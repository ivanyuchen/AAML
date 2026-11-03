import argparse
import math
from numbers import Integral
import random
import secrets
import struct
import sys
import time

import serial
from serial.tools import list_ports


BAUD_RATE = 115200
READ_TIMEOUT_SEC = 0.1
WRITE_TIMEOUT_SEC = 10.0
RESULT_TIMEOUT_SEC = 30.0

FPGA_VID = 0x0403
FPGA_PID = 0x6010

# These values must match TPU_top and uart_controller.
MEMORY_DEPTH = 1024
A_LANES_PER_WORD = 4
LANES_PER_WORD = 4
MIN_MATRIX_DIMENSION = 1
MIN_VECTOR_DIMENSION = 1
MAX_DIMENSION = 254

# Signed INT8 inputs; exact signed INT32 output comparison.
RANDOM_VALUE_MIN = -128
RANDOM_VALUE_MAX = 127

FIXED_GEMV_CASES = (
    (4, 4, 1),
    (8, 8, 1),
    (35, 41, 1),
    (29, 51, 1),
)


def pack_int8(value):
    if not isinstance(value, Integral) or not -128 <= value <= 127:
        raise ValueError(f"Expected signed INT8 (-128..127), received {value!r}")
    return struct.pack("b", int(value))


def hardware_gemv_golden(a_matrix, b_matrix):
    """Exact INT8 x INT8 dot products, accumulated as signed INT32.

    K <= 254 bounds the largest magnitude to 4,161,536, so no overflow occurs.
    """
    m_value, k_value, n_value = check_dimensions(a_matrix, b_matrix)
    return [
        [sum(int(a_matrix[row][k]) * int(b_matrix[k][column])
             for k in range(k_value)) for column in range(n_value)]
        for row in range(m_value)
    ]


def bram_word_counts(m_value, k_value, n_value):
    a_word_count = math.ceil(m_value / A_LANES_PER_WORD) * k_value
    b_word_count = math.ceil(n_value / LANES_PER_WORD) * k_value
    c_word_count = math.ceil(n_value / LANES_PER_WORD) * m_value
    return a_word_count, b_word_count, c_word_count


def dimensions_fit_hardware(m_value, k_value, n_value):
    if not (
        MIN_MATRIX_DIMENSION <= m_value <= MAX_DIMENSION
        and MIN_MATRIX_DIMENSION <= k_value <= MAX_DIMENSION
        and n_value == 1
    ):
        return False
    return max(bram_word_counts(m_value, k_value, n_value)) <= MEMORY_DEPTH


def generate_random_matrix(generator, rows, columns, minimum, maximum):
    matrix = []
    for _ in range(rows):
        matrix_row = []
        for _ in range(columns):
            matrix_row.append(generator.randint(minimum, maximum))
        matrix.append(matrix_row)
    return matrix


def find_fpga_uart():
    matches = []

    print("=" * 72)
    print("Searching for Arty A7 UART")
    print("=" * 72)

    for port in list_ports.comports():
        if port.vid == FPGA_VID and port.pid == FPGA_PID:
            matches.append(port)

            print(f"Candidate   : {port.device}")
            print(f"Description : {port.description}")
            print(f"Interface   : {port.interface}")
            print(f"Location    : {port.location}")
            print()

    if not matches:
        print("Arty A7 UART not found.")
        return None

    if len(matches) == 1:
        return matches[0].device

    # Arty UART uses FTDI Interface B.
    for port in matches:
        interface_text = (port.interface or "").upper()
        description_text = (port.description or "").upper()
        location_text = port.location or ""

        if (
            "INTERFACE B" in interface_text
            or "CONVERTER B" in description_text
            or location_text.endswith(":1.1")
        ):
            print(f"Selecting FTDI Interface B: {port.device}")
            return port.device

    selected = sorted(matches, key=lambda item: item.device)[-1].device
    print(f"Unable to identify Interface B; selecting: {selected}")
    print("Use --port to override this selection if necessary.")
    return selected


def open_uart(port_name):
    return serial.Serial(
        port=port_name,
        baudrate=BAUD_RATE,
        bytesize=serial.EIGHTBITS,
        parity=serial.PARITY_NONE,
        stopbits=serial.STOPBITS_ONE,
        timeout=READ_TIMEOUT_SEC,
        write_timeout=WRITE_TIMEOUT_SEC,
    )


def validate_matrix(matrix, name):
    if not matrix or not matrix[0]:
        raise ValueError(f"{name} must not be empty")
    column_count = len(matrix[0])
    if any(len(row) != column_count for row in matrix):
        raise ValueError(f"{name} must be rectangular")
    for row in matrix:
        for value in row:
            pack_int8(value)


