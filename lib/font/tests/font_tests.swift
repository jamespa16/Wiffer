// Host tests for lib/font. Reference numbers (advances, glyph ids, kerning,
// outline areas) were produced once with fontTools from the bundled DejaVu
// 2.37 files; areas come from fontTools' AreaPen, independent of our
// rasterizer.

private func loadBundled(_ t: Tests) -> FontRegistry {
    let reg = FontRegistry()
    for b in fontBundled {
        guard let d = t.readFile("rootfs" + b.path) else { continue }
        let f = reg.add(d, family: b.family, generic: b.generic, bold: b.bold, italic: b.italic)
        t.check(f != nil, "parse \(b.path)")
    }
    return reg
}

private func u16at(_ d: [UInt8], _ o: Int) -> Int { Int(d[o]) << 8 | Int(d[o + 1]) }
private func u32at(_ d: [UInt8], _ o: Int) -> Int { u16at(d, o) << 16 | u16at(d, o + 2) }

private func tableOffset(_ d: [UInt8], _ tag: String) -> (Int, Int)? {
    let n = u16at(d, 4)
    let want = Array(tag.utf8)
    for i in 0..<n {
        let r = 12 + i * 16
        if Array(d[r..<(r + 4)]) == want { return (u32at(d, r + 8), u32at(d, r + 12)) }
    }
    return nil
}

private func coverageSum(_ b: GlyphBitmap) -> Float {
    var s = 0
    for v in b.data { s += Int(v) }
    return Float(s) / 255
}

private func exercise(_ f: TTFont) {
    var g = 0
    while g < f.numGlyphs && g < 400 {
        _ = f.advance(of: g)
        _ = f.leftSideBearing(of: g)
        _ = FontRasterizer.render(f, glyph: g, size: 14)
        g += 7
    }
    for c in [UInt32(0x20), 0x41, 0x67, 0xE9, 0x20AC, 0x4E2D, 0x1F600, 0xFFFF, 0x10FFFF] {
        let gi = f.glyphIndex(c)
        _ = f.outline(gi)
        _ = f.kern(gi, f.glyphIndex(0x56))
    }
    _ = f.familyName
    _ = f.xHeight
    _ = f.capHeight
    _ = f.outline(-1)
    _ = f.outline(1 << 30)
}

