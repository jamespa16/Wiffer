// Paint, hit-test, API, robustness, fuzz and site tests for lib/layout
// (helpers live in layout_tests.swift).

func layoutRender(_ e: LayoutEngine, _ w: Int, _ h: Int, scrollY: Double = 0,
                  images: ((String) -> ImageBitmap?)? = nil,
                  control: ((LayoutControlPaint) -> Bool)? = nil) -> [UInt32] {
    var px = [UInt32](repeating: 0x123456, count: w * h)
    px.withUnsafeMutableBufferPointer { p in
        e.paint(into: p.baseAddress!, stride: w, width: w, height: h, scrollX: 0, scrollY: scrollY,
                images: images, controlPainter: control)
    }
    return px
}

private func at(_ px: [UInt32], _ w: Int, _ x: Int, _ y: Int) -> UInt32 { px[y * w + x] & 0xffffff }

private func hexColor(_ v: UInt32) -> String { hex([UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)]) }

func layoutPaintTests(_ t: Tests) {
    t.section("paint")
    let w = 200, h = 150
    let box = "<!DOCTYPE html><body style='margin:0'><div style='position:absolute;left:10px;top:20px;width:30px;height:40px;background:red'></div>"
    var e = layoutPage(t, box, width: w, height: h)
    var px = layoutRender(e, w, h)
    t.equal(hexColor(at(px, w, 15, 25)), "ff0000", "red box inside")
    t.equal(hexColor(at(px, w, 39, 59)), "ff0000", "red box corner")
    t.equal(hexColor(at(px, w, 9, 25)), "ffffff", "left of box")
    t.equal(hexColor(at(px, w, 40, 25)), "ffffff", "right of box")
    t.equal(hexColor(at(px, w, 15, 60)), "ffffff", "below box")
    px = layoutRender(e, w, h, scrollY: 15)
    t.equal(hexColor(at(px, w, 15, 5)), "ff0000", "scrolled box")
    t.equal(hexColor(at(px, w, 15, 46)), "ffffff", "scrolled box bottom")

    e = layoutPage(t, "<!DOCTYPE html><body style='margin:0;height:2000px'><div style='position:fixed;left:0;top:0;width:20px;height:20px;background:#00f'></div><div style='height:30px;background:#0f0'></div>", width: w, height: h)
    px = layoutRender(e, w, h, scrollY: 100)
    t.equal(hexColor(at(px, w, 5, 5)), "0000ff", "fixed stays in the viewport")
    t.equal(hexColor(at(px, w, 50, 5)), "ffffff", "flow content scrolled away")
    px = layoutRender(e, w, h, scrollY: 0)
    t.equal(hexColor(at(px, w, 50, 5)), "00ff00", "flow content at scroll 0")

    // Text paints glyph pixels inside its fragment, and nowhere else.
    e = layoutPage(t, "<!DOCTYPE html><body style='margin:0'><p style='margin:0;font:20px sans-serif;color:#000'>Hello</p>", width: w, height: h)
    px = layoutRender(e, w, h)
    if let p = e.document.firstElement(where: { $0.name == "p" }), let r = e.rect(of: p) {
        var dark = 0, outside = 0
        for y in 0..<h { for x in 0..<w where at(px, w, x, y) != 0xffffff {
            if r.contains(Double(x), Double(y)) { dark += 1 } else { outside += 1 }
        } }
        t.check(dark > 50, "text has glyph pixels", "\(dark)")
        t.equal(outside, 0, "no text pixels outside the paragraph")
    } else { t.check(false, "paragraph rect") }

    // overflow: hidden clips the child.
    e = layoutPage(t, "<!DOCTYPE html><body style='margin:0'><div style='overflow:hidden;width:50px;height:50px'><div style='width:150px;height:150px;background:red'></div></div>", width: w, height: h)
    px = layoutRender(e, w, h)
    t.equal(hexColor(at(px, w, 25, 25)), "ff0000", "clipped child inside")
    t.equal(hexColor(at(px, w, 70, 25)), "ffffff", "clipped child outside (x)")
    t.equal(hexColor(at(px, w, 25, 70)), "ffffff", "clipped child outside (y)")

    // z-index and stacking order.
    e = layoutPage(t, "<!DOCTYPE html><body style='margin:0'><div style='position:absolute;left:0;top:0;width:50px;height:50px;background:#f00;z-index:3'></div><div style='position:absolute;left:20px;top:20px;width:50px;height:50px;background:#0f0;z-index:1'></div><div style='position:absolute;left:40px;top:40px;width:50px;height:50px;background:#00f;z-index:-1'></div><div style='width:100px;height:100px;background:#888'></div>", width: w, height: h)
    px = layoutRender(e, w, h)
    t.equal(hexColor(at(px, w, 30, 30)), "ff0000", "z 3 over z 1")
    t.equal(hexColor(at(px, w, 60, 60)), "00ff00", "z 1 over z -1")
    t.equal(hexColor(at(px, w, 85, 85)), "888888", "flow block over z -1")

    // A float paints over a later block's background.
    e = layoutPage(t, "<!DOCTYPE html><body style='margin:0'><div style='float:left;width:40px;height:40px;background:#00f'></div><div style='height:60px;background:#ccc'></div>", width: w, height: h)
    px = layoutRender(e, w, h)
    t.equal(hexColor(at(px, w, 10, 10)), "0000ff", "float above block background")
    t.equal(hexColor(at(px, w, 60, 10)), "cccccc", "block background beside float")

    // Opacity, borders, dashes, canvas background.
    e = layoutPage(t, "<!DOCTYPE html><body style='margin:0;background:#ff0'><div style='opacity:0.5;width:20px;height:20px;background:#f00'></div><div style='border-left:4px solid #00f;width:20px;height:20px'></div><div style='border-top:2px dashed #000;width:100px;height:10px'></div>", width: w, height: h)
    px = layoutRender(e, w, h)
    let half = at(px, w, 10, 10)
    t.check(half >> 16 & 255 == 255 && (half >> 8 & 255) > 100 && (half >> 8 & 255) < 160 && half & 255 == 0, "50% red over yellow", hexColor(half))
    t.equal(hexColor(at(px, w, 1, 30)), "0000ff", "border-left")
    t.equal(hexColor(at(px, w, 10, 30)), "ffff00", "inside border box")
    var on = 0, off = 0
    for x in 0..<100 { if at(px, w, x, 40) == 0 { on += 1 } else { off += 1 } }
    t.check(on > 20 && off > 20, "dashed border has dashes and gaps", "\(on)/\(off)")
    t.equal(hexColor(at(px, w, 150, 140)), "ffff00", "body background fills the canvas")

    // Images and background images through the provider.
    let green = ImageBitmap(width: 4, height: 4, pixels: [UInt32](repeating: 0xff00_ff00, count: 16), opaque: true)
    let checker = ImageBitmap(width: 2, height: 2, pixels: [0xffff_0000, 0xff00_00ff, 0xff00_00ff, 0xffff_0000], opaque: true)
    let imgs: (String) -> ImageBitmap? = { u in u == "g.png" ? green : (u == "c.png" ? checker : nil) }
    e = layoutPage(t, "<!DOCTYPE html><body style='margin:0'><img src='g.png' style='display:block'><div style='width:20px;height:10px;background:url(c.png)'></div><div style='width:20px;height:10px;background:url(c.png) no-repeat'></div>",
                   width: w, height: h, images: ["g.png": (40, 30), "c.png": (2, 2)])
    px = layoutRender(e, w, h, images: imgs)
    t.equal(hexColor(at(px, w, 20, 15)), "00ff00", "scaled image")
    t.equal(hexColor(at(px, w, 41, 15)), "ffffff", "right of image")
    t.equal(hexColor(at(px, w, 4, 30)), "ff0000", "background tile (0,0)")
    t.equal(hexColor(at(px, w, 5, 30)), "0000ff", "background tile (1,0)")
    t.equal(hexColor(at(px, w, 15, 30)), "0000ff", "background tile repeated")
    t.equal(hexColor(at(px, w, 0, 40)), "ff0000", "no-repeat tile")
    t.equal(hexColor(at(px, w, 10, 40)), "ffffff", "no-repeat outside the tile")

    // visibility: hidden paints nothing; controls go through the browser's painter.
    e = layoutPage(t, "<!DOCTYPE html><body style='margin:0'><div style='visibility:hidden;width:20px;height:20px;background:red'></div><input style='display:block' value=x>", width: w, height: h)
    var calls = 0
    var ctlRect = LayoutRect()
    px = layoutRender(e, w, h, control: { c in calls += 1; ctlRect = c.borderBox; return true })
    t.equal(hexColor(at(px, w, 10, 10)), "ffffff", "visibility hidden")
    t.equal(calls, 1, "control painter called")
    t.equal(layoutInt(ctlRect.y), 20, "control rect y")
    px = layoutRender(e, w, h)
    var ink = 0
    for y in 20..<40 { for x in 0..<w where at(px, w, x, y) != 0xffffff { ink += 1 } }
    t.check(ink > 20, "default control appearance", "\(ink)")
}

