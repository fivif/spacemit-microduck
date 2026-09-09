# k1/ — K1 侧脚本

> 全部脚本已通过 `bash -n` 语法检查(`sim-drive.py` 通过 `py_compile`)。
> **板子一回来,`run-all.sh` 就能从零跑到联调。**

## 快速开始

```bash
# K1 上(一条命令跑完 环境 → 构建 → R1 验证 → 冒烟)
bash run-all.sh

# 分段跑
bash run-all.sh --skip-build     # 已编过,跳过构建
bash run-all.sh --only-ort       # 只验 R1
```

## 文件清单

| 文件 | 作用 | 在哪跑 |
|---|---|---|
| `run-all.sh` | 一键复现:环境 → 构建 → R1 → 冒烟 → 联调提示 | K1 |
| `env-init.sh` | apt 依赖(cmake/libudev-dev/pkg-config/onnxruntime)+ rustup + 源码就位 + 打补丁 + 环境留档 | K1 |
| `build-k1.sh` | 裁剪构建(`--exclude mediad duck-detect pet-detect`)+ 架构/glibc 核对 | K1 |
| **`probe-onnx.sh`** | **R1 探针**:候选 .so 定位 → 符号需求比对 → `dlopen`+`GetApi(23)` → 可选一帧 61→14 推理 | K1 |
| **`fetch-ort-from-k3.sh`** | **从 K3 搬 1.24.2+spacemit.a1**(K1 的 apt 只有 1.18.1) | **本机** |
| **`install-ort-k1.sh`** | 把搬来的 ORT 装到 `/opt/microduck-k1/ort/`,写 systemd drop-in + `ORT_DYLIB_PATH` | K1 |
| `sim-drive.py` | 驱动 `robotd`(hello → enable → init → move),与 K3 版**逐字节相同** | K1 |
| `k3-sim-port.patch` | `--sim` 移植补丁(4 文件 / 529 行 diff),K3 与 K1 通用 | 任意 |

## R1 的处理链(关键)

K1 的 apt 只有 `libonnxruntime.so.1.18.1`,**低于主仓地板 1.23** → `ort` 会在 `setup_api` 里 panic。
而 K3 预装的是 **1.24.2+spacemit.a1**。两板同为 riscv64、ABI 一致,依赖实测:

| K3 的 ORT 要求 | K1 实测 |
|---|---|
| `GLIBC_2.38` | glibc **2.39**  |
| `GLIBCXX_3.4.30` | gcc 13.2 → **3.4.32**  |
| `ELF 64-bit UCB RISC-V, RVC, double-float` | 同架构  |

所以**直接搬**即可:

```bash
# 本机(需要 K3 可达 —— 公网隧道 45.153.245.76:6322 在家也能用)
cd "K1/k1" && ./fetch-ort-from-k3.sh          # 产出 ort-k1/

# 传到 K1
scp -r ort-k1 root@<k1-ip>:/tmp/

# K1 上安装 + 验证
bash /tmp/ort-k1/install-ort-k1.sh
bash probe-onnx.sh /opt/microduck-k1/ort/libonnxruntime.so
```

> `install-ort-k1.sh` **不覆盖 `/usr/lib`** —— 用 `ORT_DYLIB_PATH` 指过去,只影响 `robotd`,
> 不动板上其它依赖 1.18.1 的程序(python3-spacemit-ort 等)。

## 传递脚本到 K1(Git Bash)

脚本通过 `ssh`/`scp` 直连板子传递:

```bash
ASKPASS="$(mktemp)"; printf '#!/bin/sh\necho "<password>"\n' > "$ASKPASS"; chmod +x "$ASKPASS"
export SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force DISPLAY=:0
K1=root@<k1-ip>

# 整套脚本
for f in run-all.sh env-init.sh build-k1.sh probe-onnx.sh install-ort-k1.sh sim-drive.py k3-sim-port.patch; do
  scp -O -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password \
      -o PubkeyAuthentication=no "$f" "$K1:/tmp/"
done
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no "$K1" 'bash /tmp/run-all.sh'
```

> 源码部署见 [`../docs/03-源码获取与构建.md`](../docs/03-源码获取与构建.md)。
> 注意: `fetch-ort-from-k3.sh` 要在**本机**跑(它用 <tools> 的 `k3ssh.sh`/`k3scp.sh` 走公网隧道)。
