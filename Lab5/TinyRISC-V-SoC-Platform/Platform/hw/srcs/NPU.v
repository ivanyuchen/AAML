`timescale 1ns / 1ps
//==============================================================================
// Lab5 CUSTOM-0 instruction map (opcode = 0x0B)
//
// 已實作的指令：
// funct3 funct7  功能                  rs1                  rs2
//   0    >2     Scalar add            加數                 加數
//               NPU_out = rs1 + rs2 + funct7；平台測試使用 funct7=5。
//   4    任意   Logistic              signed Q4.27 raw      不使用
//               NPU_out = Q0.31 raw sigmoid result。
//   5     0     Transpose 地址設定     input byte address   output byte address
//   5     1     Transpose 大小設定     rank (1..6)          total bytes
//   5     2     Transpose shape       dimension d          output_shape[d]
//   5     3     Transpose stride      dimension d          input_stride[perm[d]]
//               stride 單位為 bytes；設定指令 NPU_out=0。
//               Transpose 僅解碼 funct7[2:0]，軟體請固定使用 0..3。
//   6    任意   Transpose 啟動         不使用               不使用
//               等待 AXI 讀取、排列及寫回完成，才回覆 NPU_done。
//               NPU_out: 0=成功，1=AXI error，2=不支援的地址/大小。
//
// TPU / GEMV 指令分配（已接設定、A/B 載入、TPU 計算與 C 寫回）：
// funct3 funct7  功能                  rs1                  rs2
//   7     1     GEMV_CFG_AB           packed A byte addr   packed B byte addr
//   7     2     GEMV_CFG_C            int32 C byte addr    0（保留）
//   7     3     GEMV_CFG_DIMS         M                    K
//   7     0     GEMV_START            0（保留）            0（保留）
//
// 預定軟體呼叫順序（使用 cfu_op7 / cfu_raw_op）：
//   cfu_op7(1, packed_A, packed_B);  // 設定已打包的 A/B buffers
//   cfu_op7(2, matC, 0);            // 結果直接寫到呼叫者的 C buffer
//   cfu_op7(3, M, K);               // A: M x K，B: K，C: M
//   status = cfu_op7(0, 0, 0);      // 阻塞至結果寫回完成
// 預定設定指令成功回傳 0；START 回傳 0=成功、1=AXI error、2=參數錯誤。
// Basic 1 所需的軟體 cache maintenance 由 wrapper 在呼叫前後處理。
// 實作後 NPU_done 必須等最後一筆 AXI write response 完成才送出。
// START: 載入 A/B -> TPU 計算 -> 寫回 M 個 int32 結果 -> NPU_done。
//
// 可重新使用：funct3=1/2/3，以及 funct3=0 的 funct7=0/1/2。
// 舊 Lab1 MAC / 單筆 AXI 指令、Lab2 SIMD MAC 已移除。
// 尚未實作的非 TPU 指令回傳 3。
// funct3_i 雖有 4 bits，指令解碼只使用最低 3 bits。
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
  localparam C_BUF_WORDS = 256;  // GEMV has at most 254 int32 outputs.
  localparam C_IDX_W = $clog2(C_BUF_WORDS);

  localparam S_IDLE = 4'd0, S_DONE = 4'd1, S_ADD = 4'd2,
             S_LOGISTIC = 4'd3, S_TR_LOAD = 4'd4,
             S_TR_PERM = 4'd5, S_TR_STORE = 4'd6,
             S_TPU_LOAD = 4'd7, S_TPU_WORK = 4'd8, S_TPU_STORE = 4'd9;
  reg [3:0] state_r, next_state;
  wire             start_op = (state_r == S_IDLE) && NPU_start;
  wire             op_add = (funct3_i[2:0] == 3'd0) && (funct7_i > 32'd2);
  wire             op_logistic = (funct3_i[2:0] == 3'd4);
  wire             op_tr_cfg = (funct3_i[2:0] == 3'd5);
  wire             op_tr_start = (funct3_i[2:0] == 3'd6);
  wire             op_tpu = (funct3_i[2:0] == 3'd7);

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

  // TPU C buffer ports: one signed int32 result per word.
  reg              buf_c_we;
  reg  [C_IDX_W-1:0] buf_c_wr_idx;
  reg  [     31:0] buf_c_wr_word;
  reg  [C_IDX_W-1:0] buf_c_rd_idx;
  wire [     31:0] buf_c_rd_word;

  wire [15:0] tpu_a_idx, tpu_b_idx, tpu_c_idx;
  wire tpu_c_ram_en, tpu_c_wr_en;
  wire [    127:0] tpu_c_data;

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
  bram_sdp #(
      .ENTRY_NUM(C_BUF_WORDS),
      .DWIDTH   (32)
  ) u_buf_c (
      .clk_i       (clk),
      .we_i        (buf_c_we),
      .read_addr_i (buf_c_rd_idx),
      .write_addr_i(buf_c_wr_idx),
      .data_i      (buf_c_wr_word),
      .data_o      (buf_c_rd_word)
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
  Logistic u_logistic (
      .clk    (clk),
      .rst_n  (rst_n),
      .start  (start_op && op_logistic),
      .input_a(rs1_i),
      .done   (logistic_done),
      .result (logistic_result)
  );

  //============================================================================
  // Transpose START checks
  //============================================================================
  wire [IDX_W:0] tr_beats = (tr_total_bytes + 32'd3) >> 2;
  wire [1:0] tr_tail = tr_total_bytes[1:0];
  wire [3:0] tr_last_wstrb = (tr_tail == 2'd0) ? 4'b1111 : (4'b1111 >> (3'd4 - tr_tail));
  wire tr_bad_cfg = (tr_src_base_addr[1:0] != 2'b00) || (tr_dst_base_addr[1:0] != 2'b00) ||
                    (tr_total_bytes > TR_BUF_BYTES);

  // Transpose input / output buffer ports; no legacy Conv buffer muxes.
  always @(*) begin
    buf_a_we = axi_rd_valid && ((state_r == S_TR_LOAD) || (state_r == S_TPU_LOAD && !loading_b));
    buf_a_wr_idx = axi_rd_idx;
    buf_a_wr_word = axi_rd_word;
    buf_a_rd_idx = (state_r == S_TPU_WORK) ? tpu_a_idx[IDX_W-1:0] : tr_src_rd_idx;
    buf_b_we = (state_r == S_TR_PERM) ? tr_dst_wr_en :
               (axi_rd_valid && state_r == S_TPU_LOAD && loading_b);
    buf_b_wr_idx = (state_r == S_TR_PERM) ? tr_dst_wr_idx : axi_rd_idx;
    buf_b_wr_word = (state_r == S_TR_PERM) ? tr_dst_wr_word : axi_rd_word;
    buf_b_rd_idx = (state_r == S_TPU_WORK) ? tpu_b_idx[IDX_W-1:0] : axi_wr_idx;

    // TPU emits one result in [127:96], with its output-row index.
    buf_c_we = (state_r == S_TPU_WORK) && tpu_c_ram_en && tpu_c_wr_en;
    buf_c_wr_idx = tpu_c_idx[C_IDX_W-1:0];
    buf_c_wr_word = tpu_c_data[127:96];
    buf_c_rd_idx = axi_wr_idx[C_IDX_W-1:0];
    axi_wr_word = (state_r == S_TPU_STORE) ? buf_c_rd_word : buf_b_rd_word;
  end
  //============================================================================
  // TPU
  //============================================================================
  // funct3 funct7  功能                  rs1                  rs2
  //   7     1     GEMV_CFG_AB           packed A byte addr   packed B byte addr
  //   7     2     GEMV_CFG_C            int32 C byte addr    0（保留）
  //   7     3     GEMV_CFG_DIMS         M                    K
  //   7     0     GEMV_START            0（保留）            0（保留）

  reg [7:0] M, N, K;
  reg [31:0] matA_addr, matB_addr, matC_addr;
  wire [2:0] tpu_cfg_feild = funct7_i[2:0];
  reg tpu_in_valid;
  wire tpu_busy;
  TPU u_tpu (
      .clk(clk),
      .rst_n(rst_n),
      .in_valid(tpu_in_valid),
      .M(M),
      .K(K),
      .N(8'd1),
      .busy(tpu_busy),
      .A_ram_en(),
      .A_wr_en(),
      .A_index(tpu_a_idx),
      .A_data_in(),
      .A_data_out(buf_a_rd_word),
      .B_ram_en(),
      .B_wr_en(),
      .B_index(tpu_b_idx),
      .B_data_in(),
      .B_data_out(buf_b_rd_word),
      .C_ram_en(tpu_c_ram_en),
      .C_wr_en(tpu_c_wr_en),
      .C_index(tpu_c_idx),
      .C_data_in(tpu_c_data),
      .C_data_out(128'd0)
  );
  localparam GEMV_START = 0, GEMV_CFG_AB = 1, GEMV_CFG_C = 2, GEMV_CFG_DIMS = 3;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin

    end else if (start_op && op_tpu) begin
      case (tpu_cfg_feild)
        GEMV_CFG_AB: begin
          matA_addr <= rs1_i;
          matB_addr <= rs2_i;
        end
        GEMV_CFG_C: begin
          matC_addr <= rs1_i;
        end
        GEMV_CFG_DIMS: begin
          M <= rs1_i[7:0];
          K <= rs2_i[7:0];
        end
        default: ;
      endcase
    end
  end
  //============================================================================
  // TPU A/B load: A has ceil(M/4)*K packed words; B has K packed words.
  // C is an output and is not read from DDR.
  //============================================================================
  reg loading_b;  // 0: fill buf_a, 1: fill buf_b
  wire [8:0] tpu_row_blocks = ({1'b0, M} + 9'd3) >> 2;
  wire [16:0] tpu_a_words = {8'd0, tpu_row_blocks} * {9'd0, K};
  wire tpu_start_cmd = op_tpu && (tpu_cfg_feild == GEMV_START);
  wire tpu_bad_cfg = (M == 0) || (K == 0) || (M > 254) || (K > 254) ||
                     (tpu_a_words > 1024) ||
                     (matA_addr[1:0] != 0) || (matB_addr[1:0] != 0) ||
                     (matC_addr[1:0] != 0);




  //============================================================================
  // Control State
  //============================================================================

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) state_r <= S_IDLE;
    else state_r <= next_state;
  end

  always @(*) begin
    next_state = state_r;
    case (state_r)
      S_IDLE:
      if (NPU_start) begin
        if (op_add) next_state = S_ADD;
        else if (op_logistic) next_state = S_LOGISTIC;
        else if (op_tr_start && !tr_bad_cfg && tr_total_bytes != 0) next_state = S_TR_LOAD;
        else if (tpu_start_cmd && !tpu_bad_cfg) next_state = S_TPU_LOAD;
        else next_state = S_DONE;
      end
      S_ADD: next_state = S_DONE;
      S_LOGISTIC: if (logistic_done) next_state = S_DONE;
      S_TR_LOAD: if (axi_cmd_done) next_state = axi_cmd_err ? S_DONE : S_TR_PERM;
      S_TR_PERM: if (tr_permute_done) next_state = S_TR_STORE;
      S_TR_STORE: if (axi_cmd_done) next_state = S_DONE;
      S_TPU_LOAD:
      if (axi_cmd_done) begin
        if (axi_cmd_err) next_state = S_DONE;
        else if (loading_b) next_state = S_TPU_WORK;
      end
      S_TPU_WORK:
      if (tpu_busy) next_state = S_TPU_WORK;
      else next_state = S_TPU_STORE;
      S_TPU_STORE:
      if (axi_cmd_done) next_state = S_DONE;
      else next_state = S_TPU_STORE;
      S_DONE: next_state = S_IDLE;
      default: next_state = S_IDLE;
    endcase
  end

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      NPU_out <= 32'd0;
      NPU_done <= 1'b0;
      axi_cmd_start <= 1'b0;
      axi_cmd_write <= 1'b0;
      axi_cmd_addr <= 32'd0;
      axi_cmd_beats <= 0;
      axi_cmd_first_wstrb <= 4'b1111;
      axi_cmd_last_wstrb <= 4'b1111;
      tr_permute_start <= 1'b0;
      loading_b <= 1'b0;
      tpu_in_valid <= 1'b0;
    end else begin
      NPU_done <= 1'b0;
      axi_cmd_start <= 1'b0;
      tr_permute_start <= 1'b0;
      tpu_in_valid <= 1'b0;
      case (state_r)
        S_IDLE:
        if (NPU_start) begin
          if (op_tr_cfg) NPU_out <= 32'd0;
          else if (op_tr_start) begin
            if (tr_bad_cfg) NPU_out <= 32'd2;
            else if (tr_total_bytes == 0) NPU_out <= 32'd0;
            else begin
              axi_cmd_start <= 1'b1;
              axi_cmd_write <= 1'b0;
              axi_cmd_addr  <= tr_src_base_addr;
              axi_cmd_beats <= tr_beats;
            end
          end else if (op_tpu) begin
            if (tpu_start_cmd) begin
              if (tpu_bad_cfg) NPU_out <= 32'd2;
              else begin
                loading_b <= 1'b0;
                axi_cmd_start <= 1'b1;
                axi_cmd_write <= 1'b0;
                axi_cmd_addr <= matA_addr;
                axi_cmd_beats <= tpu_a_words[IDX_W:0];
              end
            end else NPU_out <= 32'd0;
          end else if (!op_add && !op_logistic) NPU_out <= 32'd3;
        end
        S_ADD: NPU_out <= rs1_i + rs2_i + funct7_i;
        S_LOGISTIC: NPU_out <= logistic_result;
        S_TR_LOAD:
        if (axi_cmd_done) begin
          if (axi_cmd_err) NPU_out <= 32'd1;
          else tr_permute_start <= 1'b1;
        end
        S_TR_PERM:
        if (tr_permute_done) begin
          axi_cmd_start <= 1'b1;
          axi_cmd_write <= 1'b1;
          axi_cmd_addr <= tr_dst_base_addr;
          axi_cmd_beats <= tr_beats;
          axi_cmd_first_wstrb <= 4'b1111;
          axi_cmd_last_wstrb <= tr_last_wstrb;
        end
        S_TR_STORE: if (axi_cmd_done) NPU_out <= axi_cmd_err ? 32'd1 : 32'd0;
        S_TPU_LOAD:
        if (axi_cmd_done) begin
          if (axi_cmd_err) NPU_out <= 32'd1;
          else if (!loading_b) begin
            loading_b <= 1'b1;
            axi_cmd_start <= 1'b1;
            axi_cmd_write <= 1'b0;
            axi_cmd_addr <= matB_addr;
            axi_cmd_beats <= {{(IDX_W - 7) {1'b0}}, K};
          end else begin
            // The final B beat has reached BRAM; start TPU for one cycle.
            tpu_in_valid <= 1'b1;
          end
        end
        S_TPU_WORK:
        if (!tpu_busy) begin
          // All C words are in BRAM. Start the write once, on entry to STORE.
          axi_cmd_start <= 1'b1;
          axi_cmd_write <= 1'b1;
          axi_cmd_addr <= matC_addr;
          axi_cmd_beats <= {{(IDX_W - 7) {1'b0}}, M};
          axi_cmd_first_wstrb <= 4'b1111;
          axi_cmd_last_wstrb <= 4'b1111;
        end
        S_TPU_STORE: if (axi_cmd_done) NPU_out <= axi_cmd_err ? 32'd1 : 32'd0;
        S_DONE: NPU_done <= 1'b1;
        default: ;
      endcase
    end
  end
endmodule
