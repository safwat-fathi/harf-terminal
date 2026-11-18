# Performance

Budgets: see `PROJECT_BRIEF.md` section 7. Measure before optimizing; record every run here.

## Method (Phase 0 baseline, keep identical for later runs)

- **Build:** Release (`zig build -Doptimize=ReleaseFast`, `swift build -c release`) via `macos/build-app.sh`.
- **Launch:** `open macos/.build/Harf.app`, wait 5 s for the first frame, then leave the window untouched and unfocused-safe (no input).
- **Memory:** `footprint <pid>` (phys_footprint) and `ps -o rss= -p <pid>` (KB).
- **Idle CPU:** `ps -o %cpu= -p <pid>` sampled every 2 s for 60 s; record mean and max. Also record cumulative CPU time (`ps -o time=`) before and after, which is more reliable than `%cpu` at near-zero load.
- **Record** machine model, chip, macOS version, Xcode/Swift and Zig versions with every row.

## Results

| Date | Build | Machine / OS | RSS (MB) | phys_footprint (MB) | Idle CPU mean / max (%) | Notes |
|---|---|---|---|---|---|---|
| 2026-11-13 | Release (`macos/build-app.sh`; Zig 0.17.1 ReleaseFast, Swift 6.2.4) | Apple M1, macOS 27.0.1 | 64-67 | 26 (peak 30) | 0.01 / 0.20 (30 samples over 60 s) | empty AppKit + Metal window, Phase 0; `bench/idle.sh` |

Cumulative CPU time over the 60 s idle window: 0:00.40 -> 0:00.42 (0.02 s), consistent with no timers or display link.
The 5 s startup was not timed precisely; first frame is visible by the first sample, so startup is well under any budget so far (not yet measured).

## The 30 MB target: definition and corrected measurements (2026-11-13)

**Definition.** `phys_footprint` from `footprint <pid>`, Release build, one window, empty session, measured 12-20 s after
launch, Apple M1, macOS 27.0.1. **Window size is part of the definition**, because the window's backing IOSurface is charged to
the app and scales with pixel count. Reference sizes: **80x24 class = 700x420 pt content**, and Terminal.app's default
window on this machine = 1162x597 pt content.

**Correction.** An earlier version of this section said Terminal.app is 17 MB and that window pixels live in WindowServer and are
not charged to the app. That was wrong: the 17 MB run had no real window (I never confirmed one existed). With a confirmed
1162x597 window, Terminal.app is **63 MB transient, 50 MB settled**, with a 10-19 MB `IOSurface` line charged to the process.

Controlled prototypes (throwaway, `NSView.draw` with `CTLineDraw` vs an empty `MTKView`, same window size):

| Window (content) | CPU-drawn view | Metal view (3 drawables) |
|---|---|---|
| 700x420 pt (80x24 class) | **25 MB** (IOSurface 5 MB) | 30 MB (IOSurface 9.5 MB) |
| 1162x597 pt | **30-31 MB** (IOSurface 11 MB) | 42-43 MB (IOSurface 22 MB, three surfaces) |

Other apps, same machine (not controlled for content): Terminal.app 50 MB at 1162x597; Ghostty 1.4.0 65 MB
(`Malloc Small` 46 MB, window size unknown). Metal `maximumDrawableCount` 2 vs 3 changed nothing (still three surfaces).

What this says:

- CPU drawing is 5-13 MB lighter than Metal at equal window size, because a layer-backed CPU view keeps one backing
  surface while a Metal layer holds several drawables. That, not "pixels live in WindowServer", is why the renderer change helps.
- Window size dominates. An empty CPU-drawn view is already 25 MB at 80x24 and 30 MB at Terminal's default size, before any
  terminal state exists. **30 MB is plausible at 80x24, not at 1162x597.** The Zig core, grid and scrollback must fit in the
  remaining ~5 MB at 80x24.
- Harf spike with the Metal path, atlas 2048: 34 MB; atlas 1024: 28 MB (window ~1083x248 pt). The atlas existed twice
  (4 MB CPU + 4 MB GPU). The CPU renderer has no atlas.
- **Real CPU-drawn spike app** (Zig core + CoreText, window 1083x362 pt, 2166x724 px): 30 MB at 12 s, 36 MB on a later sample;
  `IOSurface` 11 MB, `Malloc Small` 11 MB, no GPU categories. Idle CPU 0.53 s -> 0.78 s cumulative over the sampling interval (no timers).
  It is not a terminal yet (no grid or PTY), and the window is larger than the 80x24 class, so this is not yet a pass or fail against 30 MB.
- **Same spike app, window pinned to 700x420 pt (80x24 class)** via the `HARF_CONTENT_SIZE=700x420` hook in `main.swift`, Release,
  Apple M1, macOS 27.0.1, run directly (not through `open`): **28 MB `phys_footprint` at 15 s and still 28 MB at 45 s** (RSS 65 MB then 44 MB).
  `Malloc Small` 11 MB, `IOSurface` 9.2 MB, `Malloc Metadata` 0.9 MB. Cumulative CPU 0:00.72 -> 0:00.74 over 30 s idle (no timers).
  Under the 30 MB target by 2 MB, but this is still not a terminal (no grid, PTY, scrollback), and its 11 MB of malloc is the spike's
  font and layout state, not a measured terminal core. **Unexplained:** `IOSurface` here is 9.2 MB (about two 1400x840 surfaces) versus
  5 MB in the throwaway `NSView.draw` prototype at the same window size; the real view may hold an extra backing surface. Worth
  finding before the grid exists, because it is the largest single line the shell controls.
- "Feels faster" is latency, not memory. Keypress-to-pixel is not measured yet.

## Budget status

- **Owner decision (2026-11-13): target 30 MB `phys_footprint`, CPU-drawn renderer** (replaces Metal; brief section 2).
- Idle RSS is not a usable budget: an empty AppKit window is ~60-90 MB RSS because RSS counts shared framework pages. Track `phys_footprint`.
- Status against the target, at the 80x24-class window: empty CPU-drawn view 25 MB. Headroom ~5 MB for the Zig core, grid,
  scrollback and shaping caches. Not yet measured with the real core.
