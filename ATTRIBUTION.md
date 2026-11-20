# Attribution

| Material | Source | License | Local notice |
| --- | --- | --- | --- |
| Recovered tracing, ray-query and denoising WGSL; generated resource-layout variants and SPIR-V | TextureCraft, ArtCraft Team and contributors, 52ba5338dc07640704d58122e559355a41147b6a | MIT (selected from MIT OR Apache-2.0) | licenses/texturecraft/ |
| Blend math and source-informed image/painting conventions | Same pinned TextureCraft source | MIT | licenses/texturecraft/ |
| Blend oracle fixtures | Unchanged TextureCraft core functions, original recording driver in tools/oracle/ | MIT | licenses/texturecraft/ |

Naga 30.0.1 is a development-only shader compiler dependency under MIT OR
Apache-2.0, resolved in tools/shader-compiler/Cargo.lock. No Rust compiler or
renderer runtime is linked into the Zig executable. The Vulkan loader and GPU
driver are external platform dependencies. No upstream brands, icons, fonts or
other visual assets are bundled here.
