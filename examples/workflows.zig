//! End-to-end library consumers for the three requested authoring applications.
const std = @import("std");
const lib = @import("texture_painting");
const render = @import("hamudi1").renderer;
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len != 2) return error.ExpectedNewOutputDirectory;
    try std.Io.Dir.cwd().createDir(init.io, args[1], .default_dir);
    var dir = try std.Io.Dir.cwd().openDir(init.io, args[1], .{});
    defer dir.close(init.io);
    const mesh: lib.geometry.Mesh = .{ .positions = &.{ .{ -1, -1, 0 }, .{ 1, -1, 0 }, .{ 1, 1, 0 }, .{ -1, 1, 0 } }, .normals = &.{ .{ 0, 0, 1 }, .{ 0, 0, 1 }, .{ 0, 0, 1 }, .{ 0, 0, 1 } }, .uvs = &.{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } }, .indices = &.{ 0, 1, 2, 0, 2, 3 } };
    var bvh = try lib.geometry.Bvh.init(a, mesh);
    defer bvh.deinit();
    var uv = try lib.geometry.UvBuffer.init(a, mesh, 256, 256, null);
    defer uv.deinit();
    var renderer = try render.Renderer.init(a);
    defer renderer.deinit();
    try renderer.setMesh(mesh, &bvh);
    try renderer.setEnvironment(.{ 0.25, 0.25, 0.25 });
    try renderer.resize(512, 512);
    var reports: std.ArrayList(struct { name: []const u8, painted_tiles: usize, project_bytes: usize, undo_restored: bool }) = .empty;
    for ([_][]const u8{ "skin-makeup", "building-textures", "detailing" }, 0..) |name, index| {
        var session = try lib.painting.Session.init(a, 256, 256);
        defer session.deinit();
        const base = try session.addLayer("Base material", .fill);
        const color: lib.math.V3 = switch (index) {
            0 => .{ 0.55, 0.28, 0.16 },
            1 => .{ 0.7, 0.55, 0.35 },
            else => .{ 0.2, 0.23, 0.27 },
        };
        try session.setFill(base, .base_color, color, if (index == 1) .checker else .uniform, 8);
        try session.setFill(base, .roughness, .{ 0.6, 0.6, 0.6 }, .uniform, 8);
        const paint = try session.addLayer("Authored detail", .paint);
        const before = session.document.pixel(.base_color, 128, 128);
        try session.begin(paint, .base_color, switch (index) {
            0 => .{ 0.65, 0.025, 0.045 },
            1 => .{ 0.03, 0.15, 0.45 },
            else => .{ 0.8, 0.6, 0.15 },
        }, 0.8, false);
        if (index == 0) {
            try session.strokeUv(&.{ .{ 0.35, 0.45 }, .{ 0.5, 0.5 }, .{ 0.65, 0.45 } }, .{ .radius = 0.04, .hardness = 0.35, .flow = 0.4 });
        } else if (index == 1) {
            try session.stampUv(.{ 0.5, 0.5 }, .{ .radius = 0.19, .alpha = .square, .angle = 0.15 }, 1);
        } else {
            try session.stampUv(.{ 0.5, 0.5 }, .{ .radius = 0.2, .alpha = .star }, 1);
        }
        try session.commit();
        const after = session.document.pixel(.base_color, 128, 128);
        if (std.meta.eql(before, after)) return error.PaintDidNotChangeSurface;
        if (!(try session.undo()) or !std.meta.eql(before, session.document.pixel(.base_color, 128, 128))) return error.UndoFailed;
        if (!(try session.redo()) or !std.meta.eql(after, session.document.pixel(.base_color, 128, 128))) return error.RedoFailed;
        const project = try lib.image_io.save(a, session.document);
        var loaded = try lib.image_io.load(a, project);
        defer loaded.deinit();
        const image = try a.alloc([4]u16, 256 * 256);
        try loaded.region(.base_color, 0, 0, 256, 256, image);
        const first = try a.alloc([4]u16, 256 * 256);
        try session.document.region(.base_color, 0, 0, 256, 256, first);
        if (!std.mem.eql([4]u16, image, first)) return error.ProjectChangedPixels;
        const png = try lib.image_io.exportChannel(a, loaded, .base_color, .{});
        try dir.writeFile(init.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}-albedo.png", .{name}), .data = png });
        try dir.writeFile(init.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}.hamudi.json", .{name}), .data = project });
        try renderer.setMaterials(&.{.{ .width = 256, .height = 256, .rgba = image, .roughness = if (index == 2) 0.25 else 0.65, .metallic = if (index == 2) 0.8 else 0 }});
        const frame = (try renderer.preview(.{ .yaw = 0.12, .pitch = 0.05, .distance = 3.5 }, .{}, true)).?;
        const rgba16 = try a.alloc([4]u16, 512 * 512);
        for (rgba16, 0..) |*p, i| for (0..4) |k| {
            p[k] = @as(u16, frame[i * 4 + k]) * 257;
        };
        const shot = try lib.image_io.png(a, 512, 512, rgba16, .{ .color = false });
        try dir.writeFile(init.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}-viewport.png", .{name}), .data = shot });
        try reports.append(a, .{ .name = name, .painted_tiles = loaded.layers.items[paint].pixels[0].?.allocated(), .project_bytes = project.len, .undo_restored = true });
    }
    for ([_]lib.bake.Kind{ .world_normal, .ambient_occlusion, .curvature, .position, .thickness }) |kind| {
        const image = try lib.bake.generate(a, kind, mesh, &bvh, uv, .{ .samples = 16 });
        const png = try lib.image_io.png(a, 256, 256, image, .{ .bits = .sixteen, .color = false });
        try dir.writeFile(init.io, .{ .sub_path = try std.fmt.allocPrint(a, "map-{s}.png", .{@tagName(kind)}), .data = png });
    }
    const report = try std.json.Stringify.valueAlloc(a, .{ .adapter = renderer.ctx.name(), .workflows = reports.items, .maps = 5, .geometry_uploads = renderer.stats.geometry_uploads }, .{});
    try dir.writeFile(init.io, .{ .sub_path = "acceptance.json", .data = report });
}
