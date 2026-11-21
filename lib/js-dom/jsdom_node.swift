// Node, CharacterData, Text, Comment, DocumentType, DocumentFragment,
// ShadowRoot and the ParentNode / ChildNode mixins, over lib/html's
// checked mutation API (HTMLDOM.swift). Offsets in CharacterData are UTF-16
// code units, as in the DOM; lib/html stores UTF-8.

extension JSDOMBindings {
    // MARK: Basics

    func Node_nodeType(_ n: HTMLNode) -> Int {
        switch n.kind {
        case .element: return 1
        case .text: return isCDATA(n) ? 4 : 3
        case .comment: return isPI(n) ? 7 : 8
        case .document: return 9
        case .doctype: return 10
        case .documentFragment: return 11
        }
    }

    func Node_nodeName(_ n: HTMLNode) -> String {
        switch n.kind {
        case .element: return Element_tagName(n)
        case .text: return isCDATA(n) ? "#cdata-section" : "#text"
        case .comment: return isPI(n) ? ProcessingInstruction_target(n) : "#comment"
        case .document: return "#document"
        case .doctype: return n.name
        case .documentFragment: return "#document-fragment"
        }
    }

    func Node_baseURI(_ n: HTMLNode) -> String {
        if (n.nodeDocument ?? n) === document { return baseURL?.href ?? "about:blank" }
        return "about:blank"
    }

    func Node_isConnected(_ n: HTMLNode) -> Bool { n.isConnected }
    func Node_ownerDocument(_ n: HTMLNode) -> HTMLNode? { n.ownerDocument }

    func Node_getRootNode(_ n: HTMLNode, _ options: JSValue) -> HTMLNode? {
        var composed = false
        if options.isObject, case .value(let v) = heap.getProperty(options, heap.key("composed")) { composed = heap.toBoolean(v) }
        return composed ? n.rootNode(composed: true) : n.rootNode
    }

    func Node_parentNode(_ n: HTMLNode) -> HTMLNode? { n.parent }
    func Node_parentElement(_ n: HTMLNode) -> HTMLNode? { n.parentElement }
    func Node_hasChildNodes(_ n: HTMLNode) -> Bool { !n.children.isEmpty }
    func Node_childNodes(_ n: HTMLNode) -> JSValue { classes.NodeList.wrap(JSDOMNodeList(childrenOf: n)) }
    func Node_firstChild(_ n: HTMLNode) -> HTMLNode? { n.firstChild }
    func Node_lastChild(_ n: HTMLNode) -> HTMLNode? { n.lastChild }
    func Node_previousSibling(_ n: HTMLNode) -> HTMLNode? { n.previousSibling }
    func Node_nextSibling(_ n: HTMLNode) -> HTMLNode? { n.nextSibling }

    func Node_nodeValue(_ n: HTMLNode) -> String? { n.isCharacterData ? n.text : nil }
    func Node_set_nodeValue(_ n: HTMLNode, _ v: String?) { if n.isCharacterData { n.setData(v ?? "") } }

