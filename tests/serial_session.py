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
    # Part 8 /etc files and the /bin programs; the counts change with rootfs.
    ("df", " files, "),
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
    def __init__(self, extra_args=(), monitor=False, exit_device=True, iso=ISO, net=True, hostfwd=None):
        self.monitor_path = None
        self.mon = None  # connected monitor socket, opened on first use
        self.cursor = None  # mouse sprite (x, y) on screen, if known
        mon = "none"
        if monitor:  # a short path: unix socket paths are limited to ~104 bytes
            self.mondir = tempfile.mkdtemp(prefix="wiffer")
            self.monitor_path = os.path.join(self.mondir, "mon.sock")
            mon = f"unix:{self.monitor_path},server,nowait"
        args = ["qemu-system-x86_64", "-M", "q35", "-m", "1G", "-cpu", "max", "-smp", SMP, "-cdrom", iso,
                "-boot", "d", "-no-reboot", "-display", "none",
                "-serial", "stdio", "-monitor", mon, *FIRMWARE, *extra_args]
        if net and not NONET:
            args += NET_ARGS
            if hostfwd:  # Part 7D: (host port, guest port) for `tcplisten`
                i = args.index("user,id=n0")
                args[i] += f",hostfwd=tcp:127.0.0.1:{hostfwd[0]}-:{hostfwd[1]}"
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
    ap.add_argument("--web-only", action="store_true", help="run only the Phase 8I web checks (one QEMU)")
    ap.add_argument("--js-only", action="store_true", help="run only the Phase 9F /bin/js checks (one QEMU)")
    ap.add_argument("--nodisk", action="store_true", default=bool(os.environ.get("WIFFER_NODISK")),
                    help="no scratch virtio disk on the main session")
    opts = ap.parse_args()
    if opts.web_only:  # development: just the 8I browser session
        w = Session(monitor=True)
        try:
            n = web_checks(w, opts.timeout)
            print(f"{n} web check failure(s)")
            return 1 if n else 0
        finally:
            w.close()
    if opts.js_only:  # development: just the 9F session
        j = Session(monitor=True)
        try:
            n = js_checks(j, opts.timeout)
            print(f"{n} js check failure(s)")
            return 1 if n else 0
        finally:
            j.close()
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
                extra_args=disk_args(disk) if disk else (), hostfwd=(TCP_FWD_HOST, TCP_FWD_GUEST))
    # Phase K runs on its own machine: `desktop` switches the full-screen
    # shell to the WM (the console becomes window #1).
    desk = None if opts.command else Session(monitor=True, iso=NODESKTOP_ISO)
    ed = None if opts.command else Session(monitor=True)  # Phase N, in the boot desktop
    term = None if opts.command else Session(monitor=True)  # Phase L, in the boot desktop
    pre = None if opts.command else Session(monitor=True)  # Phase 6D, in the boot desktop
    gui = None if opts.command else Session(monitor=True)  # Phase 6F, in the boot desktop
    web = None if opts.command else Session(monitor=True)  # Phase 8H, the browser, in the boot desktop
    web8i = None if opts.command else Session(monitor=True)  # Phase 8I, the browser against tests/web_server.py
    jsx = None if opts.command else Session(monitor=True)  # Phase 9F, /bin/js, in the boot desktop
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
        if pre:
            failures += preempt_desktop_checks(pre, opts.timeout)
        if gui:
            failures += gui_checks(gui, opts.timeout)
        if web:
            failures += browse_checks(web, opts.timeout)
        if web8i:
            failures += web_checks(web8i, opts.timeout)
        if jsx:
            failures += js_checks(jsx, opts.timeout)
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
        if pre:
            pre.close()
        if gui:
            gui.close()
        if web:
            web.close()
        if web8i:
            web8i.close()
        if jsx:
            jsx.close()


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
            elif name in ("www.wiffer.example", "www2.wiffer.example"):  # (two: the cache keeps no aliases)
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


def free_port():
    """An unused 127.0.0.1 TCP port (bound, then released)."""
    with socket.socket() as so:
        so.bind(("127.0.0.1", 0))
        return so.getsockname()[1]

# Part 7D: `tcplisten` in the main session is reached through SLIRP hostfwd.
TCP_FWD_HOST = free_port()
TCP_FWD_GUEST = 7777

def fnv1a64(data: bytes, h=0xcbf29ce484222325) -> int:
    for b in data:
        h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return h

def http_server(body: bytes):
    """Part 7D: a Python HTTP server on 127.0.0.1 (ephemeral port) serving
    `body` at /data (the guest reaches it at 10.0.2.2). Returns (port, stop)."""
    import http.server, threading
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.0"
        def do_GET(self):
            if self.path != "/data":
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def log_message(self, *args):
            pass
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    def stop():
        srv.shutdown()
        srv.server_close()
    return srv.server_address[1], stop

def tcp_checks(s: Session, timeout: float, check):
    """Part 7D on the machine: download 1 MiB from the host over SLIRP and
    compare hashes; a closed port is refused; the host connects in through
    hostfwd to `tcplisten`, which echoes 256 KiB back."""
    import random
    body = random.Random(7).randbytes(1 << 20)
    want = f"{fnv1a64(body):016x}"
    port, stop = http_server(body)
    try:
        got = s.command(f"tcpget 10.0.2.2 {port} /data", 60.0)
        m = re.search(r"tcpget: (\d+) body bytes .*fnv1a ([0-9a-f]{16}), (\d+) ms, (\d+) KiB/s", got)
        ok = check(m is not None and m.group(1) == str(len(body)) and m.group(2) == want and "200 OK" in got,
                   "net: tcpget downloads 1 MiB from the host, hash matches", repr(got))
        if ok:
            print(f"harness: 1 MiB over SLIRP in {m.group(3)} ms ({m.group(4)} KiB/s)")
        got = s.command(f"tcpget 10.0.2.2 {port} /nothing", 30.0)
        check("404" in got and "tcpget: " in got, "net: tcpget gets a 404 for a missing path", repr(got))
    finally:
        stop()
    got = s.command(f"tcpget 10.0.2.2 {free_port()} /", 40.0)
    check("connection refused" in got or "connection reset" in got, "net: tcpget to a closed host port fails (RST)", repr(got))
    data = random.Random(8).randbytes(256 * 1024)
    s.send(f"tcplisten {TCP_FWD_GUEST}")
    s.read_until(b"listening on port", 20.0)
    echoed = b""
    err = None
    try:
        with socket.create_connection(("127.0.0.1", TCP_FWD_HOST), timeout=30) as so:
            import threading
            def feed():  # send while reading, so neither side's buffers deadlock
                try:
                    so.sendall(data)
                    so.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
            sender = threading.Thread(target=feed, daemon=True)
            sender.start()
            while True:
                chunk = so.recv(65536)
                if not chunk:
                    break
                echoed += chunk
    except OSError as e:
        err = e
    got = s.read_prompt(30.0).decode(errors="replace")
    check(err is None and echoed == data and f"echoed {len(data)} bytes, fnv1a {fnv1a64(data):016x}" in got
          and "connection from 10.0.2.2:" in got,
          "net: the host connects in through hostfwd; tcplisten echoes 256 KiB", f"{err!r} {len(echoed)} bytes {got!r}")
    got = s.command("netstat", timeout)
    check("segments in" in got, "net: netstat lists TCP state", repr(got))

def fetch_server(files, tls=None):
    """Part 7F: an HTTP (or, with tls=(chain, key), HTTPS) server on
    127.0.0.1 for /bin/fetch. `files` maps a path to (body, headers) or to
    ("redirect", status, location). HTTP/1.1 with Connection: close. Returns
    (port, stop)."""
    import http.server, ssl, threading
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        def do_GET(self):
            f = files.get(self.path)
            if f is None:
                self.send_error(404)
                return
            if f[0] == "redirect":
                self.send_response(f[1])
                self.send_header("Location", f[2])
                self.send_header("Content-Length", "0")
                self.send_header("Connection", "close")
                self.end_headers()
                return
            body, headers = f
            self.send_response(200)
            for k, v in headers:
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
        def log_message(self, *args):
            pass
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    if tls:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_3
        ctx.load_cert_chain(tls[0], tls[1])
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    def stop():
        srv.shutdown()
        srv.server_close()
    return srv.server_address[1], stop

