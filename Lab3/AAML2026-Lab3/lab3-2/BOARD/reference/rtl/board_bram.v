// Simple dual-port synchronous block RAM, one-cycle read latency.
// The interface uses 16-bit word addresses; only DEPTH physical words exist.
// Host validation ensures addresses remain in range. No memory reset is used,
// allowing Vivado to infer BRAM. The top-level FSM explicitly clears C.
module board_bram #(
    parameter DATA_WIDTH = 16,
    parameter DEPTH = 1024
)(
    input wire clka,
    input wire ena,
    input wire wea,
    input wire [15:0] addra,
    input wire [DATA_WIDTH-1:0] dina,
    input wire clkb,
    input wire enb,
    input wire [15:0] addrb,
    output reg [DATA_WIDTH-1:0] doutb
);
    localparam ADDR_BITS = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
    (* ram_style = "block" *) reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    always @(posedge clka)
        if (ena && wea) mem[addra[ADDR_BITS-1:0]] <= dina;
    always @(posedge clkb)
        if (enb) doutb <= mem[addrb[ADDR_BITS-1:0]];
endmodule
