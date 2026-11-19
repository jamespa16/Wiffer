// The SVG renderer: walks the element tree with a current transform,
// viewport, clip and inherited style, and paints shapes into a premultiplied
// RGBA canvas through lib/raster (fills; strokes become fills).
//
// Structure: svg (nested viewports with viewBox / preserveAspectRatio and
// overflow clipping), g, a, switch (first child), use (local #id and
// external file#id through SVGDocument.externalDocument; cycles, depth and
// the total drawn count are capped, which defuses `use` bombs), symbol.
// Paint: solid colors, currentColor, linear and radial gradients (stops,
// units, gradientTransform, spread, href inheritance), fill/stroke opacity,
// element opacity (an offscreen layer when both fill and stroke paint or
// the element is a group), clip-path with clipPath elements (both units,
// clip-rule). Not rendered: text, image, pattern, mask, marker, filters.

/// A rendered image: straight-alpha 0xAARRGGBB, rows top to bottom.
struct SVGRaster {
    var width: Int
    var height: Int
    var pixels: [UInt32]
}

/// Premultiplied 0xAARRGGBB pixels covering [ox, ox + w) x [oy, oy + h).
private struct SVGCanvas {
    var ox: Int, oy: Int, w: Int, h: Int
    var px: [UInt32]
    init(_ r: RasterRect) {
        ox = r.x0; oy = r.y0; w = max(0, r.x1 - r.x0); h = max(0, r.y1 - r.y0)
        px = [UInt32](repeating: 0, count: w * h)
    }
}

private struct SVGCtx {
    var t: RasterTransform
    var vw: Double
    var vh: Double
    var clip: RasterRect
    var mask: RasterMask?
    var styleIndex: Int
    var useDepth: Int
    var depth: Int
    unowned(unsafe) var doc: SVGDocument

    var diag: Double { ((vw * vw + vh * vh) / 2).squareRoot() }
}

private enum SVGPaintServer {
    case solid(UInt32)          // premultiplied
    case gradient(SVGGradient)
}

private struct SVGGradient {
    var radial: Bool
    /// Device pixel center -> gradient space.
    var inv: RasterTransform
    var x1 = 0.0, y1 = 0.0, x2 = 1.0, y2 = 0.0        // linear
    var cx = 0.5, cy = 0.5, r = 0.5, fx = 0.5, fy = 0.5, fr = 0.0  // radial
    var spread: UInt8 = 0       // 0 pad, 1 reflect, 2 repeat
    var lut: [UInt32]           // 256 premultiplied colors
}

/// Render `doc` at width x height pixels. `rootParentStyle` is the style the
/// root element inherits from (lib/layout passes the HTML parent's; default:
/// initial values with black text). nil if the size is out of range.
func svgRender(_ doc: SVGDocument, width: Int, height: Int, rootParentStyle: CSSComputedStyle? = nil) -> SVGRaster? {
    let lim = doc.limits
    guard width > 0, height > 0, width <= lim.maxDimension, height <= lim.maxDimension else { return nil }
    let r = SVGRenderer(doc, width, height)
    r.styles.append(rootParentStyle ?? CSSComputedStyle())
    if let root = doc.root {
        let ctx = SVGCtx(t: .identity, vw: Double(width), vh: Double(height),
                         clip: RasterRect(x0: 0, y0: 0, x1: width, y1: height), mask: nil,
                         styleIndex: 0, useDepth: 0, depth: 0, doc: doc)
        r.renderRoot(root, ctx, Double(width), Double(height))
    }
    return r.finish()
}

private final class SVGRenderer {
    let rootDoc: SVGDocument
    let limits: SVGLimits
    var layers: [SVGCanvas] = []
    var styles: [CSSComputedStyle] = []
    var drawn = 0
    var useStack: [ObjectIdentifier] = []

    init(_ doc: SVGDocument, _ w: Int, _ h: Int) {
        rootDoc = doc
        limits = doc.limits
        layers.append(SVGCanvas(RasterRect(x0: 0, y0: 0, x1: w, y1: h)))
    }

    func finish() -> SVGRaster {
        let c = layers[0]
        var out = c.px
        for k in 0..<out.count {
            let p = out[k]
            let a = p >> 24
            if a == 0 { out[k] = 0; continue }
            if a == 255 { continue }
            let r = min(255, ((p >> 16) & 255) * 255 / a)
            let g = min(255, ((p >> 8) & 255) * 255 / a)
            let b = min(255, (p & 255) * 255 / a)
            out[k] = a << 24 | r << 16 | g << 8 | b
        }
        return SVGRaster(width: c.w, height: c.h, pixels: out)
    }

