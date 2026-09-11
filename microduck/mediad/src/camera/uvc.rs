//! A USB camera, as **one** element the rest of the pipeline already knows how to take.
//!
//! `pipeline::camera_source` is the CSI path: it shells out to `media-ctl` to pin an IMX219 into
//! 1920×1080, then builds a bare `v4l2src`. None of that applies to a UVC camera. What *does*
//! apply is everything after it — the tee, the encoder, the appsink, [`crate::detect`] and
//! [`crate::exposure`] all take one element and one format, and neither should learn that a second
//! kind of camera exists.
//!
//! So this module builds the whole capture chain and wraps it in a [`gst::Bin`] with a single src
//! pad. To `pipeline::start` it is a source like any other, which is why that function needs no
//! branch for USB and why [`crate::pipeline::CAPTURE_FORMAT`] keeps the value it has.
//!
//! # The chain, and why each element is there
//!
//! ```text
//! v4l2src(device)
//!   → capsfilter(camera_format at camera_width×camera_height@camera_fps)
//!   [ → jpegdec ]
//!   → videoconvert
//!   → capsfilter(UYVY at the camera's mode)
//!   → videoscale(add-borders)
//!   → videorate(drop-only)
//!   → capsfilter(UYVY at [media] quality)
//! ```
//!
//! **Two modes, and the pipeline is told both.** The camera's own — `[media] camera_width`,
//! `camera_height`, `camera_fps` — and the one that leaves this bin, `[media] quality`. They are
//! the same numbers on most robots and the elements between them are then passthroughs. What they
//! are not is *interchangeable*: a UVC camera advertises a short list of modes and asking for one
//! it does not have is `not-negotiated` at the first buffer, so a config file that conflated the
//! two would make `quality` a key that decides which camera modes exist.
//!
//! **The input capsfilter is not decoration.** `v4l2src` negotiates whatever the camera offers;
//! asking for a format the camera does not have fails at the first buffer, which is a pipeline that
//! starts and then dies rather than one that refuses to build. Pinning the input side means the
//! failure is at link time, where the message names the caps.
//!
//! **`jpegdec`, not `avdec_mjpeg`.** MJPEG is the only thing this class of camera does at full
//! rate — the one measured here does 1280×720 at 30 fps in MJPG and **5 fps** in uncompressed
//! `YUYV`, because a 1.8 MB frame at 30 Hz is more than USB 2.0 will carry. `jpegdec` comes from
//! `gstreamer1.0-plugins-good`, which the board has; `avdec_mjpeg` needs `gst-libav`, which it does
//! not.
//!
//! **`videoscale` before `videorate`, and the middle capsfilter between them and the decoder.**
//! The capsfilter is what makes the camera's mode a thing the pipeline *negotiated* rather than a
//! number in a file, and what makes the two transforms work on the `UYVY` the rest of the pipeline
//! expects instead of on whatever `jpegdec` emits. `add-borders` rather than a stretch: a 16:10
//! sensor into a 16:9 stream is a picture that has been squashed, and nothing downstream can tell
//! that from a lens that is wrong.
//!
//! **The output is `UYVY`, and that is a contract rather than a preference.** It is what
//! [`crate::pipeline::CAPTURE_FORMAT`] says, what [`crate::detect`]'s gate compares against, and
//! what [`crate::exposure`] reads luma from. Converting here rather than teaching those two about a
//! second format is the whole point of this module: the detector's gate does not warn and carry on,
//! it returns and takes the thread with it.
//!
//! # `colorimetry=bt601`, which is not optional either
//!
//! `videoconvert` maps the source's negotiated colourimetry and range into the destination's,
//! rather than relabelling bytes. Left unstated it would pick a destination from the source's own
//! metadata, and an MJPEG frame from a UVC camera is usually full-range JFIF — so the Y values
//! arriving at the detector would be a different scale from the ones an ISP emits. The model was
//! trained on the ISP's. Pinning `bt601` makes the conversion explicit and the numbers predictable.
//!
//! # What this deliberately does not do
//!
//! [`crate::pipeline::raise_capture_buffers`] is not called. It exists for rkisp's two-plane `NM12`
//! and the pool depth that costs it a third of its frames; a UVC camera is single-plane and does
//! not have that problem. The cost of skipping it is that `v4l2src` stays on its default buffer
//! depth, which is worth measuring on a camera that drops frames — the numbers to compare against
//! are in that function's doc.
//!
//! No `extra-controls` either. The exposure and gain this daemon writes are rkisp control names
//! (`exposure`, `analogue_gain`) in the sensor's own units; a UVC camera has different names in
//! different units, and passing the wrong one is at best ignored and at worst a negotiation
//! failure. A UVC camera runs its own auto-exposure, and [`crate::exposure`] is not spawned for
//! this source.

