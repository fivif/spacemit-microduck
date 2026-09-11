# K1 摄像头链路实录 —— USB 取帧、厂商硬编、WebRTC 出流

> **一句话**:`mediad` 在 K1 上跑起来了,USB 摄像头 30 fps 取帧,厂商硬件 H.264 编码,
> WebRTC 出去,另一端是**真的**解出了 1 213 帧、**0 丢帧**。
> 它此前编不过的原因**不是** riscv64 缺 GStreamer/厂商硬件编码,而是板上没装 GStreamer
> 的 `-dev` 包。**实测日期 2026-09-11。**

---

## 1. 结论先行

| 项 | 实测 |
|---|---|
| 构建 | 全量 workspace(不裁任何 crate),`mediad` 在其中 |
| 取帧 | USB UVC 摄像头,1280×720@30 MJPEG |
| 编码 | `spacemith264enc`(厂商硬件 H.264,Main profile) |
| 采集环率 | **30.0 of 30 fps** |
| 消费端收到的帧率 | **29.97 of 30 fps,0 dropped**(1 213 帧 / 40.5 s,末端读数取整) |
| `mediad` 开销 | **约 123% 单核**(编码 + 取帧合计) |
| 控制台 | `mediad` 自带,`0.0.0.0:8080` |

**这件事的归档价值在"缺口是包装不是能力"这一点上。** 两块板都是 riscv64gc、都是
Bianbu、都是 GStreamer 1.24.2,厂商的编码插件就在 `/usr/lib/riscv64-linux-gnu/gstreamer-1.0/`
里躺着。编不出来只是因为编译期要的头文件从来没有 apt 装上去过 —— 一个装包动作,
被当成了平台能力的结论,写进了这个仓库的十几处文档里。

---

## 2. 那个结论是错的,错在哪

仓库里原先的说法是「`mediad` 依赖 GStreamer 与厂商硬件编码,riscv64 无对应实现」,
据此在构建时 `--exclude mediad`。这条在 K1 上**实测为假**:

| 检查 | 结果 |
|---|---|
| 厂商编码插件 | `/usr/lib/riscv64-linux-gnu/gstreamer-1.0/libgstspacemitcodec.so`,版本 **1.24.2** |
| 元素 | `spacemith264enc`,rank `primary + 1`(257) |
| GStreamer 包 | `gstreamer1.0-plugins-good` / `-base` / `-bad`、`gstreamer1.0-tools` 全在 |
| **缺的** | 只有 `libgstreamer1.0-dev` / `libgstreamer-plugins-base1.0-dev` / `libgstreamer-plugins-bad1.0-dev` |

**运行时在、开发头文件不在** —— 于是 `gstreamer-sys` 的 `build.rs` 找不到 `pkg-config`
元数据,整个 workspace 在 `mediad` 这一个 crate 上断掉。装齐三个 `-dev` 包后全量构建通过。

所以 K1 的排除已于 2026-09-11 撤销,**K1 现在不裁任何 crate**;K3 仍保留 `--exclude mediad`,
但理由是「K3 尚未把这条链跑起来」,不是 riscv64 做不了。

---

## 3. 取帧:一个 bin,两种模式

USB 摄像头走的不是 CSI 那条路。`pipeline::camera_source` 是给 rkisp 用的:它 shell 出去调
`media-ctl` 把 IMX219 钉进 1920×1080,再起一个裸 `v4l2src`。UVC 摄像头一样都不适用。

但**它之后的全都适用** —— tee、编码器、appsink、`detect`、`exposure` 都只认一个元素和一种
格式,不该知道世界上还有第二种摄像头。于是 `mediad/src/camera/uvc.rs` 把整条采集链
包成一个 [`gst::Bin`],只露一个 src pad。对 `pipeline::start` 来说它就是个普通源,
所以那个函数不需要为 USB 加分支,`[media] quality` 的含义也不变。

```text
v4l2src(device)
  → capsfilter(camera_format @ camera_width×camera_height@camera_fps)
  [ → jpegdec ]
  → videoconvert
  → capsfilter(UYVY, bt601 @ 摄像头模式)
  → videoscale(add-borders)
  → videorate(drop-only)
  → capsfilter(UYVY @ [media] quality)
```

配置(板上 `/etc/robot/robotd.toml`,只有 `[media]` 段):