- At larger windows the empty view alone reaches 30 MB (1162x597), so the target only holds for small windows unless
  the backing store is reduced further. Revisit with measured numbers once the real grid exists.
- Idle CPU budget (~0%) was met by the Phase 0 baseline: 0.01% mean. Re-measure for the CPU renderer (it redraws on dirty rects only).
- Throughput against GPU terminals (brief section 7) may drop with CPU drawing; measure with vtebench in Phase 3 and revisit.

## Phase 4: shaped Arabic rows (2026-11-14)

Method: `Harf --selftest` (section 1b). A child prints 40 distinct lines of Arabic text (about 80 columns each); the view then
draws the whole 80x24 grid (700x420 pt, retina) twice with `cacheDisplay`: the first draw shapes every row, the second hits the
row cache (`Painter.max_cached_rows` = 128). Times include AppKit's bitmap path, not only the painter. Three runs each.
Build: `macos/build-app.sh` (Zig 0.17.1 ReleaseFast, Swift release). Apple M1, macOS 27.0.1.

| Draw | ms (3 runs) |
|---|---|
| Cold, 24 shaped rows | 15.3, 14.9, 14.1 |
| Cached, same rows | 2.1, 2.1, 2.1 |

Rows without RTL text never reach CoreText shaping (counted by `Painter.stats.plain_rows` in tests). Not measured: typing latency,
a screen where every wake changes every row, memory with the cache full (128 rows; the footprint measurement is slice 4).

## Slice 3: colored screens (2026-11-14)

Same method as the Phase 4 section (`Harf --selftest`, section 1d): a child prints 40 lines whose color changes on every line,
the view draws the whole 80x24 grid twice with `cacheDisplay`. "Cold" draws every row, "second" reuses cached Arabic layouts
(plain rows have no cache). Release build via `macos/build-app.sh`, Apple M1, macOS 27.0.1, three runs.

| Screen | Cold (ms) | Second draw (ms) |
|---|---|---|
| Colored Latin, per-cell path | 2.9, 3.0, 2.7 | 1.9, 2.0, 1.8 |
| Colored Arabic, shaped path | 14.6, 13.7, 12.9 | 2.7, 2.9, 2.6 |
| Phase 4, uncolored Arabic, for comparison | 12.1 to 17.8 | 1.9 to 2.4 |

Colors and styles did not change the cost of a draw beyond noise (well inside the 2x budget). Not measured: footprint with
the four font faces and the larger glyph keys (slice 4), selection drag redraw, scrolling a large scrollback.

## Follow-ups baseline (2026-11-14, before any follow-up change)

Harness: `test "bench: painter-only frame costs (HARF_BENCH=1)"` in `src/draw.zig`. It is skipped unless `HARF_BENCH=1` is set.
Reproduce: `HARF_BENCH=1 .tools/zig/zig build test -Dtest-filter=bench -Doptimize=ReleaseFast` (Zig caches test runs by inputs, so
change the filter text, for example `bench:`, to force a re-run). Painter only: a 28 px `CGBitmapContext`, no AppKit layer or
compositing, so these are not end-to-end numbers. Mean of 300 frames after 10 warm-up frames. 80x24, every cell inked (1920
glyph calls on the plain screen). Apple M1, macOS 27.0.1, Zig 0.17.1, ReleaseFast, commit 716dfb9.

| What | µs (3 runs) |
|---|---|
| Plain full frame (`drawRows` 0..23) | 1729, 1695, 1696 |
| Plain one row (`drawRows` 5..5) | 74, 74, 73 |
| Colored plain full frame (color change every row) | 1763, 1740, 1745 |
| Arabic shaped, layouts cached, full frame | 1104, 1089, 1090 |
| Arabic shaped, cold (cache cleared each frame) | 6139, 6157, 6169 |

This matches the numbers in `docs/superpowers/plans/2026-11-14-slice3-review-and-perf-followups.md` (plain frame 1716, one row 71).

### Measured and not worth doing (plan item P5)

From the plan's earlier throwaway measurements on the same screen: `gather` for all 24 rows (about 8 C calls per cell) takes 44 µs,
`selectRow` x24 and `update` under 1 µs each, and `rowfacts.analyze` x24 rows 17 µs, against a 1.7 ms frame. Per-cell FFI and
row iteration and an ASCII fast exit in `rowfacts` therefore buy about 1 to 3 percent and are not implemented. If `gather` ever
matters, `ghostty_render_state_row_cells_get_multi` is the tool. Do not change `bidi.classOf` (ASCII digits are class `EN`).

### P1: batched glyph draws (2026-11-14)

Change: a row's glyphs go out in one `CTFontDrawGlyphs` call per run of the same font and color (plain path), and the same
for unscaled shaped-row glyphs that sit on a whole pixel. Same harness and machine as the baseline above (mean of 300 frames,
ReleaseFast, three runs after the change). The old per-glyph routines stay as `Painter.reference_draw`, which the parity tests
use; they check that the two outputs are identical byte for byte on a screen mixing Latin, fallback-font glyphs, a wide cell,
bold, italic, faint, invisible cells, color changes, combining marks, underline, strike, a shaped Arabic row (including a
colored and a bold one) and a box row.

| What | Before (µs) | After (µs) |
|---|---|---|
| Plain full frame | 1729, 1695, 1696 | 507, 500, 505 |
| Plain one row | 74, 74, 73 | 19.8, 19.9, 19.9 |
| Colored plain full frame | 1763, 1740, 1745 | 510, 509, 510 |
| Arabic shaped, cached | 1104, 1089, 1090 | 968, 968, 966 |
| Arabic shaped, cold | 6139, 6157, 6169 | 6037, 6045, 6023 |

Plain full frame is about 3.4 times faster (target: at most 700). The Arabic cached frame improves about 11 percent and the
cold frame about 2 percent: most glyphs of a justified Arabic word sit on fractional pixel positions and are not batched.

