// Phase I: pixel surfaces and drawing.
//
// - Point, Rect: signed integer geometry. Coordinates may be negative or run
//   off any edge; every primitive clips.
// - Surface: a width x height grid of UInt32 pixels, with a clip rect. It
//   either owns its pixels (heap; a 640x480 surface is a 1.2 MiB large-block
//   allocation) or wraps memory it doesn't own (the framebuffer).
// - Sprite: a 1-bit image plus a 1-bit mask (the mouse cursor).
// - ConsoleView: renders a Console's dirty rows into a Surface.
//
// Pixels are whatever format the caller uses (the console uses the
// framebuffer's, so a surface can be copied straight out). Drawing never reads
// the destination, so a Surface wrapping the framebuffer is write-only in
// practice; never call pixel(x, y) on one.
//
// No primitive allocates: they are safe on the exception-report path.

struct Point: Equatable {
    var x: Int
    var y: Int

    init(_ x: Int, _ y: Int) { self.x = x; self.y = y }
    init(x: Int, y: Int) { self.x = x; self.y = y }

    static let zero = Point(0, 0)
}

/// An axis-aligned rectangle: x in [x, x + w), y in [y, y + h). A rect with
/// w <= 0 or h <= 0 is empty; all empty rects behave alike.
struct Rect: Equatable {
    var x: Int
    var y: Int
    var w: Int
    var h: Int

    init(_ x: Int, _ y: Int, _ w: Int, _ h: Int) { self.x = x; self.y = y; self.w = w; self.h = h }
    init(x: Int, y: Int, w: Int, h: Int) { self.x = x; self.y = y; self.w = w; self.h = h }
    init(origin: Point, w: Int, h: Int) { x = origin.x; y = origin.y; self.w = w; self.h = h }

    static let empty = Rect(0, 0, 0, 0)

    var isEmpty: Bool { w <= 0 || h <= 0 }
    var maxX: Int { x + w }
    var maxY: Int { y + h }
    var origin: Point { Point(x, y) }
    var area: Int { isEmpty ? 0 : w * h }

    func contains(_ p: Point) -> Bool {
        p.x >= x && p.x < x + w && p.y >= y && p.y < y + h
    }

    /// True if `r` lies entirely inside (an empty `r` is inside anything).
    func contains(_ r: Rect) -> Bool {
        r.isEmpty || (!isEmpty && r.x >= x && r.y >= y && r.maxX <= maxX && r.maxY <= maxY)
    }

    func intersects(_ r: Rect) -> Bool { !intersection(r).isEmpty }

    /// The overlap, or `Rect.empty`.
    func intersection(_ r: Rect) -> Rect {
        let x0 = max(x, r.x), y0 = max(y, r.y)
        let x1 = min(maxX, r.maxX), y1 = min(maxY, r.maxY)
        return x1 > x0 && y1 > y0 ? Rect(x0, y0, x1 - x0, y1 - y0) : .empty
    }

    /// The bounding box of both. Empty rects are ignored.
    func union(_ r: Rect) -> Rect {
        if isEmpty { return r.isEmpty ? .empty : r }
        if r.isEmpty { return self }
        let x0 = min(x, r.x), y0 = min(y, r.y)
        return Rect(x0, y0, max(maxX, r.maxX) - x0, max(maxY, r.maxY) - y0)
    }

    func offsetBy(dx: Int, dy: Int) -> Rect { Rect(x + dx, y + dy, w, h) }
    func offsetBy(_ p: Point) -> Rect { Rect(x + p.x, y + p.y, w, h) }
}

// MARK: Sprite

/// A 1-bit image with a 1-bit mask, both packed MSB-first, `bytesPerRow`
/// bytes per row (the PSF glyph layout). Mask 0 = transparent; else image
/// bit 1 = ink, 0 = paper.
struct Sprite {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    var image: [UInt8]
    var mask: [UInt8]

