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
emulator and the same PSF font (only the console's viewport: the status bar
and window frame around it are checked separately). One more QEMU, without
isa-debug-exit, stays up after `fault ud` so the on-screen report can be
dumped. Exits non-zero if any expectation fails.
Assumes ./build.sh has already been run.
"""
import argparse, os, re, select, socket, struct, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ISO = os.path.join(ROOT, "build", "wiffer.iso")
# WIFFER_UEFI=1 boots through OVMF (Homebrew qemu's edk2) instead of SeaBIOS.
FIRMWARE = []
if os.environ.get("WIFFER_UEFI"):
    _prefix = subprocess.run(["brew", "--prefix", "qemu"], capture_output=True, text=True).stdout.strip()
    FIRMWARE = ["-drive", f"if=pflash,format=raw,readonly=on,file={_prefix}/share/qemu/edk2-x86_64-code.fd"]

PROMPT = b"> "
# The prompt is coloured (Phase G): "> " wrapped in SGR escapes.
SGR = rb"(?:\x1b\[[0-9;]*m)*"
PROMPT_RE = re.compile(rb"(?:\n|\x1b\[H)" + SGR + rb"> " + SGR)

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
    # Phase D: [String: Int] shell variables.
    ("help", "set <name> <n>"),
    ("set answer 42", "> "),
    ("set neg -7", "> "),
    ("set answer 43", "> "),
    ("get answer", "43"),
    ("get neg", "-7"),
    ("get missing", "get: not set: missing"),
    ("set bad x1", "usage: set"),
    ("vars", "answer = 43\r\nneg = -7\r\n(2 variables)"),
    ("help", "mouse           PS/2 mouse"),
    # Phase G: line editing over serial with terminal escape sequences.
    # ecXX, Left x2, "ho", End, Backspace x2, " hi" -> "echo hi".
    ("ecXX\x1b[D\x1b[Dho\x1b[F\x7f\x7f hi", "\r\nhi\r\n"),
    ("cho home\x1b[He\x1b[4~!", "\r\nhome!\r\n"),           # Home = ESC[H, End = ESC[4~
    ("cho tilde\x1b[1~e", "\r\ntilde\r\n"),                  # Home = ESC[1~
    ("echo abXc\x1b[D\x1b[D\x1b[3~", "\r\nabc\r\n"),         # Delete = ESC[3~
    ("echo aXbc\x1bOD\x1bOD\x7f", "\r\nabc\r\n"),            # Left = ESC O D, backspace mid-line
    ("cho ctrl\x01e\x05!", "\r\nctrl!\r\n"),                 # Ctrl-A, Ctrl-E
    ("echo gone\x15echo kept", "\r\nkept\r\n"),              # Ctrl-U
    ("echo first", "first"),
    ("echo second", "second"),
    ("\x1b[A\x1b[A", "\r\nfirst\r\n"),                       # history: Up x2
    ("\x1b[A\x1b[A\x1b[B", "\r\nfirst\r\n"),                 # Up x2 (first, second), Down
    ("typed\x1b[A\x1b[B", "unknown command: typed"),         # Down restores the typed line
    ("upt\t", "uptime: "),                                   # tab completion, unique
    ("h\t", "halt  help  history"),                          # ambiguous: candidates listed
    ("history", "  echo first\r\n"),
    ("help", "history         list the command history"),
    ("color", "color: white (7) on black (0)"),
    ("color pink 0", "color: unknown colour: pink"),
    ("color 1", "usage: color <fg> <bg>"),
]

MOUSE_RE = re.compile(r"mouse: x=(\d+) y=(\d+) buttons=(\d+)")

# Typed on the PS/2 keyboard through the QEMU monitor (`sendkey`), so these
# exercise IRQ1 + the scancode decoder end to end: (keys, expected output).
# The shell echoes keystrokes over serial, then runs the line.
KEYBOARD_CHECKS = [
    (["e", "c", "h", "o", "spc", "h", "i", "ret"], "echo hi\r\nhi\r\n"),
    (["e", "c", "h", "o", "spc", "shift-h", "i", "shift-1", "spc", "x", "backspace", "y", "ret"],
     "\r\nHi! y\r\n"),
    # Phase G: PS/2 arrows, End, Up (history), Tab.
    (["e", "c", "h", "o", "spc", "b", "left", "a", "end", "c", "ret"], "\r\nabc\r\n"),
    (["up", "ret"], "\r\nabc\r\n"),
    (["u", "p", "t", "tab", "ret"], "uptime: "),
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
    def __init__(self, extra_args=(), monitor=False, exit_device=True):
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
                "-serial", "stdio", "-monitor", mon, *FIRMWARE, *extra_args]
        if exit_device:  # without it, a fault or selftest leaves QEMU running
            args += ["-device", "isa-debug-exit,iobase=0xf4,iosize=0x04"]
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
# The kernel's 16-colour palette (console.swift ansiColor). Console defaults:
# ANSI 7 on 0. The status bar is black on cyan; an alert is white on red.
PALETTE = [bytes(((c >> 16) & 255, (c >> 8) & 255, c & 255)) for c in [
    0x000000, 0xAA0000, 0x00AA00, 0xAA5500, 0x0000AA, 0xAA00AA, 0x00AAAA, 0xAAAAAA,
    0x555555, 0xFF5555, 0x55FF55, 0xFFFF55, 0x5555FF, 0xFF55FF, 0x55FFFF, 0xFFFFFF]]
STATUS_BG, ALERT_BG = PALETTE[6], PALETTE[1]
# Boot line giving the console's place on screen (inside the window frame,
# under the status bar).
LAYOUT_RE = re.compile(rb"console: (\d+)x(\d+) cells at row (\d+) col (\d+) of (\d+)x(\d+)")


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
    """The subset of the kernel Console that the shell uses: text, CR, LF,
    BS, tab, deferred wrap, ESC[J/H/K/A/B/C/D and SGR colours. Returns
    (grid of (char, fg, bg), row, col)."""
    fg, bg, bold = 7, 0, False

    def blank():
        return (" ", fg + 8 if bold and fg < 8 else fg, bg)

    grid = [[blank()] * cols for _ in range(rows)]
    r = c = 0

    def line_feed():
        nonlocal grid, r
        if r + 1 < rows:
            r += 1
        else:
            grid = grid[1:] + [[blank()] * cols]

    def clear(start, end):  # cell indices, end exclusive
        for i in range(start, end):
            grid[i // cols][i % cols] = blank()

    def sgr(p):
        nonlocal fg, bg, bold
        if not p:
            p = [0]
        i = 0
        while i < len(p):
            v = p[i]
            if v == 0:
                fg, bg, bold = 7, 0, False
            elif v == 1:
                bold = True
            elif v == 22:
                bold = False
            elif 30 <= v <= 37:
                fg = v - 30
            elif v == 39:
                fg = 7
            elif 40 <= v <= 47:
                bg = v - 40
            elif v == 49:
                bg = 0
            elif 90 <= v <= 97:
                fg = v - 90 + 8
            elif 100 <= v <= 107:
                bg = v - 100 + 8
            i += 1

    text = log.decode("utf-8", errors="replace")
    i = 0
    while i < len(text):
        ch = text[i]
        i += 1
        if ch == "\x1b":
            m = re.match(r"\[([0-9;?]*)([@-~])", text[i:])
            if not m:
                continue
            i += m.end()
            args, op = m.group(1).replace("?", ""), m.group(2)
            p = [int(x) if x else 0 for x in args.split(";")] if args else []
            n = (p[0] if p else 0) or 1
            here = r * cols + min(c, cols - 1)
            if op == "m":
                sgr(p)
            elif op == "J":
                mode = p[0] if p else 0
                clear(*{0: (here, rows * cols), 1: (0, here + 1)}.get(mode, (0, rows * cols)))
            elif op in "Hf":
                p += [0, 0]
                r, c = min(p[0] or 1, rows) - 1, min(p[1] or 1, cols) - 1
            elif op == "K":
                mode, start = (p[0] if p else 0), r * cols
                clear(*{0: (here, start + cols), 1: (start, here + 1)}.get(mode, (start, start + cols)))
            elif op == "A":
                r, c = max(r - n, 0), min(c, cols - 1)
            elif op == "B":
                r, c = min(r + n, rows - 1), min(c, cols - 1)
            elif op == "C":
                c = min(c + n, cols - 1)
            elif op == "D":
                c = max(min(c, cols - 1) - n, 0)
        elif ch == "\r":
            c = 0
        elif ch == "\n":
            c = 0
            line_feed()
        elif ch == "\b":
            c = max(c - 1, 0)
        elif ch == "\t":
            c = min((c // 8 + 1) * 8, cols - 1)
        elif ch >= " " and ch != "\x7f":
            if c >= cols:
                c = 0
                line_feed()
            grid[r][c] = (ch, fg + 8 if bold and fg < 8 else fg, bg)
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


def pixel(w, pix, x, y):
    o = (y * w + x) * 3
    return pix[o:o + 3]


def layout(s: Session):
    """(console cols, rows, origin row, origin col, screen cols, rows) from the boot log."""
    m = LAYOUT_RE.search(s.log)
    assert m, "no console layout line in the boot log"
    return tuple(int(g) for g in m.groups())


def check_screen(s: Session, path: str, timeout=5.0):
    """Compare the console viewport with the emulated transcript; None if it
    matches, else the first wrong cell. The status bar and window frame
    around it aren't in the transcript and are checked separately. Retries
    for a while: the kernel flushes only once it waits for input, which is
    after it has sent the prompt."""
    glyphs, gh, cmap, fallback = load_psf1(FONT)
    cols, rows, top, left, _, _ = layout(s)
    skip = set()  # cells under the mouse sprite (11x17 px) aren't text
    if s.cursor:
        x, y = s.cursor
        skip = {(r - top, c - left) for r in range(y // gh, (y + 16) // gh + 1)
                for c in range(x // 8, (x + 10) // 8 + 1)}
    deadline = time.time() + timeout
    while True:
        while True:  # take in output still in flight (e.g. the prompt's SGR)
            chunk = s._read(0.05)
            if not chunk:
                break
            s.out += chunk
        s.screendump(path)
        w, h, pix = read_ppm(path)
        grid, cr, cc = emulate(s.log, cols, rows)
        bad = None
        for r in range(rows):
            for c in range(cols):
                ch, fgi, bgi = grid[r][c]
                bits = glyphs[cmap.get(ord(ch), fallback)]
                if (r, c) in skip:
                    continue
                fg, bg = PALETTE[fgi], PALETTE[bgi]
                if (r, c) == (cr, cc):  # the cursor is drawn inverted
                    fg, bg = bg, fg
                for y in range(gh):
                    off = (((top + r) * gh + y) * w + (left + c) * 8) * 3
                    want = b"".join(fg if (bits[y] >> (7 - x)) & 1 else bg for x in range(8))
                    if pix[off: off + 24] != want:
                        bad = (r, c, ch)
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
    fault_screen = None if opts.command else Session(monitor=True, exit_device=False)
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

        # The fault report on screen: QEMU stays up (no isa-debug-exit), so
        # the display can be dumped. A white-on-red header and footer in the
        # console, and the status bar turned red.
        if fault_screen:
            fs = fault_screen
            fs.read_prompt(opts.timeout)
            fs.send("fault ud")
            got = fs.read_until(b"System halted", opts.timeout).decode(errors="replace")
            dump = os.path.join(ROOT, "build", "fault.ppm")
            time.sleep(0.3)
            fs.screendump(dump)
            w, h, pix = read_ppm(dump)
            cols, rows, top, left, _, _ = layout(fs)
            red_rows = set()
            for y in range(top * 16, (top + rows) * 16, 4):
                if pixel(w, pix, left * 8 + 1, y) == ALERT_BG:
                    red_rows.add(y // 16)
            ok = ("System halted" in got and pixel(w, pix, w - 4, 8) == ALERT_BG
                  and len(red_rows) == 2)
            failures += not ok
            print(f"{'PASS' if ok else 'FAIL'}: fault report on screen (red rows {sorted(red_rows)}), see {dump}")

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

        # Phase G: `color` changes the console's default colours on screen.
        cols, rows, top, left, scols, srows = layout(s)
        dump = os.path.join(ROOT, "build", "color.ppm")
        # The bottom-right console cell: blank (prompt lines are short).
        bx, by = (left + cols - 1) * 8 + 4, (top + rows - 1) * 16 + 8
        for cmd, want, colour in [("color yellow blue", "color: yellow on blue", 4),
                                  ("color white black", "color: white on black", 0)]:
            s.send(cmd)
            got = s.read_prompt(opts.timeout).decode(errors="replace")
            deadline, px = time.time() + 5, None
            while time.time() < deadline:
                s.screendump(dump)
                w, h, pix = read_ppm(dump)
                px = pixel(w, pix, bx, by)
                if px == PALETTE[colour]:
                    break
                time.sleep(0.25)
            ok = want in got and px == PALETTE[colour]
            failures += not ok
            print(f"{'PASS' if ok else 'FAIL'}: {cmd} (background pixel {px.hex() if px else None})"
                  + ("" if ok else f"\n  got {got!r}"))

        # Phase G4: status bar on the top row (black on cyan, the clock
        # ticking) and a window frame around the console.
        dump = os.path.join(ROOT, "build", "status.ppm")
        s.screendump(dump)
        w, h, before = read_ppm(dump)
        time.sleep(1.2)
        s.screendump(dump)
        w, h, after = read_ppm(dump)
        band = slice(0, w * 16 * 3)
        corner = [pixel(w, after, x, (top - 1) * 16 + y) for x in range(8) for y in range(16)]
        border = [pixel(w, after, x, (top + 3) * 16 + y) for x in range(8) for y in range(16)]
        ok = (pixel(w, after, w - 4, 8) == STATUS_BG and before[band] != after[band]
              and PALETTE[6] in corner and PALETTE[6] in border
              and top == 2 and left == 1 and cols == scols - 2 and rows == srows - 3)
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'}: status bar updates, window frame drawn"
              f" (console {cols}x{rows} at row {top} col {left} of {scols}x{srows})")

        # Framebuffer console: the screen must show exactly what serial got,
        # first after a clear, then after line editing (cursor moves, erases,
        # completion lists, colours), then after scrolling well past the bottom.
        dump = os.path.join(ROOT, "build", "screen.ppm")
        for label, cmds in [("after clear", ["clear", "echo screen check"]),
                            ("after editing", ["ecXX\x1b[D\x1b[Dho\x1b[F\x7f\x7f hi", "h\t",
                                               "\x1b[A", "abc\x1b[D\x1b[D\x1b[3~\x01x"]),
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
        if fault_screen:
            fault_screen.close()


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
