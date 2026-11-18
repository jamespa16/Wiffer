// Text runs (ROADMAP Phase 8E): UTF-8 to Unicode scalars to glyphs, advances
// plus kerning, font fallback with a tofu box, measuring, a simplified UAX #14
// line breaker and a width-fitting API for layout.
//
// There is one glyph per scalar (no ligatures, no complex-script shaping), so
// a scalar index is also a glyph index and every API below speaks scalar
// indices. Positions are unrounded floats in pixels.

/// Decode UTF-8, replacing malformed sequences with U+FFFD.
func textDecodeUTF8(_ b: [UInt8]) -> [UInt32] {
    var out: [UInt32] = []
    out.reserveCapacity(b.count)
    var i = 0
    let n = b.count
    while i < n {
        let c = b[i]
        if c < 0x80 { out.append(UInt32(c)); i += 1; continue }
        var need = 0
        var v: UInt32 = 0
        var lo: UInt32 = 0
        if c >= 0xC2 && c <= 0xDF { need = 1; v = UInt32(c & 0x1F); lo = 0x80 }
        else if c >= 0xE0 && c <= 0xEF { need = 2; v = UInt32(c & 0x0F); lo = 0x800 }
        else if c >= 0xF0 && c <= 0xF4 { need = 3; v = UInt32(c & 0x07); lo = 0x10000 }
        else { out.append(0xFFFD); i += 1; continue }
        var j = 1
        while j <= need && i + j < n && b[i + j] & 0xC0 == 0x80 {
            v = v << 6 | UInt32(b[i + j] & 0x3F); j += 1
        }
        if j <= need || v < lo || v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF) {
            out.append(0xFFFD); i += max(j, 1)
        } else {
            out.append(v); i += need + 1
        }
    }
    return out
}

func textScalars(_ s: String) -> [UInt32] { textDecodeUTF8(Array(s.utf8)) }

// MARK: line breaking (simplified UAX #14)

enum TextBreakClass: UInt8 {
    case other, space, hyphen, softHyphen, open, close, cjkClose, ideograph, glue, zwsp, newline, cr, digit
}

func textBreakClass(_ c: UInt32) -> TextBreakClass {
    switch c {
    case 0x20, 0x09, 0x3000: return .space
    case 0x0A, 0x0B, 0x0C, 0x85, 0x2028, 0x2029: return .newline
    case 0x0D: return .cr
    case 0x200B: return .zwsp
    case 0xA0, 0x202F, 0x2060, 0xFEFF, 0x2007, 0x2011: return .glue
    case 0xAD: return .softHyphen
    case 0x2D, 0x2010, 0x2012, 0x2013: return .hyphen
    case 0x30...0x39: return .digit
    case 0x28, 0x5B, 0x7B, 0xAB, 0x2018, 0x201C, 0x3008, 0x300A, 0x300C, 0x300E, 0x3010, 0x3014,
         0xFF08, 0xFF3B, 0xFF5B:
        return .open
    case 0x29, 0x5D, 0x7D, 0x21, 0x3F, 0x2C, 0x2E, 0x3A, 0x3B, 0x25, 0xBB, 0x2019, 0x201D, 0x2026:
        return .close
    case 0x3001, 0x3002, 0x3009, 0x300B, 0x300D, 0x300F, 0x3011, 0x3015, 0xFF09, 0xFF3D, 0xFF5D,
         0xFF0C, 0xFF0E, 0xFF01, 0xFF1F, 0xFF1A, 0xFF1B, 0x30FB, 0x30FC:
        return .cjkClose
    case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3FFFF,
         0xFF21...0xFF3A, 0xFF41...0xFF5A, 0xFF10...0xFF19, 0xFF66...0xFF9F:
        return .ideograph
    default: return .other
    }
}

/// Break opportunities: result[i] describes the boundary before scalar i
/// (0 none, 1 allowed, 2 mandatory); result[count] is 1 (end of text, or 2
/// after a trailing newline). result[0] is always 0.
func textBreakOpportunities(_ s: [UInt32]) -> [UInt8] {
    let n = s.count
    var out = [UInt8](repeating: 0, count: n + 1)
    if n == 0 { return out }
    var cls = [TextBreakClass](repeating: .other, count: n)
    for i in 0..<n { cls[i] = textBreakClass(s[i]) }
    var i = 1
    while i < n {
        out[i] = breakBetween(s, cls, i, cls[i - 1], cls[i])
        i += 1
    }
    let last = cls[n - 1]
    out[n] = last == .newline || last == .cr ? 2 : 1
    return out
}

