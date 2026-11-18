#!/usr/bin/env python3
"""Reference PNG decoder for the PngSuite expected output (independent of the Swift code).

Usage: refdecode.py [--pil]     (run from the repo root)
Writes lib/image/fixtures/pngsuite/expected.txt: one line per file,
    name width height fnv1a64(RGBA bytes)     or     name reject
Rules (same as the Swift decoder documents): straight RGBA, gamma/background
ignored, 16-bit samples reduced to the high byte, tRNS applied (colour keys
compared at full precision), x*.png files must be rejected.
With --pil the output is cross-checked against Pillow (when installed): modes
Pillow represents faithfully (everything but 16-bit gray, which Pillow clips)
must match exactly.
"""
import os, struct, sys, zlib

D = 'lib/image/fixtures/pngsuite'

def fnv(data):
    h = 0xcbf29ce484222325
    for b in data:
        h = ((h ^ b) * 0x100000001b3) & 0xffffffffffffffff
    return h

def decode(path):
    d = open(path, 'rb').read()
    if d[:8] != b'\x89PNG\r\n\x1a\n': raise ValueError('signature')
    pos, chunks = 8, []
    while pos < len(d):
        n, = struct.unpack('>I', d[pos:pos + 4]); t = d[pos + 4:pos + 8]
        body = d[pos + 8:pos + 8 + n]
        crc, = struct.unpack('>I', d[pos + 8 + n:pos + 12 + n])
        if zlib.crc32(t + body) != crc and not (t[0] & 0x20):   # critical chunk
            raise ValueError('crc')
        if zlib.crc32(t + body) == crc: chunks.append((t, body))
        pos += 12 + n
        if t == b'IEND': break
    w, h, depth, ct, comp, filt, il = struct.unpack('>IIBBBBB', chunks[0][1])
    if ct not in (0, 2, 3, 4, 6) or depth not in {0: (1, 2, 4, 8, 16), 2: (8, 16), 3: (1, 2, 4, 8), 4: (8, 16), 6: (8, 16)}[ct]:
        raise ValueError('ihdr')
    pal, trns = None, None
    idat = b''
    for t, body in chunks[1:]:
        if t == b'PLTE' and ct == 3: pal = [tuple(body[i:i + 3]) for i in range(0, len(body), 3)]
        if t == b'tRNS': trns = body
        if t == b'IDAT': idat += body
    if not idat: raise ValueError('no idat')
    raw = zlib.decompress(idat)
    ch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ct]
    bpp = max(1, ch * depth // 8)
    out = [[None] * w for _ in range(h)]
    passes = [(0, 0, 1, 1)] if il == 0 else [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
    off = 0
    for xs, ys, dx, dy in passes:
        pw = (w - xs + dx - 1) // dx; ph = (h - ys + dy - 1) // dy
        if pw <= 0 or ph <= 0: continue
        rb = (pw * ch * depth + 7) // 8
        prev = bytearray(rb)
        for row in range(ph):
            f = raw[off]; line = bytearray(raw[off + 1:off + 1 + rb]); off += 1 + rb
            for i in range(rb):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]; c = prev[i - bpp] if i >= bpp else 0
                if f == 1: line[i] = (line[i] + a) & 255
                elif f == 2: line[i] = (line[i] + b) & 255
                elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
                elif f == 4:
                    p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                    line[i] = (line[i] + (a if pa <= pb and pa <= pc else (b if pb <= pc else c))) & 255
                elif f != 0: raise ValueError('filter')
            prev = line
            for i in range(pw):
                # samples of pixel i
                if depth == 16: s = [line[(i * ch + k) * 2] << 8 | line[(i * ch + k) * 2 + 1] for k in range(ch)]
                elif depth == 8: s = [line[i * ch + k] for k in range(ch)]
                else:
                    bit = i * depth
                    s = [(line[bit >> 3] >> (8 - depth - (bit & 7))) & ((1 << depth) - 1)]
                hi = (lambda v: v >> 8) if depth == 16 else (lambda v: v)
                if ct == 0:
                    g = s[0]; g8 = hi(g) if depth >= 8 else g * 255 // ((1 << depth) - 1)
                    a = 0 if trns and g == struct.unpack('>H', trns[:2])[0] & ((1 << depth) - 1) else 255
                    px = (g8, g8, g8, a)
                elif ct == 2:
                    a = 0 if trns and tuple(s) == struct.unpack('>HHH', trns[:6]) else 255
                    if trns and depth == 8: a = 0 if tuple(s) == tuple(v & 255 for v in struct.unpack('>HHH', trns[:6])) else 255
                    px = (hi(s[0]), hi(s[1]), hi(s[2]), a)
                elif ct == 3:
                    r, g, b = pal[s[0]]; a = trns[s[0]] if trns and s[0] < len(trns) else 255
                    px = (r, g, b, a)
                elif ct == 4: px = (hi(s[0]),) * 3 + (hi(s[1]),)
                else: px = tuple(hi(v) for v in s)
                out[ys + row * dy][xs + i * dx] = px
    return w, h, out

def main():
    pil = None
    if '--pil' in sys.argv:
        from PIL import Image
        pil = Image
    lines, mism = [], 0
    for f in sorted(os.listdir(D)):
        if not f.endswith('.png'): continue
        if f.startswith('x'):
            try: decode(os.path.join(D, f)); print('WARNING: %s decoded but should be rejected' % f)
            except Exception: pass
            lines.append('%s reject' % f); continue
        w, h, px = decode(os.path.join(D, f))
        rgba = bytes(v for row in px for p in row for v in p)
        lines.append('%s %d %d %016x' % (f, w, h, fnv(rgba)))
        if pil:
            im = pil.open(os.path.join(D, f))
            if im.mode in ('I;16', 'I'): continue   # Pillow clips 16-bit gray
            if im.mode == 'LA' or im.mode == 'PA': im = im.convert('RGBA')
            pr = im.convert('RGBA').tobytes()
            if im.mode in ('RGB', 'RGBA') and im.info.get('transparency') is not None and im.mode == 'RGB':
                pass
            if pr != rgba:
                mism += 1; print('PIL mismatch', f, im.mode)
    open(os.path.join(D, 'expected.txt'), 'w').write('\n'.join(lines) + '\n')
    print(len(lines), 'entries,', mism, 'Pillow mismatches')

main()
