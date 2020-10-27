const std = @import("std");
const cgltf = @import("cgltf");
const vk = @import("vk");
const engine = @import("engine.zig");
const render = engine.render;
const Child = std.meta.Child;

pub const Buffer = struct {
    raw: *cgltf.Buffer,

    usageFlags: vk.BufferUsageFlags = vk.BufferUsageFlags{},
    updateRate: engine.render.UpdateRate = .STATIC,
    gpuBuffer: ?render.Buffer = null,
};

pub const BufferView = struct {
    raw: *cgltf.BufferView,

    buffer: *Buffer,
};

pub const Accessor = struct {
    raw: *cgltf.Accessor,

    buffer_view: ?*BufferView,
    sparse_indices_buffer_view: ?*BufferView,
    sparse_values_buffer_view: ?*BufferView,
};

pub const Attribute = struct {
    raw: *cgltf.Attribute,

    name: [:0]const u8,
    data: *Accessor,
};

pub const Image = struct {
    raw: *cgltf.Image,

    name: [:0]const u8,
    buffer_view: ?*BufferView,
};

pub const Sampler = struct {
    raw: *cgltf.Sampler,
};

pub const Texture = struct {
    raw: *cgltf.Texture,

    name: [:0]const u8,
    image: ?*Image,
    sampler: ?*Sampler,
};

pub const Material = struct {
    raw: *cgltf.Material,

    name: [:0]const u8,
    pbr_metallic_color_texture: ?*Texture,
    pbr_metallic_roughness_texture: ?*Texture,
    pbr_specular_diffuse_texture: ?*Texture,
    pbr_specular_gloss_texture: ?*Texture,
    normal_texture: ?*Texture,
    occlusion_texture: ?*Texture,
    emissive_texture: ?*Texture,
};

pub const MorphTarget = struct {
    raw: *cgltf.MorphTarget,

    attributes: []Attribute,
};

pub const Primitive = struct {
    raw: *cgltf.Primitive,

    indices: ?*Accessor,
    material: ?*Material,
    attributes: []Attribute,
    targets: []MorphTarget,
};

pub const Mesh = struct {
    raw: *cgltf.Mesh,

    name: [:0]const u8,
    primitives: []Primitive,
    weights: []f32,
    target_names: [][:0]const u8,
};

pub const Skin = struct {
    raw: *cgltf.Skin,

    name: [:0]const u8,
    joints: []*Node,
    skeleton: ?*Node,
    inverse_bind_matrices: ?*Accessor,
};

pub const Camera = struct {
    raw: *cgltf.Camera,

    name: [:0]const u8,
};

pub const Light = struct {
    raw: *cgltf.Light,

    name: [:0]const u8,
};

pub const Node = struct {
    raw: *cgltf.Node,

    name: [:0]const u8,
    parent: ?*Node,
    children: []*Node,
    skin: ?*Skin,
    mesh: ?*Mesh,
    camera: ?*Camera,
    light: ?*Light,
};

pub const Scene = struct {
    raw: *cgltf.Scene,

    name: [:0]const u8,
    nodes: []*Node,
};

pub const AnimationSampler = struct {
    raw: *cgltf.AnimationSampler,

    input: *Accessor,
    output: *Accessor,
};

pub const AnimationChannel = struct {
    raw: *cgltf.AnimationChannel,

    sampler: *AnimationSampler,
    target_node: ?*Node,
};

pub const Animation = struct {
    raw: *cgltf.Animation,

    name: [:0]const u8,
    samplers: []AnimationSampler,
    channels: []AnimationChannel,
};

pub const Data = struct {
    raw: *cgltf.Data,

    allocator: std.heap.ArenaAllocator,
    meshes: []Mesh,
    materials: []Material,
    accessors: []Accessor,
    buffer_views: []BufferView,
    buffers: []Buffer,
    images: []Image,
    textures: []Texture,
    samplers: []Sampler,
    skins: []Skin,
    cameras: []Camera,
    lights: []Light,
    nodes: []Node,
    scenes: []Scene,
    scene: ?*Scene,
    animations: []Animation,

    renderingDataInitialized: bool = false,
};

