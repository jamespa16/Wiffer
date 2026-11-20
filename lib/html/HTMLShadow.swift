// Shadow DOM (ROADMAP Phase 9I): shadow roots, slots and slot assignment,
// the flat tree, and the custom element state that `:defined` reads.
//
// A shadow root is a DocumentFragment-kind node (`isShadowRoot`) hung off
// its host (`attachedShadowRoot`), not one of the host's children. It
// belongs to the host's document (same arena, same mutation observers), so
// every change inside a shadow tree is reported like any other. `parent`
// stops at the shadow root; `host` crosses to the host. `isConnected` and
// `rootNode(composed: true)` are shadow-including.
//
// Slot assignment follows the DOM standard ("find a slot", "find
// slottables", "assign slottables (for a tree)", "assign a slot") and runs
// eagerly from the mutation primitives in HTMLDOM.swift, from slot / name
// attribute changes and from `assign()`. A document that never had a shadow
// root skips all of it (one flag check per mutation). Whenever a slot's
// assigned nodes change, or a slot with no assigned nodes gains or loses
// fallback children, the DOM's "signal a slot change" happens: observers get
// an HTMLMutation of kind `.slotchange` targeting the slot (the event layer
// turns those into `slotchange` events at microtask time; deduplicate per
// microtask, as the spec's signal slots set does).
//
// The flat tree (`flatTreeChildren`, `flatTreeParent`) is what rendering
// walks: a host's shadow root's children instead of its own, a slot's
// assigned nodes instead of its children (its children are the fallback,
// shown when nothing is assigned). Light children of a host that no slot
// takes are not in the flat tree.

public enum HTMLShadowRootMode: UInt8 {
    case open, closed
}

public enum HTMLSlotAssignmentMode: UInt8 {
    case named, manual
}

/// The HTML Standard's custom element state. Elements start "undefined"
/// when their local name is a valid custom element name (HTML namespace),
/// else "uncustomized"; the JS custom elements layer moves them on.
public enum HTMLCustomElementState: UInt8 {
    case undefined, failed, uncustomized, precustomized, custom
}

/// Shadow root settings (stored on the shadow root).
struct HTMLShadowInfo {
    var mode: HTMLShadowRootMode
    var delegatesFocus: Bool
    var slotAssignment: HTMLSlotAssignmentMode
    var clonable: Bool
    var serializable: Bool
    var declarative = false
    var availableToElementInternals = false
}

/// Rare per-node state, allocated on first use.
final class HTMLNodeRare {
    /// Element: its shadow root (owned).
    var shadowRoot: HTMLNode? = nil
    /// Shadow root: its host and settings.
    unowned(unsafe) var host: HTMLNode? = nil
    var shadow: HTMLShadowInfo? = nil
    /// Slottable (element or text): the slot it is assigned to.
    unowned(unsafe) var assignedSlot: HTMLNode? = nil
    /// Slottable: manual slot assignment (`slot.assign(...)`).
    unowned(unsafe) var manualSlot: HTMLNode? = nil
    /// Slot: assigned nodes, and manually assigned nodes (manual mode).
    var assignedNodes: [HTMLNode] = []
    var manualNodes: [HTMLNode] = []
    /// Element: custom element state, 0 = the default for its name, else
    /// HTMLCustomElementState.rawValue + 1.
    var ceState: UInt8 = 0

    init() {}

    /// Drop every unowned link to or from `owner` (it is going away, or its
    /// document is): slottables forget this slot, the slot forgets them.
    func releaseLinks(_ owner: HTMLNode) {
        for a in assignedNodes { if let r = a.rare, r.assignedSlot === owner { r.assignedSlot = nil } }
        for m in manualNodes { if let r = m.rare, r.manualSlot === owner { r.manualSlot = nil } }
        assignedNodes = []
        manualNodes = []
        if let s = assignedSlot, let sr = s.rare {
            var i = 0
            while i < sr.assignedNodes.count { if sr.assignedNodes[i] === owner { sr.assignedNodes.remove(at: i) } else { i += 1 } }
        }
        if let s = manualSlot, let sr = s.rare {
            var i = 0
            while i < sr.manualNodes.count { if sr.manualNodes[i] === owner { sr.manualNodes.remove(at: i) } else { i += 1 } }
        }
        assignedSlot = nil
        manualSlot = nil
        if let s = shadowRoot, let sr = s.rare, sr.host === owner { sr.host = nil }
    }
}

