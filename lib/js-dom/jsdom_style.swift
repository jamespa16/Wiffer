// CSSOM: element.style (a CSSStyleDeclaration over the style attribute)
// and getComputedStyle (read-only, from lib/layout's forced computed style).
//
// The inline declaration list is re-read from the style attribute on every
// access (so setAttribute("style") and the IDL stay in step) and written
// back as the attribute's serialization. Values are validated with
// lib/css's declaration parser (cssMakeDeclarations) for the properties it
// knows; other real CSS properties (transform, transition, ...) are kept as
// given, since scripts read back what they set. Shorthands are stored as
// declared (no expansion into longhands for getPropertyValue).

final class JSDOMStyleDeclaration {
    let node: HTMLNode?
    /// getComputedStyle: a snapshot of (property, value) pairs.
    let computed: [(String, String)]?
    init(node: HTMLNode) { self.node = node; computed = nil }
    init(computed: [(String, String)]) { node = nil; self.computed = computed }
}

struct JSDOMDecl {
    var name: String
    var value: String
    var important: Bool
}

/// CSS properties exposed as style.camelCase / style["dashed-name"].
let jsdomStyleProperties: [String] = [
    "align-content", "align-items", "align-self", "animation", "animation-delay", "animation-direction",
    "animation-duration", "animation-fill-mode", "animation-iteration-count", "animation-name",
    "animation-play-state", "animation-timing-function", "appearance", "aspect-ratio", "backdrop-filter",
    "backface-visibility", "background", "background-attachment", "background-clip", "background-color",
    "background-image", "background-origin", "background-position", "background-position-x",
    "background-position-y", "background-repeat", "background-size", "block-size", "border", "border-bottom",
    "border-bottom-color", "border-bottom-left-radius", "border-bottom-right-radius", "border-bottom-style",
    "border-bottom-width", "border-collapse", "border-color", "border-image", "border-left", "border-left-color",
    "border-left-style", "border-left-width", "border-radius", "border-right", "border-right-color",
    "border-right-style", "border-right-width", "border-spacing", "border-style", "border-top",
    "border-top-color", "border-top-left-radius", "border-top-right-radius", "border-top-style",
    "border-top-width", "border-width", "bottom", "box-shadow", "box-sizing", "caption-side", "caret-color",
    "clear", "clip", "clip-path", "color", "color-scheme", "column-count", "column-gap", "columns", "contain",
    "content", "counter-increment", "counter-reset", "cursor", "direction", "display", "empty-cells", "fill",
    "fill-opacity", "filter", "flex", "flex-basis", "flex-direction", "flex-flow", "flex-grow", "flex-shrink",
    "flex-wrap", "float", "font", "font-family", "font-feature-settings", "font-size", "font-stretch",
    "font-style", "font-variant", "font-weight", "gap", "grid", "grid-area", "grid-auto-columns",
    "grid-auto-flow", "grid-auto-rows", "grid-column", "grid-column-end", "grid-column-start", "grid-row",
    "grid-row-end", "grid-row-start", "grid-template", "grid-template-areas", "grid-template-columns",
    "grid-template-rows", "height", "hyphens", "inline-size", "inset", "isolation", "justify-content",
    "justify-items", "justify-self", "left", "letter-spacing", "line-height", "list-style", "list-style-image",
    "list-style-position", "list-style-type", "margin", "margin-block-end", "margin-block-start",
    "margin-bottom", "margin-inline-end", "margin-inline-start", "margin-left", "margin-right", "margin-top",
    "mask", "mask-image", "max-height", "max-width", "min-height", "min-width", "mix-blend-mode", "object-fit",
    "object-position", "opacity", "order", "outline", "outline-color", "outline-offset", "outline-style",
    "outline-width", "overflow", "overflow-wrap", "overflow-x", "overflow-y", "overscroll-behavior", "padding",
    "padding-bottom", "padding-left", "padding-right", "padding-top", "page-break-after", "page-break-before",
    "perspective", "place-content", "place-items", "pointer-events", "position", "quotes", "resize", "right",
    "rotate", "row-gap", "scale", "scroll-behavior", "scroll-margin", "scroll-padding", "stroke",
    "stroke-dasharray", "stroke-width", "tab-size", "table-layout", "text-align", "text-decoration",
    "text-decoration-color", "text-decoration-line", "text-decoration-style", "text-indent", "text-overflow",
    "text-shadow", "text-transform", "top", "touch-action", "transform", "transform-origin", "transition",
    "transition-delay", "transition-duration", "transition-property", "transition-timing-function",
    "translate", "unicode-bidi", "user-select", "vertical-align", "visibility", "white-space", "width",
    "will-change", "word-break", "word-spacing", "word-wrap", "writing-mode", "z-index", "zoom",
    "-webkit-appearance", "-webkit-transform", "-webkit-transition", "-webkit-user-select",
    "-webkit-box-sizing", "-webkit-text-size-adjust", "-webkit-font-smoothing", "-moz-box-sizing",
]

