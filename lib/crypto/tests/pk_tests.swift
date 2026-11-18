func x25519Tests(_ t: Tests) {
    t.section("X25519 (RFC 7748)")
    t.equal(hex(X25519.scalarMult(scalar: unhex("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"),
                                  u: unhex("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c"))),
            "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552", "5.2 vector 1")
    t.equal(hex(X25519.scalarMult(scalar: unhex("4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d"),
                                  u: unhex("e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493"))),
            "95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957", "5.2 vector 2")
    // Iterated: k = u = 9; repeat k, u = X25519(k, u), k.
    var k = X25519.basePoint, u = X25519.basePoint
    let start = hostMillis()
    for i in 1...1000 {
        let r = X25519.scalarMult(scalar: k, u: u)
        u = k; k = r
        if i == 1 { t.equal(hex(k), "422c8e7a6227d7bca1350b3e2bb7279f7897b87bb6854b783c60e80311ae3079", "iterated x1") }
    }
    t.equal(hex(k), "684cf59ba83309552800ef566f2f4d3c1c3887c49360e3875f2eb94d99532c51", "iterated x1000")
    let ms = max(hostMillis() - start, 1)
    print("  x25519: \(1000 * 1000 / ms) scalar mults/s")

    let alice = unhex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
    let bob = unhex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
    let alicePub = X25519.publicKey(privateKey: alice) ?? []
    let bobPub = X25519.publicKey(privateKey: bob) ?? []
    t.equal(hex(alicePub), "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a", "6.1 alice public")
    t.equal(hex(bobPub), "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f", "6.1 bob public")
    let shared = "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"
    t.equal(hex(X25519.sharedSecret(privateKey: alice, peerPublicKey: bobPub) ?? []), shared, "6.1 shared (alice)")
    t.equal(hex(X25519.sharedSecret(privateKey: bob, peerPublicKey: alicePub) ?? []), shared, "6.1 shared (bob)")

    // Small-order and non-canonical inputs.
    let zero = [UInt8](repeating: 0, count: 32)
    var one = zero; one[0] = 1
    t.check(X25519.sharedSecret(privateKey: alice, peerPublicKey: zero) == nil, "u = 0 rejected")
    t.check(X25519.sharedSecret(privateKey: alice, peerPublicKey: one) == nil, "u = 1 rejected")
    let pBytes = unhex("edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f")
    t.check(X25519.sharedSecret(privateKey: alice, peerPublicKey: pBytes) == nil, "u = p rejected")
    let order8 = unhex("e0eb7a7c3b41b8ae1656e3faf19fc46ada098deb9c32b1fd866205165f49b800")
    t.check(X25519.sharedSecret(privateKey: alice, peerPublicKey: order8) == nil, "order-8 point rejected")
    var highBit = bobPub; highBit[31] |= 0x80
    t.equal(hex(X25519.sharedSecret(privateKey: alice, peerPublicKey: highBit) ?? []), shared, "top bit of u ignored")
    var p1 = pBytes; p1[0] = 0xee   // p + 1 = 1 mod p, non-canonical
    t.equal(X25519.scalarMult(scalar: alice, u: p1), X25519.scalarMult(scalar: alice, u: one), "u = p + 1 reduced")
    t.check(X25519.sharedSecret(privateKey: [1], peerPublicKey: bobPub) == nil, "bad length")

    if let data = t.readFile("lib/crypto/fixtures/x25519.txt") {
        var n = 0
        for f in fixtureLines(data) where f.count == 4 {
            t.equal(hex(X25519.sharedSecret(privateKey: unhex(f[0]), peerPublicKey: unhex(f[1])) ?? []), f[2], "fixture \(n) shared")
            t.equal(hex(X25519.publicKey(privateKey: unhex(f[0])) ?? []), f[3], "fixture \(n) public")
            n += 1
        }
        t.check(n == 16, "x25519 fixture lines")
    }
}