```toml
[media]
camera = true
camera_kind = "uvc"
camera_device = "/dev/v4l/by-id/usb-…-video-index0"
camera_format = "mjpeg"
camera_width = 1280
camera_height = 720
camera_fps = 30
quality = "720p30"
```

四个决定值得记下来:

- **两种模式是两件事,不能合并成一个键。** 摄像头自己的模式(`camera_*`)和离开这个 bin 的
  模式(`quality`)是分开的。同一个机器人上两者通常相等,中间的元素就是直通;但它们**不
  可互换** —— UVC 摄像头只广告很短的几个模式,要一个它没有的,第一个 buffer 就
  `not-negotiated`。合并成一个键等于让 `quality` 决定摄像头有哪些模式。
- **`jpegdec`,不是 `avdec_mjpeg`。** MJPEG 是这类摄像头唯一能跑满速的格式 —— 实测这台
  1280×720 在 MJPG 下 30 fps,在未压缩 `YUYV` 下只有 **5 fps**(1.8 MB 一帧 × 30 Hz
  超过 USB 2.0 的带宽)。`jpegdec` 来自 `gstreamer1.0-plugins-good`,板上有;
  `avdec_mjpeg` 要 `gst-libav`,板上没有。
- **`videorate drop-only=true` 只丢帧、从不造帧。** 输出帧率高于摄像头时 GStreamer 不会
  拒绝,而是给帧打上并非采集时刻的时间戳 —— 那是一种"看着没问题"的错。参数校验和
  元素构建两处都拦这个组合。
- **`videoscale add-borders`,绝不拉伸。** 16:10 的传感器塞进 16:9 就是一张被压扁的图,
  下游没有任何办法把它和"镜头不对"区分开。

输出格式是 **`UYVY`**,这是契约不是偏好:它就是 `pipeline::CAPTURE_FORMAT`,是
`detect` 的闸门比较的那个值,也是 `exposure` 读亮度的那个值。在这里转换、而不是让那两个
模块学会第二种格式,正是这个模块存在的意义 —— 检测器的闸门遇到不认识的格式不是告警
后继续,而是直接返回并把线程带走。

**`colorimetry=bt601` 也不是可选项。** `videoconvert` 是把源的色彩矩阵**映射**到目标,
不是给字节换个标签;不写就会从源自己的元数据里挑一个目标,而 UVC 摄像头的 MJPEG 帧
通常是 full-range JFIF —— 于是到达检测器的 Y 值和 ISP 出来的不是一个刻度。模型是按
ISP 那个刻度训的。

### `YUYV` 与 `YUY2` 是同一个 fourcc 的两种拼法

整条管线里只有一处会暴露这个差异,写错就在第一个 buffer 上协商失败:

| V4L2 | GStreamer |
|---|---|
| `YUYV` | **`YUY2`** |
| `UYVY` | `UYVY` |
| `NV12` | `NV12` |

MJPEG 在两边都不是 raw 格式,它的 capsule 名是 `image/jpeg`,所以格式表对它无话可说。

---

## 4. 编码:厂商硬编的属性面,以及它少了什么

板上读到的 `gst-inspect-1.0 spacemith264enc`:

```
Rank        primary + 1 (257)
Long-name   Spacemit H264 Encoder
Filename    /usr/lib/riscv64-linux-gnu/gstreamer-1.0/libgstspacemitcodec.so
Version     1.24.2
```

属性:`code-hight`、`code-type`、`code-yuv-format`、`coding-type`、`coding-width`、
`min-force-key-unit-interval`、`preset`、`qos` —— 以及从 `GstVideoEncoder` 基类继承的
`name` / `parent`。

**没有 `bitrate`。** 这一条是本次实测最值得记下来的发现,见 §6。

编码器由 `webrtcsink` 自己挑(按 rank),`mediad` 通过 `encoder-setup` 信号去配置它。
这个信号里现在是**按工厂名分派**的:

```
if name == "mpph264enc" { profile=baseline; header-mode=each-idr; }
else if !discovering { warn "a consumer negotiated something other than hardware H.264" }
```

`else` 这一支是**给 Rockchip 那条路写的**,而且理由成立:`video-caps` 已经把 offer 限制到
H.264,所以走到 `else` 说明这个限制失效了,有东西正在和 `robotd` 控制环共用的核心上
软件编码 —— 值得大声说。

