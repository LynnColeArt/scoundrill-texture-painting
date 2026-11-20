# Implemented capability inventory

Version 0.1 implements a reusable rendering/painting foundation. This inventory
distinguishes working operations from TextureCraft's larger application and
asset/preset catalog. The source inventory pins 239 source files; an inventoried
source does not imply every operation in it has been ported.

| Area | Implemented and exercised | Limits / extensions |
| --- | --- | --- |
| Geometry | Bounded meshes; SAH BVH build/query/pick/refit; UV G-buffer; UV-derived tangent frames; padded charts for UV-less materials | Tangents are not canonical MikkTSpace; no instancing or topology-aware animation API |
| Storage | Sparse 64×64 u16 images; two-level atomic COW; constant-time clones; seam padding; allocation-failure coverage | Synchronize a mutable image/session; separate clones may belong to different workers |
| Authoring | 21 channels; paint/fill layers; masks; 32 blend modes; four procedural fills; bounded history; revisioned live gestures | Native document schema, not all upstream group/effect/generator tools |
| Brushes | Seven recovered procedural alphas; custom grayscale image alphas; UV paths; pressure/spacing; world visibility; mirrored X strokes | Text/particle tools, clone/smudge pickup, complete alpha/preset library and general radial symmetry remain extensions |
| Composition | Scalar and optimized tile evaluation; dirty GPU regions; roughness/metallic and specular/glossiness workflows | Workflow is renderer-wide; the host groups strokes across materials |
| Maps | World/tangent normals, position, ID, AO, bent normal, thickness, curvature, height; high-to-low normal/height transfer; cancellation; undoable imports | Finite AO/transfer tests. Curvature/standalone height are simpler definitions than upstream; no full cage/skew/name-pair bake parity |
| Persistence | Versioned native layer/project JSON; RGBA8/RGBA16 PNG; caller-owned C buffers | No .tcraft, general image decoder, glTF/OBJ importer, UDIM or complete format parity |
| Rendering | Vulkan resources; persistent geometry/material updates; raster; recovered progressive transport, BSDF, transmission/emission, denoising, lens/display controls | Linux NVIDIA tested; raster is an approximation profile with opaque ray shadows, unoccluded IBL and no temporal AA |
| Lighting | Constant/HDR environments, six presets, rotation, SH9/GGX raster IBL, traced enclosed transport and emissive panels | Arbitrary analytic local-light API and transparent raster shadows remain extensions |
| CPU execution | Same transport shaders on an explicit CPU Vulkan driver | Small llvmpipe smoke test; replaces a separate original CPU tracer port |
| Hosts | Zig modules, static/shared C ABI, Python adapter; host-supplied persistent surface IDs; deformation and live gesture events | Application UI and movie/character document commands remain with their owning applications |

Sparse 2D painting and GPU edits support 8K dimensions. The full UV G-buffer
caps 3D painting/baking at 16,777,216 texels. Dense GPU data is bounded by the
device storage-buffer range and a 512 MiB library cap. Fully populated 8K
multichannel materials can exceed that cap.

All three requested application workflows run in `examples/workflows.zig`.
`run.py --full --output NEW_DIRECTORY` adds real actor edits, preview/history,
deformation, room controls, original comparisons, CPU execution and native-4K
output. Original evidence remains unchanged. See [API](API.md) and
[performance](PERFORMANCE.md).
