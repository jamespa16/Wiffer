// Redirect policy.

enum HTTPRedirectDecision {
    /// Not a redirect (or no usable Location): deliver the response.
    case notRedirect
    /// Follow: issue `method` to `url`. When `dropBody` is true the method
    /// changed to GET, so omit the request body and Content-* headers.
    /// `crossOrigin`: drop Authorization-like headers.
    case follow(method: [UInt8], url: URLRecord, dropBody: Bool, crossOrigin: Bool)
    case tooMany
    /// Location unparsable or a non-http(s) scheme.
    case invalid
}

let httpMaxRedirects = 10

/// `redirectsSoFar` counts redirects already followed for this request.
func httpRedirectDecision(status: Int, method: [UInt8], location: [UInt8]?,
                          current: URLRecord, redirectsSoFar: Int,
                          maxRedirects: Int = httpMaxRedirects) -> HTTPRedirectDecision {
    switch status {
    case 301, 302, 303, 307, 308: break
    default: return .notRedirect
    }
    guard let raw = location else { return .notRedirect }
    let loc = httpTrim(raw)
    if loc.isEmpty { return .notRedirect }
    if redirectsSoFar >= maxRedirects { return .tooMany }
    guard var next = URLRecord.parseOrNil(loc, base: current) else { return .invalid }
    guard next.scheme == Array("http".utf8) || next.scheme == Array("https".utf8) else { return .invalid }
    if next.fragment == nil { next.fragment = current.fragment }

    let m = method.map { c -> UInt8 in (c >= 0x61 && c <= 0x7a) ? c - 32 : c }
    let isGetOrHead = m == Array("GET".utf8) || m == Array("HEAD".utf8)
    var newMethod = m
    var drop = false
    if status == 303 && !isGetOrHead { newMethod = Array("GET".utf8); drop = true }
    else if (status == 301 || status == 302) && m == Array("POST".utf8) { newMethod = Array("GET".utf8); drop = true }
    return .follow(method: newMethod, url: next, dropBody: drop, crossOrigin: !next.sameOrigin(as: current))
}
