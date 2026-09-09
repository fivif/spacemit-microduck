<div align="center">

# spacemit-microduck

**把 Microduck 机器鸭的运行时原生跑在 SpacemiT RISC-V（K3 / K1）上。**

[![License](https://img.shields.io/badge/license-Apache--2.0-3b82f6?style=flat-square)](microduck/LICENSE)
[![Platform](https://img.shields.io/badge/platform-riscv64-8b5cf6?style=flat-square)](#状态)
[![Boards](https://img.shields.io/badge/boards-K3%20%7C%20K1-06b6d4?style=flat-square)](#状态)
[![Control loop](https://img.shields.io/badge/control%20loop-50%20Hz-22c55e?style=flat-square)](#实测)

[English](README.md) · 中文

</div>

---

Microduck 是一台约 25 cm 高的双足机器人，由强化学习策略驱动。它的运行时是一个 Rust
workspace：50 Hz 控制环、ONNX 策略执行、舵机总线，以及周边的一圈 daemon。
本仓库把这套运行时原生编译到 SpacemiT 的 RISC-V 芯片上并真正驱动机器人，
训练与仿真链路保持留在 x86/GPU 侧不变。

![架构：板子跑运行时，开发机跑仿真](docs/assets/architecture.svg)

## 状态

| | K3 | K1 |
|---|---|---|
| 芯片 | 8× X100 @2.4 GHz，60 TOPS NPU | 8× X60 @1.8 GHz，2 TOPS（CPU 内融合） |
| 板卡 | K3 Pico-ITX | MUSE-Pi-Pro |
| 定位 | 性能平台 | 集成形态 |
| 结果 | 跑通 | 跑通 |

两块板都能原生构建运行时、加载官方 9 个 ONNX 策略，并驱动 MuJoCo 里的鸭子在
不摔倒的情况下完成起身、行走和转向。

![K1 与 K3 对比](docs/assets/board-comparison.svg)

## 实测

![一个控制周期](docs/assets/tick-budget.svg)

<details>
<summary>K3 —— 完整记录</summary>

| 指标 | 值 |
|---|---|
| 裁剪构建 | 6m42s，7 个 riscv64 二进制 |
| 策略加载 | 官方 9 个 ONNX，经 spacemit ONNX Runtime 1.24.2 |
| 动作链 | 起身（z 0.065 → 0.116）、站立 7 s、行走 1.45 m |
| 控制环率 | 46–48 of 50 Hz，0 丢帧 |
| 单次推理 | 0.201 ms（p99 0.223）—— 占 20 ms 周期的 1.01% |
| 整环 CPU | 约 1.2% 单核 |
| 速度跟踪 | 命令 0.25 m/s，实测 0.097 m/s（sim-to-sim gap） |

</details>

<details>
<summary>K1 —— 完整记录</summary>

| 指标 | 值 |
|---|---|
| 裁剪构建 | 43m39s，313 crate，`robotd` 7.3 MB |
| 空载环率 | 50.0 of 50 Hz，0 丢帧 |
| 动作链 | 起身、行走 1.245 m、转向，未摔 |
| 联调环率 | 46.5–48.5 of 50 Hz |
| 满载环率 | 40.7 Hz —— 低于 45 Hz 健康门限 |
| CPU 温度 | 50 °C |

</details>

完整记录（含复现命令与各自的踩坑）在 [`docs/`](docs)。

## 用浏览器操控

同一个控制台跑在板子上，通过 daemon 的 IPC 驱动鸭子：摇杆、一次性技能、实时姿态与健康。
它自己不持有机器人状态——驱动流以 20 Hz 转发，浏览器离开后自动停止。

<div align="center">
  <img src="k3/web/ui-desktop.png" width="46%" alt="控制台，桌面布局">
  <img src="k3/web/ui-phone.png" width="26%" alt="控制台，手机布局">
</div>

## 策略从哪里来

![流水线：训练、导出、发布、加载、验证](docs/assets/pipeline.svg)

## 仓库结构

```
spacemit-microduck/
├── microduck/   运行时源码：上游 v0.11.0 + robotd --sim 客户端
├── k3/          K3：设计笔记、环境实测、联调实录、脚本、策略集、控制台
├── k1/          K1：设计笔记、环境实测、运行时版本处理、联调实录、脚本
└── docs/        实测记录
```

## `--sim` 客户端

上游 v0.11.0 没有 daemon 侧的仿真客户端，所以 `robotd` 在没有机器人的情况下无法被验证。
本仓库补上了它，从上游 `sim-remote-io` 分支移植到当前代码树，并保留了 policy channel：

| 文件 | 改动 |
|---|---|
| `duck-control/src/sim.rs` | 新增 —— `RemoteIo`，439 行 |
| `duck-control/src/lib.rs` | `+ pub mod sim;` |
| `duck-control/Cargo.toml` | `+ serde_json` |
| `robotd/src/main.rs` | `+ --sim` 参数与启动分支 |

连接是懒建立、每 tick 重试的：先起 daemon 后起仿真，daemon 会一直报不健康直到仿真应答；
仿真重启也不需要重启机器人。

针对 RISC-V 的裁剪构建（去掉 GStreamer 与厂商 NPU 运行时）：

```bash
cargo build --release --workspace \
    --exclude mediad --exclude duck-detect --exclude pet-detect
```

## 文档

| 文档 | 内容 |
|---|---|
| [`docs/K3-PORT.md`](docs/K3-PORT.md) | K3 移植：目标、环境、构建、`--sim` 缺口、联调结果、踩坑 |
| [`docs/POLICY-RUNTIME.md`](docs/POLICY-RUNTIME.md) | 一次推理的开销，以及六个网络是怎么选的 |
| [`docs/K1-PORT.md`](docs/K1-PORT.md) | K1 移植：环境、构建、ONNX Runtime 版本冲突与解决 |

## 许可与来源

本仓库是派生作品，遵循上游许可：

- `microduck/` —— 派生自 [pollen-robotics/microduck](https://github.com/pollen-robotics/microduck)，Apache-2.0，见 `microduck/LICENSE`
- `k3/policies/` —— 官方策略集 [pollen-robotics/microduck-policies](https://huggingface.co/pollen-robotics/microduck-policies)，Apache-2.0
- `k3/`、`k1/`、`docs/` —— 本项目原创

不在本仓库内：`microduck_rl`（训练）、`mjlab`、`bam` 各有独立上游仓库；
Microduck 的 3D 模型与硬件设计由其作者单独授权。
