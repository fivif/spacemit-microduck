# K3 版 — 机器鸭换脑 · 算力标杆

> 上级目录: [`../README.md`](../README.md)(案例总入口)· 对外策划稿:[`../Microduck 机器鸭 × 进迭时空 优秀案例策划.md`](../Microduck%20机器鸭%20×%20进迭时空%20优秀案例策划.md)
>
> **日期**: 2026-09-08 · **立项**: Microduck 软件栈 × SpacemiT K3(第一站)/ K1(后续)
> **K3**: `jax-spacemitk3picoitx` · 10.5.90.195 / root:bianbu(yolos-box 同款机)
> **K1**: 后续目标,K3 方案平移(见 [`docs/04`](docs/04-K1版前瞻.md) 与 [`../K1/README.md`](../K1/README.md))
>
> **一句话目标(2026-09-08 方向定稿)**: **用 SpacemiT K3 替换 Microduck 真机的瑞芯微大脑
> (RK3566 / Radxa Zero 3W)** —— 即把 microduck 主仓的 **Rust 运行时软件栈** 移植到 RISC-V;
> 仿真与训练**不搬 K3**(继续留在 x86/GPU 开发链,训练结果通过既有的 ONNX 策略链下发)。

---

## 方向(用户定稿,区别于早期草案)

| 线 | 决策 |
|---|---|
| 仿真环境 | **不上 K3** —— `duck-body`(CPU MuJoCo)与 `robotd --sim` 停在 x86 开发台;K3 只跑真机代码 |
| 训练 | **不上 K3** —— mjlab+MuJoCo Warp+PPO 需 NVIDIA GPU,本就不行(CUDA 专属) |
| **核心目标** | **替换瑞芯微**:microduck 主仓运行时(robotd 50Hz 环 + 策略 + 总线 + 周边 daemon)在 K3 上原生编译运行 |
| 后续 | K1 平移(同方法,CPU 更弱的一档,无 EP NPU) |

**案例叙事**: RISC-V AI CPU(60 TOPS)当"鸭脑" —— 真机舵机总线直接由 SpacemiT 板驱动,RL 步态策略经 ONNX Runtime(带官方 EP)执行;换脑意味着控制环算力富余量大增,为后续机载视觉(鸭子检测等,现为 Rockchip NPU 专属)留出空间。

---

## 现状基线

| 项 | RK3566(现状脑) | K3(目标脑) | 结论 |
|---|---|---|---|
| CPU | 4×A55 @1.8GHz | 8×X100 @2.4GHz(单核 SPECint 9.5 ≈ A76) | ✅ 约 2-4× 富余 |
| OS | Armbian(Trixie, glibc ≥2.31) | Bianbu 4.0.1(glibc 2.43) | ✅ 同代 systemd |
| ONNX Runtime | 地板 1.23 | **1.24.2+spacemit.a1 + EP 主库(已装)** | ✅✅ 超地板 |
| Media/NPU 加速 | rknn + mpp h264 + webrtcsink | 无对应(无摄像头;EP 是推理 EP) | ❌ **需裁剪** |
| 舵机总线 | /dev/ttyS2(1Mbps UART) | K3 有 15×UART | ✅ 可接,板级待验 |
| 供电/尺寸 | Radxa Zero 3W ~4×2cm | K3 Pico-ITX 2.5" | ⚠️ 真机集成需评估(见 01) |

## 目录

```
K3/                          ← 本目录(案例的 K3 版本)
├── README.md            ← 本文件(方向/基线/里程碑)
├── docs/
│   ├── 01-总体架构.md          K3 版运行时栈分层 + 组件保留/裁剪/替换矩阵
│   ├── 02-构建移植方案.md      工具链/依赖审计/ONNX 对接/UART 电气/系统服务
│   ├── 03-K3环境实测.md        ★2026-09-08 SSH 实测实录
│   ├── 04-K1版前瞻.md          K1 差异 + 平移策略(已展开为 ../K1/)
│   ├── 05-仿真客户端移植.md    ★v0.11.0 缺 `--sim`;从上游 sim-remote-io 分支移植(4 文件)
│   └── 06-P1联调实录.md        ★★K3 大脑驱动 MuJoCo 鸭:起身→站立→行走 1.45 m 实录
├── plans/
│   └── MILESTONES.md           P0 ✅ → P1 核心 ✅ → P2 真机 → P3 K1
├── policies/                   官方策略集(9 ONNX + manifest,HF 经 10808 代理下载)
├── local-sim/                  本地(x86)仿真:duck-body + 观测/测试脚本 + 反向隧道说明
├── web/                        ★Web 控制台(iOS 26 液态玻璃风):http://10.5.90.195:8081/
└── k3/
    ├── env-init.sh             K3 环境初始化(rustup/克隆)
    ├── build-k3.sh             裁剪构建(--exclude 列表)
    ├── sim-drive.py            K3 侧驱动(hello/enable/init/move 意图流)
    └── README.md               k3 侧文件说明
```

## 里程碑速览

| 里程碑 | 验收标准 | 状态 |
|---|---|---|
| **P0 核心闭环** | K3 上编译出 robotd;`ort` 吃上 spacemit ONNX Runtime | ✅ **2026-09-08 完成**(6m42s 构建全绿) |
| **P1 策略链** | 官方策略驱动仿真鸭:起身/站立/行走 | ✅ **核心完成**:SIT 起身 → 站立 7s → 行走 1.45m 未摔(见 `docs/06`) |
| **P2 真机替换** | 裁剪版 robotd 在 K3 驱动 XL330 总线 | 需硬件 |
| **P3 K1 平移** | K1 板(CPU-only ORT)跑通 P0 | 后续,见 [`../K1/README.md`](../K1/README.md) |
