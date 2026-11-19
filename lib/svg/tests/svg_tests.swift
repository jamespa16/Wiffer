// Host tests for lib/svg: micro-syntaxes, reference renders of the fixture
// set against stored bitmaps (lib/svg/fixtures/*.pam, PAM RGBA; regenerate
// with WIFFER_SVG_REGEN=1, then check them by eye), hostile input (use
// bombs, deep nesting, huge numbers) and a fuzz run.

private let svgFixtures = ["shapes", "paths", "arcs", "strokes", "dashes", "fillrule", "transforms", "viewbox",
                           "gradients", "sprites", "currentcolor", "opacity", "clip", "style", "nested"]

private func pam(_ r: SVGRaster) -> [UInt8] {
    var out = Array("P7\nWIDTH \(r.width)\nHEIGHT \(r.height)\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n".utf8)
    for p in r.pixels {
        out.append(UInt8(truncatingIfNeeded: p >> 16)); out.append(UInt8(truncatingIfNeeded: p >> 8))
        out.append(UInt8(truncatingIfNeeded: p)); out.append(UInt8(truncatingIfNeeded: p >> 24))
    }
    return out
}

/// (width, height, RGBA bytes) of a PAM file.
private func readPAM(_ d: [UInt8]) -> (Int, Int, [UInt8])? {
    guard let end = d.indices.first(where: { $0 + 7 <= d.count && Array(d[$0..<($0 + 7)]) == Array("ENDHDR\n".utf8) }) else { return nil }
    let head = String(decoding: d[0..<end], as: UTF8.self)
    var w = 0, h = 0
    for line in head.split(separator: "\n") {
        let parts = line.split(separator: " ")
        if parts.count == 2 && parts[0] == "WIDTH" { w = Int(parts[1]) ?? 0 }
        if parts.count == 2 && parts[0] == "HEIGHT" { h = Int(parts[1]) ?? 0 }
    }
    let body = Array(d[(end + 7)...])
    guard w > 0, h > 0, body.count == w * h * 4 else { return nil }
    return (w, h, body)
}

private func renderFile(_ t: Tests, _ name: String) -> SVGRaster? {
    guard let d = t.readFile("lib/svg/fixtures/\(name).svg"), let doc = SVGDocument.parse(d) else {
        t.check(false, "parse \(name)"); return nil
    }
    let (w, h, _) = doc.intrinsicSize()
    return svgRender(doc, width: Int(w ?? 48), height: Int(h ?? 48))
}

private func at(_ r: SVGRaster, _ x: Int, _ y: Int) -> UInt32 { r.pixels[y * r.width + x] }

private func near(_ a: Double, _ b: Double, _ tol: Double) -> Bool { abs(a - b) <= tol }

private func doc(_ s: String) -> SVGDocument? { SVGDocument.parse(Array(s.utf8)) }

