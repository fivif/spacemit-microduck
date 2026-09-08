#!/bin/bash
# K3 一次性环境初始化: rustup + clone microduck 主仓
# 在 K3(root@10.5.90.195)上执行。/tmp/… 拉入 -> bash /tmp/env-init.sh
set -euo pipefail

if ! command -v rustc >/dev/null 2>&1; then
  echo "[1/3] install rustup (minimal)…"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --no-modify-path
fi
export PATH="$HOME/.cargo/bin:$PATH"
rustc -V
cargo -V

echo "[2/3] clone microduck upstream…"
mkdir -p /opt/microduck-k3
cd /opt/microduck-k3
if [ ! -d microduck/.git ]; then
  git clone --depth 1 https://github.com/pollen-robotics/microduck.git
fi
cd microduck

echo "[3/3] rustup target (riscv64gc native; default toolchain already native)…"
rustup target list --installed
echo "done. → 下一步: bash /tmp/build-k3.sh"
