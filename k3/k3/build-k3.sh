#!/bin/bash
# K3 裁剪构建(在 K3 上: /opt/microduck-k3/microduck)
# 只裁 mediad(gstreamer 硬 C 依赖,原平台的 mpp/webrtc 无对应物);
# duck-detect/pet-detect 可编(纯 Rust+dlopen),但 K3 无 rknn/NPU 库 → 运行不可用,默认不编。
set -euo pipefail
export PATH="$HOME/.cargo/bin:$PATH"
cd /opt/microduck-k3/microduck

cargo build --release --workspace \
    --exclude mediad \
    --exclude duck-detect \
    --exclude pet-detect

ls -la target/release/robotd target/release/robotctl target/release/duckctl 2>/dev/null || true
echo "build done. (若 dbus vendored 编译失败: 追加 --exclude configd --exclude btd)"
