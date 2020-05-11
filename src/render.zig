const std = @import("std");
const imgui = @import("imgui");
const glfw = @import("glfw");

const engine = @import("engine.zig");

// TODO: No vulkan allowed at this layer!!
const vk = @import("vk");

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

pub const MappedRange = struct {
    const Self = @This();

    buffer: *Buffer,
    byteOffset: usize,
    data: []u8,

    fn flush(self: *Self) !void {
        try backend.flushMappedRange(&self.buffer.backend, self.data.ptr, self.byteOffset, self.data.len);
    }

    fn flushPart(self: *Self, comptime T: type, byteOffset: usize, count: usize) !void {
        const lenBytes = count * @sizeOf(T);
        assert(byteOffset + lenBytes <= self.data.len);
        try backend.flushMappedRange(&self.buffer.backend, self.data.ptr, self.byteOffset + byteOffset, lenBytes);
    }

    fn get(self: *Self, comptime T: type) []T {
        const count = self.data.len / @sizeOf(T);
        return @intToPtr([*]T, @ptrToInt(self.data.ptr))[0..count];
    }

    fn getPart(self: *Self, comptime T: type, byteOffset: usize, count: usize) []T {
        assert(byteOffset + count * @sizeOf(T) < self.data.len);
        return @intToPtr([*]T, @ptrToInt(self.data.ptr) + byteOffset)[0..count];
    }

    fn end(self: *Self) void {
        backend.unmapBuffer(&self.buffer.backend, self.data.ptr, self.byteOffset, self.data.len);
    }
};

pub const Buffer = struct {
    const Self = @This();

    len: usize,
    backend: backend.Buffer,

    pub fn beginMap(self: *Buffer) !MappedRange {
        return MappedRange{
            .buffer = self,
            .byteOffset = 0,
            .data = (try backend.mapBuffer(&self.backend, 0, self.len))[0..self.len],
        };
    }

    pub fn beginMapPart(self: *Buffer, comptime T: type, byteOffset: usize, itemCount: usize) !MappedRange {
        const mapLengthBytes = itemCount * @sizeOf(T);
        assert(mapLengthBytes + byteOffset <= self.mapLengthBytes);
        return MappedRange{
            .buffer = self,
            .byteOffset = byteOffset,
            .data = (try backend.mapBuffer(&self.backend, byteOffset, mapLengthBytes))[0..mapLengthBytes],
        };
    }

    pub fn destroy(self: *Buffer) void {
        backend.destroyBuffer(&self.backend);
    }
};

pub const Upload = struct {
    const Self = @This();

    frame: *Frame,
    backend: backend.RenderUpload,
    managedBuffers: std.ArrayList(Buffer),

    pub fn copyBuffer(self: *Self, source: *Buffer, dest: *Buffer) void {
        assert(dest.len >= source.len);
        backend.uploadCopyBuffer(&self.frame.backend, &self.backend, &source.backend, 0, &dest.backend, 0, source.len);
    }

    pub fn copyBufferPart(self: *Self, source: *Buffer, sourceOffset: usize, dest: *Buffer, destOffset: usize, len: usize) void {
        assert(sourceOffset + len <= source.len);
        assert(destOffset + len <= dest.len);
        backend.uploadCopyBuffer(&self.frame.backend, &self.backend, &source.backend, sourceOffset, &dest.backend, destOffset, len);
    }

    pub fn setBufferData(self: *Self, buffer: *Buffer, offset: usize, data: []const u8) !void {
        assert(offset + data.len <= buffer.len);
        const stagingBuffer = try self.newManagedStagingBuffer(data.len);
        {
            var map = try stagingBuffer.beginMap();
            defer map.end();
            @memcpy(map.data.ptr, data.ptr, data.len);
            try map.flush();
        }
        self.copyBufferPart(stagingBuffer, 0, buffer, offset, data.len);
    }

    pub fn abort(self: *Self) void {
        assert(self.frame.state == .UPLOAD);
        self.frame.state = .IDLE;

        backend.abortUpload(&self.frame.backend, &self.backend);
        self._deleteManagedBuffers();
    }

    pub fn endAndWait(self: *Self) void {
        assert(self.frame.state == .UPLOAD);
        self.frame.state = .IDLE;

        backend.endUploadAndWait(&self.frame.backend, &self.backend);
        self._deleteManagedBuffers();
    }

    pub fn newManagedStagingBuffer(self: *Self, size: usize) !*Buffer {
        const bufPtr = try self.managedBuffers.addOne();
        errdefer _ = self.managedBuffers.pop();
        bufPtr.* = try createStagingBuffer(size);
        errdefer bufPtr.destroy();
        return bufPtr;
    }

    pub fn _deleteManagedBuffers(self: *Self) void {
        for (self.managedBuffers.items) |*buffer| buffer.destroy();
        self.managedBuffers.deinit();
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
            .managedBuffers = std.ArrayList(Buffer).init(engine.allocator),
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

pub fn createStagingBuffer(size: usize) !Buffer {
    return Buffer{
        .len = size,
        .backend = try backend.createStagingBuffer(size),
    };
}

// TODO: No vulkan allowed at this layer!!
pub fn createGpuBuffer(size: usize, flags: vk.BufferUsageFlags) !Buffer {
    return Buffer{
        .len = size,
        .backend = try backend.createGpuBuffer(size, flags),
    };
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
    _ = imgui.CreateContext();
    var io = imgui.GetIO();
    //io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;     // Enable Keyboard Controls
    //io.ConfigFlags |= ImGuiConfigFlags_NavEnableGamepad;      // Enable Gamepad Controls

    // Setup Dear ImGui style
    imgui.StyleColorsDark();
    //imgui.StyleColorsClassic();

    try backend.initImgui(allocator);
}
pub fn _deinitImgui() void {
    backend.deinitImgui();

    imgui.DestroyContext();
}

pub fn _beginFrame() !void {
    try backend.beginFrame();
}

pub fn _beginImgui() void {
    backend.beginImgui();
    imgui.NewFrame();
}
