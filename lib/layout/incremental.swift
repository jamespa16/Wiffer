// Incremental restyle and relayout driven by DOM mutations, and forced layout.
//
// The DOM side reports what changed:
//
//   engine.noteAttributeChanged(node, name: "class")
//   engine.noteChildrenChanged(parent, added: [...], removed: [...])
//   engine.noteTextChanged(textNode)        // character data
//   engine.updateIfNeeded()                 // or update(); both flush the notes
//
// Notes are cheap (a list append); nothing is restyled until the flush.
//
//   * Attribute change: the element's subtree is restyled in place, plus its
//     following siblings when any rule has a `+` or `~` combinator. If no
//     layout-affecting property changed, only the display list is rebuilt
//     (geometry is kept). Attributes that matter beyond style (src, colspan,
//     align, ...) also rebuild the element's box subtree.
//   * Child list or text change: the box subtree of the nearest rebuildable
//     ancestor (a block-level, in-flow, non-anonymous block inside a block
//     container whose new display is still block) is rebuilt and spliced in.
//     Everything else falls back to a whole-document rebuild.
//   * <style>/<link> changes rescan the style sources (fetched <link> sheets
//     are kept) and restyle everything.
//
// Layout itself is still whole-document (the layout caches are keyed by a
// per-layout generation, so BFC roots are not reused across updates).
//
// Forced layout: rect(of:), computedStyle(of:) and metrics(of:) flush any
// pending style and layout first and are counted in `stats`.

struct LayoutUpdateStats {
    /// Layout-dependent queries (rect, computed style, metrics).
    var forcedQueries = 0
    /// Of those, the ones that found pending work and had to flush it.
    var forcedFlushes = 0
    /// DOM-change batches processed.
    var domBatches = 0
    /// Batches resolved by an in-place restyle with no relayout.
    var paintOnly = 0
    /// Box subtrees rebuilt and spliced into the tree.
    var subtreeRebuilds = 0
    /// Whole-document style rebuilds.
    var fullRebuilds = 0
    init() {}
}

/// Element metrics as script sees them (CSSOM View), in CSS pixels.
struct LayoutMetrics {
    var offsetWidth = 0.0, offsetHeight = 0.0
    var clientLeft = 0.0, clientTop = 0.0, clientWidth = 0.0, clientHeight = 0.0
    var scrollWidth = 0.0, scrollHeight = 0.0
    init() {}
}

extension LayoutEngine {
    // MARK: Notes

    var hasPendingDOMChanges: Bool {
        pendingRescan || !pendingAttr.isEmpty || !pendingAttrRebuild.isEmpty || !pendingChildren.isEmpty || !pendingText.isEmpty
    }

    var hasPendingWork: Bool { needsStyle || needsLayout || !pendingHover.isEmpty || hasPendingDOMChanges }

    private func connected(_ n: HTMLNode) -> Bool {
        var p: HTMLNode? = n
        var k = 0
        while let q = p, k < 4096 {
            if q === document { return true }
            p = q.parent
            k += 1
        }
        return false
    }

    private func overflowPending() {
        // Thousands of notes cost more to resolve one by one than a full restyle.
        if pendingAttr.count + pendingAttrRebuild.count + pendingChildren.count + pendingText.count > 3000 {
            pendingAttr = []; pendingAttrRebuild = []; pendingChildren = []; pendingText = []
            needsStyle = true
        }
    }

    /// An attribute was set, changed or removed.
    func noteAttributeChanged(_ node: HTMLNode, name: String) {
        guard node.kind == .element else { return }
        if name == "class" { state.classes.removeValue(forKey: ObjectIdentifier(node)) }
        if node.namespace == .html && (node.name == "style" || node.name == "link") { pendingRescan = true; return }
        if let l = pendingAttr.last, l === node {} else { pendingAttr.append(node) }
        if !layoutAttributeIsStyleOnly(name) { pendingAttrRebuild.append(node) }
        overflowPending()
    }

