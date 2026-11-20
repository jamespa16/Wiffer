// Shared antialiased scanline rasterizer (ROADMAP Phase 8J): paths built
// from lines and quadratic/cubic curves (flattened into line segments), filled
// with the nonzero or evenodd rule inside a clip rectangle, coverage handed
// out row by row.
//
// Coverage is exact signed area per pixel (the font-rs / stb_truetype v2
// accumulation method, the same as lib/font's glyph rasterizer): every edge
// adds its signed area to a cell row, and a running sum along the row gives
// the winding integral over each pixel. The fill rule is applied to that
// sum: nonzero clamps |w| to 1, evenodd folds it (|w| mod 2, mirrored above
// 1), as FreeType's smooth rasterizer does. Rows are processed in bands so
// the accumulation buffer stays small for big paths.
//
// Coordinates are sanitized on entry (NaN to 0, clamped to +-rasterMaxCoord),
// so nothing downstream can trap on hostile geometry, and the point count is
// capped (RasterPath.maxPoints).

let rasterMaxCoord: Float = 4_000_000

@inline(__always) func rasterSan(_ v: Float) -> Float {
    if v != v { return 0 }
    return max(-rasterMaxCoord, min(rasterMaxCoord, v))
}

@inline(__always) func rasterSanD(_ v: Double) -> Float {
    if v != v { return 0 }
    return Float(max(-4_000_000.0, min(4_000_000.0, v)))
}

/// A 2-D affine transform: x' = a x + c y + e, y' = b x + d y + f (the SVG
/// matrix(a b c d e f) order).
struct RasterTransform: Equatable {
    var a: Double = 1, b: Double = 0, c: Double = 0, d: Double = 1, e: Double = 0, f: Double = 0
    init() {}
    init(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ e: Double, _ f: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.e = e; self.f = f
    }
    static let identity = RasterTransform()
    static func translate(_ x: Double, _ y: Double) -> RasterTransform { RasterTransform(1, 0, 0, 1, x, y) }
    static func scale(_ x: Double, _ y: Double) -> RasterTransform { RasterTransform(x, 0, 0, y, 0, 0) }

    /// self then `o` (apply self first): o * self.
    func then(_ o: RasterTransform) -> RasterTransform {
        RasterTransform(o.a * a + o.c * b, o.b * a + o.d * b,
                        o.a * c + o.c * d, o.b * c + o.d * d,
                        o.a * e + o.c * f + o.e, o.b * e + o.d * f + o.f)
    }
    /// `o` first, then self: self * o.
    func concat(_ o: RasterTransform) -> RasterTransform { o.then(self) }

    func apply(_ x: Double, _ y: Double) -> (Double, Double) { (a * x + c * y + e, b * x + d * y + f) }

    var determinant: Double { a * d - b * c }

    func inverted() -> RasterTransform? {
        let det = determinant
        if det == 0 || det != det || !det.isFinite { return nil }
        let id = 1 / det
        let na = d * id, nb = -b * id, nc = -c * id, nd = a * id
        return RasterTransform(na, nb, nc, nd, -(na * e + nc * f), -(nb * e + nd * f))
    }

    /// Largest stretch factor (for flattening tolerances and stroke sizes).
    var maxScale: Double {
        let sx = (a * a + b * b).squareRoot(), sy = (c * c + d * d).squareRoot()
        let m = max(sx, sy)
        return m.isFinite ? m : 1
    }
    /// sqrt(|det|): the scale of lengths that don't have a direction.
    var meanScale: Double {
        let s = abs(determinant).squareRoot()
        return s.isFinite ? s : 1
    }
    var isFinite: Bool { a.isFinite && b.isFinite && c.isFinite && d.isFinite && e.isFinite && f.isFinite }
}

enum RasterFillRule: UInt8 { case nonZero, evenOdd }

