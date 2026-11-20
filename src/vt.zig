//! Thin Zig wrapper over libghostty-vt's C API (parser, screen, scrollback, cells).
//! The grid is in logical order: one cell per character, combining marks inside their base cell.
//! Not thread-safe; callers serialize access (see term.zig).
const std = @import("std");
pub const c = @import("ghostty_c");

/// Events the terminal raises while parsing. They run inside `Terminal.write` on the caller's
/// thread and must not call `write` on the same terminal.
pub const Callbacks = struct {
    ctx: ?*anyopaque = null,
    /// Bytes the terminal wants sent to the child (answers to queries such as cursor position).
    write_pty: ?*const fn (ctx: ?*anyopaque, data: []const u8) void = null,
    bell: ?*const fn (ctx: ?*anyopaque) void = null,
    /// The new title is already readable with `Terminal.title`.
    title_changed: ?*const fn (ctx: ?*anyopaque) void = null,
    /// The program started (`true`) or ended (`false`) a render hold (synchronized output, mode 2026). Runs
    /// inside `write` (and `resize`) with the caller's lock held: set a flag, nothing more.
    render_hold: ?*const fn (ctx: ?*anyopaque, held: bool) void = null,
    /// A program wrote text to the system clipboard (OSC 52) and the policy allowed it. Runs inside `write`.
    clipboard_write: ?*const fn (ctx: ?*anyopaque, text: []const u8) void = null,
    /// A program asked for a desktop notification (OSC 9, OSC 777). Both strings are untrusted program text.
    notify: ?*const fn (ctx: ?*anyopaque, title: []const u8, body: []const u8) void = null,
    /// A shell integration step (OSC 133). `exit_code` is set for `command_end` when the shell sent one. The command line and
    /// error text the sequence may carry are never passed on (untrusted). Runs inside `write` with the caller's lock held.
    command: ?*const fn (ctx: ?*anyopaque, kind: CommandKind, exit_code: ?i32) void = null,
};

/// The most columns `pathAt` and `urlAt` look at in a row.
const max_link_cols = 512;

pub const LinkKind = enum { hyperlink, url, path };

/// A link under a cell and the columns (inclusive) it covers on its row.
pub const LinkSpan = struct { kind: LinkKind, row: u16, lo: u16, hi: u16 };

/// The cells of a run `tokenAt` found, as UTF-8 text, and where in the text each column's cell starts.
const Token = struct {
    text: []const u8,
    click: usize,
    lo: usize,
    hi: usize,
    offs: [max_link_cols]u16,
    spacer: [max_link_cols]bool,

    /// The first and last column that hold bytes `start` to `end` (exclusive) of `text`; a wide character counts both its columns.
    fn columns(self: *const Token, start: usize, end: usize) struct { lo: u16, hi: u16 } {
        var first = self.lo;
        var last = self.lo;
        var i = self.lo;
        while (i <= self.hi) : (i += 1) {
            const off = self.offs[i - self.lo];
            if (off <= start) first = i;
            if (off <= end - 1) last = i;
            if (off > end - 1) break;
        }
        while (last + 1 <= self.hi and self.spacer[last + 1 - self.lo]) last += 1;
        return .{ .lo = @intCast(first), .hi = @intCast(last) };
    }
};

/// Where a file path is: the line and column a `:12:5` suffix names (0 when absent) and how many bytes of the caller's buffer it fills.
pub const PathRef = struct { len: usize, line: u32, col: u32 };

fn pathBoundary(cp: u21) bool {
    return switch (cp) {
        ' ', '\t', '"', '\'', '`', '<', '>', '(', ')', '[', ']', '{', '}', '|', ',', ';' => true,
        else => false,
    };
}

fn urlBoundary(cp: u21) bool {
    return switch (cp) {
        ' ', '\t', '"', '\'', '`', '<', '>' => true,
        else => false,
    };
}

/// Where the URL that starts at `start` in `text` (at an `http://` or `https://`) ends, exclusive: at a space, quote or angle
/// bracket, minus trailing punctuation and any closing bracket with no opening one inside the URL. Null if only the scheme is left.
fn urlEndFrom(text: []const u8, start: usize) ?usize {
    var end = start;
    while (end < text.len and !urlBoundary(text[end])) end += 1;
    var url = text[start..end];
    while (url.len > 0) {
        const last = url[url.len - 1];
        if (std.mem.indexOfScalar(u8, ".,;:!?", last) != null) {
            url = url[0 .. url.len - 1];
            continue;
        }
        if (last == ')' or last == ']' or last == '}') {
            const open: u8 = switch (last) {
                ')' => '(',
                ']' => '[',
                else => '{',
            };
            if (std.mem.count(u8, url, &.{last}) > std.mem.count(u8, url, &.{open})) {
                url = url[0 .. url.len - 1];
                continue;
            }
        }
        break;
    }
    const scheme_len: usize = if (startsWithNoCase(url, "https://")) 8 else 7;
    if (url.len <= scheme_len) return null;
    return start + url.len;
}

/// Colors the plain `http://` and `https://` URLs in a row of cells (found the way `urlAt` finds one): cells whose foreground is
/// the default get `color`, and cells with no underline get a single one. Whatever a program styled itself is left alone. A function of
/// the row's text and styles only, so the painter's row hash needs no change. Cells past `max_link_cols` are not looked at.
pub fn markUrls(cells: []Cell, color: Rgb) void {
    const n_cells = @min(cells.len, max_link_cols);
    // most rows have no "://": find out before building anything
    var has = false;
    for (0..n_cells) |i| {
        if (i + 2 >= n_cells) break;
        if (cells[i].cps.len == 1 and cells[i].cps[0] == ':' and cells[i + 1].cps.len == 1 and cells[i + 1].cps[0] == '/' and cells[i + 2].cps.len == 1 and cells[i + 2].cps[0] == '/') {
            has = true;
            break;
        }
    }
    if (!has) return;
    var bytes: [max_link_cols * 4]u8 = undefined;
    var starts: [max_link_cols]u16 = undefined; // where each cell's text starts in `bytes`
    var n: usize = 0;
    for (0..n_cells) |i| {
        starts[i] = @intCast(n);
        const cell = cells[i];
        if (cell.cps.len == 0) {
            if (cell.wide != .spacer_tail and cell.wide != .spacer_head and n < bytes.len) {
                bytes[n] = ' '; // a blank cell ends a URL
                n += 1;
            }
            continue;
        }
        for (cell.cps) |cp| {
            const len = std.unicode.utf8CodepointSequenceLength(cp) catch continue;
            if (n + len > bytes.len) break;
            _ = std.unicode.utf8Encode(cp, bytes[n..]) catch continue;
            n += len;
        }
    }
    const underline_one: u16 = @as(u16, 1) << c.GHOSTTY_STYLE_UNDERLINE_SHIFT;
    const underline_mask: u16 = @as(u16, 7) << c.GHOSTTY_STYLE_UNDERLINE_SHIFT;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, bytes[0..n], from, "://")) |k| {
        from = k + 3;
        const start: usize = if (k >= 5 and std.ascii.eqlIgnoreCase(bytes[k - 5 .. k], "https")) k - 5 else if (k >= 4 and std.ascii.eqlIgnoreCase(bytes[k - 4 .. k], "http")) k - 4 else continue;
        const end = urlEndFrom(bytes[0..n], start) orelse continue;
        var prev_inside = false;
        for (0..n_cells) |i| {
            const spacer = cells[i].wide == .spacer_tail or cells[i].wide == .spacer_head;
            const inside = if (spacer) prev_inside else starts[i] >= start and starts[i] < end;
            prev_inside = inside;
            if (!inside) continue;
            if (cells[i].style.fg == null) cells[i].style.fg = color;
            if (cells[i].style.underline() == .none) cells[i].style.flags = (cells[i].style.flags & ~underline_mask) | underline_one;
        }
        from = end;
    }
}

/// The URL a click at byte `click` of `text` is on, found the way `markUrls` colors them: scheme starts are taken in order and each URL
/// runs to its `urlEndFrom`, so a URL inside another URL is part of the outer one. Null if the click is on no URL.
fn urlExtent(text: []const u8, click: usize) ?struct { start: usize, end: usize } {
    var i: usize = 0;
    while (i < text.len) {
        if (startsWithNoCase(text[i..], "https://") or startsWithNoCase(text[i..], "http://")) {
            if (urlEndFrom(text, i)) |end| {
                if (click < end) return if (click >= i) .{ .start = i, .end = end } else null;
                i = end;
                continue;
            }
        }
        i += 1;
    }
    return null;
}

fn startsWithNoCase(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

/// `rest:123` split into `rest` and 123: a colon and one to nine digits at the end, with something before the colon.
fn splitNumber(s: []const u8) ?struct { rest: []const u8, num: u32 } {
    var i = s.len;
    while (i > 0 and std.ascii.isDigit(s[i - 1])) i -= 1;
    if (i == s.len or s.len - i > 9 or i < 2 or s[i - 1] != ':') return null;
    return .{ .rest = s[0 .. i - 1], .num = std.fmt.parseInt(u32, s[i..], 10) catch return null };
}

/// A paste over this many bytes is confirmed first (see `Terminal.pasteRisk`).
pub const large_paste_bytes: usize = 100_000;

/// Why a paste should be confirmed before it is sent.
pub const PasteRisk = struct { runs_lines: bool, large: bool };

pub const CommandKind = enum { prompt_start, input_start, output_start, command_end };

pub const Rgb = struct { r: u8, g: u8, b: u8 };

/// What the terminal answers to XTVERSION (CSI > q). Keep the number in step with build.zig.zon.
pub const xtversion = "Harf 0.4.4";

/// Harf's default colors (the slice 2 theme): foreground 0.92, background (0.06, 0.06, 0.07).
pub const theme_fg: Rgb = .{ .r = 235, .g = 235, .b = 235 };
pub const theme_bg: Rgb = .{ .r = 15, .g = 15, .b = 18 };

/// Text attributes and colors of one cell. Colors are resolved (palette indices looked up); null
/// means "the terminal default".
pub const Style = struct {
    fg: ?Rgb = null,
    bg: ?Rgb = null,
    underline_color: ?Rgb = null,
    /// The library's flag bits: the `Flag` values, with the underline style in bits 8 to 10.
    flags: u16 = 0,

    pub const Flag = struct {
        pub const bold: u16 = c.GHOSTTY_STYLE_FLAG_BOLD;
        pub const italic: u16 = c.GHOSTTY_STYLE_FLAG_ITALIC;
        pub const faint: u16 = c.GHOSTTY_STYLE_FLAG_FAINT;
        pub const blink: u16 = c.GHOSTTY_STYLE_FLAG_BLINK;
        pub const inverse: u16 = c.GHOSTTY_STYLE_FLAG_INVERSE;
        pub const invisible: u16 = c.GHOSTTY_STYLE_FLAG_INVISIBLE;
        pub const strikethrough: u16 = c.GHOSTTY_STYLE_FLAG_STRIKETHROUGH;
        pub const overline: u16 = c.GHOSTTY_STYLE_FLAG_OVERLINE;
    };
    pub const Underline = enum { none, single, double, curly, dotted, dashed };

    pub fn underline(self: Style) Underline {
        return switch ((self.flags >> c.GHOSTTY_STYLE_UNDERLINE_SHIFT) & 7) {
            1 => .single,
            2 => .double,
            3 => .curly,
            4 => .dotted,
            5 => .dashed,
            else => .none,
        };
    }
};

/// The terminal's default colors as of the last `update`.
pub const Colors = struct { fg: Rgb, bg: Rgb, cursor: ?Rgb };

pub const Options = struct {
    default_fg: Rgb = theme_fg,
    default_bg: Rgb = theme_bg,
    cols: u16 = 80,
    rows: u16 = 24,
    /// libghostty keeps history in whole pages, so this is a limit to within about 400 KB.
    scrollback_bytes: usize = 1 << 20,
    callbacks: Callbacks = .{},
    /// May a program write the clipboard (OSC 52)? Reading it is never allowed.
    allow_clipboard_write: bool = true,
};

pub const Error = error{ OutOfMemory, Ghostty };

pub const KeyAction = enum(u8) { press = 0, release = 1, repeat = 2 };

pub const Wide = enum { narrow, wide, spacer_tail, spacer_head };

/// One grid cell: its codepoints (base plus combining marks) and its width role.
/// `match`: part of a find match in view (see `Terminal.findSet`). The current match is also `selected`.
pub const Cell = struct { cps: []const u21, wide: Wide, style: Style = .{}, selected: bool = false, match: bool = false };

/// Columns `c0` to `c1` (inclusive) of viewport row `row` are part of a find match.
const MatchRange = struct { row: u16, c0: u16, c1: u16 };

fn toCColor(rgb: Rgb) c.GhosttyColorRgb {
    return .{ .r = rgb.r, .g = rgb.g, .b = rgb.b };
}

fn check(r: c.GhosttyResult) Error!void {
    if (r == c.GHOSTTY_SUCCESS) return;
    if (r == c.GHOSTTY_OUT_OF_MEMORY) return error.OutOfMemory;
    return error.Ghostty;
}

fn writePtyTrampoline(_: c.GhosttyTerminal, ud: ?*anyopaque, data: [*c]const u8, len: usize) callconv(.c) void {
    const self: *Terminal = @ptrCast(@alignCast(ud.?));
    if (self.callbacks.write_pty) |f| f(self.callbacks.ctx, data[0..len]);
}

fn bellTrampoline(_: c.GhosttyTerminal, ud: ?*anyopaque) callconv(.c) void {
    const self: *Terminal = @ptrCast(@alignCast(ud.?));
    if (self.callbacks.bell) |f| f(self.callbacks.ctx);
}

fn renderHoldTrampoline(_: c.GhosttyTerminal, ud: ?*anyopaque, held: bool) callconv(.c) void {
    const self: *Terminal = @ptrCast(@alignCast(ud.?));
    if (self.callbacks.render_hold) |f| f(self.callbacks.ctx, held);
}

/// XTVERSION: the library's own answer would be "libghostty".
fn xtversionTrampoline(_: c.GhosttyTerminal, _: ?*anyopaque) callconv(.c) c.GhosttyString {
    return .{ .ptr = xtversion.ptr, .len = xtversion.len };
}

/// XTWINOPS size queries (CSI 14, 16, 18, 19 t). Unanswered (false) until a resize has told us the cell size in pixels.
fn sizeTrampoline(_: c.GhosttyTerminal, ud: ?*anyopaque, out: *c.GhosttySizeReportSize) callconv(.c) bool {
    const self: *Terminal = @ptrCast(@alignCast(ud.?));
    if (self.cell_px[0] == 0 or self.cell_px[1] == 0) return false;
    const sz = self.size();
    out.* = .{ .rows = sz.rows, .columns = sz.cols, .cell_width = self.cell_px[0], .cell_height = self.cell_px[1] };
    return true;
}

/// Most bytes of an OSC 52 write that reach the clipboard.
const max_clipboard_write = 1 << 20;

fn replyClipboard(w: *const c.GhosttyClipboardWrite, result: c.GhosttyClipboardWriteResult) void {
    var reply = std.mem.zeroes(c.GhosttyClipboardWriteReply);
    reply.size = @sizeOf(c.GhosttyClipboardWriteReply);
    reply.result = result;
    if (w.reply) |f| f(w, &reply);
}

/// OSC 52 (and the library's other clipboard writes): the plain-text representation goes to the callback when the
/// policy allows, for the standard clipboard only. Anything else is answered as refused.
fn clipboardWriteTrampoline(_: c.GhosttyTerminal, ud: ?*anyopaque, w: [*c]const c.GhosttyClipboardWrite) callconv(.c) void {
    const self: *Terminal = @ptrCast(@alignCast(ud.?));
    const req: *const c.GhosttyClipboardWrite = @ptrCast(w);
    if (!self.allow_clipboard_write) return replyClipboard(req, c.GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED);
    if (req.location != c.GHOSTTY_CLIPBOARD_LOCATION_STANDARD) return replyClipboard(req, c.GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED);
    var i: usize = 0;
    while (i < req.contents_len) : (i += 1) {
        const item = req.contents[i];
        if (item.mime.len < 10 or !std.mem.eql(u8, item.mime.ptr[0..10], "text/plain")) continue;
        if (item.data.len > max_clipboard_write) return replyClipboard(req, c.GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED);
        if (self.callbacks.clipboard_write) |f| f(self.callbacks.ctx, item.data.ptr[0..item.data.len]);
        return replyClipboard(req, c.GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS);
    }
    replyClipboard(req, c.GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED);
}

/// Text from a program that will be shown outside the terminal (a notification): control characters, line and paragraph
/// separators and the bidi embeddings and overrides that can make one string read as another are dropped (newline and tab
/// become a space), and the result is cut at `out.len` bytes on a character boundary. Arabic and the direction marks stay.
pub fn cleanText(out: []u8, in: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < in.len) {
        const len = std.unicode.utf8ByteSequenceLength(in[i]) catch {
            i += 1;
            continue;
        };
        if (i + len > in.len) break;
        var cp = std.unicode.utf8Decode(in[i..][0..len]) catch {
            i += 1;
            continue;
        };
        const start = i;
        i += len;
        if (cp == '\n' or cp == '\t') cp = ' ';
        if (cp < 0x20 or (cp >= 0x7f and cp < 0xa0) or cp == 0x2028 or cp == 0x2029 or (cp >= 0x202a and cp <= 0x202e) or cp == 0xfeff) continue;
        if (cp == ' ' and len == 1) {
            if (n >= out.len) break;
            out[n] = ' ';
            n += 1;
            continue;
        }
        if (n + len > out.len) break;
        @memcpy(out[n..][0..len], in[start..][0..len]);
        n += len;
    }
    return out[0..n];
}

fn notificationTrampoline(_: c.GhosttyTerminal, ud: ?*anyopaque, n: [*c]const c.GhosttyTerminalDesktopNotification) callconv(.c) void {
    const self: *Terminal = @ptrCast(@alignCast(ud.?));
    const f = self.callbacks.notify orelse return;
    var title_buf: [128]u8 = undefined;
    var body_buf: [256]u8 = undefined;
    const title = cleanText(&title_buf, if (n.*.title.len == 0) "" else n.*.title.ptr[0..n.*.title.len]);
    const body = cleanText(&body_buf, if (n.*.body.len == 0) "" else n.*.body.ptr[0..n.*.body.len]);
    f(self.callbacks.ctx, title, body);
}

fn semanticPromptTrampoline(_: c.GhosttyTerminal, ud: ?*anyopaque, ev: [*c]const c.GhosttyTerminalSemanticPrompt) callconv(.c) void {
    const self: *Terminal = @ptrCast(@alignCast(ud.?));
    const f = self.callbacks.command orelse return;
    const kind: CommandKind = switch (ev.*.kind) {
        c.GHOSTTY_SEMANTIC_PROMPT_PROMPT_START => .prompt_start,
        c.GHOSTTY_SEMANTIC_PROMPT_INPUT_START => .input_start,
        c.GHOSTTY_SEMANTIC_PROMPT_OUTPUT_START => .output_start,
        c.GHOSTTY_SEMANTIC_PROMPT_COMMAND_END => .command_end,
        else => return, // a kind from a later library version
    };
    f(self.callbacks.ctx, kind, if (ev.*.has_exit_code) ev.*.exit_code else null);
}

fn colorSchemeTrampoline(_: c.GhosttyTerminal, ud: ?*anyopaque, out: *c.GhosttyColorScheme) callconv(.c) bool {
    const self: *Terminal = @ptrCast(@alignCast(ud.?));
    out.* = if (self.dark_scheme) c.GHOSTTY_COLOR_SCHEME_DARK else c.GHOSTTY_COLOR_SCHEME_LIGHT;
    return true;
}

