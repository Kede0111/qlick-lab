//! Auto Straighten: the angle that levels a photograph, read from a small grey picture of it.
//!
//! Ported for Qlick Lab from Lightcraft's `crates/pipeline/src/straighten.rs` and `upright.rs`
//! (<https://github.com/storytold/lightcraft>, MIT or Apache-2.0, at the reader's choice; their notice is kept in
//! `LICENSES.md`). Three cues, tried in this order:
//!
//! 1. **Plumb lines**: the roll named by the vanishing point of the near-vertical lines. Verticals that converge in
//!    perspective (a building shot from below) still name the camera's roll, where their mean tilt wouldn't. Only a
//!    vanishing point backed by many lines across the frame counts.
//! 2. **The horizon**: the straight line across the whole width along which it is brighter on one side than on the
//!    other (sky and sea, sky and land), scored by its weaker columns, so the edges of waves, clouds or a ridge,
//!    which hold only in places, don't make one.
//! 3. **Long lines**: the consensus of near-level or near-upright segments, with at least [`MIN_LINES`] agreeing.
//!    It also vetoes a horizon it disagrees with.
//!
//! Nothing past [`MAX_DEGREES`] is levelled. Lightcraft measured it on 113 photographs straightened by hand: the
//! mean error went from 1.01° (long lines alone) to 0.82°.
//!
//! Coordinates: centred, `(p − centre) / (long side / 2)`, so the results don't depend on the picture's size.

/// The most the photograph is turned (degrees). None of the 113 photographs straightened by hand needed more than
/// 6.1°; larger "levels" came from texture (planks, a branch, a bird's wing).
pub const MAX_DEGREES: f64 = 5.0;
/// The fewest agreeing long lines that level a photograph on their own.
pub const MIN_LINES: usize = 3;
/// The long side the picture is best read at (the thresholds below are tuned for it).
pub const ANALYSIS_LONG: usize = 1024;

const LINES_MAX_DEGREES: f64 = 10.0;
const VETO_DEGREES: f64 = 1.0;
const PLUMB_MIN_LINES: usize = 8;
const PLUMB_MIN_LENGTH: f64 = 1.5;
const PLUMB_MIN_SPREAD: f64 = 0.6;
const PLUMB_MAX_LEAN: f64 = 20.0;
const HORIZON_SIGMA: f32 = 1.5;
const HORIZON_ROWS: usize = 4;
const HORIZON_QUANTILE: f64 = 0.3;
const HORIZON_MIN_SCORE: f64 = 0.3;
const HORIZON_MARGIN: f64 = 0.05;
const HORIZON_SEARCH: f64 = 10.0;
const HORIZON_STEP: f64 = 0.25;
const HORIZON_FINE_STEP: f64 = 0.02;

/// A grey picture, rows from the top, values about 0…1 and perceptual (not linear light).
#[derive(Clone, Debug)]
pub struct Gray {
    pub width: usize,
    pub height: usize,
    pub data: Vec<f32>,
}

impl Gray {
    /// From 8-bit grey (as drawn from what the canvas shows), scaled so its bright end (99th percentile) is 1.
    pub fn from_bytes(width: usize, height: usize, bytes: &[u8]) -> Option<Gray> {
        if width == 0 || height == 0 || bytes.len() < width * height {
            return None;
        }
        let mut sorted: Vec<u8> = bytes[..width * height].to_vec();
        sorted.sort_unstable();
        let white = (f32::from(sorted[sorted.len() * 99 / 100]) / 255.0).max(1e-3);
        let data = bytes[..width * height].iter().map(|&b| (f32::from(b) / 255.0 / white).min(1.5)).collect();
        Some(Gray { width, height, data })
    }
}

/// Which cue levelled the photograph.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Cue {
    Plumb,
    Horizon,
    Lines,
}

impl Cue {
    pub fn name(self) -> &'static str {
        match self {
            Cue::Plumb => "plumb",
            Cue::Horizon => "horizon",
            Cue::Lines => "lines",
        }
    }
}

