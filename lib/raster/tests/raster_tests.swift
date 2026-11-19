// Host tests for lib/raster: coverage areas against exact geometry, fill
// rules, clipping, the stroker and dashes, trig, and a fuzz run.

private func area(_ p: RasterPath, _ rule: RasterFillRule = .nonZero,
                  clip: RasterRect = RasterRect(x0: -1000, y0: -1000, x1: 1000, y1: 1000)) -> Double {
    var s = 0
    rasterFill(p, rule: rule, clip: clip) { _, _, cov in
        for c in cov { s += Int(c) }
    }
    return Double(s) / 255
}

private func rect(_ p: inout RasterPath, _ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float, reverse: Bool = false) {
    p.moveTo(x0, y0)
    if reverse { p.lineTo(x0, y1); p.lineTo(x1, y1); p.lineTo(x1, y0) } else { p.lineTo(x1, y0); p.lineTo(x1, y1); p.lineTo(x0, y1) }
    p.close()
}

private func circle(_ p: inout RasterPath, _ cx: Float, _ cy: Float, _ r: Float) {
    let k: Float = 0.5522847498 * r
    p.moveTo(cx + r, cy)
    p.cubicTo(cx + r, cy + k, cx + k, cy + r, cx, cy + r)
    p.cubicTo(cx - k, cy + r, cx - r, cy + k, cx - r, cy)
    p.cubicTo(cx - r, cy - k, cx - k, cy - r, cx, cy - r)
    p.cubicTo(cx + k, cy - r, cx + r, cy - k, cx + r, cy)
    p.close()
}

private func near(_ a: Double, _ b: Double, _ tol: Double) -> Bool { abs(a - b) <= tol }

