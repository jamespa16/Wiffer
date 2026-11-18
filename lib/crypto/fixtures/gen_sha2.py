#!/usr/bin/env python3
# python3 -I lib/crypto/fixtures/gen_sha2.py lib/crypto/fixtures/sha2.txt
# Writes "len sha256 sha384 sha512" for a
# deterministic message (byte i = (i*7+3) & 0xff) of each length.
import hashlib, sys
out = sys.argv[1]
lens = sorted(set(list(range(0, 260)) + [511, 512, 1000, 4095, 4096, 10007]))
with open(out, "w") as f:
    for n in lens:
        m = bytes((i * 7 + 3) & 0xff for i in range(n))
        f.write("%d %s %s %s\n" % (n, hashlib.sha256(m).hexdigest(),
                                   hashlib.sha384(m).hexdigest(), hashlib.sha512(m).hexdigest()))
