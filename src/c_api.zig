//! Stable caller-owned C ABI. Invalid/released handles never become pointers.
const std = @import("std");
const lib = @import("texture_painting");
const render = @import("hamudi1").renderer;
const m = lib.math;
const a = std.heap.c_allocator;
const Scene = struct {
    mesh: lib.geometry.Mesh,
    bvh: lib.geometry.Bvh,
    uv: ?lib.geometry.UvBuffer = null,
    material: ?u32 = null,
    source_count: usize,
    vertex_sources: []u32 = &.{},
    fn deinit(self: *Scene) void {
        if (self.uv) |*uv| uv.deinit();
        self.bvh.deinit();
        a.free(self.mesh.positions);
        a.free(self.mesh.normals);
        a.free(self.mesh.uvs);
        a.free(self.mesh.indices);
        a.free(self.mesh.materials);
        a.free(self.vertex_sources);
    }
};
const Entry = union(enum) { renderer: *render.Renderer, surface: *lib.painting.Session, scene: *Scene };
const Slot = struct { generation: u32 = 1, entry: ?Entry = null };
var slots: [1024]Slot = @splat(.{});
var mutex: std.atomic.Mutex = .unlocked;
threadlocal var message: [128:0]u8 = @splat(0);
fn lock() void {
    while (!mutex.tryLock()) {
        std.Thread.yield() catch {};
    }
}
fn fail(err: anyerror) c_int {
    const name = @errorName(err);
    const n = @min(name.len, 127);
    @memcpy(message[0..n], name[0..n]);
    message[n] = 0;
    return if (err == error.OutOfMemory) -2 else -1;
}
fn lookup(handle: u64) !Entry {
    const i = handle & 0xffffffff;
    if (i == 0 or i > slots.len) return error.InvalidHandle;
    const slot = slots[i - 1];
    if (slot.generation != handle >> 32) return error.InvalidHandle;
    return slot.entry orelse error.InvalidHandle;
}
fn put(entry: Entry) !u64 {
    for (&slots, 0..) |*slot, i| {
        if (slot.entry == null) {
            slot.entry = entry;
            return (@as(u64, slot.generation) << 32) | @as(u64, i + 1);
        }
    }
    return error.HandleBudget;
}
fn renderer(handle: u64) !*render.Renderer {
    return switch (try lookup(handle)) {
        .renderer => |r| r,
        else => error.WrongHandleKind,
    };
}
fn surface(handle: u64) !*lib.painting.Session {
    return switch (try lookup(handle)) {
        .surface => |s| s,
        else => error.WrongHandleKind,
    };
}
fn scene(handle: u64) !*Scene {
    return switch (try lookup(handle)) {
        .scene => |s| s,
        else => error.WrongHandleKind,
    };
}
fn slice(comptime T: type, p: ?[*]const T, n: usize, max: usize) ![]const T {
    if (n > max) return error.InputBudget;
    if (n == 0) return &.{};
    return (p orelse return error.NullInput)[0..n];
}
const Mesh = extern struct { positions: ?[*]const m.V3, normals: ?[*]const m.V3, uvs: ?[*]const m.V2, indices: ?[*]const u32, materials: ?[*]const u32, vertex_count: usize, index_count: usize };
const Material = extern struct { width: u32, height: u32, rgba: ?[*]const [4]u16, base: m.V3, opacity: f32, roughness: f32, metallic: f32, emissive: m.V3 };
const Camera = extern struct {
    target: m.V3,
    yaw: f32,
    pitch: f32,
    distance: f32,
    fov: f32,
    scene_radius: f32,
    ortho: u32,
    fn native(c: Camera) m.Camera {
        return .{ .target = c.target, .yaw = c.yaw, .pitch = c.pitch, .distance = c.distance, .fov = c.fov, .scene_radius = c.scene_radius, .ortho = c.ortho != 0 };
    }
};
const Brush = extern struct { radius: f32, hardness: f32, flow: f32, spacing: f32, angle: f32, alpha: u32 };
const PreviewOptions = extern struct { light: [4]f32, color: m.V3, exposure: f32, filmic: u32, shadows: u32, environment_opacity: f32 };
const AlphaImage = extern struct { width: u32, height: u32, pixels: ?[*]const u16, count: usize };
const BakeOptions = extern struct { samples: u32, distance: f32, epsilon: f32, cancel: ?*const std.atomic.Value(u32) };
export fn hamudi_cancel_set(flag: ?*std.atomic.Value(u32), value: u32) c_int {
    (flag orelse return fail(error.NullOutput)).store(value, .release);
    return 0;
}
fn uvFor(s: *Scene, width: u32, height: u32, material: u32) !lib.geometry.UvBuffer {
    if (s.uv == null or s.material != material or s.uv.?.width != width or s.uv.?.height != height) {
        const next = try lib.geometry.UvBuffer.init(a, s.mesh, width, height, material);
        if (s.uv) |*uv| uv.deinit();
        s.uv = next;
        s.material = material;
    }
    return s.uv.?;
}
export fn hamudi_bake(handle: u64, material: u32, width: u32, height: u32, kind: u32, input: ?*const BakeOptions, out: ?[*][4]u16, components: usize) c_int {
    lock();
    defer mutex.unlock();
    const s = scene(handle) catch |e| return fail(e);
    const options = input orelse return fail(error.NullInput);
    if (kind >= @typeInfo(lib.bake.Kind).@"enum".fields.len or material > 255 or width == 0 or height == 0 or @as(u64, width) * height > 16_777_216 or components != @as(u64, width) * height * 4) return fail(error.BakeBudget);
    const dst = out orelse return fail(error.NullOutput);
    const uv = uvFor(s, width, height, material) catch |e| return fail(e);
    const result = lib.bake.generate(a, @enumFromInt(kind), s.mesh, &s.bvh, uv, .{ .samples = options.samples, .distance = options.distance, .epsilon = options.epsilon, .cancel_word = options.cancel }) catch |e| return fail(e);
    defer a.free(result);
    @memcpy(dst[0..result.len], result);
    return 0;
}
export fn hamudi_bake_transfer(low_handle: u64, high_handle: u64, material: u32, width: u32, height: u32, input: ?*const BakeOptions, normals: ?[*][4]u16, normal_components: usize, heights: ?[*]u16, height_components: usize) c_int {
    lock();
    defer mutex.unlock();
    const low = scene(low_handle) catch |e| return fail(e);
    const high = scene(high_handle) catch |e| return fail(e);
    const options = input orelse return fail(error.NullInput);
    const area = @as(u64, width) * height;
    if (material > 255 or area == 0 or area > 16_777_216 or normal_components != area * 4 or height_components != area) return fail(error.BakeBudget);
    const n = normals orelse return fail(error.NullOutput);
    const h = heights orelse return fail(error.NullOutput);
    const uv = uvFor(low, width, height, material) catch |e| return fail(e);
    const result = lib.bake.transferWithOptions(a, low.mesh, uv, high.mesh, &high.bvh, .{ .distance = options.distance, .cancel_word = options.cancel }) catch |e| return fail(e);
    defer a.free(result.normal);
    defer a.free(result.height);
    @memcpy(n[0..result.normal.len], result.normal);
    @memcpy(h[0..result.height.len], result.height);
    return 0;
}
fn imageBrush(input: ?*const Brush, image: ?*const AlphaImage) !lib.painting.Brush {
    var brush = try nativeBrush(input);
    const src = image orelse return error.NullInput;
    brush.image = .{ .width = src.width, .height = src.height, .pixels = try slice(u16, src.pixels, src.count, 16_777_216) };
    try brush.validate();
    return brush;
}
export fn hamudi_abi_version() u32 {
    return 1;
}
export fn hamudi_last_error() [*:0]const u8 {
    return &message;
}
export fn hamudi_renderer_create(out: ?*u64) c_int {
    return hamudi_renderer_create_device(0, out);
}
export fn hamudi_renderer_create_device(device: u32, out: ?*u64) c_int {
    lock();
    defer mutex.unlock();
    const dst = out orelse return fail(error.NullOutput);
    dst.* = 0;
    if (device > 2) return fail(error.InvalidDevice);
    const r = a.create(render.Renderer) catch |e| return fail(e);
    r.* = render.Renderer.initDevice(a, @enumFromInt(device)) catch |e| {
        a.destroy(r);
        return fail(e);
    };
    const handle = put(.{ .renderer = r }) catch |e| {
        r.deinit();
        a.destroy(r);
        return fail(e);
    };
    dst.* = handle;
    return 0;
}
export fn hamudi_surface_create(width: u32, height: u32, out: ?*u64) c_int {
    lock();
    defer mutex.unlock();
    const dst = out orelse return fail(error.NullOutput);
    dst.* = 0;
    const s = a.create(lib.painting.Session) catch |e| return fail(e);
    s.* = lib.painting.Session.init(a, width, height) catch |e| {
        a.destroy(s);
        return fail(e);
    };
    const handle = put(.{ .surface = s }) catch |e| {
        s.deinit();
        a.destroy(s);
        return fail(e);
    };
    dst.* = handle;
    return 0;
}
export fn hamudi_release(handle: u64) c_int {
    lock();
    defer mutex.unlock();
    const entry = lookup(handle) catch |e| return fail(e);
    const slot = &slots[(handle & 0xffffffff) - 1];
    slot.entry = null;
    slot.generation +%= 1;
    if (slot.generation == 0) slot.generation = 1;
    switch (entry) {
        .renderer => |r| {
            r.deinit();
            a.destroy(r);
        },
        .surface => |s| {
            s.deinit();
            a.destroy(s);
        },
        .scene => |s| {
            s.deinit();
            a.destroy(s);
        },
    }
    return 0;
}
export fn hamudi_set_mesh(handle: u64, input: ?*const Mesh) c_int {
    lock();
    defer mutex.unlock();
    const r = renderer(handle) catch |e| return fail(e);
    const src = input orelse return fail(error.NullInput);
    const positions = slice(m.V3, src.positions, src.vertex_count, 4_000_000) catch |e| return fail(e);
    const normals = slice(m.V3, src.normals, src.vertex_count, 4_000_000) catch |e| return fail(e);
    const uvs = slice(m.V2, src.uvs, src.vertex_count, 4_000_000) catch |e| return fail(e);
    const indices = slice(u32, src.indices, src.index_count, 12_000_000) catch |e| return fail(e);
    const materials = if (src.materials != null) slice(u32, src.materials, src.index_count / 3, 4_000_000) catch |e| return fail(e) else &.{};
    const mesh: lib.geometry.Mesh = .{ .positions = positions, .normals = normals, .uvs = uvs, .indices = indices, .materials = materials };
    var bvh = lib.geometry.Bvh.init(a, mesh) catch |e| return fail(e);
    defer bvh.deinit();
    r.setMesh(mesh, &bvh) catch |e| return fail(e);
    return 0;
}
export fn hamudi_set_materials(handle: u64, input: ?[*]const Material, count: usize) c_int {
    lock();
    defer mutex.unlock();
    const r = renderer(handle) catch |e| return fail(e);
    const source = slice(Material, input, count, 255) catch |e| return fail(e);
    var mats: [255]render.Material = undefined;
    for (source, mats[0..count]) |src, *dst| {
        if (src.width > 8192 or src.height > 8192) return fail(error.ImageBudget);
        const pixels = if (src.rgba != null) slice([4]u16, src.rgba, @as(usize, src.width) * src.height, 16_777_216) catch |e| return fail(e) else &.{};
        dst.* = .{ .width = src.width, .height = src.height, .rgba = pixels, .base = src.base, .opacity = src.opacity, .roughness = src.roughness, .metallic = src.metallic, .emissive = src.emissive };
    }
    r.setMaterials(mats[0..count]) catch |e| return fail(e);
    return 0;
}
export fn hamudi_set_environment(handle: u64, rgb: ?*const m.V3) c_int {
    lock();
    defer mutex.unlock();
    const r = renderer(handle) catch |e| return fail(e);
    r.setEnvironment((rgb orelse return fail(error.NullInput)).*) catch |e| return fail(e);
    return 0;
}
export fn hamudi_resize(handle: u64, w: u32, h: u32) c_int {
    lock();
    defer mutex.unlock();
    const r = renderer(handle) catch |e| return fail(e);
    r.resize(w, h) catch |e| return fail(e);
    return 0;
}
fn output(r: *render.Renderer, p: ?[*]u8, bytes: usize) ![]u8 {
    const required = @as(usize, r.width) * r.height * 4;
    if (required == 0 or bytes < required) return error.OutputBudget;
    return (p orelse return error.NullOutput)[0..required];
}
export fn hamudi_preview(handle: u64, cam: ?*const Camera, light: ?*const [4]f32, exposure: f32, filmic: u32, out: ?[*]u8, bytes: usize) c_int {
    lock();
    defer mutex.unlock();
    const r = renderer(handle) catch |e| return fail(e);
    const dst = output(r, out, bytes) catch |e| return fail(e);
    const camera = cam orelse return fail(error.NullInput);
    const rgba = r.preview(camera.native(), .{ .light = (light orelse return fail(error.NullInput)).*, .exposure = exposure, .filmic = filmic != 0 }, true) catch |e| return fail(e);
    @memcpy(dst, rgba.?);
    return 0;
}
export fn hamudi_preview_options(handle: u64, cam: ?*const Camera, input: ?*const PreviewOptions, out: ?[*]u8, bytes: usize) c_int {
    lock();
    defer mutex.unlock();
    const r = renderer(handle) catch |e| return fail(e);
    const dst = output(r, out, bytes) catch |e| return fail(e);
    const options = input orelse return fail(error.NullInput);
    const camera = cam orelse return fail(error.NullInput);
    const rgba = r.preview(camera.native(), .{ .light = options.light, .color = options.color, .exposure = options.exposure, .filmic = options.filmic != 0, .shadows = options.shadows != 0, .environment_opacity = options.environment_opacity }, true) catch |e| return fail(e);
    @memcpy(dst, rgba.?);
    return 0;
}
export fn hamudi_trace(handle: u64, cam: ?*const Camera, samples: u32, exposure: f32, filmic: u32, out: ?[*]u8, bytes: usize) c_int {
    lock();
    defer mutex.unlock();
    const r = renderer(handle) catch |e| return fail(e);
    const dst = output(r, out, bytes) catch |e| return fail(e);
    const camera = cam orelse return fail(error.NullInput);
    if (samples == 0 or samples > 1024) return fail(error.SampleBudget);
    const settings: render.Settings = .{ .exposure = exposure, .filmic = filmic != 0, .legacy_bounds_offset = false };
    var remaining = samples;
    while (remaining > 0) {
        const n = @min(remaining, 8);
        r.pass(camera.native(), settings, n) catch |e| return fail(e);
        remaining -= n;
    }
    const pixels = r.pixels(settings) catch |e| return fail(e);
    @memcpy(dst, pixels);
    return 0;
}
// Small progressive steps let the host cancel between bounded submissions.
export fn hamudi_trace_step(handle: u64, cam: ?*const Camera, samples: u32) c_int {
    lock();
    defer mutex.unlock();
    const r = renderer(handle) catch |e| return fail(e);
    if (samples == 0 or samples > 8) return fail(error.SampleBudget);
    r.pass((cam orelse return fail(error.NullInput)).native(), .{ .legacy_bounds_offset = false }, samples) catch |e| return fail(e);
    return 0;
}
export fn hamudi_resolve(handle: u64, exposure: f32, filmic: u32, out: ?[*]u8, bytes: usize) c_int {
    lock();
    defer mutex.unlock();
    const r = renderer(handle) catch |e| return fail(e);
    const dst = output(r, out, bytes) catch |e| return fail(e);
    const pixels = r.pixels(.{ .exposure = exposure, .filmic = filmic != 0 }) catch |e| return fail(e);
    @memcpy(dst, pixels);
    return 0;
}
export fn hamudi_reset(handle: u64) c_int {
    lock();
    defer mutex.unlock();
    const r = renderer(handle) catch |e| return fail(e);
    r.reset();
    return 0;
}
export fn hamudi_set_specular_glossiness(handle: u64, enabled: u32) c_int {
    lock();
    defer mutex.unlock();
    const r = renderer(handle) catch |e| return fail(e);
    r.specular_glossiness = enabled != 0;
    r.reset();
    return 0;
}
export fn hamudi_update_region(handle: u64, material: u32, x: u32, y: u32, w: u32, h: u32, input: ?[*]const [4]u16) c_int {
    lock();
    defer mutex.unlock();
    const r = renderer(handle) catch |e| return fail(e);
    const pixels = slice([4]u16, input, @as(u64, w) * h, 16_777_216) catch |e| return fail(e);
    r.updateBaseRegion(material, x, y, w, h, pixels) catch |e| return fail(e);
    return 0;
}
export fn hamudi_surface_add_layer(handle: u64, name: ?[*]const u8, bytes: usize, out: ?*u32) c_int {
    lock();
    defer mutex.unlock();
    const s = surface(handle) catch |e| return fail(e);
    const dst = out orelse return fail(error.NullOutput);
    const text = slice(u8, name, bytes, 63) catch |e| return fail(e);
    dst.* = @intCast(s.addLayer(text, .paint) catch |e| return fail(e));
    return 0;
}
export fn hamudi_surface_stroke_uv(handle: u64, layer: u32, channel: u32, rgb: ?*const m.V3, opacity: f32, erase: u32, points: ?[*]const m.V2, count: usize, input: ?*const Brush) c_int {
    lock();
    defer mutex.unlock();
    const s = surface(handle) catch |e| return fail(e);
    if (channel >= lib.painting.channel_count) return fail(error.InvalidChannel);
    const b = input orelse return fail(error.NullInput);
    if (b.alpha >= 7) return fail(error.InvalidBrush);
    const path = slice(m.V2, points, count, 100000) catch |e| return fail(e);
    const brush: lib.painting.Brush = .{ .workers = 8, .radius = b.radius, .hardness = b.hardness, .flow = b.flow, .spacing = b.spacing, .angle = b.angle, .alpha = @enumFromInt(b.alpha) };
    s.begin(layer, @enumFromInt(channel), (rgb orelse return fail(error.NullInput)).*, opacity, erase != 0) catch |e| return fail(e);
    defer s.cancel();
    s.strokeUv(path, brush) catch |e| return fail(e);
    s.commit() catch |e| return fail(e);
    return 0;
}
export fn hamudi_surface_read(handle: u64, channel: u32, out: ?[*][4]u16, components: usize) c_int {
    lock();
    defer mutex.unlock();
    const s = surface(handle) catch |e| return fail(e);
    if (channel >= lib.painting.channel_count) return fail(error.InvalidChannel);
    const count = @as(usize, s.document.width) * s.document.height;
    if (components < count * 4) return fail(error.OutputBudget);
    const dst = out orelse return fail(error.NullOutput);
    s.document.region(@enumFromInt(channel), 0, 0, s.document.width, s.document.height, dst[0..count]) catch |e| return fail(e);
    return 0;
}
export fn hamudi_surface_undo(handle: u64) c_int {
    lock();
    defer mutex.unlock();
    const s = surface(handle) catch |e| return fail(e);
    return if (s.undo() catch |e| return fail(e)) 0 else 1;
}
export fn hamudi_surface_redo(handle: u64) c_int {
    lock();
    defer mutex.unlock();
    const s = surface(handle) catch |e| return fail(e);
    return if (s.redo() catch |e| return fail(e)) 0 else 1;
}

