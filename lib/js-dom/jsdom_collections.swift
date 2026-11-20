// Live and static collections: NodeList, HTMLCollection, DOMTokenList,
// NamedNodeMap + Attr, DOMStringMap (dataset), DOMRectList. Indexed and
// named properties go through each class's JSHostExotic. Live collections
// recompute on access and cache their result until the page document
// changes (mutationVersion, bumped by the page's lib/html observer).

enum JSDOMCollectionKind {
    case childElements
    case tagName(String)            // qualified name ("*" = all)
    case tagNameNS(String?, String) // namespace ("*" = any), local name ("*" = any)
    case className([String])
    case name(String)
    case forms, images, links, anchors, scripts, embeds
    case formElements
    case fieldsetElements
    case selectOptions
    case selectedOptions
    case tableRows
    case tBodies
    case rowCells
}

final class JSDOMHTMLCollection {
    let root: HTMLNode
    let kind: JSDOMCollectionKind
    var cache: [HTMLNode] = []
    var cacheVersion = -1
    init(_ root: HTMLNode, _ kind: JSDOMCollectionKind) { self.root = root; self.kind = kind }
}

final class JSDOMNodeList {
    /// Live child list (childNodes) when set; else the static items or a
    /// live HTMLCollection-style query.
    let childrenOf: HTMLNode?
    var items: [HTMLNode]
    let live: JSDOMHTMLCollection?
    init(childrenOf n: HTMLNode) { childrenOf = n; items = []; live = nil }
    init(staticItems: [HTMLNode]) { childrenOf = nil; items = staticItems; live = nil }
    init(live: JSDOMHTMLCollection) { childrenOf = nil; items = []; self.live = live }
}

final class JSDOMTokenList {
    let node: HTMLNode
    let attribute: String
    init(_ n: HTMLNode, _ a: String) { node = n; attribute = a }
}

final class JSDOMNamedNodeMap {
    let node: HTMLNode
    init(_ n: HTMLNode) { node = n }
}

final class JSDOMStringMap {
    let node: HTMLNode
    init(_ n: HTMLNode) { node = n }
}

struct JSDOMAttrKey: Hashable {
    let node: ObjectIdentifier
    let name: String
}

final class JSDOMAttr {
    var owner: HTMLNode?
    let name: String
    var detachedValue: String
    let document: HTMLNode
    init(owner: HTMLNode?, name: String, value: String, document: HTMLNode) {
        self.owner = owner
        self.name = name
        self.detachedValue = value
        self.document = document
    }
    var value: String { owner?.attribute(name) ?? detachedValue }
}

final class JSDOMRect {
    var x: Double, y: Double, width: Double, height: Double
    init(_ x: Double, _ y: Double, _ w: Double, _ h: Double) { self.x = x; self.y = y; width = w; height = h }
}

final class JSDOMRectList {
    let rects: [JSDOMRect]
    init(_ r: [JSDOMRect]) { rects = r }
}

extension JSDOMBindings {
    // MARK: Collection evaluation

    func collectionItems(_ c: JSDOMHTMLCollection) -> [HTMLNode] {
        let cacheable = c.root.nodeDocument === document
        if cacheable && c.cacheVersion == mutationVersion { return c.cache }
        let r = computeCollection(c)
        if cacheable { c.cache = r; c.cacheVersion = mutationVersion }
        return r
    }

    func descendantsMatching(_ root: HTMLNode, _ pred: (HTMLNode) -> Bool) -> [HTMLNode] {
        var out: [HTMLNode] = []
        var stack: [HTMLNode] = []
        var i = root.children.count - 1
        while i >= 0 { stack.append(root.children[i]); i -= 1 }
        while let n = stack.popLast() {
            if n.kind == .element && pred(n) { out.append(n) }
            var j = n.children.count - 1
            while j >= 0 { stack.append(n.children[j]); j -= 1 }
        }
        return out
    }

