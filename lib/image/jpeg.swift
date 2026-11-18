// JPEG decoder: baseline and extended-sequential Huffman (8-bit), and
// progressive (spectral selection and successive approximation). Grayscale,
// YCbCr (4:4:4, 4:2:2, 4:2:0, 4:4:0, 4:1:1 and any integral ratio), RGB and
// Adobe CMYK/YCCK, restart markers. Arithmetic coding, lossless and 12-bit
// precision are .unsupported.
//
// The math follows libjpeg: the accurate integer IDCT ("islow"), "fancy"
// triangle-filter chroma upsampling for 2x1, 1x2 and 2x2 (plain replication for
// other ratios), and fixed-point YCbCr -> RGB. Output is within a level or two
// of libjpeg's default. Corrupt or truncated entropy data decodes as far as it
// goes and the rest of the image is whatever the zero bits produce, like
// browsers do; structural problems throw.

private let jpegZigzag: [Int] = [
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
    63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63, 63,  // guard for k > 63 corruption
]

private struct JPEGHuff {
    var lookup = [UInt16](repeating: 0, count: 512)   // len << 8 | sym for codes <= 9 bits
    var maxcode = [Int](repeating: -1, count: 18)
    var valoff = [Int](repeating: 0, count: 17)
    var vals = [UInt8](repeating: 0, count: 256)
    var valid = false

    init() {}

    init?(counts: [Int], symbols: [UInt8]) {
        var code = 0, k = 0
        for l in 1...16 {
            let c = counts[l - 1]
            valoff[l] = k - code
            if c > 0 {
                if code + c > (1 << l) { return nil }          // over-subscribed
                if l <= 9 {
                    for i in 0..<c {
                        let base = (code + i) << (9 - l)
                        for j in 0..<(1 << (9 - l)) { lookup[base + j] = UInt16(l << 8 | Int(symbols[k + i])) }
                    }
                }
                code += c; k += c
                maxcode[l] = code - 1
            } else { maxcode[l] = -1 }
            code <<= 1
        }
        for i in 0..<symbols.count { vals[i] = symbols[i] }
        valid = true
    }
}

private struct JPEGBits {
    let data: [UInt8]
    var pos: Int
    var buf: UInt64 = 0
    var cnt = 0
    var marker = false      // stopped at a marker (pos points at its 0xFF)
    var eobrun = 0

    init(_ d: [UInt8], _ p: Int) { data = d; pos = p }

    /// Make at least 49 bits available (zero bits past the end or a marker).
    @inline(__always)
    mutating func fill() {
        while cnt <= 48 {
            var b: UInt64 = 0
            if pos < data.count && !marker {
                let x = data[pos]
                if x == 0xff {
                    let n = pos + 1 < data.count ? data[pos + 1] : 0xd9
                    if n == 0 { b = 0xff; pos += 2 }
                    else if n == 0xff { pos += 1; continue }
                    else { marker = true }
                } else { b = UInt64(x); pos += 1 }
            }
            buf = buf << 8 | b
            cnt += 8
        }
    }

    @inline(__always)
    mutating func get(_ n: Int) -> Int {
        if n == 0 { return 0 }
        if cnt < n { fill() }
        cnt -= n
        return Int(truncatingIfNeeded: (buf >> UInt64(cnt)) & ((1 << UInt64(n)) - 1))
    }

    @inline(__always)
    mutating func bit() -> Int { get(1) }

    @inline(__always)
    mutating func receiveExtend(_ s: Int) -> Int {
        let v = get(s)
        return v < (1 << (s - 1)) ? v - (1 << s) + 1 : v
    }

    @inline(__always)
    mutating func huff(_ t: JPEGHuff) -> Int {
        if cnt < 16 { fill() }
        let e = Int(t.lookup[Int(truncatingIfNeeded: (buf >> UInt64(cnt - 9)) & 511)])
        if e != 0 { cnt -= e >> 8; return e & 255 }
        var l = 10
        while l <= 16 {
            let code = Int(truncatingIfNeeded: (buf >> UInt64(cnt - l)) & ((1 << UInt64(l)) - 1))
            if code <= t.maxcode[l] {
                cnt -= l
                let i = t.valoff[l] + code
                return i >= 0 && i < 256 ? Int(t.vals[i]) : 0
            }
            l += 1
        }
        cnt -= 16
        return 0
    }

