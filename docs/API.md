# Reusable library APIs

## Zig

The build exports two modules:

- `texture_painting`: geometry, sparse images, blend math, authoring sessions,
  CPU map generation, native PNG encoding and project persistence. No Vulkan
  SDK or libc is needed: `zig build test -Dgpu=false` exercises this boundary.
- `hamudi1`: Vulkan rendering and the optional `material_sync` adapter. The
  renderer consumes geometry and material views without owning a painting
  document, history or editor command registry.

Add the package as a Zig path dependency and import the module(s) needed by the
consumer. examples/workflows.zig is a complete consumer: it paints three material
examples, verifies history and project roundtrip, exports PNGs and generates
viewport images. Run `zig-out/bin/hamudi-workflows NEW_OUTPUT_DIRECTORY`.

`Image.clone` shares its tile table and tiles. Deinitialize each owned handle
once. Separate clones may be used on separate workers; synchronize access when
sharing the same mutable handle. The allocator must outlive its objects/clones.

Mesh and material arrays are borrowed during renderer upload. BVH queries borrow
the corresponding mesh arrays, whose topology must agree with the BVH. Updates
to a renderer are serialized by its caller. Rendered pixel views are borrowed
until the next render, resize or deinitialization.

Authoring `Session` commits strokes atomically. Failed strokes can be retried or
cancelled; completed edits have bounded COW undo/redo history. The default history
limit is 64 snapshots and a conservative 256 MiB retained-image budget. Use
session edit methods for changes that need history; direct field mutation is
intended for initial construction by an owning adapter.

`material_sync.apply(renderer, session, material)` translates dirty tiles and
channel values into packed GPU region updates. It is an adapter between the two
libraries. Renderer APIs do not require it. The first update of a previously
constant channel creates a sparse GPU page table. Only touched 64×64 tiles are
allocated. Resident storage grows geometrically and subsequent edits reuse it.
GPU tests compare sparse and dense rendering exactly and exercise a four-tile
edit of an 8K material using less than 256 KiB of uploads and 1 MiB of backing.

`Session.begin` starts a revision-bound gesture. `previewDocument` composites its
temporary coverage without changing committed document/history. `cancel` dirties
the affected area so the adapter restores committed pixels. `commit` creates one
undo entry for the entire gesture. C tokens reject stale/foreign gestures and
the Python adapter rejects stale document revisions. A gesture in the prepared
adapter is confined to its first material; a host needing multi-material strokes
must group its surface transactions at the document boundary.

`Renderer.setMesh` borrows arrays during the call, caches serialization/tangent
workspace and reuses same-sized device buffers. `Bvh.refit` supports unchanged
topology. `hamudi_scene_deform` owns the updated positions/normals and preserves
UV/material identities. Call `hamudi_set_scene` to upload that pose to a renderer.
Failed input validation leaves the preceding pose unchanged.

HDR presets, linear floating-point environment images and rotation are supported.
The raster profile uses SH9 diffuse and GGX-prefiltered specular IBL. The traced
profile uses the original importance-sampled environment and emissive transport.
Specular/glossiness is a renderer-wide workflow, matching upstream; re-sync
surfaces after changing it. Packed roughness then equals one minus glossiness.

## C and Python

The build installs `libhamudi.a`, `libhamudi.so` and include/hamudi.h. The header
defines ABI 1 and ownership rules. C handles are generation checked. Arrays are
borrowed for a call, and output memory belongs to the caller. No library-owned
pixel buffer must be freed by the caller. Errors are negative return values with
a thread-local message from `hamudi_last_error`. Calls are serialized internally.

`zig build integration` compiles and runs examples/c_consumer.c independently of
the Zig implementation, exercising painting, history and stale-handle rejection.
`zig build gpu-test` additionally requires a Vulkan device and checks resident
resources, deformation, sparse/dense pixels, invalid input, accumulation and
empty scenes. It is intentionally an explicit hardware test.

adapters/python/hamudi.py provides ctypes bindings. `PreparedViewport` consumes a
prepared Scoundrill experiment scene with RGBA16 textures, maintains a persistent
native renderer, performs 3D picking/painting and syncs dirty regions. It closes
all native handles explicitly. The native authoring APIs also export PNG and
project bytes through caller-sized output buffers.

All seven procedural brush alphas are checked against 12,138 observations from
unchanged original Rust sample functions. Noise reproduces the original bit
checksum over 58,366 values. `ImageAlpha` and C image stamps borrow grayscale
coverage during a call and preserve its aspect ratio. `hamudi_bake` and
`hamudi_bake_transfer` expose map generation to C hosts;
`hamudi_surface_import_channel` adds a map as one undoable layer. `HamudiCancel`
is caller-owned; `hamudi_cancel_set` may run while a bake holds the handle lock.

Use `Renderer.progressive` or `hamudi_trace_step`/`hamudi_resolve` for cancellable
progressive rendering. Each step submits at most eight samples, and the host can
cancel before another submission. A submitted Vulkan batch is not preempted.
`hamudi_renderer_create_device(2, ...)` requires a CPU Vulkan driver. This runs
the same shaders; it is not a second independent CPU transport implementation.

## Current bounds and scope

The tested renderer backends are Linux/Vulkan on the RTX 4070 and a tiny llvmpipe
CPU smoke render. Shader compilation
uses a locked, development-only Naga tool; committed SPIR-V lets normal builds
run without Rust. Software/platform backends require their own acceptance.

Accumulation/denoising use unmapped device-local buffers and GPU clears.
Readback uses host-cached coherent memory. Small resident geometry/material
buffers may use mapped device-local memory, capped at 64 MiB per context with
host fallback for small BAR apertures. `-Dhost-buffers=true` is a reproducible
measurement control; the full runner compares its native-4K pixels exactly
against device-local output.

The raster path uses recovered material/BSDF conventions and hardware primary
visibility with BVH directional shadows. It is a declared interactive profile,
not pixel-identical to TextureCraft's shadow-map/IBL/postprocessing pipeline.
The tracer retains the recovered transport and denoising algorithms with an
adapted buffer resource layout. Actor/room parity remains an explicit check.

Native PNG export supports RGBA8/RGBA16 with a channel color policy:
albedo/emission/specular/sheen color export as sRGB;
roughness, normals, height and other data maps stay linear by default. Explicit
color overrides remain available. Project persistence uses a versioned
native JSON schema with a 128 MiB serialized budget. Save preflights that budget
before allocating JSON output, and rejects nonfinite/invalid documents; it does
not emit a project that its own loader will reject for size. This is not .tcraft
compatibility. Map generation includes
CPU AO, world/tangent normals, position, IDs, height, curvature and thickness,
plus high-poly normal/height transfer. Map algorithm parity with every upstream
baker, full layer/effect inventory, instancing, hair and motion blur remain open.
Sparse 2D authoring supports 8K dimensions; the current full UV G-buffer limits
3D painting/baking to 16,777,216 texels. Dense GPU data is bounded by the device's
storage-buffer range and a 512 MiB library limit. Sparse 8K edits are supported;
fully populated 8K multichannel materials can exceed that limit.
