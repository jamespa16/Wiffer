// GIF decoder: the first frame only. LZW, global and local palettes, the
// transparent color index (graphic control extension) and interlacing. The
// bitmap is the logical screen size, transparent where the frame doesn't
// cover; the background color is ignored.

struct GIFDecoder {
    static func decode(_ data: [UInt8], maxBytes: Int) throws(ImageError) -> ImageBitmap {
        guard imageSniff(data) == .gif else { throw ImageError.unknownFormat }
        var r = ByteReader(data, from: 6)
        guard let sw = r.u16le(), let sh = r.u16le(), let flags = r.u8(), r.skip(2) else {
            throw ImageError.truncated
        }
        var globalPalette: [UInt32] = []
        if flags & 0x80 != 0 {
            let n = 1 << (Int(flags & 7) + 1)
            guard let t = r.bytes(n * 3) else { throw ImageError.truncated }
            globalPalette = gifPalette(t)
        }
        var transparent = -1
        while true {
            guard let b = r.u8() else { throw ImageError.truncated }
            if b == 0x3b { throw ImageError.malformed }           // trailer before any image
            if b == 0x21 {
                guard let label = r.u8() else { throw ImageError.truncated }
                if label == 0xf9 {
                    guard let size = r.u8(), size >= 4, let gf = r.u8(), r.skip(2), let ti = r.u8(),
                          r.skip(Int(size) - 4) else { throw ImageError.truncated }
                    transparent = gf & 1 != 0 ? Int(ti) : -1
                }
                if !gifSkipBlocks(&r) { throw ImageError.truncated }
                continue
            }
            if b != 0x2c { throw ImageError.malformed }
            guard let left = r.u16le(), let top = r.u16le(), let fw16 = r.u16le(), let fh16 = r.u16le(),
                  let ff = r.u8() else { throw ImageError.truncated }
            let fw = Int(fw16), fh = Int(fh16)
            var palette = globalPalette
            if ff & 0x80 != 0 {
                let n = 1 << (Int(ff & 7) + 1)
                guard let t = r.bytes(n * 3) else { throw ImageError.truncated }
                palette = gifPalette(t)
            }
            if fw == 0 || fh == 0 { throw ImageError.malformed }
            var W = Int(sw), H = Int(sh)
            if W == 0 || H == 0 {                                  // screen size missing: use the frame
                W = Int(left) + fw; H = Int(top) + fh
            }
            if !imageSizeOK(W, H, maxBytes) || !imageSizeOK(fw, fh, maxBytes) { throw ImageError.tooLarge }
            guard let minCode = r.u8(), minCode >= 1, minCode <= 11 else { throw ImageError.malformed }
            // Gather the sub-blocks.
            var lzw: [UInt8] = []
            while true {
                guard let n = r.u8() else { break }                 // truncated: decode what we have
                if n == 0 { break }
                guard let chunk = r.bytes(Int(n)) else {
                    lzw.append(contentsOf: data[r.offset..<r.end]); break
                }
                lzw.append(contentsOf: chunk)
            }
            let indices = gifLZW(lzw, Int(minCode), fw * fh)
            if indices.count == 0 && lzw.count == 0 { throw ImageError.truncated }

            var pixels = [UInt32](repeating: 0, count: W * H)
            // Row order for interlaced frames.
            var rowMap = [Int](repeating: 0, count: fh)
            if ff & 0x40 != 0 {
                var k = 0
                for (start, step) in [(0, 8), (4, 8), (2, 4), (1, 2)] {
                    var y = start
                    while y < fh { rowMap[k] = y; k += 1; y += step }
                }
            } else {
                for i in 0..<fh { rowMap[i] = i }
            }
            let l = Int(left), t = Int(top)
            for sr in 0..<fh {
                let y = t + rowMap[sr]
                if y >= H { continue }
                let base = sr * fw
                for x in 0..<fw {
                    let px = l + x
                    if px >= W { break }
                    let i = base + x
                    if i >= indices.count { break }                 // data ended early: leave transparent
                    let v = Int(indices[i])
                    if v == transparent { continue }
                    pixels[y * W + px] = v < palette.count ? palette[v] : 0xff00_0000
                }
            }
            var andA: UInt32 = 0xff
            for p in pixels { andA &= p >> 24 }
            return ImageBitmap(width: W, height: H, pixels: pixels, opaque: andA == 0xff)
        }
    }
}

private func gifPalette(_ t: [UInt8]) -> [UInt32] {
    var p = [UInt32](repeating: 0, count: t.count / 3)
    for i in 0..<p.count {
        p[i] = 0xff00_0000 | UInt32(t[3 * i]) << 16 | UInt32(t[3 * i + 1]) << 8 | UInt32(t[3 * i + 2])
    }
    return p
}

private func gifSkipBlocks(_ r: inout ByteReader) -> Bool {
    while true {
        guard let n = r.u8() else { return false }
        if n == 0 { return true }
        if !r.skip(Int(n)) { return false }
    }
}

/// LZW decode up to `limit` indices (stops at the end code, the end of the
/// data, or the limit).
private func gifLZW(_ data: [UInt8], _ minCode: Int, _ limit: Int) -> [UInt8] {
    var out = [UInt8]()
    out.reserveCapacity(min(limit, 1 << 24))
    let clear = 1 << minCode, eoi = clear + 1
    var prefix = [UInt16](repeating: 0, count: 4096)
    var suffix = [UInt8](repeating: 0, count: 4096)
    for i in 0..<clear { suffix[i] = UInt8(truncatingIfNeeded: i) }
    var next = eoi + 1
    var size = minCode + 1
    var prev = -1
    var buf: UInt32 = 0, nbits = 0, pos = 0
    var stack = [UInt8](repeating: 0, count: 4097)
    while out.count < limit {
        while nbits < size && pos < data.count { buf |= UInt32(data[pos]) << UInt32(nbits); pos += 1; nbits += 8 }
        if nbits < size { break }
        let code = Int(buf & UInt32((1 << size) - 1))
        buf >>= UInt32(size); nbits -= size
        if code == clear { next = eoi + 1; size = minCode + 1; prev = -1; continue }
        if code == eoi { break }
        var first: UInt8 = 0
        if prev < 0 {
            if code >= clear { break }                        // first code after clear must be a literal
            out.append(UInt8(truncatingIfNeeded: code))
            prev = code
            continue
        }
        var c = code
        var n = 0
        if code >= next {
            if code != next { break }                         // invalid code
            // KwKwK: the string for prev plus its own first byte.
            var q = prev
            while q >= clear { q = Int(prefix[q]) }
            first = suffix[q]
            stack[0] = first; n = 1
            c = prev
        }
        // Walk the chain back to the root, then emit in order.
        var cnt = 0
        while c >= clear && cnt < 4096 { stack[n + cnt] = suffix[c]; c = Int(prefix[c]); cnt += 1 }
        if cnt >= 4096 { break }
        stack[n + cnt] = suffix[c]; cnt += 1
        let total = n + cnt
        // stack holds: [first (KwKwK only)] then the string reversed; emit reversed part, then `first`.
        var k = total - 1
        while k >= n { if out.count < limit { out.append(stack[k]) }; k -= 1 }
        if n == 1 { if out.count < limit { out.append(stack[0]) } }
        let firstByte = stack[total - 1]
        if next < 4096 {
            prefix[next] = UInt16(truncatingIfNeeded: prev)
            suffix[next] = n == 1 ? first : firstByte
            next += 1
            if next == (1 << size) && size < 12 { size += 1 }
        }
        prev = code
    }
    return out
}
