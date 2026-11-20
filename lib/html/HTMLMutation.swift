// Mutation notifications (ROADMAP Phase 9G): the hook lib/layout's
// incremental restyle (and later the JS MutationObserver) subscribes to.
//
// Observers are closures registered on a document. Every change made
// through the public mutation API (HTMLDOM.swift: appendChild, insertBefore,
// removeChild, replaceChild, setAttribute, setData, innerHTML, ...) on a
// node owned by that document calls each observer once, synchronously,
// after the tree is consistent again (children, parent and `index` all
// updated). The parser itself never notifies: a fresh parse has no
// observers, and innerHTML & co. are reported as the one childList change
// that inserts the parsed fragment (preceded, as for any fragment
// insertion, by a removal record whose target is that detached fragment).
//
// Cost when nobody listens: one array emptiness check per mutation (the
// record is not built). Records are the DOM's MutationRecord shape:
//
//   .childList      target = the parent whose children changed;
//                   addedNodes / removedNodes in tree order;
//                   previousSibling / nextSibling = the neighbours of the
//                   changed run (after the change for additions, at the
//                   removal point for removals).
//   .attributes     target = the element; attributeName = the name as
//                   stored (lowercase for HTML); oldValue = the value before
//                   (nil if the attribute was absent; a removal is a record
//                   whose new state is `target.attribute(name) == nil`).
//   .characterData  target = the text or comment node; oldValue = old text.
//
// Moving a node that already has a parent produces two records: removal
// from the old parent, then insertion. Inserting a DocumentFragment
// produces a removal record on the fragment, then one insertion record
// with all its children. Nodes in a `<template>`'s contents belong to the
// inert template contents document, so the page's observers do not see
// them (they are not rendered). Shadow trees belong to their host's
// document, so changes inside them are reported (target.isConnected is
// shadow-including). Shadow DOM adds three engine-only kinds (.slotchange,
// .shadowRootAttached, .customElementState; see HTMLMutationKind).
//
// An observer may mutate the tree (its records are delivered re-entrantly,
// in order). It must not hold a strong reference to the document it
// observes from inside the closure unless it removes itself before the
// document should go away (the document holds the closure: a cycle).

public enum HTMLMutationKind: UInt8 {
    case childList, attributes, characterData
    /// Not DOM MutationRecords (a JS MutationObserver must skip these):
    /// "signal a slot change" for `target` (a slot; the event layer fires
    /// `slotchange` from these), a shadow root attached to `target` (the
    /// rendering of the host changes), and a changed custom element state
    /// of `target` (`:defined` may change).
    case slotchange, shadowRootAttached, customElementState
}

public struct HTMLMutation {
    public var kind: HTMLMutationKind
    public var target: HTMLNode
    public var addedNodes: [HTMLNode]
    public var removedNodes: [HTMLNode]
    public var previousSibling: HTMLNode?
    public var nextSibling: HTMLNode?
    /// .attributes only ("" otherwise).
    public var attributeName: String
    /// .attributes: the previous value (nil = it was absent).
    /// .characterData: the previous text. .childList: nil.
    public var oldValue: String?

    public init(kind: HTMLMutationKind, target: HTMLNode, addedNodes: [HTMLNode] = [], removedNodes: [HTMLNode] = [],
                previousSibling: HTMLNode? = nil, nextSibling: HTMLNode? = nil,
                attributeName: String = "", oldValue: String? = nil) {
        self.kind = kind
        self.target = target
        self.addedNodes = addedNodes
        self.removedNodes = removedNodes
        self.previousSibling = previousSibling
        self.nextSibling = nextSibling
        self.attributeName = attributeName
        self.oldValue = oldValue
    }
}

extension HTMLNode {
    /// Register `observer` on this node's document (on the node itself if it
    /// is a document). Returns an id for removeMutationObserver.
    @discardableResult
    public func addMutationObserver(_ observer: @escaping (HTMLMutation) -> Void) -> Int {
        guard let d = nodeDocument, let st = d.docState else { return 0 }
        let id = st.nextObserverID
        st.nextObserverID += 1
        st.observers.append((id: id, fn: observer))
        return id
    }

    public func removeMutationObserver(_ id: Int) {
        guard let d = nodeDocument, let st = d.docState else { return }
        var i = 0
        while i < st.observers.count {
            if st.observers[i].id == id { st.observers.remove(at: i); return }
            i += 1
        }
    }

    /// True if this node's document has observers (so building a record is
    /// worth it).
    var observed: Bool {
        guard let d = nodeDocument, let st = d.docState else { return false }
        return !st.observers.isEmpty
    }

    /// Deliver a record to this node's document's observers.
    func notify(_ m: HTMLMutation) {
        guard let d = nodeDocument, let st = d.docState, !st.observers.isEmpty else { return }
        let list = st.observers   // an observer may add or remove observers
        for o in list { o.fn(m) }
    }
}