    /// Parse ASCII art: one text line per row, `ink` and `paper` characters
    /// are opaque, anything else is transparent. Allocates (call once).
    init(art: StaticString, ink: UInt8 = 0x58 /* X */, paper: UInt8 = 0x6F /* o */) {
        var w = 0, h = 0
        art.withUTF8Buffer { buf in
            var col = 0
            for c in buf {
                if c == 0x0A { h += 1; w = max(w, col); col = 0 } else { col += 1 }
            }
            if col > 0 { h += 1; w = max(w, col) }
        }
        width = w
        height = h
        bytesPerRow = (w + 7) / 8
        image = Array(repeating: 0, count: bytesPerRow * h)
        mask = Array(repeating: 0, count: bytesPerRow * h)
        let stride = bytesPerRow
        art.withUTF8Buffer { buf in
            var row = 0, col = 0
            for c in buf {
                if c == 0x0A { row += 1; col = 0; continue }
                let i = row * stride + col / 8, bit = UInt8(0x80) >> UInt8(col & 7)
                if c == ink { image[i] |= bit; mask[i] |= bit }
                else if c == paper { mask[i] |= bit }
                col += 1
            }
        }
    }

    /// 0 transparent, 1 ink, 2 paper.
    func at(_ x: Int, _ y: Int) -> Int {
        guard x >= 0, x < width, y >= 0, y < height else { return 0 }
        let i = y * bytesPerRow + x / 8, bit = UInt8(0x80) >> UInt8(x & 7)
        return mask[i] & bit == 0 ? 0 : image[i] & bit != 0 ? 1 : 2
    }
}

// MARK: Surface

final class Surface {
    let width: Int
    let height: Int
    /// Pixels per row in memory (>= width; only wrapped memory has padding).
    let stride: Int
    let pixels: UnsafeMutablePointer<UInt32>
    let owned: Bool
    /// Drawing is limited to this; always inside `bounds`.
    private(set) var clip: Rect

    var bounds: Rect { Rect(0, 0, width, height) }

    /// A heap surface filled with `color`.
    init(width: Int, height: Int, color: UInt32 = 0) {
        self.width = max(width, 0)
        self.height = max(height, 0)
        stride = self.width
        pixels = UnsafeMutablePointer<UInt32>.allocate(capacity: max(self.width * self.height, 1))
        pixels.initialize(repeating: color, count: max(self.width * self.height, 1))
        owned = true
        clip = Rect(0, 0, self.width, self.height)
    }

    /// Wrap memory owned elsewhere (e.g. the framebuffer, at an HHDM address:
    /// only the raw pointer is kept).
    init(wrapping pixels: UnsafeMutablePointer<UInt32>, width: Int, height: Int, stride: Int) {
        self.width = max(width, 0)
        self.height = max(height, 0)
        self.stride = max(stride, self.width)
        self.pixels = pixels
        owned = false
        clip = Rect(0, 0, self.width, self.height)
    }

    deinit {
        if owned { pixels.deallocate() }
    }

    /// Set the clip rect (limited to the surface). nil = the whole surface.
    func setClip(_ r: Rect?) {
        clip = r.map { $0.intersection(bounds) } ?? bounds
    }

    /// Run `body` with the clip narrowed to `r` (within the current clip),
    /// then restore it.
    func withClip<R>(_ r: Rect, _ body: () -> R) -> R {
        let saved = clip
        clip = clip.intersection(r)
        defer { clip = saved }
        return body()
    }

    /// Read a pixel (nil outside the surface). Not for wrapped framebuffers.
    func pixel(_ x: Int, _ y: Int) -> UInt32? {
        guard x >= 0, x < width, y >= 0, y < height else { return nil }
        return pixels[y * stride + x]
    }

    // MARK: Primitives

    func plot(_ x: Int, _ y: Int, _ color: UInt32) {
        if clip.contains(Point(x, y)) { pixels[y * stride + x] = color }
    }

    func fill(_ r: Rect, _ color: UInt32) {
        let c = r.intersection(clip)
        guard !c.isEmpty else { return }
        var row = pixels + c.y * stride + c.x
        for _ in 0..<c.h {
            row.update(repeating: color, count: c.w)
            row += stride
        }
    }

    /// Fill the whole clip rect.
    func fill(_ color: UInt32) { fill(clip, color) }

    func hline(x: Int, y: Int, w: Int, _ color: UInt32) { fill(Rect(x, y, w, 1), color) }
    func vline(x: Int, y: Int, h: Int, _ color: UInt32) { fill(Rect(x, y, 1, h), color) }

