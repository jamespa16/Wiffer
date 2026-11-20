// Document, DOMImplementation, DOMParser and XMLSerializer.
//
// Every document is an HTML document except createDocument's (an "XML"
// document only in that tagName keeps its case and contentType says so:
// there is no XML parser here, and DOMParser parses every type as HTML).
// document.write appends parsed markup after the running script (9H's
// "scripts run after parsing" model), or at the end of <body> otherwise.

final class JSDOMImplementation {
    let document: HTMLNode
    init(_ d: HTMLNode) { document = d }
}

final class JSDOMParser { init() {} }
final class JSDOMXMLSerializer { init() {} }

extension JSDOMBindings {
    func Document_constructor(newTarget: JSValue) throws(JSThrow) -> JSValue {
        let d = htmlNewDocument()
        xmlDocuments.insert(ObjectIdentifier(d))
        keepDocument(d)
        let w = wrapNode(d)
        try adoptNewTarget(w, newTarget, .Document)
        return w
    }

    /// Documents made by script stay alive with the page (their nodes'
    /// parent pointers depend on the document).
    func keepDocument(_ d: HTMLNode) {
        extraDocuments.append(d)
        if extraDocuments.count > 10_000 { extraDocuments.removeFirst() }
    }

    func Document_implementation(_ d: HTMLNode) -> JSValue { classes.DOMImplementation.wrap(JSDOMImplementation(d)) }
    func Document_URL(_ d: HTMLNode) -> String { d === document ? (url?.href ?? "about:blank") : "about:blank" }
    func Document_compatMode(_ d: HTMLNode) -> String { d.quirksMode ? "BackCompat" : "CSS1Compat" }
    func Document_characterSet(_ d: HTMLNode) -> String { "UTF-8" }
    func Document_contentType(_ d: HTMLNode) -> String {
        if !isHTMLDocument(d) {
            if let de = d.documentElement, de.namespace == .html { return "application/xhtml+xml" }
            if let de = d.documentElement, de.namespace == .svg { return "image/svg+xml" }
            return "application/xml"
        }
        return "text/html"
    }
    func Document_doctype(_ d: HTMLNode) -> HTMLNode? { d.children.first { $0.kind == .doctype } }
    func Document_documentElement(_ d: HTMLNode) -> HTMLNode? { d.documentElement }
    func Document_getElementsByTagName(_ d: HTMLNode, _ q: String) -> JSValue { makeCollection(d, .tagName(q)) }
    func Document_getElementsByTagNameNS(_ d: HTMLNode, _ ns: String?, _ l: String) -> JSValue {
        makeCollection(d, .tagNameNS((ns?.isEmpty ?? true) ? nil : ns, l))
    }
    func Document_getElementsByClassName(_ d: HTMLNode, _ c: String) -> JSValue {
        makeCollection(d, .className(htmlSplitWhitespace(c)))
    }

    // MARK: Node creation

    func Document_createElement(_ d: HTMLNode, _ name: String, _ options: JSValue) throws(JSThrow) -> HTMLNode? {
        guard htmlIsValidElementName(name) else {
            throw throwDOM("InvalidCharacterError", "'" + name + "' is not a valid element name.")
        }
        return d.makeElement(isHTMLDocument(d) ? htmlLowerASCII(name) : name, .html)
    }

    func Document_createElementNS(_ d: HTMLNode, _ ns: String?, _ q: String, _ options: JSValue) throws(JSThrow) -> HTMLNode? {
        guard htmlIsValidElementName(q) else { throw throwDOM("InvalidCharacterError", "'" + q + "' is not a valid name.") }
        let nsv = (ns?.isEmpty ?? true) ? nil : ns
        if let i = q.firstIndex(of: ":") {
            let prefix = String(q[q.startIndex..<i])
            if nsv == nil { throw throwDOM("NamespaceError", "A prefix requires a namespace.") }
            if prefix == "xml" && nsv != "http://www.w3.org/XML/1998/namespace" { throw throwDOM("NamespaceError", "Bad xml prefix.") }
            if q.index(after: i) == q.endIndex { throw throwDOM("InvalidCharacterError", "Invalid qualified name.") }
        }
        if (q == "xmlns" || q.hasPrefix("xmlns:")) != (nsv == "http://www.w3.org/2000/xmlns/") {
            throw throwDOM("NamespaceError", "Bad xmlns use.")
        }
        switch nsv {
        case "http://www.w3.org/1999/xhtml": return d.makeElement(q, .html)
        case "http://www.w3.org/2000/svg": return d.makeElement(q, .svg)
        case "http://www.w3.org/1998/Math/MathML": return d.makeElement(q, .mathml)
        default:
            let e = d.makeElement(q, .mathml)
            foreignNamespaces[ObjectIdentifier(e)] = nsv ?? ""
            return e
        }
    }

