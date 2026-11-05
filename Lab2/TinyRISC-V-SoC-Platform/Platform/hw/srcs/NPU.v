`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2025/09/21 19:38:15
// Design Name: 
// Module Name: dcache_axiBus_bridge
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


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
    //output  [3:0] M_AXI_AWID,
    output reg [31:0] M_AXI_AWADDR,
    output [7:0] M_AXI_AWLEN,
    output [2:0] M_AXI_AWSIZE,
    output [1:0] M_AXI_AWBURST,
    output M_AXI_AWLOCK,
    output [3:0] M_AXI_AWCACHE,
    output [2:0] M_AXI_AWPROT,
    output [3:0] M_AXI_AWQOS,
    output [15:0] M_AXI_AWUSER,
    output reg M_AXI_AWVALID,
    input M_AXI_AWREADY,
    // W Channel
    output reg [31:0] M_AXI_WDATA,
    output [3:0] M_AXI_WSTRB,
    output reg M_AXI_WLAST,
    output reg M_AXI_WVALID,
    input M_AXI_WREADY,

    // B Channel
    //input [3:0] M_AXI_BID,
    input [1:0] M_AXI_BRESP,
    //input [15:0] M_AXI_BUSER,
    input M_AXI_BVALID,
    output M_AXI_BREADY,

    // AR Channel
    //output  [3:0] M_AXI_ARID,
    output reg [31:0] M_AXI_ARADDR,
    output [7:0] M_AXI_ARLEN,
    output [2:0] M_AXI_ARSIZE,
    output [1:0] M_AXI_ARBURST,
    output M_AXI_ARLOCK,
    output [3:0] M_AXI_ARCACHE,
    output [2:0] M_AXI_ARPROT,
    output [3:0] M_AXI_ARQOS,
    output [15:0] M_AXI_ARUSER,
    output reg M_AXI_ARVALID,
    input M_AXI_ARREADY,

    // R Channel
    input [3:0] M_AXI_RID,
    input [31:0] M_AXI_RDATA,
    input [1:0] M_AXI_RRESP,
    input M_AXI_RLAST,
    input M_AXI_RVALID,
    output M_AXI_RREADY
);
    assign M_AXI_AWLEN   = 8'h00;
    assign M_AXI_AWSIZE  = 3'b010;
    assign M_AXI_AWBURST = 2'b01;
    assign M_AXI_AWLOCK  = 1'b0;
    assign M_AXI_AWCACHE = 4'b0011;
    assign M_AXI_AWPROT  = 3'b000;
    assign M_AXI_AWQOS   = 4'b0000;
    assign M_AXI_AWUSER  = 16'h0000;
    assign M_AXI_WSTRB   = 4'b1111;
    assign M_AXI_BREADY  = 1'b1;

    assign M_AXI_ARLEN   = (ptr_flag) ?
        ((Ptr1_Burst_Ending_addr - Ptr1_Current_addr) >= 12) ? 8'h03 : (Ptr1_Burst_Ending_addr[7:0] - Ptr1_Current_addr[7:0])>>2:
        ((Ptr2_Burst_Ending_addr - Ptr2_Current_addr) >= 12) ? 8'h03 : (Ptr2_Burst_Ending_addr[7:0] - Ptr2_Current_addr[7:0])>>2;
    assign M_AXI_ARSIZE  = 3'b010;
    assign M_AXI_ARBURST = 2'b01;
    assign M_AXI_ARLOCK  = 1'b0;
    assign M_AXI_ARCACHE = 4'b0011;
    assign M_AXI_ARPROT  = 3'b000;
    assign M_AXI_ARQOS   = 4'b0000;
    assign M_AXI_ARUSER  = 16'h0000;
    assign M_AXI_RREADY  = 1'b1;

    localparam STATE_IDLE  = 4'd0;
    localparam STATE_BURST = 4'd1;
    localparam READ        = 4'd2;
    localparam SEND_ADDR   = 4'd3;
    localparam READ_DATA   = 4'd4;
    localparam ADDR_ADD    = 4'd5;
    localparam SET_INDEX   = 4'd6;
    localparam STATE_COMP  = 4'd7;
    localparam STATE_DONE  = 4'd8;

    reg [3:0] state_r;

    //Self defined NPU Signals
    reg [31:0] Ptr1_Starting_addr;
    wire [31:0] Ptr1_Ending_addr = Ptr1_Starting_addr + (N) - 1;
    reg [31:0] Ptr2_Starting_addr;
    wire [31:0] Ptr2_Ending_addr = Ptr2_Starting_addr + (N) - 1;

    wire [31:0] Ptr1_Burst_Starting_addr = Ptr1_Starting_addr;
    reg [31:0] Ptr1_Burst_Ending_addr;
    wire [31:0] Ptr2_Burst_Starting_addr = Ptr2_Starting_addr;
    reg [31:0] Ptr2_Burst_Ending_addr;

    reg [31:0] Ptr1_Current_addr;
    reg [31:0] Ptr2_Current_addr;

    reg [8:0] N;
    // Nine bits represent the public int8_t range and the extended +128 case.
    reg signed [8:0] input_offset;

    reg [7:0] ptr1_buffer [0:259];
    reg [7:0] ptr2_buffer [0:259];
    reg [31:0] ptr1_buffer_index;
    reg [31:0] ptr2_buffer_index;
    wire [31:0] ptr1_compute_start_index = {30'd0, Ptr1_Starting_addr[1:0]};
    wire [31:0] ptr2_compute_start_index = {30'd0, Ptr2_Starting_addr[1:0]};
    wire [31:0] ptr1_compute_end_index = ptr1_compute_start_index + N - 1;
    wire [31:0] ptr2_compute_end_index = ptr2_compute_start_index + N - 1;
    reg [31:0] ptr1_compute_byte;
    reg [31:0] ptr2_compute_byte;
    reg signed [31:0] accum;

    reg [7:0] expect_beats;
    reg [7:0] received_beats;
    reg read_error;

    wire ptr_flag = (Ptr1_Current_addr <= Ptr1_Ending_addr);

    // Four parallel MAC lanes.
    wire lane0_valid = (ptr1_compute_byte <= ptr1_compute_end_index) &&
                       (ptr2_compute_byte <= ptr2_compute_end_index);
    wire lane1_valid = (ptr1_compute_byte + 1 <= ptr1_compute_end_index) &&
                       (ptr2_compute_byte + 1 <= ptr2_compute_end_index);
    wire lane2_valid = (ptr1_compute_byte + 2 <= ptr1_compute_end_index) &&
                       (ptr2_compute_byte + 2 <= ptr2_compute_end_index);
    wire lane3_valid = (ptr1_compute_byte + 3 <= ptr1_compute_end_index) &&
                       (ptr2_compute_byte + 3 <= ptr2_compute_end_index);

    wire signed [8:0] lane0_input = $signed({ptr1_buffer[ptr1_compute_byte][7], ptr1_buffer[ptr1_compute_byte]}) + input_offset;
    wire signed [8:0] lane1_input = $signed({ptr1_buffer[ptr1_compute_byte + 1][7], ptr1_buffer[ptr1_compute_byte + 1]}) + input_offset;
    wire signed [8:0] lane2_input = $signed({ptr1_buffer[ptr1_compute_byte + 2][7], ptr1_buffer[ptr1_compute_byte + 2]}) + input_offset;
    wire signed [8:0] lane3_input = $signed({ptr1_buffer[ptr1_compute_byte + 3][7], ptr1_buffer[ptr1_compute_byte + 3]}) + input_offset;

    wire signed [7:0] lane0_filter = $signed(ptr2_buffer[ptr2_compute_byte]);
    wire signed [7:0] lane1_filter = $signed(ptr2_buffer[ptr2_compute_byte + 1]);
    wire signed [7:0] lane2_filter = $signed(ptr2_buffer[ptr2_compute_byte + 2]);
    wire signed [7:0] lane3_filter = $signed(ptr2_buffer[ptr2_compute_byte + 3]);

    wire signed [16:0] lane0_product = lane0_input * lane0_filter;
    wire signed [16:0] lane1_product = lane1_input * lane1_filter;
    wire signed [16:0] lane2_product = lane2_input * lane2_filter;
    wire signed [16:0] lane3_product = lane3_input * lane3_filter;

    wire signed [31:0] lane0_result = lane0_valid ? {{15{lane0_product[16]}}, lane0_product} : 32'sd0;
    wire signed [31:0] lane1_result = lane1_valid ? {{15{lane1_product[16]}}, lane1_product} : 32'sd0;
    wire signed [31:0] lane2_result = lane2_valid ? {{15{lane2_product[16]}}, lane2_product} : 32'sd0;
    wire signed [31:0] lane3_result = lane3_valid ? {{15{lane3_product[16]}}, lane3_product} : 32'sd0;
    wire signed [31:0] compute_sum = lane0_result + lane1_result + lane2_result + lane3_result;
    // Instruction
/*
 * Lab 2 CUSTOM-0 instruction encoding
 *
 * opcode = 0x0B (CUSTOM-0)
 *
 * funct3 | funct7 | Command   | rs1  | rs2
 * ------------------------------------------------
 *    3   |    0   | CONFIG    | N    | input_offset
 *    3   |    1   | LOAD_PTR1 | ptr1 | ptr2
 *
 */


    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_r                 <= STATE_IDLE;
            NPU_out                 <= 32'd0;
            NPU_done                <= 1'b0;

            M_AXI_AWADDR            <= 32'd0;
            M_AXI_AWVALID           <= 1'b0;
            M_AXI_WDATA             <= 32'd0;
            M_AXI_WLAST             <= 1'b0;
            M_AXI_WVALID            <= 1'b0;
            M_AXI_ARADDR            <= 32'd0;
            M_AXI_ARVALID           <= 1'b0;

            Ptr1_Starting_addr      <= 32'd0;
            Ptr1_Burst_Ending_addr  <= 32'd0;
            Ptr1_Current_addr       <= 32'd0;
            Ptr2_Starting_addr      <= 32'd0;
            Ptr2_Burst_Ending_addr  <= 32'd0;
            Ptr2_Current_addr       <= 32'd0;
            N                       <= 9'd0;
            input_offset            <= 9'sd0;
            ptr1_buffer_index       <= 32'd0;
            ptr2_buffer_index       <= 32'd0;
            ptr1_compute_byte       <= 32'd0;
            ptr2_compute_byte       <= 32'd0;
            accum                   <= 32'sd0;
            expect_beats            <= 8'd0;
            received_beats          <= 8'd0;
            read_error              <= 1'b0;
        end else begin
            NPU_done <= 1'b0;
            case (state_r)
                STATE_IDLE: begin
                    NPU_done <= 1'b0;
                    if (NPU_start) begin
                        if (funct3_i[2:0] == 3'd3) begin
                            if(funct7_i[6:0] == 7'd0) begin
                                N <= rs1_i[8:0];
                                input_offset <= $signed(rs2_i[8:0]);
                                state_r <= STATE_DONE;

                            end else if(funct7_i[6:0] == 7'd1) begin
                                Ptr1_Starting_addr <= rs1_i;
                                Ptr2_Starting_addr <= rs2_i;
                                Ptr1_Current_addr <= {rs1_i[31:2], 2'b00};
                                Ptr2_Current_addr <= {rs2_i[31:2], 2'b00};
                                ptr1_buffer_index <= 32'd0;
                                ptr2_buffer_index <= 32'd0;
                                state_r <= STATE_BURST;

                            end else begin
                                state_r <= STATE_DONE;
                            end
                        end else begin
                            state_r <= STATE_DONE;
                        end

                    end

                end
                STATE_BURST: begin
                    if(Ptr1_Current_addr > Ptr1_Ending_addr && Ptr2_Current_addr > Ptr2_Ending_addr) begin
                        state_r <= SET_INDEX;
                    end else begin
                        state_r <= READ;
                    end

                    Ptr1_Burst_Ending_addr <= ({Ptr1_Current_addr[31:12], 12'hFFF} <= Ptr1_Ending_addr) ? {Ptr1_Burst_Starting_addr[31:12], 12'hFFF} : Ptr1_Ending_addr;
                    Ptr2_Burst_Ending_addr <= ({Ptr2_Current_addr[31:12], 12'hFFF} <= Ptr2_Ending_addr) ? {Ptr2_Burst_Starting_addr[31:12], 12'hFFF} : Ptr2_Ending_addr;
                end
                READ: begin

                    state_r <= SEND_ADDR;
                end
                SEND_ADDR: begin
                    M_AXI_ARADDR <= ptr_flag ? Ptr1_Current_addr : Ptr2_Current_addr;
                    M_AXI_ARVALID <= 1'b1;
                    if(M_AXI_ARREADY && M_AXI_ARVALID) begin
                        M_AXI_ARVALID <= 1'b0;
                        received_beats <= 8'd0;
                        expect_beats <= M_AXI_ARLEN + 1;
                        read_error <= 1'b0;
                        state_r <= READ_DATA;
                    end
                end
                READ_DATA: begin
                    if(M_AXI_RVALID && M_AXI_RREADY) begin
                        if(M_AXI_RRESP != 2'b00) begin
                            read_error <= 1'b1;
                        end

                        if(!read_error &&
                           M_AXI_RRESP == 2'b00 &&
                           received_beats + 1 <= expect_beats) begin
                            if(ptr_flag) begin
                                ptr1_buffer[ptr1_buffer_index]     <= M_AXI_RDATA[7:0];
                                ptr1_buffer[ptr1_buffer_index + 1] <= M_AXI_RDATA[15:8];
                                ptr1_buffer[ptr1_buffer_index + 2] <= M_AXI_RDATA[23:16];
                                ptr1_buffer[ptr1_buffer_index + 3] <= M_AXI_RDATA[31:24];
                                ptr1_buffer_index <= ptr1_buffer_index + 4;
                            end else begin
                                ptr2_buffer[ptr2_buffer_index]     <= M_AXI_RDATA[7:0];
                                ptr2_buffer[ptr2_buffer_index + 1] <= M_AXI_RDATA[15:8];
                                ptr2_buffer[ptr2_buffer_index + 2] <= M_AXI_RDATA[23:16];
                                ptr2_buffer[ptr2_buffer_index + 3] <= M_AXI_RDATA[31:24];
                                ptr2_buffer_index <= ptr2_buffer_index + 4;
                            end
                        end
                        received_beats <= received_beats + 1;

                        if(M_AXI_RLAST) begin
                            if(read_error || M_AXI_RRESP != 2'b00 ||received_beats + 1 != expect_beats) begin
                                state_r <= STATE_DONE;
                            end else begin
                                state_r <= ADDR_ADD;
                            end
                        end
                    end
                end
                SET_INDEX: begin
                    ptr1_compute_byte <= ptr1_compute_start_index;
                    ptr2_compute_byte <= ptr2_compute_start_index;
                    accum <= 32'd0;
                    state_r <= STATE_COMP;
                end
                STATE_COMP: begin
                    accum <= accum + compute_sum;
                    ptr1_compute_byte <= ptr1_compute_byte + 4;
                    ptr2_compute_byte <= ptr2_compute_byte + 4;
                    if(ptr1_compute_byte + 3 >= ptr1_compute_end_index && ptr2_compute_byte + 3 >= ptr2_compute_end_index) begin
                        NPU_out <= accum + compute_sum;
                        state_r <= STATE_DONE;
                    end
                end
                ADDR_ADD: begin
                    if(ptr_flag) begin
                        Ptr1_Current_addr <= Ptr1_Current_addr + ((M_AXI_ARLEN + 1) * 4);
                    end else begin
                        Ptr2_Current_addr <= Ptr2_Current_addr + ((M_AXI_ARLEN + 1) * 4);
                    end
                    state_r <= STATE_BURST;
                end



                STATE_DONE: begin
                    NPU_done <= 1'b1;
                    state_r  <= STATE_IDLE;
                end

                default: state_r <= STATE_IDLE;
            endcase
        end
    end
endmodule
