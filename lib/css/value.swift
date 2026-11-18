// Specified values: lengths, percentages and calc() as a linear expression
// that is resolved against the element's font size and the viewport at
// computed-value time, leaving (px, percentage) for layout.

enum CSSComponent {
    case token(CSSToken)
    case function(String, [CSSComponent])
    case block(UInt8, [CSSComponent])      // 0x28 '(', 0x5b '[', 0x7b '{'
}

/// Where the cascade evaluates media queries and viewport units.
struct CSSContext {
    var viewportWidth: Double = 1024
    var viewportHeight: Double = 768
    /// Computed font-size of the root element, for `rem`. The resolver updates
    /// it after it computes the root element's style.
    var rootFontSize: Double = 16
    /// font-size: medium.
    var defaultFontSize: Double = 16
    var printMedia = false
    var darkColorScheme = false
    init() {}
}

/// A linear combination of units, plus optional bounds for min()/max()/clamp().
struct CSSCalc {
    var px = 0.0, em = 0.0, rem = 0.0, vw = 0.0, vh = 0.0, vmin = 0.0, vmax = 0.0
    var pct = 0.0
    var num = 0.0
    /// A pure number (only `num` is meaningful).
    var isNumber = false
    var los: [CSSCalc] = []
    var his: [CSSCalc] = []

    var hasBounds: Bool { !los.isEmpty || !his.isEmpty }
    var hasLengthUnits: Bool { px != 0 || em != 0 || rem != 0 || vw != 0 || vh != 0 || vmin != 0 || vmax != 0 }

    init() {}
    static func number(_ v: Double) -> CSSCalc { var c = CSSCalc(); c.num = v; c.isNumber = true; return c }
    static func px(_ v: Double) -> CSSCalc { var c = CSSCalc(); c.px = v; return c }
    static func percent(_ v: Double) -> CSSCalc { var c = CSSCalc(); c.pct = v; return c }

    /// The single plain value, if this is just "N px" (no relative units).
    var isPlain: Bool { !isNumber && !hasBounds && em == 0 && rem == 0 && vw == 0 && vh == 0 && vmin == 0 && vmax == 0 && pct == 0 }
    var isNegativeLiteral: Bool {
        if hasBounds { return false }
        let all = [px, em, rem, vw, vh, vmin, vmax, pct]
        var neg = false
        for v in all { if v > 0 { return false }; if v < 0 { neg = true } }
        return neg
    }

    func scaled(_ k: Double) -> CSSCalc {
        var c = self
        c.px *= k; c.em *= k; c.rem *= k; c.vw *= k; c.vh *= k; c.vmin *= k; c.vmax *= k
        c.pct *= k; c.num *= k
        return c
    }

    func adding(_ o: CSSCalc) -> CSSCalc? {
        if isNumber != o.isNumber || hasBounds || o.hasBounds { return nil }
        var c = self
        c.px += o.px; c.em += o.em; c.rem += o.rem; c.vw += o.vw; c.vh += o.vh
        c.vmin += o.vmin; c.vmax += o.vmax; c.pct += o.pct; c.num += o.num
        return c
    }
}

/// Computed length-percentage: used value = clamp(px + pct% * base, lo, hi).
struct CSSLP {
    var px = 0.0
    var pct = 0.0
    var lo: Float = -Float.greatestFiniteMagnitude
    var hi: Float = Float.greatestFiniteMagnitude
    init() {}
    init(px: Double, pct: Double = 0) { self.px = px; self.pct = pct }
    static let zero = CSSLP()
    var hasPercent: Bool { pct != 0 }
    /// Resolve against `base` (the containing block's size, when a percentage applies).
    func resolve(_ base: Double) -> Double {
        var v = px + pct * base / 100
        if lo > -Float.greatestFiniteMagnitude { v = max(v, Double(lo)) }
        if hi < Float.greatestFiniteMagnitude { v = min(v, Double(hi)) }
        return v
    }
}

