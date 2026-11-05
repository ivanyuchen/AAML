"""Generate packed SRAM images and golden data for the convolution lab."""

import argparse
from pathlib import Path

import numpy as np


def case_shapes(mode, count, rng):
    """Return (M, N) cases.  L=M-N+1 is intentionally often not /4."""
    directed = {
        0: [(7, 4)],
        1: [(10, 5)],
        3: [(1, 1), (4, 1), (7, 7), (5, 2), (8, 5), (9, 5),
            (10, 5), (11, 5), (12, 8), (32, 17), (254, 1),
            (254, 254)],
    }
    if mode in directed:
        return [directed[mode][i % len(directed[mode])] for i in range(count)]

    large_cases = [(64, 17), (64, 33), (64, 47), (96, 65)]
    shapes = large_cases[:count]
    for _ in range(len(shapes), count):
        m = int(rng.integers(64, 255))
        if rng.integers(0, 2) == 0:
            n = int(rng.integers(1, min(m, 24) + 1))
        else:
            out_size = int(rng.integers(1, min(m, 16) + 1))
            n = m - out_size + 1
        shapes.append((m, n))
    return shapes


def convolution(image, kernel):
    m, _ = image.shape
    n = kernel.shape[0]
    out_size = m - n + 1
    result = np.zeros((out_size, out_size), dtype=np.uint32)
    image_u32 = image.astype(np.uint32)
    kernel_u32 = kernel.astype(np.uint32)
    for oy in range(out_size):
        for ox in range(out_size):
            patch = image_u32[oy:oy + n, ox:ox + n]
            result[oy, ox] = np.sum(patch * kernel_u32, dtype=np.uint32)
    return result


def write_config(fd, m, n):
    fd.write(f"\n{m:02x} {n:02x}\n")


def write_input(fd, image):
    m, _ = image.shape
    # A is stored once, column major.  Three zero bytes after each column make
    # every four-byte vertical-vector read safe at a bottom kernel-row tail.
    stride = m + 3
    for col in range(m):
        for row in range(stride):
            value = int(image[row, col]) if row < m else 0
            fd.write(f"{value:02x} ")
            if (row & 15) == 15 or row + 1 == stride:
                fd.write("\n")


def write_weight(fd, kernel):
    n, _ = kernel.shape
    row_tiles = (n + 3) // 4
    for row_tile in range(row_tiles):
        for col in range(n):
            values = [int(kernel[row_tile * 4 + row, col])
                      if row_tile * 4 + row < n else 0
                      for row in range(4)]
            fd.write(" ".join(f"{value:02x}" for value in values) + "\n")


def write_output(fd, output):
    out_size, _ = output.shape
    tiles = (out_size + 3) // 4
    # tiles = out_size
    for row in range(out_size):
        for tile in range(tiles):
            values = [int(output[row, tile * 4 + lane])
                      if tile * 4 + lane < out_size else 0
                      for lane in range(4)]
            fd.write(" ".join(f"{value:08x}" for value in values) + "\n")


def write_readable(fd, index, image, kernel, output):
    m, _ = image.shape
    n = kernel.shape[0]
    fd.write(f"case {index}: M={m} N={n} L={m - n + 1}\n")
    fd.write(f"input:\n{image}\n")
    fd.write(f"kernel:\n{kernel}\n")
    fd.write(f"output:\n{output}\n")
    fd.write("\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", type=int, choices=range(4), required=True)
    parser.add_argument("--ncases", type=int, default=1)
    parser.add_argument("--ones", action="store_true")
    parser.add_argument("--seed", type=int, default=2026)
    parser.add_argument("--target_dir", type=Path, required=True)
    args = parser.parse_args()

    args.target_dir.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(args.seed)
    shapes = case_shapes(args.mode, args.ncases, rng)

    with (args.target_dir / "input.txt").open("w", encoding="ascii") as packed, \
         (args.target_dir / "check.txt").open("w", encoding="utf-8") as readable:
        packed.write(f"{args.ncases}\n")
        for index, (m, n) in enumerate(shapes):
            if args.mode == 3 and index == 0:
                image = np.zeros((m, m), dtype=np.uint8)
                kernel = np.zeros((n, n), dtype=np.uint8)
            elif args.mode == 3 and index == 1:
                image = np.ones((m, m), dtype=np.uint8)
                kernel = np.ones((n, n), dtype=np.uint8)
            elif args.mode == 3 and index == 2:
                image = np.full((m, m), 255, dtype=np.uint8)
                kernel = np.full((n, n), 255, dtype=np.uint8)
            elif args.ones:
                image = np.ones((m, m), dtype=np.uint8)
                kernel = np.ones((n, n), dtype=np.uint8)
            else:
                image = rng.integers(0, 256, (m, m), dtype=np.uint8)
                kernel = rng.integers(0, 256, (n, n), dtype=np.uint8)
            output = convolution(image, kernel)

            write_config(packed, m, n)
            write_input(packed, image)
            write_weight(packed, kernel)
            write_output(packed, output)
            write_readable(readable, index, image, kernel, output)


if __name__ == "__main__":
    main()
