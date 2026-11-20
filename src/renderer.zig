//! Zig-owned persistent scene and progressive Vulkan path tracer.
const std = @import("std");
const core = @import("texture_painting");
const m = core.math;
const g = core.geometry;
pub const gpu = @import("vulkan.zig");
const raster_backend = @import("raster.zig");
const envlib = @import("environment.zig");
pub const PreviewSettings = struct { light: [4]f32 = .{ -0.5, 1, 0.5, 3 }, color: [3]f32 = .{ 1, 1, 1 }, exposure: f32 = 1, filmic: bool = true, shadows: bool = true, environment_opacity: f32 = 1 };
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
const Sampling = struct { bounces: u32, legacy: bool, specular_glossiness: bool, lens: f32, focus: f32, ior: f32 };
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
pub const Stats = struct { geometry_uploads: u64 = 0, material_uploads: u64 = 0, uploaded_bytes: u64 = 0, dispatches: u64 = 0, accumulation_resets: u64 = 0, scene_buffer_allocations: u64 = 0 };
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
    material_words_used: usize = 0,
    specular_glossiness: bool = false,
    environment: m.V3 = .{ 0.5, 0.5, 0.5 },
    environment_size: [2]u32 = .{ 64, 32 },
    environment_rotation: f32 = 0,
    environment_sh: [9]m.V3 = @splat(.{ 0, 0, 0 }),
    environment_mips: [8][4]u32 = @splat(.{ 0, 0, 0, 0 }),
    environment_levels: u32 = 0,
    bounds: g.Bounds = .{},
    stats: Stats = .{},
    last_camera: ?m.Camera = null,
    last_sampling: ?Sampling = null,
    raster: ?raster_backend.Raster = null,
    raster_params: gpu.Buffer = .{},
    triangle_count: u32 = 0,
    srgb_lut: [4096]u8 = undefined,
    mesh_nodes: std.ArrayList([4]u32) = .empty,
    mesh_triangles: std.ArrayList([4]u32) = .empty,
    mesh_vertices: std.ArrayList([4]f32) = .empty,
    mesh_tangents: std.ArrayList(m.V4) = .empty,
    mesh_bitangents: std.ArrayList(m.V3) = .empty,
    pub fn init(a: std.mem.Allocator) !Renderer {
        return initDevice(a, .automatic);
    }
    pub fn initDevice(a: std.mem.Allocator, preference: gpu.Context.Device) !Renderer {
        var self: Renderer = .{ .allocator = a, .ctx = try gpu.Context.initDevice(a, preference) };
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
        self.mesh_nodes.deinit(self.allocator);
        self.mesh_triangles.deinit(self.allocator);
        self.mesh_vertices.deinit(self.allocator);
        self.mesh_tangents.deinit(self.allocator);
        self.mesh_bitangents.deinit(self.allocator);
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
            if (self.buffers[indices[i]].bytes.len != @max(bytes.len, 16)) next[i] = try gpu.Buffer.init(&self.ctx, bytes.len, false);
        }
        for (indices, data, 0..) |index, bytes, i| {
            if (next[i].handle != null) {
                self.buffers[index].deinit(&self.ctx);
                self.buffers[index] = next[i];
                self.stats.scene_buffer_allocations += 1;
            }
            // All allocations succeeded before any resident data is changed.
            @memcpy(self.buffers[index].bytes[0..bytes.len], bytes);
            self.stats.uploaded_bytes += bytes.len;
        }
    }
    pub fn setMesh(self: *Renderer, mesh: g.Mesh, bvh: *const g.Bvh) !void {
        try mesh.validate();
        if (bvh.order.len != mesh.indices.len / 3) return error.InvalidBvh;
        const tangents = if (mesh.tangents.len == mesh.positions.len) mesh.tangents else blk: {
            try self.mesh_tangents.resize(self.allocator, mesh.positions.len);
            try self.mesh_bitangents.resize(self.allocator, mesh.positions.len);
            try g.computeTangentsInto(mesh, self.mesh_tangents.items, self.mesh_bitangents.items);
            break :blk self.mesh_tangents.items;
        };
        self.mesh_nodes.clearRetainingCapacity();
        // Only reachable nodes are serialized. Builder allocates capacity for later refits.
        var used: usize = if (bvh.order.len == 0) 0 else 1;
        var ni: usize = 0;
        while (ni < used) : (ni += 1) {
            const n = bvh.nodes[ni];
            if (n.count == 0) used = @max(used, n.first + 2);
            try self.mesh_nodes.append(self.allocator, bits(n.bounds.lo, n.first));
            try self.mesh_nodes.append(self.allocator, bits(n.bounds.hi, n.count));
        }
        try self.mesh_triangles.resize(self.allocator, @max(1, bvh.order.len) * 4);
        const triangles = self.mesh_triangles.items;
        if (bvh.order.len == 0) {
            try self.mesh_nodes.appendSlice(self.allocator, &.{ bits(.{ 0, 0, 0 }, 0), bits(.{ 0, 0, 0 }, 1) });
            @memset(triangles, .{ 0, 0, 0, 0 });
        }
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
        try self.mesh_vertices.resize(self.allocator, @max(1, mesh.positions.len) * 2);
        const vertices = self.mesh_vertices.items;
        if (mesh.positions.len == 0) @memset(vertices, .{ 0, 0, 0, 0 });
        for (mesh.normals, mesh.uvs, 0..) |n, uv, i| {
            const t: m.V3 = tangents[i][0..3].*;
            vertices[i * 2] = .{ n[0], n[1], n[2], uv[0] };
            vertices[i * 2 + 1] = .{ t[0], t[1], t[2], uv[1] };
        }
        try self.replaceMany(&.{ 1, 2, 3 }, &.{ std.mem.sliceAsBytes(self.mesh_nodes.items), std.mem.sliceAsBytes(triangles), std.mem.sliceAsBytes(vertices) });
        self.bounds = .{};
        for (mesh.positions) |position| self.bounds.grow(position);
        if (mesh.positions.len == 0) self.bounds = .{ .lo = .{ 0, 0, 0 }, .hi = .{ 0, 0, 0 } };
        self.triangle_count = @intCast(mesh.indices.len / 3);
        self.stats.geometry_uploads += 1;
        self.reset();
    }
    pub fn setEnvironment(self: *Renderer, color: m.V3) !void {
        if (!m.finite(color) or @reduce(.Min, @as(@Vector(3, f32), color)) < 0) return error.InvalidEnvironment;
        var image = try envlib.Image.init(self.allocator, 64, 32);
        defer image.deinit();
        @memset(image.pixels, color);
        try self.setEnvironmentImage(image);
    }
    pub fn setEnvironmentPreset(self: *Renderer, preset: envlib.Preset, width: u32) !void {
        var image = try envlib.generate(self.allocator, preset, width);
        defer image.deinit();
        try self.setEnvironmentImage(image);
    }
    pub fn setEnvironmentImage(self: *Renderer, image: envlib.Image) !void {
        const w = image.width;
        const h = image.height;
        const count = @as(usize, w) * h;
        if (w == 0 or h == 0 or w > 4096 or h > 4096 or image.pixels.len != count) return error.EnvironmentBudget;
        for (image.pixels) |color| for (color) |v| {
            if (!std.math.isFinite(v) or v < 0 or v > 65000) return error.InvalidEnvironment;
        };
        const sh = try envlib.sh9(image);
        var mips = try envlib.prefilter(image, 6);
        defer mips.deinit();
        const cdf = try self.allocator.alloc(f32, h + count * 2);
        defer self.allocator.free(cdf);
        var total: f32 = 0;
        for (0..h) |y| {
            const sin = @sin(@as(f32, std.math.pi) * (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(h)));
            for (0..w) |x| {
                const color = image.pixels[y * w + x];
                const weight = (color[0] * 0.2126 + color[1] * 0.7152 + color[2] * 0.0722 + 1e-4) * sin;
                cdf[h + count + y * w + x] = weight;
                total += weight;
            }
        }
        if (!std.math.isFinite(total) or total <= 0) return error.InvalidEnvironment;
        for (cdf[h + count ..]) |*v| v.* /= total;
        var rows: f32 = 0;
        for (0..h) |y| {
            var sum: f32 = 0;
            for (0..w) |x| sum += cdf[h + count + y * w + x];
            rows += sum;
            cdf[y] = rows;
            var column: f32 = 0;
            for (0..w) |x| {
                column += cdf[h + count + y * w + x] / sum;
                cdf[h + y * w + x] = column;
            }
        }
        var env_storage: std.ArrayList([4]f32) = .empty;
        defer env_storage.deinit(self.allocator);
        var info: [8][4]u32 = @splat(.{ 0, 0, 0, 0 });
        for (mips.images[0..mips.count], 0..) |slot, i| {
            const mip = slot.?;
            info[i] = .{ mip.width, mip.height, @intCast(env_storage.items.len), 0 };
            try env_storage.ensureUnusedCapacity(self.allocator, mip.pixels.len);
            for (mip.pixels) |color| env_storage.appendAssumeCapacity(.{ color[0], color[1], color[2], 1 });
        }
        try self.replaceMany(&.{ 4, 9 }, &.{ std.mem.sliceAsBytes(cdf), std.mem.sliceAsBytes(env_storage.items) });
        var average: m.V3 = .{ 0, 0, 0 };
        for (image.pixels) |v| average = m.add(average, m.scale(v, 1 / @as(f32, @floatFromInt(count))));
        self.environment = average;
        self.environment_size = .{ w, h };
        self.environment_sh = sh;
        self.environment_mips = info;
        self.environment_levels = @intCast(mips.count);
        self.reset();
    }
    pub fn setEnvironmentRotation(self: *Renderer, angle: f32) !void {
        if (!std.math.isFinite(angle)) return error.InvalidEnvironment;
        self.environment_rotation = angle;
        self.reset();
    }
    pub fn setMaterials(self: *Renderer, materials: []const Material) !void {
        if (materials.len > 255) return error.MaterialBudget;
        var words: std.ArrayList(u32) = .empty;
        defer words.deinit(self.allocator);
        var sets: [256][4]f32 = @splat(.{ 1, 1, 255, 0 });
        var offsets: [2048]u32 = @splat(0);
        for (0..materials.len + 1) |i| {
            const mat = if (i < materials.len) materials[i] else Material{};
            if (!std.math.isFinite(mat.opacity) or mat.opacity < 0 or mat.opacity > 1 or !std.math.isFinite(mat.height_strength) or mat.height_strength < 0 or mat.height_strength > 100 or mat.roughness < 0 or mat.roughness > 1 or mat.metallic < 0 or mat.metallic > 1) return error.InvalidMaterial;
            if (mat.width == 0 or mat.height == 0 or mat.width > 8192 or mat.height > 8192 or !m.finite(mat.base) or !m.finite(mat.emissive) or !std.math.isFinite(mat.roughness) or !std.math.isFinite(mat.metallic)) return error.InvalidMaterial;
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
        self.material_words_used = words.items.len;
        self.stats.material_uploads += 1;
        self.reset();
    }
    pub fn updateBaseRegion(self: *Renderer, material: u32, x: u32, y: u32, w: u32, h: u32, rgba: []const [4]u16) !void {
        if (material >= self.material_count or rgba.len != @as(u64, w) * h) return error.InvalidRegion;
        const info = self.sets[material];
        const width: u32 = @intFromFloat(info[0]);
        const height: u32 = @intFromFloat(info[1]);
        if (x > width or y > height or w > width - x or h > height - y) return error.InvalidRegion;
        if (w == 0 or h == 0) return;
        try self.prepareRegion(material, 0, x, y, w, h);
        for (0..h) |dy| for (0..w) |dx| {
            const p = rgba[dy * w + dx];
            const word: u32 = @bitCast([4]u8{ self.srgb_lut[p[0] >> 4], self.srgb_lut[p[1] >> 4], self.srgb_lut[p[2] >> 4], @intCast(p[3] >> 8) });
            const at = self.wordAddress(material, 0, x + @as(u32, @intCast(dx)), y + @as(u32, @intCast(dy))) * 4;
            @memcpy(self.buffers[10].bytes[at..][0..4], std.mem.asBytes(&word));
        };
        self.stats.uploaded_bytes += @as(u64, w) * h * 4;
        self.stats.material_uploads += 1;
        self.reset();
    }
    fn materialWords(self: *Renderer) []u32 {
        return @as([*]u32, @ptrCast(@alignCast(self.buffers[10].bytes.ptr)))[0 .. self.buffers[10].bytes.len / 4];
    }
    fn reserveWords(self: *Renderer, additional: usize) !void {
        const needed = self.material_words_used + additional;
        if (needed <= self.buffers[10].bytes.len / 4) return;
        const limit = @min(@as(usize, 512 * 1024 * 1024), self.ctx.properties.limits.maxStorageBufferRange) / 4;
        if (needed > limit) return error.MaterialBudget;
        const capacity = @min(limit, @max(needed, @max(262144, self.buffers[10].bytes.len / 2)));
        var next = try gpu.Buffer.init(&self.ctx, capacity * 4, false);
        errdefer next.deinit(&self.ctx);
        const previous = self.buffers[10].bytes[0 .. self.material_words_used * 4];
        @memcpy(next.bytes[0..previous.len], previous);
        self.buffers[10].deinit(&self.ctx);
        self.buffers[10] = next;
        self.stats.scene_buffer_allocations += 1;
        self.stats.uploaded_bytes += previous.len;
    }
    // Constant channels become sparse GPU tile tables, rather than dense images.
    // Allocate all needed pages before changing any logical material state.
    fn prepareRegion(self: *Renderer, material: u32, kind: u32, x: u32, y: u32, w: u32, h: u32) !void {
        const mask: u32 = @intFromFloat(self.sets[material][2]);
        const small = mask & (@as(u32, 1) << @intCast(kind)) != 0;
        const paged = mask & (@as(u32, 1) << @intCast(kind + 8)) != 0;
        if (!small and !paged) return;
        const stride: usize = if (kind == 2 or kind == 3) 2 else 1;
        const width: usize = @intFromFloat(self.sets[material][0]);
        const height: usize = @intFromFloat(self.sets[material][1]);
        const tx = (width + 63) / 64;
        const table_count = tx * ((height + 63) / 64);
        var base: usize = self.offsets[material * 8 + kind];
        var missing: usize = 0;
        for (y / 64..(y + h - 1) / 64 + 1) |ty| for (x / 64..(x + w - 1) / 64 + 1) |tile_x| {
            if (small or self.materialWords()[base + stride + ty * tx + tile_x] == 0) missing += 1;
        };
        const extra = (if (small) stride + table_count else 0) + missing * 4096 * stride;
        var value: [2]u32 = .{ 0, 0 };
        @memcpy(value[0..stride], self.materialWords()[base..][0..stride]);
        try self.reserveWords(extra);
        const words = self.materialWords();
        if (small) {
            base = self.material_words_used;
            @memcpy(words[base..][0..stride], value[0..stride]);
            @memset(words[base + stride ..][0..table_count], 0);
            self.material_words_used += stride + table_count;
            self.offsets[material * 8 + kind] = @intCast(base);
            self.sets[material][2] = @floatFromInt((mask & ~(@as(u32, 1) << @intCast(kind))) | (@as(u32, 1) << @intCast(kind + 8)));
            try self.buffers[11].write(std.mem.sliceAsBytes(&self.offsets));
        }
        for (y / 64..(y + h - 1) / 64 + 1) |ty| for (x / 64..(x + w - 1) / 64 + 1) |tile_x| {
            const page = &words[base + stride + ty * tx + tile_x];
            if (page.* != 0) continue;
            page.* = @intCast(self.material_words_used);
            for (0..4096) |i| @memcpy(words[self.material_words_used + i * stride ..][0..stride], value[0..stride]);
            self.material_words_used += 4096 * stride;
        };
        self.stats.uploaded_bytes += extra * 4;
    }
    fn wordAddress(self: *Renderer, material: u32, kind: u32, x: u32, y: u32) usize {
        const stride: usize = if (kind == 2 or kind == 3) 2 else 1;
        const width: usize = @intFromFloat(self.sets[material][0]);
        const base: usize = self.offsets[material * 8 + kind];
        const mask: u32 = @intFromFloat(self.sets[material][2]);
        if (mask & (@as(u32, 1) << @intCast(kind + 8)) != 0) {
            const page = self.materialWords()[base + stride + (y / 64) * ((width + 63) / 64) + x / 64];
            return page + ((@as(usize, y) % 64) * 64 + x % 64) * stride;
        }
        return base + (@as(usize, y) * width + x) * stride;
    }
    pub fn updatePackedRegion(self: *Renderer, material: u32, kind: u32, x: u32, y: u32, w: u32, h: u32, words: []const u32) !void {
        if (material >= self.material_count or kind > 7) return error.InvalidMaterial;
        const stride: usize = if (kind == 2 or kind == 3) 2 else 1;
        const width: u32 = @intFromFloat(self.sets[material][0]);
        const height: u32 = @intFromFloat(self.sets[material][1]);
        if (x > width or y > height or w > width - x or h > height - y or words.len != @as(u64, w) * h * stride) return error.InvalidRegion;
        if (w == 0 or h == 0) return;
        try self.prepareRegion(material, kind, x, y, w, h);
        for (0..h) |dy| for (0..w) |dx| {
            const offset = self.wordAddress(material, kind, x + @as(u32, @intCast(dx)), y + @as(u32, @intCast(dy))) * 4;
            @memcpy(self.buffers[10].bytes[offset..][0 .. stride * 4], std.mem.sliceAsBytes(words[(dy * w + dx) * stride ..][0..stride]));
        };
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
        for (&acc) |*b| b.* = try gpu.Buffer.initDevice(&self.ctx, bytes);
        for (&illum) |*b| b.* = try gpu.Buffer.initDevice(&self.ctx, bytes);
        const out = try gpu.Buffer.initReadback(&self.ctx, @as(usize, w) * h * 4);
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
        if (self.buffers[5].size == bytes) return;
        var acc: [4]gpu.Buffer = @splat(.{});
        errdefer for (&acc) |*b| b.deinit(&self.ctx);
        var illum: [2]gpu.Buffer = @splat(.{});
        errdefer for (&illum) |*b| b.deinit(&self.ctx);
        for (&acc) |*b| b.* = try gpu.Buffer.initDevice(&self.ctx, bytes);
        for (&illum) |*b| b.* = try gpu.Buffer.initDevice(&self.ctx, bytes);
        for (&self.buffers[5..9].*) |*b| b.deinit(&self.ctx);
        @memcpy(self.buffers[5..9], &acc);
        for (&self.illum) |*b| b.deinit(&self.ctx);
        self.illum = illum;
        self.reset();
    }
    pub fn preview(self: *Renderer, camera: m.Camera, settings: PreviewSettings, readback: bool) !?[]const u8 {
        try camera.validate();
        if (self.width == 0 or self.buffers[1].handle == null or self.buffers[10].handle == null or self.buffers[9].handle == null) return error.SceneNotReady;
        if (!m.finite(settings.color) or !std.math.isFinite(settings.exposure) or settings.exposure < 0 or settings.exposure > 1e6 or !std.math.isFinite(settings.environment_opacity) or settings.environment_opacity < 0 or settings.environment_opacity > 1) return error.InvalidSettings;
        for (settings.color) |v| if (v < 0 or v > 1e6) return error.InvalidLight;
        for (settings.light) |v| if (!std.math.isFinite(v) or @abs(v) > 1e6) return error.InvalidLight;
        if (settings.light[3] < 0) return error.InvalidLight;
        if (self.raster == null) {
            var next = try raster_backend.Raster.init(&self.ctx);
            errdefer next.deinit(&self.ctx);
            const uniform = try gpu.Buffer.init(&self.ctx, 512, true);
            self.raster = next;
            self.raster_params = uniform;
        }
        const r = &self.raster.?;
        try r.resize(&self.ctx, self.width, self.height);
        const f = camera.forward();
        const e = camera.eye();
        const params: Params = .{ .inv_vp = m.inverse4(camera.inverseVP(@as(f32, @floatFromInt(self.width)) / @as(f32, @floatFromInt(self.height)))), .forward = .{ f[0], f[1], f[2], @max(1e-7, camera.scene_radius * 2e-6) }, .size = .{ self.width, self.height, 0, 1 }, .cfg = .{ 1, @intFromBool(self.specular_glossiness), 1, self.material_count }, .env = .{ @sin(self.environment_rotation), @cos(self.environment_rotation), @floatFromInt(self.environment_size[0]), @floatFromInt(self.environment_size[1]) }, .sigma = .{ 1, 1, 1, 0 }, .eye = .{ e[0], e[1], e[2], 1 }, .lens = .{ camera.distance, 0, 1.5, 0 }, .sets = self.sets };
        try self.buffers[0].write(std.mem.asBytes(&params));
        const Raw = extern struct { light: [4]f32, color: [4]f32, display: [4]f32, ambient: [4]f32, sh: [9][4]f32, mips: [8][4]u32, counts: [4]u32, inverse_vp: [16]f32 };
        var sh: [9][4]f32 = undefined;
        for (self.environment_sh, &sh) |value, *v| v.* = .{ value[0], value[1], value[2], 0 };
        const raw: Raw = .{ .light = settings.light, .color = .{ settings.color[0], settings.color[1], settings.color[2], 0 }, .display = .{ settings.exposure, if (settings.filmic) 1 else 0, settings.environment_opacity, if (settings.shadows) 1 else 0 }, .ambient = .{ self.environment[0], self.environment[1], self.environment[2], 0 }, .sh = sh, .mips = self.environment_mips, .counts = .{ self.environment_levels, 0, 0, 0 }, .inverse_vp = camera.inverseVP(@as(f32, @floatFromInt(self.width)) / @as(f32, @floatFromInt(self.height))) };
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
        if (self.width == 0 or self.buffers[10].handle == null or self.buffers[1].handle == null or self.buffers[9].handle == null) return error.SceneNotReady;
        if (spp == 0 or spp > 64 or settings.bounces == 0 or settings.bounces > 32 or self.samples > 65536 - spp) return error.SampleBudget;
        try self.ensureAccumulation();
        const sampling: Sampling = .{ .bounces = settings.bounces, .legacy = settings.legacy_bounds_offset, .specular_glossiness = self.specular_glossiness, .lens = settings.lens_radius, .focus = settings.focus, .ior = settings.ior };
        if (self.last_camera == null or self.last_sampling == null or !std.meta.eql(sampling, self.last_sampling.?) or !std.meta.eql(camera, self.last_camera.?)) {
            self.reset();
            self.last_camera = camera;
            self.last_sampling = sampling;
        }
        const f = camera.forward();
        const e = camera.eye();
        const eps = if (settings.legacy_bounds_offset) @max(1e-6, m.length(m.sub(self.bounds.hi, self.bounds.lo)) * 2e-5) else @max(1e-7, camera.scene_radius * 2e-6);
        var params: Params = .{ .inv_vp = camera.inverseVP(@as(f32, @floatFromInt(self.width)) / @as(f32, @floatFromInt(self.height))), .forward = .{ f[0], f[1], f[2], eps }, .size = .{ self.width, self.height, self.samples, spp }, .cfg = .{ settings.bounces, @intFromBool(self.specular_glossiness), 1, self.material_count }, .env = .{ @sin(self.environment_rotation), @cos(self.environment_rotation), @floatFromInt(self.environment_size[0]), @floatFromInt(self.environment_size[1]) }, .sigma = .{ 1, 1, 1, 0 }, .eye = .{ e[0], e[1], e[2], 1 }, .lens = .{ if (settings.focus > 0) settings.focus else camera.distance, settings.lens_radius, settings.ior, 0 }, .sets = self.sets };
        try self.buffers[0].write(std.mem.asBytes(&params));
        var views: [12]gpu.View = undefined;
        for (&self.buffers, &views) |*b, *v| v.* = .{ .buffer = b };
        try self.trace.bind(&self.ctx, 0, &views);
        try self.ctx.begin();
        if (self.samples == 0) {
            for (self.buffers[5..9]) |b| gpu.c.vkCmdFillBuffer(self.ctx.command, b.handle, 0, b.size, 0);
            self.ctx.barrier();
        }
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
