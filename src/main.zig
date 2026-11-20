const std = @import("std");
const c = @import("c");
const sv = @import("solver");

// layout constants

const CELL: f32 = 32;
const HEADER_H: f32 = 90;
const PAD: f32 = 10;
const MIN_W: f32 = 376;

const Preset = struct {
    name: []const u8,
    cols: usize,
    rows: usize,
    mines: usize,
};

const PRESETS = [3]Preset{
    .{ .name = "Easy", .cols = 9, .rows = 9, .mines = 10 },
    .{ .name = "Medium", .cols = 16, .rows = 16, .mines = 40 },
    .{ .name = "Expert", .cols = 30, .rows = 16, .mines = 99 },
};

const Color = struct { r: u8, g: u8, b: u8 };

const C_BG = Color{ .r = 32, .g = 37, .b = 46 };
const C_TEXT = Color{ .r = 235, .g = 238, .b = 243 };
const C_WIN = Color{ .r = 120, .g = 220, .b = 140 };
const C_BTN = Color{ .r = 58, .g = 67, .b = 80 };
const C_BTN_ON = Color{ .r = 79, .g = 124, .b = 255 };
const C_HIDDEN = Color{ .r = 184, .g = 194, .b = 207 };
const C_HIDDEN_HI = Color{ .r = 227, .g = 232, .b = 238 };
const C_HIDDEN_LO = Color{ .r = 123, .g = 135, .b = 148 };
const C_OPEN = Color{ .r = 232, .g = 232, .b = 232 };
const C_OPEN_EDGE = Color{ .r = 169, .g = 178, .b = 189 };
const C_BOOM = Color{ .r = 224, .g = 64, .b = 64 };
const C_BLACK = Color{ .r = 20, .g = 20, .b = 20 };
const C_FLAG = Color{ .r = 211, .g = 47, .b = 47 };
const NUM_COLOR = [9]Color{
    .{ .r = 0, .g = 0, .b = 0 },
    .{ .r = 31, .g = 79, .b = 216 },
    .{ .r = 27, .g = 138, .b = 46 },
    .{ .r = 211, .g = 47, .b = 47 },
    .{ .r = 26, .g = 35, .b = 126 },
    .{ .r = 142, .g = 27, .b = 27 },
    .{ .r = 0, .g = 131, .b = 143 },
    .{ .r = 34, .g = 34, .b = 34 },
    .{ .r = 102, .g = 102, .b = 102 },
};

// game state

const Game = struct {
    diff: usize = 0,
    rows: usize = 9,
    cols: usize = 9,
    mine_count: usize = 10,
    topo: sv.Topo = undefined,
    mines: [sv.MAX_CELLS]u8 = @splat(0),
    num: [sv.MAX_CELLS]u8 = @splat(0),
    revealed: [sv.MAX_CELLS]u8 = @splat(0),
    flags: [sv.MAX_CELLS]u8 = @splat(0),
    generated: bool = false,
    over: bool = false,
    won: bool = false,
    boom: isize = -1,
    rev_count: usize = 0,
    flag_count: usize = 0,
    start_ticks: u64 = 0,
    final_secs: i32 = 0,
    timer_stopped: bool = false,
    rng: sv.Rng = .{},
};

var g: Game = .{};
var pass_action: c.sg_pass_action = .{};

// last known mouse position (framebuffer pixels), used for hover-based keys
var mouse_x: f32 = 0;
var mouse_y: f32 = 0;

// per-frame layout, set at the start of drawGame()
const Layout = struct {
    s: f32, // framebuffer pixels per design unit
    ox: f32, // framebuffer pixel position of design-space (0, 0)
    oy: f32,
    w: f32, // design-space width
};
var lay: Layout = .{ .s = 1, .ox = 0, .oy = 0, .w = MIN_W };
var ts: f32 = 2; // text scale: framebuffer pixels per font pixel

// ---------- game logic ----------

fn newGame(diff: usize) void {
    const p = PRESETS[diff];
    g.diff = diff;
    g.cols = p.cols;
    g.rows = p.rows;
    g.mine_count = p.mines;
    g.topo = sv.Topo.init(p.rows, p.cols);
    @memset(&g.mines, 0);
    @memset(&g.num, 0);
    @memset(&g.revealed, 0);
    @memset(&g.flags, 0);
    g.generated = false;
    g.over = false;
    g.won = false;
    g.boom = -1;
    g.rev_count = 0;
    g.flag_count = 0;
    g.start_ticks = 0;
    g.final_secs = 0;
    g.timer_stopped = false;
}