pub fn wrap(rawData: *cgltf.Data, parentAllocator: *std.mem.Allocator) !*Data {
    var data = try parentAllocator.create(Data);
    errdefer parentAllocator.destroy(data);

    data.raw = rawData;
    data.allocator = std.heap.ArenaAllocator.init(parentAllocator);
    const allocator = &data.allocator.allocator;
    errdefer data.allocator.deinit();

    data.meshes = try allocator.alloc(Mesh, rawData.meshes_count);
    data.materials = try allocator.alloc(Material, rawData.materials_count);
    data.accessors = try allocator.alloc(Accessor, rawData.accessors_count);
    data.buffer_views = try allocator.alloc(BufferView, rawData.buffer_views_count);
    data.buffers = try allocator.alloc(Buffer, rawData.buffers_count);
    data.images = try allocator.alloc(Image, rawData.images_count);
    data.textures = try allocator.alloc(Texture, rawData.textures_count);
    data.samplers = try allocator.alloc(Sampler, rawData.samplers_count);
    data.skins = try allocator.alloc(Skin, rawData.skins_count);
    data.cameras = try allocator.alloc(Camera, rawData.cameras_count);
    data.lights = try allocator.alloc(Light, rawData.lights_count);
    data.nodes = try allocator.alloc(Node, rawData.nodes_count);
    data.scenes = try allocator.alloc(Scene, rawData.scenes_count);
    data.animations = try allocator.alloc(Animation, rawData.animations_count);

    for (data.meshes) |*mesh, i| {
        const rawMesh = &rawData.meshes[i];

        const primitives = try allocator.alloc(Primitive, rawMesh.primitives_count);
        for (primitives) |*prim, j| {
            const rawPrim = &rawMesh.primitives[j];

            const attributes = try copyAttributes(data, rawData, rawPrim.attributes, rawPrim.attributes_count);

            const targets = try allocator.alloc(MorphTarget, rawPrim.targets_count);
            for (targets) |*target, k| {
                const rawTarget = &rawPrim.targets[k];
                const targetAttributes = try copyAttributes(data, rawData, rawTarget.attributes, rawTarget.attributes_count);
                target.* = MorphTarget{
                    .raw = rawTarget,
                    .attributes = targetAttributes,
                };
            }

            prim.* = Primitive{
                .raw = rawPrim,
                .indices = fixOptional(rawPrim.indices, rawData.accessors, data.accessors),
                .material = fixOptional(rawPrim.material, rawData.materials, data.materials),
                .attributes = attributes,
                .targets = targets,
            };
        }

        const names = try allocator.alloc([:0]const u8, rawMesh.target_names_count);
        for (names) |*name, j| name.* = cstr(rawMesh.target_names[j]);

        mesh.* = Mesh{
            .raw = rawMesh,
            .name = cstr(rawMesh.name),
            .primitives = primitives,
            .weights = rawMesh.weights[0..rawMesh.weights_count],
            .target_names = names,
        };
    }

    for (data.materials) |*material, i| {
        const rawMat = &rawData.materials[i];

        material.* = Material{
            .raw = rawMat,
            .name = cstr(rawMat.name),
            .pbr_metallic_color_texture = null,
            .pbr_metallic_roughness_texture = null,
            .pbr_specular_diffuse_texture = null,
            .pbr_specular_gloss_texture = null,
            .normal_texture = fixOptional(rawMat.normal_texture.texture, rawData.textures, data.textures),
            .occlusion_texture = fixOptional(rawMat.occlusion_texture.texture, rawData.textures, data.textures),
            .emissive_texture = fixOptional(rawMat.emissive_texture.texture, rawData.textures, data.textures),
        };

        if (rawMat.has_pbr_metallic_roughness != 0) {
            material.pbr_metallic_color_texture = fixOptional(rawMat.pbr_metallic_roughness.base_color_texture.texture, rawData.textures, data.textures);
            material.pbr_metallic_roughness_texture = fixOptional(rawMat.pbr_metallic_roughness.metallic_roughness_texture.texture, rawData.textures, data.textures);
        }
        if (rawMat.has_pbr_specular_glossiness != 0) {
            material.pbr_specular_diffuse_texture = fixOptional(rawMat.pbr_specular_glossiness.diffuse_texture.texture, rawData.textures, data.textures);
            material.pbr_specular_gloss_texture = fixOptional(rawMat.pbr_specular_glossiness.specular_glossiness_texture.texture, rawData.textures, data.textures);
        }
    }

    for (data.accessors) |*accessor, i| {
        const rawAcc = &rawData.accessors[i];

        accessor.* = Accessor{
            .raw = rawAcc,
            .buffer_view = fixOptional(rawAcc.buffer_view, rawData.buffer_views, data.buffer_views),
            .sparse_indices_buffer_view = null,
            .sparse_values_buffer_view = null,
        };

        if (rawAcc.is_sparse != 0) {
            accessor.sparse_indices_buffer_view = fixOptional(rawAcc.sparse.indices_buffer_view, rawData.buffer_views, data.buffer_views);
            accessor.sparse_values_buffer_view = fixOptional(rawAcc.sparse.values_buffer_view, rawData.buffer_views, data.buffer_views);
        }
    }

    for (data.buffer_views) |*view, i| {
        const rawView = &rawData.buffer_views[i];
        view.* = BufferView{
            .raw = rawView,
            .buffer = fixNonnull(rawView.buffer, rawData.buffers, data.buffers),
        };
    }

    for (data.buffers) |*buffer, i| {
        const rawBuf = &rawData.buffers[i];
        buffer.* = Buffer{
            .raw = rawBuf,
        };
    }

    for (data.images) |*image, i| {
        const rawImage = &rawData.images[i];
        image.* = Image{
            .raw = rawImage,
            .name = cstr(rawImage.name),
            .buffer_view = fixNonnull(rawImage.buffer_view, rawData.buffer_views, data.buffer_views),
        };
    }

    for (data.textures) |*tex, i| {
        const rawTex = &rawData.textures[i];
        tex.* = Texture{
            .raw = rawTex,
            .name = cstr(rawTex.name),
            .image = fixOptional(rawTex.image, rawData.images, data.images),
            .sampler = fixOptional(rawTex.sampler, rawData.samplers, data.samplers),
        };
    }

    for (data.samplers) |*sampler, i| {
        sampler.* = Sampler{ .raw = &rawData.samplers[i] };
    }

    for (data.skins) |*skin, i| {
        const rawSkin = &rawData.skins[i];

        const joints = try allocator.alloc(*Node, rawSkin.joints_count);
        for (joints) |*joint, j| joint.* = fixNonnull(rawSkin.joints[j], rawData.nodes, data.nodes);

        skin.* = Skin{
            .raw = rawSkin,
            .name = cstr(rawSkin.name),
            .joints = joints,
            .skeleton = fixOptional(rawSkin.skeleton, rawData.nodes, data.nodes),
            .inverse_bind_matrices = fixOptional(rawSkin.inverse_bind_matrices, rawData.accessors, data.accessors),
        };
    }

    for (data.cameras) |*cam, i| {
        const rawCam = &rawData.cameras[i];
        cam.* = Camera{
            .raw = rawCam,
            .name = cstr(rawCam.name),
        };
    }

    for (data.lights) |*light, i| {
        const rawLight = &rawData.lights[i];
        light.* = Light{
            .raw = rawLight,
            .name = cstr(rawLight.name),
        };
    }

    for (data.nodes) |*node, i| {
        const rawNode = &rawData.nodes[i];

        const children = try allocator.alloc(*Node, rawNode.children_count);
        for (children) |*child, j| child.* = fixNonnull(rawNode.children[j], rawData.nodes, data.nodes);

        node.* = Node{
            .raw = rawNode,
            .name = cstr(rawNode.name),
            .parent = fixOptional(rawNode.parent, rawData.nodes, data.nodes),
            .children = children,
            .skin = fixOptional(rawNode.skin, rawData.skins, data.skins),
            .mesh = fixOptional(rawNode.mesh, rawData.meshes, data.meshes),
            .camera = fixOptional(rawNode.camera, rawData.cameras, data.cameras),
            .light = fixOptional(rawNode.light, rawData.lights, data.lights),
        };
    }

    for (data.scenes) |*scene, i| {
        const rawScene = &rawData.scenes[i];

        const nodes = try allocator.alloc(*Node, rawScene.nodes_count);
        for (nodes) |*node, j| node.* = fixNonnull(rawScene.nodes[j], rawData.nodes, data.nodes);

        scene.* = Scene{
            .raw = rawScene,
            .name = cstr(rawScene.name),
            .nodes = nodes,
        };
    }

    data.scene = fixOptional(rawData.scene, rawData.scenes, data.scenes);

    for (data.animations) |*anim, i| {
        const rawAnim = &rawData.animations[i];

        const samplers = try allocator.alloc(AnimationSampler, rawAnim.samplers_count);
        const channels = try allocator.alloc(AnimationChannel, rawAnim.channels_count);

        for (samplers) |*sampler, j| {
            const rawSampler = &rawAnim.samplers[j];
            sampler.* = AnimationSampler{
                .raw = rawSampler,
                .input = fixNonnull(rawSampler.input, rawData.accessors, data.accessors),
                .output = fixNonnull(rawSampler.output, rawData.accessors, data.accessors),
            };
        }

        for (channels) |*channel, j| {
            const rawChannel = &rawAnim.channels[j];
            channel.* = AnimationChannel{
                .raw = rawChannel,
                .sampler = fixNonnull(rawChannel.sampler, rawAnim.samplers, samplers),
                .target_node = fixOptional(rawChannel.target_node, rawData.nodes, data.nodes),
            };
        }

        anim.* = Animation{
            .raw = rawAnim,
            .name = cstr(rawAnim.name),
            .samplers = samplers,
            .channels = channels,
        };
    }

    return data;
}

