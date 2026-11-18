// Host tests for lib/x509: the DER reader, certificate parsing, path
// validation against the test PKI in tests/certs/ (tests/certs/gen.py), the
// Mozilla root store in rootfs/etc/roots.der, and fuzzing.

func libTests(_ t: Tests) {
    asn1Tests(t)
    hostnameTests(t)
    certificateTests(t)
    validationTests(t)
    mozillaRootsTests(t)
    x509FuzzTests(t)
}

let x509TestNow = asn1UnixTime(year: 2026, month: 11, day: 18, hour: 12, minute: 0, second: 0)

func certFile(_ t: Tests, _ name: String) -> [UInt8] {
    t.readFile("tests/certs/\(name).der") ?? []
}

func x509ErrorName(_ e: X509Error) -> String {
    switch e {
    case .malformed: return "malformed"
    case .unsupportedAlgorithm: return "unsupportedAlgorithm"
    case .unknownCriticalExtension: return "unknownCriticalExtension"
    default: return e.description
    }
}

func asn1Tests(_ t: Tests) {
    t.section("ASN.1")
    var r = ASN1Reader([0x30, 0x06, 0x02, 0x01, 0x05, 0x01, 0x01, 0xff])
    if let seq = r.next(), var kids = seq.children() {
        t.check(seq.is(ASN1.sequence) && r.atEnd, "sequence")
        t.equal(kids.expect(ASN1.integer)?.smallInt() ?? -1, 5, "integer")
        t.check(kids.next()?.boolean() == true && kids.atEnd, "boolean")
    } else { t.check(false, "sequence parse") }

    func fails(_ b: [UInt8], _ label: String) {
        var rd = ASN1Reader(b)
        let e = rd.next()
        t.check(e == nil && rd.failed, label)
    }
    fails([0x30, 0x80, 0x00, 0x00], "indefinite length refused")
    fails([0x04, 0x81, 0x05, 1, 2, 3, 4, 5], "non-minimal long length refused")
    fails([0x04, 0x82, 0x00, 0x80] + [UInt8](repeating: 0, count: 128), "leading-zero length refused")
    fails([0x04, 0x05, 1, 2], "length past end refused")
    fails([0x04, 0x85, 1, 0, 0, 0, 0], "5-byte length refused")
    fails([0x1f, 0x05, 0x00], "high-tag form below 31 refused")
    var big = ASN1Reader([0x04, 0x81, 0x80] + [UInt8](repeating: 7, count: 128))
    t.equal(big.next()?.length ?? -1, 128, "long-form length")

    t.check(ASN1Reader([0x02, 0x02, 0x00, 0x05]).firstInteger() == nil, "non-minimal INTEGER refused")
    t.check(ASN1Reader([0x02, 0x02, 0xff, 0x85]).firstInteger() == nil, "non-minimal negative refused")
    t.check(ASN1Reader([0x02, 0x00]).firstInteger() == nil, "empty INTEGER refused")
    t.check(ASN1Reader([0x02, 0x02, 0x00, 0x85]).firstInteger() == [0x00, 0x85], "positive with sign byte")
    var u = ASN1Reader([0x02, 0x02, 0x00, 0x85])
    t.check(u.next()?.unsignedInteger() == [0x85], "unsignedInteger drops sign byte")
    var bad = ASN1Reader([0x01, 0x01, 0x01])
    t.check(bad.next()?.boolean() == nil, "BOOLEAN must be 00/ff")

    let rsaOID = ASN1OID(arcs: [1, 2, 840, 113549, 1, 1, 11])
    t.equal(hex(rsaOID.bytes), "2a864886f70d01010b", "OID encode")
    t.equal(rsaOID.dotted, "1.2.840.113549.1.1.11", "OID dotted")
    var o = ASN1Reader([0x06, 0x03, 0x2a, 0x80, 0x01])
    t.check(o.next()?.oid() == nil, "OID with 0x80 padding refused")

    var bits = ASN1Reader([0x03, 0x02, 0x05, 0xa0])
    if let b = bits.next()?.bitStringBits() { t.check(b.unusedBits == 5 && b.bytes == [0xa0], "bit string") } else { t.check(false, "bit string") }
    var badBits = ASN1Reader([0x03, 0x02, 0x05, 0xa1])
    t.check(badBits.next()?.bitStringBits() == nil, "nonzero unused bits refused")

    func time(_ tag: UInt8, _ s: String) -> Int64? {
        var rd = ASN1Reader([tag, UInt8(s.utf8.count)] + Array(s.utf8))
        return rd.next()?.time()
    }
    t.check(time(0x17, "700101000000Z") == 0, "UTCTime epoch")
    t.check(time(0x17, "491231235959Z") == asn1UnixTime(year: 2049, month: 12, day: 31, hour: 23, minute: 59, second: 59), "UTCTime 2049")
    t.check(time(0x17, "500101000000Z") == asn1UnixTime(year: 1950, month: 1, day: 1, hour: 0, minute: 0, second: 0), "UTCTime 1950")
    t.check(time(0x18, "20380119031408Z") == 2147483648, "GeneralizedTime 2^31")
    t.check(time(0x18, "20240229000000Z") != nil, "leap day")
    t.check(time(0x18, "20230229000000Z") == nil, "not a leap day")
    t.check(time(0x17, "7001010000Z") == nil, "UTCTime without seconds refused")
    t.check(time(0x18, "20380119031408.5Z") == nil, "fractional seconds refused")
    t.check(time(0x17, "700101000000+0100") == nil, "offset refused")
    t.equal(asn1FormatTime(x509TestNow), "2026-11-18 12:00:00Z", "format time")

    // Depth limit: deeply nested SEQUENCEs stop at maxDepth.
    var deep: [UInt8] = []
    for _ in 0..<40 { deep = [0x30, UInt8(deep.count)] + deep }
    var dr = ASN1Reader(Array(deep.prefix(80)))
    var depth = 0
    if var cur = dr.next() {
        while let kids = cur.children() {
            var k = kids
            guard let n = k.next() else { break }
            cur = n; depth += 1
        }
    }
    t.check(depth < ASN1Reader.maxDepth + 1, "nesting limit", "depth \(depth)")

    var s = ASN1Reader([0x1e, 0x04, 0x00, 0x41, 0x00, 0xe9])
    t.equal(s.next()?.string() ?? "", "Aé", "BMPString")
    var t61 = ASN1Reader([0x14, 0x02, 0x41, 0xe9])
    t.equal(t61.next()?.string() ?? "", "Aé", "T61String as Latin-1")
}

