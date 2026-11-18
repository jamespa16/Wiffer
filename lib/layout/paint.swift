// Paint: the display list (CSS 2.1 Appendix E order, simplified) and the
// rasterizer into an XRGB buffer.
//
// Each stacking layer (the root, positioned boxes, and, atomically, floats
// and atomic inlines) paints: its own background and borders, negative
// z-index layers, in-flow block backgrounds and borders, floats, inline
// content (inline box backgrounds, text, decorations, atomic inlines, list
// markers), positioned descendants with z-index auto/0 in tree order, then
// positive z-index layers. Every item carries its clip (overflow ancestors)
// and alpha (accumulated opacity). Items are in page coordinates, except
// those inside position: fixed subtrees, which are viewport-relative.
//
// Painting walks the list once and skips items outside the visible rect.
// Hit testing walks it backwards.

enum LayoutItemKind: UInt8 { case hit, fill, border, text, image, bgImage, control }

struct LayoutDisplayItem {
    var kind: LayoutItemKind
    var rect: LayoutRect
    var clip: LayoutRect
    /// 0xAARRGGBB (alpha already multiplied by opacity).
    var color: UInt32
    unowned(unsafe) var box: LayoutBox
    /// text: fragment index; border: side (0-3) | style << 4; bgImage: repeat mode.
    var a: Int32 = 0
    var fixed = false
}

struct LayoutDisplayList {
    var items: [LayoutDisplayItem] = []
    init() {}

    /// The box of the topmost hit-testable item at a page point.
    func hit(x: Double, y: Double, scrollX: Double, scrollY: Double) -> LayoutBox? {
        var i = items.count - 1
        while i >= 0 {
            let it = items[i]
            i -= 1
            switch it.kind {
            case .hit, .text, .image, .control: break
            default: continue
            }
            let px = it.fixed ? x - scrollX : x, py = it.fixed ? y - scrollY : y
            if it.rect.contains(px, py) && it.clip.contains(px, py) { return it.box }
        }
        return nil
    }
}

/// What the browser's control painter gets: a form control to draw at
/// `borderBox`/`contentBox` (buffer coordinates), clipped to `clip`.
struct LayoutControlPaint {
    var node: HTMLNode
    var kind: LayoutReplacedKind
    var borderBox: LayoutRect
    var contentBox: LayoutRect
    var clip: LayoutRect
    var dst: UnsafeMutablePointer<UInt32>
    var stride: Int
    var width: Int
    var height: Int
}

private func layoutARGB(_ c: CSSColor, _ alpha: Double) -> UInt32 {
    let a = UInt32(max(0, min(255, (Double(c.a) * max(0, min(1, alpha))).rounded())))
    return a << 24 | UInt32(c.r) << 16 | UInt32(c.g) << 8 | UInt32(c.b)
}

private func layoutShade(_ c: CSSColor, _ k: Double) -> CSSColor {
    func f(_ v: UInt8) -> UInt8 { UInt8(max(0, min(255, (Double(v) * k).rounded()))) }
    if c.r == 0 && c.g == 0 && c.b == 0 && k > 1 { return CSSColor(r: 128, g: 128, b: 128, a: c.a) }
    return CSSColor(r: f(c.r), g: f(c.g), b: f(c.b), a: c.a)
}

extension LayoutEngine {
    // MARK: Display list

    func buildDisplay() {
        var list: [LayoutDisplayItem] = []
        if let r = root { paintLayer(r, &list, 0) }
        var d = LayoutDisplayList()
        d.items = list
        setDisplay(d)
    }

    private func isLayer(_ b: LayoutBox) -> Bool { b.style.position != .static && b.kind != .text }