fn titleTrampoline(_: c.GhosttyTerminal, ud: ?*anyopaque) callconv(.c) void {
    const self: *Terminal = @ptrCast(@alignCast(ud.?));
    if (self.callbacks.title_changed) |f| f(self.callbacks.ctx);
}

pub const Terminal = struct {
    gpa: std.mem.Allocator,
    callbacks: Callbacks,
    handle: c.GhosttyTerminal,
    render_state: c.GhosttyRenderState,
    row_iter: c.GhosttyRenderStateRowIterator,
    row_cells: c.GhosttyRenderStateRowCells,
    key_encoder: c.GhosttyKeyEncoder,
    key_event: c.GhosttyKeyEvent,
    /// Where a left press began (column and screen row), for the drag that follows; null between gestures.
    sel_anchor: ?struct { x: u16, y: u32 } = null,
    /// The pointer left the press cell, so a one-cell selection is now wanted.
    sel_dragged: bool = false,
    /// Clicks in the gesture's press: 1 drags by character, 2 by word, 3 or more by line.
    sel_clicks: u8 = 1,
    /// True when the current click sequence started by extending an existing selection (Shift+click),
    /// so repeat clicks keep extending instead of replacing it, and unit drags keep `sel_anchor` fixed.
    sel_extending: bool = false,
    /// A selection exists as of the last `update` (cells ask whether they are in it only then).
    selection_active: bool = false,
    mouse_encoder: c.GhosttyMouseEncoder,
    mouse_event: c.GhosttyMouseEvent,
    allow_clipboard_write: bool = true,
    /// The find in progress, if any (Cmd+F); freed with the terminal.
    search: c.GhosttySearch = null,
    /// Where the matches in view are, as of the last `update` (empty without a find).
    match_ranges: std.ArrayList(MatchRange) = .empty,
    /// The row `selectRow` last chose, so `cellInRow` can tell whether a cell is in a match.
    row_index: u16 = 0,
    /// The library's own 256-color palette, read once: a theme sets 16 of its colors over it.
    builtin_palette: [256]c.GhosttyColorRgb = undefined,
    /// The system appearance the program is told about (CSI ? 996 n, mode 2031).
    dark_scheme: bool = true,
    /// One cell in pixels (width, height) as of the last `resize`; 0 until then.
    cell_px: [2]u32 = .{ 0, 0 },
    /// Colors as of the last `update`.
    palette: [256]Rgb = @splat(.{ .r = 0, .g = 0, .b = 0 }),
    default_colors: Colors = .{ .fg = theme_fg, .bg = theme_bg, .cursor = null },

    pub fn init(gpa: std.mem.Allocator, opts: Options) Error!*Terminal {
        const self = try gpa.create(Terminal);
        errdefer gpa.destroy(self);
        // `create` applies no field defaults; this literal does, and the handles below are set one by one.
        self.* = .{
            .gpa = gpa,
            .callbacks = opts.callbacks,
            .allow_clipboard_write = opts.allow_clipboard_write,
            .handle = undefined,
            .render_state = undefined,
            .row_iter = undefined,
            .row_cells = undefined,
            .key_encoder = undefined,
            .key_event = undefined,
            .mouse_encoder = undefined,
            .mouse_event = undefined,
        };
        try check(c.ghostty_terminal_new(null, &self.handle, opts.cols, opts.rows));
        errdefer c.ghostty_terminal_free(self.handle);
        // Callback options take the function pointer (or the userdata pointer) itself as the value.
        try check(c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_USERDATA, @as(?*const anyopaque, self)));
        try check(c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_WRITE_PTY, @as(?*const anyopaque, @ptrCast(&writePtyTrampoline))));
        try check(c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_BELL, @as(?*const anyopaque, @ptrCast(&bellTrampoline))));
        try check(c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, @as(?*const anyopaque, @ptrCast(&titleTrampoline))));
        try check(c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_RENDER_HOLD, @as(?*const anyopaque, @ptrCast(&renderHoldTrampoline))));
        try check(c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, @as(?*const anyopaque, @ptrCast(&clipboardWriteTrampoline))));
        try check(c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION, @as(?*const anyopaque, @ptrCast(&notificationTrampoline))));
        try check(c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT, @as(?*const anyopaque, @ptrCast(&semanticPromptTrampoline))));
        try check(c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_COLOR_SCHEME, @as(?*const anyopaque, @ptrCast(&colorSchemeTrampoline))));
        try check(c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, &self.builtin_palette));
        try check(c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_XTVERSION, @as(?*const anyopaque, @ptrCast(&xtversionTrampoline))));
        try check(c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_SIZE, @as(?*const anyopaque, @ptrCast(&sizeTrampoline))));
        var fg: c.GhosttyColorRgb = .{ .r = opts.default_fg.r, .g = opts.default_fg.g, .b = opts.default_fg.b };
        var bg: c.GhosttyColorRgb = .{ .r = opts.default_bg.r, .g = opts.default_bg.g, .b = opts.default_bg.b };
        try check(c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg));
        try check(c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg));
        var scrollback = opts.scrollback_bytes;
        try check(c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &scrollback));
        // Kitty graphics are compiled in but not wanted in v1: a zero limit stores no images.
        var image_limit: u64 = 0;
        try check(c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &image_limit));
        try check(c.ghostty_render_state_new(null, &self.render_state));
        errdefer c.ghostty_render_state_free(self.render_state);
        try check(c.ghostty_render_state_row_iterator_new(null, &self.row_iter));
        errdefer c.ghostty_render_state_row_iterator_free(self.row_iter);
        try check(c.ghostty_render_state_row_cells_new(null, &self.row_cells));
        errdefer c.ghostty_render_state_row_cells_free(self.row_cells);
        try check(c.ghostty_key_encoder_new(null, &self.key_encoder));
        errdefer c.ghostty_key_encoder_free(self.key_encoder);
        try check(c.ghostty_key_event_new(null, &self.key_event));
        errdefer c.ghostty_key_event_free(self.key_event);
        try check(c.ghostty_mouse_encoder_new(null, &self.mouse_encoder));
        errdefer c.ghostty_mouse_encoder_free(self.mouse_encoder);
        try check(c.ghostty_mouse_event_new(null, &self.mouse_event));
        return self;
    }

    pub fn deinit(self: *Terminal) void {
        self.findEnd();
        self.match_ranges.deinit(self.gpa);
        c.ghostty_mouse_event_free(self.mouse_event);
        c.ghostty_mouse_encoder_free(self.mouse_encoder);
        c.ghostty_key_event_free(self.key_event);
        c.ghostty_key_encoder_free(self.key_encoder);
        c.ghostty_render_state_row_cells_free(self.row_cells);
        c.ghostty_render_state_row_iterator_free(self.row_iter);
        c.ghostty_render_state_free(self.render_state);
        c.ghostty_terminal_free(self.handle);
        self.gpa.destroy(self);
    }

    /// Feeds bytes from the child (escape sequences and text) to the parser.
    pub fn write(self: *Terminal, bytes: []const u8) void {
        c.ghostty_terminal_vt_write(self.handle, bytes.ptr, bytes.len);
    }

    /// Refreshes the render state from the terminal. Call once per frame, before `selectRow`,
    /// `cellInRow` and `cursor`. False on failure.
    pub fn update(self: *Terminal) bool {
        if (c.ghostty_render_state_update(self.render_state, self.handle) != c.GHOSTTY_SUCCESS) return false;
        self.selection_active = self.hasSelection();
        var rc = std.mem.zeroes(c.GhosttyRenderStateColors);
        rc.size = @sizeOf(c.GhosttyRenderStateColors);
        if (c.ghostty_render_state_get(self.render_state, c.GHOSTTY_RENDER_STATE_DATA_COLORS, &rc) == c.GHOSTTY_SUCCESS) {
            self.default_colors = .{
                .fg = .{ .r = rc.foreground.r, .g = rc.foreground.g, .b = rc.foreground.b },
                .bg = .{ .r = rc.background.r, .g = rc.background.g, .b = rc.background.b },
                .cursor = if (rc.cursor_has_value) .{ .r = rc.cursor.r, .g = rc.cursor.g, .b = rc.cursor.b } else null,
            };
            for (rc.palette, 0..) |p, i| self.palette[i] = .{ .r = p.r, .g = p.g, .b = p.b };
        }
        self.refreshMatches();
        return true;
    }

    /// Reads the find's matches that are in view (after catching the search up with the terminal, so output and scrolling are
    /// seen). A match that runs past an edge of the view is clipped to it, and one that wraps covers each row it touches.
    fn refreshMatches(self: *Terminal) void {
        self.match_ranges.clearRetainingCapacity();
        if (self.search == null) return;
        _ = c.ghostty_search_feed(self.search);
        var probe = std.mem.zeroes(c.GhosttySelectionBuffer);
        _ = c.ghostty_search_get(self.search, c.GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES, &probe); // too small by design: it says how many
        if (probe.len == 0) return;
        const list = self.gpa.alloc(c.GhosttySelection, probe.len) catch return;
        defer self.gpa.free(list);
        var buf: c.GhosttySelectionBuffer = .{ .ptr = list.ptr, .cap = list.len, .len = 0 };
        if (c.ghostty_search_get(self.search, c.GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES, &buf) != c.GHOSTTY_SUCCESS) return;
        const sz = self.size();
        for (list[0..buf.len]) |sel| {
            var a = std.mem.zeroes(c.GhosttyPointCoordinate);
            var b = std.mem.zeroes(c.GhosttyPointCoordinate);
            const has_a = c.ghostty_terminal_point_from_grid_ref(self.handle, &sel.start, c.GHOSTTY_POINT_TAG_VIEWPORT, &a) == c.GHOSTTY_SUCCESS;
            const has_b = c.ghostty_terminal_point_from_grid_ref(self.handle, &sel.end, c.GHOSTTY_POINT_TAG_VIEWPORT, &b) == c.GHOSTTY_SUCCESS;
            if (!has_a and !has_b) continue; // the page holds it but it is not in view
            const first: u32 = if (has_a) a.y else 0;
            const last: u32 = if (has_b) b.y else sz.rows - 1;
            var row = first;
            while (row <= last and row < sz.rows) : (row += 1) {
                const c0: u16 = if (row == first and has_a) a.x else 0;
                const c1: u16 = if (row == last and has_b) b.x else sz.cols - 1;
                self.match_ranges.append(self.gpa, .{ .row = @intCast(row), .c0 = c0, .c1 = c1 }) catch return;
            }
        }
    }

    fn inMatch(self: *const Terminal, col: u16) bool {
        for (self.match_ranges.items) |m| if (m.row == self.row_index and col >= m.c0 and col <= m.c1) return true;
        return false;
    }

    /// The default colors as of the last `update`.
    pub fn colors(self: *const Terminal) Colors {
        return self.default_colors;
    }

    /// Palette entry `i` as of the last `update`.
    pub fn paletteColor(self: *const Terminal, i: u8) Rgb {
        return self.palette[i];
    }

    /// Points `row_cells` at the cells of visible row `row` of the last `update`. False if the row does not exist.
    pub fn selectRow(self: *Terminal, row: u16) bool {
        if (c.ghostty_render_state_get(self.render_state, c.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, @ptrCast(&self.row_iter)) != c.GHOSTTY_SUCCESS) return false;
        var i: u32 = 0;
        while (i <= row) : (i += 1) {
            if (!c.ghostty_render_state_row_iterator_next(self.row_iter)) return false;
        }
        if (c.ghostty_render_state_row_get(self.row_iter, c.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, @ptrCast(&self.row_cells)) != c.GHOSTTY_SUCCESS) return false;
        self.row_index = row;
        return true;
    }

    /// The cell at `col` of the row chosen by `selectRow`; blank if `col` is out of range.
    pub fn cellInRow(self: *Terminal, col: u16, buf: *[16]u21) Cell {
        const blank: Cell = .{ .cps = buf[0..0], .wide = .narrow };
        if (c.ghostty_render_state_row_cells_select(self.row_cells, col) != c.GHOSTTY_SUCCESS) return blank;
        var read = self.readCell(buf);
        read.match = self.inMatch(col);
        return read;
    }

    pub const CursorShape = enum { bar, block, underline, block_hollow };
    pub const Cursor = struct { col: u16, row: u16, visible: bool, shape: CursorShape = .block, color: ?Rgb = null };

    /// The cursor of the last `update`; null when it is outside the viewport.
    pub fn cursor(self: *Terminal) ?Cursor {
        var has: bool = false;
        _ = c.ghostty_render_state_get(self.render_state, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &has);
        if (!has) return null;
        var x: u16 = 0;
        var y: u16 = 0;
        var vis: bool = true;
        _ = c.ghostty_render_state_get(self.render_state, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &x);
        _ = c.ghostty_render_state_get(self.render_state, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &y);
        _ = c.ghostty_render_state_get(self.render_state, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &vis);
        var style: c.GhosttyCursorStyle = c.GHOSTTY_CURSOR_STYLE_BLOCK;
        _ = c.ghostty_render_state_get(self.render_state, c.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &style);
        const shape: CursorShape = switch (style) {
            c.GHOSTTY_CURSOR_STYLE_BAR => .bar,
            c.GHOSTTY_CURSOR_STYLE_UNDERLINE => .underline,
            c.GHOSTTY_CURSOR_STYLE_BLOCK_HOLLOW => .block_hollow,
            else => .block,
        };
        return .{ .col = x, .row = y, .visible = vis, .shape = shape, .color = self.default_colors.cursor };
    }

    /// The bytes a key press sends to the child, for the terminal's current modes (application
    /// cursor keys, kitty flags). `mods` uses the bits of `keys.Mods`; `utf8` is the text the
    /// platform produced for the event (may be empty). Empty result: nothing to send.
    /// `unshifted` is the layout's character for the key with no modifiers (0 if unknown); the kitty
    /// protocol names a key by it. A private-use or control value (AppKit's for arrows) is ignored.
    pub fn encodeKey(self: *Terminal, key: c.GhosttyKey, mods: u32, utf8: []const u8, unshifted: u21, action: KeyAction, out: []u8) []const u8 {
        _ = c.ghostty_key_encoder_set_from_terminal(self.key_encoder, self.handle);
        _ = c.ghostty_key_event_set_key(self.key_event, key);
        _ = c.ghostty_key_event_set_mods(self.key_event, @intCast(mods & 0xF));
        _ = c.ghostty_key_event_set_action(self.key_event, switch (action) {
            .press => c.GHOSTTY_KEY_ACTION_PRESS,
            .release => c.GHOSTTY_KEY_ACTION_RELEASE,
            .repeat => c.GHOSTTY_KEY_ACTION_REPEAT,
        });
        // Control characters (AppKit reports "\x03" for Ctrl+C) are derived from the key and
        // modifiers; passing them as text makes the encoder emit a CSI u sequence instead.
        // AppKit also reports private-use characters (U+F700 for Up, ...) for function keys;
        // with the kitty keyboard protocol on, the encoder would send those as text.
        const text = if (isPrivateUse(utf8)) "" else if (std.mem.indexOfAny(u8, utf8, "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f\x7f") != null) "" else utf8;
        _ = c.ghostty_key_event_set_utf8(self.key_event, .{ .ptr = text.ptr, .len = text.len });
        // The kitty keyboard protocol names a key by its unshifted character; set it every call so
        // a previous key's value never leaks into a function key.
        const named = if (unshifted >= 0x20 and unshifted != 0x7f and !(unshifted >= 0xE000 and unshifted <= 0xF8FF)) unshifted else @import("keys.zig").unshiftedCodepoint(key);
        _ = c.ghostty_key_event_set_unshifted_codepoint(self.key_event, named);
        var written: usize = 0;
        if (c.ghostty_key_encoder_encode(self.key_encoder, self.key_event, out.ptr, out.len, &written) != c.GHOSTTY_SUCCESS) return out[0..0];
        return out[0..written];
    }

    fn isPrivateUse(utf8: []const u8) bool {
        if (utf8.len < 3) return false;
        const len = std.unicode.utf8ByteSequenceLength(utf8[0]) catch return false;
        if (len > utf8.len) return false;
        const cp = std.unicode.utf8Decode(utf8[0..len]) catch return false;
        return cp >= 0xE000 and cp <= 0xF8FF;
    }

    fn gridRef(self: *Terminal, tag: c.GhosttyPointTag, col: u16, y: u32) ?c.GhosttyGridRef {
        var pt = std.mem.zeroes(c.GhosttyPoint);
        pt.tag = tag;
        pt.value.coordinate = .{ .x = col, .y = y };
        var ref = std.mem.zeroes(c.GhosttyGridRef);
        if (c.ghostty_terminal_grid_ref(self.handle, pt, &ref) != c.GHOSTTY_SUCCESS) return null;
        return ref;
    }

    /// The URI of the OSC 8 hyperlink at a viewport cell, or "" if there is none or it does not fit `out`
    /// (a cut-off URL must never be opened). Valid until `out` is reused.
    pub fn hyperlinkAt(self: *Terminal, col: u16, row: u16, out: []u8) []const u8 {
        const at = self.clampCell(col, row);
        const ref = self.gridRef(c.GHOSTTY_POINT_TAG_VIEWPORT, at.col, at.row) orelse return "";
        var n: usize = 0;
        if (c.ghostty_grid_ref_hyperlink_uri(&ref, out.ptr, out.len, &n) != c.GHOSTTY_SUCCESS) return "";
        return out[0..n];
    }

    /// The run of cells around viewport cell (`col`, `row`) that `boundary` (on a cell's first codepoint) does not end, as UTF-8 in
    /// `buf`, with where the clicked cell's text starts in it and the column each cell's text starts at. The second half of a wide
    /// character is the character. Null if the cell is blank or a boundary, or the run does not fit `buf`.
    fn tokenAt(self: *Terminal, col: u16, row: u16, comptime boundary: fn (u21) bool, buf: []u8) ?Token {
        const at = self.clampCell(col, row);
        if (!self.update() or !self.selectRow(at.row)) return null;
        var in_run: [max_link_cols]bool = @splat(false);
        var spacer: [max_link_cols]bool = @splat(false);
        const width: usize = @min(self.size().cols, max_link_cols);
        if (width == 0) return null;
        var cps: [16]u21 = undefined;
        var i: usize = 0;
        while (i < width and c.ghostty_render_state_row_cells_next(self.row_cells)) : (i += 1) {
            const cl = self.readCell(&cps);
            spacer[i] = cl.wide == .spacer_tail or cl.wide == .spacer_head;
            in_run[i] = if (spacer[i]) i > 0 and in_run[i - 1] else cl.cps.len > 0 and !boundary(cl.cps[0]);
        }
        var click: usize = @min(at.col, width - 1);
        while (click > 0 and spacer[click]) click -= 1;
        if (!in_run[click]) return null;
        var lo = click;
        while (lo > 0 and in_run[lo - 1]) lo -= 1;
        var hi = click;
        while (hi + 1 < width and in_run[hi + 1]) hi += 1;
        if (!self.selectRow(at.row)) return null;
        var tok: Token = .{ .text = buf[0..0], .click = 0, .lo = lo, .hi = hi, .offs = undefined, .spacer = undefined };
        var n: usize = 0;
        var idx: usize = 0;
        while (idx <= hi and c.ghostty_render_state_row_cells_next(self.row_cells)) : (idx += 1) {
            if (idx < lo) continue;
            const cl = self.readCell(&cps);
            tok.offs[idx - lo] = @intCast(n);
            tok.spacer[idx - lo] = cl.wide == .spacer_tail or cl.wide == .spacer_head;
            if (tok.spacer[idx - lo]) continue;
            if (idx == click) tok.click = n;
            for (cl.cps) |cp| {
                const len = std.unicode.utf8CodepointSequenceLength(cp) catch continue;
                if (n + len > buf.len) return null;
                _ = std.unicode.utf8Encode(cp, buf[n..]) catch continue;
                n += len;
            }
        }
        tok.text = buf[0..n];
        return tok;
    }

    /// The link under viewport cell (`col`, `row`) and the columns it covers: an OSC 8 link (the cells with the same URI), else a
    /// plain http(s) URL, else a file path with its `:line:col` (what `pathAt` would return, plus the suffix). Whether the link may
    /// be opened, or the file exists, is the caller's to check.
    pub fn linkSpanAt(self: *Terminal, col: u16, row: u16) ?LinkSpan {
        const at = self.clampCell(col, row);
        var uri_buf: [2048]u8 = undefined;
        var other: [2048]u8 = undefined;
        const uri = self.hyperlinkAt(at.col, at.row, &uri_buf);
        if (uri.len > 0) {
            const cols = self.size().cols;
            var lo = at.col;
            while (lo > 0 and std.mem.eql(u8, self.hyperlinkAt(lo - 1, at.row, &other), uri)) lo -= 1;
            var hi = at.col;
            while (hi + 1 < cols and std.mem.eql(u8, self.hyperlinkAt(hi + 1, at.row, &other), uri)) hi += 1;
            return .{ .kind = .hyperlink, .row = at.row, .lo = lo, .hi = hi };
        }
        var url_buf: [2048]u8 = undefined;
        if (self.tokenAt(at.col, at.row, urlBoundary, &url_buf)) |tok| {
            if (urlExtent(tok.text, tok.click)) |e| {
                const cols = tok.columns(e.start, e.end);
                return .{ .kind = .url, .row = at.row, .lo = cols.lo, .hi = cols.hi };
            }
        }
        var path_buf: [1024]u8 = undefined;
        if (self.tokenAt(at.col, at.row, pathBoundary, &path_buf)) |tok| {
            const len = std.mem.trimEnd(u8, tok.text, ".:!?").len;
            if (len > 0) {
                const cols = tok.columns(0, len);
                return .{ .kind = .path, .row = at.row, .lo = cols.lo, .hi = cols.hi };
            }
        }
        return null;
    }

    /// The file path under a viewport cell and its `:line` and `:col` (0 when the text has none), copied into `out`: the run of cells
    /// around the click that no quote, bracket, comma or space ends, minus trailing `.`, `:`, `!` and `?` (a sentence's or a compiler
    /// message's). Null if there is no run, or the path does not fit `out` (a cut-off path is never returned). Whether the file
    /// exists is the caller's to check.
    pub fn pathAt(self: *Terminal, col: u16, row: u16, out: []u8) ?PathRef {
        var buf: [1024]u8 = undefined;
        const tok = self.tokenAt(col, row, pathBoundary, &buf) orelse return null;
        var path = std.mem.trimEnd(u8, tok.text, ".:!?");
        var line: u32 = 0;
        var column: u32 = 0;
        if (splitNumber(path)) |last| {
            if (splitNumber(last.rest)) |first| {
                path = first.rest;
                line = first.num;
                column = last.num;
            } else {
                path = last.rest;
                line = last.num;
            }
        }
        if (path.len == 0 or path.len > out.len) return null;
        @memcpy(out[0..path.len], path);
        return .{ .len = path.len, .line = line, .col = column };
    }

    /// The plain `http://` or `https://` URL under a viewport cell, copied into `out` (its length): from the last scheme at or
    /// before the click to the end of the run that no space or quote ends, minus trailing punctuation and any closing bracket that
    /// has no opening one inside the URL. Null if the click is before the URL's start, it is only a scheme, or it does not fit.
    pub fn urlAt(self: *Terminal, col: u16, row: u16, out: []u8) ?usize {
        var buf: [2048]u8 = undefined;
        const tok = self.tokenAt(col, row, urlBoundary, &buf) orelse return null;
        const e = urlExtent(tok.text, tok.click) orelse return null;
        const url = tok.text[e.start..e.end];
        if (url.len > out.len) return null;
        @memcpy(out[0..url.len], url);
        return url.len;
    }

    /// A theme: the default foreground and background, the cursor color (null: the program's or the foreground), and the 16 ANSI
    /// colors it sets (null keeps the built-in color). Everything else in the 256-color palette stays the library's own.
    pub fn setTheme(self: *Terminal, fg: Rgb, bg: Rgb, cursor_color: ?Rgb, ansi: [16]?Rgb) void {
        var f = toCColor(fg);
        var b = toCColor(bg);
        _ = c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &f);
        _ = c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &b);
        if (cursor_color) |cu| {
            var cc = toCColor(cu);
            _ = c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cc);
        } else _ = c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, @as(?*const anyopaque, null));
        var pal = self.builtin_palette;
        for (ansi, 0..) |o, i| {
            if (o) |col| pal[i] = toCColor(col);
        }
        _ = c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, &pal);
    }

    /// The system appearance changed. If the program asked to hear about it (mode 2031) and it differs from what it was last
    /// told, returns the report to send it (written into `out`); otherwise an empty slice.
    pub fn setScheme(self: *Terminal, dark: bool, out: *[16]u8) []const u8 {
        const changed = dark != self.dark_scheme;
        self.dark_scheme = dark;
        if (!changed) return "";
        var cfg: c.GhosttyTerminalModeConfig = .{ .mode = c.ghostty_mode_new(2031, false), .value = false };
        _ = c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_MODE, &cfg);
        if (!cfg.value) return "";
        var n: usize = 0;
        if (c.ghostty_color_scheme_report_encode(if (dark) c.GHOSTTY_COLOR_SCHEME_DARK else c.GHOSTTY_COLOR_SCHEME_LIGHT, out, out.len, &n) != c.GHOSTTY_SUCCESS) return "";
        return out[0..n];
    }

    /// Starts (or changes) a find for `needle` (ASCII letters match in either case) over the screen and the scrollback, and returns
    /// the number of matches. An empty needle ends the find. Nothing is selected yet: `findStep` does that.
    pub fn findSet(self: *Terminal, needle: []const u8) usize {
        if (needle.len == 0) {
            self.findEnd();
            return 0;
        }
        if (self.search == null and c.ghostty_search_new(null, &self.search, self.handle) != c.GHOSTTY_SUCCESS) {
            self.search = null;
            return 0;
        }
        var str: c.GhosttyString = .{ .ptr = needle.ptr, .len = needle.len };
        if (c.ghostty_search_set(self.search, c.GHOSTTY_SEARCH_OPT_NEEDLE, &str) != c.GHOSTTY_SUCCESS) return 0;
        _ = c.ghostty_search_run(self.search); // a one-shot, blocking run: the scrollback is bounded, so this is short
        var total: usize = 0;
        _ = c.ghostty_search_get(self.search, c.GHOSTTY_SEARCH_DATA_TOTAL_MATCHES, &total);
        return total;
    }

    pub const FindPosition = struct { number: usize, total: usize };

    /// Selects the next match toward older output (`older`) or toward newer, wrapping around, scrolls the view to it, and makes
    /// it the terminal's selection (so it is highlighted, and Cmd+C copies it). Null if there are no matches.
    pub fn findStep(self: *Terminal, older: bool) ?FindPosition {
        if (self.search == null) return null;
        const r = if (older) c.ghostty_search_select_next(self.search) else c.ghostty_search_select_prev(self.search);
        if (r != c.GHOSTTY_SUCCESS) return null;
        var match = std.mem.zeroes(c.GhosttySelection);
        if (c.ghostty_search_get(self.search, c.GHOSTTY_SEARCH_DATA_SELECTED_MATCH, &match) == c.GHOSTTY_SUCCESS) self.setSelection(match);
        var total: usize = 0;
        var index: usize = 0;
        _ = c.ghostty_search_get(self.search, c.GHOSTTY_SEARCH_DATA_TOTAL_MATCHES, &total);
        _ = c.ghostty_search_get(self.search, c.GHOSTTY_SEARCH_DATA_SELECTED_INDEX, &index);
        return .{ .number = index + 1, .total = total };
    }

    /// Ends the find and clears the match selection. Safe to call when none is active.
    pub fn findEnd(self: *Terminal) void {
        if (self.search == null) return;
        c.ghostty_search_free(self.search);
        self.search = null;
        self.setSelection(null);
    }

    /// Changes whether a program may write the clipboard (config reload).
    pub fn setClipboardWrite(self: *Terminal, allow: bool) void {
        self.allow_clipboard_write = allow;
    }

    fn clampCell(self: *Terminal, col: u16, row: u16) struct { col: u16, row: u16 } {
        const sz = self.size();
        return .{ .col = @min(col, sz.cols -| 1), .row = @min(row, sz.rows -| 1) };
    }

    fn setSelection(self: *Terminal, sel: ?c.GhosttySelection) void {
        if (sel) |*v| _ = c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_SELECTION, v) else _ = c.ghostty_terminal_set(self.handle, c.GHOSTTY_TERMINAL_OPT_SELECTION, null);
    }

    fn screenCoord(self: *Terminal, ref: *const c.GhosttyGridRef) ?c.GhosttyPointCoordinate {
        var pt = std.mem.zeroes(c.GhosttyPointCoordinate);
        if (c.ghostty_terminal_point_from_grid_ref(self.handle, ref, c.GHOSTTY_POINT_TAG_SCREEN, &pt) != c.GHOSTTY_SUCCESS) return null;
        return pt;
    }

    fn pointOrder(ax: u16, ay: u32, bx: u16, by: u32) std.math.Order {
        return if (ay != by) std.math.order(ay, by) else std.math.order(ax, bx);
    }

    /// A left press at a viewport cell. One click only marks where a drag would start (and clears any
    /// selection); two select the word, three or more the line.
    pub fn selectionPress(self: *Terminal, col: u16, row: u16, click_count: u8) void {
        const pos = self.clampCell(col, row);
        self.sel_anchor = .{ .x = pos.col, .y = @intCast(self.viewport().offset + pos.row) };
        self.sel_dragged = false;
        self.sel_clicks = click_count;
        self.sel_extending = false;
        if (click_count <= 1) return self.setSelection(null);
        const ref = self.gridRef(c.GHOSTTY_POINT_TAG_VIEWPORT, pos.col, pos.row) orelse return;
        const sel = self.unitAround(ref, click_count) orelse return;
        self.setSelection(sel);
    }

    /// A Shift+left press at a viewport cell: continues an existing selection to `(col, row)` (keeping its
    /// opposite end anchored when clicking outside it, or keeping `sel.start` anchored when clicking inside).
    /// Falls back to `selectionPress` when no selection exists or when a multi-click sequence started fresh.
    pub fn selectionExtend(self: *Terminal, col: u16, row: u16, click_count: u8) void {
        var cur = std.mem.zeroes(c.GhosttySelection);
        if ((click_count > 1 and !self.sel_extending) or
            c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_SELECTION, &cur) != c.GHOSTTY_SUCCESS)
        {
            return self.selectionPress(col, row, click_count);
        }
        var ordered = std.mem.zeroes(c.GhosttySelection);
        if (c.ghostty_terminal_selection_ordered(self.handle, &cur, c.GHOSTTY_SELECTION_ORDER_FORWARD, &ordered) != c.GHOSTTY_SUCCESS) {
            return self.selectionPress(col, row, click_count);
        }
        const pos = self.clampCell(col, row);
        const here_ref = self.gridRef(c.GHOSTTY_POINT_TAG_VIEWPORT, pos.col, pos.row) orelse return;
        const here_pt = self.screenCoord(&here_ref) orelse return;
        const lo_pt = self.screenCoord(&ordered.start) orelse return self.selectionPress(col, row, click_count);
        const hi_pt = self.screenCoord(&ordered.end) orelse return self.selectionPress(col, row, click_count);
        const cur_start_pt = self.screenCoord(&cur.start) orelse lo_pt;

        const Anchor = struct { ref: c.GhosttyGridRef, pt: c.GhosttyPointCoordinate };
        const anchor: Anchor = if (pointOrder(here_pt.x, here_pt.y, lo_pt.x, lo_pt.y) == .lt)
            .{ .ref = ordered.end, .pt = hi_pt }
        else if (pointOrder(here_pt.x, here_pt.y, hi_pt.x, hi_pt.y) == .gt)
            .{ .ref = ordered.start, .pt = lo_pt }
        else
            .{ .ref = cur.start, .pt = cur_start_pt };

        const end_ref = if (click_count <= 1) here_ref else blk: {
            const unit = self.unitAround(here_ref, click_count) orelse c.GhosttySelection{ .start = here_ref, .end = here_ref, .rectangle = false };
            break :blk if (pointOrder(here_pt.x, here_pt.y, anchor.pt.x, anchor.pt.y) == .lt) unit.start else unit.end;
        };

        self.sel_anchor = .{ .x = anchor.pt.x, .y = anchor.pt.y };
        self.sel_dragged = true;
        self.sel_clicks = click_count;
        self.sel_extending = true;
        self.setSelection(.{ .start = anchor.ref, .end = end_ref, .rectangle = false });
    }

    /// The word (two clicks) or line (three or more) around `ref`.
    fn unitAround(self: *Terminal, ref: c.GhosttyGridRef, click_count: u8) ?c.GhosttySelection {
        var sel = std.mem.zeroes(c.GhosttySelection);
        if (click_count == 2) {
            var o = std.mem.zeroes(c.GhosttyTerminalSelectWordOptions);
            o.size = @sizeOf(c.GhosttyTerminalSelectWordOptions);
            o.ref = ref;
            if (c.ghostty_terminal_select_word(self.handle, &o, &sel) != c.GHOSTTY_SUCCESS) return null;
        } else {
            var o = std.mem.zeroes(c.GhosttyTerminalSelectLineOptions);
            o.size = @sizeOf(c.GhosttyTerminalSelectLineOptions);
            o.ref = ref;
            if (c.ghostty_terminal_select_line(self.handle, &o, &sel) != c.GHOSTTY_SUCCESS) return null;
        }
        return sel;
    }

    /// The pointer moved to a viewport cell with the left button down after a one-click press.
    pub fn selectionDrag(self: *Terminal, col: u16, row: u16) void {
        const anchor = self.sel_anchor orelse return;
        const pos = self.clampCell(col, row);
        const here_y: u32 = @intCast(self.viewport().offset + pos.row);
        if (pos.col != anchor.x or here_y != anchor.y) self.sel_dragged = true;
        if (self.sel_clicks >= 2) return self.dragByUnit(anchor.x, anchor.y, pos.col, pos.row, here_y);
        if (!self.sel_dragged) return; // a jiggle inside the press cell selects nothing
        const start = self.gridRef(c.GHOSTTY_POINT_TAG_SCREEN, anchor.x, anchor.y) orelse return;
        const end = self.gridRef(c.GHOSTTY_POINT_TAG_VIEWPORT, pos.col, pos.row) orelse return;
        self.setSelection(.{ .start = start, .end = end, .rectangle = false });
    }

    /// After a double or triple click the drag grows the selection by whole words or lines: from the unit that was
    /// pressed to the unit under the pointer, whichever way the pointer went. Both ends are looked up again here
    /// (the pressed one by its screen position), so nothing is held that scrolling or output could invalidate.
    fn dragByUnit(self: *Terminal, ax: u16, ay: u32, col: u16, row: u16, here_y: u32) void {
        const first = self.gridRef(c.GHOSTTY_POINT_TAG_SCREEN, ax, ay) orelse return;
        const here = self.gridRef(c.GHOSTTY_POINT_TAG_VIEWPORT, col, row) orelse return;
        const under = self.unitAround(here, self.sel_clicks) orelse c.GhosttySelection{ .start = here, .end = here, .rectangle = false };
        const forward = pointOrder(col, here_y, ax, ay) != .lt;
        if (self.sel_extending) {
            self.setSelection(.{
                .start = first,
                .end = if (forward) under.end else under.start,
                .rectangle = false,
            });
            return;
        }
        const pressed = self.unitAround(first, self.sel_clicks) orelse return;
        self.setSelection(.{
            .start = if (forward) pressed.start else under.start,
            .end = if (forward) under.end else pressed.end,
            .rectangle = false,
        });
    }

    pub fn selectionRelease(self: *Terminal) void {
        self.sel_anchor = null;
        self.sel_dragged = false;
        self.sel_clicks = 1;
    }

    pub fn clearSelection(self: *Terminal) void {
        self.sel_extending = false;
        self.setSelection(null);
    }

    pub fn hasSelection(self: *Terminal) bool {
        var sel = std.mem.zeroes(c.GhosttySelection);
        return c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_SELECTION, &sel) == c.GHOSTTY_SUCCESS;
    }

    /// The OSC 133 mark of screen row `y` (0 = the oldest row kept): none, a primary prompt row, or a continuation row of one.
    fn promptRowKind(self: *Terminal, y: u32) c.GhosttyRowSemanticPrompt {
        const ref = self.gridRef(c.GHOSTTY_POINT_TAG_SCREEN, 0, y) orelse return c.GHOSTTY_ROW_SEMANTIC_NONE;
        var row: c.GhosttyRow = undefined;
        if (c.ghostty_grid_ref_row(&ref, &row) != c.GHOSTTY_SUCCESS) return c.GHOSTTY_ROW_SEMANTIC_NONE;
        var sp: c.GhosttyRowSemanticPrompt = c.GHOSTTY_ROW_SEMANTIC_NONE;
        if (c.ghostty_row_get(row, c.GHOSTTY_ROW_DATA_SEMANTIC_PROMPT, &sp) != c.GHOSTTY_SUCCESS) return c.GHOSTTY_ROW_SEMANTIC_NONE;
        return sp;
    }

    fn isPromptRow(self: *Terminal, y: u32) bool {
        return self.promptRowKind(y) != c.GHOSTTY_ROW_SEMANTIC_NONE;
    }

    /// Selects the output of the last finished command, found through the shell's OSC 133 marks: the row above the prompt the
    /// cursor is on (or the nearest one above it) is the end of that output. The selection is the terminal's own, so Cmd+C
    /// copies it. False, and no selection, with no marks, no output above (a command that printed nothing has none: the row above
    /// is the previous prompt, never an older command's output), or on the alternate screen.
    pub fn selectLastOutput(self: *Terminal) bool {
        if (self.onAlternateScreen()) return false;
        var cursor_y: u16 = 0;
        _ = c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_CURSOR_Y, &cursor_y);
        var y: u32 = @intCast(self.scrollbackRows() + cursor_y);
        while (!self.isPromptRow(y)) : (y -= 1) if (y == 0) return false; // no prompt mark at or above the cursor
        while (y > 0 and self.promptRowKind(y) == c.GHOSTTY_ROW_SEMANTIC_PROMPT_CONTINUATION) y -= 1; // a prompt of several lines: its first row
        if (y == 0 or self.isPromptRow(y - 1)) return false; // nothing above it, or the last command printed nothing
        const ref = self.gridRef(c.GHOSTTY_POINT_TAG_SCREEN, 0, y - 1) orelse return false;
        var sel = std.mem.zeroes(c.GhosttySelection);
        if (c.ghostty_terminal_select_output(self.handle, &ref, &sel) != c.GHOSTTY_SUCCESS) return false;
        self.setSelection(sel);
        return true;
    }

    /// Selects everything, the scrollback and the screen (Cmd+A). Works on the alternate screen too: it is the visible page then.
    pub fn selectAll(self: *Terminal) void {
        var sel = std.mem.zeroes(c.GhosttySelection);
        if (c.ghostty_terminal_select_all(self.handle, &sel) != c.GHOSTTY_SUCCESS) return;
        self.sel_extending = false;
        self.setSelection(sel);
    }

    pub const SelectMove = enum(u8) { line_left, line_right, word_left, word_right };

    /// An empty cell or a space: not part of any word.
    fn cellIsBlank(ref: *const c.GhosttyGridRef) bool {
        var raw: c.GhosttyCell = undefined;
        var has: bool = false;
        var cp: u32 = 0;
        if (c.ghostty_grid_ref_cell(ref, &raw) != c.GHOSTTY_SUCCESS) return true;
        _ = c.ghostty_cell_get(raw, c.GHOSTTY_CELL_DATA_HAS_TEXT, &has);
        _ = c.ghostty_cell_get(raw, c.GHOSTTY_CELL_DATA_CODEPOINT, &cp);
        return !has or cp == ' ';
    }

    /// The screen cell after (or before) `at`, wrapping across rows; null past the ends of the screen.
    fn stepCell(self: *Terminal, at: c.GhosttyPointCoordinate, forward: bool) ?c.GhosttyPointCoordinate {
        const cols = self.size().cols;
        if (forward) {
            if (at.x + 1 < cols) return .{ .x = at.x + 1, .y = at.y };
            if (at.y + 1 < self.scrollbackRows() + self.size().rows) return .{ .x = 0, .y = at.y + 1 };
        } else {
            if (at.x > 0) return .{ .x = at.x - 1, .y = at.y };
            if (at.y > 0 and cols > 0) return .{ .x = cols - 1, .y = at.y - 1 };
        }
        return null;
    }

    /// The nearest word edge past `at` (the start of a word going left, its end going right), by libghostty's word rules (the same as a
    /// double-click). When `from` already sits on an edge it looks from the next cell on, so repeated presses keep moving.
    fn wordEdge(self: *Terminal, from: c.GhosttyGridRef, at: c.GhosttyPointCoordinate, left: bool) ?c.GhosttyGridRef {
        const sz = self.size();
        const total: u32 = @intCast(self.scrollbackRows() + sz.rows);
        if (sz.cols == 0 or total == 0) return null;
        const limit = self.gridRef(c.GHOSTTY_POINT_TAG_SCREEN, if (left) 0 else sz.cols - 1, if (left) 0 else total - 1) orelse return null;
        const past: std.math.Order = if (left) .lt else .gt;
        var look = from;
        var tries: u8 = 0;
        while (tries < 4) : (tries += 1) { // a word edge, a run of blanks, the word beyond it
            var o = std.mem.zeroes(c.GhosttyTerminalSelectWordBetweenOptions);
            o.size = @sizeOf(c.GhosttyTerminalSelectWordBetweenOptions);
            o.start = look;
            o.end = limit;
            var word = std.mem.zeroes(c.GhosttySelection);
            if (c.ghostty_terminal_select_word_between(self.handle, &o, &word) != c.GHOSTTY_SUCCESS) return null;
            const edge = if (left) word.start else word.end;
            const e = self.screenCoord(&edge) orelse return null;
            if (!cellIsBlank(&word.start) and pointOrder(e.x, e.y, at.x, at.y) == past) return edge;
            // a run of blanks counts as a "word" to the library, and from an edge there is no progress: look from past this one
            const next = self.stepCell(e, !left) orelse return null;
            look = self.gridRef(c.GHOSTTY_POINT_TAG_SCREEN, next.x, next.y) orelse return null;
        }
        return null;
    }

    /// Moves the free end of the selection to the start or end of the logical line (wrapped rows are one line, the prompt is part of it)
    /// or to the next word edge, left or right. With no selection it starts at the cursor, which is the shell's caret. The selection is the
    /// terminal's own, so Cmd+C copies it and a mouse or Shift+click selection can be extended this way. False on the alternate screen
    /// and while the program has the kitty keyboard protocol on (Claude Code, editors): it edits its own input and wants the key.
    // ponytail: cells, not carets, are what a selection holds (both ends are inclusive), so reversing direction can leave one cell selected
    // where an editor would collapse to nothing. A caret-based anchor and focus pair is the upgrade if that matters.
    pub fn selectMove(self: *Terminal, move: SelectMove) bool {
        if (self.onAlternateScreen() or self.kittyFlags() != 0) return false;
        const left = move == .line_left or move == .word_left;
        const line = move == .line_left or move == .line_right;
        var sel = std.mem.zeroes(c.GhosttySelection);
        const had = c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_SELECTION, &sel) == c.GHOSTTY_SUCCESS;
        if (!had) {
            var cx: u16 = 0;
            var cy: u16 = 0;
            _ = c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_CURSOR_X, &cx);
            _ = c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_CURSOR_Y, &cy);
            // going left the first cell is the one before the cursor, so the character under the cursor stays out
            const x = if (left and cx > 0) cx - 1 else cx;
            const ref = self.gridRef(c.GHOSTTY_POINT_TAG_SCREEN, x, @intCast(self.scrollbackRows() + cy)) orelse return true;
            sel = .{ .start = ref, .end = ref, .rectangle = false };
        }
        const here = self.screenCoord(&sel.end) orelse return true;
        var target = sel.end;
        var moved = false;
        if (line) {
            var o = std.mem.zeroes(c.GhosttyTerminalSelectLineOptions);
            o.size = @sizeOf(c.GhosttyTerminalSelectLineOptions);
            o.ref = sel.end;
            var unit = std.mem.zeroes(c.GhosttySelection);
            if (c.ghostty_terminal_select_line(self.handle, &o, &unit) == c.GHOSTTY_SUCCESS) {
                const edge = if (left) unit.start else unit.end;
                const e = self.screenCoord(&edge) orelse return true;
                const past: std.math.Order = if (left) .lt else .gt;
                // never backwards: the cursor usually sits in the blanks after the line's last character
                if (pointOrder(e.x, e.y, here.x, here.y) == past) {
                    target = edge;
                    moved = true;
                }
            }
        } else if (self.wordEdge(sel.end, here, left)) |edge| {
            target = edge;
            moved = true;
        }
        if (!had and !moved and cellIsBlank(&target)) return true; // nothing to select, not even a lone blank cell
        self.sel_extending = false;
        self.setSelection(.{ .start = sel.start, .end = target, .rectangle = false });
        return true;
    }

    /// The selected text as UTF-8 in logical order: soft-wrapped lines joined, trailing blanks trimmed.
    /// `error.NoSelection` if nothing is selected. The caller frees the result with `gpa`.
    pub fn selectionText(self: *Terminal, gpa: std.mem.Allocator) ![]u8 {
        var sel = std.mem.zeroes(c.GhosttySelection);
        if (c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_SELECTION, &sel) != c.GHOSTTY_SUCCESS) return error.NoSelection;
        var fmt: c.GhosttyFormatter = undefined;
        try check(c.ghostty_formatter_terminal_new(null, &fmt, self.handle));
        defer c.ghostty_formatter_free(fmt);
        var yes: bool = true;
        try check(c.ghostty_formatter_set(fmt, c.GHOSTTY_FORMATTER_OPT_UNWRAP, &yes));
        try check(c.ghostty_formatter_set(fmt, c.GHOSTTY_FORMATTER_OPT_TRIM, &yes));
        try check(c.ghostty_formatter_set(fmt, c.GHOSTTY_FORMATTER_OPT_SELECTION, &sel));
        var ptr: [*c]u8 = null;
        var len: usize = 0;
        try check(c.ghostty_formatter_format_alloc(fmt, null, &ptr, &len));
        defer c.ghostty_free(null, ptr, len);
        return gpa.dupe(u8, ptr[0..len]);
    }

    /// True while the program asked for focus in/out reports (mode 1004).
    pub fn focusEvents(self: *Terminal) bool {
        var cfg: c.GhosttyTerminalModeConfig = .{ .mode = c.ghostty_mode_new(1004, false), .value = false };
        _ = c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_MODE, &cfg);
        return cfg.value;
    }

    /// The report for the window gaining or losing focus (`ESC [ I` / `ESC [ O`).
    pub fn encodeFocus(self: *Terminal, gained: bool, out: []u8) []const u8 {
        _ = self;
        var written: usize = 0;
        const ev: c.GhosttyFocusEvent = if (gained) c.GHOSTTY_FOCUS_GAINED else c.GHOSTTY_FOCUS_LOST;
        if (c.ghostty_focus_encode(ev, out.ptr, out.len, &written) != c.GHOSTTY_SUCCESS) return out[0..0];
        return out[0..written];
    }

    /// True unless the program reset alternate scroll (mode 1007): on the alternate screen the wheel then sends arrow keys.
    pub fn alternateScroll(self: *Terminal) bool {
        var cfg: c.GhosttyTerminalModeConfig = .{ .mode = c.ghostty_mode_new(1007, false), .value = false };
        if (c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_MODE, &cfg) != c.GHOSTTY_SUCCESS) return true;
        return cfg.value;
    }

    /// True while the program has any mouse tracking mode on (X10, normal, button or any-event).
    pub fn mouseTracking(self: *Terminal) bool {
        var on: bool = false;
        _ = c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &on);
        return on;
    }

    pub const MouseAction = enum(u8) { press = 0, release = 1, motion = 2 };
    /// The library's button numbers: wheel up and down are buttons four and five.
    pub const MouseButton = enum(u8) { left = 1, right = 2, middle = 3, wheel_up = 4, wheel_down = 5 };

    /// The bytes a mouse event sends for the terminal's current tracking mode and format (empty if that
    /// mode does not report it). The position is the center of cell (`col`, `row`), clamped to the grid,
    /// so the library's own cell math lands on that cell. `button` is null for motion with no button down.
    pub fn encodeMouse(self: *Terminal, action: MouseAction, button: ?MouseButton, mods: u32, col: u16, row: u16, cell_w: u32, cell_h: u32, out: []u8) []const u8 {
        const sz = self.size();
        if (sz.cols == 0 or sz.rows == 0 or cell_w == 0 or cell_h == 0) return out[0..0];
        _ = c.ghostty_mouse_encoder_set_from_terminal(self.mouse_encoder, self.handle);
        var geometry = std.mem.zeroes(c.GhosttyMouseEncoderSize);
        geometry.size = @sizeOf(c.GhosttyMouseEncoderSize);
        geometry.screen_width = @as(u32, sz.cols) * cell_w;
        geometry.screen_height = @as(u32, sz.rows) * cell_h;
        geometry.cell_width = cell_w;
        geometry.cell_height = cell_h;
        _ = c.ghostty_mouse_encoder_set(self.mouse_encoder, c.GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &geometry);
        var pressed: bool = button != null;
        _ = c.ghostty_mouse_encoder_set(self.mouse_encoder, c.GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed);
        const cx = @min(col, sz.cols - 1);
        const cy = @min(row, sz.rows - 1);
        _ = c.ghostty_mouse_event_set_action(self.mouse_event, @intFromEnum(action));
        if (button) |b| _ = c.ghostty_mouse_event_set_button(self.mouse_event, @intFromEnum(b)) else _ = c.ghostty_mouse_event_clear_button(self.mouse_event);
        _ = c.ghostty_mouse_event_set_mods(self.mouse_event, @intCast(mods & 0xF));
        _ = c.ghostty_mouse_event_set_position(self.mouse_event, .{
            .x = (@as(f32, @floatFromInt(cx)) + 0.5) * @as(f32, @floatFromInt(cell_w)),
            .y = (@as(f32, @floatFromInt(cy)) + 0.5) * @as(f32, @floatFromInt(cell_h)),
        });
        var written: usize = 0;
        if (c.ghostty_mouse_encoder_encode(self.mouse_encoder, self.mouse_event, out.ptr, out.len, &written) != c.GHOSTTY_SUCCESS) return out[0..0];
        return out[0..written];
    }

    /// The kitty keyboard protocol flags the program has set (0 = legacy keys).
    pub fn kittyFlags(self: *Terminal) u8 {
        var flags: u8 = 0;
        _ = c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &flags);
        return flags;
    }

    pub fn bracketedPaste(self: *Terminal) bool {
        var cfg: c.GhosttyTerminalModeConfig = .{ .mode = c.ghostty_mode_new(2004, false), .value = false };
        _ = c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_MODE, &cfg);
        return cfg.value;
    }

    /// What pasting `text` would do before the user has seen it: `runs_lines` when it holds a line break and the program has not
    /// asked for bracketed paste (every line then runs as it arrives, as if typed), `large` when it is over `large_paste_bytes`.
    pub fn pasteRisk(self: *Terminal, text: []const u8) PasteRisk {
        return .{
            .runs_lines = !self.bracketedPaste() and std.mem.indexOfAny(u8, text, "\r\n") != null,
            .large = text.len > large_paste_bytes,
        };
    }

    /// Appends what pasting `text` sends to the child: newlines become CR, and in bracketed
    /// paste mode the text is wrapped in ESC[200~ ... ESC[201~. The library removes control
    /// characters that could end a bracketed paste early.
    pub fn encodePaste(self: *Terminal, text: []const u8, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
        if (text.len == 0) return;
        const bracketed = self.bracketedPaste();
        // The library turns every LF into CR, so a CRLF would become two Enters. Unbracketed, fold
        // CRLF into LF first. (Bracketed text goes to the program as it is.)
        var folded: std.ArrayList(u8) = .empty;
        defer folded.deinit(gpa);
        const src: []const u8 = if (bracketed) text else blk: {
            try folded.ensureTotalCapacity(gpa, text.len);
            for (text, 0..) |ch, i| {
                if (ch == '\r' and i + 1 < text.len and text[i + 1] == '\n') continue;
                folded.appendAssumeCapacity(ch);
            }
            break :blk folded.items;
        };
        const copy = try gpa.dupe(u8, src); // the encoder edits its input in place
        defer gpa.free(copy);
        var needed: usize = 0;
        const first = c.ghostty_paste_encode(copy.ptr, copy.len, bracketed, null, 0, &needed);
        if (first != c.GHOSTTY_OUT_OF_SPACE and first != c.GHOSTTY_SUCCESS) return error.Ghostty;
        const start = out.items.len;
        try out.resize(gpa, start + needed);
        const copy2 = try gpa.dupe(u8, src);
        defer gpa.free(copy2);
        var written: usize = 0;
        if (c.ghostty_paste_encode(copy2.ptr, copy2.len, bracketed, out.items[start..].ptr, needed, &written) != c.GHOSTTY_SUCCESS) return error.Ghostty;
        out.shrinkRetainingCapacity(start + written);
    }

    /// Scrolls the viewport through the scrollback by `delta` rows (negative = toward older output).
    /// The library clamps at both ends.
    pub fn scrollViewport(self: *Terminal, delta: i32) void {
        const behavior: c.GhosttyTerminalScrollViewport = .{ .tag = c.GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA, .value = .{ .delta = delta } };
        _ = c.ghostty_terminal_scroll_viewport(self.handle, behavior);
    }

    /// Scrolls the viewport so the prompt `delta` prompts away (negative = older) is at its top, using the OSC 133 marks. True only
    /// if the viewport moved: not on the alternate screen, and not when there is no mark in that direction.
    pub fn scrollPrompt(self: *Terminal, delta: i32) bool {
        if (delta == 0 or self.onAlternateScreen()) return false;
        const before = self.viewport().offset;
        const behavior: c.GhosttyTerminalScrollViewport = .{ .tag = c.GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA_PROMPT, .value = .{ .delta_prompt = delta } };
        _ = c.ghostty_terminal_scroll_viewport(self.handle, behavior);
        return self.viewport().offset != before;
    }

    pub fn scrollToBottom(self: *Terminal) void {
        const behavior: c.GhosttyTerminalScrollViewport = .{ .tag = c.GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM, .value = .{ .delta = 0 } };
        _ = c.ghostty_terminal_scroll_viewport(self.handle, behavior);
    }

    /// Where the viewport is in the scrollable area: `offset` rows from the top, `rows` visible, `total` in all.
    pub const Viewport = struct { offset: usize, total: usize, rows: usize };

    pub fn viewport(self: *Terminal) Viewport {
        var sb: c.GhosttyTerminalScrollbar = std.mem.zeroes(c.GhosttyTerminalScrollbar);
        _ = c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_SCROLLBAR, &sb);
        return .{ .offset = @intCast(sb.offset), .total = @intCast(sb.total), .rows = @intCast(sb.len) };
    }

    pub fn atBottom(self: *Terminal) bool {
        const v = self.viewport();
        return v.offset + v.rows >= v.total;
    }

    pub fn onAlternateScreen(self: *Terminal) bool {
        var screen: c.GhosttyTerminalScreen = c.GHOSTTY_TERMINAL_SCREEN_PRIMARY;
        _ = c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen);
        return screen == c.GHOSTTY_TERMINAL_SCREEN_ALTERNATE;
    }

    /// Number of history rows above the visible screen.
    pub fn scrollbackRows(self: *Terminal) usize {
        var rows: usize = 0;
        _ = c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &rows);
        return rows;
    }

    pub fn size(self: *Terminal) struct { cols: u16, rows: u16 } {
        var cols: u16 = 0;
        var rows: u16 = 0;
        _ = c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_COLS, &cols);
        _ = c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_ROWS, &rows);
        return .{ .cols = cols, .rows = rows };
    }

    /// Changes the grid size (the library reflows). The pixel size of a cell is what size reports (XTWINOPS)
    /// tell the child; pass 0 if unknown and those queries go unanswered.
    pub fn resize(self: *Terminal, cols: u16, rows: u16, cell_w_px: u32, cell_h_px: u32) void {
        self.cell_px = .{ cell_w_px, cell_h_px };
        _ = c.ghostty_terminal_resize(self.handle, cols, rows, cell_w_px, cell_h_px);
    }

    /// The window title set by the child (OSC 0 or 2); empty if none. Valid until the next `write`.
    pub fn title(self: *Terminal) []const u8 {
        var str: c.GhosttyString = undefined;
        if (c.ghostty_terminal_get(self.handle, c.GHOSTTY_TERMINAL_DATA_TITLE, &str) != c.GHOSTTY_SUCCESS) return "";
        if (str.len == 0) return ""; // the pointer may be null when no title is set
        return str.ptr[0..str.len];
    }

    fn readSelected(self: *Terminal) bool {
        if (!self.selection_active) return false;
        var sel: bool = false;
        _ = c.ghostty_render_state_row_cells_get(self.row_cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_SELECTED, &sel);
        return sel;
    }

    /// The style of the cell `row_cells` currently points at.
    fn readStyle(self: *Terminal) Style {
        var style: Style = .{};
        var col: c.GhosttyColorRgb = undefined;
        if (c.ghostty_render_state_row_cells_get(self.row_cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &col) == c.GHOSTTY_SUCCESS)
            style.fg = .{ .r = col.r, .g = col.g, .b = col.b };
        if (c.ghostty_render_state_row_cells_get(self.row_cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &col) == c.GHOSTTY_SUCCESS)
            style.bg = .{ .r = col.r, .g = col.g, .b = col.b };
        var has: bool = false;
        _ = c.ghostty_render_state_row_cells_get(self.row_cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, &has);
        if (has) {
            var st = std.mem.zeroes(c.GhosttyStyle);
            if (c.ghostty_render_state_row_cells_get(self.row_cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &st) == c.GHOSTTY_SUCCESS) {
                style.flags = st.flags;
                style.underline_color = switch (st.underline_color.tag) {
                    c.GHOSTTY_STYLE_COLOR_PALETTE => self.palette[st.underline_color.value.palette],
                    c.GHOSTTY_STYLE_COLOR_RGB => .{ .r = st.underline_color.value.rgb.r, .g = st.underline_color.value.rgb.g, .b = st.underline_color.value.rgb.b },
                    else => null,
                };
            }
        }
        return style;
    }

    /// Reads the cell `row_cells` currently points at; `buf` holds its codepoints (at most 16).
    fn readCell(self: *Terminal, buf: *[16]u21) Cell {
        var wide: c.GhosttyCellWide = c.GHOSTTY_CELL_WIDE_NARROW;
        var raw: c.GhosttyCell = undefined;
        if (c.ghostty_render_state_row_cells_get(self.row_cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw) == c.GHOSTTY_SUCCESS) {
            _ = c.ghostty_cell_get(raw, c.GHOSTTY_CELL_DATA_WIDE, &wide);
        }
        var cps: [16]u32 = undefined;
        var gb = c.GhosttyCodepointBuffer{ .ptr = &cps, .cap = cps.len, .len = 0 };
        var n: usize = 0;
        // OUT_OF_SPACE still wrote the first 16 codepoints and set `len` to the real count.
        const got = c.ghostty_render_state_row_cells_get(self.row_cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &gb);
        if (got == c.GHOSTTY_SUCCESS or got == c.GHOSTTY_OUT_OF_SPACE) {
            n = @min(gb.len, cps.len);
        }
        for (cps[0..n], 0..) |cp, i| buf[i] = @intCast(cp);
        return .{ .cps = buf[0..n], .wide = switch (wide) {
            c.GHOSTTY_CELL_WIDE_WIDE => .wide,
            c.GHOSTTY_CELL_WIDE_SPACER_TAIL => .spacer_tail,
            c.GHOSTTY_CELL_WIDE_SPACER_HEAD => .spacer_head,
            else => .narrow,
        }, .style = self.readStyle(), .selected = self.readSelected() };
    }

    /// The cell at (`col`, `row`) of the visible screen; blank (no codepoints) if out of range.
    /// `buf` backs the returned codepoints.
    pub fn cell(self: *Terminal, col: u16, row: u16, buf: *[16]u21) Cell {
        const blank: Cell = .{ .cps = buf[0..0], .wide = .narrow };
        if (!self.update() or !self.selectRow(row)) return blank;
        return self.cellInRow(col, buf);
    }

    /// UTF-8 text of visible row `row`: blank cells are spaces, the spacer after a wide cell is
    /// skipped, trailing blanks are trimmed. The result is a slice of `out`; text that does not fit is cut off.
    pub fn rowText(self: *Terminal, row: u16, out: []u8) []const u8 {
        if (!self.update() or !self.selectRow(row)) return out[0..0];
        var n: usize = 0;
        var end: usize = 0; // length after the last non-blank cell
        var cps: [16]u21 = undefined;
        while (c.ghostty_render_state_row_cells_next(self.row_cells)) {
            const cl = self.readCell(&cps);
            if (cl.wide == .spacer_tail or cl.wide == .spacer_head) continue;
            if (cl.cps.len == 0) {
                if (n < out.len) {
                    out[n] = ' ';
                    n += 1;
                }
                continue;
            }
            for (cl.cps) |cp| {
                const len = std.unicode.utf8CodepointSequenceLength(cp) catch continue;
                if (n + len > out.len) return out[0..end];
                _ = std.unicode.utf8Encode(cp, out[n..]) catch continue;
                n += len;
            }
            end = n;
        }
        return out[0..end];
    }
};

