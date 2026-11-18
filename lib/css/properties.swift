// Property ids, declarations, and parsing declarations into longhands
// (shorthand expansion). Parsing validates: an invalid value drops the whole
// declaration, so an earlier valid one keeps winning in the cascade.

/// The order is the order values are applied in a cascade: color and font-size
/// come first because em lengths and currentColor depend on them.
enum CSSProp: UInt8 {
    case color, fontSize
    case fontFamily, fontWeight, fontStyle, lineHeight
    case display, position, top, right, bottom, left, float, clear, zIndex
    case width, height, minWidth, minHeight, maxWidth, maxHeight
    case marginTop, marginRight, marginBottom, marginLeft
    case paddingTop, paddingRight, paddingBottom, paddingLeft
    case borderTopWidth, borderRightWidth, borderBottomWidth, borderLeftWidth
    case borderTopStyle, borderRightStyle, borderBottomStyle, borderLeftStyle
    case borderTopColor, borderRightColor, borderBottomColor, borderLeftColor
    case boxSizing, backgroundColor, backgroundImage, backgroundRepeat
    case textAlign, textDecorationLine, textIndent, textTransform, whiteSpace, verticalAlign
    case listStyleType, listStylePosition, visibility, overflowX, overflowY, opacity
    case flexDirection, flexWrap, flexGrow, flexShrink, flexBasis
    case justifyContent, alignItems, alignSelf, rowGap, columnGap
    case borderCollapse, borderSpacingH, borderSpacingV, tableLayout, content, cursor
    case custom
}

let cssPropCount = Int(CSSProp.custom.rawValue) + 1

enum CSSDeclKind: UInt8 { case value, initial, inherit, unset, pending, custom }

struct CSSDeclaration {
    var prop: CSSProp
    var important = false
    var kind: CSSDeclKind
    var value: CSSValue = .ident("")
    /// custom: the property name; pending: the declared (shorthand) name.
    var name = ""
    /// custom and pending: the unsubstituted value.
    var raw: [CSSComponent] = []

    init(prop: CSSProp, kind: CSSDeclKind, value: CSSValue = .ident("")) {
        self.prop = prop; self.kind = kind; self.value = value
    }
}

func cssIsInherited(_ p: CSSProp) -> Bool {
    switch p {
    case .color, .fontSize, .fontFamily, .fontWeight, .fontStyle, .lineHeight, .textAlign, .textIndent,
         .textTransform, .whiteSpace, .listStyleType, .listStylePosition, .visibility, .borderCollapse,
         .borderSpacingH, .borderSpacingV, .cursor:
        return true
    default: return false
    }
}

// MARK: - Names

private let cssLonghandNames: [String: CSSProp] = [
    "color": .color, "font-size": .fontSize, "font-family": .fontFamily, "font-weight": .fontWeight,
    "font-style": .fontStyle, "line-height": .lineHeight, "display": .display, "position": .position,
    "top": .top, "right": .right, "bottom": .bottom, "left": .left, "float": .float, "clear": .clear,
    "z-index": .zIndex, "width": .width, "height": .height, "min-width": .minWidth, "min-height": .minHeight,
    "max-width": .maxWidth, "max-height": .maxHeight,
    "margin-top": .marginTop, "margin-right": .marginRight, "margin-bottom": .marginBottom,
    "margin-left": .marginLeft, "padding-top": .paddingTop, "padding-right": .paddingRight,
    "padding-bottom": .paddingBottom, "padding-left": .paddingLeft,
    "border-top-width": .borderTopWidth, "border-right-width": .borderRightWidth,
    "border-bottom-width": .borderBottomWidth, "border-left-width": .borderLeftWidth,
    "border-top-style": .borderTopStyle, "border-right-style": .borderRightStyle,
    "border-bottom-style": .borderBottomStyle, "border-left-style": .borderLeftStyle,
    "border-top-color": .borderTopColor, "border-right-color": .borderRightColor,
    "border-bottom-color": .borderBottomColor, "border-left-color": .borderLeftColor,
    "box-sizing": .boxSizing, "background-color": .backgroundColor, "background-image": .backgroundImage,
    "background-repeat": .backgroundRepeat, "text-align": .textAlign,
    "text-decoration-line": .textDecorationLine, "text-indent": .textIndent,
    "text-transform": .textTransform, "white-space": .whiteSpace, "vertical-align": .verticalAlign,
    "list-style-type": .listStyleType, "list-style-position": .listStylePosition,
    "visibility": .visibility, "overflow-x": .overflowX, "overflow-y": .overflowY, "opacity": .opacity,
    "flex-direction": .flexDirection, "flex-wrap": .flexWrap, "flex-grow": .flexGrow,
    "flex-shrink": .flexShrink, "flex-basis": .flexBasis, "justify-content": .justifyContent,
    "align-items": .alignItems, "align-self": .alignSelf, "row-gap": .rowGap, "column-gap": .columnGap,
    "border-collapse": .borderCollapse, "table-layout": .tableLayout, "content": .content, "cursor": .cursor,
]

