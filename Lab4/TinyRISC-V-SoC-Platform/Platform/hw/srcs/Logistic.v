module Logistic #(
    parameter MUL_LAT = 2   // product registers per multiply (see Pipeline below)
) (
    input clk,
    input rst_n,

    input [31:0] input_a,
    output done,
    output [31:0] result
);

localparam constant_1_over_3 = 715827883;
localparam constant_term = 1895147668;

// exp(-2^E) barrel-shifter constants, Q0.31 raw (value = raw / 2^31).
// Multiply the running result by the constant when `remainder` bit (27+E) is 1.
localparam exp_of_neg_1_over_4 = 1672461947;  // remainder bit 25, exp(-1/4) = 0.7788
localparam exp_of_neg_1_over_2 = 1302514674;  // remainder bit 26, exp(-1/2) = 0.6065
localparam exp_of_neg_1   = 790015084;   // remainder bit 27, exp(-1)   = 0.3679
localparam exp_of_neg_2   = 290630308;   // remainder bit 28, exp(-2)   = 0.1353
localparam exp_of_neg_4   = 39332535;    // remainder bit 29, exp(-4)   = 0.0183
localparam exp_of_neg_8   = 720401;      // remainder bit 30, exp(-8)   = 0.000335

// ports are raw bits; read the input as a signed Q4.27 value
// stage 0: the input is registered first, so the CPU-side path ends here.
reg  signed [31:0] a_stage0;
always @(posedge clk) a_stage0 <= input_a;
wire signed [31:0] a = a_stage0;

// |a| and -|a|. gemmlowp evaluates exp() on the NEGATIVE value -|a|.
wire signed [31:0] abs_input = (a > 0) ? a : -a;
wire signed [31:0] negative_abs_input = -abs_input;

