// Host tests for lib/browser: address-bar input, history, forms, the loader
// (memory transport), the HTTP client over scripted streams, and hostile pages.

private var browserTestFonts: FontRegistry? = nil

private func fonts(_ t: Tests) -> TextEngine {
    if let r = browserTestFonts { return TextEngine(registry: r) }
    let reg = FontRegistry()
    for b in fontBundled {
        guard let d = t.readFile("rootfs" + b.path) else { continue }
        reg.add(d, family: b.family, generic: b.generic, bold: b.bold, italic: b.italic)
    }
    browserTestFonts = reg
    return TextEngine(registry: reg)
}

private func strHas(_ s: String, _ sub: String) -> Bool {
    let a = Array(s.utf8), b = Array(sub.utf8)
    if b.isEmpty { return true }
    if a.count < b.count { return false }
    for i in 0...(a.count - b.count) where a[i] == b[0] && Array(a[i..<(i + b.count)]) == b { return true }
    return false
}

private func url(_ s: String) -> URLRecord { URLRecord.parseOrNil(s) ?? URLRecord() }

func libTests(_ t: Tests) {
    inputTests(t)
    historyTests(t)
    formTests(t)
    loaderTests(t)
    httpTests(t)
    hostileTests(t)
}

private func inputTests(_ t: Tests) {
    t.section("address bar")
    t.equal(browserNormalizeInput("example.com") ?? "", "https://example.com/", "bare host gets https")
    t.equal(browserNormalizeInput("  example.com/a b  ") ?? "", browserSearchPrefix + "example.com%2Fa+b", "space: search")
    t.equal(browserNormalizeInput("http://info.cern.ch") ?? "", "http://info.cern.ch/", "scheme kept")
    t.equal(browserNormalizeInput("HTTPS://Example.COM/x") ?? "", "https://example.com/x", "scheme case")
    t.equal(browserNormalizeInput("localhost:8080/p") ?? "", "http://localhost:8080/p", "localhost is http")
    t.equal(browserNormalizeInput("10.0.2.2:8000") ?? "", "http://10.0.2.2:8000/", "IP literal is http")
    t.equal(browserNormalizeInput("/www/index.html") ?? "", "file:///www/index.html", "absolute path is a file")
    t.equal(browserNormalizeInput("file:///www/") ?? "", "file:///www/", "file URL")
    t.equal(browserNormalizeInput("about:home") ?? "", "about:home", "about")
    t.equal(browserNormalizeInput("view-source:http://x.org/") ?? "", "view-source:http://x.org/", "view-source")
    t.equal(browserNormalizeInput("wiffer") ?? "", browserSearchPrefix + "wiffer", "one word: search")
    t.check(browserNormalizeInput("   ") == nil, "blank: nothing")
}

private func historyTests(_ t: Tests) {
    t.section("history")
    var h = BrowserHistory()
    t.check(!h.canGoBack && !h.canGoForward && h.current == nil, "empty")
    h.push(BrowserHistoryEntry(url: "a"))
    h.push(BrowserHistoryEntry(url: "b"))
    h.saveScroll(x: 0, y: 300)
    h.push(BrowserHistoryEntry(url: "c"))
    t.equal(h.back()?.url ?? "", "b", "back")
    t.equal(h.current?.scrollY ?? -1, 300, "scroll kept")
    t.equal(h.back()?.url ?? "", "a", "back again")
    t.check(h.back() == nil && !h.canGoBack, "nothing before the first")
    t.equal(h.forward()?.url ?? "", "b", "forward")
    h.push(BrowserHistoryEntry(url: "d"))
    t.check(!h.canGoForward && h.entries.count == 3 && h.current?.url == "d", "push drops forward entries")
    var big = BrowserHistory()
    big.maxEntries = 5
    for i in 0..<12 { big.push(BrowserHistoryEntry(url: "\(i)")) }
    t.check(big.entries.count == 5 && big.current?.url == "11" && big.entries[0].url == "7", "capped")
}

