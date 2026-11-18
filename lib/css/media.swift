// Media queries (@media, @import ... media) and @supports.

enum CSSMediaType: UInt8 { case all, screen, print, other }
enum CSSMediaCmp: UInt8 { case eq, lt, le, gt, ge }

struct CSSMediaCondition {
    enum Kind: UInt8 { case feature, not, and, or, unknown }
    var kind = Kind.unknown
    var children: [CSSMediaCondition] = []
    var name = ""
    var cmp = CSSMediaCmp.eq
    var hasValue = false
    var number = 0.0
    var ident = ""
    var isIdent = false
}

struct CSSMediaQuery {
    var negated = false
    var type = CSSMediaType.all
    var condition: CSSMediaCondition? = nil
}

/// An empty list matches everything.
struct CSSMediaQueryList {
    var queries: [CSSMediaQuery] = []
    init() {}

    func matches(_ ctx: CSSContext) -> Bool {
        if queries.isEmpty { return true }
        for q in queries {
            var r = true
            switch q.type {
            case .all: break
            case .screen: r = !ctx.printMedia
            case .print: r = ctx.printMedia
            case .other: r = false
            }
            if r, let c = q.condition { r = cssEvalMedia(c, ctx) == 1 }
            if q.negated { r = !r }
            if r { return true }
        }
        return false
    }
}

private func cssStripWS(_ c: [CSSComponent]) -> [CSSComponent] {
    var out: [CSSComponent] = []
    for x in c { if case .token(.whitespace) = x { continue }; out.append(x) }
    return out
}

private func cssIdentLower(_ c: CSSComponent) -> String? {
    if case .token(.ident(let s)) = c { return cssLower(s) }
    return nil
}

/// A media-feature value as a number (px for lengths, dppx for resolutions).
private func cssMediaNumber(_ c: CSSComponent) -> Double? {
    switch c {
    case .token(.number(let v, _)): return v
    case .token(.dimension(let v, let u, _)):
        switch cssLower(u) {
        case "dppx", "x": return v
        case "dpi": return v / 96
        case "dpcm": return v / 37.795
        default:
            if let s = cssLengthFromToken(.dimension(v, u, false)) {
                return s.px + s.em * 16 + s.rem * 16
            }
            return nil
        }
    default: return nil
    }
}

