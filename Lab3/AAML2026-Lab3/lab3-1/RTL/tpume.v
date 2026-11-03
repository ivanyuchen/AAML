`timescale 1ns/10ps
`include "PE.v"

// 4x4 row-stationary convolution, C[oy][ox] = sum A[oy+ky][ox+kx] * B[ky][kx].
// A is column major (one read = 4 vertical pixels), so a "row" here is a
// whole kernel column kx.  PE[r][k] stores kernel column kx = 4g+k (all ky);
// the four PEs of one array column hold the same kernel column.
// Array row r works on output row oy+r.  All rows see the same input words,
// row r shifted down by r pixels (bytes r..r+3 of the previous and current
// word), so a single A read feeds all 16 PEs.  Each PE needs KT words of an
// input column to finish its column product (KT+1 reads because of the
// shift), then the partial sums move PE[r][0] -> PE[r][3].  PE[r][3] yields
// one output of row oy+r per column step, accumulated in obuf over the
// kernel groups g.  After all groups, the four output rows are written to C.
module TPU(
    input              clk,
    input              rst_n,
    input              in_valid,
    input      [7:0]   M,
    input      [7:0]   N,
    output reg         busy,

    output reg         A_ram_en,
    output reg [15:0]  A_index,
    input      [31:0]  A_data_out,

    output reg         B_ram_en,
    output reg [15:0]  B_index,
    input      [31:0]  B_data_out,

    output reg         C_ram_en,
    output reg         C_wr_en,
    output reg [15:0]  C_index,
    output reg [127:0] C_data_in,
    input      [127:0] C_data_out
);

localparam IDLE        = 3'd0,
           LOAD_WEIGHT = 3'd1,
           STREAM      = 3'd2,
           DRAIN       = 3'd3,
           WRITE       = 3'd4,
           FINISH      = 3'd5;

// filter row loading
reg  [3:0]  load;                   // one bit per array column, e.g. 4'b0001 << load_col
reg  [5:0]  load_addr;
wire [31:0] filter_in = B_ram_en ? B_data_out : 32'd0;

// streaming, shared by all 16 PEs
reg  [5:0]  weight_sel;
reg         first;
reg         last;

reg  [31:0] cur_word, prev_word;    // current and previous input word
wire [63:0] input_window = {prev_word, cur_word};   // 8 consecutive pixels, top pixel in the MSBs

genvar gi, gj;
generate
    for (gi = 0; gi < 4; gi = gi + 1) begin : row
        // input_val[gj] / psum_in[gj] enter PE[gi][gj], [gj+1] leaves it
        wire [31:0] input_val [0:4];
        wire [31:0] psum_in   [0:4];
        assign input_val[0] = input_window[63-8*gi -: 32];   // row gi is shifted down gi pixels
        assign psum_in[0]   = 32'd0;

        for (gj = 0; gj < 4; gj = gj + 1) begin : col
            PE pe(
                .clk(clk), .rst_n(rst_n),
                .load(load[gj]), .load_addr(load_addr), .filter_in(filter_in),
                .weight_sel(weight_sel), .first(first), .last(last),
                .input_val(input_val[gj]), .psum_in(psum_in[gj]),
                .pass_val(input_val[gj+1]), .partial_sum(psum_in[gj+1])
            );
        end
    end
endgenerate

always @(posedge clk or negedge rst_n) begin
    case(state)
        IDLE: if (in_valid) begin
            M_reg         <= M;
            N_reg         <= N;
            out_size      <= {8'd0, M} - {8'd0, N} + 16'd1;
            out_tiles     <= ({8'd0, M} - {8'd0, N} + 16'd4) >> 2;
            kernel_words  <= ({8'd0, N} + 16'd3) >> 2;
            kernel_groups <= ({8'd0, N} + 16'd3) >> 2;
            step <= 16'd0; out_row_base <= 16'd0; word_idx <= 16'd0; group <= 16'd0;
            load_col <= 2'd0; write_row <= 2'd0;
            busy  <= 1'b1;
            state <= LOAD_WEIGHT;
        end 
        LOAD_WEIGHT: begin
            B_ram_en  <= (kernel_col < {8'd0, N_reg});
            B_index   <= B_addr;
            load_sel  <= 4'd1 << load_col;
            load_addr <= word_idx[5:0];
            if (!last_weight_word) word_idx <= word_idx + 16'd1;
            else begin
                word_idx <= 16'd0;
                if (load_col == 2'd3) begin load_col <= 2'd0; state <= STREAM; end
                else load_col <= load_col + 2'd1;
            end
        end

end



endmodule
