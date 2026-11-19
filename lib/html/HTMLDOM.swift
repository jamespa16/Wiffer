// Checked DOM mutation (ROADMAP Phase 9G): node creation, appendChild /
// insertBefore / removeChild / replaceChild with the DOM standard's
// pre-insertion validity and hierarchy checks, cloneNode, attributes,
// character data, and the innerHTML / outerHTML / insertAdjacentHTML
// entry points (fragment parsing is in HTMLParse.swift, serialization in
// HTMLSerialize.swift). Every change notifies the document's mutation
// observers (HTMLMutation.swift) and keeps `parent`, `children` and `index`
// consistent. Nothing here recurses: subtree walks use explicit stacks.

/// DOMException names, for the JS bindings to map 1:1.
public enum HTMLDOMError: Error {
    case hierarchyRequest       // HierarchyRequestError
    case notFound               // NotFoundError
    case invalidCharacter       // InvalidCharacterError
    case syntax                 // SyntaxError
    case noModificationAllowed  // NoModificationAllowedError
    case notSupported           // NotSupportedError

    public var name: String {
        switch self {
        case .hierarchyRequest: return "HierarchyRequestError"
        case .notFound: return "NotFoundError"
        case .invalidCharacter: return "InvalidCharacterError"
        case .syntax: return "SyntaxError"
        case .noModificationAllowed: return "NoModificationAllowedError"
        case .notSupported: return "NotSupportedError"
        }
    }
}

/// A new, empty HTML document (no doctype, no html element).
public func htmlNewDocument() -> HTMLNode { HTMLNode(kind: .document) }

extension HTMLNode {
    // -------------------------------------------------------------- kinds

    public var isDocumentFragment: Bool { kind == .documentFragment }
    public var isComment: Bool { kind == .comment }
    /// Text or comment.
    public var isCharacterData: Bool { kind == .text || kind == .comment }

    /// HTML `<template>` only: its contents, a DocumentFragment owned by the
    /// template contents owner document (created on first use). nil for
    /// every other node.
    public var templateContents: HTMLNode? {
        guard kind == .element && namespace == .html && tag == .template else { return nil }
        if let t = templateStorage { return t }
        let owner = (nodeDocument ?? self).templateContentsOwner
        let f = HTMLNode(kind: .documentFragment)
        owner.registerNode(f)
        f.templateHost = self
        templateStorage = f
        return f
    }

    /// For a template contents fragment: the template element (the DOM's
    /// "host" for host-including ancestry). nil otherwise.
    public var templateElement: HTMLNode? { templateHost }

    /// True if the node is in a document tree (its root is a document).
    public var isConnected: Bool { rootNode.kind == .document }

    /// The root of the node's tree (does not cross a template boundary).
    public var rootNode: HTMLNode {
        var n = self
        while let p = n.parent { n = p }
        return n
    }

    /// Inclusive descendant test (DOM `contains`).
    public func contains(_ other: HTMLNode?) -> Bool {
        var n = other
        while let x = n { if x === self { return true }; n = x.parent }
        return false
    }

    /// Host-including inclusive ancestor (crosses from a template's contents
    /// to its template element).
    func isHostIncludingInclusiveAncestor(of other: HTMLNode) -> Bool {
        var n: HTMLNode? = other
        while let x = n {
            if x === self { return true }
            n = x.parent ?? (x.kind == .documentFragment ? x.templateHost : nil)
        }
        return false
    }

    // ------------------------------------------------------------ creation
    // Called on a document (any node works: its document is used).

    var documentForCreation: HTMLNode { nodeDocument ?? self }

    /// `document.createElement`: validates the name and lowercases it (every
    /// document here is an HTML document).
    public func createElement(_ localName: String) throws(HTMLDOMError) -> HTMLNode {
        guard htmlIsValidElementName(localName) else { throw .invalidCharacter }
        return makeElement(htmlLowerASCII(localName), .html)
    }

    /// `document.createElementNS` for the three namespaces the parser knows
    /// (names are kept as given: "foreignObject", "viewBox").
    public func createElementNS(_ ns: HTMLNamespace, _ localName: String) throws(HTMLDOMError) -> HTMLNode {
        guard htmlIsValidElementName(localName) else { throw .invalidCharacter }
        return makeElement(localName, ns)
    }

