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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fat32  # Phase Z: the host-side FAT32 tool (formats and checks images)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ISO = os.path.join(ROOT, "build", "wiffer.iso")  # boots into the desktop
NODESKTOP_ISO = os.path.join(ROOT, "build", "wiffer-nodesktop.iso")  # cmdline `nodesktop`
# WIFFER_UEFI=1 boots through OVMF instead of SeaBIOS: WIFFER_OVMF (run.sh sets
# it), else Homebrew qemu's edk2.
FIRMWARE = []
if os.environ.get("WIFFER_UEFI"):
    _ovmf = os.environ.get("WIFFER_OVMF")
    if not _ovmf:
        _prefix = subprocess.run(["brew", "--prefix", "qemu"], capture_output=True, text=True).stdout.strip()
        _ovmf = f"{_prefix}/share/qemu/edk2-x86_64-code.fd"
    FIRMWARE = ["-drive", f"if=pflash,format=raw,readonly=on,file={_ovmf}"]

# Virtual CPU count for every QEMU (run.sh --smp N sets WIFFER_SMP).
SMP = os.environ.get("WIFFER_SMP", "4")

# Part 7: every QEMU gets a legacy virtio-net NIC on QEMU's user-mode (SLIRP)
# network, unless run.sh --nonet (WIFFER_NONET=1) or Session(net=False).
NONET = bool(os.environ.get("WIFFER_NONET"))
NET_ARGS = ["-netdev", "user,id=n0",
            "-device", "virtio-net-pci,netdev=n0,disable-legacy=off,disable-modern=on"]

# Phase V: the main session gets a fresh 64 MiB scratch disk (never
# build/disk.img) as a legacy virtio-blk device, unless run.sh --nodisk
# (WIFFER_NODISK=1) or --nodisk here. Phase Y: it's FAT32 (made by
# fat32.mkfs, with a host-written /hello.txt), so the kernel mounts it at
# /disk.
DISK_MIB = 64
HOST_HELLO = b"hello from the host\n"
def disk_args(path):
    return ["-drive", f"file={path},if=none,id=vd0,format=raw",
            "-device", "virtio-blk-pci,drive=vd0,disable-legacy=off,disable-modern=on"]

def scratch_disk(mib=DISK_MIB, fat=True):
    """A raw image in a new temp dir: (path, dir to remove). FAT32 with
    /hello.txt, or with fat=False all zeros."""
    d = tempfile.mkdtemp(prefix="wifferdisk")
    path = os.path.join(d, "scratch.img")
    if fat:
        fat32.mkfs(path, mib << 20, "WIFFER")
        fat32.write_file(path, "/hello.txt", HOST_HELLO)
    else:
        with open(path, "wb") as f:
            f.truncate(mib << 20)
    return path, d

def remove_disk(path, d):
    if os.path.exists(path):
        os.unlink(path)
    os.rmdir(d)

# Phase V: PCI and the disk, when the main session has one. Phase Y: /disk
# is the FAT32 scratch image (write, mkdir, mv, rm, df, fsck, disks).
DISK_CHECKS = [
    ("lspci", "1af4:1001 01.00"),
    ("lspci", "00:00.0 8086:29c0 06.00 host bridge"),
    ("disks", "vda   64 MiB    131072"),
    ("help", "disks           list block devices"),
    ("disks", "  /disk\r\n"),
    ("mount", "vda on /disk: FAT32 'WIFFER'"),
    ("cat /disk/hello.txt", "hello from the host"),
    ("cat /disk/HELLO.TXT", "hello from the host"),
    ("write /disk/w.txt written here", "> "),
    ("cat /disk/w.txt", "\r\nwritten here\r\n"),
    ("mkdir /disk/dir", "> "),
    ("mv /disk/w.txt /disk/dir", "> "),
    ("cat /disk/dir/w.txt", "\r\nwritten here\r\n"),
    ("cat /disk/w.txt", "cat: /disk/w.txt: no such file or directory"),
    ("mv /disk/dir/w.txt /", "mv: /disk/dir/w.txt: can't move across filesystems"),
    ("rm /disk/dir", "rm: /disk/dir: directory not empty"),
    ("rm /disk", "rm: /disk: mount point busy"),
    ("rm -r /disk/dir", "> "),
    ("ls /disk/dir", "ls: /disk/dir: no such file or directory"),
    ("write /disk/kept.txt kept for the host", "> "),
    ("mkdir /disk/Sub", "> "),
    ("mkdir /disk/sub", "mkdir: /disk/sub: already exists"),
    ("df", "/disk: vda 'WIFFER', 0.0 of 63.0 MiB used, 129008 clusters of 512 bytes"),
    ("sync", "> "),
    ("fsck /disk", "fsck: /disk: clean"),
    ("help", "umount <dir>    sync and unmount a disk"),
]
NODISK_CHECKS = [
    ("disks", "no disks"),
    ("lspci", "00:00.0 8086:29c0 06.00 host bridge"),
    ("ls /disk", "ls: /disk: no such file or directory"),
    ("mount", "> "),
]

PROMPT = b"> "


def boot_timeout(timeout: float) -> float:
    """The wait for the first prompt. Up to a dozen QEMUs boot at once (fault
    checks, desktop/editor/terminal sessions, Phase Y's disk boots), and
    under OVMF with -smp 4 that load pushed boots past 10 s. A pass returns
    as soon as the prompt shows, so the long ceiling costs nothing."""
    return max(timeout, 60.0)
# The prompt is coloured (Phase G): "> " wrapped in SGR escapes.
SGR = rb"(?:\x1b\[[0-9;]*m)*"
PROMPT_RE = re.compile(rb"(?:\n|\x1b\[H)" + SGR + rb"> " + SGR)

def _readme_wc():
    data = open(os.path.join(ROOT, "rootfs", "README"), "rb").read()
    lines, words = data.count(b"\n"), len(data.split())
    return f"{lines} {words} {len(data)}"