    /// At a restart boundary: drop buffered bits, consume the RSTn marker.
    mutating func restart() {
        buf = 0; cnt = 0; eobrun = 0
        var p = pos
        // Skip anything up to the next marker (junk after a corrupt interval).
        while p + 1 < data.count {
            if data[p] == 0xff && data[p + 1] != 0 && data[p + 1] != 0xff {
                if data[p + 1] >= 0xd0 && data[p + 1] <= 0xd7 { pos = p + 2; marker = false; return }
                pos = p; marker = true; return
            }
            p += 1
        }
        pos = data.count
        marker = true
    }
}

private struct JPEGComp {
    var id = 0, h = 1, v = 1, tq = 0
    var bw = 0, bh = 0          // blocks per row / column, padded to whole MCUs
    var cw = 0, ch = 0          // real sample dimensions
    var base = 0                // offset of its coefficients (in Int16s)
    var plane: [UInt8] = []     // after the IDCT: bw*8 x bh*8
}

// MARK: block decoders

private func jpegBlockBaseline(_ b: inout JPEGBits, _ dc: JPEGHuff, _ ac: JPEGHuff, _ pred: inout Int,
                               _ blk: UnsafeMutablePointer<Int16>) {
    b.fill()
    let t = min(b.huff(dc), 16)
    if t > 0 { pred = pred &+ b.receiveExtend(t) }
    blk[0] = Int16(truncatingIfNeeded: pred)
    var k = 1
    while k < 64 {
        if b.cnt < 32 { b.fill() }
        let rs = b.huff(ac)
        let s = rs & 15, r = rs >> 4
        if s == 0 {
            if r == 15 { k += 16; continue }
            break
        }
        k += r
        if k > 63 { break }
        blk[jpegZigzag[k]] = Int16(truncatingIfNeeded: b.receiveExtend(s))
        k += 1
    }
}

private func jpegDCFirst(_ b: inout JPEGBits, _ dc: JPEGHuff, _ pred: inout Int, _ al: Int,
                         _ blk: UnsafeMutablePointer<Int16>) {
    b.fill()
    let t = min(b.huff(dc), 16)
    if t > 0 { pred = pred &+ b.receiveExtend(t) }
    blk[0] = Int16(truncatingIfNeeded: pred << al)
}

private func jpegDCRefine(_ b: inout JPEGBits, _ al: Int, _ blk: UnsafeMutablePointer<Int16>) {
    if b.bit() != 0 { blk[0] |= Int16(truncatingIfNeeded: 1 << al) }
}

private func jpegACFirst(_ b: inout JPEGBits, _ ac: JPEGHuff, _ ss: Int, _ se: Int, _ al: Int,
                         _ blk: UnsafeMutablePointer<Int16>) {
    if b.eobrun > 0 { b.eobrun -= 1; return }
    var k = ss
    while k <= se {
        if b.cnt < 32 { b.fill() }
        let rs = b.huff(ac)
        let s = rs & 15, r = rs >> 4
        if s != 0 {
            k += r
            if k > 63 { break }
            blk[jpegZigzag[k]] = Int16(truncatingIfNeeded: b.receiveExtend(s) << al)
            k += 1
        } else if r == 15 {
            k += 16
        } else {
            b.eobrun = 1 << r
            if r > 0 { b.eobrun += b.get(r) }
            b.eobrun -= 1
            break
        }
    }
}

