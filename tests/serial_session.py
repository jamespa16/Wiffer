#!/usr/bin/env python3
"""Boot the ISO headless, type commands over COM1, and check the output.

Usage:
    tests/serial_session.py                 run shell checks, then `selftest`
    tests/serial_session.py -c 'help' -c 'mem'   just print a transcript

Each command is sent after the previous prompt ("> ") appears. Each
`fault <kind>` check boots its own QEMU (a fault halts the machine); those
boot in parallel with the main session. Exits non-zero
if any expectation fails. Assumes ./build.sh has already been run.
"""
import argparse, os, re, select, socket, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ISO = os.path.join(ROOT, "build", "wiffer.iso")
MONITOR_SOCK = os.path.join(ROOT, "build", "mon.sock")

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

UPTIME_RE = re.compile(r"uptime: (\d+\.\d\d) s \((\d+) ticks\)")
MOUSE_RE = re.compile(r"mouse: x=(\d+) y=(\d+) buttons=(\d+)")

# Typed on the PS/2 keyboard through the QEMU monitor (`sendkey`), so these
# exercise IRQ1 + the scancode decoder end to end: (keys, expected output).
# The shell echoes keystrokes over serial, then runs the line.
KEYBOARD_CHECKS = [
    (["e", "c", "h", "o", "spc", "h", "i", "ret"], "echo hi\r\nhi\r\n"),
    (["e", "c", "h", "o", "spc", "shift-h", "i", "shift-1", "spc", "x", "backspace", "y", "ret"],
     "\r\nHi! y\r\n"),
]

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
        mon = ["-monitor", "none"]
        if monitor:
            if os.path.exists(MONITOR_SOCK):
                os.unlink(MONITOR_SOCK)
            mon = ["-monitor", f"unix:{MONITOR_SOCK},server,nowait"]
        args = ["qemu-system-x86_64", "-M", "q35", "-m", "256M", "-cdrom", ISO,
                "-boot", "d", "-no-reboot", "-display", "none",
                "-serial", "stdio", *mon,
                "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04", *extra_args]
        self.p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT)
        self.out = b""
        self.mon = None

    def monitor(self, cmd: str, timeout=5.0) -> str:
        """Run a QEMU monitor (HMP) command and return its output."""
        if self.mon is None:
            deadline = time.time() + timeout
            while True:
                try:
                    self.mon = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    self.mon.connect(MONITOR_SOCK)
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

    def read_until(self, needle: bytes, timeout=10.0) -> bytes:
        if needle == PROMPT:
            return self.read_prompt(timeout)
        deadline = time.time() + timeout
        while needle not in self.out:
            remaining = deadline - time.time()
            if remaining <= 0 or self.p.poll() is not None:
                break
            r, _, _ = select.select([self.p.stdout], [], [], remaining)
            if r:
                chunk = os.read(self.p.stdout.fileno(), 4096)
                if not chunk:
                    break
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
            r, _, _ = select.select([self.p.stdout], [], [], remaining)
            if r:
                chunk = os.read(self.p.stdout.fileno(), 4096)
                if not chunk:
                    got, self.out = self.out, b""
                    return got
                self.out += chunk

    def send(self, text: str):
        for ch in text.encode() + b"\r":
            self.p.stdin.write(bytes([ch]))
            self.p.stdin.flush()
            time.sleep(0.005)  # don't overrun the 16-byte UART FIFO

    def close(self):
        if self.mon is not None:
            self.mon.close()
        self.p.kill()
        self.p.wait()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-c", "--command", action="append", help="command to send (repeatable)")
    ap.add_argument("--timeout", type=float, default=10.0)
    opts = ap.parse_args()

    # Each fault halts its machine, so every kind gets its own QEMU, booted now
    # so they run alongside the main session.
    faults = [] if opts.command else [(kind, want, Session()) for kind, want in FAULT_CHECKS]
    s = Session(monitor=not opts.command)
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