/// Integer pixel rectangle [x0, x1) x [y0, y1).
struct RasterRect: Equatable {
    var x0: Int, y0: Int, x1: Int, y1: Int
    init(x0: Int, y0: Int, x1: Int, y1: Int) { self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1 }
    var isEmpty: Bool { x1 <= x0 || y1 <= y0 }
    func intersection(_ o: RasterRect) -> RasterRect {
        RasterRect(x0: max(x0, o.x0), y0: max(y0, o.y0), x1: min(x1, o.x1), y1: min(y1, o.y1))
    }
}

/// Flattened contours: points with contour starts. Filling closes every
/// contour implicitly; the stroker uses `closed`.
struct RasterPath {
    var xs: [Float] = []
    var ys: [Float] = []
    /// Index of each contour's first point.
    var starts: [Int] = []
    var closed: [Bool] = []
    /// Flattening tolerance in output units.
    var tolerance: Float = 0.1
    var maxPoints = 2_000_000
    /// The point cap was hit; later points were dropped.
    var overflow = false
    private var curX: Float = 0, curY: Float = 0
    private var startX: Float = 0, startY: Float = 0
    private var open = false

    init(tolerance: Float = 0.1) { self.tolerance = max(0.001, tolerance.isFinite ? tolerance : 0.1) }

    var pointCount: Int { xs.count }

    mutating func reserve(_ n: Int) {
        let k = min(max(0, n), maxPoints)
        xs.reserveCapacity(k); ys.reserveCapacity(k)
    }
    var isEmpty: Bool { xs.isEmpty }

    mutating func moveTo(_ x: Float, _ y: Float) {
        let x = rasterSan(x), y = rasterSan(y)
        open = false
        curX = x; curY = y; startX = x; startY = y
    }

    private mutating func push(_ x: Float, _ y: Float) {
        if xs.count >= maxPoints { overflow = true; return }
        xs.append(x); ys.append(y)
    }

    private mutating func ensureOpen() {
        if !open {
            starts.append(xs.count); closed.append(false)
            push(curX, curY)
            open = true
        }
    }

    mutating func lineTo(_ x: Float, _ y: Float) {
        let x = rasterSan(x), y = rasterSan(y)
        ensureOpen()
        push(x, y)
        curX = x; curY = y
    }

    mutating func quadTo(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float) {
        let x1 = rasterSan(x1), y1 = rasterSan(y1), x2 = rasterSan(x2), y2 = rasterSan(y2)
        ensureOpen()
        let x0 = curX, y0 = curY
        let ddx = x0 - 2 * x1 + x2, ddy = y0 - 2 * y1 + y2
        let dd = (ddx * ddx + ddy * ddy).squareRoot()
        let n = rasterSegments(dd / (4 * tolerance))
        if n > 1 {
            for i in 1..<n {
                let t = Float(i) / Float(n), u = 1 - t
                push(u * u * x0 + 2 * u * t * x1 + t * t * x2, u * u * y0 + 2 * u * t * y1 + t * t * y2)
            }
        }
        push(x2, y2)
        curX = x2; curY = y2
    }

    mutating func cubicTo(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float, _ x3: Float, _ y3: Float) {
        let x1 = rasterSan(x1), y1 = rasterSan(y1), x2 = rasterSan(x2), y2 = rasterSan(y2)
        let x3 = rasterSan(x3), y3 = rasterSan(y3)
        ensureOpen()
        let x0 = curX, y0 = curY
        let ax = x0 - 2 * x1 + x2, ay = y0 - 2 * y1 + y2
        let bx = x1 - 2 * x2 + x3, by = y1 - 2 * y2 + y3
        let dd = max((ax * ax + ay * ay).squareRoot(), (bx * bx + by * by).squareRoot())
        let n = rasterSegments(dd * 0.75 / tolerance)
        if n > 1 {
            for i in 1..<n {
                let t = Float(i) / Float(n), u = 1 - t
                let w0 = u * u * u, w1 = 3 * u * u * t, w2 = 3 * u * t * t, w3 = t * t * t
                push(w0 * x0 + w1 * x1 + w2 * x2 + w3 * x3, w0 * y0 + w1 * y1 + w2 * y2 + w3 * y3)
            }
        }
        push(x3, y3)
        curX = x3; curY = y3
    }

