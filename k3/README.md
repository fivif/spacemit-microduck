# K3 —— 机器鸭运行时的 RISC-V 移植

> 在 **SpacemiT K3（Pico-ITX，8× X100）** 上原生编译并运行 Microduck 的 Rust 运行时。
> 实测日期 2026-09-08。

---

## 目标

把主仓 `microduck` 的运行时（`robotd` 50 Hz 控制环 + 策略执行 + 舵机总线 + 周边 daemon）
原生编译到 riscv64 并跑起来，驱动机器人完成动作链。

仿真与训练**不上板**：`duck-body`（CPU MuJoCo）留在开发机上，通过 `--sim` 与板上的
`robotd` 对接；训练仍走既有的 ONNX 策略链。

---

## 结果

| 项 | 实测 |
|---|---|
| 裁剪构建 | **6m42s**，产出 `robotd` 等 7 个 riscv64 二进制 |
| 策略加载 | 官方 **9 个 ONNX** 经 spacemit ONNX Runtime 1.24.2 全部加载 |
| 起身 | 坐姿检测 `deviation=0.33`，z 0.065 → 0.116 |
| 站立 | **7 s 稳定**，gz = −1.000 |
| 行走 | 15 s 走 **1.45 m**，未摔 |
| 环率 | **46–48 of 50 Hz**（健康门限 45） |
| 单次推理 | **0.201 ms**，占 50 Hz 预算 1.01% |

---

## 目录

```
K3/
├── README.md              本文件
├── docs/
│   ├── 01-总体架构.md      运行时栈分层 + 组件保留/裁剪矩阵
│   ├── 02-构建移植方案.md   工具链 / 依赖审计 / ONNX 对接 / 总线 / 系统服务
│   ├── 03-K3环境实测.md     板卡与环境实测记录
│   ├── 04-K1版前瞻.md       K1 差异分析（已展开为 ../k1/）
│   ├── 05-仿真客户端移植.md  v0.11.0 缺 `--sim`；从上游分支移植（4 文件）
│   └── 06-P1联调实录.md     起身 → 站立 → 行走 实录
├── plans/MILESTONES.md     里程碑
├── policies/               官方策略集（9 ONNX + manifest）
├── local-sim/              开发机侧仿真：duck-body + 观测/测试脚本
├── web/                    Web 控制台（浏览器摇杆）
└── k3/                     板卡侧脚本（env-init / build / sim-drive / bench_policy）
```

---

## 构建

```bash
cd /opt/microduck-k3/microduck
cargo build --release --workspace \
    --exclude mediad --exclude duck-detect --exclude pet-detect
```

裁剪原因：`mediad` 依赖 GStreamer 与厂商硬件编码，riscv64 无对应实现；
`duck-detect` / `pet-detect` 走厂商 NPU 运行时，板上没有。

---

## 复现

```bash
# 开发机：启动仿真（SIT 起始）
cd microduck_rl
PYTHONPATH=src <venv>/Scripts/python.exe \
    -m mjlab_microduck.sim.body_server --port 7801

# 开发机：把仿真端口映射到板子
ssh -N -R 7801:127.0.0.1:7801 root@<board>

# 板子
cd /opt/microduck-k3/microduck
setsid nohup ./target/release/robotd --sim 127.0.0.1:7801 </dev/null >/tmp/robotd.log 2>&1 &
python3 sim-drive.py --enable --init --vx 0 --seconds 8   # 起身 + 站立
python3 sim-drive.py --vx 0.25 --seconds 16               # 行走
./target/release/robotctl health
```

---

## 相关

| 内容 | 位置 |
|---|---|
| 移植全过程与踩坑 | [`docs/01`–`06`](docs) |
| 策略运行时开销实测 | [`../docs/POLICY-RUNTIME.md`](../docs/POLICY-RUNTIME.md) |
| K1 版本 | [`../k1/`](../k1) |
