// LayoutEngine: the API the browser (Phase 8H) drives.
//
//   let engine = LayoutEngine(document: doc, text: textEngine,
//                             viewportWidth: 800, viewportHeight: 600)
//   engine.resolveURL = { base.resolve($0) }      // for url() in <style>
//   for (i, src) in engine.styleSources.enumerated() where src.href != nil {
//       ... fetch, then engine.setStyleSheets(slot: i, [importedSheets..., sheet])
//   }
//   engine.imageSize = { url in store.size(url) }  // nil = unknown yet
//   engine.update()                                // restyle/relayout as needed
//   engine.paint(into: px, stride: s, width: w, height: h, scrollX: 0, scrollY: y,
//                images: { url in store.bitmap(url) })
//   engine.hitTest(x: px, y: py + scrollY)         // page coordinates
//
// Everything is incremental at the granularity the browser needs: style
// changes (a sheet arrives, viewport resize crossing media queries, :hover)
// rebuild the box tree; image sizes and viewport width changes relayout the
// existing tree; scrolling only repaints from the display list.

struct LayoutStyleSource {
    /// `<link rel=stylesheet href>` (as written; resolve against the base URL), or nil for `<style>`.
    var href: String?
    /// The `<style>` element's text.
    var text: String
    var media: String
    unowned(unsafe) var node: HTMLNode
}

struct LayoutHit {
    /// The deepest element under the point.
    var node: HTMLNode? = nil
    /// The nearest `<a href>` (or `<area href>`) ancestor and its href (as written).
    var link: HTMLNode? = nil
    var href: String? = nil
    /// A form control (input, select, textarea, button) under the point.
    var control: HTMLNode? = nil
    var cursor = "auto"
    /// The nearest `title` attribute.
    var title: String? = nil
    init() {}
}

/// A form control's geometry, for the browser to draw over and route input to.
struct LayoutControl {
    var node: HTMLNode
    var kind: LayoutReplacedKind
    /// Page coordinates.
    var borderBox: LayoutRect
    var contentBox: LayoutRect
    var fixed: Bool
    var visible: Bool
}

struct LayoutTimings {
    var styleMs = 0, layoutMs = 0, displayMs = 0
    init() {}
}

final class LayoutEngine {
    let document: HTMLNode
    let text: TextEngine
    let limits: LayoutLimits
    let state = LayoutStyleState()
    let ctx: LayoutContext
    private(set) var resolver: CSSStyleResolver
    private(set) var root: LayoutBox? = nil
    private(set) var styleSources: [LayoutStyleSource] = []
    var slots: [[CSSStylesheet]] = []
    private var extraSheets: [CSSStylesheet] = []
    private(set) var hasHoverRules = false
    var hoverCompoundList: [CSSCompound] = []
    var pendingHover: [HTMLNode] = []
    /// Hover changes handled without rebuilding the box tree (for tests and timing).
    private(set) var incrementalRestyles = 0
    var nodeBoxes: [ObjectIdentifier: LayoutBox] = [:]
    var controlBoxes: [LayoutBox] = []
    var imageURLs: [String] = []
    private(set) var display = LayoutDisplayList()
    private(set) var documentWidth = 0.0, documentHeight = 0.0
    /// The canvas background (root or body background, else white), 0x00RRGGBB.
    private(set) var canvasColor: UInt32 = 0xffffff
    var title = ""
    private(set) var hovered: HTMLNode? = nil
    var timings = LayoutTimings()
    var scaledCache: [String: ImageBitmap] = [:]
    var scaledBytes = 0
    /// Optional clock for timings (milliseconds); the library has none.
    var clock: (() -> Int)? = nil
    /// For url() in inline `<style>` sheets and style="" attributes.
    var resolveURL: ((String) -> String)? = nil { didSet { if !styleSources.isEmpty { reparseInline() } } }
    /// Intrinsic size of an image URL (as written in the document), nil if unknown.
    var imageSize: ((String) -> (Int, Int)?)? = nil { didSet { ctx.imageSize = imageSize; needsLayout = true } }
    /// Browser-side form state overrides (typed text, checked state).
    var controlValues: [ObjectIdentifier: String] = [:]
    var controlChecked: [ObjectIdentifier: Bool] = [:]
    private(set) var viewportWidth: Double
    private(set) var viewportHeight: Double
    var needsStyle = true
    var needsLayout = true

