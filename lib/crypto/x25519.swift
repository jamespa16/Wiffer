// X25519 Diffie-Hellman (RFC 7748).
//
//   X25519.publicKey(privateKey: k32)                 -> 32 bytes
//   X25519.sharedSecret(privateKey: k32, peerPublicKey: u32) -> 32 bytes,
//       or nil if the result is all zeros (a small-order peer key, which
//       TLS 1.3 must reject) or an input has the wrong length
//   X25519.scalarMult(scalar:u:)                      raw RFC 7748 function
//
// The private key is 32 random bytes from the caller (clamped here). Field
// elements are five 51-bit limbs with 128-bit products; the ladder uses
// constant-time conditional swaps and the same operations for every bit.

struct FE25519 {
    var v0, v1, v2, v3, v4: UInt64

    static let mask: UInt64 = (1 << 51) - 1
    static var zero: FE25519 { FE25519(v0: 0, v1: 0, v2: 0, v3: 0, v4: 0) }
    static var one: FE25519 { FE25519(v0: 1, v1: 0, v2: 0, v3: 0, v4: 0) }

    init(v0: UInt64, v1: UInt64, v2: UInt64, v3: UInt64, v4: UInt64) {
        self.v0 = v0; self.v1 = v1; self.v2 = v2; self.v3 = v3; self.v4 = v4
    }

    /// Little-endian, top bit ignored (RFC 7748 decodeUCoordinate).
    init(bytes b: [UInt8]) {
        var x: UInt128 = 0, y: UInt128 = 0
        for i in (0..<16).reversed() { x = x << 8 | UInt128(b[i]); y = y << 8 | UInt128(b[16 + i]) }
        let m = UInt128(FE25519.mask)
        v0 = UInt64(x & m)
        v1 = UInt64((x >> 51) & m)
        v2 = UInt64(((x >> 102) | (y << 26)) & m)
        v3 = UInt64((y >> 25) & m)
        v4 = UInt64((y >> 76) & m)
    }

    /// Fully reduced little-endian encoding.
    var bytes: [UInt8] {
        // After two passes t < 2p. Subtract p (add 19, drop 2^255) if
        // t + 19 reaches 2^255.
        let w = self.carried().carried()
        let (keep, _) = w.chain(0)
        let (sub, top) = w.chain(19)
        let ge = 0 &- top
        var t = keep
        t.v0 = (t.v0 & ~ge) | (sub.v0 & ge); t.v1 = (t.v1 & ~ge) | (sub.v1 & ge)
        t.v2 = (t.v2 & ~ge) | (sub.v2 & ge); t.v3 = (t.v3 & ~ge) | (sub.v3 & ge)
        t.v4 = (t.v4 & ~ge) | (sub.v4 & ge)
        let lo = UInt128(t.v0) | UInt128(t.v1) << 51 | UInt128(t.v2) &<< 102
        let hi = UInt128(t.v2 >> 26) | UInt128(t.v3) << 25 | UInt128(t.v4) << 76
        var out = [UInt8](repeating: 0, count: 32)
        for i in 0..<16 {
            out[i] = UInt8(truncatingIfNeeded: lo >> (UInt128(i) * 8))
            out[16 + i] = UInt8(truncatingIfNeeded: hi >> (UInt128(i) * 8))
        }
        return out
    }

    /// self + k with carries rippled up (no wrap): limbs below 2^51, and
    /// bit 255 returned separately.
    func chain(_ k: UInt64) -> (FE25519, UInt64) {
        let m = FE25519.mask
        var c0 = v0 &+ k
        var c1 = v1 &+ (c0 >> 51); c0 &= m
        var c2 = v2 &+ (c1 >> 51); c1 &= m
        var c3 = v3 &+ (c2 >> 51); c2 &= m
        var c4 = v4 &+ (c3 >> 51); c3 &= m
        let top = c4 >> 51
        c4 &= m
        return (FE25519(v0: c0, v1: c1, v2: c2, v3: c3, v4: c4), top)
    }

