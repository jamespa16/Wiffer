// Inline formatting: the inline content of a block container is flattened
// into items (text, inline box open/close, atomic inlines, <br>, floats and
// absolutely positioned boxes), whitespace is collapsed across item
// boundaries per `white-space`, text is shaped once per box-tree build, and
// each layout breaks the items into line boxes: greedy, at break
// opportunities, around floats, with vertical-align, text-align (justify
// included), text-indent and line-height.

enum LayoutInlineItemKind: UInt8 { case text, open, close, atomic, lineBreak, float, abs }

struct LayoutInlineItem {
    var kind: LayoutInlineItemKind
    unowned(unsafe) var box: LayoutBox
    /// The inline box (or the IFC root) this item sits in.
    unowned(unsafe) var parentBox: LayoutBox
    /// Baseline shift (down is positive) relative to the root baseline.
    var shift: Double
    var parentShift: Double
    /// white-space allows soft wrapping here.
    var wraps: Bool
}

struct LayoutSeg {
    var item: Int
    var start = 0, end = 0
    var w = 0.0
    var x = 0.0
    init(item: Int) { self.item = item }
}

@inline(__always) func layoutIsSpace(_ c: UInt32) -> Bool { c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d || c == 0x0c }

extension LayoutContext {
    // MARK: Items

    func boxMetrics(_ b: LayoutBox) -> LayoutFontMetrics {
        if let m = b.cachedMetrics { return m }
        let m = metrics(b)
        b.cachedMetrics = m
        b.cachedLineHeight = lineHeight(b)
        return m
    }

    func boxLineHeight(_ b: LayoutBox) -> Double {
        if b.cachedMetrics == nil { _ = boxMetrics(b) }
        return b.cachedLineHeight
    }

    private func vaShift(_ b: LayoutBox, _ parent: LayoutBox) -> Double {
        let pfs = Double(fontSize(parent))
        switch b.style.verticalAlign.kind {
        case .sub: return pfs * 0.2
        case .super: return -pfs * 0.4
        case .length: return -layoutSan(b.style.verticalAlign.lengthPx)
        default: return 0
        }
    }

    private func collapse(_ raw: [UInt32], _ ws: CSSWhiteSpace, _ prevSpace: inout Bool) -> [UInt32] {
        var out: [UInt32] = []
        out.reserveCapacity(raw.count)
        if ws.collapsesSpaces {
            for c in raw {
                if c == 0x0a && ws == .preLine {
                    while out.last == 0x20 { out.removeLast() }
                    out.append(0x0a)
                    prevSpace = true
                } else if layoutIsSpace(c) {
                    if !prevSpace { out.append(0x20); prevSpace = true }
                } else {
                    out.append(c)
                    prevSpace = false
                }
            }
        } else {
            var col = 0
            for c in raw {
                if c == 0x0d { continue }
                if c == 0x09 {
                    let n = 8 - col % 8
                    for _ in 0..<n { out.append(0x20) }
                    col += n
                } else if c == 0x0a { out.append(c); col = 0 }
                else { out.append(c); col += 1 }
            }
            if let l = out.last { prevSpace = l == 0x20 || l == 0x0a }
        }
        return out
    }

    func ensureItems(_ root: LayoutBox) {
        if root.items != nil { return }
        var items: [LayoutInlineItem] = []
        var prevSpace = true
        func walk(_ box: LayoutBox, _ shift: Double, _ depth: Int) {
            for c in box.children {
                let wraps = c.style.whiteSpace.wraps
                if c.isFloat {
                    items.append(LayoutInlineItem(kind: .float, box: c, parentBox: box, shift: shift, parentShift: shift, wraps: wraps))
                    continue
                }
                if c.isAbs {
                    items.append(LayoutInlineItem(kind: .abs, box: c, parentBox: box, shift: shift, parentShift: shift, wraps: wraps))
                    continue
                }
                switch c.kind {
                case .text:
                    let t = collapse(c.raw, c.style.whiteSpace, &prevSpace)
                    c.run = shape(t, c)
                    if !t.isEmpty {
                        items.append(LayoutInlineItem(kind: .text, box: c, parentBox: box, shift: shift, parentShift: shift, wraps: wraps))
                    }
                case .lineBreak:
                    items.append(LayoutInlineItem(kind: .lineBreak, box: c, parentBox: box, shift: shift, parentShift: shift, wraps: wraps))
                    prevSpace = true
                case .inline:
                    let sh = shift + vaShift(c, box)
                    items.append(LayoutInlineItem(kind: .open, box: c, parentBox: box, shift: sh, parentShift: shift, wraps: wraps))
                    if depth < limits.maxDepth + 8 { walk(c, sh, depth + 1) }
                    items.append(LayoutInlineItem(kind: .close, box: c, parentBox: box, shift: sh, parentShift: shift, wraps: wraps))
                default:
                    let sh = shift + vaShift(c, box)
                    items.append(LayoutInlineItem(kind: .atomic, box: c, parentBox: box, shift: sh, parentShift: shift,
                                                  wraps: box.style.whiteSpace.wraps))
                    prevSpace = false
                }
            }
        }
        walk(root, 0, 0)
        root.items = items
    }

