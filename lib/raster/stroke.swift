// The stroker: turns the flattened contours of a path into fill polygons
// (filled nonzero) for a given width, joins, caps and miter limit, and
// splits contours into dashes. Strokes are built in the path's own units
// (SVG user space); the caller transforms the result, so a non-uniform
// scale stretches the stroke as it should.
//
// Each open contour becomes one polygon: the left offset forward, the end
// cap, the right offset backward, the start cap. A closed contour becomes two
// loops (outer and inner). Outer corners get the join; inner corners go
// through the vertex itself (the pivot), which leaves small self-overlaps
// that the nonzero rule fills.

enum RasterLineCap: UInt8 { case butt, round, square }
enum RasterLineJoin: UInt8 { case miter, round, bevel }

struct RasterStrokeStyle {
    var width: Float = 1
    var cap = RasterLineCap.butt
    var join = RasterLineJoin.miter
    var miterLimit: Float = 4
    /// Flattening tolerance for round joins and caps, in path units.
    var tolerance: Float = 0.2
    init() {}
}

/// Limits for hostile dash patterns.
let rasterMaxDashes = 100_000

private struct RasterStroker {
    let hw: Float
    let style: RasterStrokeStyle
    var out: RasterPath
    let roundStep: Float

    init(_ s: RasterStrokeStyle, maxPoints: Int) {
        style = s
        hw = s.width / 2
        out = RasterPath(tolerance: s.tolerance)
        out.maxPoints = maxPoints
        // Angle step so the chord error stays under the tolerance.
        let r = max(hw, 0.0001)
        let c = max(-1, min(1, 1 - min(s.tolerance * 0.25, r) / r))
        var step = 2 * Float(rasterAcos(Double(c)))
        if !(step > 0.05) { step = 0.05 }
        roundStep = min(step, Float.pi / 4)
    }

    mutating func arc(_ cx: Float, _ cy: Float, _ a0: Float, _ sweep: Float) {
        let n = max(1, min(256, Int((abs(sweep) / roundStep).rounded(.up))))
        for i in 1..<n {
            let a = a0 + sweep * Float(i) / Float(n)
            out.lineTo(cx + hw * rasterCosF(a), cy + hw * rasterSinF(a))
        }
    }

    /// Join at vertex (px, py) from direction (d0x, d0y) to (d1x, d1y), both
    /// unit, on the left side (normal = (-dy, dx)). The previous offset point
    /// has been emitted; this emits through the next segment's start offset.
    mutating func join(_ px: Float, _ py: Float, _ d0x: Float, _ d0y: Float, _ d1x: Float, _ d1y: Float) {
        let n0x = -d0y * hw, n0y = d0x * hw
        let n1x = -d1y * hw, n1y = d1x * hw
        let cross = d0x * d1y - d0y * d1x
        let dot = d0x * d1x + d0y * d1y
        out.lineTo(px + n0x, py + n0y)
        if abs(cross) < 1e-4 && dot > 0 {
            out.lineTo(px + n1x, py + n1y)
            return
        }
        if cross > 0 {
            // Inner corner (the turn is toward this side): pivot.
            out.lineTo(px, py)
            out.lineTo(px + n1x, py + n1y)
            return
        }
        switch style.join {
        case .bevel:
            break
        case .miter:
            let cosHalf = ((1 + dot) / 2).squareRoot()
            if cosHalf > 1e-6 && 1 / cosHalf <= style.miterLimit {
                let k = hw / (1 + dot) / hw
                out.lineTo(px + (n0x + n1x) * k, py + (n0y + n1y) * k)
            }
        case .round:
            let a0 = rasterAtan2F(n0y, n0x)
            var a1 = rasterAtan2F(n1y, n1x)
            // The outer side turns clockwise here (cross < 0).
            while a1 > a0 { a1 -= 2 * Float.pi }
            while a1 < a0 - 2 * Float.pi { a1 += 2 * Float.pi }
            arc(px, py, a0, a1 - a0)
        }
        out.lineTo(px + n1x, py + n1y)
    }

    /// Cap at (px, py) leaving in direction (dx, dy): from the left offset
    /// to the right offset.
    mutating func cap(_ px: Float, _ py: Float, _ dx: Float, _ dy: Float) {
        let nx = -dy * hw, ny = dx * hw
        switch style.cap {
        case .butt: break
        case .square:
            out.lineTo(px + nx + dx * hw, py + ny + dy * hw)
            out.lineTo(px - nx + dx * hw, py - ny + dy * hw)
        case .round:
            let a0 = rasterAtan2F(ny, nx)
            arc(px, py, a0, -Float.pi)
        }
        out.lineTo(px - nx, py - ny)
    }