use anyhow::{Context, Result, anyhow};
use gstreamer as gst;
use gstreamer::prelude::*;
use robotd_params::CameraFormat;

use crate::pipeline::CAPTURE_FORMAT;

/// What the camera is asked to send, which is the one thing about it that cannot be discovered.
///
/// **Not probed.** Asking the device what it supports and picking the best answer sounds better
/// than being told, but the choice is not a preference — it is a fact about the camera that
/// somebody reads off `v4l2-ctl --list-formats-ext` once, and a silent fallback would make "this
/// camera is running at 5 fps" look like the pipeline's fault.
///
/// Lives in `robotd_params` because it is a config value with a spelling in the file; this is only
/// how GStreamer names the same thing.
fn gst_name(format: CameraFormat) -> Option<&'static str> {
    match format {
        // Not a raw format: it is the *capsule* name, so the capsfilter for it is `image/jpeg`
        // and this table has nothing to say.
        CameraFormat::Mjpeg => None,
        // **`YUY2`, not `YUYV`.** V4L2's `YUYV` and GStreamer's `YUY2` are the same fourcc under
        // two spellings, and this line is the only place in the pipeline where the difference
        // shows. Writing the V4L2 spelling here negotiates nothing and fails at the first buffer.
        CameraFormat::Yuyv => Some("YUY2"),
        CameraFormat::Uyvy => Some("UYVY"),
        CameraFormat::Nv12 => Some("NV12"),
    }
}

/// The capsule name for the format, which is `image/jpeg` for exactly one of them.
fn caps_name(format: CameraFormat) -> &'static str {
    match gst_name(format) {
        Some(_) => "video/x-raw",
        None => "image/jpeg",
    }
}

/// The capture chain for one USB camera, as a bin with a single src pad.
///
/// **Two modes, and they are not the same thing.** `native` is what the camera is asked for and
/// `output` is what leaves the bin; when they differ, `videoscale` and `videorate` stand between
/// them. Keeping them apart is what stops `[media] quality` from being a config value that decides
/// which camera modes exist.
///
/// Both are `(width, height, fps)`.
pub fn source(
    device: &str,
    format: CameraFormat,
    native: (u32, u32, u32),
    output: (u32, u32, u32),
) -> Result<gst::Element> {
    let (native_width, native_height, native_fps) = native;
    let (width, height, fps) = output;

    // **`videorate drop-only=true` drops frames and never makes them.** An output rate above the
    // camera's is not refused by GStreamer — it stamps frames with times they were not captured
    // at, which is the kind of wrong a video looks fine under. `Params::validate` refuses the
    // combination before the daemon starts; this is the same check where the elements are built,
    // so a caller that is not `robotd.toml` cannot get past it either.
    anyhow::ensure!(
        fps <= native_fps,
        "the camera runs at {native_fps} fps and the stream is asked for {fps} — a stream cannot \
         be smoother than the camera feeding it"
    );

    let make = |name: &str| {
        gst::ElementFactory::make(name)
            .build()
            .map_err(|_| anyhow!("no {name} element; a GStreamer package is missing"))
    };

    let src = gst::ElementFactory::make("v4l2src")
        .property("device", device)
        .build()
        .map_err(|_| {
            anyhow!(
                "no v4l2src element; it comes from gstreamer1.0-plugins-good, which \
                 setup-gstreamer.sh installs"
            )
        })?;

    // `field` consumes the builder, so a conditional field is a reassignment rather than a call.
    let mut input = gst::Caps::builder(caps_name(format))
        .field("width", native_width as i32)
        .field("height", native_height as i32)
        .field("framerate", gst::Fraction::new(native_fps as i32, 1));
    if let Some(name) = gst_name(format) {
        input = input.field("format", name);
    }

    let mut elements = vec![src, capsfilter(input.build())?];
    if format == CameraFormat::Mjpeg {
        elements.push(make("jpegdec")?);
    }
    elements.push(make("videoconvert")?);

    // **After `videoconvert` and before the scaling, and that position is load-bearing.** It is
    // what makes the camera's native mode a thing the pipeline actually negotiated rather than a
    // number in a config file, and what makes `videoscale` and `videorate` do their work on the
    // UYVY the rest of the pipeline expects rather than on whatever `jpegdec` emits.
    elements.push(capsfilter(raw_caps(native_width, native_height, native_fps))?);

    // `add-borders`, never a stretch: a 16:10 sensor into a 16:9 stream is a picture that has been
    // squashed, and nothing downstream can tell that from a lens that is wrong.
    let scale = make("videoscale")?;
    scale.set_property("add-borders", true);
    elements.push(scale);

    // Drops only — see the `ensure!` above for why that matters.
    let rate = make("videorate")?;
    rate.set_property("drop-only", true);
    elements.push(rate);

    elements.push(capsfilter(raw_caps(width, height, fps))?);

    let bin = gst::Bin::new();
    bin.add_many(&elements)
        .context("could not add the capture elements to the bin")?;
    gst::Element::link_many(&elements).context(
        "could not link the USB capture chain. A caps failure here means the camera does not \
         produce what [media] camera_format, camera_width, camera_height and camera_fps say it \
         does — check `v4l2-ctl --list-formats-ext`",
    )?;

    // The bin's one visible pad. The last element's src pad is what the rest of the pipeline
    // links against, and the ghost holds the bin's own lifetime to it.
    let last = elements.last().expect("the chain is never empty");
    let target = last
        .static_pad("src")
        .context("the last capture element has no src pad, which cannot happen")?;
    let ghost = gst::GhostPad::with_target(&target)
        .context("could not make a ghost pad for the capture bin")?;
    bin.add_pad(&ghost)
        .context("could not add the ghost pad to the capture bin")?;

    tracing::info!(
        device,
        format = format.label(),
        native = format!("{native_width}x{native_height}@{native_fps}"),
        output = format!("{width}x{height}@{fps}"),
        "usb camera"
    );

    Ok(bin.upcast())
}

