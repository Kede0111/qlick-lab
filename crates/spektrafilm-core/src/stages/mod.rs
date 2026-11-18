mod debug_compare;
pub mod filming;
pub mod no_film;
pub mod printing;
pub mod scanning;

#[cfg(test)]
mod integration_tests {
    use crate::params::RuntimeParams;
    use crate::pipeline::Pipeline;
    use crate::profile;
    use spektrafilm_math::image::ImageBuf;
    use spektrafilm_math::precision::{Scalar, from_f64};
    use std::path::Path;

    fn data_dir() -> std::path::PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .unwrap()
            .parent()
            .unwrap()
            .join("data")
    }

    #[test]
    fn test_full_pipeline_portra_400_to_endura() {
        let dir = data_dir();
        let film = profile::load_profile_by_name(&dir, "kodak_portra_400").unwrap();
        let print = profile::load_profile_by_name(&dir, "kodak_portra_endura").unwrap();

        let mut params = RuntimeParams::default();
        params.film_render.grain.active = false;
        params.film_render.halation.active = false;
        params.film_render.dir_couplers.active = false;
        params.camera.auto_exposure = false;

        let backend = spektrafilm_gpu::cpu_backend::CpuBackend;
        let img = ImageBuf::from_data(8, 8, vec![from_f64(0.184); 8 * 8 * 3]);

        let pipeline = Pipeline::new(film, print, params);
        let result = pipeline.process(img, &backend);

        assert_eq!(result.width, 8);
        assert_eq!(result.height, 8);
        let px = result.get(4, 4);
        for c in 0..3 {
            assert!(
                px[c] >= from_f64(0.0) && px[c] <= from_f64(1.0),
                "channel {c} out of range: {}",
                px[c]
            );
        }
        let mean: Scalar =
            result.data.iter().copied().sum::<Scalar>() / result.data.len() as Scalar;
        assert!(mean > from_f64(0.01), "output near-black: mean={mean}");
        assert!(mean < from_f64(0.99), "output near-white: mean={mean}");
    }

    #[test]
    fn test_full_pipeline_with_spectral_lut() {
        let dir = data_dir();
        let film = profile::load_profile_by_name(&dir, "kodak_portra_400").unwrap();
        let print = profile::load_profile_by_name(&dir, "kodak_portra_endura").unwrap();

        let mut params = RuntimeParams::default();
        params.film_render.grain.active = false;
        params.film_render.halation.active = false;
        params.film_render.dir_couplers.active = false;
        params.camera.auto_exposure = false;
        params.io.input_color_space = "sRGB".to_string();

        let backend = spektrafilm_gpu::cpu_backend::CpuBackend;
        let img = ImageBuf::from_data(8, 8, vec![from_f64(0.184); 8 * 8 * 3]);

        let pipeline = Pipeline::new_with_spectral(film, print, params, &dir);
        match pipeline {
            Ok(p) => {
                let result = p.process(img, &backend);
                let mean: Scalar =
                    result.data.iter().copied().sum::<Scalar>() / result.data.len() as Scalar;
                eprintln!("Spectral pipeline output mean: {mean}");
                let px = result.get(4, 4);
                eprintln!("Spectral pipeline pixel(4,4): {:?}", px);
                assert!(
                    mean > from_f64(0.01),
                    "spectral output near-black: mean={mean}"
                );
                assert!(
                    mean < from_f64(0.99),
                    "spectral output near-white: mean={mean}"
                );
            }
            Err(e) => {
                eprintln!("Spectral LUT not available: {e} — skipping test");
            }
        }
    }

    /// Full default chain vs upstream experimental 28bf883 (CAT16, input
    /// gamut `xy`, output gamut `cam16ucs`, model-derived curves). Reference
    /// values from `scripts/parity/exp_data_unit_references.py`: 28bf883's
    /// pipeline with the stochastic / spatial effects off and linear sRGB
    /// in/out.
    #[test]
    fn full_chain_matches_python_experimental() {
        let dir = data_dir();
        let film = profile::load_profile_by_name(&dir, "kodak_portra_400").unwrap();
        let print = profile::load_profile_by_name(&dir, "kodak_portra_endura").unwrap();

        let mut params = RuntimeParams::default();
        params.camera.auto_exposure = false;
        params.io.input_color_space = "sRGB".to_string();
        params.io.input_cctf_decoding = false;
        params.io.output_cctf_encoding = false;
        params.film_render.grain.active = false;
        params.film_render.halation.active = false;
        params.film_render.dir_couplers.active = false;
        params.print_render.glare.active = false;
        params.scanner.unsharp_mask = [0.0, 0.0];

        let backend = spektrafilm_gpu::cpu_backend::CpuBackend;
        let pipeline =
            Pipeline::new_with_spectral(film, print, params, &dir).expect("spectral LUT");

        // The f32 Scalar chain carries ~1e-4 of accumulated rounding against
        // the f64 Python reference; the f64 build tracks it tightly.
        #[cfg(feature = "precision-f64")]
        const TOL: f64 = 1e-6;
        #[cfg(not(feature = "precision-f64"))]
        const TOL: f64 = 3e-3;

        // 1×1 midgray.
        let img = ImageBuf::from_data(1, 1, vec![from_f64(0.184); 3]);
        let out = pipeline.process(img, &backend);
        let want = [
            0.18168434872454148,
            0.1816510949027062,
            0.18153344933652843,
        ];
        for c in 0..3 {
            let got = out.get(0, 0)[c] as f64;
            assert!(
                (got - want[c]).abs() < TOL,
                "midgray ch {c}: {got} vs {} (diff {:.3e})",
                want[c],
                (got - want[c]).abs()
            );
        }

        // 4×4 deterministic gradient (same integer formula on both sides).
        let (w, h) = (4u32, 4u32);
        let data: Vec<_> = (0..w * h * 3)
            .map(|i| from_f64(0.05 + 0.5 * ((i * 37) % 256) as f64 / 255.0))
            .collect();
        let img = ImageBuf::from_data(w, h, data);
        let out = pipeline.process(img, &backend);
        #[rustfmt::skip]
        let want: [[f64; 3]; 16] = [
            [0.02896626542906261, 0.10730365049408322, 0.16239691028015119],
            [0.2952306874358674, 0.36942803237279653, 0.4237362249208574],
            [0.34915625510221604, 0.0772947821905051, 0.1299852240191852],
            [0.22094665161100227, 0.2988944007530242, 0.3569270008528037],
            [0.422391926807704, 0.3459468622882615, 0.0853800424293393],
            [0.13867031835439564, 0.21872960876759817, 0.27842878636582796],
            [0.3779000724153239, 0.44498408860715744, 0.49262937276482033],
            [0.050805056174104773, 0.13102005420344773, 0.18801807047448987],
            [0.3135697569791069, 0.38642535463721744, 0.43923794064930444],
            [0.3715355019902659, 0.10009393040729274, 0.1537728436197984],
            [0.24156304469653594, 0.31846479395665417, 0.37582526616836887],
            [0.4375016246607823, 0.3682434497541976, 0.11034326928226869],
            [0.1611968989343505, 0.2409491062772523, 0.30041956414399024],
            [0.39318106799768354, 0.4588403618216505, 0.5047055189155656],
            [0.07393795333436211, 0.15474647221406923, 0.21304132680462232],
            [0.331292510042576, 0.40277791799251283, 0.45454849341234627],
        ];
        let mut max_diff = 0.0f64;
        for (i, want_px) in want.iter().enumerate() {
            let px = out.get(i as u32 % w, i as u32 / w);
            for c in 0..3 {
                let d = (px[c] as f64 - want_px[c]).abs();
                max_diff = max_diff.max(d);
                assert!(
                    d < TOL,
                    "px {i} ch {c}: {} vs {} (diff {d:.3e})",
                    px[c],
                    want_px[c]
                );
            }
        }
        eprintln!("full chain: max diff vs Python experimental {max_diff:.3e}");
    }

    #[test]
    fn test_film_scan_pipeline() {
        let dir = data_dir();
        let film = profile::load_profile_by_name(&dir, "kodak_portra_400").unwrap();
        let print = film.clone();

        let mut params = RuntimeParams::default();
        params.io.scan_film = true;
        params.film_render.grain.active = false;
        params.film_render.halation.active = false;
        params.film_render.dir_couplers.active = false;
        params.camera.auto_exposure = false;

        let backend = spektrafilm_gpu::cpu_backend::CpuBackend;
        let img = ImageBuf::from_data(4, 4, vec![from_f64(0.184); 4 * 4 * 3]);

        let pipeline = Pipeline::new(film, print, params);
        let result = pipeline.process(img, &backend);
        let mean: Scalar =
            result.data.iter().copied().sum::<Scalar>() / result.data.len() as Scalar;
        assert!(mean > from_f64(0.01), "film scan near-black: mean={mean}");
        assert!(mean < from_f64(0.99), "film scan near-white: mean={mean}");
    }

    #[test]
    fn with_params_recalibrates_print_exposure_like_a_new_pipeline() {
        let dir = data_dir();
        let film = profile::load_profile_by_name(&dir, "kodak_gold_200").unwrap();
        let print = profile::load_profile_by_name(&dir, "kodak_portra_endura").unwrap();
        let backend = spektrafilm_gpu::cpu_backend::CpuBackend;
        let img = ImageBuf::from_data(
            8,
            8,
            (0..8 * 8 * 3)
                .map(|i| from_f64((i % 17) as f64 / 16.0))
                .collect(),
        );
        let cached = Pipeline::new_with_spectral(
            film.clone(),
            print.clone(),
            RuntimeParams::default(),
            &dir,
        )
        .unwrap();
        for (ev, compensation, gamma) in [(1.3, true, 1.0), (-0.7, true, 1.2), (1.3, false, 1.0)] {
            let mut params = RuntimeParams::default();
            params.camera.exposure_compensation_ev = ev;
            params.enlarger.print_exposure_compensation = compensation;
            params.film_render.density_curves_morph.active = gamma != 1.0;
            params.film_render.density_curves_morph.gamma_factor = gamma;
            let fresh =
                Pipeline::new_with_spectral(film.clone(), print.clone(), params.clone(), &dir)
                    .unwrap();
            let reused = cached.clone().with_params(params);
            assert_eq!(
                reused.print_exposure_factor().to_bits(),
                fresh.print_exposure_factor().to_bits(),
                "EV {ev}, compensation {compensation}, gamma {gamma}"
            );
            assert_eq!(
                reused.process(img.clone(), &backend).data,
                fresh.process(img.clone(), &backend).data
            );
        }
    }

    /// The enlarger's shifts, preflash and exposure normalization aren't in
    /// `preview_pipeline_cache_key`, so a pipeline built with other values
    /// and given these through `with_params` must equal one built with them.
    #[test]
    fn with_params_refilters_the_enlarger_like_a_new_pipeline() {
        let dir = data_dir();
        let film = profile::load_profile_by_name(&dir, "kodak_portra_400").unwrap();
        let print = profile::load_profile_by_name(&dir, "kodak_portra_endura").unwrap();
        let backend = spektrafilm_gpu::cpu_backend::CpuBackend;
        let img = ImageBuf::from_data(
            8,
            8,
            (0..8 * 8 * 3)
                .map(|i| from_f64((i % 17) as f64 / 16.0))
                .collect(),
        );
        let mut built = RuntimeParams::default();
        built.enlarger.m_filter_shift = 7.3;
        built.enlarger.preflash_exposure = 0.04;
        let cached =
            Pipeline::new_with_spectral(film.clone(), print.clone(), built, &dir).unwrap();
        let cases: [(f32, f32, f32, f32, f32, bool, bool, f32); 6] = [
            (0.0, 0.0, 0.0, 0.0, 0.0, true, true, 0.0),
            (12.3, -4.7, 0.0, 0.0, 0.0, true, true, 0.0),
            (-0.1, 33.3, 0.05, 0.0, 0.0, true, true, 0.0),
            (5.0, 5.0, 0.12, -11.0, 44.0, true, true, 1.3),
            (-21.9, 8.8, 0.3, 17.5, -2.2, true, false, -0.7),
            (3.3, -3.3, 0.02, 1.0, 1.0, false, true, 0.4),
        ];
        for (m, y, preflash, preflash_m, preflash_y, normalize, compensation, ev) in cases {
            let mut params = RuntimeParams::default();
            params.enlarger.m_filter_shift = m;
            params.enlarger.y_filter_shift = y;
            params.enlarger.preflash_exposure = preflash;
            params.enlarger.preflash_m_filter_shift = preflash_m;
            params.enlarger.preflash_y_filter_shift = preflash_y;
            params.enlarger.normalize_print_exposure = normalize;
            params.enlarger.print_exposure_compensation = compensation;
            params.camera.exposure_compensation_ev = ev;
            let case = format!("{:?}", (m, y, preflash, preflash_m, preflash_y, normalize, compensation, ev));
            let fresh =
                Pipeline::new_with_spectral(film.clone(), print.clone(), params.clone(), &dir)
                    .unwrap();
            let updated = cached.clone().with_params(params);
            let bits = |v: &[f64]| v.iter().map(|x| x.to_bits()).collect::<Vec<_>>();
            assert_eq!(
                bits(updated.print_illuminant_slice()),
                bits(fresh.print_illuminant_slice()),
                "illuminant {case}"
            );
            assert_eq!(bits(&updated.preflash_raw()), bits(&fresh.preflash_raw()), "preflash {case}");
            assert_eq!(
                updated.print_exposure_factor().to_bits(),
                fresh.print_exposure_factor().to_bits(),
                "exposure factor {case}"
            );
            assert_eq!(
                serde_json::to_string(&updated.params).unwrap(),
                serde_json::to_string(&fresh.params).unwrap(),
                "params {case}"
            );
            assert_eq!(
                updated.process(img.clone(), &backend).data,
                fresh.process(img.clone(), &backend).data,
                "image {case}"
            );
        }
    }

    /// Qlick Lab: Show mask is what the halation adds, alone: with no
    /// scatter and no renormalizing, the image less its halation.
    #[test]
    fn the_halation_mask_is_what_the_halation_adds() {
        let backend = spektrafilm_gpu::cpu_backend::CpuBackend;
        let mut data = vec![from_f64(0.02); 48 * 48 * 3];
        for c in 0..3 {
            data[(24 * 48 + 24) * 3 + c] = from_f64(50.0);
        }
        let image = ImageBuf::from_data(48, 48, data);
        let halate = |mask| {
            spektrafilm_model::diffusion::apply_halation_um(
                &image, 5.0, 0.0, 1.0, [2.0; 3], [9.0; 3], [0.7; 3], 1.0, 1.0, [0.2, 0.05, 0.0], [20.0; 3], 3, 0.5, false, mask,
                &backend,
            )
        };
        let (shown, mask) = (halate(false), halate(true));
        for i in 0..shown.data.len() {
            let added = shown.data[i] - image.data[i];
            assert!((added - mask.data[i]).abs() < 1e-5, "{i}: {added} vs {}", mask.data[i]);
        }
        // Blue has no halation: black.
        assert!(mask.data.iter().skip(2).step_by(3).all(|&v| v == from_f64(0.0)));
        assert!(mask.data[(24 * 48 + 30) * 3] > from_f64(0.0));
    }

    /// Qlick Lab: with no film and no paper, a photograph without effects
    /// comes out as it went in.
    #[test]
    fn no_film_and_no_paper_keep_the_photograph() {
        let dir = data_dir();
        let film = profile::load_profile_by_name(&dir, "kodak_portra_400").unwrap();
        let mut params = RuntimeParams::default();
        params.io.no_film = true;
        params.io.scan_film = true;
        params.io.input_color_space = "sRGB".into();
        params.io.input_cctf_decoding = true;
        params.io.output_color_space = "sRGB".into();
        params.io.output_cctf_encoding = true;
        params.io.output_gamut_compress.algorithm = "off".into();
        params.film_render.grain.active = false;
        params.film_render.halation.active = false;
        let data: Vec<_> = (0..16 * 16 * 3).map(|i| from_f64(((i * 37) % 251) as f64 / 250.0)).collect();
        let image = ImageBuf::from_data(16, 16, data.clone());
        let pipeline = Pipeline::new_with_spectral(film.clone(), film, params, &dir).unwrap();
        let out = pipeline.process(image, &spektrafilm_gpu::cpu_backend::CpuBackend);
        for (a, b) in out.data.iter().zip(&data) {
            assert!((a - b).abs() < 2e-3, "{a} vs {b}");
        }
    }

    /// Qlick Lab: grain added with no film keeps saturated colours what they
    /// are: finite, near their value, never black.
    #[test]
    fn no_film_grain_keeps_saturated_colours() {
        let dir = data_dir();
        let film = profile::load_profile_by_name(&dir, "kodak_portra_400").unwrap();
        let mut params = RuntimeParams::default();
        params.io.no_film = true;
        params.io.scan_film = true;
        params.io.input_color_space = "sRGB".into();
        params.io.input_cctf_decoding = false;
        params.io.output_color_space = "sRGB".into();
        params.io.output_cctf_encoding = false;
        params.io.output_gamut_compress.algorithm = "off".into();
        params.film_render.halation.active = false;
        let colours = [[0.9, 0.0, 0.05], [0.95, 0.85, 0.0], [0.0, 0.0, 0.0], [1.4, 1.2, 1.0], [0.18, 0.18, 0.18]];
        let data: Vec<_> = (0..64 * 64).flat_map(|i| colours[(i / 64) % colours.len()]).map(from_f64).collect();
        let image = ImageBuf::from_data(64, 64, data.clone());
        let pipeline = Pipeline::new_with_spectral(film.clone(), film, params, &dir).unwrap();
        let out = pipeline.process(image, &spektrafilm_gpu::cpu_backend::CpuBackend);
        assert!(out.data.iter().all(|v| v.is_finite()));
        let mut changed = 0;
        for (a, b) in out.data.iter().zip(&data) {
            let (a, b) = (*a as f64, *b as f64);
            assert!(a >= b * 10f64.powf(-0.5) - 1e-6 && a <= b * 10f64.powf(0.5) + 1e-6, "{a} vs {b}");
            if (a - b).abs() > 1e-3 { changed += 1; }
        }
        assert!(changed > data.len() / 4, "grain changed {changed} values");
    }

    /// Qlick Lab: no film on a paper reads the image as a scanned negative: a
    /// denser part of the negative prints lighter, and grain is added.
    #[test]
    fn no_film_prints_a_scanned_negative() {
        let dir = data_dir();
        let film = profile::load_profile_by_name(&dir, "kodak_portra_400").unwrap();
        let print = profile::load_profile_by_name(&dir, "kodak_portra_endura").unwrap();
        let mut params = RuntimeParams::default();
        params.io.no_film = true;
        params.io.input_color_space = "sRGB".into();
        params.io.input_cctf_decoding = false;
        params.film_render.grain.active = false;
        // An orange base, then a thin and a dense part of the negative.
        let base = [0.8, 0.5, 0.3];
        let mut data = Vec::new();
        for y in 0..24 {
            for x in 0..24 {
                let density = if y < 2 { 0.0 } else if x < 12 { 0.3 } else { 1.2 };
                data.extend(base.map(|b: f64| from_f64(b * 10f64.powf(-density))));
                let _ = x;
            }
        }
        let image = ImageBuf::from_data(24, 24, data);
        let pipeline = Pipeline::new_with_spectral(film, print, params, &dir).unwrap();
        let out = pipeline.process(image, &spektrafilm_gpu::cpu_backend::CpuBackend);
        let thin = out.get(4, 12);
        let dense = out.get(20, 12);
        for c in 0..3 {
            assert!(dense[c] > thin[c] + from_f64(0.05), "channel {c}: dense {:?} thin {:?}", dense, thin);
        }
        // Grey in, grey out, near enough: the base's orange is taken away.
        let spread = (0..3).map(|c| dense[c]).fold(from_f64(0.0), Scalar::max) - (0..3).map(|c| dense[c]).fold(from_f64(1.0), Scalar::min);
        assert!(spread < from_f64(0.2), "dense {:?}", dense);
    }

    /// Qlick Lab: with auto exposure, a scanned negative is metered: the same
    /// negative, denser all over, prints the same.
    #[test]
    fn no_film_meters_a_scanned_negative() {
        let dir = data_dir();
        let film = profile::load_profile_by_name(&dir, "kodak_portra_400").unwrap();
        let print = profile::load_profile_by_name(&dir, "kodak_portra_endura").unwrap();
        let mut params = RuntimeParams::default();
        params.io.no_film = true;
        params.io.input_color_space = "sRGB".into();
        params.io.input_cctf_decoding = false;
        params.film_render.grain.active = false;
        let negative = |extra: f64| {
            let mut data = Vec::new();
            for y in 0..24 {
                for x in 0..24 {
                    let density = if y < 1 { 0.0 } else { extra + 0.2 + 0.05 * x as f64 };
                    data.extend([0.8, 0.5, 0.3].map(|b: f64| from_f64(b * 10f64.powf(-density))));
                }
            }
            ImageBuf::from_data(24, 24, data)
        };
        let pipeline = Pipeline::new_with_spectral(film, print, params, &dir).unwrap();
        let thin = pipeline.process(negative(0.0), &spektrafilm_gpu::cpu_backend::CpuBackend);
        let dense = pipeline.process(negative(0.6), &spektrafilm_gpu::cpu_backend::CpuBackend);
        for (a, b) in thin.data.iter().zip(&dense.data).skip(24 * 3) {
            assert!((a - b).abs() < 0.02, "{a} vs {b}");
        }
    }

    #[test]
    fn positive_slide_film_scan_stays_photographic() {
        let dir = data_dir();
        let film = profile::load_profile_by_name(&dir, "kodak_ektachrome_100").unwrap();
        let print = film.clone();

        let mut params = RuntimeParams::default();
        params.io.scan_film = true;
        params.camera.auto_exposure = false;

        let backend = spektrafilm_gpu::cpu_backend::CpuBackend;
        let mut data = Vec::with_capacity(64 * 64 * 3);
        for y in 0..64 {
            for x in 0..64 {
                data.push(from_f64(x as f64 / 63.0));
                data.push(from_f64(y as f64 / 63.0));
                data.push(from_f64(((x + y) as f64 / 126.0).powf(1.2)));
            }
        }
        let img = ImageBuf::from_data(64, 64, data);

        let pipeline = Pipeline::new_with_spectral(film, print, params.clone(), &dir)
            .unwrap()
            .with_params(params);
        assert_eq!(
            pipeline.params.film_render.dir_couplers.gamma_samelayer_rgb,
            Some([0.2291, 0.1029, 0.2651]),
            "GUI-style with_params must preserve positive-film DIR parameters"
        );
        let result = pipeline.process(img, &backend);
        let mut clipped_low = 0usize;
        let mut clipped_high = 0usize;
        for c in 0..3 {
            let values = result.data.iter().skip(c).step_by(3);
            let (mut min, mut max, mut sum) = (Scalar::INFINITY, Scalar::NEG_INFINITY, 0.0);
            let mut n = 0usize;
            for &v in values {
                min = min.min(v);
                max = max.max(v);
                sum += v;
                if v <= from_f64(0.0) {
                    clipped_low += 1;
                }
                if v >= from_f64(1.0) {
                    clipped_high += 1;
                }
                n += 1;
            }
            let mean = sum / n as Scalar;
            assert!(
                mean > from_f64(0.2) && mean < from_f64(0.8),
                "slide scan channel {c} mean is implausible: {mean} (min={min}, max={max})"
            );
        }
        let total = result.data.len();
        assert!(
            clipped_low < total / 20,
            "slide scan has too many black-clipped samples: {clipped_low}/{total}"
        );
        assert!(
            clipped_high < total / 20,
            "slide scan has too many white-clipped samples: {clipped_high}/{total}"
        );
    }
}