    func computeCollection(_ c: JSDOMHTMLCollection) -> [HTMLNode] {
        let root = c.root
        switch c.kind {
        case .childElements:
            return root.children.filter { $0.kind == .element }
        case .tagName(let q):
            if q == "*" { return descendantsMatching(root) { _ in true } }
            let lower = htmlLowerASCII(q)
            return descendantsMatching(root) { n in
                n.namespace == .html ? n.name == lower : n.name == q
            }
        case .tagNameNS(let ns, let local):
            return descendantsMatching(root) { n in
                (local == "*" || n.name == local) && (ns == "*" || jsdomNamespaceURI(n) == ns)
            }
        case .className(let classes):
            if classes.isEmpty { return [] }
            let quirks = (root.nodeDocument ?? root).quirksMode
            return descendantsMatching(root) { n in
                guard let cls = n.attribute("class") else { return false }
                let have = htmlSplitWhitespace(cls)
                for k in classes {
                    if quirks {
                        let lk = htmlLowerASCII(k)
                        if !have.contains(where: { htmlLowerASCII($0) == lk }) { return false }
                    } else if !have.contains(k) { return false }
                }
                return true
            }
        case .name(let nm):
            return descendantsMatching(root) { $0.namespace == .html && $0.attribute("name") == nm }
        case .forms: return descendantsMatching(root) { $0.isHTML("form") }
        case .images: return descendantsMatching(root) { $0.isHTML("img") }
        case .embeds: return descendantsMatching(root) { $0.isHTML("embed") }
        case .scripts: return descendantsMatching(root) { $0.isHTML("script") }
        case .links: return descendantsMatching(root) { ($0.isHTML("a") || $0.isHTML("area")) && $0.attribute("href") != nil }
        case .anchors: return descendantsMatching(root) { $0.isHTML("a") && $0.attribute("name") != nil }
        case .formElements:
            // Listed elements whose form owner is this form.
            let tree = root.rootNode
            return descendantsMatching(tree) { n in
                jsdomIsListedElement(n) && self.formOwner(n) === root
            }
        case .fieldsetElements:
            return descendantsMatching(root) { jsdomIsListedElement($0) }
        case .selectOptions:
            return selectOptions(root)
        case .selectedOptions:
            return selectOptions(root).filter { self.optionSelected($0) }
        case .tableRows:
            if root.isHTML("table") {
                var out: [HTMLNode] = []
                var heads: [HTMLNode] = [], bodies: [HTMLNode] = [], feet: [HTMLNode] = []
                for ch in root.children where ch.kind == .element {
                    if ch.isHTML("tr") { bodies.append(ch) }
                    else if ch.isHTML("thead") { heads.append(contentsOf: ch.children.filter { $0.isHTML("tr") }) }
                    else if ch.isHTML("tbody") { bodies.append(contentsOf: ch.children.filter { $0.isHTML("tr") }) }
                    else if ch.isHTML("tfoot") { feet.append(contentsOf: ch.children.filter { $0.isHTML("tr") }) }
                }
                out.append(contentsOf: heads)
                out.append(contentsOf: bodies)
                out.append(contentsOf: feet)
                return out
            }
            return root.children.filter { $0.isHTML("tr") }
        case .tBodies:
            return root.children.filter { $0.isHTML("tbody") }
        case .rowCells:
            return root.children.filter { $0.isHTML("td") || $0.isHTML("th") }
        }
    }

    func makeCollection(_ root: HTMLNode, _ kind: JSDOMCollectionKind) -> JSValue {
        classes.HTMLCollection.wrap(JSDOMHTMLCollection(root, kind))
    }

    func staticNodeList(_ nodes: [HTMLNode]) -> JSValue {
        classes.NodeList.wrap(JSDOMNodeList(staticItems: nodes))
    }

    func nodeListItems(_ l: JSDOMNodeList) -> [HTMLNode] {
        if let p = l.childrenOf { return p.children }
        if let c = l.live { return collectionItems(c) }
        return l.items
    }

    // MARK: NodeList

    func exotic_NodeList() -> JSHostExotic<JSDOMNodeList> {
        var e = JSHostExotic<JSDOMNodeList>()
        e.length = { [unowned(unsafe) self] l in self.nodeListItems(l).count }
        e.indexedGet = { [unowned(unsafe) self] (realm: JSRealm, l: JSDOMNodeList, i: Int) throws(JSThrow) -> JSValue? in
            let items = self.nodeListItems(l)
            return i >= 0 && i < items.count ? self.wrapNode(items[i]) : nil
        }
        return e
    }