private let cssAliases: [String: String] = [
    "-webkit-box-sizing": "box-sizing", "-moz-box-sizing": "box-sizing",
    "margin-inline-start": "margin-left", "margin-inline-end": "margin-right",
    "margin-block-start": "margin-top", "margin-block-end": "margin-bottom",
    "padding-inline-start": "padding-left", "padding-inline-end": "padding-right",
    "padding-block-start": "padding-top", "padding-block-end": "padding-bottom",
    "inline-size": "width", "block-size": "height", "min-inline-size": "min-width",
    "min-block-size": "min-height", "max-inline-size": "max-width", "max-block-size": "max-height",
    "inset-inline-start": "left", "inset-inline-end": "right", "inset-block-start": "top",
    "inset-block-end": "bottom", "grid-gap": "gap", "grid-row-gap": "row-gap", "grid-column-gap": "column-gap",
    "-webkit-text-decoration": "text-decoration",
]

private let cssShorthands: [String: [CSSProp]] = [
    "margin": [.marginTop, .marginRight, .marginBottom, .marginLeft],
    "padding": [.paddingTop, .paddingRight, .paddingBottom, .paddingLeft],
    "margin-inline": [.marginLeft, .marginRight], "margin-block": [.marginTop, .marginBottom],
    "padding-inline": [.paddingLeft, .paddingRight], "padding-block": [.paddingTop, .paddingBottom],
    "inset": [.top, .right, .bottom, .left],
    "border-width": [.borderTopWidth, .borderRightWidth, .borderBottomWidth, .borderLeftWidth],
    "border-style": [.borderTopStyle, .borderRightStyle, .borderBottomStyle, .borderLeftStyle],
    "border-color": [.borderTopColor, .borderRightColor, .borderBottomColor, .borderLeftColor],
    "border": [.borderTopWidth, .borderRightWidth, .borderBottomWidth, .borderLeftWidth,
               .borderTopStyle, .borderRightStyle, .borderBottomStyle, .borderLeftStyle,
               .borderTopColor, .borderRightColor, .borderBottomColor, .borderLeftColor],
    "border-top": [.borderTopWidth, .borderTopStyle, .borderTopColor],
    "border-right": [.borderRightWidth, .borderRightStyle, .borderRightColor],
    "border-bottom": [.borderBottomWidth, .borderBottomStyle, .borderBottomColor],
    "border-left": [.borderLeftWidth, .borderLeftStyle, .borderLeftColor],
    "background": [.backgroundColor, .backgroundImage, .backgroundRepeat],
    "font": [.fontStyle, .fontWeight, .fontSize, .lineHeight, .fontFamily],
    "list-style": [.listStyleType, .listStylePosition],
    "overflow": [.overflowX, .overflowY],
    "flex": [.flexGrow, .flexShrink, .flexBasis],
    "flex-flow": [.flexDirection, .flexWrap],
    "gap": [.rowGap, .columnGap],
    "border-spacing": [.borderSpacingH, .borderSpacingV],
    "text-decoration": [.textDecorationLine],
]

/// Resolve aliases and lowercase: the name the parser works with.
func cssCanonicalPropertyName(_ name: String) -> String {
    let l = cssLower(name)
    return cssAliases[l] ?? l
}

/// The longhands a (canonical, lowercase) property name sets; nil if unknown.
func cssLonghands(of name: String) -> [CSSProp]? {
    if let p = cssLonghandNames[name] { return [p] }
    return cssShorthands[name]
}

// MARK: - Component helpers

func cssIsCSSWide(_ s: String) -> CSSDeclKind? {
    switch cssLower(s) {
    case "initial": return .initial
    case "inherit": return .inherit
    case "unset", "revert", "revert-layer": return .unset
    default: return nil
    }
}

func cssContainsVar(_ comps: [CSSComponent]) -> Bool {
    for c in comps {
        switch c {
        case .function(let n, let args):
            if cssLower(n) == "var" || cssContainsVar(args) { return true }
        case .block(_, let inner):
            if cssContainsVar(inner) { return true }
        default: break
        }
    }
    return false
}

private func cssIdent(_ c: CSSComponent) -> String? {
    if case .token(.ident(let s)) = c { return cssLower(s) }
    return nil
}

private func cssURLString(_ c: CSSComponent) -> String? {
    switch c {
    case .token(.url(let s)): return s
    case .function(let n, let args):
        if cssLower(n) == "url", args.count == 1, case .token(.string(let s)) = args[0] { return s }
        return nil
    default: return nil
    }
}

