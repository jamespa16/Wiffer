// Block layout: widths (auto, fixed, %, min/max, box-sizing, auto margins),
// heights, margin collapsing (siblings, parent/first child, parent/last
// child, empty blocks), floats and clear, block formatting contexts,
// replaced elements, and absolute/fixed positioning.

/// Floats of one block formatting context, as margin boxes in the BFC root's
/// border-box coordinates.
final class LayoutFloats {
    struct Float_ { var x: Double; var y: Double; var w: Double; var h: Double; var left: Bool }
    var list: [Float_] = []
    let cap: Int
    init(cap: Int) { self.cap = cap }
    var isEmpty: Bool { list.isEmpty }

    /// Available [left, right) for a band [y, y + h), starting from [l0, r0).
    func edges(y: Double, h: Double, l0: Double, r0: Double) -> (Double, Double) {
        var l = l0, r = r0
        let hh = max(h, 0.01)
        for f in list where f.y < y + hh && f.y + f.h > y && f.h > 0 {
            if f.left { l = max(l, f.x + f.w) } else { r = min(r, f.x) }
        }
        return (l, max(l, r))
    }

    func hasFloats(y: Double, h: Double) -> Bool {
        let hh = max(h, 0.01)
        for f in list where f.y < y + hh && f.y + f.h > y && f.h > 0 { return true }
        return false
    }

    /// The lowest float bottom below `y` that ends inside the band, or nil.
    func nextBottom(after y: Double, h: Double) -> Double? {
        var best: Double? = nil
        let hh = max(h, 0.01)
        for f in list where f.y < y + hh && f.y + f.h > y && f.h > 0 {
            let b = f.y + f.h
            if best == nil || b < best! { best = b }
        }
        return best
    }

    func clearY(_ c: CSSClear) -> Double {
        var y = -layoutMaxCoord
        for f in list {
            if c == .both || (c == .left && f.left) || (c == .right && !f.left) { y = max(y, f.y + f.h) }
        }
        return y
    }

    var maxBottom: Double {
        var y = 0.0
        for f in list { y = max(y, f.y + f.h) }
        return y
    }

    /// Place a float of outer size (w, h) at or below minY; returns its margin-box origin.
    func place(w: Double, h: Double, left: Bool, minY: Double, l0: Double, r0: Double) -> (Double, Double) {
        var y = minY
        for f in list { y = max(y, f.y) }       // not above an earlier float
        if list.count >= cap {
            let x = left ? l0 : r0 - w
            return (x, y)
        }
        var guardN = 0
        while guardN <= list.count + 1 {
            let (l, r) = edges(y: y, h: h, l0: l0, r0: r0)
            if r - l >= w - 0.01 || !hasFloats(y: y, h: h) {
                let x = left ? l : r - w
                list.append(Float_(x: x, y: y, w: w, h: h, left: left))
                return (x, y)
            }
            guard let nb = nextBottom(after: y, h: h), nb > y else { break }
            y = nb
            guardN += 1
        }
        let x = left ? l0 : r0 - w
        list.append(Float_(x: x, y: y, w: w, h: h, left: left))
        return (x, y)
    }
}

struct LayoutFontMetrics {
    var ascent: Double, descent: Double, xHeight: Double
}

/// Shared state of one layout pass (and caches across passes).
final class LayoutContext {
    let text: TextEngine
    var limits: LayoutLimits
    var gen = 0
    var viewportW = 1024.0, viewportH = 768.0
    var imageSize: ((String) -> (Int, Int)?)? = nil
    var initialAbs: [LayoutBox] = []
    var fixedBoxes: [LayoutBox] = []
    private var chains: [String: FontChain] = [:]
    private var metricsCache: [String: LayoutFontMetrics] = [:]
    var steps = 0

    init(text: TextEngine, limits: LayoutLimits) {
        self.text = text
        self.limits = limits
    }

    // MARK: Fonts

    // Font helpers take the box (not its 944-byte style) so that recursive
    // layout frames never hold style copies.
    private func fontKey(_ b: LayoutBox) -> String {
        var k = b.style.fontWeight >= 600 ? "b" : "r"
        k += b.style.fontStyle == .normal ? "n" : "i"
        for f in b.style.fontFamily { k += "|"; k += f }
        return k
    }

