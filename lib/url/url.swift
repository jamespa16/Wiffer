// lib/url: WHATWG URL parsing (ROADMAP Phase 8B).
//
//   URLRecord.parse(bytes, base:) throws(URLError) -> URLRecord
//   record.href, .origin, .protocol, .host, .pathname, .search, .hash, ...
//
// Implements the basic URL parser state machine (no setters / state
// overrides). Hosts: domains (ASCII only: non-ASCII throws .nonASCIIHost, no
// IDNA), IPv4 (dotted, hex, octal, short forms), IPv6, opaque hosts for
// non-special schemes, and the empty host of file: URLs. Everything works on
// bytes and never traps; input length is capped at urlMaxLength.

let urlMaxLength = 1 << 20

enum URLError: Error, Equatable {
    case tooLong
    case missingScheme          // no base and no scheme
    case invalidBase            // relative reference against an opaque-path base
    case emptyHost
    case invalidHost            // forbidden host code point
    case invalidIPv4
    case invalidIPv6
    case nonASCIIHost           // IDNA is not implemented
    case invalidPort
    case invalidCredentials     // "@" with an empty host
}

enum URLHost: Equatable {
    case domain([UInt8])        // lowercase ASCII
    case ipv4(UInt32)
    case ipv6([UInt16])         // 8 pieces
    case opaque([UInt8])        // host of a non-special URL (percent-encoded)
    case empty                  // file:///x

    var serialized: [UInt8] {
        switch self {
        case .domain(let d), .opaque(let d): return d
        case .empty: return []
        case .ipv4(let a): return urlSerializeIPv4(a)
        case .ipv6(let p): return [0x5b] + urlSerializeIPv6(p) + [0x5d]
        }
    }
}

struct URLRecord: Equatable {
    var scheme: [UInt8] = []
    var username: [UInt8] = []
    var password: [UInt8] = []
    var host: URLHost? = nil
    /// nil when absent or equal to the scheme's default port.
    var port: UInt16? = nil
    var hasOpaquePath = false
    var opaquePath: [UInt8] = []
    var path: [[UInt8]] = []
    var query: [UInt8]? = nil
    var fragment: [UInt8]? = nil

    // MARK: parsing

    static func parse(_ input: [UInt8], base: URLRecord? = nil) throws(URLError) -> URLRecord {
        try urlBasicParse(input, base: base)
    }

    static func parse(_ input: String, base: URLRecord? = nil) throws(URLError) -> URLRecord {
        try urlBasicParse(Array(input.utf8), base: base)
    }

    static func parseOrNil(_ input: [UInt8], base: URLRecord? = nil) -> URLRecord? {
        do { return try urlBasicParse(input, base: base) } catch { return nil }
    }

    static func parseOrNil(_ input: String, base: URLRecord? = nil) -> URLRecord? {
        parseOrNil(Array(input.utf8), base: base)
    }

    /// Resolve a (possibly relative) reference against this URL.
    func resolve(_ reference: [UInt8]) -> URLRecord? {
        URLRecord.parseOrNil(reference, base: self)
    }

    func resolve(_ reference: String) -> URLRecord? { resolve(Array(reference.utf8)) }

    // MARK: components

    var isSpecial: Bool { urlIsSpecialScheme(scheme) }

    /// The port in effect: explicit, else the scheme default.
    var effectivePort: UInt16? { port ?? urlDefaultPort(scheme) }

    var hostBytes: [UInt8] { host?.serialized ?? [] }

    var pathBytes: [UInt8] {
        if hasOpaquePath { return opaquePath }
        var out: [UInt8] = []
        for seg in path { out.append(0x2f); out += seg }
        return out
    }

    func serializedBytes(excludeFragment: Bool = false) -> [UInt8] {
        var out = scheme
        out.append(0x3a)
        if let h = host {
            out.append(0x2f); out.append(0x2f)
            if !username.isEmpty || !password.isEmpty {
                out += username
                if !password.isEmpty { out.append(0x3a); out += password }
                out.append(0x40)
            }
            out += h.serialized
            if let p = port { out.append(0x3a); out += urlDecimal(Int(p)) }
        } else if !hasOpaquePath && path.count > 1 && path[0].isEmpty {
            out.append(0x2f); out.append(0x2e)
        }
        out += pathBytes
        if let q = query { out.append(0x3f); out += q }
        if !excludeFragment, let f = fragment { out.append(0x23); out += f }
        return out
    }

