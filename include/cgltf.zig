const assert = @import("std").debug.assert;

pub const CString = [*:0]const u8;
pub const MutCString = [*:0]u8;

pub const Bool32 = i32;

pub const FileType = enum(u32) {
    invalid,
    gltf,
    glb,
    _,
};

pub const Result = enum(u32) {
    success,
    data_too_short,
    unknown_format,
    invalid_json,
    invalid_gltf,
    invalid_options,
    file_not_found,
    io_error,
    out_of_memory,
    legacy_gltf,
    _,
};

pub const MemoryOptions = extern struct {
    alloc: ?*const fn (?*anyopaque, usize) callconv(.C) ?*anyopaque = null,
    free: ?*const fn (?*anyopaque, ?*anyopaque) callconv(.C) void = null,
    user_data: ?*anyopaque = null,
};

pub const FileOptions = extern struct {
    read: ?*const fn (*const MemoryOptions, *const FileOptions, CString, *usize, *(?*anyopaque)) callconv(.C) Result = null,
    release: ?*const fn (*const MemoryOptions, *const FileOptions, ?*anyopaque) callconv(.C) void = null,
    user_data: ?*anyopaque = null,
};

pub const Options = extern struct {
    type: FileType = .invalid,
    json_token_count: usize = 0,
    memory: MemoryOptions = MemoryOptions{},
    file: FileOptions = FileOptions{},
};

pub const BufferViewType = enum(u32) {
    invalid,
    indices,
    vertices,
    _,
};

pub const AttributeType = enum(u32) {
    invalid,
    position,
    normal,
    tangent,
    texcoord,
    color,
    joints,
    weights,
    _,
};

pub const ComponentType = enum(u32) {
    invalid,
    r_8,
    r_8u,
    r_16,
    r_16u,
    r_32u,
    r_32f,
    _,
};

pub const Type = enum(u32) {
    invalid,
    scalar,
    vec2,
    vec3,
    vec4,
    mat2,
    mat3,
    mat4,
    _,
};

pub const PrimitiveType = enum(u32) {
    points,
    lines,
    line_loop,
    line_strip,
    triangles,
    triangle_strip,
    triangle_fan,
    _,
};

pub const AlphaMode = enum(u32) {
    opaqueMode,
    mask,
    blend,
    _,
};

pub const AnimationPathType = enum(u32) {
    invalid,
    translation,
    rotation,
    scale,
    weights,
    _,
};

pub const InterpolationType = enum(u32) {
    linear,
    step,
    cubic_spline,
    _,
};

pub const CameraType = enum(u32) {
    invalid,
    perspective,
    orthographic,
    _,
};

pub const LightType = enum(u32) {
    invalid,
    directional,
    point,
    spot,
    _,
};

pub const Extras = extern struct {
    start_offset: usize,
    end_offset: usize,
};

pub const Buffer = extern struct {
    size: usize,
    uri: ?MutCString,
    data: ?*anyopaque,
    extras: Extras,
};

pub const BufferView = extern struct {
    buffer: *Buffer,
    offset: usize,
    size: usize,
    stride: usize,
    type: BufferViewType,
    extras: Extras,
};

pub const AccessorSparse = extern struct {
    count: usize,
    indices_buffer_view: ?*BufferView,
    indices_byte_offset: usize,
    indices_component_type: ComponentType,
    values_buffer_view: ?*BufferView,
    values_byte_offset: usize,
    extras: Extras,
    indices_extras: Extras,
    values_extras: Extras,
};

pub const Accessor = extern struct {
    component_type: ComponentType,
    normalized: Bool32,
    type: Type,
    offset: usize,
    count: usize,
    stride: usize,
    buffer_view: ?*BufferView,
    has_min: Bool32,
    min: [16]f32,
    has_max: Bool32,
    max: [16]f32,
    is_sparse: Bool32,
    sparse: AccessorSparse, // valid only if is_sparse != 0
    extras: Extras,
    pub inline fn unpackFloatsCount(self: *const Accessor) usize {
        return cgltf_accessor_unpack_floats(self, null, 0);
    }
    pub inline fn unpackFloats(self: *const Accessor, outBuffer: []f32) []f32 {
        const actualCount = cgltf_accessor_unpack_floats(self, outBuffer.ptr, outBuffer.len);
        return outBuffer[0..actualCount];
    }
    pub inline fn readFloat(self: *const Accessor, index: usize, outFloats: []f32) bool {
        assert(outFloats.len == numComponents(self.type));
        const result = cgltf_accessor_read_float(self, index, outFloats.ptr, outFloats.len);
        return result != 0;
    }
    pub inline fn readUint(self: *const Accessor, index: usize, outInts: []u32) bool {
        assert(outInts.len == numComponents(self.type));
        const result = cgltf_accessor_read_uint(self, index, outInts.ptr, outInts.len);
        return result != 0;
    }
    pub inline fn readIndex(self: *const Accessor, index: usize) usize {
        return cgltf_accessor_read_index(self, index);
    }
};

