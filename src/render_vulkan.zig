const std = @import("std");
const vk = @import("vk");
const glfw = @import("glfw");
const imgui = @import("imgui");

const impl_glfw = @import("imgui_impl_glfw.zig");
const impl_vulkan = @import("imgui_impl_vulkan.zig");

const assert = std.debug.assert;

const USE_VULKAN_DEBUG_REPORT = std.debug.runtime_safety;
const IMGUI_UNLIMITED_FRAME_RATE = false;

const deviceExtensions = [_]vk.CString{vk.KHR_SWAPCHAIN_EXTENSION_NAME};

// @TODO: Move this into swapchain state
var g_MainWindowData = impl_vulkan.Window{};
var g_MinImageCount = u32(2);
var g_SwapChainRebuild = false;
var g_SwapChainResizeWidth = u32(0);
var g_SwapChainResizeHeight = u32(0);
var g_FrameIndex = u32(0);
var g_SemaphoreIndex = u32(0);

pub const RenderBackend = struct {
    const Self = @This();

    window: *glfw.GLFWwindow,
    vkAllocator: ?*vk.AllocationCallbacks,
    instance: vk.Instance,
    physicalDevice: vk.PhysicalDevice,
    device: vk.Device,
    queueFamily: u32,
    queue: vk.Queue,
    debugReport: if (USE_VULKAN_DEBUG_REPORT) vk.DebugReportCallbackEXT else void,
    pipelineCache: ?vk.PipelineCache,
    descriptorPool: vk.DescriptorPool,
    surface: vk.SurfaceKHR,

    pub fn init(allocator: *std.mem.Allocator, window: *glfw.GLFWwindow) !Self {
        // Setup Vulkan
        if (glfw.glfwVulkanSupported() == 0)
            return error.VulkanNotSupportedByGLFW;

        var extensions_count: u32 = 0;
        var extensions_buffer = glfw.glfwGetRequiredInstanceExtensions(&extensions_count);
        const extensions = extensions_buffer[0..extensions_count];

        var debugReport: if (USE_VULKAN_DEBUG_REPORT) vk.DebugReportCallbackEXT else void = undefined;
        const vkAllocator: ?*vk.AllocationCallbacks = null; // @TODO: Better vk allocator

        // Create Vulkan Instance
        var instance = CreateInstance: {
            var create_info = vk.InstanceCreateInfo{
                .enabledExtensionCount = @intCast(u32, extensions.len),
                .ppEnabledExtensionNames = extensions.ptr,
            };

            if (USE_VULKAN_DEBUG_REPORT) {
                // Enabling multiple validation layers grouped as LunarG standard validation
                const layers = [_][*]const u8{c"VK_LAYER_LUNARG_standard_validation"};
                create_info.enabledLayerCount = @intCast(u32, layers.len);
                create_info.ppEnabledLayerNames = &layers;

                // Enable debug report extension (we need additional storage, so we duplicate the user array to add our new extension to it)
                const extensions_ext = try allocator.alloc([*]const u8, extensions.len + 1);
                defer allocator.free(extensions_ext);
                std.mem.copy([*]const u8, extensions_ext[0..extensions.len], extensions);
                extensions_ext[extensions.len] = c"VK_EXT_debug_report";

                create_info.enabledExtensionCount = @intCast(u32, extensions_ext.len);
                create_info.ppEnabledExtensionNames = extensions_ext.ptr;

                // Create Vulkan Instance
                const instance = try vk.CreateInstance(create_info, vkAllocator);

                // Get the function pointer (required for any extensions)
                var vkCreateDebugReportCallbackEXT = @ptrCast(?@typeOf(vk.vkCreateDebugReportCallbackEXT), vk.GetInstanceProcAddr(instance, c"vkCreateDebugReportCallbackEXT")).?;

                // Setup the debug report callback
                var debug_report_ci = vk.DebugReportCallbackCreateInfoEXT{
                    .flags = vk.DebugReportFlagBitsEXT.ERROR_BIT | vk.DebugReportFlagBitsEXT.WARNING_BIT | vk.DebugReportFlagBitsEXT.PERFORMANCE_WARNING_BIT,
                    .pfnCallback = debug_report,
                    .pUserData = null,
                };
                var err = vkCreateDebugReportCallbackEXT(instance, &debug_report_ci, vkAllocator, &debugReport);
                if (@enumToInt(err) < 0) {
                    return error.CreateDebugCallbackFailed;
                }
                break :CreateInstance instance;
            } else {
                // Create Vulkan Instance without any debug feature
                const instance = try vk.CreateInstance(create_info, vkAllocator);
                break :CreateInstance instance;
            }
        };

        // Select GPU
        const physicalDevice = SelectGPU: {
            const deviceCount = try vk.EnumeratePhysicalDevicesCount(instance);

            if (deviceCount == 0) {
                return error.FailedToFindGPUsWithVulkanSupport;
            }

            const devicesBuf = try allocator.alloc(vk.PhysicalDevice, deviceCount);
            defer allocator.free(devicesBuf);

            const devices = (try vk.EnumeratePhysicalDevices(instance, devicesBuf)).physicalDevices;

            const physicalDevice = for (devices) |device| {
                if (try isDeviceSuitable(allocator, device)) {
                    break device;
                }
            } else return error.FailedToFindSuitableGPU;
            break :SelectGPU physicalDevice;
        };

        // Select graphics queue family
        const queueFamily = SelectQueueFamily: {
            var count = vk.GetPhysicalDeviceQueueFamilyPropertiesCount(physicalDevice);
            var queues = try allocator.alloc(vk.QueueFamilyProperties, count);
            defer allocator.free(queues);
            _ = vk.GetPhysicalDeviceQueueFamilyProperties(physicalDevice, queues);
            for (queues) |queue, i| {
                if (queue.queueFlags & vk.QueueFlagBits.GRAPHICS_BIT != 0) {
                    break :SelectQueueFamily @intCast(u32, i);
                }
            }
            return error.FailedToFindGraphicsQueue;
        };

        // Create Logical Device (with 1 queue)
        const device = CreateLogicalDevice: {
            var device_extensions = [_][*]const u8{c"VK_KHR_swapchain"};
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
            break :CreateLogicalDevice try vk.CreateDevice(physicalDevice, create_info, vkAllocator);
        };

        const queue = vk.GetDeviceQueue(device, queueFamily, 0);

        // Create Descriptor Pool
        const descriptorPool = CreateDescriptorPool: {
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
                .flags = vk.DescriptorPoolCreateFlagBits.FREE_DESCRIPTOR_SET_BIT,
                .maxSets = 1000 * @intCast(u32, pool_sizes.len),
                .poolSizeCount = @intCast(u32, pool_sizes.len),
                .pPoolSizes = &pool_sizes,
            };
            break :CreateDescriptorPool try vk.CreateDescriptorPool(device, pool_info, vkAllocator);
        };

        // Create Window Surface
        var surface: vk.SurfaceKHR = undefined;
        const err = glfw.glfwCreateWindowSurface(instance, window, vkAllocator, &surface);
        if (@enumToInt(err) < 0)
            return error.CouldntCreateSurface;

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

        return RenderBackend{
            .window = window,
            .vkAllocator = vkAllocator,
            .instance = instance,
            .physicalDevice = physicalDevice,
            .device = device,
            .queueFamily = queueFamily,
            .queue = queue,
            .debugReport = debugReport,
            .pipelineCache = null,
            .descriptorPool = descriptorPool,
            .surface = surface,
        };
    }

    pub fn deinit(self: *Self) void {
        impl_vulkan.DestroyWindow(self.instance, self.device, &g_MainWindowData, self.vkAllocator) catch {};

        vk.DestroySurfaceKHR(self.instance, self.surface, self.vkAllocator);
        vk.DestroyDescriptorPool(self.device, self.descriptorPool, self.vkAllocator);

        if (USE_VULKAN_DEBUG_REPORT) {
            // Remove the debug report callback
            const vkDestroyDebugReportCallbackEXT = @ptrCast(?@typeOf(vk.vkDestroyDebugReportCallbackEXT), vk.GetInstanceProcAddr(self.instance, c"vkDestroyDebugReportCallbackEXT"));
            assert(vkDestroyDebugReportCallbackEXT != null);
            vkDestroyDebugReportCallbackEXT.?(self.instance, self.debugReport, self.vkAllocator);
        }

        vk.DestroyDevice(self.device, self.vkAllocator);
        vk.DestroyInstance(self.instance, self.vkAllocator);
    }

    pub fn initImgui(self: *Self, allocator: *std.mem.Allocator) !void {
        // Setup Platform/Renderer bindings
        var initResult = impl_glfw.InitForVulkan(self.window, true);
        assert(initResult);

        const wd = &g_MainWindowData;

        var init_info = impl_vulkan.InitInfo{
            .Allocator = allocator,
            .Instance = self.instance,
            .PhysicalDevice = self.physicalDevice,
            .Device = self.device,
            .QueueFamily = self.queueFamily,
            .Queue = self.queue,
            .PipelineCache = self.pipelineCache,
            .DescriptorPool = self.descriptorPool,
            .VkAllocator = self.vkAllocator,
            .MinImageCount = g_MinImageCount,
            .MSAASamples = 0,
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

        try vk.ResetCommandPool(self.device, command_pool, 0);
        const begin_info = vk.CommandBufferBeginInfo{
            .flags = vk.CommandBufferUsageFlagBits.ONE_TIME_SUBMIT_BIT,
        };
        try vk.BeginCommandBuffer(command_buffer, begin_info);

        try impl_vulkan.CreateFontsTexture(command_buffer);

        const end_info = vk.SubmitInfo{
            .commandBufferCount = 1,
            .pCommandBuffers = arrayPtr(&command_buffer),
        };
        try vk.EndCommandBuffer(command_buffer);
        try vk.QueueSubmit(self.queue, arrayPtr(&end_info), null);

        try vk.DeviceWaitIdle(self.device);
        impl_vulkan.DestroyFontUploadObjects();
    }

    pub fn deinitImgui(self: *Self) void {
        vk.DeviceWaitIdle(self.device) catch {};
        impl_vulkan.Shutdown();
        impl_glfw.Shutdown();
    }

    pub fn beginFrame(self: *Self) !void {
        if (g_SwapChainRebuild) {
            g_SwapChainRebuild = false;
            try impl_vulkan.SetMinImageCount(g_MinImageCount);
            try impl_vulkan.CreateWindow(self.instance, self.physicalDevice, self.device, &g_MainWindowData, self.queueFamily, self.vkAllocator, g_SwapChainResizeWidth, g_SwapChainResizeHeight, g_MinImageCount);
        }
    }

    pub fn beginImgui(self: *Self) void {
        // Start the Dear ImGui frame
        impl_vulkan.NewFrame();
        impl_glfw.NewFrame();
    }

    pub fn beginRender(self: *Self) !RenderFrame {
        const wd = &g_MainWindowData;
        const fsd = &wd.FrameSemaphores[g_SemaphoreIndex];
        g_SemaphoreIndex = (g_SemaphoreIndex + 1) % wd.ImageCount; // Now we can use the next set of semaphores

        const image_acquired_semaphore = fsd.ImageAcquiredSemaphore;
        const render_complete_semaphore = fsd.RenderCompleteSemaphore;
        const frameIndex = (try vk.AcquireNextImageKHR(self.device, wd.Swapchain.?, ~u64(0), image_acquired_semaphore, null)).imageIndex;

        const fd = &wd.Frames[frameIndex];
        _ = try vk.WaitForFences(self.device, arrayPtr(&fd.Fence), vk.TRUE, ~u64(0)); // wait indefinitely instead of periodically checking
        try vk.ResetFences(self.device, arrayPtr(&fd.Fence));
        try vk.ResetCommandPool(self.device, fd.CommandPool, 0);

        return RenderFrame{
            .frameIndex = frameIndex,
            .fsd = fsd,
            .fd = fd,
        };
    }

    pub fn endRender(self: *Self, frame: *RenderFrame) void {
        const wd = &g_MainWindowData;
        const render_complete_semaphore = frame.fsd.RenderCompleteSemaphore;
        var info = vk.PresentInfoKHR{
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = arrayPtr(&render_complete_semaphore),
            .swapchainCount = 1,
            .pSwapchains = arrayPtr(&wd.Swapchain.?),
            .pImageIndices = arrayPtr(&frame.frameIndex),
        };
        _ = vk.QueuePresentKHR(self.queue, info) catch @panic("QueuePresentKHR Failed!"); // TODO device lost
    }

    pub fn beginColorPass(self: *Self, frame: *RenderFrame, clearColor: imgui.Vec4) !RenderPass {
        const fd = frame.fd;
        {
            var info = vk.CommandBufferBeginInfo{
                .flags = vk.CommandBufferUsageFlagBits.ONE_TIME_SUBMIT_BIT,
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
            .wait_stage = vk.PipelineStageFlagBits.COLOR_ATTACHMENT_OUTPUT_BIT,
        };
    }

    pub fn endRenderPass(self: *Self, frame: *RenderFrame, pass: *RenderPass) void {
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
            vk.QueueSubmit(self.queue, arrayPtr(&info), fd.Fence) catch @panic("QueueSubmit failed!"); // TODO: device lost
        }
    }

    pub fn renderImgui(self: *Self, frame: *RenderFrame, pass: *RenderPass) !void {
        // Record Imgui Draw Data and draw funcs into command buffer
        try impl_vulkan.RenderDrawData(imgui.GetDrawData(), pass.cb);
    }
};

