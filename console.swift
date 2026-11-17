// Phase E: graphical text console.
//
// - Console: the model. A cols x rows grid of Cells (codepoint + colours) is
//   the source of truth, plus a cursor, a UTF-8 decoder and a small ANSI
//   escape parser. It knows nothing about pixels, so the selftests drive it
//   off-screen on a tiny grid.
// - PSFFont: the PSF1 font embedded by font.S, plus a Unicode -> glyph map
//   built from the font's Unicode table.
// - Display: renders the dirty rows of a Console into a heap back buffer and
//   copies just those rows to the framebuffer. It never reads the framebuffer.
//
// Output path: putc (serial.swift) mirrors every byte to consoleWrite, which
// only updates the grid and marks rows dirty. Pixels are drawn by
// consoleFlush, called when getc is about to wait for input (so typed
// characters echo promptly) and before the machine halts.
//
// Console.write must not allocate: putc is called from the allocator's error
// paths and from exception reports. Only init allocates.
//
// The framebuffer is at an HHDM address (0xffff8000...). It is held only as a
// raw UnsafeMutablePointer<UInt32> (no Swift object lives there; pointers
// have no spare bits, so storing one in a class or Optional is fine; see the
// "HHDM pointer" selftests).

/// One character cell: a Unicode scalar and palette indices (0-15).
struct Cell: Equatable {
    var ch: UInt32
    var fg: UInt8
    var bg: UInt8
}

let consoleDefaultFG: UInt8 = 7 // light grey
let consoleDefaultBG: UInt8 = 0 // black

/// The 16 ANSI colours as 0xRRGGBB (VGA palette).
func ansiColor(_ index: Int) -> UInt32 {
    switch index & 15 {
    case 0: return 0x000000
    case 1: return 0xAA0000
    case 2: return 0x00AA00
    case 3: return 0xAA5500
    case 4: return 0x0000AA
    case 5: return 0xAA00AA
    case 6: return 0x00AAAA
    case 7: return 0xAAAAAA
    case 8: return 0x555555
    case 9: return 0xFF5555
    case 10: return 0x55FF55
    case 11: return 0xFFFF55
    case 12: return 0x5555FF
    case 13: return 0xFF55FF
    case 14: return 0x55FFFF
    default: return 0xFFFFFF
    }
}

// MARK: Console model

final class Console {
    enum EscapeState { case ground, escape, csi }

    let cols: Int
    let rows: Int
    /// Row-major grid, cols * rows.
    var cells: [Cell]
    /// Rows changed since the last flush.
    var dirty: [Bool]
    /// Cursor. `col == cols` means a wrap is pending: the next printable
    /// character goes to the start of the next line (VT100 deferred wrap), so
    /// a line of exactly `cols` characters followed by CR LF has no blank line.
    var row = 0
    var col = 0
    /// SGR state.
    var fg = consoleDefaultFG
    var bg = consoleDefaultBG
    var bold = false
    /// Lines scrolled off the top since creation.
    var scrollCount = 0

    // UTF-8 decoder: continuation bytes still expected, value so far, and the
    // smallest value valid for this sequence length (to reject overlongs).
    var utf8Need = 0
    var utf8Value: UInt32 = 0
    var utf8Min: UInt32 = 0

    // ANSI parser.
    var escape = EscapeState.ground
    var params = InlineArray<8, Int>(repeating: 0)
    var paramCount = 0

    init(cols: Int, rows: Int) {
        self.cols = max(cols, 1)
        self.rows = max(rows, 1)
        cells = Array(repeating: Cell(ch: 0x20, fg: consoleDefaultFG, bg: consoleDefaultBG),
                      count: self.cols * self.rows)
        dirty = Array(repeating: true, count: self.rows)
    }

    var blank: Cell { Cell(ch: 0x20, fg: effectiveFG, bg: bg) }
    var effectiveFG: UInt8 { bold && fg < 8 ? fg + 8 : fg }

    func cell(_ row: Int, _ col: Int) -> Cell { cells[row * cols + col] }

