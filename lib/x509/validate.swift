// Certificate path validation for TLS server certificates, and the root
// store.
//
//   let roots = X509TrustStore(concatenatedDER: fileBytes)   // /etc/roots.der
//   roots.count, roots.rejected                // parsed / unusable entries
//   let path = try X509Validator.validate(chain: serverCertsDER,
//                                         hostname: "example.com",
//                                         now: rtcUnixSeconds,
//                                         roots: roots)
//   // path: leaf first, ending at the trust anchor; throws X509Error
//
// What is checked (RFC 5280 6.1, simplified the way browsers simplify it):
//   - the path is built from the leaf through the certificates the server
//     sent, in any order (extra and duplicate ones are fine), to an anchor
//     in the store, matching issuer/subject names and, when both are
//     present, authority/subject key identifiers; alternatives are tried
//     (cross-signs), bounded by maxDepth and a signature-check budget;
//   - every signature on the path, by the issuer's key (an anchor's own
//     signature is not checked);
//   - validity dates of every certificate including the anchor, against
//     the caller's `now` (Unix seconds from the RTC);
//   - issuers: basicConstraints cA (v1 anchors without extensions are
//     accepted), keyUsage keyCertSign when keyUsage is present,
//     pathLenConstraint, extKeyUsage serverAuth/any when present, and
//     dNSName/iPAddress name constraints applied to the leaf's names;
//   - the leaf: hostname against subjectAltName dNSName (a wildcard only as
//     the whole left-most label, matching exactly one label) or iPAddress
//     for an IP literal; no fallback to the subject CN (as in Chrome and
//     Firefox, CA/B Forum certificates always carry a SAN); extKeyUsage
//     serverAuth when present; keyUsage digitalSignature when present;
//   - no unknown critical extensions anywhere on the path below the anchor.
// Not checked: revocation (CRL/OCSP), certificate policies, SCTs.

struct X509TrustStore {
    private(set) var anchors: [X509Certificate] = []
    /// Entries in the input that did not parse (or were not certificates).
    private(set) var rejected = 0
    /// The first few parse errors, for diagnostics.
    private(set) var rejectReasons: [String] = []

    static let maxAnchors = 4096

    init() {}

    /// A concatenation of DER certificates (self-delimiting), as in
    /// /etc/roots.der. Parsing stops at the first byte that isn't a DER
    /// SEQUENCE header.
    init(concatenatedDER data: [UInt8]) {
        var r = ASN1Reader(data)
        while anchors.count + rejected < X509TrustStore.maxAnchors, let el = r.next() {
            do throws(X509Error) {
                anchors.append(try X509Certificate(der: el.encoded))
            } catch {
                rejected += 1
                if rejectReasons.count < 16 { rejectReasons.append(error.description) }
            }
        }
        if r.failed { rejected += 1; rejectReasons.append("trailing bytes that are not DER") }
    }

    var count: Int { anchors.count }

    mutating func add(_ cert: X509Certificate) { anchors.append(cert) }

    mutating func add(der: [UInt8]) -> Bool {
        do throws(X509Error) { anchors.append(try X509Certificate(der: der)); return true } catch { return false }
    }

    func containsExactly(_ cert: X509Certificate) -> Bool {
        for a in anchors where a.der == cert.der { return true }
        return false
    }
}

enum X509Validator {
    static let maxDepth = 8               // certificates, leaf and anchor included
    static let maxChainCertificates = 16  // what the server may send
    static let signatureBudget = 24       // signature checks per validation

