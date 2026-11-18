import AppKit
import CHarf

/// The Phase 3 terminal theme's background (the Zig painter fills with the same color).
let terminalBackground = NSColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 1)

/// What the I/O thread's callbacks point at. It outlives the session: the callbacks retain it
/// before hopping to the main queue, so a queued block never sees a freed object.
final class CallbackTarget: @unchecked Sendable {
    // Only read and written on the main thread.
    nonisolated(unsafe) weak var controller: TerminalController?
}

private func hop(_ ctx: UnsafeMutableRawPointer?, _ work: @escaping @MainActor (TerminalController) -> Void) {
    guard let ctx else { return }
    let addr = UInt(bitPattern: Unmanaged<CallbackTarget>.fromOpaque(ctx).retain().toOpaque())
    DispatchQueue.main.async {
        let target = Unmanaged<CallbackTarget>.fromOpaque(UnsafeRawPointer(bitPattern: addr)!).takeRetainedValue()
        MainActor.assumeIsolated {
            if let c = target.controller { work(c) }
        }
    }
}

// The session calls these on its I/O thread, so they must not be main-actor isolated: they are
// globals, not closures written inside the controller (which would inherit its isolation).
private let wakeCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ctx in hop(ctx) { $0.wakeOnMain() } }
private let titleCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ctx in hop(ctx) { $0.titleOnMain() } }
private let bellCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ctx in hop(ctx) { $0.onBell() } }
private let exitedCallback: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void = { ctx, status in hop(ctx) { $0.exitedOnMain(status) } }

private let commandCallback: @convention(c) (UnsafeMutableRawPointer?, Int32, Int32, Int32, UInt32) -> Void = { ctx, running, exitCode, hasExitCode, ms in
    hop(ctx) { $0.onCommand(running != 0, hasExitCode != 0 ? exitCode : nil, ms) }
}

/// What the paste sheet says.
struct PasteSummary {
    var title: String
    var detail: String
}

/// Characters the paste sheet must not show as they are: controls (except tab), and the ones that reorder or hide the text around
/// them (right-to-left marks, embeddings, overrides and isolates, line and paragraph separators). A joiner is kept: Persian and emoji need it.
private func hiddenInPreview(_ s: Unicode.Scalar) -> Bool {
    if s == "\t" { return false }
    if s.properties.generalCategory == .control { return true }
    switch s.value {
    case 0x061C, 0x200E, 0x200F, 0x2028, 0x2029, 0x202A...0x202E, 0x2066...0x2069: return true
    default: return false
    }
}

/// The sheet's text for a paste of `text` that `harf_term_paste_check` flagged (`risk`: bit 1 would run lines, bit 2 very large): the
/// size, the reason, and up to five lines of preview. The text is a program's or a web page's, so control characters are shown as a dot.
func pasteSummary(of text: String, risk: Int32) -> PasteSummary {
    // Line breaks are what the program sees as Enter (LF, CR, CRLF), counted over the bytes in one pass, and the preview is built
    // from the first characters only: a 10 MB paste must not make the sheet wait on the whole text.
    var breaks = 0
    var previous: UInt8 = 0
    for byte in text.utf8 {
        if byte == 13 || (byte == 10 && previous != 13) { breaks += 1 }
        previous = byte
    }
    let endsWithBreak = previous == 10 || previous == 13   // a trailing break ends the last line, it does not start one
    let lineCount = max(1, breaks + (endsWithBreak ? 0 : 1))
    let size = ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .file)
    let title = lineCount > 1 ? "Paste \(lineCount) lines (\(size))?" : "Paste \(size)?"
    var reasons: [String] = []
    if risk & 1 != 0 { reasons.append("This program has not asked for bracketed paste, so each line runs as soon as it is pasted.") }
    if risk & 2 != 0 { reasons.append("This is a very large paste.") }
    func shown(_ line: Substring) -> String {
        let scalars = Array(line.unicodeScalars.prefix(81)).map { hiddenInPreview($0) ? "\u{00B7}" : $0 }
        let head = String(String.UnicodeScalarView(scalars.prefix(80)))
        return scalars.count > 80 ? head + "…" : head
    }
    let head = text.prefix(1000)
    let rows = head.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
    var preview = rows.prefix(5).map(shown)
    // the last row read may go on past what was read: say so, or a long line looks like it ends where the reading stopped
    if head.endIndex < text.endIndex, rows.count <= 5, let last = preview.indices.last, !preview[last].hasSuffix("…") { preview[last] += "…" }
    if lineCount > min(5, rows.count) { preview.append("…") }
    return PasteSummary(title: title, detail: (reasons + [""] + preview).joined(separator: "\n"))
}

private func utf8String(_ p: UnsafePointer<UInt8>?, _ n: Int) -> String {
    guard let p, n > 0 else { return "" }
    return String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self)   // copies: the core's bytes are borrowed
}
private let clipboardCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void = { ctx, p, n in
    let text = utf8String(p, n)
    hop(ctx) { $0.clipboardOnMain(text) }
}
private let notifyCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int, UnsafePointer<UInt8>?, Int) -> Void = { ctx, t, tn, b, bn in
    let title = utf8String(t, tn), body = utf8String(b, bn)
    hop(ctx) { $0.onNotify(title, body) }
}