README_WC = _readme_wc()  # what /bin/wc prints for /README

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
    ("help", "count primes below n"),
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
    # Phase J: compositor stats.
    ("gfx", " layers, last frame "),
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
    # Phase M: RAM filesystem seeded from the rootfs.tar Limine module.
    ("cat /README", "Wiffer RAM filesystem\r\n\r\nThese files were packed into rootfs.tar"),
    ("ls /", "  README\r\n"),
    ("ls /src", "  hello.swift\r\n"),
    ("cat /src/hello.swift", "struct Greeter {"),
    ("mkdir /tmp", "> "),
    ("cd /tmp", "> "),
    ("write note hello  file", "> "),
    ("pwd", "\r\n/tmp\r\n"),
    ("cat note", "\r\nhello  file\r\n"),
    ("mv note ../moved", "> "),
    ("cd ..", "> "),
    ("cat moved", "\r\nhello  file\r\n"),
    ("rm moved tmp", "> "),
    ("cat /moved", "cat: /moved: no such file or directory"),
    # README, motd, src/hello.swift, 13 files in /fonts (Part 8), and
    # Phase 6C's 5 programs in /bin.
    ("df", "bytes in 21 files, 4 directories"),
    # Phase 6C: programs from /bin run in ring 3; crashes are reported and
    # the shell carries on.
    ("ls /bin", "  hello\r\n"),
    ("hello", "\r\nHello from ring 3!\r\n"),
    ("args one two", "argc=3\r\nargv[0]=args\r\nargv[1]=one\r\nargv[2]=two\r\n"),
    ("alloc", "alloc: checksum 67415360436"),
    ("crash null", "(crash): page fault at 0x8, rip 0x100_0000_"),
    ("crash ud", "(crash): invalid opcode, rip 0x100_0000_"),
    ("crash hlt", "(crash): general protection fault, rip 0x100_0000_"),
    ("crash stack", "(crash): page fault at 0x7f7f_ffef_f"),
    ("crash exit", "crash: exit status 3"),
    ("echo still here", "\r\nstill here\r\n"),
    ("/bin/hello", "Hello from ring 3!"),
    ("nosuchprog", "unknown command: nosuchprog"),
    ("help", "ps              list processes"),
    ("kill 9999", "kill: no such process: 9999"),
    # Phase 6E: the ported commands give the built-ins' output.
    ("/bin/ls /src", "  hello.swift\r\n"),
    ("/bin/ls /", "  README\r\n"),
    ("/bin/ls /nosuch", "ls: /nosuch: no such file or directory"),
    ("/bin/cat /src/hello.swift", "struct Greeter {"),
    ("/bin/cat /moved", "cat: /moved: no such file or directory"),
    ("/bin/echo hello world", "hello world"),
    ("/bin/wc /README", f"{README_WC} /README"),
    ("/bin/hexdump /motd", "00000000  57 65 6c 63 6f 6d 65 20  74 6f 20 57 69 66 66 65  |Welcome to Wiffe|"),
    # Pipelines: every stage is a program (a bare name is /bin/<name>).
    ("/bin/cat /README | /bin/wc", f"\r\n{README_WC}\r\n"),
    ("cat /README | wc", f"\r\n{README_WC}\r\n"),
    ("cat /README | cat | cat | wc", f"\r\n{README_WC}\r\n"),
    ("cat /README | hexdump", "|Wiffer RAM files|"),
    ("cat /README | nosuchprog", "nosuchprog: command not found"),
    ("cat /README |", "syntax error: empty command in pipeline"),
    ("/bin/iotest", " 0 failed"),
    ("/bin/iotest /disk", " 0 failed"),
    ("echo after the programs", "\r\nafter the programs\r\n"),
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

# Phase K: `windows` output and the WM's decoration colours (window.swift).
WINDOW_RE = re.compile(r"window #(\d+) x=(-?\d+) y=(-?\d+) w=(\d+) h=(\d+)( focused)? '([^']*)'")
BUTTON_RE = re.compile(r"button x=(\d+) y=(\d+) w=(\d+) h=(\d+) '([^']*)'")
TITLE_FOCUSED, TITLE_UNFOCUSED = bytes.fromhex("1E5AA8"), bytes.fromhex("3C3C3C")
TASKBAR_BG = bytes.fromhex("202830")
# Phase N: EditorColors (editor_window.swift).
EDITOR_GUTTER_BG, EDITOR_STATUS_BG = bytes.fromhex("2B303B"), bytes.fromhex("2E7D32")

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
# Phase S: a fault on an AP (CPU 1) stops the others and reports its CPU.
if int(SMP) >= 2:
    FAULT_CHECKS.append(("ap", ["*** EXCEPTION 6: #UD invalid opcode", "cpu    1", "rip    0xffffffff8"]))