/// The angle (degrees, clockwise on screen) that levels the photograph, and the cue it came from; `None` when no
/// cue can be trusted.
pub fn level(gray: &Gray) -> Option<(f64, Cue)> {
    let segments = detect_segments(gray);
    let vertical: Vec<Segment> = segments.iter().copied().filter(|s| s.tilt_from_vertical() < 30.0).collect();
    let horizontal: Vec<Segment> = segments.iter().copied().filter(|s| s.tilt_from_vertical() > 60.0).collect();
    if let Some(roll) = plumb_roll(&vertical) {
        return Some((roll, Cue::Plumb));
    }
    let lines = level_angle_within(&vertical, &horizontal, LINES_MAX_DEGREES, MIN_LINES);
    match (horizon(gray), lines) {
        (Some(h), Some(l)) => ((h - l).abs() <= VETO_DEGREES).then_some((h, Cue::Horizon)),
        (Some(h), None) => Some((h, Cue::Horizon)),
        (None, l) => l.filter(|l| l.abs() <= MAX_DEGREES).map(|l| (l, Cue::Lines)),
    }
}

// MARK: Geometry

#[derive(Clone, Copy, Debug, PartialEq)]
struct Point {
    x: f64,
    y: f64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct Segment {
    a: Point,
    b: Point,
}

impl Segment {
    fn len(&self) -> f64 {
        (self.b.x - self.a.x).hypot(self.b.y - self.a.y)
    }
    fn mid(&self) -> Point {
        Point { x: (self.a.x + self.b.x) / 2.0, y: (self.a.y + self.b.y) / 2.0 }
    }
    /// The line through the ends, homogeneous, with (a, b) a unit normal.
    fn line(&self) -> [f64; 3] {
        let l = cross([self.a.x, self.a.y, 1.0], [self.b.x, self.b.y, 1.0]);
        let n = l[0].hypot(l[1]).max(1e-12);
        [l[0] / n, l[1] / n, l[2] / n]
    }
    /// Degrees from upright (0 = upright), folded to 0…90.
    fn tilt_from_vertical(&self) -> f64 {
        let (dx, dy) = (self.b.x - self.a.x, self.b.y - self.a.y);
        dx.abs().atan2(dy.abs()).to_degrees()
    }
}

fn cross(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
}

fn dot(a: [f64; 3], b: [f64; 3]) -> f64 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

fn norm(a: [f64; 3]) -> [f64; 3] {
    let n = dot(a, a).sqrt().max(1e-300);
    [a[0] / n, a[1] / n, a[2] / n]
}

fn fold(a: f64) -> f64 {
    if a > 90.0 {
        a - 180.0
    } else if a < -90.0 {
        a + 180.0
    } else {
        a
    }
}

/// A separable Gaussian blur, edges clamped.
fn gaussian(gray: &Gray, sigma: f32) -> Gray {
    let radius = (sigma * 3.0).ceil() as isize;
    let kernel: Vec<f32> = (-radius..=radius).map(|i| (-(i * i) as f32 / (2.0 * sigma * sigma)).exp()).collect();
    let sum: f32 = kernel.iter().sum();
    let kernel: Vec<f32> = kernel.iter().map(|k| k / sum).collect();
    let (w, h) = (gray.width, gray.height);
    let mut across = vec![0f32; w * h];
    for y in 0..h {
        for x in 0..w {
            let mut acc = 0.0;
            for (k, weight) in kernel.iter().enumerate() {
                let sx = (x as isize + k as isize - radius).clamp(0, w as isize - 1) as usize;
                acc += weight * gray.data[y * w + sx];
            }
            across[y * w + x] = acc;
        }
    }
    let mut out = vec![0f32; w * h];
    for y in 0..h {
        for x in 0..w {
            let mut acc = 0.0;
            for (k, weight) in kernel.iter().enumerate() {
                let sy = (y as isize + k as isize - radius).clamp(0, h as isize - 1) as usize;
                acc += weight * across[sy * w + x];
            }
            out[y * w + x] = acc;
        }
    }
    Gray { width: w, height: h, data: out }
}

// MARK: Segments

/// Line segments: pixels of strong gradient grown into regions of one level-line direction (from the strongest
/// gradients first), each long, thin region fitted with a segment (its weighted principal axis).
fn detect_segments(gray: &Gray) -> Vec<Segment> {
    let (w, h) = (gray.width, gray.height);
    if w < 16 || h < 16 {
        return Vec::new();
    }
    let img = gaussian(gray, 0.8);
    let at = |x: usize, y: usize| img.data[y * w + x];
    let n = w * h;
    let mut mag = vec![0.0f32; n];
    let mut ang = vec![0.0f32; n];
    for y in 1..h - 1 {
        for x in 1..w - 1 {
            let gx = (at(x + 1, y - 1) + 2.0 * at(x + 1, y) + at(x + 1, y + 1)) - (at(x - 1, y - 1) + 2.0 * at(x - 1, y) + at(x - 1, y + 1));
            let gy = (at(x - 1, y + 1) + 2.0 * at(x, y + 1) + at(x + 1, y + 1)) - (at(x - 1, y - 1) + 2.0 * at(x, y - 1) + at(x + 1, y - 1));
            mag[y * w + x] = gx.hypot(gy) / 8.0;
            ang[y * w + x] = (gy.atan2(gx) + std::f32::consts::FRAC_PI_2).rem_euclid(std::f32::consts::PI);
        }
    }
    let mut sorted: Vec<f32> = mag.iter().copied().filter(|m| *m > 1e-4).collect();
    if sorted.len() < 32 {
        return Vec::new();
    }
    sorted.sort_by(f32::total_cmp);
    let p90 = sorted[sorted.len() * 9 / 10];
    let thr = (p90 * 0.35).max(0.008);
    let mut order: Vec<u32> = (0..n as u32).filter(|&i| mag[i as usize] > thr).collect();
    order.sort_by(|&a, &b| mag[b as usize].total_cmp(&mag[a as usize]));
    let mut used = vec![false; n];
    let tol = 22.5f32.to_radians();
    let min_len = 0.04 * w.max(h) as f64;
    let half_long = w.max(h) as f64 / 2.0;
    let (cx, cy) = (w as f64 / 2.0, h as f64 / 2.0);
    let mut out = Vec::new();
    let mut stack: Vec<usize> = Vec::new();
    let mut region: Vec<usize> = Vec::new();
    for &seed in &order {
        let seed = seed as usize;
        if used[seed] {
            continue;
        }
        used[seed] = true;
        region.clear();
        region.push(seed);
        stack.clear();
        stack.push(seed);
        let (mut sc, mut ss) = ((2.0 * ang[seed]).cos(), (2.0 * ang[seed]).sin());
        while let Some(i) = stack.pop() {
            let (x, y) = (i % w, i / w);
            let ra = ss.atan2(sc) / 2.0;
            for dy in -1i32..=1 {
                for dx in -1i32..=1 {
                    if dx == 0 && dy == 0 {
                        continue;
                    }
                    let (nx, ny) = (x as i32 + dx, y as i32 + dy);
                    if nx < 1 || ny < 1 || nx >= w as i32 - 1 || ny >= h as i32 - 1 {
                        continue;
                    }
                    let j = ny as usize * w + nx as usize;
                    if used[j] || mag[j] <= thr {
                        continue;
                    }
                    let mut d = (ang[j] - ra).abs() % std::f32::consts::PI;
                    if d > std::f32::consts::FRAC_PI_2 {
                        d = std::f32::consts::PI - d;
                    }
                    if d > tol {
                        continue;
                    }
                    used[j] = true;
                    region.push(j);
                    stack.push(j);
                    sc += (2.0 * ang[j]).cos();
                    ss += (2.0 * ang[j]).sin();
                }
            }
        }
        if region.len() < 12 {
            continue;
        }
        let (mut sw, mut mx, mut my) = (0.0f64, 0.0f64, 0.0f64);
        for &i in &region {
            let wt = f64::from(mag[i]);
            sw += wt;
            mx += wt * (i % w) as f64;
            my += wt * (i / w) as f64;
        }
        mx /= sw;
        my /= sw;
        let (mut sxx, mut syy, mut sxy) = (0.0, 0.0, 0.0);
        for &i in &region {
            let wt = f64::from(mag[i]);
            let (dx, dy) = ((i % w) as f64 - mx, (i / w) as f64 - my);
            sxx += wt * dx * dx;
            syy += wt * dy * dy;
            sxy += wt * dx * dy;
        }
        let theta = 0.5 * (2.0 * sxy).atan2(sxx - syy);
        let (ux, uy) = (theta.cos(), theta.sin());
        let (mut lo, mut hi, mut wlo, mut whi) = (f64::MAX, f64::MIN, f64::MAX, f64::MIN);
        for &i in &region {
            let (dx, dy) = ((i % w) as f64 - mx, (i / w) as f64 - my);
            let t = dx * ux + dy * uy;
            let s = -dx * uy + dy * ux;
            lo = lo.min(t);
            hi = hi.max(t);
            wlo = wlo.min(s);
            whi = whi.max(s);
        }
        let (len, width) = (hi - lo, (whi - wlo).max(1.0));
        if len < min_len || len / width < 5.0 {
            continue;
        }
        let a = Point { x: (mx + 0.5 + ux * lo - cx) / half_long, y: (my + 0.5 + uy * lo - cy) / half_long };
        let b = Point { x: (mx + 0.5 + ux * hi - cx) / half_long, y: (my + 0.5 + uy * hi - cy) / half_long };
        out.push(Segment { a, b });
    }
    out
}

// MARK: Vanishing points

/// Angle (radians) between a segment and the direction from its middle to the homogeneous point `v`.
fn vp_error(s: &Segment, v: [f64; 3]) -> f64 {
    let m = s.mid();
    let (dx, dy) = (v[0] - m.x * v[2], v[1] - m.y * v[2]);
    let (sx, sy) = (s.b.x - s.a.x, s.b.y - s.a.y);
    let d = dx.hypot(dy);
    if d < 1e-12 {
        return 0.0;
    }
    ((dx * sx + dy * sy) / (d * sx.hypot(sy).max(1e-12))).abs().min(1.0).acos()
}

/// The smallest eigenvector of a symmetric 3×3 matrix (Jacobi rotations).
fn smallest_eigvec(m: [[f64; 3]; 3]) -> [f64; 3] {
    let mut a = m;
    let mut v = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]];
    for _ in 0..50 {
        let (mut p, mut q, mut big) = (0, 1, 0.0);
        for i in 0..3 {
            for j in i + 1..3 {
                if a[i][j].abs() > big {
                    big = a[i][j].abs();
                    p = i;
                    q = j;
                }
            }
        }
        if big < 1e-15 {
            break;
        }
        let theta = (a[q][q] - a[p][p]) / (2.0 * a[p][q]);
        let t = if theta == 0.0 { 1.0 } else { theta.signum() / (theta.abs() + (theta * theta + 1.0).sqrt()) };
        let c = 1.0 / (t * t + 1.0).sqrt();
        let s = t * c;
        for row in a.iter_mut() {
            let (akp, akq) = (row[p], row[q]);
            row[p] = c * akp - s * akq;
            row[q] = s * akp + c * akq;
        }
        for k in 0..3 {
            let (apk, aqk) = (a[p][k], a[q][k]);
            a[p][k] = c * apk - s * aqk;
            a[q][k] = s * apk + c * aqk;
        }
        for row in v.iter_mut() {
            let (vp, vq) = (row[p], row[q]);
            row[p] = c * vp - s * vq;
            row[q] = s * vp + c * vq;
        }
    }
    let i = (0..3).min_by(|&i, &j| a[i][i].total_cmp(&a[j][j])).unwrap_or(0);
    norm([v[0][i], v[1][i], v[2][i]])
}