private func jpegACRefine(_ b: inout JPEGBits, _ ac: JPEGHuff, _ ss: Int, _ se: Int, _ al: Int,
                          _ blk: UnsafeMutablePointer<Int16>) {
    let p1 = 1 << al, m1 = -(1 << al)
    var k = ss
    if b.eobrun == 0 {
        while k <= se {
            if b.cnt < 32 { b.fill() }
            let rs = b.huff(ac)
            var r = rs >> 4
            let s = rs & 15
            var val = 0
            if s != 0 {
                val = b.bit() != 0 ? p1 : m1
            } else if r != 15 {
                b.eobrun = 1 << r
                if r > 0 { b.eobrun += b.get(r) }
                break
            }
            // Skip over already-nonzero coefficients (refining them) and r zero ones.
            while k <= se {
                let z = jpegZigzag[k]
                let c = Int(blk[z])
                if c != 0 {
                    if b.bit() != 0 && (c & p1) == 0 {
                        blk[z] = Int16(truncatingIfNeeded: c >= 0 ? c + p1 : c + m1)
                    }
                } else {
                    r -= 1
                    if r < 0 { break }
                }
                k += 1
            }
            if val != 0 && k <= 63 { blk[jpegZigzag[k]] = Int16(truncatingIfNeeded: val) }
            k += 1
        }
    }
    if b.eobrun > 0 {
        while k <= se {
            let z = jpegZigzag[k]
            let c = Int(blk[z])
            if c != 0 && b.bit() != 0 && (c & p1) == 0 {
                blk[z] = Int16(truncatingIfNeeded: c >= 0 ? c + p1 : c + m1)
            }
            k += 1
        }
        b.eobrun -= 1
    }
}

// MARK: IDCT (libjpeg jidctint, "islow")

private func jpegIDCT(_ coef: UnsafePointer<Int16>, _ q: [Int], _ ws: inout [Int],
                      _ out: UnsafeMutablePointer<UInt8>, _ stride: Int) {
    // Columns.
    for c in 0..<8 {
        let i1 = Int(coef[c + 8]), i2 = Int(coef[c + 16]), i3 = Int(coef[c + 24]), i4 = Int(coef[c + 32])
        let i5 = Int(coef[c + 40]), i6 = Int(coef[c + 48]), i7 = Int(coef[c + 56])
        let i0 = Int(coef[c]) * q[c]
        if i1 == 0 && i2 == 0 && i3 == 0 && i4 == 0 && i5 == 0 && i6 == 0 && i7 == 0 {
            let dc = i0 << 2
            for r in 0..<8 { ws[c + 8 * r] = dc }
            continue
        }
        var z2 = i2 * q[c + 16], z3 = i6 * q[c + 48]
        var z1 = (z2 + z3) * 4433
        var tmp2 = z1 + z3 * (-15137)
        var tmp3 = z1 + z2 * 6270
        z2 = i0; z3 = i4 * q[c + 32]
        var tmp0 = (z2 + z3) << 13
        var tmp1 = (z2 - z3) << 13
        let tmp10 = tmp0 + tmp3, tmp13 = tmp0 - tmp3, tmp11 = tmp1 + tmp2, tmp12 = tmp1 - tmp2
        tmp0 = i7 * q[c + 56]; tmp1 = i5 * q[c + 40]; tmp2 = i3 * q[c + 24]; tmp3 = i1 * q[c + 8]
        z1 = tmp0 + tmp3; z2 = tmp1 + tmp2; z3 = tmp0 + tmp2
        var z4 = tmp1 + tmp3
        let z5 = (z3 + z4) * 9633
        tmp0 *= 2446; tmp1 *= 16819; tmp2 *= 25172; tmp3 *= 12299
        z1 *= -7373; z2 *= -20995; z3 *= -16069; z4 *= -3196
        z3 += z5; z4 += z5
        tmp0 += z1 + z3; tmp1 += z2 + z4; tmp2 += z2 + z3; tmp3 += z1 + z4
        let rnd = 1 << 10
        ws[c] = (tmp10 + tmp3 + rnd) >> 11
        ws[c + 56] = (tmp10 - tmp3 + rnd) >> 11
        ws[c + 8] = (tmp11 + tmp2 + rnd) >> 11
        ws[c + 48] = (tmp11 - tmp2 + rnd) >> 11
        ws[c + 16] = (tmp12 + tmp1 + rnd) >> 11
        ws[c + 40] = (tmp12 - tmp1 + rnd) >> 11
        ws[c + 24] = (tmp13 + tmp0 + rnd) >> 11
        ws[c + 32] = (tmp13 - tmp0 + rnd) >> 11
    }
    // Rows.
    for r in 0..<8 {
        let w = 8 * r
        var z2 = ws[w + 2], z3 = ws[w + 6]
        var z1 = (z2 + z3) * 4433
        var tmp2 = z1 + z3 * (-15137)
        var tmp3 = z1 + z2 * 6270
        var tmp0 = (ws[w] + ws[w + 4]) << 13
        var tmp1 = (ws[w] - ws[w + 4]) << 13
        let tmp10 = tmp0 + tmp3, tmp13 = tmp0 - tmp3, tmp11 = tmp1 + tmp2, tmp12 = tmp1 - tmp2
        tmp0 = ws[w + 7]; tmp1 = ws[w + 5]; tmp2 = ws[w + 3]; tmp3 = ws[w + 1]
        z1 = tmp0 + tmp3; z2 = tmp1 + tmp2; z3 = tmp0 + tmp2
        var z4 = tmp1 + tmp3
        let z5 = (z3 + z4) * 9633
        tmp0 *= 2446; tmp1 *= 16819; tmp2 *= 25172; tmp3 *= 12299
        z1 *= -7373; z2 *= -20995; z3 *= -16069; z4 *= -3196
        z3 += z5; z4 += z5
        tmp0 += z1 + z3; tmp1 += z2 + z4; tmp2 += z2 + z3; tmp3 += z1 + z4
        let rnd = 1 << 17
        let o = out + r * stride
        o[0] = jpegClamp((tmp10 + tmp3 + rnd) >> 18)
        o[7] = jpegClamp((tmp10 - tmp3 + rnd) >> 18)
        o[1] = jpegClamp((tmp11 + tmp2 + rnd) >> 18)
        o[6] = jpegClamp((tmp11 - tmp2 + rnd) >> 18)
        o[2] = jpegClamp((tmp12 + tmp1 + rnd) >> 18)
        o[5] = jpegClamp((tmp12 - tmp1 + rnd) >> 18)
        o[3] = jpegClamp((tmp13 + tmp0 + rnd) >> 18)
        o[4] = jpegClamp((tmp13 - tmp0 + rnd) >> 18)
    }
}

