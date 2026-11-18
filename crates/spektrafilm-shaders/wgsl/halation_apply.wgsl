// Qlick Lab: the halation fed by the highlights (CPU `apply_halation_um`
// with a source). `acc` holds the bounces of the source `energy`; only what
// they carry beyond the highlight they left is added:
// `added[c] = a[c] · max(acc[c] − energy, 0)`.
//
// With `mask` (Show mask), the image becomes how far that light brightens
// each pixel, in stops over the pixel's brighter of red and green, the
// strongest channel capped at one stop and the others kept in ratio, shown
// a stop over grey per stop (CPU `halation_mask_pixel`).

struct Params {
    n_pixels: u32,
    mask: u32,
    _pad1: u32,
    _pad2: u32,
    a: vec4<f32>, // .xyz per-channel strength × amount
}

@group(0) @binding(0) var<uniform> params: Params;
@group(0) @binding(1) var<storage, read> energy: array<f32>;
@group(0) @binding(2) var<storage, read> acc: array<f32>;
@group(0) @binding(3) var<storage, read_write> img: array<f32>;

// Threads per workgroup; the host may lower it to what the GPU's
// compiled pipeline supports (see `WgpuBackend::workgroup_size`).
override WORKGROUP_SIZE: u32 = 1024u;

fn added(a: f32, bounced: f32, e: f32) -> f32 {
    // A channel at strength 0 adds nothing, whatever the scratch holds.
    return select(a * max(bounced - e, 0.0), 0.0, a == 0.0);
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
    let e = energy[base];
    let add = vec3<f32>(
        added(params.a.x, acc[base], e),
        added(params.a.y, acc[base + 1u], e),
        added(params.a.z, acc[base + 2u], e),
    );
    if params.mask != 0u {
        let floor = 1.0 / 64.0;
        let own = max(max(img[base], img[base + 1u]), floor);
        let stops = log2(vec3<f32>(1.0) + max(add, vec3<f32>(0.0)) / own);
        let over = max(1.0, max(stops.x, max(stops.y, stops.z)));
        let shown = 2.0 * stops / over;
        img[base] = shown.x;
        img[base + 1u] = shown.y;
        img[base + 2u] = shown.z;
        return;
    }
    img[base] = img[base] + add.x;
    img[base + 1u] = img[base + 1u] + add.y;
    img[base + 2u] = img[base + 2u] + add.z;
}
