# K3 移植案例 —— 用 SpacemiT K3 作为机器鸭大脑

> **一句话**:把主仓 `microduck`(Rust 运行时)原生编译到 **SpacemiT K3(riscv64)**,
> 加载官方 ONNX 策略驱动机器人 —— 软件层面证明"**RISC-V 换脑**"成立。
> **实测日期 2026-09-08**;完整工程记录见
> `Desktop\Work_World\Microduck 机器鸭 × 进迭时空 优秀案例\K3\`。

---

## 1. 目标与边界

| 线 | 决策 |
|---|---|
| **核心目标** | 用 SpacemiT K3 作为真机大脑(原平台核心板) |
| 仿真环境 | **不上板** —— `duck-body`(CPU MuJoCo)+ `robotd --sim` 留在 x86 开发台 |
| 训练 | **不上板** —— mjlab + MuJoCo Warp + PPO 是 NVIDIA CUDA 专属,与芯片无关 |
| 后续 | K1 平移(同方法,CPU 更弱一档,无独立 EP 库) |

**为什么可行**:主仓唯一的硬 C 依赖是 `mediad` 的 gstreamer(可裁剪);
`ort` 用 **load-dynamic**(dlopen 现有 `libonnxruntime.so`,不编译 C++ 部分),
K3 的 Bianbu 已装 **ONNX Runtime 1.24.2+spacemit.a1 + EP 主库**,高于主仓地板 1.23。

---

## 2. 环境事实(K3 实测)

| 项 | 值 |
|---|---|
| 板卡 | `jax-spacemitk3picoitx`(K3 Pico-ITX)· 10.5.90.195 / `root:bianbu` |
| CPU | 8× X100 @2.4GHz(RVA23) |
| OS | Bianbu 4.0.1,glibc 2.43 |
| 工具链 | gcc/g++ 15.2、git、make 已有;`cmake` 需 apt |
| Rust | rustup 安装,`riscv64gc-unknown-linux-gnu` target |
| ONNX Runtime | **1.24.2+spacemit.a1 + EP 主库** |
| 仓库位置 | `/opt/microduck-k3/microduck`(分支 `k3-sim-port`) |

> 环境探查命令与结果:`K3\docs\03-K3环境实测.md`

---

## 3. 构建(裁剪版)

```bash
cd /opt/microduck-k3/microduck
cargo build --release --exclude mediad --exclude duck-detect --exclude pet-detect
```

- **实测 6m42s 全绿**,产出 `robotd`(7.3 MB)等 7 个 RISC-V 二进制
- 踩过的两个坑:
  1. `padd`(手柄服务)→ gilrs → `libudev-sys` 构建失败 → `apt install libudev-dev`
  2. `duck-control` 在 v0.11.0 未声明 `serde_json`(移植的 sim 模块需要)

---

## 4. 关键缺口:`--sim` 在 v0.11.0 不存在

- 主仓 v0.11.0 **没有** daemon 侧的 TCP 仿真客户端(`--sim`),`duck-body` 文档写的用法属于上游
  分支 **`sim-remote-io`**——但该分支比 main **旧 2.4 万行**(缺 policy channel 等)。
- **解法**:把 `duck_control::sim::RemoteIo`(约 432 行独立模块)移植到 v0.11.0,
  保留 main 的 policy channel。改动面 = `lib.rs` + `sim.rs` + `main.rs` 共 4 个文件,
  本地分支 **`k3-sim-port`**;`cargo check` + release 构建均通过。
- 详见 `K3\docs\05-仿真客户端移植.md`。

---

## 5. 联调拓扑与结果

```
┌─ K3 (riscv64) ────────────────┐        ┌─ Windows (x86_64) ─────────┐
│ robotd 50Hz 环 + 官方 ONNX 策略│        │ duck-body (MuJoCo) + viewer│
│ spacemit ONNX Runtime          │◄──SSH 反向隧道──►│ 200Hz 物理/50Hz 控制│
└────────────────────────────────┘        └────────────────────────────┘
     robotd --sim 127.0.0.1:7801  ←──  ssh -R 7801:127.0.0.1:7801
