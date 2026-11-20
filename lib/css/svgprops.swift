// SVG presentation properties (fill, stroke and friends, stop-color,
// clip-path), CSS masks (mask-image, mask-size, ...) and background-size /
// background-position (ROADMAP Phase 8J). Their parsing and computed values
// live here so properties.swift and computed.swift only dispatch.

enum CSSPaintKind: UInt8 { case none, color, currentColor, url }

/// An SVG paint: none, a color, currentColor, or url(#id) with a fallback.
struct CSSPaint: Equatable {
    var kind = CSSPaintKind.none
    var color = CSSColor.black
    var url = ""
    /// For url paints: what to use when the reference is missing (.url means
    /// "no fallback given", which paints nothing).
    var fallback = CSSPaintKind.url
    var fallbackColor = CSSColor.black
    init() {}
    init(color: CSSColor) { kind = .color; self.color = color }
    static let none = CSSPaint()
    static let black = CSSPaint(color: .black)
}

enum CSSFillRule: UInt8, CSSKeywordEnum {
    case nonzero, evenodd
    static let cssNames = ["nonzero", "evenodd"]
    static var cssDefault: CSSFillRule { .nonzero }
}

enum CSSLineCap: UInt8, CSSKeywordEnum {
    case butt, round, square
    static let cssNames = ["butt", "round", "square"]
    static var cssDefault: CSSLineCap { .butt }
}

enum CSSLineJoin: UInt8, CSSKeywordEnum {
    case miter, round, bevel
    static let cssNames = ["miter", "round", "bevel"]
    static var cssDefault: CSSLineJoin { .miter }
}

enum CSSMaskMode: UInt8, CSSKeywordEnum {
    case matchSource, alpha, luminance
    static let cssNames = ["match-source", "alpha", "luminance"]
    static var cssDefault: CSSMaskMode { .matchSource }
}

enum CSSBgSizeKind: UInt8 { case auto, contain, cover, explicit }

/// background-size / mask-size: auto, contain, cover, or one or two
/// lengths/percentages (either may be auto).
struct CSSBgSize {
    var kind = CSSBgSizeKind.auto
    var width = CSSDimension.auto
    var height = CSSDimension.auto
    init() {}
}

/// background-position / mask-position as percentages and offsets of the
/// free space: x = px + pct% of (box width - image width).
struct CSSBgPosition {
    var x = CSSLP.zero
    var y = CSSLP.zero
    init() {}
}

/// The SVG properties of a computed style.
struct CSSSVGStyle {
    // inherited
    var fill = CSSPaint.black
    var fillOpacity = 1.0
    var fillRule = CSSFillRule.nonzero
    var stroke = CSSPaint.none
    var strokeWidth = CSSLP(px: 1)
    var strokeOpacity = 1.0
    var strokeLinecap = CSSLineCap.butt
    var strokeLinejoin = CSSLineJoin.miter
    var strokeMiterlimit = 4.0
    /// Empty = none.
    var strokeDasharray: [CSSLP] = []
    var strokeDashoffset = CSSLP.zero
    var clipRule = CSSFillRule.nonzero
    // not inherited
    var stopColor = CSSColor.black
    var stopOpacity = 1.0
    /// url(#id) of a clipPath; nil = none.
    var clipPath: String? = nil
    init() {}

    mutating func inherit(from p: CSSSVGStyle) {
        fill = p.fill; fillOpacity = p.fillOpacity; fillRule = p.fillRule
        stroke = p.stroke; strokeWidth = p.strokeWidth; strokeOpacity = p.strokeOpacity
        strokeLinecap = p.strokeLinecap; strokeLinejoin = p.strokeLinejoin; strokeMiterlimit = p.strokeMiterlimit
        strokeDasharray = p.strokeDasharray; strokeDashoffset = p.strokeDashoffset; clipRule = p.clipRule
    }
}