func layoutHitTests(_ t: Tests) {
    t.section("hit")
    let html = """
    <!DOCTYPE html><title> The  Title </title><body style='margin:0;font:16px sans-serif'>
    <p id=top style='margin:0'>Plain <a href="/next" id=lnk>a <b>bold</b> link</a> text</p>
    <div id=box style='width:100px;height:50px;background:#eee' title=tip></div>
    <div style='position:absolute;left:0;top:0;width:10px;height:10px;z-index:5' id=over></div>
    <form><input id=inp value=x> <button id=btn>go</button></form>
    <div style='position:fixed;right:0;bottom:0;width:30px;height:30px' id=fx></div>
    <div style='height:1000px'></div><a name=anchor>anchor</a><div id=far>far</div>
    """
    let e = layoutPage(t, html, width: 300, height: 200)
    t.equal(e.title, "The Title", "title")
    guard let lnk = e.document.getElementById("lnk"), let r = e.rect(of: lnk) else { t.check(false, "link rect"); return }
    let h = e.hitTest(x: r.x + 3, y: r.y + r.h / 2)
    t.equal(h.href ?? "nil", "/next", "href under the link")
    t.check(h.link === lnk, "link node")
    t.equal(h.cursor, "pointer", "pointer cursor")
    if let b = e.document.firstElement(where: { $0.name == "b" }), let br = e.rect(of: b) {
        let hb = e.hitTest(x: br.x + br.w / 2, y: br.y + br.h / 2)
        t.check(hb.node === b, "deepest element is <b>")
        t.equal(hb.href ?? "nil", "/next", "href from an ancestor")
    }
    t.equal(e.linkAt(x: 12, y: r.y + 5) ?? "nil", "nil", "no link over plain text")
    if let box = e.document.getElementById("box"), let br = e.rect(of: box) {
        let hb = e.hitTest(x: br.x + 50, y: br.y + 25)
        t.check(hb.node === box, "div under the point")
        t.equal(hb.title ?? "nil", "tip", "title attribute")
    }
    t.check(e.hitTest(x: 5, y: 5).node === e.document.getElementById("over"), "positioned box on top")
    if let inp = e.document.getElementById("inp"), let ir = e.rect(of: inp) {
        t.check(e.hitTest(x: ir.x + 5, y: ir.y + 5).control === inp, "control under the point")
    }
    if let btn = e.document.getElementById("btn"), let ir = e.rect(of: btn) {
        t.check(e.hitTest(x: ir.x + ir.w / 2, y: ir.y + ir.h / 2).control === btn, "button control")
    }
    let fx = e.document.getElementById("fx")
    t.check(e.hitTest(x: 290, y: 190 + 500, scrollX: 0, scrollY: 500).node === fx, "fixed box hit while scrolled")
    t.check(e.hitTest(x: 290, y: 190).node === fx, "fixed box hit at scroll 0")
    let fy = e.fragmentY("far") ?? -1
    t.check(fy > 1000, "fragment by id", "\(layoutInt(fy))")
    let ay = e.fragmentY("anchor") ?? -1
    t.check(ay > 1000 && ay < fy, "fragment by a name", "\(layoutInt(ay))")
    t.check(e.fragmentY("nothing") == nil, "missing fragment")
    t.check(e.documentHeight > 1000, "document height")
    let controls = e.formControls
    t.equal(controls.count, 2, "form controls")
    if controls.count == 2 {
        t.check(controls[0].kind == .textInput && controls[0].borderBox.w > 50, "text input rect")
        t.check(controls[1].kind == .button, "button control kind")
    }
    t.check(e.hitTest(x: -50, y: -50).node == nil, "outside the page")
}