test "written text lands in row 0" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    t.write("hello");
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("hello", t.rowText(0, &buf));
    try std.testing.expectEqualStrings("", t.rowText(1, &buf));
}

fn expectCps(t: *Terminal, col: u16, row: u16, want: []const u21) !void {
    var buf: [16]u21 = undefined;
    try std.testing.expectEqualSlices(u21, want, t.cell(col, row, &buf).cps);
}

test "arabic: one cell per letter, logical order" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 40, .rows = 10 });
    defer t.deinit();
    t.write("مرحبا world");
    try expectCps(t, 0, 0, &.{0x645});
    try expectCps(t, 4, 0, &.{0x627});
    try expectCps(t, 5, 0, &.{0x20});
    try expectCps(t, 6, 0, &.{'w'});
}

test "tashkeel lives in its base cell" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 40, .rows = 10 });
    defer t.deinit();
    t.write("\u{645}\u{64F}\u{62D}\u{64E}\u{645}\u{64E}\u{651}\u{62F}");
    try expectCps(t, 0, 0, &.{ 0x645, 0x64F });
    try expectCps(t, 1, 0, &.{ 0x62D, 0x64E });
    try expectCps(t, 2, 0, &.{ 0x645, 0x64E, 0x651 });
    try expectCps(t, 3, 0, &.{0x62F});
    try expectCps(t, 4, 0, &.{}); // blank
}