private func cssParseMediaFeature(_ inner: [CSSComponent]) -> CSSMediaCondition {
    var cond = CSSMediaCondition()
    let c = cssStripWS(inner)
    if c.isEmpty { return cond }
    // Nested condition: (not (...)) or ((a) and (b)).
    if case .block = c[0] { return cssParseMediaConditionTokens(c) }
    if let id = cssIdentLower(c[0]), id == "not", c.count > 1 { return cssParseMediaConditionTokens(c) }
    func cmpOf(_ k: Int) -> (CSSMediaCmp, Int)? {
        guard k < c.count, case .token(.delim(let d)) = c[k] else { return nil }
        let eq = k + 1 < c.count && { if case .token(.delim(0x3d)) = c[k + 1] { return true } else { return false } }()
        switch d {
        case 0x3d: return (.eq, 1)
        case 0x3c: return (eq ? .le : .lt, eq ? 2 : 1)
        case 0x3e: return (eq ? .ge : .gt, eq ? 2 : 1)
        default: return nil
        }
    }
    func value(_ k: Int) -> (Double?, String?)? {
        guard k < c.count else { return nil }
        if let id = cssIdentLower(c[k]) { return (nil, id) }
        if let n = cssMediaNumber(c[k]) { return (n, nil) }
        // ratio a/b
        return nil
    }
    // name  /  name : value
    if let name = cssIdentLower(c[0]) {
        if c.count == 1 { cond.kind = .feature; cond.name = name; return cond }
        if case .token(.colon) = c[1] {
            guard c.count >= 3 else { return cond }
            var n = name
            var cmp = CSSMediaCmp.eq
            if n.hasPrefix("min-") { cmp = .ge; n = String(n.dropFirst(4)) }
            else if n.hasPrefix("max-") { cmp = .le; n = String(n.dropFirst(4)) }
            else if n.hasPrefix("-webkit-min-") { cmp = .ge; n = String(n.dropFirst(12)) }
            else if n.hasPrefix("-webkit-max-") { cmp = .le; n = String(n.dropFirst(12)) }
            else if n.hasPrefix("-webkit-") { n = String(n.dropFirst(8)) }
            if c.count == 5, case .token(.number(let a, _)) = c[2], case .token(.delim(0x2f)) = c[3],
               case .token(.number(let b, _)) = c[4], b != 0 {
                cond.kind = .feature; cond.name = n; cond.cmp = cmp; cond.hasValue = true; cond.number = a / b
                return cond
            }
            guard c.count == 3, let (num, id) = value(2) else { return cond }
            cond.kind = .feature; cond.name = n; cond.cmp = cmp; cond.hasValue = true
            if let v = num { cond.number = v } else { cond.isIdent = true; cond.ident = id ?? "" }
            return cond
        }
        // name <op> value
        if let (cmp, w) = cmpOf(1), let (num, _) = value(1 + w), let v = num, c.count == 2 + w {
            cond.kind = .feature; cond.name = name; cond.cmp = cmp; cond.hasValue = true; cond.number = v
            return cond
        }
        if let (cmp, w) = cmpOf(1), let (num, id) = value(1 + w), num == nil, c.count == 2 + w {
            cond.kind = .feature; cond.name = name; cond.cmp = cmp; cond.hasValue = true
            cond.isIdent = true; cond.ident = id ?? ""
            return cond
        }
        return cond
    }
    // value <op> name [<op> value]
    if let (num, _) = value(0), let v = num, let (cmp1, w1) = cmpOf(1), 1 + w1 < c.count, let name = cssIdentLower(c[1 + w1]) {
        func flip(_ m: CSSMediaCmp) -> CSSMediaCmp {
            switch m { case .lt: return .gt; case .le: return .ge; case .gt: return .lt; case .ge: return .le; case .eq: return .eq }
        }
        var first = CSSMediaCondition()
        first.kind = .feature; first.name = name; first.cmp = flip(cmp1); first.hasValue = true; first.number = v
        let after = 2 + w1
        if after == c.count { return first }
        if let (cmp2, w2) = cmpOf(after), let (n2, _) = value(after + w2), let v2 = n2, after + w2 + 1 == c.count {
            var second = CSSMediaCondition()
            second.kind = .feature; second.name = name; second.cmp = cmp2; second.hasValue = true; second.number = v2
            cond.kind = .and; cond.children = [first, second]
            return cond
        }
    }
    return cond
}

/// A chain of `(...)` blocks joined by and/or, or `not (...)`.
private func cssParseMediaConditionTokens(_ c: [CSSComponent]) -> CSSMediaCondition {
    var cond = CSSMediaCondition()
    var i = 0
    if let id = cssIdentLower(c[0]), id == "not" {
        guard c.count == 2, case .block(0x28, let inner) = c[1] else { return cond }
        cond.kind = .not
        cond.children = [cssParseMediaFeature(inner)]
        return cond
    }
    var op = ""
    var kids: [CSSMediaCondition] = []
    while i < c.count {
        guard case .block(0x28, let inner) = c[i] else { return cond }
        kids.append(cssParseMediaFeature(inner))
        i += 1
        if i == c.count { break }
        guard let w = cssIdentLower(c[i]), w == "and" || w == "or", i + 1 < c.count else { return cond }
        if !op.isEmpty && op != w { return cond }
        op = w
        i += 1
    }
    if kids.count == 1 { return kids[0] }
    cond.kind = op == "or" ? .or : .and
    cond.children = kids
    return cond
}