fn createScene(src: Mesh) !*Scene {
    const p = try a.dupe(m.V3, try slice(m.V3, src.positions, src.vertex_count, 4_000_000));
    errdefer a.free(p);
    const n = try a.dupe(m.V3, try slice(m.V3, src.normals, src.vertex_count, 4_000_000));
    errdefer a.free(n);
    const uv = try a.dupe(m.V2, try slice(m.V2, src.uvs, src.vertex_count, 4_000_000));
    errdefer a.free(uv);
    const ids = try a.dupe(u32, try slice(u32, src.indices, src.index_count, 12_000_000));
    errdefer a.free(ids);
    const mats = try a.dupe(u32, if (src.materials != null) try slice(u32, src.materials, src.index_count / 3, 4_000_000) else &.{});
    errdefer a.free(mats);
    const mesh: lib.geometry.Mesh = .{ .positions = p, .normals = n, .uvs = uv, .indices = ids, .materials = mats };
    var bvh = try lib.geometry.Bvh.init(a, mesh);
    errdefer bvh.deinit();
    const result = try a.create(Scene);
    result.* = .{ .mesh = mesh, .bvh = bvh, .source_count = mesh.positions.len };
    return result;
}
export fn hamudi_scene_create(input: ?*const Mesh, out: ?*u64) c_int {
    lock();
    defer mutex.unlock();
    const dst = out orelse return fail(error.NullOutput);
    dst.* = 0;
    const src = input orelse return fail(error.NullInput);
    const next = createScene(src.*) catch |e| return fail(e);
    const handle = put(.{ .scene = next }) catch |e| {
        next.deinit();
        a.destroy(next);
        return fail(e);
    };
    dst.* = handle;
    return 0;
}
export fn hamudi_set_scene(render_handle: u64, scene_handle: u64) c_int {
    lock();
    defer mutex.unlock();
    const r = renderer(render_handle) catch |e| return fail(e);
    const s = scene(scene_handle) catch |e| return fail(e);
    r.setMesh(s.mesh, &s.bvh) catch |e| return fail(e);
    return 0;
}
/// Fixed-topology animation update. UVs, indices, material identities and caches
/// remain attached to this scene. Invalid input leaves the prior pose intact.
export fn hamudi_scene_deform(handle: u64, positions: ?[*]const m.V3, normals: ?[*]const m.V3, count: usize) c_int {
    lock();
    defer mutex.unlock();
    const s = scene(handle) catch |e| return fail(e);
    if (count != s.source_count) return fail(error.TopologyChanged);
    const p = slice(m.V3, positions, count, 4_000_000) catch |e| return fail(e);
    const n = slice(m.V3, normals, count, 4_000_000) catch |e| return fail(e);
    for (p, n) |position, normal| {
        if (!m.finite(position) or !m.finite(normal)) return fail(error.NonFiniteMesh);
        for (position) |v| if (@abs(v) > 1e12) return fail(error.MeshRange);
        for (normal) |v| if (@abs(v) > 1e6) return fail(error.MeshRange);
    }
    for (@constCast(s.mesh.positions), @constCast(s.mesh.normals), 0..) |*position, *normal, i| {
        const source = if (s.vertex_sources.len != 0) s.vertex_sources[i] else i;
        position.* = p[source];
        normal.* = n[source];
    }
    // Existing topology/UVs were validated on creation; new values checked above.
    s.bvh.refit(s.mesh) catch unreachable;
    return 0;
}
const Hit = extern struct { point: m.V3, normal: m.V3, uv: m.V2, triangle: u32, material: u32 };
export fn hamudi_pick(scene_handle: u64, camera: ?*const Camera, u: f32, v: f32, aspect: f32, out: ?*Hit) c_int {
    lock();
    defer mutex.unlock();
    const s = scene(scene_handle) catch |e| return fail(e);
    const dst = out orelse return fail(error.NullOutput);
    const cam = (camera orelse return fail(error.NullInput)).native();
    cam.validate() catch |e| return fail(e);
    if (!std.math.isFinite(u) or !std.math.isFinite(v) or !std.math.isFinite(aspect) or aspect <= 0 or u < 0 or u > 1 or v < 0 or v > 1) return fail(error.InvalidSample);
    const ray = cam.ray(.{ u, v }, aspect);
    const hit = s.bvh.cast(s.mesh, ray, 1e9) orelse return 1;
    const ids = s.mesh.indices[hit.triangle * 3 ..][0..3];
    var uv: m.V2 = .{ 0, 0 };
    for (ids, hit.bary) |index, weight| for (0..2) |k| {
        uv[k] += s.mesh.uvs[index][k] * weight;
    };
    dst.* = .{ .point = m.add(ray.origin, m.scale(ray.dir, hit.distance)), .normal = lib.geometry.UvBuffer.normal(s.mesh, .{ .triangle = hit.triangle, .bary = hit.bary }), .uv = uv, .triangle = hit.triangle, .material = if (s.mesh.materials.len > 0) s.mesh.materials[hit.triangle] else 0 };
    return 0;
}
export fn hamudi_surface_import_channel(handle: u64, name: ?[*]const u8, name_bytes: usize, channel: u32, rgba: ?[*]const [4]u16, components: usize, out: ?*u32) c_int {
    lock();
    defer mutex.unlock();
    const s = surface(handle) catch |e| return fail(e);
    const dst = out orelse return fail(error.NullOutput);
    if (channel >= lib.painting.channel_count or components % 4 != 0) return fail(error.InvalidChannel);
    const text = slice(u8, name, name_bytes, 63) catch |e| return fail(e);
    const pixels = slice([4]u16, rgba, components / 4, 67_108_864) catch |e| return fail(e);
    dst.* = @intCast(s.importChannel(text, @enumFromInt(channel), pixels) catch |e| return fail(e));
    return 0;
}
export fn hamudi_surface_import_base(handle: u64, input: ?[*]const [4]u16, components: usize) c_int {
    lock();
    defer mutex.unlock();
    const s = surface(handle) catch |e| return fail(e);
    if (components != @as(u64, s.document.width) * s.document.height * 4) return fail(error.InvalidImport);
    const pixels = slice([4]u16, input, components / 4, 16_777_216) catch |e| return fail(e);
    s.importBase(pixels) catch |e| return fail(e);
    return 0;
}
export fn hamudi_surface_stamp_world(surface_handle: u64, scene_handle: u64, material: u32, layer: u32, channel: u32, color: ?*const m.V3, point: ?*const m.V3, normal: ?*const m.V3, eye: ?*const m.V3, input: ?*const Brush) c_int {
    lock();
    defer mutex.unlock();
    const s = surface(surface_handle) catch |e| return fail(e);
    const mesh = scene(scene_handle) catch |e| return fail(e);
    const b = input orelse return fail(error.NullInput);
    if (b.alpha >= 7 or channel >= lib.painting.channel_count) return fail(error.InvalidBrush);
    const brush: lib.painting.Brush = .{ .workers = 8, .radius = b.radius, .hardness = b.hardness, .flow = b.flow, .spacing = b.spacing, .angle = b.angle, .alpha = @enumFromInt(b.alpha) };
    brush.validate() catch |e| return fail(e);
    if (mesh.uv == null or mesh.material != material or mesh.uv.?.width != s.document.width or mesh.uv.?.height != s.document.height) {
        const next = lib.geometry.UvBuffer.init(a, mesh.mesh, s.document.width, s.document.height, material) catch |e| return fail(e);
        if (mesh.uv) |*uv| uv.deinit();
        mesh.uv = next;
        mesh.material = material;
    }
    const center = (point orelse return fail(error.NullInput)).*;
    const n = (normal orelse return fail(error.NullInput)).*;
    const c0 = (color orelse return fail(error.NullInput)).*;
    s.begin(layer, @enumFromInt(channel), c0, 1, false) catch |e| return fail(e);
    defer s.cancel();
    s.stampWorld(mesh.mesh, &mesh.bvh, mesh.uv.?, center, n, brush, if (eye) |e| e.* else null) catch |e| return fail(e);
    s.commit() catch |e| return fail(e);
    return 0;
}
export fn hamudi_sync_surface(render_handle: u64, material: u32, surface_handle: u64) c_int {
    lock();
    defer mutex.unlock();
    const r = renderer(render_handle) catch |e| return fail(e);
    const s = surface(surface_handle) catch |e| return fail(e);
    @import("hamudi1").material_sync.apply(r, s, material) catch |e| return fail(e);
    return 0;
}
export fn hamudi_surface_clear_dirty(handle: u64) c_int {
    lock();
    defer mutex.unlock();
    const s = surface(handle) catch |e| return fail(e);
    s.clearDirty();
    return 0;
}
fn copyBytes(data: []const u8, out: ?[*]u8, bytes: usize, required: ?*usize) !void {
    const size = required orelse return error.NullOutput;
    size.* = data.len;
    if (out) |p| {
        if (bytes < data.len) return error.OutputBudget;
        @memcpy(p[0..data.len], data);
    } else if (bytes != 0) return error.NullOutput;
}
export fn hamudi_surface_save(handle: u64, out: ?[*]u8, bytes: usize, required: ?*usize) c_int {
    lock();
    defer mutex.unlock();
    const s = surface(handle) catch |e| return fail(e);
    const data = lib.image_io.save(a, s.document) catch |e| return fail(e);
    defer a.free(data);
    copyBytes(data, out, bytes, required) catch |e| return fail(e);
    return 0;
}
export fn hamudi_surface_load(handle: u64, input: ?[*]const u8, bytes: usize) c_int {
    lock();
    defer mutex.unlock();
    const s = surface(handle) catch |e| return fail(e);
    if (s.active != null) return fail(error.StrokeActive);
    const data = slice(u8, input, bytes, 128 * 1024 * 1024) catch |e| return fail(e);
    var doc = lib.image_io.load(a, data) catch |e| return fail(e);
    var next = lib.painting.Session.init(a, doc.width, doc.height) catch |e| {
        doc.deinit();
        return fail(e);
    };
    next.document.deinit();
    next.document = doc;
    next.revision = s.revision +% 1;
    next.gesture_sequence = s.gesture_sequence;
    for (doc.layers.items) |layer| next.managed_channels |= layer.enabled;
    next.dirty_channels = next.managed_channels;
    s.deinit();
    s.* = next;
    return 0;
}
export fn hamudi_surface_png(handle: u64, channel: u32, bits: u32, color: u32, out: ?[*]u8, bytes: usize, required: ?*usize) c_int {
    lock();
    defer mutex.unlock();
    const s = surface(handle) catch |e| return fail(e);
    if (channel >= lib.painting.channel_count or (bits != 8 and bits != 16)) return fail(error.InvalidExport);
    const data = lib.image_io.exportChannel(a, s.document, @enumFromInt(channel), .{ .bits = if (bits == 16) .sixteen else .eight, .color = color != 0 }) catch |e| return fail(e);
    defer a.free(data);
    copyBytes(data, out, bytes, required) catch |e| return fail(e);
    return 0;
}

