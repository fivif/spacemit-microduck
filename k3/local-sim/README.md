# local-sim — 本地(x86 Windows)Microduck 仿真

> 仿真与训练**不上 K3**(决策见上级 README);本目录就是"本地跑仿真"的落地物:
> 用 MuJoCo 跑鸭子身体,通过 TCP/NDJSON 暴露给"大脑"(robotd)。
> **实测日期 2026-09-08**,Windows 11 + uv 0.12.5。

## 组成

| 文件/目录 | 说明 |
|---|---|
| `.venv/` | `uv venv` + `mujoco==3.12.0` + `numpy==2.5.3`(不装 torch/mjlab,仿真身体不需要) |
| `test-client.py` | 最小 robotd 替身:说同款协议(hello/read/write/gain/torque),做 SIT→HOME ramp 与 50Hz 计时 |
| 仿真本体 | 直接用 `microduck_rl/src/mjlab_microduck/sim/body_server.py`(**不复制**,PYTHONPATH 指过去) |

## 运行

```bash
# 1. 启动身体(带 MuJoCo 窗口;--headless 无窗口)
cd microduck_rl
PYTHONPATH=src python -m mjlab_microduck.sim.body_server --port 7801 --keyframe HOME

# 2. 客户端验证(另一个终端)
python test-client.py --steps 250
```

`--keyframe`:`SIT`(默认,折叠待命)/`HOME`(站立放置,trunk z=0.125)/`STAND`/`FOLD`。

## 实测结果(2026-09-08)

| 项 | 结果 |
|---|---|
| 协议握手 | `{"op":"hello","protocol":1}` → `{"protocol":1}`  |
| 关节数(线上) | **15**(含 mouth;daemon 的 JOINT_NAMES) |
| 控制频率 | 250 tick / 5.00 s = **50.0 Hz**,最差迟到 0.0 ms  |
| 传感器 | trunk_z / imu.gravity(投影重力)/ quat / gyro / currents_ma 全部可读  |
| 从 SIT 线性 ramp 起立 | **会摔倒**(见下) |
| 保持 HOME 静态姿势 | **会摔倒**(设计如此,见下) |

### 关键物理事实(不是 bug)

`body_server.py:249-253` 注释原文:

> A biped at a static pose is not stable: holding the home pose with position control alone
> puts this duck on the ground in under a second, at any timestep, from any placement —
> `infer_policy.py` never does it, because it has the policy balancing from step zero.

因此:
- **两足机器人静态姿势本就站不住**,必须由策略实时平衡;
- 未被 daemon 接管前,`World.step()` 每步 `restore()` 把鸭子冻结在放置姿态(`released=False`);
- 一旦 daemon 发 `torque:on`(`released=True`),冻结解除 → 没有策略就会倒;
- 从 SIT 起身**不是**线性 ramp —— 真机走 sitstand/起身策略(`robotd` 的坐姿启动分支)。

> 这三条决定了"本地仿真"的正确用法:**要么只看被冻结的放置姿态,要么必须让策略/robotd 接管。**

## K3 ↔ 本地仿真(SSH 端口转发)

开发机的仿真端口通过 SSH 转发到板子的 localhost:

```bash
# 在 Windows(Git Bash),把本机 7801 映射到 K3 的 localhost:7801
ssh -N -R 7801:127.0.0.1:7801 root@<board> \
    -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes
```

K3 侧验证(已实测 ):
```bash
python3 -c "import socket,json; s=socket.create_connection(('127.0.0.1',7801)); ..."
# → hello {'protocol': 1} / trunk_z=0.1250 / joints=15 / gz=-1.000
```

于是 K3 上的 robotd 可以用**默认地址**:`robotd --sim 127.0.0.1:7801`。

## 联调结果(2026-09-08,详见 `../docs/06-P1联调实录.md`)

K3 原生编译的 robotd + 官方 ONNX 策略 → 本仿真鸭:

| 阶段 | 结果 |
|---|---|
| 坐姿检测 | `seated boot detected deviation=0.33` |
| 起身(sitstand) | z 0.065 → 0.116 |
| 站立 | 7 s 稳定,z=0.116,gz=-1.000 |
| 行走(vx=0.25 命令) | 15 s 走 **1.45 m**(实测 0.097 m/s),未摔倒 |
| 环率 | 46–48 of 50 Hz(隧道下,健康门限 45) |

**速度跟踪只有 ~39%**:本仿真的 `scene.xml` 是简单位置执行器,策略训练用的是 BAM 摩擦/电压模型
(sim-to-sim gap)。站立/平衡不受影响。速度保真请用 `microduck_rl/scripts/infer_policy.py`(BAM M6)。

**viewer 提示**:开窗口做演示可以,但**做性能/时序测量请用 `--headless`**(渲染会拖慢实时步进)。