/// The mask-* properties.
struct CSSMaskStyle {
    var image: String? = nil
    var mode = CSSMaskMode.matchSource
    var repeatMode = CSSBackgroundRepeat.repeat
    var size = CSSBgSize()
    var position = CSSBgPosition()
    init() {}
}

func cssIsSVGInherited(_ p: CSSProp) -> Bool {
    switch p {
    case .fill, .fillOpacity, .fillRule, .stroke, .strokeWidth, .strokeOpacity, .strokeLinecap,
         .strokeLinejoin, .strokeMiterlimit, .strokeDasharray, .strokeDashoffset, .clipRule:
        return true
    default: return false
    }
}

// MARK: - Parsing

private func cssSVGIdent(_ c: CSSComponent) -> String? {
    if case .token(.ident(let s)) = c { return cssLower(s) }
    return nil
}

private func cssSVGURL(_ c: CSSComponent) -> String? {
    switch c {
    case .token(.url(let s)): return s
    case .function(let n, let args):
        if cssLower(n) == "url", args.count == 1, case .token(.string(let s)) = args[0] { return s }
        return nil
    default: return nil
    }
}

/// A length, percentage or (SVG style) plain number of px.
private func cssSVGLength(_ c: CSSComponent, nonNegative: Bool) -> CSSCalc? {
    if case .token(.number(let v, _)) = c {
        if nonNegative && v < 0 { return nil }
        return .px(v)
    }
    guard let v = cssParseLengthPercentage(c) else { return nil }
    if nonNegative && v.isNegativeLiteral { return nil }
    return v
}

private func cssSVGOpacity(_ c: [CSSComponent]) -> CSSValue? {
    guard c.count == 1 else { return nil }
    if case .token(.percentage(let v)) = c[0] { return .number(max(0, min(1, v / 100)), false) }
    guard let (v, _) = cssParseNumber(c[0]) else { return nil }
    return .number(max(0, min(1, v)), false)
}

private func cssSVGPaint(_ c: [CSSComponent]) -> CSSValue? {
    guard !c.isEmpty, c.count <= 2 else { return nil }
    if let id = cssSVGIdent(c[0]) {
        if c.count != 1 { return nil }
        if id == "none" || id == "context-fill" || id == "context-stroke" { return .ident("none") }
    }
    if let u = cssSVGURL(c[0]) {
        if c.count == 2 {
            if let id = cssSVGIdent(c[1]), id == "none" { return .list([.url(u), .ident("none")]) }
            guard let col = cssParseColor(c[1]) else { return nil }
            return .list([.url(u), .color(col)])
        }
        return .list([.url(u)])
    }
    guard c.count == 1, let col = cssParseColor(c[0]) else { return nil }
    return .color(col)
}

private func cssSVGImage(_ c: [CSSComponent], _ resolveURL: ((String) -> String)?) -> CSSValue? {
    // A list of layers: the first url() wins; gradients count as none.
    var out: CSSValue? = nil
    var gotURL = false
    for item in c {
        if case .token(.comma) = item { continue }
        if let id = cssSVGIdent(item) {
            if id == "none" { if out == nil { out = .ident("none") }; continue }
            return nil
        }
        if let u = cssSVGURL(item) {
            if !gotURL { out = .url(resolveURL?(u) ?? u); gotURL = true }
            continue
        }
        if case .function(let n, _) = item {
            let ln = cssLower(n)
            if ln.hasSuffix("gradient") || ln.hasSuffix("image-set") || ln == "element" || ln == "paint" {
                if out == nil { out = .ident("none") }
                continue
            }
        }
        return nil
    }
    return out
}

