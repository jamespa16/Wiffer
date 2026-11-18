// PSF1 bitmap fonts (the console font is Spleen 8x16). Shared with user
// programs (lib/gui/SRCS), so it must not depend on kernel code.

// MARK: PSF1 font

struct PSFFont {
    let glyphs: UnsafePointer<UInt8>
    let glyphCount: Int
    /// Glyph height in pixels (= bytes per glyph; PSF1 glyphs are 8 wide).
    let height: Int
    let width = 8
    /// BMP codepoint -> glyph index, 0xFFFF if the font has no glyph.
    var map: [UInt16]
    /// Glyph for unmapped codepoints: U+FFFD, else '?', else glyph 0.
    var fallback: Int = 0

    /// Parse a PSF1 font. Returns nil if the header or sizes don't check out.
    init?(_ data: UnsafePointer<UInt8>, size: Int) {
        guard size >= 4, data[0] == 0x36, data[1] == 0x04 else { return nil }
        let mode = data[2]
        glyphCount = mode & 0x01 != 0 ? 512 : 256
        height = Int(data[3])
        let tableStart = 4 + glyphCount * height
        guard height > 0, tableStart <= size else { return nil }
        glyphs = data + 4
        map = Array(repeating: 0xFFFF, count: 0x10000)
        if mode & 0x02 != 0 {
            // Per glyph: UCS-2 LE codepoints, then optional 0xFFFE-introduced
            // sequences (ignored), terminated by 0xFFFF.
            var i = tableStart, g = 0, inSequence = false
            while g < glyphCount && i + 1 < size {
                let v = Int(data[i]) | Int(data[i + 1]) << 8
                i += 2
                if v == 0xFFFF { g += 1; inSequence = false }
                else if v == 0xFFFE { inSequence = true }
                else if !inSequence && map[v] == 0xFFFF { map[v] = UInt16(g) }
            }
        } else {
            for c in 0..<glyphCount { map[c] = UInt16(c) }
        }
        if map[0xFFFD] != 0xFFFF { fallback = Int(map[0xFFFD]) }
        else if map[0x3F] != 0xFFFF { fallback = Int(map[0x3F]) }
    }

    func glyph(_ cp: UInt32) -> Int {
        guard cp < 0x10000 else { return fallback }
        let g = map[Int(cp)]
        return g == 0xFFFF ? fallback : Int(g)
    }

    /// The glyph's rows, one byte each, MSB = leftmost pixel.
    func bitmap(_ glyph: Int) -> UnsafePointer<UInt8> {
        glyphs + glyph * height
    }
}
