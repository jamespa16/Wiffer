// A small fixed-width bignum for public-key verification: RSA moduli up to
// 4096 bits and the P-256 / P-384 fields and group orders.
//
//   CryptoBigInt(bytes: be)        big-endian bytes -> little-endian 64-bit limbs
//   x.bytes(count: n)              back to n big-endian bytes (nil if too big)
//   x.bitLength, isZero, compare(a, b)
//   CryptoMontgomery(modulus: m)   odd modulus; values are [UInt64] of
//                                  exactly `limbs` limbs, < m
//     toMont(a) / fromMont(a)      a*R mod m and back (R = 2^(64*limbs))
//     mul(a, b)                    a*b/R mod m (CIOS); in Montgomery form
//                                  that is ordinary multiplication
//     add, sub, pow(base, exponent limbs), inverse (Fermat, prime m)
//
// mul/add/sub do the same work whatever the values (the final conditional
// subtraction is a masked select). pow is square-and-multiply on the
// exponent's bits, so it is only for public exponents (RSA e, p-2, n-2).

struct CryptoBigInt: Equatable {
    var limbs: [UInt64]   // little-endian

    init(limbs: [UInt64]) { self.limbs = limbs }

    /// Big-endian bytes; `limbCount` pads (or the minimum is used).
    init(bytes: [UInt8], limbCount: Int? = nil) {
        let need = (bytes.count + 7) / 8
        var l = [UInt64](repeating: 0, count: max(limbCount ?? need, need))
        var i = 0
        for b in bytes.reversed() {
            l[i / 8] |= UInt64(b) << (UInt64(i % 8) * 8)
            i += 1
        }
        limbs = l
    }

    var isZero: Bool {
        var acc: UInt64 = 0
        for x in limbs { acc |= x }
        return acc == 0
    }

    var bitLength: Int {
        var i = limbs.count - 1
        while i >= 0 && limbs[i] == 0 { i -= 1 }
        if i < 0 { return 0 }
        return i * 64 + (64 - limbs[i].leadingZeroBitCount)
    }

    /// Exactly `count` big-endian bytes, or nil if the value doesn't fit.
    func bytes(count: Int) -> [UInt8]? {
        guard bitLength <= count * 8 else { return nil }
        var out = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            let limb = i / 8
            if limb < limbs.count {
                out[count - 1 - i] = UInt8(truncatingIfNeeded: limbs[limb] >> (UInt64(i % 8) * 8))
            }
        }
        return out
    }

    /// Resized to `n` limbs (high limbs dropped must be zero: caller checks).
    func resized(_ n: Int) -> [UInt64] {
        if limbs.count == n { return limbs }
        if limbs.count > n { return Array(limbs[0..<n]) }
        return limbs + [UInt64](repeating: 0, count: n - limbs.count)
    }

    /// -1, 0 or 1 (variable time; for public values).
    static func compare(_ a: [UInt64], _ b: [UInt64]) -> Int {
        let n = max(a.count, b.count)
        var i = n - 1
        while i >= 0 {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x < y ? -1 : 1 }
            i -= 1
        }
        return 0
    }

    /// r = a - b over equal-length limbs; returns the borrow (0 or 1).
    @discardableResult
    static func subtract(_ a: [UInt64], _ b: [UInt64], into r: inout [UInt64]) -> UInt64 {
        var borrow: UInt64 = 0
        for i in 0..<a.count {
            let (d1, o1) = a[i].subtractingReportingOverflow(b[i])
            let (d2, o2) = d1.subtractingReportingOverflow(borrow)
            r[i] = d2
            borrow = (o1 ? 1 : 0) | (o2 ? 1 : 0)
        }
        return borrow
    }

    /// r = a + b over equal-length limbs; returns the carry.
    @discardableResult
    static func add(_ a: [UInt64], _ b: [UInt64], into r: inout [UInt64]) -> UInt64 {
        var carry: UInt64 = 0
        for i in 0..<a.count {
            let (s1, o1) = a[i].addingReportingOverflow(b[i])
            let (s2, o2) = s1.addingReportingOverflow(carry)
            r[i] = s2
            carry = (o1 ? 1 : 0) | (o2 ? 1 : 0)
        }
        return carry
    }

    /// r = mask ? a : b, limb by limb (mask is all ones or zero).
    static func select(_ mask: UInt64, _ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        var r = b
        for i in 0..<r.count { r[i] = (a[i] & mask) | (b[i] & ~mask) }
        return r
    }
}

struct CryptoMontgomery {
    let modulus: [UInt64]
    let limbs: Int
    let n0inv: UInt64        // -m^-1 mod 2^64
    let rSquared: [UInt64]   // R^2 mod m
    let one: [UInt64]        // R mod m (1 in Montgomery form)

