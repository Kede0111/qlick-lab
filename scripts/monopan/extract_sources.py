"""Extract the Leica Monopan 50 source curves from the two manufacturer datasheets.

Both graphs are vector paths (cubic Béziers) in the PDFs, so the points are read exactly, not traced by hand.

- Spectral sensitivity: Leica Monopan 50 technical data, June 2025 (pm-23344, Dutch edition), page 2.
- Characteristic curve: ADOX HR-50 technical description, 20 Nov 2018 (ASC5011, English), page 1, red curve
  ("ADOX HR-50 with ADOX SPEED BOOST"), developed in ADOX FX-39. The Leica sheet has no characteristic curve;
  its development table (developers, times, gamma 0.65, reciprocity) is identical to the HR-50 sheet, which is
  the basis for borrowing it. That identity is an assumption, not a statement by Leica or ADOX.

The HR-50 log-exposure axis carries no numbers. Its grid is regular (17.24 pt per column); the scale is set
so that the straight part of the curve has the gamma the sheet gives for FX-39 1+9, 7 min 15 s: 0.65.

Usage:
    python scripts/monopan/extract_sources.py --leica-pdf LEICA.pdf --adox-pdf ADOX.pdf
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
from pathlib import Path

import fitz  # PyMuPDF
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "data" / "profile-sources" / "leica-monopan-50"

LEICA_SHA256 = "81d55277de23b8a2fb2fe61674bae9c2612ed6afe85df53fe5ea708aeda2097f"
ADOX_SHA256 = "4ba8752ecaca593ec3bd2857024db659945f341284fb82e7a698e96c7c9b2998"

GAMMA_FX39 = 0.65


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def bezier_points(drawing, per_segment: int = 48) -> np.ndarray:
    """Sample a path made of cubic Béziers ('c') and lines ('l') in page points."""
    pts = []
    for item in drawing["items"]:
        if item[0] == "c":
            p0, c1, c2, p3 = (np.array([q.x, q.y]) for q in item[1:5])
            t = np.linspace(0, 1, per_segment, endpoint=False)[:, None]
            pts.append((1 - t) ** 3 * p0 + 3 * (1 - t) ** 2 * t * c1 + 3 * (1 - t) * t ** 2 * c2 + t ** 3 * p3)
            last = p3
        elif item[0] == "l":
            p0, p1 = (np.array([q.x, q.y]) for q in item[1:3])
            pts.append(p0[None, :])
            last = p1
    pts.append(last[None, :])
    return np.vstack(pts)


def leica_sensitivity(pdf: Path):
    page = fitz.open(pdf)[1]
    drawings = page.get_drawings()
    # The curve: the one dark stroked path in the graph area made only of Béziers.
    curve = [d for d in drawings
             if d.get("type") == "s" and d["rect"].y0 > 440 and d["rect"].y1 < 600
             and all(it[0] == "c" for it in d["items"]) and len(d["items"]) > 10]
    assert len(curve) == 1, f"expected one sensitivity path, found {len(curve)}"
    words = page.get_text("words")
    # x axis: the centres of the wavelength labels 300 … 800.
    xl = sorted(((w[0] + w[2]) / 2, float(w[4])) for w in words
                if 575 < w[1] < 590 and w[4].isdigit() and 300 <= int(w[4]) <= 800)
    xs, nms = np.array(xl).T
    x_slope, x_icpt = np.polyfit(xs, nms, 1)
    # y axis: the red dashed grid lines at log D 1.5, 1.0, 0.5 (same y on every dash).
    grid_y = sorted({round(d["rect"].y0, 2) for d in drawings
                     if d.get("dashes") and d["dashes"] != "[] 0" and d["rect"].height < 0.1 and d["rect"].width > 100})
    assert len(grid_y) == 3, grid_y
    y_vals = np.array([1.5, 1.0, 0.5])
    y_slope, y_icpt = np.polyfit(np.array(grid_y), y_vals, 1)
    pts = bezier_points(curve[0])
    nm = x_slope * pts[:, 0] + x_icpt
    logs = y_slope * pts[:, 1] + y_icpt
    calib = {"x_nm_per_pt": x_slope, "x_nm_at_pt0": x_icpt, "x_label_centres_pt": xs.tolist(),
             "y_logS_per_pt": y_slope, "y_logS_at_pt0": y_icpt, "y_grid_pt": grid_y,
             "segments": len(curve[0]["items"])}
    return pts, nm, logs, calib


def adox_characteristic(pdf: Path):
    page = fitz.open(pdf)[0]
    drawings = page.get_drawings()
    in_graph = [d for d in drawings if d["rect"].x0 > 400 and 460 < d["rect"].y0 < 570]
    def colour(d):
        return tuple(round(v, 2) for v in (d.get("color") or ()))
    red = [d for d in in_graph if colour(d) == (0.93, 0.19, 0.17) and all(it[0] == "c" for it in d["items"])]
    blue = [d for d in in_graph if colour(d) == (0.13, 0.34, 0.65) and all(it[0] == "c" for it in d["items"])]
    assert len(red) == 1 and len(blue) == 1, (len(red), len(blue))
    frame = [d for d in in_graph if d["items"][0][0] == "re"][0]["rect"]
    # Horizontal grid lines, bottom to top, labelled 0.1 0.2 0.3 0.5 0.7 0.9 1.1 1.3 1.5; frame top 1.7, bottom 0.
    hgrid = sorted({round(d["rect"].y0, 2) for d in in_graph
                    if d["items"][0][0] == "l" and d["rect"].height < 0.1 and d["rect"].width > 100}, reverse=True)
    assert len(hgrid) == 9, hgrid
    dens_labels = [0.1, 0.2, 0.3, 0.5, 0.7, 0.9, 1.1, 1.3, 1.5]
    ys = np.array([frame.y1, *hgrid, frame.y0])
    ds = np.array([0.0, *dens_labels, 1.7])
    y_slope, y_icpt = np.polyfit(ys, ds, 1)
    vgrid = sorted({round(d["rect"].x0, 2) for d in in_graph if d["rect"].width < 1 and d["rect"].height > 20})
    col_pt = float(np.mean(np.diff(vgrid)))

    def sample(d):
        pts = bezier_points(d)
        return pts, y_slope * pts[:, 1] + y_icpt

    rpts, rden = sample(red[0])
    bpts, bden = sample(blue[0])
    # Gamma: slope of the straight part, fitted between densities 0.55 and 1.15 above the curve's own minimum.
    net = rden - rden.min()
    m = (net > 0.55) & (net < 1.15)
    slope_per_pt = np.polyfit(rpts[m, 0], rden[m], 1)[0]   # D per pt (x grows to the right)
    # Scaling the axis so this slope is the sheet's gamma 0.65 gives 0.487 log E per grid column: the grid is
    # read as the usual 0.5 log E per column, and the gamma it implies is kept as a check.
    logE_per_gamma = slope_per_pt / GAMMA_FX39
    logE_per_pt = 0.5 / col_pt
    implied_gamma = slope_per_pt / logE_per_pt
    # Origin: log E = 0 at the frame's left edge (relative axis; the profile is re-anchored later).
    to_logE = lambda x: (x - frame.x0) * logE_per_pt
    calib = {"frame_pt": [frame.x0, frame.y0, frame.x1, frame.y1], "hgrid_pt": hgrid, "density_labels": dens_labels,
             "y_D_per_pt": y_slope, "y_D_at_pt0": y_icpt, "vgrid_pt": vgrid, "grid_column_pt": col_pt,
             "gamma_datasheet": GAMMA_FX39, "straight_part_net_density": [0.55, 1.15],
             "logE_per_grid_column_from_gamma": logE_per_gamma * col_pt,
             "logE_per_pt": logE_per_pt, "logE_per_grid_column": logE_per_pt * col_pt,
             "implied_gamma": implied_gamma,
             "red_segments": len(red[0]["items"]), "blue_segments": len(blue[0]["items"])}
    return (rpts, to_logE(rpts[:, 0]), rden), (bpts, to_logE(bpts[:, 0]), bden), calib


def write_csv(path: Path, header, rows):
    with path.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        for r in rows:
            w.writerow([f"{v:.9f}" for v in r])


def review(leica_pdf, adox_pdf, sens, red, blue, out: Path):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    def crop(pdf, page_no, clip, zoom=6):
        pix = fitz.open(pdf)[page_no].get_pixmap(matrix=fitz.Matrix(zoom, zoom), clip=fitz.Rect(*clip))
        img = np.frombuffer(pix.samples, dtype=np.uint8).reshape(pix.h, pix.w, pix.n)
        return img, clip, zoom

    fig, axes = plt.subplots(1, 2, figsize=(16, 6.2), dpi=130, facecolor="#141415")
    for ax, (pdf, pg, clip, series, title) in zip(axes, [
        (leica_pdf, 1, (135, 440, 445, 615), [(sens[0], "#22c55e", "extrait (Leica)")],
         "Leica Monopan 50 — sensibilité spectrale"),
        (adox_pdf, 0, (395, 455, 550, 572), [(red[0], "#22c55e", "extrait Speed Boost"), (blue[0], "#eab308", "extrait base technique")],
         "ADOX HR-50 in FX-39 — courbe caractéristique"),
    ]):
        img, c, z = crop(pdf, pg, clip)
        ax.imshow(img)
        for pts, col, lab in series:
            ax.plot((pts[:, 0] - c[0]) * z, (pts[:, 1] - c[1]) * z, color=col, lw=1.2, ls=(0, (3, 2)), label=lab)
        ax.set_title(title, color="white", fontsize=12)
        ax.legend(loc="lower center", fontsize=9)
        ax.axis("off")
    fig.suptitle("Extraction vectorielle superposée à la fiche d'origine (pointillés verts/jaunes = points extraits)",
                 color="#cfcfd3", fontsize=11)
    fig.tight_layout(rect=(0, 0, 1, 0.93))
    fig.savefig(out, facecolor=fig.get_facecolor())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--leica-pdf", type=Path, required=True)
    ap.add_argument("--adox-pdf", type=Path, required=True)
    args = ap.parse_args()
    for p, h in [(args.leica_pdf, LEICA_SHA256), (args.adox_pdf, ADOX_SHA256)]:
        if sha256(p) != h:
            raise SystemExit(f"{p}: SHA-256 does not match the documented datasheet")
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "review").mkdir(exist_ok=True)

    spts, nm, logs, lcal = leica_sensitivity(args.leica_pdf)
    write_csv(OUT / "monopan50-sensitivity.csv", ["wavelength_nm", "log10_sensitivity", "pdf_x_pt", "pdf_y_pt"],
              zip(nm, logs, spts[:, 0], spts[:, 1]))
    red, blue, acal = adox_characteristic(args.adox_pdf)
    write_csv(OUT / "hr50-fx39-speedboost.csv", ["relative_log10_exposure", "density", "pdf_x_pt", "pdf_y_pt"],
              zip(red[1], red[2], red[0][:, 0], red[0][:, 1]))
    write_csv(OUT / "hr50-fx39-base-technical.csv", ["relative_log10_exposure", "density", "pdf_x_pt", "pdf_y_pt"],
              zip(blue[1], blue[2], blue[0][:, 0], blue[0][:, 1]))
    (OUT / "extraction.json").write_text(json.dumps({
        "leica": {"document": "Leica Monopan 50 Technische gegevens, juni 2025 (pm-23344, NL)",
                  "url": "https://leica-camera.com/sites/default/files/pm-23344-Leica-Monopan50_Technical-Data_nl.pdf",
                  "sha256": LEICA_SHA256, "page_1based": 2, **lcal},
        "adox": {"document": "ADOX HR-50 High Resolution Film, Technische Beschreibung, 20 Nov 2018 (ASC5011, EN)",
                 "url": "https://www.macodirect.de/media/pdf/c2/97/cf/ASC5011_Datenblatt_e.pdf",
                 "sha256": ADOX_SHA256, "page_1based": 1, **acal},
    }, indent=2) + "\n")
    review(args.leica_pdf, args.adox_pdf, (spts,), red, blue, OUT / "review" / "01-extraction.png")
    print(f"sensitivity: {nm.min():.1f}–{nm.max():.1f} nm, log S {logs.min():.3f}–{logs.max():.3f}")
    print(f"HR-50: D {red[2].min():.3f}–{red[2].max():.3f}, log E span {red[1].max() - red[1].min():.3f}, "
          f"gamma 0.65 would give {acal['logE_per_grid_column_from_gamma']:.4f} log E per column; "
          f"at 0.5 per column the implied gamma is {acal['implied_gamma']:.3f}")


if __name__ == "__main__":
    main()
