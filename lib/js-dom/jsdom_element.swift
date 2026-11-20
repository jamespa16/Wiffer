// Element and HTMLElement: attributes, selectors (lib/css's parser and
// matcher through the CSSElement conformance below; no selector engine of
// our own), markup (innerHTML & co., lib/html), CSSOM View metrics (forced
// layout through JSDOMHost.layout), shadow roots, focus, click().

/// An element as lib/css's selector matcher sees it from the DOM APIs
/// (querySelector, matches, closest): `:scope` is the context element and
/// `:focus` the focused element.
struct JSDOMSelElement: CSSElement {
    let node: HTMLNode
    unowned(unsafe) let b: JSDOMBindings
    let scope: HTMLNode?

    var cssTagName: String { node.name }
    var cssID: String { node.attribute("id") ?? "" }
    var cssClasses: [String] { node.classNames }
    func cssAttribute(_ name: String) -> String? {
        node.namespace == .html ? node.attribute(name) : (node.attribute(name) ?? attributeCaseFold(name))
    }
    func attributeCaseFold(_ name: String) -> String? {
        for a in node.attributes where htmlLowerASCII(a.name) == name { return a.value }
        return nil
    }
    var cssParent: JSDOMSelElement? {
        guard let p = node.parent, p.kind == .element else { return nil }
        return JSDOMSelElement(node: p, b: b, scope: scope)
    }
    var cssPreviousElementSibling: JSDOMSelElement? {
        guard let p = node.parent else { return nil }
        var i = min(node.index, p.children.count) - 1
        while i >= 0 {
            if p.children[i].kind == .element { return JSDOMSelElement(node: p.children[i], b: b, scope: scope) }
            i -= 1
        }
        return nil
    }
    var cssNextElementSibling: JSDOMSelElement? {
        guard let p = node.parent else { return nil }
        var i = node.index + 1
        while i < p.children.count {
            if p.children[i].kind == .element { return JSDOMSelElement(node: p.children[i], b: b, scope: scope) }
            i += 1
        }
        return nil
    }
    var cssIsRoot: Bool { node.parent?.kind == .document }
    var cssIsScope: Bool { scope == nil ? cssIsRoot : node === scope }
    var cssIsFocused: Bool { b.focused === node }
    var cssIsLink: Bool { (node.name == "a" || node.name == "area") && node.namespace == .html && node.attribute("href") != nil }
    var cssIsChecked: Bool {
        if node.isHTML("input") { return b.inputChecked(node) }
        if node.isHTML("option") { return b.optionSelected(node) }
        return false
    }
    var cssIsDisabled: Bool { b.isDisabled(node) }
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
    var cssIsDefined: Bool { node.isDefined }
}

extension JSDOMBindings {
    // MARK: Selectors

    func parseSelector(_ s: String) throws(JSThrow) -> [CSSComplexSelector] {
        guard let l = cssParseSelectorListStrict(s) else {
            throw throwDOM("SyntaxError", "'" + s + "' is not a valid selector.")
        }
        for c in l where c.pseudoElement != .none {
            _ = c
        }
        return l
    }

    func selMatches(_ list: [CSSComplexSelector], _ n: HTMLNode, scope: HTMLNode?) -> Bool {
        let el = JSDOMSelElement(node: n, b: self, scope: scope)
        for s in list where s.pseudoElement == .none && s.slotted == nil && s.parts == nil {
            if cssMatches(s, el) { return true }
        }
        return false
    }

    /// Descendant elements of `root` matching, in tree order (not crossing
    /// shadow or template boundaries).
    func querySelect(_ root: HTMLNode, _ list: [CSSComplexSelector], first: Bool) -> [HTMLNode] {
        var out: [HTMLNode] = []
        let scope: HTMLNode? = root.kind == .element ? root : nil
        var stack: [HTMLNode] = []
        var i = root.children.count - 1
        while i >= 0 { stack.append(root.children[i]); i -= 1 }
        while let n = stack.popLast() {
            if n.kind == .element && selMatches(list, n, scope: scope) {
                out.append(n)
                if first { return out }
            }
            var j = n.children.count - 1
            while j >= 0 { stack.append(n.children[j]); j -= 1 }
        }
        return out
    }