/// background-size / mask-size for the first layer.
private func cssParseBgSize(_ c: [CSSComponent]) -> CSSValue? {
    let layer = Array(c.prefix { if case .token(.comma) = $0 { return false }; return true })
    guard !layer.isEmpty, layer.count <= 2 else { return nil }
    if layer.count == 1, let id = cssSVGIdent(layer[0]), id == "contain" || id == "cover" { return .ident(id) }
    var items: [CSSValue] = []
    for item in layer {
        if let id = cssSVGIdent(item) {
            guard id == "auto" else { return nil }
            items.append(.ident("auto"))
            continue
        }
        guard let v = cssParseLengthPercentage(item), !v.isNegativeLiteral else { return nil }
        items.append(.dimension(v))
    }
    return .list(items)
}

/// background-position / mask-position for the first layer: one or two
/// values (keywords, lengths, percentages) or the edge-offset forms
/// (`right 10px top 5px`).
private func cssParseBgPosition(_ c: [CSSComponent]) -> CSSValue? {
    let layer = Array(c.prefix { if case .token(.comma) = $0 { return false }; return true })
    guard !layer.isEmpty, layer.count <= 4 else { return nil }
    // (axis: 0 x, 1 y, 2 either; value)
    func kw(_ id: String) -> (Int, Double)? {
        switch id {
        case "left": return (0, 0)
        case "right": return (0, 100)
        case "top": return (1, 0)
        case "bottom": return (1, 100)
        case "center": return (2, 50)
        default: return nil
        }
    }
    if layer.count <= 2 {
        var vals: [(Int, CSSCalc)] = []
        for item in layer {
            if let id = cssSVGIdent(item) {
                guard let (axis, pct) = kw(id) else { return nil }
                vals.append((axis, .percent(pct)))
            } else {
                guard let v = cssParseLengthPercentage(item) else { return nil }
                vals.append((3, v))   // a length: x first, then y
            }
        }
        var x: CSSCalc = .percent(50), y: CSSCalc = .percent(50)
        if vals.count == 1 {
            let (axis, v) = vals[0]
            if axis == 1 { y = v } else { x = v }
        } else {
            var a = vals[0], b = vals[1]
            if a.0 == 1 || b.0 == 0 { swap(&a, &b) }
            if a.0 == 1 || b.0 == 0 { return nil }
            x = a.1; y = b.1
        }
        return .list([.dimension(x), .dimension(y)])
    }
    var x: CSSCalc? = nil, y: CSSCalc? = nil
    var i = 0
    while i < layer.count {
        guard let id = cssSVGIdent(layer[i]), let (axis, pct) = kw(id) else { return nil }
        var v = CSSCalc.percent(pct)
        if i + 1 < layer.count, cssSVGIdent(layer[i + 1]) == nil {
            guard let off = cssParseLengthPercentage(layer[i + 1]) else { return nil }
            v = (pct == 100 ? v.adding(off.scaled(-1)) : v.adding(off)) ?? v
            i += 1
        }
        if axis == 0 || (axis == 2 && x == nil && y != nil) { if x != nil { return nil }; x = v }
        else if axis == 1 || axis == 2 { if y != nil { return nil }; y = v }
        i += 1
    }
    return .list([.dimension(x ?? .percent(50)), .dimension(y ?? .percent(50))])
}

private func cssDashArray(_ c: [CSSComponent]) -> CSSValue? {
    if c.count == 1, let id = cssSVGIdent(c[0]), id == "none" { return .ident("none") }
    var items: [CSSValue] = []
    for item in c {
        if case .token(.comma) = item { continue }
        guard let v = cssSVGLength(item, nonNegative: true) else { return nil }
        items.append(.dimension(v))
        if items.count > 1000 { return nil }
    }
    return items.isEmpty ? nil : .list(items)
}

