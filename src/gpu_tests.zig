const std = @import("std");
const core = @import("texture_painting");
const h = @import("hamudi1");
const t = std.testing;

test "resident geometry, dirty materials and accumulation survive animation" {
    var failing = t.FailingAllocator.init(t.allocator, .{});
    var renderer = try h.renderer.Renderer.init(failing.allocator());
    defer renderer.deinit();
    var positions = [_]core.math.V3{ .{ -1, -1, 0 }, .{ 1, -1, 0 }, .{ 0, 1, 0 } };
    const normals: [3]core.math.V3 = @splat(.{ 0, 0, 1 });
    const mesh: core.geometry.Mesh = .{ .positions = &positions, .normals = &normals, .uvs = &.{ .{ 0, 0 }, .{ 1, 0 }, .{ 0.5, 1 } }, .indices = &.{ 0, 1, 2 } };
    var bvh = try core.geometry.Bvh.init(t.allocator, mesh);
    defer bvh.deinit();
    try renderer.setMesh(mesh, &bvh);
    try renderer.setMaterials(&.{.{ .width = 4, .height = 4, .base = .{ 0.8, 0.05, 0.03 } }});
    try renderer.setEnvironment(.{ 0.5, 0.5, 0.5 });
    try renderer.resize(64, 64);
    const camera: core.math.Camera = .{ .target = .{ 0, 0, 0 }, .yaw = 0, .pitch = 0, .distance = 3, .scene_radius = 2 };
    const before = try t.allocator.dupe(u8, (try renderer.preview(camera, .{}, true)).?);
    defer t.allocator.free(before);
    const geometry_handle = renderer.buffers[2].handle;
    const material_handle = renderer.buffers[10].handle;
    const allocations = renderer.stats.scene_buffer_allocations;
    positions[2][0] = 0.5;
    try bvh.refit(mesh);
    // Warm same-topology updates must not allocate Zig workspace or GPU buffers.
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try renderer.setMesh(mesh, &bvh);
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    try t.expectEqual(geometry_handle, renderer.buffers[2].handle);
    try t.expectEqual(material_handle, renderer.buffers[10].handle);
    try t.expectEqual(allocations, renderer.stats.scene_buffer_allocations);
    const changed = (try renderer.preview(camera, .{}, true)).?;
    try t.expect(!std.mem.eql(u8, before, changed));
    const old_uploads = renderer.stats.geometry_uploads;
    const green: [16][4]u16 = @splat(.{ 0, 65535, 0, 65535 });
    try renderer.updateBaseRegion(0, 0, 0, 4, 4, &green);
    const promoted = renderer.buffers[10].handle;
    try renderer.updateBaseRegion(0, 1, 1, 1, 1, &.{.{ 65535, 65535, 65535, 65535 }});
    try t.expectEqual(promoted, renderer.buffers[10].handle);
    try t.expectEqual(old_uploads, renderer.stats.geometry_uploads);
    const sparse_frame = try t.allocator.dupe(u8, (try renderer.preview(camera, .{}, true)).?);
    defer t.allocator.free(sparse_frame);
    var dense = green;
    dense[5] = .{ 65535, 65535, 65535, 65535 };
    try renderer.setMaterials(&.{.{ .width = 4, .height = 4, .rgba = &dense }});
    try t.expectEqualSlices(u8, sparse_frame, (try renderer.preview(camera, .{}, true)).?);
    try renderer.pass(camera, .{}, 2);
    try renderer.pass(camera, .{}, 2);
    try t.expectEqual(@as(u32, 4), renderer.samples);
    const prior_bytes = renderer.stats.uploaded_bytes;
    try t.expectError(error.InvalidEnvironment, renderer.setEnvironment(.{ -1, 0, 0 }));
    try t.expectEqual(prior_bytes, renderer.stats.uploaded_bytes);
    try t.expectError(error.InvalidSettings, renderer.pass(camera, .{ .exposure = std.math.nan(f32) }, 1));
    try t.expectEqual(@as(u32, 4), renderer.samples);
    var moved = camera;
    moved.yaw = 0.1;
    try renderer.pass(moved, .{}, 2);
    try t.expectEqual(@as(u32, 2), renderer.samples);
    try renderer.pass(moved, .{ .bounces = 3 }, 1);
    try t.expectEqual(@as(u32, 1), renderer.samples);
    _ = try renderer.pixels(.{});
    try renderer.resize(32, 24);
    try t.expectEqual(@as(u32, 0), renderer.samples);
    try t.expectEqual(@as(usize, 32 * 24 * 4), (try renderer.preview(camera, .{}, true)).?.len);
}

test "small edits of an 8K material use sparse GPU pages" {
    var renderer = try h.renderer.Renderer.init(t.allocator);
    defer renderer.deinit();
    try renderer.setMaterials(&.{.{ .width = 8192, .height = 8192 }});
    const bytes = renderer.stats.uploaded_bytes;
    const patch: [4][4]u16 = @splat(.{ 65535, 0, 0, 65535 });
    // Four adjacent tiles at their shared corner; untouched areas retain defaults.
    try renderer.updateBaseRegion(0, 63, 63, 2, 2, &patch);
    try t.expect(renderer.stats.uploaded_bytes - bytes < 256 * 1024);
    try t.expect(renderer.buffers[10].bytes.len <= 1024 * 1024);
    const resident = renderer.buffers[10].handle;
    try renderer.updateBaseRegion(0, 63, 63, 2, 2, &patch);
    try t.expectEqual(resident, renderer.buffers[10].handle);
    const uploads = renderer.stats.material_uploads;
    try t.expectError(error.InvalidRegion, renderer.updateBaseRegion(0, 8192, 0, 2, 2, &patch));
    try t.expectEqual(uploads, renderer.stats.material_uploads);
}

test "an empty scene renders its environment in both backends" {
    var renderer = try h.renderer.Renderer.init(t.allocator);
    defer renderer.deinit();
    const mesh: core.geometry.Mesh = .{ .positions = &.{}, .normals = &.{}, .uvs = &.{}, .indices = &.{} };
    var bvh = try core.geometry.Bvh.init(t.allocator, mesh);
    defer bvh.deinit();
    try t.expect(bvh.cast(mesh, .{ .origin = .{ 0, 0, 3 }, .dir = .{ 0, 0, -1 } }, 100) == null);
    try renderer.setMesh(mesh, &bvh);
    try renderer.setMaterials(&.{});
    try renderer.setEnvironment(.{ 0.5, 0.25, 0.1 });
    try renderer.resize(32, 24);
    const camera: core.math.Camera = .{};
    const preview = (try renderer.preview(camera, .{ .filmic = false }, true)).?;
    try t.expect(preview[0] > preview[1] and preview[1] > preview[2]);
    const expected = preview[0..4].*;
    try renderer.pass(camera, .{ .denoise = false }, 1);
    const traced = try renderer.pixels(.{ .denoise = false });
    for (expected, traced[0..4]) |a, b| try t.expect(@abs(@as(i32, a) - b) <= 1);
}
