module PE (
    input  wire               clk,
    input  wire               input_valid,
    input  wire               clr_accum,
    input  wire signed [7:0]  a_in,
    input  wire signed [7:0]  b_in,
    output wire signed [23:0] psum_next
);

reg  signed [23:0] psum;
wire signed [15:0] prod = a_in * b_in;

assign psum_next = (clr_accum ? 24'sd0 : psum) + prod;

always @(posedge clk) begin
    if (input_valid) psum <= psum_next;
end

endmodule
