#!/bin/bash
# K1 一键复现:环境 → 构建 → ORT(R1)→ 联调。
#
# 在 K1 上执行。每个阶段可单独跳过,失败即停并给出下一步。
#     bash run-all.sh                 # 全流程
#     bash run-all.sh --skip-build    # 跳过构建(已编过)
#     bash run-all.sh --only-ort      # 只跑 R1 验证
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SKIP_BUILD=0
ONLY_ORT=0
for a in "$@"; do
    case "$a" in
        --skip-build) SKIP_BUILD=1 ;;
        --only-ort)   ONLY_ORT=1 ;;
        *) echo "未知参数 $a" >&2; exit 2 ;;
    esac
done

banner() { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }

# ---------- 0. 环境事实 ----------
banner "0/5 环境事实"
echo "model : $(cat /proc/device-tree/model 2>/dev/null || echo '?')"
echo "cpu   : $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | xargs)"
echo "kernel: $(uname -r)   glibc: $(ldd --version | head -1 | grep -oE '[0-9.]+$')"
echo "mem   : $(free -h | awk '/Mem|内存/{print $2}')"
echo "rust  : $(PATH="$HOME/.cargo/bin:$PATH" rustc -V 2>/dev/null || echo MISSING)"

# ---------- 1. 环境初始化 ----------
if [ $ONLY_ORT -eq 0 ]; then
    banner "1/5 环境初始化"
    bash "$HERE/env-init.sh"
fi

# ---------- 2. 构建 ----------
if [ $SKIP_BUILD -eq 0 ] && [ $ONLY_ORT -eq 0 ]; then
    banner "2/5 裁剪构建"
    bash "$HERE/build-k1.sh" 2>&1 | tee /tmp/k1-build.log
fi

# ---------- 3. R1:ONNX Runtime ----------
if [ $ONLY_ORT -eq 0 ]; then
    banner "3/5 R1 — ONNX Runtime 可用性"
    if bash "$HERE/probe-onnx.sh"; then
        echo "→ R1 通过,继续"
    else
        echo
        echo "→ R1 不通过。若已把 ort-k1/ 传到板上:"
        echo "     bash /tmp/ort-k1/install-ort-k1.sh && bash $HERE/probe-onnx.sh"
        echo "  没有的话,先在本机跑 fetch-ort-from-k3.sh,再 scp -r ort-k1 root@<k1-ip>:/tmp/"
        exit 1
    fi
fi

# ---------- 4. 冒烟:robotd 能否起来 ----------
if [ $ONLY_ORT -eq 0 ]; then
    banner "4/5 robotd 冒烟(--fake,不接仿真)"
    cd /opt/microduck-k1/microduck
    export ORT_DYLIB_PATH="${ORT_DYLIB_PATH:-/opt/microduck-k1/ort/libonnxruntime.so}"
    ./target/release/robotd --help >/dev/null && echo "  --help OK"
    # --fake 用假 IO,不需要仿真也不需要舵机;能起来说明 ORT + 策略加载这条路径没炸
    timeout 12 ./target/release/robotd --fake </dev/null >/tmp/robotd-fake.log 2>&1 || true
    echo "  --- 日志尾 ---"; tail -12 /tmp/robotd-fake.log
fi

# ---------- 5. 联调提示 ----------
banner "5/5 下一步:接本地 MuJoCo 仿真"
cat <<'EOF'
在 K1 上:
  cd /opt/microduck-k1/microduck
  setsid nohup ./target/release/robotd --sim 127.0.0.1:7801 </dev/null >/tmp/robotd-sim.log 2>&1 &
  python3 sim-drive.py --enable --init --vx 0 --seconds 8      # 起身 + 站立
  python3 sim-drive.py --vx 0.25 --seconds 16                  # 行走
  ./target/release/robotctl health

在 Windows 开发台(两个终端):
  # ① 本地仿真(默认 SIT 起始)
  cd microduck_rl
  PYTHONPATH=src "<案例目录>/K3/local-sim/.venv/Scripts/python.exe" \
      -m mjlab_microduck.sim.body_server --port 7801
  # ② 反向隧道(K1 没有公网隧道,只能在同网段直连)
  ssh -N -R 7801:127.0.0.1:7801 root@<k1-ip> \
      -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes

测量用 --headless,否则 viewer 会拖慢实时步进(见 K3-PORT.md §6.10)。
EOF