    func NodeList_item(_ l: JSDOMNodeList, _ i: Int) -> HTMLNode? {
        let items = nodeListItems(l)
        return i >= 0 && i < items.count ? items[i] : nil
    }
    func NodeList_length(_ l: JSDOMNodeList) -> Int { nodeListItems(l).count }

    // MARK: HTMLCollection

    func exotic_HTMLCollection() -> JSHostExotic<JSDOMHTMLCollection> {
        var e = JSHostExotic<JSDOMHTMLCollection>()
        e.length = { [unowned(unsafe) self] c in self.collectionItems(c).count }
        e.indexedGet = { [unowned(unsafe) self] (realm: JSRealm, c: JSDOMHTMLCollection, i: Int) throws(JSThrow) -> JSValue? in
            let items = self.collectionItems(c)
            return i >= 0 && i < items.count ? self.wrapNode(items[i]) : nil
        }
        e.namedGet = { [unowned(unsafe) self] (realm: JSRealm, c: JSDOMHTMLCollection, name: String) throws(JSThrow) -> JSValue? in
            if name.isEmpty { return nil }
            if let n = self.HTMLCollection_namedItem(c, name) { return self.wrapNode(n) }
            return nil
        }
        e.namedKeys = { [unowned(unsafe) self] c in
            var names: [String] = []
            for n in self.collectionItems(c) {
                if let id = n.attribute("id"), !id.isEmpty, !names.contains(id) { names.append(id) }
                if n.namespace == .html, let nm = n.attribute("name"), !nm.isEmpty, !names.contains(nm) { names.append(nm) }
            }
            return names
        }
        return e
    }

    func HTMLCollection_length(_ c: JSDOMHTMLCollection) -> Int { collectionItems(c).count }
    func HTMLCollection_item(_ c: JSDOMHTMLCollection, _ i: Int) -> HTMLNode? {
        let items = collectionItems(c)
        return i >= 0 && i < items.count ? items[i] : nil
    }
    func HTMLCollection_namedItem(_ c: JSDOMHTMLCollection, _ name: String) -> HTMLNode? {
        if name.isEmpty { return nil }
        let items = collectionItems(c)
        for n in items where n.attribute("id") == name { return n }
        for n in items where n.namespace == .html && n.attribute("name") == name { return n }
        return nil
    }

    // MARK: DOMTokenList

    func tokens(_ l: JSDOMTokenList) -> [String] {
        guard let v = l.node.attribute(l.attribute) else { return [] }
        var out: [String] = []
        for t in htmlSplitWhitespace(v) where !out.contains(t) { out.append(t) }
        return out
    }

    func setTokens(_ l: JSDOMTokenList, _ t: [String]) {
        if t.isEmpty && l.node.attribute(l.attribute) == nil { return }
        var s = ""
        for (i, x) in t.enumerated() { if i > 0 { s += " " }; s += x }
        l.node.setAttributeValue(l.attribute, s)
    }

    func checkToken(_ t: String) throws(JSThrow) {
        if t.isEmpty { throw throwDOM("SyntaxError", "The token provided must not be empty.") }
        for b in t.utf8 where htmlIsSpaceByte(b) {
            throw throwDOM("InvalidCharacterError", "The token provided contains HTML space characters.")
        }
    }

    func exotic_DOMTokenList() -> JSHostExotic<JSDOMTokenList> {
        var e = JSHostExotic<JSDOMTokenList>()
        e.length = { [unowned(unsafe) self] l in self.tokens(l).count }
        e.indexedGet = { [unowned(unsafe) self] (realm: JSRealm, l: JSDOMTokenList, i: Int) throws(JSThrow) -> JSValue? in
            let t = self.tokens(l)
            return i >= 0 && i < t.count ? self.str(t[i]) : nil
        }
        return e
    }

