//! Logic solver and solvable-board generator. Pure Zig, no dependencies.
//!
//! A board is "solvable" if, after the first click, every safe cell can be
//! revealed by deduction alone: single-cell rules, subset rules between
//! overlapping numbers, and the global mine count. `generate` keeps trying
//! random layouts until one passes, so the player never has to guess.

const std = @import("std");

pub const MAX_CELLS = 512; // enough for 30x16 (480)

/// xorshift64*
pub const Rng = struct {
    s: u64 = 1,

    pub fn init(seed: u64) Rng {
        return .{ .s = if (seed != 0) seed else 1 };
    }

    pub fn next(r: *Rng) u64 {
        var x = r.s;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        r.s = x;
        return x *% 0x2545F4914F6CDD1D;
    }

    pub fn below(r: *Rng, n: usize) usize {
        return @intCast(r.next() % n);
    }
};

/// Board topology. Cell index = row * cols + col.
pub const Topo = struct {
    rows: usize,
    cols: usize,
    n: usize,
    nbn: [MAX_CELLS]u8, // neighbour count per cell
    nb: [MAX_CELLS][8]u16, // neighbour indices, ascending

    pub fn init(rows: usize, cols: usize) Topo {
        std.debug.assert(rows * cols <= MAX_CELLS);
        var t: Topo = .{
            .rows = rows,
            .cols = cols,
            .n = rows * cols,
            .nbn = @splat(0),
            .nb = undefined,
        };
        for (0..rows) |r| {
            for (0..cols) |c| {
                const i = r * cols + c;
                var k: u8 = 0;
                var dr: isize = -1;
                while (dr <= 1) : (dr += 1) {
                    var dc: isize = -1;
                    while (dc <= 1) : (dc += 1) {
                        if (dr == 0 and dc == 0) continue;
                        const rr = @as(isize, @intCast(r)) + dr;
                        const cc = @as(isize, @intCast(c)) + dc;
                        if (rr < 0 or rr >= rows or cc < 0 or cc >= cols) continue;
                        t.nb[i][k] = @intCast(rr * @as(isize, @intCast(cols)) + cc);
                        k += 1;
                    }
                }
                t.nbn[i] = k;
            }
        }
        return t;
    }

    pub fn neighbours(t: *const Topo, i: usize) []const u16 {
        return t.nb[i][0..t.nbn[i]];
    }
};

/// num[i] = number of mines adjacent to cell i.
pub fn countNumbers(t: *const Topo, mines: []const u8, num: []u8) void {
    for (0..t.n) |i| {
        var c: u8 = 0;
        for (t.neighbours(i)) |x| c += @intFromBool(mines[x] != 0);
        num[i] = c;
    }
}

/// Reveal `start` and flood through zero cells. Cells with blocked[i] set
/// (flags) are skipped; `blocked` may be null. Returns how many cells were
/// newly revealed.
pub fn floodReveal(
    t: *const Topo,
    mines: []const u8,
    num: []const u8,
    revealed: []u8,
    blocked: ?[]u8,
    start: usize,
) usize {
    var stack: [MAX_CELLS]u16 = undefined;
    var sp: usize = 0;
    var added: usize = 0;
    if (revealed[start] != 0 or mines[start] != 0) return 0;
    if (blocked) |b| if (b[start] != 0) return 0;
    revealed[start] = 1;
    added += 1;
    if (num[start] == 0) {
        stack[sp] = @intCast(start);
        sp += 1;
    }
    while (sp > 0) {
        sp -= 1;
        const x = stack[sp];
        for (t.neighbours(x)) |y| {
            if (revealed[y] != 0 or mines[y] != 0) continue;
            revealed[y] = 1;
            if (blocked) |b| b[y] = 0;
            added += 1;
            if (num[y] == 0) {
                stack[sp] = y;
                sp += 1;
            }
        }
    }
    return added;
}

/// One constraint: exactly `rem` mines among the `len` unknown cells in `cell`.
const Con = struct {
    len: u8,
    cell: [8]u16, // ascending
    rem: i32,
    src: u16, // the revealed cell this came from

    fn slice(c: *const Con) []const u16 {
        return c.cell[0..c.len];
    }
};

fn isSubset(a: *const Con, b: *const Con) bool {
    var j: usize = 0;
    for (a.slice()) |x| {
        while (j < b.len and b.cell[j] < x) j += 1;
        if (j >= b.len or b.cell[j] != x) return false;
        j += 1;
    }
    return true;
}

