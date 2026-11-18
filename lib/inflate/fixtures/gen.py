#!/usr/bin/env python3
# Regenerates the inflate test fixtures (run from anywhere):  python3 gen.py
# Each case NAME has NAME.raw (expected output) and compressed variants.
import gzip, os, random, zlib
here = os.path.dirname(os.path.abspath(__file__))
def w(name, data): open(os.path.join(here, name), 'wb').write(data)

def raw_deflate(data, level, strategy=zlib.Z_DEFAULT_STRATEGY):
    c = zlib.compressobj(level, zlib.DEFLATED, -15, 9, strategy)
    return c.compress(data) + c.flush()

rnd = random.Random(1234)
words = [bytes(rnd.choice(b'abcdefghijklmnopqrstuvwxyz') for _ in range(rnd.randint(2, 9))) for _ in range(600)]
text = b' '.join(rnd.choice(words) for _ in range(160000))[:1_000_000]
noise = bytes(rnd.getrandbits(8) for _ in range(70000))
cases = {
    'empty': b'',
    'one': b'a',
    'hello': b'hello hello hello\n',
    'zeros': bytes(150000),                       # long matches (258)
    'noise': noise,                               # stored blocks at any level
    'text': text[:200000],
    'mixed': noise[:5000] + text[:30000] + noise[5000:9000] + bytes(2000) + text[100:60000],
    'big': text,                                  # ~1 MB
}
for name, data in cases.items():
    w(name + '.raw', data)
    for lvl in ((1, 9) if name == 'big' else (0, 1, 6, 9)):
        w('%s.l%d.zlib' % (name, lvl), zlib.compress(data, lvl))
        w('%s.l%d.deflate' % (name, lvl), raw_deflate(data, lvl))
        w('%s.l%d.gz' % (name, lvl), gzip.compress(data, lvl, mtime=0))
    if len(data) < 300000:
        for sname, s in (('huff', zlib.Z_HUFFMAN_ONLY), ('rle', zlib.Z_RLE), ('fixed', zlib.Z_FIXED)):
            w('%s.%s.deflate' % (name, sname), raw_deflate(data, 6, s))

# gzip header flags: FEXTRA, FNAME, FCOMMENT, FHCRC, all together.
def gz_member(data, flags, extra=b'', name=b'', comment=b''):
    h = bytes([0x1f, 0x8b, 8, flags, 1, 2, 3, 4, 0, 3])
    if flags & 4: h += len(extra).to_bytes(2, 'little') + extra
    if flags & 8: h += name + b'\0'
    if flags & 16: h += comment + b'\0'
    if flags & 2: h += (zlib.crc32(h) & 0xffff).to_bytes(2, 'little')
    body = raw_deflate(data, 6)
    return h + body + zlib.crc32(data).to_bytes(4, 'little') + (len(data) & 0xffffffff).to_bytes(4, 'little')
d = b'gzip header flags test ' * 50
w('flags.raw', d)
w('flags.extra.gz', gz_member(d, 4, extra=b'AB\x03\x00xyz'))
w('flags.name.gz', gz_member(d, 8, name=b'file.txt'))
w('flags.comment.gz', gz_member(d, 16, comment=b'a comment'))
w('flags.hcrc.gz', gz_member(d, 2))
w('flags.all.gz', gz_member(d, 2 | 4 | 8 | 16, extra=b'ZZ\x00\x00', name=b'n', comment=b'c'))
a, b2 = b'first member ' * 40, b'second member ' * 70
w('multi.raw', a + b2)
w('multi.gz', gz_member(a, 0) + gz_member(b2, 8, name=b'two'))
w('multi_trailing.gz', gz_member(a, 0) + b'\0\0\0\0garbage')

# Hand-built fixed-Huffman stream using every length code and every distance code.
class Bits:
    def __init__(s): s.v = 0; s.n = 0
    def put(s, val, n): s.v |= val << s.n; s.n += n
    def huff(s, code, n):  # Huffman codes are sent MSB first
        r = 0
        for i in range(n): r |= ((code >> i) & 1) << (n - 1 - i)
        s.put(r, n)
    def bytes(s): return s.v.to_bytes((s.n + 7) // 8, 'little')
LB = [3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258]
LE = [0]*8 + [1]*4 + [2]*4 + [3]*4 + [4]*4 + [5]*4 + [0]
DB = [1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577]
DE = [0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13]
b = Bits(); b.put(1, 1); b.put(1, 2)   # final block, fixed Huffman
out = bytearray()
def lit(sym):
    if sym < 144: b.huff(0x30 + sym, 8)
    elif sym < 256: b.huff(0x190 + sym - 144, 9)
    elif sym < 280: b.huff(sym - 256, 7)
    else: b.huff(0xc0 + sym - 280, 8)
for c in bytes(rnd.getrandbits(8) for _ in range(32768)): lit(c); out.append(c)
def match(lc, lx, dc, dx):
    length, dist = LB[lc] + lx, DB[dc] + dx
    lit(257 + lc)
    if LE[lc]: b.put(lx, LE[lc])
    b.huff(dc, 5)
    if DE[dc]: b.put(dx, DE[dc])
    for _ in range(length): out.append(out[-dist])
for dc in range(30):                     # every distance code, smallest and largest distance
    for dx in sorted({0, (1 << DE[dc]) - 1}):
        lc = rnd.randrange(29); match(lc, rnd.randrange(1 << LE[lc]), dc, dx)
for lc in range(29):                     # every length code, smallest and largest length
    for lx in sorted({0, (1 << LE[lc]) - 1}):
        if lc == 28 and lx: continue
        match(lc, lx, rnd.randrange(30), 0)
lit(256)
w('alldist.raw', bytes(out)); w('alldist.deflate', b.bytes())
print('ok')
