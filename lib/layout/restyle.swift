// Incremental :hover restyle. A hover change only matters for elements that
// entered or left the hover chain and match a compound selector containing
// :hover. Those subtrees (from the element's parent, to cover sibling
// combinators) are restyled in place; if no property that affects layout
// changed, the box tree and geometry are kept and only the display list is
// rebuilt. Otherwise the whole document is restyled.

/// Selector-matching state where every element counts as hovered.
private final class LayoutAllHovered {
    let state = LayoutStyleState()
    init() {}
}

private func layoutEqLP(_ a: CSSLP, _ b: CSSLP) -> Bool { a.px == b.px && a.pct == b.pct && a.lo == b.lo && a.hi == b.hi }
private func layoutEqDim(_ a: CSSDimension, _ b: CSSDimension) -> Bool { a.kind == b.kind && layoutEqLP(a.lp, b.lp) }

/// True if two computed styles differ in anything that affects layout (as
/// opposed to paint only: colors, backgrounds, decorations, opacity, ...).
func layoutStyleAffectsLayout(_ a: CSSComputedStyle, _ b: CSSComputedStyle) -> Bool {
    if a.display != b.display || a.position != b.position || a.float != b.float || a.clear != b.clear { return true }
    if a.boxSizing != b.boxSizing || a.overflowX != b.overflowX || a.overflowY != b.overflowY { return true }
    if !layoutEqDim(a.top, b.top) || !layoutEqDim(a.right, b.right) || !layoutEqDim(a.bottom, b.bottom) || !layoutEqDim(a.left, b.left) { return true }
    if !layoutEqDim(a.width, b.width) || !layoutEqDim(a.height, b.height) { return true }
    if !layoutEqDim(a.minWidth, b.minWidth) || !layoutEqDim(a.maxWidth, b.maxWidth) { return true }
    if !layoutEqDim(a.minHeight, b.minHeight) || !layoutEqDim(a.maxHeight, b.maxHeight) { return true }
    if !layoutEqDim(a.marginTop, b.marginTop) || !layoutEqDim(a.marginRight, b.marginRight)
        || !layoutEqDim(a.marginBottom, b.marginBottom) || !layoutEqDim(a.marginLeft, b.marginLeft) { return true }
    if !layoutEqLP(a.paddingTop, b.paddingTop) || !layoutEqLP(a.paddingRight, b.paddingRight)
        || !layoutEqLP(a.paddingBottom, b.paddingBottom) || !layoutEqLP(a.paddingLeft, b.paddingLeft) { return true }
    if a.borderTopWidth != b.borderTopWidth || a.borderRightWidth != b.borderRightWidth
        || a.borderBottomWidth != b.borderBottomWidth || a.borderLeftWidth != b.borderLeftWidth { return true }
    if a.fontFamily != b.fontFamily || a.fontSize != b.fontSize || a.fontWeight != b.fontWeight || a.fontStyle != b.fontStyle { return true }
    if a.lineHeight.kind != b.lineHeight.kind || a.lineHeight.value != b.lineHeight.value { return true }
    if a.textAlign != b.textAlign || !layoutEqLP(a.textIndent, b.textIndent) || a.textTransform != b.textTransform { return true }
    if a.whiteSpace != b.whiteSpace || a.verticalAlign.kind != b.verticalAlign.kind || a.verticalAlign.lengthPx != b.verticalAlign.lengthPx { return true }
    if a.listStyleType != b.listStyleType || a.listStylePosition != b.listStylePosition { return true }
    if a.borderCollapse != b.borderCollapse || a.borderSpacingH != b.borderSpacingH || a.borderSpacingV != b.borderSpacingV
        || a.tableLayout != b.tableLayout { return true }
    if a.flexDirection != b.flexDirection || a.flexWrap != b.flexWrap || a.flexGrow != b.flexGrow || a.flexShrink != b.flexShrink
        || !layoutEqDim(a.flexBasis, b.flexBasis) || a.justifyContent != b.justifyContent || a.alignItems != b.alignItems
        || a.alignSelf != b.alignSelf || !layoutEqLP(a.rowGap, b.rowGap) || !layoutEqLP(a.columnGap, b.columnGap) { return true }
    if a.contentKind != b.contentKind || a.contentItems != b.contentItems { return true }
    if (a.zIndex == nil) != (b.zIndex == nil) { return true }
    return false
}

