// Host tests for lib/layout: layout dumps of fixture pages compared with
// expected output, paint pixel checks, hit testing, a pipeline fuzzer and
// timings on saved Wikipedia and Hacker News pages.
//
// Regenerate the expected dumps on purpose with
//     WIFFER_LAYOUT_REGEN=1 ./run.sh --hosttest layout
// (then review the diff).

private var layoutTestFonts: FontRegistry? = nil

func layoutFonts(_ t: Tests) -> TextEngine {
    if let r = layoutTestFonts { return TextEngine(registry: r) }
    let reg = FontRegistry()
    for b in fontBundled {
        guard let d = t.readFile("rootfs" + b.path) else { continue }
        reg.add(d, family: b.family, generic: b.generic, bold: b.bold, italic: b.italic)
    }
    layoutTestFonts = reg
    return TextEngine(registry: reg)
}

func layoutPage(_ t: Tests, _ html: String, width: Int = 400, height: Int = 300,
                  images: [String: (Int, Int)] = [:]) -> LayoutEngine {
    let doc = htmlParse(html)
    let e = LayoutEngine(document: doc, text: layoutFonts(t), viewportWidth: width, viewportHeight: height)
    e.imageSize = { url in images[url] }
    e.update()
    return e
}

private func hostEnv(_ name: String) -> String? {
    guard let p = getenv(name) else { return nil }
    return String(cString: p)
}

func layoutSitePage(_ t: Tests, _ htmlPath: String, _ cssPath: String, width: Int) -> (LayoutEngine, Int, Int, Int)? {
    guard let h = t.readFileIfPresent(htmlPath), let c = t.readFileIfPresent(cssPath) else { return nil }
    let tx = layoutFonts(t)
    let t0 = hostMillis()
    let doc = htmlParse(h)
    let t1 = hostMillis()
    let e = LayoutEngine(document: doc, text: tx, viewportWidth: width, viewportHeight: 768)
    e.clock = { hostMillis() }
    let sheet = cssParseStylesheet(c)
    for (i, s) in e.styleSources.enumerated() where s.href != nil { e.setStyleSheets(slot: i, [sheet]); break }
    let t2 = hostMillis()
    e.update()
    let t3 = hostMillis()
    return (e, t1 - t0, t2 - t1, t3 - t2)
}

/// Paint the top of a page into a PPM file (debugging aid).
private func writePPM(_ e: LayoutEngine, _ path: String, width: Int, height: Int, scrollY: Double = 0) {
    var px = [UInt32](repeating: 0, count: width * height)
    px.withUnsafeMutableBufferPointer { p in
        e.paint(into: p.baseAddress!, stride: width, width: width, height: height, scrollX: 0, scrollY: scrollY)
    }
    var out = Array("P6\n\(width) \(height)\n255\n".utf8)
    for v in px { out.append(UInt8(v >> 16 & 255)); out.append(UInt8(v >> 8 & 255)); out.append(UInt8(v & 255)) }
    _ = hostWriteFile(path, out)
}

let layoutFixtureNames = ["block", "margins", "inline", "whitespace", "valign", "floats", "position", "tables",
                          "flex", "lists", "replaced", "pseudo", "hints", "overflow", "hn"]
let layoutFixtureImages: [String: (Int, Int)] = ["a.png": (40, 30), "b.png": (100, 50), "wide.png": (600, 200), "tall.png": (20, 80)]

private func firstDiff(_ a: String, _ b: String) -> String {
    let la = a.split(separator: "\n", omittingEmptySubsequences: false)
    let lb = b.split(separator: "\n", omittingEmptySubsequences: false)
    var i = 0
    while i < la.count && i < lb.count {
        if la[i] != lb[i] { return "line \(i + 1): got \"\(la[i])\", want \"\(lb[i])\"" }
        i += 1
    }
    return "length \(la.count) vs \(lb.count)"
}