private func cssKeywordTable(_ p: CSSProp) -> [String]? {
    switch p {
    case .display: return CSSDisplay.cssNames
    case .position: return CSSPosition.cssNames
    case .float: return CSSFloat.cssNames
    case .clear: return CSSClear.cssNames
    case .boxSizing: return CSSBoxSizing.cssNames
    case .visibility: return CSSVisibility.cssNames
    case .overflowX, .overflowY: return CSSOverflow.cssNames
    case .textAlign: return CSSTextAlign.cssNames
    case .textTransform: return CSSTextTransform.cssNames
    case .whiteSpace: return CSSWhiteSpace.cssNames
    case .listStyleType: return CSSListStyleType.cssNames
    case .listStylePosition: return CSSListStylePosition.cssNames
    case .flexDirection: return CSSFlexDirection.cssNames
    case .flexWrap: return CSSFlexWrap.cssNames
    case .justifyContent: return CSSJustifyContent.cssNames
    case .alignItems, .alignSelf: return CSSAlign.cssNames
    case .borderCollapse: return CSSBorderCollapse.cssNames
    case .tableLayout: return CSSTableLayout.cssNames
    case .borderTopStyle, .borderRightStyle, .borderBottomStyle, .borderLeftStyle: return CSSBorderStyle.cssNames
    case .fontStyle: return CSSFontStyle.cssNames
    case .backgroundRepeat: return CSSBackgroundRepeat.cssNames
    default: return nil
    }
}

private func cssKeywordAlias(_ p: CSSProp, _ s: String) -> String {
    switch p {
    case .display:
        if s == "flow-root" || s == "grid" { return "block" }
        if s == "inline-grid" { return "inline-block" }
        if s == "-webkit-flex" { return "flex" }
        if s == "-webkit-inline-flex" { return "inline-flex" }
        return s
    case .float:
        if s == "inline-start" { return "left" }
        if s == "inline-end" { return "right" }
        return s
    case .textAlign:
        switch s {
        case "start", "match-parent": return "left"
        case "end": return "right"
        case "-webkit-center", "-moz-center": return "center"
        case "-webkit-left", "-moz-left": return "left"
        case "-webkit-right", "-moz-right": return "right"
        default: return s
        }
    case .whiteSpace: return s == "break-spaces" ? "pre-wrap" : s
    case .overflowX, .overflowY: return s == "clip" ? "hidden" : s
    case .listStyleType:
        switch s {
        case "lower-latin": return "lower-alpha"
        case "upper-latin": return "upper-alpha"
        default: return s
        }
    case .justifyContent:
        switch s {
        case "start", "left", "normal", "stretch", "flex-start": return "flex-start"
        case "end", "right": return "flex-end"
        default: return s
        }
    case .alignItems, .alignSelf:
        switch s {
        case "normal": return p == .alignItems ? "stretch" : "auto"
        case "start", "self-start": return "flex-start"
        case "end", "self-end": return "flex-end"
        case "first baseline", "last baseline": return "baseline"
        default: return s
        }
    default: return s
    }
}

// MARK: - Longhand parsing

private func cssDimensionValue(_ c: CSSComponent, auto: Bool, none: Bool, intrinsic: Bool, nonNegative: Bool) -> CSSValue? {
    if let id = cssIdent(c) {
        if auto && id == "auto" { return .ident("auto") }
        if none && id == "none" { return .ident("none") }
        if intrinsic && (id == "min-content" || id == "max-content" || id == "fit-content"
                         || id == "-webkit-min-content" || id == "-webkit-max-content"
                         || id == "-moz-min-content" || id == "-moz-max-content"
                         || id == "-webkit-fit-content" || id == "-moz-fit-content") {
            if id.hasSuffix("min-content") { return .ident("min-content") }
            if id.hasSuffix("max-content") { return .ident("max-content") }
            return .ident("fit-content")
        }
        return nil
    }
    guard let v = cssParseLengthPercentage(c) else { return nil }
    if nonNegative && v.isNegativeLiteral { return nil }
    return .dimension(v)
}

private func cssBorderWidthValue(_ c: CSSComponent) -> CSSValue? {
    if let id = cssIdent(c) {
        switch id {
        case "thin": return .dimension(.px(1))
        case "medium": return .dimension(.px(3))
        case "thick": return .dimension(.px(5))
        default: return nil
        }
    }
    guard case .token(let t) = c else {
        if case .function = c, let v = cssParseLengthPercentage(c), v.pct == 0, !v.isNegativeLiteral { return .dimension(v) }
        return nil
    }
    if case .percentage = t { return nil }
    guard let v = cssParseLengthPercentage(c), !v.isNegativeLiteral else { return nil }
    return .dimension(v)
}

private func cssColorValue(_ c: CSSComponent) -> CSSValue? {
    guard let col = cssParseColor(c) else { return nil }
    return .color(col)
}

