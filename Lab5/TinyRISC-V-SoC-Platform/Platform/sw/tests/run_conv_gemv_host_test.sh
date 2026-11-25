#!/usr/bin/env bash
set -euo pipefail
platform_dir=$(cd "$(dirname "$0")/../.." && pwd)
cd "$platform_dir"
test_dir=$(mktemp -d /tmp/lab5-conv-host.XXXXXX)
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$test_dir"' EXIT
# Compare to the original Lab5 CPU kernel, before GEMV integration.
git show 69f164f:Lab5/TinyRISC-V-SoC-Platform/Platform/sw/tflm_patches/tensorflow/lite/kernels/internal/reference/integer_ops/conv.h > "$test_dir/conv_cpu_reference.h"
python3 - "$test_dir/conv_cpu_reference.h" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text().replace('TENSORFLOW_LITE_KERNELS_INTERNAL_REFERENCE_INTEGER_OPS_CONV_H_',
                          'LAB5_CPU_CONV_REFERENCE_H_')
s = s.replace('namespace reference_integer_ops', 'namespace cpu_conv_reference')
p.write_text(s)
PY
tf_root="$platform_dir/../tflite-micro"
g++ -std=c++11 -O1 -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I "$test_dir" -I sw/tflm_patches -I sw/project -I sw/app -I "$tf_root" \
  -I "$tf_root/third_party/gemmlowp" -I "$tf_root/third_party/flatbuffers/include" \
  -I "$tf_root/third_party/ruy" sw/tests/conv_gemv_host_test.cc sw/project/lab5_api.cc \
  -o "$test_dir/conv_test"
"$test_dir/conv_test"
