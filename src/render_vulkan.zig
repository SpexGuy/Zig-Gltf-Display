const std = @import("std");
const vk = @import("vk");
const glfw = @import("glfw");
const imgui = @import("imgui");
const render = @import("render.zig");

const impl_glfw = @import("imgui_impl_glfw.zig");
const impl_vulkan = @import("imgui_impl_vulkan.zig");

const assert = std.debug.assert;

const USE_VULKAN_DEBUG_REPORT = std.debug.runtime_safety and false;
const IMGUI_UNLIMITED_FRAME_RATE = false;

const deviceExtensions = [_]vk.CString{vk.KHR_SWAPCHAIN_EXTENSION_NAME};

// ----------------------- Backend state -------------------------
// @TODO: Move this into swapchain state
var g_MainWindowData = impl_vulkan.Window{};
var g_MinImageCount = @as(u32, 2);
var g_SwapChainRebuild = false;
var g_SwapChainResizeWidth = @as(u32, 0);
var g_SwapChainResizeHeight = @as(u32, 0);
var g_FrameIndex = @as(u32, 0);
var g_SemaphoreIndex = @as(u32, 0);

// All of these are set up by init()
pub var window: *glfw.GLFWwindow = undefined;
pub var vkAllocator: ?*vk.AllocationCallbacks = undefined;
pub var instance: vk.Instance = undefined;
pub var physicalDevice: vk.PhysicalDevice = undefined;
pub var device: vk.Device = undefined;
pub var queueFamily: u32 = undefined;
pub var queue: vk.Queue = undefined;
pub var debugReport: if (USE_VULKAN_DEBUG_REPORT) vk.DebugReportCallbackEXT else void = undefined;
pub var pipelineCache: ?vk.PipelineCache = undefined;
pub var descriptorPool: vk.DescriptorPool = undefined;
pub var surface: vk.SurfaceKHR = undefined;

// ----------------------- Render types -------------------------
pub const Buffer = struct {
    buffer: vk.Buffer,
    // TODO VMA: better memory management
    memory: vk.DeviceMemory,
};

pub const RenderFrame = struct {
    frameIndex: u32,
    fsd: *impl_vulkan.FrameSemaphores,
    fd: *impl_vulkan.Frame,
};

pub const RenderPass = struct {
    cb: vk.CommandBuffer,
    wait_stage: vk.PipelineStageFlags align(4),
};

pub const RenderUpload = struct {
    commandBuffer: vk.CommandBuffer,
};