pub const RenderFrame = struct {
    frameIndex: u32,
    fsd: *impl_vulkan.FrameSemaphores,
    fd: *impl_vulkan.Frame,
};

pub const RenderPass = struct {
    cb: vk.CommandBuffer,
    wait_stage: vk.PipelineStageFlags,
};

fn isDeviceSuitable(allocator: *std.mem.Allocator, device: vk.PhysicalDevice) !bool {
    // @TODO: Proper checks
    if (@ptrToInt(allocator) != 0) return true;
    return error.OutOfMemory;
    //const indices = try findQueueFamilies(allocator, device);
    //
    //const extensionsSupported = try checkDeviceExtensionSupport(allocator, device);
    //
    //var swapChainAdequate = false;
    //if (extensionsSupported) {
    //    var swapChainSupport = try querySwapChainSupport(allocator, device);
    //    defer swapChainSupport.deinit();
    //    swapChainAdequate = swapChainSupport.formats.len != 0 and swapChainSupport.presentModes.len != 0;
    //}
    //
    //return indices.isComplete() and extensionsSupported and swapChainAdequate;
}

fn checkDeviceExtensionSupport(allocator: *std.mem.Allocator, device: vk.PhysicalDevice) !bool {
    var extensionCount = try vk.EnumerateDeviceExtensionPropertiesCount(device, null);

    const availableExtensionsBuf = try allocator.alloc(vk.ExtensionProperties, extensionCount);
    defer allocator.free(availableExtensionsBuf);

    var availableExtensions = (try vk.EnumerateDeviceExtensionProperties(device, null, availableExtensionsBuf)).properties;

    var requiredExtensions = std.HashMap([*]const u8, void, hash_cstr, eql_cstr).init(allocator);
    defer requiredExtensions.deinit();

    for (deviceExtensions) |device_ext| {
        _ = try requiredExtensions.put(device_ext, {});
    }

    for (availableExtensions) |extension| {
        _ = requiredExtensions.remove(&extension.extensionName);
    }

    return requiredExtensions.count() == 0;
}