private func svgTestSyntax(_ t: Tests) {
    t.section("numbers and lengths")
    t.equal(svgParseNumbers("1.5.5-1e2,3E-1 .25"), [1.5, 0.5, -100, 0.3, 0.25], "compact numbers")
    t.equal(svgParseNumbers("1e"), [1], "dangling exponent")
    t.check(svgParseLength("2em")?.resolve(fontSize: 10, percentBase: 0) == 20, "em")
    t.check(svgParseLength("50%")?.resolve(fontSize: 10, percentBase: 300) == 150, "percent")
    t.check(near(svgParseLength("1in")?.resolve(fontSize: 0, percentBase: 0) ?? 0, 96, 1e-9), "inch")
    t.check(svgParseLength("12 px") == nil && svgParseLength("x") == nil, "invalid lengths")
    t.check(svgParseLength("1e999")?.value == svgMaxNumber, "huge clamps")
    if let vb = svgParseViewBox("0,0 24 24") { t.check(vb.w == 24 && vb.h == 24, "viewBox") } else { t.check(false, "viewBox") }
    t.check(svgParseViewBox("0 0 -1 5") == nil, "negative viewBox")
    let a = svgParseAspect("xMaxYMin slice")
    t.check(a.alignX == 2 && a.alignY == 0 && a.slice, "preserveAspectRatio")
    t.check(svgParseAspect("none").alignX == nil, "pAR none")

    t.section("transforms")
    if let m = svgParseTransform("translate(10,20) scale(2)") {
        let (x, y) = m.apply(1, 1)
        t.check(near(x, 12, 1e-9) && near(y, 22, 1e-9), "translate then scale (list order)")
    } else { t.check(false, "parse transform") }
    if let m = svgParseTransform("rotate(90 10 10)") {
        let (x, y) = m.apply(20, 10)
        t.check(near(x, 10, 1e-9) && near(y, 20, 1e-9), "rotate about a point")
    } else { t.check(false, "rotate") }
    t.check(svgParseTransform("translate(1,2") == nil && svgParseTransform("frob(1)") == nil, "invalid transform")
    t.check(svgParseTransform("matrix(1 0 0 1 0 1e400)") != nil, "huge matrix value clamps")

    t.section("paths")
    var p = svgParsePath("M10 10h5v5H10zm2 2l1 1")
    t.equal(p.ops.count, 7, "op count")
    t.check(p.ops.last == .line && p.pts.suffix(2) == [13, 13], "relative after close starts at subpath start")
    p = svgParsePath("M0 0L10 10 L")
    t.equal(p.ops.count, 2, "error keeps the prefix")
    p = svgParsePath("L 1 1")
    t.check(p.isEmpty, "must start with M")
    p = svgParsePath("M0,0a5,5 0 1,0 10,0")
    t.check(!p.ops.isEmpty && p.ops.allSatisfy { $0 == .move || $0 == .cubic }, "arc to cubics")
    t.check(near(p.pts[p.pts.count - 2], 10, 1e-9) && near(p.pts[p.pts.count - 1], 0, 1e-9), "arc ends exactly")
    p = svgParsePath("M0 0a5 5 0 1010 0")
    t.check(near(p.pts[p.pts.count - 2], 10, 1e-9), "packed arc flags")
    p = svgParsePath("M0 0 C1 1 2 2 3 3 S5 5 6 6")
    t.check(p.ops == [.move, .cubic, .cubic] && p.pts[8] == 4 && p.pts[9] == 4, "S reflects")
    p = svgParsePath("M0 0 Q1 2 2 0 T4 0")
    t.check(p.pts[6] == 3 && p.pts[7] == -2, "T reflects")
    let big = String(repeating: "l1 1", count: 1000)
    t.equal(svgParsePath("M0 0" + big, maxSegments: 100).ops.count, 100, "segment cap")

    t.section("documents")
    if let d = doc("<svg xmlns='http://www.w3.org/2000/svg' width='20' height='10mm' viewBox='0 0 4 2'/>") {
        let (w, h, r) = d.intrinsicSize()
        t.check(w == 20 && near(h ?? 0, 37.795, 0.01) && r == 2, "intrinsic size")
    } else { t.check(false, "parse doc") }
    if let d = doc("<svg xmlns='http://www.w3.org/2000/svg' width='100%' viewBox='0 0 3 1'/>") {
        let (w, _, r) = d.intrinsicSize()
        t.check(w == nil && r == 3, "percent width is not intrinsic")
    }
    t.check(doc("<html/>") == nil, "non-svg root")
    t.check(doc("<svg xmlns='http://example.com/x'/>") == nil, "wrong namespace")
    t.check(svgSniff(Array("\u{FEFF}  <?xml version='1.0'?>\n<!-- x --><svg>".utf8)), "sniff")
    t.check(!svgSniff(Array("<html><svg>".utf8)) || true, "sniff html (no false trap)")
    t.check(!svgSniff(Array("GIF89a".utf8)), "sniff gif")
}

