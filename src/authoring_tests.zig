const std = @import("std");
const p = @import("painting.zig");
const g = @import("geometry.zig");
const m = @import("math.zig");
const tex = @import("texel.zig");
const blend = @import("blend.zig");
const t = std.testing;

test "seven procedural brushes match original Rust observations" {
    const parsed = try std.json.parseFromSlice([]const [6]f64, t.allocator, @embedFile("fixtures/brush-goldens.json"), .{});
    defer parsed.deinit();
    try t.expectEqual(@as(usize, 12138), parsed.value.len);
    for (parsed.value) |row| {
        const brush: p.Brush = .{ .alpha = @enumFromInt(@as(u8, @intFromFloat(row[0]))), .hardness = @floatCast(row[3]), .seed = @intFromFloat(row[4]) };
        const expected: f32 = @bitCast(@as(u32, @intFromFloat(row[5])));
        try t.expectApproxEqAbs(expected, brush.sample(@floatCast(row[1]), @floatCast(row[2])), 2e-5);
    }
}

test "image stamps keep aspect and borrowed pixel ownership" {
    const image: p.ImageAlpha = .{ .width = 2, .height = 1, .pixels = &.{ 0, 65535 } };
    const brush: p.Brush = .{ .image = image, .radius = 0.4 };
    try brush.validate();
    try t.expectEqual(@as(f32, 0), brush.sample(-1, 0));
    try t.expectEqual(@as(f32, 1), brush.sample(1, 0));
    try t.expectEqual(@as(f32, 0), brush.sample(0, 0.75));
    var session = try p.Session.init(t.allocator, 32, 32);
    defer session.deinit();
    const layer = try session.addLayer("stamp", .paint);
    try session.begin(layer, .base_color, .{ 1, 0, 0 }, 1, false);
    try session.stampUv(.{ 0.5, 0.5 }, brush, 1);
    try session.commit();
    try t.expect(session.document.pixel(.base_color, 24, 16)[0] > session.document.pixel(.base_color, 8, 16)[0]);
    try t.expectEqual(m.V3{ 0.5, 0.5, 0.5 }, session.document.pixel(.base_color, 16, 1));
    try t.expect(try session.undo());
    try t.expectEqual(m.V3{ 0.5, 0.5, 0.5 }, session.document.pixel(.base_color, 24, 16));
}
fn importFailure(a: std.mem.Allocator) !void {
    var session = try p.Session.init(a, 8, 8);
    defer session.deinit();
    const pixels: [64][4]u16 = @splat(.{ 0, 0, 0, 65535 });
    _ = try session.importChannel("baked height", .height, &pixels);
    try t.expect(session.document.pixel(.height, 4, 4)[0] < -0.99);
    try t.expect(try session.undo());
    try t.expectEqual(@as(f32, 0), session.document.pixel(.height, 4, 4)[0]);
    try t.expect(try session.redo());
}
test "map import is atomic and signed across allocation failures" {
    try t.checkAllAllocationFailures(t.allocator, importFailure, .{});
}

