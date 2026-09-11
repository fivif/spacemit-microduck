//! The duck detector on the SpaceMiT NPU, through the vendor's execution provider.
//!
//! **The EP is a vendor blob with a private C entry point**, not one of ONNX Runtime's registered
//! providers, so `ort`'s `ExecutionProvider` list cannot reach it and neither can
//! `with_execution_providers`. What it publishes instead is
//!
//! ```c
//! OrtStatus* OrtSessionOptionsSpaceMITEnvInit(OrtSessionOptions* options,
//!                                            const char* const* provider_options_keys,
//!                                            const char* const* provider_options_values,
//!                                            size_t num_keys);
//! ```
//!
//! declared by the `spacemit_ort_env_c_api.h` the vendor ships. `ort` does hand out the raw
//! `OrtSessionOptions` its builder is holding — [`ort::AsPointer::ptr_mut`] — so the session stays
//! `ort`'s; only the provider registration is ours.
//!
//! **Two `dlopen` flags carry the whole thing.** The EP's remaining undefined symbols are
//! `onnxruntime::…` C++ mangled names that are *not* in its `DT_NEEDED` list; it finds them through
//! the process-global scope. So the same `libonnxruntime.so` that `ort` loads has to be loaded
//! `RTLD_GLOBAL` first — and `libloading::Library::new`, which is what `ort` uses, is
//! `RTLD_LOCAL | RTLD_NOW`. A plain load is not enough, and what it produces is
//! `undefined symbol: _ZN11onnxruntime…` at EP-load time, which does not name the flag. This module
//! therefore loads the Runtime itself, global, by the same path `ort` will use, and holds it open
//! for as long as the EP is.
//!
//! **The EP and the Runtime are a matched pair.** `spacemit-onnxruntime` ships its EP at
//! `ep/libspacemit_ep.so`, beside the `libonnxruntime.so` it was built against. `/usr/lib` has a
//! `libspacemit_ep.so` of its own — version 1, for the 1.18 Runtime that plain `onnxruntime`
//! provides — and the two are not interchangeable. A search that started in `/usr/lib` would find
//! the wrong one on a board that has both, and would then fail somewhere else entirely.
//!
//! **The CPU fallback stays on.** ORT's `session.disable_cpu_ep_fallback` turns "the EP does not
//! claim this node" from a slow path into a failure to load the model at all, and this graph has
//! nodes the EP does not claim. There is a reason nothing below sets it.
//!
//! # The model has to be opset 13 or newer, and the way that fails is the reason this is written
//! down
//!
//! `duck_detect.onnx` as the `duck_detector` release ships it is **opset 12**, in which `Split`
//! carries its sizes as an *attribute*. The EP's shape inference does not carry them through, so
//! its attention block is compiled against the wrong shape for `Split`'s third output:
//!
//! ```text
//! operator compile failed at node (/model.10/m/m.0/attn/Reshape_2)[Reshape],
//! spine graph SpaceMITExecutionProvider_SpineSubgraph_…  error message:
//! The input tensor cannot be reshaped to the requested shape.
//! ```
//!
//! **And that message is not the failure — the failure is that nothing comes back.** It is logged
//! once, and then the process spins at 100% of one core and never returns: ten minutes of it is
//! what it took to find this. A detector that hangs a daemon reads as anything but a shape problem.
//!
//! From **opset 13**, `Split` takes its sizes as an *input* instead of an attribute, the shape
//! propagates, and the same weights compile. The model in `models/` is therefore the opset-17
//! conversion — `onnx.version_converter.convert_version(model, 17)`, which for this graph is
//! **bit-identical** to the opset-12 original: 0.0 maximum absolute difference across all 10 500
//! outputs on 12 frames. The `.rknn` path is unaffected either way; it never reads this file.

use std::ffi::{CStr, c_char};
use std::path::{Path, PathBuf};
use std::ptr;

use anyhow::{Context, Result, anyhow, bail};
use libloading::os::unix::{Library, RTLD_GLOBAL, RTLD_NOW};
use ort::AsPointer;
use ort::session::builder::SessionBuilder;
use ort::sys;

/// The vendor's entry point, transcribed from `spacemit_ort_env_c_api.h`.
type EnvInit = unsafe extern "C" fn(
    options: *mut sys::OrtSessionOptions,
    keys: *const *const c_char,
    values: *const *const c_char,
    num_keys: usize,
) -> *mut sys::OrtStatus;

