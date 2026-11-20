//! A terminal session: a child on a PTY, a grid fed from its output, one I/O thread.
//! The I/O thread owns reading, parsing and reaping; everything else goes through `lock`/`unlock`.
const std = @import("std");
const vt = @import("vt.zig");
const pty = @import("pty.zig");
const keys = @import("keys.zig");

const c = std.c;

/// Events from the session. All run on the I/O thread, so they must be quick and must not call
/// back into the session except `wakeHandled`.
pub const Callbacks = struct {
    ctx: ?*anyopaque = null,
    /// New output was parsed. Called once, then not again until `wakeHandled`.
    wake: ?*const fn (ctx: ?*anyopaque) void = null,
    title: ?*const fn (ctx: ?*anyopaque) void = null,
    bell: ?*const fn (ctx: ?*anyopaque) void = null,
    /// The child ended and all its output has been parsed.
    exited: ?*const fn (ctx: ?*anyopaque, status: u8) void = null,
    /// A program wrote text to the clipboard (OSC 52) and the policy allowed it. The text is borrowed for the call.
    clipboard_write: ?*const fn (ctx: ?*anyopaque, text: []const u8) void = null,
    /// A program asked for a desktop notification (OSC 9, OSC 777). Untrusted text, borrowed for the call.
    notify: ?*const fn (ctx: ?*anyopaque, title: []const u8, body: []const u8) void = null,
    /// A command started running (`running`, OSC 133 `C`) or ended (`D`, or the next prompt): only when that changes, never
    /// per sequence. `exit_code` is set at an end the shell reported one for; `duration_ms` is the run time at an end.
    command: ?*const fn (ctx: ?*anyopaque, running: bool, exit_code: ?i32, duration_ms: u32) void = null,
};

pub const Options = struct {
    cols: u16 = 80,
    rows: u16 = 24,
    scrollback_bytes: usize = 1 << 20,
    /// The program to run (`argv[0]` is its path). Null runs the user's login shell.
    argv: ?[]const [:0]const u8 = null,
    callbacks: Callbacks = .{},
    /// How long a synchronized-output hold (mode 2026) may last before the display is let go anyway.
    hold_deadline_ms: u32 = 1000,
    /// May a program write the clipboard (OSC 52)?
    allow_clipboard_write: bool = true,
    /// The directory the child starts in (a shell: `$HOME` when null). A directory that cannot be entered means `/`.
    cwd: ?[:0]const u8 = null,
};

/// Most bytes `Session.input` queues before refusing more.
pub const max_pending_input: usize = 64 << 20;

