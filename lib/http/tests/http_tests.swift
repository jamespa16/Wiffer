private func u(_ s: String) -> [UInt8] { Array(s.utf8) }
private func s(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }
private func has(_ hay: String, _ needle: String) -> Bool {
    let h = Array(hay.utf8), n = Array(needle.utf8)
    if n.isEmpty { return true }
    if h.count < n.count { return false }
    var i = 0
    while i + n.count <= h.count {
        var ok = true
        var k = 0
        while k < n.count { if h[i + k] != n[k] { ok = false; break }; k += 1 }
        if ok { return true }
        i += 1
    }
    return false
}
private func url(_ x: String) -> URLRecord { URLRecord.parseOrNil(x)! }

/// Run a whole response through the parser in chunks of `chunk` bytes.
private func parse(_ raw: [UInt8], method: String = "GET", chunk: Int = 1 << 20, eof: Bool = true)
    -> (HTTPResponseCollector, HTTPResponseParser) {
    var p = HTTPResponseParser(requestMethod: u(method))
    var col = HTTPResponseCollector()
    var i = 0
    while i < raw.count {
        var ev: [HTTPParseEvent] = []
        let j = min(raw.count, i + chunk)
        p.feed(Array(raw[i..<j]), &ev)
        col.handle(ev)
        i = j
    }
    if eof {
        var ev: [HTTPParseEvent] = []
        p.finish(&ev)
        col.handle(ev)
    }
    return (col, p)
}

private func tokenBody(_ c: HTTPResponseCollector) -> String { s(c.rawBody) }

/// XOR "decoder" standing in for inflate.
private struct XorDecoder: HTTPBodyDecoder {
    var n = 0
    mutating func decode(_ input: [UInt8], final: Bool, into out: inout [UInt8]) -> Bool {
        for b in input { out.append(b ^ 0x20); n += 1 }
        return !(final && n == 99)
    }
}