**Why fractional positions are not batched.** Drawing every shaped glyph through a batch produced 93 to 155 differing bytes
per small screen. Drawing the same glyphs one at a time through a translation was exact, and so was the plain path (its
glyphs sit at `col * cell_w`, whole pixels). CoreGraphics snaps the positions of a batched call to whole pixels but honors a
translation. So the rule is exact: batch only glyphs at whole-pixel positions, draw the rest as before.

Correction (found while doing R5): `macos/build-app.sh` did not relink the app when only the Zig library changed, so the first
"pictures byte-identical" check for P1 ran against a stale binary. `build-app.sh` now deletes the linked product so it always
relinks. Rechecked with a true build: the `docs/slice3` colors and selection-latin pictures and the three `docs/phase4`
pictures are byte-identical with P1 in the binary, and `Harf --selftest` prints `selftest ok`. In the app the colored plain
80x24 screen now draws in 1.4 ms cold and 0.6 ms on the second draw (it read 2.7 and 1.8 ms on the stale binary), which
includes AppKit's bitmap path.

### P2: synchronized output, idle check (2026-11-14)

After the render-hold change, `Harf` launched directly, window open, no output, 30 s sampled every 2 s: idle CPU mean 0.01
percent, max 0.10 percent, cumulative CPU time 0:00.21 to 0:00.22 (0.01 s over 30 s). The Phase 0 level is 0.01 percent mean.
`phys_footprint` read 40 MB at 5 s and 38 MB at 35 s with the default window; that is not the defined measurement (12 to 20 s
after launch at 700x420 pt) and is the slice 4 question, but it is above the 30 MB target and worth knowing now.
`bench/idle.sh` now starts the binary itself and tracks that pid (it used `pgrep -x | head -1` and `kill`, which could end a
different running copy of the app).

**Deadline (decided 2026-11-14, option b).** A hold now ends at the latest 1 s (`Options.hold_deadline_ms`) after it began, so a
program that never resets mode 2026 cannot freeze the display. The I/O thread's `poll` takes a timeout only while a hold is open
(the time left to the deadline, one wait, no ticking); with no hold it still waits forever. Idle check after the change, window
open, no output, 30 s: mean 0.02 percent, max 0.30 percent, cumulative CPU 0:00.15 to 0:00.16 (0.01 s), the Phase 0 level.
Mutation-checked: removing the line that clears the flag fails the deadline test. A program that sets mode 2026 again without
having reset it, after a timeout, is not held for that frame (the library treats a second set as a no-op and reports no new hold);
a program that resets and sets it again is held again (tested).

### P3: dirty rows (2026-11-14)

I first closed this as not worth building (a full frame was 0.5 ms, the saving about 0.4 percent of a core); the owner asked for it
anyway, so it is built. **Design.** The painter keeps a hash per visible row of everything that row's drawing depends on (its
cells with styles and selection flags, and the cursor with the focus flag if it sits on the row), plus a frame key (grid size,
default colors, cell size). `dirtyRows` (C: `harf_term_dirty_rows`) compares the current hashes with those of the last draw
and answers which rows to redraw, adding the row above each changed row, because a glyph can reach up into its neighbor. The view
invalidates one rectangle per run of rows; `draw` repaints exactly the rectangles AppKit hands it, and the core also draws the
row below the region (clipped away by the context, not recorded as drawn) for the same reason. Hazards from the plan are
covered by the hash, not enumerated in code: focus, selection, viewport scroll, alternate screen and style-only changes change
a row's cells or the cursor entry; colors change the frame key; a resize or a new backing scale invalidates the whole view
(`layoutChanged`) and changes the key. A hidden cursor is not part of the row. Where the scale makes row edges fall off whole
device pixels the view falls back to full invalidation; `HARF_FULL_REDRAW=1` forces it everywhere.

**Proof.** `src/draw.zig` runs the view's protocol (clip to the region, fill, `drawRegion`) into a bitmap that keeps earlier frames and
compares it with a second painter's full redraw after every step of: first frame, no change, typing, cursor moves and
hiding and shapes, focus, selections (single, double-click, cleared), 40 lines of scrolling and scrolling through history, style-only
changes, OSC 4/10/11, alternate screen in and out, resizes, shaped Arabic rows with marks, wide and combining cells, and a
150-step seeded random script. Mutation-checked (each makes a named test fail): hash ignoring selection, focus, fg, style flags or
the cursor; frame key ignoring the default background; no row-above expansion and no overhang row (both caught by the random
script, which shows that glyphs of one row really do reach into the row above). Self-test 1k does the same through the view
(real `draw`, real wake path, 120 typed steps with Latin, Arabic, wide, accents and Return); it fails if the rows are
computed off by one or the rectangle starts a row late.

**Numbers** (painter only, ReleaseFast, M1, `HARF_BENCH=1`, three runs):

| What | Before | After |
|---|---|---|
| One typed character: find what changed and draw it | 487 to 540 µs (full frame) | 132, 132, 132 µs (73 µs finding, the rest drawing 3 rows) |
| A wake with nothing changed | a full frame | 73 µs, and nothing is invalidated |
| Keypress to draw, in process (self-test 1h, 200 keys) | median 3.94, 3.92, 3.95 ms | median 1.87, 2.23, 2.32 ms |
| Idle CPU (30 s) | 0.02 percent mean | 0.02 percent mean |

