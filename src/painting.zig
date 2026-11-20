//! Editor-independent material authoring with atomic strokes and COW history.
const std = @import("std");
const m = @import("math.zig");
const tex = @import("texel.zig");
const blend = @import("blend.zig");
const g = @import("geometry.zig");
pub const Channel = enum {
    base_color,
    roughness,
    metallic,
    normal,
    height,
    opacity,
    ambient_occlusion,
    emissive,
    specular_level,
    glossiness,
    specular,
    coat_weight,
    coat_roughness,
    anisotropy_level,
    anisotropy_angle,
    sheen_color,
    sheen_weight,
    sheen_roughness,
    coat_normal,
    scatter_weight,
    transmission,
    pub fn components(self: Channel) u8 {
        return switch (self) {
            .base_color, .normal, .emissive, .specular, .sheen_color, .coat_normal => 3,
            else => 1,
        };
    }
    pub fn defaults(self: Channel) m.V3 {
        return switch (self) {
            .base_color, .roughness, .specular_level, .glossiness, .sheen_roughness => .{ 0.5, 0.5, 0.5 },
            .normal, .coat_normal => .{ 0.5, 0.5, 1 },
            .opacity, .ambient_occlusion, .sheen_color => .{ 1, 1, 1 },
            .coat_roughness => .{ 0.1, 0.1, 0.1 },
            .specular => .{ 0.04, 0.04, 0.04 },
            else => .{ 0, 0, 0 },
        };
    }
};
pub const channel_count = @typeInfo(Channel).@"enum".fields.len;
pub const Pattern = enum { uniform, checker, noise, stripes };
pub const Layer = struct {
    name: [64]u8 = @splat(0),
    kind: enum { paint, fill } = .paint,
    visible: bool = true,
    opacity: f32 = 1,
    pattern: Pattern = .uniform,
    scale: f32 = 8,
    seed: u32 = 0,
    modes: [channel_count]blend.Mode = @splat(.normal),
    enabled: u32 = 0,
    values: [channel_count]m.V3 = defaultValues(),
    pixels: [channel_count]?tex.Image = @splat(null),
    mask: ?tex.Image = null,
    pub fn deinit(self: *Layer) void {
        for (&self.pixels) |*img| if (img.*) |*image| image.deinit();
        if (self.mask) |*image| image.deinit();
        self.* = undefined;
    }
    pub fn clone(self: Layer) Layer {
        var result = self;
        for (&result.pixels) |*img| {
            if (img.*) |*image| {
                image.* = image.clone();
            }
        }
        if (result.mask) |*image| image.* = image.clone();
        return result;
    }
    pub fn setValue(self: *Layer, ch: Channel, v: m.V3) !void {
        if (!m.finite(v)) return error.InvalidValue;
        self.values[@intFromEnum(ch)] = v;
        self.enabled |= @as(u32, 1) << @intCast(@intFromEnum(ch));
    }
};
fn defaultValues() [channel_count]m.V3 {
    var values: [channel_count]m.V3 = undefined;
    for (&values, 0..) |*v, i| v.* = @as(Channel, @enumFromInt(i)).defaults();
    return values;
}
pub const Document = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    layers: std.ArrayList(Layer) = .empty,
    pub fn init(a: std.mem.Allocator, w: u32, h: u32) !Document {
        if (w == 0 or h == 0 or w > 8192 or h > 8192) return error.ImageBudget;
        return .{ .allocator = a, .width = w, .height = h };
    }
    pub fn deinit(self: *Document) void {
        for (self.layers.items) |*layer| layer.deinit();
        self.layers.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn clone(self: Document) !Document {
        const list = try self.allocator.dupe(Layer, self.layers.items);
        for (list) |*layer| layer.* = layer.clone();
        return .{ .allocator = self.allocator, .width = self.width, .height = self.height, .layers = .fromOwnedSlice(list) };
    }
    pub fn pixel(self: Document, ch: Channel, x: u32, y: u32) m.V3 {
        var value = ch.defaults();
        const index = @intFromEnum(ch);
        for (self.layers.items) |layer| {
            if (!layer.visible or layer.opacity <= 0 or layer.enabled & (@as(u32, 1) << @intCast(index)) == 0) continue;
            var source = layer.values[index];
            var coverage: f32 = 1;
            if (layer.kind == .paint) {
                const image = layer.pixels[index] orelse continue;
                const p = image.get(x, y);
                const comps = ch.components();
                coverage = @as(f32, @floatFromInt(p[comps])) / 65535;
                if (coverage <= 0) continue;
                for (0..comps) |k| {
                    const v = @as(f32, @floatFromInt(p[k])) / 65535;
                    source[k] = (if (ch == .height) v * 2 - 1 else v) / coverage;
                }
                if (comps == 1) source = @splat(source[0]);
            } else {
                const u = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(self.width));
                const v = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(self.height));
                const factor: f32 = switch (layer.pattern) {
                    .uniform => 1,
                    .checker => if (@mod(@as(i32, @intFromFloat(@floor(u * layer.scale))) + @as(i32, @intFromFloat(@floor(v * layer.scale))), 2) == 0) 1 else 0.25,
                    .noise => noise(x, y, layer.seed),
                    .stripes => 0.5 + 0.5 * @sin(u * layer.scale * std.math.tau),
                };
                source = m.scale(source, factor);
            }
            const mask = if (layer.mask) |mask_image| @as(f32, @floatFromInt(mask_image.get(x, y)[0])) / 65535 else 1;
            value = m.mix(value, blend.rgb(layer.modes[index], value, source), std.math.clamp(coverage * layer.opacity * mask, 0, 1));
        }
        return value;
    }
    pub fn region(self: Document, ch: Channel, x: u32, y: u32, w: u32, h: u32, out: [][4]u16) !void {
        if (x > self.width or y > self.height or w > self.width - x or h > self.height - y or out.len != @as(u64, w) * h) return error.InvalidRegion;
        for (0..h) |dy| for (0..w) |dx| {
            const v = self.pixel(ch, x + @as(u32, @intCast(dx)), y + @as(u32, @intCast(dy)));
            out[dy * w + dx] = .{ m.u16of(v[0]), m.u16of(v[1]), m.u16of(v[2]), m.u16of(self.pixel(.opacity, x + @as(u32, @intCast(dx)), y + @as(u32, @intCast(dy)))[0]) };
        };
    }
};
pub const Alpha = enum { round, square, star, grunge };
pub const Brush = struct {
    radius: f32 = 0.05,
    hardness: f32 = 0.8,
    flow: f32 = 1,
    spacing: f32 = 0.15,
    angle: f32 = 0,
    depth: f32 = 1,
    alpha: Alpha = .round,
    seed: u32 = 0,
    mirror_x: bool = false,
    pub fn validate(self: Brush) !void {
        if (!std.math.isFinite(self.radius) or self.radius <= 0 or self.radius > 1e6 or !std.math.isFinite(self.hardness) or self.hardness < 0 or self.hardness > 1 or !std.math.isFinite(self.flow) or self.flow < 0 or self.flow > 1 or !std.math.isFinite(self.spacing) or self.spacing < 0.001 or self.spacing > 10 or !std.math.isFinite(self.angle) or !std.math.isFinite(self.depth) or self.depth <= 0 or self.depth > 100) return error.InvalidBrush;
    }
    pub fn sample(self: Brush, x: f32, y: f32) f32 {
        const co = @cos(self.angle);
        const si = @sin(self.angle);
        const u = x * co - y * si;
        const v = x * si + y * co;
        const r = switch (self.alpha) {
            .square => @max(@abs(u), @abs(v)),
            .star => @sqrt(u * u + v * v) / (0.72 + 0.28 * @cos(5 * std.math.atan2(v, u))),
            else => @sqrt(u * u + v * v),
        };
        if (r >= 1) return 0;
        const t = std.math.clamp((r - self.hardness) / @max(1 - self.hardness, 1e-6), 0, 1);
        const shape = 1 - t * t * (3 - 2 * t);
        return shape * self.flow * (if (self.alpha == .grunge) noise(@intFromFloat((u + 1) * 2048), @intFromFloat((v + 1) * 2048), self.seed) else @as(f32, 1));
    }
};
const Stroke = struct { layer: usize, channel: Channel, value: m.V3, opacity: f32, erase: bool, alpha: tex.Image };
pub const Session = struct {
    allocator: std.mem.Allocator,
    document: Document,
    undo_stack: std.ArrayList(Document) = .empty,
    redo_stack: std.ArrayList(Document) = .empty,
    active: ?Stroke = null,
    dirty: []bool,
    max_history: usize = 64,
    history_budget: usize = 256 * 1024 * 1024,
    pub fn init(a: std.mem.Allocator, w: u32, h: u32) !Session {
        var d = try Document.init(a, w, h);
        errdefer d.deinit();
        const dirty = try a.alloc(bool, @as(usize, (w + 63) / 64) * ((h + 63) / 64));
        @memset(dirty, true);
        return .{ .allocator = a, .document = d, .dirty = dirty };
    }
    pub fn deinit(self: *Session) void {
        self.cancel();
        self.document.deinit();
        for (self.undo_stack.items) |*d| d.deinit();
        for (self.redo_stack.items) |*d| d.deinit();
        self.undo_stack.deinit(self.allocator);
        self.redo_stack.deinit(self.allocator);
        self.allocator.free(self.dirty);
        self.* = undefined;
    }
    pub fn addLayer(self: *Session, name: []const u8, kind: enum { paint, fill }) !usize {
        if (self.active != null or name.len > 63 or self.document.layers.items.len >= 256) return error.InvalidLayer;
        var layer: Layer = .{ .kind = if (kind == .fill) .fill else .paint };
        @memcpy(layer.name[0..name.len], name);
        try self.document.layers.append(self.allocator, layer);
        @memset(self.dirty, true);
        return self.document.layers.items.len - 1;
    }
    pub fn begin(self: *Session, layer: usize, ch: Channel, value: m.V3, opacity: f32, erase: bool) !void {
        if (self.active != null or layer >= self.document.layers.items.len or self.document.layers.items[layer].kind != .paint or !m.finite(value) or !std.math.isFinite(opacity) or opacity < 0 or opacity > 1) return error.InvalidStroke;
        const alpha = try tex.Image.init(self.allocator, self.document.width, self.document.height, 1);
        self.active = .{ .layer = layer, .channel = ch, .value = value, .opacity = opacity, .erase = erase, .alpha = alpha };
    }
    pub fn cancel(self: *Session) void {
        if (self.active) |*stroke| stroke.alpha.deinit();
        self.active = null;
    }
    fn deposit(stroke: *Stroke, x: u32, y: u32, a: f32) !void {
        if (a <= 0) return;
        const old = @as(f32, @floatFromInt(stroke.alpha.get(x, y)[0])) / 65535;
        try stroke.alpha.set(x, y, .{ m.u16of(a + old * (1 - a)), 0, 0, 0 });
    }
    pub fn stampUv(self: *Session, uv: m.V2, brush: Brush, pressure: f32) !void {
        try brush.validate();
        if (!std.math.isFinite(uv[0]) or !std.math.isFinite(uv[1]) or !std.math.isFinite(pressure) or pressure < 0 or pressure > 1) return error.InvalidSample;
        const stroke = if (self.active) |*s| s else return error.NoStroke;
        const wf: @TypeOf(@as(f32, 0)) = @floatFromInt(self.document.width);
        const hf: f32 = @floatFromInt(self.document.height);
        const r = brush.radius * wf * pressure;
        if (r < 0.001) return;
        const cx = uv[0] * wf;
        const cy = uv[1] * hf;
        const x0: u32 = @intFromFloat(std.math.clamp(@floor(cx - r * 1.5), 0, wf));
        const y0: u32 = @intFromFloat(std.math.clamp(@floor(cy - r * 1.5), 0, hf));
        const x1: u32 = @intFromFloat(std.math.clamp(@ceil(cx + r * 1.5), 0, wf));
        const y1: u32 = @intFromFloat(std.math.clamp(@ceil(cy + r * 1.5), 0, hf));
        for (y0..y1) |y| for (x0..x1) |x| {
            try deposit(stroke, @intCast(x), @intCast(y), brush.sample((@as(f32, @floatFromInt(x)) + 0.5 - cx) / r, (@as(f32, @floatFromInt(y)) + 0.5 - cy) / r));
        };
    }
    pub fn strokeUv(self: *Session, points: []const m.V2, brush: Brush) !void {
        try brush.validate();
        if (points.len == 0 or points.len > 100000) return error.StrokeBudget;
        try self.stampUv(points[0], brush, 1);
        var remaining: f32 = brush.radius * 2 * brush.spacing;
        for (points[1..], points[0 .. points.len - 1]) |end, start| {
            const dx = end[0] - start[0];
            const dy = end[1] - start[1];
            const length = @sqrt(dx * dx + dy * dy);
            if (!std.math.isFinite(length)) return error.InvalidSample;
            var d = remaining;
            var count: usize = 0;
            while (d <= length) : (d += brush.radius * 2 * brush.spacing) {
                if (count > 100000) return error.StrokeBudget;
                try self.stampUv(.{ start[0] + dx * d / length, start[1] + dy * d / length }, brush, 1);
                count += 1;
            }
            remaining = d - length;
        }
    }
    pub fn stampWorld(self: *Session, mesh: g.Mesh, bvh: *const g.Bvh, uvbuf: g.UvBuffer, center: m.V3, normal: m.V3, brush: Brush, eye: ?m.V3) !void {
        try brush.validate();
        if (!m.finite(center) or !m.finite(normal) or uvbuf.width != self.document.width or uvbuf.height != self.document.height) return error.InvalidSample;
        const stroke = if (self.active) |*s| s else return error.NoStroke;
        const n = m.norm(normal);
        const t = m.norm(m.cross(if (@abs(n[1]) < 0.9) m.V3{ 0, 1, 0 } else m.V3{ 1, 0, 0 }, n));
        const bitangent = m.cross(n, t);
        var query: std.ArrayList(u32) = .empty;
        defer query.deinit(self.allocator);
        try bvh.query(mesh, .{ .lo = m.sub(center, @splat(brush.radius * brush.depth * 1.5)), .hi = m.add(center, @splat(brush.radius * brush.depth * 1.5)) }, &query, self.allocator);
        const wf: f32 = @floatFromInt(uvbuf.width);
        const hf: f32 = @floatFromInt(uvbuf.height);
        for (query.items) |ti| {
            const ids = mesh.indices[ti * 3 ..][0..3];
            var lo: m.V2 = .{ wf, hf };
            var hi: m.V2 = .{ 0, 0 };
            for (ids) |id| {
                lo[0] = @min(lo[0], mesh.uvs[id][0] * wf);
                lo[1] = @min(lo[1], mesh.uvs[id][1] * hf);
                hi[0] = @max(hi[0], mesh.uvs[id][0] * wf);
                hi[1] = @max(hi[1], mesh.uvs[id][1] * hf);
            }
            const x0: u32 = @intFromFloat(std.math.clamp(@floor(lo[0]), 0, wf));
            const y0: u32 = @intFromFloat(std.math.clamp(@floor(lo[1]), 0, hf));
            const x1: u32 = @intFromFloat(std.math.clamp(@ceil(hi[0]), 0, wf));
            const y1: u32 = @intFromFloat(std.math.clamp(@ceil(hi[1]), 0, hf));
            for (y0..y1) |y| for (x0..x1) |x| {
                const texel = uvbuf.texels[y * uvbuf.width + x];
                if (texel.triangle != ti) continue;
                const p = g.UvBuffer.position(mesh, texel);
                const delta = m.sub(p, center);
                if (@abs(m.dot(delta, n)) > brush.radius * brush.depth) continue;
                const alpha = brush.sample(m.dot(delta, t) / brush.radius, m.dot(delta, bitangent) / brush.radius);
                if (alpha <= 0) continue;
                if (eye) |camera_eye| {
                    const to_eye = m.sub(camera_eye, p);
                    const dist = m.length(to_eye);
                    if (dist <= 1e-6) continue;
                    const dir = m.scale(to_eye, 1 / dist);
                    if (m.dot(g.UvBuffer.normal(mesh, texel), dir) <= 0) continue;
                    if (bvh.cast(mesh, .{ .origin = m.add(p, m.scale(dir, 1e-5)), .dir = dir }, dist - 1e-5) != null) continue;
                }
                try deposit(stroke, @intCast(x), @intCast(y), alpha);
            };
        }
        if (brush.mirror_x) {
            var mirrored = brush;
            mirrored.mirror_x = false;
            try self.stampWorld(mesh, bvh, uvbuf, .{ -center[0], center[1], center[2] }, .{ -normal[0], normal[1], normal[2] }, mirrored, eye);
        }
    }
    pub fn commit(self: *Session) !void {
        const stroke = self.active orelse return error.NoStroke;
        var next = try self.document.clone();
        errdefer next.deinit();
        const ch = stroke.channel;
        const ci = @intFromEnum(ch);
        const count = ch.components();
        const layer = &next.layers.items[stroke.layer];
        if (layer.pixels[ci] == null) {
            const image_new = try tex.Image.init(self.allocator, next.width, next.height, count + 1);
            layer.pixels[ci] = image_new;
        }
        const image = &layer.pixels[ci].?;
        for (0..stroke.alpha.tiles_y) |ty| for (0..stroke.alpha.tiles_x) |tx| {
            const alpha = stroke.alpha.tile(@intCast(tx), @intCast(ty)) orelse continue;
            const empty: [4]u16 = if (ch == .height) .{ 32768, 0, 0, 0 } else .{ 0, 0, 0, 0 };
            const tile = try image.tileMut(@intCast(tx), @intCast(ty), empty);
            for (0..4096) |i| {
                const weight = @as(f32, @floatFromInt(alpha[i])) / 65535 * stroke.opacity;
                if (weight <= 0) continue;
                const offset = i * (count + 1);
                const cov = @as(f32, @floatFromInt(tile[offset + count])) / 65535;
                for (0..count) |k| {
                    const p = @as(f32, @floatFromInt(tile[offset + k])) / 65535;
                    const old = if (ch == .height) p * 2 - 1 else p;
                    const value = if (stroke.erase) old * (1 - weight) else stroke.value[k] * weight + old * (1 - weight);
                    tile[offset + k] = m.u16of(if (ch == .height) value * 0.5 + 0.5 else value);
                }
                tile[offset + count] = m.u16of(if (stroke.erase) cov * (1 - weight) else weight + cov * (1 - weight));
            }
        };
        layer.enabled |= @as(u32, 1) << @intCast(ci);
        try self.undo_stack.ensureUnusedCapacity(self.allocator, 1);
        for (self.redo_stack.items) |*d| d.deinit();
        self.redo_stack.clearRetainingCapacity();
        self.undo_stack.appendAssumeCapacity(self.document);
        self.document = next;
        for (0..stroke.alpha.tiles_y) |ty| for (0..stroke.alpha.tiles_x) |tx| {
            if (stroke.alpha.tile(@intCast(tx), @intCast(ty)) != null) self.dirty[ty * stroke.alpha.tiles_x + tx] = true;
        };
        while (self.undo_stack.items.len > self.max_history) {
            var old = self.undo_stack.orderedRemove(0);
            old.deinit();
        }
        self.cancel();
    }
    pub fn undo(self: *Session) !bool {
        if (self.active != null) return error.StrokeActive;
        if (self.undo_stack.items.len == 0) return false;
        try self.redo_stack.ensureUnusedCapacity(self.allocator, 1);
        self.redo_stack.appendAssumeCapacity(self.document);
        self.document = self.undo_stack.pop().?;
        @memset(self.dirty, true);
        return true;
    }
    pub fn redo(self: *Session) !bool {
        if (self.active != null) return error.StrokeActive;
        if (self.redo_stack.items.len == 0) return false;
        try self.undo_stack.ensureUnusedCapacity(self.allocator, 1);
        self.undo_stack.appendAssumeCapacity(self.document);
        self.document = self.redo_stack.pop().?;
        @memset(self.dirty, true);
        return true;
    }
    pub fn clearDirty(self: *Session) void {
        @memset(self.dirty, false);
    }
};
pub fn noise(x: u32, y: u32, seed: u32) f32 {
    var h = x *% 374761393 +% y *% 668265263 +% seed;
    h = (h ^ (h >> 13)) *% 1274126177;
    return @as(f32, @floatFromInt((h ^ (h >> 16)) >> 8)) / 16777216;
}
fn transactionFailure(a: std.mem.Allocator) !void {
    var session = try Session.init(a, 128, 128);
    defer session.deinit();
    const layer = try session.addLayer("makeup", .paint);
    try session.begin(layer, .base_color, .{ 1, 0, 0 }, 1, false);
    try session.stampUv(.{ 0.5, 0.5 }, .{ .radius = 0.15 }, 1);
    try session.commit();
    try std.testing.expect(session.document.pixel(.base_color, 64, 64)[0] > 0.9);
    try std.testing.expect(try session.undo());
    try std.testing.expectEqual(m.V3{ 0.5, 0.5, 0.5 }, session.document.pixel(.base_color, 64, 64));
    try std.testing.expect(try session.redo());
}
test "paint commit undo redo allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, transactionFailure, .{});
}
