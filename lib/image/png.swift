// PNG decoder: every color type and bit depth, palettes, tRNS, the five
// filters and Adam7 interlacing. Gamma, background, ICC and other ancillary
// chunks are ignored; 16-bit samples are reduced to their high byte.
// CRC errors in critical chunks (IHDR, PLTE, IDAT, IEND) fail the decode;
// a bad CRC in an ancillary chunk just drops that chunk.

private let pngIHDR: UInt32 = 0x4948_4452
private let pngPLTE: UInt32 = 0x504c_5445
private let pngIDAT: UInt32 = 0x4944_4154
private let pngIEND: UInt32 = 0x4945_4e44
private let pngTRNS: UInt32 = 0x7452_4e53

private let pngXStart = [0, 4, 0, 2, 0, 1, 0]
private let pngYStart = [0, 0, 4, 0, 2, 0, 1]
private let pngXStep = [8, 8, 4, 4, 2, 2, 1]
private let pngYStep = [8, 8, 8, 4, 4, 2, 2]

struct PNGDecoder {
    static func decode(_ data: [UInt8], maxBytes: Int) throws(ImageError) -> ImageBitmap {
        guard imageSniff(data) == .png else { throw ImageError.unknownFormat }
        var r = ByteReader(data, from: 8)
        let crcTool = InflateCRC32()

        var width = 0, height = 0, depth = 0, ctype = 0, interlace = 0
        var haveHeader = false
        var palette: [UInt32] = []
        var havePalette = false
        var trns: [UInt8] = []
        var haveTrns = false
        var z = Inflater(format: .zlib, maxOutput: 0)
        var raw: [UInt8] = []
        var rawSize = 0
        var sawIDAT = false, idatDone = false, streamDone = false
        var channels = 1

        chunks: while true {
            guard let len32 = r.u32(), let type = r.u32() else {
                if sawIDAT { break chunks }
                throw ImageError.truncated
            }
            let len = Int(len32)
            let start = r.offset
            if len32 > 0x7fff_ffff || len + 4 > r.remaining {
                if sawIDAT && haveHeader { break chunks }   // truncated tail: use what we have
                throw ImageError.truncated
            }
            _ = r.skip(len + 4)
            let critical = (type >> 24) & 0x20 == 0
            let stored = UInt32(data[start + len]) << 24 | UInt32(data[start + len + 1]) << 16
                | UInt32(data[start + len + 2]) << 8 | UInt32(data[start + len + 3])
            let crcOK = crcTool.update(0, data, start - 4, start + len) == stored
            if !crcOK {
                if critical { throw ImageError.badChecksum }
                continue
            }
            if !haveHeader && type != pngIHDR { throw ImageError.malformed }
            switch type {
            case pngIHDR:
                if haveHeader || len != 13 { throw ImageError.malformed }
                var h = ByteReader(data, from: start, count: 13)
                let w = Int(h.u32() ?? 0), ht = Int(h.u32() ?? 0)
                depth = Int(h.u8() ?? 0); ctype = Int(h.u8() ?? 0)
                let comp = h.u8() ?? 1, filt = h.u8() ?? 1
                interlace = Int(h.u8() ?? 2)
                if w == 0 || ht == 0 || w > 0x7fff_ffff || ht > 0x7fff_ffff { throw ImageError.malformed }
                switch ctype {
                case 0: if ![1, 2, 4, 8, 16].contains(depth) { throw ImageError.malformed }
                case 2, 4, 6: if depth != 8 && depth != 16 { throw ImageError.malformed }
                case 3: if ![1, 2, 4, 8].contains(depth) { throw ImageError.malformed }
                default: throw ImageError.malformed
                }
                if comp != 0 || filt != 0 || interlace > 1 { throw ImageError.malformed }
                if !imageSizeOK(w, ht, maxBytes) { throw ImageError.tooLarge }
                width = w; height = ht
                channels = ctype == 2 ? 3 : (ctype == 4 ? 2 : (ctype == 6 ? 4 : 1))
                haveHeader = true
                // Raw size: filter byte + packed row for every pass row.
                if interlace == 0 {
                    rawSize = (1 + (width * channels * depth + 7) / 8) * height
                } else {
                    for p in 0..<7 {
                        let pw = (width - pngXStart[p] + pngXStep[p] - 1) / pngXStep[p]
                        let ph = (height - pngYStart[p] + pngYStep[p] - 1) / pngYStep[p]
                        if pw > 0 && ph > 0 { rawSize += (1 + (pw * channels * depth + 7) / 8) * ph }
                    }
                }
                z = Inflater(format: .zlib, maxOutput: rawSize)
                raw.reserveCapacity(rawSize)
            case pngPLTE:
                if sawIDAT || havePalette { throw ImageError.malformed }
                if ctype == 0 || ctype == 4 { continue }          // not allowed; ignored
                if len % 3 != 0 || len == 0 || len / 3 > 256 { throw ImageError.malformed }
                if ctype == 3 && len / 3 > (1 << depth) { throw ImageError.malformed }
                palette = [UInt32](repeating: 0, count: len / 3)
                for i in 0..<(len / 3) {
                    palette[i] = 0xff00_0000 | UInt32(data[start + 3 * i]) << 16
                        | UInt32(data[start + 3 * i + 1]) << 8 | UInt32(data[start + 3 * i + 2])
                }
                havePalette = true
            case pngTRNS:
                if sawIDAT { continue }
                trns = Array(data[start..<(start + len)])
                haveTrns = true
            case pngIDAT:
                if idatDone { throw ImageError.malformed }       // IDATs must be consecutive
                sawIDAT = true
                if ctype == 3 && !havePalette { throw ImageError.malformed }
                if !streamDone {
                    do throws(InflateError) { try z.feed(Array(data[start..<(start + len)])) }
                    catch {
                        if error != .outputLimit { throw ImageError.malformed }
                        streamDone = true
                    }
                    raw.append(contentsOf: z.take())
                    if z.isDone { streamDone = true }
                }
            case pngIEND:
                break chunks
            default:
                if critical { throw ImageError.unsupported }
            }
            if sawIDAT && type != pngIDAT && type != pngIHDR { idatDone = true }
        }
        if !haveHeader { throw ImageError.malformed }
        if !sawIDAT { throw ImageError.malformed }
        if raw.count < rawSize { throw ImageError.truncated }
        if ctype == 3 && !havePalette { throw ImageError.malformed }

        // tRNS
        var trnsGray = -1
        var trnsR = -1, trnsG = -1, trnsB = -1
        if haveTrns {
            switch ctype {
            case 0:
                if trns.count >= 2 { trnsGray = Int(trns[0]) << 8 | Int(trns[1]) }
            case 2:
                if trns.count >= 6 {
                    trnsR = Int(trns[0]) << 8 | Int(trns[1])
                    trnsG = Int(trns[2]) << 8 | Int(trns[3])
                    trnsB = Int(trns[4]) << 8 | Int(trns[5])
                }
            case 3:
                for i in 0..<min(trns.count, palette.count) {
                    palette[i] = UInt32(trns[i]) << 24 | (palette[i] & 0x00ff_ffff)
                }
            default: break
            }
        }
        if depth == 8 {         // 16-bit key colours compare against 8-bit samples by their low byte
            if trnsGray >= 0 { trnsGray &= 255 }
            if trnsR >= 0 { trnsR &= 255; trnsG &= 255; trnsB &= 255 }
        } else if depth < 8 && trnsGray >= 0 {
            trnsGray &= (1 << depth) - 1
        }

        var pixels = [UInt32](repeating: 0, count: width * height)
        var bad = false
        let bitsPP = channels * depth
        let bpp = max(1, bitsPP / 8)
        let passes = interlace == 0 ? 1 : 7
        let ctypeL = ctype, depthL = depth, widthL = width
        let paletteL = palette
        let tg = trnsGray, tr = trnsR, tgg = trnsG, tb = trnsB
        raw.withUnsafeMutableBufferPointer { rp in
            pixels.withUnsafeMutableBufferPointer { px in
                var off = 0
                for p in 0..<passes {
                    let xs = interlace == 0 ? 0 : pngXStart[p], ys = interlace == 0 ? 0 : pngYStart[p]
                    let dx = interlace == 0 ? 1 : pngXStep[p], dy = interlace == 0 ? 1 : pngYStep[p]
                    let pw = (widthL - xs + dx - 1) / dx
                    let ph = (height - ys + dy - 1) / dy
                    if pw <= 0 || ph <= 0 { continue }
                    let rowBytes = (pw * bitsPP + 7) / 8
                    var prev = -1
                    for row in 0..<ph {
                        let cur = off + 1
                        let ft = rp[off]
                        if !pngUnfilter(rp, ft, cur, prev, rowBytes, bpp) { bad = true; return }
                        let dstRow = (ys + row * dy) * widthL + xs
                        pngConvertRow(rp, cur, px, dstRow, dx, pw, ctypeL, depthL, paletteL, tg, tr, tgg, tb)
                        prev = cur
                        off += 1 + rowBytes
                    }
                }
            }
        }
        if bad { throw ImageError.malformed }
        var andA: UInt32 = 0xff
        for p in pixels { andA &= p >> 24 }
        return ImageBitmap(width: width, height: height, pixels: pixels, opaque: andA == 0xff)
    }
}