pub const Attribute = extern struct {
    name: ?MutCString,
    type: AttributeType,
    index: i32,
    data: *Accessor,
};

pub const Image = extern struct {
    name: ?MutCString,
    uri: ?MutCString,
    buffer_view: ?*BufferView,
    mime_type: ?MutCString,
    extras: Extras,
};

pub const Sampler = extern struct {
    mag_filter: i32,
    min_filter: i32,
    wrap_s: i32,
    wrap_t: i32,
    extras: Extras,
};

pub const Texture = extern struct {
    name: ?MutCString,
    image: ?*Image,
    sampler: ?*Sampler,
    extras: Extras,
};

pub const TextureTransform = extern struct {
    offset: [2]f32,
    rotation: f32,
    scale: [2]f32,
    texcoord: i32,
};

pub const TextureView = extern struct {
    texture: ?*Texture,
    texcoord: i32,
    scale: f32,
    has_transform: Bool32,
    transform: TextureTransform,
    extras: Extras,
};

pub const PbrMetallicRoughness = extern struct {
    base_color_texture: TextureView,
    metallic_roughness_texture: TextureView,
    base_color_factor: [4]f32,
    metallic_factor: f32,
    roughness_factor: f32,
    extras: Extras,
};

pub const PbrSpecularGlossiness = extern struct {
    diffuse_texture: TextureView,
    specular_glossiness_texture: TextureView,
    diffuse_factor: [4]f32,
    specular_factor: [3]f32,
    glossiness_factor: f32,
};

pub const Material = extern struct {
    name: ?MutCString,
    has_pbr_metallic_roughness: Bool32,
    has_pbr_specular_glossiness: Bool32,
    pbr_metallic_roughness: PbrMetallicRoughness,
    pbr_specular_glossiness: PbrSpecularGlossiness,
    normal_texture: TextureView,
    occlusion_texture: TextureView,
    emissive_texture: TextureView,
    emissive_factor: [3]f32,
    alpha_mode: AlphaMode,
    alpha_cutoff: f32,
    double_sided: Bool32,
    unlit: Bool32,
    extras: Extras,
};

pub const MorphTarget = extern struct {
    attributes: [*]Attribute,
    attributes_count: usize,
};

pub const Primitive = extern struct {
    type: PrimitiveType,
    indices: ?*Accessor,
    material: ?*Material,
    attributes: [*]Attribute,
    attributes_count: usize,
    targets: [*]MorphTarget,
    targets_count: usize,
    extras: Extras,
};

pub const Mesh = extern struct {
    name: ?MutCString,
    primitives: [*]Primitive,
    primitives_count: usize,
    weights: [*]f32,
    weights_count: usize,
    target_names: [*]MutCString,
    target_names_count: usize,
    extras: Extras,
};

pub const Skin = extern struct {
    name: ?MutCString,
    joints: [*]*Node,
    joints_count: usize,
    skeleton: ?*Node,
    inverse_bind_matrices: ?*Accessor,
    extras: Extras,
};

pub const CameraPerspective = extern struct {
    aspect_ratio: f32,
    yfov: f32,
    zfar: f32,
    znear: f32,
    extras: Extras,
};

pub const CameraOrthographic = extern struct {
    xmag: f32,
    ymag: f32,
    zfar: f32,
    znear: f32,
    extras: Extras,
};

pub const Camera = extern struct {
    name: ?MutCString,
    type: CameraType,
    data: extern union {
        perspective: CameraPerspective,
        orthographic: CameraOrthographic,
    },
    extras: Extras,
};

pub const Light = extern struct {
    name: ?MutCString,
    color: [3]f32,
    intensity: f32,
    type: LightType,
    range: f32,
    spot_inner_cone_angle: f32,
    spot_outer_cone_angle: f32,
};

