// Per-pixel lognormal noise generation for the viewing glare model.
//
// CPU equivalent: `compute_random_glare_amount` — samples LogNormal(μ, σ)
// from a single RNG, then optionally blurs the field. The GPU version
// uses per-pixel PCG-hashed Box-Muller so the noise is independent of
// thread/workgroup ordering.
//
// Writes the same value into all 3 channels (broadcast) so the existing
// 3-channel separable Gaussian blur can post-process the field directly.

struct Params {
    n_pixels: u32,
    base_seed: u32,
    mu: f32,
    sigma: f32,
    place: vec4<u32>,
}

@group(0) @binding(0) var<uniform> params: Params;
@group(0) @binding(1) var<storage, read_write> glare_buf: array<f32>;

// Qlick Lab: the pixel's name for its draws: its index in the frame the image is a
// part of (`place` = image width, frame width, the image's first pixel in the
// frame), so a part of a photograph draws what the whole photograph draws there.
fn draw_index(idx: u32) -> u32 {
    let x = idx % params.place.x;
    let y = idx / params.place.x;
    return (y + params.place.w) * params.place.y + x + params.place.z;
}

fn pcg(state: u32) -> u32 {
    var s: u32 = state * 747796405u + 2891336453u;
    let word: u32 = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return (word >> 22u) ^ word;
}

fn unit_f32(x: u32) -> f32 {
    return f32(x) * (1.0 / 4294967296.0);
}

fn splitmix32(x: u32) -> u32 {
    var z: u32 = x;
    z = (z ^ (z >> 16u)) * 0x85ebca6bu;
    z = (z ^ (z >> 13u)) * 0xc2b2ae35u;
    return z ^ (z >> 16u);
}

// Threads per workgroup; the host may lower it to what the GPU's
// compiled pipeline supports (see `WgpuBackend::workgroup_size`).
override WORKGROUP_SIZE: u32 = 1024u;

@compute @workgroup_size(WORKGROUP_SIZE)
fn main(
    @builtin(global_invocation_id) gid: vec3<u32>,
    @builtin(num_workgroups) groups: vec3<u32>,
) {
    // 2D grid above 65535 workgroups (see `linear_dispatch_grid`).
    let idx = gid.y * groups.x * WORKGROUP_SIZE + gid.x;
    if idx >= params.n_pixels { return; }
    var rng = splitmix32(params.base_seed) ^ splitmix32(draw_index(idx));
    rng = pcg(rng);
    let u1 = unit_f32(rng);
    rng = pcg(rng);
    let u2 = unit_f32(rng);
    let z = sqrt(-2.0 * log(max(u1, 1e-7))) * cos(6.28318530717958647 * u2);
    let value = exp(params.mu + params.sigma * z);
    let base = idx * 3u;
    glare_buf[base] = value;
    glare_buf[base + 1u] = value;
    glare_buf[base + 2u] = value;
}
