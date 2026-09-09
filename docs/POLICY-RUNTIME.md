# 运行时推理 —— 策略在板子上怎么跑

> **实测日期 2026-09-09**,板卡 SpacemiT K3 Pico-ITX(Bianbu 4.0.1,riscv64)。
> 本文件回答"模型怎么被运行"——不是"怎么训练"也不是"怎么导出",而是
> **`robotd` 每 20 ms 那一次推理到底做了什么、花多少时间**。
> 上游代码:`microduck/duck-control/src/policy.rs`、`microduck/robotd/src/control.rs`。

---

## 1. 一次 tick 的推理路径

```
control 线程(50 Hz)
  └─ Safety<RemoteIo/DynamixelIo>.read()        取传感器
  └─ Observation::build(...)                    拼 61 维观测
  └─ Policy::infer(&obs, net)                    一次 ONNX 推理
  │    └─ ort::Session::run(inputs!["obs" => [1,61]]) → [1,14]
  └─ 动作 → 关节目标 → Safety.write()            下发
```

**关键数字**：

| 项 | 值 | 出处 |
|---|---|---|
| 输入 | `[1, 61]` f32 | `policy.rs:421` |
| 输出 | `[1, 14]` f32 | `policy.rs:436` |
| 图优化 | `GraphOptimizationLevel::Level3` | `policy.rs:369` |
| 推理线程 | **`intra_threads = 1`** | `policy.rs:33, 370` |
| 模型大小 | 每个 **793 KB**(9 个策略几乎等大) | 实测 `/opt/robot/policies/current/` |
| 网络结构 | 512-256-128 MLP,ELU,≈30 万参数 | `microduck_velocity_env_cfg.py` |

**为什么是单线程**（`policy.rs:29-33` 注释原文大意）：
原型用了 2 线程，在原平台的四核 CPU 上控制线程会阻塞在一个不属于它的线程池上；
这么小的网络，线程池的同步开销比并行收益更大。**留待上板重测**——本文就是那个重测。

---

## 2. 单次推理耗时(K3 实测)

方法：`onnxruntime 1.24.2+spacemit.a1` + `CPUExecutionProvider`，
复刻 `policy.rs` 的会话配置（Level3 + intra=1），`[1,61]` 零输入，
200 次预热后计 2000 次。

| 策略 | mean | p50 | p95 | p99 | max | 占 20 ms 预算 |
|---|---|---|---|---|---|---|
| alpha_walking | **0.201 ms** | 0.200 | 0.208 | 0.223 | 0.265 | **1.01%** |
| alpha_stand | 0.201 ms | 0.200 | 0.209 | 0.217 | 0.256 | 1.01% |
| alpha_sitstand | 0.201 ms | 0.200 | 0.209 | 0.219 | 0.255 | 1.01% |
| alpha_ground_pick | 0.201 ms | 0.200 | 0.208 | 0.216 | 0.422 | 1.01% |
| ball_kick_left | 0.202 ms | 0.201 | 0.209 | 0.217 | 0.417 | 1.01% |
| ball_kick_right | 0.201 ms | 0.200 | 0.209 | 0.223 | 0.260 | 1.01% |
| roller | 0.202 ms | 0.201 | 0.209 | 0.217 | 0.244 | 1.01% |
| roller_crouch | 0.203 ms | 0.202 | 0.210 | 0.219 | 0.251 | 1.01% |
| roulade | 0.201 ms | 0.200 | 0.208 | 0.217 | 0.243 | 1.00% |

**结论**：
- **9 个网络耗时几乎一致**（0.201–0.203 ms）—— 它们同架构、同参数规模，差异在噪声内。
- **单次推理占 50 Hz 预算的 1%**，p99 也只有 1.1%。**余量约 99 倍。**
- `max` 偶发到 0.42 ms（约 2 倍），仍远在预算内。

> 脚本:`bench_policy.py`(`--iters` 可调;`--providers` 只打印运行时信息)。
> 注意这是**纯推理**耗时,不含观测拼装、安全层、总线读写。

---

## 3. 整环 CPU 占用(K3 实测)

方法：读 `/proc/<pid>/task/<control_tid>/stat` 的 `utime+stime` 差值，除以
`CLK_TCK=100` 与墙钟时间。控制线程 tid 通过 `/proc/<pid>/task/*/comm` 找 `control`。

| 场景 | 窗口 | CPU ticks | 占用(单核) | 同期环率 |
|---|---|---|---|---|
| `--fake` 空闲(无策略驱动) | 60.0 s | 7 | **0.12%** | 49.0 of 50 Hz |
| `--fake` + 驱动(stand 网) | 60.0 s | 73 | **1.22%** | 49.0 of 50 Hz |
| `--fake` + 驱动(walk 网) | 55.0 s | 66 | **1.20%** | 49.0 of 50 Hz |