func bigIntTests(_ t: Tests) {
    t.section("CryptoBigInt / CryptoMontgomery")
    let v = CryptoBigInt(bytes: unhex("0102030405060708090a"))
    t.equal(v.limbs.count, 2, "limb count")
    t.equal(v.limbs[0], 0x0304_0506_0708_090a, "low limb")
    t.equal(v.bitLength, 73, "bit length")
    t.equal(hex(v.bytes(count: 12) ?? []), "00000102030405060708090a", "bytes padded")
    t.check(v.bytes(count: 9) == nil, "bytes too short")
    t.check(CryptoMontgomery(modulus: CryptoBigInt(bytes: [0x10])) == nil, "even modulus rejected")
    t.check(CryptoMontgomery(modulus: CryptoBigInt(bytes: [1])) == nil, "modulus 1 rejected")
    t.check(CryptoMontgomery(modulus: CryptoBigInt(bytes: [])) == nil, "empty modulus rejected")

    // Field identities over P-256's p, P-384's n, and 2^64 + 1 (low limb 1).
    var rng = TestRandom(seed: 42)
    let moduli = [CryptoECCurve.p256().p, CryptoECCurve.p384().n,
                  CryptoMontgomery(modulus: CryptoBigInt(limbs: [1, 1]))!, CryptoMontgomery(modulus: CryptoBigInt(limbs: [0xffff_ffff_ffff_ffc5]))!]
    for (mi, m) in moduli.enumerated() {
        var ok = true
        for _ in 0..<50 {
            var a = [UInt64](repeating: 0, count: m.limbs), b = a
            for i in 0..<m.limbs { a[i] = rng.next(); b[i] = rng.next() }
            a = m.reduceOnce(m.reduceOnce(a)); b = m.reduceOnce(m.reduceOnce(b))
            if !m.isReduced(a) || !m.isReduced(b) { a[m.limbs - 1] = 0; b[m.limbs - 1] = 0 }
            let am = m.toMont(a), bm = m.toMont(b)
            if m.fromMont(am) != a { ok = false }
            if m.sub(m.add(am, bm), bm) != am { ok = false }
            if m.mul(am, bm) != m.mul(bm, am) { ok = false }
            // (a + b)^2 = a^2 + 2ab + b^2
            let s = m.add(am, bm)
            let lhs = m.mul(s, s)
            let ab = m.mul(am, bm)
            let rhs = m.add(m.add(m.mul(am, am), m.add(ab, ab)), m.mul(bm, bm))
            if lhs != rhs { ok = false }
        }
        t.check(ok, "identities modulus \(mi)")
    }
    // Fermat inverse in the prime fields.
    let f = CryptoECCurve.p384().p
    var x = [UInt64](repeating: 0, count: f.limbs)
    for i in 0..<f.limbs { x[i] = rng.next() >> 1 }
    let xm = f.toMont(x)
    t.equal(f.fromMont(f.mul(xm, f.inverse(xm))), [1, 0, 0, 0, 0, 0], "x * x^-1 = 1")
}