/// The least-squares vanishing point of `segments`, weighted by their lengths.
fn refine_vp(segments: &[&Segment]) -> [f64; 3] {
    let mut m = [[0.0; 3]; 3];
    for s in segments {
        let l = s.line();
        let w = s.len();
        for i in 0..3 {
            for j in 0..3 {
                m[i][j] += w * l[i] * l[j];
            }
        }
    }
    smallest_eigvec(m)
}

/// The point most of a family of segments point at: RANSAC over pairs of the longest, then least squares.
fn vanishing_point(segments: &[Segment]) -> Option<[f64; 3]> {
    if segments.len() < 2 {
        return None;
    }
    let thr = 1.5f64.to_radians();
    let score = |v: [f64; 3]| -> f64 { segments.iter().map(|s| if vp_error(s, v) < thr { s.len() } else { 0.0 }).sum() };
    let mut idx: Vec<usize> = (0..segments.len()).collect();
    idx.sort_by(|&a, &b| segments[b].len().total_cmp(&segments[a].len()));
    idx.truncate(60);
    let mut best: Option<([f64; 3], f64)> = None;
    for (k, &i) in idx.iter().enumerate() {
        for &j in &idx[k + 1..] {
            let v = cross(segments[i].line(), segments[j].line());
            if dot(v, v) < 1e-24 {
                continue;
            }
            let v = norm(v);
            let sc = score(v);
            if best.is_none_or(|b| sc > b.1) {
                best = Some((v, sc));
            }
        }
    }
    let (v, _) = best?;
    let inliers: Vec<&Segment> = segments.iter().filter(|s| vp_error(s, v) < thr * 2.0).collect();
    if inliers.len() < 2 {
        return None;
    }
    let v = refine_vp(&inliers);
    (segments.iter().filter(|s| vp_error(s, v) < thr * 2.0).count() >= 2).then_some(v)
}