    /// One side of a polyline (points in order), with joins; `closedLoop`
    /// joins the last segment back to the first.
    mutating func side(_ xs: [Float], _ ys: [Float], closedLoop: Bool) {
        let n = xs.count
        var dx = [Float](repeating: 0, count: n), dy = [Float](repeating: 0, count: n)
        let segs = closedLoop ? n : n - 1
        for i in 0..<segs {
            let j = (i + 1) % n
            let ex = xs[j] - xs[i], ey = ys[j] - ys[i]
            let l = (ex * ex + ey * ey).squareRoot()
            dx[i] = l > 0 ? ex / l : 1; dy[i] = l > 0 ? ey / l : 0
        }
        if closedLoop {
            out.moveTo(xs[0] - dy[0] * hw, ys[0] + dx[0] * hw)
            out.lineTo(xs[0] - dy[0] * hw, ys[0] + dx[0] * hw)
            for i in 1..<n { join(xs[i], ys[i], dx[i - 1], dy[i - 1], dx[i], dy[i]) }
            join(xs[0], ys[0], dx[n - 1], dy[n - 1], dx[0], dy[0])
            out.close()
        } else {
            out.lineTo(xs[0] - dy[0] * hw, ys[0] + dx[0] * hw)
            if n > 2 { for i in 1..<(n - 1) { join(xs[i], ys[i], dx[i - 1], dy[i - 1], dx[i], dy[i]) } }
            out.lineTo(xs[n - 1] - dy[n - 2] * hw, ys[n - 1] + dx[n - 2] * hw)
        }
    }

    mutating func contour(_ px: ArraySlice<Float>, _ py: ArraySlice<Float>, closed: Bool) {
        // Drop repeated points.
        var xs: [Float] = [], ys: [Float] = []
        xs.reserveCapacity(px.count); ys.reserveCapacity(py.count)
        var i = px.startIndex
        while i < px.endIndex {
            let x = px[i], y = py[i]
            if let lx = xs.last, let ly = ys.last, abs(lx - x) < 1e-5 && abs(ly - y) < 1e-5 { i += 1; continue }
            xs.append(x); ys.append(y)
            i += 1
        }
        if closed && xs.count > 1, let lx = xs.last, let ly = ys.last, abs(lx - xs[0]) < 1e-5 && abs(ly - ys[0]) < 1e-5 {
            xs.removeLast(); ys.removeLast()
        }
        if xs.count == 1 {
            // A zero-length subpath: round and square caps draw a dot.
            let x = xs[0], y = ys[0]
            switch style.cap {
            case .butt: return
            case .square:
                out.moveTo(x - hw, y - hw); out.lineTo(x + hw, y - hw); out.lineTo(x + hw, y + hw); out.lineTo(x - hw, y + hw); out.close()
            case .round:
                out.moveTo(x + hw, y); out.lineTo(x + hw, y)
                arc(x, y, 0, 2 * Float.pi)
                out.close()
            }
            return
        }
        if xs.isEmpty { return }
        if closed && xs.count >= 3 {
            side(xs, ys, closedLoop: true)
            side(Array(xs.reversed()), Array(ys.reversed()), closedLoop: true)
            return
        }
        if closed { xs.append(xs[0]); ys.append(ys[0]) }
        let n = xs.count
        out.moveTo(xs[0], ys[0])
        side(xs, ys, closedLoop: false)
        // End cap.
        let ex = xs[n - 1] - xs[n - 2], ey = ys[n - 1] - ys[n - 2]
        let el = max((ex * ex + ey * ey).squareRoot(), 1e-12)
        cap(xs[n - 1], ys[n - 1], ex / el, ey / el)
        // The backward side; the cap already ended at its first offset point.
        sideBack(Array(xs.reversed()), Array(ys.reversed()))
        let sx = xs[0] - xs[1], sy = ys[0] - ys[1]
        let sl = max((sx * sx + sy * sy).squareRoot(), 1e-12)
        cap(xs[0], ys[0], sx / sl, sy / sl)
        out.close()
    }

