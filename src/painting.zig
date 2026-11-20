//! Editor-independent material authoring with atomic strokes and COW history.
const std = @import("std");
const m = @import("math.zig");
const tex = @import("texel.zig");
const blend = @import("blend.zig");
const g = @import("geometry.zig");
const coherent = @import("noise.zig");
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
    defaults: [channel_count]m.V3 = defaultValues(),
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
        return .{ .allocator = self.allocator, .width = self.width, .height = self.height, .layers = .fromOwnedSlice(list), .defaults = self.defaults };
    }
    pub fn retainedBytes(self: Document) usize {
        var bytes: usize = self.layers.items.len * @sizeOf(Layer);
        for (self.layers.items) |layer| {
            for (layer.pixels) |slot| if (slot) |image| {
                bytes += image.allocated() * 4096 * image.components * 2 + image.table.slots.len * @sizeOf(?*anyopaque);
            };
            if (layer.mask) |image| bytes += image.allocated() * 4096 * image.components * 2 + image.table.slots.len * @sizeOf(?*anyopaque);
        }
        return bytes;
    }
    pub fn pixel(self: Document, ch: Channel, x: u32, y: u32) m.V3 {
        var value = self.defaults[@intFromEnum(ch)];
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
        if (w == 0 or h == 0) return;
        var values: [4096]m.V3 = undefined;
        var opacity: [4096]m.V3 = undefined;
        for (y / 64..(y + h - 1) / 64 + 1) |ty| for (x / 64..(x + w - 1) / 64 + 1) |tx| {
            const rect: [4]usize = .{ @max(x, tx * 64) - tx * 64, @max(y, ty * 64) - ty * 64, @min(x + w, (tx + 1) * 64) - tx * 64, @min(y + h, (ty + 1) * 64) - ty * 64 };
            self.composeTileRect(ch, @intCast(tx), @intCast(ty), &values, rect);
            if (ch == .opacity) opacity = values else self.composeTileRect(.opacity, @intCast(tx), @intCast(ty), &opacity, rect);
            for (@max(y, ty * 64)..@min(y + h, (ty + 1) * 64)) |py| for (@max(x, tx * 64)..@min(x + w, (tx + 1) * 64)) |px| {
                const at = (py % 64) * 64 + px % 64;
                const v = values[at];
                out[(py - y) * w + px - x] = .{ m.u16of(if (ch == .height) v[0] * 0.5 + 0.5 else v[0]), m.u16of(if (ch == .height) v[1] * 0.5 + 0.5 else v[1]), m.u16of(if (ch == .height) v[2] * 0.5 + 0.5 else v[2]), m.u16of(opacity[at][0]) };
            };
        };
    }
    /// Resolve layer metadata and COW tile pointers once per tile, then evaluate
    /// contiguous texels. The scalar pixel path remains an independent oracle.
    pub fn composeTile(self: Document, ch: Channel, tx: u32, ty: u32, out: *[4096]m.V3) void {
        self.composeTileRect(ch, tx, ty, out, .{ 0, 0, 64, 64 });
    }
    fn composeTileRect(self: Document, ch: Channel, tx: u32, ty: u32, out: *[4096]m.V3, rect: [4]usize) void {
        const ci = @intFromEnum(ch);
        const comps = ch.components();
        @memset(out, self.defaults[ci]);
        for (self.layers.items) |layer| {
            if (!layer.visible or layer.opacity <= 0 or layer.enabled & (@as(u32, 1) << @intCast(ci)) == 0) continue;
            const pixels = if (layer.kind == .paint) (layer.pixels[ci] orelse continue).tile(tx, ty) orelse continue else null;
            const mask = if (layer.mask) |image| image.tile(tx, ty) orelse continue else null;
            for (rect[1]..rect[3]) |py| for (rect[0]..rect[2]) |px| {
                const i = py * 64 + px;
                const value = &out[i];
                var source = layer.values[ci];
                var coverage: f32 = 1;
                if (pixels) |data| {
                    const at = i * (comps + @as(usize, 1));
                    coverage = @as(f32, @floatFromInt(data[at + comps])) / 65535;
                    if (coverage <= 0) continue;
                    for (0..comps) |k| {
                        const v = @as(f32, @floatFromInt(data[at + k])) / 65535;
                        source[k] = (if (ch == .height) v * 2 - 1 else v) / coverage;
                    }
                    if (comps == 1) source = @splat(source[0]);
                } else {
                    const x = tx * 64 + @as(u32, @intCast(i % 64));
                    const y = ty * 64 + @as(u32, @intCast(i / 64));
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
                const mask_value = if (mask) |data| @as(f32, @floatFromInt(data[i])) / 65535 else 1;
                const mode = layer.modes[ci];
                const mixed = if (mode == .normal or mode == .replace or mode == .passthrough) source else blend.rgb(mode, value.*, source);
                value.* = m.mix(value.*, mixed, std.math.clamp(coverage * layer.opacity * mask_value, 0, 1));
            };
        }
    }
};
pub const Alpha = enum { round, square, star, grunge, spray, cloud, streaks };
/// Borrowed grayscale stamp, sampled bilinearly with its original aspect ratio.
pub const ImageAlpha = struct {
    width: u32,
    height: u32,
    pixels: []const u16,
    pub fn sample(self: ImageAlpha, lx: f32, ly: f32) f32 {
        const aspect = @as(f32, @floatFromInt(self.width)) / @as(f32, @floatFromInt(self.height));
        const x = if (aspect < 1) lx / aspect else lx;
        const y = if (aspect >= 1) ly * aspect else ly;
        if (@abs(x) > 1 or @abs(y) > 1) return 0;
        const fx = (x * 0.5 + 0.5) * @as(f32, @floatFromInt(self.width - 1));
        const fy = (0.5 - y * 0.5) * @as(f32, @floatFromInt(self.height - 1));
        const x0: u32 = @intFromFloat(@floor(fx));
        const y0: u32 = @intFromFloat(@floor(fy));
        const x1 = @min(x0 + 1, self.width - 1);
        const y1 = @min(y0 + 1, self.height - 1);
        const tx = fx - @floor(fx);
        const ty = fy - @floor(fy);
        const a = @as(f32, @floatFromInt(self.pixels[y0 * self.width + x0]));
        const b = @as(f32, @floatFromInt(self.pixels[y0 * self.width + x1]));
        const c = @as(f32, @floatFromInt(self.pixels[y1 * self.width + x0]));
        const d = @as(f32, @floatFromInt(self.pixels[y1 * self.width + x1]));
        return ((a + (b - a) * tx) + ((c + (d - c) * tx) - (a + (b - a) * tx)) * ty) / 65535;
    }
};
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
    workers: u8 = 1,
    image: ?ImageAlpha = null,
    pub fn validate(self: Brush) !void {
        if (self.image) |image| if (image.width == 0 or image.height == 0 or image.width > 4096 or image.height > 4096 or image.pixels.len != @as(u64, image.width) * image.height) return error.InvalidBrushImage;
        if (!std.math.isFinite(self.radius) or self.radius <= 0 or self.radius > 1e6 or !std.math.isFinite(self.hardness) or self.hardness < 0 or self.hardness > 1 or !std.math.isFinite(self.flow) or self.flow < 0 or self.flow > 1 or !std.math.isFinite(self.spacing) or self.spacing < 0.001 or self.spacing > 10 or !std.math.isFinite(self.angle) or !std.math.isFinite(self.depth) or self.depth <= 0 or self.depth > 100) return error.InvalidBrush;
    }
    pub fn sample(self: Brush, x: f32, y: f32) f32 {
        const co = @cos(self.angle);
        const si = @sin(self.angle);
        const u = x * co - y * si;
        const v = x * si + y * co;
        if (self.image) |image| return image.sample(u, v) * self.flow;
        const r = switch (self.alpha) {
            .square => @max(@abs(u), @abs(v)),
            .star => blk: {
                const k = @abs(@cos(std.math.atan2(v, u) * 5 / 2));
                break :blk @sqrt(u * u + v * v) / (0.45 + 0.55 * k * k);
            },
            else => @sqrt(u * u + v * v),
        };
        if (r >= 1) return 0;
        const hardness = @min(self.hardness, 0.999);
        const t = std.math.clamp((r - hardness) / @max(1 - hardness, 1e-6), 0, 1);
        const shape = 1 - t * t * (3 - 2 * t);
        const seed: f32 = @floatFromInt(self.seed);
        const factor: f32 = switch (self.alpha) {
            .spray => if (coherent.value(.{ u * 14, v * 14, seed * 0.37 }, self.seed) > 0.72) 1 else 0,
            .grunge => std.math.clamp((coherent.fbm(.{ u * 2.5 + seed * 0.13, v * 2.5, 0.5 }, 5, self.seed, coherent.perlin) - 0.42) * 5, 0, 1),
            .cloud => coherent.fbm(.{ u * 1.8, v * 1.8, seed * 0.21 }, 4, self.seed, coherent.value),
            .streaks => std.math.clamp((coherent.value(.{ u * 0.8, v * 18, seed * 0.7 }, self.seed) - 0.35) * 3, 0, 1),
            else => 1,
        };
        return shape * self.flow * factor;
    }
};
const Stroke = struct { token: u64, layer: usize, channel: Channel, value: m.V3, opacity: f32, erase: bool, alpha: tex.Image, deposited: bool = false };
pub const Session = struct {
    allocator: std.mem.Allocator,
    document: Document,
    undo_stack: std.ArrayList(Document) = .empty,
    redo_stack: std.ArrayList(Document) = .empty,
    active: ?Stroke = null,
    dirty: []bool,
    max_history: usize = 64,
    history_budget: usize = 256 * 1024 * 1024,
    dirty_channels: u32 = 0,
    managed_channels: u32 = 0,
    revision: u64 = 0,
    gesture_sequence: u64 = 0,
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
        self.revision +%= 1;
        return self.document.layers.items.len - 1;
    }
    fn trimHistory(self: *Session) void {
        var bytes: usize = 0;
        for (self.undo_stack.items) |doc| bytes += doc.retainedBytes();
        while (self.undo_stack.items.len > 0 and (self.undo_stack.items.len > self.max_history or bytes > self.history_budget)) {
            var old = self.undo_stack.orderedRemove(0);
            bytes -= old.retainedBytes();
            old.deinit();
        }
    }
    fn adopt(self: *Session, next: Document) !void {
        try self.undo_stack.ensureUnusedCapacity(self.allocator, 1);
        for (self.redo_stack.items) |*doc| doc.deinit();
        self.redo_stack.clearRetainingCapacity();
        self.undo_stack.appendAssumeCapacity(self.document);
        self.document = next;
        self.revision +%= 1;
        for (next.layers.items) |layer| self.managed_channels |= layer.enabled;
        self.dirty_channels |= self.managed_channels;
        self.trimHistory();
        @memset(self.dirty, true);
    }
    pub fn setDefault(self: *Session, ch: Channel, value: m.V3) !void {
        if (self.active != null or !m.finite(value)) return error.InvalidValue;
        var next = try self.document.clone();
        errdefer next.deinit();
        next.defaults[@intFromEnum(ch)] = value;
        try self.adopt(next);
        self.managed_channels |= @as(u32, 1) << @intFromEnum(ch);
        self.dirty_channels |= @as(u32, 1) << @intFromEnum(ch);
    }
    pub fn setFill(self: *Session, index: usize, ch: Channel, value: m.V3, pattern: Pattern, scale: f32) !void {
        if (self.active != null or index >= self.document.layers.items.len or !std.math.isFinite(scale) or scale <= 0 or scale > 1e6) return error.InvalidLayer;
        var next = try self.document.clone();
        errdefer next.deinit();
        const layer = &next.layers.items[index];
        if (layer.kind != .fill) return error.InvalidLayer;
        try layer.setValue(ch, value);
        layer.pattern = pattern;
        layer.scale = scale;
        try self.adopt(next);
    }
    pub fn setLayerProperties(self: *Session, index: usize, opacity: f32, visible: bool, ch: Channel, mode: blend.Mode) !void {
        if (self.active != null or index >= self.document.layers.items.len or !std.math.isFinite(opacity) or opacity < 0 or opacity > 1) return error.InvalidLayer;
        var next = try self.document.clone();
        errdefer next.deinit();
        next.layers.items[index].opacity = opacity;
        next.layers.items[index].visible = visible;
        next.layers.items[index].modes[@intFromEnum(ch)] = mode;
        try self.adopt(next);
    }
    pub fn setMask(self: *Session, index: usize, mask: ?tex.Image) !void {
        if (self.active != null or index >= self.document.layers.items.len) return error.InvalidLayer;
        if (mask) |image| if (image.width != self.document.width or image.height != self.document.height or image.components != 1) return error.InvalidMask;
        var next = try self.document.clone();
        errdefer next.deinit();
        if (next.layers.items[index].mask) |*image| image.deinit();
        next.layers.items[index].mask = if (mask) |image| image.clone() else null;
        try self.adopt(next);
    }
    pub fn removeLayer(self: *Session, index: usize) !void {
        if (self.active != null or index >= self.document.layers.items.len) return error.InvalidLayer;
        var next = try self.document.clone();
        errdefer next.deinit();
        var removed = next.layers.orderedRemove(index);
        removed.deinit();
        try self.adopt(next);
    }
    pub fn moveLayer(self: *Session, from: usize, to: usize) !void {
        if (self.active != null or from >= self.document.layers.items.len or to >= self.document.layers.items.len) return error.InvalidLayer;
        var next = try self.document.clone();
        errdefer next.deinit();
        const layer = next.layers.orderedRemove(from);
        next.layers.insertAssumeCapacity(to, layer);
        try self.adopt(next);
    }
    pub fn begin(self: *Session, layer: usize, ch: Channel, value: m.V3, opacity: f32, erase: bool) !void {
        if (self.active != null or layer >= self.document.layers.items.len or self.document.layers.items[layer].kind != .paint or !m.finite(value) or !std.math.isFinite(opacity) or opacity < 0 or opacity > 1) return error.InvalidStroke;
        const alpha = try tex.Image.init(self.allocator, self.document.width, self.document.height, 1);
        self.gesture_sequence +%= 1;
        if (self.gesture_sequence == 0) self.gesture_sequence = 1;
        self.active = .{ .token = self.gesture_sequence, .layer = layer, .channel = ch, .value = value, .opacity = opacity, .erase = erase, .alpha = alpha };
    }
    pub fn cancel(self: *Session) void {
        if (self.active) |*stroke| {
            self.managed_channels |= @as(u32, 1) << @intFromEnum(stroke.channel);
            self.dirty_channels |= @as(u32, 1) << @intFromEnum(stroke.channel);
            for (0..stroke.alpha.tiles_y) |y| for (0..stroke.alpha.tiles_x) |x| {
                if (stroke.alpha.tile(@intCast(x), @intCast(y)) != null) self.dirty[y * stroke.alpha.tiles_x + x] = true;
            };
            stroke.alpha.deinit();
        }
        self.active = null;
    }
    fn deposit(stroke: *Stroke, x: u32, y: u32, a: f32) !void {
        if (a <= 0) return;
        const old = @as(f32, @floatFromInt(stroke.alpha.get(x, y)[0])) / 65535;
        try stroke.alpha.set(x, y, .{ m.u16of(a + old * (1 - a)), 0, 0, 0 });
        stroke.deposited = true;
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
    pub fn stampWorld(self: *Session, mesh: g.Mesh, bvh: *const g.Bvh, uvbuf: g.UvBuffer, center: m.V3, normal: m.V3, brush: Brush, eye: ?m.V3) anyerror!void {
        try brush.validate();
        if (eye) |e| if (!m.finite(e)) return error.InvalidSample;
        if (!m.finite(center) or !m.finite(normal) or uvbuf.width != self.document.width or uvbuf.height != self.document.height) return error.InvalidSample;
        const stroke = if (self.active) |*s| s else return error.NoStroke;
        const n = m.norm(normal);
        const t = m.norm(m.cross(if (@abs(n[1]) < 0.9) m.V3{ 0, 1, 0 } else m.V3{ 1, 0, 0 }, n));
        const bitangent = m.cross(n, t);
        var query: std.ArrayList(u32) = .empty;
        defer query.deinit(self.allocator);
        try bvh.query(mesh, .{ .lo = m.sub(center, @splat(brush.radius * brush.depth * 1.5)), .hi = m.add(center, @splat(brush.radius * brush.depth * 1.5)) }, &query, self.allocator);
        const Job = struct {
            stroke: *Stroke,
            mesh: g.Mesh,
            bvh: *const g.Bvh,
            uvbuf: g.UvBuffer,
            center: m.V3,
            n: m.V3,
            tangent: m.V3,
            bitangent: m.V3,
            brush: Brush,
            eye: ?m.V3,
            fn run(job: *const @This(), triangles: []const u32) void {
                rasterWorld(job.stroke, job.mesh, job.bvh, job.uvbuf, job.center, job.n, job.tangent, job.bitangent, job.brush, job.eye, triangles, true) catch unreachable;
            }
        };
        const workers = @min(@min(@as(usize, brush.workers), 8), (query.items.len + 63) / 64);
        if (workers > 1) {
            // Allocate serially, then partition by triangle. A UV texel has one
            // owner triangle, so workers write disjoint texels without atomics.
            for (query.items) |ti| {
                if (!worldMaterial(mesh, uvbuf, ti)) continue;
                const rect = worldRect(mesh, ti, uvbuf.width, uvbuf.height);
                if (rect[2] == rect[0] or rect[3] == rect[1]) continue;
                for (rect[1] / 64..(rect[3] - 1) / 64 + 1) |ty| for (rect[0] / 64..(rect[2] - 1) / 64 + 1) |tx| {
                    _ = try stroke.alpha.tileMut(@intCast(tx), @intCast(ty), .{ 0, 0, 0, 0 });
                };
            }
            const job: Job = .{ .stroke = stroke, .mesh = mesh, .bvh = bvh, .uvbuf = uvbuf, .center = center, .n = n, .tangent = t, .bitangent = bitangent, .brush = brush, .eye = eye };
            var threads: [8]std.Thread = undefined;
            var started: usize = 0;
            for (0..workers) |i| {
                threads[i] = std.Thread.spawn(.{}, Job.run, .{ &job, query.items[query.items.len * i / workers .. query.items.len * (i + 1) / workers] }) catch break;
                started += 1;
            }
            // A failed worker launch falls back to serial work for that range.
            for (started..workers) |i| Job.run(&job, query.items[query.items.len * i / workers .. query.items.len * (i + 1) / workers]);
            for (threads[0..started]) |thread| thread.join();
            try stroke.alpha.pruneZeroTiles();
            stroke.deposited = stroke.alpha.allocated() != 0;
        } else try rasterWorld(stroke, mesh, bvh, uvbuf, center, n, t, bitangent, brush, eye, query.items, false);
        if (brush.mirror_x) {
            var mirrored = brush;
            mirrored.mirror_x = false;
            try self.stampWorld(mesh, bvh, uvbuf, .{ -center[0], center[1], center[2] }, .{ -normal[0], normal[1], normal[2] }, mirrored, eye);
        }
        try self.padStroke(uvbuf);
    }
    fn worldMaterial(mesh: g.Mesh, uvbuf: g.UvBuffer, ti: u32) bool {
        if (uvbuf.material) |material| if (mesh.materials.len != 0 and mesh.materials[ti] != material) return false;
        return true;
    }
    fn worldRect(mesh: g.Mesh, ti: u32, width: u32, height: u32) [4]u32 {
        const wf: f32 = @floatFromInt(width);
        const hf: f32 = @floatFromInt(height);
        var lo: m.V2 = .{ wf, hf };
        var hi: m.V2 = .{ 0, 0 };
        for (mesh.indices[ti * 3 ..][0..3]) |id| {
            lo[0] = @min(lo[0], mesh.uvs[id][0] * wf);
            lo[1] = @min(lo[1], mesh.uvs[id][1] * hf);
            hi[0] = @max(hi[0], mesh.uvs[id][0] * wf);
            hi[1] = @max(hi[1], mesh.uvs[id][1] * hf);
        }
        return .{ @intFromFloat(std.math.clamp(@floor(lo[0]), 0, wf)), @intFromFloat(std.math.clamp(@floor(lo[1]), 0, hf)), @intFromFloat(std.math.clamp(@ceil(hi[0]), 0, wf)), @intFromFloat(std.math.clamp(@ceil(hi[1]), 0, hf)) };
    }
    fn rasterWorld(stroke: *Stroke, mesh: g.Mesh, bvh: *const g.Bvh, uvbuf: g.UvBuffer, center: m.V3, n: m.V3, t: m.V3, bitangent: m.V3, brush: Brush, eye: ?m.V3, triangles: []const u32, comptime resident: bool) !void {
        for (triangles) |ti| {
            if (!worldMaterial(mesh, uvbuf, ti)) continue;
            const rect = worldRect(mesh, ti, uvbuf.width, uvbuf.height);
            for (rect[1]..rect[3]) |y| for (rect[0]..rect[2]) |x| {
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
                if (resident) {
                    const data = @constCast(stroke.alpha.tile(@intCast(x / 64), @intCast(y / 64)).?);
                    const at = (y % 64) * 64 + x % 64;
                    const old = @as(f32, @floatFromInt(data[at])) / 65535;
                    data[at] = m.u16of(alpha + old * (1 - alpha));
                } else try deposit(stroke, @intCast(x), @intCast(y), alpha);
            };
        }
    }
    fn padStroke(self: *Session, uv: g.UvBuffer) !void {
        const stroke = if (self.active) |*s| s else return error.NoStroke;
        for (0..stroke.alpha.tiles_y) |ty| for (0..stroke.alpha.tiles_x) |tx| {
            const tile = stroke.alpha.tile(@intCast(tx), @intCast(ty)) orelse continue;
            for (0..4096) |i| {
                const x = tx * 64 + i % 64;
                const y = ty * 64 + i / 64;
                if (x >= uv.width or y >= uv.height or tile[i] == 0 or uv.texels[y * uv.width + x].triangle == std.math.maxInt(u32)) continue;
                const alpha = tile[i];
                var mask = uv.paddingMask(@intCast(x), @intCast(y));
                while (mask != 0) {
                    const bit: u32 = @ctz(mask);
                    mask &= mask - 1;
                    const nx = @as(i64, @intCast(x)) + @as(i64, bit % 5) - 2;
                    const ny = @as(i64, @intCast(y)) + @as(i64, bit / 5) - 2;
                    const xx: u32 = @intCast(nx);
                    const yy: u32 = @intCast(ny);
                    const old = stroke.alpha.get(xx, yy)[0];
                    if (alpha > old) try stroke.alpha.set(xx, yy, .{ alpha, 0, 0, 0 });
                }
            }
        };
    }
    pub fn previewDocument(self: *Session) !Document {
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
        return next;
    }
    pub fn commit(self: *Session) !void {
        const stroke = self.active orelse return error.NoStroke;
        if (!stroke.deposited) {
            self.cancel();
            return;
        }
        const ci = @intFromEnum(stroke.channel);
        var next = try self.previewDocument();
        errdefer next.deinit();
        try self.undo_stack.ensureUnusedCapacity(self.allocator, 1);
        for (self.redo_stack.items) |*d| d.deinit();
        self.redo_stack.clearRetainingCapacity();
        self.undo_stack.appendAssumeCapacity(self.document);
        self.document = next;
        self.revision +%= 1;
        self.managed_channels |= @as(u32, 1) << @intCast(ci);
        self.dirty_channels |= @as(u32, 1) << @intCast(ci);
        for (0..stroke.alpha.tiles_y) |ty| for (0..stroke.alpha.tiles_x) |tx| {
            if (stroke.alpha.tile(@intCast(tx), @intCast(ty)) != null) self.dirty[ty * stroke.alpha.tiles_x + tx] = true;
        };
        self.trimHistory();
        self.cancel();
    }
    pub fn undo(self: *Session) !bool {
        if (self.active != null) return error.StrokeActive;
        if (self.undo_stack.items.len == 0) return false;
        try self.redo_stack.ensureUnusedCapacity(self.allocator, 1);
        self.redo_stack.appendAssumeCapacity(self.document);
        self.document = self.undo_stack.pop().?;
        self.revision +%= 1;
        self.dirty_channels |= self.managed_channels;
        @memset(self.dirty, true);
        return true;
    }
    pub fn redo(self: *Session) !bool {
        if (self.active != null) return error.StrokeActive;
        if (self.redo_stack.items.len == 0) return false;
        try self.undo_stack.ensureUnusedCapacity(self.allocator, 1);
        self.undo_stack.appendAssumeCapacity(self.document);
        self.document = self.redo_stack.pop().?;
        self.revision +%= 1;
        self.dirty_channels |= self.managed_channels;
        @memset(self.dirty, true);
        return true;
    }
    pub fn clearDirty(self: *Session) void {
        @memset(self.dirty, false);
        self.dirty_channels = 0;
    }
    pub fn importBase(self: *Session, rgba: []const [4]u16) !void {
        if (self.active != null or self.document.layers.items.len != 0 or rgba.len != @as(u64, self.document.width) * self.document.height) return error.InvalidImport;
        var layer: Layer = .{};
        errdefer layer.deinit();
        @memcpy(layer.name[0..4], "Base");
        var color = try tex.Image.init(self.allocator, self.document.width, self.document.height, 4);
        errdefer color.deinit();
        var opacity = try tex.Image.init(self.allocator, self.document.width, self.document.height, 2);
        errdefer opacity.deinit();
        for (0..color.tiles_y) |ty| for (0..color.tiles_x) |tx| {
            const ct = try color.tileMut(@intCast(tx), @intCast(ty), .{ 0, 0, 0, 0 });
            const ot = try opacity.tileMut(@intCast(tx), @intCast(ty), .{ 0, 0, 0, 0 });
            for (0..64) |dy| for (0..64) |dx| {
                const x = tx * 64 + dx;
                const y = ty * 64 + dy;
                if (x >= color.width or y >= color.height) continue;
                const value = rgba[y * color.width + x];
                const i = dy * 64 + dx;
                @memcpy(ct[i * 4 ..][0..3], value[0..3]);
                ct[i * 4 + 3] = 65535;
                ot[i * 2] = value[3];
                ot[i * 2 + 1] = 65535;
            };
        };
        try self.document.layers.ensureUnusedCapacity(self.allocator, 1);
        layer.pixels[@intFromEnum(Channel.base_color)] = color;
        layer.pixels[@intFromEnum(Channel.opacity)] = opacity;
        layer.enabled = (@as(u32, 1) << @intFromEnum(Channel.base_color)) | (@as(u32, 1) << @intFromEnum(Channel.opacity));
        self.document.layers.appendAssumeCapacity(layer);
        self.revision +%= 1;
        self.managed_channels |= layer.enabled;
        self.dirty_channels |= layer.enabled;
        @memset(self.dirty, true);
    }
    /// One undoable map import. RGB is straight linear data and alpha is
    /// coverage. Signed height uses centered-u16 encoding.
    pub fn importChannel(self: *Session, name: []const u8, ch: Channel, rgba: []const [4]u16) !usize {
        if (self.active != null or name.len > 63 or self.document.layers.items.len >= 256 or rgba.len != @as(u64, self.document.width) * self.document.height) return error.InvalidImport;
        var next = try self.document.clone();
        errdefer next.deinit();
        var layer: Layer = .{};
        errdefer layer.deinit();
        @memcpy(layer.name[0..name.len], name);
        const image = try importedImage(self.allocator, next.width, next.height, ch, rgba);
        layer.pixels[@intFromEnum(ch)] = image;
        layer.enabled = @as(u32, 1) << @intFromEnum(ch);
        try next.layers.append(self.allocator, layer);
        layer = .{};
        const index = next.layers.items.len - 1;
        try self.adopt(next);
        return index;
    }
};
fn importedImage(a: std.mem.Allocator, width: u32, height: u32, ch: Channel, rgba: []const [4]u16) !tex.Image {
    var image = try tex.Image.init(a, width, height, ch.components() + 1);
    errdefer image.deinit();
    for (0..height) |y| for (0..width) |x| {
        const pixel = rgba[y * width + x];
        if (pixel[3] == 0) continue;
        const alpha = @as(f32, @floatFromInt(pixel[3])) / 65535;
        const fill: [4]u16 = if (ch == .height) .{ 32768, 0, 0, 0 } else .{ 0, 0, 0, 0 };
        const tile = try image.tileMut(@intCast(x / 64), @intCast(y / 64), fill);
        const at = ((y % 64) * 64 + x % 64) * (ch.components() + @as(usize, 1));
        for (0..ch.components()) |k| {
            const v = @as(f32, @floatFromInt(pixel[k])) / 65535;
            tile[at + k] = m.u16of(if (ch == .height) (v * 2 - 1) * alpha * 0.5 + 0.5 else v * alpha);
        }
        tile[at + ch.components()] = pixel[3];
    };
    return image;
}
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
    {
        var preview = try session.previewDocument();
        defer preview.deinit();
        try std.testing.expect(preview.pixel(.base_color, 64, 64)[0] > 0.9);
        try std.testing.expectEqual(m.V3{ 0.5, 0.5, 0.5 }, session.document.pixel(.base_color, 64, 64));
    }
    try session.commit();
    try std.testing.expect(session.document.pixel(.base_color, 64, 64)[0] > 0.9);
    try std.testing.expect(try session.undo());
    try std.testing.expectEqual(m.V3{ 0.5, 0.5, 0.5 }, session.document.pixel(.base_color, 64, 64));
    try std.testing.expect(try session.redo());
}
test "paint commit undo redo allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, transactionFailure, .{});
}