    func Element_matches(_ n: HTMLNode, _ s: String) throws(JSThrow) -> Bool {
        selMatches(try parseSelector(s), n, scope: n)
    }

    func Element_closest(_ n: HTMLNode, _ s: String) throws(JSThrow) -> HTMLNode? {
        let l = try parseSelector(s)
        var x: HTMLNode? = n
        while let e = x, e.kind == .element {
            if selMatches(l, e, scope: n) { return e }
            x = e.parent
        }
        return nil
    }

    // MARK: Names

    func Element_namespaceURI(_ n: HTMLNode) -> String? { elementNamespace(n) }
    func Element_prefix(_ n: HTMLNode) -> String? { elementPrefix(n) }
    func Element_localName(_ n: HTMLNode) -> String { elementLocalName(n) }
    func Element_tagName(_ n: HTMLNode) -> String {
        if n.namespace == .html && isHTMLDocument(n.nodeDocument ?? n) { return jsdomUpperASCII(n.name) }
        return n.name
    }

    // MARK: Attributes

    func Element_classList(_ n: HTMLNode) -> JSValue { tokenList(n, "class") }
    func Element_hasAttributes(_ n: HTMLNode) -> Bool { !n.attributes.isEmpty }
    func Element_attributes(_ n: HTMLNode) -> JSValue { classes.NamedNodeMap.wrap(JSDOMNamedNodeMap(n)) }
    func Element_getAttributeNames(_ n: HTMLNode) -> JSValue {
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        var vals: [JSValue] = []
        for a in n.attributes { let s = str(a.name); _ = heap.root(s); vals.append(s) }
        return array(vals)
    }
    func Element_getAttribute(_ n: HTMLNode, _ q: String) -> String? { n.getAttribute(q) }
    func Element_getAttributeNS(_ n: HTMLNode, _ ns: String?, _ local: String) -> String? {
        guard let i = findAttributeNS(n, ns, local) else { return nil }
        return n.attributes[i].value
    }
    func Element_setAttribute(_ n: HTMLNode, _ q: String, _ v: String) throws(JSThrow) {
        do throws(HTMLDOMError) { try n.setAttribute(q, v) } catch { throw throwDOM(error) }
    }
    func Element_setAttributeNS(_ n: HTMLNode, _ ns: String?, _ q: String, _ v: String) throws(JSThrow) {
        try setAttributeNS(n, ns, q, v)
    }
    func Element_removeAttribute(_ n: HTMLNode, _ q: String) {
        let name = qualifiedAttrName(n, q)
        detachAttr(n, name)
        n.removeAttribute(name)
    }
    func Element_removeAttributeNS(_ n: HTMLNode, _ ns: String?, _ local: String) { removeAttributeNS(n, ns, local) }
    func Element_toggleAttribute(_ n: HTMLNode, _ q: String, _ force: Bool?) throws(JSThrow) -> Bool {
        if !htmlIsValidAttributeName(q) { throw throwDOM(.invalidCharacter) }
        let name = qualifiedAttrName(n, q)
        if n.hasAttribute(name) && force != true { detachAttr(n, name) }
        do throws(HTMLDOMError) { return try n.toggleAttribute(q, force: force) } catch { throw throwDOM(error) }
    }
    func Element_hasAttribute(_ n: HTMLNode, _ q: String) -> Bool { n.hasAttribute(qualifiedAttrName(n, q)) }
    func Element_hasAttributeNS(_ n: HTMLNode, _ ns: String?, _ local: String) -> Bool { findAttributeNS(n, ns, local) != nil }
    func Element_getAttributeNode(_ n: HTMLNode, _ q: String) -> JSValue {
        let name = qualifiedAttrName(n, q)
        return n.hasAttribute(name) ? attrObject(n, name) : .null
    }
    func Element_getAttributeNodeNS(_ n: HTMLNode, _ ns: String?, _ local: String) -> JSValue {
        guard let i = findAttributeNS(n, ns, local) else { return .null }
        return attrObject(n, n.attributes[i].name)
    }
    func Element_setAttributeNode(_ n: HTMLNode, _ a: JSDOMAttr) throws(JSThrow) -> JSValue { try setAttrNode(n, a) }
    func Element_setAttributeNodeNS(_ n: HTMLNode, _ a: JSDOMAttr) throws(JSThrow) -> JSValue { try setAttrNode(n, a) }
    func Element_removeAttributeNode(_ n: HTMLNode, _ a: JSDOMAttr) throws(JSThrow) -> JSValue {
        guard a.owner === n else { throw throwDOM("NotFoundError", "The attribute is not owned by this element.") }
        let w = classes.Attr.wrap(a)
        detachAttr(n, a.name)
        n.removeAttribute(a.name)
        return w
    }