private func cssParseFontFamily(_ comps: [CSSComponent]) -> CSSValue? {
    var families: [CSSValue] = []
    var cur: [String] = []
    var curString: String? = nil
    func flush() -> Bool {
        if let s = curString {
            if !cur.isEmpty { return false }
            families.append(.string(s)); curString = nil
        } else if !cur.isEmpty {
            var joined = ""
            for (k, w) in cur.enumerated() { if k > 0 { joined += " " }; joined += w }
            families.append(.string(joined)); cur = []
        } else { return false }
        return true
    }
    for c in comps {
        switch c {
        case .token(.comma): if !flush() { return nil }
        case .token(.string(let s)):
            if curString != nil || !cur.isEmpty { return nil }
            curString = s
        case .token(.ident(let s)):
            if curString != nil { return nil }
            cur.append(s)
        default: return nil
        }
    }
    if !flush() { return nil }
    return .list(families)
}

private let cssFontSizeKeywords = ["xx-small", "x-small", "small", "medium", "large", "x-large", "xx-large",
                                   "xxx-large", "larger", "smaller"]

private func cssParseFontSize(_ c: CSSComponent) -> CSSValue? {
    if let id = cssIdent(c) {
        return cssFontSizeKeywords.contains(id) ? .ident(id) : nil
    }
    guard let v = cssParseLengthPercentage(c), !v.isNegativeLiteral else { return nil }
    return .dimension(v)
}

private func cssParseFontWeight(_ c: CSSComponent) -> CSSValue? {
    if let id = cssIdent(c) {
        switch id {
        case "normal", "bold", "bolder", "lighter": return .ident(id)
        default: return nil
        }
    }
    guard let (v, _) = cssParseNumber(c), v >= 1, v <= 1000 else { return nil }
    return .number(v, true)
}

private func cssParseLineHeight(_ c: CSSComponent) -> CSSValue? {
    if let id = cssIdent(c) { return id == "normal" ? .ident("normal") : nil }
    if let (n, _) = cssParseNumber(c) { return n >= 0 ? .number(n, false) : nil }
    guard let v = cssParseLengthPercentage(c), !v.isNegativeLiteral else { return nil }
    return .dimension(v)
}

private func cssParseContent(_ comps: [CSSComponent]) -> CSSValue? {
    if comps.count == 1, let id = cssIdent(comps[0]), id == "normal" || id == "none" { return .ident(id) }
    var items: [CSSValue] = []
    for c in comps {
        switch c {
        case .token(.string(let s)): items.append(.string(s))
        case .token(.ident(let s)):
            switch cssLower(s) {
            case "open-quote": items.append(.string("\u{201C}"))
            case "close-quote": items.append(.string("\u{201D}"))
            case "no-open-quote", "no-close-quote": break
            default: return nil
            }
        case .function(let n, let args):
            let ln = cssLower(n)
            if ln == "attr", args.count == 1, case .token(.ident(let a)) = args[0] {
                items.append(.ident("attr:" + a))
            } else if ln == "counter" || ln == "counters" || ln == "url" || ln.hasSuffix("gradient") {
                continue
            } else { return nil }
        case .token(.url): continue
        default: return nil
        }
    }
    return .list(items)
}