    // MARK: Atomic inlines

    func layoutAtomic(_ b: LayoutBox, contentW: Double, cbH: Double?) {
        layoutBlock(b, cbW: contentW, cbH: cbH, floats: LayoutFloats(cap: 1), cbOX: 0, oy: 0, avail: contentW, shrink: true)
    }

    /// Baseline of an atomic inline measured from its margin-box top.
    func atomicBaseline(_ b: LayoutBox) -> Double {
        let H = b.h + b.margin.vertical
        switch b.kind {
        case .replaced: return H
        case .block: if let l = lastBaseline(b) { return b.margin.t + l }; return H
        default: if let l = firstBaseline(b) { return b.margin.t + l }; return H
        }
    }

    // MARK: Line breaking

    func layoutInline(_ root: LayoutBox, contentW: Double, cbH: Double?, floats: LayoutFloats, ox: Double, oy: Double) -> Double {
        ensureItems(root)
        guard let items = root.items else { return 0 }
        let cl = root.border.l + root.padding.l
        let ct = root.border.t + root.padding.t
        root.lines = []
        for it in items {
            switch it.kind {
            case .text: it.box.frags = []
            case .open: it.box.frags = []; resolveEdges(it.box, contentW)
            default: break
            }
        }
        let strutL = boxLineHeight(root)
        let rootM = boxMetrics(root)
        let strutHalf = (strutL - rootM.ascent - rootM.descent) / 2
        let strutTop = -(rootM.ascent + strutHalf), strutBot = rootM.descent + strutHalf
        let align = root.style.textAlign
        let indentPx = layoutSan(root.style.textIndent.resolve(contentW))

        var lineTop = ct
        var segs: [LayoutSeg] = []
        var lineW = 0.0
        var hasContent = false
        var openStack: [Int] = []
        var firstLine = true
        var pendingFloats: [Int] = []
        var availL = 0.0, availW = contentW

        func lineSpace() {
            if floats.isEmpty { availL = 0; availW = contentW; return }
            let (l, r) = floats.edges(y: oy + lineTop, h: strutL, l0: ox + cl, r0: ox + cl + contentW)
            availL = l - (ox + cl)
            availW = max(0, r - l)
        }
        func placeFloat(_ idx: Int) {
            let f = items[idx].box
            layoutFloat(f, cbW: contentW, cbH: cbH, floats: floats, minY: oy + lineTop, l0: ox + cl, r0: ox + cl + contentW)
            f.x -= ox
            f.y -= oy
        }
        lineSpace()

        func finishLine(forced: Bool, last: Bool) {
            defer {
                segs.removeAll(keepingCapacity: true)
                lineW = 0
                hasContent = false
            }
            // Trailing collapsible spaces hang (and do not count).
            var k = segs.count - 1
            while k >= 0 {
                let it = items[segs[k].item]
                if it.kind == .text {
                    if it.box.style.whiteSpace.collapsesSpaces || it.box.style.whiteSpace == .preWrap, let run = it.box.run {
                        var e = segs[k].end
                        while e > segs[k].start && layoutIsSpace(run.scalars[e - 1]) { e -= 1 }
                        let nw = Double(run.xs[e] - run.xs[segs[k].start])
                        lineW -= segs[k].w - nw
                        segs[k].w = nw
                        segs[k].end = max(e, segs[k].start)
                        if e > segs[k].start { break }
                        k -= 1
                        continue
                    }
                    break
                }
                if it.kind == .close || it.kind == .open { k -= 1; continue }
                break
            }
            if !hasContent {
                for s in segs {
                    let it = items[s.item]
                    if it.kind == .open { openStack.append(s.item) }
                    else if it.kind == .close, let i = openStack.lastIndex(where: { items[$0].box === it.box }) { openStack.remove(at: i) }
                }
                return
            }
            let indent = firstLine ? indentPx : 0
            var off = 0.0
            let free = availW - indent - lineW
            var spaceExtra = 0.0
            switch align {
            case .left: off = 0
            case .right: off = max(0, free)
            case .center: off = max(0, free / 2)
            case .justify:
                if !forced && !last && free > 0 {
                    var spaces = 0
                    for (si, s) in segs.enumerated() where items[s.item].kind == .text && si < segs.count - 1 {
                        if let r = items[s.item].box.run, s.end > s.start, r.scalars[s.end - 1] == 0x20 { spaces += 1 }
                    }
                    if spaces > 0 { spaceExtra = free / Double(spaces) }
                }
            }
            let startX = cl + availL + indent + off
            var x = startX
            for i in 0..<segs.count {
                segs[i].x = x
                x += segs[i].w
                if spaceExtra > 0 && i < segs.count - 1 && items[segs[i].item].kind == .text,
                   let r = items[segs[i].item].box.run, segs[i].end > segs[i].start, r.scalars[segs[i].end - 1] == 0x20 {
                    x += spaceExtra
                }
            }
            let endX = x
            // Vertical metrics.
            var minTop = strutTop, maxBot = strutBot
            var tallest = 0.0
            var tops = [Double](repeating: 0, count: segs.count)
            for (i, s) in segs.enumerated() {
                let it = items[s.item]
                switch it.kind {
                case .text, .open, .lineBreak:
                    let b = it.kind == .lineBreak ? it.parentBox : it.box
                    let m = boxMetrics(b)
                    let L = boxLineHeight(b)
                    let hl = (L - m.ascent - m.descent) / 2
                    let t = it.shift - m.ascent - hl, bo = it.shift + m.descent + hl
                    minTop = min(minTop, t); maxBot = max(maxBot, bo)
                case .atomic:
                    let b = it.box
                    let H = b.h + b.margin.vertical
                    var t: Double
                    switch b.style.verticalAlign.kind {
                    case .top, .bottom:
                        tallest = max(tallest, H)
                        tops[i] = 0
                        continue
                    case .middle:
                        let pm = boxMetrics(it.parentBox)
                        t = it.parentShift - pm.xHeight / 2 - H / 2
                    case .textTop:
                        t = it.parentShift - boxMetrics(it.parentBox).ascent
                    case .textBottom:
                        t = it.parentShift + boxMetrics(it.parentBox).descent - H
                    default:
                        t = it.shift - atomicBaseline(b)
                    }
                    tops[i] = t
                    minTop = min(minTop, t); maxBot = max(maxBot, t + H)
                default: break
                }
            }
            var lineH = maxBot - minTop
            if tallest > lineH { maxBot += tallest - lineH; lineH = tallest }
            let baseline = lineTop - minTop
            let lineIndex = root.lines.count
            _ = lineIndex
            // Fragments and atomic positions.
            var stack: [(Int, Double, Bool)] = []
            for o in openStack { stack.append((o, startX, false)) }
            func inlineFrag(_ itemIdx: Int, _ x0: Double, _ x1: Double, _ hasL: Bool, _ hasR: Bool) {
                let it = items[itemIdx]
                let b = it.box
                let m = boxMetrics(b)
                var f = LayoutFrag()
                f.x = x0; f.w = max(0, x1 - x0)
                f.y = baseline + it.shift - m.ascent - b.padding.t - b.border.t
                f.h = m.ascent + m.descent + b.padding.vertical + b.border.vertical
                f.baseline = baseline + it.shift
                f.hasLeft = hasL; f.hasRight = hasR
                b.frags.append(f)
            }
            for (i, s) in segs.enumerated() {
                let it = items[s.item]
                switch it.kind {
                case .text:
                    let b = it.box
                    if s.end <= s.start { continue }
                    let m = boxMetrics(b)
                    if var lf = b.frags.last, spaceExtra == 0, Int(lf.end) == s.start, abs(lf.x + lf.w - s.x) < 0.01,
                       abs(lf.baseline - (baseline + it.shift)) < 0.01 {
                        lf.end = Int32(truncatingIfNeeded: s.end)
                        lf.w = s.x + s.w - lf.x
                        b.frags[b.frags.count - 1] = lf
                    } else {
                        var f = LayoutFrag()
                        f.x = s.x; f.w = s.w
                        f.y = baseline + it.shift - m.ascent
                        f.h = m.ascent + m.descent
                        f.baseline = baseline + it.shift
                        f.start = Int32(truncatingIfNeeded: s.start); f.end = Int32(truncatingIfNeeded: s.end)
                        b.frags.append(f)
                    }
                case .open:
                    stack.append((s.item, s.x + it.box.margin.l, true))
                case .close:
                    if let si = stack.lastIndex(where: { items[$0.0].box === it.box }) {
                        let (oi, x0, hl) = stack[si]
                        stack.remove(at: si)
                        inlineFrag(oi, x0, s.x + it.box.padding.r + it.box.border.r, hl, true)
                    }
                case .atomic:
                    let b = it.box
                    let H = b.h + b.margin.vertical
                    b.x = s.x + b.margin.l
                    switch b.style.verticalAlign.kind {
                    case .top: b.y = lineTop + b.margin.t
                    case .bottom: b.y = lineTop + lineH - H + b.margin.t
                    default: b.y = baseline + tops[i] + b.margin.t
                    }
                default: break
                }
            }
            openStack = []
            for (oi, x0, hl) in stack {
                inlineFrag(oi, x0, endX, hl, false)
                openStack.append(oi)
            }
            var line = LayoutLine()
            line.y = lineTop; line.h = lineH; line.baseline = baseline
            line.x = startX; line.w = endX - startX
            root.lines.append(line)
            lineTop += lineH
            firstLine = false
            if !pendingFloats.isEmpty {
                for f in pendingFloats { placeFloat(f) }
                pendingFloats.removeAll()
            }
            lineSpace()
        }

        var i = 0, off = 0
        var breakAllowed = true
        var guardSteps = 0
        while i < items.count {
            guardSteps += 1
            if guardSteps > 50_000_000 { break }
            var word: [LayoutSeg] = []
            var wordW = 0.0, trailing = 0.0
            var forced = false
            var wordHasContent = false
            var onlySpaces = true
            var special: Int? = nil
            var j = i, o = off
            var nextAllowed = true
            gather: while j < items.count {
                let it = items[j]
                switch it.kind {
                case .open:
                    var s = LayoutSeg(item: j); s.w = it.box.margin.l + it.box.border.l + it.box.padding.l
                    word.append(s); wordW += s.w; trailing = 0
                    j += 1; o = 0
                case .close:
                    var s = LayoutSeg(item: j); s.w = it.box.margin.r + it.box.border.r + it.box.padding.r
                    word.append(s); wordW += s.w
                    if s.w > 0 { trailing = 0 }
                    j += 1; o = 0
                case .float, .abs:
                    if !wordHasContent { special = j; j += 1; nextAllowed = breakAllowed }
                    else { nextAllowed = false }
                    break gather
                case .atomic:
                    if wordHasContent { nextAllowed = it.wraps; break gather }
                    let b = it.box
                    layoutAtomic(b, contentW: contentW, cbH: cbH)
                    var s = LayoutSeg(item: j); s.w = max(0, b.w + b.margin.horizontal)
                    word.append(s); wordW += s.w; trailing = 0
                    wordHasContent = true; onlySpaces = false
                    j += 1; o = 0
                    nextAllowed = it.wraps
                    break gather
                case .lineBreak:
                    word.append(LayoutSeg(item: j))
                    forced = true; wordHasContent = true; onlySpaces = false
                    j += 1; o = 0
                    break gather
                case .text:
                    guard let run = it.box.run, run.count > 0 else { j += 1; o = 0; continue }
                    let n = run.count
                    if o >= n { j += 1; o = 0; continue }
                    var e = o + 1
                    while e < n {
                        let bk = run.breaks[e]
                        if bk == 2 || (bk == 1 && it.wraps) { break }
                        e += 1
                    }
                    let w = Double(run.xs[e] - run.xs[o])
                    var t = e
                    let collapsible = it.box.style.whiteSpace.collapsesSpaces
                    while t > o && layoutIsSpace(run.scalars[t - 1]) { t -= 1 }
                    let tw = Double(run.xs[e] - run.xs[t])
                    var s = LayoutSeg(item: j); s.start = o; s.end = e; s.w = w
                    word.append(s)
                    wordW += w
                    if t > o || !collapsible { trailing = collapsible ? tw : 0; onlySpaces = false; wordHasContent = true }
                    else { trailing += tw; wordHasContent = wordHasContent || !collapsible }
                    if e < n {
                        if run.breaks[e] == 2 { forced = true }
                        o = e
                        nextAllowed = true
                        break gather
                    }
                    j += 1; o = 0
                    if run.breaks[n] == 2 { forced = true; break gather }
                    if it.wraps, let last = run.scalars.last {
                        let c = textBreakClass(last)
                        if c == .space || c == .zwsp || c == .hyphen || c == .ideograph {
                            // Closing inline boxes stay on this side of the break.
                            while j < items.count && items[j].kind == .close {
                                let cb = items[j].box
                                var cs = LayoutSeg(item: j); cs.w = cb.margin.r + cb.border.r + cb.padding.r
                                word.append(cs); wordW += cs.w
                                j += 1
                            }
                            nextAllowed = true
                            break gather
                        }
                    }
                }
            }
            if !word.isEmpty {
                if !hasContent && onlySpaces && !forced {
                    // Collapsible spaces at the start of a line disappear.
                    for s in word where items[s.item].kind != .text { segs.append(s); lineW += s.w }
                } else {
                    var tries = 0
                    while true {
                        let fits = lineW + wordW - trailing <= availW - (firstLine ? indentPx : 0) + 0.01
                        if fits { break }
                        if hasContent && breakAllowed {
                            finishLine(forced: false, last: false)
                            continue
                        }
                        if !hasContent && !floats.isEmpty && availW < contentW - 0.01 && tries < floats.list.count + 2,
                           let nb = floats.nextBottom(after: oy + lineTop, h: strutL), nb - oy > lineTop {
                            lineTop = nb - oy
                            lineSpace()
                            tries += 1
                            continue
                        }
                        break
                    }
                    for s in word { segs.append(s) }
                    lineW += wordW
                    hasContent = hasContent || wordHasContent
                }
                if forced { finishLine(forced: true, last: false) }
            }
            if let sp = special {
                let it = items[sp]
                let b = it.box
                if it.kind == .abs {
                    b.staticParent = root
                    b.staticX = cl + availL + lineW
                    b.staticY = lineTop
                } else {
                    layoutBlock(b, cbW: contentW, cbH: cbH, floats: floats, cbOX: ox + cl, oy: 0, avail: contentW, shrink: true)
                    let ow = b.w + b.margin.horizontal
                    if !hasContent || lineW + ow <= availW {
                        placeFloat(sp)
                        lineSpace()
                    } else {
                        pendingFloats.append(sp)
                    }
                }
            }
            breakAllowed = nextAllowed
            i = j; off = o
        }
        if !segs.isEmpty { finishLine(forced: false, last: true) }
        for f in pendingFloats { placeFloat(f) }
        return max(0, lineTop - ct)
    }