test "one world stamp paints both UV islands and only dirty tiles" {
    const a = std.testing.allocator;
    const mesh: g.Mesh = .{ .positions = &.{ .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 } }, .normals = &.{ .{ 0, 0, 1 }, .{ 0, 0, 1 }, .{ 0, 0, 1 }, .{ 0, 0, 1 }, .{ 0, 0, 1 }, .{ 0, 0, 1 } }, .uvs = &.{ .{ 0, 0 }, .{ 0.4, 0 }, .{ 0, 0.4 }, .{ 0.6, 0.6 }, .{ 1, 0.6 }, .{ 0.6, 1 } }, .indices = &.{ 0, 1, 2, 3, 4, 5 } };
    var bvh = try g.Bvh.init(a, mesh);
    defer bvh.deinit();
    var uv = try g.UvBuffer.init(a, mesh, 256, 256, null);
    defer uv.deinit();
    var session = try Session.init(a, 256, 256);
    defer session.deinit();
    const layer = try session.addLayer("surface detail", .paint);
    session.clearDirty();
    try session.begin(layer, .base_color, .{ 1, 0, 0 }, 1, false);
    try session.stampWorld(mesh, &bvh, uv, .{ 0.2, 0.2, 0 }, .{ 0, 0, 1 }, .{ .radius = 0.1, .hardness = 1 }, .{ 0.2, 0.2, 1 });
    try session.commit();
    try std.testing.expect(session.document.pixel(.base_color, 20, 20)[0] > 0.9);
    try std.testing.expect(session.document.pixel(.base_color, 174, 174)[0] > 0.9);
    var dirty_count: usize = 0;
    for (session.dirty) |dirty| {
        if (dirty) dirty_count += 1;
    }
    try std.testing.expect(dirty_count < session.dirty.len);
}