    func Node_textContent(_ n: HTMLNode) -> String? {
        switch n.kind {
        case .document, .doctype: return nil
        case .text, .comment: return n.text
        case .element, .documentFragment:
            var bytes: [UInt8] = []
            var stack: [HTMLNode] = [n]
            while let x = stack.popLast() {
                if x.kind == .text { bytes.append(contentsOf: x.data); continue }
                var i = x.children.count - 1
                while i >= 0 { stack.append(x.children[i]); i -= 1 }
            }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    func Node_set_textContent(_ n: HTMLNode, _ v: String?) { n.setTextContent(v ?? "") }

    func Node_normalize(_ n: HTMLNode) {
        var stack: [HTMLNode] = [n]
        while let p = stack.popLast() {
            var i = 0
            while i < p.children.count {
                let c = p.children[i]
                if c.kind == .text {
                    if c.data.isEmpty { c.remove(); continue }
                    var extra: [UInt8] = []
                    var j = i + 1
                    while j < p.children.count, p.children[j].kind == .text { extra.append(contentsOf: p.children[j].data); j += 1 }
                    if j > i + 1 {
                        c.setDataBytes(c.data + extra)
                        while i + 1 < p.children.count, p.children[i + 1].kind == .text { p.children[i + 1].remove() }
                    }
                } else if !c.children.isEmpty {
                    stack.append(c)
                }
                i += 1
            }
        }
    }

    func Node_cloneNode(_ n: HTMLNode, _ deep: Bool) throws(JSThrow) -> HTMLNode? {
        if n.isShadowRoot { throw throwDOM("NotSupportedError", "ShadowRoot nodes are not clonable.") }
        let c = n.cloneNode(deep: deep)
        copyControlState(from: n, to: c, deep: deep)
        copyNodeFlags(from: n, to: c, deep: deep)
        if c.nodeDocument === document { ceCloned(c) }
        if c.kind == .document { hookDocument(c); keepDocument(c) }
        return c
    }

    func Node_isEqualNode(_ a: HTMLNode, _ b: HTMLNode?) -> Bool {
        guard let b = b else { return false }
        var stack: [(HTMLNode, HTMLNode)] = [(a, b)]
        while let (x, y) = stack.popLast() {
            if x.kind != y.kind { return false }
            switch x.kind {
            case .doctype:
                if x.name != y.name || (x.publicID ?? "") != (y.publicID ?? "") || (x.systemID ?? "") != (y.systemID ?? "") { return false }
            case .element:
                if x.name != y.name || x.namespace != y.namespace || x.attributes.count != y.attributes.count { return false }
                for at in x.attributes where y.attribute(at.name) != at.value { return false }
            case .text, .comment:
                if x.data != y.data { return false }
                if isPI(x) != isPI(y) || ProcessingInstruction_target(x) != ProcessingInstruction_target(y) { return false }
            default: break
            }
            if x.children.count != y.children.count { return false }
            var i = 0
            while i < x.children.count { stack.append((x.children[i], y.children[i])); i += 1 }
        }
        return true
    }

    func Node_isSameNode(_ a: HTMLNode, _ b: HTMLNode?) -> Bool { a === b }

    func Node_compareDocumentPosition(_ this: HTMLNode, _ other: HTMLNode) -> Int {
        if this === other { return 0 }
        // Ancestor chains (inclusive), from the node up.
        func chain(_ n: HTMLNode) -> [HTMLNode] {
            var out: [HTMLNode] = []
            var x: HTMLNode? = n
            while let y = x, out.count < 1_000_000 { out.append(y); x = y.parent }
            return out
        }
        let a = chain(other), b = chain(this)
        guard let ra = a.last, let rb = b.last, ra === rb else {
            let fixed = ObjectIdentifier(this) < ObjectIdentifier(other) ? 0x04 : 0x02
            return 0x01 | 0x20 | fixed
        }
        if b.contains(where: { $0 === other }) { return 0x08 | 0x02 }   // other contains this
        if a.contains(where: { $0 === this }) { return 0x10 | 0x04 }    // this contains other
        // Find the divergence point from the root.
        var i = a.count - 1, j = b.count - 1
        while i > 0 && j > 0 && a[i - 1] === b[j - 1] { i -= 1; j -= 1 }
        let ca = a[i - 1], cb = b[j - 1]
        return ca.index < cb.index ? 0x02 : 0x04
    }

    func Node_contains(_ n: HTMLNode, _ o: HTMLNode?) -> Bool { n.contains(o) }

    // MARK: Mutation

    func Node_insertBefore(_ p: HTMLNode, _ n: HTMLNode, _ child: HTMLNode?) throws(JSThrow) -> HTMLNode? {
        do throws(HTMLDOMError) { return try p.insertBefore(n, child) } catch { throw throwDOM(error) }
    }
    func Node_appendChild(_ p: HTMLNode, _ n: HTMLNode) throws(JSThrow) -> HTMLNode? {
        do throws(HTMLDOMError) { return try p.appendChild(n) } catch { throw throwDOM(error) }
    }
    func Node_replaceChild(_ p: HTMLNode, _ n: HTMLNode, _ child: HTMLNode) throws(JSThrow) -> HTMLNode? {
        do throws(HTMLDOMError) { return try p.replaceChild(n, child) } catch { throw throwDOM(error) }
    }
    func Node_removeChild(_ p: HTMLNode, _ child: HTMLNode) throws(JSThrow) -> HTMLNode? {
        do throws(HTMLDOMError) { return try p.removeChild(child) } catch { throw throwDOM(error) }
    }

    /// "Convert nodes into a node": strings become Text nodes; several make a fragment.
    func convertNodes(_ owner: HTMLNode, _ items: [JSValue]) throws(JSThrow) -> HTMLNode? {
        let doc = owner.nodeDocument ?? owner
        var nodes: [HTMLNode] = []
        for v in items {
            if let n = nodeClass.unwrap(v) { nodes.append(n) } else { nodes.append(doc.createTextNode(try toStr(v))) }
        }
        if nodes.isEmpty { return nil }
        if nodes.count == 1 { return nodes[0] }
        let f = doc.createDocumentFragment()
        for n in nodes {
            do throws(HTMLDOMError) { _ = try f.appendChild(n) } catch { throw throwDOM(error) }
        }
        return f
    }

    func ParentNode_prepend(_ p: HTMLNode, _ items: [JSValue]) throws(JSThrow) {
        guard let n = try convertNodes(p, items) else { return }
        _ = try Node_insertBefore(p, n, p.firstChild)
    }
    func ParentNode_append(_ p: HTMLNode, _ items: [JSValue]) throws(JSThrow) {
        guard let n = try convertNodes(p, items) else { return }
        _ = try Node_appendChild(p, n)
    }
    func ParentNode_replaceChildren(_ p: HTMLNode, _ items: [JSValue]) throws(JSThrow) {
        let n = try convertNodes(p, items)
        do throws(HTMLDOMError) { try p.replaceAll(with: n) } catch { throw throwDOM(error) }
    }
    func ParentNode_children(_ p: HTMLNode) -> JSValue { makeCollection(p, .childElements) }
    func ParentNode_firstElementChild(_ p: HTMLNode) -> HTMLNode? { p.children.first { $0.kind == .element } }
    func ParentNode_lastElementChild(_ p: HTMLNode) -> HTMLNode? { p.children.last { $0.kind == .element } }
    func ParentNode_childElementCount(_ p: HTMLNode) -> Int {
        var k = 0
        for c in p.children where c.kind == .element { k += 1 }
        return k
    }
    func ParentNode_querySelector(_ p: HTMLNode, _ sel: String) throws(JSThrow) -> HTMLNode? {
        let list = try parseSelector(sel)
        return querySelect(p, list, first: true).first
    }
    func ParentNode_querySelectorAll(_ p: HTMLNode, _ sel: String) throws(JSThrow) -> JSValue {
        let list = try parseSelector(sel)
        return staticNodeList(querySelect(p, list, first: false))
    }

    func ChildNode_before(_ n: HTMLNode, _ items: [JSValue]) throws(JSThrow) {
        guard let parent = n.parent else { return }
        // The first preceding sibling not in the items.
        var viable = n.previousSibling
        while let v = viable, items.contains(where: { nodeClass.unwrap($0) === v }) { viable = v.previousSibling }
        guard let node = try convertNodes(n, items) else { return }
        _ = try Node_insertBefore(parent, node, viable == nil ? parent.firstChild : viable!.nextSibling)
    }
    func ChildNode_after(_ n: HTMLNode, _ items: [JSValue]) throws(JSThrow) {
        guard let parent = n.parent else { return }
        var viable = n.nextSibling
        while let v = viable, items.contains(where: { nodeClass.unwrap($0) === v }) { viable = v.nextSibling }
        guard let node = try convertNodes(n, items) else { return }
        _ = try Node_insertBefore(parent, node, viable)
    }
    func ChildNode_replaceWith(_ n: HTMLNode, _ items: [JSValue]) throws(JSThrow) {
        guard let parent = n.parent else { return }
        var viable = n.nextSibling
        while let v = viable, items.contains(where: { nodeClass.unwrap($0) === v }) { viable = v.nextSibling }
        let node = try convertNodes(n, items)
        if n.parent === parent {
            if let x = node { _ = try Node_replaceChild(parent, x, n) } else { n.remove() }
        } else if let x = node {
            _ = try Node_insertBefore(parent, x, viable)
        }
    }
    func ChildNode_remove(_ n: HTMLNode) { n.remove() }

    func NonDocumentTypeChildNode_previousElementSibling(_ n: HTMLNode) -> HTMLNode? {
        var x = n.previousSibling
        while let y = x { if y.kind == .element { return y }; x = y.previousSibling }
        return nil
    }
    func NonDocumentTypeChildNode_nextElementSibling(_ n: HTMLNode) -> HTMLNode? {
        var x = n.nextSibling
        while let y = x { if y.kind == .element { return y }; x = y.nextSibling }
        return nil
    }

    func NonElementParentNode_getElementById(_ n: HTMLNode, _ id: String) -> HTMLNode? {
        if id.isEmpty { return nil }
        return descendantsMatching(n) { $0.attribute("id") == id }.first
    }

    func DocumentOrShadowRoot_activeElement(_ n: HTMLNode) -> HTMLNode? {
        if n.kind == .document {
            if n !== document { return nil }
            guard let f = focused, f.isConnected else { return document.body ?? document.documentElement }
            return f.retargeted(against: document)
        }
        guard let f = focused, f.isConnected else { return nil }
        let r = f.retargeted(against: n)
        return r.rootNode === n ? r : nil
    }

    func Slottable_assignedSlot(_ n: HTMLNode) -> HTMLNode? { n.assignedSlot }

    // MARK: DocumentType, DocumentFragment, ShadowRoot

    func DocumentType_name(_ n: HTMLNode) -> String { n.name }
    func DocumentType_publicId(_ n: HTMLNode) -> String { n.publicID ?? "" }
    func DocumentType_systemId(_ n: HTMLNode) -> String { n.systemID ?? "" }

    func DocumentFragment_constructor(newTarget: JSValue) throws(JSThrow) -> JSValue {
        let w = wrapNode(document.createDocumentFragment())
        try adoptNewTarget(w, newTarget, .DocumentFragment)
        return w
    }

    func ShadowRoot_mode(_ n: HTMLNode) -> String { n.shadowRootMode == .closed ? "closed" : "open" }
    func ShadowRoot_delegatesFocus(_ n: HTMLNode) -> Bool { n.delegatesFocus }
    func ShadowRoot_slotAssignment(_ n: HTMLNode) -> String { n.slotAssignment == .manual ? "manual" : "named" }
    func ShadowRoot_clonable(_ n: HTMLNode) -> Bool { n.clonable }
    func ShadowRoot_serializable(_ n: HTMLNode) -> Bool { n.serializable }
    func ShadowRoot_host(_ n: HTMLNode) -> HTMLNode? { n.host }
    func ShadowRoot_innerHTML(_ n: HTMLNode) -> String { n.innerHTML }
    func ShadowRoot_set_innerHTML(_ n: HTMLNode, _ v: String) { n.setInnerHTML(v) }
    func ShadowRoot_setHTMLUnsafe(_ n: HTMLNode, _ v: String) { n.setHTMLUnsafe(v) }
    func ShadowRoot_getHTML(_ n: HTMLNode, _ options: JSValue) -> String { getHTML(n, options) }

    func getHTML(_ n: HTMLNode, _ options: JSValue) -> String {
        var ser = false
        var roots: [HTMLNode] = []
        if options.isObject {
            if case .value(let v) = heap.getProperty(options, heap.key("serializableShadowRoots")) { ser = heap.toBoolean(v) }
            if case .value(let v) = heap.getProperty(options, heap.key("shadowRoots")), v.isObject {
                let len = Int(heap.arrayLength(v))
                var i = 0
                while i < len && i < 100_000 {
                    if case .value(let x) = heap.getProperty(v, .index(UInt32(i))), let r = nodeClass.unwrap(x) { roots.append(r) }
                    i += 1
                }
            }
        }
        return n.getHTML(serializableShadowRoots: ser, shadowRoots: roots)
    }

    // MARK: CharacterData, Text, Comment

    func units(_ n: HTMLNode) -> [UInt16] { Array(n.text.utf16) }
    func setUnits(_ n: HTMLNode, _ u: [UInt16]) { n.setData(String(decoding: u, as: UTF16.self)) }

    func CharacterData_data(_ n: HTMLNode) -> String { n.text }
    func CharacterData_set_data(_ n: HTMLNode, _ v: String) { n.setData(v) }
    func CharacterData_length(_ n: HTMLNode) -> Int { n.text.utf16.count }
    func CharacterData_appendData(_ n: HTMLNode, _ v: String) { n.appendData(v) }

    func CharacterData_substringData(_ n: HTMLNode, _ off: Int, _ count: Int) throws(JSThrow) -> String {
        let u = units(n)
        if off > u.count { throw throwDOM("IndexSizeError", "The offset is greater than the length.") }
        let end = min(u.count, off + count)
        return String(decoding: u[off..<end], as: UTF16.self)
    }
    func CharacterData_insertData(_ n: HTMLNode, _ off: Int, _ v: String) throws(JSThrow) {
        try CharacterData_replaceData(n, off, 0, v)
    }
    func CharacterData_deleteData(_ n: HTMLNode, _ off: Int, _ count: Int) throws(JSThrow) {
        try CharacterData_replaceData(n, off, count, "")
    }
    func CharacterData_replaceData(_ n: HTMLNode, _ off: Int, _ count: Int, _ v: String) throws(JSThrow) {
        var u = units(n)
        if off > u.count { throw throwDOM("IndexSizeError", "The offset is greater than the length.") }
        let end = min(u.count, off + count)
        u.replaceSubrange(off..<end, with: Array(v.utf16))
        setUnits(n, u)
    }

    func Text_constructor(_ data: String, newTarget: JSValue) throws(JSThrow) -> JSValue {
        let w = wrapNode(document.createTextNode(data))
        try adoptNewTarget(w, newTarget, .Text)
        return w
    }
    func Comment_constructor(_ data: String, newTarget: JSValue) throws(JSThrow) -> JSValue {
        let w = wrapNode(document.createComment(data))
        try adoptNewTarget(w, newTarget, .Comment)
        return w
    }

    func Text_splitText(_ n: HTMLNode, _ off: Int) throws(JSThrow) -> HTMLNode? {
        let u = units(n)
        if off > u.count { throw throwDOM("IndexSizeError", "The offset is greater than the length.") }
        let doc = n.nodeDocument ?? document
        let newNode = doc.createTextNode(String(decoding: u[off...], as: UTF16.self))
        if let p = n.parent { _ = try Node_insertBefore(p, newNode, n.nextSibling) }
        setUnits(n, Array(u[..<off]))
        return newNode
    }

    func Text_wholeText(_ n: HTMLNode) -> String {
        guard let p = n.parent else { return n.text }
        var start = n.index, end = n.index
        while start > 0 && p.children[start - 1].kind == .text { start -= 1 }
        while end + 1 < p.children.count && p.children[end + 1].kind == .text { end += 1 }
        var bytes: [UInt8] = []
        var i = start
        while i <= end && i < p.children.count { bytes.append(contentsOf: p.children[i].data); i += 1 }
        return String(decoding: bytes, as: UTF8.self)
    }
}
