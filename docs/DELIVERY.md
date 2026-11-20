# Library release 0.1

The reusable Zig renderer and texture-authoring components are implemented.
Scoundrill's `modern.create_viewport` selects a pinned Hamudi-1 build, with the
recovered traced profile as default. Hardware raster is an explicit fast profile.
The libraries also run through independent Zig and C consumers. The studio UI
remains with its existing owner; compatibility BRender entry points are unchanged.

The shipped operations and upstream extensions are listed in
[CAPABILITIES.md](CAPABILITIES.md). This is not a claim that every TextureCraft
application tool, preset and file format has been reproduced.

## Checks and evidence

- Checked Debug/ReleaseSafe core tests, exhaustive allocation-failure paths,
  independent C consumer, renderer numerical tests and real Vulkan tests pass.
- 2,592 original blend observations, 12,138 original brush observations and
  the original 58,366-value noise checksum pass.
- Actor paint/preview/cancel/commit/undo/redo, stale revisions, map import/export,
  generated garment UVs and fixed-topology source-vertex deformation pass.
- Window open/closed, emissive on/off and lamp-position controls pass. Moving a
  raster light away and back restores exact pixels. Original evidence hashes
  remain unchanged.
- Native-4K traced output and same-source memory-placement comparison pass.
  Those two memory profiles produce byte-for-byte identical displayed pixels.
- Dense 4096×4096 albedo/opacity projects roundtrip every pixel through the
  compact format. CRC/truncation, JSON compatibility and material-default
  restoration have separate tests.
- Scoundrill's pinned consumer passes; its full existing acceptance reports all
  five supported milestones passing, including original/candidate/pixel and
  audio coverage. Existing external-coverage limits remain intact.

[Full renderer/workflow run](../reference/acceptance-20261120/report.json),
[large-project/interoperability checks](../reference/acceptance-20261120/projects.json)
and [deformation timings](../reference/acceptance-20261120/deformation.json)
retain the measurements. The renderer run identifies `f562083`; subsequent IO
and adapter commits have dedicated checks. No rendering algorithm changed in
those follow-ups. The Scoundrill adapter has its own pinned build/check record.

## Measurements

RTX 4070, driver 580.196.07, Zig 0.16.0 ReleaseSafe, shared development machine.
These are finite workload observations, not a general cross-renderer speedup.

| Workload | Result |
| --- | --- |
| 720p fast raster navigation, 60 warm frames, no per-frame readback | 0.70 ms mean; 0.88 ms p95 |
| 1080p same profile | 1.41 ms mean; 1.66 ms p95 |
| Native 4K same profile | 5.24 ms mean; 5.63 ms p95 |
| Real actor, 73,295 source vertices: pose copy/refit/tangents/upload + 640×360 raster/readback | 7.85 ms mean; 9.63 ms p95, 20 frames |
| Warm emissive room, native 4K, 512 spp, 7 bounces, denoised | 33.14 s in the documented CLI timer scope; 269 MiB process peak RSS |
| Same source/scene/quality with host-only storage | 34.04 s; 1,044 MiB RSS; exact same pixels |
| Dense 4K compact albedo/opacity project | 192 MiB file; approximately 1.6 s import/save and 0.6 s load in the recorded check |

Warm paint latency varies with shared CPU load. The complete run measured p95
29.25 ms brush-down and 35.82 ms dragging with fast preview; one-sample traced
brush-down was 45.95 ms p95. Focused runs were faster, but the provisional
33.3 ms paint target is not established across these conditions. No 20× speedup
is claimed. Raster and traced quality/performance are reported separately.

Against unchanged original 720p images, candidate mean displayed RGB-byte error
ranges from 0 to 0.069; maximum differences reach 34. The original CPU/GPU
max-error-3 result is not attributed to this candidate. Lighting controls and
near-identical average appearance do not establish strict per-pixel parity.

## Deliberate decisions

Production host code is Zig; recovered kernels remain WGSL/SPIR-V. Rust is used
only for development oracles and shader compilation. CPU rendering uses a CPU
Vulkan driver running the same transport, instead of a second hand-port of the
original CPU tracer. Linux/Vulkan is the validated platform.

Native compact projects and PNG supply persistence; .tcraft and broad imported
formats remain extensions. Missing UVs receive deterministic padded triangle
charts, while authored UVs remain intact. Constant materials get an editable
backing so a small wall/prop stamp stays local. Both choices are confined to the
interactive adapter; original parity packets are unchanged.

The implementation keeps COW history, sparse GPU tiles, resident scene resources,
cached tangent/serialization workspace, SAH traversal, tile composition, parallel
disjoint-texel visibility work and cached seam neighborhoods. Hosts own stable
asset identities, application commands, shared revisions and UI integration.
