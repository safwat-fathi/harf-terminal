//! Harf's configuration: a plain `key = value` text file (default `~/.config/harf/config`), themes as files of the same
//! syntax in `themes/`, and key bindings. Parsing is lenient: a bad line is skipped and reported as a warning, never fatal.
//! The shell reads the result through the C ABI (`harf_config_*`) and applies it; nothing here touches the terminal.
const std = @import("std");
const vt = @import("vt.zig");
const keys = @import("keys.zig");

const Allocator = std.mem.Allocator;
pub const Rgb = vt.Rgb;

fn rgb(v: u24) Rgb {
    return .{ .r = @truncate(v >> 16), .g = @truncate(v >> 8), .b = @truncate(v) };
}

/// Default colors, the cursor color and the 16 ANSI colors a theme sets. The other 240 palette colors stay the terminal's own.
pub const Theme = struct {
    fg: Rgb = vt.theme_fg,
    bg: Rgb = vt.theme_bg,
    cursor: ?Rgb = null,
    palette: [16]?Rgb = @splat(null),
};

/// The colors a config file or theme file sets; whatever it leaves out stays as it was.
const Overlay = struct {
    fg: ?Rgb = null,
    bg: ?Rgb = null,
    cursor: ?Rgb = null,
    palette: [16]?Rgb = @splat(null),

    fn applyTo(self: Overlay, base: Theme) Theme {
        var t = base;
        if (self.fg) |c| t.fg = c;
        if (self.bg) |c| t.bg = c;
        if (self.cursor) |c| t.cursor = c;
        for (self.palette, 0..) |p, i| {
            if (p) |c| t.palette[i] = c;
        }
        return t;
    }
};

const builtin_dark: Theme = .{};
const builtin_light: Theme = blk: {
    var t: Theme = .{ .fg = rgb(0x1f2328), .bg = rgb(0xfafafa), .cursor = rgb(0x1f2328) };
    // the default ANSI colors are chosen for a dark background; these stay readable on a light one
    t.palette[2] = rgb(0x1a7f37);
    t.palette[3] = rgb(0x9a6700);
    t.palette[4] = rgb(0x0550ae);
    t.palette[6] = rgb(0x1b7c83);
    t.palette[7] = rgb(0x57606a);
    t.palette[8] = rgb(0x6e7781);
    t.palette[10] = rgb(0x1a7f37);
    t.palette[11] = rgb(0x7d4e00);
    t.palette[12] = rgb(0x0969da);
    t.palette[14] = rgb(0x1b7c83);
    t.palette[15] = rgb(0x1f2328);
    break :blk t;
};

pub const Action = enum {
    new_window,
    new_tab,
    close,
    split_right,
    split_down,
    focus_next,
    focus_prev,
    next_tab,
    prev_tab,
    goto_tab,
    clear,
    /// Only the visible screen (the scrollback stays); on the alternate screen the key goes to the program.
    clear_view,
    /// Scroll to the previous / next shell prompt (OSC 133); on the alternate screen the key goes to the program.
    prev_prompt,
    next_prompt,
    /// Select the last finished command's output (OSC 133), so Cmd+C copies it.
    select_output,
    /// Select everything, the scrollback included, so Cmd+C copies it.
    select_all,
    /// Move the end of the selection (starting one at the cursor) to the line's start / end, or to the previous / next word edge.
    /// On the alternate screen, or while the program has the kitty keyboard protocol on, the key goes to the program.
    select_line_left,
    select_line_right,
    select_word_left,
    select_word_right,
    /// Ctrl+_ to the shell: readline and zsh undo the last edit of the line.
    undo,
    find,
    find_next,
    find_prev,
    copy,
    paste,
    font_larger,
    font_smaller,
    font_reset,
    reload_config,
    open_config,
    quit,
    send,
    /// Removes a binding (a default one, or an earlier line's).
    none,
};

/// A key and its modifiers (`keys.Mods` bits) bound to an action. `key` is a lowercase character or a name (`left`, `return`,
/// `f5`). `arg` is the tab number for `goto_tab`, the bytes for `send`.
pub const Keybind = struct { mods: u8, key: []const u8, action: Action, arg: []const u8 };

pub const Notifications = enum { unfocused, always, off };

/// `auto`: Harf starts zsh with its OSC 133 shim; `off`: the shell is left alone.
pub const ShellIntegration = enum { auto, off };

/// Where a theme named in the config comes from, other than the two built in. Returns the file's text (allocated with `a`), or
/// null if there is no such theme.
pub const ThemeSource = struct {
    ctx: ?*anyopaque = null,
    read: ?*const fn (ctx: ?*anyopaque, a: Allocator, name: []const u8) ?[]const u8 = null,
};

pub const max_send_bytes = 63;

