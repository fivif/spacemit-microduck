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
| `env-init.sh` | apt 依赖(cmake/libudev-dev/pkg-config/onnxruntime/GStreamer -dev)+ rustup + 源码就位 + 打补丁 + 环境留档 | K1 |
| `build-k1.sh` | 全量构建(K1 不裁任何 crate)+ 架构/glibc 核对 | K1 |
| **`probe-onnx.sh`** | **R1 探针**:候选 .so 定位 → 符号需求比对 → `dlopen`+`GetApi(23)` → 可选一帧 61→14 推理 | K1 |
| **`fetch-ort-from-k3.sh`** | **从 K3 搬 1.24.2+spacemit.a1**(K1 的 apt 只有 1.18.1) | **本机** |
| **`install-ort-k1.sh`** | 把搬来的 ORT 装到 `/opt/microduck-k1/ort/`,写 systemd drop-in + `ORT_DYLIB_PATH` | K1 |
| `sim-drive.py` | 驱动 `robotd`(hello → enable → init → move),与 K3 版**逐字节相同** | K1 |
| **`stub-body.py`** | **板内被控对象替身**:同一套 NDJSON 协议,物理换成限速跟随器 —— 用来把隧道从环率测量里摘掉 | K1 |
| `k3-sim-port.patch` | `--sim` 移植补丁(4 文件 / 529 行 diff),K3 与 K1 通用 | 任意 |
| `patch-webrtcsink.sh` | 给 `webrtcsink` 打补丁(K1 摄像头链路) | K1 |

## 板载环率:为什么需要 `stub-body.py`

正常联调是「仿真在另一台机器 + SSH 反向隧道」。这一跳单独量出来,单次 `read`+`write` 往返
p50 8.7 ms / p90 20.7 ms / p99 61.4 ms —— 而一个 tick 的预算是 20 ms。
丢的帧是隧道丢的,板子的余量被这一跳盖住了。

`stub-body.py` 说的是同一套协议(hello / read / write / gain / torque / slow),只是把物理
换成一个限速跟随器,直接跑在被测的板子上。策略仍然每 tick 真跑,于是量到的就是板子自己:

```bash
# K1 上
python3 stub-body.py 7802 </dev/null >/tmp/stub.log 2>&1 &
ORT_DYLIB_PATH=/opt/microduck-k1/ort/libonnxruntime.so \
  setsid nohup ./target/release/robotd --sim 127.0.0.1:7802 </dev/null >/tmp/robotd-local.log 2>&1 &
./target/release/robotctl health      # loop 50.0 of 50.0 Hz · 0 missed
```

它**不是**仿真:没有物理、没有接触、没有画面。要看鸭子跑,还得用 `microduck_rl` 那套 MuJoCo。

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
# 本机:从 K3 取 ORT(需要 K3 可达)
cd "K1/k1" && ./fetch-ort-from-k3.sh          # 产出 ort-k1/

# 传到 K1
scp -r ort-k1 root@<k1-ip>:/tmp/

# K1 上安装 + 验证
bash /tmp/ort-k1/install-ort-k1.sh
bash probe-onnx.sh /opt/microduck-k1/ort/libonnxruntime.so
```

> `install-ort-k1.sh` **不覆盖 `/usr/lib`** —— 用 `ORT_DYLIB_PATH` 指过去,只影响 `robotd`,
> 不动板上其它依赖 1.18.1 的程序(python3-spacemit-ort 等)。

## 传递脚本到 K1

```bash
K1=root@<k1-ip>

# 整套脚本
scp run-all.sh env-init.sh build-k1.sh probe-onnx.sh install-ort-k1.sh \
    sim-drive.py stub-body.py k3-sim-port.patch "$K1:/tmp/"

ssh "$K1" 'bash /tmp/run-all.sh'
```

> 源码部署见 [`../docs/03-源码获取与构建.md`](../docs/03-源码获取与构建.md)。
> 注意: `fetch-ort-from-k3.sh` 要在**本机**跑(K3 需可达)。