class Session:
    def __init__(self, extra_args=(), monitor=False, exit_device=True, iso=ISO, net=True):
        self.monitor_path = None
        self.mon = None  # connected monitor socket, opened on first use
        self.cursor = None  # mouse sprite (x, y) on screen, if known
        mon = "none"
        if monitor:  # a short path: unix socket paths are limited to ~104 bytes
            self.mondir = tempfile.mkdtemp(prefix="wiffer")
            self.monitor_path = os.path.join(self.mondir, "mon.sock")
            mon = f"unix:{self.monitor_path},server,nowait"
        args = ["qemu-system-x86_64", "-M", "q35", "-m", "256M", "-cpu", "max", "-smp", SMP, "-cdrom", iso,
                "-boot", "d", "-no-reboot", "-display", "none",
                "-serial", "stdio", "-monitor", mon, *FIRMWARE, *extra_args]
        if net and not NONET:
            args += NET_ARGS
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

    # ---- Phase K: driving the desktop ----

    def command(self, cmd: str, timeout=10.0) -> str:
        """Type a shell command over serial; its output up to the next prompt."""
        self.send(cmd)
        return self.read_prompt(timeout).decode(errors="replace")

    def warp(self, x: int, y: int):
        """Put the kernel's pointer at (x, y) (the `warp` command): QEMU's
        mouse_move is relative and may be scaled, so absolute positions come
        from the kernel."""
        got = self.command(f"warp {x} {y}")
        assert f"warp: x={x} y={y}" in got, got

    def pointer(self):
        """The kernel's idea of the pointer: (x, y, buttons)."""
        m = MOUSE_RE.search(self.command("mouse"))
        return tuple(int(g) for g in m.groups()) if m else None

    def click(self, x: int, y: int):
        """Left click at (x, y): warp there, then press and release through
        the monitor (mouse_button sends a packet without movement)."""
        self.warp(x, y)
        self.monitor("mouse_button 1")
        time.sleep(0.15)
        self.monitor("mouse_button 0")
        time.sleep(0.15)

    def drag(self, frm, by):
        """Press at `frm`, move by `by` with mouse_move (relative, maybe
        scaled), release. Returns where the kernel says the pointer ended."""
        self.warp(*frm)
        self.monitor("mouse_button 1")
        time.sleep(0.15)
        self.monitor(f"mouse_move {by[0]} {by[1]}")
        time.sleep(0.2)
        end = self.pointer()
        self.monitor("mouse_button 0")
        time.sleep(0.15)
        return end[:2] if end else None

    def windows(self):
        """`windows`: ({id: (x, y, w, h, focused, title)}, [(x, y, w, h, label)])."""
        out = self.command("windows")
        wins = {int(m[0]): (int(m[1]), int(m[2]), int(m[3]), int(m[4]), bool(m[5]), m[6])
                for m in WINDOW_RE.findall(out)}
        buttons = [(int(m[0]), int(m[1]), int(m[2]), int(m[3]), m[4]) for m in BUTTON_RE.findall(out)]
        return wins, buttons

    def pixel_at(self, x: int, y: int, path: str):
        """The pixel at (x, y) of a fresh screendump (RGB bytes)."""
        self.screendump(path)
        w, h, pix = read_ppm(path)
        return pixel(w, pix, x, y)

    def wait_pixel(self, x: int, y: int, want, path: str, timeout=3.0, equal=True):
        """Poll screendumps until the pixel at (x, y) is (or, with
        equal=False, isn't) `want`; returns the last pixel seen."""
        deadline = time.time() + timeout
        while True:
            px = self.pixel_at(x, y, path)
            if (px == want) == equal or time.time() > deadline:
                return px
            time.sleep(0.2)

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
    ap.add_argument("--nodesktop", action="store_true", help="with -c: boot the full-screen shell")
    ap.add_argument("--nodisk", action="store_true", default=bool(os.environ.get("WIFFER_NODISK")),
                    help="no scratch virtio disk on the main session")
    opts = ap.parse_args()
    print(f"harness: -smp {SMP}" + (", no disk" if opts.nodisk else f", {DISK_MIB} MiB scratch disk"))
    disk, disk_dir = (None, None) if opts.nodisk else scratch_disk()

    # Each fault halts its machine, so every kind gets its own QEMU, booted now
    # so they run alongside the main session.
    faults = [] if opts.command else [(kind, want, Session()) for kind, want in FAULT_CHECKS]
    # (Faults and the fault screen boot the default ISO: the desktop, with
    # the shell in a terminal window; the report bypasses the compositor.)
    fault_screen = None if opts.command else Session(monitor=True, exit_device=False)
    # The Part 2 checks (full-screen shell, screen vs serial, selftest) boot
    # the `nodesktop` entry (Phase L).
    s = Session(monitor=True, iso=NODESKTOP_ISO if opts.nodesktop or not opts.command else ISO,
                extra_args=disk_args(disk) if disk else ())
    # Phase K runs on its own machine: `desktop` switches the full-screen
    # shell to the WM (the console becomes window #1).
    desk = None if opts.command else Session(monitor=True, iso=NODESKTOP_ISO)
    ed = None if opts.command else Session(monitor=True)  # Phase N, in the boot desktop
    term = None if opts.command else Session(monitor=True)  # Phase L, in the boot desktop
    # Phase Y: persistence (boot 1 of 2, in the desktop, on its own FAT32
    # image) and mkfs on a blank image. Not with --nodisk.
    persist = blank = None
    if not opts.command and not opts.nodisk:
        persist_img = scratch_disk()
        persist = Session(monitor=True, extra_args=disk_args(persist_img[0]))
        blank_img = scratch_disk(fat=False)
        blank = Session(iso=NODESKTOP_ISO, extra_args=disk_args(blank_img[0]))
    try:
        boot = s.read_prompt(boot_timeout(opts.timeout))
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

        disk_failures = 0
        for cmd, want in (NODISK_CHECKS if opts.nodisk else DISK_CHECKS):
            s.send(cmd)
            got = s.read_prompt(opts.timeout).decode(errors="replace")
            ok = want in got
            disk_failures += not ok
            print(f"{'PASS' if ok else 'FAIL'}: {cmd!r} (disk)" + ("" if ok else f"\n  wanted {want!r}\n  got {got!r}"))
        failures += disk_failures

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

        failures += smp_checks(s, opts.timeout)
        failures += process_checks(s, opts.timeout)
        failures += program_io_checks(s, opts.timeout, "6E")
        failures += net_checks(s, opts.timeout)

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

        if desk:
            failures += desktop_checks(desk, opts.timeout)
        if ed:
            failures += editor_checks(ed, opts.timeout)
        if term:
            failures += terminal_checks(term, opts.timeout)
        if blank:
            failures += mkfs_checks(blank, blank_img[0], opts.timeout)
        if persist:
            failures += persistence_checks(persist, persist_img[0], opts.timeout)

        # The boot mounted the scratch image (or, with --nodisk, there was none).
        mounted = b"vda: FAT32 'WIFFER' mounted at /disk" in s.log
        ok = mounted != opts.nodisk
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'}: boot " + ("left /disk out (no disk)" if opts.nodisk else
              "mounted vda at /disk"))

        # In-kernel self-tests: QEMU exits with (code << 1) | 1.
        s.send("selftest")
        status, rest = wait_exit(s, opts.timeout)
        sys.stdout.write(rest.decode(errors="replace"))
        if status != 1:
            print(f"FAIL: selftest exit status {status} (want 1)")
            return 1
        # Phase Y: the scratch image, written by the kernel, read on the host.
        if disk:
            problems = fat32.fsck(disk)
            kept = fat32.read_file(disk, "/kept.txt")
            # (OVMF keeps its emulated variable store in NvVars on any FAT
            # volume it finds, so a UEFI boot adds that file.)
            names = sorted(e.name for e in fat32.list_dir(disk) if e.name != "NvVars")
            ok = not problems and kept == b"kept for the host\n" and names == ["Sub", "hello.txt", "kept.txt"]
            failures += not ok
            print(f"{'PASS' if ok else 'FAIL'}: host reads the main session's /disk (fsck clean, kept.txt)"
                  + ("" if ok else f"\n  problems {problems}, kept {kept!r}, names {names}"))
        return 1 if failures else 0
    finally:
        s.close()
        if disk_dir:
            remove_disk(disk, disk_dir)
        for sess, img in ((persist, persist_img if persist else None), (blank, blank_img if blank else None)):
            if sess:
                sess.close()
                remove_disk(*img)
        for _, _, fs in faults:
            fs.close()
        if fault_screen:
            fault_screen.close()
        if desk:
            desk.close()
        if ed:
            ed.close()
        if term:
            term.close()


def fake_dns_server():
    """Part 7C: a UDP DNS responder on the host (127.0.0.1, ephemeral port).
    The guest reaches it at 10.0.2.2:<port> (SLIRP maps the gateway address to
    the host), so `host <name> 10.0.2.2:<port>` works without touching
    SLIRP's own DNS forwarder. Returns (port, stop). Besides good answers it
    serves hostile ones: a self-referencing compression pointer, a truncated
    reply and an oversize rdlength, which the guest must reject cleanly."""
    import threading
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("127.0.0.1", 0))
    sock.settimeout(0.2)
    port = sock.getsockname()[1]
    stopping = threading.Event()

    def labels(name):
        return b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\0"

    def reply(query, answers, rcode=0):
        qend = 12
        while query[qend] != 0:
            qend += query[qend] + 1
        question = query[12:qend + 5]
        head = query[:2] + bytes([0x81, 0x80 | rcode]) + b"\0\1" + len(answers).to_bytes(2, "big") + b"\0\0\0\0"
        return head + question + b"".join(answers)

    def a_rr(owner, ip, ttl=60):
        return owner + b"\0\1\0\1" + ttl.to_bytes(4, "big") + b"\0\4" + bytes(map(int, ip.split(".")))

    def serve():
        while not stopping.is_set():
            try:
                data, addr = sock.recvfrom(512)
            except socket.timeout:
                continue
            except OSError:
                return
            if len(data) < 17:
                continue
            i, parts = 12, []
            while data[i]:
                parts.append(data[i + 1:i + 1 + data[i]].decode())
                i += data[i] + 1
            name = ".".join(parts).lower()
            me = b"\xc0\x0c"
            if name == "test.wiffer.example":
                out = reply(data, [a_rr(me, "192.0.2.77")])
            elif name == "www.wiffer.example":
                target = labels("test.wiffer.example")
                cname = me + b"\0\5\0\1" + (60).to_bytes(4, "big") + len(target).to_bytes(2, "big") + target
                out = reply(data, [cname, a_rr(labels("test.wiffer.example"), "192.0.2.77")])
            elif name == "nx.wiffer.example":
                out = reply(data, [], rcode=3)
            elif name == "loop.wiffer.example":
                # The answer's owner name is a pointer to itself.
                pos = len(reply(data, []))
                out = reply(data, [bytes([0xC0 | pos >> 8, pos & 255]) + b"\0\1\0\1\0\0\0\x3c\0\4\1\2\3\4"])
            elif name == "trunc.wiffer.example":
                out = reply(data, [a_rr(me, "192.0.2.78")])[:-3]
            elif name == "huge.wiffer.example":
                out = reply(data, [me + b"\0\1\0\1\0\0\0\x3c\xff\xff\1\2\3\4"])
            else:
                continue
            sock.sendto(out, addr)

    thread = threading.Thread(target=serve, daemon=True)
    thread.start()

    def stop():
        stopping.set()
        thread.join(1.0)
        sock.close()
    return port, stop


