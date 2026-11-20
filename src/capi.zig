//! C ABI surface. Keep in sync with include/harf.h.
const std = @import("std");
const ct = @import("shape/ct.zig");
const term = @import("term.zig");
const pty = @import("pty.zig");
const vt = @import("vt.zig");
const draw = @import("draw.zig");
const config = @import("config.zig");

/// Phase 0 smoke test. Returns 0x48415246 ("HARF").
export fn harf_ping() u32 {
    return 0x48415246;
}

// ---- Terminal sessions (Phase 3): a child on a PTY, parsed into a logical-order grid ----

pub const HarfTermCallbacks = extern struct {
    ctx: ?*anyopaque,
    wake: ?*const fn (ctx: ?*anyopaque) callconv(.c) void,
    title: ?*const fn (ctx: ?*anyopaque) callconv(.c) void,
    bell: ?*const fn (ctx: ?*anyopaque) callconv(.c) void,
    exited: ?*const fn (ctx: ?*anyopaque, status: c_int) callconv(.c) void,
    /// OSC 52: UTF-8 text a program put on the clipboard (not NUL-terminated, borrowed for the call).
    clipboard_write: ?*const fn (ctx: ?*anyopaque, text: [*]const u8, len: usize) callconv(.c) void,
    /// OSC 9 / 777: untrusted UTF-8 title (may be empty) and body, borrowed for the call.
    notify: ?*const fn (ctx: ?*anyopaque, title: [*]const u8, title_len: usize, body: [*]const u8, body_len: usize) callconv(.c) void,
    /// OSC 133: a command started running or ended; only on that change (see `term.Callbacks.command`).
    command: ?*const fn (ctx: ?*anyopaque, running: c_int, exit_code: c_int, has_exit_code: c_int, duration_ms: u32) callconv(.c) void,
};

/// Opaque to C. Holds the session and the caller's callbacks; the session's own callbacks are
/// adapters that forward to `cb` (they run on the I/O thread).
const HarfTerm = struct {
    session: *term.Session,
    cb: HarfTermCallbacks,

    fn from(ctx: ?*anyopaque) *HarfTerm {
        return @ptrCast(@alignCast(ctx.?));
    }
    fn wake(ctx: ?*anyopaque) void {
        const self = from(ctx);
        if (self.cb.wake) |f| f(self.cb.ctx);
    }
    fn title(ctx: ?*anyopaque) void {
        const self = from(ctx);
        if (self.cb.title) |f| f(self.cb.ctx);
    }
    fn bell(ctx: ?*anyopaque) void {
        const self = from(ctx);
        if (self.cb.bell) |f| f(self.cb.ctx);
    }
    fn exited(ctx: ?*anyopaque, status: u8) void {
        const self = from(ctx);
        if (self.cb.exited) |f| f(self.cb.ctx, status);
    }
    fn clipboardWrite(ctx: ?*anyopaque, text: []const u8) void {
        const self = from(ctx);
        if (self.cb.clipboard_write) |f| f(self.cb.ctx, text.ptr, text.len);
    }
    fn notify(ctx: ?*anyopaque, heading: []const u8, body: []const u8) void {
        const self = from(ctx);
        if (self.cb.notify) |f| f(self.cb.ctx, heading.ptr, heading.len, body.ptr, body.len);
    }
    fn command(ctx: ?*anyopaque, running: bool, exit_code: ?i32, duration_ms: u32) void {
        const self = from(ctx);
        if (self.cb.command) |f| f(self.cb.ctx, @intFromBool(running), exit_code orelse 0, @intFromBool(exit_code != null), duration_ms);
    }
};

/// Starts a session. `argv` is a NULL-terminated program and arguments (`argv[0]` is the path),
/// or NULL for the user's login shell. Returns NULL for a zero size or if the child cannot start.
export fn harf_term_new(
    cols: u16,
    rows: u16,
    scrollback_bytes: usize,
    argv: ?[*:null]const ?[*:0]const u8,
    cb: ?*const HarfTermCallbacks,
) ?*HarfTerm {
    return harf_term_new_in(cols, rows, scrollback_bytes, argv, null, cb);
}

/// Like harf_term_new, starting the child in `cwd` (NULL: a shell starts in $HOME, a program where the app is; a directory that
/// cannot be entered means "/").
export fn harf_term_new_in(
    cols: u16,
    rows: u16,
    scrollback_bytes: usize,
    argv: ?[*:null]const ?[*:0]const u8,
    cwd: ?[*:0]const u8,
    cb: ?*const HarfTermCallbacks,
) ?*HarfTerm {
    if (cols == 0 or rows == 0) return null;
    const gpa = std.heap.smp_allocator;
    const self = gpa.create(HarfTerm) catch return null;
    errdefer gpa.destroy(self);
    self.cb = if (cb) |p| p.* else .{ .ctx = null, .wake = null, .title = null, .bell = null, .exited = null, .clipboard_write = null, .notify = null, .command = null };

    var list: std.ArrayList([:0]const u8) = .empty;
    defer list.deinit(gpa);
    if (argv) |a| {
        var i: usize = 0;
        while (a[i]) |arg| : (i += 1) list.append(gpa, std.mem.span(arg)) catch return null;
    }
    self.session = term.Session.start(gpa, .{
        .cols = cols,
        .rows = rows,
        .scrollback_bytes = scrollback_bytes,
        .argv = if (argv != null and list.items.len > 0) list.items else null,
        .cwd = if (cwd) |d| std.mem.span(d) else null,
        .callbacks = .{ .ctx = self, .wake = HarfTerm.wake, .title = HarfTerm.title, .bell = HarfTerm.bell, .exited = HarfTerm.exited, .clipboard_write = HarfTerm.clipboardWrite, .notify = HarfTerm.notify, .command = HarfTerm.command },
    }) catch return null;
    return self;
}

/// The child's process id (to ask the system for its working directory).
export fn harf_term_pid(t: *HarfTerm) c_int {
    return t.session.pid();
}

/// Starts a find for `needle` (UTF-8; ASCII letters match in either case) over the screen and scrollback. Returns the number of
/// matches; an empty needle ends the find. Nothing is selected until harf_term_find_step.
export fn harf_term_find(t: *HarfTerm, needle: [*]const u8, len: usize) usize {
    return t.session.find(needle[0..len]);
}

/// Selects the next match toward older output (`older` 1) or newer (0), wrapping, scrolls to it and highlights it. Returns 1 and
/// the match's position (1-based `number` of `total`) or 0 if there are no matches.
export fn harf_term_find_step(t: *HarfTerm, older: c_int, number: *usize, total: *usize) c_int {
    const r = t.session.findStep(older != 0) orelse return 0;
    number.* = r.number;
    total.* = r.total;
    return 1;
}

