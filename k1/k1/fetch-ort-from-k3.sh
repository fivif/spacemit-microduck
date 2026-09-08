#!/bin/bash
# 从 K3 取 ONNX Runtime 1.24.2+spacemit.a1(在本机 Git Bash 上跑,不需要 K1 在线)。
#
# 为什么:主仓 ort rc.11 地板 1.23;K1 的 apt 只有 1.18.1,而 K3 预装的是 1.24.2。
# 两板同为 riscv64、ABI 一致,且 K3 的 .so 只要求 GLIBC_2.38 / GLIBCXX_3.4.30,
# K1 有 glibc 2.39 / gcc 13.2 → 可以直接搬。依赖实测见 docs/04 §2。
#
# 产出:<本目录>/ort-k1/{libonnxruntime.so.1.24.2+spacemit.a1, libonnxruntime.so,
#                        libonnxruntime_providers_shared.so, MANIFEST.txt}
# 之后:scp -r ort-k1 root@<k1-ip>:/tmp/ && 在 K1 上跑 install-ort-k1.sh
set -euo pipefail

K3_HOST="${K3_SSH_HOST:-root@10.5.90.195}"     # k3ssh.sh 会把旧 LAN token 改写成公网隧道
OUT="$(cd "$(dirname "$0")" && pwd)/ort-k1"
YOLOS="/c/Users/zhuxuanjia/Desktop/Work_World/yolos-box"

mkdir -p "$OUT"

echo "[1/3] 在 K3 上定位 ORT…"
remote=$("$YOLOS/tools/k3ssh.sh" "$K3_HOST" '
    L=$(readlink -f /usr/lib/libonnxruntime.so)
    P=$(readlink -f /usr/lib/libonnxruntime_providers_shared.so 2>/dev/null || true)
    echo "$L"
    echo "$P"
')
lib=$(echo "$remote" | sed -n '1p')
prov=$(echo "$remote" | sed -n '2p')

if [ -z "$lib" ] || [ ! -n "$lib" ]; then
    echo "✗ K3 上没找到 libonnxruntime.so" >&2
    exit 1
fi
echo "    lib : $lib"
echo "    prov: ${prov:-（无）}"

echo "[2/3] 拉取…"
"$YOLOS/tools/k3scp.sh" "$K3_HOST:$lib" "$OUT/" || {
    echo "  k3scp.sh 不支持远程→本地方向,改用 ssh+cat 直取…"
    "$YOLOS/tools/k3ssh.sh" "$K3_HOST" "cat '$lib'" > "$OUT/$(basename "$lib")"
}
[ -n "$prov" ] && "$YOLOS/tools/k3scp.sh" "$K3_HOST:$prov" "$OUT/" 2>/dev/null || true

# 建标准符号链接名 —— ort 的 load-dynamic 默认找的是 libonnxruntime.so
(cd "$OUT" && ln -sf "$(basename "$lib")" libonnxruntime.so 2>/dev/null || \
               cp "$(basename "$lib")" libonnxruntime.so)

echo "[3/3] 留档…"
{
    echo "来源: $K3_HOST:$lib"
    echo "拉取时间: $(date -Iseconds)"
    echo "文件:"
    (cd "$OUT" && ls -la | grep -v '^total')
    echo
    echo "K1 安装:scp -r ort-k1 root@<k1-ip>:/tmp/ && ssh root@<k1-ip> 'bash /tmp/ort-k1/install-ort-k1.sh'"
} | tee "$OUT/MANIFEST.txt"

echo
echo "✓ 完成 → $OUT"
echo "  下一步:scp -r \"$OUT\" root@<k1-ip>:/tmp/"
