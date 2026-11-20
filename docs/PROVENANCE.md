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
This foundation imports no upstream implementation or shader code.

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

The earlier experiment's Rust executables are development oracles. They are
not Zig implementations. No production Rust linkage, renderer replacement,
new rendering run or speedup is asserted by this repository foundation.