@inline(__always)
private func jpegClamp(_ v: Int) -> UInt8 {
    let x = v + 128
    return x < 0 ? 0 : (x > 255 ? 255 : UInt8(truncatingIfNeeded: x))
}

// MARK: decoder

struct JPEGDecoder {
    static func decode(_ data: [UInt8], maxBytes: Int) throws(ImageError) -> ImageBitmap {
        guard imageSniff(data) == .jpeg else { throw ImageError.unknownFormat }
        var qt = [[Int]](repeating: [Int](repeating: 0, count: 64), count: 4)
        var qtSet = [Bool](repeating: false, count: 4)
        var dcTabs = [JPEGHuff](repeating: JPEGHuff(), count: 4)
        var acTabs = [JPEGHuff](repeating: JPEGHuff(), count: 4)
        var comps: [JPEGComp] = []
        var width = 0, height = 0, hmax = 1, vmax = 1, mcusX = 0, mcusY = 0
        var progressive = false
        var restartInterval = 0
        var adobe = -1
        var coefs: [Int16] = []
        var scans = 0
        var pos = 2

        parse: while true {
            // Find the next marker.
            while pos < data.count && data[pos] != 0xff { pos += 1 }
            while pos < data.count && data[pos] == 0xff { pos += 1 }
            if pos >= data.count { break parse }
            let m = Int(data[pos]); pos += 1
            if m == 0 || m == 0x01 || (m >= 0xd0 && m <= 0xd8) { continue }
            if m == 0xd9 { break parse }
            // Segment with a length.
            guard pos + 2 <= data.count else { break parse }
            let len = Int(data[pos]) << 8 | Int(data[pos + 1])
            if len < 2 { throw ImageError.malformed }
            let segEnd = pos + len
            if segEnd > data.count {
                if scans > 0 { break parse }
                throw ImageError.truncated
            }
            var r = ByteReader(data, from: pos + 2, count: len - 2)
            switch m {
            case 0xdb:                                              // DQT
                while r.remaining > 0 {
                    guard let pq = r.u8() else { throw ImageError.malformed }
                    let id = Int(pq & 15)
                    if id > 3 || pq >> 4 > 1 { throw ImageError.malformed }
                    for k in 0..<64 {
                        guard let v = pq >> 4 == 0 ? r.u8().map({ UInt16($0) }) : r.u16() else { throw ImageError.malformed }
                        qt[id][jpegZigzag[k]] = Int(v)
                    }
                    qtSet[id] = true
                }
            case 0xc4:                                              // DHT
                while r.remaining > 0 {
                    guard let tc = r.u8() else { throw ImageError.malformed }
                    let id = Int(tc & 15), cls = Int(tc >> 4)
                    if id > 3 || cls > 1 { throw ImageError.malformed }
                    var counts = [Int](repeating: 0, count: 16)
                    var total = 0
                    for i in 0..<16 {
                        guard let c = r.u8() else { throw ImageError.malformed }
                        counts[i] = Int(c); total += Int(c)
                    }
                    if total > 256 { throw ImageError.malformed }
                    guard let syms = r.bytes(total), let t = JPEGHuff(counts: counts, symbols: syms) else {
                        throw ImageError.malformed
                    }
                    if cls == 0 { dcTabs[id] = t } else { acTabs[id] = t }
                }
            case 0xdd:                                              // DRI
                restartInterval = Int(r.u16() ?? 0)
            case 0xee:                                              // APP14 Adobe
                if len >= 14 && data[pos + 2] == 0x41 && data[pos + 3] == 0x64 && data[pos + 4] == 0x6f
                    && data[pos + 5] == 0x62 && data[pos + 6] == 0x65 { adobe = Int(data[pos + 13]) }
            case 0xc0, 0xc1, 0xc2:                                  // SOF
                if !comps.isEmpty { throw ImageError.malformed }
                progressive = m == 0xc2
                guard let prec = r.u8(), let h16 = r.u16(), let w16 = r.u16(), let nc = r.u8() else {
                    throw ImageError.malformed
                }
                if prec != 8 { throw ImageError.unsupported }
                width = Int(w16); height = Int(h16)
                if width == 0 || height == 0 || nc == 0 || nc > 4 || nc == 2 { throw ImageError.malformed }
                if !imageSizeOK(width, height, maxBytes) { throw ImageError.tooLarge }
                for _ in 0..<Int(nc) {
                    guard let id = r.u8(), let hv = r.u8(), let tq = r.u8() else { throw ImageError.malformed }
                    var c = JPEGComp()
                    c.id = Int(id); c.h = Int(hv >> 4); c.v = Int(hv & 15); c.tq = Int(tq)
                    if c.h < 1 || c.h > 4 || c.v < 1 || c.v > 4 || c.tq > 3 { throw ImageError.malformed }
                    comps.append(c)
                    hmax = max(hmax, c.h); vmax = max(vmax, c.v)
                }
                var total = 0
                mcusX = (width + 8 * hmax - 1) / (8 * hmax)
                mcusY = (height + 8 * vmax - 1) / (8 * vmax)
                for i in 0..<comps.count {
                    if hmax % comps[i].h != 0 || vmax % comps[i].v != 0 { throw ImageError.unsupported }
                    comps[i].bw = mcusX * comps[i].h
                    comps[i].bh = mcusY * comps[i].v
                    comps[i].cw = (width * comps[i].h + hmax - 1) / hmax
                    comps[i].ch = (height * comps[i].v + vmax - 1) / vmax
                    comps[i].base = total
                    total += comps[i].bw * comps[i].bh * 64
                }
                // Coefficient memory is about 2 bytes per (padded) sample: keep it near the pixel cap.
                if total > maxBytes * 3 / 2 + (1 << 20) { throw ImageError.tooLarge }
                coefs = [Int16](repeating: 0, count: total)
            case 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf:
                throw ImageError.unsupported
            case 0xda:                                              // SOS
                if comps.isEmpty { throw ImageError.malformed }
                guard let ns8 = r.u8() else { throw ImageError.malformed }
                let ns = Int(ns8)
                if ns < 1 || ns > comps.count || ns > 4 { throw ImageError.malformed }
                var idx: [Int] = [], dcSel: [Int] = [], acSel: [Int] = []
                for _ in 0..<ns {
                    guard let cid = r.u8(), let tt = r.u8() else { throw ImageError.malformed }
                    guard let ci = comps.firstIndex(where: { $0.id == Int(cid) }) else { throw ImageError.malformed }
                    if idx.contains(ci) || tt >> 4 > 3 || tt & 15 > 3 { throw ImageError.malformed }
                    idx.append(ci); dcSel.append(Int(tt >> 4)); acSel.append(Int(tt & 15))
                }
                guard let ss8 = r.u8(), let se8 = r.u8(), let a = r.u8() else { throw ImageError.malformed }
                var ss = Int(ss8), se = Int(se8), ah = Int(a >> 4), al = Int(a & 15)
                if progressive {
                    if al > 13 || ah > 13 || ss > se || se > 63 { throw ImageError.malformed }
                    if ss == 0 { if se != 0 { throw ImageError.malformed } }
                    else if ns != 1 { throw ImageError.malformed }
                } else { ss = 0; se = 63; ah = 0; al = 0 }
                // Tables the scan will use must exist, and so must the quantization tables later.
                for i in 0..<ns {
                    if (!progressive || (ss == 0 && ah == 0)) && !dcTabs[dcSel[i]].valid { throw ImageError.malformed }
                    if (!progressive || ss > 0) && !acTabs[acSel[i]].valid { throw ImageError.malformed }
                }
                var bits = JPEGBits(data, segEnd)
                let dcT = dcSel.map { dcTabs[$0] }, acT = acSel.map { acTabs[$0] }
                let prog = progressive
                let ri = restartInterval
                let cs = comps
                let mx = mcusX, my = mcusY, w = width, h = height, hm = hmax, vm = vmax
                coefs.withUnsafeMutableBufferPointer { cp in
                    jpegScan(&bits, cp.baseAddress!, cs, idx, dcT, acT, mx, my, w, h, hm, vm, ri, prog, ss, se, ah, al)
                }
                pos = bits.pos
                scans += 1
                continue parse
            default:
                break                                               // APPn, COM, ...
            }
            pos = segEnd
        }
        if comps.isEmpty || scans == 0 { throw ImageError.malformed }
        for c in comps where !qtSet[c.tq] { throw ImageError.malformed }

        // Dequantize + IDCT every block into component planes.
        var ws = [Int](repeating: 0, count: 64)
        for i in 0..<comps.count {
            let c = comps[i]
            let stride = c.bw * 8
            var plane = [UInt8](repeating: 0, count: stride * c.bh * 8)
            let q = qt[c.tq]
            coefs.withUnsafeBufferPointer { cp in
                plane.withUnsafeMutableBufferPointer { pp in
                    for by in 0..<c.bh {
                        for bx in 0..<c.bw {
                            let blk = cp.baseAddress! + c.base + (by * c.bw + bx) * 64
                            let out = pp.baseAddress! + by * 8 * stride + bx * 8
                            jpegIDCT(blk, q, &ws, out, stride)
                        }
                    }
                }
            }
            comps[i].plane = plane
        }
        coefs = []
        return try jpegAssemble(comps, width, height, hmax, vmax, adobe)
    }
}

