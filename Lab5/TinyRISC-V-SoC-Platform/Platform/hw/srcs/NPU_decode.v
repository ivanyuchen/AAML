`timescale 1ns / 1ps
//==============================================================================
// NPU_decode: CUSTOM-0 funct3 / funct7 -> one-hot op flags (combinational).
// The encoding table lives in NPU.v; this is the only place that compares
// raw funct3 / funct7 values. At most one flag is 1; none = no-op (the NPU
// just finishes, e.g. funct3 = 7 or an unknown funct3 = 3 sub-function).
//==============================================================================
module NPU_decode (
    input [ 3:0] funct3_i,
    input [31:0] funct7_i,

    // funct3 = 0  (Lab1)
    output op_mac_clear,       // funct7 = 0
    output op_mac_set_offset,  // funct7 = 1
    output op_mac_acc4,        // funct7 = 2
    output op_add,             // funct7 = other (stock example)
    // funct3 = 1 / 2  (Lab1)
    output op_axi_read,
    output op_axi_write,
    // funct3 = 3  (Lab2 Conv)
    output op_conv_config,     // funct7 = 0
    output op_conv_load_ptr1,  // funct7 = 1
    output op_conv_load_ptr2,  // funct7 = 2
    output op_conv_compute,    // funct7 = 3
    // funct3 = 4  (Lab4)
    output op_logistic,
    // funct3 = 5 / 6  (Lab4)
    output op_tr_cfg,          // funct7[2:0] = config field
    output op_tr_start
);

  wire [2:0] f3 = funct3_i[2:0];  // the instruction only carries 3 bits
  wire [6:0] f7 = funct7_i[6:0];

  wire is_f3_0 = (f3 == 3'd0);
  wire is_f3_3 = (f3 == 3'd3);

  // funct3 = 0 compares the full 32-bit funct7 (as Lab1 always did): the
  // stock add uses all of it, so e.g. 128 must NOT alias to MAC_CLEAR.
  assign op_mac_clear      = is_f3_0 && (funct7_i == 32'd0);
  assign op_mac_set_offset = is_f3_0 && (funct7_i == 32'd1);
  assign op_mac_acc4       = is_f3_0 && (funct7_i == 32'd2);
  assign op_add            = is_f3_0 && (funct7_i > 32'd2);

  assign op_axi_read       = (f3 == 3'd1);
  assign op_axi_write      = (f3 == 3'd2);

  assign op_conv_config    = is_f3_3 && (f7 == 7'd0);
  assign op_conv_load_ptr1 = is_f3_3 && (f7 == 7'd1);
  assign op_conv_load_ptr2 = is_f3_3 && (f7 == 7'd2);
  assign op_conv_compute   = is_f3_3 && (f7 == 7'd3);

  assign op_logistic       = (f3 == 3'd4);
  assign op_tr_cfg         = (f3 == 3'd5);
  assign op_tr_start       = (f3 == 3'd6);

endmodule