    // MARK: Intrinsic widths of inline content

    func inlineIntrinsic(_ root: LayoutBox) -> (Double, Double) {
        ensureItems(root)
        guard let items = root.items else { return (0, 0) }
        var maxWord = 0.0, word = 0.0, line = 0.0, maxLine = 0.0
        var floatsW = 0.0
        let indent = max(0, layoutSan(root.style.textIndent.px))
        line = indent
        for it in items {
            switch it.kind {
            case .open:
                resolveEdges(it.box, 0)
                let w = it.box.margin.l + it.box.border.l + it.box.padding.l
                word += w; line += w
            case .close:
                let w = it.box.margin.r + it.box.border.r + it.box.padding.r
                word += w; line += w
            case .lineBreak:
                maxWord = max(maxWord, word); word = 0
                maxLine = max(maxLine, line); line = 0
            case .float:
                let (mn, mx) = intrinsic(it.box)
                resolveEdges(it.box, 0)
                let m = max(0, it.box.margin.horizontal)
                maxWord = max(maxWord, mn + m)
                floatsW += mx + m
            case .abs: break
            case .atomic:
                let (mn, mx) = intrinsic(it.box)
                resolveEdges(it.box, 0)
                let m = max(0, it.box.margin.horizontal)
                if it.wraps { maxWord = max(maxWord, word); word = 0 }
                word += mn + m
                if it.wraps { maxWord = max(maxWord, word); word = 0 }
                line += mx + m
            case .text:
                guard let run = it.box.run else { continue }
                let n = run.count
                var start = 0
                var k = 1
                while k <= n {
                    let bk = k < n ? run.breaks[k] : 0
                    if k == n || bk == 2 || (bk == 1 && it.wraps) {
                        var t = k
                        while t > start && layoutIsSpace(run.scalars[t - 1]) && it.box.style.whiteSpace.collapsesSpaces { t -= 1 }
                        word += Double(run.xs[t] - run.xs[start])
                        line += Double(run.xs[k] - run.xs[start])
                        if k < n || run.breaks[n] == 2 || (it.wraps && t < k) {
                            maxWord = max(maxWord, word); word = 0
                        }
                        if k < n && bk == 2 || (k == n && run.breaks[n] == 2) { maxLine = max(maxLine, line); line = 0 }
                        start = k
                    }
                    k += 1
                }
            }
        }
        maxWord = max(maxWord, word)
        maxLine = max(maxLine, line)
        return (layoutPos(maxWord), layoutPos(maxLine + floatsW))
    }
}
