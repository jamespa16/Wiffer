// SVG attribute micro-syntaxes: numbers (with the compact forms such as
// "1.5.5" and "-1-2"), lengths, viewBox, preserveAspectRatio, transform
// lists, points and path data (every command; elliptical arcs become
// cubics). Everything is sanitized: non-finite numbers are rejected and
// magnitudes clamped, so later geometry can't trap.

let svgMaxNumber = 1e9

@inline(__always) func svgSan(_ v: Double) -> Double {
    if v != v { return 0 }
    return max(-svgMaxNumber, min(svgMaxNumber, v))
}

struct SVGScanner {
    let b: [UInt8]
    var i = 0
    init(_ s: String) { b = Array(s.utf8) }

    var atEnd: Bool { i >= b.count }
    var peek: UInt8 { i < b.count ? b[i] : 0 }

    mutating func skipSpace() {
        while i < b.count && (b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0a || b[i] == 0x0d || b[i] == 0x0c) { i += 1 }
    }
    /// Whitespace and at most one comma.
    mutating func skipSep() {
        skipSpace()
        if i < b.count && b[i] == 0x2c { i += 1; skipSpace() }
    }

    /// A number: [sign] digits [. digits] [e [sign] digits]. Parsing stops
    /// at a second '.', so "1.5.5" is 1.5 then .5.
    mutating func number() -> Double? {
        let start = i
        var k = i
        var neg = false
        if k < b.count && (b[k] == 0x2b || b[k] == 0x2d) { neg = b[k] == 0x2d; k += 1 }
        var mant: Double = 0
        var digits = 0
        var scale = 0
        while k < b.count && b[k] >= 0x30 && b[k] <= 0x39 {
            if digits < 18 { mant = mant * 10 + Double(b[k] - 0x30) } else { scale += 1 }
            digits += 1; k += 1
        }
        if k < b.count && b[k] == 0x2e {
            k += 1
            var frac = 0
            while k < b.count && b[k] >= 0x30 && b[k] <= 0x39 {
                if digits < 18 { mant = mant * 10 + Double(b[k] - 0x30); scale -= 1 }
                digits += 1; frac += 1; k += 1
            }
            if frac == 0 && digits == 0 { i = start; return nil }
        }
        if digits == 0 { i = start; return nil }
        if k < b.count && (b[k] == 0x65 || b[k] == 0x45) {
            // An exponent only if digits follow ("1em" is a unit).
            var e = k + 1
            var eneg = false
            if e < b.count && (b[e] == 0x2b || b[e] == 0x2d) { eneg = b[e] == 0x2d; e += 1 }
            if e < b.count && b[e] >= 0x30 && b[e] <= 0x39 {
                var ev = 0
                while e < b.count && b[e] >= 0x30 && b[e] <= 0x39 {
                    if ev < 10_000 { ev = ev * 10 + Int(b[e] - 0x30) }
                    e += 1
                }
                scale += eneg ? -ev : ev
                k = e
            }
        }
        i = k
        var v = mant
        if scale != 0 {
            let s = max(-400, min(400, scale))
            var p = 1.0
            var n = abs(s)
            var base = 10.0
            while n > 0 { if n & 1 == 1 { p *= base }; base *= base; n >>= 1 }
            v = s > 0 ? v * p : v / p
        }
        if !v.isFinite { v = svgMaxNumber }
        return svgSan(neg ? -v : v)
    }

    /// An arc flag: a single 0 or 1 (no separator needed after it).
    mutating func flag() -> Bool? {
        skipSep()
        guard i < b.count else { return nil }
        if b[i] == 0x30 { i += 1; return false }
        if b[i] == 0x31 { i += 1; return true }
        return nil
    }

    /// Identifier letters (for units and keywords).
    mutating func word() -> String {
        let s = i
        while i < b.count && ((b[i] >= 0x61 && b[i] <= 0x7a) || (b[i] >= 0x41 && b[i] <= 0x5a) || b[i] == 0x25 || b[i] == 0x2d) { i += 1 }
        return String(decoding: b[s..<i], as: UTF8.self)
    }
}

// MARK: - Lengths

enum SVGUnit: UInt8 { case user, px, em, ex, percent, inch, cm, mm, pt, pc, rem }

struct SVGLength {
    var value: Double
    var unit: SVGUnit
    init(_ v: Double, _ u: SVGUnit = .user) { value = v; unit = u }

