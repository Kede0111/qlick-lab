//! Qlick Lab: no film (`io.no_film`). The image is taken as it is, without a
//! film's colour or process.
//!
//! - Printed on a paper, the image is read as a scanned negative: each
//!   channel's density over the film's clear base, found in the image's
//!   brightest values, stands for the dye of that layer, and the paper prints
//!   it as it prints a film's own negative (with the film's dyes).
//! - With no paper either, the image is the photograph itself: the effects
//!   (diffusion, lens blur, halation, grain) are added to it, and it goes out
//!   in the output colour space with nothing else changed.
//!
//! Runs on the CPU only: the GPU's resident chain is a film's.

use rayon::prelude::*;
use spektrafilm_gpu::ComputeBackend;
use spektrafilm_math::colorspace::{self, RgbColourspace};
use spektrafilm_math::image::ImageBuf;
use spektrafilm_math::precision::{Scalar, from_f64};

use crate::params::RuntimeParams;
use crate::profile::Profile;

/// The lightest transmission a negative's density is read from, so a black in
/// the scan stays a finite density (4.0 over the base).
const DARKEST: f64 = 1e-4;

/// The input decoded, exposed and through Prep, as linear values in the
/// input colour space. No auto exposure: the image keeps its brightness.
pub fn prepare(image: ImageBuf, params: &RuntimeParams) -> ImageBuf {
    super::filming::prepare_input(image, params, 0.0).expect("Invalid Prep settings or pixels")
}

/// The film's clear base in a scanned negative, per channel: the value 0.2 %
/// of the pixels are brighter than (the base itself, or the faintest
/// shadows next to it). 1 for a channel without any light.
pub fn negative_base(image: &ImageBuf) -> [f64; 3] {
    let n = image.data.len() / 3;
    // Every pixel up to 4 MP, then evenly spread samples: the base is the
    // same at every size of the frame.
    let step = (n / 4_000_000).max(1);
    std::array::from_fn(|c| {
        let mut values: Vec<f64> = (0..n).step_by(step).map(|i| image.data[i * 3 + c] as f64).filter(|v| v.is_finite()).collect();
        if values.is_empty() {
            return 1.0;
        }
        let k = ((values.len() as f64) * 0.998) as usize;
        let k = k.min(values.len() - 1);
        let (_, base, _) = values.select_nth_unstable_by(k, |a, b| a.total_cmp(b));
        if *base > 0.0 { *base } else { 1.0 }
    })
}

/// A scanned negative's dye densities: each channel's density over the base.
/// A black-and-white film reads one density, the channels' mean, in all three.
/// With auto exposure on, the negative is metered as the film's own would be:
/// its median density is moved to the density the film gives a mid grey, so a
/// thin or a dense scan prints alike (Print exposure still moves it).
pub fn negative_density(transmission: ImageBuf, film: &Profile, params: &RuntimeParams) -> ImageBuf {
    let base = negative_base(&transmission);
    let bw = film.is_bw();
    let mut out = transmission;
    out.data.par_chunks_exact_mut(3).for_each(|px| {
        let d: [f64; 3] = std::array::from_fn(|c| {
            let t = (px[c] as f64 / base[c]).clamp(DARKEST, 1.0);
            -t.log10()
        });
        let d = if bw { [(d[0] + d[1] + d[2]) / 3.0; 3] } else { d };
        for c in 0..3 {
            px[c] = from_f64(d[c]);
        }
    });
    if params.camera.auto_exposure {
        let shift = from_f64(midgray_density(film) - median_density(&out));
        out.data.par_iter_mut().for_each(|v| *v = (*v + shift).max(from_f64(0.0)));
    }
    out
}

/// The film's density for a mid grey, the channels' mean: its normalized
/// curves where auto exposure puts a grey card (log exposure 0).
fn midgray_density(film: &Profile) -> f64 {
    let log_exposure = film.log_exposure_f64();
    let curves = spektrafilm_model::density_curves::normalize_density_curves_f64(&film.density_curves_f64());
    let at = |c: usize| {
        let points: Vec<(f64, f64)> = log_exposure.iter().zip(&curves).map(|(&x, row)| (x, row[c])).filter(|(_, y)| y.is_finite()).collect();
        let i = points.partition_point(|(x, _)| *x < 0.0);
        match (points.get(i.wrapping_sub(1)), points.get(i)) {
            (Some(&(x0, y0)), Some(&(x1, y1))) if x1 > x0 => y0 + (y1 - y0) * (0.0 - x0) / (x1 - x0),
            (_, Some(&(_, y))) | (Some(&(_, y)), None) => y,
            _ => 0.0,
        }
    };
    (at(0) + at(1) + at(2)) / 3.0
}

/// The median of the channels' mean density, from evenly spread samples.
fn median_density(density: &ImageBuf) -> f64 {
    let n = density.data.len() / 3;
    let step = (n / 1_000_000).max(1);
    let mut values: Vec<f64> = (0..n)
        .step_by(step)
        .map(|i| (0..3).map(|c| density.data[i * 3 + c] as f64).sum::<f64>() / 3.0)
        .filter(|v| v.is_finite())
        .collect();
    if values.is_empty() {
        return 0.0;
    }
    let k = values.len() / 2;
    *values.select_nth_unstable_by(k, |a, b| a.total_cmp(b)).1
}

