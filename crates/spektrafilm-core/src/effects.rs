//! Qlick Lab: effects on the scanned photograph, after the scan and before the
//! post adjustments. Each is measured on the photograph's own proportions, so
//! a preview at any size shows what the export will.
//!
//! Chromatic aberration comes in its two optical kinds. Lateral: the lens
//! enlarges each colour differently, so fringes grow towards the corners
//! (QLab's `chromaticAberration`, up to ±3 % of the frame at 100). Axial:
//! the colours focus at different depths, so green is sharp and red and blue
//! are soft round it, purple and green fringes on contrasty edges, strongest
//! with a fast lens wide open.

use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use spektrafilm_math::image::ImageBuf;

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct EffectsParams {
    /// The chromatic aberration's switch: off, its settings are kept and
    /// nothing is applied.
    #[serde(default = "on")]
    pub ca_enabled: bool,
    /// Lateral chromatic aberration, -100 to 100: red enlarged and blue
    /// reduced about the centre (negative the other way).
    #[serde(default)]
    pub chromatic_aberration: f32,
    /// Lateral aberration between blue and yellow (red and green together)
    /// instead of red and blue: the smear of old uncoated lenses.
    #[serde(default)]
    pub ca_blue_yellow: bool,
    /// Lateral aberration along the width only, as an anamorphic lens's.
    #[serde(default)]
    pub ca_anamorphic: bool,
    /// Axial chromatic aberration, 0 to 100: red and blue out of focus round
    /// a sharp green.
    #[serde(default)]
    pub ca_axial: f32,
    /// Axial fringes only round bright light: the purple edges of highlights.
    #[serde(default)]
    pub ca_highlights: bool,
}

fn on() -> bool {
    true
}

impl Default for EffectsParams {
    fn default() -> Self {
        Self {
            ca_enabled: true,
            chromatic_aberration: 0.0,
            ca_blue_yellow: false,
            ca_anamorphic: false,
            ca_axial: 0.0,
            ca_highlights: false,
        }
    }
}

impl EffectsParams {
    pub fn is_identity(&self) -> bool {
        !self.ca_enabled || (self.chromatic_aberration == 0.0 && self.ca_axial == 0.0)
    }
}

/// Lateral at 100: QLab's most, ±3 % of the frame.
const LATERAL_AT_100: f64 = 0.03;
/// Axial at 100: red and blue blurred by this share of the long side (sigma).
const AXIAL_AT_100: f64 = 0.0035;

pub fn apply(image: &mut ImageBuf, params: &EffectsParams) {
    if !params.ca_enabled {
        return;
    }
    if params.ca_axial > 0.0 {
        axial(image, params.ca_axial as f64 / 100.0, params.ca_highlights);
    }
    if params.chromatic_aberration != 0.0 {
        lateral(image, params.chromatic_aberration as f64 / 100.0 * LATERAL_AT_100, params.ca_blue_yellow, params.ca_anamorphic);
    }
}

fn bilinear(source: &[spektrafilm_math::Scalar], w: usize, h: usize, x: f64, y: f64, channel: usize) -> f64 {
    let x = x.clamp(0.0, w as f64 - 1.0);
    let y = y.clamp(0.0, h as f64 - 1.0);
    let (x0, y0) = (x.floor() as usize, y.floor() as usize);
    let (x1, y1) = ((x0 + 1).min(w - 1), (y0 + 1).min(h - 1));
    let (fx, fy) = (x - x0 as f64, y - y0 as f64);
    let at = |x: usize, y: usize| source[(y * w + x) * 3 + channel] as f64;
    (at(x0, y0) * (1.0 - fx) + at(x1, y0) * fx) * (1.0 - fy) + (at(x0, y1) * (1.0 - fx) + at(x1, y1) * fx) * fy
}

/// One colour enlarged by `1 + k` and its opposite reduced by `1 - k` about the
/// centre: red against blue, or blue against yellow (red and green together).
fn lateral(image: &mut ImageBuf, k: f64, blue_yellow: bool, anamorphic: bool) {
    let (w, h) = (image.width as usize, image.height as usize);
    if w < 2 || h < 2 {
        return;
    }
    let source = image.data.clone();
    let (cx, cy) = ((w as f64 - 1.0) / 2.0, (h as f64 - 1.0) / 2.0);
    // A channel enlarged by s shows, at a pixel, the source at 1/s of its distance.
    let (grow, shrink) = (1.0 / (1.0 + k), 1.0 / (1.0 - k));
    image.data.par_chunks_exact_mut(w * 3).enumerate().for_each(|(y, row)| {
        let dy = y as f64 - cy;
        for x in 0..w {
            let dx = x as f64 - cx;
            let at = |s: f64, channel: usize| {
                let sy = if anamorphic { 1.0 } else { s };
                bilinear(&source, w, h, cx + dx * s, cy + dy * sy, channel)
            };
            if blue_yellow {
                row[x * 3] = at(grow, 0) as _;
                row[x * 3 + 1] = at(grow, 1) as _;
                row[x * 3 + 2] = at(shrink, 2) as _;
            } else {
                row[x * 3] = at(grow, 0) as _;
                row[x * 3 + 2] = at(shrink, 2) as _;
            }
        }
    });
}