    /// Children were inserted, removed or reordered under `parent`. `added` and
    /// `removed` are optional but let the engine notice <style>/<link>
    /// changes and drop stale caches without scanning.
    func noteChildrenChanged(_ parent: HTMLNode, added: [HTMLNode] = [], removed: [HTMLNode] = []) {
        if removed.isEmpty { state.classes.removeAll() }
        for r in removed { layoutPurgeClasses(r, state) }
        if layoutInsideSource(parent) { pendingRescan = true }
        for n in added { if layoutSubtreeHasSource(n) { pendingRescan = true } }
        for n in removed { if layoutSubtreeHasSource(n) { pendingRescan = true } }
        if parent.kind == .element && parent.name == "title" { refreshTitle() }
        pendingChildren.append(parent)
        overflowPending()
    }

    /// A text node's data changed.
    func noteTextChanged(_ node: HTMLNode) {
        guard let p = node.parent else { return }
        if layoutInsideSource(p) { pendingRescan = true }
        if p.kind == .element && p.name == "title" { refreshTitle() }
        pendingText.append(node)
        overflowPending()
    }

    private func refreshTitle() {
        var t: String? = nil
        document.walk { n in
            if n.kind == .element && n.name == "title" && n.namespace == .html { t = layoutCollapseSpaces(n.textContent); return false }
            return true
        }
        title = t ?? ""
    }

    /// Flush notes and restyle/relayout if anything is pending.
    func updateIfNeeded() { if hasPendingWork { update() } }

    // MARK: Forced layout

    /// Called by every layout-dependent query.
    func flushForQuery() {
        stats.forcedQueries += 1
        if inUpdate { return }
        if hasPendingWork {
            stats.forcedFlushes += 1
            update()
        }
    }

    /// The computed style of an element (nil for non-elements). Elements with
    /// no box (display: none) get a style computed against their parent's.
    func computedStyle(of node: HTMLNode) -> CSSComputedStyle? {
        guard node.kind == .element else { return nil }
        flushForQuery()
        if let b = box(for: node) { return b.style }
        guard let p = node.parent, p.kind == .element else {
            return resolver.computeStyle(LayoutElement(node, state), parent: nil, hints: layoutHints(node))
        }
        var pb = box(for: p)
        while let q = pb, q.anonymous { pb = q.parent }
        return resolver.computeStyle(LayoutElement(node, state), parent: pb?.style, hints: layoutHints(node))
    }

    /// offsetWidth/clientWidth/scrollHeight and friends (nil if the element has no box).
    func metrics(of node: HTMLNode) -> LayoutMetrics? {
        flushForQuery()
        guard let b = box(for: node) else { return nil }
        var m = LayoutMetrics()
        let r = layoutBoxRect(b)
        m.offsetWidth = r.w; m.offsetHeight = r.h
        if b.kind == .inline || b.kind == .text { m.scrollWidth = r.w; m.scrollHeight = r.h; return m }
        if b.parent == nil {
            m.clientWidth = viewportWidth; m.clientHeight = viewportHeight
            m.scrollWidth = max(documentWidth, viewportWidth); m.scrollHeight = max(documentHeight, viewportHeight)
            return m
        }
        let pb = b.paddingBox
        m.clientLeft = b.border.l; m.clientTop = b.border.t
        m.clientWidth = pb.w; m.clientHeight = pb.h
        var maxR = pb.x + pb.w, maxB = pb.y + pb.h
        var stack: [LayoutBox] = b.children
        var steps = 0
        while let c = stack.popLast(), steps < 100_000 {
            steps += 1
            if c.kind == .text || c.kind == .inline {
                for f in c.frags { maxR = max(maxR, c.ax + f.x + f.w); maxB = max(maxB, c.ay + f.y + f.h) }
            } else {
                maxR = max(maxR, c.ax + c.w); maxB = max(maxB, c.ay + c.h)
            }
            for g in c.children { stack.append(g) }
        }
        m.scrollWidth = max(pb.w, maxR - pb.x)
        m.scrollHeight = max(pb.h, maxB - pb.y)
        return m
    }

    // MARK: Flush

