`timescale 1ns/10ps

`define CYCLE_TIME 20.0
`include "global_buffer.v"

`timescale 1ns/10ps

module PATTERN(
    output reg          clk,
    output reg          rst_n,
    output reg          in_valid,
    output reg [7:0]    M,
    output reg [7:0]    N,
    input               busy,

    input               A_ram_en,
    input      [15:0]   A_index,
    output     [31:0]   A_data_out,
    input               B_ram_en,
    input      [15:0]   B_index,
    output     [31:0]   B_data_out,
    input               C_ram_en,
    input               C_wr_en,
    input      [15:0]   C_index,
    input      [127:0]  C_data_in,
    output     [127:0]  C_data_out
);

integer PATNUM;
integer patcount;
integer cycles;
integer total_cycles;
integer in_fd;
integer scan_result;
integer error_count;
integer expected_c_words;
integer max_cycles;

reg [7:0] M_golden, N_golden;
reg [127:0] GOLDEN [0:65535];

initial clk = 1'b0;
always #(`CYCLE_TIME/2.0) clk = ~clk;

global_buffer_bram #(.ADDR_BITS(16), .DATA_BITS(32)) gbuff_A(
    .clk(clk), .rst_n(rst_n), .ram_en(A_ram_en), .wr_en(1'b0),
    .index(A_index), .data_in(32'd0), .data_out(A_data_out)
);

global_buffer_bram #(.ADDR_BITS(16), .DATA_BITS(32)) gbuff_B(
    .clk(clk), .rst_n(rst_n), .ram_en(B_ram_en), .wr_en(1'b0), .index(B_index),
    .data_in(32'd0), .data_out(B_data_out)
);

global_buffer_bram #(.ADDR_BITS(16), .DATA_BITS(128)) gbuff_C(
    .clk(clk), .rst_n(rst_n), .ram_en(C_ram_en), .wr_en(C_wr_en), .index(C_index),
    .data_in(C_data_in), .data_out(C_data_out)
);

// Bram access checks
always @(negedge clk) begin
    if (rst_n && !busy) begin
        if (A_ram_en !== 1'b0 || B_ram_en !== 1'b0 || C_ram_en !== 1'b0 || C_wr_en !== 1'b0) begin
            $display("FAIL: BRAM access while TPU is idle");
            wrong_ans;
        end
    end
    if (rst_n && busy) begin
        if ((A_ram_en !== 1'b0 && A_ram_en !== 1'b1) ||
            (B_ram_en !== 1'b0 && B_ram_en !== 1'b1) ||
            (C_ram_en !== 1'b0 && C_ram_en !== 1'b1) ||
            (C_wr_en !== 1'b0 && C_wr_en !== 1'b1)) begin
            $display("FAIL: BRAM control signals must be 0 or 1 while TPU is busy");
            wrong_ans;
        end
        if (A_ram_en && (A_index + 3) >= M_golden * (M_golden + 3)) begin
            $display("FAIL: out-of-range input read A_index=%0d", A_index);
            wrong_ans;
        end
        if (B_ram_en && B_index >= N_golden * ((N_golden + 3) / 4)) begin
            $display("FAIL: out-of-range weight read B_index=%0d", B_index);
            wrong_ans;
        end
        // A and B may be read independently, in any order, and repeatedly.
        if (A_ram_en && ^A_index === 1'bx) begin
            $display("FAIL: A read address is invalid");
            wrong_ans;
        end
        if (B_ram_en && ^B_index === 1'bx) begin
            $display("FAIL: B read address is invalid");
            wrong_ans;
        end
        if (C_wr_en && !C_ram_en) begin
            $display("FAIL: C_wr_en asserted without C_ram_en");
            wrong_ans;
        end
        if (C_ram_en && C_wr_en) begin
            if (^C_index === 1'bx || ^C_data_in === 1'bx) begin
                $display("FAIL: C write address or data is invalid");
                wrong_ans;
            end
            if (C_index >= expected_c_words) begin
                $display("FAIL: out-of-range output write C_index=%0d", C_index);
                wrong_ans;
            end
        end
    end
end

initial begin
    rst_n = 1'b1;
    in_valid = 1'b0;
    M = 'bx;
    N = 'bx;
    total_cycles = 0;

    reset_task;
    in_fd = $fopen("./TESTBENCH/input.txt", "r");
    if (in_fd == 0) begin
        $display("FAIL: cannot open TESTBENCH/input.txt");
        wrong_ans;
    end
    scan_result = $fscanf(in_fd, "%d", PATNUM);

    for (patcount = 0; patcount < PATNUM; patcount = patcount + 1) begin
        read_config;
        validate_config;
        read_input_sram;
        read_weight_sram;
        read_golden;

        repeat (3) @(negedge clk);
        in_valid = 1'b1;
        M = M_golden;
        N = N_golden;
        @(negedge clk);
        in_valid = 1'b0;
        M = 'bx;
        N = 'bx;

        if (busy !== 1'b1) begin
            $display("FAIL pattern %0d: busy was not asserted after in_valid", patcount);
            wrong_ans;
        end

        wait_finished;
        golden_check;
        $display("\033[0;34mPASS PATTERN NO.%4d,\033[m \033[0;32m Cycles: %3d\033[m", patcount, cycles);
        total_cycles = total_cycles + cycles;
        repeat (3) @(negedge clk);
    end

    YOU_PASS_task;
    $finish;
end

task reset_task; begin
    force clk = 1'b0;
    #(`CYCLE_TIME * 2); rst_n = 1'b0;
    #(`CYCLE_TIME * 2);
    if (busy !== 1'b0 || A_ram_en !== 1'b0 || B_ram_en !== 1'b0 || C_ram_en !== 1'b0 || C_wr_en !== 1'b0) begin
        $display("----------------------------------------------------------------");
        $display("                        Reset failed!                           ");
        $display("         Output signal should be 0 after initial RESET at %8t   ", $time);
        $display("----------------------------------------------------------------");
        wrong_ans;
    end
    #(`CYCLE_TIME); rst_n = 1'b1;
    release clk;
end endtask

task read_config; begin
    scan_result = $fscanf(in_fd, "%h %h", M_golden, N_golden);
end endtask

task validate_config; begin
    integer a_words;
    integer b_words;
    integer l_value;
    l_value = M_golden - N_golden + 1;
    a_words = M_golden * (M_golden + 3);
    b_words = N_golden * ((N_golden + 3) / 4);
    expected_c_words = l_value * ((l_value + 3) / 4);
    if (N_golden == 0 || M_golden < N_golden || a_words > 65536 || b_words > 65536 || expected_c_words > 65536) begin
        $display("FAIL: invalid or oversized test configuration M=%0d N=%0d",
                 M_golden, N_golden);
        wrong_ans;
    end
end endtask

task read_input_sram; begin
    reg [7:0] value;
    reg [7:0] input_bytes [0:65535];
    integer bytes;
    integer index;
    bytes = M_golden * (M_golden + 3);
    for (index = 0; index < bytes; index = index + 1) begin
        scan_result = $fscanf(in_fd, "%h", value);
        input_bytes[index] = value;
    end
    for (index = 0; index <= bytes - 4; index = index + 1) begin
        gbuff_A.gbuff[index] = {input_bytes[index], input_bytes[index + 1],
                                input_bytes[index + 2], input_bytes[index + 3]};
    end
end endtask

task read_weight_sram; begin
    reg [7:0] value0, value1, value2, value3;
    integer words;
    integer index;
    words = N_golden * ((N_golden + 3) / 4);
    for (index = 0; index < words; index = index + 1) begin
        scan_result = $fscanf(in_fd, "%h %h %h %h", value0, value1, value2, value3);
        gbuff_B.gbuff[index] = {value0, value1, value2, value3};
    end
end endtask

task read_golden; begin
    reg [31:0] value0, value1, value2, value3;
    integer index;
    for (index = 0; index < expected_c_words; index = index + 1) begin
        scan_result = $fscanf(in_fd, "%h %h %h %h", value0, value1, value2, value3);
        GOLDEN[index] = {value0, value1, value2, value3};
        // Initialize output words to zero before each test case.
        gbuff_C.gbuff[index] = 128'd0;
    end
end endtask

task wait_finished; begin
    cycles = 0;
    max_cycles = 300 + 2 * N_golden * ((N_golden + 3) / 4) +
                 (M_golden - N_golden + 1) *
                 (((M_golden - N_golden + 4) / 4) *
                  ((N_golden + 3) / 4) * (9 * N_golden + 20) +
                  2 * (M_golden - N_golden + 1));
    while (busy === 1'b1) begin
        cycles = cycles + 1;
        if (cycles > max_cycles) begin
            $display ("------------------------------------------------------------------------------------");
            $display ("                 Pattern %0d exceeded the cycle limit (%0d cycles)                 ",
                      patcount, cycles);
            $display ("------------------------------------------------------------------------------------");
            wrong_ans;
        end
        @(negedge clk);
    end
end endtask

task golden_check; begin
    integer index;
    error_count = 0;
    for (index = 0; index < expected_c_words; index = index + 1) begin
        if (gbuff_C.gbuff[index] !== GOLDEN[index]) begin
            $display("FAIL C[%0d]=%032h, expected=%032h",
                     index, gbuff_C.gbuff[index], GOLDEN[index]);
            error_count = error_count + 1;
        end
    end
    if (error_count != 0) begin
        $display("FAIL pattern %0d: %0d errors", patcount, error_count);
        wrong_ans;
    end
end endtask

task wrong_ans; begin
    $display("       /                       \\                                          ");
    $display("    /X/                       \\X\\                                         ");
    $display("   |XX\\         _____         /XX|                                        ");   
    $display("   |XXX\\     _/       \\_     /XXX|___________                             ");      
    $display("    \\XXXXXXX             XXXXXXX/            \\\\\\                          ");  
    $display("      \\XXXX    /     \    XXXXX/                \\\\\\                       ");      
    $display("           |   0     0   |                         \\\\                      ");        
    $display("            |           |                           \\                     ");         
    $display("             \\         /                            |______//             ");       
    $display("              \\       /                             |                     ");       
    $display("               | O_O | \\                            |                     ");    
    $display("                \\ _ /   \\________________           |                     ");                 
    $display("                           | |  | |      \\         /                      ");                        
    $display("     Oh,no      ,          / |  / |       \\______/                        ");            
    $display("      Please...            \\ |  \\ |        \\ |  \\ |                       ");                           
    $display("                         __| |__| |      __| |__| |                       ");      
    $display("                         |___||___|      |___||___|                       ");    
    $display("--------------------------------------------------------------------------");
    $display("               Unfortunately, your answer is wrong                        ");
    $display("--------------------------------------------------------------------------");
    $finish;
end endtask




task YOU_PASS_task; begin
    $display("                             /  \\                                   ");                      
    $display("                            / _  \\                                  ");                        
    $display("                           | /  \\ |                                 ");                          
    $display("                           ||   || _______                         ");                               
    $display("                           ||   || | \\     \\                        ");                              
    $display("                           ||   || || \\     \\                       ");                               
    $display("                           ||   || ||  \\    |                       ");                          
    $display("                           ||   || ||   \\__/                        ");                          
    $display("                           ||   || ||   ||                         ");                        
    $display("                             \\_/  \\_/  \\_//                          ");                
    $display("                           /   _     _    \\                         ");                          
    $display("                          /                \\                        ");                       
    $display("                          |    O     O     |                        ");                    
    $display("                          |   \\  ___  /    |                        ");                
    $display("                         /     \\ \\_/ /     \\                       ");             
    $display("                        /  -----  |  -----  \\                      ");                         
    $display("                        |     \\__/|\\__/     |                      ");                
    $display("                        \\       |_|_|       /                      ");                     
    $display("                         \\_____       _____/                       ");                         
    $display("                               \\     /                             ");                       
    $display("                               |     |                             ");                 
	$display("-------------------------------------------------------------------------");
	$display("                          Congratulations!                			   ");
	$display("                   You have passed all patterns!          			   ");
	$display("                   Your execution cycles = %5d cycles   				   ", total_cycles);
	$display("                   Your clock period = %.1f ns        				   ", `CYCLE_TIME);
	$display("                   Your total latency = %.1f ns         				   ", total_cycles*`CYCLE_TIME);
	$display("------------------------------------------------------------------------");
	$finish;
end endtask

endmodule
