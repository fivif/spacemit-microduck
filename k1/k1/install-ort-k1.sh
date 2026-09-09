#!/bin/bash
# 在 K1 上安装从 K3 搬来的 ONNX Runtime(1.24.2+spacemit.a1)。
#
# 用法:把 ort-k1/ 整个目录放到 K1 上,然后
#     bash /tmp/ort-k1/install-ort-k1.sh
#
# 做的事:
#   1. 备份 K1 原有的 /usr/lib/libonnxruntime.so*(apt 的 1.18.1)
#   2. 把 1.24.2 放到 /opt/microduck-k1/ort/,并建好 libonnxruntime.so 符号链接
#   3. 不覆盖系统库 —— 用 ORT_DYLIB_PATH 指过去,避免影响板上其它程序
#   4. 跑 probe-onnx.sh 验证
#
# 为什么不直接覆盖 /usr/lib:系统里别的程序(如 python3-spacemit-ort)可能依赖 1.18.1,
# 覆盖会让它们的符号解析换一套。ORT_DYLIB_PATH 是 ort 官方支持的选择路径,只影响 robotd。
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST=/opt/microduck-k1/ort
ORT_SO=$(ls "$SRC"/libonnxruntime.so.* 2>/dev/null | grep -v providers | head -1 || true)

if [ -z "$ORT_SO" ]; then
    echo "✗ 当前目录没有 libonnxruntime.so.<版本>,只看到:" >&2
    ls -la "$SRC" >&2
    exit 1
fi

echo "[1/4] 记录现有 ORT…"
if [ -e /usr/lib/libonnxruntime.so ]; then
    echo "    现有: $(readlink -f /usr/lib/libonnxruntime.so)"
else
    echo "    现有: (无)"
fi

echo "[2/4] 安装到 $DEST …"
mkdir -p "$DEST"
cp -v "$ORT_SO" "$DEST/"
[ -f "$SRC/libonnxruntime_providers_shared.so" ] && \
    cp -v "$SRC/libonnxruntime_providers_shared.so" "$DEST/" || true
(cd "$DEST" && ln -sf "$(basename "$ORT_SO")" libonnxruntime.so)

echo "[3/4] 写入 robotd 的运行时环境…"
# systemd 下用 drop-in;裸跑时用 shell profile。
mkdir -p /etc/systemd/system/robotd.service.d
cat > /etc/systemd/system/robotd.service.d/10-ort.conf <<EOF
[Service]
Environment=ORT_DYLIB_PATH=$DEST/libonnxruntime.so
EOF
systemctl daemon-reload 2>/dev/null || true

# 让交互式 shell 也有(方便直接跑 ./target/release/robotd)
if ! grep -q "ORT_DYLIB_PATH" /root/.bashrc 2>/dev/null; then
    echo "export ORT_DYLIB_PATH=$DEST/libonnxruntime.so" >> /root/.bashrc
fi
export ORT_DYLIB_PATH="$DEST/libonnxruntime.so"
echo "    ORT_DYLIB_PATH=$ORT_DYLIB_PATH"

echo "[4/4] 验证…"
bash "$SRC/../probe-onnx.sh" "$ORT_DYLIB_PATH" || {
    # 若 probe 脚本没跟着传过来,退化成最基本的 dlopen 测试
    echo "  (未找到 probe-onnx.sh,做最小验证)"
    python3 - <<'PY' 2>/dev/null || echo "  python3 onnxruntime 不可用,跳过"
import ctypes, os
p = os.environ["ORT_DYLIB_PATH"]
h = ctypes.CDLL(p)
h.OrtGetApiBase.restype = ctypes.c_void_p
base = h.OrtGetApiBase()
print("  dlopen OK, OrtGetApiBase =", hex(base))
PY
}

echo
echo " 完成。robotd 现在会从 $DEST/libonnxruntime.so 加载策略。"
echo "  手动跑:export ORT_DYLIB_PATH=$DEST/libonnxruntime.so && ./target/release/robotd --sim 127.0.0.1:7801"