    /// Unchecked element creation (name already valid and cased).
    func makeElement(_ name: String, _ ns: HTMLNamespace, attributes: [HTMLAttribute] = []) -> HTMLNode {
        let n = HTMLNode(kind: .element, name: name, tag: ns == .html ? HTMLTag.lookup(name) : .unknown,
                         namespace: ns, attributes: attributes)
        documentForCreation.registerNode(n)
        return n
    }

    public func createTextNode(_ text: String) -> HTMLNode {
        let n = HTMLNode(kind: .text, data: Array(text.utf8))
        documentForCreation.registerNode(n)
        return n
    }

    public func createComment(_ text: String) -> HTMLNode {
        let n = HTMLNode(kind: .comment, data: Array(text.utf8))
        documentForCreation.registerNode(n)
        return n
    }

    public func createDocumentFragment() -> HTMLNode {
        let n = HTMLNode(kind: .documentFragment)
        documentForCreation.registerNode(n)
        return n
    }

    /// `document.importNode`: a clone owned by this document.
    public func importNode(_ node: HTMLNode, deep: Bool = false) throws(HTMLDOMError) -> HTMLNode {
        if node.kind == .document { throw .notSupported }
        return node.cloneNode(deep: deep, into: documentForCreation)
    }

    /// `document.adoptNode`: remove from its parent and move into this
    /// document.
    @discardableResult
    public func adoptNode(_ node: HTMLNode) throws(HTMLDOMError) -> HTMLNode {
        if node.kind == .document { throw .notSupported }
        if node.kind == .documentFragment && node.templateHost != nil { return node }
        if let p = node.parent { p.removeNode(node, suppress: false) }
        documentForCreation.adoptSubtree(node)
        return node
    }

    /// Move `root` and its subtree (template contents go to the template
    /// contents owner document) into this document's arena. No-op unless
    /// self is a document.
    func adoptSubtree(_ root: HTMLNode) {
        guard docState != nil else { return }
        var stack: [(HTMLNode, HTMLNode)] = [(root, self)]
        while let (n, d) = stack.popLast() {
            // A subtree shares its root's document (template contents
            // aside), so a node already there needs no walk.
            if n.nodeDocument === d { continue }
            d.takeNode(n)
            for c in n.children { stack.append((c, d)) }
            if let t = n.templateStorage { stack.append((t, d.templateContentsOwner)) }
        }
    }

    // ---------------------------------------------------------- cloneNode

    /// `cloneNode(deep)`. A deep clone of a template also clones its
    /// contents. Cloning a document makes a new document.
    public func cloneNode(deep: Bool = false) -> HTMLNode {
        cloneNode(deep: deep, into: kind == .document ? nil : documentForCreation)
    }

    /// Clone into `doc` (nil: self is a document; make a new one).
    func cloneNode(deep: Bool, into doc: HTMLNode?) -> HTMLNode {
        let root = cloneOne(into: doc)
        guard deep else { return root }
        var stack: [(HTMLNode, HTMLNode)] = [(self, root)]
        while let (src, dst) = stack.popLast() {
            let dd = dst.nodeDocument ?? dst
            for c in src.children {
                let cc = c.cloneOne(into: dd)
                cc.parent = dst
                cc.index = dst.children.count
                dst.children.append(cc)
                if !c.children.isEmpty || c.templateStorage != nil { stack.append((c, cc)) }
            }
            if let t = src.templateStorage, !t.children.isEmpty, let tc = dst.templateContents {
                stack.append((t, tc))
            }
        }
        return root
    }

    /// Copy of this node alone (no children), owned by `doc`.
    func cloneOne(into doc: HTMLNode?) -> HTMLNode {
        let n = HTMLNode(kind: kind, name: name, tag: tag, namespace: namespace, attributes: attributes, data: data)
        n.publicID = publicID
        n.systemID = systemID
        if kind == .document {
            n.docState?.quirks = docState?.quirks ?? false
        } else {
            (doc ?? documentForCreation).registerNode(n)
        }
        return n
    }

    // --------------------------------------------------------- tree mutation