    // MARK: Shadow DOM

    func Element_attachShadow(_ n: HTMLNode, _ d: JSDOM_ShadowRootInit) throws(JSThrow) -> HTMLNode? {
        let mode: HTMLShadowRootMode = d.mode == "closed" ? .closed : .open
        do throws(HTMLDOMError) {
            return try n.attachShadow(mode: mode, delegatesFocus: d.delegatesFocus,
                                      slotAssignment: d.slotAssignment == "manual" ? .manual : .named,
                                      clonable: d.clonable, serializable: d.serializable)
        } catch {
            throw throwDOM(error)
        }
    }
    func Element_shadowRoot(_ n: HTMLNode) -> HTMLNode? { n.shadowRoot }

    // MARK: Collections

    func Element_getElementsByTagName(_ n: HTMLNode, _ q: String) -> JSValue { makeCollection(n, .tagName(q)) }
    func Element_getElementsByTagNameNS(_ n: HTMLNode, _ ns: String?, _ local: String) -> JSValue {
        makeCollection(n, .tagNameNS((ns?.isEmpty ?? true) ? nil : ns, local))
    }
    func Element_getElementsByClassName(_ n: HTMLNode, _ c: String) -> JSValue {
        makeCollection(n, .className(htmlSplitWhitespace(c)))
    }

    // MARK: Insertion

    func Element_insertAdjacentElement(_ n: HTMLNode, _ w: String, _ el: HTMLNode) throws(JSThrow) -> HTMLNode? {
        try insertAdjacent(n, w, el)
    }

    func Element_insertAdjacentText(_ n: HTMLNode, _ w: String, _ data: String) throws(JSThrow) {
        _ = try insertAdjacent(n, w, (n.nodeDocument ?? document).createTextNode(data))
    }

    func insertAdjacent(_ n: HTMLNode, _ w: String, _ node: HTMLNode) throws(JSThrow) -> HTMLNode? {
        switch htmlLowerASCII(w) {
        case "beforebegin":
            guard let p = n.parent else { return nil }
            return try Node_insertBefore(p, node, n)
        case "afterbegin": return try Node_insertBefore(n, node, n.firstChild)
        case "beforeend": return try Node_insertBefore(n, node, nil)
        case "afterend":
            guard let p = n.parent else { return nil }
            return try Node_insertBefore(p, node, n.nextSibling)
        default:
            throw throwDOM("SyntaxError", "'" + w + "' is not a valid position.")
        }
    }

    // MARK: Markup

    func Element_innerHTML(_ n: HTMLNode) -> String { n.innerHTML }
    func Element_set_innerHTML(_ n: HTMLNode, _ v: String) { n.setInnerHTML(v) }
    func Element_outerHTML(_ n: HTMLNode) throws(JSThrow) -> String { n.outerHTML }
    func Element_set_outerHTML(_ n: HTMLNode, _ v: String) throws(JSThrow) {
        do throws(HTMLDOMError) { try n.setOuterHTML(v) } catch { throw throwDOM(error) }
    }
    func Element_insertAdjacentHTML(_ n: HTMLNode, _ pos: String, _ v: String) throws(JSThrow) {
        do throws(HTMLDOMError) { try n.insertAdjacentHTML(pos, v) } catch { throw throwDOM(error) }
    }
    func Element_setHTMLUnsafe(_ n: HTMLNode, _ v: String) { n.setHTMLUnsafe(v) }
    func Element_getHTML(_ n: HTMLNode, _ options: JSValue) -> String { getHTML(n, options) }

    // MARK: CSSOM View

    /// The border box in page coordinates (forced layout), nil without a box.
    func layoutRect(_ n: HTMLNode) -> LayoutRect? {
        guard n.isConnected, let e = host.layout() else { return nil }
        return e.rect(of: n)
    }

