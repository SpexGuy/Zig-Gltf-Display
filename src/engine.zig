const std = @import("std");
const imgui = @import("imgui");
const glfw = @import("glfw");

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

// ----------------------- Engine submodules -------------------------
pub const render = @import("render.zig");

// ----------------------- Engine state -------------------------
pub var _engineInitialized = false;
pub var allocator: Allocator = undefined;
pub var window: *glfw.GLFWwindow = undefined;

// ----------------------- Public functions -------------------------
pub fn init(windowName: [:0]const u8, heap_allocator: Allocator) !void {
    assert(!_engineInitialized);

    allocator = heap_allocator;

    // Setup GLFW window
    _ = glfw.glfwSetErrorCallback(glfw_error_callback);
    if (glfw.glfwInit() == 0)
        return error.GlfwInitFailed;

    glfw.glfwWindowHint(glfw.GLFW_CLIENT_API, glfw.GLFW_NO_API);
    window = glfw.glfwCreateWindow(1280, 720, windowName, null, null).?;

    try render._init(allocator, window);
    try render._initImgui(allocator);

    _engineInitialized = true;
}
pub fn deinit() void {
    assert(_engineInitialized);

    // Cleanup
    render._deinitImgui();
    render._deinit();

    glfw.glfwDestroyWindow(window);
    glfw.glfwTerminate();

    _engineInitialized = false;
}

pub fn beginFrame() !bool {
    if (glfw.glfwWindowShouldClose(window) != 0)
        return false;

    // Poll and handle events (inputs, window resize, etc.)
    // You can read the io.WantCaptureMouse, io.WantCaptureKeyboard flags to tell if dear imgui wants to use your inputs.
    // - When io.WantCaptureMouse is true, do not dispatch mouse input data to your main application.
    // - When io.WantCaptureKeyboard is true, do not dispatch keyboard input data to your main application.
    // Generally you may always pass all inputs to dear imgui, and hide them from your application based on those two flags.
    glfw.glfwPollEvents();

    try render._beginFrame();
    render._beginImgui();

    return true;
}

pub fn endFrame() void {}

// ----------------------- Internal functions -------------------------

fn glfw_error_callback(err: c_int, description: [*c]const u8) callconv(.C) void {
    std.debug.print("Glfw Error {}: {s}\n", .{ err, std.mem.span(description.?) });
}