/// big minus small holds (big.rem - small.rem) mines: decide if that settles it.
fn markDiff(big: *const Con, small: *const Con, safe: []u8, mine: []u8) bool {
    var d: [8]u16 = undefined;
    var nd: usize = 0;
    var j: usize = 0;
    const rd = big.rem - small.rem;
    for (big.slice()) |x| {
        while (j < small.len and small.cell[j] < x) j += 1;
        if (j < small.len and small.cell[j] == x) continue;
        d[nd] = x;
        nd += 1;
    }
    if (rd == 0) {
        for (d[0..nd]) |x| safe[x] = 1;
        return nd > 0;
    }
    if (rd == nd) {
        for (d[0..nd]) |x| mine[x] = 1;
        return nd > 0;
    }
    return false;
}

fn absDiff(a: usize, b: usize) usize {
    return if (a > b) a - b else b - a;
}

/// True if pure logic, starting with a click on `start`, clears the whole
/// board. With `check` set, panics if any deduction contradicts the real
/// layout.
pub fn isSolvable(t: *const Topo, mines: []const u8, start: usize, check: bool) bool {
    const total = t.n;
    var num: [MAX_CELLS]u8 = undefined;
    var revealed: [MAX_CELLS]u8 = @splat(0);
    var known: [MAX_CELLS]u8 = @splat(0);
    var safe: [MAX_CELLS]u8 = undefined;
    var mine: [MAX_CELLS]u8 = undefined;
    var cons: [MAX_CELLS]Con = undefined;

    var mine_total: usize = 0;
    for (mines[0..total]) |m| mine_total += @intFromBool(m != 0);
    const safe_total = total - mine_total;

    countNumbers(t, mines, &num);
    var rev_count = floodReveal(t, mines, &num, &revealed, null, start);
    var known_count: usize = 0;

    while (rev_count < safe_total) {
        // Build constraints from revealed numbers that still touch unknown cells.
        var ncons: usize = 0;
        for (0..total) |cell| {
            if (revealed[cell] == 0 or num[cell] == 0) continue;
            const c = &cons[ncons];
            c.len = 0;
            var known_n: i32 = 0;
            for (t.neighbours(cell)) |x| {
                if (known[x] != 0) {
                    known_n += 1;
                } else if (revealed[x] == 0) {
                    c.cell[c.len] = x;
                    c.len += 1;
                }
            }
            if (c.len == 0) continue;
            c.rem = @as(i32, num[cell]) - known_n;
            c.src = @intCast(cell);
            ncons += 1;
        }

        @memset(safe[0..total], 0);
        @memset(mine[0..total], 0);
        var any = false;
        for (cons[0..ncons]) |*a| {
            if (a.rem == 0) {
                for (a.slice()) |x| safe[x] = 1;
                any = true;
            } else if (a.rem == a.len) {
                for (a.slice()) |x| mine[x] = 1;
                any = true;
            }
            // Subset rule against nearby constraints (they must be within 2 cells).
            const ar = a.src / t.cols;
            const ac = a.src % t.cols;
            for (cons[0..ncons]) |*b| {
                if (b.len >= a.len) continue;
                const br = b.src / t.cols;
                const bc = b.src % t.cols;
                if (absDiff(ar, br) > 2 or absDiff(ac, bc) > 2) continue;
                if (!isSubset(b, a)) continue;
                if (markDiff(a, b, &safe, &mine)) any = true;
            }
        }

        if (!any) { // global mine-count rule
            var unk: usize = 0;
            for (0..total) |i| unk += @intFromBool(revealed[i] == 0 and known[i] == 0);
            const left = mine_total - known_count;
            if (left == 0) {
                for (0..total) |i| {
                    if (revealed[i] == 0 and known[i] == 0) safe[i] = 1;
                }
            } else if (left == unk) {
                for (0..total) |i| {
                    if (revealed[i] == 0 and known[i] == 0) mine[i] = 1;
                }
            } else {
                return false; // stuck: would need a guess
            }
        }

        if (check) {
            for (0..total) |i| {
                if (safe[i] != 0 and mines[i] != 0)
                    std.debug.panic("solver marked a mine as safe (cell {d})", .{i});
                if (mine[i] != 0 and mines[i] == 0)
                    std.debug.panic("solver marked a safe cell as a mine (cell {d})", .{i});
            }
        }
        for (0..total) |i| {
            if (mine[i] != 0 and known[i] == 0) {
                known[i] = 1;
                known_count += 1;
            }
        }
        for (0..total) |i| {
            if (safe[i] != 0) rev_count += floodReveal(t, mines, &num, &revealed, null, i);
        }
    }
    return true;
}

