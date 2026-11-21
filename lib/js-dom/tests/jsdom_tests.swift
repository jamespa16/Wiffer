// Host tests for lib/js-dom (ROADMAP Phase 9G): the generator is up to
// date, core DOM / events / window behavior, the vendored WPT subset with a
// pass-count floor, jQuery smoke tests and a DOM fuzz.

func libTests(_ t: Tests) {
    // WIFFER_JSDOM_ONLY=core|jquery|fuzz|wpt runs one group.
    let only = jsdomEnv("WIFFER_JSDOM_ONLY")
    func run(_ name: String, _ f: (Tests) -> Void) { if only == nil || only == name { f(t) } }
    run("generator", jsdomGeneratorTests)
    run("core", jsdomCoreTests)
    run("core", jsdomCore2Tests)
    run("ce", jsdomCETests)
    run("ce", jsdomLitTests)
    run("ce", jsdomVueTests)
    run("core", jsdomPreludeTests)
    run("jquery", jsdomJQueryTests)
    run("fuzz", jsdomFuzzTests)
    run("bench", jsdomBenchTests)
    run("wpt", jsdomWPTTests)
}

/// A page over `html` that collects console output.
final class JSDOMTestPage {
    var lines: [String] = []
    var errors: [String] = []
    var clock = 0.0
    let page: JSDOMPage

    init(_ html: String, url: String = "https://example.test/dir/page.html", layout: LayoutEngine? = nil,
         configure: ((inout JSDOMHost) -> Void)? = nil) {
        let doc = htmlParse(html)
        var host = JSDOMHost()
        let box = JSDOMTestBox()
        host.console = { _, text in box.lines.append(text) }
        host.reportError = { msg, _ in box.errors.append(msg) }
        host.now = { box.clock }
        host.wallClock = { 1_700_000_000_000 + box.clock }
        if let l = layout { host.layout = { l } }
        configure?(&host)
        page = JSDOMPage(document: doc, url: url, host: host)
        self.box = box
        // WIFFER_JSDOM_GCSTRESS=1: collect at every allocation.
        if jsdomEnv("WIFFER_JSDOM_GCSTRESS") != nil { page.realm.heap.gcEveryAllocation = true }
    }
    let box: JSDOMTestBox

    /// Run a script; returns console lines produced (joined with "\n") plus
    /// uncaught errors as "ERR: ...".
    func run(_ src: String) -> String {
        box.lines = []
        box.errors = []
        page.runScript(src, name: "test.js")
        page.loop.runDueTasks()
        var out = box.lines
        for e in box.errors { out.append("ERR: " + e) }
        var s = ""
        for (i, l) in out.enumerated() { if i > 0 { s += "\n" }; s += l }
        return s
    }
}

final class JSDOMTestBox {
    var lines: [String] = []
    var errors: [String] = []
    var clock = 0.0
    init() {}
}

func jsdomGeneratorTests(_ t: Tests) {
    t.section("generator")
    let rc = host_system("python3 lib/js-dom/tools/gen_bindings.py --check")
    t.check(rc == 0, "jsdom_generated.swift is up to date (run lib/js-dom/tools/gen_bindings.py)")
}

func jsdomCoreTests(_ t: Tests) {
    t.section("core")
    let p = JSDOMTestPage("<!DOCTYPE html><html><head><title>T</title></head><body><div id=a class='x y'>hi<span>there</span></div></body></html>")
    t.equal(p.run("console.log(document.title)"), "T", "document.title")
    t.equal(p.run("console.log(document.getElementById('a').textContent)"), "hithere", "textContent")
    t.equal(p.run("var d = document.getElementById('a'); console.log(d.tagName, d.className, d.classList.length, d.firstChild.data)"),
            "DIV x y 2 hi", "element basics")
    t.equal(p.run("console.log(document.querySelector('div > span').textContent, document.querySelectorAll('*').length)"),
            "there 6", "querySelector")
    t.equal(p.run("var s = document.createElement('p'); s.textContent = 'new'; document.body.appendChild(s); console.log(document.body.innerHTML)"),
            "<div id=\"a\" class=\"x y\">hi<span>there</span></div><p>new</p>", "appendChild + innerHTML")
    t.equal(p.run("var n = 0; document.body.addEventListener('click', function(e) { n++; console.log(e.type, e.target.tagName, e.eventPhase) }); document.querySelector('span').click(); console.log(n)"),
            "click SPAN 3\n1", "click bubbles")
    t.equal(p.run("console.log(document.getElementById('a') === document.getElementById('a'), document.body instanceof HTMLBodyElement, document.body instanceof Node)"),
            "true true true", "wrapper identity and prototypes")
    t.equal(p.run("try { document.body.appendChild(document) } catch (e) { console.log(e.name, e.code, e instanceof DOMException) }"),
            "HierarchyRequestError 3 true", "DOMException")
    t.equal(p.run("Promise.resolve().then(() => console.log('micro')); setTimeout(() => console.log('timer'), 0); console.log('sync')"),
            "sync\nmicro\ntimer", "event loop")
}
