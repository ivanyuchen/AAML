`timescale 1ns/1ps
module cache_coherence_tb;
  reg clk=0,rst_n=0;
  always #5 clk=~clk;
  reg [31:0] cpu_addr=0,cpu_data=0;
  reg rd=0,wr=0;
  wire [31:0] cpu_out,mem_addr;
  wire cpu_valid,rm_vld,wm_vld,clean_req,inval,start,clean_done;
  wire [255:0] wm_data;
  reg [255:0] rm_data=0;
  reg rm_complete=0,wm_complete=0;
  reg request=0,busy=0,mem_req=0,npu_done=0,fence_req=0;
  reg [255:0] memory[0:4095];
  integer rdelay=0,wdelay=0,writes=0,starts=0;
  reg [31:0] raddr=0,waddr=0;
  reg [255:0] wdata=0;
  localparam BASE=32'h60000000;
  clean_cache control(.clk_i(clk),.rst_n(rst_n),.is_npu_i(request),
    .mem_busy(busy),.mem_write_back_valid(cpu_valid),.req_i(mem_req),
    .clean_all_done(clean_done),.npu_done(npu_done),
    .clean_all_o(clean_req),.invalidate_all_o(inval),.npu_start(start));
  dcache_pro cache(.clk(clk),.rst_n(rst_n),.cpu_daddr_i(cpu_addr),
    .cpu_data_i(cpu_data),.mask_i(4'b1111),.cpu_req_wr(wr),.cpu_req_rd(rd),
    .cpu_data_o(cpu_out),.dcache_rdy_o(),.dcache_data_vld_o(cpu_valid),
    .d_exception(),.hit_o(),.invalidate_i(1'b0),.flush_i(1'b0),
    .writeback_i(1'b0),.clean_all_i(clean_req | fence_req),.clean_done_o(clean_done),
    .invalidate_all_i(inval),.mem_addr(mem_addr),.rm_rdy(1'b1),
    .rm_data(rm_data),.rm_success(1'b1),.rm_complete(rm_complete),
    .rm_vld(rm_vld),.wm_rdy(1'b1),.wm_data(wm_data),.wm_vld(wm_vld),
    .wm_success(1'b1),.wm_complete(wm_complete));
  always @(posedge clk) begin
    rm_complete<=0;wm_complete<=0;
    if(rm_vld) begin rdelay<=3;raddr<=mem_addr;end
    else if(rdelay!=0) begin
      rdelay<=rdelay-1;
      if(rdelay==1) begin rm_data<=memory[(raddr-BASE)>>5];rm_complete<=1;end
    end
    if(wm_vld) begin wdelay<=3;waddr<=mem_addr;wdata<=wm_data;end
    else if(wdelay!=0) begin
      wdelay<=wdelay-1;
      if(wdelay==1) begin memory[(waddr-BASE)>>5]<=wdata;wm_complete<=1;writes<=writes+1;end
    end
    if(start) starts<=starts+1;
  end
  task access;
    input store;
    input [31:0] addr,value;
    integer timeout_count;
    begin
      @(negedge clk);cpu_addr=addr;cpu_data=value;wr=store;rd=!store;
      @(negedge clk);wr=0;rd=0;
      timeout_count=0;
      while(!cpu_valid && timeout_count<100) begin @(negedge clk);timeout_count=timeout_count+1;end
      if(timeout_count==100) $fatal(1,"CPU memory access timed out");
      if(!store && cpu_out!==value) $fatal(1,"load %h got %h expected %h",addr,cpu_out,value);
      repeat(2) @(negedge clk);
    end
  endtask
  task clean_start;
    integer count,i;
    begin
      @(negedge clk);request=1;
      @(negedge clk);request=0;
      count=0;
      while(!start && count<30000) begin @(negedge clk);count=count+1;end
      if(count==30000) $fatal(1,"clean timed out");
      for(i=0;i<512;i=i+1)
        if(cache.way0.vld_arr.ram[i] || cache.way1.vld_arr.ram[i])
          $fatal(1,"valid bit not cleared in set %0d",i);
      if(rdelay || wdelay) $fatal(1,"NPU started with memory transfer pending");
      @(negedge clk);
      if(start) $fatal(1,"start not one cycle");
    end
  endtask
  task finish_npu;
    begin
      @(negedge clk);npu_done=1;
      @(negedge clk);npu_done=0;
      repeat(2) @(negedge clk);
    end
  endtask
  integer i;
  initial begin
    for(i=0;i<4096;i=i+1) memory[i]=0;
    repeat(3) @(negedge clk);rst_n=1;
    // Two dirty ways in the same set; plus last set and shared-line sentinel.
    access(1,BASE,32'h11223344);
    access(1,BASE+32'h4000,32'h55667788);
    access(1,BASE+32'h3fe0,32'h1234abcd);
    access(1,BASE+32'h40,32'hdeadbeef);
    access(1,BASE+32'h44,32'h76543210);
    clean_start;
    if(memory[0][31:0]!==32'h11223344 || memory[512][31:0]!==32'h55667788 ||
       memory[511][31:0]!==32'h1234abcd || memory[2][63:32]!==32'h76543210)
      $fatal(1,"dirty writeback / neighbour preservation failed");
    memory[2][31:0]=32'hbaadf00d; // NPU writes C directly to DDR.
    finish_npu;
    access(0,BASE+32'h40,32'hbaadf00d);
    access(0,BASE+32'h44,32'h76543210);
    // C is now clean and cached. It must be invalidated on the next operation.
    clean_start;
    memory[2][31:0]=32'h89abcdef;
    finish_npu;
    access(0,BASE+32'h40,32'h89abcdef);
    // Force eviction: an older dirty C must never overwrite the new result.
    access(1,BASE+32'h4040,32'h00000011);
    access(1,BASE+32'h8040,32'h00000022);
    clean_start;
    if(memory[2][31:0]!==32'h89abcdef) $fatal(1,"stale C overwrote NPU result");
    finish_npu;
    if(starts!=3) $fatal(1,"wrong start count");
    // fence.i uses the same walker without invalidate mode.
    access(1,BASE+32'h80,32'h10203040);
    @(negedge clk);fence_req=1;
    wait(clean_done);
    @(negedge clk);fence_req=0;
    if(!(cache.way0.vld_arr.ram[4] || cache.way1.vld_arr.ram[4]))
      $fatal(1,"writeback-only walk invalidated a line");
    if(memory[4][31:0]!==32'h10203040) $fatal(1,"fence writeback failed");
    $display("PASS coherence: two dirty ways, final set, dirty/clean C, neighbours, eviction, fence writeback-only");
    $finish;
  end
  initial begin #2000000;$fatal(1,"global timeout");end
endmodule