    // Incremental updates (see incremental.swift).
    var pendingAttr: [HTMLNode] = []
    var pendingChildren: [HTMLNode] = []
    var pendingText: [HTMLNode] = []
    var pendingAttrRebuild: [HTMLNode] = []
    /// Bumped when `styleSources` is rescanned after a DOM change (new or removed <style>/<link>).
    var styleSourcesVersion = 0
    var pendingRescan = false
    var inUpdate = false
    var restyleDecoChanged = false
    var hasSiblingRules = false
    var stats = LayoutUpdateStats()

    init(document: HTMLNode, text: TextEngine, viewportWidth: Int, viewportHeight: Int,
         limits: LayoutLimits = LayoutLimits(), resolveURL: ((String) -> String)? = nil) {
        self.document = document
        self.text = text
        self.limits = limits
        self.viewportWidth = Double(max(1, min(viewportWidth, 100_000)))
        self.viewportHeight = Double(max(1, min(viewportHeight, 100_000)))
        self.ctx = LayoutContext(text: text, limits: limits)
        var c = CSSContext()
        c.viewportWidth = self.viewportWidth
        c.viewportHeight = self.viewportHeight
        self.resolver = CSSStyleResolver(ctx: c)
        self.resolveURL = resolveURL
        scanDocument()
    }

    // MARK: Style sheets

    /// No doctype, or a legacy one: the HTML quirks-mode UA rules apply.
    private(set) var quirksMode = false

    func scanDocument() {
        quirksMode = true
        for c in document.children where c.kind == .doctype {
            quirksMode = htmlDoctypeQuirks(name: c.name, publicID: c.publicID, systemID: c.systemID, forceQuirks: false)
        }
        styleSources = []
        slots = []
        var t: String? = nil
        document.walk { n in
            guard n.kind == .element else { return true }
            if n.name == "title" && t == nil && n.namespace == .html { t = layoutCollapseSpaces(n.textContent) }
            if n.name == "style" && n.namespace == .html {
                styleSources.append(LayoutStyleSource(href: nil, text: n.textContent, media: n.attribute("media") ?? "", node: n))
            } else if n.name == "link", let rel = n.attribute("rel"), let href = n.attribute("href") {
                var isSheet = false, alternate = false
                htmlForEachToken(layoutLowerASCII(rel)) { w in
                    if w == "stylesheet" { isSheet = true }
                    if w == "alternate" { alternate = true }
                }
                if isSheet && !alternate {
                    styleSources.append(LayoutStyleSource(href: href, text: "", media: n.attribute("media") ?? "", node: n))
                }
            }
            return true
        }
        title = t ?? ""
        for s in styleSources {
            slots.append(s.href == nil ? [cssParseStylesheet(s.text, resolveURL: resolveURL)] : [])
        }
        rebuildResolver()
    }

    private func reparseInline() {
        for (i, s) in styleSources.enumerated() where s.href == nil {
            slots[i] = [cssParseStylesheet(s.text, resolveURL: resolveURL)]
        }
        rebuildResolver()
    }

    /// Supply the sheets for a `<link>` slot (its @imports first, then the sheet itself).
    func setStyleSheets(slot: Int, _ sheets: [CSSStylesheet]) {
        guard slot >= 0 && slot < slots.count else { return }
        slots[slot] = sheets
        rebuildResolver()
    }

    /// An extra author sheet after the document's (e.g. a user stylesheet).
    func addStyleSheet(_ sheet: CSSStylesheet) {
        extraSheets.append(sheet)
        rebuildResolver()
    }

    private func cssContext() -> CSSContext {
        var c = CSSContext()
        c.viewportWidth = viewportWidth
        c.viewportHeight = viewportHeight
        return c
    }

    func rebuildResolver() {
        let c = cssContext()
        let r = CSSStyleResolver(ctx: c)
        if quirksMode { r.addStyleSheet(layoutQuirksSheet, origin: .userAgent) }
        for (i, s) in styleSources.enumerated() {
            if !s.media.isEmpty && !cssParseMediaQueryList(s.media).matches(c) { continue }
            for sh in slots[i] { r.addStyleSheet(sh) }
        }
        for sh in extraSheets { r.addStyleSheet(sh) }
        resolver = r
        hasHoverRules = LayoutEngine.scanHover(r)
        hoverCompoundList = LayoutEngine.hoverCompounds(r)
        hasSiblingRules = LayoutEngine.scanSiblingCombinators(r)
        needsStyle = true
    }

