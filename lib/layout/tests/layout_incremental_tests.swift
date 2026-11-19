// Incremental restyle/relayout: random DOM mutations must give exactly what a
// from-scratch engine gives on the same document (box dump, document size,
// pixels, layout-affecting style), plus API checks and timings.

private let incClassPool = ["hl", "pad", "hide", "blk", "fl", "big", "sib", "a", "pb", "abs", "rel", "inl", "fx", "ib", "tbl", "it", "under", "x"]
private let incExtraCSS = """
.hl { color: #c00; background: #ff0 }
.pad { padding: 8px }
.hide { display: none }
.blk { display: block }
.fl { float: left }
.big { font-size: 24px }
.sib + p { margin-top: 20px }
.a ~ div { color: #00c }
.a + .a { border: 1px solid #080 }
li:nth-child(2n) { background: #eee }
p::before { content: "> " }
.pb::before { content: "x" }
.abs { position: absolute; top: 5px; left: 5px }
.rel { position: relative; left: 3px }
.inl { display: inline }
.fx { display: flex }
.ib { display: inline-block }
.tbl { display: table }
.it { font-style: italic }
.under { text-decoration: underline }
.hl span, .hl b { color: #0a0 }
div:empty { height: 10px; background: #ccc }
"""
private let incStyles = ["", "display:none", "float:right", "color:green", "margin:0 20px", "padding:4px", "width:50%", "position:relative;top:4px", "font-size:18px", "visibility:hidden"]
private let incSnippets = ["<p class=hl>new text</p>", "<div><span>a</span> b</div>", "<ul><li>1<li>2</ul>", "<img src=a.png>", "<b>x</b>",
                           "<div class=a>q</div><div class=a>r</div>", "<table><tr><td>c1<td>c2</table>", "<style>.hl { color: blue }</style>",
                           "<span class=pad>s</span>", "<div></div>"]

private func incFragment(_ s: String) -> HTMLNode? {
    let d = htmlParse("<i></i>" + s)
    guard let b = d.body, b.children.count > 1 else { return nil }
    let n = b.children[1]
    _ = try? b.removeChild(n)
    return n
}

private func incAllNodes(_ doc: HTMLNode) -> [HTMLNode] {
    var out: [HTMLNode] = []
    doc.walk { n in if n.kind == .element || n.kind == .text { out.append(n) }; return true }
    return out
}

private func incIsWithin(_ n: HTMLNode, _ anc: HTMLNode) -> Bool {
    var p: HTMLNode? = n
    while let q = p { if q === anc { return true }; p = q.parent }
    return false
}

private func incSetAttr(_ n: HTMLNode, _ name: String, _ value: String?) {
    if let v = value { try? n.setAttribute(name, v) } else { _ = n.removeAttribute(name) }
}

/// Apply one random mutation, reporting it to the engine. Returns a description.
@discardableResult
private func incMutate(_ e: LayoutEngine, _ doc: HTMLNode, _ rng: inout TestRandom) -> String {
    let nodes = incAllNodes(doc)
    guard nodes.count > 4 else { return "none" }
    let n = nodes[rng.below(nodes.count)]
    let structural = n.kind == .element && n.name != "html" && n.name != "head" && n.name != "body"
        || n.kind == .text
    switch rng.below(10) {
    case 0, 1, 2:
        guard n.kind == .element else { return "skip" }
        let c = incClassPool[rng.below(incClassPool.count)]
        var names = n.classNames
        if let i = names.firstIndex(of: c) { names.remove(at: i) } else { names.append(c) }
        incSetAttr(n, "class", names.isEmpty ? nil : names.joined(separator: " "))
        return "class \(c) on <\(n.name) \(n.attribute("id") ?? "")> parent <\(n.parent?.name ?? "")>"
    case 3:
        guard n.kind == .element else { return "skip" }
        let s = incStyles[rng.below(incStyles.count)]
        incSetAttr(n, "style", s.isEmpty ? nil : s)
        return "style \(s)"
    case 4:
        guard n.kind == .element else { return "skip" }
        let opts: [(String, String?)] = [("align", "center"), ("align", nil), ("hidden", ""), ("hidden", nil), ("width", "50"), ("id", "zz"),
                                          ("colspan", "2"), ("bgcolor", "#ffcc00"), ("data-x", "1"), ("src", "b.png")]
        let (a, v) = opts[rng.below(opts.count)]
        incSetAttr(n, a, v)
        return "attr \(a)"
    case 5, 6:
        guard n.kind == .element, let f = incFragment(incSnippets[rng.below(incSnippets.count)]) else { return "skip" }
        let ri = rng.below(n.children.count + 1)
        let ref: HTMLNode? = ri < n.children.count ? n.children[ri] : nil
        _ = try? n.insertBefore(f, ref)
        return "insert \(f.name) into \(n.name)"
    case 7:
        guard structural, let p = n.parent else { return "skip" }
        _ = try? p.removeChild(n)
        return "remove \(n.name) from \(p.name)"
    case 8:
        guard n.kind == .text else { return "skip" }
        n.setData("changed text \(rng.below(100)) and more words to wrap around the line")
        return "text"
    default:
        // Move a node somewhere else.
        guard structural, let p = n.parent else { return "skip" }
        let dst = nodes[rng.below(nodes.count)]
        guard dst.kind == .element, !incIsWithin(dst, n) else { return "skip" }
        _ = try? p.removeChild(n)
        _ = try? dst.insertBefore(n, nil)
        return "move \(n.name) -> \(dst.name)"
    }
}