    func chain(_ b: LayoutBox) -> FontChain {
        let k = fontKey(b)
        if let c = chains[k] { return c }
        let c = text.registry.chain(families: b.style.fontFamily, weight: b.style.fontWeight >= 600 ? 700 : 400,
                                    italic: b.style.fontStyle != .normal)
        chains[k] = c
        return c
    }

    func fontSize(_ b: LayoutBox) -> Float {
        let v = b.style.fontSize
        if v != v || v < 0 { return 0 }
        return Float(min(v, limits.maxFontSize))
    }

    @inline(never)
    func metrics(_ b: LayoutBox) -> LayoutFontMetrics {
        let size = Double(fontSize(b))
        let k = fontKey(b)
        var unit: LayoutFontMetrics
        if let m = metricsCache[k] { unit = m } else {
            let c = chain(b)
            if let f = c.fonts.first {
                let upm = Double(max(1, f.face.font.unitsPerEm))
                unit = LayoutFontMetrics(ascent: Double(f.face.font.ascent) / upm, descent: Double(f.face.font.descent) / upm,
                                         xHeight: Double(f.face.font.xHeight) / upm)
                if unit.xHeight <= 0 { unit.xHeight = 0.5 }
            } else {
                unit = LayoutFontMetrics(ascent: 0.9, descent: 0.25, xHeight: 0.5)
            }
            metricsCache[k] = unit
        }
        return LayoutFontMetrics(ascent: unit.ascent * size, descent: abs(unit.descent) * size, xHeight: unit.xHeight * size)
    }

    func lineHeight(_ b: LayoutBox) -> Double {
        let fs = Double(fontSize(b))
        switch b.style.lineHeight.kind {
        case .normal: return fs * 1.2
        case .number: return layoutPos(fs * b.style.lineHeight.value)
        case .length: return layoutPos(b.style.lineHeight.value)
        }
    }

    @inline(never)
    func shape(_ scalars: [UInt32], _ b: LayoutBox) -> TextRun {
        text.shape(scalars, chain: chain(b), size: fontSize(b))
    }

    // MARK: Edges

    func resolveEdges(_ b: LayoutBox, _ cbW: Double) {
        let w = layoutPos(cbW)
        b.margin.t = layoutSan(b.style.marginTop.resolve(w) ?? 0)
        b.margin.r = layoutSan(b.style.marginRight.resolve(w) ?? 0)
        b.margin.b = layoutSan(b.style.marginBottom.resolve(w) ?? 0)
        b.margin.l = layoutSan(b.style.marginLeft.resolve(w) ?? 0)
        if b.kind == .inline || b.kind == .text {
            // vertical margins of inline boxes have no effect
        }
        b.border.t = layoutPos(b.style.borderTopWidth)
        b.border.r = layoutPos(b.style.borderRightWidth)
        b.border.b = layoutPos(b.style.borderBottomWidth)
        b.border.l = layoutPos(b.style.borderLeftWidth)
        b.padding.t = layoutPos(b.style.paddingTop.resolve(w))
        b.padding.r = layoutPos(b.style.paddingRight.resolve(w))
        b.padding.b = layoutPos(b.style.paddingBottom.resolve(w))
        b.padding.l = layoutPos(b.style.paddingLeft.resolve(w))
        if b.kind == .text { b.margin = LayoutEdges(); b.border = LayoutEdges(); b.padding = LayoutEdges() }
        if b.kind == .cell || b.kind == .row || b.kind == .rowGroup { b.margin = LayoutEdges() }
        if b.dropBorders != 0 {
            if b.dropBorders & 1 != 0 { b.border.t = 0 }
            if b.dropBorders & 2 != 0 { b.border.r = 0 }
            if b.dropBorders & 4 != 0 { b.border.b = 0 }
            if b.dropBorders & 8 != 0 { b.border.l = 0 }
        }
    }

    func establishesBFC(_ b: LayoutBox) -> Bool {
        if b.parent == nil || b.isFloat || b.isAbs { return true }
        if b.inlineLevel && b.kind != .inline && b.kind != .text { return true }
        if b.kind == .cell || b.kind == .caption || b.kind == .flex || b.kind == .table || b.kind == .replaced { return true }
        if let p = b.parent, p.kind == .flex { return true }
        if b.style.overflowX != .visible || b.style.overflowY != .visible { return true }
        return false
    }

