#!/usr/bin/env python3
# Generates SHA-2 and AES constants as Swift array literals (the body of
# lib/crypto/tables.swift): python3 -I lib/crypto/fixtures/gen_tables.py
def primes(n):
    out, c = [], 2
    while len(out) < n:
        if all(c % p for p in out):
            out.append(c)
        c += 1
    return out

def iroot(x, k):
    lo, hi = 0, 1 << (x.bit_length() // k + 2)
    while lo < hi:
        m = (lo + hi + 1) // 2
        if m ** k <= x: lo = m
        else: hi = m - 1
    return lo

def frac_root(p, k, bits):
    return iroot(p << (k * bits), k) & ((1 << bits) - 1)

def arr(name, ty, vals, width, per):
    print(f"let {name}: [{ty}] = [")
    for i in range(0, len(vals), per):
        print("    " + ", ".join(f"0x{v:0{width}x}" for v in vals[i:i+per]) + ",")
    print("]")

P = primes(80)
arr("sha256K", "UInt32", [frac_root(p, 3, 32) for p in P[:64]], 8, 8)
arr("sha256IV", "UInt32", [frac_root(p, 2, 32) for p in P[:8]], 8, 8)
arr("sha512K", "UInt64", [frac_root(p, 3, 64) for p in P[:80]], 16, 4)
arr("sha512IV", "UInt64", [frac_root(p, 2, 64) for p in P[:8]], 16, 4)
arr("sha384IV", "UInt64", [frac_root(p, 2, 64) for p in P[8:16]], 16, 4)

def gmul(a, b):
    r = 0
    while b:
        if b & 1: r ^= a
        a <<= 1
        if a & 0x100: a ^= 0x11b
        b >>= 1
    return r

def inv(a):
    if a == 0: return 0
    for b in range(1, 256):
        if gmul(a, b) == 1: return b

def sbox(a):
    b = inv(a)
    s = b
    for i in range(1, 5):
        s ^= ((b << i) | (b >> (8 - i))) & 0xff
    return s ^ 0x63

S = [sbox(i) for i in range(256)]
arr("aesSBox", "UInt8", S, 2, 16)
te0 = [(gmul(s, 2) << 24) | (s << 16) | (s << 8) | gmul(s, 3) for s in S]
arr("aesTe0", "UInt32", te0, 8, 8)