    func DOMTokenList_length(_ l: JSDOMTokenList) -> Int { tokens(l).count }
    func DOMTokenList_item(_ l: JSDOMTokenList, _ i: Int) -> String? {
        let t = tokens(l)
        return i >= 0 && i < t.count ? t[i] : nil
    }
    func DOMTokenList_contains(_ l: JSDOMTokenList, _ t: String) -> Bool { tokens(l).contains(t) }
    func DOMTokenList_add(_ l: JSDOMTokenList, _ ts: [String]) throws(JSThrow) {
        for t in ts { try checkToken(t) }
        var cur = tokens(l)
        for t in ts where !cur.contains(t) { cur.append(t) }
        setTokens(l, cur)
    }
    func DOMTokenList_remove(_ l: JSDOMTokenList, _ ts: [String]) throws(JSThrow) {
        for t in ts { try checkToken(t) }
        var cur = tokens(l)
        cur.removeAll { ts.contains($0) }
        setTokens(l, cur)
    }
    func DOMTokenList_toggle(_ l: JSDOMTokenList, _ t: String, _ force: Bool?) throws(JSThrow) -> Bool {
        try checkToken(t)
        var cur = tokens(l)
        if cur.contains(t) {
            if force == true { return true }
            cur.removeAll { $0 == t }
            setTokens(l, cur)
            return false
        }
        if force == false { return false }
        cur.append(t)
        setTokens(l, cur)
        return true
    }
    func DOMTokenList_replace(_ l: JSDOMTokenList, _ t: String, _ n: String) throws(JSThrow) -> Bool {
        try checkToken(t)
        try checkToken(n)
        var cur = tokens(l)
        guard let i = cur.firstIndex(of: t) else { return false }
        if cur.contains(n) {
            cur[i] = n
            var seen: [String] = []
            for x in cur where !seen.contains(x) { seen.append(x) }
            cur = seen
        } else {
            cur[i] = n
        }
        setTokens(l, cur)
        return true
    }
    func DOMTokenList_supports(_ l: JSDOMTokenList, _ t: String) throws(JSThrow) -> Bool {
        if l.attribute == "rel" {
            switch htmlLowerASCII(t) {
            case "stylesheet", "icon", "preload", "modulepreload", "prefetch", "dns-prefetch", "preconnect",
                 "noopener", "noreferrer", "opener", "alternate", "next", "prev", "search", "canonical", "manifest":
                return true
            default: return false
            }
        }
        throw realm.throwTypeError("DOMTokenList has no supported tokens.")
    }
    func DOMTokenList_value(_ l: JSDOMTokenList) -> String { l.node.attribute(l.attribute) ?? "" }
    func DOMTokenList_set_value(_ l: JSDOMTokenList, _ v: String) { l.node.setAttributeValue(l.attribute, v) }

    func tokenList(_ n: HTMLNode, _ attr: String) -> JSValue { classes.DOMTokenList.wrap(JSDOMTokenList(n, attr)) }

    // MARK: Attr and NamedNodeMap

    func attrObject(_ n: HTMLNode, _ name: String) -> JSValue {
        let k = JSDOMAttrKey(node: ObjectIdentifier(n), name: name)
        if let a = attrCache[k], a.owner === n { return classes.Attr.wrap(a) }
        let a = JSDOMAttr(owner: n, name: name, value: "", document: n.nodeDocument ?? document)
        attrCache[k] = a
        return classes.Attr.wrap(a)
    }

    /// An attribute is going away: its Attr (if any) keeps the last value.
    func detachAttr(_ n: HTMLNode, _ name: String) {
        let k = JSDOMAttrKey(node: ObjectIdentifier(n), name: name)
        if let a = attrCache[k] {
            a.detachedValue = n.attribute(name) ?? a.detachedValue
            a.owner = nil
            attrCache[k] = nil
        }
    }

    func qualifiedAttrName(_ n: HTMLNode, _ q: String) -> String { n.namespace == .html ? htmlLowerASCII(q) : q }

    func exotic_NamedNodeMap() -> JSHostExotic<JSDOMNamedNodeMap> {
        var e = JSHostExotic<JSDOMNamedNodeMap>()
        e.length = { m in m.node.attributes.count }
        e.indexedGet = { [unowned(unsafe) self] (realm: JSRealm, m: JSDOMNamedNodeMap, i: Int) throws(JSThrow) -> JSValue? in
            i >= 0 && i < m.node.attributes.count ? self.attrObject(m.node, m.node.attributes[i].name) : nil
        }
        e.namedGet = { [unowned(unsafe) self] (realm: JSRealm, m: JSDOMNamedNodeMap, name: String) throws(JSThrow) -> JSValue? in
            let q = self.qualifiedAttrName(m.node, name)
            return m.node.hasAttribute(q) ? self.attrObject(m.node, q) : nil
        }
        e.namedKeys = { m in
            var out: [String] = []
            for a in m.node.attributes {
                if m.node.namespace == .html && a.name != htmlLowerASCII(a.name) { continue }
                if !out.contains(a.name) { out.append(a.name) }
            }
            return out
        }
        return e
    }

