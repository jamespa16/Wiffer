// Inline <svg> (ROADMAP Phase 8J): the element's subtree becomes an
// SVGDocument (lib/svg) when the box is built. Styles come from the page's
// cascade, so page CSS (`.icon { fill: currentColor }`, hover colors)
// reaches the icon: the document's style provider computes each SVG element
// through the page's resolver, with SVG presentation attributes as hints.
// External `use href="sprite.svg#id"` files are fetched like images (the
// URL without its fragment goes into imageURLs) and resolved at paint time.

/// Elements converted per inline <svg>.
let layoutSVGMaxNodes = 20_000

extension LayoutBuilder {
    func setUpSVG(_ box: LayoutBox, _ node: HTMLNode) {
        var nodes: [HTMLNode] = []
        var externals: [String] = []
        func make(_ h: HTMLNode) -> SVGNode {
            var attrs: [SVGAttribute] = []
            attrs.reserveCapacity(h.attributes.count)
            for a in h.attributes { attrs.append(SVGAttribute(name: a.name, value: a.value)) }
            let n = SVGNode(name: h.name, attributes: attrs)
            n.userIndex = nodes.count
            nodes.append(h)
            if h.name == "style" { n.text = h.textContent }
            if h.name == "use", let href = n.href, let u = layoutSVGExternalURL(href), !externals.contains(u), externals.count < 16 {
                externals.append(u)
            }
            return n
        }
        let root = make(node)
        var stack: [(HTMLNode, SVGNode)] = [(node, root)]
        while let (h, s) = stack.popLast() {
            if s.name == "style" || s.name == "foreignObject" { continue }
            for c in h.children where c.kind == .element && c.namespace == .svg {
                if nodes.count >= layoutSVGMaxNodes { break }
                let sc = make(c)
                s.append(sc)
                stack.append((c, sc))
            }
        }
        let doc = SVGDocument(root: root)
        let resolver = self.resolver
        let state = self.state
        doc.styleProvider = { n, parent in
            guard n.userIndex >= 0 && n.userIndex < nodes.count else { return parent }
            return resolver.computeStyle(LayoutElement(nodes[n.userIndex], state), parent: parent, hints: svgPresentationHints(n))
        }
        box.svgDoc = doc
        box.svgExternals = externals
        for u in externals { noteImage(u) }
    }
}

/// The file part of an external `use` reference ("icons.svg#x" ->
/// "icons.svg"); nil for a same-document "#x".
func layoutSVGExternalURL(_ href: String) -> String? {
    if href.utf8.first == 0x23 || href.isEmpty { return nil }
    if let h = href.utf8.firstIndex(of: 0x23) {
        let s = String(decoding: href.utf8[..<h], as: UTF8.self)
        return s.isEmpty ? nil : s
    }
    return href
}

extension LayoutEngine {
    /// The inline svg's render at w x h, cached on the box (re-rendered when
    /// the size, the inherited color or the set of loaded sprites changes).
    func svgRender(_ b: LayoutBox, _ w: Int, _ h: Int, images: ((String) -> ImageBitmap?)?) -> ImageBitmap? {
        guard let doc = b.svgDoc, w > 0, h > 0, w <= 8192, h <= 8192, w * h <= 16 << 20 else { return nil }
        var ready = 0
        for u in b.svgExternals where images?(u)?.svg != nil { ready += 1 }
        let parent = b.parent?.style ?? CSSComputedStyle()
        let key = "\(w)x\(h) \(ready) \(b.style.color.argb) \(parent.color.argb)"
        if key == b.svgKey, let r = b.svgRaster { return r }
        if let get = images {
            doc.externalDocument = { href in
                guard let u = layoutSVGExternalURL(href) else { return nil }
                return get(u)?.svg
            }
        } else { doc.externalDocument = nil }
        guard let r = lib_svgRender(doc, w, h, parent) else { return nil }
        let bm = ImageBitmap(width: w, height: h, pixels: r.pixels, opaque: false)
        b.svgRaster = bm
        b.svgKey = key
        doc.externalDocument = nil
        return bm
    }
}

/// lib/svg's svgRender, under a name the LayoutEngine method doesn't shadow.
func lib_svgRender(_ doc: SVGDocument, _ w: Int, _ h: Int, _ parent: CSSComputedStyle) -> SVGRaster? {
    svgRender(doc, width: w, height: h, rootParentStyle: parent)
}

/// Intrinsic size of an inline svg: width/height attributes (absolute
/// lengths) and the viewBox ratio.
func layoutSVGIntrinsic(_ b: LayoutBox) -> (Double?, Double?, Double?) {
    guard let d = b.svgDoc else { return (nil, nil, nil) }
    return d.intrinsicSize(fontSize: b.style.fontSize)
}