// ----------------------- Render interface functions -------------------------
pub fn init(allocator: *std.mem.Allocator, inWindow: *glfw.GLFWwindow) !void {
    window = inWindow;

    // Setup Vulkan
    if (glfw.glfwVulkanSupported() == 0)
        return error.VulkanNotSupportedByGLFW;

    var extensions_count: u32 = 0;
    var extensions_buffer = glfw.glfwGetRequiredInstanceExtensions(&extensions_count);
    const extensions = extensions_buffer[0..extensions_count];

    vkAllocator = null; // @TODO: Better vk allocator

    // Create Vulkan Instance
    {
        var create_info = vk.InstanceCreateInfo{
            .enabledExtensionCount = @intCast(u32, extensions.len),
            .ppEnabledExtensionNames = extensions.ptr,
        };

        if (USE_VULKAN_DEBUG_REPORT) {
            const layers = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};
            create_info.enabledLayerCount = @intCast(u32, layers.len);
            create_info.ppEnabledLayerNames = &layers;

            // Enable debug report extension (we need additional storage, so we duplicate the user array to add our new extension to it)
            const extensions_ext = try allocator.alloc([*:0]const u8, extensions.len + 1);
            defer allocator.free(extensions_ext);
            std.mem.copy([*:0]const u8, extensions_ext[0..extensions.len], extensions);
            extensions_ext[extensions.len] = "VK_EXT_debug_report";

            create_info.enabledExtensionCount = @intCast(u32, extensions_ext.len);
            create_info.ppEnabledExtensionNames = extensions_ext.ptr;

            // Create Vulkan Instance
            instance = try vk.CreateInstance(create_info, vkAllocator);
        } else {
            // Create Vulkan Instance without any debug features
            instance = try vk.CreateInstance(create_info, vkAllocator);
        }
    }
    errdefer vk.DestroyInstance(instance, vkAllocator);

    // Register debug callback
    if (USE_VULKAN_DEBUG_REPORT) {
        // Get the function pointer (required for any extensions)
        var vkCreateDebugReportCallbackEXT = @ptrCast(?@TypeOf(vk.vkCreateDebugReportCallbackEXT), vk.GetInstanceProcAddr(instance, "vkCreateDebugReportCallbackEXT")).?;

        // Setup the debug report callback
        var debug_report_ci = vk.DebugReportCallbackCreateInfoEXT{
            .flags = .{ .errorBit = true, .warning = true, .performanceWarning = true },
            .pfnCallback = debug_report,
            .pUserData = null,
        };
        var err = vkCreateDebugReportCallbackEXT(instance, &debug_report_ci, vkAllocator, &debugReport);
        if (@enumToInt(err) < 0) {
            return error.CreateDebugCallbackFailed;
        }
    }
    errdefer if (USE_VULKAN_DEBUG_REPORT) {
        // Remove the debug report callback
        const vkDestroyDebugReportCallbackEXT = @ptrCast(?@TypeOf(vk.vkDestroyDebugReportCallbackEXT), vk.GetInstanceProcAddr(instance, "vkDestroyDebugReportCallbackEXT"));
        assert(vkDestroyDebugReportCallbackEXT != null);
        vkDestroyDebugReportCallbackEXT.?(instance, debugReport, vkAllocator);
    };

    // Select GPU
    {
        const deviceCount = try vk.EnumeratePhysicalDevicesCount(instance);

        if (deviceCount == 0) {
            return error.FailedToFindGPUsWithVulkanSupport;
        }

        const devicesBuf = try allocator.alloc(vk.PhysicalDevice, deviceCount);
        defer allocator.free(devicesBuf);

        const devices = (try vk.EnumeratePhysicalDevices(instance, devicesBuf)).physicalDevices;

        physicalDevice = for (devices) |physDevice| {
            if (try isDeviceSuitable(allocator, physDevice)) {
                break physDevice;
            }
        } else return error.FailedToFindSuitableGPU;
    }

    // Select graphics queue family
    queueFamily = SelectQueueFamily: {
        var count = vk.GetPhysicalDeviceQueueFamilyPropertiesCount(physicalDevice);
        var queues = try allocator.alloc(vk.QueueFamilyProperties, count);
        defer allocator.free(queues);
        _ = vk.GetPhysicalDeviceQueueFamilyProperties(physicalDevice, queues);
        for (queues) |queueProps, i| {
            if (queueProps.queueFlags.graphics) {
                break :SelectQueueFamily @intCast(u32, i);
            }
        }
        return error.FailedToFindGraphicsQueue;
    };

    // Create Logical Device (with 1 queue)
    {
        var device_extensions = [_][*:0]const u8{"VK_KHR_swapchain"};
        var queue_priority = [_]f32{1.0};
        var queue_info = [_]vk.DeviceQueueCreateInfo{
            vk.DeviceQueueCreateInfo{
                .queueFamilyIndex = queueFamily,
                .queueCount = 1,
                .pQueuePriorities = &queue_priority,
            },
        };
        var create_info = vk.DeviceCreateInfo{
            .queueCreateInfoCount = @intCast(u32, queue_info.len),
            .pQueueCreateInfos = &queue_info,
            .enabledExtensionCount = @intCast(u32, device_extensions.len),
            .ppEnabledExtensionNames = &device_extensions,
        };
        device = try vk.CreateDevice(physicalDevice, create_info, vkAllocator);
    }
    errdefer vk.DestroyDevice(device, vkAllocator);

    queue = vk.GetDeviceQueue(device, queueFamily, 0);

    // Create Descriptor Pool
    {
        var pool_sizes = [_]vk.DescriptorPoolSize{
            vk.DescriptorPoolSize{ .inType = .SAMPLER, .descriptorCount = 1000 },
            vk.DescriptorPoolSize{ .inType = .COMBINED_IMAGE_SAMPLER, .descriptorCount = 1000 },
            vk.DescriptorPoolSize{ .inType = .SAMPLED_IMAGE, .descriptorCount = 1000 },
            vk.DescriptorPoolSize{ .inType = .STORAGE_IMAGE, .descriptorCount = 1000 },
            vk.DescriptorPoolSize{ .inType = .UNIFORM_TEXEL_BUFFER, .descriptorCount = 1000 },
            vk.DescriptorPoolSize{ .inType = .STORAGE_TEXEL_BUFFER, .descriptorCount = 1000 },
            vk.DescriptorPoolSize{ .inType = .UNIFORM_BUFFER, .descriptorCount = 1000 },
            vk.DescriptorPoolSize{ .inType = .STORAGE_BUFFER, .descriptorCount = 1000 },
            vk.DescriptorPoolSize{ .inType = .UNIFORM_BUFFER_DYNAMIC, .descriptorCount = 1000 },
            vk.DescriptorPoolSize{ .inType = .STORAGE_BUFFER_DYNAMIC, .descriptorCount = 1000 },
            vk.DescriptorPoolSize{ .inType = .INPUT_ATTACHMENT, .descriptorCount = 1000 },
        };
        var pool_info = vk.DescriptorPoolCreateInfo{
            .flags = .{ .freeDescriptorSet = true },
            .maxSets = 1000 * @intCast(u32, pool_sizes.len),
            .poolSizeCount = @intCast(u32, pool_sizes.len),
            .pPoolSizes = &pool_sizes,
        };
        descriptorPool = try vk.CreateDescriptorPool(device, pool_info, vkAllocator);
    }
    errdefer vk.DestroyDescriptorPool(device, descriptorPool, vkAllocator);

    // Create Window Surface
    const err = glfw.glfwCreateWindowSurface(instance, window, vkAllocator, &surface);
    if (@enumToInt(err) < 0)
        return error.CouldntCreateSurface;
    // GLFW says this call is necessary to clean up, but it crashes the program
    // so leaving it commented out for now.  If deinit/reinit is a thing we
    // want to support eventually, we should revisit this.
    //errdefer vk.DestroySurfaceKHR(instance, surface, vkAllocator);

    // Create Framebuffers
    {
        var w: c_int = 0;
        var h: c_int = 0;
        glfw.glfwGetFramebufferSize(window, &w, &h);
        _ = glfw.glfwSetFramebufferSizeCallback(window, glfw_resize_callback);
        const wd = &g_MainWindowData;
        wd.Surface = surface;
        wd.Allocator = allocator;

        var res = try vk.GetPhysicalDeviceSurfaceSupportKHR(physicalDevice, queueFamily, surface);
        if (res != vk.TRUE) {
            return error.NoWSISupport;
        }

        // Select Surface Format
        const requestSurfaceImageFormat = [_]vk.Format{ .B8G8R8A8_UNORM, .R8G8B8A8_UNORM, .B8G8R8_UNORM, .R8G8B8_UNORM };
        const requestSurfaceColorSpace = vk.ColorSpaceKHR.SRGB_NONLINEAR;
        wd.SurfaceFormat = try impl_vulkan.SelectSurfaceFormat(physicalDevice, surface, &requestSurfaceImageFormat, requestSurfaceColorSpace, allocator);

        // Select Present Mode
        if (IMGUI_UNLIMITED_FRAME_RATE) {
            var present_modes = [_]vk.PresentModeKHR{ .MAILBOX, .IMMEDIATE, .FIFO };
            wd.PresentMode = try impl_vulkan.SelectPresentMode(physicalDevice, surface, &present_modes, allocator);
        } else {
            var present_modes = [_]vk.PresentModeKHR{.FIFO};
            wd.PresentMode = try impl_vulkan.SelectPresentMode(physicalDevice, surface, &present_modes, allocator);
        }

        // Create SwapChain, RenderPass, Framebuffer, etc.
        assert(g_MinImageCount >= 2);
        try impl_vulkan.CreateWindow(instance, physicalDevice, device, wd, queueFamily, vkAllocator, @intCast(u32, w), @intCast(u32, h), g_MinImageCount);
    }
    errdefer impl_vulkan.DestroyWindow(instance, device, &g_MainWindowData, vkAllocator) catch {};
}

