// lib/browser: the browser's logic that needs no OS (Phase 8H). The app
// (user/browse) supplies the window, the event loop and the transports; this
// library has address-bar input normalization, history, the built-in pages,
// form submission, the page loader and an HTTP/1.1 client over abstract
// byte streams. Host-tested: `./run.sh --hosttest browser`.
//
// This file: what the user typed into the address bar -> a URL.

/// Search engine for address-bar text that isn't a URL.
let browserSearchPrefix = "https://lite.duckduckgo.com/lite/?q="

private func browserTrim(_ s: String) -> [UInt8] {
    var b = Array(s.utf8)
    while let l = b.last, l == 0x20 || l == 0x09 || l == 0x0a || l == 0x0d { b.removeLast() }
    var i = 0
    while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0a || b[i] == 0x0d { i += 1 }
    return Array(b[i...])
}

private func browserLower(_ b: [UInt8]) -> [UInt8] { b.map { $0 >= 0x41 && $0 <= 0x5a ? $0 + 32 : $0 } }

private func browserHasPrefix(_ b: [UInt8], _ p: String) -> Bool {
    let pb = Array(p.utf8)
    return b.count >= pb.count && browserLower(Array(b[0..<pb.count])) == pb
}

/// True for an IPv4 literal (with an optional :port), e.g. 10.0.2.2:8080.
private func browserLooksLikeIP(_ host: [UInt8]) -> Bool {
    var dots = 0
    for c in host {
        if c == 0x2e { dots += 1 } else if c == 0x3a { break } else if c < 0x30 || c > 0x39 { return false }
    }
    return dots == 3
}

/// The URL to load for address-bar text, or nil for nothing (empty input).
///
/// - A scheme the browser knows (http, https, file, about, view-source, data)
///   is parsed as is.
/// - "/path" is a local file (file:///path).
/// - Text with a space, or a single word without a dot (and not "localhost"),
///   is a search.
/// - Anything else gets a scheme: http:// for localhost and IP literals,
///   https:// otherwise ("example.com" -> "https://example.com/").
func browserNormalizeInput(_ input: String) -> String? {
    let b = browserTrim(input)
    if b.isEmpty { return nil }
    let s = String(decoding: b, as: UTF8.self)
    for scheme in ["http:", "https:", "file:", "about:", "view-source:", "data:"] where browserHasPrefix(b, scheme) {
        if scheme == "about:" || scheme == "view-source:" { return s }
        return URLRecord.parseOrNil(s)?.href ?? s
    }
    if b[0] == 0x2f { return URLRecord.parseOrNil("file://" + s)?.href ?? ("file://" + s) }
    var hasSpace = false, hasDot = false, hasColonOrSlash = false
    for c in b {
        if c == 0x20 || c == 0x09 { hasSpace = true }
        if c == 0x2e { hasDot = true }
        if c == 0x3a || c == 0x2f { hasColonOrSlash = true }
    }
    // host part: up to the first '/', '?' or '#'
    var host: [UInt8] = []
    for c in b { if c == 0x2f || c == 0x3f || c == 0x23 { break }; host.append(c) }
    let lowerHost = browserLower(host)
    let isLocal = lowerHost == Array("localhost".utf8) || browserHasPrefix(lowerHost, "localhost:")
    if hasSpace || (!hasDot && !isLocal && !hasColonOrSlash) {
        return browserSearchPrefix + String(decoding: urlFormEncodeComponent(b), as: UTF8.self)
    }
    let scheme = (isLocal || browserLooksLikeIP(host)) ? "http://" : "https://"
    if let u = URLRecord.parseOrNil(scheme + s), u.host != nil { return u.href }
    return browserSearchPrefix + String(decoding: urlFormEncodeComponent(b), as: UTF8.self)
}

/// The text to show in the address bar for a URL (as is: no elision).
func browserDisplayURL(_ url: String) -> String { url }
