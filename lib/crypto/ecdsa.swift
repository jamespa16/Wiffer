// NIST P-256 and P-384: ECDSA signature verification (FIPS 186-4/5) and
// ECDH (SEC 1), for TLS 1.3 CertificateVerify, X.509 chains and the P-256
// HelloRetryRequest key share.
//
//   P256.verify(publicKey: q, digest: h, r: r, s: s) -> Bool
//       q: SEC 1 uncompressed point (0x04 || X || Y, 65 bytes; 97 for P-384)
//       h: the message hash (any length; truncated to the order's size)
//       r, s: big-endian unsigned integers as DER INTEGER contents (leading
//             zero bytes are fine)
//   P256.verify(publicKey:digest:derSignature:)   ECDSA-Sig-Value DER
//   ecdsaParseDERSignature(der) -> (r, s)?         strict DER
//   P256.isValidPublicKey(q)
//   P256.publicKey(privateKey: d32) -> 65 bytes?   d must be in [1, n-1]
//   P256.sharedSecret(privateKey: d32, peerPublicKey: q) -> X (32 bytes)?
//   P384: the same with 48-byte scalars and coordinates.
//
// Arithmetic is CryptoMontgomery over 64-bit limbs; points are projective
// (X:Y:Z) and every addition (doubling too) uses the complete formulas of
// Renes, Costello and Batina (eprint 2015/1060, algorithm 4, a = -3), so
// the point at infinity and P = Q need no special cases. The ECDH scalar
// multiplication is double-and-add-always with masked selects; verify uses
// Shamir's trick and is variable time (its inputs are public).
// Compressed points are not supported (TLS 1.3 forbids them; certificates
// essentially never use them).

struct CryptoECPoint {
    var x: [UInt64], y: [UInt64], z: [UInt64]
}

final class CryptoECCurve {
    let p: CryptoMontgomery
    let n: CryptoMontgomery
    let b: [UInt64]          // Montgomery form
    let g: CryptoECPoint     // Montgomery form, Z = 1
    let byteCount: Int
    let limbs: Int

    init(p: String, n: String, b: String, gx: String, gy: String) {
        let pb = cryptoFromHex(p)
        byteCount = pb.count
        self.p = CryptoMontgomery(modulus: CryptoBigInt(bytes: pb))!
        self.n = CryptoMontgomery(modulus: CryptoBigInt(bytes: cryptoFromHex(n)))!
        limbs = self.p.limbs
        let f = self.p, l = limbs
        self.b = f.toMont(CryptoBigInt(bytes: cryptoFromHex(b), limbCount: l).limbs)
        g = CryptoECPoint(x: f.toMont(CryptoBigInt(bytes: cryptoFromHex(gx), limbCount: l).limbs),
                          y: f.toMont(CryptoBigInt(bytes: cryptoFromHex(gy), limbCount: l).limbs),
                          z: f.one)
    }

    static func p256() -> CryptoECCurve {
        CryptoECCurve(
            p: "ffffffff00000001000000000000000000000000ffffffffffffffffffffffff",
            n: "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551",
            b: "5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b",
            gx: "6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296",
            gy: "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5")
    }

    static func p384() -> CryptoECCurve {
        CryptoECCurve(
            p: "fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffeffffffff0000000000000000ffffffff",
            n: "ffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973",
            b: "b3312fa7e23ee7e4988e056be3f82d19181d9c6efe8141120314088f5013875ac656398d8a2ed19d2a85c8edd3ec2aef",
            gx: "aa87ca22be8b05378eb1c71ef320ad746e1d3b628ba79b9859f741e082542a385502f25dbf55296c3a545e3872760ab7",
            gy: "3617de4a96262c6f5d9e98bf9292dc29f8f41dbd289a147ce9da3113b5f0b8c00a60b1ce1d7e819d7a431d7c90ea0e5f")
    }