def net_checks(s: Session, timeout: float) -> int:
    """Part 7 (7A-7C) on the machine: virtio-net comes up, DHCP gives
    10.0.2.15, the gateway answers ping, and the resolver talks to a fake DNS
    server on the host (and survives hostile replies)."""
    if NONET:
        print("harness: --nonet, network checks skipped")
        return 0
    failures = 0
    def check(ok, label, detail=""):
        nonlocal failures
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'}: {label}" + ("" if ok else f"\n  {detail}"))
        return ok
    got = s.command("lspci", timeout)
    check("1af4:1000" in got and "network" in got, "net: lspci shows the virtio-net function (1af4:1000)", repr(got))
    deadline = time.time() + 20
    got = ""
    while time.time() < deadline:
        got = s.command("ifconfig", timeout)
        if "dhcp: lease from" in got:
            break
        time.sleep(0.5)
    check("inet 10.0.2.15" in got and "gateway 10.0.2.2" in got and "dhcp: lease from 10.0.2.2" in got
          and "52:54:00:12:34:56" in got, "net: ifconfig shows the DHCP lease (10.0.2.15) and the MAC", repr(got))
    check(re.search(r"rx [1-9]\d* frames", got) is not None, "net: eth0 received frames", repr(got))
    got = s.command("ping -c 3 10.0.2.2", 20.0)
    check("3 packets transmitted, 3 received, 0% packet loss" in got and "icmp_seq=3" in got,
          "net: ping -c 3 10.0.2.2", repr(got))
    got = s.command("arp", timeout)
    check("10.0.2.2 at " in got, "net: the gateway is in the ARP cache", repr(got))
    port, stop = fake_dns_server()
    try:
        srv = f"10.0.2.2:{port}"
        got = s.command(f"host test.wiffer.example {srv}", 20.0)
        check("test.wiffer.example has address 192.0.2.77" in got, "net: host resolves through the fake DNS server", repr(got))
        got = s.command(f"host www.wiffer.example {srv}", 20.0)
        check("www.wiffer.example is an alias for test.wiffer.example." in got
              and "test.wiffer.example has address 192.0.2.77" in got, "net: host follows a CNAME", repr(got))
        got = s.command(f"host nx.wiffer.example {srv}", 20.0)
        check("not found: NXDOMAIN" in got, "net: host reports NXDOMAIN", repr(got))
        for name in ("loop", "trunc", "huge"):
            # Hostile replies are ignored; the query times out (3 x 2 s) and the kernel lives on.
            got = s.command(f"host {name}.wiffer.example {srv}", 30.0)
            check("not found" in got and "timed out" in got, f"net: a hostile '{name}' reply fails cleanly", repr(got))
        got = s.command("ping -c 1 10.0.2.2", 20.0)
        check("1 packets transmitted, 1 received" in got, "net: the stack still answers after hostile DNS replies", repr(got))
    finally:
        stop()
    return failures


def process_checks(s: Session, timeout: float) -> int:
    """Phase 6C: a background `spin` shows in `ps` and `kill` stops it (it
    runs on an AP: without 6D's preemption a spin on CPU 0 can't be killed)."""
    failures = 0
    def check(ok, label, detail=""):
        nonlocal failures
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'}: {label}" + ("" if ok else f"\n  {detail}"))
        return ok
    if int(SMP) < 2:
        return 0
    got = s.command("spin &", timeout)
    m = re.search(r"\[(\d+)\]", got)
    if not check(m is not None, "6C: spin & prints its pid", repr(got)):
        return failures
    pid = m.group(1)
    time.sleep(0.3)
    got = s.command("ps", timeout)
    check(re.search(rf"^\s*{pid}\s+0\s+running\s+\d+\s+spin\r?$", got, re.M) is not None,
          "6C: ps lists the running spin", repr(got))
    s.command(f"kill {pid}", timeout)
    gone = False
    for _ in range(20):
        got = s.command("ps", timeout)
        if not re.search(rf"^\s*{pid}\s", got, re.M):
            gone = True
            break
        time.sleep(0.1)
    check(gone, "6C: kill stops it (gone from ps)", repr(got))
    got = s.command("hello", timeout)
    check("Hello from ring 3!" in got, "6C: the shell still runs programs after kill", repr(got))
    return failures


def program_io_checks(s: Session, timeout: float, where: str) -> int:
    """Phase 6E: programs reading the terminal (cooked lines, Ctrl-D), a
    pipeline waiting on it, and Ctrl-C killing a `spin` (on CPU 1: until 6D
    nothing interrupts a ring-3 spin on CPU 0), typed over serial."""
    failures = 0
    def check(ok, label, detail=""):
        nonlocal failures
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'}: {where}: {label}" + ("" if ok else f"\n  {detail}"))
        return ok
    def ctrl(ch: int):
        s.p.stdin.write(bytes([ch]))
        s.p.stdin.flush()
    # /bin/cat reads the terminal: the line is echoed, then cat prints it.
    s.send("/bin/cat")
    time.sleep(0.3)
    s.send("typed line")
    time.sleep(0.3)
    ctrl(0x04)  # Ctrl-D on an empty line: end of file
    got = s.read_prompt(timeout).decode(errors="replace")
    check("typed line\r\ntyped line\r\n" in got, "cat reads a cooked line from the terminal", repr(got))
    # Backspace edits the line.
    s.send("/bin/cat")
    time.sleep(0.3)
    s.p.stdin.write(b"abx\x7fc\r")
    s.p.stdin.flush()
    time.sleep(0.3)
    ctrl(0x04)
    got = s.read_prompt(timeout).decode(errors="replace")
    check("abc\r\n" in got.replace("abx\x08 \x08c", "abc"), "Backspace edits the line before cat sees it", repr(got))
    # A pipeline whose first stage reads the terminal.
    s.send("/bin/cat | /bin/wc")
    time.sleep(0.3)
    s.send("one two")
    time.sleep(0.3)
    ctrl(0x04)
    got = s.read_prompt(timeout).decode(errors="replace")
    check("\r\n1 2 8\r\n" in got, "cat | wc ends on Ctrl-D and counts the line", repr(got))
    if int(SMP) >= 2:
        s.command("set affinity 1", timeout)
        s.send("spin")
        time.sleep(0.5)
        ctrl(0x03)
        got = s.read_prompt(timeout).decode(errors="replace")
        check("^C" in got and "(spin): killed" in got, "Ctrl-C kills a running spin", repr(got))
        s.send("/bin/cat | /bin/spin")
        time.sleep(0.5)
        ctrl(0x03)
        got = s.read_prompt(timeout).decode(errors="replace")
        check("^C" in got and "(spin): killed" in got, "Ctrl-C kills a whole pipeline", repr(got))
        s.command("set affinity -1", timeout)
    got = s.command("echo shell is back", timeout)
    check("\r\nshell is back\r\n" in got, "the shell carries on", repr(got))
    got = s.command("ps", timeout)
    check(len(re.findall(r"^\s*\d+\s+\d+\s", got, re.M)) == 0, "no processes left", repr(got))
    return failures


