`timescale 1ns/1ps
module npu_read_ab_tb;
  reg clk=0, rst_n=0, go=0;
  always #5 clk=~clk;
  reg [31:0] rs1=0,rs2=0,f7=0;
  wire [31:0] result,araddr;
  wire done,arvalid,rready,awvalid,wvalid;
  wire [7:0] arlen;
  integer tick=0,remain=0,reads=0,pulses=0;
  reg [31:0] addr=0;
  reg [1:0] response=0;
  reg inject_a=0,inject_b=0;
  wire arready=(tick%3!=0);
  wire rvalid=(remain!=0)&&(tick%4!=0);
  wire [31:0] data=addr ^ 32'h93a57c21;
  NPU dut(.clk(clk),.rst_n(rst_n),.rs1_i(rs1),.rs2_i(rs2),
    .funct3_i(4'd7),.funct7_i(f7),.NPU_start(go),.NPU_done(done),.NPU_out(result),
    .M_AXI_ARADDR(araddr),.M_AXI_ARLEN(arlen),.M_AXI_ARVALID(arvalid),
    .M_AXI_ARREADY(arready),.M_AXI_RID(4'd0),.M_AXI_RDATA(data),
    .M_AXI_RRESP(response),.M_AXI_RLAST(remain==1),.M_AXI_RVALID(rvalid),
    .M_AXI_RREADY(rready),.M_AXI_AWREADY(1'b0),.M_AXI_WREADY(1'b0),
    .M_AXI_BRESP(2'd0),.M_AXI_BVALID(1'b0),
    .M_AXI_AWVALID(awvalid),.M_AXI_WVALID(wvalid));
  always @(posedge clk) begin
    tick<=tick+1;
    if (!rst_n) begin remain<=0; reads<=0; pulses<=0; end
    else begin
      if (dut.tpu_in_valid) pulses<=pulses+1;
      if (arvalid && arready) begin
        if (remain!=0) $fatal(1,"overlapping bursts");
        if (arlen>15 || {1'b0,araddr[11:0]}+(arlen+1)*4>4096)
          $fatal(1,"burst limit / 4KB boundary");
        addr<=araddr; remain<=arlen+1;
        response<=((inject_a && araddr<32'h4000) ||
                   (inject_b && araddr>=32'h4000)) ? 2'b10 : 2'b00;
      end
      if (rvalid && rready) begin
        remain<=remain-1; addr<=addr+4; reads<=reads+1;
      end
    end
  end
  task command;
    input [31:0] field,a,b;
    begin
      @(negedge clk); f7=field;rs1=a;rs2=b;go=1;
      wait(done); @(negedge clk);go=0;
      repeat(2) @(negedge clk);
    end
  endtask
  task check_load;
    input integer m,k,err;
    integer count,i,timeout_count;
    begin
      @(negedge clk);rst_n=0;go=0;
      repeat(3) @(negedge clk);
      rst_n=1; inject_a=(err==1);inject_b=(err==2);
      command(1,32'h0ffc,32'h4ffc); // cross 4KB edges in each buffer
      command(2,32'h8ffc,0);
      command(3,m,k);
      @(negedge clk);f7=0;rs1=0;rs2=0;go=1;
      timeout_count=0;
      while (!dut.tpu_in_valid && !done && timeout_count<20000) begin
        @(negedge clk);timeout_count=timeout_count+1;
      end
      if(timeout_count==20000) $fatal(1,"timeout");
      count=((m+3)/4)*k;
      if(err!=0) begin
        if(!done || result!=1 || pulses!=0 || dut.tpu_in_valid)
          $fatal(1,"bad error handling");
      end else begin
        if(done || dut.state_r!=dut.S_TPU_WORK || reads!=count+k)
          $fatal(1,"premature completion / wrong load length");
        for(i=0;i<count;i=i+1)
          if(dut.u_buf_a.RAM[i]!==((32'h0ffc+i*4)^32'h93a57c21))
            $fatal(1,"A mismatch index %0d",i);
        for(i=0;i<k;i=i+1)
          if(dut.u_buf_b.RAM[i]!==((32'h4ffc+i*4)^32'h93a57c21))
            $fatal(1,"B mismatch index %0d",i);
        repeat(4) @(negedge clk);
        if(pulses!=1 || dut.tpu_in_valid) $fatal(1,"start must pulse once");
      end
      $display("PASS read AB M=%0d K=%0d error=%0d",m,k,err);
    end
  endtask
  initial begin
    check_load(1,1,0);
    check_load(5,5,0);
    check_load(254,1,0);
    check_load(16,254,0);
    check_load(64,64,0); // maximum 1024 A words
    check_load(5,5,1);
    check_load(5,5,2);
    $display("All AB load tests passed (write channel held off in this test).");
    $finish;
  end
  initial begin #3000000;$fatal(1,"global timeout");end
endmodule