    /// `appendChild`: returns the node.
    @discardableResult
    public func appendChild(_ node: HTMLNode) throws(HTMLDOMError) -> HTMLNode {
        try insertBefore(node, nil)
    }

    /// `insertBefore(node, child)`: child nil appends. Inserting a
    /// DocumentFragment moves its children. Returns the node.
    @discardableResult
    public func insertBefore(_ node: HTMLNode, _ child: HTMLNode?) throws(HTMLDOMError) -> HTMLNode {
        try ensurePreInsertionValidity(node, child)
        var ref = child
        if let r = ref, r === node { ref = node.nextSibling }
        insertNode(node, before: ref, suppress: false)
        return node
    }

    /// `removeChild`: returns the child.
    @discardableResult
    public func removeChild(_ child: HTMLNode) throws(HTMLDOMError) -> HTMLNode {
        guard child.parent === self else { throw .notFound }
        removeNode(child, suppress: false)
        return child
    }

    /// `replaceChild(node, child)`: returns the replaced child.
    @discardableResult
    public func replaceChild(_ node: HTMLNode, _ child: HTMLNode) throws(HTMLDOMError) -> HTMLNode {
        guard kind == .document || kind == .documentFragment || kind == .element else { throw .hierarchyRequest }
        if node.isHostIncludingInclusiveAncestor(of: self) { throw .hierarchyRequest }
        guard child.parent === self else { throw .notFound }
        try checkInsertableKind(node)
        if kind == .document { try checkDocumentChildren(node, child, replacing: true) }
        var ref = child.nextSibling
        if let r = ref, r === node { ref = node.nextSibling }
        var previous = child.previousSibling
        if let p = previous, p === node { previous = node.previousSibling }
        let added = node.kind == .documentFragment ? node.children : [node]
        var removed: [HTMLNode] = []
        if child.parent != nil && child !== node {
            removed = [child]
            removeNode(child, suppress: true)
        }
        insertNode(node, before: ref, suppress: true)
        if observed && (!added.isEmpty || !removed.isEmpty) {
            notify(HTMLMutation(kind: .childList, target: self, addedNodes: added, removedNodes: removed,
                                previousSibling: previous, nextSibling: ref))
        }
        return child
    }

    /// `ChildNode.remove()`: detach from the parent, if any.
    public func remove() {
        if let p = parent { p.removeNode(self, suppress: false) }
    }

    /// `replaceChildren()` / the DOM's "replace all": remove every child,
    /// then insert `node` (a fragment's children, or one node, or nothing).
    /// One mutation record.
    public func replaceAll(with node: HTMLNode?) throws(HTMLDOMError) {
        if let n = node { try ensurePreInsertionValidity(n, nil, replacingAll: true) }
        replaceAllUnchecked(node)
    }

    func replaceAllUnchecked(_ node: HTMLNode?) {
        let removed = children
        var added: [HTMLNode] = []
        if let n = node { added = n.kind == .documentFragment ? n.children : [n] }
        if let n = node, n.kind != .documentFragment, let p = n.parent { p.removeNode(n, suppress: false) }
        for c in removed { c.parent = nil; c.index = 0 }
        children = []
        if let n = node { insertNode(n, before: nil, suppress: true) }
        if observed && (!added.isEmpty || !removed.isEmpty) {
            notify(HTMLMutation(kind: .childList, target: self, addedNodes: added, removedNodes: removed))
        }
    }

    // -------------------------------------------------------------- checks

    /// The DOM's "ensure pre-insertion validity" of `node` into self before
    /// `child`.
    func ensurePreInsertionValidity(_ node: HTMLNode, _ child: HTMLNode?, replacingAll: Bool = false) throws(HTMLDOMError) {
        guard kind == .document || kind == .documentFragment || kind == .element else { throw .hierarchyRequest }
        if node.isHostIncludingInclusiveAncestor(of: self) { throw .hierarchyRequest }
        if let c = child, c.parent !== self { throw .notFound }
        try checkInsertableKind(node)
        if kind == .document {
            if replacingAll {
                // Replace all: the document's current children go away.
                try htmlCheckDocumentFragment(node)
            } else {
                try checkDocumentChildren(node, child, replacing: false)
            }
        }
    }

