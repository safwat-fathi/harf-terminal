import AppKit
import CHarf

/// What a menu item does: an action by name, as a key binding names it.
final class ActionBox: NSObject {
    let action: String
    let arg: [UInt8]
    init(_ action: String, _ arg: [UInt8] = []) {
        self.action = action
        self.arg = arg
    }
}

/// The menus: title, then (item, action). Each item shows the shortcut the key bindings give its action.
private let menuLayout: [(String, [(String, String)])] = [
    ("Harf", [("Settings…", "open_config"), ("Choose Editor…", "choose_editor"), ("Reload Config", "reload_config"), ("Quit Harf", "quit")]),
    ("Shell", [("New Window", "new_window"), ("New Tab", "new_tab"), ("Close", "close"), ("Split Right", "split_right"), ("Split Down", "split_down"), ("Clear", "clear")]),
    ("Edit", [("Undo", "undo"), ("Copy", "copy"), ("Paste", "paste"), ("Select All", "select_all"), ("Find…", "find"), ("Find Next", "find_next"), ("Find Previous", "find_prev")]),
    ("View", [("Larger", "font_larger"), ("Smaller", "font_smaller"), ("Actual Size", "font_reset")]),
    ("Window", [("Next Tab", "next_tab"), ("Previous Tab", "prev_tab"), ("Next Pane", "focus_next"), ("Previous Pane", "focus_prev")]),
    ("About", [("About Harf", "about")]),
]

/// Resolves `url` to an existing directory path (following symlinks and Finder aliases). If `url` is a regular file, uses its parent directory.
func resolveDirectory(_ url: URL) -> String? {
    guard url.isFileURL else { return nil }
    let fm = FileManager.default
    var isDir: ObjCBool = false
    if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
        if isDir.boolValue { return url.path }
        if let resolved = try? URL(resolvingAliasFileAt: url, options: []), resolved.path != url.path,
           fm.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue {
            return resolved.path
        }
        return url.deletingLastPathComponent().path
    }
    return nil
}

/// Extracts existing directory paths from a Services pasteboard (file URLs first, then newline-separated paths/URLs in plain text).
func directories(from pboard: NSPasteboard) -> [String] {
    if let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
        return urls.compactMap(resolveDirectory)
    }
    guard let text = pboard.string(forType: .string) else { return [] }
    return text.components(separatedBy: .newlines).compactMap { line in
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let expanded = NSString(string: trimmed).expandingTildeInPath
        let url = expanded.hasPrefix("file://") ? URL(string: expanded) : (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : nil)
        return url.flatMap(resolveDirectory)
    }
}

