// Tables: the grid (colspan/rowspan, header groups first and footers last),
// automatic layout (column min/max widths from cell content, fixed and
// percentage widths, spanning cells), fixed layout, border-spacing,
// a simplified border-collapse (shared edges drawn once), captions, row
// heights with rowspan, and cell vertical-align (baseline, top, middle,
// bottom). The table box holds its captions above the grid; `gridTop` is
// where the table's own border box starts.

extension LayoutContext {
    func tableData(_ t: LayoutBox) -> LayoutTableData {
        if let d = t.table { return d }
        let d = LayoutTableData()
        t.table = d
        var heads: [LayoutBox] = [], bodies: [LayoutBox] = [], feet: [LayoutBox] = []
        for g in t.children where g.kind == .rowGroup {
            switch g.style.display {
            case .tableHeaderGroup: heads.append(g)
            case .tableFooterGroup: feet.append(g)
            default: bodies.append(g)
            }
        }
        let groups = heads + bodies + feet
        var busy: [Int] = []          // busy[c]: rows < busy[c] are covered by an earlier rowspan
        let collapse = t.style.borderCollapse == .collapse
        for g in groups {
            let groupStart = d.rows.count
            var groupRows: [LayoutBox] = []
            for r in g.children where r.kind == .row {
                if d.rows.count + groupRows.count >= limits.maxTableRows { break }
                groupRows.append(r)
            }
            let groupEnd = groupStart + groupRows.count
            for (k, r) in groupRows.enumerated() {
                let ri = groupStart + k
                d.rows.append(r)
                r.rowIndex = ri
                var col = 0
                for c in r.children where c.kind == .cell {
                    while col < busy.count && busy[col] > ri { col += 1 }
                    if col >= limits.maxTableColumns { c.col = -1; continue }
                    var cs = 1, rs = 1
                    if let n = c.node, !c.anonymous {
                        if let v = n.attribute("colspan"), let k2 = layoutParseInt(v) { cs = max(1, min(k2, 1000)) }
                        if let v = n.attribute("rowspan"), let k2 = layoutParseInt(v) { rs = k2 == 0 ? groupEnd - ri : max(1, min(k2, 65534)) }
                    }
                    cs = min(cs, limits.maxTableColumns - col)
                    rs = max(1, min(rs, groupEnd - ri))
                    c.col = col; c.rowIndex = ri; c.colspan = cs; c.rowspan = rs
                    while busy.count < col + cs { busy.append(0) }
                    for cc in col..<(col + cs) { busy[cc] = max(busy[cc], ri + rs) }
                    d.cells.append(c)
                    col += cs
                }
            }
        }
        d.columns = busy.count
        if collapse {
            let hasT = t.style.borderTopWidth > 0, hasB = t.style.borderBottomWidth > 0
            let hasL = t.style.borderLeftWidth > 0, hasR = t.style.borderRightWidth > 0
            let lastRow = d.rows.count - 1
            for c in d.cells {
                var drop: UInt8 = 0
                if c.col > 0 || hasL { drop |= 8 }
                if c.rowIndex > 0 || hasT { drop |= 1 }
                if c.col + c.colspan >= d.columns && hasR { drop |= 2 }
                if c.rowIndex + c.rowspan > lastRow && hasB { drop |= 4 }
                c.dropBorders = drop
            }
        }
        // <col>/<colgroup> widths are not boxes; read them from the DOM.
        d.colSpecWidth = []
        if let tn = t.node {
            for ch in tn.children where ch.kind == .element && (ch.name == "col" || ch.name == "colgroup") {
                let cols = ch.name == "colgroup" ? ch.children.filter { $0.kind == .element && $0.name == "col" } : [ch]
                for col in cols.prefix(1000) {
                    let span = max(1, min(layoutParseInt(col.attribute("span") ?? "1") ?? 1, 1000))
                    var w: Double? = nil
                    if let a = col.attribute("width"), let l = layoutParseHTMLLength(a), !l.hasSuffix("%") {
                        w = Double(layoutParseInt(a) ?? 0)
                    }
                    for _ in 0..<span where d.colSpecWidth.count < 1000 { d.colSpecWidth.append(w) }
                }
            }
        }
        return d
    }