pub fn deinit() void {
    impl_vulkan.DestroyWindow(instance, device, &g_MainWindowData, vkAllocator) catch {};

    // GLFW says this call is necessary to clean up, but it crashes the program
    // so leaving it commented out for now.  If deinit/reinit is a thing we
    // want to support eventually, we should revisit this.
    //vk.DestroySurfaceKHR(instance, surface, vkAllocator);

    vk.DestroyDescriptorPool(device, descriptorPool, vkAllocator);

    if (USE_VULKAN_DEBUG_REPORT) {
        // Remove the debug report callback
        const vkDestroyDebugReportCallbackEXT = @ptrCast(?@TypeOf(vk.vkDestroyDebugReportCallbackEXT), vk.GetInstanceProcAddr(instance, "vkDestroyDebugReportCallbackEXT"));
        assert(vkDestroyDebugReportCallbackEXT != null);
        vkDestroyDebugReportCallbackEXT.?(instance, debugReport, vkAllocator);
    }

    vk.DestroyDevice(device, vkAllocator);
    vk.DestroyInstance(instance, vkAllocator);
}

pub fn initImgui(allocator: *std.mem.Allocator) !void {
    // Setup Platform/Renderer bindings
    var initResult = impl_glfw.InitForVulkan(window, true);
    assert(initResult);

    const wd = &g_MainWindowData;

    var init_info = impl_vulkan.InitInfo{
        .Allocator = allocator,
        .Instance = instance,
        .PhysicalDevice = physicalDevice,
        .Device = device,
        .QueueFamily = queueFamily,
        .Queue = queue,
        .PipelineCache = pipelineCache,
        .DescriptorPool = descriptorPool,
        .VkAllocator = vkAllocator,
        .MinImageCount = g_MinImageCount,
        .MSAASamples = .{},
        .ImageCount = wd.ImageCount,
    };
    try impl_vulkan.Init(&init_info, wd.RenderPass);

    // Load Fonts
    // - If no fonts are loaded, dear imgui will use the default font. You can also load multiple fonts and use imgui.PushFont()/PopFont() to select them.
    // - AddFontFromFileTTF() will return the ImFont* so you can store it if you need to select the font among multiple.
    // - If the file cannot be loaded, the function will return NULL. Please handle those errors in your application (e.g. use an assertion, or display an error and quit).
    // - The fonts will be rasterized at a given size (w/ oversampling) and stored into a texture when calling ImFontAtlas::Build()/GetTexDataAsXXXX(), which ImGui_ImplXXXX_NewFrame below will call.
    // - Read 'docs/FONTS.txt' for more instructions and details.
    // - Remember that in C/C++ if you want to include a backslash \ in a string literal you need to write a double backslash \\ !
    //io.Fonts.AddFontDefault();
    //io.Fonts.AddFontFromFileTTF("../../misc/fonts/Roboto-Medium.ttf", 16.0f);
    //io.Fonts.AddFontFromFileTTF("../../misc/fonts/Cousine-Regular.ttf", 15.0f);
    //io.Fonts.AddFontFromFileTTF("../../misc/fonts/DroidSans.ttf", 16.0f);
    //io.Fonts.AddFontFromFileTTF("../../misc/fonts/ProggyTiny.ttf", 10.0f);
    //ImFont* font = io.Fonts.AddFontFromFileTTF("c:\\Windows\\Fonts\\ArialUni.ttf", 18.0f, NULL, io.Fonts.GetGlyphRangesJapanese());
    //assert(font != NULL);

    // Upload Fonts
    // Use any command queue
    const command_pool = wd.Frames[0].CommandPool;
    const command_buffer = wd.Frames[0].CommandBuffer;

    try vk.ResetCommandPool(device, command_pool, .{});
    const begin_info = vk.CommandBufferBeginInfo{
        .flags = .{ .oneTimeSubmit = true },
    };
    try vk.BeginCommandBuffer(command_buffer, begin_info);

    try impl_vulkan.CreateFontsTexture(command_buffer);

    const end_info = vk.SubmitInfo{
        .commandBufferCount = 1,
        .pCommandBuffers = arrayPtr(&command_buffer),
    };
    try vk.EndCommandBuffer(command_buffer);
    try vk.QueueSubmit(queue, arrayPtr(&end_info), null);

    try vk.DeviceWaitIdle(device);
    impl_vulkan.DestroyFontUploadObjects();
}