    /// One carry pass: limbs below 2^51 (+ a little in v0).
    @inline(__always) func carried() -> FE25519 {
        let m = FE25519.mask
        var r = self
        r.v1 &+= r.v0 >> 51; r.v0 &= m
        r.v2 &+= r.v1 >> 51; r.v1 &= m
        r.v3 &+= r.v2 >> 51; r.v2 &= m
        r.v4 &+= r.v3 >> 51; r.v3 &= m
        r.v0 &+= (r.v4 >> 51) &* 19; r.v4 &= m
        return r
    }

    @inline(__always) static func + (a: FE25519, b: FE25519) -> FE25519 {
        FE25519(v0: a.v0 &+ b.v0, v1: a.v1 &+ b.v1, v2: a.v2 &+ b.v2, v3: a.v3 &+ b.v3, v4: a.v4 &+ b.v4).carried()
    }

    /// a - b as a + 4p - b (limbs of b are below 2^53).
    @inline(__always) static func - (a: FE25519, b: FE25519) -> FE25519 {
        FE25519(v0: (a.v0 &+ 0x1f_ffff_ffff_ffb4) &- b.v0, v1: (a.v1 &+ 0x1f_ffff_ffff_fffc) &- b.v1,
                v2: (a.v2 &+ 0x1f_ffff_ffff_fffc) &- b.v2, v3: (a.v3 &+ 0x1f_ffff_ffff_fffc) &- b.v3,
                v4: (a.v4 &+ 0x1f_ffff_ffff_fffc) &- b.v4).carried()
    }

    @inline(__always) static func wide(_ x: UInt64, _ y: UInt64) -> UInt128 { UInt128(x) &* UInt128(y) }

    static func * (a: FE25519, b: FE25519) -> FE25519 {
        let b1 = b.v1 &* 19, b2 = b.v2 &* 19, b3 = b.v3 &* 19, b4 = b.v4 &* 19
        let r0 = wide(a.v0, b.v0) &+ wide(a.v1, b4) &+ wide(a.v2, b3) &+ wide(a.v3, b2) &+ wide(a.v4, b1)
        var r1 = wide(a.v0, b.v1) &+ wide(a.v1, b.v0) &+ wide(a.v2, b4) &+ wide(a.v3, b3) &+ wide(a.v4, b2)
        var r2 = wide(a.v0, b.v2) &+ wide(a.v1, b.v1) &+ wide(a.v2, b.v0) &+ wide(a.v3, b4) &+ wide(a.v4, b3)
        var r3 = wide(a.v0, b.v3) &+ wide(a.v1, b.v2) &+ wide(a.v2, b.v1) &+ wide(a.v3, b.v0) &+ wide(a.v4, b4)
        var r4 = wide(a.v0, b.v4) &+ wide(a.v1, b.v3) &+ wide(a.v2, b.v2) &+ wide(a.v3, b.v1) &+ wide(a.v4, b.v0)
        return reduceWide(r0, &r1, &r2, &r3, &r4)
    }

    @inline(__always) static func reduceWide(_ r0: UInt128, _ r1: inout UInt128, _ r2: inout UInt128,
                                             _ r3: inout UInt128, _ r4: inout UInt128) -> FE25519 {
        let m = UInt128(mask)
        r1 &+= r0 >> 51
        r2 &+= r1 >> 51
        r3 &+= r2 >> 51
        r4 &+= r3 >> 51
        let c = r4 >> 51
        let lo = (r0 & m) &+ c &* 19
        var out = FE25519(v0: UInt64(lo & m), v1: UInt64(r1 & m) &+ UInt64(lo >> 51),
                          v2: UInt64(r2 & m), v3: UInt64(r3 & m), v4: UInt64(r4 & m))
        out.v2 &+= out.v1 >> 51; out.v1 &= mask
        return out
    }

    func squared() -> FE25519 { self * self }

    func squared(times n: Int) -> FE25519 {
        var r = self
        for _ in 0..<n { r = r * r }
        return r
    }

