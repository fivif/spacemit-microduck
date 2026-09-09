#!/bin/bash
# K1 R1 探针:验证 K1 上的 libonnxruntime.so 能不能被 ort rc.11 用。
#
# 背景(docs/04):
#   主仓 ort = "=2.0.0-rc.11",地板 1.23 —— 低于 1.23 时 ort 会在 setup_api 里 panic。
#   K1 的 apt 包是 onnxruntime 1.2.2(包版本号 ≠ ORT 版本号),实际 .so 是 1.18.1 → 不满足。
#   K3 预装的是 1.24.2+spacemit.a1 → 满足。所以要么装新版,要么把 K3 那个搬过来(见 fetch-ort-from-k3.sh)。
#
# 本探针做三件事,层层递进:
#   1. 报告候选 .so 的文件名 / 真实版本 / 符号需求
#   2. dlopen + dlsym(OrtGetApiBase) + GetApi(23) —— 这正是 ort 初始化要走的路径
#   3. 可选:用 python3 onnxruntime 跑一帧真实策略推理(61→14)
#
# 在 K1 上执行:  bash probe-onnx.sh [策略.onnx]
set -uo pipefail

FLOOR_API=23          # ort rc.11 要求 >= 1.23
FLOOR_TEXT="1.23"

# ---- 候选库:先看显式指定的,再看 ORT_DYLIB_PATH,最后看系统默认 ----
candidates=()
[ -n "${1:-}" ] && [ -f "${1:-}" ] && candidates+=("$1")
[ -n "${ORT_DYLIB_PATH:-}" ] && [ -f "$ORT_DYLIB_PATH" ] && candidates+=("$ORT_DYLIB_PATH")
for c in \
    /opt/microduck-k1/ort/libonnxruntime.so \
    /usr/lib/libonnxruntime.so \
    /usr/lib/riscv64-linux-gnu/libonnxruntime.so \
    /usr/local/lib/libonnxruntime.so
do
    [ -e "$c" ] && candidates+=("$c")
done

if [ ${#candidates[@]} -eq 0 ]; then
    echo "✗ 没找到任何 libonnxruntime.so" >&2
    echo "  装:apt-get install -y onnxruntime   (但那只有 1.18.1)" >&2
    echo "  或:先跑 fetch-ort-from-k3.sh 把 K3 的 1.24.2 搬过来" >&2
    exit 1
fi

echo "=== 候选 ONNX Runtime ==="
for c in "${candidates[@]}"; do
    real=$(readlink -f "$c")
    printf '  %-45s -> %s\n' "$c" "$(basename "$real")"
done
echo

# ---- 1. 符号需求:能不能在 K1 的 glibc/libstdc++ 上加载 ----
echo "=== 符号需求(与 K1 本机对照)==="
TARGET=$(readlink -f "${candidates[0]}")
for sym in GLIBC GLIBCXX CXXABI; do
    need=$(readelf -V "$TARGET" 2>/dev/null | grep -oE "${sym}_[0-9.]+" | sort -uV | tail -1)
    printf '  %-8s 需要 %-14s' "$sym" "${need:-（无）}"
    if [ -n "$need" ]; then
        case "$sym" in
            GLIBC)   have=$(ldd --version | head -1 | grep -oE '[0-9]+\.[0-9]+$') ;;
            *)       have=$(strings /usr/lib/riscv64-linux-gnu/libstdc++.so.6 2>/dev/null \
                              | grep -oE "${sym}_[0-9.]+" | sort -uV | tail -1 | cut -d_ -f2) ;;
        esac
        # 粗略比较:版本串按段比大小
        if [ -n "$have" ]; then
            higher=$(printf '%s\n%s\n' "${need#*_}" "$have" | sort -V | tail -1)
            if [ "$higher" = "$have" ]; then echo "本机 $have "; else echo "本机 $have ✗"; fi
        else
            echo "本机未知 ?"
        fi
    else
        echo
    fi
done
echo

# ---- 2. dlopen + OrtGetApiBase + GetApi(23) ----
echo "=== dlopen 探针(ort 初始化的真实路径)==="
probe_src=$(mktemp /tmp/ort-probe-XXXX.c)
probe_bin=${probe_src%.c}
cat > "$probe_src" <<'EOF'
#include <stdio.h>
#include <dlfcn.h>