private let formHTML = """
<form id="f" action="/search" method="get">
<input name="q" value="first">
<input type="hidden" name="h" value="x y">
<input type="password" name="pw">
<input type="checkbox" name="c1" checked>
<input type="checkbox" name="c2" value="yes">
<input type="radio" name="r" value="1" checked><input type="radio" name="r" value="2">
<select name="s"><option value="a">A</option><optgroup label="g"><option>B b</option></optgroup></select>
<textarea name="t">line1
line2</textarea>
<input name="dis" value="no" disabled>
<input type="submit" name="go" value="Go">
<button name="b" value="bv">Button</button>
</form>
<input form="f" name="outside" value="o">
<form id="p" action="post.cgi" method="POST"><input name="a" value="1&2"></form>
"""

private func pairs(_ p: [URLFormPair]) -> String {
    String(decoding: urlFormEncode(p), as: UTF8.self)
}

private func formTests(_ t: Tests) {
    t.section("forms")
    let doc = htmlParse(formHTML)
    guard let f = doc.getElementById("f"), let p = doc.getElementById("p") else { t.check(false, "forms parse"); return }
    let st = BrowserFormState()
    let ins = doc.getElementsByTagName("input")
    t.equal(pairs(browserFormEntries(f, submitter: nil, st)),
            "q=first&h=x+y&pw=&c1=on&r=1&s=a&t=line1%0D%0Aline2&outside=o", "default entries")
    st.values[ObjectIdentifier(ins[0])] = "hello world"
    let c2 = ins[4], r2 = ins[6]
    browserToggle(c2, st)
    browserToggle(ins[3], st)
    browserToggle(r2, st)
    t.check(!browserIsChecked(ins[5], st) && browserIsChecked(r2, st), "radio group: one checked")
    let sel = doc.getElementsByTagName("select")[0]
    t.equal(browserSelectOptions(sel).count, 2, "options in optgroups")
    browserSelectOption(sel, 1, st)
    t.equal(st.values[ObjectIdentifier(sel)] ?? "", "B b", "select shows the label")
    let go = ins[8]
    t.equal(go.attribute("name") ?? "", "go", "submit found")
    let entries = pairs(browserFormEntries(f, submitter: go, st))
    t.equal(entries, "q=hello+world&h=x+y&pw=&c2=yes&r=2&s=B+b&t=line1%0D%0Aline2&go=Go&outside=o", "changed entries + submitter")
    let doc0 = url("http://example.com/dir/page.html?old=1")
    if let req = browserFormSubmission(f, submitter: go, st, documentURL: doc0, base: doc0) {
        t.equal(req.url.href, "http://example.com/search?" + entries, "GET replaces the query")
        t.check(req.method == "GET" && req.body.isEmpty, "GET has no body")
    } else { t.check(false, "GET submission") }
    if let req = browserFormSubmission(p, submitter: nil, st, documentURL: doc0, base: doc0) {
        t.equal(req.url.href, "http://example.com/dir/post.cgi", "POST action")
        t.check(req.method == "POST" && req.contentType == "application/x-www-form-urlencoded", "POST type")
        t.equal(String(decoding: req.body, as: UTF8.self), "a=1%262", "POST body")
    } else { t.check(false, "POST submission") }
    t.check(browserDefaultButton(f) === go, "default button")
    let b = doc.getElementsByTagName("button")[0]
    t.check(pairs(browserFormEntries(f, submitter: b, st)).hasSuffix("&b=bv&outside=o"), "button submitter")
    browserResetForm(f, st)
    t.check(browserIsChecked(ins[5], st) && browserControlValue(ins[0], st) == "first", "reset")
    let lab = htmlParse("<label for=x>L</label><input id=x type=checkbox><label><input type=radio id=y>R</label>")
    let labels = lab.getElementsByTagName("label")
    t.check(browserLabelTarget(labels[0])?.attribute("id") == "x" && browserLabelTarget(labels[1])?.attribute("id") == "y",
            "label targets")
}

// MARK: Loader

private func pump(_ l: BrowserLoader, _ now: inout Int, rounds: Int = 50) {
    for _ in 0..<rounds { l.pump(now: now); now += 10 }
}

