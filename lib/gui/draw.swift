// Drawing primitives beyond Surface's (lib/gui).

extension Surface {
    /// A 1-pixel line from `a` to `b` (Bresenham), clipped.
    func line(from a: Point, to b: Point, _ color: UInt32) {
        var x = a.x, y = a.y
        let dx = abs(b.x - a.x), dy = -abs(b.y - a.y)
        let sx = a.x < b.x ? 1 : -1, sy = a.y < b.y ? 1 : -1
        var err = dx + dy
        var steps = dx - dy + 1 // bounded: a line never needs more
        while steps > 0 {
            plot(x, y, color)
            if x == b.x && y == b.y { break }
            let e2 = 2 * err
            if e2 >= dy { err += dy; x += sx }
            if e2 <= dx { err += dx; y += sy }
            steps -= 1
        }
    }

    /// A filled ellipse inscribed in `r`.
    func fillEllipse(_ r: Rect, _ color: UInt32) {
        guard !r.isEmpty else { return }
        let a = r.w, b = r.h
        for row in 0..<r.h {
            let dy = 2 * row + 1 - b
            var lo = 0
            while lo < r.w {
                let dx = 2 * lo + 1 - a
                if dx * dx * b * b + dy * dy * a * a <= a * a * b * b { break }
                lo += 1
            }
            let hi = r.w - lo
            if hi > lo { fill(Rect(r.x + lo, r.y + row, hi - lo, 1), color) }
        }
    }

    /// `text` centred in `r` (clipped to it).
    func drawTextCentered(_ text: String, font: PSFFont, in r: Rect, fg: UInt32, bg: UInt32? = nil) {
        let w = font.textWidth(text)
        _ = withClip(r) {
            drawText(text, font: font, at: Point(r.x + (r.w - w) / 2, r.y + (r.h - font.height) / 2), fg: fg, bg: bg)
        }
    }
}
