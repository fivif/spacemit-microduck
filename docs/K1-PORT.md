# K1 换脑实录 —— MUSE-Pi-Pro 上的移植进展

> **一句话**:把 K3 已跑通的换脑方案平移到 **SpacemiT K1(MUSE-Pi-Pro)**,并**已跑通**。
> **代码零改动**,但实测发现 **ONNX Runtime 版本低于主仓地板**(K3 没有的问题)。
> **实测日期 2026-09-08**;工程记录见
> `Desktop\Work_World\Microduck 机器鸭 × 进迭时空 优秀案例\K1\`。

---

## 1. 板卡身份(实测确认)

| 项 | 值 |
|---|---|
| device-tree model | **`spacemit k1-x MUSE-Pi-Pro board`** |
| compatible | `spacemit,k1-x` |
| CPU | 8× Spacemit(R) **X60**,`uarch: spacemit,x60`,含 **`_ime`**(AI 融合指令扩展) |
| OS | **Bianbu 2.3.3**(`noble`)· 内核 **6.6.63** · glibc **2.39** |
| 内存 | **3.8 GiB**(4 GB 档,可用 3.4 GiB) |
| 磁盘 | 47 G 可用 |
| Python | 3.12.3 |

> 与 K3 对照:K3 是 `jax-spacemitk3picoitx`(8×X100 / Bianbu 4.0.1 / glibc 2.43 / 8 GiB)。

---

## 2. 与 K3 的差异对照

| 维度 | K3(实测) | K1(实测) | 影响 |
|---|---|---|---|
| 板卡 | K3 Pico-ITX | **MUSE-Pi-Pro** | K1 形态更适合真机集成 |
| CPU | 8× X100 @2.4 GHz | 8× **X60** @1.8 GHz | 单核 SPECint2006 **9.5 vs 3.5**(≈2.7×) |
| AI | 60 TOPS(8×A100 + spacemit EP) | **2 TOPS**(CPU `_ime` 融合) | 策略 MLP 不吃亏,两边都走 CPU |
| 内存 | 8 GiB | **3.8 GiB** | 裁剪构建够用 |
| 实时核 RCPU | ✅ 600 MHz(直挂 CAN-FD/TSN) | ❌ 无 | P2 真机总线抖动需实测 |
| **ONNX Runtime** | ✅ 预装 **1.24.2+spacemit.a1** | ⚠️ apt 只有 **1.18.1**,但 **python3-spacemit-ort 自带 1.24.0** ✅ | R1 已解 |

**为什么"代码零改动"成立**:策略是 512-256-128 的 MLP(61 维入 / 14 维出 / 50 Hz),
计算量极小;K1 与 K3 的差异全在**运行性能**,不在**编译路径** —— 同一个 `riscv64gc` target。

---

## 3. 环境安装(已完成)

| 项 | 初始 | 处置 |
|---|---|---|
| gcc / g++ / make / git / curl | ✅ 13.2.0 / 4.3 / 2.43 / 8.5 | — |
| cmake | ❌ | ✅ apt `3.28.3` |
| libudev-dev / pkg-config | ❌ | ✅ apt(`padd → gilrs → libudev-sys` 需要) |
| rustc / cargo | ❌ | ✅ rustup **1.98.1**(2026-09-01) |
| onnxruntime | ❌ **完全未装** | ✅ apt `onnxruntime 1.2.2` |

---

## 4. 源码转储:K1 上 github 不可达

| 通道 | 结果 |
|---|---|
| `github.com` | ❌ **000**(超时) → **`git clone` 必失败** |
| `codeload.github.com` | ✅ 200(能下 tarball,但只含 main,拿不到 `k3-sim-port`) |
| `static.rust-lang.org` / `index.crates.io` / `static.crates.io` | ✅ 200(rustup 与 cargo 依赖可下) |

**采用路径**:本机 `tar` 打包(含 `.git`,35 MB)→ `scp` → `/opt/microduck-k1/` → 解包。

解包后核对:分支 `k3-sim-port`、`duck-control/src/sim.rs` 17 026 B 在位、
`Cargo.lock` **519 registry / 0 git 源**(可离线 vendor)。

> ⚠️ 解包后 `git` 报"可疑的仓库所有权",需 `git config --global --add safe.directory <path>`。

---

## 5. R1 风险:ORT 版本低于地板(实测确认)

立项时(`K3/docs/04-K1版前瞻.md`)预判"K1 大概率只有 CPU 版 ORT,走 CPU 即可";
**实测证明这条预判不完整** —— 不是"有没有 EP"的问题,是**版本本身低于地板**:

| 环节 | 证据 |
|---|---|
| 主仓地板 | `Cargo.toml`: `floor = "1.23"`,注释明说 `ort` 在 1.23 以下会 panic |
| `ort` 绑定 | `duck-control/Cargo.toml`: `ort = "=2.0.0-rc.11"`,`load-dynamic`(dlopen,不编 C++) |
| K1 apt 包 | `onnxruntime **1.2.2**`(包版本号 ≠ ORT 版本号) |
| K1 实际 .so | `libonnxruntime.so → .so.1 → libonnxruntime.so.1.**18.1**` |
| 结论 | **1.18.1 < 1.23 → 落在"会 panic"的区间** |

**为什么 K3 没这个问题**:K3 的 Bianbu 4.0.1 预装 1.24.2+spacemit.a1,≥ 地板,dlopen 即用。

### ✅ 已解决(2026-09-09,K1 实测)—— 解法就在板子上

K1 已装的 **`python3-spacemit-ort`** 包内自带一个更新的 ORT:

```
/usr/lib/python3.12/dist-packages/onnxruntime/capi/
└── libonnxruntime.so.1.24.0+spacemit.a3     26.7 MB
```

| 检查项 | 结果 |
|---|---|
| 版本 | **1.24.0+spacemit.a3** ≥ 地板 1.23 ✅ |
| API v23(`probe-onnx.sh` dlopen + `GetApi(23)`) | ✅ **可用** |
| `GLIBC_2.38` / `GLIBCXX_3.4.30` / `CXXABI_1.3.15` | K1 有 2.39 / 3.4.33 / 1.3.15 ✅ |

已装到 `/opt/microduck-k1/ort/`(用 `ORT_DYLIB_PATH` 指向,**不覆盖 `/usr/lib`**)。

> **教训**:早先 `apt-cache search spacemit | head -20` 被截断,漏看了这个包 ——
> 它当时已经装在板上。**查包时不要截断输出。**

### 对策(按实际优先级)

| # | 方案 | 代价 | 状态 |
|---|---|---|---|
| **1** | **用 K1 自带的 `python3-spacemit-ort` 里的 ORT** | 零 | ✅ **已采用** |
| 2 | 从 K3 搬 1.24.2(ABI 已核对兼容) | 低 | 备选 |
| 3 | K1 apt 源里找更新包 | 低 | 已查:`v2.3` / `noble-porting` / `plucky` 均只有 1.18.1 |
| 4 | 自己编译 ONNX Runtime(riscv64) | 高 | 兜底 |
| 5 | 降 `ort` 绑定版本(动"代码零改动"前提) | 中 | 未用 |

`robotd` 只用 **CPU EP**,不需要 `libspacemit_ep.so`(8×A100 专用,K1 本就没有)。

**验证工具**:`K1\k1\probe-onnx.sh`(dlopen + `OrtGetApiBase()->GetApi(23)` + 一帧 61→14 推理)。

---

## 6. 进度与结果(2026-09-09 实测)

| 步 | 状态 |
|---|---|
| 1. 板卡确认(MUSE-Pi-Pro / X60 / Bianbu 2.3.3) | ✅ |
| 2. apt 依赖 + rustup 1.98.1 | ✅ |
| 3. 源码转储(本机 tar → scp) | ✅ |
| 4. 裁剪构建产出二进制 | ✅ **43m39s / 313 crate / robotd 7 319 888 B** |
| 5. `ort` 吃上 1.24.0(R1) | ✅ **已解决**(K1 自带) |
| 6. `robotd --sim` 联调 | ✅ **起身 → 站立 → 行走 1.245 m → 转向,未摔** |

| 指标 | K1 | K3(同期) |
|---|---|---|
| 空载环率(`--fake`) | **50.0 of 50 Hz · 0 missed** | 49.0 Hz · 0 missed |
| 联调环率(`--sim` 隧道) | 46.5–48.5 Hz | 47.9 Hz |
| ⚠️ **满载最低** | **40.7 Hz**(<45 门限) | 未低于 45 |
| 行走 | **1.245 m** | 1.145 m |
| CPU 温度 | **50 °C** | 64 °C |
| Web 控制台 | ✅ `:8081`(浏览器摇杆,实测驱动 1.44 m) | ✅ `:8081` |

**构建慢的真正原因**:K1 只有 **3.8 GiB 内存且无 swap**,6 个 rustc 并行(合计 ~1.9 GB)时
内核反复回收页缓存,load average 达 **10.36** —— 瓶颈是内存不是 CPU。

### 踩坑(9 条,详见 `K1\docs\05-联调实录.md` §踩坑清单)

1. K1 上 `github.com` 不可达 → 源码须本机打包 scp
2. **R1 解法就在板子上**(`python3-spacemit-ort` 自带 1.24.0);教训:`apt-cache search ... | head -20` 截断导致漏看
3. 构建慢 = 内存压力,不是 CPU;可 `cargo build -j4`
4. **`sit_toggle` 是切换不是"起身"** —— 连按两次坐回去
5. 已折叠的鸭子**不要用 `robot.init`**(线性 ramp 会拖倒),用 `sit_toggle`
6. **本机只能跑一个 `body_server`** —— 多实例抢 7801,后启动的"重启"无效
7. **浏览器与测试脚本会互相覆盖指令**(`robot.move` last-writer-wins)
8. `robotctl` 自建 socket 用 `--robot-socket`,不是 `--socket`
9. 仿真执行器简化,速度跟踪仅 37–39%,**指令过猛容易摔**(`vx=-0.40` 实测开翻)

**构建命令**(板子回来后重跑):

```bash
cd /opt/microduck-k1/microduck
export PATH="$HOME/.cargo/bin:$PATH"
cargo build --release --workspace \
    --exclude mediad --exclude duck-detect --exclude pet-detect
```

若失败按序排查:① `libudev-sys` → apt 装 libudev-dev/pkg-config;② dbus vendored → `--exclude configd btd`;
③ **ORT ABI 是运行期问题**,编译能过也要按 §5 验;④ 内存 3.8 GiB 不足则 `-j4`。

---

## 7. 相关文件

| 内容 | 位置 |
|---|---|
| 工程总目录 | `Desktop\Work_World\Microduck 机器鸭 × 进迭时空 优秀案例\` |
| **K1 版项目代码** | 上述目录 `K1\microduck_src\`(主仓 v0.11.0 + `--sim` 补丁,22 MB,4 文件差异) |
| K1 方案 / 环境 / 转储 / R1 | 上述目录 `K1\docs\01-04` |
| K1 侧脚本 | 上述目录 `K1\k1\`(run-all / env-init / build / **probe-onnx** / **fetch-ort-from-k3** / **install-ort** / sim-drive / **k3-sim-port.patch**) |
| K1 里程碑 + K3/K1 对照基线 | 上述目录 `K1\plans\MILESTONES.md` |
| K3 侧对照 | [`K3-PORT.md`](K3-PORT.md) |
| 芯片官方资料 | yolos-box 知识库 **21** |