    func Document_createDocumentFragment(_ d: HTMLNode) throws(JSThrow) -> HTMLNode? { d.createDocumentFragment() }
    func Document_createTextNode(_ d: HTMLNode, _ s: String) throws(JSThrow) -> HTMLNode? { d.createTextNode(s) }
    func Document_createCDATASection(_ d: HTMLNode, _ s: String) throws(JSThrow) -> HTMLNode? {
        throw throwDOM("NotSupportedError", "CDATA sections are not supported in HTML documents.")
    }
    func Document_createComment(_ d: HTMLNode, _ s: String) throws(JSThrow) -> HTMLNode? { d.createComment(s) }
    func Document_createProcessingInstruction(_ d: HTMLNode, _ t: String, _ s: String) throws(JSThrow) -> JSValue {
        throw throwDOM("NotSupportedError", "Processing instructions are not supported.")
    }

    func Document_importNode(_ d: HTMLNode, _ n: HTMLNode, _ options: JSValue) throws(JSThrow) -> HTMLNode? {
        var deep = false
        if options.isObject {
            if case .value(let v) = heap.getProperty(options, heap.key("selfOnly")) { deep = !heap.toBoolean(v) } else { deep = true }
        } else {
            deep = heap.toBoolean(options)
        }
        if n.kind == .document || n.isShadowRoot { throw throwDOM("NotSupportedError", "This node can not be imported.") }
        do throws(HTMLDOMError) { return try d.importNode(n, deep: deep) } catch { throw throwDOM(error) }
    }

    func Document_adoptNode(_ d: HTMLNode, _ n: HTMLNode) throws(JSThrow) -> HTMLNode? {
        if n.kind == .document { throw throwDOM("NotSupportedError", "Documents can not be adopted.") }
        if n.isShadowRoot { throw throwDOM("HierarchyRequestError", "Shadow roots can not be adopted.") }
        do throws(HTMLDOMError) { return try d.adoptNode(n) } catch { throw throwDOM(error) }
    }

    func Document_createAttribute(_ d: HTMLNode, _ name: String) throws(JSThrow) -> JSValue {
        if !htmlIsValidAttributeName(name) { throw throwDOM(.invalidCharacter) }
        return classes.Attr.wrap(JSDOMAttr(owner: nil, name: isHTMLDocument(d) ? htmlLowerASCII(name) : name, value: "", document: d))
    }
    func Document_createAttributeNS(_ d: HTMLNode, _ ns: String?, _ q: String) throws(JSThrow) -> JSValue {
        if !htmlIsValidAttributeName(q) { throw throwDOM(.invalidCharacter) }
        return classes.Attr.wrap(JSDOMAttr(owner: nil, name: q, value: "", document: d))
    }

    func Document_createEvent(_ d: HTMLNode, _ name: String) throws(JSThrow) -> JSDOMEvent {
        let i: JSDOMInterface
        switch htmlLowerASCII(name) {
        case "event", "events", "htmlevents", "svgevents": i = .Event
        case "customevent": i = .CustomEvent
        case "uievent", "uievents": i = .UIEvent
        case "mouseevent", "mouseevents": i = .MouseEvent
        case "keyboardevent": i = .KeyboardEvent
        case "focusevent": i = .FocusEvent
        case "hashchangeevent": i = .HashChangeEvent
        case "errorevent": i = .ErrorEvent
        case "popstateevent": i = .PopStateEvent
        default: throw throwDOM("NotSupportedError", "The provided event type ('" + name + "') is invalid.")
        }
        let e = JSDOMEvent(i, type: "", time: now())
        e.initialized = false
        return e
    }

