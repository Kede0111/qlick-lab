//! Private, serial JSON-lines protocol for the native macOS client.
//! stdout is protocol-only; diagnostics go to stderr. EOF releases all caches.
use anyhow::{Context, Result, bail, ensure};
use serde::Deserialize;
use serde_json::{Value, json};
use spektrafilm_core::{
    image_size,
    params::RuntimeParams,
    pipeline::Pipeline,
    post::{PostParams, PostProcess},
    presets,
    preview::*,
    profile,
};
use spektrafilm_gpu::ComputeBackend;
use spektrafilm_io::{
    border::{BorderOptions, BorderStyle, add_border, extend_for_instagram},
    crop::Crop,
    encoding::Encoding,
    resize::{self, Fit},
};
use spektrafilm_core::stages::scanning::convert_output;
use spektrafilm_math::{colorspace::RgbColourspace, image::ImageBuf};
use std::{
    io::{BufRead, Write},
    path::{Path, PathBuf},
    time::Instant,
};

mod pipelines;
mod proxy;
use proxy::{PROXY_LONG, drop_other_proxy, proxy_file, read_proxy, write_proxy};

/// EditorModel.readPreview rejects larger preview buffers.
const DISPLAY_MAX_DIM: usize = 8192;

#[derive(Deserialize)]
struct Request {
    id: u64,
    #[serde(flatten)]
    command: Command,
}

#[derive(Deserialize)]
#[serde(tag = "command", rename_all = "snake_case")]
enum Command {
    /// The enlarger M/Y filter shifts that print a mid-grey neutral with
    /// these settings (upstream's print balance); image-independent.
    BalancePrint {
        film: String,
        paper: String,
        params: Box<RuntimeParams>,
    },
    Catalog,
    ExportLut {
        film: String,
        paper: String,
        params: Box<RuntimeParams>,
        size: u32,
        output: PathBuf,
    },
    /// Unprocessed, identically framed source for the Windows original view.
    /// This does not replace the retained film render used by Save.
    /// A preset file's text (Python spektrafilm's GUI state) as the stocks
    /// and params to apply over `params`, which keeps what a preset doesn't
    /// carry (see `spektrafilm_core::presets::KEPT`). Without `params`, over
    /// the defaults: enough to check a file.
    PresetImport {
        text: String,
        #[serde(default)]
        params: Option<Box<RuntimeParams>>,
    },
    /// The settings as a preset file's text.
    PresetExport {
        film: String,
        paper: String,
        params: Box<RuntimeParams>,
    },
    Original {
        input: PathBuf,
        params: Box<RuntimeParams>,
        limit_preview: bool,
        preview_path: PathBuf,
    },
    /// The colour space a RAW's camera preview says it's in, for the Mac's
    /// Match camera brightness reference (`spektrafilm_io::brightness::
    /// preview_colour_space`): "srgb", "adobe_rgb", "other" or null.
    PreviewColourSpace {
        input: PathBuf,
    },
    /// A colour-managed camera/original reference for clients without a
    /// native colour-managed extractor. Independent of retained render state.
    BrightnessReference {
        input: PathBuf,
        reference_path: PathBuf,
        expected_width: u32,
        expected_height: u32,
    },
    /// Qlick Lab: reads a RAW again with the Daylight balance, reduced, and fits
    /// the As Shot balance to it as a matrix, so every canvas-size frame after
    /// takes its white balance from a matrix, As Shot included: no slider ever
    /// waits for the RAW to be read again. Answers As Shot's and Auto's
    /// temperature and tint in the engine's own terms, for the sliders.
    PrepareBalance {
        input: PathBuf,
        #[serde(default)]
        source_generation: u64,
        params: Box<RuntimeParams>,
        read_long_side: u32,
    },
    /// Qlick Lab: makes the photograph's proxy (`proxy_file`) if it hasn't one:
    /// a reduced Daylight read and its As Shot fit, which every frame up to
    /// `PROXY_LONG` pixels develops from instead of the RAW.
    MakeProxy {
        input: PathBuf,
        params: Box<RuntimeParams>,
    },
    /// Qlick Lab: the white balance eyedropper: the temperature and tint that make
    /// the photograph neutral at (`x`, `y`), fractions of its width and height
    /// from the top left, uncropped and unturned.
    PickBalance {
        input: PathBuf,
        #[serde(default)]
        source_generation: u64,
        params: Box<RuntimeParams>,
        x: f64,
        y: f64,
    },
    /// Fit the graded exposure to an embedded camera-preview reference without
    /// replacing the current render or changing the decoded source.
    PlaceExposure {
        input: PathBuf,
        source_generation: u64,
        film: String,
        paper: String,
        params: Box<RuntimeParams>,
        reference_path: PathBuf,
    },
    Render {
        input: PathBuf,
        #[serde(default)]
        source_generation: u64,
        film: String,
        paper: String,
        params: Box<RuntimeParams>,
        limit_preview: bool,
        preview_path: PathBuf,
        /// While a slider moves: render at this fraction of the photograph's
        /// size (the canvas resolution), a preview that is never saved.
        #[serde(default)]
        interactive_scale: Option<f32>,
        /// The crop, sent with an Image Size target only: the target describes
        /// the cropped photograph, so its extent sets the working size. The
        /// render itself is never cropped.
        #[serde(default)]
        crop: Option<Crop>,
        /// Qlick Lab: with `interactive_scale`, the long side the frame needs,
        /// so a RAW read for the first time is read only that large.
        #[serde(default)]
        read_long_side: Option<u32>,
        /// Qlick Lab: with a frame at the photograph's size, the part of it the
        /// canvas shows: x, y, width and height as fractions of the frame,
        /// uncropped and unturned. Only that part is developed and written,
        /// the same as that part of the whole frame's render; the answer's
        /// `region` says which pixels of the frame they are. Without it in
        /// the answer the whole frame was developed (params that read the
        /// whole frame), as without it in the request.
        #[serde(default)]
        region: Option<[f64; 4]>,
    },
    /// A small render of the current source with another film/paper or a
    /// preset, for the stock and preset previews. Independent of the main render: it never replaces the
    /// retained output (Save) nor the cached main pipeline.
    Thumbnail {
        input: PathBuf,
        #[serde(default)]
        source_generation: u64,
        film: String,
        paper: String,
        params: Box<RuntimeParams>,
        /// The thumbnail's long edge in pixels.
        long_side: u32,
        preview_path: PathBuf,
        /// The photograph's crop. The whole frame is developed, as for the
        /// main preview, then cut, so grain and halation keep their scale.
        #[serde(default)]
        crop: Option<Crop>,
        /// A preset file's text, applied over `params` as `preset_import`
        /// applies it; its film and paper replace `film` and `paper`.
        #[serde(default)]
        preset: Option<String>,
        /// Read a RAW only as large as this thumbnail needs, where the decoder
        /// can, instead of the whole sensor: far quicker, with the same colours.
        /// The source it leaves is decoded again for anything larger.
        #[serde(default)]
        reduced_decode: bool,
        /// Only decode, as this thumbnail would, and leave what its develop
        /// leaves for a `place_exposure` after: no develop, no preview.
        #[serde(default)]
        decode_only: bool,
        /// Also read `preview_colour_space`'s answer for `input`, while it
        /// decodes, as "preview_colour_space".
        #[serde(default)]
        preview_colour_space: bool,
    },
    /// Frees the thumbnails' caches (the previews were turned off).
    ReleaseThumbnails,
    /// Frees the GPU's kept film sides (ticket 41): the editor closed or
    /// memory is short. Safe at any time; the next render just misses.
    ReleaseFilmCache,
    /// The tone graph's curve: `count` greys through film → print → scan
    /// (`spektrafilm_core::tone_curve`). Image-independent.
    ToneCurve {
        film: String,
        paper: String,
        params: Box<RuntimeParams>,
        #[serde(default)]
        count: Option<usize>,
    },
    Save {
        render_id: u64,
        output: PathBuf,
        #[serde(default)]
        save_options: spektrafilm_io::save::SaveOptions,
        /// Match the displayed preview and CLI: adjust before interpolating a
        /// straightened crop. Older clients retain their existing save order.
        #[serde(default)]
        crop_after_post: bool,
        #[serde(default)]
        border: Option<BorderStyle>,
        #[serde(default)]
        border_options: BorderOptions,
        /// Extend the border to Instagram's 3:4.
        #[serde(default)]
        instagram: bool,
        #[serde(default)]
        crop: Option<Crop>,
        /// Clockwise quarter turns. The preview is never rotated, so turning
        /// the photograph doesn't need a new render.
        #[serde(default)]
        rotate_cw: i32,
        /// Resample the saved file to this edge, after the border.
        #[serde(default)]
        fit: Option<Fit>,
    },
}

#[derive(Default)]
struct Session {
    source_generation: u64,
    backend: Option<Box<dyn ComputeBackend>>,
    source: Option<Source>,
    /// The source resized to the working/preview dimensions, so edits that
    /// don't change the size skip a full-resolution resample.
    scaled: Option<((u32, u32), ImageBuf)>,
    /// The same for interactive renders, kept beside `scaled` so a drag
    /// after a full-size render doesn't resample the source again.
    interactive: Option<((u32, u32), ImageBuf)>,
    /// Prep's output for the photograph-size and the interactive frame (see
    /// `Pipeline::with_prepared_frame`): each slot only ever sees its frame's
    /// one resample of `source` per size, and is replaced with the source.
    prepared_photo: spektrafilm_core::prep::PreparedFrame,
    prepared_interactive: spektrafilm_core::prep::PreparedFrame,
    /// Qlick Lab: the interactive frame of a Daylight read, taken to the
    /// asked white balance by its matrix (`balance_matrix`), so a canvas-size
    /// render follows the temperature and tint without reading the RAW again.
    balanced: Option<(BalanceKey, ImageBuf)>,
    prepared_balanced: spektrafilm_core::prep::PreparedFrame,
    /// Qlick Lab: As Shot as a matrix from a Daylight read (`PrepareBalance`).
    as_shot_fit: Option<AsShotFit>,
    /// Qlick Lab: that Daylight read, under way on a thread of its own while renders go on.
    pending_balance: Option<PendingBalance>,
    /// Qlick Lab: a larger Daylight read than the source (a proxy, or a reduced read the canvas has outgrown),
    /// under way on a thread of its own while frames go on from what there is.
    pending_source: Option<PendingSource>,
    /// The source's auto-exposure metering frame. Every render of the source,
    /// at any preview or working size, meters it, as the exporter does, so
    /// the preview's exposure is the export's.
    metering: Option<ImageBuf>,
    /// Calibrated pipelines for every command that renders (ticket 29).
    pipelines: pipelines::Pipelines,
    output: Option<Rendered>,
    /// The source reduced for stock and preset thumbnails.
    thumbnail_source: Option<((u32, u32), ImageBuf)>,
    /// Reduced sources for preset thumbnails whose RAW white balance isn't
    /// the main source's, most recent last.
    thumbnail_wb_sources: Vec<WbSource>,
    /// The metering frame's film exposure in stops for the tone graph's
    /// histogram, keyed by the source and the render pipeline.
    film_stops: Option<(String, Vec<[f32; 3]>)>,
    /// Counts the sources decoded: with a slot and a size it names a working
    /// frame's pixels for the backend's film-side cache (ticket 41).
    source_loads: u64,
}

/// The source decoded with another RAW white balance, reduced to the largest
/// frame a thumbnail develops (`THUMBNAIL_FRAME_MAX`).
struct WbSource {
    /// Effective (`RawWhiteBalance::effective`).
    wb: spektrafilm_io::RawWhiteBalance,
    colour: spektrafilm_io::InputColour,
    image: ImageBuf,
    /// The auto-exposure metering frame of this decode.
    metering: ImageBuf,
    /// Read reduced, at no more than `THUMBNAIL_FRAME_MAX`.
    reduced: bool,
}

/// Qlick Lab: a region in fractions of a frame as that frame's pixels (x, y,
/// width, height): every pixel it touches, within the frame.
fn frame_window([x, y, width, height]: [f64; 4], (frame_width, frame_height): (u32, u32)) -> [u32; 4] {
    let (w, h) = (f64::from(frame_width), f64::from(frame_height));
    let left = ((x * w).floor() as u32).min(frame_width.saturating_sub(1));
    let top = ((y * h).floor() as u32).min(frame_height.saturating_sub(1));
    let right = (((x + width) * w).ceil() as u32).clamp(left + 1, frame_width.max(left + 1));
    let bottom = (((y + height) * h).ceil() as u32).clamp(top + 1, frame_height.max(top + 1));
    [left, top, right - left, bottom - top]
}

/// The longest frame developed for a cropped thumbnail.
const THUMBNAIL_FRAME_MAX: u32 = 1280;

/// Qlick Lab: the bound for a frame asked larger than Negs's thumbnails (its loupe
/// and Comparaison, up to 4096). Unchanged for every size Negs itself asks.
fn frame_max(long_side: u32) -> u32 {
    THUMBNAIL_FRAME_MAX.max(long_side)
}
/// White balances kept for preset thumbnails (few presets differ).
const THUMBNAIL_WB_SOURCES: usize = 4;

/// The long side a reduced read needs for a thumbnail's frame
/// ([`thumbnail_dimensions`]) without knowing the photograph's size: the crop's
/// shorter fraction bounds how much larger than `long_side` the frame can be.
fn reduced_read_side(long_side: u32, crop: Option<&Crop>) -> u32 {
    let fraction = crop.map_or(1.0, |c| c.width.min(c.height)).max(1e-6);
    ((long_side as f64 / fraction).ceil().min(frame_max(long_side) as f64) as u32).max(long_side)
}

/// `dimensions` within `image`: a reduced read can round a pixel under the
/// frame its full size calls for.
fn within((width, height): (u32, u32), image: &ImageBuf) -> (u32, u32) {
    (width.min(image.width), height.min(image.height))
}

/// The frame developed for a thumbnail: large enough that the crop fills
/// `long_side`, within a bound (a tight crop then gets fewer pixels).
fn thumbnail_dimensions((width, height): (u32, u32), long_side: u32, crop: Option<&Crop>) -> (u32, u32) {
    let (fraction_w, fraction_h) = crop.map_or((1.0, 1.0), |c| (c.width, c.height));
    let cropped_long = (width as f64 * fraction_w).max(height as f64 * fraction_h).max(1.0);
    let frame_long = (width.max(height) as f64 * long_side as f64 / cropped_long).min(frame_max(long_side) as f64);
    let scale = frame_long / width.max(height) as f64;
    if scale >= 1.0 {
        (width, height)
    } else {
        (((width as f64 * scale).round() as u32).max(1), ((height as f64 * scale).round() as u32).max(1))
    }
}

/// Qlick Lab: what a balanced interactive frame was made of: its size, the
/// temperature and tint (bits), and the decode it came from.
type BalanceKey = ((u32, u32), u64, u64, u64);

/// A balanced frame's name for the film-side cache: its pixels change with the balance.
fn balance_name(key: &BalanceKey) -> u64 {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    key.hash(&mut hasher);
    hasher.finish() & (u64::MAX >> 1)
}

/// Qlick Lab: `matrix` over every pixel of a linear RGB frame.
fn apply_matrix(image: &mut ImageBuf, matrix: [[f64; 3]; 3]) {
    use rayon::prelude::*;
    image.data.par_chunks_exact_mut(3).for_each(|p| {
        let v = [p[0] as f64, p[1] as f64, p[2] as f64];
        for (out, row) in p.iter_mut().zip(matrix) {
            *out = (row[0] * v[0] + row[1] * v[1] + row[2] * v[2]) as spektrafilm_math::Scalar;
        }
    });
}

/// The fit of As Shot to a Daylight read, from their metering frames: the matrix, As Shot's temperature and tint,
/// and Auto's.
type BalanceFit = ([[f64; 3]; 3], (f64, f64), Option<(f64, f64)>);

fn fit_balance(daylight_metering: &ImageBuf, as_shot_metering: &ImageBuf) -> Option<BalanceFit> {
    // Reads at different sizes can round their metering frames a pixel apart.
    let resized;
    let daylight_metering = if (daylight_metering.width, daylight_metering.height) != (as_shot_metering.width, as_shot_metering.height) {
        resized = spektrafilm_core::preview::downsample_area(daylight_metering, (as_shot_metering.width, as_shot_metering.height));
        &resized
    } else {
        daylight_metering
    };
    let pairs = fit_pixels(daylight_metering, as_shot_metering);
    let (matrix, weights) = fit_matrix(&pairs)?;
    let as_shot = search_balance(|m| {
        let mut cost = 0.0;
        for r in 0..3 {
            for i in 0..3 {
                for j in 0..3 {
                    cost += (m[r][i] - matrix[r][i]) * weights[i][j] * (m[r][j] - matrix[r][j]);
                }
            }
        }
        cost
    })?;
    // Auto: the middle tones, averaged in logarithms, made neutral.
    let mut sum = [0.0f64; 3];
    for (d, _) in &pairs {
        for c in 0..3 {
            sum[c] += d[c].ln();
        }
    }
    let count = pairs.len() as f64;
    let mean = [(sum[0] / count).exp(), (sum[1] / count).exp(), (sum[2] / count).exp()];
    let auto = search_balance(|m| {
        let out: Vec<f64> = (0..3).map(|r| (m[r][0] * mean[0] + m[r][1] * mean[1] + m[r][2] * mean[2]).max(1e-9)).collect();
        (out[0] / out[1]).ln().powi(2) + (out[2] / out[1]).ln().powi(2)
    });
    Some((matrix, as_shot, auto))
}

