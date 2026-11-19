// The DOM produced by the HTML parser (ROADMAP Phase 8C) and changed by
// the checked mutation API in HTMLDOM.swift (Phase 9G).
//
// Ownership: a parent owns its children (`children` holds strong
// references); `parent` is unowned(unsafe) (Embedded Swift has no `weak`).
// Every node also belongs to a document (`nodeDocument`, unowned), and the
// document keeps every node created for it alive in an arena
// (`HTMLDocumentState.arena`) until the document itself goes away. So a
// detached node's old parent never dangles while its document lives. When
// the document is freed (or `teardown()` is called on it), every node it
// owns gets `parent = nil` and the trees are dismantled iteratively, so
// freeing a deep tree never recurses. A node still held elsewhere after
// that keeps working as the root of a detached subtree.

public enum HTMLNodeKind: UInt8 {
    case document, doctype, element, text, comment, documentFragment
}

public enum HTMLNamespace: UInt8 {
    case html, svg, mathml
}

public struct HTMLAttribute {
    /// Lowercase for HTML elements; SVG attributes use their camelCase form
    /// (viewBox); namespaced foreign attributes keep the prefix ("xlink:href").
    public var name: String
    public var value: String
    /// True for the attributes the parser treats as namespaced (xlink:href,
    /// xml:lang, xmlns:xlink, ...).
    public var isNamespaced: Bool

    public init(name: String, value: String, isNamespaced: Bool = false) {
        self.name = name
        self.value = value
        self.isNamespaced = isNamespaced
    }
}

/// Per-document state, allocated only for document nodes.
final class HTMLDocumentState {
    /// Every node owned by the document (slot = node.arenaIndex). Adopting a
    /// node into another document moves it to that document's arena.
    var arena: [HTMLNode?] = []
    var observers: [(id: Int, fn: (HTMLMutation) -> Void)] = []
    var nextObserverID = 1
    var quirks = false
    /// True for a template contents owner document.
    var inert = false
    /// The template contents owner document (created on first use).
    var templateDocument: HTMLNode? = nil
}

public final class HTMLNode {
    public let kind: HTMLNodeKind
    /// Elements: the tag name (lowercase for HTML; SVG names are camelCase,
    /// e.g. "foreignObject"). Doctype: the doctype name. Otherwise "".
    public internal(set) var name: String
    /// Known HTML element, or `.unknown` (also for every foreign element).
    let tag: HTMLTag
    public internal(set) var namespace: HTMLNamespace
    /// Change with setAttribute/removeAttribute (HTMLDOM.swift), so that
    /// mutation observers hear about it.
    public internal(set) var attributes: [HTMLAttribute]
    /// Text and comment content as UTF-8 (see `text`). Change with setData.
    public internal(set) var data: [UInt8]
    /// Doctype only.
    public internal(set) var publicID: String?
    public internal(set) var systemID: String?
    public internal(set) unowned(unsafe) var parent: HTMLNode?
    public internal(set) var children: [HTMLNode]
    /// Position in `parent.children`. Valid once the parse has finished (the
    /// parser fills it in a final pass), and kept valid by every mutation.
    public internal(set) var index: Int
    /// Document only: true if a parse limit (input bytes, node count) cut the
    /// parse short. Fragments from htmlParseFragment too.
    public internal(set) var truncated: Bool
    /// The document this node belongs to (itself for a document).
    unowned(unsafe) var nodeDocument: HTMLNode?
    /// Slot in nodeDocument's arena.
    var arenaIndex: Int
    /// Document only.
    var docState: HTMLDocumentState?
    /// HTML `<template>` only: its contents fragment (see templateContents).
    var templateStorage: HTMLNode?
    /// Template contents fragment only: the template element it belongs to.
    unowned(unsafe) var templateHost: HTMLNode?

    init(kind: HTMLNodeKind, name: String = "", tag: HTMLTag = .unknown,
         namespace: HTMLNamespace = .html, attributes: [HTMLAttribute] = [], data: [UInt8] = []) {
        self.kind = kind
        self.name = name
        self.tag = tag
        self.namespace = namespace
        self.attributes = attributes
        self.data = data
        self.publicID = nil
        self.systemID = nil
        self.parent = nil
        self.children = []
        self.index = 0
        self.truncated = false
        self.nodeDocument = nil
        self.arenaIndex = -1
        self.docState = nil
        self.templateStorage = nil
        self.templateHost = nil
        if kind == .document {
            docState = HTMLDocumentState()
            nodeDocument = self
        }
    }

    deinit {
        if docState != nil { dismantleArena() }
        if let t = templateStorage { t.templateHost = nil }
        if children.isEmpty { return }
        // Free the subtree iteratively: a child nobody else holds has its
        // children taken first, so the release never recurses (this matters
        // for nodes outside any arena, e.g. after their document went away).
        // Children that outlive this node must not point back at it.
        var stack = children
        children = []
        while var n = stack.popLast() {
            n.parent = nil
            if isKnownUniquelyReferenced(&n) && !n.children.isEmpty {
                stack.append(contentsOf: n.children)
                n.children = []
            }
        }
    }

