// The DOM produced by the HTML parser (ROADMAP Phase 8C).
//
// Ownership: a parent owns its children (`children` holds strong
// references); `parent` is unowned(unsafe) (Embedded Swift has no `weak`).
// So a document frees itself and everything under it when the last
// reference to the document goes away, and no reference cycles exist. The
// one rule: do not keep a node and use its `parent` after dropping the
// document it came from. The parser caps tree depth, so recursive
// deallocation cannot overflow the stack; `teardown()` frees a tree
// iteratively if you want it gone at a precise moment.

public enum HTMLNodeKind: UInt8 {
    case document, doctype, element, text, comment
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

public final class HTMLNode {
    public let kind: HTMLNodeKind
    /// Elements: the tag name (lowercase for HTML; SVG names are camelCase,
    /// e.g. "foreignObject"). Doctype: the doctype name. Otherwise "".
    public internal(set) var name: String
    /// Known HTML element, or `.unknown` (also for every foreign element).
    let tag: HTMLTag
    public internal(set) var namespace: HTMLNamespace
    public internal(set) var attributes: [HTMLAttribute]
    /// Text and comment content as UTF-8 (see `text`).
    public internal(set) var data: [UInt8]
    /// Doctype only.
    public internal(set) var publicID: String?
    public internal(set) var systemID: String?
    public internal(set) unowned(unsafe) var parent: HTMLNode?
    public internal(set) var children: [HTMLNode]
    /// Position in `parent.children`; valid once the parse has finished
    /// (the parser fills it in a final pass).
    public internal(set) var index: Int
    /// Document only: true if a parse limit (input bytes, node count) cut the
    /// parse short.
    public internal(set) var truncated: Bool

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
    public func teardown() {
        var stack: [HTMLNode] = [self]
        while let n = stack.popLast() {
            for c in n.children { c.parent = nil; stack.append(c) }
            n.children = []
        }
    }

    // ------------------------------------------------- builder-only mutation

    func appendChild(_ c: HTMLNode) {
        c.parent = self
        c.index = children.count
        children.append(c)
    }
    func insertChild(_ c: HTMLNode, before ref: HTMLNode?) {
        guard let ref = ref, let i = childIndex(ref) else { appendChild(c); return }
        c.parent = self
        children.insert(c, at: i)
    }
    func childIndex(_ c: HTMLNode) -> Int? {
        var i = children.count - 1
        while i >= 0 { if children[i] === c { return i }; i -= 1 }
        return nil
    }
    func detach() {
        guard let p = parent else { return }
        if let i = p.childIndex(self) { p.children.remove(at: i) }
        parent = nil
    }

    /// Fill in `index` for every node under this one.
    func assignIndices() {
        var stack: [HTMLNode] = [self]
        while let n = stack.popLast() {
            var i = 0
            for c in n.children { c.index = i; i += 1; if !c.children.isEmpty { stack.append(c) } }
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
