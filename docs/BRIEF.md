# Extraction brief

Owner direction, November 20, 2026.

## Deliverables

1. **hamudi-1:** a reusable Zig rendering library, destined to be Scoundrill's
   default viewport renderer. Recover raster PBR, scene/material updates,
   lighting and shadows, CPU/GPU tracing, accumulation, denoising and display
   conversion from the selected TextureCraft system.
2. **Texture painting:** reusable Zig libraries for paintable surfaces, brushes,
   texture/map creation, layer compositing, baking and export.
3. A narrow Scoundrill adapter that connects those libraries to the editor.
   Recreating TextureCraft's application shell is outside the initial scope.

Production host logic is Zig. Vulkan runs the recovered WGSL compiled to
committed SPIR-V; normal builds and applications require no Rust runtime or
compiler. The same kernels can run on a CPU Vulkan driver. This replaces a
separate hand-port of the original CPU tracer, a deliberate implementation change.

## User workflows

| Application | Acceptance workflow to build |
| --- | --- |
| Skin and makeup | Paint color and surface properties on an actor across UV seams; use masks and layers to isolate changes; undo/redo and save/export them. Verify eyes, cutouts, normals and small facial details. |
| Buildings and objects | Create and apply materials and maps to props and architecture; verify repeat scale, seams, per-material assignment and consistency under room lighting. |
| Detailing | Place controlled stamps, decals, wear, dirt and fine marks; mask and adjust them without destroying underlying work; preserve detail in export. |

These workflows define product goals. Individual brushes, map types and
persistence formats require an explicit feature inventory before support claims.
Skin authoring does not by itself promise a subsurface skin shading model.

## Integration contract

A paint operation identifies changed surface regions and channels. Compositing
produces updated material data. hamudi-1 displays that update while preserving
unaffected scene resources. A camera or light update must not require repainting
or rebuilding an unchanged document.

Libraries expose caller-owned allocation and lifetime rules and can run without
an editor window. Input samples are application-independent; adapters supply
pointer pressure and other available device information.

The first end-to-end milestone is: load an actor or prop, paint a stroke, see
the material update in hamudi-1, undo/redo it, and export the changed texture.

## Default-renderer cutover

hamudi-1 becoming the default is an explicit objective. Cutover requires working
Zig rendering and painting, the existing actor/room regressions, Scoundrill
acceptance, and measured interactive performance. The modern factory now selects the pinned Hamudi-1 reference profile. Fixed
BRender remains the compatibility engine; application UI adoption uses the
modern factory rather than changing compatibility entry points.