/// The roll named by the vanishing point of the near-upright segments.
fn plumb_roll(vertical: &[Segment]) -> Option<f64> {
    let lines: Vec<Segment> = vertical.iter().copied().filter(|s| s.tilt_from_vertical() < PLUMB_MAX_LEAN).collect();
    let v = vanishing_point(&lines)?;
    let thr = 2f64.to_radians();
    let inliers: Vec<&Segment> = lines.iter().filter(|s| vp_error(s, v) < thr).collect();
    let length: f64 = inliers.iter().map(|s| s.len()).sum();
    let (lo, hi) = inliers.iter().map(|s| s.mid().x).fold((f64::MAX, f64::MIN), |(lo, hi), x| (lo.min(x), hi.max(x)));
    if inliers.len() < PLUMB_MIN_LINES || length < PLUMB_MIN_LENGTH || hi - lo < PLUMB_MIN_SPREAD {
        return None;
    }
    // A vanishing point inside or near the frame is a feature of the scene, not the camera's roll.
    let finite = v[2].abs() > 1e-9;
    if finite && (v[0] / v[2]).hypot(v[1] / v[2]) < 2.0 {
        return None;
    }
    let (vx, vy) = if finite { (v[0] / v[2], v[1] / v[2]) } else { (v[0], v[1]) };
    let roll = fold(vx.atan2(vy).to_degrees());
    (roll.is_finite() && roll.abs() <= MAX_DEGREES).then_some(roll)
}

