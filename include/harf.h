/* Harf core C ABI. Hand-written; keep in sync with src/capi.zig. */
#ifndef HARF_H
#define HARF_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Phase 0 smoke test: returns a fixed magic value so the shell can prove the
 * Zig core is linked and callable. */
uint32_t harf_ping(void);

/* ---- Terminal sessions (Phase 3): a child on a PTY, parsed into a logical-order grid ---- */

typedef struct HarfTerm HarfTerm;

/* Callbacks run on the session's I/O thread: keep them short, and do not call back into the
 * session except harf_term_wake_handled. wake fires once, then not again until
 * harf_term_wake_handled is called. */
typedef struct {
    void *ctx;
    void (*wake)(void *ctx);
    void (*title)(void *ctx);
    void (*bell)(void *ctx);
    void (*exited)(void *ctx, int status);
    /* OSC 52: UTF-8 text a program put on the clipboard (no NUL, borrowed for the call). Only called when the policy
     * (harf_term_set_clipboard_write) allows it, and only for the standard clipboard. */
    void (*clipboard_write)(void *ctx, const uint8_t *text, size_t len);
    /* OSC 9 / 777: untrusted UTF-8 title (may be empty) and body, borrowed for the call. */
    void (*notify)(void *ctx, const uint8_t *title, size_t title_len, const uint8_t *body, size_t body_len);
    /* OSC 133: a command started running (running = 1) or ended (running = 0; has_exit_code says whether exit_code is real;
       duration_ms is how long it ran). Called only when that changes, never once per sequence. */
    void (*command)(void *ctx, int running, int exit_code, int has_exit_code, uint32_t duration_ms);
} HarfTermCallbacks;

/* argv: NULL-terminated program and arguments (argv[0] is the path), or NULL for the login shell.
 * Returns NULL for a zero size or if the child cannot start. */
HarfTerm *harf_term_new(uint16_t cols, uint16_t rows, size_t scrollback_bytes,
                        const char *const *argv, const HarfTermCallbacks *cb);
/* Like harf_term_new, starting the child in `cwd` (NULL: a shell starts in $HOME; a directory that cannot be entered means "/"). */
HarfTerm *harf_term_new_in(uint16_t cols, uint16_t rows, size_t scrollback_bytes, const char *const *argv, const char *cwd,
                           const HarfTermCallbacks *cb);
/* The child's process id (ask the system for its working directory with it). */
int harf_term_pid(HarfTerm *t);
/* Stops the session (hangs up on the child if it still runs). No callback runs after it returns. */
void harf_term_free(HarfTerm *t);
/* Sends bytes to the child as if typed. 0 = ok. */
int harf_term_input(HarfTerm *t, const uint8_t *bytes, size_t len);
/* cell_w_px, cell_h_px: pixel size of one cell. 0 = ok. */
int harf_term_resize(HarfTerm *t, uint16_t cols, uint16_t rows, uint32_t cell_w_px, uint32_t cell_h_px);
/* UTF-8 text of visible row `row`, trailing blanks trimmed, no NUL. Returns bytes written (cut off at cap). */
size_t harf_term_row_text(HarfTerm *t, uint16_t row, char *out, size_t cap);
/* Copies the title the child set (no NUL). Returns bytes written, cut off at cap. */
size_t harf_term_title(HarfTerm *t, char *out, size_t cap);

/* A font at size_px device pixels with its glyph cache. */
typedef struct HarfPainter HarfPainter;
typedef struct {
    float cell_w, cell_h; /* whole-pixel cell size */
    float ascent;         /* baseline offset from the top of a cell */
} HarfCellMetrics;
HarfPainter *harf_painter_new(float size_px);
/* Like harf_painter_new in the font family `family` (UTF-8). NULL if it is not installed or not monospaced. */
HarfPainter *harf_painter_new_font(const char *family, float size_px);
void harf_painter_free(HarfPainter *p);
void harf_painter_metrics(HarfPainter *p, HarfCellMetrics *out);
/* Draws rows first_row..last_row (inclusive, clamped to the grid) and the cursor into a y-down
 * CGContextRef in device pixels; the grid's top-left is the context's origin. Locks the session. */
