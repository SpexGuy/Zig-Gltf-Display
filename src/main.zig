const std = @import("std");
const ig = @import("imgui");
const cgltf = @import("cgltf");
const vk = @import("vk");

const gltf = @import("gltf_wrap.zig");
const engine = @import("engine.zig");
const autogui = @import("autogui.zig");

const Allocator = std.mem.Allocator;
const warn = std.debug.warn;
const assert = std.debug.assert;
const Child = std.meta.Child;

const heap_allocator = std.heap.c_allocator;

const models = [_]ModelPath{
    makePath("TriangleWithoutIndices"),
    makePath("Triangle"),
    makePath("AnimatedTriangle"),
    makePath("AnimatedMorphCube"),
    makePath("AnimatedMorphSphere"),
};

const FIRST_MODEL = @as(usize, 0);
var loadedModelIndex = FIRST_MODEL;
var targetModelIndex = FIRST_MODEL;

const ModelPath = struct {
    gltfFile: [*:0]const u8,
    directory: [*:0]const u8,
};

fn makePath(comptime model: []const u8) ModelPath {
    const gen = struct {
        const path = "models/" ++ model ++ "/glTF/" ++ model ++ ".gltf";
        const dir = "models/" ++ model ++ "/glTF/";
    };
    return ModelPath{ .gltfFile = gen.path, .directory = gen.dir };
}

fn loadModel(index: usize) !*gltf.Data {
    const nextModel = &models[targetModelIndex];

    std.debug.warn("Loading {}\n", .{std.mem.spanZ(nextModel.gltfFile)});

    const options = cgltf.Options{};

    const data = try cgltf.parseFile(options, nextModel.gltfFile);
    errdefer cgltf.free(data);

    try cgltf.loadBuffers(options, data, nextModel.directory);
    // unload handled by cgltf.free

    const wrapped = try gltf.wrap(data, heap_allocator);
    errdefer gltf.free(wrapped);

    return wrapped;
}

fn uploadRenderingData(data: *gltf.Data, frame: *engine.render.Frame) !void {
    markUsageFlags(data);
    try uploadBuffers(data, frame);
}

fn markUsageFlags(data: *gltf.Data) void {
    for (data.buffer_views) |view| {
        if (view.raw.type == .vertices) view.buffer.usageFlags.vertexBuffer = true;
        if (view.raw.type == .indices) view.buffer.usageFlags.indexBuffer = true;
    }
}

fn uploadBuffers(data: *gltf.Data, frame: *engine.render.Frame) !void {
    assert(!data.renderingDataInitialized);

    var upload = try frame.beginUpload();
    errdefer upload.abort();

    errdefer unloadRenderingData(data);

    for (data.buffers) |*buffer, i| {
        buffer.gpuBuffer = try engine.render.createGpuBuffer(buffer.raw.size, buffer.usageFlags);
        const bufferData = @ptrCast([*]u8, buffer.raw.data.?)[0..buffer.raw.size];
        try upload.setBufferData(&buffer.gpuBuffer.?, 0, bufferData);
    }

    upload.endAndWait();
    data.renderingDataInitialized = true;
}

fn unloadRenderingData(data: *gltf.Data) void {
    const backend = engine.render.backend;
    assert(data.renderingDataInitialized);
    for (data.buffers) |*buffer| {
        if (buffer.gpuBuffer != null) {
            buffer.gpuBuffer.?.destroy();
            buffer.gpuBuffer = null;
        }
    }
}

fn unloadModel(data: *gltf.Data) void {
    cgltf.free(data.raw);
    gltf.free(data);
}

var show_demo_window = false;
var show_gltf_data = false;
var clearColor = ig.Vec4{ .x = 0.2, .y = 0.2, .z = 0.2, .w = 1 };

pub fn main() !void {
    try engine.init("glTF Renderer", heap_allocator);
    defer engine.deinit();

    // Our state
    var data = try loadModel(loadedModelIndex);
    defer unloadModel(data);
    assert(!data.renderingDataInitialized);

    // Main loop
    while (try engine.beginFrame()) : (engine.endFrame()) {
        // show the options window
        OPTIONS_WINDOW: {
            const open = ig.Begin("Control");
            defer ig.End();
            if (!open) break :OPTIONS_WINDOW;

            ig.Text("Current File (%lld/%lld): %s", loadedModelIndex + 1, models.len, models[loadedModelIndex].gltfFile);
            if (ig.Button("Load Previous File")) {
                targetModelIndex = (if (targetModelIndex == 0) models.len else targetModelIndex) - 1;
            }
            ig.SameLine();
            if (ig.Button("Load Next File")) {
                targetModelIndex = if (targetModelIndex >= models.len - 1) 0 else (targetModelIndex + 1);
            }
            _ = ig.Checkbox("Show glTF Data", &show_gltf_data);
            _ = ig.Checkbox("Show ImGui Demo", &show_demo_window);
            if (ig.Button("Crash")) {
                @panic("Don't press the big shiny button!");
            }
        }
        if (show_demo_window) ig.ShowDemoWindowExt(&show_demo_window);
        if (show_gltf_data) drawGltfUI(data, &show_gltf_data);

        if (targetModelIndex != loadedModelIndex) {
            unloadModel(data);
            data = try loadModel(targetModelIndex);
            loadedModelIndex = targetModelIndex;
        }

        // waits on frame ready semaphore
        var frame = try engine.render.beginRender();
        defer frame.end();

        if (data.renderingDataInitialized != true) {
            warn("Setting up rendering data...\n", .{});
            try uploadRenderingData(data, &frame);
            assert(data.renderingDataInitialized);
        }

        // TODO: Make this beginRenderPass(colorPass)
        var colorRender = try frame.beginColorPass(clearColor);
        defer colorRender.end();

        // rendering code here...

        try engine.render.renderImgui(&colorRender);
    }
}

fn drawGltfUI(data: *gltf.Data, show: *bool) void {
    const Static = struct {};

    const showWindow = ig.BeginExt("glTF Data", show, .{});
    defer ig.End();

    // early out as an optimization
    if (!showWindow) return;

    ig.Columns(2);
    defer ig.Columns(1);

    ig.PushStyleVarVec2(ig.StyleVar.FramePadding, ig.Vec2{ .x = 2, .y = 2 });
    defer ig.PopStyleVar();

    ig.Separator();

    autogui.draw(gltf.Data, data, heap_allocator);

    ig.Separator();
}