pub const Node = extern struct {
    name: ?MutCString,
    parent: ?*Node,
    children: [*]*Node,
    children_count: usize,
    skin: ?*Skin,
    mesh: ?*Mesh,
    camera: ?*Camera,
    light: ?*Light,
    weights: [*]f32,
    weights_count: usize,
    has_translation: Bool32,
    has_rotation: Bool32,
    has_scale: Bool32,
    has_matrix: Bool32,
    translation: [3]f32,
    rotation: [4]f32,
    scale: [3]f32,
    matrix: [16]f32,
    extras: Extras,
    pub inline fn transformLocal(self: *const Node) [16]f32 {
        var transform: [16]f32 = undefined;
        cgltf_node_transform_local(self, &transform);
        return transform;
    }
    pub inline fn transformWorld(self: *const Node) [16]f32 {
        var transform: [16]f32 = undefined;
        cgltf_node_transform_world(self, &transform);
        return transform;
    }
};

pub const Scene = extern struct {
    name: ?MutCString,
    nodes: [*]*Node,
    nodes_count: usize,
    extras: Extras,
};

pub const AnimationSampler = extern struct {
    input: *Accessor,
    output: *Accessor,
    interpolation: InterpolationType,
    extras: Extras,
};

pub const AnimationChannel = extern struct {
    sampler: *AnimationSampler,
    target_node: ?*Node,
    target_path: AnimationPathType,
    extras: Extras,
};

pub const Animation = extern struct {
    name: ?MutCString,
    samplers: [*]AnimationSampler,
    samplers_count: usize,
    channels: [*]AnimationChannel,
    channels_count: usize,
    extras: Extras,
};

pub const Asset = extern struct {
    copyright: ?MutCString,
    generator: ?MutCString,
    version: ?MutCString,
    min_version: ?MutCString,
    extras: Extras,
};

pub const Data = extern struct {
    file_type: FileType,
    file_data: ?*anyopaque,
    asset: Asset,
    meshes: [*]Mesh,
    meshes_count: usize,
    materials: [*]Material,
    materials_count: usize,
    accessors: [*]Accessor,
    accessors_count: usize,
    buffer_views: [*]BufferView,
    buffer_views_count: usize,
    buffers: [*]Buffer,
    buffers_count: usize,
    images: [*]Image,
    images_count: usize,
    textures: [*]Texture,
    textures_count: usize,
    samplers: [*]Sampler,
    samplers_count: usize,
    skins: [*]Skin,
    skins_count: usize,
    cameras: [*]Camera,
    cameras_count: usize,
    lights: [*]Light,
    lights_count: usize,
    nodes: [*]Node,
    nodes_count: usize,
    scenes: [*]Scene,
    scenes_count: usize,
    scene: ?*Scene,
    animations: [*]Animation,
    animations_count: usize,
    extras: Extras,
    extensions_used: [*]MutCString,
    extensions_used_count: usize,
    extensions_required: [*]MutCString,
    extensions_required_count: usize,
    json: [*]const u8,
    json_size: usize,
    bin: ?*const anyopaque,
    bin_size: usize,
    memory: MemoryOptions,
    file: FileOptions,
};
pub inline fn parse(options: *const Options, data: []const u8) !*Data {
    var out_data: ?*Data = undefined;
    const result = cgltf_parse(options, data.ptr, data.len, &out_data);
    if (result == .success) return out_data.?;
    switch (result) {
        .data_too_short => return error.CgltfDataTooShort,
        .unknown_format => return error.CgltfUnknownFormat,
        .invalid_json => return error.CgltfInvalidJson,
        .invalid_gltf => return error.CgltfInvalidGltf,
        .invalid_options => return error.CgltfInvalidOptions,
        .file_not_found => return error.CgltfFileNotFound,
        .io_error => return error.CgltfIOError,
        .out_of_memory => return error.OutOfMemory,
        .legacy_gltf => return error.CgltfLegacyGltf,
        else => unreachable,
    }
}
pub inline fn parseFile(options: Options, path: CString) !*Data {
    var out_data: ?*Data = undefined;
    const result = cgltf_parse_file(&options, path, &out_data);
    if (result == .success) return out_data.?;
    switch (result) {
        .data_too_short => return error.CgltfDataTooShort,
        .unknown_format => return error.CgltfUnknownFormat,
        .invalid_json => return error.CgltfInvalidJson,
        .invalid_gltf => return error.CgltfInvalidGltf,
        .invalid_options => return error.CgltfInvalidOptions,
        .file_not_found => return error.CgltfFileNotFound,
        .io_error => return error.CgltfIOError,
        .out_of_memory => return error.OutOfMemory,
        .legacy_gltf => return error.CgltfLegacyGltf,
        else => unreachable,
    }
}
pub inline fn loadBuffers(options: Options, data: *Data, gltf_path: CString) !void {
    const result = cgltf_load_buffers(&options, data, gltf_path);
    if (result == .success) return;
    switch (result) {
        .data_too_short => return error.CgltfDataTooShort,
        .unknown_format => return error.CgltfUnknownFormat,
        .invalid_json => return error.CgltfInvalidJson,
        .invalid_gltf => return error.CgltfInvalidGltf,
        .invalid_options => return error.CgltfInvalidOptions,
        .file_not_found => return error.CgltfFileNotFound,
        .io_error => return error.CgltfIOError,
        .out_of_memory => return error.OutOfMemory,
        .legacy_gltf => return error.CgltfLegacyGltf,
        else => unreachable,
    }
}
pub inline fn loadBufferBase64(options: Options, size: usize, base64: []const u8) ![]u8 {
    assert(base64.len >= (size * 4 + 2) / 3);
    var out: ?*anyopaque = null;
    const result = cgltf_load_buffer_base64(&options, size, base64.ptr, &out);
    if (result == .success) {
        const temp: [*]u8 = @ptrCast(out.?);
        return temp[0..size];
    }
    switch (result) {
        .io_error => return error.CgltfIOError,
        .out_of_memory => return error.OutOfMemory,
        else => unreachable,
    }
}
pub inline fn validate(data: *Data) Result {
    return cgltf_validate(data);
}
pub inline fn free(data: *Data) void {
    cgltf_free(data);
}

