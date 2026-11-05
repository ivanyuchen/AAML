`timescale 1ns/10ps
`include "PE.v"

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

reg [2:0]  state;
reg [7:0]  M_reg, N_reg;
reg [15:0] out_size;
reg [15:0] out_tiles;
reg [15:0] kernel_words;
reg [15:0] kernel_groups;
reg [15:0] step;
reg [15:0] out_row_base;
reg [15:0] word_idx;
reg [15:0] group;
reg [1:0]  load_col;
reg [1:0]  write_row;

wire [15:0] kernel_col = {group[13:0], 2'b00} + {14'd0, load_col};
wire [15:0] input_col  = {group[13:0], 2'b00} + step;
wire [15:0] input_row  = out_row_base + {word_idx[13:0], 2'b00};
wire [15:0] A_addr     = input_col * ({8'd0, M_reg} + 16'd3) + input_row;
wire [15:0] B_addr     = word_idx * {8'd0, N_reg} + kernel_col;

wire last_group       = (group == kernel_groups - 16'd1);
wire last_weight_word = (word_idx == kernel_words - 16'd1);
wire last_input_word  = (word_idx == kernel_words);
wire last_row_block   = (out_row_base + 16'd4 >= out_size);
wire last_write_row   = (write_row == 2'd3) || (out_row_base + {14'd0, write_row} + 16'd1 >= out_size);

reg  [3:0]  load_sel;
reg  [5:0]  load_addr;
reg  [31:0] cur_word, prev_word;
reg         first_d0, last_d0, first_d1, last_d1;
reg  [5:0]  weight_sel_d0, weight_sel_d1;
wire [31:0] weight_data  = B_ram_en ? B_data_out : 32'd0;
wire [63:0] input_window = {prev_word, cur_word};

reg        out_valid_d0, out_valid_d1, out_valid_d2;
reg        out_first_d0, out_first_d1, out_first_d2;
reg [7:0]  out_col_d0, out_col_d1, out_col_d2;

wire [7:0]   write_base = {step[5:0], 2'b00};
wire [3:0]   write_mask = {({8'd0, write_base} + 16'd0) < out_size, ({8'd0, write_base} + 16'd1) < out_size,
                           ({8'd0, write_base} + 16'd2) < out_size, ({8'd0, write_base} + 16'd3) < out_size};
wire [511:0] write_words;

genvar r, k;
generate
for (r = 0; r < 4; r = r + 1) begin : row
    wire [32*5-1:0] input_chain, psum_chain;
    assign input_chain[31:0] = input_window[63-8*r -: 32];
    assign psum_chain[31:0]  = 32'd0;

    for (k = 0; k < 4; k = k + 1) begin : pcol
        PE pe(.clk(clk), .rst_n(rst_n), .load(load_sel[k]), .load_addr(load_addr), .filter_in(weight_data),
              .weight_sel(weight_sel_d1), .first(first_d1), .last(last_d1),
              .input_val(input_chain[32*k +: 32]), .psum_in(psum_chain[32*k +: 32]),
              .pass_val(input_chain[32*(k+1) +: 32]), .partial_sum(psum_chain[32*(k+1) +: 32]));
    end

    reg [31:0] out_buf [0:255];
    always @(posedge clk) begin
        if (out_valid_d2) out_buf[out_col_d2] <= (out_first_d2 ? 32'd0 : out_buf[out_col_d2]) + psum_chain[159:128];
    end

    assign write_words[128*r +: 128] = {write_mask[3] ? out_buf[write_base]        : 32'd0,
                                        write_mask[2] ? out_buf[write_base + 8'd1] : 32'd0,
                                        write_mask[1] ? out_buf[write_base + 8'd2] : 32'd0,
                                        write_mask[0] ? out_buf[write_base + 8'd3] : 32'd0};
end
endgenerate

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= IDLE; busy <= 1'b0;
        A_ram_en <= 1'b0; B_ram_en <= 1'b0; C_ram_en <= 1'b0; C_wr_en <= 1'b0;
        A_index <= 16'd0; B_index <= 16'd0; C_index <= 16'd0; C_data_in <= 128'd0;
        M_reg <= 8'd0; N_reg <= 8'd0;
        out_size <= 16'd0; out_tiles <= 16'd0; kernel_words <= 16'd0; kernel_groups <= 16'd0;
        step <= 16'd0; out_row_base <= 16'd0; word_idx <= 16'd0; group <= 16'd0;
        load_col <= 2'd0; write_row <= 2'd0;
        load_sel <= 4'd0; load_addr <= 6'd0; cur_word <= 32'd0; prev_word <= 32'd0;
        first_d0 <= 1'b0; last_d0 <= 1'b0; first_d1 <= 1'b0; last_d1 <= 1'b0;
        weight_sel_d0 <= 6'd0; weight_sel_d1 <= 6'd0;
        out_valid_d0 <= 1'b0; out_valid_d1 <= 1'b0; out_valid_d2 <= 1'b0;
        out_first_d0 <= 1'b0; out_first_d1 <= 1'b0; out_first_d2 <= 1'b0;
        out_col_d0 <= 8'd0; out_col_d1 <= 8'd0; out_col_d2 <= 8'd0;
    end
    else begin
        A_ram_en <= 1'b0; B_ram_en <= 1'b0; C_ram_en <= 1'b0; C_wr_en <= 1'b0;
        load_sel <= 4'd0;
        first_d0 <= 1'b0; last_d0 <= 1'b0; out_valid_d0 <= 1'b0;

        cur_word  <= A_ram_en ? A_data_out : 32'd0;
        prev_word <= cur_word;
        first_d1 <= first_d0; last_d1 <= last_d0; weight_sel_d1 <= weight_sel_d0;
        out_valid_d1 <= out_valid_d0; out_valid_d2 <= out_valid_d1;
        out_first_d1 <= out_first_d0; out_first_d2 <= out_first_d1;
        out_col_d1   <= out_col_d0;   out_col_d2   <= out_col_d1;

        case (state)
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

        STREAM: begin
            A_ram_en      <= (input_col < {8'd0, M_reg}) && (input_row < {8'd0, M_reg});
            A_index       <= A_addr;
            first_d0      <= (word_idx == 16'd1);
            last_d0       <= last_input_word;
            weight_sel_d0 <= word_idx[5:0] - 6'd1;
            out_valid_d0  <= last_input_word && (step >= 16'd3);
            out_col_d0    <= step[7:0] - 8'd3;
            out_first_d0  <= (group == 16'd0);
            if (!last_input_word) word_idx <= word_idx + 16'd1;
            else begin
                word_idx <= 16'd0;
                if (step != out_size + 16'd2) step <= step + 16'd1;
                else begin
                    step <= 16'd0;
                    if (!last_group) begin group <= group + 16'd1; state <= LOAD_WEIGHT; end
                    else begin group <= 16'd0; state <= DRAIN; end
                end
            end
        end

        DRAIN: if (step == 16'd2) begin step <= 16'd0; state <= WRITE; end
               else step <= step + 16'd1;

        WRITE: begin
            C_ram_en  <= 1'b1;
            C_wr_en   <= 1'b1;
            C_index   <= (out_row_base + {14'd0, write_row}) * out_tiles + step;
            C_data_in <= write_words[128*write_row +: 128];
            if (step == out_tiles - 16'd1) begin
                step <= 16'd0;
                if (!last_write_row) write_row <= write_row + 2'd1;
                else begin
                    write_row <= 2'd0;
                    if (last_row_block) state <= FINISH;
                    else begin out_row_base <= out_row_base + 16'd4; state <= LOAD_WEIGHT; end
                end
            end
            else step <= step + 16'd1;
        end

        FINISH: begin busy <= 1'b0; state <= IDLE; end

        default: state <= IDLE;
        endcase
    end
end

endmodule