/// Parse an SVG/mask/background-geometry longhand; nil if invalid or not one
/// of these properties.
func cssParseSVGLonghand(_ p: CSSProp, _ c: [CSSComponent], resolveURL: ((String) -> String)?) -> CSSValue? {
    switch p {
    case .fill, .stroke: return cssSVGPaint(c)
    case .fillOpacity, .strokeOpacity, .stopOpacity: return cssSVGOpacity(c)
    case .strokeWidth:
        guard c.count == 1, let v = cssSVGLength(c[0], nonNegative: true) else { return nil }
        return .dimension(v)
    case .strokeDashoffset:
        guard c.count == 1, let v = cssSVGLength(c[0], nonNegative: false) else { return nil }
        return .dimension(v)
    case .strokeMiterlimit:
        guard c.count == 1, let (v, _) = cssParseNumber(c[0]), v >= 1 else { return nil }
        return .number(min(v, 1e6), false)
    case .strokeDasharray: return cssDashArray(c)
    case .stopColor:
        guard c.count == 1, let col = cssParseColor(c[0]) else { return nil }
        return .color(col)
    case .clipPath:
        guard !c.isEmpty else { return nil }
        if c.count == 1, let id = cssSVGIdent(c[0]) { return id == "none" ? .ident("none") : nil }
        if let u = cssSVGURL(c[0]), c.count == 1 { return .url(u) }
        // Basic shapes (inset(), circle(), ...) and boxes are not drawn: no clip.
        for item in c {
            switch item {
            case .function, .token(.ident): continue
            default: return nil
            }
        }
        return .ident("none")
    case .maskImage: return cssSVGImage(c, resolveURL)
    case .maskSize, .backgroundSize: return cssParseBgSize(c)
    case .maskPosition, .backgroundPosition: return cssParseBgPosition(c)
    case .maskRepeat:
        guard let id = c.first.flatMap(cssSVGIdent) else { return nil }
        let k = id == "space" || id == "round" ? "repeat" : id
        guard let idx = CSSBackgroundRepeat.cssNames.firstIndex(of: k) else { return nil }
        return .keyword(UInt8(idx))
    case .maskMode:
        guard let id = c.first.flatMap(cssSVGIdent), let idx = CSSMaskMode.cssNames.firstIndex(of: id) else { return nil }
        return .keyword(UInt8(idx))
    case .fillRule, .clipRule:
        guard c.count == 1, let id = cssSVGIdent(c[0]), let idx = CSSFillRule.cssNames.firstIndex(of: id) else { return nil }
        return .keyword(UInt8(idx))
    case .strokeLinecap:
        guard c.count == 1, let id = cssSVGIdent(c[0]), let idx = CSSLineCap.cssNames.firstIndex(of: id) else { return nil }
        return .keyword(UInt8(idx))
    case .strokeLinejoin:
        guard c.count == 1, var id = cssSVGIdent(c[0]) else { return nil }
        if id == "miter-clip" || id == "arcs" { id = "miter" }
        guard let idx = CSSLineJoin.cssNames.firstIndex(of: id) else { return nil }
        return .keyword(UInt8(idx))
    default: return nil
    }
}