fn secsSince(start: u64) i32 {
    const s: f64 = c.stm_sec(c.stm_since(start));
    return @intFromFloat(@min(s, 999.0));
}

fn elapsedSecs() i32 {
    if (g.over) return g.final_secs;
    if (!g.generated) return 0;
    return secsSince(g.start_ticks);
}

fn reveal(i: usize) void {
    if (g.revealed[i] != 0 or g.flags[i] != 0) return;
    if (g.mines[i] != 0) {
        g.boom = @intCast(i);
        g.over = true;
        return;
    }
    g.rev_count += sv.floodReveal(&g.topo, &g.mines, &g.num, &g.revealed, g.flags[0..], i);
}

fn chord(i: usize) void {
    const n = g.num[i];
    if (n == 0) return;
    var f: u8 = 0;
    for (g.topo.neighbours(i)) |nb| {
        if (g.flags[nb] != 0) f += 1;
    }
    if (f != n) return;
    for (g.topo.neighbours(i)) |x| {
        if (g.flags[x] == 0 and g.revealed[x] == 0) {
            reveal(x);
            if (g.over) return;
        }
    }
}

fn finishCheck() void {
    if (!g.over and g.rev_count == g.topo.n - g.mine_count) {
        g.over = true;
        g.won = true;
        for (0..g.topo.n) |i| g.flags[i] = g.mines[i];
        g.flag_count = g.mine_count;
    }
    if (g.over and g.generated and !g.timer_stopped) {
        g.final_secs = secsSince(g.start_ticks);
        g.timer_stopped = true;
    }
}

fn leftClick(i: usize) void {
    if (g.over) return;
    if (g.revealed[i] != 0) {
        chord(i);
    } else if (g.flags[i] == 0) {
        if (!g.generated) {
            // the presets always leave room for the mines, so this can't fail
            _ = sv.generate(&g.topo, g.mine_count, i, &g.rng, &g.mines) catch unreachable;
            sv.countNumbers(&g.topo, &g.mines, &g.num);
            g.generated = true;
            g.start_ticks = c.stm_now();
        }
        reveal(i);
    }
    finishCheck();
}

fn flagClick(i: usize) void {
    if (g.over or g.revealed[i] != 0) return;
    g.flags[i] ^= 1;
    if (g.flags[i] != 0) g.flag_count += 1 else g.flag_count -= 1;
}

// ---------- layout ----------

fn colsF() f32 {
    return @floatFromInt(g.cols);
}

fn rowsF() f32 {
    return @floatFromInt(g.rows);
}

fn designW() f32 {
    return @max(colsF() * CELL, MIN_W);
}

fn designH() f32 {
    return HEADER_H + rowsF() * CELL + PAD;
}

fn boardX() f32 {
    return (designW() - colsF() * CELL) / 2;
}

/// Pure function of the current framebuffer size and board size. Used by both
/// drawing and mouse picking, so they can never disagree.
fn computeLayout() Layout {
    const fw = c.sapp_widthf();
    const fh = c.sapp_heightf();
    const w = designW();
    const h = designH();
    const fit = @min(fw / w, fh / h);
    // snap the cell to whole pixels so grid lines stay crisp at any window size
    const cell_px = @max(1.0, @floor(fit * CELL));
    const s = cell_px / CELL;
    return .{
        .s = s,
        .ox = @floor((fw - w * s) / 2),
        .oy = @floor((fh - h * s) / 2),
        .w = w,
    };
}

const Btn = struct { x: f32, y: f32, w: f32, h: f32 };

fn diffButton(k: usize) Btn {
    return .{
        .x = (designW() - 352) / 2 + @as(f32, @floatFromInt(k)) * 120,
        .y = 8,
        .w = 112,
        .h = 30,
    };
}

fn mouseToCell(l: Layout, mx: f32, my: f32) ?usize {
    const dx = (mx - l.ox) / l.s;
    const dy = (my - l.oy) / l.s;
    const col = @floor((dx - boardX()) / CELL);
    const row = @floor((dy - HEADER_H) / CELL);
    if (col < 0 or row < 0 or col >= colsF() or row >= rowsF()) return null;
    const ci: usize = @intFromFloat(col);
    const ri: usize = @intFromFloat(row);
    return ri * g.cols + ci;
}

// ---------- drawing primitives (design units in, framebuffer pixels out) ----------