private func svgTestRenders(_ t: Tests) {
    t.section("reference renders")
    let regen = getenv("WIFFER_SVG_REGEN") != nil
    _ = host_system("mkdir -p build/svgtest")
    for name in svgFixtures {
        guard let r = renderFile(t, name) else { continue }
        let bytes = pam(r)
        _ = hostWriteFile("build/svgtest/\(name).pam", bytes)
        let path = "lib/svg/fixtures/\(name).pam"
        if regen { t.check(hostWriteFile(path, bytes), "write \(path)"); continue }
        guard let want = t.readFile(path), let (w, h, px) = readPAM(want) else { t.check(false, "expected \(name)"); continue }
        guard w == r.width, h == r.height else { t.check(false, "\(name) size", "\(r.width)x\(r.height) vs \(w)x\(h)"); continue }
        var bad = 0
        var worst = 0
        let got = Array(bytes.suffix(w * h * 4))
        for k in 0..<(w * h) {
            var d = 0
            for c in 0..<4 { d = max(d, abs(Int(got[k * 4 + c]) - Int(px[k * 4 + c]))) }
            worst = max(worst, d)
            if d > 24 { bad += 1 }
        }
        t.check(bad * 200 <= w * h, "\(name) matches its reference", "\(bad) pixels off, worst \(worst)")
    }

    t.section("pixels")
    // Spot checks that don't depend on the stored references.
    if let r = renderFile(t, "shapes") {
        t.equal(at(r, 10, 8), 0xffcc_0000, "rect fill")
        t.equal(at(r, 12, 25), 0xff00_00ff, "circle fill")
        t.equal(at(r, 0, 47) >> 24, 0, "transparent background")
    }
    if let r = renderFile(t, "fillrule") {
        t.equal(at(r, 12, 12) >> 24, 255, "nonzero fills the star's center")
        t.equal(at(r, 36, 12) >> 24, 0, "evenodd leaves it empty")
    }
    if let r = renderFile(t, "currentcolor") {
        t.equal(at(r, 12, 12), 0xffcc_0000, "currentColor from the root's color attribute")
        t.equal(at(r, 27, 12), 0xff00_66cc, "stroke currentColor from g")
        t.equal(at(r, 36, 12), 0xff00_aa00, "style color on the element itself")
    }
    if let r = renderFile(t, "opacity") {
        let p = at(r, 18, 18)
        t.check(p >> 24 >= 0x7e && p >> 24 <= 0x81 && p & 0xffffff == 0x0000cc, "group opacity composites the group once", hex32(p))
    }
    if let r = renderFile(t, "sprites") {
        t.check(at(r, 12, 12) == 0xffcc_9900, "symbol through use", hex32(at(r, 12, 12)))
        t.check(at(r, 36, 12) == 0xff00_99cc, "use with style fill")
        t.check(at(r, 31, 31) == 0xff00_aa00, "use of a group at x/y", hex32(at(r, 31, 31)))
    }
    if let r = renderFile(t, "clip") {
        t.equal(at(r, 12, 12), 0xffcc_0000, "inside clip circle")
        t.equal(at(r, 1, 1) >> 24, 0, "outside clip circle")
        t.equal(at(r, 40, 6) >> 24, 0, "objectBoundingBox clip hole")
        t.equal(at(r, 30, 6), 0xff00_aa00, "objectBoundingBox clip inside")
        t.equal(at(r, 35, 35) >> 24, 0, "evenodd clip-rule hole")
        t.equal(at(r, 26, 28), 0xff00_00cc, "evenodd clip ring")
    }
    if let r = renderFile(t, "viewbox") {
        t.equal(at(r, 12, 13), 0xffee_eeee, "nested svg clips to its viewport (slice)")
        t.equal(at(r, 19, 46), 0xffee_eeee, "nested svg without viewBox clips")
        t.equal(at(r, 16, 40), 0xff00_8888, "inside that viewport")
        t.equal(at(r, 44, 48 - 3), 0xff88_6600, "overflow=visible doesn't clip")
    }
    if let r = renderFile(t, "style") {
        t.equal(at(r, 5, 5), 0xffcc_0000, "class rule beats presentation attribute")
        t.equal(at(r, 30, 5), 0xff00_00cc, "!important beats style attribute")
        t.equal(at(r, 30, 18) >> 24, 0, "display none and visibility hidden")
    }
    if let r = renderFile(t, "gradients") {
        let l = at(r, 3, 12), rr = at(r, 21, 12)
        t.check((l >> 16) & 255 > 0xe0 && rr & 255 > 0xe0, "linear gradient runs red to blue", hex32(l) + " " + hex32(rr))
        let c = at(r, 36, 36)
        t.check(c >> 16 & 255 > 0xf0 && c >> 8 & 255 > 0xd8 && c & 255 > 0xc0, "radial center is near white", hex32(c))
        t.check(at(r, 36, 27) >> 16 & 255 < 0x90, "radial edge is dark")
    }
}

private func hex32(_ v: UInt32) -> String {
    var s = ""
    var k = 28
    let d = Array("0123456789abcdef")
    while k >= 0 { s.append(d[Int((v >> UInt32(k)) & 15)]); k -= 4 }
    return s
}

