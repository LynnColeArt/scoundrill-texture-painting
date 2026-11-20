# Scoundrill texture painting

Reusable Zig libraries for rendering and authoring textures on 3D surfaces.
**hamudi-1 is intended to become Scoundrill's default viewport rendering engine.**
The painting libraries serve skin and makeup, building and object textures, and
detailing workflows.

The unchanged Rust TextureCraft build established feasibility. It remains a
pinned behavior reference for a complete Zig recreation of the selected systems,
rather than a runtime dependency of the finished libraries.

Status: Zig geometry, sparse COW image storage, all 32 blend modes, atomic
paint strokes and undo/redo are implemented. A Zig-owned Vulkan tracer renders
the existing Movie Maker actor using the recovered tracing/denoising shaders.
Scoundrill has not switched renderers; raster rendering, broader authoring,
baking, IO, performance work and integration remain in progress.

Build with Zig 0.16.0 and the system Vulkan development loader:

```sh
zig build -Doptimize=ReleaseSafe
zig build test
./zig-out/bin/hamudi SCENE.json OUT.ppm 256 144 128 gpu
```

The CLI consumes the existing prepared TextureCraft experiment scene and RGBA16
material files. Output is native-resolution PPM with a JSON execution report.
Source shader regeneration uses Python and the locked development-only Naga tool:

```sh
python3 tools/prepare_shaders.py
cargo run --release --locked --manifest-path tools/shader-compiler/Cargo.toml -- "$PWD"
```

- [Product and acceptance brief](docs/BRIEF.md)
- [Library boundaries and upstream inventory](docs/ARCHITECTURE.md)
- [Movie Maker renderer behavior and acceptance map](docs/RENDERER-BEHAVIOR.md)
- [Performance plan](docs/PERFORMANCE.md)
- [Implementation sequence](docs/ROADMAP.md)
- [Reference provenance](docs/PROVENANCE.md)

This is the permanent project checkout. Temporary references and worktrees belong
under /tmp or ~/work-trees and must be removed when their work is finished.
