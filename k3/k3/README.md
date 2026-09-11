# k3/ — K3 侧脚本

| 文件 | 作用 | 位置/执行方式 |
|---|---|---|
| `env-init.sh` | rustup(minimal)+ 核对 `/opt/microduck-k3/microduck` 源码树 | 传 `/tmp` 后 `bash /tmp/env-init.sh`(root) |
| `build-k3.sh` | 裁剪构建(`--exclude mediad`;K3 尚未把 mediad 跑起来,非 riscv64 缺实现,见 [`../../docs/K1-MEDIA.md`](../../docs/K1-MEDIA.md))+ 架构核对 | env-init 后执行同路径 |
| `sim-drive.py` | 驱动 robotd(hello → enable → init → move),协议见 `docs/05` | 在 K3 上 `python3 sim-drive.py --enable --init --vx 0 --seconds 8` |
| **`bench_policy.py`** | **策略推理基准**:单次推理耗时(mean/p50/p95/p99/max)+ 占 50 Hz 预算比例 | 在 K3 上 `python3 bench_policy.py --iters 2000` |
| `probe-onnx.sh`(待写,P0 第 4 步) | dlopen libonnxruntime.so + 61→14 策略 ONNX 一帧推理 | P0 验收项 |
| `units/`(待写,P2) | Bianbu systemd unit 集 | 参考主仓 `deploy/` |

## bench_policy.py

复刻 `duck-control/src/policy.rs` 的会话配置(`Level3` 图优化 + `intra_threads=1`),
对 `--dir` 下每个 `.onnx` 跑 `--iters` 次,报告分位数。

```bash
python3 bench_policy.py                      # 默认 /opt/robot/policies/current,2000 次
python3 bench_policy.py --iters 5000
python3 bench_policy.py --providers          # 只看运行时版本与可用 EP
```

**K3 实测(2026-09-09)**:9 个策略一致 **0.201 ms** 均值,p99 ≤ 0.223 ms,占 50 Hz 预算 **1.01%**。
完整数据与整环 CPU 占用见 [`../../docs/POLICY-RUNTIME.md`](../../docs/POLICY-RUNTIME.md)。

> 注意: 整环 CPU 测量用 `robotctl health` 时要传 `--robot-socket`(不是 `--socket`,后者给 updaterd)。

## 传递脚本到 K3(Git Bash)

```bash
# 源码树(先解包到 /opt/microduck-k3/microduck,见 ../../k1/docs/03)
tar czf /tmp/k3-src.tar.gz microduck
scp /tmp/k3-src.tar.gz root@<board>:/opt/microduck-k3/

# 脚本
scp env-init.sh build-k3.sh sim-drive.py bench_policy.py root@<board>:/tmp/
ssh root@<board> 'bash /tmp/env-init.sh && bash /tmp/build-k3.sh'
```