/// "background-color" -> "backgroundColor"; "-webkit-transform" -> "webkitTransform".
func jsdomCamelCase(_ s: String) -> String {
    var out: [UInt8] = []
    var up = false
    var first = true
    for b in s.utf8 {
        if b == 0x2d {
            if first { first = false; continue }
            up = true
            continue
        }
        first = false
        if up && b >= 0x61 && b <= 0x7a { out.append(b - 0x20) } else { out.append(b) }
        up = false
    }
    return String(decoding: out, as: UTF8.self)
}

/// Parse a declaration list's text into declarations (no validation).
func jsdomParseDeclarations(_ text: String) -> [JSDOMDecl] {
    let b = Array(text.utf8)
    var out: [JSDOMDecl] = []
    var i = 0
    while i < b.count && out.count < 10_000 {
        // One declaration up to a top-level ';'.
        var depth = 0
        var quote: UInt8 = 0
        let start = i
        var colon = -1
        while i < b.count {
            let c = b[i]
            if quote != 0 {
                if c == 0x5c { i += 2; continue }
                if c == quote { quote = 0 }
            } else if c == 0x22 || c == 0x27 { quote = c }
            else if c == 0x2f && i + 1 < b.count && b[i + 1] == 0x2a {
                i += 2
                while i + 1 < b.count && !(b[i] == 0x2a && b[i + 1] == 0x2f) { i += 1 }
                i += 1
            }
            else if c == 0x28 || c == 0x5b { depth += 1 }
            else if c == 0x29 || c == 0x5d { if depth > 0 { depth -= 1 } }
            else if c == 0x3a && colon < 0 && depth == 0 { colon = i }
            else if c == 0x3b && depth == 0 { break }
            i += 1
        }
        let end = min(i, b.count)
        i += 1
        guard colon > start else { continue }
        let name = jsdomTrim(Array(b[start..<colon]))
        var value = jsdomTrim(Array(b[(colon + 1)..<end]))
        var important = false
        // "!important" at the end (ASCII case-insensitive, optional spaces).
        if let bang = value.lastIndex(of: 0x21) {
            let tail = String(decoding: jsdomTrim(Array(value[(bang + 1)...])), as: UTF8.self)
            if htmlLowerASCII(tail) == "important" {
                important = true
                value = jsdomTrim(Array(value[..<bang]))
            }
        }
        if name.isEmpty || value.isEmpty { continue }
        var n = String(decoding: name, as: UTF8.self)
        if !n.hasPrefix("--") { n = htmlLowerASCII(n) }
        out.append(JSDOMDecl(name: n, value: String(decoding: value, as: UTF8.self), important: important))
    }
    return out
}

func jsdomTrim(_ b: [UInt8]) -> [UInt8] {
    var s = 0, e = b.count
    while s < e && htmlIsSpaceByte(b[s]) { s += 1 }
    while e > s && htmlIsSpaceByte(b[e - 1]) { e -= 1 }
    return Array(b[s..<e])
}

func jsdomSerializeDeclarations(_ ds: [JSDOMDecl]) -> String {
    var s = ""
    for (i, d) in ds.enumerated() {
        if i > 0 { s += " " }
        s += d.name + ": " + d.value + (d.important ? " !important" : "") + ";"
    }
    return s
}

