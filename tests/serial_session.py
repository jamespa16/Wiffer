#!/usr/bin/env python3
"""Boot the ISO headless, type commands over COM1, and check the output.

Usage:
    tests/serial_session.py                 run shell checks, then `selftest`
    tests/serial_session.py -c 'help' -c 'mem'   just print a transcript

    tests/serial_session.py -c 'help' --screendump build/screen.ppm

Each command is sent after the previous prompt ("> ") appears. Each
`fault <kind>` check boots its own QEMU (a fault halts the machine); those
boot in parallel with the main session. The main session also has a QEMU
monitor socket: the framebuffer console is checked pixel-for-pixel with
`screendump` against the serial transcript replayed through a tiny terminal
emulator and the same PSF font. Exits non-zero if any expectation fails.
Assumes ./build.sh has already been run.
"""
import argparse, os, re, select, socket, struct, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ISO = os.path.join(ROOT, "build", "wiffer.iso")

PROMPT = b"> "
PROMPT_RE = re.compile(rb"(?:\n|\x1b\[H)> ")

# (input, substring expected in the output that follows it)
CHECKS = [
    ("help", "echo <text>"),
    ("echo hello world", "hello world"),
    ("echo  spaced   out ", "spaced   out"),
    ("ehco\x7f\x7f\x7fcho fixed", "fixed"),
    ("bogus", "unknown command: bogus"),
    ("fb", "framebuffer: "),
    ("mem", "frames: "),
    ("mem", "heap: "),
    ("peek 0", "peek: address must be non-null"),
    ("peek zz", "usage: peek"),
    ("clear", "\x1b[2J"),
    ("fault", "usage: fault"),
    ("help", "uptime"),
    ("help", "mouse           PS/2 mouse"),
]

MOUSE_RE = re.compile(r"mouse: x=(\d+) y=(\d+) buttons=(\d+)")

# Typed on the PS/2 keyboard through the QEMU monitor (`sendkey`), so these
# exercise IRQ1 + the scancode decoder end to end: (keys, expected output).
# The shell echoes keystrokes over serial, then runs the line.
KEYBOARD_CHECKS = [
    (["e", "c", "h", "o", "spc", "h", "i", "ret"], "echo hi\r\nhi\r\n"),
    (["e", "c", "h", "o", "spc", "shift-h", "i", "shift-1", "spc", "x", "backspace", "y", "ret"],
     "\r\nHi! y\r\n"),
]

UPTIME_RE = re.compile(r"uptime: (\d+\.\d\d) s \((\d+) ticks\)")

# fault <kind> -> strings the exception report must contain. After the report
# the kernel writes 2 to isa-debug-exit, so QEMU exits with (2 << 1) | 1.
EXCEPTION_STATUS = 5
FAULT_CHECKS = [
    ("ud", ["*** EXCEPTION 6: #UD invalid opcode", "rip    0xffffffff8"]),
    ("de", ["*** EXCEPTION 0: #DE divide error", "rip    0xffffffff8"]),
    ("pf", ["*** EXCEPTION 14: #PF page fault", "error  0x0000000000000002",
            "cr2    0x0000700000000000"]),
    ("gp", ["*** EXCEPTION 13: #GP general protection fault", "rip    0xffffffff8"]),
    ("df", ["*** EXCEPTION 8: #DF double fault", "rsp    0x0000700000000000"]),
]