/// Scrolls to the prompt `delta` prompts away (negative: older) using the shell's OSC 133 marks. Returns 1 if the key was taken
/// (even when there is no prompt that way, so the shell never sees it), 0 on the alternate screen: the key belongs to the program.
export fn harf_term_scroll_prompt(t: *HarfTerm, delta: c_int) c_int {
    return @intFromBool(t.session.scrollPrompt(delta));
}

/// Selects the output of the last finished command (the shell's OSC 133 marks); Cmd+C then copies it. Returns 1 if something was
/// selected, 0 if not (no marks, or the alternate screen: the key then belongs to the program).
export fn harf_term_select_output(t: *HarfTerm) c_int {
    return @intFromBool(t.session.selectOutput());
}

/// Selects everything, scrollback included (Cmd+A); Cmd+C then copies it.
export fn harf_term_select_all(t: *HarfTerm) void {
    t.session.selectAll();
}

/// Moves the free end of the selection (starting one at the cursor if there is none): `kind` 0 to the start of the line, 1 to its end,
/// 2 to the previous word edge, 3 to the next. Returns 1 if the key was taken, 0 on the alternate screen or while the program has the kitty
/// keyboard protocol on (the key then belongs to the program).
export fn harf_term_select_move(t: *HarfTerm, kind: c_int) c_int {
    if (kind < 0 or kind > 3) return 0;
    return @intFromBool(t.session.selectMove(@enumFromInt(kind)));
}

/// Ends the find and clears its selection.
export fn harf_term_find_end(t: *HarfTerm) void {
    t.session.findEnd();
}

/// Stops the session; the child is hung up on if it is still running. No callback runs after this returns.
export fn harf_term_free(t: *HarfTerm) void {
    t.session.deinit();
    std.heap.smp_allocator.destroy(t);
}

/// Sends bytes to the child as if typed (the view snaps back to the live screen). 0 on success.
export fn harf_term_input(t: *HarfTerm, bytes: [*]const u8, len: usize) c_int {
    t.session.typeText(bytes[0..len]) catch return -1;
    return 0;
}

/// Wheel or trackpad: `delta_rows` rows toward newer output when positive, older when negative. On the
/// alternate screen it becomes Up/Down key presses for the program. 0 on success.
export fn harf_term_scroll(t: *HarfTerm, delta_rows: i32) c_int {
    t.session.scroll(delta_rows) catch return -1;
    return 0;
}

/// Resizes the grid and the PTY; `cell_w_px` and `cell_h_px` are the pixel size of one cell. 0 on success.
export fn harf_term_resize(t: *HarfTerm, cols: u16, rows: u16, cell_w_px: u32, cell_h_px: u32) c_int {
    t.session.resize(cols, rows, cell_w_px, cell_h_px) catch return -1;
    return 0;
}

/// Copies the UTF-8 text of visible row `row` (trailing blanks trimmed, no NUL) into `out`.
/// Returns the number of bytes written, cut off at `cap`.
export fn harf_term_row_text(t: *HarfTerm, row: u16, out: [*]u8, cap: usize) usize {
    const g = t.session.lock();
    defer t.session.unlock();
    return g.rowText(row, out[0..cap]).len;
}

/// Sends a key event. `keycode` is the macOS virtual keycode, `mods` the HARF_MOD_* bits, `utf8` the
/// text AppKit produced (may be empty), `action` 0 press, 1 release, 2 repeat. Returns 1 if the key was
/// handled (and its bytes queued), 0 if it is a text key that the caller should send with
/// harf_term_input, -1 on error.
export fn harf_term_key(t: *HarfTerm, keycode: u16, mods: u32, utf8: ?[*]const u8, len: usize, unshifted: u32, action: c_int) c_int {
    const act: vt.KeyAction = switch (action) {
        1 => .release,
        2 => .repeat,
        else => .press,
    };
    const text: []const u8 = if (utf8) |p| p[0..len] else "";
    const handled = t.session.key(keycode, mods, text, std.math.cast(u21, unshifted) orelse 0, act) catch return -1;
    return if (handled) 1 else 0;
}

/// Whether pasting `utf8` should be confirmed first: 0 = no, bit 1 = it would run lines (it holds a line break and the program has
/// not asked for bracketed paste), bit 2 = it is very large (over 100,000 bytes).
export fn harf_term_paste_check(t: *HarfTerm, utf8: [*]const u8, len: usize) c_int {
    const r = t.session.pasteRisk(utf8[0..len]);
    return @as(c_int, @intFromBool(r.runs_lines)) | (@as(c_int, @intFromBool(r.large)) << 1);
}

/// Pastes text, framed for the terminal's paste mode. 0 on success.
export fn harf_term_paste(t: *HarfTerm, utf8: [*]const u8, len: usize) c_int {
    t.session.paste(utf8[0..len]) catch return -1;
    return 0;
}

/// Copies the window title the child set into `out` (no NUL). Returns bytes written, cut off at `cap`.
export fn harf_term_title(t: *HarfTerm, out: [*]u8, cap: usize) usize {
    var buf: [512]u8 = undefined;
    const title = t.session.title(&buf);
    const n = @min(title.len, cap);
    @memcpy(out[0..n], title[0..n]);
    return n;
}

pub const HarfCellMetrics = extern struct { cell_w: f32, cell_h: f32, ascent: f32 };

/// A font at `size_px` device pixels plus its glyph cache. NULL if Menlo is unavailable.
export fn harf_painter_new(size_px: f32) ?*draw.Painter {
    return draw.Painter.init(std.heap.smp_allocator, size_px) catch null;
}

export fn harf_painter_free(p: *draw.Painter) void {
    p.deinit();
}

export fn harf_painter_metrics(p: *draw.Painter, out: *HarfCellMetrics) void {
    const m = p.metrics();
    out.* = .{ .cell_w = m.cell_w, .cell_h = m.cell_h, .ascent = m.ascent };
}

/// Draws rows `first_row`..`last_row` (inclusive, clamped) and the cursor into a y-down CGContext in
/// device pixels; the grid's top-left is the context's origin. Takes the session lock itself.
export fn harf_term_draw(t: *HarfTerm, p: *draw.Painter, ctx: *ct.CGContext, first_row: u16, last_row: u16) void {
    const g = t.session.lock();
    defer t.session.unlock();
    p.focused = t.session.focused();
    p.drawRegion(g, ctx, first_row, last_row);
}