    private func paintLayer(_ L: LayoutBox, _ list: inout [LayoutDisplayItem], _ depth: Int) {
        if depth > limits.maxDepth + 16 { return }
        var neg: [(Int, Int, LayoutBox)] = [], zero: [LayoutBox] = [], pos: [(Int, Int, LayoutBox)] = []
        var floats: [LayoutBox] = []
        var blocks: [LayoutBox] = []
        var ifcRoots: [LayoutBox] = []
        var markers: [LayoutBox] = []
        var order = 0
        if L.kind == .inline {
            // A positioned inline box: its fragments and its part of the line content.
            paintInlineDecorations(L, &list)
        } else {
            paintDecorations(L, &list)
            if L.childrenInline { ifcRoots.append(L) }
            if L.marker != nil { markers.append(L) }
        }
        var stack: [LayoutBox] = []
        var i = L.children.count - 1
        while i >= 0 { stack.append(L.children[i]); i -= 1 }
        while let b = stack.popLast() {
            if isLayer(b) {
                let z = b.style.zIndex ?? 0
                order += 1
                if z < 0 { neg.append((z, order, b)) } else if z > 0 { pos.append((z, order, b)) } else { zero.append(b) }
                continue
            }
            if b.isFloat { floats.append(b); continue }
            if b.isAtomicInline { continue }
            if b.kind == .inline || b.kind == .text || b.kind == .lineBreak {
                var k = b.children.count - 1
                while k >= 0 { stack.append(b.children[k]); k -= 1 }
                continue
            }
            blocks.append(b)
            if b.childrenInline { ifcRoots.append(b) }
            if b.marker != nil { markers.append(b) }
            var k = b.children.count - 1
            while k >= 0 { stack.append(b.children[k]); k -= 1 }
        }
        neg.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        pos.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        for (_, _, b) in neg { paintLayer(b, &list, depth + 1) }
        for b in blocks { paintDecorations(b, &list) }
        for f in floats { paintLayer(f, &list, depth + 1) }
        if L.kind == .inline {
            if let rootBox = ctx.coordContainer(L), let items = rootBox.items,
               let start = items.firstIndex(where: { $0.kind == .open && $0.box === L }) {
                var end = start + 1
                while end < items.count && !(items[end].kind == .close && items[end].box === L) { end += 1 }
                paintItems(items, start + 1, end, &list, depth)
            }
        }
        for r in ifcRoots { if let items = r.items { paintItems(items, 0, items.count, &list, depth) } }
        for m in markers { if let mk = m.marker { paintMarker(mk, &list) } }
        for b in zero { paintLayer(b, &list, depth + 1) }
        for (_, _, b) in pos { paintLayer(b, &list, depth + 1) }
    }

    private func paintItems(_ items: [LayoutInlineItem], _ from: Int, _ to: Int, _ list: inout [LayoutDisplayItem], _ depth: Int) {
        var i = from
        while i < to && i < items.count {
            let it = items[i]
            switch it.kind {
            case .open:
                if isLayer(it.box) {
                    var e = i + 1
                    while e < items.count && !(items[e].kind == .close && items[e].box === it.box) { e += 1 }
                    i = e + 1
                    continue
                }
                paintInlineDecorations(it.box, &list)
            case .text:
                paintText(it.box, &list)
            case .atomic:
                if !isLayer(it.box) && !it.box.isFloat { paintLayer(it.box, &list, depth + 1) }
            default:
                break
            }
            i += 1
        }
    }

    private func push(_ list: inout [LayoutDisplayItem], _ kind: LayoutItemKind, _ r: LayoutRect, _ b: LayoutBox,
                      color: UInt32 = 0, a: Int32 = 0) {
        if r.w <= 0 || r.h <= 0 { return }
        list.append(LayoutDisplayItem(kind: kind, rect: r, clip: b.clip, color: color, box: b, a: a, fixed: b.inFixed))
    }

    @inline(never)
    private func paintBorders(_ b: LayoutBox, _ r: LayoutRect, _ e: LayoutEdges, _ list: inout [LayoutDisplayItem],
                              left: Bool = true, right: Bool = true) {
        let s = b.style
        let al = b.opacityAcc
        func side(_ k: Int, _ rect: LayoutRect, _ st: CSSBorderStyle, _ c0: CSSColor) {
            if !st.isVisible || c0.a == 0 { return }
            var c = c0
            switch st {
            case .inset, .groove: c = (k == 0 || k == 3) ? layoutShade(c0, 0.6) : layoutShade(c0, 1.4)
            case .outset, .ridge: c = (k == 0 || k == 3) ? layoutShade(c0, 1.4) : layoutShade(c0, 0.6)
            default: break
            }
            push(&list, .border, rect, b, color: layoutARGB(c, al), a: Int32(k) | Int32(st.rawValue) << 4)
        }
        if e.t > 0 { side(0, LayoutRect(x: r.x, y: r.y, w: r.w, h: e.t), s.borderTopStyle, s.borderTopColor) }
        if e.b > 0 { side(2, LayoutRect(x: r.x, y: r.maxY - e.b, w: r.w, h: e.b), s.borderBottomStyle, s.borderBottomColor) }
        if e.l > 0 && left { side(3, LayoutRect(x: r.x, y: r.y + e.t, w: e.l, h: r.h - e.t - e.b), s.borderLeftStyle, s.borderLeftColor) }
        if e.r > 0 && right { side(1, LayoutRect(x: r.maxX - e.r, y: r.y + e.t, w: e.r, h: r.h - e.t - e.b), s.borderRightStyle, s.borderRightColor) }
    }