    mutating func close() {
        if open {
            if let k = closed.indices.last { closed[k] = true }
            // An explicit closing point keeps the stroker's last segment.
            if let lx = xs.last, let ly = ys.last, lx != startX || ly != startY { push(startX, startY) }
        }
        open = false
        curX = startX; curY = startY
    }

    /// Every point through `t` (for paths flattened in user space).
    mutating func transform(_ t: RasterTransform) {
        for k in 0..<xs.count {
            let (x, y) = t.apply(Double(xs[k]), Double(ys[k]))
            xs[k] = rasterSanD(x); ys[k] = rasterSanD(y)
        }
    }

    /// Append another path's contours.
    mutating func append(_ o: RasterPath) {
        for (ci, s) in o.starts.enumerated() {
            let e = ci + 1 < o.starts.count ? o.starts[ci + 1] : o.xs.count
            if xs.count + (e - s) > maxPoints { overflow = true; return }
            starts.append(xs.count); closed.append(o.closed[ci])
            xs.append(contentsOf: o.xs[s..<e]); ys.append(contentsOf: o.ys[s..<e])
        }
        open = false
    }

    /// Bounding box of the points (nil if empty).
    var bounds: (Float, Float, Float, Float)? {
        guard !xs.isEmpty else { return nil }
        var x0 = xs[0], x1 = xs[0], y0 = ys[0], y1 = ys[0]
        for k in 0..<xs.count {
            x0 = min(x0, xs[k]); x1 = max(x1, xs[k]); y0 = min(y0, ys[k]); y1 = max(y1, ys[k])
        }
        return (x0, y0, x1, y1)
    }

    /// Contour k as a point range.
    func contour(_ k: Int) -> Range<Int> {
        let s = starts[k]
        let e = k + 1 < starts.count ? starts[k + 1] : xs.count
        return s..<max(s, e)
    }
}

@inline(__always) func rasterSegments(_ v: Float) -> Int {
    if !(v > 0) { return 1 }
    let r = v.squareRoot()
    if r > 256 { return 256 }
    return max(1, Int(r.rounded(.up)))
}

/// The accumulation buffer for one band of rows.
private struct RasterAccum {
    var a: [Float]
    let w: Int
    let stride: Int
    var rows: Int
    var minCol: [Int]
    var maxCol: [Int]

    init(w: Int, rows: Int) {
        self.w = w; stride = w + 2; self.rows = rows
        a = [Float](repeating: 0, count: (w + 2) * rows + 4)
        minCol = [Int](repeating: Int.max, count: rows)
        maxCol = [Int](repeating: -1, count: rows)
    }

    mutating func reset(rows r: Int) {
        rows = r
        for k in 0..<a.count { a[k] = 0 }
        for k in 0..<minCol.count { minCol[k] = Int.max; maxCol[k] = -1 }
    }

