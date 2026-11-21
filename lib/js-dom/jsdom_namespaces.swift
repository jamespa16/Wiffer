// Namespaces and the node kinds lib/html doesn't model:
//
// - "validate and extract" (createElementNS, setAttributeNS, createDocument,
//   createAttributeNS) and the prefix / localName of elements created with a
//   prefix (lib/html stores the qualified name);
// - namespaced attributes: lib/html stores attributes by qualified name only,
//   so the namespace of an attribute set with setAttributeNS lives in
//   `attrNamespaces` (parser-adjusted xlink:/xml:/xmlns attributes are
//   recognized by their prefix);
// - ProcessingInstruction (a comment node flagged in `piTargets`) and
//   CDATASection (a text node in `cdataNodes`): same tree rules, their own
//   nodeType / nodeName / interface;
// - lookupNamespaceURI / lookupPrefix / isDefaultNamespace;
// - document named properties (document.formName, document.imgName).

let jsdomXMLNS = "http://www.w3.org/XML/1998/namespace"
let jsdomXMLNSNS = "http://www.w3.org/2000/xmlns/"
let jsdomXLinkNS = "http://www.w3.org/1999/xlink"
let jsdomHTMLNS = "http://www.w3.org/1999/xhtml"

struct JSDOMQName {
    var namespace: String?
    var prefix: String?
    var local: String
}

extension JSDOMBindings {
    // MARK: Validate and extract

    func validateAndExtract(_ nsIn: String?, _ q: String, element: Bool) throws(JSThrow) -> JSDOMQName {
        let ns = (nsIn?.isEmpty ?? true) ? nil : nsIn
        var prefix: String? = nil
        var local = q
        if let i = q.firstIndex(of: ":") {
            let p = String(q[q.startIndex..<i])
            let l = String(q[q.index(after: i)...])
            if p.isEmpty || l.isEmpty || !jsdomValidPrefix(p) || !(element ? htmlIsValidElementName(l) : htmlIsValidAttributeName(l)) {
                throw throwDOM("InvalidCharacterError", "'" + q + "' is not a valid qualified name.")
            }
            prefix = p
            local = l
        } else if !(element ? htmlIsValidElementName(q) : htmlIsValidAttributeName(q)) {
            throw throwDOM("InvalidCharacterError", "'" + q + "' is not a valid qualified name.")
        }
        if prefix != nil && ns == nil { throw throwDOM("NamespaceError", "A namespace is required for a prefixed name.") }
        if prefix == "xml" && ns != jsdomXMLNS { throw throwDOM("NamespaceError", "The xml prefix requires the XML namespace.") }
        if (q == "xmlns" || prefix == "xmlns") && ns != jsdomXMLNSNS { throw throwDOM("NamespaceError", "xmlns requires the XMLNS namespace.") }
        if ns == jsdomXMLNSNS && q != "xmlns" && prefix != "xmlns" { throw throwDOM("NamespaceError", "The XMLNS namespace requires xmlns.") }
        return JSDOMQName(namespace: ns, prefix: prefix, local: local)
    }

    // MARK: Element names

    func elementPrefix(_ n: HTMLNode) -> String? {
        guard prefixedElements.contains(ObjectIdentifier(n)), let i = n.name.firstIndex(of: ":") else { return nil }
        return String(n.name[n.name.startIndex..<i])
    }

    func elementLocalName(_ n: HTMLNode) -> String {
        guard prefixedElements.contains(ObjectIdentifier(n)), let i = n.name.firstIndex(of: ":") else { return n.name }
        return String(n.name[n.name.index(after: i)...])
    }

    func elementNamespace(_ n: HTMLNode) -> String? {
        if let f = foreignNamespaces[ObjectIdentifier(n)] { return f.isEmpty ? nil : f }
        return jsdomNamespaceURI(n)
    }

    // MARK: Attributes

