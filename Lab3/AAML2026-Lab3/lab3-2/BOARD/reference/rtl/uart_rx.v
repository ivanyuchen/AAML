module uart_rx #(
    parameter CLK_FREQ  = 100_000_000,
    parameter BAUD_RATE = 115_200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,
    output reg [7:0]  rx_data, // send 1 byte in one time
    output reg        rx_valid
);

localparam integer CLKS_PER_BIT  = CLK_FREQ / BAUD_RATE;
localparam integer HALF_BIT_CLKS = CLKS_PER_BIT / 2;

localparam S_IDLE  = 3'd0;
localparam S_START = 3'd1;
localparam S_DATA  = 3'd2;
localparam S_STOP  = 3'd3;

reg [2:0] state;
reg [15:0] clk_count;
reg [2:0] bit_index;
reg [7:0] data_buf;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state     <= S_IDLE;
        clk_count <= 16'd0;
        bit_index <= 3'd0;
        data_buf  <= 8'd0;
        rx_data   <= 8'd0;
        rx_valid  <= 1'b0;
    end else begin
        rx_valid <= 1'b0;

        case (state)
            S_IDLE: begin
                clk_count <= 16'd0;
                bit_index <= 3'd0;
                if (rx == 1'b0)
                    state <= S_START;
            end

            S_START: begin
                if (clk_count == HALF_BIT_CLKS - 1) begin // for fear the noise detected in S_IDLE, double check the rx = 1'b0 after half bit clks
                    clk_count <= 16'd0;
                    if (rx == 1'b0)
                        state <= S_DATA; // start to transfer the data(1 byte)
                    else
                        state <= S_IDLE;
                end else begin
                    clk_count <= clk_count + 1'b1;
                end
            end

            S_DATA: begin
                if (clk_count == CLKS_PER_BIT - 1) begin // take the data from rx in this cycle
                    clk_count <= 16'd0;
                    data_buf[bit_index] <= rx;

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
                if (clk_count == CLKS_PER_BIT - 1) begin
                    clk_count <= 16'd0;
                    rx_data   <= data_buf;
                    rx_valid  <= 1'b1; // send data to the bram
                    state     <= S_IDLE;
                end else begin
                    clk_count <= clk_count + 1'b1;
                end
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule