private func fu(_ s: String) -> [UInt8] { Array(s.utf8) }
private func fs(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }
private func furl(_ x: String) -> URLRecord { URLRecord.parseOrNil(x)! }

private func fhas(_ hay: String, _ needle: String) -> Bool {
    let h = Array(hay.utf8), n = Array(needle.utf8)
    if n.isEmpty { return true }
    if h.count < n.count { return false }
    for i in 0...(h.count - n.count) where Array(h[i..<i + n.count]) == n { return true }
    return false
}

private func fetchFixedRandom(_ n: Int) -> [UInt8] { [UInt8](repeating: 7, count: n) }

/// Feed `wire` to a new plain exchange in `chunk`-byte pieces (then EOF if
/// asked); the head, the body and the final event.
private func fetchRun(_ wire: [UInt8], chunk: Int, eof: Bool = true, method: String = "GET")
    -> (head: HTTPResponseHead?, body: [UInt8], end: FetchEvent?, request: [UInt8]) {
    let ex = FetchExchange(url: furl("http://example.test/x?y=1"), method: method, tls: nil, random: fetchFixedRandom)
    ex.start()
    let request = ex.takeOutput()
    var head: HTTPResponseHead? = nil
    var body: [UInt8] = []
    var end: FetchEvent? = nil
    func take(_ events: [FetchEvent]) {
        for e in events {
            switch e {
            case .head(let h): head = h
            case .body(let b): body += b
            case .complete, .failed: end = e
            }
        }
    }
    var i = 0
    while i < wire.count {
        let j = min(wire.count, i + chunk)
        take(ex.receive(Array(wire[i..<j])))
        i = j
    }
    if eof { take(ex.receiveEOF()) }
    return (head, body, end, request)
}

private func isComplete(_ e: FetchEvent?) -> Bool {
    if case .complete? = e { return true }
    return false
}

private func failure(_ e: FetchEvent?) -> String? {
    if case .failed(let m)? = e { return m }
    return nil
}

private func chunked(_ data: [UInt8], size: Int) -> [UInt8] {
    var out: [UInt8] = []
    var i = 0
    let hex = Array("0123456789abcdef".utf8)
    while i < data.count {
        let n = min(size, data.count - i)
        var digits: [UInt8] = []
        var v = n
        repeat { digits.insert(hex[v & 15], at: 0); v >>= 4 } while v > 0
        out += digits + fu("\r\n") + Array(data[i..<i + n]) + fu("\r\n")
        i += n
    }
    return out + fu("0\r\n\r\n")
}

