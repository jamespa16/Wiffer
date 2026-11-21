// Host tests for lib/js-web: URL / URLSearchParams, TextEncoder /
// TextDecoder, Blob / FormData, Headers, fetch and XMLHttpRequest over a
// fake network, with the same-origin and CORS cases.

final class JSWebTestNet {
    var handler: (JSWebRequest) -> JSWebNetResult = { r in .failure("no route for " + r.url.href) }
    var seen: [JSWebRequest] = []
    var pending: [(id: Int, result: JSWebNetResult, done: (JSWebNetResult) -> Void)] = []
    var cancelled: [Int] = []
    var nextID = 1
    let net = JSWebNetwork()

    init() {
        net.start = { [unowned self] req, done in
            self.seen.append(req)
            let id = self.nextID
            self.nextID += 1
            self.pending.append((id: id, result: self.handler(req), done: done))
            return id
        }
        net.cancel = { [unowned self] id in
            self.cancelled.append(id)
            self.pending.removeAll { $0.id == id }
        }
    }

    /// Deliver everything pending (one at a time, in order).
    func deliver() -> Bool {
        if pending.isEmpty { return false }
        let p = pending.removeFirst()
        p.done(p.result)
        return true
    }
}

func jswebResponse(_ url: String, _ body: String, status: Int = 200, headers: [(String, String)] = []) -> JSWebNetResult {
    var r = JSWebResponse(url: URLRecord.parseOrNil(url) ?? URLRecord())
    r.status = status
    r.statusText = status == 200 ? "OK" : ""
    for (k, v) in headers { r.headers.append((name: k, value: v)) }
    r.body = Array(body.utf8)
    return .response(r)
}

final class JSWebTestPage {
    let tn = JSWebTestNet()
    var lines: [String] = []
    var clock = 0.0
    var page: JSDOMPage! = nil
    var web: JSWeb! = nil

    init(url: String = "http://a.test/dir/page.html", html: String = "<!DOCTYPE html><title>t</title><body>") {
        var host = JSDOMHost()
        host.console = { [unowned self] _, text in self.lines.append(text) }
        host.reportError = { [unowned self] msg, _ in self.lines.append("ERR: " + msg) }
        host.now = { [unowned self] in self.clock }
        page = JSDOMPage(document: htmlParse(html), url: url, host: host)
        if jswebEnvSet("WIFFER_JSWEB_GCSTRESS") { page.realm.heap.gcEveryAllocation = true }
        web = JSWeb(page: page, network: tn.net)
    }

    deinit {
        web.tearDown()
        page.tearDown()
    }

    /// Run `src`, then the network and the loop until idle; console lines joined.
    func run(_ src: String, advance: Double = 0) -> String {
        lines = []
        page.runScript(src, name: "test.js")
        var n = 0
        while n < 200 {
            page.loop.runDueTasks()
            if tn.deliver() { n += 1; continue }
            page.loop.runDueTasks()
            if advance > 0, let d = page.loop.nextDeadline(), d > 0, d <= advance { clock += d; n += 1; continue }
            if tn.pending.isEmpty && (page.loop.nextDeadline().map { $0 > 0 } ?? true) { break }
            n += 1
        }
        var s = ""
        for (i, l) in lines.enumerated() { if i > 0 { s += "\n" }; s += l }
        return s
    }
}

func jswebEnvSet(_ name: String) -> Bool { getenv(name) != nil }

func libTests(_ t: Tests) {
    jswebURLTests(t)
    jswebEncodingTests(t)
    jswebBodyTests(t)
    jswebFetchTests(t)
    jswebCORSTests(t)
    jswebXHRTests(t)
}

