#!/bin/bash
# K1 构建(在 K1 上:/opt/microduck-k1/microduck)
#
# K1 不裁任何 crate。mediad 也能编能跑:USB 摄像头链路 MJPEG → UYVY →
# spacemith264enc(硬件 H.264)→ WebRTC,出实帧。它此前被排除的理由写的是
# "gstreamer 硬 C 依赖,K1 无 mpp/硬件编码适配" —— **这条是错的**:真正的原因是
# 板上从来没装 GStreamer 的 -dev 包(libgstreamer1.0-dev /
# libgstreamer-plugins-base1.0-dev / libgstreamer-plugins-bad1.0-dev,env-init.sh 已装);
# riscv64 并不缺 GStreamer/厂商编码支持。装齐后 `--exclude mediad` 已撤销(2026-09-11)。
#
# duck-detect 不裁(2026-09-10 起改):原来裁它的理由是"走 rknn .so dlopen,
# 本平台没有那个 NPU 运行时",这条现在两头都不成立 ——
#   一来 dlopen 的东西编译期本来就不需要,`librknnrt.so` 不在板上也照样编得过;
#   二来 duck-detect 多了第三条路:src/spacemit.rs 走厂商私有的 C 入口
#   OrtSessionOptionsSpaceMITEnvInit,把 SpaceMIT EP 挂到**同一个** ort 会话上。
#   而 duck-bench 是板上唯一能验证这条路的工具 —— 裁掉 duck-detect 等于把唯一的
#   验证手段裁掉,之前那批 EP 数字也就没法复现了。
#   K1 实测:`cargo build --release -p duck-detect` 35.82s,无警告通过。
#
# pet-detect 不裁 —— 而且它也从来没能被裁掉:
#   robotd/Cargo.toml 里有 `pet-detect = { path = "../pet-detect" }`,
#   robotd/src/main.rs 用 `pet_detect::worker::PetHandle` + `pet_detect::PettingEvent`。
#   也就是说 `--exclude pet-detect` 只挡掉了两个独立二进制(pet-detect / pet-features),
#   pet-detect 的代码(ort dlopen + rustfft + hound)**一直编在 robotd 里**。
#   板上那个 7 319 888 B 的 robotd 用 strings 就能看到 pet-detect/src/worker.rs、
#   arecord 的采样参数、audio.pet_detect —— 证据齐全。
#   它和 rknn 毫无关系:走的是 robotd 同一条 ORT 路径,模型 20 201 B。
#   K1 上实测:两个二进制编译 2m46s / 1 770 728 B,喂静音正常输出 `p 0.000 normal`。
#
# 若构建失败,按 docs/03 §4 的顺序排查:
#   1. libudev-sys  → apt install libudev-dev pkg-config(env-init.sh 已装)
#   2. gstreamer-sys(mediad)→ apt install libgstreamer1.0-dev
#      libgstreamer-plugins-base1.0-dev libgstreamer-plugins-bad1.0-dev(env-init.sh 已装)
#   3. dbus vendored → 追加 --exclude configd --exclude btd
#   4. ort rc.11 与 libonnxruntime.so 的 ABI —— 这是运行期问题,见 docs/04
#   5. 内存不足(3.8 GiB)→ cargo build -j4
set -euo pipefail
export PATH="$HOME/.cargo/bin:$PATH"
cd /opt/microduck-k1/microduck

start=$(date +%s)
cargo build --release --workspace
end=$(date +%s)

echo "=== build finished in $((end - start))s ==="
ls -la target/release/robotd target/release/robotctl target/release/duckctl \
      target/release/mediad target/release/pet-detect target/release/pet-features \
      target/release/duck-bench 2>/dev/null || true

echo "=== 二进制架构核对 ==="
file target/release/robotd 2>/dev/null || true

echo "=== glibc 地板(应 ≤ 板子 glibc 2.39)==="
objdump -T target/release/robotd 2>/dev/null | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -3 || true