extension ASN1Reader {
    func firstInteger() -> [UInt8]? {
        var c = self
        return c.next()?.integer()
    }
}

func hostnameTests(_ t: Tests) {
    t.section("hostnames")
    func m(_ p: String, _ h: String) -> Bool { x509DNSPatternMatches(x509NormalizeHost(p), x509NormalizeHost(h)) }
    t.check(m("example.com", "EXAMPLE.com."), "case and trailing dot")
    t.check(m("*.example.com", "www.example.com"), "wildcard")
    t.check(!m("*.example.com", "example.com"), "wildcard needs a label")
    t.check(!m("*.example.com", "a.b.example.com"), "wildcard is one label")
    t.check(!m("*.com", "example.com"), "no *.tld")
    t.check(!m("w*.example.com", "www.example.com"), "partial wildcard refused")
    t.check(!m("www.*.com", "www.example.com"), "inner wildcard refused")
    t.check(x509ParseIP("127.0.0.1") == [127, 0, 0, 1], "IPv4")
    t.check(x509ParseIP("01.2.3.4") == nil, "IPv4 leading zero refused")
    t.check(x509ParseIP("256.1.1.1") == nil, "IPv4 range")
    t.check(x509ParseIP("1.2.3") == nil, "IPv4 three parts")
    t.check(x509ParseIP("::1") == [UInt8](repeating: 0, count: 15) + [1], "IPv6 ::1")
    t.check(x509ParseIP("[::1]") == [UInt8](repeating: 0, count: 15) + [1], "IPv6 brackets")
    t.check(x509ParseIP("2001:db8::8:800:200c:417a") == unhex("20010db8000000000008080020 0c417a"), "IPv6 gap")
    t.check(x509ParseIP("::ffff:1.2.3.4") == unhex("00000000000000000000ffff01020304"), "IPv6 mapped v4")
    t.check(x509ParseIP("1:2:3:4:5:6:7:8") == unhex("00010002000300040005000600070008"), "IPv6 full")
    t.check(x509ParseIP("1::2::3") == nil, "two gaps refused")
    t.check(x509ParseIP("1:2:3:4:5:6:7:8:9") == nil, "nine groups refused")
    t.check(x509ParseIP("example.com") == nil, "not an IP")
}