pub const Session = struct {
    gpa: std.mem.Allocator,
    pty: pty.Pty,
    term: *vt.Terminal,
    callbacks: Callbacks,
    thread: ?std.Thread = null,
    /// Guards `term`. Held by the I/O thread while parsing and by drawing code while reading cells.
    term_lock: c.pthread_mutex_t = .{},
    /// Guards `out_queue`. Taken after `term_lock` when both are needed, never before.
    out_lock: c.pthread_mutex_t = .{},
    /// Bytes for the child (typed input, pasted text, parser replies), oldest first. Only the I/O
    /// thread writes them to the PTY, so no caller ever waits on a child that is not reading.
    out_queue: std.ArrayList(u8) = .empty,
    out_head: usize = 0,
    /// Written by `input` to wake the I/O thread; it then polls for POLLOUT.
    kick_pipe: [2]c_int = .{ -1, -1 },
    /// `deinit` writes to [1] to wake the I/O thread, which polls [0] together with the PTY.
    stop_pipe: [2]c_int = .{ -1, -1 },
    wake_pending: std.atomic.Value(bool) = .init(false),
    focus: std.atomic.Value(bool) = .init(true),
    /// True inside a render hold (synchronized output). Set by the parser callback (terminal lock held), and cleared
    /// by the I/O thread when `hold_deadline_ms` runs out.
    held: std.atomic.Value(bool) = .init(false),
    /// A command is running (OSC 133 `C` seen, no `D` yet) and when it started; touched only by the parser callback.
    cmd_running: bool = false,
    cmd_started_ms: i64 = 0,
    hold_deadline_ms: u32 = 1000,
    /// Wheel rows carried toward the next wheel event (|rows| < 3); guarded by `term_lock`.
    wheel_rows: i32 = 0,
    /// The pointer's last cell, packed (col << 16 | row).
    pointer: std.atomic.Value(u32) = .init(0),
    /// Cell size in pixels, for mouse reports (set by the first draw or `harf_term_mouse`).
    cell_px: std.atomic.Value(u32) = .init((8 << 16) | 16),
    /// -1 while the child runs, then its exit code.
    exit_status: std.atomic.Value(i32) = .init(-1),

    pub fn start(gpa: std.mem.Allocator, opts: Options) !*Session {
        const self = try gpa.create(Session);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .pty = undefined, .term = undefined, .callbacks = opts.callbacks, .hold_deadline_ms = opts.hold_deadline_ms };
        if (c.pipe(&self.stop_pipe) != 0) return error.PipeFailed;
        pty.setCloexec(self.stop_pipe[0]);
        pty.setCloexec(self.stop_pipe[1]);
        errdefer {
            _ = c.close(self.stop_pipe[0]);
            _ = c.close(self.stop_pipe[1]);
        }
        if (c.pipe(&self.kick_pipe) != 0) return error.PipeFailed;
        for (self.kick_pipe) |fd| {
            pty.setCloexec(fd);
            pty.setNonblock(fd);
        }
        errdefer {
            _ = c.close(self.kick_pipe[0]);
            _ = c.close(self.kick_pipe[1]);
        }
        errdefer self.out_queue.deinit(gpa);
        self.term = try vt.Terminal.init(gpa, .{
            .cols = opts.cols,
            .rows = opts.rows,
            .scrollback_bytes = opts.scrollback_bytes,
            .callbacks = .{ .ctx = self, .write_pty = onWritePty, .bell = onBell, .title_changed = onTitle, .render_hold = onRenderHold, .clipboard_write = onClipboard, .notify = onNotify, .command = onCommand },
            .allow_clipboard_write = opts.allow_clipboard_write,
        });
        errdefer self.term.deinit();
        self.pty = if (opts.argv) |argv|
            try pty.Pty.spawn(gpa, .{ .argv = argv, .cols = opts.cols, .rows = opts.rows, .cwd = opts.cwd })
        else
            try pty.Pty.spawnShell(gpa, opts.cols, opts.rows, opts.cwd);
        errdefer self.pty.deinit();
        self.thread = try std.Thread.spawn(.{}, ioLoop, .{self});
        return self;
    }

    /// Stops the I/O thread, hangs up on the child if it is still running, and frees everything.
    pub fn deinit(self: *Session) void {
        _ = c.write(self.stop_pipe[1], "x", 1);
        if (self.thread) |t| t.join();
        self.pty.deinit();
        self.term.deinit();
        _ = c.close(self.stop_pipe[0]);
        _ = c.close(self.stop_pipe[1]);
        _ = c.close(self.kick_pipe[0]);
        _ = c.close(self.kick_pipe[1]);
        self.out_queue.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    /// Queues bytes for the child as if typed; returns at once. The I/O thread sends them when the
    /// child is ready to read. Fails with `error.InputQueueFull` past `max_pending_input` queued bytes.
    pub fn input(self: *Session, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        {
            _ = c.pthread_mutex_lock(&self.out_lock);
            defer _ = c.pthread_mutex_unlock(&self.out_lock);
            if (self.out_queue.items.len - self.out_head + bytes.len > max_pending_input) return error.InputQueueFull;
            try self.out_queue.appendSlice(self.gpa, bytes);
        }
        _ = c.write(self.kick_pipe[1], "k", 1); // a full pipe means a wake-up is already pending
    }

    /// The user is typing (text, a key that sends bytes, or a paste): the selection goes away and the
    /// viewport returns to the live screen if it is scrolled up. Not for the parser's replies: those run
    /// with the terminal lock held.
    fn userInput(self: *Session) void {
        var changed = false;
        {
            const t = self.lock();
            defer self.unlock();
            if (t.hasSelection()) {
                t.clearSelection();
                changed = true;
            }
            if (!t.atBottom()) {
                t.scrollToBottom();
                changed = true;
            }
        }
        if (changed) self.requestWake();
    }

    /// Typed text for the child: snaps the viewport to the bottom, then queues it like `input`.
    pub fn typeText(self: *Session, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        self.userInput();
        try self.input(bytes);
    }

    /// Where the pointer last was (a cell), for wheel events, which carry a position.
    pub fn setPointer(self: *Session, col: u16, row: u16) void {
        self.pointer.store((@as(u32, col) << 16) | row, .release);
    }

    /// The window gained or lost focus: the cursor look follows, and a program that asked (mode 1004)
    /// hears `ESC [ I` or `ESC [ O`.
    pub fn setFocus(self: *Session, gained: bool) !void {
        if (self.focus.swap(gained, .acq_rel) == gained) return;
        var buf: [8]u8 = undefined;
        var n: usize = 0;
        {
            const t = self.lock();
            defer self.unlock();
            if (t.focusEvents()) n = t.encodeFocus(gained, &buf).len;
        }
        self.requestWake(); // redraw the cursor
        if (n > 0) try self.input(buf[0..n]);
    }

    /// A left-button selection gesture at a viewport cell. phase: 0 press, 1 drag, 2 release.
    /// `mods` uses `keys.Mods`: Shift on press continues an existing selection.
    pub fn selection(self: *Session, phase: u8, click_count: u8, mods: u32, col: u16, row: u16) void {
        {
            const t = self.lock();
            defer self.unlock();
            switch (phase) {
                0 => if (mods & keys.Mods.shift != 0) t.selectionExtend(col, row, click_count) else t.selectionPress(col, row, click_count),
                1 => t.selectionDrag(col, row),
                else => t.selectionRelease(),
            }
        }
        self.requestWake();
    }

    pub fn clearSelection(self: *Session) void {
        {
            const t = self.lock();
            defer self.unlock();
            t.clearSelection();
        }
        self.requestWake();
    }

    /// The selected text, or null if nothing is selected. The caller frees it with `gpa`.
    pub fn selectionText(self: *Session, gpa: std.mem.Allocator) !?[]u8 {
        const t = self.lock();
        defer self.unlock();
        return t.selectionText(gpa) catch |e| if (e == error.NoSelection) null else e;
    }

    /// True while the program is inside a synchronized-output hold. The hold ends when the program ends it, on RIS,
    /// on resize, or `hold_deadline_ms` (1 s) after it began, so a program that never ends one cannot freeze the display.
    pub fn renderHeld(self: *const Session) bool {
        return self.held.load(.acquire);
    }

    pub fn focused(self: *const Session) bool {
        return self.focus.load(.acquire);
    }

    pub fn setCellPx(self: *Session, w: u32, h: u32) void {
        if (w > 0 and h > 0) self.cell_px.store((w << 16) | (h & 0xFFFF), .release);
    }

    /// A mouse event at cell (`col`, `row`). True if the program has mouse tracking on and took the event
    /// (the bytes it asked for are queued, possibly none); false means the caller keeps it (selection).
    pub fn mouse(self: *Session, action: vt.Terminal.MouseAction, button: ?vt.Terminal.MouseButton, mods: u32, col: u16, row: u16, cell_w: u32, cell_h: u32) !bool {
        var buf: [64]u8 = undefined;
        var n: usize = 0;
        {
            const t = self.lock();
            defer self.unlock();
            if (!t.mouseTracking()) return false;
            n = t.encodeMouse(action, button, mods, col, row, cell_w, cell_h, &buf).len;
        }
        if (n > 0) try self.input(buf[0..n]);
        return true;
    }

    /// Not tracking the mouse: nothing is carried toward a program any more. Always true (for the `else if`).
    fn resetWheel(self: *Session) bool {
        self.wheel_rows = 0;
        return true;
    }

    /// The wheel or trackpad: `delta_rows` rows toward newer output when positive, older when negative.
    /// On the alternate screen the program gets that many Up or Down key presses (in its cursor key
    /// mode) unless it reset alternate scroll (mode 1007); otherwise the viewport scrolls through the scrollback. At most 64 presses per call.
    pub fn scroll(self: *Session, delta_rows: i32) !void {
        if (delta_rows == 0) return;
        var buf: [64 * 8]u8 = undefined;
        var n: usize = 0;
        {
            const t = self.lock();
            defer self.unlock();
            if (t.mouseTracking()) {
                // A wheel notch is three rows and a program treats one wheel event as about a notch, so rows
                // add up: small trackpad steps send an event only once three have gathered. A change of
                // direction drops the rows carried the other way.
                if ((delta_rows < 0) != (self.wheel_rows < 0) and self.wheel_rows != 0) self.wheel_rows = 0;
                self.wheel_rows += delta_rows;
                const notches = @divTrunc(self.wheel_rows, 3);
                self.wheel_rows -= notches * 3;
                const p = self.pointer.load(.acquire);
                const cp = self.cell_px.load(.acquire);
                const button: vt.Terminal.MouseButton = if (notches < 0) .wheel_up else .wheel_down;
                const events = @min(@abs(notches), 16);
                for (0..events) |_| n += t.encodeMouse(.press, button, 0, @intCast(p >> 16), @intCast(p & 0xFFFF), cp >> 16, cp & 0xFFFF, buf[n..]).len;
            } else if (self.resetWheel() and t.onAlternateScreen()) {
                // Mode 1007 (on by default) asks for arrows; a program that reset it gets nothing, and there is no scrollback to scroll.
                if (t.alternateScroll()) {
                    const arrow = keys.fromMac(if (delta_rows < 0) 126 else 125).?; // Up, Down
                    const presses = @min(@abs(delta_rows), 64);
                    for (0..presses) |_| n += t.encodeKey(arrow, 0, "", 0, .press, buf[n..]).len;
                }
            } else {
                t.scrollViewport(delta_rows);
            }
        }
        if (n > 0) try self.input(buf[0..n]) else self.requestWake();
    }

    /// Handles a key event the way a terminal must: function keys, and any key with Control held,
    /// are encoded for the terminal's current modes and queued. Returns false for text keys, which
    /// the caller sends as text through `input` (that keeps dead keys and Arabic layouts working),
    /// and for a key that has no encoding. `utf8` is the text the layout types for the key with
    /// Control removed, `unshifted` its character with no modifiers (0 if unknown).
    pub fn key(self: *Session, keycode: u16, mods: u32, utf8: []const u8, unshifted: u21, action: vt.KeyAction) !bool {
        if (keys.isModifierKeycode(keycode)) return true; // nothing to send
        const k = keys.fromMac(keycode) orelse return false;
        const functional = keys.isFunctional(k);
        if (!functional and mods & keys.Mods.ctrl == 0) return false;
        var buf: [128]u8 = undefined;
        var n: usize = 0;
        {
            const t = self.lock();
            defer self.unlock();
            const legacy = t.kittyFlags() == 0;
            if (legacy and action != .release) {
                // Editor-style keys (brief section 5) are for programs that have not enabled the kitty
                // protocol; once one has, it gets the full modifier encoding instead.
                if (keys.editorBytes(k, mods)) |seq| {
                    @memcpy(buf[0..seq.len], seq);
                    n = seq.len;
                } else if (mods & keys.Mods.super != 0) {
                    return true; // other Command combinations belong to the app, not the shell
                } else if (!functional) {
                    // Control plus a character: the classic control code, named by the layout's letter.
                    const cb = keys.controlByte(keys.layoutCodepoint(utf8, unshifted, k)) orelse return false;
                    if (mods & keys.Mods.alt != 0) {
                        buf[0] = 0x1b;
                        n = 1;
                    }
                    buf[n] = cb;
                    n += 1;
                }
            }
            if (n == 0) {
                // Control combinations carry no text of their own.
                const text = if (mods & keys.Mods.ctrl != 0) "" else utf8;
                n = t.encodeKey(k, mods, text, unshifted, action, &buf).len;
            }
        }
        if (n == 0) return false;
        self.userInput();
        try self.input(buf[0..n]);
        return true;
    }

    /// Whether `text` should be confirmed before `paste` (see `vt.Terminal.pasteRisk`).
    pub fn pasteRisk(self: *Session, text: []const u8) vt.PasteRisk {
        const t = self.lock();
        defer self.unlock();
        return t.pasteRisk(text);
    }

    /// Queues pasted text, framed for the terminal's current paste mode.
    pub fn paste(self: *Session, text: []const u8) !void {
        if (text.len > 0) self.userInput();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.gpa);
        {
            const t = self.lock();
            defer self.unlock();
            try t.encodePaste(text, &out, self.gpa);
        }
        try self.input(out.items);
    }

    /// Copies the window title into `out` under the lock (a slice of `out`, cut off if too long).
    pub fn title(self: *Session, out: []u8) []const u8 {
        const t = self.lock();
        defer self.unlock();
        const src = t.title();
        const n = @min(src.len, out.len);
        @memcpy(out[0..n], src[0..n]);
        return out[0..n];
    }

    /// Bytes queued for the child and not yet sent.
    pub fn pendingInput(self: *Session) usize {
        _ = c.pthread_mutex_lock(&self.out_lock);
        defer _ = c.pthread_mutex_unlock(&self.out_lock);
        return self.out_queue.items.len - self.out_head;
    }

    /// Sends as much queued input as the child takes right now. I/O thread only.
    fn flushOutput(self: *Session) void {
        _ = c.pthread_mutex_lock(&self.out_lock);
        defer _ = c.pthread_mutex_unlock(&self.out_lock);
        while (self.out_head < self.out_queue.items.len) {
            const n = self.pty.writeSome(self.out_queue.items[self.out_head..]) catch {
                self.out_queue.clearRetainingCapacity(); // the child is gone: nobody will read these
                self.out_head = 0;
                return;
            };
            if (n == 0) return;
            self.out_head += n;
        }
        self.out_queue.clearRetainingCapacity();
        self.out_head = 0;
    }

    /// Resizes the grid and the PTY. `cell_w_px` and `cell_h_px` are the size of one cell.
    pub fn resize(self: *Session, cols: u16, rows: u16, cell_w_px: u32, cell_h_px: u32) !void {
        {
            const t = self.lock();
            defer self.unlock();
            t.resize(cols, rows, cell_w_px, cell_h_px);
        }
        self.requestWake(); // a resize ends a render hold: show the result at once
        const total_w: u16 = @intCast(@min(std.math.maxInt(u16), @as(u64, cols) * cell_w_px));
        const total_h: u16 = @intCast(@min(std.math.maxInt(u16), @as(u64, rows) * cell_h_px));
        try self.pty.resize(cols, rows, total_w, total_h);
    }

    /// Locks the grid and returns it. Pair with `unlock`; keep the lock short.
    pub fn lock(self: *Session) *vt.Terminal {
        _ = c.pthread_mutex_lock(&self.term_lock);
        return self.term;
    }

    pub fn unlock(self: *Session) void {
        _ = c.pthread_mutex_unlock(&self.term_lock);
    }

    /// Re-arms the `wake` callback; call it before reading the grid for a redraw.
    pub fn wakeHandled(self: *Session) void {
        self.wake_pending.store(false, .release);
    }

    /// The child's exit code once it has ended and its output is fully parsed, else null.
    pub fn exitStatus(self: *Session) ?u8 {
        const v = self.exit_status.load(.acquire);
        return if (v < 0) null else @intCast(v);
    }

    pub fn pid(self: *Session) c_int {
        return self.pty.pid;
    }

    fn monotonicMs() i64 {
        var ts: c.timespec = undefined;
        _ = c.clock_gettime(.MONOTONIC, &ts);
        return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
    }

    fn requestWake(self: *Session) void {
        // A program inside a synchronized-output hold (mode 2026) is mid-frame: draw nothing until it ends.
        if (self.held.load(.acquire)) return;
        if (self.wake_pending.swap(true, .acq_rel)) return;
        if (self.callbacks.wake) |f| f(self.callbacks.ctx);
    }

    fn ioLoop(self: *Session) void {
        var buf: [64 * 1024]u8 = undefined;
        var fds = [3]c.pollfd{
            .{ .fd = self.pty.fd, .events = c.POLL.IN, .revents = 0 },
            .{ .fd = self.stop_pipe[0], .events = c.POLL.IN, .revents = 0 },
            .{ .fd = self.kick_pipe[0], .events = c.POLL.IN, .revents = 0 },
        };
        const readable = c.POLL.IN | c.POLL.HUP | c.POLL.ERR | c.POLL.NVAL;
        var hold_began: ?i64 = null; // when the open hold began (monotonic ms); I/O thread only
        while (true) {
            // Watch for POLLOUT only while there is something to send: idle means no wake-ups.
            fds[0].events = if (self.pendingInput() > 0) c.POLL.IN | c.POLL.OUT else c.POLL.IN;
            // The one timed wait in the product: only while a hold is open, and only until its deadline. Idle has none.
            if (!self.held.load(.acquire)) hold_began = null; // ended by RIS or resize, which do not pass through a read
            var timeout: c_int = -1;
            if (hold_began) |t0| {
                const left = @as(i64, self.hold_deadline_ms) - (monotonicMs() - t0);
                timeout = @intCast(@max(left, 0));
            }
            const r = c.poll(&fds, fds.len, timeout);
            if (r < 0) {
                if (std.posix.errno(@as(isize, r)) == .INTR) continue;
                break;
            }
            if (hold_began) |t0| if (monotonicMs() - t0 >= self.hold_deadline_ms) {
                // The program has held the frame past the deadline: show what is there, and stop timing this hold.
                self.held.store(false, .release);
                hold_began = null;
                self.requestWake();
            };
            if (fds[1].revents != 0) return; // deinit: it hangs up on the child and reaps it
            if (fds[2].revents != 0) {
                var junk: [64]u8 = undefined;
                _ = c.read(self.kick_pipe[0], &junk, junk.len);
            }
            // Read first: output must drain even while input is stuck, or both sides wait on each other.
            if (fds[0].revents & readable != 0) {
                const n = self.pty.read(&buf) catch break;
                if (n == 0) break;
                _ = c.pthread_mutex_lock(&self.term_lock);
                self.term.write(buf[0..n]);
                _ = c.pthread_mutex_unlock(&self.term_lock);
                if (self.held.load(.acquire)) {
                    if (hold_began == null) hold_began = monotonicMs();
                } else hold_began = null;
                self.requestWake();
            }
            if (self.pendingInput() > 0) self.flushOutput();
        }
        // The child closed its side: reap it and report.
        const status = self.pty.wait();
        self.exit_status.store(status, .release);
        self.endCommand(null); // a shell that dies mid-command (`exit 1`) never sends `D`
        if (self.callbacks.exited) |f| f(self.callbacks.ctx, status);
    }

    // Parser callbacks run inside Terminal.write on the I/O thread, with term_lock held.
    fn onWritePty(ctx: ?*anyopaque, data: []const u8) void {
        const self: *Session = @ptrCast(@alignCast(ctx.?));
        self.input(data) catch {}; // a reply that does not fit the queue is dropped
    }

    fn onRenderHold(ctx: ?*anyopaque, held: bool) void {
        const self: *Session = @ptrCast(@alignCast(ctx.?));
        self.held.store(held, .release); // only a flag: the terminal lock is held
    }

    fn onBell(ctx: ?*anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(ctx.?));
        if (self.callbacks.bell) |f| f(self.callbacks.ctx);
    }

    fn onTitle(ctx: ?*anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(ctx.?));
        if (self.callbacks.title) |f| f(self.callbacks.ctx);
    }

    fn onClipboard(ctx: ?*anyopaque, text: []const u8) void {
        const self: *Session = @ptrCast(@alignCast(ctx.?));
        if (self.callbacks.clipboard_write) |f| f(self.callbacks.ctx, text);
    }

    fn onCommand(ctx: ?*anyopaque, kind: vt.CommandKind, exit_code: ?i32) void {
        const self: *Session = @ptrCast(@alignCast(ctx.?));
        switch (kind) {
            .output_start => {
                if (self.cmd_running) return;
                self.cmd_running = true;
                self.cmd_started_ms = monotonicMs();
                if (self.callbacks.command) |f| f(self.callbacks.ctx, true, null, 0);
            },
            // a prompt starting also ends a command whose shell never sent `D`
            .command_end => self.endCommand(exit_code),
            .prompt_start => self.endCommand(null),
            .input_start => {},
        }
    }

    /// Reports the running command as ended (once); a no-op when none runs.
    fn endCommand(self: *Session, exit_code: ?i32) void {
        if (!self.cmd_running) return;
        self.cmd_running = false;
        const ran = @max(0, monotonicMs() - self.cmd_started_ms);
        if (self.callbacks.command) |f| f(self.callbacks.ctx, false, exit_code, @intCast(@min(ran, std.math.maxInt(u32))));
    }

    fn onNotify(ctx: ?*anyopaque, heading: []const u8, body: []const u8) void {
        const self: *Session = @ptrCast(@alignCast(ctx.?));
        if (self.callbacks.notify) |f| f(self.callbacks.ctx, heading, body);
    }

    /// Starts a find for `needle` and returns the number of matches (0 ends it); see `vt.Terminal.findSet`.
    pub fn find(self: *Session, needle: []const u8) usize {
        const t = self.lock();
        const n = t.findSet(needle);
        self.unlock();
        self.requestWake();
        return n;
    }

    /// The next match toward older output or newer (wrapping): selected, scrolled to and highlighted. Null if there is none.
    pub fn findStep(self: *Session, older: bool) ?vt.Terminal.FindPosition {
        const t = self.lock();
        const r = t.findStep(older);
        self.unlock();
        self.requestWake();
        return r;
    }

    /// Jumps `delta` prompts (negative = older) using the shell's OSC 133 marks (see `vt.Terminal.scrollPrompt`). False only on
    /// the alternate screen, where the key is the program's. On the primary screen the key is always taken, even with no prompt
    /// that way: sent on, it would reach the shell as an escape sequence (zsh types `;9A` on the command line).
    pub fn scrollPrompt(self: *Session, delta: i32) bool {
        const t = self.lock();
        const alt = t.onAlternateScreen();
        const moved = !alt and t.scrollPrompt(delta);
        self.unlock();
        if (moved) self.requestWake();
        return !alt;
    }

    /// Selects the last finished command's output (OSC 133); false if there is none to select (see `vt.Terminal.selectLastOutput`).
    pub fn selectOutput(self: *Session) bool {
        const t = self.lock();
        const ok = t.selectLastOutput();
        self.unlock();
        if (ok) self.requestWake();
        return ok;
    }

    /// Selects everything (Cmd+A).
    pub fn selectAll(self: *Session) void {
        const t = self.lock();
        t.selectAll();
        self.unlock();
        self.requestWake();
    }

    /// Moves the selection's free end by line edge or word (see `vt.Terminal.selectMove`); false on the alternate screen.
    pub fn selectMove(self: *Session, move: vt.Terminal.SelectMove) bool {
        const t = self.lock();
        const ok = t.selectMove(move);
        self.unlock();
        if (ok) self.requestWake();
        return ok;
    }

    pub fn findEnd(self: *Session) void {
        const t = self.lock();
        t.findEnd();
        self.unlock();
        self.requestWake();
    }

    /// Clear screen: the screen (and the scrollback, if `scrollback`) is emptied here, then Ctrl+L is typed so a shell redraws its
    /// prompt at the top. A full-screen program (the alternate screen) owns its screen: nothing happens and this returns false,
    /// so the caller can let the key through to it.
    pub fn clearScreen(self: *Session, scrollback: bool) bool {
        {
            const t = self.lock();
            defer self.unlock();
            if (t.onAlternateScreen()) return false;
            t.write(if (scrollback) "\x1b[H\x1b[2J\x1b[3J" else "\x1b[H\x1b[2J");
        }
        self.requestWake();
        self.typeText("\x0c") catch {};
        return true;
    }

    /// A theme (colors, see `vt.Terminal.setTheme`); the view is woken to redraw.
    pub fn setTheme(self: *Session, fg: vt.Rgb, bg: vt.Rgb, cursor_color: ?vt.Rgb, ansi: [16]?vt.Rgb) void {
        {
            const t = self.lock();
            defer self.unlock();
            t.setTheme(fg, bg, cursor_color, ansi);
        }
        self.requestWake();
    }

    /// The system appearance changed: a program that asked (mode 2031) is told.
    pub fn setScheme(self: *Session, dark: bool) void {
        var buf: [16]u8 = undefined;
        var n: usize = 0;
        {
            const t = self.lock();
            defer self.unlock();
            n = t.setScheme(dark, &buf).len;
        }
        if (n > 0) self.input(buf[0..n]) catch {};
    }

    /// Changes whether a program may write the clipboard (config reload).
    pub fn setClipboardWrite(self: *Session, allow: bool) void {
        const t = self.lock();
        defer self.unlock();
        t.setClipboardWrite(allow);
    }
};