    /// A 1-pixel outline just inside `r`.
    func frame(_ r: Rect, _ color: UInt32) {
        guard !r.isEmpty else { return }
        hline(x: r.x, y: r.y, w: r.w, color)
        if r.h > 1 { hline(x: r.x, y: r.maxY - 1, w: r.w, color) }
        if r.h > 2 {
            vline(x: r.x, y: r.y + 1, h: r.h - 2, color)
            if r.w > 1 { vline(x: r.maxX - 1, y: r.y + 1, h: r.h - 2, color) }
        }
    }

    /// Copy `src` (in `from`'s coordinates) so its top-left lands at `to`.
    /// Clipped against both surfaces. `from` may be `self` (overlap is fine).
    func blit(from: Surface, src: Rect, to: Point) {
        // Clip the source to its surface, moving the destination with it.
        let s = src.intersection(from.bounds)
        guard !s.isEmpty else { return }
        let dx = to.x - src.x, dy = to.y - src.y
        let d = s.offsetBy(dx: dx, dy: dy).intersection(clip)
        guard !d.isEmpty else { return }
        let sx = d.x - dx, sy = d.y - dy
        let overlapping = from === self && d.intersects(Rect(sx, sy, d.w, d.h))
        if overlapping && (d.y > sy || (d.y == sy && d.x > sx)) {
            // Copy backwards (bottom-up, right-to-left) so source pixels are
            // read before they're overwritten.
            var r = d.h - 1
            while r >= 0 {
                let dst = pixels + (d.y + r) * stride + d.x
                let sp = from.pixels + (sy + r) * from.stride + sx
                var i = d.w - 1
                while i >= 0 { dst[i] = sp[i]; i -= 1 }
                r -= 1
            }
        } else {
            for r in 0..<d.h {
                let dst = pixels + (d.y + r) * stride + d.x
                let sp = from.pixels + (sy + r) * from.stride + sx
                for i in 0..<d.w { dst[i] = sp[i] }
            }
        }
    }

    /// Draw a `w` x `h` 1-bit image at `at`, packed MSB-first in rows of
    /// `bytesPerRow` bytes. Set bits get `fg`; clear bits get `bg`, or are
    /// left alone if `bg` is nil. With a mask (same layout), pixels whose
    /// mask bit is clear are left alone.
    func drawBits(_ bits: UnsafePointer<UInt8>, mask: UnsafePointer<UInt8>?, bytesPerRow: Int,
                  w: Int, h: Int, at p: Point, fg: UInt32, bg: UInt32?) {
        let c = Rect(p.x, p.y, w, h).intersection(clip)
        guard !c.isEmpty else { return }
        let x0 = c.x - p.x
        for y in c.y..<c.maxY {
            let srcRow = (y - p.y) * bytesPerRow
            let row = bits + srcRow
            var dst = pixels + y * stride + c.x
            for sx in x0..<(x0 + c.w) {
                let byte = sx >> 3, bit = UInt8(0x80) >> UInt8(sx & 7)
                if let mask, mask[srcRow + byte] & bit == 0 { dst += 1; continue }
                if row[byte] & bit != 0 { dst.pointee = fg } else if let bg { dst.pointee = bg }
                dst += 1
            }
        }
    }

    /// A masked sprite: ink pixels get `ink`, paper pixels get `paper`.
    func drawSprite(_ s: Sprite, at p: Point, ink: UInt32, paper: UInt32) {
        s.image.withUnsafeBufferPointer { image in
            s.mask.withUnsafeBufferPointer { mask in
                guard let i = image.baseAddress, let m = mask.baseAddress else { return }
                drawBits(i, mask: m, bytesPerRow: s.bytesPerRow, w: s.width, h: s.height,
                         at: p, fg: ink, bg: paper)
            }
        }
    }

