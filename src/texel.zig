//! Sparse two-level copy-on-write images. Clones cost one reference increment.
const std = @import("std");
const m = @import("math.zig");
pub const tile_size = 64;
pub const tile_area = 4096;
const Tile = struct { refs: std.atomic.Value(usize) = .init(1), data: []u16 };
const Table = struct { refs: std.atomic.Value(usize) = .init(1), slots: []?*Tile };
pub const Image = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    components: u8,
    tiles_x: u32,
    tiles_y: u32,
    table: *Table,
    pub fn init(a: std.mem.Allocator, w: u32, h: u32, components: u8) !Image {
        if (w == 0 or h == 0 or w > 8192 or h > 8192 or components == 0 or components > 4) return error.ImageBudget;
        const tx = (w + 63) / 64;
        const ty = (h + 63) / 64;
        const slots = try a.alloc(?*Tile, @as(usize, tx) * ty);
        errdefer a.free(slots);
        @memset(slots, null);
        const table = try a.create(Table);
        table.* = .{ .slots = slots };
        return .{ .allocator = a, .width = w, .height = h, .components = components, .tiles_x = tx, .tiles_y = ty, .table = table };
    }
    pub fn clone(self: Image) Image {
        _ = self.table.refs.fetchAdd(1, .monotonic);
        return self;
    }
    fn dropTile(a: std.mem.Allocator, t: *Tile) void {
        if (t.refs.fetchSub(1, .acq_rel) == 1) {
            a.free(t.data);
            a.destroy(t);
        }
    }
    fn dropTable(a: std.mem.Allocator, t: *Table) void {
        if (t.refs.fetchSub(1, .acq_rel) == 1) {
            for (t.slots) |slot| if (slot) |entry| dropTile(a, entry);
            a.free(t.slots);
            a.destroy(t);
        }
    }
    pub fn deinit(self: *Image) void {
        dropTable(self.allocator, self.table);
        self.* = undefined;
    }
    fn unique(self: *Image) !void {
        if (self.table.refs.load(.acquire) == 1) return;
        const slots = try self.allocator.dupe(?*Tile, self.table.slots);
        errdefer self.allocator.free(slots);
        const t = try self.allocator.create(Table);
        t.* = .{ .slots = slots };
        for (slots) |slot| if (slot) |entry| {
            _ = entry.refs.fetchAdd(1, .monotonic);
        };
        dropTable(self.allocator, self.table);
        self.table = t;
    }
    pub fn tile(self: Image, x: u32, y: u32) ?[]const u16 {
        if (x >= self.tiles_x or y >= self.tiles_y) return null;
        return if (self.table.slots[@as(usize, y) * self.tiles_x + x]) |t| t.data else null;
    }
    pub fn tileIdentity(self: Image, x: u32, y: u32) ?*const anyopaque {
        if (x >= self.tiles_x or y >= self.tiles_y) return null;
        return self.table.slots[@as(usize, y) * self.tiles_x + x];
    }
    pub fn tileMut(self: *Image, x: u32, y: u32, fill: [4]u16) ![]u16 {
        if (x >= self.tiles_x or y >= self.tiles_y) return error.InvalidPixel;
        try self.unique();
        const slot = &self.table.slots[@as(usize, y) * self.tiles_x + x];
        if (slot.*) |t| {
            if (t.refs.load(.acquire) == 1) return t.data;
            const data = try self.allocator.dupe(u16, t.data);
            errdefer self.allocator.free(data);
            const next = try self.allocator.create(Tile);
            next.* = .{ .data = data };
            dropTile(self.allocator, t);
            slot.* = next;
            return data;
        }
        const data = try self.allocator.alloc(u16, tile_area * @as(usize, self.components));
        errdefer self.allocator.free(data);
        for (0..tile_area) |i| for (0..self.components) |c| {
            data[i * self.components + c] = fill[c];
        };
        const next = try self.allocator.create(Tile);
        next.* = .{ .data = data };
        slot.* = next;
        return data;
    }
    pub fn get(self: Image, x: u32, y: u32) [4]u16 {
        var result: [4]u16 = @splat(0);
        if (x >= self.width or y >= self.height) return result;
        const data = self.tile(x / 64, y / 64) orelse return result;
        const base = ((y % 64) * 64 + x % 64) * self.components;
        for (0..self.components) |k| result[k] = data[base + k];
        return result;
    }
    pub fn set(self: *Image, x: u32, y: u32, value: [4]u16) !void {
        if (x >= self.width or y >= self.height) return error.InvalidPixel;
        const data = try self.tileMut(x / 64, y / 64, .{ 0, 0, 0, 0 });
        const base = ((y % 64) * 64 + x % 64) * self.components;
        @memcpy(data[base..][0..self.components], value[0..self.components]);
    }
    pub fn allocated(self: Image) usize {
        var n: usize = 0;
        for (self.table.slots) |slot| {
            if (slot != null) n += 1;
        }
        return n;
    }
};
pub const Padding = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    source: []u32,
    pub fn init(a: std.mem.Allocator, width: u32, height: u32, covered: []const bool) !Padding {
        if (width == 0 or height == 0 or width > 8192 or height > 8192 or covered.len != @as(u64, width) * height) return error.ImageBudget;
        const source = try a.alloc(u32, covered.len);
        errdefer a.free(source);
        @memset(source, std.math.maxInt(u32));
        var queue = try a.alloc(u32, covered.len);
        defer a.free(queue);
        var tail: usize = 0;
        for (covered, 0..) |valid, i| {
            if (valid) {
                source[i] = @intCast(i);
                queue[tail] = @intCast(i);
                tail += 1;
            }
        }
        var head: usize = 0;
        while (head < tail) : (head += 1) {
            const i = queue[head];
            const x = i % width;
            const y = i / width;
            var neighbors: [4]u32 = undefined;
            var n: usize = 0;
            if (x > 0) {
                neighbors[n] = i - 1;
                n += 1;
            }
            if (x + 1 < width) {
                neighbors[n] = i + 1;
                n += 1;
            }
            if (y > 0) {
                neighbors[n] = i - width;
                n += 1;
            }
            if (y + 1 < height) {
                neighbors[n] = i + width;
                n += 1;
            }
            for (neighbors[0..n]) |j| {
                if (source[j] == std.math.maxInt(u32)) {
                    source[j] = source[i];
                    queue[tail] = j;
                    tail += 1;
                }
            }
        }
        return .{ .allocator = a, .width = width, .height = height, .source = source };
    }
    pub fn deinit(self: *Padding) void {
        self.allocator.free(self.source);
        self.* = undefined;
    }
    pub fn apply(self: Padding, image: *Image) !void {
        if (image.width != self.width or image.height != self.height) return error.InvalidDimensions;
        var original = image.clone();
        defer original.deinit();
        for (self.source, 0..) |s, i| {
            if (s != std.math.maxInt(u32) and s != i) try image.set(@intCast(i % self.width), @intCast(i / self.width), original.get(s % self.width, s / self.width));
        }
    }
};
fn imageFailure(a: std.mem.Allocator) !void {
    var image = try Image.init(a, 128, 128, 4);
    defer image.deinit();
    try image.set(1, 1, .{ 65535, 0, 0, 65535 });
    var clone = image.clone();
    defer clone.deinit();
    try clone.set(1, 1, .{ 0, 65535, 0, 65535 });
    try std.testing.expectEqual(@as(u16, 65535), image.get(1, 1)[0]);
}
test "COW allocation failures preserve ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, imageFailure, .{});
}
test "sparse clone modifies only touched tile" {
    var image = try Image.init(std.testing.allocator, 8192, 8192, 4);
    defer image.deinit();
    try image.set(1, 1, .{ 1, 2, 3, 4 });
    try image.set(80, 1, .{ 4, 3, 2, 1 });
    var clone = image.clone();
    defer clone.deinit();
    const original = image.tileIdentity(1, 0);
    try clone.set(1, 1, .{ 2, 2, 2, 2 });
    try std.testing.expectEqual(original, clone.tileIdentity(1, 0));
    try std.testing.expectEqual(@as(usize, 2), clone.allocated());
    try std.testing.expectEqual(@as(u16, 1), image.get(1, 1)[0]);
}