    /// Validate a server's certificate list (leaf first, DER) for
    /// `hostname` (nil skips the name check) at time `now`.
    static func validate(chain: [[UInt8]], hostname: String?, now: Int64,
                         roots: X509TrustStore, requireServerAuth: Bool = true) throws(X509Error) -> [X509Certificate] {
        guard let leafDER = chain.first else { throw .emptyChain }
        guard chain.count <= maxChainCertificates else { throw .chainTooLong }
        let leaf = try X509Certificate(der: leafDER)
        var pool: [X509Certificate] = []
        for d in chain.dropFirst() {
            // An extra certificate that doesn't parse is ignored; if it was
            // needed, the path search reports untrustedRoot.
            if let c = try? X509Certificate(der: d) { pool.append(c) }
        }
        if let o = leaf.unknownCriticalExtension { throw .unknownCriticalExtension(o) }

        var search = X509PathSearch(leaf: leaf, pool: pool, roots: roots, now: now, requireServerAuth: requireServerAuth)
        guard let path = search.run() else { throw search.firstError ?? .untrustedRoot }

        // Leaf checks (after trust, so an untrusted chain reports that).
        if now < leaf.notBefore { throw .notYetValid }
        if now > leaf.notAfter { throw .expired }
        if let h = hostname, !x509MatchesHostname(leaf, h) { throw .hostnameMismatch }
        if requireServerAuth, let eku = leaf.extendedKeyUsage,
           !eku.contains(X509OID.serverAuth), !eku.contains(X509OID.anyExtendedKeyUsage) {
            throw .extendedKeyUsage
        }
        if let ku = leaf.keyUsage, ku & X509KeyUsage.digitalSignature == 0 { throw .keyUsage }
        return path
    }
}

/// Depth-first search for a path from the leaf to an anchor.
struct X509PathSearch {
    let leaf: X509Certificate
    let pool: [X509Certificate]
    let roots: X509TrustStore
    let now: Int64
    let requireServerAuth: Bool
    var budget = X509Validator.signatureBudget
    var firstError: X509Error? = nil
    var used: [Bool]

    init(leaf: X509Certificate, pool: [X509Certificate], roots: X509TrustStore, now: Int64, requireServerAuth: Bool) {
        self.leaf = leaf; self.pool = pool; self.roots = roots; self.now = now
        self.requireServerAuth = requireServerAuth
        used = [Bool](repeating: false, count: pool.count)
    }

    mutating func run() -> [X509Certificate]? {
        extend([leaf])
    }

    private mutating func note(_ e: X509Error) { if firstError == nil { firstError = e } }

    private mutating func extend(_ path: [X509Certificate]) -> [X509Certificate]? {
        guard let cur = path.last else { return nil }
        // The certificate itself is an anchor (a server that sends its root,
        // or a directly trusted leaf).
        if roots.containsExactly(cur) {
            if let e = checkIssuer(cur, path: Array(path.dropLast()), anchor: true) { note(e) } else { return path }
        }
        for a in roots.anchors where cur.couldBeIssued(by: a) && a.der != cur.der {
            if let e = checkIssuer(a, path: path, anchor: true) { note(e); continue }
            guard budget > 0 else { note(.chainTooLong); return nil }
            budget -= 1
            if let e = cur.isSigned(by: a) { note(e); continue }
            return path + [a]
        }
        guard path.count + 1 < X509Validator.maxDepth else { note(.chainTooLong); return nil }
        for i in 0..<pool.count where !used[i] {
            let c = pool[i]
            guard c.der != cur.der, cur.couldBeIssued(by: c) else { continue }
            if let e = checkIssuer(c, path: path, anchor: false) { note(e); continue }
            guard budget > 0 else { note(.chainTooLong); return nil }
            budget -= 1
            if let e = cur.isSigned(by: c) { note(e); continue }
            used[i] = true
            if let p = extend(path + [c]) { return p }
            used[i] = false
        }
        return nil
    }