func cssParseMediaQueryList(_ comps: [CSSComponent]) -> CSSMediaQueryList {
    var list = CSSMediaQueryList()
    var parts: [[CSSComponent]] = [[]]
    for c in comps {
        if case .token(.comma) = c { parts.append([]) } else { parts[parts.count - 1].append(c) }
    }
    if parts.count == 1 && parts[0].isEmpty { return list }
    for p in parts {
        var q = CSSMediaQuery()
        var i = 0
        if p.isEmpty { q.type = .other; list.queries.append(q); continue }   // `@media ,x` is "not all"
        var first = cssIdentLower(p[0])
        if first == "only" { i = 1; first = i < p.count ? cssIdentLower(p[i]) : nil }
        else if first == "not" {
            if p.count > 1, case .block = p[1] {
                q.condition = cssParseMediaConditionTokens(p)
                list.queries.append(q)
                continue
            }
            q.negated = true; i = 1; first = i < p.count ? cssIdentLower(p[i]) : nil
        }
        if i < p.count, let ty = first {
            switch ty {
            case "all": q.type = .all
            case "screen": q.type = .screen
            case "print": q.type = .print
            default: q.type = .other
            }
            i += 1
            if i < p.count {
                guard let a = cssIdentLower(p[i]), a == "and", i + 1 < p.count else { q.type = .other; list.queries.append(q); continue }
                q.condition = cssParseMediaConditionTokens(Array(p[(i + 1)...]))
            }
        } else if i < p.count {
            q.condition = cssParseMediaConditionTokens(Array(p[i...]))
        } else { q.type = .other }
        list.queries.append(q)
    }
    return list
}

func cssParseMediaQueryList(_ source: String) -> CSSMediaQueryList {
    let t = cssTokenize(Array(source.utf8))
    return cssParseMediaQueryList(cssBuildComponents(t, 0, t.count, keepWS: false))
}

// MARK: - Evaluation (1 = true, 0 = false, -1 = unknown)

private func cssCompare(_ actual: Double, _ cmp: CSSMediaCmp, _ want: Double) -> Int8 {
    switch cmp {
    case .eq: return abs(actual - want) < 0.001 ? 1 : 0
    case .lt: return actual < want ? 1 : 0
    case .le: return actual <= want ? 1 : 0
    case .gt: return actual > want ? 1 : 0
    case .ge: return actual >= want ? 1 : 0
    }
}

private func cssEvalFeature(_ c: CSSMediaCondition, _ ctx: CSSContext) -> Int8 {
    var name = c.name
    var cmp = c.cmp
    if name.hasPrefix("min-") { cmp = .ge; name = String(name.dropFirst(4)) }
    else if name.hasPrefix("max-") { cmp = .le; name = String(name.dropFirst(4)) }
    var actual: Double? = nil
    switch name {
    case "width", "device-width": actual = ctx.viewportWidth
    case "height", "device-height": actual = ctx.viewportHeight
    case "aspect-ratio", "device-aspect-ratio": actual = ctx.viewportHeight > 0 ? ctx.viewportWidth / ctx.viewportHeight : 0
    case "resolution", "device-pixel-ratio": actual = 1
    case "color": actual = 8
    case "color-index", "monochrome", "grid": actual = 0
    default: break
    }
    if let a = actual {
        if !c.hasValue { return a != 0 ? 1 : 0 }
        if c.isIdent { return -1 }
        return cssCompare(a, cmp, c.number)
    }
    var id: String? = nil
    switch name {
    case "orientation": id = ctx.viewportWidth >= ctx.viewportHeight ? "landscape" : "portrait"
    case "prefers-color-scheme": id = ctx.darkColorScheme ? "dark" : "light"
    case "prefers-reduced-motion", "prefers-contrast", "prefers-reduced-transparency", "prefers-reduced-data":
        id = "no-preference"
    case "hover", "any-hover": id = "hover"
    case "pointer", "any-pointer": id = "fine"
    case "scripting": id = "none"
    case "display-mode": id = "browser"
    case "color-gamut": id = "srgb"
    case "update": id = "fast"
    case "forced-colors", "inverted-colors": id = "none"
    default: break
    }
    guard let actualID = id else { return -1 }
    if !c.hasValue { return actualID != "none" ? 1 : 0 }
    if !c.isIdent { return -1 }
    if name == "color-gamut" { return (c.ident == "srgb") ? 1 : 0 }
    return actualID == c.ident ? 1 : 0
}

