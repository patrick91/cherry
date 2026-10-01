#!/usr/bin/env python3
"""An inline TUI on the primary screen, for resize tests.

    inline-tui-mimic.py MODE HISTORY_LINES LOG [START]

Prints HISTORY_LINES numbered lines, then keeps a 5-line live block at the
bottom, below which it leaves the cursor, and redraws it on every SIGWINCH.
Each size it is given is appended to LOG as "ROWSxCOLS" once its redraw is
written. With START, it draws nothing until that file exists.

MODE "ink" redraws as Ink's log-update does: it erases the lines it drew
last, moving the cursor up from where it is, and draws the block again.

MODE "claude" redraws as Claude Code's renderer does: the history and the
live block are one frame, and when the terminal gets fewer rows (or more,
with the cursor below the frame), or other columns, it erases the screen's
rows from the top (CUP, then EL 2 and CUD for each row) and draws the
frame's last rows from the top, as many as fit above the cursor's row
(from Claude Code 2.1's renderer). MODE "claude-cursor" is "claude" with
the terminal's cursor parked in the input box between draws, as Claude Code
shows it: Ghostty then grows the screen below it instead of pulling
scrollback down.
"""
import fcntl
import os
import signal
import struct
import sys
import termios
import time

mode, history_count, log_path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
BLOCK = 5
# The parked cursor is 3 rows above the row below the frame; each draw first
# moves it back down.
PARK = 3 if mode == "claude-cursor" else 0
if PARK:
    mode = "claude"


def size():
    rows, cols, _, _ = struct.unpack("HHHH", fcntl.ioctl(1, termios.TIOCGWINSZ, b"\0" * 8))
    return rows, cols


def write(text):
    os.write(1, text.encode())


def block(generation, cols):
    lines = [
        "LIVE-TOP " + "-" * max(0, min(cols, 40) - 9),
        f"LIVE status generation {generation}",
        "LIVE > input box",
        "LIVE footer one",
        "LIVE footer two",
    ]
    return [line[:cols] for line in lines]


history = [f"HISTORY {index:03d} " + "." * 20 for index in range(history_count)]
winched = False


def on_winch(_signal, _frame):
    global winched
    winched = True


signal.signal(signal.SIGWINCH, on_winch)
if len(sys.argv) > 4:
    while not os.path.exists(sys.argv[4]):
        time.sleep(0.02)
    winched = False
rows, cols = size()
generation = 0
frame = history + block(generation, cols)
# The first draw: the whole frame, each line followed by a newline, so the
# cursor waits at the start of the row below it.
write("".join(line + "\r\n" for line in frame) + (f"\x1b[{PARK}A\x1b[9G" if PARK else ""))
viewport = rows


def log(rows, cols):
    with open(log_path, "a") as handle:
        stamp = f" @{time.time():.4f}" if os.environ.get("MIMIC_TIMESTAMPS") else ""
        handle.write(f"{rows}x{cols}{stamp}\n")


log(rows, cols)
while True:
    if not winched:
        time.sleep(0.02)
        continue
    winched = False
    new_rows, new_cols = size()
    generation += 1
    live = block(generation, new_cols)
    if PARK:
        write(f"\x1b[{PARK}B\r")
    if mode == "ink":
        # eraseLines(BLOCK + 1): the cursor's row and the block's, upwards.
        erase = "\x1b[2K" + "\x1b[1A\x1b[2K" * BLOCK + "\x1b[G"
        write(erase + "".join(line + "\r\n" for line in live))
    else:
        previous_frame_height = len(frame)
        frame = history + live
        if new_rows != viewport or new_cols != cols:
            # Claude Code's reset (`clearTerminal` with the new viewport's
            # rows; it grows with the cursor below the frame), and the
            # frame's rows from `x` on.
            hidden = max(0, previous_frame_height - min(viewport, new_rows))
            start = min(hidden + 1, max(0, len(frame) - new_rows + 1))
            erase = "\x1b[H" + "\x1b[2K\x1b[1B" * new_rows + "\x1b[H"
            write(erase + "".join(line[:new_cols] + "\r\n" for line in frame[start:]))
        else:
            write("\x1b[G")
    if PARK:
        write(f"\x1b[{PARK}A\x1b[9G")
    viewport, cols = new_rows, new_cols
    log(new_rows, new_cols)