void harf_term_draw(HarfTerm *t, HarfPainter *p, void *cg_context, uint16_t first_row, uint16_t last_row);
/* Which visible rows differ from what harf_term_draw last drew: out[i] is 1 for a row to redraw (the row above each changed
 * row is included, because glyphs reach into it). Returns the grid's row count; cap is the size of out, and a count larger
 * than cap means the caller must redraw everything. Every row is reported before the first draw and after a change of the
 * grid size or the default colors. harf_term_draw also draws the row below last_row (its glyphs reach up into last_row), but
 * does not count it as drawn, so the context must be clipped to the rows' rectangle. */
size_t harf_term_dirty_rows(HarfTerm *t, HarfPainter *p, uint8_t *out, size_t cap);

/* Modifier bits for harf_term_key. */
#define HARF_MOD_SHIFT 1
#define HARF_MOD_CTRL 2
#define HARF_MOD_ALT 4
#define HARF_MOD_SUPER 8
/* keycode: macOS virtual keycode. utf8: the text the layout types for the key with Control removed
 * (Shift applied; may be empty). unshifted: the layout's character for the key with no modifiers, as a
 * Unicode scalar (0 if unknown). A Control combination is named by the layout's letter, so AZERTY,
 * Dvorak and Colemak work, and by the physical US key when the layout has no ASCII letter there.
 * action: 0 press, 1 release, 2 repeat. Returns 1 if handled (function keys, Control combinations,
 * lone modifiers: bytes were queued), 0 if it is a text key to send with harf_term_input or a key
 * with no encoding, -1 on error. */
int harf_term_key(HarfTerm *t, uint16_t keycode, uint32_t mods, const uint8_t *utf8, size_t len, uint32_t unshifted, int action);
/* Wheel or trackpad: delta_rows rows toward newer output when positive, toward older when negative.
 * On the alternate screen the program gets that many Up/Down key presses instead. 0 = ok. */
int harf_term_scroll(HarfTerm *t, int32_t delta_rows);
/* A mouse event at a pixel of the grid (device pixels, origin at its top-left). action: 0 press, 1 release,
 * 2 motion. button: 0 none, 1 left, 2 right, 3 middle. Returns 1 if the program has mouse tracking on and took
 * the event, 0 if the caller keeps it for selection (Shift always keeps it), -1 on error. */
int harf_term_mouse(HarfTerm *t, HarfPainter *p, int action, int button, uint32_t mods, double x_px, double y_px);
/* The window gained (1) or lost (0) focus: the cursor is hollow while unfocused, and a program that enabled
 * focus events (mode 1004) is told. 0 = ok. */
int harf_term_focus(HarfTerm *t, int focused);
/* A left-button selection gesture at a pixel of the grid (use it when harf_term_mouse returned 0).
 * phase: 0 press, 1 drag, 2 release. click_count: 1, 2 (word) or 3 (line). mods uses HARF_MOD_*;
 * HARF_MOD_SHIFT on press continues an existing selection. 0 = ok. */
int harf_term_selection_event(HarfTerm *t, HarfPainter *p, int phase, int click_count, uint32_t mods, double x_px, double y_px);
/* The OSC 8 hyperlink under a pixel of the grid: copies its URI (no NUL) into out and returns its length, or 0 if there is
 * none or it does not fit cap. */
size_t harf_term_hyperlink_at(HarfTerm *t, HarfPainter *p, double x_px, double y_px, uint8_t *out, size_t cap);
/* The file path under a pixel (same convention): its length (0 = none, or it does not fit), and the :line and :col after it (0 when
   absent). The file may not exist: the caller checks. */
size_t harf_term_path_at(HarfTerm *t, HarfPainter *p, double x_px, double y_px, uint8_t *out, size_t cap, uint32_t *line, uint32_t *col);
/* The link under a pixel and the cells it covers: 0 none, 1 an OSC 8 hyperlink, 2 a plain URL, 3 a file path (with its :line:col);
   *row, *lo, *hi get its row and first and last column. The caller checks that it can be opened (allowed scheme, file exists). */