FETCH_RE = re.compile(r"fetch: (\d+) [^,]*, (\d+) bytes, fnv1a ([0-9a-f]{16}), (\d+) ms, (\d+) KiB/s")

def fetch_checks(s: Session, timeout: float, check):
    """Part 7F: /bin/fetch over HTTP (1 MiB with a hash, gzip, a redirect
    chain, a 404, 10 MiB for throughput) and HTTPS (a local Python ssl server
    with the test PKI from tests/certs/: trusted via --ca, refused without
    it); /bin/nc both ways; /bin/ping."""
    import gzip, random, threading
    body = random.Random(9).randbytes(1 << 20)
    big = random.Random(10).randbytes(10 << 20)
    text = b"".join(b"line %d of a compressible page\n" % i for i in range(20000))
    certs = os.path.join(ROOT, "tests", "certs")
    with open(os.path.join(certs, "roots.der"), "rb") as f:
        ca = f.read()
    files = {
        "/data": (body, [("Content-Type", "application/octet-stream")]),
        "/big": (big, []),
        "/page": (gzip.compress(text), [("Content-Type", "text/plain"), ("Content-Encoding", "gzip")]),
        "/hop1": ("redirect", 301, "/hop2"),
        "/hop2": ("redirect", 302, "/data"),
        "/testca.der": (ca, []),
    }
    port, stop = fetch_server(files)
    tport, tstop = fetch_server({"/data": (body, []), "/": (b"hello over TLS\n", [])},
                                tls=(os.path.join(certs, "leaf-ec.chain.pem"), os.path.join(certs, "leaf-ec.key.pem")))
    want = f"{fnv1a64(body):016x}"
    try:
        url = f"http://10.0.2.2:{port}"
        got = s.command(f"fetch -v -q {url}/data", 60.0)
        m = FETCH_RE.search(got)
        check(m is not None and m.group(1) == "200" and m.group(2) == str(len(body)) and m.group(3) == want,
              "fetch: 1 MiB over HTTP, hash matches", repr(got[-600:]))
        got = s.command(f"fetch -v -q {url}/big", 90.0)
        m = FETCH_RE.search(got)
        ok = check(m is not None and m.group(2) == str(len(big)) and m.group(3) == f"{fnv1a64(big):016x}",
                   "fetch: 10 MiB over HTTP, hash matches", repr(got[-600:]))
        if ok:
            ms = int(m.group(4))
            print(f"harness: 10 MiB through SLIRP (MSI-X) in {ms} ms ({len(big) / 1e6 / (ms / 1000):.1f} MB/s)")
        got = s.command(f"fetch -v -q {url}/page", 60.0)
        m = FETCH_RE.search(got)
        check("Content-Encoding: gzip" in got and m is not None and m.group(2) == str(len(text))
              and m.group(3) == f"{fnv1a64(text):016x}", "fetch: a gzip response is decoded", repr(got[-600:]))
        got = s.command(f"fetch -v -q {url}/hop1", 60.0)
        m = FETCH_RE.search(got)
        check("301 redirect to" in got and "302 redirect to" in got and m is not None and m.group(3) == want,
              "fetch: follows a 301 and a 302 to the data", repr(got[-600:]))
        got = s.command(f"fetch {url}/nothing", 30.0)
        check("exit status 3" in got, "fetch: a 404 exits with status 3", repr(got))
        got = s.command(f"fetch -o /testca.der {url}/testca.der", 30.0)
        got += s.command("/bin/wc /testca.der", timeout)
        check(f" {len(ca)} /testca.der" in got, "fetch -o writes the test CA to a file", repr(got))
        turl = f"https://localhost:{tport}"
        got = s.command(f"fetch -v -q --ca /testca.der --resolve localhost:10.0.2.2 {turl}/data", 60.0)
        m = FETCH_RE.search(got)
        check(m is not None and m.group(1) == "200" and m.group(3) == want,
              "fetch: 1 MiB over HTTPS (TLS 1.3, test CA via --ca), hash matches", repr(got[-600:]))
        got = s.command(f"fetch --resolve localhost:10.0.2.2 {turl}/", 60.0)
        check("TLS:" in got and "exit status 1" in got, "fetch: the test server's certificate is refused with /etc/roots.der",
              repr(got[-400:]))
        got = s.command(f"fetch --ca /testca.der https://10.0.2.2:{tport}/", 60.0)
        check("TLS:" in got and "exit status 1" in got, "fetch: a name the certificate doesn't cover is refused",
              repr(got[-400:]))
        got = s.command(f"fetch -k https://10.0.2.2:{tport}/", 60.0)
        check("hello over TLS" in got, "fetch -k skips the certificate check", repr(got[-400:]))
        got = s.command(f"fetch http://10.0.2.2:{free_port()}/", 30.0)
        check("connection refused" in got, "fetch: a closed port is refused", repr(got))
    finally:
        stop()
        tstop()

    # nc -l in the guest, reached from the host through hostfwd.
    s.send(f"nc -l {TCP_FWD_GUEST}")
    time.sleep(1.0)
    got_host = b""
    err = None
    try:
        with socket.create_connection(("127.0.0.1", TCP_FWD_HOST), timeout=20) as so:
            so.sendall(b"from the host\n")
            s.read_until(b"from the host", 20.0)
            s.send("from the guest")
            time.sleep(0.5)
            s.p.stdin.write(b"\x04")  # Ctrl-D: end of input, nc half-closes
            s.p.stdin.flush()
            while True:
                chunk = so.recv(4096)
                if not chunk:
                    break
                got_host += chunk
    except OSError as e:
        err = e
    got = s.read_prompt(20.0).decode(errors="replace")
    check(err is None and got_host == b"from the guest\n", "nc -l: host to guest and guest to host through hostfwd",
          f"{err!r} {got_host!r} {got!r}")

    # nc in the guest connecting out to a host listener.
    lsock = socket.socket()
    lsock.bind(("127.0.0.1", 0))
    lsock.listen(1)
    lsock.settimeout(20)
    received = []
    def serve():
        try:
            c, _ = lsock.accept()
            with c:
                c.sendall(b"hello guest\n")
                data = b""
                while True:
                    chunk = c.recv(4096)
                    if not chunk:
                        break
                    data += chunk
                received.append(data)
        except OSError:
            pass
    th = threading.Thread(target=serve, daemon=True)
    th.start()
    s.send(f"nc 10.0.2.2 {lsock.getsockname()[1]}")
    out = s.read_until(b"hello guest", 20.0).decode(errors="replace")
    s.send("hello host")
    time.sleep(0.5)
    s.p.stdin.write(b"\x04")
    s.p.stdin.flush()
    out += s.read_prompt(20.0).decode(errors="replace")
    th.join(5)
    lsock.close()
    check("hello guest" in out and received == [b"hello host\n"], "nc: connects out, both directions, Ctrl-D closes",
          f"{received!r} {out!r}")

    got = s.command("/bin/ping -c 3 10.0.2.2", 20.0)
    check("3 packets transmitted, 3 received, 0% packet loss" in got and "icmp_seq=3" in got,
          "net: /bin/ping -c 3 10.0.2.2 (ICMP socket)", repr(got))
    got = s.command("ifconfig", timeout)
    check("irq: msi-x vector 0x50 on cpu 0" in got, "net: virtio-net interrupts through MSI-X", repr(got))

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
        # Phase 7F: the built-in `host` and /bin/host (the resolve call) give the same answers.
        for host in ("host", "/bin/host"):
            got = s.command(f"{host} test.wiffer.example {srv}", 20.0)
            check("test.wiffer.example has address 192.0.2.77" in got, f"net: {host} resolves through the fake DNS server", repr(got))
            www = "www.wiffer.example" if host == "host" else "www2.wiffer.example"
            got = s.command(f"{host} {www} {srv}", 20.0)
            check(f"{www} is an alias for test.wiffer.example." in got
                  and "test.wiffer.example has address 192.0.2.77" in got, f"net: {host} follows a CNAME", repr(got))
            got = s.command(f"{host} nx.wiffer.example {srv}", 20.0)
            check("not found: NXDOMAIN" in got, f"net: {host} reports NXDOMAIN", repr(got))
            for name in ("loop", "trunc", "huge"):
                # Hostile replies are ignored; the query times out (3 x 2 s) and the kernel lives on.
                got = s.command(f"{host} {name}.wiffer.example {srv}", 30.0)
                check("not found" in got and "timed out" in got, f"net: {host}: a hostile '{name}' reply fails cleanly", repr(got))
        got = s.command("ping -c 1 10.0.2.2", 20.0)
        check("1 packets transmitted, 1 received" in got, "net: the stack still answers after hostile DNS replies", repr(got))
    finally:
        stop()
    tcp_checks(s, timeout, check)
    fetch_checks(s, timeout, check)
    return failures


