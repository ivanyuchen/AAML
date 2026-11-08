//==============================================================================
// Transpose: on-chip permute engine used by NPU (funct3 = 5 / 6).
//
// Naming
//   src  = input tensor  (NPU loads it from DDR into src_buf)
//   dst  = output tensor (built in dst_buf, NPU stores it to DDR)
//   word = one 32-bit AXI beat = one buffer entry
//
// src_buf / dst_buf are bram_sdp instances owned by the NPU and shared with
// Conv (Lab2 ptr1 / ptr2 buffers). This module only sees:
//   src_buf read port  (src_rd_idx -> src_rd_word, 1-cycle latency)
//   dst_buf write port (dst_wr_en / dst_wr_idx / dst_wr_word)
//
// Flow (NPU drives every step; this module never touches AXI)
//   1. CONFIG : cfg_wr_en pulses, one field per CUSTOM-0 funct3 = 5
//   2. LOAD   : NPU burst-reads src from DDR into src_buf
//   3. PERMUTE: permute_start -> src_buf (strided bytes) -> dst_buf -> permute_done
//   4. STORE  : NPU burst-writes dst_buf to DDR
//==============================================================================
module Transpose #(
    parameter BUF_BYTES = 16384,                 // largest MobileViT transpose = 16KB
    parameter BUF_WORDS = BUF_BYTES / 4,
    parameter WIDX_W    = $clog2(BUF_WORDS),     // word index width
    parameter MAX_RANK  = 6,
    parameter DIM_W     = $clog2(BUF_BYTES + 1)
) (
    input clk_i,
    input rst_n,

    // -------------------------------------------------------------------------
    // 1. CONFIG (NPU forwards funct7 / rs1 / rs2 of funct3 = 5)
    // -------------------------------------------------------------------------
    input        cfg_wr_en,  // 1-cycle pulse
    input [ 2:0] cfg_field,  // funct7, see CFG_* below
    input [31:0] cfg_rs1,
    input [31:0] cfg_rs2,

    // Config read-back for NPU's AXI bursts
    output reg [31:0] src_base_addr,  // DDR byte address of src tensor
    output reg [31:0] dst_base_addr,  // DDR byte address of dst tensor
    output reg [31:0] total_bytes,    // tensor size in bytes (src == dst)

    // -------------------------------------------------------------------------
    // 3. PERMUTE
    // -------------------------------------------------------------------------
    input      permute_start,  // 1-cycle pulse, after LOAD finished
    output reg permute_done,   // 1-cycle pulse, dst_buf complete

    // src_buf read port (synchronous: src_rd_word valid ONE cycle after idx)
    output reg [WIDX_W-1:0] src_rd_idx,
    input      [      31:0] src_rd_word,

    // dst_buf write port
    output reg              dst_wr_en,
    output reg [WIDX_W-1:0] dst_wr_idx,
    output reg [      31:0] dst_wr_word
);

  // -----------------------------------------------------------------------------
  // cfg_field encoding (= funct7 of funct3 = 5)
  //   field          rs1            rs2
  //   CFG_ADDR       src_base_addr  dst_base_addr
  //   CFG_SIZE       rank           total_bytes
  //   CFG_DST_SHAPE  dim d          dst_shape[d]   (output length of dim d)
  //   CFG_SRC_STRIDE dim d          src_stride[d]  (src byte step when output
  //                                                 dim d advances by 1
  //                                                 = input_stride[perm[d]])
  // -----------------------------------------------------------------------------
  localparam CFG_ADDR = 0;
  localparam CFG_SIZE = 1;
  localparam CFG_DST_SHAPE = 2;
  localparam CFG_SRC_STRIDE = 3;

  reg [DIM_W-1:0] dst_shape[0:MAX_RANK-1];
  reg [DIM_W-1:0] src_stride[0:MAX_RANK-1];
  reg [2:0] rank;

  localparam IDLE = 0;
  localparam TRANSPOSE = 1;

  reg state, next_state;

  always @(*) begin
    next_state = IDLE;
    case (state)
      IDLE: begin
        if (permute_start) next_state = TRANSPOSE;
      end
      TRANSPOSE: begin
        if (permute_done) next_state = IDLE;
        else next_state = TRANSPOSE;
      end
      default: next_state = IDLE;
    endcase
  end

  always @(posedge clk_i) begin
    if (!rst_n) state <= IDLE;
    else state <= next_state;
  end

  integer i;
  always @(posedge clk_i) begin
    if (!rst_n) begin
      for (i = 0; i < MAX_RANK; i = i + 1) begin
        dst_shape[i]  <= 1;
        src_stride[i] <= 0;
      end
      src_base_addr <= 0;
      dst_base_addr <= 0;
      rank          <= 0;
      total_bytes   <= 0;
    end else if (cfg_wr_en) begin
      case (cfg_field)
        CFG_ADDR: begin
          src_base_addr <= cfg_rs1;
          dst_base_addr <= cfg_rs2;
        end
        CFG_SIZE: begin
          rank        <= cfg_rs1;
          total_bytes <= cfg_rs2;
        end
        CFG_DST_SHAPE: dst_shape[cfg_rs1] <= cfg_rs2;
        CFG_SRC_STRIDE: src_stride[cfg_rs1] <= cfg_rs2;
        default: ;
      endcase
    end
  end

  // -----------------------------------------------------------------------------
  // PERMUTE
  //   Odometer over dst dims: dim 0 = outermost, dim rank-1 = innermost
  //   (same order as TFLite). Dims >= rank count as length 1, so stale
  //   config from a previous higher-rank transpose is harmless.
  //
  //   layer_loop_control[d] = current index of dst dim d
  //   layer_src_addr[d]     = sum_{k<=d} layer_loop_control[k] * src_stride[k]
  //     -> no multipliers: the dim that advances adds src_stride[d], every
  //        inner dim that wraps copies that value (its own index is back to 0)
  //   src byte address      = layer_src_addr[MAX_RANK-1]
  //
  //   Pipeline (1 byte / cycle):
  //     I: src_rd_idx = src_byte_addr[WIDX_W+1:2], keep src_byte_addr[1:0]
  //     R: src_rd_word valid -> pick byte -> pack into dst word;
  //        every 4th byte (or the last byte) registers a dst_buf write
  //     W: dst_buf written; the last write pulses permute_done
  // -----------------------------------------------------------------------------
  reg [DIM_W-1:0] layer_loop_control[0:MAX_RANK-1];
  reg [DIM_W-1:0] layer_src_addr    [0:MAX_RANK-1];

  // ---- next odometer state (combinational) ----
  reg [MAX_RANK-1:0] layer_wrap;  // dim d is at its last index
  reg [MAX_RANK-1:0] layer_step;  // every inner dim wraps -> dim d moves
  reg [   DIM_W-1:0] layer_loop_control_next[0:MAX_RANK-1];
  reg [   DIM_W-1:0] layer_src_addr_next    [0:MAX_RANK-1];
  reg [   DIM_W-1:0] outer_src_addr_next;
  integer j;
  always @(*) begin
    for (j = 0; j < MAX_RANK; j = j + 1)
      layer_wrap[j] = (j >= rank) || (layer_loop_control[j] == dst_shape[j] - 1'b1);

    layer_step[MAX_RANK-1] = 1'b1;
    for (j = MAX_RANK - 2; j >= 0; j = j - 1)
      layer_step[j] = layer_step[j+1] && layer_wrap[j+1];

    outer_src_addr_next = 0;
    for (j = 0; j < MAX_RANK; j = j + 1) begin
      if (!layer_step[j]) begin
        layer_loop_control_next[j] = layer_loop_control[j];
        layer_src_addr_next[j]     = layer_src_addr[j];
      end else if (!layer_wrap[j]) begin
        layer_loop_control_next[j] = layer_loop_control[j] + 1'b1;
        layer_src_addr_next[j]     = layer_src_addr[j] + src_stride[j];
      end else begin
        layer_loop_control_next[j] = 0;
        layer_src_addr_next[j]     = outer_src_addr_next;
      end
      outer_src_addr_next = layer_src_addr_next[j];
    end
  end

  wire [DIM_W-1:0] src_byte_addr = layer_src_addr[MAX_RANK-1];
  always @(*) src_rd_idx = src_byte_addr[WIDX_W+1:2];

  // ---- stage I: issue one src byte per cycle ----
  reg  [DIM_W-1:0] issue_cnt;  // bytes issued so far
  wire             issue = (state == TRANSPOSE) && (issue_cnt != total_bytes);
  wire             issue_last = (issue_cnt == total_bytes - 1);

  // ---- stage R: src_rd_word valid, pack into dst word ----
  reg              rd_valid;
  reg              rd_last;
  reg  [      1:0] rd_byte_sel;
  wire [     31:0] rd_word_shift = src_rd_word >> {rd_byte_sel, 3'b000};
  wire [      7:0] rd_byte = rd_word_shift[7:0];

  reg  [DIM_W-1:0] pack_cnt;  // bytes packed so far = dst byte address
  reg  [     31:0] pack_word;
  wire [      1:0] pack_lane = pack_cnt[1:0];
  wire [     31:0] pack_word_next = pack_word | ({24'd0, rd_byte} << {pack_lane, 3'b000});

  // ---- stage W ----
  reg              wr_last;

  integer k;
  always @(posedge clk_i) begin
    if (!rst_n || permute_start) begin
      for (k = 0; k < MAX_RANK; k = k + 1) begin
        layer_loop_control[k] <= 0;
        layer_src_addr[k]     <= 0;
      end
      issue_cnt       <= 0;
      rd_valid        <= 1'b0;
      rd_last         <= 1'b0;
      rd_byte_sel     <= 2'd0;
      pack_cnt        <= 0;
      pack_word       <= 32'd0;
      dst_wr_en   <= 1'b0;
      dst_wr_idx  <= 0;
      dst_wr_word <= 32'd0;
      wr_last         <= 1'b0;
      permute_done    <= 1'b0;
    end else begin
      // I
      if (issue) begin
        for (k = 0; k < MAX_RANK; k = k + 1) begin
          layer_loop_control[k] <= layer_loop_control_next[k];
          layer_src_addr[k]     <= layer_src_addr_next[k];
        end
        issue_cnt <= issue_cnt + 1'b1;
      end
      rd_valid    <= issue;
      rd_last     <= issue && issue_last;
      rd_byte_sel <= src_byte_addr[1:0];

      // R
      dst_wr_en <= 1'b0;
      wr_last       <= 1'b0;
      if (rd_valid) begin
        pack_cnt <= pack_cnt + 1'b1;
        if (pack_lane == 2'd3 || rd_last) begin
          dst_wr_en   <= 1'b1;
          dst_wr_idx  <= pack_cnt[WIDX_W+1:2];
          dst_wr_word <= pack_word_next;
          wr_last         <= rd_last;
          pack_word       <= 32'd0;
        end else begin
          pack_word <= pack_word_next;
        end
      end

      // W (total_bytes == 0: nothing to do, finish right away)
      permute_done <= (dst_wr_en && wr_last) ||
                      (state == TRANSPOSE && total_bytes == 0 && !permute_done);
    end
  end

endmodule