    var hrefBytes: [UInt8] { serializedBytes() }
    var href: String { String(decoding: serializedBytes(), as: UTF8.self) }
    var protocolString: String { String(decoding: scheme + [0x3a], as: UTF8.self) }
    var hostname: String { String(decoding: hostBytes, as: UTF8.self) }
    var hostWithPort: String {
        var b = hostBytes
        if let p = port { b.append(0x3a); b += urlDecimal(Int(p)) }
        return String(decoding: b, as: UTF8.self)
    }
    var portString: String { port.map { String(decoding: urlDecimal(Int($0)), as: UTF8.self) } ?? "" }
    var pathname: String { String(decoding: pathBytes, as: UTF8.self) }
    var search: String {
        guard let q = query, !q.isEmpty else { return "" }
        return String(decoding: [0x3f] + q, as: UTF8.self)
    }
    var hash: String {
        guard let f = fragment, !f.isEmpty else { return "" }
        return String(decoding: [0x23] + f, as: UTF8.self)
    }

    /// path + query, the request target of an HTTP origin-form request.
    var requestTarget: [UInt8] {
        var out = pathBytes
        if out.isEmpty || out[0] != 0x2f { out.insert(0x2f, at: 0) }
        if let q = query { out.append(0x3f); out += q }
        return out
    }

    /// Serialized origin ("https://example.com", "null" for opaque origins).
    var origin: String {
        let s = String(decoding: scheme, as: UTF8.self)
        switch s {
        case "http", "https", "ws", "wss", "ftp":
            var out = scheme + [0x3a, 0x2f, 0x2f] + hostBytes
            if let p = port { out.append(0x3a); out += urlDecimal(Int(p)) }
            return String(decoding: out, as: UTF8.self)
        case "blob":
            if let inner = URLRecord.parseOrNil(pathBytes), inner.scheme == Array("http".utf8) || inner.scheme == Array("https".utf8) {
                return inner.origin
            }
            return "null"
        default: return "null"
        }
    }

    /// Same scheme, host and effective port.
    func sameOrigin(as o: URLRecord) -> Bool {
        scheme == o.scheme && hostBytes == o.hostBytes && effectivePort == o.effectivePort
    }
}

// MARK: schemes

func urlIsSpecialScheme(_ s: [UInt8]) -> Bool {
    switch s.count {
    case 2: return s == [0x77, 0x73]                                  // ws
    case 3: return s == Array("ftp".utf8) || s == Array("wss".utf8)
    case 4: return s == Array("file".utf8) || s == Array("http".utf8)
    case 5: return s == Array("https".utf8)
    default: return false
    }
}

func urlDefaultPort(_ s: [UInt8]) -> UInt16? {
    if s == Array("http".utf8) || s == Array("ws".utf8) { return 80 }
    if s == Array("https".utf8) || s == Array("wss".utf8) { return 443 }
    if s == Array("ftp".utf8) { return 21 }
    return nil
}

func urlDecimal(_ v: Int) -> [UInt8] {
    if v <= 0 { return [0x30] }
    var d: [UInt8] = []
    var x = v
    while x > 0 { d.append(UInt8(0x30 + x % 10)); x /= 10 }
    return d.reversed()
}

// MARK: percent-encoding

enum URLEncodeSet {
    case c0Control, fragment, query, specialQuery, path, userinfo, component, formURLEncoded
}

@inline(__always) private func urlInC0(_ c: UInt8) -> Bool { c <= 0x1f || c > 0x7e }