int harf_term_link_span_at(HarfTerm *t, HarfPainter *p, double x_px, double y_px, uint16_t *row, uint16_t *lo, uint16_t *hi);
/* Tints cells lo..hi of visible row `row` whenever that row is drawn (the caller invalidates the row); one at a time. */
void harf_painter_set_highlight(HarfPainter *p, uint16_t row, uint16_t lo, uint16_t hi, uint8_t r, uint8_t g, uint8_t b);
void harf_painter_clear_highlight(HarfPainter *p);
/* The plain http or https URL under a pixel: its length (0 = none, or it does not fit). */
size_t harf_term_url_at(HarfTerm *t, HarfPainter *p, double x_px, double y_px, uint8_t *out, size_t cap);
/* Starts a find for `needle` (UTF-8; ASCII letters match in either case) over the screen and scrollback; returns the number of
 * matches (an empty needle ends the find). Nothing is selected until harf_term_find_step. */
size_t harf_term_find(HarfTerm *t, const uint8_t *needle, size_t len);
/* Selects the next match toward older output (older = 1) or newer (0), wrapping; scrolls to it and highlights it. Returns 1 with
 * the match's 1-based position `number` of `total`, or 0 if there are no matches. */
int harf_term_find_step(HarfTerm *t, int older, size_t *number, size_t *total);
/* Scrolls to the prompt `delta` prompts away (negative: older) using the shell's OSC 133 marks. Returns 1 if the key was taken (even
   when there is no prompt that way, so the shell never sees it), 0 on the alternate screen: the key belongs to the program. */
int harf_term_scroll_prompt(HarfTerm *t, int delta);
/* Selects the output of the last finished command (the shell's OSC 133 marks); Cmd+C then copies it. Returns 1 if something was
   selected, 0 if not (no marks, or the alternate screen: the key then belongs to the program). */
int harf_term_select_output(HarfTerm *t);
/* Selects everything, scrollback included (Cmd+A); Cmd+C then copies it. */
void harf_term_select_all(HarfTerm *t);
/* Moves the free end of the selection (starting one at the cursor if there is none): `kind` 0 to the start of the line, 1 to its end,
   2 to the previous word edge, 3 to the next. Returns 1 if the key was taken, 0 on the alternate screen or while the program has the kitty
   keyboard protocol on (the key then belongs to the program). */
int harf_term_select_move(HarfTerm *t, int kind);
/* Ends the find and clears its highlight. */
void harf_term_find_end(HarfTerm *t);
/* Clear the screen (and the scrollback if `scrollback` is not 0), then type Ctrl+L so a shell redraws its prompt. On the
   alternate screen nothing happens and it returns 0 (the key is the program's); otherwise 1. */
int harf_term_clear(HarfTerm *t, int scrollback);
/* Whether a program may write the clipboard with OSC 52 (1 yes, 0 no; the default is yes). Reading is never allowed. */
void harf_term_set_clipboard_write(HarfTerm *t, int allow);
/* The selected text as UTF-8 in logical order, or NULL if nothing is selected; *len is its length. Free with harf_free. */
uint8_t *harf_term_selection_text(HarfTerm *t, size_t *len);
void harf_free(void *p);
void harf_term_clear_selection(HarfTerm *t);
/* The terminal's current default background (a program's OSC 11 changes it) as R, G, B bytes: fill the margins
 * around the grid with it. */
void harf_term_default_bg(HarfTerm *t, uint8_t rgb[3]);
/* The terminal's real grid size (a program can change it, for example to 132 columns, without the view knowing). */
void harf_term_grid(HarfTerm *t, uint16_t *cols, uint16_t *rows);
/* Whether pasting `utf8` should be confirmed first: 0 = no, bit 1 = it would run lines (a line break, and the program has not asked
   for bracketed paste), bit 2 = it is very large (over 100,000 bytes). */
