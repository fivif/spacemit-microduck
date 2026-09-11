#!/bin/bash
# 给 gst-plugins-rs 的 webrtcsink 打补丁:它不该向做不到的编码器索要
# profile=constrained-baseline。
#
#   parser_caps(force_profile) 是 net/webrtc/src/utils.rs 里的一个 Rust 助手函数。
#   webrtcsink 在 PayloadChainBuilder::build 里这样调它:
#       force_profile = self.output_caps.is_any() && needs_encoding
#   于是生成一个 capsfilter,位置正好卡在 h264parse 之后、rtph264pay 之前。
#   spacemith264enc 出的是 Main,所以
#       h264parse ! video/x-h264,stream-format=avc,profile=constrained-baseline
#   必然 not-negotiated,整条 discovery 管线跟着死,只留一句
#   "No caps found for stream video_0"。
#
# spacemith264enc 上没有任何属性能把 profile 改掉(code-type、coding-type、
# code-yuv-format、preset 试过,h264parse 一律报 Main),所以要挪的是这个 profile
# 要求,不是编码器。
#
# **下面这张表是"已知能出 constrained-baseline"的编码器名单。** 表里的仍然照旧钉死
# profile;表外的 —— 包括 spacemith264enc,也包括任何没人验证过的编码器 —— 不再带
# profile 字段,编码器出什么就是什么。方向很重要:没验证过的编码器绝不能被强求,
# 否则流会在一个既不提 profile 也不提编码器名字的地方断掉。
#
# 与 Rockchip 那条路的区别:RK 侧 mpph264enc 的 pad 模板漏了 constrained-baseline,
# 补的是**模板**;这里编码器根本产不出那个 profile,所以改的是**要求**。见
# ../../microduck/docs/project/media-bringup.md 的对照。
#
# 用法: patch-webrtcsink.sh [SRCROOT]   默认 /tmp/gst-plugins-rs-0.14.5
set -euo pipefail

SRCROOT="${1:-/tmp/gst-plugins-rs-0.14.5}"
UTILS="$SRCROOT/net/webrtc/src/utils.rs"

if [ ! -f "$UTILS" ]; then
  echo "patch-webrtcsink: no $UTILS" >&2
  exit 1
fi

if grep -q "KNOWN_CONSTRAINED_BASELINE" "$UTILS"; then
  echo "patch-webrtcsink: already applied, nothing to do"
  exit 0
fi

python3 - "$UTILS" <<'PY'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    src = f.read()

# An earlier revision of this script inserted a marker list; take it back out
# first so re-running on a tree that already has it is still a clean patch.
for stale in ("h264_encoder_supports_constrained_baseline", "ALLOW_ANY_H264_PROFILE"):
    if stale in src:
        sys.exit(f"patch-webrtcsink: {stale} found but KNOWN_CONSTRAINED_BASELINE is not — "
                 "the tree is in a half-patched state, revert utils.rs and re-run")

anchor = "    pub fn parser_caps(&self, force_profile: bool) -> gst::Caps {"
if anchor not in src:
    sys.exit("patch-webrtcsink: parser_caps anchor not found — refusing to guess")

# The Rust below is left in English: it lands in an upstream file whose comments
# are English, and a patch that reads in two languages is worse than one that
# reads in one.
insert = '''    /// Encoders verified to emit `constrained-baseline` on their src pad.
    ///
    /// `parser_caps` used to demand that profile from **every** H.264 encoder.
    /// When the encoder can produce it that is right and worth keeping: the
    /// profile is WebRTC's interoperable floor. When it cannot, the demand is
    /// unsatisfiable and the failure is silent — `h264parse` is not-negotiated,
    /// the discovery pipeline dies, and the only message is "No codec present
    /// that can handle the stream's type", naming neither the profile nor the
    /// encoder. A hardware block that makes Main only (spacemith264enc) is the
    /// case that found this.
    ///
    /// So the list is a *permit*, not a deny: only these keep the demand, and
    /// everything else — including encoders nobody has tested — passes its own
    /// profile through. That direction is the safe one, because it fails as a
    /// larger profile rather than as a dead stream.
    const KNOWN_CONSTRAINED_BASELINE: &[&str] = &[
        "x264enc",
        "openh264enc",
        "nvh264enc",
        "vaapih264enc",
        "qsvh264enc",
        "nvv4l2h264enc",
    ];

    fn forces_constrained_baseline(&self) -> bool {
        self.encoder_name()
            .map(|name| Self::KNOWN_CONSTRAINED_BASELINE.contains(&name.as_str()))
            .unwrap_or(false)
    }

'''

src = src.replace(anchor, insert + anchor, 1)

old = """                if force_profile {
                    gst::debug!(
                        CAT,
                        "No H264 profile requested, selecting constrained-baseline"
                    );

                    gst::Caps::builder(codec_caps_name)
                        .field("stream-format", "avc")
                        .field("profile", "constrained-baseline")
                        .build()
                } else {"""

new = """                if force_profile && self.forces_constrained_baseline() {
                    gst::debug!(
                        CAT,
                        "No H264 profile requested, selecting constrained-baseline"
                    );

                    gst::Caps::builder(codec_caps_name)
                        .field("stream-format", "avc")
                        .field("profile", "constrained-baseline")
                        .build()
                } else if force_profile {
                    gst::debug!(
                        CAT,
                        "No H264 profile requested and this encoder is not known to \\
                         emit constrained-baseline; taking the encoder's own profile"
                    );

                    gst::Caps::builder(codec_caps_name)
                        .field("stream-format", "avc")
                        .build()
                } else {"""

if old not in src:
    sys.exit("patch-webrtcsink: parser_caps body not found verbatim — refusing to guess")

src = src.replace(old, new, 1)

with open(path, "w", encoding="utf-8") as f:
    f.write(src)

print("patch-webrtcsink: patched", path)
PY

grep -n "forces_constrained_baseline\|KNOWN_CONSTRAINED_BASELINE" "$UTILS"
