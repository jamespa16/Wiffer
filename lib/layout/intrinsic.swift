// Intrinsic (min-content / max-content) border-box widths, cached per layout
// pass. Used for shrink-to-fit (floats, inline-blocks, absolutely positioned
// boxes), table columns and flex bases.

extension LayoutContext {
    /// (min-content, max-content) border-box widths of `b`.
    func intrinsic(_ b: LayoutBox) -> (Double, Double) {
        if b.intrinsicGen == gen { return (b.minContent, b.maxContent) }
        b.intrinsicGen = gen          // set first: a (malformed) cycle sees zeros
        b.minContent = 0; b.maxContent = 0
        resolveEdges(b, 0)
        let bp = b.border.horizontal + b.padding.horizontal
        var mn = 0.0, mx = 0.0
        if b.kind == .replaced {
            let (w, _) = replacedSize(b, cbW: 0, cbH: nil)
            mn = w + bp; mx = mn
        } else if b.kind == .table {
            (mn, mx) = tableIntrinsic(b)
        } else if b.style.width.kind == .length && !b.style.width.hasPercent, let w = specifiedContentWidth(b, 0) {
            mn = w + bp; mx = mn
            if b.kind == .cell { let (cmn, _) = contentIntrinsic(b); mn = max(mn, cmn + bp); mx = max(mx, mn) }
        } else {
            let (cmn, cmx) = contentIntrinsic(b)
            mn = cmn + bp; mx = cmx + bp
        }
        // min/max-width (fixed lengths only)
        let bs = b.style.boxSizing == .borderBox ? 0 : bp
        if b.style.maxWidth.kind == .length && !b.style.maxWidth.hasPercent, let v = b.style.maxWidth.resolve(0) {
            mn = min(mn, layoutSan(v) + bs); mx = min(mx, layoutSan(v) + bs)
        }
        if b.style.minWidth.kind == .length && !b.style.minWidth.hasPercent, let v = b.style.minWidth.resolve(0) {
            mn = max(mn, layoutSan(v) + bs); mx = max(mx, layoutSan(v) + bs)
        }
        mn = layoutPos(mn); mx = max(mn, layoutPos(mx))
        b.minContent = mn; b.maxContent = mx
        return (mn, mx)
    }

    /// A child's contribution to its parent's intrinsic widths (margin box; px margins only).
    func contribution(_ c: LayoutBox) -> (Double, Double) {
        let (mn, mx) = intrinsic(c)
        let ml = c.style.marginLeft.kind == .length && !c.style.marginLeft.hasPercent ? layoutSan(c.style.marginLeft.lp.px) : 0
        let mr = c.style.marginRight.kind == .length && !c.style.marginRight.hasPercent ? layoutSan(c.style.marginRight.lp.px) : 0
        let m = ml + mr
        return (max(0, mn + m), max(0, mx + m))
    }

    /// Content-box intrinsic widths from the children.
    func contentIntrinsic(_ b: LayoutBox) -> (Double, Double) {
        var mn = 0.0, mx = 0.0
        switch b.kind {
        case .flex:
            let row = b.style.flexDirection == .row || b.style.flexDirection == .rowReverse
            let gap = layoutPos(b.style.columnGap.px)
            var n = 0
            for c in b.children where !c.isAbs {
                let (cmn, cmx) = contribution(c)
                if row {
                    mx += cmx
                    if b.style.flexWrap == .nowrap { mn += cmn } else { mn = max(mn, cmn) }
                } else { mn = max(mn, cmn); mx = max(mx, cmx) }
                n += 1
            }
            if row && n > 1 { mx += gap * Double(n - 1); if b.style.flexWrap == .nowrap { mn += gap * Double(n - 1) } }
        case .block, .cell, .caption:
            if b.childrenInline { return inlineIntrinsic(b) }
            var floatRow = 0.0
            for c in b.children {
                if c.isAbs { continue }
                let (cmn, cmx) = contribution(c)
                mn = max(mn, cmn)
                if c.isFloat { floatRow += cmx; mx = max(mx, floatRow) }
                else { floatRow = 0; mx = max(mx, cmx) }
            }
        default:
            break
        }
        return (layoutPos(mn), layoutPos(mx))
    }
}
