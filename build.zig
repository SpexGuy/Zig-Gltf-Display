const std = @import("std");
const path = std.fs.path;
const Builder = std.build.Builder;
const LibExeObjStep = std.build.LibExeObjStep;

const glslc_command = if (std.builtin.os.tag == .windows) "tools/win/glslc.exe" else "glslc";

pub fn build(b: *Builder) void {
    const exe = b.addExecutable("zig-gltf", "src/main.zig");
    setDependencies(b, exe);
    exe.install();

    const run_step = b.step("run", "Run the project");
    const run_cmd = exe.run();
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest("src/all_tests.zig");
    setDependencies(b, tests);

    const vscode_exe = b.addExecutable("vscode", "src/main.zig");
    setDependencies(b, vscode_exe);

    const vscode_install = b.addInstallArtifact(vscode_exe);

    const vscode_step = b.step("vscode", "Build for VSCode");
    vscode_step.dependOn(&vscode_install.step);

    const run_tests = b.step("test", "Run all tests");
    run_tests.dependOn(&tests.step);
}

fn setDependencies(b: *Builder, step: *LibExeObjStep) void {
    const mode = b.standardReleaseOptions();

    step.setBuildMode(mode);
    step.linkLibC();

    step.addPackagePath("imgui", "include/imgui.zig");
    step.addPackagePath("vk", "include/vk.zig");
    step.addPackagePath("glfw", "include/glfw.zig");
    step.addPackagePath("cgltf", "include/cgltf.zig");

    if (std.builtin.os.tag == .windows) {
        if (mode == .Debug) {
            step.linkSystemLibrary("lib/win/cimguid");
        } else {
            step.linkSystemLibrary("lib/win/cimgui");
        }
        step.linkSystemLibrary("lib/win/glfw3");
        step.linkSystemLibrary("lib/win/vulkan-1");
        step.linkSystemLibrary("gdi32");
        step.linkSystemLibrary("shell32");
    } else {
        step.linkSystemLibrary("glfw");
        step.linkSystemLibrary("vulkan");
        @compileError("TODO: Build and link cimgui for non-windows platforms");
    }

    step.addCSourceFile("c_src/cgltf.c", &[_][]const u8{ "-std=c99", "-DCGLTF_IMPLEMENTATION", "-D_CRT_SECURE_NO_WARNINGS" });
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
