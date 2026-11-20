//! Renderer package. The authoring package is usable without Vulkan or libc.
pub const renderer = @import("renderer.zig");
pub const material_sync = @import("material_sync.zig");
pub const environment = @import("environment.zig");
test {
    @import("std").testing.refAllDecls(@This());
}
