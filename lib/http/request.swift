// Request building.

struct HTTPRequestOptions {
    var userAgent = "Wiffer/0.1"
    var accept = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
    var acceptEncoding = "gzip, deflate"
    var keepAlive = true
    init() {}
}

private func httpSanitize(_ s: [UInt8]) -> [UInt8] {
    // header injection guard: CR, LF and NUL never reach the wire
    var out: [UInt8] = []
    out.reserveCapacity(s.count)
    for c in s { out.append(c == 0x0d || c == 0x0a || c == 0x00 ? 0x20 : c) }
    return out
}

private func httpIsToken(_ s: [UInt8]) -> Bool {
    if s.isEmpty { return false }
    for c in s where !httpIsTokenByte(c) { return false }
    return true
}

/// "Host" header value for a URL: host, plus ":port" when not the default.
func httpHostHeader(_ url: URLRecord) -> [UInt8] {
    var h = url.hostBytes
    if let p = url.port { h.append(0x3a); h += urlDecimal(Int(p)) }
    return h
}

/// Build the request bytes (request line + headers + body). `cookie` is the
/// value from HTTPCookieJar.cookieHeader. `headers` the caller supplies
/// override the defaults of the same name. For a POST with a body,
/// Content-Length is added, and Content-Type from `contentType` (form posts:
/// "application/x-www-form-urlencoded" with body urlFormEncode(...)).
func httpBuildRequest(method: [UInt8], url: URLRecord, headers: [HTTPHeader] = [],
                      body: [UInt8] = [], contentType: [UInt8]? = nil,
                      cookie: [UInt8]? = nil,
                      options: HTTPRequestOptions = HTTPRequestOptions()) -> [UInt8] {
    var m = method.map { c -> UInt8 in (c >= 0x61 && c <= 0x7a) ? c - 32 : c }
    if !httpIsToken(m) { m = Array("GET".utf8) }
    var out = m
    out.append(0x20)
    out += httpSanitize(url.requestTarget)
    out += Array(" HTTP/1.1\r\n".utf8)

    func line(_ n: String, _ v: [UInt8]) {
        out += Array(n.utf8); out += [0x3a, 0x20]; out += httpSanitize(v); out += [0x0d, 0x0a]
    }
    func overridden(_ n: String) -> Bool { headers.httpHas(n) }

    line("Host", httpHostHeader(url))
    if !overridden("User-Agent") { line("User-Agent", Array(options.userAgent.utf8)) }
    if !overridden("Accept") { line("Accept", Array(options.accept.utf8)) }
    if !overridden("Accept-Encoding") && !options.acceptEncoding.isEmpty {
        line("Accept-Encoding", Array(options.acceptEncoding.utf8))
    }
    if !overridden("Connection") { line("Connection", Array((options.keepAlive ? "keep-alive" : "close").utf8)) }
    if let c = cookie, !c.isEmpty, !overridden("Cookie") { line("Cookie", c) }
    let hasBody = !body.isEmpty || m == Array("POST".utf8) || m == Array("PUT".utf8)
    if hasBody {
        if let ct = contentType, !overridden("Content-Type") { line("Content-Type", ct) }
        line("Content-Length", urlDecimal(body.count))
    }
    for h in headers {
        if httpEqualsIgnoreCase(h.name, "Host") || httpEqualsIgnoreCase(h.name, "Content-Length")
            || !httpIsToken(h.name) { continue }
        out += h.name; out += [0x3a, 0x20]; out += httpSanitize(h.value); out += [0x0d, 0x0a]
    }
    out += [0x0d, 0x0a]
    out += body
    return out
}
