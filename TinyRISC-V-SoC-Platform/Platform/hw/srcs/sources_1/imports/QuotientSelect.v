module QuotientSelect (
    input [65:0] r_1_i, //sign + 65 bits
    input [65:0] r_2_i, //sign + 65 bits
    input [33:0] d, //sign + 33 bits
    input [33:0] neg_d,

    input [31:0] pos_q,
    input [31:0] neg_q,

    output [65:0] r_1_o,
    output [65:0] r_2_o,
    output reg [31:0] pos_q_o,
    output reg [31:0] neg_q_o
);

    //Input: remainder in carry-save format
    //       divisor
    //       quotient
    //Output: above data in the next iteration
    
    wire [65:0] r_1, r_2;

    // 4r estimate in units of 2^60; |4r| reaches 8/3*d (~43 units), so keep all 8 bits signed
    wire signed [7:0] pre_add_r;

    assign pre_add_r = r_1_i[65:58] + r_2_i[65:58];

    // Shift by 2 is modulo 2^66, so the new top 6 bits are pre_add_r[5:0]
    assign r_1 = {pre_add_r[5:0], r_1_i[57:0], 2'b0};
    assign r_2 = {6'b0,           r_2_i[57:0], 2'b0};

    // Selection thresholds per d[30:28] (d[31]=1 after normalization), valid for carry-save error < 2 units
    reg signed [7:0] m_n1, m_0, m_1, m_2;

    always @(*) begin
        case (d[30:28])
            3'd0: begin m_n1 = -8'sd13; m_0 = -8'sd4; m_1 = 8'sd4; m_2 = 8'sd12; end
            3'd1: begin m_n1 = -8'sd15; m_0 = -8'sd5; m_1 = 8'sd5; m_2 = 8'sd14; end
            3'd2: begin m_n1 = -8'sd16; m_0 = -8'sd5; m_1 = 8'sd5; m_2 = 8'sd15; end
            3'd3: begin m_n1 = -8'sd17; m_0 = -8'sd6; m_1 = 8'sd5; m_2 = 8'sd17; end
            3'd4: begin m_n1 = -8'sd19; m_0 = -8'sd7; m_1 = 8'sd6; m_2 = 8'sd19; end
            3'd5: begin m_n1 = -8'sd20; m_0 = -8'sd7; m_1 = 8'sd6; m_2 = 8'sd20; end
            3'd6: begin m_n1 = -8'sd22; m_0 = -8'sd7; m_1 = 8'sd7; m_2 = 8'sd21; end
            default: begin m_n1 = -8'sd24; m_0 = -8'sd8; m_1 = 8'sd8; m_2 = 8'sd23; end
        endcase
    end

    wire [2:0] q;

    assign q = (pre_add_r >= m_2)  ? 3'b010 :
               (pre_add_r >= m_1)  ? 3'b001 :
               (pre_add_r >= m_0)  ? 3'b000 :
               (pre_add_r >= m_n1) ? 3'b111 : 3'b110;

    reg [65:0] sub;

    Compressor32 #(.WIDTH(66)) m_Compressor32(
        .in1(r_1),
        .in2(r_2),
        .in3(sub),
        .out1(r_1_o),
        .out2(r_2_o)
    );

    always @(*) begin
        case(q)
            3'b000: begin
                sub = 0;
                pos_q_o = {pos_q[29:0], 2'b00};
                neg_q_o = {neg_q[29:0], 2'b00};
            end
            3'b001: begin
                sub = {neg_d, 32'b0};
                pos_q_o = {pos_q[29:0], 2'b01};
                neg_q_o = {neg_q[29:0], 2'b00};
            end
            3'b010: begin
                sub = {(neg_d << 1), 32'b0};
                pos_q_o = {pos_q[29:0], 2'b10};
                neg_q_o = {neg_q[29:0], 2'b00};
            end
            3'b111: begin
                sub = {d, 32'b0};
                pos_q_o = {pos_q[29:0], 2'b00};
                neg_q_o = {neg_q[29:0], 2'b01};
            end
            3'b110: begin
                sub = {(d << 1), 32'b0};
                pos_q_o = {pos_q[29:0], 2'b00};
                neg_q_o = {neg_q[29:0], 2'b10};
            end
            default: begin
                sub = 0;
                pos_q_o = {pos_q[29:0], 2'b00};
                neg_q_o = {neg_q[29:0], 2'b10};
            end
        endcase
    end

endmodule