    func NamedNodeMap_length(_ m: JSDOMNamedNodeMap) -> Int { m.node.attributes.count }
    func NamedNodeMap_item(_ m: JSDOMNamedNodeMap, _ i: Int) -> JSValue {
        i >= 0 && i < m.node.attributes.count ? attrObject(m.node, m.node.attributes[i].name) : .null
    }
    func NamedNodeMap_getNamedItem(_ m: JSDOMNamedNodeMap, _ q: String) -> JSValue {
        let n = qualifiedAttrName(m.node, q)
        return m.node.hasAttribute(n) ? attrObject(m.node, n) : .null
    }
    func NamedNodeMap_getNamedItemNS(_ m: JSDOMNamedNodeMap, _ ns: String?, _ local: String) -> JSValue {
        let name = jsdomAttributeName(ns, local, m.node)
        return name.map { m.node.hasAttribute($0) ? attrObject(m.node, $0) : .null } ?? .null
    }
    func NamedNodeMap_setNamedItem(_ m: JSDOMNamedNodeMap, _ a: JSDOMAttr) throws(JSThrow) -> JSValue {
        try setAttrNode(m.node, a)
    }
    func NamedNodeMap_setNamedItemNS(_ m: JSDOMNamedNodeMap, _ a: JSDOMAttr) throws(JSThrow) -> JSValue {
        try setAttrNode(m.node, a)
    }
    func NamedNodeMap_removeNamedItem(_ m: JSDOMNamedNodeMap, _ q: String) throws(JSThrow) -> JSValue {
        let n = qualifiedAttrName(m.node, q)
        guard m.node.hasAttribute(n) else { throw throwDOM("NotFoundError", "No item with name '" + q + "' was found.") }
        let a = attrObject(m.node, n)
        let d = heap.rootDepth
        _ = heap.root(a)
        detachAttr(m.node, n)
        m.node.removeAttribute(n)
        heap.popRoots(to: d)
        return a
    }
    func NamedNodeMap_removeNamedItemNS(_ m: JSDOMNamedNodeMap, _ ns: String?, _ local: String) throws(JSThrow) -> JSValue {
        guard let name = jsdomAttributeName(ns, local, m.node), m.node.hasAttribute(name) else {
            throw throwDOM("NotFoundError", "No item with that name was found.")
        }
        return try NamedNodeMap_removeNamedItem(m, name)
    }

    func setAttrNode(_ el: HTMLNode, _ a: JSDOMAttr) throws(JSThrow) -> JSValue {
        if let o = a.owner, o !== el { throw throwDOM("InUseAttributeError", "The attribute is in use by another element.") }
        if a.owner === el { return attrObject(el, a.name) }
        let old: JSValue = el.hasAttribute(a.name) ? attrObject(el, a.name) : .null
        let d = heap.rootDepth
        _ = heap.root(old)
        if el.hasAttribute(a.name) { detachAttr(el, a.name) }
        el.setAttributeValue(a.name, a.detachedValue)
        a.owner = el
        attrCache[JSDOMAttrKey(node: ObjectIdentifier(el), name: a.name)] = a
        heap.popRoots(to: d)
        return old
    }

