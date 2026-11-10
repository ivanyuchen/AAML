`timescale 1ns / 1ps

module new_logistic_tb;
  reg clk = 1'b0;
  reg rst_n = 1'b0;
  reg start = 1'b0;
  reg [31:0] input_a = 32'd0;
  wire done;
  wire [31:0] result;
  integer failures = 0;
  integer checks = 0;
  integer cycles;
  integer i;
  real input_real;
  real expected;
  real actual;
  real error;
  real max_error = 0.0;

  NewLogistic dut (
      .clk(clk), .rst_n(rst_n), .start(start),
      .input_a(input_a), .done(done), .result(result)
  );

  always #5 clk = ~clk;

  task check_input;
    input signed [31:0] raw_input;
    begin
      @(negedge clk);
      input_a = raw_input;
      start = 1'b1;
      @(negedge clk);
      start = 1'b0;
      // The NPU keeps rs1_i stable until the custom instruction completes.
      cycles = 0;
      while (!done && cycles < 40) begin
        @(negedge clk);
        cycles = cycles + 1;
      end

      if (!done) begin
        $display("FAIL timeout input_raw=%0d", raw_input);
        failures = failures + 1;
      end else begin
        input_real = $itor(raw_input) / 134217728.0;
        expected = 1.0 / (1.0 + $exp(-input_real));
        actual = $itor($signed(result)) / 2147483648.0;
        error = actual - expected;
        if (error < 0.0) error = -error;
        if (error > max_error) max_error = error;
        if (error > 0.00001 || result[31]) begin
          $display("FAIL input=%f expected=%f actual=%f raw=%0d", input_real, expected, actual, $signed(result));
          failures = failures + 1;
        end
      end
      checks = checks + 1;
      repeat (2) @(negedge clk);
    end
  endtask

  initial begin
    repeat (2) @(negedge clk);
    rst_n = 1'b1;
    check_input(32'sd0);
    check_input(32'sd0);  // same input must start a new operation
    check_input(32'sd134217728);  // +1
    check_input(-32'sd134217728); // -1
    for (i = -255; i <= 255; i = i + 1)
      check_input(i * 32'sd8388608);  // Q4.27 values from -15.9375 to +15.9375

    $display("checks=%0d failures=%0d max_real_error=%g", checks, failures, max_error);
    if (failures != 0) $fatal(1, "NewLogistic test failed");
    $finish;
  end
endmodule