func urlInEncodeSet(_ c: UInt8, _ set: URLEncodeSet) -> Bool {
    if urlInC0(c) { return true }
    switch set {
    case .c0Control: return false
    case .fragment: return c == 0x20 || c == 0x22 || c == 0x3c || c == 0x3e || c == 0x60
    case .query: return c == 0x20 || c == 0x22 || c == 0x23 || c == 0x3c || c == 0x3e
    case .specialQuery: return c == 0x20 || c == 0x22 || c == 0x23 || c == 0x3c || c == 0x3e || c == 0x27
    case .path:
        return c == 0x20 || c == 0x22 || c == 0x23 || c == 0x3c || c == 0x3e || c == 0x3f
            || c == 0x5e || c == 0x60 || c == 0x7b || c == 0x7d
    case .userinfo:
        if urlInEncodeSet(c, .path) { return true }
        return c == 0x2f || c == 0x3a || c == 0x3b || c == 0x3d || c == 0x40
            || (c >= 0x5b && c <= 0x5e) || c == 0x7c
    case .component:
        if urlInEncodeSet(c, .userinfo) { return true }
        return (c >= 0x24 && c <= 0x26) || c == 0x2b || c == 0x2c
    case .formURLEncoded:
        if urlInEncodeSet(c, .component) { return true }
        return c == 0x21 || (c >= 0x27 && c <= 0x29) || c == 0x7e
    }
}

private let urlHexUpper: [UInt8] = Array("0123456789ABCDEF".utf8)

@inline(__always) func urlAppendPercent(_ c: UInt8, to out: inout [UInt8]) {
    out.append(0x25)
    out.append(urlHexUpper[Int(c >> 4)])
    out.append(urlHexUpper[Int(c & 15)])
}

func urlPercentEncode(_ bytes: [UInt8], _ set: URLEncodeSet) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    for c in bytes {
        if urlInEncodeSet(c, set) { urlAppendPercent(c, to: &out) } else { out.append(c) }
    }
    return out
}

@inline(__always) func urlHexValue(_ c: UInt8) -> Int {
    switch c {
    case 0x30...0x39: return Int(c) - 0x30
    case 0x41...0x46: return Int(c) - 0x41 + 10
    case 0x61...0x66: return Int(c) - 0x61 + 10
    default: return -1
    }
}

func urlPercentDecode(_ bytes: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    var i = 0
    let n = bytes.count
    while i < n {
        let c = bytes[i]
        if c == 0x25 && i + 2 < n {
            let h = urlHexValue(bytes[i + 1]), l = urlHexValue(bytes[i + 2])
            if h >= 0 && l >= 0 { out.append(UInt8(h * 16 + l)); i += 3; continue }
        }
        out.append(c)
        i += 1
    }
    return out
}

// MARK: application/x-www-form-urlencoded

struct URLFormPair: Equatable {
    var name: [UInt8]
    var value: [UInt8]
    init(_ name: [UInt8], _ value: [UInt8]) { self.name = name; self.value = value }
    init(_ name: String, _ value: String) { self.name = Array(name.utf8); self.value = Array(value.utf8) }
}

/// Percent-encode for a form field: space becomes "+", unreserved bytes
/// (alnum and *-._) pass through, everything else is %XX.
func urlFormEncodeComponent(_ bytes: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    for c in bytes {
        if c == 0x20 { out.append(0x2b) }
        else if c == 0x2a || c == 0x2d || c == 0x2e || c == 0x5f
            || (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) {
            out.append(c)
        } else { urlAppendPercent(c, to: &out) }
    }
    return out
}

func urlFormEncode(_ pairs: [URLFormPair]) -> [UInt8] {
    var out: [UInt8] = []
    for (i, p) in pairs.enumerated() {
        if i > 0 { out.append(0x26) }
        out += urlFormEncodeComponent(p.name)
        out.append(0x3d)
        out += urlFormEncodeComponent(p.value)
    }
    return out
}

func urlFormDecode(_ input: [UInt8]) -> [URLFormPair] {
    var pairs: [URLFormPair] = []
    var i = 0
    let n = input.count
    while i <= n {
        var j = i
        while j < n && input[j] != 0x26 { j += 1 }
        if j > i {
            var k = i
            while k < j && input[k] != 0x3d { k += 1 }
            var name = Array(input[i..<k])
            var value = k < j ? Array(input[(k + 1)..<j]) : []
            for x in 0..<name.count where name[x] == 0x2b { name[x] = 0x20 }
            for x in 0..<value.count where value[x] == 0x2b { value[x] = 0x20 }
            pairs.append(URLFormPair(urlPercentDecode(name), urlPercentDecode(value)))
        }
        i = j + 1
    }
    return pairs
}

// MARK: hosts

private func urlIsForbiddenHostByte(_ c: UInt8) -> Bool {
    switch c {
    case 0x00, 0x09, 0x0a, 0x0d, 0x20, 0x23, 0x2f, 0x3a, 0x3c, 0x3e, 0x3f, 0x40, 0x5b, 0x5c, 0x5d, 0x5e, 0x7c:
        return true
    default: return false
    }
}

