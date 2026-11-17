#!/usr/bin/env python3
"""Boot the ISO headless, type commands over COM1, and check the output.

Usage:
    tests/serial_session.py                 run shell checks, then `selftest`
    tests/serial_session.py -c 'help' -c 'mem'   just print a transcript

Each command is sent after the previous prompt ("> ") appears. Exits non-zero
if any expectation fails. Assumes ./build.sh has already been run.
"""
import argparse, os, re, select, subprocess, sys, time

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
    ("mem", "usable: "),
    ("peek 0", "peek: address must be non-null"),
    ("peek zz", "usage: peek"),
    ("clear", "\x1b[2J"),
]


class Session:
    def __init__(self, extra_args=()):
        args = ["qemu-system-x86_64", "-M", "q35", "-m", "256M", "-cdrom", ISO,
                "-boot", "d", "-no-reboot", "-display", "none",
                "-serial", "stdio", "-monitor", "none",
                "-device", "isa-debug-exit,iobase=0xf4,iosize=0x04", *extra_args]
        self.p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT)
        self.out = b""

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
        self.p.kill()
        self.p.wait()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-c", "--command", action="append", help="command to send (repeatable)")
    ap.add_argument("--timeout", type=float, default=10.0)
    opts = ap.parse_args()

    s = Session()
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

        # In-kernel self-tests: QEMU exits with (code << 1) | 1.
        s.send("selftest")
        try:
            status = s.p.wait(timeout=opts.timeout)
        except subprocess.TimeoutExpired:
            status = None
        s.out += s.p.stdout.read() or b""
        sys.stdout.write(s.out.decode(errors="replace"))
        if status != 1:
            print(f"FAIL: selftest exit status {status} (want 1)")
            return 1
        return 1 if failures else 0
    finally:
        s.close()


if __name__ == "__main__":
    sys.exit(main())
