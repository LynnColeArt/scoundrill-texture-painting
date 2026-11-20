# Delivery status

## Implemented release

- [x] Permanent repository, scope, source/dependency inventory and licenses.
- [x] Preserved Movie Maker actor/room inputs, observations and hashes.
- [x] Independent Zig authoring and renderer modules, C ABI and Python adapter.
- [x] Geometry, picking/refit, UV/tangent mapping, sparse COW images and history.
- [x] Seven procedural brushes/image alphas, masks/fills and 32 blend modes.
- [x] Revisioned live preview, exact cancel, grouped undo/redo and map import.
- [x] Raster PBR, recovered tracing/denoising, HDR lighting and CPU Vulkan execution.
- [x] Map generation/transfer, PNG color/data export and checked compact projects.
- [x] Native skin/makeup, building/object texture and detailing workflows.
- [x] Optimized resident resources, sparse GPU pages, SAH, composition, workers and seam caches.
- [x] Real-actor deformation, dense 4K project roundtrip and native-4K render evidence.
- [x] Pinned Scoundrill modern factory default with the traced reference profile.
- [x] Modern adapter checks and all five existing supported Scoundrill milestones.

[Delivery and measurements](DELIVERY.md) identify the checked commits and results.
[Capabilities](CAPABILITIES.md) is the feature-level contract.

## Explicit extensions and remaining targets

- [ ] Strict original/candidate per-pixel parity, including canonical tangent conventions.
- [ ] Stable p95 paint latency below 33.3 ms across full measured conditions.
- [ ] All upstream paint/pickup/text/particle/preset/effect/generator tools.
- [ ] Full upstream bake/cage/skew semantics and broad format/.tcraft/UDIM compatibility.
- [ ] Additional platforms, temporal AA, instancing, hair and motion blur.
- [ ] Application-wide studio UI/document adoption by the owning application team.

The raster approximation retains unoccluded environment lighting and opaque
shadow casters; emissive neighbor illumination belongs to the traced profile.
Native compact/PNG persistence and CPU Vulkan are deliberate implementation
choices. A 20× cross-renderer speedup has not been established.