def process_checks(s: Session, timeout: float) -> int:
    """Phase 6C: a background `spin` shows in `ps` and `kill` stops it.
    Phase 6D (any -smp count, 1 included): with a spin per CPU the shell
    still runs commands and programs; `sleep 500` takes about 500 ms; Ctrl-C
    kills a foreground spin (on CPU 0 with -smp 1)."""
    failures = 0
    def check(ok, label, detail=""):
        nonlocal failures
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'}: {label}" + ("" if ok else f"\n  {detail}"))
        return ok
    failures += preempt_checks(s, timeout)
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


def preempt_checks(s: Session, timeout: float) -> int:
    """Phase 6D on the serial shell (see process_checks)."""
    failures = 0
    def check(ok, label, detail=""):
        nonlocal failures
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'}: {label}" + ("" if ok else f"\n  {detail}"))
        return ok
    n = int(SMP)
    pids = []
    for _ in range(n):
        m = re.search(r"\[(\d+)\]", s.command("spin &", timeout))
        if m:
            pids.append(m.group(1))
    check(len(pids) == n, f"6D: {n} background spin(s) started", repr(pids))
    time.sleep(0.5)
    got = s.command("echo preempted", timeout)
    check("\r\npreempted\r\n" in got, f"6D: the shell runs beside {n} spin(s)", repr(got))
    got = s.command("hello", timeout)
    check("Hello from ring 3!" in got, f"6D: programs run beside {n} spin(s)", repr(got))
    got = s.command("ps", timeout)
    running = [p for p in pids if re.search(rf"^\s*{p}\s+0\s+running\s", got, re.M)]
    check(len(running) == n, "6D: ps lists every spin running", repr(got))
    for p in pids:
        s.command(f"kill {p}", timeout)
    gone = False
    for _ in range(20):
        got = s.command("ps", timeout)
        if not any(re.search(rf"^\s*{p}\s", got, re.M) for p in pids):
            gone = True
            break
        time.sleep(0.1)
    check(gone, "6D: kill stops every spin", repr(got))
    # sleep: the shell waits about 500 ms (host time is loose under load).
    t0 = time.time()
    got = s.command("sleep -v 500", timeout)
    took = time.time() - t0
    m = re.search(r"slept (\d+) ms", got)
    check(m is not None and 490 <= int(m.group(1)) <= 510 and took >= 0.45,
          f"6D: sleep -v 500 sleeps 500 ms ({m.group(1) if m else None} ms, {took:.2f} s on the host)", repr(got))
    # Ctrl-C kills a foreground spin (on CPU 0 when it's the only CPU).
    s.send("spin")
    time.sleep(0.5)
    s.p.stdin.write(b"\x03")
    s.p.stdin.flush()
    got = s.read_prompt(timeout).decode(errors="replace")
    check("(spin): killed" in got, "6D: Ctrl-C kills a foreground spin", repr(got))
    got = s.command("echo after", timeout)
    check("\r\nafter\r\n" in got, "6D: the shell carries on after Ctrl-C", repr(got))
    return failures


def preempt_desktop_checks(s: Session, timeout: float) -> int:
    """Phase 6D on the desktop: with a spin per CPU, keys typed on the PS/2
    keyboard still echo in the terminal window, on screen."""
    failures = 0
    dump = os.path.join(ROOT, "build", "preempt.ppm")
    def check(ok, label, detail=""):
        nonlocal failures
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'}: 6D desktop: {label}" + ("" if ok or not detail else f"\n  {detail}"))
        return ok
    boot = s.read_prompt(boot_timeout(timeout))
    if not check(PROMPT_RE.search(boot) and b"desktop: on" in s.log, "boots into the desktop", repr(boot[-200:])):
        return failures
    n = int(SMP)
    pids = []
    for _ in range(n):
        m = re.search(r"\[(\d+)\]", s.command("spin &", timeout))
        if m:
            pids.append(m.group(1))
    check(len(pids) == n, f"{n} spin(s) in the background", repr(pids))
    time.sleep(0.5)
    s.sendkeys(key_names("echo typed\n"))
    got = s.read_prompt(timeout).decode(errors="replace")
    check("\r\ntyped\r\n" in got, "keys reach the shell beside the spins", repr(got))
    wins, _ = s.windows()
    w1 = wins.get(1)
    s.warp(640, 600)
    time.sleep(0.5)
    s.screendump(dump)
    lines = ocr_window(dump, w1) if w1 else []
    check(any("> echo typed" in l for l in lines) and any(l.strip() == "typed" for l in lines),
          "the terminal redraws the typed line", "\n  ".join(lines))
    for p in pids:
        s.command(f"kill {p}", timeout)
    got = s.command("ps", timeout)
    check(not any(re.search(rf"^\s*{p}\s+\d+\s+running", got, re.M) for p in pids), "spins killed", repr(got))
    return failures


