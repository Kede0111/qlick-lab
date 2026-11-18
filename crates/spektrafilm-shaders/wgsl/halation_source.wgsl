// Qlick Lab: the halation's source, the highlights' light alone (CPU
// `HalationSource::energy`). The energy is the brighter of red and green
// (blue never reaches the film base), faded in by a smoothstep over
// `threshold ± softness` stops above mid-grey (1.0 in film raw), and given
// back `gain` stops as it rises: `e · w · 2^(gain · w)`. Written to all three
// channels, so each channel's bounces can blur it at their own width.

struct Params {
    n_pixels: u32,
    _pad0: u32,
    _pad1: u32,
    _pad2: u32,
    shape: vec4<f32>, // .x threshold (EV), .y softness (EV), .z gain (EV)
}

@group(0) @binding(0) var<uniform> params: Params;
@group(0) @binding(1) var<storage, read> src: array<f32>;
@group(0) @binding(2) var<storage, read_write> dst: array<f32>;

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
    let base = idx * 3u;
    let e = max(src[base], src[base + 1u]);
    var energy = 0.0;
    if e > 0.0 {
        let s = max(params.shape.y, 1e-3);
        let t = clamp((log2(e) - (params.shape.x - s)) / (2.0 * s), 0.0, 1.0);
        let w = t * t * (3.0 - 2.0 * t);
        energy = e * w * exp2(params.shape.z * w);
    }
    dst[base] = energy;
    dst[base + 1u] = energy;
    dst[base + 2u] = energy;
}
