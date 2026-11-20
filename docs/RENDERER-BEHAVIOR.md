# Movie Maker renderer behavior and acceptance map

Scoundrill is the Movie Maker project. Its existing renderer documentation,
fixtures, harnesses, verifiers and recorded results are the starting behavior
contract for hamudi-1. Feasibility testing has already been done. Extend its
coverage for the Zig port instead of repeating discovery from scratch.

The records remain in the sibling checkout. [The original index](../reference/baseline-index.json)
pins actor/room results; [the behavior index](../reference/behavior-index.json)
pins the additional consulted inputs and executable checks. Both record the
Scoundrill commit and working-file hashes. Indexing is not a fresh rendering run.

## Evidence entry points

- [Renderer assessment](../../scoundrill/docs/TEXTURECRAFT-RENDERER.md)
- [Actor experiment](../../scoundrill/experiments/texturecraft/README.md) and
  [actor verifier](../../scoundrill/experiments/texturecraft/verify_experiment.py)
- [Room experiment](../../scoundrill/experiments/texturecraft/room/README.md) and
  [room verifier](../../scoundrill/experiments/texturecraft/room/verify_room.py)
- [Independent Cycles room comparison](../../scoundrill/experiments/texturecraft/room/cycles/README.md)
  and [comparison verifier](../../scoundrill/experiments/texturecraft/room/cycles/verify_compare.py)
- [Scene/material transfer contract](../../scoundrill/docs/CYCLES-BRIDGE.md) and
  [frozen scene packet](../../scoundrill/modern/reference/snapshot.json.gz)
- [Godot navigation/readback study](../../scoundrill/experiments/godot_forward_plus/README.md)

## Established behavior to carry into port acceptance

| ID | Existing check or observation | How to use it |
| --- | --- | --- |
| R01 | Actor verifier checks positions/normals with zero error and sampled vertex-color atlas error below 1/65535. | Preserve source colors and geometry; the triangle atlas is an explicitly approximate adapter. Native vertex-color support needs its own comparison. |
| R02 | Actor adapter decodes eye RGB from sRGB and applies the original MASK cutoff before upload. | Preserve color/coverage semantics; add focused candidate tests beyond this actor fixture. |
| R03 | Actor verifier checks native dimensions, nonblank output, and the recorded RTX 4070 adapter for raster/GPU cases at 720p, 1080p and 4K. | Reuse the workload matrix; declare the actual test adapter and prohibit silent fallback. |
| R04 | At 256x144/128 samples, recorded CPU/GPU mean byte difference is 0.1670 and maximum is 1. The verifier allows mean below 0.5 and maximum at most 3. | Distinguish observed values from acceptance limits. This is a starting finite-scene oracle, not an all-material tolerance. |
| R05 | An unused outlier vertex changes the face ROI despite unchanged rendered triangles; the diagnostic requires mean difference above 1. | Retain the original bug reproduction. A scale-safe ray-offset correction needs a separately named regression and expected behavior. Do not make the corrected candidate reproduce the bug. |
| R06 | Room preparation preserves the actor prefix exactly; closing the window only adds a shutter; lamp off changes only emission. | Keep controlled inputs and their hashes so light-response differences remain attributable. |
| R07 | Closing the window darkens traced floor by more than 2 displayed levels and leaves it below 1; closed-room raster back wall remains above 30. | Preserve the traced transport check and retain the raster environment-leak diagnostic. Indoor-lighting improvements require new expectations. |
| R08 | Shadow toggle changes floor ROI by more than 10; ten same-process directional-light frames change by more than 1000 bytes per step and return exactly to the first image. | Test invalidation and repeatability. Define separate expectations if temporal filtering deliberately changes the return behavior. |
| R09 | Traced lamp on/off changes actor ROI by more than 5, and moving it by more than 3; raster floor on/off delta is zero. | Preserve the light-transport checks; document any new raster local-light or indirect-light implementation independently. |
| R10 | Room evidence includes native 4K shadowed camera updates, with readback, and separate 720p moving-light timings. | Keep camera and light costs separate; do not extrapolate the light-sweep timing to 4K. |
| R11 | Cycles comparison checks frozen input hashes, geometry transfer error below 3e-6 and projection error below 0.005 pixels. | Reuse for scene/camera adapter validation. Cross-renderer image differences are descriptive, not pixel-parity gates. |
| R12 | Cycles comparison applies the matched exposure, 0.6 pre-scaled fitted ACES curve and sRGB transform; its displayed sealed floor is black despite tiny linear residuals. | Keep scene-linear checks separate from display checks and from the original AgX reference. |
| R13 | Godot study separates warm navigation from per-frame HDR readback and documents differing lighting profiles. | Reuse the workload design for optimization; its timings and quality are Godot evidence, not hamudi-1 performance. |

Thresholds above come from the committed verifiers. They are tied to the fixed
scene, camera, ROI, display profile and runtime used there. Porting a verifier
requires preserving those preconditions; these numbers are not generic tolerances.
The original verifiers and artifacts remain authoritative if this summary drifts.

## Known source observations and missing coverage

The assessment also records fully opaque shadow casters, shared shadow-map
state, contact seams and global-bounds ray offsets. Keep source-confirmed limits
distinct from executed controls. Read the pinned source and add focused cases
before changing those behaviors.

Existing records do not establish brush/compositor/baker parity, deforming actor
updates, instancing, all-material coverage, skin scattering, hair, transmission,
motion blur or production local-light units. Add those contracts as the selected
systems are recovered. Reuse the recorded actor/room scenes for integration.

The default viewport must declare its lighting/quality profile. A fast raster
preview and the traced room reference have different light transport; optimization
must measure fidelity as well as speed. Original outputs remain immutable while
intentional corrections receive separately versioned expectations.
