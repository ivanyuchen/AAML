#!/usr/bin/env bash
set -euo pipefail
platform_dir=$(cd "$(dirname "$0")/../.." && pwd)
cd "$platform_dir"
test_dir=$(mktemp -d /tmp/lab5-basic2-sim.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
imports=hw/srcs/sources_1/imports
cache_sources=("$imports/clean_cache.v" "$imports/dcache_pro.v" "$imports/way_32Bx512.v"
  "$imports/DistributedRAM.v" "$imports/lru_1b.v" "$imports/tag_block18b.v"
  "$imports/data_block32B.v" "$imports/SDPBRAMD.v")
iverilog -g2001 -s clean_cache_tb -o "$test_dir/control" hw/tests/clean_cache_tb.v "$imports/clean_cache.v"
vvp "$test_dir/control"
iverilog -g2001 -s cache_coherence_tb -o "$test_dir/cache" hw/tests/cache_coherence_tb.v "${cache_sources[@]}"
vvp "$test_dir/cache"
riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -nostdlib -Wl,-Ttext=0x60000000 -Wl,--no-relax \
  hw/tests/backend_coherence_program.S -o "$test_dir/program.elf"
riscv64-unknown-elf-objcopy -O binary "$test_dir/program.elf" "$test_dir/program.bin"
python3 - "$test_dir" <<'PYHEX'
import sys
from pathlib import Path
p = Path(sys.argv[1])
data = (p / 'program.bin').read_bytes()
words = [int.from_bytes(data[i:i+4], 'little') for i in range(0, len(data), 4)]
words += [0x00000013] * (256 - len(words))
(p / 'program.hex').write_text(''.join(f'{word:08x}\n' for word in words))
PYHEX
if ! iverilog -g2012 -I hw/srcs/sources_1 -I "$imports" -s backend_coherence_tb \
  -o "$test_dir/backend" hw/tests/backend_coherence_tb.v "$imports"/*.v "$imports"/*.sv \
  > "$test_dir/build.log" 2>&1; then
  cat "$test_dir/build.log"
  exit 1
fi
vvp "$test_dir/backend" +PROGRAM="$test_dir/program.hex"
iverilog -g2001 -s npu_gemv_tb -o "$test_dir/gemv" hw/tests/npu_gemv_tb.v hw/srcs/*.v
vvp "$test_dir/gemv"