    @inline(never)
    private func paintDecorations(_ b: LayoutBox, _ list: inout [LayoutDisplayItem]) {
        if b.kind == .text || b.kind == .lineBreak || b.kind == .inline { return }
        let r = layoutBoxRect(b)
        let visible = b.style.visibility == .visible && b.opacityAcc > 0.004
        if visible {
            let s = b.style
            if b.paintsBackground && s.backgroundColor.a > 0 {
                push(&list, .fill, r, b, color: layoutARGB(s.backgroundColor, b.opacityAcc))
            }
            if s.backgroundImage != nil && b.paintsBackground {
                let pb = LayoutRect(x: r.x + b.border.l, y: r.y + b.border.t, w: r.w - b.border.horizontal, h: r.h - b.border.vertical)
                push(&list, .bgImage, pb, b, color: layoutARGB(CSSColor.white, b.opacityAcc), a: Int32(s.backgroundRepeat.rawValue))
            }
            paintBorders(b, r, b.border, &list)
        }
        push(&list, .hit, r, b)
        if visible && b.kind == .replaced {
            let cb = b.contentBox
            if b.replaced == .image {
                push(&list, .image, cb, b, color: layoutARGB(CSSColor.white, b.opacityAcc))
            } else if b.replaced.isControl {
                push(&list, .control, cb, b, color: layoutARGB(b.style.color, b.opacityAcc))
            } else {
                push(&list, .fill, cb, b, color: layoutARGB(CSSColor(r: 0xdd, g: 0xdd, b: 0xdd), b.opacityAcc))
            }
        }
    }

    @inline(never)
    private func paintInlineDecorations(_ b: LayoutBox, _ list: inout [LayoutDisplayItem]) {
        let s = b.style
        let visible = s.visibility == .visible && b.opacityAcc > 0.004
        for f in b.frags {
            let r = LayoutRect(x: b.ax + f.x, y: b.ay + f.y, w: f.w, h: f.h)
            if visible {
                if s.backgroundColor.a > 0 { push(&list, .fill, r, b, color: layoutARGB(s.backgroundColor, b.opacityAcc)) }
                if s.backgroundImage != nil {
                    push(&list, .bgImage, r, b, color: layoutARGB(CSSColor.white, b.opacityAcc), a: Int32(s.backgroundRepeat.rawValue))
                }
                paintBorders(b, r, b.border, &list, left: f.hasLeft, right: f.hasRight)
            }
            push(&list, .hit, r, b)
        }
    }

    @inline(never)
    private func paintText(_ b: LayoutBox, _ list: inout [LayoutDisplayItem]) {
        let s = b.style
        let visible = s.visibility == .visible && b.opacityAcc > 0.004
        guard let run = b.run else { return }
        let fs = Double(run.size)
        for (fi, f) in b.frags.enumerated() {
            let r = LayoutRect(x: b.ax + f.x, y: b.ay + f.y, w: f.w, h: f.h)
            if !visible { push(&list, .hit, r, b); continue }
            push(&list, .text, r, b, color: layoutARGB(s.color, b.opacityAcc), a: Int32(fi))
            if b.deco != 0 && f.w > 0 {
                let t = max(1, (fs / 14).rounded())
                let base = b.ay + f.baseline
                let col = layoutARGB(b.decoColor, b.opacityAcc)
                if b.deco & 1 != 0 {
                    push(&list, .fill, LayoutRect(x: r.x, y: (base + max(1, fs * 0.09)).rounded(), w: r.w, h: t), b, color: col)
                }
                if b.deco & 2 != 0 {
                    push(&list, .fill, LayoutRect(x: r.x, y: r.y.rounded(), w: r.w, h: t), b, color: col)
                }
                if b.deco & 4 != 0 {
                    let xh = boxXHeight(b)
                    push(&list, .fill, LayoutRect(x: r.x, y: (base - xh / 2 - t / 2).rounded(), w: r.w, h: t), b, color: col)
                }
            }
        }
    }