    var infinity: CryptoECPoint {
        CryptoECPoint(x: [UInt64](repeating: 0, count: limbs), y: p.one, z: [UInt64](repeating: 0, count: limbs))
    }

    /// Complete addition (RCB algorithm 4, a = -3); works for doubling.
    func add(_ p1: CryptoECPoint, _ p2: CryptoECPoint) -> CryptoECPoint {
        let f = p
        var t0 = f.mul(p1.x, p2.x)
        var t1 = f.mul(p1.y, p2.y)
        var t2 = f.mul(p1.z, p2.z)
        var t3 = f.add(p1.x, p1.y)
        var t4 = f.add(p2.x, p2.y)
        t3 = f.mul(t3, t4)
        t4 = f.add(t0, t1)
        t3 = f.sub(t3, t4)
        t4 = f.add(p1.y, p1.z)
        var x3 = f.add(p2.y, p2.z)
        t4 = f.mul(t4, x3)
        x3 = f.add(t1, t2)
        t4 = f.sub(t4, x3)
        x3 = f.add(p1.x, p1.z)
        var y3 = f.add(p2.x, p2.z)
        x3 = f.mul(x3, y3)
        y3 = f.add(t0, t2)
        y3 = f.sub(x3, y3)
        var z3 = f.mul(b, t2)
        x3 = f.sub(y3, z3)
        z3 = f.add(x3, x3)
        x3 = f.add(x3, z3)
        z3 = f.sub(t1, x3)
        x3 = f.add(t1, x3)
        y3 = f.mul(b, y3)
        t1 = f.add(t2, t2)
        t2 = f.add(t1, t2)
        y3 = f.sub(y3, t2)
        y3 = f.sub(y3, t0)
        t1 = f.add(y3, y3)
        y3 = f.add(t1, y3)
        t1 = f.add(t0, t0)
        t0 = f.add(t1, t0)
        t0 = f.sub(t0, t2)
        t1 = f.mul(t4, y3)
        t2 = f.mul(t0, y3)
        y3 = f.mul(x3, z3)
        y3 = f.add(y3, t2)
        x3 = f.mul(t3, x3)
        x3 = f.sub(x3, t1)
        z3 = f.mul(t4, z3)
        t1 = f.mul(t3, t0)
        z3 = f.add(z3, t1)
        return CryptoECPoint(x: x3, y: y3, z: z3)
    }

    func select(_ mask: UInt64, _ a: CryptoECPoint, _ b: CryptoECPoint) -> CryptoECPoint {
        CryptoECPoint(x: CryptoBigInt.select(mask, a.x, b.x), y: CryptoBigInt.select(mask, a.y, b.y),
                      z: CryptoBigInt.select(mask, a.z, b.z))
    }

    /// k * P for a secret scalar (big-endian, byteCount bytes): the same
    /// double, add and select for every bit.
    func scalarMul(_ k: [UInt8], _ pt: CryptoECPoint) -> CryptoECPoint {
        var r = infinity
        for byte in k {
            for i in (0..<8).reversed() {
                r = add(r, r)
                let s = add(r, pt)
                let bit = UInt64((byte >> UInt8(i)) & 1)
                r = select(0 &- bit, s, r)
            }
        }
        return r
    }

    /// u1 * G + u2 * Q (variable time), scalars as limbs.
    func doubleScalarMul(_ u1: [UInt64], _ u2: [UInt64], _ q: CryptoECPoint) -> CryptoECPoint {
        let gq = add(g, q)
        var r = infinity
        var started = false
        var i = 64 * limbs - 1
        while i >= 0 {
            if started { r = add(r, r) }
            let b1 = (u1[i / 64] >> UInt64(i % 64)) & 1, b2 = (u2[i / 64] >> UInt64(i % 64)) & 1
            if b1 == 1 && b2 == 1 { r = add(r, gq); started = true }
            else if b1 == 1 { r = add(r, g); started = true }
            else if b2 == 1 { r = add(r, q); started = true }
            i -= 1
        }
        return r
    }