/// Hard cap on nested slot flattening (slots assigned to slots).
let htmlMaxSlotNesting = 64

extension HTMLNode {
    func ensureRare() -> HTMLNodeRare {
        if let r = rare { return r }
        let r = HTMLNodeRare()
        rare = r
        return r
    }

    // ------------------------------------------------------- shadow roots

    /// True for a ShadowRoot (a DocumentFragment hung off a host).
    public var isShadowRoot: Bool { kind == .documentFragment && rare?.shadow != nil }

    /// ShadowRoot: its host element. nil for every other node.
    public var host: HTMLNode? { isShadowRoot ? rare?.host : nil }

    /// Element.shadowRoot: the shadow root if its mode is open, else nil.
    public var shadowRoot: HTMLNode? {
        guard let s = rare?.shadowRoot, s.rare?.shadow?.mode == .open else { return nil }
        return s
    }

    /// The element's shadow root whatever its mode (for rendering, the
    /// browser and the JS layer's closed-root bookkeeping).
    public var attachedShadowRoot: HTMLNode? { kind == .element ? rare?.shadowRoot : nil }

    /// True if the element has a shadow root.
    public var isShadowHost: Bool { kind == .element && rare?.shadowRoot != nil }

    /// ShadowRoot settings (nil / false on other nodes).
    public var shadowRootMode: HTMLShadowRootMode? { rare?.shadow?.mode }
    public var delegatesFocus: Bool { rare?.shadow?.delegatesFocus ?? false }
    public var slotAssignment: HTMLSlotAssignmentMode { rare?.shadow?.slotAssignment ?? .named }
    public var clonable: Bool { rare?.shadow?.clonable ?? false }
    public var serializable: Bool { rare?.shadow?.serializable ?? false }
    /// Created by declarative shadow DOM (and not re-attached since).
    public var isDeclarativeShadowRoot: Bool { rare?.shadow?.declarative ?? false }
    /// ShadowRoot "available to element internals" (ElementInternals.shadowRoot).
    public var availableToElementInternals: Bool {
        get { rare?.shadow?.availableToElementInternals ?? false }
        set { if rare?.shadow != nil { rare?.shadow?.availableToElementInternals = newValue } }
    }

    /// The HTML Standard's "valid shadow host name".
    public var isValidShadowHostName: Bool {
        guard kind == .element && namespace == .html else { return false }
        switch name {
        case "article", "aside", "blockquote", "body", "div", "footer", "h1", "h2", "h3", "h4", "h5", "h6",
             "header", "main", "nav", "p", "section", "span":
            return true
        default:
            return htmlIsValidCustomElementName(name)
        }
    }

    /// `element.attachShadow({mode, delegatesFocus, slotAssignment, clonable,
    /// serializable})`: the DOM's "attach a shadow root". Returns the shadow
    /// root. NotSupportedError if the element can't host one (not HTML, not a
    /// valid shadow host name, `customElementShadowDisabled` (the custom
    /// element definition's disableShadow, which the JS layer knows), or it
    /// already has a root that isn't a declarative one of the same mode). A
    /// declarative root of the same mode is emptied, stops being declarative
    /// and is returned.
    @discardableResult
    public func attachShadow(mode: HTMLShadowRootMode, delegatesFocus: Bool = false,
                             slotAssignment: HTMLSlotAssignmentMode = .named, clonable: Bool = false,
                             serializable: Bool = false, customElementShadowDisabled: Bool = false) throws(HTMLDOMError) -> HTMLNode {
        guard isValidShadowHostName else { throw .notSupported }
        if customElementShadowDisabled { throw .notSupported }
        if let current = rare?.shadowRoot {
            guard current.rare?.shadow?.declarative == true, current.rare?.shadow?.mode == mode else { throw .notSupported }
            current.replaceAllUnchecked(nil)
            current.rare?.shadow?.declarative = false
            return current
        }
        let s = HTMLNode(kind: .documentFragment)
        documentForCreation.registerNode(s)
        let sr = s.ensureRare()
        sr.host = self
        sr.shadow = HTMLShadowInfo(mode: mode, delegatesFocus: delegatesFocus, slotAssignment: slotAssignment,
                                   clonable: clonable, serializable: serializable)
        let st = customElementState
        if st == .precustomized || st == .custom { sr.shadow?.availableToElementInternals = true }
        ensureRare().shadowRoot = s
        nodeDocument?.docState?.hasShadowTrees = true
        if observed { notify(HTMLMutation(kind: .shadowRootAttached, target: self)) }
        return s
    }

