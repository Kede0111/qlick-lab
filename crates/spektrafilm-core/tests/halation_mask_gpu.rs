//! Qlick Lab: Show mask on the GPU-resident chain shows what the CPU shows:
//! the halation alone, through the film and paper, on black.

use spektrafilm_core::{params::RuntimeParams, pipeline::Pipeline, profile};
use spektrafilm_gpu::{cpu_backend::CpuBackend, wgpu_backend::WgpuBackend};
use spektrafilm_math::{image::ImageBuf, precision::from_f64};
use std::path::Path;

fn pipeline(params: RuntimeParams) -> Pipeline {
    let data = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../data");
    Pipeline::new_with_spectral(
        profile::load_profile_by_name(&data, "kodak_portra_400").unwrap(),
        profile::load_profile_by_name(&data, "kodak_portra_endura").unwrap(),
        params,
        &data,
    )
    .unwrap()
}

/// A dark frame with one bright light in it.
fn image() -> ImageBuf {
    let (w, h) = (96u32, 64u32);
    let data = (0..w * h)
        .flat_map(|i| {
            let (x, y) = (i % w, i / w);
            let lit = (40..48).contains(&x) && (28..36).contains(&y);
            [if lit { 40.0 } else { 0.05 }; 3]
        })
        .map(from_f64)
        .collect();
    ImageBuf::from_data(w, h, data)
}

#[test]
fn the_halation_mask_matches_the_cpu() {
    let Some(gpu) = WgpuBackend::new() else {
        assert!(std::env::var_os("SPEKTRAFILM_REQUIRE_GPU").is_none(), "no GPU adapter, and SPEKTRAFILM_REQUIRE_GPU is set");
        eprintln!("no GPU adapter available; skipping");
        return;
    };
    let mut params = RuntimeParams::default();
    params.camera.auto_exposure = false;
    params.film_render.grain.active = false;
    params.film_render.glare.active = false;
    params.print_render.glare.active = false;
    params.film_render.halation.active = true;
    params.film_render.halation.halation_amount = 2.0;
    params.film_render.halation.show_mask = true;
    // A small frame, so the glow spreads over a few pixels.
    params.camera.film_format_mm = 3.0;
    let pipe = pipeline(params.clone());
    let cpu = pipe.process(image(), &CpuBackend);
    let gpu_out = pipe.process(image(), &gpu);
    let max = cpu.data.iter().zip(&gpu_out.data).map(|(a, b)| (*a as f64 - *b as f64).abs()).fold(0.0, f64::max);
    eprintln!("max |gpu - cpu| {max:.3e}");
    assert!(max < 1e-2, "max |gpu - cpu| {max}");

    // The light itself is gone; its glow shows round it, red more than blue.
    params.film_render.halation.show_mask = false;
    let shown = pipeline(params).process(image(), &CpuBackend);
    let at = |img: &ImageBuf, x, y| img.get(x, y).map(|v| v as f64);
    assert!(at(&cpu, 44, 32)[1] < at(&shown, 44, 32)[1] - 0.2, "{:?} vs {:?}", at(&cpu, 44, 32), at(&shown, 44, 32));
    let near = at(&cpu, 52, 32);
    let far = at(&cpu, 4, 4);
    assert!(near[0] > far[0] + 0.01 && near[0] > near[2], "near {near:?} far {far:?}");
}