def check_dimensions(a_matrix, b_matrix):
    validate_matrix(a_matrix, "A")
    validate_matrix(b_matrix, "B")
    m_value = len(a_matrix)
    k_value = len(a_matrix[0])
    b_rows = len(b_matrix)
    n_value = len(b_matrix[0])

    if k_value != b_rows:
        raise ValueError(
            f"Dimension mismatch: A is {m_value}x{k_value}, "
            f"but B is {b_rows}x{n_value}"
        )

    if n_value != 1:
        raise ValueError("GEMV requires N=1")
    if not dimensions_fit_hardware(m_value, k_value, n_value):
        a_words, b_words, c_words = bram_word_counts(
            m_value, k_value, n_value
        )
        raise ValueError(
            "Dimensions exceed TPU register or BRAM limits: "
            f"M={m_value}, K={k_value}, N={n_value}, "
            f"A words={a_words}, B words={b_words}, C words={c_words}"
        )
    return m_value, k_value, n_value


def build_request_packet(a_matrix, b_matrix):
    m_value, k_value, n_value = check_dimensions(a_matrix, b_matrix)
    packet = bytearray([k_value, m_value, n_value])

    # A BRAM address = m_block*K + k.
    for m_block in range(math.ceil(m_value / A_LANES_PER_WORD)):
        for k_index in range(k_value):
            for lane in range(A_LANES_PER_WORD):
                row = m_block * A_LANES_PER_WORD + lane
                value = a_matrix[row][k_index] if row < m_value else 0
                packet.extend(pack_int8(value))

    # B BRAM address = n_block*K + k.
    for n_block in range(math.ceil(n_value / LANES_PER_WORD)):
        for k_index in range(k_value):
            for lane in range(LANES_PER_WORD):
                column = n_block * LANES_PER_WORD + lane
                value = b_matrix[k_index][column] if column < n_value else 0
                packet.extend(pack_int8(value))

    return bytes(packet), m_value, k_value, n_value


def expected_response_size(m_value, n_value):
    c_word_count = m_value * math.ceil(n_value / LANES_PER_WORD)
    return c_word_count * LANES_PER_WORD * 4


def expected_uart_response_size(m_value, n_value):
    return expected_response_size(m_value, n_value) + 4


def read_exact(ser, byte_count, timeout_sec):
    result = bytearray()
    deadline = time.monotonic() + timeout_sec
    while len(result) < byte_count and time.monotonic() < deadline:
        chunk = ser.read(byte_count - len(result))
        if chunk:
            result.extend(chunk)
    return bytes(result)


def unpack_c_matrix(received, m_value, n_value):
    n_blocks = math.ceil(n_value / LANES_PER_WORD)
    expected_bytes = expected_response_size(m_value, n_value)
    if len(received) != expected_bytes:
        raise ValueError(
            f"Expected {expected_bytes} result bytes, received {len(received)}"
        )

    flat_bits = struct.unpack(f"<{expected_bytes // 4}i", received)
    c_bits = [
        [0x00000000 for _ in range(n_value)]
        for _ in range(m_value)
    ]
    value_index = 0

    # TPU C BRAM address = n_block*M + row.
    for n_block in range(n_blocks):
        for row in range(m_value):
            for lane in range(LANES_PER_WORD):
                column = n_block * LANES_PER_WORD + lane
                value_bits = flat_bits[value_index]
                value_index += 1
                if column < n_value:
                    c_bits[row][column] = value_bits
                elif value_bits != 0:
                    raise ValueError("Nonzero padding in C response")
    return c_bits


def compare_results(actual, expected):
    return [(row, column, actual[row][column], value)
            for row, values in enumerate(expected)
            for column, value in enumerate(values)
            if actual[row][column] != value]


def print_matrix(name, matrix):
    print(f"{name} =")
    for row in matrix:
        print("  " + " ".join(f"{value:12d}" for value in row))
    print()


def print_matrix_preview(name, matrix, rows=4, columns=8):
    shown_rows = min(rows, len(matrix))
    shown_columns = min(columns, len(matrix[0]))
    print(f"{name} preview ({shown_rows}x{shown_columns}) =")
    for row in range(shown_rows):
        print(
            "  "
            + " ".join(
                f"{matrix[row][column]:12d}"
                for column in range(shown_columns)
            )
        )
    print()


