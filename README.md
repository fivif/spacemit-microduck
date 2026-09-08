<p align="center">
  <b>SpacemiT × Microduck</b>
</p>

<h1 align="center">spacemit-microduck</h1>

<p align="center">
  <em>换脑：把 Microduck 机器鸭的运行时搬到 SpacemiT RISC-V（K3 / K1）。</em>
</p>

---

用 **SpacemiT K3 / K1** 替换 Microduck 真机的瑞芯微 RK3566 大脑 ——
把主仓 `microduck` 的 Rust 运行时软件栈**原生编译到 RISC-V**。
**仿真与训练不上板**（继续留在 x86/GPU 开发链，训练结果经既有 ONNX 策略链下发）。

## 结果

| | K3 | K1 |
|---|---|---|
| 芯片 | 8× X100 @2.4GHz · 60 TOPS EP | 8× X60 @1.8GHz · 2 TOPS（CPU `_ime`） |
| 板卡 | K3 Pico-ITX | **MUSE-Pi-Pro** |
| 角色 | 算力标杆 | 落地形态 |
| 状态 | ✅ P0 + P1 跑通 | 🟡 环境就绪，构建/联调待完成 |

**K3 实测**（2026-09-08/09，Bianbu 4.0.1）：

| 指标 | 值 |
|---|---|
| 裁剪构建 | **6m42s** 全绿 → `robotd` 等 7 个 riscv64 二进制 |
| 策略加载 | 官方 **9 个 ONNX** 经 spacemit ONNX Runtime 1.24.2 全部加载 |
| 动作链 | 坐姿起身（z 0.065→0.116）→ 站立 **7 s 稳定** → 行走 **1.45 m 未摔** |
| 控制环率 | **46–48 of 50 Hz**（SSH 隧道下，健康门限 45）· 0 missed ticks |
| 单次推理 | **0.201 ms**（p99 0.223）—— 占 50 Hz 预算 **1.01%** |
| 整环 CPU | **约 1.2% 单核**（8 核 K3 上 ≈ 0.15% 总算力） |
| 速度跟踪 | ⚠️ 命令 0.25 m/s → 实测 0.097 m/s（39%）—— sim-to-sim gap，见 `docs/K3-PORT.md` §6 |

> 完整数据与复现命令：[`docs/K3-PORT.md`](docs/K3-PORT.md) ·
> [`docs/POLICY-RUNTIME.md`](docs/POLICY-RUNTIME.md) ·
> 基准脚本 [`k3/k3/bench_policy.py`](k3/k3/bench_policy.py)

## 目录

```
spacemit-microduck/
├── microduck/     K1 要编译的完整源码(上游 v0.11.0 + robotd --sim 客户端)
├── k3/            K3 版:方案 / 环境实测 / 联调实录 / 脚本 / 策略 / Web 控制台
├── k1/            K1 版:方案 / 环境实测 / 源码转储 / R1 风险 / 脚本
└── docs/          实测数据:换脑移植 / 策略运行时 / K1 进展
```

### `microduck/` —— 运行时源码

上游 [`pollen-robotics/microduck`](https://github.com/pollen-robotics/microduck) `@5984efb` (v0.11.0)，
加上 **daemon 侧 TCP 仿真客户端 `--sim`**（v0.11.0 缺失，从上游 `sim-remote-io` 分支移植）：

| 文件 | 改动 |
|---|---|
| `duck-control/src/sim.rs` | **新增** —— `RemoteIo`，439 行 |
| `duck-control/src/lib.rs` | `+ pub mod sim;` |
| `duck-control/Cargo.toml` | `+ serde_json` |
| `robotd/src/main.rs` | `+ --sim` 参数与启动分支 |

裁剪构建（riscv64 无 gstreamer / rknn 适配）：

```bash
cargo build --release --workspace \
    --exclude mediad --exclude duck-detect --exclude pet-detect
```

### `k3/` —— K3 版

`docs/01–06`（架构 / 移植方案 / 环境实测 / K1 前瞻 / `--sim` 移植 / P1 联调实录）·
`k3/`（env-init / build / sim-drive 脚本）· `policies/`（9 个官方 ONNX + manifest）·
`web/`（单页控制台）· `local-sim/`（x86 侧 MuJoCo 身体 + 隧道说明）。

### `k1/` —— K1 版

`docs/01–04`（方案 / 环境实测 / 源码转储 / **R1 风险**）·
`k1/`（run-all / build / **probe-onnx** / **fetch-ort-from-k3** / **install-ort** / sim-drive / patch）·
`plans/MILESTONES.md`。

**K1 实测要点**：板卡 = `spacemit k1-x MUSE-Pi-Pro board`（8×X60、Bianbu 2.3.3、3.8 GiB）；
K1 上 `github.com` 不可达（源码须从本机打包 scp）；
⚠️ **K1 的 apt 只有 `libonnxruntime.so.1.18.1`，低于主仓地板 1.23**（K3 预装 1.24.2+spacemit.a1 才没事）。

### `docs/` —— 实测数据

| 文件 | 内容 |
|---|---|
| [`K3-PORT.md`](docs/K3-PORT.md) | K3 换脑移植：目标边界 / 环境 / 构建 / `--sim` 缺口与移植 / 联调结果 / **10 条踩坑** / 复现命令 |
| [`POLICY-RUNTIME.md`](docs/POLICY-RUNTIME.md) | 策略运行时实测：一次 tick 的推理路径 / 单次耗时 / 整环 CPU / 六网选择 / 加载校验 |
| [`K1-PORT.md`](docs/K1-PORT.md) | K1 进展：板卡确认 / 环境安装 / 源码转储 / **R1（ORT 版本冲突）** / 未验证项 |

> 三份都是**实测记录**，不是设计文档。数字旁边都标了测量方法与前提（比如 CPU 数据是在非空载的板子上取的，偏保守）。

## 许可与来源

本仓库是派生作品，遵循上游许可：

- `microduck/` —— 派生自 [`pollen-robotics/microduck`](https://github.com/pollen-robotics/microduck)，**Apache-2.0**，见 `microduck/LICENSE`
- `k3/policies/` —— 官方策略集 [`pollen-robotics/microduck-policies`](https://huggingface.co/pollen-robotics/microduck-policies)，**Apache-2.0**
- `k3/`、`k1/`、`docs/` 的文档与脚本 —— 本项目原创

**不在本仓库内**（体积 / 许可原因）：

- `microduck_rl`（训练环境）、`mjlab`、`bam` —— 各有独立上游仓库
- Microduck 的 3D 模型 / 硬件设计 —— 上游单独授权，非 Apache-2.0
- 真机换脑的硬件工作（舵机总线 / 供电 / 装机）—— 需硬件，未开展