private func urlIsForbiddenDomainByte(_ c: UInt8) -> Bool {
    urlIsForbiddenHostByte(c) || c <= 0x1f || c == 0x25 || c == 0x7f
}

func urlSerializeIPv4(_ a: UInt32) -> [UInt8] {
    var out: [UInt8] = []
    for i in 0..<4 {
        if i > 0 { out.append(0x2e) }
        out += urlDecimal(Int((a >> UInt32(24 - 8 * i)) & 0xff))
    }
    return out
}

func urlSerializeIPv6(_ p: [UInt16]) -> [UInt8] {
    // find the first longest run of zero pieces (length > 1)
    var bestStart = -1, bestLen = 0
    var i = 0
    while i < 8 {
        if p[i] == 0 {
            var j = i
            while j < 8 && p[j] == 0 { j += 1 }
            if j - i > bestLen { bestStart = i; bestLen = j - i }
            i = j
        } else { i += 1 }
    }
    if bestLen < 2 { bestStart = -1 }
    let hex = Array("0123456789abcdef".utf8)
    var out: [UInt8] = []
    var ignore0 = false
    for k in 0..<8 {
        if ignore0 && p[k] == 0 { continue }
        ignore0 = false
        if bestStart == k {
            out += k == 0 ? [0x3a, 0x3a] : [0x3a]
            ignore0 = true
            continue
        }
        var digits: [UInt8] = []
        var v = p[k]
        repeat { digits.append(hex[Int(v & 15)]); v >>= 4 } while v != 0
        out += digits.reversed()
        if k != 7 { out.append(0x3a) }
    }
    return out
}

private func urlParseIPv6(_ s: [UInt8]) -> [UInt16]? {
    var addr = [UInt16](repeating: 0, count: 8)
    var piece = 0
    var compress = -1
    var p = 0
    let n = s.count
    func at(_ i: Int) -> Int { i < n ? Int(s[i]) : -1 }
    if at(p) == 0x3a {
        if at(p + 1) != 0x3a { return nil }
        p += 2; piece += 1; compress = piece
    }
    while at(p) != -1 {
        if piece == 8 { return nil }
        if at(p) == 0x3a {
            if compress != -1 { return nil }
            p += 1; piece += 1; compress = piece
            continue
        }
        var value = 0, length = 0
        while length < 4 && at(p) != -1 && urlHexValue(UInt8(at(p))) >= 0 {
            value = value * 16 + urlHexValue(UInt8(at(p)))
            p += 1; length += 1
        }
        if at(p) == 0x2e {
            if length == 0 { return nil }
            p -= length
            if piece > 6 { return nil }
            var seen = 0
            while at(p) != -1 {
                var v4 = -1
                if seen > 0 {
                    if at(p) == 0x2e && seen < 4 { p += 1 } else { return nil }
                }
                if at(p) == -1 || at(p) < 0x30 || at(p) > 0x39 { return nil }
                while at(p) >= 0x30 && at(p) <= 0x39 {
                    let num = at(p) - 0x30
                    if v4 == -1 { v4 = num } else if v4 == 0 { return nil } else { v4 = v4 * 10 + num }
                    if v4 > 255 { return nil }
                    p += 1
                }
                addr[piece] = UInt16(Int(addr[piece]) * 0x100 + v4)
                seen += 1
                if seen == 2 || seen == 4 { piece += 1 }
            }
            if seen != 4 { return nil }
            break
        } else if at(p) == 0x3a {
            p += 1
            if at(p) == -1 { return nil }
        } else if at(p) != -1 { return nil }
        addr[piece] = UInt16(value)
        piece += 1
    }
    if compress != -1 {
        var swaps = piece - compress
        piece = 7
        while piece != 0 && swaps > 0 {
            let t = addr[compress + swaps - 1]
            addr[compress + swaps - 1] = addr[piece]
            addr[piece] = t
            piece -= 1; swaps -= 1
        }
    } else if piece != 8 { return nil }
    return addr
}