**在 K1 上它误报了。** 实测日志:

```
WARN mediad::pipeline: a consumer negotiated something other than hardware H.264
     encoder=spacemith264enc consumer=55156a24-…
```

名字是 `spacemith264enc` —— 这是**硬件**编码器,而且 rank 257 高于 `x264enc`,它正是
我们希望 `webrtcsink` 挑中的那个。这个告警只是把「不认识你」说成了「你不对」。

> **待办(未改)**:把分派改成**按能力**而不是按名字 —— 对 `mpph264enc` 设那两个属性,
> 其余情况检查下游 caps 拿到的编码器实例是不是一个 `GstVideoEncoder` 且不是已知的
> 软件编码器;或者至少把 `spacemith264enc` 加进已知硬件的名单,并给它一个能被配置的属性。
> 本文只记录现象,不动这段代码。

---

## 5. 那个 profile 要求:和 Rockchip 那次是**相反**的两个问题

这是本次唯一需要动系统的地方,而且它和 Rockchip 那次踩的坑**看起来一样、实质相反**。
`microduck/docs/project/media-bringup.md` 记过 RK 那次(§「The constraint flags were
worth reading, and the template was worse than the flags」):

| | Rockchip(`mpph264enc`) | **K1(`spacemith264enc`)** |
|---|---|---|
| 现象 | `webrtcsink` 索要 `profile=constrained-baseline`,协商空集,discovery 丢掉 H.264 | 同上 |
| 根因 | 编码器**能**出这个 profile,但 **pad 模板漏列**了它 | 编码器**根本产不出**它,只出 Main |
| 修哪边 | **修模板**(上游插件仓库一对一宽度补丁,发布为 `v3`) | **修要求**(本地构建的 `webrtcsink` 补丁) |

失败路径是同一个,而且**静默**:

1. `webrtcsink` 的 codec discovery 建链时不带输出 caps,于是
   `force_profile = output_caps.is_any() && needs_encoding` 为真,它插一个 capsfilter
   要求 `video/x-h264,stream-format=avc,profile=constrained-baseline`。
2. 这个 capsfilter 的位置就在 **`h264parse` 之后、`rtph264pay` 之前**。
3. `h264parse` 从 caps 查询里会剥掉 `alignment`、`stream-format`、`parsed`,**但不会剥
   `profile`** —— 要求一路传到编码器的 src pad。
4. 空交集 → `h264parse` not-negotiated → 整条 discovery 管线死掉。
5. 日志里只有一句 `No caps found for stream video_0` / `There is no codec present that
   can handle the stream's type` —— **既不提 profile,也不提编码器**。

K1 上为什么"修要求"而不是"修模板":`spacemith264enc` 上没有任何属性能把 profile 改掉。
`code-type`、`coding-type`、`code-yuv-format`、`preset` 都试过,`h264parse` 一律报 Main。
所以没有模板可以放宽,只能把这个**对所有人都生效**的要求收窄。

### 补丁的形状

`net/webrtc/src/utils.rs` 的 `parser_caps(force_profile)` 里,判断从

```rust
if force_profile {            // 向每一个 H.264 编码器索要 constrained-baseline
```

改成

```rust
if force_profile && self.forces_constrained_baseline() {   // 只向验证过的索要
```

**方向是关键,而且我第一版写反了。** 第一版把表写成"哪些编码器支持 constrained-baseline",
于是 `spacemith264enc` 不在表里 → 走旧路径 → 问题照旧。运行日志里那句
`Bitrate handling is not supported yet for spacemith264enc` 本身就是证据,说明运行时
编码器名就是 `spacemith264enc`。

正确的方向是**许可名单(permit)而不是拒绝名单(deny)**:

```rust
const KNOWN_CONSTRAINED_BASELINE: &[&str] = &[
    "x264enc", "openh264enc", "nvh264enc",
    "vaapih264enc", "qsvh264enc", "nvv4l2h264enc",
];
```

只有表里的继续保留这个要求 —— 对它们而言这仍然是 WebRTC 的互操作底线,该留;
**表外的**(包括没有任何人验证过的编码器)把 profile 字段整个去掉,编码器出什么就是什么。
**这个方向是安全的方向**:失败形态是"一个更大的 profile",而不是"一条死掉的流"。