private func jswebURLTests(_ t: Tests) {
    t.section("URL and URLSearchParams")
    let p = JSWebTestPage()
    t.equal(p.run("const u = new URL('../x/y?a=1&b=two+words#h', 'http://a.test/d/p/q'); console.log(u.href, u.pathname, u.search, u.hash, u.origin)"),
            "http://a.test/d/x/y?a=1&b=two+words#h /d/x/y ?a=1&b=two+words #h http://a.test", "resolve against a base")
    t.equal(p.run("console.log(u.searchParams.get('b'), u.searchParams.has('a'), u.searchParams.size)"), "two words true 2", "searchParams reads the query")
    t.equal(p.run("u.searchParams.append('c', 'x&y'); u.searchParams.delete('a'); console.log(u.href)"),
            "http://a.test/d/x/y?b=two+words&c=x%26y#h", "searchParams writes back")
    t.equal(p.run("u.pathname = 'p/q'; u.hash = ''; u.port = '8080'; console.log(u.href)"), "http://a.test:8080/p/q?b=two+words&c=x%26y", "setters")
    t.equal(p.run("u.search = '?z=9'; console.log(u.searchParams.get('z'), String(u))"), "9 http://a.test:8080/p/q?z=9", "search setter, toString")
    t.equal(p.run("try { new URL('nope') } catch (e) { console.log(e.name) }; console.log(URL.canParse('http://x/'), URL.canParse('x'), URL.parse('x'))"),
            "TypeError\ntrue false null", "invalid URL")
    t.equal(p.run("const s = new URLSearchParams('?b=2&a=1&b=1'); s.sort(); console.log(s.toString(), [...s.keys()].join(), s.getAll('b').join())"),
            "a=1&b=2&b=1 a,b,b 2,1", "sort is stable")
    t.equal(p.run("console.log(new URLSearchParams({x: '1', y: 'é'}).toString(), new URLSearchParams([['k', 'v w']]).toString())"),
            "x=1&y=%C3%A9 k=v+w", "record and sequence init")
    t.equal(p.run("let o = []; new URLSearchParams('a=1&b=2').forEach((v, k) => o.push(k + v)); for (const [k, v] of new URLSearchParams('c=3')) o.push(k + v); console.log(o.join())"),
            "a1,b2,c3", "forEach and iteration")
    t.equal(p.run("console.log(JSON.stringify({u: new URL('http://h/')}), Object.prototype.toString.call(new URLSearchParams()))"),
            "{\"u\":\"http://h/\"} [object URLSearchParams]", "toJSON, toStringTag")
}

private func jswebEncodingTests(_ t: Tests) {
    t.section("TextEncoder and TextDecoder")
    let p = JSWebTestPage()
    t.equal(p.run("const e = new TextEncoder().encode('h\\u00e9 \\u20ac'); console.log(e.length, e[1], e[2], e instanceof Uint8Array)"),
            "7 195 169 true", "encode UTF-8")
    t.equal(p.run("console.log(new TextDecoder().decode(new Uint8Array([0xEF,0xBB,0xBF,104,0xC3,0xA9])), new TextDecoder('utf-16le').decode(new Uint8Array([104,0,105,0]).buffer))"),
            "hé hi", "decode with BOM, UTF-16LE from an ArrayBuffer")
    t.equal(p.run("try { new TextDecoder('utf-8', {fatal: true}).decode(new Uint8Array([0xC3])) } catch (e) { console.log(e.name) }; console.log(new TextDecoder().decode(new Uint8Array([0xC3])) === '\\uFFFD')"),
            "TypeError\ntrue", "fatal mode, replacement")
    t.equal(p.run("const d = new TextDecoder(); console.log(d.decode(new Uint8Array([0xE2, 0x82]), {stream: true}) + d.decode(new Uint8Array([0xAC])))"),
            "€", "streaming keeps a split sequence")
    t.equal(p.run("console.log(new TextDecoder('latin1').encoding, new TextDecoder('ISO-8859-1').decode(new Uint8Array([0xE9]))); try { new TextDecoder('nope') } catch (e) { console.log(e.name) }"),
            "windows-1252 é\nRangeError", "labels")
    t.equal(p.run("const buf = new Uint8Array(4); const r = new TextEncoder().encodeInto('a\\u20acb', buf); console.log(r.read, r.written, buf[0], buf[1])"),
            "2 4 97 226", "encodeInto stops when full")
}