func cssEvalMedia(_ c: CSSMediaCondition, _ ctx: CSSContext) -> Int8 {
    switch c.kind {
    case .unknown: return -1
    case .feature: return cssEvalFeature(c, ctx)
    case .not:
        let r = cssEvalMedia(c.children[0], ctx)
        return r == -1 ? -1 : (r == 1 ? 0 : 1)
    case .and:
        var unknown = false
        for k in c.children {
            let r = cssEvalMedia(k, ctx)
            if r == 0 { return 0 }
            if r == -1 { unknown = true }
        }
        return unknown ? -1 : 1
    case .or:
        var unknown = false
        for k in c.children {
            let r = cssEvalMedia(k, ctx)
            if r == 1 { return 1 }
            if r == -1 { unknown = true }
        }
        return unknown ? -1 : 0
    }
}

// MARK: - @supports

/// Evaluates a (keepWS) @supports condition: declarations we can parse,
/// selector(), not/and/or and parentheses. `display: grid` is reported
/// unsupported so pages fall back to layouts we can do.
func cssEvalSupports(_ comps: [CSSComponent]) -> Bool {
    let c = cssStripWSKeepingStructure(comps)
    return cssEvalSupportsList(c, 0) == 1
}

private func cssStripWSKeepingStructure(_ c: [CSSComponent]) -> [CSSComponent] { cssStripWS(c) }

private func cssEvalSupportsList(_ c: [CSSComponent], _ depth: Int) -> Int8 {
    if depth > 8 || c.isEmpty { return 0 }
    var i = 0
    var negate = false
    if let id = cssIdentLower(c[0]), id == "not" { negate = true; i = 1 }
    var result: Int8 = -2
    var op = ""
    while i < c.count {
        var r: Int8 = 0
        switch c[i] {
        case .block(0x28, let inner):
            r = cssEvalSupportsBlock(inner, depth + 1)
        case .function(let n, let args):
            let l = cssLower(n)
            if l == "selector" {
                let t = cssFlatten(args)
                r = cssParseSelectorList(t) != nil ? 1 : 0
            } else { r = 0 }
        default: return 0
        }
        if result == -2 { result = r }
        else if op == "and" { result = (result == 1 && r == 1) ? 1 : 0 }
        else { result = (result == 1 || r == 1) ? 1 : 0 }
        i += 1
        if i == c.count { break }
        guard let w = cssIdentLower(c[i]), w == "and" || w == "or", i + 1 < c.count else { return 0 }
        if !op.isEmpty && op != w { return 0 }
        op = w
        i += 1
    }
    if result == -2 { return 0 }
    return negate ? (result == 1 ? 0 : 1) : result
}

private func cssEvalSupportsBlock(_ inner: [CSSComponent], _ depth: Int) -> Int8 {
    let c = cssStripWS(inner)
    guard !c.isEmpty else { return 0 }
    if case .block = c[0] { return cssEvalSupportsList(c, depth) }
    if case .function = c[0] { return cssEvalSupportsList(c, depth) }
    if let id = cssIdentLower(c[0]), id == "not" { return cssEvalSupportsList(c, depth) }
    guard case .token(.ident(let name)) = c[0], c.count >= 2, case .token(.colon) = c[1] else { return 0 }
    var value = Array(c[2...])
    // Drop a trailing !important.
    if value.count >= 2, case .token(.ident(let imp)) = value[value.count - 1], cssLower(imp) == "important",
       case .token(.delim(0x21)) = value[value.count - 2] { value.removeLast(2) }
    if value.isEmpty { return name.hasPrefix("--") ? 1 : 0 }
    let decls = cssMakeDeclarations(name: name, value, important: false, resolveURL: nil)
    if decls.isEmpty { return 0 }
    if cssCanonicalPropertyName(name) == "display", value.count == 1, case .token(.ident(let v)) = value[0] {
        let l = cssLower(v)
        if l == "grid" || l == "inline-grid" { return 0 }
    }
    return 1
}
