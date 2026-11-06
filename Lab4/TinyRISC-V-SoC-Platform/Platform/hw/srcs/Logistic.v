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
wire signed [31:0] a = input_a;

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

// exp(mod) = exp(-1/8) * (1 + x + x^2/2 + x^3/6 + x^4/24), same op order as gemmlowp
wire signed [31:0] x2         = mul_q31(x, x);
wire signed [31:0] x3         = mul_q31(x2, x);
wire signed [31:0] x4         = mul_q31(x2, x2);
wire signed [31:0] x4_over_4  = rdiv_pot(x4, 2);
// = x^2/2 + x^3/6 + x^4/24
wire signed [31:0] poly_rest  = rdiv_pot(mul_q31(x4_over_4 + x3, devided_3) + x2, 1);
wire signed [31:0] exp_mod    = exponential_devided_minus_8
                                + mul_q31(exponential_devided_minus_8, x + poly_rest);

// Barrel shifter: for each set bit of `remainder`, multiply by exp(-2^E).
// bit 25 = 1/4, 26 = 1/2, 27 = 1, 28 = 2, 29 = 4, 30 = 8 (same order as gemmlowp).
wire signed [31:0] exp_s0 = remainder[25] ? mul_q31(exp_mod, exp_minus_1_4) : exp_mod;
wire signed [31:0] exp_s1 = remainder[26] ? mul_q31(exp_s0,  exp_minus_1_2) : exp_s0;
wire signed [31:0] exp_s2 = remainder[27] ? mul_q31(exp_s1,  exp_minus_1)   : exp_s1;
wire signed [31:0] exp_s3 = remainder[28] ? mul_q31(exp_s2,  exp_minus_2)   : exp_s2;
wire signed [31:0] exp_s4 = remainder[29] ? mul_q31(exp_s3,  exp_minus_4)   : exp_s3;
wire signed [31:0] exp_neg = remainder[30] ? mul_q31(exp_s4, exp_minus_8)   : exp_s4;   // exp(-|a|), Q0.31

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

wire signed [31:0] half_den = rounding_half_sum(exp_neg, 32'sh7fffffff);   // (e + 1) / 2

// initial estimate: x0 = 48/17 - 32/17 * half_den
wire signed [31:0] rx0 = c48_over_17 + mul_q31(half_den, c_neg32_over_17);

// 3 Newton-Raphson steps: x = x + x * (1 - half_den * x)
wire signed [31:0] rx1 = rx0 + sat_shl(mul_q31(rx0, ONE_Q2_29 - mul_q31(half_den, rx0)), 2);
wire signed [31:0] rx2 = rx1 + sat_shl(mul_q31(rx1, ONE_Q2_29 - mul_q31(half_den, rx1)), 2);
wire signed [31:0] rx3 = rx2 + sat_shl(mul_q31(rx2, ONE_Q2_29 - mul_q31(half_den, rx2)), 2);

// x / 2 and back to Q0.31: same raw value shifted left by 1 (saturating)
wire signed [31:0] result_if_positive = sat_shl(rx3, 1);                                // 1 / (1 + e), Q0.31

// sigmoid(a): a > 0 -> result_if_positive ; a < 0 -> 1 - result_if_positive (1.0 = 0x7fffffff in Q0.31) ; a == 0 -> 0.5
wire signed [31:0] result_if_negative = 32'sh7fffffff - result_if_positive;
assign result = (a == 0) ? (32'sd1 << 30) : (a > 0) ? result_if_positive : result_if_negative;
assign done   = 1'b1;     // purely combinational: result is valid as long as input_a is stable

endmodule
