//! Source-informed recovery of TextureCraft's procedural HDR lighting and IBL.
const std = @import("std");
const m = @import("texture_painting").math;
pub const Preset = enum {
    studio_soft,
    studio_contrast,
    overcast,
    sunset,
    warehouse,
    night,
    pub fn parse(name: []const u8) !Preset {
        const names = [_][]const u8{ "Studio Soft", "Studio Contrast", "Overcast", "Sunset", "Warehouse", "Night" };
        for (names, 0..) |s, i| if (std.ascii.eqlIgnoreCase(s, name)) return @enumFromInt(i);
        return error.UnknownEnvironment;
    }
};
pub const Image = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    pixels: []m.V3,
    pub fn init(a: std.mem.Allocator, w: u32, h: u32) !Image {
        if (w == 0 or h == 0 or w > 4096 or h > 4096 or @as(u64, w) * h > 16_777_216) return error.EnvironmentBudget;
        return .{ .allocator = a, .width = w, .height = h, .pixels = try a.alloc(m.V3, @as(usize, w) * h) };
    }
    pub fn deinit(self: *Image) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }
    pub fn clone(self: Image) !Image {
        return .{ .allocator = self.allocator, .width = self.width, .height = self.height, .pixels = try self.allocator.dupe(m.V3, self.pixels) };
    }
    fn get(self: Image, x: i64, y: i64) m.V3 {
        const xx: usize = @intCast(@mod(x, self.width));
        const yy: usize = @intCast(std.math.clamp(y, 0, self.height - 1));
        return self.pixels[yy * self.width + xx];
    }
    pub fn sample(self: Image, d: m.V3) m.V3 {
        if (!m.finite(d)) return .{ 0, 0, 0 };
        const uv = uvOf(d);
        const fx = uv[0] * @as(f32, @floatFromInt(self.width)) - 0.5;
        const fy = uv[1] * @as(f32, @floatFromInt(self.height)) - 0.5;
        const x: i64 = @intFromFloat(@floor(fx));
        const y: i64 = @intFromFloat(@floor(fy));
        const tx = fx - @floor(fx);
        const ty = fy - @floor(fy);
        return m.mix(m.mix(self.get(x, y), self.get(x + 1, y), tx), m.mix(self.get(x, y + 1), self.get(x + 1, y + 1), tx), ty);
    }
    pub fn half(self: Image) !Image {
        var result = try Image.init(self.allocator, @max(self.width / 2, 1), @max(self.height / 2, 1));
        for (0..result.height) |y| for (0..result.width) |x| {
            const sx: @TypeOf(@as(i64, 0)) = @intCast(x * 2);
            const sy: i64 = @intCast(y * 2);
            result.pixels[y * result.width + x] = m.scale(m.add(m.add(self.get(sx, sy), self.get(sx + 1, sy)), m.add(self.get(sx, sy + 1), self.get(sx + 1, sy + 1))), 0.25);
        };
        return result;
    }
};
pub fn dirOf(u: f32, v: f32) m.V3 {
    const theta = v * std.math.pi;
    const phi = u * std.math.tau;
    return .{ @sin(theta) * @cos(phi), @cos(theta), @sin(theta) * @sin(phi) };
}
pub fn uvOf(d: m.V3) m.V2 {
    return .{ @mod(std.math.atan2(d[2], d[0]) / std.math.tau, 1), std.math.acos(std.math.clamp(d[1], -1, 1)) / std.math.pi };
}
fn smooth(x: f32) f32 {
    const t = std.math.clamp(x, 0, 1);
    return t * t * (3 - 2 * t);
}
fn sky(d: m.V3, z: m.V3, h: m.V3, g: m.V3) m.V3 {
    return if (d[1] >= 0) m.mix(h, z, std.math.pow(f32, d[1], 0.6)) else m.mix(h, g, std.math.pow(f32, -d[1], 0.25));
}
fn box(d: m.V3, az: f32, el: f32, hw: f32, hh: f32, color: m.V3) m.V3 {
    const elevation = std.math.asin(std.math.clamp(d[1], -1, 1)) * 180 / std.math.pi;
    const angle = std.math.atan2(d[2], d[0]) * 180 / std.math.pi;
    const daz = @mod(angle - az + 540, 360) - 180;
    return m.scale(color, (1 - smooth((@abs(daz) / hw - 0.8) / 0.4)) * (1 - smooth((@abs(elevation - el) / hh - 0.8) / 0.4)));
}
pub fn radiance(preset: Preset, d: m.V3) m.V3 {
    return switch (preset) {
        .studio_soft => m.add(m.add(m.add(sky(d, .{ 0.5, 0.52, 0.56 }, .{ 0.32, 0.32, 0.33 }, .{ 0.08, 0.075, 0.07 }), box(d, 40, 35, 28, 20, .{ 5.5, 5.2, 4.8 })), box(d, -125, 20, 35, 22, .{ 1.1, 1.25, 1.5 })), box(d, 175, 55, 8, 25, .{ 3, 3, 3 })),
        .studio_contrast => m.add(m.add(sky(d, .{ 0.04, 0.04, 0.04 }, .{ 0.03, 0.03, 0.03 }, .{ 0.01, 0.01, 0.01 }), box(d, 35, 30, 22, 18, .{ 14, 13.2, 12 })), box(d, -150, 40, 6, 30, .{ 4, 4.4, 5 })),
        .overcast => m.add(sky(d, .{ 1.2, 1.25, 1.35 }, .{ 0.95, 0.95, 0.95 }, .{ 0.18, 0.2, 0.15 }), box(d, 60, 55, 40, 25, .{ 0.6, 0.6, 0.6 })),
        .sunset => m.add(sky(d, .{ 0.15, 0.25, 0.55 }, .{ 1.4, 0.65, 0.3 }, .{ 0.08, 0.06, 0.05 }), m.scale(.{ 1, 0.6, 0.3 }, smooth((m.dot(d, dirOf(0.12, 0.47)) - 0.9985) / 0.0012) * 120)),
        .warehouse => blk: {
            var c = sky(d, .{ 0.25, 0.25, 0.25 }, .{ 0.18, 0.18, 0.18 }, .{ 0.06, 0.06, 0.06 });
            for (0..6) |i| c = m.add(c, box(d, -150 + @as(f32, @floatFromInt(i)) * 60, 50, 6, 3, .{ 9, 8.5, 7.5 }));
            break :blk m.add(c, box(d, 90, 5, 30, 12, .{ 1.6, 1.8, 2.2 }));
        },
        .night => m.add(m.add(sky(d, .{ 0.01, 0.015, 0.04 }, .{ 0.03, 0.03, 0.06 }, .{ 0.005, 0.005, 0.005 }), box(d, 20, 15, 10, 10, .{ 0.4, 1.6, 4 })), box(d, -110, 10, 12, 8, .{ 4, 0.8, 1.6 })),
    };
}
pub fn generate(a: std.mem.Allocator, preset: Preset, width: u32) !Image {
    if (width < 16 or width > 4096 or width % 2 != 0) return error.EnvironmentBudget;
    var image = try Image.init(a, width, width / 2);
    for (0..image.height) |y| for (0..image.width) |x| {
        image.pixels[y * width + x] = radiance(preset, dirOf((@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(width)), (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(image.height))));
    };
    return image;
}
pub fn basis(d: m.V3) [9]f32 {
    const x = d[0];
    const y = d[1];
    const z = d[2];
    return .{ 0.282095, 0.488603 * y, 0.488603 * z, 0.488603 * x, 1.092548 * x * y, 1.092548 * y * z, 0.315392 * (3 * z * z - 1), 1.092548 * x * z, 0.546274 * (x * x - y * y) };
}
pub fn sh9(image: Image) ![9]m.V3 {
    var src = try image.clone();
    defer src.deinit();
    while (src.width > 128) {
        const next = try src.half();
        src.deinit();
        src = next;
    }
    var result: [9]m.V3 = @splat(.{ 0, 0, 0 });
    const wf: f32 = @floatFromInt(src.width);
    const hf: f32 = @floatFromInt(src.height);
    for (0..src.height) |y| {
        const theta = std.math.pi * (@as(f32, @floatFromInt(y)) + 0.5) / hf;
        const dw = (std.math.tau / wf) * (std.math.pi / hf) * @sin(theta);
        for (0..src.width) |x| {
            const d = dirOf((@as(f32, @floatFromInt(x)) + 0.5) / wf, (@as(f32, @floatFromInt(y)) + 0.5) / hf);
            const l = m.scale(src.pixels[y * src.width + x], dw);
            for (basis(d), 0..) |ylm, k| result[k] = m.add(result[k], m.scale(l, ylm));
        }
    }
    const kernel = [_]f32{ 1, 2.0 / 3.0, 2.0 / 3.0, 2.0 / 3.0, 0.25, 0.25, 0.25, 0.25, 0.25 };
    for (&result, kernel) |*v, k| v.* = m.scale(v.*, k);
    return result;
}
pub const Mips = struct {
    images: [8]?Image = @splat(null),
    count: usize = 0,
    pub fn deinit(self: *Mips) void {
        for (&self.images) |*image| if (image.*) |*img| img.deinit();
        self.* = .{};
    }
};
pub fn prefilter(image: Image, levels: usize) !Mips {
    if (levels == 0 or levels > 8) return error.EnvironmentBudget;
    var result: Mips = .{};
    errdefer result.deinit();
    var pyramid: Mips = .{};
    defer pyramid.deinit();
    const base = try image.clone();
    pyramid.images[0] = base;
    pyramid.count = 1;
    for (pyramid.images[0].?.pixels) |*v| for (v) |*c| {
        c.* = @min(c.*, 64);
    };
    while (pyramid.count < 8 and pyramid.images[pyramid.count - 1].?.width > 8) {
        const next = try pyramid.images[pyramid.count - 1].?.half();
        pyramid.images[pyramid.count] = next;
        pyramid.count += 1;
    }
    const first = try image.clone();
    result.images[0] = first;
    result.count = 1;
    var w = image.width;
    var h = image.height;
    for (1..levels) |level| {
        w = @max(w / 2, 4);
        h = @max(h / 2, 2);
        const rough = @as(f32, @floatFromInt(level)) / @as(f32, @floatFromInt(levels - 1));
        const alpha = @max(rough * rough, 1e-3);
        const Sample = struct { half_vector: m.V3, weight: f32, source: usize };
        var table: [128]Sample = undefined;
        var n: usize = 0;
        var sum: f32 = 0;
        const texel_area = 4 * std.math.pi / (@as(f32, @floatFromInt(image.width)) * @as(f32, @floatFromInt(image.height)));
        for (0..128) |i| {
            const xi = @as(f32, @floatFromInt(@bitReverse(@as(u32, @intCast(i))))) * 2.3283064e-10;
            const phi = std.math.tau * @as(f32, @floatFromInt(i)) / 128;
            const co = @sqrt(@max((1 - xi) / (1 + (alpha * alpha - 1) * xi), 0));
            const si = @sqrt(@max(1 - co * co, 0));
            const weight = 2 * co * co - 1;
            if (weight <= 0) continue;
            const denominator = co * co * (alpha * alpha - 1) + 1;
            const dd = alpha * alpha / @max(std.math.pi * denominator * denominator, 1e-8);
            const sample_area = 1 / (128 * dd / 4 + 1e-6);
            const lod = std.math.clamp(0.5 * @log2(sample_area / texel_area) + 1, 0, @as(f32, @floatFromInt(pyramid.count - 1)));
            table[n] = .{ .half_vector = .{ si * @cos(phi), si * @sin(phi), co }, .weight = weight, .source = @intFromFloat(@floor(lod + 0.5)) };
            n += 1;
            sum += weight;
        }
        var output = try Image.init(image.allocator, w, h);
        errdefer output.deinit();
        const Job = struct {
            output: *Image,
            pyramid: *const Mips,
            table: []const Sample,
            sum: f32,
            fn run(job: *const @This(), start: usize, end: usize) void {
                const wf: f32 = @floatFromInt(job.output.width);
                const hf: f32 = @floatFromInt(job.output.height);
                for (start..end) |y| for (0..job.output.width) |x| {
                    const normal = dirOf((@as(f32, @floatFromInt(x)) + 0.5) / wf, (@as(f32, @floatFromInt(y)) + 0.5) / hf);
                    const t = m.norm(m.cross(if (@abs(normal[1]) < 0.999) m.V3{ 0, 1, 0 } else m.V3{ 1, 0, 0 }, normal));
                    const b = m.cross(normal, t);
                    var color: m.V3 = .{ 0, 0, 0 };
                    for (job.table) |sample| {
                        const hv = sample.half_vector;
                        const hw = m.add(m.add(m.scale(t, hv[0]), m.scale(b, hv[1])), m.scale(normal, hv[2]));
                        color = m.add(color, m.scale(job.pyramid.images[sample.source].?.sample(m.sub(m.scale(hw, 2 * hv[2]), normal)), sample.weight));
                    }
                    job.output.pixels[y * job.output.width + x] = m.scale(color, 1 / @max(job.sum, 1e-6));
                };
            }
        };
        const job: Job = .{ .output = &output, .pyramid = &pyramid, .table = table[0..n], .sum = sum };
        {
            var threads: [8]std.Thread = undefined;
            var started: usize = 0;
            defer for (threads[0..started]) |thread| thread.join();
            const workers = @min(@min(std.Thread.getCpuCount() catch 1, 8), h);
            for (0..workers) |i| {
                threads[i] = try std.Thread.spawn(.{}, Job.run, .{ &job, @as(usize, h) * i / workers, @as(usize, h) * (i + 1) / workers });
                started += 1;
            }
        }
        result.images[level] = output;
        result.count += 1;
    }
    return result;
}
test "uniform IBL remains finite and normalized" {
    const a = std.testing.allocator;
    var image = try Image.init(a, 32, 16);
    defer image.deinit();
    @memset(image.pixels, .{ 1, 1, 1 });
    const coeff = try sh9(image);
    var value: f32 = 0;
    for (coeff, basis(.{ 0, 1, 0 })) |c, y| value += c[0] * y;
    try std.testing.expectApproxEqAbs(@as(f32, 1), value, 0.04);
    var mips = try prefilter(image, 4);
    defer mips.deinit();
    for (mips.images[0..mips.count]) |img| for (img.?.pixels) |pixel| {
        try std.testing.expectApproxEqAbs(@as(f32, 1), pixel[0], 2e-5);
    };
}