class Session:
    def __init__(self, extra_args=(), monitor=False):
        self.monitor_path = None
        self.mon = None  # connected monitor socket, opened on first use
        self.cursor = None  # mouse sprite (x, y) on screen, if known
        mon = "none"
        if monitor:  # a short path: unix socket paths are limited to ~104 bytes
            self.mondir = tempfile.mkdtemp(prefix="wiffer")
            self.monitor_path = os.path.join(self.mondir, "mon.sock")
            mon = f"unix:{self.monitor_path},server,nowait"
        args = ["qemu-system-x86_64", "-M", "q35", "-m", "256M", "-cdrom", ISO,
                "-boot", "d", "-no-reboot", "-display", "none",
                "-serial", "stdio", "-monitor", mon,
                "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04", *extra_args]
        self.p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT)
        self.out = b""
        self.log = b""  # everything received, for the screen emulator

    def _read(self, remaining):
        """Next chunk of output: None on timeout, b"" at EOF."""
        r, _, _ = select.select([self.p.stdout], [], [], remaining)
        if not r:
            return None
        chunk = os.read(self.p.stdout.fileno(), 4096)
        self.log += chunk
        return chunk

    def read_until(self, needle: bytes, timeout=10.0) -> bytes:
        if needle == PROMPT:
            return self.read_prompt(timeout)
        deadline = time.time() + timeout
        while needle not in self.out:
            remaining = deadline - time.time()
            if remaining <= 0 or self.p.poll() is not None:
                break
            chunk = self._read(remaining)
            if chunk == b"":
                break
            if chunk:
                self.out += chunk
        idx = self.out.find(needle)
        if idx < 0:
            got, self.out = self.out, b""
            return got
        got, self.out = self.out[: idx + len(needle)], self.out[idx + len(needle):]
        return got

    def read_prompt(self, timeout=10.0) -> bytes:
        """Read up to a shell prompt: "> " at line start or right after a clear."""
        deadline = time.time() + timeout
        while True:
            m = PROMPT_RE.search(self.out)
            if m:
                got, self.out = self.out[: m.end()], self.out[m.end():]
                return got
            remaining = deadline - time.time()
            if remaining <= 0 or self.p.poll() is not None:
                got, self.out = self.out, b""
                return got
            chunk = self._read(remaining)
            if chunk == b"":
                got, self.out = self.out, b""
                return got
            if chunk:
                self.out += chunk

    def send(self, text: str):
        for ch in text.encode() + b"\r":
            self.p.stdin.write(bytes([ch]))
            self.p.stdin.flush()
            time.sleep(0.005)  # don't overrun the 16-byte UART FIFO

    def monitor(self, cmd: str, timeout=10.0) -> str:
        """Run a QEMU monitor (HMP) command and return its output. QEMU's
        monitor socket takes one client, so every command shares a connection."""
        if self.mon is None:
            deadline = time.time() + timeout
            while True:
                try:
                    self.mon = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    self.mon.connect(self.monitor_path)
                    break
                except OSError:
                    self.mon.close()
                    self.mon = None
                    if time.time() > deadline:
                        raise
                    time.sleep(0.05)
            self._monitor_read(timeout)  # banner + first prompt
        self.mon.sendall(cmd.encode() + b"\n")
        return self._monitor_read(timeout)

    def _monitor_read(self, timeout) -> str:
        buf = b""
        deadline = time.time() + timeout
        while not buf.endswith(b"(qemu) "):
            remaining = deadline - time.time()
            if remaining <= 0:
                break
            r, _, _ = select.select([self.mon], [], [], remaining)
            if not r:
                break
            chunk = self.mon.recv(4096)
            if not chunk:
                break
            buf += chunk
        return buf.decode(errors="replace")

    def sendkeys(self, keys):
        for k in keys:
            self.monitor(f"sendkey {k}")
            time.sleep(0.02)

    def screendump(self, path: str, timeout=10.0):
        """Write the display to `path` (PPM); the prompt returns once written."""
        if os.path.exists(path):
            os.unlink(path)
        self.monitor(f"screendump {path}", timeout)

    def close(self):
        if self.mon is not None:
            self.mon.close()
        self.p.kill()
        self.p.wait()
        if self.monitor_path:
            if os.path.exists(self.monitor_path):
                os.unlink(self.monitor_path)
            os.rmdir(self.mondir)


# ---- Screen check: replay the serial log, render it, compare pixels ----------

FONT = os.path.join(ROOT, "fonts", "spleen-8x16.psfu")
FG, BG = (0xAA, 0xAA, 0xAA), (0, 0, 0)  # console defaults: ANSI 7 on 0


def load_psf1(path):
    """(glyph bitmaps, height, codepoint -> glyph, fallback glyph), like PSFFont."""
    d = open(path, "rb").read()
    assert d[:2] == b"\x36\x04", "not a PSF1 font"
    count, h = (512 if d[2] & 1 else 256), d[3]
    glyphs = [d[4 + g * h: 4 + (g + 1) * h] for g in range(count)]
    cmap, i, g, seq = {}, 4 + count * h, 0, False
    while d[2] & 2 and g < count and i + 1 < len(d):
        v = struct.unpack_from("<H", d, i)[0]
        i += 2
        if v == 0xFFFF:
            g, seq = g + 1, False
        elif v == 0xFFFE:
            seq = True
        elif not seq:
            cmap.setdefault(v, g)
    return glyphs, h, cmap, cmap.get(0xFFFD, cmap.get(0x3F, 0))