test "lam-alef is two cells" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 40, .rows = 10 });
    defer t.deinit();
    t.write("\u{644}\u{627}");
    try expectCps(t, 0, 0, &.{0x644});
    try expectCps(t, 1, 0, &.{0x627});
}

test "zwnj joins the previous cell" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 40, .rows = 10 });
    defer t.deinit();
    t.write("\u{645}\u{6CC}\u{200C}\u{62E}\u{648}\u{627}\u{647}\u{645}");
    try expectCps(t, 1, 0, &.{ 0x6CC, 0x200C });
}

test "emoji is a wide cell plus a spacer" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 40, .rows = 10 });
    defer t.deinit();
    t.write("ok \u{1F600} ok");
    var buf: [16]u21 = undefined;
    try std.testing.expectEqual(Wide.wide, t.cell(3, 0, &buf).wide);
    try std.testing.expectEqualSlices(u21, &.{0x1F600}, t.cell(3, 0, &buf).cps);
    try std.testing.expectEqual(Wide.spacer_tail, t.cell(4, 0, &buf).wide);
}

test "rowText skips the spacer after a wide cell" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 40, .rows = 10 });
    defer t.deinit();
    t.write("ok \u{1F600} ok");
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("ok \u{1F600} ok", t.rowText(0, &buf));
}

