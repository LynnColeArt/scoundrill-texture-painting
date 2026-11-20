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
    if (material >= r.material_count or @as(u32, @intFromFloat(r.sets[material][0])) != s.document.width or @as(u32, @intFromFloat(r.sets[material][1])) != s.document.height) return error.InvalidMaterial;
    var rgba: [4096][4]u16 = undefined;
    var words: [8192]u32 = undefined;
    const tx = (s.document.width + 63) / 64;
    const doc = s.document;
    for (s.dirty, 0..) |dirty, i| {
        if (!dirty) continue;
        const x = @as(u32, @intCast(i % tx)) * 64;
        const y = @as(u32, @intCast(i / tx)) * 64;
        const w = @min(64, doc.width - x);
        const h = @min(64, doc.height - y);
        for (groups, 0..) |group, kind| {
            if (s.dirty_channels & group == 0) continue;
            if (kind == 0) {
                try doc.region(.base_color, x, y, w, h, rgba[0 .. @as(usize, w) * h]);
                try r.updateBaseRegion(material, x, y, w, h, rgba[0 .. @as(usize, w) * h]);
                continue;
            }
            const stride: usize = if (kind == 2 or kind == 3) 2 else 1;
            for (0..h) |dy| for (0..w) |dx| {
                const px = x + @as(u32, @intCast(dx));
                const py = y + @as(u32, @intCast(dy));
                const at = (dy * w + dx) * stride;
                switch (kind) {
                    1 => words[at] = four(.{ byte(doc.pixel(.ambient_occlusion, px, py)[0]), byte(doc.pixel(.roughness, px, py)[0]), byte(doc.pixel(.metallic, px, py)[0]), byte(doc.pixel(.specular_level, px, py)[0]) }),
                    2 => {
                        const n = doc.pixel(.normal, px, py);
                        words[at] = half(n[0] * 2 - 1, n[1] * 2 - 1);
                        words[at + 1] = half(n[2] * 2 - 1, doc.pixel(.sheen_roughness, px, py)[0]);
                    },
                    3 => {
                        const spec = doc.pixel(.specular, px, py);
                        words[at] = half(doc.pixel(.height, px, py)[0], spec[0]);
                        words[at + 1] = half(spec[1], spec[2]);
                    },
                    4, 6 => {
                        const color = doc.pixel(if (kind == 4) .emissive else .sheen_color, px, py);
                        words[at] = four(.{ r.srgb_lut[m.u16of(color[0]) >> 4], r.srgb_lut[m.u16of(color[1]) >> 4], r.srgb_lut[m.u16of(color[2]) >> 4], byte(doc.pixel(if (kind == 4) .scatter_weight else .sheen_weight, px, py)[0]) });
                    },
                    5 => words[at] = four(.{ byte(doc.pixel(.coat_weight, px, py)[0]), byte(doc.pixel(.coat_roughness, px, py)[0]), byte(doc.pixel(.anisotropy_level, px, py)[0]), byte(doc.pixel(.anisotropy_angle, px, py)[0]) }),
                    7 => {
                        const n = doc.pixel(.coat_normal, px, py);
                        words[at] = four(.{ m.u8of((128 + 127 * (n[0] * 2 - 1)) / 255), m.u8of((128 + 127 * (n[1] * 2 - 1)) / 255), byte(doc.pixel(.transmission, px, py)[0]), 0 });
                    },
                    else => unreachable,
                }
            };
            try r.updatePackedRegion(material, @intCast(kind), x, y, w, h, words[0 .. @as(usize, w) * h * stride]);
        }
    }
    s.clearDirty();
}