func ecdsaTests(_ t: Tests) {
    t.section("ECDSA")
    // RFC 6979 A.2.5: P-256, SHA-256, message "sample".
    let q6979 = unhex("04 60fed4ba255a9d31c961eb74c6356d68c049b8923b61fa6ce669622e60f29fb6 7903fe1008b8bc99a41ae9e95628bc64f2f1b20c2d7e9f5177a3c294d4462299")
    let r6979 = unhex("efd48b2aacb6a8fd1140dd9cd45e81d69d2c877b56aaf991c34d0ea84eaf3716")
    let s6979 = unhex("f7cb1c942d657c41d436c7a1b6e29f65f3e900dbb9aff4064dc4ab2f843acda8")
    let h6979 = SHA256.hash(ascii("sample"))
    t.check(P256.verify(publicKey: q6979, digest: h6979, r: r6979, s: s6979), "RFC 6979 P-256 sample")
    t.check(!P256.verify(publicKey: q6979, digest: SHA256.hash(ascii("test")), r: r6979, s: s6979), "RFC 6979 wrong message")

    let n256 = unhex("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551")
    let p256 = unhex("ffffffff00000001000000000000000000000000ffffffffffffffffffffffff")
    // Range checks on r and s (Wycheproof-style).
    let zero32 = [UInt8](repeating: 0, count: 32)
    t.check(!P256.verify(publicKey: q6979, digest: h6979, r: zero32, s: s6979), "r = 0 rejected")
    t.check(!P256.verify(publicKey: q6979, digest: h6979, r: r6979, s: zero32), "s = 0 rejected")
    t.check(!P256.verify(publicKey: q6979, digest: h6979, r: n256, s: s6979), "r = n rejected")
    t.check(!P256.verify(publicKey: q6979, digest: h6979, r: r6979, s: n256), "s = n rejected")
    t.check(!P256.verify(publicKey: q6979, digest: h6979, r: r6979, s: [1] + s6979), "s > n rejected")
    t.check(!P256.verify(publicKey: q6979, digest: h6979, r: [], s: s6979), "empty r rejected")
    t.check(P256.verify(publicKey: q6979, digest: h6979, r: [0, 0] + r6979, s: [0] + s6979), "leading zeros ok")
    // s and n - s are both valid ECDSA signatures.
    let nm = CryptoECCurve.p256().n
    let sNeg = CryptoBigInt(limbs: nm.sub([0, 0, 0, 0], CryptoBigInt(bytes: s6979).limbs)).bytes(count: 32) ?? []
    t.check(P256.verify(publicKey: q6979, digest: h6979, r: r6979, s: sNeg), "n - s accepted")
    // Public key checks.
    var offCurve = q6979; offCurve[64] ^= 1
    t.check(!P256.verify(publicKey: offCurve, digest: h6979, r: r6979, s: s6979), "point off curve rejected")
    t.check(!P256.isValidPublicKey(offCurve), "off curve invalid")
    t.check(P256.isValidPublicKey(q6979), "valid point")
    var compressed = Array(q6979[0..<33]); compressed[0] = 3
    t.check(!P256.isValidPublicKey(compressed), "compressed rejected")
    t.check(!P256.isValidPublicKey([0]), "infinity encoding rejected")
    t.check(!P256.isValidPublicKey([4] + p256 + Array(q6979[33...])), "x = p rejected")
    t.check(!P256.isValidPublicKey(q6979 + [0]), "trailing byte rejected")
    var wrongTag = q6979; wrongTag[0] = 6
    t.check(!P256.isValidPublicKey(wrongTag), "hybrid tag rejected")

    t.section("ECDSA DER")
    let der = [0x30, 0x44, 0x02, 0x20] + r6979.map { $0 } + [0x02, 0x20] + s6979
    t.check(ecdsaParseDERSignature(der) == nil, "high-bit integers need a leading zero")
    let good = [0x30, 0x46, 0x02, 0x21, 0x00] + r6979 + [0x02, 0x21, 0x00] + s6979
    t.check(P256.verify(publicKey: q6979, digest: h6979, derSignature: good), "DER signature")
    t.check(ecdsaParseDERSignature(good + [0]) == nil, "trailing data rejected")
    t.check(ecdsaParseDERSignature([0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x01]) != nil, "small integers")
    t.check(ecdsaParseDERSignature([0x30, 0x07, 0x02, 0x02, 0x00, 0x01, 0x02, 0x01, 0x01]) == nil, "non-minimal integer rejected")
    t.check(ecdsaParseDERSignature([0x30, 0x81, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x01]) == nil, "non-minimal length rejected")
    t.check(ecdsaParseDERSignature([0x30, 0x06, 0x02, 0x01, 0x81, 0x02, 0x01, 0x01]) == nil, "negative rejected")
    t.check(ecdsaParseDERSignature([0x30, 0x03, 0x02, 0x01, 0x01]) == nil, "missing s rejected")

    t.section("ECDSA fixtures")
    var seeds: [[UInt8]] = []
    if let data = t.readFile("lib/crypto/fixtures/ecdsa.txt") {
        var n = 0
        var prevKey: [UInt8] = []
        for f in fixtureLines(data) where f.count == 5 {
            let alg: CryptoHashAlgorithm = f[1] == "sha256" ? .sha256 : f[1] == "sha384" ? .sha384 : .sha512
            let q = unhex(f[2]), msg = f[3] == "-" ? [] : unhex(f[3]), sig = unhex(f[4])
            let h = alg.hash(msg)
            let verify: ([UInt8], [UInt8], [UInt8]) -> Bool = { q, h, s in
                f[0] == "p256" ? P256.verify(publicKey: q, digest: h, derSignature: s)
                               : P384.verify(publicKey: q, digest: h, derSignature: s)
            }
            t.check(verify(q, h, sig), "fixture \(n) \(f[0]) \(f[1]) valid")
            var h2 = h; h2[0] ^= 1
            t.check(!verify(q, h2, sig), "fixture \(n) tampered digest")
            if h.count > q.count / 2 {   // only the leftmost bits of a long digest count
                var h3 = h; h3[h3.count - 1] ^= 1
                t.check(verify(q, h3, sig), "fixture \(n) digest truncated to the order size")
            }
            var s2 = sig; s2[s2.count - 1] ^= 1
            t.check(!verify(q, h, s2), "fixture \(n) tampered s")
            var s3 = sig; s3[6] ^= 0x10
            t.check(!verify(q, h, s3), "fixture \(n) tampered r")
            if prevKey.count == q.count { t.check(!verify(prevKey, h, sig), "fixture \(n) wrong key") }
            prevKey = q
            if n % 6 == 0 { seeds.append(q + sig + h) }
            n += 1
        }
        t.check(n == 42, "ecdsa fixture lines")
    }
    // Fuzz: mutated key || signature || digest; must never trap.
    var accepted = 0
    t.fuzz("ECDSA verify", seeds: seeds, iterations: 300) { m in
        let keyLen = m.count > 200 ? 97 : 65
        guard m.count > keyLen else { return }
        let q = Array(m[0..<keyLen]), rest = Array(m[keyLen...])
        let split = max(rest.count - (keyLen == 97 ? 48 : 32), 0)
        let sig = Array(rest[0..<split]), h = Array(rest[split...])
        if keyLen == 97 ? P384.verify(publicKey: q, digest: h, derSignature: sig) : P256.verify(publicKey: q, digest: h, derSignature: sig) {
            accepted += 1
        }
    }
    t.fuzz("ECDSA DER parse", seeds: [good, der], iterations: 3000) { m in _ = ecdsaParseDERSignature(m) }
    t.check(accepted <= seeds.count + 40, "fuzzed signatures mostly rejected", "\(accepted) accepted")

    t.section("ECDH")
    // RFC 5903 section 8.1 (P-256).
    let i5903 = unhex("c88f01f510d9ac3f70a292daa2316de544e9aab8afe84049c62a9c57862d1433")
    let gi = unhex("04 dad0b65394221cf9b051e1feca5787d098dfe637fc90b9ef945d0c3772581180 5271a0461cdb8252d61f1c456fa3e59ab1f45b33accf5f58389e0577b8990bb3")
    let gr = unhex("04 d12dfb5289c8d4f81208b70270398c342296970a0bccb74c736fc7554494bf63 56fbf3ca366cc23e8157854c13c58d6aac23f046ada30f8353e74f33039872ab")
    t.equal(hex(P256.publicKey(privateKey: i5903) ?? []), hex(gi), "RFC 5903 g^i")
    t.equal(hex(P256.sharedSecret(privateKey: i5903, peerPublicKey: gr) ?? []),
            "d6840f6b42f6edafd13116e0e12565202fef8e9ece7dce03812464d04b9442de", "RFC 5903 shared")
    t.check(P256.publicKey(privateKey: zero32) == nil, "private key 0 rejected")
    t.check(P256.publicKey(privateKey: n256) == nil, "private key n rejected")
    t.check(P256.sharedSecret(privateKey: i5903, peerPublicKey: offCurve) == nil, "invalid peer rejected")
    if let data = t.readFile("lib/crypto/fixtures/ecdh.txt") {
        var n = 0
        for f in fixtureLines(data) where f.count == 5 {
            let p384 = f[0] == "p384"
            let d = unhex(f[1]), peer = unhex(f[2])
            let s = p384 ? P384.sharedSecret(privateKey: d, peerPublicKey: peer) : P256.sharedSecret(privateKey: d, peerPublicKey: peer)
            let own = p384 ? P384.publicKey(privateKey: d) : P256.publicKey(privateKey: d)
            t.equal(hex(s ?? []), f[3], "fixture \(n) \(f[0]) shared")
            t.equal(hex(own ?? []), f[4], "fixture \(n) \(f[0]) public")
            n += 1
        }
        t.check(n == 16, "ecdh fixture lines")
    }
}

