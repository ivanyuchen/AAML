module uart_tx #(
    parameter CLK_FREQ  = 100_000_000,
    parameter BAUD_RATE = 115_200
)(
    input  wire      clk,
    input  wire      rst_n,
    input  wire [7:0] tx_data,
    input  wire      tx_start,
    output reg       tx,
    output reg       tx_busy
);

localparam integer CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;

localparam S_IDLE  = 2'd0;
localparam S_START = 2'd1;
localparam S_DATA  = 2'd2;
localparam S_STOP  = 2'd3;

reg [1:0] state;
reg [15:0] clk_count;
reg [2:0] bit_index;
reg [7:0] data_buf;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state     <= S_IDLE;
        clk_count <= 16'd0;
        bit_index <= 3'd0;
        data_buf  <= 8'd0;
        tx        <= 1'b1;
        tx_busy   <= 1'b0;
    end else begin
        case (state)
            S_IDLE: begin
                tx      <= 1'b1;
                tx_busy <= 1'b0;
                clk_count <= 16'd0;
                bit_index <= 3'd0;

                if (tx_start) begin
                    tx_busy  <= 1'b1;
                    data_buf <= tx_data;
                    state    <= S_START;
                end
            end

            S_START: begin
                tx <= 1'b0;
                if (clk_count == CLKS_PER_BIT - 1) begin
                    clk_count <= 16'd0;
                    state <= S_DATA;
                end else begin
                    clk_count <= clk_count + 1'b1;
                end
            end

            S_DATA: begin
                tx <= data_buf[bit_index];
                if (clk_count == CLKS_PER_BIT - 1) begin
                    clk_count <= 16'd0;
                    if (bit_index == 3'd7) begin
                        bit_index <= 3'd0;
                        state <= S_STOP;
                    end else begin
                        bit_index <= bit_index + 1'b1;
                    end
                end else begin
                    clk_count <= clk_count + 1'b1;
                end
            end

            S_STOP: begin
                tx <= 1'b1;
                if (clk_count == CLKS_PER_BIT - 1) begin
                    clk_count <= 16'd0;
                    state <= S_IDLE;
                end else begin
                    clk_count <= clk_count + 1'b1;
                end
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule