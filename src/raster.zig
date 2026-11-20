//! Hardware rasterization over persistent hamudi scene buffers.
const std = @import("std");
const vk = @import("vulkan.zig");
const c = vk.c;
const check = vk.check;
const Image = struct {
    image: c.VkImage = null,
    memory: c.VkDeviceMemory = null,
    view: c.VkImageView = null,
    fn init(ctx: *vk.Context, width: u32, height: u32, depth: bool) !Image {
        var self: Image = .{};
        errdefer self.deinit(ctx);
        const format: c.VkFormat = if (depth) c.VK_FORMAT_D32_SFLOAT else c.VK_FORMAT_R8G8B8A8_UNORM;
        const info: c.VkImageCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = c.VK_IMAGE_TYPE_2D, .format = format, .extent = .{ .width = width, .height = height, .depth = 1 }, .mipLevels = 1, .arrayLayers = 1, .samples = c.VK_SAMPLE_COUNT_1_BIT, .tiling = c.VK_IMAGE_TILING_OPTIMAL, .usage = if (depth) c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT else c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT, .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE, .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED };
        try check(c.vkCreateImage(ctx.device, &info, null, &self.image));
        var req: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(ctx.device, self.image, &req);
        var mt: ?u32 = null;
        for (0..ctx.memory.memoryTypeCount) |i| {
            if (req.memoryTypeBits & (@as(u32, 1) << @intCast(i)) != 0 and ctx.memory.memoryTypes[i].propertyFlags & c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT != 0) {
                mt = @intCast(i);
                break;
            }
        }
        const alloc: c.VkMemoryAllocateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size, .memoryTypeIndex = mt orelse return error.DeviceLimit };
        try check(c.vkAllocateMemory(ctx.device, &alloc, null, &self.memory));
        try check(c.vkBindImageMemory(ctx.device, self.image, self.memory, 0));
        const view: c.VkImageViewCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = self.image, .viewType = c.VK_IMAGE_VIEW_TYPE_2D, .format = format, .subresourceRange = .{ .aspectMask = if (depth) c.VK_IMAGE_ASPECT_DEPTH_BIT else c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 } };
        try check(c.vkCreateImageView(ctx.device, &view, null, &self.view));
        return self;
    }
    fn deinit(self: *Image, ctx: *vk.Context) void {
        if (self.view != null) c.vkDestroyImageView(ctx.device, self.view, null);
        if (self.image != null) c.vkDestroyImage(ctx.device, self.image, null);
        if (self.memory != null) c.vkFreeMemory(ctx.device, self.memory, null);
        self.* = .{};
    }
};
pub const Raster = struct {
    layout: c.VkDescriptorSetLayout = null,
    pipeline_layout: c.VkPipelineLayout = null,
    pipeline: c.VkPipeline = null,
    background_pipeline: c.VkPipeline = null,
    pool: c.VkDescriptorPool = null,
    set: c.VkDescriptorSet = null,
    render_pass: c.VkRenderPass = null,
    framebuffer: c.VkFramebuffer = null,
    color: Image = .{},
    depth: Image = .{},
    width: u32 = 0,
    height: u32 = 0,
    pub fn init(ctx: *vk.Context) !Raster {
        var self: Raster = .{};
        errdefer self.deinit(ctx);
        var bindings: [13]c.VkDescriptorSetLayoutBinding = undefined;
        for (&bindings, 0..) |*b, i| b.* = .{ .binding = @intCast(i), .descriptorType = if (i == 0 or i == 12) c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER else c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT };
        const li: c.VkDescriptorSetLayoutCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 13, .pBindings = &bindings };
        try check(c.vkCreateDescriptorSetLayout(ctx.device, &li, null, &self.layout));
        const pl: c.VkPipelineLayoutCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1, .pSetLayouts = &self.layout };
        try check(c.vkCreatePipelineLayout(ctx.device, &pl, null, &self.pipeline_layout));
        const attachments = [_]c.VkAttachmentDescription{ .{ .format = c.VK_FORMAT_R8G8B8A8_UNORM, .samples = c.VK_SAMPLE_COUNT_1_BIT, .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE, .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE, .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE, .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED, .finalLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL }, .{ .format = c.VK_FORMAT_D32_SFLOAT, .samples = c.VK_SAMPLE_COUNT_1_BIT, .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE, .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE, .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE, .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED, .finalLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL } };
        const color: c.VkAttachmentReference = .{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
        const depth: c.VkAttachmentReference = .{ .attachment = 1, .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL };
        const sub: c.VkSubpassDescription = .{ .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS, .colorAttachmentCount = 1, .pColorAttachments = &color, .pDepthStencilAttachment = &depth };
        const deps = [_]c.VkSubpassDependency{ .{ .srcSubpass = c.VK_SUBPASS_EXTERNAL, .dstSubpass = 0, .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT, .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT, .srcAccessMask = 0, .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT }, .{ .srcSubpass = 0, .dstSubpass = c.VK_SUBPASS_EXTERNAL, .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, .dstStageMask = c.VK_PIPELINE_STAGE_TRANSFER_BIT, .srcAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, .dstAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT } };
        const rp: c.VkRenderPassCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, .attachmentCount = 2, .pAttachments = &attachments, .subpassCount = 1, .pSubpasses = &sub, .dependencyCount = 2, .pDependencies = &deps };
        try check(c.vkCreateRenderPass(ctx.device, &rp, null, &self.render_pass));
        const vs = try shader(ctx, @embedFile("spirv/preview_vs.spv"));
        defer c.vkDestroyShaderModule(ctx.device, vs, null);
        const fs = try shader(ctx, @embedFile("spirv/preview_fs.spv"));
        defer c.vkDestroyShaderModule(ctx.device, fs, null);
        const stages = [_]c.VkPipelineShaderStageCreateInfo{ .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = vs, .pName = "preview_vs" }, .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = fs, .pName = "preview_fs" } };
        const vertex: c.VkPipelineVertexInputStateCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
        const assembly: c.VkPipelineInputAssemblyStateCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST };
        const viewport: c.VkPipelineViewportStateCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .viewportCount = 1, .scissorCount = 1 };
        const raster: c.VkPipelineRasterizationStateCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO, .polygonMode = c.VK_POLYGON_MODE_FILL, .cullMode = c.VK_CULL_MODE_NONE, .frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE, .lineWidth = 1 };
        const ms: c.VkPipelineMultisampleStateCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT };
        const ds: c.VkPipelineDepthStencilStateCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO, .depthTestEnable = c.VK_TRUE, .depthWriteEnable = c.VK_TRUE, .depthCompareOp = c.VK_COMPARE_OP_LESS_OR_EQUAL };
        const color_blend: c.VkPipelineColorBlendAttachmentState = .{ .colorWriteMask = 15 };
        const blend_state: c.VkPipelineColorBlendStateCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, .attachmentCount = 1, .pAttachments = &color_blend };
        const dynamic_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
        const dynamic: c.VkPipelineDynamicStateCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO, .dynamicStateCount = 2, .pDynamicStates = &dynamic_states };
        const pi: c.VkGraphicsPipelineCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .stageCount = 2, .pStages = &stages, .pVertexInputState = &vertex, .pInputAssemblyState = &assembly, .pViewportState = &viewport, .pRasterizationState = &raster, .pMultisampleState = &ms, .pDepthStencilState = &ds, .pColorBlendState = &blend_state, .pDynamicState = &dynamic, .layout = self.pipeline_layout, .renderPass = self.render_pass, .subpass = 0 };
        try check(c.vkCreateGraphicsPipelines(ctx.device, null, 1, &pi, null, &self.pipeline));
        const bvs = try shader(ctx, @embedFile("spirv/background_vs.spv"));
        defer c.vkDestroyShaderModule(ctx.device, bvs, null);
        const bfs = try shader(ctx, @embedFile("spirv/background_fs.spv"));
        defer c.vkDestroyShaderModule(ctx.device, bfs, null);
        const background_stages = [_]c.VkPipelineShaderStageCreateInfo{ .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_VERTEX_BIT, .module = bvs, .pName = "background_vs" }, .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT, .module = bfs, .pName = "background_fs" } };
        const no_depth: c.VkPipelineDepthStencilStateCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO, .depthTestEnable = c.VK_FALSE, .depthWriteEnable = c.VK_FALSE };
        var background_info = pi;
        background_info.pStages = &background_stages;
        background_info.pDepthStencilState = &no_depth;
        try check(c.vkCreateGraphicsPipelines(ctx.device, null, 1, &background_info, null, &self.background_pipeline));

        const sizes = [_]c.VkDescriptorPoolSize{ .{ .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 2 }, .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 11 } };
        const pool: c.VkDescriptorPoolCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1, .poolSizeCount = 2, .pPoolSizes = &sizes };
        try check(c.vkCreateDescriptorPool(ctx.device, &pool, null, &self.pool));
        const set: c.VkDescriptorSetAllocateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = self.pool, .descriptorSetCount = 1, .pSetLayouts = &self.layout };
        try check(c.vkAllocateDescriptorSets(ctx.device, &set, &self.set));
        return self;
    }
    pub fn deinit(self: *Raster, ctx: *vk.Context) void {
        if (self.framebuffer != null) c.vkDestroyFramebuffer(ctx.device, self.framebuffer, null);
        self.color.deinit(ctx);
        self.depth.deinit(ctx);
        if (self.pool != null) c.vkDestroyDescriptorPool(ctx.device, self.pool, null);
        if (self.pipeline != null) c.vkDestroyPipeline(ctx.device, self.pipeline, null);
        if (self.background_pipeline != null) c.vkDestroyPipeline(ctx.device, self.background_pipeline, null);
        if (self.render_pass != null) c.vkDestroyRenderPass(ctx.device, self.render_pass, null);
        if (self.pipeline_layout != null) c.vkDestroyPipelineLayout(ctx.device, self.pipeline_layout, null);
        if (self.layout != null) c.vkDestroyDescriptorSetLayout(ctx.device, self.layout, null);
        self.* = .{};
    }
    pub fn resize(self: *Raster, ctx: *vk.Context, width: u32, height: u32) !void {
        if (width == self.width and height == self.height) return;
        var color = try Image.init(ctx, width, height, false);
        errdefer color.deinit(ctx);
        var depth = try Image.init(ctx, width, height, true);
        errdefer depth.deinit(ctx);
        var framebuffer: c.VkFramebuffer = null;
        const views = [_]c.VkImageView{ color.view, depth.view };
        const info: c.VkFramebufferCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, .renderPass = self.render_pass, .attachmentCount = 2, .pAttachments = &views, .width = width, .height = height, .layers = 1 };
        try check(c.vkCreateFramebuffer(ctx.device, &info, null, &framebuffer));
        if (self.framebuffer != null) c.vkDestroyFramebuffer(ctx.device, self.framebuffer, null);
        self.color.deinit(ctx);
        self.depth.deinit(ctx);
        self.framebuffer = framebuffer;
        self.color = color;
        self.depth = depth;
        self.width = width;
        self.height = height;
    }
    pub fn bind(self: *Raster, ctx: *vk.Context, buffers: *const [12]vk.Buffer, settings: *const vk.Buffer) void {
        var infos: [13]c.VkDescriptorBufferInfo = undefined;
        var writes: [13]c.VkWriteDescriptorSet = undefined;
        for (0..13) |i| {
            const b = if (i == 12) settings else &buffers[i];
            infos[i] = .{ .buffer = b.handle, .offset = 0, .range = b.size };
            writes[i] = .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = self.set, .dstBinding = @intCast(i), .descriptorCount = 1, .descriptorType = if (i == 0 or i == 12) c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER else c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .pBufferInfo = &infos[i] };
        }
        c.vkUpdateDescriptorSets(ctx.device, 13, &writes, 0, null);
    }
    pub fn draw(self: *Raster, ctx: *vk.Context, triangle_count: u32, out: ?*const vk.Buffer, background: [4]f32) void {
        const clear = [_]c.VkClearValue{ .{ .color = .{ .float32 = background } }, .{ .depthStencil = .{ .depth = 1, .stencil = 0 } } };
        const begin: c.VkRenderPassBeginInfo = .{ .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .renderPass = self.render_pass, .framebuffer = self.framebuffer, .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = self.width, .height = self.height } }, .clearValueCount = 2, .pClearValues = &clear };
        c.vkCmdBeginRenderPass(ctx.command, &begin, c.VK_SUBPASS_CONTENTS_INLINE);
        c.vkCmdBindPipeline(ctx.command, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline);
        c.vkCmdBindDescriptorSets(ctx.command, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline_layout, 0, 1, &self.set, 0, null);
        const viewport: c.VkViewport = .{ .x = 0, .y = 0, .width = @floatFromInt(self.width), .height = @floatFromInt(self.height), .minDepth = 0, .maxDepth = 1 };
        const scissor: c.VkRect2D = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = self.width, .height = self.height } };
        c.vkCmdSetViewport(ctx.command, 0, 1, &viewport);
        c.vkCmdSetScissor(ctx.command, 0, 1, &scissor);
        c.vkCmdBindPipeline(ctx.command, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.background_pipeline);
        c.vkCmdDraw(ctx.command, 3, 1, 0, 0);
        c.vkCmdBindPipeline(ctx.command, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline);
        c.vkCmdDraw(ctx.command, triangle_count * 3, 1, 0, 0);
        c.vkCmdEndRenderPass(ctx.command);
        if (out) |buffer| {
            const region: c.VkBufferImageCopy = .{ .bufferOffset = 0, .bufferRowLength = 0, .bufferImageHeight = 0, .imageSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 }, .imageOffset = .{ .x = 0, .y = 0, .z = 0 }, .imageExtent = .{ .width = self.width, .height = self.height, .depth = 1 } };
            c.vkCmdCopyImageToBuffer(ctx.command, self.color.image, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buffer.handle, 1, &region);
            ctx.barrier();
        }
    }
};
fn shader(ctx: *vk.Context, data: []const u8) !c.VkShaderModule {
    const aligned = try ctx.allocator.alignedAlloc(u8, .@"4", data.len);
    defer ctx.allocator.free(aligned);
    @memcpy(aligned, data);
    var module: c.VkShaderModule = null;
    const info: c.VkShaderModuleCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = data.len, .pCode = @ptrCast(aligned.ptr) };
    try check(c.vkCreateShaderModule(ctx.device, &info, null, &module));
    return module;
}
