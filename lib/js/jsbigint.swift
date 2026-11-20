// Arbitrary-precision integer arithmetic for BigInt (ROADMAP Phase 9E).
// Pure functions on magnitudes: [UInt32], little endian (limb 0 is the
// least significant), normalized (no high zero limbs, zero = []). Signs
// travel separately (JSBigInt below). Nothing here allocates a heap cell,
// throws or traps: the realm layer (jsbigint_ops.swift) checks sizes
// against JSLimits.maxBigIntBits before calling anything that can grow.
//
// Algorithms: schoolbook add/sub, schoolbook multiplication with Karatsuba
// above jsBNKaratsubaThreshold limbs, Knuth algorithm D division,
// chunked conversion to and from text in any radix 2...36, two's complement
// bitwise operations, correctly rounded (ties to even) conversion to and
// from Double.

let jsBNKaratsubaThreshold = 40

/// A signed integer value (sign + magnitude). Zero is never negative.
struct JSBigInt {
    var negative: Bool
    var mag: [UInt32]
    init(negative: Bool, mag: [UInt32]) {
        self.mag = mag
        self.negative = mag.isEmpty ? false : negative
    }
    var isZero: Bool { mag.isEmpty }
    static let zero = JSBigInt(negative: false, mag: [])
}

@inline(__always) func jsBNTrim(_ a: inout [UInt32]) {
    while let l = a.last, l == 0 { a.removeLast() }
}

func jsBNFromUInt64(_ v: UInt64) -> [UInt32] {
    if v == 0 { return [] }
    let hi = UInt32(truncatingIfNeeded: v >> 32)
    return hi == 0 ? [UInt32(truncatingIfNeeded: v)] : [UInt32(truncatingIfNeeded: v), hi]
}

func jsBNBitLength(_ a: [UInt32]) -> Int {
    guard let l = a.last else { return 0 }
    return (a.count - 1) * 32 + (32 - l.leadingZeroBitCount)
}

func jsBNCmp(_ a: [UInt32], _ b: [UInt32]) -> Int {
    if a.count != b.count { return a.count < b.count ? -1 : 1 }
    var i = a.count - 1
    while i >= 0 {
        if a[i] != b[i] { return a[i] < b[i] ? -1 : 1 }
        i -= 1
    }
    return 0
}

func jsBNAdd(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
    let x = a.count >= b.count ? a : b
    let y = a.count >= b.count ? b : a
    var r: [UInt32] = []
    r.reserveCapacity(x.count + 1)
    var carry: UInt64 = 0
    for i in 0..<x.count {
        let s = UInt64(x[i]) + (i < y.count ? UInt64(y[i]) : 0) + carry
        r.append(UInt32(truncatingIfNeeded: s))
        carry = s >> 32
    }
    if carry != 0 { r.append(UInt32(truncatingIfNeeded: carry)) }
    return r
}

/// a - b for a >= b.
func jsBNSub(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
    var r: [UInt32] = []
    r.reserveCapacity(a.count)
    var borrow: UInt64 = 0
    for i in 0..<a.count {
        let d = UInt64(a[i]) &- (i < b.count ? UInt64(b[i]) : 0) &- borrow
        r.append(UInt32(truncatingIfNeeded: d))
        borrow = (d >> 63) & 1
    }
    jsBNTrim(&r)
    return r
}

func jsBNMulSmall(_ a: [UInt32], _ m: UInt32, add: UInt32 = 0) -> [UInt32] {
    var r: [UInt32] = []
    r.reserveCapacity(a.count + 1)
    var carry = UInt64(add)
    for x in a {
        let t = UInt64(x) * UInt64(m) + carry
        r.append(UInt32(truncatingIfNeeded: t))
        carry = t >> 32
    }
    if carry != 0 { r.append(UInt32(truncatingIfNeeded: carry)) }
    jsBNTrim(&r)
    return r
}

/// In place a = a * m + add.
func jsBNMulAddInPlace(_ a: inout [UInt32], _ m: UInt32, _ add: UInt32) {
    var carry = UInt64(add)
    for i in 0..<a.count {
        let t = UInt64(a[i]) * UInt64(m) + carry
        a[i] = UInt32(truncatingIfNeeded: t)
        carry = t >> 32
    }
    if carry != 0 { a.append(UInt32(truncatingIfNeeded: carry)) }
}

