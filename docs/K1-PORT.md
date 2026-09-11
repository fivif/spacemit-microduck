# K1 换脑实录 —— MUSE-Pi-Pro 上的移植

> **一句话**:把 K3 已跑通的换脑方案平移到 **SpacemiT K1(MUSE-Pi-Pro)**,并已跑通。
> **控制环零改动**,唯一的技术障碍是 ONNX Runtime 版本,解法在板子自带的包里;
> 感知侧是**加法** —— `duck-detect` 新增一个 SpaceMIT EP 后端(见 §7)。
> **实测日期 2026-09-08 / 09 / 10**。

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
| 内存 | 8 GiB | **3.8 GiB** | 全量构建也够用 |
| 实时核 RCPU | 600 MHz(直挂 CAN-FD/TSN) | 无 | 真机总线抖动需实测 |
| ONNX Runtime | 预装 **1.24.2+spacemit.a1** | apt 只有 1.18.1;`python3-spacemit-ort` 自带 **1.24.0** | 见第 4 节 |

**为什么控制环"零改动"成立**:策略是 512-256-128 的 MLP(61 维入 / 14 维出 / 50 Hz),
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

`robotd` 只用 CPU EP,不加载 `libspacemit_ep.so` —— 策略 MLP 太小,EP 没有收益。

验证工具:`k1/probe-onnx.sh`(dlopen + `OrtGetApiBase()->GetApi(23)` + 一帧 61 -> 14 推理)。

---

## 5. 构建

```bash
cd /opt/microduck-k1/microduck
cargo build --release --workspace
```

| 项 | 值 |
|---|---|
| 耗时 | **43m39s** |
| crate | 313 |
| `robotd` | 7 319 888 B |
| 对比 | K3 为 6m42s |

> 上表那次构建带着 `--exclude duck-detect` 与 `--exclude mediad`，两个排除**现在都已撤销**。
> `duck-detect` 于 2026-09-10 去掉：它靠 `dlopen` 找运行时，编译期不需要任何厂商库，运行期在
> K1 上走 `src/spacemit.rs` 挂 SpaceMIT EP、没有就退回 CPU。增量重建
> `cargo build --release -p duck-detect` 实测 **35.82s**，无警告通过。去掉它的另一个理由更直接：
> `duck-bench` 是板上唯一能验证 EP 这条路的工具 —— 裁掉 crate 等于把唯一的验证手段裁掉。
>
> `mediad` 于 2026-09-11 撤销：**完整实测见 [`K1-MEDIA.md`](K1-MEDIA.md)**。它一直编不过的原因
> **不是** riscv64 缺 GStreamer/厂商硬件编码，而是板上没装 GStreamer 的 `-dev` 包
> （`libgstreamer1.0-dev` / `libgstreamer-plugins-base1.0-dev` / `libgstreamer-plugins-bad1.0-dev`，
> `env-init.sh` 已装）。装齐后全量构建通过，`target/release/mediad` 可运行，USB 摄像头链路
> MJPEG → UYVY → `spacemith264enc`（硬件 H.264）→ WebRTC 出实帧 —— 消费端实测
> **29.97 of 30 fps、0 丢帧**。**K1 现在不裁任何 crate。**

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
| 联调环率 | `--sim` | 46.5-48.5 of 50 Hz(仿真在另一台机器,走 SSH 隧道) |
| 满载最低 | 行走 + 转向 + 观测同时 | 40.7 Hz,**隧道上限,不是板子上限** |
| 板载环率 | `--sim 127.0.0.1` + 板内 `stub-body.py` | **50.0 of 50 Hz,0 missed**;robotd 1.9% 单核 |
| CPU 温度 | — | **50 C** |
| 检测器 / EP | `duck-bench --backend spacemit` | p50 **142.0 ms**;每帧 CPU 279.7 ms(2 Hz 下 56% 单核) |
| 检测器 / CPU 对照 | `duck-bench --backend cpu` | p50 **718.5 ms** —— EP **快 5.1 倍** |

### 与 K3 对比

| 指标 | K1 | K3 |
|---|---|---|
| 构建 | 43m39s | **6m42s** |
| 空载环率 | **50.0 of 50 Hz,0 missed** | 49.0 Hz,0 missed |
| 行走 | **1.245 m** | 1.145 m |
| CPU 温度 | **50 C** | 64 C |
| 满载最低环率 | 40.7 Hz | 未低于 45 |

K1 能跑通完整链路。上表最后一行**两边都是带隧道测的**,所以它只是个相对读数 ——
摘掉隧道、把被控对象挪进板子之后,同一个控制环是 **50.0 of 50 Hz、0 丢帧、1.9% 单核**,
**不能**据此说 K1 跑不动 50 Hz。真机集成要量的是舵机总线那一段(1 Mbaud),那是另一笔账。

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
7. **跑 NPU 需要 `RTLD_GLOBAL`** —— EP 的 `onnxruntime::…` 符号不在它的 `DT_NEEDED` 里,
   必须自己按同一条路径把 `libonnxruntime.so` 全局提起来。