    func Element_getBoundingClientRect(_ n: HTMLNode) -> JSValue {
        guard let r = layoutRect(n) else { return rectValue(0, 0, 0, 0) }
        let (sx, sy) = host.scrollPosition()
        return rectValue(r.x - sx, r.y - sy, r.w, r.h)
    }

    func Element_getClientRects(_ n: HTMLNode) -> JSValue {
        guard let r = layoutRect(n) else { return classes.DOMRectList.wrap(JSDOMRectList([])) }
        let (sx, sy) = host.scrollPosition()
        return classes.DOMRectList.wrap(JSDOMRectList([JSDOMRect(r.x - sx, r.y - sy, r.w, r.h)]))
    }

    func Element_checkVisibility(_ n: HTMLNode, _ options: JSValue) -> Bool { layoutRect(n) != nil }

    func Element_scrollIntoView(_ n: HTMLNode, _ arg: JSValue) {
        if let r = layoutRect(n) { host.scrollTo(host.scrollPosition().0, max(0, r.y)) }
    }

    func scrollArgs(_ a: JSValue, _ b: JSValue) -> (Double?, Double?) {
        if a.isObject {
            var x: Double? = nil, y: Double? = nil
            if case .value(let l) = heap.getProperty(a, heap.key("left")), l.isNumber { x = l.numberValue }
            if case .value(let t) = heap.getProperty(a, heap.key("top")), t.isNumber { y = t.numberValue }
            return (x, y)
        }
        let x = a.isNumber ? a.numberValue : (a.isUndefined ? nil : 0)
        let y = b.isNumber ? b.numberValue : (b.isUndefined ? nil : 0)
        return (x, y)
    }

    func isScrollingElement(_ n: HTMLNode) -> Bool { n === document.documentElement || n === document.body }

    func Element_scroll(_ n: HTMLNode, _ a: JSValue, _ b: JSValue) {
        let (x, y) = scrollArgs(a, b)
        if isScrollingElement(n) {
            let (sx, sy) = host.scrollPosition()
            host.scrollTo(x.map { $0.isNaN ? 0 : $0 } ?? sx, y.map { $0.isNaN ? 0 : $0 } ?? sy)
        }
    }
    func Element_scrollBy(_ n: HTMLNode, _ a: JSValue, _ b: JSValue) {
        let (x, y) = scrollArgs(a, b)
        if isScrollingElement(n) {
            let (sx, sy) = host.scrollPosition()
            host.scrollTo(sx + (x ?? 0), sy + (y ?? 0))
        }
    }
    func Element_scrollTop(_ n: HTMLNode) -> Double { isScrollingElement(n) ? host.scrollPosition().1 : 0 }
    func Element_scrollLeft(_ n: HTMLNode) -> Double { isScrollingElement(n) ? host.scrollPosition().0 : 0 }
    func Element_set_scrollTop(_ n: HTMLNode, _ v: Double) {
        if isScrollingElement(n) { host.scrollTo(host.scrollPosition().0, v.isNaN ? 0 : max(0, v)) }
    }
    func Element_set_scrollLeft(_ n: HTMLNode, _ v: Double) {
        if isScrollingElement(n) { host.scrollTo(v.isNaN ? 0 : max(0, v), host.scrollPosition().1) }
    }

    func metrics(_ n: HTMLNode) -> LayoutMetrics? {
        guard n.isConnected, let e = host.layout() else { return nil }
        return e.metrics(of: n)
    }
    func Element_scrollWidth(_ n: HTMLNode) -> Int { jsdomRound(metrics(n)?.scrollWidth ?? 0) }
    func Element_scrollHeight(_ n: HTMLNode) -> Int { jsdomRound(metrics(n)?.scrollHeight ?? 0) }
    func Element_clientTop(_ n: HTMLNode) -> Int { jsdomRound(metrics(n)?.clientTop ?? 0) }
    func Element_clientLeft(_ n: HTMLNode) -> Int { jsdomRound(metrics(n)?.clientLeft ?? 0) }
    func Element_clientWidth(_ n: HTMLNode) -> Int {
        if n === document.documentElement { return host.viewport().0 }
        return jsdomRound(metrics(n)?.clientWidth ?? 0)
    }
    func Element_clientHeight(_ n: HTMLNode) -> Int {
        if n === document.documentElement { return host.viewport().1 }
        return jsdomRound(metrics(n)?.clientHeight ?? 0)
    }