def js_checks(s: Session, timeout: float) -> int:
    """Phase 9F: /bin/js on the scripts in /js. A computation with a known
    answer, a timer sequence, the REPL (line editing, multi-line input,
    Ctrl-C), an infinite loop the time budget terminates and a heap bomb the
    heap cap terminates; the desktop (pointer, shell) keeps answering while
    a script spins."""
    failures = 0
    def check(ok, label, detail=""):
        nonlocal failures
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'}: 9F js: {label}" + ("" if ok or not detail else f"\n  {detail}"))
        return ok
    boot = s.read_prompt(boot_timeout(timeout))
    if not check(PROMPT_RE.search(boot) and b"desktop: on" in s.log, "boots into the desktop", repr(boot[-200:])):
        return failures
    got = s.command("js /js/fib.js", 60.0)
    check("fib(20) = 6765\r\n" in got, "fib(20) = 6765", repr(got))
    check('json = {"a":[1,2,{"b":"x"}],"c":null} true' in got, "JSON round trip", repr(got))
    check("[ 1, 4, 9 ] { n: 1, s: 'two', nested: { deep: [ 1, 2 ] } }" in got, "console.log formats objects", repr(got))
    check("answer is 42.5 years and 99% done [ 1 ]" in got, "console.log %s %d %i %% %o", repr(got))
    got = s.command("js -e console.log(typeof setTimeout, [1,2,3].length, 'ok')", 30.0)
    check("function 3 ok\r\n" in got, "js -e", repr(got))
    got = s.command("js /js/timers.js", 30.0)
    order = re.findall(r"^(sync|micro|t0-first|t0-second|t50|t200|tick\d|done)\r?$", got, re.M)
    check(order == ["sync", "micro", "t0-first", "t0-second", "t50", "tick1", "t200", "tick2", "tick3", "done"]
          and "never" not in got, "timer sequence runs in due order", repr(got))
    got = s.command("js /js/mod.mjs", 30.0)
    check("module dep 144\r\nawaited\r\n" in got and "Uncaught (in promise) Error: unhandled on purpose" in got,
          "an ES module with an import, top-level await and an unhandled rejection", repr(got))
    got = s.command("js -e Promise.resolve(5).then(v=>console.log('p'+v));console.log('s')", 30.0)
    check("s\r\np5\r\n" in got, "promise jobs run after the script", repr(got))
    got = s.command("js /js/nosuch.js", 30.0)
    check("js: /js/nosuch.js: no such file" in got, "a missing file is reported", repr(got))
    got = s.command("js -e throw new TypeError('bad')", 30.0)
    check("Uncaught TypeError: bad" in got, "an uncaught exception is reported", repr(got))

    # The REPL: raw terminal, line editing, multi-line input, Ctrl-C, Ctrl-D.
    s.send("js")
    got = s.read_until(b"\r> ", 30.0).decode(errors="replace")
    check("Wiffer JavaScript" in got, "the REPL starts", repr(got))
    s.send("6 * 7")
    got = s.read_until(b"42\r\n", 30.0).decode(errors="replace")
    check(got.endswith("42\r\n"), "REPL evaluates 6 * 7", repr(got))
    s.send("function f(n) {")
    s.read_until(b"... ", 10.0)
    s.send("  return n + 1")
    s.read_until(b"... ", 10.0)
    s.send("}")
    s.read_until(b"undefined\r\n", 10.0)
    s.send("f(41)")
    got = s.read_until(b"42\r\n", 30.0).decode(errors="replace")
    check(got.endswith("42\r\n"), "REPL multi-line input (unexpected end of input continues)", repr(got))
    s.send("var o = {a: [1, 'x'], f}; o")
    got = s.read_until(b"}\r\n", 30.0).decode(errors="replace")
    check("{ a: [ 1, 'x' ], f: [Function: f] }" in got, "REPL inspects results", repr(got))
    s.send("let q = 1; q +")
    s.read_until(b"... ", 10.0)
    s.send("1")
    got = s.read_until(b"2\r\n", 30.0).decode(errors="replace")
    check(got.endswith("2\r\n"), "REPL continues an incomplete expression", repr(got))
    s.send("nosuchvar")
    got = s.read_until(b"not defined\r\n", 30.0).decode(errors="replace")
    check("Uncaught ReferenceError: nosuchvar is not defined" in got, "REPL reports errors", repr(got))
    s.send("setTimeout(() => console.log('late'), 300)")
    s.read_until(b"1\r\n", 10.0)
    got = s.read_until(b"late\r\n", 10.0).decode(errors="replace")
    check("late\r\n" in got, "REPL timers fire while it waits for input", repr(got))
    s.send("while (true) {}")
    time.sleep(1.0)
    s.p.stdin.write(b"\x03")
    s.p.stdin.flush()
    got = s.read_until(b"interrupted", 30.0).decode(errors="replace")
    check("script terminated: interrupted" in got, "Ctrl-C terminates a running REPL script", repr(got))
    s.send("q")
    got = s.read_until(b"1\r\n", 30.0).decode(errors="replace")
    check(got.endswith("1\r\n"), "the REPL survives, its globals intact", repr(got))
    s.p.stdin.write(b"\x04")
    s.p.stdin.flush()
    got = s.read_prompt(timeout).decode(errors="replace")
    check(PROMPT_RE.search(got.encode()) is not None, "Ctrl-D leaves the REPL for the shell", repr(got))
    got = s.command("echo shell back", timeout)
    check("shell back" in got, "the shell works after the REPL", repr(got))

    # An infinite loop: the 5 s default budget terminates it; the desktop and
    # the shell keep answering meanwhile.
    t0 = time.time()
    got = s.command("js /js/loop.js &", timeout)
    check("[" in got, "loop.js starts in the background", repr(got))
    time.sleep(0.5)
    t1 = time.time()
    got = s.command("echo alive", timeout)
    check("alive" in got and time.time() - t1 < 3.0, "the shell answers while a script spins", repr(got))
    s.warp(333, 222)
    check(s.pointer() == (333, 222, 0), "the pointer still moves while a script spins", repr(s.pointer()))
    wins, _ = s.windows()
    check(bool(wins), "the window manager answers while a script spins", repr(wins))
    got = s.read_until(b"time budget exceeded", 30.0).decode(errors="replace")
    took = time.time() - t0
    check("script terminated: time budget exceeded" in got and 4.0 <= took < 25.0,
          f"the default budget terminates an infinite loop ({took:.1f} s)", repr(got))
    s.read_prompt(timeout)
    got = s.command("js --budget 1000 /js/loop.js", 30.0)
    check("script terminated: time budget exceeded (1000 ms)" in got, "--budget sets the budget", repr(got))

    # A heap bomb: the heap cap terminates it, memory comes back.
    before = re.search(r"(\d+) used", s.command("mem"))
    got = s.command("js /js/bomb.js", 120.0)
    check("script terminated: heap limit exceeded (64 MiB)" in got, "the heap cap terminates a heap bomb", repr(got[-300:]))
    after = re.search(r"(\d+) used", s.command("mem"))
    check(before and after and int(after.group(1)) <= int(before.group(1)) + 64,
          "the heap bomb's memory is returned", f"{before and before.group(0)} -> {after and after.group(0)}")
    got = s.command("echo done", timeout)
    check("done" in got, "the shell works after the bomb", repr(got))
    return failures