/// The vendor's execution provider, loaded and ready to attach to a session.
///
/// Moved into [`crate::onnx::Model`] on the way in, and dropped after the session — the EP cannot
/// outlive the model it is registered on, and the Runtime cannot outlive the EP.
pub struct Ep {
    /// The provider itself. Dropped first, and dropped at all only after the session is gone.
    _ep: Library,
    init: EnvInit,
    /// For turning a returned `OrtStatus` into a sentence. Borrowed from `_ort`, which is why
    /// `_ort` is declared last.
    api: *const sys::OrtApi,
    version: String,
    /// The Runtime the EP resolves its `onnxruntime::…` symbols from. Loaded `RTLD_GLOBAL`, and
    /// held open: dropping it would take the global scope away from every later EP.
    _ort: Library,
}

// SAFETY: the same argument as `rknn::Model`'s, and for the same reason — `mediad` runs its
// detector on a thread of its own, so this has to cross a thread boundary or the detector cannot
// be used by the daemon that exists to use it.
//
// `Ep` owns every handle it holds: the two libraries are its own `dlopen`ed copies, and `api`
// points into one of them, so it moves with them. Nothing here is handed out — the only two
// methods are `attach` and `message`, both `&self`, both called from whatever thread owns the
// `Model` that holds this. `Sync` is deliberately **not** claimed: two sessions sharing one
// provider is not something this type was written for, and the compiler should keep saying so.
unsafe impl Send for Ep {}

impl Ep {
    /// Find and load the EP that belongs to this board's ONNX Runtime.
    pub fn load() -> Result<Self> {
        let runtime_path = ort_path();
        let runtime = global(&runtime_path).with_context(|| {
            format!(
                "loading ONNX Runtime from {} — set ORT_DYLIB_PATH to the one this board uses",
                runtime_path.display()
            )
        })?;
        let (api, version) = unsafe { api_and_version(&runtime)? };

        let ep_path = ep_path(&runtime_path).ok_or_else(|| {
            anyhow!(
                "no libspacemit_ep.so to go with {}. The vendor ships it at \
                 <runtime dir>/ep/libspacemit_ep.so; set SPACEMIT_EP_PATH to point at another.",
                runtime_path.display()
            )
        })?;
        let provider = global(&ep_path)
            .with_context(|| format!("loading the SpaceMiT EP from {}", ep_path.display()))?;

        // SAFETY: the symbol is looked up by the name the vendor's header declares, and the
        // signature above is transcribed from it. A missing symbol is an error here rather than a
        // jump into nothing later.
        let init = unsafe {
            *provider
                .get::<EnvInit>(b"OrtSessionOptionsSpaceMITEnvInit\0")
                .context(
                    "libspacemit_ep.so has no OrtSessionOptionsSpaceMITEnvInit — it is probably the \
                     version 1 EP that belongs to the 1.18 Runtime, not this one",
                )?
        };

        Ok(Self {
            _ep: provider,
            init,
            api,
            version,
            _ort: runtime,
        })
    }

    /// Register the EP on a session `ort` is building.
    ///
    /// **No provider options, and that is a choice rather than an omission.** The vendor does
    /// publish `SPACEMIT_EP_INTRA_THREAD_NUM`, `SPACEMIT_EP_ENABLE_DMA` and others, and one of them
    /// may well be worth setting on a board whose other job is a 50 Hz control loop. Which one,
    /// and to what, is a measurement — so this passes none, and a measurement that says the EP is
    /// taking cores is a measurement of the default. Guessing one now would hide that.
    pub(crate) fn attach(&self, builder: &mut SessionBuilder) -> Result<()> {
        // SAFETY: the builder's options outlive the call, and the two option arrays are null with a
        // count of zero, which is the "no options" case the header describes.
        let status = unsafe { (self.init)(builder.ptr_mut(), ptr::null(), ptr::null(), 0) };
        if !status.is_null() {
            bail!("OrtSessionOptionsSpaceMITEnvInit: {}", self.message(status));
        }
        Ok(())
    }

    /// The ONNX Runtime this EP was built against, e.g. `1.24.2+spacemit.a1`.
    pub fn version(&self) -> &str {
        &self.version
    }