def run_gemv_test(
    port_name,
    a_matrix,
    b_matrix,
    seed,
    print_all_matrices,
    test_name,
    wait_for_button=True,
):
    packet, m_value, k_value, n_value = build_request_packet(
        a_matrix, b_matrix
    )
    response_size = expected_response_size(m_value, n_value)
    uart_response_size = expected_uart_response_size(m_value, n_value)
    a_words, b_words, c_words = bram_word_counts(m_value, k_value, n_value)

    print("Computing exact INT8 / INT32 Golden result...")
    golden_matrix = hardware_gemv_golden(a_matrix, b_matrix)

    print("=" * 72)
    print(f"{test_name}: TPU UART INT8 GEMV test")
    print("=" * 72)
    print(f"Port              : {port_name}")
    print(f"Baud rate         : {BAUD_RATE}")
    print(f"Random seed       : {seed}")
    print(f"Dimensions        : M={m_value}, K={k_value}, N={n_value}")
    print(f"TPU MAC count     : {m_value * k_value * n_value}")
    print(f"BRAM words        : A={a_words}, B={b_words}, C={c_words}")
    print(f"Request bytes     : {len(packet)}")
    print(f"Expected RX bytes : {uart_response_size}")
    print("Comparison        : exact signed INT32 equality")
    print()

    if print_all_matrices or max(m_value, k_value, n_value) <= 16:
        print_matrix("Input A", a_matrix)
        print_matrix("Input B", b_matrix)
    else:
        print_matrix_preview("Input A", a_matrix)
        print_matrix_preview("Input B", b_matrix)

    try:
        with open_uart(port_name) as ser:
            time.sleep(0.1)
            ser.reset_input_buffer()
            ser.reset_output_buffer()

            if wait_for_button:
                input(
                    f"{test_name}: press BTN1 once to enter UART load mode, then press "
                    "Enter here..."
                )

            ser.reset_input_buffer()
            print("Sending K, M, N, matrix A and matrix B...")
            written = ser.write(packet)
            ser.flush()

            if written != len(packet):
                print(f"FAIL: wrote {written} of {len(packet)} bytes.")
                return False

            print("Waiting for matrix C...")
            received = read_exact(ser, uart_response_size, RESULT_TIMEOUT_SEC)

    except (
        serial.SerialException,
        serial.SerialTimeoutException,
        OSError,
    ) as error:
        print(f"FAIL: serial error: {error}")
        return False

    if len(received) != uart_response_size:
        print(
            f"FAIL: received {len(received)} of {uart_response_size} expected bytes."
        )
        if received:
            print(f"Partial RX: {received[:64].hex(' ')}")
        print("Check BTN1, selected UART port, baud rate, reset and bitstream.")
        return False

    c_payload = received[:response_size]
    execution_cycles = struct.unpack("<I", received[response_size:])[0]

    try:
        actual_matrix = unpack_c_matrix(c_payload, m_value, n_value)
    except ValueError as error:
        print(f"FAIL: {error}")
        return False
    mismatches = compare_results(actual_matrix, golden_matrix)

    if print_all_matrices or max(m_value, n_value) <= 16:
        print_matrix("FPGA C", actual_matrix)
        print_matrix("Hardware-rule Golden C", golden_matrix)
    else:
        print_matrix_preview("FPGA C", actual_matrix)
        print_matrix_preview("Hardware-rule Golden C", golden_matrix)

    print(f"Execution cycles  : {execution_cycles}")

    if mismatches:
        print(f"FAIL: {len(mismatches)} matrix element(s) differ.")
        for row, column, actual, expected in mismatches[:20]:
            print(f"  C[{row}][{column}]: FPGA={actual}, Golden={expected}")
        return False

    # print("PASS: UART -> BRAM -> TPU -> BRAM -> UART random GEMV passed.")
    print("==============================================================")
    print("**                                                          **")
    print("**                                                          **")
    print("**                                                          **")
    print("**                         PASS                             **")
    print("**                                                          **")
    print("**                                                          **")
    print("**                                                          **")
    print("==============================================================")
    return True


def parse_arguments():
    parser = argparse.ArgumentParser(
        description=(
            "Generate fixed-size register/BRAM-valid INT8 GEMV cases and test the "
            "Arty A7 TPU through UART."
        )
    )
    parser.add_argument(
        "--port",
        help="Serial port override, for example COM5 or /dev/ttyUSB1",
    )
    parser.add_argument(
        "--seed",
        type=int,
        help="Random seed for matrix/vector values; omit to generate a new seed",
    )
    parser.add_argument(
        "--print-matrices",
        action="store_true",
        help="Print complete matrices even when dimensions exceed 16",
    )
    parser.add_argument(
        "--no-button-wait",
        action="store_true",
        help="Send immediately without waiting for the BTN1 prompt",
    )
    return parser.parse_args()


def main():
    args = parse_arguments()

    seed = args.seed if args.seed is not None else secrets.randbits(64)
    generator = random.Random(seed)

    port_name = args.port or find_fpga_uart()
    if port_name is None:
        print()
        print("Unable to find the Arty A7 UART.")
        print("Use --port COMx or --port /dev/ttyUSB1 if auto-detection fails.")
        sys.exit(1)

    all_passed = True
    for case_index, (m_value, k_value, n_value) in enumerate(FIXED_GEMV_CASES, start=1):
        if not dimensions_fit_hardware(m_value, k_value, n_value):
            print(
                "Unable to generate testcase: "
                f"M={m_value}, K={k_value}, N={n_value} exceeds hardware limits."
            )
            sys.exit(1)

        a_matrix = generate_random_matrix(
            generator,
            m_value,
            k_value,
            RANDOM_VALUE_MIN,
            RANDOM_VALUE_MAX,
        )
        b_matrix = generate_random_matrix(
            generator,
            k_value,
            n_value,
            RANDOM_VALUE_MIN,
            RANDOM_VALUE_MAX,
        )

        test_name = f"Case {case_index} ({m_value}x{k_value} matrix, {k_value}x1 vector)"
        success = run_gemv_test(
            port_name,
            a_matrix,
            b_matrix,
            seed,
            args.print_matrices,
            test_name,
            wait_for_button=not args.no_button_wait,
        )
        all_passed = all_passed and success
        if not success:
            break

    sys.exit(0 if all_passed else 1)


if __name__ == "__main__":
    main()