    /// Add a line in band coordinates (rows [0, rows)).
    mutating func line(_ ax: Float, _ ay: Float, _ bx: Float, _ by: Float) {
        if ay == by { return }
        var dir: Float = 1
        var x0 = ax, y0 = ay, x1 = bx, y1 = by
        if ay > by { dir = -1; x0 = bx; y0 = by; x1 = ax; y1 = ay }
        let fh = Float(rows)
        if y1 <= 0 || y0 >= fh { return }
        let dxdy = (x1 - x0) / (y1 - y0)
        var x = x0
        if y0 < 0 { x -= y0 * dxdy; y0 = 0 }
        let yEnd = Int(min(fh, y1.rounded(.up)))
        var y = Int(y0)
        let fw = Float(w)
        while y < yEnd {
            let fy = Float(y)
            let dy = min(fy + 1, y1) - max(fy, y0)
            var xn = x + dxdy * dy
            let xc = min(max(x, 0), fw)
            xn = min(max(xn, 0), fw)
            let d = dy * dir
            let xa = min(xc, xn), xb = max(xc, xn)
            let x0f = xa.rounded(.down)
            let x0i = Int(x0f)
            let x1c = xb.rounded(.up)
            let x1i = Int(x1c)
            let row = y * stride
            if x0i < minCol[y] { minCol[y] = x0i }
            if x1i + 1 > maxCol[y] { maxCol[y] = x1i + 1 }
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
}

@inline(__always) func rasterCoverage(_ sum: Float, _ rule: RasterFillRule) -> UInt8 {
    var v = abs(sum)
    if rule == .evenOdd {
        if v > 1 {
            v = v - 2 * (v * 0.5).rounded(.down)
            if v > 1 { v = 2 - v }
        }
    } else if v > 1 { v = 1 }
    return UInt8(v * 255 + 0.5)
}

/// Fill `path` with `rule`, clipped to `clip`. For every row with coverage,
/// `body(y, x, coverage)` gets the coverage of pixels [x, x + count) on row y.
/// Returns false if nothing was drawn.
@discardableResult
func rasterFill(_ path: RasterPath, rule: RasterFillRule, clip: RasterRect,
                _ body: (Int, Int, UnsafeBufferPointer<UInt8>) -> Void) -> Bool {
    guard !clip.isEmpty, let (bx0, by0, bx1, by1) = path.bounds else { return false }
    // Pixel bbox of the path, inside the clip. Edges left of the clip still
    // count (they clamp to column 0); edges right of it don't matter.
    let px0 = max(clip.x0, Int(bx0.rounded(.down)))
    let py0 = max(clip.y0, Int(by0.rounded(.down)))
    let px1 = min(clip.x1, Int(bx1.rounded(.up)) + 1)
    let py1 = min(clip.y1, Int(by1.rounded(.up)) + 1)
    // The left edge of the fill area: edges left of the clip clamp here.
    if px1 <= px0 || py1 <= py0 { return false }
    let w = px1 - px0, h = py1 - py0
    if w > 1 << 16 || h > 1 << 16 { return false }
    let ox = Float(px0), oy = Float(py0)

    let bandRows = max(1, min(h, 262_144 / (w + 2)))
    var acc = RasterAccum(w: w, rows: min(bandRows, h))
    var out = [UInt8](repeating: 0, count: w)
    var drew = false

    if h <= bandRows {
        // One band (glyphs, icons): lines go straight in, no edge list.
        for k in 0..<path.starts.count {
            let r = path.contour(k)
            if r.count < 2 { continue }
            var px = path.xs[r.upperBound - 1] - ox, py = path.ys[r.upperBound - 1] - oy
            for i in r {
                let x = path.xs[i] - ox, y = path.ys[i] - oy
                acc.line(px, py, x, y)
                px = x; py = y
            }
        }
        rasterEmit(&acc, &out, h, w, px0, py0, rule, &drew, body)
        return drew
    }

    // Edges, sorted by top.
    var ex0: [Float] = [], ey0: [Float] = [], ex1: [Float] = [], ey1: [Float] = []
    let np = path.xs.count
    ex0.reserveCapacity(np); ey0.reserveCapacity(np); ex1.reserveCapacity(np); ey1.reserveCapacity(np)
    for k in 0..<path.starts.count {
        let r = path.contour(k)
        if r.count < 2 { continue }
        var px = path.xs[r.upperBound - 1] - ox, py = path.ys[r.upperBound - 1] - oy
        for i in r {
            let x = path.xs[i] - ox, y = path.ys[i] - oy
            if y != py && !(max(y, py) <= 0) && !(min(y, py) >= Float(h)) {
                ex0.append(px); ey0.append(py); ex1.append(x); ey1.append(y)
            }
            px = x; py = y
        }
    }
    if ex0.isEmpty { return false }
    var tops = [Float](repeating: 0, count: ex0.count)
    for e in 0..<ex0.count { tops[e] = min(ey0[e], ey1[e]) }
    var order = [Int](0..<ex0.count)
    order.sort { tops[$0] < tops[$1] }

    var active: [Int] = []
    var next = 0
    var band = 0
    var fresh = true
    while band < h {
        let rows = min(bandRows, h - band)
        let fb = Float(band), fe = Float(band + rows)
        // Drop finished edges, add the ones starting in this band.
        var k = 0
        while k < active.count {
            let e = active[k]
            if max(ey0[e], ey1[e]) <= fb { active[k] = active[active.count - 1]; active.removeLast() } else { k += 1 }
        }
        while next < order.count {
            let e = order[next]
            if tops[e] >= fe { break }
            if max(ey0[e], ey1[e]) > fb { active.append(e) }
            next += 1
        }
        if active.isEmpty {
            band += rows
            continue
        }
        if !fresh { acc.reset(rows: rows) } else { acc.rows = rows }
        fresh = false
        for e in active { acc.line(ex0[e], ey0[e] - fb, ex1[e], ey1[e] - fb) }
        rasterEmit(&acc, &out, rows, w, px0, py0 + band, rule, &drew, body)
        band += rows
    }
    return drew
}

/// Running sums of a band into coverage rows, handed to `body`.
@inline(__always)
private func rasterEmit(_ acc: inout RasterAccum, _ out: inout [UInt8], _ rows: Int, _ w: Int, _ x0: Int, _ y0: Int,
                        _ rule: RasterFillRule, _ drew: inout Bool,
                        _ body: (Int, Int, UnsafeBufferPointer<UInt8>) -> Void) {
    let stride = acc.stride
    acc.a.withUnsafeBufferPointer { a in
        out.withUnsafeMutableBufferPointer { o in
            guard let base = o.baseAddress else { return }
            for r in 0..<rows {
                let lo = acc.minCol[r]
                if lo == Int.max { continue }
                let hi = min(w, acc.maxCol[r])
                let start = min(lo, w)
                var sum: Float = 0
                let row = r * stride
                var any: UInt8 = 0
                var x = start
                while x < hi {
                    sum += a[row + x]
                    let c = rasterCoverage(sum, rule)
                    o[x] = c
                    any |= c
                    x += 1
                }
                // Past the last touched cell the sum is constant.
                if x < w {
                    let c = rasterCoverage(sum, rule)
                    any |= c
                    while x < w { o[x] = c; x += 1 }
                }
                if any == 0 { continue }
                drew = true
                body(y0 + r, x0 + start, UnsafeBufferPointer(start: base + start, count: w - start))
            }
        }
    }
}

/// An 8-bit coverage mask over a rectangle (clip paths, glyphs, tests).
struct RasterMask {
    var x = 0, y = 0, width = 0, height = 0
    var data: [UInt8] = []
    init() {}
    init(x: Int, y: Int, width: Int, height: Int, fill: UInt8 = 0) {
        self.x = x; self.y = y; self.width = max(0, width); self.height = max(0, height)
        data = [UInt8](repeating: fill, count: self.width * self.height)
    }

    /// Coverage at a pixel (0 outside).
    func at(_ px: Int, _ py: Int) -> UInt8 {
        let lx = px - x, ly = py - y
        if lx < 0 || ly < 0 || lx >= width || ly >= height { return 0 }
        return data[ly * width + lx]
    }
}

/// Rasterize into a mask covering `clip` (the union with whatever is there:
/// max of coverages).
func rasterFillMask(_ path: RasterPath, rule: RasterFillRule, into m: inout RasterMask) {
    let clip = RasterRect(x0: m.x, y0: m.y, x1: m.x + m.width, y1: m.y + m.height)
    let mw = m.width, mx = m.x, my = m.y
    m.data.withUnsafeMutableBufferPointer { d in
        _ = rasterFill(path, rule: rule, clip: clip) { y, x, cov in
            let row = (y - my) * mw + (x - mx)
            for k in 0..<cov.count where cov[k] > d[row + k] { d[row + k] = cov[k] }
        }
    }
}