    /// Specified width as a content-box width, or nil for auto.
    func specifiedContentWidth(_ b: LayoutBox, _ cbW: Double) -> Double? {
        guard let w = b.style.width.resolve(cbW) else { return nil }
        var v = layoutSan(w)
        if b.style.boxSizing == .borderBox && b.kind != .table { v -= b.border.horizontal + b.padding.horizontal }
        return max(0, v)
    }

    func clampWidth(_ b: LayoutBox, _ cw: Double, _ cbW: Double) -> Double {
        var v = cw
        let bs = b.style.boxSizing == .borderBox ? b.border.horizontal + b.padding.horizontal : 0
        if let mx = b.style.maxWidth.resolve(cbW) { v = min(v, layoutSan(mx) - bs) }
        if let mn = b.style.minWidth.resolve(cbW) { v = max(v, layoutSan(mn) - bs) }
        return max(0, v)
    }

    func clampHeight(_ b: LayoutBox, _ ch: Double, _ cbH: Double?) -> Double {
        var v = ch
        let bs = b.style.boxSizing == .borderBox ? b.border.vertical + b.padding.vertical : 0
        if b.style.maxHeight.kind == .length, !(b.style.maxHeight.hasPercent && cbH == nil),
           let mx = b.style.maxHeight.resolve(cbH ?? 0) { v = min(v, layoutSan(mx) - bs) }
        if b.style.minHeight.kind == .length, !(b.style.minHeight.hasPercent && cbH == nil),
           let mn = b.style.minHeight.resolve(cbH ?? 0) { v = max(v, layoutSan(mn) - bs) }
        return max(0, v)
    }

    /// Specified height as a content-box height (nil for auto, or a
    /// percentage of an indefinite containing block).
    func specifiedContentHeight(_ b: LayoutBox, _ cbH: Double?) -> Double? {
        let d = b.style.height
        guard d.kind == .length else { return nil }
        if d.hasPercent && cbH == nil { return nil }
        var v = layoutSan(d.lp.resolve(cbH ?? 0))
        if b.style.boxSizing == .borderBox && b.kind != .table { v -= b.border.vertical + b.padding.vertical }
        return max(0, v)
    }

    // MARK: Shrink-to-fit

    /// Border-box width for shrink-to-fit with `avail` (border box + nothing else).
    func fitWidth(_ b: LayoutBox, avail: Double) -> Double {
        let (mn, mx) = intrinsic(b)
        return max(mn, min(max(0, avail), mx))
    }

    // MARK: Block-level boxes