```

| 阶段 | 结果 |
|---|---|
| 策略加载 | 官方 9 个 ONNX(alpha_walking/stand/sitstand/ground_pick/roulade 等)全部加载 |
| 坐姿检测 | `seated boot detected deviation=0.33` |
| 起身(sitstand) | z 0.065 → 0.116 |
| 站立 | **7 s 稳定**,gz = −1.000 |
| 行走(vx=0.25 命令) | 15 s 走 **1.45 m**(实测 0.097 m/s),未摔倒 |
| 环率 | **46–48 of 50 Hz**(隧道下,健康门限 45) |
| Web 控制台 | K3 上 `:8081` 单页控制台,摇杆/坐站/技能全部走通 |
| 速度跟踪 | ⚠️ 命令 0.25 m/s,实测 **0.097 m/s(39%)** —— sim-to-sim gap,见 §6.6 |

> **推理开销实测**(2026-09-09,`--fake` 无仿真):单次 ONNX 推理 **0.201 ms**(占 50 Hz 预算 1.01%),
> 整环 CPU **约 1.2% 单核**,0 missed ticks。详见 [`POLICY-RUNTIME.md`](POLICY-RUNTIME.md)。

---

## 6. 踩坑清单(移植到别的 RISC-V 板时同样适用)

1. **`robot.init` 不使能策略** —— `driving = intents.enabled() && bringup==Ready && ...`,
   `enabled` 默认 false。必须 **先 `robot.enable` 再 `robot.init`**。
2. **起身窗口只有 1 秒**(manifest `sitstand.unwind_s = 1.0`)—— init 后 1 s 内才走 sitstand;
   超窗口退化为 `Sit::Up` → 站立网络。
3. **`robot.init` 单独用会把坐着的鸭子拖倒** —— 没有策略平衡时线性 ramp 必倒。
4. **必须从 SIT 起始**,不能 `--keyframe HOME` —— HOME 起步策略接管后前倾摔倒(实测 x 冲 13 cm)。
5. **仿真重启后 daemon 自动重连但不会重发力矩** —— 新仿真 `released=False`,鸭子被 `restore()` 冻结;
   需要 `relax` + `init` 重新握手(注意 `relax` 会让鸭子塌下去)。
6. **速度跟踪只有 ~39%**(0.097 vs 0.25 m/s)—— `duck-body` 的 `scene.xml` 是简单位置执行器,
   策略是在 **BAM 摩擦/电压模型**下训练的(sim-to-sim gap);站立/平衡不受影响。
   要速度保真请用 `microduck_rl/scripts/infer_policy.py`(BAM M6)。
7. **SSH 反向隧道是免防火墙的关键** —— Windows 入站 7801 被拦且加规则需管理员;
   `ssh -R 7801:127.0.0.1:7801` 把本机端口映射到 K3 的 localhost,robotd 用默认地址即可。
   隧道下 RTT p50 3 ms / max 10 ms。
8. **`pkill -f <模式>` 会匹配到执行它的远程 shell 自身** —— 用正则括号规避(`[s]erver\.py`)。
9. **`robot.state` 是订阅通知,不是可调方法** —— 直接调用返回 `unknown method`;
   必须 `robot.subscribe {hz:10}` 后另开连接收通知。
10. **viewer 会拖慢实时步进**(曾落后 7.6 s)—— 做性能/时序测量用 `--headless`。

---

## 7. 复现命令

```bash
# Windows:启动本地仿真(SIT 起始,设计路径)
cd microduck_rl
PYTHONPATH=src "<案例目录>/K3/local-sim/.venv/Scripts/python.exe" \
    -m mjlab_microduck.sim.body_server --port 7801

# Windows:反向隧道
cd yolos-box
K3_SSH_HOST="root@10.5.90.195 -p 22" ./tools/k3ssh.sh root@10.5.90.195 \
    -N -R 7801:127.0.0.1:7801 -o ServerAliveInterval=30 -o ExitOnForwardFailure=yes

# K3
cd /opt/microduck-k3/microduck
setsid nohup ./target/release/robotd --sim 127.0.0.1:7801 </dev/null >/tmp/robotd-sim.log 2>&1 &
python3 /tmp/sim-drive.py --enable --init --vx 0 --seconds 8    # 起身 + 站立
python3 /tmp/sim-drive.py --vx 0.25 --seconds 16               # 行走
./target/release/robotctl health
```

---

## 8. 相关文件

| 内容 | 位置 |
|---|---|
| 工程总目录 | `Desktop\Work_World\Microduck 机器鸭 × 进迭时空 优秀案例\` |
| K3 版方案与实录 | 上述目录 `K3\`(docs/01–06、plans/MILESTONES.md、k3/ 脚本) |
| 策略运行时实测 | [`POLICY-RUNTIME.md`](POLICY-RUNTIME.md)(推理耗时 / CPU 占用 / 选网逻辑) |
| K1 版(实测进展) | [`K1-PORT.md`](K1-PORT.md) + 上述目录 `K1\` |
| 芯片官方资料 | yolos-box 知识库 **21**(K1/K3 规格与产品线) |
| 本知识库(4 仓) | [`README.md`](../README.md) · [`RELATIONS.md`](../RELATIONS.md) |

---

## 9. K1 —— 已平移跑通(2026-09-09)

K1(8×X60 @1.8GHz、2 TOPS CPU 融合、MUSE-Pi-Pro 板卡形态)**代码零改动**平移完成:

| 指标 | K1 | K3 |
|---|---|---|
| 裁剪构建 | 43m39s | **6m42s** |
| 空载环率 | **50.0 of 50 Hz · 0 missed** | 49.0 Hz · 0 missed |
| 行走 | **1.245 m** | 1.145 m |
| CPU 温度 | **50 °C** | 64 °C |
| ⚠️ 满载最低 | **40.7 Hz**(<45 门限) | 未低于 45 |

途中解掉的一个真问题:K1 的 apt 只提供 `libonnxruntime.so.1.18.1`(低于地板 1.23),
但 **`python3-spacemit-ort` 包里自带 1.24.0** —— 用 `ORT_DYLIB_PATH` 指过去即可,无需跨机搬运。
详见 [`K1-PORT.md`](K1-PORT.md)。
