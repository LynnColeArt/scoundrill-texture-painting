# Implementation decisions

## Direct Vulkan first

The first backend targets the existing Linux/RTX 4070 reference environment.
Zig owns the Vulkan device, allocations, descriptors, pipelines and progressive
dispatch. Naga compiles WGSL to committed SPIR-V during development; normal Zig
builds do not require Rust. Additional platform backends remain future work.

## Resource layout adaptation

The recovered WGSL remains in shaders/upstream. tools/prepare_shaders.py produces
buffer-backed material access and a buffer-backed display resolve, leaving the
transport and denoising algorithms intact. Packed material buffers support
region updates without recreating texture arrays. The change requires explicit
original/candidate validation; it is not assumed equivalent from inspection.

## Behavior and corrections

Original renderer records remain immutable. Candidate image differences are
measured on their pinned inputs. Scale-safe offsets are selectable separately
from legacy bounds offsets. Default-renderer cutover remains dependent on
integration acceptance and does not follow from a successful actor render alone.

## Native authoring and missing UVs

The authoring module is independent of Vulkan/libc. A separate renderer module
and material-sync adapter expose the combined workflow through C and Python.
Dirty updates cover the recovered packed material channels, not only base color.
Previously constant channels grow sparse 64×64 GPU pages on first use, then
reuse resident pages. Geometric capacity growth avoids reallocating for each
new page; warm fixed-topology actor updates reuse geometry buffers and workspace.

The actor's garment, teeth and tongue have no authored UV area in the reference
packet. The interactive adapter therefore generates padded triangle charts in
Zig, keeps authored skin/eye UVs, and expands the previously constant material
color into an editable texture. Original fixture data and CLI parity inputs are
unchanged. This resolves otherwise invisible painting on zero-area UVs.

Project IO uses native versioned JSON and PNG8/PNG16. Full .tcraft and external
format parity have not been substituted by this format choice; their remaining
scope stays explicit in the roadmap.

## Preview quality and shared hosts

The Scoundrill modern factory defaults to the recovered traced transport, keeping
the accepted warm emissive-panel profile meaningful. Raster is an explicit fast
profile. Small progressive submissions let the host cancel or prioritize input
between batches; a submitted GPU batch is not preemptible. Host document IDs
identify assets/materials/textures/UV sets; transient native handles never replace
those identities. Studio UI remains with its parallel owner.

## CPU execution and formats

CPU rendering uses the same shaders through a CPU Vulkan driver, rather than a
second hand-port of the Rust CPU tracer. This reduces transport drift; the
platform dependency and tiny llvmpipe acceptance are explicit. Native project
JSON/PNG supplies working persistence, while .tcraft and broad import support
remain separate extensions. [CAPABILITIES.md](CAPABILITIES.md) lists the shipped
operations and the upstream features that are not implied by them.