pub const Config = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    /// The directory the config was read from (empty for a config parsed from text).
    dir: [:0]const u8 = "",
    font_family: [:0]const u8 = "Menlo",
    /// In points.
    font_size: f32 = 14,
    /// Default content size for new windows, in points.
    window_width: f32 = 1000,
    window_height: f32 = 720,
    scrollback_bytes: usize = 1 << 20,
    /// May a program write the clipboard (OSC 52)? Reading is never allowed.
    clipboard_write: bool = true,
    notifications: Notifications = .unfocused,
    shell_integration: ShellIntegration = .auto,
    /// Confirm a paste that would run lines in a program without bracketed paste, or that is very large.
    paste_guard: bool = true,
    /// How Cmd-click on a file path opens it: a URL template, a command template, or `app:<path>`; empty is the default text editor.
    editor: [:0]const u8 = "",
    /// The theme for a dark and for a light system appearance (index 0 and 1), with the file's own colors applied on top.
    themes: [2]Theme = .{ builtin_dark, builtin_dark },
    theme_names: [2][]const u8 = .{ "dark", "dark" },
    keybinds: std.ArrayList(Keybind) = .empty,
    warnings: std.ArrayList([:0]const u8) = .empty,
    overlay: Overlay = .{},

    pub fn deinit(self: *Config) void {
        const gpa = self.gpa;
        self.arena.deinit();
        gpa.destroy(self);
    }

    /// The theme for a dark (true) or light system appearance.
    pub fn theme(self: *const Config, dark: bool) Theme {
        return self.themes[if (dark) 0 else 1];
    }

    fn warn(self: *Config, where: []const u8, line: usize, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const a = self.arena.allocator();
        const msg = try std.fmt.allocPrint(a, fmt, args);
        const full = if (line == 0)
            try std.fmt.allocPrintSentinel(a, "{s}", .{msg}, 0)
        else if (where.len == 0)
            try std.fmt.allocPrintSentinel(a, "line {d}: {s}", .{ line, msg }, 0)
        else
            try std.fmt.allocPrintSentinel(a, "{s}, line {d}: {s}", .{ where, line, msg }, 0);
        try self.warnings.append(a, full);
    }

    /// One `key = value` line of the main config.
    fn setting(self: *Config, line: usize, key: []const u8, value: []const u8) Allocator.Error!void {
        const a = self.arena.allocator();
        if (std.mem.eql(u8, key, "font_family")) {
            if (value.len == 0 or value.len > 128) return self.warn("", line, "font_family needs a font name", .{});
            self.font_family = try std.mem.Allocator.dupeSentinel(a, u8, value, 0);
        } else if (std.mem.eql(u8, key, "font_size")) {
            const v = std.fmt.parseFloat(f32, value) catch 0;
            if (!(v >= 6 and v <= 72)) return self.warn("", line, "font_size must be a number of points from 6 to 72, not '{s}'", .{value});
            self.font_size = v;
        } else if (std.mem.eql(u8, key, "window_width")) {
            const v = std.fmt.parseFloat(f32, value) catch 0;
            if (!(v >= 100 and v <= 16384)) return self.warn("", line, "window_width must be a number of points from 100 to 16384, not '{s}'", .{value});
            self.window_width = v;
        } else if (std.mem.eql(u8, key, "window_height")) {
            const v = std.fmt.parseFloat(f32, value) catch 0;
            if (!(v >= 100 and v <= 16384)) return self.warn("", line, "window_height must be a number of points from 100 to 16384, not '{s}'", .{value});
            self.window_height = v;
        } else if (std.mem.eql(u8, key, "scrollback_bytes")) {
            self.scrollback_bytes = std.fmt.parseInt(usize, value, 10) catch return self.warn("", line, "scrollback_bytes must be a whole number, not '{s}'", .{value});
        } else if (std.mem.eql(u8, key, "clipboard_write")) {
            if (std.mem.eql(u8, value, "allow")) self.clipboard_write = true else if (std.mem.eql(u8, value, "deny")) self.clipboard_write = false else try self.warn("", line, "clipboard_write is allow or deny, not '{s}'", .{value});
        } else if (std.mem.eql(u8, key, "notifications")) {
            self.notifications = std.meta.stringToEnum(Notifications, value) orelse return self.warn("", line, "notifications is unfocused, always or off, not '{s}'", .{value});
        } else if (std.mem.eql(u8, key, "editor")) {
            if (value.len > 256) return self.warn("", line, "editor is at most 256 bytes", .{});
            self.editor = try std.mem.Allocator.dupeSentinel(a, u8, value, 0);
        } else if (std.mem.eql(u8, key, "paste_guard")) {
            if (std.mem.eql(u8, value, "on")) self.paste_guard = true else if (std.mem.eql(u8, value, "off")) self.paste_guard = false else try self.warn("", line, "paste_guard is on or off, not '{s}'", .{value});
        } else if (std.mem.eql(u8, key, "shell_integration")) {
            self.shell_integration = std.meta.stringToEnum(ShellIntegration, value) orelse return self.warn("", line, "shell_integration is auto or off, not '{s}'", .{value});
        } else if (std.mem.eql(u8, key, "theme")) {
            try self.themeSetting(line, value);
        } else if (std.mem.eql(u8, key, "keybind")) {
            try self.keybind(line, value);
        } else switch (colorSetting(&self.overlay, key, value)) {
            .ok => {},
            .bad => try self.warn("", line, "'{s}' is not a color for {s} (write #rrggbb)", .{ value, key }),
            .not_a_color => try self.warn("", line, "unknown setting '{s}'", .{key}),
        }
    }

    /// `theme = NAME`, or `theme = dark:NAME, light:NAME` to follow the system appearance.
    fn themeSetting(self: *Config, line: usize, value: []const u8) Allocator.Error!void {
        const a = self.arena.allocator();
        var names: [2][]const u8 = .{ "dark", "dark" };
        if (std.mem.indexOfScalar(u8, value, ':') == null) {
            if (!safeName(value)) return self.warn("", line, "'{s}' is not a theme name", .{value});
            names = .{ try a.dupe(u8, value), try a.dupe(u8, value) };
        } else {
            var parts = std.mem.splitScalar(u8, value, ',');
            while (parts.next()) |part| {
                const p = std.mem.trim(u8, part, " \t");
                const colon = std.mem.indexOfScalar(u8, p, ':') orelse return self.warn("", line, "theme: expected dark:NAME, light:NAME", .{});
                const which = std.mem.trim(u8, p[0..colon], " \t");
                const name = std.mem.trim(u8, p[colon + 1 ..], " \t");
                if (!safeName(name)) return self.warn("", line, "'{s}' is not a theme name", .{name});
                if (std.mem.eql(u8, which, "dark")) names[0] = try a.dupe(u8, name) else if (std.mem.eql(u8, which, "light")) names[1] = try a.dupe(u8, name) else return self.warn("", line, "theme: '{s}' is not dark or light", .{which});
            }
        }
        self.theme_names = names;
    }

    /// `keybind = cmd+shift+t = new_tab`. The separator is the first `=` that is not itself the key (`cmd+=`).
    fn keybind(self: *Config, line: usize, value: []const u8) Allocator.Error!void {
        var sep: ?usize = null;
        for (value, 0..) |ch, i| {
            if (ch == '=' and (i == 0 or value[i - 1] != '+')) {
                sep = i;
                break;
            }
        }
        const at = sep orelse return self.warn("", line, "keybind: expected 'keybind = trigger = action'", .{});
        const trigger = std.mem.trim(u8, value[0..at], " \t");
        const action_text = std.mem.trim(u8, value[at + 1 ..], " \t");
        const a = self.arena.allocator();
        const t = (try parseTrigger(a, trigger)) orelse return self.warn("", line, "keybind: '{s}' is not a key (like cmd+shift+t, option+left, f5)", .{trigger});
        const act = (try parseAction(a, action_text)) orelse return self.warn("", line, "keybind: '{s}' is not an action (or its argument is wrong; send is limited to {d} bytes)", .{ action_text, max_send_bytes });
        var i: usize = 0;
        while (i < self.keybinds.items.len) {
            const k = self.keybinds.items[i];
            if (k.mods == t.mods and std.mem.eql(u8, k.key, t.key)) _ = self.keybinds.orderedRemove(i) else i += 1;
        }
        if (act.action != .none) try self.keybinds.append(a, .{ .mods = t.mods, .key = t.key, .action = act.action, .arg = act.arg });
    }

    fn applyLines(self: *Config, text: []const u8) Allocator.Error!void {
        var n: usize = 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            n += 1;
            const l = std.mem.trim(u8, raw, " \t\r");
            if (l.len == 0 or l[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, l, '=') orelse {
                try self.warn("", n, "expected 'key = value'", .{});
                continue;
            };
            try self.setting(n, std.mem.trim(u8, l[0..eq], " \t"), std.mem.trim(u8, l[eq + 1 ..], " \t"));
        }
    }

    /// Resolves one theme name to colors, with the config file's own color settings on top.
    fn resolveTheme(self: *Config, name: []const u8, source: ThemeSource) Allocator.Error!Theme {
        const a = self.arena.allocator();
        var base: Theme = builtin_dark;
        if (std.mem.eql(u8, name, "dark")) {
            base = builtin_dark;
        } else if (std.mem.eql(u8, name, "light")) {
            base = builtin_light;
        } else if (source.read) |read| {
            if (read(source.ctx, a, name)) |text| {
                var o: Overlay = .{};
                var n: usize = 0;
                var lines = std.mem.splitScalar(u8, text, '\n');
                while (lines.next()) |raw| {
                    n += 1;
                    const l = std.mem.trim(u8, raw, " \t\r");
                    if (l.len == 0 or l[0] == '#') continue;
                    const eq = std.mem.indexOfScalar(u8, l, '=') orelse continue;
                    const key = std.mem.trim(u8, l[0..eq], " \t");
                    const where = try std.fmt.allocPrint(a, "theme '{s}'", .{name});
                    switch (colorSetting(&o, key, std.mem.trim(u8, l[eq + 1 ..], " \t"))) {
                        .ok => {},
                        .bad => try self.warn(where, n, "'{s}' is not a color for {s}", .{ l[eq + 1 ..], key }),
                        .not_a_color => try self.warn(where, n, "unknown setting '{s}' (a theme sets foreground, background, cursor_color and palette)", .{key}),
                    }
                }
                base = o.applyTo(builtin_dark);
            } else {
                try self.warn("", 0, "theme '{s}' not found; using dark", .{name});
            }
        } else {
            try self.warn("", 0, "theme '{s}' is not a built-in theme (dark, light)", .{name});
        }
        return self.overlay.applyTo(base);
    }
};

