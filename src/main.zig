const std = @import("std");
const ig = @import("imgui");
const cgltf = @import("cgltf");
const gltf = @import("gltf_wrap.zig");
const Engine = @import("engine.zig").g_Engine;

const Allocator = std.mem.Allocator;
const warn = std.debug.warn;
const assert = std.debug.assert;

const heap_allocator = std.heap.c_allocator;

const models = [_]ModelPath{
    makePath("TriangleWithoutIndices"),
    makePath("Triangle"),
    makePath("AnimatedTriangle"),
    makePath("AnimatedMorphCube"),
    makePath("AnimatedMorphSphere"),
};

var nextModelPath = usize(0);

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

fn loadNextModel() !*gltf.Data {
    const nextModel = &models[nextModelPath];
    nextModelPath += 1;
    if (nextModelPath >= models.len) nextModelPath = 0;

    std.debug.warn("Loading {}\n", nextModel.gltfFile);

    const options = cgltf.Options{};
    const data = try cgltf.parseFile(options, nextModel.gltfFile);
    errdefer cgltf.free(data);
    try cgltf.loadBuffers(options, data, nextModel.directory);
    const wrapped = try gltf.wrap(data, heap_allocator);
    return wrapped;
}

fn unloadModel(data: *gltf.Data) void {
    cgltf.free(data.raw);
    gltf.free(data);
}