    /// Affine (x, y) in normal form, or nil for the point at infinity.
    func affine(_ pt: CryptoECPoint) -> ([UInt64], [UInt64])? {
        if CryptoBigInt(limbs: pt.z).isZero { return nil }
        let zi = p.inverse(pt.z)
        return (p.fromMont(p.mul(pt.x, zi)), p.fromMont(p.mul(pt.y, zi)))
    }

    /// SEC 1 uncompressed point, checked to be on the curve.
    func decodePoint(_ bytes: [UInt8]) -> CryptoECPoint? {
        let c = byteCount
        guard bytes.count == 1 + 2 * c, bytes[0] == 4 else { return nil }
        let x = CryptoBigInt(bytes: Array(bytes[1...c]), limbCount: limbs).limbs
        let y = CryptoBigInt(bytes: Array(bytes[(c + 1)...]), limbCount: limbs).limbs
        guard p.isReduced(x), p.isReduced(y) else { return nil }
        let xm = p.toMont(x), ym = p.toMont(y)
        // y^2 == x^3 - 3x + b
        let lhs = p.mul(ym, ym)
        let x3 = p.mul(p.mul(xm, xm), xm)
        let threeX = p.add(p.add(xm, xm), xm)
        let rhs = p.add(p.sub(x3, threeX), b)
        guard lhs == rhs else { return nil }
        return CryptoECPoint(x: xm, y: ym, z: p.one)
    }

    func encodePoint(_ pt: CryptoECPoint) -> [UInt8]? {
        guard let a = affine(pt),
              let xb = CryptoBigInt(limbs: a.0).bytes(count: byteCount),
              let yb = CryptoBigInt(limbs: a.1).bytes(count: byteCount) else { return nil }
        return [4] + xb + yb
    }

    /// A big-endian integer in [1, n-1] as limbs, or nil.
    func scalar(_ bytes: [UInt8]) -> [UInt64]? {
        var s = bytes[...]
        while let f = s.first, f == 0 { s = s.dropFirst() }
        guard !s.isEmpty, s.count <= byteCount else { return nil }
        let v = CryptoBigInt(bytes: Array(s), limbCount: limbs).limbs
        guard n.isReduced(v) else { return nil }
        return v
    }

    func verify(publicKey: [UInt8], digest: [UInt8], r rBytes: [UInt8], s sBytes: [UInt8]) -> Bool {
        guard let q = decodePoint(publicKey), let r = scalar(rBytes), let s = scalar(sBytes) else { return false }
        // e: the leftmost bits of the digest (the orders here are whole bytes).
        let eb = digest.count > byteCount ? Array(digest[0..<byteCount]) : digest
        let e = n.reduceOnce(CryptoBigInt(bytes: eb, limbCount: limbs).limbs)
        let w = n.inverse(n.toMont(s))          // s^-1 * R
        let u1 = n.mul(e, w), u2 = n.mul(r, w)  // e/s, r/s
        guard let a = affine(doubleScalarMul(u1, u2, q)) else { return false }
        return n.reduceOnce(a.0) == r             // p < 2n for both curves
    }

    func publicKey(privateKey: [UInt8]) -> [UInt8]? {
        guard privateKey.count == byteCount, scalar(privateKey) != nil else { return nil }
        return encodePoint(scalarMul(privateKey, g))
    }

    func sharedSecret(privateKey: [UInt8], peerPublicKey: [UInt8]) -> [UInt8]? {
        guard privateKey.count == byteCount, scalar(privateKey) != nil,
              let q = decodePoint(peerPublicKey),
              let a = affine(scalarMul(privateKey, q)) else { return nil }
        return CryptoBigInt(limbs: a.0).bytes(count: byteCount)
    }
}

