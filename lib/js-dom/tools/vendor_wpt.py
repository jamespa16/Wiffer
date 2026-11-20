#!/usr/bin/env python3
"""Vendor the WPT subset lib/js-dom's host tests run (ROADMAP Phase 9G).

    git clone --depth 1 --filter=blob:none --sparse https://github.com/web-platform-tests/wpt.git /tmp/wpt
    git -C /tmp/wpt sparse-checkout set dom/nodes dom/events dom/collections dom/lists resources html/dom
    python3 lib/js-dom/tools/vendor_wpt.py /tmp/wpt

Copies testharness.js, the WPT license, the selected tests and the helper
scripts they load into lib/js-dom/fixtures/wpt/, and writes tests.txt (one
test path per line) and COMMIT. Selection: testharness.js tests in the
directories below that run without rendering, frames, workers, XML or
WebDriver (see SKIP_PATTERNS); the floor in tests/wpt-floor.txt is a total
subtest pass count over all of them.
"""
import os
import re
import shutil
import subprocess
import sys

DIRS = ["dom/nodes", "dom/events", "dom/collections", "dom/lists", "html/dom/documents/dom-tree-accessors"]
TOP_FILES = ["dom/common.js", "dom/constants.js"]

SKIP_PATTERNS = [
    r"crash", r"iframe", r"frame", r"\.sub\.", r"\.https\.", r"tentative", r"worker", r"realm",
    r"testdriver", r"xhtml", r"\.xml$", r"\.svg$", r"\.xht$", r"idlharness", r"incumbent", r"cross-",
    r"not-fully-active", r"adoption", r"characterset", r"base-url", r"Document-URL", r"Document-contentType",
    r"NodeList-static-length", r"window-composed-path", r"handler-count", r"moveBefore", r"insertion-removing",
    r"focus-event-document-move", r"pointer-event-document-move", r"Document-constructor",
    r"Node-cloneNode-document", r"Node-cloneNode-external", r"Document-createEvent-touchevent",
    r"webkit-", r"scrolling", r"click-on-absolute", r"keypress", r"replace-event-listener",
]

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "fixtures", "wpt")


def skipped(path):
    return any(re.search(p, path) for p in SKIP_PATTERNS)


def uses_testharness(text):
    return "testharness.js" in text or text.lstrip().startswith("//") or "test(" in text


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    src = sys.argv[1]
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    commit = subprocess.run(["git", "-C", src, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    with open(os.path.join(OUT, "COMMIT"), "w") as f:
        f.write(commit + "\n")
    for f in ["LICENSE.md", "resources/testharness.js"]:
        dst = os.path.join(OUT, f)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy(os.path.join(src, f), dst)
    tests = []
    helpers = set(TOP_FILES)
    for d in DIRS:
        for name in sorted(os.listdir(os.path.join(src, d))):
            path = d + "/" + name
            full = os.path.join(src, path)
            if not os.path.isfile(full):
                continue
            is_page = name.endswith(".html") or name.endswith(".htm")
            is_any = name.endswith(".any.js") or name.endswith(".window.js")
            if not (is_page or is_any) or skipped(path):
                continue
            text = open(full, encoding="utf-8", errors="replace").read()
            if is_page and "testharness.js" not in text:
                continue
            if "testdriver" in text or "<iframe" in text or "window.open(" in text or "new Worker" in text:
                continue
            tests.append(path)
            # Local helper scripts (src="x.js", "../x.js", "/dom/x.js", META: script=).
            refs = re.findall(r'<script[^>]+src=["\']([^"\']+)["\']', text) + re.findall(r"META:\s*script=(\S+)", text)
            for r in refs:
                if r.startswith("/resources/"):
                    continue
                if r.startswith("/"):
                    helpers.add(r[1:])
                else:
                    helpers.add(os.path.normpath(os.path.join(d, r)))
    for h in sorted(helpers):
        s = os.path.join(src, h)
        if os.path.isfile(s):
            dst = os.path.join(OUT, h)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy(s, dst)
    for t in tests:
        dst = os.path.join(OUT, t)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy(os.path.join(src, t), dst)
    with open(os.path.join(OUT, "tests.txt"), "w") as f:
        for t in tests:
            f.write(t + "\n")
    print("vendored %d tests, %d helpers from %s" % (len(tests), len(helpers), commit))
    return 0


if __name__ == "__main__":
    sys.exit(main())