private func incMakeEngine(_ t: Tests, _ doc: HTMLNode, _ sheet: CSSStylesheet?) -> LayoutEngine {
    let e = LayoutEngine(document: doc, text: layoutFonts(t), viewportWidth: 400, viewportHeight: 300)
    e.imageSize = { u in layoutFixtureImages[u] }
    if let s = sheet { for (i, src) in e.styleSources.enumerated() where src.href != nil { e.setStyleSheets(slot: i, [s]) } }
    e.addStyleSheet(cssParseStylesheet(incExtraCSS))
    return e
}

private func incPaint(_ e: LayoutEngine) -> [UInt32] {
    var buf = [UInt32](repeating: 0, count: 400 * 300)
    buf.withUnsafeMutableBufferPointer { p in
        e.paint(into: p.baseAddress!, stride: 400, width: 400, height: 300, scrollX: 0, scrollY: 0)
    }
    return buf
}

/// Empty string if the engines agree, else what differs.
private func incCompare(_ inc: LayoutEngine, _ fresh: LayoutEngine) -> String {
    let a = inc.dump(), b = fresh.dump()
    if a != b {
        let la = a.split(separator: "\n", omittingEmptySubsequences: false), lb = b.split(separator: "\n", omittingEmptySubsequences: false)
        var i = 0
        while i < la.count && i < lb.count && la[i] == lb[i] { i += 1 }
        if hostEnvDebug {
            var shown = 0, j = i
            while j < la.count && j < lb.count && shown < 6 {
                if la[j] != lb[j] { print("DIFF \(j + 1): inc \(la[j])\nDIFF \(j + 1): new \(lb[j])"); shown += 1 }
                j += 1
            }
        }
        return "dump line \(i + 1): inc \"\(i < la.count ? String(la[i]) : "<end>")\" vs fresh \"\(i < lb.count ? String(lb[i]) : "<end>")\""
    }
    if inc.documentHeight != fresh.documentHeight || inc.documentWidth != fresh.documentWidth { return "document size" }
    // Computed styles of every element.
    var bad = ""
    inc.document.walk { n in
        guard n.kind == .element, bad.isEmpty else { return bad.isEmpty }
        let x = inc.box(for: n), y = fresh.box(for: n)
        if (x == nil) != (y == nil) { bad = "box presence of <\(n.name)>"; return false }
        if let x = x, let y = y {
            if layoutStyleAffectsLayout(x.style, y.style) { bad = "layout style of <\(n.name)>"; return false }
            if x.style.color != y.style.color || x.style.backgroundColor != y.style.backgroundColor
                || x.style.opacity != y.style.opacity || x.style.visibility != y.style.visibility
                || x.style.textDecoration != y.style.textDecoration { bad = "paint style of <\(n.name)>"; return false }
        }
        return true
    }
    if !bad.isEmpty { return bad }
    if let ra = inc.root, let rb = fresh.root {
        var st: [(LayoutBox, LayoutBox)] = [(ra, rb)]
        while let (x, y) = st.popLast() {
            let nm = x.node.map { $0.kind == .element ? "<" + $0.name + ">" : "#text" } ?? "anon"
            if x.children.count != y.children.count { return "child count of \(nm)" }
            if x.deco != y.deco || x.decoColor != y.decoColor { return "deco of \(nm) \(x.deco) vs \(y.deco)" }
            if x.paintsBackground != y.paintsBackground || x.opacityAcc != y.opacityAcc || x.inFixed != y.inFixed { return "paint flags of \(nm)" }
            if x.style.color != y.style.color || x.style.backgroundColor != y.style.backgroundColor
                || x.style.opacity != y.style.opacity || x.style.visibility != y.style.visibility
                || x.style.textDecoration != y.style.textDecoration || x.style.zIndex != y.style.zIndex { return "box style of \(nm) (\(x.kind), \(x.anonymous))" }
            for i in 0..<x.children.count { st.append((x.children[i], y.children[i])) }
        }
    }
    let pa = incPaint(inc), pb = incPaint(fresh)
    if pa != pb {
        var i = 0
        while pa[i] == pb[i] { i += 1 }
        return "pixels at \(i % 400),\(i / 400): \(pa[i]) vs \(pb[i])"
    }
    if inc.formControls.count != fresh.formControls.count { return "control count" }
    return ""
}