private func jswebBodyTests(_ t: Tests) {
    t.section("Blob, FormData, Headers")
    let p = JSWebTestPage(html: "<form id=f><input name=q value=hi><input type=checkbox name=c checked><input type=checkbox name=d><select name=s><option>one<option selected value=2>two</select><textarea name=t>a\nb</textarea><input name=dis disabled value=x><button name=go value=1>Go</button></form>")
    t.equal(p.run("const b = new Blob(['ab', new Uint8Array([99]), new Blob(['d'])], {type: 'Text/Plain'}); console.log(b.size, b.type); b.text().then(s => console.log(s)); b.slice(1, -1).text().then(s => console.log(s))"),
            "4 text/plain\nabcd\nbc", "Blob parts, text, slice")
    t.equal(p.run("const f = new File(['x'], 'a.txt', {type: 'text/plain'}); console.log(f.name, f.size, f instanceof Blob)"), "a.txt 1 true", "File")
    t.equal(p.run("const fd = new FormData(document.getElementById('f')); console.log([...fd].map(([k, v]) => k + '=' + JSON.stringify(v)).join(' '))"),
            "q=\"hi\" c=\"on\" s=\"2\" t=\"a\\r\\nb\"", "FormData(form) entry list")
    t.equal(p.run("document.querySelector('[name=q]').value = 'typed'; const g = new FormData(document.getElementById('f'), document.querySelector('button')); console.log(g.get('q'), g.get('go'), g.has('d'))"),
            "typed 1 false", "page control state and submitter")
    t.equal(p.run("const h = new FormData(); h.append('a', '1'); h.append('a', '2'); h.set('b', new Blob(['z']), 'z.bin'); console.log(h.getAll('a').join(), h.get('b').name, h.get('nope'))"),
            "1,2 z.bin null", "FormData methods")
    t.equal(p.run("const hd = new Headers({'Content-Type': 'text/html', 'X-A': '1'}); hd.append('x-a', '2'); console.log(hd.get('x-A'), hd.has('content-type'), [...hd.keys()].join())"),
            "1, 2 true content-type,x-a", "Headers combine and sort")
    t.equal(p.run("try { new Headers([['bad name', 'v']]) } catch (e) { console.log(e.name) }; const r = new Request('/x', {method: 'post', headers: {Cookie: 'a=1', 'X-Ok': '1'}, body: 'hi'}); console.log(r.method, r.url, r.headers.has('cookie'), r.headers.get('content-type'))"),
            "TypeError\nPOST http://a.test/x false text/plain;charset=UTF-8", "Request: forbidden headers dropped, body type")
    t.equal(p.run("try { new Request('/x', {body: 'a'}) } catch (e) { console.log(e.name) }; new Response('{\"a\":[1]}', {status: 201, headers: {'X-Y': 'z'}}).json().then(j => console.log(j.a[0]))"),
            "TypeError\n1", "GET with body throws; Response json")
    t.equal(p.run("const res = new Response('abc'); res.text().then(s => { console.log(s, res.bodyUsed); return res.text() }).catch(e => console.log(e.name)); console.log(Response.json({k: 1}).headers.get('content-type'))"),
            "application/json\nabc true\nTypeError", "body used once; Response.json")
    t.equal(p.run("new Response(new URLSearchParams('a=1')).headers.get('content-type') === 'application/x-www-form-urlencoded;charset=UTF-8' && console.log('ok'); new Response(new Uint8Array([1,2])).arrayBuffer().then(b => console.log(b.byteLength))"),
            "ok\n2", "body types")
}

