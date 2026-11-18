// Cookie jar (RFC 6265), in memory, session only (no persistence).
//
//   var jar = HTTPCookieJar()
//   for sc in head.setCookies { jar.setCookie(sc, from: url, now: now) }
//   let header = jar.cookieHeader(for: url, now: now)          // for requests
//   let docCookie = jar.documentCookie(for: url, now: now)     // document.cookie
//
// Not implemented: SameSite enforcement, the public suffix list (a short
// built-in list of multi-label suffixes plus "no dot" stops the obvious
// supercookies), persistence, __Host-/__Secure- prefixes.

struct HTTPCookie: Equatable {
    var name: [UInt8]
    var value: [UInt8]
    var domain: [UInt8]
    var hostOnly: Bool
    var path: [UInt8]
    /// Unix seconds; nil = session cookie.
    var expires: Int?
    var secure: Bool
    var httpOnly: Bool
    var creation: Int
    var lastAccess: Int
}

let httpCookieMaxPerDomain = 50
let httpCookieMaxTotal = 3000
let httpCookieMaxPairBytes = 4096
let httpCookieMaxAttributeBytes = 1024

/// RFC 6265 section 5.1.3.
func httpDomainMatches(host: [UInt8], domain: [UInt8]) -> Bool {
    if host == domain { return true }
    if host.count <= domain.count { return false }
    let off = host.count - domain.count
    if host[off - 1] != 0x2e { return false }
    for i in 0..<domain.count where host[off + i] != domain[i] { return false }
    // never domain-match IP addresses by suffix
    return !httpLooksLikeIP(host)
}

func httpLooksLikeIP(_ h: [UInt8]) -> Bool {
    if h.isEmpty { return false }
    if h[0] == 0x5b { return true }
    var digitsOrDots = true
    for c in h where !(c == 0x2e || (c >= 0x30 && c <= 0x39)) { digitsOrDots = false; break }
    return digitsOrDots
}

/// RFC 6265 section 5.1.4.
func httpPathMatches(requestPath: [UInt8], cookiePath: [UInt8]) -> Bool {
    if requestPath == cookiePath { return true }
    if requestPath.count > cookiePath.count {
        for i in 0..<cookiePath.count where requestPath[i] != cookiePath[i] { return false }
        if cookiePath.last == 0x2f { return true }
        if requestPath[cookiePath.count] == 0x2f { return true }
    }
    return false
}

/// RFC 6265 section 5.1.4 default-path.
func httpDefaultPath(_ requestPath: [UInt8]) -> [UInt8] {
    if requestPath.isEmpty || requestPath[0] != 0x2f { return [0x2f] }
    var last = 0
    for (i, c) in requestPath.enumerated() where c == 0x2f { last = i }
    if last == 0 { return [0x2f] }
    return Array(requestPath[0..<last])
}

private let httpPublicSuffixes: [String] = [
    "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "com.au", "net.au", "org.au", "co.jp", "ne.jp",
    "or.jp", "com.br", "co.nz", "co.in", "co.za", "com.cn", "com.mx", "com.tr", "co.kr", "com.tw",
    "github.io", "herokuapp.com", "blogspot.com", "appspot.com",
]

private func httpIsPublicSuffix(_ d: [UInt8]) -> Bool {
    if !d.contains(0x2e) { return true } // a bare TLD (or "localhost")
    for s in httpPublicSuffixes where Array(s.utf8) == d { return true }
    return false
}

struct HTTPCookieJar {
    private(set) var cookies: [HTTPCookie] = []
    private var counter = 0

    init() {}

    var count: Int { cookies.count }

    mutating func clear() { cookies = [] }

    mutating func removeExpired(now: Int) {
        cookies.removeAll { c in if let e = c.expires { return e <= now } else { return false } }
    }