The finding cost (gather and hash of 24 rows) is the part to cut if it ever matters: the library's own per-row dirty flags could
skip rows, at the price of tracking the cursor, focus and selection ourselves. **Not verified by a machine:** that AppKit keeps the
pixels of the rows it did not ask for between partial draws. The spike on this machine shows it asks for exactly the invalidated
rectangle (`getRectsBeingDrawn` returned one rect, the rows' own); the view is layer-backed (`NSViewBackingLayer`); a screenshot
cannot be taken from this session (screen capture is not permitted). It is on the owner's checklist.

### P4 gate: does drawing slow the parsing of a flood? (2026-11-14)

Harness: `test "bench: flood parse throughput ..."` in `src/capi.zig`, skipped unless `HARF_BENCH=1`
(`HARF_BENCH=1 .tools/zig/zig build test -Dtest-filter='bench: flood parse' -Doptimize=ReleaseFast`, about 1 minute). A child runs
`seq 1 3000000` (about 22 MB of output); the time until it has exited and all output is parsed is measured, alone and with a
second thread drawing the whole 80x24 screen through `harf_term_draw` every 8 ms (about 100 frames per second, more than the
app draws: it draws at most once per display refresh). ReleaseFast, Apple M1, macOS 27.0.1, commit after P1.

| Run | No drawing | Drawing at about 100 fps | Slowdown |
|---|---|---|---|
| 1 | 7.82 s | 8.86 s (873 frames) | 1.13x |
| 2 | 8.50 s | 9.04 s (900 frames) | 1.06x |
| 3 | 8.06 s | 8.43 s (841 frames) | 1.05x |

**Result: not meaningful (5 to 13 percent), so P4 (two-phase render-state lock) is closed as not needed.**

**Correction (2026-11-17):** this gate drew on a fixed 8 ms clock, at 80x24. The app does not: it rescans every visible row on every wake,
so under a flood the scan, not the draw, is what holds the lock. See "Flood throughput through the real app" at the end of this file.

Two other findings:
- A first attempt drew back to back with no gap between frames and the flood did not finish in over five minutes (the drawing
  thread kept re-taking `term_lock` before the parser thread could). That is not a load the app produces, because redraws are
  coalesced to one per wake, but it shows the mutex is unfair. If a future feature draws in a tight loop, revisit P4.
- The flood itself runs at only about 3 MB/s end to end in this harness (a 22 MB `seq` in 8 s). That is far below the
  186 to 448 MB/s the Phase 3 spike measured for parsing alone, so the limit is elsewhere (the child writing through the pty,
  the 64 KiB read size, or the per-wake path). It is a slice 4 (`vtebench`) question, not a P4 one.

## Slice 4 baseline (2026-11-14)

Method: `bench/footprint.sh [settle=15] [mode]`: starts `macos/.build/Harf.app/Contents/MacOS/Harf` itself with
`HARF_CONTENT_SIZE=700x420`, tracks that pid, waits for the child to finish (modes that print first), settles 15 s, reads
`footprint <pid>`, and kills only its own process. Release build (`macos/build-app.sh`, which always relinks), Apple M1,
macOS 27.0.1, Zig 0.17.1, commit c0fc58f plus the script. Target: 30 MB `phys_footprint` at 700x420 pt, empty session.

| State | Footprint (3 runs) | Malloc Small | IOSurface | IOAccelerator (graphics) |
|---|---|---|---|---|
| Settled, empty session, at the prompt | 28, 28, 27 MB | 13 MB | 4976 KB (one surface) | 1.3 MB |
| After printing 6000 lines (1 MiB scrollback full) | 34, 32, 32 MB | 13, 11, 11 MB | 4976 KB once, then 9952 KB (two surfaces) | about 1.3 MB |
| After printing 100 MB, then settled | 32, 32, 31 MB | 11 MB | 9952 KB (two surfaces) | 1.3 MB |

- **The empty settled state is under the 30 MB target** (27 to 28 MB), with margin of 2 to 3 MB.
- **Every state where the view has been redrawn is 2 to 6 MB higher, and most of that is a second `IOSurface`** (9.95 MB instead
  of 4.98 MB: two 1400x904 BGRA surfaces, the window's backing store plus a second drawable). This is the spike's unexplained extra
  surface. It appears once content changes and redraws, not at an idle empty prompt. Task 1 attributes it.
- `Malloc Small` is the largest single line (11 to 13 MB) in every state. It is lower after a flood (11 MB) than at idle (13 MB),
  so most of it is fixed startup state (fonts, frameworks, Swift runtime), not data that grows.
- The ad hoc readings of 38 to 40 MB quoted earlier in `docs/perf.md` were taken 5 s after launch on a stale build (before
  `build-app.sh` relinked) and are superseded by this table.
- A 100 MB `yes | head -c` flood finishes in about 4 s through the real app (about 25 MB/s end to end including drawing).
  The 3 MB/s of the Zig flood benchmark is mostly `seq` itself (it writes one line at a time); Task 3 separates the two.

## Slice 4: where the memory goes (attribution, 2026-11-14)

Experiment: one temporary env-var knob per candidate setting on the window or view (not committed), each run through
`bench/footprint.sh 15 scrollback` (the state that shows the second surface), one run per knob, same machine and build.

| Knob | Footprint | IOSurface | Verdict |
|---|---|---|---|
| none (current) | 31 MB | 9952 KB (two surfaces) | baseline |
| `window.colorSpace = .sRGB` | **26 MB** | **4976 KB (one surface)** | **this is the cause** |
| `window.isOpaque = true` with an opaque background | 32 MB | 9952 KB | no effect |
| `view.wantsLayer = false` | 32 MB | 9952 KB | no effect |
| `view.wantsLayer = true` | 32 MB | 9952 KB | no effect |
| `layerContentsRedrawPolicy = .onSetNeedsDisplay` | 31 MB | 9952 KB | no effect |
| `layerContentsRedrawPolicy = .beforeViewResize` | 32 MB | 9952 KB | no effect |
| `layer.contentsFormat = .RGBA8Uint` | 31 MB | 9952 KB | no effect |
| `window.allowsConcurrentViewDrawing = false` | 32 MB | 9952 KB | no effect |
| `layer.isOpaque = true` | 32 MB | 9952 KB | no effect |
| `layer.contentsScale = 1` | 32 MB | 9952 KB | no effect |

The window's default color space (the display's wide-gamut profile) makes AppKit keep two 1400x904 BGRA surfaces once the view
has been redrawn; with an sRGB window there is one. The spike's unexplained extra surface (9.2 MB against 5 MB in the throwaway
prototype) is this: the prototype never redrew, and the spike did. No other setting tried changes it.