8. **opset-12 的检测模型会让 EP 挂死而不是报错** —— 打一行 `operator compile failed` 之后
   单核 100% 空转不再返回,`timeout 45` 才收得回来。换 opset 13+ 即可。
9. **量延迟之前先确认板上没别的活** —— 有别的编译在跑时 EP 的 p50 从 142.0 抬到 182.0、
   p99 从 146.7 抬到 441.1。先看 `ps` 和 `/proc/loadavg`。

---

## 7. 感知:`duck-detect` 接入 SpaceMIT EP(2026-09-10)

控制环之外唯一动过的地方,而它是**加法不是重写**:新增
[`duck-detect/src/spacemit.rs`](../microduck/duck-detect/src/spacemit.rs)(256 行),
把厂商私有的 C 入口 `OrtSessionOptionsSpaceMITEnvInit` 挂到 **`onnx.rs` 已经在建的那个 ort 会话**上。
输入张量、归一化、letterbox、decode、`mediad` 的取帧全部未动 —— 变的只是 ORT 把节点交给谁。

| | 入口 | 模型 | 代码 |
|---|---|---|---|
| Rockchip | `librknnrt.so` 的 `rknn_*` | INT8 `.rknn` | `rknn.rs`,未动 |
| **K1(本板)** | `OrtSessionOptionsSpaceMITEnvInit` | `.onnx`(opset 17) | `spacemit.rs`,**新增** |
| 两者都没有 | — | `.onnx` | `onnx.rs`,未动(CPU) |

三个方面必须知道:

- **`RTLD_GLOBAL` 不是可选项** —— 见踩坑 7;另外 `/usr/lib/libspacemit_ep.so` 是给 1.18 Runtime
  的 version 1 EP,搜索顺序必须从 Runtime 旁边开始,否则在两者都有的板子上会找错。
- **模型必须是 opset 13+** —— 见踩坑 8;现在的 `duck_detect.onnx` 是 opset-17 转换结果,
  对这个图**逐位相同**(12 帧 × 10 500 输出,最大绝对差 0.000e+00)。
- **CPU 回落必须保持开启** —— `session.disable_cpu_ep_fallback` 没有设也不能设:
  这个图有 EP 不认领的节点,打开它就从"慢路径"变成"模型加载不了"。

实测(1.6 GHz / `performance`,板上无其他负载,`--hz 2`):

| | EP | CPU(2 线程) | 比值 |
|---|---|---|---|
| 延迟 p50 | **142.0 ms** | 718.5 ms | **5.1x** |
| p95 / p99 | 144.5 / 146.7 ms | 719.5 / 719.8 ms | |
| 每帧 CPU | **279.7 ms** | 1439.7 ms | **5.1x** |
| 2 Hz 摊到单核 | **56%** | 288% | |

**两句话必须一起说**:EP 快 5 倍是真的;但 2 Hz 下它仍占 **56% 的单核** ——
EP 只接管它认领的子图,其余节点回落 CPU,张量搬运也在主机上。所以不能照抄
"NPU 路径约占单核十分之一"那句话,那是另一块板子的账。
检测结果两边一致:阈值 0.05 时 12 帧里 4 帧出框,框坐标逐个相同(frame_09 概率 0.13 vs 0.14)。
(这批是合成帧,只做等价性检查,不是精度评测。)

判读:`duck-bench` 横幅里的 `runtime …` 就是"到底谁在干活"的唯一凭据 ——
显示 `onnxruntime · cpu` 说明 EP 没挂上,此时检测仍在跑,只是慢 5 倍、吃 2.9 个核。

---

## 8. 相关文件

| 内容 | 位置 |
|---|---|
| K1 方案 / 环境 / 构建 / R1 / 联调 | `K1/docs/01-05` |
| 检测器 EP 后端的完整实录(挂死复现、逐帧对照) | [`K1/docs/05-联调实录.md`](../k1/docs/05-联调实录.md) |
| K1 侧脚本 | `K1/k1/`(`run-all` / `env-init` / `build` / `patch-webrtcsink` / `probe-onnx` / `install-ort` / `sim-drive` / `stub-body.py` / `k3-sim-port.patch`) |
| K1 里程碑 + K3/K1 对照 | `K1/plans/MILESTONES.md` |
| **K1 摄像头链路：`mediad` 的 GStreamer 依赖、UVC 取帧、厂商硬编、WebRTC 出流** | [`K1-MEDIA.md`](K1-MEDIA.md) |
| K3 侧对照 | [`K3-PORT.md`](K3-PORT.md) |