// Measurement hooks. HARF_MEASURE=1 records when each frame finished (read by the self-test's latency section);
// HARF_TRACE=startup prints the time from process start to the end of the first frame. Both cost one environment
// lookup at launch and nothing per frame when off.
nonisolated(unsafe) var measureFrameEnd: Double = 0
nonisolated(unsafe) var measureDirtyMarks = 0   // how many times the wake path has marked the view dirty (HARF_MEASURE only)
nonisolated(unsafe) var measureScans = 0   // how many times the wake path has scanned the grid for changed rows (HARF_MEASURE and the self-test only)
nonisolated(unsafe) var measureDirtyRect = NSRect.null   // the union of the rectangles the wake path invalidated since the last reset
nonisolated(unsafe) var trackDirty = false   // the self-test sets it to record the three values above; HARF_MEASURE=1 sets it for the whole run
/// HARF_FULL_REDRAW=1 draws the whole view on every change, as before dirty rows: an escape hatch for telling whether a
/// drawing oddity comes from partial redraws.
private let forceFullRedraw = ProcessInfo.processInfo.environment["HARF_FULL_REDRAW"] == "1"
/// The wake path scans the grid for changed rows at most once per interval (one frame at 120 Hz); see `wakeOnMain`.
let scanInterval = 1.0 / 120
private let measureFrames = ProcessInfo.processInfo.environment["HARF_MEASURE"] == "1"
private var recordDirty: Bool { measureFrames || trackDirty }
private let traceStartup = ProcessInfo.processInfo.environment["HARF_TRACE"] == "startup"
nonisolated(unsafe) private var startupReported = false

private func processStartTime() -> Double? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return nil }
    let t = info.kp_proc.p_un.__p_starttime
    return Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000
}

/// Prints the time since process start with a label (HARF_TRACE=startup).
func traceStep(_ label: String) {
    guard traceStartup, let start = processStartTime() else { return }
    var now = timeval()
    gettimeofday(&now, nil)
    print(String(format: "  +%.1f ms %@", (Double(now.tv_sec) + Double(now.tv_usec) / 1_000_000 - start) * 1000, label))
    fflush(stdout)
}

func noteFrameEnd() {
    if measureFrames { measureFrameEnd = ProcessInfo.processInfo.systemUptime }
    if traceStartup && !startupReported {
        startupReported = true
        var now = timeval()
        gettimeofday(&now, nil)
        if let start = processStartTime() {
            print(String(format: "startup_ms=%.1f", (Double(now.tv_sec) + Double(now.tv_usec) / 1_000_000 - start) * 1000))
            fflush(stdout)
        }
    }
}

/// Owns one session, its painter and its view. All methods run on the main thread.
@MainActor
final class TerminalController {
    let view: TerminalView
    private var term: OpaquePointer?
    private var painter: OpaquePointer?
    private let target = CallbackTarget()
    private var retainedTarget: Unmanaged<CallbackTarget>?
    private(set) var scale: CGFloat
    private var cellPx = (w: CGFloat(8), h: CGFloat(16))
    private var fontPt: CGFloat { Settings.shared.fontPt }
    /// The font the painter was made for, so a reload that changes only colors keeps the painter and its caches.
    private var paintedFont = (family: "", pt: CGFloat(0), scale: CGFloat(0))
    private let inset: CGFloat = 6
    private(set) var gridSize = (cols: 0, rows: 0)
    /// Cell size and grid inset in points, for the self-test.
    var cellSizePt: CGSize { CGSize(width: cellPx.w / scale, height: cellPx.h / scale) }
    var insetPt: CGFloat { inset }
    private(set) var exitStatus: Int32?

    var onTitle: (String) -> Void = { _ in }
    var onBell: () -> Void = {}
    var onExit: (Int32) -> Void = { _ in }
    /// A program asked for a desktop notification (OSC 9, OSC 777): sanitized title (may be empty) and body.
    var onNotify: (String, String) -> Void = { _, _ in }
    /// OSC 133: a command started running or ended (its exit code if the shell sent one, and how long it ran in milliseconds).
    var onCommand: (_ running: Bool, _ exitCode: Int32?, _ durationMs: UInt32) -> Void = { _, _, _ in }
    /// The view became the first responder (the window's title follows the focused pane).
    var onFocus: () -> Void = {}
    /// Where OSC 52 writes and Cmd+C copies go (the self-test points it at a private pasteboard).
    var clipboard: NSPasteboard = .general
    /// May a program change the clipboard right now? Only while the user is typing into this very terminal (`hasKeyboard`): a
    /// program in another window, tab or split pane must not replace what the user copied (paste-jacking). The self-test
    /// overrides it.
    lazy var clipboardWriteAllowed: () -> Bool = { [weak self] in self?.hasKeyboard() ?? false }

    /// True while the app is active, its window is key, and this terminal's pane (its find field counts) has the keyboard, not a
    /// sibling pane or another tab. A terminal with no pane around it is its window's only terminal.
    func hasKeyboard() -> Bool { NSApp.isActive && view.window?.isKeyWindow == true && paneIsFirstResponder }

    /// This terminal's pane (its find field counts) holds its window's first responder. A terminal with no pane around it is
    /// its window's only terminal. The cursor and focus reports follow this, so one pane per window looks focused.
    var paneIsFirstResponder: Bool {
        guard let pane = enclosingPane(of: view) else { return true }
        return enclosingPane(of: view.window?.firstResponder) === pane
    }