/// Parse an IPv4 number part; nil on failure. Saturates at 2^40.
private func urlParseIPv4Number(_ s: [UInt8]) -> UInt64? {
    if s.isEmpty { return nil }
    var radix: UInt64 = 10
    var i = 0
    if s.count >= 2 && s[0] == 0x30 && (s[1] == 0x78 || s[1] == 0x58) { radix = 16; i = 2 }
    else if s.count >= 2 && s[0] == 0x30 { radix = 8; i = 1 }
    if i >= s.count { return 0 }
    var v: UInt64 = 0
    while i < s.count {
        let d = urlHexValue(s[i])
        if d < 0 || UInt64(d) >= radix { return nil }
        v = v * radix + UInt64(d)
        if v > 1 << 40 { v = 1 << 40 }
        i += 1
    }
    return v
}

private func urlSplitDots(_ s: [UInt8]) -> [[UInt8]] {
    var parts: [[UInt8]] = [[]]
    for c in s {
        if c == 0x2e { parts.append([]) } else { parts[parts.count - 1].append(c) }
    }
    return parts
}

private func urlEndsInANumber(_ s: [UInt8]) -> Bool {
    var parts = urlSplitDots(s)
    if parts[parts.count - 1].isEmpty {
        if parts.count == 1 { return false }
        parts.removeLast()
    }
    let last = parts[parts.count - 1]
    if !last.isEmpty {
        var allDigits = true
        for c in last where c < 0x30 || c > 0x39 { allDigits = false; break }
        if allDigits { return true }
    }
    return urlParseIPv4Number(last) != nil
}

private func urlParseIPv4(_ s: [UInt8]) -> UInt32? {
    var parts = urlSplitDots(s)
    if parts[parts.count - 1].isEmpty && parts.count > 1 { parts.removeLast() }
    if parts.count > 4 { return nil }
    var nums: [UInt64] = []
    for p in parts {
        guard let v = urlParseIPv4Number(p) else { return nil }
        nums.append(v)
    }
    for i in 0..<(nums.count - 1) where nums[i] > 255 { return nil }
    var limit: UInt64 = 1
    for _ in 0..<(5 - nums.count) { limit *= 256 }
    if nums[nums.count - 1] >= limit { return nil }
    var ipv4 = nums[nums.count - 1]
    for i in 0..<(nums.count - 1) {
        var m: UInt64 = 1
        for _ in 0..<(3 - i) { m *= 256 }
        ipv4 += nums[i] * m
    }
    return UInt32(truncatingIfNeeded: ipv4)
}

func urlParseHost(_ input: [UInt8], isOpaque: Bool) throws(URLError) -> URLHost {
    if let f = input.first, f == 0x5b {
        guard input.last == 0x5d, input.count >= 2 else { throw .invalidIPv6 }
        guard let a = urlParseIPv6(Array(input[1..<(input.count - 1)])) else { throw .invalidIPv6 }
        return .ipv6(a)
    }
    if isOpaque {
        for c in input where urlIsForbiddenHostByte(c) { throw .invalidHost }
        return .opaque(urlPercentEncode(input, .c0Control))
    }
    var domain = urlPercentDecode(input)
    for i in 0..<domain.count {
        let c = domain[i]
        if c >= 0x80 { throw .nonASCIIHost }
        if c >= 0x41 && c <= 0x5a { domain[i] = c + 32 }
    }
    if domain.isEmpty { throw .emptyHost }
    for c in domain where urlIsForbiddenDomainByte(c) { throw .invalidHost }
    if urlEndsInANumber(domain) {
        guard let a = urlParseIPv4(domain) else { throw .invalidIPv4 }
        return .ipv4(a)
    }
    return .domain(domain)
}

// MARK: the parser

private enum URLState {
    case schemeStart, scheme, noScheme, specialRelativeOrAuthority, pathOrAuthority
    case relative, relativeSlash, specialAuthoritySlashes, specialAuthorityIgnoreSlashes
    case authority, host, port, file, fileSlash, fileHost, pathStart, path
    case opaquePath, query, fragment
}

@inline(__always) private func urlIsAlpha(_ c: Int) -> Bool { (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) }
@inline(__always) private func urlIsDigit(_ c: Int) -> Bool { c >= 0x30 && c <= 0x39 }

private func urlIsWindowsDriveLetter(_ s: [UInt8]) -> Bool {
    s.count == 2 && urlIsAlpha(Int(s[0])) && (s[1] == 0x3a || s[1] == 0x7c)
}