// ---- tests ----

const Spy = struct {
    wakes: std.atomic.Value(u32) = .init(0),
    exits: std.atomic.Value(i32) = .init(-1),
    /// The `command` events in order (the first eight), written by the I/O thread; `cmd_count` publishes them.
    cmd_events: [8]CmdEvent = undefined,
    cmd_count: std.atomic.Value(u32) = .init(0),

    fn from(ctx: ?*anyopaque) *Spy {
        return @ptrCast(@alignCast(ctx.?));
    }
    fn wake(ctx: ?*anyopaque) void {
        _ = from(ctx).wakes.fetchAdd(1, .monotonic);
    }
    fn exited(ctx: ?*anyopaque, status: u8) void {
        from(ctx).exits.store(status, .release);
    }
    const CmdEvent = struct { running: bool, exit_code: ?i32, duration_ms: u32 };
    fn command(ctx: ?*anyopaque, running: bool, exit_code: ?i32, duration_ms: u32) void {
        const self = from(ctx);
        const n = self.cmd_count.load(.monotonic);
        if (n < self.cmd_events.len) self.cmd_events[n] = .{ .running = running, .exit_code = exit_code, .duration_ms = duration_ms };
        self.cmd_count.store(n + 1, .release);
    }
    fn callbacks(self: *Spy) Callbacks {
        return .{ .ctx = self, .wake = wake, .exited = exited, .command = command };
    }
};

