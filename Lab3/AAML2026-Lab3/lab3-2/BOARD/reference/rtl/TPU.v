module TPU #(
    parameter A_WIDTH = 8,
    parameter B_WIDTH = 8,
    parameter PSUM_WIDTH = 32
)(
    input                         clk,
    input                         rst_n,

    input                         in_valid,
    input      [7:0]              K,
    input      [7:0]              M,
    input      [7:0]              N,
    output reg                    busy,

    output                        A_ram_en,
    output                        A_wr_en,
    output     [15:0]             A_index,
    output     [A_WIDTH*4-1:0]    A_data_in,
    input      [A_WIDTH*4-1:0]    A_data_out,

    output                        B_ram_en,
    output                        B_wr_en,
    output     [15:0]             B_index,
    output     [B_WIDTH*4-1:0]    B_data_in,
    input      [B_WIDTH*4-1:0]    B_data_out,

    output                        C_ram_en,
    output                        C_wr_en,
    output     [15:0]             C_index,
    output     [127:0]            C_data_in,
    input      [127:0]            C_data_out
);

reg        busy_r;
reg        run;
reg  [7:0] k_last_r;
reg  [5:0] blk_last_r;
reg  [1:0] row_tail_r;
reg  [9:0] addr_r;
reg  [7:0] k_r;
reg  [5:0] blk_r;
reg  [2:0] since_start;

reg        valid_d;
reg        first_d;
reg        last_d;
reg  [5:0] blk_d;

reg  [1:0] write_left;
reg  [7:0] write_row;
reg  signed [23:0] hold1, hold2, hold3;

wire start = in_valid && !busy_r;

wire [7:0] k_last   = start ? K - 8'd1 : k_last_r;
wire [5:0] blk_last = start ? (M - 8'd1) >> 2 : blk_last_r;
wire [7:0] k_cur    = start ? 8'd0 : k_r;
wire [5:0] blk_cur  = start ? 6'd0 : blk_r;
wire [9:0] addr_cur = start ? 10'd0 : addr_r;

wire issue   = start || (run && (k_r != 8'd0 || since_start[2]));
wire k_end   = (k_cur == k_last);
wire blk_end = (blk_cur == blk_last);
wire run_n   = issue ? !(k_end && blk_end) : run;

wire signed [23:0] psum [0:3];

genvar i;
generate
    for (i = 0; i < 4; i = i + 1) begin : pe_array
        PE pe (
            .clk         (clk),
            .input_valid (valid_d),
            .clr_accum   (first_d),
            .a_in        (A_data_out[31-8*i -: 8]),
            .b_in        (B_data_out[31:24]),
            .psum_next   (psum[i])
        );
    end
endgenerate

wire       block_done = valid_d && last_d;
wire [1:0] block_rows = (blk_d == blk_last_r) ? row_tail_r : 2'd3;
wire [1:0] write_left_n = block_done ? block_rows :
                          (write_left != 2'd0) ? write_left - 2'd1 : 2'd0;
wire signed [23:0] write_val = block_done ? psum[0] : hold1;

assign A_ram_en  = issue;
assign A_wr_en   = 1'b0;
assign A_index   = {6'd0, addr_cur};
assign A_data_in = {A_WIDTH*4{1'b0}};

assign B_ram_en  = issue;
assign B_wr_en   = 1'b0;
assign B_index   = {8'd0, k_cur};
assign B_data_in = {B_WIDTH*4{1'b0}};

assign C_ram_en  = block_done || (write_left != 2'd0);
assign C_wr_en   = C_ram_en;
assign C_index   = {8'd0, block_done ? {blk_d, 2'b00} : write_row};
assign C_data_in = {{8{write_val[23]}}, write_val, 96'd0};

always @(*) begin
    busy = busy_r || in_valid;
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        busy_r      <= 1'b0;
        run         <= 1'b0;
        k_last_r    <= 8'd0;
        blk_last_r  <= 6'd0;
        row_tail_r  <= 2'd0;
        addr_r      <= 10'd0;
        k_r         <= 8'd0;
        blk_r       <= 6'd0;
        since_start <= 3'd4;
        valid_d     <= 1'b0;
        first_d     <= 1'b0;
        last_d      <= 1'b0;
        blk_d       <= 6'd0;
        write_left  <= 2'd0;
        write_row   <= 8'd0;
    end
    else begin
        busy_r     <= run_n || issue || (write_left_n != 2'd0);
        run        <= run_n;
        write_left <= write_left_n;

        if (start) begin
            k_last_r   <= k_last;
            blk_last_r <= blk_last;
            row_tail_r <= M[1:0] - 2'd1;
        end

        valid_d <= issue;
        first_d <= (k_cur == 8'd0);
        last_d  <= k_end;
        blk_d   <= blk_cur;

        if (issue) begin
            addr_r <= addr_cur + 10'd1;
            if (k_end) begin
                k_r   <= 8'd0;
                blk_r <= blk_cur + 6'd1;
            end
            else begin
                k_r   <= k_cur + 8'd1;
                blk_r <= blk_cur;
            end
        end

        if (issue && k_cur == 8'd0) since_start <= 3'd1;
        else if (!since_start[2])   since_start <= since_start + 3'd1;

        if (block_done)               write_row <= {blk_d, 2'b01};
        else if (write_left != 2'd0)  write_row <= write_row + 8'd1;
    end
end

always @(posedge clk) begin
    if (block_done) begin
        hold1 <= psum[1];
        hold2 <= psum[2];
        hold3 <= psum[3];
    end
    else if (write_left != 2'd0) begin
        hold1 <= hold2;
        hold2 <= hold3;
    end
end

endmodule