**`Malloc Small` (11 to 13 MB in every state).** `heap -s` at the settled prompt: 60,201 allocations, 8.7 MB in malloc zones,
of which 4.95 MB is "non-object" blocks averaging 157 bytes and the rest is framework state (Objective-C method caches 0.45 MB,
`NSMutableDictionary` storage 0.35 MB, `CFString` 0.28 MB, Swift metadata 0.26 MB, CoreSVG attributes, Metal resource lists).
Zig's allocator maps pages directly, so the terminal, render state, painter caches and glyph cache are not in these zones;
the whole process is only about 2 to 3 MB above the empty CPU-drawn prototype (25 MB at the same window size). Nothing in
`Malloc Small` is Harf state that can be trimmed; it is AppKit.

**Ranked candidates.** 1. sRGB window color space: about 5 MB once the view has redrawn. 2. Nothing else is above the 2 MB
threshold the plan set for a fix.

## Slice 4: footprint after the fix (2026-11-14)

Change: `window.colorSpace = .sRGB` in `AppDelegate` (the attribution above). Same method, build and machine as the slice 4
baseline; three runs per state.

| State | Before (3 runs) | After (3 runs) | IOSurface after |
|---|---|---|---|
| Settled, empty session | 28, 28, 27 MB | **25, 25, 25 MB** | 4976 KB |
| After printing 6000 lines (1 MiB scrollback full) | 34, 32, 32 MB | **26, 26, 26 MB** | 4976 KB |
| After printing 100 MB, then settled | 32, 32, 31 MB | **26, 26, 26 MB** | 4976 KB |

**The 30 MB target holds in every state with about 4 MB of margin** (run-to-run spread under 1 MB). The self-test section
`HARF_MEASURE=1` also checks that a 100 MB flood through a session leaves `phys_footprint` within 2 MB of before: it read
48.0 MB before, 48.6 MB with the flooded session open, 47.6 MB after closing it (the self-test process is larger than the app
because it holds many sessions); no growth. What changes for the eye: the window is now an sRGB window, so colors are
interpreted as sRGB (what the theme and the ANSI palette are defined in) instead of in the display's wide-gamut space; the
`docs/slice3` and `docs/phase4` pictures, which are rendered into a bitmap, regenerate byte-identical.

## Slice 4: throughput (2026-11-14)

**Question.** Is the 3 MB/s the Zig flood benchmark showed (a 22 MB `seq`) a Harf problem?

**Answer: no. It is the PTY, and the child's write pattern.** The same commands through a bare reader (Python `pty`: `os.read(fd, 65536)`
in a loop, no parsing at all) versus through Harf's `Session` (no drawing), ReleaseFast, Apple M1, macOS 27.0.1, one run each. Every rate
in this table is bytes of output divided by seconds, MB = 10^6 bytes (the `seq` load is 22.9 MB, the others 100 MB), so a row's rate can be
checked from its time:

| Load | Bare reader | Harf `Session` | Bytes per `read` (bare) |
|---|---|---|---|
| `seq 1 3000000` (22.9 MB, a line per write) | 7.54 s, 3.0 MB/s | 7.59 s, 3.0 MB/s | 13 |
| `yes \| head -c 100MB` (full lines) | 3.10 s, 32 MB/s | 3.07 s, 33 MB/s | 99 |
| `head -c 100MB /dev/zero \| tr` (no newlines) | 6.59 s, 15 MB/s | 8.15 s, 12 MB/s | 1023 |
| `yes \| head -c 100MB \| cat` (large block writes) | 0.71 s, 141 MB/s | 0.99 s, 101 MB/s | 1023 |

- A terminal that parses nothing is exactly as slow on the first two rows, so those loads are limited by the child's writes
  through the PTY (a tty is line-buffered: `seq` makes 2.5 million writes). On large block writes the PTY delivers about 1 KB
  per `read` on macOS whatever the writer does, and a bare reader tops out near 140 MB/s.
- Harf's time against the bare reader, row by row: 1.01x, 0.99x (both inside run-to-run noise), 1.24x and 1.39x. Only the last two
  show a cost (parsing, one lock and one wake per read), and the last is the 100 MB/s class of load where it is largest; one run each,
  so the ratios carry the spread of the same-session pairs in the "tried and dropped" note below (up to about 8 percent).
- A real 100 MB `yes | head -c` flood through the full app (window drawing) took about 4 s.

**Tried and dropped: draining the PTY before locking.** Reading everything available (up to 64 KB) before taking the lock once
did not move the numbers beyond run-to-run noise (same session: 8.30 vs 8.99 s, 3.40 vs 3.45 s, 8.56 vs 9.15 s, 1.28 vs 1.19 s;
the machine itself varied by 20 percent between sessions). By the rule that a fix must beat its spread it was reverted.

**`vtebench` 0.3.1** (built from source in the scratchpad), run inside the app at 80x24 with `--max-secs 4 --max-samples 20`,
window drawing, 20 samples each; time per sample (each sample is at least 1 MiB of output):

| Benchmark | Mean | Median | p90 |
|---|---|---|---|
| dense_cells | 18.4 ms | 18 | 23 |
| medium_cells | 19.3 ms | 18 | 24 |
| sync_medium_cells | 18.3 ms | 18 | 24 |
| unicode | 10.1 ms | 10 | 16 |
| scrolling | 37.0 ms | 35 | 46 |
| scrolling_bottom_region | 37.5 ms | 36 | 47 |
| scrolling_bottom_small_region | 37.6 ms | 37 | 44 |
| scrolling_top_region | 39.9 ms | 38 | 50 |
| scrolling_top_small_region | 38.5 ms | 38 | 47 |
| scrolling_fullscreen | 49.5 ms | 47 | 62 |

These are absolute numbers; no other terminal was run on this machine, so there is no comparison and **"competitive" is neither
shown nor refuted** (comparing needs the other terminals installed and is done only if the owner asks). For scale, one sample of at
least 1 MiB in about 18 to 50 ms is 20 to 55 MiB/s (21 to 58 MB/s) end to end including drawing, against 186 to 448 MB/s for
parsing alone in the Phase 3 spike.

## Slice 4: latency, startup and idle against the budgets (2026-11-14)

Release build (`macos/build-app.sh`), Apple M1, macOS 27.0.1, 700x420 pt window, warm file cache, commit after `8c1d22f`.

