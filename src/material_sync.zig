//! Optional bridge: authoring documents -> renderer dirty material regions.
const std = @import("std");
const core = @import("texture_painting");
const render = @import("renderer.zig");
const m = core.math;
const p = core.painting;
fn bit(ch: p.Channel) u32 {
    return @as(u32, 1) << @intFromEnum(ch);
}
const groups = [_]u32{
    bit(.base_color) | bit(.opacity),       bit(.roughness) | bit(.metallic) | bit(.ambient_occlusion) | bit(.specular_level) | bit(.glossiness),
    bit(.normal) | bit(.sheen_roughness),   bit(.height) | bit(.specular),
    bit(.emissive) | bit(.scatter_weight),  bit(.coat_weight) | bit(.coat_roughness) | bit(.anisotropy_level) | bit(.anisotropy_angle),
    bit(.sheen_color) | bit(.sheen_weight), bit(.coat_normal) | bit(.transmission),
};
fn byte(v: f32) u8 {
    return @intCast(m.u16of(v) >> 8);
}
fn four(v: [4]u8) u32 {
    return @bitCast(v);
}
fn half(a: f32, b: f32) u32 {
    const x: u16 = @bitCast(@as(f16, @floatCast(a)));
    const y: u16 = @bitCast(@as(f16, @floatCast(b)));
    return @as(u32, x) | (@as(u32, y) << 16);
}
pub fn apply(r: *render.Renderer, s: *p.Session, material: u32) !void {
    try applyCoverage(r, s, material, null);
}
pub fn applyCoverage(r: *render.Renderer, s: *p.Session, material: u32, coverage: ?core.texel.Image) !void {
    if (material >= r.material_count or @as(u32, @intFromFloat(r.sets[material][0])) != s.document.width or @as(u32, @intFromFloat(r.sets[material][1])) != s.document.height) return error.InvalidMaterial;
    if (coverage) |image| if (image.components != 1 or image.width != s.document.width or image.height != s.document.height) return error.InvalidCoverage;
    var rgba: [4096][4]u16 = undefined;
    var words: [8192]u32 = undefined;
    var lanes: [4][4096]m.V3 = undefined;
    const tx = (s.document.width + 63) / 64;
    const doc = s.document;
    for (s.dirty, 0..) |dirty, i| {
        if (!dirty) continue;
        var x = @as(u32, @intCast(i % tx)) * 64;
        var y = @as(u32, @intCast(i / tx)) * 64;
        var w: u32 = @min(64, doc.width - x);
        var h: u32 = @min(64, doc.height - y);
        if (coverage) |image| {
            const data = image.tile(@intCast(i % tx), @intCast(i / tx)) orelse continue;
            var lo: [2]u32 = .{ w, h };
            var hi: [2]u32 = .{ 0, 0 };
            for (0..h) |dy| for (0..w) |dx| {
                if (data[dy * 64 + dx] == 0) continue;
                lo[0] = @min(lo[0], @as(u32, @intCast(dx)));
                lo[1] = @min(lo[1], @as(u32, @intCast(dy)));
                hi[0] = @max(hi[0], @as(u32, @intCast(dx + 1)));
                hi[1] = @max(hi[1], @as(u32, @intCast(dy + 1)));
            };
            if (hi[0] <= lo[0] or hi[1] <= lo[1]) continue;
            x += lo[0];
            y += lo[1];
            w = hi[0] - lo[0];
            h = hi[1] - lo[1];
        }
        for (groups, 0..) |group, kind| {
            if (s.dirty_channels & group == 0) continue;
            if (kind == 0) {
                try doc.region(.base_color, x, y, w, h, rgba[0 .. @as(usize, w) * h]);
                try r.updateBaseRegion(material, x, y, w, h, rgba[0 .. @as(usize, w) * h]);
                continue;
            }
            const stride: usize = if (kind == 2 or kind == 3) 2 else 1;
            const channels: [4]?p.Channel = switch (kind) {
                1 => .{ .ambient_occlusion, if (r.specular_glossiness) .glossiness else .roughness, .metallic, .specular_level },
                2 => .{ .normal, .sheen_roughness, null, null },
                3 => .{ .height, .specular, null, null },
                4 => .{ .emissive, .scatter_weight, null, null },
                5 => .{ .coat_weight, .coat_roughness, .anisotropy_level, .anisotropy_angle },
                6 => .{ .sheen_color, .sheen_weight, null, null },
                7 => .{ .coat_normal, .transmission, null, null },
                else => unreachable,
            };
            for (channels, 0..) |channel, lane| if (channel) |ch| doc.composeTile(ch, @intCast(i % tx), @intCast(i / tx), &lanes[lane]);
            for (0..h) |dy| for (0..w) |dx| {
                const px = x + @as(u32, @intCast(dx));
                const py = y + @as(u32, @intCast(dy));
                const at = (dy * w + dx) * stride;
                const local = (py % 64) * 64 + px % 64;
                const a = lanes[0][local];
                const b = lanes[1][local];
                switch (kind) {
                    1 => words[at] = four(.{ byte(a[0]), byte(if (r.specular_glossiness) 1 - b[0] else b[0]), byte(lanes[2][local][0]), byte(lanes[3][local][0]) }),
                    2 => {
                        const n = a;
                        words[at] = half(n[0] * 2 - 1, n[1] * 2 - 1);
                        words[at + 1] = half(n[2] * 2 - 1, b[0]);
                    },
                    3 => {
                        const spec = b;
                        words[at] = half(a[0], spec[0]);
                        words[at + 1] = half(spec[1], spec[2]);
                    },
                    4, 6 => {
                        const color = a;
                        words[at] = four(.{ r.srgb_lut[m.u16of(color[0]) >> 4], r.srgb_lut[m.u16of(color[1]) >> 4], r.srgb_lut[m.u16of(color[2]) >> 4], byte(b[0]) });
                    },
                    5 => words[at] = four(.{ byte(a[0]), byte(b[0]), byte(lanes[2][local][0]), byte(lanes[3][local][0]) }),
                    7 => {
                        const n = a;
                        words[at] = four(.{ m.u8of((128 + 127 * (n[0] * 2 - 1)) / 255), m.u8of((128 + 127 * (n[1] * 2 - 1)) / 255), byte(b[0]), 0 });
                    },
                    else => unreachable,
                }
            };
            try r.updatePackedRegion(material, @intCast(kind), x, y, w, h, words[0 .. @as(usize, w) * h * stride]);
        }
    }
    s.clearDirty();
}
