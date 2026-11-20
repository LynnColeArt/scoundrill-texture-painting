# Reference provenance

This project recreates selected TextureCraft subsystems in Zig using the
licensed source and recorded behavior. It is a source-informed port and
extraction, not a clean-room claim.

Upstream: https://github.com/storytold/texturecraft
Pinned revision: 52ba5338dc07640704d58122e559355a41147b6a
Workspace version: 0.6.1
Upstream declares MIT OR Apache-2.0. Its README credits the ArtCraft Team and
TextureCraft contributors. Before adapting implementation or shaders, preserve
the applicable full license text and notices, and track exact source hashes.
Recovered WGSL, generated variants and SPIR-V are now included under the selected
MIT license. Full upstream license texts and NOTICE are retained in
licenses/texturecraft. See ATTRIBUTION.md.

## Consulted references

On November 20, 2026, the pinned upstream README, workspace Cargo.toml,
docs/architecture.md and the core, texel, geom, compose, paint, bake, render and
engine Cargo.toml files were read through the GitHub connector.
reference/upstream.json records exact paths, URLs and direct internal dependencies.
Manifest/documentation inspection establishes an initial inventory, not complete
source recovery or validation of every advertised feature.

Existing local evidence was read from:
- /home/lynn/projects/scoundrill/docs/TEXTURECRAFT-RENDERER.md
- /home/lynn/projects/scoundrill/experiments/texturecraft/
- /home/lynn/projects/scoundrill/experiments/texturecraft/room/

reference/baseline-index.json pins the local Scoundrill HEAD at indexing time and
hashes the relevant saved reports and PNG results. It records paths in the
sibling checkout; it does not copy images or make this project self-contained.
The index also reports whether each recorded working-tree file matches that
commit. Preserve original source manifests, fixtures, observations and images.

Following the owner's direction to reuse Movie Maker's extensive behavior
documentation, docs/RENDERER-BEHAVIOR.md maps its actor and room verifiers,
independent Cycles comparisons, scene-transfer contract and Godot timing study.
reference/behavior-index.json separately pins the consulted harnesses, reports,
fixtures and comparison artifacts. The original baseline index is unchanged.

The earlier experiment's Rust executables are development oracles. They are
not Zig implementations. The new native executable links Vulkan and libc, with
all renderer host logic in Zig. Its first actor comparison is a new candidate
run; original records were not overwritten. The modern Scoundrill factory now selects a pinned Hamudi-1 build; fixed BRender
compatibility is unchanged. No general cross-renderer speedup is established.

reference/source-inventory.json records 239 selected upstream source files and
SHA-256 hashes before porting. Source-informed implementations consult core
blend.rs, texel tile/color helpers, geometry camera/BVH conventions, paint
brush/raster/commit conventions, render gpu_trace.rs and the recovered WGSL.
reference/core-goldens.json identifies the 2592 unchanged Rust blend observations.
The recording driver is retained in tools/oracle; its Cargo manifest is a path
template for a separate temporary reference checkout.

Additional source-informed recovery includes binned BVH splitting, UV-derived
tangent conventions, two-texel stroke padding and the raster environment-BRDF
fit. Vulkan calls follow the installed Khronos Vulkan headers; Naga's installed
public API supplies development-only SPIR-V generation. Original shaders remain
unchanged under shaders/upstream, with generated resource access under
shaders/generated and the native preview entry points in shaders/preview.wgsl.

The procedural noise and seven brush sampling functions now have independent
original observations. `reference/brush-goldens.json` records original source,
shim and fixture hashes. The recording shim extracts the original sample and
smoothstep function bodies verbatim; the original noise file is compiled
unchanged and its own checksum test is run. The Zig noise test reproduces all
58,366 checksum inputs; 12,138 brush observations cover coordinates, hardness
and seeds. No original observation was regenerated to hide a candidate mismatch.

HDR presets, SH irradiance and GGX prefiltering are informed by pinned render
`ibl.rs`. The Vulkan memory/resource policies, sparse GPU page layout, tile
compositor, parallel disjoint-texel painting, cached seam-neighbor masks and
native ABI are Zig implementation choices. A separate same-source host-storage
build is retained as an executable memory-placement measurement control.

Candidate release captures are retained separately under
reference/acceptance-20261120, with hashes and exact run commits. They include
rendered views of Scoundrill's CC0-derived actor; the fixture provenance and CC0
dedication are retained alongside them. Native JSON v1 remains readable, and
compact v2 stores binary tiles with checked metadata, CRC and bounded decoding.
The dense-4K project check is a new candidate observation, not an upstream golden.
