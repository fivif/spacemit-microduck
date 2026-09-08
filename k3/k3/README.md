# k3/ — K3 侧脚本

| 文件 | 作用 | 位置/执行方式 |
|---|---|---|
| `env-init.sh` | rustup(minimal)+ clone 主仓到 `/opt/microduck-k3/microduck` | 传 `/tmp` 后 `bash /tmp/env-init.sh`(root) |
| `build-k3.sh` | 裁剪构建(`--exclude mediad duck-detect pet-detect`) | env-init 后执行同路径 |
| `probe-onnx.sh`(待写,P0 第 4 步) | dlopen libonnxruntime.so + 61→14 策略 ONNX 一帧推理 | P0 验收项 |
| `units/`(待写,P2) | Bianbu systemd unit 集 | 参考主仓 `deploy/` |

## 传递脚本到 K3 的姿势(Git Bash)

```bash
cd /c/Users/zhuxuanjia/Desktop/Work_World/yolos-box
cat "/c/Users/zhuxuanjia/Desktop/Work_World/Microduck 机器鸭 × 进迭时空 优秀案例/K3/k3/env-init.sh" | \
  ./tools/k3ssh.sh root@10.5.90.195 'cat > /tmp/env-init.sh; bash /tmp/env-init.sh'
```

> SSH 细节见 yolos-box 知识库 **20 §5**(k3ssh.sh 第一参数必须是 `root@10.5.90.195` 旧 token)。