/// A capsfilter, which is how every constraint in the chain is expressed.
fn capsfilter(caps: gst::Caps) -> Result<gst::Element> {
    gst::ElementFactory::make("capsfilter")
        .property("caps", &caps)
        .build()
        .map_err(|_| anyhow!("no capsfilter element; gstreamer core is incomplete"))
}

/// What the chain promises the rest of the pipeline, spelled out.
///
/// The first three fields are the same ones [`crate::pipeline::start`] pins on its own capsfilter
/// downstream; `colorimetry` and `pixel-aspect-ratio` are added here because this is the last point
/// that knows where the pixels came from — see the module doc.
fn raw_caps(width: u32, height: u32, fps: u32) -> gst::Caps {
    gst::Caps::builder("video/x-raw")
        .field("format", CAPTURE_FORMAT)
        .field("colorimetry", "bt601")
        .field("width", width as i32)
        .field("height", height as i32)
        .field("pixel-aspect-ratio", gst::Fraction::new(1, 1))
        .field("framerate", gst::Fraction::new(fps as i32, 1))
        .build()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The V4L2 spelling and the GStreamer one differ for exactly one of these, and it is the one
    /// a camera is most likely to offer uncompressed.
    #[test]
    fn yuyv_is_yuy2_to_gstreamer() {
        assert_eq!(gst_name(CameraFormat::Yuyv), Some("YUY2"));
        assert_eq!(gst_name(CameraFormat::Uyvy), Some("UYVY"));
        assert_eq!(gst_name(CameraFormat::Nv12), Some("NV12"));
        // MJPEG is not a raw format, so it has no name in this table — it is the capsule name.
        assert_eq!(gst_name(CameraFormat::Mjpeg), None);
        assert_eq!(caps_name(CameraFormat::Mjpeg), "image/jpeg");
        assert_eq!(caps_name(CameraFormat::Yuyv), "video/x-raw");
    }

    /// Every format in the config has a name here, so `[media] camera_format` cannot name one this
    /// cannot build. A new variant added to `CameraFormat` without a line above fails to compile
    /// rather than at a robot's next boot — the match is exhaustive on purpose.
    #[test]
    fn every_format_maps_to_a_capsule() {
        for format in CameraFormat::ALL {
            assert!(!caps_name(format).is_empty(), "{format:?} has no capsule");
        }
    }
}
