#!/usr/bin/env python3
"""Extract the RFC 8448 traces used by lib/tls tests into rfc8448.txt.

    python3 -I lib/tls/fixtures/gen_rfc8448.py rfc8448.txt

(rfc8448.txt from https://www.rfc-editor.org/rfc/rfc8448.txt.) Every
"label (N octets): hex" value in sections 3 (Simple 1-RTT Handshake) and 5
(HelloRetryRequest) is written as one line

    s<section>.<who>.<action>.<label>[.<n>] <hex>

with spaces and punctuation in action/label turned into '_' and a counter
when the same key repeats. Lengths are checked against the octet counts.
"""
import os, re, sys

def slug(s):
    return re.sub(r"[^a-z0-9]+", "_", s.lower()).strip("_")

def main():
    text = open(sys.argv[1], encoding="ascii", errors="replace").read().splitlines()
    out = []
    section = None
    who = action = None
    label = None
    want = 0
    buf = []
    seen = {}

    def flush():
        nonlocal label, buf
        if label is None:
            return
        data = bytes.fromhex("".join(buf))
        if len(data) != want:
            sys.exit(f"length mismatch for {label}: {len(data)} != {want}")
        key = f"s{section}.{who}.{slug(action)}.{slug(label)}"
        n = seen.get(key, 0)
        seen[key] = n + 1
        if n:
            key += f".{n}"
        out.append(f"{key} {data.hex()}")
        label, buf = None, []

    for line in text:
        m = re.match(r"^(\d+)\.\s", line)
        if m:
            flush()
            section = int(m.group(1))
            continue
        if section not in (3, 5):
            continue
        if line.startswith("RFC 8448") or line.startswith("Thomson") or not line.strip():
            continue
        m = re.match(r"^\s+\{(client|server)\}\s+(.*)$", line)
        if m:
            flush()
            who, action = m.group(1), m.group(2)
            continue
        m = re.match(r"^\s+([A-Za-z][A-Za-z0-9 ]*?) \((\d+) octets\):\s*(.*)$", line)
        if m:
            flush()
            label, want = m.group(1), int(m.group(2))
            rest = m.group(3)
            buf = [] if rest.startswith("(") else [rest.replace(" ", "")]
            continue
        if label is not None and re.match(r"^\s+([0-9a-f]{2}\s*)+$", line):
            buf.append(line.replace(" ", ""))
            continue
        # A continuation of the action text ("(same as server)" etc.)
        flush()
    flush()
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "rfc8448.txt")
    with open(path, "w") as f:
        f.write("# RFC 8448 sections 3 and 5, extracted by gen_rfc8448.py\n")
        f.write("\n".join(out) + "\n")
    print(f"{len(out)} values -> {path}")

main()
