// jQuery 3.7.1 (lib/js/fixtures/corpus) on a page with a layout engine:
// the smoke script in fixtures/jquery-smoke.js must log only "ok" lines.

private var jsdomTestFonts: FontRegistry? = nil

func jsdomFonts(_ t: Tests) -> TextEngine {
    if let r = jsdomTestFonts { return TextEngine(registry: r) }
    let reg = FontRegistry()
    for b in fontBundled {
        guard let d = t.readFile("rootfs" + b.path) else { continue }
        reg.add(d, family: b.family, generic: b.generic, bold: b.bold, italic: b.italic)
    }
    jsdomTestFonts = reg
    return TextEngine(registry: reg)
}

/// A page whose host has a real LayoutEngine (forced layout works).
final class JSDOMLayoutPage {
    let box = JSDOMTestBox()
    let doc: HTMLNode
    let engine: LayoutEngine
    let page: JSDOMPage

    var deadline = 0

    init(_ t: Tests, _ html: String, width: Int = 800, height: Int = 600, budgetMs: Int = 10_000) {
        doc = htmlParse(html)
        let e = LayoutEngine(document: doc, text: jsdomFonts(t), viewportWidth: width, viewportHeight: height)
        e.update()
        engine = e
        var host = JSDOMHost()
        let b = box
        host.console = { _, text in b.lines.append(text) }
        host.reportError = { msg, _ in b.errors.append(msg) }
        host.now = { b.clock }
        host.layout = { e }
        host.viewport = { (width, height) }
        let budget = JSDOMBudget()
        host.beginTask = { budget.deadline = hostMillis() + budgetMs }
        page = JSDOMPage(document: doc, url: "https://example.test/smoke.html", host: host)
        page.runtime.interruptHandler = { _ in hostMillis() > budget.deadline }
    }

    /// Run the event loop on a virtual clock until idle.
    func settle() {
        var k = 0
        while k < 10_000 {
            k += 1
            page.loop.runDueTasks()
            guard let d = page.loop.nextDeadline() else { break }
            if d > 0 { box.clock += d }
            if box.clock > 60_000 { break }
        }
    }
}

func jsdomJQueryTests(_ t: Tests) {
    t.section("jquery")
    guard let jq = t.readFile("lib/js/fixtures/corpus/jquery-3.7.1.js"),
          let html = t.readFile("lib/js-dom/fixtures/jquery-smoke.html"),
          let smoke = t.readFile("lib/js-dom/fixtures/jquery-smoke.js") else {
        t.check(false, "jquery fixtures")
        return
    }
    let p = JSDOMLayoutPage(t, String(decoding: html, as: UTF8.self))
    let start = hostMillis()
    p.page.runScript(bytes: jq, name: "jquery-3.7.1.js")
    t.check(p.box.errors.isEmpty, "jQuery loads", p.box.errors.first ?? "")
    p.page.runScript(bytes: smoke, name: "jquery-smoke.js")
    p.page.finishParsing()
    p.page.finishLoading()
    p.settle()
    var ok = 0
    var failures: [String] = []
    for l in p.box.lines {
        if l.hasPrefix("ok ") { ok += 1 } else if l != "done" { failures.append(l) }
    }
    for e in p.box.errors { failures.append("error: " + e) }
    t.check(failures.isEmpty, "jQuery smoke: no failures", failures.prefix(12).joined(separator: "\n    "))
    t.check(ok >= 101, "jQuery smoke: " + String(ok) + " checks ok")
    t.check(p.box.lines.contains("done"), "jQuery smoke ran to the end")
    print("jquery smoke: " + String(ok) + " ok, " + String(failures.count) + " failed (" + String(hostMillis() - start) + " ms)")
}

final class JSDOMBudget {
    var deadline = 0
    init() {}
}