extension LayoutEngine {
    /// Compounds (anywhere in a selector) that contain :hover.
    static func hoverCompounds(_ r: CSSStyleResolver) -> [CSSCompound] {
        var out: [CSSCompound] = []
        func has(_ c: CSSCompound, _ depth: Int) -> Bool {
            if c.pseudos.contains(.hover) { return true }
            if depth > 4 { return false }
            if let h = c.hostArgs { for k in h where has(k, depth + 1) { return true } }
            for s in c.negations { for k in s.compounds where has(k, depth + 1) { return true } }
            for l in c.anyOf { for s in l { for k in s.compounds where has(k, depth + 1) { return true } } }
            return false
        }
        for rs in r.allRuleSets {
            for e in rs.entries {
                for c in e.selector.compounds where has(c, 0) {
                    // `:host(:hover)` is matched against the host itself.
                    if out.count < 2000 { out.append(c.hostArgs?.first ?? c) }
                }
                if let sl = e.selector.slotted { for c in sl where has(c, 0) { if out.count < 2000 { out.append(c) } } }
            }
        }
        return out
    }

    /// Elements whose hover state changed and that a :hover compound could match.
    func hoverAffected(_ old: Set<ObjectIdentifier>, _ new: Set<ObjectIdentifier>, _ oldNode: HTMLNode?, _ newNode: HTMLNode?) -> [HTMLNode] {
        let probe = LayoutStyleState()
        probe.classes = state.classes
        var changed: [HTMLNode] = []
        func chain(_ n: HTMLNode?, _ other: Set<ObjectIdentifier>) {
            var p = n
            var k = 0
            while let e = p, k < 4096 {
                if e.kind == .element && !other.contains(ObjectIdentifier(e)) { changed.append(e) }
                p = layoutFlatParent(e) ?? e.parent
                k += 1
            }
        }
        chain(oldNode, new)
        chain(newNode, old)
        var out: [HTMLNode] = []
        for e in changed {
            // Match with every element treated as hovered.
            probe.hovered = [ObjectIdentifier(e)]
            let el = LayoutElement(e, probe)
            for c in hoverCompoundList {
                var budget = 5000
                if cssMatchCompound(c, el, &budget) { out.append(e); break }
            }
        }
        state.classes = probe.classes.count > state.classes.count ? probe.classes : state.classes
        return out
    }

    /// Restyle the subtrees under `roots` in place. Returns false if a
    /// layout-affecting property changed (the caller then restyles everything).
    /// `widen` starts at the parent of each root (hover: sibling combinators);
    /// otherwise the roots are restyled as given.
    func restyleInPlace(_ roots: [HTMLNode], widen: Bool = true) -> Bool {
        var done: Set<ObjectIdentifier> = []
        for r0 in roots {
            var r = r0
            if widen, let fp = layoutFlatParent(r0), fp.kind == .element { r = fp }
            if done.contains(ObjectIdentifier(r)) { continue }
            done.insert(ObjectIdentifier(r))
            if !r.isInFlatTree { continue }   // not rendered (an unslotted light child): no boxes to fix
            if !widen && box(for: r) == nil {
                // A boxless element with flat-tree children may be display: contents
                // (a slot, say) whose children are rendered: rebuild instead.
                if !r.flatTreeChildren.isEmpty { return false }
                // No box: fine if the element (or its parent) stays unrendered.
                guard let pn = layoutFlatParent(r), pn.kind == .element else { return false }
                if let pb = box(for: pn) {
                    let sp = styleParent(pb)
                    let s = resolver.computeStyle(LayoutElement(r, state), parent: sp?.style, hints: layoutHints(r))
                    if s.display != .none { return false }
                } else if !unrenderedNode(pn) { return false }
                continue
            }
            guard let rb = box(for: r) else { return false }
            var stack: [(HTMLNode, LayoutBox)] = [(r, rb)]
            var steps = 0
            while let (n, parentBox) = stack.popLast() {
                steps += 1
                if steps > 200_000 { return false }
                guard let b = box(for: n), b.node === n else {
                    // No box: fine if it is still display: none, else rebuild everything.
                    if n === r { return false }
                    let s = resolver.computeStyle(LayoutElement(n, state), parent: parentBox.style, hints: layoutHints(n))
                    if s.display != .none { return false }
                    continue
                }
                // Style inherits through the flat-tree parent. An element whose parent has no
                // box (display: contents, a slot) cannot be restyled in place from the box tree.
                var parentStyleBox: LayoutBox? = nil
                if let dp = layoutFlatParent(n), dp.kind == .element {
                    guard let pb = box(for: dp), pb.node === dp else { return false }
                    parentStyleBox = styleParent(pb)
                }
                if n !== r || b.parent != nil || !widen {
                    if !restyleOne(b, n, parentStyleBox) { return false }
                }
                for c in n.flatTreeChildren.reversed() where c.kind == .element { stack.append((c, b)) }
            }
            if restyleDecoChanged { restyleDecoChanged = false; if !widen || !refreshDecorations(rb) { return false } }
        }
        return true
    }