/// Which visible rows differ from what `harf_term_draw` last drew: `out[i]` is 1 for a row to redraw (it includes the row
/// above each changed row). Returns the grid's row count; `cap` is the size of `out`, and if it is smaller than the row count
/// the caller must redraw everything. All rows are reported before the first draw and after a change of grid size or colors.
export fn harf_term_dirty_rows(t: *HarfTerm, p: *draw.Painter, out: [*]u8, cap: usize) usize {
    const g = t.session.lock();
    defer t.session.unlock();
    p.focused = t.session.focused();
    var flags: [256]bool = undefined;
    const n = p.dirtyRows(g, flags[0..@min(cap, flags.len)]);
    for (0..@min(cap, flags.len, n)) |i| out[i] = @intFromBool(flags[i]);
    return if (n > flags.len) 0xFFFF else n; // a grid taller than the buffer: say "too many" so the caller redraws everything
}

/// A mouse event at the pixel (`x_px`, `y_px`) of the grid (device pixels, origin at its top-left).
/// action: 0 press, 1 release, 2 motion. button: 0 none (motion), 1 left, 2 right, 3 middle. `mods` uses
/// the HARF_MOD_* bits. Returns 1 if the program has mouse tracking on and took the event, 0 if the
/// caller keeps it (a selection gesture; Shift always keeps it), -1 on error.
export fn harf_term_mouse(t: *HarfTerm, p: *draw.Painter, action: c_int, button: c_int, mods: u32, x_px: f64, y_px: f64) c_int {
    if (action == 2 and button == 0) {
        // Plain motion costs nothing unless a program asked to hear it, and its position only matters to a
        // program that tracks the mouse (a wheel event carries it). That includes the Shift-flagged,
        // position-only call the view makes for every wheel event.
        const g = t.session.lock();
        defer t.session.unlock();
        if (!g.mouseTracking()) return 0;
    }
    var col: u16 = 0;
    var row: u16 = 0;
    {
        const g = t.session.lock();
        defer t.session.unlock();
        const cell = p.cellAt(g, x_px, y_px);
        col = cell.col;
        row = cell.row;
    }
    const m = p.metrics();
    const cw: u32 = @max(1, @as(u32, @intFromFloat(m.cell_w)));
    const ch: u32 = @max(1, @as(u32, @intFromFloat(m.cell_h)));
    t.session.setPointer(col, row);
    t.session.setCellPx(cw, ch);
    if (mods & 1 != 0) return 0; // Shift selects, even while a program tracks the mouse
    const act: vt.Terminal.MouseAction = switch (action) {
        1 => .release,
        2 => .motion,
        else => .press,
    };
    const btn: ?vt.Terminal.MouseButton = switch (button) {
        1 => .left,
        2 => .right,
        3 => .middle,
        else => null,
    };
    const took = t.session.mouse(act, btn, mods, col, row, cw, ch) catch return -1;
    return if (took) 1 else 0;
}

/// The window gained (1) or lost (0) focus. The cursor is drawn hollow while unfocused, and a program that
/// enabled focus events is told. 0 on success.
export fn harf_term_focus(t: *HarfTerm, focused: c_int) c_int {
    t.session.setFocus(focused != 0) catch return -1;
    return 0;
}

/// A selection gesture with the left button, at a pixel of the grid. phase: 0 press, 1 drag, 2 release.
/// `click_count` is the click count of the event (1 click, 2 word, 3 line). `mods` uses `HARF_MOD_*`;
/// Shift on press continues an existing selection. Use it when `harf_term_mouse` returned 0. 0 on success.
export fn harf_term_selection_event(t: *HarfTerm, p: *draw.Painter, phase: c_int, click_count: c_int, mods: u32, x_px: f64, y_px: f64) c_int {
    var col: u16 = 0;
    var row: u16 = 0;
    {
        const g = t.session.lock();
        defer t.session.unlock();
        const cell = p.cellAt(g, x_px, y_px);
        col = cell.col;
        row = cell.row;
    }
    t.session.selection(@intCast(@max(0, @min(2, phase))), @intCast(@max(1, @min(255, click_count))), mods, col, row);
    return 0;
}

/// The OSC 8 hyperlink under a pixel of the grid (device pixels, origin at its top-left): copies its URI (no NUL) into `out`
/// and returns its length, or 0 if there is no link there or the URI does not fit `cap` (a cut-off URL is never returned).
export fn harf_term_hyperlink_at(t: *HarfTerm, p: *draw.Painter, x_px: f64, y_px: f64, out: [*]u8, cap: usize) usize {
    const g = t.session.lock();
    defer t.session.unlock();
    const cell = p.cellAt(g, x_px, y_px);
    const uri = g.hyperlinkAt(cell.col, cell.row, out[0..cap]);
    return uri.len;
}

/// The file path under a pixel of the grid (device pixels, origin at its top-left): copies it (no NUL) into `out` and returns its
/// length, or 0 if there is none or it does not fit `cap` (a cut-off path is never returned). `*line` and `*col` get the `:line`
/// and `:col` that followed it (0 when absent). Whether the file exists is the caller's to check.
export fn harf_term_path_at(t: *HarfTerm, p: *draw.Painter, x_px: f64, y_px: f64, out: [*]u8, cap: usize, line: *u32, col: *u32) usize {
    const g = t.session.lock();
    defer t.session.unlock();
    const cell = p.cellAt(g, x_px, y_px);
    const r = g.pathAt(cell.col, cell.row, out[0..cap]) orelse return 0;
    line.* = r.line;
    col.* = r.col;
    return r.len;
}

/// The plain http or https URL under a pixel of the grid: copies it (no NUL) into `out` and returns its length, or 0 if there is
/// none or it does not fit `cap`.
export fn harf_term_url_at(t: *HarfTerm, p: *draw.Painter, x_px: f64, y_px: f64, out: [*]u8, cap: usize) usize {
    const g = t.session.lock();
    defer t.session.unlock();
    const cell = p.cellAt(g, x_px, y_px);
    return g.urlAt(cell.col, cell.row, out[0..cap]) orelse 0;
}

/// The link under a pixel of the grid and the cells it covers: returns 0 for none, 1 an OSC 8 hyperlink, 2 a plain URL, 3 a file path
/// (with its `:line:col`); `*row`, `*lo` and `*hi` get its row and first and last column. Whether it can be opened, or the file
/// exists, is the caller's to check.
export fn harf_term_link_span_at(t: *HarfTerm, p: *draw.Painter, x_px: f64, y_px: f64, row: *u16, lo: *u16, hi: *u16) c_int {
    const g = t.session.lock();
    defer t.session.unlock();
    const cell = p.cellAt(g, x_px, y_px);
    const s = g.linkSpanAt(cell.col, cell.row) orelse return 0;
    row.* = s.row;
    lo.* = s.lo;
    hi.* = s.hi;
    return switch (s.kind) {
        .hyperlink => 1,
        .url => 2,
        .path => 3,
    };
}