    /// Resolve the pending DOM notes into restyles and box subtree rebuilds
    /// (called by update()).
    func processDOMChanges() {
        let attrs = pendingAttr, rebuildAttrs = pendingAttrRebuild, kids = pendingChildren, texts = pendingText
        let rescan = pendingRescan
        pendingAttr = []; pendingAttrRebuild = []; pendingChildren = []; pendingText = []; pendingRescan = false
        stats.domBatches += 1
        if rescan { rescanSources() }
        if needsStyle || root == nil { return }

        // Structural changes: rebuild box subtrees.
        var starts: [HTMLNode] = kids
        for t in texts { if let p = t.parent { starts.append(p) } }
        starts.append(contentsOf: rebuildAttrs)
        var any = false
        if !starts.isEmpty {
            var cands: [HTMLNode] = []
            var seen: Set<ObjectIdentifier> = []
            for s in starts where connected(s) {
                guard let (r, _) = rebuildRoot(from: s) else { needsStyle = true; return }
                if seen.insert(ObjectIdentifier(r)).inserted { cands.append(r) }
            }
            // Drop candidates nested under another one.
            var outer: [HTMLNode] = []
            for c in cands {
                var nested = false
                var p = c.parent
                var k = 0
                while let q = p, k < 4096 {
                    if seen.contains(ObjectIdentifier(q)) { nested = true; break }
                    p = q.parent
                    k += 1
                }
                if !nested { outer.append(c) }
            }
            for c in outer where connected(c) {
                if !rebuildAround(c) { needsStyle = true; return }
                any = true
            }
        }

        // Style-only changes: restyle in place.
        var roots: [HTMLNode] = []
        for d in attrs where connected(d) {
            roots.append(d)
            if hasSiblingRules, let p = d.parent {
                var after = false
                for c in p.children where c.kind == .element {
                    if after { roots.append(c) } else if c === d { after = true }
                }
            }
        }
        var restyled = false
        if !roots.isEmpty {
            if restyleInPlace(roots, widen: false) {
                restyled = true
            } else {
                for d in attrs where connected(d) {
                    let start: HTMLNode? = hasSiblingRules ? (d.parent?.kind == .element ? d.parent : d) : d
                    guard let (r, _) = rebuildRoot(from: start), rebuildAround(r) else { needsStyle = true; return }
                    any = true
                }
            }
        }
        if any { needsLayout = true }
        else if restyled && !needsLayout, let r = root {
            stats.paintOnly += 1
            computeAbsolute(r)
            buildDisplay()
        }
    }

    /// Re-read <style>/<link> elements, keeping fetched sheets for links that are still there.
    private func rescanSources() {
        let oldSources = styleSources
        let oldSlots = slots
        scanDocument()
        for (i, s) in styleSources.enumerated() where s.href != nil {
            for (j, o) in oldSources.enumerated() where o.node === s.node && o.href == s.href && j < oldSlots.count {
                slots[i] = oldSlots[j]
            }
        }
        rebuildResolver()
        styleSourcesVersion += 1
    }

    // MARK: Subtree rebuild

    /// The nearest element at or above `n` whose box can be rebuilt on its own.
    private func rebuildRoot(from n: HTMLNode?) -> (HTMLNode, LayoutBox)? {
        var cur = n
        var k = 0
        while let e = cur, k < 4096 {
            k += 1
            if e.kind == .element, let b = nodeBoxes[ObjectIdentifier(e)], b.node === e, layoutCanRebuild(b, e) { return (e, b) }
            cur = e.parent
        }
        return nil
    }

    /// Rebuild the box subtree of `e0` (or, if its new display no longer fits, of an ancestor).
    private func rebuildAround(_ e0: HTMLNode) -> Bool {
        var cur: HTMLNode? = e0
        var tries = 0
        while let c = cur, tries < 64 {
            tries += 1
            guard let (e, old) = rebuildRoot(from: c) else { return false }
            if spliceRebuilt(e, old) { stats.subtreeRebuilds += 1; return true }
            cur = e.parent
        }
        return false
    }

