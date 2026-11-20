//! Source-informed recovery of texel/noise.rs at the pinned TextureCraft revision.
const std = @import("std");
pub const V3 = [3]f32;
pub fn pcg3d(x: u32, y: u32, z: u32) [3]u32 {
    var v = [3]u32{ x *% 1664525 +% 1013904223, y *% 1664525 +% 1013904223, z *% 1664525 +% 1013904223 };
    v[0] +%= v[1] *% v[2];
    v[1] +%= v[2] *% v[0];
    v[2] +%= v[0] *% v[1];
    for (&v) |*a| a.* ^= a.* >> 16;
    v[0] +%= v[1] *% v[2];
    v[1] +%= v[2] *% v[0];
    v[2] +%= v[0] *% v[1];
    return v;
}
const Cell = struct { index: i32, fraction: f32 };
fn cell(p: f32) Cell {
    const f = @floor(p);
    const i: i32 = if (std.math.isNan(f)) 0 else if (f >= 2147483648.0) std.math.maxInt(i32) else if (f <= -2147483648.0) std.math.minInt(i32) else @intFromFloat(f);
    return .{ .index = i, .fraction = p - f };
}
fn hash01(x: i32, y: i32, z: i32, seed: u32) f32 {
    return @as(f32, @floatFromInt(pcg3d(@as(u32, @bitCast(x)) ^ seed *% 0x9e3779b9, @bitCast(y), @bitCast(z))[0])) / 4294967296.0;
}
fn smooth(t: f32) f32 {
    return t * t * t * (t * (t * 6 - 15) + 10);
}
fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}
fn interpolate(v: [8]f32, t: V3) f32 {
    return lerp(lerp(lerp(v[0], v[1], t[0]), lerp(v[2], v[3], t[0]), t[1]), lerp(lerp(v[4], v[5], t[0]), lerp(v[6], v[7], t[0]), t[1]), t[2]);
}
pub fn value(p: V3, seed: u32) f32 {
    @setFloatMode(.strict);
    const c = [3]Cell{ cell(p[0]), cell(p[1]), cell(p[2]) };
    var v: [8]f32 = undefined;
    for (0..8) |i| v[i] = hash01(c[0].index +% @as(i32, @intCast(i & 1)), c[1].index +% @as(i32, @intCast((i >> 1) & 1)), c[2].index +% @as(i32, @intCast((i >> 2) & 1)), seed);
    return interpolate(v, .{ smooth(c[0].fraction), smooth(c[1].fraction), smooth(c[2].fraction) });
}
const gradients = [12]V3{ .{ 1, 1, 0 }, .{ -1, 1, 0 }, .{ 1, -1, 0 }, .{ -1, -1, 0 }, .{ 1, 0, 1 }, .{ -1, 0, 1 }, .{ 1, 0, -1 }, .{ -1, 0, -1 }, .{ 0, 1, 1 }, .{ 0, -1, 1 }, .{ 0, 1, -1 }, .{ 0, -1, -1 } };
pub fn perlin(p: V3, seed: u32) f32 {
    @setFloatMode(.strict);
    const c = [3]Cell{ cell(p[0]), cell(p[1]), cell(p[2]) };
    var v: [8]f32 = undefined;
    for (0..8) |i| {
        const dx: i32 = @intCast(i & 1);
        const dy: i32 = @intCast((i >> 1) & 1);
        const dz: i32 = @intCast((i >> 2) & 1);
        const h = pcg3d(@as(u32, @bitCast(c[0].index +% dx)) ^ seed *% 0x85ebca6b, @bitCast(c[1].index +% dy), @bitCast(c[2].index +% dz));
        const g = gradients[h[1] % 12];
        v[i] = g[0] * (c[0].fraction - @as(f32, @floatFromInt(dx))) + g[1] * (c[1].fraction - @as(f32, @floatFromInt(dy))) + g[2] * (c[2].fraction - @as(f32, @floatFromInt(dz)));
    }
    return std.math.clamp(interpolate(v, .{ smooth(c[0].fraction), smooth(c[1].fraction), smooth(c[2].fraction) }) * 0.5 + 0.5, 0, 1);
}
pub fn cellular(p: V3, seed: u32) V3 {
    @setFloatMode(.strict);
    const c = [3]Cell{ cell(p[0]), cell(p[1]), cell(p[2]) };
    var f1: f32 = std.math.floatMax(f32);
    var f2 = f1;
    var id: u32 = 0;
    for (0..3) |z| for (0..3) |y| for (0..3) |x| {
        const dx = @as(i32, @intCast(x)) - 1;
        const dy = @as(i32, @intCast(y)) - 1;
        const dz = @as(i32, @intCast(z)) - 1;
        const h = pcg3d(@as(u32, @bitCast(c[0].index +% dx)) ^ seed *% 0xc2b2ae35, @bitCast(c[1].index +% dy), @bitCast(c[2].index +% dz));
        const a = @as(f32, @floatFromInt(dx)) + @as(f32, @floatFromInt(h[0])) / 4294967296.0 - c[0].fraction;
        const b = @as(f32, @floatFromInt(dy)) + @as(f32, @floatFromInt(h[1])) / 4294967296.0 - c[1].fraction;
        const d = @as(f32, @floatFromInt(dz)) + @as(f32, @floatFromInt(h[2])) / 4294967296.0 - c[2].fraction;
        const distance = a * a + b * b + d * d;
        if (distance < f1) {
            f2 = f1;
            f1 = distance;
            id = h[0] ^ h[1];
        } else if (distance < f2) {
            f2 = distance;
        }
    };
    return .{ @min(@sqrt(f1), 1), @min(@sqrt(f2), 1), @as(f32, @floatFromInt(id)) / 4294967296.0 };
}
pub fn worley(p: V3, seed: u32) f32 {
    return cellular(p, seed)[0];
}
pub fn fbm(p: V3, octaves: u32, seed: u32, comptime base: fn (V3, u32) f32) f32 {
    @setFloatMode(.strict);
    var sum: f32 = 0;
    var amplitude: f32 = 0.5;
    var normalization: f32 = 0;
    var position = p;
    for (0..std.math.clamp(octaves, 1, 12)) |octave| {
        sum += amplitude * base(position, seed +% @as(u32, @intCast(octave)) * 31);
        normalization += amplitude;
        for (&position) |*v| v.* = v.* * 2 + 17.13;
        amplitude *= 0.5;
    }
    return sum / normalization;
}
fn checksumPoint(checksum: *u64, p: V3) void {
    for ([_]u32{ 0, 7 }) |seed| {
        const c = cellular(p, seed);
        for ([_]f32{ value(p, seed), perlin(p, seed), c[0], c[1], c[2], fbm(p, 6, seed, perlin), fbm(p, 3, seed, value) }) |v| checksum.* = (checksum.* ^ @as(u32, @bitCast(v))) *% 0x0100000001b3;
    }
}
test "58366 noise values preserve the original Rust bit checksum" {
    var checksum: u64 = 0xcbf29ce484222325;
    for (0..4000) |i| checksumPoint(&checksum, .{ @as(f32, @floatFromInt(i)) * 0.37 - 700, @as(f32, @floatFromInt((i * 7919) % 8000)) * 0.01 - 40, @as(f32, @floatFromInt(i % 97)) * -0.53 });
    const special = [_]f32{ 0, -0.0, 1, -1, 0.5, -0.5, 1e-7, -1e-7, 8388607.5, -8388607.5, 8388608, 3e9, -3e9 };
    for (special) |a| for (special) |b| checksumPoint(&checksum, .{ a, b, a - b });
    try std.testing.expectEqual(@as(u64, 0x67e814aa2127b333), checksum);
}