/// The level the long lines agree on, within `max` degrees and backed by `min_lines` segments: the length-weighted
/// median of the level family (or the upright one, when it has more than twice the length), if most of the length
/// agrees with it within 2°.
fn level_angle_within(vertical: &[Segment], horizontal: &[Segment], max: f64, min_lines: usize) -> Option<f64> {
    let deviation = |s: &Segment, upright: bool| {
        let (dx, dy) = (s.b.x - s.a.x, s.b.y - s.a.y);
        let a = fold(if upright { dx.atan2(dy) } else { dy.atan2(dx) }.to_degrees());
        if upright { -a } else { a }
    };
    let lh: f64 = horizontal.iter().map(Segment::len).sum();
    let lv: f64 = vertical.iter().map(Segment::len).sum();
    let (set, upright) = if lh >= lv * 0.5 && lh > 0.0 { (horizontal, false) } else { (vertical, true) };
    if set.is_empty() {
        return None;
    }
    let mut v: Vec<(f64, f64)> = set.iter().map(|s| (deviation(s, upright), s.len())).collect();
    v.sort_by(|a, b| a.0.total_cmp(&b.0));
    let total: f64 = v.iter().map(|x| x.1).sum();
    let mut acc = 0.0;
    let median = v.iter().find(|(_, l)| {
        acc += l;
        acc >= total / 2.0
    })?;
    let agreeing: Vec<_> = v.iter().filter(|(d, _)| (d - median.0).abs() <= 2.0).collect();
    let agree: f64 = agreeing.iter().map(|x| x.1).sum();
    (agree >= 0.5 * total && agreeing.len() >= min_lines && median.0.abs() <= max).then_some(-median.0)
}