private func fixtureTests(_ t: Tests) {
    t.section("fixtures")
    let regen = hostEnv("WIFFER_LAYOUT_REGEN") != nil
    for name in layoutFixtureNames {
        guard let html = t.readFile("lib/layout/fixtures/\(name).html") else { continue }
        // A fixture with its own .css (a saved site) gets it as the first <link> sheet, at 1024 px.
        let css = t.readFileIfPresent("lib/layout/fixtures/\(name).css")
        let doc = htmlParse(html)
        let e = LayoutEngine(document: doc, text: layoutFonts(t), viewportWidth: css == nil ? 400 : 1024, viewportHeight: css == nil ? 300 : 768)
        e.imageSize = { url in layoutFixtureImages[url] }
        if let c = css { for (i, s) in e.styleSources.enumerated() where s.href != nil { e.setStyleSheets(slot: i, [cssParseStylesheet(c)]); break } }
        e.update()
        let got = e.dump()
        let path = "lib/layout/fixtures/\(name).expected"
        if hostEnv("WIFFER_LAYOUT_PPM") != nil { writePPM(e, "build/hosttest/fx-\(name).ppm", width: 400, height: 300) }
        if regen {
            t.check(hostWriteFile(path, Array(got.utf8)), "write \(path)")
            continue
        }
        guard let want = t.readFile(path) else { continue }
        let w = String(decoding: want, as: UTF8.self)
        if got != w {
            _ = hostWriteFile("build/hosttest/layout-\(name).actual", Array(got.utf8))
            t.check(false, "\(name) dump", firstDiff(got, w))
        } else { t.check(true, name) }
    }
}

func libTests(_ t: Tests) {
    // WIFFER_LAYOUT_ONLY=robustness (etc.) runs one group.
    let only = hostEnv("WIFFER_LAYOUT_ONLY")
    func want(_ g: String) -> Bool { only == nil || only == g }
    if want("fixtures") { fixtureTests(t) }
    if want("paint") { layoutPaintTests(t) }
    if want("hit") { layoutHitTests(t) }
    if want("svg") { layoutSVGTests(t) }
    if want("api") { layoutAPITests(t) }
    if want("robustness") { layoutRobustnessTests(t) }
    if want("fuzz") { layoutFuzzTests(t) }
    if want("sites") { layoutSiteTests(t) }
    if want("incremental") { layoutIncrementalTests(t) }
    if only == "profile" {
        // Restyle the Wikipedia page repeatedly (for a sampling profiler).
        if let (e, _, _, _) = layoutSitePage(t, "lib/html/fixtures/wikipedia-html.html", "lib/layout/fixtures/wikipedia.css", width: 1024) {
            for _ in 0..<30 { e.invalidateStyle(); e.update() }
        }
    }
    // WIFFER_LAYOUT_RENDER=page.html[:sheet.css] paints any saved page to build/hosttest/render.ppm.
    if let spec = hostEnv("WIFFER_LAYOUT_RENDER") {
        let parts = spec.split(separator: ":").map(String.init)
        let w = Int(hostEnv("WIFFER_LAYOUT_WIDTH") ?? "1024") ?? 1024
        let hgt = Int(hostEnv("WIFFER_LAYOUT_HEIGHT") ?? "1400") ?? 1400
        let sy = Double(Int(hostEnv("WIFFER_LAYOUT_SCROLL") ?? "0") ?? 0)
        if let h = t.readFileIfPresent(parts[0]) {
            let e = LayoutEngine(document: htmlParse(h), text: layoutFonts(t), viewportWidth: w, viewportHeight: 768)
            if parts.count > 1, let c = t.readFileIfPresent(parts[1]) {
                let sheet = cssParseStylesheet(c)
                for (i, s) in e.styleSources.enumerated() where s.href != nil { e.setStyleSheets(slot: i, [sheet]) }
            }
            e.update()
            writePPM(e, "build/hosttest/render.ppm", width: w, height: hgt, scrollY: sy)
            if hostEnv("WIFFER_LAYOUT_DUMP") != nil { print(e.dump()) }
        }
    }
    if hostEnv("WIFFER_LAYOUT_PPM") != nil {
        if let (e, _, _, _) = layoutSitePage(t, "lib/layout/fixtures/hn.html", "lib/layout/fixtures/hn.css", width: 1024) {
            writePPM(e, "build/hosttest/hn.ppm", width: 1024, height: 700)
        }
        if let (e, _, _, _) = layoutSitePage(t, "lib/html/fixtures/wikipedia-html.html", "lib/layout/fixtures/wikipedia.css", width: 1024) {
            writePPM(e, "build/hosttest/wiki.ppm", width: 1024, height: 1400)
        }
    }
}