private func loaderTests(_ t: Tests) {
    t.section("loader")
    let tx = fonts(t)
    let mem = BrowserMemoryTransport()
    let l = BrowserLoader(text: tx, width: 640, height: 480)
    l.addTransport(mem)
    var log: [String] = []
    l.log = { log.append($0) }
    mem.add("http://t.test/", """
    <!DOCTYPE html><html><head><title>Test page</title><link rel=stylesheet href="s.css"></head>
    <body><div id=box>box</div><img src="i.png"><p id=frag>x</p></body></html>
    """, latency: 0)
    mem.add("http://t.test/s.css", "@import url(imp.css); #box { width: 100px; height: 50px; background: #2040c0 }",
            type: "text/css", latency: 3)
    mem.add("http://t.test/imp.css", "body { margin: 0 } p { background-image: url(bg.png) }", type: "text/css", latency: 2)
    if let png = t.readFile("lib/image/fixtures/pngsuite/basn2c08.png") {
        mem.add("http://t.test/i.png", bytes: png, type: "image/png", latency: 1)
        mem.add("http://t.test/bg.png", bytes: png, type: "image/png", latency: 0)
    }
    var now = 1000
    l.navigate(BrowserRequest(url: url("http://t.test/")), now: now)
    t.check(l.isLoading && l.phase == .document, "document phase")
    l.pump(now: now)
    var c = l.takeChanges()
    t.check(c.newPage && c.title && l.page?.title == "Test page", "document parsed, title")
    t.check(!c.layout, "no layout before the CSS")
    t.check(mem.started.count == 3, "stylesheet and image start at once (\(mem.started.count))")
    pump(l, &now, rounds: 3)
    c = l.takeChanges()
    t.check(!c.layout, "still waiting for the @import")
    pump(l, &now, rounds: 20)
    c = l.takeChanges()
    t.check(c.layout && c.finished && l.phase == .done, "laid out and finished")
    guard let p = l.page else { t.check(false, "page"); return }
    if let box = p.document.getElementById("box"), let r = p.engine.rect(of: box) {
        t.check(r.x == 0 && r.w == 100 && r.h == 50, "both sheets applied (box \(r.x),\(r.w)x\(r.h))")
    } else { t.check(false, "box laid out") }
    t.check(p.images.bitmaps["i.png"]?.width == 32, "image decoded")
    t.check(p.images.bitmaps["http://t.test/bg.png"] != nil, "background image found by layout and fetched",
            p.engine.imageURLs.joined(separator: ",") + " | " + Array(p.images.bitmaps.keys).joined(separator: ",") + " | " + log.joined(separator: "; "))
    t.check(mem.started.contains { $0.request.url.href == "http://t.test/imp.css" }, "@import fetched")
    t.check(l.statusText.hasPrefix("Done"), "status done: " + l.statusText)

    // CSS timeout.
    mem.add("http://t.test/slow.html", "<title>Slow</title><link rel=stylesheet href=never.css><p>x", latency: 0)
    mem.add("http://t.test/never.css", "p{color:red}", type: "text/css", latency: 100_000)
    l.cssTimeout = 500
    l.navigate(BrowserRequest(url: url("http://t.test/slow.html")), now: now)
    l.pump(now: now)
    _ = l.takeChanges()
    l.pump(now: now + 100)
    t.check(!l.takeChanges().layout, "waits for CSS")
    t.check((l.timeout(now: now + 100) ?? -1) == 0 || (l.timeout(now: now + 100) ?? 1000) <= 400, "timeout reported")
    l.pump(now: now + 600)
    c = l.takeChanges()
    t.check(c.layout && l.isLoading, "laid out after the CSS timeout, still loading")
    // Stop cancels the slow sheet.
    let before = mem.cancelled.count
    l.stop(now: now + 700)
    c = l.takeChanges()
    t.check(c.finished && !l.isLoading && mem.cancelled.count == before + 1 && mem.pendingCount == 0, "stop cancels")
    now += 1000

    // Failures and built-in pages.
    l.navigate(BrowserRequest(url: url("http://nowhere.test/")), now: now)
    pump(l, &now, rounds: 3)
    t.check(l.page?.isError == true && l.page?.title == "Server not found", "DNS failure page: " + (l.page?.title ?? ""))
    l.navigate(BrowserRequest(url: url("gopher://x/")), now: now)
    pump(l, &now, rounds: 3)
    t.check(l.page?.title == "Unsupported address", "unsupported scheme")
    l.navigate(BrowserRequest(url: url("about:home")), now: now)
    pump(l, &now, rounds: 3)
    t.check(l.page?.title == "Home" && (l.page?.document.getElementsByTagName("a").count ?? 0) >= 9, "about:home bookmarks")
    l.navigate(BrowserRequest(url: url("about:blank")), now: now)
    pump(l, &now, rounds: 3)
    t.check(l.page?.title == "about:blank" && l.phase == .done, "about:blank")
    l.navigate(BrowserRequest(url: url("http://t.test/")), now: now, viewSource: true)
    pump(l, &now, rounds: 5)
    t.check(l.page?.displayURL == "view-source:http://t.test/" && strHas(l.page?.document.textContent ?? "", "<title>Test page"),
            "view-source shows the markup")
    mem.add("http://t.test/plain.txt", "a < b", type: "text/plain")
    l.navigate(BrowserRequest(url: url("http://t.test/plain.txt")), now: now)
    pump(l, &now, rounds: 3)
    t.check(l.page?.document.getElementsByTagName("pre").first?.textContent == "a < b", "text/plain in a pre")
    mem.add("http://t.test/e404", "", status: 404)
    l.navigate(BrowserRequest(url: url("http://t.test/e404")), now: now)
    pump(l, &now, rounds: 3)
    t.check(l.page?.title == "HTTP 404" && l.page?.isError == true, "empty 404: error page")
    if let png = t.readFile("lib/image/fixtures/pngsuite/basn2c08.png") {
        mem.add("http://t.test/pic.png", bytes: png, type: "image/png")
        let n0 = mem.started.count
        l.navigate(BrowserRequest(url: url("http://t.test/pic.png")), now: now)
        pump(l, &now, rounds: 3)
        t.check(l.page?.images.bitmaps["http://t.test/pic.png"] != nil && mem.started.count == n0 + 1, "image document, fetched once")
    }
    // windows-1252
    mem.add("http://t.test/latin", bytes: [0x3c, 0x74, 0x69, 0x74, 0x6c, 0x65, 0x3e, 0xe9, 0x3c, 0x2f, 0x74, 0x69, 0x74, 0x6c, 0x65, 0x3e],
            type: "text/html; charset=windows-1252")
    l.navigate(BrowserRequest(url: url("http://t.test/latin")), now: now)
    pump(l, &now, rounds: 3)
    t.equal(l.page?.title ?? "", "\u{e9}", "charset from Content-Type")
    t.check(log.contains { $0.hasPrefix("done ") }, "log lines")
}

