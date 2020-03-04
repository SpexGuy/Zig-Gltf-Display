const std = @import("std");
const imgui = @import("imgui");
const Engine = @import("engine.zig").g_Engine;

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    try Engine.init(allocator);
    defer Engine.deinit();

    // Our state
    var show_demo_window = true;
    var show_another_window = false;
    var slider_value: f32 = 0;
    var counter: i32 = 0;
    var clearColor = imgui.Vec4{ .x = 0.5, .y = 0, .z = 1, .w = 1 };

    // Main loop
    while (try Engine.beginFrame()) : (Engine.endFrame()) {
        // 1. Show the big demo window (Most of the sample code is in imgui.ShowDemoWindow()! You can browse its code to learn more about Dear ImGui!).
        if (show_demo_window)
            imgui.ShowDemoWindow(&show_demo_window);

        // 2. Show a simple window that we create ourselves. We use a Begin/End pair to created a named window.
        {
            _ = imgui.Begin(c"Hello, world!", null, 0); // Create a window called "Hello, world!" and append into it.

            imgui.Text(c"This is some useful text."); // Display some text (you can use a format strings too)
            _ = imgui.Checkbox(c"Demo Window", &show_demo_window); // Edit bools storing our window open/close state
            _ = imgui.Checkbox(c"Another Window", &show_another_window);

            _ = imgui.SliderFloat(c"float", &slider_value, 0.0, 1.0, null, 1); // Edit 1 float using a slider from 0.0 to 1.0
            _ = imgui.ColorEdit3(c"clear color", @ptrCast(*[3]f32, &clearColor), 0); // Edit 3 floats representing a color

            if (imgui.Button(c"Button", imgui.Vec2{ .x = 0, .y = 0 })) // Buttons return true when clicked (most widgets return true when edited/activated)
                counter += 1;
            imgui.SameLine(0, -1);
            imgui.Text(c"counter = %d", counter);

            imgui.Text(c"Application average %.3f ms/frame (%.1f FPS)", 1000.0 / imgui.GetIO().Framerate, imgui.GetIO().Framerate);
            imgui.End();
        }

        // 3. Show another simple window.
        if (show_another_window) {
            _ = imgui.Begin(c"Another Window", &show_another_window, 0); // Pass a pointer to our bool variable (the window will have a closing button that will clear the bool when clicked)
            imgui.Text(c"Hello from another window!");
            if (imgui.Button(c"Close Me", imgui.Vec2{ .x = 0, .y = 0 }))
                show_another_window = false;
            imgui.End();
        }

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
