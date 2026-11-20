const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core = b.addModule("texture_painting", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize, .link_libc = true });
    core.linkSystemLibrary("vulkan", .{});
    const cli = b.addExecutable(.{ .name = "hamudi", .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "texture_painting", .module = core }}, .link_libc = true }) });
    b.installArtifact(cli);
    const tests = b.addTest(.{ .root_module = core });
    b.step("test", "Run library correctness and allocation failure tests").dependOn(&b.addRunArtifact(tests).step);
}