pub fn deinitImgui() void {
    vk.DeviceWaitIdle(device) catch {};
    impl_vulkan.Shutdown();
    impl_glfw.Shutdown();
}

pub fn beginFrame() !void {
    if (g_SwapChainRebuild) {
        g_SwapChainRebuild = false;
        try impl_vulkan.SetMinImageCount(g_MinImageCount);
        try impl_vulkan.CreateWindow(instance, physicalDevice, device, &g_MainWindowData, queueFamily, vkAllocator, g_SwapChainResizeWidth, g_SwapChainResizeHeight, g_MinImageCount);
    }
}

pub fn beginImgui() void {
    // Start the Dear ImGui frame
    impl_vulkan.NewFrame();
    impl_glfw.NewFrame();
}

pub fn beginRender() !RenderFrame {
    const wd = &g_MainWindowData;
    const fsd = &wd.FrameSemaphores[g_SemaphoreIndex];
    g_SemaphoreIndex = (g_SemaphoreIndex + 1) % wd.ImageCount; // Now we can use the next set of semaphores

    const image_acquired_semaphore = fsd.ImageAcquiredSemaphore;
    const render_complete_semaphore = fsd.RenderCompleteSemaphore;
    const frameIndex = (try vk.AcquireNextImageKHR(device, wd.Swapchain.?, ~@as(u64, 0), image_acquired_semaphore, null)).imageIndex;

    const fd = &wd.Frames[frameIndex];
    _ = try vk.WaitForFences(device, arrayPtr(&fd.Fence), vk.TRUE, ~@as(u64, 0)); // wait indefinitely instead of periodically checking
    try vk.ResetFences(device, arrayPtr(&fd.Fence));
    try vk.ResetCommandPool(device, fd.CommandPool, .{});

    return RenderFrame{
        .frameIndex = frameIndex,
        .fsd = fsd,
        .fd = fd,
    };
}