    /// The namespace of a stored attribute.
    func attrNamespace(_ n: HTMLNode, _ name: String) -> String? {
        if !attrNamespaces.isEmpty, let ns = attrNamespaces[JSDOMAttrKey(node: ObjectIdentifier(n), name: name)] { return ns }
        // Parser-adjusted foreign attributes (xlink:href on SVG, ...).
        for a in n.attributes where a.name == name {
            if !a.isNamespaced { return nil }
            if name.hasPrefix("xlink:") { return jsdomXLinkNS }
            if name.hasPrefix("xml:") { return jsdomXMLNS }
            if name == "xmlns" || name.hasPrefix("xmlns:") { return jsdomXMLNSNS }
            return nil
        }
        return nil
    }

    func attrLocalName(_ n: HTMLNode, _ name: String) -> String {
        guard attrNamespace(n, name) != nil, let i = name.firstIndex(of: ":") else { return name }
        return String(name[name.index(after: i)...])
    }

    func attrPrefix(_ n: HTMLNode, _ name: String) -> String? {
        guard attrNamespace(n, name) != nil, let i = name.firstIndex(of: ":") else { return nil }
        return String(name[name.startIndex..<i])
    }

    /// The index of the attribute (namespace, localName), if present.
    func findAttributeNS(_ n: HTMLNode, _ nsIn: String?, _ local: String) -> Int? {
        let ns = (nsIn?.isEmpty ?? true) ? nil : nsIn
        var i = 0
        while i < n.attributes.count {
            let name = n.attributes[i].name
            if attrNamespace(n, name) == ns && attrLocalName(n, name) == local { return i }
            i += 1
        }
        return nil
    }

    func setAttributeNS(_ n: HTMLNode, _ nsIn: String?, _ q: String, _ v: String) throws(JSThrow) {
        let qn = try validateAndExtract(nsIn, q, element: false)
        if let i = findAttributeNS(n, qn.namespace, qn.local) {
            n.setAttributeValue(n.attributes[i].name, v)
            return
        }
        if qn.namespace == nil && n.hasAttribute(q) {
            // A same-named attribute in some namespace exists: add a second one.
            appendAttribute(n, q, v, namespaced: false)
            return
        }
        if let ns = qn.namespace { attrNamespaces[JSDOMAttrKey(node: ObjectIdentifier(n), name: q)] = ns }
        if n.hasAttribute(q) { appendAttribute(n, q, v, namespaced: qn.namespace != nil) } else { n.setAttributeValue(q, v) }
    }

    /// Append an attribute even if one of the same qualified name exists.
    func appendAttribute(_ n: HTMLNode, _ name: String, _ v: String, namespaced: Bool) {
        n.attributes.append(HTMLAttribute(name: name, value: v, isNamespaced: namespaced))
        if n.observed { n.notify(HTMLMutation(kind: .attributes, target: n, attributeName: name, oldValue: nil)) }
    }

    func removeAttributeNS(_ n: HTMLNode, _ ns: String?, _ local: String) {
        guard let i = findAttributeNS(n, ns, local) else { return }
        let name = n.attributes[i].name
        detachAttr(n, name)
        let old = n.attributes[i].value
        n.attributes.remove(at: i)
        // Notify first: the custom element layer reads the namespace.
        if n.observed { n.notify(HTMLMutation(kind: .attributes, target: n, attributeName: name, oldValue: old)) }
        attrNamespaces[JSDOMAttrKey(node: ObjectIdentifier(n), name: name)] = nil
    }

    // MARK: Namespace lookup

    func locateNamespace(_ n: HTMLNode, _ prefixIn: String?) -> String? {
        let prefix = (prefixIn?.isEmpty ?? true) ? nil : prefixIn
        switch n.kind {
        case .element:
            if prefix == "xml" { return jsdomXMLNS }
            if prefix == "xmlns" { return jsdomXMLNSNS }
            var x: HTMLNode? = n
            var k = 0
            while let e = x, e.kind == .element, k < 100_000 {
                k += 1
                if let ns = elementNamespace(e), elementPrefix(e) == prefix { return ns }
                for a in e.attributes where attrNamespace(e, a.name) == jsdomXMLNSNS {
                    let p = attrPrefix(e, a.name)
                    let l = attrLocalName(e, a.name)
                    if (p == "xmlns" && l == prefix) || (prefix == nil && p == nil && l == "xmlns") {
                        return a.value.isEmpty ? nil : a.value
                    }
                }
                x = e.parent
            }
            return nil
        case .document:
            guard let de = n.documentElement else { return nil }
            return locateNamespace(de, prefix)
        case .doctype, .documentFragment:
            return nil
        default:
            guard let p = n.parentElement else { return nil }
            return locateNamespace(p, prefix)
        }
    }

