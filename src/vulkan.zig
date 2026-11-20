//! Native Vulkan ownership and compute dispatch. The caller serializes access.
const std = @import("std");
pub const config = @import("hamudi_options");
pub const c = @cImport({
    @cInclude("vulkan/vulkan.h");
    @cInclude("time.h");
});
pub const Error = error{ VulkanFailed, NoComputeDevice, NoHostMemory, DeviceLimit, GpuTimeout };
pub fn check(result: c.VkResult) Error!void {
    if (result != c.VK_SUCCESS) {
        std.log.err("Vulkan returned {d}", .{result});
        return error.VulkanFailed;
    }
}
pub const Context = struct {
    pub const Device = enum { automatic, hardware, cpu };
    allocator: std.mem.Allocator,
    instance: c.VkInstance = null,
    physical: c.VkPhysicalDevice = null,
    device: c.VkDevice = null,
    queue: c.VkQueue = null,
    pool: c.VkCommandPool = null,
    command: c.VkCommandBuffer = null,
    fence: c.VkFence = null,
    memory: c.VkPhysicalDeviceMemoryProperties = undefined,
    properties: c.VkPhysicalDeviceProperties = undefined,
    mapped_local_bytes: usize = 0,
    device_storage_bytes: usize = 0,
    pub fn init(a: std.mem.Allocator) !Context {
        return initDevice(a, .automatic);
    }
    pub fn initDevice(a: std.mem.Allocator, preference: Device) !Context {
        var self: Context = .{ .allocator = a };
        errdefer self.deinit();
        const app: c.VkApplicationInfo = .{ .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "hamudi-1", .applicationVersion = 1, .pEngineName = "hamudi-1", .apiVersion = c.VK_API_VERSION_1_1 };
        const info: c.VkInstanceCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
        try check(c.vkCreateInstance(&info, null, &self.instance));
        var count: u32 = 0;
        try check(c.vkEnumeratePhysicalDevices(self.instance, &count, null));
        if (count == 0 or count > 32) return error.NoComputeDevice;
        var devices: [32]c.VkPhysicalDevice = undefined;
        try check(c.vkEnumeratePhysicalDevices(self.instance, &count, &devices));
        var family: ?u32 = null;
        var score: u32 = 0;
        for (devices[0..count]) |p| {
            var prop: c.VkPhysicalDeviceProperties = undefined;
            c.vkGetPhysicalDeviceProperties(p, &prop);
            const cpu = prop.deviceType == c.VK_PHYSICAL_DEVICE_TYPE_CPU;
            if ((preference == .cpu and !cpu) or (preference == .hardware and cpu)) continue;
            var n: u32 = 0;
            c.vkGetPhysicalDeviceQueueFamilyProperties(p, &n, null);
            if (n > 64) continue;
            var families: [64]c.VkQueueFamilyProperties = undefined;
            c.vkGetPhysicalDeviceQueueFamilyProperties(p, &n, &families);
            for (families[0..n], 0..) |f, i| {
                if (f.queueFlags & (c.VK_QUEUE_COMPUTE_BIT | c.VK_QUEUE_GRAPHICS_BIT) != (c.VK_QUEUE_COMPUTE_BIT | c.VK_QUEUE_GRAPHICS_BIT)) continue;
                const s: u32 = if (prop.deviceType == c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) 3 else if (prop.deviceType == c.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU) 2 else 1;
                if (s > score) {
                    self.physical = p;
                    self.properties = prop;
                    family = @intCast(i);
                    score = s;
                }
                break;
            }
        }
        const fi = family orelse return error.NoComputeDevice;
        if (self.properties.limits.maxPerStageDescriptorStorageBuffers < 11 or self.properties.limits.maxUniformBufferRange < 4288) return error.DeviceLimit;
        c.vkGetPhysicalDeviceMemoryProperties(self.physical, &self.memory);
        const priority: f32 = 1;
        const qi: c.VkDeviceQueueCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = fi, .queueCount = 1, .pQueuePriorities = &priority };
        const di: c.VkDeviceCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qi };
        try check(c.vkCreateDevice(self.physical, &di, null, &self.device));
        c.vkGetDeviceQueue(self.device, fi, 0, &self.queue);
        const pi: c.VkCommandPoolCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = fi };
        try check(c.vkCreateCommandPool(self.device, &pi, null, &self.pool));
        const ai: c.VkCommandBufferAllocateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = self.pool, .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
        try check(c.vkAllocateCommandBuffers(self.device, &ai, &self.command));
        const ff: c.VkFenceCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
        try check(c.vkCreateFence(self.device, &ff, null, &self.fence));
        return self;
    }
    pub fn deinit(self: *Context) void {
        if (self.device != null) {
            _ = c.vkDeviceWaitIdle(self.device);
            if (self.fence != null) c.vkDestroyFence(self.device, self.fence, null);
            if (self.pool != null) c.vkDestroyCommandPool(self.device, self.pool, null);
            c.vkDestroyDevice(self.device, null);
        }
        if (self.instance != null) c.vkDestroyInstance(self.instance, null);
        self.* = undefined;
    }
    pub fn name(self: *const Context) []const u8 {
        return std.mem.sliceTo(&self.properties.deviceName, 0);
    }
    pub fn begin(self: *Context) !void {
        try check(c.vkResetCommandBuffer(self.command, 0));
        const bi: c.VkCommandBufferBeginInfo = .{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
        try check(c.vkBeginCommandBuffer(self.command, &bi));
    }
    pub fn barrier(self: *Context) void {
        const b: c.VkMemoryBarrier = .{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT | c.VK_ACCESS_TRANSFER_WRITE_BIT | c.VK_ACCESS_HOST_WRITE_BIT, .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT | c.VK_ACCESS_HOST_READ_BIT };
        c.vkCmdPipelineBarrier(self.command, c.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, c.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 1, &b, 0, null, 0, null);
    }
    pub fn submit(self: *Context) !void {
        try check(c.vkEndCommandBuffer(self.command));
        try check(c.vkResetFences(self.device, 1, &self.fence));
        const si: c.VkSubmitInfo = .{ .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &self.command };
        try check(c.vkQueueSubmit(self.queue, 1, &si, self.fence));
        const r = c.vkWaitForFences(self.device, 1, &self.fence, c.VK_TRUE, 30_000_000_000);
        if (r == c.VK_TIMEOUT) return error.GpuTimeout;
        try check(r);
    }
};
pub const Buffer = struct {
    handle: c.VkBuffer = null,
    memory: c.VkDeviceMemory = null,
    bytes: []u8 = &.{},
    size: usize = 0,
    local_accounting: usize = 0,
    device_accounting: usize = 0,
    const Policy = enum { host, resident, device };
    pub fn init(ctx: *Context, size: usize, uniform: bool) !Buffer {
        return initPolicy(ctx, size, uniform, if (uniform or config.force_host_buffers) .host else .resident);
    }
    pub fn initReadback(ctx: *Context, size: usize) !Buffer {
        return initPolicy(ctx, size, false, .host);
    }
    pub fn initDevice(ctx: *Context, size: usize) !Buffer {
        return initPolicy(ctx, size, false, if (config.force_host_buffers) .host else .device);
    }
    fn initPolicy(ctx: *Context, size: usize, uniform: bool, policy: Policy) !Buffer {
        if (size > 512 * 1024 * 1024 or (!uniform and size > ctx.properties.limits.maxStorageBufferRange)) return error.DeviceLimit;
        var self: Buffer = .{};
        errdefer self.deinit(ctx);
        const bi: c.VkBufferCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = @max(size, 16), .usage = (if (uniform) @as(u32, c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT) else @as(u32, c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT)) | c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT, .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE };
        try check(c.vkCreateBuffer(ctx.device, &bi, null, &self.handle));
        self.size = @max(size, 16);
        var req: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(ctx.device, self.handle, &req);
        var tried: u32 = 0;
        var selected_flags: u32 = 0;
        while (self.memory == null) {
            var mt: ?u32 = null;
            var best: u32 = 0;
            for (0..ctx.memory.memoryTypeCount) |i| {
                const bit = @as(u32, 1) << @intCast(i);
                if (req.memoryTypeBits & bit == 0 or tried & bit != 0) continue;
                const flags = ctx.memory.memoryTypes[i].propertyFlags;
                const local = flags & c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT != 0;
                const visible = flags & (c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) == (c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
                const cpu = ctx.properties.deviceType == c.VK_PHYSICAL_DEVICE_TYPE_CPU;
                if (policy == .device and !local) continue;
                if (policy != .device and !visible) continue;
                // BAR apertures can be only 256 MiB. Reserve at most 64 MiB per
                // context for small resident data; allocation failure falls back
                // to host memory instead of exhausting the mapped local heap.
                if (policy != .device and local and !cpu and (policy == .host or req.size > 32 * 1024 * 1024 or ctx.mapped_local_bytes + req.size > 64 * 1024 * 1024)) continue;
                const score: u32 = if (policy == .device) (if (!visible) 4 else 3) else if (local and !cpu) 4 else if (flags & c.VK_MEMORY_PROPERTY_HOST_CACHED_BIT != 0) 3 else 2;
                if (score > best) {
                    best = score;
                    mt = @intCast(i);
                    selected_flags = flags;
                }
            }
            const index = mt orelse return if (policy == .device) error.NoDeviceMemory else error.NoHostMemory;
            tried |= @as(u32, 1) << @intCast(index);
            const mi: c.VkMemoryAllocateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size, .memoryTypeIndex = index };
            const result = c.vkAllocateMemory(ctx.device, &mi, null, &self.memory);
            if (result != c.VK_SUCCESS) {
                self.memory = null;
                if (result != c.VK_ERROR_OUT_OF_DEVICE_MEMORY and result != c.VK_ERROR_OUT_OF_HOST_MEMORY) try check(result);
            }
        }
        try check(c.vkBindBufferMemory(ctx.device, self.handle, self.memory, 0));
        if (policy != .device) {
            var p: ?*anyopaque = null;
            try check(c.vkMapMemory(ctx.device, self.memory, 0, c.VK_WHOLE_SIZE, 0, &p));
            self.bytes = @as([*]u8, @ptrCast(p.?))[0..self.size];
            @memset(self.bytes, 0);
            if (selected_flags & c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT != 0 and ctx.properties.deviceType != c.VK_PHYSICAL_DEVICE_TYPE_CPU) {
                self.local_accounting = @intCast(req.size);
                ctx.mapped_local_bytes += self.local_accounting;
            }
        } else {
            self.device_accounting = @intCast(req.size);
            ctx.device_storage_bytes += self.device_accounting;
        }
        return self;
    }
    pub fn deinit(self: *Buffer, ctx: *Context) void {
        if (self.bytes.len > 0) c.vkUnmapMemory(ctx.device, self.memory);
        if (self.handle != null) c.vkDestroyBuffer(ctx.device, self.handle, null);
        if (self.memory != null) c.vkFreeMemory(ctx.device, self.memory, null);
        ctx.mapped_local_bytes -= self.local_accounting;
        ctx.device_storage_bytes -= self.device_accounting;
        self.* = .{};
    }
    pub fn write(self: Buffer, data: []const u8) !void {
        if (data.len > self.bytes.len) return error.DeviceLimit;
        @memcpy(self.bytes[0..data.len], data);
    }
};
pub const View = struct { buffer: *const Buffer, offset: usize = 0, size: usize = 0 };
pub const Program = struct {
    layout: c.VkDescriptorSetLayout = null,
    pipeline_layout: c.VkPipelineLayout = null,
    pipeline: c.VkPipeline = null,
    pool: c.VkDescriptorPool = null,
    sets: [8]c.VkDescriptorSet = @splat(null),
    bindings: u32 = 0,
    pub fn init(ctx: *Context, spirv: []const u8, entry: [*:0]const u8, bindings: u32) !Program {
        var self: Program = .{ .bindings = bindings };
        errdefer self.deinit(ctx);
        var bb: [18]c.VkDescriptorSetLayoutBinding = undefined;
        if (bindings > bb.len) return error.DeviceLimit;
        for (bb[0..bindings], 0..) |*b, i| b.* = .{ .binding = @intCast(i), .descriptorType = if (i == 0) c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER else c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT };
        const li: c.VkDescriptorSetLayoutCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = bindings, .pBindings = &bb };
        try check(c.vkCreateDescriptorSetLayout(ctx.device, &li, null, &self.layout));
        const pl: c.VkPipelineLayoutCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1, .pSetLayouts = &self.layout };
        try check(c.vkCreatePipelineLayout(ctx.device, &pl, null, &self.pipeline_layout));
        const aligned = try ctx.allocator.alignedAlloc(u8, .@"4", spirv.len);
        defer ctx.allocator.free(aligned);
        @memcpy(aligned, spirv);
        var module: c.VkShaderModule = null;
        const sm: c.VkShaderModuleCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = spirv.len, .pCode = @ptrCast(aligned.ptr) };
        try check(c.vkCreateShaderModule(ctx.device, &sm, null, &module));
        defer c.vkDestroyShaderModule(ctx.device, module, null);
        const ci: c.VkComputePipelineCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO, .stage = .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_COMPUTE_BIT, .module = module, .pName = entry }, .layout = self.pipeline_layout };
        try check(c.vkCreateComputePipelines(ctx.device, null, 1, &ci, null, &self.pipeline));
        const ps = [_]c.VkDescriptorPoolSize{ .{ .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 8 }, .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 8 * bindings } };
        const pi: c.VkDescriptorPoolCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 8, .poolSizeCount = 2, .pPoolSizes = &ps };
        try check(c.vkCreateDescriptorPool(ctx.device, &pi, null, &self.pool));
        const layouts: [8]c.VkDescriptorSetLayout = @splat(self.layout);
        const ai: c.VkDescriptorSetAllocateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = self.pool, .descriptorSetCount = 8, .pSetLayouts = &layouts };
        try check(c.vkAllocateDescriptorSets(ctx.device, &ai, &self.sets));
        return self;
    }
    pub fn deinit(self: *Program, ctx: *Context) void {
        if (self.pool != null) c.vkDestroyDescriptorPool(ctx.device, self.pool, null);
        if (self.pipeline != null) c.vkDestroyPipeline(ctx.device, self.pipeline, null);
        if (self.pipeline_layout != null) c.vkDestroyPipelineLayout(ctx.device, self.pipeline_layout, null);
        if (self.layout != null) c.vkDestroyDescriptorSetLayout(ctx.device, self.layout, null);
        self.* = .{};
    }
    pub fn bind(self: *Program, ctx: *Context, slot: usize, views: []const View) !void {
        if (slot >= 8 or views.len != self.bindings) return error.DeviceLimit;
        var info: [18]c.VkDescriptorBufferInfo = undefined;
        var writes: [18]c.VkWriteDescriptorSet = undefined;
        for (views, 0..) |v, i| {
            if (v.offset > v.buffer.size) return error.DeviceLimit;
            const size = if (v.size > 0) v.size else v.buffer.size - v.offset;
            if (size == 0 or v.offset + size > v.buffer.size) return error.DeviceLimit;
            info[i] = .{ .buffer = v.buffer.handle, .offset = v.offset, .range = size };
            writes[i] = .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = self.sets[slot], .dstBinding = @intCast(i), .descriptorCount = 1, .descriptorType = if (i == 0) c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER else c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &info[i] };
        }
        c.vkUpdateDescriptorSets(ctx.device, @intCast(views.len), &writes, 0, null);
    }
    pub fn dispatch(self: *Program, ctx: *Context, slot: usize, width: u32, height: u32) void {
        c.vkCmdBindPipeline(ctx.command, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline);
        c.vkCmdBindDescriptorSets(ctx.command, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.sets[slot], 0, null);
        c.vkCmdDispatch(ctx.command, (width + 7) / 8, (height + 7) / 8, 1);
        ctx.barrier();
    }
};
pub fn nanoseconds() u64 {
    var t: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &t);
    return @as(u64, @intCast(t.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(t.tv_nsec));
}
