//! Qlick Lab: a RAW's proxy. Its Daylight read reduced to `PROXY_LONG` pixels, with its As Shot fit, kept on disk
//! (`QLICK_PROXY_DIR`) so that opening the photograph again, editing it at the size it's shown, its brightness match
//! and its thumbnails never read the RAW. 100 % and the export still do.
//!
//! The file is a line of JSON, then the pixels. They were half floats, 6 bytes a pixel (26 MB a photograph); a
//! sensor's noise doesn't compress, so most of that kept noise to the last bit. Now each value is counted on a
//! curve that follows the noise (a square root up to 1.0, a logarithm above), in 12 bits: the step is under the
//! sensor's own noise at every level, and about a third of a percent at mid-grey. What a neighbour predicts is
//! taken off, and what's left is deflated, in strips that are written and read side by side. About 10 MB, read in
//! a few milliseconds more than before. Only frames up to `PROXY_LONG` come from it: an export never does.

use anyhow::{Context, Result, ensure};
use rayon::prelude::*;
use serde_json::{Value, json};
use spektrafilm_math::{image::ImageBuf, precision::Scalar};
use std::{
    io::{Read, Write},
    path::{Path, PathBuf},
};

pub const PROXY_LONG: u32 = 2560;
/// 2: the compact pixels. A file of another version is never found (its name differs) nor read.
const PROXY_VERSION: u32 = 2;
pub const PROXY_EXTENSION: &str = "qnproxy2";

/// The codes: 12 bits over the curve from `-NEGATIVE` (a colour outside the gamut reads a little under zero) to
/// the curve's value at `TOP` (recovered highlights read above 1.0).
const CODES: f32 = 4095.0;
const NEGATIVE: f32 = 0.25;
const TOP: f32 = 64.0;
/// Rows to a strip: enough strips for every core, each large enough to deflate well.
const STRIP_ROWS: usize = 64;

fn curve(value: f32) -> f32 {
    let size = value.abs();
    let bent = if size <= 1.0 { size.sqrt() } else { 1.0 + 0.5 * size.ln() };
    bent.copysign(value)
}

fn straight(bent: f32) -> f32 {
    let size = bent.abs();
    let value = if size <= 1.0 { size * size } else { ((size - 1.0) * 2.0).exp() };
    value.copysign(bent)
}

fn span() -> f32 {
    NEGATIVE + curve(TOP)
}

fn code(value: f32, span: f32) -> u16 {
    // A value that isn't a number counts as black.
    let value = if value.is_finite() { value } else { 0.0 };
    ((curve(value) + NEGATIVE) / span * CODES).round().clamp(0.0, CODES) as u16
}

/// Every code's value.
fn values() -> Vec<Scalar> {
    let span = span();
    (0..=CODES as u32).map(|code| straight(code as f32 / CODES * span - NEGATIVE) as Scalar).collect()
}

/// What the pixels to the left, above and above left say this one is (the median edge detector of lossless JPEG).
fn predicted(left: i32, up: i32, corner: i32) -> i32 {
    if corner >= left.max(up) {
        left.min(up)
    } else if corner <= left.min(up) {
        left.max(up)
    } else {
        left + up - corner
    }
}

/// One strip's codes, a channel after the other, as what the prediction missed: small numbers, low bytes then
/// high bytes, deflated.
fn pack_strip(codes: &[u16], width: usize) -> Result<Vec<u8>> {
    let rows = codes.len() / (width * 3);
    let mut low = Vec::with_capacity(codes.len());
    let mut high = Vec::with_capacity(codes.len());
    for channel in 0..3 {
        let at = |row: usize, x: usize| i32::from(codes[(row * width + x) * 3 + channel]);
        for row in 0..rows {
            for x in 0..width {
                let guess = match (row, x) {
                    (0, 0) => 0,
                    (0, _) => at(0, x - 1),
                    (_, 0) => at(row - 1, 0),
                    _ => predicted(at(row, x - 1), at(row - 1, x), at(row - 1, x - 1)),
                };
                let missed = at(row, x) - guess;
                let folded = ((missed << 1) ^ (missed >> 31)) as u16;
                low.push(folded as u8);
                high.push((folded >> 8) as u8);
            }
        }
    }
    let mut encoder = flate2::write::DeflateEncoder::new(Vec::with_capacity(codes.len()), flate2::Compression::new(5));
    encoder.write_all(&low)?;
    encoder.write_all(&high)?;
    Ok(encoder.finish()?)
}