func layoutAPITests(_ t: Tests) {
    t.section("api")
    // :hover restyle.
    var e = layoutPage(t, "<!DOCTYPE html><style>a:hover { color: #ff0000 } a { color: #0000ff }</style><a href=x id=a>link</a> <span id=s>s</span>")
    let a = e.document.getElementById("a")!
    t.check(e.hasHoverRules, "hover rules detected")
    t.check(e.box(for: a)?.style.color == CSSColor(r: 0, g: 0, b: 255), "not hovered")
    t.check(e.setHover(a), "hover needs repaint")
    e.update()
    t.check(e.box(for: a)?.style.color == CSSColor(r: 255, g: 0, b: 0), "hovered color")
    t.check(!e.setHover(a), "same hover is a no-op")
    t.check(e.setHover(nil), "unhover")
    e.update()
    t.check(e.box(for: a)?.style.color == CSSColor(r: 0, g: 0, b: 255), "unhovered color")
    e = layoutPage(t, "<a href=x id=a>link</a>")
    t.check(!e.setHover(e.document.getElementById("a")), "no hover rules: no restyle")

    // Images arriving later.
    var sizes: [String: (Int, Int)] = [:]
    e = LayoutEngine(document: htmlParse("<!DOCTYPE html><img id=i src=late.png><p id=p>after</p>"), text: layoutFonts(t),
                     viewportWidth: 400, viewportHeight: 300)
    e.imageSize = { sizes[$0] }
    e.update()
    let img = e.document.getElementById("i")!
    t.equal(layoutInt(e.rect(of: img)?.w ?? -1), 0, "unknown image is 0 wide")
    t.check(e.imageURLs == ["late.png"], "image URLs")
    sizes["late.png"] = (120, 80)
    e.imagesChanged()
    e.update()
    t.equal(layoutInt(e.rect(of: img)?.w ?? -1), 120, "image width after it arrives")
    t.equal(layoutInt(e.rect(of: img)?.h ?? -1), 80, "image height after it arrives")

    // Viewport resize with a media query; percentage widths.
    e = layoutPage(t, "<!DOCTYPE html><style>#d { width: 50% } @media (max-width: 500px) { #d { width: 10px } }</style><body style='margin:0'><div id=d>x</div>", width: 800, height: 300)
    let d = e.document.getElementById("d")!
    t.equal(layoutInt(e.rect(of: d)?.w ?? -1), 400, "50% of 800")
    e.setViewport(width: 400, height: 300)
    e.update()
    t.equal(layoutInt(e.rect(of: d)?.w ?? -1), 10, "media query after resize")

    // <link> slots and extra sheets.
    e = layoutPage(t, "<!DOCTYPE html><link rel=stylesheet href=a.css><style>#x { height: 5px }</style><link rel='alternate stylesheet' href=b.css><div id=x></div>")
    t.equal(e.styleSources.count, 2, "style sources")
    t.equal(e.styleSources[0].href ?? "nil", "a.css", "link href")
    let x = e.document.getElementById("x")!
    t.equal(layoutInt(e.rect(of: x)?.h ?? -1), 5, "inline style sheet applies")
    e.setStyleSheets(slot: 0, [cssParseStylesheet("#x { height: 50px; width: 30px }")])
    e.update()
    t.equal(layoutInt(e.rect(of: x)?.h ?? -1), 5, "later <style> still wins")
    t.equal(layoutInt(e.rect(of: x)?.w ?? -1), 30, "linked sheet applies")
    e.addStyleSheet(cssParseStylesheet("#x { height: 7px !important }"))
    e.update()
    t.equal(layoutInt(e.rect(of: x)?.h ?? -1), 7, "extra sheet")

    // Quirks mode (no doctype): tables do not inherit text-align.
    e = layoutPage(t, "<center><table width=300><tr><td id=c>x</td></tr></table></center>")
    t.check(e.quirksMode, "no doctype is quirks mode")
    if let c = e.document.getElementById("c"), let b = e.box(for: c) { t.check(b.style.textAlign == .left, "quirks: table text-align initial") }
    e = layoutPage(t, "<!DOCTYPE html><p>x")
    t.check(!e.quirksMode, "doctype html is standards mode")

    // Hint values never inject CSS; author CSS beats hints.
    e = layoutPage(t, "<!DOCTYPE html><table bgcolor='red; display:none' width='50%; x'><tr><td id=c>x</td></tr></table>")
    t.check(e.rect(of: e.document.getElementById("c")!) != nil, "hostile bgcolor ignored")
    e = layoutPage(t, "<!DOCTYPE html><style>img { width: 10px; height: auto }</style><img id=i src=a.png width=200 height=100>", images: ["a.png": (40, 30)])
    if let r = e.rect(of: e.document.getElementById("i")!) {
        t.equal(layoutInt(r.w), 10, "CSS width beats width attribute")
        t.equal(layoutInt(r.h), 8, "height auto from the aspect ratio")
    }
    // Control state overrides.
    e = layoutPage(t, "<!DOCTYPE html><input id=i value=abc>")
    let inp = e.document.getElementById("i")!
    e.controlValues[ObjectIdentifier(inp)] = "typed"
    let px = layoutRender(e, 200, 50)
    var ink = 0
    for v in px where v & 0xffffff != 0xffffff { ink += 1 }
    t.check(ink > 30, "typed control value painted")
}