extension JSDOMBindings {
    func inlineStyle(_ n: HTMLNode) -> JSValue { classes.CSSStyleDeclaration.wrap(JSDOMStyleDeclaration(node: n)) }

    func declarations(_ s: JSDOMStyleDeclaration) -> [JSDOMDecl] {
        if let c = s.computed { return c.map { JSDOMDecl(name: $0.0, value: $0.1, important: false) } }
        guard let n = s.node, let a = n.attribute("style") else { return [] }
        return jsdomParseDeclarations(a)
    }

    func writeDeclarations(_ s: JSDOMStyleDeclaration, _ ds: [JSDOMDecl]) {
        guard let n = s.node else { return }
        n.setAttributeValue("style", jsdomSerializeDeclarations(ds))
    }

    func readOnly(_ s: JSDOMStyleDeclaration) throws(JSThrow) {
        if s.computed != nil { throw throwDOM("NoModificationAllowedError", "The style declaration is read-only.") }
    }

    /// Is `value` acceptable for `name`? (lib/css validates what it knows.)
    func validCSSValue(_ name: String, _ value: String) -> Bool {
        if name.hasPrefix("--") { return true }
        let canonical = cssCanonicalPropertyName(name)
        if cssLonghands(of: canonical) != nil {
            let toks = cssTokenize(Array(value.utf8))
            let comps = cssBuildComponents(toks, 0, toks.count, keepWS: false)
            return !cssMakeDeclarations(name: name, comps, important: false, resolveURL: nil).isEmpty
        }
        if !jsdomStyleProperties.contains(name) { return false }
        // Unbalanced brackets or a stray ';' are never valid.
        var depth = 0
        for b in value.utf8 {
            if b == 0x28 { depth += 1 } else if b == 0x29 { depth -= 1; if depth < 0 { return false } }
            else if b == 0x3b && depth == 0 { return false }
        }
        return depth == 0
    }

    func CSSStyleDeclaration_cssText(_ s: JSDOMStyleDeclaration) throws(JSThrow) -> String {
        if s.computed != nil { return "" }
        return jsdomSerializeDeclarations(declarations(s))
    }

    func CSSStyleDeclaration_set_cssText(_ s: JSDOMStyleDeclaration, _ v: String) throws(JSThrow) {
        try readOnly(s)
        var out: [JSDOMDecl] = []
        for d in jsdomParseDeclarations(v) where validCSSValue(d.name, d.value) {
            out.removeAll { $0.name == d.name }
            out.append(d)
        }
        writeDeclarations(s, out)
    }

    func CSSStyleDeclaration_length(_ s: JSDOMStyleDeclaration) -> Int { declarations(s).count }
    func CSSStyleDeclaration_item(_ s: JSDOMStyleDeclaration, _ i: Int) -> String {
        let ds = declarations(s)
        return i >= 0 && i < ds.count ? ds[i].name : ""
    }

    func propName(_ p: String) -> String { p.hasPrefix("--") ? p : htmlLowerASCII(p) }

    func CSSStyleDeclaration_getPropertyValue(_ s: JSDOMStyleDeclaration, _ p: String) -> String {
        let name = propName(p)
        var found: String? = nil
        for d in declarations(s) where d.name == name { found = d.value }
        if let f = found { return f }
        // A longhand of a declared shorthand: the shorthand's value if it is a single token.
        if s.computed == nil, let sh = jsdomShorthand(of: name) {
            for d in declarations(s) where d.name == sh && !d.value.contains(" ") { found = d.value }
        }
        return found ?? ""
    }

    func CSSStyleDeclaration_getPropertyPriority(_ s: JSDOMStyleDeclaration, _ p: String) -> String {
        let name = propName(p)
        for d in declarations(s) where d.name == name && d.important { return "important" }
        return ""
    }