/// Qlick Lab: As Shot, fitted as a matrix from a Daylight read of the same RAW.
#[derive(Clone)]
struct AsShotFit {
    path: PathBuf,
    generation: u64,
    lens: spektrafilm_io::LensCorrection,
    matrix: [[f64; 3]; 3],
    as_shot: (f64, f64),
    auto: Option<(f64, f64)>,
}

/// Qlick Lab: a Daylight read on a thread of its own, and what it's for.
struct PendingBalance {
    path: PathBuf,
    generation: u64,
    lens: spektrafilm_io::LensCorrection,
    interpretation: spektrafilm_io::InputInterpretation,
    limit: u32,
    as_shot_metering: ImageBuf,
    read: std::thread::JoinHandle<Result<(spektrafilm_io::LoadedImage, ImageBuf)>>,
}

/// Qlick Lab: a larger Daylight read on a thread of its own, to take the source's place once it's in.
struct PendingSource {
    path: PathBuf,
    generation: u64,
    lens: spektrafilm_io::LensCorrection,
    interpretation: spektrafilm_io::InputInterpretation,
    /// The long side asked for; 0 is the whole photograph.
    limit: u32,
    read: std::thread::JoinHandle<Result<(spektrafilm_io::LoadedImage, ImageBuf)>>,
}

impl PendingSource {
    /// Whether this read is `input`'s, at least `limit` large.
    fn serves(&self, input: &Path, generation: u64, lens: spektrafilm_io::LensCorrection, limit: u32) -> bool {
        self.path == input && self.generation == generation && self.lens == lens && (self.limit == 0 || (limit != 0 && limit <= self.limit))
    }
}

/// Pixels of a metering frame worth fitting by: neither near black nor near clipping.
fn fit_pixels(daylight: &ImageBuf, as_shot: &ImageBuf) -> Vec<([f64; 3], [f64; 3])> {
    if (daylight.width, daylight.height) != (as_shot.width, as_shot.height) {
        return Vec::new();
    }
    let peak = daylight.data.iter().fold(0.0f64, |m, &v| m.max(v as f64)).max(1e-6);
    daylight
        .data
        .chunks_exact(3)
        .zip(as_shot.data.chunks_exact(3))
        .filter_map(|(d, a)| {
            let d = [d[0] as f64, d[1] as f64, d[2] as f64];
            let a = [a[0] as f64, a[1] as f64, a[2] as f64];
            let low = d.iter().chain(a.iter()).all(|&v| v > peak * 0.002);
            let high = d.iter().chain(a.iter()).all(|&v| v < peak * 0.92);
            (low && high).then_some((d, a))
        })
        .collect()
}

/// The 3 × 3 matrix taking `daylight` pixels to `as_shot` ones, by least squares.
fn fit_matrix(pairs: &[([f64; 3], [f64; 3])]) -> Option<([[f64; 3]; 3], [[f64; 3]; 3])> {
    if pairs.len() < 64 {
        return None;
    }
    let mut dtd = [[0.0; 3]; 3];
    let mut dta = [[0.0; 3]; 3];
    for (d, a) in pairs {
        for i in 0..3 {
            for j in 0..3 {
                dtd[i][j] += d[i] * d[j];
                dta[i][j] += d[i] * a[j];
            }
        }
    }
    let inverse = invert3(dtd)?;
    // Row r of M: (DᵀD)⁻¹ · Dᵀ a_r.
    let mut m = [[0.0; 3]; 3];
    for r in 0..3 {
        for c in 0..3 {
            m[r][c] = (0..3).map(|k| inverse[c][k] * dta[k][r]).sum();
        }
    }
    Some((m, dtd))
}

fn invert3(m: [[f64; 3]; 3]) -> Option<[[f64; 3]; 3]> {
    let det = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
        + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
    if !det.is_finite() || det.abs() < 1e-18 {
        return None;
    }
    let c = |a: usize, b: usize, x: usize, y: usize| m[a][b] * m[x][y];
    Some([
        [(c(1, 1, 2, 2) - c(1, 2, 2, 1)) / det, (c(0, 2, 2, 1) - c(0, 1, 2, 2)) / det, (c(0, 1, 1, 2) - c(0, 2, 1, 1)) / det],
        [(c(1, 2, 2, 0) - c(1, 0, 2, 2)) / det, (c(0, 0, 2, 2) - c(0, 2, 2, 0)) / det, (c(0, 2, 1, 0) - c(0, 0, 1, 2)) / det],
        [(c(1, 0, 2, 1) - c(1, 1, 2, 0)) / det, (c(0, 1, 2, 0) - c(0, 0, 2, 1)) / det, (c(0, 0, 1, 1) - c(0, 1, 1, 0)) / det],
    ])
}

fn custom_matrix(temperature: f64, tint: f64) -> Option<[[f64; 3]; 3]> {
    spektrafilm_io::daylight_adjustment(spektrafilm_io::RawWhiteBalance {
        mode: spektrafilm_io::RawWhiteBalanceMode::Custom,
        temperature,
        tint,
    })
}

/// The temperature and tint whose matrix is nearest `cost`'s minimum: a coarse search over the whole range, in
/// even steps of mired and of the tint's logarithm, then finer ones round the best.
fn search_balance(cost: impl Fn(&[[f64; 3]; 3]) -> f64) -> Option<(f64, f64)> {
    let (mut best, mut best_cost) = (None, f64::INFINITY);
    let try_pair = |mired: f64, log_tint: f64, best: &mut Option<(f64, f64)>, best_cost: &mut f64| {
        let (temperature, tint) = (1e6 / mired, log_tint.exp2());
        if !(1667.0..=25000.0).contains(&temperature) || !(0.05..=4.0).contains(&tint) {
            return;
        }
        if let Some(matrix) = custom_matrix(temperature, tint) {
            let c = cost(&matrix);
            if c < *best_cost {
                *best_cost = c;
                *best = Some((mired, log_tint));
            }
        }
    };
    // 40 to 600 mired (25 000 to 1 667 K); tint ×1/4 to ×4.
    for i in 0..=28 {
        for j in 0..=12 {
            try_pair(40.0 + i as f64 * 20.0, -2.0 + j as f64 / 3.0, &mut best, &mut best_cost);
        }
    }
    let (mut mired, mut log_tint) = best?;
    let (mut step_m, mut step_t) = (20.0, 1.0 / 3.0);
    for _ in 0..9 {
        step_m /= 2.5;
        step_t /= 2.5;
        for i in -3..=3 {
            for j in -3..=3 {
                try_pair(mired + i as f64 * step_m, log_tint + j as f64 * step_t, &mut best, &mut best_cost);
            }
        }
        (mired, log_tint) = best?;
    }
    Some((1e6 / mired, log_tint.exp2()))
}

/// Qlick Lab: a monochrome sensor's frame, which no white balance changes.
fn is_grey(image: &ImageBuf) -> bool {
    image.data.chunks_exact(3).step_by(7).take(20_000).all(|p| p[0] == p[1] && p[1] == p[2])
}

/// The decoded input, and what it was decoded with: a RAW's white balance
/// and a non-RAW file's interpretation each need a new decode.
struct Source {
    path: PathBuf,
    /// The photograph's whole size; `image`'s unless the read was reduced.
    full: (u32, u32),
    /// The long side a reduced read was asked for; None when it is whole.
    reduced_to: Option<u32>,
    wb: spektrafilm_io::RawWhiteBalance,
    lens: spektrafilm_io::LensCorrection,
    lens_correction_supported: bool,
    interpretation: spektrafilm_io::InputInterpretation,
    colour: spektrafilm_io::InputColour,
    image: ImageBuf,
}

impl Source {
    fn current(
        &self,
        path: &Path,
        wb: spektrafilm_io::RawWhiteBalance,
        lens: spektrafilm_io::LensCorrection,
        interpretation: &spektrafilm_io::InputInterpretation,
    ) -> bool {
        self.path == path
            && if spektrafilm_io::is_raw(path) {
                // Qlick Lab: a preset's unused temperature and tint read the same.
                self.wb.effective() == wb.effective() && self.lens == lens
            } else {
                &self.interpretation == interpretation
            }
    }

    /// Large enough for a read limited to `max_long_side` (0 is whole).
    fn covers(&self, max_long_side: u32) -> bool {
        self.reduced_to.is_none_or(|read| max_long_side != 0 && max_long_side <= read)
    }
}

/// The last render. `image` is the scan before the post adjustments, so a
/// post-only edit reuses it; `key` is everything else the render depended on.
struct Rendered {
    id: u64,
    key: Value,
    /// The response to the render, reused when only the post adjustments change.
    response: Value,
    source: PathBuf,
    film: String,
    /// The render's output space and encoding: the preview space. Post, the
    /// border and resizing work in it; a save to another space converts.
    encoding: Encoding,
    post: PostParams,
    image: ImageBuf,
}

fn catalog(data: &Path) -> Result<Value> {
    let mut stocks = Vec::new();
    for entry in std::fs::read_dir(data.join("profiles"))? {
        let path = entry?.path();
        if path.extension().and_then(|x| x.to_str()) != Some("json") {
            continue;
        }
        stocks.push(path.file_stem().unwrap().to_string_lossy().into_owned());
    }
    let mut catalog = spektrafilm_core::catalog::catalog(data, stocks)?;
    ensure!(
        !catalog["profiles"].as_array().is_some_and(Vec::is_empty),
        "No profiles found in {}",
        data.display()
    );
    catalog["protocol"] = json!(1);
    catalog["capabilities"] = json!({"save_options": true, "crop_after_post": true, "color_space": true, "presets": true, "input_interpretation": true, "preview_color_space": true, "tone_curve": true, "place_exposure": true, "brightness_reference": true});
    // What a preset leaves as it is: a preset's thumbnail changes only with these.
    catalog["preset_kept"] = json!(presets::KEPT);
    Ok(catalog)
}

/// `preview_colour_space`'s answer for `input`: "srgb", "adobe_rgb", "other" or None.
fn declared_preview_colour_space(input: &Path) -> Result<Option<&'static str>> {
    use spektrafilm_io::brightness::{Declared, preview_colour_space};
    let file = std::fs::read(input).with_context(|| format!("Couldn't read {}", input.display()))?;
    Ok(preview_colour_space(&file).map(|declared| match declared {
        Declared::Srgb => "srgb",
        Declared::AdobeRgb => "adobe_rgb",
        Declared::Other => "other",
    }))
}

impl Session {
    /// Decodes `input` unless the session already holds it with these
    /// settings, and at least `max_long_side` large (0 is whole: see
    /// [`spektrafilm_io::load_image_colour_limited`]).
    /// Qlick Lab: once the Daylight read is in (or, with `wait`, once it comes), fits As Shot to it and, while the
    /// source is still the As Shot read it was made for, takes its place: the frames after are a matrix away
    /// from any white balance, As Shot included, and look the same.
    fn take_balance(&mut self, wait: bool) {
        let Some(pending) = self.pending_balance.as_ref() else { return };
        if !wait && !pending.read.is_finished() {
            return;
        }
        let pending = self.pending_balance.take().unwrap();
        let log = std::env::var_os("QLICK_RENDER_LOG").is_some();
        let Ok(Ok((loaded, daylight_metering))) = pending.read.join() else {
            if log {
                eprintln!("helper prepare_balance: the Daylight read failed");
            }
            return;
        };
        let Some((matrix, as_shot, auto)) = fit_balance(&daylight_metering, &pending.as_shot_metering) else { return };
        if log {
            eprintln!("helper prepare_balance: as shot {as_shot:?}, auto {auto:?}");
        }
        // Kept as the photograph's proxy, for the next time it opens.
        if let Some(file) = proxy_file(&pending.path, pending.lens).filter(|f| !f.exists()) {
            let (image, full, colour, supported) = (loaded.image.clone(), loaded.full_size, loaded.colour.clone(), loaded.lens_correction_supported);
            let (path, lens_enabled) = (pending.path.clone(), pending.lens.enabled);
            std::thread::spawn(move || {
                if let Err(error) = write_proxy(&file, &image, full, &colour, supported, matrix, as_shot, auto) {
                    eprintln!("proxy {}: {error}", file.display());
                } else {
                    drop_other_proxy(&path, lens_enabled);
                }
            });
        }
        let as_shot_wb = spektrafilm_io::RawWhiteBalance::default();
        let installs = self.source_generation == pending.generation
            && self.source.as_ref().is_some_and(|s| s.current(&pending.path, as_shot_wb, pending.lens, &pending.interpretation));
        self.as_shot_fit = Some(AsShotFit { path: pending.path.clone(), generation: pending.generation, lens: pending.lens, matrix, as_shot, auto });
        if !installs {
            return;
        }
        let reduced = loaded.full_size != (loaded.image.width, loaded.image.height);
        self.install_daylight(
            pending.path,
            pending.generation,
            pending.lens,
            pending.interpretation,
            loaded.image,
            loaded.full_size,
            reduced.then_some(pending.limit),
            loaded.colour,
            loaded.lens_correction_supported,
            daylight_metering,
        );
    }

    /// Qlick Lab: the larger read asked for by a frame that showed from a smaller source (`pending_source`), once
    /// it's in: it takes the source's place if the photograph is still the one open, read the same way.
    fn take_refined(&mut self) {
        if !self.pending_source.as_ref().is_some_and(|pending| pending.read.is_finished()) {
            return;
        }
        let pending = self.pending_source.take().unwrap();
        let Ok(Ok((loaded, metering))) = pending.read.join() else {
            if std::env::var_os("QLICK_RENDER_LOG").is_some() {
                eprintln!("helper refine: the larger read failed");
            }
            return;
        };
        let daylight = spektrafilm_io::RawWhiteBalance { mode: spektrafilm_io::RawWhiteBalanceMode::Daylight, ..Default::default() };
        let smaller = self.source_generation == pending.generation
            && self.source.as_ref().is_some_and(|s| {
                s.current(&pending.path, daylight, pending.lens, &pending.interpretation)
                    && s.image.width.max(s.image.height) < loaded.image.width.max(loaded.image.height)
            });
        if !smaller {
            return;
        }
        if std::env::var_os("QLICK_RENDER_LOG").is_some() {
            eprintln!("helper refine: {}×{} takes the source's place", loaded.image.width, loaded.image.height);
        }
        let reduced = loaded.full_size != (loaded.image.width, loaded.image.height);
        self.install_daylight(
            pending.path,
            pending.generation,
            pending.lens,
            pending.interpretation,
            loaded.image,
            loaded.full_size,
            reduced.then_some(pending.limit),
            loaded.colour,
            loaded.lens_correction_supported,
            metering,
        );
    }

    /// Qlick Lab: a Daylight read becomes the source, with its caches cleared as a new read clears them.
    #[allow(clippy::too_many_arguments)]
    fn install_daylight(
        &mut self,
        path: PathBuf,
        generation: u64,
        lens: spektrafilm_io::LensCorrection,
        interpretation: spektrafilm_io::InputInterpretation,
        image: ImageBuf,
        full: (u32, u32),
        reduced_to: Option<u32>,
        colour: spektrafilm_io::InputColour,
        lens_correction_supported: bool,
        metering: ImageBuf,
    ) {
        self.source = None;
        self.scaled = None;
        self.interactive = None;
        self.prepared_photo = Default::default();
        self.prepared_interactive = Default::default();
        self.balanced = None;
        self.prepared_balanced = Default::default();
        self.thumbnail_source = None;
        self.thumbnail_wb_sources = Vec::new();
        self.film_stops = None;
        self.source_loads += 1;
        if let Some(backend) = &self.backend {
            backend.release_film_cache();
        }
        let daylight = spektrafilm_io::RawWhiteBalance { mode: spektrafilm_io::RawWhiteBalanceMode::Daylight, ..Default::default() };
        self.source = Some(Source { path, full, reduced_to, wb: daylight, lens, lens_correction_supported, interpretation, colour, image });
        self.metering = Some(metering);
        self.source_generation = generation;
    }

    /// Qlick Lab: a photograph opened (a new generation) whose proxy is on disk takes it as its source at once,
    /// with its As Shot fit: no RAW is read for anything up to `PROXY_LONG` pixels. True if it did.
    fn adopt_proxy(
        &mut self,
        input: &Path,
        generation: u64,
        lens: spektrafilm_io::LensCorrection,
        interpretation: &spektrafilm_io::InputInterpretation,
    ) -> bool {
        if self.source_generation == generation && self.source.as_ref().is_some_and(|s| s.path == input && s.lens == lens) {
            return false;
        }
        let Some(file) = proxy_file(input, lens) else { return false };
        let started = std::time::Instant::now();
        let Ok(proxy) = read_proxy(&file) else { return false };
        // Its last use, so the app removes the least recently used first.
        if let Ok(handle) = std::fs::File::options().write(true).open(&file) {
            let _ = handle.set_modified(std::time::SystemTime::now());
        }
        self.pending_balance = None;
        let metering = spektrafilm_core::stages::filming::metering_preview(&proxy.image);
        let reduced = proxy.full != (proxy.image.width, proxy.image.height);
        let long = proxy.image.width.max(proxy.image.height);
        self.as_shot_fit = Some(AsShotFit {
            path: input.to_path_buf(), generation, lens, matrix: proxy.matrix, as_shot: proxy.as_shot, auto: proxy.auto,
        });
        self.install_daylight(
            input.to_path_buf(),
            generation,
            lens,
            interpretation.clone(),
            proxy.image,
            proxy.full,
            reduced.then_some(long),
            proxy.colour,
            proxy.lens_supported,
            metering,
        );
        if std::env::var_os("QLICK_RENDER_LOG").is_some() {
            eprintln!("helper proxy: {} read in {:.0} ms", input.display(), started.elapsed().as_secs_f64() * 1000.0);
        }
        true
    }

