module Logistic(
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
// Pipeline. One 32x32 multiply (saturating_rounding_doubling_high_mul) per stage at most, so each stage is short.
//   stage 0       input register                      (above)
//   stage 1       x2
//   stage 2       x3, x4
//   stage 3       (x4/4 + x3) * 1/3
//   stage 4       x + poly_rest
//   stage 5       exp_mod  (exp of the small part)
//   stage 6..11   barrel shifter, one exp(-2^E) factor per stage
//   stage 12      half_denominator
//   stage 13      first estimate of 1/half_denominator
//   stage 14..19  3 Newton-Raphson steps, 2 stages each
//   stage 20      sign / zero select -> result
// Everything is aligned: the value in stage k belongs to the same input as stage k-1 had
// one clock earlier. Total latency from input_a to result: PIPELINE_LATENCY clocks.
//==============================================================================
localparam PIPELINE_LATENCY = 21;

// values carried along the pipeline (aligned to their stage index)
reg signed [31:0] remainder_pipe [1:10];
reg        [1:0]  sign_pipe      [1:19];      // {a_is_zero, a_is_positive}

// exp(a_mod_quarter_minus_one_quarter) = exp(-1/8) * (1 + x + x^2/2 + x^3/6 + x^4/24), same op order as gemmlowp
reg signed [31:0] x_stage1, x2_stage1;
reg signed [31:0] x_stage2, x2_stage2, x3_stage2, x4_stage2;
reg signed [31:0] x_stage3, x2_stage3, x4_over_4_plus_x3_times_constant_1_over_3_stage3;
reg signed [31:0] x_plus_x4_over_24_plus_x3_over_6_plus_x2_over_2_stage4;

// exp(-|a|) after each barrel stage; exp_result_pipe[5] = exp_mod, exp_result_pipe[11] = exp_on_negative_values
reg signed [31:0] exp_result_pipe [5:11];

// 1/(1+e) Newton-Raphson
reg signed [31:0] half_denominator_pipe         [12:19];
reg signed [31:0] x_reciprocal_pipe                  [13:19];
reg signed [31:0] half_denominator_times_x_pipe [14:18];

wire signed [31:0] result_if_positive = saturating_rounding_multiply_by_pot(x_reciprocal_pipe[19], 1);   // 1 / (1 + e), Q0.31
wire signed [31:0] result_if_negative = 32'sh7fffffff - result_if_positive;
reg  signed [31:0] result_stage20;

integer pipeline_index;
always @(posedge clk) begin
    // ---- carried values ----
    remainder_pipe[1] <= remainder;
    sign_pipe[1]      <= {(a == 0), (a > 0)};
    for (pipeline_index = 2; pipeline_index <= 10; pipeline_index = pipeline_index + 1) remainder_pipe[pipeline_index] <= remainder_pipe[pipeline_index - 1];
    for (pipeline_index = 2; pipeline_index <= 19; pipeline_index = pipeline_index + 1) sign_pipe[pipeline_index]      <= sign_pipe[pipeline_index - 1];

    // ---- stage 1..5: exp of the small part ----
    x_stage1  <= x;
    x2_stage1 <= saturating_rounding_doubling_high_mul(x, x);

    x_stage2  <= x_stage1;
    x2_stage2 <= x2_stage1;
    x3_stage2 <= saturating_rounding_doubling_high_mul(x2_stage1, x_stage1);
    x4_stage2 <= saturating_rounding_doubling_high_mul(x2_stage1, x2_stage1);

    x_stage3  <= x_stage2;
    x2_stage3 <= x2_stage2;
    x4_over_4_plus_x3_times_constant_1_over_3_stage3 <= saturating_rounding_doubling_high_mul(rounding_divide_by_pot(x4_stage2, 2) + x3_stage2, constant_1_over_3);

    // poly_rest = x^2/2 + x^3/6 + x^4/24
    x_plus_x4_over_24_plus_x3_over_6_plus_x2_over_2_stage4 <= x_stage3 + rounding_divide_by_pot(x4_over_4_plus_x3_times_constant_1_over_3_stage3 + x2_stage3, 1);

    exp_result_pipe[5] <= constant_term
                   + saturating_rounding_doubling_high_mul(constant_term, x_plus_x4_over_24_plus_x3_over_6_plus_x2_over_2_stage4);

    // ---- stage 6..11: barrel shifter (bit 25 = 1/4, 26 = 1/2, 27 = 1, 28 = 2, 29 = 4, 30 = 8) ----
    exp_result_pipe[6]  <= remainder_pipe[5][25]  ? saturating_rounding_doubling_high_mul(exp_result_pipe[5],  exp_of_neg_1_over_4) : exp_result_pipe[5];
    exp_result_pipe[7]  <= remainder_pipe[6][26]  ? saturating_rounding_doubling_high_mul(exp_result_pipe[6],  exp_of_neg_1_over_2) : exp_result_pipe[6];
    exp_result_pipe[8]  <= remainder_pipe[7][27]  ? saturating_rounding_doubling_high_mul(exp_result_pipe[7],  exp_of_neg_1)   : exp_result_pipe[7];
    exp_result_pipe[9]  <= remainder_pipe[8][28]  ? saturating_rounding_doubling_high_mul(exp_result_pipe[8],  exp_of_neg_2)   : exp_result_pipe[8];
    exp_result_pipe[10] <= remainder_pipe[9][29]  ? saturating_rounding_doubling_high_mul(exp_result_pipe[9],  exp_of_neg_4)   : exp_result_pipe[9];
    exp_result_pipe[11] <= remainder_pipe[10][30] ? saturating_rounding_doubling_high_mul(exp_result_pipe[10], exp_of_neg_8)   : exp_result_pipe[10];

    // ---- stage 12..19: 1 / (1 + e) ----
    half_denominator_pipe[12] <= rounding_half_sum(exp_result_pipe[11], 32'sh7fffffff);        // (e + 1) / 2
    for (pipeline_index = 13; pipeline_index <= 19; pipeline_index = pipeline_index + 1)
        half_denominator_pipe[pipeline_index] <= half_denominator_pipe[pipeline_index - 1];

    // initial estimate: x = 48/17 - 32/17 * half_denominator
    x_reciprocal_pipe[13] <= constant_48_over_17 + saturating_rounding_doubling_high_mul(half_denominator_pipe[12], constant_neg_32_over_17);

    // 3 Newton-Raphson steps: x = x + x * (1 - half_denominator * x), 2 stages per step
    half_denominator_times_x_pipe[14] <= saturating_rounding_doubling_high_mul(half_denominator_pipe[13], x_reciprocal_pipe[13]);
    x_reciprocal_pipe[14] <= x_reciprocal_pipe[13];
    x_reciprocal_pipe[15] <= x_reciprocal_pipe[14]
                        + saturating_rounding_multiply_by_pot(saturating_rounding_doubling_high_mul(x_reciprocal_pipe[14], F2_ONE - half_denominator_times_x_pipe[14]), 2);

    half_denominator_times_x_pipe[16] <= saturating_rounding_doubling_high_mul(half_denominator_pipe[15], x_reciprocal_pipe[15]);
    x_reciprocal_pipe[16]                  <= x_reciprocal_pipe[15];
    x_reciprocal_pipe[17] <= x_reciprocal_pipe[16]
                        + saturating_rounding_multiply_by_pot(saturating_rounding_doubling_high_mul(x_reciprocal_pipe[16], F2_ONE - half_denominator_times_x_pipe[16]), 2);

    half_denominator_times_x_pipe[18] <= saturating_rounding_doubling_high_mul(half_denominator_pipe[17], x_reciprocal_pipe[17]);
    x_reciprocal_pipe[18]                  <= x_reciprocal_pipe[17];
    x_reciprocal_pipe[19] <= x_reciprocal_pipe[18]
                        + saturating_rounding_multiply_by_pot(saturating_rounding_doubling_high_mul(x_reciprocal_pipe[18], F2_ONE - half_denominator_times_x_pipe[18]), 2);

    // ---- stage 20: sigmoid(a): a > 0 -> result_if_positive ; a < 0 -> 1 - result_if_positive ; a == 0 -> 0.5 ----
    result_stage20 <= sign_pipe[19][1] ? (32'sd1 << 30)
                : sign_pipe[19][0] ? result_if_positive
                :                    result_if_negative;
end

assign result = result_stage20;

//==============================================================================
// done: the result is valid once input_a has been stable for PIPELINE_LATENCY clocks.
// (rs1_i stays stable while the CPU waits, so no separate start signal is needed.
//  If the same value is presented again, the pipeline already holds its result.)
//==============================================================================
reg [31:0] previous_input_a;
reg [4:0]  stable_cycle_count;
wire       input_a_changed = (input_a != previous_input_a);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        previous_input_a <= 32'd0;
        stable_cycle_count   <= 5'd0;
    end else begin
        previous_input_a <= input_a;
        if (input_a_changed) stable_cycle_count <= 5'd0;
        else if (stable_cycle_count != PIPELINE_LATENCY - 1) stable_cycle_count <= stable_cycle_count + 5'd1;
    end
end

assign done = !input_a_changed && (stable_cycle_count == PIPELINE_LATENCY - 1);

endmodule