    private static func scanHover(_ r: CSSStyleResolver) -> Bool {
        func compoundHas(_ c: CSSCompound, _ depth: Int) -> Bool {
            if c.pseudos.contains(.hover) { return true }
            if depth > 4 { return false }
            for s in c.negations { for k in s.compounds where compoundHas(k, depth + 1) { return true } }
            for l in c.anyOf { for s in l { for k in s.compounds where compoundHas(k, depth + 1) { return true } } }
            return false
        }
        for e in r.ruleSet.entries {
            for c in e.selector.compounds where compoundHas(c, 0) { return true }
        }
        return false
    }

    // MARK: Inputs

    func setViewport(width: Int, height: Int) {
        let w = Double(max(1, min(width, 100_000))), h = Double(max(1, min(height, 100_000)))
        if w == viewportWidth && h == viewportHeight { return }
        viewportWidth = w; viewportHeight = h
        // Media queries and vw/vh units: restyle.
        resolver.setContext(cssContext())
        rebuildResolverMediaOnly()
        needsStyle = true
    }

    private func rebuildResolverMediaOnly() {
        // <link media> / <style media> are evaluated when the resolver is built.
        var anyMedia = false
        for s in styleSources where !s.media.isEmpty { anyMedia = true }
        if anyMedia { rebuildResolver() }
    }

    /// The element under the pointer (nil when it leaves). Returns true if
    /// the page must be repainted (a :hover rule may apply).
    @discardableResult
    func setHover(_ node: HTMLNode?) -> Bool {
        if node === hovered { return false }
        let oldNode = hovered
        let old = state.hovered
        hovered = node
        var set: Set<ObjectIdentifier> = []
        var p = node
        var k = 0
        while let n = p, k < 4096 { if n.kind == .element { set.insert(ObjectIdentifier(n)) }; p = n.parent; k += 1 }
        state.hovered = set
        if !hasHoverRules || needsStyle { return hasHoverRules }
        let affected = hoverAffected(old, set, oldNode, node)
        if affected.isEmpty { return false }
        pendingHover.append(contentsOf: affected)
        return true
    }

    /// Image sizes changed (call after new images report their size).
    func imagesChanged() { needsLayout = true }

    /// Restyle the whole document on the next update (e.g. after a DOM change).
    func invalidateStyle() { needsStyle = true }

    // MARK: Pipeline

    private func now() -> Int { clock?() ?? 0 }

    /// Restyle and relayout as needed. Cheap when nothing changed.
    func update() {
        inUpdate = true
        defer { inUpdate = false }
        if hasPendingDOMChanges { processDOMChanges() }
        if !needsStyle && !pendingHover.isEmpty && root != nil {
            let t0 = now()
            let roots = pendingHover
            pendingHover = []
            if restyleInPlace(roots) {
                incrementalRestyles += 1
                if !needsLayout, let r = root { computeAbsolute(r); buildDisplay() }
                timings.styleMs = now() - t0
            } else {
                needsStyle = true
            }
        }
        pendingHover = []
        if needsStyle {
            let t0 = now()
            stats.fullRebuilds += 1
            let b = LayoutBuilder(resolver: resolver, state: state, limits: limits)
            root?.items = nil
            root = b.build(document)
            nodeBoxes = b.nodeBoxes
            controlBoxes = b.controls
            imageURLs = b.imageURLs
            needsStyle = false
            needsLayout = true
            timings.styleMs = now() - t0
        }
        if needsLayout {
            let t0 = now()
            relayout()
            let t1 = now()
            timings.layoutMs = t1 - t0
            buildDisplay()
            timings.displayMs = now() - t1
            needsLayout = false
        }
    }

    private func relayout() {
        ctx.gen += 1
        ctx.steps = 0
        ctx.viewportW = viewportWidth
        ctx.viewportH = viewportHeight
        ctx.imageSize = imageSize
        guard let r = root else { documentWidth = viewportWidth; documentHeight = viewportHeight; canvasColor = 0xffffff; return }
        ctx.assignContainingBlocks(r)
        let floats = LayoutFloats(cap: limits.maxFloatsPerContext)
        ctx.layoutBlock(r, cbW: viewportWidth, cbH: viewportHeight, floats: floats, cbOX: 0, oy: 0)
        r.x = r.margin.l
        r.y = r.margin.t
        let icb = LayoutRect(x: 0, y: 0, w: viewportWidth, h: viewportHeight)
        for a in ctx.initialAbs { ctx.layoutAbsolute(a, icb) }
        for f in ctx.fixedBoxes { ctx.layoutAbsolute(f, icb) }
        computeAbsolute(r)
    }

