const std = @import("std");
const ig = @import("imgui");
const cgltf = @import("cgltf");
const gltf = @import("gltf_wrap.zig");
const engine = @import("engine.zig");
const vk = @import("vk");

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
            const open = ig.Begin("Control", null, .{});
            defer ig.End();
            if (!open) break :OPTIONS_WINDOW;

            ig.Text("Current File (%lld/%lld): %s", loadedModelIndex + 1, models.len, models[loadedModelIndex].gltfFile);
            if (ig.Button("Load Previous File", ig.Vec2{ .x = 0, .y = 0 })) {
                targetModelIndex = (if (targetModelIndex == 0) models.len else targetModelIndex) - 1;
            }
            ig.SameLine(0, -1);
            if (ig.Button("Load Next File", ig.Vec2{ .x = 0, .y = 0 })) {
                targetModelIndex = if (targetModelIndex >= models.len - 1) 0 else (targetModelIndex + 1);
            }
            _ = ig.Checkbox("Show glTF Data", &show_gltf_data);
            _ = ig.Checkbox("Show ImGui Demo", &show_demo_window);
            if (ig.Button("Crash", ig.Vec2{ .x = 0, .y = 0 })) {
                @panic("Don't press the big shiny button!");
            }
        }
        if (show_demo_window) ig.ShowDemoWindow(&show_demo_window);
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
    var allocatorRaw = std.heap.ArenaAllocator.init(heap_allocator);
    defer allocatorRaw.deinit();
    const arena = &allocatorRaw.allocator;

    const Static = struct {};

    const showWindow = ig.Begin("glTF Data", show, .{});
    defer ig.End();

    // early out as an optimization
    if (!showWindow) return;

    ig.Columns(2, null, true);
    defer ig.Columns(1, null, true);

    ig.PushStyleVarVec2(ig.StyleVar.FramePadding, ig.Vec2{ .x = 2, .y = 2 });
    defer ig.PopStyleVar(1);

    ig.Separator();

    drawStructUI(gltf.Data, data, arena);

    ig.Separator();
}

const NULL_TERM = [_]u8{0};
fn nullTerm(comptime str: []const u8) [:0]const u8 {
    const fullStr = str ++ NULL_TERM;
    return fullStr[0..str.len :0];
}

fn allocPrintZ(allocator: *Allocator, comptime fmt: []const u8, params: var) ![:0]const u8 {
    const formatted = try std.fmt.allocPrint(allocator, fmt ++ NULL_TERM, params);
    assert(formatted[formatted.len - 1] == 0);
    return formatted[0 .. formatted.len - 1 :0];
}

const INLINE_FLAGS = ig.TreeNodeFlags{ .Leaf=true, .NoTreePushOnOpen=true, .Bullet=true };
const MAX_STRING_LEN = 255;

/// Recursively draws generated read-only UI for a single struct.
/// No memory from the passed arena is in use after this call.  It can be freed or reset.
fn drawStructUI(comptime DataType: type, dataPtr: *const DataType, arena: *Allocator) void {
    switch (@typeInfo(DataType)) {
        .Struct => |info| {
            inline for (info.fields) |field| {
                drawFieldUI(field.field_type, &@field(dataPtr, field.name), nullTerm(field.name), arena);
            }
        },
        .Pointer => {
            drawStructUI(DataType.Child, dataPtr.*, arena);
        },
        else => @compileError("Invalid type passed to drawStructUI: " ++ @typeName(DataType)),
    }
}

