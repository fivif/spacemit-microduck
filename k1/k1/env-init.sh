#!/bin/bash
# K1 一次性环境初始化:apt 依赖 + rustup + 主仓源码就位
#
# 在 K1 上以 root 执行。
# 与 K3 版的差异:① 路径 /opt/microduck-k1;② 源码从开发机传上来(见 docs/03);
# ③ K1 缺 cmake/libudev-dev/pkg-config,一并装上。
set -euo pipefail

echo "[1/5] apt 依赖(cmake / libudev-dev / pkg-config / ONNX Runtime / GStreamer -dev)…"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# libudev-dev + pkg-config 是 padd -> gilrs -> libudev-sys 的构建依赖。
# gstreamer 的 -dev 包是 mediad(gstreamer-sys 链)的构建依赖:它们没装的时候整个
# workspace 会在 mediad 处断掉 —— 这不是 riscv64 缺 GStreamer/厂商编码支持,
# 装齐即过。见 docs/03 §4。
# onnxruntime 是策略推理用的 libonnxruntime.so —— 注意 K1 apt 里是 1.2.2 包版本,
# 实际提供 libonnxruntime.so.1.18.1,低于主仓地板 1.23,见 docs/04。
apt-get install -y -qq cmake libudev-dev pkg-config onnxruntime \
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libgstreamer-plugins-bad1.0-dev

echo "[2/5] rustup…"
if ! command -v rustc >/dev/null 2>&1; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y --profile minimal --no-modify-path
fi
export PATH="$HOME/.cargo/bin:$PATH"
rustc -V
cargo -V
# 本机就是 riscv64gc,默认 target 即可;显式确认一下。
rustup target list --installed | grep -q riscv64gc-unknown-linux-gnu && echo "target ok"

echo "[3/5] 源码就位…"
mkdir -p /opt/microduck-k1
cd /opt/microduck-k1
if [ ! -d microduck ]; then
  # 源码从开发机打包传上来(见 docs/03 §1)
  if [ -f microduck-k1-src.tar.gz ]; then
    tar xzf microduck-k1-src.tar.gz
  elif [ -f /tmp/microduck-k1-src.tar.gz ]; then
    tar xzf /tmp/microduck-k1-src.tar.gz -C /opt/microduck-k1
  else
    echo "!! 未找到源码包。请先按 docs/03 §1 打包并 scp 到 /opt/microduck-k1/,再重跑本脚本。" >&2
    exit 1
  fi
fi
cd microduck

echo "[4/5] 补 --sim(若分支未带)…"
if [ ! -f duck-control/src/sim.rs ]; then
  patch_file="$(dirname "$0")/k3-sim-port.patch"
  if [ -f "$patch_file" ]; then
    git apply "$patch_file" && echo "k3-sim-port.patch applied"
  else
    echo "!! 缺 duck-control/src/sim.rs 且找不到 k3-sim-port.patch" >&2
    exit 1
  fi
fi
ls -la duck-control/src/sim.rs

echo "[5/5] 环境事实留档…"
{
  echo "model: $(cat /proc/device-tree/model 2>/dev/null)"
  echo "kernel: $(uname -r)"
  echo "cpu: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2-)"
  echo "mem: $(free -h | awk '/Mem|内存/{print $2}')"
  echo "glibc: $(ldd --version | head -1)"
  echo "rustc: $(rustc -V)"
  echo "onnxruntime.so: $(readlink -f /usr/lib/libonnxruntime.so 2>/dev/null || echo MISSING)"
} | tee /opt/microduck-k1/env-facts.txt

echo "done. → 下一步: bash $(dirname "$0")/build-k1.sh"