func jsBNMulSchool(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
    if a.isEmpty || b.isEmpty { return [] }
    var r = [UInt32](repeating: 0, count: a.count + b.count)
    for i in 0..<a.count {
        let ai = UInt64(a[i])
        if ai == 0 { continue }
        var carry: UInt64 = 0
        for j in 0..<b.count {
            let t = ai * UInt64(b[j]) + UInt64(r[i + j]) + carry
            r[i + j] = UInt32(truncatingIfNeeded: t)
            carry = t >> 32
        }
        r[i + b.count] = UInt32(truncatingIfNeeded: carry)
    }
    jsBNTrim(&r)
    return r
}

/// r += x << (limbs * 32), growing r as needed.
func jsBNAddShifted(_ r: inout [UInt32], _ x: [UInt32], _ limbs: Int) {
    if x.isEmpty { return }
    while r.count < x.count + limbs + 1 { r.append(0) }
    var carry: UInt64 = 0
    var i = 0
    while i < x.count || carry != 0 {
        let idx = limbs + i
        if idx >= r.count { r.append(0) }
        let s = UInt64(r[idx]) + (i < x.count ? UInt64(x[i]) : 0) + carry
        r[idx] = UInt32(truncatingIfNeeded: s)
        carry = s >> 32
        i += 1
    }
}

func jsBNMul(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
    if a.isEmpty || b.isEmpty { return [] }
    let n = max(a.count, b.count)
    if min(a.count, b.count) < jsBNKaratsubaThreshold { return jsBNMulSchool(a, b) }
    let h = (n + 1) / 2
    func lo(_ x: [UInt32]) -> [UInt32] { var l = Array(x[0..<min(h, x.count)]); jsBNTrim(&l); return l }
    func hi(_ x: [UInt32]) -> [UInt32] { x.count > h ? Array(x[h...]) : [] }
    let a0 = lo(a), a1 = hi(a), b0 = lo(b), b1 = hi(b)
    let z0 = jsBNMul(a0, b0)
    let z2 = jsBNMul(a1, b1)
    var z1 = jsBNMul(jsBNAdd(a0, a1), jsBNAdd(b0, b1))
    z1 = jsBNSub(z1, z0)
    z1 = jsBNSub(z1, z2)
    var r = z0
    jsBNAddShifted(&r, z1, h)
    jsBNAddShifted(&r, z2, 2 * h)
    jsBNTrim(&r)
    return r
}

func jsBNDivModSmall(_ a: [UInt32], _ d: UInt32) -> ([UInt32], UInt32) {
    if d == 0 { return ([], 0) }
    var q = [UInt32](repeating: 0, count: a.count)
    var rem: UInt64 = 0
    var i = a.count - 1
    while i >= 0 {
        let cur = (rem << 32) | UInt64(a[i])
        q[i] = UInt32(truncatingIfNeeded: cur / UInt64(d))
        rem = cur % UInt64(d)
        i -= 1
    }
    jsBNTrim(&q)
    return (q, UInt32(truncatingIfNeeded: rem))
}

/// In place divide by a small number; returns the remainder.
func jsBNDivSmallInPlace(_ a: inout [UInt32], _ d: UInt32) -> UInt32 {
    var rem: UInt64 = 0
    var i = a.count - 1
    while i >= 0 {
        let cur = (rem << 32) | UInt64(a[i])
        a[i] = UInt32(truncatingIfNeeded: cur / UInt64(d))
        rem = cur % UInt64(d)
        i -= 1
    }
    jsBNTrim(&a)
    return UInt32(truncatingIfNeeded: rem)
}

func jsBNShl(_ a: [UInt32], _ bits: Int) -> [UInt32] {
    if a.isEmpty || bits <= 0 { return a }
    let ls = bits / 32, bs = bits % 32
    var r = [UInt32](repeating: 0, count: ls)
    r.reserveCapacity(a.count + ls + 1)
    if bs == 0 { r.append(contentsOf: a); return r }
    var carry: UInt32 = 0
    for x in a {
        r.append((x << UInt32(bs)) | carry)
        carry = x >> UInt32(32 - bs)
    }
    if carry != 0 { r.append(carry) }
    return r
}