    private func spacing(_ t: LayoutBox) -> (Double, Double) {
        if t.style.borderCollapse == .collapse { return (0, 0) }
        return (layoutPos(t.style.borderSpacingH), layoutPos(t.style.borderSpacingV))
    }

    /// Column min/max/percent/fixed widths (border-box cell widths).
    func tableColumns(_ t: LayoutBox) -> LayoutTableData {
        let d = tableData(t)
        if d.colGen == gen { return d }
        d.colGen = gen
        let n = d.columns
        d.colMin = [Double](repeating: 0, count: n)
        d.colMax = [Double](repeating: 0, count: n)
        d.colPct = [Double](repeating: 0, count: n)
        d.colFixed = [Double](repeating: 0, count: n)
        let (hs, _) = spacing(t)
        for (i, w) in d.colSpecWidth.enumerated() where i < n {
            if let v = w { d.colFixed[i] = layoutPos(v); d.colMin[i] = 0; d.colMax[i] = layoutPos(v) }
        }
        var spanning: [LayoutBox] = []
        for c in d.cells {
            let (mn0, mx0) = intrinsic(c)
            var mn = mn0, mx = mx0
            var fixedW = 0.0
            let ws = c.style.width
            if ws.kind == .length && !ws.hasPercent {
                let bp = c.border.horizontal + c.padding.horizontal
                fixedW = layoutPos(ws.lp.px + (c.style.boxSizing == .borderBox ? 0 : bp))
                mn = max(mn0, min(fixedW, mn0))
                mx = max(mn, fixedW)
            } else if ws.hasPercent && c.colspan == 1 {
                d.colPct[c.col] = max(d.colPct[c.col], layoutPos(ws.lp.pct))
            }
            if c.colspan == 1 {
                d.colMin[c.col] = max(d.colMin[c.col], mn)
                d.colMax[c.col] = max(d.colMax[c.col], mx)
                if fixedW > 0 { d.colFixed[c.col] = max(d.colFixed[c.col], fixedW) }
            } else {
                spanning.append(c)
            }
        }
        spanning.sort { $0.colspan < $1.colspan }
        for c in spanning {
            let (mn, mx) = intrinsic(c)
            let a = c.col, e = min(n, c.col + c.colspan)
            if a >= e { continue }
            let sp = hs * Double(e - a - 1)
            var smin = 0.0, smax = 0.0
            for k in a..<e { smin += d.colMin[k]; smax += d.colMax[k] }
            if mn > smin + sp {
                let extra = mn - smin - sp
                for k in a..<e {
                    let share = smax > 0 ? d.colMax[k] / smax : 1 / Double(e - a)
                    d.colMin[k] += extra * share
                }
            }
            if mx > smax + sp {
                let extra = mx - smax - sp
                for k in a..<e {
                    let share = smax > 0 ? d.colMax[k] / smax : 1 / Double(e - a)
                    d.colMax[k] += extra * share
                }
            }
        }
        for k in 0..<n {
            if d.colFixed[k] > 0 { d.colMax[k] = max(d.colMin[k], d.colFixed[k]) }
            d.colMax[k] = max(d.colMax[k], d.colMin[k])
        }
        return d
    }

    func tableIntrinsic(_ t: LayoutBox) -> (Double, Double) {
        let d = tableColumns(t)
        resolveEdges(t, 0)
        if t.style.borderCollapse == .collapse { t.padding = LayoutEdges() }
        let (hs, _) = spacing(t)
        let n = d.columns
        let sp = n > 0 ? hs * Double(n + 1) : 0
        var mn = 0.0, mx = 0.0, pct = 0.0, nonPctMax = 0.0, needed = 0.0
        for k in 0..<n {
            mn += d.colMin[k]; mx += d.colMax[k]
            if d.colPct[k] > 0 {
                pct += d.colPct[k]
                needed = max(needed, d.colMax[k] * 100 / d.colPct[k])
            } else { nonPctMax += d.colMax[k] }
        }
        if pct > 0 && pct < 100 { needed = max(needed, nonPctMax * 100 / (100 - pct)) }
        mx = max(mx, needed)
        let bp = t.border.horizontal + t.padding.horizontal
        var capMin = 0.0
        for c in t.children where c.kind == .caption { capMin = max(capMin, intrinsic(c).0) }
        mn = max(mn + sp + bp, capMin)
        mx = max(mx + sp + bp, mn)
        if t.style.width.kind == .length && !t.style.width.hasPercent {
            let w = layoutPos(t.style.width.lp.px + (t.style.boxSizing == .borderBox ? 0 : bp))
            mn = max(mn, w); mx = mn
        }
        return (mn, mx)
    }