func libTests(_ t: Tests) {
    // MARK: request
    t.section("request")
    var req = s(httpBuildRequest(method: u("get"), url: url("http://example.com/a/b?x=1#frag")))
    t.equal(req, "GET /a/b?x=1 HTTP/1.1\r\nHost: example.com\r\nUser-Agent: Wiffer/0.1\r\nAccept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8\r\nAccept-Encoding: gzip, deflate\r\nConnection: keep-alive\r\n\r\n", "GET")
    req = s(httpBuildRequest(method: u("POST"), url: url("https://h.example:8443/f"), headers: [HTTPHeader("X-A", "1\r\nEvil: yes"), HTTPHeader("accept", "*/*")],
                             body: u("a=1&b=2"), contentType: u("application/x-www-form-urlencoded"), cookie: u("k=v; k2=v2")))
    t.check(req.hasPrefix("POST /f HTTP/1.1\r\nHost: h.example:8443\r\n"), "POST line + host with port")
    t.check(has(req, "Cookie: k=v; k2=v2\r\n"), "cookie header")
    t.check(has(req, "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: 7\r\n"), "post headers")
    t.check(has(req, "X-A: 1  Evil: yes\r\n") && !has(req, "\r\nEvil:"), "header injection neutralised")
    t.check(has(req, "accept: */*\r\n") && !has(req, "Accept: text/html"), "caller overrides default Accept")
    t.check(req.hasSuffix("\r\n\r\na=1&b=2"), "body")
    req = s(httpBuildRequest(method: u("GET"), url: url("http://[::1]/"), options: { var o = HTTPRequestOptions(); o.keepAlive = false; return o }()))
    t.check(has(req, "Host: [::1]\r\n") && has(req, "Connection: close\r\n"), "ipv6 host, close")
    t.check(s(httpBuildRequest(method: u("b a d"), url: url("http://x/"))).hasPrefix("GET / "), "bad method becomes GET")

    // MARK: parser
    t.section("parser: content-length")
    let cl = u("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 5\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\n\r\nhelloEXTRA")
    for chunk in [1, 2, 3, 7, 1000] {
        let (c, p) = parse(cl, chunk: chunk, eof: false)
        t.check(c.isComplete && c.error == nil && c.keepAlive, "complete (chunk \(chunk))")
        t.equal(tokenBody(c), "hello", "body (chunk \(chunk))")
        t.equal(s(p.leftover), "EXTRA", "leftover (chunk \(chunk))")
        t.check(c.head?.status == 200 && s(c.head?.reason ?? []) == "OK", "status")
        t.equal(c.head?.setCookies.count ?? 0, 2, "duplicate Set-Cookie kept")
    }
    t.section("parser: chunked")
    let ch = u("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5;ext=1\r\npedia\r\nE\r\n in\r\n\r\nchunks.\r\n0\r\nX-Trailer: yes\r\nX-T2: two\r\n\r\n")
    for chunk in [1, 2, 5, 1000] {
        let (c, _) = parse(ch, chunk: chunk, eof: false)
        t.check(c.isComplete && c.error == nil && c.keepAlive, "chunked complete (chunk \(chunk))")
        t.equal(tokenBody(c), "Wikipedia in\r\n\r\nchunks.", "chunked body (chunk \(chunk))")
        t.equal(c.trailers.count, 2, "trailers (chunk \(chunk))")
    }
    var (c, _) = parse(u("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 99\r\n\r\n3\r\nabc\r\n0\r\n\r\n"))
    t.check(c.isComplete && tokenBody(c) == "abc", "chunked wins over content-length")
    (c, _) = parse(u("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nZZ\r\n"))
    t.check(c.error == .badChunk, "bad chunk size")
    (c, _) = parse(u("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabcXX"))
    t.check(c.error == .badChunk, "missing CRLF after chunk data")
    (c, _) = parse(u("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nab"))
    t.check(c.error == .truncated, "truncated chunked")
    (c, _) = parse(u("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nFFFFFFFFFFFF\r\n"))
    t.check(c.error == .badChunk, "huge chunk")

    t.section("parser: framing")
    (c, _) = parse(u("HTTP/1.0 200 OK\r\n\r\nuntil close"))
    t.check(c.isComplete && tokenBody(c) == "until close" && !c.keepAlive, "close-delimited")
    (c, _) = parse(u("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc"))
    t.check(c.error == .truncated, "short content-length body")
    (c, _) = parse(u("HTTP/1.1 200 OK\r\nContent-Length: 3\r\nContent-Length: 4\r\n\r\nabc"))
    t.check(c.error == .badContentLength, "conflicting content-length")
    (c, _) = parse(u("HTTP/1.1 200 OK\r\nContent-Length: 3, 3\r\n\r\nabc"))
    t.check(c.isComplete && tokenBody(c) == "abc", "duplicate equal content-length")
    (c, _) = parse(u("HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\n"))
    t.check(c.error == .badContentLength, "negative content-length")
    (c, _) = parse(u("HTTP/1.1 200 OK\r\nContent-Length: 99999999999999\r\n\r\n"))
    t.check(c.error == .bodyTooLarge, "huge content-length")
    (c, _) = parse(u("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n"), method: "HEAD")
    t.check(c.isComplete && c.rawBody.isEmpty && c.keepAlive, "HEAD has no body")
    (c, _) = parse(u("HTTP/1.1 204 No Content\r\nContent-Length: 100\r\n\r\n"))
    t.check(c.isComplete && c.rawBody.isEmpty, "204")
    (c, _) = parse(u("HTTP/1.1 304 Not Modified\r\nETag: \"x\"\r\n\r\n"))
    t.check(c.isComplete && c.rawBody.isEmpty && c.keepAlive, "304")
    (c, _) = parse(u("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"))
    t.check(c.isComplete && c.head?.status == 200 && tokenBody(c) == "ok", "1xx skipped")
    (c, _) = parse(u("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 2\r\n\r\nok"))
    t.check(c.isComplete && !c.keepAlive, "Connection: close")
    (c, _) = parse(u("HTTP/1.0 200 OK\r\nConnection: Keep-Alive\r\nContent-Length: 2\r\n\r\nok"))
    t.check(c.isComplete && c.keepAlive, "1.0 keep-alive")
    (c, _) = parse(u("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
    t.check(c.isComplete && c.keepAlive && c.rawBody.isEmpty, "zero length")

    t.section("parser: headers")
    (c, _) = parse(u("HTTP/1.1 200 OK\r\nX-Folded: one\r\n two\r\n\tthree\r\nX-Dup: a\r\nx-dup: b\r\nContent-Length: 0\r\n\r\n"))
    t.equal(s(c.head?.header("X-Folded") ?? []), "one two three", "folded header")
    t.equal(s(c.head?.header("X-DUP") ?? []), "a, b", "duplicate headers joined, case-insensitive")
    (c, _) = parse(u("HTTP/1.1 200 OK\nContent-Length: 2\n\nok"))
    t.check(c.isComplete && tokenBody(c) == "ok", "bare LF line endings")
    (c, _) = parse(u("HTTP/1.1 200 OK\r\nBad Header: x\r\n\r\n"))
    t.check(c.error == .badHeader, "space in header name")
    (c, _) = parse(u("HTTP/1.1 200 OK\r\nNoColon\r\n\r\n"))
    t.check(c.error == .badHeader, "header without colon")
    (c, _) = parse(u("garbage\r\n\r\n"))
    t.check(c.error == .badStatusLine, "garbage status line")
    (c, _) = parse(u("HTTP/1.1 20 OK\r\n\r\n"))
    t.check(c.error == .badStatusLine, "short status")
    (c, _) = parse(u("HTTP/1.1 200\r\nContent-Length: 0\r\n\r\n"))
    t.check(c.isComplete && c.head?.status == 200 && (c.head?.reason.isEmpty ?? false), "status without reason")
    (c, _) = parse(u("HTTP/1.1 200 OK\r\nA: " + String(repeating: "x", count: 20000) + "\r\n\r\n"))
    t.check(c.error == .lineTooLong, "long header line")
    var many = "HTTP/1.1 200 OK\r\n"
    for k in 0..<300 { many += "H\(k): v\r\n" }
    (c, _) = parse(u(many + "\r\n"))
    t.check(c.error == .tooManyHeaders, "too many headers")
    (c, _) = parse(u(""))
    t.check(c.error == .truncated, "EOF before any response")
    let gz = parse(u("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 0\r\n\r\n")).0
    t.check(gz.head?.contentEncoding == .gzip, "contentEncoding gzip")
    let st = parse(u("HTTP/1.1 200 OK\r\nContent-Encoding: deflate, gzip\r\nContent-Length: 0\r\n\r\n")).0
    t.check(st.head?.contentEncoding == .unknown && st.head?.contentEncodings == [.deflate, .gzip], "stacked encodings")

    t.section("content-encoding hook")
    var sink = HTTPBodySink<XorDecoder>(decoder: XorDecoder())
    sink.push([0x41]); sink.push([0x42])
    t.check(sink.finish() && sink.output == [0x61, 0x62], "sink decodes streaming")
    var plain = HTTPBodySink<HTTPIdentityDecoder>(decoder: nil)
    plain.push(u("ab")); plain.push(u("cd"))
    t.check(plain.finish() && s(plain.output) == "abcd", "sink identity")
    var capped = HTTPBodySink<HTTPIdentityDecoder>(decoder: nil, maxOutput: 3)
    t.check(!capped.push(u("abcd")), "sink output cap")
    t.equal(s(httpDecodeBody(raw: u("x"), encoding: .gzip) { d, _ in d + u("!") } ?? []), "x!", "closure decode")
    t.check(httpDecodeBody(raw: u("x"), encoding: .unknown) { d, _ in d } == nil, "unknown encoding rejected")

    // MARK: redirects
    t.section("redirects")
    let cur = url("http://example.com/a/b?q=1#orig")
    func red(_ status: Int, _ m: String, _ loc: String?, n: Int = 0) -> HTTPRedirectDecision {
        httpRedirectDecision(status: status, method: u(m), location: loc.map { u($0) }, current: cur, redirectsSoFar: n)
    }
    if case .follow(let m, let to, let drop, let cross) = red(301, "POST", "/x/y") {
        t.check(s(m) == "GET" && drop && !cross && to.href == "http://example.com/x/y#orig", "301 POST->GET, relative, fragment inherited")
    } else { t.check(false, "301 follow") }
    if case .follow(let m, _, let drop, _) = red(302, "GET", "z") { t.check(s(m) == "GET" && !drop, "302 GET stays") } else { t.check(false, "302") }
    if case .follow(let m, _, let drop, _) = red(303, "PUT", "/z") { t.check(s(m) == "GET" && drop, "303 PUT->GET") } else { t.check(false, "303") }
    if case .follow(let m, _, let drop, _) = red(303, "HEAD", "/z") { t.check(s(m) == "HEAD" && !drop, "303 HEAD stays") } else { t.check(false, "303 head") }
    if case .follow(let m, _, let drop, _) = red(307, "POST", "/z") { t.check(s(m) == "POST" && !drop, "307 keeps method") } else { t.check(false, "307") }
    if case .follow(let m, _, let drop, _) = red(308, "POST", "/z") { t.check(s(m) == "POST" && !drop, "308 keeps method") } else { t.check(false, "308") }
    if case .follow(_, let to, _, let cross) = red(302, "GET", "https://other.org/p#new") {
        t.check(cross && to.href == "https://other.org/p#new", "cross-origin, new fragment")
    } else { t.check(false, "cross origin") }
    if case .follow(_, let to, _, _) = red(302, "GET", "//cdn.example.com/s.js") { t.equal(to.href, "http://cdn.example.com/s.js#orig", "scheme-relative") } else { t.check(false, "//") }
    if case .tooMany = red(302, "GET", "/x", n: 10) {} else { t.check(false, "11th redirect refused") }
    if case .follow = red(302, "GET", "/x", n: 9) {} else { t.check(false, "10th redirect allowed") }
    if case .invalid = red(302, "GET", "ftp://h/") {} else { t.check(false, "non-http scheme invalid") }
    if case .invalid = red(302, "GET", "http://[bad/") {} else { t.check(false, "unparsable invalid") }
    if case .notRedirect = red(302, "GET", nil) {} else { t.check(false, "no Location") }
    if case .notRedirect = red(200, "GET", "/x") {} else { t.check(false, "200 not a redirect") }
    if case .notRedirect = red(304, "GET", "/x") {} else { t.check(false, "304 not a redirect") }

    // MARK: dates
    t.section("dates")
    t.equal(httpParseDate(u("Sun, 06 Nov 1994 08:49:37 GMT")) ?? -1, 784111777, "rfc1123")
    t.equal(httpParseDate(u("Sunday, 06-Nov-94 08:49:37 GMT")) ?? -1, 784111777, "rfc850")
    t.equal(httpParseDate(u("Sun Nov  6 08:49:37 1994")) ?? -1, 784111777, "asctime")
    t.equal(httpParseDate(u("Thu, 01 Jan 1970 00:00:00 GMT")) ?? -1, 0, "epoch")
    t.equal(httpParseDate(u("Wed, 21 Oct 2015 07:28:00 GMT")) ?? -1, 1445412480, "2015")
    t.equal(httpParseDate(u("Tue, 29 Feb 2000 00:00:00 GMT")) ?? -1, 951782400, "leap day")
    t.check(httpParseDate(u("Tue, 29 Feb 2001 00:00:00 GMT")) == nil, "invalid leap day")
    t.check(httpParseDate(u("Sun, 06 Nov 1994 25:49:37 GMT")) == nil, "bad hour")
    t.check(httpParseDate(u("garbage")) == nil, "garbage")
    t.check(httpParseDate(u("Sun, 06 Nov 1500 08:49:37 GMT")) == nil, "year < 1601")

    // MARK: cookies
    t.section("cookies")
    let now = 1_700_000_000
    var jar = HTTPCookieJar()
    let site = url("https://www.example.com/dir/page")
    t.check(jar.setCookie(u("sid=abc; Path=/; HttpOnly; Secure"), from: site, now: now), "store")
    t.check(jar.setCookie(u("theme=dark; Domain=.example.com; Path=/dir"), from: site, now: now), "domain cookie")
    t.check(jar.setCookie(u("deep=1; Path=/dir/sub"), from: site, now: now), "deep path")
    t.check(jar.setCookie(u("hostonly=1"), from: site, now: now), "default path")
    t.equal(s(jar.cookieHeader(for: site, now: now) ?? []), "theme=dark; hostonly=1; sid=abc", "header order: longer path first, then creation")
    t.equal(s(jar.cookieHeader(for: url("https://example.com/dir/x"), now: now) ?? []), "theme=dark", "domain cookie reaches parent host; host-only does not")
    t.equal(s(jar.cookieHeader(for: url("https://a.b.example.com/dir/x"), now: now) ?? []), "theme=dark", "subdomain")
    t.check(jar.cookieHeader(for: url("https://notexample.com/dir/x"), now: now) == nil, "different domain")
    t.equal(s(jar.cookieHeader(for: url("http://www.example.com/dir/x"), now: now) ?? []), "theme=dark; hostonly=1", "Secure not sent over http")
    t.equal(s(jar.documentCookie(for: site, now: now)), "theme=dark; hostonly=1", "document.cookie hides HttpOnly (and path /dir/sub)")
    t.check(!jar.setCookie(u("x=1; Domain=other.com"), from: site, now: now), "foreign domain rejected")
    t.check(!jar.setCookie(u("x=1; Domain=com"), from: site, now: now), "TLD domain rejected")
    t.check(!jar.setCookie(u("x=1; Domain=co.uk"), from: url("https://foo.co.uk/"), now: now), "public suffix rejected")
    t.check(!jar.setCookie(u("x=1; Secure"), from: url("http://www.example.com/"), now: now), "Secure from http rejected")
    t.check(!jar.setCookie(u("novalue"), from: site, now: now), "no '=' rejected")
    t.check(!jar.setCookie(u("=v"), from: site, now: now), "empty name rejected")
    t.check(!jar.setCookie(u("h=1; HttpOnly"), from: site, now: now, fromScript: true), "script can't set HttpOnly")
    t.check(!jar.setCookie(u("sid=hijack; Path=/"), from: site, now: now, fromScript: true), "script can't overwrite HttpOnly")
    t.check(!jar.setCookie(u("sid=hijack; Path=/"), from: url("http://www.example.com/"), now: now), "insecure can't overwrite Secure")
    t.check(jar.setCookie(u("theme=light; Domain=example.com; Path=/dir"), from: site, now: now), "replace")
    t.equal(s(jar.cookieHeader(for: site, now: now) ?? []), "theme=light; hostonly=1; sid=abc", "replaced value, keeps creation order")
    // expiry
    t.check(jar.setCookie(u("exp=1; Max-Age=10; Path=/"), from: site, now: now), "max-age")
    t.check(jar.cookieHeader(for: site, now: now + 5)!.count > 0 && has(s(jar.cookieHeader(for: site, now: now + 5)!), "exp=1"), "alive at +5")
    t.check(!has(s(jar.cookieHeader(for: site, now: now + 10) ?? []), "exp=1"), "gone at +10")
    t.check(jar.setCookie(u("e2=1; Expires=Wed, 21 Oct 2015 07:28:00 GMT; Path=/"), from: site, now: now) == false, "past Expires not stored")
    t.check(jar.setCookie(u("e3=1; Expires=Wed, 21 Oct 2099 07:28:00 GMT; Path=/"), from: site, now: now), "future Expires")
    t.check(jar.setCookie(u("e4=1; Expires=Wed, 21 Oct 2099 07:28:00 GMT; Max-Age=5; Path=/"), from: site, now: now), "both")
    t.check(!has(s(jar.cookieHeader(for: site, now: now + 6) ?? []), "e4=1") && has(s(jar.cookieHeader(for: site, now: now + 6) ?? []), "e3=1"), "Max-Age beats Expires")
    t.check(jar.setCookie(u("e3=; Max-Age=0; Path=/"), from: site, now: now), "delete via Max-Age=0")
    t.check(!has(s(jar.cookieHeader(for: site, now: now) ?? []), "e3="), "deleted")
    t.equal(httpDefaultPath(u("/a/b/c")).count, 4, "default-path /a/b")
    t.check(httpPathMatches(requestPath: u("/a/b"), cookiePath: u("/a")), "path match")
    t.check(!httpPathMatches(requestPath: u("/ab"), cookiePath: u("/a")), "path mismatch")
    t.check(httpDomainMatches(host: u("a.example.com"), domain: u("example.com")), "domain match")
    t.check(!httpDomainMatches(host: u("1.2.3.4"), domain: u("3.4")), "no IP suffix match")
    var big = HTTPCookieJar()
    for k in 0..<80 { big.setCookie(u("c\(k)=v"), from: site, now: now) }
    t.check(big.count <= httpCookieMaxPerDomain, "per-domain cap", "\(big.count)")

    // MARK: cache
    t.section("cache")
    let cu = url("http://example.com/res.css#ignored")
    func head(_ hs: [HTTPHeader], status: Int = 200) -> HTTPResponseHead {
        var h = HTTPResponseHead(); h.status = status; h.headers = hs; return h
    }
    var cache = HTTPCache()
    t.check(cache.store(url: cu, method: u("GET"), head: head([HTTPHeader("Cache-Control", "max-age=60")]), body: u("body"), now: now), "stores max-age")
    t.check(cache.lookup(url("http://example.com/res.css"), now: now + 59) != nil, "fresh (fragment ignored)")
    t.check(cache.lookup(cu, now: now + 60) == nil, "stale at 60")
    t.check(!cache.store(url: cu, method: u("GET"), head: head([HTTPHeader("Cache-Control", "no-store")]), body: u("b"), now: now), "no-store")
    t.check(cache.stale(cu) == nil, "no-store evicts old entry")
    t.check(!cache.store(url: cu, method: u("POST"), head: head([HTTPHeader("Cache-Control", "max-age=60")]), body: u("b"), now: now), "POST not cached")
    t.check(!cache.store(url: cu, method: u("GET"), head: head([]), body: u("b"), now: now), "no freshness, no validators: not cached")
    t.check(cache.store(url: cu, method: u("GET"), head: head([HTTPHeader("ETag", "\"v1\"")]), body: u("b"), now: now), "validator-only entry stored")
    t.check(cache.lookup(cu, now: now) == nil && cache.conditionalHeaders(for: cu).count == 1, "stale but conditional")
    let rv = cache.revalidated(cu, newHeaders: [HTTPHeader("Cache-Control", "max-age=100")], now: now + 10)
    t.check(rv != nil && cache.lookup(cu, now: now + 109) != nil && cache.lookup(cu, now: now + 110) == nil, "304 refreshes")
    t.check(cache.store(url: cu, method: u("GET"), head: head([HTTPHeader("Cache-Control", "no-cache"), HTTPHeader("ETag", "\"a\"")]), body: u("b"), now: now) && cache.lookup(cu, now: now) == nil, "no-cache never fresh")
    t.check(cache.store(url: cu, method: u("GET"), head: head([HTTPHeader("Expires", "Wed, 21 Oct 2015 07:30:00 GMT"), HTTPHeader("Date", "Wed, 21 Oct 2015 07:28:00 GMT")]), body: u("b"), now: 1_445_412_480), "Expires with Date")
    t.check(cache.lookup(cu, now: 1_445_412_480 + 119) != nil && cache.lookup(cu, now: 1_445_412_480 + 120) == nil, "Expires lifetime")
    t.check(cache.store(url: cu, method: u("GET"), head: head([HTTPHeader("Cache-Control", "max-age=100"), HTTPHeader("Age", "90")]), body: u("b"), now: now) && cache.lookup(cu, now: now + 9) != nil && cache.lookup(cu, now: now + 10) == nil, "Age header")
    t.check(!cache.store(url: cu, method: u("GET"), head: head([HTTPHeader("Cache-Control", "max-age=100"), HTTPHeader("Vary", "Cookie")]), body: u("b"), now: now), "Vary: Cookie not cached")
    cache.invalidate(cu)
    t.check(cache.stale(cu) == nil, "invalidate")
    var small = HTTPCache(maxBytes: 100)
    for k in 0..<10 { small.store(url: url("http://e/\(k)"), method: u("GET"), head: head([HTTPHeader("Cache-Control", "max-age=60")]), body: [UInt8](repeating: 1, count: 20), now: now + k) }
    t.check(small.totalBytes <= 100 && small.lookup(url("http://e/9"), now: now + 10) != nil && small.lookup(url("http://e/0"), now: now + 10) == nil, "eviction oldest first")

    // MARK: pool
    t.section("pool")
    var pool = HTTPConnectionPool()
    let ka = HTTPOriginKey(url: url("http://a.com/")), kb = HTTPOriginKey(url: url("https://a.com/"))
    t.check(ka != kb && ka == HTTPOriginKey(url: url("http://a.com:80/x")), "origin keys")
    var ids: [Int] = []
    for _ in 0..<6 { if case .open(let id) = pool.acquire(ka, now: 0) { ids.append(id) } }
    t.equal(ids.count, 6, "6 connections opened")
    t.check(pool.acquire(ka, now: 0) == .wait, "7th waits")
    t.check(pool.acquire(kb, now: 0) != .wait, "other origin independent")
    t.check(pool.release(ids[0], reusable: true, now: 5), "release keep-alive")
    t.check(pool.acquire(ka, now: 6) == .reuse(ids[0]), "idle connection reused")
    t.check(!pool.release(ids[1], reusable: false, now: 6) && pool.drainClosable() == [ids[1]], "non-reusable closed")
    t.check({ if case .open = pool.acquire(ka, now: 6) { return true } else { return false } }(), "slot freed by close")
    pool.release(ids[2], reusable: true, now: 10)
    t.check(pool.acquire(kb, now: 71) != .reuse(ids[2]) && pool.drainClosable() == [ids[2]], "idle timeout expires")
    pool.remove(ids[3])
    t.check(pool.count(for: ka).busy == 4, "remove")
    var tiny = HTTPConnectionPool(); tiny.maxTotal = 2
    _ = tiny.acquire(ka, now: 0)
    if case .open(let first) = tiny.acquire(kb, now: 0) { tiny.release(first, reusable: true, now: 1) }
    let kc = HTTPOriginKey(url: url("http://c.com/"))
    t.check({ if case .open = tiny.acquire(kc, now: 2) { return true } else { return false } }() && tiny.drainClosable().count == 1, "total cap evicts idle")

    // MARK: fuzz
    t.section("fuzz")
    let seeds: [[UInt8]] = [cl, ch,
        u("HTTP/1.1 301 Moved\r\nLocation: /x\r\nTransfer-Encoding: gzip, chunked\r\nSet-Cookie: a=b; Path=/\r\n\r\n"),
        u("HTTP/1.0 200 OK\r\nX: a\r\n b\r\n\r\nrest"), u("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 204 No\r\n\r\n")]
    t.fuzz("http-parser", seeds: seeds, iterations: 40000) { data in
        var p = HTTPResponseParser(requestMethod: u(data.count % 7 == 0 ? "HEAD" : "GET"))
        var ev: [HTTPParseEvent] = []
        let cut = data.count / 2
        p.feed(Array(data[0..<cut]), &ev)
        p.feed(Array(data[cut...]), &ev)
        p.finish(&ev)
        var col = HTTPResponseCollector(); col.handle(ev)
        if let h = col.head { _ = h.contentEncodings; _ = h.wantsKeepAlive; _ = h.setCookies }
    }
    let cookieSeeds: [[UInt8]] = [u("a=b; Path=/; Domain=.example.com; Expires=Wed, 21 Oct 2099 07:28:00 GMT; Max-Age=60; Secure; HttpOnly"),
                                  u("x=y;;;=;Path;Domain=;Max-Age=-5; expires=garbage"), u("k=v; Path=/a/b/c; domain=www.example.com")]
    t.fuzz("http-cookie", seeds: cookieSeeds, iterations: 40000) { data in
        var j = HTTPCookieJar()
        j.setCookie(data, from: site, now: now)
        j.setCookie(data, from: url("http://localhost/x"), now: now)
        _ = j.cookieHeader(for: site, now: now + 100)
        _ = j.documentCookie(for: url("http://localhost/x/y"), now: now)
        _ = httpParseDate(data)
        var c = HTTPCache()
        c.store(url: site, method: u("GET"), head: head([HTTPHeader(u("Cache-Control"), data), HTTPHeader(u("Expires"), data), HTTPHeader(u("Age"), data)]), body: [], now: now)
        _ = httpRedirectDecision(status: 302, method: u("GET"), location: data, current: site, redirectsSoFar: 0)
    }
}
