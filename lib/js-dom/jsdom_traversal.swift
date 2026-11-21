// DOM Standard "Traversal": NodeIterator and TreeWalker (Lit instantiates
// its templates with a TreeWalker). The filter (a function or an object
// with acceptNode) lives in hidden slot 0 of the wrapper. NodeIterators
// follow removals through the page's mutation records (the "pre-removing
// steps", computed from the record's siblings after the fact).

final class JSDOMNodeIterator {
    let root: HTMLNode
    var reference: HTMLNode
    var pointerBefore = true
    let whatToShow: Int
    var active = false
    init(root: HTMLNode, whatToShow: Int) {
        self.root = root
        reference = root
        self.whatToShow = whatToShow
    }
}

final class JSDOMTreeWalker {
    let root: HTMLNode
    var current: HTMLNode
    let whatToShow: Int
    var active = false
    init(root: HTMLNode, whatToShow: Int) {
        self.root = root
        current = root
        self.whatToShow = whatToShow
    }
}

let jsdomFilterAccept = 1
let jsdomFilterReject = 2
let jsdomFilterSkip = 3
let jsdomMaxTraversalSteps = 50_000_000

extension JSDOMBindings {
    func Document_createTreeWalker(_ d: HTMLNode, _ root: HTMLNode, _ what: Int, _ filter: JSValue) throws(JSThrow) -> JSValue {
        let w = classes.TreeWalker.wrap(JSDOMTreeWalker(root: root, whatToShow: what))
        setHiddenSlot(w, 0, filter.isUndefined ? .null : filter)
        return w
    }

    func Document_createNodeIterator(_ d: HTMLNode, _ root: HTMLNode, _ what: Int, _ filter: JSValue) throws(JSThrow) -> JSValue {
        let it = JSDOMNodeIterator(root: root, whatToShow: what)
        let w = classes.NodeIterator.wrap(it)
        setHiddenSlot(w, 0, filter.isUndefined ? .null : filter)
        // Drop iterators whose wrappers are gone, then track this one.
        nodeIterators.removeAll { self.classes.NodeIterator.existingWrapper(for: $0) == nil }
        if nodeIterators.count < 10_000 { nodeIterators.append(it) }
        return w
    }

    func traversalNodeType(_ n: HTMLNode) -> Int {
        switch n.kind {
        case .element: return 1
        case .text: return isCDATA(n) ? 4 : 3
        case .comment: return isPI(n) ? 7 : 8
        case .document: return 9
        case .doctype: return 10
        case .documentFragment: return 11
        }
    }

    /// The DOM's "filter" a node: whatToShow, then the user filter.
    func traversalFilter(_ n: HTMLNode, _ what: Int, _ wrapper: JSValue?, active: inout Bool) throws(JSThrow) -> Int {
        if active { throw throwDOM("InvalidStateError", "The filter is already running.") }
        let bit = traversalNodeType(n) - 1
        if (what >> bit) & 1 == 0 { return jsdomFilterSkip }
        guard let w = wrapper else { return jsdomFilterAccept }
        let f = hiddenSlot(w, 0)
        if f.isNull || f.isUndefined { return jsdomFilterAccept }
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        let nodeW = wrapNode(n)
        _ = heap.root(nodeW)
        active = true
        let r: JSValue
        do throws(JSThrow) {
            if heap.isCallable(f) {
                r = try realm.call(f, this: .undefined, args: [nodeW])
            } else {
                let m = try realm.getV(f, heap.key("acceptNode"))
                if !heap.isCallable(m) {
                    active = false
                    throw realm.throwTypeError("NodeFilter.acceptNode is not a function")
                }
                r = try realm.call(m, this: f, args: [nodeW])
            }
        } catch {
            active = false
            throw error
        }
        active = false
        let x = try realm.toNumber(r)
        return x.isFinite ? Int(x) & 0xFFFF : 0
    }

    // MARK: NodeIterator

    func NodeIterator_root(_ it: JSDOMNodeIterator) -> HTMLNode? { it.root }
    func NodeIterator_referenceNode(_ it: JSDOMNodeIterator) -> HTMLNode? { it.reference }
    func NodeIterator_pointerBeforeReferenceNode(_ it: JSDOMNodeIterator) -> Bool { it.pointerBefore }
    func NodeIterator_whatToShow(_ it: JSDOMNodeIterator) -> Int { it.whatToShow }
    func NodeIterator_filter(_ it: JSDOMNodeIterator) -> JSValue {
        classes.NodeIterator.existingWrapper(for: it).map { hiddenSlot($0, 0) } ?? .null
    }
    func NodeIterator_detach(_ it: JSDOMNodeIterator) {}