    /// Distribute the grid width over the columns.
    private func columnWidths(_ d: LayoutTableData, gridW: Double, fixed: Bool, t: LayoutBox) -> [Double] {
        let n = d.columns
        var w = [Double](repeating: 0, count: n)
        if n == 0 { return w }
        if fixed {
            var assigned = [Bool](repeating: false, count: n)
            var used = 0.0
            for (i, s) in d.colSpecWidth.enumerated() where i < n {
                if let v = s { w[i] = v; assigned[i] = true; used += v }
            }
            if let r = d.rows.first {
                for c in r.children where c.kind == .cell && c.col >= 0 && c.col < n {
                    if assigned[c.col] { continue }
                    var cw: Double? = nil
                    if let v = c.style.width.resolve(gridW) {
                        cw = layoutPos(v) + (c.style.boxSizing == .borderBox ? 0 : c.border.horizontal + c.padding.horizontal)
                    }
                    if let v = cw {
                        let span = min(c.colspan, n - c.col)
                        for k in c.col..<(c.col + span) { w[k] = v / Double(span); assigned[k] = true }
                        used += v
                    }
                }
            }
            var free = 0
            for a in assigned where !a { free += 1 }
            if free > 0 {
                let each = max(0, gridW - used) / Double(free)
                for k in 0..<n where !assigned[k] { w[k] = each }
            } else if used < gridW && used > 0 {
                for k in 0..<n { w[k] *= gridW / used }
            }
            return w
        }
        var pctTotal = 0.0
        for k in 0..<n { pctTotal += d.colPct[k] }
        let pctScale = pctTotal > 100 ? 100 / pctTotal : 1
        var used = 0.0
        var isPct = [Bool](repeating: false, count: n)
        for k in 0..<n where d.colPct[k] > 0 {
            w[k] = max(d.colMin[k], d.colPct[k] * pctScale * gridW / 100)
            isPct[k] = true
            used += w[k]
        }
        let remaining = gridW - used
        var smin = 0.0, smax = 0.0, autoMax = 0.0, autoCount = 0, otherCount = 0
        for k in 0..<n where !isPct[k] {
            smin += d.colMin[k]; smax += d.colMax[k]
            otherCount += 1
            if d.colFixed[k] == 0 { autoMax += d.colMax[k]; autoCount += 1 }
        }
        if otherCount == 0 {
            if remaining > 0 && used > 0 { for k in 0..<n { w[k] += remaining * w[k] / used } }
            return w
        }
        if remaining >= smax {
            var extra = remaining - smax
            for k in 0..<n where !isPct[k] { w[k] = d.colMax[k] }
            if extra > 0 {
                if autoCount > 0 {
                    for k in 0..<n where !isPct[k] && d.colFixed[k] == 0 {
                        w[k] += autoMax > 0 ? extra * d.colMax[k] / autoMax : extra / Double(autoCount)
                    }
                } else if smax > 0 {
                    for k in 0..<n where !isPct[k] { w[k] += extra * d.colMax[k] / smax }
                } else {
                    for k in 0..<n where !isPct[k] { w[k] += extra / Double(otherCount) }
                }
                extra = 0
            }
        } else if remaining >= smin {
            let span = smax - smin
            let f = span > 0 ? (remaining - smin) / span : 0
            for k in 0..<n where !isPct[k] { w[k] = d.colMin[k] + (d.colMax[k] - d.colMin[k]) * f }
        } else {
            for k in 0..<n where !isPct[k] { w[k] = d.colMin[k] }
        }
        return w
    }

