# Project Brief: Harf — Arabic-first, Agent-friendly Terminal Emulator for macOS

> **Status: Implemented (v0.2.0).** Originally written as the pre-implementation handoff brief; updated to reflect shipped decisions, the actual repository layout, and remaining open items. See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the chronological decisions log.

---

## 1. Goal

Build a **terminal emulator** (not a TUI app that runs inside one) for **macOS on Apple Silicon** that is:

1. **Snappy and light**: low memory and CPU footprint, near-zero idle cost.
2. **Arabic-correct from day 1**: RTL, contextual shaping, and correct mixed Arabic/English (bidi) rendering, with cursor and selection that behave correctly.
3. **Pleasant for developers**, especially those running AI coding agents (Claude Code, Codex) in it.
4. **Open source** (MIT License).

Why an emulator: only an emulator owns the renderer, so only an emulator can fix Arabic shaping and bidi. A TUI app just emits text and the host terminal decides how it looks.

---

## 2. Locked decisions

| Area | Decision |
|---|---|
| Product | **Harf** — terminal emulator, macOS 14.0+ Apple Silicon only (v1) |
| Core language | **Zig** (pin an exact compiler version, see §10) |
| macOS shell | **Thin Swift/AppKit shell** (the way Ghostty is structured); Zig core exposes a small C ABI |
| Rendering | **CPU-drawn (CoreGraphics + CoreText) into a layer-backed AppKit view, damage-tracked, no web view, no Metal.** *Changed 2026-11-13 by the owner (was: Metal + glyph atlas) to reach a ~30 MB footprint. Measured at equal window size, a CPU-drawn view is 5-13 MB lighter than Metal (docs/perf.md). Note: Terminal.app itself is ~50 MB at its default window; an earlier 17 MB reading was wrong.* |
| Shaping and font fallback | **CoreText** (system fallback for Arabic; no bundled font in v1) |
| Bidi | Own UAX #9 implementation in Zig, validated against Unicode conformance files |
| Grid model | Grid stays in **logical order**; reordering happens at display time |
| Arabic | Must work from the first usable build, including mixed English/Arabic lines |
| License | MIT; no GPL/LGPL dependencies (uses `libghostty-vt` 1.0.1, MIT; FriBidi is LGPL, so not used) |
| Performance budgets | See §7 (defaults accepted, with one caveat on RSS) |

---

## 3. Architecture

```
PTY (child shell)
  -> VT parser (escape sequence state machine)
    -> Screen / grid (logical order, damage-tracked)
      -> Per-row layout:  bidi (UAX #9) -> shaping (CoreText) -> cluster-to-cell map
        -> Draw: Zig draws damaged rows into a CGContext handed across the C ABI (CoreText glyph runs, cell backgrounds, cursor, selection)
          -> Swift/AppKit shell: view + dirty-rect invalidation, window, tabs, menus, IME, notifications
             (2026-11-13: replaces glyph atlas + frame snapshot + Metal draw)
```

### 3.1 Zig / Swift split

- **Zig core** owns: PTY, parser, screen/scrollback, layout (bidi + shaping), drawing (CoreText/CoreGraphics into a CGContext), selection/cursor logic, config.
- **Swift shell** owns: windows, tabs/splits UI, menus, input events and IME (`NSTextInputClient`), the view and its dirty-rect invalidation, notifications, session restore.
- **C ABI** is small and stable: create/destroy terminal, write input, resize, draw rows into a CGContext, get selection text, callbacks for title/bell/notification/clipboard.
- CoreText and CoreGraphics have C APIs, so Zig calls them directly and draws into the CGContext Swift passes in. (2026-11-13: replaces "Metal is Obj-C/Swift only, so Swift draws".)
- Zig builds a static library plus a generated C header; the Swift package/Xcode project links it.

### 3.2 Threads

- I/O thread: PTY read, parse, mutate screen.
- Render side: takes a consistent snapshot (lock or double buffer), draws only damaged rows.
- No timers while idle. Cursor blink and animations only run while needed.

### 3.3 Fast path

Rows containing **no RTL code points** skip bidi and shaping entirely and take the plain-terminal path. Only rows with Arabic (or other RTL) pay the layout cost. Shaped rows are cached until they become dirty. Ordinary output must run at plain-terminal speed.

---

## 4. Arabic and bidi design