/// Magnitude shift right (truncating).
func jsBNShr(_ a: [UInt32], _ bits: Int) -> [UInt32] {
    if bits <= 0 { return a }
    let ls = bits / 32, bs = bits % 32
    if ls >= a.count { return [] }
    var r: [UInt32] = []
    r.reserveCapacity(a.count - ls)
    if bs == 0 { r.append(contentsOf: a[ls...]); return r }
    for i in ls..<a.count {
        let hiPart: UInt32 = i + 1 < a.count ? a[i + 1] << UInt32(32 - bs) : 0
        r.append((a[i] >> UInt32(bs)) | hiPart)
    }
    jsBNTrim(&r)
    return r
}

/// Quotient and remainder of magnitudes (Knuth D). b must be non-empty.
func jsBNDivMod(_ a: [UInt32], _ b: [UInt32]) -> ([UInt32], [UInt32]) {
    if b.isEmpty { return ([], []) }
    if jsBNCmp(a, b) < 0 { return ([], a) }
    if b.count == 1 {
        let (q, r) = jsBNDivModSmall(a, b[0])
        return (q, r == 0 ? [] : [r])
    }
    let s = b[b.count - 1].leadingZeroBitCount
    let v = jsBNShl(b, s)
    var u = jsBNShl(a, s)
    while u.count < a.count + 1 { u.append(0) }
    let n = v.count, m = a.count - n
    var q = [UInt32](repeating: 0, count: m + 1)
    let vn1 = UInt64(v[n - 1]), vn2 = UInt64(v[n - 2])
    let base: UInt64 = 1 << 32
    var j = m
    while j >= 0 {
        let num = (UInt64(u[j + n]) << 32) | UInt64(u[j + n - 1])
        var qhat = num / vn1
        var rhat = num % vn1
        while qhat >= base || qhat &* vn2 > ((rhat << 32) | UInt64(u[j + n - 2])) {
            qhat -= 1
            rhat += vn1
            if rhat >= base { break }
        }
        var borrow: Int64 = 0
        var carry: UInt64 = 0
        for i in 0..<n {
            let p = qhat &* UInt64(v[i]) &+ carry
            carry = p >> 32
            let t = Int64(u[i + j]) - borrow - Int64(p & 0xFFFF_FFFF)
            u[i + j] = UInt32(truncatingIfNeeded: t)
            borrow = t < 0 ? 1 : 0
        }
        let t = Int64(u[j + n]) - borrow - Int64(truncatingIfNeeded: carry)
        u[j + n] = UInt32(truncatingIfNeeded: t)
        if t < 0 {
            qhat -= 1
            var c: UInt64 = 0
            for i in 0..<n {
                let s2 = UInt64(u[i + j]) + UInt64(v[i]) + c
                u[i + j] = UInt32(truncatingIfNeeded: s2)
                c = s2 >> 32
            }
            u[j + n] = UInt32(truncatingIfNeeded: UInt64(u[j + n]) + c)
        }
        q[j] = UInt32(truncatingIfNeeded: qhat)
        j -= 1
    }
    jsBNTrim(&q)
    var rem = Array(u[0..<n])
    jsBNTrim(&rem)
    return (q, jsBNShr(rem, s))
}

// MARK: Signed operations

func jsBNAddSigned(_ a: JSBigInt, _ b: JSBigInt) -> JSBigInt {
    if a.negative == b.negative { return JSBigInt(negative: a.negative, mag: jsBNAdd(a.mag, b.mag)) }
    let c = jsBNCmp(a.mag, b.mag)
    if c == 0 { return .zero }
    if c > 0 { return JSBigInt(negative: a.negative, mag: jsBNSub(a.mag, b.mag)) }
    return JSBigInt(negative: b.negative, mag: jsBNSub(b.mag, a.mag))
}

func jsBNNegate(_ a: JSBigInt) -> JSBigInt { JSBigInt(negative: !a.negative, mag: a.mag) }

func jsBNSubSigned(_ a: JSBigInt, _ b: JSBigInt) -> JSBigInt { jsBNAddSigned(a, jsBNNegate(b)) }

func jsBNMulSigned(_ a: JSBigInt, _ b: JSBigInt) -> JSBigInt {
    JSBigInt(negative: a.negative != b.negative, mag: jsBNMul(a.mag, b.mag))
}

/// Truncating division and remainder (the remainder takes the dividend's sign).
func jsBNDivRemSigned(_ a: JSBigInt, _ b: JSBigInt) -> (JSBigInt, JSBigInt) {
    let (q, r) = jsBNDivMod(a.mag, b.mag)
    return (JSBigInt(negative: a.negative != b.negative, mag: q), JSBigInt(negative: a.negative, mag: r))
}