    /// The sentence inside an `OrtStatus`, with the status released.
    fn message(&self, status: *mut sys::OrtStatus) -> String {
        // SAFETY: `api` came from `OrtGetApiBase()->GetApi(ORT_API_VERSION)` on the Runtime this
        // type holds open, and `status` is one this type has just been handed.
        unsafe {
            let api = &*self.api;
            let text = (api.GetErrorMessage)(status);
            let text = if text.is_null() {
                "no message".to_owned()
            } else {
                CStr::from_ptr(text).to_string_lossy().into_owned()
            };
            (api.ReleaseStatus)(status);
            text
        }
    }
}

/// `dlopen` with `RTLD_NOW | RTLD_GLOBAL`.
///
/// `RTLD_NOW` for the reason this module exists: with lazy binding, an `onnxruntime::…` symbol the
/// global scope does not have would stay unresolved until the first inference, which is a crash
/// inside the EP rather than an error at load time. `RTLD_GLOBAL` because those symbols are not in
/// the EP's `DT_NEEDED` at all.
fn global(path: &Path) -> Result<Library> {
    // SAFETY: this is a plain `dlopen` of a path this module chose. `Library::open` is unsafe
    // because running a library's initialisers is, and that is exactly what is being asked for.
    unsafe { Library::open(Some(path), RTLD_NOW | RTLD_GLOBAL) }.map_err(|error| anyhow!("{error}"))
}

/// Where ONNX Runtime is, by the same rule `ort` itself uses: `ORT_DYLIB_PATH`, else the soname.
fn ort_path() -> PathBuf {
    std::env::var_os("ORT_DYLIB_PATH")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("libonnxruntime.so"))
}

/// The EP that goes with this Runtime — see the module docs for why the search starts beside it.
fn ep_path(runtime: &Path) -> Option<PathBuf> {
    if let Some(explicit) = std::env::var_os("SPACEMIT_EP_PATH").filter(|value| !value.is_empty()) {
        return Some(PathBuf::from(explicit));
    }

    let mut candidates: Vec<PathBuf> = Vec::new();
    // A bare soname has an empty parent, which would silently become the working directory.
    if let Some(directory) = runtime.parent().filter(|parent| !parent.as_os_str().is_empty()) {
        candidates.push(directory.join("ep/libspacemit_ep.so"));
        candidates.push(directory.join("libspacemit_ep.so"));
    }
    candidates.push(PathBuf::from("/usr/lib/riscv64-linux-gnu/libspacemit_ep.so"));
    candidates.push(PathBuf::from("/usr/lib/aarch64-linux-gnu/libspacemit_ep.so"));
    candidates.push(PathBuf::from("/usr/lib/libspacemit_ep.so"));

    candidates.into_iter().find(|candidate| candidate.exists())
}

/// `OrtGetApiBase()->GetApi(ORT_API_VERSION)`, and the version string beside it.
///
/// This is the same call `ort` makes for itself; it is repeated here for one reason — a `OrtStatus`
/// that comes back from the vendor's entry point is a pointer that only the C API can turn into a
/// sentence, and "Provider options key/value cannot be empty" is worth more than "failed".
///
/// # Safety
///
/// `library` must be a loaded ONNX Runtime, and must stay loaded for as long as the returned
/// pointer is used.
unsafe fn api_and_version(library: &Library) -> Result<(*const sys::OrtApi, String)> {
    let base = unsafe {
        let getter = library
            .get::<unsafe extern "C" fn() -> *const sys::OrtApiBase>(b"OrtGetApiBase\0")
            .context("OrtGetApiBase")?;
        getter()
    };
    if base.is_null() {
        bail!("OrtGetApiBase returned null");
    }

    let api = unsafe { ((*base).GetApi)(sys::ORT_API_VERSION) };
    if api.is_null() {
        bail!(
            "this ONNX Runtime has no API v{}, which is the one `ort` binds",
            sys::ORT_API_VERSION
        );
    }

    let version = unsafe {
        let text = ((*base).GetVersionString)();
        if text.is_null() {
            "unknown".to_owned()
        } else {
            CStr::from_ptr(text).to_string_lossy().into_owned()
        }
    };

    Ok((api, version))
}