func cssResolveCalc(_ c: CSSCalc, fontSize: Double, ctx: CSSContext) -> CSSLP {
    func lin(_ k: CSSCalc) -> Double {
        k.px + k.em * fontSize + k.rem * ctx.rootFontSize + k.vw * ctx.viewportWidth / 100
            + k.vh * ctx.viewportHeight / 100
            + k.vmin * min(ctx.viewportWidth, ctx.viewportHeight) / 100
            + k.vmax * max(ctx.viewportWidth, ctx.viewportHeight) / 100
    }
    var r = CSSLP()
    r.px = c.isNumber ? c.num : lin(c)
    r.pct = c.pct
    for b in c.los {
        let v = Float(max(-3e38, min(3e38, lin(b))))
        r.lo = r.lo > -Float.greatestFiniteMagnitude ? max(r.lo, v) : v
    }
    for b in c.his {
        let v = Float(max(-3e38, min(3e38, lin(b))))
        r.hi = r.hi < Float.greatestFiniteMagnitude ? min(r.hi, v) : v
    }
    return r
}

enum CSSDimensionKind: UInt8 { case auto, length, none, minContent, maxContent, fitContent }

/// A computed width/height/margin/inset: `auto`, `none`, or a length-percentage.
struct CSSDimension {
    var kind: CSSDimensionKind = .length
    var lp = CSSLP()
    init() {}
    init(px: Double) { lp = CSSLP(px: px) }
    init(kind: CSSDimensionKind) { self.kind = kind }
    static let auto = CSSDimension(kind: .auto)
    static let none = CSSDimension(kind: .none)
    static let zero = CSSDimension()
    var isAuto: Bool { kind == .auto }
    var isLength: Bool { kind == .length }
    var hasPercent: Bool { kind == .length && lp.pct != 0 }
    /// The used px value when this is a length (percentages against `base`), else nil.
    func resolve(_ base: Double) -> Double? { kind == .length ? lp.resolve(base) : nil }
}

enum CSSValue {
    case ident(String)                // lowercased keyword
    case keyword(UInt8)               // index into the property's keyword table
    case number(Double, Bool)         // value, is integer
    case dimension(CSSCalc)           // length, percentage or calc
    case color(CSSColorValue)
    case string(String)
    case url(String)
    case list([CSSValue])
}

// MARK: - Parsing

let cssMaxCalcDepth = 12

private func cssUnitScale(_ u: String) -> CSSCalc? {
    var c = CSSCalc()
    switch cssLower(u) {
    case "px": c.px = 1
    case "em": c.em = 1
    case "rem": c.rem = 1
    case "ex": c.em = 0.5
    case "ch": c.em = 0.5
    case "vw", "svw", "lvw", "dvw", "vi", "svi", "lvi", "dvi": c.vw = 1
    case "vh", "svh", "lvh", "dvh", "vb", "svb", "lvb", "dvb": c.vh = 1
    case "vmin", "svmin", "lvmin", "dvmin": c.vmin = 1
    case "vmax", "svmax", "lvmax", "dvmax": c.vmax = 1
    case "pt": c.px = 4.0 / 3.0
    case "pc": c.px = 16
    case "in": c.px = 96
    case "cm": c.px = 96 / 2.54
    case "mm": c.px = 96 / 25.4
    case "q": c.px = 96 / 101.6
    default: return nil
    }
    return c
}

/// A dimension/percentage token as a calc value (no plain numbers).
func cssLengthFromToken(_ t: CSSToken) -> CSSCalc? {
    switch t {
    case .dimension(let v, let u, _):
        guard let s = cssUnitScale(u) else { return nil }
        return s.scaled(v)
    case .percentage(let v): return CSSCalc.percent(v)
    default: return nil
    }
}

private struct CSSCalcParser {
    let c: [CSSComponent]
    var i = 0

    mutating func parseSum(_ depth: Int) -> CSSCalc? {
        guard depth < cssMaxCalcDepth, var acc = parseProduct(depth) else { return nil }
        while i < c.count {
            guard case .token(.delim(let op)) = c[i], op == 0x2b || op == 0x2d else { return nil }
            i += 1
            guard let rhs = parseProduct(depth) else { return nil }
            guard let s = acc.adding(op == 0x2b ? rhs : rhs.scaled(-1)) else { return nil }
            acc = s
        }
        return acc
    }