private func jpegScan(_ bits: inout JPEGBits, _ coef: UnsafeMutablePointer<Int16>, _ comps: [JPEGComp],
                      _ scan: [Int], _ dcT: [JPEGHuff], _ acT: [JPEGHuff],
                      _ mcusX: Int, _ mcusY: Int, _ width: Int, _ height: Int, _ hmax: Int, _ vmax: Int,
                      _ restartInterval: Int, _ progressive: Bool, _ ss: Int, _ se: Int, _ ah: Int, _ al: Int) {
    var pred = [Int](repeating: 0, count: scan.count)
    let interleaved = scan.count > 1
    var total = mcusX * mcusY
    var bpr = 0
    if !interleaved {
        let c = comps[scan[0]]
        bpr = (c.cw + 7) / 8
        total = bpr * ((c.ch + 7) / 8)
    }
    for mcu in 0..<total {
        if restartInterval > 0 && mcu > 0 && mcu % restartInterval == 0 {
            bits.restart()
            for i in 0..<pred.count { pred[i] = 0 }
        }
        let n = interleaved ? scan.count : 1
        for s in 0..<n {
            let c = comps[scan[s]]
            let bh = interleaved ? c.v : 1, bw = interleaved ? c.h : 1
            for j in 0..<bh {
                for i in 0..<bw {
                    let block: Int
                    if interleaved {
                        block = ((mcu / mcusX) * c.v + j) * c.bw + (mcu % mcusX) * c.h + i
                    } else {
                        block = (mcu / bpr) * c.bw + (mcu % bpr)
                    }
                    let blk = coef + c.base + block * 64
                    if !progressive {
                        jpegBlockBaseline(&bits, dcT[s], acT[s], &pred[s], blk)
                    } else if ss == 0 {
                        if ah == 0 { jpegDCFirst(&bits, dcT[s], &pred[s], al, blk) }
                        else { jpegDCRefine(&bits, al, blk) }
                    } else if ah == 0 {
                        jpegACFirst(&bits, acT[s], ss, se, al, blk)
                    } else {
                        jpegACRefine(&bits, acT[s], ss, se, al, blk)
                    }
                }
            }
        }
    }
}

