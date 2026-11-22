"""Build the Leica Monopan 50 profile (data/profiles/leica_monopan_50.json) from the extracted source points.

Inputs, all checked in (see extract_sources.py for how they were read from the datasheets):
    data/profile-sources/leica-monopan-50/monopan50-sensitivity.csv   Leica, spectral sensitivity
    data/profile-sources/leica-monopan-50/hr50-fx39-speedboost.csv    ADOX HR-50 in FX-39, red curve

Conventions follow the Tri-X preparation (data/profile-sources/bw-expansion/README.md) so the two behave alike:
- one channel (`channel_model: "bw"`), spectrally flat silver density, base density added once;
- engine log exposure 0 gives net density 0.75 above base + fog;
- spectral weights scaled so an 18.4 % grey under D55 gives unit raw exposure. The scale is transferred from the
  shipped Tri-X profile (whose grey is 1 by construction): for a neutral grey the reconstructed spectrum is flat,
  so raw ∝ Σ D55·S and the ratio of the two sums carries Tri-X's calibration over; a measured engine correction
  (ENGINE_GREY_CORRECTION) removes what that approximation misses. tests/leica_monopan.rs checks it in the engine.

Usage:
    python scripts/monopan/prepare.py [--output-dir data/profiles]
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
from datetime import date
from pathlib import Path

import numpy as np
from scipy.interpolate import PchipInterpolator
from scipy.optimize import least_squares
from scipy.stats import norm

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "data" / "profile-sources" / "leica-monopan-50"
STOCK = "leica_monopan_50"
WL = np.arange(380.0, 781.0, 5.0)
LOGE = np.linspace(-3.0, 4.0, 256)
ANCHOR_NET_DENSITY = 0.75
N_COMPONENTS = 4
MAX_SOURCE_ERROR = 0.01   # D, same gate as Tri-X
# The engine's reconstructed grey is not flat in the deep red / near infrared where this film is most sensitive,
# so the flat-spectrum transfer above leaves the grey at 0.88035 raw exposure (measured with the engine's
# hanatos2025 path, crates/spektrafilm-core/tests/leica_monopan.rs). This brings it back to 1.
ENGINE_GREY_CORRECTION = -np.log10(0.8803499937057495)


def read_csv(path: Path) -> np.ndarray:
    with path.open() as f:
        rows = list(csv.reader(f))[1:]
    return np.array([[float(v) for v in r] for r in rows])


def d55() -> np.ndarray:
    src = (ROOT / "crates/spektrafilm-math/src/spectral.rs").read_text()
    block = re.search(r"pub const ILLUMINANT_D55_F64: \[f64; N_WAVELENGTHS\] = \[(.*?)\];", src, re.S).group(1)
    v = np.array([float(x) for x in block.replace("\n", " ").split(",") if x.strip()])
    assert v.size == WL.size
    return v


def sensitivity():
    s = read_csv(SRC / "monopan50-sensitivity.csv")
    nm, logs = s[:, 0], s[:, 1]
    order = np.argsort(nm)
    nm, logs = nm[order], logs[order]
    keep = np.concatenate([[True], np.diff(nm) > 1e-6])
    nm, logs = nm[keep], logs[keep]
    lo, hi = nm.min(), nm.max()
    out = np.full(WL.size, np.nan)
    inside = (WL >= lo) & (WL <= hi)
    out[inside] = PchipInterpolator(nm, logs)(WL[inside])
    # The plotted curve ends on the graph floor (log S = 0) at 778.6 nm; below that floor nothing is measured.
    out[out < 0.0] = np.nan
    return out, (lo, hi)


def grey_shift(logs: np.ndarray) -> float:
    """log10 shift making an 18.4 % D55 grey give raw exposure 1, calibrated on the shipped Tri-X."""
    trix = json.loads((ROOT / "data/profiles/kodak_trix400_d76_8min.json").read_text())
    tl = np.array([np.nan if r[0] is None else r[0] for r in trix["data"]["log_sensitivity"]], dtype=float)
    ill = d55()
    s_trix = np.nansum(ill * 10 ** tl)
    s_mono = np.nansum(ill * 10 ** logs)
    return float(np.log10(s_trix / s_mono)) + ENGINE_GREY_CORRECTION


def model(params, x, base):
    c, a, s = np.split(params, 3)
    return base + sum(a[i] * norm.cdf((x - c[i]) / s[i]) for i in range(N_COMPONENTS))


def characteristic():
    r = read_csv(SRC / "hr50-fx39-speedboost.csv")
    x, d = r[:, 0], r[:, 1]
    order = np.argsort(x)
    x, d = x[order], d[order]
    # Free base + fog between the technical base film's floor (0.10, same PET support, blue curve) and the
    # lowest plotted red density: the toe below the plot is not measured, the fit continues it smoothly.
    span = x.max() - x.min()
    c0 = np.linspace(x.min() + 0.15 * span, x.max() - 0.2 * span, N_COMPONENTS)
    a0 = np.full(N_COMPONENTS, (d.max() - 0.15) / N_COMPONENTS)
    s0 = np.full(N_COMPONENTS, span / 6)
    p0 = np.concatenate([c0, a0, s0, [0.15]])
    lo = np.concatenate([np.full(N_COMPONENTS, x.min() - span), np.zeros(N_COMPONENTS), np.full(N_COMPONENTS, 0.05), [0.10]])
    hi = np.concatenate([np.full(N_COMPONENTS, x.max() + span), np.full(N_COMPONENTS, 2.0), np.full(N_COMPONENTS, 3.0), [d.min()]])
    res = least_squares(lambda p: model(p[:-1], x, p[-1]) - d, p0, bounds=(lo, hi), max_nfev=20000)
    p, base = res.x[:-1], res.x[-1]
    err = np.abs(model(p, x, base) - d).max()
    return x, d, p, base, err


def fmt(v, digits=10):
    return None if v is None or not np.isfinite(v) else float(round(float(v), digits))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--output-dir", type=Path, default=ROOT / "target" / "monopan")
    args = ap.parse_args()

    logs, (lo, hi) = sensitivity()
    shift = grey_shift(logs)
    logs_n = logs + shift

    x, d, p, base, err = characteristic()
    assert err < MAX_SOURCE_ERROR, f"fit error {err:.4f} D"
    c, a, s = np.split(p, 3)
    # Re-anchor: engine log E 0 ↔ net density 0.75 above base + fog.
    net = lambda xx: model(p, xx, 0.0)
    xs = np.linspace(x.min() - 3, x.max() + 3, 20001)
    origin = float(np.interp(ANCHOR_NET_DENSITY, net(xs), xs))
    c_eng = c - origin
    layers = np.stack([a[i] * norm.cdf((LOGE - c_eng[i]) / s[i]) for i in range(N_COMPONENTS)], axis=1)
    curves = layers.sum(axis=1)
    # Python/Rust development subtracts the sampled floor; keep the floor tiny so the source still matches.
    floor = float(curves.min())
    order = np.argsort(c_eng)

    leica = json.loads((SRC / "extraction.json").read_text())
    today = date.today().isoformat()
    profile = {
        "metadata": {
            "version": "qlicklab-monopan-1",
            "created": today,
            "copyright": "Preparation: Qlick Lab (Quentin Descotte / Jackfrom), 2026. Manufacturer source rights retained.",
            "license": "Preparation and profile: CC BY-SA 4.0. Manufacturer graph data retain their original rights.",
            "citation": "Spektrafilm by Andrea Volpato and contributors; https://github.com/andreavolpato/spektrafilm . "
                        "New calibration in spektrafilm's format, not an upstream stock profile.",
            "datasource": (
                f"Spectral sensitivity: {leica['leica']['document']}; {leica['leica']['url']}; SHA256 {leica['leica']['sha256']}. "
                f"Characteristic curve: {leica['adox']['document']}, red curve (SPEED BOOST) in ADOX FX-39 1+9, 7 min 15 s, 20 C; "
                f"{leica['adox']['url']}; SHA256 {leica['adox']['sha256']}. "
                "Assumption: Monopan 50 is ADOX HR-50 (identical development table, gamma, reciprocity and spectral range); "
                "neither Leica nor ADOX states it. Unnumbered log E axis read as 0.5 per grid column (implied gamma "
                f"{leica['adox']['implied_gamma']:.3f}, sheet gamma 0.65). Sensitivity PCHIP over {lo:.1f}-{hi:.1f} nm, null below the "
                "graph floor. Toe below D 0.20 and shoulder above D 1.49 are smooth continuations, not measurements. "
                "Reproduce with scripts/monopan/prepare.py; sources and checks in data/profile-sources/leica-monopan-50/."
            ),
        },
        "info": {
            "stock": STOCK,
            "name": "Leica Monopan 50",
            "type": "negative",
            "support": "film",
            "stage": "filming",
            "use": "still",
            "antihalation": "strong",
            "target_print": "ilford_mgrc_deluxe_grade2",
            "channel_model": "bw",
            "densitometer": "diffuse_visual",
            "log_sensitivity_density_over_min": 1.0,
            "reference_illuminant": "D55",
            "viewing_illuminant": "D50",
        },
        "data": {
            "wavelengths": [fmt(w) for w in WL],
            "log_sensitivity": [[fmt(v)] for v in logs_n],
            "channel_density": [[1.0] for _ in WL],
            "base_density": [[fmt(base)] for _ in WL],
            "log_exposure": [fmt(v) for v in LOGE],
            "density_curves": [[fmt(v)] for v in curves],
            "development_time": [7.25],
            "density_curves_model": {
                "model_type": "norm_cdfs",
                "centers": [[float(c_eng[i]) for i in order]],
                "amplitudes": [[float(a[i]) for i in order]],
                "sigmas": [[float(s[i]) for i in order]],
            },
            "density_curves_layers": [[[fmt(layers[j, i])] for i in order] for j in range(LOGE.size)],
        },
    }
    args.output_dir.mkdir(parents=True, exist_ok=True)
    out = args.output_dir / f"{STOCK}.json"
    out.write_text(json.dumps(profile, indent=4) + "\n")

    # Agreement with the source, the way the runtime reads it (floor subtracted, base added once).
    rt = np.interp(x - origin, LOGE, curves) - floor + base
    report = {
        "source_exposure_origin": origin,
        "sensitivity_log_shift": shift,
        "base_plus_fog": base,
        "max_source_density_error": float(np.abs(rt - d).max()),
        "minimum_sampled_net_density": floor,
        "tolerance": MAX_SOURCE_ERROR,
        "density_range_total": [float(curves.min() + base), float(curves.max() + base)],
        "speed_point_logE_net_0_1": float(np.interp(0.1, curves, LOGE)),
        "sensitivity_range_nm": [lo, hi],
        "sha256": hashlib.sha256(out.read_bytes()).hexdigest(),
    }
    (SRC / "preparation-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    plot(logs_n, x - origin, d, curves, base, floor, SRC / "review" / "02-profile.png")


def plot(logs, xsrc, dsrc, curves, base, floor, path):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    trix = json.loads((ROOT / "data/profiles/kodak_trix400_d76_8min.json").read_text())["data"]
    tl = np.array([np.nan if r[0] is None else r[0] for r in trix["log_sensitivity"]], dtype=float)
    tc = np.array([r[0] for r in trix["density_curves"]]) + trix["base_density"][0][0]

    fg, dim, red = "#e8e8ea", "#8a8a8f", "#e5222b"
    fig, (a1, a2) = plt.subplots(1, 2, figsize=(15, 5.6), dpi=130, facecolor="#141415")
    for ax in (a1, a2):
        ax.set_facecolor("#141415")
        ax.tick_params(colors=dim)
        for sp in ax.spines.values():
            sp.set_color("#28282a")
        ax.grid(color="#28282a", lw=0.6)
    # Visible-band hint
    for lo, hi, col in [(380, 450, "#3b5bdb"), (450, 500, "#15aabf"), (500, 570, "#40c057"), (570, 600, "#fab005"),
                        (600, 700, "#f03e3e"), (700, 780, "#5c2b2b")]:
        a1.axvspan(lo, hi, color=col, alpha=0.10, lw=0)
    a1.plot(WL, tl - np.nanmax(tl), color=dim, lw=1.4, ls="--", label="Kodak Tri-X 400 (référence)")
    a1.plot(WL, logs - np.nanmax(logs), color=red, lw=2.4, label="Leica Monopan 50")
    a1.axvline(700, color=dim, lw=0.8, ls=":")
    a1.text(705, -1.55, "proche IR\n(non capté par\nles capteurs)", color=dim, fontsize=8)
    a1.set_xlim(380, 780)
    a1.set_ylim(-1.8, 0.15)
    a1.set_xlabel("Longueur d'onde (nm)", color=fg)
    a1.set_ylabel("log sensibilité (relative au pic)", color=fg)
    a1.set_title("Sensibilité spectrale dans le profil", color=fg)
    a1.legend(facecolor="#1c1c1e", edgecolor="#28282a", labelcolor=fg, fontsize=9)

    a2.plot(LOGE, tc, color=dim, lw=1.4, ls="--", label="Kodak Tri-X 400 / D-76 (référence)")
    a2.plot(LOGE, curves - floor + base, color=red, lw=2.4, label="Monopan 50 — modèle du profil")
    a2.scatter(xsrc[::12], dsrc[::12], s=9, color=fg, zorder=5, label="points de la fiche ADOX (FX-39)")
    a2.axvline(0, color=dim, lw=0.8, ls=":")
    a2.text(0.05, 0.08, "gris moyen\n18 %", color=dim, fontsize=8)
    a2.set_xlim(-3, 4)
    a2.set_ylim(0, 2.6)
    a2.set_xlabel("log exposition (0 = gris moyen)", color=fg)
    a2.set_ylabel("densité totale", color=fg)
    a2.set_title("Courbe caractéristique dans le profil", color=fg)
    a2.legend(facecolor="#1c1c1e", edgecolor="#28282a", labelcolor=fg, fontsize=9, loc="upper left")
    fig.tight_layout()
    fig.savefig(path, facecolor=fig.get_facecolor())


if __name__ == "__main__":
    main()
