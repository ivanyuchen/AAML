// UART packet: K, M, N; A and B words (4 INT8 bytes each).
// Logical lane 0 arrives first and occupies the most significant byte.
// Response: M words of four little-endian INT32 lanes, then uint32 cycles.
module uart_controller #(
    parameter memory_depth = 1024,
    parameter memory_bits = 16,
    parameter BRAM_READ_LATENCY = 1
)(
    input wire clk, rst_n,
    input wire load_enable, tpu_done,
    input wire [7:0] rx_data,
    input wire rx_valid,
    output reg [7:0] tx_data,
    output reg tx_start,
    input wire tx_busy,
    output reg [7:0] K_value, M_value, N_value,
    output reg config_valid, load_done,
    output reg A_wr_en,
    output reg [15:0] A_index,
    output reg [31:0] A_data_in,
    output reg B_wr_en,
    output reg [15:0] B_index,
    output reg [31:0] B_data_in,
    output reg [15:0] C_index,
    input wire [127:0] C_data_out,
    output reg send_done,
    input wire [31:0] execution_cycles
);
    localparam RX_WAIT_ENABLE=0, RX_GET_K=1, RX_GET_M=2,
               RX_GET_N=3, RX_GET_A=4, RX_GET_B=5, RX_WAIT_RELEASE=6;
    reg [2:0] rx_state;
    reg [15:0] a_words, a_count, b_count;
    reg [31:0] rx_word;
    reg [1:0] rx_lane;

    localparam [2:0] TX_IDLE=0, TX_WAIT_BRAM=1, TX_SEND_BYTE=2,
        TX_WAIT_BUSY=3, TX_WAIT_DONE=4, TX_SEND_CYCLE_BYTE=5,
        TX_WAIT_CYCLE_BUSY=6, TX_WAIT_CYCLE_DONE=7;
    reg [2:0] tx_state;
    reg [31:0] C_word_count, C_word_counter, bram_wait_counter;
    reg [127:0] tx_word;
    reg [3:0] tx_byte_count;
    reg [1:0] cycle_byte_count;
    reg tpu_done_d;
    reg [31:0] tx_execution_cycles;

    function [7:0] select_tx_byte;
        input [127:0] data_word;
        input [3:0] byte_number;
        integer bit_offset;
        begin
            bit_offset = 96 - 32 * (byte_number / 4) + 8 * (byte_number % 4);
            select_tx_byte = data_word[bit_offset +: 8];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_state <= RX_WAIT_ENABLE;
            K_value <= 0; M_value <= 0; N_value <= 0;
            config_valid <= 0; load_done <= 0;
            A_wr_en <= 0; B_wr_en <= 0;
            A_index <= 0; B_index <= 0;
            A_data_in <= 0; B_data_in <= 0;
            a_words <= 0; a_count <= 0; b_count <= 0;
            rx_word <= 0; rx_lane <= 0;
        end else begin
            config_valid <= 0;
            load_done <= 0;
            A_wr_en <= 0;
            B_wr_en <= 0;
            if (!load_enable) begin
                rx_state <= RX_WAIT_ENABLE;
                a_count <= 0; b_count <= 0;
                rx_word <= 0; rx_lane <= 0;
            end else begin
                case (rx_state)
                    RX_WAIT_ENABLE: rx_state <= RX_GET_K;
                    RX_GET_K: if (rx_valid) begin
                        K_value <= rx_data;
                        rx_state <= RX_GET_M;
                    end
                    RX_GET_M: if (rx_valid) begin
                        M_value <= rx_data;
                        rx_state <= RX_GET_N;
                    end
                    RX_GET_N: if (rx_valid) begin
                        N_value <= rx_data;
                        config_valid <= 1;
                        a_words <= (({8'd0, M_value} + 16'd3) >> 2) * {8'd0, K_value};
                        a_count <= 0; b_count <= 0;
                        rx_lane <= 0; rx_word <= 0;
                        rx_state <= RX_GET_A;
                    end
                    RX_GET_A: if (rx_valid) begin
                        rx_word <= {rx_word[23:0], rx_data};
                        if (rx_lane == 3) begin
                            A_data_in <= {rx_word[23:0], rx_data};
                            A_index <= a_count;
                            A_wr_en <= 1;
                            a_count <= a_count + 1'b1;
                            rx_lane <= 0;
                            if (a_count + 16'd1 == a_words)
                                rx_state <= RX_GET_B;
                        end else rx_lane <= rx_lane + 1'b1;
                    end
                    RX_GET_B: if (rx_valid) begin
                        rx_word <= {rx_word[23:0], rx_data};
                        if (rx_lane == 3) begin
                            B_data_in <= {rx_word[23:0], rx_data};
                            B_index <= b_count;
                            B_wr_en <= 1;
                            b_count <= b_count + 1'b1;
                            rx_lane <= 0;
                            if (b_count + 16'd1 == {8'd0, K_value})
                                rx_state <= RX_WAIT_RELEASE;
                        end else rx_lane <= rx_lane + 1'b1;
                    end
                    RX_WAIT_RELEASE: begin
                        // The last B write commits on this edge.
                        if (B_wr_en) load_done <= 1;
                    end
                    default: rx_state <= RX_WAIT_ENABLE;
                endcase
            end
        end
    end

//
// UART transmission controller
//
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tx_state          <= TX_IDLE;

        tx_data           <= 8'd0;
        tx_start          <= 1'b0;
        send_done         <= 1'b0;

        C_index           <= {memory_bits{1'b0}};
        C_word_count      <= 32'd0;
        C_word_counter    <= 32'd0;

        bram_wait_counter <= 32'd0;
        tx_word           <= 128'd0;
        tx_byte_count     <= 4'd0;
        cycle_byte_count  <= 2'd0;

        tpu_done_d        <= 1'b0;
        tx_execution_cycles <= 32'd0;
    end
    else begin
        tpu_done_d <= tpu_done;

        // Pulse-type outputs
        tx_start  <= 1'b0;
        send_done <= 1'b0;

        case (tx_state)

            TX_IDLE: begin
                tx_byte_count     <= 4'd0;
                cycle_byte_count  <= 2'd0;
                C_word_counter    <= 32'd0;
                bram_wait_counter <= 32'd0;

                //
                // Start only on the rising edge of tpu_done.
                //
                if (tpu_done && !tpu_done_d) begin
                    C_index <= {memory_bits{1'b0}};
                    tx_execution_cycles <= execution_cycles;

                    //
                    // C_word_count = ceil(N / 4) * M
                    //
                    C_word_count <=
                        ((({24'd0, N_value} + 32'd3) >> 2) *
                          {24'd0, M_value});

                    if ((M_value == 8'd0) || (N_value == 8'd0)) begin // the special case, do not send any bit
                        cycle_byte_count <= 2'd0;
                        tx_state <= TX_SEND_CYCLE_BYTE;
                    end
                    else begin
                        tx_state <= TX_WAIT_BRAM;
                    end
                end
            end

            //
            // C_index was changed before entering this state.
            // Wait for the synchronous BRAM output.
            //
            TX_WAIT_BRAM: begin
                if (bram_wait_counter < BRAM_READ_LATENCY) begin
                    bram_wait_counter <= bram_wait_counter + 32'd1;
                end
                else begin // the data can be read from BRAM
                    tx_word           <= C_data_out;
                    tx_byte_count     <= 4'd0;
                    bram_wait_counter <= 32'd0;
                    tx_state          <= TX_SEND_BYTE;
                end
            end

            //
            // Submit one byte to uart_tx.
            //
            TX_SEND_BYTE: begin
                if (!tx_busy) begin
                    tx_data  <= select_tx_byte(tx_word, tx_byte_count);
                    tx_start <= 1'b1;
                    tx_state <= TX_WAIT_BUSY;
                end
            end

            //
            // Wait until uart_tx accepts tx_start and raises tx_busy.
            //
            TX_WAIT_BUSY: begin
                if (tx_busy)
                    tx_state <= TX_WAIT_DONE;
            end

            //
            // Wait until transmission of the current byte finishes.
            //
            TX_WAIT_DONE: begin
                if (!tx_busy) begin
                    if (tx_byte_count == 4'd15) begin
                        if ((C_word_counter + 32'd1) >= C_word_count) begin // finish sending the C matrix data
                            cycle_byte_count <= 2'd0;
                            tx_state <= TX_SEND_CYCLE_BYTE;
                        end
                        else begin
                            C_word_counter    <= C_word_counter + 32'd1;
                            C_index           <= C_index + 1'b1;
                            tx_byte_count     <= 4'd0;
                            bram_wait_counter <= 32'd0;
                            tx_state          <= TX_WAIT_BRAM; // wait bram to read another data
                        end
                    end
                    else begin
                        tx_byte_count <= tx_byte_count + 1'b1;
                        tx_state      <= TX_SEND_BYTE; // keep sending bytes, until 16 bytes
                    end
                end
            end

            TX_SEND_CYCLE_BYTE: begin
                if (!tx_busy) begin
                    case (cycle_byte_count)
                        2'd0: tx_data <= tx_execution_cycles[7:0];
                        2'd1: tx_data <= tx_execution_cycles[15:8];
                        2'd2: tx_data <= tx_execution_cycles[23:16];
                        2'd3: tx_data <= tx_execution_cycles[31:24];
                    endcase
                    tx_start <= 1'b1;
                    tx_state <= TX_WAIT_CYCLE_BUSY;
                end
            end

            TX_WAIT_CYCLE_BUSY: begin
                if (tx_busy)
                    tx_state <= TX_WAIT_CYCLE_DONE;
            end

            TX_WAIT_CYCLE_DONE: begin
                if (!tx_busy) begin
                    if (cycle_byte_count == 2'd3) begin
                        send_done <= 1'b1;
                        tx_state <= TX_IDLE;
                    end
                    else begin
                        cycle_byte_count <= cycle_byte_count + 1'b1;
                        tx_state <= TX_SEND_CYCLE_BYTE;
                    end
                end
            end

            default: begin
                tx_state  <= TX_IDLE;
                tx_start  <= 1'b0;
                send_done <= 1'b0;
            end
        endcase
    end
end

endmodule