    private func boxXHeight(_ b: LayoutBox) -> Double { ctx.boxMetrics(b).xHeight }

    @inline(never)
    private func paintMarker(_ m: LayoutBox, _ list: inout [LayoutDisplayItem]) {
        guard m.run != nil, !m.frags.isEmpty, m.style.visibility == .visible else { return }
        let r = LayoutRect(x: m.ax, y: m.ay, w: m.w, h: m.h)
        push(&list, .text, r, m, color: layoutARGB(m.style.color, m.opacityAcc), a: 0)
    }

    // MARK: Rasterizer

    /// Paint the visible part of the page into an XRGB buffer. (scrollX,
    /// scrollY) is the page point at the buffer's top-left. `images` returns
    /// a decoded bitmap for a URL as written in the document (nil if not
    /// loaded); scaled copies are cached here. `controlPainter` may draw form
    /// controls itself (return true), else a default appearance is drawn.
    func paint(into dst: UnsafeMutablePointer<UInt32>, stride: Int, width: Int, height: Int,
               scrollX: Double = 0, scrollY: Double = 0,
               images: ((String) -> ImageBitmap?)? = nil,
               controlPainter: ((LayoutControlPaint) -> Bool)? = nil) {
        guard width > 0, height > 0, stride >= width else { return }
        let bg = canvasColor
        for y in 0..<height {
            let row = dst + y * stride
            for x in 0..<width { row[x] = bg }
        }
        let screen = LayoutRect(x: 0, y: 0, w: Double(width), h: Double(height))
        let sx = layoutSan(scrollX), sy = layoutSan(scrollY)
        for it in display.items {
            if it.kind == .hit { continue }
            let ox = it.fixed ? 0 : sx, oy = it.fixed ? 0 : sy
            let r = LayoutRect(x: it.rect.x - ox, y: it.rect.y - oy, w: it.rect.w, h: it.rect.h)
            if !r.intersects(screen) { continue }
            var c = LayoutRect(x: it.clip.x - ox, y: it.clip.y - oy, w: it.clip.w, h: it.clip.h).intersection(screen)
            if it.clip.w >= layoutMaxCoord { c = screen }
            if c.w <= 0 || c.h <= 0 || !r.intersects(c) { continue }
            let cx0 = max(0, min(width, layoutInt(c.x))), cy0 = max(0, min(height, layoutInt(c.y)))
            let cx1 = max(cx0, min(width, layoutInt(c.maxX))), cy1 = max(cy0, min(height, layoutInt(c.maxY)))
            if cx0 >= cx1 || cy0 >= cy1 { continue }
            let sub = dst + cy0 * stride + cx0
            let sw = cx1 - cx0, sh = cy1 - cy0
            switch it.kind {
            case .fill:
                layoutFill(sub, stride, sw, sh, layoutInt(r.x) - cx0, layoutInt(r.y) - cy0, layoutInt(r.maxX) - cx0, layoutInt(r.maxY) - cy0, it.color)
            case .border:
                paintBorderItem(it, r, sub, stride, sw, sh, cx0, cy0)
            case .text:
                let b = it.box
                guard let run = b.run, Int(it.a) < b.frags.count else { continue }
                let f = b.frags[Int(it.a)]
                let alpha = UInt8(it.color >> 24)
                if alpha == 0 { continue }
                let x = Float(b.ax + f.x - ox) - Float(cx0)
                let base = layoutInt(b.ay + f.baseline - oy) - cy0
                text.draw(run, from: Int(f.start), to: Int(f.end), into: sub, stride: stride, width: sw, height: sh,
                          x: x, baselineY: base, color: it.color & 0xffffff, alpha: alpha)
            case .image:
                guard let src = it.box.src, let get = images, let bm = get(src) else {
                    paintAltText(it.box, r, sub, stride, sw, sh, cx0, cy0)
                    continue
                }
                let w = layoutInt(r.w), h = layoutInt(r.h)
                if w <= 0 || h <= 0 { continue }
                guard let scaled = scaledImage(src, bm, w, h) else { continue }
                imageBlend(into: sub, stride: stride, width: sw, height: sh, src: scaled, x: layoutInt(r.x) - cx0, y: layoutInt(r.y) - cy0)
            case .bgImage:
                guard let url = it.box.style.backgroundImage, let get = images, let bm = get(url), bm.width > 0, bm.height > 0 else { continue }
                let rep = CSSBackgroundRepeat(rawValue: UInt8(truncatingIfNeeded: it.a)) ?? .repeat
                let ox0 = layoutInt(r.x) - cx0, oy0 = layoutInt(r.y) - cy0
                // Clip tiles to the item's own rect as well.
                let ix0 = max(0, ox0), iy0 = max(0, oy0)
                let ix1 = min(sw, ox0 + layoutInt(r.w)), iy1 = min(sh, oy0 + layoutInt(r.h))
                if ix0 >= ix1 || iy0 >= iy1 { continue }
                let tsub = sub + iy0 * stride + ix0
                let tw = ix1 - ix0, th = iy1 - iy0
                let bx = ox0 - ix0, by = oy0 - iy0
                let nx = (rep == .repeat || rep == .repeatX) ? (tw - bx + bm.width - 1) / bm.width : 1
                let ny = (rep == .repeat || rep == .repeatY) ? (th - by + bm.height - 1) / bm.height : 1
                if nx * ny > 20_000 { continue }
                for ty in 0..<max(1, ny) {
                    for tx in 0..<max(1, nx) {
                        imageBlend(into: tsub, stride: stride, width: tw, height: th, src: bm, x: bx + tx * bm.width, y: by + ty * bm.height)
                    }
                }
            case .control:
                let b = it.box
                if let cp = controlPainter, let n = b.node {
                    let bbox = LayoutRect(x: b.ax - ox, y: b.ay - oy, w: b.w, h: b.h)
                    let info = LayoutControlPaint(node: n, kind: b.replaced, borderBox: bbox, contentBox: r, clip: c,
                                                  dst: dst, stride: stride, width: width, height: height)
                    if cp(info) { continue }
                }
                paintControl(b, r, sub, stride, sw, sh, cx0, cy0, it.color)
            case .hit:
                break
            }
        }
    }

