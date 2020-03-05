const std = @import("std");
const imgui = @import("imgui");
const cgltf = @import("cgltf");
const gltf = @import("gltf_wrap.zig");
const Engine = @import("engine.zig").g_Engine;

const allocator = std.heap.c_allocator;

const models = [_]ModelPath{
    makePath("TriangleWithoutIndices"),
    makePath("Triangle"),
    makePath("AnimatedTriangle"),
    makePath("AnimatedMorphCube"),
    makePath("AnimatedMorphSphere"),
};

const ModelPath = struct {
    gltfFile: [*]const u8,
    directory: [*]const u8,
};

fn makePath(comptime model: []const u8) ModelPath {
    const gen = struct {
        const path = "models/" ++ model ++ "/glTF/" ++ model ++ ".gltf" ++ [_]u8{0};
        const dir = "models/" ++ model ++ "/glTF/" ++ [_]u8{0};
    };
    return ModelPath{ .gltfFile = &gen.path, .directory = &gen.dir };
}

var nextModelPath = usize(0);

fn loadNextModel() !*gltf.Data {
    const nextModel = &models[nextModelPath];
    nextModelPath += 1;
    if (nextModelPath >= models.len) nextModelPath = 0;

    std.debug.warn("Loading {}\n", nextModel.gltfFile);

    const options = cgltf.Options{};
    const data = try cgltf.parseFile(options, nextModel.gltfFile);
    errdefer cgltf.free(data);
    try cgltf.loadBuffers(options, data, nextModel.directory);
    const wrapped = try gltf.wrap(data, allocator);
    return wrapped;
}

fn unloadModel(data: *gltf.Data) void {
    cgltf.free(data.raw);
    gltf.free(data);
}

pub fn main() !void {
    try Engine.init(allocator);
    defer Engine.deinit();

    // Our state
    var show_demo_window = true;
    var show_another_window = false;
    var slider_value: f32 = 0;
    var counter: i32 = 0;
    var clearColor = imgui.Vec4{ .x = 0.5, .y = 0, .z = 1, .w = 1 };

    var data = try loadNextModel();
    defer unloadModel(data);

    std.debug.warn("GLTF contents: {}\n", data);

    // Main loop
    while (try Engine.beginFrame()) : (Engine.endFrame()) {
        // 1. Show the big demo window (Most of the sample code is in imgui.ShowDemoWindow()! You can browse its code to learn more about Dear ImGui!).
        if (show_demo_window)
            imgui.ShowDemoWindow(&show_demo_window);

        // waits on frame ready semaphore
        var frame = try Engine.render.beginRender();
        defer frame.end();

        // TODO: Make this beginRenderPass(colorPass)
        var colorRender = try frame.beginColorPass(clearColor);
        defer colorRender.end();

        // rendering code here...

        try Engine.render.renderImgui(&colorRender);
    }
}