脚本:`k1/k1/patch-webrtcsink.sh`(幂等;发现半补丁残留会拒绝执行而不是硬打)。

### 构建,以及为什么不能信增量

板上的 `gst-plugins-rs` 源码在 `/tmp/gst-plugins-rs-0.14.5`,产物装到
`/usr/local/lib/gstreamer-1.0/libgstrswebrtc.so`(板上 apt 的 `gstreamer1.0-plugins-bad`
**不含** `webrtcsink`,它只来自这个本地产物)。

```bash
cd /tmp/gst-plugins-rs-0.14.5
source /root/.cargo/env
export CARGO_PROFILE_RELEASE_DEBUG=0          # 关调试信息,否则默认的 debug 版会把镜像写爆
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16 # 降低单进程内存峰值
cargo build --release -p gst-plugin-webrtc --offline -j 1
cp target/release/libgstrswebrtc.so /usr/local/lib/gstreamer-1.0/
```

两个坑:

- **`-j 1` 必须在脚本内部 `export`。** 每条 ssh 命令都是一次新会话,写在命令行前缀上的
  环境变量到不了子进程 —— 用了默认并行度就是内核 oops。
- **`touch` 源码不足以让增量构建重编。** 有一次构建 2.34 秒就报 `Finished`,产出的 `.so`
  与打补丁前**逐字节相同**。可靠做法是删掉这个 crate 的指纹目录和 `deps/libgstrswebrtc.{so,rlib}`
  再编。**板上的增量构建不可信。**
- **用 `strings | grep` 验证补丁有没有进去也是不可靠的。** Rust 的 `&str` 常量尾合并在高
  优化级别下会把表名折进别的字符串里,`grep -c spacemith264enc` 返回 0 并不代表补丁不在。
  改用 `grep -ac "x264enc"`,返回 2。

---

## 6. 码率控制:厂商驱动的一个缺口,不是一个移植 bug

跑起来之后日志里有一行 ERROR:

```
ERROR gst: Bitrate handling is not supported yet for spacemith264enc
     cat=webrtcsink src=webrtcsink0 file=net/webrtc/src/webrtcsink/imp.rs line=1728
```

来源是 `webrtcsink` 的 `configure_congestion_control`,它记录一条警告然后
`return Ok(())` —— **不致命**。

但它指向的东西是真的:`spacemith264enc` **没有 `bitrate` 属性**(`gst-inspect` 里
`bitrate` 命中数为 0)。所以:

- `[media] bitrate` 在这块板上**不生效**;
- `congestion_control` 在这块板上**不生效** —— 拥塞控制没有可调的旋钮。

**这是厂商编码器驱动的接口缺口,应该照实记录,而不是伪装成移植问题。** RK 那条路上
`mpph264enc` 有 `bps` 和 `rc-mode=cbr`,所以那份 `microduck/docs/project/media-bringup.md`
里"四个属性是管线决策"的表**不能照抄到 K1**。K1 的等价表格目前只有一行:没有可设的码率。

---

## 7. 端到端验证:帧是真的出来了

**消费端是 `webrtcsrc`** —— 和 `webrtcsink` 同一个插件里的真元素,它自己起一条
`gst-launch-1.0`,于是"机器人的流出去了也到了"这句话是由**被验证进程之外**的东西说的。

板上有别的负载(`nanomq`、换脑项目的 `neuron`、一个 MQTT 基准),量之前先把基准停掉,
并记录前后 loadavg —— `docs/K1-PORT.md` 踩坑 9 说的就是这个。

```bash
# 消费端(板内,127.0.0.1)
gst-launch-1.0 -v \
  webrtcsrc signaller::uri="ws://127.0.0.1:8443" \
              signaller::producer-peer-id="<producer-id>" \
  ! decodebin ! videoconvert \
  ! fpsdisplaysink video-sink=fakesink text-overlay=false sync=false
```

`producer-peer-id` 要照抄 —— 它是 signaller 子对象的属性,**不会**出现在
`gst-inspect-1.0 webrtcsrc` 的输出里,漏掉它不会大声失败:元素建得起来、管线进
PLAYING、然后一帧都不来。

实测(loadavg 3.8,已停掉 MQTT 基准):

```
rendered: 162,  dropped: 0, current: 32.40, average: 32.40
rendered: 313,  dropped: 0, current: 30.01, average: 31.20
rendered: 763,  dropped: 0, current: 29.96, average: 30.46
rendered: 1213, dropped: 0, current: 29.97, average: 30.28
```