private func jswebFetchTests(_ t: Tests) {
    t.section("fetch")
    let p = JSWebTestPage()
    p.tn.handler = { r in
        switch r.url.pathname {
        case "/data.json": return jswebResponse(r.url.href, "{\"x\": 42, \"s\": \"é\"}", headers: [("Content-Type", "application/json"), ("X-Custom", "c")])
        case "/echo": return jswebResponse(r.url.href, r.method + " " + String(decoding: r.body, as: UTF8.self))
        case "/missing": return jswebResponse(r.url.href, "nope", status: 404)
        case "/redir": return jswebResponse("http://a.test/final", "landed")
        default: return .failure("refused")
        }
    }
    t.equal(p.run("fetch('/data.json').then(r => { console.log(r.status, r.ok, r.type, r.url, r.headers.get('x-custom')); return r.json() }).then(j => console.log(j.x, j.s))"),
            "200 true basic http://a.test/data.json c\n42 é", "same-origin JSON")
    let req = p.tn.seen.last
    t.check(req?.credentials == true && !(req?.headers.contains { $0.name == "Origin" } ?? true), "same-origin: cookies, no Origin header")
    t.equal(p.run("fetch('/echo', {method: 'POST', body: new URLSearchParams({a: 'b c'})}).then(r => r.text()).then(s => console.log(s))"),
            "POST a=b+c", "POST a URLSearchParams body")
    t.check(p.tn.seen.last?.headers.contains { $0.name == "content-type" && $0.value.hasPrefix("application/x-www-form-urlencoded") } == true,
            "content type sent")
    t.equal(p.run("fetch('/missing').then(r => console.log(r.status, r.ok))"), "404 false", "HTTP errors resolve")
    t.equal(p.run("fetch('/refused').catch(e => console.log(e.name, e.message))"), "TypeError Failed to fetch", "network errors reject")
    t.equal(p.run("fetch('/redir').then(r => console.log(r.redirected, r.url))"), "true http://a.test/final", "redirected")
    t.equal(p.run("const ac = new AbortController(); const pr = fetch('/data.json', {signal: ac.signal}); ac.abort(); pr.catch(e => console.log(e.name))"),
            "AbortError", "abort rejects")
    t.check(!p.tn.cancelled.isEmpty, "abort cancels the request")
    t.equal(p.run("fetch('/x', {signal: AbortSignal.abort()}).catch(e => console.log(e.name))"), "AbortError", "already aborted")
    t.equal(p.run("fetch('data:text/plain;base64,aGk=').then(r => r.text()).then(s => console.log(s)); fetch('data:,a%20b').then(r => r.text()).then(s => console.log(s))"),
            "hi\na b", "data: URLs")
    t.equal(p.run("fetch(new Request('/echo', {method: 'PUT', body: 'z'})).then(r => r.text()).then(s => console.log(s))"), "PUT z", "a Request object")
    t.check(p.web.fetchCount == 10, "fetch count \(p.web.fetchCount)")
}