    // ------------------------------------------------------------ documents

    /// The node's document; nil for a document (as in the DOM).
    public var ownerDocument: HTMLNode? { kind == .document ? nil : nodeDocument }

    /// Document only: quirks mode (from the doctype; fragment parses inherit
    /// it from the context's document).
    public var quirksMode: Bool { docState?.quirks ?? false }

    /// Documents only (0 otherwise): how many nodes the arena keeps alive.
    /// Detached nodes count until the document goes away.
    public var arenaNodeCount: Int {
        guard let st = docState else { return 0 }
        var n = 0
        for case .some in st.arena { n += 1 }
        return n
    }

    /// Put a freshly created node in this document's arena.
    func registerNode(_ n: HTMLNode) {
        guard let st = docState else { return }
        n.nodeDocument = self
        n.arenaIndex = st.arena.count
        st.arena.append(n)
    }

    /// Move one node (not its subtree) from its document's arena to this one.
    func takeNode(_ n: HTMLNode) {
        guard let st = docState else { return }
        let old = n.nodeDocument
        if old === self { return }
        let oldIndex = n.arenaIndex
        n.nodeDocument = self
        n.arenaIndex = st.arena.count
        st.arena.append(n)   // before the old slot lets go of it
        if let o = old, let ost = o.docState, oldIndex >= 0, oldIndex < ost.arena.count, ost.arena[oldIndex] === n {
            ost.arena[oldIndex] = nil
        }
    }

    /// The template contents owner document: an inert document that owns
    /// every `<template>`'s contents (an inert document is its own).
    var templateContentsOwner: HTMLNode {
        guard let st = docState else { return nodeDocument?.templateContentsOwner ?? self }
        if st.inert { return self }
        if let t = st.templateDocument { return t }
        let t = HTMLNode(kind: .document)
        t.docState?.inert = true
        t.docState?.quirks = st.quirks
        st.templateDocument = t
        return t
    }

    /// Release every node this document owns without recursion: a node that
    /// nobody but the arena holds has its children taken away first, so its
    /// release never cascades down a deep tree. Nodes held elsewhere survive
    /// with no document (nodeDocument nil) and no parent if theirs went away.
    func dismantleArena() {
        guard let st = docState else { return }
        var arena = st.arena
        st.arena = []
        // Nodes that outlive the document are left without one.
        for case let n? in arena { n.nodeDocument = nil }
        for c in children { c.parent = nil }
        children = []
        var kids: [HTMLNode] = []
        var pending: [Int] = []
        var i = 0
        while i < arena.count {
            pending.append(i)
            while let k = pending.popLast() {
                if k < 0 || k >= arena.count || arena[k] == nil { continue }
                if !isKnownUniquelyReferenced(&arena[k]) { continue }
                guard let n = arena[k] else { continue }
                arena[k] = nil
                kids = n.children
                n.children = []
                if let t = n.templateStorage { t.templateHost = nil; n.templateStorage = nil }
                for c in kids {
                    c.parent = nil
                    let ci = c.arenaIndex
                    if ci >= 0 && ci < arena.count && arena[ci] === c { pending.append(ci) }
                }
                kids.removeAll()
            }
            i += 1
        }
        arena.removeAll()
    }

    // ---------------------------------------------------------------- kinds

    public var isElement: Bool { kind == .element }
    public var isText: Bool { kind == .text }
    public var isHTMLElement: Bool { kind == .element && namespace == .html }

    /// Text or comment content as a String.
    public var text: String { String(decoding: data, as: UTF8.self) }

    // ---------------------------------------------------------- navigation

    public var firstChild: HTMLNode? { children.first }
    public var lastChild: HTMLNode? { children.last }
    /// O(1) after the parse (uses `index`).
    public var nextSibling: HTMLNode? {
        guard let p = parent, index + 1 < p.children.count else { return nil }
        return p.children[index + 1]
    }
    public var previousSibling: HTMLNode? {
        guard let p = parent, index > 0, index - 1 < p.children.count else { return nil }
        return p.children[index - 1]
    }
    /// The parent, if it is an element (not the document).
    public var parentElement: HTMLNode? {
        guard let p = parent, p.kind == .element else { return nil }
        return p
    }

    // ---------------------------------------------------------- attributes

    /// Value of the attribute with this exact (lowercase) name.
    public func attribute(_ name: String) -> String? {
        for a in attributes where a.name == name { return a.value }
        return nil
    }
    public func hasAttribute(_ name: String) -> Bool { attribute(name) != nil }
    public var id: String? { attribute("id") }

    /// Whitespace-separated class tokens (not cached; compute once per node).
    public var classNames: [String] {
        guard let c = attribute("class") else { return [] }
        return htmlSplitWhitespace(c)
    }
    public func hasClass(_ cls: String) -> Bool {
        guard let c = attribute("class") else { return false }
        var found = false
        htmlForEachToken(c) { if $0 == cls { found = true } }
        return found
    }

