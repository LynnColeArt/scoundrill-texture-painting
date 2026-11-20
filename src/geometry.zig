const std = @import("std");
const m = @import("math.zig");
pub const V3 = m.V3;
pub const V2 = m.V2;
pub const Mesh = struct {
    positions: []const V3,
    normals: []const V3,
    uvs: []const V2,
    indices: []const u32,
    materials: []const u32 = &.{},
    tangents: []const m.V4 = &.{},
    pub fn validate(self: Mesh) !void {
        if (self.positions.len == 0 or self.positions.len > 4_000_000 or self.indices.len == 0 or self.indices.len % 3 != 0 or self.indices.len > 12_000_000 or self.normals.len != self.positions.len or self.uvs.len != self.positions.len or (self.materials.len != 0 and self.materials.len != self.indices.len / 3)) return error.InvalidMesh;
        for (self.positions, self.normals, self.uvs) |p, n, uv| if (!m.finite(p) or !m.finite(n) or !std.math.isFinite(uv[0]) or !std.math.isFinite(uv[1])) return error.NonFiniteMesh;
        for (self.positions) |p| for (p) |v| {
            if (@abs(v) > 1e12) return error.MeshRange;
        };
        for (self.uvs) |uv| for (uv) |v| {
            if (@abs(v) > 1e6) return error.MeshRange;
        };
        if (self.tangents.len != 0 and self.tangents.len != self.positions.len) return error.InvalidMesh;
        for (self.tangents) |t| for (t) |v| {
            if (!std.math.isFinite(v)) return error.NonFiniteMesh;
        };
        for (self.indices) |i| if (i >= self.positions.len) return error.InvalidIndex;
    }
    pub fn triangle(self: Mesh, i: usize) [3]V3 {
        return .{ self.positions[self.indices[i * 3]], self.positions[self.indices[i * 3 + 1]], self.positions[self.indices[i * 3 + 2]] };
    }
};
/// UV-derived orthonormal tangents, with corner-angle weighting and handedness.
pub fn computeTangents(a: std.mem.Allocator, mesh: Mesh) ![]m.V4 {
    try mesh.validate();
    const result = try a.alloc(m.V4, mesh.positions.len);
    errdefer a.free(result);
    @memset(result, .{ 0, 0, 0, 1 });
    const bitangents = try a.alloc(V3, mesh.positions.len);
    defer a.free(bitangents);
    @memset(bitangents, .{ 0, 0, 0 });
    for (0..mesh.indices.len / 3) |ti| {
        const ids = mesh.indices[ti * 3 ..][0..3];
        const p = mesh.triangle(ti);
        const a0 = mesh.uvs[ids[0]];
        const a1 = mesh.uvs[ids[1]];
        const a2 = mesh.uvs[ids[2]];
        const du1 = a1[0] - a0[0];
        const dv1 = a1[1] - a0[1];
        const du2 = a2[0] - a0[0];
        const dv2 = a2[1] - a0[1];
        const det = du1 * dv2 - du2 * dv1;
        if (@abs(det) < 1e-20) continue;
        const e1 = m.sub(p[1], p[0]);
        const e2 = m.sub(p[2], p[0]);
        const t = m.norm(m.scale(m.sub(m.scale(e1, dv2), m.scale(e2, dv1)), 1 / det));
        const b = m.norm(m.scale(m.sub(m.scale(e2, du1), m.scale(e1, du2)), 1 / det));
        for (ids, 0..) |id, k| {
            const left = m.norm(m.sub(p[(k + 1) % 3], p[k]));
            const right = m.norm(m.sub(p[(k + 2) % 3], p[k]));
            const angle = std.math.acos(std.math.clamp(m.dot(left, right), -1, 1));
            for (0..3) |c| {
                result[id][c] += t[c] * angle;
                bitangents[id][c] += b[c] * angle;
            }
        }
    }
    for (result, mesh.normals, bitangents) |*t, n0, b| {
        const n = m.norm(n0);
        const sum: V3 = t[0..3].*;
        const tangent = m.norm(m.sub(sum, m.scale(n, m.dot(n, sum))));
        t.* = .{ tangent[0], tangent[1], tangent[2], if (m.dot(m.cross(n, tangent), b) < 0) -1 else 1 };
    }
    return result;
}
pub const Bounds = struct {
    lo: V3 = .{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) },
    hi: V3 = .{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) },
    pub fn grow(self: *Bounds, p: V3) void {
        for (0..3) |k| {
            self.lo[k] = @min(self.lo[k], p[k]);
            self.hi[k] = @max(self.hi[k], p[k]);
        }
    }
    pub fn hit(self: Bounds, ray: m.Ray, limit: f32) bool {
        var near: f32 = 0;
        var far = limit;
        for (0..3) |k| {
            if (@abs(ray.dir[k]) < 1e-20) {
                if (ray.origin[k] < self.lo[k] or ray.origin[k] > self.hi[k]) return false;
                continue;
            }
            const a = (self.lo[k] - ray.origin[k]) / ray.dir[k];
            const b = (self.hi[k] - ray.origin[k]) / ray.dir[k];
            near = @max(near, @min(a, b));
            far = @min(far, @max(a, b));
            if (near > far) return false;
        }
        return true;
    }
};
pub const Node = struct { bounds: Bounds, first: u32, count: u32 };
pub const Hit = struct { distance: f32, triangle: u32, bary: V3 };
pub const Bvh = struct {
    allocator: std.mem.Allocator,
    nodes: []Node,
    order: []u32,
    pub fn init(a: std.mem.Allocator, mesh: Mesh) !Bvh {
        try mesh.validate();
        const count = mesh.indices.len / 3;
        const nodes = try a.alloc(Node, count * 2);
        errdefer a.free(nodes);
        const order = try a.alloc(u32, count);
        errdefer a.free(order);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        var self: Bvh = .{ .allocator = a, .nodes = nodes, .order = order };
        var used: usize = 1;
        const centers = try a.alloc(V3, count);
        defer a.free(centers);
        const bounds = try a.alloc(Bounds, count);
        defer a.free(bounds);
        for (centers, bounds, 0..) |*center, *bound, i| {
            const t = mesh.triangle(i);
            center.* = m.scale(m.add(m.add(t[0], t[1]), t[2]), 1.0 / 3.0);
            bound.* = .{};
            for (t) |v| bound.grow(v);
        }
        self.build(centers, bounds, 0, 0, count, &used, 0);
        return self;
    }
    fn area(bounds: Bounds) f32 {
        const d = m.sub(bounds.hi, bounds.lo);
        return @max(d[0], 0) * @max(d[1], 0) + @max(d[1], 0) * @max(d[2], 0) + @max(d[2], 0) * @max(d[0], 0);
    }
    fn binOf(center: V3, lo: V3, extent: V3, axis: usize) usize {
        return @intFromFloat(std.math.clamp((center[axis] - lo[axis]) / extent[axis] * 12, 0, 11));
    }
    fn build(self: *Bvh, centers: []const V3, bounds: []const Bounds, ni: usize, start: usize, count: usize, used: *usize, depth: u32) void {
        var b: Bounds = .{};
        var cb: Bounds = .{};
        for (self.order[start..][0..count]) |o| {
            b.grow(bounds[o].lo);
            b.grow(bounds[o].hi);
            cb.grow(centers[o]);
        }
        self.nodes[ni] = .{ .bounds = b, .first = @intCast(start), .count = @intCast(count) };
        if (count <= 4 or depth >= 48) return;
        const ext = m.sub(cb.hi, cb.lo);
        const Bin = struct { bounds: Bounds = .{}, count: u32 = 0 };
        var bins: [3][12]Bin = @splat(@splat(.{}));
        for (self.order[start..][0..count]) |o| for (0..3) |axis| {
            if (ext[axis] <= 1e-12) continue;
            const bin = &bins[axis][binOf(centers[o], cb.lo, ext, axis)];
            bin.count += 1;
            bin.bounds.grow(bounds[o].lo);
            bin.bounds.grow(bounds[o].hi);
        };
        var best_axis: usize = 0;
        var best_split: usize = 0;
        var best_cost: f32 = std.math.inf(f32);
        for (0..3) |axis| {
            if (ext[axis] <= 1e-12) continue;
            var suffix = bins[axis];
            var j: usize = 11;
            while (j > 0) {
                j -= 1;
                suffix[j].count += suffix[j + 1].count;
                if (suffix[j + 1].count > 0) {
                    suffix[j].bounds.grow(suffix[j + 1].bounds.lo);
                    suffix[j].bounds.grow(suffix[j + 1].bounds.hi);
                }
            }
            var left: Bin = .{};
            for (1..12) |split| {
                const bin = bins[axis][split - 1];
                left.count += bin.count;
                if (bin.count > 0) {
                    left.bounds.grow(bin.bounds.lo);
                    left.bounds.grow(bin.bounds.hi);
                }
                const right = suffix[split];
                if (left.count == 0 or right.count == 0) continue;
                const cost = @as(f32, @floatFromInt(left.count)) * area(left.bounds) + @as(f32, @floatFromInt(right.count)) * area(right.bounds);
                if (cost < best_cost) {
                    best_cost = cost;
                    best_axis = axis;
                    best_split = split;
                }
            }
        }
        const order = self.order[start..][0..count];
        var half: usize = 0;
        if (best_split > 0 and best_cost < @as(f32, @floatFromInt(count)) * area(b)) {
            for (0..order.len) |i| {
                if (binOf(centers[order[i]], cb.lo, ext, best_axis) < best_split) {
                    std.mem.swap(u32, &order[half], &order[i]);
                    half += 1;
                }
            }
        }
        if (half == 0 or half == count) {
            var axis: usize = 0;
            if (ext[1] > ext[axis]) axis = 1;
            if (ext[2] > ext[axis]) axis = 2;
            const C = struct {
                centers: []const V3,
                axis: usize,
                fn less(c: @This(), x: u32, y: u32) bool {
                    return c.centers[x][c.axis] < c.centers[y][c.axis];
                }
            };
            std.mem.sort(u32, order, C{ .centers = centers, .axis = axis }, C.less);
            half = count / 2;
        }
        const left = used.*;
        used.* += 2;
        self.nodes[ni].first = @intCast(left);
        self.nodes[ni].count = 0;
        self.build(centers, bounds, left, start, half, used, depth + 1);
        self.build(centers, bounds, left + 1, start + half, count - half, used, depth + 1);
    }
    pub fn deinit(self: *Bvh) void {
        self.allocator.free(self.nodes);
        self.allocator.free(self.order);
        self.* = undefined;
    }
    pub fn query(self: Bvh, mesh: Mesh, bounds: Bounds, out: *std.ArrayList(u32), a: std.mem.Allocator) !void {
        _ = mesh;
        var stack: [64]u32 = undefined;
        stack[0] = 0;
        var sp: usize = 1;
        while (sp > 0) {
            sp -= 1;
            const n = self.nodes[stack[sp]];
            var overlap = true;
            for (0..3) |k| {
                if (n.bounds.hi[k] < bounds.lo[k] or n.bounds.lo[k] > bounds.hi[k]) overlap = false;
            }
            if (!overlap) continue;
            if (n.count > 0) {
                try out.appendSlice(a, self.order[n.first..][0..n.count]);
            } else {
                if (sp + 2 > stack.len) return error.BvhDepth;
                stack[sp] = n.first;
                stack[sp + 1] = n.first + 1;
                sp += 2;
            }
        }
    }
    pub fn refit(self: *Bvh, mesh: Mesh) !void {
        try mesh.validate();
        if (mesh.indices.len / 3 != self.order.len) return error.TopologyChanged;
        self.refitNode(mesh, 0);
    }
    fn refitNode(self: *Bvh, mesh: Mesh, i: usize) void {
        var b: Bounds = .{};
        const n = self.nodes[i];
        if (n.count > 0) {
            for (self.order[n.first..][0..n.count]) |o| for (mesh.triangle(o)) |p| b.grow(p);
        } else {
            self.refitNode(mesh, n.first);
            self.refitNode(mesh, n.first + 1);
            for ([_]u32{ n.first, n.first + 1 }) |c| {
                b.grow(self.nodes[c].bounds.lo);
                b.grow(self.nodes[c].bounds.hi);
            }
        }
        self.nodes[i].bounds = b;
    }
    pub fn cast(self: Bvh, mesh: Mesh, ray: m.Ray, max_distance: f32) ?Hit {
        var stack: [64]u32 = undefined;
        stack[0] = 0;
        var sp: usize = 1;
        var limit = max_distance;
        var result: ?Hit = null;
        while (sp > 0) {
            sp -= 1;
            const n = self.nodes[stack[sp]];
            if (!n.bounds.hit(ray, limit)) continue;
            if (n.count == 0) {
                if (sp + 2 > stack.len) return result;
                stack[sp] = n.first;
                stack[sp + 1] = n.first + 1;
                sp += 2;
            } else {
                for (self.order[n.first..][0..n.count]) |o| {
                    if (hitTriangle(mesh.triangle(o), ray, limit)) |h| {
                        limit = h.distance;
                        result = .{ .distance = h.distance, .triangle = o, .bary = h.bary };
                    }
                }
            }
        }
        return result;
    }
};
pub fn hitTriangle(t: [3]V3, r: m.Ray, limit: f32) ?Hit {
    const e1 = m.sub(t[1], t[0]);
    const e2 = m.sub(t[2], t[0]);
    const p = m.cross(r.dir, e2);
    const det = m.dot(e1, p);
    if (@abs(det) < 1e-12) return null;
    const s = m.sub(r.origin, t[0]);
    const u = m.dot(s, p) / det;
    if (u < -1e-5 or u > 1.00001) return null;
    const q = m.cross(s, e1);
    const v = m.dot(r.dir, q) / det;
    if (v < -1e-5 or u + v > 1.00001) return null;
    const distance = m.dot(e2, q) / det;
    if (distance <= 0 or distance >= limit) return null;
    return .{ .distance = distance, .triangle = 0, .bary = .{ 1 - u - v, u, v } };
}
pub const Texel = struct { triangle: u32 = std.math.maxInt(u32), bary: V3 = .{ 0, 0, 0 } };
pub const UvBuffer = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    texels: []Texel,
    pub fn init(a: std.mem.Allocator, mesh: Mesh, width: u32, height: u32, material: ?u32) !UvBuffer {
        try mesh.validate();
        if (width == 0 or height == 0 or width > 8192 or height > 8192 or @as(u64, width) * height > 16_777_216) return error.ImageBudget;
        const texels = try a.alloc(Texel, @as(usize, width) * height);
        @memset(texels, .{});
        const wf: @TypeOf(@as(f32, 0)) = @floatFromInt(width);
        const hf: f32 = @floatFromInt(height);
        for (0..mesh.indices.len / 3) |ti| {
            if (material) |mat| {
                if (mesh.materials.len > 0 and mesh.materials[ti] != mat) continue;
            }
            const ids = mesh.indices[ti * 3 ..][0..3];
            var uv: [3]V2 = undefined;
            for (ids, 0..) |id, k| uv[k] = .{ mesh.uvs[id][0] * wf, mesh.uvs[id][1] * hf };
            const lo: V2 = .{ @min(uv[0][0], @min(uv[1][0], uv[2][0])), @min(uv[0][1], @min(uv[1][1], uv[2][1])) };
            const hi: V2 = .{ @max(uv[0][0], @max(uv[1][0], uv[2][0])), @max(uv[0][1], @max(uv[1][1], uv[2][1])) };
            const x0: u32 = @intFromFloat(std.math.clamp(@floor(lo[0]), 0, wf));
            const y0: u32 = @intFromFloat(std.math.clamp(@floor(lo[1]), 0, hf));
            const x1: u32 = @intFromFloat(std.math.clamp(@ceil(hi[0]), 0, wf));
            const y1: u32 = @intFromFloat(std.math.clamp(@ceil(hi[1]), 0, hf));
            const d = (uv[1][1] - uv[2][1]) * (uv[0][0] - uv[2][0]) + (uv[2][0] - uv[1][0]) * (uv[0][1] - uv[2][1]);
            if (@abs(d) < 1e-12) continue;
            for (y0..y1) |y| for (x0..x1) |x| {
                const px = @as(f32, @floatFromInt(x)) + 0.5;
                const py = @as(f32, @floatFromInt(y)) + 0.5;
                const u = ((uv[1][1] - uv[2][1]) * (px - uv[2][0]) + (uv[2][0] - uv[1][0]) * (py - uv[2][1])) / d;
                const v = ((uv[2][1] - uv[0][1]) * (px - uv[2][0]) + (uv[0][0] - uv[2][0]) * (py - uv[2][1])) / d;
                const w = 1 - u - v;
                if (u >= -1e-6 and v >= -1e-6 and w >= -1e-6) texels[y * width + x] = .{ .triangle = @intCast(ti), .bary = .{ u, v, w } };
            };
        }
        return .{ .allocator = a, .width = width, .height = height, .texels = texels };
    }
    pub fn deinit(self: *UvBuffer) void {
        self.allocator.free(self.texels);
        self.* = undefined;
    }
    pub fn position(mesh: Mesh, t: Texel) V3 {
        const tri = mesh.triangle(t.triangle);
        return m.add(m.add(m.scale(tri[0], t.bary[0]), m.scale(tri[1], t.bary[1])), m.scale(tri[2], t.bary[2]));
    }
    pub fn normal(mesh: Mesh, t: Texel) V3 {
        const ids = mesh.indices[t.triangle * 3 ..][0..3];
        return m.norm(m.add(m.add(m.scale(mesh.normals[ids[0]], t.bary[0]), m.scale(mesh.normals[ids[1]], t.bary[1])), m.scale(mesh.normals[ids[2]], t.bary[2])));
    }
};
test "BVH picking and refit" {
    const a = std.testing.allocator;
    var p = [_]V3{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 } };
    const mesh: Mesh = .{ .positions = &p, .normals = &.{ .{ 0, 0, 1 }, .{ 0, 0, 1 }, .{ 0, 0, 1 } }, .uvs = &.{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 } }, .indices = &.{ 0, 1, 2 } };
    var b = try Bvh.init(a, mesh);
    defer b.deinit();
    try std.testing.expect(b.cast(mesh, .{ .origin = .{ 0.2, 0.2, 1 }, .dir = .{ 0, 0, -1 } }, 10) != null);
    p[0][2] = 2;
    p[1][2] = 2;
    p[2][2] = 2;
    try b.refit(mesh);
    try std.testing.expect(b.cast(mesh, .{ .origin = .{ 0.2, 0.2, 1 }, .dir = .{ 0, 0, -1 } }, 10) == null);
}