fn sleepMs(ms: u32) void {
    const ts: std.c.timespec = .{ .sec = ms / 1000, .nsec = @as(isize, ms % 1000) * std.time.ns_per_ms };
    _ = std.c.nanosleep(&ts, null);
}

/// Test-only polling: product code never polls.
fn waitFor(timeout_ms: u32, ctx: anytype, comptime pred: fn (@TypeOf(ctx)) bool) bool {
    var waited: u32 = 0;
    while (waited < timeout_ms) : (waited += 5) {
        if (pred(ctx)) return true;
        sleepMs(5);
    }
    return pred(ctx);
}

const Row = struct {
    s: *Session,
    want: []const u8,
    exact: bool = true,
    fn ok(self: Row) bool {
        const t = self.s.lock();
        defer self.s.unlock();
        var buf: [512]u8 = undefined;
        var r: u16 = 0;
        while (r < t.size().rows) : (r += 1) {
            const text = t.rowText(r, &buf);
            if (if (self.exact) std.mem.eql(u8, text, self.want) else std.mem.indexOf(u8, text, self.want) != null) return true;
        }
        return false;
    }
};

const Exited = struct {
    s: *Session,
    fn ok(self: Exited) bool {
        return self.s.exitStatus() != null;
    }
};

test "echo round trip" {
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{"/bin/sh"} });
    defer s.deinit();
    try s.input("echo hi\n");
    try std.testing.expect(waitFor(10_000, Row{ .s = s, .want = "hi" }, Row.ok));
}

test "flood and fast exit" {
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "seq 1 200000" } });
    defer s.deinit();
    try std.testing.expect(waitFor(20_000, Exited{ .s = s }, Exited.ok));
    try std.testing.expectEqual(@as(?u8, 0), s.exitStatus());
    const t = s.lock();
    defer s.unlock();
    var buf: [512]u8 = undefined;
    var r: u16 = t.size().rows;
    var last: []const u8 = "";
    while (r > 0) {
        r -= 1;
        last = t.rowText(r, &buf);
        if (last.len > 0) break;
    }
    try std.testing.expectEqualStrings("200000", last);
    try std.testing.expect(t.scrollbackRows() <= 1200);
}

const CmdCount = struct {
    spy: *Spy,
    want: u32,
    fn ok(self: CmdCount) bool {
        return self.spy.cmd_count.load(.acquire) >= self.want;
    }
};