/// Parses config text. A line that cannot be used is skipped and listed in `warnings`; only running out of memory fails.
pub fn parse(gpa: Allocator, text: []const u8, source: ThemeSource) Allocator.Error!*Config {
    const self = try gpa.create(Config);
    errdefer gpa.destroy(self);
    self.* = .{ .gpa = gpa, .arena = .init(gpa) };
    errdefer self.arena.deinit();
    try self.applyLines(default_keybinds);
    try self.applyLines(text);
    self.themes[0] = try self.resolveTheme(self.theme_names[0], source);
    self.themes[1] = if (std.mem.eql(u8, self.theme_names[0], self.theme_names[1])) self.themes[0] else try self.resolveTheme(self.theme_names[1], source);
    return self;
}

/// Reads `<dir>/config` (a missing file is an empty config) and the themes in `<dir>/themes/`.
pub fn load(gpa: Allocator, dir: []const u8) Allocator.Error!*Config {
    var path_buf: [1024]u8 = undefined;
    const text: []u8 = if (std.fmt.bufPrintSentinel(&path_buf, "{s}/config", .{dir}, 0)) |path| readFile(gpa, path) orelse &.{} else |_| &.{};
    defer if (text.len > 0) gpa.free(text);
    var source: DirSource = .{ .dir = dir };
    const cfg = try parse(gpa, text, .{ .ctx = &source, .read = readTheme });
    cfg.dir = try std.mem.Allocator.dupeSentinel(cfg.arena.allocator(), u8, dir, 0);
    return cfg;
}

const DirSource = struct { dir: []const u8 };

fn readTheme(ctx: ?*anyopaque, a: Allocator, name: []const u8) ?[]const u8 {
    const src: *DirSource = @ptrCast(@alignCast(ctx.?));
    if (!safeName(name)) return null;
    var buf: [1200]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&buf, "{s}/themes/{s}", .{ src.dir, name }, 0) catch return null;
    return readFile(a, path);
}

pub fn safeName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or name[0] == '.') return false;
    for (name) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '_' or ch == '-')) return false;
    return true;
}

fn readFile(gpa: Allocator, path: [:0]const u8) ?[]u8 {
    const fd = std.c.open(path.ptr, .{});
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (out.items.len < (1 << 20)) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n <= 0) break;
        out.appendSlice(gpa, buf[0..@intCast(n)]) catch {
            out.deinit(gpa);
            return null;
        };
    }
    return out.toOwnedSlice(gpa) catch null;
}

pub const SetKeyError = error{ InvalidValue, OutOfMemory };

/// Whether `line` is an uncommented `key = ...` setting line (spacing around the key and `=` is free).
fn isSettingLine(line: []const u8, key: []const u8) bool {
    const t = std.mem.trimStart(u8, line, " \t");
    if (!std.mem.startsWith(u8, t, key)) return false;
    const rest = std.mem.trimStart(u8, t[key.len..], " \t");
    return rest.len > 0 and rest[0] == '=';
}