pub fn endRender(frame: *RenderFrame) void {
    const wd = &g_MainWindowData;
    const render_complete_semaphore = frame.fsd.RenderCompleteSemaphore;
    var info = vk.PresentInfoKHR{
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = arrayPtr(&render_complete_semaphore),
        .swapchainCount = 1,
        .pSwapchains = arrayPtr(&wd.Swapchain.?),
        .pImageIndices = arrayPtr(&frame.frameIndex),
    };
    _ = vk.QueuePresentKHR(queue, info) catch @panic("QueuePresentKHR Failed!"); // TODO device lost
}

pub fn beginColorPass(frame: *RenderFrame, clearColor: imgui.Vec4) !RenderPass {
    const fd = frame.fd;
    {
        var info = vk.CommandBufferBeginInfo{
            .flags = .{ .oneTimeSubmit = true },
        };
        try vk.BeginCommandBuffer(fd.CommandBuffer, info);
    }
    {
        const wd = &g_MainWindowData;
        var info = vk.RenderPassBeginInfo{
            .renderPass = wd.RenderPass.?,
            .framebuffer = fd.Framebuffer,
            .renderArea = vk.Rect2D{
                .offset = vk.Offset2D{ .x = 0, .y = 0 },
                .extent = vk.Extent2D{ .width = wd.Width, .height = wd.Height },
            },
            .clearValueCount = 1,
            .pClearValues = @ptrCast([*]const vk.ClearValue, &clearColor),
        };
        vk.CmdBeginRenderPass(fd.CommandBuffer, info, .INLINE);
    }
    return RenderPass{
        .cb = fd.CommandBuffer,
        .wait_stage = .{ .colorAttachmentOutput = true },
    };
}

pub fn endRenderPass(frame: *RenderFrame, pass: *RenderPass) void {
    const fd = frame.fd;
    const fsd = frame.fsd;
    // Submit command buffer
    vk.CmdEndRenderPass(fd.CommandBuffer);
    vk.EndCommandBuffer(fd.CommandBuffer) catch @panic("EndCommandBuffer failed!");
    {
        var info = vk.SubmitInfo{
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = arrayPtr(&fsd.ImageAcquiredSemaphore),
            .pWaitDstStageMask = arrayPtr(&pass.wait_stage),
            .commandBufferCount = 1,
            .pCommandBuffers = arrayPtr(&fd.CommandBuffer),
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = arrayPtr(&fsd.RenderCompleteSemaphore),
        };
        vk.QueueSubmit(queue, arrayPtr(&info), fd.Fence) catch @panic("QueueSubmit failed!"); // TODO: device lost
    }
}

pub fn beginUpload(frame: *RenderFrame) !RenderUpload {
    const fd = frame.fd;
    {
        var info = vk.CommandBufferBeginInfo{
            .flags = .{ .oneTimeSubmit = true },
        };
        try vk.BeginCommandBuffer(fd.CommandBuffer, info);
    }
    return RenderUpload{
        .commandBuffer = fd.CommandBuffer,
    };
}