test "command callbacks: C starts, D ends with the exit code, repeated marks make no event" {
    var spy: Spy = .{};
    const script = "printf '\\033]133;A\\007\\033]133;A\\007'; printf '\\033]133;C\\007'; sleep 0.3; printf '\\033]133;D;3\\007'; " ++
        "i=0; while [ $i -lt 1000 ]; do printf '\\033]133;A\\007'; i=$((i+1)); done; echo flood-done; sleep 5";
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", script }, .callbacks = spy.callbacks() });
    defer s.deinit();
    try std.testing.expect(waitFor(10_000, CmdCount{ .spy = &spy, .want = 2 }, CmdCount.ok));
    try std.testing.expect(hexOf(s, "flood-done")); // every mark has been parsed by now
    try std.testing.expectEqual(@as(u32, 2), spy.cmd_count.load(.acquire)); // one start, one end: the 1002 other marks changed nothing
    try std.testing.expect(spy.cmd_events[0].running);
    try std.testing.expectEqual(@as(u32, 0), spy.cmd_events[0].duration_ms);
    try std.testing.expect(!spy.cmd_events[1].running);
    try std.testing.expectEqual(@as(?i32, 3), spy.cmd_events[1].exit_code);
    try std.testing.expect(spy.cmd_events[1].duration_ms >= 250);
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn system(cmd: [*:0]const u8) c_int;

/// Sets (or, with null, removes) an environment variable for a test and puts it back when `restore` runs.
const EnvVar = struct {
    name: [:0]const u8,
    old: ?[]const u8,
    fn set(a: std.mem.Allocator, name: [:0]const u8, value: ?[:0]const u8) !EnvVar {
        const old: ?[]const u8 = if (std.c.getenv(name.ptr)) |v| try a.dupe(u8, std.mem.span(v)) else null;
        if (value) |v| _ = setenv(name.ptr, v.ptr, 1) else _ = unsetenv(name.ptr);
        return .{ .name = name, .old = old };
    }
    fn restore(self: EnvVar, a: std.mem.Allocator) void {
        if (self.old) |o| {
            const z = std.mem.Allocator.dupeSentinel(a, u8, o, 0) catch return;
            defer a.free(z);
            _ = setenv(self.name.ptr, z.ptr, 1);
            a.free(o);
        } else _ = unsetenv(self.name.ptr);
    }
};

test "zsh with the integration reports commands and keeps the user's ZDOTDIR" {
    const a = std.testing.allocator;
    const tmp = if (std.c.getenv("TMPDIR")) |d| std.mem.trimEnd(u8, std.mem.span(d), "/") else "/tmp";
    var home_buf: [256]u8 = undefined;
    const home = try std.fmt.bufPrintSentinel(&home_buf, "{s}/harf-zsh-test-{d}", .{ tmp, std.c.getpid() }, 0);
    var cmd_buf: [600]u8 = undefined;
    _ = system((try std.fmt.bufPrintSentinel(&cmd_buf, "mkdir -p '{s}' && touch '{s}/.zshrc'", .{ home, home }, 0)).ptr); // an empty .zshrc: no new-user prompt
    defer _ = system((std.fmt.bufPrintSentinel(&cmd_buf, "rm -rf '{s}'", .{home}, 0) catch unreachable).ptr);
    var cwd_buf: [512]u8 = undefined;
    const cwd = std.mem.sliceTo(std.c.getcwd(&cwd_buf, cwd_buf.len).?[0..cwd_buf.len], 0);
    var dir_buf: [600]u8 = undefined;
    const dir = try std.fmt.bufPrintSentinel(&dir_buf, "{s}/macos/shell-integration", .{cwd}, 0);

    // a hermetic login zsh: its own HOME, no ZDOTDIR of ours to start with
    const shell_var = try EnvVar.set(a, "SHELL", "/bin/zsh");
    defer shell_var.restore(a);
    const home_var = try EnvVar.set(a, "HOME", home);
    defer home_var.restore(a);
    const zdot_var = try EnvVar.set(a, "ZDOTDIR", home);
    defer zdot_var.restore(a);
    pty.default_shell_integration_dir = dir;
    defer pty.default_shell_integration_dir = null;

    var spy: Spy = .{};
    const s = try Session.start(a, .{ .callbacks = spy.callbacks() });
    defer s.deinit();
    try s.typeText("false\n");
    try std.testing.expect(waitFor(15_000, CmdCount{ .spy = &spy, .want = 2 }, CmdCount.ok));
    try std.testing.expect(spy.cmd_events[0].running);
    try std.testing.expect(!spy.cmd_events[1].running);
    try std.testing.expectEqual(@as(?i32, 1), spy.cmd_events[1].exit_code);
    try s.typeText("true\n");
    try std.testing.expect(waitFor(15_000, CmdCount{ .spy = &spy, .want = 4 }, CmdCount.ok));
    try std.testing.expectEqual(@as(?i32, 0), spy.cmd_events[3].exit_code);
    try s.typeText("print -r -- \"Z=$ZDOTDIR\"\n");
    var want_buf: [300]u8 = undefined;
    const want = try std.fmt.bufPrint(&want_buf, "Z={s}", .{home});
    try std.testing.expect(hexOf(s, want)); // the user's own ZDOTDIR is back inside the shell

    // no ZDOTDIR at all: the shim leaves none behind
    _ = unsetenv("ZDOTDIR");
    var spy2: Spy = .{};
    const s2 = try Session.start(a, .{ .callbacks = spy2.callbacks() });
    defer s2.deinit();
    try s2.typeText("print -r -- \"Z=$ZDOTDIR\"\n");
    try std.testing.expect(waitFor(15_000, Row{ .s = s2, .want = "Z=", .exact = true }, Row.ok));

    // `exec` replaces the shell with a process that never closes the command, so it must not open one, however it is typed
    for ([_][]const u8{ " exec sh -c 'echo EXECED; sleep 5'\n", "builtin exec sh -c 'echo EXECED; sleep 5'\n" }) |line| {
        var spy3: Spy = .{};
        const s3 = try Session.start(a, .{ .callbacks = spy3.callbacks() });
        defer s3.deinit();
        try s3.typeText(line);
        try std.testing.expect(waitFor(15_000, Row{ .s = s3, .want = "EXECED", .exact = true }, Row.ok));
        try std.testing.expectEqual(@as(u32, 0), spy3.cmd_count.load(.acquire));
    }
}

test "scrollPrompt takes the key on the primary screen even with nowhere to go, and never on the alternate screen" {
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "seq 1 5; sleep 5" } });
    defer s.deinit();
    try std.testing.expect(hexOf(s, "5"));
    try std.testing.expect(s.scrollPrompt(-1)); // no prompt marks: nothing moves, but the key must not reach the shell (zsh would type ";9A")
    try std.testing.expect(s.scrollPrompt(1));
    const alt = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "printf '\\033[?1049hINALT'; sleep 5" } });
    defer alt.deinit();
    try std.testing.expect(hexOf(alt, "INALT"));
    try std.testing.expect(!alt.scrollPrompt(-1)); // a full-screen program owns its keys
}

test "a command still running when the child exits is closed" {
    var spy: Spy = .{};
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "printf '\\033]133;C\\007'; sleep 0.2; exit 3" }, .callbacks = spy.callbacks() });
    defer s.deinit();
    try std.testing.expect(waitFor(10_000, CmdCount{ .spy = &spy, .want = 2 }, CmdCount.ok));
    try std.testing.expect(spy.cmd_events[0].running);
    try std.testing.expect(!spy.cmd_events[1].running); // otherwise the tab would show a running command for a dead shell
    try std.testing.expectEqual(@as(?i32, null), spy.cmd_events[1].exit_code);
}

test "wake is coalesced until handled" {
    var spy: Spy = .{};
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{"/bin/sh"}, .callbacks = spy.callbacks() });
    defer s.deinit();
    try s.input("echo a\n");
    try std.testing.expect(waitFor(10_000, Row{ .s = s, .want = "a" }, Row.ok));
    try std.testing.expectEqual(@as(u32, 1), spy.wakes.load(.monotonic));
    try s.input("echo b\n");
    try std.testing.expect(waitFor(10_000, Row{ .s = s, .want = "b" }, Row.ok));
    try std.testing.expectEqual(@as(u32, 1), spy.wakes.load(.monotonic)); // never handled, so still one
    s.wakeHandled();
    try s.input("echo c\n");
    try std.testing.expect(waitFor(10_000, Row{ .s = s, .want = "c" }, Row.ok));
    try std.testing.expectEqual(@as(u32, 2), spy.wakes.load(.monotonic));
}

test "deinit kills a live child" {
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sleep", "60" } });
    const p = s.pid();
    s.deinit();
    const rc = std.c.kill(p, @enumFromInt(0)); // signal 0: only checks that the process exists
    const e = std.posix.errno(@as(isize, rc));
    try std.testing.expectEqual(@as(c_int, -1), rc);
    try std.testing.expectEqual(std.posix.E.SRCH, e);
}

test "resize while output streams" {
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "seq 1 200000" } });
    defer s.deinit();
    const sizes = [_][2]u16{ .{ 10, 5 }, .{ 200, 60 }, .{ 1, 1 } };
    for (0..50) |i| {
        const sz = sizes[i % sizes.len];
        try s.resize(sz[0], sz[1], 8, 16);
    }
    try s.resize(80, 24, 8, 16);
    try std.testing.expect(waitFor(30_000, Exited{ .s = s }, Exited.ok));
    try std.testing.expectEqual(@as(?u8, 0), s.exitStatus());
}

test "exit status is reported" {
    var spy: Spy = .{};
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "exit 7" }, .callbacks = spy.callbacks() });
    defer s.deinit();
    try std.testing.expect(waitFor(10_000, Exited{ .s = s }, Exited.ok));
    try std.testing.expectEqual(@as(?u8, 7), s.exitStatus());
    try std.testing.expectEqual(@as(i32, 7), spy.exits.load(.acquire));
}

test "terminal replies reach the child" {
    // macOS od pads each byte with extra spaces; tr squeezes them so the needle below matches.
    const script = "stty raw -echo; printf '\\033[6n'; dd bs=1 count=6 2>/dev/null | od -An -tx1 | tr -s ' '";
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", script } });
    defer s.deinit();
    try std.testing.expect(waitFor(10_000, Row{ .s = s, .want = "1b 5b 31 3b 31 52", .exact = false }, Row.ok));
}

test "a child does not inherit another session's descriptors" {
    const a = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sleep", "60" } });
    defer a.deinit();
    var script_buf: [256]u8 = undefined;
    const script = try std.fmt.bufPrintSentinel(
        &script_buf,
        "for fd in {d} {d} {d}; do if (: <&$fd) 2>/dev/null; then echo leaked$fd; fi; done; echo done",
        .{ a.pty.fd, a.stop_pipe[0], a.stop_pipe[1] },
        0,
    );
    const b = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", script } });
    defer b.deinit();
    try std.testing.expect(waitFor(10_000, Row{ .s = b, .want = "done" }, Row.ok));
    try std.testing.expect(!(Row{ .s = b, .want = "leaked", .exact = false }).ok());
}

fn nowMs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

test "input never blocks" {
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 3" } });
    defer s.deinit();
    const big = try std.testing.allocator.alloc(u8, 8 << 20);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    const t0 = nowMs();
    try s.input(big);
    try std.testing.expect(nowMs() - t0 < 200);
}

test "queued input reaches the child in order" {
    const script = "stty raw -echo; echo ready; sleep 1; head -c 1000000 | wc -c";
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", script } });
    defer s.deinit();
    try std.testing.expect(waitFor(10_000, Row{ .s = s, .want = "ready", .exact = false }, Row.ok));
    const data = try std.testing.allocator.alloc(u8, 1_000_000);
    defer std.testing.allocator.free(data);
    @memset(data, 'y');
    try s.input(data);
    try std.testing.expect(waitFor(20_000, Row{ .s = s, .want = "1000000", .exact = false }, Row.ok));
}