/// Tints the cells `lo` to `hi` of visible row `row` the next time that row is drawn (the caller invalidates the row). One
/// highlight at a time; `harf_painter_clear_highlight` removes it.
export fn harf_painter_set_highlight(p: *draw.Painter, row: u16, lo: u16, hi: u16, r: u8, g: u8, b: u8) void {
    p.highlight = .{ .row = row, .lo = lo, .hi = @max(lo, hi), .color = .{ .r = r, .g = g, .b = b } };
}

export fn harf_painter_clear_highlight(p: *draw.Painter) void {
    p.highlight = null;
}

/// Clear the screen (and the scrollback if `scrollback` is not 0), then type Ctrl+L so a shell redraws its prompt. On the
/// alternate screen nothing happens and it returns 0 (the key is the program's); otherwise 1.
export fn harf_term_clear(t: *HarfTerm, scrollback: c_int) c_int {
    return @intFromBool(t.session.clearScreen(scrollback != 0));
}

/// Whether a program may write the clipboard with OSC 52 (1 yes, 0 no). Reading it is never allowed.
export fn harf_term_set_clipboard_write(t: *HarfTerm, allow: c_int) void {
    t.session.setClipboardWrite(allow != 0);
}

/// The selected text as UTF-8 in logical order (soft wraps joined, trailing blanks trimmed), or NULL if
/// nothing is selected. `*len` receives its length. Free it with `harf_free`.
export fn harf_term_selection_text(t: *HarfTerm, len: *usize) ?[*]u8 {
    const text = (t.session.selectionText(std.heap.c_allocator) catch return null) orelse return null;
    len.* = text.len;
    if (text.len == 0) {
        std.heap.c_allocator.free(text);
        return null;
    }
    return text.ptr;
}

/// Frees what `harf_term_selection_text` returned.
export fn harf_free(p: ?*anyopaque) void {
    std.c.free(p);
}

export fn harf_term_clear_selection(t: *HarfTerm) void {
    t.session.clearSelection();
}

/// The terminal's current default background (a program's OSC 11 changes it), as red, green, blue bytes.
/// The view fills the margins around the grid with it.
export fn harf_term_default_bg(t: *HarfTerm, rgb: *[3]u8) void {
    const g = t.session.lock();
    defer t.session.unlock();
    _ = g.update(); // pick up a color set since the last draw
    const bg = g.colors().bg;
    rgb.* = .{ bg.r, bg.g, bg.b };
}

/// The terminal's real grid size right now. A program can change it (DECCOLM, 132 columns) without the view knowing.
export fn harf_term_grid(t: *HarfTerm, cols: *u16, rows: *u16) void {
    const g = t.session.lock();
    defer t.session.unlock();
    const sz = g.size();
    cols.* = sz.cols;
    rows.* = sz.rows;
}

/// Re-arms the `wake` callback; call before reading the grid for a redraw.
export fn harf_term_wake_handled(t: *HarfTerm) void {
    t.session.wakeHandled();
}

/// The child's exit code once it has ended and its output is parsed, -1 while it runs.
export fn harf_term_exit_status(t: *HarfTerm) c_int {
    return if (t.session.exitStatus()) |s| s else -1;
}

const TestExit = struct {
    status: std.atomic.Value(c_int) = .init(-1),
    fn onExited(ctx: ?*anyopaque, status: c_int) callconv(.c) void {
        const self: *TestExit = @ptrCast(@alignCast(ctx.?));
        self.status.store(status, .release);
    }
};

test "harf_term round trip through the C ABI" {
    var state: TestExit = .{};
    const cb: HarfTermCallbacks = .{ .ctx = &state, .wake = null, .title = null, .bell = null, .exited = TestExit.onExited, .clipboard_write = null, .notify = null, .command = null };
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "printf hi" };
    const t = harf_term_new(80, 24, 1 << 20, &argv, &cb) orelse return error.TermNotCreated;
    defer harf_term_free(t);
    var waited: u32 = 0;
    while (harf_term_exit_status(t) != 0 and waited < 10_000) : (waited += 5) {
        const ts: std.c.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    try std.testing.expectEqual(@as(c_int, 0), harf_term_exit_status(t));
    try std.testing.expectEqual(@as(c_int, 0), state.status.load(.acquire));
    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), harf_term_row_text(t, 0, &buf, buf.len));
    try std.testing.expectEqualStrings("hi", buf[0..2]);
}

test "harf_term_key and harf_term_paste" {
    const argv = [_:null]?[*:0]const u8{ "/bin/cat", null };
    const t = harf_term_new(80, 24, 1 << 20, &argv, null) orelse return error.TermNotCreated;
    defer harf_term_free(t);
    try std.testing.expectEqual(@as(c_int, 1), harf_term_key(t, 126, 0, null, 0, 0, 0)); // up arrow
    try std.testing.expectEqual(@as(c_int, 1), harf_term_key(t, 56, 1, null, 0, 0, 0)); // shift alone
    try std.testing.expectEqual(@as(c_int, 0), harf_term_key(t, 200, 0, "x", 1, 0, 0)); // unknown key: text path
    try std.testing.expectEqual(@as(c_int, 0), harf_term_paste(t, "hi", 2));
}

test "harf_term_mouse: tracking takes the event, Shift keeps it for selection" {
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "printf '\\033[?1000h\\033[?1006h'; sleep 5", null };
    const t = harf_term_new(80, 24, 1 << 20, &argv, null) orelse return error.TermNotCreated;
    defer harf_term_free(t);
    const p = harf_painter_new(28) orelse return error.NoPainter;
    defer harf_painter_free(p);
    var waited: u32 = 0;
    while (waited < 10_000) : (waited += 5) {
        const g = t.session.lock();
        const on = g.mouseTracking();
        t.session.unlock();
        if (on) break;
        const ts: std.c.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    try std.testing.expectEqual(@as(c_int, 0), harf_term_mouse(t, p, 0, 1, 1, 40, 40)); // Shift: not for the program
    try std.testing.expectEqual(@as(usize, 0), t.session.pendingInput());
    try std.testing.expectEqual(@as(c_int, 1), harf_term_mouse(t, p, 0, 1, 0, 40, 40)); // the program takes it
}

test "harf_term_paste_check returns the reason bits" {
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "sleep 5", null };
    const t = harf_term_new(20, 3, 1 << 20, &argv, null) orelse return error.TermNotCreated;
    defer harf_term_free(t);
    try std.testing.expectEqual(@as(c_int, 0), harf_term_paste_check(t, "hi", 2));
    try std.testing.expectEqual(@as(c_int, 1), harf_term_paste_check(t, "a\nb", 3)); // would run lines
    const big = try std.testing.allocator.alloc(u8, 100_001);
    defer std.testing.allocator.free(big);
    @memset(big, 'a');
    try std.testing.expectEqual(@as(c_int, 2), harf_term_paste_check(t, big.ptr, big.len));
    big[5] = '\n';
    try std.testing.expectEqual(@as(c_int, 3), harf_term_paste_check(t, big.ptr, big.len));
}