typedef struct OrtApiBase OrtApiBase;
struct OrtApiBase {
    const void *(*GetApi)(unsigned int version);
    const char *(*GetVersionString)(void);
};

int main(int argc, char **argv) {
    const char *path = (argc > 1) ? argv[1] : "libonnxruntime.so";
    void *h = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    if (!h) { fprintf(stderr, "dlopen FAILED: %s\n", dlerror()); return 2; }

    const OrtApiBase *(*get_api_base)(void) =
        (const OrtApiBase *(*)(void))dlsym(h, "OrtGetApiBase");
    if (!get_api_base) { fprintf(stderr, "dlsym(OrtGetApiBase) FAILED: %s\n", dlerror()); return 3; }

    const OrtApiBase *base = get_api_base();
    if (!base || !base->GetVersionString) { fprintf(stderr, "no version string\n"); return 4; }

    printf("ORT_VERSION=%s\n", base->GetVersionString());
    const void *api = base->GetApi(23);
    printf("ORT_API_V23=%s\n", api ? "available" : "MISSING");
    return api ? 0 : 5;
}
EOF

if ! gcc -O0 -o "$probe_bin" "$probe_src" -ldl 2>/tmp/ort-probe-build.err; then
    echo "✗ gcc 编译探针失败:" >&2
    cat /tmp/ort-probe-build.err >&2
    rm -f "$probe_src"
    exit 1
fi
rm -f "$probe_src"

verdict=1
for c in "${candidates[@]}"; do
    printf '  %-45s ' "$c"
    out=$("$probe_bin" "$c" 2>&1)
    rc=$?
    if [ $rc -eq 0 ]; then
        v=$(echo "$out" | grep '^ORT_VERSION=' | cut -d= -f2)
        echo " 可加载 · 版本 $v · API v23 可用"
        verdict=0
        FOUND="$c"
    else
        msg=$(echo "$out" | tail -1)
        echo "✗ rc=$rc · $msg"
    fi
done
rm -f "$probe_bin"
echo

# ---- 3. 可选:一帧真实策略推理 ----
policy="${2:-}"
if [ -n "$policy" ] && [ -f "$policy" ]; then
    echo "=== 一帧策略推理(61→14):$(basename "$policy") ==="
    if python3 -c "import onnxruntime" 2>/dev/null; then
        python3 - "$policy" <<'PY'
import sys, numpy as np, onnxruntime as ort
p = sys.argv[1]
s = ort.InferenceSession(p, providers=["CPUExecutionProvider"])
i = s.get_inputs()[0]; o = s.get_outputs()[0]
x = np.zeros((1, 61), dtype=np.float32)
y = s.run(None, {i.name: x})[0]
print(f"  input  {i.name} {i.shape}")
print(f"  output {o.name} {y.shape}  首 4 值 {np.round(y.ravel()[:4], 4)}")
print("   推理通过" if y.shape[-1] == 14 else f"  ✗ 输出维度 {y.shape[-1]} != 14")
PY
    else
        echo "  (跳过:没有 python3 onnxruntime —— apt install python3-spacemit-ort)"
    fi
    echo
fi

# ---- 结论 ----
echo "=== 结论 ==="
if [ $verdict -eq 0 ]; then
    echo " 有可用的 ONNX Runtime(API v23 / >= $FLOOR_TEXT):$FOUND"
    echo "  设 ORT_DYLIB_PATH=$FOUND 后,robotd 即可加载策略(无需重编译)。"
    exit 0
else
    echo "✗ 没有满足地板 $FLOOR_TEXT 的 ONNX Runtime —— R1 成立,robotd 会在 setup_api 里 panic。"
    echo "  对策(按优先级,见 docs/04 §2):"
    echo "    1) 从 K3 搬 1.24.2:本机跑 fetch-ort-from-k3.sh,再 scp 到 K1 后跑 install-ort-k1.sh"
    echo "    2) 在板上查找其它已安装的 ONNX Runtime:find / -name 'libonnxruntime.so*'"
    echo "    3) 自己编 ONNX Runtime(riscv64,慢)"
    exit 1
fi