extern fn glfw_resize_callback(window: ?*glfw.GLFWwindow, w: c_int, h: c_int) void {
    g_SwapChainRebuild = true;
    g_SwapChainResizeWidth = @intCast(u32, w);
    g_SwapChainResizeHeight = @intCast(u32, h);
}

extern fn debug_report(flags: vk.DebugReportFlagsEXT, objectType: vk.DebugReportObjectTypeEXT, object: u64, location: usize, messageCode: i32, pLayerPrefix: ?[*]const u8, pMessage: ?[*]const u8, pUserData: ?*c_void) vk.Bool32 {
    std.debug.warn("[vulkan] ObjectType: {}\nMessage: {}\n\n", objectType, pMessage);
    @panic("VK Error");
    //return vk.FALSE;
}

fn hash_cstr(a: [*]const u8) u32 {
    // FNV 32-bit hash
    var h: u32 = 2166136261;
    var i: usize = 0;
    while (a[i] != 0) : (i += 1) {
        h ^= a[i];
        h *%= 16777619;
    }
    return h;
}

fn eql_cstr(a: [*]const u8, b: [*]const u8) bool {
    return std.cstr.cmp(a, b) == 0;
}

// converts *T to *[1]T
fn arrayPtrType(comptime ptrType: type) type {
    const info = @typeInfo(ptrType);
    if (info.Pointer.is_const) {
        return *const [1]ptrType.Child;
    } else {
        return *[1]ptrType.Child;
    }
}

fn arrayPtr(ptr: var) arrayPtrType(@typeOf(ptr)) {
    return @ptrCast(arrayPtrType(@typeOf(ptr)), ptr);
}