private let hostEnvDebug = getenv("WIFFER_INC_DEBUG") != nil

private func incFuzzPage(_ t: Tests, _ name: String, _ html: [UInt8], _ sheet: CSSStylesheet?, seed: UInt64, rounds: Int) -> (Int, Int, LayoutUpdateStats) {
    let doc = htmlParse(html)
    let inc = incMakeEngine(t, doc, sheet)
    inc.update()
    var rng = TestRandom(seed: seed)
    var failures = 0, checks = 0
    var log: [String] = []
    for r in 0..<rounds {
        let k = 1 + rng.below(3)
        let st0 = inc.stats
        for _ in 0..<k { log.append(incMutate(inc, doc, &rng)) }
        // Sometimes force the update through a layout query.
        if rng.below(4) == 0, let b = doc.body { _ = inc.rect(of: b) } else { inc.updateIfNeeded() }
        let fresh = incMakeEngine(t, doc, sheet)
        fresh.update()
        let d = incCompare(inc, fresh)
        checks += 1
        if !d.isEmpty {
            failures += 1
            if hostEnvDebug, let b = doc.body, let bb = inc.box(for: b) {
                print("BODY \(name) inc margin \(bb.margin.t) display \(bb.style.display) mt \(bb.style.marginTop.lp.px) \(bb.style.marginTop.kind) parent \(bb.parent?.node?.name ?? "nil") attrs " + b.attributes.map { $0.name + "=" + $0.value }.joined(separator: ",") + " fresh/inc class " + (b.attribute("class") ?? "-") + " styleattr " + (b.attribute("style") ?? "-"))
            }
            if hostEnvDebug {
                print("SRC inc \(inc.styleSources.count) fresh \(fresh.styleSources.count) " + inc.styleSources.map { String($0.text.prefix(20)) }.joined(separator: "|") + " // " + fresh.styleSources.map { String($0.text.prefix(20)) }.joined(separator: "|"))
            }
            if hostEnvDebug { print("STATS paint \(inc.stats.paintOnly - st0.paintOnly) sub \(inc.stats.subtreeRebuilds - st0.subtreeRebuilds) full \(inc.stats.fullRebuilds - st0.fullRebuilds)") }
            if hostEnvDebug { print("LOG \(name): " + log.joined(separator: " | ")) }
            t.check(false, "\(name) round \(r)", d + " after " + log.suffix(k + 1).joined(separator: "; "))
            if failures >= 3 { break }
            // Resynchronise: continue from scratch state.
            inc.invalidateStyle(); inc.update()
        }
    }
    return (checks, failures, inc.stats)
}

