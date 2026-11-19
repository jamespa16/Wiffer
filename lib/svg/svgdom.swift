// The SVG element tree (ROADMAP Phase 8J). Standalone files come from
// lib/xml; inline <svg> in HTML is converted by lib/layout through the
// builder API (SVGNode(name:attributes:) and append). Both end up as one
// SVGDocument, which the renderer (svgrender.swift) draws.
//
// Styling goes through lib/css: SVGElement is a CSSElement, presentation
// attributes (fill="red") become hint declarations that cascade below every
// author rule, and `<style>` elements in a standalone file are parsed as
// author sheets. An embedder can replace the style computation entirely
// (`SVGDocument.styleProvider`): lib/layout does, so page CSS styles inline
// icons.

struct SVGLimits {
    /// Elements in a document (the XML parser's node cap also applies).
    var maxNodes = 100_000
    /// Shapes and groups drawn in one render (bounds `use` bombs).
    var maxDrawn = 50_000
    /// Nesting of `use` references.
    var maxUseDepth = 16
    /// Path segments in one `d` attribute.
    var maxPathSegments = 200_000
    /// Gradient stops used.
    var maxStops = 256
    /// Largest render, either side.
    var maxDimension = 8192
    /// Nested group opacity / clip layers.
    var maxLayers = 12
    init() {}
}

struct SVGAttribute {
    var name: String
    var value: String
}

final class SVGNode {
    /// Local name, SVG case ("linearGradient").
    let name: String
    var attributes: [SVGAttribute]
    private(set) var children: [SVGNode] = []
    unowned(unsafe) private(set) var parent: SVGNode?
    /// Index among the parent's children.
    private(set) var index = 0
    /// Text content (only kept for <style>).
    var text = ""
    /// The embedder's tag for this node (lib/layout: an index into its
    /// list of HTML nodes); -1 if none.
    var userIndex = -1
    /// Presentation-attribute declarations, parsed once.
    var hintCache: [CSSDeclaration]? = nil
    var classCache: [String]? = nil
    /// Parsed shape geometry (path data, points), once.
    var geometryCache: SVGPath? = nil

    init(name: String, attributes: [SVGAttribute] = []) {
        self.name = name
        self.attributes = attributes
    }

    func append(_ c: SVGNode) {
        c.parent = self
        c.index = children.count
        children.append(c)
    }

    func attr(_ n: String) -> String? {
        for a in attributes where a.name == n { return a.value }
        return nil
    }

    /// href, or the older xlink:href.
    var href: String? { attr("href") ?? attr("xlink:href") }

    var classes: [String] {
        if let c = classCache { return c }
        var out: [String] = []
        if let v = attr("class") {
            var cur: [UInt8] = []
            for b in v.utf8 {
                if b == 0x20 || b == 0x09 || b == 0x0a || b == 0x0d || b == 0x0c {
                    if !cur.isEmpty { out.append(String(decoding: cur, as: UTF8.self)); cur = [] }
                } else { cur.append(b) }
            }
            if !cur.isEmpty { out.append(String(decoding: cur, as: UTF8.self)) }
        }
        classCache = out
        return out
    }
}

/// The node as the selector matcher sees it.
struct SVGElement: CSSElement {
    let node: SVGNode
    init(_ n: SVGNode) { node = n }
    var cssTagName: String { node.name }
    var cssID: String { node.attr("id") ?? "" }
    var cssClasses: [String] { node.classes }
    func cssAttribute(_ name: String) -> String? { node.attr(name) }
    var cssParent: SVGElement? { node.parent.map { SVGElement($0) } }
    var cssPreviousElementSibling: SVGElement? {
        guard let p = node.parent, node.index > 0, node.index - 1 < p.children.count else { return nil }
        return SVGElement(p.children[node.index - 1])
    }
    var cssNextElementSibling: SVGElement? {
        guard let p = node.parent, node.index + 1 < p.children.count else { return nil }
        return SVGElement(p.children[node.index + 1])
    }
    var cssIsRoot: Bool { node.parent == nil }
    var cssIsEmpty: Bool { node.children.isEmpty }
    var cssSiblingIndex: Int { node.index + 1 }
    var cssSiblingCount: Int { node.parent?.children.count ?? 1 }
}

