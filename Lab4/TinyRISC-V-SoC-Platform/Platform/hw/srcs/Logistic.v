module NewLogistic (
    input clk,
    input rst_n,
    input start,
    input [31:0] input_a,
    output reg done,
    output reg [31:0] result
);

  localparam constant_1_over_3 = 715827883;
  localparam exp_neg_1_over_8 = 1895147668;
  // exp(-2^E) barrel-shifter constants, Q0.31 raw (value = raw / 2^31).
  // Multiply the running result by the constant when `remainder` bit (27+E) is 1.
  localparam exp_of_neg_1_over_4 = 1672461947;  // remainder bit 25, exp(-1/4) = 0.7788
  localparam exp_of_neg_1_over_2 = 1302514674;  // remainder bit 26, exp(-1/2) = 0.6065
  localparam exp_of_neg_1 = 790015084;  // remainder bit 27, exp(-1)   = 0.3679
  localparam exp_of_neg_2 = 290630308;  // remainder bit 28, exp(-2)   = 0.1353
  localparam exp_of_neg_4 = 39332535;  // remainder bit 29, exp(-4)   = 0.0183
  localparam exp_of_neg_8 = 720401;  // remainder bit 30, exp(-8)   = 0.000335

  localparam signed [31:0] const_48_over_17 = 32'sd1515870810;  // 48/17 Q2.29
  localparam signed [31:0] const_neg_32_over_17 = -32'sd1010580540;  // -32/17 Q2.29
  localparam signed [31:0] Fixedpoint_Q229_ONE = 32'sd1 << 29;  // 1.0 in Q2.29


  function signed [31:0] Logistic_mul;
    input signed [31:0] a;
    input signed [31:0] b;
    reg signed [63:0] product;
    reg signed [63:0] rounded;
    begin
      product = a * b;
      rounded = product + 64'sd1073741824;
      Logistic_mul = rounded[62:31];
    end
  endfunction

  function signed [31:0] rounding_divide_by_pot;
    input signed [31:0] value;
    input integer shift;
    reg signed [31:0] mask, remainder_bits, threshold;
    begin
      mask = (32'sd1 << shift) - 32'sd1;
      remainder_bits = value & mask;
      threshold = (mask >>> 1) + ((value < 0) ? 32'sd1 : 32'sd0);
      rounding_divide_by_pot = (value >>> shift) + ((remainder_bits > threshold) ? 32'sd1 : 32'sd0);
    end
  endfunction

  function signed [31:0] saturating_rounding_multiply_by_pot;
    input signed [31:0] value;
    input integer shift;
    reg signed [31:0] threshold;
    begin
      threshold = (32'sd1 << (31 - shift)) - 32'sd1;
      if (value > threshold) saturating_rounding_multiply_by_pot = 32'sh7fffffff;
      else if (value < -threshold) saturating_rounding_multiply_by_pot = 32'sh80000000;
      else saturating_rounding_multiply_by_pot = value <<< shift;
    end
  endfunction


  reg [3:0] stage;
  localparam stage_1 = 0;
  wire [31:0] t = (input_a[31] == 1'b1) ? -input_a : input_a;
  wire [31:0] m = -((t & ((1 << 25) - 1)) << 4);  // Q0.31
  wire [31:0] r = (t & 32'h7E000000);  // Q4.27

  localparam stage_2 = 1;  // taylor e(m)
  reg [5:0] stage_2_step;
  reg signed [31:0] stage_2_acc;
  wire signed [31:0] stage_2_u1 = $signed(m) + (32'sd1 << 28);  // u = m + 1/8, Q0.31
  reg signed [31:0] stage_2_u2;
  reg signed [31:0] stage_2_u3;
  reg signed [31:0] stage_2_u4;
  localparam stage_2_0 = 20;
  localparam stage_2_1 = 21;
  localparam stage_2_2 = 22;
  localparam stage_2_3 = 23;
  localparam stage_2_4 = 24;
  localparam stage_2_5 = 25;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n || stage != stage_2) begin
      stage_2_step <= stage_2_0;
    end else if (stage == stage_2) begin
      stage_2_step <= stage_2_step + 1;
      if (stage_2_step == stage_2_0) begin
        stage_2_u2 <= Logistic_mul(stage_2_u1, stage_2_u1);  // u^2
      end else if (stage_2_step == stage_2_1) begin
        stage_2_u3 <= Logistic_mul(stage_2_u2, stage_2_u1);  // u^3
        stage_2_u4 <= Logistic_mul(stage_2_u2, stage_2_u2);  // u^4
      end else if (stage_2_step == stage_2_2) begin
        stage_2_acc <= rounding_divide_by_pot(stage_2_u4, 2) + stage_2_u3;
      end else if (stage_2_step == stage_2_3) begin
        stage_2_u3 <= Logistic_mul(stage_2_acc, constant_1_over_3);
      end else if (stage_2_step == stage_2_4) begin
        stage_2_acc <= stage_2_u1 + rounding_divide_by_pot(stage_2_u3 + stage_2_u2, 1);
      end else if (stage_2_step == stage_2_5) begin
        stage_2_acc <= exp_neg_1_over_8 + Logistic_mul(exp_neg_1_over_8, stage_2_acc);
      end
    end
  end

  localparam stage_3 = 2;  // exp(-2^E) * exp(m)
  reg [2:0] stage_3_step;
  reg signed [31:0] stage_3_acc;

  function signed [31:0] exp_factor;
    input [2:0] step;
    begin
      case (step)
        3'd1: exp_factor = exp_of_neg_1_over_4;
        3'd2: exp_factor = exp_of_neg_1_over_2;
        3'd3: exp_factor = exp_of_neg_1;
        3'd4: exp_factor = exp_of_neg_2;
        3'd5: exp_factor = exp_of_neg_4;
        3'd6: exp_factor = exp_of_neg_8;
        default: exp_factor = 32'sd0;
      endcase
    end
  endfunction

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n || stage != stage_3) begin
      stage_3_step <= 3'd0;
    end else if (stage == stage_3) begin
      if (stage_3_step == 3'd0) begin
        stage_3_acc  <= stage_2_acc;  // start with exp(m)
        stage_3_step <= 3'd1;
      end else if (stage_3_step <= 3'd6) begin
        if (r[24+stage_3_step]) stage_3_acc <= Logistic_mul(stage_3_acc, exp_factor(stage_3_step));
        stage_3_step <= stage_3_step + 3'd1;
      end
    end
  end

  localparam stage_4 = 3;  // h = (1+e)/2
  wire signed [31:0] stage_4_acc = (stage_3_acc >>> 1) + (32'sd1 << 30);  // (1 + exp(-|x|)) / 2
  wire signed [31:0] h = stage_4_acc;

  localparam stage_5 = 4;  // Newton-Raphson iteration to compute 1/h
  reg [2:0] stage_5_step;
  reg signed [31:0] z;  // Q2.29 estimate of 1/h
  reg signed [31:0] one_minus_hz;  // Q2.29
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n || stage != stage_5) begin
      stage_5_step <= 3'd0;
    end else if (stage == stage_5) begin
      if (stage_5_step <= 3'd6) begin
        stage_5_step <= stage_5_step + 3'd1;
        case (stage_5_step)
          3'd0: z <= const_48_over_17 + Logistic_mul(h, const_neg_32_over_17);
          3'd1, 3'd3, 3'd5: one_minus_hz <= Fixedpoint_Q229_ONE - Logistic_mul(h, z);
          3'd2, 3'd4, 3'd6:
          z <= z + saturating_rounding_multiply_by_pot(Logistic_mul(z, one_minus_hz), 2);
        endcase
      end
    end
  end

  localparam stage_6 = 5;  // final result
  wire signed [31:0] s = saturating_rounding_multiply_by_pot(z, 1);
  localparam stage_done = 6;

  // Control only: each arithmetic stage keeps its own always block above.
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      stage <= stage_1;
      done <= 1'b0;
      result <= 32'd0;
    end else begin
      done <= 1'b0;
      case (stage)
        stage_1: if (start) stage <= stage_2;
        stage_2: if (stage_2_step == stage_2_5) stage <= stage_3;
        stage_3: if (stage_3_step == 3'd6) stage <= stage_4;
        stage_4: stage <= stage_5;
        stage_5: if (stage_5_step == 3'd6) stage <= stage_6;
        stage_6: begin
          if (input_a == 0) result <= 32'sd1 << 30;
          else if ($signed(input_a) > 0) result <= s;
          else result <= 32'sh7fffffff - s;
          done <= 1'b1;
          stage <= stage_done;
        end
        stage_done: stage <= stage_1;
        default: stage <= stage_1;
      endcase
    end
  end

endmodule