private func jswebCORSTests(_ t: Tests) {
    t.section("CORS")
    let p = JSWebTestPage()
    p.tn.handler = { r in
        let path = r.url.pathname
        let origin = r.headers.first { $0.name == "Origin" }?.value ?? ""
        if r.method == "OPTIONS" {
            if path == "/open" {
                return jswebResponse(r.url.href, "", status: 204, headers: [("Access-Control-Allow-Origin", "*"), ("Access-Control-Allow-Methods", "PUT, DELETE"),
                                                                            ("Access-Control-Allow-Headers", "X-Token")])
            }
            return jswebResponse(r.url.href, "", status: 204)
        }
        switch path {
        case "/open": return jswebResponse(r.url.href, "open " + r.method, headers: [("Access-Control-Allow-Origin", "*"), ("X-Secret", "s"),
                                                                                    ("X-Shown", "y"), ("Access-Control-Expose-Headers", "X-Shown"), ("Content-Type", "text/plain")])
        case "/creds": return jswebResponse(r.url.href, "creds", headers: [("Access-Control-Allow-Origin", origin), ("Access-Control-Allow-Credentials", "true")])
        case "/star": return jswebResponse(r.url.href, "star", headers: [("Access-Control-Allow-Origin", "*")])
        default: return jswebResponse(r.url.href, "closed")
        }
    }
    t.equal(p.run("fetch('http://b.test/closed').then(r => console.log('leaked')).catch(e => console.log(e.name))").split(separator: "\n").last.map { String($0) } ?? "",
            "TypeError", "no Access-Control-Allow-Origin: fails")
    t.check(p.lines.contains { $0.hasPrefix("Access to fetch at 'http://b.test/closed' from origin 'http://a.test' has been blocked by CORS policy") },
            "console explains the block", p.lines.joined(separator: " | "))
    let sent = p.tn.seen.last
    t.check(sent?.credentials == false && sent?.headers.contains { $0.name == "Origin" && $0.value == "http://a.test" } == true,
            "cross-origin: Origin header, no cookies")
    t.equal(p.run("fetch('http://b.test/open').then(r => { console.log(r.type, r.headers.get('x-secret'), r.headers.get('x-shown'), r.headers.get('content-type')); return r.text() }).then(console.log)"),
            "cors null y text/plain\nopen GET", "ACAO *: allowed, headers filtered")
    let n0 = p.tn.seen.count
    t.equal(p.run("fetch('http://b.test/open', {method: 'PUT', headers: {'X-Token': 't'}}).then(r => r.text()).then(console.log)"), "open PUT", "preflight allows PUT + X-Token")
    t.check(p.tn.seen.count == n0 + 2 && p.tn.seen[n0].method == "OPTIONS"
            && p.tn.seen[n0].headers.contains { $0.name == "Access-Control-Request-Method" && $0.value == "PUT" }
            && p.tn.seen[n0].headers.contains { $0.name == "Access-Control-Request-Headers" && $0.value == "x-token" },
            "preflight sent first with the method and headers")
    t.equal(p.run("fetch('http://b.test/open', {method: 'PATCH'}).catch(e => console.log(e.name))").split(separator: "\n").last.map { String($0) } ?? "",
            "TypeError", "preflight without the method: fails")
    let n1 = p.tn.seen.count
    t.equal(p.run("fetch('http://b.test/star', {method: 'DELETE'}).catch(e => console.log(e.name))").split(separator: "\n").last.map { String($0) } ?? "",
            "TypeError", "preflight that allows nothing: fails")
    t.check(p.tn.seen.count == n1 + 1, "the actual request is not sent after a failed preflight")
    t.equal(p.run("fetch('http://b.test/star', {headers: {'Content-Type': 'text/plain'}, method: 'POST', body: 'x'}).then(r => r.text()).then(console.log)"),
            "star", "a simple POST needs no preflight")
    t.equal(p.run("fetch('http://b.test/star', {credentials: 'include'}).catch(e => console.log(e.name))").split(separator: "\n").last.map { String($0) } ?? "",
            "TypeError", "credentials with ACAO *: fails")
    t.equal(p.run("fetch('http://b.test/creds', {credentials: 'include'}).then(r => r.text()).then(console.log)"), "creds", "credentials with the exact origin")
    t.check(p.tn.seen.last?.credentials == true, "credentials include sends cookies")
    t.equal(p.run("fetch('http://b.test/star', {mode: 'same-origin'}).catch(e => console.log(e.name))").split(separator: "\n").last.map { String($0) } ?? "",
            "TypeError", "mode same-origin")
    t.equal(p.run("fetch('http://b.test/closed', {mode: 'no-cors'}).then(r => { console.log(r.type, r.status); return r.text() }).then(s => console.log(JSON.stringify(s)))"),
            "opaque 0\n\"\"", "no-cors: opaque")
    t.equal(p.run("fetch('https://a.test/star').then(r => console.log(r.type))"), "cors", "another scheme is another origin")
    let f = JSWebTestPage(url: "file:///www/index.html")
    f.tn.handler = { r in jswebResponse(r.url.href, "local") }
    t.equal(f.run("fetch('data.txt').then(r => r.text()).then(console.log)"), "local", "file: pages fetch file: URLs")
    t.equal(f.run("fetch('http://b.test/closed').catch(e => console.log(e.name))").split(separator: "\n").last.map { String($0) } ?? "",
            "TypeError", "file: page to http: is cross-origin")
}