/// `text` with the setting `key` set to `value`: every uncommented `key = ...` line is rewritten in place, and when there is none a
/// `key = value` line is added at the end. Comments and every other line stay as they are. A value with a line break is refused
/// (it would put a second setting in the file). The caller frees the result.
pub fn setKey(gpa: Allocator, text: []const u8, key: []const u8, value: []const u8) SetKeyError![]u8 {
    if (std.mem.indexOfAny(u8, value, "\r\n") != null) return error.InvalidValue;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var found = false;
    var first = true;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!first) try out.append(gpa, '\n');
        first = false;
        if (isSettingLine(line, key)) {
            found = true;
            try out.print(gpa, "{s} = {s}", .{ key, value });
        } else try out.appendSlice(gpa, line);
    }
    if (!found) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(gpa, '\n');
        try out.print(gpa, "{s} = {s}\n", .{ key, value });
    }
    return out.toOwnedSlice(gpa);
}

/// `setKey` on the config file at `path` (created if missing). The new text is written beside the file and renamed over it, so a
/// reader (the config watcher) never sees half a file.
pub fn setKeyInFile(gpa: Allocator, path: [:0]const u8, key: []const u8, value: []const u8) !void {
    // A config that is a symlink (a dotfiles repo) is changed where it points, and stays a link; the file keeps its mode.
    var real_buf: [1100]u8 = undefined;
    const real: [:0]const u8 = if (realpath(path.ptr, &real_buf)) |r| std.mem.span(r) else path;
    var st: std.c.Stat = undefined;
    const have_mode = std.c.stat(real.ptr, &st) == 0;
    const old = readFile(gpa, real);
    defer if (old) |o| gpa.free(o);
    const text = try setKey(gpa, old orelse "", key, value);
    defer gpa.free(text);
    var tmp_buf: [1100]u8 = undefined;
    const tmp = try std.fmt.bufPrintSentinel(&tmp_buf, "{s}.harf-tmp", .{real}, 0);
    writeFile(tmp, text) catch |e| {
        _ = std.c.unlink(tmp.ptr);
        return e;
    };
    if (have_mode) _ = std.c.chmod(tmp.ptr, @intCast(st.mode & 0o7777));
    if (std.c.rename(tmp.ptr, real.ptr) != 0) {
        _ = std.c.unlink(tmp.ptr);
        return error.CannotWrite;
    }
}

extern "c" fn realpath(noalias path: [*:0]const u8, noalias resolved: [*]u8) ?[*:0]u8;

const ColorResult = enum { ok, bad, not_a_color };

/// foreground, background, cursor_color or `palette = N=#rrggbb` (N from 0 to 15).
fn colorSetting(o: *Overlay, key: []const u8, value: []const u8) ColorResult {
    if (std.mem.eql(u8, key, "foreground")) return setColor(&o.fg, value);
    if (std.mem.eql(u8, key, "background")) return setColor(&o.bg, value);
    if (std.mem.eql(u8, key, "cursor_color")) return setColor(&o.cursor, value);
    if (std.mem.eql(u8, key, "palette")) {
        const eq = std.mem.indexOfScalar(u8, value, '=') orelse return .bad;
        const n = std.fmt.parseInt(usize, std.mem.trim(u8, value[0..eq], " \t"), 10) catch return .bad;
        if (n >= 16) return .bad;
        return setColor(&o.palette[n], std.mem.trim(u8, value[eq + 1 ..], " \t"));
    }
    return .not_a_color;
}

fn setColor(dst: *?Rgb, value: []const u8) ColorResult {
    dst.* = parseColor(value) orelse return .bad;
    return .ok;
}

/// `#rrggbb` or `rrggbb`.
pub fn parseColor(text: []const u8) ?Rgb {
    const t = if (text.len > 0 and text[0] == '#') text[1..] else text;
    if (t.len != 6) return null;
    const v = std.fmt.parseInt(u24, t, 16) catch return null;
    return rgb(v);
}

const Trigger = struct { mods: u8, key: []const u8 };

const named_keys = [_][]const u8{ "left", "right", "up", "down", "return", "tab", "escape", "backspace", "delete", "space", "home", "end", "pageup", "pagedown", "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12" };

fn canonicalKey(a: Allocator, text: []const u8) Allocator.Error!?[]const u8 {
    var low_buf: [16]u8 = undefined;
    if (text.len == 0 or text.len > low_buf.len) return null;
    const low = std.ascii.lowerString(&low_buf, text);
    const alias: []const u8 = if (std.mem.eql(u8, low, "enter")) "return" else if (std.mem.eql(u8, low, "esc")) "escape" else low;
    for (named_keys) |k| if (std.mem.eql(u8, alias, k)) return try a.dupe(u8, k);
    // anything else must be one printable character
    const n = std.unicode.utf8CountCodepoints(text) catch return null;
    if (n != 1 or text[0] <= ' ') return null;
    return try a.dupe(u8, if (text.len == 1) low else text);
}

/// `cmd+shift+t`, `option+left`, `cmd+=`, `cmd++`.
fn parseTrigger(a: Allocator, text: []const u8) Allocator.Error!?Trigger {
    var key_text: []const u8 = undefined;
    var mod_text: []const u8 = "";
    if (std.mem.eql(u8, text, "+")) {
        key_text = "+";
    } else if (std.mem.endsWith(u8, text, "++")) {
        key_text = "+";
        mod_text = text[0 .. text.len - 2];
    } else if (std.mem.lastIndexOfScalar(u8, text, '+')) |i| {
        key_text = text[i + 1 ..];
        mod_text = text[0..i];
    } else {
        key_text = text;
    }
    var mods: u8 = 0;
    if (mod_text.len > 0) {
        var it = std.mem.splitScalar(u8, mod_text, '+');
        while (it.next()) |m| {
            var low: [12]u8 = undefined;
            if (m.len > low.len) return null;
            const name = std.ascii.lowerString(&low, std.mem.trim(u8, m, " \t"));
            if (std.mem.eql(u8, name, "cmd") or std.mem.eql(u8, name, "command") or std.mem.eql(u8, name, "super")) {
                mods |= @intCast(keys.Mods.super);
            } else if (std.mem.eql(u8, name, "ctrl") or std.mem.eql(u8, name, "control")) {
                mods |= @intCast(keys.Mods.ctrl);
            } else if (std.mem.eql(u8, name, "alt") or std.mem.eql(u8, name, "option") or std.mem.eql(u8, name, "opt")) {
                mods |= @intCast(keys.Mods.alt);
            } else if (std.mem.eql(u8, name, "shift")) {
                mods |= @intCast(keys.Mods.shift);
            } else return null;
        }
    }
    const key = (try canonicalKey(a, std.mem.trim(u8, key_text, " \t"))) orelse return null;
    return .{ .mods = mods, .key = key };
}

