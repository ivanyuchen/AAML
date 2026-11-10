`timescale 1ns / 1ps
//==============================================================================
// NPU: CUSTOM-0 coprocessor of the TinyRISC-V CPU.
//
// Hierarchy
//   NPU
//   +-- u_decode     NPU_decode     funct3 / funct7 -> one-hot op flags
//   +-- u_axi        NPU_axi        the only AXI4 master (burst read / write)
//   +-- u_buf_a      bram_sdp       Conv ptr1 buffer  /  Transpose src_buf
//   +-- u_buf_b      bram_sdp       Conv ptr2 buffer  /  Transpose dst_buf
//   +-- u_transpose  Transpose      permute engine (src_buf -> dst_buf)
//   +-- u_logistic   Logistic       int8 sigmoid pipeline
//   +-- u_mac4_simd  NPU_mac4_simd  Lab1 MAC
//   +-- u_mac4_lanes NPU_mac4_lanes Lab2 (Conv) MAC
//
// Buffer sharing: only one instruction runs at a time, so Conv and Transpose
// never use buf_a / buf_b together. A Transpose overwrites whatever Conv had
// loaded (Conv always reloads with LOAD_PTR1/2 before COMPUTE).
//
//==============================================================================
// CUSTOM-0 instruction allocation (opcode 0x0B, funct3_i selects the op)
//
// Protocol for every op: CPU issues the instruction -> NPU_start -> NPU
// works (multicycle allowed) -> NPU_done=1 only when NPU_out is valid.
// The CPU stalls until NPU_done. funct7_i is a sub-function field.
//
// funct3  funct7  Name            Owner     rs1 / rs2 / NPU_out
// ------  ------  --------------  --------  ------------------------------
//  0      0       MAC_CLEAR       Lab1      NPU_out = 0, acc = 0
//  0      1       MAC_SET_OFFSET  Lab1      rs1 = input offset
//  0      2       MAC_ACC4        Lab1      acc += sum_{4 bytes}
//                                           (rs1.byte + offset) * rs2.byte
//                                           NPU_out = acc
//  0      other   COMPUTE         platform  stock example: rs1+rs2+funct7
//  1      -       AXI_READ        Lab1      single read, rs1 = addr
//                                           (misaligned ok), NPU_out = data
//  2      -       AXI_WRITE       Lab1      single write, rs1 = addr,
//                                           rs2 = data (misaligned ok,
//                                           uses WSTRB), done after B resp
//  3      0       MAC_CONFIG      Lab2      KEEP (Conv uses hw_simd_mac).
//                                           rs1 = N, rs2 = input_offset
//  3      1       MAC_LOAD_PTR1   Lab2      rs1 = ptr1. Burst-reads N bytes
//                                           into buf_a. NPU_out unchanged
//  3      2       MAC_LOAD_PTR2   Lab2      rs1 = ptr2. Burst-reads N bytes
//                                           into buf_b. NPU_out unchanged
//  3      3       MAC_COMPUTE     Lab2      no read. NPU_out = sum over N of
//                                           (buf_a[i] + off) * buf_b[i]
//                                           (needs CONFIG, PTR1, PTR2 first)
//  4      -       LOGISTIC        Lab4      sigmoid of one element.
//                                           rs1 = signed Q4.27 raw input
//                                           NPU_out = Q0.31 raw result
//  5      0..3    TRANSPOSE_CFG   Lab4      write a config register:
//                                             0: rs1 = src base addr
//                                                rs2 = dst base addr
//                                             1: rs1 = rank (1..6)
//                                                rs2 = total bytes
//                                             2: rs1 = dim d
//                                                rs2 = output_shape[d]
//                                             3: rs1 = dim d
//                                                rs2 = input_stride[perm[d]]
//                                                      (in BYTES)
//                                           dim 0 = outermost. NPU_out = 0
//  6      -       TRANSPOSE_START Lab4      load src -> permute -> store dst.
//                                           NPU_done after the last write
//                                           response. NPU_out:
//                                             0 ok
//                                             1 AXI error response
//                                             2 bad config (base addr not
//                                               word aligned or total bytes
//                                               > TR_BUF_BYTES)
//  7      -       (free)                    spare
//
// Rules:
//  - Do not change funct3 = 0/1/2 (Lab1) or 3 (Lab2): Lab4 spec says
//    preserve the Lab1/Lab2 instructions (Conv uses funct3 = 3).
//  - funct3_i is 4 bits wide but the instruction carries only 3.
//  - Transpose: CPU never touches tensor data; it only does cfg writes,
//    start, wait, and the cache clean/invalidate around the call.
//==============================================================================
module NPU (
    input clk,
    input rst_n,

    // CPU Interface //
    input      [31:0] rs1_i,
    input      [31:0] rs2_i,
    output reg [31:0] NPU_out,
    input             NPU_start,
    output reg        NPU_done,

    input [ 3:0] funct3_i,
    input [31:0] funct7_i,

    // AXI4 Master Interface (M_AXI) //
    // AW Channel
    output [31:0] M_AXI_AWADDR,
    output [ 7:0] M_AXI_AWLEN,
    output [ 2:0] M_AXI_AWSIZE,
    output [ 1:0] M_AXI_AWBURST,
    output        M_AXI_AWLOCK,
    output [ 3:0] M_AXI_AWCACHE,
    output [ 2:0] M_AXI_AWPROT,
    output [ 3:0] M_AXI_AWQOS,
    output [15:0] M_AXI_AWUSER,
    output        M_AXI_AWVALID,
    input         M_AXI_AWREADY,
    // W Channel
    output [31:0] M_AXI_WDATA,
    output [ 3:0] M_AXI_WSTRB,
    output        M_AXI_WLAST,
    output        M_AXI_WVALID,
    input         M_AXI_WREADY,
    // B Channel
    input  [ 1:0] M_AXI_BRESP,
    input         M_AXI_BVALID,
    output        M_AXI_BREADY,
    // AR Channel
    output [31:0] M_AXI_ARADDR,
    output [ 7:0] M_AXI_ARLEN,
    output [ 2:0] M_AXI_ARSIZE,
    output [ 1:0] M_AXI_ARBURST,
    output        M_AXI_ARLOCK,
    output [ 3:0] M_AXI_ARCACHE,
    output [ 2:0] M_AXI_ARPROT,
    output [ 3:0] M_AXI_ARQOS,
    output [15:0] M_AXI_ARUSER,
    output        M_AXI_ARVALID,
    input         M_AXI_ARREADY,
    // R Channel
    input  [ 3:0] M_AXI_RID,
    input  [31:0] M_AXI_RDATA,
    input  [ 1:0] M_AXI_RRESP,
    input         M_AXI_RLAST,
    input         M_AXI_RVALID,
    output        M_AXI_RREADY
);

  localparam TR_BUF_BYTES = 16384;  // largest MobileViT transpose = 16KB
  localparam BUF_WORDS = TR_BUF_BYTES / 4;
  localparam IDX_W = $clog2(BUF_WORDS);

  //============================================================================
  // FSM states
  //============================================================================
  localparam S_IDLE = 4'd0;
  localparam S_DONE = 4'd1;
  localparam S_ADD = 4'd2;  // funct3=0 (other funct7) stock add
  localparam S_L1_COMP = 4'd3;  // funct3=0 Lab1 MAC
  localparam S_L1_AXI = 4'd4;  // funct3=1/2 waiting for NPU_axi
  localparam S_CONV_LOAD = 4'd5;  // funct3=3 LOAD_PTR1/2 waiting for NPU_axi
  localparam S_CONV_COMP = 4'd6;  // funct3=3 COMPUTE
  localparam S_LOGISTIC = 4'd7;  // funct3=4
  localparam S_TR_LOAD = 4'd8;  // funct3=6 DDR -> buf_a
  localparam S_TR_PERM = 4'd9;  //          buf_a -> buf_b
  localparam S_TR_STORE = 4'd10;  //          buf_b -> DDR
  localparam S_L1_ACC = 4'd11;  // funct3=0 MAC_ACC4: acc += registered mac_sum
  localparam S_L1_SUM = 4'd12;  // funct3=0 MAC_ACC4: products -> mac_sum_r

  reg [3:0] state_r, next_state;

  wire start_op = (state_r == S_IDLE) && NPU_start;

  //============================================================================
  // Decode (the op flags are valid while the CPU holds the instruction)
  //============================================================================
  wire op_mac_clear, op_mac_set_offset, op_mac_acc4, op_add;
  wire op_axi_read, op_axi_write;
  wire op_conv_config, op_conv_load_ptr1, op_conv_load_ptr2, op_conv_compute;
  wire op_logistic, op_tr_cfg, op_tr_start;

  NPU_decode u_decode (
      .funct3_i         (funct3_i),
      .funct7_i         (funct7_i),
      .op_mac_clear     (op_mac_clear),
      .op_mac_set_offset(op_mac_set_offset),
      .op_mac_acc4      (op_mac_acc4),
      .op_add           (op_add),
      .op_axi_read      (op_axi_read),
      .op_axi_write     (op_axi_write),
      .op_conv_config   (op_conv_config),
      .op_conv_load_ptr1(op_conv_load_ptr1),
      .op_conv_load_ptr2(op_conv_load_ptr2),
      .op_conv_compute  (op_conv_compute),
      .op_logistic      (op_logistic),
      .op_tr_cfg        (op_tr_cfg),
      .op_tr_start      (op_tr_start)
  );

  //============================================================================
  // Sub-module wires
  //============================================================================
  // NPU_axi
  reg              axi_cmd_start;
  reg              axi_cmd_write;
  reg  [     31:0] axi_cmd_addr;
  reg  [  IDX_W:0] axi_cmd_beats;
  reg  [      3:0] axi_cmd_first_wstrb;
  reg  [      3:0] axi_cmd_last_wstrb;
  wire             axi_cmd_done;
  wire             axi_cmd_err;
  wire             axi_rd_valid;
  wire [IDX_W-1:0] axi_rd_idx;
  wire [     31:0] axi_rd_word;
  wire [IDX_W-1:0] axi_wr_idx;
  reg  [     31:0] axi_wr_word;

  // buf_a / buf_b
  reg              buf_a_we;
  reg  [IDX_W-1:0] buf_a_wr_idx;
  reg  [     31:0] buf_a_wr_word;
  reg  [IDX_W-1:0] buf_a_rd_idx;
  wire [     31:0] buf_a_rd_word;
  reg              buf_b_we;
  reg  [IDX_W-1:0] buf_b_wr_idx;
  reg  [     31:0] buf_b_wr_word;
  reg  [IDX_W-1:0] buf_b_rd_idx;
  wire [     31:0] buf_b_rd_word;

  // Transpose
  wire [     31:0] tr_src_base_addr;
  wire [     31:0] tr_dst_base_addr;
  wire [     31:0] tr_total_bytes;
  reg              tr_permute_start;
  wire             tr_permute_done;
  wire [IDX_W-1:0] tr_src_rd_idx;
  wire             tr_dst_wr_en;
  wire [IDX_W-1:0] tr_dst_wr_idx;
  wire [     31:0] tr_dst_wr_word;

  //============================================================================
  // Sub-modules
  //============================================================================
  NPU_axi #(
      .IDX_W    (IDX_W),
      .MAX_BURST(16)
  ) u_axi (
      .clk            (clk),
      .rst_n          (rst_n),
      .cmd_start      (axi_cmd_start),
      .cmd_write      (axi_cmd_write),
      .cmd_addr       (axi_cmd_addr),
      .cmd_beats      (axi_cmd_beats),
      .cmd_first_wstrb(axi_cmd_first_wstrb),
      .cmd_last_wstrb (axi_cmd_last_wstrb),
      .cmd_done       (axi_cmd_done),
      .cmd_err        (axi_cmd_err),
      .rd_valid       (axi_rd_valid),
      .rd_idx         (axi_rd_idx),
      .rd_word        (axi_rd_word),
      .wr_idx         (axi_wr_idx),
      .wr_word        (axi_wr_word),
      .M_AXI_AWADDR   (M_AXI_AWADDR),
      .M_AXI_AWLEN    (M_AXI_AWLEN),
      .M_AXI_AWSIZE   (M_AXI_AWSIZE),
      .M_AXI_AWBURST  (M_AXI_AWBURST),
      .M_AXI_AWLOCK   (M_AXI_AWLOCK),
      .M_AXI_AWCACHE  (M_AXI_AWCACHE),
      .M_AXI_AWPROT   (M_AXI_AWPROT),
      .M_AXI_AWQOS    (M_AXI_AWQOS),
      .M_AXI_AWUSER   (M_AXI_AWUSER),
      .M_AXI_AWVALID  (M_AXI_AWVALID),
      .M_AXI_AWREADY  (M_AXI_AWREADY),
      .M_AXI_WDATA    (M_AXI_WDATA),
      .M_AXI_WSTRB    (M_AXI_WSTRB),
      .M_AXI_WLAST    (M_AXI_WLAST),
      .M_AXI_WVALID   (M_AXI_WVALID),
      .M_AXI_WREADY   (M_AXI_WREADY),
      .M_AXI_BRESP    (M_AXI_BRESP),
      .M_AXI_BVALID   (M_AXI_BVALID),
      .M_AXI_BREADY   (M_AXI_BREADY),
      .M_AXI_ARADDR   (M_AXI_ARADDR),
      .M_AXI_ARLEN    (M_AXI_ARLEN),
      .M_AXI_ARSIZE   (M_AXI_ARSIZE),
      .M_AXI_ARBURST  (M_AXI_ARBURST),
      .M_AXI_ARLOCK   (M_AXI_ARLOCK),
      .M_AXI_ARCACHE  (M_AXI_ARCACHE),
      .M_AXI_ARPROT   (M_AXI_ARPROT),
      .M_AXI_ARQOS    (M_AXI_ARQOS),
      .M_AXI_ARUSER   (M_AXI_ARUSER),
      .M_AXI_ARVALID  (M_AXI_ARVALID),
      .M_AXI_ARREADY  (M_AXI_ARREADY),
      .M_AXI_RDATA    (M_AXI_RDATA),
      .M_AXI_RRESP    (M_AXI_RRESP),
      .M_AXI_RLAST    (M_AXI_RLAST),
      .M_AXI_RVALID   (M_AXI_RVALID),
      .M_AXI_RREADY   (M_AXI_RREADY)
  );

  bram_sdp #(
      .ENTRY_NUM(BUF_WORDS),
      .DWIDTH   (32)
  ) u_buf_a (
      .clk_i       (clk),
      .we_i        (buf_a_we),
      .read_addr_i (buf_a_rd_idx),
      .write_addr_i(buf_a_wr_idx),
      .data_i      (buf_a_wr_word),
      .data_o      (buf_a_rd_word)
  );

  bram_sdp #(
      .ENTRY_NUM(BUF_WORDS),
      .DWIDTH   (32)
  ) u_buf_b (
      .clk_i       (clk),
      .we_i        (buf_b_we),
      .read_addr_i (buf_b_rd_idx),
      .write_addr_i(buf_b_wr_idx),
      .data_i      (buf_b_wr_word),
      .data_o      (buf_b_rd_word)
  );

  Transpose #(
      .BUF_BYTES(TR_BUF_BYTES)
  ) u_transpose (
      .clk_i        (clk),
      .rst_n        (rst_n),
      .cfg_wr_en    (start_op && op_tr_cfg),
      .cfg_field    (funct7_i[2:0]),
      .cfg_rs1      (rs1_i),
      .cfg_rs2      (rs2_i),
      .src_base_addr(tr_src_base_addr),
      .dst_base_addr(tr_dst_base_addr),
      .total_bytes  (tr_total_bytes),
      .permute_start(tr_permute_start),
      .permute_done (tr_permute_done),
      .src_rd_idx   (tr_src_rd_idx),
      .src_rd_word  (buf_a_rd_word),
      .dst_wr_en    (tr_dst_wr_en),
      .dst_wr_idx   (tr_dst_wr_idx),
      .dst_wr_word  (tr_dst_wr_word)
  );

  wire        logistic_done;
  wire [31:0] logistic_result;
  NewLogistic u_logistic (
      .clk    (clk),
      .rst_n  (rst_n),
      .start  (start_op && op_logistic),
      .input_a(rs1_i),
      .done   (logistic_done),
      .result (logistic_result)
  );

  //============================================================================
  // Lab1: MAC + single AXI read / write
  //============================================================================
  // MAC_ACC4 is pipelined (one cycle was too long at 81 MHz):
  //   start: rs1/rs2 registered -> S_L1_COMP: 4 products registered
  //   -> S_L1_SUM: adder tree into mac_sum_r -> S_L1_ACC: acc += mac_sum_r
  reg signed  [31:0] acc_r;
  reg signed  [31:0] offset;
  reg         [31:0] l1_a_bytes;
  reg         [31:0] l1_b_bytes;
  reg signed  [31:0] mac_sum_r;
  wire signed [31:0] mac_sum;
  NPU_mac4_simd u_mac4_simd (
      .clk    (clk),
      .offset (offset),
      .a_bytes(l1_a_bytes),
      .b_bytes(l1_b_bytes),
      .sum    (mac_sum)
  );

  // A misaligned access touches two words: done as a 2-beat burst.
  wire [1:0] l1_byte_off = rs1_i[1:0];
  wire l1_misaligned = (l1_byte_off != 2'b00);
  wire [4:0] l1_shift = {l1_byte_off, 3'b000};
  wire [31:0] l1_wdata0 = rs2_i << l1_shift;
  wire [31:0] l1_wdata1 = rs2_i >> (6'd32 - l1_shift);
  wire [3:0] l1_wstrb0 = l1_misaligned ? (4'b1111 << l1_byte_off) : 4'b1111;
  wire [3:0] l1_wstrb1 = l1_misaligned ? (4'b1111 >> (3'd4 - l1_byte_off)) : 4'b1111;

  //============================================================================
  // Lab2 (Conv): N bytes in buf_a (ptr1) / buf_b (ptr2), 4 lanes per cycle
  //
  // Each buffer holds the words starting at ptrX & ~3, so lane group g needs
  // bytes [s + 4g, s + 4g + 3] (s = ptrX[1:0]) = words g and g+1.
  // COMPUTE reads word j = 0, 1, 2, ... and, once word j arrives, combines it
  // with word j-1 to form group j-1. Groups past N are masked by the lanes.
  //============================================================================
  reg [8:0] N;
  reg signed [8:0] input_offset;
  reg [1:0] ptr1_byte_off;
  reg [1:0] ptr2_byte_off;
  reg [IDX_W-1:0] conv_rd_idx;  // word being requested
  reg conv_rd_valid;  // buf_X_rd_word holds word conv_data_idx
  reg [IDX_W-1:0] conv_data_idx;
  reg [31:0] ptr1_prev_word;
  reg [31:0] ptr2_prev_word;
  reg signed [31:0] accum;

  wire [7:0] conv_groups = (N + 9'd3) >> 2;  // ceil(N / 4)
  wire [63:0] ptr1_pair = {buf_a_rd_word, ptr1_prev_word};
  wire [63:0] ptr2_pair = {buf_b_rd_word, ptr2_prev_word};
  wire [31:0] lane_in_bytes = ptr1_pair >> {ptr1_byte_off, 3'b000};
  wire [31:0] lane_flt_bytes = ptr2_pair >> {ptr2_byte_off, 3'b000};
  wire [IDX_W-1:0] conv_group = conv_data_idx - 1'b1;
  wire conv_group_valid = conv_rd_valid && (conv_data_idx != 0) && (conv_data_idx <= conv_groups);
  wire conv_last_group = (conv_data_idx == conv_groups);

  // COMPUTE pipeline (BRAM -> MAC -> accumulate is too long for one cycle):
  //   P1: aligned lane bytes of one group      P2: 4-lane MAC sum
  //   then accum += P2 sum
  reg p1_valid;
  reg p1_last;
  reg [31:0] p1_in_bytes;
  reg [31:0] p1_flt_bytes;
  reg [31:0] p1_group_byte;
  reg p2_valid;
  reg p2_last;
  reg signed [31:0] p2_sum;
  wire signed [31:0] compute_sum;

  NPU_mac4_lanes u_mac4_lanes (
      .input_offset(input_offset),
      .in_bytes    (p1_in_bytes),
      .flt_bytes   (p1_flt_bytes),
      .ptr1_byte   (p1_group_byte),
      .ptr1_end    ({23'd0, N} - 1'b1),
      .ptr2_byte   (p1_group_byte),
      .ptr2_end    ({23'd0, N} - 1'b1),
      .sum         (compute_sum)
  );

  reg conv_load_ptr2;  // LOAD target: 0 = buf_a (ptr1), 1 = buf_b (ptr2)

  //============================================================================
  // Transpose START checks
  //============================================================================
  wire [IDX_W:0] tr_beats = (tr_total_bytes + 32'd3) >> 2;
  wire [1:0] tr_tail = tr_total_bytes[1:0];
  wire [3:0] tr_last_wstrb = (tr_tail == 2'd0) ? 4'b1111 : (4'b1111 >> (3'd4 - tr_tail));
  wire tr_bad_cfg = (tr_src_base_addr[1:0] != 2'b00) || (tr_dst_base_addr[1:0] != 2'b00) ||
                    (tr_total_bytes > TR_BUF_BYTES);

  //============================================================================
  // Buffer port muxes (selected by state; only one user at a time)
  //============================================================================
  always @(*) begin
    // buf_a: AXI fills it (Conv ptr1 / Transpose src), Conv or Transpose reads
    buf_a_we      = axi_rd_valid && ((state_r == S_CONV_LOAD && !conv_load_ptr2) ||
                                     state_r == S_TR_LOAD);
    buf_a_wr_idx = axi_rd_idx;
    buf_a_wr_word = axi_rd_word;
    buf_a_rd_idx = (state_r == S_TR_PERM) ? tr_src_rd_idx : conv_rd_idx;

    // buf_b: AXI fills it (Conv ptr2) or Transpose writes it (dst);
    //        Conv reads it, or AXI streams it out (Transpose STORE)
    if (state_r == S_TR_PERM) begin
      buf_b_we      = tr_dst_wr_en;
      buf_b_wr_idx  = tr_dst_wr_idx;
      buf_b_wr_word = tr_dst_wr_word;
    end else begin
      buf_b_we      = axi_rd_valid && state_r == S_CONV_LOAD && conv_load_ptr2;
      buf_b_wr_idx  = axi_rd_idx;
      buf_b_wr_word = axi_rd_word;
    end
    buf_b_rd_idx = (state_r == S_TR_STORE) ? axi_wr_idx : conv_rd_idx;
  end

  // AXI write data: buf_b for Transpose STORE, Lab1 data otherwise. Lab1
  // data is registered so it has the same 1-cycle latency as a BRAM read.
  reg [31:0] l1_wr_word;
  always @(posedge clk)
    l1_wr_word <= (axi_wr_idx == 0) ? (l1_misaligned ? l1_wdata0 : rs2_i) : l1_wdata1;
  always @(*) axi_wr_word = (state_r == S_TR_STORE) ? buf_b_rd_word : l1_wr_word;

  //============================================================================
  // FSM part 1/3: state register
  //============================================================================
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) state_r <= S_IDLE;
    else state_r <= next_state;
  end

  //============================================================================
  // FSM part 2/3: next-state logic
  //============================================================================
  always @(*) begin
    next_state = state_r;
    case (state_r)
      S_IDLE: begin
        if (NPU_start) begin
          if (op_mac_clear || op_mac_set_offset || op_mac_acc4) next_state = S_L1_COMP;
          else if (op_add) next_state = S_ADD;
          else if (op_axi_read || op_axi_write) next_state = S_L1_AXI;
          else if (op_conv_load_ptr1 || op_conv_load_ptr2) next_state = S_CONV_LOAD;
          else if (op_conv_compute) next_state = S_CONV_COMP;
          else if (op_logistic) next_state = S_LOGISTIC;
          else if (op_tr_start && !tr_bad_cfg && tr_total_bytes != 0) next_state = S_TR_LOAD;
          else next_state = S_DONE;  // CONFIG / TRANSPOSE_CFG / bad start / no-op
        end
      end
      S_L1_COMP: next_state = op_mac_acc4 ? S_L1_SUM : S_DONE;
      S_L1_SUM: next_state = S_L1_ACC;
      S_ADD, S_L1_ACC: next_state = S_DONE;
      S_L1_AXI, S_CONV_LOAD: if (axi_cmd_done) next_state = S_DONE;
      S_CONV_COMP: if (N == 0 || (p2_valid && p2_last)) next_state = S_DONE;
      S_LOGISTIC: if (logistic_done) next_state = S_DONE;
      S_TR_LOAD: if (axi_cmd_done) next_state = axi_cmd_err ? S_DONE : S_TR_PERM;
      S_TR_PERM: if (tr_permute_done) next_state = S_TR_STORE;
      S_TR_STORE: if (axi_cmd_done) next_state = S_DONE;
      S_DONE: next_state = S_IDLE;
      default: next_state = S_IDLE;
    endcase
  end

  //============================================================================
  // FSM part 3/3: datapath / output registers
  //============================================================================
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      NPU_out             <= 32'd0;
      NPU_done            <= 1'b0;
      acc_r               <= 32'sd0;
      offset              <= 32'sd0;
      l1_a_bytes          <= 32'd0;
      l1_b_bytes          <= 32'd0;
      mac_sum_r           <= 32'sd0;
      N                   <= 9'd0;
      input_offset        <= 9'sd0;
      ptr1_byte_off       <= 2'd0;
      ptr2_byte_off       <= 2'd0;
      conv_load_ptr2      <= 1'b0;
      conv_rd_idx         <= 0;
      conv_rd_valid       <= 1'b0;
      conv_data_idx       <= 0;
      ptr1_prev_word      <= 32'd0;
      ptr2_prev_word      <= 32'd0;
      accum               <= 32'sd0;
      p1_valid            <= 1'b0;
      p1_last             <= 1'b0;
      p1_in_bytes         <= 32'd0;
      p1_flt_bytes        <= 32'd0;
      p1_group_byte       <= 32'd0;
      p2_valid            <= 1'b0;
      p2_last             <= 1'b0;
      p2_sum              <= 32'sd0;
      axi_cmd_start       <= 1'b0;
      axi_cmd_write       <= 1'b0;
      axi_cmd_addr        <= 32'd0;
      axi_cmd_beats       <= 0;
      axi_cmd_first_wstrb <= 4'b1111;
      axi_cmd_last_wstrb  <= 4'b1111;
      tr_permute_start    <= 1'b0;
    end else begin
      NPU_done         <= 1'b0;
      axi_cmd_start    <= 1'b0;
      tr_permute_start <= 1'b0;

      case (state_r)
        S_IDLE: begin
          conv_rd_idx   <= 0;
          conv_rd_valid <= 1'b0;
          p1_valid      <= 1'b0;
          p1_last       <= 1'b0;
          p2_valid      <= 1'b0;
          p2_last       <= 1'b0;
          accum         <= 32'sd0;
          l1_a_bytes    <= rs1_i;
          l1_b_bytes    <= rs2_i;
          if (NPU_start) begin
            if (op_axi_read) begin
              axi_cmd_start <= 1'b1;
              axi_cmd_write <= 1'b0;
              axi_cmd_addr  <= rs1_i;
              axi_cmd_beats <= l1_misaligned ? 2 : 1;
            end
            if (op_axi_write) begin
              axi_cmd_start       <= 1'b1;
              axi_cmd_write       <= 1'b1;
              axi_cmd_addr        <= rs1_i;
              axi_cmd_beats       <= l1_misaligned ? 2 : 1;
              axi_cmd_first_wstrb <= l1_wstrb0;
              axi_cmd_last_wstrb  <= l1_wstrb1;
            end
            if (op_conv_config) begin
              N            <= rs1_i[8:0];
              input_offset <= $signed(rs2_i[8:0]);
            end
            if (op_conv_load_ptr1 || op_conv_load_ptr2) begin
              conv_load_ptr2 <= op_conv_load_ptr2;
              if (op_conv_load_ptr1) ptr1_byte_off <= rs1_i[1:0];
              else ptr2_byte_off <= rs1_i[1:0];
              axi_cmd_start <= 1'b1;
              axi_cmd_write <= 1'b0;
              axi_cmd_addr  <= rs1_i;
              axi_cmd_beats <= ({2'b00, N} + rs1_i[1:0] + 11'd3) >> 2;
            end
            if (op_tr_cfg) NPU_out <= 32'd0;  // the register is written via start_op
            if (op_tr_start) begin
              if (tr_bad_cfg) begin
                NPU_out <= 32'd2;
              end else if (tr_total_bytes == 0) begin
                NPU_out <= 32'd0;
              end else begin
                axi_cmd_start <= 1'b1;
                axi_cmd_write <= 1'b0;
                axi_cmd_addr  <= tr_src_base_addr;
                axi_cmd_beats <= tr_beats;
              end
            end
          end
        end

        S_L1_COMP: begin
          if (op_mac_clear) begin
            NPU_out <= 32'b0;
            acc_r   <= 32'b0;
          end else if (op_mac_set_offset) begin
            offset <= rs1_i;
          end
        end

        S_L1_SUM: mac_sum_r <= mac_sum;

        S_L1_ACC: begin
          acc_r   <= acc_r + mac_sum_r;
          NPU_out <= acc_r + mac_sum_r;
        end

        S_ADD: NPU_out <= rs1_i + rs2_i + funct7_i;

        S_L1_AXI: begin
          if (op_axi_read && axi_rd_valid) begin
            if (axi_rd_idx == 0) NPU_out <= axi_rd_word >> l1_shift;
            else NPU_out <= NPU_out | (axi_rd_word << (6'd32 - l1_shift));
          end
        end

        S_CONV_COMP: begin
          conv_rd_idx   <= conv_rd_idx + 1'b1;
          conv_rd_valid <= 1'b1;
          conv_data_idx <= conv_rd_idx;
          if (conv_rd_valid) begin
            ptr1_prev_word <= buf_a_rd_word;
            ptr2_prev_word <= buf_b_rd_word;
          end
          // P1
          p1_valid      <= conv_group_valid;
          p1_last       <= conv_group_valid && conv_last_group;
          p1_in_bytes   <= lane_in_bytes;
          p1_flt_bytes  <= lane_flt_bytes;
          p1_group_byte <= {conv_group, 2'b00};
          // P2
          p2_valid      <= p1_valid;
          p2_last       <= p1_last;
          p2_sum        <= compute_sum;
          // accumulate
          if (N == 0) begin
            NPU_out <= 32'd0;
          end else if (p2_valid) begin
            accum <= accum + p2_sum;
            if (p2_last) NPU_out <= accum + p2_sum;
          end
        end

        S_LOGISTIC: NPU_out <= logistic_result;

        S_TR_LOAD: begin
          if (axi_cmd_done) begin
            if (axi_cmd_err) NPU_out <= 32'd1;
            else tr_permute_start <= 1'b1;
          end
        end

        S_TR_PERM: begin
          if (tr_permute_done) begin
            axi_cmd_start       <= 1'b1;
            axi_cmd_write       <= 1'b1;
            axi_cmd_addr        <= tr_dst_base_addr;
            axi_cmd_beats       <= tr_beats;
            axi_cmd_first_wstrb <= 4'b1111;
            axi_cmd_last_wstrb  <= tr_last_wstrb;
          end
        end

        S_TR_STORE: if (axi_cmd_done) NPU_out <= axi_cmd_err ? 32'd1 : 32'd0;

        S_DONE: NPU_done <= 1'b1;

        default: ;
      endcase
    end
  end

endmodule
