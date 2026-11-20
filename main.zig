const c = @import("c");

var pass_action: c.sg_pass_action = .{};
var t: f32 = 0;

fn init() callconv(.c) void {
    c.sg_setup(&.{
        .environment = c.sglue_environment(),
        .logger = .{ .func = c.slog_func },
    });
    pass_action.colors[0] = .{
        .load_action = c.SG_LOADACTION_CLEAR,
        .clear_value = .{ .r = 0.1, .g = 0.1, .b = 0.15, .a = 1 },
    };
}

fn frame() callconv(.c) void {
    t += @floatCast(c.sapp_frame_duration());
    pass_action.colors[0].clear_value.g = 0.5 + 0.5 * @sin(t);

    c.sg_begin_pass(&.{ .action = pass_action, .swapchain = c.sglue_swapchain() });
    c.sg_end_pass();
    c.sg_commit();
}

fn cleanup() callconv(.c) void {
    c.sg_shutdown();
}

pub fn main() void {
    c.sapp_run(&.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .width = 640,
        .height = 480,
        .window_title = "sokol + zig",
        .logger = .{ .func = c.slog_func },
    });
}