const ParsedAction = struct { action: Action, arg: []const u8 };

fn parseAction(a: Allocator, text: []const u8) Allocator.Error!?ParsedAction {
    const colon = std.mem.indexOfScalar(u8, text, ':');
    const name = if (colon) |i| text[0..i] else text;
    const arg = if (colon) |i| text[i + 1 ..] else "";
    const action: Action = if (std.mem.eql(u8, name, "unbind")) .none else std.meta.stringToEnum(Action, name) orelse return null;
    switch (action) {
        .send => {
            const bytes = (try unescape(a, arg)) orelse return null;
            if (bytes.len == 0 or bytes.len > max_send_bytes) return null;
            return .{ .action = .send, .arg = bytes };
        },
        .goto_tab => {
            const n = std.fmt.parseInt(u8, arg, 10) catch return null;
            if (n < 1 or n > 9) return null;
            return .{ .action = .goto_tab, .arg = try a.dupe(u8, arg) };
        },
        else => {
            if (colon != null) return null;
            return .{ .action = action, .arg = "" };
        },
    }
}

/// `\e` `\n` `\r` `\t` `\\` and `\xNN` in a `send:` text; anything else after a backslash is taken as written.
fn unescape(a: Allocator, text: []const u8) Allocator.Error!?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '\\' or i + 1 >= text.len) {
            try out.append(a, text[i]);
            continue;
        }
        i += 1;
        switch (text[i]) {
            'e' => try out.append(a, 0x1b),
            'n' => try out.append(a, '\n'),
            'r' => try out.append(a, '\r'),
            't' => try out.append(a, '\t'),
            '\\' => try out.append(a, '\\'),
            'x' => {
                if (i + 2 >= text.len) return null; // two hex digits must follow
                try out.append(a, std.fmt.parseInt(u8, text[i + 1 .. i + 3], 16) catch return null);
                i += 2;
            },
            else => |ch| try out.append(a, ch),
        }
    }
    return out.items;
}

/// The file "Open Config" creates when there is none: every setting, commented out, at its default.
pub const template =
    \\# Harf configuration. One `key = value` per line; `#` starts a comment. The file is read again as soon as it is saved.
    \\
    \\# A monospaced font installed on this Mac, and its size in points.
    \\# font_family = Menlo
    \\# font_size = 14
    \\
    \\# Default content size for new windows, in points.
    \\# window_width = 1000
    \\# window_height = 720
    \\
    \\# dark, light, or the name of a file in ~/.config/harf/themes/ (it holds foreground, background, cursor_color and palette lines).
    \\# `dark:NAME, light:NAME` follows the system appearance.
    \\# theme = dark
    \\# theme = dark:dark, light:light
    \\
    \\# Colors written over the theme: #rrggbb. palette is ANSI colors 0 to 15, as `palette = 1=#ff5555`.
    \\# foreground = #ebebeb
    \\# background = #0f0f12
    \\# cursor_color = #ebebeb
    \\
    \\# Scrollback for new windows, in bytes (about 1,000 rows at 80 columns per megabyte).
    \\# scrollback_bytes = 1048576
    \\
    \\# May a program set the clipboard (OSC 52)? Only while this window is in front. allow or deny. Reading it is never allowed.
    \\# clipboard_write = allow
    \\
    \\# Notifications a program asks for (OSC 9, OSC 777): unfocused (only when you are not looking at the terminal), always, or off.
    \\# notifications = unfocused
    \\
    \\# Shell integration: auto starts your zsh with marks for prompts and commands (OSC 133), which Cmd+Up/Down, Cmd+Shift+A and the
    \\# running marker on a tab use; off leaves your shell alone. It applies to windows, tabs and panes you open afterwards.
    \\# shell_integration = auto
    \\
    \\# Paste guard: on asks before a paste that would run lines in a program without bracketed paste (a line break, as if typed) or that
    \\# is over 100,000 bytes; off never asks.
    \\# paste_guard = on
    \\
    \\# Editor for Cmd-click on a file name in the output (`path`, `path:line` or `path:line:col`). {path}, {line} and {col} are filled
    \\# in (line and col are 1 when the text has none). A URL template opens through the system; a command runs without a shell;
    \\# app:<path to an .app> opens the file in that app, with no line number. With none set the file opens in the default text editor.
    \\# editor = vscode://file{path}:{line}:{col}
    \\# editor = code --goto {path}:{line}:{col}
    \\# editor = app:/Applications/Sublime Text.app
    \\
    \\# Key bindings: keybind = trigger = action. Triggers are modifiers (cmd, ctrl, option, shift) and a key, joined with +:
    \\# cmd+t, option+left, cmd+shift+d, f5, cmd+]. Your lines replace the default for the same trigger; `unbind` removes it.
    \\# Actions: new_window new_tab close split_right split_down focus_next focus_prev next_tab prev_tab goto_tab:N clear clear_view prev_prompt next_prompt select_output select_all
    \\# select_line_left select_line_right select_word_left select_word_right undo find find_next find_prev copy paste font_larger font_smaller font_reset reload_config open_config quit
    \\# and send:TEXT (up to 63 bytes, with \e \n \r \t \\ \xNN) to type something into the program.
    \\# keybind = cmd+t = new_tab
    \\# keybind = cmd+w = unbind
    \\# keybind = option+left = send:\e[1;3D
    \\
;