/// Fills `mines_out` with a random layout that is solvable from a first click
/// on `start`. The clicked cell and its neighbours are mine-free, so the first
/// click always opens an area. Returns the number of layouts tried.
pub fn generate(
    t: *const Topo,
    mine_count: usize,
    start: usize,
    rng: *Rng,
    mines_out: []u8,
) error{TooManyMines}!usize {
    var prot: [MAX_CELLS]bool = @splat(false);
    var pool: [MAX_CELLS]u16 = undefined;
    var np: usize = 0;
    prot[start] = true;
    for (t.neighbours(start)) |x| prot[x] = true;
    for (0..t.n) |i| {
        if (!prot[i]) {
            pool[np] = @intCast(i);
            np += 1;
        }
    }
    if (mine_count > np) return error.TooManyMines;

    var attempts: usize = 0;
    while (true) {
        var p: [MAX_CELLS]u16 = undefined;
        attempts += 1;
        @memcpy(p[0..np], pool[0..np]);
        @memset(mines_out[0..t.n], 0);
        for (0..mine_count) |i| {
            const j = i + rng.below(np - i);
            std.mem.swap(u16, &p[i], &p[j]);
            mines_out[p[i]] = 1;
        }
        if (isSolvable(t, mines_out, start, false)) return attempts;
    }
}

// ---------- tests (ported from test_solver.c) ----------

const Preset = struct { name: []const u8, cols: usize, rows: usize, mines: usize };

const PRESETS = [3]Preset{
    .{ .name = "Easy", .cols = 9, .rows = 9, .mines = 10 },
    .{ .name = "Medium", .cols = 16, .rows = 16, .mines = 40 },
    .{ .name = "Expert", .cols = 30, .rows = 16, .mines = 99 },
};

test "generated boards are valid and solvable" {
    var rng = Rng.init(12345);
    for (PRESETS) |p| {
        const t = Topo.init(p.rows, p.cols);
        const boards = 30;
        var worst: usize = 0;
        for (0..boards) |_| {
            var mines: [MAX_CELLS]u8 = undefined;
            const start = rng.below(t.n);
            const attempts = try generate(&t, p.mines, start, &rng, &mines);
            try std.testing.expect(attempts > 0);
            worst = @max(worst, attempts);

            var count: usize = 0;
            for (mines[0..t.n]) |m| count += @intFromBool(m != 0);
            try std.testing.expectEqual(p.mines, count);
            try std.testing.expectEqual(@as(u8, 0), mines[start]);
            for (t.neighbours(start)) |x| try std.testing.expectEqual(@as(u8, 0), mines[x]);
            // check = true verifies every deduction against the real layout
            try std.testing.expect(isSolvable(&t, &mines, start, true));
        }
        std.debug.print("{s:<7} {d} boards OK, worst {d} attempts\n", .{ p.name, boards, worst });
    }
}

test "dense 9x9 boards are sometimes rejected, never contradicted" {
    var rng = Rng.init(54321);
    const t = Topo.init(9, 9);
    var ok: usize = 0;
    var bad: usize = 0;
    for (0..300) |_| {
        var mines: [MAX_CELLS]u8 = @splat(0);
        var placed: usize = 0;
        while (placed < 22) {
            const i = rng.below(81);
            var near_start = i == 40;
            for (t.neighbours(40)) |x| near_start = near_start or x == i;
            if (mines[i] == 0 and !near_start) {
                mines[i] = 1;
                placed += 1;
            }
        }
        if (isSolvable(&t, &mines, 40, true)) ok += 1 else bad += 1;
    }
    std.debug.print("dense 9x9: {d} solvable, {d} rejected\n", .{ ok, bad });
    try std.testing.expect(bad > 0);
}

test "topology of a 3x3 board" {
    const t = Topo.init(3, 3);
    try std.testing.expectEqualSlices(u16, &.{ 1, 3, 4 }, t.neighbours(0));
    try std.testing.expectEqualSlices(u16, &.{ 0, 1, 2, 3, 5, 6, 7, 8 }, t.neighbours(4));
}