    /// Feed one byte of UTF-8 text with control characters and ANSI escapes.
    func write(_ byte: UInt8) {
        if utf8Need > 0 {
            if byte & 0xC0 == 0x80 {
                utf8Value = utf8Value << 6 | UInt32(byte & 0x3F)
                utf8Need -= 1
                if utf8Need == 0 {
                    let v = utf8Value
                    let bad = v < utf8Min || v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF)
                    put(bad ? 0xFFFD : v)
                }
                return
            }
            utf8Need = 0
            put(0xFFFD) // truncated sequence; this byte starts something new
        }
        if byte < 0x80 { ascii(byte); return }
        escape = .ground // non-ASCII aborts an escape sequence
        switch byte {
        case 0xC2...0xDF: startSequence(1, UInt32(byte & 0x1F), 0x80)
        case 0xE0...0xEF: startSequence(2, UInt32(byte & 0x0F), 0x800)
        case 0xF0...0xF4: startSequence(3, UInt32(byte & 0x07), 0x10000)
        default: put(0xFFFD) // stray continuation, C0/C1, F5-FF
        }
    }

    func write(_ s: StaticString) {
        s.withUTF8Buffer { for b in $0 { write(b) } }
    }

    func startSequence(_ need: Int, _ value: UInt32, _ minimum: UInt32) {
        utf8Need = need
        utf8Value = value
        utf8Min = minimum
    }

    func ascii(_ b: UInt8) {
        switch escape {
        case .escape:
            escape = b == 0x5B ? .csi : .ground // only CSI ("ESC [") is supported
            paramCount = 0
            params[0] = 0
            return
        case .csi:
            if csi(b) { return }
        case .ground:
            break
        }
        switch b {
        case 0x1B: escape = .escape
        case 0x0A: newLine() // LF also returns to column 0 (like onlcr)
        case 0x0D: col = 0
        case 0x08: if col > 0 { col -= 1 }
        case 0x09: col = min((col / 8 + 1) * 8, cols - 1)
        case 0x20..<0x7F: put(UInt32(b))
        default: break // other control characters and DEL
        }
    }

    /// One byte inside "ESC [". Returns false if the byte aborted the
    /// sequence and should be handled as ordinary input.
    func csi(_ b: UInt8) -> Bool {
        switch b {
        case 0x30...0x39:
            if paramCount == 0 { paramCount = 1; params[0] = 0 }
            let i = paramCount - 1
            params[i] = min(params[i] * 10 + Int(b - 0x30), 9999)
        case 0x3B: // ';'
            if paramCount == 0 { paramCount = 1; params[0] = 0 }
            if paramCount < params.count { params[paramCount] = 0; paramCount += 1 }
        case 0x20...0x2F, 0x3C...0x3F:
            break // intermediates and private markers ('?'): accepted, ignored
        case 0x40...0x7E:
            escape = .ground
            dispatch(b)
        default:
            escape = .ground
            return false
        }
        return true
    }

    /// Parameter `i`, with 0 or missing meaning `fallback`.
    func param(_ i: Int, _ fallback: Int) -> Int {
        i < paramCount && params[i] != 0 ? params[i] : fallback
    }

    func dispatch(_ final: UInt8) {
        switch final {
        case 0x6D: sgr() // m
        case 0x48, 0x66: // H, f: cursor position (1-based)
            row = min(param(0, 1), rows) - 1
            col = min(param(1, 1), cols) - 1
        case 0x41: row = max(row - param(0, 1), 0); col = min(col, cols - 1) // A
        case 0x42: row = min(row + param(0, 1), rows - 1); col = min(col, cols - 1) // B
        case 0x43: col = min(col + param(0, 1), cols - 1) // C
        case 0x44: col = max(min(col, cols - 1) - param(0, 1), 0) // D
        case 0x4A: // J: erase in display
            let here = row * cols + min(col, cols - 1)
            switch param(0, 0) {
            case 0: clear(from: here, to: cells.count)
            case 1: clear(from: 0, to: here + 1)
            default: clear(from: 0, to: cells.count)
            }
        case 0x4B: // K: erase in line
            let start = row * cols, here = start + min(col, cols - 1)
            switch param(0, 0) {
            case 0: clear(from: here, to: start + cols)
            case 1: clear(from: start, to: here + 1)
            default: clear(from: start, to: start + cols)
            }
        default: break
        }
    }

    func sgr() {
        if paramCount == 0 { resetAttributes(); return }
        var i = 0
        while i < paramCount {
            let p = params[i]
            switch p {
            case 0: resetAttributes()
            case 1: bold = true
            case 22: bold = false
            case 30...37: fg = UInt8(p - 30)
            case 39: fg = consoleDefaultFG
            case 40...47: bg = UInt8(p - 40)
            case 49: bg = consoleDefaultBG
            case 90...97: fg = UInt8(p - 90 + 8)
            case 100...107: bg = UInt8(p - 100 + 8)
            case 38, 48: // 38;5;n / 38;2;r;g;b: only n < 16 is honoured
                if i + 2 < paramCount && params[i + 1] == 5 {
                    if params[i + 2] < 16 {
                        if p == 38 { fg = UInt8(params[i + 2]) } else { bg = UInt8(params[i + 2]) }
                    }
                    i += 2
                } else if i + 1 < paramCount && params[i + 1] == 2 {
                    i += 4
                }
            default: break
            }
            i += 1
        }
    }

    func resetAttributes() {
        fg = consoleDefaultFG
        bg = consoleDefaultBG
        bold = false
    }

    func clear(from: Int, to: Int) {
        guard from < to else { return }
        let b = blank
        for i in from..<to { cells[i] = b }
        for r in (from / cols)...((to - 1) / cols) { dirty[r] = true }
    }

    /// Store a printable codepoint at the cursor and advance.
    func put(_ cp: UInt32) {
        if col >= cols { newLine() }
        cells[row * cols + col] = Cell(ch: cp, fg: effectiveFG, bg: bg)
        dirty[row] = true
        col += 1
    }

    func newLine() {
        col = 0
        if row + 1 < rows { row += 1 } else { scroll() }
    }

    /// Shift the grid up one row and blank the bottom row.
    func scroll() {
        let n = (rows - 1) * cols
        for i in 0..<n { cells[i] = cells[i + cols] }
        let b = blank
        for i in n..<cells.count { cells[i] = b }
        for r in 0..<rows { dirty[r] = true }
        scrollCount += 1
    }
}

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