/// Undo the filter of one row in place. `cur` and `prev` are offsets of the
/// row data (after the filter byte); prev < 0 means an all-zero row above.
private func pngUnfilter(_ b: UnsafeMutableBufferPointer<UInt8>, _ ft: UInt8, _ cur: Int, _ prev: Int,
                         _ n: Int, _ bpp: Int) -> Bool {
    switch ft {
    case 0:
        return true
    case 1:
        if n > bpp { for i in bpp..<n { b[cur + i] = b[cur + i] &+ b[cur + i - bpp] } }
    case 2:
        if prev >= 0 { for i in 0..<n { b[cur + i] = b[cur + i] &+ b[prev + i] } }
    case 3:
        for i in 0..<n {
            let left = i >= bpp ? Int(b[cur + i - bpp]) : 0
            let up = prev >= 0 ? Int(b[prev + i]) : 0
            b[cur + i] = b[cur + i] &+ UInt8(truncatingIfNeeded: (left + up) >> 1)
        }
    case 4:
        for i in 0..<n {
            let a = i >= bpp ? Int(b[cur + i - bpp]) : 0
            let up = prev >= 0 ? Int(b[prev + i]) : 0
            let c = (i >= bpp && prev >= 0) ? Int(b[prev + i - bpp]) : 0
            let p = a + up - c
            let pa = abs(p - a), pb = abs(p - up), pc = abs(p - c)
            let pred = (pa <= pb && pa <= pc) ? a : (pb <= pc ? up : c)
            b[cur + i] = b[cur + i] &+ UInt8(truncatingIfNeeded: pred)
        }
    default:
        return false
    }
    return true
}