    /// Qlick Lab: As Shot's matrix for this source, if `PrepareBalance` fitted it.
    fn as_shot_matrix(&self, input: &Path, generation: u64, lens: spektrafilm_io::LensCorrection) -> Option<[[f64; 3]; 3]> {
        self.as_shot_fit
            .as_ref()
            .filter(|fit| fit.path == input && fit.generation == generation && fit.lens == lens)
            .map(|fit| fit.matrix)
    }

    fn load_source(
        &mut self,
        input: &Path,
        source_generation: u64,
        wb: spektrafilm_io::RawWhiteBalance,
        lens: spektrafilm_io::LensCorrection,
        interpretation: spektrafilm_io::InputInterpretation,
        max_long_side: u32,
    ) -> Result<()> {
        let reload = self.source_generation != source_generation
            || self.source.as_ref().is_none_or(|source| {
                !source.current(input, wb, lens, &interpretation) || !source.covers(max_long_side)
            });
        if reload {
            // Qlick Lab: a Daylight read under way for this photograph is what a balanced frame wants: wait for it
            // rather than read the RAW twice at once.
            if self.pending_balance.as_ref().is_some_and(|p| p.path == input && p.generation == source_generation) {
                self.take_balance(true);
                let still = self.source_generation != source_generation
                    || self.source.as_ref().is_none_or(|source| {
                        !source.current(input, wb, lens, &interpretation) || !source.covers(max_long_side)
                    });
                if !still {
                    return Ok(());
                }
            }
            // Release the last source's caches before decoding the next.
            self.source = None;
            self.scaled = None;
            self.interactive = None;
            self.prepared_photo = Default::default();
            self.prepared_interactive = Default::default();
            self.balanced = None;
            self.prepared_balanced = Default::default();
            self.metering = None;
            self.thumbnail_source = None;
            self.thumbnail_wb_sources = Vec::new();
            self.film_stops = None;
            self.source_loads += 1;
            if let Some(backend) = &self.backend {
                backend.release_film_cache();
            }
            let loaded = spektrafilm_io::load_image_colour_limited(
                input,
                spektrafilm_io::Formats::Any,
                wb,
                lens,
                &interpretation,
                max_long_side,
            )?;
            let reduced = loaded.full_size != (loaded.image.width, loaded.image.height);
            self.source = Some(Source {
                path: input.to_path_buf(),
                full: loaded.full_size,
                reduced_to: reduced.then_some(max_long_side),
                wb,
                lens,
                lens_correction_supported: loaded.lens_correction_supported,
                interpretation,
                colour: loaded.colour,
                image: loaded.image,
            });
            self.source_generation = source_generation;
        }
        Ok(())
    }

