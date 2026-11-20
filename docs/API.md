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
constant channel may allocate its dense GPU backing; subsequent region updates
reuse that backing.

## C and Python

The build installs `libhamudi.a`, `libhamudi.so` and include/hamudi.h. The header
defines ABI 1 and ownership rules. C handles are generation checked. Arrays are
borrowed for a call, and output memory belongs to the caller. No library-owned
pixel buffer must be freed by the caller. Errors are negative return values with
a thread-local message from `hamudi_last_error`. Calls are serialized internally.

`zig build integration` compiles and runs examples/c_consumer.c independently of
the Zig implementation, exercising painting, history and stale-handle rejection.

adapters/python/hamudi.py provides ctypes bindings. `PreparedViewport` consumes a
prepared Scoundrill experiment scene with RGBA16 textures, maintains a persistent
native renderer, performs 3D picking/painting and syncs dirty regions. It closes
all native handles explicitly. The native authoring APIs also export PNG and
project bytes through caller-sized output buffers.

## Current bounds and scope

The tested renderer backend is Linux/Vulkan on the RTX 4070. Shader compilation
uses a locked, development-only Naga tool; committed SPIR-V lets normal builds
run without Rust. Software/platform backends require their own acceptance.

The raster path uses recovered material/BSDF conventions and hardware primary
visibility with BVH directional shadows. It is a declared interactive profile,
not pixel-identical to TextureCraft's shadow-map/IBL/postprocessing pipeline.
The tracer retains the recovered transport and denoising algorithms with an
adapted buffer resource layout. Actor/room parity remains an explicit check.

Native PNG export supports RGBA8/RGBA16. Project persistence uses a versioned
native JSON schema; this is not .tcraft compatibility. Map generation includes
CPU AO, world/tangent normals, position, IDs, height, curvature and thickness,
plus high-poly normal/height transfer. Map algorithm parity with every upstream
baker, full layer/effect inventory, instancing, hair and motion blur remain open.
