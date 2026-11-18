#!/usr/bin/env python3
# python3 -I lib/crypto/fixtures/gen_aead.py lib/crypto/fixtures/aead.txt
# Writes "alg key nonce aad plaintext sealed"
# ('-' for empty) from Python `cryptography` (OpenSSL), deterministic inputs.
import sys, hashlib
from cryptography.hazmat.primitives.ciphers.aead import AESGCM, ChaCha20Poly1305

def det(tag, n):
    out = b""
    i = 0
    while len(out) < n:
        out += hashlib.sha256(("%s/%d" % (tag, i)).encode()).digest()
        i += 1
    return out[:n]

def h(b):
    return b.hex() if b else "-"

lines = ["# alg key nonce aad plaintext sealed(ct||tag), from Python cryptography"]
lens = [0, 1, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 128, 129, 255, 256, 300, 1000]
for i, n in enumerate(lens):
    for alg, ks in (("gcm", 16), ("gcm", 32), ("chacha", 32)):
        key = det("k%s%d%d" % (alg, ks, i), ks)
        nonce = det("n%d%s" % (i, alg), 12)
        aad = det("a%d" % i, (i * 5) % 40)
        p = det("p%d" % i, n)
        c = (AESGCM(key) if alg == "gcm" else ChaCha20Poly1305(key)).encrypt(nonce, p, aad)
        lines.append(" ".join([alg, key.hex(), nonce.hex(), h(aad), h(p), c.hex()]))
open(sys.argv[1], "w").write("\n".join(lines) + "\n")
