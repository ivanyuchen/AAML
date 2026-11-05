# =============================================================================
# Arty A7-100T FPGA build and programming
# =============================================================================

VIVADO ?= vivado
VIVADO_JOBS ?= 4

BOARD_CREATE_TCL := BOARD/scripts/create_board_project.tcl
BOARD_BUILD_TCL := BOARD/scripts/build_bitstream.tcl
BOARD_PROGRAM_TCL := BOARD/scripts/program_fpga.tcl
BOARD_BITSTREAM := build/bitstream/gemv_board.bit

.PHONY: fpga_board_files
.PHONY: generate_gemv_bitstream program
.PHONY: fpga_clean clean_all


# Create the Vivado project from RTL, IP and XDC files.
fpga_board_files:
	@echo "============================================================"
	@echo "Preparing Vivado Arty A7-100T GEMV board files"
	@echo "============================================================"
	$(VIVADO) -mode batch \
		-source $(BOARD_CREATE_TCL)


# Run synthesis, implementation and generate a new bitstream.
# This target does not program the FPGA.
generate_gemv_bitstream: fpga_board_files
	@echo "============================================================"
	@echo "Running synthesis, implementation and bitstream generation"
	@echo "Vivado jobs: $(VIVADO_JOBS)"
	@echo "============================================================"
	$(VIVADO) -mode batch \
		-source $(BOARD_BUILD_TCL) \
		-tclargs $(VIVADO_JOBS)
	@test -f "$(BOARD_BITSTREAM)" || \
		(echo "ERROR: Bitstream generation failed." && exit 1)
	@echo "Generated bitstream: $(BOARD_BITSTREAM)"


# Program only, using the existing bitstream.
# This target does not rerun synthesis or implementation.
program:
	@echo "============================================================"
	@echo "Programming Arty A7-100T with existing bitstream"
	@echo "Bitstream: $(BOARD_BITSTREAM)"
	@echo "============================================================"
	@test -f "$(BOARD_BITSTREAM)" || \
		(echo "ERROR: Bitstream not found: $(BOARD_BITSTREAM)" && exit 1)
	$(VIVADO) -mode batch \
		-source $(BOARD_PROGRAM_TCL)

UART_PORT ?=
PYTHON ?= python3

.PHONY: hardware_verify

hardware_verify:
	@echo "============================================================"
	@echo "Running Arty A7 FPGA hardware verification"
	@echo "UART port: $(if $(UART_PORT),$(UART_PORT),automatic detection)"
	@echo "============================================================"
	@if [ -n "$(UART_PORT)" ]; then \
		test -e "$(UART_PORT)" || { \
			echo "ERROR: UART port not found: $(UART_PORT)"; \
			exit 1; \
		}; \
		$(PYTHON) HOST/uart_test.py --port "$(UART_PORT)"; \
	else \
		$(PYTHON) HOST/uart_test.py; \
	fi

# Remove Vivado projects, reports, bitstreams and session logs.
# The original simulation clean target remains unchanged.
fpga_clean:
	rm -rf ./build
	rm -f ./vivado*.jou
	rm -f ./vivado*.log
	rm -f ./vivado*.str
	rm -f ./vivado*.pb
	rm -f ./webtalk*.jou
	rm -f ./webtalk*.log


clean_all: fpga_clean