func jsBNCmpSigned(_ a: JSBigInt, _ b: JSBigInt) -> Int {
    if a.negative != b.negative { return a.negative ? -1 : 1 }
    let c = jsBNCmp(a.mag, b.mag)
    return a.negative ? -c : c
}

/// Two's complement of the value in exactly n limbs (n large enough).
func jsBNToTwos(_ a: JSBigInt, _ n: Int) -> [UInt32] {
    var r = a.mag
    while r.count < n { r.append(0) }
    if a.negative {
        var carry: UInt64 = 1
        for i in 0..<r.count {
            let s = UInt64(~r[i]) + carry
            r[i] = UInt32(truncatingIfNeeded: s)
            carry = s >> 32
        }
    }
    return r
}

func jsBNFromTwos(_ t: [UInt32]) -> JSBigInt {
    guard let top = t.last else { return .zero }
    if top & 0x8000_0000 == 0 {
        var m = t
        jsBNTrim(&m)
        return JSBigInt(negative: false, mag: m)
    }
    var m = t
    var carry: UInt64 = 1
    for i in 0..<m.count {
        let s = UInt64(~m[i]) + carry
        m[i] = UInt32(truncatingIfNeeded: s)
        carry = s >> 32
    }
    jsBNTrim(&m)
    return JSBigInt(negative: true, mag: m)
}

/// op: 0 and, 1 or, 2 xor.
func jsBNBitwise(_ op: Int, _ a: JSBigInt, _ b: JSBigInt) -> JSBigInt {
    let n = max(a.mag.count, b.mag.count) + 1
    let x = jsBNToTwos(a, n), y = jsBNToTwos(b, n)
    var r = [UInt32](repeating: 0, count: n)
    for i in 0..<n {
        r[i] = op == 0 ? x[i] & y[i] : op == 1 ? x[i] | y[i] : x[i] ^ y[i]
    }
    return jsBNFromTwos(r)
}

/// ~a = -a - 1.
func jsBNNot(_ a: JSBigInt) -> JSBigInt {
    jsBNSubSigned(jsBNNegate(a), JSBigInt(negative: false, mag: [1]))
}

/// a << k for k >= 0.
func jsBNShiftLeft(_ a: JSBigInt, _ k: Int) -> JSBigInt { JSBigInt(negative: a.negative, mag: jsBNShl(a.mag, k)) }

/// a >> k (floor, arithmetic) for k >= 0.
func jsBNShiftRight(_ a: JSBigInt, _ k: Int) -> JSBigInt {
    if !a.negative { return JSBigInt(negative: false, mag: jsBNShr(a.mag, k)) }
    let m1 = jsBNSub(a.mag, [1])
    return JSBigInt(negative: true, mag: jsBNAdd(jsBNShr(m1, k), [1]))
}

/// The low `bits` bits of the magnitude.
func jsBNTruncateMag(_ m: [UInt32], _ bits: Int) -> [UInt32] {
    if bits <= 0 { return [] }
    if jsBNBitLength(m) <= bits { return m }
    let full = bits / 32, rem = bits % 32
    var r = Array(m[0..<min(full, m.count)])
    if rem > 0 && full < m.count { r.append(m[full] & ((1 << UInt32(rem)) - 1)) }
    jsBNTrim(&r)
    return r
}

/// BigInt.asUintN for bits <= a size the caller has checked.
func jsBNAsUintN(_ bits: Int, _ a: JSBigInt) -> JSBigInt {
    if bits == 0 { return .zero }
    if !a.negative { return JSBigInt(negative: false, mag: jsBNTruncateMag(a.mag, bits)) }
    // -|a| mod 2^bits = 2^bits - (|a| mod 2^bits), or 0.
    let t = jsBNTruncateMag(a.mag, bits)
    if t.isEmpty { return .zero }
    let p = jsBNShl([1], bits)
    return JSBigInt(negative: false, mag: jsBNSub(p, t))
}

func jsBNAsIntN(_ bits: Int, _ a: JSBigInt) -> JSBigInt {
    if bits == 0 { return .zero }
    let u = jsBNAsUintN(bits, a)
    // u >= 2^(bits-1)  ->  u - 2^bits
    if jsBNBitLength(u.mag) == bits {
        return JSBigInt(negative: true, mag: jsBNSub(jsBNShl([1], bits), u.mag))
    }
    return u
}