    // MARK: Absolute positions

    private func relOffset(_ b: LayoutBox, _ cc: LayoutBox?) -> (Double, Double) {
        guard b.style.position == .relative, b.kind != .text else { return (0, 0) }
        let cw = cc.map { $0.w - $0.border.horizontal - $0.padding.horizontal } ?? viewportWidth
        let chh: Double? = cc.map { $0.h - $0.border.vertical - $0.padding.vertical }
        var dx = 0.0, dy = 0.0
        if let l = b.style.left.resolve(cw) { dx = l } else if let r = b.style.right.resolve(cw) { dx = -r }
        if let t = b.style.top.resolve(chh ?? 0), !(b.style.top.hasPercent && chh == nil) { dy = t }
        else if let bo = b.style.bottom.resolve(chh ?? 0) { dy = -bo }
        return (layoutSan(dx), layoutSan(dy))
    }

    func computeAbsolute(_ root: LayoutBox) {
        var maxX = viewportWidth, maxY = 0.0
        var stack: [LayoutBox] = [root]
        let inf = LayoutRect.infinite
        root.clip = inf
        root.opacityAcc = max(0, min(1, root.style.opacity))
        root.inFixed = false
        root.extentClipped = false
        while let b = stack.popLast() {
            let cc = ctx.coordContainer(b)
            var bx = 0.0, by = 0.0
            if let c = cc { bx = c.ax; by = c.ay + (b.isAbs ? 0 : c.childOffsetY) }
            var sx = 0.0, sy = 0.0
            if let p = b.parent, p.kind == .inline { sx = p.shiftX; sy = p.shiftY }
            let (rx, ry) = relOffset(b, cc)
            b.relX = rx; b.relY = ry
            if b.kind == .inline || b.kind == .text {
                b.shiftX = sx + rx; b.shiftY = sy + ry
                b.ax = bx + b.shiftX; b.ay = by + b.shiftY
            } else {
                b.ax = bx + b.x + rx + sx
                b.ay = by + b.y + ry + sy
                b.shiftX = 0; b.shiftY = 0
            }
            if let p = b.parent {
                b.inFixed = p.inFixed || b.style.position == .fixed
                var c = p.clip
                if p.kind != .inline && p.kind != .text && (p.style.overflowX != .visible || p.style.overflowY != .visible) {
                    let pb = p.paddingBox
                    c = c.intersection(pb)
                }
                if b.style.position == .fixed { c = inf }
                b.clip = c
                b.opacityAcc = p.opacityAcc * max(0, min(1, b.style.opacity))
                b.extentClipped = p.extentClipped || (p.kind != .inline && p.style.overflowX != .visible && p.style.overflowY != .visible)
            }
            if !b.inFixed && !b.extentClipped {
                if b.kind == .text || b.kind == .inline {
                    for f in b.frags { maxX = max(maxX, b.ax + f.x + f.w); maxY = max(maxY, b.ay + f.y + f.h) }
                } else {
                    maxX = max(maxX, b.ax + b.w); maxY = max(maxY, b.ay + b.h + (b.parent == nil ? b.margin.b : 0))
                }
            }
            if let m = b.marker {
                m.ax = b.ax + m.x; m.ay = b.ay + m.y
                m.clip = b.clip; m.opacityAcc = b.opacityAcc; m.inFixed = b.inFixed
            }
            var i = b.children.count - 1
            while i >= 0 { stack.append(b.children[i]); i -= 1 }
        }
        documentWidth = layoutSan(maxX)
        documentHeight = layoutSan(max(maxY, viewportHeight))
        // Canvas background: the root's, else the body's.
        canvasColor = 0xffffff
        root.paintsBackground = true
        let rb = root.style.backgroundColor
        if rb.a > 0 {
            canvasColor = layoutOpaque(rb)
            root.paintsBackground = false
        } else if let body = root.children.first(where: { $0.node?.name == "body" }) {
            body.paintsBackground = true
            let bb = body.style.backgroundColor
            if bb.a > 0 { canvasColor = layoutOpaque(bb); body.paintsBackground = false }
        }
    }