    func Attr_namespaceURI(_ a: JSDOMAttr) -> String? {
        if a.name.hasPrefix("xlink:") { return "http://www.w3.org/1999/xlink" }
        if a.name.hasPrefix("xml:") { return "http://www.w3.org/XML/1998/namespace" }
        if a.name == "xmlns" || a.name.hasPrefix("xmlns:") { return "http://www.w3.org/2000/xmlns/" }
        return nil
    }
    func Attr_prefix(_ a: JSDOMAttr) -> String? {
        guard Attr_namespaceURI(a) != nil, let i = a.name.firstIndex(of: ":") else { return nil }
        return String(a.name[a.name.startIndex..<i])
    }
    func Attr_localName(_ a: JSDOMAttr) -> String {
        guard Attr_namespaceURI(a) != nil, let i = a.name.firstIndex(of: ":") else { return a.name }
        return String(a.name[a.name.index(after: i)...])
    }
    func Attr_name(_ a: JSDOMAttr) -> String { a.name }
    func Attr_value(_ a: JSDOMAttr) -> String { a.value }
    func Attr_set_value(_ a: JSDOMAttr, _ v: String) {
        if let o = a.owner { o.setAttributeValue(a.name, v) } else { a.detachedValue = v }
    }
    func Attr_nodeType(_ a: JSDOMAttr) -> Int { 2 }
    func Attr_ownerElement(_ a: JSDOMAttr) -> HTMLNode? { a.owner }
    func Attr_ownerDocument(_ a: JSDOMAttr) -> HTMLNode? { a.document }
    func Attr_specified(_ a: JSDOMAttr) -> Bool { true }

    // MARK: DOMStringMap (dataset)

    func exotic_DOMStringMap() -> JSHostExotic<JSDOMStringMap> {
        var e = JSHostExotic<JSDOMStringMap>()
        e.namedGet = { [unowned(unsafe) self] (realm: JSRealm, m: JSDOMStringMap, name: String) throws(JSThrow) -> JSValue? in
            guard let attr = jsdomDataAttributeName(name), let v = m.node.attribute(attr) else { return nil }
            return self.str(v)
        }
        e.namedKeys = { m in
            var out: [String] = []
            for a in m.node.attributes where a.name.hasPrefix("data-") {
                if let k = jsdomDatasetKey(a.name) { out.append(k) }
            }
            return out
        }
        e.namedEnumerable = true
        e.namedSet = { [unowned(unsafe) self] (realm: JSRealm, m: JSDOMStringMap, name: String, v: JSValue) throws(JSThrow) -> Bool in
            guard let attr = jsdomDataAttributeName(name) else {
                throw self.throwDOM("SyntaxError", "'" + name + "' is not a valid property name.")
            }
            let s = try self.toStr(v)
            if !htmlIsValidAttributeName(attr) { throw self.throwDOM("InvalidCharacterError", "Invalid data attribute name.") }
            m.node.setAttributeValue(attr, s)
            return true
        }
        e.namedDelete = { (realm: JSRealm, m: JSDOMStringMap, name: String) throws(JSThrow) -> Bool in
            guard let attr = jsdomDataAttributeName(name), m.node.hasAttribute(attr) else { return false }
            m.node.removeAttribute(attr)
            return true
        }
        return e
    }

    // MARK: DOMRect / DOMRectList