/// The film's grain on a density image, as the film develops it.
pub fn grain(density: ImageBuf, film: &Profile, params: &RuntimeParams) -> ImageBuf {
    if !crate::grain::grain_active(params) {
        return density;
    }
    let pixel_size_um = super::filming::grain_pixel_size_um(params, density.width, density.height);
    spektrafilm_model::grain::apply_grain_lanes(
        density,
        pixel_size_um,
        &crate::grain::grain_settings(film, &params.film_render.grain),
        &crate::grain::grain_curves(film),
        film.is_positive(),
        super::filming::grain_lanes(params),
        params.settings.serial_grain,
    )
}

/// The photograph with the effects added, still linear in the input colour
/// space: the optical ones on its light, then the film's grain. Each value is
/// read as the film would have been exposed to it (a mid grey where auto
/// exposure puts one), the film grains that density, and the change goes back
/// to the photograph's light through the curve's slope there.
pub fn effects(linear: ImageBuf, film: &Profile, params: &RuntimeParams, backend: &dyn ComputeBackend) -> ImageBuf {
    let mut linear = super::filming::optical_effects(linear, params, backend);
    if !crate::grain::grain_active(params) || params.film_render.halation.show_mask && params.film_render.halation.active {
        return linear;
    }
    let curve = FilmCurve::new(film);
    let mut slopes = vec![0.0f64; linear.data.len()];
    let density_data: Vec<Scalar> = linear
        .data
        .par_iter()
        .zip(slopes.par_iter_mut())
        .enumerate()
        .map(|(i, (&v, slope))| {
            let (d, s) = curve.at(i % 3, (v as f64).max(1e-6).log10() - MIDGRAY.log10());
            *slope = s;
            from_f64(d)
        })
        .collect();
    let density = ImageBuf::from_data(linear.width, linear.height, density_data);
    let before = density.data.clone();
    let grained = grain(density, film, params);
    linear.data.par_iter_mut().enumerate().for_each(|(i, v)| {
        let change = (grained.data[i] as f64 - before[i] as f64) / slopes[i];
        if change.is_finite() && *v > from_f64(0.0) {
            *v *= from_f64(10f64.powf(change.clamp(-0.5, 0.5)));
        }
    });
    linear
}

/// The grey card auto exposure brings to the film's log exposure 0.
const MIDGRAY: f64 = 0.184;

/// The film's normalized density curves, read with their slope.
struct FilmCurve {
    /// Per channel, (log exposure, density) where the density is known.
    points: [Vec<(f64, f64)>; 3],
}

impl FilmCurve {
    fn new(film: &Profile) -> Self {
        let log_exposure = film.log_exposure_f64();
        let curves = spektrafilm_model::density_curves::normalize_density_curves_f64(&film.density_curves_f64());
        FilmCurve {
            points: std::array::from_fn(|c| {
                log_exposure.iter().zip(&curves).map(|(&x, row)| (x, row[c])).filter(|(x, y)| x.is_finite() && y.is_finite()).collect()
            }),
        }
    }

    /// Channel `c`'s density at `log_exposure` (held at the curve's ends), and
    /// its slope in density per log exposure, never flatter than 0.1 (signed:
    /// a slide's density falls with light).
    fn at(&self, c: usize, log_exposure: f64) -> (f64, f64) {
        let points = &self.points[c];
        if points.len() < 2 {
            return (0.0, 1.0);
        }
        let x = log_exposure.clamp(points[0].0, points[points.len() - 1].0);
        let i = points.partition_point(|(px, _)| *px < x).clamp(1, points.len() - 1);
        let ((x0, y0), (x1, y1)) = (points[i - 1], points[i]);
        let slope = if x1 > x0 { (y1 - y0) / (x1 - x0) } else { 0.0 };
        let density = y0 + slope * (x - x0);
        let falls = points[points.len() - 1].1 < points[0].1;
        (density, if falls { slope.min(-0.1) } else { slope.max(0.1) })
    }
}

/// Linear values in the input colour space, out in the output colour space:
/// adapted, gamut-compressed and encoded as the scan's output is.
pub fn output(mut linear: ImageBuf, params: &RuntimeParams, gamut: &crate::gamut_compression::OutputGamutCompress) -> ImageBuf {
    let from = RgbColourspace::input(&params.io.input_color_space);
    let to = RgbColourspace::output(&params.io.output_color_space);
    let m = colorspace::icc_rgb_to_rgb(from, to);
    linear.data.par_chunks_exact_mut(3).for_each(|px| {
        let v = [px[0] as f64, px[1] as f64, px[2] as f64];
        let mut out: [f64; 3] = std::array::from_fn(|i| m[i][0] * v[0] + m[i][1] * v[1] + m[i][2] * v[2]);
        if gamut.is_active() {
            out = gamut.compress(out);
        }
        for i in 0..3 {
            px[i] = from_f64(out[i]) as Scalar;
        }
    });
    if params.io.output_cctf_encoding {
        super::scanning::encode_output(&mut linear, &params.io.output_color_space);
    }
    linear
}
