//I'm having fun with the render abstraction layer.
//The rendering backend implements a static interface for its class RenderBackend, and can specify data types for RenderFrame and RenderPass.  The render api wraps all that up into a common api.

const std = @import("std");
const imgui = @import("imgui");
const glfw = @import("glfw");

const Allocator = std.mem.Allocator;

// TODO: Select module to import as "impl" based on backend selection (Vulkan, D3D, etc)
const impl = @import("render_vulkan.zig");

pub const RenderPass = struct {
    const Self = @This();

    frame: *RenderFrame,
    backend: impl.RenderPass,

    pub fn end(self: *Self) void {
        self.frame.render.backend.endRenderPass(&self.frame.backend, &self.backend);
    }
};

pub const RenderFrame = struct {
    const Self = @This();

    render: *RenderInterface,
    backend: impl.RenderFrame,

    pub fn end(self: *Self) void {
        self.render.backend.endRender(&self.backend);
    }

    pub fn beginColorPass(self: *Self, clearColor: imgui.Vec4) !RenderPass {
        return RenderPass{
            .frame = self,
            .backend = try self.render.backend.beginColorPass(&self.backend, clearColor),
        };
    }
};

pub const RenderInterface = struct {
    const Self = @This();

    backend: impl.RenderBackend,

    pub fn _init(allocator: *Allocator, window: *glfw.GLFWwindow) !RenderInterface {
        return RenderInterface{
            .backend = try impl.RenderBackend.init(allocator, window),
        };
    }
    pub fn _deinit(self: *Self) void {
        self.backend.deinit();
    }

    pub fn _initImgui(self: *Self, allocator: *Allocator) !void {
        // Setup Dear ImGui context
        imgui.CHECKVERSION();
        _ = imgui.CreateContext(null);
        var io = imgui.GetIO();
        //io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;     // Enable Keyboard Controls
        //io.ConfigFlags |= ImGuiConfigFlags_NavEnableGamepad;      // Enable Gamepad Controls

        // Setup Dear ImGui style
        imgui.StyleColorsDark(null);
        //imgui.StyleColorsClassic(null);

        try self.backend.initImgui(allocator);
    }
    pub fn _deinitImgui(self: *Self) void {
        self.backend.deinitImgui();

        imgui.DestroyContext(null);
    }

    pub fn _beginFrame(self: *Self) !void {
        try self.backend.beginFrame();
    }

    pub fn _beginImgui(self: *Self) void {
        self.backend.beginImgui();
        imgui.NewFrame();
    }

    pub fn beginRender(self: *Self) !RenderFrame {
        return RenderFrame{
            .render = self,
            .backend = try self.backend.beginRender(),
        };
    }

    pub fn renderImgui(self: *Self, pass: *RenderPass) !void {
        imgui.Render();
        try self.backend.renderImgui(&pass.frame.backend, &pass.backend);
    }
};