// MARK: HTTP over scripted streams

private final class ScriptServer {
    /// (request text) -> raw response; nil: close without answering.
    var respond: (String) -> [UInt8]? = { _ in nil }
    var requests: [String] = []
    var opened = 0
    var refuse = false
    var closeAfterResponse = false
    var hold = false
}

private final class ScriptStream: BrowserStream {
    let server: ScriptServer
    var buf: [UInt8] = []
    var inbox: [UInt8] = []
    var st = BrowserStreamState.connecting
    var closeWhenDrained = false

    init(_ s: ScriptServer) {
        server = s
        super.init()
        s.opened += 1
        if s.refuse { st = .failed(.connectionRefused("test")) }
    }

    override var state: BrowserStreamState { st }
    override func send(_ bytes: [UInt8]) { buf += bytes }
    override func receive() -> [UInt8] {
        let d = inbox
        inbox = []
        if closeWhenDrained && st == .open { st = .closed }
        return d
    }
    override func close() { if st == .open || st == .connecting { st = .closed } }

    override func pump(now: Int) {
        if st == .connecting { st = .open }
        guard st == .open, !server.hold else { return }
        // One complete request (headers + Content-Length body) at a time.
        while let end = find(buf, [13, 10, 13, 10]) {
            let head = String(decoding: buf[0..<end], as: UTF8.self)
            var len = 0
            for line in head.split(separator: "\r\n") where String(line).hasPrefix("Content-Length:") {
                len = Int(line.dropFirst(15).trimmingCharacters()) ?? 0
            }
            guard buf.count >= end + 4 + len else { return }
            let req = String(decoding: buf[0..<(end + 4 + len)], as: UTF8.self)
            buf.removeFirst(end + 4 + len)
            server.requests.append(req)
            if let r = server.respond(req) {
                inbox += r
                if server.closeAfterResponse { closeWhenDrained = true }
            } else { st = .closed }
        }
    }