/// Parse the value of one longhand; `c` has no whitespace and keeps commas.
func cssParseLonghand(_ p: CSSProp, _ c: [CSSComponent], resolveURL: ((String) -> String)?) -> CSSValue? {
    if let names = cssKeywordTable(p) {
        guard c.count == 1, let id = cssIdent(c[0]) else {
            // `first baseline` style two-word values are not supported.
            return nil
        }
        let k = cssKeywordAlias(p, id)
        guard let idx = names.firstIndex(of: k) else { return nil }
        if p == .alignSelf || p == .alignItems {
            // align-items has no `auto`.
            if p == .alignItems && k == "auto" { return nil }
        }
        return .keyword(UInt8(idx))
    }
    switch p {
    case .color, .backgroundColor, .borderTopColor, .borderRightColor, .borderBottomColor, .borderLeftColor:
        return c.count == 1 ? cssColorValue(c[0]) : nil
    case .fontSize: return c.count == 1 ? cssParseFontSize(c[0]) : nil
    case .fontFamily: return cssParseFontFamily(c)
    case .fontWeight: return c.count == 1 ? cssParseFontWeight(c[0]) : nil
    case .lineHeight: return c.count == 1 ? cssParseLineHeight(c[0]) : nil
    case .top, .right, .bottom, .left, .marginTop, .marginRight, .marginBottom, .marginLeft:
        return c.count == 1 ? cssDimensionValue(c[0], auto: true, none: false, intrinsic: false, nonNegative: false) : nil
    case .width, .height:
        return c.count == 1 ? cssDimensionValue(c[0], auto: true, none: false, intrinsic: true, nonNegative: true) : nil
    case .minWidth, .minHeight:
        return c.count == 1 ? cssDimensionValue(c[0], auto: true, none: false, intrinsic: true, nonNegative: true) : nil
    case .maxWidth, .maxHeight:
        return c.count == 1 ? cssDimensionValue(c[0], auto: false, none: true, intrinsic: true, nonNegative: true) : nil
    case .paddingTop, .paddingRight, .paddingBottom, .paddingLeft:
        return c.count == 1 ? cssDimensionValue(c[0], auto: false, none: false, intrinsic: false, nonNegative: true) : nil
    case .flexBasis:
        guard c.count == 1 else { return nil }
        if let id = cssIdent(c[0]), id == "content" { return .ident("auto") }
        return cssDimensionValue(c[0], auto: true, none: false, intrinsic: true, nonNegative: true)
    case .textIndent:
        guard c.count == 1, let v = cssParseLengthPercentage(c[0]) else { return nil }
        return .dimension(v)
    case .borderTopWidth, .borderRightWidth, .borderBottomWidth, .borderLeftWidth:
        return c.count == 1 ? cssBorderWidthValue(c[0]) : nil
    case .zIndex:
        guard c.count == 1 else { return nil }
        if let id = cssIdent(c[0]) { return id == "auto" ? .ident("auto") : nil }
        guard case .token(.number(let v, true)) = c[0] else { return nil }
        return .number(max(-2e9, min(2e9, v)), true)
    case .opacity:
        guard c.count == 1 else { return nil }
        if case .token(.percentage(let v)) = c[0] { return .number(max(0, min(1, v / 100)), false) }
        guard let (v, _) = cssParseNumber(c[0]) else { return nil }
        return .number(max(0, min(1, v)), false)
    case .flexGrow, .flexShrink:
        guard c.count == 1, let (v, _) = cssParseNumber(c[0]), v >= 0 else { return nil }
        return .number(v, false)
    case .rowGap, .columnGap:
        guard c.count == 1 else { return nil }
        if let id = cssIdent(c[0]) { return id == "normal" ? .dimension(CSSCalc()) : nil }
        guard let v = cssParseLengthPercentage(c[0]), !v.isNegativeLiteral else { return nil }
        return .dimension(v)
    case .borderSpacingH, .borderSpacingV:
        guard c.count == 1, let v = cssParseLengthPercentage(c[0]), !v.isNegativeLiteral, v.pct == 0 else { return nil }
        return .dimension(v)
    case .verticalAlign:
        guard c.count == 1 else { return nil }
        if let id = cssIdent(c[0]) {
            guard let idx = CSSVerticalAlignKind.cssNames.firstIndex(of: id) else { return nil }
            return .keyword(UInt8(idx))
        }
        guard let v = cssParseLengthPercentage(c[0]) else { return nil }
        return .dimension(v)
    case .textDecorationLine:
        var bits: UInt8 = 0
        guard !c.isEmpty else { return nil }
        for item in c {
            guard let id = cssIdent(item) else { return nil }
            switch id {
            case "none": if c.count != 1 { return nil }
            case "underline": bits |= 1
            case "overline": bits |= 2
            case "line-through": bits |= 4
            case "blink": break
            default: return nil
            }
        }
        return .number(Double(bits), true)
    case .backgroundImage:
        guard c.count == 1 else { return nil }
        if let id = cssIdent(c[0]) { return id == "none" ? .ident("none") : nil }
        guard let u = cssURLString(c[0]) else { return nil }
        return .url(resolveURL?(u) ?? u)
    case .content: return cssParseContent(c)
    case .cursor:
        for item in c { if let id = cssIdent(item) { return .ident(id) } }
        return nil
    default: return nil
    }
}

// MARK: - Shorthands

private func cssEdges(_ comps: [CSSComponent]) -> [CSSComponent]? {
    switch comps.count {
    case 1: return [comps[0], comps[0], comps[0], comps[0]]
    case 2: return [comps[0], comps[1], comps[0], comps[1]]
    case 3: return [comps[0], comps[1], comps[2], comps[1]]
    case 4: return comps
    default: return nil
    }
}

private func cssBoxShorthand(_ props: [CSSProp], _ comps: [CSSComponent], _ url: ((String) -> String)?) -> [CSSDeclaration]? {
    guard let e = cssEdges(comps) else { return nil }
    var out: [CSSDeclaration] = []
    for k in 0..<4 {
        guard let v = cssParseLonghand(props[k], [e[k]], resolveURL: url) else { return nil }
        out.append(CSSDeclaration(prop: props[k], kind: .value, value: v))
    }
    return out
}

private func cssPair(_ props: [CSSProp], _ comps: [CSSComponent], _ url: ((String) -> String)?) -> [CSSDeclaration]? {
    var e: [CSSComponent]
    switch comps.count {
    case 1: e = [comps[0], comps[0]]
    case 2: e = comps
    default: return nil
    }
    var out: [CSSDeclaration] = []
    for k in 0..<2 {
        guard let v = cssParseLonghand(props[k], [e[k]], resolveURL: url) else { return nil }
        out.append(CSSDeclaration(prop: props[k], kind: .value, value: v))
    }
    return out
}

