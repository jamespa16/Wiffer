// Phase I: ConsoleView (split out of surface.swift so that file can be shared
// with user programs, which have no Console).

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