final class SVGDocument {
    let root: SVGNode?
    let limits: SVGLimits
    private(set) var ids: [String: SVGNode] = [:]
    private(set) var nodeCount = 0
    /// Author sheets from <style> elements.
    private(set) var sheets: [CSSStylesheet] = []
    private var resolver: CSSStyleResolver? = nil
    /// Replaces the built-in style computation: (element, parent style) ->
    /// computed style. Called for every element drawn (and for gradient
    /// stops and clip paths).
    var styleProvider: ((SVGNode, CSSComputedStyle) -> CSSComputedStyle)? = nil
    /// Resolves an external reference ("sprite.svg" of "sprite.svg#icon")
    /// to its document, for `use`; nil = not available (yet).
    var externalDocument: ((String) -> SVGDocument?)? = nil
    /// Set by the XML path when the source was not well-formed.
    var wellFormed = true

    init(root: SVGNode?, limits: SVGLimits = SVGLimits()) {
        self.root = root
        self.limits = limits
        index()
    }

    private func index() {
        guard let r = root else { return }
        var stack: [SVGNode] = [r]
        var styleText: [String] = []
        while let n = stack.popLast() {
            nodeCount += 1
            if let id = n.attr("id"), !id.isEmpty, ids[id] == nil { ids[id] = n }
            if n.name == "style" && !n.text.isEmpty { styleText.append(n.text) }
            var i = n.children.count - 1
            while i >= 0 { stack.append(n.children[i]); i -= 1 }
        }
        // Document order (the stack walk visits it in order already).
        for s in styleText { sheets.append(cssParseStylesheet(s)) }
    }

    func element(id: String) -> SVGNode? { ids[id] }

    /// The computed style of `n` given its parent's.
    func style(_ n: SVGNode, parent: CSSComputedStyle) -> CSSComputedStyle {
        if let p = styleProvider { return p(n, parent) }
        if resolver == nil {
            let r = CSSStyleResolver(ctx: CSSContext(), noUserAgent: true)
            r.addStyleSheet(cssParseStylesheet(svgUserAgentSheet), origin: .userAgent)
            for s in sheets { r.addStyleSheet(s) }
            resolver = r
        }
        guard let r = resolver else { return parent }
        return r.computeStyle(SVGElement(n), parent: parent, hints: svgPresentationHints(n))
    }

    /// Parse a standalone SVG file. nil if there is no `svg` root element.
    static func parse(_ bytes: [UInt8], limits: SVGLimits = SVGLimits()) -> SVGDocument? {
        var xl = XMLLimits()
        xl.maxNodes = limits.maxNodes
        let x = xmlParse(bytes, limits: xl)
        guard let xr = x.root, xr.localName == "svg", xr.namespace == xmlNamespaceSVG || xr.namespace.isEmpty else { return nil }
        let root = svgConvert(xr)
        let d = SVGDocument(root: root, limits: limits)
        d.wellFormed = x.wellFormed
        return d
    }

    /// Intrinsic size from the root's width/height (absolute lengths only)
    /// and the viewBox's aspect ratio.
    func intrinsicSize(fontSize: Double = 16) -> (width: Double?, height: Double?, ratio: Double?) {
        guard let r = root else { return (nil, nil, nil) }
        func abs(_ a: String) -> Double? {
            guard let v = r.attr(a), let l = svgParseLength(v), l.unit != .percent else { return nil }
            let px = l.resolve(fontSize: fontSize, percentBase: 0)
            return px > 0 && px.isFinite ? min(px, 1e6) : nil
        }
        let w = abs("width"), h = abs("height")
        var ratio: Double? = nil
        if let vb = r.attr("viewBox").flatMap(svgParseViewBox) { ratio = vb.w / vb.h }
        else if let w = w, let h = h, h > 0 { ratio = w / h }
        return (w, h, ratio)
    }
}

