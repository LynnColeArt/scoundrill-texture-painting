# Performance plan

Heavy speed optimization is a product requirement. Numerical budgets below are
provisional engineering targets, not owner-approved thresholds or achieved results.

## Existing evidence

The unchanged Rust room experiment reports a mean 10.10 ms per native
3840x2160 shadowed camera update on an RTX 4070, including readback, across ten
small camera changes. Other work ran concurrently. It is useful feasibility
evidence, not an isolated benchmark, a p95 result, a painting-latency measurement
or an animated-scene measurement.

Actor and room evidence is indexed in reference/baseline-index.json.
Preserve these observations; capture dedicated benchmark runs separately.
The [behavior map](RENDERER-BEHAVIOR.md) links the existing executable checks and
quality comparisons to port acceptance. The Godot study also measures navigation
separately from per-frame readback; reuse that measurement distinction, without
attributing Godot's times to hamudi-1. Declare the chosen interactive lighting
profile and its relationship to the traced reference before default cutover.

## Measurement matrix

| Workload | Record separately |
| --- | --- |
| Camera-only updates | CPU submission, GPU time, frame p50/p95/p99, upload bytes, steady-state allocations |
| Directional/local-light changes | Shadow work, invalidation, frame distributions, correctness and temporal stability |
| Brush dragging on an actor | Input-to-visible latency, touched tiles, composite time, upload bytes, stalls |
| Large building/prop materials | Resolution, layer count, resident CPU/GPU memory, dirty area versus total area |
| Fine stamps and masks | Detail fidelity, update cost, undo/redo time and memory growth |
| Deforming actor | Geometry upload, acceleration structure work, material reuse and frame distributions |
| Progressive tracing/baking | Time to comparable quality, samples, cancellation latency, memory and convergence |

Run at 720p, 1080p and native 4K where applicable; distinguish viewport dimensions
from texture resolution. Include 1K/4K/8K materials and small/sparse/full dirty
regions. Pin scene, hardware/driver, build flags, quality settings and seeds.
Warm up and collect repeated runs. Keep CPU/GPU time, startup, readback,
image encoding and file IO identifiable. Explicitly identify overlapping work.

Initial target: a 16.67 ms steady interactive frame budget (60 Hz) and p95
input-to-visible paint response below 33.3 ms on the declared development
fixture/hardware. Validate or revise these after isolated baselines; do not
silently reduce resolution, quality or features to meet them.

## Optimization order

1. Instrument the original and candidate using the same workloads.
2. Keep meshes/materials resident; avoid uploads and resource recreation when
   camera, light or unrelated document data changes.
3. Preserve and measure dirty-region compositing and uploads. Investigate
   tile batching, compact update descriptors and allocation reuse.
4. Profile CPU hot loops for cache locality, SIMD and bounded parallel jobs.
   Profile GPU occupancy, bandwidth, pass count, traversal and synchronization.
5. Decouple painting responsiveness from tracing, baking and export work.
6. Consider algorithmic changes only with fidelity and quality comparisons.

Correctness gates cover channel semantics, color space, coverage, seams,
visibility and undo. Exact deterministic CPU cases use exact comparison.
Cross-device GPU and stochastic results need declared tolerances and quality
metrics before acceptance; a screenshot looking similar is insufficient.
Known corrections get separate expected behavior and evidence.