test "resize with size reports does not block" {
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "printf '\\033[?2048h'; sleep 3" } });
    defer s.deinit();
    sleepMs(300); // let the mode switch be parsed
    const big = try std.testing.allocator.alloc(u8, 4 << 20);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    try s.input(big);
    const t0 = nowMs();
    try s.resize(100, 30, 8, 16);
    try std.testing.expect(nowMs() - t0 < 500);
}

test "input over the cap is refused" {
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 3" } });
    defer s.deinit();
    const big = try std.testing.allocator.alloc(u8, max_pending_input + 1);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    try std.testing.expectError(error.InputQueueFull, s.input(big));
    try std.testing.expectEqual(@as(usize, 0), s.pendingInput());
}

test "key: text keys are left to the text path, Arabic text arrives intact" {
    const script = "stty raw -echo; echo ready; dd bs=1 count=2 2>/dev/null | od -An -tx1 | tr -s ' '";
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", script } });
    defer s.deinit();
    try std.testing.expect(!try s.key(0, 0, "ش", 0, .press)); // physical A on an Arabic layout
    try std.testing.expect(!try s.key(200, 0, "م", 0, .press)); // unknown keycode
    try std.testing.expect(waitFor(10_000, Row{ .s = s, .want = "ready", .exact = false }, Row.ok));
    try s.input("م");
    try std.testing.expect(waitFor(10_000, Row{ .s = s, .want = "d9 85", .exact = false }, Row.ok));
}

test "key: arrows and ctrl c are encoded, modifier keys send nothing" {
    const script = "stty raw -echo; echo ready; dd bs=1 count=4 2>/dev/null | od -An -tx1 | tr -s ' '";
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", script } });
    defer s.deinit();
    try std.testing.expect(waitFor(10_000, Row{ .s = s, .want = "ready", .exact = false }, Row.ok));
    try std.testing.expect(try s.key(56, 1, "", 0, .press)); // shift alone
    try std.testing.expect(try s.key(126, 0, "", 0, .press)); // up arrow: ESC [ A (3 bytes)
    try std.testing.expect(try s.key(8, keys.Mods.ctrl, "\x03", 0, .press)); // ctrl c: 1 byte
    try std.testing.expect(waitFor(10_000, Row{ .s = s, .want = "1b 5b 41 03", .exact = false }, Row.ok));
}

test "paste reaches the child with newlines as CR" {
    const script = "stty raw -echo; echo ready; dd bs=1 count=3 2>/dev/null | od -An -tx1 | tr -s ' '";
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", script } });
    defer s.deinit();
    try std.testing.expect(waitFor(10_000, Row{ .s = s, .want = "ready", .exact = false }, Row.ok));
    try s.paste("a\nb");
    try std.testing.expect(waitFor(10_000, Row{ .s = s, .want = "61 0d 62", .exact = false }, Row.ok));
}

test "title copy" {
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "printf '\\033]0;hi\\007'; sleep 2" } });
    defer s.deinit();
    var buf: [16]u8 = undefined;
    var got = false;
    var waited: u32 = 0;
    while (waited < 10_000 and !got) : (waited += 5) {
        got = std.mem.eql(u8, s.title(&buf), "hi");
        if (!got) sleepMs(5);
    }
    try std.testing.expect(got);
    var one: [1]u8 = undefined;
    try std.testing.expectEqualStrings("h", s.title(&one));
}

fn hexOf(s: *Session, want: []const u8) bool {
    return waitFor(10_000, Row{ .s = s, .want = want, .exact = false }, Row.ok);
}

test "key: Option and Command editing keys in legacy mode" {
    const script = "stty raw -echo; echo ready; dd bs=1 count=7 2>/dev/null | od -An -tx1 | tr -s ' '";
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", script } });
    defer s.deinit();
    try std.testing.expect(hexOf(s, "ready"));
    try std.testing.expect(try s.key(123, keys.Mods.alt, "", 0, .press)); // Option+Left: ESC b
    try std.testing.expect(try s.key(124, keys.Mods.alt, "", 0, .press)); // Option+Right: ESC f
    try std.testing.expect(try s.key(123, keys.Mods.super, "", 0, .press)); // Cmd+Left: ^A
    try std.testing.expect(try s.key(126, keys.Mods.super, "", 0, .press)); // Cmd+Up: nothing for the shell
    try std.testing.expect(try s.key(124, keys.Mods.super, "", 0, .press)); // Cmd+Right: ^E
    try std.testing.expect(try s.key(51, keys.Mods.super, "", 0, .press)); // Cmd+Backspace: ^U
    try std.testing.expect(hexOf(s, "1b 62 1b 66 01 05 15"));
}

test "key: Option+arrows send the full modifier encoding once the program asked for the kitty protocol" {
    const script = "stty raw -echo; printf '\\033[>1u'; echo ready; dd bs=1 count=6 2>/dev/null | od -An -tx1 | tr -s ' '";
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", script } });
    defer s.deinit();
    try std.testing.expect(hexOf(s, "ready"));
    try std.testing.expect(try s.key(123, keys.Mods.alt, "", 0, .press)); // ESC [ 1 ; 3 D
    try std.testing.expect(hexOf(s, "1b 5b 31 3b 33 44"));
}

test "key: a release reaches a program that asked for event types, and only that program" {
    // flags 1 (disambiguate) + 2 (event types): the press is ESC [ 1 ; 1 : 1 A and the release ESC [ 1 ; 1 : 3 A (16 bytes)
    const script = "stty raw -echo; printf '\\033[>3u'; echo ready; dd bs=1 count=16 2>/dev/null | od -An -tx1 | tr -s ' '";
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", script } });
    defer s.deinit();
    try std.testing.expect(hexOf(s, "ready"));
    try std.testing.expect(try s.key(126, 0, "", 0, .press));
    try std.testing.expect(try s.key(126, 0, "", 0, .release));
    try std.testing.expect(hexOf(s, "1b 5b 31 3b 31 3a 31 41 1b 5b 31 3b 31 3a 33 41"));

    // legacy program: a release is not reported at all
    const legacy = "stty raw -echo; echo ready; dd bs=1 count=3 2>/dev/null | od -An -tx1 | tr -s ' '";
    const l = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", legacy } });
    defer l.deinit();
    try std.testing.expect(hexOf(l, "ready"));
    try std.testing.expect(!try l.key(126, 0, "", 0, .release));
    try std.testing.expect(try l.key(126, 0, "", 0, .press));
    try std.testing.expect(hexOf(l, "1b 5b 41"));
}

test "clearScreen empties the screen and the scrollback, types Ctrl+L, and leaves a full-screen program alone" {
    const script = "seq 1 60; stty raw -echo; echo ready; dd bs=1 count=1 2>/dev/null | od -An -tx1";
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", script } });
    defer s.deinit();
    try std.testing.expect(hexOf(s, "ready"));
    {
        const t = s.lock();
        defer s.unlock();
        try std.testing.expect(t.scrollbackRows() > 0);
    }
    try std.testing.expect(s.clearScreen(true));
    try std.testing.expect(hexOf(s, "0c")); // the shell's prompt redraw key reached the child
    const t = s.lock();
    defer s.unlock();
    try std.testing.expectEqual(@as(usize, 0), t.scrollbackRows());
    var buf: [200]u8 = undefined;
    for (0..t.size().rows) |r| try std.testing.expect(std.mem.indexOf(u8, t.rowText(@intCast(r), &buf), "ready") == null);

    // the alternate screen belongs to the program: nothing is cleared and nothing is typed
    const alt = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "printf '\\033[?1049hINALT'; stty raw -echo; echo; dd bs=1 count=1 2>/dev/null | od -An -tx1" } });
    defer alt.deinit();
    try std.testing.expect(hexOf(alt, "INALT"));
    try std.testing.expect(!alt.clearScreen(true));
    try std.testing.expect(!alt.clearScreen(false)); // false: the caller lets Ctrl+L through to the program
    sleepMs(300);
    try std.testing.expectEqual(@as(usize, 0), alt.pendingInput());
    const at = alt.lock();
    defer alt.unlock();
    var b2: [200]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, at.rowText(0, &b2), "INALT") != null);
}

test "a session starts in the directory it is given" {
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "pwd -P; sleep 1" }, .cwd = "/usr" });
    defer s.deinit();
    try std.testing.expect(hexOf(s, "/usr"));
    const missing = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "pwd -P; sleep 1" }, .cwd = "/no/such/directory" });
    defer missing.deinit();
    try std.testing.expect(waitFor(10_000, Row{ .s = missing, .want = "/", .exact = true }, Row.ok)); // it cannot be entered: the root
}

test "key: Ctrl letters follow the layout, not the physical key" {
    const script = "stty raw -echo; echo ready; dd bs=1 count=3 2>/dev/null | od -An -tx1 | tr -s ' '";
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", script } });
    defer s.deinit();
    try std.testing.expect(hexOf(s, "ready"));
    try std.testing.expect(try s.key(12, keys.Mods.ctrl, "a", 'a', .press)); // AZERTY: "a" sits where QWERTY has Q
    try std.testing.expect(try s.key(34, keys.Mods.ctrl, "c", 'c', .press)); // Dvorak: "c" sits where QWERTY has I
    try std.testing.expect(try s.key(8, keys.Mods.ctrl, "\u{624}", 0x624, .press)); // Arabic layout: falls back to the physical C
    try std.testing.expect(hexOf(s, "01 03 03"));
}