test "utf-8 split across two writes equals one write" {
    const text = "مرحبا world";
    const a = try Terminal.init(std.testing.allocator, .{ .cols = 40, .rows = 10 });
    defer a.deinit();
    const b = try Terminal.init(std.testing.allocator, .{ .cols = 40, .rows = 10 });
    defer b.deinit();
    a.write(text);
    // byte 5 falls inside the third Arabic letter (two bytes each)
    b.write(text[0..5]);
    b.write(text[5..]);
    var ba: [128]u8 = undefined;
    var bb: [128]u8 = undefined;
    const ra = a.rowText(0, &ba);
    try std.testing.expect(ra.len > 0);
    try std.testing.expectEqualStrings(ra, b.rowText(0, &bb));
}

const Spy = struct {
    replies: [64]u8 = undefined,
    reply_len: usize = 0,
    bells: u32 = 0,
    titles: u32 = 0,
    clip: [256]u8 = undefined,
    clip_len: usize = 0,
    clips: u32 = 0,
    note: [256]u8 = undefined,
    note_len: usize = 0,
    notes: u32 = 0,

    fn from(ctx: ?*anyopaque) *Spy {
        return @ptrCast(@alignCast(ctx.?));
    }
    fn writePty(ctx: ?*anyopaque, data: []const u8) void {
        const self = from(ctx);
        @memcpy(self.replies[self.reply_len..][0..data.len], data);
        self.reply_len += data.len;
    }
    fn bell(ctx: ?*anyopaque) void {
        from(ctx).bells += 1;
    }
    fn titleChanged(ctx: ?*anyopaque) void {
        from(ctx).titles += 1;
    }
    fn clipboardWrite(ctx: ?*anyopaque, text: []const u8) void {
        const self = from(ctx);
        @memcpy(self.clip[0..text.len], text);
        self.clip_len = text.len;
        self.clips += 1;
    }
    /// Recorded as "title|body".
    fn notify(ctx: ?*anyopaque, title: []const u8, body: []const u8) void {
        const self = from(ctx);
        self.note_len = (std.fmt.bufPrint(&self.note, "{s}|{s}", .{ title, body }) catch unreachable).len;
        self.notes += 1;
    }
    fn callbacks(self: *Spy) Callbacks {
        return .{ .ctx = self, .write_pty = writePty, .bell = bell, .title_changed = titleChanged, .clipboard_write = clipboardWrite, .notify = notify };
    }
    fn replyText(self: *const Spy) []const u8 {
        return self.replies[0..self.reply_len];
    }
};

test "bell callback fires" {
    var spy: Spy = .{};
    const t = try Terminal.init(std.testing.allocator, .{ .callbacks = spy.callbacks() });
    defer t.deinit();
    t.write("\x07");
    try std.testing.expectEqual(@as(u32, 1), spy.bells);
}

test "title change callback and getter" {
    var spy: Spy = .{};
    const t = try Terminal.init(std.testing.allocator, .{ .callbacks = spy.callbacks() });
    defer t.deinit();
    t.write("\x1b]0;hello\x07");
    try std.testing.expectEqual(@as(u32, 1), spy.titles);
    try std.testing.expectEqualStrings("hello", t.title());
}

test "cursor position report goes to write_pty" {
    var spy: Spy = .{};
    const t = try Terminal.init(std.testing.allocator, .{ .callbacks = spy.callbacks() });
    defer t.deinit();
    t.write("\x1b[6n");
    try std.testing.expectEqualStrings("\x1b[1;1R", spy.replyText());

    var spy2: Spy = .{};
    const t2 = try Terminal.init(std.testing.allocator, .{ .callbacks = spy2.callbacks() });
    defer t2.deinit();
    t2.write("ab\x1b[6n");
    try std.testing.expectEqualStrings("\x1b[1;3R", spy2.replyText());
}

test "OSC 52 write reaches the clipboard callback, for the standard clipboard only" {
    var spy: Spy = .{};
    const t = try Terminal.init(std.testing.allocator, .{ .callbacks = spy.callbacks() });
    defer t.deinit();
    t.write("\x1b]52;c;aGVsbG8=\x07"); // "hello"
    try std.testing.expectEqualStrings("hello", spy.clip[0..spy.clip_len]);
    t.write("\x1b]52;p;d29ybGQ=\x07"); // the primary selection: macOS has none, so it is not written to the clipboard
    try std.testing.expectEqual(@as(u32, 1), spy.clips);
}

test "OSC 52 write is refused by policy, and a read is never answered" {
    var spy: Spy = .{};
    const t = try Terminal.init(std.testing.allocator, .{ .callbacks = spy.callbacks(), .allow_clipboard_write = false });
    defer t.deinit();
    t.write("\x1b]52;c;aGVsbG8=\x07");
    try std.testing.expectEqual(@as(u32, 0), spy.clips);
    t.setClipboardWrite(true);
    t.write("\x1b]52;c;aGVsbG8=\x07");
    try std.testing.expectEqual(@as(u32, 1), spy.clips);
    t.write("\x1b]52;c;?\x07"); // a program asking for the clipboard's contents
    try std.testing.expectEqual(@as(usize, 0), spy.reply_len);
}

test "OSC 9 and OSC 777 raise a desktop notification" {
    var spy: Spy = .{};
    const t = try Terminal.init(std.testing.allocator, .{ .callbacks = spy.callbacks() });
    defer t.deinit();
    t.write("\x1b]9;Build done\x07");
    try std.testing.expectEqualStrings("|Build done", spy.note[0..spy.note_len]);
    t.write("\x1b]777;notify;Claude;Needs approval\x07");
    try std.testing.expectEqualStrings("Claude|Needs approval", spy.note[0..spy.note_len]);
    try std.testing.expectEqual(@as(u32, 2), spy.notes);
}

test "cleanText drops controls and bidi overrides, keeps Arabic, and cuts at a character boundary" {
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("ab c", cleanText(&out, "a\x1bb\n\u{202e}c"));
    try std.testing.expectEqualStrings("مرحبا\u{200f} 1", cleanText(&out, "مرحبا\u{200f} 1\x07")); // the direction mark stays
    var small: [4]u8 = undefined;
    try std.testing.expectEqualStrings("aaa", cleanText(&small, "aaa\u{20ac}")); // the 3-byte character does not fit: dropped whole
    try std.testing.expectEqualStrings("", cleanText(&small, "\x1b"));
}

test "hyperlinkAt finds the URI of an OSC 8 link, and nothing elsewhere" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    t.write("\x1b]8;;https://example.com/a\x1b\\link\x1b]8;;\x1b\\ plain");
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("https://example.com/a", t.hyperlinkAt(1, 0, &buf));
    try std.testing.expectEqualStrings("", t.hyperlinkAt(7, 0, &buf)); // "plain"
    var tiny: [4]u8 = undefined;
    try std.testing.expectEqualStrings("", t.hyperlinkAt(1, 0, &tiny)); // too long for the buffer: never a cut-off URL
}

/// Writes `text` to a fresh terminal, then asks `pathAt` about column `col` of its first row.
fn pathProbe(text: []const u8, col: u16, out: []u8) !?struct { path: []const u8, line: u32, col: u32 } {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    t.write(text);
    const r = t.pathAt(col, 0, out) orelse return null;
    return .{ .path = out[0..r.len], .line = r.line, .col = r.col };
}

test "pathAt finds the path token under a cell and its line and column" {
    var buf: [128]u8 = undefined;
    const a = (try pathProbe("see src/main.zig:12:5: error", 5, &buf)).?;
    try std.testing.expectEqualStrings("src/main.zig", a.path);
    try std.testing.expectEqual(@as(u32, 12), a.line);
    try std.testing.expectEqual(@as(u32, 5), a.col);
    const b = (try pathProbe("open foo.txt, then", 6, &buf)).?;
    try std.testing.expectEqualStrings("foo.txt", b.path);
    try std.testing.expectEqual(@as(u32, 0), b.line);
    try std.testing.expectEqualStrings("~/notes.md", (try pathProbe("(~/notes.md)", 4, &buf)).?.path);
    const c7 = (try pathProbe("file.zig:7", 0, &buf)).?;
    try std.testing.expectEqualStrings("file.zig", c7.path);
    try std.testing.expectEqual(@as(u32, 7), c7.line);
    try std.testing.expectEqual(@as(u32, 0), c7.col);
    try std.testing.expectEqualStrings("/etc/hosts", (try pathProbe("cat /etc/hosts.", 9, &buf)).?.path); // a sentence's full stop is not the path's
    try std.testing.expect((try pathProbe("see src/main.zig", 3, &buf)) == null); // on the space
    try std.testing.expect((try pathProbe("see src/main.zig", 40, &buf)) == null); // past the text
    // each CJK character takes two columns: the column of `a` is 5, not 3
    const cjk = (try pathProbe("漢字 a/b.c:9", 5, &buf)).?;
    try std.testing.expectEqualStrings("a/b.c", cjk.path);
    try std.testing.expectEqual(@as(u32, 9), cjk.line);
    // the second half of a wide character is the character: "漢字" is itself a token
    try std.testing.expectEqualStrings("漢字", (try pathProbe("漢字 a/b.c:9", 3, &buf)).?.path);
    // Arabic text before the path does not move the columns (the grid is in logical order)
    const ar = (try pathProbe("مرحبا src/x.zig:3", 10, &buf)).?;
    try std.testing.expectEqualStrings("src/x.zig", ar.path);
    try std.testing.expectEqual(@as(u32, 3), ar.line);
    var tiny: [3]u8 = undefined;
    try std.testing.expect((try pathProbe("src/main.zig:1", 2, &tiny)) == null); // never a cut-off path
}

/// Like `pathProbe` for `urlAt`.
fn urlProbe(text: []const u8, col: u16, out: []u8) !?[]const u8 {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    t.write(text);
    const n = t.urlAt(col, 0, out) orelse return null;
    return out[0..n];
}

test "urlAt finds a plain http or https URL under a cell" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("https://example.com/a?b=1&c=2", (try urlProbe("visit https://example.com/a?b=1&c=2. Then", 14, &buf)).?);
    // a closing parenthesis belongs to the URL only while it is balanced
    try std.testing.expectEqualStrings("https://en.wikipedia.org/wiki/Foo_(bar)", (try urlProbe("(https://en.wikipedia.org/wiki/Foo_(bar))", 20, &buf)).?);
    try std.testing.expectEqualStrings("https://x.com", (try urlProbe("(see https://x.com)", 10, &buf)).?);
    // a markdown link opens only from its URL part
    try std.testing.expect((try urlProbe("[docs](https://x.com/y)", 2, &buf)) == null);
    try std.testing.expectEqualStrings("https://x.com/y", (try urlProbe("[docs](https://x.com/y)", 14, &buf)).?);
    try std.testing.expectEqualStrings("HTTP://EXAMPLE.COM/x", (try urlProbe("HTTP://EXAMPLE.COM/x", 8, &buf)).?);
    // a URL inside a URL is part of the outer one, wherever it is clicked (the coloring paints it as one)
    const nested = "go https://a.org/x?r=https://b.org/y ok";
    try std.testing.expectEqualStrings("https://a.org/x?r=https://b.org/y", (try urlProbe(nested, 30, &buf)).?);
    try std.testing.expectEqualStrings("https://a.org/x?r=https://b.org/y", (try urlProbe(nested, 8, &buf)).?);
    // other schemes, a bare scheme, a space and a small buffer give nothing
    try std.testing.expect((try urlProbe("see ftp://x.org/a", 10, &buf)) == null);
    try std.testing.expect((try urlProbe("https://", 3, &buf)) == null);
    try std.testing.expect((try urlProbe("file:///etc/passwd", 3, &buf)) == null);
    try std.testing.expect((try urlProbe("see https://x.org", 3, &buf)) == null); // on the space
    var tiny: [4]u8 = undefined;
    try std.testing.expect((try urlProbe("https://example.com", 10, &tiny)) == null); // never a cut-off URL
}

/// A row of cells for `text` (one cell per codepoint; a CJK character is a wide cell followed by its spacer), `store` holding the codepoints.
fn testCells(text: []const u8, cells: []Cell, store: []u21) []Cell {
    var n: usize = 0;
    var s: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepoint()) |cp| {
        store[s] = cp;
        const wide = cp >= 0x2E80;
        cells[n] = .{ .cps = store[s .. s + 1], .wide = if (wide) .wide else .narrow };
        n += 1;
        s += 1;
        if (wide) {
            cells[n] = .{ .cps = store[s..s], .wide = .spacer_tail };
            n += 1;
        }
    }
    return cells[0..n];
}

fn spanProbe(text: []const u8, col: u16) !?LinkSpan {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    t.write(text);
    return t.linkSpanAt(col, 0);
}