func layoutRobustnessTests(_ t: Tests) {
    t.section("robustness")
    let verbose = getenv("WIFFER_LAYOUT_VERBOSE") != nil
    func run(_ html: String, _ label: String, width: Int = 300) {
        if verbose { print("  robustness: \(label)"); fflush(nil) }
        let e = layoutPage(t, html, width: width, height: 200)
        let px = layoutRender(e, 64, 48, scrollY: 10)
        _ = e.hitTest(x: 10, y: 10)
        _ = e.dump()
        t.check(px.count == 64 * 48 && e.documentHeight == e.documentHeight, label)
    }
    var deep = ""
    for _ in 0..<5000 { deep += "<div style='padding-left:1px'>" }
    run(deep + "x", "deep divs")
    deep = ""
    for _ in 0..<3000 { deep += "<span style='border:1px solid'>" }
    run(deep + "x", "deep spans")
    deep = ""
    for _ in 0..<600 { deep += "<table><tr><td>" }
    run(deep + "x", "deep tables")
    deep = ""
    for _ in 0..<600 { deep += "<div style='float:left;display:inline-block'>" }
    run(deep + "x", "deep floats")
    deep = ""
    for _ in 0..<600 { deep += "<div style='display:flex;flex-direction:column'><div style='flex:1'>" }
    run(deep + "x", "deep flex")
    deep = ""
    for _ in 0..<600 { deep += "<li><ol style='position:relative'>" }
    run(deep + "x", "deep lists")
    run("<div style='width:1e30px;height:1e30px;margin:-1e30px;padding:1e30px;font-size:1e30px;line-height:1e30px'>huge</div>", "huge values")
    run("<div style='width:calc(100% - 1e308px);font-size:0;line-height:-5px;z-index:99999999999;opacity:-3'>x</div>", "odd values")
    run("<table><tr><td colspan=99999 rowspan=0>a<td rowspan=70000>b<tr><td colspan=0>c</table>", "spans")
    var cols = "<table><tr>"
    for _ in 0..<1500 { cols += "<td>x" }
    run(cols, "many columns")
    var word = "<p>"
    for _ in 0..<200_000 { word += "w" }
    run(word, "one huge word")
    var floats = ""
    for i in 0..<3000 { floats += "<div style='float:\(i % 2 == 0 ? "left" : "right");width:\(i % 50)px;height:3px'></div>text " }
    run(floats, "many floats")
    var flex = "<div style='display:flex'>"
    for _ in 0..<300 { flex += "<div style='flex:1 1 0;min-width:10px;max-width:5px'>x</div>" }
    run(flex + "</div>", "flex clamps")
    run("<img src=a.png width=999999 height=999999><img src=a.png style='width:-5px'><input size=99999999><textarea rows=99999 cols=99999></textarea>", "huge replaced")
    var pre = "<pre>"
    for _ in 0..<2000 { pre += "\t\tx\n" }
    run(pre, "pre tabs")
    run("<div style='position:absolute;left:50%;right:50%;width:auto;top:-1e9px'>a</div><div style='position:fixed;inset:0'>b</div>", "abs edge cases")
    run("<p style='text-align:justify;width:1px'>a b c d e f g</p><p style='text-indent:-1e9px'>x y</p>", "justify narrow")
    run("<ul style='list-style:upper-roman'><li value=-5>a<li value=999999999>b<li value=3999>c</ul>", "list values")
    run("", "empty document", width: 1)
}

