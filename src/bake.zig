//! Bounded CPU mesh-map generation. No window or renderer dependency.
const std = @import("std");
const m = @import("math.zig");
const g = @import("geometry.zig");
const p = @import("painting.zig");
pub const Kind = enum { world_normal, position, id, ambient_occlusion, bent_normal, thickness, curvature, height, normal };
pub const Options = struct { samples: u32 = 32, distance: f32 = 1, epsilon: f32 = 1e-5, cancel: ?*const std.atomic.Value(bool) = null };
pub fn generate(a: std.mem.Allocator, kind: Kind, mesh: g.Mesh, bvh: *const g.Bvh, uv: g.UvBuffer, options: Options) ![][4]u16 {
    try mesh.validate();
    if (options.samples == 0 or options.samples > 256 or !std.math.isFinite(options.distance) or options.distance <= 0 or !std.math.isFinite(options.epsilon) or options.epsilon <= 0) return error.BakeBudget;
    const output = try a.alloc([4]u16, uv.texels.len);
    errdefer a.free(output);
    @memset(output, .{ 0, 0, 0, 0 });
    const bounds = bvh.nodes[0].bounds;
    const extent = m.sub(bounds.hi, bounds.lo);
    for (uv.texels, 0..) |texel, i| {
        if (i % 1024 == 0) if (options.cancel) |cancel| {
            if (cancel.load(.acquire)) return error.Cancelled;
        };
        if (texel.triangle == std.math.maxInt(u32)) continue;
        const position = g.UvBuffer.position(mesh, texel);
        const normal = g.UvBuffer.normal(mesh, texel);
        var value: m.V3 = .{ 0, 0, 0 };
        switch (kind) {
            .world_normal => value = m.add(m.scale(normal, 0.5), .{ 0.5, 0.5, 0.5 }),
            .normal => value = .{ 0.5, 0.5, 1 },
            .position => for (0..3) |k| {
                value[k] = (position[k] - bounds.lo[k]) / @max(extent[k], 1e-8);
            },
            .id => {
                const id = if (mesh.materials.len > 0) mesh.materials[texel.triangle] else texel.triangle;
                value = .{ p.noise(id, 1, 0), p.noise(id, 2, 0), p.noise(id, 3, 0) };
            },
            .height => value = @splat((position[1] - bounds.lo[1]) / @max(extent[1], 1e-8)),
            .curvature => {
                const tri = mesh.triangle(texel.triangle);
                const gn = m.norm(m.cross(m.sub(tri[1], tri[0]), m.sub(tri[2], tri[0])));
                value = @splat(1 - std.math.clamp(m.dot(normal, gn), 0, 1));
            },
            .ambient_occlusion, .bent_normal, .thickness => {
                const axis = if (kind == .thickness) m.scale(normal, -1) else normal;
                const tangent = m.norm(m.cross(if (@abs(axis[1]) < 0.9) m.V3{ 0, 1, 0 } else m.V3{ 1, 0, 0 }, axis));
                const bitangent = m.cross(axis, tangent);
                const origin = m.add(position, m.scale(axis, options.epsilon));
                var sum: f32 = 0;
                var bent: m.V3 = .{ 0, 0, 0 };
                for (0..options.samples) |s| {
                    const u = (@as(f32, @floatFromInt(s)) + 0.5) / @as(f32, @floatFromInt(options.samples));
                    const v = @as(f32, @floatFromInt(@bitReverse(@as(u32, @intCast(s))))) / 4294967296;
                    const radius = @sqrt(u);
                    const phi = std.math.tau * v;
                    const dir = m.add(m.add(m.scale(tangent, radius * @cos(phi)), m.scale(bitangent, radius * @sin(phi))), m.scale(axis, @sqrt(1 - u)));
                    const hit = bvh.cast(mesh, .{ .origin = origin, .dir = dir }, options.distance);
                    if (kind == .thickness) {
                        sum += if (hit) |h| h.distance / options.distance else 1;
                    } else if (hit == null) {
                        sum += 1;
                        bent = m.add(bent, dir);
                    }
                }
                value = if (kind == .bent_normal) m.add(m.scale(if (m.length(bent) > 0) m.norm(bent) else normal, 0.5), .{ 0.5, 0.5, 0.5 }) else @splat(sum / @as(f32, @floatFromInt(options.samples)));
            },
        }
        output[i] = .{ m.u16of(value[0]), m.u16of(value[1]), m.u16of(value[2]), 65535 };
    }
    return output;
}
/// High-poly tangent-space normal and signed-distance transfer along a cage normal.
pub fn transfer(a: std.mem.Allocator, low: g.Mesh, uv: g.UvBuffer, high: g.Mesh, bvh: *const g.Bvh, reach: f32) !struct { normal: [][4]u16, height: []u16 } {
    try low.validate();
    try high.validate();
    if (!std.math.isFinite(reach) or reach <= 0) return error.BakeBudget;
    const normals = try a.alloc([4]u16, uv.texels.len);
    errdefer a.free(normals);
    @memset(normals, .{ 32768, 32768, 65535, 0 });
    const heights = try a.alloc(u16, uv.texels.len);
    errdefer a.free(heights);
    @memset(heights, 32768);
    for (uv.texels, 0..) |texel, i| {
        if (texel.triangle == std.math.maxInt(u32)) continue;
        const pos = g.UvBuffer.position(low, texel);
        const n = g.UvBuffer.normal(low, texel);
        if (bvh.cast(high, .{ .origin = m.add(pos, m.scale(n, reach)), .dir = m.scale(n, -1) }, reach * 2)) |hit| {
            const hn = g.UvBuffer.normal(high, .{ .triangle = hit.triangle, .bary = hit.bary });
            const tangent = m.norm(m.cross(if (@abs(n[1]) < 0.9) m.V3{ 0, 1, 0 } else m.V3{ 1, 0, 0 }, n));
            const bitangent = m.cross(n, tangent);
            normals[i] = .{ m.u16of(m.dot(hn, tangent) * 0.5 + 0.5), m.u16of(m.dot(hn, bitangent) * 0.5 + 0.5), m.u16of(m.dot(hn, n) * 0.5 + 0.5), 65535 };
            heights[i] = m.u16of((reach - hit.distance) / (2 * reach) + 0.5);
        }
    }
    return .{ .normal = normals, .height = heights };
}
test "plane AO, world normals, and cancellation" {
    const a = std.testing.allocator;
    const mesh: g.Mesh = .{ .positions = &.{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 } }, .normals = &.{ .{ 0, 0, 1 }, .{ 0, 0, 1 }, .{ 0, 0, 1 } }, .uvs = &.{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 } }, .indices = &.{ 0, 1, 2 } };
    var bvh = try g.Bvh.init(a, mesh);
    defer bvh.deinit();
    var uv = try g.UvBuffer.init(a, mesh, 16, 16, null);
    defer uv.deinit();
    const ao = try generate(a, .ambient_occlusion, mesh, &bvh, uv, .{ .samples = 8 });
    defer a.free(ao);
    try std.testing.expectEqual(@as(u16, 65535), ao[0][0]);
    var cancel = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Cancelled, generate(a, .position, mesh, &bvh, uv, .{ .cancel = &cancel }));
}
