// Styling the DOM: HTMLNode as a CSSElement (through a small wrapper that
// carries the browser's :hover set), and HTML presentational hints
// (bgcolor, width, align, cellpadding, <font>, ...), which the CSS library
// does not know about. Hints cascade below every author rule (see
// CSSStyleResolver.computeStyle(_:parent:hints:)).

/// State shared by every LayoutElement of a document.
final class LayoutStyleState {
    /// Elements in the hover chain (the element under the pointer and its ancestors).
    var hovered: Set<ObjectIdentifier> = []
    /// Split class lists (selector matching asks for them over and over).
    var classes: [ObjectIdentifier: [String]] = [:]
    init() {}
}

/// An element as the selector matcher sees it.
struct LayoutElement: CSSElement {
    let node: HTMLNode
    unowned(unsafe) let state: LayoutStyleState

    init(_ node: HTMLNode, _ state: LayoutStyleState) { self.node = node; self.state = state }

    var cssTagName: String { node.name }
    var cssID: String { node.attribute("id") ?? "" }
    var cssClasses: [String] {
        let k = ObjectIdentifier(node)
        if let c = state.classes[k] { return c }
        let c = node.classNames
        state.classes[k] = c
        return c
    }
    func cssAttribute(_ name: String) -> String? { node.attribute(name) }
    var cssParent: LayoutElement? {
        guard let p = node.parent, p.kind == .element else { return nil }
        return LayoutElement(p, state)
    }
    var cssPreviousElementSibling: LayoutElement? {
        guard let p = node.parent else { return nil }
        var i = min(node.index, p.children.count) - 1
        while i >= 0 {
            let c = p.children[i]
            if c.kind == .element { return LayoutElement(c, state) }
            i -= 1
        }
        return nil
    }
    var cssNextElementSibling: LayoutElement? {
        guard let p = node.parent else { return nil }
        var i = node.index + 1
        while i < p.children.count {
            let c = p.children[i]
            if c.kind == .element { return LayoutElement(c, state) }
            i += 1
        }
        return nil
    }
    var cssIsRoot: Bool { node.parent?.kind == .document }
    var cssIsHovered: Bool { !state.hovered.isEmpty && state.hovered.contains(ObjectIdentifier(node)) }
    var cssIsLink: Bool { (node.name == "a" || node.name == "area") && node.attribute("href") != nil }
    var cssIsChecked: Bool {
        if node.name == "input" { return node.attribute("checked") != nil }
        if node.name == "option" { return node.attribute("selected") != nil }
        return false
    }
    var cssIsDisabled: Bool { node.attribute("disabled") != nil }
    var cssIsEmpty: Bool {
        for c in node.children {
            if c.kind == .element { return false }
            if c.kind == .text && !c.data.isEmpty { return false }
        }
        return true
    }
    var cssSiblingIndex: Int {
        guard let p = node.parent else { return 1 }
        var n = 1
        var i = 0
        let end = min(node.index, p.children.count)
        while i < end { if p.children[i].kind == .element { n += 1 }; i += 1 }
        return n
    }
    var cssSiblingCount: Int {
        guard let p = node.parent else { return 1 }
        var n = 0
        for c in p.children where c.kind == .element { n += 1 }
        return n
    }

    // Shadow DOM.
    var cssTreeScope: CSSTreeScope { layoutTreeScope(node) }
    var cssShadowHost: LayoutElement? {
        guard node.documentHasShadowTrees, let h = node.rootNode.host else { return nil }
        return LayoutElement(h, state)
    }
    var cssShadowRootScope: Int? {
        guard let s = node.attachedShadowRoot else { return nil }
        return layoutScopeID(s)
    }
    var cssAssignedSlot: LayoutElement? {
        guard let s = node.assignedSlotIncludingClosed else { return nil }
        return LayoutElement(s, state)
    }
    var cssPartNames: [String] {
        guard let p = node.attribute("part") else { return [] }
        return htmlSplitWhitespace(p)
    }
    var cssExportParts: [(String, String)] {
        guard let p = node.attribute("exportparts") else { return [] }
        return cssParseExportParts(p)
    }
    var cssIsDefined: Bool { node.isDefined }
}

/// The CSS scope id of a shadow root (stable while it lives).
func layoutScopeID(_ root: HTMLNode) -> Int {
    Int(bitPattern: UInt(bitPattern: ObjectIdentifier(root)))
}

/// The tree scope of a node: the document (id 0) or its shadow root, and
/// how many shadow roots deep that is.
func layoutTreeScope(_ n: HTMLNode) -> CSSTreeScope {
    guard n.documentHasShadowTrees else { return CSSTreeScope() }
    let root = n.rootNode
    guard root.isShadowRoot else { return CSSTreeScope() }
    var depth = 1
    var h = root.host
    var k = 0
    while let x = h, k < 4096 {
        guard let r = x.rootNode.host else { break }
        depth += 1
        h = r
        k += 1
    }
    return CSSTreeScope(id: layoutScopeID(root), depth: depth)
}