private func breakBetween(_ s: [UInt32], _ cls: [TextBreakClass], _ i: Int, _ p: TextBreakClass, _ c: TextBreakClass) -> UInt8 {
    if p == .cr { return c == .newline && s[i] == 0x0A ? 0 : 2 }
    if p == .newline { return 2 }
    if c == .newline || c == .cr || c == .space || c == .zwsp { return 0 }
    if p == .zwsp { return 1 }
    if c == .glue || p == .glue { return 0 }
    if c == .close || c == .cjkClose { return 0 }
    if p == .open { return 0 }
    if p == .space { return 1 }
    if p == .softHyphen { return 1 }
    if p == .hyphen {
        if c == .digit || c == .hyphen { return 0 }
        if i >= 2 {
            let pp = cls[i - 2]
            if pp == .space || pp == .hyphen || pp == .open || pp == .newline || pp == .cr { return 0 }
            return 1
        }
        return 0
    }
    if p == .ideograph || c == .ideograph { return 1 }
    if p == .cjkClose { return 1 }
    return 0
}

// MARK: shaping

struct TextGlyph {
    var glyph: Int          // glyph id, fontTofuGlyph for a missing character, -1 if invisible
    var font: Int           // index into the run's chain
    var advance: Float      // pixels, kerning with the next glyph included
}

struct TextRun {
    var scalars: [UInt32]
    var glyphs: [TextGlyph]
    var xs: [Float]          // xs[i] = pen position before glyph i; xs[count] = total width
    var breaks: [UInt8]      // see textBreakOpportunities
    var chain: FontChain
    var size: Float
    var ascent: Float        // pixels, from the first font in the chain
    var descent: Float       // pixels, positive
    var lineGap: Float
    var xHeight: Float

    var count: Int { scalars.count }
    var width: Float { xs[xs.count - 1] }

    /// Width of scalars [from, to).
    func width(from: Int, to: Int) -> Float {
        let a = min(max(from, 0), count), b = min(max(to, a), count)
        return xs[b] - xs[a]
    }

    /// The next break opportunity strictly after `from` (a scalar index),
    /// or count at the end.
    func nextBreak(after from: Int) -> Int {
        var i = max(from, 0) + 1
        while i < count { if breaks[i] != 0 { return i }; i += 1 }
        return count
    }
}

struct TextLine {
    var start: Int
    var end: Int            // start of the next line (scalars [start, end) are on this line)
    var contentEnd: Int     // end without trailing spaces and the newline
    var width: Float        // width of [start, contentEnd)
    var forced: Bool        // ended by a mandatory break
}

func textIsCollapsibleSpace(_ c: UInt32) -> Bool {
    c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C || c == 0x3000
}

extension TextRun {
    /// One line starting at `start` that fits in `maxWidth`: it ends at the
    /// last break opportunity that fits (trailing spaces hang and do not count),
    /// at a mandatory break, or, if even the first word is too wide, at the
    /// next opportunity (or mid-word if `breakWords`). Always consumes at least
    /// one scalar when any remain.
    func fitLine(from start: Int, maxWidth: Float, breakWords: Bool = false) -> TextLine {
        let n = count
        let s = min(max(start, 0), n)
        if s >= n { return TextLine(start: s, end: s, contentEnd: s, width: 0, forced: false) }
        var lastOpp = -1
        var overflow = false
        var i = s
        var end = n
        var forced = false
        while i < n {
            if i > s {
                let b = breaks[i]
                if b == 2 { end = i; forced = true; break }
                if overflow && b == 1 { end = i; break }
                if b == 1 { lastOpp = i }
            }
            if !overflow && !textIsCollapsibleSpace(scalars[i]) && xs[i + 1] - xs[s] > maxWidth + 0.001 {
                if lastOpp > s { end = lastOpp; break }
                if i > s && breakWords { end = i; break }
                overflow = true
            }
            i += 1
        }
        var ce = end
        while ce > s && textIsCollapsibleSpace(scalars[ce - 1]) { ce -= 1 }
        return TextLine(start: s, end: end, contentEnd: ce, width: xs[ce] - xs[s], forced: forced)
    }
}

/// Shaping, measuring and drawing, with a shared glyph cache.
final class TextEngine {
    let registry: FontRegistry
    let cache: GlyphCache

    init(registry: FontRegistry, cache: GlyphCache = GlyphCache()) {
        self.registry = registry
        self.cache = cache
    }