pub fn numComponents(inType: Type) usize {
    // translated because we should at least try to inline this.
    return switch (inType) {
        .vec2 => 2,
        .vec3 => 3,
        .vec4 => 4,
        .mat2 => 4,
        .mat3 => 9,
        .mat4 => 16,
        else => 1,
    };
}
pub inline fn copyExtrasJsonCount(data: *const Data, extras: *const Extras) usize {
    var size: usize = 0;
    var result = cgltf_copy_extras_json(data, extras, null, &size);
    assert(result == .success); // can only fail on invalid size ptr
    return size;
}
pub inline fn copyExtrasJson(data: *const Data, extras: *const Extras, outBuffer: []u8) []u8 {
    var size: usize = outBuffer.len;
    var result = cgltf_copy_extras_json(data, extras, outBuffer.ptr, &size);
    assert(result == .success); // can only fail on invalid size ptr
    return outBuffer[0..size];
}

pub extern fn cgltf_parse(options: [*c]const Options, data: ?*const anyopaque, size: usize, out_data: [*c]([*c]Data)) Result;
pub extern fn cgltf_parse_file(options: [*c]const Options, path: [*c]const u8, out_data: [*c]([*c]Data)) Result;
pub extern fn cgltf_load_buffers(options: [*c]const Options, data: [*c]Data, gltf_path: [*c]const u8) Result;
pub extern fn cgltf_load_buffer_base64(options: [*c]const Options, size: usize, base64: [*c]const u8, out_data: [*c](?*anyopaque)) Result;
pub extern fn cgltf_validate(data: [*c]Data) Result;
pub extern fn cgltf_free(data: [*c]Data) void;
pub extern fn cgltf_node_transform_local(node: [*c]const Node, out_matrix: [*c]f32) void;
pub extern fn cgltf_node_transform_world(node: [*c]const Node, out_matrix: [*c]f32) void;
pub extern fn cgltf_accessor_read_float(accessor: [*c]const Accessor, index: usize, out: [*c]f32, element_size: usize) Bool32;
pub extern fn cgltf_accessor_read_uint(accessor: [*c]const Accessor, index: usize, out: [*c]u32, element_size: usize) Bool32;
pub extern fn cgltf_accessor_read_index(accessor: [*c]const Accessor, index: usize) usize;
pub extern fn cgltf_num_components(type_0: Type) usize;
pub extern fn cgltf_accessor_unpack_floats(accessor: [*c]const Accessor, out: [*c]f32, float_count: usize) usize;
pub extern fn cgltf_copy_extras_json(data: [*c]const Data, extras: [*c]const Extras, dest: [*c]u8, dest_size: [*c]usize) Result;
