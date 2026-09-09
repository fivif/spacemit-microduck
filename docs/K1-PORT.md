# K1 换脑实录 —— MUSE-Pi-Pro 上的移植

> **一句话**:把 K3 已跑通的换脑方案平移到 **SpacemiT K1(MUSE-Pi-Pro)**,并已跑通。
> **代码零改动**,唯一的技术障碍是 ONNX Runtime 版本,解法在板子自带的包里。
> **实测日期 2026-09-08 / 09**。

---

## 1. 板卡身份(实测确认)

| 项 | 值 |
|---|---|
| device-tree model | `spacemit k1-x MUSE-Pi-Pro board` |
| compatible | `spacemit,k1-x` |
| CPU | 8x Spacemit(R) **X60**,`uarch: spacemit,x60`,含 **`_ime`**(AI 融合指令扩展) |
| OS | **Bianbu 2.3.3**(`noble`),内核 **6.6.63**,glibc **2.39** |
| 内存 | **3.8 GiB**(4 GB 档,可用 3.4 GiB) |
| 磁盘 | 47 G 可用 |
| Python | 3.12.3 |

---

## 2. 与 K3 的差异对照

| 维度 | K3(实测) | K1(实测) | 影响 |
|---|---|---|---|
| 板卡 | K3 Pico-ITX | **MUSE-Pi-Pro** | K1 形态更适合真机集成 |
| CPU | 8x X100 @2.4 GHz | 8x **X60** @1.8 GHz | 单核 SPECint2006 **9.5 vs 3.5**(约 2.7 倍) |
| AI | 60 TOPS(8x A100 + spacemit EP) | **2 TOPS**(CPU `_ime` 融合) | 策略 MLP 不吃亏,两边都走 CPU |
| 内存 | 8 GiB | **3.8 GiB** | 裁剪构建够用 |
| 实时核 RCPU | 600 MHz(直挂 CAN-FD/TSN) | 无 | 真机总线抖动需实测 |
| ONNX Runtime | 预装 **1.24.2+spacemit.a1** | apt 只有 1.18.1;`python3-spacemit-ort` 自带 **1.24.0** | 见第 4 节 |

**为什么"代码零改动"成立**:策略是 512-256-128 的 MLP(61 维入 / 14 维出 / 50 Hz),
计算量极小;K1 与 K3 的差异全在**运行性能**,不在**编译路径** —— 同一个 `riscv64gc` target。

---

## 3. 环境安装

| 项 | 初始 | 处置 |
|---|---|---|
| gcc / g++ / make / git / curl | 13.2.0 / 4.3 / 2.43 / 8.5 | 已有 |
| cmake | 缺 | apt `3.28.3` |
| libudev-dev / pkg-config | 缺 | apt(`padd -> gilrs -> libudev-sys` 需要) |
| rustc / cargo | 缺 | rustup **1.98.1**(2026-09-01) |
| onnxruntime | 缺 | apt `onnxruntime 1.2.2` |

---

## 4. ONNX Runtime 版本冲突与解决

主仓 `ort` 绑定的地板是 **1.23**(`Cargo.toml` 的 `[workspace.metadata.onnxruntime] floor`),
低于此版本 `ort` 会在 `setup_api` 中 panic。K1 的情况:

| 环节 | 值 |
|---|---|
| apt 包 | `onnxruntime 1.2.2`(包版本号与 ORT 版本号不同) |
| 实际提供 | `libonnxruntime.so.1.18.1` |
| 结论 | **1.18.1 < 1.23**,不满足 |

**解决**:K1 已装的 `python3-spacemit-ort` 包内自带一个更新的 ORT:

```
/usr/lib/python3.12/dist-packages/onnxruntime/capi/
└── libonnxruntime.so.1.24.0+spacemit.a3     26.7 MB
```

| 检查项 | 结果 |
|---|---|
| 版本 | **1.24.0+spacemit.a3**,高于地板 1.23 |
| API v23(`probe-onnx.sh` dlopen + `GetApi(23)`) | 可用 |
| `GLIBC_2.38` / `GLIBCXX_3.4.30` / `CXXABI_1.3.15` | K1 有 2.39 / 3.4.33 / 1.3.15 |