func layoutFuzzTests(_ t: Tests) {
    t.section("fuzz")
    var seeds: [[UInt8]] = []
    for n in layoutFixtureNames { if let b = t.readFileIfPresent("lib/layout/fixtures/\(n).html") { seeds.append(b) } }
    if let h = t.readFileIfPresent("lib/layout/fixtures/hn.html") { seeds.append(Array(h.prefix(6000))) }
    let tx = layoutFonts(t)
    var buf = [UInt32](repeating: 0, count: 64 * 48)
    t.fuzz("pipeline", seeds: seeds, iterations: 400) { bytes in
        let doc = htmlParse(bytes)
        let e = LayoutEngine(document: doc, text: tx, viewportWidth: 200, viewportHeight: 150)
        e.imageSize = { u in u.utf8.count % 3 == 0 ? nil : (u.utf8.count * 7, u.utf8.count * 3) }
        e.update()
        buf.withUnsafeMutableBufferPointer { p in
            e.paint(into: p.baseAddress!, stride: 64, width: 64, height: 48, scrollY: 20)
        }
        _ = e.hitTest(x: 30, y: 30)
        if let b = doc.body { _ = e.setHover(b.firstElement { _ in true }); e.update() }
        e.setViewport(width: 90, height: 60)
        e.update()
    }
}