    /// An element without a box whose own display is none (computed against its parent's box).
    func unrenderedNode(_ n: HTMLNode) -> Bool {
        guard box(for: n) == nil, let gp = layoutFlatParent(n), gp.kind == .element, let gb = box(for: gp) else { return false }
        let s = resolver.computeStyle(LayoutElement(n, state), parent: styleParent(gb)?.style, hints: layoutHints(n))
        return s.display == .none
    }

    func styleParent(_ b: LayoutBox?) -> LayoutBox? {
        var p = b
        while let q = p, q.anonymous { p = q.parent }
        return p
    }

    private func restyleOne(_ b: LayoutBox, _ n: HTMLNode, _ parent: LayoutBox?) -> Bool {
        var s = resolver.computeStyle(LayoutElement(n, state), parent: parent?.style, hints: layoutHints(n))
        if s.fontSize > limits.maxFontSize { s.fontSize = limits.maxFontSize }
        if s.fontSize != s.fontSize { s.fontSize = 16 }
        if layoutStyleAffectsLayout(b.style, s) { return false }
        if s.backgroundImage != b.style.backgroundImage, s.backgroundImage != nil { return false }
        // A ::before/::after that appears or disappears changes the box tree.
        var hasBefore = false, hasAfter = false
        var nestedPseudo = false
        layoutFindPseudos(b, &hasBefore, &hasAfter, &nestedPseudo, 0)
        if nestedPseudo { return false }
        if b.kind != .replaced && b.kind != .lineBreak {
            for which in [CSSPseudoElement.before, CSSPseudoElement.after] {
                let ps = resolver.computePseudoStyle(LayoutElement(n, state), which, elementStyle: s)
                let exists = ps != nil && ps!.display != .none
                if exists != (which == .before ? hasBefore : hasAfter) { return false }
            }
        }
        if s.textDecoration != b.style.textDecoration || (s.textDecoration.rawValue != 0 && s.color != b.style.color) { restyleDecoChanged = true }
        b.style = s
        for c in b.children {
            if c.kind == .text && (c.node?.flatTreeParent === n || c.pseudo == .marker) { c.style = s }
            if c.pseudo == .before || c.pseudo == .after {
                guard let ps = resolver.computePseudoStyle(LayoutElement(n, state), c.pseudo == .before ? .before : .after,
                                                           elementStyle: s) else { return false }
                if layoutStyleAffectsLayout(c.style, ps) { return false }
                c.style = ps
                for t in c.children where t.kind == .text { t.style = ps }
            }
            if c.anonymous {
                // Anonymous wrappers inherit; their text children follow the element.
                if !restyleAnon(c, s, n) { return false }
            }
        }
        if let m = b.marker { m.style = s }
        return true
    }

    /// Anonymous wrappers (possibly nested) inherit from the element; its text follows it.
    private func restyleAnon(_ c: LayoutBox, _ s: CSSComputedStyle, _ n: HTMLNode) -> Bool {
        let anon = layoutAnonStyle(s, c.style.display)
        if layoutStyleAffectsLayout(c.style, anon) { return false }
        c.style = anon
        for t in c.children {
            if t.kind == .text && t.node?.flatTreeParent === n { t.style = s }
            else if t.anonymous && t.kind != .text { if !restyleAnon(t, s, n) { return false } }
        }
        return true
    }

    /// Recompute propagated text-decoration under `b`. False if anonymous
    /// boxes are involved (their deco is derived at build time): rebuild then.
    private func refreshDecorations(_ b: LayoutBox) -> Bool {
        var stack: [(LayoutBox, UInt8, CSSColor)] = []
        var d0: UInt8 = 0, c0 = CSSColor.black
        if let p = b.parent { d0 = p.deco; c0 = p.decoColor }
        stack.append((b, d0, c0))
        while let (x, d, c) = stack.popLast() {
            var nd = d, nc = c
            if x.kind != .text {
                if x.isOutOfFlow || x.isAtomicInline { nd = 0 }
                if x.style.textDecoration.rawValue != 0 && !x.anonymous { nd |= x.style.textDecoration.rawValue; nc = x.style.color }
            }
            if x.anonymous && x.kind != .text && x !== b { return false }
            x.deco = nd
            x.decoColor = nc
            for ch in x.children { stack.append((ch, nd, nc)) }
        }
        return true
    }
}

/// ::before/::after boxes among `b`'s children, looking through anonymous wrappers.
func layoutFindPseudos(_ b: LayoutBox, _ before: inout Bool, _ after: inout Bool, _ nested: inout Bool, _ depth: Int) {
    for c in b.children {
        if c.pseudo == .before { before = true; if depth > 0 { nested = true } }
        if c.pseudo == .after { after = true; if depth > 0 { nested = true } }
        if c.anonymous && c.pseudo == .none && c.kind != .text && depth < 6 { layoutFindPseudos(c, &before, &after, &nested, depth + 1) }
    }
}
