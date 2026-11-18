// TrueType reader (ROADMAP Phase 8E). Parses sfnt files with glyf outlines:
// table directory, head, hhea, maxp, hmtx, cmap (formats 4 and 12), loca,
// glyf (simple and composite), kern (format 0), OS/2 and name (optional).
//
// Hostile-input safe: every offset goes through a bounds check, recursion and
// point counts are bounded, and nothing here traps on malformed data.

struct TTPoint {
    var x: Float
    var y: Float
    var on: Bool
}

/// A glyph outline in font units, y up. `ends[i]` is the index of the last
/// point of contour i.
struct TTOutline {
    var points: [TTPoint] = []
    var ends: [Int] = []
}

struct TTTable {
    var offset = 0
    var length = 0
    var present: Bool { length > 0 }
}

func ttTag(_ s: StaticString) -> UInt32 {
    var v: UInt32 = 0
    let p = s.utf8Start
    for i in 0..<4 { v = v << 8 | UInt32(p[i]) }
    return v
}

final class TTFont {
    let data: [UInt8]
    private(set) var tableCount = 0
    private(set) var unitsPerEm = 0
    private(set) var numGlyphs = 0
    private(set) var indexToLocFormat = 0
    private(set) var macStyle = 0
    private(set) var hheaAscent = 0      // font units
    private(set) var hheaDescent = 0     // negative
    private(set) var lineGap = 0
    private(set) var numHMetrics = 0
    private(set) var os2Version = -1
    private(set) var typoAscent = 0
    private(set) var typoDescent = 0
    private(set) var winAscent = 0
    private(set) var winDescent = 0
    private(set) var weightClass = 0
    private(set) var fsSelection = 0
    private(set) var xHeightUnits = 0
    private(set) var capHeightUnits = 0

    private var head = TTTable(), hhea = TTTable(), maxp = TTTable(), hmtx = TTTable()
    private var cmap = TTTable(), loca = TTTable(), glyf = TTTable()
    private var kernT = TTTable(), os2 = TTTable(), nameT = TTTable()
    private var cmapOffset = 0     // absolute offset of the chosen subtable
    private var cmapFormat = 0     // 4 or 12, 0 if none
    private var kernPairs = 0      // absolute offset of format-0 pair array
    private var kernCount = 0

    static let maxComponentDepth = 6
    static let maxComponents = 64
    static let maxPoints = 20000

    /// nil unless `data` is a TrueType-outline sfnt with the required tables.
    init?(_ data: [UInt8]) {
        self.data = data
        var r = ByteReader(data)
        guard let ver = r.u32(), let n = r.u16(), r.skip(6) else { return nil }
        // 0x00010000 or 'true'. 'OTTO' (CFF) and collections are unsupported.
        guard ver == 0x0001_0000 || ver == 0x7472_7565, n >= 1, n <= 256 else { return nil }
        var tables: [UInt32: TTTable] = [:]
        for _ in 0..<Int(n) {
            guard let tag = r.u32(), r.skip(4), let off = r.u32(), let len = r.u32() else { return nil }
            let o = Int(off), l = Int(len)
            if o > data.count || l > data.count - o { continue }
            if tables[tag] == nil { tables[tag] = TTTable(offset: o, length: l) }
        }
        tableCount = tables.count
        guard let h = tables[ttTag("head")], let hh = tables[ttTag("hhea")],
              let mp = tables[ttTag("maxp")], let hm = tables[ttTag("hmtx")],
              let cm = tables[ttTag("cmap")], let lo = tables[ttTag("loca")],
              let gl = tables[ttTag("glyf")] else { return nil }
        head = h; hhea = hh; maxp = mp; hmtx = hm; cmap = cm; loca = lo; glyf = gl
        if let t = tables[ttTag("kern")] { kernT = t }
        if let t = tables[ttTag("OS/2")] { os2 = t }
        if let t = tables[ttTag("name")] { nameT = t }

        guard head.length >= 54, hhea.length >= 36, maxp.length >= 6 else { return nil }
        guard let upm = u16(head.offset + 18), upm >= 16, upm <= 16384 else { return nil }
        unitsPerEm = upm
        macStyle = u16(head.offset + 44) ?? 0
        indexToLocFormat = i16(head.offset + 50) ?? 0
        guard indexToLocFormat == 0 || indexToLocFormat == 1 else { return nil }
        guard let ng = u16(maxp.offset + 4), ng >= 1 else { return nil }
        numGlyphs = ng
        hheaAscent = i16(hhea.offset + 4) ?? 0
        hheaDescent = i16(hhea.offset + 6) ?? 0
        lineGap = i16(hhea.offset + 8) ?? 0
        numHMetrics = u16(hhea.offset + 34) ?? 0
        guard numHMetrics >= 1, numHMetrics * 4 <= hmtx.length else { return nil }
        let entry = indexToLocFormat == 0 ? 2 : 4
        guard (numGlyphs + 1) * entry <= loca.length else { return nil }

        if os2.length >= 78 {
            os2Version = u16(os2.offset) ?? -1
            weightClass = u16(os2.offset + 4) ?? 0
            fsSelection = u16(os2.offset + 62) ?? 0
            typoAscent = i16(os2.offset + 68) ?? 0
            typoDescent = i16(os2.offset + 70) ?? 0
            winAscent = u16(os2.offset + 74) ?? 0
            winDescent = u16(os2.offset + 76) ?? 0
            if os2Version >= 2, os2.length >= 90 {
                xHeightUnits = i16(os2.offset + 86) ?? 0
                capHeightUnits = i16(os2.offset + 88) ?? 0
            }
        }
        selectCmap()
        parseKern()
    }