    // ------------------------------------------------------ trees and roots

    /// The DOM's "get the root node" (getRootNode): with `composed`, crosses
    /// shadow roots to their hosts (the shadow-including root).
    public func rootNode(composed: Bool) -> HTMLNode {
        var n = rootNode
        if !composed { return n }
        while let h = n.host { n = h.rootNode }
        return n
    }

    /// The shadow-including parent: the parent, or a shadow root's host.
    public var composedParent: HTMLNode? { parent ?? host }

    /// Shadow-including inclusive ancestor (DOM).
    public func isShadowIncludingInclusiveAncestor(of other: HTMLNode) -> Bool {
        var n: HTMLNode? = other
        while let x = n {
            if x === self { return true }
            n = x.composedParent
        }
        return false
    }

    /// The DOM's "retarget A against B": climb out of shadow trees until the
    /// node is in a tree that B can see (event targets, hit results).
    public func retargeted(against b: HTMLNode) -> HTMLNode {
        var a = self
        var k = 0
        while k < 100_000 {
            k += 1
            let root = a.rootNode
            guard root.isShadowRoot, let h = root.host else { return a }
            if root.isShadowIncludingInclusiveAncestor(of: b) { return a }
            a = h
        }
        return a
    }

    /// Pre-order walk in shadow-including tree order (an element, then its
    /// shadow root's subtree, then its children). Template contents are not
    /// entered. The body returns false to stop.
    public func walkShadowIncluding(_ body: (HTMLNode) -> Bool) {
        var stack: [HTMLNode] = [self]
        while let n = stack.popLast() {
            if !body(n) { return }
            var i = n.children.count - 1
            while i >= 0 { stack.append(n.children[i]); i -= 1 }
            if let s = n.rare?.shadowRoot { stack.append(s) }
        }
    }

    // ------------------------------------------------------------- flat tree

    /// The node's children in the flat tree: a host's shadow root's children,
    /// a slot's assigned nodes (or its own children, the fallback, when
    /// nothing is assigned), otherwise its children.
    public var flatTreeChildren: [HTMLNode] {
        guard let r = rare else { return children }
        if kind == .element, let s = r.shadowRoot { return s.children }
        if !r.assignedNodes.isEmpty { return r.assignedNodes }
        return children
    }

    /// The node's parent in the flat tree: its assigned slot, a shadow
    /// root's host, nil for a host's light child that no slot takes (or a
    /// slot's fallback child while the slot has assigned nodes), otherwise
    /// the parent. A shadow root itself has none.
    public var flatTreeParent: HTMLNode? {
        if let s = rare?.assignedSlot { return s }
        guard let p = parent else { return nil }
        if let pr = p.rare {
            if pr.shadow != nil { return pr.host }
            if p.kind == .element && pr.shadowRoot != nil { return nil }
            if !pr.assignedNodes.isEmpty { return nil }
        }
        return p
    }

    /// True if the node is in the flat tree of its document (rendered as
    /// far as tree structure goes; display: none aside).
    public var isInFlatTree: Bool {
        var n: HTMLNode = self
        var k = 0
        while k < 100_000 {
            k += 1
            if n.kind == .document { return true }
            guard let p = n.flatTreeParent else { return false }
            n = p
        }
        return false
    }

