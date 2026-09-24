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


// 訊號方向以 NPU 為準：input 是外部送進來，output 是 NPU 送出去。
// 未指定型別的 input/output 預設是 wire，可由連線或 assign 驅動。
// reg 可在 always 區塊內賦值；是否形成暫存器，要看賦值方式。
// 下方 posedge clk 區塊中的 state_r、NPU_out、NPU_done 會形成暫存器。
module NPU (
    input clk,   // 系統時脈；在上升緣更新狀態、判定 AXI 握手。
    input rst_n, // 低電位有效的非同步 reset：0 時重設 NPU。

    // CPU Interface：CPU 發出自訂指令，NPU 完成後回傳結果。
    input      [31:0] rs1_i,   // 第一個運算元；AXI 讀/寫指令中是記憶體地址。
    input      [31:0] rs2_i,   // 第二個運算元；AXI 寫指令中是要寫入的 32-bit 資料。
    output reg [31:0] NPU_out, // 回傳 CPU 的結果；AXI 讀取時應放讀回的資料。
    input             NPU_start, // CPU 提出的啟動訊號；在 IDLE 接受新指令。
    output reg        NPU_done,  // 完成通知；目前在 DONE 狀態拉高一個 clock。

    input [ 3:0] funct3_i, // 操作種類，使用 [2:0]：001=AXI 讀，010=AXI 寫。
    input [31:0] funct7_i, // 子功能/附加參數；此介面用 32 bits 承接。

    // AXI4 Master Interface：NPU 主動發起交易，透過匯流排存取記憶體。
    // 每個 channel 都在 clock 上升緣 VALID && READY 時完成一次傳輸。
    // 傳送方不可等 READY 才拉高 VALID；等待握手時須保持 VALID 與內容穩定。
    // AW Channel：寫入地址，方向 NPU -> 記憶體端；與 W channel 獨立握手。
    //output  [3:0] M_AXI_AWID,
    output reg [31:0] M_AXI_AWADDR, // 要寫入的 byte 地址；本小題要求 4-byte 對齊。
    output [7:0] M_AXI_AWLEN,      // burst 的 beat 數減 1；0 表示只傳 1 beat。
    output [2:0] M_AXI_AWSIZE,     // 每個 beat 的 bytes = 2^AWSIZE；010 表示 4 bytes。
    output [1:0] M_AXI_AWBURST,    // burst 地址變化方式；01=INCR，依 beat 大小遞增。
    output M_AXI_AWLOCK,           // exclusive 存取屬性；0 表示一般存取。
    output [3:0] M_AXI_AWCACHE,    // 此筆交易的 buffer/cache 屬性，不會自動清除 CPU cache。
    output [2:0] M_AXI_AWPROT,     // 存取權限、安全性、指令/資料等屬性。
    output [3:0] M_AXI_AWQOS,      // 交易服務品質/優先權提示；目前固定 0。
    output [15:0] M_AXI_AWUSER,    // 自訂附加資訊；此範例未使用，固定 0。
    output reg M_AXI_AWVALID,     // NPU：目前寫入地址與屬性有效。
    input M_AXI_AWREADY,          // 記憶體端：現在可以接收寫入地址。
    // W Channel：寫入資料，方向 NPU -> 記憶體端。
    output reg [31:0] M_AXI_WDATA, // 要寫入的資料；共有 4 個 byte。
    output reg [3:0] M_AXI_WSTRB,      // byte 寫入遮罩；bit 0 對應 WDATA[7:0]，1111 表示全寫。
    output reg M_AXI_WLAST,       // 這是 burst 的最後一個 beat；單拍交易時應為 1。
    output reg M_AXI_WVALID,      // NPU：目前 WDATA/WSTRB/WLAST 有效。
    input M_AXI_WREADY,           // 記憶體端：現在可以接收寫入資料。

    // B Channel：寫入回應，方向 記憶體端 -> NPU；收到回應才算交易完成。
    //input [3:0] M_AXI_BID,
    input [1:0] M_AXI_BRESP, // 寫入回應碼：00=OKAY，10=SLVERR，11=DECERR。
    //input [15:0] M_AXI_BUSER,
    input M_AXI_BVALID,  // 記憶體端：目前有有效的寫入回應。
    output M_AXI_BREADY, // NPU：可以接收寫入回應；目前固定為 1。

    // AR Channel：讀取地址，方向 NPU -> 記憶體端。
    //output  [3:0] M_AXI_ARID,
    output reg [31:0] M_AXI_ARADDR, // 要讀取的 byte 地址；本小題要求 4-byte 對齊。
    output [7:0] M_AXI_ARLEN,      // burst 的 beat 數減 1；0 表示只讀 1 beat。
    output [2:0] M_AXI_ARSIZE,     // 每個 beat 的 bytes = 2^ARSIZE；010 表示 4 bytes。
    output [1:0] M_AXI_ARBURST,    // burst 地址變化方式；01=INCR。
    output M_AXI_ARLOCK,           // exclusive 存取屬性；0 表示一般存取。
    output [3:0] M_AXI_ARCACHE,    // 讀取交易的 buffer/cache 屬性；仍須由軟體維護 cache 一致性。
    output [2:0] M_AXI_ARPROT,     // 存取權限、安全性、指令/資料等屬性。
    output [3:0] M_AXI_ARQOS,      // 交易服務品質/優先權提示；目前固定 0。
    output [15:0] M_AXI_ARUSER,    // 自訂附加資訊；此範例未使用，固定 0。
    output reg M_AXI_ARVALID,     // NPU：目前讀取地址與屬性有效。
    input M_AXI_ARREADY,          // 記憶體端：現在可以接收讀取地址。

    // R Channel：讀回資料，方向 記憶體端 -> NPU。
    input [3:0] M_AXI_RID,    // 回傳資料的交易 ID；目前範例未使用。
    input [31:0] M_AXI_RDATA, // 記憶體讀回的 32-bit 資料；握手時才能視為接收成功。
    input [1:0] M_AXI_RRESP,  // 讀取回應碼：00=OKAY，10=SLVERR，11=DECERR。
    input M_AXI_RLAST,       // 記憶體端標記這是最後一個 beat；單拍交易應為 1。
    input M_AXI_RVALID,      // 記憶體端：目前 RDATA/RRESP/RLAST 有效。
    output M_AXI_RREADY      // NPU：現在可以接收讀回資料；目前固定為 1。
);
    // 以下 assign 持續輸出固定設定：單拍、每拍 4 bytes。
    assign M_AXI_AWLEN   = 8'h00;
    assign M_AXI_AWSIZE  = 3'b010;
    assign M_AXI_AWBURST = 2'b01;
    assign M_AXI_AWLOCK  = 1'b0;
    assign M_AXI_AWCACHE = 4'b0011;
    assign M_AXI_AWPROT  = 3'b000;
    assign M_AXI_AWQOS   = 4'b0000;
    assign M_AXI_AWUSER  = 16'h0000;
    assign M_AXI_BREADY  = 1'b1;    // 回應到達時就會握手，控制邏輯須在該上升緣處理。

    assign M_AXI_ARLEN   = 8'h00;
    assign M_AXI_ARSIZE  = 3'b010;
    assign M_AXI_ARBURST = 2'b01;
    assign M_AXI_ARLOCK  = 1'b0;
    assign M_AXI_ARCACHE = 4'b0011;
    assign M_AXI_ARPROT  = 3'b000;
    assign M_AXI_ARQOS   = 4'b0000;
    assign M_AXI_ARUSER  = 16'h0000;
    assign M_AXI_RREADY  = 1'b1; // 資料到達時就會握手，控制邏輯須在該上升緣取走資料。

    localparam STATE_IDLE = 3'd0; // 等待 CPU 的 NPU_start。
    localparam STATE_READ = 3'd1; // 執行 AXI 讀取。
    localparam STATE_WRITE = 3'd2; // 分別處理 AW/W 握手，並等待 B 回應。
    localparam STATE_SEND_ADDR = 3'd3; // 等待讀取地址握手。
    localparam STATE_COMP = 3'd4; // 執行原本的加法範例。
    localparam STATE_DONE = 3'd5; // 拉高 NPU_done，然後回到 IDLE。

    reg [2:0] state_r; // 保存狀態機目前狀態的 3-bit 暫存器。

    reg signed [31:0] acc_r;
    reg signed [31:0] offset;
    reg stage;
    wire misaligned_addr = (rs1_i[1:0] != 2'b00);


    // 加法範例與單拍、4-byte 對齊的 AXI 讀寫流程。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_r       <= STATE_IDLE;
            NPU_out       <= 32'd0;
            NPU_done      <= 1'b0;

            // Reset 時取消所有地址/資料要求，並清除輸出暫存器。
            M_AXI_AWADDR  <= 32'd0;
            M_AXI_AWVALID <= 1'b0;
            M_AXI_WDATA   <= 32'd0;
            M_AXI_WLAST   <= 1'b0;
            M_AXI_WVALID  <= 1'b0;
            M_AXI_ARADDR  <= 32'd0;
            M_AXI_ARVALID <= 1'b0;
            M_AXI_WSTRB   <= 4'b1111;
            acc_r <= 32'd0;
            offset <= 32'd0;

            stage <= 1'b0;
        end else begin
            NPU_done <= 1'b0;
            case (state_r)
                STATE_IDLE: begin
                    NPU_done <= 1'b0;
                    if (NPU_start) begin
                        if (funct3_i[2:0] == 3'b000) begin
                            state_r <= STATE_COMP;
                        end
                        else if (funct3_i[2:0] == 3'b001) begin
                            if (misaligned_addr) begin
                                M_AXI_ARADDR <= {rs1_i[31:2], 2'b00};
                                M_AXI_ARVALID <= 1'b1; // 表示讀取地址有效。
                                state_r <= STATE_SEND_ADDR;
                            end else begin
                                M_AXI_ARADDR <= rs1_i; // 設定要讀取的記憶體地址。
                                M_AXI_ARVALID <= 1'b1; // 表示讀取地址有效。
                                state_r <= STATE_SEND_ADDR;
                            end
                        end
                        else if (funct3_i[2:0] == 3'b010) begin
                            if (misaligned_addr) begin
                                M_AXI_AWADDR  <= {rs1_i[31:2], 2'b00};
                                M_AXI_WDATA  <= (rs2_i << rs1_i[1:0]*8);
                                M_AXI_WSTRB   <= (4'b1111 << rs1_i[1:0]);
                                M_AXI_WLAST   <= 1'b1; // 單拍交易，WLAST 設為 1。
                                M_AXI_AWVALID <= 1'b1; // 表示寫入地址有效。
                                M_AXI_WVALID  <= 1'b1; // 表示寫入資料有效
                                state_r <= STATE_WRITE;
                            end else begin 
                                M_AXI_AWADDR  <= rs1_i; // 設定要寫入的記憶體地址。
                                M_AXI_WDATA   <= rs2_i; // 設定要寫入的資料。
                                M_AXI_WSTRB   <= 4'b1111;
                                M_AXI_WLAST   <= 1'b1; // 單拍交易，WLAST 設為 1。
                                M_AXI_AWVALID <= 1'b1; // 表示寫入地址有效。
                                M_AXI_WVALID  <= 1'b1; // 表示寫入資料有效
                                state_r <= STATE_WRITE;
                            end

                        end
                        else begin
                            state_r <= STATE_DONE;
                        end
                    end
                end
                STATE_READ: begin
                    // 在此處理 AXI 讀取的握手與資料接收。
                    // 當讀取完成後，將資料存入 NPU_out，並轉到 STATE_DONE。
                    if (misaligned_addr) begin
                        if (M_AXI_RVALID) begin
                            if(stage == 1'b0) begin
                                NPU_out <= M_AXI_RDATA >> (rs1_i[1:0] * 8);
                                M_AXI_ARADDR <= {rs1_i[31:2] + 1'b1, 2'b00};
                                M_AXI_ARVALID <= 1'b1; // 表示讀取地址有效。
                                state_r <= STATE_SEND_ADDR; // 轉到完成狀態。
                                stage   <=  1'b1;
                            end else begin
                                NPU_out <= NPU_out |(M_AXI_RDATA << (32 - rs1_i[1:0] * 8));
                                stage   <= 1'b0;
                                state_r <= STATE_DONE;
                            end      
                        end
                    end else begin
                        if (M_AXI_RVALID) begin
                            NPU_out <= M_AXI_RDATA; // 將讀回的資料存入 NPU_out。
                            state_r <= STATE_DONE; // 轉到完成狀態。
                        end
                    end

                end
                STATE_WRITE: begin
                    // AW 和 W 各自握手；收到 B 回應後才通知 CPU 完成。
                    if(M_AXI_AWREADY && M_AXI_AWVALID) begin
                        M_AXI_AWVALID <= 1'b0; // 地址已經被接收，取消有效訊號。
                    end
                    if(M_AXI_WREADY && M_AXI_WVALID) begin
                        M_AXI_WVALID <= 1'b0; // 資料已經被接收，取消有效訊號。
                    end
                    if(M_AXI_BVALID && M_AXI_BREADY) begin
                        if (!misaligned_addr) begin
                            // Aligned write 只做一次。
                            stage   <= 1'b0;
                            state_r <= STATE_DONE;
                        end
                        else if (stage == 1'b0) begin
                            // Misaligned 第一筆完成，發出第二筆。
                            M_AXI_AWADDR <= {rs1_i[31:2] + 1'b1, 2'b00};
                            M_AXI_WDATA <= rs2_i >> (32 - rs1_i[1:0] * 8);
                            M_AXI_WSTRB <= 4'b1111 >> (4 - rs1_i[1:0]);
                            M_AXI_WLAST   <= 1'b1;
                            M_AXI_AWVALID <= 1'b1;
                            M_AXI_WVALID  <= 1'b1;
                            stage         <= 1'b1;
                        end
                        else begin
                            // Misaligned 第二筆完成。
                            stage   <= 1'b0;
                            state_r <= STATE_DONE;
                        end
                    end

                end
                STATE_SEND_ADDR: begin
                    // 在此處理 AXI 讀取地址的握手。
                    // 當地址傳送完成後，轉到 STATE_READ。
                    if (M_AXI_ARREADY) begin
                        M_AXI_ARVALID <= 1'b0; // 地址已經被接收，取消有效訊號。
                        state_r <= STATE_READ; // 轉到讀取狀態。
                    end
                end
                STATE_COMP: begin
                    if(funct7_i == 7'b0000000) begin
                        NPU_out <= 32'b0; // 執行加法運算。
                        acc_r   <= 32'b0; // 清除累加器。
                    end else if(funct7_i == 7'b0000001) begin
                        offset <= rs1_i;
                    end else if (funct7_i == 7'b0000010) begin
                        acc_r   <= acc_r + mac_sum;
                        NPU_out <= acc_r + mac_sum;
                    end
                    state_r <= STATE_DONE;
                end

                STATE_DONE: begin
                    NPU_done <= 1'b1;
                    state_r  <= STATE_IDLE;
                end

                default: state_r <= STATE_IDLE;
            endcase
        end
    end


integer i;
  reg signed [31:0] mac_sum;

  always @(*) begin
      mac_sum = 32'sd0;

      for (i = 0; i < 4; i = i + 1) begin
          mac_sum = mac_sum
              + ($signed(rs1_i[i*8 +: 8]) + offset)
              *  $signed(rs2_i[i*8 +: 8]);
      end
  end
endmodule