    // MARK: raw access

    @inline(__always) private func u16(_ o: Int) -> Int? {
        guard o >= 0, o <= data.count - 2 else { return nil }
        return Int(data[o]) << 8 | Int(data[o + 1])
    }
    @inline(__always) private func i16(_ o: Int) -> Int? {
        guard let v = u16(o) else { return nil }
        return Int(Int16(truncatingIfNeeded: v))
    }
    @inline(__always) private func u32(_ o: Int) -> Int? {
        guard o >= 0, o <= data.count - 4 else { return nil }
        return Int(data[o]) << 24 | Int(data[o + 1]) << 16 | Int(data[o + 2]) << 8 | Int(data[o + 3])
    }

    // MARK: metrics

    /// Ascent and descent (positive) in font units, from hhea.
    var ascent: Int { hheaAscent }
    var descent: Int { -hheaDescent }
    var isBold: Bool { macStyle & 1 != 0 || fsSelection & 0x20 != 0 || weightClass >= 600 }
    var isItalic: Bool { macStyle & 2 != 0 || fsSelection & 0x201 != 0 }

    /// x-height in font units: OS/2 if present, else the height of 'x'.
    var xHeight: Int {
        if xHeightUnits > 0 { return xHeightUnits }
        if let m = maxY(glyphIndex(0x78)), m > 0 { return m }
        return unitsPerEm / 2
    }
    var capHeight: Int {
        if capHeightUnits > 0 { return capHeightUnits }
        if let m = maxY(glyphIndex(0x48)), m > 0 { return m }
        return unitsPerEm * 7 / 10
    }

    private func maxY(_ g: Int) -> Int? {
        guard let o = outline(g), !o.points.isEmpty else { return nil }
        var m: Float = -1e9
        for p in o.points where p.y > m { m = p.y }
        return Int(m)
    }

    /// Horizontal advance in font units (0 for an out-of-range glyph).
    func advance(of glyph: Int) -> Int {
        guard glyph >= 0, glyph < numGlyphs else { return 0 }
        let i = glyph < numHMetrics ? glyph : numHMetrics - 1
        return u16(hmtx.offset + i * 4) ?? 0
    }

    /// Left side bearing in font units.
    func leftSideBearing(of glyph: Int) -> Int {
        guard glyph >= 0, glyph < numGlyphs else { return 0 }
        if glyph < numHMetrics { return i16(hmtx.offset + glyph * 4 + 2) ?? 0 }
        let o = hmtx.offset + numHMetrics * 4 + (glyph - numHMetrics) * 2
        guard o + 2 <= hmtx.offset + hmtx.length else { return 0 }
        return i16(o) ?? 0
    }

