`timescale 1ns/1ps
module npu_gemv_tb;
  reg clk=0, rst_n=0, go=0;
  always #5 clk=~clk;
  reg [31:0] rs1=0,rs2=0,f7=0;
  wire [31:0] result,araddr;
  wire done,arvalid,rready,awvalid,wvalid;
  wire [31:0] awaddr,wdata;
  wire [7:0] awlen;
  wire [3:0] wstrb;
  wire wlast,bready;
  reg bvalid=0;
  reg [31:0] write_addr=0;
  integer write_left=0,writes=0;
  reg signed [31:0] results[0:253];
  integer expected_writes=0;
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
    .M_AXI_RREADY(rready),.M_AXI_AWREADY(arready),.M_AXI_WREADY(tick%5!=0),
    .M_AXI_BRESP(2'd0),.M_AXI_BVALID(bvalid),
    .M_AXI_AWVALID(awvalid),.M_AXI_WVALID(wvalid),.M_AXI_AWADDR(awaddr),
    .M_AXI_AWLEN(awlen),.M_AXI_WDATA(wdata),.M_AXI_WSTRB(wstrb),
    .M_AXI_WLAST(wlast),.M_AXI_BREADY(bready));
  always @(posedge clk) begin
    if (!rst_n) begin bvalid<=0;write_left<=0;writes<=0;end
    else begin
      if(bvalid && bready) bvalid<=0;
      if(awvalid && arready) begin write_addr<=awaddr;write_left<=awlen+1;end
      if(wvalid && tick%5!=0) begin
        if(write_left==0 || wstrb!=15 || wlast!=(write_left==1))
          $fatal(1,"bad AXI write protocol");
        if(write_addr<32'h8ffc || write_addr>=32'h8ffc+expected_writes*4)
          $fatal(1,"C write outside M results");
        results[(write_addr-32'h8ffc)/4]<=wdata;
        write_addr<=write_addr+4;write_left<=write_left-1;writes<=writes+1;
        if(wlast) bvalid<=1;
      end
    end
  end
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
    integer count,i,j,timeout_count,sum;
    reg signed [7:0] a,b;
    reg [31:0] packed_a,packed_b;
    begin
      @(negedge clk);rst_n=0;go=0;
      repeat(3) @(negedge clk);
      rst_n=1; expected_writes=m; inject_a=(err==1);inject_b=(err==2);
      command(1,32'h0ffc,32'h4ffc); // cross 4KB edges in each buffer
      command(2,32'h8ffc,0);
      command(3,m,k);
      @(negedge clk);f7=0;rs1=0;rs2=0;go=1;
      timeout_count=0;
      while (!done && timeout_count<20000) begin
        @(negedge clk);timeout_count=timeout_count+1;
      end
      if(timeout_count==20000) $fatal(1,"timeout");
      count=((m+3)/4)*k;
      if(err!=0) begin
        if(!done || result!=1 || pulses!=0 || dut.tpu_in_valid)
          $fatal(1,"bad error handling");
      end else begin
        if(result!=0 || reads!=count+k || writes!=m || pulses!=1)
          $fatal(1,"bad completion status or transfer count");
        for(i=0;i<m;i=i+1) begin
          sum=0;
          for(j=0;j<k;j=j+1) begin
            packed_a=(32'h0ffc+((i/4)*k+j)*4)^32'h93a57c21;
            packed_b=(32'h4ffc+j*4)^32'h93a57c21;
            a=packed_a >> (24-8*(i%4)); b=packed_b[31:24];
            sum=sum+a*b;
          end
          if(results[i]!==sum) $fatal(1,"C[%0d] got %0d expected %0d",i,results[i],sum);
        end
      end
      $display("PASS GEMV AXI M=%0d K=%0d error=%0d",m,k,err);
    end
  endtask
  initial begin
    check_load(1,1,0);
    check_load(5,5,0);
    check_load(254,1,0);
    check_load(16,254,0);
    check_load(254,16,0);
    check_load(64,64,0); // maximum 1024 A words
    check_load(5,5,1);
    check_load(5,5,2);
    $display("All GEMV load/compute/store tests passed.");
    $finish;
  end
  initial begin #3000000;$fatal(1,"global timeout");end
endmodule