    /// Checks on a certificate acting as the issuer of path.last.
    private func checkIssuer(_ c: X509Certificate, path: [X509Certificate], anchor: Bool) -> X509Error? {
        if now < c.notBefore { return .notYetValid }
        if now > c.notAfter { return .expired }
        if path.isEmpty { return nil }   // a directly trusted leaf
        if anchor {
            // Trust anchors: honour constraints they state, accept v1 roots.
            if c.hasBasicConstraints && !c.isCA { return .notCA }
        } else {
            if !c.isCA { return .notCA }
            if let o = c.unknownCriticalExtension { return .unknownCriticalExtension(o) }
            if requireServerAuth, let eku = c.extendedKeyUsage,
               !eku.contains(X509OID.serverAuth), !eku.contains(X509OID.anyExtendedKeyUsage) {
                return .extendedKeyUsage
            }
        }
        if let ku = c.keyUsage, ku & X509KeyUsage.keyCertSign == 0 { return .keyUsage }
        if let limit = c.pathLength {
            // Non-self-issued intermediates between c and the leaf.
            var n = 0
            for p in path.dropFirst() where !p.isSelfIssued { n += 1 }
            if n > limit { return .pathLength }
        }
        if let nc = c.nameConstraints, !x509NameConstraintsAllow(nc, leaf) { return .nameConstraints }
        return nil
    }
}

// MARK: - Host names

/// ASCII lower case, one trailing dot removed.
func x509NormalizeHost(_ s: String) -> [UInt8] {
    var b: [UInt8] = []
    for c in s.utf8 { b.append(c >= 0x41 && c <= 0x5a ? c + 0x20 : c) }
    if b.last == 0x2e { b.removeLast() }
    return b
}

/// Does the leaf certificate cover `host` (a DNS name, IPv4 literal, or
/// IPv6 literal with or without brackets)?
func x509MatchesHostname(_ cert: X509Certificate, _ host: String) -> Bool {
    if let ip = x509ParseIP(host) {
        for a in cert.ipAddresses where a == ip { return true }
        return false
    }
    let h = x509NormalizeHost(host)
    guard !h.isEmpty, h.first != 0x2e, !x509Contains(h, [0x2e, 0x2e]) else { return false }
    for name in cert.dnsNames where x509DNSPatternMatches(x509NormalizeHost(name), h) { return true }
    return false
}

func x509Contains(_ a: [UInt8], _ needle: [UInt8]) -> Bool {
    guard a.count >= needle.count else { return false }
    for i in 0...(a.count - needle.count) where Array(a[i..<(i + needle.count)]) == needle { return true }
    return false
}

/// RFC 6125 6.4.3, restricted: "*" must be the entire left-most label and
/// matches exactly one non-empty label; the rest must have at least two
/// labels (no "*.com").
func x509DNSPatternMatches(_ pattern: [UInt8], _ host: [UInt8]) -> Bool {
    if pattern.isEmpty { return false }
    if pattern.count >= 2 && pattern[0] == 0x2a && pattern[1] == 0x2e {
        let rest = Array(pattern[2...])
        guard rest.contains(0x2e), !rest.contains(0x2a), let dot = host.firstIndex(of: 0x2e), dot > 0 else { return false }
        return Array(host[(dot + 1)...]) == rest
    }
    if pattern.contains(0x2a) { return false }   // partial wildcards refused
    return pattern == host
}

/// IPv4 dotted quad (4 bytes) or IPv6 (16 bytes; brackets allowed).
func x509ParseIP(_ s: String) -> [UInt8]? {
    var b = Array(s.utf8)
    if b.first == 0x5b && b.last == 0x5d { b = Array(b[1..<(b.count - 1)]) }
    if let v4 = x509ParseIPv4(b[...]) { return v4 }
    return x509ParseIPv6(b)
}

func x509ParseIPv4(_ b: ArraySlice<UInt8>) -> [UInt8]? {
    var out: [UInt8] = []
    var cur = -1
    var digits = 0
    var leadingZero = false
    for c in b {
        if c == 0x2e {
            guard cur >= 0, out.count < 3 else { return nil }
            out.append(UInt8(cur)); cur = -1; digits = 0
        } else if c >= 0x30 && c <= 0x39 {
            if digits == 1 && leadingZero { return nil }
            if digits == 0 { leadingZero = c == 0x30; cur = 0 }
            digits += 1
            cur = cur * 10 + Int(c - 0x30)
            guard cur <= 255, digits <= 3 else { return nil }
        } else { return nil }
    }
    guard cur >= 0, out.count == 3 else { return nil }
    out.append(UInt8(cur))
    return out
}

