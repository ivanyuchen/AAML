`timescale 1ns / 1ps

module clean_cache (
    input clk_i,
    input rst_n,
    // One-cycle accepted instruction request, NOT the raw is_npu decode level.
    // The CPU must hold the instruction operands until npu_done.
    input is_npu_i,
    input mem_busy,
    input mem_write_back_valid,  // Kept for interface compatibility; busy tracks drain.
    input req_i,

    input  clean_all_done,
    input  npu_done,
    output clean_all_o,
    output invalidate_all_o,
    output npu_start
);

  localparam IDLE = 3'd0, WAIT_MEM = 3'd1, CLEAN = 3'd2, START = 3'd3, WAIT_NPU = 3'd4;
  reg [2:0] state_r, next_state;

  // Keep the cache request asserted until it acknowledges completion.
  // Cache writeback + invalidation and request arbitration are implemented
  // outside this controller; clean_all_done must cover that whole operation.
  assign clean_all_o = rst_n && (state_r == CLEAN);
  assign npu_start   = rst_n && (state_r == START);
  // Mode for the cache walk: write back dirty lines AND invalidate all lines.
  // This must be connected to corresponding logic in dcache_pro.
  assign invalidate_all_o = rst_n && (state_r == CLEAN);
  always @(posedge clk_i or negedge rst_n) begin
    if (!rst_n) state_r <= IDLE;
    else state_r <= next_state;
  end

  always @(*) begin
    next_state = state_r;
    case (state_r)
      IDLE: if (is_npu_i) next_state = WAIT_MEM;
      // No completion pulse is required if MEM was already idle.
      WAIT_MEM: if (!req_i && !mem_busy) next_state = CLEAN;
      CLEAN: if (clean_all_done) next_state = START;
      START: next_state = WAIT_NPU;
      WAIT_NPU: if (npu_done) next_state = IDLE;
      default: next_state = IDLE;
    endcase
  end
endmodule