// MARK: Horizon

/// The angle that levels the horizon, if there is one: the straight line across the width along which the rows
/// above are brighter (or darker) than those below in most columns.
fn horizon(gray: &Gray) -> Option<f64> {
    let img = gaussian(gray, HORIZON_SIGMA);
    let (w, h) = (img.width, img.height);
    let k = HORIZON_ROWS;
    if w < 32 || h < 4 * k + 8 {
        return None;
    }
    let cols: Vec<usize> = (0..w).step_by(2).collect();
    let mut diff = vec![0f32; cols.len() * h];
    let mut prefix = vec![0f64; h + 1];
    for (ci, &x) in cols.iter().enumerate() {
        for y in 0..h {
            prefix[y + 1] = prefix[y] + f64::from(img.data[y * w + x]);
        }
        for y in k..h - k {
            let above = (prefix[y] - prefix[y - k]) / k as f64;
            let below = (prefix[y + k] - prefix[y]) / k as f64;
            diff[ci * h + y] = (above - below) as f32;
        }
    }
    let mut strengths: Vec<f32> = diff.iter().map(|d| d.abs()).filter(|d| *d > 0.0).collect();
    if strengths.len() < 100 {
        return None;
    }
    let p99 = strengths.len() * 99 / 100;
    strengths.select_nth_unstable_by(p99, f32::total_cmp);
    let normaliser = f64::from(strengths[p99]).max(1e-4);
    let cx = w as f64 / 2.0;
    let rows = ((h as f64 * HORIZON_MARGIN) as isize).max(k as isize)..((h as f64 * (1.0 - HORIZON_MARGIN)) as isize).min((h - k) as isize);
    let mut column = Vec::with_capacity(cols.len());
    let mut score = |t: f64, b: f64, sign: f32| -> f64 {
        column.clear();
        for (ci, &x) in cols.iter().enumerate() {
            let y = (b + t * (x as f64 - cx)).round() as isize;
            if rows.contains(&y) {
                column.push(sign * diff[ci * h + y as usize]);
            }
        }
        // A line that leaves the frame for more than a fifth of the width is not a horizon.
        if column.len() * 5 < cols.len() * 4 {
            return f64::MIN;
        }
        let i = ((column.len() - 1) as f64 * HORIZON_QUANTILE) as usize;
        column.select_nth_unstable_by(i, f32::total_cmp);
        f64::from(column[i])
    };
    let mut best = (f64::MIN, 0.0f64, 0.0f64, 1.0f32);
    for sign in [1.0f32, -1.0] {
        let mut deg = -HORIZON_SEARCH;
        while deg <= HORIZON_SEARCH {
            let t = deg.to_radians().tan();
            for b in rows.clone().step_by(2) {
                let s = score(t, b as f64, sign);
                if s > best.0 {
                    best = (s, deg, b as f64, sign);
                }
            }
            deg += HORIZON_STEP;
        }
    }
    let (coarse_deg, coarse_b, sign) = (best.1, best.2, best.3);
    let mut deg = coarse_deg - 0.3;
    while deg <= coarse_deg + 0.3 {
        let t = deg.to_radians().tan();
        let mut b = coarse_b - 3.0;
        while b <= coarse_b + 3.0 {
            let s = score(t, b, sign);
            if s > best.0 {
                best = (s, deg, b, sign);
            }
            b += 0.5;
        }
        deg += HORIZON_FINE_STEP;
    }
    let (s, deg) = (best.0 / normaliser, best.1);
    // A line falling `deg` to the right is levelled by turning it −deg.
    (s >= HORIZON_MIN_SCORE && deg.abs() <= MAX_DEGREES).then_some(-deg)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A sky over a sea whose line falls `deg` to the right, with a little texture.
    fn seascape(w: usize, h: usize, deg: f64) -> Gray {
        let t = deg.to_radians().tan();
        let mut data = vec![0f32; w * h];
        let mut seed = 7u32;
        for y in 0..h {
            for x in 0..w {
                seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                let noise = (seed >> 8) as f32 / (1u32 << 24) as f32 * 0.04;
                let line = h as f64 * 0.55 + t * (x as f64 - w as f64 / 2.0);
                data[y * w + x] = if (y as f64) < line { 0.85 } else { 0.35 } + noise;
            }
        }
        Gray { width: w, height: h, data }
    }

    #[test]
    fn a_tilted_horizon_is_levelled() {
        for deg in [-3.0, -1.2, 0.7, 2.5] {
            let (angle, _) = level(&seascape(1024, 683, deg)).expect("a horizon");
            assert!((angle + deg).abs() < 0.15, "tilt {deg}: turned {angle}");
        }
    }

    #[test]
    fn a_level_horizon_is_left_alone() {
        let (angle, _) = level(&seascape(1024, 683, 0.0)).expect("a horizon");
        assert!(angle.abs() < 0.1, "turned {angle}");
    }

    #[test]
    fn nothing_straight_says_nothing() {
        let mut seed = 3u32;
        let data = (0..512 * 341)
            .map(|_| {
                seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                (seed >> 8) as f32 / (1u32 << 24) as f32
            })
            .collect();
        assert_eq!(level(&Gray { width: 512, height: 341, data }), None);
    }

    #[test]
    fn upright_lines_name_the_roll() {
        // Six dark posts, all leaning 2° (clockwise on screen) across a light wall.
        let (w, h) = (1024usize, 683usize);
        let t = 2f64.to_radians().tan();
        let mut data = vec![0.8f32; w * h];
        for post in 0..8 {
            let x0 = 100.0 + post as f64 * 115.0;
            for y in 0..h {
                let x = x0 + t * (h as f64 / 2.0 - y as f64);
                for dx in 0..6 {
                    let px = (x + dx as f64) as usize;
                    if px < w {
                        data[y * w + px] = 0.15;
                    }
                }
            }
        }
        let (angle, _) = level(&Gray { width: w, height: h, data }).expect("posts");
        assert!((angle.abs() - 2.0).abs() < 0.3, "turned {angle}");
    }
}