pub const default_keybinds =
    \\keybind = cmd+n = new_window
    \\keybind = cmd+t = new_tab
    \\keybind = cmd+w = close
    \\keybind = cmd+d = split_right
    \\keybind = cmd+shift+d = split_down
    \\keybind = cmd+] = focus_next
    \\keybind = cmd+[ = focus_prev
    \\keybind = cmd+shift+] = next_tab
    \\keybind = cmd+shift+[ = prev_tab
    \\keybind = cmd+1 = goto_tab:1
    \\keybind = cmd+2 = goto_tab:2
    \\keybind = cmd+3 = goto_tab:3
    \\keybind = cmd+4 = goto_tab:4
    \\keybind = cmd+5 = goto_tab:5
    \\keybind = cmd+6 = goto_tab:6
    \\keybind = cmd+7 = goto_tab:7
    \\keybind = cmd+8 = goto_tab:8
    \\keybind = cmd+9 = goto_tab:9
    \\keybind = cmd+k = clear
    \\keybind = ctrl+l = clear_view
    \\keybind = cmd+up = prev_prompt
    \\keybind = cmd+down = next_prompt
    \\keybind = cmd+shift+a = select_output
    \\keybind = cmd+a = select_all
    \\keybind = cmd+shift+left = select_line_left
    \\keybind = cmd+shift+right = select_line_right
    \\keybind = option+shift+left = select_word_left
    \\keybind = option+shift+right = select_word_right
    \\keybind = cmd+z = undo
    \\keybind = cmd+f = find
    \\keybind = cmd+g = find_next
    \\keybind = cmd+shift+g = find_prev
    \\keybind = cmd+c = copy
    \\keybind = cmd+v = paste
    \\keybind = cmd+= = font_larger
    \\keybind = cmd+shift+= = font_larger
    \\keybind = cmd+- = font_smaller
    \\keybind = cmd+0 = font_reset
    \\keybind = cmd+, = open_config
    \\keybind = cmd+shift+, = reload_config
    \\keybind = cmd+q = quit
;

// ---- tests ----

const testing = std.testing;
const super: u8 = @intCast(keys.Mods.super);
const shift: u8 = @intCast(keys.Mods.shift);
const alt: u8 = @intCast(keys.Mods.alt);

fn find(c: *const Config, mods: u8, key: []const u8) ?Keybind {
    for (c.keybinds.items) |k| if (k.mods == mods and std.mem.eql(u8, k.key, key)) return k;
    return null;
}

fn parseOwned(text: []const u8) !*Config {
    return parse(testing.allocator, text, .{});
}

test "the defaults parse without a warning and bind the shell's shortcuts" {
    const c = try parseOwned("");
    defer c.deinit();
    try testing.expectEqual(@as(usize, 0), c.warnings.items.len);
    try testing.expectEqual(Action.new_tab, find(c, super, "t").?.action);
    try testing.expectEqual(Action.split_down, find(c, super | shift, "d").?.action);
    try testing.expectEqual(Action.prev_tab, find(c, super | shift, "[").?.action);
    try testing.expectEqual(Action.font_larger, find(c, super, "=").?.action);
    const nine = find(c, super, "9").?;
    try testing.expectEqual(Action.goto_tab, nine.action);
    try testing.expectEqualStrings("9", nine.arg);
    try testing.expectEqual(Action.reload_config, find(c, super | shift, ",").?.action);
    try testing.expectEqual(Action.clear_view, find(c, @intCast(keys.Mods.ctrl), "l").?.action);
    try testing.expectEqual(Action.prev_prompt, find(c, super, "up").?.action);
    try testing.expectEqual(Action.next_prompt, find(c, super, "down").?.action);
    try testing.expectEqual(Action.select_output, find(c, super | shift, "a").?.action);
    try testing.expectEqual(Action.select_all, find(c, super, "a").?.action);
    try testing.expectEqual(Action.select_line_left, find(c, super | shift, "left").?.action);
    try testing.expectEqual(Action.select_line_right, find(c, super | shift, "right").?.action);
    try testing.expectEqual(Action.select_word_left, find(c, alt | shift, "left").?.action);
    try testing.expectEqual(Action.select_word_right, find(c, alt | shift, "right").?.action);
    try testing.expectEqual(Action.undo, find(c, super, "z").?.action);
    try testing.expectEqual(ShellIntegration.auto, c.shell_integration);
    // nothing is bound to the editing keys the core already maps (Option+arrows, Cmd+arrows)
    try testing.expect(find(c, alt, "left") == null);
    try testing.expect(find(c, super, "left") == null);
}

test "settings" {
    const c = try parseOwned(
        \\# a comment
        \\font_family = Monaco
        \\font_size = 16.5
        \\window_width = 1000
        \\window_height = 650
        \\scrollback_bytes = 2097152
        \\clipboard_write = deny
        \\notifications = always
        \\shell_integration = off
        \\paste_guard = off
        \\editor = vscode://file{path}:{line}:{col}
    );
    defer c.deinit();
    try testing.expectEqualStrings("vscode://file{path}:{line}:{col}", c.editor);
    try testing.expectEqual(ShellIntegration.off, c.shell_integration);
    try testing.expect(!c.paste_guard);
    try testing.expectEqual(@as(usize, 0), c.warnings.items.len);
    try testing.expectEqualStrings("Monaco", c.font_family);
    try testing.expectEqual(@as(f32, 16.5), c.font_size);
    try testing.expectEqual(@as(f32, 1000), c.window_width);
    try testing.expectEqual(@as(f32, 650), c.window_height);
    try testing.expectEqual(@as(usize, 2097152), c.scrollback_bytes);
    try testing.expect(!c.clipboard_write);
    try testing.expectEqual(Notifications.always, c.notifications);
    const d = try parseOwned("");
    defer d.deinit();
    try testing.expectEqualStrings("Menlo", d.font_family);
    try testing.expectEqual(@as(f32, 1000), d.window_width);
    try testing.expectEqual(@as(f32, 720), d.window_height);
    try testing.expect(d.clipboard_write);
    try testing.expectEqual(Notifications.unfocused, d.notifications);
    try testing.expect(d.paste_guard);
    try testing.expectEqualStrings("", d.editor);
}

test "an editor template longer than 256 bytes is a warning and changes nothing" {
    var text: [300]u8 = undefined;
    @memcpy(text[0..9], "editor = ");
    @memset(text[9..], 'x');
    const c = try parseOwned(&text);
    defer c.deinit();
    try testing.expectEqualStrings("", c.editor);
    try testing.expectEqual(@as(usize, 1), c.warnings.items.len);
}

test "a bad line is a warning with its line number, and the rest still applies" {
    const c = try parseOwned("font_size = 3\nnonsense\nunknown_key = 1\nforeground = red\nbackground = #102030\nclipboard_write = maybe\nfont_size = 15");
    defer c.deinit();
    try testing.expectEqual(@as(usize, 5), c.warnings.items.len);
    try testing.expect(std.mem.startsWith(u8, c.warnings.items[0], "line 1: font_size must be"));
    try testing.expect(std.mem.startsWith(u8, c.warnings.items[1], "line 2: expected 'key = value'"));
    try testing.expect(std.mem.startsWith(u8, c.warnings.items[2], "line 3: unknown setting 'unknown_key'"));
    try testing.expectEqual(@as(f32, 15), c.font_size);
    try testing.expectEqual(Rgb{ .r = 0x10, .g = 0x20, .b = 0x30 }, c.theme(true).bg);
}

test "window_width and window_height reject out-of-range or non-numeric values" {
    const c = try parseOwned("window_width = 50\nwindow_height = 20000\nwindow_width = nope\nwindow_height = NaN");
    defer c.deinit();
    try testing.expectEqual(@as(usize, 4), c.warnings.items.len);
    try testing.expectEqual(@as(f32, 1000), c.window_width);
    try testing.expectEqual(@as(f32, 720), c.window_height);
}

const FakeThemes = struct {
    fn read(_: ?*anyopaque, a: Allocator, name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, name, "solar")) return a.dupe(u8, "foreground = #839496\nbackground = #002b36\npalette = 1=#dc322f\npalette = 99=#000000\n") catch null;
        return null;
    }
};