    func Document_createRange(_ d: HTMLNode) throws(JSThrow) -> JSValue {
        throw throwDOM("NotSupportedError", "Range is not supported.")
    }
    func Document_createTreeWalker(_ d: HTMLNode, _ root: HTMLNode, _ what: Int, _ filter: JSValue) throws(JSThrow) -> JSValue {
        throw throwDOM("NotSupportedError", "TreeWalker is not supported.")
    }
    func Document_createNodeIterator(_ d: HTMLNode, _ root: HTMLNode, _ what: Int, _ filter: JSValue) throws(JSThrow) -> JSValue {
        throw throwDOM("NotSupportedError", "NodeIterator is not supported.")
    }

    // MARK: Resource metadata

    func Document_location(_ d: HTMLNode) -> JSValue { d === document ? locationObject() : .null }
    func Document_domain(_ d: HTMLNode) -> String { d === document ? (url?.hostname ?? "") : "" }
    func Document_set_domain(_ d: HTMLNode, _ v: String) {}
    func Document_referrer(_ d: HTMLNode) -> String { d === document ? host.referrer : "" }
    func Document_cookie(_ d: HTMLNode) throws(JSThrow) -> String { d === document ? host.getCookie() : "" }
    func Document_set_cookie(_ d: HTMLNode, _ v: String) throws(JSThrow) { if d === document { host.setCookie(v) } }
    func Document_lastModified(_ d: HTMLNode) -> String { "01/01/2026 00:00:00" }
    func Document_readyState(_ d: HTMLNode) -> String { d === document ? readyState : "complete" }

    // MARK: Tree accessors

    func titleElement(_ d: HTMLNode) -> HTMLNode? {
        if let de = d.documentElement, de.namespace == .svg {
            return de.children.first { $0.kind == .element && $0.namespace == .svg && $0.name == "title" }
        }
        return d.firstElement { $0.isHTML("title") }
    }

    func Document_title(_ d: HTMLNode) -> String {
        guard let t = titleElement(d) else { return "" }
        return jsdomStripCollapse(Node_textContent(t) ?? "")
    }

    func Document_set_title(_ d: HTMLNode, _ v: String) {
        if let t = titleElement(d) { t.setTextContent(v); return }
        guard let de = d.documentElement, de.namespace == .html, let head = d.head else { return }
        let t = d.makeElement("title", .html)
        t.setTextContent(v)
        _ = try? head.appendChild(t)
        _ = de
    }

    func Document_dir(_ d: HTMLNode) -> String { d.documentElement?.attribute("dir") ?? "" }
    func Document_set_dir(_ d: HTMLNode, _ v: String) { d.documentElement?.setAttributeValue("dir", v) }

    func Document_body(_ d: HTMLNode) throws(JSThrow) -> HTMLNode? {
        guard let de = d.documentElement, de.isHTML("html") else { return nil }
        return de.children.first { $0.isHTML("body") || $0.isHTML("frameset") }
    }

    func Document_set_body(_ d: HTMLNode, _ v: HTMLNode?) throws(JSThrow) {
        guard let b = v, b.isHTML("body") || b.isHTML("frameset") else {
            throw throwDOM("HierarchyRequestError", "The new body element must be a body or frameset element.")
        }
        if let cur = try Document_body(d) {
            if cur === b { return }
            _ = try Node_replaceChild(cur.parent ?? d, b, cur)
            return
        }
        guard let de = d.documentElement else { throw throwDOM("HierarchyRequestError", "There is no document element.") }
        _ = try Node_appendChild(de, b)
    }

    func Document_head(_ d: HTMLNode) -> HTMLNode? {
        guard let de = d.documentElement, de.isHTML("html") else { return nil }
        return de.children.first { $0.isHTML("head") }
    }