    // MARK: cmap

    private func selectCmap() {
        guard cmap.length >= 4, let n = u16(cmap.offset + 2) else { return }
        var best = 0
        for i in 0..<min(n, 64) {
            let rec = cmap.offset + 4 + i * 8
            guard let plat = u16(rec), let enc = u16(rec + 2), let off = u32(rec + 4),
                  off < cmap.length else { continue }
            let sub = cmap.offset + off
            guard let fmt = u16(sub), fmt == 4 || fmt == 12 else { continue }
            var score = 0
            switch (plat, enc) {
            case (3, 10): score = 100
            case (0, 4), (0, 6): score = 95
            case (3, 1): score = 60
            case (0, _): score = 50
            default: score = 0
            }
            if score == 0 { continue }
            if fmt == 12 { score += 5 }
            if score > best { best = score; cmapOffset = sub; cmapFormat = fmt }
        }
    }

    /// Glyph for a Unicode scalar, 0 (.notdef) if unmapped.
    func glyphIndex(_ c: UInt32) -> Int {
        let g: Int
        switch cmapFormat {
        case 4: g = lookup4(c)
        case 12: g = lookup12(c)
        default: g = 0
        }
        return g < numGlyphs ? g : 0
    }

    private func lookup12(_ c: UInt32) -> Int {
        guard let n = u32(cmapOffset + 12), n > 0, n <= 1 << 20 else { return 0 }
        var lo = 0, hi = n - 1
        let base = cmapOffset + 16
        let ch = Int(c)
        while lo <= hi {
            let mid = (lo + hi) >> 1
            guard let s = u32(base + mid * 12), let e = u32(base + mid * 12 + 4),
                  let g = u32(base + mid * 12 + 8) else { return 0 }
            if ch < s { hi = mid - 1 } else if ch > e { lo = mid + 1 } else { return g + (ch - s) }
        }
        return 0
    }

    private func lookup4(_ c: UInt32) -> Int {
        guard c <= 0xFFFF, let sx2 = u16(cmapOffset + 6) else { return 0 }
        let segs = sx2 / 2
        guard segs > 0 else { return 0 }
        let endBase = cmapOffset + 14
        let startBase = endBase + sx2 + 2
        let deltaBase = startBase + sx2
        let rangeBase = deltaBase + sx2
        let ch = Int(c)
        var lo = 0, hi = segs - 1
        while lo < hi {
            let mid = (lo + hi) >> 1
            guard let e = u16(endBase + mid * 2) else { return 0 }
            if e < ch { lo = mid + 1 } else { hi = mid }
        }
        guard let e = u16(endBase + lo * 2), let s = u16(startBase + lo * 2),
              ch <= e, ch >= s, let delta = u16(deltaBase + lo * 2),
              let ro = u16(rangeBase + lo * 2) else { return 0 }
        if ro == 0 { return (ch + delta) & 0xFFFF }
        guard let g = u16(rangeBase + lo * 2 + ro + (ch - s) * 2), g != 0 else { return 0 }
        return (g + delta) & 0xFFFF
    }

    // MARK: kern

    private func parseKern() {
        guard kernT.length >= 4, u16(kernT.offset) == 0, let n = u16(kernT.offset + 2) else { return }
        var off = kernT.offset + 4
        let end = kernT.offset + kernT.length
        for _ in 0..<min(n, 16) {
            guard off + 14 <= end, let len = u16(off + 2), let cov = u16(off + 4), len >= 14 else { return }
            if cov >> 8 == 0 && cov & 1 == 1 {
                guard let np = u16(off + 6) else { return }
                let avail = (min(off + len, end) - (off + 14)) / 6
                kernPairs = off + 14
                kernCount = min(np, avail)
                return
            }
            off += len
        }
    }

    var hasKerning: Bool { kernCount > 0 }