/// The `mask` shorthand (first layer): image, repeat, position / size, mode.
func cssParseMaskShorthand(_ comps: [CSSComponent], _ resolveURL: ((String) -> String)?) -> [CSSDeclaration]? {
    let layer = Array(comps.prefix { if case .token(.comma) = $0 { return false }; return true })
    guard !layer.isEmpty else { return nil }
    var image: CSSValue? = nil, rep: CSSValue? = nil, mode: CSSValue? = nil
    var pos: [CSSComponent] = [], size: [CSSComponent] = []
    var afterSlash = false
    for item in layer {
        if case .token(.delim(0x2f)) = item { afterSlash = true; continue }
        if let id = cssSVGIdent(item) {
            if id == "none" { image = .ident("none"); continue }
            if let v = cssParseSVGLonghand(.maskRepeat, [item], resolveURL: nil) { rep = v; continue }
            if let v = cssParseSVGLonghand(.maskMode, [item], resolveURL: nil) { mode = v; continue }
            if ["left", "right", "top", "bottom", "center"].contains(id) { pos.append(item); continue }
            if id == "contain" || id == "cover" || (id == "auto" && afterSlash) { size.append(item); continue }
            // boxes and compositing operators
            if ["border-box", "padding-box", "content-box", "fill-box", "stroke-box", "view-box", "no-clip",
                "add", "subtract", "intersect", "exclude", "repeat-x", "repeat-y"].contains(id) { continue }
            return nil
        }
        var isImage = cssSVGURL(item) != nil
        if case .function(let n, _) = item, cssLower(n) != "calc" { isImage = true }
        if isImage {
            if let v = cssSVGImage([item], resolveURL) { image = v; continue }
            return nil
        }
        if afterSlash { size.append(item) } else { pos.append(item) }
    }
    func mk(_ p: CSSProp, _ v: CSSValue?) -> CSSDeclaration {
        v.map { CSSDeclaration(prop: p, kind: .value, value: $0) } ?? CSSDeclaration(prop: p, kind: .initial)
    }
    var out = [mk(.maskImage, image), mk(.maskRepeat, rep), mk(.maskMode, mode)]
    out.append(mk(.maskPosition, pos.isEmpty ? nil : cssParseBgPosition(pos)))
    out.append(mk(.maskSize, size.isEmpty ? nil : cssParseBgSize(size)))
    return out
}

// MARK: - Computed values

private func cssSVGKw(_ v: CSSValue) -> UInt8 {
    if case .keyword(let k) = v { return k }
    return 0
}

private func cssPaintValue(_ v: CSSValue) -> CSSPaint {
    var p = CSSPaint()
    switch v {
    case .color(let c):
        switch c {
        case .rgba(let col): p.kind = .color; p.color = col
        case .currentColor: p.kind = .currentColor
        }
    case .list(let items):
        guard let first = items.first, case .url(let u) = first else { return p }
        p.kind = .url; p.url = u
        if items.count > 1 {
            switch items[1] {
            case .color(let c):
                switch c {
                case .rgba(let col): p.fallback = .color; p.fallbackColor = col
                case .currentColor: p.fallback = .currentColor
                }
            default: p.fallback = .none
            }
        }
    default: break
    }
    return p
}

extension CSSComputedStyle {
    mutating func applySVG(_ prop: CSSProp, _ v: CSSValue, ctx: CSSContext) {
        func lp(_ v: CSSValue) -> CSSLP {
            if case .dimension(let c) = v { return cssResolveCalc(c, fontSize: fontSize, ctx: ctx) }
            return .zero
        }
        func num(_ v: CSSValue, _ d: Double) -> Double {
            if case .number(let n, _) = v { return n }
            return d
        }
        switch prop {
        case .fill: svg.fill = cssPaintValue(v)
        case .stroke: svg.stroke = cssPaintValue(v)
        case .fillOpacity: svg.fillOpacity = num(v, 1)
        case .strokeOpacity: svg.strokeOpacity = num(v, 1)
        case .stopOpacity: svg.stopOpacity = num(v, 1)
        case .fillRule: svg.fillRule = CSSFillRule(cssIndex: cssSVGKw(v))
        case .clipRule: svg.clipRule = CSSFillRule(cssIndex: cssSVGKw(v))
        case .strokeWidth: svg.strokeWidth = lp(v)
        case .strokeDashoffset: svg.strokeDashoffset = lp(v)
        case .strokeMiterlimit: svg.strokeMiterlimit = num(v, 4)
        case .strokeLinecap: svg.strokeLinecap = CSSLineCap(cssIndex: cssSVGKw(v))
        case .strokeLinejoin: svg.strokeLinejoin = CSSLineJoin(cssIndex: cssSVGKw(v))
        case .strokeDasharray:
            var out: [CSSLP] = []
            if case .list(let items) = v { for i in items { out.append(lp(i)) } }
            svg.strokeDasharray = out
        case .stopColor:
            if case .color(let c) = v {
                switch c {
                case .rgba(let col): svg.stopColor = col
                case .currentColor: svg.stopColor = color
                }
            }
        case .clipPath: if case .url(let u) = v { svg.clipPath = u } else { svg.clipPath = nil }
        case .maskImage: if case .url(let u) = v { mask.image = u } else { mask.image = nil }
        case .maskMode: mask.mode = CSSMaskMode(cssIndex: cssSVGKw(v))
        case .maskRepeat: mask.repeatMode = CSSBackgroundRepeat(cssIndex: cssSVGKw(v))
        case .maskSize: mask.size = bgSize(v, ctx)
        case .backgroundSize: backgroundSize = bgSize(v, ctx)
        case .maskPosition: mask.position = bgPosition(v, ctx)
        case .backgroundPosition: backgroundPosition = bgPosition(v, ctx)
        default: break
        }
    }

