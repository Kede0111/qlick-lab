//! Leica Monopan 50: the prepared profile against its manufacturer sources, and its exposure calibration
//! in the real engine (data/profile-sources/leica-monopan-50/README.md).
use spektrafilm_core::{params::RuntimeParams, pipeline::Pipeline, profile};
use spektrafilm_math::{image::ImageBuf, precision::{from_f64, to_f64}};
use std::path::PathBuf;

const FILM: &str = "leica_monopan_50";
const PAPER: &str = "ilford_mgrc_deluxe_grade2";

fn data_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../data")
}

fn params() -> RuntimeParams {
    let mut p: RuntimeParams = serde_json::from_str(include_str!("fixtures/bw-expansion/trix-paper.json")).unwrap();
    p.io.input_cctf_decoding = false;
    p.io.output_cctf_encoding = false;
    p.camera.auto_exposure = false;
    p
}

#[test]
fn monopan_is_a_black_and_white_negative_printed_on_multigrade() {
    let p = profile::load_profile_by_name(&data_dir(), FILM).unwrap();
    assert!(p.is_bw() && p.is_negative() && p.is_film());
    assert_eq!(p.info.target_print.as_deref(), Some(PAPER));
    // Superpanchromatic: still sensitive at 750 nm, where Tri-X has long stopped.
    let at = |nm: f64| p.data.log_sensitivity[((nm - 380.0) / 5.0) as usize][0];
    assert!(at(750.0).is_finite() && at(750.0) > at(500.0) - 0.5);
    let trix = profile::load_profile_by_name(&data_dir(), "kodak_trix400_d76_8min").unwrap();
    assert!(!trix.data.log_sensitivity[74][0].is_finite());
}

#[test]
fn loaded_model_agrees_with_the_adox_curve() {
    let report: serde_json::Value =
        serde_json::from_str(include_str!("../../../data/profile-sources/leica-monopan-50/preparation-report.json")).unwrap();
    let p = profile::load_profile_by_name(&data_dir(), FILM).unwrap();
    let origin = report["source_exposure_origin"].as_f64().unwrap();
    let (x, d) = (&p.data.log_exposure, &p.data.density_curves);
    let floor = d[0][0];
    let source = include_str!("../../../data/profile-sources/leica-monopan-50/hr50-fx39-speedboost.csv");
    for row in source.lines().skip(1) {
        let v: Vec<f64> = row.split(',').map(|s| s.parse().unwrap()).collect();
        let at = v[0] - origin;
        let i = x.partition_point(|e| *e < at).clamp(1, x.len() - 1);
        let t = ((at - x[i - 1]) / (x[i] - x[i - 1])).clamp(0.0, 1.0);
        let total = d[i - 1][0] * (1.0 - t) + d[i][0] * t - floor + p.data.base_density[0];
        assert!((total - v[1]).abs() < 0.01, "source {row}, runtime {total}");
    }
}

/// The raw exposure an 18.4 % grey gives the film, through the engine's spectral reconstruction.
fn grey_raw(film: &str) -> f64 {
    let pipeline = Pipeline::new_with_spectral(
        profile::load_profile_by_name(&data_dir(), film).unwrap(),
        profile::load_profile_by_name(&data_dir(), PAPER).unwrap(),
        params(),
        &data_dir(),
    )
    .unwrap();
    let grey = ImageBuf::from_data(2, 2, vec![from_f64(0.184); 12]);
    let (raw, _) = pipeline.metering_film_raw(&grey);
    to_f64(raw.data[0])
}

#[test]
fn mid_grey_gives_unit_exposure_like_tri_x() {
    let trix = grey_raw("kodak_trix400_d76_8min");
    let mono = grey_raw(FILM);
    assert!((trix - 1.0).abs() < 0.02, "Tri-X grey raw {trix}");
    assert!((mono - 1.0).abs() < 0.02, "Monopan grey raw {mono}");
}
