//============================================================================//
// AAML Lab 3-1 - 4x4 row-stationary convolution accelerator                  //
// file: TESTBENCH.v                                                          //
// description: top-level convolution testbench                               //
//============================================================================//


`timescale 1ns/10ps
`include "PATTERN.v"
`include "TPU.v"

module TESTBENCH;



//* CHIP io wires
wire            clk, rst_n;
wire            in_valid;
wire [7:0]      M;
wire [7:0]      N;
wire            busy;
wire            A_ram_en;
wire [15:0]     A_index;
wire [31:0]     A_data_out;
wire            B_ram_en;
wire [15:0]     B_index;
wire [31:0]     B_data_out;
wire            C_ram_en;
wire            C_wr_en;
wire [15:0]     C_index;
wire [127:0]    C_data_in;
wire [127:0]    C_data_out;


initial begin
    `ifdef RTL
        // $fsdbDumpfile("dump.fsdb"); // fsdb if you want
        // $fsdbDumpvars(0,"+mda");
	
	$dumpfile("dump.vcd");
	$dumpvars(0, TESTBENCH);
    `endif
end


PATTERN My_Pattern(
    .clk            (clk),     
    .rst_n          (rst_n),     
    .in_valid       (in_valid),         
    .M              (M), 
    .N              (N), 
    .busy           (busy),     
    .A_ram_en       (A_ram_en),
    .A_index        (A_index),         
    .A_data_out     (A_data_out),         
    .B_ram_en       (B_ram_en),
    .B_index        (B_index),         
    .B_data_out     (B_data_out),         
    .C_ram_en       (C_ram_en),
    .C_wr_en        (C_wr_en),         
    .C_index        (C_index),         
    .C_data_in      (C_data_in),         
    .C_data_out     (C_data_out)         
);




TPU My_TPU(
    .clk            (clk),     
    .rst_n          (rst_n),     
    .in_valid       (in_valid),         
    .M              (M), 
    .N              (N), 
    .busy           (busy),     
    .A_ram_en       (A_ram_en),
    .A_index        (A_index),         
    .A_data_out     (A_data_out),         
    .B_ram_en       (B_ram_en),
    .B_index        (B_index),         
    .B_data_out     (B_data_out),         
    .C_ram_en       (C_ram_en),
    .C_wr_en        (C_wr_en),         
    .C_index        (C_index),         
    .C_data_in      (C_data_in),         
    .C_data_out     (C_data_out)         
);




endmodule