/// Convert one unfiltered row to ARGB, writing pixel i to px[dst + i * step].
private func pngConvertRow(_ b: UnsafeMutableBufferPointer<UInt8>, _ cur: Int,
                           _ px: UnsafeMutableBufferPointer<UInt32>, _ dst: Int, _ step: Int, _ n: Int,
                           _ ct: Int, _ depth: Int, _ pal: [UInt32],
                           _ tGray: Int, _ tR: Int, _ tG: Int, _ tB: Int) {
    switch (ct, depth) {
    case (6, 8):
        for i in 0..<n {
            let o = cur + 4 * i
            px[dst + i * step] = UInt32(b[o + 3]) << 24 | UInt32(b[o]) << 16 | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2])
        }
    case (2, 8):
        for i in 0..<n {
            let o = cur + 3 * i
            let r = Int(b[o]), g = Int(b[o + 1]), bl = Int(b[o + 2])
            let a: UInt32 = (r == tR && g == tG && bl == tB) ? 0 : 0xff00_0000
            px[dst + i * step] = a | UInt32(r) << 16 | UInt32(g) << 8 | UInt32(bl)
        }
    case (0, 8):
        for i in 0..<n {
            let g = Int(b[cur + i])
            let a: UInt32 = g == tGray ? 0 : 0xff00_0000
            px[dst + i * step] = a | UInt32(g) << 16 | UInt32(g) << 8 | UInt32(g)
        }
    case (4, 8):
        for i in 0..<n {
            let g = UInt32(b[cur + 2 * i])
            px[dst + i * step] = UInt32(b[cur + 2 * i + 1]) << 24 | g << 16 | g << 8 | g
        }
    case (3, 8):
        for i in 0..<n {
            let v = Int(b[cur + i])
            px[dst + i * step] = v < pal.count ? pal[v] : 0xff00_0000
        }
    case (6, 16):
        for i in 0..<n {
            let o = cur + 8 * i
            px[dst + i * step] = UInt32(b[o + 6]) << 24 | UInt32(b[o]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 4])
        }
    case (2, 16):
        for i in 0..<n {
            let o = cur + 6 * i
            let r = Int(b[o]) << 8 | Int(b[o + 1]), g = Int(b[o + 2]) << 8 | Int(b[o + 3])
            let bl = Int(b[o + 4]) << 8 | Int(b[o + 5])
            let a: UInt32 = (r == tR && g == tG && bl == tB) ? 0 : 0xff00_0000
            px[dst + i * step] = a | UInt32(b[o]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 4])
        }
    case (0, 16):
        for i in 0..<n {
            let o = cur + 2 * i
            let g = Int(b[o]) << 8 | Int(b[o + 1])
            let h = UInt32(b[o])
            let a: UInt32 = g == tGray ? 0 : 0xff00_0000
            px[dst + i * step] = a | h << 16 | h << 8 | h
        }
    case (4, 16):
        for i in 0..<n {
            let o = cur + 4 * i
            let g = UInt32(b[o])
            px[dst + i * step] = UInt32(b[o + 2]) << 24 | g << 16 | g << 8 | g
        }
    default:
        // 1, 2 and 4 bit gray or palette.
        let mask = (1 << depth) - 1
        for i in 0..<n {
            let bit = i * depth
            let v = (Int(b[cur + (bit >> 3)]) >> (8 - depth - (bit & 7))) & mask
            if ct == 3 {
                px[dst + i * step] = v < pal.count ? pal[v] : 0xff00_0000
            } else {
                let g = UInt32(v * 255 / mask)
                let a: UInt32 = v == tGray ? 0 : 0xff00_0000
                px[dst + i * step] = a | g << 16 | g << 8 | g
            }
        }
    }
}