    private func find(_ h: [UInt8], _ n: [UInt8]) -> Int? {
        if h.count < n.count { return nil }
        for i in 0...(h.count - n.count) where Array(h[i..<(i + n.count)]) == n { return i }
        return nil
    }
}

extension Substring {
    fileprivate func trimmingCharacters() -> String {
        var s = String(self)
        while s.hasPrefix(" ") { s.removeFirst() }
        while s.hasSuffix(" ") { s.removeLast() }
        return s
    }
}

private func resp(_ status: Int, _ headers: [String], _ body: [UInt8]) -> [UInt8] {
    var s = "HTTP/1.1 \(status) X\r\n"
    for h in headers { s += h + "\r\n" }
    s += "Content-Length: \(body.count)\r\n\r\n"
    return Array(s.utf8) + body
}

private func run(_ h: BrowserHTTPTransport, _ id: Int, _ r: BrowserRequest, rounds: Int = 20) -> BrowserTransportEvent? {
    h.start(id, r, now: 0)
    for i in 0..<rounds {
        h.poll(now: i)
        for e in h.events {
            switch e {
            case .done(let eid, _) where eid == id: h.events = []; return e
            case .failed(let eid, _) where eid == id: h.events = []; return e
            default: break
            }
        }
        h.events = []
    }
    return nil
}

private func doneBody(_ e: BrowserTransportEvent?) -> (BrowserResponse?, BrowserLoadError?) {
    switch e {
    case .done(_, let r): return (r, nil)
    case .failed(_, let err): return (nil, err)
    default: return (nil, nil)
    }
}