    // ------------------------------------------------------------------ slots

    /// An HTML `<slot>` element.
    public var isSlot: Bool { kind == .element && namespace == .html && name == "slot" }

    /// Element or text: the nodes a slot can take.
    public var isSlottable: Bool { kind == .element || kind == .text }

    /// A slot's name (its `name` attribute, or "").
    public var slotName: String { attribute("name") ?? "" }

    /// A slottable's name (an element's `slot` attribute, or ""; "" for text).
    public var slottableName: String { kind == .element ? (attribute("slot") ?? "") : "" }

    /// Slottable.assignedSlot: the slot it is assigned to, if that slot's
    /// shadow root is open (the DOM's "find a slot" with open = true).
    public var assignedSlot: HTMLNode? { findSlot(open: true) }

    /// The slot this slottable is currently assigned to, open or closed.
    public var assignedSlotIncludingClosed: HTMLNode? { rare?.assignedSlot }

    /// Slot.assignedNodes({flatten}).
    public func assignedNodes(flatten: Bool = false) -> [HTMLNode] {
        guard isSlot else { return [] }
        if !flatten { return rare?.assignedNodes ?? [] }
        var out: [HTMLNode] = []
        findFlattenedSlottables(&out, 0)
        return out
    }

    /// Slot.assignedElements({flatten}).
    public func assignedElements(flatten: Bool = false) -> [HTMLNode] {
        assignedNodes(flatten: flatten).filter { $0.kind == .element }
    }

    /// A slot's manually assigned nodes (manual slot assignment mode).
    public var manuallyAssignedNodes: [HTMLNode] { rare?.manualNodes ?? [] }

    /// Slot.assign(...nodes): manual slot assignment. Non-slottables are
    /// ignored. Takes effect only in shadow roots with manual assignment.
    public func assign(_ nodes: [HTMLNode]) {
        guard isSlot else { return }
        let r = ensureRare()
        for n in r.manualNodes { if let nr = n.rare, nr.manualSlot === self { nr.manualSlot = nil } }
        var set: [HTMLNode] = []
        var seen: Set<ObjectIdentifier> = []
        var others: [HTMLNode] = []
        for n in nodes where n.isSlottable {
            if !seen.insert(ObjectIdentifier(n)).inserted { continue }
            let nr = n.ensureRare()
            if let old = nr.manualSlot, old !== self, let or = old.rare {
                var i = 0
                while i < or.manualNodes.count { if or.manualNodes[i] === n { or.manualNodes.remove(at: i) } else { i += 1 } }
                if !others.contains(where: { $0 === old }) { others.append(old) }
            }
            nr.manualSlot = self
            set.append(n)
        }
        r.manualNodes = set
        let root = rootNode
        assignSlottablesForTree(root)
        // Slots in other trees that lost nodes (the DOM leaves them stale
        // until their tree changes; engines don't).
        for o in others where o.rootNode !== root { o.assignSlottables() }
    }

    /// The DOM's "find a slot" for a slottable.
    func findSlot(open: Bool) -> HTMLNode? {
        guard isSlottable, let p = parent, p.kind == .element, let shadow = p.rare?.shadowRoot,
              let info = shadow.rare?.shadow else { return nil }
        if open && info.mode != .open { return nil }
        if info.slotAssignment == .manual {
            guard let s = rare?.manualSlot, s.rootNode === shadow else { return nil }
            return s
        }
        let nm = slottableName
        return shadow.firstElement { $0.isSlot && $0.slotName == nm }
    }

    /// The DOM's "find slottables" for a slot.
    func findSlottables() -> [HTMLNode] {
        let root = rootNode
        guard root.isShadowRoot, let host = root.host, let info = root.rare?.shadow else { return [] }
        var out: [HTMLNode] = []
        if info.slotAssignment == .manual {
            for s in rare?.manualNodes ?? [] where s.parent === host { out.append(s) }
            return out
        }
        // Named: only the first slot with a given name takes anything.
        let nm = slotName
        guard let first = root.firstElement(where: { $0.isSlot && $0.slotName == nm }), first === self else { return [] }
        for c in host.children where c.isSlottable && c.slottableName == nm { out.append(c) }
        return out
    }

