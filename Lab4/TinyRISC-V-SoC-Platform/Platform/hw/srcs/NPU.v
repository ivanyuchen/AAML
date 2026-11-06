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
    output reg [3:0] M_AXI_WSTRB,
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
    assign M_AXI_BREADY  = 1'b1;

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
    localparam STATE_ADD   = 4'd9;   // funct3=0 (other funct7) stock add
    // Lab1 states (single-beat AXI read/write, SIMD4 MAC)
    localparam L1_READ     = 4'd10;
    localparam L1_WRITE    = 4'd11;
    localparam L1_SEND_ADDR= 4'd12;
    localparam L1_COMP     = 4'd13;
    // Logistic
    localparam LOGISTIC    = 4'd14;

    reg [3:0] state_r;
    reg [3:0] next_state;

    //Self defined NPU Signals
    reg [8:0] N;
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

    // Lab1 signals
    reg signed [31:0] acc_r;
    reg signed [31:0] offset;
    reg stage;
    wire misaligned_addr = (rs1_i[1:0] != 2'b00);
    wire signed [31:0] mac_sum;
    NPU_mac4_simd u_mac4_simd (
        .offset(offset), .a_bytes(rs1_i), .b_bytes(rs2_i), .sum(mac_sum)
    );

    reg [7:0] expect_beats;
    reg [7:0] received_beats;
    reg read_error;

    wire ptr_flag = (Ptr1_Current_addr <= Ptr1_Ending_addr);

    reg load_only;                       // 1: LOAD_PTR1/2 -> go to DONE after read, no compute
    reg single_rd;                       // 1: current op is Lab1 single-beat read
    // Lab1 single-beat read (funct3=1) forces ARLEN=0; Lab2 burst read otherwise.
    assign M_AXI_ARLEN   = single_rd ? 8'h00 : (ptr_flag) ?
        ((Ptr1_Burst_Ending_addr - Ptr1_Current_addr) >= 12) ? 8'h03 : (Ptr1_Burst_Ending_addr[7:0] - Ptr1_Current_addr[7:0])>>2:
        ((Ptr2_Burst_Ending_addr - Ptr2_Current_addr) >= 12) ? 8'h03 : (Ptr2_Burst_Ending_addr[7:0] - Ptr2_Current_addr[7:0])>>2;

    // Four parallel MAC lanes (see NPU_mac.v).
    wire [31:0] lane_in_bytes  = {ptr1_buffer[ptr1_compute_byte + 3], ptr1_buffer[ptr1_compute_byte + 2],
                                  ptr1_buffer[ptr1_compute_byte + 1], ptr1_buffer[ptr1_compute_byte]};
    wire [31:0] lane_flt_bytes = {ptr2_buffer[ptr2_compute_byte + 3], ptr2_buffer[ptr2_compute_byte + 2],
                                  ptr2_buffer[ptr2_compute_byte + 1], ptr2_buffer[ptr2_compute_byte]};
    wire signed [31:0] compute_sum;
    NPU_mac4_lanes u_mac4_lanes (
        .input_offset(input_offset),
        .in_bytes(lane_in_bytes), .flt_bytes(lane_flt_bytes),
        .ptr1_byte(ptr1_compute_byte), .ptr1_end(ptr1_compute_end_index),
        .ptr2_byte(ptr2_compute_byte), .ptr2_end(ptr2_compute_end_index),
        .sum(compute_sum)
    );
    //==========================================================================
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
    //  1      -       AXI_READ        Lab1      single-beat read, rs1 = addr
    //                                           (misaligned ok), NPU_out = data
    //  2      -       AXI_WRITE       Lab1      single-beat write, rs1 = addr,
    //                                           rs2 = data (misaligned ok,
    //                                           uses WSTRB), done after B resp
    //  3      0       MAC_CONFIG      Lab2      KEEP (Conv uses hw_simd_mac).
    //                                           rs1 = N, rs2 = input_offset
    //  3      1       MAC_LOAD_PTR1   Lab2      rs1 = ptr1 (rs2 unused). Burst-reads
    //                                           N bytes into buffer 1. NPU_out = 0
    //  3      2       MAC_LOAD_PTR2   Lab2      rs1 = ptr2 (rs2 unused). Burst-reads
    //                                           N bytes into buffer 2. NPU_out = 0
    //  3      3       MAC_COMPUTE     Lab2      no read. NPU_out = sum over N of
    //                                           buf1[i]+off) * buf2[i]
    //                                           (needs CONFIG, PTR1, PTR2 first)
    //  4      -       LOGISTIC        Lab4      sigmoid of one element.
    //                                           rs1 = signed Q4.27 raw input
    //                                           NPU_out = Q0.31 raw result
    //                                           (sigmoid(0) = 1<<30; saturation,
    //                                           rounding, clamp stay in SW)
    //  5      0..4    TRANSPOSE_CFG   Lab4      write a config register:
    //                                             0: rs1 = input base addr
    //                                                rs2 = output base addr
    //                                             1: rs1 = rank
    //                                                rs2 = element size (bytes)
    //                                             2: rs1 = dim d
    //                                                rs2 = output_shape[d]
    //                                             3: rs1 = dim d
    //                                                rs2 = input_stride[perm[d]]
    //                                             4: rs1 = dim d
    //                                                rs2 = output_stride[d]
    //  6      -       TRANSPOSE_START Lab4      launch; NPU moves all elements
    //                                           over its AXI master. NPU_done
    //                                           only after the last write
    //                                           response. NPU_out = 0 ok /
    //                                           nonzero error code.
    //  7      -       (free)                    spare
    //
    // Rules:
    //  - Do not change funct3 = 0/1/2 (Lab1) or 3 (Lab2): Lab4 spec says
    //    preserve the Lab1/Lab2 instructions (Conv uses funct3 = 3).
    //  - funct3_i is 4 bits wide but the instruction carries only 3.
    //  - SW mirrors this table via cfu_op3 / cfu_op4 / cfu_op5 / cfu_op6
    //    (or cfu_raw_op(funct3, funct7, rs1, rs2)).
    //  - Transpose: CPU never touches tensor data; it only does cfg writes,
    //    start, wait, and the cache clean/invalidate around the call.
    //==========================================================================



    wire logistic_done;
    wire signed [31:0] logistic_result;
    Logistic u_logistic (
        .clk(clk), .rst_n(rst_n),
        .input_a(rs1_i),
        .done(logistic_done),
        .result(logistic_result)
    );

    //==========================================================================
    // FSM part 1/3: state register (sequential, only holds the state)
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state_r <= STATE_IDLE;
        else        state_r <= next_state;
    end

    //==========================================================================
    // FSM part 2/3: next-state logic (combinational, decides ONLY the state)
    // Pure function of state_r and the inputs; no datapath assignments here.
    //==========================================================================
    always @(*) begin
        next_state = state_r;                       // default: stay
        case (state_r)
            STATE_IDLE: begin
                if (NPU_start) begin
                    case (funct3_i[2:0])
                        3'd0: begin                 // Lab1 MAC / stock add
                            if (funct7_i == 7'd0 || funct7_i == 7'd1 || funct7_i == 7'd2)
                                next_state = L1_COMP;
                            else
                                next_state = STATE_ADD;
                        end
                        3'd1: next_state = L1_SEND_ADDR;      // Lab1 single read
                        3'd2: next_state = L1_WRITE;          // Lab1 single write
                        3'd3: begin                           // Lab2 MAC
                            case (funct7_i[6:0])
                                7'd0:    next_state = STATE_DONE;   // CONFIG
                                7'd1:    next_state = STATE_BURST;  // LOAD_PTR1
                                7'd2:    next_state = STATE_BURST;  // LOAD_PTR2
                                7'd3:    next_state = SET_INDEX;    // COMPUTE
                                default: next_state = STATE_DONE;
                            endcase
                        end
                        3'd4: next_state = LOGISTIC;          // Lab4 logistic
                        default: next_state = STATE_DONE;
                    endcase
                end
            end

            // ---- Lab1 single-beat AXI read / write / MAC ----
            L1_SEND_ADDR: if (M_AXI_ARREADY) next_state = L1_READ;
            L1_READ: begin
                if (M_AXI_RVALID) begin
                    if (misaligned_addr && stage == 1'b0) next_state = L1_SEND_ADDR; // 2nd word
                    else                                  next_state = STATE_DONE;
                end
            end
            L1_WRITE: begin
                if (M_AXI_BVALID && M_AXI_BREADY) begin
                    if (misaligned_addr && stage == 1'b0) next_state = L1_WRITE;     // 2nd write
                    else                                  next_state = STATE_DONE;
                end
            end
            L1_COMP:   next_state = STATE_DONE;
            STATE_ADD: next_state = STATE_DONE;
            LOGISTIC:  if (logistic_done) next_state = STATE_DONE;

            // ---- Lab2 burst read + MAC ----
            STATE_BURST: begin
                if (Ptr1_Current_addr > Ptr1_Ending_addr && Ptr2_Current_addr > Ptr2_Ending_addr)
                    next_state = load_only ? STATE_DONE : SET_INDEX;
                else
                    next_state = READ;
            end
            READ:      next_state = SEND_ADDR;
            SEND_ADDR: if (M_AXI_ARREADY && M_AXI_ARVALID) next_state = READ_DATA;
            READ_DATA: begin
                if (M_AXI_RVALID && M_AXI_RREADY && M_AXI_RLAST) begin
                    if (read_error || M_AXI_RRESP != 2'b00 || received_beats + 1 != expect_beats)
                        next_state = STATE_DONE;
                    else
                        next_state = ADDR_ADD;
                end
            end
            ADDR_ADD:  next_state = STATE_BURST;
            SET_INDEX: next_state = STATE_COMP;
            STATE_COMP: begin
                if (ptr1_compute_byte + 3 >= ptr1_compute_end_index &&
                    ptr2_compute_byte + 3 >= ptr2_compute_end_index)
                    next_state = STATE_DONE;
            end

            STATE_DONE: next_state = STATE_IDLE;
            default:    next_state = STATE_IDLE;
        endcase
    end

    //==========================================================================
    // FSM part 3/3: datapath / output registers (sequential).
    // Selected by state_r; it never assigns state_r.
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
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
            M_AXI_WSTRB             <= 4'b1111;
            acc_r                   <= 32'sd0;
            offset                  <= 32'sd0;
            stage                   <= 1'b0;
            single_rd               <= 1'b0;
            load_only               <= 1'b0;
        end else begin
            NPU_done <= 1'b0;
            case (state_r)
                STATE_IDLE: begin
                    NPU_done <= 1'b0;
                    if (NPU_start) begin
                        single_rd <= (funct3_i[2:0] == 3'd1);
                        if (funct3_i[2:0] == 3'd3) begin
                            if(funct7_i[6:0] == 7'd0) begin
                                N <= rs1_i[8:0];
                                input_offset <= $signed(rs2_i[8:0]);

                            end else if(funct7_i[6:0] == 7'd1) begin
                                // LOAD_PTR1: only read ptr1. ptr2 is marked "already done"
                                // (current addr past its end) so the read loop skips it.
                                Ptr1_Starting_addr <= rs1_i;
                                Ptr1_Current_addr <= {rs1_i[31:2], 2'b00};
                                Ptr2_Current_addr <= 32'hFFFF_FFFF;
                                ptr1_buffer_index <= 32'd0;
                                load_only <= 1'b1;

                            end else if(funct7_i[6:0] == 7'd2) begin
                                // LOAD_PTR2: only read ptr2. ptr1 is marked "already done".
                                Ptr2_Starting_addr <= rs1_i;
                                Ptr2_Current_addr <= {rs1_i[31:2], 2'b00};
                                Ptr1_Current_addr <= 32'hFFFF_FFFF;
                                ptr2_buffer_index <= 32'd0;
                                load_only <= 1'b1;

                            end else if(funct7_i[6:0] == 7'd3) begin
                                // COMPUTE: both buffers are already loaded.
                                load_only <= 1'b0;

                            end else begin
                            end
                        end else if (funct3_i[2:0] == 3'd0) begin
                            // Lab1 MAC / stock add: no setup needed, the next state does the work.
                        end else if (funct3_i[2:0] == 3'd1) begin
                            // Lab1 single AXI read (handles misaligned address)
                            M_AXI_ARADDR  <= misaligned_addr ? {rs1_i[31:2], 2'b00} : rs1_i;
                            M_AXI_ARVALID <= 1'b1;
                        end else if (funct3_i[2:0] == 3'd2) begin
                            // Lab1 single AXI write (handles misaligned address)
                            if (misaligned_addr) begin
                                M_AXI_AWADDR <= {rs1_i[31:2], 2'b00};
                                M_AXI_WDATA  <= (rs2_i << rs1_i[1:0]*8);
                                M_AXI_WSTRB  <= (4'b1111 << rs1_i[1:0]);
                            end else begin
                                M_AXI_AWADDR <= rs1_i;
                                M_AXI_WDATA  <= rs2_i;
                                M_AXI_WSTRB  <= 4'b1111;
                            end
                            M_AXI_WLAST   <= 1'b1;
                            M_AXI_AWVALID <= 1'b1;
                            M_AXI_WVALID  <= 1'b1;
                        end else begin
                        end

                    end

                end
                L1_SEND_ADDR: begin
                    if (M_AXI_ARREADY) begin
                        M_AXI_ARVALID <= 1'b0;
                    end
                end
                L1_READ: begin
                    if (misaligned_addr) begin
                        if (M_AXI_RVALID) begin
                            if (stage == 1'b0) begin
                                NPU_out <= M_AXI_RDATA >> (rs1_i[1:0] * 8);
                                M_AXI_ARADDR <= {rs1_i[31:2] + 1'b1, 2'b00};
                                M_AXI_ARVALID <= 1'b1;
                                stage   <= 1'b1;
                            end else begin
                                NPU_out <= NPU_out | (M_AXI_RDATA << (32 - rs1_i[1:0] * 8));
                                stage   <= 1'b0;
                            end
                        end
                    end else begin
                        if (M_AXI_RVALID) begin
                            NPU_out <= M_AXI_RDATA;
                        end
                    end
                end
                L1_WRITE: begin
                    if (M_AXI_AWREADY && M_AXI_AWVALID) M_AXI_AWVALID <= 1'b0;
                    if (M_AXI_WREADY && M_AXI_WVALID)   M_AXI_WVALID  <= 1'b0;
                    if (M_AXI_BVALID && M_AXI_BREADY) begin
                        if (!misaligned_addr) begin
                            stage   <= 1'b0;
                        end else if (stage == 1'b0) begin
                            M_AXI_AWADDR  <= {rs1_i[31:2] + 1'b1, 2'b00};
                            M_AXI_WDATA   <= rs2_i >> (32 - rs1_i[1:0] * 8);
                            M_AXI_WSTRB   <= 4'b1111 >> (4 - rs1_i[1:0]);
                            M_AXI_WLAST   <= 1'b1;
                            M_AXI_AWVALID <= 1'b1;
                            M_AXI_WVALID  <= 1'b1;
                            stage         <= 1'b1;
                        end else begin
                            stage   <= 1'b0;
                        end
                    end
                end
                L1_COMP: begin
                    if (funct7_i == 7'd0) begin
                        NPU_out <= 32'b0;
                        acc_r   <= 32'b0;
                    end else if (funct7_i == 7'd1) begin
                        offset <= rs1_i;
                    end else if (funct7_i == 7'd2) begin
                        acc_r   <= acc_r + mac_sum;
                        NPU_out <= acc_r + mac_sum;
                    end
                end
                STATE_ADD: begin
                    NPU_out <= rs1_i + rs2_i + funct7_i;
                end
                STATE_BURST: begin
                    if(Ptr1_Current_addr > Ptr1_Ending_addr && Ptr2_Current_addr > Ptr2_Ending_addr) begin
                    end else begin
                    end

                    Ptr1_Burst_Ending_addr <= ({Ptr1_Current_addr[31:12], 12'hFFF} <= Ptr1_Ending_addr) ? {Ptr1_Burst_Starting_addr[31:12], 12'hFFF} : Ptr1_Ending_addr;
                    Ptr2_Burst_Ending_addr <= ({Ptr2_Current_addr[31:12], 12'hFFF} <= Ptr2_Ending_addr) ? {Ptr2_Burst_Starting_addr[31:12], 12'hFFF} : Ptr2_Ending_addr;
                end
                READ: begin

                end
                SEND_ADDR: begin
                    M_AXI_ARADDR <= ptr_flag ? Ptr1_Current_addr : Ptr2_Current_addr;
                    M_AXI_ARVALID <= 1'b1;
                    if(M_AXI_ARREADY && M_AXI_ARVALID) begin
                        M_AXI_ARVALID <= 1'b0;
                        received_beats <= 8'd0;
                        expect_beats <= M_AXI_ARLEN + 1;
                        read_error <= 1'b0;
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
                            end else begin
                            end
                        end
                    end
                end
                SET_INDEX: begin
                    ptr1_compute_byte <= ptr1_compute_start_index;
                    ptr2_compute_byte <= ptr2_compute_start_index;
                    accum <= 32'd0;
                end
                STATE_COMP: begin
                    accum <= accum + compute_sum;
                    ptr1_compute_byte <= ptr1_compute_byte + 4;
                    ptr2_compute_byte <= ptr2_compute_byte + 4;
                    if(ptr1_compute_byte + 3 >= ptr1_compute_end_index && ptr2_compute_byte + 3 >= ptr2_compute_end_index) begin
                        NPU_out <= accum + compute_sum;
                    end
                end
                ADDR_ADD: begin
                    if(ptr_flag) begin
                        Ptr1_Current_addr <= Ptr1_Current_addr + ((M_AXI_ARLEN + 1) * 4);
                    end else begin
                        Ptr2_Current_addr <= Ptr2_Current_addr + ((M_AXI_ARLEN + 1) * 4);
                    end
                end
                LOGISTIC: begin
                    NPU_out <= logistic_result;
                end



                STATE_DONE: begin
                    NPU_done <= 1'b1;
                end

                default: ;
            endcase
        end
    end
endmodule
