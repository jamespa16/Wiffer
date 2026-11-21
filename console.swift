// Phase E: graphical text console.
//
// - Console: the model. A cols x rows grid of Cells (codepoint + colours) is
//   the source of truth, plus a cursor, a UTF-8 decoder and a small ANSI
//   escape parser. It knows nothing about pixels, so the selftests drive it
//   off-screen on a tiny grid.
// - PSFFont: the PSF1 font embedded by font.S, plus a Unicode -> glyph map
//   built from the font's Unicode table.
// - Display: renders the dirty rows of a Console into a window layer of the
//   compositor (compositor.swift), which copies just the damaged rects to the
//   framebuffer. Nothing reads the framebuffer.
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

/// Row dirtiness with a bounded column span. Bool subscripting keeps full-row
/// invalidation explicit for resize, palette changes and callers editing cells.
struct ConsoleDirtyRows {
    let cols: Int
    var starts: [Int]
    var ends: [Int]
    init(cols: Int, rows: Int) {
        self.cols = cols
        starts = Array(repeating: 0, count: rows)
        ends = Array(repeating: cols, count: rows)
    }
    subscript(row: Int) -> Bool {
        get { starts[row] < ends[row] }
        set { starts[row] = newValue ? 0 : cols; ends[row] = newValue ? cols : 0 }
    }
    mutating func mark(_ row: Int, from: Int, to: Int) {
        starts[row] = min(starts[row], from)
        ends[row] = max(ends[row], to)
    }
}

final class Console {
    enum EscapeState { case ground, escape, csi }