test "harf_term_draw takes the cursor's look from the focus flag" {
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "sleep 5", null };
    const t = harf_term_new(20, 3, 1 << 20, &argv, null) orelse return error.TermNotCreated;
    defer harf_term_free(t);
    const p = harf_painter_new(28) orelse return error.NoPainter;
    defer harf_painter_free(p);
    var m: HarfCellMetrics = undefined;
    harf_painter_metrics(p, &m);
    const w: usize = @intFromFloat(m.cell_w * 20);
    const h: usize = @intFromFloat(m.cell_h * 3);
    const data = try std.testing.allocator.alloc(u8, w * h * 4);
    defer std.testing.allocator.free(data);
    const space = ct.CGColorSpaceCreateDeviceRGB() orelse return error.NoColorSpace;
    defer ct.CGColorSpaceRelease(space);
    const ctx = ct.CGBitmapContextCreate(data.ptr, w, h, 8, w * 4, space, 2 | (2 << 12)) orelse return error.NoContext;
    defer ct.CGContextRelease(ctx);
    ct.CGContextTranslateCTM(ctx, 0, @floatFromInt(h));
    ct.CGContextScaleCTM(ctx, 1, -1);
    const mid = (@as(usize, @intFromFloat(m.cell_h)) / 2) * w * 4 + (@as(usize, @intFromFloat(m.cell_w)) / 2) * 4;
    _ = harf_term_focus(t, 1);
    harf_term_draw(t, p, ctx, 0, 2);
    try std.testing.expect(data[mid + 2] > 200); // the focused cursor is a solid block
    _ = harf_term_focus(t, 0);
    harf_term_draw(t, p, ctx, 0, 2);
    try std.testing.expect(data[mid + 2] < 60); // unfocused: hollow, the middle is background
}

test "selection through the C ABI: a click on a shaped Arabic row selects the letter under it" {
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "printf '\\xd9\\x85\\xd8\\xb1\\xd8\\xad\\xd8\\xa8\\xd8\\xa7'; sleep 5", null };
    const t = harf_term_new(20, 3, 1 << 20, &argv, null) orelse return error.TermNotCreated;
    defer harf_term_free(t);
    const p = harf_painter_new(28) orelse return error.NoPainter;
    defer harf_painter_free(p);
    var buf: [64]u8 = undefined;
    var waited: u32 = 0;
    while (harf_term_row_text(t, 0, &buf, buf.len) < 10 and waited < 10_000) : (waited += 5) {
        const ts: std.c.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    // The pixel x range that maps to columns 1 and 2 of the shaped row, from the painter's own hit-test.
    var x1: f64 = 0;
    var x2: f64 = 0;
    {
        const g = t.session.lock();
        defer t.session.unlock();
        const m = p.metrics();
        var px: f64 = 0;
        while (px < m.cell_w * 5) : (px += 1) {
            const col = p.cellAt(g, px, m.cell_h * 0.5).col;
            if (col == 1 and x1 == 0) x1 = px;
            if (col == 2 and x2 == 0) x2 = px;
        }
    }
    try std.testing.expect(x1 > 0 and x2 > 0);
    try std.testing.expectEqual(@as(c_int, 0), harf_term_selection_event(t, p, 0, 1, 0, x1, 5)); // press on the second letter
    try std.testing.expectEqual(@as(c_int, 0), harf_term_selection_event(t, p, 1, 1, 0, x2, 5)); // drag to the third
    try std.testing.expectEqual(@as(c_int, 0), harf_term_selection_event(t, p, 2, 1, 0, x2, 5));
    var len: usize = 0;
    const text = harf_term_selection_text(t, &len) orelse return error.NoSelection;
    defer harf_free(text);
    // logical letters 1 and 2 (U+0631 U+062D), wherever they are drawn
    try std.testing.expectEqualStrings("\u{631}\u{62D}", text[0..len]);
    // Shift+click on letter 3 (U+0628) extends the selection to letters 1..3
    var x3: f64 = 0;
    {
        const g = t.session.lock();
        defer t.session.unlock();
        const m = p.metrics();
        var px: f64 = 0;
        while (px < m.cell_w * 5) : (px += 1) {
            if (p.cellAt(g, px, m.cell_h * 0.5).col == 3) {
                x3 = px;
                break;
            }
        }
    }
    try std.testing.expect(x3 > 0);
    try std.testing.expectEqual(@as(c_int, 0), harf_term_selection_event(t, p, 0, 1, 1, x3, 5));
    try std.testing.expectEqual(@as(c_int, 0), harf_term_selection_event(t, p, 2, 1, 1, x3, 5));
    var ext_len: usize = 0;
    const ext = harf_term_selection_text(t, &ext_len) orelse return error.NoSelection;
    defer harf_free(ext);
    try std.testing.expectEqualStrings("\u{631}\u{62D}\u{628}", ext[0..ext_len]);
    harf_term_clear_selection(t);
    try std.testing.expect(harf_term_selection_text(t, &len) == null);
}

test "selection through the C ABI: the second cell of lam-alef is its own target" {
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "printf '\\xd9\\x84\\xd8\\xa7 \\xd9\\x85'; sleep 5", null }; // lam, alef, a blank, meem
    const t = harf_term_new(20, 3, 1 << 20, &argv, null) orelse return error.TermNotCreated;
    defer harf_term_free(t);
    const p = harf_painter_new(28) orelse return error.NoPainter;
    defer harf_painter_free(p);
    var buf: [64]u8 = undefined;
    var waited: u32 = 0;
    while (harf_term_row_text(t, 0, &buf, buf.len) < 7 and waited < 10_000) : (waited += 5) {
        const ts: std.c.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    // pixel x of columns 1 (the alef) and 2 (the blank) from the painter's own hit-test
    var x1: f64 = 0;
    var x2: f64 = 0;
    {
        const g = t.session.lock();
        defer t.session.unlock();
        const m = p.metrics();
        var px: f64 = 0;
        while (px < m.cell_w * 4) : (px += 1) {
            const col = p.cellAt(g, px, m.cell_h * 0.5).col;
            if (col == 1 and x1 == 0) x1 = px;
            if (col == 2 and x2 == 0) x2 = px;
        }
    }
    try std.testing.expect(x1 > 0 and x2 > 0);
    _ = harf_term_selection_event(t, p, 0, 1, 0, x1, 5);
    _ = harf_term_selection_event(t, p, 1, 1, 0, x2, 5);
    _ = harf_term_selection_event(t, p, 2, 1, 0, x2, 5);
    var len: usize = 0;
    const text = harf_term_selection_text(t, &len) orelse return error.NoSelection;
    defer harf_free(text);
    try std.testing.expectEqualStrings("\u{627}", text[0..len]); // the alef, from its own cell
}

