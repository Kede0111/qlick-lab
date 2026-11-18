// Per-channel variant of add_scaled: `dst[i,c] += scale[c] * src[i,c]`.
//
// Used by halation's final additive step where the halation strength
// `a_tot[c] = halation_strength[c] * halation_amount` differs per
// channel (e.g. Portra is `(0.05, 0.015, 0.0)` — blue gets no halation
// at all). Averaging the scalar value produces a uniform cool halo
// around bright edges; the per-channel variant preserves the film's
// chromatic halation signature.
//
// Qlick Lab: with `replace` (Show mask), `dst[i,c] = scale[c] * src[i,c]`:
// the halation alone, on black. A channel at scale 0 is 0, whatever `src`
// holds.

struct Params {
    n_pixels: u32,
    replace: u32,
    _pad1: u32,
    _pad2: u32,
    scale: vec4<f32>, // .xyz used (per channel), .w padding
}

@group(0) @binding(0) var<uniform> params: Params;
@group(0) @binding(1) var<storage, read> src: array<f32>;
@group(0) @binding(2) var<storage, read_write> dst: array<f32>;

// Threads per workgroup; the host may lower it to what the GPU's
// compiled pipeline supports (see `WgpuBackend::workgroup_size`).
override WORKGROUP_SIZE: u32 = 1024u;

fn scaled(s: f32, v: f32) -> f32 {
    return select(s * v, 0.0, s == 0.0);
}

@compute @workgroup_size(WORKGROUP_SIZE)
fn main(
    @builtin(global_invocation_id) gid: vec3<u32>,
    @builtin(num_workgroups) groups: vec3<u32>,
) {
    // 2D grid above 65535 workgroups (see `linear_dispatch_grid`).
    let idx = gid.y * groups.x * WORKGROUP_SIZE + gid.x;
    if idx >= params.n_pixels { return; }
    let base = idx * 3u;
    let s = params.scale.xyz;
    if params.replace != 0u {
        dst[base]      = scaled(s.x, src[base]);
        dst[base + 1u] = scaled(s.y, src[base + 1u]);
        dst[base + 2u] = scaled(s.z, src[base + 2u]);
        return;
    }
    dst[base]      = dst[base]      + s.x * src[base];
    dst[base + 1u] = dst[base + 1u] + s.y * src[base + 1u];
    dst[base + 2u] = dst[base + 2u] + s.z * src[base + 2u];
}