/// The parent to walk for rendering: the flat-tree parent, a shadow root's
/// host, and (for nodes outside the flat tree, which have no boxes) nil.
func layoutFlatParent(_ n: HTMLNode) -> HTMLNode? {
    if n.isShadowRoot { return n.host }
    return n.flatTreeParent
}

// MARK: - Presentational hints

/// Attribute values go into CSS text, so only harmless characters pass.
private func layoutHintSafe(_ v: String) -> String? {
    var out: [UInt8] = []
    for b in v.utf8 {
        if out.count > 64 { return nil }
        switch b {
        case 0x30...0x39, 0x41...0x5a, 0x61...0x7a, 0x23, 0x2e, 0x25, 0x2d, 0x2b: out.append(b)
        case 0x20, 0x09, 0x0a, 0x0d: if !out.isEmpty { out.append(0x20) }
        default: return nil
        }
    }
    while out.last == 0x20 { out.removeLast() }
    return out.isEmpty ? nil : String(decoding: out, as: UTF8.self)
}

/// HTML "rules for parsing dimension values": digits[.digits][%].
func layoutParseHTMLLength(_ v: String) -> String? {
    var digits: [UInt8] = []
    var seenDot = false
    var pct = false
    var started = false
    for b in v.utf8 {
        if !started && (b == 0x20 || b == 0x09 || b == 0x0a) { continue }
        started = true
        if b >= 0x30 && b <= 0x39 { digits.append(b); if digits.count > 9 { return nil } }
        else if b == 0x2e && !seenDot && !digits.isEmpty { seenDot = true; digits.append(b) }
        else { if b == 0x25 { pct = true }; break }
    }
    while digits.last == 0x2e { digits.removeLast() }
    if digits.isEmpty { return nil }
    return String(decoding: digits, as: UTF8.self) + (pct ? "%" : "px")
}

private func layoutParseHTMLInt(_ v: String) -> Int? {
    var n = 0
    var any = false
    var neg = false
    var started = false
    for b in v.utf8 {
        if !started && (b == 0x20 || b == 0x09 || b == 0x0a) { continue }
        if !started && (b == 0x2d || b == 0x2b) { started = true; neg = b == 0x2d; continue }
        started = true
        if b >= 0x30 && b <= 0x39 { n = min(n * 10 + Int(b - 0x30), 1_000_000); any = true } else { break }
    }
    return any ? (neg ? -n : n) : nil
}

/// A legacy color attribute value as CSS ("ff6600" -> "#ff6600").
private func layoutHintColor(_ v: String) -> String? {
    guard let s = layoutHintSafe(v), !s.contains(" ") else { return nil }
    let u = Array(s.utf8)
    if u.first == 0x23 { return s }
    var hex = true
    for b in u where !((b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x46) || (b >= 0x61 && b <= 0x66)) { hex = false }
    if hex && (u.count == 3 || u.count == 6) { return "#" + s }
    return s
}

private func layoutLower(_ s: String) -> String {
    var out: [UInt8] = []
    for b in s.utf8 { out.append(b >= 0x41 && b <= 0x5a ? b + 32 : b) }
    return String(decoding: out, as: UTF8.self)
}

private func layoutEnclosingTable(_ n: HTMLNode) -> HTMLNode? {
    var p = n.parent
    var k = 0
    while let q = p, k < 6 {
        if q.kind == .element && q.name == "table" { return q }
        p = q.parent
        k += 1
    }
    return nil
}

