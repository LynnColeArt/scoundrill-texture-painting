# Roadmap

## Recorded foundation

- [x] Create the permanent repository and capture owner scope.
- [x] Identify the tested upstream revision and direct library dependencies.
- [x] Index the existing actor and room evidence without recapturing it.
- [x] Define reuse boundaries, application workflows and performance work.
- [x] Map Movie Maker's existing renderer behavior records and executable checks.

## Recovery and implementation

- [ ] Inventory public operations, source files, shaders, assets and dependencies.
- [x] Preserve required licenses/notices and source hashes before adapting code.
- [x] Select and prove the Zig GPU backend with an actual render.
- [ ] Extend the original reference to deterministic paint/composite/bake cases.
- [ ] Establish isolated viewport and painting performance baselines.
- [x] Implement shared geometry, surface storage and material contracts.
- [x] Implement hamudi-1 raster rendering and scene/material update handling.
- [x] Implement brushes, visibility, seams, dirty compositing and history.
- [x] Complete the first actor/prop paint-render-undo-export workflow.
- [ ] Recover the remaining selected tracing, denoising, map baking and IO features.
- [x] Validate initial skin/makeup, building/object and detailing workflows.
- [ ] Profile and optimize CPU/GPU work while retaining acceptance.
- [ ] Integrate deforming actors and editor events in Scoundrill.
- [ ] Pass Scoundrill regressions and switch the default viewport to hamudi-1.

Known upstream behavior requiring explicit decisions and separate regressions:
raster environment light ignores room enclosure; emission does not illuminate
neighboring raster surfaces; shadow casters are treated as opaque; room contact
seams and small-feature ray-offset artifacts need attention. These limits do not
invalidate the feasibility experiment, but cannot be called solved by a port.

Implemented so far: bounded mesh validation, BVH picking/refit/query, UV surface
mapping, camera math, sparse two-level COW images, padding, 32 blend modes,
layer composition, UV/world stamps and atomic stroke history. The Vulkan tracer
and denoiser render the existing actor. Core tests include 2592 original blend
observations and exhaustive allocation-failure paths for COW edits and strokes.
Performance improvements and default-renderer cutover are not claimed yet.