/// XML subtree to SVG nodes: SVG (or unnamespaced) elements only; elements
/// in other namespaces (editor metadata, foreignObject content) are dropped
/// with their subtrees. Explicit stack, so depth is the XML parser's cap.
func svgConvert(_ x: XMLNode) -> SVGNode {
    func make(_ e: XMLNode) -> SVGNode {
        var attrs: [SVGAttribute] = []
        attrs.reserveCapacity(e.attributes.count)
        for a in e.attributes {
            if a.namespace.isEmpty { attrs.append(SVGAttribute(name: a.name, value: a.value)) }
            else if a.namespace == xmlNamespaceXLink { attrs.append(SVGAttribute(name: "xlink:" + a.localName, value: a.value)) }
            else if a.namespace == xmlNamespaceXML { attrs.append(SVGAttribute(name: "xml:" + a.localName, value: a.value)) }
        }
        let n = SVGNode(name: e.localName, attributes: attrs)
        if e.localName == "style" { n.text = e.textContent }
        return n
    }
    let root = make(x)
    var stack: [(XMLNode, SVGNode)] = [(x, root)]
    while let (xe, se) = stack.popLast() {
        if se.name == "style" || se.name == "foreignObject" { continue }
        for c in xe.children where c.kind == .element {
            if !(c.namespace == xmlNamespaceSVG || c.namespace.isEmpty) { continue }
            let sc = make(c)
            se.append(sc)
            stack.append((c, sc))
        }
    }
    return root
}

/// The SVG part of the user agent sheet (the rest of the HTML one doesn't
/// apply to a standalone file).
let svgUserAgentSheet = "svg:not(:root), symbol, image, marker, pattern, foreignObject { overflow: hidden }"

/// Presentation attributes (and their CSS property names).
let svgPresentationAttributes: Set<String> = [
    "fill", "fill-opacity", "fill-rule", "stroke", "stroke-width", "stroke-opacity", "stroke-linecap",
    "stroke-linejoin", "stroke-miterlimit", "stroke-dasharray", "stroke-dashoffset", "clip-rule",
    "stop-color", "stop-opacity", "clip-path", "opacity", "display", "visibility", "color", "font-size",
    "overflow",
]

/// The element's presentation attributes as hint declarations. Values that
/// could break out of a declaration (`;`, braces) are dropped.
func svgPresentationHints(_ n: SVGNode) -> [CSSDeclaration] {
    if let h = n.hintCache { return h }
    var css = ""
    for a in n.attributes where svgPresentationAttributes.contains(a.name) {
        var ok = a.value.utf8.count <= 4096
        for b in a.value.utf8 where b == 0x3b || b == 0x7b || b == 0x7d || b == 0x21 { ok = false; break }
        if !ok { continue }
        css += a.name + ":" + a.value + ";"
    }
    let h = css.isEmpty ? [] : cssParseInlineStyle(css)
    n.hintCache = h
    return h
}

/// Does the data look like an SVG file? (Optional BOM and whitespace, then
/// an XML declaration, comment or doctype, and `<svg` within the first 4 KB.)
func svgSniff(_ d: [UInt8]) -> Bool {
    var i = 0
    if d.count >= 3 && d[0] == 0xef && d[1] == 0xbb && d[2] == 0xbf { i = 3 }
    while i < d.count && (d[i] == 0x20 || d[i] == 0x09 || d[i] == 0x0a || d[i] == 0x0d) { i += 1 }
    guard i < d.count, d[i] == 0x3c else { return false }
    let end = min(d.count, i + 4096)
    var k = i
    while k + 4 <= end {
        if d[k] == 0x3c && d[k + 1] == 0x73 && d[k + 2] == 0x76 && d[k + 3] == 0x67 {
            let n = k + 4 < d.count ? d[k + 4] : 0x20
            if n == 0x20 || n == 0x3e || n == 0x09 || n == 0x0a || n == 0x0d || n == 0x2f { return true }
        }
        k += 1
    }
    return false
}