func certificateTests(_ t: Tests) {
    t.section("certificates")
    do throws(X509Error) {
        let leaf = try X509Certificate(der: certFile(t, "leaf-ec"))
        t.equal(leaf.version, 3, "version")
        t.equal(leaf.subject.commonName ?? "", "localhost", "subject CN")
        t.equal(leaf.issuer.description, "CN=Wiffer Test Intermediate EC, O=Wiffer Test PKI, C=XX", "issuer DN")
        t.check(leaf.signatureAlgorithm == .ecdsa(.sha256), "ecdsa-with-SHA256")
        t.check(leaf.notBefore == asn1UnixTime(year: 2025, month: 1, day: 1, hour: 0, minute: 0, second: 0), "notBefore")
        t.check(leaf.notAfter == asn1UnixTime(year: 2035, month: 1, day: 1, hour: 0, minute: 0, second: 0), "notAfter")
        if case .ecP256(let q) = leaf.publicKey { t.check(q.count == 65 && P256.isValidPublicKey(q), "P-256 key") } else { t.check(false, "P-256 key") }
        t.check(leaf.dnsNames == ["localhost", "*.wiffer.test"], "dNSNames")
        t.equal(leaf.ipAddresses.count, 2, "iPAddresses")
        t.check(!leaf.isCA && leaf.hasBasicConstraints, "leaf not CA")
        t.check(leaf.keyUsage == X509KeyUsage.digitalSignature, "keyUsage")
        t.check(leaf.extendedKeyUsage == [X509OID.serverAuth], "EKU")
        t.check(leaf.authorityKeyID != nil && leaf.subjectKeyID != nil, "key identifiers")
        let inter = try X509Certificate(der: certFile(t, "int-ec"))
        t.check(inter.isCA && inter.pathLength == 0, "intermediate CA pathlen 0")
        t.check(inter.signatureAlgorithm == .rsaPKCS1(.sha384), "sha384WithRSAEncryption")
        t.check(leaf.authorityKeyID == inter.subjectKeyID, "AKI = issuer SKI")
        t.check(leaf.isSigned(by: inter) == nil, "leaf signed by intermediate")
        let root = try X509Certificate(der: certFile(t, "root-rsa"))
        t.check(inter.isSigned(by: root) == nil, "intermediate signed by root (RSA)")
        t.check(root.isSigned(by: root) == nil && root.isSelfIssued, "root self-signed")
        let rleaf = try X509Certificate(der: certFile(t, "leaf-rsa"))
        t.check(rleaf.signatureAlgorithm == .rsaPSS(.sha256, saltLength: 32), "RSASSA-PSS parameters")
        if case .rsa(let n, let e) = rleaf.publicKey { t.check(x509BitLength(n) == 2048 && e == [1, 0, 1], "RSA key") } else { t.check(false, "RSA key") }
        let rint = try X509Certificate(der: certFile(t, "int-rsa"))
        t.check(rleaf.isSigned(by: rint) == nil, "PSS signature verifies")
        let eroot = try X509Certificate(der: certFile(t, "root-ec"))
        t.check(rint.isSigned(by: eroot) == nil, "P-384 ECDSA signature verifies")
        t.check(rint.isSigned(by: root) == .badSignature, "wrong issuer key")
        let nc = try X509Certificate(der: certFile(t, "int-nc"))
        t.check(nc.nameConstraints?.permittedDNS == ["allowed.test"], "nameConstraints parsed")
    } catch {
        t.check(false, "parse test certificates", error.description)
    }
    // Malformed: trailing garbage, truncation, bad version.
    var der = certFile(t, "leaf-ec")
    t.check((try? X509Certificate(der: der + [0])) == nil, "trailing byte refused")
    t.check((try? X509Certificate(der: Array(der.dropLast()))) == nil, "truncated refused")
    if der.count > 12 {
        der[der.count - 3] ^= 0   // no-op keeps the array alive
        t.check((try? X509Certificate(der: [0x30, 0x00])) == nil, "empty SEQUENCE refused")
    }
}