private func httpTests(_ t: Tests) {
    t.section("http client")
    let srv = ScriptServer()
    let h = BrowserHTTPTransport()
    var tlsAsked = false
    h.openStream = { _, port, tls, _ in tlsAsked = tlsAsked || tls; _ = port; return ScriptStream(srv) }
    h.unixTime = { 1_700_000_000 }
    let gz = unhex("1f8b08000000000000ffb329c92cc949b54bafb2d187b06c0a809ccc8282d41485a4fc944a1bfd023b00c505682224000000")
    srv.respond = { req in
        if req.hasPrefix("GET /redir ") { return resp(302, ["Location: /final"], []) }
        if req.hasPrefix("GET /final ") { return resp(200, ["Content-Type: text/html", "Set-Cookie: sid=42; Path=/"], Array("final".utf8)) }
        if req.hasPrefix("GET /gz ") { return resp(200, ["Content-Encoding: gzip"], gz) }
        if req.hasPrefix("GET /chunked ") {
            return Array("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n".utf8)
        }
        if req.hasPrefix("GET /cached ") {
            if strHas(req, "If-None-Match: \"v1\"") { return Array("HTTP/1.1 304 Not Modified\r\nETag: \"v1\"\r\n\r\n".utf8) }
            return resp(200, ["ETag: \"v1\"", "Cache-Control: no-cache"], Array("cached body".utf8))
        }
        if req.hasPrefix("GET /fresh ") { return resp(200, ["Cache-Control: max-age=600"], Array("fresh".utf8)) }
        if req.hasPrefix("POST /form ") { return resp(200, [], Array((req.split(separator: "\r\n").last.map { String($0) } ?? "").utf8)) }
        if req.hasPrefix("GET /loop") { return resp(301, ["Location: /loop"], []) }
        if req.hasPrefix("GET /garbage ") { return Array("SMTP ready\r\n\r\n".utf8) }
        return resp(404, [], Array("nope".utf8))
    }
    var (r, e) = doneBody(run(h, 1, BrowserRequest(url: url("http://h.test/redir"))))
    t.check(r?.url.href == "http://h.test/final" && r.map { browserText($0.body) } == "final" && e == nil, "redirect followed")
    t.check(srv.opened == 1 && srv.requests.count == 2, "keep-alive: one connection for both (\(srv.opened))")
    (r, _) = doneBody(run(h, 2, BrowserRequest(url: url("http://h.test/gz"))))
    t.equal(r.map { browserText($0.body) } ?? "", "<title>gz</title><p>gzipped body</p>", "gzip decoded")
    (r, _) = doneBody(run(h, 3, BrowserRequest(url: url("http://h.test/chunked"))))
    t.equal(r.map { browserText($0.body) } ?? "", "abcde", "chunked")
    t.check(strHas(srv.requests.last ?? "", "Cookie: sid=42"), "cookie sent back")
    (r, _) = doneBody(run(h, 4, BrowserRequest(url: url("http://h.test/cached"))))
    (r, _) = doneBody(run(h, 5, BrowserRequest(url: url("http://h.test/cached"))))
    t.check(r.map { browserText($0.body) } == "cached body" && r?.status == 200 && strHas(srv.requests.last ?? "", "If-None-Match"),
            "304 revalidation serves the cached body")
    _ = run(h, 6, BrowserRequest(url: url("http://h.test/fresh")))
    let n = srv.requests.count
    (r, _) = doneBody(run(h, 7, BrowserRequest(url: url("http://h.test/fresh"))))
    t.check(r.map { browserText($0.body) } == "fresh" && srv.requests.count == n, "fresh entry: no request")
    var post = BrowserRequest(url: url("http://h.test/form"))
    post.method = "POST"
    post.body = Array("a=1&b=2".utf8)
    post.contentType = "application/x-www-form-urlencoded"
    (r, _) = doneBody(run(h, 8, post))
    t.equal(r.map { browserText($0.body) } ?? "", "a=1&b=2", "POST body sent")
    t.check(strHas(srv.requests.last ?? "", "Content-Type: application/x-www-form-urlencoded"), "POST content type")
    (r, e) = doneBody(run(h, 9, BrowserRequest(url: url("http://h.test/loop")), rounds: 40))
    t.check(e == .tooManyRedirects, "redirect loop stops")
    (r, e) = doneBody(run(h, 10, BrowserRequest(url: url("http://h.test/garbage"))))
    t.check(e != nil && r == nil, "non-HTTP reply is an error")
    (r, _) = doneBody(run(h, 11, BrowserRequest(url: url("http://h.test/missing"))))
    t.check(r?.status == 404 && r.map { browserText($0.body) } == "nope", "404 delivered with its body")
    // A stale keep-alive connection closed by the server is retried.
    srv.closeAfterResponse = true
    (r, _) = doneBody(run(h, 12, BrowserRequest(url: url("http://h.test/final"))))
    (r, e) = doneBody(run(h, 13, BrowserRequest(url: url("http://h.test/final"))))
    t.check(r != nil && e == nil, "retry after the server closed an idle connection")
    srv.closeAfterResponse = false
    // Refused.
    srv.refuse = true
    (r, e) = doneBody(run(h, 14, BrowserRequest(url: url("http://other.test/"))))
    t.check(e == .connectionRefused("test"), "connection refused")
    srv.refuse = false
    // Six connections per host.
    srv.hold = true
    let opened0 = srv.opened
    for i in 0..<10 {
        var q = BrowserRequest(url: url("http://many.test/img\(i)"))
        q.kind = .image
        h.start(100 + i, q, now: 0)
    }
    h.poll(now: 1)
    t.equal(srv.opened - opened0, 6, "at most 6 connections per host")
    srv.hold = false
    var done = 0
    for i in 0..<40 {
        h.poll(now: 2 + i)
        for ev in h.events { if case .done = ev { done += 1 } }
        h.events = []
    }
    t.equal(done, 10, "all 10 finish over the 6")
    t.check(strHas(srv.requests.last ?? "", "Accept: image/"), "image Accept header")
    // Timeout.
    srv.hold = true
    h.responseTimeout = 100
    h.connectTimeout = 100
    h.start(200, BrowserRequest(url: url("http://slow.test/")), now: 0)
    h.poll(now: 50)
    h.poll(now: 150)
    var timedOut = false
    for ev in h.events { if case .failed(200, .timedOut) = ev { timedOut = true } }
    h.events = []
    t.check(timedOut, "response timeout")
    // Cancel.
    h.start(201, BrowserRequest(url: url("http://slow.test/")), now: 1000)
    h.poll(now: 1001)
    h.cancel(201)
    h.poll(now: 5000)
    t.check(h.events.isEmpty, "cancelled: no events")
    srv.hold = false
    t.check(!tlsAsked, "http does not ask for TLS")
    _ = run(h, 300, BrowserRequest(url: url("https://secure.test/final")))
    t.check(tlsAsked, "https asks for TLS")

    // Loader + HTTP transport together.
    let l = BrowserLoader(text: fonts(t), width: 400, height: 300)
    l.addTransport(h)
    var now = 0
    l.navigate(BrowserRequest(url: url("http://h.test/redir")), now: now)
    pump(l, &now, rounds: 10)
    t.check(l.page?.url.href == "http://h.test/final" && l.phase == .done, "loader over HTTP with a redirect")
}