test "themes: built in, from a file, and the config's own colors on top" {
    const src: ThemeSource = .{ .read = FakeThemes.read };
    const light = try parse(testing.allocator, "theme = light", src);
    defer light.deinit();
    try testing.expectEqual(builtin_light.bg, light.theme(true).bg);
    try testing.expectEqual(builtin_light.bg, light.theme(false).bg);

    const both = try parse(testing.allocator, "theme = dark:solar, light:light\nbackground = #111111", src);
    defer both.deinit();
    // the theme file's colors, then the config file's `background` over them
    try testing.expectEqual(Rgb{ .r = 0x83, .g = 0x94, .b = 0x96 }, both.theme(true).fg);
    try testing.expectEqual(Rgb{ .r = 0x11, .g = 0x11, .b = 0x11 }, both.theme(true).bg);
    try testing.expectEqual(Rgb{ .r = 0xdc, .g = 0x32, .b = 0x2f }, both.theme(true).palette[1].?);
    try testing.expectEqual(builtin_light.fg, both.theme(false).fg);
    // the theme file's bad line (palette 99) is a warning that names the theme
    try testing.expectEqual(@as(usize, 1), both.warnings.items.len);
    try testing.expect(std.mem.startsWith(u8, both.warnings.items[0], "theme 'solar', line 4"));

    const missing = try parse(testing.allocator, "theme = nope", src);
    defer missing.deinit();
    try testing.expectEqual(builtin_dark.bg, missing.theme(true).bg);
    try testing.expectEqual(@as(usize, 1), missing.warnings.items.len);
}

test "theme names that could leave the themes directory are refused" {
    for ([_][]const u8{ "../x", "a/b", ".hidden", "" }) |bad| try testing.expect(!safeName(bad));
    try testing.expect(safeName("solarized-dark_2.0"));
    const c = try parseOwned("theme = ../../etc/passwd");
    defer c.deinit();
    try testing.expectEqual(@as(usize, 1), c.warnings.items.len);
    try testing.expectEqualStrings("dark", c.theme_names[0]);
}

test "keybinds: override, unbind, send with escapes, and keys that are themselves + or =" {
    const c = try parseOwned(
        \\keybind = cmd+t = new_window
        \\keybind = cmd+w = unbind
        \\keybind = option+left = send:\e[1;3D
        \\keybind = cmd+shift+x = send:a\x01\\\n
        \\keybind = ctrl+f5 = goto_tab:3
        \\keybind = cmd++ = font_larger
        \\keybind = cmd+Return = split_right
        \\keybind = cmd+i = goto_tab:12
        \\keybind = cmd+j = send:\xZZ
        \\keybind = cmd+y = launch_missiles
    );
    defer c.deinit();
    try testing.expectEqual(Action.new_window, find(c, super, "t").?.action);
    try testing.expect(find(c, super, "w") == null);
    const left = find(c, alt, "left").?;
    try testing.expectEqual(Action.send, left.action);
    try testing.expectEqualStrings("\x1b[1;3D", left.arg);
    try testing.expectEqualStrings("a\x01\\\n", find(c, super | shift, "x").?.arg);
    try testing.expectEqual(Action.goto_tab, find(c, @intCast(keys.Mods.ctrl), "f5").?.action);
    try testing.expectEqual(Action.font_larger, find(c, super, "+").?.action);
    try testing.expectEqual(Action.split_right, find(c, super, "return").?.action);
    // goto_tab:12, a bad escape and an unknown action are warnings, not bindings
    try testing.expect(find(c, super, "i") == null and find(c, super, "j") == null and find(c, super, "y") == null);
    try testing.expectEqual(@as(usize, 3), c.warnings.items.len);
}

test "send is limited, so a binding cannot hold a megabyte" {
    var long: [200]u8 = undefined;
    @memset(&long, 'a');
    const text = try std.fmt.allocPrint(testing.allocator, "keybind = cmd+j = send:{s}", .{long[0..64]});
    defer testing.allocator.free(text);
    const c = try parseOwned(text);
    defer c.deinit();
    try testing.expect(find(c, super, "j") == null);
    try testing.expectEqual(@as(usize, 1), c.warnings.items.len);
}

fn writeFile(path: [:0]const u8, text: []const u8) !void {
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o644));
    if (fd < 0) return error.CannotWrite;
    defer _ = std.c.close(fd);
    if (std.c.write(fd, text.ptr, text.len) != text.len) return error.CannotWrite;
}

test "setKey rewrites the setting in place, keeps comments, and adds it when it is missing" {
    const a = testing.allocator;
    const one = try setKey(a, "font_size = 15\n# editor = old\neditor = x\n", "editor", "y");
    defer a.free(one);
    try testing.expectEqualStrings("font_size = 15\n# editor = old\neditor = y\n", one); // the comment is not the setting
    const two = try setKey(a, "font_size = 15\n# editor = old\n", "editor", "y");
    defer a.free(two);
    try testing.expectEqualStrings("font_size = 15\n# editor = old\neditor = y\n", two);
    const three = try setKey(a, "a = 1", "editor", "y"); // no trailing newline: one is added before the new line
    defer a.free(three);
    try testing.expectEqualStrings("a = 1\neditor = y\n", three);
    const four = try setKey(a, "", "editor", "y");
    defer a.free(four);
    try testing.expectEqualStrings("editor = y\n", four);
    const five = try setKey(a, "editor_x = 1\n  editor=  old  \n", "editor", "y"); // another key is not this one; spacing is free
    defer a.free(five);
    try testing.expectEqualStrings("editor_x = 1\neditor = y\n", five);
    try testing.expectError(error.InvalidValue, setKey(a, "", "editor", "a\nb")); // a value must not smuggle in another setting
    try testing.expectError(error.InvalidValue, setKey(a, "", "editor", "a\rb"));
}