pub fn uploadCopyBuffer(
    frame: *RenderFrame,
    upload: *RenderUpload,
    source: *Buffer,
    sourceOffset: usize,
    dest: *Buffer,
    destOffset: usize,
    len: usize,
) void {
    const copyRegion = vk.BufferCopy{
        .srcOffset = sourceOffset,
        .dstOffset = destOffset,
        .size = len,
    };
    vk.CmdCopyBuffer(upload.commandBuffer, source.buffer, dest.buffer, arrayPtr(&copyRegion));
}

pub fn abortUpload(frame: *RenderFrame, upload: *RenderUpload) void {
    vk.ResetCommandBuffer(upload.commandBuffer, .{ .releaseResources = true }) catch {};
}

pub fn endUploadAndWait(frame: *RenderFrame, upload: *RenderUpload) void {
    vk.EndCommandBuffer(upload.commandBuffer) catch @panic("EndCommandBuffer failed!");
    const submitInfo = vk.SubmitInfo{
        .commandBufferCount = 1,
        .pCommandBuffers = arrayPtr(&upload.commandBuffer),
    };
    vk.QueueSubmit(queue, arrayPtr(&submitInfo), null) catch @panic("QueueSubmit failed!");
    vk.QueueWaitIdle(queue) catch @panic("QueueWaitIdle failed!");
}

pub fn createGpuBuffer(size: usize, flags: vk.BufferUsageFlags) !Buffer {
    return try createVkBuffer(size, flags.with(.{ .transferDst = true }), .{ .deviceLocal = true });
}

pub fn createStagingBuffer(size: usize) !Buffer {
    return try createVkBuffer(size, .{ .transferSrc = true }, .{ .hostVisible = true, .hostCoherent = true });
}

pub fn destroyBuffer(buffer: *Buffer) void {
    vk.DestroyBuffer(device, buffer.buffer, vkAllocator);
    vk.FreeMemory(device, buffer.memory, vkAllocator);
}

pub fn mapBuffer(buffer: *Buffer, offset: usize, length: usize) ![*]u8 {
    var result: [*]u8 = undefined;
    try vk.MapMemory(device, buffer.memory, offset, length, .{}, @ptrCast(**c_void, &result));
    return result;
}

pub fn flushMappedRange(buffer: *Buffer, mappedPtr: [*]u8, offset: usize, length: usize) !void {
    const range = vk.MappedMemoryRange{
        .memory = buffer.memory,
        .offset = offset,
        .size = length,
    };
    try vk.FlushMappedMemoryRanges(device, arrayPtr(&range));
}

pub fn unmapBuffer(buffer: *Buffer, mappedPtr: [*]u8, offset: usize, length: usize) void {
    vk.UnmapMemory(device, buffer.memory);
}

pub fn renderImgui(frame: *RenderFrame, pass: *RenderPass) !void {
    // Record Imgui Draw Data and draw funcs into command buffer
    try impl_vulkan.RenderDrawData(imgui.GetDrawData(), pass.cb);
}

// ----------------------- Backend functions -------------------------
pub fn createVkBuffer(size: usize, usageFlags: vk.BufferUsageFlags, memoryFlags: vk.MemoryPropertyFlags) !Buffer {
    const info = vk.BufferCreateInfo{
        .size = size,
        .usage = usageFlags,
        .sharingMode = .EXCLUSIVE,
    };

    const buffer = try vk.CreateBuffer(device, info, vkAllocator);
    errdefer vk.DestroyBuffer(device, buffer, vkAllocator);

    const stagingReqs = vk.GetBufferMemoryRequirements(device, buffer);
    const stagingAllocInfo = vk.MemoryAllocateInfo{
        .allocationSize = stagingReqs.size,
        .memoryTypeIndex = getMemoryTypeIndex(stagingReqs.memoryTypeBits, memoryFlags),
    };

    // TODO VMA: better allocation management
    const memory = try vk.AllocateMemory(device, stagingAllocInfo, vkAllocator);
    errdefer vk.FreeMemory(device, memory, vkAllocator);
    try vk.BindBufferMemory(device, buffer, memory, 0);

    return Buffer{
        .buffer = buffer,
        .memory = memory,
    };
}

pub fn getMemoryTypeIndex(memType: u32, properties: vk.MemoryPropertyFlags) u32 {
    return impl_vulkan.MemoryType(properties, memType).?;
}