/// A strip back into `pixels` (its rows of the image).
fn unpack_strip(packed: &[u8], width: usize, values: &[Scalar], pixels: &mut [Scalar]) -> Result<()> {
    let count = pixels.len();
    let rows = count / (width * 3);
    let mut bytes = Vec::with_capacity(count * 2);
    flate2::read::DeflateDecoder::new(packed).take(count as u64 * 2 + 1).read_to_end(&mut bytes)?;
    ensure!(bytes.len() == count * 2, "A proxy's strip cut short");
    let (low, high) = bytes.split_at(count);
    let mut codes = vec![0i32; rows * width];
    for channel in 0..3 {
        let plane = channel * rows * width;
        for row in 0..rows {
            for x in 0..width {
                let index = row * width + x;
                let folded = i32::from(low[plane + index]) | i32::from(high[plane + index]) << 8;
                let missed = (folded >> 1) ^ -(folded & 1);
                let guess = match (row, x) {
                    (0, 0) => 0,
                    (0, _) => codes[index - 1],
                    (_, 0) => codes[index - width],
                    _ => predicted(codes[index - 1], codes[index - width], codes[index - width - 1]),
                };
                let code = guess + missed;
                ensure!((0..values.len() as i32).contains(&code), "A proxy's pixel out of range");
                codes[index] = code;
                pixels[index * 3 + channel] = values[code as usize];
            }
        }
    }
    Ok(())
}

/// The pixels as written: each strip's length, and the strips one after the other.
fn pack(image: &ImageBuf) -> Result<(Vec<usize>, Vec<u8>)> {
    let width = image.width as usize;
    let span = span();
    let strips: Vec<Vec<u8>> = image
        .data
        .par_chunks(width * 3 * STRIP_ROWS)
        .map(|rows| {
            let codes: Vec<u16> = rows.iter().map(|&value| code(value as f32, span)).collect();
            pack_strip(&codes, width)
        })
        .collect::<Result<_>>()?;
    Ok((strips.iter().map(Vec::len).collect(), strips.concat()))
}

fn unpack(width: u32, height: u32, lengths: &[usize], data: &[u8]) -> Result<ImageBuf> {
    let (width, height) = (width as usize, height as usize);
    ensure!(width > 0 && height > 0 && lengths.len() == height.div_ceil(STRIP_ROWS), "Not a proxy's strips");
    ensure!(lengths.iter().sum::<usize>() == data.len(), "A proxy cut short");
    let mut starts = Vec::with_capacity(lengths.len());
    let mut start = 0;
    for length in lengths {
        starts.push(start);
        start += length;
    }
    let values = values();
    let mut pixels = vec![Scalar::default(); width * height * 3];
    pixels
        .par_chunks_mut(width * 3 * STRIP_ROWS)
        .zip(starts.par_iter().zip(lengths.par_iter()))
        .try_for_each(|(rows, (&start, &length))| unpack_strip(&data[start..start + length], width, &values, rows))?;
    Ok(ImageBuf { width: width as u32, height: height as u32, data: pixels })
}

/// The proxy's file for `input` as it is now: named by its path, size, modification time (whole seconds) and lens
/// correction, so an edited file or a changed correction never finds a stale one. The app names it the same way.
pub fn proxy_file(input: &Path, lens: spektrafilm_io::LensCorrection) -> Option<PathBuf> {
    proxy_file_for(input, lens.enabled)
}