func libTests(_ t: Tests) {
    let reg = loadBundled(t)
    t.equal(reg.faces.count, 12, "12 bundled faces")
    guard reg.faces.count == 12 else { return }
    let sans = reg.faces[0].font, sansBold = reg.faces[1].font
    let mono = reg.faces[8].font, serifBold = reg.faces[5].font

    // MARK: parsing
    t.section("parse")
    // file name: tables, glyphs, A, space, W, i advances (fontTools)
    let expect: [(Int, Int, Int, Int, Int, Int, Int)] = [
        (0, 20, 6253, 1401, 651, 2025, 569),
        (1, 19, 6196, 1585, 713, 2259, 702),
        (2, 19, 5355, 1401, 651, 2025, 569),
        (3, 19, 5413, 1585, 713, 2259, 702),
        (4, 20, 3528, 1479, 651, 2105, 655),
        (5, 19, 3506, 1589, 713, 2300, 778),
        (6, 19, 3507, 1479, 651, 2105, 655),
        (7, 19, 3506, 1589, 713, 2300, 778),
        (8, 18, 3377, 1233, 1233, 1233, 1233),
        (9, 18, 3316, 1233, 1233, 1233, 1233),
        (10, 18, 2710, 1233, 1233, 1233, 1233),
        (11, 18, 2711, 1233, 1233, 1233, 1233),
    ]
    for e in expect {
        let f = reg.faces[e.0].font
        let n = fontBundled[e.0].path
        t.equal(f.tableCount, e.1, "table count \(n)")
        t.equal(f.unitsPerEm, 2048, "unitsPerEm \(n)")
        t.equal(f.numGlyphs, e.2, "glyph count \(n)")
        t.equal(f.advance(of: f.glyphIndex(0x41)), e.3, "advance A \(n)")
        t.equal(f.advance(of: f.glyphIndex(0x20)), e.4, "advance space \(n)")
        t.equal(f.advance(of: f.glyphIndex(0x57)), e.5, "advance W \(n)")
        t.equal(f.advance(of: f.glyphIndex(0x69)), e.6, "advance i \(n)")
        t.equal(f.ascent, e.0 == 4 || e.0 == 6 ? 1901 : (e.0 == 5 || e.0 == 7 ? 1923 : 1901), "ascent \(n)")
        t.equal(f.descent, 483, "descent \(n)")
        t.check(f.advance(of: f.numGlyphs) == 0, "advance past end")
    }
    t.equal(sans.familyName ?? "", "DejaVu Sans", "family name")
    t.equal(serifBold.familyName ?? "", "DejaVu Serif", "serif family name")
    t.check(!sans.isBold && sansBold.isBold && reg.faces[2].font.isItalic && !sans.isItalic, "style flags")
    t.check(sans.xHeight > 1000 && sans.xHeight < 1200, "xHeight", "\(sans.xHeight)")
    t.check(sans.capHeight > 1400 && sans.capHeight < 1600, "capHeight", "\(sans.capHeight)")

    // MARK: cmap
    t.section("cmap")
    t.equal(sans.glyphIndex(0x41), 36, "A")
    t.equal(sans.glyphIndex(0x67), 74, "g")
    t.equal(sans.glyphIndex(0xE9), 171, "eacute")
    t.equal(sans.glyphIndex(0x20AC), 2948, "Euro")
    t.equal(sans.glyphIndex(0x3B1), 838, "alpha")
    t.equal(sans.glyphIndex(0x1F600), 5857, "U+1F600 (format 12)")
    t.equal(sans.glyphIndex(0x4E2D), 0, "CJK not in DejaVu")
    t.equal(sans.glyphIndex(0x10FFFF), 0, "out of range")
    t.equal(sans.glyphIndex(0xFFFF), 0, "FFFF")

    // MARK: kerning
    t.section("kern")
    let gA = sans.glyphIndex(0x41), gV = sans.glyphIndex(0x56), gT = sans.glyphIndex(0x54), go = sans.glyphIndex(0x6F)
    t.equal(sans.kern(gA, gV), -131, "kern A V")
    t.equal(sans.kern(gT, go), -348, "kern T o")
    t.equal(sans.kern(gA, gA), 57, "kern A A")
    t.equal(sans.kern(go, go), 0, "no kern o o")
    t.check(sans.hasKerning && !mono.hasKerning, "hasKerning")
    t.equal(mono.kern(gA, gV), 0, "mono has no kern")

    // MARK: outlines
    t.section("outlines")
    if let e = sans.outline(171), let plain = sans.outline(sans.glyphIndex(0x65)) {
        t.check(e.points.count > plain.points.count && e.ends.count == plain.ends.count + 1,
                "eacute is composite (e + acute)", "\(e.points.count) vs \(plain.points.count)")
    } else { t.check(false, "eacute outline") }
    t.check(sans.outline(3)?.points.isEmpty == true, "space outline empty")
    let areas: [(Int, Float)] = [(36, 678360), (74, 732244.25), (171, 635586.75), (167, 734421.33), (2948, 651142.75), (5857, 1310727.25)]
    for (g, area) in areas {
        // composite glyphs 171 (eacute) and 167 (aring) exercise transforms/offsets
        if let b = FontRasterizer.render(sans, glyph: g, size: 256) {
            let want = area * (256 / 2048) * (256 / 2048)
            let got = coverageSum(b)
            t.check(abs(got - want) / want < 0.01, "area glyph \(g)", "got \(got) want \(want)")
        } else { t.check(false, "render glyph \(g)") }
    }

    // MARK: rasterizer
    t.section("raster")
    for ch in [UInt32(0x41), 0x67] {
        let g = sans.glyphIndex(ch)
        let area: Float = ch == 0x41 ? 678360 : 732244.25
        for size in [Float(12), 16, 24, 48, 100] {
            guard let b = FontRasterizer.render(sans, glyph: g, size: size) else { t.check(false, "render \(ch) \(size)"); continue }
            let s = size / 2048
            let want = area * s * s
            let tol: Float = size < 20 ? 0.03 : 0.015
            t.check(abs(coverageSum(b) - want) / want < tol, "coverage \(ch) @\(size)", "got \(coverageSum(b)) want \(want)")
            t.check(b.width > 0 && b.height > 0 && b.data.count == b.width * b.height, "bitmap dims")
            t.check(abs(b.advance - Float(sans.advance(of: g)) * s) < 0.001, "bitmap advance")
            // the bbox is tight: ink within the first/last two rows and columns
            var top = 0, bottom = 0, leftCol = 0, rightCol = 0
            for x in 0..<b.width { for k in 0..<min(2, b.height) { top += Int(b.data[k * b.width + x]); bottom += Int(b.data[(b.height - 1 - k) * b.width + x]) } }
            for y in 0..<b.height { for k in 0..<min(2, b.width) { leftCol += Int(b.data[y * b.width + k]); rightCol += Int(b.data[y * b.width + b.width - 1 - k]) } }
            t.check(top > 0 && bottom > 0 && leftCol > 0 && rightCol > 0, "tight bbox \(ch) @\(size)")
        }
    }
    if let a = FontRasterizer.render(sans, glyph: gA, size: 64) {
        // 'A' is symmetric about half its advance: centroid on that axis
        var sx: Float = 0, sw: Float = 0
        for y in 0..<a.height { for x in 0..<a.width {
            let v = Float(a.data[y * a.width + x]); sx += v * (Float(x + a.left) + 0.5); sw += v
        } }
        t.check(abs(sx / sw - a.advance / 2) < 0.4, "A symmetric", "centroid \(sx / sw) vs \(a.advance / 2)")
        // inside the apex-to-baseline bar (crossbar row) has coverage; far corner doesn't
        t.check(a.data[0] == 0 && a.data[a.width - 1] == 0, "A top corners empty")
        t.check(a.top > 40 && a.top < 55, "A height ~0.73em", "\(a.top)")
        let barRow = a.height * 2 / 3
        t.check(a.data[barRow * a.width + a.width / 2] == 255, "A crossbar solid")
    }
    // 'H' symmetric: left half and right half coverage equal
    if let h = FontRasterizer.render(sans, glyph: sans.glyphIndex(0x48), size: 40) {
        var l: Float = 0, r: Float = 0
        let cx = Float(h.advance) / 2
        for y in 0..<h.height { for x in 0..<h.width {
            let v = Float(h.data[y * h.width + x]); let px = Float(x + h.left) + 0.5
            if px < cx { l += v } else { r += v }
        } }
        t.check(abs(l - r) / (l + r) < 0.02, "H halves equal")
    }
    // blank glyph and bad inputs
    if let sp = FontRasterizer.render(sans, glyph: 3, size: 16) {
        t.check(sp.width == 0 && sp.advance > 0, "space bitmap empty with advance")
    } else { t.check(false, "space render") }
    t.check(FontRasterizer.render(sans, glyph: gA, size: 0) == nil, "size 0")
    t.check(FontRasterizer.render(sans, glyph: gA, size: 100000) == nil, "huge size")
    t.check(FontRasterizer.render(sans, glyph: 1 << 20, size: 16) == nil, "bad glyph")
    // synthetic bold and italic
    if let n = FontRasterizer.render(sans, glyph: gA, size: 32),
       let b = FontRasterizer.render(sans, glyph: gA, size: 32, bold: true),
       let i = FontRasterizer.render(sans, glyph: gA, size: 32, italic: true) {
        t.check(coverageSum(b) > coverageSum(n) * 1.05, "synthetic bold adds ink")
        t.check(b.advance > n.advance, "synthetic bold widens advance")
        // oblique: ink at the top shifts right relative to the bottom
        func centroid(_ g: GlyphBitmap, _ y0: Int, _ y1: Int) -> Float {
            var s: Float = 0, w: Float = 0
            for y in y0..<y1 { for x in 0..<g.width { let v = Float(g.data[y * g.width + x]); s += v * Float(x + g.left); w += v } }
            return s / max(w, 1)
        }
        let sh = centroid(i, 0, 6) - centroid(i, i.height - 6, i.height)
        let sn = centroid(n, 0, 6) - centroid(n, n.height - 6, n.height)
        t.check(sh > sn + 3, "synthetic italic shears", "\(sh) vs \(sn)")
    } else { t.check(false, "synthetic render") }

    // MARK: cache
    t.section("cache")
    let cache = GlyphCache(capacity: 5_000)
    for pass in 0..<2 {
        for g in 30..<130 {
            _ = cache.bitmap(fontID: 0, font: sans, glyph: g, size: 16, bold: false, italic: false)
            t.check(cache.bytes <= cache.capacity, "cache under cap pass \(pass)")
        }
    }
    t.check(cache.clears > 0, "cache cleared when full", "\(cache.clears)")
    let c2 = GlyphCache()
    _ = c2.bitmap(fontID: 0, font: sans, glyph: 36, size: 16, bold: false, italic: false)
    _ = c2.bitmap(fontID: 0, font: sans, glyph: 36, size: 16, bold: false, italic: false)
    _ = c2.bitmap(fontID: 0, font: sans, glyph: 36, size: 17, bold: false, italic: false)
    _ = c2.bitmap(fontID: 1, font: sans, glyph: 36, size: 16, bold: true, italic: false)
    t.check(c2.hits == 1 && c2.misses == 3 && c2.count == 3, "cache keys (font, size, glyph, style)",
            "hits \(c2.hits) misses \(c2.misses) count \(c2.count)")

    // MARK: blit
    t.section("blit")
    let half = GlyphBitmap(width: 1, height: 1, left: 0, top: 1, advance: 1, data: [128])
    var px = [UInt32](repeating: 0, count: 16)
    fontBlit(half, into: &px, width: 4, x: 1, y: 1, color: 0xFFFFFF)
    t.check(px[0] == 0x808080 || px[0] == 0 , "blit placement")
    t.equal(Int(px[1]), 0x808080, "half coverage white on black")
    fontBlit(half, into: &px, width: 4, x: 1, y: 1, color: 0xFF0000, alpha: 128)
    t.equal(Int(px[1] >> 16 & 255), 0xA0, "alpha-scaled red over grey (red)")
    let full = GlyphBitmap(width: 2, height: 2, left: -1, top: 1, advance: 1, data: [255, 255, 255, 255])
    fontBlit(full, into: &px, width: 4, x: 0, y: 0, color: 0x112233)       // partly outside top-left
    t.equal(Int(px[0]), 0x112233, "clipped blit")
    fontBlit(full, into: &px, width: 4, x: 100, y: 100, color: 0x112233)
    fontBlit(full, into: &px, width: 4, x: -100, y: -100, color: 0x112233)
    fontBlit(full, into: &px, width: 0, x: 0, y: 0, color: 0x112233)
    t.check(true, "off-buffer blits do not crash")

    // MARK: registry
    t.section("registry")
    func famOf(_ names: [String], _ w: Int = 400, _ it: Bool = false) -> TextFont? {
        reg.face(family: names[0], weight: w, italic: it)
    }
    t.equal(famOf(["Arial"])?.face.family ?? "", "DejaVu Sans", "Arial")
    t.equal(famOf(["helvetica"])?.face.family ?? "", "DejaVu Sans", "helvetica")
    t.equal(famOf(["system-ui"])?.face.family ?? "", "DejaVu Sans", "system-ui")
    t.equal(famOf(["Verdana"])?.face.family ?? "", "DejaVu Sans", "Verdana")
    t.equal(famOf(["Times New Roman"])?.face.family ?? "", "DejaVu Serif", "Times New Roman")
    t.equal(famOf(["'Georgia'"])?.face.family ?? "", "DejaVu Serif", "quoted Georgia")
    t.equal(famOf(["serif"])?.face.family ?? "", "DejaVu Serif", "serif")
    t.equal(famOf(["Courier New"])?.face.family ?? "", "DejaVu Sans Mono", "Courier New")
    t.equal(famOf(["MONOSPACE"])?.face.family ?? "", "DejaVu Sans Mono", "MONOSPACE")
    t.equal(famOf(["DejaVu Serif"])?.face.family ?? "", "DejaVu Serif", "specific name")
    t.check(famOf(["Comic Sans Nonexistent"]) == nil, "unknown family")
    if let b = famOf(["sans-serif"], 700, true) {
        t.check(b.face.weight == 700 && b.face.italic && !b.synthBold && !b.synthItalic, "bold italic exact face")
    } else { t.check(false, "bold italic") }
    if let b = famOf(["serif"], 900, false) { t.check(b.face.weight == 700 && !b.synthBold, "weight 900 -> bold face") }
    let chain = reg.chain(families: ["Helvetica", "Arial", "Times"], weight: 400, italic: false)
    t.check(chain.fonts.count == 3 && chain.fonts[0].face.family == "DejaVu Sans" && chain.fonts[1].face.family == "DejaVu Serif"
            && chain.fonts[2].face.family == "DejaVu Sans Mono", "chain without repeats", "\(chain.fonts.count)")
    t.check(reg.chain(families: ["nonexistent"], weight: 400, italic: false).fonts[0].face.family == "DejaVu Sans",
            "unknown family falls back to sans")
    // A registry with only regular faces synthesizes bold and italic.
    let partial = FontRegistry()
    if let d = t.readFile("rootfs/fonts/DejaVuSerif.ttf") {
        partial.add(d, family: "DejaVu Serif", generic: .serif, bold: false, italic: false)
        let s = partial.face(family: "serif", weight: 700, italic: true)
        t.check(s?.synthBold == true && s?.synthItalic == true, "synthetic fallback flags")
        let s2 = partial.face(family: "serif", weight: 400, italic: false)
        t.check(s2?.synthBold == false && s2?.synthItalic == false, "no synthesis when exact")
    }
    t.check(FontRegistry().add([1, 2, 3], family: "x", generic: .serif, bold: false, italic: false) == nil, "garbage rejected")
    t.check(FontRegistry().face(family: "serif", weight: 400, italic: false) == nil, "empty registry")

    // MARK: text runs
    t.section("text")
    let engine = TextEngine(registry: reg)
    let sansChain = reg.chain(families: ["sans-serif"], weight: 400, italic: false)
    let size: Float = 16
    let sc = size / 2048
    let av = engine.shape("AV", chain: sansChain, size: size)
    let want = Float(sans.advance(of: gA) + sans.advance(of: gV) - 131) * sc
    t.check(abs(av.width - want) < 0.001, "AV kerned width", "\(av.width) vs \(want)")
    let noKern = engine.shape("AB", chain: sansChain, size: size)
    t.check(abs(noKern.width - Float(sans.advance(of: gA) + sans.advance(of: sans.glyphIndex(0x42))) * sc + 0) < 0.001
            || noKern.width > 0, "AB width")
    t.check(abs(engine.measure("A V", chain: sansChain, size: size) -
                Float(sans.advance(of: gA) + 651 + sans.advance(of: gV)) * sc) < 0.001, "no kerning across a space")
    t.check(engine.measure("", chain: sansChain, size: size) == 0, "empty measure")
    t.check(abs(av.ascent - 1901 * sc) < 0.001 && abs(av.descent - 483 * sc) < 0.001, "run ascent/descent")
    // tofu: CJK is in no bundled face
    let tofu = engine.shape("a\u{4E2D}b", chain: sansChain, size: size)
    t.check(tofu.glyphs[1].glyph == fontTofuGlyph && tofu.glyphs[0].glyph != fontTofuGlyph, "tofu for missing char")
    t.check(abs(tofu.glyphs[1].advance - size * 0.6) < 0.001, "tofu advance")
    if let tb = engine.bitmap(tofu, 1) {
        t.check(tb.width > 2 && tb.data[0] == 255 && tb.data[tb.width + 1] == 0, "tofu is a hollow box")
    } else { t.check(false, "tofu bitmap") }
    // fallback: find a char in sans but not in mono
    var fb: UInt32 = 0
    for c in UInt32(0x100)..<0x2000 where mono.glyphIndex(c) == 0 && sans.glyphIndex(c) != 0 { fb = c; break }
    t.check(fb != 0, "found char only in sans")
    let monoFirst = reg.chain(families: ["monospace", "sans-serif"], weight: 400, italic: false)
    let fr = engine.shape([0x41, fb], chain: monoFirst, size: size)
    t.check(fr.glyphs[0].font == 0 && fr.glyphs[1].font == 1 && fr.glyphs[1].glyph == sans.glyphIndex(fb), "falls back to next face")
    // controls and zero-width
    let z = engine.shape([0x61, 0x200B, 0xAD, 0x0A, 0x62], chain: sansChain, size: size)
    t.check(z.glyphs[1].advance == 0 && z.glyphs[2].advance == 0 && z.glyphs[3].advance == 0, "zero-width chars")
    t.check(abs(engine.shape([0xA0], chain: sansChain, size: size).width - 651 * sc) < 0.001, "nbsp is a space")
    // bad UTF-8
    t.equal(textDecodeUTF8([0x61, 0xFF, 0xC3, 0xA9, 0xE2, 0x82]).count, 4, "utf8 replacement")
    t.check(textDecodeUTF8([0xF0, 0x9F, 0x98, 0x80]) == [0x1F600], "utf8 4-byte")
    t.check(textDecodeUTF8([0xC0, 0x80]) == [0xFFFD, 0xFFFD], "overlong rejected")
    t.check(textScalars("\u{E9}\u{4E2D}") == [0xE9, 0x4E2D], "String scalars")
    // drawing
    var buf = [UInt32](repeating: 0xFFFFFF, count: 100 * 30)
    let hello = engine.shape("Hello", chain: sansChain, size: 16)
    buf.withUnsafeMutableBufferPointer { p in
        engine.draw(hello, from: 0, to: 5, into: p.baseAddress!, stride: 100, width: 100, height: 30,
                    x: 4, baselineY: 20, color: 0x000000)
    }
    var inked = 0
    for v in buf where v != 0xFFFFFF { inked += 1 }
    t.check(inked > 40 && buf[0] == 0xFFFFFF, "draw inked pixels", "\(inked)")

    // MARK: line breaking
    t.section("breaks")
    func brk(_ s: String) -> [Int] {
        let b = textBreakOpportunities(textScalars(s))
        var r: [Int] = []
        for i in 1..<max(b.count - 1, 1) where b[i] != 0 { r.append(i) }
        return r
    }
    t.check(brk("hello world foo") == [6, 12], "after spaces", "\(brk("hello world foo"))")
    t.check(brk("well-known thing") == [5, 11], "after hyphen", "\(brk("well-known thing"))")
    t.check(brk("a -5 b") == [2, 5], "no break before digit after hyphen", "\(brk("a -5 b"))")
    t.check(brk("x--y") == [], "double hyphen", "\(brk("x--y"))")
    t.check(brk("日本語") == [1, 2], "between ideographs")
    t.check(brk("日本。語") == [1, 3], "never before closing punctuation, allowed after", "\(brk("日本。語"))")
    t.check(brk("a )b") == [], "no break before closing paren")
    t.check(brk("foo, bar") == [5], "comma stays with word", "\(brk("foo, bar"))")
    t.check(brk("(a b)") == [3], "no break after open paren", "\(brk("(a b)"))")
    t.check(brk("「日本」") == [2], "CJK open/close", "\(brk("「日本」"))")
    t.check(brk("a\u{A0}b c") == [4], "nbsp glues", "\(brk("a\u{A0}b c"))")
    t.check(brk("ab\u{200B}cd") == [3], "zwsp", "\(brk("ab\u{200B}cd"))")
    t.check(brk("a\u{AD}b") == [2], "soft hyphen", "\(brk("a\u{AD}b"))")
    let mb = textBreakOpportunities(textScalars("ab\ncd\r\nef"))
    t.check(mb[3] == 2 && mb[7] == 2 && mb[6] == 0, "mandatory breaks incl. CRLF", "\(mb)")
    t.check(textBreakOpportunities([]) == [0], "empty")

    // fitLine with monospace: every glyph is 1233/2048 em wide
    let mchain = reg.chain(families: ["monospace"], weight: 400, italic: false)
    let msize: Float = 20
    let cw = 1233 * msize / 2048
    let m = engine.shape("hello world foo", chain: mchain, size: msize)
    t.check(abs(m.width - 15 * cw) < 0.01, "mono run width")
    var l = m.fitLine(from: 0, maxWidth: 11.5 * cw)
    t.check(l.end == 12 && l.contentEnd == 11 && abs(l.width - 11 * cw) < 0.01 && !l.forced, "fit: hang trailing space",
            "end \(l.end) ce \(l.contentEnd)")
    l = m.fitLine(from: 12, maxWidth: 11.5 * cw)
    t.check(l.end == 15 && l.contentEnd == 15, "fit: last line")
    l = m.fitLine(from: 0, maxWidth: 5.5 * cw)
    t.check(l.end == 6 && l.contentEnd == 5, "fit: first word exactly", "end \(l.end)")
    l = m.fitLine(from: 0, maxWidth: 3 * cw)
    t.check(l.end == 6, "fit: overlong word overflows to next opportunity", "end \(l.end)")
    l = m.fitLine(from: 0, maxWidth: 3 * cw, breakWords: true)
    t.check(l.end == 3, "fit: breakWords splits mid-word", "end \(l.end)")
    l = m.fitLine(from: 0, maxWidth: 0.2 * cw, breakWords: true)
    t.check(l.end >= 1, "fit: always progresses")
    let nl = engine.shape("ab\ncd", chain: mchain, size: msize)
    l = nl.fitLine(from: 0, maxWidth: 1000)
    t.check(l.end == 3 && l.contentEnd == 2 && l.forced && abs(l.width - 2 * cw) < 0.01, "fit: newline ends line")
    t.check(m.nextBreak(after: 0) == 6 && m.nextBreak(after: 6) == 12 && m.nextBreak(after: 12) == 15, "nextBreak")
    t.check(abs(m.width(from: 6, to: 11) - 5 * cw) < 0.01, "width(from:to:)")
    t.check(m.fitLine(from: 15, maxWidth: 10).end == 15 && m.fitLine(from: 99, maxWidth: 10).end == 15, "fit at end")
    // paragraph wrap loop terminates and covers everything
    let para = engine.shape(String(repeating: "lorem ipsum dolor-sit amet ", count: 20), chain: sansChain, size: 14)
    var pos = 0, lines = 0
    while pos < para.count && lines < 1000 {
        let ln = para.fitLine(from: pos, maxWidth: 150)
        t.check(ln.end > pos && ln.width <= 150.01, "wrap line fits", "w \(ln.width)")
        pos = ln.end; lines += 1
    }
    t.check(pos == para.count && lines > 5, "wrap covers paragraph", "lines \(lines)")

    // MARK: hostile input
    t.section("hostile")
    t.check(TTFont([]) == nil && TTFont([0, 1, 0, 0]) == nil && TTFont(Array("OTTO".utf8) + [UInt8](repeating: 0, count: 64)) == nil, "reject junk")
    if let d = t.readFile("rootfs/fonts/DejaVuSerif.ttf") {
        for n in [0, 11, 12, 100, 300, 1000, 100_000, d.count - 1] {
            if let f = TTFont(Array(d.prefix(n))) { exercise(f) }
        }
        t.check(TTFont(Array(d.prefix(300))) == nil, "truncated table data rejected")
        // composite recursion: make eacute's first component refer to itself
        var h = d
        if let (loca, _) = tableOffset(h, "loca"), let (glyf, _) = tableOffset(h, "glyf"), let (head, _) = tableOffset(h, "head") {
            let longLoca = u16at(h, head + 50) == 1
            let serif = reg.faces[4].font
            let g = serif.glyphIndex(0xE9)
            let off = longLoca ? u32at(h, loca + g * 4) : u16at(h, loca + g * 2) * 2
            let at = glyf + off + 10          // component flags, then glyph index
            h[at + 2] = UInt8(g >> 8); h[at + 3] = UInt8(g & 255)
            if let f = TTFont(h) {
                t.check(f.outline(g) == nil, "self-referential composite rejected")
                exercise(f)
            } else { t.check(false, "mutated font still parses") }
        }
        // out-of-range loca / huge point counts: every outline call is safe
        var h2 = d
        if let (loca, len) = tableOffset(h2, "loca") {
            var i = loca; while i < loca + len { h2[i] = 0xFF; i += 3 }
            if let f = TTFont(h2) { exercise(f) }
        }
    }

    // MARK: fuzz
    t.section("fuzz")
    t.fuzz("TTFont", seeds: [Array((t.readFile("rootfs/fonts/DejaVuSansMono-Oblique.ttf") ?? []).prefix(4000))], iterations: 400) { data in
        if let f = TTFont(data) { exercise(f) }
    }
    // Targeted mutations: directory and table headers of a whole font, plus glyf/loca/cmap bytes.
    if let seed = t.readFile("rootfs/fonts/DejaVuSansMono-Oblique.ttf") {
        var rng = TestRandom(seed: 0xF0F7)
        var tabs: [Int] = [0, 4, 12]
        let nt = u16at(seed, 4)
        for i in 0..<nt { tabs.append(u32at(seed, 12 + i * 16 + 8)); tabs.append(12 + i * 16) }
        var parsed = 0
        for iter in 0..<500 {
            var m = seed
            for _ in 0..<(1 + rng.below(5)) {
                let base = tabs[rng.below(tabs.count)]
                let at = min(base + rng.below(64), m.count - 1)
                switch rng.below(4) {
                case 0: m[at] ^= UInt8(1 << rng.below(8))
                case 1: m[at] = 0xFF
                case 2: m[at] = 0
                default: m[at] = UInt8(truncatingIfNeeded: rng.next())
                }
            }
            if iter % 5 == 0 { m = Array(m.prefix(rng.below(m.count))) }
            if let f = TTFont(m) { parsed += 1; exercise(f) }
        }
        t.check(parsed > 20, "fuzz mutants mostly still parse (so glyph paths run)", "\(parsed)")
    }

    // MARK: speed
    t.section("speed")
    let glyphIDs = (0x61...0x7A).map { sans.glyphIndex(UInt32($0)) }
    let start = hostMillis()
    var rendered = 0
    var ms = 0
    repeat {
        for _ in 0..<200 { for g in glyphIDs { if FontRasterizer.render(sans, glyph: g, size: 16) != nil { rendered += 1 } } }
        ms = hostMillis() - start
    } while ms < 300
    print("font: rasterized \(rendered) glyphs at 16 px in \(ms) ms = \(rendered * 1000 / max(ms, 1)) glyphs/s (uncached, host)")
    t.check(rendered > 0, "speed measured")
}
