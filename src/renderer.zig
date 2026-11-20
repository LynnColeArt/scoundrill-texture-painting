//! Zig-owned persistent scene and progressive Vulkan path tracer.
const std = @import("std");
const core = @import("texture_painting");
const m = core.math;
const g = core.geometry;
pub const gpu = @import("vulkan.zig");
const raster_backend = @import("raster.zig");
pub const PreviewSettings = struct { light: [4]f32 = .{ -0.5, 1, 0.5, 3 }, color: [3]f32 = .{ 1, 1, 1 }, exposure: f32 = 1, filmic: bool = true, shadows: bool = true };
pub const Material = struct {
    width: u32 = 1,
    height: u32 = 1,
    rgba: []const [4]u16 = &.{},
    base: m.V3 = .{ 0.5, 0.5, 0.5 },
    opacity: f32 = 1,
    roughness: f32 = 0.5,
    metallic: f32 = 0,
    emissive: m.V3 = .{ 0, 0, 0 },
    normal: []const [3]u16 = &.{},
    height_map: []const u16 = &.{},
    roughness_map: []const u16 = &.{},
    metallic_map: []const u16 = &.{},
    height_strength: f32 = 0,
};
const Sampling = struct { bounces: u32, legacy: bool, lens: f32, focus: f32, ior: f32 };
pub const Settings = struct {
    bounces: u32 = 7,
    denoise: bool = true,
    exposure: f32 = 1,
    filmic: bool = false,
    environment_opacity: f32 = 1,
    legacy_bounds_offset: bool = true,
    lens_radius: f32 = 0,
    focus: f32 = 0,
    ior: f32 = 1.5,
    pub fn validate(self: Settings) !void {
        if (!std.math.isFinite(self.exposure) or self.exposure < 0 or self.exposure > 1e6 or !std.math.isFinite(self.environment_opacity) or self.environment_opacity < 0 or self.environment_opacity > 1 or !std.math.isFinite(self.lens_radius) or self.lens_radius < 0 or self.lens_radius > 1e4 or !std.math.isFinite(self.focus) or self.focus < 0 or self.focus > 1e12 or !std.math.isFinite(self.ior) or self.ior < 1 or self.ior > 5) return error.InvalidSettings;
    }
};
pub const Params = extern struct { inv_vp: [16]f32, forward: [4]f32, size: [4]u32, cfg: [4]u32, env: [4]f32, sigma: [4]f32, eye: [4]f32, lens: [4]f32, sets: [256][4]f32 };
const Post = extern struct { size: [4]u32, display: [4]f32, top: [4]f32, bottom: [4]f32 };
pub const Stats = struct { geometry_uploads: u64 = 0, material_uploads: u64 = 0, uploaded_bytes: u64 = 0, dispatches: u64 = 0, accumulation_resets: u64 = 0 };
pub const Renderer = struct {
    allocator: std.mem.Allocator,
    ctx: gpu.Context,
    trace: gpu.Program = .{},
    init_post: gpu.Program = .{},
    step_post: gpu.Program = .{},
    resolve: gpu.Program = .{},
    buffers: [12]gpu.Buffer = @splat(.{}),
    post: gpu.Buffer = .{},
    illum: [2]gpu.Buffer = @splat(.{}),
    output: gpu.Buffer = .{},
    width: u32 = 0,
    height: u32 = 0,
    samples: u32 = 0,
    sets: [256][4]f32 = @splat(.{ 1, 1, 255, 0 }),
    offsets: [2048]u32 = @splat(0),
    material_count: u32 = 0,
    environment: m.V3 = .{ 0.5, 0.5, 0.5 },
    bounds: g.Bounds = .{},
    stats: Stats = .{},
    last_camera: ?m.Camera = null,
    last_sampling: ?Sampling = null,
    raster: ?raster_backend.Raster = null,
    raster_params: gpu.Buffer = .{},
    triangle_count: u32 = 0,
    srgb_lut: [4096]u8 = undefined,
    pub fn init(a: std.mem.Allocator) !Renderer {
        var self: Renderer = .{ .allocator = a, .ctx = try gpu.Context.init(a) };
        errdefer self.deinit();
        for (&self.srgb_lut, 0..) |*v, i| v.* = m.u8of(m.srgb((@as(f32, @floatFromInt(i)) + 0.5) / 4096));
        self.trace = try gpu.Program.init(&self.ctx, @embedFile("spirv/trace_main.spv"), "trace_main", 12);
        self.init_post = try gpu.Program.init(&self.ctx, @embedFile("spirv/denoise_init.spv"), "denoise_init", 8);
        self.step_post = try gpu.Program.init(&self.ctx, @embedFile("spirv/denoise_step.spv"), "denoise_step", 8);
        self.resolve = try gpu.Program.init(&self.ctx, @embedFile("spirv/resolve.spv"), "resolve", 8);
        self.buffers[0] = try gpu.Buffer.init(&self.ctx, @sizeOf(Params), true);
        const align_bytes = @max(@as(usize, 256), self.ctx.properties.limits.minUniformBufferOffsetAlignment);
        self.post = try gpu.Buffer.init(&self.ctx, align_bytes * 6, true);
        return self;
    }
    pub fn deinit(self: *Renderer) void {
        _ = gpu.c.vkDeviceWaitIdle(self.ctx.device);
        if (self.raster) |*raster| raster.deinit(&self.ctx);
        self.raster_params.deinit(&self.ctx);
        self.trace.deinit(&self.ctx);
        self.init_post.deinit(&self.ctx);
        self.step_post.deinit(&self.ctx);
        self.resolve.deinit(&self.ctx);
        for (&self.buffers) |*b| b.deinit(&self.ctx);
        self.post.deinit(&self.ctx);
        for (&self.illum) |*b| b.deinit(&self.ctx);
        self.output.deinit(&self.ctx);
        self.ctx.deinit();
        self.* = undefined;
    }
    fn replaceMany(self: *Renderer, indices: []const usize, data: []const []const u8) !void {
        if (indices.len > 3 or indices.len != data.len) return error.DeviceLimit;
        var next: [3]gpu.Buffer = @splat(.{});
        errdefer for (&next) |*b| b.deinit(&self.ctx);
        for (data, 0..) |bytes, i| {
            next[i] = try gpu.Buffer.init(&self.ctx, bytes.len, false);
            try next[i].write(bytes);
        }
        for (indices, data, 0..) |index, bytes, i| {
            self.buffers[index].deinit(&self.ctx);
            self.buffers[index] = next[i];
            self.stats.uploaded_bytes += bytes.len;
        }
    }
    pub fn setMesh(self: *Renderer, mesh: g.Mesh, bvh: *const g.Bvh) !void {
        try mesh.validate();
        const tangents = if (mesh.tangents.len == mesh.positions.len) mesh.tangents else try g.computeTangents(self.allocator, mesh);
        defer if (mesh.tangents.len != mesh.positions.len) self.allocator.free(tangents);
        if (bvh.order.len != mesh.indices.len / 3) return error.InvalidBvh;
        var nodes: std.ArrayList([4]u32) = .empty;
        defer nodes.deinit(self.allocator);
        // Only reachable nodes are serialized. Builder allocates capacity for later refits.
        var used: usize = 1;
        var ni: usize = 0;
        while (ni < used) : (ni += 1) {
            const n = bvh.nodes[ni];
            if (n.count == 0) used = @max(used, n.first + 2);
            try nodes.append(self.allocator, bits(n.bounds.lo, n.first));
            try nodes.append(self.allocator, bits(n.bounds.hi, n.count));
        }
        var triangles = try self.allocator.alloc([4]u32, bvh.order.len * 4);
        defer self.allocator.free(triangles);
        for (bvh.order, 0..) |orig, i| {
            const ids = mesh.indices[orig * 3 ..][0..3];
            const sign: f32 = tangents[ids[0]][3];
            for (0..3) |k| triangles[i * 4 + k] = bits(mesh.positions[ids[k]], switch (k) {
                0 => if (mesh.materials.len > 0) mesh.materials[orig] else 0,
                1 => @bitCast(sign),
                else => 0,
            });
            triangles[i * 4 + 3] = .{ ids[0], ids[1], ids[2], orig };
        }
        var vertices = try self.allocator.alloc([4]f32, mesh.positions.len * 2);
        defer self.allocator.free(vertices);
        for (mesh.normals, mesh.uvs, 0..) |n, uv, i| {
            const t: m.V3 = tangents[i][0..3].*;
            vertices[i * 2] = .{ n[0], n[1], n[2], uv[0] };
            vertices[i * 2 + 1] = .{ t[0], t[1], t[2], uv[1] };
        }
        try self.replaceMany(&.{ 1, 2, 3 }, &.{ std.mem.sliceAsBytes(nodes.items), std.mem.sliceAsBytes(triangles), std.mem.sliceAsBytes(vertices) });
        self.bounds = .{};
        for (mesh.positions) |position| self.bounds.grow(position);
        self.triangle_count = @intCast(mesh.indices.len / 3);
        self.stats.geometry_uploads += 1;
        self.reset();
    }
    pub fn setEnvironment(self: *Renderer, color: m.V3) !void {
        if (!m.finite(color) or @reduce(.Min, @as(@Vector(3, f32), color)) < 0) return error.InvalidEnvironment;
        const w = 64;
        const h = 32;
        var env_pixels: [w * h][4]f32 = undefined;
        for (&env_pixels) |*p| p.* = .{ color[0], color[1], color[2], 1 };
        var cdf: [h + w * h * 2]f32 = undefined;
        var weights: [w * h]f32 = undefined;
        const luminance = color[0] * 0.2126 + color[1] * 0.7152 + color[2] * 0.0722;
        for (0..h) |y| {
            const sin = @sin(@as(f32, std.math.pi) * (@as(f32, @floatFromInt(y)) + 0.5) / h);
            for (0..w) |x| weights[y * w + x] = (luminance + 1e-4) * sin;
        }
        var total: f32 = 0;
        for (weights) |v| total += v;
        for (weights, 0..) |v, i| cdf[h + w * h + i] = v / total;
        var rows: f32 = 0;
        for (0..h) |y| {
            var sum: f32 = 0;
            for (0..w) |x| sum += cdf[h + w * h + y * w + x];
            rows += sum;
            cdf[y] = rows;
            var column: f32 = 0;
            for (0..w) |x| {
                column += cdf[h + w * h + y * w + x] / sum;
                cdf[h + y * w + x] = column;
            }
        }
        try self.replaceMany(&.{ 4, 9 }, &.{ std.mem.sliceAsBytes(&cdf), std.mem.sliceAsBytes(&env_pixels) });
        self.environment = color;
        self.reset();
    }
    pub fn setMaterials(self: *Renderer, materials: []const Material) !void {
        if (materials.len == 0 or materials.len > 255) return error.MaterialBudget;
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(self.allocator);
        var sets: [256][4]f32 = @splat(.{ 1, 1, 255, 0 });
        var offsets: [2048]u32 = @splat(0);
        for (0..materials.len + 1) |i| {
            const mat = if (i < materials.len) materials[i] else Material{};
            if (mat.width == 0 or mat.height == 0 or mat.width > 8192 or mat.height > 8192 or @as(u64, mat.width) * mat.height > 16_777_216 or !m.finite(mat.base) or !m.finite(mat.emissive) or !std.math.isFinite(mat.roughness) or !std.math.isFinite(mat.metallic)) return error.InvalidMaterial;
            const area = @as(usize, mat.width) * mat.height;
            var mask: u32 = 255;
            if (mat.rgba.len != 0 and mat.rgba.len != area) return error.InvalidMaterial;
            inline for (.{ mat.normal, mat.height_map, mat.roughness_map, mat.metallic_map }) |lane| {
                if (lane.len != 0 and lane.len != area) return error.InvalidMaterial;
            }
            for (0..8) |k| {
                offsets[i * 8 + k] = @intCast(words.items.len);
                const large = switch (k) {
                    0 => mat.rgba.len > 0,
                    1 => mat.roughness_map.len > 0 or mat.metallic_map.len > 0,
                    2 => mat.normal.len > 0,
                    3 => mat.height_map.len > 0,
                    else => false,
                };
                if (large) mask &= ~(@as(u32, 1) << @intCast(k));
                const count = if (large) area else 1;
                if (words.items.len + count * (if (k == 2 or k == 3) @as(usize, 2) else 1) > self.ctx.properties.limits.maxStorageBufferRange / 4) return error.MaterialBudget;
                try words.ensureUnusedCapacity(self.allocator, count * (if (k == 2 or k == 3) @as(usize, 2) else 1));
                for (0..count) |p| {
                    switch (k) {
                        0 => {
                            var col: [4]u8 = .{ m.u8of(m.srgb(mat.base[0])), m.u8of(m.srgb(mat.base[1])), m.u8of(m.srgb(mat.base[2])), m.u8of(mat.opacity) };
                            if (mat.rgba.len > 0) {
                                for (0..3) |c| col[c] = self.srgb_lut[mat.rgba[p][c] >> 4];
                                col[3] = @intCast(mat.rgba[p][3] >> 8);
                            }
                            words.appendAssumeCapacity(@bitCast(col));
                        },
                        1 => words.appendAssumeCapacity(@bitCast([4]u8{ 255, if (mat.roughness_map.len > 0) @intCast(mat.roughness_map[p] >> 8) else @intCast(m.u16of(mat.roughness) >> 8), if (mat.metallic_map.len > 0) @intCast(mat.metallic_map[p] >> 8) else @intCast(m.u16of(mat.metallic) >> 8), 128 })),
                        2 => {
                            var normal: [4]f32 = .{ 0, 0, 1, 0.5 };
                            if (mat.normal.len > 0) for (0..3) |c| {
                                normal[c] = @as(f32, @floatFromInt(mat.normal[p][c])) / 65535 * 2 - 1;
                            };
                            appendHalf(&words, normal);
                        },
                        3 => {
                            const height = if (mat.height_map.len > 0) (@as(f32, @floatFromInt(mat.height_map[p])) - 32768) / 32767 else 0;
                            appendHalf(&words, .{ height, 0.04, 0.04, 0.04 });
                        },
                        4 => words.appendAssumeCapacity(@bitCast([4]u8{ m.u8of(m.srgb(mat.emissive[0])), m.u8of(m.srgb(mat.emissive[1])), m.u8of(m.srgb(mat.emissive[2])), 0 })),
                        5 => words.appendAssumeCapacity(@bitCast([4]u8{ 0, 25, 0, 0 })),
                        6 => words.appendAssumeCapacity(@bitCast([4]u8{ 255, 255, 255, 0 })),
                        7 => words.appendAssumeCapacity(@bitCast([4]u8{ 128, 128, 0, 0 })),
                        else => unreachable,
                    }
                }
            }
            sets[i] = .{ @floatFromInt(mat.width), @floatFromInt(mat.height), @floatFromInt(mask), mat.height_strength };
        }
        try self.replaceMany(&.{ 10, 11 }, &.{ std.mem.sliceAsBytes(words.items), std.mem.sliceAsBytes(&offsets) });
        self.sets = sets;
        self.offsets = offsets;
        self.material_count = @intCast(materials.len);
        self.stats.material_uploads += 1;
        self.reset();
    }
    pub fn updateBaseRegion(self: *Renderer, material: u32, x: u32, y: u32, w: u32, h: u32, rgba: []const [4]u16) !void {
        if (material >= self.material_count or rgba.len != @as(u64, w) * h) return error.InvalidRegion;
        const info = self.sets[material];
        const width: u32 = @intFromFloat(info[0]);
        const height: u32 = @intFromFloat(info[1]);
        if (x > width or y > height or w > width - x or h > height - y) return error.InvalidRegion;
        try self.denseKind(material, 0);
        const base = self.offsets[material * 8];
        for (0..h) |dy| for (0..w) |dx| {
            const p = rgba[dy * w + dx];
            const word: u32 = @bitCast([4]u8{ self.srgb_lut[p[0] >> 4], self.srgb_lut[p[1] >> 4], self.srgb_lut[p[2] >> 4], @intCast(p[3] >> 8) });
            const at = (base + (@as(usize, y) + dy) * width + x + dx) * 4;
            @memcpy(self.buffers[10].bytes[at..][0..4], std.mem.asBytes(&word));
        };
        self.stats.uploaded_bytes += @as(u64, w) * h * 4;
        self.stats.material_uploads += 1;
        self.reset();
    }
    fn denseKind(self: *Renderer, material: u32, kind: u32) !void {
        if (material >= self.material_count or kind > 7) return error.InvalidMaterial;
        const mask: u32 = @intFromFloat(self.sets[material][2]);
        if (mask & (@as(u32, 1) << @intCast(kind)) == 0) return;
        const width: usize = @intFromFloat(self.sets[material][0]);
        const height: usize = @intFromFloat(self.sets[material][1]);
        const stride: usize = if (kind == 2 or kind == 3) 8 else 4;
        const previous = self.buffers[10];
        const size = previous.bytes.len + width * height * stride;
        var next = try gpu.Buffer.init(&self.ctx, size, false);
        errdefer next.deinit(&self.ctx);
        @memcpy(next.bytes[0..previous.bytes.len], previous.bytes);
        const offset = self.offsets[material * 8 + kind] * 4;
        const value = previous.bytes[offset..][0..stride];
        for (0..width * height) |i| @memcpy(next.bytes[previous.bytes.len + i * stride ..][0..stride], value);
        self.offsets[material * 8 + kind] = @intCast(previous.bytes.len / 4);
        self.sets[material][2] = @floatFromInt(mask & ~(@as(u32, 1) << @intCast(kind)));
        self.buffers[10] = next;
        var old = previous;
        old.deinit(&self.ctx);
        try self.buffers[11].write(std.mem.sliceAsBytes(&self.offsets));
        self.stats.uploaded_bytes += width * height * stride;
    }
    pub fn updatePackedRegion(self: *Renderer, material: u32, kind: u32, x: u32, y: u32, w: u32, h: u32, words: []const u32) !void {
        if (material >= self.material_count or kind > 7) return error.InvalidMaterial;
        const stride: usize = if (kind == 2 or kind == 3) 2 else 1;
        const width: u32 = @intFromFloat(self.sets[material][0]);
        const height: u32 = @intFromFloat(self.sets[material][1]);
        if (x > width or y > height or w > width - x or h > height - y or words.len != @as(u64, w) * h * stride) return error.InvalidRegion;
        try self.denseKind(material, kind);
        const base = self.offsets[material * 8 + kind];
        for (0..h) |dy| {
            const offset = (@as(usize, base) + ((@as(usize, y) + dy) * width + x) * stride) * 4;
            @memcpy(self.buffers[10].bytes[offset..][0 .. w * stride * 4], std.mem.sliceAsBytes(words[dy * w * stride ..][0 .. w * stride]));
        }
        self.stats.uploaded_bytes += words.len * 4;
        self.stats.material_uploads += 1;
        self.reset();
    }
    pub fn resize(self: *Renderer, w: u32, h: u32) !void {
        if (w == 0 or h == 0 or w > 3840 or h > 2160) return error.ImageBudget;
        if (self.width == w and self.height == h) return;
        var acc: [4]gpu.Buffer = @splat(.{});
        errdefer for (&acc) |*b| b.deinit(&self.ctx);
        var illum: [2]gpu.Buffer = @splat(.{});
        errdefer for (&illum) |*b| b.deinit(&self.ctx);
        const bytes: usize = 16;
        for (&acc) |*b| b.* = try gpu.Buffer.init(&self.ctx, bytes, false);
        for (&illum) |*b| b.* = try gpu.Buffer.init(&self.ctx, bytes, false);
        const out = try gpu.Buffer.init(&self.ctx, @as(usize, w) * h * 4, false);
        for (&self.buffers[5..9].*) |*b| b.deinit(&self.ctx);
        @memcpy(self.buffers[5..9], &acc);
        for (&self.illum) |*b| b.deinit(&self.ctx);
        self.illum = illum;
        self.output.deinit(&self.ctx);
        self.output = out;
        self.width = w;
        self.height = h;
        self.reset();
    }
    fn ensureAccumulation(self: *Renderer) !void {
        const bytes = @as(usize, self.width) * self.height * 16;
        if (self.buffers[5].bytes.len == bytes) return;
        var acc: [4]gpu.Buffer = @splat(.{});
        errdefer for (&acc) |*b| b.deinit(&self.ctx);
        var illum: [2]gpu.Buffer = @splat(.{});
        errdefer for (&illum) |*b| b.deinit(&self.ctx);
        for (&acc) |*b| b.* = try gpu.Buffer.init(&self.ctx, bytes, false);
        for (&illum) |*b| b.* = try gpu.Buffer.init(&self.ctx, bytes, false);
        for (&self.buffers[5..9].*) |*b| b.deinit(&self.ctx);
        @memcpy(self.buffers[5..9], &acc);
        for (&self.illum) |*b| b.deinit(&self.ctx);
        self.illum = illum;
        self.reset();
    }
    pub fn preview(self: *Renderer, camera: m.Camera, settings: PreviewSettings, readback: bool) !?[]const u8 {
        try camera.validate();
        if (self.width == 0 or self.material_count == 0 or self.triangle_count == 0 or self.buffers[9].handle == null) return error.SceneNotReady;
        if (!m.finite(settings.color) or !std.math.isFinite(settings.exposure) or settings.exposure < 0) return error.InvalidSettings;
        for (settings.light) |v| if (!std.math.isFinite(v)) return error.InvalidLight;
        if (self.raster == null) {
            var next = try raster_backend.Raster.init(&self.ctx);
            errdefer next.deinit(&self.ctx);
            const uniform = try gpu.Buffer.init(&self.ctx, 64, true);
            self.raster = next;
            self.raster_params = uniform;
        }
        const r = &self.raster.?;
        try r.resize(&self.ctx, self.width, self.height);
        const f = camera.forward();
        const e = camera.eye();
        const params: Params = .{ .inv_vp = m.inverse4(camera.inverseVP(@as(f32, @floatFromInt(self.width)) / @as(f32, @floatFromInt(self.height)))), .forward = .{ f[0], f[1], f[2], @max(1e-7, camera.scene_radius * 2e-6) }, .size = .{ self.width, self.height, 0, 1 }, .cfg = .{ 1, 0, 1, self.material_count }, .env = .{ 0, 1, 64, 32 }, .sigma = .{ 1, 1, 1, 0 }, .eye = .{ e[0], e[1], e[2], 1 }, .lens = .{ camera.distance, 0, 1.5, 0 }, .sets = self.sets };
        try self.buffers[0].write(std.mem.asBytes(&params));
        const raw: [4][4]f32 = .{ settings.light, .{ settings.color[0], settings.color[1], settings.color[2], 0 }, .{ settings.exposure, if (settings.filmic) 1 else 0, 0, if (settings.shadows) 1 else 0 }, .{ self.environment[0], self.environment[1], self.environment[2], 0 } };
        try self.raster_params.write(std.mem.asBytes(&raw));
        r.bind(&self.ctx, &self.buffers, &self.raster_params);
        try self.ctx.begin();
        r.draw(&self.ctx, self.triangle_count, if (readback) &self.output else null, .{ m.srgb(self.environment[0]), m.srgb(self.environment[1]), m.srgb(self.environment[2]), 1 });
        try self.ctx.submit();
        self.last_camera = null;
        self.reset();
        return if (readback) self.output.bytes[0 .. @as(usize, self.width) * self.height * 4] else null;
    }
    pub fn reset(self: *Renderer) void {
        self.samples = 0;
        self.stats.accumulation_resets += 1;
    }
    pub fn pass(self: *Renderer, camera: m.Camera, settings: Settings, spp: u32) !void {
        try camera.validate();
        try settings.validate();
        if (self.width == 0 or self.material_count == 0 or self.buffers[1].handle == null or self.buffers[9].handle == null) return error.SceneNotReady;
        if (spp == 0 or spp > 64 or settings.bounces == 0 or settings.bounces > 32 or self.samples > 65536 - spp) return error.SampleBudget;
        try self.ensureAccumulation();
        const sampling: Sampling = .{ .bounces = settings.bounces, .legacy = settings.legacy_bounds_offset, .lens = settings.lens_radius, .focus = settings.focus, .ior = settings.ior };
        if (self.last_camera == null or self.last_sampling == null or !std.meta.eql(sampling, self.last_sampling.?) or !std.meta.eql(camera, self.last_camera.?)) {
            self.reset();
            self.last_camera = camera;
            self.last_sampling = sampling;
        }
        if (self.samples == 0) for (self.buffers[5..9]) |b| {
            @memset(b.bytes, 0);
        };
        const f = camera.forward();
        const e = camera.eye();
        const eps = if (settings.legacy_bounds_offset) @max(1e-6, m.length(m.sub(self.bounds.hi, self.bounds.lo)) * 2e-5) else @max(1e-7, camera.scene_radius * 2e-6);
        var params: Params = .{ .inv_vp = camera.inverseVP(@as(f32, @floatFromInt(self.width)) / @as(f32, @floatFromInt(self.height))), .forward = .{ f[0], f[1], f[2], eps }, .size = .{ self.width, self.height, self.samples, spp }, .cfg = .{ settings.bounces, 0, 1, self.material_count }, .env = .{ 0, 1, 64, 32 }, .sigma = .{ 1, 1, 1, 0 }, .eye = .{ e[0], e[1], e[2], 1 }, .lens = .{ if (settings.focus > 0) settings.focus else camera.distance, settings.lens_radius, settings.ior, 0 }, .sets = self.sets };
        try self.buffers[0].write(std.mem.asBytes(&params));
        var views: [12]gpu.View = undefined;
        for (&self.buffers, &views) |*b, *v| v.* = .{ .buffer = b };
        try self.trace.bind(&self.ctx, 0, &views);
        try self.ctx.begin();
        self.trace.dispatch(&self.ctx, 0, self.width, self.height);
        try self.ctx.submit();
        self.samples += spp;
        self.stats.dispatches += 1;
    }
    pub fn pixels(self: *Renderer, settings: Settings) ![]const u8 {
        try settings.validate();
        if (self.samples == 0) return error.NoSamples;
        const stride = self.post.bytes.len / 6;
        for ([_]u32{ 0, 1, 2, 4, 8, 16 }, 0..) |step, i| {
            const q: Post = .{ .size = .{ self.width, self.height, self.samples, step }, .display = .{ settings.exposure, if (settings.filmic) 1 else 0, settings.environment_opacity, if (settings.denoise) 1 else 0 }, .top = .{ 0.03, 0.03, 0.03, 0 }, .bottom = .{ 0.01, 0.01, 0.01, 0 } };
            @memcpy(self.post.bytes[i * stride ..][0..@sizeOf(Post)], std.mem.asBytes(&q));
            var views: [8]gpu.View = undefined;
            views[0] = .{ .buffer = &self.post, .offset = i * stride, .size = @sizeOf(Post) };
            for (0..4) |k| views[k + 1] = .{ .buffer = &self.buffers[k + 5] };
            views[5] = .{ .buffer = &self.illum[if (i == 0 or i % 2 == 0) @as(usize, 0) else 1] };
            views[6] = .{ .buffer = &self.illum[if (i == 0 or i % 2 == 0) @as(usize, 1) else 0] };
            views[7] = .{ .buffer = &self.output };
            if (i == 0) {
                try self.init_post.bind(&self.ctx, 0, &views);
                try self.resolve.bind(&self.ctx, 0, &views);
            } else try self.step_post.bind(&self.ctx, i, &views);
        }
        try self.ctx.begin();
        if (settings.denoise) {
            self.init_post.dispatch(&self.ctx, 0, self.width, self.height);
            for (1..6) |i| self.step_post.dispatch(&self.ctx, i, self.width, self.height);
        }
        self.resolve.dispatch(&self.ctx, 0, self.width, self.height);
        try self.ctx.submit();
        return self.output.bytes[0 .. @as(usize, self.width) * self.height * 4];
    }
};
fn bits(p: m.V3, w: u32) [4]u32 {
    return .{ @bitCast(p[0]), @bitCast(p[1]), @bitCast(p[2]), w };
}
fn tangent(n: m.V3) m.V3 {
    return m.norm(m.cross(if (@abs(n[1]) < 0.9) m.V3{ 0, 1, 0 } else m.V3{ 1, 0, 0 }, n));
}
fn appendHalf(list: *std.ArrayList(u32), v: [4]f32) void {
    const h: [4]u16 = .{ @bitCast(@as(f16, @floatCast(v[0]))), @bitCast(@as(f16, @floatCast(v[1]))), @bitCast(@as(f16, @floatCast(v[2]))), @bitCast(@as(f16, @floatCast(v[3]))) };
    list.appendAssumeCapacity(@as(u32, h[0]) | (@as(u32, h[1]) << 16));
    list.appendAssumeCapacity(@as(u32, h[2]) | (@as(u32, h[3]) << 16));
}
