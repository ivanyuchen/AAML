`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// bram_sdp: simple dual-port RAM with SYNCHRONOUS read (1-cycle latency).
//   - one write port, one read port, same clock
//   - data_o is the word at read_addr_i sampled on the previous posedge
//   - written in Xilinx's inference template so Vivado maps it to BRAM
// -----------------------------------------------------------------------------
module bram_sdp
#(parameter ENTRY_NUM = 4096,
  parameter DWIDTH    = 32,
  parameter AWIDTH    = $clog2(ENTRY_NUM))
(
    input                     clk_i,
    input                     we_i,
    input      [AWIDTH-1 : 0] read_addr_i,
    input      [AWIDTH-1 : 0] write_addr_i,
    input      [DWIDTH-1 : 0] data_i,
    output reg [DWIDTH-1 : 0] data_o
);

(* ram_style = "block" *)
reg [DWIDTH-1 : 0] RAM [ENTRY_NUM-1 : 0];

always @(posedge clk_i) begin
    if (we_i)
        RAM[write_addr_i] <= data_i;
end

always @(posedge clk_i) begin
    data_o <= RAM[read_addr_i];
end

endmodule
