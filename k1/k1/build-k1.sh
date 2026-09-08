#!/bin/bash
# K1 裁剪构建(在 K1 上:/opt/microduck-k1/microduck)
#
# 与 K3 版完全一致的三项裁剪:
#   mediad    —— gstreamer 硬 C 依赖,K1 无 mpp/硬件编码适配
#   duck-detect / pet-detect —— 走 rknn .so dlopen,K1 无 NPU 库,编了也跑不了
#
# 若构建失败,按 docs/03 §5 的顺序排查:
#   1. libudev-sys  → apt install libudev-dev pkg-config(env-init.sh 已装)
#   2. dbus vendored → 追加 --exclude configd --exclude btd
#   3. ort rc.11 与 libonnxruntime.so 的 ABI —— 这是运行期问题,见 docs/04
#   4. 内存不足(3.8 GiB)→ cargo build -j4
set -euo pipefail
export PATH="$HOME/.cargo/bin:$PATH"
cd /opt/microduck-k1/microduck

start=$(date +%s)
cargo build --release --workspace \
    --exclude mediad \
    --exclude duck-detect \
    --exclude pet-detect
end=$(date +%s)

echo "=== build finished in $((end - start))s ==="
ls -la target/release/robotd target/release/robotctl target/release/duckctl 2>/dev/null || true

echo "=== 二进制架构核对 ==="
file target/release/robotd 2>/dev/null || true

echo "=== glibc 地板(应 ≤ 板子 glibc 2.39)==="
objdump -T target/release/robotd 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -3 || true