    /// The DOM's "find flattened slottables".
    func findFlattenedSlottables(_ out: inout [HTMLNode], _ depth: Int) {
        guard depth < htmlMaxSlotNesting, rootNode.isShadowRoot else { return }
        var list = findSlottables()
        if list.isEmpty { list = children.filter { $0.isSlottable } }
        for n in list {
            if n.isSlot && n.rootNode.isShadowRoot { n.findFlattenedSlottables(&out, depth + 1) }
            else { out.append(n) }
        }
    }

    /// The DOM's "assign slottables" for a slot.
    func assignSlottables() {
        let found = findSlottables()
        let old = rare?.assignedNodes ?? []
        var same = found.count == old.count
        if same { for i in 0..<found.count where found[i] !== old[i] { same = false; break } }
        if same { return }
        let r = ensureRare()
        for o in old { if let orr = o.rare, orr.assignedSlot === self { orr.assignedSlot = nil } }
        r.assignedNodes = found
        for n in found {
            let nr = n.ensureRare()
            if let prev = nr.assignedSlot, prev !== self, let pr = prev.rare {
                // The node moves here from another slot: that slot changes too
                // (it may not be reassigned in this pass, or would see no change).
                var i = 0
                var took = false
                while i < pr.assignedNodes.count { if pr.assignedNodes[i] === n { pr.assignedNodes.remove(at: i); took = true } else { i += 1 } }
                if took { prev.signalSlotChange() }
            }
            nr.assignedSlot = self
        }
        signalSlotChange()
    }

    /// The DOM's "assign slottables for a tree" (the root's inclusive
    /// descendants, not entering nested shadow roots).
    func assignSlottablesForTree(_ root: HTMLNode) {
        var slots: [HTMLNode] = []
        root.walk { n in if n.isSlot { slots.append(n) }; return true }
        for s in slots { s.assignSlottables() }
    }

    /// The DOM's "assign a slot" for a slottable.
    func assignASlot() {
        if let s = findSlot(open: false) { s.assignSlottables() }
    }

    /// The DOM's "signal a slot change": a `.slotchange` record.
    func signalSlotChange() {
        if observed { notify(HTMLMutation(kind: .slotchange, target: self)) }
    }

    /// Does the subtree (inclusive) contain a slot?
    func subtreeHasSlot() -> Bool {
        var found = false
        walk { n in
            if n.isSlot { found = true; return false }
            return true
        }
        return found
    }

    var documentHasShadowTrees: Bool { nodeDocument?.docState?.hasShadowTrees ?? false }

    /// Slot steps of the DOM's "insert" for nodes just inserted under self.
    func slotStepsAfterInsert(_ nodes: [HTMLNode]) {
        guard documentHasShadowTrees else { return }
        let parentRoot = rootNode
        var treeRun = false
        for n in nodes {
            // The DOM does this for named assignment only; a manually assigned
            // node that comes back to its host is taken again too, as engines
            // do (assignments always equal "find slottables").
            if kind == .element, rare?.shadowRoot != nil, n.isSlottable {
                n.assignASlot()
            }
            if parentRoot.isShadowRoot && isSlot && (rare?.assignedNodes.isEmpty ?? true) { signalSlotChange() }
            if !treeRun && parentRoot.isShadowRoot && n.subtreeHasSlot() { treeRun = true }
        }
        if treeRun { assignSlottablesForTree(parentRoot) }
    }

    /// Slot steps of the DOM's "remove" for `child`, just removed from self.
    func slotStepsAfterRemove(_ child: HTMLNode) {
        guard documentHasShadowTrees else { return }
        if let s = child.rare?.assignedSlot { s.assignSlottables() }
        let parentRoot = rootNode
        if parentRoot.isShadowRoot && isSlot && (rare?.assignedNodes.isEmpty ?? true) { signalSlotChange() }
        if child.subtreeHasSlot() {
            assignSlottablesForTree(parentRoot)
            assignSlottablesForTree(child)
        }
    }