test "key: Ctrl with punctuation and digits in legacy mode" {
    const script = "stty raw -echo; echo ready; dd bs=1 count=5 2>/dev/null | od -An -tx1 | tr -s ' '";
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", script } });
    defer s.deinit();
    try std.testing.expect(hexOf(s, "ready"));
    try std.testing.expect(try s.key(33, keys.Mods.ctrl, "[", '[', .press)); // ESC
    try std.testing.expect(try s.key(46, keys.Mods.ctrl, "m", 'm', .press)); // CR
    try std.testing.expect(try s.key(27, keys.Mods.ctrl, "-", '-', .press)); // 0x1f, readline undo
    try std.testing.expect(try s.key(19, keys.Mods.ctrl | keys.Mods.shift, "@", '2', .press)); // NUL
    try std.testing.expect(try s.key(34, keys.Mods.ctrl, "i", 'i', .press)); // TAB
    try std.testing.expect(hexOf(s, "1b 0d 1f 00 09"));
}

test "key: Ctrl+C and AZERTY Ctrl+A reach a program that enabled the kitty protocol" {
    const script = "stty raw -echo; printf '\\033[>5u'; echo ready; dd bs=1 count=19 2>/dev/null | xxd -p";
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", script } });
    defer s.deinit();
    try std.testing.expect(hexOf(s, "ready"));
    try std.testing.expect(try s.key(8, keys.Mods.ctrl, "c", 'c', .press)); // ESC [ 99 ; 5 u
    try std.testing.expect(try s.key(12, keys.Mods.ctrl, "a", 'a', .press)); // ESC [ 97 :: 113 ; 5 u: the layout's a, with the physical q as the base-layout key
    try std.testing.expect(hexOf(s, "1b5b39393b35751b5b39373a3a3131333b3575"));
}

test "key: a key that produces nothing is not reported as handled" {
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 5" } });
    defer s.deinit();
    try std.testing.expect(!try s.key(47, keys.Mods.ctrl, ".", '.', .press)); // Ctrl+. has no control code
    try std.testing.expectEqual(@as(usize, 0), s.pendingInput());
}

const AtBottom = struct {
    s: *Session,
    want: bool,
    fn ok(self: AtBottom) bool {
        const t = self.s.lock();
        defer self.s.unlock();
        const v = t.viewport();
        return (v.offset + v.rows == v.total) == self.want;
    }
};

test "scroll: the viewport moves, and typing snaps it to the bottom" {
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "seq 1 200; exec cat" } });
    defer s.deinit();
    try std.testing.expect(waitFor(10_000, Row{ .s = s, .want = "200" }, Row.ok));
    try s.scroll(-30);
    try std.testing.expect(AtBottom.ok(.{ .s = s, .want = false }));
    try s.typeText("xyz\n");
    try std.testing.expect(waitFor(10_000, AtBottom{ .s = s, .want = true }, AtBottom.ok));
    try std.testing.expect(waitFor(10_000, Row{ .s = s, .want = "xyz", .exact = false }, Row.ok)); // the echo is on screen
    try s.scroll(-30);
    try std.testing.expect(AtBottom.ok(.{ .s = s, .want = false }));
    _ = try s.key(126, 0, "", 0, .press); // an arrow key snaps too
    try std.testing.expect(AtBottom.ok(.{ .s = s, .want = true }));
    try s.scroll(-30);
    try s.paste("p");
    try std.testing.expect(AtBottom.ok(.{ .s = s, .want = true }));
}

test "scroll: new output does not move a scrolled viewport" {
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "seq 1 100; sleep 0.6; seq 101 160; sleep 5" } });
    defer s.deinit();
    try std.testing.expect(waitFor(10_000, Row{ .s = s, .want = "100" }, Row.ok));
    try s.scroll(-20);
    var before: usize = 0;
    var total_before: usize = 0;
    {
        const t = s.lock();
        defer s.unlock();
        before = t.viewport().offset;
        total_before = t.viewport().total;
    }
    const Grew = struct {
        s: *Session,
        total: usize,
        fn ok(self: @This()) bool {
            const t = self.s.lock();
            defer self.s.unlock();
            return t.viewport().total > self.total;
        }
    };
    try std.testing.expect(waitFor(10_000, Grew{ .s = s, .total = total_before }, Grew.ok));
    const t = s.lock();
    defer s.unlock();
    try std.testing.expectEqual(before, t.viewport().offset);
}

test "scroll: the alternate screen gets arrow keys, in the terminal's cursor key mode" {
    const script = "printf '\\033[?1049h'; stty raw -echo; echo ready; dd bs=1 count=12 2>/dev/null | od -An -tx1 | tr -s ' '";
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", script } });
    defer s.deinit();
    try std.testing.expect(hexOf(s, "ready"));
    try s.scroll(-3); // three presses of Up: ESC [ A
    try s.scroll(1); // one Down
    try std.testing.expect(hexOf(s, "1b 5b 41 1b 5b 41 1b 5b 41 1b 5b 42"));
}

test "scroll: with alternate scroll (mode 1007) reset, the alternate screen's wheel sends nothing" {
    const script = "printf '\\033[?1049h\\033[?1007l'; stty raw -echo; echo ready; dd bs=1 count=1 2>/dev/null | od -An -tx1 | tr -s ' '";
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", script } });
    defer s.deinit();
    try std.testing.expect(hexOf(s, "ready"));
    try s.scroll(-3); // would be three Up presses with 1007 set
    try s.input("Z");
    try std.testing.expect(hexOf(s, "5a")); // the child's first byte is the Z: the wheel sent nothing before it
}

test "mouse: reports reach a program that asked for them, and nothing goes out otherwise" {
    const script = "printf '\\033[?1000h\\033[?1006h'; stty raw -echo; echo ready; dd bs=1 count=18 2>/dev/null | xxd -p";
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", script } });
    defer s.deinit();
    try std.testing.expect(hexOf(s, "ready"));
    try std.testing.expect(try s.mouse(.press, .left, 0, 4, 2, 10, 20));
    try std.testing.expect(try s.mouse(.release, .left, 0, 4, 2, 10, 20));
    try std.testing.expect(hexOf(s, "1b5b3c303b353b334d1b5b3c303b353b336d")); // ESC [ < 0 ; 5 ; 3 M, then m
}

test "mouse: with tracking off nothing is sent and the caller keeps the event" {
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 5" } });
    defer s.deinit();
    try std.testing.expect(!try s.mouse(.press, .left, 0, 4, 2, 10, 20));
    try std.testing.expectEqual(@as(usize, 0), s.pendingInput());
}

test "scroll: a program that tracks the mouse gets wheel events, not a scrolled viewport" {
    const script = "printf '\\033[?1000h\\033[?1006h'; stty raw -echo; echo ready; dd bs=1 count=30 2>/dev/null | xxd -p";
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", script } });
    defer s.deinit();
    try std.testing.expect(hexOf(s, "ready"));
    s.setPointer(6, 1);
    try s.scroll(-3); // one wheel-up event at the pointer: ESC [ < 64 ; 7 ; 2 M
    try s.scroll(6); // two wheel-down events (a notch is three rows): ESC [ < 65 ; 7 ; 2 M, twice
    try std.testing.expect(hexOf(s, "1b5b3c36343b373b324d1b5b3c36353b373b324d1b5b3c36353b373b324d"));
}

test "focus: events go to a program only when it asked for them" {
    const script = "printf '\\033[?1004h'; stty raw -echo; echo ready; dd bs=1 count=6 2>/dev/null | xxd -p";
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", script } });
    defer s.deinit();
    try std.testing.expect(hexOf(s, "ready"));
    try s.setFocus(false);
    try s.setFocus(true);
    try std.testing.expect(hexOf(s, "1b5b4f1b5b49")); // ESC [ O, then ESC [ I
    try std.testing.expect(s.focused());
}

test "focus: nothing is sent without the mode, but the flag still changes" {
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "sleep 5" } });
    defer s.deinit();
    try std.testing.expect(s.focused());
    try s.setFocus(false);
    try std.testing.expect(!s.focused());
    try std.testing.expectEqual(@as(usize, 0), s.pendingInput());
}

const HasSelection = struct {
    s: *Session,
    fn now(self: HasSelection) bool {
        const t = self.s.lock();
        defer self.s.unlock();
        return t.hasSelection();
    }
};

fn selectFirstCells(s: *Session) void {
    s.selection(0, 1, 0, 0, 0); // press
    s.selection(1, 1, 0, 3, 0); // drag
    s.selection(2, 1, 0, 3, 0); // release
}