def smp_checks(s: Session, timeout: float) -> int:
    """Phase T: `cpus` and `par` agree with the -smp count; `par` finds the
    right number of primes, spread over more than one CPU when there is one."""
    failures = 0
    def check(ok, label, detail=""):
        nonlocal failures
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'}: {label}" + ("" if ok else f"\n  {detail}"))
        return ok
    n_cpus = int(SMP)
    got = s.command("cpus", timeout)
    rows = re.findall(r"^(\d+)  \d+  yes  ", got, re.M)
    check(len(rows) == n_cpus, f"smp: `cpus` lists {n_cpus} online CPU(s)", repr(got))
    got = s.command("par 1000000", 60.0)
    # Each worker lists every CPU it ran on (it yields per chunk, so it may
    # migrate); the union is what shows the work spread.
    workers = [(int(w), {int(x) for x in c.split(",")}, int(p)) for w, c, p in
               re.findall(r"worker (\d+)  cpus ([\d,]+)  primes (\d+)", got)]
    total = re.search(r"parallel: (\d+) primes in (\d+) ticks", got)
    single = re.search(r"single:\s+(\d+) primes in (\d+) ticks", got)
    # pi(1000000) = 78498
    check(total and single and int(total.group(1)) == 78498 and int(single.group(1)) == 78498
          and sum(p for _, _, p in workers) == 78498 and "ERROR" not in got,
          "smp: par 1000000 finds 78498 primes in parallel and single", repr(got))
    check(len(workers) == n_cpus, f"smp: par runs {n_cpus} worker(s)", repr(got))
    cpus_used = set().union(*(c for _, c, _ in workers))
    if n_cpus >= 2:
        check(len(cpus_used) > 1, f"smp: par workers ran on several CPUs ({sorted(cpus_used)})", repr(got))
    check(re.search(r"speedup: \d+\.\d\d", got) is not None,
          "smp: par prints a speedup line", repr(got))
    got = s.command("par 200000", 60.0)
    check("parallel: 17984 primes" in got and "single:   17984 primes" in got, "smp: par 200000 finds 17984 primes", repr(got))
    got = s.command("par x", timeout)
    check("usage: par" in got, "smp: par rejects a bad count", repr(got))
    return failures