    /// Lay out a block-level box. Sets w, h, margins, children and b.x
    /// (margin-left offset plus any centering, relative to the containing
    /// block's content-left); the caller sets b.y and adds its own x offset.
    /// `cbOX` is the containing block content-left and `oy` the box's
    /// border-box top, both in the float context's coordinates.
    func layoutBlock(_ b: LayoutBox, cbW cbW0: Double, cbH: Double?, floats: LayoutFloats, cbOX: Double, oy: Double,
                     avail availIn: Double? = nil, shrink: Bool = false, forceW: Double? = nil) {
        steps += 1
        let cbW = layoutPos(cbW0)
        let bfcRoot = establishesBFC(b)
        if bfcRoot && b.layoutGen == gen && b.layoutKeyW == cbW && b.layoutKeyH == (cbH ?? -1)
            && b.layoutKeyAvail == (availIn ?? -1) && b.layoutKeyForce == (forceW ?? -1) && b.layoutKeyShrink == shrink {
            return
        }
        b.layoutGen = gen
        b.layoutKeyW = cbW; b.layoutKeyH = cbH ?? -1; b.layoutKeyAvail = availIn ?? -1
        b.layoutKeyForce = forceW ?? -1; b.layoutKeyShrink = shrink
        resolveEdges(b, cbW)
        b.lines = []
        b.childOffsetY = 0
        b.collapseThrough = false
        if b.kind == .table { layoutTable(b, cbW: cbW, cbH: cbH, avail: availIn, shrink: shrink, forceW: forceW); return }
        if b.kind == .replaced { layoutReplacedBlock(b, cbW: cbW, cbH: cbH, avail: availIn); return }

        let avail = layoutPos(availIn ?? cbW)
        let mlAuto = b.style.marginLeft.isAuto, mrAuto = b.style.marginRight.isAuto
        let bp = b.border.horizontal + b.padding.horizontal
        var cw: Double
        let specW = specifiedContentWidth(b, cbW)
        if let f = forceW {
            cw = max(0, f - bp)
        } else if let w = specW {
            cw = w
        } else if shrink || b.style.width.kind == .minContent || b.style.width.kind == .maxContent || b.style.width.kind == .fitContent {
            let room = avail - b.margin.horizontal
            switch b.style.width.kind {
            case .minContent: cw = intrinsic(b).0 - bp
            case .maxContent: cw = intrinsic(b).1 - bp
            default: cw = fitWidth(b, avail: room) - bp
            }
        } else {
            cw = avail - b.margin.horizontal - bp
        }
        if forceW == nil { cw = clampWidth(b, cw, cbW) }
        cw = max(0, layoutSan(cw))
        b.w = cw + bp

        // Auto margins (and legacy <center> alignment) for in-flow blocks.
        if forceW == nil && !shrink && !b.isFloat && !b.isAbs {
            let free = avail - b.w - (mlAuto ? 0 : b.margin.l) - (mrAuto ? 0 : b.margin.r)
            if mlAuto && mrAuto { b.margin.l = max(0, free / 2); b.margin.r = max(0, free / 2) }
            else if mlAuto { b.margin.l = free }
            else if mrAuto { b.margin.r = free }
            else if let p = b.parent, p.legacyCenter, b.margin.l == 0, b.margin.r == 0, b.w < avail {
                b.margin.l = (avail - b.w) / 2
            }
        }
        b.x = b.margin.l

        // Content.
        let inner = bfcRoot ? LayoutFloats(cap: limits.maxFloatsPerContext) : floats
        let ox = bfcRoot ? 0.0 : cbOX + b.margin.l
        let boy = bfcRoot ? 0.0 : oy
        let specH = specifiedContentHeight(b, cbH)
        let childCbH = specH
        var contentH = 0.0
        if b.kind == .flex {
            contentH = layoutFlex(b, contentW: cw, contentH: specH, cbH: cbH, minH: clampHeight(b, 0, cbH), maxCbH: cbH)
        } else if b.childrenInline {
            contentH = layoutInline(b, contentW: cw, cbH: childCbH, floats: inner, ox: ox, oy: boy)
        } else {
            contentH = layoutBlockChildren(b, contentW: cw, cbH: childCbH, floats: inner, ox: ox, oy: boy, bfcRoot: bfcRoot)
        }
        if bfcRoot && specH == nil {
            let ct = b.border.t + b.padding.t
            contentH = max(contentH, inner.maxBottom - ct)
        }
        var ch = specH ?? contentH
        if b.kind == .cell { ch = max(ch, contentH) }
        ch = clampHeight(b, ch, cbH)
        b.h = layoutPos(ch + b.border.vertical + b.padding.vertical)
        if b.kind == .flex, specH == nil, ch != contentH { flexStretchAfterHeight(b, ch) }
        // Outside list marker.
        if let m = b.marker { placeMarker(b, m) }
        if !b.absChildren.isEmpty { layoutAbsChildren(b) }
    }

    /// The top margin of `c` combined with the margins of its first in-flow
    /// descendants that collapse with it.
    func topMarginChain(_ c: LayoutBox, _ cbW: Double) -> LayoutMargin {
        var m = LayoutMargin()
        var cur = c
        var w = cbW
        var k = 0
        while k < limits.maxDepth + 8 {
            k += 1
            m.add(layoutSan(cur.style.marginTop.resolve(w) ?? 0))
            if establishesBFC(cur) || !cur.isBlockContainer || cur.childrenInline || cur.kind != .block { break }
            if cur.style.borderTopWidth > 0 || cur.style.paddingTop.resolve(w) > 0 { break }
            var next: LayoutBox? = nil
            for ch in cur.children where !ch.isOutOfFlow { next = ch; break }
            guard let n = next, !n.inlineLevel else { break }
            if let sw = cur.style.width.resolve(w) { w = layoutPos(sw) }
            cur = n
        }
        return m
    }