#[cfg(test)]
mod files {
    /// `QLICK_LEVEL_FILES="a.jpg b.jpg" cargo test -p spektrafilm-io level_files -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn level_files() {
        for path in std::env::var("QLICK_LEVEL_FILES").unwrap_or_default().split_whitespace() {
            let img = image::open(path).unwrap().to_luma8();
            let scale = super::ANALYSIS_LONG as f32 / img.width().max(img.height()) as f32;
            let img = image::imageops::resize(&img, (img.width() as f32 * scale) as u32, (img.height() as f32 * scale) as u32, image::imageops::FilterType::Triangle);
            let gray = super::Gray::from_bytes(img.width() as usize, img.height() as usize, img.as_raw()).unwrap();
            let segments = super::detect_segments(&gray);
            let vertical: Vec<_> = segments.iter().copied().filter(|s| s.tilt_from_vertical() < 30.0).collect();
            let horizontal: Vec<_> = segments.iter().copied().filter(|s| s.tilt_from_vertical() > 60.0).collect();
            println!("{path}: level {:?} plumb {:?} horizon {:?} lines {:?}", super::level(&gray), super::plumb_roll(&vertical), super::horizon(&gray),
                     super::level_angle_within(&vertical, &horizontal, 10.0, 3));
        }
    }
}