### Keypress to pixel: budget under 10 ms

`HARF_MEASURE=1 macos/.build/Harf.app/Contents/MacOS/Harf --selftest` (section 1h) types 200 letters at an idle `cat` prompt through
`TerminalView.handleKey` (the code every key reaches after AppKit decodes the event). Each keystroke is timed from just before
that call until the frame that shows the echo has finished (`measureFrameEnd`, set at the end of `TerminalController.draw`).
**The path is the product's:** the check waits for the wake path (`wakeOnMain` -> `markDirty`) to mark the view dirty, and fails
if it never does (an earlier version of this check read the grid directly and would have passed with that line deleted; fixed
after review, and mutation-checked: removing the mark makes the self-test fail).

| Run | Median | p95 | Max |
|---|---|---|---|
| 1 | 3.94 ms | 4.80 ms | 6.09 ms |
| 2 | 3.92 ms | 4.84 ms | 6.62 ms |
| 3 | 3.95 ms | 4.72 ms | 6.14 ms |

(The first version of this check, which skipped the wake hop, read 4.73 / 5.52 / 6.48 ms; a re-run during review read 5.84 / 7.84 / 12.87.
Latency varies by a few ms with machine load.)

What the number includes: handing the key to the core, the PTY round trip and the child's echo, parsing, the wake and the hop to
the main thread, and a full-frame draw (the draw is triggered by the check itself, standing in for the display link, because an
off-screen window gets no display ticks). It leaves out the wait for the display's next refresh (up to one frame, about 8 ms on
average at 60 Hz) and the compositor. **Whether the budget "under 10 ms keypress to pixel" holds is therefore not decided by
this number:** about 4 ms in process plus about 8 ms of average refresh wait is about 12 ms at 60 Hz, over 10 ms; the budget needs
a definition (in process, or to the display) before it can be called met. Not measured: the same during a flood, and real
`NSEvent` delivery (`keyDown` goes through `interpretKeyEvents`, which needs an active window).

### Startup: budget under 100 ms to the first usable frame

`bench/startup.sh 10` (own pid, `HARF_TRACE=startup`): process start (kernel `p_starttime`) to the end of the first frame.

| Run | ms |
|---|---|
| first launch after a rebuild | 1179 |
| the next nine, sorted | 118, 121, 121, 122, 122, 123, 123, 128, 128 (median 122) |

Where the time goes, from one traced launch (`HARF_TRACE=startup` prints each step; about 155 ms with the extra printing):
17 ms to `main()`, 50 ms in `NSApplication.shared`, 35 ms to `applicationDidFinishLaunching`, 7 ms to create the core, painter and
shell, 27 ms to build the window, 16 ms to the first frame. Harf's own work is about 50 ms of that.

**The floor.** A minimal AppKit app (one window, one empty view, nothing else) built the same way reaches its first frame in
**123 to 139 ms, median 131 ms** on this machine. Harf (118 to 128 ms) is at that floor, not above it. **The 100 ms budget is
below what any AppKit window reaches here**, so it cannot be met by changes to Harf; it needs an owner decision (for example
"within 10 percent of an empty AppKit window", or a budget measured to a different moment). Not measured: a cold file cache
(needs `sudo purge`).

### Idle: budget about 0

`bench/idle.sh macos/.build/Harf.app 60`: window open at the prompt, 60 s sampled every 2 s: mean **0.01 percent**, max
0.20 percent, cumulative CPU time 0:00.15 to 0:00.16 (0.01 s in 60 s). `phys_footprint` 22 MB.

That 22 MB is 3 MB below the 25 MB settled figure in the footprint table above. They are different runs at different times (idle.sh
reads the footprint at the end of its sampling, after about a minute; footprint.sh at 12 to 20 s), and I did not find what accounts for
the gap. The section below shows this machine's footprint moving by about 10 MB with graphics state alone, so a 3 MB difference between
two runs is inside that, and neither number should be quoted without its state.

### Footprint depends on the machine's graphics state (found in review, 2026-11-14)

The slice 4 footprint table above (25 to 26 MB in every state, nine runs) was taken in one machine state. Later the **same
binary** read much higher: the previous commit's build (`47c559f`), measured again the same hour, gave 26, 26 in a first pair and
then 29, 37, 37, 37, 37 MB (settled, 12 to 15 s); the working tree gave 36, 39, 39, 39, 32, 39 MB. In the high state the
`footprint` breakdown differs from the low state in two lines only: "Owned physical footprint (unmapped)" is about 5 MB (the size
of one window surface) and `IOAccelerator (graphics)` is 3.9 MB instead of 1.3 MB; `IOSurface` stays one 4976 KB surface and
`Malloc Small` is unchanged. A **4K external display is online** in the high state (`system_profiler SPDisplaysDataType`); I did
not record whether it was connected during the low-state runs, so this is a hypothesis, not a finding. Consequences:

- The footprint of a window app on this machine moves by about 10 MB with graphics state outside Harf's code. "Met" for the 30 MB
  target is true in the state I measured it and not true in the other.
- The sRGB window color space still matters in the high state: with it removed the scrollback-full state read 40 MB, with it 30 MB.
- `bench/footprint.sh` now exits 1 above 30 MB (`MAX_MB` to change), so a change can be checked; it also prints the breakdown, so the
  state can be read off each run. Open: repeat the measurement with and without the external display, and decide what the
  target means when graphics accounting alone can move it by 10 MB.

## Flood throughput through the real app (2026-11-17)

Prompted by a review of PR #2 (a benchmark and profile taken on another machine, macOS 15.6.1, chip and window size not recorded). I
checked its claim on this machine, then fixed it. Apple M1, macOS 27.0.1, Release builds of commit 4be6dd6 (before) and the same plus
the throttle below (after). The load is `seq 1 2000000` as the app's child (`bench/profile-seq.sh`); the floor is a bare Python `pty`
reader running the same `seq` (no parsing, no drawing; the method of "Slice 4: throughput" above).