/// Recursively draws generated read-only UI for a named field.
/// name must be a null-terminated string.
/// No memory from the passed arena is in use after this call.  It can be freed or reset.
/// fieldPtr is `var` to allow arbitrary bit alignment
fn drawFieldUI(comptime FieldType: type, fieldPtr: var, name: [:0]const u8, arena: *Allocator) void {
    if (FieldType == c_void) {
        ig.AlignTextToFramePadding();
        _ = ig.TreeNodeExStr(name.ptr, INLINE_FLAGS);
        ig.NextColumn();
        ig.AlignTextToFramePadding();
        ig.Text("0x%p", fieldPtr);
        ig.NextColumn();
        return;
    }
    switch (@typeInfo(FieldType)) {
        .Bool => {
            ig.AlignTextToFramePadding();
            _ = ig.TreeNodeExStr(name.ptr, INLINE_FLAGS);
            ig.NextColumn();
            ig.AlignTextToFramePadding();
            ig.Text(if (fieldPtr.*) "true" else "false");
            ig.NextColumn();
        },
        .Int => |info| {
            ig.AlignTextToFramePadding();
            _ = ig.TreeNodeExStr(name.ptr, INLINE_FLAGS);
            ig.NextColumn();
            ig.AlignTextToFramePadding();
            if (info.is_signed) {
                ig.Text("%lld (%s)", @intCast(isize, fieldPtr.*), @typeName(FieldType));
            } else {
                ig.Text("%llu (%s)", @intCast(usize, fieldPtr.*), @typeName(FieldType));
            }
            ig.NextColumn();
        },
        .Float => {
            ig.AlignTextToFramePadding();
            _ = ig.TreeNodeExStr(name.ptr, INLINE_FLAGS);
            ig.NextColumn();
            ig.AlignTextToFramePadding();
            ig.Text("%f (%s)", fieldPtr.*, @typeName(FieldType));
            ig.NextColumn();
        },
        .Array => |info| {
            drawSliceFieldUI(info.child, fieldPtr.*[0..info.len], name, arena);
        },
        .Enum => |info| {
            ig.AlignTextToFramePadding();
            _ = ig.TreeNodeExStr(name.ptr, INLINE_FLAGS);
            ig.NextColumn();
            ig.AlignTextToFramePadding();
            const cstr = if (allocPrintZ(arena, "{}", .{@tagName(fieldPtr.*)})) |str| str else |err| "<out of memory>";
            ig.Text(".%s", cstr.ptr);
            ig.NextColumn();
        },
        .Struct => |info| {
            ig.AlignTextToFramePadding();
            const nodeOpen = ig.TreeNodeStr(name.ptr);
            defer if (nodeOpen) ig.TreePop();
            ig.NextColumn();
            ig.AlignTextToFramePadding();
            ig.Text("%s", @typeName(FieldType));
            ig.NextColumn();
            if (nodeOpen) {
                drawStructUI(FieldType, fieldPtr, arena);
            }
        },
        .Optional => |info| {
            if (fieldPtr.*) |nonnullValue| {
                drawFieldUI(info.child, &nonnullValue, name, arena);
            } else {
                ig.AlignTextToFramePadding();
                _ = ig.TreeNodeExStr(name.ptr, INLINE_FLAGS);
                ig.NextColumn();
                ig.AlignTextToFramePadding();
                ig.Text("null");
                ig.NextColumn();
            }
        },
        .Pointer => |info| {
            switch (info.size) {
                .One => drawFieldUI(info.child, fieldPtr.*, name, arena),
                .Slice => drawSliceFieldUI(info.child, fieldPtr.*, name, arena),
                else => {
                    ig.AlignTextToFramePadding();
                    _ = ig.TreeNodeExStr(name.ptr, INLINE_FLAGS);
                    ig.NextColumn();
                    ig.AlignTextToFramePadding();
                    ig.Text("0x%p", fieldPtr.*);
                    ig.NextColumn();
                },
            }
        },
        .Opaque => {
            ig.AlignTextToFramePadding();
            _ = ig.TreeNodeExStr(name.ptr, INLINE_FLAGS);
            ig.NextColumn();
            ig.AlignTextToFramePadding();
            ig.Text("%s@0x%p", @typeName(FieldType), fieldPtr);
            ig.NextColumn();
        },
        else => {
            ig.AlignTextToFramePadding();
            _ = ig.TreeNodeExStr(name.ptr, INLINE_FLAGS);
            ig.NextColumn();
            ig.AlignTextToFramePadding();
            ig.Text("<TODO " ++ @typeName(FieldType) ++ ">@0x%p", fieldPtr);
            ig.NextColumn();
        },
    }
}

/// Recursively draws generated UI for a slice.  If the slice is []u8, checks if it is a printable string
/// and draws it if so.  Otherwise generates similar UI to a struct, with fields named [0], [1], etc.
/// If the slice has length one and its payload is a struct, the [0] field will be elided and the single
/// element will be displayed inline.
/// No memory from the passed arena is in use after this call.  It can be freed or reset.
fn drawSliceFieldUI(comptime DataType: type, slice: []const DataType, name: [:0]const u8, arena: *Allocator) void {
    if (DataType == u8 and slice.len < MAX_STRING_LEN and isPrintable(slice)) {
        ig.AlignTextToFramePadding();
        _ = ig.TreeNodeExStr(name.ptr, INLINE_FLAGS);
        ig.NextColumn();
        ig.AlignTextToFramePadding();
        const nullTermStr = if (allocPrintZ(arena, "{}", .{slice})) |cstr| cstr else |err| "out of memory";
        ig.Text("\"%s\" ", nullTermStr.ptr);
        ig.NextColumn();
    } else {
        ig.AlignTextToFramePadding();
        const nodeOpen = ig.TreeNodeStr(name.ptr);
        defer if (nodeOpen) ig.TreePop();
        ig.NextColumn();
        ig.AlignTextToFramePadding();
        ig.Text("[%llu]%s", slice.len, nullTerm(@typeName(DataType)).ptr);
        ig.NextColumn();
        if (nodeOpen) {
            const NextDisplayType = RemoveSinglePointers(DataType);
            if (@typeInfo(NextDisplayType) == .Struct and slice.len == 1) {
                drawStructUI(DataType, &slice[0], arena);
            } else {
                for (slice) |*item, i| {
                    // TODO: Put null-terminated printing into
                    const itemName: [:0]const u8 = if (allocPrintZ(arena, "[{}]", .{i})) |str| str else |err| "<out of memory>";
                    drawFieldUI(DataType, item, itemName, arena);
                }
            }
        }
    }
}

/// Returns true if the string is made up of only printable characters.
/// \n,\r, and \t are not considered printable by this function.
fn isPrintable(string: []const u8) bool {
    for (string) |char| {
        if (char < 32 or char > 126) return false;
    }
    return true;
}

/// Returns the type that this type points to after unwrapping all
/// non-nullable single pointers.  Examples:
/// *T -> T
/// **T -> T
/// ?*T -> ?*T
/// **?*T -> ?*T
/// *[*]*T -> [*]*T
fn RemoveSinglePointers(comptime InType: type) type {
    comptime var Type = InType;
    comptime while (@typeInfo(Type) == .Pointer and @typeInfo(Type).Pointer.size == .One) {
        Type = Type.Child;
    };
    return Type;
}