    // MARK: Queries

    /// The element under a point in page coordinates (viewport + scroll).
    func hitTest(x: Double, y: Double, scrollX: Double = 0, scrollY: Double = 0) -> LayoutHit {
        var hit = LayoutHit()
        guard let b = display.hit(x: x, y: y, scrollX: scrollX, scrollY: scrollY) else { return hit }
        hit.node = b.element
        hit.cursor = b.style.cursor
        var p = hit.node
        var k = 0
        while let n = p, k < 4096 {
            if n.kind == .element {
                if hit.link == nil && (n.name == "a" || n.name == "area"), let h = n.attribute("href") { hit.link = n; hit.href = h }
                if hit.control == nil && (n.name == "input" || n.name == "select" || n.name == "textarea" || n.name == "button") { hit.control = n }
                if hit.title == nil, let t = n.attribute("title") { hit.title = t }
            }
            p = n.parent
            k += 1
        }
        if hit.link != nil && hit.cursor == "auto" { hit.cursor = "pointer" }
        if hit.cursor == "auto", b.kind == .text { hit.cursor = "text" }
        return hit
    }

    /// The href under a point (page coordinates), as written.
    func linkAt(x: Double, y: Double, scrollX: Double = 0, scrollY: Double = 0) -> String? {
        hitTest(x: x, y: y, scrollX: scrollX, scrollY: scrollY).href
    }

    /// Border-box rectangle of an element in page coordinates (union of its fragments for inline boxes).
    func rect(of node: HTMLNode) -> LayoutRect? {
        flushForQuery()
        guard let b = nodeBoxes[ObjectIdentifier(node)] else { return nil }
        return layoutBoxRect(b)
    }

    /// The box generated for an element, if any.
    func box(for node: HTMLNode) -> LayoutBox? { nodeBoxes[ObjectIdentifier(node)] }

    /// Page y to scroll to for a `#fragment` (an id, or an `<a name>`).
    func fragmentY(_ name: String) -> Double? {
        if name.isEmpty || name == "top" { return 0 }
        var target = document.getElementById(name)
        if target == nil { target = document.firstElement { $0.name == "a" && $0.attribute("name") == name } }
        guard let t = target else { return nil }
        var p: HTMLNode? = t
        var k = 0
        while let n = p, k < 4096 {
            if let r = rect(of: n) { return r.y }
            p = n.parent
            k += 1
        }
        return nil
    }

    /// Form controls with their rectangles (page coordinates), in document order.
    var formControls: [LayoutControl] {
        var out: [LayoutControl] = []
        for b in controlBoxes {
            guard let n = b.node else { continue }
            let kind: LayoutReplacedKind = b.kind == .replaced ? b.replaced : .button
            out.append(LayoutControl(node: n, kind: kind, borderBox: b.borderBox, contentBox: b.contentBox,
                                     fixed: b.inFixed, visible: b.style.visibility == .visible))
        }
        return out
    }

    func setDisplay(_ d: LayoutDisplayList) { display = d }

    /// Text dump of the box tree (see layoutDump).
    func dump() -> String {
        guard let r = root else { return "" }
        return layoutDump(r)
    }
}

/// The HTML Standard's quirks-mode additions to the user agent sheet.
let layoutQuirksSheet = cssParseStylesheet("""
table { font-weight: initial; font-style: initial; font-size: initial; line-height: initial;
        white-space: initial; text-align: initial }
""")

func layoutOpaque(_ c: CSSColor) -> UInt32 { UInt32(c.r) << 16 | UInt32(c.g) << 8 | UInt32(c.b) }

/// Page rectangle of a box (inline boxes: union of fragments).
func layoutBoxRect(_ b: LayoutBox) -> LayoutRect {
    if b.kind == .inline || b.kind == .text {
        var r = LayoutRect()
        var first = true
        for f in b.frags {
            let fr = LayoutRect(x: b.ax + f.x, y: b.ay + f.y, w: f.w, h: f.h)
            if first { r = fr; first = false } else { r = r.union(fr) }
        }
        if first {
            // An empty inline: find a descendant with geometry.
            var stack: [LayoutBox] = b.children
            var k = 0
            while let c = stack.popLast(), k < 100_000 {
                k += 1
                let cr = layoutBoxRect(c)
                if cr.w > 0 || cr.h > 0 { if first { r = cr; first = false } else { r = r.union(cr) } }
            }
        }
        return r
    }
    if b.kind == .table, let d = b.table {
        return LayoutRect(x: b.ax, y: b.ay + d.gridTop, w: b.w, h: max(0, b.h - d.gridTop))
    }
    return b.borderBox
}

