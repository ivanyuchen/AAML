`timescale 1ns/1ps
// Compare against the pre-sharing Logistic implementation supplied as
// module Logistic_before. The comparison checks result AND completion cycle.
module logistic_shared_tb;
  reg clk=0,rst_n=0,start=0;
  reg [31:0] value=0;
  wire done_before,done_after;
  wire [31:0] before_value,after_value;
  integer checks=0,i,cycles;
  reg [31:0] random_state=32'h89abcdef;
  always #5 clk=~clk;
  Logistic_before reference(.clk(clk),.rst_n(rst_n),.start(start),
    .input_a(value),.done(done_before),.result(before_value));
  Logistic dut(.clk(clk),.rst_n(rst_n),.start(start),
    .input_a(value),.done(done_after),.result(after_value));
  always @(posedge clk) begin
    #1;
    if(rst_n && (done_before !== done_after || before_value !== after_value))
      $fatal(1,"mismatch input=%h old=%h new=%h old_done=%b new_done=%b",
        value,before_value,after_value,done_before,done_after);
  end
  task check;
    input [31:0] x;
    begin
      @(negedge clk);value=x;start=1;
      @(negedge clk);start=0;cycles=0;
      while(!done_after && cycles<40) begin @(negedge clk);cycles=cycles+1;end
      if(!done_after)$fatal(1,"timeout");
      checks=checks+1;
      repeat(2)@(negedge clk);
    end
  endtask
  initial begin
    repeat(3)@(negedge clk);rst_n=1;
    check(0);check(0);check(1);check(32'hffffffff);
    check(32'h7fffffff);check(32'h80000000);check(32'h80000001);
    // Neighbours of each exponential range-reduction boundary, both signs.
    for(i=0;i<64;i=i+1)begin
      check((i<<25)-1);check(i<<25);check((i<<25)+1);
      check(-((i<<25)-1));check(-(i<<25));check(-((i<<25)+1));
    end
    for(i=0;i<10000;i=i+1)begin
      random_state=random_state*32'd1664525+32'd1013904223;
      check(random_state);
    end
    @(negedge clk);value=32'h76543210;start=1;
    @(negedge clk);start=0;
    repeat(8)@(negedge clk);rst_n=0;
    repeat(3)@(negedge clk);rst_n=1;
    check(0);check(32'h08000000);check(32'hf8000000);
    $display("PASS shared Logistic: %0d inputs, exact raw results and done cycles; mid-run reset",checks);
    $finish;
  end
  initial begin #10000000;$fatal(1,"global timeout");end
endmodule
