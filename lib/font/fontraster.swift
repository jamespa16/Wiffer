// Glyph rasterizer, glyph cache and pixel blitter (ROADMAP Phase 8E).
//
// Outlines are flattened (quadratic curves into short lines) and filled by
// accumulating signed area per pixel (the font-rs / stb_truetype v2 method):
// exact antialiased coverage for non-overlapping contours; overlapping
// contours of the same direction clamp to full coverage.

/// An 8-bit coverage bitmap. `left` is the x offset of the bitmap's left edge
/// from the pen origin, `top` the distance of its top edge above the baseline
/// (both in pixels, y up for `top`). `advance` is in pixels.
struct GlyphBitmap {
    var width = 0
    var height = 0
    var left = 0
    var top = 0
    var advance: Float = 0
    var data: [UInt8] = []
    var byteSize: Int { data.count + 48 }
}

/// Glyph id used for the tofu box (a missing character).
let fontTofuGlyph = 0xFFFF

/// Synthetic emboldening amount in pixels for a pixel size.
func fontBoldAmount(_ size: Float) -> Float { max(size / 20, 0.5) }
/// Horizontal shear for synthetic oblique (tan of about 11.3 degrees).
let fontObliqueShear: Float = 0.2

private struct FontAccum {
    var a: [Float]
    let w: Int
    let h: Int
    let stride: Int

    init(w: Int, h: Int) {
        self.w = w; self.h = h; stride = w + 2
        a = [Float](repeating: 0, count: (w + 2) * h + 4)
    }

    mutating func line(_ ax: Float, _ ay: Float, _ bx: Float, _ by: Float) {
        if ay == by { return }
        var dir: Float = 1
        var x0 = ax, y0 = ay, x1 = bx, y1 = by
        if ay > by { dir = -1; x0 = bx; y0 = by; x1 = ax; y1 = ay }
        if y1 <= 0 || y0 >= Float(h) { return }
        let dxdy = (x1 - x0) / (y1 - y0)
        var x = x0
        if y0 < 0 { x -= y0 * dxdy; y0 = 0 }
        let yEnd = min(h, Int(y1.rounded(.up)))
        var y = Int(y0)
        let fw = Float(w)
        while y < yEnd {
            let fy = Float(y)
            let dy = min(fy + 1, y1) - max(fy, y0)
            var xn = x + dxdy * dy
            // keep inside the bitmap; the bbox guarantees this up to rounding
            let xc = min(max(x, 0), fw)
            xn = min(max(xn, 0), fw)
            let d = dy * dir
            let xa = min(xc, xn), xb = max(xc, xn)
            let x0f = xa.rounded(.down)
            let x0i = Int(x0f)
            let x1c = xb.rounded(.up)
            let x1i = Int(x1c)
            let row = y * stride
            if x1i <= x0i + 1 {
                let xmf = 0.5 * (xc + xn) - x0f
                a[row + x0i] += d - d * xmf
                a[row + x0i + 1] += d * xmf
            } else {
                let s = 1 / (xb - xa)
                let xf0 = xa - x0f
                let a0 = 0.5 * s * (1 - xf0) * (1 - xf0)
                let xf1 = xb - x1c + 1
                let am = 0.5 * s * xf1 * xf1
                a[row + x0i] += d * a0
                if x1i == x0i + 2 {
                    a[row + x0i + 1] += d * (1 - a0 - am)
                } else {
                    let a1 = s * (1.5 - xf0)
                    a[row + x0i + 1] += d * (a1 - a0)
                    var xi = x0i + 2
                    while xi < x1i - 1 { a[row + xi] += d * s; xi += 1 }
                    let a2 = a1 + Float(x1i - x0i - 3) * s
                    a[row + x1i - 1] += d * (1 - a2 - am)
                }
                a[row + x1i] += d * am
            }
            x = x + dxdy * dy
            y += 1
        }
    }

    mutating func quad(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float) {
        let ddx = x0 - 2 * x1 + x2, ddy = y0 - 2 * y1 + y2
        let dd = (ddx * ddx + ddy * ddy).squareRoot()
        // flattening error is dd / (4 n^2); aim for 0.1 px
        let n = min(max(Int((dd / 0.4).squareRoot().rounded(.up)), 1), 32)
        var px = x0, py = y0
        for i in 1...n {
            let t = Float(i) / Float(n)
            let u = 1 - t
            let nx = u * u * x0 + 2 * u * t * x1 + t * t * x2
            let ny = u * u * y0 + 2 * u * t * y1 + t * t * y2
            line(px, py, nx, ny)
            px = nx; py = ny
        }
    }
}

enum FontRasterizer {
    static let maxDimension = 1024

