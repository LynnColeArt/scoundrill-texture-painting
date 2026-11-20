//! Source-informed port of TextureCraft core/blend.rs. See licenses/texturecraft.
const std = @import("std");
const m = @import("math.zig");
pub const Mode = enum { normal, passthrough, disable, replace, multiply, divide, inverse_divide, darken, lighten, linear_dodge, subtract, inverse_subtract, difference, exclusion, signed_addition, overlay, screen, linear_burn, color_burn, color_dodge, soft_light, hard_light, vivid_light, linear_light, pin_light, tint, saturation, color, value, normal_map_combine, normal_map_detail, normal_map_inverse_detail };
fn burn(a: f32, b: f32) f32 {
    return if (a >= 1) 1 else if (b <= 0) 0 else 1 - @min((1 - a) / b, 1);
}
fn dodge(a: f32, b: f32) f32 {
    return if (a <= 0) 0 else if (b >= 1) 1 else @min(a / (1 - b), 1);
}
fn overlay(a: f32, b: f32) f32 {
    return if (a < 0.5) 2 * a * b else 1 - 2 * (1 - a) * (1 - b);
}
fn soft(a0: f32, b0: f32) f32 {
    const a = std.math.clamp(a0, 0, 1);
    const b = std.math.clamp(b0, 0, 1);
    if (b <= 0.5) return a - (1 - 2 * b) * a * (1 - a);
    const d = if (a <= 0.25) ((16 * a - 12) * a + 4) * a else @sqrt(a);
    return a + (2 * b - 1) * (d - a);
}
pub fn scalar(mode: Mode, a: f32, b: f32) f32 {
    return switch (mode) {
        .normal, .passthrough, .replace => b,
        .disable => a,
        .multiply => a * b,
        .divide => a / @max(b, 1e-6),
        .inverse_divide => b / @max(a, 1e-6),
        .darken => @min(a, b),
        .lighten => @max(a, b),
        .linear_dodge => a + b,
        .subtract => a - b,
        .inverse_subtract => b - a,
        .difference => @abs(a - b),
        .exclusion => a + b - 2 * a * b,
        .signed_addition, .linear_light => a + 2 * b - 1,
        .overlay => overlay(a, b),
        .screen => 1 - (1 - a) * (1 - b),
        .linear_burn => a + b - 1,
        .color_burn => burn(a, b),
        .color_dodge => dodge(a, b),
        .soft_light => soft(a, b),
        .hard_light => overlay(b, a),
        .vivid_light => if (b < 0.5) burn(a, 2 * b) else dodge(a, 2 * (b - 0.5)),
        .pin_light => if (b < 0.5) @min(a, 2 * b) else @max(a, 2 * b - 1),
        else => b,
    };
}
fn lum(v: m.V3) f32 {
    return v[0] * 0.3 + v[1] * 0.59 + v[2] * 0.11;
}
fn clip(v: m.V3) m.V3 {
    const l = lum(v);
    const n = @min(v[0], @min(v[1], v[2]));
    const x = @max(v[0], @max(v[1], v[2]));
    var out = v;
    if (n < 0 and l - n > 1e-6) for (&out) |*c| {
        c.* = l + (c.* - l) * l / (l - n);
    };
    if (x > 1 and x - l > 1e-6) for (&out) |*c| {
        c.* = l + (c.* - l) * (1 - l) / (x - l);
    };
    return out;
}
fn setLum(v: m.V3, l: f32) m.V3 {
    const d = l - lum(v);
    return clip(.{ v[0] + d, v[1] + d, v[2] + d });
}
fn sat(v: m.V3) f32 {
    return @max(v[0], @max(v[1], v[2])) - @min(v[0], @min(v[1], v[2]));
}
fn setSat(v: m.V3, s: f32) m.V3 {
    const n = @min(v[0], @min(v[1], v[2]));
    const d = sat(v);
    return if (d <= 1e-6) .{ 0, 0, 0 } else .{ (v[0] - n) * s / d, (v[1] - n) * s / d, (v[2] - n) * s / d };
}
fn unpack(v: m.V3) m.V3 {
    return .{ v[0] * 2 - 1, v[1] * 2 - 1, v[2] * 2 - 1 };
}
fn pack(v: m.V3) m.V3 {
    return m.add(m.scale(v, 0.5 / @max(m.length(v), 1e-6)), .{ 0.5, 0.5, 0.5 });
}
pub fn rnm(a: m.V3, b: m.V3) m.V3 {
    var t = unpack(a);
    t[2] += 1;
    var u = unpack(b);
    u[0] = -u[0];
    u[1] = -u[1];
    return pack(m.sub(m.scale(t, m.dot(t, u)), m.scale(u, t[2])));
}
pub fn rgb(mode: Mode, a: m.V3, b: m.V3) m.V3 {
    return switch (mode) {
        .color => setLum(b, lum(a)),
        .saturation => setLum(setSat(a, sat(b)), lum(a)),
        .value => if (@max(a[0], @max(a[1], a[2])) <= 1e-6) @splat(@max(b[0], @max(b[1], b[2]))) else m.scale(a, @max(b[0], @max(b[1], b[2])) / @max(a[0], @max(a[1], a[2]))),
        .tint => m.scale(b, lum(a)),
        .normal_map_combine => blk: {
            const na = unpack(a);
            const nb = unpack(b);
            break :blk pack(.{ na[0] + nb[0], na[1] + nb[1], na[2] * nb[2] });
        },
        .normal_map_detail => rnm(a, b),
        .normal_map_inverse_detail => rnm(b, a),
        else => .{ scalar(mode, a[0], b[0]), scalar(mode, a[1], b[1]), scalar(mode, a[2], b[2]) },
    };
}
test "normal detail preserves flat base" {
    const result = rnm(.{ 0.5, 0.5, 1 }, .{ 0.6, 0.5, 0.98 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), result[0], 0.003);
}

test "all 32 blend modes match 2592 unchanged Rust observations" {
    const Case = struct { mode: u8, a: m.V3, b: m.V3, rgb: m.V3, scalar: f32 };
    const parsed = try std.json.parseFromSlice([]Case, std.testing.allocator, @embedFile("fixtures/blend-goldens.json"), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2592), parsed.value.len);
    for (parsed.value) |c| {
        const mode: Mode = @enumFromInt(c.mode);
        try std.testing.expectApproxEqRel(c.scalar + 1, scalar(mode, c.a[0], c.b[0]) + 1, 1e-5);
        const result = rgb(mode, c.a, c.b);
        for (c.rgb, result) |expected, actual| try std.testing.expectApproxEqAbs(expected, actual, 2e-5);
    }
}
