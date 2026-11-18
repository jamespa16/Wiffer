// lib/http: HTTP/1.1 client logic with no I/O (ROADMAP Phase 8B).
//
// Files: headers.swift (this), request.swift, parser.swift, decoder.swift,
// redirect.swift, date.swift, cookies.swift, cache.swift, pool.swift.
// The browser's event loop owns the sockets; these types are state machines
// and policy objects it drives. No clock either: callers pass `now` as Unix
// seconds (Int).

struct HTTPHeader: Equatable {
    var name: [UInt8]
    var value: [UInt8]
    init(_ name: [UInt8], _ value: [UInt8]) { self.name = name; self.value = value }
    init(_ name: String, _ value: String) { self.name = Array(name.utf8); self.value = Array(value.utf8) }
}

@inline(__always) func httpLower(_ c: UInt8) -> UInt8 { (c >= 0x41 && c <= 0x5a) ? c + 32 : c }

func httpEqualsIgnoreCase(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    if a.count != b.count { return false }
    for i in 0..<a.count where httpLower(a[i]) != httpLower(b[i]) { return false }
    return true
}

func httpEqualsIgnoreCase(_ a: [UInt8], _ b: String) -> Bool { httpEqualsIgnoreCase(a, Array(b.utf8)) }

@inline(__always) func httpIsOWS(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 }

func httpTrim(_ s: [UInt8]) -> [UInt8] {
    var a = 0, b = s.count
    while a < b && httpIsOWS(s[a]) { a += 1 }
    while b > a && httpIsOWS(s[b - 1]) { b -= 1 }
    return a == 0 && b == s.count ? s : Array(s[a..<b])
}

func httpLowercased(_ s: [UInt8]) -> [UInt8] { s.map { httpLower($0) } }

/// RFC 7230 token characters.
func httpIsTokenByte(_ c: UInt8) -> Bool {
    switch c {
    case 0x30...0x39, 0x41...0x5a, 0x61...0x7a: return true
    case 0x21, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2a, 0x2b, 0x2d, 0x2e, 0x5e, 0x5f, 0x60, 0x7c, 0x7e: return true
    default: return false
    }
}

/// Split a comma-separated header value into trimmed, non-empty elements.
func httpSplitList(_ v: [UInt8]) -> [[UInt8]] {
    var out: [[UInt8]] = []
    var cur: [UInt8] = []
    var inQuote = false
    for c in v {
        if c == 0x22 { inQuote.toggle() }
        if c == 0x2c && !inQuote {
            let t = httpTrim(cur); if !t.isEmpty { out.append(t) }
            cur = []
        } else { cur.append(c) }
    }
    let t = httpTrim(cur); if !t.isEmpty { out.append(t) }
    return out
}

/// Parse an unsigned decimal; nil on empty, non-digit, or more than `limit`.
func httpParseDecimal(_ s: [UInt8], limit: Int = 1 << 50) -> Int? {
    if s.isEmpty || s.count > 19 { return nil }
    var v = 0
    for c in s {
        guard c >= 0x30 && c <= 0x39 else { return nil }
        v = v * 10 + Int(c - 0x30)
        if v > limit { return nil }
    }
    return v
}

extension Array where Element == HTTPHeader {
    /// All values of a header (case-insensitive), in order.
    func httpValues(_ name: String) -> [[UInt8]] {
        let n = [UInt8](name.utf8)
        var out: [[UInt8]] = []
        for h in self where httpEqualsIgnoreCase(h.name, n) { out.append(h.value) }
        return out
    }

    /// Values joined with ", " (right for list headers; use httpValues for
    /// Set-Cookie).
    func httpValue(_ name: String) -> [UInt8]? {
        let vs = httpValues(name)
        if vs.isEmpty { return nil }
        var out = vs[0]
        var i = 1
        while i < vs.count { out += [0x2c, 0x20]; out += vs[i]; i += 1 }
        return out
    }

    func httpHas(_ name: String) -> Bool {
        let n = [UInt8](name.utf8)
        for h in self where httpEqualsIgnoreCase(h.name, n) { return true }
        return false
    }
}