private func cssBorderSide(_ w: CSSProp, _ s: CSSProp, _ c: CSSProp, _ comps: [CSSComponent]) -> [CSSDeclaration]? {
    var width: CSSValue? = nil, style: CSSValue? = nil, color: CSSValue? = nil
    guard !comps.isEmpty else { return nil }
    for item in comps {
        if width == nil, let v = cssBorderWidthValue(item) { width = v; continue }
        if style == nil, let v = cssParseLonghand(s, [item], resolveURL: nil) { style = v; continue }
        if color == nil, let v = cssColorValue(item) { color = v; continue }
        return nil
    }
    func mk(_ p: CSSProp, _ v: CSSValue?) -> CSSDeclaration {
        v.map { CSSDeclaration(prop: p, kind: .value, value: $0) } ?? CSSDeclaration(prop: p, kind: .initial)
    }
    return [mk(w, width), mk(s, style), mk(c, color)]
}

private func cssParseBackground(_ comps: [CSSComponent], _ url: ((String) -> String)?) -> [CSSDeclaration]? {
    var color: CSSValue? = nil, image: CSSValue? = nil, rep: CSSValue? = nil
    guard !comps.isEmpty else { return nil }
    // Layers are comma separated; only the last (bottom) layer's color counts, the
    // first image wins. Everything else (position, size, attachment, box) is skipped.
    var sawComma = false
    for item in comps {
        switch item {
        case .token(.comma): sawComma = true
        case .token(.ident(let s)):
            let l = cssLower(s)
            if l == "none" { if image == nil { image = .ident("none") } }
            else if let v = cssColorValue(item) { color = v }
            else if let k = CSSBackgroundRepeat.cssNames.firstIndex(of: l) { if !sawComma { rep = .keyword(UInt8(k)) } }
            else if l == "no-repeat" {}
            else if ["repeat", "space", "round", "scroll", "fixed", "local", "left", "right", "top", "bottom",
                     "center", "border-box", "padding-box", "content-box", "cover", "contain", "auto",
                     "text"].contains(l) {}
            else { return nil }
        case .function(let n, _):
            let ln = cssLower(n)
            if ln == "url" { if let u = cssURLString(item), image == nil { image = .url(url?(u) ?? u) } }
            else if let v = cssColorValue(item) { color = v }
            else if ln.hasSuffix("gradient") || ln == "image-set" || ln == "-webkit-image-set" { if image == nil { image = .ident("none") } }
            else if ln == "calc" {}
            else { return nil }
        case .token(.url(let u)): if image == nil { image = .url(url?(u) ?? u) }
        case .token(.hash): if let v = cssColorValue(item) { color = v } else { return nil }
        case .token(.dimension), .token(.percentage), .token(.number), .token(.delim(0x2f)): break
        default: return nil
        }
    }
    func mk(_ p: CSSProp, _ v: CSSValue?) -> CSSDeclaration {
        v.map { CSSDeclaration(prop: p, kind: .value, value: $0) } ?? CSSDeclaration(prop: p, kind: .initial)
    }
    return [mk(.backgroundColor, color), mk(.backgroundImage, image), mk(.backgroundRepeat, rep)]
}

private func cssParseFont(_ comps: [CSSComponent]) -> [CSSDeclaration]? {
    var style: CSSValue? = nil, weight: CSSValue? = nil
    var i = 0
    var size: CSSValue? = nil
    while i < comps.count {
        let item = comps[i]
        if let id = cssIdent(item) {
            if id == "normal" { i += 1; continue }
            if id == "italic" || id == "oblique" { style = .keyword(id == "italic" ? 1 : 2); i += 1; continue }
            if id == "bold" || id == "bolder" || id == "lighter" { weight = .ident(id); i += 1; continue }
            if id == "small-caps" || id.hasSuffix("condensed") || id.hasSuffix("expanded") { i += 1; continue }
        }
        if case .token(.number(let v, true)) = item, v >= 1, v <= 1000 { weight = .number(v, true); i += 1; continue }
        size = cssParseFontSize(item)
        if size == nil { return nil }
        i += 1
        break
    }
    guard let sz = size else { return nil }
    var lh: CSSValue? = nil
    if i < comps.count, case .token(.delim(0x2f)) = comps[i] {
        guard i + 1 < comps.count, let v = cssParseLineHeight(comps[i + 1]) else { return nil }
        lh = v
        i += 2
    }
    guard i < comps.count, let fam = cssParseFontFamily(Array(comps[i...])) else { return nil }
    func mk(_ p: CSSProp, _ v: CSSValue?) -> CSSDeclaration {
        v.map { CSSDeclaration(prop: p, kind: .value, value: $0) } ?? CSSDeclaration(prop: p, kind: .initial)
    }
    return [mk(.fontStyle, style), mk(.fontWeight, weight), CSSDeclaration(prop: .fontSize, kind: .value, value: sz),
            mk(.lineHeight, lh), CSSDeclaration(prop: .fontFamily, kind: .value, value: fam)]
}

