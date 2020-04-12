const std = @import("std");
const path = std.fs.path;
const Builder = std.build.Builder;
const LibExeObjStep = std.build.LibExeObjStep;

const glslc_command = if (std.builtin.os.tag == .windows) "tools/win/glslc.exe" else "glslc";

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const exe = b.addExecutable("zig-gltf", "src/main.zig");
    exe.setBuildMode(mode);
    exe.linkLibC();

    exe.addPackagePath("imgui", "include/imgui.zig");
    exe.addPackagePath("vk", "include/vk.zig");
    exe.addPackagePath("glfw", "include/glfw.zig");
    exe.addPackagePath("cgltf", "include/cgltf.zig");

    if (std.builtin.os.tag == .windows) {
        exe.linkSystemLibrary("lib/win/cimguid");
        exe.linkSystemLibrary("lib/win/glfw3");
        exe.linkSystemLibrary("lib/win/vulkan-1");
        exe.linkSystemLibrary("gdi32");
        exe.linkSystemLibrary("shell32");
    } else {
        exe.linkSystemLibrary("glfw");
        exe.linkSystemLibrary("vulkan");
        @compileError("TODO: Build and link cimgui for non-windows platforms");
    }

    exe.addCSourceFile("c_src/cgltf.c", &[_][]const u8{ "-std=c99", "-DCGLTF_IMPLEMENTATION", "-D_CRT_SECURE_NO_WARNINGS" });

    exe.install();

    const run_step = b.step("run", "Run the project");
    const run_cmd = exe.run();
    run_step.dependOn(&run_cmd.step);
}

fn addShader(b: *Builder, exe: var, in_file: []const u8, out_file: []const u8) !void {
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
