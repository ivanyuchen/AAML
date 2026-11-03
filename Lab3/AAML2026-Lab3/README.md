# AAML2026 lab3

[Lab introduction of Lab3](https://nycu-caslab.github.io/AAML2026/labs/lab_3.html)


## Directory Structure

```bash
.
├── README.md
├── lab3-1
│   ├── data_generator.py
│   ├── Makefile
│   ├── Makefile_ncverilog
│   ├── Makefile_vcs
│   ├── RTL
│   │   ├── global_buffer.v
│   │   └── TPU.v
│   └── TESTBENCH
│       ├── PATTERN.v
│       └── TESTBENCH.v
└── lab3-2
    ├── BOARD
    │   ├── reference
    │   │   ├── constraints
    │   │   │   └── arty_a7_100t.xdc
    │   │   ├── ip
    │   │   └── rtl
    │   │       ├── PE.v
    │   │       ├── TPU.v
    │   │       ├── TPU_top.v
    │   │       ├── uart_controller.v
    │   │       ├── uart_rx.v
    │   │       └── uart_tx.v
    │   └── scripts
    │       ├── create_board_project.tcl
    │       ├── build_bitstream.tcl
    │       └── program_fpga.tcl
    ├── HOST
    │   └── uart_test.py
    ├── Makefile
    └── requirements.txt
```

- `lab3-1`: Row-stationary 2D convolution design problem.
- `lab3-2`: GEMV design problem.
- `lab3-1/RTL`: The source code for the Lab 3-1 simulation design.
- `lab3-1/TESTBENCH`: The testbench for Lab 3-1.
- `lab3-1/data_generator.py`: The test case generator for Lab 3-1.
- `lab3-2/BOARD/reference/rtl`: The RTL source directory for Lab 3-2 FPGA verification.

## Lab 3-1 Software Simulation

Run the following Makefile commands inside `lab3-1` for software simulation.

- `make verif1`
    - Run the code with #1 test case.
- `make verif2`
    - Run the code with #2 test case.
- `make verif3`
    - Run the code with #3 test case.
- `make verif4`
    - Run the code with #4 test case.

Lab 3-2 does not use `make verif1`, `make verif2`, `make verif3`, or `make verif4`.

## Lab 3-2 Arty A7-100T FPGA Verification

Run the following commands inside the `lab3-2` directory.

### Hardware RTL

The RTL used for FPGA hardware verification is located under `BOARD/reference/rtl`.

You are only allowed to modify the following RTL files:

```text
BOARD/reference/rtl/TPU.v
BOARD/reference/rtl/PE.v
```

Four test cases are provided to help you verify the correctness of your design. During grading, the TAs will evaluate your GEMV design on the FPGA using different test cases. The grading results will be based on FPGA execution rather than the provided simulation results. Modifying any other files related to FPGA hardware verification will result in a score of zero for the GEMV assignment.

### Prepare the FPGA Board Files

The following command prepares the Vivado board files from the RTL, IP, and XDC files:

```bash
make fpga_board_files
```

You normally do not need to run this command separately because it is automatically executed by `make generate_gemv_bitstream`.

### Generate the Bitstream

After modifying `TPU.v` or `PE.v`, run:

```bash
make generate_gemv_bitstream
```

This command automatically prepares the FPGA board files, generates the required IP output products, runs synthesis and implementation, and generates:

```text
build/bitstream/gemv_board.bit
```

The FPGA is not programmed automatically by this command.

### Program the FPGA

Program the Arty A7-100T using the existing bitstream:

```bash
make program
```

This command does not rerun synthesis or implementation.

### Run Hardware Verification

After programming the FPGA, run:

```bash
make hardware_verify
```
For each test case, follow these steps:

1. Press BTN1 on the FPGA board to enter UART data-loading mode.
2. Press Enter on the keyboard when prompted.

The Python program will transmit the input matrix and vector to the FPGA through UART and start the GEMV computation. After the computation is complete, the FPGA will return the output vector to the Python program through UART for verification.

If automatic UART detection fails, specify the UART port manually:

```bash
make hardware_verify UART_PORT=/dev/ttyUSB1
```

Use the following command to find the correct UART port:

```bash
python3 -m serial.tools.list_ports -v
```

### Complete Hardware Flow

```bash
make generate_gemv_bitstream
make program
make hardware_verify
```

### Clean FPGA Build Files

```bash
make fpga_clean
```

To clean both simulation and FPGA-generated files:

```bash
make clean_all
```