/// A photograph keeps one proxy: made with lens corrections on, the one made with them off goes, and the other way.
pub fn drop_other_proxy(input: &Path, lens_enabled: bool) {
    if let Some(other) = proxy_file_for(input, !lens_enabled) {
        let _ = std::fs::remove_file(other);
    }
}

fn proxy_file_for(input: &Path, lens_enabled: bool) -> Option<PathBuf> {
    let dir = std::env::var_os("QLICK_PROXY_DIR").map(PathBuf::from)?;
    if !spektrafilm_io::is_raw(input) {
        return None;
    }
    let meta = std::fs::metadata(input).ok()?;
    let seconds = meta.modified().ok()?.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs();
    let name = format!("{}|{}|{}|{}|v{}", input.display(), meta.len(), seconds, u8::from(lens_enabled), PROXY_VERSION);
    // FNV-1a, 64 bits: stable, and easy to compute in the app too.
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in name.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    Some(dir.join(format!("{hash:016x}.{PROXY_EXTENSION}")))
}

/// A proxy as read: the reduced Daylight read and what the RAW said with it.
pub struct Proxy {
    pub image: ImageBuf,
    pub full: (u32, u32),
    pub colour: spektrafilm_io::InputColour,
    pub lens_supported: bool,
    pub matrix: [[f64; 3]; 3],
    pub as_shot: (f64, f64),
    pub auto: Option<(f64, f64)>,
}

/// Writes a proxy. Written aside and renamed, so a reader never sees half of one.
#[allow(clippy::too_many_arguments)]
pub fn write_proxy(
    file: &Path,
    image: &ImageBuf,
    full: (u32, u32),
    colour: &spektrafilm_io::InputColour,
    lens_supported: bool,
    matrix: [[f64; 3]; 3],
    as_shot: (f64, f64),
    auto: Option<(f64, f64)>,
) -> Result<()> {
    let long = image.width.max(image.height);
    let reduced;
    let image = if long > PROXY_LONG {
        let scale = PROXY_LONG as f64 / long as f64;
        let size = (((image.width as f64 * scale).round() as u32).max(1), ((image.height as f64 * scale).round() as u32).max(1));
        reduced = spektrafilm_core::preview::downsample_area(image, size);
        &reduced
    } else {
        image
    };
    let (strips, pixels) = pack(image)?;
    let header = json!({
        "v": PROXY_VERSION, "width": image.width, "height": image.height, "full": [full.0, full.1],
        "colour": colour, "lens_supported": lens_supported, "matrix": matrix,
        "as_shot": [as_shot.0, as_shot.1], "auto": auto.map(|(t, g)| json!([t, g])),
        "strips": strips,
    });
    let mut bytes = serde_json::to_vec(&header)?;
    bytes.push(b'\n');
    bytes.extend_from_slice(&pixels);
    if let Some(dir) = file.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let aside = file.with_extension(format!("part{}", std::process::id()));
    std::fs::write(&aside, &bytes)?;
    std::fs::rename(&aside, file)?;
    Ok(())
}