def desktop_checks(s: Session, timeout: float) -> int:
    """Phase K end to end: switch to the desktop, open two windows (Ctrl-Alt-T
    and the taskbar's + Terminal), drag one by its title bar, click to swap
    focus, resize, close one with its close box and one with Alt-F4, Alt-Tab
    in between, checking each step with `windows`, the WM's serial log and
    screendumps."""
    failures = 0
    dump = os.path.join(ROOT, "build", "desktop.ppm")

    def check(ok, label, detail=""):
        nonlocal failures
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'}: desktop: {label}" + ("" if ok or not detail else f"\n  {detail}"))
        return ok

    def title_px(win):  # inside the title bar, left of the title text
        return win[0] + 4, win[1] + 12

    def title_px_right(win):  # inside the title bar, just left of the close box
        return win[0] + win[2] - 24, win[1] + 12

    boot = s.read_prompt(boot_timeout(timeout))
    got = s.command("desktop")
    if not check("desktop: on" in got and PROMPT_RE.search(boot), "desktop command", repr(got)):
        return failures
    wins, buttons = s.windows()
    check(list(wins) == [1] and wins[1][4] and wins[1][5] == "Wiffer shell"
          and [b[4] for b in buttons] == ["+ Terminal", "+ Editor", "#1"],
          "console is window #1, taskbar buttons", f"{wins} {buttons}")
    tx, ty = buttons[0][0] + buttons[0][2] // 2, buttons[0][1] + buttons[0][3] // 2
    check(s.wait_pixel(*title_px(wins[1]), TITLE_FOCUSED, dump) == TITLE_FOCUSED
          and s.pixel_at(tx, ty, dump) != TASKBAR_BG and s.pixel_at(tx, buttons[0][1] - 1, dump) == TASKBAR_BG,
          "console window decorated, taskbar drawn")

    # Two windows: Ctrl-Alt-T on the PS/2 keyboard, then the + Terminal button.
    s.sendkeys(["ctrl-alt-t"])
    check(b"wm: open #2" in s.read_until(b"wm: focus #2", timeout), "Ctrl-Alt-T opens window #2")
    s.click(tx, ty)
    check(b"wm: open #3" in s.read_until(b"wm: focus #3", timeout), "+ Terminal opens window #3")
    wins, _ = s.windows()
    w2, w3 = wins.get(2), wins.get(3)
    if not check(w2 and w3 and w3[4] and not w2[4], "two windows, the newer focused", str(wins)):
        return failures
    p2 = s.wait_pixel(*title_px(w2), TITLE_UNFOCUSED, dump)
    p3 = s.pixel_at(*title_px(w3), dump)
    check(p2 == TITLE_UNFOCUSED and p3 == TITLE_FOCUSED, "title bars: #3 focused, #2 not",
          f"#2 {p2.hex()} #3 {p3.hex()}")

    # Drag #3 by its title bar (mouse_move is relative: the kernel reports
    # where the pointer really went).
    start = (w3[0] + 150, w3[1] + 10)
    end = s.drag(start, (200, 150))
    moved = s.read_until(b"wm: move #3", timeout)
    wins, _ = s.windows()
    n3 = wins.get(3)
    want = (w3[0] + end[0] - start[0], w3[1] + end[1] - start[1]) if end else None
    check(b"wm: move #3" in moved and end and end != start and n3 and (n3[0], n3[1]) == want,
          f"drag moves #3 by the pointer's travel ({start} -> {end})", f"{w3} -> {n3}, want {want}")
    old = (w3[0] + w3[2] - 60, w3[1] + 5)  # #3's old title bar, now uncovered
    pn = s.wait_pixel(*title_px(n3), TITLE_FOCUSED, dump)
    po = s.pixel_at(*old, dump)
    check(pn == TITLE_FOCUSED and po not in (TITLE_FOCUSED, TITLE_UNFOCUSED),
          "screen: #3's title bar moved", f"new {pn.hex()} old {po.hex()}")

    # Click #2's title bar: focus swaps.
    s.click(w2[0] + 40, w2[1] + 10)
    check(b"wm: focus #2" in s.read_until(b"wm: focus #2", timeout), "click focuses #2")
    p2 = s.wait_pixel(*title_px(w2), TITLE_FOCUSED, dump)
    p3 = s.pixel_at(*title_px_right(n3), dump)  # the part #2 doesn't cover
    wins, _ = s.windows()
    check(p2 == TITLE_FOCUSED and p3 == TITLE_UNFOCUSED and wins[2][4] and list(wins)[-1] == 2,
          "focus colours swapped, #2 on top", f"#2 {p2.hex()} #3 {p3.hex()}")

    # Resize #3 from its bottom-right grip.
    grip = (n3[0] + n3[2] - 3, n3[1] + n3[3] - 3)
    end = s.drag(grip, (60, 40))
    s.read_until(b"wm: resize #3", timeout)
    wins, _ = s.windows()
    r3 = wins.get(3)
    want = (n3[2] + end[0] - grip[0], n3[3] + end[1] - grip[1]) if end else None
    check(r3 and (r3[2], r3[3]) == want and (r3[0], r3[1]) == (n3[0], n3[1]),
          "grip drag resizes #3", f"{n3} -> {r3}, want size {want}")

    # Close #2 with its close box.
    s.click(w2[0] + w2[2] - 12, w2[1] + 12)
    check(b"wm: close #2" in s.read_until(b"wm: close #2", timeout), "close box closes #2")
    wins, _ = s.windows()
    gone = s.wait_pixel(*title_px(w2), TITLE_FOCUSED, dump, equal=False)
    check(2 not in wins and wins.get(3, (0,) * 5)[4] and gone not in (TITLE_FOCUSED, TITLE_UNFOCUSED),
          "#2 gone from the screen, focus back to #3", f"{wins} pixel {gone.hex()}")

    # Alt-Tab twice: the console, then #3 again. Alt-F4 closes #3.
    s.sendkeys(["alt-tab"])
    check(b"wm: focus #1" in s.read_until(b"wm: focus #1", timeout), "Alt-Tab focuses the console")
    s.sendkeys(["alt-tab"])
    check(b"wm: focus #3" in s.read_until(b"wm: focus #3", timeout), "Alt-Tab again focuses #3")
    s.sendkeys(["alt-f4"])
    check(b"wm: close #3" in s.read_until(b"wm: close #3", timeout), "Alt-F4 closes #3")
    wins, _ = s.windows()
    check(list(wins) == [1] and wins[1][4], "only the console is left, focused", str(wins))
    s.sendkeys(["meta_l-ret"])
    check(b"wm: open #4" in s.read_until(b"wm: focus #4", timeout), "Super+Enter opens a window")

    # The taskbar clock ticks.
    s.screendump(dump)
    w, h, before = read_ppm(dump)
    time.sleep(1.2)
    s.screendump(dump)
    w, h, after = read_ppm(dump)
    band = slice((h - 20) * w * 3, h * w * 3)
    check(before[band] != after[band], "taskbar clock updates")
    return failures


def enter_desktop(s: Session, timeout: float):
    """Boot to the shell and switch to the desktop; the `desktop` output (or
    None if that failed). If boot goes straight into the desktop (Phase L),
    only the wait for the first prompt is needed."""
    boot = s.read_prompt(boot_timeout(timeout))
    if not PROMPT_RE.search(boot):
        return None
    if b"desktop: on" in s.log:  # booted into it: serial is terminal #1's
        return boot.decode(errors="replace")
    got = s.command("desktop")
    return got if "desktop: on" in got else None


def key_names(text: str):
    """`sendkey` names for plain text (lower case, digits, space, newline)."""
    names = {" ": "spc", "\n": "ret", ".": "dot", "/": "slash", "-": "minus"}
    return [names.get(c, c) for c in text]


def editor_checks(s: Session, timeout: float) -> int:
    """Phase N end to end: `edit /notes.txt` over serial opens a focused
    editor window; text typed on the PS/2 keyboard (sendkey) goes into it,
    a typo is fixed with arrows and Backspace, Ctrl-S saves (`cat` over
    serial, which still reaches terminal #1's shell, shows the file), the
    window is checked in a screendump, a dirty close is refused until "n",
    and Ctrl-Q closes."""
    failures = 0
    dump = os.path.join(ROOT, "build", "editor.ppm")

    def check(ok, label, detail=""):
        nonlocal failures
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'}: editor: {label}" + ("" if ok or not detail else f"\n  {detail}"))
        return ok

    if not check(enter_desktop(s, timeout) is not None, "desktop is on"):
        return failures
    got = s.command("edit /notes.txt")
    if not check("edit: window #2: /notes.txt: new file" in got and "wm: focus #2" in got,
                 "edit /notes.txt opens a focused window", repr(got)):
        return failures
    wins, _ = s.windows()
    ew = wins.get(2)
    check(ew and ew[4] and ew[5] == "/notes.txt", "window #2 titled /notes.txt", str(wins))

    # Type two lines with a typo, then fix it: Up, End, 4 x Backspace, retype.
    s.sendkeys(key_names("hello wrold\nsecond line") + ["up", "end"] + ["backspace"] * 4 + key_names("orld"))
    s.sendkeys(["ctrl-s"])
    time.sleep(0.3)
    got = s.command("cat /notes.txt")
    check("hello world\r\nsecond line\r\n" in got, "Ctrl-S saved the typed text", repr(got))
    wins, _ = s.windows()
    check(wins.get(2, (0,) * 6)[5] == "/notes.txt" and wins[2][4], "title clean after save, editor still focused",
          str(wins))

    # The window on screen: gutter at the content's top-left, status line
    # along its bottom.
    x, y, w, h = ew[:4]
    gutter = s.wait_pixel(x + 3, y + 23, EDITOR_GUTTER_BG, dump)
    status = s.pixel_at(x + 2 + 200, y + h - 2 - 4, dump)
    check(gutter == EDITOR_GUTTER_BG and status == EDITOR_STATUS_BG, "screen: gutter and status line drawn",
          f"gutter {gutter.hex()} status {status.hex()}")

    # A dirty close (Alt-F4) is refused and asks; "n" discards and closes.
    s.sendkeys(key_names("x") + ["alt-f4"])
    time.sleep(0.3)
    wins, _ = s.windows()
    check(2 in wins and wins[2][5] == "/notes.txt [+]", "dirty Alt-F4 keeps the window", str(wins))
    s.sendkeys(["n"])
    check(b"wm: close #2" in s.read_until(b"wm: close #2", timeout), "n discards and closes")
    got = s.command("cat /notes.txt")
    check("hello world\r\nsecond line\r\n" in got and "linex" not in got, "the file kept the saved text",
          repr(got))

    # `open editor` (the taskbar's + Editor hook): an untitled editor; Ctrl-Q
    # closes it.
    s.command("open editor")
    wins, _ = s.windows()
    new = [i for i, v in wins.items() if v[5] == "untitled"]
    check(len(new) == 1 and wins[new[0]][4], "open editor: an untitled, focused editor", str(wins))
    if new:
        s.sendkeys(["ctrl-q"])
        want = f"wm: close #{new[0]}".encode()
        check(want in s.read_until(want, timeout), "Ctrl-Q closes a clean editor")
    return failures