    /// Slot steps of the DOM's attribute change steps (`name` on a slot,
    /// `slot` on a slottable).
    func slotStepsAfterAttributeChange(_ attr: String, old: String?, new: String?) {
        guard documentHasShadowTrees, kind == .element else { return }
        guard attr == "name" || attr == "slot" else { return }
        if old == new || (old == nil && new == "") || (old == "" && new == nil) { return }
        if attr == "name" && isSlot {
            let root = rootNode
            if root.isShadowRoot { assignSlottablesForTree(root) }
        }
        if attr == "slot" {
            if let s = rare?.assignedSlot { s.assignSlottables() }
            assignASlot()
        }
    }

    /// Assign every slot in every shadow tree under (and including) self
    /// (after the parser built shadow trees without running insertion steps).
    func assignAllSlots() {
        var roots: [HTMLNode] = []
        walkShadowIncluding { n in
            if n.isShadowRoot { roots.append(n) }
            return true
        }
        if rootNode.isShadowRoot && !roots.contains(where: { $0 === rootNode }) { roots.append(rootNode) }
        for r in roots { assignSlottablesForTree(r) }
    }

    // -------------------------------------------------------- custom elements

    /// The element's custom element state (see HTMLCustomElementState).
    public var customElementState: HTMLCustomElementState {
        if let r = rare, r.ceState != 0, let s = HTMLCustomElementState(rawValue: r.ceState - 1) { return s }
        return kind == .element && namespace == .html && htmlIsValidCustomElementName(name) ? .undefined : .uncustomized
    }

    /// Set by the custom elements layer (upgrade, construction, failure).
    /// Reported to observers as a `.customElementState` record (`:defined`
    /// may change).
    public func setCustomElementState(_ s: HTMLCustomElementState) {
        guard kind == .element else { return }
        let old = customElementState
        ensureRare().ceState = s.rawValue + 1
        if old != s && observed { notify(HTMLMutation(kind: .customElementState, target: self)) }
    }

    /// The DOM's "defined": state uncustomized or custom (`:defined`).
    public var isDefined: Bool {
        let s = customElementState
        return s == .uncustomized || s == .custom
    }
}

/// The HTML Standard's "valid custom element name": starts with an ASCII
/// lower alpha, contains a hyphen, no ASCII upper alpha, only PCENChars,
/// and not one of the reserved SVG/MathML names.
public func htmlIsValidCustomElementName(_ name: String) -> Bool {
    var it = name.unicodeScalars.makeIterator()
    guard let first = it.next(), first.value >= 0x61 && first.value <= 0x7a else { return false }
    var hyphen = false
    while let c = it.next() {
        let v = c.value
        if v == 0x2d { hyphen = true; continue }
        if v >= 0x41 && v <= 0x5a { return false }
        let ok = v == 0x2e || (v >= 0x30 && v <= 0x39) || v == 0x5f || (v >= 0x61 && v <= 0x7a) || v == 0xb7
            || (v >= 0xc0 && v <= 0xd6) || (v >= 0xd8 && v <= 0xf6) || (v >= 0xf8 && v <= 0x37d)
            || (v >= 0x37f && v <= 0x1fff) || (v >= 0x200c && v <= 0x200d) || (v >= 0x203f && v <= 0x2040)
            || (v >= 0x2070 && v <= 0x218f) || (v >= 0x2c00 && v <= 0x2fef) || (v >= 0x3001 && v <= 0xd7ff)
            || (v >= 0xf900 && v <= 0xfdcf) || (v >= 0xfdf0 && v <= 0xfffd) || (v >= 0x10000 && v <= 0xeffff)
        if !ok { return false }
    }
    if !hyphen { return false }
    switch name {
    case "annotation-xml", "color-profile", "font-face", "font-face-src", "font-face-uri", "font-face-format",
         "font-face-name", "missing-glyph":
        return false
    default:
        return true
    }
}