**结论**：
- 整环 CPU 占用 **约 1.2% 单核** —— 8 核的 K3 上约 **0.15% 总算力**。
- 推理只占其中一部分（50 Hz × 0.2 ms = **1%**），其余是观测拼装、安全层、IPC。
- **0 missed ticks**，全程 48–49 of 50 Hz。

> 注意: 测量环境不是空载：K3 上 `系统服务` 等占 ~30%，
> `load average ≈ 2.2`。因此这是**偏保守**的数字。

---

## 4. 六个网络,怎么选

`Policy` 加载 6 类会话，由 `Net` 枚举选择（`robotd/src/control.rs:497-530`）：

| Net | 触发条件 | 备注 |
|---|---|---|
| `Stand` | 命令速度模长 **< 0.05**（`DEFAULT_STANDING_THRESHOLD`），或 body 激活 | 站立/平衡 |
| `Walk` | 其余情况 | 强制加载 |
| `SitStand` | twist vx 槽带 posture flag（**1=坐, 0=站**） | `unwind_s=1.0` 起身窗口 |
| `GroundPick` | 相位脚本，twist 槽带 `[cos φ, sin φ, 0]` | `period_s=4.0` |
| `Skill(index)` | 显式请求的一次性技能 | 踢球、翻滚等 |
| (roller) | `mode: "roller"`，预留 stand 网 | `action_scale=0.8` |

**热插拔成立的前提**：所有网络共享同一 61 维观测布局，切换 = 换 session + 换命令块编码，
**不是换契约**（`policy.rs` 文件头）。

---

## 5. 加载即校验,不是推理时才报错

`policy.rs` 文件头的设计原则（原文大意）：

> **一切都在加载时校验，不在推理时。** 观测宽度错、动作数错、ONNX Runtime 缺失，
> 必须在机器人还站着、调用方还能被告知原因的时候失败 —— 而不是六十个 tick 之后，
> 走到一半的时候。

`robotd` 把加载失败转成「**保持姿势 + 报不健康**」，让 updater 回滚发布，
而不是留下一个走不了路的机器人。

配套的兜底：

| 机制 | 作用 |
|---|---|
| `ensure_runtime()` | 先用 `libloading` 探 `libonnxruntime.so`，把"库缺失"变成普通错误 |
| `catching_ort_panics()` | 把 `ort` 的 panic 转成 `PolicyError::RuntimePanic` |
| `check_width()` | 校验输入/输出维度 |

> **`ensure_runtime` 不能防 panic** —— 注释里记着那次翻车：某板子 ORT **1.20.1**，
> 库能加载(探针通过)，但 `ort` 在 `setup_api` 里版本检查时 panic
> （`expected version >= '1.23.x', but got '1.20.1'`）。
> 这正是 **K1 的 R1 风险**（[`K1-PORT.md`](K1-PORT.md) §5）：K1 只有 1.18.1。

---

## 6. 与训练侧的关系

| | 训练(microduck_rl) | 运行(robotd) |
|---|---|---|
| 执行器 | `bam.mjlab.BamActuator`（MuJoCo Warp） | 真机固件 PD，`kp_fw=200` |
| 观测归一化 | `EmpiricalNormalization` | **已烘焙进 ONNX** |
| 动作 | 14 维 | 14 维，`motor_target = DEFAULT_POSE + action × scale` |
| 频率 | 50 Hz | 50 Hz |

**归一化必须烘焙进 ONNX**（`scripts/export.py` 做）—— 手转 checkpoint 会隐藏 bug。
这是 sim2real 闭环里最容易出错的一环。

---

## 7. 复现

```bash
# K3 上
python3 bench_policy.py --iters 2000            # 单次推理耗时
python3 bench_policy.py --providers             # 只看运行时版本/EP

# 整环 CPU(需 daemon 在跑)
cd /opt/microduck-k3/microduck
setsid nohup ./target/release/robotd --fake --socket /run/robotd-bench.sock \
    </dev/null >/tmp/robotd-fake.log 2>&1 &
T=$(grep -l ^control /proc/$(pgrep -f "robotd --fake")/task/*/comm | cut -d/ -f5)
# 采样:读 /proc/<pid>/task/$T/stat 的 $14/$15,除以 CLK_TCK=100 与墙钟
./target/release/robotctl --robot-socket /run/robotd-bench.sock monitor   # 看 net 选择
```

**踩坑**：`robotctl health` 默认读 `/run/robotd.sock`，自建 socket 要用
`--robot-socket`（不是 `--socket`，后者是 updaterd 的）。

---

## 8. 相关

| 内容 | 位置 |
|---|---|
| K3 换脑移植(构建/联调/踩坑) | [`K3-PORT.md`](K3-PORT.md) |
| K1 换脑进展(ORT 1.18.1 冲突) | [`K1-PORT.md`](K1-PORT.md) |
| 观测/动作契约术语 | [`TERMS.md`](TERMS.md) §三 |
| 代码 | `microduck/duck-control/src/policy.rs` · `microduck/robotd/src/control.rs` |
| 实测脚本 | 案例目录 `K3/k3/bench_policy.py` |