func libTests(_ t: Tests) {
    t.section("math")
    var worst = 0.0
    var x = -20.0
    while x < 20 {
        // sin^2 + cos^2 and atan2 round trip
        let s = rasterSin(x), c = rasterCos(x)
        worst = max(worst, abs(s * s + c * c - 1))
        let a = rasterAtan2(s, c)
        let back = x - 2 * rasterPi * ((x - a) / (2 * rasterPi)).rounded()
        worst = max(worst, abs(back - a))
        x += 0.0137
    }
    t.check(worst < 1e-9, "trig identities", "\(worst)")
    t.check(near(rasterSin(rasterPi / 6), 0.5, 1e-12), "sin 30")
    t.check(near(rasterAcos(0.5), rasterPi / 3, 1e-10), "acos")
    t.check(rasterSin(Double.nan) == 0 && rasterAtan2(.infinity, 1) == 0, "non-finite")

    t.section("fill")
    var sq = RasterPath()
    rect(&sq, 1.5, 2.25, 11.5, 7.25)
    t.check(near(area(sq), 50, 0.05), "rect area", "\(area(sq))")
    var c = RasterPath()
    circle(&c, 20, 20, 10)
    t.check(near(area(c), Double.pi * 100, 4), "circle area", "\(area(c))")
    // Two same-direction squares: nonzero fills the hole, evenodd doesn't.
    var two = RasterPath()
    rect(&two, 0, 0, 20, 20)
    rect(&two, 5, 5, 15, 15)
    t.check(near(area(two, .nonZero), 400, 0.1), "nonzero overlap", "\(area(two))")
    t.check(near(area(two, .evenOdd), 300, 0.1), "evenodd hole", "\(area(two, .evenOdd))")
    var rev = RasterPath()
    rect(&rev, 0, 0, 20, 20)
    rect(&rev, 5, 5, 15, 15, reverse: true)
    t.check(near(area(rev, .nonZero), 300, 0.1), "nonzero reversed hole")
    // Fractional overlap: evenodd folds partial coverage.
    var half = RasterPath()
    rect(&half, 0, 0, 10, 10)
    rect(&half, 0.5, 0, 10, 10)
    t.check(near(area(half, .evenOdd), 5, 0.05), "evenodd fold", "\(area(half, .evenOdd))")
    // Clipping, including edges left of the clip.
    let clip = RasterRect(x0: 5, y0: 5, x1: 8, y1: 9)
    t.check(near(area(sq, clip: clip), 6.75, 0.01), "clip", "\(area(sq, clip: clip))")
    var big = RasterPath()
    rect(&big, -1e9, -1e9, 1e9, 1e9)
    t.check(near(area(big, clip: RasterRect(x0: 0, y0: 0, x1: 100, y1: 50)), 5000, 0.5), "huge rect clipped")
    var rows = Set<Int>()
    rasterFill(sq, rule: .nonZero, clip: RasterRect(x0: 0, y0: 0, x1: 100, y1: 100)) { y, x0, cov in
        rows.insert(y)
        _ = x0; _ = cov
    }
    t.equal(rows.count, 6, "rows touched")
    // Bands: a tall path crosses several.
    var tall = RasterPath()
    rect(&tall, 0, 0, 3000, 300)
    t.check(near(area(tall, clip: RasterRect(x0: 0, y0: 0, x1: 4000, y1: 4000)), 900_000, 1), "banded")
    var nan = RasterPath()
    nan.moveTo(.nan, 0); nan.lineTo(.infinity, 5); nan.lineTo(-.infinity, .nan); nan.close()
    _ = area(nan)
    t.check(true, "nan safe")
    var m = RasterMask(x: 0, y: 0, width: 30, height: 30)
    rasterFillMask(sq, rule: .nonZero, into: &m)
    t.equal(Int(m.at(5, 4)), 255, "mask inside")
    t.equal(Int(m.at(1, 4)), 128, "mask half pixel")
    t.equal(Int(m.at(50, 4)), 0, "mask outside")

    t.section("transform")
    let tr = RasterTransform.translate(10, 5).concat(.scale(2, 3))
    let (tx, ty) = tr.apply(1, 1)
    t.check(near(tx, 12, 1e-9) && near(ty, 8, 1e-9), "concat order")
    if let inv = tr.inverted() {
        let (bx, by) = inv.apply(tx, ty)
        t.check(near(bx, 1, 1e-9) && near(by, 1, 1e-9), "inverse")
    } else { t.check(false, "invertible") }
    t.check(RasterTransform.scale(0, 1).inverted() == nil, "singular")

    t.section("stroke")
    var ln = RasterPath()
    ln.moveTo(10, 10); ln.lineTo(30, 10)
    var st = RasterStrokeStyle()
    st.width = 4
    t.check(near(area(rasterStroke(ln, st)), 80, 0.1), "butt line", "\(area(rasterStroke(ln, st)))")
    st.cap = .square
    t.check(near(area(rasterStroke(ln, st)), 96, 0.1), "square caps")
    st.cap = .round
    t.check(near(area(rasterStroke(ln, st)), 80 + Double.pi * 4, 0.6), "round caps", "\(area(rasterStroke(ln, st)))")
    // A right angle: miter adds the corner square, bevel half of it.
    var corner = RasterPath()
    corner.moveTo(10, 10); corner.lineTo(30, 10); corner.lineTo(30, 30)
    st.cap = .butt
    st.join = .miter
    t.check(near(area(rasterStroke(corner, st)), 160, 0.2), "miter corner", "\(area(rasterStroke(corner, st)))")
    st.join = .bevel
    t.check(near(area(rasterStroke(corner, st)), 158, 0.2), "bevel corner", "\(area(rasterStroke(corner, st)))")
    st.join = .round
    t.check(near(area(rasterStroke(corner, st)), 156 + Double.pi, 0.3), "round corner", "\(area(rasterStroke(corner, st)))")
    // A sharp angle beyond the miter limit falls back to bevel.
    var sharp = RasterPath()
    sharp.moveTo(0, 0); sharp.lineTo(40, 0); sharp.lineTo(0, 3)
    st.join = .miter; st.miterLimit = 4
    let a1 = area(rasterStroke(sharp, st))
    st.miterLimit = 100
    let a2 = area(rasterStroke(sharp, st))
    t.check(a2 > a1 + 10, "miter limit", "\(a1) \(a2)")
    // Closed square outline: ring area.
    var box = RasterPath()
    rect(&box, 10, 10, 30, 30)
    st.join = .miter; st.miterLimit = 4
    t.check(near(area(rasterStroke(box, st)), 24 * 24 - 16 * 16, 0.2), "closed ring", "\(area(rasterStroke(box, st)))")
    var dot = RasterPath()
    dot.moveTo(50, 50); dot.lineTo(50, 50)
    st.cap = .round
    t.check(near(area(rasterStroke(dot, st)), Double.pi * 4, 0.6), "zero-length round dot", "\(area(rasterStroke(dot, st))) \(dbgShoelace(rasterStroke(dot, st)))")
    st.cap = .butt
    t.check(area(rasterStroke(dot, st)) == 0, "zero-length butt")

    t.section("dash")
    var long = RasterPath()
    long.moveTo(0, 10); long.lineTo(100, 10)
    let d = rasterDash(long, [10, 5], offset: 0)
    t.equal(d.starts.count, 7, "dash count")
    st.width = 2; st.cap = .butt
    t.check(near(area(rasterStroke(d, st)), 2 * 70, 0.2), "dash area", "\(area(rasterStroke(d, st)))")
    let d2 = rasterDash(long, [10, 5], offset: 5)
    t.check(near(area(rasterStroke(d2, st)), 2 * 65, 0.3), "dash offset", "\(area(rasterStroke(d2, st)))")
    t.equal(rasterDash(long, [0.0001, 0.0001], offset: 0).starts.count, 1, "too many dashes: solid")
    t.equal(rasterDash(long, [-1, 2], offset: 0).starts.count, 1, "negative: solid")
    let dots = rasterDash(long, [0, 10], offset: 0)
    st.cap = .round
    t.check(near(area(rasterStroke(dots, st)), 10 * Double.pi, 2.5), "zero dashes with round caps", "\(area(rasterStroke(dots, st)))")

    t.section("fuzz")
    var rng = TestRandom(seed: 42)
    for _ in 0..<3000 {
        var p = RasterPath()
        let n = 1 + rng.below(12)
        func v() -> Float {
            switch rng.below(10) {
            case 0: return .nan
            case 1: return Float(rng.below(2_000_000)) - 1e6
            case 2: return .infinity
            default: return Float(rng.below(4000)) / 40 - 20
            }
        }
        for _ in 0..<n {
            switch rng.below(5) {
            case 0: p.moveTo(v(), v())
            case 1: p.lineTo(v(), v())
            case 2: p.quadTo(v(), v(), v(), v())
            case 3: p.cubicTo(v(), v(), v(), v(), v(), v())
            default: p.close()
            }
        }
        _ = area(p, rng.below(2) == 0 ? .nonZero : .evenOdd, clip: RasterRect(x0: 0, y0: 0, x1: 64, y1: 64))
        var s = RasterStrokeStyle()
        s.width = v(); s.miterLimit = v()
        s.cap = RasterLineCap(rawValue: UInt8(rng.below(3))) ?? .butt
        s.join = RasterLineJoin(rawValue: UInt8(rng.below(3))) ?? .miter
        let dashed = rasterDash(p, [v(), v(), v()], offset: v())
        _ = area(rasterStroke(dashed, s, maxPoints: 100_000), .nonZero, clip: RasterRect(x0: 0, y0: 0, x1: 64, y1: 64))
    }
    t.check(true, "fuzz survived")
}

func dbgShoelace(_ p: RasterPath) -> String {
    var out = ""
    for k in 0..<p.starts.count {
        let r = p.contour(k)
        var a: Double = 0
        for i in r {
            let j = i + 1 < r.upperBound ? i + 1 : r.lowerBound
            a += Double(p.xs[i]) * Double(p.ys[j]) - Double(p.xs[j]) * Double(p.ys[i])
        }
        out += "c\(k) n=\(r.count) a=\(a / 2) "
    }
    return out
}