    func HTMLElement_offsetParent(_ n: HTMLNode) -> HTMLNode? {
        guard n.isConnected, n !== document.body, let e = host.layout() else { return nil }
        guard let st = e.computedStyle(of: n), st.display != .none, st.position != .fixed else { return nil }
        var p = n.parent
        while let x = p, x.kind == .element {
            if x === document.body { return x }
            if let s = e.computedStyle(of: x) {
                if s.position != .static { return x }
                if s.position == .static && (x.isHTML("td") || x.isHTML("th") || x.isHTML("table")) { return x }
            }
            p = x.parent
        }
        return document.body
    }

    func offsetOrigin(_ n: HTMLNode) -> (Double, Double) {
        guard let r = layoutRect(n) else { return (0, 0) }
        guard let p = HTMLElement_offsetParent(n), p !== document.body, let pr = layoutRect(p) else { return (r.x, r.y) }
        let st = host.layout()?.computedStyle(of: p)
        return (r.x - pr.x - (st?.borderLeftWidth ?? 0), r.y - pr.y - (st?.borderTopWidth ?? 0))
    }
    func HTMLElement_offsetTop(_ n: HTMLNode) -> Int { jsdomRound(offsetOrigin(n).1) }
    func HTMLElement_offsetLeft(_ n: HTMLNode) -> Int { jsdomRound(offsetOrigin(n).0) }
    func HTMLElement_offsetWidth(_ n: HTMLNode) -> Int { jsdomRound(layoutRect(n)?.w ?? 0) }
    func HTMLElement_offsetHeight(_ n: HTMLNode) -> Int { jsdomRound(layoutRect(n)?.h ?? 0) }

    // MARK: HTMLElement

    func HTMLElement_click(_ n: HTMLNode) {
        if isDisabled(n) { return }
        if clickInProgress.contains(ObjectIdentifier(n)) { return }
        clickInProgress.insert(ObjectIdentifier(n))
        defer { clickInProgress.remove(ObjectIdentifier(n)) }
        let e = JSDOMEvent(.PointerEvent, type: "click", time: now())
        e.bubbles = true
        e.cancelable = true
        e.composed = true
        e.viewIsWindow = true
        e.detail = 1
        e.isTrusted = false
        _ = try? dispatch(e, to: .node(n))
    }

    /// innerText getter (approximation: textContent with <br> as newlines,
    /// block boundaries as newlines, and display:none subtrees skipped when
    /// layout is available).
    func HTMLElement_innerText(_ n: HTMLNode) -> String {
        var out: [UInt8] = []
        var stack: [(HTMLNode, Bool)] = [(n, false)]
        let engine = n.isConnected ? host.layout() : nil
        while let (x, closing) = stack.popLast() {
            if closing {
                if jsdomIsBlockName(x.name) && !out.isEmpty && out.last != 0x0a { out.append(0x0a) }
                continue
            }
            if x.kind == .text { out.append(contentsOf: x.data); continue }
            if x.kind != .element && x.kind != .documentFragment { continue }
            if x.kind == .element {
                if x.isHTML("br") { out.append(0x0a); continue }
                if x.isHTML("script") || x.isHTML("style") || x.isHTML("template") { continue }
                if x !== n, let e = engine, let st = e.computedStyle(of: x), st.display == .none { continue }
                if jsdomIsBlockName(x.name) && !out.isEmpty && out.last != 0x0a { out.append(0x0a) }
                stack.append((x, true))
            }
            var i = x.children.count - 1
            while i >= 0 { stack.append((x.children[i], false)); i -= 1 }
        }
        while out.last == 0x0a { out.removeLast() }
        return String(decoding: out, as: UTF8.self)
    }

    func HTMLElement_set_innerText(_ n: HTMLNode, _ v: String) {
        let doc = n.nodeDocument ?? document
        let f = doc.createDocumentFragment()
        var line: [UInt8] = []
        func flush() {
            if !line.isEmpty { _ = try? f.appendChild(doc.createTextNode(String(decoding: line, as: UTF8.self))); line = [] }
        }
        for b in v.utf8 {
            if b == 0x0a { flush(); _ = try? f.appendChild(doc.makeElement("br", .html)) }
            else if b != 0x0d { line.append(b) }
        }
        flush()
        n.replaceAllUnchecked(f.children.isEmpty ? nil : f)
    }

