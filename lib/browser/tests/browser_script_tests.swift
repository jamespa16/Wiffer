// Host tests for scripts in the loader (Phase 9H): execution order, async,
// modules, nomodule / unknown types, <noscript>, events, script-inserted
// scripts, fetch through the loader's transports, the time budget, errors.

private func scriptFonts(_ t: Tests) -> TextEngine {
    let reg = FontRegistry()
    for b in fontBundled {
        guard let d = t.readFile("rootfs" + b.path) else { continue }
        reg.add(d, family: b.family, generic: b.generic, bold: b.bold, italic: b.italic)
    }
    return TextEngine(registry: reg)
}

private func scriptURL(_ s: String) -> URLRecord { URLRecord.parseOrNil(s) ?? URLRecord() }

final class BrowserScriptTestRig {
    let mem = BrowserMemoryTransport()
    let loader: BrowserLoader
    var log: [String] = []
    var console: [String] = []
    var now = 1000
    var navigations: [String] = []

    init(_ tx: TextEngine) {
        loader = BrowserLoader(text: tx, width: 640, height: 480)
        loader.addTransport(mem)
        loader.scriptsEnabled = true
        loader.cssTimeout = 500
        loader.clock = { [unowned self] in self.now }
        loader.log = { [unowned self] s in self.log.append(s) }
        loader.scriptHooks.console = { [unowned self] _, s in self.console.append(s) }
        loader.scriptHooks.navigate = { [unowned self] u, _ in self.navigations.append(u) }
    }

    /// Navigate and pump until the load finishes (or `rounds` run out).
    func load(_ url: String, rounds: Int = 200) {
        log = []
        console = []
        loader.navigate(BrowserRequest(url: scriptURL(url)), now: now)
        settle(rounds: rounds)
    }

    func settle(rounds: Int = 200) {
        var n = 0
        while n < rounds {
            loader.pump(now: now)
            _ = loader.takeChanges()
            n += 1
            if loader.phase == .done && mem.pendingCount == 0 {
                if let d = loader.timeout(now: now), d > 0, d <= 20 { now += d; continue }
                if loader.timeout(now: now) == 0 { continue }
                break
            }
            now += 10
        }
    }

    func has(_ prefix: String) -> Bool { log.contains { $0.hasPrefix(prefix) } }
    var consoleText: String { console.joined(separator: ",") }
}