func layoutSiteTests(_ t: Tests) {
    t.section("sites")
    if let (e, p, c, l) = layoutSitePage(t, "lib/layout/fixtures/hn.html", "lib/layout/fixtures/hn.css", width: 1024) {
        print("  Hacker News (33 KB): parse \(p) ms, css \(c) ms, style+layout \(l) ms (style \(e.timings.styleMs), layout \(e.timings.layoutMs), display list \(e.timings.displayMs))")
        if let main = e.document.getElementById("hnmain"), let r = e.rect(of: main) {
            t.equal(layoutInt(r.w), 857, "hnmain is 85% of 1008")
            t.equal(layoutInt(r.x), 84, "hnmain centered")
        } else { t.check(false, "hnmain") }
        let stories = e.document.getElementsByClassName("athing")
        t.equal(stories.count, 30, "30 stories")
        var lastY = -1.0, ordered = true
        for s in stories { if let r = e.rect(of: s) { if r.y <= lastY { ordered = false }; lastY = r.y } }
        t.check(ordered, "stories stacked")
        if let first = stories.first, let tl = first.firstElement(where: { $0.hasClass("titleline") })?.firstElement(where: { $0.name == "a" }),
           let r = e.rect(of: tl) {
            t.check(r.x > 110 && r.x < 130 && r.h > 10 && r.h < 20, "first title link position", "\(layoutInt(r.x)),\(layoutInt(r.y))")
            t.check(e.linkAt(x: r.x + 5, y: r.y + 5)?.hasPrefix("https://") == true, "title link hit")
        }
        t.check(l < 500, "HN style+layout time", "\(l) ms")
    }
    if let (e, p, c, l) = layoutSitePage(t, "lib/html/fixtures/wikipedia-html.html", "lib/layout/fixtures/wikipedia.css", width: 1024) {
        print("  Wikipedia (783 KB, 228 KB CSS): parse \(p) ms, css \(c) ms, style+layout \(l) ms (style \(e.timings.styleMs), layout \(e.timings.layoutMs), display list \(e.timings.displayMs)), \(e.display.items.count) display items, height \(layoutInt(e.documentHeight))")
        t.check(e.documentHeight > 10_000, "wikipedia is long")
        t.check(l < 1000, "wikipedia style+layout under a second", "\(l) ms")
        // Relayout only (no restyle), e.g. after images arrive.
        let t0 = hostMillis()
        e.imagesChanged()
        e.update()
        let relayout = hostMillis() - t0
        // Scrolling: repaint a 1024x768 viewport at 20 positions.
        var px = [UInt32](repeating: 0, count: 1024 * 768)
        let t1 = hostMillis()
        for k in 0..<20 {
            px.withUnsafeMutableBufferPointer { b in
                e.paint(into: b.baseAddress!, stride: 1024, width: 1024, height: 768, scrollY: Double(k) * 1000)
            }
        }
        let paint = (hostMillis() - t1) / 20
        print("  Wikipedia relayout \(relayout) ms, paint \(paint) ms per 1024x768 frame")
        t.check(paint < 200, "paint time", "\(paint) ms")
        let t2 = hostMillis()
        e.setViewport(width: 700, height: 600)
        e.update()
        print("  Wikipedia resize to 700 px (restyle + layout): \(hostMillis() - t2) ms")
    }
}
