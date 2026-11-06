module Logistic(
    input clk,
    input rst_n,

    input [31:0] input_a,
    output done,
    output [31:0] result
);

localparam devided_3 = 715827883;
localparam exponential_devided_minus_8 = 1895147668;

// exp(-2^E) barrel-shifter constants, Q0.31 raw (value = raw / 2^31).
// Multiply the running result by the constant when `remainder` bit (27+E) is 1.
localparam exp_minus_1_4 = 1672461947;  // remainder bit 25, exp(-1/4) = 0.7788
localparam exp_minus_1_2 = 1302514674;  // remainder bit 26, exp(-1/2) = 0.6065
localparam exp_minus_1   = 790015084;   // remainder bit 27, exp(-1)   = 0.3679
localparam exp_minus_2   = 290630308;   // remainder bit 28, exp(-2)   = 0.1353
localparam exp_minus_4   = 39332535;    // remainder bit 29, exp(-4)   = 0.0183
localparam exp_minus_8   = 720401;      // remainder bit 30, exp(-8)   = 0.000335

// ports are raw bits; read the input as a signed Q4.27 value
// stage 0: the input is registered first, so the CPU-side path ends here.
reg  signed [31:0] a_s0;
always @(posedge clk) a_s0 <= input_a;
wire signed [31:0] a = a_s0;

// |a| and -|a|. gemmlowp evaluates exp() on the NEGATIVE value -|a|.
wire signed [31:0] a_abs = (a > 0) ? a : -a;
wire signed [31:0] neg_t = -a_abs;