    let cols: Int
    let rows: Int
    /// Row-major grid, cols * rows.
    var cells: [Cell]
    /// Rows changed since the last flush.
    var dirty: ConsoleDirtyRows
    /// Cursor. `col == cols` means a wrap is pending: the next printable
    /// character goes to the start of the next line (VT100 deferred wrap), so
    /// a line of exactly `cols` characters followed by CR LF has no blank line.
    var row = 0
    var col = 0
    /// What SGR 0/39/49 return to (the `color` command changes them).
    var defaultFG = consoleDefaultFG
    var defaultBG = consoleDefaultBG
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
        dirty = ConsoleDirtyRows(cols: self.cols, rows: self.rows)
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
            case 39: fg = defaultFG
            case 40...47: bg = UInt8(p - 40)
            case 49: bg = defaultBG
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
        fg = defaultFG
        bg = defaultBG
        bold = false
    }

    /// Change the default colours. Cells (and the current attributes) still
    /// in the old defaults take the new ones, so the screen recolours.
    func setDefaultColors(fg newFG: UInt8, bg newBG: UInt8) {
        for i in 0..<cells.count {
            if cells[i].fg == defaultFG { cells[i].fg = newFG }
            if cells[i].bg == defaultBG { cells[i].bg = newBG }
        }
        if fg == defaultFG { fg = newFG }
        if bg == defaultBG { bg = newBG }
        defaultFG = newFG
        defaultBG = newBG
        for r in 0..<rows { dirty[r] = true }
    }

    func clear(from: Int, to: Int) {
        guard from < to else { return }
        let b = blank
        for i in from..<to { cells[i] = b }
        for r in (from / cols)...((to - 1) / cols) {
            dirty.mark(r, from: max(from - r * cols, 0), to: min(to - r * cols, cols))
        }
    }

    /// Store a printable codepoint at the cursor and advance.
    func put(_ cp: UInt32) {
        if col >= cols { newLine() }
        cells[row * cols + col] = Cell(ch: cp, fg: effectiveFG, bg: bg)
        dirty.mark(row, from: col, to: col + 1)
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

// MARK: Framebuffer display

/// The boot console on the compositor (Phase J). Layers, bottom to top: the
/// desktop pattern, a "window" holding the G4 frame and the console (rendered
/// by ConsoleView into the window's own surface), the status bar, and (added
/// by mouse.swift) the mouse cursor. Rendering only touches those surfaces
/// and damages what changed; flush() composites, which is the only thing
/// that writes the framebuffer.
final class Display {
    /// Framebuffer (HHDM address), written only, never read.
    let fb: UnsafeMutablePointer<UInt32>
    /// Framebuffer row length in pixels (pitch / 4).
    let fbStride: Int
    let width: Int
    let height: Int
    /// The framebuffer wrapped as a (write-only) surface: the compositor's front.
    let front: Surface
    let compositor: Compositor
    /// The compositor's screen-sized back buffer.
    var back: Surface { compositor.back }
    let desktop: PatternLayer
    /// Chrome rows from `windowRow` down (the frame) and the console.
    let window: SurfaceLayer
    /// Chrome row `statusRow`; hidden without a status bar.
    let status: SurfaceLayer
    let font: PSFFont
    /// Draws the console into `window`; holds the palette and text cursor.
    let view: ConsoleView
    /// The ANSI palette in the framebuffer's pixel format.
    var palette: InlineArray<16, UInt32> { view.palette }
    var showCursor: Bool {
        get { view.showCursor }
        set { view.showCursor = newValue }
    }
    var flushes = 0
    /// Channel sizes and shifts (red, green, blue), for color(_:).
    let channels: InlineArray<6, UInt8>

    /// Layout (G4): where the console's grid sits on screen, in cells, and
    /// the "chrome" around it: a screen-sized grid for the status bar and the
    /// window frame. Chrome cells under the console viewport are unused.
    var originRow = 0
    var originCol = 0
    var viewRows = 0
    var viewCols = 0
    /// Screen row of the status bar, or -1.
    var statusRow = -1
    /// Screen row where the window layer starts.
    var windowRow = 0
    var chrome: [Cell]
    var chromeDirty: [Bool]

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
        var ch = InlineArray<6, UInt8>(repeating: 0)
        ch[0] = f.red_mask_size; ch[1] = f.red_mask_shift
        ch[2] = f.green_mask_size; ch[3] = f.green_mask_shift
        ch[4] = f.blue_mask_size; ch[5] = f.blue_mask_shift
        channels = ch
        let screenCols = width / font.width, screenRows = height / font.height
        chrome = Array(repeating: Cell(ch: 0x20, fg: consoleDefaultFG, bg: consoleDefaultBG),
                       count: screenCols * screenRows)
        chromeDirty = Array(repeating: false, count: screenRows)
        viewRows = screenRows
        viewCols = screenCols
        var palette = InlineArray<16, UInt32>(repeating: 0)
        for i in 0..<16 { palette[i] = Display.convert(ansiColor(i), ch) }
        view = ConsoleView(font: font, palette: palette)
        front = Surface(wrapping: fb, width: width, height: height, stride: fbStride)
        compositor = Compositor(front: front)
        desktop = PatternLayer(frame: Rect(0, 0, width, height), color: Display.convert(desktopColor, ch),
                               dotColor: Display.convert(desktopDotColor, ch))
        let bg = palette[Int(consoleDefaultBG)]
        window = SurfaceLayer(surface: Surface(width: screenCols * font.width, height: screenRows * font.height,
                                               color: bg), at: .zero, band: .windows)
        status = SurfaceLayer(surface: Surface(width: width, height: font.height, color: bg), at: .zero, band: .panel)
        compositor.add(desktop)
        compositor.add(window)
        compositor.add(status)
        compositor.setVisible(status, false)
        compositor.composite()
    }

    /// 0xRRGGBB in a pixel format given as (size, shift) for red, green, blue.
    static func convert(_ c: UInt32, _ ch: InlineArray<6, UInt8>) -> UInt32 {
        func channel(_ v: UInt32, _ size: UInt8, _ shift: UInt8) -> UInt32 {
            ((v & 0xFF) >> UInt32(8 - size)) << UInt32(shift)
        }
        return channel(c >> 16, ch[0], ch[1]) | channel(c >> 8, ch[2], ch[3]) | channel(c, ch[4], ch[5])
    }

    /// 0xRRGGBB in the framebuffer's pixel format.
    func color(_ rgb: UInt32) -> UInt32 { Display.convert(rgb, channels) }

    var cols: Int { width / font.width }
    var rows: Int { height / font.height }

    /// Draw chrome cell (col, row) (screen cells) into the layer holding that
    /// row: the status bar or the window.
    func drawChrome(col: Int, row: Int) {
        let cell = chrome[row * cols + col]
        let target = row == statusRow ? status.surface : window.surface
        let y = row == statusRow ? 0 : (row - windowRow) * font.height
        target.drawGlyph(font.glyph(cell.ch), font: font, at: Point(col * font.width, y),
                         fg: palette[Int(cell.fg & 15)], bg: palette[Int(cell.bg & 15)])
    }

    // MARK: Layout

    /// Reserve the top row for a status bar (if `statusBar`) and, if `title`
    /// is given, frame the rest as a window with that title. Returns the
    /// console size that fits in the remaining viewport. Call before drawing.
    func setLayout(statusBar: Bool, title: String?) -> (cols: Int, rows: Int) {
        var top = 0
        if statusBar && rows >= 2 {
            statusRow = 0
            top = 1
            for col in 0..<cols { chrome[col] = Cell(ch: 0x20, fg: statusFG, bg: statusBG) }
            chromeDirty[0] = true
            // Past the last cell (a width that isn't a multiple of 8): bar colour.
            status.surface.fill(palette[Int(statusBG)])
        }
        compositor.setVisible(status, statusRow >= 0)
        windowRow = top
        compositor.setSurface(window, Surface(width: cols * font.width, height: (rows - top) * font.height,
                                              color: palette[Int(consoleDefaultBG)]))
        compositor.move(window, to: Point(0, top * font.height))
        originRow = top
        originCol = 0
        viewRows = rows - top
        viewCols = cols
        if let title, cols >= 8, rows - top >= 4 {
            let right = cols - 1, bottom = rows - 1
            func frame(_ r: Int, _ c: Int, _ ch: UInt32) {
                chrome[r * cols + c] = Cell(ch: ch, fg: frameFG, bg: consoleDefaultBG)
            }
            frame(top, 0, 0x250C); frame(top, right, 0x2510) // corners
            frame(bottom, 0, 0x2514); frame(bottom, right, 0x2518)
            for c in 1..<right { frame(top, c, 0x2500); frame(bottom, c, 0x2500) }
            for r in (top + 1)..<bottom { frame(r, 0, 0x2502); frame(r, right, 0x2502) }
            var col = 2
            for s in " \(title) ".unicodeScalars where col < right - 1 {
                chrome[top * cols + col] = Cell(ch: s.value, fg: titleFG, bg: consoleDefaultBG)
                col += 1
            }
            for r in top...bottom { chromeDirty[r] = true }
            originRow = top + 1
            originCol = 1
            viewRows = rows - top - 2
            viewCols = cols - 2
        }
        return (viewCols, viewRows)
    }

    let statusFG: UInt8 = 0, statusBG: UInt8 = 6 // black on cyan
    let alertFG: UInt8 = 15, alertBG: UInt8 = 1 // white on red
    let frameFG: UInt8 = 6, titleFG: UInt8 = 15

    /// Put `text` in the status bar (padded with blanks). Marks the row dirty
    /// only if something changed.
    func setStatus(_ text: String) {
        guard statusRow >= 0 else { return }
        let base = statusRow * cols
        var col = 0
        var changed = false
        for s in text.unicodeScalars where col < cols {
            let cell = Cell(ch: s.value, fg: statusFG, bg: statusBG)
            if chrome[base + col] != cell { chrome[base + col] = cell; changed = true }
            col += 1
        }
        while col < cols {
            let cell = Cell(ch: 0x20, fg: statusFG, bg: statusBG)
            if chrome[base + col] != cell { chrome[base + col] = cell; changed = true }
            col += 1
        }
        if changed { chromeDirty[statusRow] = true }
    }

    /// Status bar alert in white on red. ASCII only; never allocates, so an
    /// exception report can use it.
    func setStatusAlert(_ text: StaticString) {
        guard statusRow >= 0 else { return }
        let base = statusRow * cols
        text.withUTF8Buffer { buf in
            for col in 0..<cols {
                let ch: UInt32 = col < buf.count ? UInt32(buf[col]) : 0x20
                chrome[base + col] = Cell(ch: ch, fg: alertFG, bg: alertBG)
            }
        }
        status.surface.fill(Rect(cols * font.width, 0, width, font.height), palette[Int(alertBG)])
        chromeDirty[statusRow] = true
    }

    func inViewport(_ r: Int, _ c: Int) -> Bool {
        r >= originRow && r < originRow + viewRows && c >= originCol && c < originCol + viewCols
    }

    /// Render the chrome's and the console's dirty rows (and the cursor's old
    /// and new rows) into their layers, damage them, and composite. Never
    /// allocates.
    func flush(_ c: Console) {
        if let wm = windowManager, wm.compositor === compositor {
            // Phase K: the console is a window; the WM draws it.
            wm.render()
            compositor.composite()
            flushes += 1
            return
        }
        let fw = font.width, fh = font.height
        for r in 0..<rows where chromeDirty[r] {
            chromeDirty[r] = false
            for col in 0..<cols where !inViewport(r, col) { drawChrome(col: col, row: r) }
            compositor.damage(Rect(0, r * fh, width, fh))
        }
        let ws = window.surface
        let viewport = Rect(originCol * fw, (originRow - windowRow) * fh, viewCols * fw, viewRows * fh)
        ws.withClip(viewport) {
            view.render(c, into: ws, at: viewport.origin) { compositor.damage(window, local: $0) }
        }
        compositor.composite()
        flushes += 1
    }
}