    func rectValue(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> JSValue {
        classes.DOMRect.wrap(JSDOMRect(x, y, w, h))
    }

    func DOMRect_constructor(_ x: Double, _ y: Double, _ w: Double, _ h: Double, newTarget: JSValue) throws(JSThrow) -> JSValue {
        let v = rectValue(x, y, w, h)
        try adoptNewTarget(v, newTarget, .DOMRect)
        return v
    }
    func DOMRect_x(_ r: JSDOMRect) -> Double { r.x }
    func DOMRect_y(_ r: JSDOMRect) -> Double { r.y }
    func DOMRect_width(_ r: JSDOMRect) -> Double { r.width }
    func DOMRect_height(_ r: JSDOMRect) -> Double { r.height }
    func DOMRect_set_x(_ r: JSDOMRect, _ v: Double) { r.x = v }
    func DOMRect_set_y(_ r: JSDOMRect, _ v: Double) { r.y = v }
    func DOMRect_set_width(_ r: JSDOMRect, _ v: Double) { r.width = v }
    func DOMRect_set_height(_ r: JSDOMRect, _ v: Double) { r.height = v }
    func DOMRect_top(_ r: JSDOMRect) -> Double { min(r.y, r.y + r.height) }
    func DOMRect_bottom(_ r: JSDOMRect) -> Double { max(r.y, r.y + r.height) }
    func DOMRect_left(_ r: JSDOMRect) -> Double { min(r.x, r.x + r.width) }
    func DOMRect_right(_ r: JSDOMRect) -> Double { max(r.x, r.x + r.width) }
    func DOMRect_toJSON(_ r: JSDOMRect) -> JSValue {
        let o = newObject()
        let d = heap.rootDepth
        _ = heap.root(o)
        for (k, v) in [("x", r.x), ("y", r.y), ("width", r.width), ("height", r.height), ("top", DOMRect_top(r)),
                       ("right", DOMRect_right(r)), ("bottom", DOMRect_bottom(r)), ("left", DOMRect_left(r))] {
            setProp(o, k, .number(v))
        }
        heap.popRoots(to: d)
        return o
    }

    func exotic_DOMRectList() -> JSHostExotic<JSDOMRectList> {
        var e = JSHostExotic<JSDOMRectList>()
        e.length = { l in l.rects.count }
        e.indexedGet = { [unowned(unsafe) self] (realm: JSRealm, l: JSDOMRectList, i: Int) throws(JSThrow) -> JSValue? in
            i >= 0 && i < l.rects.count ? self.classes.DOMRect.wrap(l.rects[i]) : nil
        }
        return e
    }
    func DOMRectList_length(_ l: JSDOMRectList) -> Int { l.rects.count }
    func DOMRectList_item(_ l: JSDOMRectList, _ i: Int) -> JSValue {
        i >= 0 && i < l.rects.count ? classes.DOMRect.wrap(l.rects[i]) : .null
    }
}

extension HTMLNode {
    func isHTML(_ name: String) -> Bool { kind == .element && namespace == .html && self.name == name }
}

/// dataset key ("fooBar") -> attribute name ("data-foo-bar"); nil if the
/// key has "-" followed by a lowercase ASCII letter.
func jsdomDataAttributeName(_ key: String) -> String? {
    var out: [UInt8] = Array("data-".utf8)
    var prevDash = false
    for b in key.utf8 {
        if prevDash && b >= 0x61 && b <= 0x7a { return nil }
        prevDash = b == 0x2d
        if b >= 0x41 && b <= 0x5a { out.append(0x2d); out.append(b + 0x20) } else { out.append(b) }
    }
    return String(decoding: out, as: UTF8.self)
}

/// "data-foo-bar" -> "fooBar" (nil if not a dataset name).
func jsdomDatasetKey(_ attr: String) -> String? {
    let bytes = Array(attr.utf8)
    guard bytes.count >= 5 else { return nil }
    var out: [UInt8] = []
    var i = 5
    while i < bytes.count {
        let b = bytes[i]
        if b >= 0x41 && b <= 0x5a { return nil }
        if b == 0x2d && i + 1 < bytes.count && bytes[i + 1] >= 0x61 && bytes[i + 1] <= 0x7a {
            out.append(bytes[i + 1] - 0x20)
            i += 2
            continue
        }
        out.append(b)
        i += 1
    }
    return String(decoding: out, as: UTF8.self)
}

/// The DOM namespace URI of an element.
func jsdomNamespaceURI(_ n: HTMLNode) -> String? {
    guard n.kind == .element else { return nil }
    switch n.namespace {
    case .html: return "http://www.w3.org/1999/xhtml"
    case .svg: return "http://www.w3.org/2000/svg"
    case .mathml: return "http://www.w3.org/1998/Math/MathML"
    }
}

/// The stored attribute name for (namespace, localName), or nil when no
/// such attribute can exist here.
func jsdomAttributeName(_ ns: String?, _ local: String, _ n: HTMLNode) -> String? {
    guard let ns = ns, !ns.isEmpty else { return local }
    switch ns {
    case "http://www.w3.org/1999/xlink": return "xlink:" + local
    case "http://www.w3.org/XML/1998/namespace": return "xml:" + local
    case "http://www.w3.org/2000/xmlns/": return local == "xmlns" ? "xmlns" : "xmlns:" + local
    default: return nil
    }
}

func jsdomIsListedElement(_ n: HTMLNode) -> Bool {
    guard n.kind == .element && n.namespace == .html else { return false }
    switch n.name {
    case "button", "fieldset", "input", "object", "output", "select", "textarea": return true
    default: return false
    }
}