// split -|a| into a small part in [-1/4, 0) plus a multiple of 1/4 (Q4.27).
// 1/4 in Q4.27 is 1<<25.
wire signed [31:0] mod       = (neg_t & ((32'sd1 << 25) - 32'sd1)) - (32'sd1 << 25);
wire signed [31:0] remainder = mod - neg_t;

// Rescale<0>: Q4.27 -> Q0.31 is a left shift by 4 (same real value).
// Then x = mod + 1/8, and 1/8 in Q0.31 is 1<<28.
wire signed [31:0] mod_q31 = mod <<< 4;
wire signed [31:0] x       = mod_q31 + (32'sd1 << 28);

function signed [31:0] mul_q31(input signed [31:0] a, input signed [31:0] b);
    reg signed [63:0] p;
    begin
        p = a * b;
        mul_q31 = (p + (64'sd1 << 30)) >>> 31;      
    end
endfunction

// Divide by 2^n with round-to-nearest (gemmlowp RoundingDivideByPOT).
function signed [31:0] rdiv_pot(input signed [31:0] v, input integer n);
    reg signed [31:0] mask, remd, thr;
    begin
        mask = (32'sd1 << n) - 32'sd1;
        remd = v & mask;
        thr  = (mask >>> 1) + ((v < 0) ? 32'sd1 : 32'sd0);
        rdiv_pot = (v >>> n) + ((remd > thr) ? 32'sd1 : 32'sd0);
    end
endfunction

//==============================================================================
// 1 / (1 + e) for e = exp(-|a|) in (0,1)   (gemmlowp one_over_one_plus_x_for_x_in_0_1)
//   formats: e, half_den are Q0.31; x_* are Q2.29 (1.0 = 1<<29)
//==============================================================================
localparam signed [31:0] c48_over_17      = 1515870810;    // 48/17,  Q2.29
localparam signed [31:0] c_neg32_over_17  = -1010580540;   // -32/17, Q2.29
localparam signed [31:0] ONE_Q2_29        = 32'sd1 << 29;

// Saturating arithmetic left shift by n (gemmlowp Rescale to more fractional bits).
function signed [31:0] sat_shl(input signed [31:0] v, input integer n);
    reg signed [31:0] thr;
    begin
        thr = (32'sd1 << (31 - n)) - 32'sd1;
        if      (v >  thr) sat_shl = 32'sh7fffffff;
        else if (v < -thr) sat_shl = 32'sh80000000;
        else               sat_shl = v <<< n;
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
// Pipeline. One 32x32 multiply (mul_q31) per stage at most, so each stage is short.
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
// one clock earlier. Total latency from input_a to result: LATENCY clocks.
//==============================================================================
localparam LATENCY = 21;

// values carried along the pipeline (aligned to their stage index)
reg signed [31:0] remainder_pipe [1:10];
reg        [1:0]  sign_pipe      [1:19];      // {a_is_zero, a_is_positive}

// exp(mod) = exp(-1/8) * (1 + x + x^2/2 + x^3/6 + x^4/24), same op order as gemmlowp
reg signed [31:0] x_s1, x2_s1;
reg signed [31:0] x_s2, x2_s2, x3_s2, x4_s2;
reg signed [31:0] x_s3, x2_s3, x4_over_4_plus_x3_times_one_third_s3;
reg signed [31:0] x_plus_poly_rest_s4;

// exp(-|a|) after each barrel stage; exp_pipe[5] = exp_mod, exp_pipe[11] = exp_on_negative_values
reg signed [31:0] exp_pipe [5:11];

// 1/(1+e) Newton-Raphson
reg signed [31:0] half_denominator_pipe         [12:19];
reg signed [31:0] x_recip_pipe                  [13:19];
reg signed [31:0] half_denominator_times_x_pipe [14:18];

wire signed [31:0] result_if_positive = sat_shl(x_recip_pipe[19], 1);   // 1 / (1 + e), Q0.31
wire signed [31:0] result_if_negative = 32'sh7fffffff - result_if_positive;
reg  signed [31:0] result_s20;

integer pipe_i;
always @(posedge clk) begin
    // ---- carried values ----
    remainder_pipe[1] <= remainder;
    sign_pipe[1]      <= {(a == 0), (a > 0)};
    for (pipe_i = 2; pipe_i <= 10; pipe_i = pipe_i + 1) remainder_pipe[pipe_i] <= remainder_pipe[pipe_i - 1];
    for (pipe_i = 2; pipe_i <= 19; pipe_i = pipe_i + 1) sign_pipe[pipe_i]      <= sign_pipe[pipe_i - 1];

    // ---- stage 1..5: exp of the small part ----
    x_s1  <= x;
    x2_s1 <= mul_q31(x, x);

    x_s2  <= x_s1;
    x2_s2 <= x2_s1;
    x3_s2 <= mul_q31(x2_s1, x_s1);
    x4_s2 <= mul_q31(x2_s1, x2_s1);

    x_s3  <= x_s2;
    x2_s3 <= x2_s2;
    x4_over_4_plus_x3_times_one_third_s3 <= mul_q31(rdiv_pot(x4_s2, 2) + x3_s2, devided_3);

    // poly_rest = x^2/2 + x^3/6 + x^4/24
    x_plus_poly_rest_s4 <= x_s3 + rdiv_pot(x4_over_4_plus_x3_times_one_third_s3 + x2_s3, 1);

    exp_pipe[5] <= exponential_devided_minus_8
                   + mul_q31(exponential_devided_minus_8, x_plus_poly_rest_s4);

    // ---- stage 6..11: barrel shifter (bit 25 = 1/4, 26 = 1/2, 27 = 1, 28 = 2, 29 = 4, 30 = 8) ----
    exp_pipe[6]  <= remainder_pipe[5][25]  ? mul_q31(exp_pipe[5],  exp_minus_1_4) : exp_pipe[5];
    exp_pipe[7]  <= remainder_pipe[6][26]  ? mul_q31(exp_pipe[6],  exp_minus_1_2) : exp_pipe[6];
    exp_pipe[8]  <= remainder_pipe[7][27]  ? mul_q31(exp_pipe[7],  exp_minus_1)   : exp_pipe[7];
    exp_pipe[9]  <= remainder_pipe[8][28]  ? mul_q31(exp_pipe[8],  exp_minus_2)   : exp_pipe[8];
    exp_pipe[10] <= remainder_pipe[9][29]  ? mul_q31(exp_pipe[9],  exp_minus_4)   : exp_pipe[9];
    exp_pipe[11] <= remainder_pipe[10][30] ? mul_q31(exp_pipe[10], exp_minus_8)   : exp_pipe[10];

    // ---- stage 12..19: 1 / (1 + e) ----
    half_denominator_pipe[12] <= rounding_half_sum(exp_pipe[11], 32'sh7fffffff);        // (e + 1) / 2
    for (pipe_i = 13; pipe_i <= 19; pipe_i = pipe_i + 1)
        half_denominator_pipe[pipe_i] <= half_denominator_pipe[pipe_i - 1];

    // initial estimate: x = 48/17 - 32/17 * half_denominator
    x_recip_pipe[13] <= c48_over_17 + mul_q31(half_denominator_pipe[12], c_neg32_over_17);

    // 3 Newton-Raphson steps: x = x + x * (1 - half_denominator * x), 2 stages per step
    half_denominator_times_x_pipe[14] <= mul_q31(half_denominator_pipe[13], x_recip_pipe[13]);
    x_recip_pipe[14]                  <= x_recip_pipe[13];
    x_recip_pipe[15] <= x_recip_pipe[14]
                        + sat_shl(mul_q31(x_recip_pipe[14], ONE_Q2_29 - half_denominator_times_x_pipe[14]), 2);

    half_denominator_times_x_pipe[16] <= mul_q31(half_denominator_pipe[15], x_recip_pipe[15]);
    x_recip_pipe[16]                  <= x_recip_pipe[15];
    x_recip_pipe[17] <= x_recip_pipe[16]
                        + sat_shl(mul_q31(x_recip_pipe[16], ONE_Q2_29 - half_denominator_times_x_pipe[16]), 2);

    half_denominator_times_x_pipe[18] <= mul_q31(half_denominator_pipe[17], x_recip_pipe[17]);
    x_recip_pipe[18]                  <= x_recip_pipe[17];
    x_recip_pipe[19] <= x_recip_pipe[18]
                        + sat_shl(mul_q31(x_recip_pipe[18], ONE_Q2_29 - half_denominator_times_x_pipe[18]), 2);

    // ---- stage 20: sigmoid(a): a > 0 -> result_if_positive ; a < 0 -> 1 - result_if_positive ; a == 0 -> 0.5 ----
    result_s20 <= sign_pipe[19][1] ? (32'sd1 << 30)
                : sign_pipe[19][0] ? result_if_positive
                :                    result_if_negative;
end

assign result = result_s20;

//==============================================================================
// done: the result is valid once input_a has been stable for LATENCY clocks.
// (rs1_i stays stable while the CPU waits, so no separate start signal is needed.
//  If the same value is presented again, the pipeline already holds its result.)
//==============================================================================
reg [31:0] input_a_prev;
reg [4:0]  stable_cnt;
wire       input_a_changed = (input_a != input_a_prev);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        input_a_prev <= 32'd0;
        stable_cnt   <= 5'd0;
    end else begin
        input_a_prev <= input_a;
        if (input_a_changed)                  stable_cnt <= 5'd0;
        else if (stable_cnt != LATENCY - 1)   stable_cnt <= stable_cnt + 5'd1;
    end
end

assign done = !input_a_changed && (stable_cnt == LATENCY - 1);

endmodule