// MARK: Framebuffer display

final class Display {
    /// Framebuffer (HHDM address), written only, never read.
    let fb: UnsafeMutablePointer<UInt32>
    /// Framebuffer row length in pixels (pitch / 4).
    let fbStride: Int
    let width: Int
    let height: Int
    /// Heap back buffer, width * height pixels, rows packed.
    let back: UnsafeMutablePointer<UInt32>
    let font: PSFFont
    /// The ANSI palette in the framebuffer's pixel format.
    var palette = InlineArray<16, UInt32>(repeating: 0)
    /// Where the cursor was last drawn (an inverted cell).
    var cursorRow = -1
    var cursorCol = -1
    var showCursor = true
    var flushes = 0

    /// Needs a 32-bpp RGB framebuffer with <= 8-bit channels; else nil.
    init?(_ f: limine_framebuffer, font: PSFFont) {
        guard let address = f.address, f.bpp == 32,
              f.memory_model == UInt8(LIMINE_FRAMEBUFFER_RGB),
              f.red_mask_size <= 8, f.green_mask_size <= 8, f.blue_mask_size <= 8,
              f.pitch % 4 == 0, f.pitch / 4 >= f.width,
              f.width >= UInt64(font.width), f.height >= UInt64(font.height),
              f.width <= 16384, f.height <= 16384 else { return nil }
        fb = address.assumingMemoryBound(to: UInt32.self)
        fbStride = Int(f.pitch / 4)
        width = Int(f.width)
        height = Int(f.height)
        self.font = font
        back = UnsafeMutablePointer<UInt32>.allocate(capacity: width * height)
        func channel(_ v: UInt32, _ size: UInt8, _ shift: UInt8) -> UInt32 {
            ((v & 0xFF) >> UInt32(8 - size)) << UInt32(shift)
        }
        for i in 0..<16 {
            let c = ansiColor(i)
            palette[i] = channel(c >> 16, f.red_mask_size, f.red_mask_shift)
                | channel(c >> 8, f.green_mask_size, f.green_mask_shift)
                | channel(c, f.blue_mask_size, f.blue_mask_shift)
        }
        // Clear everything once, including the margin no cell covers.
        back.initialize(repeating: palette[Int(consoleDefaultBG)], count: width * height)
        copyRows(0, height)
    }