func validationTests(_ t: Tests) {
    t.section("validation")
    let roots = X509TrustStore(concatenatedDER: t.readFile("tests/certs/roots.der") ?? [])
    t.equal(roots.count, 2, "test roots")
    let leafEC = certFile(t, "leaf-ec"), intEC = certFile(t, "int-ec")
    let leafRSA = certFile(t, "leaf-rsa"), intRSA = certFile(t, "int-rsa")

    func ok(_ chain: [[UInt8]], _ host: String?, _ label: String) {
        do throws(X509Error) {
            let p = try X509Validator.validate(chain: chain, hostname: host, now: x509TestNow, roots: roots)
            t.check(p.count >= 2, label)
        } catch { t.check(false, label, error.description) }
    }
    func bad(_ chain: [[UInt8]], _ host: String?, _ want: X509Error, _ label: String, now: Int64? = nil) {
        do throws(X509Error) {
            _ = try X509Validator.validate(chain: chain, hostname: host, now: now ?? x509TestNow, roots: roots)
            t.check(false, label, "accepted")
        } catch {
            t.check(x509ErrorName(error) == x509ErrorName(want), label, "got \(error.description)")
        }
    }
    ok([leafEC, intEC], "localhost", "EC chain")
    ok([leafRSA, intRSA], "localhost", "RSA chain (PSS leaf, P-384 root)")
    ok([leafEC, intRSA, certFile(t, "rogue-root"), intEC, intEC], "foo.wiffer.test", "out of order, extra and duplicate certs")
    ok([leafEC, intEC, certFile(t, "root-rsa")], "127.0.0.1", "root included, IPv4 SAN")
    ok([leafEC, intEC], "[::1]", "IPv6 SAN")
    ok([leafEC, intEC], "LOCALHOST.", "host case and trailing dot")
    ok([leafEC, intEC], nil, "no hostname check")
    ok([certFile(t, "leaf-nc-ok"), certFile(t, "int-nc")], "ok.allowed.test", "within name constraints")

    bad([certFile(t, "leaf-expired"), intEC], "localhost", .expired, "expired")
    bad([certFile(t, "leaf-notyet"), intEC], "localhost", .notYetValid, "not yet valid")
    bad([leafEC, intEC], "other.test", .hostnameMismatch, "wrong host")
    bad([leafEC, intEC], "a.b.wiffer.test", .hostnameMismatch, "wildcard depth")
    bad([leafEC, intEC], "127.0.0.2", .hostnameMismatch, "wrong IP")
    bad([certFile(t, "leaf-untrusted"), certFile(t, "rogue-root")], "localhost", .untrustedRoot, "untrusted root")
    bad([certFile(t, "leaf-untrusted")], "localhost", .untrustedRoot, "untrusted root, root not sent")
    bad([leafEC], "localhost", .untrustedRoot, "missing intermediate")
    bad([certFile(t, "leaf-badsig"), intEC], "localhost", .badSignature, "bad signature")
    bad([certFile(t, "leaf-via-nonca"), certFile(t, "int-nonca")], "localhost", .notCA, "intermediate without CA:true")
    bad([certFile(t, "leaf-via-nokeycertsign"), certFile(t, "int-noks")], "localhost", .keyUsage, "intermediate without keyCertSign")
    bad([certFile(t, "leaf-pathlen"), certFile(t, "int-sub"), intEC], "localhost", .pathLength, "path length")
    bad([certFile(t, "leaf-clientauth"), intEC], "localhost", .extendedKeyUsage, "EKU clientAuth only")
    bad([certFile(t, "leaf-nc-evil"), certFile(t, "int-nc")], "evil.test", .nameConstraints, "name constraints")
    bad([], "localhost", .emptyChain, "empty chain")
    bad([[0x30, 0x03, 0x02, 0x01, 0x00]], "localhost", .malformed(""), "garbage leaf")
    // The intermediate expires too: a "now" past 2035 fails on the issuer.
    bad([leafEC, intEC], "localhost", .expired, "everything expired",
        now: asn1UnixTime(year: 2036, month: 1, day: 1, hour: 0, minute: 0, second: 0))
    // A directly trusted (pinned) self-signed certificate.
    var pinned = X509TrustStore()
    _ = pinned.add(der: certFile(t, "leaf-ec"))
    do throws(X509Error) {
        let p = try X509Validator.validate(chain: [certFile(t, "leaf-ec")], hostname: "localhost", now: x509TestNow, roots: pinned)
        t.equal(p.count, 1, "trusted leaf itself")
    } catch { t.check(false, "trusted leaf itself", error.description) }
}

