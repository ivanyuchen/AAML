`timescale 1ns/1ps
module backend_coherence_tb;
  reg clk=0,rst_n=0;
  always #5 clk=~clk;
  reg [31:0] rom[0:255];
  reg [255:0] memory[0:4095];
  reg [7:0] pc=0;
  wire pop;
  wire [31:0] mem_addr,rs1,rs2,f7;
  wire [3:0] f3;
  wire rm_vld,wm_vld,npu_start;
  wire [255:0] wm_data;
  reg [255:0] rm_data=0;
  reg rm_done=0,wm_done=0,npu_done=0;
  integer rdelay=0,wdelay=0,ndelay=0,operations=0,checks=0,flushes=0;
  reg [31:0] raddr,waddr;
  reg [255:0] wdata;
  reg [31:0] cfg_a,cfg_b,cfg_c;
  Backend_top dut(.clk(clk),.rst_n(rst_n),.inst_rdy_i(1'b1),
    .inst_pc_i(32'h60000000+{22'd0,pc,2'b00}),.inst_i(rom[pc]),
    .inst_pred_taken_i(1'b0),.req_inst_o(pop),.invalid_complete_i(1'b1),
    .dbus_rm_addr(mem_addr),.dbus_rm_rdy(1'b1),.dbus_rm_data(rm_data),
    .dbus_rm_success(1'b1),.dbus_rm_complete(rm_done),.dbus_rm_vld(rm_vld),
    .dbus_wm_rdy(1'b1),.dbus_wm_data(wm_data),.dbus_wm_vld(wm_vld),
    .dbus_wm_success(1'b1),.dbus_wm_complete(wm_done),
    .m_axi_lite_awready(1'b1),.m_axi_lite_wready(1'b1),
    .m_axi_lite_bvalid(1'b0),.m_axi_lite_bresp(2'b00),
    .m_axi_lite_arready(1'b1),.m_axi_lite_rvalid(1'b0),
    .m_axi_lite_rdata(32'd0),.m_axi_lite_rresp(2'b00),
    .rs1_o(rs1),.rs2_o(rs2),.funct3_o(f3),.funct7_o(f7),
    .NPU_start(npu_start),.NPU_done(npu_done),.NPU_out(32'd0));
  always @(posedge clk) begin
    if(rst_n && pop)pc<=pc+1;
    rm_done<=0;wm_done<=0;npu_done<=0;
    if(rm_vld)begin rdelay<=5;raddr<=mem_addr;end
    else if(rdelay!=0)begin
      rdelay<=rdelay-1;
      if(rdelay==1)begin rm_data<=memory[raddr[16:5]];rm_done<=1;end
    end
    if(wm_vld)begin wdelay<=7;waddr<=mem_addr;wdata<=wm_data;end
    else if(wdelay!=0)begin
      wdelay<=wdelay-1;
      if(wdelay==1)begin memory[waddr[16:5]]<=wdata;wm_done<=1;end
    end
    if(dut.npu_clean_req && dut.u_clean_cache.state_r!=dut.u_clean_cache.CLEAN)
      $fatal(1,"bad cache ownership");
    if(dut.npu_start_after_clean)flushes<=flushes+1;
    if(ndelay!=0)begin ndelay<=ndelay-1;if(ndelay==1)npu_done<=1;end
    if(npu_start)begin
      ndelay<=4;
      if(f3==7)begin
        case(f7)
          1:begin cfg_a<=rs1;cfg_b<=rs2;end
          2:cfg_c<=rs1;
          3:if(rs1!=1 || rs2!=1)$fatal(1,"bad dims");
          0:begin
            if(dut.mem_busy || dut.mem_req || wdelay || rdelay)
              $fatal(1,"NPU started before MEM / cache drained");
            if(memory[cfg_a[16:5]][31:0] !== (operations==0 ? 32'h05000000 : 32'h07000000) ||
               memory[cfg_b[16:5]][31:0] !== 32'h03000000)
              $fatal(1,"NPU saw stale A/B");
            memory[cfg_c[16:5]][31:0] <= operations==0 ? 15 : 21;
            operations<=operations+1;
          end
          default:$fatal(1,"bad opcode");
        endcase
      end else if(f3==0 && f7==5)begin
        if(rs1 !== (checks==0 ? 15 : 21))$fatal(1,"CPU saw stale C: %0d",rs1);
        checks<=checks+1;
        if(checks==1)begin
          if(operations!=2 || flushes!=2)$fatal(1,"wrong operation / flush count");
          $display("PASS backend: real RISC-V stores/config/START/loads, dirty and clean C, no CBO");
          $finish;
        end
      end else $fatal(1,"unexpected NPU instruction");
    end
  end
  integer i;
  reg [1023:0] program_path;
  initial begin
    for(i=0;i<256;i=i+1)rom[i]=32'h00000013;
    for(i=0;i<4096;i=i+1)memory[i]=0;
    if(!$value$plusargs("PROGRAM=%s",program_path))$fatal(1,"missing PROGRAM");
    $readmemh(program_path,rom);
    repeat(4)@(negedge clk);rst_n=1;
  end
  initial begin #1000000;$fatal(1,"timeout pc=%0d checks=%0d",pc,checks);end
endmodule
