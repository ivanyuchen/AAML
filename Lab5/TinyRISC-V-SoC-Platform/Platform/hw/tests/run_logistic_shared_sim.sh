#!/usr/bin/env bash
set -euo pipefail
platform_dir=$(cd "$(dirname "$0")/../.." && pwd)
cd "$platform_dir"
test_dir=$(mktemp -d /tmp/lab5-logistic-shared.XXXXXX)
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$test_dir"' EXIT
# Pin the tested pre-sharing implementation so later commits remain comparable.
git show 0312497:Lab5/TinyRISC-V-SoC-Platform/Platform/hw/srcs/Logistic.v > "$test_dir/reference.v"
python3 - "$test_dir/reference.v" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_text(p.read_text().replace('module Logistic (', 'module Logistic_before (', 1))
PY
iverilog -g2001 -s logistic_shared_tb -o "$test_dir/equivalence" \
  hw/tests/logistic_shared_tb.v hw/srcs/Logistic.v "$test_dir/reference.v"
vvp "$test_dir/equivalence"
iverilog -g2001 -s new_logistic_tb -o "$test_dir/numeric" \
  hw/tests/new_logistic_tb.v hw/srcs/Logistic.v
vvp "$test_dir/numeric"
