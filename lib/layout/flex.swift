// Flexbox: row and column, wrap, flex-basis/grow/shrink with min/max
// clamping (the spec's freeze loop), automatic minimum size (min-content),
// justify-content, align-items/align-self (stretch, start, end, center;
// baseline as start), auto margins in the main axis, row/column gap, and
// the reverse directions. `order` is not supported.

private struct LayoutFlexItem {
    unowned(unsafe) var box: LayoutBox
    var base = 0.0          // flex base size (border box)
    var hyp = 0.0           // hypothetical main size (border box)
    var target = 0.0
    var minMain = 0.0, maxMain = layoutMaxCoord
    var marginMain = 0.0
    var frozen = false
    var cross = 0.0          // outer cross size
}

extension LayoutContext {
    func layoutFlex(_ b: LayoutBox, contentW: Double, contentH: Double?, cbH: Double?, minH: Double, maxCbH: Double?) -> Double {
        let row = b.style.flexDirection == .row || b.style.flexDirection == .rowReverse
        let reverse = b.style.flexDirection == .rowReverse || b.style.flexDirection == .columnReverse
        let wrap = b.style.flexWrap != .nowrap
        let cl = b.border.l + b.padding.l, ct = b.border.t + b.padding.t
        let gapMain = layoutPos(row ? b.style.columnGap.resolve(contentW) : b.style.rowGap.resolve(contentH ?? 0))
        let gapCross = layoutPos(row ? b.style.rowGap.resolve(contentH ?? 0) : b.style.columnGap.resolve(contentW))
        let mainSize: Double? = row ? contentW : contentH
        var items: [LayoutFlexItem] = []
        for c in b.children {
            if c.isAbs { c.staticParent = b; c.staticX = cl; c.staticY = ct; continue }
            resolveEdges(c, contentW)
            var it = LayoutFlexItem(box: c)
            let bpMain = row ? c.border.horizontal + c.padding.horizontal : c.border.vertical + c.padding.vertical
            it.marginMain = row ? c.margin.horizontal : c.margin.vertical
            // Base size.
            var base: Double? = nil
            let fb = c.style.flexBasis
            if fb.kind == .length && !(fb.hasPercent && mainSize == nil) {
                base = layoutPos(fb.lp.resolve(mainSize ?? 0)) + (c.style.boxSizing == .borderBox ? 0 : bpMain)
            }
            if base == nil {
                if row, let w = specifiedContentWidth(c, contentW) { base = w + bpMain }
                if !row, let h = specifiedContentHeight(c, contentH) { base = h + bpMain }
            }
            if base == nil {
                if row { base = intrinsic(c).1 }
                else {
                    measureColumnItem(c, b, contentW: contentW, contentH: contentH)
                    base = c.h
                }
            }
            it.base = layoutPos(base ?? 0)
            // Min/max main size.
            let mnD = row ? c.style.minWidth : c.style.minHeight, mxD = row ? c.style.maxWidth : c.style.maxHeight
            let bsAdj = c.style.boxSizing == .borderBox ? 0 : bpMain
            if mnD.kind == .length, let v = mnD.resolve(mainSize ?? 0), !(mnD.hasPercent && mainSize == nil) {
                it.minMain = layoutPos(v) + bsAdj
            } else if mnD.isAuto && c.style.overflowX == .visible && c.style.overflowY == .visible {
                if row {
                    var m = (c.kind == .replaced || c.kind == .table) ? intrinsic(c).0
                        : contentIntrinsic(c).0 + c.border.horizontal + c.padding.horizontal
                    if let w = specifiedContentWidth(c, contentW) { m = min(m, w + bpMain) }
                    it.minMain = m
                } else { it.minMain = 0 }
            }
            if mxD.kind == .length, let v = mxD.resolve(mainSize ?? 0), !(mxD.hasPercent && mainSize == nil) {
                it.maxMain = max(it.minMain, layoutPos(v) + bsAdj)
            }
            it.hyp = max(it.minMain, min(it.maxMain, it.base))
            items.append(it)
        }
        if items.isEmpty { return contentH ?? 0 }

        // Lines.
        var lines: [Range<Int>] = []
        if wrap, let ms = mainSize {
            var start = 0, sum = 0.0
            for (i, it) in items.enumerated() {
                let outer = it.hyp + it.marginMain
                if i > start && sum + gapMain + outer > ms + 0.01 {
                    lines.append(start..<i); start = i; sum = outer
                } else { sum += (i > start ? gapMain : 0) + outer }
            }
            lines.append(start..<items.count)
        } else {
            lines.append(0..<items.count)
        }

        // Flexible lengths.
        for line in lines {
            let count = line.count
            guard let ms = mainSize else {
                for i in line { items[i].target = items[i].hyp }
                continue
            }
            var sumHyp = 0.0
            for i in line { sumHyp += items[i].hyp + items[i].marginMain }
            let growing = ms - sumHyp - gapMain * Double(count - 1) > 0
            for i in line {
                items[i].target = items[i].hyp
                let fb = items[i].box
                items[i].frozen = growing ? fb.style.flexGrow <= 0 || items[i].base > items[i].hyp
                                          : fb.style.flexShrink <= 0 || items[i].base < items[i].hyp
            }
            var iter = 0
            while iter <= count + 1 {
                iter += 1
                var used = gapMain * Double(count - 1)
                var unfrozen = 0
                for i in line {
                    used += (items[i].frozen ? items[i].target : items[i].base) + items[i].marginMain
                    if !items[i].frozen { unfrozen += 1 }
                }
                if unfrozen == 0 { break }
                let free = ms - used
                var sumGrow = 0.0, sumShrink = 0.0
                for i in line where !items[i].frozen {
                    sumGrow += layoutPos(items[i].box.style.flexGrow)
                    sumShrink += layoutPos(items[i].box.style.flexShrink) * items[i].base
                }
                var distribute = free
                if growing && sumGrow < 1 { distribute = free * sumGrow }
                var violation = 0.0
                for i in line where !items[i].frozen {
                    let fb = items[i].box
                    var t = items[i].base
                    if growing { if sumGrow > 0 { t += distribute * layoutPos(fb.style.flexGrow) / sumGrow } }
                    else if sumShrink > 0 { t += free * layoutPos(fb.style.flexShrink) * items[i].base / sumShrink }
                    let c = max(items[i].minMain, min(items[i].maxMain, max(0, t)))
                    violation += c - t
                    items[i].target = c
                }
                if abs(violation) < 0.001 { for i in line { items[i].frozen = true }; break }
                for i in line where !items[i].frozen {
                    let t = items[i].target
                    if violation > 0 && t <= items[i].minMain + 0.0001 { items[i].frozen = true }
                    if violation < 0 && t >= items[i].maxMain - 0.0001 { items[i].frozen = true }
                }
            }
        }

        // Cross sizes.
        for i in 0..<items.count {
            let c = items[i].box
            let main = layoutPos(items[i].target)
            if row {
                layoutBlock(c, cbW: contentW, cbH: contentH, floats: LayoutFloats(cap: 1), cbOX: 0, oy: 0, forceW: main)
                resolveEdges(c, contentW)
                items[i].cross = c.h + c.margin.vertical
            } else {
                measureColumnItem(c, b, contentW: contentW, contentH: contentH)
                c.h = main
                items[i].cross = c.w + c.margin.horizontal
            }
        }
        var lineCross: [Double] = []
        for line in lines {
            var m = 0.0
            for i in line { m = max(m, items[i].cross) }
            lineCross.append(m)
        }
        if lines.count == 1 {
            if row, let h = contentH { lineCross[0] = h }
            else if row { lineCross[0] = max(lineCross[0], minH) }
            if !row { lineCross[0] = contentW }
        }

        // Place.
        var crossPos = 0.0
        var maxMainUsed = 0.0
        for (li, line) in lines.enumerated() {
            let lc = lineCross[li]
            var used = gapMain * Double(line.count - 1)
            var autoMargins = 0
            for i in line {
                used += items[i].target + items[i].marginMain
                let c = items[i].box
                if row { if c.style.marginLeft.isAuto { autoMargins += 1 }; if c.style.marginRight.isAuto { autoMargins += 1 } }
                else { if c.style.marginTop.isAuto { autoMargins += 1 }; if c.style.marginBottom.isAuto { autoMargins += 1 } }
            }
            let remaining = (mainSize ?? used) - used
            var start = 0.0, between = 0.0
            let n = Double(line.count)
            var autoShare = 0.0
            if autoMargins > 0 && remaining > 0 { autoShare = remaining / Double(autoMargins) }
            else {
                switch b.style.justifyContent {
                case .flexStart: break
                case .flexEnd: start = remaining
                case .center: start = remaining / 2
                case .spaceBetween: if remaining > 0 && line.count > 1 { between = remaining / (n - 1) }
                case .spaceAround: if remaining > 0 { between = remaining / n; start = between / 2 }
                case .spaceEvenly: if remaining > 0 { between = remaining / (n + 1); start = between }
                }
            }
            var pos = start
            let order = reverse ? Array(line.reversed()) : Array(line)
            for i in order {
                let c = items[i].box
                if autoShare > 0 {
                    if row {
                        if c.style.marginLeft.isAuto { c.margin.l = autoShare }
                        if c.style.marginRight.isAuto { c.margin.r = autoShare }
                    } else {
                        if c.style.marginTop.isAuto { c.margin.t = autoShare }
                        if c.style.marginBottom.isAuto { c.margin.b = autoShare }
                    }
                }
                let mStart = row ? c.margin.l : c.margin.t
                let mEnd = row ? c.margin.r : c.margin.b
                let main = items[i].target
                // Cross alignment.
                var al = c.style.alignSelf == .auto ? b.style.alignItems : c.style.alignSelf
                if al == .auto { al = .stretch }
                let crossAutoA = row ? c.style.marginTop.isAuto : c.style.marginLeft.isAuto
                let crossAutoB = row ? c.style.marginBottom.isAuto : c.style.marginRight.isAuto
                var off = 0.0
                if row {
                    if al == .stretch && c.style.height.isAuto && !crossAutoA && !crossAutoB {
                        let h = clampHeight(c, max(0, lc - c.margin.vertical - c.border.vertical - c.padding.vertical), contentH)
                        c.h = max(c.h, h + c.border.vertical + c.padding.vertical)
                    }
                    let outer = c.h + c.margin.vertical
                    if crossAutoA && crossAutoB { off = max(0, (lc - outer) / 2) }
                    else if crossAutoA { off = max(0, lc - outer) }
                    else {
                        switch al {
                        case .flexEnd: off = lc - outer
                        case .center: off = (lc - outer) / 2
                        default: off = 0
                        }
                    }
                    c.x = cl + pos + mStart
                    c.y = ct + crossPos + off + c.margin.t
                } else {
                    let outer = c.w + c.margin.horizontal
                    if crossAutoA && crossAutoB { off = max(0, (lc - outer) / 2) }
                    else if crossAutoA { off = max(0, lc - outer) }
                    else {
                        switch al {
                        case .flexEnd: off = lc - outer
                        case .center: off = (lc - outer) / 2
                        default: off = 0
                        }
                    }
                    c.y = ct + pos + mStart
                    c.x = cl + crossPos + off + c.margin.l
                }
                pos += mStart + main + mEnd + gapMain + between
            }
            maxMainUsed = max(maxMainUsed, pos - gapMain - between)
            crossPos += lc + gapCross
        }
        let crossTotal = max(0, crossPos - gapCross)
        if row { return contentH ?? crossTotal }
        return contentH ?? max(0, maxMainUsed)
    }

