# Library boundaries

This is an extraction proposal informed by pinned upstream manifests and
architecture documentation, not an implemented API.

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

## Proposed dependency direction

Geometry and image/value types sit below the renderer and authoring services.
Painting uses geometry and surface storage; composition produces material
images; hamudi-1 consumes scene and material views plus bounded updates.

The renderer must not depend on painting history, an editor command registry or
TextureCraft project documents. Split CPU bake contracts from the GPU bake
implementation to avoid a renderer/baker cycle.

Expected public entry points are a renderer, texture-painting services, geometry
and image/surface services. Exact Zig module names and package granularity follow
the first working consumer, rather than creating empty packages now.

## Decisions requiring implementation evidence

- Zig GPU backend, platform matrix and shader ownership.
- Mesh/texture update descriptors, resource handles and generation tracking.
- Sparse tile representation, undo ownership and worker scheduling.
- Deforming geometry and BVH updates for Scoundrill actors.
- Persistence/export formats and UV/UDIM feature coverage.
- Explicit local lights, indoor indirect-light strategy and transparent shadows.

A Scoundrill adapter translates its scene packet, animation state and editor
events. The libraries must also support a standalone headless consumer for
parity and performance checks.