def mkfs_checks(s: Session, img: str, timeout: float) -> int:
    """Phase Y on a blank (all-zero) image: the boot says there's no FAT32,
    `mkfs vda` formats it, `mount vda /disk` mounts it, and what's written
    there is on the image (read on the host after QEMU is killed)."""
    failures = 0

    def check(ok, label, detail=""):
        nonlocal failures
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'}: blank disk: {label}" + ("" if ok or not detail else f"\n  {detail}"))

    boot = s.read_prompt(boot_timeout(timeout))
    check(b"vda: no FAT32 filesystem (mkfs vda)" in s.log, "boot says 'no FAT32 filesystem (mkfs vda)'",
          repr(boot[-300:]))
    got = s.command("mount") + s.command("ls /disk")  # /disk is made anyway, empty
    check("on /disk" not in got and "ls: " not in got, "nothing mounted at /disk", repr(got))
    got = s.command("mkfs vda", 20)
    check("mkfs: vda: FAT32 'WIFFER', 0.0 of 63.0 MiB used, 129008 clusters of 512 bytes" in got, "mkfs vda", repr(got))
    got = s.command("mount vda /disk")
    check("vda: FAT32 'WIFFER' mounted at /disk" in got, "mount vda /disk", repr(got))
    got = s.command("mkfs vda")
    check("mkfs: vda: mounted at /disk (umount first)" in got, "mkfs refuses a mounted disk", repr(got))
    s.command("write /disk/made.txt made after mkfs")
    got = s.command("umount /disk")
    got += s.command("ls /disk") + s.command("mount vda /disk") + s.command("cat /disk/made.txt")
    check("made after mkfs" in got and "mounted at /disk" in got, "umount, mount again, file still there", repr(got))
    s.p.kill()
    s.p.wait()
    problems = fat32.fsck(img)
    made = fat32.read_file(img, "/made.txt") if not problems else None
    check(not problems and made == b"made after mkfs\n", "host: fsck clean, made.txt readable",
          f"problems {problems}, made {made!r}")
    return failures


PERSIST_NOTE = "kept on disk\nacross a reboot"


def persistence_checks(s: Session, img: str, timeout: float) -> int:
    """Phase Y's "done when": in the desktop, edit /disk/notes.txt with the
    PS/2 keyboard and Ctrl-S, write and mkdir from the terminal, `sync`,
    then kill QEMU. A second QEMU on the same image finds every file, and
    so does the host (fat32.fsck clean, read_file)."""
    failures = 0

    def check(ok, label, detail=""):
        nonlocal failures
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'}: persistence: {label}" + ("" if ok or not detail else f"\n  {detail}"))
        return ok

    if not check(enter_desktop(s, timeout) is not None, "desktop is on (boot 1)"):
        return failures
    got = s.command("edit /disk/notes.txt")
    if not check("/disk/notes.txt: new file" in got, "edit /disk/notes.txt opens a new file", repr(got)):
        return failures
    s.sendkeys(key_names(PERSIST_NOTE) + ["ctrl-s"])
    time.sleep(0.3)
    got = s.command("cat /disk/notes.txt")
    check(PERSIST_NOTE.replace("\n", "\r\n") + "\r\n" in got, "Ctrl-S saved the note under /disk", repr(got))
    s.sendkeys(["ctrl-q"])
    check(b"wm: close #2" in s.read_until(b"wm: close #2", timeout), "Ctrl-Q closes the editor")
    for cmd in ["write /disk/log.txt from the terminal", "mkdir /disk/saved", "write /disk/saved/deep.txt nested",
                "write /disk/hello.txt replaced", "sync"]:
        got = s.command(cmd)
        check(f"{cmd.split()[0]}: " not in got, cmd, repr(got))
    s.p.kill()  # no shutdown: everything must already be on the image
    s.p.wait()

    second = Session(iso=NODESKTOP_ISO, extra_args=disk_args(img))
    try:
        boot = second.read_prompt(boot_timeout(timeout))
        check(b"vda: FAT32 'WIFFER' mounted at /disk" in second.log, "boot 2 mounts the same image", repr(boot[-300:]))
        for path, want in [("/disk/notes.txt", PERSIST_NOTE), ("/disk/log.txt", "from the terminal"),
                           ("/disk/saved/deep.txt", "nested"), ("/disk/hello.txt", "replaced")]:
            got = second.command(f"cat {path}")
            check("\r\n" + want.replace("\n", "\r\n") + "\r\n" in got, f"boot 2: cat {path}", repr(got))
        got = second.command("fsck /disk")
        check("fsck: /disk: clean" in got, "boot 2: fsck /disk clean", repr(got))
    finally:
        second.close()
    problems = fat32.fsck(img)
    check(not problems, "host: fat32.fsck clean", str(problems))
    if not problems:
        files = {p: fat32.read_file(img, p) for p in ["/notes.txt", "/log.txt", "/saved/deep.txt", "/hello.txt"]}
        check(files == {"/notes.txt": PERSIST_NOTE.encode() + b"\n", "/log.txt": b"from the terminal\n",
                        "/saved/deep.txt": b"nested\n", "/hello.txt": b"replaced\n"},
              "host: read_file gets every file", str(files))
    return failures


def ocr_window(path: str, win):
    """The text in terminal window `win` = (x, y, w, h, ...) of a screendump,
    read cell by cell: each 8x16 cell's pixels that differ from its most
    common colour are matched against the PSF font's ASCII glyphs (so
    colours and the inverted cursor don't matter). Rows, right-stripped."""
    glyphs, gh, cmap, _ = load_psf1(FONT)
    lookup = {}
    for c in range(0x7E, 0x1F, -1):
        if c in cmap:
            lookup[glyphs[cmap[c]]] = chr(c)
    w, h, pix = read_ppm(path)
    x0, y0 = win[0] + 2, win[1] + 2 + 20
    cols, rows = (win[2] - 4) // 8, (win[3] - 24) // gh
    lines = []
    for r in range(rows):
        line = ""
        for c in range(cols):
            px = [[pixel(w, pix, x0 + c * 8 + x, y0 + r * gh + y) for x in range(8)] for y in range(gh)]
            flat = [p for row in px for p in row]
            bg = max(set(flat), key=flat.count)
            bits = bytes(sum(0x80 >> x for x in range(8) if row[x] != bg) for row in px)
            line += lookup.get(bits, " " if not any(bits) else "?")
        lines.append(line.rstrip())
    return lines


