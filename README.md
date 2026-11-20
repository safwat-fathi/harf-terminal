# Harf

A fast, lightweight terminal emulator for macOS (Apple Silicon) with Arabic and bidirectional (bidi) text support from day one.

Harf pairs a **Zig** core (PTY, VT parser/grid, UAX #9 bidi, CoreText shaping, CoreGraphics drawing) with a thin **Swift/AppKit** shell.

## Features

- **Arabic & Bidi Rendering**:
  - Own Unicode Bidirectional Algorithm (UAX #9) implementation in Zig, tested against Unicode 18.0.0 conformance suites.
  - CoreText contextual shaping, ligatures, tashkeel, and system font fallback.
  - Logical-order grid with per-row logical-to-visual mapping — copying text always yields logical order.
  - Plain LTR rows skip bidi and shaping entirely.
- **Lightweight & Responsive**:
  - CPU-drawn via CoreGraphics and CoreText (no Metal, no web view), ~25–26 MB memory footprint.
  - Dirty-row tracking and batched glyph drawing; zero timers while idle.
- **Native macOS Shell**:
  - Windows, native tabs, and split panes (`Cmd+D` / `Cmd+Shift+D`).
  - Find bar (`Cmd+F`) across scrollback and active screen with all visible matches highlighted.
  - Editor-style cursor/edit shortcuts (`Option+Left/Right`, `Option+Backspace/Delete`, `Cmd+Left/Right`), keyboard selection (`Cmd+A`, `Cmd+Shift+Left/Right`, `Option+Shift+Left/Right`) and `Cmd+Z` undo at the prompt.
  - OSC 8 clickable links, plain URLs, and `path:line:col` file paths (`Cmd+Click` with `Cmd+Hover` preview; **Harf → Choose Editor…**), OSC 52 clipboard writes (gated to the focused pane), and OSC 9/777 notifications.
  - Paste guard (`paste_guard = on` by default) confirms pastes over 100 KB or multi-line pastes when bracketed paste is off.
  - Drop a file from Finder onto a terminal (or a split pane) to type its shell-quoted path at the cursor.
  - Open folders via `open -a Harf <dir>`, Finder drag-and-drop, CLI arguments, or Finder Services (**New Harf at Folder** / **New Harf Tab at Folder** under System Settings → Keyboard → Keyboard Shortcuts → Services → Files and Folders).
- **Shell Integration (OSC 133)**:
  - Bundled `zsh` integration (`shell_integration = auto` by default) for prompt jumping (`Cmd+Up` / `Cmd+Down`), selecting the last command's output (`Cmd+Shift+A`), and completion notifications for long-running commands.
- **Live Configuration**:
  - Plain `key = value` config with automatic hot reload on save, custom themes, system dark/light appearance tracking, and customizable keybindings.

## Requirements

- **OS**: macOS 14.0+ on Apple Silicon (`aarch64`)
- **Zig**: `0.17.1` (pinned in [`.zig-version`](.zig-version))
- **Xcode / Swift**: Swift 6.0+ toolchain

## Building & Running

Build the Zig static library, link the Swift shell, and assemble `macos/.build/Harf.app`:

```sh
./macos/build-app.sh
open macos/.build/Harf.app
```

> **Note:** `macos/build-app.sh` uses `.tools/zig/zig` if present, otherwise `zig` from `PATH`.

### Installing

Copy the built app to `/Applications` and launch it:

```sh
./macos/build-app.sh                  # builds macos/.build/Harf.app
rm -rf /Applications/Harf.app         # only when updating an existing install; quit Harf first
cp -R macos/.build/Harf.app /Applications/
open -a Harf
```

The build is local and unsigned, so macOS does not block it. Harf does not update itself: repeat these steps after each rebuild.

### Running Tests

Run the Zig test suite (includes UAX #9 conformance, shaping, VT/PTY, and config tests):

```sh
zig build test
```

On the first run, `test/fetch-ucd.sh` downloads the pinned Unicode 18.0.0 data files into `test/ucd/` and verifies their SHA-256 checksums.

To build only the Zig static library (`zig-out/lib/libharf.a`):

```sh
zig build
```

## Configuration

Harf reads its configuration from `$XDG_CONFIG_HOME/harf/config` (default `~/.config/harf/config`) and reloads automatically when saved. Press `Cmd+,` to open (or create) the commented default config file.

Example `~/.config/harf/config`:

```ini
font_family = Menlo
font_size = 14

# Default content size for new windows, in points
# window_width = 1000
# window_height = 720

# Built-in themes: dark, light, or files in ~/.config/harf/themes/
theme = dark:dark, light:light

# Optional color overrides (#rrggbb)
# foreground = #ebebeb
# background = #0f0f12
# cursor_color = #ebebeb
# palette = 1=#ff5555

scrollback_bytes = 1048576
clipboard_write = allow       # allow | deny (reads are never allowed)
notifications = unfocused     # unfocused | always | off
shell_integration = auto      # auto | off
paste_guard = on              # on | off

# Editor for Cmd+Click on file paths (`path`, `path:line`, `path:line:col`)
# editor = vscode://file{path}:{line}:{col}
# editor = code --goto {path}:{line}:{col}
# editor = app:/Applications/Sublime Text.app

# Custom keybindings (use `unbind` to remove a default, or `send:TEXT` to send bytes)
# keybind = cmd+t = new_tab
# keybind = cmd+w = unbind
```

### Default Shortcuts

| Shortcut | Action |
|---|---|
| `Cmd+N` / `Cmd+T` / `Cmd+W` | New window / New tab / Close pane or tab |
| `Cmd+D` / `Cmd+Shift+D` | Split right / Split down |
| `Cmd+]` / `Cmd+[` | Focus next / previous pane |
| `Cmd+Shift+]` / `Cmd+Shift+[` | Next / previous tab (`Cmd+1`–`9` to jump) |
| `Cmd+F` / `Cmd+G` / `Cmd+Shift+G` | Find / Next match / Previous match |
| `Cmd+C` / `Cmd+V` | Copy / Paste |
| `Cmd+A` | Select all, scrollback included |
| `Cmd+Shift+Left` / `Cmd+Shift+Right` | Select from the cursor to the start / end of the line (wrapped rows are one line; the prompt counts) |
| `Option+Shift+Left` / `Option+Shift+Right` | Extend the selection one word left / right (from the cursor when nothing is selected) |
| `Cmd+Z` | Undo the last edit of the prompt line (sends `Ctrl+_`, which zsh and readline bind to undo) |
| `Cmd+K` / `Ctrl+L` | Clear screen & scrollback / Clear visible screen |
| `Cmd+Up` / `Cmd+Down` | Jump to previous / next prompt (OSC 133) |
| `Cmd+Shift+A` | Select last command output (OSC 133) |
| `Cmd+=` / `Cmd+-` / `Cmd+0` | Increase / decrease / reset font size |
| `Cmd+,` / `Cmd+Shift+,` | Open config / Reload config |

`Cmd+Shift+Left/Right` and `Option+Shift+Left/Right` are left to the program on the alternate screen and while a program has the kitty keyboard protocol on (Claude Code does, and moves its own caret with them); `Cmd+A` and `Cmd+Z` work everywhere.

## Troubleshooting

Harf writes a log to `~/Library/Logs/Harf/harf.log`: launch, quit, config warnings, failed notifications and editor launches, pane exits. If the last run ended without a `quit` line, the next launch says so, and macOS keeps the crash report as `Harf-*.ips` in `~/Library/Logs/DiagnosticReports`. See [docs/logging.md](docs/logging.md).

## Architecture

```
PTY (child shell)
  -> VT parser + screen/grid (libghostty-vt, logical order, damage-tracked)
    -> Per-row layout: bidi (UAX #9) -> shaping (CoreText) -> cluster-to-cell map [RTL rows only]
      -> Draw (Zig, CoreText/CoreGraphics into a CGContext over include/harf.h)
        -> Swift/AppKit shell: view + dirty-rect invalidation, windows, tabs, splits, IME, notifications
```

- [`src/`](src/) — Zig core (`libharf.a`)
- [`include/harf.h`](include/harf.h) — Hand-written C ABI matching [`src/capi.zig`](src/capi.zig)
- [`macos/`](macos/) — Swift/AppKit shell and `build-app.sh`
- [`ARCHITECTURE.md`](ARCHITECTURE.md) — Architecture rules and decisions log

## License & Acknowledgments

Harf is licensed under the [MIT License](LICENSE).

- Terminal VT parser and grid state are powered by [libghostty-vt](https://github.com/ghostty-org/ghostty) (1.0.1, MIT License).
- Bidi tables and conformance tests use data from the Unicode Character Database (18.0.0). See [NOTICE](NOTICE) for full third-party notices.