// MARK: Double conversion

func jsBNToDouble(_ a: JSBigInt) -> Double {
    let bl = jsBNBitLength(a.mag)
    if bl == 0 { return 0 }
    if bl > 1024 { return a.negative ? -Double.infinity : Double.infinity }
    var r: Double
    if bl <= 64 {
        var v: UInt64 = UInt64(a.mag[0])
        if a.mag.count > 1 { v |= UInt64(a.mag[1]) << 32 }
        r = Double(v)
    } else {
        let shift = bl - 64
        let top = jsBNShr(a.mag, shift)
        var v: UInt64 = UInt64(top[0]) | (top.count > 1 ? UInt64(top[1]) << 32 : 0)
        // Sticky bit: anything below the top 64 bits.
        var sticky = false
        let fullLimbs = shift / 32
        for i in 0..<min(fullLimbs, a.mag.count) where a.mag[i] != 0 { sticky = true; break }
        if !sticky && shift % 32 != 0 && fullLimbs < a.mag.count {
            if a.mag[fullLimbs] & ((1 << UInt32(shift % 32)) - 1) != 0 { sticky = true }
        }
        if sticky { v |= 1 }
        r = Double(v)
        // 2^shift (shift <= 960).
        let scale = Double(bitPattern: UInt64(1023 + shift) << 52)
        r *= scale
    }
    return a.negative ? -r : r
}

/// An integral, finite double as a BigInt.
func jsBNFromDouble(_ d: Double) -> JSBigInt {
    if d == 0 || !d.isFinite { return .zero }
    let neg = d < 0
    let bits = d.magnitude.bitPattern
    let expBits = Int((bits >> 52) & 0x7FF)
    var m = bits & 0xF_FFFF_FFFF_FFFF
    var e: Int
    if expBits == 0 { e = -1074 } else { m |= 1 << 52; e = expBits - 1075 }
    var mag = jsBNFromUInt64(m)
    if e > 0 { mag = jsBNShl(mag, e) } else if e < 0 { mag = jsBNShr(mag, -e) }
    return JSBigInt(negative: neg, mag: mag)
}

/// Compare a BigInt with a Number: -1, 0, 1, or 2 when unordered (NaN).
func jsBNCompareDouble(_ a: JSBigInt, _ d: Double) -> Int {
    if d.isNaN { return 2 }
    if d == Double.infinity { return -1 }
    if d == -Double.infinity { return 1 }
    let t = d.rounded(.towardZero)
    let c = jsBNCmpSigned(a, jsBNFromDouble(t))
    if c != 0 { return c }
    if d > t { return -1 }
    if d < t { return 1 }
    return 0
}

// MARK: Text

let jsBNDigitChars: [UInt8] = Array("0123456789abcdefghijklmnopqrstuvwxyz".utf8)

/// Digits of the magnitude in the radix (2...36), most significant first
/// (no sign; "0" for zero).
func jsBNMagToDigits(_ m: [UInt32], radix: Int) -> [UInt8] {
    if m.isEmpty { return [0x30] }
    if m.count == 1 && Int(m[0]) < radix { return [jsBNDigitChars[Int(m[0])]] }
    // Largest power of the radix below 2^32.
    var chunk: UInt32 = UInt32(radix)
    var k = 1
    while UInt64(chunk) * UInt64(radix) <= 0xFFFF_FFFF { chunk *= UInt32(radix); k += 1 }
    var cur = m
    var out: [UInt8] = []
    out.reserveCapacity(jsBNBitLength(m) / 3 + 2)
    while !cur.isEmpty {
        var rem = jsBNDivSmallInPlace(&cur, chunk)
        if cur.isEmpty {
            while rem != 0 { out.append(jsBNDigitChars[Int(rem % UInt32(radix))]); rem /= UInt32(radix) }
        } else {
            for _ in 0..<k { out.append(jsBNDigitChars[Int(rem % UInt32(radix))]); rem /= UInt32(radix) }
        }
    }
    out.reverse()
    return out
}

@inline(__always) func jsBNDigitValue(_ c: UInt16) -> Int {
    if c >= 0x30 && c <= 0x39 { return Int(c) - 0x30 }
    if c >= 0x61 && c <= 0x7A { return Int(c) - 0x61 + 10 }
    if c >= 0x41 && c <= 0x5A { return Int(c) - 0x41 + 10 }
    return 99
}