func libTests(_ t: Tests) {
    t.section("endpoint")
    let e1 = fetchEndpoint(furl("https://Example.COM/a"))
    t.check(e1?.host == "example.com" && e1?.port == 443 && e1?.tls == true && e1?.ipv4 == nil, "https default port")
    let e2 = fetchEndpoint(furl("http://10.0.2.2:8080/"))
    t.check(e2?.ipv4 == 0x0A00_0202 && e2?.port == 8080 && e2?.tls == false, "http IPv4 literal and port")
    t.check(fetchEndpoint(furl("ftp://x/")) == nil && fetchEndpoint(furl("http://[::1]/")) == nil, "other schemes and IPv6 refused")

    t.section("request")
    let req = fs(fetchRequestBytes(url: furl("http://example.test:81/p/q?r#frag")))
    t.check(req.hasPrefix("GET /p/q?r HTTP/1.1\r\nHost: example.test:81\r\n"), "request line and Host", req)
    t.check(fhas(req, "Connection: close\r\n") && fhas(req, "Accept-Encoding: gzip, deflate\r\n")
            && req.hasSuffix("\r\n\r\n"), "Connection: close, Accept-Encoding", req)

    t.section("plain")
    let body = fu("hello, wiffer\n")
    let resp = fu("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nContent-Type: text/plain\r\n\r\n") + body
    for chunk in [1, 7, 4096] {
        let r = fetchRun(resp, chunk: chunk, eof: false)
        t.check(r.head?.status == 200 && r.body == body && isComplete(r.end), "Content-Length in \(chunk)-byte pieces")
        t.check(fs(r.request).hasPrefix("GET /x?y=1 HTTP/1.1\r\n"), "the request went out")
    }
    let close = fetchRun(fu("HTTP/1.0 200 OK\r\n\r\nuntil close"), chunk: 3)
    t.check(close.body == fu("until close") && isComplete(close.end), "close-delimited body ends at EOF")
    let short = fetchRun(fu("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc"), chunk: 100)
    t.check(failure(short.end) != nil && short.body == fu("abc"), "a short body fails at EOF")
    let garbage = fetchRun(fu("SSH-2.0-OpenSSH\r\n\r\n"), chunk: 100)
    t.check(failure(garbage.end) != nil && garbage.head == nil, "not HTTP: fails")
    let head = fetchRun(fu("HTTP/1.1 200 OK\r\nContent-Length: 99\r\n\r\n"), chunk: 100, eof: false, method: "HEAD")
    t.check(isComplete(head.end) && head.body.isEmpty, "HEAD has no body")

    t.section("gzip")
    if let gz = t.readFile("lib/inflate/fixtures/big.l9.gz"), let raw = t.readFile("lib/inflate/fixtures/big.raw") {
        let wire = fu("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n\r\n") + chunked(gz, size: 1000)
        for chunk in [7, 1500, 1 << 20] {
            let r = fetchRun(wire, chunk: chunk, eof: false)
            t.check(r.body == raw && isComplete(r.end), "chunked gzip in \(chunk)-byte pieces decodes (\(raw.count) bytes)")
        }
        var bad = gz
        bad[bad.count / 2] ^= 0x55
        let b = fetchRun(fu("HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: \(bad.count)\r\n\r\n") + bad, chunk: 512)
        t.check(failure(b.end) != nil, "corrupt gzip fails", failure(b.end) ?? "")
    }
    if let z = t.readFile("lib/inflate/fixtures/big.l1.zlib"), let raw = t.readFile("lib/inflate/fixtures/big.raw") {
        let r = fetchRun(fu("HTTP/1.1 200 OK\r\nContent-Encoding: deflate\r\nContent-Length: \(z.count)\r\n\r\n") + z, chunk: 333)
        t.check(r.body == raw && isComplete(r.end), "deflate (zlib) decodes")
    }
    let br = fetchRun(fu("HTTP/1.1 200 OK\r\nContent-Encoding: br\r\nContent-Length: 1\r\n\r\nx"), chunk: 100)
    t.check(failure(br.end) != nil && br.body.isEmpty, "brotli is refused")

    t.section("redirect")
    let r = fetchRun(fu("HTTP/1.1 302 Found\r\nLocation: /next?a=b\r\nContent-Length: 0\r\n\r\n"), chunk: 100, eof: false)
    if let h = r.head, case .follow(let m, let u, _, _) = fetchRedirect(h, method: "GET", url: furl("http://example.test/x"), redirectsSoFar: 0) {
        t.check(m == fu("GET") && u.href == "http://example.test/next?a=b", "302 to a relative Location", u.href)
    } else {
        t.check(false, "302 is a redirect")
    }
    if let h = r.head, case .tooMany = fetchRedirect(h, method: "GET", url: furl("http://example.test/x"), redirectsSoFar: 10) {
        t.check(true, "the 11th redirect is refused")
    } else {
        t.check(false, "the 11th redirect is refused")
    }

    t.section("tls")
    var cfg = TLSClientConfig(serverName: "example.test", trust: .insecureAcceptAny, now: 1_800_000_000)
    cfg.alpn = ["http/1.1"]
    let ex = FetchExchange(url: furl("https://example.test/"), tls: cfg, random: fetchFixedRandom)
    ex.start()
    let hello = ex.takeOutput()
    t.check(hello.count > 100 && hello[0] == 22, "https: a ClientHello record goes out first (\(hello.count) bytes)")
    t.check(!fhas(fs(hello), "GET /"), "https: the request waits for the handshake")
    let ev = ex.receive(fu("HTTP/1.1 200 OK\r\n\r\n"))
    var failed = false
    for e in ev { if case .failed = e { failed = true } }
    t.check(failed && ex.transport.failure != nil, "https: a plaintext answer fails the handshake", ex.transport.failure ?? "")
    t.check(!ex.takeOutput().isEmpty, "https: an alert is queued for the server")
    let ex2 = FetchExchange(url: furl("https://example.test/"), tls: cfg, random: fetchFixedRandom)
    ex2.start()
    _ = ex2.takeOutput()
    var eofFailed = false
    for e in ex2.receiveEOF() { if case .failed = e { eofFailed = true } }
    t.check(eofFailed, "https: EOF during the handshake fails")
}