test "linkSpanAt gives the columns of the link under a cell" {
    // a plain URL: "https://example.com/a" is 21 cells from column 4; the full stop after it is not part of it
    const url = (try spanProbe("see https://example.com/a. ok", 10)).?;
    try std.testing.expectEqual(LinkKind.url, url.kind);
    try std.testing.expectEqual(@as(u16, 0), url.row);
    try std.testing.expectEqual(@as(u16, 4), url.lo);
    try std.testing.expectEqual(@as(u16, 24), url.hi);
    // a file path with its line and column: "src/main.zig:12:5" is 17 cells from column 3, without the colon after it
    const path = (try spanProbe("at src/main.zig:12:5: error", 5)).?;
    try std.testing.expectEqual(LinkKind.path, path.kind);
    try std.testing.expectEqual(@as(u16, 3), path.lo);
    try std.testing.expectEqual(@as(u16, 19), path.hi);
    // an OSC 8 link: the cells written while it was open, spaces included
    const link = (try spanProbe("\x1b]8;;https://example.com/x\x1b\\link here\x1b]8;;\x1b\\ plain", 1)).?;
    try std.testing.expectEqual(LinkKind.hyperlink, link.kind);
    try std.testing.expectEqual(@as(u16, 0), link.lo);
    try std.testing.expectEqual(@as(u16, 8), link.hi);
    // columns, not bytes: CJK characters take two cells each
    const cjk_path = (try spanProbe("漢字 a/b.c:9", 5)).?;
    try std.testing.expectEqual(LinkKind.path, cjk_path.kind);
    try std.testing.expectEqual(@as(u16, 5), cjk_path.lo);
    try std.testing.expectEqual(@as(u16, 11), cjk_path.hi);
    const cjk_url = (try spanProbe("漢 http://a.b/c", 6)).?;
    try std.testing.expectEqual(LinkKind.url, cjk_url.kind);
    try std.testing.expectEqual(@as(u16, 3), cjk_url.lo);
    try std.testing.expectEqual(@as(u16, 14), cjk_url.hi);
    try std.testing.expect((try spanProbe("see https://example.com/a. ok", 3)) == null); // on a space
}

test "markUrls colors a plain URL and nothing else" {
    const blue: Rgb = .{ .r = 10, .g = 20, .b = 250 };
    var cells: [64]Cell = undefined;
    var store: [64]u21 = undefined;
    // "see https://example.com/a?b=1. ok": the URL is cells 4 to 28; the full stop after it is not part of it
    var row = testCells("see https://example.com/a?b=1. ok", &cells, &store);
    markUrls(row, blue);
    for (row, 0..) |cell, i| {
        const inside = i >= 4 and i <= 28;
        try std.testing.expectEqual(inside, cell.style.fg != null and std.meta.eql(cell.style.fg.?, blue));
        try std.testing.expectEqual(inside, cell.style.underline() == .single);
    }
    // a program that set the colour itself, or underlined, is respected
    row = testCells("go http://x.org/p now", &cells, &store);
    row[8].style.fg = .{ .r = 1, .g = 2, .b = 3 };
    row[9].style.flags = @as(u16, 3) << c.GHOSTTY_STYLE_UNDERLINE_SHIFT; // curly
    markUrls(row, blue);
    try std.testing.expectEqual(Rgb{ .r = 1, .g = 2, .b = 3 }, row[8].style.fg.?);
    try std.testing.expectEqual(Style.Underline.single, row[8].style.underline()); // underlined, its own colour kept
    try std.testing.expectEqual(blue, row[9].style.fg.?);
    try std.testing.expectEqual(Style.Underline.curly, row[9].style.underline());
    // other schemes and a bare scheme are left alone
    for ([_][]const u8{ "ftp://x.org/a", "https://", "file:///etc/passwd", "no url here" }) |text| {
        row = testCells(text, &cells, &store);
        markUrls(row, blue);
        for (row) |cell| try std.testing.expect(cell.style.fg == null and cell.style.underline() == .none);
    }
    // a wide character before the URL is two cells: the URL "http://a.b" starts at cell 3, and a spacer inside it is coloured too
    row = testCells("漢 http://a.b", &cells, &store);
    markUrls(row, blue);
    for (row, 0..) |cell, i| try std.testing.expectEqual(i >= 3, cell.style.fg != null);
    row = testCells("http://a.b/漢", &cells, &store);
    markUrls(row, blue);
    for (row) |cell| try std.testing.expect(cell.style.fg != null); // the spacer of the wide character at the end is part of the URL
}

test "setTheme changes the default colors, the 16 ANSI colors and what a program is told, and keeps the rest of the palette" {
    var spy: Spy = .{};
    const t = try Terminal.init(std.testing.allocator, .{ .callbacks = spy.callbacks() });
    defer t.deinit();
    _ = t.update();
    const before_20 = t.paletteColor(20);
    const before_2 = t.paletteColor(2);
    var ansi: [16]?Rgb = @splat(null);
    ansi[1] = .{ .r = 0xdc, .g = 0x32, .b = 0x2f };
    t.setTheme(.{ .r = 0x83, .g = 0x94, .b = 0x96 }, .{ .r = 0x11, .g = 0x22, .b = 0x33 }, .{ .r = 0xff, .g = 0, .b = 0 }, ansi);
    _ = t.update();
    try std.testing.expectEqual(Rgb{ .r = 0x83, .g = 0x94, .b = 0x96 }, t.colors().fg);
    try std.testing.expectEqual(Rgb{ .r = 0x11, .g = 0x22, .b = 0x33 }, t.colors().bg);
    try std.testing.expectEqual(Rgb{ .r = 0xff, .g = 0, .b = 0 }, t.colors().cursor.?);
    try std.testing.expectEqual(Rgb{ .r = 0xdc, .g = 0x32, .b = 0x2f }, t.paletteColor(1));
    try std.testing.expectEqual(before_2, t.paletteColor(2)); // not set by the theme: the built-in color
    try std.testing.expectEqual(before_20, t.paletteColor(20));
    t.write("\x1b]11;?\x07"); // a program asking for the background (Codex does at start-up)
    try std.testing.expectEqualStrings("\x1b]11;rgb:1111/2222/3333\x07", spy.replyText());
    // setting a theme again starts from the built-in palette, not from the previous theme
    t.setTheme(.{ .r = 1, .g = 1, .b = 1 }, .{ .r = 2, .g = 2, .b = 2 }, null, @splat(null));
    _ = t.update();
    try std.testing.expect(t.colors().cursor == null);
    try std.testing.expect(!std.meta.eql(Rgb{ .r = 0xdc, .g = 0x32, .b = 0x2f }, t.paletteColor(1)));
}

test "the color scheme is answered to a query and reported on change only to a program that asked" {
    var spy: Spy = .{};
    const t = try Terminal.init(std.testing.allocator, .{ .callbacks = spy.callbacks() });
    defer t.deinit();
    t.write("\x1b[?996n");
    try std.testing.expectEqualStrings("\x1b[?997;1n", spy.replyText()); // dark is the default
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("", t.setScheme(false, &buf)); // mode 2031 is off: nothing to tell
    spy.reply_len = 0;
    t.write("\x1b[?996n");
    try std.testing.expectEqualStrings("\x1b[?997;2n", spy.replyText());
    t.write("\x1b[?2031h");
    try std.testing.expectEqualStrings("\x1b[?997;1n", t.setScheme(true, &buf));
    try std.testing.expectEqualStrings("", t.setScheme(true, &buf)); // no change, no report
}

test "find marks every match in view, not only the current one, and nothing once it ends" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 30, .rows = 6 });
    defer t.deinit();
    t.write("xx needle yy needle\r\nno hit here\r\nneedleneedle");
    var buf: [16]u21 = undefined;
    try std.testing.expectEqual(@as(usize, 4), t.findSet("needle"));
    _ = t.findStep(true); // the newest match: the second "needle" of the last line (cols 6..11)
    // every match in view is marked: row 0 cols 3..8 and 13..18, row 2 cols 0..5 and 6..11; nothing else is
    for ([_][2]u16{ .{ 0, 3 }, .{ 0, 8 }, .{ 0, 13 }, .{ 0, 18 }, .{ 2, 0 }, .{ 2, 5 }, .{ 2, 6 }, .{ 2, 11 } }) |at| try std.testing.expect(cellOf(t, at[0], at[1], &buf).match);
    for ([_][2]u16{ .{ 0, 0 }, .{ 0, 2 }, .{ 0, 9 }, .{ 0, 12 }, .{ 0, 19 }, .{ 1, 3 }, .{ 2, 12 } }) |at| try std.testing.expect(!cellOf(t, at[0], at[1], &buf).match);
    // the current match is also the selection (the painter shows it as one), the others are only marked
    try std.testing.expect(cellOf(t, 2, 6, &buf).selected);
    try std.testing.expect(!cellOf(t, 0, 3, &buf).selected and cellOf(t, 0, 3, &buf).match);
    t.findEnd();
    try std.testing.expect(!cellOf(t, 0, 3, &buf).match and !cellOf(t, 2, 6, &buf).match);
}

test "find: counts matches across scrollback, selects them newest first, wraps, scrolls to them, and ends cleanly" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    t.write("needle-one at the very top\r\n");
    writeLines(t, 100);
    t.write("needle-two near the bottom\r\n");
    try std.testing.expect(t.scrollbackRows() > 0);
    try std.testing.expectEqual(@as(usize, 2), t.findSet("NEEDLE")); // ASCII case does not matter
    const first = t.findStep(true).?; // the newest match: it is on the live screen
    try std.testing.expectEqual(@as(usize, 1), first.number);
    try std.testing.expectEqual(@as(usize, 2), first.total);
    try std.testing.expect(t.atBottom());
    const txt = try t.selectionText(std.testing.allocator);
    defer std.testing.allocator.free(txt);
    try std.testing.expectEqualStrings("needle", txt); // the match itself is the selection
    const second = t.findStep(true).?; // older: in the scrollback, and the viewport follows it there
    try std.testing.expectEqual(@as(usize, 2), second.number);
    try std.testing.expect(!t.atBottom());
    const wrapped = t.findStep(true).?; // after the oldest, the newest again
    try std.testing.expectEqual(@as(usize, 1), wrapped.number);
    const back = t.findStep(false).?; // the other direction
    try std.testing.expectEqual(@as(usize, 2), back.number);
    try std.testing.expectEqual(@as(usize, 0), t.findSet("no such text anywhere"));
    try std.testing.expect(t.findStep(true) == null);
    t.findEnd();
    try std.testing.expect(!t.hasSelection());
    t.findEnd(); // ending twice is fine
}

test "a new terminal starts with its field defaults" {
    // gpa.create gives memory with no defaults applied; init must set them (Debug fills it with 0xAA).
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    try std.testing.expectEqual(@as(?@TypeOf(t.sel_anchor.?), null), t.sel_anchor);
    try std.testing.expect(!t.sel_dragged);
    try std.testing.expect(!t.selection_active);
    try std.testing.expectEqual(@as(u8, 1), t.sel_clicks);
    try std.testing.expectEqual([2]u32{ 0, 0 }, t.cell_px);
    try std.testing.expectEqual(theme_bg, t.default_colors.bg);
}

test "XTVERSION names Harf, not the library" {
    var spy: Spy = .{};
    const t = try Terminal.init(std.testing.allocator, .{ .callbacks = spy.callbacks() });
    defer t.deinit();
    t.write("\x1b[>0q");
    try std.testing.expectEqualStrings("\x1bP>|" ++ xtversion ++ "\x1b\\", spy.replyText());
}

test "XTWINOPS size queries are answered once the cell size is known" {
    var spy: Spy = .{};
    const t = try Terminal.init(std.testing.allocator, .{ .callbacks = spy.callbacks() });
    defer t.deinit();
    t.write("\x1b[16t"); // the cell size is not known yet: no answer, as before
    try std.testing.expectEqual(@as(usize, 0), spy.reply_len);
    t.resize(100, 30, 17, 33);
    t.write("\x1b[16t"); // one cell, in pixels: CSI 6 ; height ; width t
    try std.testing.expectEqualStrings("\x1b[6;33;17t", spy.replyText());
    spy.reply_len = 0;
    t.write("\x1b[14t"); // the text area, in pixels: CSI 4 ; height ; width t
    try std.testing.expectEqualStrings("\x1b[4;990;1700t", spy.replyText());
    spy.reply_len = 0;
    t.write("\x1b[18t"); // the text area, in cells: CSI 8 ; rows ; columns t
    try std.testing.expectEqualStrings("\x1b[8;30;100t", spy.replyText());
}

fn writeLines(t: *Terminal, n: usize) void {
    var buf: [32]u8 = undefined;
    for (0..n) |i| t.write(std.fmt.bufPrint(&buf, "line {d}\r\n", .{i}) catch unreachable);
}

/// `n` finished commands (a marked prompt `$ cmd<i>`, then `lines` of output, then the exit mark) and a last prompt, as a
/// shell with OSC 133 integration draws them.
fn writeBlocks(t: *Terminal, n: usize, lines: usize) void {
    var buf: [48]u8 = undefined;
    for (0..n) |i| {
        t.write(std.fmt.bufPrint(&buf, "\x1b]133;A\x07$ cmd{d}\r\n\x1b]133;C\x07", .{i}) catch unreachable);
        for (0..lines) |j| t.write(std.fmt.bufPrint(&buf, "out{d}-{d}\r\n", .{ i, j }) catch unreachable);
        t.write("\x1b]133;D;0\x07");
    }
    t.write("\x1b]133;A\x07$ ");
}

fn topRow(t: *Terminal, buf: []u8) []const u8 {
    return t.rowText(0, buf);
}

test "scrollPrompt moves the viewport one prompt at a time" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    writeBlocks(t, 3, 40);
    var buf: [64]u8 = undefined;
    try std.testing.expect(t.atBottom());
    try std.testing.expect(t.scrollPrompt(-1));
    try std.testing.expectEqualStrings("$ cmd2", topRow(t, &buf));
    try std.testing.expect(t.scrollPrompt(-1));
    try std.testing.expectEqualStrings("$ cmd1", topRow(t, &buf));
    try std.testing.expect(t.scrollPrompt(-1));
    try std.testing.expectEqualStrings("$ cmd0", topRow(t, &buf));
    try std.testing.expect(!t.scrollPrompt(-1)); // already at the first prompt
    try std.testing.expectEqualStrings("$ cmd0", topRow(t, &buf));
    try std.testing.expect(t.scrollPrompt(1));
    try std.testing.expectEqualStrings("$ cmd1", topRow(t, &buf));
}

test "scrollPrompt does nothing without marks, on the alternate screen, or after the scrollback was cleared" {
    const plain = try Terminal.init(std.testing.allocator, .{});
    defer plain.deinit();
    writeLines(plain, 100);
    const before = plain.viewport().offset;
    try std.testing.expect(!plain.scrollPrompt(-1));
    try std.testing.expectEqual(before, plain.viewport().offset);

    const alt = try Terminal.init(std.testing.allocator, .{});
    defer alt.deinit();
    writeBlocks(alt, 3, 40);
    alt.write("\x1b[?1049h");
    try std.testing.expect(!alt.scrollPrompt(-1));

    const cleared = try Terminal.init(std.testing.allocator, .{});
    defer cleared.deinit();
    writeBlocks(cleared, 3, 40);
    cleared.write("\x1b[H\x1b[2J\x1b[3J"); // Cmd+K: the marks went with the scrollback
    const at = cleared.viewport().offset;
    try std.testing.expect(!cleared.scrollPrompt(-1));
    try std.testing.expectEqual(at, cleared.viewport().offset);
}

const two_commands = "\x1b]133;A\x07$ one\r\n\x1b]133;C\x07alpha\r\nbeta\r\n\x1b]133;D;0\x07" ++
    "\x1b]133;A\x07$ two\r\n\x1b]133;C\x07gamma\r\ndelta\r\n\x1b]133;D;0\x07\x1b]133;A\x07$ ";

test "selectLastOutput selects the output of the last finished command" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    t.write(two_commands);
    try std.testing.expect(t.selectLastOutput());
    const txt = try t.selectionText(std.testing.allocator);
    defer std.testing.allocator.free(txt);
    try std.testing.expectEqualStrings("gamma\ndelta", txt);
}

test "selectLastOutput does not reach back past a command that printed nothing" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    // `ls` printed "a b", then `true` printed nothing: the last command's output is empty, not "a b"
    t.write("\x1b]133;A\x07$ ls\r\n\x1b]133;C\x07a b\r\n\x1b]133;D;0\x07\x1b]133;A\x07$ true\r\n\x1b]133;C\x07\x1b]133;D;0\x07\x1b]133;A\x07$ ");
    try std.testing.expect(!t.selectLastOutput());
    try std.testing.expectError(error.NoSelection, t.selectionText(std.testing.allocator));
}

test "selectLastOutput finds the output above a prompt of two lines" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    t.write("\x1b]133;A\x07$ one\r\n\x1b]133;C\x07out1\r\n\x1b]133;D;0\x07\x1b]133;A\x07~/src\r\n$ ");
    try std.testing.expect(t.selectLastOutput());
    const txt = try t.selectionText(std.testing.allocator);
    defer std.testing.allocator.free(txt);
    try std.testing.expectEqualStrings("out1", txt);
}

test "selectLastOutput does nothing without marks, on the alternate screen, or after the scrollback was cleared" {
    const plain = try Terminal.init(std.testing.allocator, .{});
    defer plain.deinit();
    writeLines(plain, 30);
    try std.testing.expect(!plain.selectLastOutput());
    try std.testing.expectError(error.NoSelection, plain.selectionText(std.testing.allocator));

    const alt = try Terminal.init(std.testing.allocator, .{});
    defer alt.deinit();
    alt.write(two_commands ++ "\x1b[?1049h");
    try std.testing.expect(!alt.selectLastOutput());

    const cleared = try Terminal.init(std.testing.allocator, .{});
    defer cleared.deinit();
    cleared.write(two_commands ++ "\x1b[H\x1b[2J\x1b[3J");
    try std.testing.expect(!cleared.selectLastOutput());
    try std.testing.expectError(error.NoSelection, cleared.selectionText(std.testing.allocator));
}

test "pasteRisk: a line break risks running lines only without bracketed paste; very large always asks" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    const none: PasteRisk = .{ .runs_lines = false, .large = false };
    try std.testing.expectEqual(none, t.pasteRisk("one line"));
    for ([_][]const u8{ "a\nb", "a\rb", "ls\n" }) |text| try std.testing.expect(t.pasteRisk(text).runs_lines);
    t.write("\x1b[?2004h"); // the program asked for bracketed paste: it sees one paste, not typing
    for ([_][]const u8{ "a\nb", "a\rb", "ls\n" }) |text| try std.testing.expectEqual(none, t.pasteRisk(text));
    const big = try std.testing.allocator.alloc(u8, large_paste_bytes + 1);
    defer std.testing.allocator.free(big);
    @memset(big, 'a');
    try std.testing.expect(!t.pasteRisk(big[0..large_paste_bytes]).large); // exactly the limit does not ask
    try std.testing.expect(t.pasteRisk(big).large); // bracketed or not
    t.write("\x1b[?2004l");
    try std.testing.expect(t.pasteRisk(big).large);
}

test "default scrollback keeps between 500 and 1200 rows at 80 columns" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    writeLines(t, 3000);
    // History is pruned a whole page at a time, so the count swings with the page boundary;
    // measured 569 to 1160 over 20,000 lines at 80 columns (215 to 452 at 200 columns).
    const n = t.scrollbackRows();
    try std.testing.expect(n >= 500 and n <= 1200);
}

test "scrollback_bytes = 0 keeps nothing" {
    const t = try Terminal.init(std.testing.allocator, .{ .scrollback_bytes = 0 });
    defer t.deinit();
    writeLines(t, 100);
    try std.testing.expectEqual(@as(usize, 0), t.scrollbackRows());
}

test "kitty image storage limit is zero" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    var limit: u64 = 1;
    try std.testing.expectEqual(c.GHOSTTY_SUCCESS, c.ghostty_terminal_get(t.handle, c.GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_STORAGE_LIMIT, &limit));
    try std.testing.expectEqual(@as(u64, 0), limit);
}