    /// Steps 4–5: what may be inserted where.
    func checkInsertableKind(_ node: HTMLNode) throws(HTMLDOMError) {
        switch node.kind {
        case .document: throw .hierarchyRequest
        case .text: if kind == .document { throw .hierarchyRequest }
        case .doctype: if kind != .document { throw .hierarchyRequest }
        case .element, .comment, .documentFragment: break
        }
    }

    /// Step 6 for a document parent: at most one element and one doctype,
    /// doctype before the element, no text. `replacing`: `child` is being
    /// replaced (it doesn't count).
    func checkDocumentChildren(_ node: HTMLNode, _ child: HTMLNode?, replacing: Bool) throws(HTMLDOMError) {
        var elementCount = 0, doctypeCount = 0
        for c in children where !(replacing && c === child) {
            if c.kind == .element { elementCount += 1 }
            if c.kind == .doctype { doctypeCount += 1 }
        }
        func doctypeFollowing(_ c: HTMLNode) -> Bool {
            var i = c.index + 1
            while i < children.count { if children[i].kind == .doctype { return true }; i += 1 }
            return false
        }
        func elementPreceding(_ c: HTMLNode) -> Bool {
            var i = min(c.index, children.count) - 1
            while i >= 0 { if children[i].kind == .element && children[i] !== c { return true }; i -= 1 }
            return false
        }
        switch node.kind {
        case .documentFragment:
            var e = 0
            for c in node.children {
                if c.kind == .element { e += 1 }
                if c.kind == .text { throw .hierarchyRequest }
            }
            if e > 1 { throw .hierarchyRequest }
            if e == 1 {
                if elementCount > 0 { throw .hierarchyRequest }
                if let c = child {
                    if !replacing && c.kind == .doctype { throw .hierarchyRequest }
                    if doctypeFollowing(c) { throw .hierarchyRequest }
                }
            }
        case .element:
            if elementCount > 0 { throw .hierarchyRequest }
            if let c = child {
                if !replacing && c.kind == .doctype { throw .hierarchyRequest }
                if doctypeFollowing(c) { throw .hierarchyRequest }
            }
        case .doctype:
            if doctypeCount > 0 { throw .hierarchyRequest }
            if let c = child {
                if elementPreceding(c) { throw .hierarchyRequest }
            } else if elementCount > 0 { throw .hierarchyRequest }
        default: break
        }
    }

    // ------------------------------------------------------ primitive steps

    /// Insert `node` (or a fragment's children) before `ref` (a child of
    /// self, or nil to append). Validity already checked.
    func insertNode(_ node: HTMLNode, before ref: HTMLNode?, suppress: Bool) {
        var nodes: [HTMLNode]
        if node.kind == .documentFragment {
            nodes = node.children
            if nodes.isEmpty { return }
            for c in nodes { c.parent = nil; c.index = 0 }
            node.children = []
            if node.observed {
                node.notify(HTMLMutation(kind: .childList, target: node, removedNodes: nodes))
            }
        } else {
            if let p = node.parent { p.removeNode(node, suppress: false) }
            nodes = [node]
        }
        if let d = nodeDocument { for n in nodes { d.adoptSubtree(n) } }
        var at = children.count
        if let r = ref, r.parent === self {
            if r.index < children.count && children[r.index] === r { at = r.index }
            else if let i = childIndex(r) { at = i }
        }
        for n in nodes { n.parent = self }
        children.insert(contentsOf: nodes, at: at)
        reindex(from: at)
        if !suppress && observed {
            let prev: HTMLNode? = at > 0 ? children[at - 1] : nil
            let endIdx = at + nodes.count
            let next: HTMLNode? = endIdx < children.count ? children[endIdx] : nil
            notify(HTMLMutation(kind: .childList, target: self, addedNodes: nodes,
                                previousSibling: prev, nextSibling: next))
        }
    }

    /// Remove a child of self.
    func removeNode(_ child: HTMLNode, suppress: Bool) {
        var i = child.index
        if !(i >= 0 && i < children.count && children[i] === child) {
            guard let j = childIndex(child) else { return }
            i = j
        }
        let prev: HTMLNode? = i > 0 ? children[i - 1] : nil
        let next: HTMLNode? = i + 1 < children.count ? children[i + 1] : nil
        children.remove(at: i)
        child.parent = nil
        child.index = 0
        reindex(from: i)
        if !suppress && observed {
            notify(HTMLMutation(kind: .childList, target: self, removedNodes: [child],
                                previousSibling: prev, nextSibling: next))
        }
    }