    func layoutBlockChildren(_ b: LayoutBox, contentW: Double, cbH: Double?, floats: LayoutFloats, ox: Double, oy: Double,
                             bfcRoot: Bool) -> Double {
        let cl = b.border.l + b.padding.l
        let ct = b.border.t + b.padding.t
        var y = ct
        var pending = LayoutMargin()
        var first = true
        let collapseTop = !bfcRoot && b.border.t == 0 && b.padding.t == 0
        for c in b.children {
            if c.isAbs {
                c.staticParent = b
                c.staticX = cl
                c.staticY = y + pending.value
                continue
            }
            if c.isFloat {
                let fy = y + (first && collapseTop ? 0 : pending.value)
                layoutFloat(c, cbW: contentW, cbH: cbH, floats: floats, minY: oy + fy, l0: ox + cl, r0: ox + cl + contentW)
                c.x -= ox
                c.y -= oy
                continue
            }
            let chain = topMarginChain(c, contentW)
            var top: Double
            if first && collapseTop { top = y } else { var m = pending; m.merge(chain); top = y + m.value }
            if c.style.clear != .none && !floats.isEmpty {
                let cy = floats.clearY(c.style.clear) - oy
                if top < cy { top = cy }
            }
            var avail: Double? = nil
            var dx = 0.0
            if establishesBFC(c) && !floats.isEmpty && floats.hasFloats(y: oy + top, h: 1) {
                let (l, r) = floats.edges(y: oy + top, h: 1, l0: ox + cl, r0: ox + cl + contentW)
                dx = l - (ox + cl)
                avail = r - l
            }
            layoutBlock(c, cbW: contentW, cbH: cbH, floats: floats, cbOX: ox + cl + dx, oy: oy + top, avail: avail)
            c.x += cl + dx
            c.y = top
            if c.collapseThrough {
                var m = (first && collapseTop) ? LayoutMargin() : pending
                if !(first && collapseTop) { m.merge(chain) }
                m.add(c.margin.b)
                pending = m
                c.y = top
                first = false
                continue
            }
            y = top + c.h
            pending = c.collapsedBottom
            first = false
        }
        let zeroHeight = b.style.height.isAuto || (b.style.height.kind == .length && b.style.height.lp.px == 0 && b.style.height.lp.pct == 0)
        let collapseBottom = !bfcRoot && b.border.b == 0 && b.padding.b == 0 && zeroHeight
        var h: Double
        b.collapsedBottom = LayoutMargin(b.margin.b)
        if collapseBottom {
            b.collapsedBottom.merge(pending)
            h = y - ct
        } else {
            h = y + pending.value - ct
        }
        h = max(0, h)
        if first && h == 0 && collapseTop && collapseBottom && b.style.minHeight.resolve(0) ?? 0 <= 0 && b.marker == nil {
            b.collapseThrough = true
        }
        return h
    }

    func layoutFloat(_ c: LayoutBox, cbW: Double, cbH: Double?, floats: LayoutFloats, minY: Double, l0: Double, r0: Double) {
        layoutBlock(c, cbW: cbW, cbH: cbH, floats: floats, cbOX: l0, oy: 0, avail: max(0, r0 - l0), shrink: true)
        var my = minY
        if c.style.clear != .none { my = max(my, floats.clearY(c.style.clear)) }
        let ow = max(0, c.w + c.margin.horizontal), oh = max(0, c.h + c.margin.vertical)
        let (fx, fy) = floats.place(w: ow, h: oh, left: c.style.float == .left, minY: my, l0: l0, r0: r0)
        c.x = fx + c.margin.l
        c.y = fy + c.margin.t
    }

    // MARK: Replaced elements