private func urlIsNormalizedWindowsDriveLetter(_ s: [UInt8]) -> Bool {
    s.count == 2 && urlIsAlpha(Int(s[0])) && s[1] == 0x3a
}

private func urlStartsWithWindowsDriveLetter(_ d: [UInt8], _ from: Int) -> Bool {
    if from < 0 || from + 2 > d.count { return false }
    if !(urlIsAlpha(Int(d[from])) && (d[from + 1] == 0x3a || d[from + 1] == 0x7c)) { return false }
    if from + 2 == d.count { return true }
    let c = d[from + 2]
    return c == 0x2f || c == 0x5c || c == 0x3f || c == 0x23
}

private func urlIsSingleDot(_ b: [UInt8]) -> Bool {
    if b == [0x2e] { return true }
    return b.count == 3 && b[0] == 0x25 && b[1] == 0x32 && (b[2] | 0x20) == 0x65
}

private func urlIsDoubleDot(_ b: [UInt8]) -> Bool {
    // "..", ".%2e", "%2e.", "%2e%2e" (case-insensitive)
    var i = 0
    var parts = 0
    while i < b.count {
        if b[i] == 0x2e { i += 1 }
        else if i + 2 < b.count && b[i] == 0x25 && b[i + 1] == 0x32 && (b[i + 2] | 0x20) == 0x65 { i += 3 }
        else { return false }
        parts += 1
    }
    return parts == 2
}

private func urlShortenPath(_ url: inout URLRecord) {
    if url.scheme == Array("file".utf8) && url.path.count == 1
        && urlIsNormalizedWindowsDriveLetter(url.path[0]) { return }
    if !url.path.isEmpty { url.path.removeLast() }
}