const unnamed: [:0]const u8 = "<null>";

fn cstr(dataOpt: ?[*:0]const u8) [:0]const u8 {
    return if (dataOpt) |data| std.mem.spanZ(data) else unnamed;
}

fn copyAttributes(data: *Data, rawData: *cgltf.Data, rawAttributes: [*]cgltf.Attribute, rawCount: usize) ![]Attribute {
    const attributes = try data.allocator.allocator.alloc(Attribute, rawCount);
    for (attributes) |*attr, i| {
        const rawAttr = &rawAttributes[i];
        attr.* = Attribute{
            .raw = rawAttr,
            .name = cstr(rawAttr.name),
            .data = fixNonnull(rawAttr.data, rawData.accessors, data.accessors),
        };
    }
    return attributes;
}

pub fn free(data: *Data) void {
    const parentAllocator = data.allocator.child_allocator;
    data.allocator.deinit();
    parentAllocator.destroy(data);
}

fn fixOptional(pointer: anytype, rawArray: anytype, wrapArray: anytype) ?*Child(@TypeOf(wrapArray.ptr)) {
    if (pointer) |nonNull| {
        return fixNonnull(nonNull, rawArray, wrapArray);
    } else {
        return null;
    }
}

fn fixNonnull(pointer: anytype, rawArray: anytype, wrapArray: anytype) *Child(@TypeOf(wrapArray.ptr)) {
    const diff = @divExact(@ptrToInt(pointer) - @ptrToInt(rawArray), @sizeOf(Child(@TypeOf(rawArray))));
    return &wrapArray[diff];
}