    /// Rasterize a glyph at `size` pixels per em. `bold` and `italic` apply
    /// the synthetic fallbacks (see fontBoldAmount / fontObliqueShear). Returns
    /// nil only if the outline is invalid or the bitmap would be too large;
    /// blank glyphs (space) give an empty bitmap that still has an advance.
    static func render(_ font: TTFont, glyph: Int, size: Float, bold: Bool = false, italic: Bool = false) -> GlyphBitmap? {
        guard size > 0, size <= 512 else { return nil }
        if glyph == fontTofuGlyph { return tofu(font, size: size) }
        let scale = size / Float(font.unitsPerEm)
        var adv = Float(font.advance(of: glyph)) * scale
        let boldAmt = bold ? fontBoldAmount(size) : 0
        if bold { adv += boldAmt }
        guard let o = font.outline(glyph) else { return nil }
        var bm = GlyphBitmap()
        bm.advance = adv
        if o.points.isEmpty { return bm }

        let shear: Float = italic ? fontObliqueShear : 0
        var pts = [TTPoint](); pts.reserveCapacity(o.points.count)
        var minX: Float = 1e9, minY: Float = 1e9, maxX: Float = -1e9, maxY: Float = -1e9
        for p in o.points {
            let x = (p.x + shear * p.y) * scale
            let y = -p.y * scale
            pts.append(TTPoint(x: x, y: y, on: p.on))
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
        let padX = Int(boldAmt.rounded(.up))
        let ox = Int(minX.rounded(.down)), oy = Int(minY.rounded(.down))
        let w = Int(maxX.rounded(.up)) - ox + padX
        let h = Int(maxY.rounded(.up)) - oy
        guard w > 0, h > 0, w <= maxDimension, h <= maxDimension else { return nil }
        var acc = FontAccum(w: w, h: h)
        let fx = Float(ox), fy = Float(oy)
        var s = 0
        for e in o.ends {
            if e - s >= 1 { contour(&acc, pts, s, e, fx, fy) }
            s = e + 1
        }
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            var sum: Float = 0
            let row = y * acc.stride
            for x in 0..<w {
                sum += acc.a[row + x]
                let c = min(abs(sum), 1)
                out[y * w + x] = UInt8(c * 255 + 0.5)
            }
        }
        if padX > 0 { widen(&out, w, h, boldAmt) }
        bm.width = w; bm.height = h; bm.left = ox; bm.top = -oy; bm.data = out
        return bm
    }

    /// Horizontal dilation by `amount` pixels (bold fallback): each pixel takes
    /// the max of itself and its left neighbour scaled by the remaining reach.
    private static func widen(_ d: inout [UInt8], _ w: Int, _ h: Int, _ amount: Float) {
        var reach = amount
        var passes = 0
        while reach > 0 && passes < 4 {
            let f = min(reach, 1)
            for y in 0..<h {
                let row = y * w
                var x = w - 1
                while x > 0 {
                    let n = UInt8(Float(d[row + x - 1]) * f)
                    if n > d[row + x] { d[row + x] = n }
                    x -= 1
                }
            }
            reach -= 1; passes += 1
        }
    }

    private static func contour(_ acc: inout FontAccum, _ p: [TTPoint], _ s: Int, _ e: Int, _ fx: Float, _ fy: Float) {
        @inline(__always) func X(_ i: Int) -> Float { p[i].x - fx }
        @inline(__always) func Y(_ i: Int) -> Float { p[i].y - fy }
        var cx: Float = 0, cy: Float = 0       // current on-curve point
        var qx: Float = 0, qy: Float = 0       // pending control point
        var hasQ = false
        var first = s, last = e
        let sx: Float, sy: Float
        if p[s].on {
            sx = X(s); sy = Y(s); first = s + 1
        } else if p[e].on {
            sx = X(e); sy = Y(e); last = e - 1
        } else {
            sx = (X(s) + X(e)) / 2; sy = (Y(s) + Y(e)) / 2
        }
        cx = sx; cy = sy
        var i = first
        while i <= last {
            let x = X(i), y = Y(i)
            if p[i].on {
                if hasQ { acc.quad(cx, cy, qx, qy, x, y); hasQ = false } else { acc.line(cx, cy, x, y) }
                cx = x; cy = y
            } else {
                if hasQ {
                    let mx = (qx + x) / 2, my = (qy + y) / 2
                    acc.quad(cx, cy, qx, qy, mx, my)
                    cx = mx; cy = my
                }
                qx = x; qy = y; hasQ = true
            }
            i += 1
        }
        if hasQ { acc.quad(cx, cy, qx, qy, sx, sy) } else { acc.line(cx, cy, sx, sy) }
    }