private func urlBasicParse(_ rawInput: [UInt8], base: URLRecord?) throws(URLError) -> URLRecord {
    if rawInput.count > urlMaxLength { throw .tooLong }
    // strip leading/trailing C0 control or space; remove tab and newlines
    var a = 0, b = rawInput.count
    while a < b && rawInput[a] <= 0x20 { a += 1 }
    while b > a && rawInput[b - 1] <= 0x20 { b -= 1 }
    var input: [UInt8] = []
    input.reserveCapacity(b - a)
    for i in a..<b {
        let c = rawInput[i]
        if c != 0x09 && c != 0x0a && c != 0x0d { input.append(c) }
    }
    let n = input.count

    var url = URLRecord()
    var state = URLState.schemeStart
    var buffer: [UInt8] = []
    var atSignSeen = false, insideBrackets = false, passwordTokenSeen = false
    var p = 0
    let fileScheme = Array("file".utf8)

    func remainingStartsWith(_ p: Int, _ c: UInt8) -> Bool { p + 1 < n && input[p + 1] == c }

    while true {
        let c: Int = p >= 0 && p < n ? Int(input[p]) : -1
        let special = urlIsSpecialScheme(url.scheme)
        switch state {
        case .schemeStart:
            if urlIsAlpha(c) { buffer.append(textLowerByte(UInt8(c))); state = .scheme }
            else { state = .noScheme; p -= 1 }

        case .scheme:
            if urlIsAlpha(c) || urlIsDigit(c) || c == 0x2b || c == 0x2d || c == 0x2e {
                buffer.append(textLowerByte(UInt8(c)))
            } else if c == 0x3a {
                url.scheme = buffer
                buffer = []
                if url.scheme == fileScheme {
                    state = .file
                } else if urlIsSpecialScheme(url.scheme), let bs = base, bs.scheme == url.scheme {
                    state = .specialRelativeOrAuthority
                } else if urlIsSpecialScheme(url.scheme) {
                    state = .specialAuthoritySlashes
                } else if remainingStartsWith(p, 0x2f) {
                    state = .pathOrAuthority; p += 1
                } else {
                    url.hasOpaquePath = true
                    state = .opaquePath
                }
            } else {
                buffer = []; state = .noScheme; p = -1
            }

        case .noScheme:
            guard let bs = base else { throw .missingScheme }
            if bs.hasOpaquePath && c != 0x23 { throw .invalidBase }
            if bs.hasOpaquePath && c == 0x23 {
                url.scheme = bs.scheme; url.path = bs.path; url.hasOpaquePath = true
                url.opaquePath = bs.opaquePath; url.query = bs.query
                url.fragment = []
                state = .fragment
            } else if bs.scheme != fileScheme { state = .relative; p -= 1 }
            else { state = .file; p -= 1 }

        case .specialRelativeOrAuthority:
            if c == 0x2f && remainingStartsWith(p, 0x2f) { state = .specialAuthorityIgnoreSlashes; p += 1 }
            else { state = .relative; p -= 1 }

        case .pathOrAuthority:
            if c == 0x2f { state = .authority } else { state = .path; p -= 1 }

        case .relative:
            let bs = base! // reached only through noScheme/specialRelativeOrAuthority, which have a base
            url.scheme = bs.scheme
            if c == 0x2f { state = .relativeSlash }
            else if urlIsSpecialScheme(url.scheme) && c == 0x5c { state = .relativeSlash }
            else {
                url.username = bs.username; url.password = bs.password
                url.host = bs.host; url.port = bs.port
                url.path = bs.path; url.query = bs.query
                if c == 0x3f { url.query = []; state = .query }
                else if c == 0x23 { url.fragment = []; state = .fragment }
                else if c != -1 {
                    url.query = nil
                    urlShortenPath(&url)
                    state = .path; p -= 1
                }
            }

        case .relativeSlash:
            if special && (c == 0x2f || c == 0x5c) { state = .specialAuthorityIgnoreSlashes }
            else if c == 0x2f { state = .authority }
            else {
                let bs = base!
                url.username = bs.username; url.password = bs.password
                url.host = bs.host; url.port = bs.port
                state = .path; p -= 1
            }

        case .specialAuthoritySlashes:
            if c == 0x2f && remainingStartsWith(p, 0x2f) { state = .specialAuthorityIgnoreSlashes; p += 1 }
            else { state = .specialAuthorityIgnoreSlashes; p -= 1 }

        case .specialAuthorityIgnoreSlashes:
            if c != 0x2f && c != 0x5c { state = .authority; p -= 1 }

        case .authority:
            if c == 0x40 {
                if atSignSeen { buffer = [0x25, 0x34, 0x30] + buffer }
                atSignSeen = true
                for cp in buffer {
                    if cp == 0x3a && !passwordTokenSeen { passwordTokenSeen = true; continue }
                    var enc: [UInt8] = []
                    if urlInEncodeSet(cp, .userinfo) { urlAppendPercent(cp, to: &enc) } else { enc.append(cp) }
                    if passwordTokenSeen { url.password += enc } else { url.username += enc }
                }
                buffer = []
            } else if c == -1 || c == 0x2f || c == 0x3f || c == 0x23 || (special && c == 0x5c) {
                if atSignSeen && buffer.isEmpty { throw .invalidCredentials }
                p -= buffer.count + 1
                buffer = []
                state = .host
            } else { buffer.append(UInt8(c)) }

        case .host:
            if c == 0x3a && !insideBrackets {
                if buffer.isEmpty { throw .emptyHost }
                url.host = try urlParseHost(buffer, isOpaque: !special)
                buffer = []
                state = .port
            } else if c == -1 || c == 0x2f || c == 0x3f || c == 0x23 || (special && c == 0x5c) {
                p -= 1
                if special && buffer.isEmpty { throw .emptyHost }
                url.host = buffer.isEmpty ? .empty : try urlParseHost(buffer, isOpaque: !special)
                buffer = []
                state = .pathStart
            } else {
                if c == 0x5b { insideBrackets = true }
                if c == 0x5d { insideBrackets = false }
                buffer.append(UInt8(c))
            }

        case .port:
            if urlIsDigit(c) { buffer.append(UInt8(c)) }
            else if c == -1 || c == 0x2f || c == 0x3f || c == 0x23 || (special && c == 0x5c) {
                if !buffer.isEmpty {
                    var port = 0
                    for d in buffer {
                        port = port * 10 + Int(d - 0x30)
                        if port > 65535 { throw .invalidPort }
                    }
                    url.port = (urlDefaultPort(url.scheme).map { Int($0) == port } ?? false) ? nil : UInt16(port)
                    buffer = []
                }
                state = .pathStart; p -= 1
            } else { throw .invalidPort }

        case .file:
            url.scheme = fileScheme
            url.host = .empty
            if c == 0x2f || c == 0x5c { state = .fileSlash }
            else if let bs = base, bs.scheme == fileScheme {
                url.host = bs.host; url.path = bs.path; url.query = bs.query
                if c == 0x3f { url.query = []; state = .query }
                else if c == 0x23 { url.fragment = []; state = .fragment }
                else if c != -1 {
                    url.query = nil
                    if !urlStartsWithWindowsDriveLetter(input, p) { urlShortenPath(&url) }
                    else { url.path = [] }
                    state = .path; p -= 1
                }
            } else { state = .path; p -= 1 }

        case .fileSlash:
            if c == 0x2f || c == 0x5c { state = .fileHost }
            else {
                if let bs = base, bs.scheme == fileScheme {
                    url.host = bs.host
                    if !urlStartsWithWindowsDriveLetter(input, p), let first = bs.path.first,
                       urlIsNormalizedWindowsDriveLetter(first) {
                        url.path.append(first)
                    }
                }
                state = .path; p -= 1
            }

        case .fileHost:
            if c == -1 || c == 0x2f || c == 0x5c || c == 0x3f || c == 0x23 {
                p -= 1
                if urlIsWindowsDriveLetter(buffer) { state = .path }
                else if buffer.isEmpty { url.host = .empty; state = .pathStart }
                else {
                    var h = try urlParseHost(buffer, isOpaque: !special)
                    if h == .domain(Array("localhost".utf8)) { h = .empty }
                    url.host = h
                    buffer = []
                    state = .pathStart
                }
            } else { buffer.append(UInt8(c)) }

        case .pathStart:
            if special {
                state = .path
                if c != 0x2f && c != 0x5c { p -= 1 }
            } else if c == 0x3f { url.query = []; state = .query }
            else if c == 0x23 { url.fragment = []; state = .fragment }
            else if c != -1 {
                state = .path
                if c != 0x2f { p -= 1 }
            }

        case .path:
            if c == -1 || c == 0x2f || (special && c == 0x5c) || c == 0x3f || c == 0x23 {
                let slash = c == 0x2f || (special && c == 0x5c)
                if urlIsDoubleDot(buffer) {
                    urlShortenPath(&url)
                    if !slash { url.path.append([]) }
                } else if urlIsSingleDot(buffer) && !slash {
                    url.path.append([])
                } else if !urlIsSingleDot(buffer) {
                    if url.scheme == fileScheme && url.path.isEmpty && urlIsWindowsDriveLetter(buffer) {
                        buffer[1] = 0x3a
                    }
                    url.path.append(buffer)
                }
                buffer = []
                if c == 0x3f { url.query = []; state = .query }
                if c == 0x23 { url.fragment = []; state = .fragment }
            } else {
                let ch = UInt8(c)
                if urlInEncodeSet(ch, .path) { urlAppendPercent(ch, to: &buffer) } else { buffer.append(ch) }
            }

        case .opaquePath:
            if c == 0x3f { url.query = []; state = .query }
            else if c == 0x23 { url.fragment = []; state = .fragment }
            else if c == 0x20 {
                if remainingStartsWith(p, 0x3f) || remainingStartsWith(p, 0x23) { url.opaquePath += [0x25, 0x32, 0x30] }
                else { url.opaquePath.append(0x20) }
            } else if c != -1 {
                let ch = UInt8(c)
                if urlInEncodeSet(ch, .c0Control) { urlAppendPercent(ch, to: &url.opaquePath) }
                else { url.opaquePath.append(ch) }
            }

        case .query:
            if c == -1 || c == 0x23 {
                let set: URLEncodeSet = special ? .specialQuery : .query
                url.query = (url.query ?? []) + urlPercentEncode(buffer, set)
                buffer = []
                if c == 0x23 { url.fragment = []; state = .fragment }
            } else { buffer.append(UInt8(c)) }

        case .fragment:
            if c != -1 {
                let ch = UInt8(c)
                if urlInEncodeSet(ch, .fragment) { urlAppendPercent(ch, to: &url.fragment!) }
                else { url.fragment!.append(ch) }
            }
        }
        if p >= n { break }
        p += 1
    }
    return url
}

@inline(__always) private func textLowerByte(_ c: UInt8) -> UInt8 { (c >= 0x41 && c <= 0x5a) ? c + 32 : c }