    private func spliceRebuilt(_ e: HTMLNode, _ old: LayoutBox) -> Bool {
        guard let p = old.parent else { return false }
        var idx = -1
        for (i, c) in p.children.enumerated() where c === old { idx = i; break }
        if idx < 0 { return false }
        let b = LayoutBuilder(resolver: resolver, state: state, limits: limits)
        let holder = LayoutBox(kind: .block, node: nil, style: layoutAnonStyle(CSSComputedStyle(), .block))
        b.buildElement(e, into: holder, parentStyle: p, depth: old.depth, deco: p.deco, decoColor: p.decoColor, center: p.legacyCenter)
        guard holder.children.count == 1, let nb = holder.children.first, nb.node === e,
              layoutCanRebuildResult(nb) else { return false }

        // Forget the old subtree's registrations.
        var oldBoxes: Set<ObjectIdentifier> = []
        var stack: [LayoutBox] = [old]
        while let x = stack.popLast() {
            oldBoxes.insert(ObjectIdentifier(x))
            if let n = x.node, n.kind == .element, let m = nodeBoxes[ObjectIdentifier(n)], m === x { nodeBoxes.removeValue(forKey: ObjectIdentifier(n)) }
            for c in x.children { stack.append(c) }
        }
        var hadControl = false
        for c in controlBoxes where oldBoxes.contains(ObjectIdentifier(c)) { hadControl = true; break }
        p.children[idx] = nb
        nb.parent = p
        for (k, v) in b.nodeBoxes { nodeBoxes[k] = v }
        for u in b.imageURLs where !imageURLs.contains(u) { imageURLs.append(u) }
        if hadControl || !b.controls.isEmpty {
            var keep = Set<ObjectIdentifier>()
            for c in controlBoxes where !oldBoxes.contains(ObjectIdentifier(c)) { keep.insert(ObjectIdentifier(c)) }
            for c in b.controls { keep.insert(ObjectIdentifier(c)) }
            var out: [LayoutBox] = []
            var ws: [LayoutBox] = []
            if let r = root { ws.append(r) }
            while let x = ws.popLast() {
                if keep.contains(ObjectIdentifier(x)) { out.append(x) }
                var i = x.children.count - 1
                while i >= 0 { ws.append(x.children[i]); i -= 1 }
            }
            controlBoxes = out
        }
        p.items = nil
        return true
    }
}

/// Attributes whose change can only matter through style matching, so an
/// in-place restyle is enough (anything else rebuilds the element's boxes).
func layoutAttributeIsStyleOnly(_ name: String) -> Bool {
    switch name {
    case "class", "id", "style", "title", "hidden", "lang", "dir", "href", "role", "tabindex", "disabled", "checked", "selected": return true
    default:
        return name.hasPrefix("data-") || name.hasPrefix("aria-")
    }
}

/// Can this box be replaced on its own (a block-level, in-flow block in a block container)?
func layoutCanRebuild(_ b: LayoutBox, _ e: HTMLNode) -> Bool {
    guard let p = b.parent, !p.anonymous, p.node != nil, p.node === e.parent,
          p.kind == .block || p.kind == .cell || p.kind == .caption else { return false }
    return layoutCanRebuildResult(b)
}

func layoutCanRebuildResult(_ b: LayoutBox) -> Bool {
    b.kind == .block && !b.anonymous && !b.inlineLevel && !b.isOutOfFlow && b.pseudo == .none
        && b.style.display == .block && b.marker == nil
}

/// Is `n` a <style>/<link> or inside one (a <style>'s text is its descendants' text)?
func layoutInsideSource(_ n: HTMLNode) -> Bool {
    var p: HTMLNode? = n
    var k = 0
    while let q = p, k < 4096 {
        if q.kind == .element && q.namespace == .html && (q.name == "style" || q.name == "link") { return true }
        p = q.parent
        k += 1
    }
    return false
}

/// Does this subtree contain a <style> or stylesheet <link>?
func layoutSubtreeHasSource(_ n: HTMLNode) -> Bool {
    var found = false
    var steps = 0
    n.walk { x in
        steps += 1
        if steps > 20_000 || found { return false }
        if x.kind == .element && x.namespace == .html && (x.name == "style" || x.name == "link") { found = true; return false }
        return true
    }
    return found
}

func layoutPurgeClasses(_ n: HTMLNode, _ state: LayoutStyleState) {
    var steps = 0
    n.walk { x in
        steps += 1
        if steps > 20_000 { return false }
        state.classes.removeValue(forKey: ObjectIdentifier(x))
        return true
    }
}

extension LayoutEngine {
    /// True if some rule uses a sibling combinator (`+` or `~`), including inside :not()/:is().
    static func scanSiblingCombinators(_ r: CSSStyleResolver) -> Bool {
        func sel(_ s: CSSComplexSelector, _ depth: Int) -> Bool {
            for c in s.combinators where c == .adjacent || c == .general { return true }
            if depth > 4 { return false }
            for k in s.compounds {
                for n in k.negations where sel(n, depth + 1) { return true }
                for l in k.anyOf { for n in l where sel(n, depth + 1) { return true } }
            }
            return false
        }
        for e in r.ruleSet.entries where sel(e.selector, 0) { return true }
        return false
    }
}