    // ------------------------------------------------------------- queries

    /// Pre-order walk of this node and all descendants (explicit stack, safe
    /// for any depth). The body returns false to stop the walk early.
    public func walk(_ body: (HTMLNode) -> Bool) {
        var stack: [HTMLNode] = [self]
        while let n = stack.popLast() {
            if !body(n) { return }
            var i = n.children.count - 1
            while i >= 0 { stack.append(n.children[i]); i -= 1 }
        }
    }

    /// First descendant element (or self) matching `pred`, in document order.
    public func firstElement(where pred: (HTMLNode) -> Bool) -> HTMLNode? {
        var result: HTMLNode? = nil
        walk { n in
            if n.kind == .element && pred(n) { result = n; return false }
            return true
        }
        return result
    }

    /// All descendant elements (not self) matching `pred`, in document order.
    public func elements(where pred: (HTMLNode) -> Bool) -> [HTMLNode] {
        var out: [HTMLNode] = []
        walk { n in
            if n !== self && n.kind == .element && pred(n) { out.append(n) }
            return true
        }
        return out
    }

    public func getElementById(_ id: String) -> HTMLNode? {
        firstElement { $0.attribute("id") == id }
    }
    /// `tag` is matched against the tag name, lowercase for HTML ("div").
    /// "*" matches every element.
    public func getElementsByTagName(_ tag: String) -> [HTMLNode] {
        elements { tag == "*" || $0.name == tag }
    }
    public func getElementsByClassName(_ cls: String) -> [HTMLNode] {
        elements { $0.hasClass(cls) }
    }
    /// The root `<html>` element of a document.
    public var documentElement: HTMLNode? {
        for c in children where c.kind == .element { return c }
        return nil
    }
    public var head: HTMLNode? { documentElement?.firstChildElement(named: "head") }
    public var body: HTMLNode? { documentElement?.firstChildElement(named: "body") }

    public func firstChildElement(named n: String) -> HTMLNode? {
        for c in children where c.kind == .element && c.name == n { return c }
        return nil
    }

    /// Concatenated text of all descendant text nodes.
    public var textContent: String {
        var bytes: [UInt8] = []
        walk { n in
            if n.kind == .text { bytes.append(contentsOf: n.data) }
            return true
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // ------------------------------------------------------------ teardown

    /// Free the whole subtree now, without recursion. The node is left empty.
    /// On a document this also releases every node in its arena (see the
    /// ownership note at the top of the file).
    public func teardown() {
        if docState != nil { dismantleArena(); docState?.templateDocument?.teardown(); return }
        var stack: [HTMLNode] = [self]
        while let n = stack.popLast() {
            for c in n.children { c.parent = nil; stack.append(c) }
            n.children = []
        }
    }

    // ------------------------------------------------- builder-only mutation
    // Unchecked, no notifications, and `index` is not maintained (the parser
    // runs assignIndices at the end). Moving a node under a parent in another
    // document (a template's contents) adopts it.

    func parserAppend(_ c: HTMLNode) {
        if c.nodeDocument !== nodeDocument, let d = nodeDocument { d.adoptSubtree(c) }
        c.parent = self
        c.index = children.count
        children.append(c)
    }
    func parserInsert(_ c: HTMLNode, before ref: HTMLNode?) {
        guard let ref = ref, let i = childIndex(ref) else { parserAppend(c); return }
        if c.nodeDocument !== nodeDocument, let d = nodeDocument { d.adoptSubtree(c) }
        c.parent = self
        children.insert(c, at: i)
    }
    func childIndex(_ c: HTMLNode) -> Int? {
        var i = children.count - 1
        while i >= 0 { if children[i] === c { return i }; i -= 1 }
        return nil
    }
    func parserDetach() {
        guard let p = parent else { return }
        if let i = p.childIndex(self) { p.children.remove(at: i) }
        parent = nil
    }

    /// Fill in `index` for every node under this one (template contents
    /// included).
    func assignIndices() {
        var stack: [HTMLNode] = [self]
        while let n = stack.popLast() {
            var i = 0
            for c in n.children {
                c.index = i
                i += 1
                if !c.children.isEmpty || c.templateStorage != nil { stack.append(c) }
            }
            if let t = n.templateStorage { stack.append(t) }
        }
    }
}

func htmlIsSpaceByte(_ b: UInt8) -> Bool {
    b == 0x20 || b == 0x09 || b == 0x0a || b == 0x0c || b == 0x0d
}

func htmlForEachToken(_ s: String, _ body: (String) -> Void) {
    var cur: [UInt8] = []
    for b in s.utf8 {
        if htmlIsSpaceByte(b) {
            if !cur.isEmpty { body(String(decoding: cur, as: UTF8.self)); cur.removeAll(keepingCapacity: true) }
        } else { cur.append(b) }
    }
    if !cur.isEmpty { body(String(decoding: cur, as: UTF8.self)) }
}

func htmlSplitWhitespace(_ s: String) -> [String] {
    var out: [String] = []
    htmlForEachToken(s) { out.append($0) }
    return out
}