func rsaTests(_ t: Tests) {
    t.section("RSA")
    var seeds: [[UInt8]] = []
    var key2048: RSAPublicKey? = nil
    if let data = t.readFile("lib/crypto/fixtures/rsa.txt") {
        var n = 0
        for f in fixtureLines(data) where f.count == 7 {
            let alg: CryptoHashAlgorithm = f[1] == "sha256" ? .sha256 : f[1] == "sha384" ? .sha384 : .sha512
            let salt = intField(f[2])
            guard let key = RSAPublicKey(modulus: unhex(f[3]), exponent: unhex(f[4])) else {
                t.check(false, "fixture \(n) key"); n += 1; continue
            }
            let h = alg.hash(unhex(f[5])), sig = unhex(f[6])
            let label = "fixture \(n) \(f[0]) \(key.bitLength) \(f[1]) salt \(salt)"
            let verify: ([UInt8], [UInt8]) -> Bool = { s, h in
                f[0] == "pkcs1" ? key.verifyPKCS1v15(signature: s, digest: h, hash: alg)
                                : key.verifyPSS(signature: s, digest: h, hash: alg, saltLength: salt)
            }
            t.check(verify(sig, h), "\(label) valid")
            var h2 = h; h2[0] ^= 0x80
            t.check(!verify(sig, h2), "\(label) tampered digest")
            var s2 = sig; s2[s2.count / 2] ^= 4
            t.check(!verify(s2, h), "\(label) tampered signature")
            t.check(!verify([0] + sig, h), "\(label) long signature")
            t.check(!verify(Array(sig.dropFirst()), h), "\(label) short signature")
            if f[0] == "pss" {
                t.check(!key.verifyPSS(signature: sig, digest: h, hash: alg, saltLength: salt + 1), "\(label) wrong salt length")
                t.check(!key.verifyPKCS1v15(signature: sig, digest: h, hash: alg), "\(label) not PKCS#1")
            } else {
                t.check(!key.verifyPSS(signature: sig, digest: h, hash: alg), "\(label) not PSS")
                if alg == .sha384 { t.check(!key.verifyPKCS1v15(signature: sig, digest: SHA512.hash(unhex(f[5])), hash: .sha512), "\(label) wrong hash") }
            }
            let nBytes = unhex(f[3])
            t.check(!verify(nBytes, h), "\(label) signature = n rejected")
            if key.bitLength == 2048 && f[0] == "pkcs1" && seeds.isEmpty { seeds.append(sig); key2048 = key }
            n += 1
        }
        t.check(n >= 40, "rsa fixture lines")
    }
    // Key validation.
    let n2048 = [UInt8](repeating: 0xc5, count: 256)
    t.check(RSAPublicKey(modulus: n2048, exponent: [1, 0, 1]) != nil, "plain key accepted")
    t.check(RSAPublicKey(modulus: [0, 0] + n2048, exponent: [0, 1, 0, 1]) != nil, "leading zeros stripped")
    t.check(RSAPublicKey(modulus: Array(n2048.dropLast()) + [0xc4], exponent: [1, 0, 1]) == nil, "even modulus rejected")
    t.check(RSAPublicKey(modulus: n2048, exponent: [1]) == nil, "e = 1 rejected")
    t.check(RSAPublicKey(modulus: n2048, exponent: [2]) == nil, "even e rejected")
    t.check(RSAPublicKey(modulus: n2048, exponent: []) == nil, "empty e rejected")
    t.check(RSAPublicKey(modulus: n2048, exponent: [0xff] + n2048) == nil, "e > n rejected")
    t.check(RSAPublicKey(modulus: [UInt8](repeating: 0xc5, count: 64), exponent: [3]) == nil, "512-bit rejected")
    t.check(RSAPublicKey(modulus: [1] + [UInt8](repeating: 0xc5, count: 512), exponent: [3]) == nil, "4097-bit rejected")
    t.check(RSAPublicKey(modulus: [], exponent: [3]) == nil, "empty modulus rejected")
    t.equal(hex(rsaMGF1(seed: ascii("foo"), length: 3, hash: .sha256)), hex(Array(SHA256.hash(ascii("foo") + [0, 0, 0, 0]).prefix(3))), "MGF1 prefix")

    if let key = key2048 {
        let h = SHA256.hash([1, 2, 3])
        t.fuzz("RSA verify", seeds: seeds, iterations: 400) { m in
            _ = key.verifyPKCS1v15(signature: m, digest: h, hash: .sha256)
            _ = key.verifyPSS(signature: m, digest: h, hash: .sha256)
        }
    }
    t.fuzz("RSA key parse", seeds: [n2048 + [1, 0, 1]], iterations: 200) { m in
        let cut = max(m.count - 3, 0)
        if let k = RSAPublicKey(modulus: Array(m[0..<cut]), exponent: Array(m[cut...])) {
            _ = k.verifyPKCS1v15(signature: Array(m[0..<min(cut, k.byteCount)]), digest: SHA256.hash([]), hash: .sha256)
        }
    }
}