    fn thumbnail(
        &mut self,
        input: PathBuf,
        source_generation: u64,
        mut film: String,
        mut paper: String,
        mut params: Box<RuntimeParams>,
        long_side: u32,
        preview_path: PathBuf,
        crop: Option<Crop>,
        preset: Option<String>,
        reduced_decode: bool,
        decode_only: bool,
        colour_space: bool,
        data: &Path,
    ) -> Result<Value> {
        let started = Instant::now();
        // Qlick Lab: up to 4096 (Negs stops at 1024). Its loupe and its
        // Comparaison develop a photograph at the size it's looked at, with
        // this same command, so they show what the thumbnail and the export do.
        ensure!((16..=4096).contains(&long_side), "Invalid thumbnail size");
        let preset_applied = preset.is_some();
        if let Some(text) = preset {
            let preset = presets::import(&text, data).map_err(anyhow::Error::msg)?;
            params = Box::new(presets::apply(&preset.params, &params));
            (film, paper) = (preset.film, preset.paper);
        }
        if let Some(crop) = &crop {
            crop.validate()?;
        }
        ensure!(
            RgbColourspace::find(&params.io.output_color_space).is_some(),
            "Unknown output colour space: {}",
            params.io.output_color_space
        );
        params.io.raw_white_balance.validate()?;
        params.settings.serial_grain = false;
        let post = std::mem::take(&mut params.post);
        let interpretation = params.io.input_interpretation.clone();
        interpretation.validate()?;
        let (wb, lens) = (params.io.raw_white_balance, params.io.lens_correction);
        // Qlick Lab: the photograph's proxy, if it has one, rather than its RAW (a whole read excepted).
        if reduced_decode || decode_only {
            self.adopt_proxy(&input, source_generation, lens, &interpretation);
        }
        // A preset whose RAW white balance isn't the photograph's needs a
        // decode of its own. It gets a reduced copy here, so the main render
        // keeps its decoded source. (A preset keeps the lens correction and
        // the interpretation, so only the white balance can differ.)
        // Qlick Lab: not while the source is a Daylight read: a matrix takes it to the preset's balance.
        let daylight_read = self.source_generation == source_generation
            && self.source.as_ref().is_some_and(|s| {
                s.path == input && s.lens == lens && s.wb.effective().mode == spektrafilm_io::RawWhiteBalanceMode::Daylight
            });
        let matrix_reaches = spektrafilm_io::daylight_adjustment(wb.effective()).is_some()
            || (wb.effective().mode == spektrafilm_io::RawWhiteBalanceMode::AsShot
                && self.as_shot_matrix(&input, source_generation, lens).is_some());
        let own_decode = preset_applied
            && spektrafilm_io::is_raw(&input)
            && self.source_generation == source_generation
            && !(daylight_read && matrix_reaches)
            && self.source.as_ref().is_some_and(|s| s.path == input && s.wb.effective() != wb.effective());
        ensure!(!decode_only || !preset_applied, "A preset's thumbnail can't be decoded alone");
        // Qlick Lab: while the source is a Daylight read kept for the canvas's
        // frames, this takes its white balance from the same matrix instead of
        // reading the RAW again with it (and the canvas reading it back after).
        let daylight = spektrafilm_io::RawWhiteBalance { mode: spektrafilm_io::RawWhiteBalanceMode::Daylight, ..Default::default() };
        let mut balance = (!own_decode
            && spektrafilm_io::is_raw(&input)
            && self.source_generation == source_generation
            && self.source.as_ref().is_some_and(|s| s.current(&input, daylight, lens, &interpretation) && !s.current(&input, wb, lens, &interpretation)))
            .then(|| {
                spektrafilm_io::daylight_adjustment(wb.effective()).or_else(|| {
                    (wb.effective().mode == spektrafilm_io::RawWhiteBalanceMode::AsShot)
                        .then(|| self.as_shot_matrix(&input, source_generation, lens))
                        .flatten()
                })
            })
            .flatten();
        let read_wb = if balance.is_some() { daylight } else { wb };
        // The camera preview's colour space beside the decode, which takes
        // far longer: the match needs both.
        let declared = std::thread::scope(|scope| -> Result<Option<Option<&'static str>>> {
            let declared = colour_space.then(|| scope.spawn(|| declared_preview_colour_space(&input)));
            if !own_decode {
                let limit = if reduced_decode { reduced_read_side(long_side, crop.as_ref()) } else { 0 };
                self.load_source(&input, source_generation, read_wb, lens, interpretation.clone(), limit)?;
            }
            declared.map(|thread| thread.join().map_err(|_| anyhow::anyhow!("Reading the preview's colour space failed"))?).transpose()
        })?;
        let decoded = started.elapsed();
        let Source { full, reduced_to, .. } = self.source.as_ref().unwrap();
        let (full, mut reduced) = (*full, reduced_to.is_some());
        // The thumbnail is the whole frame; Image Size describes the export.
        image_size::clear(&mut params);
        let dimensions = thumbnail_dimensions(full, long_side, crop.as_ref());
        let (working, metering) = if own_decode {
            let found = self.thumbnail_wb_sources.iter().position(|s| s.wb == wb.effective() && s.reduced == reduced_decode);
            let index = match found {
                Some(index) => index,
                None => {
                    let limit = if reduced_decode { THUMBNAIL_FRAME_MAX } else { 0 };
                    let loaded = spektrafilm_io::load_image_colour_limited(
                        &input, spektrafilm_io::Formats::Any, wb, lens, &interpretation, limit,
                    )?;
                    let metering = spektrafilm_core::stages::filming::metering_preview(&loaded.image);
                    // The largest frame any thumbnail develops, so a new crop
                    // reduces this copy instead of decoding again.
                    let largest = within(thumbnail_dimensions(full, THUMBNAIL_FRAME_MAX, None), &loaded.image);
                    let image = if largest == (loaded.image.width, loaded.image.height) {
                        loaded.image
                    } else {
                        downsample_area(&loaded.image, largest)
                    };
                    if self.thumbnail_wb_sources.len() >= THUMBNAIL_WB_SOURCES {
                        self.thumbnail_wb_sources.remove(0);
                    }
                    self.thumbnail_wb_sources.push(WbSource {
                        wb: wb.effective(), colour: loaded.colour, image, metering, reduced: reduced_decode,
                    });
                    self.thumbnail_wb_sources.len() - 1
                }
            };
            let entry = self.thumbnail_wb_sources.remove(index);
            params.io.apply_input_colour(&entry.colour);
            reduced = entry.reduced;
            let dimensions = within(dimensions, &entry.image);
            let working = if dimensions == (entry.image.width, entry.image.height) {
                entry.image.clone()
            } else {
                downsample_area(&entry.image, dimensions)
            };
            let metering = Some(entry.metering.clone());
            self.thumbnail_wb_sources.push(entry);
            (working, metering)
        } else {
            let Source { image: source, colour, .. } = self.source.as_ref().unwrap();
            params.io.apply_input_colour(colour);
            if (params.camera.auto_exposure || balance.is_some()) && self.metering.is_none() {
                self.metering = Some(spektrafilm_core::stages::filming::metering_preview(source));
            }
            if balance.is_some() && self.metering.as_ref().is_some_and(is_grey) {
                balance = None;
            }
            // A decode alone develops nothing, so it has no frame to shrink.
            let mut working = if decode_only {
                ImageBuf::from_data(1, 1, vec![Default::default(); 3])
            } else {
                let dimensions = within(dimensions, source);
                working_source(source, &mut self.thumbnail_source, dimensions, downsample_area).clone()
            };
            let mut metering = self.metering.clone().filter(|_| params.camera.auto_exposure || balance.is_some());
            if let Some(matrix) = balance {
                apply_matrix(&mut working, matrix);
                if let Some(frame) = metering.as_mut() {
                    apply_matrix(frame, matrix);
                }
            }
            (working, metering)
        };
        let resampled = started.elapsed();
        let key = preview_pipeline_cache_key(&film, &paper, &params);
        let (calibrated, cached) =
            self.pipelines.get_or_build(&key, false, || build_pipeline(data, &film, &paper, &params))?;
        let mut pipeline = calibrated.clone().with_params((*params).clone());
        if let Some(metering) = metering {
            pipeline = pipeline.with_metering_preview(metering);
        }
        let built = started.elapsed();
        let ms = |d: std::time::Duration| d.as_secs_f64() * 1000.0;
        if decode_only {
            return Ok(json!({
                "source_width": full.0, "source_height": full.1, "reduced_decode": reduced,
                "raw": spektrafilm_io::is_raw(&input),
                "preview_colour_space": declared.flatten(), "elapsed_ms": ms(started.elapsed()), "cached_pipeline": cached,
            }));
        }
        let backend = self.backend.get_or_insert_with(spektrafilm_gpu::select_backend);
        let (output, used_backend) = pipeline.process_with_backend(working, backend.as_ref());
        let cropped = crop.map(|crop| crop.apply(&output));
        let output = cropped.as_ref().unwrap_or(&output);
        let processed = started.elapsed();
        let encoding = Encoding::new(&params.io.output_color_space, params.io.output_cctf_encoding);
        let (width, height) = write_display(output, encoding, &post, &preview_path)?;
        let mut result = json!({
            "width": width, "height": height, "backend": used_backend,
            "display_color_space": DisplaySpace::of(encoding).name(),
            // The photograph's whole size, for a camera brightness match and the
            // layout, even from a reduced read.
            "source_width": full.0, "source_height": full.1, "reduced_decode": reduced,
            "elapsed_ms": ms(started.elapsed()), "cached_pipeline": cached,
            "timing_ms": {"decode": ms(decoded), "resample": ms(resampled - decoded),
                "pipeline": ms(built - resampled), "process": ms(processed - built),
                "write": ms(started.elapsed() - processed)},
        });
        if let Some(declared) = declared {
            result["preview_colour_space"] = json!(declared);
        }
        Ok(result)
    }

    fn handle(&mut self, request: Request, data: &Path) -> Result<Value> {
        self.take_balance(false);
        self.take_refined();
        match request.command {
            Command::Catalog => catalog(data),
            Command::BalancePrint { film, paper, params } => {
                let started = Instant::now();
                let (m, y) = spektrafilm_core::print_balance::solve_neutral_filter_shifts(
                    profile::load_profile_by_name(data, &film)?,
                    profile::load_profile_by_name(data, &paper)?,
                    &params,
                    data,
                    spektrafilm_core::print_balance::MIDGRAY,
                )
                .map_err(anyhow::Error::msg)?;
                Ok(json!({"m_filter_shift": m, "y_filter_shift": y,
                          "elapsed_ms": started.elapsed().as_secs_f64() * 1000.0}))
            }
            Command::ExportLut { film, paper, params, size, output } => {
                let started = Instant::now();
                let cube = spektrafilm_core::lut_export::cube(data, &film, &paper, *params, size)
                    .map_err(anyhow::Error::msg)?;
                std::fs::write(&output, cube)?;
                Ok(json!({"size": size, "elapsed_ms": started.elapsed().as_secs_f64() * 1000.0}))
            }
            Command::PresetImport { text, params } => {
                let preset = presets::import(&text, data).map_err(anyhow::Error::msg)?;
                let params = presets::apply(&preset.params, &params.unwrap_or_default());
                Ok(json!({"film": preset.film, "paper": preset.paper, "params": params}))
            }
            Command::PresetExport { film, paper, params } => {
                let text = presets::export(&film, &paper, &params, data).map_err(anyhow::Error::msg)?;
                Ok(json!({"text": text}))
            }
            Command::Original { input, params, limit_preview, preview_path } => {
                ensure!(input != preview_path, "Choose a different preview path to preserve the source");
                ensure!(params.io.upscale_factor.is_finite()
                    && (0.1..=1.0).contains(&params.io.upscale_factor), "Invalid working resolution");
                params.io.raw_white_balance.validate()?;
                params.io.input_interpretation.validate()?;
                let loaded = spektrafilm_io::load_image_colour(
                    &input, spektrafilm_io::Formats::Any, params.io.raw_white_balance,
                    params.io.lens_correction, &params.io.input_interpretation,
                )?;
                let source = loaded.image;
                // Never enlarged: an Image Size target is ignored, and the
                // canvas fits the original to the developed photograph.
                let factor = if params.io.photo_long_side_px.is_some() { 1.0 } else { params.io.upscale_factor };
                let dimensions = preview_dimensions(source.width, source.height, factor, limit_preview);
                let resized = (dimensions != (source.width, source.height))
                    .then(|| rescale_preview_input_fast(&source, dimensions));
                let working = resized.as_ref().unwrap_or(&source);
                let (encoding, converted) = original_encoding(&params, &loaded.colour, working);
                let working = converted.as_ref().unwrap_or(working);
                let (width, height) = write_display(working, encoding, &PostParams::default(), &preview_path)?;
                Ok(json!({"width": width, "height": height, "input_colour": loaded.colour,
                          "display_color_space": DisplaySpace::of(encoding).name()}))
            }
            Command::Thumbnail {
                input, source_generation, film, paper, params, long_side, preview_path, crop, preset, reduced_decode, decode_only,
                preview_colour_space,
            } => self.thumbnail(
                input, source_generation, film, paper, params, long_side, preview_path, crop, preset, reduced_decode, decode_only,
                preview_colour_space, data,
            ),
            Command::ToneCurve { film, paper, params, count } => {
                let started = Instant::now();
                let params = spektrafilm_core::tone_curve::tone_params(&params);
                let key = preview_pipeline_cache_key(&film, &paper, &params);
                let (calibrated, cached) =
                    self.pipelines.get_or_build(&key, false, || build_pipeline(data, &film, &paper, &params))?;
                let pipeline = calibrated.clone().with_params(params);
                let built = started.elapsed();
                let curve = spektrafilm_core::tone_curve::tone_curve(&pipeline, count.unwrap_or(256));
                let ms = |d: std::time::Duration| d.as_secs_f64() * 1000.0;
                Ok(json!({
                    "stops": spektrafilm_core::tone_curve::STOPS,
                    "film": curve.film, "paper": curve.paper, "rgb": curve.rgb,
                    "cached_pipeline": cached,
                    "timing_ms": {"pipeline": ms(built), "curve": ms(started.elapsed() - built)},
                    "elapsed_ms": ms(started.elapsed()),
                }))
            }
            Command::ReleaseThumbnails => {
                self.thumbnail_source = None;
                self.pipelines.release_unpinned();
                self.thumbnail_wb_sources = Vec::new();
                Ok(json!({}))
            }
            Command::ReleaseFilmCache => {
                let bytes = self.backend.as_ref().map_or(0, |backend| backend.release_film_cache());
                Ok(json!({"released_bytes": bytes}))
            }
            Command::PreviewColourSpace { input } => Ok(json!({ "colour_space": declared_preview_colour_space(&input)? })),
            Command::BrightnessReference { input, reference_path, expected_width, expected_height } => {
                ensure!(expected_width > 0 && expected_height > 0,
                    "The brightness reference needs the photograph's dimensions");
                ensure!(input != reference_path
                    && !std::fs::canonicalize(&reference_path).ok().is_some_and(|output|
                        std::fs::canonicalize(&input).ok().as_ref() == Some(&output)),
                    "The brightness reference must not replace the original photograph");
                match spektrafilm_io::brightness::reference(&input, (expected_width, expected_height)) {
                    Ok(reference) => {
                        spektrafilm_io::brightness::write_reference(&reference, &reference_path)?;
                        Ok(json!({"usable": true, "reference_path": reference_path,
                            "width": reference.width(), "height": reference.height()}))
                    }
                    Err(error) => {
                        if let Some(spektrafilm_io::brightness::Unusable(reason)) = error.downcast_ref::<spektrafilm_io::brightness::Unusable>() {
                            Ok(json!({"usable": false, "reason": reason, "for_photo": true}))
                        } else {
                            Err(error)
                        }
                    }
                }
            }
            Command::PrepareBalance { input, source_generation, params, read_long_side } => {
                ensure!(spektrafilm_io::is_raw(&input), "Only a RAW has a white balance to prepare");
                let lens = params.io.lens_correction;
                let interpretation = params.io.input_interpretation.clone();
                self.adopt_proxy(&input, source_generation, lens, &interpretation);
                if let Some(fit) = self.as_shot_fit.as_ref().filter(|f| f.path == input && f.generation == source_generation && f.lens == lens) {
                    return Ok(json!({"as_shot": [fit.as_shot.0, fit.as_shot.1], "auto": fit.auto.map(|(t, g)| json!([t, g])), "ready": true}));
                }
                if self.pending_balance.as_ref().is_some_and(|p| p.path == input && p.generation == source_generation && p.lens == lens) {
                    return Ok(json!({"ready": false}));
                }
                // As Shot's metering frame: the source's, which must be the As Shot read.
                let as_shot_wb = spektrafilm_io::RawWhiteBalance::default();
                let keeps = self.source_generation == source_generation
                    && self.source.as_ref().is_some_and(|s| s.current(&input, as_shot_wb, lens, &interpretation));
                ensure!(keeps, "The photograph isn't read As Shot");
                let source = &self.source.as_ref().unwrap().image;
                let as_shot_metering = self.metering.get_or_insert_with(|| spektrafilm_core::stages::filming::metering_preview(source)).clone();
                let limit = if read_long_side == 0 { 0 } else { ((read_long_side as f64 / 512.0).ceil() * 512.0 + 512.0).max(2048.0) as u32 };
                let (path, thread_interpretation) = (input.clone(), interpretation.clone());
                let read = std::thread::Builder::new().name("daylight-read".into()).spawn(move || {
                    let daylight = spektrafilm_io::RawWhiteBalance { mode: spektrafilm_io::RawWhiteBalanceMode::Daylight, ..Default::default() };
                    let loaded = spektrafilm_io::load_image_colour_limited(
                        &path, spektrafilm_io::Formats::Any, daylight, lens, &thread_interpretation, limit,
                    )?;
                    let metering = spektrafilm_core::stages::filming::metering_preview(&loaded.image);
                    Ok((loaded, metering))
                })?;
                self.pending_balance = Some(PendingBalance {
                    path: input, generation: source_generation, lens, interpretation, limit, as_shot_metering, read,
                });
                Ok(json!({"ready": false}))
            }
            Command::MakeProxy { input, params } => {
                let started = std::time::Instant::now();
                let lens = params.io.lens_correction;
                let interpretation = params.io.input_interpretation.clone();
                let Some(file) = proxy_file(&input, lens) else { return Ok(json!({"made": false})) };
                if file.exists() {
                    return Ok(json!({"made": false, "exists": true}));
                }
                // The As Shot read first (small: only its metering frame is kept), then the Daylight one, which the
                // decoder develops from the sensor data it has just read for the first.
                let as_shot = spektrafilm_io::load_image_colour_limited(
                    &input, spektrafilm_io::Formats::Any, spektrafilm_io::RawWhiteBalance::default(), lens, &interpretation, 1024,
                )?;
                let as_shot_metering = spektrafilm_core::stages::filming::metering_preview(&as_shot.image);
                drop(as_shot);
                let daylight = spektrafilm_io::RawWhiteBalance { mode: spektrafilm_io::RawWhiteBalanceMode::Daylight, ..Default::default() };
                let loaded = spektrafilm_io::load_image_colour_limited(&input, spektrafilm_io::Formats::Any, daylight, lens, &interpretation, PROXY_LONG)?;
                let read_ms = started.elapsed().as_secs_f64() * 1000.0;
                let daylight_metering = spektrafilm_core::stages::filming::metering_preview(&loaded.image);
                let (matrix, as_shot, auto) = fit_balance(&daylight_metering, &as_shot_metering)
                    .context("The photograph has too few usable pixels to fit its white balance")?;
                write_proxy(&file, &loaded.image, loaded.full_size, &loaded.colour, loaded.lens_correction_supported, matrix, as_shot, auto)?;
                drop_other_proxy(&input, lens.enabled);
                Ok(json!({"made": true, "elapsed_ms": started.elapsed().as_secs_f64() * 1000.0, "read_ms": read_ms,
                    "bytes": std::fs::metadata(&file).map(|m| m.len()).unwrap_or(0)}))
            }
            Command::PickBalance { input, source_generation, params, x, y } => {
                ensure!(spektrafilm_io::is_raw(&input), "Only a RAW's white balance can be picked");
                ensure!((0.0..=1.0).contains(&x) && (0.0..=1.0).contains(&y), "Pick a point on the photograph");
                let lens = params.io.lens_correction;
                let interpretation = params.io.input_interpretation.clone();
                let wb = params.io.raw_white_balance;
                self.adopt_proxy(&input, source_generation, lens, &interpretation);
                // The source as it is, if it's this photograph; else read it, reduced, with the asked balance.
                let mine = self.source_generation == source_generation
                    && self.source.as_ref().is_some_and(|s| s.path == input && s.lens == lens);
                if !mine {
                    self.load_source(&input, source_generation, wb, lens, interpretation, 2560)?;
                }
                let source = self.source.as_ref().unwrap();
                // What takes a Daylight read to this source's pixels.
                let read_matrix = match source.wb.effective().mode {
                    spektrafilm_io::RawWhiteBalanceMode::AsShot => self
                        .as_shot_matrix(&input, source_generation, lens)
                        .context("The photograph's As Shot balance isn't known yet; try again in a moment")?,
                    _ => spektrafilm_io::daylight_adjustment(source.wb.effective()).context("No balance for this read")?,
                };
                let inverse = invert3(read_matrix).context("This balance can't be undone")?;
                let image = &source.image;
                let (w, h) = (image.width as i64, image.height as i64);
                let (cx, cy) = ((x * w as f64) as i64, (y * h as f64) as i64);
                let radius = ((w.max(h) as f64) * 0.004).round().max(2.0) as i64;
                let mut sum = [0.0f64; 3];
                let mut count = 0.0;
                for py in (cy - radius).max(0)..=(cy + radius).min(h - 1) {
                    for px in (cx - radius).max(0)..=(cx + radius).min(w - 1) {
                        let i = ((py * w + px) * 3) as usize;
                        for c in 0..3 {
                            sum[c] += image.data[i + c] as f64;
                        }
                        count += 1.0;
                    }
                }
                ensure!(count > 0.0, "Pick a point on the photograph");
                let mean = [sum[0] / count, sum[1] / count, sum[2] / count];
                let daylight: Vec<f64> = (0..3).map(|r| inverse[r][0] * mean[0] + inverse[r][1] * mean[1] + inverse[r][2] * mean[2]).collect();
                ensure!(daylight.iter().all(|&v| v > 1e-5), "That point is too dark to balance on: pick a light grey or a white");
                let peak = image.data.iter().fold(0.0f64, |m, &v| m.max(v as f64));
                ensure!(mean.iter().all(|&v| v < peak * 0.98), "That point is clipped: pick a grey or a white with detail");
                let (temperature, tint) = search_balance(|m| {
                    let out: Vec<f64> = (0..3).map(|r| (m[r][0] * daylight[0] + m[r][1] * daylight[1] + m[r][2] * daylight[2]).max(1e-9)).collect();
                    (out[0] / out[1]).ln().powi(2) + (out[2] / out[1]).ln().powi(2)
                })
                .context("No white balance makes that point neutral")?;
                Ok(json!({"temperature": temperature, "tint": tint}))
            }
            Command::PlaceExposure { input, source_generation, film, paper, mut params, reference_path } => {
                let started = Instant::now();
                params.prep.validate().map_err(anyhow::Error::msg)?;
                params.io.raw_white_balance.validate()?;
                params.io.input_interpretation.validate()?;
                ensure!(params.io.upscale_factor.is_finite()
                    && (0.1..=1.0).contains(&params.io.upscale_factor), "Invalid working resolution");
                ensure!(RgbColourspace::find(&params.io.output_color_space).is_some(),
                    "Unknown output colour space: {}", params.io.output_color_space);
                self.adopt_proxy(&input, source_generation, params.io.lens_correction, &params.io.input_interpretation);
                let wb = params.io.raw_white_balance.effective();
                // Qlick Lab: a Daylight read (a proxy) is taken to the asked balance by its matrix.
                let matrix = self.source.as_ref().filter(|s| {
                    s.wb.effective().mode == spektrafilm_io::RawWhiteBalanceMode::Daylight
                        && !s.current(&input, params.io.raw_white_balance, params.io.lens_correction, &params.io.input_interpretation)
                }).and_then(|_| {
                    spektrafilm_io::daylight_adjustment(wb).or_else(|| {
                        (wb.mode == spektrafilm_io::RawWhiteBalanceMode::AsShot)
                            .then(|| self.as_shot_matrix(&input, source_generation, params.io.lens_correction))
                            .flatten()
                    })
                });
                let source = self.source.as_ref().context("Open a photograph and wait for its preview before placing exposure")?;
                ensure!(self.source_generation == source_generation
                    && (matrix.is_some() || source.current(&input, params.io.raw_white_balance, params.io.lens_correction,
                                      &params.io.input_interpretation)),
                    "The photograph or RAW settings changed; wait for its current preview and try again");
                let balanced = matrix.map(|matrix| {
                    let mut image = source.image.clone();
                    apply_matrix(&mut image, matrix);
                    let metering = spektrafilm_core::stages::filming::metering_preview(&image);
                    (image, metering)
                });
                let source_image = balanced.as_ref().map_or(&source.image, |(image, _)| image);
                let reference = placement_reference(&reference_path, source_image)?;
                params.io.apply_input_colour(&source.colour);
                ensure!(RgbColourspace::find(&params.io.input_color_space).is_some(),
                    "Unknown input colour space: {}", params.io.input_color_space);
                image_size::clear(&mut params);
                let key = preview_pipeline_cache_key(&film, &paper, &params);
                // Borrow the calibrated look when possible, but keep all
                // placement work local. Save must still see the last preview.
                let mut pipeline = match self.pipelines.peek(&key) {
                    Some(pipeline) => pipeline.clone().with_params((*params).clone()),
                    None => build_pipeline(data, &film, &paper, &params)?,
                };
                if let Some(metering) = balanced.as_ref().map(|(_, metering)| metering).or(self.metering.as_ref()) {
                    pipeline = pipeline.with_metering_preview(metering.clone());
                }
                let backend = self.backend.get_or_insert_with(spektrafilm_gpu::select_backend);
                let placement = spektrafilm_core::exposure_placement::place_exposure(
                    &pipeline, source_image, &reference, backend.as_ref(),
                ).map_err(anyhow::Error::msg)?;
                let mut result = serde_json::to_value(placement)?;
                result["elapsed_ms"] = json!(started.elapsed().as_secs_f64() * 1000.0);
                Ok(result)
            }
            Command::Save {
                render_id,
                output,
                save_options,
                crop_after_post,
                border,
                border_options,
                instagram,
                crop,
                rotate_cw,
                fit,
            } => {
                let Rendered {
                    id,
                    source,
                    film,
                    encoding,
                    post,
                    image,
                    ..
                } = self.output.as_mut().context("No preview to save")?;
                let (encoding, encoded) = (*encoding, encoding.encoded);
                ensure!(
                    *id == render_id,
                    "The preview changed; wait for the current render and try again"
                );
                ensure!(
                    source != &output,
                    "Choose a different output path to preserve the source"
                );
                if let Some(crop) = &crop {
                    crop.validate()?;
                }
                save_options.check(&output)?;
                let metadata = spektrafilm_io::read_metadata(source);
                // The render is the unclipped scan; Post, crop, border and resize
                // work on it as the file will hold it. Clipping in place keeps
                // memory flat, and the display clips the same way.
                spektrafilm_core::pipeline::clip_to_display(image, encoded);
                let image = &*image;
                let adjusted_before = (crop_after_post && !post.is_identity())
                    .then(|| PostProcess::new(post, encoded, encoding.space.name).applied(image));
                let image = adjusted_before.as_ref().unwrap_or(image);
                // Crop in the unrotated orientation, then rotate, then add the border.
                let cropped = crop.map(|crop| crop.apply(image));
                let image = cropped.as_ref().unwrap_or(image);
                let adjusted = (!crop_after_post && !post.is_identity())
                    .then(|| PostProcess::new(post, encoded, encoding.space.name).applied(image));
                let image = adjusted.as_ref().unwrap_or(image);
                let rotated =
                    (rotate_cw.rem_euclid(4) != 0).then(|| image.clone().rotated_cw(rotate_cw));
                let image = rotated.as_ref().unwrap_or(image);
                let bordered = match border {
                    Some(style) => {
                        let bordered =
                            add_border(image, style, &border_options, film, encoding, data)?;
                        Some(if instagram {
                            extend_for_instagram(&bordered, style, &border_options, encoding)
                        } else {
                            bordered
                        })
                    }
                    None => None,
                };
                let image = bordered.as_ref().unwrap_or(image);
                let resized = fit.and_then(|fit| resize::fit(image, fit, encoding));
                let image = resized.as_ref().unwrap_or(image);
                // Saved in the preview's space, the file holds the render's
                // values. Another space gets the preview's colours, clipped to
                // the smaller of the two gamuts (relative colorimetric).
                let space = RgbColourspace::find(&save_options.color_space)
                    .with_context(|| format!("Unknown colour space: {}", save_options.color_space))?;
                let converted = (space.name != encoding.space.name).then(|| {
                    let mut converted = image.clone();
                    convert_output(&mut converted, encoding.space.name, space.name, encoded);
                    converted
                });
                let image = converted.as_ref().unwrap_or(image);
                let save_options = spektrafilm_io::save::SaveOptions { linear: !encoded, ..save_options };
                spektrafilm_io::save::save_image_with_options(image, &output, metadata.as_ref(), &save_options)?;
                Ok(json!({"saved": output}))
            }
            Command::Render {
                input,
                source_generation,
                film,
                paper,
                mut params,
                limit_preview,
                preview_path,
                interactive_scale,
                crop,
                read_long_side,
                region,
            } => {
                let started = Instant::now();
                ensure!(
                    region.is_none_or(|r| r.iter().all(|v| v.is_finite() && (0.0..=1.0).contains(v)) && r[2] > 0.0 && r[3] > 0.0),
                    "Invalid region"
                );
                ensure!(
                    params.io.upscale_factor.is_finite()
                        && (0.1..=1.0).contains(&params.io.upscale_factor),
                    "Invalid working resolution"
                );
                ensure!(
                    interactive_scale.is_none_or(|s| s.is_finite() && s > 0.0),
                    "Invalid interactive scale"
                );
                // The preview space: the app sends the export's colour space,
                // so the preview judges the export's gamut.
                ensure!(
                    RgbColourspace::find(&params.io.output_color_space).is_some(),
                    "Unknown output colour space: {}",
                    params.io.output_color_space
                );
                params.io.raw_white_balance.validate()?;
                params.settings.serial_grain = false;
                params.prep.validate().map_err(anyhow::Error::msg)?;
                // Applied to the display and on save, so the pipeline runs without them.
                let post = std::mem::take(&mut params.post);
                let wb = params.io.raw_white_balance;
                let lens = params.io.lens_correction;
                let interpretation = params.io.input_interpretation.clone();
                interpretation.validate()?;
                self.adopt_proxy(&input, source_generation, lens, &interpretation);
                // Qlick Lab: a canvas-size frame of a RAW that has to be read again (its
                // white balance changed) is read reduced, which takes a fraction of the
                // whole read; the whole photograph is read again when it's asked for.
                let read_limit = match (interactive_scale.filter(|&s| s < 1.0), self.source.as_ref()) {
                    (Some(scale), Some(known))
                        if self.source_generation == source_generation
                            && known.path == input
                            && spektrafilm_io::is_raw(&input) =>
                    {
                        let long = known.full.0.max(known.full.1) as f64;
                        let wanted = ((long * scale as f64 / 512.0).ceil() * 512.0 + 512.0).max(2048.0);
                        if wanted >= long * 0.75 { 0 } else { wanted as u32 }
                    }
                    // Not read yet: as large as the app says the frame needs.
                    (Some(_), _) if spektrafilm_io::is_raw(&input) => read_long_side
                        .map(|side| ((side as f64 / 512.0).ceil() * 512.0 + 512.0).max(2048.0) as u32)
                        .unwrap_or(0),
                    _ => 0,
                };
                // Qlick Lab: a canvas-size frame of a RAW takes its white balance from
                // a Daylight read and the balance's matrix, as the decoder does itself
                // after developing at D65, unless the source is read with it already.
                let exact = self.source_generation == source_generation
                    && self.source.as_ref().is_some_and(|s| s.current(&input, wb, lens, &interpretation));
                let as_shot_matrix = (wb.effective().mode == spektrafilm_io::RawWhiteBalanceMode::AsShot)
                    .then(|| self.as_shot_matrix(&input, source_generation, lens))
                    .flatten();
                // Any preview frame, zoomed in or not: the export alone decodes the RAW with its balance.
                let mut balance = (!exact && spektrafilm_io::is_raw(&input))
                    .then(|| spektrafilm_io::daylight_adjustment(wb.effective()).or(as_shot_matrix))
                    .flatten();
                let asked_wb = wb;
                let wb = if balance.is_some() {
                    spektrafilm_io::RawWhiteBalance { mode: spektrafilm_io::RawWhiteBalanceMode::Daylight, ..Default::default() }
                } else {
                    wb
                };
                // Qlick Lab: a limited preview (12 MP at most) of a RAW whose size is known is read no larger than it
                // shows, not whole to be reduced after: a 60 MP photograph then takes a third of the time and of
                // the memory. The whole photograph is read when the limit is lifted, and for the export.
                let read_limit = match self.source.as_ref() {
                    Some(known)
                        if interactive_scale.is_none_or(|s| s >= 1.0)
                            && limit_preview
                            && self.source_generation == source_generation
                            && known.path == input
                            && spektrafilm_io::is_raw(&input) =>
                    {
                        let long = f64::from(known.full.0.max(known.full.1));
                        image_size::resolve(&params, known.full, crop.as_ref()).map_or(0, |size| {
                            let shown = preview_cap(size.working, true);
                            let shown = f64::from(shown.0.max(shown.1));
                            if shown < long * 0.75 { shown as u32 + 16 } else { 0 }
                        })
                    }
                    _ => read_limit,
                };
                // Qlick Lab: a reduced read that has the frame's pixels already (a proxy under a canvas no larger)
                // isn't read again for the margin a new read would take. One that hasn't them (a proxy under a
                // large canvas, a zoom) shows this frame from what it has, at once, while the larger read comes on
                // a thread of its own and takes its place for the frames after: the app asks again while the
                // answer says `refining`. Only a Daylight read, which a matrix takes to any balance.
                let mut refine = None;
                let read_limit = match (interactive_scale.filter(|&s| s < 1.0), self.source.as_ref()) {
                    (Some(scale), Some(known))
                        if self.source_generation == source_generation && known.current(&input, wb, lens, &interpretation) =>
                    {
                        match known.reduced_to {
                            Some(read) => {
                                let needed = known.full.0.max(known.full.1) as f64 * scale as f64;
                                let have = f64::from(known.image.width.max(known.image.height));
                                if needed <= have {
                                    read
                                } else if wb.effective().mode == spektrafilm_io::RawWhiteBalanceMode::Daylight {
                                    // Within a tenth, the frame is as sharp as the canvas can tell.
                                    if needed > have * 1.1 {
                                        refine = Some(read_limit);
                                    }
                                    read
                                } else {
                                    read_limit
                                }
                            }
                            None => read_limit,
                        }
                    }
                    _ => read_limit,
                };
                if let Some(limit) = refine {
                    if !self.pending_source.as_ref().is_some_and(|pending| pending.serves(&input, source_generation, lens, limit)) {
                        let (path, thread_interpretation) = (input.clone(), interpretation.clone());
                        let read = std::thread::Builder::new().name("larger-read".into()).spawn(move || {
                            let daylight =
                                spektrafilm_io::RawWhiteBalance { mode: spektrafilm_io::RawWhiteBalanceMode::Daylight, ..Default::default() };
                            let loaded = spektrafilm_io::load_image_colour_limited(
                                &path, spektrafilm_io::Formats::Any, daylight, lens, &thread_interpretation, limit,
                            )?;
                            let metering = spektrafilm_core::stages::filming::metering_preview(&loaded.image);
                            Ok((loaded, metering))
                        })?;
                        self.pending_source = Some(PendingSource {
                            path: input.clone(), generation: source_generation, lens, interpretation: interpretation.clone(), limit, read,
                        });
                    }
                } else if self.pending_source.as_ref().is_some_and(|pending| pending.path != input || pending.generation != source_generation) {
                    // Another photograph's: its read ends by itself, and is dropped.
                    self.pending_source = None;
                }
                let refining = self.pending_source.as_ref().is_some_and(|pending| pending.path == input && pending.generation == source_generation);
                self.load_source(&input, source_generation, wb, lens, interpretation, read_limit)?;
                let t_load = started.elapsed();
                let Source { image: source, colour: input_colour, lens_correction_supported, full, .. } =
                    self.source.as_ref().unwrap();
                let full = *full;
                // RAW and decoded files are the engine's linear sRGB; manual
                // pass-through keeps the params' input fields, as 0.8 did.
                params.io.apply_input_colour(input_colour);
                if (params.camera.auto_exposure || balance.is_some()) && self.metering.is_none() {
                    self.metering = Some(spektrafilm_core::stages::filming::metering_preview(source));
                }
                if balance.is_some() && self.metering.as_ref().is_some_and(is_grey) {
                    balance = None;
                }
                // The metering frame as balanced: what a read with this balance meters.
                let balanced_metering = balance.and_then(|matrix| {
                    self.metering.as_ref().map(|frame| {
                        let mut frame = frame.clone();
                        apply_matrix(&mut frame, matrix);
                        frame
                    })
                });
                let (source_width, source_height) = full;
                // The uncapped frame an export develops, and the photograph the
                // crop cuts from it; an invalid or too-large request fails here,
                // before anything is allocated at that size.
                let size = image_size::resolve(&params, (source_width, source_height), crop.as_ref())?;
                image_size::clear(&mut params);
                // The photograph's preview, at most 12 MP if limited; an
                // interactive render is a smaller frame of it that never
                // enlarges the source.
                let photo_dimensions = preview_cap(size.working, limit_preview);
                let dimensions = match interactive_scale.filter(|&s| s < 1.0) {
                    Some(s) => within(interactive_dimensions(photo_dimensions, s, (source_width, source_height)), source),
                    None => photo_dimensions,
                };
                // The resolved size, not the crop: panning a crop, or any crop
                // with the same working size, reuses the render.
                let render_key = json!({
                    "input": input, "source_generation": source_generation, "film": film,
                    "paper": paper, "params": params, "limit_preview": limit_preview,
                    "interactive_scale": interactive_scale, "working": size.working,
                    "region": region.filter(|_| interactive_scale.is_none_or(|s| s >= 1.0)).map(|r| frame_window(r, photo_dimensions)),
                    // Qlick Lab: a source that took another's place (a larger read) develops again.
                    "source_loads": self.source_loads,
                });
                let reused = self.output.take().filter(|last| last.key == render_key);
                if let Some(last) = reused {
                    write_display(&last.image, last.encoding, &post, &preview_path)?;
                    let mut response = last.response.clone();
                    // Edge rounding moves the crop's pixels with its position.
                    response["photo_crop_width"] = json!(size.photo.0);
                    response["photo_crop_height"] = json!(size.photo.1);
                    response["elapsed_ms"] = json!(started.elapsed().as_secs_f64() * 1000.0);
                    response["refining"] = json!(refining);
                    self.output = Some(Rendered {
                        id: request.id,
                        post,
                        ..last
                    });
                    return Ok(response);
                }
                let key = preview_pipeline_cache_key(&film, &paper, &params);
                let t_before_pipeline = started.elapsed();
                let before_build = started.elapsed();
                let (calibrated, cached_pipeline) =
                    self.pipelines.get_or_build(&key, true, || build_pipeline(data, &film, &paper, &params))?;
                let mut pipeline = calibrated.clone().with_params((*params).clone());
                let pipeline_ms = (started.elapsed() - before_build).as_secs_f64() * 1000.0;
                if let Some(metering) = balanced_metering.as_ref().or(self.metering.as_ref()) {
                    pipeline = pipeline.with_metering_preview(metering.clone());
                }
                // The tone graph's histogram: the photograph's film exposure,
                // from the metering frame (the whole frame, before spatial effects).
                // Prep's exposure is a uniform gain, so it shifts the stops like
                // the camera's; its other controls reshape them, so then the
                // frame goes through Prep and is counted as exposed.
                let histogram = {
                    let metering = match &balanced_metering {
                        Some(frame) => frame,
                        None => &*self
                            .metering
                            .get_or_insert_with(|| spektrafilm_core::stages::filming::metering_preview(source)),
                    };
                    let ae = if params.camera.auto_exposure { pipeline.metering_film_raw(metering).1 } else { 0.0 };
                    let reshaped = !spektrafilm_core::prep::PrepParams { exposure_ev: 0.0, ..params.prep }.is_identity();
                    let mut stops_key = format!("{}|{source_generation}|{}", input.display(), key);
                    if balance.is_some() {
                        stops_key += &format!("|wb{}|{}", asked_wb.effective().temperature, asked_wb.effective().tint);
                    }
                    if reshaped {
                        stops_key += &format!("|{:?}|{ae}|{}", params.prep, params.camera.exposure_compensation_ev);
                    }
                    if self.film_stops.as_ref().is_none_or(|(old, _)| old != &stops_key) {
                        let raw = if reshaped {
                            pipeline.metering_film_raw_prepared(metering, ae).map_err(anyhow::Error::msg)?
                        } else {
                            pipeline.metering_film_raw(metering).0
                        };
                        self.film_stops = Some((stops_key, spektrafilm_core::tone_curve::raw_stops(&raw)));
                    }
                    let ev = if reshaped { 0.0 } else { ae + params.camera.exposure_compensation_ev as f64 + params.prep.exposure_ev as f64 };
                    let counts = spektrafilm_core::tone_curve::film_histogram(&self.film_stops.as_ref().unwrap().1, ev, 128);
                    json!({"stops": spektrafilm_core::tone_curve::STOPS, "ev": ev, "counts": counts})
                };
                let whole_frame = dimensions == photo_dimensions;
                let backend = self
                    .backend
                    .get_or_insert_with(spektrafilm_gpu::select_backend);
                // Qlick Lab: the part of the frame the canvas shows, developed with the margin its blurs read.
                use spektrafilm_core::pipeline::Window;
                let asked = region
                    .filter(|_| whole_frame && pipeline.windows(backend.as_ref()))
                    .map(|r| frame_window(r, dimensions))
                    .and_then(|[x, y, width, height]| {
                        let window = Window { x, y, width, height };
                        let grown = window.grown(pipeline.window_margin(dimensions.0, dimensions.1), dimensions);
                        // Nearly the whole frame: develop it, and keep it.
                        let (part, frame) = (u64::from(grown.width) * u64::from(grown.height), u64::from(dimensions.0) * u64::from(dimensions.1));
                        (part * 4 <= frame * 3).then_some((window, grown))
                    });
                let kept = |developed: ImageBuf, window: Window, grown: Window| {
                    let inner = Window { x: window.x - grown.x, y: window.y - grown.y, ..window };
                    (inner.cut(&developed), window)
                };
                // Prep's base is the whole frame's, so it works on the frame before the cut; without it the
                // part is cut first, and the frame is neither copied for its balance nor sent whole.
                let prep_whole = !params.prep.is_identity() && !params.prep.is_exposure_only();
                let mut part = None;
                if let Some((window, grown)) = asked.filter(|_| !prep_whole) {
                    let base = working_source(source, &mut self.scaled, dimensions, rescale_preview_input_fast);
                    let mut cut = grown.cut(base);
                    let name = match balance {
                        Some(matrix) => {
                            apply_matrix(&mut cut, matrix);
                            let effective = asked_wb.effective();
                            balance_name(&(dimensions, effective.temperature.to_bits() ^ effective.mode as u64, effective.tint.to_bits(), self.source_loads))
                        }
                        None => self.source_loads,
                    };
                    // A slot of its own: the screen's frame under it keeps its film side too.
                    part = pipeline
                        .clone()
                        .with_film_cache(3, name)
                        .with_cut_window(grown, dimensions)
                        .process_resident_borrowed(&cut, backend.as_ref())
                        .map(|developed| kept(developed, window, grown));
                }
                let working = if part.is_some() {
                    None
                } else {
                    Some(if whole_frame && balance.is_none() {
                    pipeline = pipeline.with_prepared_frame(self.prepared_photo.clone()).with_film_cache(0, self.source_loads);
                    working_source(
                        source,
                        &mut self.scaled,
                        dimensions,
                        rescale_preview_input_fast,
                    )
                } else {
                    let base = if whole_frame {
                        working_source(source, &mut self.scaled, dimensions, rescale_preview_input_fast)
                    } else {
                        working_source(source, &mut self.interactive, dimensions, downsample_area)
                    };
                    if let Some(matrix) = balance {
                        let effective = asked_wb.effective();
                        let mode = effective.mode as u64;
                        let balance_key: BalanceKey =
                            (dimensions, effective.temperature.to_bits() ^ mode, effective.tint.to_bits(), self.source_loads);
                        if self.balanced.as_ref().is_none_or(|(kept, _)| *kept != balance_key) {
                            self.balanced = None;
                            self.prepared_balanced.clear();
                            let mut image = base.clone();
                            apply_matrix(&mut image, matrix);
                            self.balanced = Some((balance_key, image));
                        }
                        // A name of its own for the film-side cache: these pixels change with the balance.
                        let name = balance_name(&balance_key);
                        pipeline = pipeline.with_prepared_frame(self.prepared_balanced.clone()).with_film_cache(2, name);
                        &self.balanced.as_ref().unwrap().1
                    } else {
                        pipeline = pipeline.with_prepared_frame(self.prepared_interactive.clone()).with_film_cache(1, self.source_loads);
                        base
                    }
                })
                };
                let t_working = started.elapsed();
                if let (None, Some((window, grown)), Some(working)) = (&part, asked, working) {
                    part = pipeline
                        .clone()
                        .with_window(Some(grown))
                        .process_resident_borrowed(working, backend.as_ref())
                        .map(|developed| kept(developed, window, grown));
                }
                let window = part.as_ref().map(|(_, window)| *window);
                let (output, used_backend) = match (part, working) {
                    (Some((output, _)), _) => (output, backend.name()),
                    (None, Some(working)) if pipeline.params.io.scan_film && pipeline.film.is_positive() => {
                        pipeline.process_with_backend(working.clone(), backend.as_ref())
                    }
                    (None, Some(working)) => pipeline
                        .process_resident_borrowed(working, backend.as_ref())
                        .map(|output| (output, backend.name()))
                        .unwrap_or_else(|| pipeline.process_with_backend(working.clone(), backend.as_ref())),
                    (None, None) => unreachable!("a frame without a part has its working image"),
                };
                let encoding = Encoding::new(&params.io.output_color_space, params.io.output_cctf_encoding);
                let (width, height) = write_display(&output, encoding, &post, &preview_path)?;
                if std::env::var_os("QLICK_RENDER_LOG").is_some() {
                    eprintln!(
                        "helper render: load={:.0} metering={:.0} pipeline={:.0} histogram+working={:.0} process+write={:.0} total={:.0} read_limit={} balance={} dims={:?}",
                        t_load.as_secs_f64() * 1000.0,
                        (t_before_pipeline - t_load).as_secs_f64() * 1000.0,
                        pipeline_ms,
                        (t_working - t_before_pipeline).as_secs_f64() * 1000.0 - pipeline_ms,
                        (started.elapsed() - t_working).as_secs_f64() * 1000.0,
                        started.elapsed().as_secs_f64() * 1000.0,
                        read_limit,
                        balance.is_some(),
                        dimensions
                    );
                }
                // At the uncapped working size the output is byte-identical to
                // a Fast (GPU) export, so the app can save it instead of
                // rendering again. The display proxy's limit doesn't matter:
                // Save uses this float output.
                // Qlick Lab: nor when its white balance is a matrix's: the export decodes it exactly.
                let export_resolution = (output.width, output.height) == size.working && balance.is_none() && window.is_none();
                let response = json!({
                    "width": width, "height": height, "output_width": output.width, "output_height": output.height,
                    "photo_width": photo_dimensions.0, "photo_height": photo_dimensions.1,
                    "working_width": size.working.0, "working_height": size.working.1,
                    "photo_crop_width": size.photo.0, "photo_crop_height": size.photo.1,
                    "source_width": source_width, "source_height": source_height,
                    "export_resolution": export_resolution,
                    "raw": spektrafilm_io::is_raw(&input), "backend": used_backend,
                    "input_colour": input_colour,
                    "lens_correction_supported": lens_correction_supported,
                    "output_color_space": encoding.space.name,
                    "display_color_space": DisplaySpace::of(encoding).name(),
                    "elapsed_ms": started.elapsed().as_secs_f64() * 1000.0,
                    "film_histogram": histogram,
                    "cached_pipeline": cached_pipeline, "pipeline_ms": pipeline_ms,
                    "refining": refining,
                });
                let mut response = response;
                if let Some(window) = window {
                    response["region"] = json!([window.x, window.y, window.width, window.height]);
                }
                if let Some(fit) = self.as_shot_fit.as_ref().filter(|f| f.path == input && f.generation == source_generation) {
                    response["as_shot_balance"] = json!([fit.as_shot.0, fit.as_shot.1]);
                    response["auto_balance"] = fit.auto.map_or(Value::Null, |(t, g)| json!([t, g]));
                }
                self.output = Some(Rendered {
                    id: request.id,
                    key: render_key,
                    response: response.clone(),
                    source: input,
                    film,
                    encoding,
                    post,
                    image: output,
                });
                Ok(response)
            }
        }
    }
}

