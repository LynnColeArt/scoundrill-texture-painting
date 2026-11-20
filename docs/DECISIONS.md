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