    func locatePrefix(_ e: HTMLNode, _ ns: String) -> String? {
        var x: HTMLNode? = e
        var k = 0
        while let el = x, el.kind == .element, k < 100_000 {
            k += 1
            if elementNamespace(el) == ns, let p = elementPrefix(el) { return p }
            for a in el.attributes where attrPrefix(el, a.name) == "xmlns" && a.value == ns { return attrLocalName(el, a.name) }
            x = el.parent
        }
        return nil
    }

    func Node_lookupNamespaceURI(_ n: HTMLNode, _ prefix: String?) -> String? { locateNamespace(n, prefix) }

    func Node_lookupPrefix(_ n: HTMLNode, _ nsIn: String?) -> String? {
        guard let ns = nsIn, !ns.isEmpty else { return nil }
        switch n.kind {
        case .element: return locatePrefix(n, ns)
        case .document: return n.documentElement.flatMap { locatePrefix($0, ns) }
        case .doctype, .documentFragment: return nil
        default: return n.parentElement.flatMap { locatePrefix($0, ns) }
        }
    }

    func Node_isDefaultNamespace(_ n: HTMLNode, _ nsIn: String?) -> Bool {
        let ns = (nsIn?.isEmpty ?? true) ? nil : nsIn
        return locateNamespace(n, nil) == ns
    }

    // MARK: ProcessingInstruction and CDATASection

    func isPI(_ n: HTMLNode) -> Bool { n.kind == .comment && !piTargets.isEmpty && piTargets[ObjectIdentifier(n)] != nil }
    func isCDATA(_ n: HTMLNode) -> Bool { n.kind == .text && !cdataNodes.isEmpty && cdataNodes.contains(ObjectIdentifier(n)) }

    func Document_createProcessingInstruction(_ d: HTMLNode, _ target: String, _ data: String) throws(JSThrow) -> HTMLNode? {
        if !htmlIsValidElementName(target) {
            throw throwDOM("InvalidCharacterError", "'" + target + "' is not a valid processing instruction target.")
        }
        if jsdomHasSubstring(data, "?>") { throw throwDOM("InvalidCharacterError", "The data contains '?>'.") }
        let c = d.createComment(data)
        piTargets[ObjectIdentifier(c)] = target
        return c
    }

    func Document_createCDATASection(_ d: HTMLNode, _ data: String) throws(JSThrow) -> HTMLNode? {
        if isHTMLDocument(d) { throw throwDOM("NotSupportedError", "CDATA sections are not supported in HTML documents.") }
        if jsdomHasSubstring(data, "]]>") { throw throwDOM("InvalidCharacterError", "The data contains ']]>'.") }
        let t = d.createTextNode(data)
        cdataNodes.insert(ObjectIdentifier(t))
        return t
    }

    func ProcessingInstruction_target(_ n: HTMLNode) -> String { piTargets[ObjectIdentifier(n)] ?? "" }

