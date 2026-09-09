# K1 版 — 机器鸭换脑 · 落地形态

> **状态**: ✅ **P0' + P1' 核心达成**(2026-09-09) —— K1 原生编译的 `robotd` 驱动机器鸭完成
> 起身 → 站立 → 行走 1.245 m → 转向,全程未摔;Web 控制台可浏览器操控。
> **上游参考**: [`../K3/docs/04-K1版前瞻.md`](../K3/docs/04-K1版前瞻.md)(立项预判)·
> [`docs/04-与K3差异与R1风险.md`](docs/04-与K3差异与R1风险.md)(实测校正)·
> [`docs/05-联调实录.md`](docs/05-联调实录.md)(本轮结果)

---

## 为什么还要 K1

K3 是**算力标杆**(证明 RISC-V 跑得动机器人运行时),K1 是**落地形态**:
MUSE-Pi-Pro 板卡体积与功耗更贴近真机换脑的实际需求。
优秀案例可以同时呈现两个版本 —— K3 立技术高度,K1 给可落地的集成路径。

## 板卡已确认(2026-09-08 实测)

| 项 | 值 |
|---|---|
| device-tree model | **`spacemit k1-x MUSE-Pi-Pro board`** |
| CPU | 8× Spacemit(R) **X60**,含 `_ime`(AI 融合指令扩展) |
| OS | Bianbu **2.3.3**(noble)· 内核 6.6.63 · glibc 2.39 |
| 内存 | **3.8 GiB**(4 GB 档) |

## K1 与 K3 的关键差异

| 维度 | K3 | K1 | 影响 |
|---|---|---|---|
| CPU | 8×X100 @2.4GHz | 8×X60 @1.8GHz | 单核 9.5 vs 3.5;50Hz 环 + MLP 仍富余 |
| AI | 60 TOPS EP | 2 TOPS(CPU 指令内) | 两边都走 CPU EP,策略 MLP 不吃亏 |
| 内存 | 8 GiB(本机档) | **3.8 GiB** | 裁剪构建够用 |
| OS | Bianbu 4.0.1 | Bianbu 2.3.3 | 同源 |
| **ORT** | ✅ 预装 **1.24.2+spacemit.a1** | ✅ **python3-spacemit-ort 自带 1.24.0**（系统 apt 只有 1.18.1） | R1 已解，见 `docs/04` |
| 实时核 | ✅ RCPU 600MHz(CAN-FD/TSN) | ❌ 无 | P2 真机总线抖动需实测 |
| 板卡形态 | K3 Pico-ITX | **MUSE-Pi-Pro** | 体积/功耗更适合真机集成 |

## 平移计划(继承 K3 方案,代码零改动)

1. **环境**:[`k1/env-init.sh`](k1/env-init.sh) —— apt 依赖 + rustup + 源码就位 + 打补丁
2. **构建**:[`k1/build-k1.sh`](k1/build-k1.sh)(裁剪 `--exclude mediad duck-detect pet-detect`)
3. **仿真客户端**:`--sim` 补丁已导出为 [`k1/k3-sim-port.patch`](k1/k3-sim-port.patch),`git apply` 即得
4. **策略**:`../K3/policies/` 的 9 个 ONNX + manifest 直接复用(与芯片无关)
5. **唯一风险点**:K1 的 `libonnxruntime.so`(**1.18.1**)与 `ort rc.11` 的地板(**1.23**)冲突
   —— 对策见 [`docs/04`](docs/04-与K3差异与R1风险.md) §2
6. **验收**:复刻 K3 P0/P1 —— robotd 编译通过 + 加载策略 + `robotd --sim` 接本地 MuJoCo 鸭

## 目录

```
K1/
├── README.md                       ← 本文件
├── microduck_src/                  ★ K1 版项目代码(主仓 v0.11.0 + --sim 补丁,22 MB)
│   └── README.md                   与上游的差异 / 结构 / 怎么送到 K1
├── docs/
│   ├── 01-K1版方案.md              交付物映射 + 验收标准
│   ├── 02-K1环境实测.md            板卡身份 / 工具链 / ORT / 网络(实测)
│   ├── 03-源码获取与构建.md        github 不可达 → 本机打包转储 + 构建状态
│   ├── 04-与K3差异与R1风险.md      K3/K1 对照表 + ORT 版本冲突对策
│   └── 05-联调实录.md              ★ 2026-09-09 实测:起身/行走/转向/环率 + 9 条踩坑
├── k1/
│   ├── README.md                   脚本说明 + R1 处理链 + 传递姿势
│   ├── run-all.sh                  ★ 一键:环境 → 构建 → R1 → 冒烟
│   ├── env-init.sh                 一次性环境初始化
│   ├── build-k1.sh                 裁剪构建
│   ├── probe-onnx.sh               ★ R1 探针(dlopen + GetApi(23) + 一帧推理)
│   ├── fetch-ort-from-k3.sh        ★ 从 K3 搬 1.24.2(本机跑)
│   ├── install-ort-k1.sh           ★ 装到 /opt/microduck-k1/ort + ORT_DYLIB_PATH
│   ├── sim-drive.py                驱动 robotd(与 K3 版相同)
│   └── k3-sim-port.patch           --sim 移植补丁(已应用进 microduck_src)
└── plans/MILESTONES.md             P0'/P1'/P2' + K3/K1 对照基线
```

> **代码已就绪**:[`microduck_src/`](microduck_src/) 就是 K1 要编的完整源码
> (上游 v0.11.0 + `--sim` 补丁,4 文件差异,md5 已核对),**K1 上一行不改**;
> K1 侧脚本全部通过 `bash -n` / `py_compile`,板子回来跑 `run-all.sh` 即可。

## 实测结果(2026-09-09)

| 项 | 值 |
|---|---|
| 裁剪构建 | **43m39s**,313 crate,`robotd` 7 319 888 B |
| R1(ORT) | ✅ 用 K1 自带的 **1.24.0+spacemit.a3**,策略全部加载 |
| 空载环率 | **50.0 of 50 Hz · 0 missed** |
| 起身 | z 0.070 → **0.116** |
| 行走 | **1.245 m** 未摔 |
| 转向 | ✅ `vyaw=0.5` |
| 联调环率 | 46.5–48.5 of 50 Hz |
| ⚠️ 满载最低 | **40.7 Hz**(低于 45 健康门限) |
| CPU 温度 | **50 °C**(K3 同期 64 °C) |
| Web 控制台 | ✅ `:8081`,浏览器摇杆驱动实测 1.44 m |

> 详情与 9 条踩坑:[`docs/05-联调实录.md`](docs/05-联调实录.md)

## 待办清单

- [ ] 满载环率余量优化(40.7 Hz < 45 门限)
- [ ] 真机集成评估(尺寸/供电/UART 总线/**实时性**)
- [ ] 与 K3 做更细的算力对比(同策略同场景、多次采样)
