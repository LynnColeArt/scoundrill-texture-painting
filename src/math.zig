const std = @import("std");
pub const V2 = [2]f32;
pub const V3 = [3]f32;
pub const V4 = [4]f32;
pub fn add(a: V3, b: V3) V3 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}
pub fn sub(a: V3, b: V3) V3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}
pub fn mul(a: V3, b: V3) V3 {
    return .{ a[0] * b[0], a[1] * b[1], a[2] * b[2] };
}
pub fn scale(a: V3, s: f32) V3 {
    return .{ a[0] * s, a[1] * s, a[2] * s };
}
pub fn dot(a: V3, b: V3) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
pub fn cross(a: V3, b: V3) V3 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}
pub fn length(a: V3) f32 {
    return @sqrt(dot(a, a));
}
pub fn norm(a: V3) V3 {
    const l = length(a);
    return if (l > 1e-20 and std.math.isFinite(l)) scale(a, 1 / l) else .{ 0, 0, 1 };
}
pub fn mix(a: V3, b: V3, t: f32) V3 {
    return add(scale(a, 1 - t), scale(b, t));
}
pub fn finite(a: V3) bool {
    return std.math.isFinite(a[0]) and std.math.isFinite(a[1]) and std.math.isFinite(a[2]);
}
pub fn srgb(x: f32) f32 {
    const v = std.math.clamp(x, 0, 1);
    return if (v <= 0.0031308) v * 12.92 else 1.055 * std.math.pow(f32, v, 1.0 / 2.4) - 0.055;
}
pub fn linear(x: f32) f32 {
    const v = std.math.clamp(x, 0, 1);
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}
pub fn u16of(x: f32) u16 {
    return if (std.math.isFinite(x)) @intFromFloat(@floor(std.math.clamp(x, 0, 1) * 65535 + 0.5)) else 0;
}
pub fn u8of(x: f32) u8 {
    return if (std.math.isFinite(x)) @intFromFloat(@floor(std.math.clamp(x, 0, 1) * 255 + 0.5)) else 0;
}
pub const Ray = struct { origin: V3, dir: V3 };
pub const Camera = struct {
    target: V3 = .{ 0, 0, 0 },
    yaw: f32 = 0.7,
    pitch: f32 = 0.25,
    distance: f32 = 3,
    fov: f32 = 45,
    scene_radius: f32 = 1,
    ortho: bool = false,
    free: bool = false,
    orient: V4 = .{ 0, 0, 0, 1 },
    pub fn eye(self: Camera) V3 {
        const v: V3 = if (self.free) self.rotate(.{ 0, 0, 1 }) else .{ @cos(self.pitch) * @sin(self.yaw), @sin(self.pitch), @cos(self.pitch) * @cos(self.yaw) };
        return add(self.target, scale(v, self.distance));
    }
    fn rotate(self: Camera, v: V3) V3 {
        const q: V3 = self.orient[0..3].*;
        const t = scale(cross(q, v), 2);
        return add(v, add(scale(t, self.orient[3]), cross(q, t)));
    }
    pub fn forward(self: Camera) V3 {
        return norm(sub(self.target, self.eye()));
    }
    pub fn basis(self: Camera) [3]V3 {
        const f = self.forward();
        const up: V3 = if (self.free) self.rotate(.{ 0, 1, 0 }) else .{ 0, 1, 0 };
        const r = norm(cross(f, up));
        return .{ r, cross(r, f), f };
    }
    pub fn validate(self: Camera) !void {
        if (!finite(self.target) or !std.math.isFinite(self.yaw) or !std.math.isFinite(self.pitch) or !std.math.isFinite(self.distance) or self.distance <= 0 or !std.math.isFinite(self.fov) or self.fov < 5 or self.fov > 150 or !std.math.isFinite(self.scene_radius) or self.scene_radius <= 0) return error.InvalidCamera;
    }
    pub fn inverseVP(self: Camera, aspect: f32) [16]f32 {
        const b = self.basis();
        const e = self.eye();
        const r = @max(self.scene_radius, 1e-3);
        const near = @max(@max(self.distance - r * 4, r * 0.01), 1e-4);
        const far = self.distance + r * 50;
        const h = @tan(self.fov * std.math.pi / 360);
        // Inverse projection followed by camera-to-world. Column-major, Vulkan/WebGPU z in [0,1].
        if (self.ortho) {
            const n = @min(near, 0.01);
            const x = scale(b[0], h * self.distance * aspect);
            const y = scale(b[1], h * self.distance);
            const z = scale(b[2], far - n);
            const p = add(e, scale(b[2], n));
            return .{ x[0], x[1], x[2], 0, y[0], y[1], y[2], 0, z[0], z[1], z[2], 0, p[0], p[1], p[2], 1 };
        }
        const a = 1 / far - 1 / near;
        const x = scale(b[0], h * aspect);
        const y = scale(b[1], h);
        const z = scale(e, a);
        const p = add(b[2], scale(e, 1 / near));
        return .{ x[0], x[1], x[2], 0, y[0], y[1], y[2], 0, z[0], z[1], z[2], a, p[0], p[1], p[2], 1 / near };
    }
    pub fn ray(self: Camera, uv: V2, aspect: f32) Ray {
        const b = self.basis();
        const h = @tan(self.fov * std.math.pi / 360);
        const offset = add(scale(b[0], (uv[0] * 2 - 1) * h * aspect), scale(b[1], (1 - uv[1] * 2) * h));
        return .{ .origin = if (self.ortho) add(self.eye(), scale(offset, self.distance)) else self.eye(), .dir = if (self.ortho) b[2] else norm(add(b[2], offset)) };
    }
};
test "linear color roundtrip" {
    for (0..256) |i| {
        const x = @as(f32, @floatFromInt(i)) / 255;
        try std.testing.expectApproxEqAbs(x, srgb(linear(x)), 2e-6);
    }
}
test "camera center" {
    const c: Camera = .{ .yaw = 0, .pitch = 0 };
    try std.testing.expectEqual(V3{ 0, 0, -1 }, c.ray(.{ 0.5, 0.5 }, 1).dir);
}
