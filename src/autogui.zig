const std = @import("std");
const ig = @import("imgui");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Child = std.meta.Child;

const NULL_TERM = [_]u8{0};
fn nullTerm(comptime str: []const u8) [:0]const u8 {
    const fullStr = str ++ NULL_TERM;
    return fullStr[0..str.len :0];
}

fn allocPrintZ(allocator: *Allocator, comptime fmt: []const u8, params: anytype) ![:0]const u8 {
    const formatted = try std.fmt.allocPrint(allocator, fmt ++ NULL_TERM, params);
    assert(formatted[formatted.len - 1] == 0);
    return formatted[0 .. formatted.len - 1 :0];
}

const INLINE_FLAGS = ig.TreeNodeFlags{ .Leaf = true, .NoTreePushOnOpen = true, .Bullet = true };
const MAX_STRING_LEN = 255;

pub fn draw(comptime DataType: type, dataPtr: *const DataType, heapAllocator: *Allocator) void {
    var allocatorRaw = std.heap.ArenaAllocator.init(heapAllocator);
    defer allocatorRaw.deinit();
    const arena = &allocatorRaw.allocator;

    drawStructUI(DataType, dataPtr, arena);
}

/// Recursively draws generated read-only UI for a single struct.
/// No memory from the passed arena is in use after this call.  It can be freed or reset.
pub fn drawStructUI(comptime DataType: type, dataPtr: *const DataType, arena: *Allocator) void {
    switch (@typeInfo(DataType)) {
        .Struct => |info| {
            inline for (info.fields) |field| {
                drawFieldUI(field.field_type, &@field(dataPtr, field.name), nullTerm(field.name), arena);
            }
        },
        .Pointer => {
            drawStructUI(Child(DataType), dataPtr.*, arena);
        },
        else => @compileError("Invalid type passed to drawStructUI: " ++ @typeName(DataType)),
    }
}

/// Recursively draws generated read-only UI for a named field.
/// name must be a null-terminated string.
/// No memory from the passed arena is in use after this call.  It can be freed or reset.
/// fieldPtr is `var` to allow arbitrary bit alignment
pub fn drawFieldUI(comptime FieldType: type, fieldPtr: anytype, name: [:0]const u8, arena: *Allocator) void {
    if (FieldType == c_void) {
        ig.AlignTextToFramePadding();
        _ = ig.TreeNodeExStrExt(name.ptr, INLINE_FLAGS);
        ig.NextColumn();
        ig.AlignTextToFramePadding();
        ig.Text("0x%p", fieldPtr);
        ig.NextColumn();
        return;
    }
    switch (@typeInfo(FieldType)) {
        .Bool => {
            ig.AlignTextToFramePadding();
            _ = ig.TreeNodeExStrExt(name.ptr, INLINE_FLAGS);
            ig.NextColumn();
            ig.AlignTextToFramePadding();
            ig.Text(if (fieldPtr.*) "true" else "false");
            ig.NextColumn();
        },
        .Int => |info| {
            ig.AlignTextToFramePadding();
            _ = ig.TreeNodeExStrExt(name.ptr, INLINE_FLAGS);
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
            _ = ig.TreeNodeExStrExt(name.ptr, INLINE_FLAGS);
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
            _ = ig.TreeNodeExStrExt(name.ptr, INLINE_FLAGS);
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
                _ = ig.TreeNodeExStrExt(name.ptr, INLINE_FLAGS);
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
                    _ = ig.TreeNodeExStrExt(name.ptr, INLINE_FLAGS);
                    ig.NextColumn();
                    ig.AlignTextToFramePadding();
                    ig.Text("0x%p", fieldPtr.*);
                    ig.NextColumn();
                },
            }
        },
        .Opaque => {
            ig.AlignTextToFramePadding();
            _ = ig.TreeNodeExStrExt(name.ptr, INLINE_FLAGS);
            ig.NextColumn();
            ig.AlignTextToFramePadding();
            ig.Text("%s@0x%p", @typeName(FieldType), fieldPtr);
            ig.NextColumn();
        },
        else => {
            ig.AlignTextToFramePadding();
            _ = ig.TreeNodeExStrExt(name.ptr, INLINE_FLAGS);
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
pub fn drawSliceFieldUI(comptime DataType: type, slice: []const DataType, name: [:0]const u8, arena: *Allocator) void {
    if (DataType == u8 and slice.len < MAX_STRING_LEN and isPrintable(slice)) {
        ig.AlignTextToFramePadding();
        _ = ig.TreeNodeExStrExt(name.ptr, INLINE_FLAGS);
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
        Type = Child(Type);
    };
    return Type;
}
