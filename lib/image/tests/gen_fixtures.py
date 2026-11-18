#!/usr/bin/env python3
"""Generates the GIF and JPEG test fixtures under lib/image/fixtures (run from the repo root).

Needs Pillow (for the source picture and CMYK), and libjpeg-turbo's cjpeg/djpeg
on PATH. The JPEG reference output is djpeg's (default settings: ISLOW IDCT,
fancy upsampling); the Swift decoder is compared against it within a small
tolerance. GIFs are written by a small encoder here (so local palettes, frame
offsets, interlace and transparency are all under control) and the expected
pixels are known by construction; the manifest stores a hash of the RGBA bytes
with transparent pixels as 0,0,0,0.
"""
import os, random, subprocess, sys
from PIL import Image, ImageDraw

OUT = 'lib/image/fixtures'
os.makedirs(OUT, exist_ok=True)

def fnv(data):
    h = 0xcbf29ce484222325
    for b in data: h = ((h ^ b) * 0x100000001b3) & 0xffffffffffffffff
    return h

def picture(w, h, seed=1):
    r = random.Random(seed)
    im = Image.new('RGB', (w, h))
    px = im.load()
    for y in range(h):
        for x in range(w):
            px[x, y] = (x * 255 // max(1, w - 1), y * 255 // max(1, h - 1), (x + y) * 255 // max(1, w + h - 2))
    d = ImageDraw.Draw(im)
    for _ in range(8):
        c = tuple(r.randrange(256) for _ in range(3))
        x, y, s = r.randrange(w), r.randrange(h), r.randrange(4, max(5, min(w, h) // 2))
        d.ellipse((x - s, y - s, x + s, y + s), fill=c)
    for _ in range(w * h // 10):
        x, y = r.randrange(w), r.randrange(h)
        p = px[x, y]
        px[x, y] = tuple(max(0, min(255, v + r.randrange(-12, 13))) for v in p)
    d.text((3, 3), 'Wiffer', fill=(255, 255, 255))
    return im

# ---- GIF ----
def lzw(indices, mincode):
    clear, eoi = 1 << mincode, (1 << mincode) + 1
    table = {bytes([i]): i for i in range(clear)}
    nxt, size = eoi + 1, mincode + 1
    out, buf, nb = bytearray(), 0, 0
    def emit(code):
        nonlocal buf, nb
        buf |= code << nb; nb += size
        while nb >= 8: out.append(buf & 255); buf >>= 8; nb -= 8
    emit(clear)
    cur = b''
    for v in indices:
        nc = cur + bytes([v])
        if nc in table: cur = nc; continue
        emit(table[cur])
        if nxt < 4096:
            table[nc] = nxt; nxt += 1
            if nxt > (1 << size) and size < 12: size += 1
        else:
            emit(clear); table = {bytes([i]): i for i in range(clear)}; nxt, size = eoi + 1, mincode + 1
        cur = bytes([v])
    emit(table[cur]); emit(eoi)
    if nb: out.append(buf & 255)
    return bytes(out)

def gif(screen, frame_pos, frame_size, indices, gpal, lpal=None, trans=None, interlace=False, mincode=8):
    sw, sh = screen; fw, fh = frame_size
    b = bytearray(b'GIF89a') + sw.to_bytes(2, 'little') + sh.to_bytes(2, 'little')
    if gpal:
        n = len(gpal); bits = max(1, (n - 1).bit_length()); full = 1 << bits
        b += bytes([0x80 | (bits - 1), 0, 0])
        for c in list(gpal) + [(0, 0, 0)] * (full - n): b += bytes(c)
    else: b += bytes([0, 0, 0])
    b += b'\x21\xf9\x04' + bytes([1 if trans is not None else 0, 0, 0, trans or 0, 0])
    b += b'\x21\xfe\x03abc\x00'                      # a comment extension to skip
    flags = 0
    if lpal:
        bits = max(1, (len(lpal) - 1).bit_length()); flags |= 0x80 | (bits - 1)
    if interlace: flags |= 0x40
    b += b'\x2c' + frame_pos[0].to_bytes(2, 'little') + frame_pos[1].to_bytes(2, 'little')
    b += fw.to_bytes(2, 'little') + fh.to_bytes(2, 'little') + bytes([flags])
    if lpal:
        for c in list(lpal) + [(0, 0, 0)] * ((1 << bits) - len(lpal)): b += bytes(c)
    rows = [indices[y * fw:(y + 1) * fw] for y in range(fh)]
    if interlace:
        order = [y for s, st in ((0, 8), (4, 8), (2, 4), (1, 2)) for y in range(s, fh, st)]
        rows = [rows[y] for y in order]
    data = lzw(bytes(v for r in rows for v in r), mincode)
    b += bytes([mincode])
    for i in range(0, len(data), 255):
        ch = data[i:i + 255]; b += bytes([len(ch)]) + ch
    b += b'\x00'
    # a second frame that must be ignored
    b += b'\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x44\x01\x00' + b'\x3b'
    return bytes(b)

manifest = []
def gif_case(name, data, screen, frame_pos, frame_size, indices, pal_of, trans):
    open(f'{OUT}/{name}.gif', 'wb').write(data)
    W, H = screen; rgba = bytearray(W * H * 4)
    fw, fh = frame_size
    for y in range(fh):
        for x in range(fw):
            X, Y = frame_pos[0] + x, frame_pos[1] + y
            if X >= W or Y >= H: continue
            v = indices[y * fw + x]
            if v == trans: continue
            r, g, bl = pal_of[v] if v < len(pal_of) else (0, 0, 0)
            o = (Y * W + X) * 4; rgba[o:o + 4] = bytes((r, g, bl, 255))
    manifest.append('%s.gif %d %d %016x' % (name, W, H, fnv(rgba)))

rnd = random.Random(7)
def palette(n): return [tuple(rnd.randrange(256) for _ in range(3)) for _ in range(n)]
def pixels(w, h, n): return [(x * 7 + y * 3 + (x * y) // 5 + (rnd.randrange(3) if (x + y) % 5 == 0 else 0)) % n for y in range(h) for x in range(w)]

p256, p16, p4 = palette(256), palette(16), palette(4)
for name, w, h, pal, il, tr in [('basic256', 70, 50, p256, False, None), ('interlaced', 40, 37, p256, True, None),
                                ('transparent', 33, 21, p16, False, 5), ('palette4', 31, 29, p4, True, 2),
                                ('palette16', 50, 50, p16, False, None)]:
    mincode = max(2, (len(pal) - 1).bit_length())
    idx = pixels(w, h, len(pal))
    gif_case('g_' + name, gif((w, h), (0, 0), (w, h), idx, pal, trans=tr, interlace=il, mincode=mincode),
             (w, h), (0, 0), (w, h), idx, pal, tr)
# Local palette, frame smaller than the screen and offset, clipped at the edge.
idx = pixels(20, 12, 16)
gif_case('g_local_offset', gif((40, 30), (30, 25), (20, 12), idx, p4, lpal=p16, trans=3, mincode=4),
         (40, 30), (30, 25), (20, 12), idx, p16, 3)
# Big enough to fill the 4096-entry code table (forces clear codes and 12-bit codes).
idx = [rnd.randrange(256) for _ in range(200 * 100)]
gif_case('g_bigcodes', gif((200, 100), (0, 0), (200, 100), idx, p256), (200, 100), (0, 0), (200, 100), idx, p256, None)
open(f'{OUT}/gifs.txt', 'w').write('\n'.join(manifest) + '\n')

# ---- JPEG ----
def run(*a, inp=None, out=None):
    subprocess.run(a, check=True, stdin=open(inp, 'rb') if inp else None, stdout=open(out, 'wb') if out else None)

tmp = os.environ.get('TMPDIR', '/tmp') + '/imgfix'
os.makedirs(tmp, exist_ok=True)
jpegs = []
def jcase(name, w, h, args, gray=False, seed=1):
    src = tmp + '/src_%s.%s' % (name, 'pgm' if gray else 'ppm')
    im = picture(w, h, seed)
    (im.convert('L') if gray else im).save(src)
    jpg = f'{OUT}/j_{name}.jpg'
    run('cjpeg', *args, inp=src, out=jpg)
    run('djpeg', '-pnm', jpg, out=f'{OUT}/j_{name}.pnm') if False else run('djpeg', jpg, out=f'{OUT}/j_{name}.pnm')

jcase('444', 100, 75, ['-quality', '85', '-sample', '1x1'])
jcase('422', 100, 75, ['-quality', '85', '-sample', '2x1'])
jcase('420', 100, 75, ['-quality', '85'])
jcase('411', 100, 75, ['-quality', '85', '-sample', '4x1'])
jcase('440', 100, 75, ['-quality', '85', '-sample', '1x2'])
jcase('gray', 100, 75, ['-quality', '85'], gray=True)
jcase('restart', 100, 75, ['-quality', '85', '-restart', '5'])
jcase('restart_rows', 100, 75, ['-quality', '75', '-restart', '2B', '-sample', '2x2'])
jcase('odd', 61, 37, ['-quality', '80'])
jcase('opt', 100, 75, ['-quality', '90', '-optimize'])
jcase('q10', 100, 75, ['-quality', '10'])
jcase('q100', 100, 75, ['-quality', '100', '-sample', '1x1'])
jcase('tiny', 8, 8, ['-quality', '90'])
jcase('one', 1, 1, ['-quality', '90'])
jcase('wide', 130, 5, ['-quality', '90'])
jcase('prog420', 100, 75, ['-quality', '85', '-progressive'])
jcase('prog444', 100, 75, ['-quality', '85', '-progressive', '-sample', '1x1'])
jcase('prog422', 61, 37, ['-quality', '85', '-progressive', '-sample', '2x1'])
jcase('prog_gray', 100, 75, ['-quality', '85', '-progressive'], gray=True)
jcase('prog_restart', 100, 75, ['-quality', '85', '-progressive', '-restart', '3'])
jcase('prog_411', 100, 75, ['-quality', '60', '-progressive', '-sample', '4x1'])

# CMYK (Adobe marker, inverted values) from Pillow; reference = Pillow's own RGB conversion.
cm = picture(48, 40, 3).convert('CMYK')
cm.save(f'{OUT}/j_cmyk.jpg', quality=90)
ref = Image.open(f'{OUT}/j_cmyk.jpg').convert('RGB')
ref.save(f'{OUT}/j_cmyk.pnm')
# Speed fixtures: 1024x768 picture as PNG, baseline JPEG and progressive JPEG.
big = picture(1024, 768, 5)
big.save(f'{OUT}/speed.png', compress_level=6)
big.save(tmp + '/speed.ppm')
run('cjpeg', '-quality', '85', inp=tmp + '/speed.ppm', out=f'{OUT}/speed.jpg')
run('cjpeg', '-quality', '85', '-progressive', inp=tmp + '/speed.ppm', out=f'{OUT}/speed_prog.jpg')
print('done')