// MARK: upsampling and color conversion

/// One full-width row of component `c` at output row y, into `out[0..<width]`.
private func jpegUpsampleRow(_ c: JPEGComp, _ y: Int, _ width: Int, _ hmax: Int, _ vmax: Int,
                             _ out: inout [UInt8], _ tmp: inout [Int]) {
    let stride = c.bw * 8
    let hs = hmax / c.h, vs = vmax / c.v
    c.plane.withUnsafeBufferPointer { p in
        if hs == 1 && vs == 1 {
            let row = min(y, c.ch - 1) * stride
            for x in 0..<width { out[x] = p[row + x] }
        } else if hs == 2 && vs == 1 && c.cw > 2 {
            let row = min(y, c.ch - 1) * stride
            let n = c.cw
            for x in 0..<width {
                let i = x >> 1
                if x & 1 == 0 {
                    out[x] = i == 0 ? p[row] : UInt8(truncatingIfNeeded: (3 * Int(p[row + i]) + Int(p[row + i - 1]) + 1) >> 2)
                } else {
                    out[x] = i == n - 1 ? p[row + i] : UInt8(truncatingIfNeeded: (3 * Int(p[row + i]) + Int(p[row + i + 1]) + 2) >> 2)
                }
            }
        } else if hs == 1 && vs == 2 {
            let sy = min(y >> 1, c.ch - 1)
            let ny = y & 1 == 0 ? max(sy - 1, 0) : min(sy + 1, c.ch - 1)
            let bias = y & 1 == 0 ? 1 : 2
            let r0 = sy * stride, r1 = ny * stride
            for x in 0..<width { out[x] = UInt8(truncatingIfNeeded: (3 * Int(p[r0 + x]) + Int(p[r1 + x]) + bias) >> 2) }
        } else if hs == 2 && vs == 2 && c.cw > 2 {
            let sy = min(y >> 1, c.ch - 1)
            let ny = y & 1 == 0 ? max(sy - 1, 0) : min(sy + 1, c.ch - 1)
            let r0 = sy * stride, r1 = ny * stride
            let n = c.cw
            for i in 0..<n { tmp[i] = 3 * Int(p[r0 + i]) + Int(p[r1 + i]) }
            for x in 0..<width {
                let i = x >> 1
                if x & 1 == 0 {
                    out[x] = i == 0 ? UInt8(truncatingIfNeeded: (tmp[0] * 4 + 8) >> 4)
                        : UInt8(truncatingIfNeeded: (tmp[i] * 3 + tmp[i - 1] + 8) >> 4)
                } else {
                    out[x] = i == n - 1 ? UInt8(truncatingIfNeeded: (tmp[i] * 4 + 7) >> 4)
                        : UInt8(truncatingIfNeeded: (tmp[i] * 3 + tmp[i + 1] + 7) >> 4)
                }
            }
        } else {
            let row = min(y / vs, c.ch - 1) * stride
            for x in 0..<width { out[x] = p[row + min(x / hs, c.cw - 1)] }
        }
    }
}