def gui_checks(s: Session, timeout: float) -> int:
    """Phase 6F on the desktop: ring-3 windows. wintest paints a marker
    rectangle (0x2040C0) that the screendump must show; a drag and a resize
    follow; keys and clicks reach the program; the taskbar's + Apps menu
    launches clock (redrawn every second) and sysmon; killing the focused
    program removes its window, moves focus and returns its memory; an
    event flood at a program that never reads changes nothing."""
    failures = 0
    dump = os.path.join(ROOT, "build", "gui.ppm")
    MARKER = bytes.fromhex("2040C0")

    def check(ok, label, detail=""):
        nonlocal failures
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'}: 6F gui: {label}" + ("" if ok or not detail else f"\n  {detail}"))
        return ok

    def find(title):
        wins, _ = s.windows()
        for i, w in wins.items():
            if w[5] == title:
                return i, w
        return None, None

    def used_frames():
        m = re.search(r"(\d+) used", s.command("mem"))
        return int(m.group(1)) if m else -1

    boot = s.read_prompt(boot_timeout(timeout))
    if not check(PROMPT_RE.search(boot) and b"desktop: on" in s.log, "boots into the desktop", repr(boot[-200:])):
        return failures
    # Warm up (first spawn allocates tables), then take the baseline.
    s.command("wintest &", timeout)
    time.sleep(0.8)
    _, w = find("wintest")
    pid = re.search(r"^\s*(\d+)\s+\d+\s+running\s+\d+\s+wintest", s.command("ps"), re.M)
    if pid:
        s.command(f"kill {pid.group(1)}", timeout)
    time.sleep(0.8)
    base_frames = used_frames()

    got = s.command("wintest &", timeout)
    check("[" in got, "wintest & starts", repr(got))
    time.sleep(0.8)
    wid, w = find("wintest")
    if not check(w is not None and w[4], "a window titled wintest opens, focused", str(s.windows())):
        return failures
    cx, cy = w[0] + 2, w[1] + 22
    px = s.wait_pixel(cx + 10, cy + 70, MARKER, dump)
    check(px == MARKER, "the program's pixels are on screen (marker rectangle)", px.hex())
    check(w[2] == 224 and w[3] == 164, "window is content size + decorations", str(w))

    # Keys and a click reach it.
    s.sendkeys(["a"])
    check(b"ev key 97" in s.read_until(b"ev key 97", timeout), "a key typed on the keyboard reaches the program")
    s.click(cx + 20, cy + 20)
    check(b"ev click 1" in s.read_until(b"ev click 1", timeout), "a click on its button runs the button's handler")

    # Drag.
    start = (w[0] + 60, w[1] + 10)
    end = s.drag(start, (120, 90))
    s.read_until(b"wm: move", timeout)
    _, n = find("wintest")
    check(n and end and (n[0], n[1]) == (w[0] + end[0] - start[0], w[1] + end[1] - start[1]), "drag moves the window",
          f"{w} -> {n}")
    cx, cy = n[0] + 2, n[1] + 22
    px = s.wait_pixel(cx + 10, cy + 70, MARKER, dump)
    check(px == MARKER, "its pixels moved with it", px.hex())

    # Resize with the grip.
    grip = (n[0] + n[2] - 3, n[1] + n[3] - 3)
    end = s.drag(grip, (60, 40))
    s.read_until(b"wm: resize", timeout)
    _, r = find("wintest")
    check(r and end and (r[2], r[3]) == (n[2] + end[0] - grip[0], n[3] + end[1] - grip[1]), "grip drag resizes", f"{n} -> {r}")
    check(b"ev adopted" in s.read_until(b"ev adopted", timeout) + s.log, "the program adopted the new buffer")
    time.sleep(0.5)
    px = s.pixel_at(r[0] + r[2] - 8, r[1] + 22 + 70, dump)
    check(px == MARKER, "the marker rectangle follows the new width", px.hex())

    # Killing the focused program.
    pid = re.search(r"^\s*(\d+)\s+\d+\s+running\s+\d+\s+wintest", s.command("ps"), re.M)
    s.command(f"kill {pid.group(1)}" if pid else "ps", timeout)
    time.sleep(0.8)
    wins, _ = s.windows()
    gone = find("wintest")[0] is None
    check(gone and any(w[4] for w in wins.values()), "kill removes the window and focus moves on", str(wins))
    used = used_frames()
    check(abs(used - base_frames) <= 8, "memory is back to baseline", f"{base_frames} -> {used}")
    px = s.pixel_at(r[0] + r[2] - 8, r[1] + 22 + 70, dump)
    check(px != MARKER, "its pixels left the screen", px.hex())

    # The launcher menu.
    _, buttons = s.windows()
    apps = [b for b in buttons if b[4] == "+ Apps"]
    if check(bool(apps), "taskbar has an Apps launcher", str(buttons)):
        a = apps[0]
        s.click(a[0] + a[2] // 2, a[1] + a[3] // 2)
        # Rows of 20 px, newest app last (Phase 8H added browse): clock,
        # sysmon, browse; the menu sits right above the taskbar.
        px = s.pixel_at(a[0] + 20, a[1] - 66, dump)  # the menu's top border
        check(px == bytes.fromhex("55FFFF"), "the menu opens above the button", px.hex())
        s.click(a[0] + 20, a[1] - 54)  # first row: clock
        check(b"launch: clock" in s.read_until(b"launch: clock", timeout), "choosing clock launches /bin/clock")
        time.sleep(0.8)
        cid, c = find("Clock")
        if check(c is not None, "the Clock window opens", str(s.windows())):
            box = (c[0] + 8, c[1] + 22 + 8, c[2] - 16, 60)
            def band():
                s.screendump(dump)
                w_, h_, pix = read_ppm(dump)
                return b"".join(pix[((box[1] + y) * w_ + box[0]) * 3:((box[1] + y) * w_ + box[0] + box[2]) * 3]
                                for y in range(box[3]))
            a1 = band()
            time.sleep(1.6)
            a2 = band()
            check(a1 != a2, "the clock redraws as time passes")
        s.click(a[0] + a[2] // 2, a[1] + a[3] // 2)
        s.click(a[0] + 20, a[1] - 34)  # second row: sysmon
        check(b"launch: sysmon" in s.read_until(b"launch: sysmon", timeout), "choosing sysmon launches /bin/sysmon")
        time.sleep(0.8)
        check(find("System monitor")[0] is not None, "the sysmon window opens")
        s.click(a[0] + a[2] // 2, a[1] + a[3] // 2)
        s.click(a[0] + 20, a[1] - 14)  # third row: browse (Phase 8H)
        check(b"launch: browse" in s.read_until(b"launch: browse", timeout), "choosing browse launches /bin/browse")
        s.read_until(b"browse: title 'Home'", 30)
        time.sleep(0.5)
        check(find("Home")[0] is not None, "the browser opens about:home", str(s.windows()))
    got = s.command("ps")
    for name in ("clock", "sysmon", "browse"):
        m = re.search(rf"^\s*(\d+)\s+\d+\s+running\s+\d+\s+{name}", got, re.M)
        if m:
            s.command(f"kill {m.group(1)}", timeout)
    time.sleep(0.5)

    # A flood of mouse events at a program that never reads them.
    s.command("wintest noread &", timeout)
    time.sleep(0.8)
    _, f = find("wintest")
    if check(f is not None, "wintest noread opens a window"):
        s.warp(f[0] + 100, f[1] + 60)
        for i in range(40):
            s.monitor(f"mouse_move {(-1) ** i * 30} {(-1) ** i * 10}")
        got = s.command("ps", timeout)
        check("wintest" in got, "the flood didn't hurt the system", repr(got[-200:]))
        pid = re.search(r"^\s*(\d+)\s+\d+\s+running\s+\d+\s+wintest", got, re.M)
        if pid:
            s.command(f"kill {pid.group(1)}", timeout)
        time.sleep(0.5)
    check(find("wintest")[0] is None, "and the window goes with the process")
    return failures


def program_io_checks(s: Session, timeout: float, where: str) -> int:
    """Phase 6E: programs reading the terminal (cooked lines, Ctrl-D), a
    pipeline waiting on it, and Ctrl-C killing a `spin` (6D preempts it), typed over serial."""
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
    if True:
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
          and [b[4] for b in buttons] == ["+ Terminal", "+ Editor", "+ Apps", "#1"],
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


# ---- Phase 8H: the browser -------------------------------------------------

BROWSE_TITLE_RE = re.compile(rb"browse: title '([^']*)'")
BROWSE_SCROLL_RE = re.compile(rb"browse: scroll y=(\d+)")


def browse_checks(s: Session, timeout: float) -> int:
    """Phase 8H on the desktop: /bin/browse on rootfs /www (file://). The
    browser writes "browse: ..." lines to serial on navigation, title
    changes, scrolling, submits, errors and when a load is done; the checks
    wait for those, then look at `windows` and screendumps. Page pixels:
    the window's content starts 2 px right and 22 px down from its frame,
    and the page 30 px below that (the toolbar)."""
    failures = 0
    dump = os.path.join(ROOT, "build", "browse.ppm")

    def check(ok, label, detail=""):
        nonlocal failures
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'}: 8H browse: {label}" + ("" if ok or not detail else f"\n  {detail}"))
        return ok

    def find(title):
        wins, _ = s.windows()
        for i, w in wins.items():
            if w[5] == title:
                return i, w
        return None, None

    def wait_title(title, t=60.0):
        got = s.read_until(f"browse: title '{title}'".encode(), t)
        return f"browse: title '{title}'".encode() in got

    def kill_all(name="browse"):
        for m in re.finditer(rf"^\s*(\d+)\s+\d+\s+running\s+\d+\s+{name}", s.command("ps"), re.M):
            s.command(f"kill {m.group(1)}", timeout)
        time.sleep(0.5)

    boot = s.read_prompt(boot_timeout(timeout))
    if not check(PROMPT_RE.search(boot) and b"desktop: on" in s.log, "boots into the desktop", repr(boot[-200:])):
        return failures
    check(b"mouse with wheel" in s.log, "the PS/2 mouse is in IntelliMouse mode (wheel)")

    t0 = time.time()
    s.command("browse file:///www/index.html &", timeout)
    got = s.read_until(b"browse: done file:///www/index.html", 120)
    check(b"browse: done file:///www/index.html" in got, "loads file:///www/index.html", repr(got[-300:]))
    m = re.search(rb"browse: done file:///www/index.html in (\d+) ms", got)
    print(f"harness: browse started and loaded the test page in {time.time() - t0:.1f} s"
          + (f" (load {int(m.group(1))} ms)" if m else ""))
    time.sleep(0.8)
    wid, w = find("Wiffer test page")
    if not check(w is not None and w[4], "the window title is the page <title>", str(s.windows())):
        return failures
    px0, py0 = w[0] + 2, w[1] + 22 + 30  # page origin on screen

    def page_pixel(x, y, want, t=5.0):
        return s.wait_pixel(px0 + x, py0 + y, bytes.fromhex(want), dump, timeout=t)

    px = page_pixel(100, 40, "C02080")
    check(px == bytes.fromhex("C02080"), "the page's coloured box is on screen", px.hex())
    px = page_pixel(300, 90, "E0A020")
    check(px == bytes.fromhex("E0A020"), "a linked stylesheet applies", px.hex())

    # A link click, back and forward.
    s.click(px0 + 150, py0 + 120)
    check(wait_title("Second page"), "clicking a link navigates (title changes)")
    time.sleep(0.5)
    check(find("Second page")[0] is not None, "the window title follows")
    px = page_pixel(100, 40, "20A0C0")
    check(px == bytes.fromhex("20A0C0"), "the second page is drawn", px.hex())
    s.sendkeys(["alt-left"])
    check(wait_title("Wiffer test page"), "Alt-Left goes back")
    s.sendkeys(["alt-right"])
    check(wait_title("Second page"), "Alt-Right goes forward")
    s.sendkeys(["alt-left"])
    wait_title("Wiffer test page")
    s.read_until(b"browse: done file:///www/index.html", 30)
    time.sleep(0.5)

    # Scrolling: End, Home, the wheel.
    s.sendkeys(["end"])
    got = s.read_until(b"browse: scroll y=", 10) + s.read_until(b"\n", 2)
    m = BROWSE_SCROLL_RE.search(got)
    check(m is not None and int(m.group(1)) > 2500, "End scrolls to the bottom", repr(got[-200:]))
    vh = w[3] - 22 - 2 - 30 - 20
    px = page_pixel(100, vh - 40, "2060E0")
    check(px == bytes.fromhex("2060E0"), "the last block is on screen", px.hex())
    s.sendkeys(["home"])
    got = s.read_until(b"browse: scroll y=0", 10)
    check(b"browse: scroll y=0" in got, "Home scrolls to the top", repr(got[-200:]))
    s.warp(px0 + 600, py0 + 300)
    s.monitor("mouse_move 0 0 -1")
    got = s.read_until(b"browse: scroll y=60", 10)
    check(b"browse: scroll y=60" in got, "the wheel scrolls down 60 px a notch", repr(got[-200:]))
    s.monitor("mouse_move 0 0 1")
    got = s.read_until(b"browse: scroll y=0", 10)
    check(b"browse: scroll y=0" in got, "and back up", repr(got[-200:]))
    s.sendkeys(["pgdn"])
    got = s.read_until(b"browse: scroll y=", 10) + s.read_until(b"\n", 2)
    m = BROWSE_SCROLL_RE.search(got)
    check(m is not None and int(m.group(1)) > 300, "PgDn pages down", repr(got[-200:]))
    s.sendkeys(["home"])
    s.read_until(b"browse: scroll y=0", 10)

    # A form: type into the text field, submit with Enter.
    s.click(px0 + 440, py0 + 20)
    time.sleep(0.3)
    s.sendkeys(["a", "b", "c", "ret"])
    got = s.read_until(b"browse: title 'Second page'", 30)
    check(b"submit GET file:///www/page2.html?q=wifferabc&c=on&s=one" in got, "a form submits by GET with the typed text",
          repr(got[-300:]))

    # Errors and hostile pages, each in its own browser.
    s.command("browse file:///www/missing.html &", timeout)
    got = s.read_until(b"browse: title 'File not found'", 60)
    check(b"browse: error file:///www/missing.html: File not found" in got, "a missing file is an error page", repr(got[-300:]))
    for name in ("deep", "junk"):
        s.command(f"browse file:///www/{name}.html &", timeout)
        got = s.read_until(f"browse: done file:///www/{name}.html".encode(), 120)
        check(f"browse: done file:///www/{name}.html".encode() in got, f"loads the hostile page {name}.html", repr(got[-300:]))
    time.sleep(1.0)
    got = s.command("ps", timeout)
    n = len(re.findall(r"running\s+\d+\s+browse", got))
    check(n == 4, "all four browsers still run after the hostile pages", repr(got))
    m = re.search(r"(\d+) used \((\d+) MiB\)", s.command("mem", timeout))
    if m:
        print(f"harness: memory in use with four browsers open: {m.group(2)} MiB")
    kill_all()
    check(find("Wiffer test page")[0] is None, "killing the browser closes its window")

    # Over the network: the harness's HTTP server, HTTPS with the test CA
    # (fetched with /bin/fetch), and a refused connection.
    certs = os.path.join(ROOT, "tests", "certs")
    with open(os.path.join(certs, "roots.der"), "rb") as f:
        ca = f.read()
    page = (b"<!DOCTYPE html><title>Over HTTP</title><link rel=stylesheet href=/s.css>"
            b"<div id=b style='width:200px;height:80px;background:#30A050'></div><img src=/g.png>")
    with open(os.path.join(ROOT, "rootfs", "www", "green.png"), "rb") as f:
        png = f.read()
    files = {"/": (page, [("Content-Type", "text/html")]), "/s.css": (b"body{margin:0}", [("Content-Type", "text/css")]),
             "/g.png": (png, [("Content-Type", "image/png")]), "/testca.der": (ca, []),
             "/moved": ("redirect", 302, "/")}
    port, stop = fetch_server(files)
    tport, tstop = fetch_server({"/": (b"<title>Over HTTPS</title><p>secure", [("Content-Type", "text/html")])},
                                tls=(os.path.join(certs, "leaf-ec.chain.pem"), os.path.join(certs, "leaf-ec.key.pem")))
    try:
        s.command(f"browse http://10.0.2.2:{port}/moved &", timeout)
        got = s.read_until(b"browse: title 'Over HTTP'", 90)
        got += s.read_until(b"browse: done http://10.0.2.2", 60)
        got += s.read_until(b"bytes)", 5)
        check(b"browse: title 'Over HTTP'" in got and b"2/2 resources" in got,
              "http://: a redirect, then the page with its stylesheet and image", repr(got[-400:]))
        time.sleep(0.8)
        _, w = find("Over HTTP")
        if check(w is not None, "the HTTP page's window", str(s.windows())):
            px = s.wait_pixel(w[0] + 2 + 100, w[1] + 22 + 30 + 40, bytes.fromhex("30A050"), dump)
            check(px == bytes.fromhex("30A050"), "the HTTP page is drawn", px.hex())
        # (Command lines stay short: the terminal window is 76 columns wide.)
        s.command(f"fetch -o /ca.der http://10.0.2.2:{port}/testca.der", 30.0)
        s.command(f"browse --ca /ca.der -r localhost:10.0.2.2 https://localhost:{tport}/ &", timeout)
        got = s.read_until(b"browse: title 'Over HTTPS'", 90)
        check(b"browse: title 'Over HTTPS'" in got, "https:// with the test CA (TLS 1.3)", repr(got[-400:]))
        s.command(f"browse -r localhost:10.0.2.2 https://localhost:{tport}/ &", timeout)
        got = s.read_until(b"browse: title 'Secure connection failed'", 90)
        check(b"Secure connection failed: TLS:" in got,
              "an untrusted certificate is a TLS error page", repr(got[-400:]))
        s.command(f"browse http://10.0.2.2:{free_port()}/ &", timeout)
        got = s.read_until(b"browse: title 'Connection refused'", 60)
        check(b"browse: title 'Connection refused'" in got, "a closed port is a connection-refused page", repr(got[-400:]))
        s.command("browse http://no-such-host.invalid/ &", timeout)
        got = s.read_until(b"browse: title 'Server not found'", 60)
        check(b"browse: title 'Server not found'" in got, "an unknown host is a DNS error page", repr(got[-400:]))
    finally:
        stop()
        tstop()
    got = s.command("ps", timeout)
    check(len(re.findall(r"running\s+\d+\s+browse", got)) == 5, "every browser survived", repr(got))
    kill_all()
    return failures


def web_checks(s: Session, timeout: float) -> int:
    """Phase 8I on the desktop: /bin/browse against tests/web_server.py (HTTP
    and, with the test CA, HTTPS) serving tests/web/. Layout, image, form,
    cookie, redirect, chunked and compressed fixtures, then hostile servers
    (stalls, truncation, reset, garbage, huge headers, an endless stream, a
    decompression bomb, a PNG with lying dimensions): after each the browser
    must still be alive. Waits are on the browser's "browse: " serial lines
    with generous timeouts, never on sleeps alone. Page pixels: the window's
    content starts 2 px right and 22 px down of its frame, and the page 30 px
    below that (the toolbar)."""
    import web_server
    failures = 0
    dump = os.path.join(ROOT, "build", "web.ppm")

    def check(ok, label, detail=""):
        nonlocal failures
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'}: 8I web: {label}" + ("" if ok or not detail else f"\n  {detail}"))
        return ok

    def find(title):
        wins, _ = s.windows()
        for i, w in wins.items():
            if w[5] == title:
                return i, w
        return None, None

    def browsers():
        return re.findall(r"^\s*(\d+)\s+\d+\s+running\s+\d+\s+browse", s.command("ps", timeout), re.M)

    def kill_all():
        for pid in browsers():
            s.command(f"kill {pid}", timeout)
        for _ in range(20):
            if not browsers():
                break
            time.sleep(0.25)

    boot = s.read_prompt(boot_timeout(timeout))
    if not check(PROMPT_RE.search(boot) and b"desktop: on" in s.log, "boots into the desktop", repr(boot[-200:])):
        return failures

    srv = web_server.WebServer()
    tsrv = web_server.WebServer(tls=True)
    base = f"http://10.0.2.2:{srv.port}"
    sbase = f"https://localhost:{tsrv.port}"
    TLSARGS = "--ca /ca.der -r localhost:10.0.2.2"  # (the terminal is 76 columns wide: keep lines short)
    try:
        web_checks_run(s, timeout, check, find, browsers, kill_all, srv, tsrv, base, sbase, TLSARGS, dump)
    finally:
        srv.stop()
        tsrv.stop()
    return failures


def web_checks_run(s, timeout, check, find, browsers, kill_all, srv, tsrv, base, sbase, TLSARGS, dump) -> int:
    """The body of web_checks (split so the servers are always stopped). Returns
    0: failures are counted by `check`."""
    def launch(url, flags=""):
        s.command(f"browse {flags} {url} &".replace("  ", " "), timeout)

    def load(url, flags="", t=120.0):
        """Open `url` in a new browser: (text up to the end of its "done"
        line, or what arrived by the deadline; whether it finished)."""
        launch(url, flags)
        got = s.read_until(f"browse: done {url}".encode(), t)
        found = f"browse: done {url}".encode() in got
        if found:
            got += s.read_until(b"\n", 10)
        return got.decode(errors="replace"), found

    def resources(text):
        m = re.search(r"(\d+)/(\d+) resources", text)
        return (int(m.group(1)), int(m.group(2))) if m else None

    def origin(title):
        _, w = find(title)
        return (w[0] + 2, w[1] + 22 + 30) if w else None

    def pixel_in_page(title, x, y, want=None, t=6.0):
        o = origin(title)
        if o is None:
            return None
        if want is None:
            return s.pixel_at(o[0] + x, o[1] + y, dump)
        return s.wait_pixel(o[0] + x, o[1] + y, bytes.fromhex(want), dump, timeout=t)

    def read_title(title, t=60.0):
        got = s.read_until(f"browse: title '{title}'".encode(), t)
        return f"browse: title '{title}'".encode() in got, got.decode(errors="replace")

    # The test CA, with /bin/fetch, as in browse_checks.
    s.command(f"fetch -o /ca.der {base}/testca.der", 30.0)

    # ---- Layout fixtures: each loads cleanly (title, no error, every
    # subresource); a few have pixels at known places.
    pages = [("layout/block.html", "Layout: block"), ("layout/inline.html", "Layout: inline"),
             ("layout/float.html", "Layout: float"), ("layout/position.html", "Layout: position"),
             ("layout/table.html", "Layout: table"), ("layout/flex.html", "Layout: flex"),
             ("layout/lists.html", "Layout: lists"), ("layout/fonts.html", "Layout: fonts"),
             ("layout/colors.html", "Layout: colors"), ("big.html", "Tall page")]
    pixels = {"layout/colors.html": [(10, 25, "FF0000"), (10, 75, "00FF00"), (10, 125, "0000FF"), (10, 175, "FF8000")],
              "layout/float.html": [(50, 50, "E04040")],
              "layout/position.html": [(340, 130, "8040C0"), (110, 45, "C0A020")]}
    t0 = time.time()
    for path, title in pages:
        got, found = load(f"{base}/{path}")
        ok = found and f"title '{title}'" in got and "browse: error" not in got and "subresource failed" not in got
        if not check(ok, f"{path} loads with title '{title}'", got[-300:]):
            kill_all()
            continue
        time.sleep(0.5)
        for x, y, want in pixels.get(path, []):
            px = pixel_in_page(title, x, y, want)
            check(px == bytes.fromhex(want), f"{path}: pixel ({x},{y}) is #{want}", px.hex() if px else "no window")
        kill_all()
    print(f"harness: {len(pages)} layout pages in {time.time() - t0:.0f} s")

    # ---- Declarative shadow DOM (Phase 9I), with no script engine: the page
    # renders pixel for pixel like its light-DOM equivalent.
    def page_region(path, title, want_pixels, w=360, h=200):
        got, found = load(f"{base}/{path}")
        ok = found and f"title '{title}'" in got and "browse: error" not in got
        if not check(ok, f"{path} loads with title '{title}'", got[-300:]):
            kill_all()
            return None
        time.sleep(0.8)
        for x, y, want in want_pixels:
            px = pixel_in_page(title, x, y, want)
            check(px == bytes.fromhex(want), f"{path}: pixel ({x},{y}) is #{want}", px.hex() if px else "no window")
        o = origin(title)
        region = None
        if o:
            s.screendump(dump)
            pw, ph, pix = read_ppm(dump)
            region = [pixel(pw, pix, o[0] + x, o[1] + y) for y in range(0, h, 2) for x in range(0, w, 2)]
        kill_all()
        return region
    dsd_pixels = [(12, 12, "802040"), (300, 25, "2060E0"), (32, 57, "E0A020")]
    shadow = page_region("layout/shadow.html", "Layout: shadow", dsd_pixels)
    light = page_region("layout/shadow-light.html", "Layout: shadow light", dsd_pixels)
    if shadow is not None and light is not None:
        diff = sum(1 for a, b in zip(shadow, light) if a != b)
        check(diff == 0, "declarative shadow DOM page renders like its light-DOM twin (JS off)", f"{diff} of {len(shadow)} sampled pixels differ")

    # ---- Images: PNG with alpha, JPEG baseline and progressive, GIF.
    got, found = load(f"{base}/images.html")
    check(found and resources(got) == (4, 4) and "can't decode" not in got, "images.html: all four images fetched and decoded", got[-300:])
    time.sleep(0.8)
    px = pixel_in_page("Images", 20, 30, "20A040")
    check(px == bytes.fromhex("20A040"), "an opaque PNG pixel is exact", px.hex() if px else "no window")
    px = pixel_in_page("Images", 60, 30)
    check(px is not None and px[0] >= 250 and 110 <= px[1] <= 145 and abs(px[1] - px[2]) <= 3,
          "a half-transparent PNG pixel blends with the page", px.hex() if px else "no window")
    for name, x in (("baseline JPEG", 150), ("progressive JPEG", 254)):
        px = pixel_in_page("Images", x, 37)
        check(px is not None and px != b"\xff\xff\xff", f"the {name} is drawn", px.hex() if px else "no window")
    kill_all()

    # ---- SVG icons (Phase 8J): <img>, inline <svg> styled by page CSS,
    # an external <use> sprite and a mask-image icon.
    got, found = load(f"{base}/icons.html")
    check(found and resources(got) == (3, 3) and "can't decode" not in got, "icons.html: the three SVG files fetched and decoded", got[-300:])
    time.sleep(0.8)
    for x, y, want, what in ((20, 20, "802040", "<img> SVG: the circle"), (3, 3, "E0A020", "<img> SVG: the square"),
                             (95, 35, "2060E0", "inline svg: fill=currentColor from page CSS"), (72, 12, "FFFFFF", "inline svg: a path"),
                             (155, 35, "30A050", "use of an external sprite"), (125, 5, "A02020", "sprite: currentColor from the page"),
                             (200, 20, "C02080", "mask-image icon: inside the mask"), (182, 2, "FFFFFF", "mask-image icon: masked out")):
        px = pixel_in_page("Icons", x, y, want)
        check(px == bytes.fromhex(want), f"icons.html: {what} (#{want})", px.hex() if px else "no window")
    kill_all()

    # ---- Navigation in one browser: the index, a link click, back and forward.
    got, found = load(f"{base}/")
    check(found and "title 'Web fixtures'" in got, "the index loads", got[-300:])
    time.sleep(0.5)
    px = pixel_in_page("Web fixtures", 40, 30, "D02080")
    check(px == bytes.fromhex("D02080"), "the index's coloured box", px.hex() if px else "no window")
    o = origin("Web fixtures")
    if o:
        s.click(o[0] + 100, o[1] + 80)
        ok, got = read_title("Layout: block")
        check(ok and "click link" in got, "clicking the first link opens the block page", got[-200:])
        s.sendkeys(["alt-left"])
        ok, got = read_title("Web fixtures")
        check(ok, "Alt-Left returns to the index", got[-200:])
        s.sendkeys(["alt-right"])
        ok, got = read_title("Layout: block")
        check(ok, "Alt-Right goes forward again", got[-200:])
    kill_all()

    # ---- Redirects.
    for code in (301, 302, 303, 307):
        launch(f"{base}/redir/{code}")
        ok, got = read_title("Redirect target", 90)
        check(ok and srv.last("/redir/ok") is not None, f"a {code} redirect is followed", got[-300:])
        kill_all()
    launch(f"{base}/redir/chain")
    ok, got = read_title("Redirect target", 90)
    check(ok and srv.count("/redir/c4") == 1, "a 301, 302, 303 and 307 chain ends at the target", got[-300:])
    kill_all()
    launch(f"{base}/redir/loop")
    ok, got = read_title("Redirect loop", 90)
    check(ok, "a redirect loop is an error page", got[-300:])
    check(len(browsers()) == 1, "the browser survives the loop")
    kill_all()

    # ---- Chunked and compressed responses.
    for path, title in (("chunked", "Chunked page"), ("gzip", "Gzip page"), ("deflate", "Deflate page")):
        got, found = load(f"{base}/{path}")
        check(found and f"title '{title}'" in got and "browse: error" not in got, f"/{path} is decoded", got[-300:])
        kill_all()

    # ---- Cookies: Set-Cookie on a redirecting response, then a page echoing what came back.
    launch(f"{base}/cookie/set")
    got = s.read_until(b"browse: title 'Cookie ", 60).decode(errors="replace") + s.read_until(b"\n", 5).decode(errors="replace")
    last = srv.last("/cookie/echo")
    ck = last["headers"].get("cookie", "") if last else ""
    check("sid=wiffer42" in got and "theme=dark" in got and "sid=wiffer42" in ck and "theme=dark" in ck,
          "cookies set by a redirect come back on the next request", f"{got[-200:]!r} {ck!r}")
    kill_all()

    # ---- Forms: type into the field, Enter. The server echoes the fields in the title.
    got, found = load(f"{base}/form.html")
    check(found, "form.html loads", got[-200:])
    time.sleep(0.5)
    o = origin("Form page")
    if o:
        s.click(o[0] + 40, o[1] + 30)
        time.sleep(0.3)
        s.sendkeys(["a", "b", "c", "ret"])
        got = s.read_until(b"browse: title 'Echo GET", 60).decode(errors="replace") + s.read_until(b"\n", 5).decode(errors="replace")
        check("submit GET" in got and "q=abc&h=hid&c=on" in got, "a GET form is echoed by the server", got[-300:])
        time.sleep(1.0)
        px = pixel_in_page("Echo GET q=abc&h=hid&c=on", 60, 30, "FFFFFF")
        check(px == b"\xff\xff\xff", "the page after a submit has no leftover text field where the input was",
              px.hex() if px else "no window")
        req = srv.last("/echo")
        check(req is not None and req["path"] == "/echo?q=abc&h=hid&c=on", "the GET query string the server saw",
              str(req and req["path"]))
        s.sendkeys(["alt-left"])
        ok, got = read_title("Form page", 30)
        check(ok, "Alt-Left goes back to the form", got[-200:])
        time.sleep(0.8)
        o = origin("Form page")
        if o:
            s.click(o[0] + 40, o[1] + 90)
            time.sleep(0.3)
            s.sendkeys(["x", "y", "z", "ret"])
            got = s.read_until(b"browse: title 'Echo POST", 60).decode(errors="replace") + s.read_until(b"\n", 5).decode(errors="replace")
            check("submit POST" in got and "p=xyz&h=post" in got, "a POST form is echoed by the server", got[-300:])
            post = None
            with srv.lock:
                for r in srv.requests:
                    if r["method"] == "POST":
                        post = r
            check(post is not None and post["body"] == b"p=xyz&h=post"
                  and post["headers"].get("content-type", "").startswith("application/x-www-form-urlencoded"),
                  "the POST body and content type the server saw", repr(post and (post["body"], post["headers"])))
    kill_all()

    # ---- Errors: an HTTP 404 with a body, a refused port.
    got, found = load(f"{base}/no/such/page")
    check("title 'Not found'" in got, "an HTTP 404 shows the server's page", got[-300:])
    kill_all()
    launch(f"http://10.0.2.2:{free_port()}/")
    ok, got = read_title("Connection refused", 60)
    time.sleep(0.5)
    check(ok and find("Connection refused")[0] is not None, "a refused connection is an error page (and the window title)", got[-300:])
    kill_all()

    # ---- HTTPS with the test CA.
    got, found = load(f"{sbase}/", TLSARGS)
    check(found and "title 'Web fixtures'" in got, "https:// index through TLS 1.3", got[-300:])
    time.sleep(0.5)
    px = pixel_in_page("Web fixtures", 40, 30, "D02080")
    check(px == bytes.fromhex("D02080"), "the https page is drawn", px.hex() if px else "no window")
    kill_all()
    got, found = load(f"{sbase}/gzip", TLSARGS)
    check(found and "title 'Gzip page'" in got, "a gzip response over TLS", got[-300:])
    kill_all()

    # ---- Hostile servers. Each in its own browser; afterwards it must be alive.
    def hostile(name, expect=None, stop=False, settle=10.0, b=base, flags="", path=None):
        """Open /hostile/<name>. Without `stop`, the load must end (a "done" or
        "error" line) and the line must match the regex `expect`. With stop=True
        the load never ends by itself: after `settle` seconds it is still
        pending, Escape (Stop) must log "browse: stopped". Either way the
        browser must still be running."""
        url = f"{b}{path or '/hostile/' + name}"
        launch(url, flags)
        pat = re.compile(rb"browse: (done|error) " + re.escape(url.encode()) + rb"[^\n]*")
        got = b""
        deadline = time.time() + (settle if stop else 120)
        while time.time() < deadline and not pat.search(got):
            got += s.read_until(b"\n", min(5.0, max(0.1, deadline - time.time())))
        m = pat.search(got)
        text = got.decode(errors="replace")
        if stop:
            check(m is None, f"hostile {name}: the load is still pending after {settle:.0f} s", text[-300:])
            s.sendkeys(["esc"])
            more = s.read_until(b"browse: stopped", 20)
            check(b"browse: stopped" in more, f"hostile {name}: Escape stops the load", more.decode(errors="replace")[-300:])
        else:
            line = m.group(0).decode(errors="replace") if m else ""
            check(m is not None and re.search(expect, line) is not None, f"hostile {name}: the load ends ({expect})", text[-400:])
        n = len(browsers())
        check(n == 1, f"hostile {name}: the browser is still running", f"{n} browsers")
        return text

    hostile("stall-headers", stop=True)
    kill_all()
    hostile("stall-body", stop=True)
    kill_all()
    hostile("truncated", r"")
    kill_all()
    hostile("reset", r"error \S+: (Connection failed|Bad response|Connection refused)")
    kill_all()
    hostile("garbage", r"error \S+: Bad response")
    kill_all()
    hostile("hugeheaders", r"")
    kill_all()
    hostile("bomb", r"error \S+: (Too large|Content encoding error)")
    kill_all()
    got = hostile("pngdims", r"done ")
    check("title 'Lying PNG'" in got, "the lying PNG page itself still loads", got[-300:])
    kill_all()
    hostile("truncated over TLS", r"", b=sbase, flags=TLSARGS, path="/ht")  # (short: the command line must fit the terminal)
    kill_all()
    # An endless chunked stream is cut off by a size limit, or stopped by hand.
    url = f"{base}/hostile/endless"
    launch(url)
    pat = re.compile(rb"browse: (done|error) " + re.escape(url.encode()) + rb"[^\n]*")
    got, deadline = b"", time.time() + 15
    while time.time() < deadline and not pat.search(got):
        got += s.read_until(b"\n", 5)
    m = pat.search(got)
    if m is None:
        s.sendkeys(["esc"])
        more = s.read_until(b"browse: stopped", 30)
        check(b"browse: stopped" in more, "hostile endless: still streaming after 15 s, Escape stops it",
              more.decode(errors="replace")[-300:])
    else:
        check(b"error" in m.group(0), "hostile endless: cut off by a limit", m.group(0).decode(errors="replace"))
    check(len(browsers()) == 1, "hostile endless: the browser is still running")
    kill_all()

    # The system is still sound afterwards: a fresh browser loads a page.
    got, found = load(f"{base}/layout/lists.html")
    check(found and "title 'Layout: lists'" in got, "a fresh browser still loads a page after all the hostile servers", got[-300:])
    m = re.search(r"(\d+) used \((\d+) MiB\)", s.command("mem", timeout))
    if m:
        print(f"harness: memory in use at the end of the web checks: {m.group(2)} MiB")
    kill_all()
    return 0


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