test "setKeyInFile creates the file, then rewrites the line" {
    const tmp = if (std.c.getenv("TMPDIR")) |d| std.mem.trimEnd(u8, std.mem.span(d), "/") else "/tmp";
    var path_buf: [300]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "{s}/harf-setkey-test-{d}", .{ tmp, std.c.getpid() }, 0);
    defer _ = std.c.unlink(path.ptr);
    try setKeyInFile(testing.allocator, path, "editor", "first");
    const a = readFile(testing.allocator, path).?;
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("editor = first\n", a);
    try setKeyInFile(testing.allocator, path, "editor", "second");
    const b = readFile(testing.allocator, path).?;
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("editor = second\n", b);
}

test "setKeyInFile writes through a symlink and keeps it, and keeps the file's mode" {
    const tmp = if (std.c.getenv("TMPDIR")) |d| std.mem.trimEnd(u8, std.mem.span(d), "/") else "/tmp";
    var target_buf: [300]u8 = undefined;
    const target = try std.fmt.bufPrintSentinel(&target_buf, "{s}/harf-setkey-target-{d}", .{ tmp, std.c.getpid() }, 0);
    var link_buf: [300]u8 = undefined;
    const link = try std.fmt.bufPrintSentinel(&link_buf, "{s}/harf-setkey-link-{d}", .{ tmp, std.c.getpid() }, 0);
    defer _ = std.c.unlink(target.ptr);
    defer _ = std.c.unlink(link.ptr);
    try writeFile(target, "font_size = 15\n");
    _ = std.c.chmod(target.ptr, 0o600);
    try testing.expectEqual(@as(c_int, 0), std.c.symlink(target.ptr, link.ptr)); // a dotfiles repo's config
    try setKeyInFile(testing.allocator, link, "editor", "x");
    var rl_buf: [300]u8 = undefined;
    try testing.expect(std.c.readlink(link.ptr, &rl_buf, rl_buf.len) > 0); // still a link
    const through = readFile(testing.allocator, target).?; // and the file it points to is the one that changed
    defer testing.allocator.free(through);
    try testing.expectEqualStrings("font_size = 15\neditor = x\n", through);
    var st: std.c.Stat = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.stat(target.ptr, &st));
    try testing.expectEqual(@as(u32, 0o600), @as(u32, st.mode) & 0o777);
}

test "load reads config and themes from a directory, and a missing directory is an empty config" {
    const tmp = if (std.c.getenv("TMPDIR")) |d| std.mem.trimEnd(u8, std.mem.span(d), "/") else "/tmp";
    var dir_buf: [256]u8 = undefined;
    const dir = try std.fmt.bufPrintSentinel(&dir_buf, "{s}/harf-config-test-{d}", .{ tmp, std.c.getpid() }, 0);
    _ = std.c.mkdir(dir.ptr, 0o755);
    var themes_buf: [300]u8 = undefined;
    const themes = try std.fmt.bufPrintSentinel(&themes_buf, "{s}/themes", .{dir}, 0);
    _ = std.c.mkdir(themes.ptr, 0o755);
    var cfg_buf: [300]u8 = undefined;
    const cfg_path = try std.fmt.bufPrintSentinel(&cfg_buf, "{s}/config", .{dir}, 0);
    var th_buf: [300]u8 = undefined;
    const th_path = try std.fmt.bufPrintSentinel(&th_buf, "{s}/themes/mine", .{dir}, 0);
    defer {
        _ = std.c.unlink(cfg_path.ptr);
        _ = std.c.unlink(th_path.ptr);
        _ = std.c.rmdir(themes.ptr);
        _ = std.c.rmdir(dir.ptr);
    }
    try writeFile(cfg_path, "font_size = 18\ntheme = mine\n");
    try writeFile(th_path, "background = #0a0b0c\n");
    const c = try load(testing.allocator, dir);
    defer c.deinit();
    try testing.expectEqual(@as(usize, 0), c.warnings.items.len);
    try testing.expectEqual(@as(f32, 18), c.font_size);
    try testing.expectEqual(Rgb{ .r = 0x0a, .g = 0x0b, .b = 0x0c }, c.theme(true).bg);
    try testing.expectEqualStrings(dir, c.dir);

    const none = try load(testing.allocator, "/nonexistent/harf/dir");
    defer none.deinit();
    try testing.expectEqual(@as(usize, 0), none.warnings.items.len);
    try testing.expectEqual(@as(f32, 14), none.font_size);
}

test "every example line of the template is valid once uncommented" {
    var live: std.ArrayList(u8) = .empty;
    defer live.deinit(testing.allocator);
    var lines = std.mem.splitScalar(u8, template, '\n');
    var examples: usize = 0;
    while (lines.next()) |l| {
        if (!std.mem.startsWith(u8, l, "# ")) continue;
        const rest = l[2..];
        for ([_][]const u8{ "font_family = ", "font_size = ", "window_width = ", "window_height = ", "theme = ", "foreground = ", "background = ", "cursor_color = ", "scrollback_bytes = ", "clipboard_write = ", "notifications = ", "shell_integration = ", "paste_guard = ", "editor = ", "keybind = " }) |k| {
            if (std.mem.startsWith(u8, rest, k)) {
                try live.appendSlice(testing.allocator, rest);
                try live.append(testing.allocator, '\n');
                examples += 1;
            }
        }
    }
    try testing.expect(examples >= 10);
    const c = try parseOwned(live.items);
    defer c.deinit();
    for (c.warnings.items) |w| std.debug.print("template warning: {s}\n", .{w});
    try testing.expectEqual(@as(usize, 0), c.warnings.items.len);
}
