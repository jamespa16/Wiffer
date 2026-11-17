// Phase I selftests: Rect geometry, Surface primitives checked pixel by pixel
// on small surfaces (clipping at every edge, negative coordinates), sprites,
// text, and ConsoleView (called from runSelfTests).

/// Every pixel of `s` equals `want(x, y)`.
func surfaceIs(_ s: Surface, _ want: (Int, Int) -> UInt32) -> Bool {
    for y in 0..<s.height {
        for x in 0..<s.width where s.pixel(x, y) != want(x, y) { return false }
    }
    return true
}

/// `s` is `bg` except inside `r`, which is `fg`.
func onlyRect(_ s: Surface, _ r: Rect, _ fg: UInt32, _ bg: UInt32) -> Bool {
    surfaceIs(s) { x, y in r.contains(Point(x, y)) ? fg : bg }
}

/// Fill `s` with a pattern unique per pixel.
func pattern(_ s: Surface, _ base: UInt32) {
    for y in 0..<s.height { for x in 0..<s.width { s.plot(x, y, base + UInt32(y * 100 + x)) } }
}

/// The pixel `font` draws for glyph `g` at (x, y) inside the cell.
func glyphBit(_ font: PSFFont, _ g: Int, _ x: Int, _ y: Int) -> Bool {
    font.bitmap(g)[y] & (UInt8(0x80) >> UInt8(x)) != 0
}

let testSpriteArt: StaticString = """
Xo.
.oX
"""

func rectTests(_ t: inout SelfTest) {
    let a = Rect(0, 0, 10, 10), b = Rect(5, -5, 10, 8)
    t.check("rect: intersection", a.intersection(b) == Rect(5, 0, 5, 3))
    t.check("rect: disjoint intersection is empty",
            a.intersection(Rect(10, 0, 5, 5)).isEmpty && a.intersection(Rect(-5, -5, 5, 20)).isEmpty)
    t.check("rect: union", a.union(b) == Rect(0, -5, 15, 15))
    t.check("rect: union ignores empty", a.union(Rect(50, 50, 0, 3)) == a && Rect.empty.union(b) == b
            && Rect(1, 1, -2, 4).union(.empty).isEmpty)
    t.check("rect: contains point (half-open)", a.contains(Point(0, 0)) && a.contains(Point(9, 9))
            && !a.contains(Point(10, 5)) && !a.contains(Point(5, 10)) && !a.contains(Point(-1, 0)))
    t.check("rect: contains rect", a.contains(Rect(2, 2, 8, 8)) && !a.contains(Rect(2, 2, 9, 8))
            && a.contains(Rect.empty))
    t.check("rect: isEmpty", Rect(3, 3, 0, 5).isEmpty && Rect(3, 3, 5, -1).isEmpty && !Rect(-3, -3, 1, 1).isEmpty)
    t.check("rect: offsetBy", b.offsetBy(dx: -5, dy: 5) == Rect(0, 0, 10, 8)
            && a.offsetBy(Point(-2, 3)) == Rect(-2, 3, 10, 10))
    t.check("rect: negative coordinates", Rect(-4, -4, 6, 6).intersection(a) == Rect(0, 0, 2, 2)
            && !Rect(-4, -4, 6, 6).contains(Point(2, 0)) && Rect(-4, -4, 6, 6).contains(Point(-4, 1)))
}