// MARK: Hostile input

private func hostileTests(_ t: Tests) {
    t.section("hostile pages")
    let mem = BrowserMemoryTransport()
    let l = BrowserLoader(text: fonts(t), width: 500, height: 400)
    l.addTransport(mem)
    var rng = TestRandom(seed: 8)
    var junk: [UInt8] = []
    for _ in 0..<100_000 { junk.append(UInt8(truncatingIfNeeded: rng.next())) }
    mem.add("http://x.test/junk", bytes: junk, type: "text/html")
    var deep = ""
    for _ in 0..<5000 { deep += "<div><span><table><tr><td>" }
    mem.add("http://x.test/deep", deep + "deep")
    var imgs = "<title>imgs</title>"
    for i in 0..<20 { imgs += "<img src=\"bad\(i).png\" width=10>" }
    for i in 0..<20 { mem.add("http://x.test/bad\(i).png", bytes: Array(junk[(i * 100)..<(i * 100 + 300)]), type: "image/png") }
    mem.add("http://x.test/imgs", imgs)
    mem.add("http://x.test/badcss", "<link rel=stylesheet href=b.css><p>x")
    mem.add("http://x.test/b.css", bytes: junk, type: "text/css")
    var now = 0
    for u in ["http://x.test/junk", "http://x.test/deep", "http://x.test/imgs", "http://x.test/badcss"] {
        l.navigate(BrowserRequest(url: url(u)), now: now)
        pump(l, &now, rounds: 40)
        t.check(l.page != nil && l.phase == .done, "survives " + u)
    }
    // Whole-loader fuzz (ROADMAP 8I): mutated documents, stylesheets and
    // images go through fetch, decode, parse, style, layout and paint.
    t.section("fuzz")
    let page = Array("<!DOCTYPE html><title>F</title><link rel=stylesheet href=s.css><style>p{color:red}</style><body><div id=box>box</div><img src=i.png width=20><table><tr><td>a<td>b</table><form><input name=q value=x><select><option>1</select></form><a href=#box>l</a>".utf8)
    let css = Array("@import url(imp.css); #box{width:100px;height:50px;background:#2040c0;float:left} p{margin:1em;display:flex} td{border:1px solid} a:hover{color:blue}".utf8)
    let png = t.readFileIfPresent("lib/image/fixtures/pngsuite/basn2c08.png") ?? []
    let tx = fonts(t)
    var buf = [UInt32](repeating: 0, count: 100 * 80)
    var n = 0
    t.fuzz("loader", seeds: [page, css] + (png.isEmpty ? [] : [png]), iterations: 600) { data in
        n += 1
        let mem = BrowserMemoryTransport()
        let l = BrowserLoader(text: tx, width: 300, height: 200)
        l.addTransport(mem)
        // Rotate which resource is the mutant.
        mem.add("http://f.test/", bytes: n % 3 == 0 ? data : page, type: "text/html")
        mem.add("http://f.test/s.css", bytes: n % 3 == 1 ? data : css, type: "text/css")
        mem.add("http://f.test/imp.css", bytes: n % 3 == 1 ? Array(data.reversed()) : css, type: "text/css")
        mem.add("http://f.test/i.png", bytes: n % 3 == 2 ? data : png, type: "image/png")
        var now = 0
        l.navigate(BrowserRequest(url: url("http://f.test/")), now: now)
        pump(l, &now, rounds: 30)
        _ = l.takeChanges()
        if let e = l.page?.engine {
            buf.withUnsafeMutableBufferPointer { p in e.paint(into: p.baseAddress!, stride: 100, width: 100, height: 80, scrollY: 0) }
        }
    }
}