/// References are small, upright, complete camera frames. Decode their ICC/
/// transfer metadata through the same colour-managed loader as other images;
/// the solver receives linear sRGB, never encoded PNG samples mistaken for light.
fn placement_reference(path: &Path, source: &ImageBuf) -> Result<ImageBuf> {
    let metadata = std::fs::metadata(path).context("Reading camera-preview reference")?;
    ensure!(metadata.is_file() && metadata.len() <= 32 * 1024 * 1024,
        "The camera-preview reference must be a PNG smaller than 32 MB");
    let reader = image::ImageReader::open(path)?.with_guessed_format()?;
    ensure!(reader.format() == Some(image::ImageFormat::Png), "The camera-preview reference must be a PNG");
    let (width, height) = reader.into_dimensions()?;
    ensure!((2..=2048).contains(&width) && (2..=2048).contains(&height),
        "The camera-preview reference must be between 2 and 2048 pixels on each side");
    let reference = spektrafilm_io::load_image(path, spektrafilm_io::Formats::Any)?;
    let aspect = reference.width as f64 / reference.height as f64;
    let source_aspect = source.width as f64 / source.height as f64;
    ensure!((aspect / source_aspect - 1.0).abs() <= 0.02,
        "The camera-preview reference must show the whole photograph with matching orientation");
    ensure!(reference.data.iter().all(|v| v.is_finite()), "The camera-preview reference contains invalid pixels");
    Ok(reference)
}