    func reindex(from start: Int) {
        var i = max(0, start)
        while i < children.count { children[i].index = i; i += 1 }
    }

    // ---------------------------------------------------------- attributes

    /// `getAttribute`: the name is lowercased for HTML elements.
    public func getAttribute(_ name: String) -> String? {
        attribute(namespace == .html ? htmlLowerASCII(name) : name)
    }

    /// `setAttribute`. Throws InvalidCharacterError for a bad name. The name
    /// is lowercased for HTML elements. No-op on non-elements.
    public func setAttribute(_ name: String, _ value: String) throws(HTMLDOMError) {
        guard htmlIsValidAttributeName(name) else { throw .invalidCharacter }
        guard kind == .element else { return }
        setAttributeValue(namespace == .html ? htmlLowerASCII(name) : name, value)
    }

    /// Set an attribute whose name is already valid and cased.
    func setAttributeValue(_ name: String, _ value: String) {
        var old: String? = nil
        var found = false
        var i = 0
        while i < attributes.count {
            if attributes[i].name == name {
                old = attributes[i].value
                attributes[i].value = value
                found = true
                break
            }
            i += 1
        }
        if !found { attributes.append(HTMLAttribute(name: name, value: value)) }
        if observed {
            notify(HTMLMutation(kind: .attributes, target: self, attributeName: name, oldValue: old))
        }
    }

    /// `removeAttribute` (lowercased for HTML elements). Returns whether it
    /// was there.
    @discardableResult
    public func removeAttribute(_ name: String) -> Bool {
        guard kind == .element else { return false }
        let n = namespace == .html ? htmlLowerASCII(name) : name
        var i = 0
        while i < attributes.count {
            if attributes[i].name == n {
                let old = attributes[i].value
                attributes.remove(at: i)
                if observed {
                    notify(HTMLMutation(kind: .attributes, target: self, attributeName: n, oldValue: old))
                }
                return true
            }
            i += 1
        }
        return false
    }

    /// `toggleAttribute(name, force)`: returns whether the attribute is
    /// present afterwards.
    @discardableResult
    public func toggleAttribute(_ name: String, force: Bool? = nil) throws(HTMLDOMError) -> Bool {
        guard htmlIsValidAttributeName(name) else { throw .invalidCharacter }
        guard kind == .element else { return false }
        let n = namespace == .html ? htmlLowerASCII(name) : name
        if hasAttribute(n) {
            if force == true { return true }
            removeAttribute(n)
            return false
        }
        if force == false { return false }
        setAttributeValue(n, "")
        return true
    }

    // ------------------------------------------------------ character data

    /// Replace a text or comment node's data. No-op on other kinds.
    public func setData(_ text: String) {
        setDataBytes(Array(text.utf8))
    }

    public func setDataBytes(_ bytes: [UInt8]) {
        guard kind == .text || kind == .comment else { return }
        let old: String? = observed ? self.text : nil
        data = bytes
        if observed { notify(HTMLMutation(kind: .characterData, target: self, oldValue: old)) }
    }

    public func appendData(_ text: String) {
        guard kind == .text || kind == .comment else { return }
        let old: String? = observed ? self.text : nil
        data.append(contentsOf: text.utf8)
        if observed { notify(HTMLMutation(kind: .characterData, target: self, oldValue: old)) }
    }

    /// The `textContent` setter: elements and fragments get their children
    /// replaced by one text node (none for ""); text and comments get new
    /// data; documents and doctypes are unchanged.
    public func setTextContent(_ text: String) {
        switch kind {
        case .element, .documentFragment:
            replaceAllUnchecked(text.isEmpty ? nil : createTextNode(text))
        case .text, .comment:
            setData(text)
        case .document, .doctype:
            break
        }
    }

    // ------------------------------------------------------ markup entry points

    /// `innerHTML` getter (the HTML fragment serializing algorithm; a
    /// template serializes its contents).
    public var innerHTML: String { htmlSerializeChildren(self) }

