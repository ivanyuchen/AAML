`timescale 1ns/1ps
module clean_cache_tb;
  reg clk=0,rst_n=0,is_npu=0,mem_busy=0,mem_valid=0,req=0;
  reg clean_done=0,npu_done=0;
  wire clean,start,invalidate_all;
  integer starts=0;
  always #5 clk=~clk;
  clean_cache dut(.clk_i(clk),.rst_n(rst_n),.is_npu_i(is_npu),
    .mem_busy(mem_busy),.mem_write_back_valid(mem_valid),.req_i(req),
    .clean_all_done(clean_done),.npu_done(npu_done),
    .clean_all_o(clean),.invalidate_all_o(invalidate_all),.npu_start(start));
  always @(posedge clk) if(start) starts=starts+1;
  // Invalidate mode accompanies the entire clean request, never completion only.
  always @(negedge clk) begin
    #1; // Let reset and combinational outputs settle before sampling.
    if (invalidate_all !== clean)
      $fatal(1,"invalidate mode must follow the clean request");
    if (!rst_n && invalidate_all)
      $fatal(1,"invalidate mode active during reset");
  end
  task step;
    begin @(posedge clk); #1; end
  endtask
  task finish_operation;
    begin
      repeat(4) begin step; if(!clean || start) $fatal(1,"clean request dropped"); end
      @(negedge clk);clean_done=1;
      step; if(clean || !start) $fatal(1,"missing start after clean");
      @(negedge clk);clean_done=0;
      step; if(clean || start) $fatal(1,"start longer than one cycle");
      // Busy instruction decode must not retrigger while the NPU is running.
      @(negedge clk);is_npu=1;
      repeat(4) begin step;if(clean || start) $fatal(1,"retrigger while busy");end
      @(negedge clk);is_npu=0;npu_done=1;
      step;
      @(negedge clk);npu_done=0;
      step;if(clean || start) $fatal(1,"not idle after completion");
    end
  endtask
  initial begin
    step; @(negedge clk);rst_n=1;
    // Idle MEM: no writeback-valid pulse will ever occur.
    is_npu=1;step;
    @(negedge clk);is_npu=0;
    step;if(!clean) $fatal(1,"idle MEM waited for a completion pulse");
    finish_operation;
    // Drain an outstanding memory request, including same-cycle dispatch.
    @(negedge clk);is_npu=1;req=1;mem_busy=1;
    step;@(negedge clk);is_npu=0;
    repeat(3) begin step;if(clean || start) $fatal(1,"did not wait for MEM");end
    @(negedge clk);mem_valid=1;
    step;if(clean) $fatal(1,"completion pulse while busy is not drained");
    @(negedge clk);mem_busy=0;mem_valid=0;
    step;if(clean) $fatal(1,"ignored current dispatch request");
    @(negedge clk);req=0;
    step;if(!clean) $fatal(1,"failed to clean after drain");
    finish_operation;
    if(starts!=2) $fatal(1,"expected exactly two starts, got %0d",starts);
    // Reset aborts an in-progress clean without starting the NPU.
    @(negedge clk);is_npu=1;step;
    @(negedge clk);is_npu=0;step;
    if(!clean) $fatal(1,"expected clean before reset");
    @(negedge clk);rst_n=0;#1;
    if(clean || start) $fatal(1,"outputs active during reset");
    step;@(negedge clk);rst_n=1;
    step;if(clean || start) $fatal(1,"not idle after reset");
    $display("PASS clean_cache: idle/busy MEM, held request, single start, completion, reset");
    $finish;
  end
  initial begin #10000;$fatal(1,"timeout");end
endmodule
