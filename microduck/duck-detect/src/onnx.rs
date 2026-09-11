//! The same detector through ONNX Runtime — on the CPU, or on the SpaceMiT NPU.
//!
//! **Why the CPU version exists at all.** The RK3566 has an NPU, the vendor kernel has the driver —
//! and on this board the device tree ships `npu@fde40000` as `disabled`, with the only overlay
//! Armbian offers being one that disables it further. Enabling it is an overlay and a reboot, which
//! is a decision about somebody's robot rather than a detail of a detector. So the detector runs on
//! four A55 cores until that happens, and moves to the NPU by changing one config value.
//!
//! ONNX Runtime is already on every provisioned board — `setup-board.sh` installs it for robotd's
//! policies — and `ort` dlopens it, so this costs no new dependency on the robot.
//!
//! **On a SpaceMiT board the same graph runs on the NPU instead**, through
//! [`crate::spacemit::Ep`]. It is the same session, the same tensors and the same normalisation:
//! what changes is which provider ONNX Runtime hands the nodes to, so there is one ONNX path here
//! rather than two that would drift.
//!
//! Three ways in, and the difference is only who decides: [`Model::open_preferring_npu`] for a
//! caller that wants the best this board has, [`Model::open_on`] for one that has already loaded
//! an EP, and [`Model::open`] for the CPU explicitly. All three report the outcome in
//! [`Model::runtime`].

use std::path::Path;

use anyhow::{Context, Result, bail};
use ort::session::{Session, builder::GraphOptimizationLevel};
use ort::value::Tensor;

use crate::spacemit;

/// A YOLO detector on ONNX Runtime.
pub struct Model {
    session: Session,
    /// `[height, width, channels]`, as the graph declares it.
    pub input: (usize, usize, usize),
    /// How many floats come back, so the caller can size its own buffer once.
    pub output_len: usize,
    /// What is doing the arithmetic, for the log line that says what was actually used. `"cpu"`,
    /// or the vendor provider with the Runtime it was built against.
    pub runtime: String,
    /// The vendor EP, when one is attached.
    ///
    /// Never read, and held for two reasons: declared after the session so it is dropped after it
    /// — the EP cannot outlive the model it is registered on — and kept at all so the two libraries
    /// underneath it stay loaded for the session's lifetime.
    _ep: Option<spacemit::Ep>,
}

impl Model {
    /// The detector on the CPU.
    pub fn open(path: &Path) -> Result<Self> {
        Self::build(path, None)
    }

    /// The detector on the SpaceMiT NPU.
    ///
    /// `ep` is moved in: it has to outlive the session it registers itself on, which is why this
    /// takes ownership rather than a reference. Load one with [`spacemit::Ep::load`].
    pub fn open_on(path: &Path, ep: spacemit::Ep) -> Result<Self> {
        Self::build(path, Some(ep))
    }

    /// The detector on whatever this board has: the vendor NPU provider when one can be loaded,
    /// the CPU when it cannot.
    ///
    /// **This is the one callers should use**, because the answer is a property of the board rather
    /// than of the caller, and both answers are the same type over the same tensors — see
    /// [`Model::runtime`] for which one it turned out to be. Falling back is worth a log line rather
    /// than a silent default: on a K1 the same graph is 142 ms on the provider and 719 ms on the
    /// cores `robotd`'s control loop is using.
    pub fn open_preferring_npu(path: &Path) -> Result<Self> {
        match spacemit::Ep::load() {
            Ok(ep) => Self::open_on(path, ep),
            Err(error) => {
                tracing::warn!(
                    error = %format!("{error:#}"),
                    "no npu provider for this model; running on the cpu instead"
                );
                Self::open(path)
            }
        }
    }

    fn build(path: &Path, ep: Option<spacemit::Ep>) -> Result<Self> {
        let runtime = match &ep {
            Some(ep) => format!("spacemit ep · onnxruntime {}", ep.version()),
            None => "onnxruntime · cpu".to_owned(),
        };

        let mut builder = Session::builder()
            .context("ort session builder")?
            .with_optimization_level(GraphOptimizationLevel::Level3)
            .context("ort optimisation level")?
            // **Two threads, not four.** The other two belong to `robotd`'s control loop and to
            // GStreamer; a detector that takes the whole SoC to find a duck 3 m away has taken
            // something more important than it gave.
            .with_intra_threads(2)
            .context("ort threads")?;

        // Between the last CPU option and the commit, so nothing ort does afterwards can replace
        // the provider list this appends to.
        if let Some(ep) = &ep {
            ep.attach(&mut builder)?;
        }

        let session = builder
            .commit_from_file(path)
            .with_context(|| format!("cannot load {}", path.display()))?;

        // NCHW, as exported: [1, 3, H, W].
        let shape = session
            .inputs()
            .first()
            .and_then(|input| input.dtype().tensor_shape().map(|dims| dims.to_vec()))
            .unwrap_or_default();
        let input = match shape.as_slice() {
            [_, c, h, w] if *c == 3 => (*h as usize, *w as usize, *c as usize),
            other => bail!("expected a [1, 3, H, W] input, got {other:?}"),
        };

        let output_len = session
            .outputs()
            .first()
            .and_then(|output| output.dtype().tensor_shape().map(|dims| dims.to_vec()))
            .map(|dims| dims.iter().map(|dim| *dim as usize).product())
            .unwrap_or(0);

        Ok(Self {
            session,
            input,
            output_len,
            runtime,
            _ep: ep,
        })
    }

    /// One letterboxed RGB frame in, the raw head out — the same layout the NPU path returns, so
    /// [`crate::decode`] does not care which one produced it.
    pub fn infer(&mut self, frame: &[u8], out: &mut Vec<f32>) -> Result<()> {
        let (height, width, channels) = self.input;
        if frame.len() != height * width * channels {
            bail!(
                "frame is {} bytes, the model wants {}",
                frame.len(),
                height * width * channels
            );
        }

        // HWC bytes to NCHW floats, normalised the way the export expects (0..1). The RKNN runtime
        // does this itself from the mean/std baked into the .rknn; here it is ours to do.
        let mut planar = vec![0.0f32; frame.len()];
        for y in 0..height {
            for x in 0..width {
                for c in 0..channels {
                    planar[c * height * width + y * width + x] =
                        frame[(y * width + x) * channels + c] as f32 / 255.0;
                }
            }
        }

        let tensor = Tensor::from_array((
            [1_usize, channels, height, width],
            planar.into_boxed_slice(),
        ))
        .context("building the input tensor")?;
        let outputs = self
            .session
            .run(ort::inputs!["images" => tensor])
            .context("inference failed")?;
        let (_, data) = outputs[0]
            .try_extract_tensor::<f32>()
            .context("the output is not f32")?;
        out.clear();
        out.extend_from_slice(data);
        Ok(())
    }
}