**1 213 帧,0 丢帧,稳定在 29.97 of 30 fps**,`mediad` 端同时报
`capture rate fps=30.0 target=30`。首段 32.40 是启动瞬间的时钟对齐,取稳态读数。

同一段时间里 `mediad` 自己消耗 `/proc/<pid>/stat` 的 utime+stime **约 123% 单核** ——
USB 取帧、MJPEG 解码、色彩转换、硬件编码全部折在里面。

> **别用 PNG 计数去量帧率。** 第一次跑的时候送进 `pngenc`,65 秒只落盘 316 个文件,
> 看起来像 4.9 fps。那不是流的帧率,是八个 X60 核编 720p PNG 的速度。要量流就用
> `fakesink`。

---

## 8. 踩坑

1. **`YUYV` 写成 GStreamer 的 `YUY2`** —— V4L2 与 GStreamer 对同一个 fourcc 两种拼法,
   写错就在第一个 buffer 上协商失败。
2. **取帧不能裸用 `v4l2src`(CSI 那条路)** —— rkisp 给它 2 个 buffer 的池,回收太慢,
   每三帧丢一帧。USB 那条路没有这个问题,所以 `uvc.rs` **不**调
   `raise_capture_buffers`。
3. **输入侧的 capsfilter 不是装饰** —— 不钉住摄像头模式的话,`v4l2src` 协商到什么就是
   什么,要到摄像头没有的格式会在第一个 buffer 上失败;钉住之后失败发生在链接期,
   报错里带 caps。
4. **`profile-attached` 的坑:补丁表写反了方向** —— 见 §5。许可名单,不是拒绝名单。
5. **板上的增量构建不可信** —— 见 §5,`touch` 不够,要删指纹。
6. **`-j 1` 要写在脚本里** —— 每条 ssh 是新会话,命令行前缀的环境变量传不到子进程。
7. **给编码器设它没有的属性会 panic** —— 而信号处理器里的 panic 会 abort。所以
   `encoder-setup` 里一律按工厂名先判断,不"抱着试试看"的心态去 set。
8. **量帧率要用 `fakesink`** —— 见 §7。
9. **量之前先确认板上没别的活** —— 同 `docs/K1-PORT.md` 踩坑 9。先看 `ps` 和
   `/proc/loadavg`。

---

## 9. 复现

```bash
# 板子上一次性
bash env-init.sh                                   # 已含三个 GStreamer -dev 包
bash build-k1.sh                                   # 全量 workspace,不裁

# 跑起来
export GST_PLUGIN_PATH=/usr/local/lib/gstreamer-1.0
setsid nohup ./target/release/mediad --config /etc/robot/robotd.toml \
  </dev/null >/tmp/mediad-serve.log 2>&1 &

# producer id(日志带 ANSI 颜色,先剥掉)
sed 's/\x1b\[[0-9;]*m//g' /tmp/mediad-serve.log \
  | grep 'registered as \[Producer\]' | tail -1

# 用上面那串 id 接一路消费端,看帧率
gst-launch-1.0 -v webrtcsrc signaller::uri="ws://127.0.0.1:8443" \
  signaller::producer-peer-id="<id>" ! decodebin ! videoconvert \
  ! fpsdisplaysink video-sink=fakesink text-overlay=false sync=false
```

---

## 10. 相关文件

| 内容 | 位置 |
|---|---|
| USB 采集 bin | [`microduck/mediad/src/camera/uvc.rs`](../microduck/mediad/src/camera/uvc.rs) |
| 摄像头几何 / intrinsics | [`microduck/mediad/src/camera.rs`](../microduck/mediad/src/camera.rs) |
| 源分派 / `encoder-setup` / `video-caps` | [`microduck/mediad/src/pipeline.rs`](../microduck/mediad/src/pipeline.rs) |
| `webrtcsink` profile 补丁 | [`k1/k1/patch-webrtcsink.sh`](../k1/k1/patch-webrtcsink.sh) |
| Rockchip 侧的同名坑(模板 vs 要求) | [`microduck/docs/project/media-bringup.md`](../microduck/docs/project/media-bringup.md) |
| K1 移植总记录 | [`K1-PORT.md`](K1-PORT.md) |