### 4.1 Requirements

- Contextual shaping (initial/medial/final/isolated forms), lam-alef ligature, tashkeel (combining marks) attached to the right base letter.
- Correct bidi for mixed lines: Arabic next to English, numbers, paths, punctuation, brackets (bracket mirroring and pairing per UAX #9).
- Isolates (LRI, RLI, FSI, PDI) and explicit embeddings/overrides handled per UAX #9.
- Arabic-Indic digits (`١٢٣`) and Western digits (`123`) both render correctly.
- Pre-shaped presentation-form code points (U+FB50 to U+FDFF, U+FE70 to U+FEFF) emitted by some apps are treated as ordinary characters.
- Grapheme clusters per UAX #29; cell widths per Unicode width data (Arabic letters are 1 cell; combining marks 0).

### 4.2 Logical grid, visual layout

Apps (shells, vim, tmux) write text in logical order at logical columns. The grid keeps that. At layout time each row gets a **logical to visual map** (and the inverse). Cursor drawing, selection rectangles, mouse hit-testing and copy all go through this map. Copy always produces logical-order text.

### 4.3 Cell model: the main technical risk

Terminals assume one fixed-width cell per cluster; Arabic joins and font advances do not. The spike (Phase 1) must compare at least:

- **A. Shape the whole run, then snap each cluster to its cell origin.** Grid-perfect, but joins can show gaps or overlaps if glyph advance differs from cell width.
- **B. Same as A, with per-glyph horizontal scaling/positioning to close joins.**
- **C. Shape with natural advances and snap only at run boundaries.** Best looking, but column math is harder.

Test with 3 to 4 system fonts. Decision criteria: join continuity, tashkeel placement, lam-alef, legibility at small sizes, cost per row. Document the winner and why in `docs/cell-model.md`.

### 4.4 Base direction policy (needs real design work)

Starting proposal (to be validated, not locked):

- Shell prompt and plain output: per-row base direction from first strong character (auto), with a config override (LTR / RTL / auto).
- Full-screen TUIs and layout-heavy output must **not mirror** boxes and padded layouts. A row like `│ مرحبا    │` reordered with an RTL base would jump text to the right edge and break the layout.

**Important correction to an earlier assumption:** Claude Code and Codex generally render **inline on the primary screen** using cursor positioning and box drawing, not on the alternate screen. So "alt screen means LTR" is not enough. Ideas to evaluate:

- Rows that contain box-drawing characters or were written with absolute cursor positioning get an LTR base (Arabic runs still reordered internally).
- Per-tab toggle plus per-app profile.
- Honor explicit sequences from the Terminal Working Group bidi spec (ECMA-48 BDSM/SPD and related private modes) if apps start emitting them. Read the spec and decide what to implement.
- Use OSC 133 to distinguish prompt/input regions from command output and apply different policies.

### 4.5 Cursor and typing

zsh and readline know nothing about bidi; they move the cursor in logical columns. In a line with an LTR base, an RTL run **grows and shifts as you type** (the first typed character moves as the run extends). This is expected behavior in implicit-mode bidi terminals, but it must feel acceptable. Phase 4 should prototype options, for example treating the OSC 133 input region as its own paragraph with direction chosen by first strong character. Study existing behavior before inventing.

Also decide here: what Left/Right mean inside an RTL run (visual vs logical direction) and where Option+Left/Right word jumps stop over Arabic text (see the editing keys in §5).

### 4.6 Conformance

- Implement UAX #9 in Zig and run **BidiTest.txt** and **BidiCharacterTest.txt** from unicode.org in CI. Download them in a build/test step with a pinned Unicode version, or vendor them if the license allows.
- Add golden tests for layout: input string -> visual order + logical/visual maps.

### 4.7 Sample strings for tests

```
مرحبا world 123
السلام عليكم ورحمة الله
مُحَمَّد                       (tashkeel)
لا إله إلا الله               (lam-alef)
ls ملف.txt                     (path with Arabic)
"النتيجة: ١٢٣ (ناجح)"          (Arabic-Indic digits + brackets)
echo "اختبار" | wc -c          (shell line)
│ مرحبا    │                   (box layout, must not mirror)
```

The product owner is an Arabic speaker and will judge visual quality. Prefer asking for screenshots/feedback over assuming a rendering is correct.

---

## 5. Agent-compatibility (v1, non-negotiable)

Claude Code and Codex stress terminals with streaming redraws, boxes, and rich input. v1 must support:

- **Synchronized output** (DEC private mode 2026): no flicker on redraw.
- **Damage tracking**: a token stream repaints a few rows, not the whole screen.
- **Bracketed paste**, **focus events**, **truecolor**, mouse reporting (SGR).
- **Kitty keyboard protocol** (so Shift+Enter inserts a newline, plus modifiers in general).
- **OSC 8** hyperlinks, **OSC 52** clipboard (with a permission setting), **OSC 9 / OSC 777** notifications.
- Common terminal queries and replies (DA1/DA2, DSR/cursor position report, OSC 10/11 color queries for theme detection, XTVERSION). Verify against what Claude Code and Codex actually send.
- **Editor-style line editing keys.** The terminal does not edit the line; the Swift shell maps these keys to bytes zsh/readline already understand:

  | Key | Sends |
  |---|---|
  | Option+Left / Right | `ESC b` / `ESC f` (word back / forward) |
  | Option+Backspace | `ESC DEL` (delete word back) |
  | Option+Delete (fn+Option+Backspace) | `ESC d` (delete word ahead) |
  | Cmd+Left / Right | `^A` / `^E` (line start / end) |
  | Cmd+Backspace | `^U` (delete to line start) |
  | Cmd+Delete (forward) | `^K` (delete to line end) |

  These are the defaults when the app has not enabled the kitty keyboard protocol; when it has, send the full modifier encoding instead. Option-as-Meta is a setting, since Option also types compose/Arabic characters. All bindings user-remappable.
- Underline styles/colors, cursor shape (DECSCUSR), wide characters and emoji widths.
- Correct **alternate screen** and **scrollback** behavior, plus resize reflow that does not corrupt inline UIs.

Test matrix: shell, vim/neovim, tmux, htop, less, fzf, **Claude Code**, **Codex CLI**, plus `vttest` and an escape-sequence conformance suite.

---

## 6. Developer UX

### v1 (shipped in v0.2.0, with noted gaps)

- **OSC 133 shell integration (zsh)**: jump between prompts (`Cmd+Up` / `Cmd+Down`), select last command output (`Cmd+Shift+A`), and completion notifications when a command >= 10 s finishes while unfocused. *(Not built: bash/fish shims, failed-command row marks.)*
- **Background completion notifications**: OSC 9 / OSC 777 and long-running OSC 133 commands notify when unfocused (`notifications = unfocused | always | off`). *(A tab-title running dot was tried and removed because long-lived programs like Claude Code, vim, and `tail -f` kept it permanently on; "waiting for input" is not built.)*
- **Cmd-click on `path:line:col` and URLs**: opens files in the configured editor (`editor` setting or **Harf → Choose Editor…**), plus plain URL auto-coloring and OSC 8 hyperlinks, with `Cmd+Hover` preview.
- **Tabs and splits** for parallel agent sessions (`Cmd+T`, `Cmd+D`, `Cmd+Shift+D`, starting in the focused pane's working directory). *(Session restore is not yet built.)*
- **Scrollback search** (`Cmd+F`, ASCII case-insensitive via `libghostty-vt`; highlights all visible matches). *(Bidi-aware visual-position highlighting is still basic/grid-based.)*
- **Large-paste guard** (`paste_guard = on`): confirms pastes over 100,000 bytes, or multi-line pastes when bracketed paste is off.
- **Finder & folder integration**: drop files from Finder onto a terminal to type their shell-quoted paths; open folders via `open -a Harf <dir>`, CLI arguments, or Finder Services (**New Harf at Folder** / **New Harf Tab at Folder**).
- **Default shortcuts** (all remappable via `keybind`; editing keys are in §5):
  - `Cmd+Up` / `Down`: jump to previous / next prompt (OSC 133 marks).
  - `Cmd+K` clear screen & scrollback, `Ctrl+L` clear visible screen, `Cmd+F` find, `Cmd+C` / `V` copy and paste.
  - `Cmd+A` select all; `Cmd+Shift+Left/Right` and `Option+Shift+Left/Right` select from the cursor to the line edge / word by word; `Cmd+Z` undo at the prompt (`^_`).
  - `Cmd+T` / `W` new / close tab or pane, `Cmd+D` / `Cmd+Shift+D` split, `Cmd+1..9` switch tab.
  - `Cmd+Click` opens OSC 8 hyperlinks, plain URLs, and `path:line:col`.
  - Not yet built: `Option+Click` at prompt (send arrow keys).
- Plain-text config (`~/.config/harf/config`), hot reload of config and themes, light/dark themes + system appearance tracking.

### v2 (parked, needs a permission model)

- Local control socket + CLI so an agent can read a pane, send keys, create panes. Powerful but security-sensitive: design permissions first.

---

## 7. Performance budgets

| Metric | Target |
|---|---|
| Idle CPU | ~0% (no timers, no redraw when idle) |
| Keypress to pixel | under 10 ms |
| Startup | under 100 ms to first usable frame |
| Idle RSS | under 30 MB (see caveat) |
| Throughput | competitive with other GPU terminals on vtebench-style workloads |
| Scrollback | configurable; compact row storage; default sized to the memory budget |

**Caveat on RSS:** AppKit + Metal themselves may exceed 30 MB. In Phase 0, measure an empty AppKit + Metal window first, then confirm or revise the target relative to that baseline and record it in `docs/perf.md`.

**Update 2026-11-13 (owner decision):** the target is **30 MB `phys_footprint`** (not RSS), and the renderer is CPU-drawn to reach it. Measured at 80x24-class window size: empty CPU-drawn view 25 MB, empty Metal view 30 MB. Window size is part of the definition; see `docs/perf.md`. Throughput against GPU terminals may drop; that target is to be revisited with measured numbers.

**Method:** set up benchmarks **before** optimizing. Use vtebench for throughput, Instruments (Time Profiler, Allocations, Metal System Trace) for CPU/memory/GPU, and an internal keypress-to-present timestamp for latency. Track results in `docs/perf.md` with machine and OS version.

---

## 8. Roadmap and status

- **Phase 0 (Scaffolding and baselines):** Done. Zig `0.17.1` pinned, `build.zig` + `include/harf.h` + SwiftPM shell + `macos/build-app.sh`, CI, MIT license, `ARCHITECTURE.md`, `docs/perf.md`.
- **Phase 1 (Arabic render spike):** Done. Owner chose model C ("C fit", per-word kashida justification), documented in `docs/cell-model.md`.
- **Phase 2 (Bidi UAX #9):** Done. `src/bidi/bidi.zig` + `src/bidi/tables.zig`, validated against Unicode 18.0.0 (`BidiTest.txt`, `BidiCharacterTest.txt` via `test/fetch-ucd.sh`) in `zig build test`.
- **Phase 3 (PTY + parser + grid):** Done. Adopted `libghostty-vt` 1.0.1 (`src/vt.zig`), `src/pty.zig`, `src/term.zig`, `src/draw.zig`, dirty-row invalidation, sRGB backing store (~25–26 MB footprint), `programs_test.zig`, `vttest` conformance (`docs/phase3-done.md`).
- **Phase 4 (Arabic layout integrated with grid):** Done. `src/rowfacts.zig`, `src/rowlayout.zig`, logical-cell cursor, accepted in `docs/phase4-manual-check.md`.
- **Phase 5 (Agent compatibility):** Done. Verified with Claude Code and Codex CLI (`docs/phase5-spike.md`), plus XTVERSION, XTWINOPS (`CSI 14/16/18/19 t`), OSC 8, OSC 52 (write-only, focused-pane gated), OSC 9/777, kitty key-release events.
- **Phase 6 (Developer UX):** Shipped core v1 items (tabs/splits, find, config/themes/hot-reload, OSC 133 zsh integration, paste guard, `Cmd+Click` on paths/URLs, Finder folder/file integration). Remaining: session restore, `Option+Click` at prompt, bash/fish OSC 133.
- **Phase 7 (Selection, editing keys, remapping, polish):** Largely done (logical selection/copy, editor-style editing keys, `keybind` remapping, app icon, logging). Remaining: visual (bidi-aware) mouse selection, ink centering, per-paragraph bidi across soft wraps.

---

## 9. Resolved decisions & remaining open items

1. **Parser reuse in Zig (Resolved):** `libghostty-vt` 1.0.1 (MIT) is used behind a thin Zig C-ABI wrapper (`src/vt.zig`).
2. **Prior art for bidi in terminals (Resolved):** Researched in `docs/bidi-prior-art.md` (VTE, Konsole, iTerm2, WezTerm, Terminal.app, mlterm).
3. **Cell model (Resolved):** Model C ("C fit", per-word kashida justification) chosen; documented in `docs/cell-model.md`.
4. **Base direction policy (Resolved for v1):** `src/rowfacts.zig` sets `auto` base direction to RTL only if the first non-blank cell is strong RTL and the row contains no box/block characters (`ltr`/`rtl` override supported).
5. **Typing behavior (Resolved for v1):** Logical-cell cursor with C-fit word re-fitting accepted by the owner in Phase 4 (`docs/phase4-manual-check.md`).
6. **Who draws glyphs (Resolved):** Zig draws glyph runs with CoreText straight into a `CGContext` passed across `include/harf.h` (`src/draw.zig`); no atlas.
7. **Name, license, minimum macOS version (Resolved):** **Harf**, **MIT**, **macOS 14.0+**.
8. **Fonts (Resolved for v1):** Relies on CoreText system fallback (no bundled font).
9. **Hosting/distribution (Open):** Local unsigned app builds (`macos/build-app.sh`, tagged `v0.2.0`); notarization, signing, and auto-update remain future work.

---

## 10. Current repo layout

```
harf-terminal/
  build.zig
  build.zig.zon
  .zig-version            # pinned compiler (0.17.1)
  LICENSE
  NOTICE
  README.md
  ARCHITECTURE.md
  include/harf.h          # hand-written C ABI matching src/capi.zig
  src/
    capi.zig              # C ABI exports
    config.zig            # key = value config, themes, keybinds
    draw.zig              # CoreText/CoreGraphics painter + dirty rows
    keys.zig              # key encoding
    pty.zig               # forkpty + shell integration env
    rowfacts.zig          # RTL detection & base direction policy
    rowlayout.zig         # C-fit row shaping & cache
    term.zig              # Session (I/O thread, selection, search, OSC 133/52/8/9)
    vt.zig / vt_c.h       # libghostty-vt 1.0.1 wrapper
    bidi/                 # UAX #9 + generated tables + conformance tests
    shape/                # CoreText bindings, C-fit layout
    programs_test.zig     # real-program PTY smoke tests
  macos/                  # SwiftPM AppKit shell + build-app.sh + shell-integration/
  bench/                  # footprint.sh, idle.sh, startup.sh
  test/                   # fetch-ucd.sh + Unicode 18.0.0 data (git-ignored)
  tools/                  # gen-bidi-tables.sh
  docs/                   # cell-model.md, perf.md, logging.md, bidi-prior-art.md, conformance/
```

---

## 11. Working agreements for Claude Code

1. **Read this brief first.** Do not change a locked decision (§2) without asking.
2. **Zig moves fast.** Run `zig version`, pin it, and read the stdlib source for the pinned version instead of recalling APIs from memory. Do not guess function signatures.
3. **Verify before relying** on anything in §9.
4. **Test first for bidi.** Conformance files in CI before wiring layout into the grid.
5. **Measure before optimizing.** Record benchmark results in `docs/perf.md`.
6. **Dependencies:** none without discussion; license must be MIT-compatible (no GPL/LGPL).
7. **Small commits per phase**, each meeting its acceptance criteria. Stop and ask when a design question in §4.4 or §4.5 needs a human judgment about how Arabic should look or feel.
8. **Use real Arabic test strings** (§4.7) and ask the owner for screenshots/feedback on visual correctness.
9. Keep the C ABI small. Prefer adding capability in Zig over adding Swift logic.
10. Keep idle cost at zero: no polling, no always-on timers.

---

## 12. Historical: original Phase 0 prompt

```
Read PROJECT_BRIEF.md in full. Then do Phase 0 only:
1. Run `zig version`, pin the compiler in .zig-version and build.zig.zon.
2. Scaffold the repo layout from section 10 (empty modules are fine).
3. Make build.zig produce a static library and a C header exposing one test function.
4. Create a minimal Swift/AppKit app under macos/ that links the library, opens a Metal-backed window, and calls the test function.
5. Measure RSS and idle CPU of the empty app and write the numbers to docs/perf.md.
6. Write ARCHITECTURE.md summarizing section 3.
Do not start Phase 1. Ask me about the project name and license before the first commit.
```