    private func bgSize(_ v: CSSValue, _ ctx: CSSContext) -> CSSBgSize {
        var s = CSSBgSize()
        switch v {
        case .ident(let id): s.kind = id == "contain" ? .contain : (id == "cover" ? .cover : .auto)
        case .list(let items):
            s.kind = .explicit
            func dim(_ i: CSSValue) -> CSSDimension {
                if case .dimension(let c) = i {
                    var d = CSSDimension()
                    d.lp = cssResolveCalc(c, fontSize: fontSize, ctx: ctx)
                    return d
                }
                return .auto
            }
            if items.count >= 1 { s.width = dim(items[0]) }
            if items.count >= 2 { s.height = dim(items[1]) }
            if s.width.isAuto && s.height.isAuto { s.kind = .auto }
        default: break
        }
        return s
    }

    private func bgPosition(_ v: CSSValue, _ ctx: CSSContext) -> CSSBgPosition {
        var p = CSSBgPosition()
        if case .list(let items) = v, items.count == 2 {
            if case .dimension(let c) = items[0] { p.x = cssResolveCalc(c, fontSize: fontSize, ctx: ctx) }
            if case .dimension(let c) = items[1] { p.y = cssResolveCalc(c, fontSize: fontSize, ctx: ctx) }
        }
        return p
    }

    mutating func copySVGProperty(_ prop: CSSProp, from s: CSSComputedStyle) {
        switch prop {
        case .fill: svg.fill = s.svg.fill
        case .stroke: svg.stroke = s.svg.stroke
        case .fillOpacity: svg.fillOpacity = s.svg.fillOpacity
        case .strokeOpacity: svg.strokeOpacity = s.svg.strokeOpacity
        case .stopOpacity: svg.stopOpacity = s.svg.stopOpacity
        case .fillRule: svg.fillRule = s.svg.fillRule
        case .clipRule: svg.clipRule = s.svg.clipRule
        case .strokeWidth: svg.strokeWidth = s.svg.strokeWidth
        case .strokeDashoffset: svg.strokeDashoffset = s.svg.strokeDashoffset
        case .strokeMiterlimit: svg.strokeMiterlimit = s.svg.strokeMiterlimit
        case .strokeLinecap: svg.strokeLinecap = s.svg.strokeLinecap
        case .strokeLinejoin: svg.strokeLinejoin = s.svg.strokeLinejoin
        case .strokeDasharray: svg.strokeDasharray = s.svg.strokeDasharray
        case .stopColor: svg.stopColor = s.svg.stopColor
        case .clipPath: svg.clipPath = s.svg.clipPath
        case .maskImage: mask.image = s.mask.image
        case .maskMode: mask.mode = s.mask.mode
        case .maskRepeat: mask.repeatMode = s.mask.repeatMode
        case .maskSize: mask.size = s.mask.size
        case .maskPosition: mask.position = s.mask.position
        case .backgroundSize: backgroundSize = s.backgroundSize
        case .backgroundPosition: backgroundPosition = s.backgroundPosition
        default: break
        }
    }
}