test "harf_term_default_bg follows a program's OSC 11" {
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "printf '\\033]11;rgb:10/20/30\\007'; echo done; sleep 5", null };
    const t = harf_term_new(20, 3, 1 << 20, &argv, null) orelse return error.TermNotCreated;
    defer harf_term_free(t);
    var rgb: [3]u8 = undefined;
    harf_term_default_bg(t, &rgb);
    try std.testing.expectEqual([3]u8{ 15, 15, 18 }, rgb); // Harf's theme until the program changes it
    var buf: [64]u8 = undefined;
    var waited: u32 = 0;
    while (harf_term_row_text(t, 0, &buf, buf.len) < 4 and waited < 10_000) : (waited += 5) {
        const ts: std.c.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    harf_term_default_bg(t, &rgb);
    try std.testing.expectEqual([3]u8{ 0x10, 0x20, 0x30 }, rgb);
}

test "harf_term_mouse: a wheel's position-only call records the pointer only while a program tracks the mouse" {
    const p = harf_painter_new(28) orelse return error.NoPainter;
    defer harf_painter_free(p);
    var m: HarfCellMetrics = undefined;
    harf_painter_metrics(p, &m);
    const x: f64 = m.cell_w * 5.5; // column 5
    const y: f64 = m.cell_h * 2.5; // row 2
    // not tracking: nothing is recorded (and no hit-test is run)
    const off_argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "sleep 5", null };
    const off = harf_term_new(40, 10, 1 << 20, &off_argv, null) orelse return error.TermNotCreated;
    defer harf_term_free(off);
    _ = harf_term_mouse(off, p, 2, 0, 1, x, y); // motion, no button, Shift: position only
    try std.testing.expectEqual(@as(u32, 0), off.session.pointer.load(.acquire));
    // tracking: the pointer's cell is recorded so a wheel event carries it
    const on_argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "printf '\\033[?1000h'; sleep 5", null };
    const on = harf_term_new(40, 10, 1 << 20, &on_argv, null) orelse return error.TermNotCreated;
    defer harf_term_free(on);
    var waited: u32 = 0;
    while (waited < 10_000) : (waited += 5) {
        const g = on.session.lock();
        const tracking = g.mouseTracking();
        on.session.unlock();
        if (tracking) break;
        const ts: std.c.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    _ = harf_term_mouse(on, p, 2, 0, 1, x, y);
    try std.testing.expectEqual((@as(u32, 5) << 16) | 2, on.session.pointer.load(.acquire));
}

test "harf_term_grid reports the grid, including a program's 132-column switch" {
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "printf '\\033[?40h\\033[?3h'; echo wide; sleep 5", null };
    const t = harf_term_new(80, 24, 1 << 20, &argv, null) orelse return error.TermNotCreated;
    defer harf_term_free(t);
    var cols: u16 = 0;
    var rows: u16 = 0;
    harf_term_grid(t, &cols, &rows);
    try std.testing.expect(rows == 24 and (cols == 80 or cols == 132));
    var buf: [200]u8 = undefined;
    var waited: u32 = 0;
    while (harf_term_row_text(t, 0, &buf, buf.len) < 4 and waited < 10_000) : (waited += 5) {
        const ts: std.c.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    harf_term_grid(t, &cols, &rows);
    try std.testing.expectEqual(@as(u16, 132), cols); // the terminal followed the program, not the view
    try std.testing.expectEqual(@as(u16, 24), rows);
}

test "harf_term_new rejects zero size" {
    const cb: HarfTermCallbacks = .{ .ctx = null, .wake = null, .title = null, .bell = null, .exited = null, .clipboard_write = null, .notify = null, .command = null };
    try std.testing.expect(harf_term_new(0, 24, 1 << 20, null, &cb) == null);
    try std.testing.expect(harf_term_new(80, 0, 1 << 20, null, &cb) == null);
}

test "harf_ping returns magic" {
    try std.testing.expectEqual(@as(u32, 0x48415246), harf_ping());
}

test {
    _ = @import("shape/layout.zig");
    _ = @import("bidi/bidi.zig");
    _ = @import("vt.zig");
    _ = @import("pty.zig");
    _ = @import("term.zig");
    _ = @import("keys.zig");
    _ = @import("draw.zig");
    _ = @import("rowfacts.zig");
    _ = @import("rowlayout.zig");
    _ = @import("programs_test.zig");
    _ = @import("config.zig");
}

// ---- P4 gate measurement (HARF_BENCH=1): does drawing slow the parsing of a flood? ----

const DrawLoop = struct {
    t: *HarfTerm,
    p: *draw.Painter,
    stop: std.atomic.Value(bool) = .init(false),
    frames: std.atomic.Value(u32) = .init(0),

    fn run(self: *DrawLoop) void {
        var m: HarfCellMetrics = undefined;
        harf_painter_metrics(self.p, &m);
        const w: usize = @intFromFloat(m.cell_w * 80);
        const h: usize = @intFromFloat(m.cell_h * 24);
        const data = std.heap.smp_allocator.alloc(u8, w * h * 4) catch return;
        defer std.heap.smp_allocator.free(data);
        const space = ct.CGColorSpaceCreateDeviceRGB() orelse return;
        defer ct.CGColorSpaceRelease(space);
        const ctx = ct.CGBitmapContextCreate(data.ptr, w, h, 8, w * 4, space, 2 | (2 << 12)) orelse return;
        defer ct.CGContextRelease(ctx);
        while (!self.stop.load(.acquire)) {
            harf_term_draw(self.t, self.p, ctx, 0, 23);
            _ = self.frames.fetchAdd(1, .monotonic);
            // A frame every 8 ms (a 120 Hz display). Back to back, the drawing thread can keep the lock away from
            // the parser altogether, which is not a load the app produces: it draws at most once per wake.
            const ts: std.c.timespec = .{ .sec = 0, .nsec = 8 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
        }
    }
};

fn benchNow() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Seconds for a child to print about 22 MB (`seq 1 3000000`) and have it all parsed, with or without a thread drawing
/// the whole screen continuously. Returns the elapsed seconds and the number of frames drawn meanwhile.
const FloodResult = struct { secs: f64, frames: u32 };

fn floodSeconds(drawing: bool) !FloodResult {
    return floodCommand(drawing, "seq 1 3000000");
}

fn floodCommand(drawing: bool, cmd: [*:0]const u8) !FloodResult {
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd, null };
    const t = harf_term_new(80, 24, 1 << 20, &argv, null) orelse return error.TermNotCreated;
    defer harf_term_free(t);
    const p = harf_painter_new(28) orelse return error.NoPainter;
    defer harf_painter_free(p);
    var loop: DrawLoop = .{ .t = t, .p = p };
    const th: ?std.Thread = if (drawing) try std.Thread.spawn(.{}, DrawLoop.run, .{&loop}) else null;
    const t0 = benchNow();
    while (harf_term_exit_status(t) != 0) {
        const ts: std.c.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
        if (benchNow() - t0 > 60 * std.time.ns_per_s) break; // never hang the benchmark
    }
    const secs = @as(f64, @floatFromInt(benchNow() - t0)) / std.time.ns_per_s;
    loop.stop.store(true, .release);
    if (th) |x| x.join();
    return .{ .secs = secs, .frames = loop.frames.load(.monotonic) };
}