    /// The hollow box drawn for characters no face can display.
    static func tofu(_ font: TTFont, size: Float) -> GlyphBitmap {
        var bm = GlyphBitmap()
        bm.advance = size * 0.6
        let w = max(Int((size * 0.5).rounded()), 3)
        let h = max(Int((size * 0.72).rounded()), 5)
        let t = max(Int((size / 14).rounded()), 1)
        var d = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w where x < t || x >= w - t || y < t || y >= h - t { d[y * w + x] = 255 }
        }
        bm.width = w; bm.height = h; bm.data = d
        bm.left = max(Int((size * 0.05).rounded()), 1)
        bm.top = h
        return bm
    }
}

// MARK: cache

struct GlyphKey: Hashable {
    var font: Int
    var size: Int      // pixel size in 1/8 px
    var glyph: Int
    var flags: Int     // 1 bold, 2 italic
}

/// Glyph bitmap cache keyed by (font id, pixel size, glyph, synthetic style),
/// with a memory cap: when it would be exceeded the whole cache is cleared.
final class GlyphCache {
    private var map: [GlyphKey: GlyphBitmap] = [:]
    private(set) var bytes = 0
    let capacity: Int
    private(set) var hits = 0
    private(set) var misses = 0
    private(set) var clears = 0
    var count: Int { map.count }

    init(capacity: Int = 4 << 20) { self.capacity = capacity }

    func clear() { map.removeAll(); bytes = 0 }

    /// The bitmap for a glyph, rasterizing on a miss. Sizes are quantized to
    /// 1/8 px.
    func bitmap(fontID: Int, font: TTFont, glyph: Int, size: Float, bold: Bool, italic: Bool) -> GlyphBitmap? {
        let q = Int((size * 8).rounded())
        let key = GlyphKey(font: fontID, size: q, glyph: glyph, flags: (bold ? 1 : 0) | (italic ? 2 : 0))
        if let b = map[key] { hits += 1; return b }
        misses += 1
        guard let b = FontRasterizer.render(font, glyph: glyph, size: Float(q) / 8, bold: bold, italic: italic) else { return nil }
        if bytes + b.byteSize > capacity { map.removeAll(); bytes = 0; clears += 1 }
        map[key] = b
        bytes += b.byteSize
        return b
    }
}

// MARK: blit

/// Alpha-blend a coverage bitmap into a 32-bit XRGB (0x00RRGGBB) buffer.
/// (x, y) is the pen position on the baseline in destination pixels; the
/// bitmap's bearings are applied. `color` is 0x00RRGGBB, `alpha` scales the
/// coverage. Pixels outside [0, width) x [0, height) are clipped.
func fontBlit(_ bm: GlyphBitmap, into dst: UnsafeMutablePointer<UInt32>, stride: Int,
              width: Int, height: Int, x: Int, y: Int, color: UInt32, alpha: UInt8 = 255) {
    if bm.width == 0 || bm.height == 0 || stride <= 0 { return }
    let bx = x + bm.left, by = y - bm.top
    let x0 = max(bx, 0), x1 = min(bx + bm.width, min(width, stride))
    let y0 = max(by, 0), y1 = min(by + bm.height, height)
    if x0 >= x1 || y0 >= y1 { return }
    let cr = Int(color >> 16 & 255), cg = Int(color >> 8 & 255), cb = Int(color & 255)
    let al = Int(alpha)
    bm.data.withUnsafeBufferPointer { src in
        for py in y0..<y1 {
            let srow = (py - by) * bm.width - bx
            let drow = dst + py * stride
            for px in x0..<x1 {
                var a = Int(src[srow + px])
                if a == 0 { continue }
                if al != 255 { a = (a * al + 127) / 255 }
                if a == 0 { continue }
                if a == 255 { drow[px] = UInt32(cr << 16 | cg << 8 | cb); continue }
                let d = drow[px]
                let dr = Int(d >> 16 & 255), dg = Int(d >> 8 & 255), db = Int(d & 255)
                let r = (cr * a + dr * (255 - a) + 127) / 255
                let g = (cg * a + dg * (255 - a) + 127) / 255
                let b = (cb * a + db * (255 - a) + 127) / 255
                drow[px] = UInt32(r << 16 | g << 8 | b)
            }
        }
    }
}

/// Same, into a [UInt32] with `width` pixels per row.
func fontBlit(_ bm: GlyphBitmap, into dst: inout [UInt32], width: Int, x: Int, y: Int,
              color: UInt32, alpha: UInt8 = 255) {
    guard width > 0 else { return }
    let height = dst.count / width
    dst.withUnsafeMutableBufferPointer { p in
        guard let base = p.baseAddress else { return }
        fontBlit(bm, into: base, stride: width, width: width, height: height, x: x, y: y, color: color, alpha: alpha)
    }
}
