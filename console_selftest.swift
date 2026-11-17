// Phase E selftests: the console model on small off-screen grids, the PSF
// font, and the framebuffer display (called from runSelfTests).

/// Row `r` of `c` shows exactly `text` (ASCII), padded with blanks.
func rowIs(_ c: Console, _ r: Int, _ text: StaticString) -> Bool {
    text.withUTF8Buffer { buf in
        guard buf.count <= c.cols else { return false }
        for i in 0..<c.cols where c.cell(r, i).ch != (i < buf.count ? UInt32(buf[i]) : 0x20) {
            return false
        }
        return true
    }
}

func feed(_ c: Console, _ bytes: [UInt8]) {
    for b in bytes { c.write(b) }
}

/// A class field holding a raw framebuffer (HHDM) pointer.
final class PointerBox {
    var p: UnsafeMutablePointer<UInt32>?
    init(_ p: UnsafeMutablePointer<UInt32>?) { self.p = p }
}

enum PointerChoice {
    case front(UnsafeMutablePointer<UInt32>)
    case back(UnsafeMutablePointer<UInt32>)
    case none
}

@inline(never)
func choose(_ p: UnsafeMutablePointer<UInt32>, _ k: Int) -> PointerChoice {
    k == 0 ? .front(p) : k == 1 ? .back(p) : .none
}