func x509ParseIPv6(_ b: [UInt8]) -> [UInt8]? {
    guard b.count >= 2, b.count <= 45, b.contains(0x3a) else { return nil }
    var head: [UInt16] = [], tail: [UInt16] = []
    var seenGap = false
    var i = 0
    if b[0] == 0x3a {
        guard b[1] == 0x3a else { return nil }
        seenGap = true; i = 2
    }
    var v4: [UInt8]? = nil
    while i < b.count {
        // One group (or a trailing dotted IPv4).
        var j = i
        while j < b.count && b[j] != 0x3a { j += 1 }
        let group = b[i..<j]
        guard !group.isEmpty else { return nil }
        if group.contains(0x2e) {
            guard j == b.count, let q = x509ParseIPv4(group) else { return nil }
            v4 = q
        } else {
            guard group.count <= 4 else { return nil }
            var v: UInt16 = 0
            for c in group {
                let d: UInt16
                switch c {
                case 0x30...0x39: d = UInt16(c - 0x30)
                case 0x61...0x66: d = UInt16(c - 0x61 + 10)
                case 0x41...0x46: d = UInt16(c - 0x41 + 10)
                default: return nil
                }
                v = v << 4 | d
            }
            if seenGap { tail.append(v) } else { head.append(v) }
        }
        i = j
        if i < b.count {          // at a ':'
            i += 1
            if i < b.count && b[i] == 0x3a {
                guard !seenGap else { return nil }
                seenGap = true; i += 1
            } else if i == b.count { return nil }   // trailing single ':'
        }
    }
    let groups = head.count + tail.count + (v4 == nil ? 0 : 2)
    if seenGap { guard groups <= 7 else { return nil } } else { guard groups == 8 else { return nil } }
    var all = head
    if seenGap { all += [UInt16](repeating: 0, count: 8 - groups) }
    all += tail
    var out: [UInt8] = []
    for g in all { out.append(UInt8(g >> 8)); out.append(UInt8(g & 0xff)) }
    if let q = v4 { out += q }
    return out.count == 16 ? out : nil
}

// MARK: - Name constraints

func x509DNSWithin(_ name: [UInt8], _ base0: String) -> Bool {
    var base = x509NormalizeHost(base0)
    if base.first == 0x2e { base.removeFirst() }    // ".example.com" form
    if base.isEmpty { return true }
    if name == base { return true }
    return name.count > base.count && name[name.count - base.count - 1] == 0x2e
        && Array(name[(name.count - base.count)...]) == base
}

func x509IPWithin(_ ip: [UInt8], _ range: [UInt8]) -> Bool {
    guard range.count == ip.count * 2 else { return false }
    for i in 0..<ip.count where ip[i] & range[ip.count + i] != range[i] & range[ip.count + i] { return false }
    return true
}

func x509NameConstraintsAllow(_ nc: X509NameConstraints, _ leaf: X509Certificate) -> Bool {
    for n in leaf.dnsNames {
        var h = x509NormalizeHost(n)
        if h.count >= 2 && h[0] == 0x2a && h[1] == 0x2e { h = Array(h[2...]) }
        for e in nc.excludedDNS where x509DNSWithin(h, e) { return false }
        if !nc.permittedDNS.isEmpty {
            var ok = false
            for p in nc.permittedDNS where x509DNSWithin(h, p) { ok = true }
            if !ok { return false }
        }
    }
    for ip in leaf.ipAddresses {
        for e in nc.excludedIP where x509IPWithin(ip, e) { return false }
        let sameFamily = nc.permittedIP.filter { $0.count == ip.count * 2 }
        if !sameFamily.isEmpty {
            var ok = false
            for p in sameFamily where x509IPWithin(ip, p) { ok = true }
            if !ok { return false }
        }
    }
    return true
}
