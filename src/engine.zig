const std = @import("std");
const imgui = @import("imgui");
const glfw = @import("glfw");

usingnamespace @import("render.zig");

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const g_Engine = &engine_instance_memory;
var g_EngineInitialized = false;
var engine_instance_memory: Engine = undefined;

const Engine = struct {
    const Self = @This();

    allocator: *Allocator,
    window: *glfw.GLFWwindow,
    render: RenderInterface,

    pub fn init(self: *Self, allocator: *Allocator) !void {
        assert(!g_EngineInitialized);

        // Setup GLFW window
        _ = glfw.glfwSetErrorCallback(glfw_error_callback);
        if (glfw.glfwInit() == 0)
            return error.GlfwInitFailed;

        glfw.glfwWindowHint(glfw.GLFW_CLIENT_API, glfw.GLFW_NO_API);
        const window = glfw.glfwCreateWindow(1280, 720, c"Dear ImGui GLFW+Vulkan example", null, null).?;

        const renderInterface = try RenderInterface._init(allocator, window);

        self.* = Self{
            .allocator = allocator,
            .window = window,
            .render = renderInterface,
        };

        try self.render._initImgui(allocator);

        g_EngineInitialized = true;
    }
    pub fn deinit(self: *Self) void {
        assert(g_EngineInitialized);

        // Cleanup
        self.render._deinitImgui();
        self.render._deinit();

        glfw.glfwDestroyWindow(self.window);
        glfw.glfwTerminate();

        g_EngineInitialized = false;
    }

    pub fn beginFrame(self: *Self) !bool {
        if (glfw.glfwWindowShouldClose(self.window) != 0)
            return false;

        // Poll and handle events (inputs, window resize, etc.)
        // You can read the io.WantCaptureMouse, io.WantCaptureKeyboard flags to tell if dear imgui wants to use your inputs.
        // - When io.WantCaptureMouse is true, do not dispatch mouse input data to your main application.
        // - When io.WantCaptureKeyboard is true, do not dispatch keyboard input data to your main application.
        // Generally you may always pass all inputs to dear imgui, and hide them from your application based on those two flags.
        glfw.glfwPollEvents();

        try self.render._beginFrame();
        self.render._beginImgui();

        return true;
    }

    pub fn endFrame(self: *Self) void {}
};

extern fn glfw_error_callback(err: c_int, description: ?[*]const u8) void {
    std.debug.warn("Glfw Error {}: {}\n", err, std.mem.toSliceConst(u8, description.?));
}