/// Magnitude from digit code units in the radix; nil when a digit is invalid
/// or there are none. maxBits caps the result (nil past it, tooBig set).
func jsBNParseDigits(_ s: ArraySlice<UInt16>, radix: Int, maxBits: Int, tooBig: inout Bool) -> [UInt32]? {
    if s.isEmpty { return nil }
    var chunk: UInt32 = UInt32(radix)
    var k = 1
    while UInt64(chunk) * UInt64(radix) <= 0xFFFF_FFFF { chunk *= UInt32(radix); k += 1 }
    var mag: [UInt32] = []
    var acc: UInt32 = 0, mult: UInt32 = 1, n = 0
    for c in s {
        let d = jsBNDigitValue(c)
        if d >= radix { return nil }
        acc = acc * UInt32(radix) + UInt32(d)
        mult = n == 0 ? UInt32(radix) : mult * UInt32(radix)
        n += 1
        if n == k {
            jsBNMulAddInPlace(&mag, chunk, acc)
            jsBNTrim(&mag)
            acc = 0; n = 0
            if mag.count * 32 > maxBits + 64 { tooBig = true; return nil }
        }
    }
    if n > 0 { jsBNMulAddInPlace(&mag, mult, acc); jsBNTrim(&mag) }
    if jsBNBitLength(mag) > maxBits { tooBig = true; return nil }
    return mag
}

/// StringToBigInt over UTF-16 code units: trimmed, optional 0x/0o/0b prefix
/// (unsigned), or an optionally signed decimal. nil for a syntax error.
func jsBNParseString(_ units: [UInt16], maxBits: Int, tooBig: inout Bool) -> JSBigInt? {
    var lo = 0, hi = units.count
    while lo < hi && jsIsStrWhiteSpace(UInt32(units[lo])) { lo += 1 }
    while hi > lo && jsIsStrWhiteSpace(UInt32(units[hi - 1])) { hi -= 1 }
    if lo == hi { return .zero }
    var radix = 10
    var neg = false
    var p = lo
    if hi - lo >= 2 && units[lo] == 0x30 {
        let c = units[lo + 1] | 0x20
        if c == 0x78 { radix = 16; p = lo + 2 } else if c == 0x6F { radix = 8; p = lo + 2 } else if c == 0x62 { radix = 2; p = lo + 2 }
    }
    if radix == 10 && (units[p] == 0x2B || units[p] == 0x2D) {
        neg = units[p] == 0x2D
        p += 1
    }
    guard let m = jsBNParseDigits(units[p..<hi], radix: radix, maxBits: maxBits, tooBig: &tooBig) else { return nil }
    return JSBigInt(negative: neg, mag: m)
}

/// Int value when |a| < 2^62, else nil.
func jsBNToInt(_ a: JSBigInt) -> Int? {
    if a.mag.count > 2 { return nil }
    var v: UInt64 = 0
    if a.mag.count > 0 { v = UInt64(a.mag[0]) }
    if a.mag.count > 1 { v |= UInt64(a.mag[1]) << 32 }
    if v >= (1 << 62) { return nil }
    return a.negative ? -Int(v) : Int(v)
}

func jsBNFromInt(_ i: Int) -> JSBigInt {
    JSBigInt(negative: i < 0, mag: jsBNFromUInt64(i < 0 ? UInt64(bitPattern: Int64(-(i + 1))) + 1 : UInt64(i)))
}

/// Low 64 bits of the two's complement value (BigInt.asUintN(64, a)).
func jsBNLow64(_ a: JSBigInt) -> UInt64 {
    var v: UInt64 = 0
    if a.mag.count > 0 { v = UInt64(a.mag[0]) }
    if a.mag.count > 1 { v |= UInt64(a.mag[1]) << 32 }
    return a.negative ? (0 &- v) : v
}

/// A 64-bit element as a BigInt (typed arrays, DataView).
func jsBNFromBits64(_ bits: UInt64, signed: Bool) -> JSBigInt {
    if signed && bits >> 63 == 1 {
        return JSBigInt(negative: true, mag: jsBNFromUInt64(0 &- bits))
    }
    return JSBigInt(negative: false, mag: jsBNFromUInt64(bits))
}