private func cssParseListStyle(_ comps: [CSSComponent]) -> [CSSDeclaration]? {
    var type: CSSValue? = nil, pos: CSSValue? = nil
    var sawNone = 0
    guard !comps.isEmpty else { return nil }
    for item in comps {
        if let id = cssIdent(item) {
            if id == "none" { sawNone += 1; continue }
            if let v = cssParseLonghand(.listStylePosition, [item], resolveURL: nil) { pos = v; continue }
            if let v = cssParseLonghand(.listStyleType, [item], resolveURL: nil) { type = v; continue }
            return nil
        }
        if cssURLString(item) != nil { continue }
        return nil
    }
    if type == nil && sawNone > 0 { type = .keyword(0) }
    func mk(_ p: CSSProp, _ v: CSSValue?) -> CSSDeclaration {
        v.map { CSSDeclaration(prop: p, kind: .value, value: $0) } ?? CSSDeclaration(prop: p, kind: .initial)
    }
    return [mk(.listStyleType, type), mk(.listStylePosition, pos)]
}

private func cssParseFlex(_ comps: [CSSComponent]) -> [CSSDeclaration]? {
    func out(_ g: Double, _ s: Double, _ b: CSSValue) -> [CSSDeclaration] {
        [CSSDeclaration(prop: .flexGrow, kind: .value, value: .number(g, false)),
         CSSDeclaration(prop: .flexShrink, kind: .value, value: .number(s, false)),
         CSSDeclaration(prop: .flexBasis, kind: .value, value: b)]
    }
    if comps.count == 1, let id = cssIdent(comps[0]) {
        switch id {
        case "none": return out(0, 0, .ident("auto"))
        case "auto": return out(1, 1, .ident("auto"))
        case "initial": return out(0, 1, .ident("auto"))
        default: break
        }
    }
    var nums: [Double] = []
    var basis: CSSValue? = nil
    guard !comps.isEmpty, comps.count <= 3 else { return nil }
    for item in comps {
        if case .token(.number(let v, _)) = item, v >= 0 {
            // A third bare number can't be a basis; unitless 0 is a basis only after two numbers.
            if nums.count < 2 && basis == nil { nums.append(v); continue }
            if v == 0 && basis == nil && nums.count >= 1 { basis = .dimension(CSSCalc()); continue }
            return nil
        }
        if basis == nil, let v = cssParseLonghand(.flexBasis, [item], resolveURL: nil) { basis = v; continue }
        return nil
    }
    if nums.isEmpty && basis == nil { return nil }
    let g = nums.count > 0 ? nums[0] : 1
    let s = nums.count > 1 ? nums[1] : 1
    return out(g, s, basis ?? .dimension(.percent(0)))
}

private func cssParseOverflow(_ comps: [CSSComponent]) -> [CSSDeclaration]? {
    guard comps.count == 1 || comps.count == 2 else { return nil }
    guard let x = cssParseLonghand(.overflowX, [comps[0]], resolveURL: nil),
          let y = cssParseLonghand(.overflowY, [comps[comps.count - 1]], resolveURL: nil) else { return nil }
    return [CSSDeclaration(prop: .overflowX, kind: .value, value: x), CSSDeclaration(prop: .overflowY, kind: .value, value: y)]
}

private func cssParseTextDecoration(_ comps: [CSSComponent]) -> [CSSDeclaration]? {
    var lines: [CSSComponent] = []
    guard !comps.isEmpty else { return nil }
    for item in comps {
        if let id = cssIdent(item) {
            if id == "underline" || id == "overline" || id == "line-through" || id == "none" || id == "blink" {
                lines.append(item); continue
            }
            if ["solid", "double", "dotted", "dashed", "wavy"].contains(id) { continue }
        }
        if cssColorValue(item) != nil { continue }
        if case .token(.dimension) = item { continue }
        if case .token(.number) = item { continue }
        return nil
    }
    let v = lines.isEmpty ? CSSValue.number(0, true) : (cssParseLonghand(.textDecorationLine, lines, resolveURL: nil) ?? .number(0, true))
    return [CSSDeclaration(prop: .textDecorationLine, kind: .value, value: v)]
}