    /// nil unless the modulus is odd and greater than 1.
    init?(modulus m: CryptoBigInt) {
        var l = m.limbs
        while l.count > 1 && l[l.count - 1] == 0 { l.removeLast() }
        guard !l.isEmpty, l[0] & 1 == 1, l.count > 1 || l[0] > 1 else { return nil }
        modulus = l
        limbs = l.count
        var inv: UInt64 = l[0]                 // correct to 3 bits
        for _ in 0..<5 { inv = inv &* (2 &- l[0] &* inv) }
        n0inv = 0 &- inv
        // R mod m and R^2 mod m by doubling 1 modulo m.
        var x = [UInt64](repeating: 0, count: l.count)
        x[0] = 1
        var t = x
        var r: [UInt64] = []
        for i in 0..<(128 * l.count) {
            // x = 2x mod m (x < m, so one subtraction is enough).
            var top: UInt64 = 0
            for j in 0..<x.count {
                let v = x[j]
                x[j] = (v << 1) | top
                top = v >> 63
            }
            let borrow = CryptoBigInt.subtract(x, l, into: &t)
            // keep t if top carried out or no borrow (x >= m)
            let useT: UInt64 = (top | (borrow ^ 1)) != 0 ? ~0 : 0
            x = CryptoBigInt.select(useT, t, x)
            if i == 64 * l.count - 1 { r = x }
        }
        one = r
        rSquared = x
    }

    /// a * b / R mod m. Inputs must be < m and have `limbs` limbs.
    func mul(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        let k = limbs
        var out = [UInt64](repeating: 0, count: k)
        withUnsafeTemporaryAllocation(of: UInt64.self, capacity: k + 2) { t in
            for i in 0..<(k + 2) { t[i] = 0 }
            a.withUnsafeBufferPointer { ap in
                b.withUnsafeBufferPointer { bp in
                    modulus.withUnsafeBufferPointer { np in
                        for i in 0..<k {
                            let bi = UInt128(bp[i])
                            var c: UInt128 = 0
                            for j in 0..<k {
                                let s = UInt128(ap[j]) &* bi &+ UInt128(t[j]) &+ c
                                t[j] = UInt64(truncatingIfNeeded: s)
                                c = s >> 64
                            }
                            var s = UInt128(t[k]) &+ c
                            t[k] = UInt64(truncatingIfNeeded: s)
                            t[k + 1] = UInt64(truncatingIfNeeded: s >> 64)
                            let m = UInt128(t[0] &* n0inv)
                            s = UInt128(t[0]) &+ m &* UInt128(np[0])
                            c = s >> 64
                            for j in 1..<max(k, 1) {
                                s = UInt128(t[j]) &+ m &* UInt128(np[j]) &+ c
                                t[j - 1] = UInt64(truncatingIfNeeded: s)
                                c = s >> 64
                            }
                            s = UInt128(t[k]) &+ c
                            t[k - 1] = UInt64(truncatingIfNeeded: s)
                            t[k] = t[k + 1] &+ UInt64(truncatingIfNeeded: s >> 64)
                        }
                    }
                }
            }
            // t < 2m: subtract m unless that borrows past t[k].
            var borrow: UInt64 = 0
            for j in 0..<k {
                let (d1, o1) = t[j].subtractingReportingOverflow(modulus[j])
                let (d2, o2) = d1.subtractingReportingOverflow(borrow)
                out[j] = d2
                borrow = (o1 ? 1 : 0) | (o2 ? 1 : 0)
            }
            let keepT: UInt64 = (borrow > t[k]) ? ~0 : 0   // t < m
            for j in 0..<k { out[j] = (t[j] & keepT) | (out[j] & ~keepT) }
        }
        return out
    }

    func toMont(_ a: [UInt64]) -> [UInt64] { mul(a, rSquared) }

    func fromMont(_ a: [UInt64]) -> [UInt64] {
        var o = [UInt64](repeating: 0, count: limbs)
        o[0] = 1
        return mul(a, o)
    }

    func add(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        var s = a, d = a
        let carry = CryptoBigInt.add(a, b, into: &s)
        let borrow = CryptoBigInt.subtract(s, modulus, into: &d)
        let useD: UInt64 = (carry | (borrow ^ 1)) != 0 ? ~0 : 0
        return CryptoBigInt.select(useD, d, s)
    }

    func sub(_ a: [UInt64], _ b: [UInt64]) -> [UInt64] {
        var d = a, s = a
        let borrow = CryptoBigInt.subtract(a, b, into: &d)
        CryptoBigInt.add(d, modulus, into: &s)
        return CryptoBigInt.select(0 &- borrow, s, d)
    }

    /// base^exponent with base in Montgomery form; exponent is public.
    func pow(_ base: [UInt64], _ exponent: [UInt64]) -> [UInt64] {
        var r = one
        let bits = CryptoBigInt(limbs: exponent).bitLength
        var i = bits - 1
        while i >= 0 {
            r = mul(r, r)
            if (exponent[i / 64] >> UInt64(i % 64)) & 1 == 1 { r = mul(r, base) }
            i -= 1
        }
        return r
    }

    /// a^(m-2): the inverse for a prime modulus (0 maps to 0).
    func inverse(_ a: [UInt64]) -> [UInt64] {
        var two = [UInt64](repeating: 0, count: limbs)
        two[0] = 2
        var e = modulus
        CryptoBigInt.subtract(modulus, two, into: &e)
        return pow(a, e)
    }

    /// Reduce a value with `limbs` limbs that is below 2m.
    func reduceOnce(_ a: [UInt64]) -> [UInt64] {
        var d = a
        let borrow = CryptoBigInt.subtract(a, modulus, into: &d)
        return CryptoBigInt.select(0 &- borrow, a, d)
    }

    /// a < m (variable time; public values).
    func isReduced(_ a: [UInt64]) -> Bool { CryptoBigInt.compare(a, modulus) < 0 }
}
