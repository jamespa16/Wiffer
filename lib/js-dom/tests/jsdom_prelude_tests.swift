// Tests for jsdom_prelude.swift (9J): IntersectionObserver, ResizeObserver,
// PerformanceObserver and HTMLDocument on a page with a real layout engine.

func jsdomPreludeTests(_ t: Tests) {
    t.section("prelude observers")
    let p = JSDOMLayoutPage(t, """
        <!DOCTYPE html><style>body { margin: 0 } #a { height: 100px } #gap { height: 2000px } #b { height: 50px; width: 200px }</style>
        <body><div id=a></div><div id=gap></div><div id=b></div></body>
        """, width: 800, height: 600)
    func run(_ s: String) -> String {
        p.box.lines = []
        p.box.errors = []
        p.page.runScript(s, name: "prelude-test.js")
        p.settle()
        var out = p.box.lines
        for e in p.box.errors { out.append("ERR: " + e) }
        var r = ""
        for (i, l) in out.enumerated() { if i > 0 { r += "\n" }; r += l }
        return r
    }
    t.equal(run("""
        var seen = [];
        var io = new IntersectionObserver(function (es, o) {
          es.forEach(function (e) { seen.push(e.target.id + ':' + e.isIntersecting + ':' + e.intersectionRatio); });
          console.log(seen.join(' ') + ' ' + (o === io));
        }, { threshold: [0, 1] });
        io.observe(document.getElementById('a'));
        io.observe(document.getElementById('b'));
        """), "a:true:1 b:false:0 true", "IntersectionObserver: in view and out of view")
    t.equal(run("""
        document.getElementById('gap').style.height = '10px';
        window.dispatchEvent(new Event('resize'));
        """), "a:true:1 b:false:0 b:true:1 true", "IntersectionObserver: a change after a resize")
    t.equal(run("""
        var ro = new ResizeObserver(function (es) { console.log(es.map(function (e) { return e.contentRect.width + 'x' + e.contentRect.height; }).join(' ')); });
        ro.observe(document.getElementById('b'));
        """), "200x50", "ResizeObserver: the first size")
    t.equal(run("""
        document.getElementById('b').style.width = '300px';
        window.dispatchEvent(new Event('resize'));
        """), "300x50", "ResizeObserver: a new size")
    t.equal(run("""
        var po = new PerformanceObserver(function () { console.log('never'); });
        po.observe({ entryTypes: ['longtask'] });
        console.log(Array.isArray(PerformanceObserver.supportedEntryTypes), document instanceof HTMLDocument,
                    typeof IntersectionObserver.prototype.observe, Object.keys(window).indexOf('IntersectionObserver'));
        try { IntersectionObserver(function () {}) } catch (e) { console.log(e.name) }
        try { new IntersectionObserver(function () {}, { threshold: 2 }) } catch (e) { console.log(e.name) }
        """), "true true function -1\nTypeError\nRangeError", "PerformanceObserver, HTMLDocument, errors")
    t.equal(run("""
        navigator.serviceWorker.getRegistrations().then(function (r) { console.log('sw ' + r.length + ' ' + ('serviceWorker' in navigator)); });
        navigator.serviceWorker.register('/sw.js').catch(function (e) { console.log(e.name); });
        """), "sw 0 true\nNotSupportedError", "navigator.serviceWorker: no registrations, register() rejects")
    t.equal(run("""
        navigator.clipboard.writeText('copied').then(function () { return navigator.clipboard.readText(); })
          .then(function (s) { console.log(s + ' ' + typeof navigator.clipboard.read); });
        """), "copied function", "navigator.clipboard: a page-local clipboard")
    p.page.tearDown()
}