def terminal_checks(s: Session, timeout: float) -> int:
    """Phase L end to end, on the default boot (straight into the desktop
    with terminal #1): a second terminal (Ctrl-Alt-T) opens beside the
    first; each has its own variables and history; keys typed with sendkey
    reach only the focused one (read back from screendumps by matching the
    font's glyphs); serial follows the focused terminal; resize; and every
    way to close one (exit, close <n>, the close box, Alt-F4), then a serial
    key with no terminal left opens a new one."""
    failures = 0
    dump = os.path.join(ROOT, "build", "terminals.ppm")

    def check(ok, label, detail=""):
        nonlocal failures
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'}: terminal: {label}" + ("" if ok or not detail else f"\n  {detail}"))
        return ok

    def wait_for(text: str):
        return text.encode() in s.read_until(text.encode(), timeout)

    def has(lines, text):
        return any(text in l for l in lines)

    boot = s.read_prompt(boot_timeout(timeout))
    if not check(PROMPT_RE.search(boot) and b"desktop: on" in s.log and b"cmdline: ''" in s.log,
                 "boots into the desktop with a prompt", repr(boot[-200:])):
        return failures
    wins, _ = s.windows()
    w1 = wins.get(1)
    if not check(list(wins) == [1] and w1[4] and w1[5] == "Terminal 1", "one focused terminal", str(wins)):
        return failures
    s.command("set a 1")
    check("\r\n1\r\n" in s.command("get a"), "set/get in terminal #1")

    # A second terminal, beside the first; serial follows it.
    s.sendkeys(["ctrl-alt-t"])
    check(wait_for("wm: focus #2"), "Ctrl-Alt-T opens terminal #2")
    s.read_prompt(timeout)  # #2's first prompt, now on serial
    wins, _ = s.windows()
    w1, w2 = wins.get(1), wins.get(2)
    if not check(w1 and w2 and w2[4] and w2[5] == "Terminal 2" and w2[0] >= w1[0] + w1[2] and w2[1] == w1[1],
                 "#2 focused, side by side with #1", str(wins)):
        return failures
    check("get: not set: a" in s.command("get a"), "#2 has its own variables")
    s.command("set a 2")
    check("\r\n2\r\n" in s.command("get a"), "set/get in #2")
    s.sendkeys(key_names("echo two\n"))
    check("\r\ntwo\r\n" in s.read_prompt(timeout).decode(errors="replace"), "keyboard types into #2")

    # Click #1: focus and serial move to it.
    s.click(w1[0] + w1[2] // 2, w1[1] + w1[3] // 2)
    check(wait_for("wm: focus #1"), "click focuses #1")
    check("\r\n1\r\n" in s.command("get a"), "#1 kept its variable")
    got = s.command("history")
    check("set a 1" in got and "set a 2" not in got and "echo two" not in got, "#1's history is its own", repr(got))
    s.sendkeys(key_names("echo one\n"))
    check("\r\none\r\n" in s.read_prompt(timeout).decode(errors="replace"), "keyboard types into #1")

    # The screen: each window shows only its own typing.
    s.warp(640, 600)  # pointer off the text
    time.sleep(0.3)
    s.screendump(dump)
    t1, t2 = ocr_window(dump, w1), ocr_window(dump, w2)
    check(has(t1, "> echo one") and has(t1, "> get a") and not has(t1, "echo two"),
          "screen: #1 shows its session only", "\n  ".join(t1))
    check(has(t2, "> echo two") and has(t2, "get: not set: a") and not has(t2, "echo one"),
          "screen: #2 shows its session only", "\n  ".join(t2))
    w, h, pix = read_ppm(dump)
    check(pixel(w, pix, w1[0] + 4, w1[1] + 12) == TITLE_FOCUSED and pixel(w, pix, w2[0] + 4, w2[1] + 12) == TITLE_UNFOCUSED,
          "screen: #1's title bar focused, #2's not")

    # Resize #2 smaller from its grip (focuses it); the shell carries on.
    grip = (w2[0] + w2[2] - 3, w2[1] + w2[3] - 3)
    s.drag(grip, (-160, -120))
    check(wait_for("wm: resize #2"), "grip drag resizes #2")
    wins, _ = s.windows()
    r2 = wins.get(2)
    check(r2 and r2[2] < w2[2] and r2[3] < w2[3] and r2[4], "#2 smaller and focused", str(wins))
    check("\r\nsmall\r\n" in s.command("echo small"), "#2's shell works after the resize")
    s.warp(640, 600)
    time.sleep(0.3)
    s.screendump(dump)
    t2 = ocr_window(dump, r2)
    check(has(t2, "> echo small") and has(t2, "warp: x=640 y=600"),
          "screen: #2 redrawn at its new size", "\n  ".join(t2))

    # Closing: exit, close <n> on itself, the close box, Alt-F4.
    s.send("exit")
    check(wait_for("wm: close #2"), "exit closes #2")
    check(wait_for("wm: focus #1"), "focus back to #1")
    wins, _ = s.windows()
    check(list(wins) == [1] and wins[1][4], "only #1 left", str(wins))
    s.send("open terminal")
    check(wait_for("wm: focus #3"), "open terminal opens #3")
    s.read_prompt(timeout)  # #1's prompt
    s.read_prompt(timeout)  # #3's first prompt
    s.send("close 3")
    check(wait_for("wm: close #3"), "close 3 from #3 closes it")
    _, buttons = s.windows()
    plus = buttons[0]
    s.click(plus[0] + plus[2] // 2, plus[1] + plus[3] // 2)
    check(wait_for("wm: focus #4"), "+ Terminal opens #4")
    s.read_prompt(timeout)
    wins, _ = s.windows()
    w4 = wins.get(4)
    if w4:
        s.click(w4[0] + w4[2] - 12, w4[1] + 12)
        check(wait_for("wm: close #4"), "the close box closes #4")
    s.sendkeys(["alt-f4"])
    check(wait_for("wm: close #1"), "Alt-F4 closes #1, the last terminal")
    s.send("")
    check(wait_for("wm: focus #5"), "a serial key with no terminal opens one")
    s.read_prompt(timeout)
    wins, _ = s.windows()
    check(list(wins) == [5] and wins[5][4], "terminal #5 is the only window", str(wins))
    got = s.command("open log")
    wins, _ = s.windows()
    check("open log: #6" in got and wins.get(6, (0,) * 6)[5] == "Log", "open log shows the kernel log", repr(got))
    # Phase 6E: programs and pipelines in a terminal window (serial follows #5).
    got = s.command("/bin/cat /README | /bin/wc")
    check(f"\r\n{README_WC}\r\n" in got, "/bin/cat /README | /bin/wc works in a terminal window", repr(got))
    failures += program_io_checks(s, timeout, "terminal window")
    return failures


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