    func CSSStyleDeclaration_setProperty(_ s: JSDOMStyleDeclaration, _ p: String, _ v: String, _ prio: String) throws(JSThrow) {
        try readOnly(s)
        let name = propName(p)
        let value = String(decoding: jsdomTrim(Array(v.utf8)), as: UTF8.self)
        if value.isEmpty { _ = try CSSStyleDeclaration_removeProperty(s, name); return }
        let important = htmlLowerASCII(prio) == "important"
        if !prio.isEmpty && !important { return }
        if !validCSSValue(name, value) { return }
        var ds = declarations(s)
        if let i = ds.firstIndex(where: { $0.name == name }) {
            ds[i].value = value
            ds[i].important = important
        } else {
            // Setting a longhand overrides a declared shorthand's part of it:
            // keep it simple and append.
            ds.append(JSDOMDecl(name: name, value: value, important: important))
        }
        writeDeclarations(s, ds)
    }

    func CSSStyleDeclaration_removeProperty(_ s: JSDOMStyleDeclaration, _ p: String) throws(JSThrow) -> String {
        try readOnly(s)
        let name = propName(p)
        var ds = declarations(s)
        let old = CSSStyleDeclaration_getPropertyValue(s, name)
        let before = ds.count
        ds.removeAll { $0.name == name || jsdomShorthand(of: $0.name) == nil && jsdomLonghandsOf(name).contains($0.name) }
        if ds.count != before { writeDeclarations(s, ds) }
        return old
    }

    func CSSStyleDeclaration_parentRule(_ s: JSDOMStyleDeclaration) -> JSValue { .null }
    func CSSStyleDeclaration_cssFloat(_ s: JSDOMStyleDeclaration) throws(JSThrow) -> String {
        CSSStyleDeclaration_getPropertyValue(s, "float")
    }
    func CSSStyleDeclaration_set_cssFloat(_ s: JSDOMStyleDeclaration, _ v: String) throws(JSThrow) {
        try CSSStyleDeclaration_setProperty(s, "float", v, "")
    }

    func exotic_CSSStyleDeclaration() -> JSHostExotic<JSDOMStyleDeclaration> {
        var e = JSHostExotic<JSDOMStyleDeclaration>()
        e.length = { [unowned(unsafe) self] s in self.declarations(s).count }
        e.indexedGet = { [unowned(unsafe) self] (realm: JSRealm, s: JSDOMStyleDeclaration, i: Int) throws(JSThrow) -> JSValue? in
            let ds = self.declarations(s)
            return i >= 0 && i < ds.count ? self.str(ds[i].name) : nil
        }
        return e
    }