    func Document_images(_ d: HTMLNode) -> JSValue { makeCollection(d, .images) }
    func Document_embeds(_ d: HTMLNode) -> JSValue { makeCollection(d, .embeds) }
    func Document_plugins(_ d: HTMLNode) -> JSValue { makeCollection(d, .embeds) }
    func Document_links(_ d: HTMLNode) -> JSValue { makeCollection(d, .links) }
    func Document_forms(_ d: HTMLNode) -> JSValue { makeCollection(d, .forms) }
    func Document_scripts(_ d: HTMLNode) -> JSValue { makeCollection(d, .scripts) }
    func Document_anchors(_ d: HTMLNode) -> JSValue { makeCollection(d, .anchors) }
    func Document_getElementsByName(_ d: HTMLNode, _ name: String) -> JSValue {
        classes.NodeList.wrap(JSDOMNodeList(live: JSDOMHTMLCollection(d, .name(name))))
    }
    func Document_currentScript(_ d: HTMLNode) -> HTMLNode? { d === document ? currentScript : nil }

    // MARK: Dynamic markup insertion

    func Document_write(_ d: HTMLNode, _ parts: [String]) throws(JSThrow) {
        var s = ""
        for p in parts { s += p }
        try documentWrite(d, s)
    }
    func Document_writeln(_ d: HTMLNode, _ parts: [String]) throws(JSThrow) {
        var s = ""
        for p in parts { s += p }
        try documentWrite(d, s + "\n")
    }

    func documentWrite(_ d: HTMLNode, _ s: String) throws(JSThrow) {
        guard d === document else { return }
        if writeDepth > 16 { return }
        writeDepth += 1
        defer { writeDepth -= 1 }
        // After the running script (or after what it wrote so far).
        if let anchor = writeTarget ?? currentScript, let p = anchor.parent {
            let context = p.kind == .element ? p : (document.body ?? p)
            let frag = htmlParseFragment(s, context: context)
            let last = frag.lastChild
            _ = try Node_insertBefore(p, frag, anchor.nextSibling)
            if let l = last { writeTarget = l }
            return
        }
        guard let body = document.body ?? document.documentElement else { return }
        let frag = htmlParseFragment(s, context: body.kind == .element ? body : document.makeElement("body", .html))
        _ = try Node_appendChild(body, frag)
    }

    func Document_open(_ d: HTMLNode, _ a: JSValue, _ b: JSValue) -> JSValue { wrapNode(d) }
    func Document_close(_ d: HTMLNode) {}

    // MARK: User interaction

    func Document_defaultView(_ d: HTMLNode) -> JSValue { d === document ? realm.global : .null }
    func Document_hasFocus(_ d: HTMLNode) -> Bool { d === document && host.hasFocus() }
    func Document_designMode(_ d: HTMLNode) -> String { designMode ? "on" : "off" }
    func Document_set_designMode(_ d: HTMLNode, _ v: String) {
        let l = htmlLowerASCII(v)
        if l == "on" { designMode = true } else if l == "off" { designMode = false }
    }
    func Document_execCommand(_ d: HTMLNode, _ cmd: String, _ ui: Bool, _ v: String) -> Bool {
        if htmlLowerASCII(cmd) == "copy" { return false }
        return false
    }
    func Document_queryCommandSupported(_ d: HTMLNode, _ cmd: String) -> Bool { false }
    func Document_hidden(_ d: HTMLNode) -> Bool { false }
    func Document_visibilityState(_ d: HTMLNode) -> String { "visible" }
    func Document_getSelection(_ d: HTMLNode) -> JSValue { d === document ? selectionObject() : .null }

    func Document_elementFromPoint(_ d: HTMLNode, _ x: Double, _ y: Double) -> JSValue {
        guard d === document, let e = host.layout() else { return .null }
        let (sx, sy) = host.scrollPosition()
        let hit = e.hitTest(x: x, y: y, scrollX: sx, scrollY: sy)
        var n = hit.documentNode ?? hit.node
        while let x = n, x.kind != .element { n = x.parent }
        return wrapNode(n ?? document.body)
    }
    func Document_elementsFromPoint(_ d: HTMLNode, _ x: Double, _ y: Double) -> JSValue {
        let v = Document_elementFromPoint(d, x, y)
        guard let n = nodeClass.unwrap(v) else { return array([]) }
        var out: [HTMLNode] = []
        var x: HTMLNode? = n
        while let e = x, e.kind == .element { out.append(e); x = e.parent }
        return nodeArray(out)
    }
    func Document_scrollingElement(_ d: HTMLNode) -> HTMLNode? {
        d.quirksMode ? (try? Document_body(d)) ?? nil : d.documentElement
    }