test "bench: flood parse throughput with and without continuous drawing (HARF_BENCH=1)" {
    if (std.c.getenv("HARF_BENCH") == null) return error.SkipZigTest;
    std.debug.print("\n", .{});
    for (0..3) |_| {
        const quiet = try floodSeconds(false);
        const busy = try floodSeconds(true);
        std.debug.print("BENCH flood 22 MB: no drawing {d:.2} s ({d:.0} MB/s) | drawing {d:.2} s ({d:.0} MB/s, {d} frames, {d:.0} frames/s) | slowdown {d:.2}x\n", .{
            quiet.secs, 22.0 / quiet.secs, busy.secs, 22.0 / busy.secs, busy.frames, @as(f64, @floatFromInt(busy.frames)) / busy.secs, busy.secs / quiet.secs,
        });
    }
}

test "bench: which loads are slow (HARF_BENCH=1)" {
    if (std.c.getenv("HARF_BENCH") == null) return error.SkipZigTest;
    const Case = struct { name: []const u8, cmd: [*:0]const u8, mb: f64 };
    const cases = [_]Case{
        .{ .name = "seq 1 3000000 (a line per write)", .cmd = "seq 1 3000000", .mb = 22.9 },
        .{ .name = "yes | head -c 100MB (full lines, block writes)", .cmd = "yes 'flood flood flood flood flood flood flood flood flood flood flood flood flood' | head -c 100000000", .mb = 100.0 },
        .{ .name = "head -c 100MB /dev/zero | tr (no newlines)", .cmd = "head -c 100000000 /dev/zero | tr '\\\\0' 'x'", .mb = 100.0 },
        .{ .name = "yes | head -c 100MB | cat (a pipe stage)", .cmd = "yes 'abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij abcdefghij' | head -c 100000000 | cat", .mb = 100.0 },
    };
    std.debug.print("\n", .{});
    for (cases) |cs| {
        const r = try floodCommand(false, cs.cmd);
        std.debug.print("BENCH {s}: {d:.2} s = {d:.1} MB/s\n", .{ cs.name, r.secs, cs.mb / r.secs });
    }
}

test "harf_term_dirty_rows reports changed rows, and a focus change dirties the cursor's row" {
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "printf 'one\\r\\ntwo\\r\\nthree'; sleep 5", null };
    const t = harf_term_new(20, 6, 1 << 20, &argv, null) orelse return error.TermNotCreated;
    defer harf_term_free(t);
    const p = harf_painter_new(28) orelse return error.NoPainter;
    defer harf_painter_free(p);
    var m: HarfCellMetrics = undefined;
    harf_painter_metrics(p, &m);
    const w: usize = @intFromFloat(m.cell_w * 20);
    const h: usize = @intFromFloat(m.cell_h * 6);
    const data = try std.testing.allocator.alloc(u8, w * h * 4);
    defer std.testing.allocator.free(data);
    const space = ct.CGColorSpaceCreateDeviceRGB() orelse return error.NoColorSpace;
    defer ct.CGColorSpaceRelease(space);
    const ctx = ct.CGBitmapContextCreate(data.ptr, w, h, 8, w * 4, space, 2 | (2 << 12)) orelse return error.NoContext;
    defer ct.CGContextRelease(ctx);
    var buf: [200]u8 = undefined;
    var waited: u32 = 0;
    while (harf_term_row_text(t, 2, &buf, buf.len) < 5 and waited < 10_000) : (waited += 5) {
        const ts: std.c.timespec = .{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    var out: [6]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 6), harf_term_dirty_rows(t, p, &out, out.len));
    try std.testing.expectEqualSlices(u8, &.{ 1, 1, 1, 1, 1, 1 }, &out); // nothing drawn yet
    harf_term_draw(t, p, ctx, 0, 5);
    _ = harf_term_dirty_rows(t, p, &out, out.len);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0 }, &out); // everything is as drawn
    _ = harf_term_focus(t, 0);
    _ = harf_term_dirty_rows(t, p, &out, out.len);
    try std.testing.expectEqual(@as(u8, 1), out[2]); // the cursor sits at the end of row 2: its look changed with focus
    try std.testing.expectEqual(@as(u8, 0), out[5]);
    var tiny: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 6), harf_term_dirty_rows(t, p, &tiny, tiny.len)); // a buffer too small to answer: the caller sees 6 > 2
}

// ---- Configuration (Phase 6): the file, themes and key bindings; the shell applies them ----

/// Colors a theme sets. `palette_set` has bit i set when ANSI color i is given; the other colors stay the terminal's own.
pub const HarfTheme = extern struct {
    fg: [3]u8,
    bg: [3]u8,
    has_cursor: u8,
    cursor: [3]u8,
    palette_set: u16,
    palette: [16][3]u8,
};

/// One key binding. `mods` uses the HARF_MOD_* bits; `key` is a lowercase character or a name (`left`, `return`, `f5`);
/// `action` is the action's name (`new_tab`, `send`, ...); `arg` is the tab number as text for `goto_tab`, the bytes for `send`.
pub const HarfKeybind = extern struct {
    mods: u8,
    arg_len: u8,
    key: [16]u8,
    action: [24]u8,
    arg: [64]u8,
};

fn defaultConfigDir(buf: []u8) ?[]const u8 {
    if (std.c.getenv("XDG_CONFIG_HOME")) |x| {
        const v = std.mem.span(x);
        if (v.len > 0) return std.fmt.bufPrint(buf, "{s}/harf", .{v}) catch null;
    }
    const home = std.c.getenv("HOME") orelse return null;
    return std.fmt.bufPrint(buf, "{s}/.config/harf", .{std.mem.span(home)}) catch null;
}

/// Reads the configuration in `dir` (a missing directory or file is an empty configuration), or in the default place
/// (`$XDG_CONFIG_HOME/harf`, else `~/.config/harf`) when `dir` is NULL. Bad lines are warnings, never failures. Free with
/// harf_config_free.
export fn harf_config_load(dir: ?[*:0]const u8) ?*config.Config {
    var buf: [1024]u8 = undefined;
    const path = if (dir) |d| std.mem.span(d) else defaultConfigDir(&buf) orelse return null;
    return config.load(std.heap.smp_allocator, path) catch null;
}