    /// Column flex item: width from stretch or shrink-to-fit, laid out to get its height.
    private func measureColumnItem(_ c: LayoutBox, _ f: LayoutBox, contentW: Double, contentH: Double?) {
        var al = c.style.alignSelf == .auto ? f.style.alignItems : c.style.alignSelf
        if al == .auto { al = .stretch }
        if al == .stretch && c.style.width.isAuto && !c.style.marginLeft.isAuto && !c.style.marginRight.isAuto {
            resolveEdges(c, contentW)
            let w = clampWidth(c, max(0, contentW - c.margin.horizontal - c.border.horizontal - c.padding.horizontal), contentW)
            layoutBlock(c, cbW: contentW, cbH: contentH, floats: LayoutFloats(cap: 1), cbOX: 0, oy: 0,
                        forceW: w + c.border.horizontal + c.padding.horizontal)
        } else {
            layoutBlock(c, cbW: contentW, cbH: contentH, floats: LayoutFloats(cap: 1), cbOX: 0, oy: 0, avail: contentW, shrink: true)
        }
        resolveEdges(c, contentW)
    }

    /// A row container whose height grew after layout (min-height): re-stretch single-line items.
    func flexStretchAfterHeight(_ b: LayoutBox, _ ch: Double) {
        guard b.style.flexDirection == .row || b.style.flexDirection == .rowReverse, b.style.flexWrap == .nowrap else { return }
        let ct = b.border.t + b.padding.t
        for c in b.children where !c.isAbs {
            var al = c.style.alignSelf == .auto ? b.style.alignItems : c.style.alignSelf
            if al == .auto { al = .stretch }
            let outer = c.h + c.margin.vertical
            switch al {
            case .stretch:
                if c.style.height.isAuto { c.h = max(c.h, ch - c.margin.vertical) }
            case .flexEnd: c.y = ct + ch - outer + c.margin.t
            case .center: c.y = ct + (ch - outer) / 2 + c.margin.t
            default: break
            }
        }
    }
}