    mutating func parseProduct(_ depth: Int) -> CSSCalc? {
        guard var acc = parseFactor(depth) else { return nil }
        while i < c.count {
            guard case .token(.delim(let op)) = c[i] else { return nil }
            if op == 0x2b || op == 0x2d { return acc }
            guard op == 0x2a || op == 0x2f else { return nil }
            i += 1
            guard let rhs = parseFactor(depth) else { return nil }
            if acc.hasBounds || rhs.hasBounds { return nil }
            if op == 0x2a {
                if rhs.isNumber { acc = acc.scaled(rhs.num) }
                else if acc.isNumber { acc = rhs.scaled(acc.num) }
                else { return nil }
            } else {
                guard rhs.isNumber, rhs.num != 0 else { return nil }
                acc = acc.scaled(1 / rhs.num)
            }
        }
        return acc
    }

    mutating func parseFactor(_ depth: Int) -> CSSCalc? {
        guard i < c.count else { return nil }
        let item = c[i]
        i += 1
        switch item {
        case .token(.number(let v, _)): return CSSCalc.number(v)
        case .token(let t): return cssLengthFromToken(t)
        case .block(0x28, let inner):
            var p = CSSCalcParser(c: inner)
            guard let r = p.parseSum(depth + 1), p.i == inner.count else { return nil }
            return r
        case .function(let name, let args):
            return cssParseMathFunction(cssLower(name), args, depth + 1)
        default: return nil
        }
    }
}

private func cssSplitCommas(_ comps: [CSSComponent]) -> [[CSSComponent]] {
    var out: [[CSSComponent]] = [[]]
    for c in comps {
        if case .token(.comma) = c { out.append([]) } else { out[out.count - 1].append(c) }
    }
    return out
}

func cssParseMathFunction(_ name: String, _ args: [CSSComponent], _ depth: Int) -> CSSCalc? {
    if depth >= cssMaxCalcDepth { return nil }
    switch name {
    case "calc", "-webkit-calc", "-moz-calc":
        var p = CSSCalcParser(c: args)
        guard let r = p.parseSum(depth), p.i == args.count else { return nil }
        return r
    case "min", "max", "clamp":
        let parts = cssSplitCommas(args)
        var vals: [CSSCalc] = []
        for part in parts {
            var p = CSSCalcParser(c: part)
            guard let r = p.parseSum(depth), p.i == part.count, !r.hasBounds else { return nil }
            vals.append(r)
        }
        if name == "clamp" {
            guard vals.count == 3, vals[0].isNumber == vals[1].isNumber, vals[1].isNumber == vals[2].isNumber else { return nil }
            var r = vals[1]
            r.los = [vals[0]]; r.his = [vals[2]]
            return r
        }
        guard vals.count >= 1 else { return nil }
        for v in vals where v.isNumber != vals[0].isNumber { return nil }
        // The base term is the one carrying a percentage; the rest are bounds.
        var base = 0
        var found = 0
        for (k, v) in vals.enumerated() where v.pct != 0 { base = k; found += 1 }
        if found > 1 { return nil }
        var r = vals[base]
        for (k, v) in vals.enumerated() where k != base {
            if name == "min" { r.his.append(v) } else { r.los.append(v) }
        }
        return r
    default: return nil
    }
}

/// A length, percentage or calc-family function; a bare 0 counts as a length.
func cssParseLengthPercentage(_ c: CSSComponent) -> CSSCalc? {
    switch c {
    case .token(.number(let v, _)):
        return v == 0 ? CSSCalc() : nil
    case .token(let t): return cssLengthFromToken(t)
    case .function(let n, let args):
        guard let r = cssParseMathFunction(cssLower(n), args, 0), !r.isNumber else { return nil }
        return r
    default: return nil
    }
}

/// A number (including calc() that yields a number).
func cssParseNumber(_ c: CSSComponent) -> (Double, Bool)? {
    switch c {
    case .token(.number(let v, let isInt)): return (v, isInt)
    case .function(let n, let args):
        guard let r = cssParseMathFunction(cssLower(n), args, 0), r.isNumber, !r.hasBounds else { return nil }
        return (r.num, false)
    default: return nil
    }
}