    /// Content-box size of a replaced element.
    func replacedSize(_ b: LayoutBox, cbW: Double, cbH: Double?) -> (Double, Double) {
        var iw: Double? = nil, ih: Double? = nil
        let fs = Double(fontSize(b))
        switch b.replaced {
        case .image:
            if let src = b.src, let p = imageSize, let (w, h) = p(src), w >= 0, h >= 0 {
                iw = Double(min(w, 100_000)); ih = Double(min(h, 100_000))
            } else if !b.label.isEmpty && b.style.width.isAuto && b.style.height.isAuto {
                if b.labelRun == nil { b.labelRun = shape(textScalars(b.label), b) }
                iw = Double(b.labelRun!.width) + 4; ih = lineHeight(b)
            } else if b.style.width.isAuto && b.style.height.isAuto {
                iw = 0; ih = 0
            }
        case .textInput, .password:
            let size = Double(max(1, min(layoutParseInt(b.node?.attribute("size") ?? "") ?? 20, 1000)))
            let cw = Double(shape([0x30], b).width)
            iw = size * (cw > 0 ? cw : fs * 0.55); ih = fs * 1.2
        case .textarea:
            let cols = Double(max(1, min(layoutParseInt(b.node?.attribute("cols") ?? "") ?? 20, 1000)))
            let rows = Double(max(1, min(layoutParseInt(b.node?.attribute("rows") ?? "") ?? 2, 1000)))
            let cw = Double(shape([0x30], b).width)
            iw = cols * (cw > 0 ? cw : fs * 0.55); ih = rows * fs * 1.2
        case .checkbox, .radio: iw = 13; ih = 13
        case .button:
            if b.labelRun == nil { b.labelRun = shape(textScalars(b.label), b) }
            iw = Double(b.labelRun!.width); ih = fs * 1.2
        case .select:
            var wmax = 0.0
            for o in b.options.prefix(200) { wmax = max(wmax, Double(shape(textScalars(o), b).width)) }
            if b.labelRun == nil { b.labelRun = shape(textScalars(b.label), b) }
            iw = wmax + 20; ih = fs * 1.2
        case .frame: iw = 300; ih = 150
        case .svg:
            // width/height attributes, else the viewBox ratio across the
            // containing block (as other browsers do), else 300x150.
            let (w0, h0, r0) = layoutSVGIntrinsic(b)
            if let w = w0, let h = h0 { iw = w; ih = h }
            else if let r = r0, r > 0 {
                if let w = w0 { iw = w; ih = w / r }
                else if let h = h0 { ih = h; iw = h * r }
                else {
                    let cw = layoutPos(cbW)
                    iw = cw > 0 ? cw : 300; ih = iw! / r
                }
            } else { iw = w0 ?? 300; ih = h0 ?? 150 }
        default: iw = 80; ih = 16
        }
        var ratio: Double? = (iw != nil && ih != nil && iw! > 0 && ih! > 0) ? iw! / ih! : nil
        if b.replaced == .svg, let r = layoutSVGIntrinsic(b).2, r > 0, r.isFinite { ratio = r }
        var w = specifiedContentWidth(b, cbW)
        var h = specifiedContentHeight(b, cbH)
        let wAuto = w == nil, hAuto = h == nil
        if w == nil && h == nil { w = iw ?? 0; h = ih ?? 0 }
        else if w == nil { w = ratio.map { h! * $0 } ?? (iw ?? 0) }
        else if h == nil { h = ratio.map { w! / $0 } ?? (ih ?? 0) }
        var fw = clampWidth(b, w!, cbW)
        var fh = h!
        if fw != w! && hAuto, let r = ratio { fh = fw / r }
        let ch = clampHeight(b, fh, cbH)
        if ch != fh && wAuto, let r = ratio { fw = clampWidth(b, ch * r, cbW) }
        fh = ch
        return (layoutPos(fw), layoutPos(fh))
    }

    func layoutReplacedBlock(_ b: LayoutBox, cbW: Double, cbH: Double?, avail: Double?) {
        let (cw, ch) = replacedSize(b, cbW: cbW, cbH: cbH)
        b.w = cw + b.border.horizontal + b.padding.horizontal
        b.h = ch + b.border.vertical + b.padding.vertical
        if !b.inlineLevel && !b.isFloat && !b.isAbs {
            let room = layoutPos(avail ?? cbW)
            let free = room - b.w - (b.style.marginLeft.isAuto ? 0 : b.margin.l) - (b.style.marginRight.isAuto ? 0 : b.margin.r)
            if b.style.marginLeft.isAuto && b.style.marginRight.isAuto { b.margin.l = max(0, free / 2); b.margin.r = max(0, free / 2) }
            else if b.style.marginLeft.isAuto { b.margin.l = free }
            else if let p = b.parent, p.legacyCenter, b.margin.l == 0, b.margin.r == 0, b.w < room { b.margin.l = (room - b.w) / 2 }
        }
        b.x = b.margin.l
        b.collapsedBottom = LayoutMargin(b.margin.b)
    }