/// Resolves directory arguments passed on the command line (ignoring macOS launch flags like `-psn_...` or `-NS...`).
func launchDirectories(from args: [String]) -> [String] {
    var dirs: [String] = []
    var i = 1
    var literalOnly = false
    while i < args.count {
        let arg = args[i]
        if !literalOnly, arg == "--" {
            literalOnly = true
            i += 1
            continue
        }
        if !literalOnly, arg.hasPrefix("-") {
            if (arg.hasPrefix("-NS") || arg.hasPrefix("-Apple")), i + 1 < args.count, !args[i + 1].hasPrefix("-") {
                i += 2
            } else {
                i += 1
            }
            continue
        }
        let expanded = NSString(string: arg).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        if let dir = resolveDirectory(url) {
            dirs.append(dir)
        } else {
            FileHandle.standardError.write(Data("harf: not a directory: \(arg)\n".utf8))
        }
        i += 1
    }
    return dirs
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [WindowController] = []
    var launchDirectories: [String] = []
    private var openedOnLaunch = false

    /// The terminal that has the keyboard, if one does (the find field of a pane counts as its pane's).
    func focusedController() -> TerminalController? { focusedPane()?.controller }

    private func controller(of window: NSWindow?) -> WindowController? { windows.first { $0.window === window } }

    func focusedPane() -> TerminalPane? { controller(of: NSApp.keyWindow)?.focusedPane() }

    private func frontmostWindow() -> NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.orderedWindows.first(where: { controller(of: $0) != nil }) ?? windows.last?.window
    }

    /// A new window (or a tab of the frontmost window) with a login shell, starting in `cwd` (or where the focused terminal is).
    @discardableResult
    func openWindow(tab: Bool, argv: [String]? = nil, content: NSSize? = nil, cwd: String? = nil) -> WindowController? {
        let target = frontmostWindow()
        let defaultSize = NSSize(width: Settings.shared.windowWidth, height: Settings.shared.windowHeight)
        let size = content ?? (tab ? target?.contentView?.bounds.size : nil) ?? defaultSize
        guard let wc = WindowController(argv: argv, content: size, cwd: cwd ?? focusedController()?.currentDirectory()) else { return nil }
        wc.onClose = { [weak self] closing in self?.windows.removeAll { $0 === closing } }
        windows.append(wc)
        if tab, let target { target.addTabbedWindow(wc.window, ordered: .above) }
        else if let target { wc.window.cascadeTopLeft(from: NSPoint(x: target.frame.minX + 28, y: target.frame.maxY - 28)) }
        else { wc.window.center() }
        wc.window.makeKeyAndOrderFront(nil)
        wc.window.makeFirstResponder(wc.allPanes.first?.controller.view)
        return wc
    }

    private func initialContentSize() -> NSSize {
        // Measurement hook (docs/perf.md): HARF_CONTENT_SIZE=WxH pins the window, e.g. 700x420 for the 80x24 class.
        var content = NSSize(width: Settings.shared.windowWidth, height: Settings.shared.windowHeight)
        if let s = ProcessInfo.processInfo.environment["HARF_CONTENT_SIZE"] {
            let p = s.split(separator: "x").compactMap { Double($0) }
            if p.count == 2 { content = NSSize(width: p[0], height: p[1]) }
        }
        return content
    }

    private func initialArgv() -> [String]? {
        // Measurement hook (bench/footprint.sh): HARF_CHILD_CMD runs a command first, then the user's shell.
        if let cmd = ProcessInfo.processInfo.environment["HARF_CHILD_CMD"], !cmd.isEmpty {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            return ["/bin/sh", "-c", "\(cmd); exec \(shell) -l"]
        }
        return nil
    }

    private func openInitialWindow() {
        openedOnLaunch = true
        guard openWindow(tab: false, argv: initialArgv(), content: initialContentSize()) != nil else { fatalError("cannot start the terminal") }
        traceStep("window built and shown")
        NSApp.activate()
    }

    /// Opens a window (or tab in the frontmost window) for each directory in `dirs`.
    @discardableResult
    func openDirectories(_ dirs: [String], tab: Bool) -> Bool {
        guard !dirs.isEmpty else { return false }
        openedOnLaunch = true
        for dir in dirs {
            let size = windows.isEmpty ? initialContentSize() : nil
            _ = openWindow(tab: tab, content: size, cwd: dir)
        }
        NSApp.activate()
        return true
    }

    /// Runs an action named by a key binding or a menu item. Returns whether it was one.
    @discardableResult
    func perform(_ action: String, _ arg: [UInt8], from c: TerminalController?) -> Bool {
        let wc = controller(of: c?.view.window ?? NSApp.keyWindow)
        let pane = c.flatMap { enclosingPane(of: $0.view) } ?? wc?.focusedPane()
        switch action {
        case "about": NSApp.orderFrontStandardAboutPanel(options: [.version: ""])
        case "quit": NSApp.terminate(nil)
        case "open_config": Settings.shared.openConfigFile()
        case "choose_editor": chooseEditor()
        case "reload_config": Settings.shared.reload()
        case "font_larger": Settings.shared.fontLarger()
        case "font_smaller": Settings.shared.fontSmaller()
        case "font_reset": Settings.shared.fontReset()
        case "new_window": openWindow(tab: false)
        case "new_tab": openWindow(tab: true)
        case "close": if let pane, let wc { wc.close(pane: pane) } else { NSApp.keyWindow?.performClose(nil) }
        case "split_right": if let pane, let wc { wc.split(pane, vertical: true) }
        case "split_down": if let pane, let wc { wc.split(pane, vertical: false) }
        case "focus_next": wc?.focusPane(next: true)
        case "focus_prev": wc?.focusPane(next: false)
        case "next_tab": NSApp.keyWindow?.selectNextTab(nil)
        case "prev_tab": NSApp.keyWindow?.selectPreviousTab(nil)
        case "goto_tab":
            let n = Int(String(decoding: arg, as: UTF8.self)) ?? 0
            if let tabs = NSApp.keyWindow?.tabbedWindows, n >= 1, n <= tabs.count { tabs[n - 1].makeKeyAndOrderFront(nil) }
        case "find": pane?.showFind()
        case "find_next", "find_prev":
            if let pane, pane.isFindOpen { pane.findStep(older: action == "find_next") } else { pane?.showFind() }
        case "copy", "paste", "select_all", "undo":
            // the find field has the keyboard: it is the one to paste into, select all in and undo in, and to copy from when the user
            // selected something in it. Otherwise Cmd+C copies the terminal's selection, which is where the current find match is.
            if let text = (c?.view.window ?? NSApp.keyWindow)?.firstResponder as? NSTextView, action != "copy" || text.selectedRange.length > 0 {
                switch action {
                case "copy": text.copy(nil)
                case "paste": text.paste(nil)
                case "select_all": text.selectAll(nil)
                default: text.undoManager?.undo()
                }
            } else if let c { return c.perform(action, arg: arg) } else { return pane?.controller.perform(action, arg: arg) ?? false }
        default: return c?.perform(action, arg: arg) ?? pane?.controller.perform(action, arg: arg) ?? false
        }
        return true
    }

    @objc func menuAction(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ActionBox else { return }
        perform(box.action, box.arg, from: focusedController())
    }

    /// Builds the menus from the key bindings, so a remapped shortcut shows in its menu.
    func rebuildMenu() {
        let main = NSMenu()
        for (title, items) in menuLayout {
            let top = NSMenuItem()
            main.addItem(top)
            let menu = NSMenu(title: title)
            for (text, action) in items {
                let mi = NSMenuItem(title: text, action: #selector(menuAction(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = ActionBox(action)
                let shortcuts = Settings.shared.bindings.filter { $0.value.action == action && $0.key.key.unicodeScalars.count == 1 }
                if let t = shortcuts.keys.min(by: { ($0.mods.nonzeroBitCount, $0.key) < ($1.mods.nonzeroBitCount, $1.key) }) {
                    mi.keyEquivalent = t.key
                    var mask: NSEvent.ModifierFlags = []
                    if t.mods & UInt8(HARF_MOD_SHIFT) != 0 { mask.insert(.shift) }
                    if t.mods & UInt8(HARF_MOD_CTRL) != 0 { mask.insert(.control) }
                    if t.mods & UInt8(HARF_MOD_ALT) != 0 { mask.insert(.option) }
                    if t.mods & UInt8(HARF_MOD_SUPER) != 0 { mask.insert(.command) }
                    mi.keyEquivalentModifierMask = mask
                }
                menu.addItem(mi)
            }
            top.submenu = menu
            if title == "Window" { NSApp.windowsMenu = menu }   // AppKit adds the tab and window items to it
        }
        NSApp.mainMenu = main
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        traceStep("applicationWillFinishLaunching")
        Log.start()   // first, so config warnings land in the file
        Settings.shared.load()   // before any terminal exists (including launch-time open or Services); it builds the menu
        traceStep("main menu installed, configuration loaded")
        NSApp.servicesProvider = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        traceStep("applicationDidFinishLaunching")
        if !launchDirectories.isEmpty {
            openDirectories(launchDirectories, tab: false)
            traceStep("window built and shown")
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        launchDirectories.isEmpty && !openedOnLaunch && windows.isEmpty
    }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        guard !openedOnLaunch && windows.isEmpty else { return false }
        openInitialWindow()
        return true
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        openDirectories(urls.compactMap(resolveDirectory), tab: false)
    }

    @objc func newTerminalAtFolder(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let dirs = directories(from: pboard)
        guard !dirs.isEmpty else {
            error.pointee = "No valid folder was selected." as NSString
            return
        }
        openDirectories(dirs, tab: userData == "New Tab")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) { Log.info("quit") }
}