    /// style.camelCase and style["dashed-name"] accessors for every property.
    func installStyleProperties() {
        let p = protos[JSDOMInterface.CSSStyleDeclaration.rawValue]
        unowned(unsafe) let b = self
        for name in jsdomStyleProperties {
            var names = [name, jsdomCamelCase(name)]
            if name.hasPrefix("-webkit-") { names.append("Webkit" + String(jsdomCamelCase(name).dropFirst(6))) }
            for n in names {
                if n == "float" { continue }
                realm.defineGetter(p, n, setter: { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
                    guard let s = b.classes.CSSStyleDeclaration.unwrap(args.this) else { throw b.illegal("CSSStyleDeclaration", n) }
                    let v = args[0].isNull ? "" : try b.toStr(args[0])
                    try b.CSSStyleDeclaration_setProperty(s, name, v, "")
                    return .undefined
                }) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
                    guard let s = b.classes.CSSStyleDeclaration.unwrap(args.this) else { throw b.illegal("CSSStyleDeclaration", n) }
                    return b.str(b.CSSStyleDeclaration_getPropertyValue(s, name))
                }
            }
        }
    }

    // MARK: getComputedStyle

    func Window_getComputedStyle(_ w: JSDOMBindings, _ el: HTMLNode, _ pseudo: String??) throws(JSThrow) -> JSValue {
        var pairs: [(String, String)] = []
        if el.isConnected, let e = host.layout(), let st = e.computedStyle(of: el) {
            let r = e.box(for: el).map { layoutBoxRect($0) }
            pairs = jsdomComputedPairs(st, rect: r)
        }
        return classes.CSSStyleDeclaration.wrap(JSDOMStyleDeclaration(computed: pairs))
    }

    // MARK: CSS namespace

    func CSS_supports(_ p: String, _ v: String?) -> Bool {
        if let value = v { return validCSSValue(propName(p), value) }
        // supports("(display: flex)")
        let t = String(decoding: jsdomTrim(Array(p.utf8)), as: UTF8.self)
        guard t.hasPrefix("("), t.hasSuffix(")") else { return false }
        let inner = jsdomParseDeclarations(String(t.dropFirst().dropLast()))
        guard let d = inner.first else { return false }
        return validCSSValue(d.name, d.value)
    }

    func CSS_escape(_ s: String) -> String {
        var out = ""
        let scalars = Array(s.unicodeScalars)
        for (i, c) in scalars.enumerated() {
            let v = c.value
            if v == 0 { out += "\u{FFFD}"; continue }
            if (v >= 1 && v <= 0x1f) || v == 0x7f || (i == 0 && v >= 0x30 && v <= 0x39)
                || (i == 1 && v >= 0x30 && v <= 0x39 && scalars[0].value == 0x2d) {
                out += "\\" + jsdomHex(Int(v)) + " "
                continue
            }
            if i == 0 && v == 0x2d && scalars.count == 1 { out += "\\-"; continue }
            if v >= 0x80 || v == 0x2d || v == 0x5f || (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5a) || (v >= 0x61 && v <= 0x7a) {
                out.unicodeScalars.append(c)
                continue
            }
            out += "\\"
            out.unicodeScalars.append(c)
        }
        return out
    }
}

func jsdomHex(_ v: Int) -> String {
    let digits = Array("0123456789abcdef".utf8)
    var out: [UInt8] = []
    var x = v
    repeat { out.append(digits[x & 15]); x >>= 4 } while x > 0
    return String(decoding: out.reversed(), as: UTF8.self)
}

func jsdomShorthand(of longhand: String) -> String? {
    if longhand.hasPrefix("margin-") { return "margin" }
    if longhand.hasPrefix("padding-") { return "padding" }
    if longhand.hasPrefix("background-") { return "background" }
    if longhand.hasPrefix("overflow-") { return "overflow" }
    return nil
}

func jsdomLonghandsOf(_ shorthand: String) -> [String] {
    switch shorthand {
    case "margin", "padding": return ["top", "right", "bottom", "left"].map { shorthand + "-" + $0 }
    case "overflow": return ["overflow-x", "overflow-y"]
    default: return []
    }
}

// MARK: Computed value serialization

func jsdomPx(_ d: Double) -> String {
    if d == d.rounded() && abs(d) < 1e15 { return String(Int(d)) + "px" }
    let r = (d * 1000).rounded() / 1000
    return jsdomFormatNumber(r) + "px"
}

func jsdomColor(_ c: CSSColor) -> String {
    if c.a == 255 { return "rgb(" + String(c.r) + ", " + String(c.g) + ", " + String(c.b) + ")" }
    let a = (Double(c.a) / 255 * 1000).rounded() / 1000
    return "rgba(" + String(c.r) + ", " + String(c.g) + ", " + String(c.b) + ", " + jsdomFormatNumber(a) + ")"
}

func jsdomKeyword<E: CSSKeywordEnum>(_ e: E) -> String where E: RawRepresentable, E.RawValue == UInt8 {
    let i = Int(e.rawValue)
    return i < E.cssNames.count ? E.cssNames[i] : ""
}

func jsdomDimension(_ d: CSSDimension, used: Double?) -> String {
    switch d.kind {
    case .auto: return used.map { jsdomPx($0) } ?? "auto"
    case .none: return "none"
    case .minContent: return "min-content"
    case .maxContent: return "max-content"
    case .fitContent: return "fit-content"
    case .length:
        if d.lp.pct != 0 && d.lp.px == 0 { return used.map { jsdomPx($0) } ?? (jsdomFormatNumber(d.lp.pct) + "%") }
        return jsdomPx(d.lp.px)
    }
}

