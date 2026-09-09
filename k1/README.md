# K1 —— 机器鸭运行时的 RISC-V 移植

> 在 **SpacemiT K1（MUSE-Pi-Pro，8× X60）** 上原生编译并运行 Microduck 的 Rust 运行时。
> 实测日期 2026-09-08 / 09。

---

## 目标

把同一套运行时（`robotd` 50 Hz 控制环 + 策略执行 + 舵机总线 + 周边 daemon）
原生编译到 riscv64 并跑起来。**代码零改动** —— 与 K3 共用同一份源码，
差异全在运行性能，不在编译路径（同一个 `riscv64gc` target）。

---

## 结果

| 项 | 实测 |
|---|---|
| 板卡 | `spacemit k1-x MUSE-Pi-Pro board`，8× X60，Bianbu 2.3.3，3.8 GiB |
| 裁剪构建 | **43m39s**，313 crate，`robotd` 7 319 888 B |
| 策略加载 | 官方 9 个 ONNX 全部加载 |
| 起身 | z 0.070 → **0.116** |
| 行走 | **1.245 m**，未摔；转向成功 |
| 空载环率 | **50.0 of 50 Hz，0 missed** |
| 联调环率 | 46.5–48.5 of 50 Hz |
| 满载最低 | **40.7 Hz**（低于 45 Hz 健康门限） |
| CPU 温度 | 50 °C |

---

## 目录

```
K1/
├── README.md              本文件
├── microduck_src/         要编译的完整源码（主仓 v0.11.0 + --sim 补丁）
├── docs/
│   ├── 01-K1版方案.md      交付物映射 + 验收标准
│   ├── 02-K1环境实测.md    板卡身份 / 工具链 / ONNX Runtime / 环境
│   ├── 03-源码获取与构建.md 打包传输 + 构建
│   ├── 04-与K3差异与R1风险.md  K3/K1 对照 + ONNX Runtime 版本冲突与解决
│   └── 05-联调实录.md      起身 / 行走 / 转向 实录 + 踩坑
├── k1/                     板卡侧脚本
└── plans/MILESTONES.md     里程碑 + K3/K1 对照
```

---

## ONNX Runtime 版本冲突

主仓 `ort` 绑定的地板是 **1.23**，低于此版本会在 `setup_api` 中 panic。
K1 的 apt 只提供 `libonnxruntime.so.1.18.1`，但板上已装的 `python3-spacemit-ort`
包内自带 **1.24.0**：

```
/usr/lib/python3.12/dist-packages/onnxruntime/capi/
└── libonnxruntime.so.1.24.0+spacemit.a3
```

用 `ORT_DYLIB_PATH` 指向它即可，不覆盖 `/usr/lib`（板上其它依赖 1.18.1 的程序不受影响）。

---

## 构建

```bash
cd /opt/microduck-k1/microduck
cargo build --release --workspace \
    --exclude mediad --exclude duck-detect --exclude pet-detect
```

构建比 K3 慢 6.5 倍的原因是**内存不是 CPU**：3.8 GiB 且无 swap，六个 rustc 并行时
内核反复回收页缓存。需要更稳的墙钟时间可用 `cargo build -j4`。

---

## 复现

```bash
# 开发机：启动仿真 + 端口映射
cd microduck_rl
PYTHONPATH=src <venv>/Scripts/python.exe -m mjlab_microduck.sim.body_server --port 7801
ssh -N -R 7801:127.0.0.1:7801 root@<board>

# 板子
cd /opt/microduck-k1/microduck
export ORT_DYLIB_PATH=/opt/microduck-k1/ort/libonnxruntime.so
setsid nohup ./target/release/robotd --sim 127.0.0.1:7801 </dev/null >/tmp/robotd.log 2>&1 &
python3 sim-drive.py --enable --init --vx 0 --seconds 12   # 起身 + 站立
python3 sim-drive.py --vx 0.25 --seconds 14                # 行走
./target/release/robotctl --robot-socket /run/robotd.sock health

# Web 控制台（浏览器摇杆）
cd /opt/microduck-k1/web
setsid nohup python3 server.py --port 8081 --socket /run/robotd.sock </dev/null >/tmp/web.log 2>&1 &
```

---

## 相关

| 内容 | 位置 |
|---|---|
| 环境 / 构建 / 冲突解决 / 联调 | [`docs/01`–`05`](docs) |
| 里程碑与 K3/K1 对照 | [`plans/MILESTONES.md`](plans/MILESTONES.md) |
| K3 版本 | [`../k3/`](../k3) |
