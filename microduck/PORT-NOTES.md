# microduck_src — K1 版项目代码

> **这是 K1 版要编译的完整源码**,即主仓 `microduck`(上游 v0.11.0 / `main` `5984efb`)
> **加上 `--sim` 移植补丁**(本地分支 `k3-sim-port` 的 4 个文件改动)。
> **K1 上一行不改** —— 差异全在板卡与运行环境,不在代码。

## 与上游的差异(仅 4 个文件)

| 文件 | 改动 | 行数 |
|---|---|---|
| `duck-control/src/sim.rs` | **新增** —— `RemoteIo`:daemon 侧的 TCP 仿真客户端 | 439 |
| `duck-control/src/lib.rs` | +`pub mod sim;` | 2 |
| `duck-control/Cargo.toml` | +`serde_json = { workspace = true }` | 3 |
| `robotd/src/main.rs` | +`--sim: Option<String>` 参数 + 启动分支 | 31 |

> 等价于 `git apply ../k1/k3-sim-port.patch`。这里直接给**已应用补丁的完整树**,
> 省掉 K1 上的打补丁步骤(板子上没有 `.git`,也不方便解冲突)。
> 四文件 md5 已与本地 `k3-sim-port` 工作树逐一核对一致。

## 结构

24 个 crate(workspace),其中:

| 会编译 | 被裁剪 | 原因 |
|---|---|---|
| `robotd` / `duck-control` / `duck-ipc-proto` / `robotctl` / `duckctl` / `updater` / `kinematics` / `odometry` / `sounds` / `tof` / `padd` / `configd` / `btd` / `robotd-params` / `test-support` / `xtask` | `mediad` | gstreamer 硬 C 依赖,riscv64 无 mpp 适配 |
| | `duck-detect` / `pet-detect` | 走 rknn `.so` dlopen,riscv64 无 NPU 库 |

构建命令(见 [`../k1/build-k1.sh`](../k1/build-k1.sh)):

```bash
cargo build --release --workspace \
    --exclude mediad --exclude duck-detect --exclude pet-detect
```

## 怎么送到 K1

K1 上 **`github.com` 不可达**(实测 000),`git clone` 必失败。从本机打包:

```bash
# 本机
cd "/c/Users/zhuxuanjia/Desktop/Work_World/Microduck 机器鸭 × 进迭时空 优秀案例/K1"
tar czf /tmp/microduck-k1-src.tar.gz microduck_src

ASKPASS="$(mktemp)"; printf '#!/bin/sh\necho "bianbu"\n' > "$ASKPASS"; chmod +x "$ASKPASS"
SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force DISPLAY=:0 \
  scp -O -o StrictHostKeyChecking=accept-new -o PreferredAuthentications=password \
      -o PubkeyAuthentication=no /tmp/microduck-k1-src.tar.gz root@<k1-ip>:/opt/microduck-k1/

# K1
cd /opt/microduck-k1 && tar xzf microduck-k1-src.tar.gz && mv microduck_src microduck
```

> `env-init.sh` 期望的解包结果是 `/opt/microduck-k1/microduck`,
> 所以最后一步 `mv microduck_src microduck` 不能省(或用 `--transform` 解包时改名)。
> 本目录**不含 `.git` 与 `target/`**(22 MB),不需要它们。

## 相关

| 内容 | 位置 |
|---|---|
| `--sim` 补丁(可 `git apply`) | [`../k1/k3-sim-port.patch`](../k1/k3-sim-port.patch) |
| 移植背景与缺口定位 | [`../../K3/docs/05-仿真客户端移植.md`](../../K3/docs/05-仿真客户端移植.md) |
| K1 环境与构建 | [`../docs/02-K1环境实测.md`](../docs/02-K1环境实测.md) · [`../docs/03-源码获取与构建.md`](../docs/03-源码获取与构建.md) |