int harf_term_paste_check(HarfTerm *t, const uint8_t *utf8, size_t len);
/* Pastes text, framed for the terminal's paste mode (bracketed, newlines as CR). 0 = ok. */
int harf_term_paste(HarfTerm *t, const uint8_t *utf8, size_t len);
void harf_term_wake_handled(HarfTerm *t);
/* The child's exit code once it has ended and its output is parsed; -1 while it runs. */
int harf_term_exit_status(HarfTerm *t);

/* A theme's colors for one session. palette_set has bit i set when ANSI color i is given; the others stay the terminal's. */
typedef struct {
    uint8_t fg[3], bg[3];
    uint8_t has_cursor;
    uint8_t cursor[3];
    uint16_t palette_set;
    uint8_t palette[16][3];
} HarfTheme;
/* Applies a theme to this session (default colors, cursor color, ANSI colors) and redraws. 0 = ok. */
int harf_term_set_theme(HarfTerm *t, const HarfTheme *theme);
/* The system appearance, dark (1) or light (0): answers CSI ? 996 n, and tells a program that enabled mode 2031 of a change. */
void harf_term_set_scheme(HarfTerm *t, int dark);

/* ---- Configuration (Phase 6): a `key = value` file, themes and key bindings; the shell applies them ---- */

typedef struct HarfConfig HarfConfig;
/* Reads the configuration in `dir`, or in the default place ($XDG_CONFIG_HOME/harf, else ~/.config/harf) when dir is NULL. A
 * missing directory or file is an empty configuration; bad lines are warnings. Free with harf_config_free. */
HarfConfig *harf_config_load(const char *dir);
void harf_config_free(HarfConfig *cfg);
/* The directory it was read from (valid until harf_config_free). */
const char *harf_config_dir(HarfConfig *cfg);
/* The text of a commented configuration file with every setting at its default (static). */
const char *harf_config_template(void);
const char *harf_config_font_family(HarfConfig *cfg);
float harf_config_font_size(HarfConfig *cfg); /* points */
float harf_config_window_width(HarfConfig *cfg); /* points */
float harf_config_window_height(HarfConfig *cfg); /* points */
size_t harf_config_scrollback_bytes(HarfConfig *cfg);
int harf_config_clipboard_write(HarfConfig *cfg); /* 1 allow, 0 deny */
int harf_config_notifications(HarfConfig *cfg);   /* 0 unfocused, 1 always, 2 off */
int harf_config_shell_integration(HarfConfig *cfg); /* 0 auto, 1 off */
int harf_config_paste_guard(HarfConfig *cfg);       /* 1 on, 0 off */
const char *harf_config_editor(HarfConfig *cfg);    /* how Cmd-click opens a file; empty = the default text editor */
/* Sets `key = value` in the config file at `path` (created if missing; an uncommented line is rewritten in place, comments kept).
   0 = ok, -1 = the value holds a line break, or the file cannot be written. */
int harf_config_set_key(const char *path, const char *key, const char *value);
/* The directory holding the zsh shim (`zsh/.zshenv`): a login zsh started afterwards emits OSC 133 marks. NULL turns it off. */
void harf_set_shell_integration_dir(const char *dir);
/* The theme for a dark (1) or light (0) system appearance. */
void harf_config_theme(HarfConfig *cfg, int dark, HarfTheme *out);
/* One key binding: mods use HARF_MOD_*; key is a lowercase character or a name (left, return, f5); action is its name
 * (new_tab, goto_tab, send, ...); arg is the tab number as text for goto_tab, the bytes for send. */
typedef struct {
    uint8_t mods, arg_len;
    char key[16];
    char action[24];
    uint8_t arg[64];
} HarfKeybind;
size_t harf_config_keybind_count(HarfConfig *cfg);
int harf_config_keybind(HarfConfig *cfg, size_t i, HarfKeybind *out); /* 0, or -1 if there is no binding i */
size_t harf_config_warning_count(HarfConfig *cfg);
const char *harf_config_warning(HarfConfig *cfg, size_t i); /* NULL if there is no warning i */

#ifdef __cplusplus
}
#endif

#endif /* HARF_H */