private func jswebXHRTests(_ t: Tests) {
    t.section("XMLHttpRequest")
    let p = JSWebTestPage()
    p.tn.handler = { r in
        switch r.url.pathname {
        case "/data.json": return jswebResponse(r.url.href, "{\"x\": 7}", headers: [("Content-Type", "application/json; charset=utf-8"), ("Set-Cookie", "a=1")])
        case "/echo": return jswebResponse(r.url.href, r.method + " " + String(decoding: r.body, as: UTF8.self) + " " + (r.headers.first { $0.name == "X-A" }?.value ?? ""))
        case "/slow": return .failure("never")
        default: return jswebResponse(r.url.href, "closed")
        }
    }
    t.equal(p.run("""
        const x = new XMLHttpRequest(); const st = [];
        x.onreadystatechange = function () { st.push(this.readyState) };
        x.addEventListener('load', e => console.log(x.status, x.statusText, x.responseText, x.getResponseHeader('content-type'), x.getResponseHeader('set-cookie'), e.loaded));
        x.onloadend = () => console.log(st.join(), x.responseURL);
        x.open('GET', '/data.json'); x.send(); console.log('sent', x.readyState)
        """),
            "sent 1\n200 OK {\"x\": 7} application/json; charset=utf-8 null 8\n1,2,3,4 http://a.test/data.json", "GET with events in order")
    t.equal(p.run("const y = new XMLHttpRequest(); y.responseType = 'json'; y.onload = () => console.log(y.response.x, y.response === y.response); y.open('GET', '/data.json'); y.send()"),
            "7 true", "responseType json")
    t.equal(p.run("const z = new XMLHttpRequest(); z.open('POST', '/echo'); z.setRequestHeader('X-A', 'one'); z.setRequestHeader('x-a', 'two'); z.onload = () => console.log(z.responseText); z.send('body')"),
            "POST body one, two", "POST with headers")
    t.equal(p.run("const s = new XMLHttpRequest(); try { s.open('GET', '/data.json', false) } catch (e) { console.log(e.name) }"),
            "InvalidAccessError", "synchronous XHR throws")
    t.equal(p.run("const a = new XMLHttpRequest(); a.open('GET', '/slow'); a.onabort = () => console.log('abort', a.readyState, a.status); a.onloadend = () => console.log('end'); a.send(); a.abort(); console.log(a.readyState)"),
            "abort 4 0\nend\n0", "abort")
    t.equal(p.run("const c = new XMLHttpRequest(); c.open('GET', 'http://b.test/closed'); c.onerror = () => console.log('error', c.status, c.readyState); c.onload = () => console.log('leaked'); c.send()")
                .split(separator: "\n").last.map { String($0) } ?? "",
            "error 0 4", "cross-origin XHR without CORS: error event")
    p.tn.handler = { r in r.url.pathname == "/hang" ? jswebResponse(r.url.href, "late") : jswebResponse(r.url.href, "x") }
    p.tn.pending = []
    // A timeout: the response never arrives before the timer.
    let saved = p.tn.net.start
    p.tn.net.start = { req, done in p.tn.seen.append(req); return 99 }
    t.equal(p.run("const tm = new XMLHttpRequest(); tm.open('GET', '/hang'); tm.timeout = 50; tm.ontimeout = () => console.log('timeout', tm.readyState); tm.send()", advance: 100),
            "timeout 4", "timeout")
    p.tn.net.start = saved
    t.equal(p.run("console.log(XMLHttpRequest.DONE, new XMLHttpRequest() instanceof EventTarget, Object.prototype.toString.call(new XMLHttpRequest()))"),
            "4 true [object XMLHttpRequest]", "constants, EventTarget, toStringTag")
    t.equal(p.run("const ab = new XMLHttpRequest(); ab.responseType = 'arraybuffer'; ab.onload = () => console.log(ab.response.byteLength); ab.open('GET', '/x'); ab.send()"),
            "1", "responseType arraybuffer")
    t.check(p.web.xhrCount >= 6, "xhr count")
}
