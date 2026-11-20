# Roadmap

## Recorded foundation

- [x] Create the permanent repository and capture owner scope.
- [x] Identify the tested upstream revision and direct library dependencies.
- [x] Index the existing actor and room evidence without recapturing it.
- [x] Define reuse boundaries, application workflows and performance work.
- [x] Map Movie Maker's existing renderer behavior records and executable checks.

## Recovery and implementation

- [ ] Inventory public operations, source files, shaders, assets and dependencies.
- [ ] Preserve required licenses/notices and source hashes before adapting code.
- [ ] Select and prove the Zig GPU backend with an actual render.
- [ ] Extend the original reference to deterministic paint/composite/bake cases.
- [ ] Establish isolated viewport and painting performance baselines.
- [ ] Implement shared geometry, surface storage and material contracts.
- [ ] Implement hamudi-1 raster rendering and scene/material update handling.
- [ ] Implement brushes, visibility, seams, dirty compositing and history.
- [ ] Complete the first actor/prop paint-render-undo-export workflow.
- [ ] Recover the remaining selected tracing, denoising, map baking and IO features.
- [ ] Validate skin/makeup, building/object and detailing workflows.
- [ ] Profile and optimize CPU/GPU work while retaining acceptance.
- [ ] Integrate deforming actors and editor events in Scoundrill.
- [ ] Pass Scoundrill regressions and switch the default viewport to hamudi-1.

Known upstream behavior requiring explicit decisions and separate regressions:
raster environment light ignores room enclosure; emission does not illuminate
neighboring raster surfaces; shadow casters are treated as opaque; room contact
seams and small-feature ray-offset artifacts need attention. These limits do not
invalidate the feasibility experiment, but cannot be called solved by a port.

No implementation milestones, performance improvements or default-renderer
cutover have been completed yet.