/// Red and blue out of focus round green: each blurred (three box passes, a
/// near-Gaussian), and, for highlights only, mixed in where the blur is bright.
fn axial(image: &mut ImageBuf, amount: f64, highlights: bool) {
    let (w, h) = (image.width as usize, image.height as usize);
    if w < 3 || h < 3 {
        return;
    }
    let sigma = amount * AXIAL_AT_100 * w.max(h) as f64;
    if sigma < 0.3 {
        return;
    }
    // Three box blurs of this radius approximate a Gaussian of `sigma`.
    let radius = ((((12.0 * sigma * sigma / 3.0) + 1.0).sqrt() - 1.0) / 2.0).round().max(1.0) as usize;
    let mut planes: Vec<Vec<f32>> = [0usize, 2]
        .iter()
        .map(|&c| image.data.iter().skip(c).step_by(3).map(|&v| v as f32).collect())
        .collect();
    for plane in planes.iter_mut() {
        for _ in 0..3 {
            box_blur(plane, w, h, radius);
        }
    }
    image.data.par_chunks_exact_mut(3).enumerate().for_each(|(i, p)| {
        let (r, b) = (planes[0][i] as f64, planes[1][i] as f64);
        let weight = if highlights {
            // Only where the blurred light is bright: the fringe of a highlight.
            let light = 0.5 * (r + b);
            ((light - 0.55) / 0.35).clamp(0.0, 1.0)
        } else {
            1.0
        };
        let mix = |sharp: f64, soft: f64| if highlights { sharp.max(sharp + (soft - sharp) * weight) } else { soft };
        p[0] = mix(p[0] as f64, r) as _;
        p[2] = mix(p[2] as f64, b) as _;
    });
}

/// A box blur of `radius` across rows, then down columns.
fn box_blur(plane: &mut [f32], w: usize, h: usize, radius: usize) {
    let pass = |line: &mut [f32], scratch: &mut Vec<f32>| {
        let n = line.len();
        scratch.clear();
        scratch.extend_from_slice(line);
        let width = (2 * radius + 1) as f32;
        let at = |i: isize| scratch[i.clamp(0, n as isize - 1) as usize];
        let mut sum: f32 = (-(radius as isize)..=radius as isize).map(at).sum();
        for (i, out) in line.iter_mut().enumerate() {
            *out = sum / width;
            sum += at(i as isize + radius as isize + 1) - at(i as isize - radius as isize);
        }
    };
    plane.par_chunks_exact_mut(w).for_each_init(Vec::new, |scratch, row| pass(row, scratch));
    let mut columns = vec![0f32; w * h];
    for y in 0..h {
        for x in 0..w {
            columns[x * h + y] = plane[y * w + x];
        }
    }
    columns.par_chunks_exact_mut(h).for_each_init(Vec::new, |scratch, column| pass(column, scratch));
    for x in 0..w {
        for y in 0..h {
            plane[y * w + x] = columns[x * h + y];
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn picture() -> Vec<spektrafilm_math::Scalar> {
        (0..19 * 13 * 3).map(|i| ((i * 37) % 255) as spektrafilm_math::Scalar / 255.0).collect()
    }

    #[test]
    fn zero_leaves_the_photograph_and_the_centre_stays() {
        let data = picture();
        let mut image = ImageBuf::from_data(19, 13, data.clone());
        apply(&mut image, &EffectsParams::default());
        assert!(image.data == data);
        apply(&mut image, &EffectsParams { chromatic_aberration: 100.0, ..Default::default() });
        let centre = (6 * 19 + 9) * 3;
        assert!((image.data[centre] - data[centre]).abs() < 1e-6);
        assert!(image.data.iter().zip(&data).any(|(a, b)| (a - b).abs() > 1e-6));
        // Green never moves.
        assert!(image.data.chunks(3).zip(data.chunks(3)).all(|(a, b)| a[1] == b[1]));
    }

    #[test]
    fn switched_off_keeps_the_settings_and_applies_nothing() {
        let data = picture();
        let mut image = ImageBuf::from_data(19, 13, data.clone());
        let params = EffectsParams { ca_enabled: false, chromatic_aberration: 100.0, ca_axial: 100.0, ..Default::default() };
        assert!(params.is_identity());
        apply(&mut image, &params);
        assert!(image.data == data);
        // Edits saved before the switch existed have it on.
        let old: EffectsParams = serde_json::from_str(r#"{"chromatic_aberration": 40.0}"#).unwrap();
        assert!(old.ca_enabled && !old.is_identity());
    }

    #[test]
    fn axial_softens_red_and_blue_only() {
        // Large enough for a blur of a few pixels.
        let data: Vec<spektrafilm_math::Scalar> = (0..600 * 400 * 3).map(|i| ((i * 37) % 255) as spektrafilm_math::Scalar / 255.0).collect();
        let mut image = ImageBuf::from_data(600, 400, data.clone());
        apply(&mut image, &EffectsParams { ca_axial: 100.0, ..Default::default() });
        assert!(image.data.chunks(3).zip(data.chunks(3)).all(|(a, b)| a[1] == b[1]));
        let spread = |d: &[spektrafilm_math::Scalar]| d.chunks(3).map(|p| p[0] as f64).fold((f64::MAX, f64::MIN), |(lo, hi), v| (lo.min(v), hi.max(v)));
        let (before, after) = (spread(&data), spread(&image.data));
        assert!(after.1 - after.0 < before.1 - before.0);
    }

    #[test]
    fn blue_yellow_moves_green_with_red() {
        let data = picture();
        let mut image = ImageBuf::from_data(19, 13, data.clone());
        apply(&mut image, &EffectsParams { chromatic_aberration: 100.0, ca_blue_yellow: true, ..Default::default() });
        assert!(image.data.chunks(3).zip(data.chunks(3)).any(|(a, b)| a[1] != b[1]));
    }
}