    private func paintBorderItem(_ it: LayoutDisplayItem, _ r: LayoutRect, _ sub: UnsafeMutablePointer<UInt32>, _ stride: Int,
                                 _ sw: Int, _ sh: Int, _ cx0: Int, _ cy0: Int) {
        let sideK = Int(it.a & 15)
        let st = CSSBorderStyle(rawValue: UInt8(truncatingIfNeeded: it.a >> 4)) ?? .solid
        let x0 = layoutInt(r.x) - cx0, y0 = layoutInt(r.y) - cy0, x1 = layoutInt(r.maxX) - cx0, y1 = layoutInt(r.maxY) - cy0
        let horizontal = sideK == 0 || sideK == 2
        switch st {
        case .dashed, .dotted:
            let thick = max(1, horizontal ? y1 - y0 : x1 - x0)
            let on = st == .dotted ? thick : thick * 3
            let period = on * 2
            if horizontal {
                var x = x0
                var guardN = 0
                while x < x1 && guardN < 100_000 {
                    if x + on > -period && x < sw + period { layoutFill(sub, stride, sw, sh, x, y0, min(x + on, x1), y1, it.color) }
                    x += period; guardN += 1
                }
            } else {
                var y = y0
                var guardN = 0
                while y < y1 && guardN < 100_000 {
                    if y + on > -period && y < sh + period { layoutFill(sub, stride, sw, sh, x0, y, x1, min(y + on, y1), it.color) }
                    y += period; guardN += 1
                }
            }
        case .double:
            let thick = horizontal ? y1 - y0 : x1 - x0
            if thick >= 3 {
                let t = (thick + 1) / 3
                if horizontal {
                    layoutFill(sub, stride, sw, sh, x0, y0, x1, y0 + t, it.color)
                    layoutFill(sub, stride, sw, sh, x0, y1 - t, x1, y1, it.color)
                } else {
                    layoutFill(sub, stride, sw, sh, x0, y0, x0 + t, y1, it.color)
                    layoutFill(sub, stride, sw, sh, x1 - t, y0, x1, y1, it.color)
                }
            } else { layoutFill(sub, stride, sw, sh, x0, y0, x1, y1, it.color) }
        default:
            layoutFill(sub, stride, sw, sh, x0, y0, x1, y1, it.color)
        }
    }