fn rect(x: f32, y: f32, w: f32, h: f32, col: Color) void {
    // round both edges so neighbouring rects always meet without gaps
    const x0 = lay.ox + @round(x * lay.s);
    const y0 = lay.oy + @round(y * lay.s);
    const x1 = lay.ox + @round((x + w) * lay.s);
    const y1 = lay.oy + @round((y + h) * lay.s);
    c.sgl_begin_quads();
    c.sgl_v2f_c3b(x0, y0, col.r, col.g, col.b);
    c.sgl_v2f_c3b(x1, y0, col.r, col.g, col.b);
    c.sgl_v2f_c3b(x1, y1, col.r, col.g, col.b);
    c.sgl_v2f_c3b(x0, y1, col.r, col.g, col.b);
    c.sgl_end();
}

fn tri(ax: f32, ay: f32, bx: f32, by: f32, cx: f32, cy: f32, col: Color) void {
    c.sgl_begin_triangles();
    c.sgl_v2f_c3b(lay.ox + ax * lay.s, lay.oy + ay * lay.s, col.r, col.g, col.b);
    c.sgl_v2f_c3b(lay.ox + bx * lay.s, lay.oy + by * lay.s, col.r, col.g, col.b);
    c.sgl_v2f_c3b(lay.ox + cx * lay.s, lay.oy + cy * lay.s, col.r, col.g, col.b);
    c.sgl_end();
}

fn disc(cx: f32, cy: f32, r: f32, col: Color) void {
    const segs = 24;
    const px = lay.ox + cx * lay.s;
    const py = lay.oy + cy * lay.s;
    const pr = r * lay.s;
    c.sgl_begin_triangles();
    var k: usize = 0;
    while (k < segs) : (k += 1) {
        const a0 = 2.0 * std.math.pi * @as(f32, @floatFromInt(k)) / segs;
        const a1 = 2.0 * std.math.pi * @as(f32, @floatFromInt(k + 1)) / segs;
        c.sgl_v2f_c3b(px, py, col.r, col.g, col.b);
        c.sgl_v2f_c3b(px + pr * @cos(a0), py + pr * @sin(a0), col.r, col.g, col.b);
        c.sgl_v2f_c3b(px + pr * @cos(a1), py + pr * @sin(a1), col.r, col.g, col.b);
    }
    c.sgl_end();
}

fn line(ax: f32, ay: f32, bx: f32, by: f32, thickness: f32, col: Color) void {
    const x0 = lay.ox + ax * lay.s;
    const y0 = lay.oy + ay * lay.s;
    const x1 = lay.ox + bx * lay.s;
    const y1 = lay.oy + by * lay.s;
    const dx = x1 - x0;
    const dy = y1 - y0;
    const len = @sqrt(dx * dx + dy * dy);
    if (len == 0) return;
    const half = @max(1.0, thickness * lay.s) / 2;
    const nx = -dy / len * half;
    const ny = dx / len * half;
    c.sgl_begin_quads();
    c.sgl_v2f_c3b(x0 + nx, y0 + ny, col.r, col.g, col.b);
    c.sgl_v2f_c3b(x1 + nx, y1 + ny, col.r, col.g, col.b);
    c.sgl_v2f_c3b(x1 - nx, y1 - ny, col.r, col.g, col.b);
    c.sgl_v2f_c3b(x0 - nx, y0 - ny, col.r, col.g, col.b);
    c.sgl_end();
}

const Anchor = enum { left, center, right };

/// Text in the 8x8 debug font. dx is the anchor x in design units, cy the
/// vertical centre of the text in design units.
fn text(anchor: Anchor, dx: f32, cy: f32, s: []const u8, col: Color) void {
    if (s.len == 0) return;
    const glyph = 8 * ts; // glyph size in framebuffer pixels
    const width = glyph * @as(f32, @floatFromInt(s.len));
    const px = lay.ox + dx * lay.s;
    const py = @round(lay.oy + cy * lay.s - glyph / 2);
    const x = @round(switch (anchor) {
        .left => px,
        .center => px - width / 2,
        .right => px - width,
    });
    // sdtx positions are in character cells
    c.sdtx_pos(x / glyph, py / glyph);
    c.sdtx_color3b(col.r, col.g, col.b);
    c.sdtx_putr(s.ptr, @intCast(s.len));
}