func drbgTests(_ t: Tests) {
    t.section("ChaChaDRBG")
    // Known answer computed with Python cryptography's ChaCha20 from the
    // construction described in drbg.swift.
    var g = ChaChaDRBG(seed: ascii("wiffer"))
    t.equal(hex(g.generate(100)), "38598cc32867634eb2404b2b6f908f684935a1eb35ff0446c58a340ff83fd5bc09538f48085124a11d65160eb250dc28987008112c91c4390cbec462b2b043abf63bf28d6b1dd185699216976122603a8c59a665b07665b134d904f52341cd82ac0f3399", "first request")
    t.equal(hex(g.generate(16)), "10d9a49d15b24ff99c0102861eaee31e", "second request (rekeyed)")
    g.reseed(ascii("more"))
    t.equal(hex(g.generate(8)), "3f638c785638dbc9", "after reseed")
    var a = ChaChaDRBG(seed: [1]), b = ChaChaDRBG(seed: [1]), c = ChaChaDRBG(seed: [2])
    let x = a.generate(64)
    t.equal(x, b.generate(64), "deterministic")
    t.check(x != c.generate(64), "seed matters")
    t.check(a.generate(64) != x, "no repeats")
    t.equal(a.generate(0).count, 0, "empty request")
    // Rough balance over 1 MiB.
    let big = a.generate(1 << 20)
    var ones = 0
    for v in big { ones += v.nonzeroBitCount }
    let expected = 4 << 20
    t.check(abs(ones - expected) < 20_000, "bit balance", "\(ones) of \(8 << 20)")
}

