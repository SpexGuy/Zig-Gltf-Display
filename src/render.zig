const std = @import("std");
const imgui = @import("imgui");
const glfw = @import("glfw");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

// ----------------------- Render submodules -------------------------
// TODO: Select module to import as "backend" based on backend selection (Vulkan, D3D, etc)
pub const backend = @import("render_vulkan.zig");

// ----------------------- Render state -------------------------
// (there is none yet)

// ----------------------- Render types -------------------------
pub const UpdateRate = enum {
    /// Never changed
    STATIC,

    /// Changed occasionally
    DYNAMIC,

    /// Changed every frame
    STREAMING,
};

pub const Upload = struct {
    const Self = @This();

    frame: *Frame,
    backend: backend.RenderUpload,

    pub fn abort(self: *Self) void {
        assert(self.frame.state == .UPLOAD);
        self.frame.state = .IDLE;

        backend.abortUpload(&self.frame.backend, &self.backend);
    }

    pub fn endAndWait(self: *Self) void {
        assert(self.frame.state == .UPLOAD);
        self.frame.state = .IDLE;

        backend.endUploadAndWait(&self.frame.backend, &self.backend);
    }
};

pub const Pass = struct {
    const Self = @This();

    frame: *Frame,
    backend: backend.RenderPass,

    pub fn end(self: *Self) void {
        assert(self.frame.state == .RENDER);
        self.frame.state = .IDLE;

        backend.endRenderPass(&self.frame.backend, &self.backend);
    }
};

pub const Frame = struct {
    const Self = @This();

    const State = enum {
        IDLE,
        RENDER,
        UPLOAD,
    };

    state: State,
    backend: backend.RenderFrame,

    pub fn end(self: *Self) void {
        backend.endRender(&self.backend);
    }

    pub fn beginUpload(self: *Self) !Upload {
        // TODO: Allow upload and render simultaneously
        assert(self.state == .IDLE);
        self.state = .UPLOAD;
        errdefer self.state = .IDLE;

        return Upload{
            .frame = self,
            .backend = try backend.beginUpload(&self.backend),
        };
    }

    pub fn beginColorPass(self: *Self, clearColor: imgui.Vec4) !Pass {
        assert(self.state == .IDLE);
        self.state = .RENDER;
        errdefer self.state = .IDLE;

        return Pass{
            .frame = self,
            .backend = try backend.beginColorPass(&self.backend, clearColor),
        };
    }
};

// ----------------------- Public functions -------------------------
pub fn beginRender() !Frame {
    return Frame{
        .state = .IDLE,
        .backend = try backend.beginRender(),
    };
}

pub fn renderImgui(pass: *Pass) !void {
    imgui.Render();
    try backend.renderImgui(&pass.frame.backend, &pass.backend);
}

// ----------------------- Internal functions -------------------------
pub fn _init(allocator: *Allocator, window: *glfw.GLFWwindow) !void {
    try backend.init(allocator, window);
}
pub fn _deinit() void {
    backend.deinit();
}

pub fn _initImgui(allocator: *Allocator) !void {
    // Setup Dear ImGui context
    imgui.CHECKVERSION();
    _ = imgui.CreateContext(null);
    var io = imgui.GetIO();
    //io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;     // Enable Keyboard Controls
    //io.ConfigFlags |= ImGuiConfigFlags_NavEnableGamepad;      // Enable Gamepad Controls

    // Setup Dear ImGui style
    imgui.StyleColorsDark(null);
    //imgui.StyleColorsClassic(null);

    try backend.initImgui(allocator);
}
pub fn _deinitImgui() void {
    backend.deinitImgui();

    imgui.DestroyContext(null);
}

pub fn _beginFrame() !void {
    try backend.beginFrame();
}

pub fn _beginImgui() void {
    backend.beginImgui();
    imgui.NewFrame();
}