已安装到 `/opt/microduck-k1/ort/`,用 `ORT_DYLIB_PATH` 指向,**不覆盖 `/usr/lib`**
(板上其它依赖 1.18.1 的程序不受影响)。

`robotd` 只用 CPU EP,不需要 `libspacemit_ep.so`(那是 AI 核专用,K1 本就没有)。

验证工具:`k1/probe-onnx.sh`(dlopen + `OrtGetApiBase()->GetApi(23)` + 一帧 61 -> 14 推理)。

---

## 5. 构建

```bash
cd /opt/microduck-k1/microduck
cargo build --release --workspace \
    --exclude mediad --exclude duck-detect --exclude pet-detect
```

| 项 | 值 |
|---|---|
| 耗时 | **43m39s** |
| crate | 313 |
| `robotd` | 7 319 888 B |
| 对比 | K3 为 6m42s |

**构建慢的原因是内存,不是 CPU**:K1 只有 3.8 GiB 且**无 swap**,六个 rustc 并行
(合计约 1.9 GB)时内核反复回收页缓存,load average 达 10.36。
需要更稳的墙钟时间可用 `cargo build -j4` 降低并行度。

---

## 6. 联调结果

| 阶段 | 操作 | 结果 |
|---|---|---|
| 坐姿检测 | `robotd --sim` 接仿真 | `deviation=0.33` |
| 起身 | `robot.init` | z 0.070 -> **0.116** |
| 站立 | 保持 twist=0 | 稳定,gz = -1.000 |
| 行走 | `vx=0.25` 14 s | x **1.181 -> 2.426 = 1.245 m**,未摔 |
| 转向 | `vyaw=0.5` 8 s | 转向成功,未摔 |
| 空载环率 | `--fake` | **50.0 of 50 Hz,0 missed** |
| 联调环率 | `--sim` | 46.5-48.5 of 50 Hz |
| 满载最低 | 行走 + 转向 + 观测同时 | **40.7 Hz**,低于 45 Hz 健康门限 |
| CPU 温度 | — | **50 C** |

### 与 K3 对比

| 指标 | K1 | K3 |
|---|---|---|
| 裁剪构建 | 43m39s | **6m42s** |
| 空载环率 | **50.0 of 50 Hz,0 missed** | 49.0 Hz,0 missed |
| 行走 | **1.245 m** | 1.145 m |
| CPU 温度 | **50 C** | 64 C |
| 满载最低环率 | **40.7 Hz** | 未低于 45 |

K1 能跑通完整链路,但**满载时余量不足**(掉到健康门限以下)—— 这是 K1 相比 K3 的
第一个实测性能差距,也是真机集成要正视的点(真机还有舵机总线负载)。

### 踩坑

1. **`sit_toggle` 是切换,不是"起身"** —— 连按两次就坐回去了。
2. **已折叠的机器人不要用 `robot.init`** —— 它会用线性 ramp 重新归位,把折叠的机器人拖倒;
   正确做法是 `sit_toggle`。
3. **同一端口只能跑一个仿真实例** —— 多个 `body_server` 抢同一端口时,
   只有第一个绑定成功,后启动的"重启"看着成功其实没生效。
4. **驱动指令是 last-writer-wins** —— 浏览器摇杆与脚本会互相覆盖,调试时先关页面。
5. **`robotctl` 自建 socket 要用 `--robot-socket`**,不是 `--socket`(后者给 updaterd)。
6. **仿真执行器是简化的** —— `duck-body` 用位置执行器,策略是在 BAM 摩擦模型下训练的,
   速度跟踪只有 37-39%,指令过猛容易摔倒。

---

## 7. 相关文件

| 内容 | 位置 |
|---|---|
| K1 方案 / 环境 / 构建 / R1 / 联调 | 案例目录 `K1/docs/01-05` |
| K1 侧脚本 | 案例目录 `K1/k1/`(`run-all` / `env-init` / `build` / `probe-onnx` / `install-ort` / `sim-drive` / `k3-sim-port.patch`) |
| K1 里程碑 + K3/K1 对照 | 案例目录 `K1/plans/MILESTONES.md` |
| K3 侧对照 | [`K3-PORT.md`](K3-PORT.md) |
