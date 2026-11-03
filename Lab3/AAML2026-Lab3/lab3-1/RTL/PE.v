module PE (
    input             clk,
    input             rst_n,

    input             load,
    input      [5:0]  load_addr,
    input      [31:0] filter_in,

    input      [5:0]  weight_sel,
    input             first,
    input             last,
    input      [31:0] input_val,
    input      [31:0] psum_in,
    output     [31:0] pass_val,
    output reg [31:0] partial_sum
);

reg [31:0] filter_mem [0:63];
reg [31:0] accum;

assign pass_val = input_val;

wire [31:0] weight_word = filter_mem[weight_sel];
wire [31:0] dot_product = weight_word[31:24] * input_val[31:24]
                        + weight_word[23:16] * input_val[23:16]
                        + weight_word[15:8]  * input_val[15:8]
                        + weight_word[7:0]   * input_val[7:0];
wire [31:0] accum_next  = (first ? 32'd0 : accum) + dot_product;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        accum       <= 32'd0;
        partial_sum <= 32'd0;
    end
    else begin
        accum <= accum_next;
        if (last) partial_sum <= psum_in + accum_next;
    end
end

always @(posedge clk) begin
    if (load) filter_mem[load_addr] <= filter_in;
end

endmodule