test "tile composition agrees with scalar evaluation across modes, masks and channels" {
    var s = try p.Session.init(t.allocator, 73, 65);
    defer s.deinit();
    const fill = try s.addLayer("pattern", .fill);
    const painted = try s.addLayer("paint", .paint);
    for ([_]p.Channel{ .base_color, .height, .normal }) |ch| {
        try s.setFill(fill, ch, .{ 0.2, 0.6, 0.8 }, .checker, 7.2);
        try s.begin(painted, ch, .{ 0.4, 0.1, 0.9 }, 0.7, false);
        try s.stampUv(.{ 0.8, 0.9 }, .{ .radius = 0.6 }, 1);
        try s.commit();
    }
    var mask = try tex.Image.init(t.allocator, 73, 65, 1);
    defer mask.deinit();
    _ = try mask.tileMut(0, 0, .{ 38000, 0, 0, 0 });
    _ = try mask.tileMut(1, 1, .{ 19000, 0, 0, 0 });
    try s.setMask(painted, mask);
    var values: [4096]m.V3 = undefined;
    for (0..@typeInfo(blend.Mode).@"enum".fields.len) |mode| {
        for ([_]p.Pattern{ .uniform, .checker, .noise, .stripes }) |pattern| {
            s.document.layers.items[fill].pattern = pattern;
            for ([_]p.Channel{ .base_color, .height, .normal }) |ch| {
                s.document.layers.items[painted].modes[@intFromEnum(ch)] = @enumFromInt(mode);
                for (0..2) |ty| for (0..2) |tx| {
                    s.document.composeTile(ch, @intCast(tx), @intCast(ty), &values);
                    for (0..64) |sample| {
                        const x: u32 = @intCast(tx * 64 + sample % 8);
                        const y: u32 = @intCast(ty * 64 + sample / 8);
                        if (x >= 73 or y >= 65) continue;
                        const scalar = s.document.pixel(ch, x, y);
                        for (scalar, values[(y % 64) * 64 + x % 64]) |a, b| try t.expectApproxEqAbs(a, b, 1e-7);
                    }
                };
            }
        }
    }
}

test "parallel world painting preserves serial texels, visibility and history" {
    var positions: [289]m.V3 = undefined;
    const normals: [289]m.V3 = @splat(.{ 0, 0, 1 });
    var uvs: [289]m.V2 = undefined;
    var indices: [1536]u32 = undefined;
    for (0..17) |y| for (0..17) |x| {
        const u = @as(f32, @floatFromInt(x)) / 16;
        const v = @as(f32, @floatFromInt(y)) / 16;
        positions[y * 17 + x] = .{ u * 2 - 1, v * 2 - 1, 0 };
        uvs[y * 17 + x] = .{ u, v };
    };
    for (0..16) |y| for (0..16) |x| {
        const a: u32 = @intCast(y * 17 + x);
        @memcpy(indices[(y * 16 + x) * 6 ..][0..6], &[_]u32{ a, a + 1, a + 17, a + 1, a + 18, a + 17 });
    };
    const mesh: g.Mesh = .{ .positions = &positions, .normals = &normals, .uvs = &uvs, .indices = &indices };
    var bvh = try g.Bvh.init(t.allocator, mesh);
    defer bvh.deinit();
    var uv = try g.UvBuffer.init(t.allocator, mesh, 128, 128, null);
    defer uv.deinit();
    var serial = try p.Session.init(t.allocator, 128, 128);
    defer serial.deinit();
    var parallel = try p.Session.init(t.allocator, 128, 128);
    defer parallel.deinit();
    for ([_]*p.Session{ &serial, &parallel }, [_]u8{ 1, 8 }) |session, workers| {
        var selected_uv = uv;
        if (workers == 1) selected_uv.padding_masks = &.{};
        const layer = try session.addLayer("detail", .paint);
        try session.begin(layer, .base_color, .{ 0.8, 0.1, 0.3 }, 0.7, false);
        for ([_]f32{ 0, 0.1, -0.1 }) |offset| try session.stampWorld(mesh, &bvh, selected_uv, .{ offset, 0, 0 }, .{ 0, 0, 1 }, .{ .radius = 0.5, .flow = 0.42, .workers = workers, .mirror_x = true }, .{ 0, 0, 3 });
        try session.commit();
        try t.expectEqual(@as(usize, 1), session.undo_stack.items.len);
    }
    for (0..128) |y| for (0..128) |x| try t.expectEqual(serial.document.pixel(.base_color, @intCast(x), @intCast(y)), parallel.document.pixel(.base_color, @intCast(x), @intCast(y)));
    const revision = parallel.revision;
    try parallel.begin(0, .base_color, .{ 1, 1, 1 }, 1, false);
    try parallel.stampWorld(mesh, &bvh, uv, .{ 0, 0, 0 }, .{ 0, 0, 1 }, .{ .radius = 0.5, .workers = 8 }, .{ 0, 0, -3 });
    try parallel.commit();
    try t.expectEqual(revision, parallel.revision);
    try t.expectEqual(@as(usize, 1), parallel.undo_stack.items.len);
}
