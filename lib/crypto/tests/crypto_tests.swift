// Host tests for lib/crypto. Vectors come from the standards (FIPS 180-4,
// FIPS 197, RFC 4231, RFC 5869, RFC 8446/8448, the GCM spec test cases, RFC
// 8439, RFC 7748, Wycheproof-style edge cases) or from fixtures generated
// with Python hashlib / `cryptography` (OpenSSL) by lib/crypto/fixtures/gen_*.py.

func libTests(_ t: Tests) {
    hashTests(t)
    macTests(t)
    aesTests(t)
    chachaTests(t)
    x25519Tests(t)
    bigIntTests(t)
    ecdsaTests(t)
    rsaTests(t)
    drbgTests(t)
    throughput(t)
}

func ascii(_ s: String) -> [UInt8] { Array(s.utf8) }

/// Fixture lines split on spaces (lines starting with '#' skipped).
func fixtureLines(_ data: [UInt8]) -> [[String]] {
    var lines: [[String]] = []
    var fields: [String] = []
    var cur: [UInt8] = []
    func endField() {
        if !cur.isEmpty { fields.append(String(decoding: cur, as: UTF8.self)); cur = [] }
    }
    for b in data + [0x0a] {
        if b == 0x0a {
            endField()
            if !fields.isEmpty && !fields[0].hasPrefix("#") { lines.append(fields) }
            fields = []
        } else if b == 0x20 || b == 0x09 || b == 0x0d {
            endField()
        } else { cur.append(b) }
    }
    return lines
}

func intField(_ s: String) -> Int {
    var v = 0
    for c in s.utf8 where c >= 0x30 && c <= 0x39 { v = v * 10 + Int(c - 0x30) }
    return v
}

func patternMessage(_ n: Int) -> [UInt8] {
    var m = [UInt8](repeating: 0, count: n)
    for i in 0..<n { m[i] = UInt8(truncatingIfNeeded: i &* 7 &+ 3) }
    return m
}