    func timesSmall(_ k: UInt64) -> FE25519 {
        var r1 = FE25519.wide(v1, k), r2 = FE25519.wide(v2, k), r3 = FE25519.wide(v3, k), r4 = FE25519.wide(v4, k)
        return FE25519.reduceWide(FE25519.wide(v0, k), &r1, &r2, &r3, &r4)
    }

    /// self^(p-2).
    func inverted() -> FE25519 {
        let z2 = squared()
        let z9 = z2.squared(times: 2) * self
        let z11 = z9 * z2
        let z2_5 = z11.squared() * z9                     // 2^5 - 1
        let z2_10 = z2_5.squared(times: 5) * z2_5         // 2^10 - 1
        let z2_20 = z2_10.squared(times: 10) * z2_10
        let z2_40 = z2_20.squared(times: 20) * z2_20
        let z2_50 = z2_40.squared(times: 10) * z2_10
        let z2_100 = z2_50.squared(times: 50) * z2_50
        let z2_200 = z2_100.squared(times: 100) * z2_100
        let z2_250 = z2_200.squared(times: 50) * z2_50
        return z2_250.squared(times: 5) * z11             // 2^255 - 21
    }

    /// Swap a and b when `bit` is 1, without branching.
    @inline(__always) static func cswap(_ a: inout FE25519, _ b: inout FE25519, _ bit: UInt64) {
        let m = 0 &- bit
        var t = m & (a.v0 ^ b.v0); a.v0 ^= t; b.v0 ^= t
        t = m & (a.v1 ^ b.v1); a.v1 ^= t; b.v1 ^= t
        t = m & (a.v2 ^ b.v2); a.v2 ^= t; b.v2 ^= t
        t = m & (a.v3 ^ b.v3); a.v3 ^= t; b.v3 ^= t
        t = m & (a.v4 ^ b.v4); a.v4 ^= t; b.v4 ^= t
    }
}

enum X25519 {
    static let basePoint: [UInt8] = [9] + [UInt8](repeating: 0, count: 31)

    /// RFC 7748 X25519(k, u): 32-byte scalar and u-coordinate.
    static func scalarMult(scalar: [UInt8], u: [UInt8]) -> [UInt8] {
        precondition(scalar.count == 32 && u.count == 32)
        var k = scalar
        k[0] &= 248; k[31] &= 127; k[31] |= 64
        let x1 = FE25519(bytes: u)
        var x2 = FE25519.one, z2 = FE25519.zero, x3 = x1, z3 = FE25519.one
        var swap: UInt64 = 0
        var bit = 254
        while bit >= 0 {
            let kt = UInt64((k[bit >> 3] >> UInt8(bit & 7)) & 1)
            swap ^= kt
            FE25519.cswap(&x2, &x3, swap)
            FE25519.cswap(&z2, &z3, swap)
            swap = kt
            let a = x2 + z2, aa = a.squared()
            let b = x2 - z2, bb = b.squared()
            let e = aa - bb
            let c = x3 + z3, d = x3 - z3
            let da = d * a, cb = c * b
            x3 = (da + cb).squared()
            z3 = x1 * (da - cb).squared()
            x2 = aa * bb
            z2 = e * (aa + e.timesSmall(121665))
            bit -= 1
        }
        FE25519.cswap(&x2, &x3, swap)
        FE25519.cswap(&z2, &z3, swap)
        return (x2 * z2.inverted()).bytes
    }

    static func publicKey(privateKey: [UInt8]) -> [UInt8]? {
        guard privateKey.count == 32 else { return nil }
        return scalarMult(scalar: privateKey, u: basePoint)
    }

    static func sharedSecret(privateKey: [UInt8], peerPublicKey: [UInt8]) -> [UInt8]? {
        guard privateKey.count == 32, peerPublicKey.count == 32 else { return nil }
        let s = scalarMult(scalar: privateKey, u: peerPublicKey)
        var acc: UInt8 = 0
        for b in s { acc |= b }
        return acc == 0 ? nil : s
    }
}