/// CSS text for the element's presentational hints ("" if none).
func layoutHintCSS(_ n: HTMLNode) -> String {
    if n.attributes.isEmpty && n.name != "td" && n.name != "th" { return "" }
    var css = ""
    func add(_ s: String) { css += s; css += ";" }
    let name = n.name
    func color(_ attr: String, _ prop: String) {
        if let v = n.attribute(attr), let c = layoutHintColor(v) { add(prop + ":" + c) }
    }
    func length(_ attr: String, _ prop: String) {
        if let v = n.attribute(attr), let l = layoutParseHTMLLength(v) { add(prop + ":" + l) }
    }
    func textAlign() {
        if let v = n.attribute("align") {
            switch layoutLower(v) {
            case "left": add("text-align:left")
            case "right": add("text-align:right")
            case "center", "middle": add("text-align:center")
            case "justify": add("text-align:justify")
            default: break
            }
        }
    }
    func vAlign() {
        if let v = n.attribute("valign") {
            switch layoutLower(v) {
            case "top": add("vertical-align:top")
            case "middle", "center": add("vertical-align:middle")
            case "bottom": add("vertical-align:bottom")
            case "baseline": add("vertical-align:baseline")
            default: break
            }
        }
    }
    switch name {
    case "body":
        color("bgcolor", "background-color")
        color("text", "color")
    case "table":
        color("bgcolor", "background-color")
        length("width", "width")
        length("height", "height")
        if let v = n.attribute("cellspacing"), let k = layoutParseHTMLInt(v), k >= 0 { add("border-spacing:\(min(k, 1000))px") }
        if let v = n.attribute("border") {
            let k = layoutParseHTMLInt(v) ?? 1
            if k > 0 { add("border:\(min(k, 100))px outset gray") }
        }
        if let v = n.attribute("align") {
            switch layoutLower(v) {
            case "left": add("float:left")
            case "right": add("float:right")
            case "center": add("margin-left:auto;margin-right:auto")
            default: break
            }
        }
    case "td", "th":
        color("bgcolor", "background-color")
        length("width", "width")
        length("height", "height")
        textAlign()
        vAlign()
        if n.attribute("nowrap") != nil { add("white-space:nowrap") }
        if let t = layoutEnclosingTable(n) {
            if let v = t.attribute("cellpadding"), let k = layoutParseHTMLInt(v), k >= 0 { add("padding:\(min(k, 1000))px") }
            if let v = t.attribute("border"), (layoutParseHTMLInt(v) ?? 1) > 0 { add("border:1px inset gray") }
        }
    case "tr", "thead", "tbody", "tfoot":
        color("bgcolor", "background-color")
        textAlign()
        vAlign()
        if name == "tr" { length("height", "height") }
    case "col", "colgroup":
        length("width", "width")
    case "img", "iframe", "video", "canvas", "embed", "object", "svg":
        length("width", "width")
        length("height", "height")
        if name == "img" || name == "object" {
            if let v = n.attribute("border"), let k = layoutParseHTMLInt(v), k > 0 { add("border:\(min(k, 100))px solid") }
            if let v = n.attribute("hspace"), let k = layoutParseHTMLInt(v), k > 0 { add("margin-left:\(min(k, 1000))px;margin-right:\(min(k, 1000))px") }
            if let v = n.attribute("vspace"), let k = layoutParseHTMLInt(v), k > 0 { add("margin-top:\(min(k, 1000))px;margin-bottom:\(min(k, 1000))px") }
            if let v = n.attribute("align") {
                switch layoutLower(v) {
                case "left": add("float:left")
                case "right": add("float:right")
                case "middle", "absmiddle", "center": add("vertical-align:middle")
                case "top": add("vertical-align:top")
                case "texttop": add("vertical-align:text-top")
                case "bottom", "baseline", "absbottom": add("vertical-align:baseline")
                default: break
                }
            }
        }
    case "div", "p", "h1", "h2", "h3", "h4", "h5", "h6", "caption", "legend":
        textAlign()
    case "font":
        color("color", "color")
        if let v = n.attribute("face"), let f = layoutHintSafe(v) {
            var names = ""
            htmlForEachToken(f.replacingOccurrences(",", " ")) { w in names += (names.isEmpty ? "" : ",") + "\"" + w + "\"" }
            if !names.isEmpty { add("font-family:" + names) }
        }
        if let v = n.attribute("size"), let k0 = layoutParseHTMLInt(v) {
            let u = Array(v.utf8)
            var k = k0
            if let f = u.first(where: { $0 != 0x20 }), f == 0x2b || f == 0x2d { k = 3 + k0 }
            let sizes = ["x-small", "x-small", "small", "medium", "large", "x-large", "xx-large", "xxx-large"]
            add("font-size:" + sizes[max(1, min(7, k))])
        }
    case "hr":
        length("width", "width")
        if let v = n.attribute("size"), let k = layoutParseHTMLInt(v), k > 0 { add("height:\(min(k, 1000) - min(k, 2))px") }
        color("color", "border-color")
        if let v = n.attribute("align") {
            switch layoutLower(v) {
            case "left": add("margin-left:0")
            case "right": add("margin-right:0")
            default: break
            }
        }
    case "br":
        if let v = n.attribute("clear") {
            switch layoutLower(v) {
            case "left": add("clear:left")
            case "right": add("clear:right")
            case "all", "both": add("clear:both")
            default: break
            }
        }
    case "ul", "ol", "li", "dl", "dir", "menu":
        if n.attribute("compact") != nil {}
    default:
        break
    }
    return css
}

extension String {
    /// Minimal replacement helper (no Foundation).
    fileprivate func replacingOccurrences(_ a: Character, _ b: Character) -> String {
        var out = ""
        for c in self { out.append(c == a ? b : c) }
        return out
    }
}

/// Parsed hint declarations for an element.
func layoutHints(_ n: HTMLNode) -> [CSSDeclaration] {
    let css = layoutHintCSS(n)
    if css.isEmpty { return [] }
    return cssParseInlineStyle(css)
}