// MARK: - Dump

private func layoutDescribe(_ n: HTMLNode?) -> String {
    guard let n = n, n.kind == .element else { return "" }
    var s = "<" + n.name
    if let id = n.attribute("id"), !id.isEmpty { s += "#" + id }
    for c in n.classNames.prefix(3) { s += "." + c }
    return s + ">"
}

private func layoutKindName(_ b: LayoutBox) -> String {
    var k: String
    switch b.kind {
    case .block: k = b.inlineLevel ? "inline-block" : (b.style.display == .listItem ? "list-item" : "block")
    case .inline: k = "inline"
    case .text: k = "text"
    case .replaced: k = "replaced"
    case .lineBreak: k = "br"
    case .marker: k = "marker"
    case .table: k = b.inlineLevel ? "inline-table" : "table"
    case .rowGroup: k = "row-group"
    case .row: k = "row"
    case .cell: k = "cell"
    case .caption: k = "caption"
    case .flex: k = b.inlineLevel ? "inline-flex" : "flex"
    }
    if b.anonymous { k = "anon-" + k }
    return k
}

private func layoutRectString(_ r: LayoutRect) -> String {
    "\(layoutInt(r.x)),\(layoutInt(r.y)) \(layoutInt(r.w))x\(layoutInt(r.h))"
}

private func layoutTextSnippet(_ s: [UInt32], _ a: Int, _ b: Int) -> String {
    var out = ""
    var i = max(0, a)
    let e = min(b, s.count)
    var n = 0
    while i < e {
        let c = s[i]
        if c == 0x0a { out += "\\n" }
        else if c == 0x22 { out += "\\\"" }
        else if let u = Unicode.Scalar(c) { out.unicodeScalars.append(u) }
        i += 1
        n += 1
        if n >= 40 && i < e { out += "..."; break }
    }
    return out
}

/// One line per box: kind, element, page rectangle as integers; text boxes
/// list each fragment (line piece) with its text.
func layoutDump(_ root: LayoutBox) -> String {
    var out = ""
    var stack: [(LayoutBox, Int)] = [(root, 0)]
    while let (b, d) = stack.popLast() {
        var line = ""
        for _ in 0..<d { line += "  " }
        if b.kind == .text {
            guard let run = b.run else { continue }
            for f in b.frags {
                out += line + "text \"" + layoutTextSnippet(run.scalars, Int(f.start), Int(f.end)) + "\" "
                    + layoutRectString(LayoutRect(x: b.ax + f.x, y: b.ay + f.y, w: f.w, h: f.h)) + "\n"
            }
            continue
        }
        if b.kind == .lineBreak { continue }
        line += layoutKindName(b)
        let desc = layoutDescribe(b.node)
        if !desc.isEmpty { line += " " + desc }
        switch b.pseudo {
        case .before: line += "::before"
        case .after: line += "::after"
        default: break
        }
        line += " " + layoutRectString(layoutBoxRect(b))
        if b.isFloat { line += " float-" + (b.style.float == .left ? "left" : "right") }
        switch b.style.position {
        case .relative: line += " relative"
        case .absolute: line += " absolute"
        case .fixed: line += " fixed"
        case .sticky: line += " sticky"
        default: break
        }
        if b.kind == .cell { line += " [r\(b.rowIndex) c\(b.col)" + (b.colspan > 1 ? " cs\(b.colspan)" : "") + (b.rowspan > 1 ? " rs\(b.rowspan)" : "") + "]" }
        out += line + "\n"
        if let m = b.marker, let r = m.run {
            var ml = ""
            for _ in 0...d { ml += "  " }
            out += ml + "marker \"" + layoutTextSnippet(r.scalars, 0, r.count) + "\" "
                + layoutRectString(LayoutRect(x: m.ax, y: m.ay, w: m.w, h: m.h)) + "\n"
        }
        var i = b.children.count - 1
        while i >= 0 { stack.append((b.children[i], d + 1)); i -= 1 }
    }
    return out
}