export fn hamudi_surface_set_default(handle: u64, channel: u32, value: ?*const m.V3) c_int {
    lock();
    defer mutex.unlock();
    const s = surface(handle) catch |e| return fail(e);
    if (channel >= lib.painting.channel_count) return fail(error.InvalidChannel);
    s.setDefault(@enumFromInt(channel), (value orelse return fail(error.NullInput)).*) catch |e| return fail(e);
    return 0;
}
export fn hamudi_material_height(handle: u64, material: u32, strength: f32) c_int {
    lock();
    defer mutex.unlock();
    const r = renderer(handle) catch |e| return fail(e);
    if (material >= r.material_count or !std.math.isFinite(strength) or strength < 0 or strength > 100) return fail(error.InvalidMaterial);
    r.sets[material][3] = strength;
    r.reset();
    return 0;
}
export fn hamudi_scene_unwrap_missing(handle: u64, out: ?*[256]u32) c_int {
    lock();
    defer mutex.unlock();
    const s = scene(handle) catch |e| return fail(e);
    const dst = out orelse return fail(error.NullOutput);
    var owned = lib.unwrap.missing(a, s.mesh) catch |e| return fail(e);
    const bvh = lib.geometry.Bvh.init(a, owned.mesh) catch |e| {
        owned.deinit();
        return fail(e);
    };
    const source_count = s.source_count;
    if (s.vertex_sources.len != 0) for (owned.vertex_sources) |*source| {
        source.* = s.vertex_sources[source.*];
    };
    s.deinit();
    s.* = .{ .mesh = owned.mesh, .bvh = bvh, .source_count = source_count, .vertex_sources = owned.vertex_sources };
    dst.* = owned.minimum_resolution;
    return 0;
}
fn gestureSession(handle: u64, gesture: u64) !*lib.painting.Session {
    const s = try surface(handle);
    if (s.active == null or s.active.?.token != gesture) return error.InvalidGesture;
    return s;
}
export fn hamudi_surface_revision(handle: u64, out: ?*u64) c_int {
    lock();
    defer mutex.unlock();
    const s = surface(handle) catch |e| return fail(e);
    (out orelse return fail(error.NullOutput)).* = s.revision;
    return 0;
}
export fn hamudi_surface_begin(handle: u64, expected: u64, layer: u32, channel: u32, color: ?*const m.V3, opacity: f32, erase: u32, out: ?*u64) c_int {
    lock();
    defer mutex.unlock();
    const s = surface(handle) catch |e| return fail(e);
    const dst = out orelse return fail(error.NullOutput);
    if (expected != s.revision) return fail(error.StaleRevision);
    if (channel >= lib.painting.channel_count) return fail(error.InvalidChannel);
    s.begin(layer, @enumFromInt(channel), (color orelse return fail(error.NullInput)).*, opacity, erase != 0) catch |e| return fail(e);
    dst.* = s.active.?.token;
    return 0;
}
fn nativeBrush(input: ?*const Brush) !lib.painting.Brush {
    const b = input orelse return error.NullInput;
    if (b.alpha >= 7) return error.InvalidBrush;
    const brush: lib.painting.Brush = .{ .workers = 8, .radius = b.radius, .hardness = b.hardness, .flow = b.flow, .spacing = b.spacing, .angle = b.angle, .alpha = @enumFromInt(b.alpha) };
    try brush.validate();
    return brush;
}
export fn hamudi_surface_stamp_uv(handle: u64, gesture: u64, u: f32, v: f32, pressure: f32, input: ?*const Brush) c_int {
    lock();
    defer mutex.unlock();
    const s = gestureSession(handle, gesture) catch |e| return fail(e);
    s.stampUv(.{ u, v }, nativeBrush(input) catch |e| return fail(e), pressure) catch |e| return fail(e);
    return 0;
}
export fn hamudi_surface_stamp_world_active(handle: u64, gesture: u64, scene_handle: u64, material: u32, point: ?*const m.V3, normal: ?*const m.V3, eye: ?*const m.V3, input: ?*const Brush) c_int {
    lock();
    defer mutex.unlock();
    const s = gestureSession(handle, gesture) catch |e| return fail(e);
    const mesh = scene(scene_handle) catch |e| return fail(e);
    const brush = nativeBrush(input) catch |e| return fail(e);
    worldStamp(s, mesh, material, point, normal, eye, brush) catch |e| return fail(e);
    return 0;
}
fn worldStamp(s: *lib.painting.Session, mesh: *Scene, material: u32, point: ?*const m.V3, normal: ?*const m.V3, eye: ?*const m.V3, brush: lib.painting.Brush) !void {
    if (mesh.uv == null or mesh.material != material or mesh.uv.?.width != s.document.width or mesh.uv.?.height != s.document.height) {
        const next = try lib.geometry.UvBuffer.init(a, mesh.mesh, s.document.width, s.document.height, material);
        if (mesh.uv) |*uv| uv.deinit();
        mesh.uv = next;
        mesh.material = material;
    }
    try s.stampWorld(mesh.mesh, &mesh.bvh, mesh.uv.?, (point orelse return error.NullInput).*, (normal orelse return error.NullInput).*, brush, if (eye) |e| e.* else null);
}
export fn hamudi_surface_stamp_image_uv(handle: u64, gesture: u64, u: f32, v: f32, pressure: f32, input: ?*const Brush, image: ?*const AlphaImage) c_int {
    lock();
    defer mutex.unlock();
    const s = gestureSession(handle, gesture) catch |e| return fail(e);
    s.stampUv(.{ u, v }, imageBrush(input, image) catch |e| return fail(e), pressure) catch |e| return fail(e);
    return 0;
}
export fn hamudi_surface_stamp_image_world(handle: u64, gesture: u64, scene_handle: u64, material: u32, point: ?*const m.V3, normal: ?*const m.V3, eye: ?*const m.V3, input: ?*const Brush, image: ?*const AlphaImage) c_int {
    lock();
    defer mutex.unlock();
    const s = gestureSession(handle, gesture) catch |e| return fail(e);
    const mesh = scene(scene_handle) catch |e| return fail(e);
    worldStamp(s, mesh, material, point, normal, eye, imageBrush(input, image) catch |e| return fail(e)) catch |e| return fail(e);
    return 0;
}
export fn hamudi_surface_preview(render_handle: u64, material: u32, surface_handle: u64, gesture: u64) c_int {
    lock();
    defer mutex.unlock();
    const r = renderer(render_handle) catch |e| return fail(e);
    const s = gestureSession(surface_handle, gesture) catch |e| return fail(e);
    var doc = s.previewDocument() catch |e| return fail(e);
    var preview = lib.painting.Session.init(a, doc.width, doc.height) catch |e| {
        doc.deinit();
        return fail(e);
    };
    defer preview.deinit();
    preview.document.deinit();
    preview.document = doc;
    @memset(preview.dirty, false);
    const stroke = s.active.?;
    preview.dirty_channels = @as(u32, 1) << @intFromEnum(stroke.channel);
    for (0..stroke.alpha.tiles_y) |y| for (0..stroke.alpha.tiles_x) |x| {
        if (stroke.alpha.tile(@intCast(x), @intCast(y)) != null) preview.dirty[y * stroke.alpha.tiles_x + x] = true;
    };
    @import("hamudi1").material_sync.applyCoverage(r, &preview, material, stroke.alpha) catch |e| return fail(e);
    return 0;
}
export fn hamudi_surface_commit(handle: u64, gesture: u64) c_int {
    lock();
    defer mutex.unlock();
    const s = gestureSession(handle, gesture) catch |e| return fail(e);
    s.commit() catch |e| return fail(e);
    return 0;
}
export fn hamudi_surface_cancel(handle: u64, gesture: u64) c_int {
    lock();
    defer mutex.unlock();
    const s = gestureSession(handle, gesture) catch |e| return fail(e);
    s.cancel();
    return 0;
}
export fn hamudi_set_environment_preset(handle: u64, name: ?[*]const u8, bytes: usize, width: u32) c_int {
    lock();
    defer mutex.unlock();
    const r = renderer(handle) catch |e| return fail(e);
    const label = slice(u8, name, bytes, 128) catch |e| return fail(e);
    const preset = @import("hamudi1").environment.Preset.parse(label) catch |e| return fail(e);
    r.setEnvironmentPreset(preset, width) catch |e| return fail(e);
    return 0;
}
export fn hamudi_set_environment_image(handle: u64, w: u32, h: u32, input: ?[*]const m.V3, components: usize) c_int {
    lock();
    defer mutex.unlock();
    const r = renderer(handle) catch |e| return fail(e);
    if (w == 0 or h == 0 or w > 4096 or h > 4096 or components != @as(u64, w) * h * 3) return fail(error.EnvironmentBudget);
    const data = slice(m.V3, input, components / 3, 16_777_216) catch |e| return fail(e);
    const env = @import("hamudi1").environment.Image{ .allocator = a, .width = w, .height = h, .pixels = @constCast(data) };
    r.setEnvironmentImage(env) catch |e| return fail(e);
    return 0;
}
export fn hamudi_set_environment_rotation(handle: u64, radians: f32) c_int {
    lock();
    defer mutex.unlock();
    const r = renderer(handle) catch |e| return fail(e);
    r.setEnvironmentRotation(radians) catch |e| return fail(e);
    return 0;
}
