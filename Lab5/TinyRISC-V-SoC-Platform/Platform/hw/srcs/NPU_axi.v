`timescale 1ns / 1ps
//==============================================================================
// NPU_axi: the NPU's only AXI4 master. Moves N 32-bit words between DDR and
// an on-chip word buffer; the NPU decides which buffer is on the other side.
//
// Command (cmd_start = 1-cycle pulse, other cmd_* sampled with it)
//   cmd_write = 0 : read  cmd_beats words from cmd_addr -> rd_* stream
//   cmd_write = 1 : write cmd_beats words to   cmd_addr <- wr_* stream
//   cmd_addr must be word aligned. cmd_beats = 0 finishes immediately.
//   Write strobes: beat 0 uses cmd_first_wstrb, the last beat cmd_last_wstrb
//   (a 1-beat write uses both ANDed), every other beat 4'b1111.
//   cmd_done pulses when everything is finished (writes: after the last B).
//   cmd_err stays 1 until the next cmd_start if any RRESP/BRESP != OKAY.
//
// Bursts: INCR, up to MAX_BURST beats, never crossing a 4KB boundary,
// one burst in flight at a time.
//
// Read stream : rd_valid / rd_idx / rd_word follow the R channel directly
//               (rd_idx = word index counted from cmd_addr).
// Write stream: wr_idx goes to a SYNCHRONOUS-read buffer (1-cycle latency);
//               wr_word must be that buffer's output. wr_idx is advanced in
//               the same cycle a beat is accepted, so wr_word always holds
//               the current beat and W can stream one beat per cycle.
//==============================================================================
module NPU_axi #(
    parameter IDX_W     = 12,  // word index width (buffer depth = 2^IDX_W)
    parameter MAX_BURST = 16
) (
    input clk,
    input rst_n,

    // -------------------------------------------------------------------------
    // Command
    // -------------------------------------------------------------------------
    input             cmd_start,
    input             cmd_write,
    input      [31:0] cmd_addr,
    input      [IDX_W:0] cmd_beats,
    input      [ 3:0] cmd_first_wstrb,
    input      [ 3:0] cmd_last_wstrb,
    output reg        cmd_done,
    output reg        cmd_err,

    // -------------------------------------------------------------------------
    // Read stream (DDR -> buffer)
    // -------------------------------------------------------------------------
    output             rd_valid,
    output [IDX_W-1:0] rd_idx,
    output [     31:0] rd_word,

    // -------------------------------------------------------------------------
    // Write stream (buffer -> DDR)
    // -------------------------------------------------------------------------
    output [IDX_W-1:0] wr_idx,
    input  [     31:0] wr_word,

    // -------------------------------------------------------------------------
    // AXI4 master
    // -------------------------------------------------------------------------
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

    output [31:0] M_AXI_WDATA,
    output [ 3:0] M_AXI_WSTRB,
    output        M_AXI_WLAST,
    output        M_AXI_WVALID,
    input         M_AXI_WREADY,

    input  [1:0] M_AXI_BRESP,
    input        M_AXI_BVALID,
    output       M_AXI_BREADY,

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

    input  [31:0] M_AXI_RDATA,
    input  [ 1:0] M_AXI_RRESP,
    input         M_AXI_RLAST,
    input         M_AXI_RVALID,
    output        M_AXI_RREADY
);

  localparam IDLE = 3'd0;
  localparam AR = 3'd1;
  localparam R = 3'd2;
  localparam AW = 3'd3;
  localparam W = 3'd4;
  localparam B = 3'd5;

  reg [2:0] state;

  reg [31:0] addr;  // start address of the current burst
  reg [IDX_W:0] remain;  // words not yet covered by a finished burst
  reg [IDX_W:0] total;  // cmd_beats
  reg [IDX_W-1:0] beat_cnt;  // global word index of the current beat
  reg [7:0] burst_beat;  // beat index inside the current burst
  reg [3:0] first_wstrb, last_wstrb;

  // ---------------------------------------------------------------------------
  // Length of the current burst: min(remain, MAX_BURST, words to 4KB edge).
  // addr / remain only change between bursts, so this is stable in a burst.
  // ---------------------------------------------------------------------------
  wire [10:0] words_to_4k = 11'd1024 - {1'b0, addr[11:2]};
  wire [IDX_W:0] cap = (words_to_4k < MAX_BURST) ? words_to_4k : MAX_BURST;
  wire [IDX_W:0] burst_len = (remain < cap) ? remain : cap;
  wire [7:0] axlen = burst_len - 1'b1;
  wire last_in_burst = (burst_beat == axlen);

  // ---------------------------------------------------------------------------
  // AXI constant fields
  // ---------------------------------------------------------------------------
  assign M_AXI_AWSIZE  = 3'b010;
  assign M_AXI_AWBURST = 2'b01;
  assign M_AXI_AWLOCK  = 1'b0;
  assign M_AXI_AWCACHE = 4'b0011;
  assign M_AXI_AWPROT  = 3'b000;
  assign M_AXI_AWQOS   = 4'b0000;
  assign M_AXI_AWUSER  = 16'h0000;
  assign M_AXI_ARSIZE  = 3'b010;
  assign M_AXI_ARBURST = 2'b01;
  assign M_AXI_ARLOCK  = 1'b0;
  assign M_AXI_ARCACHE = 4'b0011;
  assign M_AXI_ARPROT  = 3'b000;
  assign M_AXI_ARQOS   = 4'b0000;
  assign M_AXI_ARUSER  = 16'h0000;
  assign M_AXI_BREADY  = 1'b1;
  assign M_AXI_RREADY  = 1'b1;

  // ---------------------------------------------------------------------------
  // AR / R
  // ---------------------------------------------------------------------------
  assign M_AXI_ARVALID = (state == AR);
  assign M_AXI_ARADDR  = addr;
  assign M_AXI_ARLEN   = axlen;

  assign rd_valid      = (state == R) && M_AXI_RVALID;
  assign rd_idx        = beat_cnt;
  assign rd_word       = M_AXI_RDATA;

  // ---------------------------------------------------------------------------
  // AW / W
  // ---------------------------------------------------------------------------
  wire w_fire = M_AXI_WVALID && M_AXI_WREADY;
  wire is_first_beat = (beat_cnt == 0);
  wire is_last_beat = ({1'b0, beat_cnt} == total - 1'b1);

  assign M_AXI_AWVALID = (state == AW);
  assign M_AXI_AWADDR  = addr;
  assign M_AXI_AWLEN   = axlen;

  assign M_AXI_WVALID  = (state == W);
  assign M_AXI_WDATA   = wr_word;
  assign M_AXI_WLAST   = last_in_burst;
  assign M_AXI_WSTRB   = (is_first_beat ? first_wstrb : 4'b1111) &
                         (is_last_beat  ? last_wstrb  : 4'b1111);

  // Present the NEXT beat's index in the cycle the current one is accepted.
  assign wr_idx = w_fire ? beat_cnt + 1'b1 : beat_cnt;

  // ---------------------------------------------------------------------------
  // Control
  // ---------------------------------------------------------------------------
  wire [IDX_W:0] remain_after = remain - burst_len;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state       <= IDLE;
      addr        <= 32'd0;
      remain      <= 0;
      total       <= 0;
      beat_cnt    <= 0;
      burst_beat  <= 8'd0;
      first_wstrb <= 4'b1111;
      last_wstrb  <= 4'b1111;
      cmd_done    <= 1'b0;
      cmd_err     <= 1'b0;
    end else begin
      cmd_done <= 1'b0;
      case (state)
        IDLE: begin
          if (cmd_start) begin
            addr        <= {cmd_addr[31:2], 2'b00};
            remain      <= cmd_beats;
            total       <= cmd_beats;
            beat_cnt    <= 0;
            burst_beat  <= 8'd0;
            first_wstrb <= cmd_first_wstrb;
            last_wstrb  <= cmd_last_wstrb;
            cmd_err     <= 1'b0;
            if (cmd_beats == 0) cmd_done <= 1'b1;
            else state <= cmd_write ? AW : AR;
          end
        end

        AR: if (M_AXI_ARREADY) state <= R;

        R: begin
          if (M_AXI_RVALID) begin
            if (M_AXI_RRESP != 2'b00) cmd_err <= 1'b1;
            beat_cnt   <= beat_cnt + 1'b1;
            burst_beat <= burst_beat + 1'b1;
            if (M_AXI_RLAST) begin
              burst_beat <= 8'd0;
              addr       <= addr + {burst_len, 2'b00};
              remain     <= remain_after;
              if (remain_after == 0) begin
                state    <= IDLE;
                cmd_done <= 1'b1;
              end else begin
                state <= AR;
              end
            end
          end
        end

        // wr_idx = beat_cnt here, so wr_word is valid by the time W starts
        AW: if (M_AXI_AWREADY) state <= W;

        W: begin
          if (w_fire) begin
            beat_cnt   <= beat_cnt + 1'b1;
            burst_beat <= burst_beat + 1'b1;
            if (last_in_burst) state <= B;
          end
        end

        B: begin
          if (M_AXI_BVALID) begin
            if (M_AXI_BRESP != 2'b00) cmd_err <= 1'b1;
            burst_beat <= 8'd0;
            addr       <= addr + {burst_len, 2'b00};
            remain     <= remain_after;
            if (remain_after == 0) begin
              state    <= IDLE;
              cmd_done <= 1'b1;
            end else begin
              state <= AW;
            end
          end
        end

        default: state <= IDLE;
      endcase
    end
  end

endmodule