    /// Process one Set-Cookie header value received from `url`. `fromScript`
    /// is for document.cookie writes (HttpOnly cookies can't be set or
    /// replaced). Returns true if the jar changed (stored or deleted).
    @discardableResult
    mutating func setCookie(_ header: [UInt8], from url: URLRecord, now: Int, fromScript: Bool = false) -> Bool {
        if header.count > httpCookieMaxPairBytes + 4 * httpCookieMaxAttributeBytes { return false }
        for c in header where c == 0x00 || c == 0x0d || c == 0x0a { return false }
        // split into name-value pair and attributes
        var parts: [[UInt8]] = [[]]
        for c in header { if c == 0x3b { parts.append([]) } else { parts[parts.count - 1].append(c) } }
        let pair = parts[0]
        guard let eq = pair.firstIndex(of: 0x3d) else { return false }
        let name = httpTrim(Array(pair[0..<eq]))
        let value = httpTrim(Array(pair[(eq + 1)...]))
        if name.isEmpty || name.count + value.count > httpCookieMaxPairBytes { return false }
        for c in name + value where (c < 0x20 && c != 0x09) || c == 0x7f { return false }

        var domainAttr: [UInt8]? = nil
        var pathAttr: [UInt8]? = nil
        var expires: Int? = nil
        var maxAge: Int? = nil
        var secure = false, httpOnly = false
        var k = 1
        while k < parts.count {
            let attr = parts[k]
            k += 1
            var an = attr, av: [UInt8] = []
            if let e = attr.firstIndex(of: 0x3d) { an = Array(attr[0..<e]); av = Array(attr[(e + 1)...]) }
            an = httpLowercased(httpTrim(an)); av = httpTrim(av)
            if av.count > httpCookieMaxAttributeBytes { continue }
            switch String(decoding: an, as: UTF8.self) {
            case "expires": if let t = httpParseDate(av) { expires = t }
            case "max-age":
                var digits = av
                var neg = false
                if digits.first == 0x2d { neg = true; digits.removeFirst() }
                if let v = httpParseDecimal(digits, limit: 1 << 40) { maxAge = neg ? -v : v }
            case "domain":
                var d = httpLowercased(av)
                if d.first == 0x2e { d.removeFirst() }
                domainAttr = d.isEmpty ? nil : d
            case "path": pathAttr = (av.first == 0x2f) ? av : nil
            case "secure": secure = true
            case "httponly": httpOnly = true
            default: break
            }
        }

        let host = url.hostBytes
        let isSecureURL = url.scheme == Array("https".utf8) || url.scheme == Array("wss".utf8)
        if secure && !isSecureURL { return false }
        if fromScript && httpOnly { return false }

        var domain = host
        var hostOnly = true
        if let d = domainAttr {
            if httpIsPublicSuffix(d) && d != host { return false }
            if !httpDomainMatches(host: host, domain: d) { return false }
            if httpLooksLikeIP(host) && d != host { return false }
            domain = d
            hostOnly = false
        }
        let path = pathAttr ?? httpDefaultPath(url.pathBytes)

        var expiry: Int? = nil
        if let ma = maxAge { expiry = ma <= 0 ? 0 : now + min(ma, 400 * 86400) }
        else if let e = expires { expiry = e }
        let expired = (expiry ?? Int.max) <= now

        // find an existing cookie with the same identity
        var existing = -1
        for (i, c) in cookies.enumerated() where c.name == name && c.domain == domain && c.path == path && c.hostOnly == hostOnly {
            existing = i; break
        }
        if existing >= 0 {
            if fromScript && cookies[existing].httpOnly { return false }
            if !isSecureURL && cookies[existing].secure { return false }
        } else if !isSecureURL {
            // an insecure origin can't shadow a secure cookie of the same name
            for c in cookies where c.secure && c.name == name && httpDomainMatches(host: host, domain: c.domain)
                && httpPathMatches(requestPath: path, cookiePath: c.path) { return false }
        }
        if expired {
            if existing >= 0 { cookies.remove(at: existing); return true }
            return false
        }
        counter += 1
        var cookie = HTTPCookie(name: name, value: value, domain: domain, hostOnly: hostOnly, path: path,
                                expires: expiry, secure: secure, httpOnly: httpOnly,
                                creation: counter, lastAccess: counter)
        if existing >= 0 {
            cookie.creation = cookies[existing].creation
            cookies[existing] = cookie
        } else {
            cookies.append(cookie)
            evict(domain: domain, now: now)
        }
        return true
    }

    private mutating func evict(domain: [UInt8], now: Int) {
        removeExpired(now: now)
        var same: [Int] = []
        for (i, c) in cookies.enumerated() where c.domain == domain { same.append(i) }
        if same.count > httpCookieMaxPerDomain {
            var oldest = same[0]
            for i in same where cookies[i].lastAccess < cookies[oldest].lastAccess { oldest = i }
            cookies.remove(at: oldest)
        }
        if cookies.count > httpCookieMaxTotal {
            var oldest = 0
            for i in 0..<cookies.count where cookies[i].lastAccess < cookies[oldest].lastAccess { oldest = i }
            cookies.remove(at: oldest)
        }
    }

    private func matching(for url: URLRecord, now: Int, includeHTTPOnly: Bool) -> [Int] {
        let host = url.hostBytes
        let path = url.pathBytes.isEmpty ? [0x2f] : url.pathBytes
        let secureURL = url.scheme == Array("https".utf8) || url.scheme == Array("wss".utf8)
        var idx: [Int] = []
        for (i, c) in cookies.enumerated() {
            if let e = c.expires, e <= now { continue }
            if c.hostOnly ? host != c.domain : !httpDomainMatches(host: host, domain: c.domain) { continue }
            if !httpPathMatches(requestPath: path, cookiePath: c.path) { continue }
            if c.secure && !secureURL { continue }
            if c.httpOnly && !includeHTTPOnly { continue }
            idx.append(i)
        }
        // longer paths first, then earlier creation
        idx.sort { a, b in
            let ca = cookies[a], cb = cookies[b]
            if ca.path.count != cb.path.count { return ca.path.count > cb.path.count }
            return ca.creation < cb.creation
        }
        return idx
    }

    /// The Cookie request header value for `url`, or nil if no cookie applies.
    mutating func cookieHeader(for url: URLRecord, now: Int, includeHTTPOnly: Bool = true) -> [UInt8]? {
        let idx = matching(for: url, now: now, includeHTTPOnly: includeHTTPOnly)
        if idx.isEmpty { return nil }
        var out: [UInt8] = []
        counter += 1
        for (n, i) in idx.enumerated() {
            if n > 0 { out += [0x3b, 0x20] }
            out += cookies[i].name; out.append(0x3d); out += cookies[i].value
            cookies[i].lastAccess = counter
        }
        return out
    }

    /// document.cookie getter: no HttpOnly cookies.
    mutating func documentCookie(for url: URLRecord, now: Int) -> [UInt8] {
        cookieHeader(for: url, now: now, includeHTTPOnly: false) ?? []
    }
}