func consoleTests(_ t: inout SelfTest) {
    // Text, CR/LF, cursor.
    let c = Console(cols: 10, rows: 3)
    c.write("ab\r\ncd")
    t.check("console: text and CR LF", rowIs(c, 0, "ab") && rowIs(c, 1, "cd") && c.row == 1 && c.col == 2)
    c.write("\rX")
    t.check("console: CR returns to column 0", rowIs(c, 1, "Xd") && c.col == 1)

    // Scrolling past the bottom.
    c.write("\n1\n2\n3")
    t.check("console: scroll past bottom", rowIs(c, 0, "1") && rowIs(c, 1, "2") && rowIs(c, 2, "3")
            && c.row == 2 && c.scrollCount == 2)
    t.check("console: scroll dirties all rows", c.dirty[0] && c.dirty[1] && c.dirty[2])

    // Backspace and the shell's "\b \b" erase.
    let b = Console(cols: 10, rows: 2)
    b.write("abc\u{8} \u{8}")
    t.check("console: \\b \\b erases", rowIs(b, 0, "ab") && b.col == 2)
    b.write("\r\u{8}")
    t.check("console: backspace stops at column 0", b.col == 0)

    // Tab, deferred wrap.
    let w = Console(cols: 10, rows: 3)
    w.write("a\tb")
    t.check("console: tab to column 8", w.cell(0, 8).ch == 0x62 && w.col == 9)
    w.write("\r\n0123456789")
    t.check("console: full line leaves wrap pending", w.row == 1 && w.col == 10)
    w.write("\r\nx")
    t.check("console: no blank line after full line", rowIs(w, 2, "x") && w.row == 2)
    w.write("\u{1B}[2;1H0123456789y")
    t.check("console: wrap on next character", rowIs(w, 2, "y") && w.col == 1)

    // ANSI erase and cursor positioning.
    let e = Console(cols: 10, rows: 3)
    e.write("hello\r\nworld")
    e.write("\u{1B}[2J")
    t.check("console: ESC[2J clears", rowIs(e, 0, "") && rowIs(e, 1, "") && e.row == 1 && e.col == 5)
    e.write("\u{1B}[H")
    t.check("console: ESC[H homes", e.row == 0 && e.col == 0)
    e.write("\u{1B}[3;4Hz")
    t.check("console: ESC[row;colH", e.cell(2, 3).ch == 0x7A && e.row == 2 && e.col == 4)
    e.write("\u{1B}[1;1Habcdef\u{1B}[1;3H\u{1B}[K")
    t.check("console: ESC[K clears to end of line", rowIs(e, 0, "ab") && e.col == 2)

    // SGR colour state.
    let s = Console(cols: 10, rows: 2)
    s.write("\u{1B}[31ma\u{1B}[1;32mb\u{1B}[0mc\u{1B}[44;93md\u{1B}[39;49me\u{1B}[1mf\u{1B}[mg\u{1B}[97;100mh")
    let fgs: [UInt8] = [1, 10, 7, 11, 7, 15, 7, 15]
    let bgs: [UInt8] = [0, 0, 0, 4, 0, 0, 0, 8]
    var colours = true
    for i in 0..<8 where s.cell(0, i).fg != fgs[i] || s.cell(0, i).bg != bgs[i] { colours = false }
    t.check("console: SGR 0/1/30-37/90-97/40-47/39/49", colours && rowIs(s, 0, "abcdefgh"))
    s.write("\u{1B}[0m\u{1B}[41m\u{1B}[2J")
    t.check("console: clear uses current background", s.cell(1, 9).bg == 1)
    s.write("\u{1B}[0m\u{1B}[?25l\u{1B}[1;1Hq")
    t.check("console: private CSI ignored", s.cell(0, 0).ch == 0x71)

    // UTF-8: 2, 3 and 4 bytes, invalid and truncated input.
    let u = Console(cols: 10, rows: 1)
    feed(u, [0xC3, 0xA9, 0xE2, 0x94, 0x80, 0xF0, 0x9F, 0x98, 0x80, 0xFF, 0xC3, 0x41, 0xC0, 0x80])
    let want: [UInt32] = [0xE9, 0x2500, 0x1F600, 0xFFFD, 0xFFFD, 0x41, 0xFFFD, 0xFFFD]
    var utf8 = true
    for i in 0..<want.count where u.cell(0, i).ch != want[i] { utf8 = false }
    t.check("console: UTF-8 decode", utf8 && u.col == want.count)

    // Font.
    let font = PSFFont(font_data(), size: Int(font_psf_size))
    t.check("font: PSF1 8x16, 512 glyphs", font?.height == 16 && font?.glyphCount == 512)
    if let font {
        t.check("font: ASCII maps to itself", font.glyph(0x41) == 0x41 && font.glyph(0x7E) == 0x7E)
        t.check("font: box drawing mapped", font.glyph(0x2500) != font.fallback
                && font.glyph(0x250C) != font.fallback)
        t.check("font: unmapped uses U+FFFD", font.glyph(0x1F600) == font.glyph(0xFFFD))
    }
    var bad: [UInt8] = [0x36, 0x05, 0, 16]
    t.check("font: bad magic rejected", bad.withUnsafeBufferPointer { PSFFont($0.baseAddress!, size: 4) } == nil)
    bad = [0x36, 0x04, 0, 16]
    t.check("font: truncated rejected", bad.withUnsafeBufferPointer { PSFFont($0.baseAddress!, size: 4) } == nil)

    // HHDM framebuffer pointers survive classes, Optionals and enums.
    if let d = display {
        let box = PointerBox(d.fb)
        var enumOK = true
        if case .front(let p) = choose(d.fb, 0) { enumOK = enumOK && p == d.fb } else { enumOK = false }
        if case .back(let p) = choose(d.fb, 1) { enumOK = enumOK && p == d.fb } else { enumOK = false }
        if case .none = choose(d.fb, 2) {} else { enumOK = false }
        t.check("HHDM pointer in class/Optional", box.p == d.fb && UInt(bitPattern: d.fb) >= 0xffff_8000_0000_0000)
        t.check("HHDM pointer in enum payload", enumOK)
    }

    // The live display: a full redraw, and the back buffer matches the model.
    if let con = console, let d = display {
        t.check("display: grid covers the framebuffer", con.cols == d.cols && con.rows == d.rows)
        for r in 0..<con.rows { con.dirty[r] = true }
        let start = ticks
        d.flush(con)
        var clean = true
        for r in 0..<con.rows where con.dirty[r] { clean = false }
        for _ in 0..<9 {
            for r in 0..<con.rows { con.dirty[r] = true }
            d.flush(con)
        }
        let elapsed = ticks - start
        puts("  10 full redraws: "); printDec(elapsed * 1000 / timerHz); puts(" ms\n")
        t.check("display: flush clears dirty rows", clean)
        // Cell (0, 0) holds a known glyph; its pixels in the back buffer must match.
        let cell = con.cell(0, 0)
        let bits = d.font.bitmap(d.font.glyph(cell.ch))
        var match = true
        for y in 0..<16 {
            for x in 0..<8 {
                let on = bits[y] & (0x80 >> UInt8(x)) != 0
                let px = d.back[y * d.width + x]
                let inverted = con.row == 0 && min(con.col, con.cols - 1) == 0
                if px != d.palette[Int(on != inverted ? cell.fg : cell.bg)] { match = false }
            }
        }
        t.check("display: back buffer glyph matches cell", match)
    }
}