pub fn main() !void {
    try Engine.init(heap_allocator);
    defer Engine.deinit();

    // Our state
    var show_demo_window = true;
    var clearColor = ig.Vec4{ .x = 0.2, .y = 0.2, .z = 0.2, .w = 1 };

    var data = try loadNextModel();
    defer unloadModel(data);

    std.debug.warn("GLTF contents: {}\n", data);

    // Main loop
    while (try Engine.beginFrame()) : (Engine.endFrame()) {
        // 1. Show the big demo window (Most of the sample code is in ig.ShowDemoWindow()! You can browse its code to learn more about Dear ImGui!).
        if (show_demo_window)
            ig.ShowDemoWindow(&show_demo_window);

        drawGltfUI(data);

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

fn drawGltfUI(data: *gltf.Data) void {
    var allocatorRaw = std.heap.ArenaAllocator.init(heap_allocator);
    defer allocatorRaw.deinit();
    const arena = &allocatorRaw.allocator;

    const Static = struct {};

    const showWindow = ig.Begin(c"glTF Data", null, 0);
    defer ig.End();

    // early out as an optimization
    if (!showWindow) return;

    ig.Columns(2, null, true);
    defer ig.Columns(1, null, true);

    ig.PushStyleVarVec2(ig.StyleVar.FramePadding, ig.Vec2{ .x = 2, .y = 2 });
    defer ig.PopStyleVar(1);

    ig.Separator();

    drawPtrUI(data, arena);

    ig.Separator();
}

const NullTerm = [_]u8{0};
const InlineFlags = ig.TreeNodeFlagBits.Leaf | ig.TreeNodeFlagBits.NoTreePushOnOpen | ig.TreeNodeFlagBits.BulletPt;

fn drawPtrUI(dataPtr: var, arena: *Allocator) void {
    const DataType = @typeOf(dataPtr).Child;
    switch (@typeInfo(DataType)) {
        .Struct => |info| {
            inline for (info.fields) |field| {
                drawFieldUI(&@field(dataPtr, field.name), field.field_type, &(field.name ++ NullTerm), arena);
            }
        },
        .Pointer => {
            drawPtrUI(dataPtr.*, arena);
        },
        else => @compileError("Invalid type passed to drawPtrUI: " ++ @typeName(DataType)),
    }
}

fn drawFieldUI(fieldPtr: var, comptime FieldType: type, name: [*]const u8, arena: *Allocator) void {
    if (FieldType == c_void) {
        ig.AlignTextToFramePadding();
        _ = ig.TreeNodeExStr(name, InlineFlags);
        ig.NextColumn();
        ig.AlignTextToFramePadding();
        ig.Text(c"0x%p", fieldPtr);
        ig.NextColumn();
        return;
    }
    switch (@typeInfo(FieldType)) {
        .Bool => {
            ig.AlignTextToFramePadding();
            _ = ig.TreeNodeExStr(name, InlineFlags);
            ig.NextColumn();
            ig.AlignTextToFramePadding();
            ig.Text(if (fieldPtr.*) c"true" else c"false");
            ig.NextColumn();
        },
        .Int => |info| {
            ig.AlignTextToFramePadding();
            _ = ig.TreeNodeExStr(name, InlineFlags);
            ig.NextColumn();
            ig.AlignTextToFramePadding();
            if (info.is_signed) {
                ig.Text(c"%lld (%s)", @intCast(isize, fieldPtr.*), &(@typeName(FieldType) ++ NullTerm));
            } else {
                ig.Text(c"%llu (%s)", @intCast(usize, fieldPtr.*), &(@typeName(FieldType) ++ NullTerm));
            }
            ig.NextColumn();
        },
        .Float => {
            ig.AlignTextToFramePadding();
            _ = ig.TreeNodeExStr(name, InlineFlags);
            ig.NextColumn();
            ig.AlignTextToFramePadding();
            ig.Text(c"%f (%s)", fieldPtr.*, &(@typeName(FieldType) ++ NullTerm));
            ig.NextColumn();
        },
        .Array => |info| {
            drawSliceFieldUI(fieldPtr.*[0..info.len], info.child, name, arena);
        },
        .Enum => |info| {
            ig.AlignTextToFramePadding();
            _ = ig.TreeNodeExStr(name, InlineFlags);
            ig.NextColumn();
            ig.AlignTextToFramePadding();
            const cstr = if (std.fmt.allocPrint(arena, "{}" ++ NullTerm, @tagName(fieldPtr.*))) |str| str.ptr else |err| c"<out of memory>";
            ig.Text(c".%s", cstr);
            ig.NextColumn();
        },
        .Struct => |info| {
            ig.AlignTextToFramePadding();
            const nodeOpen = ig.TreeNodeStr(name);
            defer if (nodeOpen) ig.TreePop();
            ig.NextColumn();
            ig.AlignTextToFramePadding();
            ig.Text(c"%s", &(@typeName(FieldType) ++ NullTerm));
            ig.NextColumn();
            if (nodeOpen) {
                drawPtrUI(fieldPtr, arena);
            }
        },
        .Optional => |info| {
            if (fieldPtr.*) |nonnullValue| {
                drawFieldUI(&nonnullValue, info.child, name, arena);
            } else {
                ig.AlignTextToFramePadding();
                _ = ig.TreeNodeExStr(name, InlineFlags);
                ig.NextColumn();
                ig.AlignTextToFramePadding();
                ig.Text(c"null");
                ig.NextColumn();
            }
        },
        .Pointer => |info| {
            switch (info.size) {
                .One => drawFieldUI(fieldPtr.*, info.child, name, arena),
                .Slice => drawSliceFieldUI(fieldPtr.*, info.child, name, arena),
                else => {
                    ig.AlignTextToFramePadding();
                    _ = ig.TreeNodeExStr(name, InlineFlags);
                    ig.NextColumn();
                    ig.AlignTextToFramePadding();
                    ig.Text(c"0x%p", fieldPtr.*);
                    ig.NextColumn();
                },
            }
        },
        .Opaque => {
            ig.AlignTextToFramePadding();
            _ = ig.TreeNodeExStr(name, InlineFlags);
            ig.NextColumn();
            ig.AlignTextToFramePadding();
            ig.Text(c"0x%p", fieldPtr);
            ig.NextColumn();
        },
        else => {
            ig.AlignTextToFramePadding();
            _ = ig.TreeNodeExStr(name, InlineFlags);
            ig.NextColumn();
            ig.AlignTextToFramePadding();
            ig.Text(&("<TODO " ++ @typeName(FieldType) ++ ">" ++ NullTerm));
            ig.NextColumn();
        },
    }
}

fn drawSliceFieldUI(slice: var, comptime DataType: type, name: [*]const u8, arena: *Allocator) void {
    if (DataType == u8) {
        // make sure this is a null-terminated slice
        assert(slice.ptr[slice.len] == 0);

        ig.AlignTextToFramePadding();
        _ = ig.TreeNodeExStr(name, InlineFlags);
        ig.NextColumn();
        ig.AlignTextToFramePadding();
        ig.Text(c"\"%s\"", slice.ptr);
        ig.NextColumn();
    } else {
        ig.AlignTextToFramePadding();
        const nodeOpen = ig.TreeNodeStr(name);
        defer if (nodeOpen) ig.TreePop();
        ig.NextColumn();
        ig.AlignTextToFramePadding();
        ig.Text(c"[%llu]%s", slice.len, &(@typeName(DataType) ++ NullTerm));
        ig.NextColumn();
        if (nodeOpen) {
            comptime var T = DataType;
            comptime while (@typeInfo(T) == .Pointer and @typeInfo(T).Pointer.size == .One) {
                T = T.Child;
            };
            if (@typeInfo(T) == .Struct and slice.len == 1) {
                drawPtrUI(&slice[0], arena);
            } else {
                for (slice) |*item, i| {
                    const itemName: [*]const u8 = if (std.fmt.allocPrint(arena, "[{}]" ++ NullTerm, i)) |str| str.ptr else |err| c"<out of memory>";
                    drawFieldUI(item, DataType, itemName, arena);
                }
            }
        }
    }
}