    /// Like side(open) but the first offset point is already emitted by the cap.
    mutating func sideBack(_ xs: [Float], _ ys: [Float]) {
        let n = xs.count
        var dx = [Float](repeating: 0, count: n), dy = [Float](repeating: 0, count: n)
        for i in 0..<(n - 1) {
            let ex = xs[i + 1] - xs[i], ey = ys[i + 1] - ys[i]
            let l = (ex * ex + ey * ey).squareRoot()
            dx[i] = l > 0 ? ex / l : 1; dy[i] = l > 0 ? ey / l : 0
        }
        if n > 2 { for i in 1..<(n - 1) { join(xs[i], ys[i], dx[i - 1], dy[i - 1], dx[i], dy[i]) } }
        out.lineTo(xs[n - 1] - dy[n - 2] * hw, ys[n - 1] + dx[n - 2] * hw)
    }
}

/// The fill polygons (nonzero) of `path`'s stroke.
func rasterStroke(_ path: RasterPath, _ style: RasterStrokeStyle, maxPoints: Int = 2_000_000) -> RasterPath {
    var s = style
    if !(s.width > 0) || !s.width.isFinite { return RasterPath() }
    if !(s.miterLimit >= 1) { s.miterLimit = 4 }
    var st = RasterStroker(s, maxPoints: maxPoints)
    for k in 0..<path.starts.count {
        let r = path.contour(k)
        if r.isEmpty { continue }
        st.contour(path.xs[r], path.ys[r], closed: path.closed[k])
        if st.out.overflow { break }
    }
    return st.out
}

/// Split contours into dashes. `dashes` are lengths (an odd count repeats
/// twice); `offset` shifts the pattern start. Patterns that are all zero,
/// negative, or would make more than rasterMaxDashes pieces return the path
/// unchanged.
func rasterDash(_ path: RasterPath, _ dashes: [Float], offset: Float) -> RasterPath {
    var pat = dashes
    if pat.isEmpty { return path }
    if pat.count % 2 == 1 { pat += pat }
    var total: Float = 0
    for d in pat {
        if !(d >= 0) || !d.isFinite { return path }
        total += d
    }
    if !(total > 0) || !total.isFinite { return path }
    // Estimate the number of pieces.
    var length: Float = 0
    for k in 0..<path.starts.count {
        let r = path.contour(k)
        var i = r.lowerBound + 1
        while i < r.upperBound {
            let dx = path.xs[i] - path.xs[i - 1], dy = path.ys[i] - path.ys[i - 1]
            length += (dx * dx + dy * dy).squareRoot()
            i += 1
        }
    }
    if length / total * Float(pat.count) > Float(rasterMaxDashes) { return path }

    var out = RasterPath(tolerance: path.tolerance)
    out.maxPoints = path.maxPoints
    var off = offset.isFinite ? offset : 0
    off = off - total * (off / total).rounded(.down)
    for k in 0..<path.starts.count {
        let r = path.contour(k)
        if r.count < 2 { continue }
        // Pattern state at the contour start.
        var idx = 0
        var left = pat[0]
        var skip = off
        var guardN = 0
        while skip > 0 && guardN < 10_000 {
            guardN += 1
            if skip >= left { skip -= left; idx = (idx + 1) % pat.count; left = pat[idx] }
            else { left -= skip; skip = 0 }
        }
        var on = idx % 2 == 0
        if on {
            out.moveTo(path.xs[r.lowerBound], path.ys[r.lowerBound])
            out.lineTo(path.xs[r.lowerBound], path.ys[r.lowerBound])
        }
        var i = r.lowerBound + 1
        var steps = 0
        while i < r.upperBound {
            var x0 = path.xs[i - 1], y0 = path.ys[i - 1]
            let x1 = path.xs[i], y1 = path.ys[i]
            var seg = ((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0)).squareRoot()
            while seg > 0 && steps < rasterMaxDashes * 4 {
                steps += 1
                if left >= seg {
                    if on { out.lineTo(x1, y1) }
                    left -= seg
                    seg = 0
                } else {
                    let t = left / seg
                    let mx = x0 + (x1 - x0) * t, my = y0 + (y1 - y0) * t
                    if on { out.lineTo(mx, my) }
                    on.toggle()
                    // A dash starts with a point of its own, so a zero-length
                    // dash still gets its caps.
                    if on { out.moveTo(mx, my); out.lineTo(mx, my) }
                    seg -= left
                    x0 = mx; y0 = my
                    idx = (idx + 1) % pat.count
                    left = pat[idx]
                }
            }
            i += 1
        }
    }
    return out
}