**Two things decide whether a number here means anything.**
- `sample` suspends the app's threads every millisecond, so a flood being profiled takes 15 to 40 percent longer. Flood times below are
  unsampled (`SAMPLE_SECONDS=0`) unless marked; the shares of time come from sampled runs of the same builds.
- The machine's speed moved during the evening (the bare reader took 2.96 to 5.44 s for the same `seq`). So every ratio is within one set: a
  floor run before and after each Harf run, before and after builds interleaved, three rounds.

**Correction.** The first version of this section (commit 43f86f7) reported 1.4 to 1.7 times the floor at 80x24 and 2.4 to 2.5 at the
default window. Those flood times were taken while `sample` was running and overstated the cost, most at 80x24. The PR's own unsampled
figures (`seq` 3.13 s against Terminal.app's 2.50 s) were closer to the truth than mine.

### Result of the throttle (same set, unsampled, three rounds)

| Window | Grid | Bare reader (s) | Before (s) | After (s) | App CPU before / after (s) |
|---|---|---|---|---|---|
| `HARF_CONTENT_SIZE=700x420` | 80x24 (1920 cells) | 3.64 to 3.87 | 4.20, 4.33, 4.37 (1.12 to 1.14x) | 3.82, 3.89, 3.91 (1.00 to 1.02x) | 4.7 to 4.8 / 3.3 to 3.4 |
| default 1000x720 | 139x42 (5838 cells) | 3.71 to 3.94 | 7.55, 7.76, 7.96 (1.97 to 2.04x) | 4.00, 4.07, 4.08 (1.02 to 1.05x) | 8.0 to 8.4 / 3.5 to 3.6 |

Ratios are against the mean of the two floor runs on either side. The gate set before building it (full app within about 8 percent of the floor at
both sizes, scan under 5 percent of the main thread) is met. Shares from sampled runs at 80x24, three runs each:

| | Main thread in `invalidateChangedRows` | Parser thread waiting on the session lock |
|---|---|---|
| Before | 68, 67, 67 percent | 72, 72, 73 percent |
| After | 2, 7, 4 percent | 4, 10, 6 percent |

Not measured after the change, because the console was locked and no window would open: the scan share at the default window, and `cat`
(below).

### What the profile showed before

- **The PR's profile reproduces.** The main thread was in `TerminalController.invalidateChangedRows` -> `harf_term_dirty_rows`, which holds the
  session lock while it gathers and hashes every visible row; the PR saw 75 percent, this machine 44 to 68 percent across runs. Inside the scan's
  call subtree: `gather` 34 to 48 percent, `rowHash` 40 to 51 percent, of which `Wyhash.update` 31 to 40 percent. (The draw path also gathers and
  hashes the rows it draws; these counts are only the scan's subtree.)
- **Why it was a loop.** `wakeOnMain` re-arms the wake (`harf_term_wake_handled`) before it scans, so during a flood the I/O thread woke the main
  thread again after every read and `lock, scan every row, unlock` ran back to back. Its rate was bounded by its own cost, not by the display
  refresh; only the draw is coalesced by AppKit. The P4 note above predicted this ("if a future feature draws in a tight loop"), and the P4 gate did
  not model it: it drew on a fixed 8 ms clock at 80x24, while the default window is now 139x42 (config `window_width`/`window_height`, a78bba1).
- **The cost grew with the grid** (unsampled, before): about 0.5 s over the floor at 80x24, 3.7 to 4.1 s at 139x42, for 3.0 times the cells. The PR said the
  gap grows with window size without testing it; this confirms it.
- **Block writes were hit hardest** (`bench/bench.sh Harf` run as the app's own child at the default window, before the change, one session, three
  runs). `cat` of a 50 MB text file took 10.62, 8.29, 11.54 s; a bare reader takes 0.23, 0.27, 0.29 s for the same file (50,300 reads of about
  1 KB). The scan ran once per 1 KB read, and 50,300 scans at about 0.2 ms (38 ns per cell from P3, times 5838 cells) is about 10 s. That is
  arithmetic from P3's per-cell cost, not a measurement, but it matches. That session was in the machine's slower state (its `seq` took 12.7 s,
  against 7.7 s unsampled in the A/B above), so quote the order of magnitude, not the multiple. The after-change `cat` time is under "Follow-up" below.
- **Footprint at the default window** (same bench.sh run, before the change): 37 MB idle, 88 MB after the loads, 59 MB after `clear` and 22 s. The PR
  saw 47, 77 and 65 MB, so its growth is real at this window size. The slice 4 table above recorded a flat 26 MB after a 100 MB flood at 700x420.
  The attribution is under "Follow-up" below: the growth is transient window backing store (IOSurface), not scrollback and not a leak.

Not established by the PR: its Terminal.app comparison (a single run with an unrecorded window size, against a Terminal.app that was already running;
a fresh-instance run is under "Follow-up" below) and "colour parsing is not the bottleneck" (its colour test was a zsh loop, 0.07 s).

### The change

`wakeOnMain` (`TerminalView.swift`) scans at most once per `scanInterval` (1/120 s). The first wake after a quiet moment scans at once; a wake that follows
a scan by less than the interval waits out the rest of it with a one-shot timer. The wake stays armed until the scan re-arms it, so no further wakes
arrive while one waits, and idle costs nothing. Skipping a scan is safe because `dirtyRows` compares with the hash recorded at the last draw, not the last
scan. Cost: an echo during streaming output can wait up to one interval (about 8 ms) for its scan; at an idle prompt nothing changes.

- Self-test 1l (written first and watched failing): two wakes in one interval give one scan at once, one when the interval is over and none after;
  a 300,000-line flood stays within one scan per interval (before: 35,062 scans in 1.28 s; after: 61 in 0.89 s) and nothing runs once it stops.
- Keypress to draw (`HARF_MEASURE=1 Harf --selftest`, section 1h), after: median 2.11, 1.90, 1.96 ms, p95 about 3.1 ms; the dirty-rows work above
  recorded 1.87 to 2.32 ms. Unchanged, as expected, because the first wake after a quiet moment is not delayed.
- `Harf --selftest`: ok (23 s before, 26 s after). `zig build test`: 279 of 282 tests passed, 3 skipped (the `HARF_BENCH` ones); the Zig sources are unchanged.
- **A flaky check that was not this change, now fixed:** with `HARF_MEASURE=1`, the pane-focus section ("the pane that lost the keyboard did not hear
  focus out after focus in") failed in some runs, 3 of 8 with the throttle and 3 of 8 without it. It is a test race, found by loading the machine
  (8 CPU-bound processes: it then failed 7 of 7 full runs; on an idle machine 0 of 8). The test waited for a row that contained `READY` and not
  `echo`, but the tty echoes the typed command before the shell has run it, and at a split pane's width the echo wraps inside the word `echo`, so the
  wait could end on the echo alone. The test then sent focus in and out before the program had asked for them (mode 1004), so the program heard
  nothing and `head -c 6` never finished. The app was right: a program that has not asked is not told. The wait now needs a row that is exactly
  `READY` (two tests had the same helper). After: 0 failures in 28 isolated runs under heavy load (the old wait failed 3 of 20 in the same setup).

### Follow-up (2026-11-18, same machine, one session, `macos/.build/Harf.app` at fe069a8 unless noted)

`bench/bench.sh` run as each app's own child (`open -n <bundle> --env HARF_CHILD_CMD=...`), default window (139x42), three runs, the median in
brackets. The bare PTY reader measured in the same ten minutes took 0.44 to 0.52 s for the `cat` file and 0.04 s for the colour file. These two runs
were made one after the other, not interleaved, so use the `cat` and colour rows (a factor of 10) and the CPU row, not small differences in `seq`.

| Load | Before the change | After the change | Bare reader |
|---|---|---|---|
| `cat` of a 50 MB file | 5.59, 5.58, 5.72 s (5.59) | 0.52, 0.51, 0.50 s (0.51) | 0.44 to 0.52 s |
| 200k colour lines from a file | 0.58, 0.58, 0.71 s (0.58) | 0.07, 0.07, 0.07 s (0.07) | 0.04 s |
| `seq 1 2000000` | 7.39, 6.02, 5.97 s (6.02) | 4.42, 5.17, 4.49 s (4.49) | 4.65 to 5.37 s, measured right after (3.9 s earlier) |
| app CPU, all nine loads | 41.15 s | 13.21 s | |

- **Block writes were the worst case and are fixed.** `cat` went from about 11 times the floor to about 1.0 to 1.1 times it; the throttled build at 80x24
  (the current build) gave 0.65, 0.55, 0.57 s. This session's `cat` before the change (5.6 s) is half of the earlier session's 10.6 s: the same code, a
  different machine state, which is why only same-set comparisons count. The floor of `seq` drifted from 3.9 to 5 s between sets for the same reason.
- **Scan share at the default window** (`bench/profile-seq.sh`, sampled, current build): `invalidateChangedRows` is 13, 11, 10 percent of the main
  thread's samples (76 of 570, 66 of 625, 63 of 627), against 2 to 7 percent at 80x24 before. The gate I set (under 5 percent) is met at 80x24 and not at
  the default window: a scan costs about 3 times as much with 3 times the cells, and the throttle bounds how often it runs, not what one costs. The
  flood itself is within the floor (table above), so this is a lower-order cost; it is what the dirty flags or the single-hash change in "Still open"
  would reduce, if it ever matters.
- **The post-flood memory growth is transient window backing store.** A 100 MB flood (`yes | head -c 100000000`) at the default window: 39 MB idle (60 MB
  in a second run; the startup state varies), 75 MB during the flood, 40 MB 15 s after, and 40 MB at 60 s. At the peak the `footprint` categories
  were: IOSurface 14 -> 42 MB (1 -> 3 surfaces), IOAccelerator (graphics) 1.3 -> 4.1 MB, Malloc Small flat at 14 MB. So it is not scrollback (capped at
  1 MiB per session) and not a leak. The `bench.sh` runs agree: loaded 70 MB before the change and 76 MB after, final 54 and 61 MB.
- **Terminal.app on this machine** (a fresh instance, `open -n -a Terminal` on a `.command` file, its default window 125x27, so a smaller grid than
  Harf's 139x42; the table compares the apps as they open):

  | | Terminal.app 125x27 | Harf 139x42 | Harf 80x24 |
  |---|---|---|---|
  | `seq 1 2000000` | 4.48, 4.45, 4.55 s | 4.42, 5.17, 4.49 s | 6.41, 5.30, 4.56 s |
  | `cat` of 50 MB | 2.21, 2.20, 2.20 s | 0.52, 0.51, 0.50 s | 0.65, 0.55, 0.57 s |
  | 200k colour lines | 0.30, 0.29, 0.29 s | 0.07 s | 0.06, 0.07, 0.07 s |
  | app CPU, all loads | 20.23 s | 13.21 s | 14.15 s |
  | footprint idle / loaded / final | 77 / 406 / 405 MB | 40 / 76 / 61 MB | 40 / 50 / 40 MB |

  Harf is about 4 times faster on `cat` and the colour file, equal on `seq` (the floor-bound case), and uses less CPU and much less memory under load
  (Terminal.app keeps its scrollback: 405 MB after the loads). The PR's "14 to 25 percent slower" no longer holds after the change. One session, one
  machine, and the Harf `seq` runs swung with the floor, so treat `seq` as a tie.
- One launch of the throttled bundle never ran its child (an instance was alive for ten minutes and wrote nothing); a probe and a retry of the same
  bundle ran normally. The cause was not found.

Still open: self-test sections 2c (Ctrl+C under kitty flags 5) and the shortcut checks fail while the active keyboard layout is not a Latin one
(with Arabic PC active, Ctrl+C reports the layout's key, `CSI 1572...`, which is what the kitty protocol asks for, and Cmd+N is not matched), so
`--selftest` passes only on a Latin layout. If the scan ever matters again at larger windows (it is 10 to 13 percent of the main thread at 139x42): the
library's per-row dirty flags (Harf would need to track the cursor, focus, selection and find matches itself; extend the `draw.zig` differential tests
first), or one `Wyhash` call per row instead of about seven per cell.