/// The desktop background: dark blue-grey with a lighter dot every 8 px.
let desktopColor: UInt32 = 0x1C3A4A
let desktopDotColor: UInt32 = 0x2E5A70

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
    // G4: a status bar on the top row, and the console in a titled window.
    let size = d.setLayout(statusBar: true, title: "Wiffer shell")
    let c = Console(cols: size.cols, rows: size.rows)
    for i in 0..<earlyLogCount { c.write(earlyLog[i]) }
    display = d
    compositor = d.compositor
    console = c
    print("console: \(c.cols)x\(c.rows) cells at row \(d.originRow) col \(d.originCol) of \(d.cols)x\(d.rows), status bar on row \(d.statusRow), on a \(d.width)x\(d.height) framebuffer")
    statusBarRefresh()
    consoleFlush()
}

// MARK: Status bar

var statusNextTick: UInt64 = 0

/// Redraw the status bar text (uptime, memory) at most every half second.
/// Called from the main loop (readKey's idle wait), never from an IRQ
/// handler: it allocates.
func statusBarRefresh() {
    if let wm = windowManager {
        guard ticks >= statusNextTick else { return }
        statusNextTick = ticks + timerHz / 2
        let free = (pmm.freeFrames * frameSize) >> 20
        wm.refreshStatus("up \(uptimeClock())  free \(free) MiB  heap \(heap.bytesInUse / 1024) KiB")
        return
    }
    guard let d = display, d.statusRow >= 0, ticks >= statusNextTick else { return }
    let t = ticks
    statusNextTick = t + timerHz / 2
    let clock = uptimeClock()
    let free = (pmm.freeFrames * frameSize) >> 20, total = (pmm.totalFrames * frameSize) >> 20
    d.setStatus(" Wiffer  \u{2502}  up \(clock)  \u{2502}  free \(free) of \(total) MiB (\(pmm.freeFrames) frames)  \u{2502}  heap \(heap.bytesInUse / 1024) KiB in \(heap.liveCount) blocks")
}

/// Time since boot as H:MM:SS.
func uptimeClock() -> String {
    let s = ticks / timerHz
    let m = s / 60 % 60, sec = s % 60
    return "\(s / 3600):\(m < 10 ? "0" : "")\(m):\(sec < 10 ? "0" : "")\(sec)"
}

/// Show an alert in the status bar now. Never allocates.
func statusBarAlert(_ text: StaticString) {
    display?.setStatusAlert(text)
}