/// "<prefix>NNN" with zero-padded digits, like printf("%03d").
fn label(buf: *[32]u8, prefix: []const u8, n: i32) []const u8 {
    @memcpy(buf[0..prefix.len], prefix);
    var len = prefix.len;
    var v: i32 = n;
    var digits: usize = 3;
    if (v < 0) {
        buf[len] = '-';
        len += 1;
        v = @min(-v, 99);
        digits = 2;
    } else {
        v = @min(v, 999);
    }
    var d = digits;
    while (d > 0) {
        d -= 1;
        buf[len + d] = '0' + @as(u8, @intCast(@mod(v, 10)));
        v = @divTrunc(v, 10);
    }
    return buf[0 .. len + digits];
}

// ---------- drawing ----------

fn flag(x0: f32, y0: f32) void {
    tri(x0 + 14, y0 + 6, x0 + 14, y0 + 16, x0 + 24, y0 + 11, C_FLAG);
    rect(x0 + 13, y0 + 6, 2, 19, C_BLACK);
    rect(x0 + 8, y0 + 24, 14, 3, C_BLACK);
}

fn drawCell(i: usize, x0: f32, y0: f32) void {
    const is_mine = g.generated and g.mines[i] != 0;
    const show_mine = g.over and !g.won and is_mine and g.flags[i] == 0;
    if (g.revealed[i] != 0 or show_mine) {
        rect(x0, y0, CELL, CELL, C_OPEN_EDGE);
        const is_boom = g.boom == @as(isize, @intCast(i));
        rect(x0 + 1, y0 + 1, CELL - 2, CELL - 2, if (is_boom) C_BOOM else C_OPEN);
        if (is_mine) {
            disc(x0 + CELL / 2, y0 + CELL / 2, 8, C_BLACK);
        } else if (g.num[i] > 0) {
            const ch = [1]u8{'0' + g.num[i]};
            text(.center, x0 + CELL / 2, y0 + CELL / 2, &ch, NUM_COLOR[g.num[i]]);
        }
        return;
    }
    rect(x0, y0, CELL, CELL, C_HIDDEN_LO);
    rect(x0, y0, CELL - 1, CELL - 1, C_HIDDEN_HI);
    rect(x0 + 2, y0 + 2, CELL - 4, CELL - 4, C_HIDDEN);
    if (g.flags[i] != 0) {
        flag(x0, y0);
        if (g.over and !g.won and !is_mine) { // wrong flag
            line(x0 + 5, y0 + 5, x0 + CELL - 5, y0 + CELL - 5, 1, C_BLACK);
            line(x0 + CELL - 5, y0 + 5, x0 + 5, y0 + CELL - 5, 1, C_BLACK);
        }
    }
}

fn drawGame() void {
    const fw = c.sapp_widthf();
    const fh = c.sapp_heightf();

    lay = computeLayout();
    ts = @max(1.0, @floor(2.0 * lay.s)); // whole-number font scale stays crisp

    c.sdtx_canvas(fw / ts, fh / ts);
    c.sdtx_origin(0, 0);
    c.sdtx_font(0);

    c.sgl_defaults();
    c.sgl_viewport(0, 0, c.sapp_width(), c.sapp_height(), true);
    c.sgl_ortho(0, fw, fh, 0, -1, 1); // pixel coordinates, origin top-left

    // difficulty buttons
    for (0..3) |k| {
        const b = diffButton(k);
        rect(b.x, b.y, b.w, b.h, if (k == g.diff) C_BTN_ON else C_BTN);
        text(.center, b.x + b.w / 2, b.y + 15, PRESETS[k].name, C_TEXT);
    }

    // counters and status
    var buf: [32]u8 = undefined;
    text(.left, 12, 56, label(&buf, "Mines ", @as(i32, @intCast(g.mine_count)) - @as(i32, @intCast(g.flag_count))), C_TEXT);
    text(.right, lay.w - 12, 56, label(&buf, "Time ", elapsedSecs()), C_TEXT);
    const status: []const u8 = if (g.won)
        "Solved! Press R"
    else if (g.over)
        "Boom! Press R"
    else if (g.generated)
        ""
    else
        "Click any cell";
    text(.center, lay.w / 2, 76, status, if (g.won) C_WIN else C_TEXT);

    // board
    const bx = boardX();
    for (0..g.rows) |row| {
        for (0..g.cols) |col| {
            drawCell(
                row * g.cols + col,
                bx + @as(f32, @floatFromInt(col)) * CELL,
                HEADER_H + @as(f32, @floatFromInt(row)) * CELL,
            );
        }
    }
}