    // MARK: Lengths

    func len(_ n: SVGNode, _ a: String, _ ctx: SVGCtx, _ axis: Int, _ def: Double, fontSize: Double) -> Double {
        guard let v = n.attr(a), let l = svgParseLength(v) else { return def }
        let base = axis == 0 ? ctx.vw : (axis == 1 ? ctx.vh : ctx.diag)
        return l.resolve(fontSize: fontSize, percentBase: base)
    }

    /// The device-space bbox of a user rect (for viewport clips).
    func deviceRect(_ t: RasterTransform, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> RasterRect {
        var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity
        for (px, py) in [(x, y), (x + w, y), (x, y + h), (x + w, y + h)] {
            let (dx, dy) = t.apply(px, py)
            x0 = min(x0, dx); y0 = min(y0, dy); x1 = max(x1, dx); y1 = max(y1, dy)
        }
        func ci(_ v: Double, _ up: Bool) -> Int {
            if !v.isFinite { return v > 0 ? 1 << 20 : -(1 << 20) }
            let c = max(-1e6, min(1e6, up ? v.rounded(.up) : v.rounded(.down)))
            return Int(c)
        }
        return RasterRect(x0: ci(x0, false), y0: ci(y0, false), x1: ci(x1, true), y1: ci(y1, true))
    }

    // MARK: Tree

    func renderRoot(_ root: SVGNode, _ ctx: SVGCtx, _ w: Double, _ h: Double) {
        guard root.name == "svg" else { return }
        let st = ctx.doc.style(root, parent: styles[ctx.styleIndex])
        if st.display == .none { return }
        styles.append(st)
        defer { styles.removeLast() }
        var c = ctx
        c.styleIndex = styles.count - 1
        viewport(root, c, 0, 0, w, h, clip: false)
    }

    /// Children of a viewport-establishing element (svg, symbol) mapped
    /// into (x, y, w, h) of the current user space.
    func viewport(_ n: SVGNode, _ ctx: SVGCtx, _ x: Double, _ y: Double, _ w: Double, _ h: Double, clip: Bool) {
        if !(w > 0) || !(h > 0) { return }
        var c = ctx
        if let vb = n.attr("viewBox").flatMap(svgParseViewBox) {
            let m = svgViewBoxTransform(vb, svgParseAspect(n.attr("preserveAspectRatio")), x, y, w, h)
            c.t = ctx.t.concat(m)
            c.vw = vb.w; c.vh = vb.h
        } else {
            c.t = ctx.t.concat(.translate(x, y))
            c.vw = w; c.vh = h
        }
        if clip && styles[ctx.styleIndex].overflowX != .visible {
            c.clip = c.clip.intersection(deviceRect(ctx.t, x, y, w, h))
            if c.clip.isEmpty { return }
        }
        renderChildren(n, c)
    }

    func renderChildren(_ n: SVGNode, _ ctx: SVGCtx) {
        for ch in n.children {
            if drawn >= limits.maxDrawn { return }
            renderNode(ch, ctx)
        }
    }

    @inline(never)
    func renderNode(_ n: SVGNode, _ ctx: SVGCtx) {
        switch n.name {
        case "svg", "g", "a", "switch", "use", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon": break
        default: return
        }
        drawn += 1
        if drawn > limits.maxDrawn || ctx.depth > 96 { return }
        let st = ctx.doc.style(n, parent: styles[ctx.styleIndex])
        if st.display == .none { return }
        styles.append(st)
        defer { styles.removeLast() }
        var c = ctx
        c.styleIndex = styles.count - 1
        c.depth = ctx.depth + 1
        if let tr = n.attr("transform"), let m = svgParseTransform(tr) {
            c.t = ctx.t.concat(m)
            if !c.t.isFinite { return }
        }
        let isShape = n.name != "svg" && n.name != "g" && n.name != "a" && n.name != "switch" && n.name != "use"
        // Group opacity and clipping wrap the element.
        let opacity = st.opacity
        if opacity <= 0.002 { return }
        if let ref = st.svg.clipPath, let m = clipMask(ref, n, c) {
            c.mask = m
        }
        var layered = false
        var fold = 1.0
        if opacity < 0.998 {
            let fills = st.svg.fill.kind != .none, strokes = st.svg.stroke.kind != .none
            if isShape && !(fills && strokes) { fold = opacity }
            else if layers.count < limits.maxLayers {
                layers.append(SVGCanvas(c.clip))
                layered = true
            } else { fold = opacity }
        }
        switch n.name {
        case "svg":
            let fs = st.fontSize
            let x = len(n, "x", ctx, 0, 0, fontSize: fs), y = len(n, "y", ctx, 1, 0, fontSize: fs)
            let w = len(n, "width", ctx, 0, ctx.vw, fontSize: fs), h = len(n, "height", ctx, 1, ctx.vh, fontSize: fs)
            viewport(n, c, x, y, w, h, clip: true)
        case "g", "a": renderChildren(n, c)
        case "switch":
            for ch in n.children where ch.attr("requiredExtensions") == nil {
                renderNode(ch, c)
                break
            }
        case "use": renderUse(n, c)
        default:
            if st.visibility == .visible, let p = geometry(n, c, st) { paintShape(p, n, c, st, fold) }
        }
        if layered {
            let top = layers.removeLast()
            composite(top, opacity)
        }
    }

    func composite(_ src: SVGCanvas, _ opacity: Double) {
        let k = UInt32(max(0, min(256, Int(opacity * 256 + 0.5))))
        let li = layers.count - 1
        let dx0 = layers[li].ox, dy0 = layers[li].oy, dw = layers[li].w, dh = layers[li].h
        layers[li].px.withUnsafeMutableBufferPointer { d in
            src.px.withUnsafeBufferPointer { s in
                for y in 0..<src.h {
                    let gy = y + src.oy - dy0
                    if gy < 0 || gy >= dh { continue }
                    for x in 0..<src.w {
                        let gx = x + src.ox - dx0
                        if gx < 0 || gx >= dw { continue }
                        let sp = s[y * src.w + x]
                        if sp == 0 { continue }
                        d[gy * dw + gx] = svgOver(svgScale(sp, k), d[gy * dw + gx])
                    }
                }
            }
        }
    }

    // MARK: use

    func renderUse(_ n: SVGNode, _ ctx: SVGCtx) {
        guard let href = n.href, ctx.useDepth < limits.maxUseDepth else { return }
        var doc = ctx.doc
        var target: SVGNode? = nil
        if href.utf8.first == 0x23 {
            target = doc.element(id: String(href.dropFirst()))
        } else if let ext = doc.externalDocument, let d = ext(href) {
            doc = d
            if let h = href.utf8.firstIndex(of: 0x23) {
                let id = String(decoding: href.utf8[href.utf8.index(after: h)...], as: UTF8.self)
                target = d.element(id: id)
            } else { target = d.root }
        }
        guard let tg = target else { return }
        // No cycles: not an ancestor, not already being expanded.
        var a: SVGNode? = n
        while let x = a { if x === tg { return }; a = x.parent }
        let tid = ObjectIdentifier(tg)
        if useStack.contains(tid) { return }
        useStack.append(tid)
        defer { useStack.removeLast() }
        let st = styles[ctx.styleIndex]
        let fs = st.fontSize
        var c = ctx
        c.doc = doc
        c.useDepth = ctx.useDepth + 1
        let x = len(n, "x", ctx, 0, 0, fontSize: fs), y = len(n, "y", ctx, 1, 0, fontSize: fs)
        c.t = ctx.t.concat(.translate(x, y))
        if tg.name == "symbol" || tg.name == "svg" {
            drawn += 1
            if drawn > limits.maxDrawn { return }
            let ts = doc.style(tg, parent: st)
            if ts.display == .none { return }
            styles.append(ts)
            defer { styles.removeLast() }
            c.styleIndex = styles.count - 1
            var w = len(n, "width", ctx, 0, -1, fontSize: fs), h = len(n, "height", ctx, 1, -1, fontSize: fs)
            if w < 0 { w = len(tg, "width", c, 0, ctx.vw, fontSize: fs) }
            if h < 0 { h = len(tg, "height", c, 1, ctx.vh, fontSize: fs) }
            let sx = tg.name == "svg" ? len(tg, "x", c, 0, 0, fontSize: fs) : 0
            let sy = tg.name == "svg" ? len(tg, "y", c, 1, 0, fontSize: fs) : 0
            viewport(tg, c, sx, sy, w, h, clip: true)
            return
        }
        renderNode(tg, c)
    }

    // MARK: Geometry

    func geometry(_ n: SVGNode, _ ctx: SVGCtx, _ st: CSSComputedStyle) -> SVGPath? {
        if let g = n.geometryCache { return g }
        let fs = st.fontSize
        var p = SVGPath()
        switch n.name {
        case "path":
            p = svgParsePath(n.attr("d") ?? "", maxSegments: limits.maxPathSegments)
            n.geometryCache = p
        case "polyline", "polygon":
            p = svgParsePoints(n.attr("points") ?? "", closed: n.name == "polygon")
            n.geometryCache = p
        case "rect":
            let x = len(n, "x", ctx, 0, 0, fontSize: fs), y = len(n, "y", ctx, 1, 0, fontSize: fs)
            let w = len(n, "width", ctx, 0, 0, fontSize: fs), h = len(n, "height", ctx, 1, 0, fontSize: fs)
            if !(w > 0) || !(h > 0) { return nil }
            var rx = len(n, "rx", ctx, 0, -1, fontSize: fs), ry = len(n, "ry", ctx, 1, -1, fontSize: fs)
            if rx < 0 && ry < 0 { rx = 0; ry = 0 } else if rx < 0 { rx = ry } else if ry < 0 { ry = rx }
            rx = min(rx, w / 2); ry = min(ry, h / 2)
            if rx > 0 && ry > 0 {
                let k = 0.5522847498
                p.move(x + rx, y)
                p.line(x + w - rx, y)
                p.cubic(x + w - rx + k * rx, y, x + w, y + ry - k * ry, x + w, y + ry)
                p.line(x + w, y + h - ry)
                p.cubic(x + w, y + h - ry + k * ry, x + w - rx + k * rx, y + h, x + w - rx, y + h)
                p.line(x + rx, y + h)
                p.cubic(x + rx - k * rx, y + h, x, y + h - ry + k * ry, x, y + h - ry)
                p.line(x, y + ry)
                p.cubic(x, y + ry - k * ry, x + rx - k * rx, y, x + rx, y)
                p.close()
            } else {
                p.move(x, y); p.line(x + w, y); p.line(x + w, y + h); p.line(x, y + h); p.close()
            }
        case "circle", "ellipse":
            let cx = len(n, "cx", ctx, 0, 0, fontSize: fs), cy = len(n, "cy", ctx, 1, 0, fontSize: fs)
            var rx: Double, ry: Double
            if n.name == "circle" {
                rx = len(n, "r", ctx, 2, 0, fontSize: fs); ry = rx
            } else {
                rx = len(n, "rx", ctx, 0, -1, fontSize: fs); ry = len(n, "ry", ctx, 1, -1, fontSize: fs)
                if rx < 0 { rx = ry }
                if ry < 0 { ry = rx }
            }
            if !(rx > 0) || !(ry > 0) { return nil }
            let k = 0.5522847498
            p.move(cx + rx, cy)
            p.cubic(cx + rx, cy + k * ry, cx + k * rx, cy + ry, cx, cy + ry)
            p.cubic(cx - k * rx, cy + ry, cx - rx, cy + k * ry, cx - rx, cy)
            p.cubic(cx - rx, cy - k * ry, cx - k * rx, cy - ry, cx, cy - ry)
            p.cubic(cx + k * rx, cy - ry, cx + rx, cy - k * ry, cx + rx, cy)
            p.close()
        case "line":
            p.move(len(n, "x1", ctx, 0, 0, fontSize: fs), len(n, "y1", ctx, 1, 0, fontSize: fs))
            p.line(len(n, "x2", ctx, 0, 0, fontSize: fs), len(n, "y2", ctx, 1, 0, fontSize: fs))
        default: return nil
        }
        return p.isEmpty ? nil : p
    }

    /// User-space bounding box of a path (for objectBoundingBox units).
    func bbox(_ p: SVGPath) -> (Double, Double, Double, Double)? {
        let f = p.flatten(.identity, tolerance: 0.25)
        guard let (x0, y0, x1, y1) = f.bounds else { return nil }
        return (Double(x0), Double(y0), Double(x1 - x0), Double(y1 - y0))
    }

    // MARK: Painting

    func paintShape(_ p: SVGPath, _ n: SVGNode, _ ctx: SVGCtx, _ st: CSSComputedStyle, _ fold: Double) {
        let s = st.svg
        var box: (Double, Double, Double, Double)? = nil
        func objBox() -> (Double, Double, Double, Double)? {
            if box == nil { box = bbox(p) }
            return box
        }
        if s.fill.kind != .none, let server = paintServer(s.fill, st, ctx, objBox) {
            let path = p.flatten(ctx.t)
            fillPath(path, s.fillRule == .evenodd ? .evenOdd : .nonZero, server, s.fillOpacity * fold, ctx)
        }
        if s.stroke.kind != .none {
            let w = s.strokeWidth.resolve(ctx.diag)
            if w > 0 && w.isFinite, let server = paintServer(s.stroke, st, ctx, objBox) {
                var flat = p.flatten(ctx.t, userSpace: true)
                if !s.strokeDasharray.isEmpty {
                    var dashes: [Float] = []
                    for d in s.strokeDasharray.prefix(1000) { dashes.append(rasterSanD(d.resolve(ctx.diag))) }
                    flat = rasterDash(flat, dashes, offset: rasterSanD(s.strokeDashoffset.resolve(ctx.diag)))
                }
                var rs = RasterStrokeStyle()
                rs.width = rasterSanD(w)
                rs.cap = s.strokeLinecap == .round ? .round : (s.strokeLinecap == .square ? .square : .butt)
                rs.join = s.strokeLinejoin == .round ? .round : (s.strokeLinejoin == .bevel ? .bevel : .miter)
                rs.miterLimit = rasterSanD(s.strokeMiterlimit)
                rs.tolerance = Float(0.1 / max(1e-6, min(1e6, ctx.t.maxScale)))
                var outline = rasterStroke(flat, rs)
                outline.transform(ctx.t)
                fillPath(outline, .nonZero, server, s.strokeOpacity * fold, ctx)
            }
        }
    }

    func fillPath(_ path: RasterPath, _ rule: RasterFillRule, _ server: SVGPaintServer, _ opacity: Double, _ ctx: SVGCtx) {
        let li = layers.count - 1
        let lay = RasterRect(x0: layers[li].ox, y0: layers[li].oy, x1: layers[li].ox + layers[li].w, y1: layers[li].oy + layers[li].h)
        let clip = ctx.clip.intersection(lay)
        if clip.isEmpty { return }
        let k = UInt32(max(0, min(256, Int(opacity * 256 + 0.5))))
        if k == 0 { return }
        let ox = layers[li].ox, oy = layers[li].oy, lw = layers[li].w
        let mask = ctx.mask
        layers[li].px.withUnsafeMutableBufferPointer { d in
            _ = rasterFill(path, rule: rule, clip: clip) { y, x, cov in
                let row = (y - oy) * lw - ox
                switch server {
                case .solid(let c):
                    let src = svgScale(c, k)
                    for i in 0..<cov.count {
                        var a = UInt32(cov[i])
                        if a == 0 { continue }
                        if let m = mask { a = a * UInt32(m.at(x + i, y)) / 255; if a == 0 { continue } }
                        let s = a == 255 ? src : svgScale(src, a + (a >> 7))
                        d[row + x + i] = svgOver(s, d[row + x + i])
                    }
                case .gradient(let g):
                    let py = Double(y) + 0.5
                    var gx = g.inv.a * (Double(x) + 0.5) + g.inv.c * py + g.inv.e
                    var gy = g.inv.b * (Double(x) + 0.5) + g.inv.d * py + g.inv.f
                    for i in 0..<cov.count {
                        defer { gx += g.inv.a; gy += g.inv.b }
                        var a = UInt32(cov[i])
                        if a == 0 { continue }
                        if let m = mask { a = a * UInt32(m.at(x + i, y)) / 255; if a == 0 { continue } }
                        guard let c = svgGradientColor(g, gx, gy) else { continue }
                        let s = svgScale(svgScale(c, k), a + (a >> 7))
                        d[row + x + i] = svgOver(s, d[row + x + i])
                    }
                }
            }
        }
    }

    // MARK: Paint servers

    func paintServer(_ p: CSSPaint, _ st: CSSComputedStyle, _ ctx: SVGCtx,
                     _ objBox: () -> (Double, Double, Double, Double)?) -> SVGPaintServer? {
        switch p.kind {
        case .none: return nil
        case .color: return .solid(svgPremul(p.color, 1))
        case .currentColor: return .solid(svgPremul(st.color, 1))
        case .url:
            if let g = gradient(p.url, st, ctx, objBox) { return g }
            switch p.fallback {
            case .color: return .solid(svgPremul(p.fallbackColor, 1))
            case .currentColor: return .solid(svgPremul(st.color, 1))
            default: return nil
            }
        }
    }

    /// The element a url() / href refers to in `doc` (same-document only).
    func lookup(_ url: String, _ doc: SVGDocument) -> SVGNode? {
        guard let h = url.utf8.lastIndex(of: 0x23) else { return nil }
        let id = String(decoding: url.utf8[url.utf8.index(after: h)...], as: UTF8.self)
        return doc.element(id: id)
    }

    func gradient(_ url: String, _ st: CSSComputedStyle, _ ctx: SVGCtx,
                  _ objBox: () -> (Double, Double, Double, Double)?) -> SVGPaintServer? {
        guard let g0 = lookup(url, ctx.doc), g0.name == "linearGradient" || g0.name == "radialGradient" else { return nil }
        // The href chain, nearest first.
        var chain: [SVGNode] = [g0]
        var cur = g0
        while chain.count < 16, let h = cur.href, let next = lookup(h, ctx.doc),
              next.name == "linearGradient" || next.name == "radialGradient", !chain.contains(where: { $0 === next }) {
            chain.append(next); cur = next
        }
        func attr(_ a: String) -> String? {
            for n in chain { if let v = n.attr(a) { return v } }
            return nil
        }
        let radial = g0.name == "radialGradient"
        let obb = attr("gradientUnits") != "userSpaceOnUse"
        var m = ctx.t
        if obb {
            guard let (bx, by, bw, bh) = objBox(), bw > 0, bh > 0 else { return nil }
            m = m.concat(RasterTransform(bw, 0, 0, bh, bx, by))
        }
        if let gt = attr("gradientTransform"), let tm = svgParseTransform(gt) { m = m.concat(tm) }
        guard let inv = m.inverted(), inv.isFinite else { return nil }
        // Coordinates: fractions in bounding-box units, lengths otherwise.
        func coord(_ a: String, _ axis: Int, _ def: String) -> Double {
            let s = attr(a) ?? def
            guard let l = svgParseLength(s) else { return 0 }
            if obb { return l.unit == .percent ? l.value / 100 : l.value }
            let base = axis == 0 ? ctx.vw : (axis == 1 ? ctx.vh : ctx.diag)
            return l.resolve(fontSize: st.fontSize, percentBase: base)
        }
        // Stops from the first gradient in the chain that has any.
        var stopsNode = g0
        for n in chain where n.children.contains(where: { $0.name == "stop" }) { stopsNode = n; break }
        let gst = ctx.doc.style(g0, parent: st)
        var offs: [Double] = [], cols: [CSSColor] = [], alphas: [Double] = []
        for s in stopsNode.children where s.name == "stop" {
            if offs.count >= limits.maxStops { break }
            let ss = ctx.doc.style(s, parent: gst)
            var o = 0.0
            if let v = s.attr("offset") {
                let t = svgParseLength(v)
                if let t = t { o = t.unit == .percent ? t.value / 100 : t.value }
            }
            o = max(0, min(1, o))
            if let last = offs.last { o = max(o, last) }
            offs.append(o); cols.append(ss.svg.stopColor); alphas.append(ss.svg.stopOpacity)
        }
        if offs.isEmpty { return nil }
        if offs.count == 1 { return .solid(svgPremul(cols[0], alphas[0])) }
        var lut = [UInt32](repeating: 0, count: 256)
        var seg = 0
        let last = offs.count - 1
        for i in 0..<256 {
            let t = Double(i) / 255
            var a = 0, b = 0
            var f = 0.0
            if t <= offs[0] { a = 0; b = 0 }
            else if t >= offs[last] { a = last; b = last }
            else {
                while seg + 1 < last && t > offs[seg + 1] { seg += 1 }
                a = seg; b = seg + 1
                let span = offs[b] - offs[a]
                f = span > 0 ? max(0, min(1, (t - offs[a]) / span)) : 1
            }
            let ca = cols[a], cb = cols[b]
            func mix(_ x: UInt8, _ y: UInt8) -> UInt8 {
                UInt8(max(0, min(255, Double(x) + (Double(y) - Double(x)) * f + 0.5)))
            }
            let aa = Double(ca.a) / 255 * alphas[a], ab = Double(cb.a) / 255 * alphas[b]
            let c = CSSColor(r: mix(ca.r, cb.r), g: mix(ca.g, cb.g), b: mix(ca.b, cb.b), a: 255)
            lut[i] = svgPremul(c, max(0, min(1, aa + (ab - aa) * f)))
        }
        var g = SVGGradient(radial: radial, inv: inv, lut: lut)
        switch attr("spreadMethod") {
        case "reflect": g.spread = 1
        case "repeat": g.spread = 2
        default: g.spread = 0
        }
        if radial {
            g.cx = coord("cx", 0, "50%"); g.cy = coord("cy", 1, "50%"); g.r = coord("r", 2, "50%")
            g.fx = attr("fx") != nil ? coord("fx", 0, "50%") : g.cx
            g.fy = attr("fy") != nil ? coord("fy", 1, "50%") : g.cy
            g.fr = attr("fr") != nil ? coord("fr", 2, "0%") : 0
            if !(g.r > 0) { return .solid(lut[255]) }
            // A focal point outside the end circle moves onto it (SVG 1.1).
            let dx = g.fx - g.cx, dy = g.fy - g.cy
            let dist = (dx * dx + dy * dy).squareRoot()
            if dist > g.r * 0.999 {
                let k = g.r * 0.999 / dist
                g.fx = g.cx + dx * k; g.fy = g.cy + dy * k
            }
            g.fr = max(0, min(g.fr, g.r))
        } else {
            g.x1 = coord("x1", 0, "0%"); g.y1 = coord("y1", 1, "0%")
            g.x2 = coord("x2", 0, "100%"); g.y2 = coord("y2", 1, "0%")
            if g.x1 == g.x2 && g.y1 == g.y2 { return .solid(lut[255]) }
        }
        return .gradient(g)
    }

    // MARK: Clipping

    func clipMask(_ url: String, _ n: SVGNode, _ ctx: SVGCtx) -> RasterMask? {
        guard let cp = lookup(url, ctx.doc), cp.name == "clipPath" else { return nil }
        var m = RasterMask(x: ctx.clip.x0, y: ctx.clip.y0, width: ctx.clip.x1 - ctx.clip.x0, height: ctx.clip.y1 - ctx.clip.y0)
        if m.width <= 0 || m.height <= 0 { return m }
        let st = styles[ctx.styleIndex]
        let cst = ctx.doc.style(cp, parent: st)
        var t = ctx.t
        if let tr = cp.attr("transform"), let tm = svgParseTransform(tr) { t = t.concat(tm) }
        if cp.attr("clipPathUnits") == "objectBoundingBox" {
            guard let (bx, by, bw, bh) = elementBox(n, ctx, 0) else { return m }
            t = t.concat(RasterTransform(bw, 0, 0, bh, bx, by))
        }
        var c = ctx
        c.t = t
        for ch in cp.children {
            drawn += 1
            if drawn > limits.maxDrawn { break }
            var shape = ch
            var ct = t
            if ch.name == "use", let h = ch.href, let tg = lookup(h, ctx.doc), tg.name != "use", tg !== cp {
                let fs = cst.fontSize
                ct = ct.concat(.translate(len(ch, "x", ctx, 0, 0, fontSize: fs), len(ch, "y", ctx, 1, 0, fontSize: fs)))
                shape = tg
            }
            let ss = ctx.doc.style(shape, parent: cst)
            if ss.display == .none || ss.visibility != .visible { continue }
            if let tr = ch.attr("transform"), let tm = svgParseTransform(tr) { ct = ct.concat(tm) }
            if shape !== ch, let tr = shape.attr("transform"), let tm = svgParseTransform(tr) { ct = ct.concat(tm) }
            c.t = ct
            guard let p = geometry(shape, c, ss) else { continue }
            rasterFillMask(p.flatten(ct), rule: ss.svg.clipRule == .evenodd ? .evenOdd : .nonZero, into: &m)
        }
        if let prev = ctx.mask {
            for y in 0..<m.height {
                for x in 0..<m.width {
                    let k = y * m.width + x
                    m.data[k] = UInt8(UInt32(m.data[k]) * UInt32(prev.at(m.x + x, m.y + y)) / 255)
                }
            }
        }
        return m
    }

    /// User-space bounding box of an element (shapes; groups as the union of
    /// their children, through child transforms).
    func elementBox(_ n: SVGNode, _ ctx: SVGCtx, _ depth: Int) -> (Double, Double, Double, Double)? {
        if depth > 8 { return nil }
        let st = styles[ctx.styleIndex]
        if let p = geometry(n, ctx, st) { return bbox(p) }
        var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity
        for ch in n.children.prefix(1000) {
            guard let (bx, by, bw, bh) = elementBox(ch, ctx, depth + 1) else { continue }
            var m = RasterTransform.identity
            if let tr = ch.attr("transform"), let tm = svgParseTransform(tr) { m = tm }
            for (px, py) in [(bx, by), (bx + bw, by), (bx, by + bh), (bx + bw, by + bh)] {
                let (qx, qy) = m.apply(px, py)
                x0 = min(x0, qx); y0 = min(y0, qy); x1 = max(x1, qx); y1 = max(y1, qy)
            }
        }
        if !x0.isFinite || !x1.isFinite { return nil }
        return (x0, y0, x1 - x0, y1 - y0)
    }
}

// MARK: - Pixels

@inline(__always) func svgPremul(_ c: CSSColor, _ opacity: Double) -> UInt32 {
    let a = UInt32(max(0, min(255, Int(Double(c.a) * max(0, min(1, opacity)) + 0.5))))
    let r = (UInt32(c.r) * a + 127) / 255, g = (UInt32(c.g) * a + 127) / 255, b = (UInt32(c.b) * a + 127) / 255
    return a << 24 | r << 16 | g << 8 | b
}

/// Scale every channel of a premultiplied pixel by k / 256 (k <= 256).
@inline(__always) func svgScale(_ p: UInt32, _ k: UInt32) -> UInt32 {
    if k >= 256 { return p }
    let rb = (((p & 0x00ff_00ff) &* k) >> 8) & 0x00ff_00ff
    let ag = (((p >> 8) & 0x00ff_00ff) &* k) & 0xff00_ff00
    return rb | ag
}

/// Source over destination, both premultiplied.
@inline(__always) func svgOver(_ s: UInt32, _ d: UInt32) -> UInt32 {
    let sa = s >> 24
    if sa == 255 { return s }
    if sa == 0 && s == 0 { return d }
    let inv = 256 - (sa + (sa >> 7))
    let rb = (((d & 0x00ff_00ff) &* inv) >> 8) & 0x00ff_00ff
    let ag = ((((d >> 8) & 0x00ff_00ff) &* inv)) & 0xff00_ff00
    let o = rb | ag
    // Channel-wise add (no overflow: premultiplied sums stay <= 255).
    let r = min(255, (s >> 16 & 255) + (o >> 16 & 255))
    let g = min(255, (s >> 8 & 255) + (o >> 8 & 255))
    let b = min(255, (s & 255) + (o & 255))
    let a = min(255, sa + (o >> 24))
    return a << 24 | r << 16 | g << 8 | b
}

private func svgGradientColor(_ g: SVGGradient, _ x: Double, _ y: Double) -> UInt32? {
    var t: Double
    if g.radial {
        let cdx = g.cx - g.fx, cdy = g.cy - g.fy, dr = g.r - g.fr
        let pdx = x - g.fx, pdy = y - g.fy
        let a = cdx * cdx + cdy * cdy - dr * dr
        let b = pdx * cdx + pdy * cdy + g.fr * dr
        let c = pdx * pdx + pdy * pdy - g.fr * g.fr
        if abs(a) < 1e-12 {
            if abs(b) < 1e-12 { return nil }
            t = c / (2 * b)
        } else {
            let disc = b * b - a * c
            if disc < 0 { return nil }
            let sq = disc.squareRoot()
            t = (b + sq) / a
            if g.fr + t * dr < 0 { t = (b - sq) / a }
            if g.fr + t * dr < 0 { return nil }
        }
    } else {
        let dx = g.x2 - g.x1, dy = g.y2 - g.y1
        t = ((x - g.x1) * dx + (y - g.y1) * dy) / (dx * dx + dy * dy)
    }
    if !t.isFinite { return nil }
    switch g.spread {
    case 1:
        t = abs(t)
        t = t - 2 * (t / 2).rounded(.down)
        if t > 1 { t = 2 - t }
    case 2:
        t = t - t.rounded(.down)
    default:
        t = max(0, min(1, t))
    }
    return g.lut[max(0, min(255, Int(t * 255 + 0.5)))]
}
