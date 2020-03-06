const std = @import("std");
const ig = @import("imgui");
const cgltf = @import("cgltf");
const gltf = @import("gltf_wrap.zig");
const engine = @import("engine.zig");

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

var modelPathIndex = usize(1);

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

fn loadModel() !*gltf.Data {
    const nextModel = &models[modelPathIndex];

    std.debug.warn("Loading {}\n", std.mem.toSliceConst(u8, nextModel.gltfFile));

    const options = cgltf.Options{};

    const data = try cgltf.parseFile(options, nextModel.gltfFile);
    errdefer cgltf.free(data);

    try cgltf.loadBuffers(options, data, nextModel.directory);

    const wrapped = try gltf.wrap(data, heap_allocator);
    errdefer gltf.free(wrapped);

    return wrapped;
}

fn unloadModel(data: *gltf.Data) void {
    cgltf.free(data.raw);
    gltf.free(data);
}

pub fn main() !void {
    try engine.init(c"glTF Renderer", heap_allocator);
    defer engine.deinit();

    // Our state
    var show_demo_window = false;
    var show_gltf_data = false;
    var clearColor = ig.Vec4{ .x = 0.2, .y = 0.2, .z = 0.2, .w = 1 };

    var data = try loadModel();
    defer unloadModel(data);

    // Main loop
    while (try engine.beginFrame()) : (engine.endFrame()) {
        // show the options window
        OPTIONS_WINDOW: {
            const open = ig.Begin(c"Control", null, 0);
            defer ig.End();
            if (!open) break :OPTIONS_WINDOW;

            ig.Text(c"Current File (%lld/%lld): %s", modelPathIndex + 1, models.len, models[modelPathIndex].gltfFile);
            if (ig.Button(c"Load Previous File", ig.Vec2{ .x = 0, .y = 0 })) {
                modelPathIndex = (if (modelPathIndex == 0) models.len else modelPathIndex) - 1;
                unloadModel(data);
                data = try loadModel();
            }
            ig.SameLine(0, -1);
            if (ig.Button(c"Load Next File", ig.Vec2{ .x = 0, .y = 0 })) {
                modelPathIndex = if (modelPathIndex >= models.len - 1) 0 else (modelPathIndex + 1);
                unloadModel(data);
                data = try loadModel();
            }
            _ = ig.Checkbox(c"Show glTF Data", &show_gltf_data);
            _ = ig.Checkbox(c"Show ImGui Demo", &show_demo_window);
        }
        if (show_demo_window) ig.ShowDemoWindow(&show_demo_window);
        if (show_gltf_data) drawGltfUI(data, &show_gltf_data);

        // waits on frame ready semaphore
        var frame = try engine.render.beginRender();
        defer frame.end();

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

    const showWindow = ig.Begin(c"glTF Data", show, 0);
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
const INLINE_FLAGS = ig.TreeNodeFlagBits.Leaf | ig.TreeNodeFlagBits.NoTreePushOnOpen | ig.TreeNodeFlagBits.BulletPt;
const MAX_STRING_LEN = 255;

/// Recursively draws generated read-only UI for a single struct.
/// No memory from the passed arena is in use after this call.  It can be freed or reset.
fn drawStructUI(comptime DataType: type, dataPtr: *const DataType, arena: *Allocator) void {
    switch (@typeInfo(DataType)) {
        .Struct => |info| {
            inline for (info.fields) |field| {
                drawFieldUI(field.field_type, &@field(dataPtr, field.name), &(field.name ++ NULL_TERM), arena);
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
fn drawFieldUI(comptime FieldType: type, fieldPtr: *const FieldType, name: [*]const u8, arena: *Allocator) void {
    if (FieldType == c_void) {
        ig.AlignTextToFramePadding();
        _ = ig.TreeNodeExStr(name, INLINE_FLAGS);
        ig.NextColumn();
        ig.AlignTextToFramePadding();
        ig.Text(c"0x%p", fieldPtr);
        ig.NextColumn();
        return;
    }
    switch (@typeInfo(FieldType)) {
        .Bool => {
            ig.AlignTextToFramePadding();
            _ = ig.TreeNodeExStr(name, INLINE_FLAGS);
            ig.NextColumn();
            ig.AlignTextToFramePadding();
            ig.Text(if (fieldPtr.*) c"true" else c"false");
            ig.NextColumn();
        },
        .Int => |info| {
            ig.AlignTextToFramePadding();
            _ = ig.TreeNodeExStr(name, INLINE_FLAGS);
            ig.NextColumn();
            ig.AlignTextToFramePadding();
            if (info.is_signed) {
                ig.Text(c"%lld (%s)", @intCast(isize, fieldPtr.*), &(@typeName(FieldType) ++ NULL_TERM));
            } else {
                ig.Text(c"%llu (%s)", @intCast(usize, fieldPtr.*), &(@typeName(FieldType) ++ NULL_TERM));
            }
            ig.NextColumn();
        },
        .Float => {
            ig.AlignTextToFramePadding();
            _ = ig.TreeNodeExStr(name, INLINE_FLAGS);
            ig.NextColumn();
            ig.AlignTextToFramePadding();
            ig.Text(c"%f (%s)", fieldPtr.*, &(@typeName(FieldType) ++ NULL_TERM));
            ig.NextColumn();
        },
        .Array => |info| {
            drawSliceFieldUI(info.child, fieldPtr.*[0..info.len], name, arena);
        },
        .Enum => |info| {
            ig.AlignTextToFramePadding();
            _ = ig.TreeNodeExStr(name, INLINE_FLAGS);
            ig.NextColumn();
            ig.AlignTextToFramePadding();
            const cstr = if (std.fmt.allocPrint(arena, "{}" ++ NULL_TERM, @tagName(fieldPtr.*))) |str| str.ptr else |err| c"<out of memory>";
            ig.Text(c".%s", cstr);
            ig.NextColumn();
        },
        .Struct => |info| {
            ig.AlignTextToFramePadding();
            const nodeOpen = ig.TreeNodeStr(name);
            defer if (nodeOpen) ig.TreePop();
            ig.NextColumn();
            ig.AlignTextToFramePadding();
            ig.Text(c"%s", &(@typeName(FieldType) ++ NULL_TERM));
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
                _ = ig.TreeNodeExStr(name, INLINE_FLAGS);
                ig.NextColumn();
                ig.AlignTextToFramePadding();
                ig.Text(c"null");
                ig.NextColumn();
            }
        },
        .Pointer => |info| {
            switch (info.size) {
                .One => drawFieldUI(info.child, fieldPtr.*, name, arena),
                .Slice => drawSliceFieldUI(info.child, fieldPtr.*, name, arena),
                else => {
                    ig.AlignTextToFramePadding();
                    _ = ig.TreeNodeExStr(name, INLINE_FLAGS);
                    ig.NextColumn();
                    ig.AlignTextToFramePadding();
                    ig.Text(c"0x%p", fieldPtr.*);
                    ig.NextColumn();
                },
            }
        },
        .Opaque => {
            ig.AlignTextToFramePadding();
            _ = ig.TreeNodeExStr(name, INLINE_FLAGS);
            ig.NextColumn();
            ig.AlignTextToFramePadding();
            ig.Text(c"%s@0x%p", &(@typeName(FieldType) ++ NULL_TERM), fieldPtr);
            ig.NextColumn();
        },
        else => {
            ig.AlignTextToFramePadding();
            _ = ig.TreeNodeExStr(name, INLINE_FLAGS);
            ig.NextColumn();
            ig.AlignTextToFramePadding();
            ig.Text(&("<TODO " ++ @typeName(FieldType) ++ ">@0x%p" ++ NULL_TERM), fieldPtr);
            ig.NextColumn();
        },
    }
}

/// Recursively draws generated UI for a slice.  If the slice is []u8, checks if it is a printable string
/// and draws it if so.  Otherwise generates similar UI to a struct, with fields named [0], [1], etc.
/// If the slice has length one and its payload is a struct, the [0] field will be elided and the single
/// element will be displayed inline.
/// No memory from the passed arena is in use after this call.  It can be freed or reset.
fn drawSliceFieldUI(comptime DataType: type, slice: []const DataType, name: [*]const u8, arena: *Allocator) void {
    if (DataType == u8 and slice.len < MAX_STRING_LEN and isPrintable(slice)) {
        ig.AlignTextToFramePadding();
        _ = ig.TreeNodeExStr(name, INLINE_FLAGS);
        ig.NextColumn();
        ig.AlignTextToFramePadding();
        const nullTermStr = if (std.fmt.allocPrint(arena, "{}" ++ NULL_TERM, slice)) |cstr| cstr.ptr else |err| c"out of memory";
        ig.Text(c"\"%s\"", nullTermStr);
        ig.NextColumn();
    } else {
        ig.AlignTextToFramePadding();
        const nodeOpen = ig.TreeNodeStr(name);
        defer if (nodeOpen) ig.TreePop();
        ig.NextColumn();
        ig.AlignTextToFramePadding();
        ig.Text(c"[%llu]%s", slice.len, &(@typeName(DataType) ++ NULL_TERM));
        ig.NextColumn();
        if (nodeOpen) {
            const NextDisplayType = RemoveSinglePointers(DataType);
            if (@typeInfo(NextDisplayType) == .Struct and slice.len == 1) {
                drawStructUI(DataType, &slice[0], arena);
            } else {
                for (slice) |*item, i| {
                    const itemName: [*]const u8 = if (std.fmt.allocPrint(arena, "[{}]" ++ NULL_TERM, i)) |str| str.ptr else |err| c"<out of memory>";
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