// split -|a| into a small part in [-1/4, 0) plus a multiple of 1/4 (Q4.27).
// 1/4 in Q4.27 is 1<<25.
wire signed [31:0] a_mod_quarter_minus_one_quarter       = (negative_abs_input & ((32'sd1 << 25) - 32'sd1)) - (32'sd1 << 25);
wire signed [31:0] remainder = a_mod_quarter_minus_one_quarter - negative_abs_input;

// Rescale<0>: Q4.27 -> Q0.31 is a left shift by 4 (same real value).
// Then x = a_mod_quarter_minus_one_quarter + 1/8, and 1/8 in Q0.31 is 1<<28.
wire signed [31:0] a_mod_quarter_minus_one_quarter_f0 = a_mod_quarter_minus_one_quarter <<< 4;
wire signed [31:0] x       = a_mod_quarter_minus_one_quarter_f0 + (32'sd1 << 28);

function signed [31:0] saturating_rounding_doubling_high_mul(input signed [31:0] a, input signed [31:0] b);
    reg signed [63:0] ab_64;
    begin
        ab_64 = a * b;
        saturating_rounding_doubling_high_mul = (ab_64 + (64'sd1 << 30)) >>> 31;      
    end
endfunction

// Divide by 2^n with round-to-nearest (gemmlowp RoundingDivideByPOT).
function signed [31:0] rounding_divide_by_pot(input signed [31:0] v, input integer n);
    reg signed [31:0] mask, remainder_bits, threshold;
    begin
        mask = (32'sd1 << n) - 32'sd1;
        remainder_bits = v & mask;
        threshold  = (mask >>> 1) + ((v < 0) ? 32'sd1 : 32'sd0);
        rounding_divide_by_pot = (v >>> n) + ((remainder_bits > threshold) ? 32'sd1 : 32'sd0);
    end
endfunction

//==============================================================================
// 1 / (1 + e) for e = exp(-|a|) in (0,1)   (gemmlowp one_over_one_plus_x_for_x_in_0_1)
//   formats: e, half_den are Q0.31; x_* are Q2.29 (1.0 = 1<<29)
//==============================================================================
localparam signed [31:0] constant_48_over_17      = 1515870810;    // 48/17,  Q2.29
localparam signed [31:0] constant_neg_32_over_17  = -1010580540;   // -32/17, Q2.29
localparam signed [31:0] F2_ONE        = 32'sd1 << 29;

// Saturating arithmetic left shift by n (gemmlowp Rescale to more fractional bits).
function signed [31:0] saturating_rounding_multiply_by_pot(input signed [31:0] v, input integer n);
    reg signed [31:0] threshold;
    begin
        threshold = (32'sd1 << (31 - n)) - 32'sd1;
        if      (v >  threshold) saturating_rounding_multiply_by_pot = 32'sh7fffffff;
        else if (v < -threshold) saturating_rounding_multiply_by_pot = 32'sh80000000;
        else               saturating_rounding_multiply_by_pot = v <<< n;
    end
endfunction

// (a + b) / 2 rounded away from the middle (gemmlowp RoundingHalfSum), 64-bit sum.
function signed [31:0] rounding_half_sum(input signed [31:0] a, input signed [31:0] b);
    reg signed [63:0] sum;
    begin
        sum = a + b;
        sum = sum + ((sum >= 0) ? 64'sd1 : -64'sd1);
        rounding_half_sum = (sum + ((sum < 0) ? 64'sd1 : 64'sd0)) >>> 1;   // divide by 2, toward 0
    end
endfunction

//==============================================================================
// Pipeline (81 MHz ui_clk = 12.3 ns, too short for a 32x32 multiply plus its
// rounding and the surrounding adds in one cycle).
//
// Every multiply goes through Logistic_mul: MUL_LAT product registers, which
// Vivado packs into the DSP48 M/P registers. A "step" = multiply + post-op:
//   inputs registered at T  ->  product at T + MUL_LAT  ->  post-op result
//   registered at T + STEP  (STEP = MUL_LAT + 1)
// Values not consumed by a step ride along in *_at[T] shift registers, where
// the index is the cycle (counted from a_stage0 = 0) the value belongs to.
//
//   T = 1                x, remainder bits, sign            (from a_stage0)
//   step  1              x2 = x*x
//   step  2              x3 = x2*x, x4 = x2*x2  ->  x4/4 + x3
//   step  3              (x4/4 + x3) * 1/3      ->  poly = x + (.. + x2)/2
//   step  4              exp_mod = c + c*poly
//   steps 5..10          barrel shifter, one exp(-2^E) factor per step
//   +1 cycle             half_denominator = (e + 1) / 2
//   step 11              x0 = 48/17 - 32/17 * half_denominator
//   steps 12..17         3 Newton-Raphson iterations, 2 steps each
//   +1 cycle             sign / zero select -> result
// Bit-exact with the single-cycle-per-stage version (same ops, same order).
//==============================================================================
localparam STEP    = MUL_LAT + 1;

localparam T_X     = 1;                       // x, remainder, sign
localparam T_X2    = T_X + STEP;              // x2
localparam T_S3    = T_X2 + STEP;             // x4/4 + x3
localparam T_POLY  = T_S3 + STEP;             // poly
localparam T_E0    = T_POLY + STEP;           // exp_mod
localparam T_E6    = T_E0 + 6 * STEP;         // exp(-|a|)
localparam T_HD    = T_E6 + 1;                // half_denominator
localparam T_XR0   = T_HD + STEP;             // first estimate of 1/half_den
localparam T_XR3   = T_XR0 + 6 * STEP;        // after 3 Newton-Raphson steps
localparam T_RES   = T_XR3 + 1;               // result register
localparam PIPELINE_LATENCY = T_RES + 1;      // + the a_stage0 input register

// ---- T = 1 ----
reg signed [31:0] x_at   [T_X:T_S3+MUL_LAT];
reg        [ 5:0] rem_at [T_X:T_E6-1];       // remainder bits [30:25]
reg        [ 1:0] sign_at[T_X:T_RES-1];      // {a_is_zero, a_is_positive}

// ---- step 1: x2 ----
wire signed [31:0] x2_y;
Logistic_mul #(.LAT(MUL_LAT)) u_mul_x2 (.clk(clk), .a(x_at[T_X]), .b(x_at[T_X]), .y(x2_y));
reg signed [31:0] x2_at [T_X2:T_S3+MUL_LAT];

// ---- step 2: x3, x4 ----
wire signed [31:0] x3_y, x4_y;
Logistic_mul #(.LAT(MUL_LAT)) u_mul_x3 (.clk(clk), .a(x2_at[T_X2]), .b(x_at[T_X2]),  .y(x3_y));
Logistic_mul #(.LAT(MUL_LAT)) u_mul_x4 (.clk(clk), .a(x2_at[T_X2]), .b(x2_at[T_X2]), .y(x4_y));
reg signed [31:0] x4_over_4_plus_x3;          // valid at T_S3

// ---- step 3: (x4/4 + x3) * 1/3, poly ----
wire signed [31:0] s3_y;
Logistic_mul #(.LAT(MUL_LAT)) u_mul_s3 (.clk(clk), .a(x4_over_4_plus_x3), .b(constant_1_over_3), .y(s3_y));
reg signed [31:0] x_plus_x4_over_24_plus_x3_over_6_plus_x2_over_2;  // valid at T_POLY

// ---- step 4: exp_mod, steps 5..10: barrel shifter ----
wire signed [31:0] e0_y;
Logistic_mul #(.LAT(MUL_LAT)) u_mul_e0 (.clk(clk), .a(constant_term),
                                        .b(x_plus_x4_over_24_plus_x3_over_6_plus_x2_over_2), .y(e0_y));
reg  signed [31:0] exp_at [T_E0:T_E6];
wire signed [31:0] exp_next [1:6];            // result of barrel step j

function signed [31:0] barrel_constant(input integer j);
    case (j)
        1: barrel_constant = exp_of_neg_1_over_4;
        2: barrel_constant = exp_of_neg_1_over_2;
        3: barrel_constant = exp_of_neg_1;
        4: barrel_constant = exp_of_neg_2;
        5: barrel_constant = exp_of_neg_4;
        default: barrel_constant = exp_of_neg_8;
    endcase
endfunction

genvar g;
generate
    for (g = 1; g <= 6; g = g + 1) begin : g_barrel
        localparam T_IN = T_E0 + (g - 1) * STEP;
        wire signed [31:0] y;
        Logistic_mul #(.LAT(MUL_LAT)) u_mul (.clk(clk), .a(exp_at[T_IN]), .b(barrel_constant(g)), .y(y));
        // remainder bit 24+g selects exp(-2^(g-3))
        assign exp_next[g] = rem_at[T_IN+MUL_LAT][g-1] ? y : exp_at[T_IN+MUL_LAT];
    end
endgenerate

// ---- 1 / (1 + e) ----
reg  signed [31:0] half_denominator_at [T_HD:T_XR0+4*STEP];
wire signed [31:0] xr0_y;
Logistic_mul #(.LAT(MUL_LAT)) u_mul_xr0 (.clk(clk), .a(half_denominator_at[T_HD]),
                                         .b(constant_neg_32_over_17), .y(xr0_y));
reg  signed [31:0] x_reciprocal_at [T_XR0:T_XR3];
wire signed [31:0] x_reciprocal_next [1:3];

// Newton-Raphson iteration n: step A at T_A: half_den * x -> 1 - half_den * x
//                             step B at T_A + STEP: x + 4 * x * (1 - half_den * x)
generate
    for (g = 1; g <= 3; g = g + 1) begin : g_newton
        localparam T_A = T_XR0 + (g - 1) * 2 * STEP;
        localparam T_B = T_A + STEP;
        wire signed [31:0] hx_y, step_y;
        reg  signed [31:0] one_minus_half_denominator_times_x;   // valid at T_B
        Logistic_mul #(.LAT(MUL_LAT)) u_mul_a (.clk(clk), .a(half_denominator_at[T_A]),
                                               .b(x_reciprocal_at[T_A]), .y(hx_y));
        always @(posedge clk) one_minus_half_denominator_times_x <= F2_ONE - hx_y;
        Logistic_mul #(.LAT(MUL_LAT)) u_mul_b (.clk(clk), .a(x_reciprocal_at[T_B]),
                                               .b(one_minus_half_denominator_times_x), .y(step_y));
        assign x_reciprocal_next[g] = x_reciprocal_at[T_B+MUL_LAT]
                                    + saturating_rounding_multiply_by_pot(step_y, 2);
    end
endgenerate

wire signed [31:0] result_if_positive = saturating_rounding_multiply_by_pot(x_reciprocal_at[T_XR3], 1);   // 1 / (1 + e), Q0.31
wire signed [31:0] result_if_negative = 32'sh7fffffff - result_if_positive;
reg  signed [31:0] result_stage;

integer k;
always @(posedge clk) begin
    // ---- T = 1 ----
    x_at[T_X]    <= x;
    rem_at[T_X]  <= remainder[30:25];
    sign_at[T_X] <= {(a == 0), (a > 0)};
    for (k = T_X + 1; k <= T_S3 + MUL_LAT; k = k + 1) x_at[k]    <= x_at[k-1];
    for (k = T_X + 1; k <= T_E6 - 1;       k = k + 1) rem_at[k]  <= rem_at[k-1];
    for (k = T_X + 1; k <= T_RES - 1;      k = k + 1) sign_at[k] <= sign_at[k-1];

    // ---- step 1..3 ----
    x2_at[T_X2] <= x2_y;
    for (k = T_X2 + 1; k <= T_S3 + MUL_LAT; k = k + 1) x2_at[k] <= x2_at[k-1];

    x4_over_4_plus_x3 <= rounding_divide_by_pot(x4_y, 2) + x3_y;

    // poly_rest = x^2/2 + x^3/6 + x^4/24
    x_plus_x4_over_24_plus_x3_over_6_plus_x2_over_2 <=
        x_at[T_S3+MUL_LAT] + rounding_divide_by_pot(s3_y + x2_at[T_S3+MUL_LAT], 1);

    // ---- step 4..10: exp(-|a|) ----
    exp_at[T_E0] <= constant_term + e0_y;
    for (k = T_E0 + 1; k <= T_E6; k = k + 1) exp_at[k] <= exp_at[k-1];
    for (k = 1; k <= 6; k = k + 1) exp_at[T_E0 + k * STEP] <= exp_next[k];

    // ---- 1 / (1 + e) ----
    half_denominator_at[T_HD] <= rounding_half_sum(exp_at[T_E6], 32'sh7fffffff);   // (e + 1) / 2
    for (k = T_HD + 1; k <= T_XR0 + 4 * STEP; k = k + 1)
        half_denominator_at[k] <= half_denominator_at[k-1];

    // initial estimate: x = 48/17 - 32/17 * half_denominator
    x_reciprocal_at[T_XR0] <= constant_48_over_17 + xr0_y;
    for (k = T_XR0 + 1; k <= T_XR3; k = k + 1) x_reciprocal_at[k] <= x_reciprocal_at[k-1];
    for (k = 1; k <= 3; k = k + 1) x_reciprocal_at[T_XR0 + k * 2 * STEP] <= x_reciprocal_next[k];

    // ---- sigmoid(a): a > 0 -> result_if_positive ; a < 0 -> 1 - result_if_positive ; a == 0 -> 0.5 ----
    result_stage <= sign_at[T_RES-1][1] ? (32'sd1 << 30)
                  : sign_at[T_RES-1][0] ? result_if_positive
                  :                       result_if_negative;
end

assign result = result_stage;

//==============================================================================
// done: the result is valid once input_a has been stable for PIPELINE_LATENCY clocks.
// (rs1_i stays stable while the CPU waits, so no separate start signal is needed.
//  If the same value is presented again, the pipeline already holds its result.)
//==============================================================================
reg [31:0] previous_input_a;
reg [6:0]  stable_cycle_count;
wire       input_a_changed = (input_a != previous_input_a);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        previous_input_a <= 32'd0;
        stable_cycle_count   <= 7'd0;
    end else begin
        previous_input_a <= input_a;
        if (input_a_changed) stable_cycle_count <= 7'd0;
        else if (stable_cycle_count != PIPELINE_LATENCY - 1) stable_cycle_count <= stable_cycle_count + 7'd1;
    end
end

assign done = !input_a_changed && (stable_cycle_count == PIPELINE_LATENCY - 1);

endmodule


//==============================================================================
// Logistic_mul: y = SaturatingRoundingDoublingHighMul(a, b), same rounding as
// the saturating_rounding_doubling_high_mul function above, LAT cycles after
// a / b. The product registers have no reset so Vivado can pack them into
// the DSP48 pipeline (M / P registers).
//==============================================================================
module Logistic_mul #(
    parameter LAT = 2
) (
    input                clk,
    input  signed [31:0] a,
    input  signed [31:0] b,
    output signed [31:0] y
);
    reg signed [63:0] product [1:LAT];
    integer k;
    always @(posedge clk) begin
        product[1] <= a * b;
        for (k = 2; k <= LAT; k = k + 1) product[k] <= product[k-1];
    end
    wire signed [63:0] rounded = product[LAT] + (64'sd1 << 30);
    assign y = rounded[62:31];   // (a*b + 2^30) >>> 31, low 32 bits
endmodule