    /// Kerning adjustment in font units between two glyphs (usually negative).
    func kern(_ left: Int, _ right: Int) -> Int {
        guard kernCount > 0 else { return 0 }
        let key = left << 16 | right
        var lo = 0, hi = kernCount - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            let p = kernPairs + mid * 6
            guard let l = u16(p), let r = u16(p + 2) else { return 0 }
            let k = l << 16 | r
            if key < k { hi = mid - 1 } else if key > k { lo = mid + 1 } else { return i16(p + 4) ?? 0 }
        }
        return 0
    }

    // MARK: name

    /// A name-table string (1 family, 2 subfamily, 4 full name, 16 typographic
    /// family) decoded to ASCII ('?' for anything else), or nil.
    func nameString(_ id: Int) -> String? {
        guard nameT.length >= 6, let count = u16(nameT.offset + 2), let so = u16(nameT.offset + 4) else { return nil }
        for i in 0..<min(count, 512) {
            let rec = nameT.offset + 6 + i * 12
            guard let plat = u16(rec), let nid = u16(rec + 6), nid == id,
                  let len = u16(rec + 8), let off = u16(rec + 10) else { continue }
            let start = nameT.offset + so + off
            guard start >= 0, start + len <= nameT.offset + nameT.length else { continue }
            var s = ""
            if plat == 3 || plat == 0 {
                var j = 0
                while j + 1 < len {
                    let c = Int(data[start + j]) << 8 | Int(data[start + j + 1])
                    s.append(c >= 0x20 && c < 0x7f ? Character(Unicode.Scalar(UInt8(c))) : "?")
                    j += 2
                }
            } else {
                for j in 0..<len {
                    let c = data[start + j]
                    s.append(c >= 0x20 && c < 0x7f ? Character(Unicode.Scalar(c)) : "?")
                }
            }
            return s
        }
        return nil
    }

    var familyName: String? { nameString(16) ?? nameString(1) }

    // MARK: glyf

    private func glyphRange(_ g: Int) -> (Int, Int)? {
        guard g >= 0, g < numGlyphs else { return nil }
        let a: Int, b: Int
        if indexToLocFormat == 0 {
            guard let x = u16(loca.offset + g * 2), let y = u16(loca.offset + g * 2 + 2) else { return nil }
            a = x * 2; b = y * 2
        } else {
            guard let x = u32(loca.offset + g * 4), let y = u32(loca.offset + g * 4 + 4) else { return nil }
            a = x; b = y
        }
        if b <= a { return (0, 0) }
        guard b <= glyf.length else { return nil }
        return (glyf.offset + a, b - a)
    }

    /// The glyph's outline in font units; empty for blank glyphs (space),
    /// nil if the glyph data is invalid.
    func outline(_ glyph: Int) -> TTOutline? {
        var budget = TTFont.maxComponents
        return load(glyph, depth: 0, budget: &budget)
    }

    private func load(_ g: Int, depth: Int, budget: inout Int) -> TTOutline? {
        guard let (start, len) = glyphRange(g) else { return nil }
        if len == 0 { return TTOutline() }
        guard len >= 10 else { return nil }
        var r = ByteReader(data, from: start, count: len)
        guard let nc16 = r.u16(), r.skip(8) else { return nil }
        let nc = Int(Int16(truncatingIfNeeded: nc16))
        if nc >= 0 { return loadSimple(&r, nc) }
        guard depth < TTFont.maxComponentDepth else { return nil }
        return loadComposite(&r, depth: depth, budget: &budget)
    }

    private func loadSimple(_ r: inout ByteReader, _ nc: Int) -> TTOutline? {
        var out = TTOutline()
        if nc == 0 { return out }
        out.ends.reserveCapacity(nc)
        var prev = -1
        for _ in 0..<nc {
            guard let e = r.u16() else { return nil }
            if Int(e) <= prev { return nil }
            prev = Int(e)
            out.ends.append(prev)
        }
        let np = prev + 1
        guard np <= TTFont.maxPoints, let il = r.u16(), r.skip(Int(il)) else { return nil }
        var flags = [UInt8](repeating: 0, count: np)
        var i = 0
        while i < np {
            guard let f = r.u8() else { return nil }
            flags[i] = f; i += 1
            if f & 8 != 0 {
                guard let rep = r.u8() else { return nil }
                var k = Int(rep)
                while k > 0 && i < np { flags[i] = f; i += 1; k -= 1 }
            }
        }
        out.points.reserveCapacity(np)
        var xs = [Int](repeating: 0, count: np)
        var v = 0
        for i in 0..<np {
            let f = flags[i]
            if f & 2 != 0 {
                guard let d = r.u8() else { return nil }
                v += f & 0x10 != 0 ? Int(d) : -Int(d)
            } else if f & 0x10 == 0 {
                guard let d = r.u16() else { return nil }
                v += Int(Int16(truncatingIfNeeded: d))
            }
            xs[i] = v
        }
        v = 0
        for i in 0..<np {
            let f = flags[i]
            if f & 4 != 0 {
                guard let d = r.u8() else { return nil }
                v += f & 0x20 != 0 ? Int(d) : -Int(d)
            } else if f & 0x20 == 0 {
                guard let d = r.u16() else { return nil }
                v += Int(Int16(truncatingIfNeeded: d))
            }
            out.points.append(TTPoint(x: Float(xs[i]), y: Float(v), on: flags[i] & 1 != 0))
        }
        return out
    }

    private static func f2dot14(_ r: inout ByteReader) -> Float? {
        guard let v = r.u16() else { return nil }
        return Float(Int16(truncatingIfNeeded: v)) / 16384
    }

    private func loadComposite(_ r: inout ByteReader, depth: Int, budget: inout Int) -> TTOutline? {
        var out = TTOutline()
        while true {
            guard budget > 0 else { return nil }
            budget -= 1
            guard let flags = r.u16(), let gi = r.u16() else { return nil }
            var a1 = 0, a2 = 0
            if flags & 1 != 0 {
                guard let x = r.u16(), let y = r.u16() else { return nil }
                if flags & 2 != 0 {
                    a1 = Int(Int16(truncatingIfNeeded: x)); a2 = Int(Int16(truncatingIfNeeded: y))
                } else { a1 = Int(x); a2 = Int(y) }
            } else {
                guard let x = r.u8(), let y = r.u8() else { return nil }
                if flags & 2 != 0 {
                    a1 = Int(Int8(truncatingIfNeeded: x)); a2 = Int(Int8(truncatingIfNeeded: y))
                } else { a1 = Int(x); a2 = Int(y) }
            }
            var m00: Float = 1, m01: Float = 0, m10: Float = 0, m11: Float = 1
            if flags & 8 != 0 {
                guard let s = TTFont.f2dot14(&r) else { return nil }
                m00 = s; m11 = s
            } else if flags & 0x40 != 0 {
                guard let sx = TTFont.f2dot14(&r), let sy = TTFont.f2dot14(&r) else { return nil }
                m00 = sx; m11 = sy
            } else if flags & 0x80 != 0 {
                guard let a = TTFont.f2dot14(&r), let b = TTFont.f2dot14(&r),
                      let c = TTFont.f2dot14(&r), let d = TTFont.f2dot14(&r) else { return nil }
                m00 = a; m01 = b; m10 = c; m11 = d
            }
            guard var child = load(Int(gi), depth: depth + 1, budget: &budget) else { return nil }
            // x' = m00 x + m10 y ; y' = m01 x + m11 y
            for i in 0..<child.points.count {
                let p = child.points[i]
                child.points[i].x = m00 * p.x + m10 * p.y
                child.points[i].y = m01 * p.x + m11 * p.y
            }
            var dx: Float = 0, dy: Float = 0
            if flags & 2 != 0 {
                dx = Float(a1); dy = Float(a2)
            } else {
                // point matching: parent point a1 aligns with child point a2
                guard a1 < out.points.count, a2 < child.points.count else { return nil }
                dx = out.points[a1].x - child.points[a2].x
                dy = out.points[a1].y - child.points[a2].y
            }
            let base = out.points.count
            guard base + child.points.count <= TTFont.maxPoints else { return nil }
            for p in child.points { out.points.append(TTPoint(x: p.x + dx, y: p.y + dy, on: p.on)) }
            for e in child.ends { out.ends.append(e + base) }
            if flags & 0x20 == 0 { break }
        }
        return out
    }
}