    /// Draw glyph number `glyph` of `font` with its top-left at `p`. A nil
    /// `bg` leaves the background pixels alone.
    func drawGlyph(_ glyph: Int, font: PSFFont, at p: Point, fg: UInt32, bg: UInt32?) {
        let c = Rect(p.x, p.y, font.width, font.height)
        if font.width == 8, let bg, clip.contains(c) {
            // Fast path (every console cell): unclipped, opaque, 8 wide.
            var src = font.bitmap(glyph)
            var dst = pixels + p.y * stride + p.x
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
                dst += stride
            }
            return
        }
        drawBits(font.bitmap(glyph), mask: nil, bytesPerRow: (font.width + 7) / 8,
                 w: font.width, h: font.height, at: p, fg: fg, bg: bg)
    }

    /// Draw the glyph for Unicode scalar `cp`.
    func drawGlyph(codepoint cp: UInt32, font: PSFFont, at p: Point, fg: UInt32, bg: UInt32?) {
        drawGlyph(font.glyph(cp), font: font, at: p, fg: fg, bg: bg)
    }

    /// Draw `text` left to right, one cell per Unicode scalar (no control
    /// characters are interpreted). Returns the pen position after the text.
    @discardableResult
    func drawText(_ text: String, font: PSFFont, at p: Point, fg: UInt32, bg: UInt32?) -> Point {
        var x = p.x
        for s in text.unicodeScalars {
            if x >= clip.maxX { x += font.width; continue } // keep measuring
            drawGlyph(font.glyph(s.value), font: font, at: Point(x, p.y), fg: fg, bg: bg)
            x += font.width
        }
        return Point(x, p.y)
    }
}

/// Width of `text` in cells (the font is monospace: one cell per scalar).
func textCells(_ text: String) -> Int {
    var n = 0
    for _ in text.unicodeScalars { n += 1 }
    return n
}

extension PSFFont {
    /// Width of `text` in pixels.
    func textWidth(_ text: String) -> Int { textCells(text) * width }
}

// MARK: ConsoleView

/// Draws a Console (cell grid) into a Surface: only dirty rows, plus the rows
/// the text cursor (an inverted cell) left and entered. Never allocates.
final class ConsoleView {
    let font: PSFFont
    /// The 16 ANSI colours in the target surface's pixel format.
    var palette: InlineArray<16, UInt32>
    var showCursor = true
    /// Where the text cursor was last drawn.
    private(set) var cursorRow = -1
    private(set) var cursorCol = -1

    init(font: PSFFont, palette: InlineArray<16, UInt32>) {
        self.font = font
        self.palette = palette
    }

    /// Size of a console in pixels.
    func pixelSize(_ c: Console) -> (w: Int, h: Int) { (c.cols * font.width, c.rows * font.height) }

    /// Render `c`'s dirty rows with cell (0, 0) at `origin`, clear their
    /// dirty flags, and report each repainted row (clipped to the surface's
    /// clip) to `damaged`. Rows outside the clip are marked clean too.
    func render(_ c: Console, into s: Surface, at origin: Point, damaged: (Rect) -> Void) {
        let cr = min(c.row, c.rows - 1), cc = min(c.col, c.cols - 1)
        if cr != cursorRow || cc != cursorCol {
            if cursorRow >= 0 && cursorRow < c.rows { c.dirty[cursorRow] = true }
            c.dirty[cr] = true
        }
        let fw = font.width, fh = font.height
        for r in 0..<c.rows where c.dirty[r] {
            c.dirty[r] = false
            let y = origin.y + r * fh
            let rowRect = Rect(origin.x, y, c.cols * fw, fh).intersection(s.clip)
            if rowRect.isEmpty { continue }
            let base = r * c.cols
            for col in 0..<c.cols {
                let x = origin.x + col * fw
                if x + fw <= rowRect.x || x >= rowRect.maxX { continue }
                let cell = c.cells[base + col]
                var fg = palette[Int(cell.fg & 15)], bg = palette[Int(cell.bg & 15)]
                if showCursor && r == cr && col == cc { swap(&fg, &bg) }
                s.drawGlyph(font.glyph(cell.ch), font: font, at: Point(x, y), fg: fg, bg: bg)
            }
            damaged(rowRect)
        }
        cursorRow = cr
        cursorCol = cc
    }

    /// Like render(_:into:at:damaged:), returning the bounding box of what
    /// was repainted (empty if nothing).
    @discardableResult
    func render(_ c: Console, into s: Surface, at origin: Point) -> Rect {
        var box = Rect.empty
        render(c, into: s, at: origin) { box = box.union($0) }
        return box
    }
}