def emulate(log: bytes, cols: int, rows: int):
    """The subset of the kernel Console that the shell uses (ASCII, CR, LF,
    BS, tab, deferred wrap, ESC[2J, ESC[H, ESC[K). Returns (grid, row, col)."""
    grid = [[" "] * cols for _ in range(rows)]
    r = c = 0

    def line_feed():
        nonlocal grid, r
        if r + 1 < rows:
            r += 1
        else:
            grid = grid[1:] + [[" "] * cols]

    text = log.decode("ascii", errors="replace")
    i = 0
    while i < len(text):
        ch = text[i]
        i += 1
        if ch == "\x1b":
            m = re.match(r"\[([0-9;]*)([A-Za-z])", text[i:])
            if not m:
                continue
            i += m.end()
            args, op = m.group(1), m.group(2)
            p = [int(x) if x else 0 for x in args.split(";")] if args else []
            if op == "J":
                grid = [[" "] * cols for _ in range(rows)]
            elif op == "H":
                p += [0, 0]
                r, c = min(p[0] or 1, rows) - 1, min(p[1] or 1, cols) - 1
            elif op == "K":
                for x in range(min(c, cols - 1), cols):
                    grid[r][x] = " "
        elif ch == "\r":
            c = 0
        elif ch == "\n":
            c = 0
            line_feed()
        elif ch == "\b":
            c = max(c - 1, 0)
        elif ch == "\t":
            c = min((c // 8 + 1) * 8, cols - 1)
        elif " " <= ch < "\x7f":
            if c >= cols:
                c = 0
                line_feed()
            grid[r][c] = ch
            c += 1
    return grid, r, min(c, cols - 1)


def read_ppm(path):
    data = open(path, "rb").read()
    fields, pos = [], 0
    while len(fields) < 4:  # magic, width, height, maxval
        m = re.compile(rb"\s*(\S+)").match(data, pos)
        fields.append(m.group(1))
        pos = m.end()
    assert fields[0] == b"P6" and fields[3] == b"255", fields
    return int(fields[1]), int(fields[2]), data[pos + 1:]


def check_screen(s: Session, path: str, timeout=5.0):
    """Compare the display with the emulated transcript; None if it matches,
    else the first wrong cell. Retries for a while: the kernel flushes only
    once it waits for input, which is after it has sent the prompt."""
    glyphs, gh, cmap, fallback = load_psf1(FONT)
    skip = set()  # cells under the mouse sprite (11x17 px) aren't text
    if s.cursor:
        x, y = s.cursor
        skip = {(r, c) for r in range(y // gh, (y + 16) // gh + 1)
                for c in range(x // 8, (x + 10) // 8 + 1)}
    fg, bg = bytes(FG), bytes(BG)
    deadline = time.time() + timeout
    while True:
        s.screendump(path)
        w, h, pix = read_ppm(path)
        cols, rows = w // 8, h // gh
        grid, cr, cc = emulate(s.log, cols, rows)
        bad = None
        for r in range(rows):
            for c in range(cols):
                bits = glyphs[cmap.get(ord(grid[r][c]), fallback)]
                if (r, c) in skip:
                    continue
                inv = (r, c) == (cr, cc)  # the cursor is drawn inverted
                for y in range(gh):
                    off = ((r * gh + y) * w + c * 8) * 3
                    want = b"".join(fg if ((bits[y] >> (7 - x)) & 1) != inv else bg
                                    for x in range(8))
                    if pix[off: off + 24] != want:
                        bad = (r, c, grid[r][c])
                        break
                if bad:
                    break
            if bad:
                break
        if not bad or time.time() > deadline:
            return bad
        time.sleep(0.25)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-c", "--command", action="append", help="command to send (repeatable)")
    ap.add_argument("--timeout", type=float, default=10.0)
    ap.add_argument("--screendump", metavar="PPM", help="with -c: dump the display at the end")
    opts = ap.parse_args()

    # Each fault halts its machine, so every kind gets its own QEMU, booted now
    # so they run alongside the main session.
    faults = [] if opts.command else [(kind, want, Session()) for kind, want in FAULT_CHECKS]
    s = Session(monitor=True)
    try:
        boot = s.read_prompt(opts.timeout)
        if not PROMPT_RE.search(boot):
            print(boot.decode(errors="replace"))
            print("FAIL: no prompt after boot")
            return 1
        if opts.command:
            sys.stdout.write(boot.decode(errors="replace"))
            for cmd in opts.command:
                s.send(cmd)
                sys.stdout.write(s.read_prompt(opts.timeout).decode(errors="replace"))
            print()
            if opts.screendump:
                time.sleep(0.5)  # let the console flush
                s.screendump(os.path.abspath(opts.screendump))
            return 0
        failures = 0
        for cmd, want in CHECKS:
            s.send(cmd)
            got = s.read_prompt(opts.timeout).decode(errors="replace")
            ok = want in got
            failures += not ok
            print(f"{'PASS' if ok else 'FAIL'}: {cmd!r}" + ("" if ok else f"\n  wanted {want!r}\n  got {got!r}"))
        print(f"{len(CHECKS) - failures}/{len(CHECKS)} shell checks passed")

        # uptime: the tick count must grow between two calls.
        samples = []
        for _ in range(2):
            s.send("uptime")
            m = UPTIME_RE.search(s.read_prompt(opts.timeout).decode(errors="replace"))
            samples.append(int(m.group(2)) if m else None)
            time.sleep(0.3)
        ok = None not in samples and samples[1] > samples[0]
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'}: uptime advances (ticks {samples})")

        # fault <kind>: a report, then QEMU exits via isa-debug-exit.
        for kind, want, fs in faults:
            got = fs.read_prompt(opts.timeout)
            fs.send(f"fault {kind}")
            status, rest = wait_exit(fs, opts.timeout)
            got = (got + rest).decode(errors="replace")
            missing = [w for w in want if w not in got]
            ok = status == EXCEPTION_STATUS and not missing
            failures += not ok
            print(f"{'PASS' if ok else 'FAIL'}: fault {kind}" + ("" if ok else
                  f"\n  exit status {status} (want {EXCEPTION_STATUS}), missing {missing}\n  got {got!r}"))

        # PS/2 keyboard: keys typed through the monitor reach the shell.
        for keys, want in KEYBOARD_CHECKS:
            s.sendkeys(keys)
            got = s.read_prompt(opts.timeout).decode(errors="replace")
            ok = want in got
            failures += not ok
            print(f"{'PASS' if ok else 'FAIL'}: keyboard {' '.join(keys)}" + ("" if ok else
                  f"\n  wanted {want!r}\n  got {got!r}"))

        # PS/2 mouse: relative moves and a button press through the monitor.
        def mouse_state():
            s.send("mouse")
            m = MOUSE_RE.search(s.read_prompt(opts.timeout).decode(errors="replace"))
            return tuple(int(g) for g in m.groups()) if m else None
        before = mouse_state()
        s.monitor("mouse_move 40 30")
        s.monitor("mouse_button 1")
        time.sleep(0.2)
        after = mouse_state()
        s.monitor("mouse_button 0")
        ok = (before is not None and after is not None and after[0] > before[0]
              and after[1] > before[1] and after[2] == 1)
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'}: mouse moves right/down, left button ({before} -> {after})")
        if after:
            s.cursor = after[:2]

        # Mouse sprite: drawn over the console, in front of the text.
        if s.cursor:
            dump = os.path.join(ROOT, "build", "cursor.ppm")
            time.sleep(0.3)
            s.screendump(dump)
            w, h, pix = read_ppm(dump)
            x, y = s.cursor
            def px(px_x, px_y):
                o = (px_y * w + px_x) * 3
                return pix[o:o + 3]
            # Art row 4 is "XoooX": outline at col 0, fill at cols 1-3.
            ok = px(x, y + 4) == b"\0\0\0" and px(x + 2, y + 4) == b"\xff\xff\xff"
            failures += not ok
            print(f"{'PASS' if ok else 'FAIL'}: mouse sprite drawn at {s.cursor}")

        # Framebuffer console: the screen must show exactly what serial got,
        # first after a clear, then after scrolling well past the bottom.
        dump = os.path.join(ROOT, "build", "screen.ppm")
        for label, cmds in [("after clear", ["clear", "echo screen check"]),
                            ("after scrolling", ["help"] * 5 + ["echo bottom line"])]:
            for cmd in cmds:
                s.send(cmd)
                s.read_prompt(opts.timeout)
            bad = check_screen(s, dump)
            failures += bad is not None
            print(f"{'PASS' if not bad else 'FAIL'}: screen matches serial {label}" + ("" if not bad else
                  f"\n  first mismatch at row {bad[0]} col {bad[1]} (want {bad[2]!r}), see {dump}"))

        # In-kernel self-tests: QEMU exits with (code << 1) | 1.
        s.send("selftest")
        status, rest = wait_exit(s, opts.timeout)
        sys.stdout.write(rest.decode(errors="replace"))
        if status != 1:
            print(f"FAIL: selftest exit status {status} (want 1)")
            return 1
        return 1 if failures else 0
    finally:
        s.close()
        for _, _, fs in faults:
            fs.close()


def wait_exit(s: Session, timeout: float):
    """Wait for QEMU to exit, returning (status or None, remaining output)."""
    try:
        status = s.p.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        status = None
        s.p.kill()
    s.out += s.p.stdout.read() or b""
    out, s.out = s.out, b""
    return status, out


if __name__ == "__main__":
    sys.exit(main())