/// A request line. Params from before `io.input_interpretation` keep the
/// meaning of their input fields; see `infer_input_interpretation`.
fn parse_request(line: &str) -> Result<Request> {
    let mut value: Value = serde_json::from_str(line)?;
    if let Some(params) = value.get_mut("params") {
        spektrafilm_core::params::infer_input_interpretation(params);
    }
    Ok(serde_json::from_value(value)?)
}

/// Writes the preview for the app as raw RGBA, avoiding PNG compression on
/// every slider edit. Save keeps the float output, independent of this proxy.
/// The bytes are in `DisplaySpace::of(encoding)`.
fn write_display(
    image: &ImageBuf,
    encoding: Encoding,
    post: &PostParams,
    path: &Path,
) -> Result<(usize, usize)> {
    let post = (!post.is_identity()).then(|| PostProcess::new(post, encoding.encoded, encoding.space.name));
    let (width, height, bytes) =
        display_rgba_with_post(image, DISPLAY_MAX_DIM, encoding, post.as_ref());
    std::fs::write(path, bytes).context("Writing preview buffer")?;
    Ok((width, height))
}

/// A calibrated pipeline for `film` printed on `paper` (or scanned).
fn build_pipeline(data: &Path, film: &str, paper: &str, params: &RuntimeParams) -> Result<Pipeline> {
    let film_profile = profile::load_profile_by_name(data, film)?;
    let print_profile = profile::load_profile_by_name(data, if params.io.scan_film { film } else { paper })?;
    Pipeline::new_with_spectral(film_profile, print_profile, params.clone(), data).map_err(anyhow::Error::msg)
}

/// The source at `dimensions`. A resampled copy is kept until the source or
/// the size changes, so ordinary edits don't resample the full image again.
fn working_source<'a>(
    source: &'a ImageBuf,
    scaled: &'a mut Option<((u32, u32), ImageBuf)>,
    dimensions: (u32, u32),
    resample: fn(&ImageBuf, (u32, u32)) -> ImageBuf,
) -> &'a ImageBuf {
    if dimensions == (source.width, source.height) {
        *scaled = None;
        return source;
    }
    if scaled.as_ref().is_none_or(|(size, _)| *size != dimensions) {
        *scaled = None; // release the previous size before allocating
        *scaled = Some((dimensions, resample(source, dimensions)));
    }
    &scaled.as_ref().unwrap().1
}

fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();
    let args: Vec<_> = std::env::args_os().collect();
    if args.len() != 3 || args[1] != "--data-dir" {
        bail!("Usage: spektrafilm-native --data-dir PATH");
    }
    let data = PathBuf::from(&args[2]);
    let mut session = Session::default();
    let mut stdout = std::io::stdout().lock();
    for line in std::io::stdin().lock().lines() {
        let line = line?;
        let id = serde_json::from_str::<Value>(&line)
            .ok()
            .and_then(|v| v["id"].as_u64())
            .unwrap_or(0);
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> Result<Value> {
            session.handle(parse_request(&line)?, &data)
        }))
        .unwrap_or_else(|_| {
            // A panicked GPU/decoder may have invalidated its cached state.
            session = Session::default();
            Err(anyhow::anyhow!(
                "The image engine failed. Try a different image or settings."
            ))
        });
        let response = match result {
            Ok(result) => json!({"id": id, "result": result}),
            Err(error) => json!({"id": id, "error": format!("{error:#}")}),
        };
        serde_json::to_writer(&mut stdout, &response)?;
        writeln!(stdout)?;
        stdout.flush()?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    /// The app names the same commands (EngineCommand.swift); both sides check against commands.txt.
    #[test]
    fn commands_match_the_shared_list() {
        let list = include_str!("../commands.txt");
        let names: Vec<&str> = list.lines().map(str::trim).filter(|l| !l.is_empty() && !l.starts_with('#')).collect();
        for name in &names {
            let error = serde_json::from_str::<Command>(&format!(r#"{{"command":"{name}"}}"#)).err().map(|e| e.to_string());
            assert!(!error.as_deref().unwrap_or("").contains("unknown variant"), "the helper doesn't know `{name}`");
        }
        // Every variant is listed: an unknown name's error lists the variants serde expects.
        let error = serde_json::from_str::<Command>(r#"{"command":"no_such_command"}"#).err().unwrap().to_string();
        for name in &names {
            assert!(error.contains(&format!("`{name}`")), "`{name}` missing from the helper's variants: {error}");
        }
        assert_eq!(error.matches('`').count() / 2 - 1, names.len(), "the helper has commands commands.txt doesn't list: {error}");
    }

    // Qlick Lab: the white balance fit.
    #[test]
    fn white_balance_fit_recovers_a_balance() {
        let truth = custom_matrix(4800.0, 1.08).unwrap();
        // Daylight pixels, varied, and what that balance makes of them.
        let mut pairs = Vec::new();
        for i in 0..400 {
            let d = [0.05 + (i % 7) as f64 * 0.05, 0.08 + (i % 11) as f64 * 0.03, 0.04 + (i % 13) as f64 * 0.025];
            let a: Vec<f64> = (0..3).map(|r| truth[r][0] * d[0] + truth[r][1] * d[1] + truth[r][2] * d[2]).collect();
            pairs.push((d, [a[0], a[1], a[2]]));
        }
        let (matrix, weights) = fit_matrix(&pairs).unwrap();
        for r in 0..3 {
            for c in 0..3 {
                assert!((matrix[r][c] - truth[r][c]).abs() < 1e-9, "{matrix:?} {truth:?}");
            }
        }
        let (temperature, tint) = search_balance(|m| {
            let mut cost = 0.0;
            for r in 0..3 {
                for i in 0..3 {
                    for j in 0..3 {
                        cost += (m[r][i] - matrix[r][i]) * weights[i][j] * (m[r][j] - matrix[r][j]);
                    }
                }
            }
            cost
        })
        .unwrap();
        assert!((temperature - 4800.0).abs() < 15.0, "{temperature}");
        assert!((tint - 1.08).abs() < 0.01, "{tint}");
        let inverse = invert3(truth).unwrap();
        for r in 0..3 {
            for c in 0..3 {
                let product: f64 = (0..3).map(|k| truth[r][k] * inverse[k][c]).sum();
                assert!((product - if r == c { 1.0 } else { 0.0 }).abs() < 1e-9);
            }
        }
    }

    use super::*;
    #[test]
    fn brightness_reference_is_independent_and_refuses_to_replace_the_photo() {
        let dir = std::env::temp_dir().join(format!("qlick-reference-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let input = dir.join("input.png");
        let source = ImageBuf::from_data(4, 2, [0.2, 0.5, 0.8].repeat(8));
        spektrafilm_io::save_image(&source, &input, None).unwrap();
        let before = std::fs::read(&input).unwrap();
        let mut session = Session {
            source_generation: 31,
            output: Some(Rendered { id: 7, key: Value::Null, response: Value::Null,
                source: input.clone(), film: "kodak_gold_200".into(), encoding: Encoding::from(true),
                post: PostParams::default(), image: source.clone() }),
            ..Default::default()
        };
        let output = dir.join("reference.png");
        let command = |reference_path| Command::BrightnessReference {
            input: input.clone(), reference_path, expected_width: 4, expected_height: 2,
        };
        let result = session.handle(Request { id: 8, command: command(output.clone()) }, Path::new(".")).unwrap();
        assert_eq!((result["usable"].as_bool(), result["width"].as_u64(), result["height"].as_u64()),
            (Some(true), Some(4), Some(2)));
        assert!(session.source.is_none() && !session.pipelines.has_main());
        assert_eq!(session.source_generation, 31);
        let retained = session.output.as_ref().unwrap();
        assert_eq!(retained.id, 7);
        assert_eq!(retained.image.data, source.data);
        let reference = placement_reference(&output, &source).unwrap();
        assert_eq!(reference.width, 4);
        let error = session.handle(Request { id: 9, command: command(input.clone()) }, Path::new(".")).unwrap_err();
        assert!(error.to_string().contains("must not replace"));
        assert_eq!(std::fs::read(&input).unwrap(), before);
        let alpha = dir.join("alpha.png");
        image::RgbaImage::from_pixel(4, 2, image::Rgba([128, 128, 128, 255])).save(&alpha).unwrap();
        let unsuitable = session.handle(Request { id: 10, command: Command::BrightnessReference {
            input: alpha, reference_path: output, expected_width: 4, expected_height: 2,
        } }, Path::new(".")).unwrap();
        assert_eq!(unsuitable["usable"], false);
        assert_eq!(unsuitable["for_photo"], true);
        assert_eq!(unsuitable["reason"], "Transparent images can’t be matched.");
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn bw_expansion_catalog_keeps_negative_reversal_and_paper_distinct() {
        let data = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../data");
        let result = catalog(&data).unwrap();
        let profiles = result["profiles"].as_array().unwrap();
        let stock = |id: &str| profiles.iter().find(|p| p["id"] == id).unwrap();
        let film = stock("kodak_trix400_d76_8min");
        let paper = stock("ilford_mgrc_deluxe_grade2");
        assert_eq!(film["paper"], false);
        assert_eq!(film["positive"], false);
        assert_eq!(film["target_print"], paper["id"]);
        assert_eq!(paper["paper"], true);
        assert_eq!(paper["bw"], true);
        assert_eq!(stock("kodak_trix")["positive"], true);
    }
    #[test]
    fn catalog_marks_fotufilm_ports_and_their_sampled_films() {
        let data = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../data");
        let result = catalog(&data).unwrap();
        let profiles = result["profiles"].as_array().unwrap();
        let provenance = |p: &Value| (p["fotufilm"].as_bool().unwrap(), p["manufacturer_data"].as_bool().unwrap());
        let fotufilm: Vec<_> = profiles.iter().filter(|p| provenance(p).0).collect();
        let sampled: Vec<_> = fotufilm.iter().filter(|p| !provenance(p).1).map(|p| p["id"].as_str().unwrap()).collect();
        assert_eq!(fotufilm.len(), 29);
        assert_eq!(sampled.len(), 8, "{sampled:?}");
        assert!(sampled.contains(&"cinestill_400d") && !sampled.contains(&"fujifilm_superia_200"));
        // Spektrafilm's own profiles are from manufacturer data.
        assert!(profiles.iter().filter(|p| !provenance(p).0).all(|p| provenance(p).1));
    }
    #[test]
    fn presets_import_over_the_current_params_and_export() {
        let data = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../data");
        let mut session = Session::default();
        let mut current = RuntimeParams::default();
        current.io.photo_long_side_px = Some(2400);
        current.camera.exposure_compensation_ev = 1.0;
        let text = r#"{"simulation": {"film_stock": "kodak_portra_400", "route": "input > film > scan"},
                       "couplers": {"langmuir_donor_k_rgb": [Infinity, 1.0, 1.0]}}"#;
        let imported = session.handle(Request { id: 1, command: Command::PresetImport {
            text: text.into(), params: Some(Box::new(current)),
        } }, &data).unwrap();
        assert_eq!(imported["film"], "kodak_portra_400");
        assert_eq!(imported["params"]["io"]["photo_long_side_px"], 2400);
        assert_eq!(imported["params"]["io"]["scan_film"], true);
        assert_eq!(imported["params"]["camera"]["exposure_compensation_ev"], 0.0);
        assert_eq!(imported["params"]["film_render"]["dir_couplers"]["langmuir_donor_k_rgb"][0], Value::Null);
        let params: RuntimeParams = serde_json::from_value(imported["params"].clone()).unwrap();
        let exported = session.handle(Request { id: 2, command: Command::PresetExport {
            film: "kodak_portra_400".into(), paper: "kodak_supra_endura".into(), params: Box::new(params),
        } }, &data).unwrap();
        let text = exported["text"].as_str().unwrap();
        assert!(text.contains("Infinity"), "{text}");
        let refused = session.handle(Request { id: 3, command: Command::PresetImport {
            text: r#"{"simulation": {"film_stock": "kodak_unknown"}}"#.into(), params: None,
        } }, &data).unwrap_err();
        assert!(refused.to_string().contains("kodak_unknown"), "{refused}");
    }

    /// A preset's thumbnail is the thumbnail of what `preset_import` makes of
    /// it over the current params, and it leaves the main render alone.
    #[test]
    fn preset_thumbnails_apply_the_preset_like_preset_import() {
        let data = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../data");
        let dir = std::env::temp_dir().join(format!("qlick-preset-thumbnail-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let input = dir.join("input.png");
        let pixels = (0..48 * 32 * 3).map(|i| ((i * 37) % 255) as spektrafilm_math::Scalar / 255.0).collect();
        spektrafilm_io::save_image(&ImageBuf::from_data(48, 32, pixels), &input, None).unwrap();
        let text = r#"{"simulation": {"film_stock": "kodak_portra_400", "print_paper": "kodak_portra_endura"},
                       "camera": {"exposure_compensation_ev": 1.5}}"#;
        let mut current = RuntimeParams::default();
        current.io.output_color_space = "Display P3".into();
        current.camera.exposure_compensation_ev = -1.0;
        let mut session = Session::default();
        let thumbnail = |session: &mut Session, film: &str, paper: &str, params: RuntimeParams, preset: Option<&str>, name: &str| {
            let preview = dir.join(name);
            let response = session.handle(Request { id: 1, command: Command::Thumbnail {
                input: input.clone(), source_generation: 1, film: film.into(), paper: paper.into(),
                params: Box::new(params), long_side: 24, preview_path: preview.clone(), crop: None,
                preset: preset.map(str::to_string), reduced_decode: false, decode_only: false, preview_colour_space: false,
            } }, &data).unwrap();
            (response, std::fs::read(preview).unwrap())
        };
        let (response, with_preset) =
            thumbnail(&mut session, "kodak_gold_200", "kodak_supra_endura", current.clone(), Some(text), "preset.rgba");
        assert_eq!((response["width"].as_u64(), response["height"].as_u64()), (Some(24), Some(16)));
        // The photograph's colour space stays; the preset's look comes in.
        assert_eq!(response["display_color_space"], DisplaySpace::Rec2020SrgbTransfer.name());
        let imported = session.handle(Request { id: 2, command: Command::PresetImport {
            text: text.into(), params: Some(Box::new(current.clone())),
        } }, &data).unwrap();
        assert_eq!(imported["params"]["camera"]["exposure_compensation_ev"], 1.5);
        let params: RuntimeParams = serde_json::from_value(imported["params"].clone()).unwrap();
        let film = imported["film"].as_str().unwrap();
        let paper = imported["paper"].as_str().unwrap();
        let (_, applied) = thumbnail(&mut session, film, paper, params, None, "applied.rgba");
        assert_eq!(with_preset, applied);
        let (_, plain) = thumbnail(&mut session, "kodak_gold_200", "kodak_supra_endura", current, None, "plain.rgba");
        assert_ne!(with_preset, plain);
        assert!(session.output.is_none() && !session.pipelines.has_main());
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// A reduced read is never smaller than the frame a thumbnail develops,
    /// whatever the photograph's shape, and an uncropped one is exactly it.
    #[test]
    fn reduced_reads_cover_the_thumbnail_frame() {
        for full in [(6048, 4024), (4024, 6048), (8000, 2000), (1000, 1000), (300, 200)] {
            for crop in [None, Some((0.5, 0.5)), Some((0.9, 0.2)), Some((0.15, 0.8)), Some((0.01, 0.01))] {
                let crop = crop.map(|(width, height)| Crop { x: 0.0, y: 0.0, width, height, angle: 0.0 });
                for long_side in [16, 512, 1024] {
                    let read = reduced_read_side(long_side, crop.as_ref());
                    let (w, h) = thumbnail_dimensions(full, long_side, crop.as_ref());
                    assert!(read >= w.max(h) || read >= full.0.max(full.1), "{full:?} {crop:?} {long_side}: {read}");
                    assert!(read <= THUMBNAIL_FRAME_MAX);
                    if crop.is_none() && full.0.max(full.1) >= long_side {
                        assert_eq!(read, w.max(h));
                    }
                }
            }
        }
        let small = ImageBuf::new(512, 340);
        assert_eq!(within((512, 341), &small), (512, 340));
    }

    /// A non-RAW file is always read whole: the same thumbnail either way.
    #[test]
    fn a_reduced_read_of_a_non_raw_file_is_the_whole_file() {
        let data = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../data");
        let dir = std::env::temp_dir().join(format!("qlick-reduced-thumbnail-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let input = dir.join("input.png");
        let pixels = (0..48 * 32 * 3).map(|i| ((i * 37) % 255) as spektrafilm_math::Scalar / 255.0).collect();
        spektrafilm_io::save_image(&ImageBuf::from_data(48, 32, pixels), &input, None).unwrap();
        let mut session = Session::default();
        let mut thumbnail = |reduced_decode: bool| {
            let preview = dir.join(format!("{reduced_decode}.rgba"));
            let response = session.handle(Request { id: 1, command: Command::Thumbnail {
                input: input.clone(), source_generation: 1, film: "kodak_gold_200".into(),
                paper: "kodak_supra_endura".into(), params: Box::default(), long_side: 24,
                preview_path: preview.clone(), crop: None, preset: None, reduced_decode, decode_only: false,
                preview_colour_space: false,
            } }, &data).unwrap();
            (response, std::fs::read(preview).unwrap())
        };
        let (whole, whole_pixels) = thumbnail(false);
        let (reduced, reduced_pixels) = thumbnail(true);
        assert_eq!((reduced["source_width"].as_u64(), reduced["source_height"].as_u64()), (Some(48), Some(32)));
        assert_eq!(reduced["reduced_decode"], false);
        assert_eq!(whole["width"], reduced["width"]);
        assert!(whole_pixels == reduced_pixels);

        // Decoded alone: the size, no preview, and nothing declared.
        let preview = dir.join("decoded.rgba");
        let decoded = session.handle(Request { id: 1, command: Command::Thumbnail {
            input: input.clone(), source_generation: 2, film: "kodak_gold_200".into(),
            paper: "kodak_supra_endura".into(), params: Box::default(), long_side: 24,
            preview_path: preview.clone(), crop: None, preset: None, reduced_decode: true, decode_only: true,
            preview_colour_space: true,
        } }, &data).unwrap();
        assert_eq!((decoded["source_width"].as_u64(), decoded["source_height"].as_u64()), (Some(48), Some(32)));
        assert!(decoded["preview_colour_space"].is_null() && decoded.get("width").is_none());
        assert!(!preview.exists());
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// The match after a decode alone is the one after the whole thumbnail,
    /// and the colour space read beside the decode is `preview_colour_space`'s.
    #[cfg(target_os = "macos")]
    #[test]
    #[ignore = "requires a local camera RAW: set SPEKTRAFILM_RAW_TEST_FILE"]
    fn a_match_after_a_decode_alone_is_the_same() {
        let input = PathBuf::from(std::env::var_os("SPEKTRAFILM_RAW_TEST_FILE").expect("SPEKTRAFILM_RAW_TEST_FILE"));
        let data = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../data");
        let dir = std::env::temp_dir().join(format!("qlick-decode-only-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let mut params = RuntimeParams::default();
        params.io.output_color_space = "Display P3".into();
        let reference = dir.join("reference.png");
        let placed = |decode_only: bool| {
            let mut session = Session::default();
            let decoded = session.handle(Request { id: 1, command: Command::Thumbnail {
                input: input.clone(), source_generation: 1, film: "kodak_gold_200".into(),
                paper: "kodak_supra_endura".into(), params: Box::new(params.clone()), long_side: 512,
                preview_path: dir.join("thumbnail.rgba"), crop: None, preset: None, reduced_decode: true, decode_only,
                preview_colour_space: decode_only,
            } }, &data).unwrap();
            let (width, height) = (decoded["source_width"].as_u64().unwrap() as u32, decoded["source_height"].as_u64().unwrap() as u32);
            if !reference.exists() {
                session.handle(Request { id: 2, command: Command::BrightnessReference {
                    input: input.clone(), reference_path: reference.clone(), expected_width: width, expected_height: height,
                } }, &data).unwrap();
            }
            let placed = session.handle(Request { id: 3, command: Command::PlaceExposure {
                input: input.clone(), source_generation: 1, film: "kodak_gold_200".into(), paper: "kodak_supra_endura".into(),
                params: Box::new(params.clone()), reference_path: reference.clone(),
            } }, &data).unwrap();
            (decoded, placed)
        };
        let (_, whole) = placed(false);
        let (decoded, alone) = placed(true);
        assert_eq!(whole["exposure_ev"], alone["exposure_ev"]);
        assert_eq!(whole["highlight_limited"], alone["highlight_limited"]);
        let declared = Session::default().handle(Request { id: 4, command: Command::PreviewColourSpace { input: input.clone() } }, &data).unwrap();
        assert_eq!(decoded["preview_colour_space"], declared["colour_space"]);
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// Ticket 39: the editor solves a new photograph's match on a whole
    /// decode alone, before any render. The match is the one solved after
    /// the settled render, as before, with and without auto exposure.
    #[cfg(target_os = "macos")]
    #[test]
    #[ignore = "requires a local camera RAW: set SPEKTRAFILM_RAW_TEST_FILE"]
    fn the_editors_match_before_the_first_render_is_the_same() {
        let input = PathBuf::from(std::env::var_os("SPEKTRAFILM_RAW_TEST_FILE").expect("SPEKTRAFILM_RAW_TEST_FILE"));
        let data = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../data");
        let dir = std::env::temp_dir().join(format!("qlick-match-first-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let reference = dir.join("reference.png");
        for auto_exposure in [true, false] {
            let mut params = RuntimeParams::default();
            params.camera.auto_exposure = auto_exposure;
            let placed = |decode_first: bool| {
                let mut session = Session::default();
                let (width, height) = if decode_first {
                    let decoded = session.handle(Request { id: 1, command: Command::Thumbnail {
                        input: input.clone(), source_generation: 1, film: "kodak_gold_200".into(),
                        paper: "kodak_supra_endura".into(), params: Box::new(params.clone()), long_side: 16,
                        preview_path: dir.join("decode.rgba"), crop: None, preset: None, reduced_decode: false, decode_only: true,
                        preview_colour_space: true,
                    } }, &data).unwrap();
                    assert_eq!(decoded["raw"].as_bool(), Some(true));
                    (decoded["source_width"].as_u64().unwrap() as u32, decoded["source_height"].as_u64().unwrap() as u32)
                } else {
                    let rendered = session.handle(Request { id: 1, command: Command::Render {
                        input: input.clone(), source_generation: 1, film: "kodak_gold_200".into(),
                        paper: "kodak_supra_endura".into(), params: Box::new(params.clone()), limit_preview: false,
                        preview_path: dir.join("render.rgba"), interactive_scale: None, crop: None, read_long_side: None, region: None,
                    } }, &data).unwrap();
                    (rendered["source_width"].as_u64().unwrap() as u32, rendered["source_height"].as_u64().unwrap() as u32)
                };
                if !reference.exists() {
                    session.handle(Request { id: 2, command: Command::BrightnessReference {
                        input: input.clone(), reference_path: reference.clone(), expected_width: width, expected_height: height,
                    } }, &data).unwrap();
                }
                let placed = session.handle(Request { id: 3, command: Command::PlaceExposure {
                    input: input.clone(), source_generation: 1, film: "kodak_gold_200".into(), paper: "kodak_supra_endura".into(),
                    params: Box::new(params.clone()), reference_path: reference.clone(),
                } }, &data).unwrap();
                ((width, height), placed)
            };
            let (size, rendered) = placed(false);
            let (decoded_size, decoded) = placed(true);
            assert_eq!(size, decoded_size);
            assert_eq!(rendered["exposure_ev"], decoded["exposure_ev"], "auto exposure {auto_exposure}");
            assert_eq!(rendered["highlight_limited"], decoded["highlight_limited"]);
        }
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// A reduced read reports the whole photograph's size, and anything that
    /// needs more of it decodes again; a whole source serves a reduced request.
    #[cfg(target_os = "macos")]
    #[test]
    #[ignore = "requires a local camera RAW: set SPEKTRAFILM_RAW_TEST_FILE"]
    fn a_reduced_read_is_decoded_again_for_more() {
        let input = PathBuf::from(std::env::var_os("SPEKTRAFILM_RAW_TEST_FILE").expect("SPEKTRAFILM_RAW_TEST_FILE"));
        let data = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../data");
        let dir = std::env::temp_dir().join(format!("qlick-reduced-raw-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let mut session = Session::default();
        let mut thumbnail = |long_side: u32, reduced_decode: bool| {
            session.handle(Request { id: 1, command: Command::Thumbnail {
                input: input.clone(), source_generation: 1, film: "kodak_gold_200".into(),
                paper: "kodak_supra_endura".into(), params: Box::default(), long_side,
                preview_path: dir.join("thumbnail.rgba"), crop: None, preset: None, reduced_decode, decode_only: false,
                preview_colour_space: false,
            } }, &data).unwrap()
        };
        let reduced = thumbnail(256, true);
        assert_eq!(reduced["reduced_decode"], true);
        // Smaller than the read: no new decode.
        assert_eq!(thumbnail(128, true)["timing_ms"]["decode"].as_f64().map(|ms| ms < 5.0), Some(true));
        assert_eq!(thumbnail(512, true)["reduced_decode"], true);
        let whole = thumbnail(256, false);
        assert_eq!(whole["reduced_decode"], false);
        assert_eq!(
            (reduced["source_width"].clone(), reduced["source_height"].clone()),
            (whole["source_width"].clone(), whole["source_height"].clone())
        );
        assert_eq!((reduced["width"].clone(), reduced["height"].clone()), (whole["width"].clone(), whole["height"].clone()));
        assert_eq!(thumbnail(256, true)["reduced_decode"], false);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn linear_display_is_encoded_without_mutating_output() {
        let image = ImageBuf::from_data(1, 1, vec![0.0, 0.18, 1.0]);
        assert_eq!(
            display_rgba(&image, DISPLAY_MAX_DIM, false).2,
            vec![0, 118, 255, 255]
        );
        assert_eq!(
            display_rgba(&image, DISPLAY_MAX_DIM, true).2,
            vec![0, 46, 255, 255]
        );
        assert_eq!(image.data[1], 0.18);
    }
    #[test]
    fn original_keeps_the_render_available_for_save() {
        let dir = std::env::temp_dir().join(format!("qlick-original-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let input = dir.join("input.png");
        let preview = dir.join("original.rgba");
        let source = ImageBuf::from_data(2, 1, vec![0.0, 0.5, 1.0, 1.0, 0.5, 0.0]);
        spektrafilm_io::save_image(&source, &input, None).unwrap();
        let mut session = Session {
            output: Some(Rendered { id: 7, key: Value::Null, response: Value::Null,
                source: input.clone(), film: "kodak_gold_200".into(), encoding: Encoding::from(true),
                post: PostParams::default(), image: source.clone() }),
            ..Default::default()
        };
        let params = Box::new(RuntimeParams::default());
        let response = session.handle(Request { id: 8, command: Command::Original {
            input: input.clone(), params, limit_preview: false, preview_path: preview.clone(),
        } }, Path::new(".")).unwrap();
        assert_eq!(response["width"], 2);
        assert_eq!(response["height"], 1);
        assert_eq!(std::fs::read(preview).unwrap().len(), 8);
        let retained = session.output.as_ref().unwrap();
        assert_eq!(retained.id, 7);
        assert_eq!(retained.image.data, source.data);
        let saved = dir.join("saved.png");
        session.handle(Request { id: 9, command: Command::Save {
            render_id: 7, output: saved.clone(), save_options: Default::default(), crop_after_post: false, border: None,
            border_options: BorderOptions::default(), instagram: false,
            crop: None, rotate_cw: 0, fit: None,
        } }, Path::new(".")).unwrap();
        assert_eq!(std::fs::read(input).unwrap(), std::fs::read(saved).unwrap());
        // Another colour space converts the sRGB render and carries its profile.
        let wide = dir.join("wide.png");
        let save_options = spektrafilm_io::save::SaveOptions {
            bit_depth: Some(16), color_space: "Display P3".into(), ..Default::default()
        };
        session.handle(Request { id: 10, command: Command::Save {
            render_id: 7, output: wide.clone(), save_options, crop_after_post: false, border: None,
            border_options: BorderOptions::default(), instagram: false,
            crop: None, rotate_cw: 0, fit: None,
        } }, Path::new(".")).unwrap();
        let mut decoder = image::ImageReader::open(&wide).unwrap().into_decoder().unwrap();
        let icc = image::ImageDecoder::icc_profile(&mut decoder).unwrap().unwrap();
        let p3 = RgbColourspace::find("Display P3").unwrap();
        assert_eq!(icc, spektrafilm_io::icc::profile(p3, false));
        let pixels = image::DynamicImage::from_decoder(decoder).unwrap().to_rgb16().into_raw();
        // sRGB's (0, 0.5, 1) and (1, 0.5, 0) lie inside Display P3's primaries.
        assert!(pixels[0] > 0 && pixels[2] < 65535, "{pixels:?}");
        assert!(pixels[3] < 65535 && pixels[5] > 0, "{pixels:?}");
        std::fs::remove_dir_all(dir).unwrap();
    }
    /// Qlick Lab: a part of the frame developed alone is that part of the whole frame's
    /// develop: the same light from beyond its edges (halation, couplers), the same
    /// grains, the same exposure, Prep's whole-frame base included. Without grain the two
    /// are one picture. With it, a density that differs in its last bits (the blurs sum
    /// other neighbours) now and then draws another count of grains: a few values in a
    /// thousand, grain for grain, and nothing the eye can place.
    #[test]
    fn a_part_of_the_frame_is_developed_as_in_the_whole() {
        let data = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../data");
        let dir = std::env::temp_dir().join(format!("qlick-region-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let (input, preview) = (dir.join("input.tiff"), dir.join("preview.rgba"));
        // A gradient, fine texture, hard edges and small bright lights: something for every blur to carry.
        let (width, height) = (2400u32, 1600u32);
        let mut pixels = Vec::with_capacity((width * height * 3) as usize);
        for y in 0..height {
            for x in 0..width {
                let hash = (x.wrapping_mul(2654435761) ^ y.wrapping_mul(40503)).wrapping_mul(2246822519) >> 24;
                let mut v = 0.04 + 0.5 * (x as f32 / width as f32) * (y as f32 / height as f32) + hash as f32 / 255.0 * 0.05;
                if (x / 160 + y / 160) % 2 == 0 {
                    v *= 0.45;
                }
                if x % 400 < 6 && y % 400 < 6 {
                    v = 1.0;
                }
                pixels.extend([v, v * 0.9, v * 0.8].map(|c| c as spektrafilm_math::Scalar));
            }
        }
        spektrafilm_io::save_image(&ImageBuf::from_data(width, height, pixels), &input, None).unwrap();
        let Command::Render { params, .. } = render(&input, &preview, None, None, None) else { unreachable!() };
        let command = |params: &RuntimeParams, region| Command::Render {
            input: input.clone(), source_generation: 1, film: "kodak_portra_400".into(),
            paper: "kodak_portra_endura".into(), params: Box::new(params.clone()), limit_preview: false,
            preview_path: preview.clone(), interactive_scale: None, crop: None, read_long_side: None, region,
        };
        for (name, grain, prep) in [("no grain", false, false), ("grain", true, false), ("grain and Prep", true, true)] {
            let mut params = (*params).clone();
            params.film_render.grain.active = grain;
            if prep {
                params.prep.contrast = 25.0;
                params.prep.shadows = 30.0;
            }
            let mut session = Session::default();
            let response = session.handle(Request { id: 1, command: command(&params, None) }, &data).unwrap();
            assert!(response.get("region").is_none());
            let whole = session.output.as_ref().unwrap().image.clone();
            assert_eq!((whole.width, whole.height), (width, height));
            for region in [[0.4, 0.35, 0.2, 0.25], [0.0, 0.0, 0.3, 0.2], [0.75, 0.7, 0.25, 0.3]] {
                let response = session.handle(Request { id: 2, command: command(&params, Some(region)) }, &data).unwrap();
                let [x, y, w, h]: [u32; 4] = serde_json::from_value(response["region"].clone()).expect("a part was developed");
                assert_eq!(response["export_resolution"], false);
                assert_eq!((response["output_width"].as_u64(), response["output_height"].as_u64()), (Some(w.into()), Some(h.into())));
                let part = &session.output.as_ref().unwrap().image;
                let (mut worst, mut squares, mut over) = (0.0f64, 0.0f64, 0usize);
                for row in 0..h {
                    for column in 0..w {
                        for c in 0..3 {
                            let a = f64::from(part.data[part.idx(column, row, c)] as f32).clamp(0.0, 1.0);
                            let b = f64::from(whole.data[whole.idx(x + column, y + row, c)] as f32).clamp(0.0, 1.0);
                            let difference = (a - b).abs() * 255.0;
                            worst = worst.max(difference);
                            squares += difference * difference;
                            over += usize::from(difference > 1.0);
                        }
                    }
                }
                let values = (w * h * 3) as f64;
                let (rms, over) = ((squares / values).sqrt(), over as f64 / values);
                eprintln!("{name}, {region:?} → {x},{y} {w}×{h}: rms {rms:.4} of 255, worst {worst:.3}, {:.4} % over a step", over * 100.0);
                if grain {
                    assert!(rms < 0.15 && over < 0.002, "{name}: a part differs from the whole: rms {rms}, {over} over a step");
                } else {
                    assert!(worst < 0.1, "{name}: a part differs from the whole: rms {rms}, worst {worst}");
                }
            }
        }
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// A Display P3 preview renders in P3 and shows through the Rec. 2020
    /// proxy; saving it as P3 writes the render's own values, and saving it
    /// as sRGB converts them. The original view shares the preview space.
    #[test]
    fn wide_preview_space_renders_and_saves_without_reconverting() {
        let data = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../data");
        let dir = std::env::temp_dir().join(format!("qlick-wide-preview-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let (input, preview) = (dir.join("input.png"), dir.join("preview.rgba"));
        let pixels = (0..24 * 16 * 3).map(|i| ((i * 37) % 255) as spektrafilm_math::Scalar / 255.0).collect();
        spektrafilm_io::save_image(&ImageBuf::from_data(24, 16, pixels), &input, None).unwrap();
        let mut session = Session::default();
        let Command::Render { mut params, .. } = render(&input, &preview, None, None, None) else { unreachable!() };
        params.io.output_color_space = "Display P3".into();
        params.settings.serial_grain = false;
        let command = |params: Box<RuntimeParams>| Command::Render {
            input: input.clone(), source_generation: 1, film: "kodak_portra_400".into(),
            paper: "kodak_portra_endura".into(), params, limit_preview: false,
            preview_path: preview.clone(), interactive_scale: None, crop: None, read_long_side: None, region: None,
        };
        let response = session.handle(Request { id: 1, command: command(params.clone()) }, &data).unwrap();
        assert_eq!(response["output_color_space"], "Display P3");
        assert_eq!(response["display_color_space"], DisplaySpace::Rec2020SrgbTransfer.name());
        let rendered = session.output.as_ref().unwrap();
        assert_eq!(rendered.encoding, Encoding::new("Display P3", true));
        let mut clipped = rendered.image.clone();
        spektrafilm_core::pipeline::clip_to_display(&mut clipped, true);

        let save = |session: &mut Session, name: &str, space: &str| {
            let output = dir.join(name);
            let save_options = spektrafilm_io::save::SaveOptions {
                bit_depth: Some(16), color_space: space.into(), ..Default::default()
            };
            session.handle(Request { id: 2, command: Command::Save {
                render_id: 1, output: output.clone(), save_options, crop_after_post: false, border: None,
                border_options: BorderOptions::default(), instagram: false, crop: None, rotate_cw: 0, fit: None,
            } }, &data).unwrap();
            image::open(&output).unwrap().to_rgb16().into_raw()
        };
        let p3 = save(&mut session, "p3.png", "Display P3");
        for (saved, want) in p3.iter().zip(&clipped.data) {
            assert!((f64::from(*saved) / 65535.0 - f64::from(*want)).abs() <= 0.5 / 65535.0 + 1e-6);
        }
        let srgb = save(&mut session, "srgb.png", "sRGB");
        let mut converted = clipped.clone();
        convert_output(&mut converted, "Display P3", "sRGB", true);
        for (saved, want) in srgb.iter().zip(&converted.data) {
            assert!((f64::from(*saved) / 65535.0 - f64::from(*want)).abs() <= 0.5 / 65535.0 + 1e-6);
        }
        assert_ne!(p3, srgb);

        let original = session.handle(Request { id: 3, command: Command::Original {
            input: input.clone(), params, limit_preview: false, preview_path: dir.join("original.rgba"),
        } }, &data).unwrap();
        assert_eq!(original["display_color_space"], DisplaySpace::Rec2020SrgbTransfer.name());
        std::fs::remove_dir_all(dir).unwrap();
    }

    fn render(input: &Path, preview: &Path, target: Option<u32>, crop: Option<Crop>, interactive_scale: Option<f32>) -> Command {
        let mut params = RuntimeParams::default();
        params.io.photo_long_side_px = target;
        Command::Render {
            input: input.into(), source_generation: 1, film: "kodak_portra_400".into(),
            paper: "kodak_portra_endura".into(), params: Box::new(params), limit_preview: false,
            preview_path: preview.into(), interactive_scale, crop, read_long_side: None, region: None,
        }
    }

    /// The app renders a film change at canvas size first (ticket 28): the
    /// export-size render that follows matches one made without that step,
    /// in the kept output and in the display buffer.
    #[test]
    fn a_quick_frame_before_a_film_change_leaves_its_settled_render_unchanged() {
        let data = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../data");
        let dir = std::env::temp_dir().join(format!("qlick-quick-frame-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let (input, preview) = (dir.join("input.png"), dir.join("preview.rgba"));
        let pixels = (0..96 * 64 * 3).map(|i| ((i * 37) % 255) as spektrafilm_math::Scalar / 255.0).collect();
        spektrafilm_io::save_image(&ImageBuf::from_data(96, 64, pixels), &input, None).unwrap();
        let with_film = |film: &str, interactive_scale: Option<f32>| {
            let Command::Render { mut params, .. } = render(&input, &preview, None, None, None) else { unreachable!() };
            params.settings.serial_grain = false;
            Command::Render {
                input: input.clone(), source_generation: 1, film: film.into(), paper: "kodak_portra_endura".into(),
                params, limit_preview: false, preview_path: preview.clone(), interactive_scale, crop: None, read_long_side: None, region: None,
            }
        };
        let settled = |quick_first: bool| {
            let mut session = Session::default();
            session.handle(Request { id: 1, command: with_film("kodak_portra_400", None) }, &data).unwrap();
            if quick_first {
                let quick = session.handle(Request { id: 2, command: with_film("kodak_gold_200", Some(0.5)) }, &data).unwrap();
                assert_eq!(quick["output_width"].as_u64(), Some(48));
                assert_eq!(quick["export_resolution"].as_bool(), Some(false));
            }
            let response = session.handle(Request { id: 3, command: with_film("kodak_gold_200", None) }, &data).unwrap();
            assert_eq!(response["export_resolution"].as_bool(), Some(true));
            (session.output.unwrap().image.data, std::fs::read(&preview).unwrap())
        };
        let (direct, direct_display) = settled(false);
        let (after_quick, after_quick_display) = settled(true);
        assert!(direct == after_quick, "the settled render differs after a quick frame");
        assert!(direct_display == after_quick_display, "the display buffer differs after a quick frame");
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// Ticket 39: a photograph's first frame comes after a decode alone (the
    /// whole photograph) and a quick frame. Its settled render matches the
    /// one a fresh helper renders straight away, in the kept output and the
    /// display buffer, and the decode reports the size and RAW-ness the
    /// render does.
    #[test]
    fn a_first_frame_after_a_decode_alone_and_a_quick_frame_is_unchanged() {
        let data = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../data");
        let dir = std::env::temp_dir().join(format!("qlick-decode-first-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let (input, preview) = (dir.join("input.png"), dir.join("preview.rgba"));
        let pixels = (0..96 * 64 * 3).map(|i| ((i * 53) % 255) as spektrafilm_math::Scalar / 255.0).collect();
        spektrafilm_io::save_image(&ImageBuf::from_data(96, 64, pixels), &input, None).unwrap();
        let command = |interactive_scale: Option<f32>| {
            let Command::Render { mut params, .. } = render(&input, &preview, None, None, None) else { unreachable!() };
            params.settings.serial_grain = false;
            Command::Render {
                input: input.clone(), source_generation: 1, film: "kodak_gold_200".into(), paper: "kodak_portra_endura".into(),
                params, limit_preview: false, preview_path: preview.clone(), interactive_scale, crop: None, read_long_side: None, region: None,
            }
        };
        let settled = |decode_first: bool| {
            let mut session = Session::default();
            if decode_first {
                let Command::Render { params, .. } = command(None) else { unreachable!() };
                let decoded = session.handle(Request { id: 1, command: Command::Thumbnail {
                    input: input.clone(), source_generation: 1, film: "kodak_gold_200".into(),
                    paper: "kodak_portra_endura".into(), params, long_side: 16,
                    preview_path: dir.join("decode.rgba"), crop: None, preset: None, reduced_decode: false, decode_only: true,
                    preview_colour_space: false,
                } }, &data).unwrap();
                assert_eq!((decoded["source_width"].as_u64(), decoded["source_height"].as_u64()), (Some(96), Some(64)));
                assert_eq!(decoded["raw"].as_bool(), Some(false));
                assert!(session.thumbnail_source.is_none(), "a decode alone shrinks nothing");
                session.handle(Request { id: 2, command: command(Some(0.5)) }, &data).unwrap();
            }
            let response = session.handle(Request { id: 3, command: command(None) }, &data).unwrap();
            assert_eq!(response["export_resolution"].as_bool(), Some(true));
            assert_eq!(response["raw"].as_bool(), Some(false));
            (session.output.unwrap().image.data, std::fs::read(&preview).unwrap(), response["film_histogram"].clone())
        };
        let (direct, direct_display, direct_histogram) = settled(false);
        let (after, after_display, after_histogram) = settled(true);
        assert!(direct == after, "the settled render differs after a decode alone");
        assert!(direct_display == after_display, "the display buffer differs after a decode alone");
        assert_eq!(direct_histogram, after_histogram);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn image_size_renders_report_sizes_reuse_pans_and_keep_drags_within_the_source() {
        let data = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../data");
        let dir = std::env::temp_dir().join(format!("qlick-image-size-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let (input, preview) = (dir.join("input.png"), dir.join("preview.rgba"));
        let pixels = (0..40 * 30 * 3).map(|i| ((i * 37) % 255) as spektrafilm_math::Scalar / 255.0).collect();
        spektrafilm_io::save_image(&ImageBuf::from_data(40, 30, pixels), &input, None).unwrap();
        let mut session = Session::default();
        let mut send = |id, command| session.handle(Request { id, command }, &data);

        // A centred half-extent crop at 60 px develops the whole frame at 120 × 90.
        let centre = Crop { x: 0.25, y: 0.25, width: 0.5, height: 0.5, angle: 0.0 };
        let full = send(1, render(&input, &preview, Some(60), Some(centre), None)).unwrap();
        assert_eq!((full["working_width"].as_u64(), full["working_height"].as_u64()), (Some(120), Some(90)));
        assert_eq!((full["photo_crop_width"].as_u64(), full["photo_crop_height"].as_u64()), (Some(60), Some(45)));
        assert_eq!((full["output_width"].as_u64(), full["source_width"].as_u64()), (Some(120), Some(40)));
        assert_eq!(full["export_resolution"], true);
        drop(send);
        let image = session.output.as_ref().unwrap().image.data.as_ptr();

        // Panning the crop reuses the simulation and reports its own pixels.
        let mut send = |id, command| session.handle(Request { id, command }, &data);
        let panned = Crop { x: 0.2, y: 0.3, ..centre };
        let reused = send(2, render(&input, &preview, Some(60), Some(panned), None)).unwrap();
        assert_eq!(reused["photo_crop_width"].as_u64(), Some(60));
        assert_eq!(reused["output_width"].as_u64(), Some(120));
        drop(send);
        let retained = session.output.as_ref().unwrap();
        assert_eq!((retained.id, retained.image.data.as_ptr()), (2, image));

        // Zoomed past fit on a 3x enlargement, a drag frame stays inside the
        // source and is never saved as an export.
        let mut send = |id, command| session.handle(Request { id, command }, &data);
        let drag = send(3, render(&input, &preview, Some(120), None, Some(0.6))).unwrap();
        assert_eq!((drag["output_width"].as_u64(), drag["output_height"].as_u64()), (Some(40), Some(30)));
        assert_eq!(drag["export_resolution"], false);
        assert_eq!(drag["working_width"].as_u64(), Some(120));

        // Too large a request fails before allocation and keeps the last render.
        let speck = Crop { x: 0.5, y: 0.5, width: 0.002, height: 0.002, angle: 0.0 };
        let error = send(4, render(&input, &preview, Some(65_535), Some(speck), None)).unwrap_err().to_string();
        assert!(error.contains("MP limit"), "{error}");
        let mixed = {
            let Command::Render { mut params, .. } = render(&input, &preview, Some(60), None, None) else { unreachable!() };
            params.io.upscale_factor = 0.5;
            Command::Render { input: input.clone(), source_generation: 1, film: "kodak_portra_400".into(),
                paper: "kodak_portra_endura".into(), params, limit_preview: false, preview_path: preview.clone(),
                interactive_scale: None, crop: None, read_long_side: None, region: None }
        };
        assert!(send(5, mixed).unwrap_err().to_string().contains("factor must be 1"));
        // Original never enlarges, whatever the target.
        let original = send(6, Command::Original { input: input.clone(), params: {
            let mut params = RuntimeParams::default(); params.io.photo_long_side_px = Some(400); Box::new(params)
        }, limit_preview: false, preview_path: preview.clone() }).unwrap();
        assert_eq!((original["width"].as_u64(), original["height"].as_u64()), (Some(40), Some(30)));
        drop(send);
        assert_eq!(session.output.as_ref().unwrap().id, 3);
        assert_ne!(session.output.as_ref().unwrap().image.data.as_ptr(), image);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn working_source_is_resampled_once_per_size() {
        let source = ImageBuf::from_data(4, 2, vec![0.5; 24]);
        let mut scaled = None;
        let first = working_source(&source, &mut scaled, (2, 1), rescale_preview_input_fast)
            .data
            .as_ptr();
        assert_eq!(
            working_source(&source, &mut scaled, (2, 1), rescale_preview_input_fast)
                .data
                .as_ptr(),
            first
        );
        assert_eq!(
            working_source(&source, &mut scaled, (1, 1), rescale_preview_input_fast).width,
            1
        );
        let full = working_source(&source, &mut scaled, (4, 2), rescale_preview_input_fast);
        assert_eq!(full.data.as_ptr(), source.data.as_ptr());
        assert!(scaled.is_none());
    }
    #[test]
    fn save_reads_the_apps_border_options() {
        use spektrafilm_io::border::Rgb;
        // As `saveCommand` in the app's EditorModel writes it.
        let request: Request = serde_json::from_str(
            r##"{"id": 1, "command": "save", "render_id": 1, "output": "out.png", "rotate_cw": 0,
                "border": "white", "instagram": true,
                "border_options": {"width": 0.05, "line": 0.004, "color": "#1f2a44", "line_color": "#000000"}}"##,
        )
        .unwrap();
        let Command::Save {
            border,
            border_options,
            instagram,
            save_options,
            crop_after_post,
            ..
        } = request.command
        else {
            panic!("not a save")
        };
        assert_eq!(border, Some(BorderStyle::Solid));
        assert!(instagram);
        assert_eq!(save_options.jpeg_quality, 95);
        assert!(save_options.copy_metadata);
        assert_eq!(save_options.bit_depth, None);
        assert_eq!(save_options.color_space, "sRGB");
        assert!(!crop_after_post, "existing clients retain their original Post/crop order");
        assert_eq!(
            border_options,
            BorderOptions {
                width: Some(0.05),
                color: Rgb([0x1f, 0x2a, 0x44]),
                ..Default::default()
            }
        );
    }

    #[test]
    fn stale_preview_cannot_be_saved() {
        let mut session = Session {
            output: Some(Rendered {
                id: 2,
                key: Value::Null,
                response: Value::Null,
                source: "source.png".into(),
                film: "kodak_gold_200".into(),
                encoding: Encoding::from(true),
                post: PostParams::default(),
                image: ImageBuf::from_data(1, 1, vec![0.0; 3]),
            }),
            ..Default::default()
        };
        let request = Request {
            id: 3,
            command: Command::Save {
                render_id: 1,
                output: "unused.png".into(),
                save_options: Default::default(),
                crop_after_post: false,
                border: None,
                border_options: BorderOptions::default(),
                instagram: false,
                crop: None,
                rotate_cw: 0,
                fit: None,
            },
        };
        assert!(
            session
                .handle(request, Path::new("."))
                .unwrap_err()
                .to_string()
                .contains("preview changed")
        );
    }
}