export fn harf_config_free(cfg: *config.Config) void {
    cfg.deinit();
}

/// The directory the configuration was read from (NUL-terminated, valid until harf_config_free).
export fn harf_config_dir(cfg: *config.Config) [*:0]const u8 {
    return cfg.dir.ptr;
}

/// The text of a commented configuration file with every setting at its default (static, NUL-terminated).
export fn harf_config_template() [*:0]const u8 {
    return config.template;
}

export fn harf_config_font_family(cfg: *config.Config) [*:0]const u8 {
    return cfg.font_family.ptr;
}

export fn harf_config_font_size(cfg: *config.Config) f32 {
    return cfg.font_size;
}

export fn harf_config_window_width(cfg: *config.Config) f32 {
    return cfg.window_width;
}

export fn harf_config_window_height(cfg: *config.Config) f32 {
    return cfg.window_height;
}

export fn harf_config_scrollback_bytes(cfg: *config.Config) usize {
    return cfg.scrollback_bytes;
}

export fn harf_config_clipboard_write(cfg: *config.Config) c_int {
    return @intFromBool(cfg.clipboard_write);
}

/// 0 unfocused, 1 always, 2 off.
export fn harf_config_notifications(cfg: *config.Config) c_int {
    return @intFromEnum(cfg.notifications);
}

/// The `editor` template (NUL-terminated, empty when none is set).
export fn harf_config_editor(cfg: *config.Config) [*:0]const u8 {
    return cfg.editor.ptr;
}

/// Sets `key = value` in the config file at `path` (created if missing; an existing uncommented line is rewritten in place, comments
/// are kept). 0 on success, -1 if the value holds a line break or the file cannot be written.
export fn harf_config_set_key(path: [*:0]const u8, key: [*:0]const u8, value: [*:0]const u8) c_int {
    config.setKeyInFile(std.heap.smp_allocator, std.mem.span(path), std.mem.span(key), std.mem.span(value)) catch return -1;
    return 0;
}

/// 1 on, 0 off.
export fn harf_config_paste_guard(cfg: *config.Config) c_int {
    return @intFromBool(cfg.paste_guard);
}

/// 0 auto, 1 off.
export fn harf_config_shell_integration(cfg: *config.Config) c_int {
    return @intFromEnum(cfg.shell_integration);
}

var shell_integration_buf: [1024:0]u8 = undefined;

/// Where the shell integration shim lives (a directory holding `zsh/.zshenv`); a login zsh started afterwards gets it. NULL turns
/// it off. The text is copied; one that does not fit is the same as NULL.
export fn harf_set_shell_integration_dir(dir: ?[*:0]const u8) void {
    const s = std.mem.span(dir orelse {
        pty.default_shell_integration_dir = null;
        return;
    });
    if (s.len >= shell_integration_buf.len) {
        pty.default_shell_integration_dir = null;
        return;
    }
    @memcpy(shell_integration_buf[0..s.len], s);
    shell_integration_buf[s.len] = 0;
    pty.default_shell_integration_dir = shell_integration_buf[0..s.len :0];
}

/// The theme for a dark (1) or light (0) system appearance.
export fn harf_config_theme(cfg: *config.Config, dark: c_int, out: *HarfTheme) void {
    const t = cfg.theme(dark != 0);
    out.* = std.mem.zeroes(HarfTheme);
    out.fg = .{ t.fg.r, t.fg.g, t.fg.b };
    out.bg = .{ t.bg.r, t.bg.g, t.bg.b };
    if (t.cursor) |c| {
        out.has_cursor = 1;
        out.cursor = .{ c.r, c.g, c.b };
    }
    for (t.palette, 0..) |p, i| if (p) |c| {
        out.palette_set |= @as(u16, 1) << @intCast(i);
        out.palette[i] = .{ c.r, c.g, c.b };
    };
}

export fn harf_config_keybind_count(cfg: *config.Config) usize {
    return cfg.keybinds.items.len;
}

/// Key binding `i` (0 on success, -1 if there is none). Later bindings replace earlier ones for the same trigger.
export fn harf_config_keybind(cfg: *config.Config, i: usize, out: *HarfKeybind) c_int {
    if (i >= cfg.keybinds.items.len) return -1;
    const k = cfg.keybinds.items[i];
    out.* = std.mem.zeroes(HarfKeybind);
    out.mods = k.mods;
    out.arg_len = @intCast(@min(k.arg.len, out.arg.len));
    @memcpy(out.arg[0..out.arg_len], k.arg[0..out.arg_len]);
    const key = k.key[0..@min(k.key.len, out.key.len - 1)];
    @memcpy(out.key[0..key.len], key);
    const name = @tagName(k.action);
    @memcpy(out.action[0..name.len], name);
    return 0;
}

export fn harf_config_warning_count(cfg: *config.Config) usize {
    return cfg.warnings.items.len;
}

/// Warning `i` (NUL-terminated, valid until harf_config_free), or NULL.
export fn harf_config_warning(cfg: *config.Config, i: usize) ?[*:0]const u8 {
    if (i >= cfg.warnings.items.len) return null;
    return cfg.warnings.items[i].ptr;
}

/// A theme's colors for this session: default foreground and background, cursor color, and the ANSI colors it sets. 0 = ok.
export fn harf_term_set_theme(t: *HarfTerm, theme: *const HarfTheme) c_int {
    var ansi: [16]?vt.Rgb = @splat(null);
    for (0..16) |i| {
        if (theme.palette_set & (@as(u16, 1) << @intCast(i)) != 0) ansi[i] = .{ .r = theme.palette[i][0], .g = theme.palette[i][1], .b = theme.palette[i][2] };
    }
    const cursor_color: ?vt.Rgb = if (theme.has_cursor != 0) .{ .r = theme.cursor[0], .g = theme.cursor[1], .b = theme.cursor[2] } else null;
    t.session.setTheme(
        .{ .r = theme.fg[0], .g = theme.fg[1], .b = theme.fg[2] },
        .{ .r = theme.bg[0], .g = theme.bg[1], .b = theme.bg[2] },
        cursor_color,
        ansi,
    );
    return 0;
}

/// The system appearance, dark (1) or light (0): what `CSI ? 996 n` answers, and what a program that enabled mode 2031 is told
/// when it changes.
export fn harf_term_set_scheme(t: *HarfTerm, dark: c_int) void {
    t.session.setScheme(dark != 0);
}

/// Like harf_painter_new in the font family `family` (UTF-8, NUL-terminated). NULL if the family is not installed or is not
/// monospaced.
export fn harf_painter_new_font(family: [*:0]const u8, size_px: f32) ?*draw.Painter {
    return draw.Painter.initFamily(std.heap.smp_allocator, std.mem.span(family), size_px) catch null;
}