func hashTests(_ t: Tests) {
    t.section("SHA-2")
    let abc = ascii("abc")
    let two = ascii("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
    let four = ascii("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu")
    t.equal(hex(SHA256.hash([])), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "sha256 empty")
    t.equal(hex(SHA256.hash(abc)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha256 abc")
    t.equal(hex(SHA256.hash(two)), "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1", "sha256 448-bit")
    t.equal(hex(SHA384.hash(abc)), "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7", "sha384 abc")
    t.equal(hex(SHA384.hash(four)), "09330c33f71147e83d192fc782cd1b4753111b173b3b05d22fa08086e3b0f712fcc7c71a557e2db966c3e9fa91746039", "sha384 896-bit")
    t.equal(hex(SHA512.hash(abc)), "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f", "sha512 abc")
    t.equal(hex(SHA512.hash(four)), "8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909", "sha512 896-bit")
    var million = SHA256()
    let chunk = [UInt8](repeating: 0x61, count: 1000)
    for _ in 0..<1000 { million.update(chunk) }
    t.equal(hex(million.finalize()), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0", "sha256 million a")

    // Every length near the block boundaries, against Python hashlib.
    if let data = t.readFile("lib/crypto/fixtures/sha2.txt") {
        var n = 0
        for f in fixtureLines(data) where f.count == 4 {
            let m = patternMessage(intField(f[0]))
            t.equal(hex(SHA256.hash(m)), f[1], "sha256 len \(f[0])")
            t.equal(hex(SHA384.hash(m)), f[2], "sha384 len \(f[0])")
            t.equal(hex(SHA512.hash(m)), f[3], "sha512 len \(f[0])")
            n += 1
        }
        t.check(n > 200, "sha2 fixture lines")
    }

    // Incremental updates at every split point, and snapshots.
    let m = patternMessage(300)
    let want256 = SHA256.hash(m), want384 = SHA384.hash(m)
    var splitOK = true
    for cut in 0...m.count {
        var a = SHA256(), b = SHA384()
        a.update(m[0..<cut]); b.update(m[0..<cut])
        let snap = a.finalize()
        a.update(m[cut...]); b.update(m[cut...])
        if a.finalize() != want256 || b.finalize() != want384 || snap != SHA256.hash(Array(m[0..<cut])) { splitOK = false }
    }
    t.check(splitOK, "split updates and snapshots")
    var three = SHA256()
    for b in m { three.update([b]) }
    t.equal(three.finalize(), want256, "byte-at-a-time")
    t.equal(CryptoHashAlgorithm.sha384.hash(m), want384, "CryptoHashAlgorithm")
}

func macTests(_ t: Tests) {
    t.section("HMAC (RFC 4231)")
    struct Case { let key: [UInt8]; let data: [UInt8]; let s256: String; let s384: String; let s512: String }
    let cases = [
        Case(key: [UInt8](repeating: 0x0b, count: 20), data: ascii("Hi There"),
             s256: "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
             s384: "afd03944d84895626b0825f4ab46907f15f9dadbe4101ec682aa034c7cebc59cfaea9ea9076ede7f4af152e8b2fa9cb6",
             s512: "87aa7cdea5ef619d4ff0b4241a1d6cb02379f4e2ce4ec2787ad0b30545e17cdedaa833b7d6b8a702038b274eaea3f4e4be9d914eeb61f1702e696c203a126854"),
        Case(key: ascii("Jefe"), data: ascii("what do ya want for nothing?"),
             s256: "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
             s384: "af45d2e376484031617f78d2b58a6b1b9c7ef464f5a01b47e42ec3736322445e8e2240ca5e69e2c78b3239ecfab21649",
             s512: "164b7a7bfcf819e2e395fbe73b56e0a387bd64222e831fd610270cd7ea2505549758bf75c05a994a6d034f65f8f0e6fdcaeab1a34d4a6b4b636e070a38bce737"),
        Case(key: [UInt8](repeating: 0xaa, count: 20), data: [UInt8](repeating: 0xdd, count: 50),
             s256: "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe",
             s384: "88062608d3e6ad8a0aa2ace014c8a86f0aa635d947ac9febe83ef4e55966144b2a5ab39dc13814b94e3ab6e101a34f27",
             s512: "fa73b0089d56a284efb0f0756c890be9b1b5dbdd8ee81a3655f83e33b2279d39bf3e848279a722c806b485a47e67c807b946a337bee8942674278859e13292fb"),
        Case(key: [UInt8](repeating: 0xaa, count: 131), data: ascii("Test Using Larger Than Block-Size Key - Hash Key First"),
             s256: "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54",
             s384: "4ece084485813e9088d2c63a041bc5b44f9ef1012a2b588f3cd11f05033ac4c60c2ef6ab4030fe8296248df163f44952",
             s512: "80b24263c7c1a3ebb71493c1dd7be8b49b46d1f41b4aeec1121b013783f8f3526b56d037e05f2598bd0fd2215d6a1e5295e64f73f63f0aec8b915a985d786598"),
    ]
    for (i, c) in cases.enumerated() {
        t.equal(hex(HMAC<SHA256>.mac(key: c.key, message: c.data)), c.s256, "case \(i) sha256")
        t.equal(hex(HMAC<SHA384>.mac(key: c.key, message: c.data)), c.s384, "case \(i) sha384")
        t.equal(hex(HMAC<SHA512>.mac(key: c.key, message: c.data)), c.s512, "case \(i) sha512")
    }

    t.section("HKDF (RFC 5869)")
    let ikm = [UInt8](repeating: 0x0b, count: 22)
    let prk1 = HKDF<SHA256>.extract(salt: unhex("000102030405060708090a0b0c"), ikm: ikm)
    t.equal(hex(prk1), "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5", "case 1 prk")
    t.equal(hex(HKDF<SHA256>.expand(prk: prk1, info: unhex("f0f1f2f3f4f5f6f7f8f9"), length: 42) ?? []),
            "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865", "case 1 okm")
    let prk3 = HKDF<SHA256>.extract(salt: [], ikm: ikm)
    t.equal(hex(prk3), "19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04", "case 3 prk")
    t.equal(hex(HKDF<SHA256>.expand(prk: prk3, info: [], length: 42) ?? []),
            "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8", "case 3 okm")
    t.check(HKDF<SHA256>.expand(prk: prk3, info: [], length: 255 * 32 + 1) == nil, "too long")
    t.equal(HKDF<SHA256>.expand(prk: prk3, info: [], length: 255 * 32)?.count ?? 0, 255 * 32, "max length")

    t.section("HKDF-Expand-Label (RFC 8448)")
    // The simple 1-RTT handshake's key schedule, up to the handshake keys.
    let early = HKDF<SHA256>.extract(salt: [], ikm: [UInt8](repeating: 0, count: 32))
    t.equal(hex(early), "33ad0a1c607ec03b09e6cd9893680ce210adf300aa1f2660e1b22e10f170f92a", "early secret")
    let derived = HKDF<SHA256>.deriveSecret(secret: early, label: "derived", transcriptHash: SHA256.hash([])) ?? []
    t.equal(hex(derived), "6f2615a108c702c5678f54fc9dbab69716c076189c48250cebeac3576c3611ba", "derived")
    let shared = unhex("8bd4054fb55b9d63fdfbacf9f04b9f0d35e6d63f537563efd46272900f89492d")
    let hs = HKDF<SHA256>.extract(salt: derived, ikm: shared)
    t.equal(hex(hs), "1dc826e93606aa6fdc0aadc12f741b01046aa6b99f691ed221a9f0ca043fbeac", "handshake secret")
    let sHS = unhex("b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38")
    t.equal(hex(HKDF<SHA256>.expandLabel(secret: sHS, label: "key", context: [], length: 16) ?? []),
            "3fce516009c21727d0f2e4e86ee403bc", "server handshake key")
    t.equal(hex(HKDF<SHA256>.expandLabel(secret: sHS, label: "iv", context: [], length: 12) ?? []),
            "5d313eb2671276ee13000b30", "server handshake iv")
}

func aesTests(_ t: Tests) {
    t.section("AES (FIPS 197 C.1-C.3)")
    let pt = unhex("00112233445566778899aabbccddeeff")
    var k: [UInt8] = []
    for i in 0..<32 { k.append(UInt8(i)) }
    t.equal(hex(AES(key: Array(k[0..<16]))!.encrypt(block: pt)), "69c4e0d86a7b0430d8cdb78070b4c55a", "aes-128")
    t.equal(hex(AES(key: Array(k[0..<24]))!.encrypt(block: pt)), "dda97ca4864cdfe06eaf70a0ec0d7191", "aes-192")
    t.equal(hex(AES(key: k)!.encrypt(block: pt)), "8ea2b7ca516745bfeafc49904b496089", "aes-256")
    t.check(AES(key: [1, 2, 3]) == nil, "bad key size")

    t.section("AES-GCM (GCM spec test cases)")
    struct G { let key: String; let iv: String; let p: String; let a: String; let c: String; let tag: String }
    let p64 = "d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255"
    let p60 = String(p64.prefix(120))
    let aad = "feedfacedeadbeeffeedfacedeadbeefabaddad2"
    let k1 = "feffe9928665731c6d6a8f9467308308"
    let gcm = [
        G(key: "00000000000000000000000000000000", iv: "000000000000000000000000", p: "", a: "", c: "", tag: "58e2fccefa7e3061367f1d57a4e7455a"),
        G(key: "00000000000000000000000000000000", iv: "000000000000000000000000", p: "00000000000000000000000000000000", a: "",
          c: "0388dace60b6a392f328c2b971b2fe78", tag: "ab6e47d42cec13bdf53a67b21257bddf"),
        G(key: k1, iv: "cafebabefacedbaddecaf888", p: p64, a: "",
          c: "42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091473f5985",
          tag: "4d5c2af327cd64a62cf35abd2ba6fab4"),
        G(key: k1, iv: "cafebabefacedbaddecaf888", p: p60, a: aad,
          c: "42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091",
          tag: "5bc94fbc3221a5db94fae95ae7121a47"),
        G(key: k1, iv: "cafebabefacedbad", p: p60, a: aad,
          c: "61353b4c2806934a777ff51fa22a4755699b2a714fcdc6f83766e5f97b6c742373806900e49f24b22b097544d4896b424989b5e1ebac0f07c23f4598",
          tag: "3612d2e79e3b0785561be14aaca2fccb"),
        G(key: k1, iv: "9313225df88406e555909c5aff5269aa6a7a9538534f7da1e4c303d2a318a728c3c0c95156809539fcf0e2429a6b525416aedbf5a0de6a57a637b39b", p: p60, a: aad,
          c: "8ce24998625615b603a033aca13fb894be9112a5c3a211a8ba262a3cca7e2ca701e4a9a4fba43c90ccdcb281d48c7c6fd62875d2aca417034c34aee5",
          tag: "619cc5aefffe0bfa462af43c1699d050"),
        G(key: "0000000000000000000000000000000000000000000000000000000000000000", iv: "000000000000000000000000", p: "", a: "", c: "",
          tag: "530f8afbc74536b9a963b4f1c4cb738b"),
        G(key: "0000000000000000000000000000000000000000000000000000000000000000", iv: "000000000000000000000000", p: "00000000000000000000000000000000", a: "",
          c: "cea7403d4d606b6e074ec5d3baf39d18", tag: "d0d1c8a799996bf0265b98b5d48ab919"),
        G(key: k1 + k1, iv: "cafebabefacedbaddecaf888", p: p64, a: "",
          c: "522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662898015ad",
          tag: "b094dac5d93471bdec1a502270e3cc6c"),
        G(key: k1 + k1, iv: "cafebabefacedbaddecaf888", p: p60, a: aad,
          c: "522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662",
          tag: "76fc6ece0f4e1768cddf8853bb2d551b"),
    ]
    for (i, g) in gcm.enumerated() {
        guard let aead = AESGCM(key: unhex(g.key)) else { t.check(false, "case \(i) key"); continue }
        let sealed = aead.seal(nonce: unhex(g.iv), aad: unhex(g.a), plaintext: unhex(g.p))
        t.equal(hex(sealed), g.c + g.tag, "case \(i) seal")
        t.equal(aead.open(nonce: unhex(g.iv), aad: unhex(g.a), ciphertextAndTag: sealed) ?? [0xee], unhex(g.p), "case \(i) open")
        aeadNegative(t, "gcm case \(i)", sealed, unhex(g.a)) { aead.open(nonce: unhex(g.iv), aad: $1, ciphertextAndTag: $0) }
    }
    // Wider round trips (lengths across block boundaries), against Python
    // `cryptography`.
    if let data = t.readFile("lib/crypto/fixtures/aead.txt") {
        var n = 0
        for f in fixtureLines(data) where f.count == 6 {
            let key = unhex(f[1]), nonce = unhex(f[2]), a = f[3] == "-" ? [] : unhex(f[3])
            let p = f[4] == "-" ? [] : unhex(f[4])
            if f[0] == "gcm", let g = AESGCM(key: key) {
                t.equal(hex(g.seal(nonce: nonce, aad: a, plaintext: p)), f[5], "fixture gcm \(n)")
            } else if f[0] == "chacha", let c = ChaCha20Poly1305(key: key) {
                t.equal(hex(c.seal(nonce: nonce, aad: a, plaintext: p)), f[5], "fixture chacha \(n)")
            } else { t.check(false, "fixture line \(n)") }
            n += 1
        }
        t.check(n >= 40, "aead fixture lines")
    }
}

/// Every single-bit flip of the sealed message, a truncation, and an AAD
/// change must be rejected.
func aeadNegative(_ t: Tests, _ name: String, _ sealed: [UInt8], _ aad: [UInt8],
                  _ open: ([UInt8], [UInt8]) -> [UInt8]?) {
    var rejected = true
    for i in 0..<sealed.count {
        for bit in 0..<8 {
            var m = sealed
            m[i] ^= UInt8(1 << bit)
            if open(m, aad) != nil { rejected = false }
        }
    }
    t.check(rejected, "\(name): bit flips rejected")
    t.check(open(Array(sealed.dropLast()), aad) == nil, "\(name): truncated rejected")
    t.check(open(Array(sealed.prefix(15)), aad) == nil, "\(name): short rejected")
    t.check(open(sealed, aad + [0]) == nil, "\(name): aad change rejected")
}
