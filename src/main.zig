const std = @import("std");
const lib = @import("texture_painting");
const m = lib.math;
const g = lib.geometry;
const render = @import("hamudi1").renderer;
const Input = struct { positions: []const m.V3, normals: []const m.V3, uvs: []const m.V2, indices: []const u32, parts: []const struct { material: u32, start: u32, count: u32 }, materials: []const struct { width: u32, height: u32, rgba16: []const u8, metallic: f32 = 0, roughness: f32 = 0.5, emissive: m.V3 = .{ 0, 0, 0 } }, camera: m.Camera, environment: m.V3 = .{ 0.5, 0.5, 0.5 }, exposure: f32 = 1, filmic: bool = false };
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len < 7) return error.UsageExpectedSceneOutputWidthHeightSamples;
    const data = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], a, .limited(64 * 1024 * 1024));
    const parsed = try std.json.parseFromSlice(Input, a, data, .{ .ignore_unknown_fields = true });
    const input = parsed.value;
    const w = try std.fmt.parseInt(u32, args[3], 10);
    const h = try std.fmt.parseInt(u32, args[4], 10);
    const samples = try std.fmt.parseInt(u32, args[5], 10);
    if (samples == 0 or samples > 4096) return error.SampleBudget;
    const material_ids = try a.alloc(u32, input.indices.len / 3);
    @memset(material_ids, 0);
    for (input.parts) |p| {
        if (p.start % 3 != 0 or p.count % 3 != 0 or @as(u64, p.start) + p.count > input.indices.len or p.material >= input.materials.len) return error.InvalidPart;
        @memset(material_ids[p.start / 3 ..][0 .. p.count / 3], p.material);
    }
    const mesh: g.Mesh = .{ .positions = input.positions, .normals = input.normals, .uvs = input.uvs, .indices = input.indices, .materials = material_ids };
    var bvh = try g.Bvh.init(a, mesh);
    defer bvh.deinit();
    const mats = try a.alloc(render.Material, input.materials.len);
    for (input.materials, mats) |src, *dst| {
        if (std.fs.path.isAbsolute(src.rgba16) or std.mem.indexOf(u8, src.rgba16, "..") != null) return error.InvalidTexturePath;
        const path = try std.fs.path.join(a, &.{ std.fs.path.dirname(args[1]) orelse ".", src.rgba16 });
        const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, a, .limited(128 * 1024 * 1024));
        if (bytes.len != @as(u64, src.width) * src.height * 8) return error.InvalidTexture;
        const rgba = try a.alloc([4]u16, bytes.len / 8);
        for (rgba, 0..) |*p, i| for (0..4) |k| {
            p[k] = std.mem.readInt(u16, bytes[i * 8 + k * 2 ..][0..2], .little);
        };
        dst.* = .{ .width = src.width, .height = src.height, .rgba = rgba, .metallic = src.metallic, .roughness = src.roughness, .emissive = src.emissive };
    }
    const start = render.gpu.nanoseconds();
    var r = try render.Renderer.init(a);
    defer r.deinit();
    try r.setMesh(mesh, &bvh);
    try r.setMaterials(mats);
    try r.setEnvironment(input.environment);
    try r.resize(w, h);
    const settings: render.Settings = .{ .exposure = input.exposure, .filmic = input.filmic, .denoise = if (args.len > 7) !std.mem.eql(u8, args[7], "raw") else true };
    const mode = args[6];
    var done: u32 = 0;
    const is_raster = std.mem.eql(u8, mode, "raster");
    if (!is_raster and !std.mem.eql(u8, mode, "gpu")) return error.InvalidMode;
    while (!is_raster and done < samples) {
        const spp = @min(samples - done, 8);
        try r.pass(input.camera, settings, spp);
        done += spp;
    }
    var frame_ms: std.ArrayList(f64) = .empty;
    if (is_raster) {
        _ = try r.preview(input.camera, .{ .exposure = input.exposure, .filmic = input.filmic }, false);
        for (0..samples) |i| {
            var camera = input.camera;
            camera.yaw += @as(f32, @floatFromInt(i)) * 0.0002;
            const tick = render.gpu.nanoseconds();
            _ = try r.preview(camera, .{ .exposure = input.exposure, .filmic = input.filmic }, false);
            try frame_ms.append(a, @as(f64, @floatFromInt(render.gpu.nanoseconds() - tick)) / 1e6);
        }
    }
    const rgba = if (is_raster) (try r.preview(input.camera, .{ .exposure = input.exposure, .filmic = input.filmic }, true)).? else try r.pixels(settings);
    var ppm: std.ArrayList(u8) = .empty;
    try ppm.appendSlice(a, try std.fmt.allocPrint(a, "P6\n{d} {d}\n255\n", .{ w, h }));
    for (0..@as(usize, w) * h) |i| try ppm.appendSlice(a, rgba[i * 4 ..][0..3]);
    var file = try std.Io.Dir.cwd().createFile(init.io, args[2], .{ .exclusive = true });
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, ppm.items);
    const report = try std.json.Stringify.valueAlloc(a, .{ .adapter = r.ctx.name(), .width = w, .height = h, .samples = samples, .seconds = @as(f64, @floatFromInt(render.gpu.nanoseconds() - start)) / 1e9, .stats = r.stats, .warm_frame_ms_without_readback = frame_ms.items }, .{});
    const report_path = try std.fmt.allocPrint(a, "{s}.json", .{args[2]});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = report_path, .data = report });
}
