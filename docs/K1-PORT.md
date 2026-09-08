# K1 换脑实录 —— MUSE-Pi-Pro 上的移植进展

> **一句话**:把 K3 已跑通的换脑方案平移到 **SpacemiT K1(MUSE-Pi-Pro)**。
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
| **ONNX Runtime** | ✅ 预装 **1.24.2+spacemit.a1** | ❌ apt 只有 **1.18.1** | ⚠️ **R1 爆发点** |

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

### 对策(按优先级)

| # | 方案 | 代价 |
|---|---|---|
| **1** | **从 K3 搬 `libonnxruntime.so.1.24.2+spacemit.a1`** | 低 —— ★ 首选 |
| 2 | 在 K1 apt 源里找更新的包(包名 `spacemit-onnxruntime`,K1 装到的叫 `onnxruntime`) | 低 |
| 3 | 自己编译 ONNX Runtime(riscv64) | 高 |
| 4 | 官方 riscv64 预编译包 | 中 |
| 5 | 降 `ort` 绑定版本(动"代码零改动"前提) | 中 |

**方案 1 的可行性已核对**(K3 上 `readelf` 实测,K1 侧比对):

| K3 的 ORT 需求 | K1 实测 | |
|---|---|---|
| `GLIBC_2.38`(最高) | glibc **2.39** | ✅ |
| `GLIBCXX_3.4.30`(最高) | gcc 13.2 → **3.4.32** | ✅ |
| `ELF 64-bit UCB RISC-V, RVC, double-float` | 同架构/同 ABI | ✅ |

`robotd` 只用 **CPU EP**,不需要 `libspacemit_ep.so`(8×A100 专用,K1 本就没有)。
**唯一未知**:spacemit 的 ORT 可能在初始化时 dlopen `libspacemit_ep.so`(非 NEEDED,运行时加载),
K1 无此库 —— 需上板实测。

**验证工具已备好**:`K1\k1\probe-onnx.sh`(dlopen + `OrtGetApiBase()->GetApi(23)` + 一帧 61→14 推理)、
`fetch-ort-from-k3.sh`(本机拉取)、`install-ort-k1.sh`(K1 安装,用 `ORT_DYLIB_PATH` 不覆盖系统库)。

---

## 6. 进度与未验证项

| 步 | 状态 |
|---|---|
| 1. 板卡确认(MUSE-Pi-Pro / X60 / Bianbu 2.3.3) | ✅ |
| 2. apt 依赖 + rustup 1.98.1 | ✅ |
| 3. 源码转储(本机 tar → scp) | ✅ |
| 4. 裁剪构建产出二进制 | 🟡 已启动,板子离线前未跑完(停在 crates.io 下载阶段) |
| 5. `ort` 吃上 1.18.1(R1) | ❌ 未验证 |
| 6. `robotd --sim` 联调 / 环率 / 位移 | ❌ 未验证 |

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