    /// `argv` nil runs the login shell. `frame` is the view's initial size in points.
    init?(argv: [String]?, frame: NSSize, scale: CGFloat = 2, cwd: String? = nil) {
        self.scale = scale
        view = TerminalView(frame: NSRect(origin: .zero, size: frame))
        view.registerForDraggedTypes([.fileURL])
        target.controller = self
        guard makePainter() else { return nil }
        let size = fitGrid(frame)
        let cstrs: [UnsafeMutablePointer<CChar>?] = (argv ?? []).map { strdup($0) } + [nil]
        defer { cstrs.forEach { free($0) } }
        var cb = HarfTermCallbacks(ctx: nil, wake: wakeCallback, title: titleCallback, bell: bellCallback, exited: exitedCallback,
                                 clipboard_write: clipboardCallback, notify: notifyCallback, command: commandCallback)
        let cwdC = cwd.flatMap { strdup($0) }
        defer { free(cwdC) }
        let retained = Unmanaged.passRetained(target)
        retainedTarget = retained
        cb.ctx = retained.toOpaque()
        term = cstrs.withUnsafeBufferPointer { buf -> OpaquePointer? in
            let argvPtr = UnsafeMutablePointer(mutating: buf.baseAddress!)
            return argvPtr.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: buf.count) { p in
                harf_term_new_in(UInt16(size.cols), UInt16(size.rows), Settings.shared.scrollbackBytes, argv == nil ? nil : p, cwdC, &cb)
            }
        }
        guard term != nil else { return nil }
        gridSize = size
        view.controller = self
        Settings.shared.register(self)
        applyTheme()
        if let t = term { harf_term_set_clipboard_write(t, Settings.shared.clipboardWrite ? 1 : 0) }
    }

    /// The configuration changed (or the font size did): a new font, theme and policies, and the grid refit to the new cell size.
    func applySettings() {
        guard let t = term else { return }
        if paintedFont.family != Settings.shared.fontFamily || paintedFont.pt != fontPt { makePainter() }
        applyTheme()
        harf_term_set_clipboard_write(t, Settings.shared.clipboardWrite ? 1 : 0)
        layoutChanged(force: true)
    }

    /// The theme for the system's current appearance goes to the core, which also tells a program that asked (mode 2031).
    /// With no configuration loaded the terminal keeps its built-in dark colors.
    func applyTheme() {
        guard let t = term else { return }
        if var theme = Settings.shared.theme() { _ = harf_term_set_theme(t, &theme) }
        harf_term_set_scheme(t, Settings.shared.isDark ? 1 : 0)
        view.needsDisplay = true
    }

    /// The child's working directory, so a new tab or pane can start where this one is. Nil if the system will not say.
    func currentDirectory() -> String? {
        guard let t = term else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(harf_term_pid(t), PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    /// Find: the number of matches for `text` (an empty text ends the find). Nothing is selected until `findStep`.
    func findStart(_ text: String) -> Int {
        guard let t = term else { return 0 }
        let bytes = Array(text.utf8)
        return bytes.withUnsafeBufferPointer { Int(harf_term_find(t, $0.baseAddress ?? UnsafePointer(bitPattern: 1)!, bytes.count)) }
    }

    /// Selects the next match toward older output (or newer), wrapping, and scrolls to it: its 1-based number and the total.
    func findStep(older: Bool) -> (number: Int, total: Int)? {
        guard let t = term else { return nil }
        var number = 0, total = 0
        return harf_term_find_step(t, older ? 1 : 0, &number, &total) == 1 ? (number, total) : nil
    }

    func findEnd() {
        if let t = term { harf_term_find_end(t) }
    }

    /// An action that works on this terminal. False if it is not one (the app handles it, or it does not exist).
    func perform(_ action: String, arg: [UInt8]) -> Bool {
        guard let t = term else { return false }
        switch action {
        case "copy": copySelection()
        case "paste": if let s = NSPasteboard.general.string(forType: .string) { paste(s) }
        case "clear": _ = harf_term_clear(t, 1)
        case "clear_view": return harf_term_clear(t, 0) == 1   // on the alternate screen the key is the program's
        case "prev_prompt": return harf_term_scroll_prompt(t, -1) == 1   // false (alternate screen): the key is the program's
        case "next_prompt": return harf_term_scroll_prompt(t, 1) == 1
        case "select_output": return harf_term_select_output(t) == 1
        case "send": _ = arg.withUnsafeBufferPointer { harf_term_input(t, $0.baseAddress, arg.count) }
        default: return false
        }
        return true
    }

    /// Stops the session. Safe to call twice. No callback runs after it returns.
    func close() {
        if let t = term {
            term = nil
            harf_term_free(t)
        }
        retainedTarget?.release()
        retainedTarget = nil
        if let p = painter {
            painter = nil
            harf_painter_free(p)
        }
        view.controller = nil
    }

    deinit { MainActor.assumeIsolated { close() } }

    // MARK: layout

    @discardableResult
    private func makePainter() -> Bool {
        let family = Settings.shared.fontFamily
        let size = Float(fontPt * scale)
        var made = harf_painter_new_font(family, size)
        if made == nil {
            if family != "Menlo" { FileHandle.standardError.write(Data("harf: font_family '\(family)' is not an installed monospaced font; using Menlo\n".utf8)) }
            made = harf_painter_new(size)
        }
        guard let p = made else { return false }
        if let old = painter { harf_painter_free(old) }
        painter = p
        hover = nil   // the new painter has no highlight, and the pointing hand would outlive its tint
        view.window?.invalidateCursorRects(for: view)
        paintedFont = (family, fontPt, scale)
        var m = HarfCellMetrics()
        harf_painter_metrics(p, &m)
        cellPx = (CGFloat(m.cell_w), CGFloat(m.cell_h))
        return true
    }

    private func fitGrid(_ size: NSSize) -> (cols: Int, rows: Int) {
        let cw = cellPx.w / scale, ch = cellPx.h / scale
        // The small slack keeps a window sized for exactly N cells at N columns despite floating-point rounding.
        return (max(1, Int(((size.width - 2 * inset) / cw + 1e-6).rounded(.down))),
                max(1, Int(((size.height - 2 * inset) / ch + 1e-6).rounded(.down))))
    }

    /// The view's size or backing scale changed: refit the grid and tell the session.
    func layoutChanged(scale newScale: CGFloat? = nil, force: Bool = false) {
        guard let t = term else { return }
        if let s = newScale, s != scale {
            scale = s
            makePainter()
        }
        let size = fitGrid(view.bounds.size)
        if size.cols != gridSize.cols || size.rows != gridSize.rows || newScale != nil || force {
            gridSize = size
            harf_term_resize(t, UInt16(size.cols), UInt16(size.rows), UInt32(cellPx.w), UInt32(cellPx.h))
        }
        view.needsDisplay = true
    }

    // MARK: input

    /// A key event. Returns true if the terminal handled it (function keys, Control combinations,
    /// lone modifiers); false means it is a text key and the caller sends its text.
    func sendKey(code: UInt16, mods: UInt32, text: String, unshifted: UInt32 = 0, action: Int32 = 0) -> Bool {
        guard let t = term else { return true }
        let bytes = Array(text.utf8)
        return bytes.withUnsafeBufferPointer { harf_term_key(t, code, mods, $0.baseAddress, bytes.count, unshifted, action) } != 0
    }

    /// Text typed or composed: goes to the child as UTF-8.
    func sendText(_ text: String) {
        guard let t = term, !text.isEmpty else { return }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { harf_term_input(t, $0.baseAddress, bytes.count) }
    }

    /// A left-button selection gesture at `p` (view points). phase: 0 press, 1 drag, 2 release.
    func selection(_ phase: Int32, clickCount: Int, mods: UInt32, at p: NSPoint) {
        guard let t = term, let painter else { return }
        let x = Double((p.x - inset) * scale), y = Double((p.y - inset) * scale)
        _ = harf_term_selection_event(t, painter, phase, Int32(clickCount), mods, x, y)
    }

    /// The selected text in logical order, or nil.
    func selectedText() -> String? {
        guard let t = term else { return nil }
        var len = 0
        guard let ptr = harf_term_selection_text(t, &len) else { return nil }
        defer { harf_free(ptr) }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
    }

    /// Cmd+C: the selection goes to the pasteboard; nothing selected does nothing.
    func copySelection(to pasteboard: NSPasteboard? = nil) {
        guard let s = selectedText() else { return }
        let pb = pasteboard ?? clipboard
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    /// The terminal's default background right now (a program's OSC 11 changes it).
    func defaultBackground() -> NSColor? {
        guard let t = term else { return nil }
        var rgb: [UInt8] = [0, 0, 0]
        harf_term_default_bg(t, &rgb)
        return NSColor(srgbRed: CGFloat(rgb[0]) / 255, green: CGFloat(rgb[1]) / 255, blue: CGFloat(rgb[2]) / 255, alpha: 1)
    }

    /// The terminal's real grid (a program can change it, for example to 132 columns, behind the view's back).
    func coreGrid() -> (cols: Int, rows: Int) {
        guard let t = term else { return (0, 0) }
        var cols: UInt16 = 0, rows: UInt16 = 0
        harf_term_grid(t, &cols, &rows)
        return (Int(cols), Int(rows))
    }

    /// This terminal gained (true) or lost (false) the keyboard: the cursor look follows, and so does a program that asked for focus events.
    func setFocus(_ on: Bool) {
        guard let t = term else { return }
        _ = harf_term_focus(t, on ? 1 : 0)
    }

    /// Wheel or trackpad, in rows: positive toward newer output.
    func scroll(rows: Int32) {
        guard let t = term, rows != 0 else { return }
        _ = harf_term_scroll(t, rows)
    }

    /// A mouse event at `p` (view points). True if the program took it (mouse tracking); false means the
    /// caller keeps it. Mods with Shift only record the pointer position.
    @discardableResult
    func mouse(_ action: Int32, button: Int32, mods: UInt32, at p: NSPoint) -> Bool {
        guard let t = term, let painter else { return false }
        let x = Double((p.x - inset) * scale), y = Double((p.y - inset) * scale)
        return harf_term_mouse(t, painter, action, button, mods, x, y) == 1
    }

    /// Pastes `text`, after asking when the core says it should be confirmed (a line break in a program without bracketed paste, or a
    /// very large paste) and the guard is on. The text is captured now: the clipboard may change while the sheet is open.
    func paste(_ text: String) {
        guard let t = term, !text.isEmpty else { return }
        let bytes = Array(text.utf8)
        func send() {
            guard let t = self.term else { return }   // the session may have ended while the sheet was open
            _ = bytes.withUnsafeBufferPointer { harf_term_paste(t, $0.baseAddress, bytes.count) }
        }
        let risk = Settings.shared.pasteGuard ? bytes.withUnsafeBufferPointer { harf_term_paste_check(t, $0.baseAddress, bytes.count) } : 0
        if risk == 0 { return send() }
        confirmPaste(pasteSummary(of: text, risk: risk)) { ok in if ok { send() } }
    }

    /// The text a file drop types: each path shell-quoted (single quotes, so sh, bash, zsh and fish agree), a space after each. Nil when
    /// the pasteboard holds no file URL.
    func dropText(from pb: NSPasteboard) -> String? {
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return nil }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        return urls.map { url -> String in
            let p = url.path
            if p.unicodeScalars.allSatisfy(safe.contains) { return p + " " }
            // inside single quotes only ' needs care in sh, bash and zsh, but fish also reads \\ and \' there: close the quote around both
            return "'" + p.map { $0 == "'" ? "'\\''" : $0 == "\\" ? "'\\\\'" : String($0) }.joined() + "' "
        }.joined()
    }

    /// Asks whether to paste: a sheet on the window. The self-test replaces it. With no window to attach a sheet to it answers no.
    lazy var confirmPaste: (PasteSummary, @escaping (Bool) -> Void) -> Void = { [weak self] summary, done in
        guard let window = self?.view.window else { return done(false) }
        let alert = NSAlert()
        alert.messageText = summary.title
        alert.informativeText = summary.detail
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { done($0 == .alertFirstButtonReturn) }
    }

    // MARK: events from the session (already on the main thread)

    private var lastScan = -Double.infinity   // `systemUptime` when the last scan began

    /// The session woke us. The scan below visits every visible row with the session lock held, and during a flood the I/O thread wakes us
    /// after every read, so unthrottled it ran back to back and the parser spent most of its time waiting for the lock (docs/perf.md,
    /// "Flood throughput"). So the first wake after a quiet moment scans at once, and one that follows a scan by less than `scanInterval`
    /// waits out the rest of the interval. The wake stays armed until `scan` re-arms it, so no more wakes arrive while one is waiting:
    /// the timer is one-shot and idle costs nothing. A skipped scan loses nothing: `dirtyRows` compares with what was last *drawn*.
    /// An echo during streaming output can wait up to one interval (about 8 ms) for its scan.
    func wakeOnMain() {
        let wait = scanInterval - (ProcessInfo.processInfo.systemUptime - lastScan)
        if wait <= 0 { return scan() }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated { self?.scan() }
        }
    }

    private func scan() {
        guard let t = term else { return }
        lastScan = ProcessInfo.processInfo.systemUptime
        if recordDirty { measureScans += 1 }
        harf_term_wake_handled(t)   // re-arm before reading, so output arriving during the draw wakes us again
        followProgramGrid()
        invalidateChangedRows()
        if hover != nil, let window = view.window {   // the text under a tinted link may have changed or scrolled
            updateHover(command: NSEvent.modifierFlags.contains(.command), at: view.convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    private var dirtyRows = [UInt8](repeating: 0, count: 256)

    /// Asks AppKit to redraw only the rows that differ from what was last drawn (`harf_term_dirty_rows`), one rectangle per
    /// run of rows. Everything that changes the picture without output (focus, selection, scrolling the viewport, colors)
    /// changes a row's cells or the frame key, so it shows up here too; a resize or a new backing scale goes through
    /// `layoutChanged`, which invalidates the whole view.
    private func invalidateChangedRows() {
        guard let t = term, let p = painter else { return }
        let n = harf_term_dirty_rows(t, p, &dirtyRows, dirtyRows.count)
        let chPt = cellPx.h / scale
        // A partial rectangle is exact only if its edges fall on whole device pixels; otherwise AppKit rounds it outward and a
        // row could be painted in part. The usual scales (1, 2, 3) are exact; the others redraw the whole view.
        let exact = (inset * scale).truncatingRemainder(dividingBy: 1) == 0 && cellPx.h.truncatingRemainder(dividingBy: 1) == 0
        guard exact, !forceFullRedraw, n <= dirtyRows.count, n == gridSize.rows else { return markDirty() }
        var row = 0
        while row < n {
            if dirtyRows[row] == 0 { row += 1; continue }
            var end = row
            while end + 1 < n && dirtyRows[end + 1] != 0 { end += 1 }
            let rect = NSRect(x: 0, y: inset + CGFloat(row) * chPt, width: view.bounds.width, height: CGFloat(end - row + 1) * chPt)
            view.setNeedsDisplay(rect)
            if recordDirty { measureDirtyMarks += 1; measureDirtyRect = measureDirtyRect.union(rect) }
            row = end + 1
        }
    }

    /// A program can change the grid itself (DECCOLM switches 80 and 132 columns). The window follows: it is resized so the
    /// grid fits it exactly, which also keeps the right-hand columns from being clipped. A window the user has put
    /// in full screen refuses the resize and keeps its size; the next ordinary resize refits the grid to the window.
    private func followProgramGrid() {
        let g = coreGrid()
        guard g.cols > 0, g.rows > 0, g.cols != gridSize.cols || g.rows != gridSize.rows else { return }
        let rowsChanged = g.rows != gridSize.rows
        gridSize = g
        // Only the dimension the program changed is resized, so a window dragged to an odd height keeps it.
        let size = NSSize(width: CGFloat(g.cols) * cellPx.w / scale + 2 * inset,
                          height: rowsChanged ? CGFloat(g.rows) * cellPx.h / scale + 2 * inset : view.bounds.height)
        guard let w = view.window else { return view.setFrameSize(size) }   // ends in layoutChanged
        // Only a terminal that fills its window can resize it. A pane in a split keeps its share (the window is not resized to one
        // pane's grid) and the next ordinary resize refits the grid.
        // ponytail: a program that asks for 132 columns in a narrow split is clipped, not given more room.
        if w.contentView === (enclosingPane(of: view) ?? view) { w.setContentSize(size) }   // ends in layoutChanged
    }

    /// Asks AppKit to draw the view. The one place the wake path does it, so the latency check can see it happen.
    private func markDirty() {
        view.needsDisplay = true
        if recordDirty { measureDirtyMarks += 1; measureDirtyRect = view.bounds }
    }

    fileprivate func titleOnMain() {
        guard let t = term else { return }
        var buf = [UInt8](repeating: 0, count: 512)
        let cap = buf.count
        let n = buf.withUnsafeMutableBufferPointer { bp in
            bp.baseAddress!.withMemoryRebound(to: CChar.self, capacity: cap) { harf_term_title(t, $0, cap) }
        }
        onTitle(String(decoding: buf[0..<min(n, cap)], as: UTF8.self))
    }

    /// OSC 52: the core allowed a program to put text on the clipboard (policy, standard clipboard only).
    fileprivate func clipboardOnMain(_ text: String) {
        guard clipboardWriteAllowed() else { return }
        clipboard.clearContents()
        clipboard.setString(text, forType: .string)
    }

    /// The OSC 8 hyperlink under `p` (view points), if it is one worth opening: http, https or mailto. Any other scheme
    /// (file:, an app's own scheme) could start something the user never meant to open, so a click on it does nothing.
    func hyperlink(at p: NSPoint) -> URL? {
        guard let t = term, let painter else { return nil }
        var buf = [UInt8](repeating: 0, count: 2048)
        let n = harf_term_hyperlink_at(t, painter, Double((p.x - inset) * scale), Double((p.y - inset) * scale), &buf, buf.count)
        guard n > 0, let url = URL(string: String(decoding: buf[0..<n], as: UTF8.self)),
              let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return nil }
        return url
    }

    /// The plain http or https URL under `p` (view points), if there is one: text a program printed without OSC 8.
    func urlTarget(at p: NSPoint) -> URL? {
        guard let t = term, let painter else { return nil }
        var buf = [UInt8](repeating: 0, count: 2048)
        let n = harf_term_url_at(t, painter, Double((p.x - inset) * scale), Double((p.y - inset) * scale), &buf, buf.count)
        guard n > 0, let url = URL(string: String(decoding: buf[0..<n], as: UTF8.self)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
        return url
    }

    /// The file under `p` (view points): a path as printed (`~/x`, absolute, or relative to this pane's directory), with its `:line`
    /// and `:col`. Nil unless it exists and is a regular file: the text came from a program, so it is checked, not trusted.
    func pathTarget(at p: NSPoint) -> PathTarget? {
        guard let t = term, let painter else { return nil }
        var buf = [UInt8](repeating: 0, count: 1024)
        var line: UInt32 = 0, col: UInt32 = 0
        let n = harf_term_path_at(t, painter, Double((p.x - inset) * scale), Double((p.y - inset) * scale), &buf, buf.count, &line, &col)
        guard n > 0 else { return nil }
        var path = (String(decoding: buf[0..<n], as: UTF8.self) as NSString).expandingTildeInPath
        if !path.hasPrefix("/") { path = (currentDirectory() ?? NSHomeDirectory()) + "/" + path }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        // a regular file, after following links: not a directory, and not a device or FIFO (`2>/dev/null` would offer /dev/null, and
        // opening /dev/zero in an editor never ends)
        guard (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
        return PathTarget(url: url, line: Int(line), col: Int(col))
    }

    /// The cells (row and first and last column) of the link under the pointer while Command is held; nil when there is none.
    private(set) var hover: (row: Int, lo: Int, hi: Int)?

    /// The cells of what a Command-click on `p` would open: an OSC 8 link of an allowed scheme, a plain http(s) URL, or a file that
    /// exists. Nil for anything else, so nothing is tinted that a click would not open.
    func hoverLink(at p: NSPoint) -> (row: Int, lo: Int, hi: Int)? {
        guard let t = term, let painter else { return nil }
        var row: UInt16 = 0, lo: UInt16 = 0, hi: UInt16 = 0
        let kind = harf_term_link_span_at(t, painter, Double((p.x - inset) * scale), Double((p.y - inset) * scale), &row, &lo, &hi)
        let openable: Bool
        switch kind {
        case 1: openable = hyperlink(at: p) != nil
        case 2: openable = urlTarget(at: p) != nil
        case 3: openable = pathTarget(at: p) != nil
        default: openable = false
        }
        return openable ? (Int(row), Int(lo), Int(hi)) : nil
    }

    /// Tints the link under the pointer (or clears it): the painter draws the tint with its row, so the old and new rows are redrawn
    /// and the pointing hand follows.
    func setHover(_ new: (row: Int, lo: Int, hi: Int)?) {
        guard let painter else { return }
        let old = hover
        if old?.row == new?.row && old?.lo == new?.lo && old?.hi == new?.hi { return }
        hover = new
        if let new {
            let c = NSColor.linkColor.usingColorSpace(.sRGB) ?? .systemBlue
            func byte(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
            harf_painter_set_highlight(painter, UInt16(new.row), UInt16(new.lo), UInt16(new.hi), byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
        } else {
            harf_painter_clear_highlight(painter)
        }
        for row in [old?.row, new?.row].compactMap({ $0 }) { invalidateRow(row) }
        view.window?.invalidateCursorRects(for: view)
    }

    /// Command held (or let go) with the pointer at `p`: the link under it is tinted only while Command is down.
    func updateHover(command: Bool, at p: NSPoint) {
        // flagsChanged goes to the key view wherever the pointer is, and the core clamps a pixel to the nearest cell: outside the view
        // there is nothing under the pointer
        setHover(command && view.bounds.contains(p) ? hoverLink(at: p) : nil)
    }

    /// Where the pointing hand shows, in view points.
    var hoverRect: NSRect? {
        guard let h = hover else { return nil }
        let w = cellPx.w / scale, ch = cellPx.h / scale
        return NSRect(x: inset + CGFloat(h.lo) * w, y: inset + CGFloat(h.row) * ch, width: CGFloat(h.hi - h.lo + 1) * w, height: ch)
    }

    private func invalidateRow(_ row: Int) {
        let chPt = cellPx.h / scale
        let exact = (inset * scale).truncatingRemainder(dividingBy: 1) == 0 && cellPx.h.truncatingRemainder(dividingBy: 1) == 0
        if exact { view.setNeedsDisplay(NSRect(x: 0, y: inset + CGFloat(row) * chPt, width: view.bounds.width, height: chPt)) } else { view.needsDisplay = true }
    }

    /// What a Command-click on a path or URL does; the self-test replaces them.
    lazy var openPath: (PathTarget) -> Void = { launchEditor($0) }
    lazy var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    fileprivate func exitedOnMain(_ status: Int32) {
        exitStatus = status
        onExit(status)
    }

    // MARK: drawing

    fileprivate func draw(in ctx: CGContext, dirty: NSRect) {
        defer { noteFrameEnd() }
        guard let t = term, let p = painter else { return }
        let chPt = cellPx.h / scale
        // The rows that touch the rectangle. The core also draws the row below `last`, whose glyphs can reach up into it.
        let first = max(0, Int(((dirty.minY - inset) / chPt).rounded(.down)))
        let last = max(first, Int(((dirty.maxY - inset) / chPt).rounded(.up)) - 1)
        ctx.saveGState()
        ctx.translateBy(x: inset, y: inset)
        ctx.scaleBy(x: 1 / scale, y: 1 / scale)   // the painter works in device pixels
        harf_term_draw(t, p, Unmanaged.passUnretained(ctx).toOpaque(), UInt16(min(first, 65535)), UInt16(min(last, 65535)))
        ctx.restoreGState()
    }

    /// UTF-8 text of visible row `row` (for the self-test).
    func rowText(_ row: Int) -> String {
        guard let t = term else { return "" }
        var buf = [CChar](repeating: 0, count: 1024)
        let n = harf_term_row_text(t, UInt16(row), &buf, buf.count)
        return String(decoding: buf[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// CPU-drawn terminal view: the Zig painter draws into the view's CGContext. No GPU, no timers.
@MainActor
final class TerminalView: NSView {
    weak var controller: TerminalController?

    override var isFlipped: Bool { true }   // y-down, matches the painter
    override var acceptsFirstResponder: Bool { true }

    /// Text AppKit has composed but not committed (a dead key); kept only so AppKit's state machine works.
    private var marked = ""

    private static func harfMods(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.shift) { m |= UInt32(HARF_MOD_SHIFT) }
        if f.contains(.control) { m |= UInt32(HARF_MOD_CTRL) }
        if f.contains(.option) { m |= UInt32(HARF_MOD_ALT) }
        if f.contains(.command) { m |= UInt32(HARF_MOD_SUPER) }
        return m
    }

    /// Keys whose press reached the program through the core. A release is forwarded only for these (a program that asked
    /// for event types, kitty flag 2, hears it); a key that typed text, or that the app itself used, has no release to report.
    private var forwardedKeys = Set<UInt16>()

    /// Function keys and Control combinations are encoded by the core; everything else is text.
    /// `text` is called only for text keys (it runs `interpretKeyEvents` in the real path).
    func handleKey(code: UInt16, mods: UInt32, characters: String, unshifted: UInt32 = 0, isRepeat: Bool, text: () -> Void) {
        let handled = controller?.sendKey(code: code, mods: mods, text: characters, unshifted: unshifted, action: isRepeat ? 2 : 0) == true
        if handled { forwardedKeys.insert(code) }
        // Command shortcuts belong to the menu; the core maps the editing keys, and nothing else is typed
        if handled || mods & UInt32(HARF_MOD_SUPER) != 0 { return }
        text()
    }

    /// The layout's text with Control removed (Control turns "c" into U+0003), and its character with no modifiers:
    /// the core names Control combinations by them, so AZERTY, Dvorak and Colemak work.
    private func keyText(_ event: NSEvent) -> (text: String, unshifted: UInt32) {
        let text = event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control)) ?? event.characters ?? ""
        return (text, event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0)
    }

    /// A key the configuration binds (Command shortcuts, `send:` remaps) runs its action and never reaches the program. This
    /// runs before the main menu sees the key, so a binding wins over a menu shortcut.
    private func runBinding(_ event: NSEvent) -> Bool {
        // AppKit offers a key to every terminal view in the window in turn, so only the view that has the keyboard may act: not a
        // sibling pane, and not while a text field (the find bar) has it, which keeps its own copy, paste and typing.
        // (A view with no window, as in the self-test, has nothing to compare with.)
        if let responder = window?.firstResponder, responder !== self { return false }
        guard let t = Trigger(event), let b = Settings.shared.bindings[t] else { return false }
        if controller?.perform(b.action, arg: b.arg) == true { return true }   // copy, paste, clear, send: this terminal's own
        return (NSApp.delegate as? AppDelegate)?.perform(b.action, b.arg, from: controller) ?? false
    }

    override func becomeFirstResponder() -> Bool {
        controller?.onFocus()
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        controller?.setHover(nil)   // Command may be released while another view has the keyboard
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        event.type == .keyDown && runBinding(event) ? true : super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if runBinding(event) { return }
        let k = keyText(event)
        handleKey(code: event.keyCode, mods: Self.harfMods(event.modifierFlags), characters: k.text, unshifted: k.unshifted,
                  isRepeat: event.isARepeat) { interpretKeyEvents([event]) }
    }

    override func keyUp(with event: NSEvent) {
        guard forwardedKeys.remove(event.keyCode) != nil else { return }
        let k = keyText(event)
        _ = controller?.sendKey(code: event.keyCode, mods: Self.harfMods(event.modifierFlags), text: k.text, unshifted: k.unshifted, action: 1)
    }

    @objc func paste(_ sender: Any?) {
        if let s = NSPasteboard.general.string(forType: .string) { controller?.paste(s) }
    }

    // A file dropped from Finder types its quoted path, as a paste.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let text = controller?.dropText(from: sender.draggingPasteboard) else { return false }
        controller?.paste(text)
        return true
    }

    /// Trackpad points convert to rows at the cell height; a wheel notch is three rows. The remainder
    /// carries over, so slow scrolling still moves. No timers.
    private var scrollRemainder: CGFloat = 0

    /// Sends the event to a mouse-tracking program; false means nobody took it.
    @discardableResult
    private func sendMouse(_ action: Int32, _ button: Int32, _ event: NSEvent) -> Bool {
        controller?.mouse(action, button: button, mods: Self.harfMods(event.modifierFlags), at: convert(event.locationInWindow, from: nil)) ?? false
    }

    /// True while a left drag belongs to the selection (the program did not take its press).
    private var selecting = false

    private func selectionEvent(_ phase: Int32, _ event: NSEvent) {
        controller?.selection(phase, clickCount: event.clickCount, mods: Self.harfMods(event.modifierFlags), at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        // Command-click opens an OSC 8 link, even while a program tracks the mouse
        // (then a plain http(s) URL a program printed, then a file path, which opens in the editor)
        let at = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command) {
            if let url = controller?.hyperlink(at: at) {
                NSWorkspace.shared.open(url)
                return
            }
            if let url = controller?.urlTarget(at: at) {
                controller?.openURL(url)
                return
            }
            if let target = controller?.pathTarget(at: at) {
                controller?.openPath(target)
                return
            }
        }
        selecting = !sendMouse(0, 1, event)
        if selecting { selectionEvent(0, event) }
    }
    override func mouseDragged(with event: NSEvent) {
        if selecting { selectionEvent(1, event) } else { sendMouse(2, 1, event) }
    }
    override func mouseUp(with event: NSEvent) {
        if selecting { selectionEvent(2, event); selecting = false } else { sendMouse(1, 1, event) }
    }

    @objc func copy(_ sender: Any?) { controller?.copySelection() }
    override func rightMouseDown(with event: NSEvent) { sendMouse(0, 2, event) }
    override func rightMouseUp(with event: NSEvent) { sendMouse(1, 2, event) }
    override func rightMouseDragged(with event: NSEvent) { sendMouse(2, 2, event) }
    override func otherMouseDown(with event: NSEvent) { sendMouse(0, 3, event) }
    override func otherMouseUp(with event: NSEvent) { sendMouse(1, 3, event) }
    override func otherMouseDragged(with event: NSEvent) { sendMouse(2, 3, event) }
    override func mouseMoved(with event: NSEvent) {
        controller?.updateHover(command: event.modifierFlags.contains(.command), at: convert(event.locationInWindow, from: nil))
        sendMouse(2, 0, event)
    }
    override func mouseExited(with event: NSEvent) { controller?.setHover(nil) }
    override func flagsChanged(with event: NSEvent) {
        if let window { controller?.updateHover(command: event.modifierFlags.contains(.command), at: convert(window.mouseLocationOutsideOfEventStream, from: nil)) }
        super.flagsChanged(with: event)
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        if let r = controller?.hoverRect { addCursorRect(r, cursor: .pointingHand) }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func scrollWheel(with event: NSEvent) {
        guard let c = controller else { return }
        // Wheel events to a mouse-tracking program carry the pointer's cell: record it (Shift = position only).
        c.mouse(2, button: 0, mods: UInt32(HARF_MOD_SHIFT), at: convert(event.locationInWindow, from: nil))
        if event.phase == .began || event.phase == .mayBegin { scrollRemainder = 0 }
        let rows = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / max(1, c.cellSizePt.height) : event.scrollingDeltaY * 3
        scrollRemainder += rows
        let whole = scrollRemainder.rounded(.towardZero)
        scrollRemainder -= whole
        if whole != 0 { c.scroll(rows: Int32(-whole)) }   // fingers down shows older output: toward the top
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // One rectangle at a time, exactly what AppKit is repainting: the painter records the rows it draws as up to date,
        // so it must not be asked for rows that fall between two separate rectangles.
        var rects: UnsafePointer<NSRect>?
        var count = 0
        getRectsBeingDrawn(&rects, count: &count)
        let list = rects.map { Array(UnsafeBufferPointer(start: $0, count: count)) } ?? [dirtyRect]
        for r in list {
            (controller?.defaultBackground() ?? terminalBackground).setFill()
            r.fill()
            controller?.draw(in: ctx, dirty: r)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        controller?.layoutChanged()
    }

    private var focusObservers: [NSObjectProtocol] = []
    private var firstResponderWatch: NSKeyValueObservation?
    /// From the window's key notifications (the self-test posts them for a window that is not really key).
    private var windowIsKey = false

    /// Focus is the key window's keyboard focus, and it belongs to one pane: the cursor is hollow in the others, and only the
    /// program in the focused pane hears focus in and out (mode 1004).
    private func syncFocus() { controller?.setFocus(windowIsKey && controller?.paneIsFirstResponder == true) }

    private var focusSyncPending = false

    /// The first responder changed. AppKit passes through states in which no pane has it (a find field's editor leaves the view
    /// tree while it is still the first responder), and a program must not hear focus out and in for that, so the sync waits for
    /// the end of the run-loop turn, when the keyboard has settled.
    private func syncFocusSoon() {
        guard !focusSyncPending else { return }
        focusSyncPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.focusSyncPending = false; self?.syncFocus() }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for o in focusObservers { NotificationCenter.default.removeObserver(o) }
        focusObservers = []
        firstResponderWatch = nil
        guard let w = window else { return }
        let nc = NotificationCenter.default
        func watch(_ name: Notification.Name, key: Bool) -> NSObjectProtocol {
            nc.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.windowIsKey = key
                    if !key { self?.controller?.setHover(nil) }   // Command-Tab away: no key event will say it was let go
                    self?.syncFocus()
                }
            }
        }
        focusObservers = [watch(NSWindow.didBecomeKeyNotification, key: true), watch(NSWindow.didResignKeyNotification, key: false)]
        // Every way the keyboard moves between panes (a click, Cmd+[ and Cmd+], a split, a close, the find bar) changes this.
        firstResponderWatch = w.observe(\.firstResponder, options: []) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.syncFocusSoon() }
        }
        windowIsKey = w.isKeyWindow
        syncFocus()
    }

    deinit {
        MainActor.assumeIsolated { for o in focusObservers { NotificationCenter.default.removeObserver(o) } }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let s = window?.backingScaleFactor { controller?.layoutChanged(scale: s) }
    }
}

// Minimal text input: committed text goes to the child. Marked text is tracked so dead keys
// (Option+E, then a vowel) compose; full IME is Phase 7.
extension TerminalView: @preconcurrency NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        marked = ""
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        controller?.sendText(text)
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    }
    func unmarkText() { marked = "" }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { marked.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: marked.utf16.count) }
    func hasMarkedText() -> Bool { !marked.isEmpty }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { .zero }
    func characterIndex(for point: NSPoint) -> Int { 0 }
    override func doCommand(by selector: Selector) {}   // Return, arrows etc. are handled before this
}