test "resize to 500x200 and to 1x1 keeps working" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    t.resize(500, 200, 0, 0);
    try std.testing.expectEqual(@as(u16, 500), t.size().cols);
    try std.testing.expectEqual(@as(u16, 200), t.size().rows);
    t.write("x");
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("x", t.rowText(0, &buf));
    t.resize(1, 1, 0, 0);
    try std.testing.expectEqual(@as(u16, 1), t.size().cols);
    try std.testing.expectEqual(@as(u16, 1), t.size().rows);
    t.write("hello\r\n");
}

test "title is empty when never set" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    try std.testing.expectEqualStrings("", t.title());
}

test "cell with more than 16 codepoints keeps the first 16" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    t.write("a");
    for (0..20) |_| t.write("\u{64E}");
    var buf: [16]u21 = undefined;
    const cl = t.cell(0, 0, &buf);
    try std.testing.expectEqual(@as(usize, 16), cl.cps.len);
    try std.testing.expectEqual(@as(u21, 'a'), cl.cps[0]);
}

test "cursor follows output" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    t.write("ab\r\ncd");
    try std.testing.expect(t.update());
    try std.testing.expectEqual(Terminal.Cursor{ .col = 2, .row = 1, .visible = true }, t.cursor().?);
    t.write("\x1b[?25l");
    try std.testing.expect(t.update());
    try std.testing.expect(!t.cursor().?.visible);
}

test "selectRow does not refresh" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    try std.testing.expect(t.update());
    t.write("x");
    var buf: [16]u21 = undefined;
    try std.testing.expect(t.selectRow(0));
    try std.testing.expectEqual(@as(usize, 0), t.cellInRow(0, &buf).cps.len);
    try std.testing.expect(t.update());
    try std.testing.expect(t.selectRow(0));
    try std.testing.expectEqualSlices(u21, &.{'x'}, t.cellInRow(0, &buf).cps);
}

fn encFor(t: *Terminal, code: u16, mods: u32, utf8: []const u8, buf: []u8) []const u8 {
    return t.encodeKey(@import("keys.zig").fromMac(code).?, mods, utf8, 0, .press, buf);
}

test "up arrow, normal and application mode" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[A", encFor(t, 126, 0, "", &buf));
    t.write("\x1b[?1h");
    try std.testing.expectEqualStrings("\x1bOA", encFor(t, 126, 0, "", &buf));
}

test "AppKit reports private-use text for function keys; arrows still encode" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[A", encFor(t, 126, 0, "\u{F700}", &buf)); // up
    try std.testing.expectEqualStrings("\x1b[B", encFor(t, 125, 0, "\u{F701}", &buf)); // down
    try std.testing.expectEqualStrings("\x1b[3~", encFor(t, 117, 0, "\u{F728}", &buf)); // forward delete
    try std.testing.expectEqualStrings("\x1bOP", encFor(t, 122, 0, "\u{F704}", &buf)); // F1
}

test "arrows and function keys with the kitty keyboard protocol on" {
    // Claude Code and other TUIs send ESC[>1u; AppKit's private-use text must not reach the encoder.
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    t.write("\x1b[>1u");
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[A", encFor(t, 126, 0, "\u{F700}", &buf));
    try std.testing.expectEqualStrings("\x1b[B", encFor(t, 125, 0, "\u{F701}", &buf));
    try std.testing.expectEqualStrings("\x1b[3~", encFor(t, 117, 0, "\u{F728}", &buf));
    try std.testing.expectEqualStrings("\x1b[C", encFor(t, 124, 0, "", &buf));
}

test "kitty keyboard flags follow the program's requests" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    try std.testing.expectEqual(@as(u8, 0), t.kittyFlags());
    t.write("\x1b[>1u");
    try std.testing.expectEqual(@as(u8, 1), t.kittyFlags());
    t.write("\x1b[<u");
    try std.testing.expectEqual(@as(u8, 0), t.kittyFlags());
}

test "ctrl letters under the kitty keyboard protocol (what Claude Code sets)" {
    // Claude Code asks for flags 5 (disambiguate + report alternates). Without the key's
    // unshifted codepoint the encoder produced no bytes at all, so Ctrl+C did nothing.
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\x03", encFor(t, 8, 2, "\x03", &buf)); // legacy mode
    t.write("\x1b[>5u");
    try std.testing.expectEqualStrings("\x1b[99;5u", encFor(t, 8, 2, "\x03", &buf)); // ctrl c
    try std.testing.expectEqualStrings("\x1b[100;5u", encFor(t, 2, 2, "\x04", &buf)); // ctrl d
    try std.testing.expectEqualStrings("\x1b[108;5u", encFor(t, 37, 2, "\x0c", &buf)); // ctrl l
    try std.testing.expectEqualStrings("\x1b[A", encFor(t, 126, 0, "\u{F700}", &buf)); // arrows unchanged
}

test "the layout's unshifted letter names the key under the kitty protocol" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    t.write("\x1b[>5u");
    var buf: [32]u8 = undefined;
    const q = @import("keys.zig").fromMac(12).?; // physical Q, AZERTY "a"
    // unicode key code 97 (the layout's a), base-layout key 113 (the physical q), as the protocol says
    try std.testing.expectEqualStrings("\x1b[97::113;5u", t.encodeKey(q, 2, "", 'a', .press, &buf));
    // AppKit's private-use "unshifted" character for an arrow is not a codepoint to send
    try std.testing.expectEqualStrings("\x1b[A", t.encodeKey(@import("keys.zig").fromMac(126).?, 0, "", 0xF700, .press, &buf));
}

test "keypad enter sends a carriage return, like Return" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\r", encFor(t, 76, 0, "\r", &buf));
}

test "paste: control bytes become spaces, so CR and LF are the only bytes that can act as Enter (the paste guard relies on it)" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    for ([_]bool{ false, true }) |bracketed| {
        if (bracketed) t.write("\x1b[?2004h");
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(std.testing.allocator);
        try t.encodePaste("a\x03b\x04c\x1b[31md\x7fe\x15f\x00g", &out, std.testing.allocator); // Ctrl-C, Ctrl-D, ESC, DEL, Ctrl-U, NUL
        const body = if (bracketed) out.items["\x1b[200~".len .. out.items.len - "\x1b[201~".len] else out.items;
        try std.testing.expectEqualStrings("a b c [31md e f g", body);
    }
}

test "paste: CRLF is one Enter, a lone CR stays one" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try t.encodePaste("a\r\nb\r\n\r\nc\rd\ne", &out, std.testing.allocator);
    try std.testing.expectEqualStrings("a\rb\r\rc\rd\re", out.items);
    out.clearRetainingCapacity();
    t.write("\x1b[?2004h"); // bracketed: the text goes through as it is
    try t.encodePaste("a\r\nb", &out, std.testing.allocator);
    try std.testing.expectEqualStrings("\x1b[200~a\r\nb\x1b[201~", out.items);
}

test "ctrl c, enter, backspace, shift tab" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\x03", encFor(t, 8, 2, "", &buf));
    try std.testing.expectEqualStrings("\x03", encFor(t, 8, 2, "\x03", &buf));
    try std.testing.expectEqualStrings("\r", encFor(t, 36, 0, "\r", &buf));
    try std.testing.expectEqualStrings("\x7f", encFor(t, 51, 0, "\x7f", &buf));
    try std.testing.expectEqualStrings("\x1b[Z", encFor(t, 48, 1, "\t", &buf));
}

test "paste: newlines, bracketed mode, and an embedded end marker" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    try t.encodePaste("a\nb", &out, std.testing.allocator);
    try std.testing.expectEqualStrings("a\rb", out.items);
    out.clearRetainingCapacity();
    t.write("\x1b[?2004h");
    try t.encodePaste("a\nb", &out, std.testing.allocator);
    try std.testing.expectEqualStrings("\x1b[200~a\nb\x1b[201~", out.items); // bracketed text keeps its newlines
    out.clearRetainingCapacity();
    try t.encodePaste("x\x1b[201~y", &out, std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, out.items[6 .. out.items.len - 6], "\x1b") == null);
}

fn cellOf(t: *Terminal, row: u16, col: u16, buf: *[16]u21) Cell {
    _ = t.update();
    _ = t.selectRow(row);
    return t.cellInRow(col, buf);
}

test "sgr colors resolve" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    t.write("\x1b[31mA\x1b[38;5;196mB\x1b[38;2;1;2;3mC\x1b[48;2;9;8;7mD\x1b[0mE");
    var buf: [16]u21 = undefined;
    const a = cellOf(t, 0, 0, &buf);
    try std.testing.expect(a.style.fg != null and a.style.fg.?.r > 150 and a.style.fg.?.g < 120); // palette red
    try std.testing.expectEqual(t.paletteColor(1), a.style.fg.?);
    const b = cellOf(t, 0, 1, &buf);
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 0, .b = 0 }, b.style.fg.?); // 256-color cube
    const cc = cellOf(t, 0, 2, &buf);
    try std.testing.expectEqual(Rgb{ .r = 1, .g = 2, .b = 3 }, cc.style.fg.?); // truecolor
    const d = cellOf(t, 0, 3, &buf);
    try std.testing.expectEqual(Rgb{ .r = 9, .g = 8, .b = 7 }, d.style.bg.?);
    const e = cellOf(t, 0, 4, &buf);
    try std.testing.expect(e.style.fg == null and e.style.bg == null and e.style.flags == 0);
}

test "style flags and underline styles" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    t.write("\x1b[1;3;2;7;8;9mX\x1b[0m\x1b[4mS\x1b[21mD\x1b[4:3mC\x1b[4:4mT\x1b[4:5mH\x1b[24m\x1b[53mO\x1b[0mN");
    var buf: [16]u21 = undefined;
    const F = Style.Flag;
    const x = cellOf(t, 0, 0, &buf).style;
    try std.testing.expectEqual(F.bold | F.italic | F.faint | F.inverse | F.invisible | F.strikethrough, x.flags & 0xFF);
    try std.testing.expectEqual(Style.Underline.none, x.underline());
    try std.testing.expectEqual(Style.Underline.single, cellOf(t, 0, 1, &buf).style.underline());
    try std.testing.expectEqual(Style.Underline.double, cellOf(t, 0, 2, &buf).style.underline());
    try std.testing.expectEqual(Style.Underline.curly, cellOf(t, 0, 3, &buf).style.underline());
    try std.testing.expectEqual(Style.Underline.dotted, cellOf(t, 0, 4, &buf).style.underline());
    try std.testing.expectEqual(Style.Underline.dashed, cellOf(t, 0, 5, &buf).style.underline());
    const o = cellOf(t, 0, 6, &buf).style;
    try std.testing.expect(o.flags & F.overline != 0 and o.underline() == .none);
    try std.testing.expectEqual(@as(u16, 0), cellOf(t, 0, 7, &buf).style.flags);
}

test "underline color resolves" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    t.write("\x1b[4m\x1b[58;2;10;20;30mU\x1b[58;5;1mP");
    var buf: [16]u21 = undefined;
    try std.testing.expectEqual(Rgb{ .r = 10, .g = 20, .b = 30 }, cellOf(t, 0, 0, &buf).style.underline_color.?);
    try std.testing.expectEqual(t.paletteColor(1), cellOf(t, 0, 1, &buf).style.underline_color.?);
}

test "default colors are Harf's and programs can change them" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    _ = t.update();
    try std.testing.expectEqual(theme_fg, t.colors().fg);
    try std.testing.expectEqual(theme_bg, t.colors().bg);
    t.write("\x1b]11;rgb:10/20/30\x07");
    _ = t.update();
    try std.testing.expectEqual(Rgb{ .r = 0x10, .g = 0x20, .b = 0x30 }, t.colors().bg);
    const custom = try Terminal.init(std.testing.allocator, .{ .default_fg = .{ .r = 1, .g = 2, .b = 3 }, .default_bg = .{ .r = 4, .g = 5, .b = 6 } });
    defer custom.deinit();
    _ = custom.update();
    try std.testing.expectEqual(Rgb{ .r = 1, .g = 2, .b = 3 }, custom.colors().fg);
    try std.testing.expectEqual(Rgb{ .r = 4, .g = 5, .b = 6 }, custom.colors().bg);
}

test "palette change shows" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    t.write("\x1b]4;1;rgb:ff/00/00\x07\x1b[31mx");
    var buf: [16]u21 = undefined;
    try std.testing.expectEqual(Rgb{ .r = 255, .g = 0, .b = 0 }, cellOf(t, 0, 0, &buf).style.fg.?);
}

test "erased cell keeps its background" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    t.write("\x1b[44m\x1b[2K");
    var buf: [16]u21 = undefined;
    const c0 = cellOf(t, 0, 0, &buf);
    try std.testing.expectEqual(@as(usize, 0), c0.cps.len);
    try std.testing.expectEqual(t.paletteColor(4), c0.style.bg.?);
    try std.testing.expectEqual(t.paletteColor(4), cellOf(t, 0, 79, &buf).style.bg.?);
}

fn lineNo(t: *Terminal, row: u16) !i64 {
    var buf: [64]u8 = undefined;
    const text = t.rowText(row, &buf);
    if (!std.mem.startsWith(u8, text, "line ")) return error.NotALine;
    return std.fmt.parseInt(i64, text[5..], 10);
}

fn fillHistory(t: *Terminal, n: usize) void {
    var buf: [32]u8 = undefined;
    for (0..n) |i| t.write(std.fmt.bufPrint(&buf, "line {d}\r\n", .{i}) catch unreachable);
}

test "viewport scrolls into history" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 20, .rows = 10 });
    defer t.deinit();
    fillHistory(t, 60);
    _ = t.update();
    const before = try lineNo(t, 0);
    try std.testing.expect(t.viewport().offset + t.viewport().rows == t.viewport().total); // at the bottom
    t.scrollViewport(-5);
    _ = t.update();
    try std.testing.expectEqual(before - 5, try lineNo(t, 0));
    t.scrollToBottom();
    _ = t.update();
    try std.testing.expectEqual(before, try lineNo(t, 0));
}

test "viewport clamps" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 20, .rows = 10 });
    defer t.deinit();
    fillHistory(t, 60);
    // the live screen before the flood: every row's text and the cursor
    _ = t.update();
    var before: [10][32]u8 = undefined;
    var before_len: [10]usize = undefined;
    for (0..10) |r| {
        const text = t.rowText(@intCast(r), &before[r]);
        before_len[r] = text.len;
    }
    const cursor_before = t.cursor().?;
    t.scrollViewport(-100000);
    _ = t.update();
    try std.testing.expectEqual(@as(usize, 0), t.viewport().offset);
    try std.testing.expectEqual(@as(i64, 0), try lineNo(t, 0)); // the oldest line
    t.scrollViewport(100000);
    try std.testing.expectEqual(t.viewport().total, t.viewport().offset + t.viewport().rows);
    for (0..1000) |i| t.scrollViewport(if (i % 2 == 0) -7 else 3);
    const v = t.viewport();
    try std.testing.expect(v.offset + v.rows <= v.total);
    t.scrollToBottom();
    try std.testing.expectEqual(t.viewport().total, t.viewport().offset + t.viewport().rows);
    // after the flood the live screen and the cursor are exactly as they were
    _ = t.update();
    var after: [32]u8 = undefined;
    for (0..10) |r| {
        const text = t.rowText(@intCast(r), &after);
        try std.testing.expectEqualStrings(before[r][0..before_len[r]], text);
    }
    const cursor_after = t.cursor().?;
    try std.testing.expectEqual(cursor_before.col, cursor_after.col);
    try std.testing.expectEqual(cursor_before.row, cursor_after.row);
    try std.testing.expect(cursor_after.visible);
}

test "cursor hidden while scrolled" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 20, .rows = 10 });
    defer t.deinit();
    fillHistory(t, 60);
    _ = t.update();
    try std.testing.expect(t.cursor() != null);
    t.scrollViewport(-5);
    _ = t.update();
    try std.testing.expect(t.cursor() == null);
}

test "alternate screen is reported" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    try std.testing.expect(!t.onAlternateScreen());
    t.write("\x1b[?1049h");
    try std.testing.expect(t.onAlternateScreen());
    t.write("\x1b[?1049l");
    try std.testing.expect(!t.onAlternateScreen());
}

test "mouse tracking follows the program's request" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    try std.testing.expect(!t.mouseTracking());
    t.write("\x1b[?1000h");
    try std.testing.expect(t.mouseTracking());
    t.write("\x1b[?1000l");
    try std.testing.expect(!t.mouseTracking());
}

test "alternate scroll (mode 1007) follows the program, on unless it is reset" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    try std.testing.expect(t.alternateScroll()); // the library's default, which keeps the wheel working in less and man
    t.write("\x1b[?1007l");
    try std.testing.expect(!t.alternateScroll());
    t.write("\x1b[?1007h");
    try std.testing.expect(t.alternateScroll());
}

test "mouse reports in SGR mode, 1-based, at the cell's center" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    t.write("\x1b[?1000h\x1b[?1006h");
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[<0;5;3M", t.encodeMouse(.press, .left, 0, 4, 2, 10, 20, &buf));
    try std.testing.expectEqualStrings("\x1b[<0;5;3m", t.encodeMouse(.release, .left, 0, 4, 2, 10, 20, &buf));
    try std.testing.expectEqualStrings("\x1b[<2;1;1M", t.encodeMouse(.press, .right, 0, 0, 0, 10, 20, &buf));
    try std.testing.expectEqualStrings("\x1b[<64;1;1M", t.encodeMouse(.press, .wheel_up, 0, 0, 0, 10, 20, &buf));
    try std.testing.expectEqualStrings("\x1b[<65;1;1M", t.encodeMouse(.press, .wheel_down, 0, 0, 0, 10, 20, &buf));
    try std.testing.expectEqualStrings("\x1b[<4;1;1M", t.encodeMouse(.press, .left, 1, 0, 0, 10, 20, &buf)); // shift adds 4
}

test "motion is reported only in the modes that ask for it" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    var buf: [32]u8 = undefined;
    t.write("\x1b[?1000h\x1b[?1006h");
    try std.testing.expectEqual(@as(usize, 0), t.encodeMouse(.motion, null, 0, 3, 3, 10, 20, &buf).len);
    t.write("\x1b[?1003h");
    try std.testing.expectEqualStrings("\x1b[<35;4;4M", t.encodeMouse(.motion, null, 0, 3, 3, 10, 20, &buf));
}

test "mouse positions clamp to the grid" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit();
    t.write("\x1b[?1000h\x1b[?1006h");
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[<0;10;5M", t.encodeMouse(.press, .left, 0, 500, 500, 10, 20, &buf));
}

test "wide grid reports columns past 223" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 300, .rows = 5 });
    defer t.deinit();
    var buf: [32]u8 = undefined;
    t.write("\x1b[?1000h\x1b[?1006h");
    try std.testing.expectEqualStrings("\x1b[<0;251;1M", t.encodeMouse(.press, .left, 0, 250, 0, 10, 20, &buf));
    // The legacy X10 format cannot name column 250 in one byte. Whatever the library does, the
    // result must be empty or one well-formed 6-byte report, never a corrupt or oversized one.
    t.write("\x1b[?1006l");
    const legacy = t.encodeMouse(.press, .left, 0, 250, 0, 10, 20, &buf);
    try std.testing.expect(legacy.len == 0 or (legacy.len == 6 and std.mem.eql(u8, legacy[0..3], "\x1b[M")));
}