    func NodeIterator_nextNode(_ it: JSDOMNodeIterator) throws(JSThrow) -> HTMLNode? { try iterTraverse(it, next: true) }
    func NodeIterator_previousNode(_ it: JSDOMNodeIterator) throws(JSThrow) -> HTMLNode? { try iterTraverse(it, next: false) }

    func iterTraverse(_ it: JSDOMNodeIterator, next: Bool) throws(JSThrow) -> HTMLNode? {
        var node = it.reference
        var before = it.pointerBefore
        let w = classes.NodeIterator.existingWrapper(for: it)
        var steps = 0
        while steps < jsdomMaxTraversalSteps {
            steps += 1
            if next {
                if !before {
                    guard let f = followingNode(node, within: it.root) else { return nil }
                    node = f
                } else { before = false }
            } else {
                if before {
                    guard node !== it.root, let p = precedingNode(node, within: it.root) else { return nil }
                    node = p
                } else { before = true }
            }
            let r = try traversalFilter(node, it.whatToShow, w, active: &it.active)
            if r == jsdomFilterAccept { break }
        }
        it.reference = node
        it.pointerBefore = before
        return node
    }

    /// Next node in tree order inside `root` (nil past the end).
    func followingNode(_ n: HTMLNode, within root: HTMLNode) -> HTMLNode? {
        if let c = n.children.first { return c }
        var x: HTMLNode? = n
        var k = 0
        while let cur = x, cur !== root, k < 100_000 {
            if let s = cur.nextSibling { return s }
            x = cur.parent
            k += 1
        }
        return nil
    }

    /// Previous node in tree order inside `root` (root itself included).
    func precedingNode(_ n: HTMLNode, within root: HTMLNode) -> HTMLNode? {
        if n === root { return nil }
        guard let p = n.previousSibling else { return n.parent }
        var x = p
        var k = 0
        while let l = x.children.last, k < 100_000 { x = l; k += 1 }
        return x
    }

    func isInclusiveAncestor(_ a: HTMLNode, of n: HTMLNode) -> Bool {
        var x: HTMLNode? = n
        var k = 0
        while let c = x, k < 100_000 {
            if c === a { return true }
            x = c.parent
            k += 1
        }
        return false
    }

    /// NodeIterator pre-removing steps, from a childList record (after the
    /// fact: the removed nodes, their old parent and neighbours).
    func iteratorsNoteRemoval(_ m: HTMLMutation) {
        if nodeIterators.isEmpty || m.removedNodes.isEmpty { return }
        for it in nodeIterators {
            var k = 0
            while k < m.removedNodes.count {
                let r = m.removedNodes[k]
                let nextSib: HTMLNode? = k + 1 < m.removedNodes.count ? m.removedNodes[k + 1] : m.nextSibling
                k += 1
                if r === it.root || !isInclusiveAncestor(r, of: it.reference) { continue }
                // The old parent must have been inside the root.
                if !isInclusiveAncestor(it.root, of: m.target) { continue }
                if it.pointerBefore {
                    var next: HTMLNode? = nextSib
                    if next == nil {
                        var x: HTMLNode? = m.target
                        var steps = 0
                        while let c = x, c !== it.root, steps < 100_000 {
                            if let s = c.nextSibling { next = s; break }
                            x = c.parent
                            steps += 1
                        }
                    }
                    if let nx = next {
                        it.reference = nx
                        continue
                    }
                    it.pointerBefore = false
                }
                if let p = m.previousSibling {
                    var x = p
                    var steps = 0
                    while let l = x.children.last, steps < 100_000 { x = l; steps += 1 }
                    it.reference = x
                } else {
                    it.reference = m.target
                }
            }
        }
    }

    // MARK: TreeWalker

    func TreeWalker_root(_ t: JSDOMTreeWalker) -> HTMLNode? { t.root }
    func TreeWalker_whatToShow(_ t: JSDOMTreeWalker) -> Int { t.whatToShow }
    func TreeWalker_filter(_ t: JSDOMTreeWalker) -> JSValue {
        classes.TreeWalker.existingWrapper(for: t).map { hiddenSlot($0, 0) } ?? .null
    }
    func TreeWalker_currentNode(_ t: JSDOMTreeWalker) -> HTMLNode? { t.current }
    func TreeWalker_set_currentNode(_ t: JSDOMTreeWalker, _ n: HTMLNode) { t.current = n }

    func twFilter(_ t: JSDOMTreeWalker, _ n: HTMLNode) throws(JSThrow) -> Int {
        try traversalFilter(n, t.whatToShow, classes.TreeWalker.existingWrapper(for: t), active: &t.active)
    }