func surfaceTests(_ t: inout SelfTest) {
    rectTests(&t)
    let bg: UInt32 = 0x111111, fg: UInt32 = 0xABCDEF
    let s = Surface(width: 8, height: 6, color: bg)
    t.check("surface: created filled", onlyRect(s, .empty, fg, bg) && s.clip == s.bounds && s.pixel(8, 0) == nil
            && s.pixel(0, -1) == nil)

    // Fill, clipped at every edge and from negative coordinates.
    let fills = [Rect(2, 1, 3, 2), Rect(-3, -2, 5, 4), Rect(6, 4, 9, 9), Rect(-1, 2, 20, 1),
                 Rect(3, -9, 2, 30), Rect(-10, -10, 30, 30), Rect(8, 0, 2, 2), Rect(0, -2, 3, 2), Rect(1, 1, 0, 3)]
    var fillsOK = true
    for r in fills {
        s.fill(bg)
        s.fill(r, fg)
        if !onlyRect(s, r, fg, bg) { fillsOK = false }
    }
    t.check("surface: fill clipped at each edge, negative coords", fillsOK)

    // Clip rect: fill and plot stop at it; withClip narrows and restores.
    s.fill(bg)
    s.setClip(Rect(1, 1, 5, 3))
    s.fill(Rect(-5, -5, 20, 20), fg)
    s.plot(0, 0, fg); s.plot(6, 4, fg)
    let clipOK = onlyRect(s, Rect(1, 1, 5, 3), fg, bg)
    s.setClip(Rect(-4, 4, 100, 100))
    let clamped = s.clip == Rect(0, 4, 8, 2)
    s.setClip(nil)
    s.fill(bg)
    s.withClip(Rect(4, 0, 10, 3)) {
        s.withClip(Rect(0, 1, 6, 10)) { s.fill(fg) }
    }
    t.check("surface: clip rect limits drawing", clipOK && clamped)
    t.check("surface: nested withClip restores", onlyRect(s, Rect(4, 1, 2, 2), fg, bg) && s.clip == s.bounds)

    // Lines and frames.
    s.fill(bg)
    s.hline(x: -2, y: 0, w: 5, fg)
    s.hline(x: 6, y: 5, w: 9, fg)
    s.vline(x: 7, y: -3, h: 5, fg)
    s.hline(x: 0, y: -1, w: 8, fg); s.vline(x: 8, y: 0, h: 6, fg) // fully outside
    t.check("surface: hline/vline clipped", surfaceIs(s) { x, y in
        (y == 0 && x < 3) || (y == 5 && x >= 6) || (x == 7 && y < 2) ? fg : bg })
    s.fill(bg)
    s.frame(Rect(1, 1, 5, 4), fg)
    t.check("surface: frame", surfaceIs(s) { x, y in
        (x >= 1 && x <= 5 && y >= 1 && y <= 4) && (x == 1 || x == 5 || y == 1 || y == 4) ? fg : bg })
    s.fill(bg)
    s.frame(Rect(-1, -1, 10, 8), fg) // only the edges outside: nothing drawn
    let offFrame = onlyRect(s, .empty, fg, bg)
    s.frame(Rect(4, 3, 6, 6), fg) // right and bottom sides clipped away
    t.check("surface: frame clipped", offFrame && surfaceIs(s) { x, y in
        (x >= 4 && y >= 3) && (x == 4 || y == 3) ? fg : bg })

    // Blit from another surface, clipped on both sides.
    let src = Surface(width: 4, height: 3)
    pattern(src, 0x1000)
    func srcPx(_ x: Int, _ y: Int) -> UInt32 { 0x1000 + UInt32(y * 100 + x) }
    s.fill(bg)
    s.blit(from: src, src: src.bounds, to: Point(2, 1))
    let plain = surfaceIs(s) { x, y in Rect(2, 1, 4, 3).contains(Point(x, y)) ? srcPx(x - 2, y - 1) : bg }
    s.fill(bg)
    s.blit(from: src, src: src.bounds, to: Point(-2, -1))
    let negative = surfaceIs(s) { x, y in x < 2 && y < 2 ? srcPx(x + 2, y + 1) : bg }
    s.fill(bg)
    s.blit(from: src, src: src.bounds, to: Point(6, 4))
    let farEdge = surfaceIs(s) { x, y in x >= 6 && y >= 4 ? srcPx(x - 6, y - 4) : bg }
    s.fill(bg)
    s.blit(from: src, src: Rect(-1, 1, 3, 5), to: Point(0, 0)) // source rect off its surface
    let srcClip = surfaceIs(s) { x, y in x >= 1 && x < 3 && y < 2 ? srcPx(x - 1, y + 1) : bg }
    s.fill(bg)
    s.setClip(Rect(3, 0, 2, 6))
    s.blit(from: src, src: src.bounds, to: Point(2, 2))
    s.setClip(nil)
    let dstClip = surfaceIs(s) { x, y in x >= 3 && x < 5 && y >= 2 && y < 5 ? srcPx(x - 2, y - 2) : bg }
    s.fill(bg)
    s.blit(from: src, src: src.bounds, to: Point(8, 0))
    s.blit(from: src, src: src.bounds, to: Point(0, -3))
    let outside = onlyRect(s, .empty, fg, bg)
    t.check("surface: blit", plain)
    t.check("surface: blit clipped at negative coords", negative)
    t.check("surface: blit clipped at far edges", farEdge)
    t.check("surface: blit source rect clipped", srcClip)
    t.check("surface: blit honours destination clip", dstClip)
    t.check("surface: blit fully outside draws nothing", outside)

    // Blit within one surface, overlapping, in both directions.
    let o = Surface(width: 6, height: 5)
    pattern(o, 0)
    o.blit(from: o, src: Rect(0, 0, 4, 3), to: Point(1, 1))
    let down = surfaceIs(o) { x, y in
        Rect(1, 1, 4, 3).contains(Point(x, y)) ? UInt32((y - 1) * 100 + x - 1) : UInt32(y * 100 + x) }
    pattern(o, 0)
    o.blit(from: o, src: Rect(1, 1, 5, 4), to: Point(0, 0))
    let up = surfaceIs(o) { x, y in
        Rect(0, 0, 5, 4).contains(Point(x, y)) ? UInt32((y + 1) * 100 + x + 1) : UInt32(y * 100 + x) }
    pattern(o, 0)
    o.blit(from: o, src: Rect(0, 2, 5, 1), to: Point(1, 2))
    let right = surfaceIs(o) { x, y in
        y == 2 && x >= 1 ? UInt32(200 + x - 1) : UInt32(y * 100 + x) }
    t.check("surface: overlapping self-blit (down/up/right)", down && up && right)

    // Glyphs: opaque and transparent, clipped at every edge.
    if let font = display?.font ?? PSFFont(font_data(), size: Int(font_psf_size)) {
        let g = font.glyph(0x41) // 'A'
        let gs = Surface(width: 12, height: 20, color: bg)
        var glyphsOK = true
        for p in [Point(2, 2), Point(-3, -5), Point(7, 9), Point(-6, 10), Point(9, -12)] {
            gs.fill(bg)
            gs.drawGlyph(g, font: font, at: p, fg: fg, bg: 0x22)
            let ok = surfaceIs(gs) { x, y in
                let gx = x - p.x, gy = y - p.y
                guard gx >= 0, gx < 8, gy >= 0, gy < 16 else { return bg }
                return glyphBit(font, g, gx, gy) ? fg : 0x22
            }
            if !ok { glyphsOK = false }
        }
        t.check("surface: drawGlyph clipped at every edge", glyphsOK)
        gs.fill(bg)
        gs.drawGlyph(codepoint: 0x41, font: font, at: Point(1, 1), fg: fg, bg: nil)
        t.check("surface: transparent glyph background", surfaceIs(gs) { x, y in
            let gx = x - 1, gy = y - 1
            return gx >= 0 && gx < 8 && gy >= 0 && gy < 16 && glyphBit(font, g, gx, gy) ? fg : bg })

        let ts = Surface(width: 20, height: 16, color: bg)
        let end = ts.drawText("Hi\u{2500}", font: font, at: Point(-4, 0), fg: fg, bg: 0x22)
        let gH = font.glyph(0x48), gi = font.glyph(0x69), gl = font.glyph(0x2500)
        t.check("surface: drawText advances by cells", end == Point(20, 0) && textCells("Hi\u{2500}") == 3
                && font.textWidth("abcd") == 32)
        t.check("surface: drawText pixels", surfaceIs(ts) { x, y in
            let px = x + 4, cell = px / 8, gx = px % 8
            let gl = cell == 0 ? gH : cell == 1 ? gi : gl
            return glyphBit(font, gl, gx, y) ? fg : 0x22 })

        // ConsoleView: a 4x2 console drawn at an offset in a small surface.
        let c = Console(cols: 4, rows: 2)
        c.write("ab\r\ncd")
        var palette = InlineArray<16, UInt32>(repeating: 0)
        for i in 0..<16 { palette[i] = 0x100 + UInt32(i) }
        let view = ConsoleView(font: font, palette: palette)
        let cs = Surface(width: 40, height: 40, color: bg)
        let at = Point(3, 2)
        func consolePixel(_ x: Int, _ y: Int, cursor: (Int, Int)) -> UInt32 {
            let cx = x - at.x, cy = y - at.y
            guard cx >= 0, cx < 32, cy >= 0, cy < 32 else { return bg }
            let row = cy / 16, col = cx / 8
            let cell = c.cell(row, col)
            var f = palette[Int(cell.fg)], b = palette[Int(cell.bg)]
            if (row, col) == cursor { swap(&f, &b) }
            return glyphBit(font, font.glyph(cell.ch), cx % 8, cy % 16) ? f : b
        }
        var rects: [Rect] = []
        rects.reserveCapacity(8)
        view.render(c, into: cs, at: at) { rects.append($0) }
        t.check("consoleview: renders cells and inverted cursor",
                surfaceIs(cs) { consolePixel($0, $1, cursor: (1, 2)) })
        t.check("consoleview: reports each row, clears dirty", rects == [Rect(3, 2, 32, 16), Rect(3, 18, 32, 16)]
                && !c.dirty[0] && !c.dirty[1])
        t.check("consoleview: nothing dirty, nothing drawn", view.render(c, into: cs, at: at).isEmpty)
        c.write("\u{1B}[1;4Hz")
        let damage = view.render(c, into: cs, at: at)
        t.check("consoleview: only changed and cursor rows",
                damage == Rect(3, 2, 32, 32) && surfaceIs(cs) { consolePixel($0, $1, cursor: (0, 3)) })
        c.write("\u{1B}[1;1H")
        t.check("consoleview: cursor move repaints its row", view.render(c, into: cs, at: at) == Rect(3, 2, 32, 16))
        for r in 0..<c.rows { c.dirty[r] = true }
        cs.fill(bg)
        var clipped = Rect.empty
        cs.withClip(Rect(5, 0, 100, 20)) { clipped = view.render(c, into: cs, at: Point(-4, -10)) }
        t.check("consoleview: clipped, negative origin", clipped == Rect(5, 0, 23, 20) && surfaceIs(cs) { x, y in
            guard x >= 5, y < 20, x < 28 else { return bg }
            let cx = x + 4, cy = y + 10, row = cy / 16, col = cx / 8
            let cell = c.cell(row, col)
            var f = palette[Int(cell.fg)], b = palette[Int(cell.bg)]
            if row == 0 && col == 0 { swap(&f, &b) }
            return glyphBit(font, font.glyph(cell.ch), cx % 8, cy % 16) ? f : b })

        // Primitives don't allocate.
        let before = HeapUsage()
        for _ in 0..<10 {
            cs.fill(Rect(-3, -3, 50, 7), fg)
            cs.frame(Rect(1, 1, 30, 30), bg)
            cs.blit(from: cs, src: Rect(0, 0, 20, 20), to: Point(5, 5))
            cs.drawText("hello", font: font, at: Point(-3, 30), fg: fg, bg: nil)
            cs.withClip(Rect(0, 0, 10, 10)) { cs.drawGlyph(codepoint: 0x2500, font: font, at: Point(2, 2), fg: fg, bg: bg) }
            c.write("x")
            view.render(c, into: cs, at: at)
        }
        t.check("surface: primitives don't allocate", HeapUsage() == before)
    }

    // Masked 1-bit sprites.
    let sp = Sprite(art: testSpriteArt)
    t.check("sprite: parsed", sp.width == 3 && sp.height == 2 && sp.at(0, 0) == 1 && sp.at(1, 0) == 2
            && sp.at(2, 0) == 0 && sp.at(0, 1) == 0 && sp.at(2, 1) == 1)
    let ss = Surface(width: 4, height: 3, color: bg)
    var spritesOK = true
    for p in [Point(0, 0), Point(-1, -1), Point(2, 2), Point(3, -1), Point(-2, 2)] {
        ss.fill(bg)
        ss.drawSprite(sp, at: p, ink: 0xAA, paper: 0xBB)
        if !surfaceIs(ss, { x, y in
            let v = sp.at(x - p.x, y - p.y)
            return v == 1 ? 0xAA : v == 2 ? 0xBB : bg }) { spritesOK = false }
    }
    t.check("sprite: masked blit clipped at every edge", spritesOK)
    let arrow = Sprite(art: cursorArt)
    t.check("sprite: mouse cursor art", arrow.width == 11 && arrow.height == 17 && arrow.at(0, 4) == 1
            && arrow.at(2, 4) == 2 && arrow.at(4, 4) == 1 && arrow.at(5, 4) == 0 && arrow.at(6, 16) == 1)
}