func jsdomLP(_ l: CSSLP) -> String {
    if l.pct != 0 && l.px == 0 { return jsdomFormatNumber(l.pct) + "%" }
    return jsdomPx(l.px)
}

func jsdomComputedPairs(_ s: CSSComputedStyle, rect: LayoutRect?) -> [(String, String)] {
    var p: [(String, String)] = []
    p.append(("display", jsdomKeyword(s.display)))
    p.append(("position", jsdomKeyword(s.position)))
    p.append(("float", jsdomKeyword(s.float)))
    p.append(("clear", jsdomKeyword(s.clear)))
    p.append(("box-sizing", jsdomKeyword(s.boxSizing)))
    p.append(("visibility", jsdomKeyword(s.visibility)))
    p.append(("overflow-x", jsdomKeyword(s.overflowX)))
    p.append(("overflow-y", jsdomKeyword(s.overflowY)))
    p.append(("overflow", s.overflowX == s.overflowY ? jsdomKeyword(s.overflowX)
              : jsdomKeyword(s.overflowX) + " " + jsdomKeyword(s.overflowY)))
    p.append(("opacity", jsdomFormatNumber(s.opacity)))
    p.append(("z-index", s.zIndex.map { String($0) } ?? "auto"))
    p.append(("color", jsdomColor(s.color)))
    p.append(("background-color", jsdomColor(s.backgroundColor)))
    p.append(("background-image", s.backgroundImage.map { "url(\"" + $0 + "\")" } ?? "none"))
    let cw = rect.map { $0.w - s.borderLeftWidth - s.borderRightWidth } ?? nil
    let ch = rect.map { $0.h - s.borderTopWidth - s.borderBottomWidth } ?? nil
    let padW = (cw ?? 0)
    var contentW: Double? = nil, contentH: Double? = nil
    if let w = cw, let h = ch {
        if s.boxSizing == .borderBox { contentW = w + s.borderLeftWidth + s.borderRightWidth; contentH = h + s.borderTopWidth + s.borderBottomWidth }
        else {
            contentW = w - s.paddingLeft.resolve(padW) - s.paddingRight.resolve(padW)
            contentH = h - s.paddingTop.resolve(padW) - s.paddingBottom.resolve(padW)
        }
    }
    let inline = s.display == .inline
    p.append(("width", inline ? "auto" : jsdomDimension(s.width, used: contentW).replacingAuto(contentW)))
    p.append(("height", inline ? "auto" : jsdomDimension(s.height, used: contentH).replacingAuto(contentH)))
    p.append(("min-width", jsdomDimension(s.minWidth, used: nil)))
    p.append(("min-height", jsdomDimension(s.minHeight, used: nil)))
    p.append(("max-width", jsdomDimension(s.maxWidth, used: nil)))
    p.append(("max-height", jsdomDimension(s.maxHeight, used: nil)))
    p.append(("top", jsdomDimension(s.top, used: nil)))
    p.append(("right", jsdomDimension(s.right, used: nil)))
    p.append(("bottom", jsdomDimension(s.bottom, used: nil)))
    p.append(("left", jsdomDimension(s.left, used: nil)))
    p.append(("margin-top", jsdomDimension(s.marginTop, used: nil).replacingAuto(0)))
    p.append(("margin-right", jsdomDimension(s.marginRight, used: nil).replacingAuto(0)))
    p.append(("margin-bottom", jsdomDimension(s.marginBottom, used: nil).replacingAuto(0)))
    p.append(("margin-left", jsdomDimension(s.marginLeft, used: nil).replacingAuto(0)))
    p.append(("padding-top", jsdomLP(s.paddingTop)))
    p.append(("padding-right", jsdomLP(s.paddingRight)))
    p.append(("padding-bottom", jsdomLP(s.paddingBottom)))
    p.append(("padding-left", jsdomLP(s.paddingLeft)))
    p.append(("border-top-width", jsdomPx(s.borderTopWidth)))
    p.append(("border-right-width", jsdomPx(s.borderRightWidth)))
    p.append(("border-bottom-width", jsdomPx(s.borderBottomWidth)))
    p.append(("border-left-width", jsdomPx(s.borderLeftWidth)))
    p.append(("border-top-style", jsdomKeyword(s.borderTopStyle)))
    p.append(("border-right-style", jsdomKeyword(s.borderRightStyle)))
    p.append(("border-bottom-style", jsdomKeyword(s.borderBottomStyle)))
    p.append(("border-left-style", jsdomKeyword(s.borderLeftStyle)))
    p.append(("border-top-color", jsdomColor(s.borderTopColor)))
    p.append(("border-right-color", jsdomColor(s.borderRightColor)))
    p.append(("border-bottom-color", jsdomColor(s.borderBottomColor)))
    p.append(("border-left-color", jsdomColor(s.borderLeftColor)))
    var fam = ""
    for (i, f) in s.fontFamily.enumerated() {
        if i > 0 { fam += ", " }
        fam += f.contains(" ") ? "\"" + f + "\"" : f
    }
    p.append(("font-family", fam))
    p.append(("font-size", jsdomPx(s.fontSize)))
    p.append(("font-weight", String(s.fontWeight)))
    p.append(("font-style", jsdomKeyword(s.fontStyle)))
    switch s.lineHeight.kind {
    case .normal: p.append(("line-height", "normal"))
    case .number: p.append(("line-height", jsdomPx(s.lineHeight.value * s.fontSize)))
    case .length: p.append(("line-height", jsdomPx(s.lineHeight.value)))
    }
    p.append(("text-align", s.textAlign == .left ? "start" : jsdomKeyword(s.textAlign)))
    p.append(("text-transform", jsdomKeyword(s.textTransform)))
    p.append(("white-space", jsdomKeyword(s.whiteSpace)))
    var deco: [String] = []
    if s.textDecoration.hasUnderline { deco.append("underline") }
    if s.textDecoration.hasOverline { deco.append("overline") }
    if s.textDecoration.hasLineThrough { deco.append("line-through") }
    p.append(("text-decoration-line", deco.isEmpty ? "none" : deco.joined(separator: " ")))
    p.append(("text-indent", jsdomLP(s.textIndent)))
    p.append(("vertical-align", s.verticalAlign.kind == .length ? jsdomPx(s.verticalAlign.lengthPx) : jsdomKeyword(s.verticalAlign.kind)))
    p.append(("list-style-type", jsdomKeyword(s.listStyleType)))
    p.append(("list-style-position", jsdomKeyword(s.listStylePosition)))
    p.append(("flex-direction", jsdomKeyword(s.flexDirection)))
    p.append(("flex-wrap", jsdomKeyword(s.flexWrap)))
    p.append(("flex-grow", jsdomFormatNumber(s.flexGrow)))
    p.append(("flex-shrink", jsdomFormatNumber(s.flexShrink)))
    p.append(("flex-basis", jsdomDimension(s.flexBasis, used: nil)))
    p.append(("justify-content", s.justifyContent == .flexStart ? "normal" : jsdomKeyword(s.justifyContent)))
    p.append(("align-items", s.alignItems == .stretch ? "normal" : jsdomKeyword(s.alignItems)))
    p.append(("align-self", jsdomKeyword(s.alignSelf)))
    p.append(("row-gap", s.rowGap.px == 0 && s.rowGap.pct == 0 ? "normal" : jsdomLP(s.rowGap)))
    p.append(("column-gap", s.columnGap.px == 0 && s.columnGap.pct == 0 ? "normal" : jsdomLP(s.columnGap)))
    p.append(("border-collapse", jsdomKeyword(s.borderCollapse)))
    p.append(("table-layout", jsdomKeyword(s.tableLayout)))
    p.append(("cursor", s.cursor))
    p.append(("pointer-events", "auto"))
    p.append(("transform", "none"))
    p.append(("direction", "ltr"))
    return p
}

extension String {
    func replacingAuto(_ v: Double?) -> String {
        if self == "auto", let x = v { return jsdomPx(x) }
        return self
    }
}