    // MARK: List markers

    func placeMarker(_ li: LayoutBox, _ m: LayoutBox) {
        if m.run == nil || m.run!.scalars != m.raw { m.run = shape(m.raw, m) }
        guard let r = m.run else { return }
        let met = metrics(m)
        let w = Double(r.width)
        let base = firstBaseline(li) ?? (li.border.t + li.padding.t + (lineHeight(li) - met.ascent - met.descent) / 2 + met.ascent)
        m.w = w
        m.h = met.ascent + met.descent
        m.x = li.border.l + li.padding.l - w
        m.y = base - met.ascent
        m.frags = [LayoutFrag()]
        m.frags[0].x = m.x; m.frags[0].y = m.y; m.frags[0].w = w; m.frags[0].h = m.h
        m.frags[0].baseline = base
        m.frags[0].start = 0; m.frags[0].end = Int32(truncatingIfNeeded: r.count)
    }

    // MARK: Baselines

    /// First line baseline, relative to the box's border-box top.
    func firstBaseline(_ b: LayoutBox) -> Double? {
        var cur = b
        var off = 0.0
        var k = 0
        while k < limits.maxDepth + 8 {
            k += 1
            if let l = cur.lines.first { return off + l.baseline + cur.childOffsetY }
            if cur.kind == .replaced || cur.kind == .text { return nil }
            var next: LayoutBox? = nil
            for c in cur.children where !c.isOutOfFlow && c.kind != .text { next = c; break }
            if cur.kind == .table, let t = cur.table, let r = t.rows.first {
                for c in r.children where c.kind == .cell { next = c; break }
                if let n = next { off += cur.childOffsetY + layoutOffsetWithin(n, cur); cur = n; continue }
            }
            guard let n = next else { return nil }
            off += n.y + cur.childOffsetY
            cur = n
        }
        return nil
    }

    /// Last line baseline (inline-block baseline), or nil.
    func lastBaseline(_ b: LayoutBox) -> Double? {
        var cur = b
        var off = 0.0
        var k = 0
        while k < limits.maxDepth + 8 {
            k += 1
            if cur.style.overflowY != .visible && k > 1 { return nil }
            if let l = cur.lines.last { return off + l.baseline + cur.childOffsetY }
            if cur.kind == .replaced || cur.kind == .text || cur.kind == .table { return cur.kind == .table ? firstBaseline(cur).map { off + $0 } : nil }
            var next: LayoutBox? = nil
            for c in cur.children.reversed() where !c.isOutOfFlow && c.kind != .text { next = c; break }
            guard let n = next else { return nil }
            off += n.y + cur.childOffsetY
            cur = n
        }
        return nil
    }

    // MARK: Absolute positioning

    /// Where a box's coordinates are relative to.
    func coordContainer(_ b: LayoutBox) -> LayoutBox? {
        if b.isAbs { return b.cb }
        var p = b.parent
        while let q = p, q.kind == .inline { p = q.parent }
        return p
    }

    /// Assign containing blocks for absolutely positioned and fixed boxes
    /// (explicit stack walk).
    func assignContainingBlocks(_ root: LayoutBox) {
        initialAbs = []
        fixedBoxes = []
        var stack: [(LayoutBox, LayoutBox?)] = [(root, nil)]
        while let (b, positioned) = stack.popLast() {
            b.absChildren = []
            var pos = positioned
            if b.isAbs {
                if b.style.position == .fixed { b.cb = nil; fixedBoxes.append(b) }
                else if let p = positioned { b.cb = p }
                else { b.cb = nil; initialAbs.append(b) }
            }
            if b.style.position != .static && b.kind != .text {
                var cbBox = b
                if cbBox.kind == .inline { cbBox = coordContainer(b) ?? b }
                pos = cbBox
            }
            for c in b.children.reversed() { stack.append((c, pos)) }
        }
        // absChildren lists in tree order
        var walk: [LayoutBox] = [root]
        while let b = walk.popLast() {
            if b.isAbs && b.style.position == .absolute, let cb = b.cb { cb.absChildren.append(b) }
            for c in b.children.reversed() { walk.append(c) }
        }
    }