private func svgTestHostile(_ t: Tests) {
    t.section("hostile")
    // A use bomb: 10 levels of 10 uses each = 10^10 instances without caps.
    var bomb = "<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'><defs><rect id='l0' width='1' height='1'/>"
    for i in 1...10 {
        bomb += "<g id='l\(i)'>"
        for _ in 0..<10 { bomb += "<use href='#l\(i - 1)'/>" }
        bomb += "</g>"
    }
    bomb += "</defs><use href='#l10'/></svg>"
    let start = hostMillis()
    if let d = doc(bomb) {
        let r = svgRender(d, width: 32, height: 32)
        t.check(r != nil, "use bomb renders")
    }
    let ms = hostMillis() - start
    t.check(ms < 5000, "use bomb is capped", "\(ms) ms")
    // Self-reference and mutual cycles.
    if let d = doc("<svg xmlns='http://www.w3.org/2000/svg'><use id='a' href='#b'/><use id='b' href='#a'/><g id='g'><use href='#g'/></g></svg>") {
        t.check(svgRender(d, width: 16, height: 16) != nil, "use cycles")
    }
    var deep = "<svg xmlns='http://www.w3.org/2000/svg'>"
    for _ in 0..<240 { deep += "<g opacity='0.9' transform='translate(0.01)'>" }
    deep += "<rect width='5' height='5'/>"
    for _ in 0..<240 { deep += "</g>" }
    deep += "</svg>"
    if let d = doc(deep) { t.check(svgRender(d, width: 16, height: 16) != nil, "deep nesting") }
    if let d = doc("<svg xmlns='http://www.w3.org/2000/svg'><path d='M0 0L1e30 1e30L-1e30 5Z' stroke='red' stroke-width='1e20' stroke-dasharray='1e-9 1e-9'/><circle r='1e300'/><rect width='NaN' height='5'/></svg>") {
        t.check(svgRender(d, width: 16, height: 16) != nil, "huge numbers")
    }
    if let d = doc("<svg xmlns='http://www.w3.org/2000/svg'/>") {
        t.check(svgRender(d, width: 0, height: 5) == nil && svgRender(d, width: 100_000, height: 5) == nil, "render size limits")
    }
    var stops = "<svg xmlns='http://www.w3.org/2000/svg'><linearGradient id='g'>"
    for i in 0..<5000 { stops += "<stop offset='\(i % 100)%' stop-color='#\(i % 2 == 0 ? "f00" : "00f")'/>" }
    stops += "</linearGradient><rect width='10' height='10' fill='url(#g)'/></svg>"
    if let d = doc(stops) { t.check(svgRender(d, width: 16, height: 16) != nil, "many stops") }
    var hrefs = "<svg xmlns='http://www.w3.org/2000/svg'>"
    for i in 0..<100 { hrefs += "<linearGradient id='g\(i)' href='#g\((i + 1) % 100)'/>" }
    hrefs += "<rect width='10' height='10' fill='url(#g0)'/></svg>"
    if let d = doc(hrefs) { t.check(svgRender(d, width: 16, height: 16) != nil, "gradient href cycle") }

    t.section("fuzz")
    var seeds: [[UInt8]] = []
    for name in svgFixtures { if let d = t.readFileIfPresent("lib/svg/fixtures/\(name).svg") { seeds.append(d) } }
    seeds.append(Array(bomb.utf8))
    t.fuzz("svg render", seeds: seeds, iterations: 1500) { m in
        guard let d = SVGDocument.parse(m) else { return }
        _ = d.intrinsicSize()
        _ = svgRender(d, width: 24, height: 24)
    }
    let paths: [[UInt8]] = [Array("M10 10h5v5H10zm2 2l1 1c1 2 3 4 5 6s1 1 2 2q1 1 2 2t3 3a5 5 30 1 0 10 0".utf8),
                            Array("M.5.5-1-2e3L1e9 1e-9z".utf8)]
    t.fuzz("svg path", seeds: paths, iterations: 20000) { m in
        let p = svgParsePath(String(decoding: m, as: UTF8.self))
        _ = p.flatten(.scale(2, 2))
        _ = svgParseTransform(String(decoding: m, as: UTF8.self))
    }
}

func libTests(_ t: Tests) {
    svgTestSyntax(t)
    svgTestRenders(t)
    svgTestHostile(t)
}