/// Hex digits to bytes (curve constants).
func cryptoFromHex(_ s: String) -> [UInt8] {
    var out: [UInt8] = []
    var hi: UInt8? = nil
    for c in s.utf8 {
        let v: UInt8
        switch c {
        case 0x30...0x39: v = c - 0x30
        case 0x61...0x66: v = c - 0x61 + 10
        default: continue
        }
        if let h = hi { out.append(h << 4 | v); hi = nil } else { hi = v }
    }
    return out
}

/// ECDSA-Sig-Value ::= SEQUENCE { r INTEGER, s INTEGER }, strict DER:
/// minimal lengths, minimal positive integers, nothing trailing. Returns
/// the integer contents (possibly with one leading zero byte).
func ecdsaParseDERSignature(_ der: [UInt8]) -> (r: [UInt8], s: [UInt8])? {
    var rd = ByteReader(der)
    func length(_ rd: inout ByteReader) -> Int? {
        guard let l = rd.u8() else { return nil }
        if l < 0x80 { return Int(l) }
        guard l == 0x81, let l2 = rd.u8(), l2 >= 0x80 else { return nil }
        return Int(l2)
    }
    func integer(_ rd: inout ByteReader) -> [UInt8]? {
        guard rd.u8() == 0x02, let n = length(&rd), n > 0, let v = rd.bytes(n) else { return nil }
        if v[0] & 0x80 != 0 { return nil }                       // negative
        if v.count > 1 && v[0] == 0 && v[1] & 0x80 == 0 { return nil }  // not minimal
        return v
    }
    guard rd.u8() == 0x30, let n = length(&rd), n == rd.remaining, var body = rd.sub(n),
          let r = integer(&body), let s = integer(&body), body.atEnd else { return nil }
    return (r, s)
}

enum P256 {
    static let byteCount = 32
    static func verify(publicKey: [UInt8], digest: [UInt8], r: [UInt8], s: [UInt8]) -> Bool {
        CryptoECCurve.p256().verify(publicKey: publicKey, digest: digest, r: r, s: s)
    }
    static func verify(publicKey: [UInt8], digest: [UInt8], derSignature: [UInt8]) -> Bool {
        guard let sig = ecdsaParseDERSignature(derSignature) else { return false }
        return verify(publicKey: publicKey, digest: digest, r: sig.r, s: sig.s)
    }
    static func isValidPublicKey(_ q: [UInt8]) -> Bool { CryptoECCurve.p256().decodePoint(q) != nil }
    static func publicKey(privateKey: [UInt8]) -> [UInt8]? {
        CryptoECCurve.p256().publicKey(privateKey: privateKey)
    }
    static func sharedSecret(privateKey: [UInt8], peerPublicKey: [UInt8]) -> [UInt8]? {
        CryptoECCurve.p256().sharedSecret(privateKey: privateKey, peerPublicKey: peerPublicKey)
    }
}

enum P384 {
    static let byteCount = 48
    static func verify(publicKey: [UInt8], digest: [UInt8], r: [UInt8], s: [UInt8]) -> Bool {
        CryptoECCurve.p384().verify(publicKey: publicKey, digest: digest, r: r, s: s)
    }
    static func verify(publicKey: [UInt8], digest: [UInt8], derSignature: [UInt8]) -> Bool {
        guard let sig = ecdsaParseDERSignature(derSignature) else { return false }
        return verify(publicKey: publicKey, digest: digest, r: sig.r, s: sig.s)
    }
    static func isValidPublicKey(_ q: [UInt8]) -> Bool { CryptoECCurve.p384().decodePoint(q) != nil }
    static func publicKey(privateKey: [UInt8]) -> [UInt8]? {
        CryptoECCurve.p384().publicKey(privateKey: privateKey)
    }
    static func sharedSecret(privateKey: [UInt8], peerPublicKey: [UInt8]) -> [UInt8]? {
        CryptoECCurve.p384().sharedSecret(privateKey: privateKey, peerPublicKey: peerPublicKey)
    }
}