test "typing, keys and paste clear the selection; lone modifier keys and Cmd+C do not" {
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "echo hello world; exec cat" } });
    defer s.deinit();
    try std.testing.expect(waitFor(10_000, Row{ .s = s, .want = "hello world" }, Row.ok));
    const sel = HasSelection{ .s = s };
    selectFirstCells(s);
    try std.testing.expect(sel.now());
    _ = try s.key(56, keys.Mods.shift, "", 0, .press); // Shift alone sends nothing: the selection stays
    try std.testing.expect(sel.now());
    _ = try s.key(8, keys.Mods.super, "", 0, .press); // Cmd+C belongs to the app: the selection stays
    try std.testing.expect(sel.now());
    try s.typeText("x");
    try std.testing.expect(!sel.now());
    selectFirstCells(s);
    try std.testing.expect(sel.now());
    _ = try s.key(126, 0, "", 0, .press); // an arrow key
    try std.testing.expect(!sel.now());
    selectFirstCells(s);
    try s.typeText("\n"); // a new line
    try std.testing.expect(!sel.now());
    selectFirstCells(s);
    try s.paste("p");
    try std.testing.expect(!sel.now());
}

test "Session.selection with Shift extends an existing selection" {
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "printf 'hello world'; sleep 5" } });
    defer s.deinit();
    try std.testing.expect(waitFor(10_000, Row{ .s = s, .want = "hello world" }, Row.ok));
    selectFirstCells(s); // selects "hell" (0..3)
    s.selection(0, 1, keys.Mods.shift, 10, 0);
    s.selection(2, 1, keys.Mods.shift, 10, 0);
    const txt = (try s.selectionText(std.testing.allocator)) orelse return error.NoSelection;
    defer std.testing.allocator.free(txt);
    try std.testing.expectEqualStrings("hello world", txt);
}

const wheel_up_event = "1b5b3c36343b313b314d"; // ESC [ < 64 ; 1 ; 1 M
const wheel_down_event = "1b5b3c36353b313b314d"; // ESC [ < 65 ; 1 ; 1 M

fn wheelSession(read_bytes: usize) !*Session {
    var script: [160]u8 = undefined;
    const text = try std.fmt.bufPrintSentinel(&script, "printf '\\033[?1000h\\033[?1006h'; stty raw -echo; echo ready; dd bs=1 count={d} 2>/dev/null | xxd -p", .{read_bytes}, 0);
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", text } });
    errdefer s.deinit();
    if (!hexOf(s, "ready")) return error.NotReady;
    return s;
}

test "scroll: small trackpad steps add up to one wheel event per three rows" {
    // Three calls of one row are one notch, not three events; a program treats one event as about three lines.
    const s = try wheelSession(11);
    defer s.deinit();
    try s.scroll(-1);
    try s.scroll(-1);
    try s.scroll(-1);
    try s.input("Z"); // a marker: nothing but one event may come before it
    try std.testing.expect(hexOf(s, wheel_up_event ++ "5a"));
}

test "scroll: three rows at once is one wheel event" {
    const s = try wheelSession(11);
    defer s.deinit();
    try s.scroll(-3);
    try s.input("Z");
    try std.testing.expect(hexOf(s, wheel_up_event ++ "5a"));
}

test "scroll: a change of direction drops the carried rows" {
    const s = try wheelSession(11);
    defer s.deinit();
    try s.scroll(-2); // two rows toward older output are carried
    try s.scroll(2); // the other way: the carry is dropped, two rows are carried
    try s.scroll(1); // three rows in this direction: one wheel-down event
    try s.input("Z");
    try std.testing.expect(hexOf(s, wheel_down_event ++ "5a"));
}

test "scroll: the carried rows are dropped when tracking turns off" {
    const script = "printf '\\\\033[?1000h\\\\033[?1006h'; stty raw -echo; echo ready; dd bs=1 count=1 2>/dev/null >/dev/null; printf '\\\\033[?1000l'; echo off; sleep 0.3; printf '\\\\033[?1000h'; echo on2; dd bs=1 count=1 2>/dev/null | xxd -p";
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", script } });
    defer s.deinit();
    try std.testing.expect(hexOf(s, "ready"));
    try s.scroll(-2); // carried: two rows
    try s.input("a"); // lets the child go on and turn tracking off
    try std.testing.expect(hexOf(s, "off"));
    try s.scroll(1); // tracking is off: this scrolls the viewport and clears the carry
    try std.testing.expect(hexOf(s, "on2"));
    try s.scroll(-1); // one row carried again; had the old carry survived this would be three rows: an event
    try s.input("Z");
    // The child reads one byte: the marker "5a". Had an event gone out first, it would read 1b (or leftovers of an
    // earlier event, 5b), never 5a.
    try std.testing.expect(hexOf(s, "5a"));
}

const Held = struct {
    s: *Session,
    want: bool,
    fn ok(self: Held) bool {
        return self.s.renderHeld() == self.want;
    }
};

test "synchronized output: no wake during a hold, exactly one when it ends, and the grid holds both parts" {
    var spy: Spy = .{};
    const script = "printf '\\033[?2026h'; printf 'part-one'; sleep 0.5; printf 'part-two'; printf '\\033[?2026l'; sleep 5";
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", script }, .callbacks = spy.callbacks() });
    defer s.deinit();
    try std.testing.expect(waitFor(10_000, Held{ .s = s, .want = true }, Held.ok));
    try std.testing.expect(waitFor(10_000, Row{ .s = s, .want = "part-one", .exact = false }, Row.ok)); // parsed, but held
    try std.testing.expectEqual(@as(u32, 0), spy.wakes.load(.monotonic)); // the view is not told to draw half a frame
    try std.testing.expect(waitFor(10_000, Held{ .s = s, .want = false }, Held.ok));
    try std.testing.expect(waitFor(10_000, Row{ .s = s, .want = "part-onepart-two" }, Row.ok));
    try std.testing.expectEqual(@as(u32, 1), spy.wakes.load(.monotonic)); // one wake, with both parts in the grid
}

test "synchronized output: RIS and resize end a hold and wake the view" {
    var spy: Spy = .{};
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "printf '\\033[?2026h'; echo ready; read x; printf '\\033c'; sleep 5" }, .callbacks = spy.callbacks() });
    defer s.deinit();
    try std.testing.expect(waitFor(10_000, Held{ .s = s, .want = true }, Held.ok));
    try std.testing.expectEqual(@as(u32, 0), spy.wakes.load(.monotonic));
    try s.input("\n"); // the child resets the terminal (RIS)
    try std.testing.expect(waitFor(10_000, Held{ .s = s, .want = false }, Held.ok));
    try std.testing.expectEqual(@as(u32, 1), spy.wakes.load(.monotonic));

    var spy2: Spy = .{};
    const s2 = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "printf '\\033[?2026h'; sleep 5" }, .callbacks = spy2.callbacks() });
    defer s2.deinit();
    try std.testing.expect(waitFor(10_000, Held{ .s = s2, .want = true }, Held.ok));
    try s2.resize(100, 30, 8, 16);
    try std.testing.expect(!s2.renderHeld());
    try std.testing.expectEqual(@as(u32, 1), spy2.wakes.load(.monotonic));
}

test "synchronized output: a flood inside a hold does not deadlock" {
    var spy: Spy = .{};
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "printf '\\033[?2026h'; seq 1 200000; printf '\\033[?2026l'; echo finished; sleep 5" }, .callbacks = spy.callbacks() });
    defer s.deinit();
    try std.testing.expect(waitFor(30_000, Row{ .s = s, .want = "finished" }, Row.ok));
    try std.testing.expect(!s.renderHeld());
    try std.testing.expect(spy.wakes.load(.monotonic) <= 3); // the whole flood was one held frame
}

test "synchronized output: a hold that never ends is released after the deadline and the view is woken" {
    var spy: Spy = .{};
    // opens a hold, draws, and never closes it
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", "printf '\\033[?2026h'; printf 'stuck-frame'; sleep 20" }, .callbacks = spy.callbacks(), .hold_deadline_ms = 300 });
    defer s.deinit();
    try std.testing.expect(waitFor(10_000, Held{ .s = s, .want = true }, Held.ok));
    try std.testing.expectEqual(@as(u32, 0), spy.wakes.load(.monotonic)); // held: nothing yet
    try std.testing.expect(waitFor(5_000, Held{ .s = s, .want = false }, Held.ok)); // the deadline lets go
    try std.testing.expect(waitFor(5_000, Row{ .s = s, .want = "stuck-frame" }, Row.ok));
    try std.testing.expectEqual(@as(u32, 1), spy.wakes.load(.monotonic)); // and the view is told to draw it
}

test "synchronized output: a program that holds again after the deadline is held again" {
    var spy: Spy = .{};
    const script = "printf '\\033[?2026h'; sleep 0.6; printf '\\033[?2026l'; printf '\\033[?2026h'; printf 'second'; sleep 20";
    const s = try Session.start(std.testing.allocator, .{ .argv = &.{ "/bin/sh", "-c", script }, .callbacks = spy.callbacks(), .hold_deadline_ms = 300 });
    defer s.deinit();
    try std.testing.expect(waitFor(10_000, Row{ .s = s, .want = "second" }, Row.ok));
    try std.testing.expect(s.renderHeld()); // a fresh hold started after the first one timed out
}