func mozillaRootsTests(_ t: Tests) {
    t.section("Mozilla roots")
    guard let data = t.readFile("rootfs/etc/roots.der") else { return }
    let start = hostMillis()
    let roots = X509TrustStore(concatenatedDER: data)
    let ms = hostMillis() - start
    for r in roots.rejectReasons { print("  rejected: \(r)") }
    t.equal(roots.rejected, 0, "every root parses")
    t.check(roots.count >= 100, "root count", "\(roots.count)")
    var rsa = 0, p256 = 0, p384 = 0, otherKey = 0
    var verified = 0, unsupported: [String] = [], failed = 0
    for a in roots.anchors {
        switch a.publicKey {
        case .rsa: rsa += 1
        case .ecP256: p256 += 1
        case .ecP384: p384 += 1
        default: otherKey += 1
        }
        switch a.isSigned(by: a) {
        case nil: verified += 1
        case .unsupportedAlgorithm(let why)?: unsupported.append("\(a.subject.commonName ?? a.subject.description): \(why)")
        default: failed += 1
        }
    }
    print("  roots.der: \(roots.count) roots parsed in \(ms) ms (\(roots.rejected) rejected); keys RSA \(rsa), P-256 \(p256), P-384 \(p384), other \(otherKey)")
    print("  self-signatures: \(verified) verify, \(unsupported.count) unsupported, \(failed) fail")
    for u in unsupported { print("    unsupported: \(u)") }
    t.equal(failed, 0, "no self-signature fails")
    // P-521 (one root as of 2026) is not supported; such roots just never
    // anchor a path.
    t.check(otherKey <= 2, "nearly every root key is RSA, P-256 or P-384", "\(otherKey) others")
}

func x509FuzzTests(_ t: Tests) {
    t.section("fuzz")
    var seeds: [[UInt8]] = []
    for n in ["leaf-ec", "leaf-rsa", "int-ec", "int-nc", "root-ec"] { seeds.append(certFile(t, n)) }
    if let moz = t.readFileIfPresent("rootfs/etc/roots.der") {
        var r = ASN1Reader(moz)
        var i = 0
        while let el = r.next(), i < 6 { if i % 2 == 0 { seeds.append(el.encoded) }; i += 1 }
    }
    t.fuzz("X509Certificate", seeds: seeds, iterations: 10000) { data in
        if let c = try? X509Certificate(der: data) {
            _ = c.subject.description; _ = c.issuer.description
            _ = x509MatchesHostname(c, "localhost")
        }
        // Walk the raw DER tree too.
        func walk(_ r: inout ASN1Reader, _ n: inout Int) {
            while let e = r.next(), n < 10000 {
                n += 1
                _ = e.oid(); _ = e.integer(); _ = e.time(); _ = e.string(); _ = e.bitStringBits()
                if var k = e.children() { walk(&k, &n) }
            }
        }
        var r = ASN1Reader(data)
        var n = 0
        walk(&r, &n)
    }
    let roots = X509TrustStore(concatenatedDER: t.readFile("tests/certs/roots.der") ?? [])
    let chain = [certFile(t, "leaf-ec"), certFile(t, "int-ec")]
    var rng = TestRandom(seed: 99)
    t.fuzz("X509Validator", seeds: chain, iterations: 1500) { data in
        let which = rng.below(2)
        var c = chain
        c[which] = data
        _ = try? X509Validator.validate(chain: c, hostname: "localhost", now: x509TestNow, roots: roots)
    }
}