func browserScriptTests(_ t: Tests) {
    t.section("scripts")
    let tx = scriptFonts(t)
    let r = BrowserScriptTestRig(tx)
    r.mem.add("http://s.test/", """
    <!DOCTYPE html><title>Before</title><link rel=stylesheet href=s.css>
    <script>console.log('inline1 ' + document.readyState + ' ' + (document.getElementById('late') ? 'parsed' : 'not parsed'))</script>
    <script src=a.js></script>
    <script async src=async.js></script>
    <script defer src=d.js></script>
    <script type=module>import {v} from './m1.js'; console.log('module ' + v)</script>
    <script nomodule>console.log('nomodule ran')</script>
    <script type=text/template>console.log('template ran')</script>
    <script type="text/javascript; charset=utf-8">console.log('typed')</script>
    <noscript><p id=ns>no script</p></noscript>
    <div id=box style="width: 10px; height: 10px"></div>
    <p id=late>late</p>
    <script>
    document.addEventListener('DOMContentLoaded', () => console.log('DCL'));
    window.addEventListener('load', () => console.log('load ' + document.readyState));
    console.log('width ' + document.getElementById('box').getBoundingClientRect().width);
    document.title = 'After';
    </script>
    """)
    r.mem.add("http://s.test/s.css", "#box { width: 50px !important }", type: "text/css", latency: 3)
    r.mem.add("http://s.test/a.js", "console.log('a.js')", type: "text/javascript", latency: 5)
    r.mem.add("http://s.test/async.js", "console.log('async')", type: "text/javascript", latency: 0)
    r.mem.add("http://s.test/d.js", "console.log('defer')", type: "application/javascript", latency: 1)
    r.mem.add("http://s.test/m1.js", "import {w} from '/m2.js'; export const v = 'v' + w;", type: "text/javascript", latency: 2)
    r.mem.add("http://s.test/m2.js", "export const w = 2;", type: "text/javascript", latency: 2)
    r.load("http://s.test/")
    let order = r.console
    t.check(order.first == "async" || order.first == "inline1 loading parsed", "async may run first", r.consoleText)
    let sync = order.filter { $0 != "async" }
    t.equal(sync.joined(separator: ","), "inline1 loading parsed,a.js,defer,module v2,typed,width 50,DCL,load complete",
            "document order as if deferred, after the CSS; module graph; nomodule and templates skipped")
    t.check(r.has("script http://s.test/a.js "), "script lines", r.log.joined(separator: "; "))
    t.check(r.has("event DOMContentLoaded ") && r.has("event load "), "event lines")
    t.equal(r.loader.page?.title ?? "", "After", "document.title set by a script")
    if let ns = r.loader.page?.document.getElementById("ns") { t.check(false, "noscript parsed as markup: \(ns.name)") }
    else { t.check(true, "noscript content is raw text") }
    let lines = r.log
    let li = lines.firstIndex { $0.hasPrefix("event load") } ?? -1
    let di = lines.firstIndex { $0.hasPrefix("done ") } ?? -1
    t.check(li >= 0 && di > li, "load fires before the done line")

    // Errors are logged and counted, never fatal.
    r.mem.add("http://s.test/err.html", """
    <title>Err</title><script>
    function f() { null.x }
    f()
    </script><script>console.log('still runs')</script><script>syntax error here(</script>
    <script src=missing.js onerror="console.log('onerror fired')"></script>
    """)
    r.load("http://s.test/err.html")
    t.equal(r.consoleText, "still runs,onerror fired", "errors do not stop later scripts")
    t.check(r.loader.scriptErrors == 2, "two script errors counted (\(r.loader.scriptErrors))")
    t.check(r.log.contains { $0.hasPrefix("js error http://s.test/err.html:2: TypeError") }, "js error line with url:line",
            r.log.filter { $0.hasPrefix("js") }.joined(separator: "; "))
    t.check(r.loader.statusText.hasSuffix("2 script errors"), "status line counts errors: " + r.loader.statusText)

    // Script-inserted scripts, a class toggle (incremental restyle), fetch.
    r.mem.add("http://s.test/dyn.html", """
    <title>Dyn</title><style>.on { color: red }</style><div id=t>x</div><script>
    const s = document.createElement('script'); s.src = 'ins.js'; document.head.appendChild(s);
    const i = document.createElement('script'); i.textContent = "console.log('inline inserted')"; document.body.appendChild(i);
    document.body.insertAdjacentHTML('beforeend', '<script>console.log("innerHTML ran")<' + '/script>');
    document.write('<script>console.log("written")<' + '/script>');
    fetch('/data.json').then(r => r.json()).then(j => console.log('fetched ' + j.n));
    window.addEventListener('load', () => setTimeout(() => { document.getElementById('t').className = 'on' }, 5));
    setTimeout(() => console.log('timer'), 0);
    </script>
    """)
    r.mem.add("http://s.test/ins.js", "console.log('inserted src')", type: "text/javascript", latency: 2)
    r.mem.add("http://s.test/data.json", "{\"n\": 5}", type: "application/json", latency: 1)
    r.load("http://s.test/dyn.html")
    let c = r.console
    t.check(c.contains("inline inserted") && c.contains("inserted src") && c.contains("written") && !c.contains("innerHTML ran"),
            "inserted scripts run (not innerHTML ones)", r.consoleText)
    t.check(c.contains("fetched 5") && c.contains("timer"), "fetch through the loader, timers", r.consoleText)
    t.check(r.has("restyle "), "class toggle restyles in a rendering step", r.log.joined(separator: "; "))
    if let p = r.loader.page, let el = p.document.getElementById("t"), let st = p.engine.computedStyle(of: el) {
        t.check(st.color.r == 255 && st.color.g == 0, "the new class applies")
    } else { t.check(false, "computed style") }

    // A class toggle repaints with the new background.
    r.mem.add("http://s.test/tog.html", "<style>body{margin:0} #b{width:50px;height:20px;background:#2040C0} #b.on{background:#C04020}</style><div id=b></div>")
    r.load("http://s.test/tog.html")
    func px() -> UInt32 {
        var buf = [UInt32](repeating: 0, count: 100 * 40)
        if let e = r.loader.page?.engine {
            buf.withUnsafeMutableBufferPointer { p in e.paint(into: p.baseAddress!, stride: 100, width: 100, height: 40, scrollY: 0) }
        }
        return buf[10 * 100 + 10] & 0xFFFFFF
    }
    t.check(px() == 0x2040C0, "toggle: before (\(px()))")
    r.loader.page?.scripts?.page.runScript("document.getElementById('b').classList.toggle('on')")
    r.settle(rounds: 20)
    t.check(px() == 0xC04020, "toggle: after the rendering step (\(px()))")

    // Cross-origin fetch fails; same-origin XHR works.
    r.mem.add("http://s.test/cors.html", """
    <title>Cors</title><script>
    fetch('http://other.test/x').then(() => console.log('leaked')).catch(e => console.log('blocked ' + e.name));
    const x = new XMLHttpRequest(); x.open('GET', '/data.json'); x.onload = () => console.log('xhr ' + x.status); x.send();
    </script>
    """)
    r.mem.add("http://other.test/x", "secret", type: "text/plain")
    r.load("http://s.test/cors.html")
    t.check(r.console.contains("blocked TypeError") && r.console.contains("xhr 200"), "CORS block and XHR", r.consoleText)
    t.check(r.console.contains { $0.hasPrefix("Access to fetch at 'http://other.test/x'") }, "CORS console message")

    // The time budget: an endless loop is stopped, the page stays usable.
    r.loader.scriptBudgetMs = 200
    var hungCalls = 0
    r.loader.scriptHooks.hung = { _ in hungCalls += 1; return hungCalls < 3 ? .keepRunning : .stop }
    r.mem.add("http://s.test/loop.html", "<title>Loop</title><script>console.log('start'); while (true) {}</script><script>console.log('after')</script>")
    let saved = r.loader.clock
    var ticks = 0
    r.loader.clock = { ticks += 1; return r.now + ticks }
    r.load("http://s.test/loop.html")
    r.loader.clock = saved
    t.check(r.has("js budget exceeded http://s.test/loop.html"), "budget exceeded line", r.log.joined(separator: "; "))
    t.check(hungCalls >= 3 && r.loader.page?.scripts?.stopped == true, "Stop terminates and switches scripts off")
    t.check(!r.console.contains("after"), "no scripts after Stop")
    t.check(r.loader.phase == .done && r.has("done "), "the page still finishes loading")
    t.check(r.loader.statusText.split(separator: "|").contains { $0 == " script stopped " || $0 == " script stopped" },
            "status: " + r.loader.statusText)

    // Wait extends the budget: the script finishes.
    r.loader.scriptHooks.hung = { _ in .wait }
    r.mem.add("http://s.test/slow.html", "<title>Slow</title><script>let k = 0; for (let i = 0; i < 300000; i++) k += i; console.log('slow done')</script>")
    ticks = 0
    r.loader.clock = { ticks += 1; return r.now + ticks }
    r.load("http://s.test/slow.html")
    r.loader.clock = saved
    t.check(r.console.contains("slow done"), "Wait lets the script finish", r.consoleText)
    r.loader.scriptBudgetMs = 5000

    // location assignment goes to the browser's navigate hook.
    r.mem.add("http://s.test/nav.html", "<title>Nav</title><script>location.href = 'other.html'</script>")
    r.load("http://s.test/nav.html")
    t.equal(r.navigations.last ?? "", "http://s.test/other.html", "location.href = ... navigates")

    // Scripts off: Part 8 behavior (noscript shown, no script runs).
    r.loader.scriptsEnabled = false
    r.load("http://s.test/")
    t.check(r.console.isEmpty && r.loader.page?.document.getElementById("ns") != nil && r.loader.page?.title == "Before",
            "--nojs: nothing runs, <noscript> is markup")
    r.loader.scriptsEnabled = true

    // Error locations from stacks.
    t.equal(browserErrorLocation("TypeError: x\n    at f (http://a/b.js:12:5)\n    at http://a/b.js:20:1", fallback: "u"),
            "http://a/b.js:12", "stack location with a function name")
    t.equal(browserErrorLocation("SyntaxError: bad", fallback: "http://a/"), "http://a/:0", "no stack")
}
