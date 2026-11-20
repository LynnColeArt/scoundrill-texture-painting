# Library boundaries

Two implemented Zig modules expose the recovered systems. `texture_painting`
owns geometry, sparse images, documents, brushes, history, map generation and
native IO. It runs without Vulkan or libc. `hamudi1` owns persistent Vulkan
rendering, HDR environments and an optional dirty-material adapter. C and Python
consumers exercise both modules independently of any application shell.

## Upstream inventory

Reference: storytold/texturecraft at
52ba5338dc07640704d58122e559355a41147b6a (workspace 0.6.1).

| Upstream crate | Observed responsibility | Proposed destination |
| --- | --- | --- |
| core | Document model, channels, layers, masks, blend math | Material/painting model, with shared value types separated |
| texel | Sparse copy-on-write tiles, UV padding, deterministic noise, color transfer | Surface storage and image operations |
| geom | Meshes, tangents, BVH, picking, UV G-buffer, camera | Shared geometry and surface queries |
| compose | Layer evaluation, patterns, padding, display conversion | Texture compositor |
| paint | Stroke sampling, stamps, visibility, rasterization, commit | Brush and painting library |
| bake | Mesh-map generation and high-poly transfer | Map baking library |
| render | Raster PBR, headless output, CPU/GPU tracing and GPU bake support | hamudi-1 |
| formats | Mesh/texture/project IO | Optional IO adapters; feature inventory pending |
| engine | Session, caches, history, tools, commands | Extract necessary history/session services; application commands stay in adapters |
| automation, ui-egui, apps | Control transport and application shell | Outside library core |

The pinned render manifest depends directly on core, texel, geom, compose and
bake. Paint depends directly on core, texel, geom and compose. Extracting just
the render directory would therefore leave substantial upstream coupling.

The upstream architecture describes one UV-space G-buffer shared by painting,
compositing, baking and padding. Preserve that agreement when separating
libraries. It also describes sparse 64x64 u16 copy-on-write tiles and updates
limited to dirty tiles. These are existing design properties, not new speedups.

## Dependency direction

Geometry and image/value types sit below the renderer and authoring services.
Painting uses geometry and surface storage; composition produces material
images; hamudi-1 consumes scene and material views plus bounded updates.

The renderer must not depend on painting history, an editor command registry or
TextureCraft project documents. Split CPU bake contracts from the GPU bake
implementation to avoid a renderer/baker cycle.

Public entry points and ownership rules are in [API.md](API.md).
`examples/workflows.zig` is a standalone consumer of both modules. The C ABI
exports generation-checked scene, renderer and surface handles. Fixed-topology
deformation refits the BVH and reuses warmed CPU workspace and GPU buffers.
Constant material channels grow sparse 64×64 GPU pages when edited; camera and
light changes upload no geometry or material data.

## Remaining extensions

- Platform matrix beyond the tested Linux NVIDIA and CPU Vulkan drivers.
- Topology changes for animated meshes require explicit new scene upload.
- Worker scheduling and concurrent per-document authoring remain host concerns.
- Persistence/export formats and UV/UDIM feature coverage.
- Arbitrary analytic local lights and transparent raster shadows. Emissive mesh
  panels and enclosed indirect light are supported by the recovered tracer.

A Scoundrill adapter translates its scene packet, animation state and editor
events. The libraries must also support a standalone headless consumer for
parity and performance checks.