    /// Offset of `b`'s coordinate origin within `ancestor` (walking coordinate containers).
    func layoutOffsetWithin(_ b: LayoutBox, _ ancestor: LayoutBox?) -> Double {
        var y = b.y
        var p = coordContainer(b)
        var k = 0
        while let q = p, q !== ancestor, k < 4096 {
            y += q.y + q.childOffsetY
            p = coordContainer(q)
            k += 1
        }
        if let q = p, q === ancestor { y += q.childOffsetY }
        return y
    }

    /// Static position of `b` in the coordinates of its containing block (nil = page).
    func staticPosition(_ b: LayoutBox) -> (Double, Double) {
        var x = b.staticX, y = b.staticY
        guard let sp = b.staticParent else { return (x, y) }
        var p: LayoutBox? = sp
        var k = 0
        while let q = p, q !== b.cb, k < 4096 {
            x += q.x; y += q.y
            if let c = coordContainer(q) { y += c.childOffsetY }
            p = coordContainer(q)
            k += 1
        }
        return (x, y)
    }

    func layoutAbsChildren(_ cb: LayoutBox) {
        let rect = LayoutRect(x: cb.border.l, y: cb.border.t, w: max(0, cb.w - cb.border.horizontal), h: max(0, cb.h - cb.border.vertical))
        for a in cb.absChildren { layoutAbsolute(a, rect) }
    }

    func layoutAbsolute(_ b: LayoutBox, _ rect: LayoutRect) {
        let cbw = rect.w, cbh = rect.h
        resolveEdges(b, cbw)
        let left = b.style.left.resolve(cbw).map(layoutSan), right = b.style.right.resolve(cbw).map(layoutSan)
        let top = b.style.top.resolve(cbh).map(layoutSan), bottom = b.style.bottom.resolve(cbh).map(layoutSan)
        let bp = b.border.horizontal + b.padding.horizontal
        var forceW: Double? = nil
        if b.kind != .replaced && b.kind != .table {
            if let cw = specifiedContentWidth(b, cbw) { forceW = clampWidth(b, cw, cbw) + bp }
            else if let l = left, let r = right, b.style.width.isAuto {
                forceW = clampWidth(b, max(0, cbw - l - r - b.margin.horizontal - bp), cbw) + bp
            }
        }
        let avail = max(0, cbw - (left ?? 0) - (right ?? 0))
        b.layoutGen = -1
        layoutBlock(b, cbW: cbw, cbH: cbh, floats: LayoutFloats(cap: 1), cbOX: 0, oy: 0, avail: avail, shrink: true, forceW: forceW)
        resolveEdges(b, cbw)
        if b.style.height.isAuto, let t = top, let bo = bottom, b.kind != .replaced {
            let hh = clampHeight(b, max(0, cbh - t - bo - b.margin.vertical - b.border.vertical - b.padding.vertical), cbh)
            b.h = hh + b.border.vertical + b.padding.vertical
        }
        let (sx, sy) = staticPosition(b)
        if let l = left {
            if right != nil && !b.style.width.isAuto && b.style.marginLeft.isAuto && b.style.marginRight.isAuto {
                let free = cbw - l - (right ?? 0) - b.w
                b.margin.l = max(0, free / 2)
            }
            b.x = rect.x + l + b.margin.l
        } else if let r = right { b.x = rect.x + cbw - r - b.margin.r - b.w }
        else { b.x = sx + b.margin.l }
        if let t = top {
            if bottom != nil && !b.style.height.isAuto && b.style.marginTop.isAuto && b.style.marginBottom.isAuto {
                let free = cbh - t - (bottom ?? 0) - b.h
                b.margin.t = max(0, free / 2)
            }
            b.y = rect.y + t + b.margin.t
        } else if let bo = bottom { b.y = rect.y + cbh - bo - b.margin.b - b.h }
        else { b.y = sy + b.margin.t }
    }
}