    // MARK: DOMImplementation

    func DOMImplementation_createDocumentType(_ i: JSDOMImplementation, _ name: String, _ pub: String, _ sys: String) throws(JSThrow) -> HTMLNode? {
        if name.isEmpty == false && !htmlIsValidAttributeName(name) && !name.contains(":") {
            throw throwDOM("InvalidCharacterError", "Invalid doctype name.")
        }
        for b in name.utf8 where htmlIsSpaceByte(b) || b == 0 || b == 0x3e {
            throw throwDOM("InvalidCharacterError", "Invalid doctype name.")
        }
        return jsdomMakeDoctype(i.document, name, pub, sys)
    }

    func DOMImplementation_createDocument(_ i: JSDOMImplementation, _ ns: String?, _ q: String, _ dt: HTMLNode?) throws(JSThrow) -> HTMLNode? {
        let d = htmlNewDocument()
        xmlDocuments.insert(ObjectIdentifier(d))
        keepDocument(d)
        if let t = dt { _ = try Node_appendChild(d, t) }
        if !q.isEmpty, let e = try Document_createElementNS(d, ns, q, .undefined) {
            _ = try Node_appendChild(d, e)
        }
        return d
    }

    func DOMImplementation_createHTMLDocument(_ i: JSDOMImplementation, _ title: String?) throws(JSThrow) -> HTMLNode? {
        let d = htmlNewDocument()
        keepDocument(d)
        let dt = jsdomMakeDoctype(d, "html", "", "")
        _ = try? d.appendChild(dt)
        let html = d.makeElement("html", .html)
        _ = try? d.appendChild(html)
        let head = d.makeElement("head", .html)
        _ = try? html.appendChild(head)
        if let t = title {
            let te = d.makeElement("title", .html)
            _ = try? te.appendChild(d.createTextNode(t))
            _ = try? head.appendChild(te)
        }
        _ = try? html.appendChild(d.makeElement("body", .html))
        return d
    }

    func DOMImplementation_hasFeature(_ i: JSDOMImplementation) -> Bool { true }

    // MARK: DOMParser, XMLSerializer

    func DOMParser_constructor(newTarget: JSValue) throws(JSThrow) -> JSValue { classes.DOMParser.wrap(JSDOMParser()) }

    func DOMParser_parseFromString(_ p: JSDOMParser, _ s: String, _ type: String) throws(JSThrow) -> HTMLNode? {
        switch type {
        case "text/html", "text/xml", "application/xml", "application/xhtml+xml", "image/svg+xml": break
        default: throw realm.throwTypeError("Failed to execute 'parseFromString' on 'DOMParser': The provided value '" + type + "' is not a valid enum value of type DOMParserSupportedType.")
        }
        let d = htmlParse(s, declarativeShadowRoots: false)
        if type != "text/html" { xmlDocuments.insert(ObjectIdentifier(d)) }
        keepDocument(d)
        return d
    }

    func XMLSerializer_constructor(newTarget: JSValue) throws(JSThrow) -> JSValue { classes.XMLSerializer.wrap(JSDOMXMLSerializer()) }
    func XMLSerializer_serializeToString(_ s: JSDOMXMLSerializer, _ n: HTMLNode) -> String {
        n.kind == .document ? htmlSerializeChildren(n) : htmlSerialize(n)
    }
}

func jsdomMakeDoctype(_ doc: HTMLNode, _ name: String, _ pub: String, _ sys: String) -> HTMLNode {
    let n = HTMLNode(kind: .doctype, name: name)
    n.publicID = pub
    n.systemID = sys
    (doc.nodeDocument ?? doc).registerNode(n)
    return n
}

/// "Strip and collapse ASCII whitespace".
func jsdomStripCollapse(_ s: String) -> String {
    var out: [UInt8] = []
    var space = false
    for b in s.utf8 {
        if htmlIsSpaceByte(b) { space = !out.isEmpty; continue }
        if space { out.append(0x20); space = false }
        out.append(b)
    }
    return String(decoding: out, as: UTF8.self)
}