    func layoutTable(_ t: LayoutBox, cbW: Double, cbH: Double?, avail availIn: Double?, shrink: Bool, forceW: Double?) {
        let d = tableColumns(t)
        resolveEdges(t, cbW)
        if t.style.borderCollapse == .collapse { t.padding = LayoutEdges() }
        let (hs, vs) = spacing(t)
        let n = d.columns
        let sp = n > 0 ? hs * Double(n + 1) : 0
        let bp = t.border.horizontal + t.padding.horizontal
        let avail = layoutPos(availIn ?? cbW)
        let (tmin, tmax) = tableIntrinsic(t)
        var borderW: Double
        var specified = false
        if let f = forceW { borderW = f; specified = true }
        else if let v = t.style.width.resolve(cbW) {
            borderW = layoutPos(v) + (t.style.boxSizing == .borderBox ? 0 : bp)
            specified = true
        } else {
            borderW = min(max(0, avail - t.margin.horizontal), tmax)
        }
        if let mx = t.style.maxWidth.resolve(cbW) { borderW = min(borderW, layoutPos(mx) + (t.style.boxSizing == .borderBox ? 0 : bp)) }
        if let mnw = t.style.minWidth.resolve(cbW) { borderW = max(borderW, layoutPos(mnw) + (t.style.boxSizing == .borderBox ? 0 : bp)) }
        let fixedLayout = t.style.tableLayout == .fixed && specified
        if !fixedLayout { borderW = max(borderW, tmin) }
        borderW = layoutPos(borderW)
        t.w = borderW
        let gridW = max(0, borderW - bp - sp)
        let colW = columnWidths(d, gridW: gridW, fixed: fixedLayout, t: t)

        // Horizontal placement (auto margins, legacy centering).
        if !shrink && !t.isFloat && !t.isAbs && !t.inlineLevel {
            let mlA = t.style.marginLeft.isAuto, mrA = t.style.marginRight.isAuto
            let free = avail - t.w - (mlA ? 0 : t.margin.l) - (mrA ? 0 : t.margin.r)
            if mlA && mrA { t.margin.l = max(0, free / 2); t.margin.r = max(0, free / 2) }
            else if mlA { t.margin.l = free }
            else if mrA { t.margin.r = free }
            else if let p = t.parent, p.legacyCenter, t.margin.l == 0, t.margin.r == 0, t.w < avail { t.margin.l = (avail - t.w) / 2 }
        }
        t.x = t.margin.l

        // Captions above the grid.
        var y = 0.0
        for c in t.children where c.kind == .caption {
            layoutBlock(c, cbW: borderW, cbH: nil, floats: LayoutFloats(cap: 1), cbOX: 0, oy: 0, forceW: borderW)
            c.x = 0
            c.y = y + c.margin.t
            y = c.y + c.h + c.margin.b
        }
        d.gridTop = y
        let cl = t.border.l + t.padding.l
        let gridTopY = y + t.border.t + t.padding.t
        var colX = [Double](repeating: 0, count: n + 1)
        var x = cl + hs
        for k in 0..<n { colX[k] = x; x += colW[k] + hs }
        colX[n] = x

        // Cells.
        let nr = d.rows.count
        var rowH = [Double](repeating: 0, count: nr)
        var rowBase = [Double](repeating: 0, count: nr)
        var rowBelow = [Double](repeating: 0, count: nr)
        for (ri, r) in d.rows.enumerated() {
            resolveEdges(r, cbW)
            if let h = r.style.height.resolve(0), !r.style.height.hasPercent { rowH[ri] = layoutPos(h) }
        }
        var cellBase: [Double] = []
        cellBase.reserveCapacity(d.cells.count)
        for c in d.cells {
            let a = min(c.col, n), e = min(n, c.col + c.colspan)
            let cw = a < e ? colX[e] - colX[a] - hs : 0
            layoutBlock(c, cbW: gridW, cbH: nil, floats: LayoutFloats(cap: 1), cbOX: 0, oy: 0, forceW: max(0, cw))
            c.x = colX[a]
            let bl = firstBaseline(c) ?? (c.h - c.border.b - c.padding.b)
            cellBase.append(bl)
            if c.rowspan == 1 && c.rowIndex < nr {
                let ri = c.rowIndex
                if layoutCellAlign(c) == 0 {
                    rowBase[ri] = max(rowBase[ri], bl)
                    rowBelow[ri] = max(rowBelow[ri], c.h - bl)
                    rowH[ri] = max(rowH[ri], rowBase[ri] + rowBelow[ri])
                }
                rowH[ri] = max(rowH[ri], c.h)
            }
        }
        for c in d.cells where c.rowspan > 1 && c.rowIndex < nr {
            let last = min(nr, c.rowIndex + c.rowspan) - 1
            var sum = vs * Double(last - c.rowIndex)
            for k in c.rowIndex...last { sum += rowH[k] }
            if c.h > sum { rowH[last] += c.h - sum }
        }
        // Specified table height: spread the extra over the rows.
        var gridH = nr > 0 ? vs * Double(nr + 1) : 0
        for h in rowH { gridH += h }
        let tbv = t.border.vertical + t.padding.vertical
        if let sh = specifiedContentHeight(t, cbH), t.style.boxSizing == .borderBox ? sh + 0 > gridH + tbv : sh > gridH, nr > 0 {
            let target = t.style.boxSizing == .borderBox ? sh - tbv : sh
            let extra = (target - gridH) / Double(nr)
            if extra > 0 { for k in 0..<nr { rowH[k] += extra }; gridH = max(gridH, target) }
        }
        var rowY = [Double](repeating: 0, count: nr + 1)
        y = gridTopY + (nr > 0 ? vs : 0)
        for k in 0..<nr { rowY[k] = y; y += rowH[k] + vs }
        rowY[nr] = y

        // Row groups and rows (rectangles spanning the grid).
        let rowX = cl
        let rowW = max(0, borderW - bp)
        for g in t.children where g.kind == .rowGroup {
            var gy0 = layoutMaxCoord, gy1 = -layoutMaxCoord
            for r in g.children where r.kind == .row && r.rowIndex < nr && d.rows.count > r.rowIndex && d.rows[r.rowIndex] === r {
                gy0 = min(gy0, rowY[r.rowIndex]); gy1 = max(gy1, rowY[r.rowIndex] + rowH[r.rowIndex])
            }
            if gy0 > gy1 { gy0 = gridTopY; gy1 = gridTopY }
            resolveEdges(g, cbW)
            g.x = rowX; g.y = gy0; g.w = rowW; g.h = gy1 - gy0
            for r in g.children where r.kind == .row {
                if r.rowIndex < nr && d.rows.count > r.rowIndex && d.rows[r.rowIndex] === r {
                    r.x = 0; r.y = rowY[r.rowIndex] - gy0; r.w = rowW; r.h = rowH[r.rowIndex]
                } else { r.x = 0; r.y = 0; r.w = 0; r.h = 0 }
            }
        }
        for (i, c) in d.cells.enumerated() {
            guard c.rowIndex < nr, let r = c.parent, let g = r.parent else { continue }
            let last = min(nr, c.rowIndex + c.rowspan) - 1
            let h = rowY[last] + rowH[last] - rowY[c.rowIndex]
            let contentH = c.h
            switch layoutCellAlign(c) {
            case 0: c.childOffsetY = max(0, rowBase[c.rowIndex] - cellBase[i])
            case 1: c.childOffsetY = 0
            case 2: c.childOffsetY = max(0, (h - contentH) / 2)
            default: c.childOffsetY = max(0, h - contentH)
            }
            c.h = max(h, contentH)
            c.x = c.x - g.x - r.x
            c.y = rowY[c.rowIndex] - g.y - r.y
        }
        for c in t.children where c.kind != .caption && c.kind != .rowGroup && c.isAbs {
            c.staticParent = t; c.staticX = cl; c.staticY = gridTopY
        }
        let gridBorderH = gridH + tbv
        var total = d.gridTop + gridBorderH
        _ = total
        t.h = layoutPos(d.gridTop + gridBorderH)
        total = t.h
        t.collapsedBottom = LayoutMargin(t.margin.b)
        if !t.absChildren.isEmpty { layoutAbsChildren(t) }
    }
}

/// 0 baseline, 1 top, 2 middle, 3 bottom.
func layoutCellAlign(_ c: LayoutBox) -> Int {
    switch c.style.verticalAlign.kind {
    case .top, .textTop: return 1
    case .middle: return 2
    case .bottom, .textBottom: return 3
    default: return 0
    }
}