func throughput(_ t: Tests) {
    t.section("throughput")
    let size = 1 << 20
    let data = patternMessage(size)
    func rate(_ name: String, _ reps: Int, _ body: () -> Void) {
        let start = hostMillis()
        for _ in 0..<reps { body() }
        let ms = max(hostMillis() - start, 1)
        print("  \(name): \(reps * 1000 / ms) MB/s (\(reps) MiB in \(ms) ms)")
    }
    let gcm = AESGCM(key: [UInt8](repeating: 7, count: 16))!
    let gcm256 = AESGCM(key: [UInt8](repeating: 7, count: 32))!
    let cc = ChaCha20Poly1305(key: [UInt8](repeating: 7, count: 32))!
    let nonce = [UInt8](repeating: 1, count: 12)
    var sink = 0
    rate("AES-128-GCM seal", 8) { sink &+= Int(gcm.seal(nonce: nonce, aad: [], plaintext: data)[5]) }
    rate("AES-256-GCM seal", 8) { sink &+= Int(gcm256.seal(nonce: nonce, aad: [], plaintext: data)[5]) }
    rate("ChaCha20-Poly1305 seal", 8) { sink &+= Int(cc.seal(nonce: nonce, aad: [], plaintext: data)[5]) }
    rate("SHA-256", 16) { sink &+= Int(SHA256.hash(data)[0]) }
    rate("SHA-384", 16) { sink &+= Int(SHA384.hash(data)[0]) }
    func ops(_ name: String, _ reps: Int, _ body: () -> Void) {
        let start = hostMillis()
        for _ in 0..<reps { body() }
        let ms = max(hostMillis() - start, 1)
        print("  \(name): \(ms * 1000 / reps) us each")
    }
    let q = unhex("04 60fed4ba255a9d31c961eb74c6356d68c049b8923b61fa6ce669622e60f29fb6 7903fe1008b8bc99a41ae9e95628bc64f2f1b20c2d7e9f5177a3c294d4462299")
    let r = unhex("efd48b2aacb6a8fd1140dd9cd45e81d69d2c877b56aaf991c34d0ea84eaf3716")
    let s = unhex("f7cb1c942d657c41d436c7a1b6e29f65f3e900dbb9aff4064dc4ab2f843acda8")
    let h = SHA256.hash(ascii("sample"))
    ops("P-256 verify", 20) { if P256.verify(publicKey: q, digest: h, r: r, s: s) { sink &+= 1 } }
    let d = [UInt8](repeating: 0x42, count: 32)
    ops("P-256 ECDH", 20) { sink &+= P256.sharedSecret(privateKey: d, peerPublicKey: q)?.count ?? 0 }
    let d48 = [UInt8](repeating: 0x42, count: 48)
    if let q384 = P384.publicKey(privateKey: d48) {
        ops("P-384 ECDH", 10) { sink &+= P384.sharedSecret(privateKey: d48, peerPublicKey: q384)?.count ?? 0 }
    }
    if let data = t.readFileIfPresent("lib/crypto/fixtures/rsa.txt") {
        for f in fixtureLines(data) where f.count == 7 && f[0] == "pkcs1" && f[1] == "sha256" {
            guard let key = RSAPublicKey(modulus: unhex(f[3]), exponent: unhex(f[4])) else { continue }
            if key.bitLength != 2048 && key.bitLength != 4096 { continue }
            let sig = unhex(f[6]), hh = SHA256.hash(unhex(f[5]))
            ops("RSA-\(key.bitLength) e=\(f[4]) verify", 20) { if key.verifyPKCS1v15(signature: sig, digest: hh, hash: .sha256) { sink &+= 1 } }
        }
    }
    t.check(sink != 0, "benchmarks ran")
}