    func HTMLElement_isContentEditable(_ n: HTMLNode) -> Bool {
        var x: HTMLNode? = n
        while let e = x, e.kind == .element {
            if let v = e.attribute("contenteditable") {
                let l = htmlLowerASCII(v)
                if l == "" || l == "true" || l == "plaintext-only" { return true }
                if l == "false" { return false }
            }
            x = e.parent
        }
        return document.attribute("designMode") == "on"
    }

    // MARK: HTMLOrSVGElement

    func HTMLOrSVGElement_dataset(_ n: HTMLNode) -> JSValue { classes.DOMStringMap.wrap(JSDOMStringMap(n)) }
    func ElementCSSInlineStyle_style(_ n: HTMLNode) -> JSValue { inlineStyle(n) }

    func isFocusable(_ n: HTMLNode) -> Bool {
        guard n.kind == .element, n.isConnected else { return false }
        if n.attribute("tabindex") != nil { return true }
        if n.namespace != .html { return false }
        switch n.name {
        case "a", "area": return n.attribute("href") != nil
        case "input": return inputType(n) != "hidden" && !isDisabled(n)
        case "select", "textarea", "button": return !isDisabled(n)
        case "iframe", "summary": return true
        default: return HTMLElement_isContentEditable(n)
        }
    }

    func HTMLOrSVGElement_tabIndex(_ n: HTMLNode) -> Int {
        if let v = n.attribute("tabindex"), let i = jsdomParseInteger(v), i >= -2_147_483_648, i <= 2_147_483_647 { return i }
        if n.namespace == .html {
            switch n.name {
            case "a", "area": return n.attribute("href") != nil ? 0 : -1
            case "input", "select", "textarea", "button", "iframe", "summary": return 0
            default: break
            }
        }
        return -1
    }
    func HTMLOrSVGElement_set_tabIndex(_ n: HTMLNode, _ v: Int) { n.setAttributeValue("tabindex", String(v)) }

    func HTMLOrSVGElement_focus(_ n: HTMLNode, _ options: JSValue) {
        var target = n
        if let s = n.attachedShadowRoot, s.delegatesFocus {
            if let f = s.firstElement(where: { self.isFocusable($0) }) { target = f } else { return }
        }
        if !isFocusable(target) { return }
        setFocus(target)
    }

    func HTMLOrSVGElement_blur(_ n: HTMLNode) {
        if focused === n { setFocus(nil) }
    }

    /// Move focus, firing blur/focusout on the old and focus/focusin on the
    /// new element (relatedTarget set), and tell the browser.
    func setFocus(_ n: HTMLNode?) {
        if focused === n { return }
        let old = focused
        focused = n
        if let o = old, o.isConnected {
            fireFocus("blur", o, related: n, bubbles: false)
            fireFocus("focusout", o, related: n, bubbles: true)
        }
        if let x = n, focused === x {
            fireFocus("focus", x, related: old, bubbles: false)
            fireFocus("focusin", x, related: old, bubbles: true)
        }
        host.focusChanged(focused)
    }

    func fireFocus(_ type: String, _ n: HTMLNode, related: HTMLNode?, bubbles: Bool) {
        let e = JSDOMEvent(.FocusEvent, type: type, time: now())
        e.bubbles = bubbles
        e.composed = true
        e.isTrusted = true
        e.viewIsWindow = true
        e.relatedTarget = related.map { .node($0) }
        _ = try? dispatch(e, to: .node(n))
    }
}

func jsdomUpperASCII(_ s: String) -> String {
    var out: [UInt8] = []
    out.reserveCapacity(s.utf8.count)
    for b in s.utf8 { out.append(b >= 0x61 && b <= 0x7a ? b - 0x20 : b) }
    return String(decoding: out, as: UTF8.self)
}

func jsdomIsBlockName(_ n: String) -> Bool {
    switch n {
    case "p", "div", "section", "article", "header", "footer", "nav", "aside", "main", "h1", "h2", "h3", "h4", "h5",
         "h6", "ul", "ol", "li", "dl", "dt", "dd", "table", "tr", "blockquote", "pre", "form", "fieldset", "figure",
         "figcaption", "address", "hr", "details", "summary", "body", "html":
        return true
    default: return false
    }
}