    func TreeWalker_parentNode(_ t: JSDOMTreeWalker) throws(JSThrow) -> HTMLNode? {
        var node: HTMLNode? = t.current
        var k = 0
        while let n = node, n !== t.root, k < 100_000 {
            k += 1
            node = n.parent
            if let p = node, try twFilter(t, p) == jsdomFilterAccept {
                t.current = p
                return p
            }
        }
        return nil
    }

    func TreeWalker_firstChild(_ t: JSDOMTreeWalker) throws(JSThrow) -> HTMLNode? { try twChildren(t, first: true) }
    func TreeWalker_lastChild(_ t: JSDOMTreeWalker) throws(JSThrow) -> HTMLNode? { try twChildren(t, first: false) }

    func twChildren(_ t: JSDOMTreeWalker, first: Bool) throws(JSThrow) -> HTMLNode? {
        var node: HTMLNode? = first ? t.current.children.first : t.current.children.last
        var steps = 0
        while let n0 = node, steps < jsdomMaxTraversalSteps {
            steps += 1
            var n = n0
            let r = try twFilter(t, n)
            if r == jsdomFilterAccept { t.current = n; return n }
            if r == jsdomFilterSkip, let c = first ? n.children.first : n.children.last {
                node = c
                continue
            }
            var found: HTMLNode? = nil
            var k = 0
            while k < 100_000 {
                k += 1
                if let s = first ? n.nextSibling : n.previousSibling { found = s; break }
                guard let p = n.parent, p !== t.root, p !== t.current else { return nil }
                n = p
            }
            node = found
        }
        return nil
    }

    func TreeWalker_nextSibling(_ t: JSDOMTreeWalker) throws(JSThrow) -> HTMLNode? { try twSiblings(t, next: true) }
    func TreeWalker_previousSibling(_ t: JSDOMTreeWalker) throws(JSThrow) -> HTMLNode? { try twSiblings(t, next: false) }

    func twSiblings(_ t: JSDOMTreeWalker, next: Bool) throws(JSThrow) -> HTMLNode? {
        var node = t.current
        if node === t.root { return nil }
        var steps = 0
        while steps < jsdomMaxTraversalSteps {
            steps += 1
            var sib: HTMLNode? = next ? node.nextSibling : node.previousSibling
            while let s = sib, steps < jsdomMaxTraversalSteps {
                steps += 1
                node = s
                let r = try twFilter(t, s)
                if r == jsdomFilterAccept { t.current = s; return s }
                sib = next ? s.children.first : s.children.last
                if r == jsdomFilterReject || sib == nil { sib = next ? s.nextSibling : s.previousSibling }
            }
            guard let p = node.parent, p !== t.root else { return nil }
            node = p
            if try twFilter(t, p) == jsdomFilterAccept { return nil }
        }
        return nil
    }

    func TreeWalker_previousNode(_ t: JSDOMTreeWalker) throws(JSThrow) -> HTMLNode? {
        var node = t.current
        var steps = 0
        while node !== t.root && steps < jsdomMaxTraversalSteps {
            steps += 1
            var sib = node.previousSibling
            while let s = sib, steps < jsdomMaxTraversalSteps {
                steps += 1
                node = s
                var r = try twFilter(t, node)
                while r != jsdomFilterReject, let l = node.children.last, steps < jsdomMaxTraversalSteps {
                    steps += 1
                    node = l
                    r = try twFilter(t, node)
                }
                if r == jsdomFilterAccept { t.current = node; return node }
                sib = node.previousSibling
            }
            if node === t.root { return nil }
            guard let p = node.parent else { return nil }
            node = p
            if try twFilter(t, node) == jsdomFilterAccept { t.current = node; return node }
        }
        return nil
    }

    func TreeWalker_nextNode(_ t: JSDOMTreeWalker) throws(JSThrow) -> HTMLNode? {
        var node = t.current
        var r = jsdomFilterAccept
        var steps = 0
        while steps < jsdomMaxTraversalSteps {
            steps += 1
            while r != jsdomFilterReject, let c = node.children.first, steps < jsdomMaxTraversalSteps {
                steps += 1
                node = c
                r = try twFilter(t, node)
                if r == jsdomFilterAccept { t.current = node; return node }
            }
            var sibling: HTMLNode? = nil
            var temp: HTMLNode? = node
            var k = 0
            while let tp = temp, k < 100_000 {
                k += 1
                if tp === t.root { return nil }
                if let s = tp.nextSibling { sibling = s; break }
                temp = tp.parent
            }
            guard let s = sibling else { return nil }
            node = s
            r = try twFilter(t, node)
            if r == jsdomFilterAccept { t.current = node; return node }
        }
        return nil
    }
}