private func jpegAssemble(_ comps: [JPEGComp], _ width: Int, _ height: Int, _ hmax: Int, _ vmax: Int,
                          _ adobe: Int) throws(ImageError) -> ImageBitmap {
    var pixels = [UInt32](repeating: 0, count: width * height)
    let n = comps.count
    var rows = [[UInt8]](repeating: [UInt8](repeating: 0, count: width), count: n)
    var tmp = [Int](repeating: 0, count: max(width, 8) + 16)
    // libjpeg's YCC -> RGB tables.
    var crR = [Int](repeating: 0, count: 256), cbB = crR, crG = crR, cbG = crR
    for i in 0..<256 {
        let x = i - 128
        crR[i] = (91881 * x + 32768) >> 16
        cbB[i] = (116130 * x + 32768) >> 16
        crG[i] = -46802 * x
        cbG[i] = -22554 * x + 32768
    }
    // 3 components: YCbCr unless Adobe says RGB (or the ids are R, G, B).
    var ycc = true
    if n == 3 {
        if adobe == 0 { ycc = false }
        else if adobe < 0 && comps[0].id == 0x52 && comps[1].id == 0x47 && comps[2].id == 0x42 { ycc = false }
    }
    for y in 0..<height {
        for ci in 0..<n { jpegUpsampleRow(comps[ci], y, width, hmax, vmax, &rows[ci], &tmp) }
        let o = y * width
        if n == 1 {
            for x in 0..<width { let g = UInt32(rows[0][x]); pixels[o + x] = 0xff00_0000 | g << 16 | g << 8 | g }
        } else if n == 3 {
            for x in 0..<width {
                let a = Int(rows[0][x]), b = Int(rows[1][x]), c = Int(rows[2][x])
                if ycc {
                    pixels[o + x] = jpegPack(a + crR[c], a + ((cbG[b] + crG[c]) >> 16), a + cbB[b])
                } else {
                    pixels[o + x] = jpegPack(a, b, c)
                }
            }
        } else {
            for x in 0..<width {
                var c = Int(rows[0][x]), m = Int(rows[1][x]), yy = Int(rows[2][x])
                let k = Int(rows[3][x])
                if adobe == 2 {          // YCCK: libjpeg turns it into (inverted) CMY
                    let r = c + crR[Int(rows[2][x])], g = c + ((cbG[Int(rows[1][x])] + crG[Int(rows[2][x])]) >> 16)
                    let b = c + cbB[Int(rows[1][x])]
                    c = 255 - min(255, max(0, r)); m = 255 - min(255, max(0, g)); yy = 255 - min(255, max(0, b))
                }
                if adobe >= 0 {          // Adobe stores inverted CMYK
                    pixels[o + x] = jpegPack((c * k + 127) / 255, (m * k + 127) / 255, (yy * k + 127) / 255)
                } else {
                    pixels[o + x] = jpegPack(((255 - c) * (255 - k) + 127) / 255, ((255 - m) * (255 - k) + 127) / 255,
                                              ((255 - yy) * (255 - k) + 127) / 255)
                }
            }
        }
    }
    return ImageBitmap(width: width, height: height, pixels: pixels, opaque: true)
}

@inline(__always)
private func jpegPack(_ r: Int, _ g: Int, _ b: Int) -> UInt32 {
    let rr = r < 0 ? 0 : (r > 255 ? 255 : r)
    let gg = g < 0 ? 0 : (g > 255 ? 255 : g)
    let bb = b < 0 ? 0 : (b > 255 ? 255 : b)
    return 0xff00_0000 | UInt32(rr) << 16 | UInt32(gg) << 8 | UInt32(bb)
}
