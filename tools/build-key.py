#!/usr/bin/env python3
"""Hash build inputs, including paths, directory membership and file contents."""
import hashlib
import pathlib
import stat
import sys

h = hashlib.sha256()
for arg in sys.argv[1:]:
    root = pathlib.Path(arg)
    paths = [root, *sorted(root.rglob('*'))] if root.is_dir() else [root]
    for path in paths:
        h.update(str(path).encode() + b'\0')
        if path.exists() or path.is_symlink():
            h.update(str(stat.S_IMODE(path.lstat().st_mode)).encode() + b'\0')
        if path.is_symlink():
            h.update(b'link\0' + str(path.readlink()).encode() + b'\0')
        if path.is_file():
            h.update(b'file\0')
            with path.open('rb') as source:
                for chunk in iter(lambda: source.read(1024 * 1024), b''):
                    h.update(chunk)
        elif path.is_dir():
            h.update(b'dir\0')
        else:
            h.update(b'missing\0')
        h.update(b'\0')
print(h.hexdigest())