    /// In user units. `percentBase` is what 100% means (a viewport width,
    /// height or normalized diagonal).
    func resolve(fontSize: Double, percentBase: Double) -> Double {
        let fs = fontSize.isFinite && fontSize > 0 ? fontSize : 16
        let r: Double
        switch unit {
        case .user, .px: r = value
        case .em, .rem: r = value * fs
        case .ex: r = value * fs / 2
        case .percent: r = value * percentBase / 100
        case .inch: r = value * 96
        case .cm: r = value * 96 / 2.54
        case .mm: r = value * 96 / 25.4
        case .pt: r = value * 4 / 3
        case .pc: r = value * 16
        }
        return svgSan(r)
    }
}

func svgParseLength(_ s: String) -> SVGLength? {
    var sc = SVGScanner(s)
    sc.skipSpace()
    guard let v = sc.number() else { return nil }
    let w = sc.word()
    sc.skipSpace()
    guard sc.atEnd else { return nil }
    let u: SVGUnit
    switch cssLower(w) {
    case "": u = .user
    case "px": u = .px
    case "em": u = .em
    case "rem": u = .rem
    case "ex": u = .ex
    case "%": u = .percent
    case "in": u = .inch
    case "cm": u = .cm
    case "mm": u = .mm
    case "pt": u = .pt
    case "pc": u = .pc
    default: return nil
    }
    return SVGLength(v, u)
}

/// A list of numbers separated by whitespace and/or commas.
func svgParseNumbers(_ s: String, max n: Int = 1_000_000) -> [Double] {
    var sc = SVGScanner(s)
    var out: [Double] = []
    sc.skipSpace()
    while !sc.atEnd && out.count < n {
        guard let v = sc.number() else { break }
        out.append(v)
        sc.skipSep()
    }
    return out
}

struct SVGViewBox {
    var x: Double, y: Double, w: Double, h: Double
}

func svgParseViewBox(_ s: String) -> SVGViewBox? {
    let v = svgParseNumbers(s, max: 5)
    guard v.count == 4, v[2] > 0, v[3] > 0 else { return nil }
    return SVGViewBox(x: v[0], y: v[1], w: v[2], h: v[3])
}

struct SVGAspect {
    /// 0 min, 1 mid, 2 max; nil align = none.
    var alignX: Int? = 1
    var alignY: Int? = 1
    var slice = false
    init() {}
}

func svgParseAspect(_ s: String?) -> SVGAspect {
    var a = SVGAspect()
    guard let s = s else { return a }
    var words: [String] = []
    var cur = ""
    for c in s { if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "," { if !cur.isEmpty { words.append(cur); cur = "" } } else { cur.append(c) } }
    if !cur.isEmpty { words.append(cur) }
    var k = 0
    if k < words.count && words[k] == "defer" { k += 1 }
    guard k < words.count else { return a }
    let al = words[k]
    if al == "none" { a.alignX = nil; a.alignY = nil }
    else {
        let u = Array(al.utf8)
        guard u.count == 8 else { return SVGAspect() }
        func axis(_ t: ArraySlice<UInt8>) -> Int? {
            switch String(decoding: t, as: UTF8.self) {
            case "Min": return 0
            case "Mid": return 1
            case "Max": return 2
            default: return nil
            }
        }
        guard u[0] == 0x78, u[4] == 0x59, let x = axis(u[1..<4]), let y = axis(u[5..<8]) else { return SVGAspect() }
        a.alignX = x; a.alignY = y
    }
    if k + 1 < words.count && words[k + 1] == "slice" { a.slice = true }
    return a
}

