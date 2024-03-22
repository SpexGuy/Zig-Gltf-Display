const std = @import("std");
const path = std.fs.path;
const ArrayList = std.ArrayList;
const Builder = std.build.Builder;
const LibExeObjStep = std.build.LibExeObjStep;
const Module = std.build.Module;

const ig_build = @import("zig-imgui/imgui_build.zig");

const glslc_command = if (std.builtin.os.tag == .windows) "tools/win/glslc.exe" else "glslc";

pub fn build(b: *Builder) void {
    var buffer: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var allocator = fba.allocator();
    var module_names = ArrayList([]const u8).init(allocator);
    var module_list = ArrayList(*Module).init(allocator);

    const mode = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    // Add modules to the builder
    const mod_vk = b.addModule("vk", .{
        .source_file = .{ .path = "include/vk.zig" },
        .dependencies = &.{},
    });
    module_names.append("vk") catch @panic("");
    module_list.append(mod_vk) catch @panic("");

    const mod_glfw = b.addModule("glfw", .{
        .source_file = .{ .path = "include/glfw.zig" },
        .dependencies = &.{
            .{ .name = "vk", .module = mod_vk },
        },
    });
    module_names.append("glfw") catch @panic("");
    module_list.append(mod_glfw) catch @panic("");

    const mod_cgltf = b.addModule("cgltf", .{
        .source_file = .{ .path = "include/cgltf.zig" },
        .dependencies = &.{},
    });
    module_names.append("cgltf") catch @panic("");
    module_list.append(mod_cgltf) catch @panic("");

    ig_build.addTestStep(b, "imgui:test", "zig-imgui/imgui", mode, target);

    const exe = b.addExecutable(.{
        .name = "zig-gltf",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = mode,
    });
    setDependencies(exe, module_names, module_list, target);
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the project");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_source_file = .{ .path = "src/all_tests.zig" },
        .target = target,
        .optimize = mode,
    });
    setDependencies(tests, module_names, module_list, target);

    const vscode_exe = b.addExecutable(.{
        .name = "vscode",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = mode,
    });
    setDependencies(vscode_exe, module_names, module_list, target);

    const vscode_install = b.addInstallArtifact(vscode_exe, .{});

    const vscode_step = b.step("vscode", "Build for VSCode");
    vscode_step.dependOn(&vscode_install.step);

    const run_tests = b.step("test", "Run all tests");
    run_tests.dependOn(&tests.step);
}

fn setDependencies(step: *LibExeObjStep, module_names: ArrayList([]const u8), module_list: ArrayList(*Module), target: std.zig.CrossTarget) void {
    step.linkLibCpp();

    ig_build.link(step, "zig-imgui/imgui");

    // Add modules to the compilation step
    for (module_names.items, module_list.items) |name, mod| {
        step.addModule(name, mod);
    }

    // Windows libraries
    if (target.getOs().tag == .windows) {
        const glfw = if (target.getAbi() == .msvc) "lib/win/glfw3.lib" else "lib/win/libglfw3.a";
        step.addObjectFile(.{ .path = glfw });
        step.addObjectFile(.{ .path = "lib/win/vulkan-1.lib" });
        step.linkSystemLibrary("gdi32");
        step.linkSystemLibrary("shell32");
        if (step.kind == .exe) {
            step.subsystem = .Windows;
        }
    } else {
        step.linkSystemLibrary("glfw");
        step.linkSystemLibrary("vulkan");
    }

    // C source code and flags
    step.addCSourceFile(.{
        .file = .{ .path = "c_src/cgltf.c" },
        .flags = &[_][]const u8{ "-std=c99", "-DCGLTF_IMPLEMENTATION", "-D_CRT_SECURE_NO_WARNINGS" },
    });
}

fn addShader(b: *Builder, exe: anytype, in_file: []const u8, out_file: []const u8) !void {
    // example:
    // glslc -o shaders/vert.spv shaders/shader.vert
    const dirname = "shaders";
    const full_in = try path.join(b.allocator, &[_][]const u8{ dirname, in_file });
    const full_out = try path.join(b.allocator, &[_][]const u8{ dirname, out_file });

    const run_cmd = b.addSystemCommand(&[_][]const u8{
        glslc_command,
        "-o",
        full_out,
        full_in,
    });
    exe.step.dependOn(&run_cmd.step);
}
