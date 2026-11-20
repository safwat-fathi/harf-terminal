import AppKit
import CHarf

/// `Harf --selftest`: drives a controller without a window and checks drawing and resizing. Exits 0 on success.
@MainActor
func selfTest() -> Never {
    var tempScripts: [String] = []   // scripts the checks write; removed before the self-test ends, including on failure
    func fail(_ what: String) -> Never {
        print("selftest FAILED: \(what)")
        for p in tempScripts { try? FileManager.default.removeItem(atPath: p) }
        exit(1)
    }
    func pump(_ seconds: Double, until done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return done()
    }

    print("selftest: start")
    // 1. Output is parsed, drawn, and the grid refits on resize.
    guard let c = TerminalController(argv: ["/bin/sh", "-c", "printf 'hello مرحبا'; sleep 2"], frame: NSSize(width: 700, height: 420)) else { fail("cannot start") }
    if !pump(5, until: { c.rowText(0).contains("hello مرحبا") }) { fail("row 0 is '\(c.rowText(0))'") }
    guard let rep = c.view.bitmapImageRepForCachingDisplay(in: c.view.bounds) else { fail("no bitmap") }
    c.view.cacheDisplay(in: c.view.bounds, to: rep)
    // HARF_SELFTEST_PNG=<path> keeps a picture of the first view for a human to look at.
    if let path = ProcessInfo.processInfo.environment["HARF_SELFTEST_PNG"], let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
    }
    let px = Double(rep.pixelsWide) / Double(c.view.bounds.width)
    func ink(_ y0: Double, _ y1: Double) -> Bool {
        let bg = terminalBackground.usingColorSpace(.sRGB)!
        for y in stride(from: Int(y0 * px), to: Int(y1 * px), by: 2) {
            for x in stride(from: Int(6 * px), to: rep.pixelsWide - Int(6 * px), by: 2) {
                guard let col = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(col.redComponent - bg.redComponent) > 0.1 || abs(col.greenComponent - bg.greenComponent) > 0.1 { return true }
            }
        }
        return false
    }
    if !ink(6, 22) { fail("first row has no ink") }
    if ink(380, 414) { fail("last row has ink") }
    c.view.setFrameSize(NSSize(width: 1, height: 1))
    if c.gridSize.cols != 1 || c.gridSize.rows != 1 { fail("grid at 1x1 pt is \(c.gridSize)") }
    c.view.setFrameSize(NSSize(width: 600, height: 400))
    if c.gridSize.cols < 40 || c.gridSize.rows < 10 { fail("grid at 600x400 pt is \(c.gridSize)") }
    c.close()

    // 1b. Cost of a screen of shaped Arabic rows (Phase 4): first draw shapes every row, the second hits the cache.
    let flood = "i=0; while [ $i -lt 40 ]; do printf 'بيتي مرحبا السلام عليكم ورحمة الله وبركاته %d بيتي مرحبا السلام عليكم ورحمة الله\\n' $i; i=$((i+1)); done; sleep 4"
    guard let shaped = TerminalController(argv: ["/bin/sh", "-c", flood], frame: NSSize(width: 700, height: 420)) else { fail("cannot start shaped session") }
    if !pump(5, until: { shaped.rowText(shaped.gridSize.rows - 2).contains("بيتي") }) { fail("shaped rows: row is '\(shaped.rowText(shaped.gridSize.rows - 2))'") }
    guard let srep = shaped.view.bitmapImageRepForCachingDisplay(in: shaped.view.bounds) else { fail("no bitmap") }
    func timed() -> Double {
        let t0 = Date()
        shaped.view.cacheDisplay(in: shaped.view.bounds, to: srep)
        return Date().timeIntervalSince(t0) * 1000
    }
    let cold = timed()
    let warm = timed()
    print(String(format: "selftest: %dx%d screen of shaped Arabic rows: cold draw %.1f ms, cached draw %.1f ms", shaped.gridSize.cols, shaped.gridSize.rows, cold, warm))
    shaped.close()

    // 1c. Arabic samples (brief 4.7): the grid keeps the logical text and every sample row is drawn.
    let samples = ["مرحبا world 123", "السلام عليكم ورحمة الله", "مُحَمَّد", "لا إله إلا الله", "ls ملف.txt",
                   "\"النتيجة: ١٢٣ (ناجح)\"", "echo \"اختبار\" | wc -c", "│ مرحبا    │"]
    guard let arabic = TerminalController(argv: ["/bin/sh", "-c", "printf '%s\\n' \"$@\"; sleep 3", "sh"] + samples, frame: NSSize(width: 700, height: 420)) else { fail("cannot start samples session") }
    if !pump(5, until: { arabic.rowText(samples.count - 1) == samples[samples.count - 1] }) { fail("samples: row \(samples.count - 1) is '\(arabic.rowText(samples.count - 1))'") }
    for (i, want) in samples.enumerated() where arabic.rowText(i) != want { fail("samples: row \(i) is '\(arabic.rowText(i))', want '\(want)'") }
    guard let arep = arabic.view.bitmapImageRepForCachingDisplay(in: arabic.view.bounds) else { fail("no bitmap") }
    arabic.view.cacheDisplay(in: arabic.view.bounds, to: arep)
    func rowHasInk(_ rep: NSBitmapImageRep, _ c: TerminalController, _ row: Int) -> Bool {
        let scalePx = Double(rep.pixelsWide) / Double(c.view.bounds.width)
        let bg = terminalBackground.usingColorSpace(.sRGB)!
        let y0 = Double(c.insetPt) + Double(row) * Double(c.cellSizePt.height)
        for y in stride(from: Int((y0 + 2) * scalePx), to: Int((y0 + Double(c.cellSizePt.height) - 2) * scalePx), by: 2) {
            for x in stride(from: Int(Double(c.insetPt) * scalePx), to: rep.pixelsWide - Int(Double(c.insetPt) * scalePx), by: 2) {
                guard let col = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(col.redComponent - bg.redComponent) > 0.1 || abs(col.greenComponent - bg.greenComponent) > 0.1 { return true }
            }
        }
        return false
    }
    for i in 0..<samples.count where !rowHasInk(arep, arabic, i) { fail("samples: row \(i) has no ink") }
    // The pictures a human looks at (brief 4.7): HARF_SELFTEST_PNG_DIR=<dir> keeps them.
    let pictureDir = ProcessInfo.processInfo.environment["HARF_SELFTEST_PNG_DIR"]
    func savePNG(_ rep: NSBitmapImageRep, _ name: String) {
        guard let dir = pictureDir, let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
    }
    savePNG(arep, "samples.png")
    arabic.close()
    // Typing: the same text one letter at a time, frame by frame (row 0 only), at an LTR prompt and on a bare row.
    func typingStrip(prompt: String, text: String, name: String) {
        guard let t = TerminalController(argv: ["/bin/sh", "-c", "printf '\(prompt)'; cat"], frame: NSSize(width: 700, height: 420)) else { fail("cannot start typing strip") }
        if !prompt.isEmpty, !pump(5, until: { t.rowText(0).contains(prompt.trimmingCharacters(in: .whitespaces)) }) { fail("typing strip: no prompt") }
        _ = pump(0.3) { false }
        var frames: [NSBitmapImageRep] = []
        var typed = ""
        for ch in text {
            typed.append(ch)
            t.sendText(String(ch))
            let want = (prompt + typed).trimmingCharacters(in: .whitespaces)
            if !pump(5, until: { t.rowText(0).trimmingCharacters(in: .whitespaces) == want }) { fail("typing strip: row 0 is '\(t.rowText(0))', want '\(want)'") }
            guard let r = t.view.bitmapImageRepForCachingDisplay(in: t.view.bounds) else { fail("no bitmap") }
            t.view.cacheDisplay(in: t.view.bounds, to: r)
            frames.append(r)
        }
        if pictureDir != nil, let first = frames.first {
            let hPx = Int((t.insetPt + t.cellSizePt.height + 4) * CGFloat(first.pixelsWide) / t.view.bounds.width)
            guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: first.pixelsWide, pixelsHigh: hPx * frames.count, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let gctx = NSGraphicsContext(bitmapImageRep: out) else { fail("no strip bitmap") }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = gctx
            for (i, r) in frames.enumerated() {
                let img = NSImage(size: NSSize(width: r.pixelsWide, height: r.pixelsHigh))
                img.addRepresentation(r)
                img.draw(in: NSRect(x: 0, y: (frames.count - 1 - i) * hPx, width: r.pixelsWide, height: hPx),
                         from: NSRect(x: 0, y: r.pixelsHigh - hPx, width: r.pixelsWide, height: hPx), operation: .copy, fraction: 1)
            }
            NSGraphicsContext.restoreGraphicsState()
            savePNG(out, name)
        }
        t.close()
    }
    typingStrip(prompt: "❯ ", text: "السلام عليكم", name: "typing-prompt.png")
    typingStrip(prompt: "", text: "السلام عليكم", name: "typing-bare.png")

    // 1d. Slice 3 pictures (HARF_SELFTEST_PNG_DIR) and the cost of colored screens.
    func scriptController(_ text: String) -> TerminalController {
        let path = NSTemporaryDirectory() + "harf-selftest-\(getpid())-\(UUID().uuidString).sh"
        tempScripts.append(path)
        do { try (text + "\nsleep 8\n").write(toFile: path, atomically: true, encoding: .utf8) } catch { fail("cannot write a script") }
        guard let c = TerminalController(argv: ["/bin/sh", path], frame: NSSize(width: 700, height: 420)) else { fail("cannot start a script session") }
        return c
    }
    let colorScript = #"""
    for b in 0 1; do for c in 30 31 32 33 34 35 36 37 90 91 92 93 94 95 96 97; do printf '\033[%d;%dm %3d \033[0m' $b $c $c; done; printf '\n'; done
    i=16; while [ $i -lt 52 ]; do printf '\033[48;5;%dm  \033[0m' $i; i=$((i+1)); done; printf '\n'
    i=0; while [ $i -lt 40 ]; do printf '\033[48;2;%d;%d;128m  \033[0m' $((i*6)) $((255-i*6)); i=$((i+1)); done; printf '\n'
    printf '\033[1mbold\033[0m \033[3mitalic\033[0m \033[4munderline\033[0m \033[21mdouble\033[0m \033[4:3mcurly\033[0m \033[4:4mdotted\033[0m \033[4:5mdashed\033[0m \033[9mstrike\033[0m \033[2mfaint\033[0m \033[7minverse\033[0m \033[1;3;4mall\033[0m\n'
    printf '\033[38;2;255;160;0mtruecolor text\033[0m \033[48;2;40;40;90m\033[38;5;229m 256 on truecolor \033[0m\n'
    printf '\033[42m\033[2K erased line, green background\033[0m\n'
    """#
    let colors = scriptController(colorScript)
    if !pump(5, until: { (0..<colors.gridSize.rows).contains { colors.rowText($0).contains("inverse all") } }) { fail("colors: rows are '\(colors.rowText(0))'") }
    if let rep = colors.view.bitmapImageRepForCachingDisplay(in: colors.view.bounds) { colors.view.cacheDisplay(in: colors.view.bounds, to: rep); savePNG(rep, "colors.png") }
    colors.close()

    let arabicColorScript = #"""
    printf '\033[1;34mمجلد\033[0m  \033[0;32mسكريبت.sh\033[0m  \033[0;31mأرشيف.tar.gz\033[0m  \033[0;36mرابط -> هدف\033[0m  \033[1;33mملف.txt\033[0m\n'
    printf '\033[44m\033[1;37m  نتيجة: ١٢٣ (ناجح)  \033[0m  \033[41m خطأ \033[0m  \033[4;31mتحذير\033[0m  \033[9mمشطوب\033[0m\n'
    printf 'plain latin \033[32mgreen\033[0m and \033[1;35mbold magenta\033[0m\n'
    printf '\033[7m  مقلوب  \033[0m \033[2mباهت\033[0m\n'
    """#
    let acolors = scriptController(arabicColorScript)
    if !pump(5, until: { (0..<acolors.gridSize.rows).contains { acolors.rowText($0).contains("باهت") } }) { fail("arabic colors: rows are '\(acolors.rowText(0))'") }
    if let rep = acolors.view.bitmapImageRepForCachingDisplay(in: acolors.view.bounds) { acolors.view.cacheDisplay(in: acolors.view.bounds, to: rep); savePNG(rep, "arabic-colors.png") }
    acolors.close()

    // Selection over a Latin row and an Arabic row, with real mouse events.
    let selpic = scriptController(#"printf 'select this latin text\nمرحبا بالعالم ورحمة الله\n'"#)
    let selwin = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
    selwin.contentView = selpic.view
    if !pump(5, until: { selpic.rowText(1).contains("ورحمة") }) { fail("selection picture: rows are '\(selpic.rowText(0))'") }
    do {
        let cell = selpic.cellSizePt
        func at(_ col: Double, _ row: Double) -> NSPoint { NSPoint(x: selpic.insetPt + cell.width * (col + 0.5), y: 420 - (selpic.insetPt + cell.height * (row + 0.5))) }
        func ev(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: selwin.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1) else { fail("cannot make a mouse event") }
            return e
        }
        selpic.view.mouseDown(with: ev(.leftMouseDown, at(7, 0)))
        selpic.view.mouseDragged(with: ev(.leftMouseDragged, at(11, 0)))
        selpic.view.mouseUp(with: ev(.leftMouseUp, at(11, 0)))
        if let rep = selpic.view.bitmapImageRepForCachingDisplay(in: selpic.view.bounds) { selpic.view.cacheDisplay(in: selpic.view.bounds, to: rep); savePNG(rep, "selection-latin.png") }
        selpic.view.mouseDown(with: ev(.leftMouseDown, at(22, 1)))
        selpic.view.mouseDragged(with: ev(.leftMouseDragged, at(14, 1)))
        selpic.view.mouseUp(with: ev(.leftMouseUp, at(14, 1)))
        if let rep = selpic.view.bitmapImageRepForCachingDisplay(in: selpic.view.bounds) { selpic.view.cacheDisplay(in: selpic.view.bounds, to: rep); savePNG(rep, "selection-arabic.png") }
    }
    selpic.close()

    // Cost of a colored 80x24 screen: plain (per-cell path) and Arabic (shaped path). Cold draws every row, cached reuses layouts.
    func timedScreen(_ label: String, _ line: String) {
        let flood = "i=0; while [ $i -lt 40 ]; do printf '\\033[3%d;4%dm\(line)\\033[0m\\n' $((i % 7 + 1)) $(((i + 3) % 7 + 1)) $i; i=$((i+1)); done; sleep 4"
        guard let c = TerminalController(argv: ["/bin/sh", "-c", flood], frame: NSSize(width: 700, height: 420)) else { fail("cannot start \(label)") }
        if !pump(5, until: { c.rowText(c.gridSize.rows - 2).contains("x") || c.rowText(c.gridSize.rows - 2).contains("بيتي") }) { fail("\(label): rows not ready") }
        guard let r = c.view.bitmapImageRepForCachingDisplay(in: c.view.bounds) else { fail("no bitmap") }
        func t() -> Double { let t0 = Date(); c.view.cacheDisplay(in: c.view.bounds, to: r); return Date().timeIntervalSince(t0) * 1000 }
        let cold = t(), warm = t()
        print(String(format: "selftest: colored %@ 80x24 screen: cold draw %.1f ms, second draw %.1f ms", label, cold, warm))
        c.close()
    }
    timedScreen("plain", "colored latin text line %d xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx")
    timedScreen("arabic", "بيتي مرحبا السلام عليكم ورحمة الله وبركاته %d بيتي مرحبا السلام عليكم ورحمة الله")

    // 1e. A program's OSC 11 (default background) also changes the margins around the grid, not just the cells.
    do {
        guard let b = TerminalController(argv: ["/bin/sh", "-c", #"printf '\033]11;rgb:ff/ff/ff\007'; echo done; sleep 4"#], frame: NSSize(width: 700, height: 420)) else { fail("cannot start background session") }
        if !pump(5, until: { (0..<3).contains { b.rowText($0).contains("done") } }) { fail("background: child not done") }
        guard let r = b.view.bitmapImageRepForCachingDisplay(in: b.view.bounds) else { fail("no bitmap") }
        b.view.cacheDisplay(in: b.view.bounds, to: r)
        let px = Double(r.pixelsWide) / Double(b.view.bounds.width)
        // 2 points from the left and top edges: inside the 6-point inset, outside every cell
        guard let margin = r.colorAt(x: Int(2 * px), y: Int(2 * px))?.usingColorSpace(.sRGB) else { fail("no margin pixel") }
        if margin.redComponent < 0.95 || margin.greenComponent < 0.95 || margin.blueComponent < 0.95 {
            fail("background: after OSC 11 white the margin is (\(margin.redComponent), \(margin.greenComponent), \(margin.blueComponent))")
        }
        b.close()
    }

    // 1f. HARF_MEASURE=1: a 100 MB flood must not leave memory growing (phys_footprint, the budget's own measure).
    if ProcessInfo.processInfo.environment["HARF_MEASURE"] == "1" {
        func physFootprintMB() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
            }
            return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
        }
        guard let warm = TerminalController(argv: ["/bin/sh", "-c", "sleep 30"], frame: NSSize(width: 700, height: 420)) else { fail("cannot start the baseline session") }
        _ = pump(1.5) { false }
        let before = physFootprintMB()
        guard let flood = TerminalController(argv: ["/bin/sh", "-c", "yes 'flood flood flood flood flood flood flood flood flood flood flood flood flood' | head -c 100000000"], frame: NSSize(width: 700, height: 420)) else { fail("cannot start the flood session") }
        if !pump(120, until: { flood.exitStatus != nil }) { fail("flood did not finish in 120 s") }
        _ = pump(2) { false }
        let during = physFootprintMB()
        flood.close()
        _ = pump(2) { false }
        let after = physFootprintMB()
        warm.close()
        print(String(format: "selftest: footprint before flood %.1f MB, with the flooded session open %.1f MB, after it is closed %.1f MB", before, during, after))
        if during - before > 2 { fail(String(format: "footprint after a flood is %.1f MB above before (limit 2 MB)", during - before)) }
        if after - before > 2 { fail(String(format: "footprint after closing the flood session is %.1f MB above before (limit 2 MB)", after - before)) }
    }

    // 1g. Pictures of real programs running in the view (HARF_SELFTEST_PNG_DIR); each is skipped if the program is missing.
    if pictureDir != nil {
        func installed(_ tool: String) -> Bool {
            ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"].contains { FileManager.default.isExecutableFile(atPath: $0 + tool) }
        }
        func programPicture(_ tool: String, _ png: String, script: String, ready: String, keys: [String]) {
            guard installed(tool) else { print("selftest: \(tool) is not installed, no picture"); return }
            let c = scriptController(script)
            if !pump(10, until: { (0..<c.gridSize.rows).contains { c.rowText($0).contains(ready) } }) { fail("\(tool): '\(ready)' never appeared") }
            for k in keys { c.sendText(k); _ = pump(0.5) { false } }
            _ = pump(0.8) { false }
            if let rep = c.view.bitmapImageRepForCachingDisplay(in: c.view.bounds) { c.view.cacheDisplay(in: c.view.bounds, to: rep); savePNG(rep, png) }
            c.close()
        }
        let sample = #"printf '#!/bin/sh\n# a small script\nname="harf"\nif [ -n "$name" ]; then\n  echo "hello $name" | tr a-z A-Z\nfi\nfor i in 1 2 3; do\n  echo "$i"\ndone\n' > "$F""#
        tempScripts.append("\(NSTemporaryDirectory())harf-selftest-vim-\(getpid()).sh")   // the picture closes vim before its own rm runs
        programPicture("vim", "vim.png", script: "F=\(NSTemporaryDirectory())harf-selftest-vim-\(getpid()).sh; \(sample); vim -u NONE -N -n \"$F\"; rm -f \"$F\"",
                       ready: "a small script", keys: [":syntax on\r", ":set ft=sh\r", ":set number\r"])
        let tmuxName = "harfpic\(getpid())"
        programPicture("tmux", "tmux.png", script: "tmux -L \(tmuxName) -f /dev/null new-session", ready: "[0]", keys: ["\u{2}%", "echo left pane\r", "\u{2}o", "echo right pane\r"])
        for dir in ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/"] where FileManager.default.isExecutableFile(atPath: dir + "tmux") {
            let kill = Process(); kill.executableURL = URL(fileURLWithPath: dir + "tmux"); kill.arguments = ["-L", tmuxName, "kill-server"]
            try? kill.run(); kill.waitUntilExit(); break
        }
        programPicture("htop", "htop.png", script: "htop", ready: "Tasks", keys: [])
        programPicture("fzf", "fzf.png", script: "printf 'alpha\\nbeta\\ngamma\\ndelta\\nepsilon\\nzeta\\n' | fzf --height=100%", ready: "gamma", keys: ["a"])
    }

    // 1h. HARF_MEASURE=1: keypress-to-draw latency at an idle prompt. In process: from just before the key is handed to the view
    // until the frame that shows the echo has finished. It leaves out waiting for the display's next refresh and the compositor.
    if ProcessInfo.processInfo.environment["HARF_MEASURE"] == "1" {
        guard let c = TerminalController(argv: ["/bin/sh", "-c", "exec cat"], frame: NSSize(width: 700, height: 420)) else { fail("cannot start the latency session") }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = c.view
        guard let rep = c.view.bitmapImageRepForCachingDisplay(in: c.view.bounds) else { fail("no bitmap") }
        _ = pump(1.0) { false }
        c.view.cacheDisplay(in: c.view.bounds, to: rep)   // warm the draw path once
        func typed() -> Int { (0..<c.gridSize.rows).reduce(0) { $0 + c.rowText($1).filter { $0.isLetter }.count } }
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        var samples: [Double] = []
        for i in 0..<200 {
            let ch = String(letters[i % 26])
            let before = typed()
            let marks = measureDirtyMarks
            measureDirtyRect = .null
            let t0 = ProcessInfo.processInfo.systemUptime
            c.view.handleKey(code: 0, mods: 0, characters: ch, isRepeat: false) { c.sendText(ch) }
            // The product path: key -> core -> PTY echo -> parse -> wake -> hop to the main thread -> wakeOnMain marks the
            // view dirty (`markDirty`). We wait for that mark; we do not read the grid to decide the echo has arrived.
            let deadline = t0 + 2
            while measureDirtyMarks == marks && ProcessInfo.processInfo.systemUptime < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.0002)) }
            if measureDirtyMarks == marks { fail("keystroke \(i): the product's wake path never marked the view dirty within 2 s") }
            // An off-screen window gets no display-link tick, so this stands in for it: draw once, now, what the wake
            // invalidated (the changed row and the one above it, not the whole view).
            let dirty = measureDirtyRect.intersection(c.view.bounds)
            if dirty.isNull || dirty.height > 3 * c.cellSizePt.height { fail("keystroke \(i): the wake invalidated \(measureDirtyRect) of a \(c.view.bounds.size) view; one echoed letter should touch at most two rows") }
            guard let part = c.view.bitmapImageRepForCachingDisplay(in: dirty) else { fail("no bitmap") }
            c.view.cacheDisplay(in: dirty, to: part)
            if typed() != before + 1 { fail("keystroke \(i): the frame drawn after the wake does not show the echo") }
            samples.append((measureFrameEnd - t0) * 1000)
            _ = pump(0.01) { false }
        }
        c.close()
        samples.sort()
        let median = samples[samples.count / 2], p95 = samples[Int(Double(samples.count) * 0.95)], worst = samples[samples.count - 1]
        print(String(format: "selftest: keypress-to-draw at an idle prompt over %d keystrokes: median %.2f ms, p95 %.2f ms, max %.2f ms", samples.count, median, p95, worst))
        if median >= 10 { fail(String(format: "median keypress-to-draw latency is %.2f ms (budget 10 ms)", median)) }
    }

    // 1i. The app's window is an sRGB window: with the default color space AppKit keeps a second backing surface (about 5 MB)
    // once the view has been redrawn. Nothing else in the self-test would notice that setting disappearing.
    do {
        guard let wc = WindowController(argv: ["/bin/sh", "-c", "sleep 2"], content: NSSize(width: 700, height: 420), cwd: nil) else { fail("cannot start the window session") }
        let w = wc.window
        if w.colorSpace != NSColorSpace.sRGB { fail("the terminal window's color space is \(String(describing: w.colorSpace?.localizedName)), not sRGB (costs about 5 MB of footprint)") }
        w.close()
    }

    // 1j. A program that switches the terminal to 132 columns (DECCOLM) gets a window that fits them, and the window follows
    // it back to 80. Before this the grid changed and the window did not, so the right-hand columns were clipped.
    do {
        // The first second is for the window to finish its own refit, which would otherwise reset the grid under the program.
        let script = "sleep 1; printf '\\033[?40h\\033[?3h'; printf wide; sleep 3; printf '\\033[?3l'; printf narrow; sleep 3"
        guard let wc = WindowController(argv: ["/bin/sh", "-c", script], content: NSSize(width: 700, height: 420), cwd: nil) else { fail("cannot start the DECCOLM session") }
        let c = wc.allPanes[0].controller
        func fits(_ cols: Int) -> Bool {
            let want = CGFloat(cols) * c.cellSizePt.width + 2 * c.insetPt
            return abs(c.view.bounds.width - want) < 1 && c.gridSize.cols == cols && c.coreGrid().cols == cols
        }
        if !pump(5, until: { c.coreGrid().cols == 132 }) { fail("DECCOLM: the core never went to 132 columns (grid \(c.coreGrid()), row0 '\(c.rowText(0))')") }
        if !pump(3, until: { fits(132) }) { fail("DECCOLM: the program switched to 132 columns but the window is \(c.view.bounds.width) pt wide, grid \(c.gridSize), core \(c.coreGrid())") }
        _ = pump(0.3) { false }
        if !fits(132) { fail("DECCOLM: the 132-column fit did not hold (view \(c.view.bounds.width) pt, grid \(c.gridSize), core \(c.coreGrid()))") }
        if !pump(5, until: { fits(80) && c.rowText(0).contains("narrow") }) { fail("DECCOLM: back to 80 columns, the window is \(c.view.bounds.width) pt wide, grid \(c.gridSize), core \(c.coreGrid())") }
        wc.window.close()
    }

    // 1j2. In a split the window does not follow one pane's grid: the pane keeps its share (before this the window was resized to the
    // 132 columns of one pane and squeezed the other).
    do {
        setenv("SHELL", "/bin/sh", 1)   // a split starts the login shell: keep the user's own startup files out of the test
        let script = "sleep 1; printf '\\033[?40h\\033[?3h'; printf wide; sleep 3"
        guard let wc = WindowController(argv: ["/bin/sh", "-c", script], content: NSSize(width: 700, height: 420), cwd: nil) else { fail("cannot start the DECCOLM split session") }
        wc.split(wc.allPanes[0], vertical: true)
        let c = wc.allPanes[0].controller
        let before = wc.window.contentView?.bounds.size
        if !pump(5, until: { c.coreGrid().cols == 132 }) { fail("DECCOLM in a split: the core never went to 132 columns (grid \(c.coreGrid()))") }
        _ = pump(1.0) { false }   // time for a window resize, if one were wrongly made
        if wc.window.contentView?.bounds.size != before { fail("DECCOLM in a split: the window changed from \(String(describing: before)) to \(String(describing: wc.window.contentView?.bounds.size))") }
        wc.window.close()
    }

    // 1k. Dirty rows, through the view: a bitmap that is updated only with the rectangles the wake path invalidates, each drawn by the
    // view's own `draw`, must equal a full redraw after every step (typing Latin and Arabic, Return, so the screen scrolls).
    do {
        trackDirty = true
        defer { trackDirty = false }
        guard let c = TerminalController(argv: ["/bin/sh", "-c", "exec cat"], frame: NSSize(width: 700, height: 420)) else { fail("cannot start the dirty-rows session") }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = c.view
        _ = pump(1.0) { false }
        guard let kept = c.view.bitmapImageRepForCachingDisplay(in: c.view.bounds), let full = c.view.bitmapImageRepForCachingDisplay(in: c.view.bounds) else { fail("no bitmap") }
        c.view.cacheDisplay(in: c.view.bounds, to: kept)
        let px = Double(kept.pixelsWide) / Double(c.view.bounds.width)
        let alphabet = ["a", "b", "g", "م", "ر", "ح", "ب", "ا", " ", " ", "\r", "é", "日", "ل"]
        var seed: UInt32 = 12345
        var partial = 0
        for i in 0..<120 {
            seed = seed &* 1664525 &+ 1013904223
            let ch = alphabet[Int(seed >> 16) % alphabet.count]
            let marks = measureDirtyMarks
            measureDirtyRect = .null
            c.sendText(ch)
            let deadline = Date().addingTimeInterval(2)
            while measureDirtyMarks == marks && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
            _ = pump(0.03) { false }   // let any second wake (cat's own output) arrive
            let dirty = measureDirtyRect.intersection(c.view.bounds)
            if !dirty.isNull {
                if dirty.height < c.view.bounds.height { partial += 1 }
                guard let part = c.view.bitmapImageRepForCachingDisplay(in: dirty) else { fail("no bitmap") }
                c.view.cacheDisplay(in: dirty, to: part)
                guard let src = part.bitmapData, let dst = kept.bitmapData else { fail("no bitmap data") }
                let x0 = Int((dirty.minX * px).rounded()), y0 = Int((dirty.minY * px).rounded())
                let bytes = min(part.bytesPerRow, kept.bytesPerRow - x0 * 4)
                for y in 0..<part.pixelsHigh where y0 + y < kept.pixelsHigh { memcpy(dst + (y0 + y) * kept.bytesPerRow + x0 * 4, src + y * part.bytesPerRow, bytes) }
            }
            c.view.cacheDisplay(in: c.view.bounds, to: full)
            guard let a = kept.bitmapData, let b = full.bitmapData else { fail("no bitmap data") }
            for y in 0..<kept.pixelsHigh where memcmp(a + y * kept.bytesPerRow, b + y * full.bytesPerRow, kept.pixelsWide * 4) != 0 {
                fail("dirty rows: after step \(i) ('\(ch)') the partially redrawn view differs from a full redraw at pixel row \(y) (row \(Int(Double(y) / px / c.cellSizePt.height)), invalidated \(dirty))")
            }
        }
        if partial < 60 { fail("dirty rows: only \(partial) of 120 steps invalidated less than the whole view") }
        print("selftest: dirty rows: 120 typed steps, \(partial) redrawn as rows, every one identical to a full redraw")
        c.close()
        _ = win
    }

    // 1l. The wake path scans the grid for changed rows at most once per `scanInterval`. A flood used to wake it after every read, and each
    // scan held the session lock, so the parser spent most of a flood waiting for the main thread (docs/perf.md, "Flood throughput").
    do {
        trackDirty = true
        defer { trackDirty = false }
        // (a) Two wakes in one interval: the first scans at once (nothing is delayed at a quiet prompt), the second waits and scans once
        // the interval is over, and then nothing runs: no timer ticks on.
        guard let q = TerminalController(argv: ["/bin/sh", "-c", "sleep 30"], frame: NSSize(width: 700, height: 420)) else { fail("cannot start the scan session") }
        _ = pump(0.3) { false }
        let base = measureScans
        q.wakeOnMain()
        if measureScans != base + 1 { fail("scan throttle: the first wake after a quiet moment made \(measureScans - base) scans, not 1") }
        q.wakeOnMain()
        if measureScans != base + 1 { fail("scan throttle: a second wake inside the interval scanned at once (\(measureScans - base) scans); it should wait") }
        if !pump(0.5, until: { measureScans == base + 2 }) { fail("scan throttle: the deferred scan never ran (\(measureScans - base) scans)") }
        _ = pump(0.3) { false }
        if measureScans != base + 2 { fail("scan throttle: \(measureScans - base - 2) scans happened with no wake to cause them") }
        q.close()
        // (b) A flood: the wakes arrive after every read, and the scans stay within one per interval.
        let n = 300_000
        guard let f = TerminalController(argv: ["/bin/sh", "-c", "sleep 0.3; seq 1 \(n); sleep 30"], frame: NSSize(width: 700, height: 420)) else { fail("cannot start the flood session") }
        let t0 = ProcessInfo.processInfo.systemUptime
        let s0 = measureScans
        if !pump(120, until: { (0..<f.gridSize.rows).contains { f.rowText($0).contains(String(n)) } }) { fail("scan throttle: the last line of the flood never appeared") }
        let elapsed = ProcessInfo.processInfo.systemUptime - t0
        let scans = measureScans - s0
        let allowed = Int(elapsed / scanInterval) + 5
        if scans > allowed { fail(String(format: "scan throttle: %d scans in %.2f s of flood; at most %d (one per %.1f ms)", scans, elapsed, allowed, scanInterval * 1000)) }
        _ = pump(0.3) { false }
        let settled = measureScans
        _ = pump(0.3) { false }
        if measureScans != settled { fail("scan throttle: \(measureScans - settled) scans happened after the output had stopped") }
        print(String(format: "selftest: scan throttle: a %d-line flood took %.2f s and made %d scans (at most %d); idle afterwards", n, elapsed, scans, allowed))
        f.close()
    }

    // 2. Typing (a letter, an Arabic letter, Return) goes through the view's own key path.
    let echo = ["/bin/sh", "-c", "read x; echo got:$x"]
    func rows(_ c: TerminalController) -> String { (0..<6).map { c.rowText($0) }.joined(separator: "|") }
    guard let typing = TerminalController(argv: echo, frame: NSSize(width: 700, height: 420)) else { fail("cannot start typing session") }
    func key(_ code: UInt16, _ chars: String) {
        typing.view.handleKey(code: code, mods: 0, characters: chars, isRepeat: false) { typing.sendText(chars) }
    }
    key(0, "a")
    key(46, "م")
    key(36, "\r")
    if !pump(5, until: { rows(typing).contains("got:aم") }) { fail("typing: rows are '\(rows(typing))'") }
    typing.close()

    // 2b. A real arrow-key NSEvent reaches the child as an escape sequence, kitty protocol on or off.
    for kitty in ["", "\\033[>1u"] {
        let script = "stty raw -echo; printf '\(kitty)'; printf R; head -c 3 | od -An -c"
        guard let arrows = TerminalController(argv: ["/bin/sh", "-c", script], frame: NSSize(width: 700, height: 420)) else { fail("cannot start arrow session") }
        if !pump(5, until: { rows(arrows).contains("R") }) { fail("arrow child not ready: '\(rows(arrows))'") }
        guard let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0,
                                        windowNumber: 0, context: nil, characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}",
                                        isARepeat: false, keyCode: 126) else { fail("cannot make key event") }
        arrows.view.keyDown(with: ev)
        if !pump(5, until: { rows(arrows).contains("033") }) { fail("arrow (kitty '\(kitty)'): rows are '\(rows(arrows))'") }
        if !rows(arrows).contains("[   A") { fail("arrow (kitty '\(kitty)'): wrong bytes '\(rows(arrows))'") }
        arrows.close()
    }

    // 2c. Option and Command editing keys, and Ctrl+C under the keyboard flags Claude Code sets (5), as real key events.
    func keyEvent(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        guard let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                        characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { fail("cannot make key event") }
        return ev
    }
    func expectBytes(_ name: String, prelude: String, count: Int, events: [NSEvent], contains: String) {
        let script = "stty raw -echo; printf '\(prelude)'; printf R; head -c \(count) | od -An -tx1 | tr -s ' '"
        guard let t = TerminalController(argv: ["/bin/sh", "-c", script], frame: NSSize(width: 700, height: 420)) else { fail("cannot start \(name)") }
        if !pump(5, until: { t.rowText(0).contains("R") }) { fail("\(name): child not ready: '\(t.rowText(0))'") }
        for ev in events { t.view.keyDown(with: ev) }
        if !pump(5, until: { (0..<4).contains { t.rowText($0).contains(contains) } }) { fail("\(name): rows are '\((0..<4).map { t.rowText($0) }.joined(separator: "|"))', want '\(contains)'") }
        t.close()
    }
    expectBytes("option+left, cmd+left", prelude: "", count: 3,
                events: [keyEvent(123, "\u{F702}", [.option, .numericPad, .function]), keyEvent(123, "\u{F702}", [.command, .numericPad, .function])],
                contains: "1b 62 01")
    expectBytes("ctrl+c with kitty flags 5", prelude: "\\033[>5u", count: 7, events: [keyEvent(8, "\u{03}", [.control])], contains: "1b 5b 39 39 3b 35 75")

    // 2d. The wheel scrolls through the scrollback (a real scroll event), and typing brings the view back.
    guard let hist = TerminalController(argv: ["/bin/sh", "-c", "seq 1 80; exec cat"], frame: NSSize(width: 700, height: 420)) else { fail("cannot start scrollback session") }
    let lastRow = hist.gridSize.rows - 2
    if !pump(5, until: { hist.rowText(lastRow).trimmingCharacters(in: .whitespaces) == "80" }) { fail("scrollback: rows are '\(hist.rowText(lastRow))'") }
    let topBefore = Int(hist.rowText(0).trimmingCharacters(in: .whitespaces)) ?? -1
    guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0), let wheel = NSEvent(cgEvent: cg) else { fail("cannot make a scroll event") }
    hist.view.scrollWheel(with: wheel)
    if !pump(5, until: { (Int(hist.rowText(0).trimmingCharacters(in: .whitespaces)) ?? 999) < topBefore }) { fail("scrollback: wheel did not scroll, row 0 is '\(hist.rowText(0))'") }
    hist.sendText("hi\n")
    if !pump(5, until: { (0..<hist.gridSize.rows).contains { hist.rowText($0).contains("hi") } }) { fail("scrollback: typing did not bring the view back") }
    hist.close()

    // 2e. A real mouse click reaches a program that asked for mouse reports, at the cell under the pointer.
    do {
        let script = "stty raw -echo; printf '\\033[?1000h\\033[?1006h'; printf R; head -c 18 | od -An -tx1 | tr -s ' '"
        guard let m = TerminalController(argv: ["/bin/sh", "-c", script], frame: NSSize(width: 700, height: 420)) else { fail("cannot start mouse session") }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = m.view
        if !pump(5, until: { m.rowText(0).contains("R") }) { fail("mouse: child not ready: '\(m.rowText(0))'") }
        _ = pump(0.3) { false }   // the child switched tracking on before it printed R; let the parser see it
        let cell = m.cellSizePt
        let pt = NSPoint(x: m.insetPt + cell.width * 4.5, y: 420 - (m.insetPt + cell.height * 2.5))   // window coordinates: y up
        func click(_ type: NSEvent.EventType) -> NSEvent {
            guard let ev = NSEvent.mouseEvent(with: type, location: pt, modifierFlags: [], timestamp: 0, windowNumber: win.windowNumber, context: nil,
                                              eventNumber: 0, clickCount: 1, pressure: 1) else { fail("cannot make a mouse event") }
            return ev
        }
        m.view.mouseDown(with: click(.leftMouseDown))
        m.view.mouseUp(with: click(.leftMouseUp))
        func joined() -> String { (0..<4).map { m.rowText($0) }.joined().filter { $0 != " " } }   // the hex dump wraps
        if !pump(5, until: { joined().contains("1b5b3c303b353b334d1b5b3c303b353b336d") }) {
            fail("mouse: rows are '\((0..<4).map { m.rowText($0) }.joined(separator: "|"))'")
        }
        m.close()
    }

    // 2g. A key release reaches a program that asked for event types (kitty flags 1 + 2), for a key whose press reached it.
    do {
        let script = "stty raw -echo; printf '\\033[>3u'; printf R; head -c 16 | od -An -tx1 | tr -s ' '"
        guard let t = TerminalController(argv: ["/bin/sh", "-c", script], frame: NSSize(width: 700, height: 420)) else { fail("cannot start the release session") }
        if !pump(5, until: { t.rowText(0).contains("R") }) { fail("release: child not ready: '\(t.rowText(0))'") }
        _ = pump(0.3) { false }
        func up(_ type: NSEvent.EventType) -> NSEvent {
            guard let ev = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0, windowNumber: 0, context: nil,
                                            characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: 126) else { fail("cannot make a key event") }
            return ev
        }
        t.view.keyUp(with: up(.keyUp))   // a release with no press behind it is not reported
        t.view.keyDown(with: up(.keyDown))
        t.view.keyUp(with: up(.keyUp))
        if !pump(5, until: { (0..<4).contains { t.rowText($0).contains("1b 5b 31 3b 31 3a 31 41 1b 5b 31 3b 31 3a 33 41") } }) {
            fail("release: rows are '\((0..<4).map { t.rowText($0) }.joined(separator: "|"))'")
        }
        t.close()
    }

    // 2h. A program's OSC 52 write reaches the clipboard, OSC 9 raises a notification, and a Command-click opens an OSC 8 link:
    // http(s) and mailto only. A file: link, and a cell with no link, give nothing to open.
    do {
        let script = "printf '\\033]52;c;aGVsbG8=\\007'; printf '\\033]9;Build done\\007'; "
            + "printf '\\033]8;;https://example.com/x\\033\\\\link\\033]8;;\\033\\\\ '; "
            + "printf '\\033]8;;file:///etc/passwd\\033\\\\evil\\033]8;;\\033\\\\'; sleep 5"
        guard let c = TerminalController(argv: ["/bin/sh", "-c", script], frame: NSSize(width: 700, height: 420)) else { fail("cannot start the OSC session") }
        let pb = NSPasteboard(name: NSPasteboard.Name("app.harf.selftest"))
        pb.clearContents()
        c.clipboard = pb
        c.clipboardWriteAllowed = { false }   // not focused: the program's write must be ignored
        var notes: [(String, String)] = []
        c.onNotify = { notes.append(($0, $1)) }
        if !pump(5, until: { c.rowText(0).contains("evil") }) { fail("OSC: row 0 is '\(c.rowText(0))'") }
        if pb.string(forType: .string) != nil { fail("OSC 52: a write while the terminal is not focused changed the clipboard") }
        guard let c2 = TerminalController(argv: ["/bin/sh", "-c", "printf '\\033]52;c;aGVsbG8=\\007'; sleep 2"], frame: NSSize(width: 700, height: 420)) else { fail("cannot start the second OSC 52 session") }
        c2.clipboard = pb
        c2.clipboardWriteAllowed = { true }   // focused
        if !pump(5, until: { pb.string(forType: .string) == "hello" }) { fail("OSC 52: the clipboard holds \(String(describing: pb.string(forType: .string)))") }
        c2.close()
        if notes.count != 1 || notes[0].1 != "Build done" { fail("OSC 9: notifications are \(notes)") }
        let cell = c.cellSizePt
        func at(_ col: Double) -> NSPoint { NSPoint(x: c.insetPt + cell.width * col, y: c.insetPt + cell.height * 0.5) }   // the view is y-down
        if c.hyperlink(at: at(1.5))?.absoluteString != "https://example.com/x" { fail("OSC 8: link at column 1 is \(String(describing: c.hyperlink(at: at(1.5))))") }
        if c.hyperlink(at: at(6.5)) != nil { fail("OSC 8: a file: link would be opened") }
        if c.hyperlink(at: at(30.5)) != nil { fail("OSC 8: a link where there is none") }
        pb.clearContents()
        c.close()
    }

    // 2f. Window focus reaches a program that asked for focus events (mode 1004).
    do {
        // The first half second is for the view to join its window: a session starts "focused", and attaching an unfocused window
        // tells a program that has already asked for focus events "out", ahead of the "in" and "out" this test looks for.
        let script = "sleep 0.5; stty raw -echo; printf '\\033[?1004h'; printf R; head -c 6 | od -An -tx1 | tr -s ' '"
        guard let f = TerminalController(argv: ["/bin/sh", "-c", script], frame: NSSize(width: 700, height: 420)) else { fail("cannot start focus session") }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = f.view
        if !pump(5, until: { f.rowText(0).contains("R") }) { fail("focus: child not ready: '\(f.rowText(0))'") }
        _ = pump(0.3) { false }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: win)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: win)
        if !pump(5, until: { (0..<3).contains { f.rowText($0).contains("1b 5b 49 1b 5b 4f") } }) {
            fail("focus: rows are '\((0..<3).map { f.rowText($0) }.joined(separator: "|"))'")
        }
        f.close()
    }

    // 2g. Drag-select with real mouse events and copy: logical text reaches the pasteboard, nothing selected copies nothing.
    do {
        guard let sel = TerminalController(argv: ["/bin/sh", "-c", "printf 'hello world\\nمرحبا بالعالم\\n'; sleep 5"], frame: NSSize(width: 700, height: 420)) else { fail("cannot start selection session") }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = sel.view
        if !pump(5, until: { sel.rowText(1).contains("بالعالم") }) { fail("selection: rows are '\(sel.rowText(0))|\(sel.rowText(1))'") }
        let cell = sel.cellSizePt
        func at(_ col: Double, _ row: Double) -> NSPoint { NSPoint(x: sel.insetPt + cell.width * (col + 0.5), y: 420 - (sel.insetPt + cell.height * (row + 0.5))) }
        func ev(_ type: NSEvent.EventType, _ p: NSPoint, clicks: Int = 1, mods: NSEvent.ModifierFlags = []) -> NSEvent {
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: mods, timestamp: 0, windowNumber: win.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: clicks, pressure: 1) else { fail("cannot make a mouse event") }
            return e
        }
        let pb = NSPasteboard(name: NSPasteboard.Name("harf.selftest.\(getpid())"))
        sel.copySelection(to: pb)
        if pb.string(forType: .string) != nil { fail("selection: copy with nothing selected wrote to the pasteboard") }
        sel.view.mouseDown(with: ev(.leftMouseDown, at(0, 0)))
        sel.view.mouseDragged(with: ev(.leftMouseDragged, at(4, 0)))
        sel.view.mouseUp(with: ev(.leftMouseUp, at(4, 0)))
        sel.copySelection(to: pb)
        if pb.string(forType: .string) != "hello" { fail("selection: copied '\(pb.string(forType: .string) ?? "nil")', want 'hello'") }
        // Shift+click after releasing continues the selection forward (and again further).
        sel.view.mouseDown(with: ev(.leftMouseDown, at(8, 0), mods: .shift))
        sel.view.mouseUp(with: ev(.leftMouseUp, at(8, 0), mods: .shift))
        sel.copySelection(to: pb)
        if pb.string(forType: .string) != "hello wor" { fail("shift-selection forward: copied '\(pb.string(forType: .string) ?? "nil")', want 'hello wor'") }
        sel.view.mouseDown(with: ev(.leftMouseDown, at(10, 0), mods: .shift))
        sel.view.mouseUp(with: ev(.leftMouseUp, at(10, 0), mods: .shift))
        sel.copySelection(to: pb)
        if pb.string(forType: .string) != "hello world" { fail("shift-selection repeat: copied '\(pb.string(forType: .string) ?? "nil")', want 'hello world'") }
        // Select "world", release, then Shift+click backward to "hello" keeps "world" in the selection.
        sel.view.mouseDown(with: ev(.leftMouseDown, at(6, 0)))
        sel.view.mouseDragged(with: ev(.leftMouseDragged, at(10, 0)))
        sel.view.mouseUp(with: ev(.leftMouseUp, at(10, 0)))
        sel.view.mouseDown(with: ev(.leftMouseDown, at(0, 0), mods: .shift))
        sel.view.mouseUp(with: ev(.leftMouseUp, at(0, 0), mods: .shift))
        sel.copySelection(to: pb)
        if pb.string(forType: .string) != "hello world" { fail("shift-selection backward: copied '\(pb.string(forType: .string) ?? "nil")', want 'hello world'") }
        // The Arabic row reads right to left, so its logical start is at the right: drag in reading order, right to
        // left across the 13 cells it occupies. The copy is the logical text. (A left-to-right drag selects the
        // logical range between its endpoints, which is the minimal copy of slice 3; visual selection is Phase 7.)
        sel.view.mouseDown(with: ev(.leftMouseDown, at(12, 1)))
        sel.view.mouseDragged(with: ev(.leftMouseDragged, at(0, 1)))
        sel.view.mouseUp(with: ev(.leftMouseUp, at(0, 1)))
        sel.copySelection(to: pb)
        if pb.string(forType: .string) != "مرحبا بالعالم" { fail("selection: copied '\(pb.string(forType: .string) ?? "nil")', want the Arabic row") }
        pb.releaseGlobally()
        sel.close()
    }

    // 3. Paste, bracketed or not, arrives as typed text.
    guard let pasting = TerminalController(argv: echo, frame: NSSize(width: 700, height: 420)) else { fail("cannot start paste session") }
    pasting.paste("x y")
    pasting.view.handleKey(code: 36, mods: 0, characters: "\r", isRepeat: false) {}
    if !pump(5, until: { rows(pasting).contains("got:x y") }) { fail("paste: rows are '\(rows(pasting))'") }
    // 3a. A file drop types the shell-quoted paths: plain stays plain, a space or apostrophe is single-quoted, none gives nil.
    do {
        let pb = NSPasteboard(name: NSPasteboard.Name("harf.selftest.drop.\(getpid())"))
        pb.clearContents()
        pb.writeObjects([URL(fileURLWithPath: "/tmp/a") as NSURL, URL(fileURLWithPath: "/tmp/it's here") as NSURL, URL(fileURLWithPath: "/tmp/x\\'y") as NSURL])
        // a backslash goes outside the quotes ('\\'), where sh, bash, zsh and fish all read it as one literal backslash; inside single
        // quotes fish would read \\ and \' as escapes, and a file name could end its quoting
        let want = "/tmp/a '/tmp/it'\\''s here' '/tmp/x'\\\\''\\''y' "
        if pasting.dropText(from: pb) != want { fail("drop: got '\(pasting.dropText(from: pb) ?? "nil")', want '\(want)'") }
        pb.clearContents()
        pb.setString("not a file", forType: .string)
        if pasting.dropText(from: pb) != nil { fail("drop: a pasteboard with no file URL gave text") }
        pb.releaseGlobally()
        guard let c = TerminalController(argv: ["/bin/sh", "-c", "read -r x; echo \"got:$x\""], frame: NSSize(width: 700, height: 420)) else { fail("cannot start the drop session") }
        c.paste("'/tmp/it'\\''s here'")
        c.view.handleKey(code: 36, mods: 0, characters: "\r", isRepeat: false) {}
        if !pump(5, until: { rows(c).contains("got:'/tmp/it'\\''s here'") }) { fail("drop: rows are '\(rows(c))'") }
        c.close()
    }
    pasting.close()

    // 3b. The paste guard: a one-line paste never asks; text that would run lines in a program without bracketed paste asks first and
    // only a yes sends it; a program with bracketed paste is not asked about; the guard can be switched off; the sheet shows no
    // control characters.
    do {
        guard let c = TerminalController(argv: ["/bin/sh", "-c", "cat"], frame: NSSize(width: 700, height: 420)) else { fail("cannot start the paste-guard session") }
        var asked: [PasteSummary] = []
        var answer = false
        c.confirmPaste = { summary, done in asked.append(summary); done(answer) }
        c.paste("ONELINE")
        if !asked.isEmpty { fail("paste guard: a one-line paste must not ask") }
        if !pump(5, until: { rows(c).contains("ONELINE") }) { fail("paste guard: the one-line paste never arrived (rows \(rows(c)))") }
        c.paste("PQR\nSTU")
        if asked.count != 1 { fail("paste guard: a multi-line paste without bracketed paste must ask once, asked \(asked.count) times") }
        _ = pump(0.5) { false }
        if rows(c).contains("PQR") { fail("paste guard: a cancelled paste reached the program") }
        answer = true
        c.paste("PQR\nSTU")
        if !pump(5, until: { rows(c).contains("PQR") && rows(c).contains("STU") }) { fail("paste guard: a confirmed paste never arrived (rows \(rows(c)))") }
        c.close()

        guard let b = TerminalController(argv: ["/bin/sh", "-c", "printf '\\033[?2004hREADY'; cat"], frame: NSSize(width: 700, height: 420)) else { fail("cannot start the bracketed session") }
        var askedB = 0
        b.confirmPaste = { _, done in askedB += 1; done(true) }
        if !pump(5, until: { rows(b).contains("READY") }) { fail("paste guard: the bracketed session never started") }
        b.paste("MNO\nXYZ")
        if askedB != 0 { fail("paste guard: bracketed paste must not ask about a multi-line paste") }
        b.close()

        let dir = NSTemporaryDirectory() + "harf-selftest-pasteguard-\(getpid())"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try? "paste_guard = off\n".write(toFile: dir + "/config", atomically: false, encoding: .utf8)
        Settings.shared.load(directory: dir)
        defer { Settings.shared.load(directory: dir + "/none") }
        guard let o = TerminalController(argv: ["/bin/sh", "-c", "cat"], frame: NSSize(width: 700, height: 420)) else { fail("cannot start the guard-off session") }
        var askedO = 0
        o.confirmPaste = { _, done in askedO += 1; done(true) }
        o.paste("GHI\nJKL")
        if askedO != 0 { fail("paste guard: paste_guard = off must never ask") }
        o.close()

        let s = pasteSummary(of: "line1\nline2\u{1b}[31m", risk: 1)
        if !s.title.contains("2 lines") || s.detail.contains("\u{1b}") || !s.detail.contains("line1") { fail("paste guard: the summary is '\(s.title)' / '\(s.detail)'") }
        // The preview is the one place the user sees what will run, so text that reorders or hides itself must not: right-to-left
        // overrides and isolates are shown as a dot; a joiner (Persian, emoji) is kept.
        let bidi = pasteSummary(of: "echo hello \u{202E}~ fr- mr ;\u{2066}x\u{2069}\u{200F}", risk: 1)
        if bidi.detail.unicodeScalars.contains(where: { [0x202E, 0x2066, 0x2069, 0x200F].contains($0.value) }) { fail("paste guard: bidi controls reached the preview") }
        if !pasteSummary(of: "a\u{200D}b", risk: 1).detail.unicodeScalars.contains(where: { $0.value == 0x200D }) { fail("paste guard: a zero-width joiner must be kept") }
        // Line breaks are what the program sees as Enter (LF, CR, CRLF), not every Unicode separator; a trailing one ends the last line.
        if pasteSummary(of: "a\u{2028}b\u{0B}c", risk: 1).title.contains("lines") { fail("paste guard: U+2028 and VT are not line breaks for the program") }
        if pasteSummary(of: "ls\n", risk: 1).title.contains("lines") { fail("paste guard: 'ls' plus its line break is one line") }
        if !pasteSummary(of: "a\r\nb\rc\nd", risk: 1).title.contains("4 lines") { fail("paste guard: CRLF, CR and LF are one break each") }
        // A row the preview had to cut (here by the first-1000-characters limit, not the 80-column one) must say it goes on: four long lines,
        // then a fifth whose first 36 characters are all that was read.
        let cutText = (0..<4).map { _ in String(repeating: "a", count: 240) }.joined(separator: "\n") + "\n" + String(repeating: "b", count: 500)
        let cutRows = pasteSummary(of: cutText, risk: 1).detail.split(separator: "\n", omittingEmptySubsequences: false).filter { $0.hasPrefix("a") || $0.hasPrefix("b") }
        if cutRows.last.map({ !$0.hasSuffix("…") }) ?? true { fail("paste guard: a row cut by the preview's read limit shows no ellipsis ('\(cutRows.last ?? "")')") }
        // A 10 MB paste on one line is the very large case the guard exists for: the sheet must not wait on the whole text.
        let huge = String(repeating: "abcdefghij", count: 1_000_000)
        let began = Date()
        let hs = pasteSummary(of: huge, risk: 2)
        let took = Date().timeIntervalSince(began)
        if took > 0.25 || !hs.title.contains("MB") { fail("paste guard: summarising 10 MB took \(took) s ('\(hs.title)')") }
    }

    // 3c. Command-click on a path or a plain URL. The editor templates (URL, command run without a shell, app, default), a path under the
    // pointer (resolved against the pane's directory, and the file must exist), a plain http(s) URL, and the order: OSC 8, URL, path.
    do {
        let url12 = URL(string: "vscode://file/tmp/my%20dir/a%20b.swift:12:5")!
        if editorLaunch(template: "vscode://file{path}:{line}:{col}", path: "/tmp/my dir/a b.swift", line: 12, col: 5) != .url(url12) { fail("editor: the URL template gave \(editorLaunch(template: "vscode://file{path}:{line}:{col}", path: "/tmp/my dir/a b.swift", line: 12, col: 5))") }
        // a file name must not add parameters to a query-style template: & = ; + $ , @ are escaped along with the rest
        let queryLaunch = editorLaunch(template: "idea://open?file={path}&line={line}", path: "/tmp/x&line=99;a=b+c,d@e$f.txt", line: 7, col: 1)
        if queryLaunch != .url(URL(string: "idea://open?file=/tmp/x%26line%3D99%3Ba%3Db%2Bc%2Cd%40e%24f.txt&line=7")!) { fail("editor: a file name leaked into the query: \(queryLaunch)") }
        let hostile = "/tmp/x; rm -rf ~ $(id) 'q'.txt"
        if editorLaunch(template: "code --goto {path}:{line}:{col}", path: hostile, line: 0, col: 0) != .command(["code", "--goto", hostile + ":1:1"]) { fail("editor: a hostile file name must stay one argument") }
        if editorLaunch(template: "", path: "/tmp/a", line: 1, col: 1) != .textEditor { fail("editor: no template means the default text editor") }
        if editorLaunch(template: "app:/Applications/Sublime Text.app", path: "/tmp/a", line: 3, col: 1) != .app(URL(fileURLWithPath: "/Applications/Sublime Text.app")) { fail("editor: an app: template") }

        let dir = NSTemporaryDirectory() + "harf-selftest-pathclick-\(getpid())"
        try? FileManager.default.createDirectory(atPath: dir + "/sub", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try? "x\n".write(toFile: dir + "/b.txt", atomically: false, encoding: .utf8)
        let script = "printf 'see b.txt:4:2 ok /nope.txt:1 sub https://example.com/a. ftp://x.org/f\\n'; sleep 5"
        guard let pc = TerminalController(argv: ["/bin/sh", "-c", script], frame: NSSize(width: 700, height: 420), cwd: dir) else { fail("cannot start the path-click session") }
        if !pump(5, until: { pc.rowText(0).contains("ftp://") }) { fail("path click: row 0 is '\(pc.rowText(0))'") }
        let cell = pc.cellSizePt
        func at(_ col: Double) -> NSPoint { NSPoint(x: pc.insetPt + cell.width * (col + 0.5), y: pc.insetPt + cell.height * 0.5) }   // view coordinates (y-down)
        guard let target = pc.pathTarget(at: at(5)) else { fail("path click: a relative file in the pane's directory was not found") }
        if target.url.lastPathComponent != "b.txt" || target.line != 4 || target.col != 2 || !FileManager.default.fileExists(atPath: target.url.path) { fail("path click: the target is \(target)") }
        if pc.pathTarget(at: at(20)) != nil { fail("path click: a file that does not exist was offered") }
        if pc.pathTarget(at: at(30)) != nil { fail("path click: a directory was offered") }
        if pc.pathTarget(at: at(3)) != nil { fail("path click: a space gave a path") }
        if pc.urlTarget(at: at(40))?.absoluteString != "https://example.com/a" { fail("url click: got \(String(describing: pc.urlTarget(at: at(40))))") }
        if pc.urlTarget(at: at(60)) != nil || pc.urlTarget(at: at(5)) != nil { fail("url click: ftp or a path gave a URL") }

        // through the view: Command-click routes, a plain click does not
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = pc.view
        func click(_ col: Double, _ flags: NSEvent.ModifierFlags) {
            let p = NSPoint(x: pc.insetPt + cell.width * (col + 0.5), y: 420 - (pc.insetPt + cell.height * 0.5))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags, timestamp: 0, windowNumber: win.windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: 1, pressure: 1) else { fail("cannot make a mouse event") }
                if type == .leftMouseDown { pc.view.mouseDown(with: e) } else { pc.view.mouseUp(with: e) }
            }
        }
        var paths: [PathTarget] = []
        var urls: [URL] = []
        pc.openPath = { paths.append($0) }
        pc.openURL = { urls.append($0) }
        // a device and a FIFO exist and are not directories, but they are not files: opening them would read forever
        try? FileManager.default.removeItem(atPath: dir + "/pipe")
        if mkfifo(dir + "/pipe", 0o644) != 0 { fail("cannot make a FIFO") }
        guard let dev = TerminalController(argv: ["/bin/sh", "-c", "printf '/dev/null pipe\\n'; sleep 5"], frame: NSSize(width: 700, height: 420), cwd: dir) else { fail("cannot start the device session") }
        if !pump(5, until: { dev.rowText(0).contains("pipe") }) { fail("path click: row 0 is '\(dev.rowText(0))'") }
        if dev.pathTarget(at: NSPoint(x: dev.insetPt + cell.width * 2.5, y: dev.insetPt + cell.height * 0.5)) != nil { fail("path click: /dev/null was offered as a file") }
        if dev.pathTarget(at: NSPoint(x: dev.insetPt + cell.width * 12.5, y: dev.insetPt + cell.height * 0.5)) != nil { fail("path click: a FIFO was offered as a file") }
        dev.close()
        // command mode runs through a POSIX login shell: fish, tcsh and the like have no "$@", so they are not used
        if editorShell(env: "/opt/homebrew/bin/fish") != "/bin/zsh" || editorShell(env: nil) != "/bin/zsh" { fail("editor: a non-POSIX or missing SHELL must give /bin/zsh") }
        if editorShell(env: "/bin/bash") != "/bin/bash" || editorShell(env: "/usr/local/bin/zsh") != "/usr/local/bin/zsh" { fail("editor: a POSIX SHELL is kept") }

        click(5, [])
        if !paths.isEmpty { fail("path click: a plain click opened a path") }
        click(5, .command)
        if paths.count != 1 || paths[0].line != 4 || !urls.isEmpty { fail("path click: a Command-click gave paths \(paths), urls \(urls)") }
        click(40, .command)
        if urls.map(\.absoluteString) != ["https://example.com/a"] || paths.count != 1 { fail("url click: a Command-click gave paths \(paths), urls \(urls)") }
        click(60, .command)
        if urls.count != 1 || paths.count != 1 { fail("a Command-click on ftp:// opened something") }

        // The Command-hover highlight: the columns of what a Command-click would open (nothing for ftp://, a missing file, a directory
        // or a space), shown as a tint on exactly those cells and gone when cleared.
        if let h = pc.hoverLink(at: at(40)), (h.row, h.lo, h.hi) == (0, 33, 53) {} else { fail("hover: the URL's span is \(String(describing: pc.hoverLink(at: at(40))))") }
        if let h = pc.hoverLink(at: at(5)), (h.row, h.lo, h.hi) == (0, 4, 12) {} else { fail("hover: the file's span is \(String(describing: pc.hoverLink(at: at(5))))") }
        for col in [3.0, 20.0, 30.0, 60.0] where pc.hoverLink(at: at(col)) != nil { fail("hover: column \(col) has nothing to open but got a highlight") }
        func bottomEdge(_ col: Double) -> [Int] {
            guard let rep = pc.view.bitmapImageRepForCachingDisplay(in: pc.view.bounds) else { fail("cannot make a bitmap") }
            pc.view.cacheDisplay(in: pc.view.bounds, to: rep)
            let ratio = Double(rep.pixelsWide) / Double(pc.view.bounds.width)
            let x = Int((pc.insetPt + cell.width * (col + 0.5)) * ratio)
            let y = Int((pc.insetPt + cell.height) * ratio) - 1   // the last pixel row of row 0: where the highlight's line is
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { fail("cannot read a pixel") }
            return [Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255)]
        }
        // hover belongs to the view: Command pressed with the pointer elsewhere, a new painter, and the window losing key all clear it
        pc.setHover(pc.hoverLink(at: at(5)))
        pc.updateHover(command: true, at: NSPoint(x: -500, y: -500))
        if pc.hover != nil { fail("hover: a pointer outside the view kept (or made) a highlight") }
        pc.setHover(pc.hoverLink(at: at(5)))
        Settings.shared.fontLarger()
        if pc.hover != nil { fail("hover: the highlight outlived the painter that drew it") }
        Settings.shared.fontReset()
        pc.setHover(pc.hoverLink(at: at(5)))
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: win)
        _ = pump(0.3) { false }
        if pc.hover != nil { fail("hover: the highlight stayed after the window lost key") }
        pc.setHover(nil)
        let before = bottomEdge(8), other = bottomEdge(20)
        pc.setHover(pc.hoverLink(at: at(5)))
        let lit = bottomEdge(8)
        if zip(before, lit).allSatisfy({ abs($0 - $1) < 40 }) { fail("hover: the file's cells did not change (\(before) then \(lit))") }
        if bottomEdge(20) != other { fail("hover: a cell outside the span changed") }
        if bottomEdge(8) != lit { fail("hover: drawing again changed the highlight") }
        pc.setHover(nil)
        if bottomEdge(8) != before { fail("hover: the highlight stayed after it was cleared") }
        pc.close()
    }

    // 3d. The editor picker: which template an app gets, and the config line it writes (rewritten in place, read back by a reload, and
    // never able to carry a second setting in a line break).
    do {
        if editorTemplate(forBundleID: "com.microsoft.VSCode", appPath: "/Applications/Visual Studio Code.app") != "vscode://file{path}:{line}:{col}" { fail("picker: VS Code's template") }
        if editorTemplate(forBundleID: "com.microsoft.VSCodeInsiders", appPath: "/x.app") != "vscode-insiders://file{path}:{line}:{col}" { fail("picker: VS Code Insiders' template") }
        if editorTemplate(forBundleID: "com.vscodium", appPath: "/x.app") != "vscodium://file{path}:{line}:{col}" { fail("picker: VSCodium's template") }
        if editorTemplate(forBundleID: "com.todesktop.230313mzl4w4u92", appPath: "/x.app") != "cursor://file{path}:{line}:{col}" { fail("picker: Cursor's template") }
        if editorTemplate(forBundleID: "com.sublimetext.4", appPath: "/Applications/Sublime Text.app") != "app:/Applications/Sublime Text.app" { fail("picker: an unknown app is opened by app:") }
        if editorTemplate(forBundleID: nil, appPath: "/Applications/Other.app") != "app:/Applications/Other.app" { fail("picker: an app with no bundle id") }

        let dir = NSTemporaryDirectory() + "harf-selftest-editor-\(getpid())"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try? "font_size = 15\neditor = old\n".write(toFile: dir + "/config", atomically: false, encoding: .utf8)
        Settings.shared.load(directory: dir)
        defer { Settings.shared.load(directory: dir + "/none") }
        if Settings.shared.editor != "old" { fail("picker: the config's editor is '\(Settings.shared.editor)'") }
        if !Settings.shared.setEditor("vscode://file{path}:{line}:{col}") { fail("picker: setEditor failed") }
        if Settings.shared.editor != "vscode://file{path}:{line}:{col}" { fail("picker: the reload read '\(Settings.shared.editor)'") }
        let text = (try? String(contentsOfFile: dir + "/config", encoding: .utf8)) ?? ""
        if text != "font_size = 15\neditor = vscode://file{path}:{line}:{col}\n" { fail("picker: the file is now '\(text)'") }
        if Settings.shared.setEditor("a\nfont_size = 40") { fail("picker: a template with a line break was accepted") }
        if Settings.shared.editor != "vscode://file{path}:{line}:{col}" { fail("picker: a refused template changed the editor") }
    }

    // 4. Title and bell reach the window; a clean exit closes it.
    guard let wc1 = WindowController(argv: ["/bin/sh", "-c", "printf '\\033]0;T1\\007\\007'"], content: NSSize(width: 700, height: 420), cwd: nil) else { fail("cannot start title session") }
    var bells = 0
    wc1.allPanes[0].controller.onBell = { bells += 1 }
    if !pump(5, until: { wc1.closed }) { fail("a clean exit did not close the window") }
    if wc1.window.title != "T1" { fail("title is '\(wc1.window.title)'") }
    if bells != 1 { fail("bell count is \(bells)") }

    // 2i. Configuration, through the app's own path: a config file sets the font and the theme (the core is told, so a program's
    // colour query gets the new colours), a key binding intercepts a key, a theme file is read, a bad line is a warning, and
    // saving the file changes the settings with no restart (file watching).
    do {
        let tmp = NSTemporaryDirectory() + "harf-selftest-config-\(getpid())"
        let fm = FileManager.default
        try? fm.removeItem(atPath: tmp)
        try? fm.createDirectory(atPath: tmp + "/themes", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tmp) }
        func write(_ name: String, _ text: String, atomically: Bool = false) { try? text.write(toFile: tmp + "/" + name, atomically: atomically, encoding: .utf8) }
        write("themes/mine", "background = #102030\nforeground = #a0b0c0\npalette = 1=#ff0000\n")
        write("config", "font_size = 20\nwindow_width = 960\nwindow_height = 600\ntheme = mine\nclipboard_write = deny\nnotifications = off\nkeybind = option+left = send:X\nbogus line\n")
        let plainCell = TerminalController(argv: ["/bin/sh", "-c", "sleep 1"], frame: NSSize(width: 700, height: 420))?.cellSizePt
        Settings.shared.load(directory: tmp)
        if Settings.shared.fontPt != 20 { fail("config: font size is \(Settings.shared.fontPt)") }
        if Settings.shared.windowWidth != 960 || Settings.shared.windowHeight != 600 { fail("config: window size is \(Settings.shared.windowWidth)x\(Settings.shared.windowHeight)") }
        if Settings.shared.warnings.count != 1 || !Settings.shared.warnings[0].contains("line 8") { fail("config: warnings are \(Settings.shared.warnings)") }
        if Settings.shared.notifications != 2 || Settings.shared.clipboardWrite { fail("config: notifications \(Settings.shared.notifications), clipboard \(Settings.shared.clipboardWrite)") }
        let script = "stty raw -echo; printf R; head -c 1 | od -An -c"
        guard let c = TerminalController(argv: ["/bin/sh", "-c", script], frame: NSSize(width: 700, height: 420)) else { fail("cannot start the config session") }
        if let plain = plainCell, !(c.cellSizePt.width > plain.width * 1.3) { fail("config: font_size = 20 did not enlarge the cell (\(c.cellSizePt) against \(plain))") }
        guard let bg = c.defaultBackground() else { fail("config: no background") }
        if abs(bg.redComponent - 0x10 / 255.0) > 0.01 || abs(bg.greenComponent - 0x20 / 255.0) > 0.01 || abs(bg.blueComponent - 0x30 / 255.0) > 0.01 { fail("config: the theme file's background is \(bg)") }
        if !pump(5, until: { c.rowText(0).contains("R") }) { fail("config: child not ready '\(c.rowText(0))'") }
        c.view.keyDown(with: keyEvent(123, "\u{F702}", [.option, .numericPad, .function]))   // bound: sends X, not the editing key's ESC b
        if !pump(5, until: { (0..<3).contains { c.rowText($0).dropFirst().contains("X") } }) { fail("config: the binding sent '\((0..<3).map { c.rowText($0) })'") }
        c.close()
        // saving the file (in place, then replaced) is seen without a restart
        write("config", "font_size = 11\ntheme = mine\n")
        if !pump(5, until: { Settings.shared.fontPt == 11 }) { fail("config: an edit in place was not noticed (font size \(Settings.shared.fontPt))") }
        write("config", "font_size = 13\ntheme = mine\n", atomically: true)
        if !pump(5, until: { Settings.shared.fontPt == 13 }) { fail("config: a replaced file was not noticed (font size \(Settings.shared.fontPt))") }
        write("themes/mine", "background = #405060\n")
        let live = TerminalController(argv: ["/bin/sh", "-c", "sleep 3"], frame: NSSize(width: 700, height: 420))
        if !pump(5, until: { (live?.defaultBackground()?.redComponent ?? 0) > 0.2 }) { fail("config: a changed theme file did not reach a running terminal") }
        live?.close()
        // back to the built-in defaults for the rest of the run
        let empty = tmp + "/empty"
        try? fm.createDirectory(atPath: empty, withIntermediateDirectories: true)
        Settings.shared.load(directory: empty)
        if Settings.shared.fontPt != 14 || Settings.shared.windowWidth != 1000 || Settings.shared.windowHeight != 720 || !Settings.shared.clipboardWrite { fail("config: an empty directory did not give the defaults") }
    }

    // 2j. Panes, through the window controller the app uses: a split shares the window and starts where its neighbour's shell is,
    // splits nest, a closed pane gives its place to its neighbour, the keyboard moves between panes, and the last pane closes the
    // window. Find counts matches in the scrollback and scrolls to each.
    do {
        setenv("SHELL", "/bin/sh", 1)   // a split starts the login shell: keep the user's own startup files out of the test
        let script = "echo needle-top; seq 1 100; echo needle-bottom; sleep 30"
        guard let wc = WindowController(argv: ["/bin/sh", "-c", script], content: NSSize(width: 700, height: 420), cwd: "/usr") else { fail("cannot make a window controller") }
        var windowClosed = false
        wc.onClose = { _ in windowClosed = true }
        guard let first = wc.allPanes.first, wc.allPanes.count == 1 else { fail("a new window should have one pane") }
        let cols = first.controller.gridSize.cols
        if !pump(5, until: { (0..<first.controller.gridSize.rows).contains { first.controller.rowText($0).contains("needle-bottom") } }) { fail("panes: the first pane's output never arrived") }
        // find: two matches, the newest first; the older one is in the scrollback and the view is taken to it
        if first.controller.findStart("NEEDLE") != 2 { fail("find: expected two matches for NEEDLE") }
        guard let a = first.controller.findStep(older: true), a.number == 1, a.total == 2 else { fail("find: the first step should be match 1 of 2") }
        guard let b = first.controller.findStep(older: true), b.number == 2 else { fail("find: the second step should be match 2 of 2") }
        if !(0..<first.controller.gridSize.rows).contains(where: { first.controller.rowText($0).contains("needle-top") }) { fail("find: the view did not scroll to the older match") }
        first.showFind()
        if !first.isFindOpen { fail("find: the bar did not open") }
        first.hideFind()
        if first.isFindOpen || first.controller.findStart("") != 0 { fail("find: the bar did not close") }
        // split: a second shell in the directory the first one is in, side by side
        wc.split(first, vertical: true)
        guard wc.allPanes.count == 2, wc.allPanes[0] === first else { fail("split: expected two panes") }
        let second = wc.allPanes[1]
        if !(second.controller.gridSize.cols < cols && first.controller.gridSize.cols < cols) { fail("split: the panes should each be narrower than the whole window (\(first.controller.gridSize.cols), \(second.controller.gridSize.cols) of \(cols))") }
        if abs(first.frame.width - second.frame.width) > 24 { fail("split: unequal panes \(first.frame.width) and \(second.frame.width)") }
        if wc.focusedPane() !== second { fail("split: the new pane should have the keyboard") }
        // a window that is not key (every window here) gives no pane the keyboard, so no pane may write the clipboard or silence a notification
        if wc.allPanes.contains(where: { $0.controller.hasKeyboard() || $0.controller.clipboardWriteAllowed() }) { fail("panes: a pane of a window that is not key has the keyboard") }
        second.controller.sendText("pwd -P\n")
        if !pump(8, until: { (0..<second.controller.gridSize.rows).contains { second.controller.rowText($0).trimmingCharacters(in: .whitespaces) == "/usr" } }) {
            fail("split: the new shell did not start in /usr: '\((0..<4).map { second.controller.rowText($0) })'")
        }
        // nest a split below the second pane, move the keyboard around, close the middle one
        wc.split(second, vertical: false)
        if wc.allPanes.count != 3 { fail("split: expected three panes") }
        let third = wc.allPanes[2]
        if let dir = ProcessInfo.processInfo.environment["HARF_SELFTEST_PNG_DIR"] {   // pictures for a human, drawn offscreen
            first.showFind()
            first.findChanged("9")   // many matches in view: the number rows 89 to 99
            _ = pump(0.5) { false }
            func shot(_ v: NSView, _ name: String) {
                v.layoutSubtreeIfNeeded()
                guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/" + name))
            }
            shot(wc.window.contentView!, "shell-panes-whole.png")
            shot(first, "shell-pane-first.png")
            shot(second, "shell-pane-second.png")
            shot(third.controller.view, "shell-view-third.png")
            first.hideFind()
            wc.window.makeFirstResponder(third.controller.view)
        }
        wc.focusPane(next: true)
        if wc.focusedPane() !== first { fail("focus: next from the last pane should wrap to the first") }
        wc.focusPane(next: false)
        if wc.focusedPane() !== third { fail("focus: previous from the first pane should wrap to the last") }
        wc.close(pane: second)
        if wc.allPanes.count != 2 || wc.allPanes[0] !== first || wc.allPanes[1] !== third { fail("close: the neighbour should take the closed pane's place") }
        if abs(third.frame.width - first.frame.width) > 24 { fail("close: the remaining panes should share the window (\(first.frame.width), \(third.frame.width))") }
        wc.close(pane: third)
        if wc.allPanes.count != 1 || windowClosed { fail("close: one pane should remain and the window stay open") }
        wc.close(pane: first)
        if !windowClosed || !wc.closed { fail("close: closing the last pane should close the window") }
    }

    // 2k. The app's own shortcuts, end to end: a Command key reaches the view, the key map finds the action, and the app delegate
    // does it. (2i and 2j test the key map and the panes; this is the layer between them, which the real app runs.)
    do {
        let d = AppDelegate()
        NSApp.delegate = d
        let defaults = NSTemporaryDirectory() + "harf-selftest-shortcuts-\(getpid())"
        try? FileManager.default.createDirectory(atPath: defaults, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: defaults) }
        Settings.shared.load(directory: defaults)   // the default key bindings
        guard let c = TerminalController(argv: ["/bin/sh", "-c", "sleep 8"], frame: NSSize(width: 700, height: 420)) else { fail("cannot start the shortcut session") }
        let opened = NSApp.windows.count
        if !c.view.performKeyEquivalent(with: keyEvent(45, "n", [.command])) { fail("shortcuts: Cmd+N was not handled by the view") }
        if NSApp.windows.count != opened + 1 { fail("shortcuts: Cmd+N did not open a window (\(opened) windows before, \(NSApp.windows.count) after)") }
        if c.view.performKeyEquivalent(with: keyEvent(45, "n", [.control])) { fail("shortcuts: Ctrl+N must reach the program, not open a window") }
        if !c.view.performKeyEquivalent(with: keyEvent(17, "t", [.command])) { fail("shortcuts: Cmd+T was not handled by the view") }
        if NSApp.windows.count != opened + 2 { fail("shortcuts: Cmd+T did not open a tab (\(NSApp.windows.count) windows)") }
        if !c.view.performKeyEquivalent(with: keyEvent(37, "l", [.control])) { fail("shortcuts: Ctrl+L was not handled on the main screen") }
        for w in NSApp.windows.suffix(2) { w.close() }   // closing them ends their shells
        c.close()
        NSApp.delegate = nil
    }

    // 2k2. Select all, the keyboard selection moves (word and line edge, from the cursor) and Cmd+Z, as real key events with the
    // default bindings. The first row is a separate logical line, so only Cmd+A can reach it.
    do {
        let dir = NSTemporaryDirectory() + "harf-selftest-selkeys-\(getpid())"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        Settings.shared.load(directory: dir)
        guard let c = TerminalController(argv: ["/bin/sh", "-c", "printf 'first line\\nalpha beta gamma'; sleep 8"], frame: NSSize(width: 700, height: 420)) else { fail("cannot start the selection-key session") }
        if !pump(5, until: { c.rowText(1).contains("gamma") }) { fail("selection keys: the text did not arrive ('\(c.rowText(1))')") }
        func press(_ name: String, _ ev: NSEvent, expect want: String) {
            if !c.view.performKeyEquivalent(with: ev) { fail("selection keys: \(name) was not handled by the view") }
            if c.selectedText() != want { fail("selection keys: after \(name) the selection is '\(String(describing: c.selectedText()))', want '\(want)'") }
        }
        let left: NSEvent.ModifierFlags = [.numericPad, .function]
        press("Option+Shift+Left", keyEvent(123, "\u{F702}", left.union([.option, .shift])), expect: "gamma")
        press("Option+Shift+Left again", keyEvent(123, "\u{F702}", left.union([.option, .shift])), expect: "beta gamma")
        press("Cmd+Shift+Left", keyEvent(123, "\u{F702}", left.union([.command, .shift])), expect: "alpha beta gamma")
        press("Cmd+A", keyEvent(0, "a", [.command]), expect: "first line\nalpha beta gamma")
        c.close()
        expectBytes("cmd+z sends ctrl+_", prelude: "", count: 1, events: [keyEvent(6, "z", [.command])], contains: "1f")
    }

    // 2l. With several panes, a shortcut acts on the pane that has the keyboard. AppKit offers a key to every terminal view in the
    // window in turn, so a view must refuse it unless it is the one in focus (before this, the first pane took every Cmd+V).
    do {
        let dir = NSTemporaryDirectory() + "harf-selftest-focus-\(getpid())"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try? "keybind = cmd+j = send:Z\n".write(toFile: dir + "/config", atomically: false, encoding: .utf8)
        Settings.shared.load(directory: dir)
        defer { Settings.shared.load(directory: dir + "/none") }   // back to the defaults for what follows
        setenv("SHELL", "/bin/sh", 1)
        let watch = "stty raw -echo; echo READY; head -c 1 | od -An -c; sleep 30"
        guard let wc = WindowController(argv: ["/bin/sh", "-c", watch], content: NSSize(width: 700, height: 420), cwd: nil) else { fail("cannot make the focus window") }
        let first = wc.allPanes[0]
        wc.split(first, vertical: true)
        let second = wc.allPanes[1]
        second.controller.sendText("\(watch)\n")
        // The program's own output is a row that is exactly READY. The typed command is echoed before the shell has run it (and wraps
        // at the pane's width, which can split "echo" across rows), so a row that merely contains READY proves nothing.
        func ready(_ p: TerminalPane) -> Bool { (0..<p.controller.gridSize.rows).contains { p.controller.rowText($0).trimmingCharacters(in: .whitespaces) == "READY" } }
        if !pump(8, until: { ready(first) && ready(second) }) { fail("focus: the two panes never became ready") }
        wc.window.makeFirstResponder(second.controller.view)
        let event = keyEvent(38, "j", [.command])
        if first.controller.view.performKeyEquivalent(with: event) { fail("focus: a pane that does not have the keyboard handled a shortcut") }
        if !second.controller.view.performKeyEquivalent(with: event) { fail("focus: the pane that has the keyboard did not handle it") }
        func sawZ(_ p: TerminalPane) -> Bool { (0..<p.controller.gridSize.rows).contains { p.controller.rowText($0).contains("Z") } }   // READY has no Z
        if !pump(5, until: { sawZ(second) }) { fail("focus: the shortcut's text never reached the focused pane") }
        _ = pump(0.5) { false }
        if sawZ(first) { fail("focus: the shortcut's text reached the pane that was not in focus") }
        wc.window.close()
    }

    // 2m. Cmd+C while the find bar is open copies the match, which is the terminal's selection. The find field has the keyboard and
    // nothing selected in it, so before this the copy went to the field and copied nothing.
    do {
        guard let wc = WindowController(argv: ["/bin/sh", "-c", "echo hay needle stack; sleep 30"], content: NSSize(width: 700, height: 420), cwd: nil) else { fail("cannot make the find-copy window") }
        let pane = wc.allPanes[0]
        let pb = NSPasteboard(name: NSPasteboard.Name("harf.selftest.findcopy.\(getpid())"))
        pb.clearContents()
        pane.controller.clipboard = pb
        if !pump(5, until: { pane.controller.rowText(0).contains("needle") }) { fail("find copy: the output never arrived") }
        pane.showFind()
        pane.findChanged("needle")
        guard let field = wc.window.firstResponder as? NSTextView else { fail("find copy: the find field should have the keyboard") }
        if field.selectedRange.length != 0 { fail("find copy: nothing should be selected in the find field") }
        if pane.controller.selectedText() != "needle" { fail("find copy: the match is not the terminal's selection ('\(String(describing: pane.controller.selectedText()))')") }
        let d = AppDelegate()
        if !d.perform("copy", [], from: pane.controller) { fail("find copy: the copy was not handled") }
        if pb.string(forType: .string) != "needle" { fail("find copy: the clipboard holds '\(String(describing: pb.string(forType: .string)))', not the match") }
        pb.clearContents()
        wc.window.close()
    }

    // 2n. Focus (the cursor, and focus in and out for a program that asked, mode 1004) follows the pane that has the keyboard, not
    // every pane of the key window. Before this every pane was told it had focus when the window became key, and nobody heard
    // the keyboard move between panes. The find bar belongs to its pane: opening and closing it must not look like a focus change.
    do {
        setenv("SHELL", "/bin/sh", 1)
        let watch = "stty raw -echo; printf '\\033[?1004h'; echo READY; head -c 6 | od -An -tx1 | tr -s ' '; sleep 30"
        // Both programs are typed into a shell after the panes are in the window: a program that asked for focus events before its
        // view was attached would be told "out" by the attaching, ahead of what this test looks for.
        guard let wc = WindowController(argv: nil, content: NSSize(width: 700, height: 420), cwd: nil) else { fail("cannot make the pane focus window") }
        let first = wc.allPanes[0]
        wc.split(first, vertical: true)
        let second = wc.allPanes[1]
        first.controller.sendText("\(watch)\n")
        second.controller.sendText("\(watch)\n")
        // As in the focus test above: only a row that is exactly READY is the program's output, not the echo of the typed command.
        func ready(_ p: TerminalPane) -> Bool { (0..<p.controller.gridSize.rows).contains { p.controller.rowText($0).trimmingCharacters(in: .whitespaces) == "READY" } }
        func heard(_ p: TerminalPane) -> Bool { (0..<p.controller.gridSize.rows).contains { p.controller.rowText($0).contains("1b 5b 49 1b 5b 4f") } }   // in, then out
        if !pump(8, until: { ready(first) && ready(second) }) { fail("pane focus: the two panes never became ready") }
        // the window becomes key with the keyboard in the second pane: only that program hears focus in
        wc.window.makeFirstResponder(second.controller.view)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: wc.window)
        _ = pump(0.3) { false }   // the notification is delivered on the run loop; the keyboard moves only after it
        // the keyboard moves to the first pane: the second hears focus out (its six bytes are in, out), the first hears focus in
        wc.window.makeFirstResponder(first.controller.view)
        if !pump(5, until: { heard(second) }) { fail("pane focus: the pane that lost the keyboard did not hear focus out after focus in") }
        _ = pump(0.3) { false }
        if heard(first) { fail("pane focus: the first pane heard focus out before it lost the keyboard") }
        // its find bar takes the keyboard and gives it back: that is still the same pane, so its program hears nothing
        first.showFind()
        first.hideFind()
        _ = pump(0.5) { false }
        if heard(first) { fail("pane focus: opening and closing the find bar looked like a focus change to the program") }
        // the keyboard leaves the first pane: now its program hears focus out
        wc.window.makeFirstResponder(second.controller.view)
        if !pump(5, until: { heard(first) }) { fail("pane focus: the first pane never heard focus in then out") }
        wc.window.close()
    }

    // 2o. First run: Cmd+, on a machine with no config directory creates it, and what the user then saves is noticed (nothing was
    // being watched, because the directory did not exist when the configuration was read).
    do {
        let tmp = NSTemporaryDirectory() + "harf-selftest-firstrun-\(getpid())"
        let fm = FileManager.default
        try? fm.removeItem(atPath: tmp)
        Settings.shared.load(directory: tmp + "/harf")   // does not exist yet
        let path = Settings.shared.ensureConfigFile()
        if path != tmp + "/harf/config" || !fm.fileExists(atPath: path) { fail("first run: the config file is '\(path)', exists \(fm.fileExists(atPath: path))") }
        try? "font_size = 22\n".write(toFile: path, atomically: false, encoding: .utf8)
        if !pump(5, until: { Settings.shared.fontPt == 22 }) { fail("first run: a file saved in the new config directory was not noticed (font size \(Settings.shared.fontPt))") }
        Settings.shared.load(directory: tmp + "/none")   // back to the defaults for what follows
        try? fm.removeItem(atPath: tmp)
    }

    // 2p. OSC 133 marks reach the controller as a start and an end, with the exit code and how long the command ran; and only a
    // command that ran long enough produces a notification, which says nothing of what was run.
    do {
        guard let c = TerminalController(argv: ["/bin/sh", "-c", "printf '\\033]133;C\\007'; sleep 0.3; printf '\\033]133;D;3\\007'; sleep 5"], frame: NSSize(width: 700, height: 420)) else { fail("cannot start the command-state session") }
        var events: [(running: Bool, exitCode: Int32?, durationMs: UInt32)] = []
        c.onCommand = { events.append(($0, $1, $2)) }
        if !pump(5, until: { events.count >= 2 }) { fail("command state: wanted a start and an end, got \(events.count) events") }
        if !events[0].running { fail("command state: the first event must be the start") }
        if events[1].running || events[1].exitCode != 3 || events[1].durationMs < 250 { fail("command state: the end was \(events[1])") }
        c.close()
        if commandNotification(exitCode: 3, durationMs: 12_000)?.body != "Failed (exit 3)" { fail("a failed long command must say it failed") }
        if commandNotification(exitCode: 0, durationMs: 10_000)?.body != "Done" || commandNotification(exitCode: nil, durationMs: 10_000)?.body != "Done" { fail("a finished long command says Done") }
        if commandNotification(exitCode: 0, durationMs: 9_999) != nil { fail("a short command must not notify") }
    }

    // 2q. Opening folders via Finder Services, `open -a` (`application(_:open:)`), and CLI arguments.
    do {
        let fm = FileManager.default
        let base = NSTemporaryDirectory() + "harf-selftest-open-\(getpid())"
        let dirA = base + "/folder a"
        let dirB = base + "/folder-b"
        let linkB = base + "/link-b"
        let fileA = dirA + "/note.txt"
        try? fm.createDirectory(atPath: dirA, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: dirB, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(atPath: linkB, withDestinationPath: dirB)
        try? "hi\n".write(toFile: fileA, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(atPath: base) }

        if resolveDirectory(URL(fileURLWithPath: dirA)) != dirA { fail("open dir: directory resolution failed") }
        if resolveDirectory(URL(fileURLWithPath: linkB)) != linkB { fail("open dir: symlink directory resolution failed") }
        if resolveDirectory(URL(fileURLWithPath: fileA)) != dirA { fail("open dir: file should resolve to parent dir") }
        if resolveDirectory(URL(fileURLWithPath: base + "/missing")) != nil { fail("open dir: missing path should be nil") }
        let parsed = launchDirectories(from: ["Harf", "-psn_0_99", "-NSDocumentRevisionsDebugMode", "YES", dirA, "--", dirB])
        if parsed != [dirA, dirB] { fail("open dir: launchDirectories returned \(parsed)") }

        setenv("SHELL", "/bin/sh", 1)
        let d0 = AppDelegate()
        if !d0.applicationShouldOpenUntitledFile(NSApp) { fail("open dir: fresh delegate should allow untitled window") }
        d0.launchDirectories = [dirA]
        if d0.applicationShouldOpenUntitledFile(NSApp) { fail("open dir: delegate with launchDirectories should suppress untitled window") }

        let d = AppDelegate()
        NSApp.delegate = d
        defer { NSApp.delegate = nil }
        let before = NSApp.windows.count
        d.application(NSApp, open: [URL(fileURLWithPath: dirA)])
        if NSApp.windows.count != before + 1 { fail("open dir: application(_:open:) did not open a window") }
        if d.applicationShouldOpenUntitledFile(NSApp) { fail("open dir: should not open an untitled window after open(_:open:)") }
        d.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        _ = pump(0.15) { false }
        if NSApp.windows.count != before + 1 { fail("open dir: didFinishLaunching opened an extra window") }

        guard let w1 = NSApp.windows.last, let p1 = panes(under: w1.contentView).first else { fail("open dir: missing first pane") }
        p1.controller.sendText("pwd\n")
        if !pump(5, until: { (0..<p1.controller.gridSize.rows).contains { p1.controller.rowText($0).contains("folder a") } }) {
            fail("open dir: first window did not start in '\(dirA)'")
        }

        let pb = NSPasteboard(name: NSPasteboard.Name("harf.selftest.service.\(getpid())"))
        pb.clearContents()
        pb.writeObjects([URL(fileURLWithPath: dirB) as NSURL])
        var serviceErr: NSString?
        d.newTerminalAtFolder(pb, userData: "New Tab", error: &serviceErr)
        if serviceErr != nil { fail("open dir: service tab failed: \(String(describing: serviceErr))") }
        if NSApp.windows.count != before + 2 { fail("open dir: service tab did not open a window") }
        if w1.tabbedWindows?.count != 2 { fail("open dir: service New Tab did not attach as a tab") }
        guard let w2 = NSApp.windows.last, let p2 = panes(under: w2.contentView).first else { fail("open dir: missing second pane") }
        p2.controller.sendText("pwd\n")
        if !pump(5, until: { (0..<p2.controller.gridSize.rows).contains { p2.controller.rowText($0).contains("folder-b") } }) {
            fail("open dir: tab did not start in '\(dirB)'")
        }

        pb.clearContents()
        pb.setString(dirA, forType: .string)
        serviceErr = nil
        d.newTerminalAtFolder(pb, userData: nil, error: &serviceErr)
        if serviceErr != nil || NSApp.windows.count != before + 3 { fail("open dir: plain-text service failed") }

        pb.clearContents()
        pb.setString(base + "/missing", forType: .string)
        serviceErr = nil
        d.newTerminalAtFolder(pb, userData: nil, error: &serviceErr)
        if serviceErr == nil || NSApp.windows.count != before + 3 { fail("open dir: invalid path should set service error") }

        pb.clearContents()
        for w in NSApp.windows.suffix(3) { w.close() }
    }

    // 5. A failing shell keeps its window and says so.
    guard let wc2 = WindowController(argv: ["/bin/sh", "-c", "echo boom; exit 3"], content: NSSize(width: 700, height: 420), cwd: nil) else { fail("cannot start failing session") }
    let bad = wc2.allPanes[0].controller
    if !pump(5, until: { bad.exitStatus == 3 }) { fail("exit status is \(String(describing: bad.exitStatus))") }
    _ = pump(0.2) { false }
    if wc2.closed { fail("exit status 3 closed the window") }
    if !wc2.window.title.contains("exited (3)") { fail("title is '\(wc2.window.title)'") }
    if !bad.rowText(0).contains("boom") { fail("row 0 is '\(bad.rowText(0))'") }
    wc2.window.close()

    for p in tempScripts { try? FileManager.default.removeItem(atPath: p) }
    print("selftest ok")
    exit(0)
}

let args = CommandLine.arguments
traceStep("main() entered")
if args.contains("--selftest") {
    setvbuf(stdout, nil, _IONBF, 0)
    MainActor.assumeIsolated { _ = NSApplication.shared; selfTest() }
}

if let i = args.firstIndex(of: "--conformance"), i + 1 < args.count {
    setvbuf(stdout, nil, _IONBF, 0)
    let dir = args[i + 1]
    MainActor.assumeIsolated { _ = NSApplication.shared; conformance(dir: dir) }
}

let app = NSApplication.shared
traceStep("NSApplication.shared")
let delegate = AppDelegate()
delegate.launchDirectories = launchDirectories(from: args)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