fn isDeviceSuitable(allocator: *std.mem.Allocator, inDevice: vk.PhysicalDevice) !bool {
    // @TODO: Proper checks
    if (@ptrToInt(allocator) != 0) return true;
    return error.OutOfMemory;
    //const indices = try findQueueFamilies(allocator, inDevice);
    //
    //const extensionsSupported = try checkDeviceExtensionSupport(allocator, inDevice);
    //
    //var swapChainAdequate = false;
    //if (extensionsSupported) {
    //    var swapChainSupport = try querySwapChainSupport(allocator, inDevice);
    //    defer swapChainSupport.deinit();
    //    swapChainAdequate = swapChainSupport.formats.len != 0 and swapChainSupport.presentModes.len != 0;
    //}
    //
    //return indices.isComplete() and extensionsSupported and swapChainAdequate;
}

fn checkDeviceExtensionSupport(allocator: *std.mem.Allocator, inDevice: vk.PhysicalDevice) !bool {
    var extensionCount = try vk.EnumerateDeviceExtensionPropertiesCount(inDevice, null);

    const availableExtensionsBuf = try allocator.alloc(vk.ExtensionProperties, extensionCount);
    defer allocator.free(availableExtensionsBuf);

    var availableExtensions = (try vk.EnumerateDeviceExtensionProperties(inDevice, null, availableExtensionsBuf)).properties;

    var requiredExtensions = std.HashMap([*:0]const u8, void, hash_cstr, eql_cstr).init(allocator);
    defer requiredExtensions.deinit();

    for (deviceExtensions) |device_ext| {
        _ = try requiredExtensions.put(device_ext, {});
    }

    for (availableExtensions) |extension| {
        _ = requiredExtensions.remove(&extension.extensionName);
    }

    return requiredExtensions.count() == 0;
}

fn glfw_resize_callback(inWindow: ?*glfw.GLFWwindow, w: c_int, h: c_int) callconv(.C) void {
    g_SwapChainRebuild = true;
    g_SwapChainResizeWidth = @intCast(u32, w);
    g_SwapChainResizeHeight = @intCast(u32, h);
}

fn debug_report(flags: vk.DebugReportFlagsEXT.IntType, objectType: vk.DebugReportObjectTypeEXT, object: u64, location: usize, messageCode: i32, pLayerPrefix: ?[*:0]const u8, pMessage: ?[*:0]const u8, pUserData: ?*c_void) callconv(vk.CallConv) vk.Bool32 {
    std.debug.warn("[vulkan] ObjectType: {}\nMessage: {s}\n\n", .{ objectType, pMessage });
    @panic("VK Error");
    //return vk.FALSE;
}

fn hash_cstr(a: [*:0]const u8) u32 {
    // FNV 32-bit hash
    var h: u32 = 2166136261;
    var i: usize = 0;
    while (a[i] != 0) : (i += 1) {
        h ^= a[i];
        h *%= 16777619;
    }
    return h;
}

fn eql_cstr(a: [*:0]const u8, b: [*:0]const u8) bool {
    return std.cstr.cmp(a, b) == 0;
}

/// Takes a pointer type like *T, *const T, *align(4)T, etc,
/// returns the pointer type *[1]T, *const [1]T, *align(4) [1]T, etc.
fn ArrayPtrType(comptime ptrType: type) type {
    comptime {
        // Check that the input is of type *T
        var info = @typeInfo(ptrType);
        assert(info == .Pointer);
        assert(info.Pointer.size == .One);
        assert(info.Pointer.sentinel == null);

        // Create the new value type, [1]T
        const arrayInfo = std.builtin.TypeInfo{
            .Array = .{
                .len = 1,
                .child = info.Pointer.child,
                .sentinel = @as(?info.Pointer.child, null),
            },
        };

        // Patch the type to be *[1]T, preserving other modifiers
        const singleArrayType = @Type(arrayInfo);
        info.Pointer.child = singleArrayType;
        // also need to change the type of the sentinel
        // we checked that this is null above so no work needs to be done here.
        info.Pointer.sentinel = @as(?singleArrayType, null);
        return @Type(info);
    }
}

pub fn arrayPtr(ptr: anytype) ArrayPtrType(@TypeOf(ptr)) {
    return @as(ArrayPtrType(@TypeOf(ptr)), ptr);
}