    private func scaledImage(_ url: String, _ bm: ImageBitmap, _ w: Int, _ h: Int) -> ImageBitmap? {
        if bm.width == w && bm.height == h { return bm }
        let key = "\(w)x\(h) " + url
        if let s = scaledCache[key] { return s }
        guard let s = imageScaleBilinear(bm, width: w, height: h, maxBytes: 64 << 20) else { return nil }
        if scaledBytes + s.byteCount > 64 << 20 { scaledCache = [:]; scaledBytes = 0 }
        scaledCache[key] = s
        scaledBytes += s.byteCount
        return s
    }

    private func drawLabel(_ run: TextRun, _ x: Double, _ r: LayoutRect, _ b: LayoutBox, _ sub: UnsafeMutablePointer<UInt32>,
                           _ stride: Int, _ sw: Int, _ sh: Int, _ cx0: Int, _ cy0: Int, _ color: UInt32) {
        let m = ctx.boxMetrics(b)
        let base = r.y + (r.h - m.ascent - m.descent) / 2 + m.ascent
        text.draw(run, from: 0, to: run.count, into: sub, stride: stride, width: sw, height: sh,
                  x: Float(x) - Float(cx0), baselineY: layoutInt(base) - cy0, color: color & 0xffffff,
                  alpha: UInt8(max(1, color >> 24)))
    }

    private func paintAltText(_ b: LayoutBox, _ r: LayoutRect, _ sub: UnsafeMutablePointer<UInt32>, _ stride: Int,
                              _ sw: Int, _ sh: Int, _ cx0: Int, _ cy0: Int) {
        guard !b.label.isEmpty, r.w > 0, r.h > 0 else { return }
        if b.labelRun == nil { b.labelRun = ctx.shape(textScalars(b.label), b) }
        guard let run = b.labelRun else { return }
        drawLabel(run, r.x + 2, r, b, sub, stride, sw, sh, cx0, cy0, layoutARGB(b.style.color, b.opacityAcc))
    }