    var cols: Int { width / font.width }
    var rows: Int { height / font.height }

    /// Draw glyph `glyph` into the back buffer at text cell (col, row).
    func drawGlyph(col: Int, row: Int, glyph: Int, fg: UInt32, bg: UInt32) {
        var src = font.bitmap(glyph)
        var dst = back + row * font.height * width + col * font.width
        for _ in 0..<font.height {
            let bits = src.pointee
            dst[0] = bits & 0x80 != 0 ? fg : bg
            dst[1] = bits & 0x40 != 0 ? fg : bg
            dst[2] = bits & 0x20 != 0 ? fg : bg
            dst[3] = bits & 0x10 != 0 ? fg : bg
            dst[4] = bits & 0x08 != 0 ? fg : bg
            dst[5] = bits & 0x04 != 0 ? fg : bg
            dst[6] = bits & 0x02 != 0 ? fg : bg
            dst[7] = bits & 0x01 != 0 ? fg : bg
            src += 1
            dst += width
        }
    }

    /// Copy pixel rows [y, y + count) from the back buffer to the framebuffer.
    func copyRows(_ y: Int, _ count: Int) {
        for line in y..<(y + count) {
            let s = back + line * width
            let d = fb + line * fbStride
            var x = 0
            while x < width { d[x] = s[x]; x += 1 }
        }
    }

    /// Render the console's dirty rows (and the cursor's old and new rows)
    /// into the back buffer, then copy those rows to the framebuffer.
    func flush(_ c: Console) {
        let cr = min(c.row, c.rows - 1), cc = min(c.col, c.cols - 1)
        if cr != cursorRow || cc != cursorCol {
            if cursorRow >= 0 && cursorRow < c.rows { c.dirty[cursorRow] = true }
            c.dirty[cr] = true
        }
        let visibleRows = min(c.rows, rows), visibleCols = min(c.cols, cols)
        for r in 0..<visibleRows where c.dirty[r] {
            for col in 0..<visibleCols {
                let cell = c.cells[r * c.cols + col]
                var fg = palette[Int(cell.fg & 15)], bg = palette[Int(cell.bg & 15)]
                if showCursor && r == cr && col == cc { swap(&fg, &bg) }
                drawGlyph(col: col, row: r, glyph: font.glyph(cell.ch), fg: fg, bg: bg)
            }
            copyRows(r * font.height, font.height)
            c.dirty[r] = false
        }
        cursorRow = cr
        cursorCol = cc
        flushes += 1
    }
}

// MARK: Kernel console

var console: Console? = nil
var display: Display? = nil

/// Bytes written before the console exists (before the heap is up), replayed
/// onto the screen by consoleInit so the whole boot log is visible.
var earlyLog = InlineArray<1024, UInt8>(repeating: 0)
var earlyLogCount = 0

/// Called by putc for every byte also sent to serial. Never allocates.
func consoleWrite(_ byte: UInt8) {
    if let c = console {
        c.write(byte)
    } else if earlyLogCount < earlyLog.count {
        earlyLog[earlyLogCount] = byte
        earlyLogCount += 1
    }
}

/// Push pending changes to the screen.
func consoleFlush() {
    if let c = console, let d = display { d.flush(c) }
}

/// Set up the framebuffer console. Needs the heap (pmm initialised).
func consoleInit() {
    guard let resp = framebuffer_request.response, resp.pointee.framebuffer_count > 0,
          let fbp = resp.pointee.framebuffers[0] else {
        puts("console: no framebuffer, serial only\n")
        return
    }
    guard let font = PSFFont(font_data(), size: Int(font_psf_size)) else {
        puts("console: bad PSF font, serial only\n")
        return
    }
    guard let d = Display(fbp.pointee, font: font) else {
        puts("console: unsupported framebuffer (need 32 bpp RGB), serial only\n")
        return
    }
    let c = Console(cols: d.cols, rows: d.rows)
    for i in 0..<earlyLogCount { c.write(earlyLog[i]) }
    display = d
    console = c
    print("console: \(c.cols)x\(c.rows) cells on a \(d.width)x\(d.height) framebuffer")
    consoleFlush()
}