/// Expand one (canonical lowercase) declaration into longhands; nil if the
/// property is unknown or the value is invalid.
func cssExpandDeclaration(_ name: String, _ comps: [CSSComponent], resolveURL: ((String) -> String)?) -> [CSSDeclaration]? {
    if let p = cssLonghandNames[name] {
        guard let v = cssParseLonghand(p, comps, resolveURL: resolveURL) else { return nil }
        return [CSSDeclaration(prop: p, kind: .value, value: v)]
    }
    switch name {
    case "margin": return cssBoxShorthand([.marginTop, .marginRight, .marginBottom, .marginLeft], comps, resolveURL)
    case "padding": return cssBoxShorthand([.paddingTop, .paddingRight, .paddingBottom, .paddingLeft], comps, resolveURL)
    case "inset": return cssBoxShorthand([.top, .right, .bottom, .left], comps, resolveURL)
    case "margin-inline": return cssPair([.marginLeft, .marginRight], comps, resolveURL)
    case "margin-block": return cssPair([.marginTop, .marginBottom], comps, resolveURL)
    case "padding-inline": return cssPair([.paddingLeft, .paddingRight], comps, resolveURL)
    case "padding-block": return cssPair([.paddingTop, .paddingBottom], comps, resolveURL)
    case "border-width":
        return cssBoxShorthand([.borderTopWidth, .borderRightWidth, .borderBottomWidth, .borderLeftWidth], comps, resolveURL)
    case "border-style":
        return cssBoxShorthand([.borderTopStyle, .borderRightStyle, .borderBottomStyle, .borderLeftStyle], comps, resolveURL)
    case "border-color":
        return cssBoxShorthand([.borderTopColor, .borderRightColor, .borderBottomColor, .borderLeftColor], comps, resolveURL)
    case "border":
        guard let t = cssBorderSide(.borderTopWidth, .borderTopStyle, .borderTopColor, comps) else { return nil }
        var out: [CSSDeclaration] = []
        let sides: [(CSSProp, CSSProp, CSSProp)] = [
            (.borderTopWidth, .borderTopStyle, .borderTopColor), (.borderRightWidth, .borderRightStyle, .borderRightColor),
            (.borderBottomWidth, .borderBottomStyle, .borderBottomColor), (.borderLeftWidth, .borderLeftStyle, .borderLeftColor)]
        for (w, s, c) in sides {
            var d0 = t[0], d1 = t[1], d2 = t[2]
            d0.prop = w; d1.prop = s; d2.prop = c
            out.append(d0); out.append(d1); out.append(d2)
        }
        return out
    case "border-top": return cssBorderSide(.borderTopWidth, .borderTopStyle, .borderTopColor, comps)
    case "border-right": return cssBorderSide(.borderRightWidth, .borderRightStyle, .borderRightColor, comps)
    case "border-bottom": return cssBorderSide(.borderBottomWidth, .borderBottomStyle, .borderBottomColor, comps)
    case "border-left": return cssBorderSide(.borderLeftWidth, .borderLeftStyle, .borderLeftColor, comps)
    case "background": return cssParseBackground(comps, resolveURL)
    case "font": return cssParseFont(comps)
    case "list-style": return cssParseListStyle(comps)
    case "overflow": return cssParseOverflow(comps)
    case "flex": return cssParseFlex(comps)
    case "flex-flow":
        var dir: CSSValue? = nil, wrap: CSSValue? = nil
        guard !comps.isEmpty, comps.count <= 2 else { return nil }
        for item in comps {
            if dir == nil, let v = cssParseLonghand(.flexDirection, [item], resolveURL: nil) { dir = v; continue }
            if wrap == nil, let v = cssParseLonghand(.flexWrap, [item], resolveURL: nil) { wrap = v; continue }
            return nil
        }
        return [dir.map { CSSDeclaration(prop: .flexDirection, kind: .value, value: $0) } ?? CSSDeclaration(prop: .flexDirection, kind: .initial),
                wrap.map { CSSDeclaration(prop: .flexWrap, kind: .value, value: $0) } ?? CSSDeclaration(prop: .flexWrap, kind: .initial)]
    case "gap": return cssPair([.rowGap, .columnGap], comps, resolveURL)
    case "border-spacing": return cssPair([.borderSpacingH, .borderSpacingV], comps, resolveURL)
    case "text-decoration": return cssParseTextDecoration(comps)
    default: return nil
    }
}

/// Make the declarations for `name: value`: custom properties keep their raw
/// value, values using var() are kept as pending (one per longhand covered),
/// everything else is validated and expanded. Unknown or invalid: nothing.
func cssMakeDeclarations(name rawName: String, _ comps: [CSSComponent], important: Bool,
                         resolveURL: ((String) -> String)?) -> [CSSDeclaration] {
    var out: [CSSDeclaration] = []
    if rawName.utf8.count >= 2 && rawName.utf8.first == 0x2d && rawName.utf8.dropFirst().first == 0x2d {
        var d = CSSDeclaration(prop: .custom, kind: .custom)
        d.name = rawName; d.raw = comps; d.important = important
        return [d]
    }
    let name = cssCanonicalPropertyName(rawName)
    guard let longhands = cssLonghands(of: name) else { return [] }
    if comps.count == 1, case .token(.ident(let s)) = comps[0], let kind = cssIsCSSWide(s) {
        for p in longhands {
            var d = CSSDeclaration(prop: p, kind: kind)
            d.important = important
            out.append(d)
        }
        return out
    }
    if cssContainsVar(comps) {
        for p in longhands {
            var d = CSSDeclaration(prop: p, kind: .pending)
            d.name = name; d.raw = comps; d.important = important
            out.append(d)
        }
        return out
    }
    guard var ds = cssExpandDeclaration(name, comps, resolveURL: resolveURL) else { return [] }
    for k in 0..<ds.count { ds[k].important = important }
    return ds
}