    /// Copy the side state (PI targets, CDATA flags, control state, element
    /// prefixes and foreign namespaces, attribute namespaces) to a clone.
    func copyNodeFlags(from a: HTMLNode, to b: HTMLNode, deep: Bool) {
        if piTargets.isEmpty && cdataNodes.isEmpty && prefixedElements.isEmpty && foreignNamespaces.isEmpty
            && attrNamespaces.isEmpty && xmlDocuments.isEmpty { return }
        var sa: [HTMLNode] = [a], sb: [HTMLNode] = [b]
        while let x = sa.popLast(), let y = sb.popLast() {
            let kx = ObjectIdentifier(x), ky = ObjectIdentifier(y)
            if let t = piTargets[kx] { piTargets[ky] = t }
            if cdataNodes.contains(kx) { cdataNodes.insert(ky) }
            if prefixedElements.contains(kx) { prefixedElements.insert(ky) }
            if let f = foreignNamespaces[kx] { foreignNamespaces[ky] = f }
            if x.kind == .document && xmlDocuments.contains(kx) { xmlDocuments.insert(ky) }
            for at in x.attributes {
                if let ns = attrNamespaces[JSDOMAttrKey(node: kx, name: at.name)] {
                    attrNamespaces[JSDOMAttrKey(node: ky, name: at.name)] = ns
                }
            }
            if !deep { break }
            if x.children.count == y.children.count {
                sa.append(contentsOf: x.children)
                sb.append(contentsOf: y.children)
            }
        }
    }

    // MARK: Document named properties

    /// The document's named elements for `name` (HTML "supported property
    /// names" of Document): exposed embeds/forms/iframes/images/objects by
    /// name, images/objects (and embeds) by id.
    func documentNamedElements(_ d: HTMLNode, _ name: String) -> [HTMLNode] {
        if name.isEmpty { return [] }
        return descendantsMatching(d) { e in
            guard e.namespace == .html else { return false }
            switch e.name {
            case "form", "iframe", "embed": return e.attribute("name") == name
            case "img": return e.attribute("name") == name || (e.attribute("id") == name && e.attribute("name") != nil && !(e.attribute("name") ?? "").isEmpty)
            case "object": return e.attribute("name") == name || e.attribute("id") == name
            default: return false
            }
        }
    }

    func makeDocumentExotic() -> JSExoticHandler {
        var h = JSExoticHandler()
        h.getOwnProperty = { [unowned(unsafe) self] (realm: JSRealm, o: JSValue, k: JSPropertyKey) throws(JSThrow) -> JSProperty? in
            guard k.isString, let d = self.nodeClass.unwrap(o), d.kind == .document else { return nil }
            if realm.heap.getOwnProperty(o, k) != nil { return nil }
            switch realm.heap.getProperty(realm.heap.getPrototypeOf(o), k) {
            case .value(let v): if !v.isUndefined { return nil }
            case .getter: return nil
            case .exotic: return nil
            }
            let name = realm.heap.swiftString(realm.heap.keyValue(k))
            let els = self.documentNamedElements(d, name)
            if els.isEmpty { return nil }
            if els.count == 1 { return .data(self.wrapNode(els[0]), [.configurable]) }
            return .data(self.makeCollection(d, .documentNamed(name)), [.configurable])
        }
        return h
    }

    // MARK: CompositionEvent

    func CompositionEvent_constructor(_ type: String, _ d: JSDOM_CompositionEventInit, newTarget: JSValue) throws(JSThrow) -> JSValue {
        let e = try uiEvent(.CompositionEvent, type, bubbles: d.bubbles, cancelable: d.cancelable, composed: d.composed,
                            view: d.view, detail: d.detail, which: d.which)
        e.data = d.data
        return try finishEvent(e, newTarget)
    }
    func CompositionEvent_data(_ e: JSDOMEvent) -> String { e.data ?? "" }
}

/// A valid namespace prefix: no whitespace, NUL, '/', '>' (and not empty).
func jsdomValidPrefix(_ p: String) -> Bool {
    if p.isEmpty { return false }
    for b in p.utf8 where htmlIsSpaceByte(b) || b == 0 || b == 0x2f || b == 0x3e { return false }
    return true
}

/// A local name after a prefix: like an attribute local name, plus no ':'
/// at the start (the DOM's relaxed "valid element local name" on the rest).
func jsdomValidLocalNameAfterPrefix(_ l: String) -> Bool {
    if l.isEmpty { return false }
    for b in l.utf8 where htmlIsSpaceByte(b) || b == 0 || b == 0x2f || b == 0x3e { return false }
    return true
}