func layoutIncrementalTests(_ t: Tests) {
    t.section("incremental")

    // API behavior on a small page.
    do {
        let e = layoutPage(t, """
        <style>.hl{color:red}.wide{width:300px}</style>
        <div id=a class=wide>one</div><div id=b>two</div><div id=c><p>para</p></div>
        """)
        let a = e.document.getElementById("a")!
        let before = e.stats
        let h0 = e.documentHeight
        incSetAttr(a, "class", "wide hl")
        t.check(e.hasPendingWork, "pending after note")
        e.updateIfNeeded()
        t.check(!e.hasPendingWork, "clean after update")
        t.equal(e.stats.paintOnly, before.paintOnly + 1, "class toggle is paint-only")
        t.equal(e.stats.fullRebuilds, before.fullRebuilds, "no full rebuild")
        t.equal(e.computedStyle(of: a)?.color.r ?? 0, 255, "computed color after class")
        t.equal(Int(e.documentHeight), Int(h0), "height unchanged")

        // Forced layout.
        let c = e.document.getElementById("c")!
        let q0 = e.stats.forcedQueries, f0 = e.stats.forcedFlushes
        let hBefore = e.rect(of: c)?.h ?? 0
        incSetAttr(a, "style", "height:200px")
        let y1 = e.rect(of: c)?.y ?? 0
        t.check(y1 > (e.rect(of: a)?.y ?? 0) + 190, "rect flushes pending style and layout", "\(y1)")
        t.equal(e.stats.forcedQueries - q0, 3, "queries counted")
        t.equal(e.stats.forcedFlushes - f0, 1, "one flush")
        _ = e.rect(of: c)
        t.equal(e.stats.forcedFlushes - f0, 1, "second query does not flush")
        t.check(hBefore > 0, "rect works")
        if let m = e.metrics(of: a) { t.equal(Int(m.offsetHeight), 200, "offsetHeight"); t.equal(Int(m.clientWidth), 300, "clientWidth") } else { t.check(false, "metrics") }
        t.check(e.metrics(of: e.document.getElementById("b")!)?.scrollHeight ?? 0 > 0, "scrollHeight")

        // Insert and remove a block.
        let n = incFragment("<div id=n>new</div>")!
        _ = try? c.insertBefore(n, c.children.first)
        t.check(e.rect(of: n) != nil, "inserted element has a box after flush")
        let sub = e.stats.subtreeRebuilds
        t.check(sub > 0, "child insertion rebuilt a subtree, not the document")
        _ = try? c.removeChild(n)
        e.updateIfNeeded()
        t.check(e.box(for: n) == nil, "removed element lost its box")
        // display:none appears and disappears.
        incSetAttr(a, "style", "display:none")
        t.check(e.rect(of: a) == nil, "display none removes the box")
        incSetAttr(a, "style", nil)
        t.check(e.rect(of: a) != nil, "display none removed brings it back")
        // New <style> element.
        let st = incFragment("<style>#b { color: #f00 }</style>")!
        _ = try? e.document.body!.appendChild(st)
        e.document.body!.assignIndices()
        t.equal(e.computedStyle(of: e.document.getElementById("b")!)?.color.r ?? 0, 255, "inserted <style> applies")
        t.check(e.styleSourcesVersion > 0, "sources rescanned")
    }

    // Wired to lib/html's mutation records: public DOM API calls restyle with no manual notes.
    do {
        let e = layoutPage(t, """
        <style>.hl{color:red}.big{font-size:30px}#t{width:200px}</style>
        <div id=a>one</div><div id=b>two</div><ul id=u><li>x</li></ul>
        """)
        let a = e.document.getElementById("a")!, u = e.document.getElementById("u")!
        let before = e.stats
        try? a.setAttribute("class", "hl")
        t.check(e.hasPendingWork, "mutation observer queued a change")
        t.equal(e.computedStyle(of: a)?.color.r ?? 0, 255, "setAttribute restyles via observer")
        t.equal(e.stats.paintOnly, before.paintOnly + 1, "observer class change is paint-only")
        let h0 = e.rect(of: e.document.getElementById("b")!)?.y ?? 0
        try? a.setAttribute("class", "big")
        let h1 = e.rect(of: e.document.getElementById("b")!)?.y ?? 0
        t.check(h1 > h0, "font-size change moves the next block", "\(h0) -> \(h1)")
        e.document.body!.setInnerHTML("<div id=t>fresh <b>text</b></div>")
        t.check(e.rect(of: e.document.getElementById("t")!) != nil, "setInnerHTML shows new content")
        t.check(e.box(for: u) == nil, "old content gone")
        let tn = e.document.getElementById("t")!.firstChild!
        let w0 = e.rect(of: tn.parent!)?.h ?? 0
        tn.setData("a much longer run of text that will certainly wrap around several lines in a two hundred pixel box")
        t.check((e.rect(of: tn.parent!)?.h ?? 0) > w0, "setData relayouts")
        let fresh = LayoutEngine(document: e.document, text: layoutFonts(t), viewportWidth: 400, viewportHeight: 300)
        fresh.update()
        t.check(e.dump() == fresh.dump(), "observer-driven result equals from scratch")
    }

    // Fuzz: incremental result == from-scratch result.
    var pages: [(String, [UInt8], CSSStylesheet?)] = []
    for n in layoutFixtureNames where n != "hn" {
        if let b = t.readFileIfPresent("lib/layout/fixtures/\(n).html") { pages.append((n, b, nil)) }
    }
    if let h = t.readFileIfPresent("lib/layout/fixtures/hn.html"), let c = t.readFileIfPresent("lib/layout/fixtures/hn.css") {
        pages.append(("hn", Array(h.prefix(12000)), cssParseStylesheet(c)))
    }
    pages.append(("synthetic", Array("""
    <body><div class=a>1</div><div class=a>2</div><p>p1</p><ul><li>a<li>b<li>c<li>d</ul>
    <div><span>inline</span> text <b>bold</b><div>nested block</div> after</div>
    <table><tr><td>x<td><div>cell block</div></table><center><div>c</div></center>
    <div style="float:left">f</div><p>after float <a href=x>link</a></p><div></div><section><p>s</p><p>t</p></section>
    """.utf8), nil))
    var totalChecks = 0, totalFail = 0
    var agg = LayoutUpdateStats()
    var seed: UInt64 = UInt64(getenv("WIFFER_INC_SEED").flatMap { Int(String(cString: $0)) } ?? 1)
    let mult = getenv("WIFFER_INC_ROUNDS").flatMap { Int(String(cString: $0)) } ?? 1
    for (name, html, sheet) in pages {
        let (c, f, s) = incFuzzPage(t, name, html, sheet, seed: seed, rounds: (name == "hn" ? 25 : 40) * mult)
        totalChecks += c; totalFail += f
        agg.paintOnly += s.paintOnly; agg.subtreeRebuilds += s.subtreeRebuilds; agg.fullRebuilds += s.fullRebuilds
        seed &+= 7919
    }
    t.check(totalFail == 0, "incremental == from scratch (\(totalChecks) checks)", "\(totalFail) failures")
    print("  incremental fuzz: \(totalChecks) checks, \(agg.paintOnly) paint-only, \(agg.subtreeRebuilds) subtree rebuilds, \(agg.fullRebuilds) full rebuilds")
    t.check(agg.paintOnly > 0 && agg.subtreeRebuilds > 0, "fuzz exercised both incremental paths")

    // Timing on the Wikipedia page.
    if let (e, _, _, _) = layoutSitePage(t, "lib/html/fixtures/wikipedia-html.html", "lib/layout/fixtures/wikipedia.css", width: 1024) {
        e.addStyleSheet(cssParseStylesheet(".hl { color: #c00; background: #ffd } .big { font-size: 20px; padding: 4px }"))
        e.update()
        let ps = e.document.getElementsByTagName("p")
        let target = ps.count > 40 ? ps[40] : (ps.first ?? e.document)
        let li = e.document.getElementsByTagName("li")
        let target2 = li.count > 100 ? li[100] : target
        func toggle(_ n: HTMLNode, _ c: String, _ on: Bool) {
            incSetAttr(n, "class", on ? c : nil)
        }
        let N = 20
        var t0 = hostMillis()
        for i in 0..<N { toggle(target, "hl", i % 2 == 0); e.updateIfNeeded() }
        let paintMs = Double(hostMillis() - t0) / Double(N)
        t0 = hostMillis()
        for i in 0..<N { toggle(target2, "big", i % 2 == 0); e.updateIfNeeded() }
        let layoutMs = Double(hostMillis() - t0) / Double(N)
        t0 = hostMillis()
        for _ in 0..<3 { e.invalidateStyle(); e.update() }
        let fullMs = Double(hostMillis() - t0) / 3.0
        print("  Wikipedia class toggle: paint-only \(paintMs) ms, layout-affecting \(layoutMs) ms, full restyle+layout \(fullMs) ms (\(e.stats.paintOnly) paint-only, \(e.stats.subtreeRebuilds) subtree rebuilds)")
        t.check(paintMs < 50 && layoutMs < 50, "class toggle under 50 ms")
        // Same answer as from scratch.
        toggle(target2, "big", true)
        e.updateIfNeeded()
        let fresh = LayoutEngine(document: e.document, text: layoutFonts(t), viewportWidth: 1024, viewportHeight: 768)
        if let sheetText = t.readFileIfPresent("lib/layout/fixtures/wikipedia.css") {
            let sh = cssParseStylesheet(sheetText)
            for (i, s) in fresh.styleSources.enumerated() where s.href != nil { fresh.setStyleSheets(slot: i, [sh]); break }
        }
        fresh.addStyleSheet(cssParseStylesheet(".hl { color: #c00; background: #ffd } .big { font-size: 20px; padding: 4px }"))
        fresh.update()
        t.check(e.dump() == fresh.dump(), "Wikipedia incremental dump equals from scratch")
    }
}
