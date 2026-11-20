//! Deterministic padded triangle charts for material sets with no authored UVs.
const std = @import("std");
const g = @import("geometry.zig");
const m = @import("math.zig");
pub const Owned = struct {
    allocator: std.mem.Allocator,
    mesh: g.Mesh,
    minimum_resolution: [256]u32,
    pub fn deinit(self: *Owned) void {
        self.allocator.free(self.mesh.positions);
        self.allocator.free(self.mesh.normals);
        self.allocator.free(self.mesh.uvs);
        self.allocator.free(self.mesh.indices);
        self.allocator.free(self.mesh.materials);
        self.* = undefined;
    }
};
pub fn missing(a: std.mem.Allocator, mesh: g.Mesh) !Owned {
    try mesh.validate();
    var counts: [256]u32 = @splat(0);
    var authored: [256]bool = @splat(false);
    const triangles = mesh.indices.len / 3;
    for (0..triangles) |i| {
        const mat = if (mesh.materials.len > 0) mesh.materials[i] else 0;
        if (mat >= 256) return error.MaterialBudget;
        counts[mat] += 1;
        const ids = mesh.indices[i * 3 ..][0..3];
        const u = mesh.uvs[ids[0]];
        const v = mesh.uvs[ids[1]];
        const w = mesh.uvs[ids[2]];
        if (@abs((v[0] - u[0]) * (w[1] - u[1]) - (v[1] - u[1]) * (w[0] - u[0])) > 1e-12) authored[mat] = true;
    }
    var minimum: [256]u32 = @splat(0);
    var extra: usize = 0;
    for (counts, authored, 0..) |count, has_uv, i| {
        if (count == 0 or has_uv) continue;
        const columns: u32 = @intFromFloat(@ceil(@sqrt(@as(f32, @floatFromInt(count)))));
        const resolution = ((columns * 8 + 63) / 64) * 64;
        if (resolution > 8192) return error.ImageBudget;
        minimum[i] = resolution;
        extra += @as(usize, count) * 3;
    }
    if (mesh.positions.len + extra > 4_000_000) return error.MeshBudget;
    const p = try a.alloc(m.V3, mesh.positions.len + extra);
    errdefer a.free(p);
    @memcpy(p[0..mesh.positions.len], mesh.positions);
    const n = try a.alloc(m.V3, p.len);
    errdefer a.free(n);
    @memcpy(n[0..mesh.normals.len], mesh.normals);
    const uv = try a.alloc(m.V2, p.len);
    errdefer a.free(uv);
    @memcpy(uv[0..mesh.uvs.len], mesh.uvs);
    const ids = try a.dupe(u32, mesh.indices);
    errdefer a.free(ids);
    const mats = try a.dupe(u32, mesh.materials);
    errdefer a.free(mats);
    var next = mesh.positions.len;
    var used: [256]u32 = @splat(0);
    for (0..triangles) |i| {
        const mat = if (mesh.materials.len > 0) mesh.materials[i] else 0;
        const res = minimum[mat];
        if (res == 0) continue;
        const columns = res / 8;
        const cell = used[mat];
        used[mat] += 1;
        const x = @as(f32, @floatFromInt((cell % columns) * 8));
        const y = @as(f32, @floatFromInt((cell / columns) * 8));
        const rf: f32 = @floatFromInt(res);
        const chart = [_]m.V2{ .{ (x + 1.5) / rf, (y + 1.5) / rf }, .{ (x + 6.5) / rf, (y + 1.5) / rf }, .{ (x + 1.5) / rf, (y + 6.5) / rf } };
        for (0..3) |k| {
            const source = mesh.indices[i * 3 + k];
            p[next] = mesh.positions[source];
            n[next] = mesh.normals[source];
            uv[next] = chart[k];
            ids[i * 3 + k] = @intCast(next);
            next += 1;
        }
    }
    return .{ .allocator = a, .mesh = .{ .positions = p, .normals = n, .uvs = uv, .indices = ids, .materials = mats }, .minimum_resolution = minimum };
}
test "missing UV charts preserve geometry and create covered texels" {
    const a = std.testing.allocator;
    const mesh: g.Mesh = .{ .positions = &.{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 } }, .normals = &.{ .{ 0, 0, 1 }, .{ 0, 0, 1 }, .{ 0, 0, 1 } }, .uvs = &.{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } }, .indices = &.{ 0, 1, 2 } };
    var owned = try missing(a, mesh);
    defer owned.deinit();
    try std.testing.expectEqual(mesh.triangle(0), owned.mesh.triangle(0));
    try std.testing.expectEqual(@as(u32, 64), owned.minimum_resolution[0]);
    var uv = try g.UvBuffer.init(a, owned.mesh, 64, 64, null);
    defer uv.deinit();
    var covered: usize = 0;
    for (uv.texels) |t| {
        if (t.triangle != std.math.maxInt(u32)) covered += 1;
    }
    try std.testing.expect(covered > 0);
}
