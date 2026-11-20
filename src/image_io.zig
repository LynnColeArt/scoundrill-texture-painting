//! Native PNG encoding and deterministic project persistence; no system image codec.
const std = @import("std");
const m = @import("math.zig");
const paint = @import("painting.zig");
const tex = @import("texel.zig");
pub const PngOptions = struct { bits: enum { eight, sixteen } = .eight, color: bool = true };
pub fn png(a: std.mem.Allocator, width: u32, height: u32, pixels: []const [4]u16, options: PngOptions) ![]u8 {
    if (width == 0 or height == 0 or width > 8192 or height > 8192 or pixels.len != @as(u64, width) * height) return error.ImageBudget;
    const stride: @TypeOf(@as(usize, 0)) = if (options.bits == .eight) 4 else 8;
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(a);
    try raw.ensureTotalCapacity(a, (@as(usize, width) * stride + 1) * height);
    for (0..height) |y| {
        raw.appendAssumeCapacity(0);
        for (pixels[y * width ..][0..width]) |p| for (p, 0..) |v, k| {
            const value = if (options.color and k < 3) m.u16of(m.srgb(@as(f32, @floatFromInt(v)) / 65535)) else v;
            if (options.bits == .eight) raw.appendAssumeCapacity(@intCast(value >> 8)) else {
                raw.appendAssumeCapacity(@intCast(value >> 8));
                raw.appendAssumeCapacity(@truncate(value));
            }
        };
    }
    var z: std.ArrayList(u8) = .empty;
    defer z.deinit(a);
    try z.appendSlice(a, &.{ 0x78, 0x01 });
    var offset: usize = 0;
    while (offset < raw.items.len) {
        const n = @min(@as(usize, 65535), raw.items.len - offset);
        const len: u16 = @intCast(n);
        try z.append(a, if (offset + n == raw.items.len) 1 else 0);
        try z.appendSlice(a, &.{ @truncate(len), @intCast(len >> 8), @truncate(~len), @intCast((~len) >> 8) });
        try z.appendSlice(a, raw.items[offset..][0..n]);
        offset += n;
    }
    var a1: u32 = 1;
    var a2: u32 = 0;
    for (raw.items) |v| {
        a1 = (a1 + v) % 65521;
        a2 = (a2 + a1) % 65521;
    }
    var checksum: [4]u8 = undefined;
    std.mem.writeInt(u32, &checksum, (a2 << 16) | a1, .big);
    try z.appendSlice(a, &checksum);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "\x89PNG\r\n\x1a\n");
    var ihdr: [13]u8 = @splat(0);
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = if (options.bits == .eight) 8 else 16;
    ihdr[9] = 6;
    try chunk(a, &out, "IHDR", &ihdr);
    try chunk(a, &out, "IDAT", z.items);
    try chunk(a, &out, "IEND", &.{});
    return out.toOwnedSlice(a);
}
fn chunk(a: std.mem.Allocator, out: *std.ArrayList(u8), name: *const [4]u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.appendSlice(a, &len);
    const start = out.items.len;
    try out.appendSlice(a, name);
    try out.appendSlice(a, data);
    var crc: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc, std.hash.Crc32.hash(out.items[start..]), .big);
    try out.appendSlice(a, &crc);
}
pub fn exportChannel(a: std.mem.Allocator, doc: paint.Document, ch: paint.Channel, options: PngOptions) ![]u8 {
    const data = try a.alloc([4]u16, @as(usize, doc.width) * doc.height);
    defer a.free(data);
    try doc.region(ch, 0, 0, doc.width, doc.height, data);
    return png(a, doc.width, doc.height, data, options);
}
const StoredTile = struct { x: u32, y: u32, data: []const u16 };
const StoredImage = struct { components: u8, tiles: []const StoredTile };
const StoredChannel = struct { channel: paint.Channel, image: StoredImage };
const StoredLayer = struct { name: [64]u8, kind: enum { paint, fill }, visible: bool, opacity: f32, pattern: paint.Pattern, scale: f32, seed: u32, modes: [paint.channel_count]@import("blend.zig").Mode, enabled: u32, values: [paint.channel_count]m.V3, channels: []const StoredChannel, mask: ?StoredImage };
const Stored = struct { version: u32 = 1, width: u32, height: u32, layers: []const StoredLayer, defaults: ?[paint.channel_count]m.V3 = null };
fn storeImage(a: std.mem.Allocator, image: tex.Image) !StoredImage {
    var tiles: std.ArrayList(StoredTile) = .empty;
    for (0..image.tiles_y) |y| for (0..image.tiles_x) |x| {
        if (image.tile(@intCast(x), @intCast(y))) |data| try tiles.append(a, .{ .x = @intCast(x), .y = @intCast(y), .data = data });
    };
    return .{ .components = image.components, .tiles = tiles.items };
}
pub fn save(a: std.mem.Allocator, doc: paint.Document) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var layers: std.ArrayList(StoredLayer) = .empty;
    for (doc.layers.items) |layer| {
        var channels: std.ArrayList(StoredChannel) = .empty;
        for (layer.pixels, 0..) |img, i| if (img) |image| {
            try channels.append(scratch, .{ .channel = @enumFromInt(i), .image = try storeImage(scratch, image) });
        };
        try layers.append(scratch, .{ .name = layer.name, .kind = if (layer.kind == .fill) .fill else .paint, .visible = layer.visible, .opacity = layer.opacity, .pattern = layer.pattern, .scale = layer.scale, .seed = layer.seed, .modes = layer.modes, .enabled = layer.enabled, .values = layer.values, .channels = channels.items, .mask = if (layer.mask) |image| try storeImage(scratch, image) else null });
    }
    return std.json.Stringify.valueAlloc(a, Stored{ .width = doc.width, .height = doc.height, .layers = layers.items, .defaults = doc.defaults }, .{});
}
fn restoreImage(a: std.mem.Allocator, w: u32, h: u32, src: StoredImage, expected: u8) !tex.Image {
    if (src.components != expected or src.tiles.len > @as(usize, (w + 63) / 64) * ((h + 63) / 64)) return error.InvalidProject;
    var image = try tex.Image.init(a, w, h, expected);
    errdefer image.deinit();
    for (src.tiles) |tile| {
        if (tile.x >= image.tiles_x or tile.y >= image.tiles_y or tile.data.len != 4096 * @as(usize, expected) or image.tile(tile.x, tile.y) != null) return error.InvalidProject;
        const dst = try image.tileMut(tile.x, tile.y, .{ 0, 0, 0, 0 });
        @memcpy(dst, tile.data);
    }
    return image;
}
pub fn load(a: std.mem.Allocator, data: []const u8) !paint.Document {
    if (data.len > 128 * 1024 * 1024) return error.ProjectBudget;
    const parsed = try std.json.parseFromSlice(Stored, a, data, .{});
    defer parsed.deinit();
    const src = parsed.value;
    if (src.version != 1 or src.layers.len > 256) return error.InvalidProject;
    var doc = try paint.Document.init(a, src.width, src.height);
    errdefer doc.deinit();
    if (src.defaults) |values| {
        for (values) |v| if (!m.finite(v)) return error.InvalidProject;
        doc.defaults = values;
    }
    for (src.layers) |row| {
        if (!std.math.isFinite(row.opacity) or row.opacity < 0 or row.opacity > 1 or !std.math.isFinite(row.scale) or row.scale <= 0 or row.scale > 1e6 or row.channels.len > paint.channel_count) return error.InvalidProject;
        var layer: paint.Layer = .{ .name = row.name, .kind = if (row.kind == .fill) .fill else .paint, .visible = row.visible, .opacity = row.opacity, .pattern = row.pattern, .scale = row.scale, .seed = row.seed, .modes = row.modes, .enabled = row.enabled, .values = row.values };
        errdefer layer.deinit();
        for (row.values) |v| if (!m.finite(v)) return error.InvalidProject;
        for (row.channels) |ch| {
            const index = @intFromEnum(ch.channel);
            if (layer.pixels[index] != null) return error.InvalidProject;
            const img = try restoreImage(a, src.width, src.height, ch.image, ch.channel.components() + 1);
            layer.pixels[index] = img;
        }
        if (row.mask) |mask| {
            const img = try restoreImage(a, src.width, src.height, mask, 1);
            layer.mask = img;
        }
        try doc.layers.append(a, layer);
    }
    return doc;
}
fn persistenceFailure(a: std.mem.Allocator) !void {
    var s = try paint.Session.init(a, 16, 16);
    defer s.deinit();
    const layer = try s.addLayer("skin", .paint);
    try s.begin(layer, .base_color, .{ 0.9, 0.2, 0.1 }, 1, false);
    try s.stampUv(.{ 0.5, 0.5 }, .{ .radius = 0.2 }, 1);
    try s.commit();
    const data = try save(a, s.document);
    defer a.free(data);
    var doc = try load(a, data);
    defer doc.deinit();
    try std.testing.expectEqual(s.document.pixel(.base_color, 8, 8), doc.pixel(.base_color, 8, 8));
}
test "project roundtrip and allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, persistenceFailure, .{});
}
test "PNG encodes native dimensions and 16 bits" {
    const data = try png(std.testing.allocator, 1, 1, &.{.{ 65535, 0, 32768, 65535 }}, .{ .bits = .sixteen });
    defer std.testing.allocator.free(data);
    try std.testing.expectEqual(@as(u8, 16), data[24]);
    try std.testing.expectEqualStrings("IHDR", data[12..16]);
}
