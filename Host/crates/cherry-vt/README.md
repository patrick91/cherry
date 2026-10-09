# cherry-vt

Safe ownership wrapper around a pinned upstream libghostty-vt, using a small C
shim compiled against the matching upstream headers rather than duplicating
complex C struct layouts in Rust. A terminal can move between threads (`Send`)
but cannot be accessed concurrently (`!Sync`). Ghostty callbacks run
synchronously and append PTY replies and events into a stable owned
allocation; they copy what Ghostty lends them and never call back into the
terminal.

`feed` consumes workload output and returns terminal-query replies for the
host to write to the PTY. `resize` may also return size-report bytes. The host
must remove answered queries and modes 2048 (in-band size reports) and 2033
(visibility reports) from the frontend's display stream; otherwise the
frontend can generate duplicate replies. Snapshots and `modes()` never carry
those two modes. The host also takes the queries it leaves unanswered out of
that stream and sends each to one attached client to answer (see the
[host guide](../../README.md#bounds-and-terminal-fidelity)).
Size queries use the session's rows/columns and its cell size (`resize_cells`; 8×16 until a client reports one).

### Prompts on resize

A new terminal clears the shell's prompt on resize, as Ghostty's own
terminal does (libghostty-vt's constructor turns that off for embedders;
`cherry_vt_new` resets the terminal to Ghostty's defaults): when the cursor
is at a prompt that OSC 133 marked, the shell redraws the prompt on SIGWINCH,
and the terminal clears it for that redraw. Before a resize that changes the
columns, `resize_cells` clears it itself, in place, before the rows reflow:
from the row OSC 133 marked as the prompt's first down to the end of the
screen, taking in the rows marked as its continuation and rows that soft-wrap
into it, with the cursor left where it was. The rows are then blank, so the
reflow neither wraps nor unwraps them, and a shell that moves up as many rows
as its prompt took at the old width (zsh) redraws it on its first row.
Ghostty clears only after the reflow, from the last part of a prompt line
the new width wraps (the reflow marks each part as the prompt's first row):
the parts above stay beside the redraw, and a line the new width unwraps
moves the cursor up, so the redraw erases output above the prompt. The clear
is fed as output (a cursor position, an erase below, the cursor put back;
an unfinished sequence is kept as `clear_history` keeps it) and only when
it leaves nothing else changed: on the primary screen, without a pending
wrap or origin mode, with a pen of the default background, a prompt that
begins on the screen, and a shell that redraws its whole prompt (no
`redraw=0` or `redraw=last` in its last OSC 133 A or N, which Ghostty's bash
integration sends; a reset forgets it). Otherwise the resize is Ghostty's,
which honours those options.
Color queries (OSC 10, 11 and 12) and the color-scheme query (`CSI ?996n`)
report the colors `set_colors` gave (the host passes those its `Create`
named), by default light gray on black and dark; a reset keeps them.
Grapheme clustering (mode 2027) is on by default, as in Ghostty, and a reset
(RIS) turns it back on: cell widths of emoji, flags and ZWJ sequences then
match the app's terminal, into which snapshots are replayed.
`clear_history` clears the history above the screen as `ED 3` would, keeping
an unfinished escape sequence the output left (its continuation is fed again
after the erase); when the output left a UTF-8 character half written, the
erase waits for the `feed` that completes it (it returns false then).
XTGETTCAP `TN` (the terminfo name) is answered only after
`set_terminfo_name`, with the name given (the program's TERM).

The library is built with `-Doptimize=ReleaseSafe` (`Scripts/build-host-vt`):
the host parses untrusted output from every session, so Zig's runtime safety
checks stay on. Each session's terminal lives in its own holder process
(`cherry-host hold`), so a safety abort ends only that session. The script records the Ghostty revision and the
optimize mode next to the archive (`SOURCE_REVISION`, `OPTIMIZE`); the build
script refuses an archive whose stamps do not match, including one built
before the stamps existed, and asks for `Scripts/build-host-vt` to be run.

## Events

Besides replies, output makes the terminal report what programs ask of it
beyond drawing. `take_events` returns them in order, as `VtEvent`s:

- `Title` (OSC 0 or 2; OSC 1 sets the icon name and is ignored) and `Pwd`,
  the working directory exactly as reported: a `file://host/path` URI (OSC 7,
  percent-encoded) or a plain path (OSC 9;9, OSC 1337 CurrentDir). An empty
  value means cleared, by the program or by a reset (RIS, which Ghostty does
  without a callback: `feed` compares the terminal's values afterwards). A
  value set again unchanged is not reported again. Titles are cut to 1024
  bytes; a title that is not UTF-8, or an OSC longer than Ghostty's parser
  keeps (2 KiB for these), changes nothing.
- `Bell` (BEL).
- `Notification { title, body }` for OSC 9 (body only) and OSC 777
  (`notify;title;body`).
- `Progress { state, value }` for OSC 9;4. `value` is a percentage, clamped to
  100, absent when the program gave none; a reset reports `Remove`. Ghostty
  takes an OSC 9;4 with an unknown state for an OSC 9 notification.
- `ProgramStatus` when the program status records changed
  (`program_status()`): an OSC 7501 report, a new primary shell prompt (OSC
  133 A) that ends the program before it, or a reset. libghostty-vt checks
  each report against the specification and keeps nothing (setting its
  program status callback also makes it answer the support query, `OSC 7501
  ; ?`); the terminal keeps the records as the reports come, in its
  callbacks' state, so no bound on pending events can lose one
  (`program_status.rs`: a report replaces its record whole, `clear` removes a
  record and its children or all of them, at most
  `MAX_PROGRAM_STATUS_RECORDS` (64) with the least recently updated making
  room, invisible formatting characters removed from the text).
  `end_program()` drops what an exited program left `working`, `blocked` or
  `idle`; `done` and `error` stay.

Events never produce replies, and nothing but `feed` produces them:
snapshots, `refresh`, `viewport`, `modes`, `inspect` and `resize` work on
copies or report nothing. Sequences split across reads are reported once
they end. Pending events are bounded (`MAX_PENDING_EVENTS`,
`MAX_PENDING_EVENT_BYTES`), so a terminal whose events nobody takes stays
small: a title, working directory, progress report or program status change
replaces the one before it when nothing came between, a bell right after a bell adds nothing, and
beyond the bounds the oldest are dropped. A title, working directory or
progress report is state, not news: when the bounds drop the latest of its
kind, it is kept apart and taken first, so a taker never misses the current
value (which, set again unchanged, would not be reported again). `title()`
and `pwd()` always read the current values, and `mode(value, ansi)` reads one
mode as the terminal holds it (DECCKM, application cursor keys, is
`mode(1, false)`). modifyOtherKeys has no getter: `modes()` writes
`ESC[>4;2m`, right before its kitty keyboard pop, exactly when it is at level
2 (libghostty keeps only that level; 1 and `ESC[>4m` are off), and
cherry-host's `screen::terminal_state` reads it there.

The terminal can also be read as text in place, without a copy:
`screen_text()` gives the whole of it with its history and `active_text()`
the active screen alone (soft-wrapped rows joined while autowrap is on,
trailing blanks and blank rows at the end trimmed). `cursor()` says where the
cursor is, which screen shows and how many rows of history lie above, and
`lines_ending(rows)` how many lines of that text end on those rows (a row
ends one unless it holds text and soft-wraps onto the next, as the text is
formatted), so the line that holds the cursor needs no marking of a copy.

libghostty-vt parses kitty notifications (OSC 99) but drops them, so they
never come from `take_events`. `Osc99` (one per session) takes each complete
`ESC ] 99 ; metadata ; payload` sequence, as a reader of the output stream
that keeps whole control strings sees it, and assembles notifications sent in
chunks (`i` identifier, `d=0` more to come, `p=title|body`, `e=1` base64);
`parse_osc99` handles a single sequence. Icons, buttons and payload types it
does not know are parts of a notification that are not reported: their
chunks still end it (without `d=0`). Queries (`p=?`), close requests and
liveness checks are not notifications and give nothing.

## Snapshots

`snapshot` produces VT bytes, beginning with a reset (RIS), for a fresh
renderer of the same dimensions. The shim encodes content itself from the
grid (the upstream formatter drops trailing blank rows, background-only rows
and per-cell hyperlinks):

- Content is written from the oldest history row down, one line per row, so
  the stream always ends on the last active row. Every active row lands on its
  own row, including after Ctrl-L or erase-below with history, in partial
  screens such as `fzf --height`, and after a resize. History scrolls off in
  order.
- Each cell is written at its column with its own style: SGR attributes and
  colours (palette and RGB, underline style and colour), OSC 8 hyperlinks,
  DECSCA protection, graphemes and wide cells. Cells erased under a background
  colour are recreated with ECH under that colour, so background-only rows and
  runs keep their colour instead of reverting to the default background.
- Soft wraps are recreated by letting the receiver wrap, so wrapped lines keep
  their wrap flags (copying and URL detection work across the wrap), also when
  a wide glyph that did not fit left a spacer in the last column.
- A wide character printed under a DEC or national character set is kept by
  Ghostty as a wide cell holding a space, which would print narrow. It is
  printed the same way: an ideographic space under DEC special graphics, then
  G0 designated ASCII again.
- With an alternate screen active, the primary screen is encoded first from a
  copy that left the alternate screen with the same mode that entered it
  (1049, 1047 or 47), then that mode is set again and the alternate screen is
  encoded. Leaving it later shows the primary screen and cursor as they were;
  the primary cursor that 1049 saved keeps its origin mode.
- Each screen's saved cursor (DECSC or 1048) follows its content, while the
  receiver still has default modes and full margins: its position, pending
  wrap, pen, protection, character sets and origin mode are set up, DECSC
  saves them, and they are put back to defaults. It is read by restoring it
  on the copy, and nothing is sent when it is the default that restoring
  without a save gives.
- Terminal-wide state follows the content: tab stops, modes, margins
  (DECSTBM/DECSLRM) and modifyOtherKeys. Then the cursor: an origin-aware CUP,
  the pending wrap (the glyph at the screen edge or right margin is reprinted
  before character sets are restored and before autowrap may be disabled),
  the SGR pen, the open
  hyperlink, protection and character sets. The kitty keyboard stack is
  rebuilt entry by entry for each screen, including entries below a current
  value of 0 and the stack of an inactive alternate screen, so later pops and
  screen switches see the same flags. Unfinished UTF-8/control continuations
  come last.
- Grapheme clustering (2027) is set, on or off, before content so cell
  widths match whatever the receiver's default. `refresh()` sends it only
  when the session turned it off.

`refresh()` brings a terminal of the same size that already holds this
terminal's history (a renderer that followed the session, or a fresh one) to
the current screens without a reset and without history: no RIS and no ED 2
or 3, so the receiver's scrollback is left alone. It sends what `snapshot`
sends, with two differences. Every state a snapshot restores is first put
back to its default explicitly, since the receiver is not reset: the screen
(back to the primary one), pen, hyperlink, protection, character sets
(designated ASCII), margins, modes, modifyOtherKeys, tab stops, the saved
cursor of each screen it repaints and both screens' kitty keyboard stacks.
And each screen's active area is erased line by line (EL, with DEC protection
selected so ISO protection does not survive) and repainted in place from its
top row, instead of streaming history; soft wraps are recreated inside the
screen.
The whole is one synchronized update (2026), left as the session has it.
Modes whose default comes from the user's terminal (see `modes()`) are not
reset. The size is that of the screens, whatever the history, so it suits
a renderer that only needs the screens, such as one painting a viewport
from a copy, or one of the same size that kept its own history.

`snapshot_limited(max_bytes)` is `snapshot` with the oldest history dropped,
in whole logical lines, until the result fits. When the cut falls inside a
soft-wrapped line, the rest of that line is dropped too, however long it is,
so the kept history never starts with a line fragment. When that line
continues into the active screen, all history is dropped. The active screen,
and the primary screen under an alternate screen, are never dropped; if they
alone exceed the limit it fails.

## Viewport rendering

For a physical terminal whose size differs from the canonical grid:

- `viewport(cols, rows)` repaints the top-left `cols×rows` view. It is content
  only: each row is painted at an absolute position over a cleared line, rows
  below the grid are erased, and the cursor position, visibility (25) and pen
  are restored, all inside a synchronized-output (2026) bracket. It sends no
  reset and no other modes, so sending it after every batch of output never
  makes the renderer reply.
- `modes()` makes the physical terminal's modes match: it resets every mode it
  manages to its default, then sets the non-default ones. It manages the
  alternate screen, input and display modes, modifyOtherKeys and the current
  kitty keyboard flags. cherry-host reads whether the alternate screen shows,
  and the kitty flags, from this output (`screen::terminal_state`, for
  `SessionInfo`); a test there pins its shape, so a change here needs that
  reader updated. Modes whose default comes from the user's terminal
  settings rather than the VT standard (DECARM 8, which libghostty defaults
  to off and does not implement, alternate scroll 1007, the Meta and Alt key
  modes 1035, 1036 and 1039, grapheme clustering 2027) are never reset: they
  are set only while the session has them away from this terminal's default
  (libghostty's, with grapheme clustering on), as its own output would set
  them. One the session sets back to that default
  keeps the value last sent. Insert, origin and left/right margin modes,
  margins and character sets are forced to their defaults, because frames
  paint at absolute positions. Cursor visibility and synchronized output are
  left to `viewport`, in-band size (2048) and visibility (2033) reports to the
  host, and DECCOLM is never sent. Resets have side effects (switching screens
  clears the alternate screen, enabling 1004/2031 makes the renderer report),
  so send it when entering viewport rendering and again only when its output
  changes, then paint a frame.
- `modes()` keeps the physical terminal's primary cursor. It switches screens
  before any reset that homes the cursor, and it returns to the primary
  screen with `?1049h ?1049l`: `?1049l` restores the cursor 1049 saved even
  on the primary screen, where that cursor can be stale (tmux keeps it apart
  from DECSC, so an earlier program's is still there), and the `?1049h`
  before it saves the current one. The cursor that `?1049h` saves, and that
  leaving the alternate screen with `?1049l` restores (for example when a
  client detaches from a program on the alternate screen), is therefore the
  one the physical primary screen showed: the user's prompt when rendering
  started on the alternate screen, or where the last frame of the primary
  screen left it. Leave with `?1049l` even when the session used 47 or 1047:
  leaving those keeps the alternate screen's cursor.
- When `modes()` is sent again while the physical terminal is on the
  alternate screen, its `?1049h` saves that screen's own cursor (xterm,
  Ghostty) or does nothing (tmux), so the primary cursor survives. A terminal
  with one saved cursor for both screens that also saves on a repeated
  `?1049h` would lose it there.
- Write `modes()` and the frame after it as one synchronized update,
  `ESC[?2026h` + `modes()` + `viewport()`: the frame's closing `ESC[?2026l`
  ends it, so the physical terminal never shows the intermediate screen
  switch (leaving and re-entering the alternate screen clears it until the
  frame repaints).

## Limits

- Of the kitty images, only those of the active screen's placements on
  screen are re-sent (`graphics_replay`, after a snapshot's or
  `refresh_with`'s content; `viewport_graphics` for a window that shows
  part of the screen, and `viewport_placements` for one that places only
  what changed from frame to frame); see the
  [host guide](../../README.md#kitty-graphics) for what is not. `kitty`
  reads a graphics command's control data as Ghostty's parser does (its
  tests check that against libghostty-vt), for the host and `cherry
  attach` to tell which commands name a file.
- Palette and dynamic colour changes (OSC 4/10/11/12), the working directory
  (OSC 7) and the title are not exported; `title()` and `pwd()` give the
  last two.
- Cursor shape (DECSCUSR block, underline or bar) is not restored; its blink
  setting is (mode 12). The pinned API exposes the shape only through the
  render state, which cannot tell a program's choice from the default.
- The contents and saved cursor of an inactive alternate screen are not
  kept.
- A saved cursor, or the primary cursor 1049 saved, loses a pending wrap
  held at a right margin inside the screen (DECSLRM); only the position is
  kept. So does the cursor when Ghostty kept its pending wrap while a resize
  moved the screen edge away from it, since no edge holds it on the replay. A
  slot that a saved cursor designates, and that the live cursor has at
  Ghostty's UTF-8 default, comes back designated ASCII, which prints the
  same.
- Hyperlink ids (`OSC 8 ; id=…`) are not restored because the cell API exposes
  only the URI; adjacent cells with the same URI become one link.
- Semantic prompt marks (OSC 133) are not restored.
- When several mouse tracking modes (9/1000/1002/1003) or mouse formats are
  set at once, they are replayed in mode-number order; the effective one is not
  exposed, so the last one the program set may not win.
- A soft-wrapped row loses its wrap flag (not its position) when its last
  cell, or the first cell of its continuation, is empty or background-only.
  A pending wrap on an empty or background-only edge cell is not restored,
  for the cursor or a saved cursor.
- The oldest retained history row is replayed as the start of a line. When it
  continues a line whose start the scrollback limit pruned, it loses its
  continuation mark; its text and position are kept. Likewise, when
  `snapshot_limited` drops all history because the cut line continues into
  the active screen, the first active row loses its continuation mark.
- A cell with a style but no text comes back as a styled space. ISO (SPA/EPA)
  protection comes back as DEC (DECSCA) protection.
- When the primary screen under an alternate screen has character-set
  designations, the alternate screen is replayed after designating ASCII in
  those slots, which prints the same as Ghostty's UTF-8 default. A wide cell
  holding a space (see above) leaves G0 designated ASCII too, and `refresh()`
  designates ASCII in every slot the session leaves at the default.
- Continuations over 1 MiB cause an explicit snapshot error. The host also
  bounds individual control strings before they reach this library.

## Validation

```
Scripts/build-host-vt
cargo test --manifest-path Host/Cargo.toml -p cherry-vt -- --test-threads=1
cargo test --manifest-path Host/Cargo.toml -p cherry-vt --test neovim -- --ignored
```

`CHERRY_GHOSTTY_VT_DIR` may point at another prefix built by the script; it
needs the same stamps.

Tests compare `Terminal::inspect()` (hidden test support): every history and
active row with its cell attributes and wrap flags, the cursor, modes, tab
stops, margins, pen, character sets and kitty flags. Saved cursors are
compared by restoring them on both terminals. `refresh()` is compared the
same way without history, on a fresh terminal and on one that followed the
session and then missed output that changed every kind of state, whose own
history must stay as it was. Tests also pin some of the
limits above: hyperlink ids, cursor shape, saved-cursor state that is not
kept, and the first row of a line whose start was pruned or dropped. Plain
screen text cannot detect rows moving between history and the active area
or lost backgrounds. The opt-in Neovim test starts real Neovim on a PTY
after some history and a cleared screen, supplies query replies,
reconstructs its screen in a second terminal, brings a third one that
followed only the shell up to date with `refresh()`, exits the editor, and
compares the terminals with the original shell screen visible again.
