#!/bin/bash
# K3 裁剪构建(在 K3 上: /opt/microduck-k3/microduck)
# 只裁 mediad —— K3 尚未把它跑起来,不是 riscv64 做不了(K1 已编出并运行,见 ../../docs/K1-MEDIA.md)。
#
# duck-detect 不裁(2026-09-10 起改):原来裁它的理由是"走 rknn .so dlopen,
# 本平台没有那个 NPU 运行时",这条现在不成立了 —— dlopen 的东西编译期本来就不需要,
# 而且 duck-detect 多了 src/spacemit.rs 这条 SpaceMIT EP 的路(厂商私有 C 入口
# OrtSessionOptionsSpaceMITEnvInit,挂到同一个 ort 会话上)。duck-bench 是唯一能
# 在板上验证它的工具。同一份代码在 K1 上 `cargo build --release -p duck-detect`
# 35.82s 通过;K3 上尚未实测。
#
# pet-detect 不裁:纯 Rust + rustfft + ort(dlopen),模型 20 KB,
# 与 robotd 走同一条 ORT 路径,没有 rknn 依赖。
set -euo pipefail
export PATH="$HOME/.cargo/bin:$PATH"
cd /opt/microduck-k3/microduck

cargo build --release --workspace \
    --exclude mediad

ls -la target/release/robotd target/release/robotctl target/release/duckctl \
      target/release/pet-detect target/release/pet-features \
      target/release/duck-bench 2>/dev/null || true
echo "build done. (若 dbus vendored 编译失败: 追加 --exclude configd --exclude btd)"
