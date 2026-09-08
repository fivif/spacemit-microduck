# 里程碑

> 验收明确、单步可回退。仿真/训练不搬 K3(已在 README 定语)。
> **2026-09-08 更新:P0 ✅、P1 核心 ✅(见 `docs/06-P1联调实录.md`)**

## P0 · 核心闭环 ✅ 完成(2026-09-08)

| 步骤 | 状态 |
|---|---|
| 1. rustup 安装(riscv64gc) | ✅ |
| 2. clone 主仓 `/opt/microduck-k3/microduck` | ✅ |
| 3. 裁剪构建(`--exclude mediad duck-detect pet-detect`) | ✅ **6m42s,全绿**(robotd 7.3 MB 等 7 个二进制) |
| 4. `--sim` 移植(v0.11.0 缺,见 `docs/05`) | ✅ 4 文件,`cargo check` + release 通过 |
| 5. 本地仿真 `duck-body` | ✅ 50.0 Hz 精确 / 协议 / 15 关节 |
| 6. K3 ↔ 本地仿真协议连通 | ✅ 反向隧道 + 协议实测 |
| 7. ONNX Runtime 兼容性(原 R1 风险) | ✅ 官方策略全部加载并推理成功 |

## P1 · 策略链 ✅ 核心完成

| 步骤 | 状态 |
|---|---|
| 1. `robotd --sim` 接本地 duck-body | ✅ 自动重连、50 Hz 环、healthy |
| 2. 官方策略集(9 ONNX) | ✅ `/opt/robot/policies/current` |
| 3. 起身→站立→行走 | ✅ SIT 起身 → 站立 7 s 稳定 → 行走 1.45 m 未摔 |
| 4. 速度保真 | ⚠️ 实测 0.097 vs 命令 0.25 m/s(sim-to-sim gap,见 `docs/06` §5) |
| 5. 环率(隧道下) | ✅ 46–48 of 50 Hz(健康门限 45) |

**剩余(可选)**:换 `infer_policy.py` 的 BAM 场景验证速度保真;`robotctl` 全命令面回归;多鸭。

## P2 · 真机替换(需硬件,~数天)

1. UART 引脚/电平核对(1Mbps 总线)
2. 供电方案(Pico-ITX vs 原 5V)+ 尺寸试装
3. 裁剪 daemon 集 systemd units(Bianbu)
4. IMU(id200)+ 15 舵机回读 → 与原平台基线对比
5. 视觉:原 rknn 检测器禁用后,机载视觉**下一步**是 SpaceMIT EP 化(60TOPS)——另立项

## P3 · K1 平移(后续)

- 在 K1(MUSE 形态优先)上重跑 P0(预期 <1 天,工具链同);
- 决策:案例双版本呈现(K3 算力标杆 + K1 落地形态)见 docs/04。