    private func zeroWidth(_ c: UInt32) -> Bool {
        c < 0x20 && c != 0x09 || (c >= 0x7F && c < 0xA0) || c == 0xAD || (c >= 0x200B && c <= 0x200F)
            || c == 0x2028 || c == 0x2029 || c == 0x2060 || c == 0xFEFF || (c >= 0xFE00 && c <= 0xFE0F)
    }

    func shape(_ scalars: [UInt32], chain: FontChain, size: Float) -> TextRun {
        let n = scalars.count
        var glyphs = [TextGlyph](repeating: TextGlyph(glyph: -1, font: 0, advance: 0), count: n)
        var asc: Float = size * 0.9, desc: Float = size * 0.25, gap: Float = 0, xh: Float = size * 0.5
        if let f0 = chain.fonts.first {
            let sc = size / Float(f0.face.font.unitsPerEm)
            asc = Float(f0.face.font.ascent) * sc
            desc = Float(f0.face.font.descent) * sc
            gap = Float(f0.face.font.lineGap) * sc
            xh = Float(f0.face.font.xHeight) * sc
        }
        var prevGlyph = -1, prevFont = -1
        for i in 0..<n {
            var c = scalars[i]
            if zeroWidth(c) { prevGlyph = -1; continue }
            if c == 0xA0 || c == 0x09 || c == 0x202F || c == 0x3000 || c == 0x2007 { c = 0x20 }
            if c == 0x2011 { c = 0x2D }
            var found = false
            for (fi, tf) in chain.fonts.enumerated() {
                let g = tf.face.font.glyphIndex(c)
                if g == 0 { continue }
                let sc = size / Float(tf.face.font.unitsPerEm)
                var adv = Float(tf.face.font.advance(of: g)) * sc
                if tf.synthBold { adv += fontBoldAmount(size) }
                if prevGlyph >= 0 && prevFont == fi && i > 0 {
                    let k = tf.face.font.kern(prevGlyph, g)
                    if k != 0 { glyphs[i - 1].advance += Float(k) * sc }
                }
                glyphs[i] = TextGlyph(glyph: g, font: fi, advance: adv)
                prevGlyph = g; prevFont = fi
                found = true
                break
            }
            if !found {
                glyphs[i] = TextGlyph(glyph: fontTofuGlyph, font: 0, advance: size * 0.6)
                prevGlyph = -1
            }
        }
        var xs = [Float](repeating: 0, count: n + 1)
        var x: Float = 0
        for i in 0..<n { xs[i] = x; x += glyphs[i].advance }
        xs[n] = x
        return TextRun(scalars: scalars, glyphs: glyphs, xs: xs, breaks: textBreakOpportunities(scalars),
                       chain: chain, size: size, ascent: asc, descent: desc, lineGap: gap, xHeight: xh)
    }

    func shape(_ text: String, chain: FontChain, size: Float) -> TextRun {
        shape(textScalars(text), chain: chain, size: size)
    }

    /// Width in pixels of `text` (no wrapping).
    func measure(_ text: String, chain: FontChain, size: Float) -> Float {
        shape(text, chain: chain, size: size).width
    }

    /// The bitmap for glyph `i` of a run (nil for invisible or blank glyphs).
    func bitmap(_ run: TextRun, _ i: Int) -> GlyphBitmap? {
        let g = run.glyphs[i]
        guard g.glyph >= 0, g.font < run.chain.fonts.count else { return nil }
        let tf = run.chain.fonts[g.font]
        guard let b = cache.bitmap(fontID: tf.face.id, font: tf.face.font, glyph: g.glyph, size: run.size,
                                   bold: tf.synthBold, italic: tf.synthItalic) else { return nil }
        return b.width == 0 ? nil : b
    }

    /// Draw scalars [from, to) of a run with the pen at (x, baselineY) in an
    /// XRGB buffer. Glyph origins are rounded to whole pixels.
    func draw(_ run: TextRun, from: Int, to: Int, into dst: UnsafeMutablePointer<UInt32>, stride: Int,
              width: Int, height: Int, x: Float, baselineY: Int, color: UInt32, alpha: UInt8 = 255) {
        let a = min(max(from, 0), run.count), b = min(max(to, a), run.count)
        if a >= b { return }
        let origin = run.xs[a]
        for i in a..<b {
            guard let bm = bitmap(run, i) else { continue }
            let px = Int((x + run.xs[i] - origin).rounded())
            fontBlit(bm, into: dst, stride: stride, width: width, height: height,
                     x: px, y: baselineY, color: color, alpha: alpha)
        }
    }
}