test "focus events are encoded, and the mode says whether the program wants them" {
    const t = try Terminal.init(std.testing.allocator, .{});
    defer t.deinit();
    try std.testing.expect(!t.focusEvents());
    t.write("\x1b[?1004h");
    try std.testing.expect(t.focusEvents());
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[I", t.encodeFocus(true, &buf));
    try std.testing.expectEqualStrings("\x1b[O", t.encodeFocus(false, &buf));
}

fn selectText(t: *Terminal, c0: u16, r0: u16, c1: u16, r1: u16) ![]u8 {
    t.selectionPress(c0, r0, 1);
    t.selectionDrag(c1, r1);
    t.selectionRelease();
    return t.selectionText(std.testing.allocator);
}

test "selection copy is logical text" {
    const cases = [_][]const u8{
        "hello world",
        "مُحَمَّد", // tashkeel
        "لا إله إلا الله", // lam-alef
        "a\u{301}b", // a combining mark
        "日本語", // wide characters
    };
    for (cases) |str| {
        const t = try Terminal.init(std.testing.allocator, .{ .cols = 30, .rows = 5 });
        defer t.deinit();
        t.write(str);
        _ = t.update();
        const end = t.cursor().?.col - 1;
        const got = try selectText(t, 0, 0, end, 0);
        defer std.testing.allocator.free(got);
        try std.testing.expectEqualStrings(str, got);
    }
}

fn dragText(t: *Terminal, clicks: u8, from: [2]u16, to: [2]u16) ![]u8 {
    t.selectionPress(from[0], from[1], clicks);
    t.selectionDrag(to[0], to[1]);
    t.selectionRelease();
    return t.selectionText(std.testing.allocator);
}

test "double-click then drag extends the selection in whole words, forward and backward" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 30, .rows = 5 });
    defer t.deinit();
    t.write("alpha beta gamma delta");
    // press inside "beta" (col 7), drag into the middle of "gamma" (col 13): both words whole
    const fwd = try dragText(t, 2, .{ 7, 0 }, .{ 13, 0 });
    defer std.testing.allocator.free(fwd);
    try std.testing.expectEqualStrings("beta gamma", fwd);
    // drag back into "alpha" (col 2): from the start of alpha to the end of beta
    const back = try dragText(t, 2, .{ 7, 0 }, .{ 2, 0 });
    defer std.testing.allocator.free(back);
    try std.testing.expectEqualStrings("alpha beta", back);
    // still inside the pressed word: just that word
    const same = try dragText(t, 2, .{ 7, 0 }, .{ 8, 0 });
    defer std.testing.allocator.free(same);
    try std.testing.expectEqualStrings("beta", same);
}

test "triple-click then drag extends the selection in whole lines" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 30, .rows = 5 });
    defer t.deinit();
    t.write("first line\r\nsecond line\r\nthird line");
    const down = try dragText(t, 3, .{ 3, 0 }, .{ 2, 2 });
    defer std.testing.allocator.free(down);
    try std.testing.expectEqualStrings("first line\nsecond line\nthird line", down);
    const up = try dragText(t, 3, .{ 3, 2 }, .{ 4, 1 });
    defer std.testing.allocator.free(up);
    try std.testing.expectEqualStrings("second line\nthird line", up);
}

test "a single-click drag still selects characters" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 30, .rows = 5 });
    defer t.deinit();
    t.write("alpha beta gamma delta");
    const got = try dragText(t, 1, .{ 7, 0 }, .{ 13, 0 });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("eta gam", got);
}

fn expectSelected(t: *Terminal, want: []const u8) !void {
    const got = try t.selectionText(std.testing.allocator);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "select all takes the scrollback and the screen" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 10, .rows = 3 });
    defer t.deinit();
    t.write("a\r\nb\r\nc\r\nd\r\ne");
    try std.testing.expect(t.scrollbackRows() >= 2);
    t.selectAll();
    try expectSelected(t, "a\nb\nc\nd\ne");
}

test "line moves select from the cursor to the logical line's edge, the prompt included" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 30, .rows = 5 });
    defer t.deinit();
    t.write("prompt % git commit -m hi"); // the cursor sits in the blank after the last character
    try std.testing.expect(t.selectMove(.line_left));
    try expectSelected(t, "prompt % git commit -m hi");
    // nothing right of the cursor: no selection, not even a lone blank cell
    t.clearSelection();
    try std.testing.expect(t.selectMove(.line_right));
    try std.testing.expect(!t.hasSelection());
    // cursor on the '%': leftwards leaves the character under it out, rightwards takes it
    t.write("\x1b[1;8H");
    try std.testing.expect(t.selectMove(.line_left));
    try expectSelected(t, "prompt");
    t.clearSelection();
    try std.testing.expect(t.selectMove(.line_right));
    try expectSelected(t, "% git commit -m hi");
}

test "line moves treat soft-wrapped rows as one line" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit();
    t.write("0123456789abcde"); // wraps after the 9: the cursor is on row 1, column 5
    try std.testing.expect(t.selectMove(.line_left));
    try expectSelected(t, "0123456789abcde");
    t.clearSelection();
    t.write("\x1b[1;4H"); // row 0, column 3
    try std.testing.expect(t.selectMove(.line_right));
    try expectSelected(t, "3456789abcde");
}

test "word moves step word by word and repeat" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 30, .rows = 5 });
    defer t.deinit();
    t.write("alpha beta gamma delta");
    try std.testing.expect(t.selectMove(.word_left));
    try expectSelected(t, "delta");
    try std.testing.expect(t.selectMove(.word_left));
    try expectSelected(t, "gamma delta");
    try std.testing.expect(t.selectMove(.word_left));
    try expectSelected(t, "beta gamma delta");
    try std.testing.expect(t.selectMove(.word_left));
    try expectSelected(t, "alpha beta gamma delta");
    // at the start there is nowhere to go: the selection stays
    try std.testing.expect(t.selectMove(.word_left));
    try expectSelected(t, "alpha beta gamma delta");
    t.clearSelection();
    t.write("\x1b[1;7H"); // column 6, the 'b' of beta
    try std.testing.expect(t.selectMove(.word_right));
    try expectSelected(t, "beta");
    try std.testing.expect(t.selectMove(.word_right));
    try expectSelected(t, "beta gamma");
}

test "a mouse selection can be extended from the keyboard" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 30, .rows = 5 });
    defer t.deinit();
    t.write("alpha beta gamma delta");
    const got = try selectText(t, 6, 0, 9, 0);
    std.testing.allocator.free(got);
    try std.testing.expect(t.selectMove(.word_right));
    try expectSelected(t, "beta gamma");
    try std.testing.expect(t.selectMove(.line_right));
    try expectSelected(t, "beta gamma delta");
}

test "the keyboard selection moves leave a program with the kitty keyboard protocol on to itself" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 30, .rows = 5 });
    defer t.deinit();
    t.write("alpha beta");
    t.write("\x1b[>5u"); // what Claude Code sets
    try std.testing.expect(t.kittyFlags() != 0);
    inline for (.{ Terminal.SelectMove.line_left, .line_right, .word_left, .word_right }) |m| {
        try std.testing.expect(!t.selectMove(m));
    }
    try std.testing.expect(!t.hasSelection());
    t.write("\x1b[<u"); // popped: the shell's again
    try std.testing.expect(t.selectMove(.word_left));
    try expectSelected(t, "beta");
}

test "the keyboard selection moves leave the alternate screen to its program" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 30, .rows = 5 });
    defer t.deinit();
    t.write("\x1b[?1049hsome text");
    inline for (.{ Terminal.SelectMove.line_left, .line_right, .word_left, .word_right }) |m| {
        try std.testing.expect(!t.selectMove(m));
    }
    try std.testing.expect(!t.hasSelection());
    t.selectAll(); // Cmd+A still works there: it selects the visible page
    try expectSelected(t, "some text");
}

test "selection copy joins soft wraps and keeps hard newlines, without trailing blanks" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 10, .rows = 6 });
    defer t.deinit();
    t.write("abcdefghijklmnopqrstuvwxyz\r\nsecond   ");
    _ = t.update();
    const got = try selectText(t, 0, 0, 9, 3);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("abcdefghijklmnopqrstuvwxyz\nsecond", got);
}

test "reversed drag selects the same text" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 30, .rows = 5 });
    defer t.deinit();
    t.write("hello world");
    const got = try selectText(t, 8, 0, 2, 0);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("llo wor", got);
}

test "a jiggle inside the press cell selects nothing; leaving and returning selects one cell" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 30, .rows = 5 });
    defer t.deinit();
    t.write("hello world");
    t.selectionPress(3, 0, 1);
    t.selectionDrag(3, 0);
    try std.testing.expect(!t.hasSelection());
    t.selectionDrag(6, 0);
    try std.testing.expect(t.hasSelection());
    t.selectionDrag(3, 0); // back on the press cell after leaving it
    const one = try t.selectionText(std.testing.allocator);
    defer std.testing.allocator.free(one);
    try std.testing.expectEqualStrings("l", one);
}

test "word and line selection" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 30, .rows = 5 });
    defer t.deinit();
    t.write("foo bar baz");
    t.selectionPress(5, 0, 2);
    const word = try t.selectionText(std.testing.allocator);
    defer std.testing.allocator.free(word);
    try std.testing.expectEqualStrings("bar", word);
    t.selectionPress(5, 0, 3);
    const line = try t.selectionText(std.testing.allocator);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqualStrings("foo bar baz", line);
}

test "a plain click clears the selection; clearSelection too" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 30, .rows = 5 });
    defer t.deinit();
    t.write("hello world");
    const got = try selectText(t, 0, 0, 4, 0);
    std.testing.allocator.free(got);
    try std.testing.expect(t.hasSelection());
    t.selectionPress(7, 0, 1);
    try std.testing.expect(!t.hasSelection()); // a click without a drag selects nothing
    const again = try selectText(t, 0, 0, 4, 0);
    std.testing.allocator.free(again);
    t.clearSelection();
    try std.testing.expect(!t.hasSelection());
}

fn expectSelection(t: *Terminal, want: []const u8) !void {
    const got = try t.selectionText(std.testing.allocator);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "Shift+click continues an existing selection forward, backward, and repeatedly" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 40, .rows = 5 });
    defer t.deinit();
    t.write("alpha beta gamma delta");

    // Drag forward "beta" (6..9), release, then Shift+click past it and again further right.
    t.selectionPress(6, 0, 1);
    t.selectionDrag(9, 0);
    t.selectionRelease();
    try expectSelection(t, "beta");

    t.selectionExtend(13, 0, 1);
    t.selectionRelease();
    try expectSelection(t, "beta gam");

    t.selectionExtend(21, 0, 1);
    t.selectionRelease();
    try expectSelection(t, "beta gamma delta");

    // Shift+click inside shrinks from the active end (anchor at 6 stays fixed).
    t.selectionExtend(15, 0, 1);
    t.selectionRelease();
    try expectSelection(t, "beta gamma");

    // Shift+click before the selection keeps the right end (15) anchored and extends left.
    t.selectionExtend(0, 0, 1);
    t.selectionRelease();
    try expectSelection(t, "alpha beta gamma");

    // Shift+click inside a reversed selection keeps its right anchor (15) fixed.
    t.selectionExtend(6, 0, 1);
    t.selectionRelease();
    try expectSelection(t, "beta gamma");
}

test "Shift+click preserves a backward drag when extending past either end" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 40, .rows = 5 });
    defer t.deinit();
    t.write("alpha beta gamma");

    // Backward drag across "beta" (9 -> 6), release, then Shift+click right into "gamma".
    t.selectionPress(9, 0, 1);
    t.selectionDrag(6, 0);
    t.selectionRelease();
    try expectSelection(t, "beta");

    t.selectionExtend(15, 0, 1);
    t.selectionRelease();
    try expectSelection(t, "beta gamma");
}

test "Shift+click extends from word/line selection, drags after Shift+press, and handles Shift+double-click" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 40, .rows = 5 });
    defer t.deinit();
    t.write("alpha beta gamma\r\nsecond line");

    // Double-click "beta", release, then Shift+click before it: keeps end of "beta".
    t.selectionPress(7, 0, 2);
    t.selectionRelease();
    try expectSelection(t, "beta");
    t.selectionExtend(0, 0, 1);
    t.selectionRelease();
    try expectSelection(t, "alpha beta");

    // Dragging after a Shift+click continues adjusting from the same anchor, even across it.
    t.selectionPress(6, 0, 1);
    t.selectionDrag(9, 0);
    t.selectionRelease();
    t.selectionExtend(13, 0, 1);
    t.selectionDrag(15, 0);
    t.selectionRelease();
    try expectSelection(t, "beta gamma");
    t.selectionExtend(12, 0, 1);
    t.selectionDrag(2, 0);
    t.selectionRelease();
    try expectSelection(t, "pha b");

    // Shift+double-click extends to the whole word on repeat click.
    t.selectionPress(0, 0, 1);
    t.selectionDrag(4, 0);
    t.selectionRelease();
    t.selectionExtend(13, 0, 1);
    t.selectionRelease();
    t.selectionExtend(13, 0, 2);
    t.selectionRelease();
    try expectSelection(t, "alpha beta gamma");

    // Shift+click across lines.
    t.selectionExtend(5, 1, 1);
    t.selectionRelease();
    try expectSelection(t, "alpha beta gamma\nsecond");
}

test "Shift+click with no selection starts a fresh selection (including double-click)" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 30, .rows = 5 });
    defer t.deinit();
    t.write("alpha beta gamma");

    t.selectionExtend(7, 0, 1);
    t.selectionRelease();
    try std.testing.expect(!t.hasSelection());

    t.selectionExtend(7, 0, 2);
    t.selectionRelease();
    try expectSelection(t, "beta");

    // A fresh triple-click with Shift still selects the whole line instead of extending the word.
    t.selectionExtend(7, 0, 3);
    t.selectionRelease();
    try expectSelection(t, "alpha beta gamma");
}

test "Shift+click extends selection across scrolled viewport" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 20, .rows = 5 });
    defer t.deinit();
    fillHistory(t, 20);
    _ = t.update();

    var bot_buf: [64]u8 = undefined;
    const bot_text = t.rowText(3, &bot_buf);
    try std.testing.expect(bot_text.len > 0);
    t.selectionPress(0, 3, 1);
    t.selectionDrag(@intCast(bot_text.len - 1), 3);
    t.selectionRelease();
    t.scrollViewport(-16);
    _ = t.update();

    var row_buf: [64]u8 = undefined;
    const top_text = t.rowText(2, &row_buf);
    t.selectionExtend(0, 2, 1);
    t.selectionRelease();
    const got = try t.selectionText(std.testing.allocator);
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.startsWith(u8, got, top_text));
    try std.testing.expect(std.mem.endsWith(u8, got, bot_text));
}

test "selection survives scrolling the viewport" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 20, .rows = 10 });
    defer t.deinit();
    fillHistory(t, 60);
    _ = t.update();
    const got = try selectText(t, 0, 3, 5, 3);
    defer std.testing.allocator.free(got);
    t.scrollViewport(-5);
    _ = t.update();
    try std.testing.expect(t.hasSelection());
    const after = try t.selectionText(std.testing.allocator);
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings(got, after);
}

test "output over the selected cells keeps the selection, and copies what is there now" {
    // The library does not clear a selection when text is overwritten in place (Decision 9, ruled in the
    // ledger): the selection stays on its cells, and scrolling output carries it along with the content.
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 30, .rows = 5 });
    defer t.deinit();
    t.write("hello world");
    const got = try selectText(t, 0, 0, 4, 0);
    std.testing.allocator.free(got);
    t.write("\x1b[1;1Hxxxxx");
    try std.testing.expect(t.hasSelection());
    const now = try t.selectionText(std.testing.allocator);
    defer std.testing.allocator.free(now);
    try std.testing.expectEqualStrings("xxxxx", now);
}

test "scrolling output carries the selection with its content" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 20, .rows = 5 });
    defer t.deinit();
    t.write("keep me\r\n");
    const got = try selectText(t, 0, 0, 6, 0);
    std.testing.allocator.free(got);
    t.write("a\r\nb\r\nc\r\nd\r\ne\r\nf\r\n"); // scrolls "keep me" up
    try std.testing.expect(t.hasSelection());
    const text = try t.selectionText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("keep me", text);
}

test "cells know whether they are selected" {
    const t = try Terminal.init(std.testing.allocator, .{ .cols = 30, .rows = 5 });
    defer t.deinit();
    t.write("hello world");
    const got = try selectText(t, 2, 0, 4, 0);
    std.testing.allocator.free(got);
    var buf: [16]u21 = undefined;
    try std.testing.expect(!cellOf(t, 0, 1, &buf).selected);
    try std.testing.expect(cellOf(t, 0, 3, &buf).selected);
    try std.testing.expect(!cellOf(t, 0, 5, &buf).selected);
}

const chunk_stream =
    "plain ascii and digits 0123456789\r\n" ++
    "two-byte \u{e9}\u{e8}\u{fc} three-byte \u{20ac}\u{2713} four-byte \u{1F600}\u{1F468}\r\n" ++
    "\x1b[1;31mbold red\x1b[0m \x1b[4:3mcurly\x1b[0m \x1b[38;2;10;20;30mtruecolor\x1b[0m\r\n" ++
    "\x1b]0;a window title\x07\x1b]2;second title\x1b\\" ++
    "\u{645}\u{64F}\u{62D}\u{64E}\u{645}\u{64E}\u{651}\u{62F} \u{644}\u{627} \u{628}\u{64A}\u{62A}\u{64A}\r\n" ++ // tashkeel, lam-alef
    "\u{65E5}\u{672C}\u{8A9E} wide\r\n" ++
    "a\u{301} e\u{308} combining\r\n" ++
    "\x1b[5;3Hcursor moved \x1b[2K\x1b[3Aup\x1b[?25l\x1b[2J\x1b[Hafter clear\r\nline two\x1b[1;1H";

/// A grid fingerprint: every row's text, the cursor and the title, and per cell the style flags and colors.
fn fingerprint(t: *Terminal, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    _ = t.update();
    var buf: [256]u8 = undefined;
    var cps: [16]u21 = undefined;
    const sz = t.size();
    for (0..sz.rows) |r| {
        try out.appendSlice(gpa, t.rowText(@intCast(r), &buf));
        try out.append(gpa, '\n');
        _ = t.selectRow(@intCast(r));
        for (0..sz.cols) |col| {
            const cell = t.cellInRow(@intCast(col), &cps);
            const st = cell.style;
            try out.print(gpa, "{d}:{x}:{any}:{any};", .{ @intFromEnum(cell.wide), st.flags, st.fg, st.bg });
        }
        try out.append(gpa, '\n');
    }
    try out.print(gpa, "cursor {any} title '{s}'\n", .{ t.cursor(), t.title() });
}

test "chunking does not change the grid" {
    const gpa = std.testing.allocator;
    var whole_fp: std.ArrayList(u8) = .empty;
    defer whole_fp.deinit(gpa);
    {
        const t = try Terminal.init(gpa, .{ .cols = 40, .rows = 12 });
        defer t.deinit();
        t.write(chunk_stream);
        try fingerprint(t, &whole_fp, gpa);
    }
    for ([_]usize{ 1, 2, 3, 7, 13, 64, 4096, 65536 }) |chunk| {
        var fp: std.ArrayList(u8) = .empty;
        defer fp.deinit(gpa);
        const t = try Terminal.init(gpa, .{ .cols = 40, .rows = 12 });
        defer t.deinit();
        var i: usize = 0;
        while (i < chunk_stream.len) : (i += chunk) t.write(chunk_stream[i..@min(i + chunk, chunk_stream.len)]);
        try fingerprint(t, &fp, gpa);
        std.testing.expectEqualStrings(whole_fp.items, fp.items) catch |e| {
            std.debug.print("chunk size {d} changed the grid\n", .{chunk});
            return e;
        };
    }
}