/// The transform mapping a viewBox onto a viewport (x, y, w, h).
func svgViewBoxTransform(_ vb: SVGViewBox, _ a: SVGAspect, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> RasterTransform {
    var sx = w / vb.w, sy = h / vb.h
    guard sx.isFinite && sy.isFinite else { return .identity }
    var tx = x - vb.x * sx, ty = y - vb.y * sy
    if let ax = a.alignX, let ay = a.alignY {
        let s = a.slice ? max(sx, sy) : min(sx, sy)
        sx = s; sy = s
        let freeX = w - vb.w * s, freeY = h - vb.h * s
        tx = x - vb.x * s + freeX * Double(ax) / 2
        ty = y - vb.y * s + freeY * Double(ay) / 2
    }
    return RasterTransform(sx, 0, 0, sy, tx, ty)
}

// MARK: - Transforms

/// A transform list; nil if it is invalid (the attribute is then ignored).
func svgParseTransform(_ s: String) -> RasterTransform? {
    var sc = SVGScanner(s)
    var t = RasterTransform.identity
    var steps = 0
    sc.skipSpace()
    while !sc.atEnd && steps < 1000 {
        steps += 1
        let name = sc.word()
        sc.skipSpace()
        guard sc.peek == 0x28 else { return nil }
        sc.i += 1
        var args: [Double] = []
        sc.skipSpace()
        while !sc.atEnd && sc.peek != 0x29 && args.count < 7 {
            guard let v = sc.number() else { return nil }
            args.append(v)
            sc.skipSep()
        }
        guard sc.peek == 0x29 else { return nil }
        sc.i += 1
        var m: RasterTransform
        switch name {
        case "matrix":
            guard args.count == 6 else { return nil }
            m = RasterTransform(args[0], args[1], args[2], args[3], args[4], args[5])
        case "translate":
            guard args.count == 1 || args.count == 2 else { return nil }
            m = .translate(args[0], args.count == 2 ? args[1] : 0)
        case "scale":
            guard args.count == 1 || args.count == 2 else { return nil }
            m = .scale(args[0], args.count == 2 ? args[1] : args[0])
        case "rotate":
            guard args.count == 1 || args.count == 3 else { return nil }
            let r = args[0] * rasterPi / 180
            let c = rasterCos(r), sn = rasterSin(r)
            m = RasterTransform(c, sn, -sn, c, 0, 0)
            if args.count == 3 {
                m = RasterTransform.translate(-args[1], -args[2]).then(m).then(.translate(args[1], args[2]))
            }
        case "skewX":
            guard args.count == 1 else { return nil }
            let r = args[0] * rasterPi / 180
            m = RasterTransform(1, 0, rasterSin(r) / rasterCos(r), 1, 0, 0)
        case "skewY":
            guard args.count == 1 else { return nil }
            let r = args[0] * rasterPi / 180
            m = RasterTransform(1, rasterSin(r) / rasterCos(r), 0, 1, 0, 0)
        default: return nil
        }
        if !m.isFinite { return nil }
        // Later transforms in the list apply first (closest to the content).
        t = t.concat(m)
        sc.skipSep()
    }
    return t
}

// MARK: - Paths

enum SVGPathOp: UInt8 { case move, line, quad, cubic, close }

/// Path geometry in user units: ops with their points (move/line 1, quad 2,
/// cubic 3, close 0).
struct SVGPath {
    var ops: [SVGPathOp] = []
    var pts: [Double] = []
    init() {}
    var isEmpty: Bool { ops.isEmpty }

    mutating func move(_ x: Double, _ y: Double) { ops.append(.move); pts.append(svgSan(x)); pts.append(svgSan(y)) }
    mutating func line(_ x: Double, _ y: Double) { ops.append(.line); pts.append(svgSan(x)); pts.append(svgSan(y)) }
    mutating func quad(_ x1: Double, _ y1: Double, _ x: Double, _ y: Double) {
        ops.append(.quad); pts.append(svgSan(x1)); pts.append(svgSan(y1)); pts.append(svgSan(x)); pts.append(svgSan(y))
    }
    mutating func cubic(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double, _ y: Double) {
        ops.append(.cubic)
        pts.append(svgSan(x1)); pts.append(svgSan(y1)); pts.append(svgSan(x2)); pts.append(svgSan(y2))
        pts.append(svgSan(x)); pts.append(svgSan(y))
    }
    mutating func close() { ops.append(.close) }

    /// Flatten through `t` (user to device) with a device tolerance.
    /// `userSpace`: keep user coordinates (for stroking), with the tolerance
    /// scaled so the result is still fine enough once transformed.
    func flatten(_ t: RasterTransform, tolerance: Double = 0.1, userSpace: Bool = false, maxPoints: Int = 2_000_000) -> RasterPath {
        let scale = max(1e-6, min(1e6, t.maxScale))
        var p = RasterPath(tolerance: Float(userSpace ? tolerance / scale : tolerance))
        p.maxPoints = maxPoints
        var k = 0
        func pt(_ i: Int) -> (Float, Float) {
            if userSpace { return (rasterSanD(pts[i]), rasterSanD(pts[i + 1])) }
            let (x, y) = t.apply(pts[i], pts[i + 1])
            return (rasterSanD(x), rasterSanD(y))
        }
        for op in ops {
            switch op {
            case .move:
                guard k + 2 <= pts.count else { return p }
                let (x, y) = pt(k); p.moveTo(x, y); k += 2
            case .line:
                guard k + 2 <= pts.count else { return p }
                let (x, y) = pt(k); p.lineTo(x, y); k += 2
            case .quad:
                guard k + 4 <= pts.count else { return p }
                let (x1, y1) = pt(k), (x, y) = pt(k + 2); p.quadTo(x1, y1, x, y); k += 4
            case .cubic:
                guard k + 6 <= pts.count else { return p }
                let (x1, y1) = pt(k), (x2, y2) = pt(k + 2), (x, y) = pt(k + 4)
                p.cubicTo(x1, y1, x2, y2, x, y); k += 6
            case .close: p.close()
            }
            if p.overflow { break }
        }
        return p
    }
}

/// Elliptical arc (SVG endpoint parameterization) as cubics appended to `p`.
func svgArc(_ p: inout SVGPath, _ x0: Double, _ y0: Double, _ rx0: Double, _ ry0: Double, _ angle: Double,
            _ large: Bool, _ sweep: Bool, _ x: Double, _ y: Double) {
    if x0 == x && y0 == y { return }
    var rx = abs(rx0), ry = abs(ry0)
    if rx == 0 || ry == 0 || !rx.isFinite || !ry.isFinite { p.line(x, y); return }
    let phi = angle * rasterPi / 180
    let cp = rasterCos(phi), sp = rasterSin(phi)
    let dx = (x0 - x) / 2, dy = (y0 - y) / 2
    let x1p = cp * dx + sp * dy, y1p = -sp * dx + cp * dy
    // Scale up radii that are too small.
    let lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
    if lam > 1 { let s = lam.squareRoot(); rx *= s; ry *= s }
    let rx2 = rx * rx, ry2 = ry * ry
    var num = rx2 * ry2 - rx2 * y1p * y1p - ry2 * x1p * x1p
    if num < 0 { num = 0 }
    let den = rx2 * y1p * y1p + ry2 * x1p * x1p
    var coef = den > 0 ? (num / den).squareRoot() : 0
    if large == sweep { coef = -coef }
    let cxp = coef * rx * y1p / ry, cyp = -coef * ry * x1p / rx
    let cx = cp * cxp - sp * cyp + (x0 + x) / 2
    let cy = sp * cxp + cp * cyp + (y0 + y) / 2
    func ang(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
        rasterAtan2(ux * vy - uy * vx, ux * vx + uy * vy)
    }
    let ux = (x1p - cxp) / rx, uy = (y1p - cyp) / ry
    let vx = (-x1p - cxp) / rx, vy = (-y1p - cyp) / ry
    let theta1 = ang(1, 0, ux, uy)
    var dtheta = ang(ux, uy, vx, vy)
    if !sweep && dtheta > 0 { dtheta -= 2 * rasterPi }
    if sweep && dtheta < 0 { dtheta += 2 * rasterPi }
    guard cx.isFinite, cy.isFinite, dtheta.isFinite else { p.line(x, y); return }
    let n = max(1, min(16, Int((abs(dtheta) / (rasterPi / 2)).rounded(.up))))
    let seg = dtheta / Double(n)
    let k = 4.0 / 3.0 * rasterSin(seg / 4) / rasterCos(seg / 4)
    var t = theta1
    for i in 0..<n {
        let c1 = rasterCos(t), s1 = rasterSin(t)
        let t2 = t + seg
        let c2 = rasterCos(t2), s2 = rasterSin(t2)
        // Unit-circle control points, then scale, rotate, translate.
        let e1x = c1 - k * s1, e1y = s1 + k * c1
        let e2x = c2 + k * s2, e2y = s2 - k * c2
        func map(_ ux: Double, _ uy: Double) -> (Double, Double) {
            let px = ux * rx, py = uy * ry
            return (cp * px - sp * py + cx, sp * px + cp * py + cy)
        }
        let (ax, ay) = map(e1x, e1y), (bx, by) = map(e2x, e2y)
        var (ex, ey) = map(c2, s2)
        if i == n - 1 { ex = x; ey = y }
        p.cubic(ax, ay, bx, by, ex, ey)
        t = t2
    }
}

/// Parse path data. Stops at the first error and keeps what came before it
/// (SVG's error rule). `maxSegments` caps the commands.
func svgParsePath(_ d: String, maxSegments: Int = 200_000) -> SVGPath {
    var p = SVGPath()
    var sc = SVGScanner(d)
    var cx = 0.0, cy = 0.0          // current point
    var sx = 0.0, sy = 0.0          // subpath start
    var lcx = 0.0, lcy = 0.0        // last control point (for S/T)
    var lastCmd: UInt8 = 0
    var cmd: UInt8 = 0
    var segs = 0
    sc.skipSpace()
    while !sc.atEnd && segs < maxSegments {
        let c = sc.peek
        let isLetter = (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a)
        if isLetter {
            cmd = c
            sc.i += 1
            sc.skipSpace()
        } else if cmd == 0 || cmd == 0x7a || cmd == 0x5a {
            break   // numbers with no command (or after Z)
        }
        // After a moveto, extra coordinate pairs are linetos.
        let rel = cmd >= 0x61
        let up = rel ? cmd - 32 : cmd
        if segs == 0 && up != 0x4d { break }
        func num() -> Double? { let v = sc.number(); sc.skipSep(); return v }
        switch up {
        case 0x4d: // M
            guard let x = num(), let y = num() else { return p }
            cx = rel ? cx + x : x; cy = rel ? cy + y : y
            p.move(cx, cy)
            sx = cx; sy = cy
            cmd = rel ? 0x6c : 0x4c
        case 0x4c: // L
            guard let x = num(), let y = num() else { return p }
            cx = rel ? cx + x : x; cy = rel ? cy + y : y
            p.line(cx, cy)
        case 0x48: // H
            guard let x = num() else { return p }
            cx = rel ? cx + x : x
            p.line(cx, cy)
        case 0x56: // V
            guard let y = num() else { return p }
            cy = rel ? cy + y : y
            p.line(cx, cy)
        case 0x43: // C
            guard let x1 = num(), let y1 = num(), let x2 = num(), let y2 = num(), let x = num(), let y = num() else { return p }
            let ox = rel ? cx : 0, oy = rel ? cy : 0
            p.cubic(ox + x1, oy + y1, ox + x2, oy + y2, ox + x, oy + y)
            lcx = ox + x2; lcy = oy + y2
            cx = ox + x; cy = oy + y
        case 0x53: // S
            guard let x2 = num(), let y2 = num(), let x = num(), let y = num() else { return p }
            let ox = rel ? cx : 0, oy = rel ? cy : 0
            let lu = lastCmd >= 0x61 ? lastCmd - 32 : lastCmd
            let x1 = lu == 0x43 || lu == 0x53 ? 2 * cx - lcx : cx
            let y1 = lu == 0x43 || lu == 0x53 ? 2 * cy - lcy : cy
            p.cubic(x1, y1, ox + x2, oy + y2, ox + x, oy + y)
            lcx = ox + x2; lcy = oy + y2
            cx = ox + x; cy = oy + y
        case 0x51: // Q
            guard let x1 = num(), let y1 = num(), let x = num(), let y = num() else { return p }
            let ox = rel ? cx : 0, oy = rel ? cy : 0
            p.quad(ox + x1, oy + y1, ox + x, oy + y)
            lcx = ox + x1; lcy = oy + y1
            cx = ox + x; cy = oy + y
        case 0x54: // T
            guard let x = num(), let y = num() else { return p }
            let ox = rel ? cx : 0, oy = rel ? cy : 0
            let lu = lastCmd >= 0x61 ? lastCmd - 32 : lastCmd
            let x1 = lu == 0x51 || lu == 0x54 ? 2 * cx - lcx : cx
            let y1 = lu == 0x51 || lu == 0x54 ? 2 * cy - lcy : cy
            p.quad(x1, y1, ox + x, oy + y)
            lcx = x1; lcy = y1
            cx = ox + x; cy = oy + y
        case 0x41: // A
            guard let rx = num(), let ry = num(), let rot = num() else { return p }
            guard let large = sc.flag() else { return p }
            guard let sweep = sc.flag() else { return p }
            sc.skipSep()
            guard let x = num(), let y = num() else { return p }
            let ex = rel ? cx + x : x, ey = rel ? cy + y : y
            svgArc(&p, cx, cy, rx, ry, rot, large, sweep, ex, ey)
            cx = ex; cy = ey
        case 0x5a: // Z
            p.close()
            cx = sx; cy = sy
        default:
            return p
        }
        lastCmd = cmd
        segs += 1
        sc.skipSpace()
    }
    return p
}

/// polyline / polygon points.
func svgParsePoints(_ s: String, closed: Bool) -> SVGPath {
    let v = svgParseNumbers(s, max: 400_000)
    var p = SVGPath()
    var k = 0
    while k + 1 < v.count {
        if k == 0 { p.move(v[0], v[1]) } else { p.line(v[k], v[k + 1]) }
        k += 2
    }
    if closed && !p.isEmpty { p.close() }
    return p
}