    /// `outerHTML` getter.
    public var outerHTML: String { htmlSerialize(self) }

    /// `innerHTML` setter: fragment-parse with self as the context, then
    /// replace all children (a template's contents for a template).
    /// Elements only (and fragments, which parse as if in `<body>`).
    public func setInnerHTML(_ markup: String, limits: HTMLParseLimits = HTMLParseLimits()) {
        guard kind == .element || kind == .documentFragment else { return }
        let context = kind == .element ? self : makeElement("body", .html)
        let frag = htmlParseFragment(Array(markup.utf8), context: context, limits: limits)
        (templateContents ?? self).replaceAllUnchecked(frag)
    }

    /// `outerHTML` setter: replace self with the parsed markup (context: the
    /// parent; `<body>` if the parent is a fragment). NoModificationAllowed
    /// if the parent is the document; no-op without a parent.
    public func setOuterHTML(_ markup: String, limits: HTMLParseLimits = HTMLParseLimits()) throws(HTMLDOMError) {
        guard kind == .element, let p = parent else { return }
        if p.kind == .document { throw .noModificationAllowed }
        let context = p.kind == .documentFragment ? makeElement("body", .html) : p
        let frag = htmlParseFragment(Array(markup.utf8), context: context, limits: limits)
        try p.replaceChild(frag, self)
    }

    /// `insertAdjacentHTML(position, markup)`: position is beforebegin,
    /// afterbegin, beforeend or afterend (ASCII case-insensitive), else
    /// SyntaxError.
    public func insertAdjacentHTML(_ position: String, _ markup: String,
                                   limits: HTMLParseLimits = HTMLParseLimits()) throws(HTMLDOMError) {
        let pos = htmlLowerASCII(position)
        var context: HTMLNode
        switch pos {
        case "beforebegin", "afterend":
            guard let p = parent, p.kind != .document else { throw .noModificationAllowed }
            context = p
        case "afterbegin", "beforeend":
            context = self
        default:
            throw .syntax
        }
        if context.kind != .element || (context.namespace == .html && context.tag == .html) {
            context = makeElement("body", .html)
        }
        let frag = htmlParseFragment(Array(markup.utf8), context: context, limits: limits)
        switch pos {
        case "beforebegin": if let p = parent { try p.insertBefore(frag, self) }
        case "afterbegin": try insertBefore(frag, firstChild)
        case "beforeend": try appendChild(frag)
        default: if let p = parent { try p.insertBefore(frag, nextSibling) }
        }
    }
}

// ------------------------------------------------------------ name checks

/// The DOM's "valid element local name".
func htmlIsValidElementName(_ s: String) -> Bool {
    var it = s.utf8.makeIterator()
    guard let first = it.next() else { return false }
    let alpha = (first >= 0x41 && first <= 0x5a) || (first >= 0x61 && first <= 0x7a)
    if alpha {
        while let b = it.next() {
            if htmlIsSpaceByte(b) || b == 0 || b == 0x2f || b == 0x3e { return false }
        }
        return true
    }
    guard first == 0x3a || first == 0x5f || first >= 0x80 else { return false }
    while let b = it.next() {
        let ok = (b >= 0x41 && b <= 0x5a) || (b >= 0x61 && b <= 0x7a) || (b >= 0x30 && b <= 0x39)
            || b == 0x2d || b == 0x2e || b == 0x3a || b == 0x5f || b >= 0x80
        if !ok { return false }
    }
    return true
}

/// The DOM's "valid attribute local name".
func htmlIsValidAttributeName(_ s: String) -> Bool {
    if s.utf8.isEmpty { return false }
    for b in s.utf8 where htmlIsSpaceByte(b) || b == 0 || b == 0x2f || b == 0x3d || b == 0x3e { return false }
    return true
}

/// Document-children check used by replaceAll (no existing children).
func htmlCheckDocumentFragment(_ node: HTMLNode) throws(HTMLDOMError) {
    if node.kind == .documentFragment {
        var e = 0
        for c in node.children {
            if c.kind == .element { e += 1 }
            if c.kind == .text { throw .hierarchyRequest }
        }
        if e > 1 { throw .hierarchyRequest }
    }
}
