# microduck — 可直接编译的完整源码树

> 这是本仓库自带的完整源码:上游 `pollen-robotics/microduck` v0.11.0(`main` `5984efb`)
> **已应用 `--sim` 移植补丁**,并加了检测器的 SpaceMIT EP 后端。K3 / K1 两侧都拿这棵树编译。
> **控制环一行未改** —— 差异全在板卡与运行环境,不在控制环的代码;感知侧是加法,清单见下。

## 与上游的差异(6 个文件)

| 文件 | 改动 | 行数 |
|---|---|---|
| `duck-control/src/sim.rs` | **新增** —— `RemoteIo`:daemon 侧的 TCP 仿真客户端 | 439 |
| `duck-control/src/lib.rs` | +`pub mod sim;` | 2 |
| `duck-control/Cargo.toml` | +`serde_json = { workspace = true }` | 3 |
| `robotd/src/main.rs` | +`--sim: Option<String>` 参数 + 启动分支 | 31 |
| `duck-detect/src/spacemit.rs` | **新增** —— SpaceMIT EP 加载器:厂商私有 C 入口 + `RTLD_GLOBAL` | 257 |
| `duck-detect/src/{lib,onnx}.rs`、`src/bin/duck-bench.rs`、`mediad/src/detect.rs` | +后端选择(EP 优先,不可用退 CPU);`--backend` 参数 | — |

前 4 行等价于 `git apply ../k1/k1/k3-sim-port.patch`;后 2 行是**加法** ——
新增一个后端,原有 `rknn.rs` / `onnx.rs` 的推理路径、`mediad` 的取帧与解码、控制环全部未动。
详见 [`../docs/K1-PORT.md`](../docs/K1-PORT.md) §7。

> **模型文件已换**:`duck-detect/models/duck_detect.onnx` 现在是 **opset 17**(原文件为 opset 12)。
> 原因是厂商 EP 编不过 opset-12 图里的 `Split`(尺寸还写在属性里),症状是**挂死**不是报错。
> 转换对这个图**逐位相同**(最大绝对差 0.000e+00)。`.rknn` 未动,Rockchip 那条路不受影响。

## 结构

24 个 crate(workspace),K1 现在**一个都不裁**,全部会编译:

| 全部会编译 | 曾经被裁 | 原因 |
|---|---|---|
| `robotd` / `duck-control` / `duck-ipc-proto` / `robotctl` / `duckctl` / `updater` / `kinematics` / `odometry` / `sounds` / `tof` / `padd` / `configd` / `btd` / `robotd-params` / `test-support` / `xtask` / `pet-detect` / `duck-detect` / `mediad` | (无) | — |

`mediad` 也曾被 K1 的构建脚本排除,理由写的是「gstreamer 硬 C 依赖,riscv64 无 mpp 适配」。
**这条对 K1 不成立**:真正的原因是板上没装 GStreamer 的 `-dev` 包
(`libgstreamer1.0-dev` / `libgstreamer-plugins-base1.0-dev` / `libgstreamer-plugins-bad1.0-dev`),
riscv64 并不缺 GStreamer/厂商编码支持。装齐后 `--exclude mediad` 已从
[`../k1/k1/build-k1.sh`](../k1/k1/build-k1.sh) 撤销(2026-09-11),`mediad` 能编能跑 ——
USB 摄像头链路 MJPEG → UYVY → `spacemith264enc`(硬件 H.264)→ WebRTC 出实帧。

`duck-detect` 曾经也被裁,理由和 `pet-detect` 一样是"dlopen = rknn"。**那条理由现在不成立**:
`dlopen` 的东西编译期本来就不需要那个运行时,而它运行期有三条路 —— Rockchip 的 `rknn`、
SpaceMiT 的 EP、以及两者都没有时的 CPU;`duck-bench` 也在这个 crate 里,是板上唯一能把三条路
分别测一遍的工具。`2026-09-10` 起两个构建脚本都去掉了 `--exclude duck-detect`。

`pet-detect` 一度和 `duck-detect` 一起被排掉,理由是"dlopen = rknn"。**这个理由不成立**,
而且那个排除**从来没生效过**:`robotd/Cargo.toml` 依赖 `pet-detect`,
`--exclude` 只挡顶层产物、挡不住被依赖的库 —— `pet-detect` 的代码一直编在 `robotd` 里,
少的只是 `pet-detect` / `pet-features` 两个独立二进制。
它的依赖是 `ort {load-dynamic}` + `rustfft` + `hound`,和 `robotd` 是同一条 ORT 路径,
模型 20 KB。已在 K1 上实测编译并运行(见 [`../k1/docs/05-联调实录.md`](../k1/docs/05-联调实录.md))。

构建命令(见 [`../k1/k1/build-k1.sh`](../k1/k1/build-k1.sh) / [`../k3/k3/build-k3.sh`](../k3/k3/build-k3.sh)):

```bash
cargo build --release --workspace                     # K1:不裁任何 crate
cargo build --release --workspace --exclude mediad    # K3 的 build-k3.sh 目前仍排除 mediad
```

`duck-detect` 一度和 `pet-detect` 一起被排掉,理由同样是"dlopen = rknn"。**它现在也不裁了**:
`dlopen` 的东西编译期不需要那个运行时,而它运行期有三条路 —— Rockchip 的 `rknn`、SpaceMiT 的
`OrtSessionOptionsSpaceMITEnvInit`(`src/spacemit.rs`)、以及两者都没有时的 CPU。`duck-bench`
也在这个 crate 里,而它是板上唯一能把这三条路分别测一遍的工具。

## 怎么送到板上

本目录**不含 `.git` 与 `target/`**(约 22 MB),打包传过去即可:

```bash
# 开发机
tar czf /tmp/microduck-src.tar.gz microduck
scp /tmp/microduck-src.tar.gz root@<board>:/opt/

# 板子
cd /opt && tar xzf microduck-src.tar.gz && mv microduck microduck-k3   # K1 则改 microduck-k1
```

> 两侧脚本期望的解包结果是 `/opt/microduck-k3/microduck`(K1 为 `/opt/microduck-k1/microduck`),
> 所以最后一步改名不能省(或用 `tar --transform` 解包时改)。
> 完整流程见 [`../k1/docs/03-源码获取与构建.md`](../k1/docs/03-源码获取与构建.md)。

## 相关

| 内容 | 位置 |
|---|---|
| `--sim` 补丁(可 `git apply`) | [`../k1/k1/k3-sim-port.patch`](../k1/k1/k3-sim-port.patch) |
| 移植背景与缺口定位 | [`../k3/docs/05-仿真客户端移植.md`](../k3/docs/05-仿真客户端移植.md) |
| K3 移植总览 | [`../docs/K3-PORT.md`](../docs/K3-PORT.md) |
| K1 环境与构建 | [`../k1/docs/02-K1环境实测.md`](../k1/docs/02-K1环境实测.md) · [`../k1/docs/03-源码获取与构建.md`](../k1/docs/03-源码获取与构建.md) |