    private func paintControl(_ b: LayoutBox, _ r: LayoutRect, _ sub: UnsafeMutablePointer<UInt32>, _ stride: Int,
                              _ sw: Int, _ sh: Int, _ cx0: Int, _ cy0: Int, _ color: UInt32) {
        guard let n = b.node else { return }
        let id = ObjectIdentifier(n)
        let x0 = layoutInt(r.x) - cx0, y0 = layoutInt(r.y) - cy0, x1 = layoutInt(r.maxX) - cx0, y1 = layoutInt(r.maxY) - cy0
        switch b.replaced {
        case .checkbox, .radio:
            let checked = controlChecked[id] ?? (n.attribute("checked") != nil)
            let s = min(x1 - x0, y1 - y0)
            if s <= 2 { return }
            let border: UInt32 = 0xff76_7676
            if b.replaced == .checkbox {
                layoutFill(sub, stride, sw, sh, x0, y0, x0 + s, y0 + s, border)
                layoutFill(sub, stride, sw, sh, x0 + 1, y0 + 1, x0 + s - 1, y0 + s - 1, 0xffff_ffff)
                if checked { layoutFill(sub, stride, sw, sh, x0 + 3, y0 + 3, x0 + s - 3, y0 + s - 3, 0xff00_5fcc) }
            } else {
                let cx = Double(x0) + Double(s) / 2, cy = Double(y0) + Double(s) / 2, rad = Double(s) / 2
                layoutDisc(sub, stride, sw, sh, cx, cy, rad, border)
                layoutDisc(sub, stride, sw, sh, cx, cy, rad - 1, 0xffff_ffff)
                if checked { layoutDisc(sub, stride, sw, sh, cx, cy, rad - 3, 0xff00_5fcc) }
            }
        case .textInput, .password, .textarea:
            var s = controlValues[id] ?? b.label
            var col = color
            if controlValues[id] == nil && b.labelIsPlaceholder { col = (color & 0xff00_0000) | 0x75_7575 }
            if b.replaced == .password && !(controlValues[id] == nil && b.labelIsPlaceholder) {
                var p = ""
                for _ in s.unicodeScalars.prefix(1000) { p += "\u{2022}" }
                s = p
            }
            if s.isEmpty { return }
            if b.replaced == .textarea {
                let m = ctx.boxMetrics(b)
                let lh = ctx.boxLineHeight(b)
                var y = r.y
                var line: [UInt32] = []
                var lines: [[UInt32]] = []
                for c in textScalars(s) { if c == 0x0a { lines.append(line); line = [] } else { line.append(c) } }
                lines.append(line)
                for l in lines.prefix(500) {
                    if y > r.maxY { break }
                    let run = ctx.shape(l, b)
                    text.draw(run, from: 0, to: run.count, into: sub, stride: stride, width: sw, height: sh,
                              x: Float(r.x) - Float(cx0), baselineY: layoutInt(y + (lh - m.ascent - m.descent) / 2 + m.ascent) - cy0,
                              color: col & 0xffffff, alpha: UInt8(max(1, col >> 24)))
                    y += lh
                }
                return
            }
            let run = (controlValues[id] == nil && b.replaced != .password) ? (b.labelRun ?? ctx.shape(textScalars(s), b)) : ctx.shape(textScalars(s), b)
            if b.labelRun == nil && controlValues[id] == nil && b.replaced != .password { b.labelRun = run }
            drawLabel(run, r.x, r, b, sub, stride, sw, sh, cx0, cy0, col)
        case .button:
            if b.labelRun == nil { b.labelRun = ctx.shape(textScalars(b.label), b) }
            guard let run = b.labelRun else { return }
            drawLabel(run, r.x + max(0, (r.w - Double(run.width)) / 2), r, b, sub, stride, sw, sh, cx0, cy0, color)
        case .select:
            let label = controlValues[id] ?? b.label
            let run = ctx.shape(textScalars(label), b)
            drawLabel(run, r.x, r, b, sub, stride, sw, sh, cx0, cy0, color)
            // A small down arrow at the right.
            let ax = x1 - 10, ay = (y0 + y1) / 2 - 2
            for k in 0..<4 { layoutFill(sub, stride, sw, sh, ax + k, ay + k, ax + 7 - k, ay + k + 1, 0xff33_3333) }
        default:
            break
        }
    }
}

/// Fill [x0, x1) x [y0, y1) (clipped to w x h) with an ARGB color.
func layoutFill(_ dst: UnsafeMutablePointer<UInt32>, _ stride: Int, _ w: Int, _ h: Int,
                _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ argb: UInt32) {
    let a = Int(argb >> 24)
    if a == 0 { return }
    let ax = max(0, x0), ay = max(0, y0), bx = min(w, x1), by = min(h, y1)
    if ax >= bx || ay >= by { return }
    let c = argb & 0xff_ffff
    if a == 255 {
        for y in ay..<by {
            let row = dst + y * stride
            for x in ax..<bx { row[x] = c }
        }
        return
    }
    let cr = Int(c >> 16 & 255), cg = Int(c >> 8 & 255), cb = Int(c & 255)
    let ia = 255 - a
    for y in ay..<by {
        let row = dst + y * stride
        for x in ax..<bx {
            let d = row[x]
            let r = (cr * a + Int(d >> 16 & 255) * ia + 127) / 255
            let g = (cg * a + Int(d >> 8 & 255) * ia + 127) / 255
            let b = (cb * a + Int(d & 255) * ia + 127) / 255
            row[x] = UInt32(r << 16 | g << 8 | b)
        }
    }
}

/// A filled circle (no antialiasing).
func layoutDisc(_ dst: UnsafeMutablePointer<UInt32>, _ stride: Int, _ w: Int, _ h: Int,
                _ cx: Double, _ cy: Double, _ r: Double, _ argb: UInt32) {
    if r <= 0 { return }
    let y0 = max(0, layoutInt(cy - r) - 1), y1 = min(h, layoutInt(cy + r) + 1)
    if y0 >= y1 { return }
    for y in y0..<y1 {
        let dy = Double(y) + 0.5 - cy
        let d2 = r * r - dy * dy
        if d2 < 0 { continue }
        let dx = d2.squareRoot()
        layoutFill(dst, stride, w, h, layoutInt(cx - dx), y, layoutInt(cx + dx), y + 1, argb)
    }
}
