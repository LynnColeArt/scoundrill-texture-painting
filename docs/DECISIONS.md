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
Previously constant channels allocate dense backing on first use, then accept
region updates without reallocating the scene.

The actor's garment, teeth and tongue have no authored UV area in the reference
packet. The interactive adapter therefore generates padded triangle charts in
Zig, keeps authored skin/eye UVs, and expands the previously constant material
color into an editable texture. Original fixture data and CLI parity inputs are
unchanged. This resolves otherwise invisible painting on zero-area UVs.

Project IO uses native versioned JSON and PNG8/PNG16. Full .tcraft and external
format parity have not been substituted by this format choice; their remaining
scope stays explicit in the roadmap.
