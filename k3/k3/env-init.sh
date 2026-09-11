#!/bin/bash
# K3 一次性环境初始化: rustup + 核对源码树
# 在 K3(root@<board>)上执行。前置:主仓源码已解包到 /opt/microduck-k3/microduck
set -euo pipefail

if ! command -v rustc >/dev/null 2>&1; then
  echo "[1/3] install rustup (minimal)…"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --no-modify-path
fi
export PATH="$HOME/.cargo/bin:$PATH"
rustc -V
cargo -V

echo "[2/3] 核对源码树…"
cd /opt/microduck-k3/microduck
[ -f Cargo.toml ] || { echo "缺少 /opt/microduck-k3/microduck(Cargo.toml 不在),先传源码树" >&2; exit 1; }
grep -m1 '^version' Cargo.toml || true

echo "[3/3] rustup target (riscv64gc native; default toolchain already native)…"
rustup target list --installed
echo "done. → 下一步: bash /tmp/build-k3.sh"
