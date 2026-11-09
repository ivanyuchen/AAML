`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// MAC datapaths used by NPU.v.
//   NPU_mac4_simd  : Lab1  funct3=0, funct7=2   4 bytes of rs1/rs2 -> one sum
//                    (products registered: sum is valid 1 cycle after inputs)
//   NPU_mac4_lanes : Lab2  funct3=3, funct7=3   4 lanes with per-lane valid
//                    (pure combinational)
//////////////////////////////////////////////////////////////////////////////////

// Lab1: sum_{i=0..3} (rs1.byte[i] + offset) * rs2.byte[i]
// The 4 products are registered, then summed combinationally: one cycle
// for (byte + offset) * byte, a second (in the caller) for the adder tree.
module NPU_mac4_simd (
    input                clk,
    input  signed [31:0] offset,
    input         [31:0] a_bytes,   // rs1: 4 signed int8 (input)
    input         [31:0] b_bytes,   // rs2: 4 signed int8 (filter)
    output reg signed [31:0] sum
);
    reg signed [31:0] product [0:3];
    integer i;
    always @(posedge clk) begin
        for (i = 0; i < 4; i = i + 1)
            product[i] <= ($signed(a_bytes[i*8 +: 8]) + offset) * $signed(b_bytes[i*8 +: 8]);
    end
    always @(*) begin
        sum = 32'sd0;
        for (i = 0; i < 4; i = i + 1) sum = sum + product[i];
    end
endmodule

// Lab2: four parallel MAC lanes over the two on-chip buffers.
// The top level reads 4 bytes from each buffer (starting at ptrX_byte) and
// passes them in; lanes whose byte index is past ptrX_end are masked to 0.
module NPU_mac4_lanes (
    input  signed [8:0]  input_offset,
    input         [31:0] in_bytes,     // buffer1[byte+3 : byte]  (byte+0 in [7:0])
    input         [31:0] flt_bytes,    // buffer2[byte+3 : byte]
    input         [31:0] ptr1_byte,    // current index in buffer 1
    input         [31:0] ptr1_end,     // last valid index in buffer 1
    input         [31:0] ptr2_byte,
    input         [31:0] ptr2_end,
    output signed [31:0] sum
);
    wire [3:0] valid;
    genvar k;
    generate
        for (k = 0; k < 4; k = k + 1) begin : g_valid
            assign valid[k] = (ptr1_byte + k <= ptr1_end) &&
                              (ptr2_byte + k <= ptr2_end);
        end
    endgenerate

    wire signed [8:0]  lane_in   [0:3];
    wire signed [7:0]  lane_flt  [0:3];
    wire signed [16:0] lane_prod [0:3];
    wire signed [31:0] lane_res  [0:3];
    generate
        for (k = 0; k < 4; k = k + 1) begin : g_lane
            assign lane_in[k]   = $signed({in_bytes[k*8+7], in_bytes[k*8 +: 8]}) + input_offset;
            assign lane_flt[k]  = $signed(flt_bytes[k*8 +: 8]);
            assign lane_prod[k] = lane_in[k] * lane_flt[k];
            assign lane_res[k]  = valid[k] ? {{15{lane_prod[k][16]}}, lane_prod[k]} : 32'sd0;
        end
    endgenerate

    assign sum = lane_res[0] + lane_res[1] + lane_res[2] + lane_res[3];
endmodule