pub fn read_proxy(file: &Path) -> Result<Proxy> {
    let bytes = std::fs::read(file)?;
    let end = bytes.iter().position(|&b| b == b'\n').context("Not a proxy")?;
    let header: Value = serde_json::from_slice(&bytes[..end])?;
    ensure!(header["v"].as_u64() == Some(u64::from(PROXY_VERSION)), "A proxy of another version");
    let (width, height) = (header["width"].as_u64().context("width")? as u32, header["height"].as_u64().context("height")? as u32);
    ensure!(u64::from(width) * u64::from(height) <= 64_000_000, "A proxy too large");
    let strips: Vec<usize> = serde_json::from_value(header["strips"].clone()).context("strips")?;
    let image = unpack(width, height, &strips, &bytes[end + 1..])?;
    let pair = |value: &Value| -> Option<(f64, f64)> { Some((value.get(0)?.as_f64()?, value.get(1)?.as_f64()?)) };
    Ok(Proxy {
        image,
        full: (header["full"][0].as_u64().context("full")? as u32, header["full"][1].as_u64().context("full")? as u32),
        colour: serde_json::from_value(header["colour"].clone())?,
        lens_supported: header["lens_supported"].as_bool().unwrap_or(false),
        matrix: serde_json::from_value(header["matrix"].clone())?,
        as_shot: pair(&header["as_shot"]).context("as_shot")?,
        auto: pair(&header["auto"]),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A frame with what a photograph has: smooth tones, noise, deep shadows, a recovered highlight and a colour
    /// outside the gamut.
    fn frame(width: u32, height: u32) -> ImageBuf {
        let mut state = 0x2545_f491_4f6c_dd1du64;
        let mut noise = move || {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            (state >> 40) as f32 / (1u64 << 24) as f32 - 0.5
        };
        let mut data = Vec::with_capacity((width * height * 3) as usize);
        for y in 0..height {
            for x in 0..width {
                let tone = (x as f32 / width as f32).powi(3) * 1.2 + y as f32 / height as f32 * 0.002;
                for channel in 0..3 {
                    let value = tone * (1.0 + channel as f32 * 0.1) + noise() * 0.01 * tone.sqrt();
                    data.push(value as Scalar);
                }
            }
        }
        data[0] = 7.5 as Scalar;
        data[1] = -0.03 as Scalar;
        data[2] = 0.0 as Scalar;
        ImageBuf { width, height, data }
    }

    #[test]
    fn the_curve_comes_back() {
        for value in [-0.05f32, -1e-4, 0.0, 1e-5, 0.003, 0.18, 0.999, 1.0, 1.001, 3.0, 60.0] {
            assert!((straight(curve(value)) - value).abs() <= value.abs() * 1e-5 + 1e-9, "{value}");
        }
    }

    #[test]
    fn pixels_come_back_within_a_step() {
        // Sizes that end a strip exactly, in the middle of one, and in one row.
        for (width, height) in [(97, 64), (64, 131), (33, 1), (1, 70)] {
            let image = frame(width, height);
            let (strips, data) = pack(&image).unwrap();
            let back = unpack(width, height, &strips, &data).unwrap();
            let span = span();
            for (index, (&was, &is)) in image.data.iter().zip(&back.data).enumerate() {
                // Half a code on the curve, as a value.
                let (was, is) = (was as f32, is as f32);
                let step = (straight(curve(was) + span / CODES) - was).abs().max((was - straight(curve(was) - span / CODES)).abs());
                assert!((was - is).abs() <= step * 0.51 + 1e-9, "{width}×{height} at {index}: {was} read {is}");
            }
        }
    }

    #[test]
    fn mid_grey_keeps_a_third_of_a_percent() {
        let span = span();
        let back = values()[usize::from(code(0.18, span))] as f32;
        assert!((back / 0.18 - 1.0).abs() < 0.002);
        let step = straight(curve(0.18) + span / CODES) / 0.18 - 1.0;
        assert!(step < 0.004, "{step}");
    }

    #[test]
    fn a_proxy_is_written_and_read() {
        let dir = std::env::temp_dir().join(format!("qlick-proxy-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("test.qnproxy2");
        let image = frame(300, 200);
        let colour: spektrafilm_io::InputColour = serde_json::from_value(json!(spektrafilm_io::InputColour::raw("apple"))).unwrap();
        let matrix = [[1.1, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 0.9]];
        write_proxy(&file, &image, (3000, 2000), &colour, true, matrix, (5200.0, 1.1), None).unwrap();
        let proxy = read_proxy(&file).unwrap();
        assert_eq!((proxy.image.width, proxy.image.height, proxy.full), (300, 200, (3000, 2000)));
        assert_eq!((proxy.matrix, proxy.as_shot, proxy.auto, proxy.lens_supported), (matrix, (5200.0, 1.1), None, true));
        // Cut short, it isn't read as a photograph.
        let bytes = std::fs::read(&file).unwrap();
        std::fs::write(&file, &bytes[..bytes.len() - 40]).unwrap();
        assert!(read_proxy(&file).is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// What the compact pixels cost a develop, on a real photograph: the same Daylight read developed from the
    /// pixels as read and from the pixels as a proxy keeps them, pushed two stops so the shadows show, without
    /// grain (which would hide the difference). Prints the figures; the two must be the same picture.
    #[cfg(target_os = "macos")]
    #[test]
    #[ignore = "requires a local camera RAW: set SPEKTRAFILM_RAW_TEST_FILE"]
    fn a_develop_from_a_proxy_is_the_develop_from_its_read() {
        let input = PathBuf::from(std::env::var_os("SPEKTRAFILM_RAW_TEST_FILE").expect("SPEKTRAFILM_RAW_TEST_FILE"));
        let data = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../data");
        let daylight = spektrafilm_io::RawWhiteBalance { mode: spektrafilm_io::RawWhiteBalanceMode::Daylight, ..Default::default() };
        let read = spektrafilm_io::load_image_colour_limited(
            &input, spektrafilm_io::Formats::Any, daylight, Default::default(), &Default::default(), PROXY_LONG,
        )
        .unwrap();
        let started = std::time::Instant::now();
        let (strips, packed) = pack(&read.image).unwrap();
        let packing = started.elapsed();
        let started = std::time::Instant::now();
        let kept = unpack(read.image.width, read.image.height, &strips, &packed).unwrap();
        let unpacking = started.elapsed();
        let pixels = read.image.data.len() / 3;
        eprintln!(
            "{}×{}: {:.1} MB as half floats, {:.1} MB compact; packed in {:.0} ms, unpacked in {:.0} ms",
            read.image.width, read.image.height, pixels as f64 * 6.0 / 1e6, packed.len() as f64 / 1e6,
            packing.as_secs_f64() * 1e3, unpacking.as_secs_f64() * 1e3,
        );
        let backend = spektrafilm_gpu::select_backend();
        for (ev, grain) in [(0.0, false), (2.0, false), (2.0, true)] {
            let mut params = spektrafilm_core::params::RuntimeParams::default();
            params.io.apply_input_colour(&read.colour);
            params.camera.auto_exposure = false;
            params.camera.exposure_compensation_ev = ev;
            params.film_render.grain.active = grain;
            let develop = |image: &ImageBuf| {
                let pipeline = crate::build_pipeline(&data, "kodak_portra_400", "kodak_portra_endura", &params).unwrap();
                pipeline.process_with_backend(image.clone(), backend.as_ref()).0
            };
            let (exact, compact) = (develop(&read.image), develop(&kept));
            let (mut worst, mut squares, mut over) = (0.0f64, 0.0f64, 0usize);
            for (a, b) in exact.data.iter().zip(&compact.data) {
                let difference = (f64::from(*a as f32).clamp(0.0, 1.0) - f64::from(*b as f32).clamp(0.0, 1.0)).abs() * 255.0;
                worst = worst.max(difference);
                squares += difference * difference;
                over += usize::from(difference > 1.0);
            }
            let rms = (squares / exact.data.len() as f64).sqrt();
            eprintln!(
                "{ev:+.0} EV, grain {}: rms {rms:.3} of 255 (PSNR {:.1} dB), worst {worst:.2}, {:.4} % of values over one step of 8 bits",
                if grain { "on" } else { "off" }, 20.0 * (255.0 / rms.max(1e-9)).log10(), over as f64 / exact.data.len() as f64 * 100.0,
            );
            if !grain {
                assert!(rms < 0.5, "the compact proxy shows: rms {rms}");
            }
        }
    }
}