// ---------- input ----------

fn hovered() ?usize {
    return mouseToCell(computeLayout(), mouse_x, mouse_y);
}

fn onClick(left: bool, right: bool, ctrl: bool) void {
    const l = computeLayout();
    if (left) {
        const dx = (mouse_x - l.ox) / l.s;
        const dy = (mouse_y - l.oy) / l.s;
        for (0..3) |k| {
            const b = diffButton(k);
            if (dx >= b.x and dx < b.x + b.w and dy >= b.y and dy < b.y + b.h) {
                newGame(k);
                return;
            }
        }
    }
    const cell = mouseToCell(l, mouse_x, mouse_y) orelse return;
    if (right or (left and ctrl)) {
        flagClick(cell);
    } else if (left) {
        leftClick(cell);
    }
}

fn onKey(key: c.sapp_keycode) void {
    switch (key) {
        c.SAPP_KEYCODE_ESCAPE => c.sapp_request_quit(),
        c.SAPP_KEYCODE_R, c.SAPP_KEYCODE_F2 => newGame(g.diff),
        c.SAPP_KEYCODE_1 => newGame(0),
        c.SAPP_KEYCODE_2 => newGame(1),
        c.SAPP_KEYCODE_3 => newGame(2),
        c.SAPP_KEYCODE_F => {
            if (hovered()) |i| flagClick(i);
        },
        c.SAPP_KEYCODE_SPACE => {
            if (hovered()) |i| leftClick(i);
        },
        else => {},
    }
}

fn event(ev_ptr: [*c]const c.sapp_event) callconv(.c) void {
    const ev = ev_ptr.*;
    switch (ev.type) {
        c.SAPP_EVENTTYPE_MOUSE_MOVE => {
            mouse_x = ev.mouse_x;
            mouse_y = ev.mouse_y;
        },
        c.SAPP_EVENTTYPE_MOUSE_DOWN => {
            mouse_x = ev.mouse_x;
            mouse_y = ev.mouse_y;
            onClick(
                ev.mouse_button == c.SAPP_MOUSEBUTTON_LEFT,
                ev.mouse_button == c.SAPP_MOUSEBUTTON_RIGHT,
                (ev.modifiers & c.SAPP_MODIFIER_CTRL) != 0,
            );
        },
        c.SAPP_EVENTTYPE_KEY_DOWN => {
            if (!ev.key_repeat) onKey(ev.key_code);
        },
        else => {},
    }
}

// ---------- sokol callbacks ----------

fn init() callconv(.c) void {
    c.sg_setup(&.{
        .environment = c.sglue_environment(),
        .logger = .{ .func = c.slog_func },
    });
    c.sgl_setup(&.{
        .logger = .{ .func = c.slog_func },
    });
    var dt = std.mem.zeroes(c.sdtx_desc_t);
    dt.fonts[0] = c.sdtx_font_cpc();
    dt.logger.func = c.slog_func;
    c.sdtx_setup(&dt);
    c.stm_setup();

    pass_action.colors[0] = .{
        .load_action = c.SG_LOADACTION_CLEAR,
        .clear_value = .{
            .r = @as(f32, C_BG.r) / 255.0,
            .g = @as(f32, C_BG.g) / 255.0,
            .b = @as(f32, C_BG.b) / 255.0,
            .a = 1,
        },
    };

    const t: u64 = @intCast(c.time(null));
    g.rng = sv.Rng.init((t *% 0x9E3779B97F4A7C15) ^ c.stm_now());
    newGame(0);
}

fn frame() callconv(.c) void {
    drawGame();

    c.sg_begin_pass(&.{ .action = pass_action, .swapchain = c.sglue_swapchain() });
    c.sgl_draw();
    c.sdtx_draw();
    c.sg_end_pass();
    c.sg_commit();
}

fn cleanup() callconv(.c) void {
    c.sdtx_shutdown();
    c.sgl_shutdown();
    c.sg_shutdown();
}

pub fn main() void {
    c.sapp_run(&.{
        .init_cb = init,
        .frame_cb = frame,
        .cleanup_cb = cleanup,
        .event_cb = event,
        // sized so Expert fits at 1:1; the layout rescales to any window size
        .width = 960,
        .height = 620,
        .high_dpi = true,
        .window_title = "Minesweeper (always solvable)",
        .logger = .{ .func = c.slog_func },
    });
}