#[cfg(test)]
mod debug_tests {
    use crate::params::RuntimeParams;
    use crate::profile;
    use crate::stages;
    use spektrafilm_math::image::ImageBuf;
    use spektrafilm_math::precision::from_f64;
    use std::path::Path;

    #[test]
    fn debug_pipeline_values() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .unwrap()
            .parent()
            .unwrap()
            .join("data");
        let film = profile::load_profile_by_name(&dir, "kodak_portra_400").unwrap();
        let print = profile::load_profile_by_name(&dir, "kodak_portra_endura").unwrap();

        let mut params = RuntimeParams::default();
        params.film_render.grain.active = false;
        params.film_render.halation.active = false;
        params.film_render.dir_couplers.active = false;
        params.camera.auto_exposure = false;
        params.io.input_color_space = "sRGB".to_string();

        let backend = spektrafilm_gpu::cpu_backend::CpuBackend;
        let gray = from_f64(0.184);
        let img = ImageBuf::from_data(1, 1, vec![gray, gray, gray]);
        eprintln!("Input: {:?}", img.get(0, 0));

        let ref_illuminant = crate::illuminants::select_illuminant(&film.info.reference_illuminant);
        let log_raw = stages::filming::expose(
            img,
            &film,
            &params,
            &backend,
            None,
            &ref_illuminant,
            1.0,
            0.0,
        );
        eprintln!("log_raw: {:?}", log_raw.get(0, 0));

        let density_cmy = stages::filming::develop(log_raw, &film, &params, &backend);
        eprintln!("density_cmy: {:?}", density_cmy.get(0, 0));

        // Use simplified printing path for debug trace
        let printed = stages::printing::process(&density_cmy, &film, &print, &params, &backend);
        eprintln!("density_print: {:?}", printed.get(0, 0));
        let density_print = printed;
        let rgb_out = stages::scanning::scan(
            density_print,
            &print,
            &params,
            &backend,
            &crate::color_reference::ColorReference::identity(),
            &crate::gamut_compression::OutputGamutCompress::identity(),
        );
        eprintln!("rgb_out: {:?}", rgb_out.get(0, 0));
    }
}
