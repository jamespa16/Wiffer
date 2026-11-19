// Number <-> string conversions for lib/js (ROADMAP Part 9, "Numbers"),
// written here because Embedded Swift's description can't be relied on and
// no C library may be used. No libm calls either (trunc/floor/fmod are
// done on bits or through Int64).
//
// API (the VM / built-ins contract). Strings in and out are ASCII byte
// arrays or JS code units; JSHeap wraps them into string cells.
//
//   Number -> string
//     jsNumberToString(d) -> [UInt8]       ECMAScript Number::toString(x)
//                                            (shortest round trip, Ryu)
//     jsNumberToRadixString(d, radix)      Number.prototype.toString(r),
//                                            radix 2...36 (V8's algorithm)
//     jsNumberToFixed(d, f)                toFixed, f in 0...100
//     jsNumberToExponential(d, f?)         toExponential, f in 0...100 or
//                                            nil (as many digits as needed)
//     jsNumberToPrecision(d, p)            toPrecision, p in 1...100
//       (range checks and the RangeError are the caller's; out-of-range
//        arguments are clamped, never trap)
//     jsShortestDigits(d) -> (digits, exponent)   Ryu: d = digits * 10^exponent
//
//   String -> number
//     jsStringToNumber(units) -> Double    ECMAScript StringToNumber: white
//                                            space, sign, Infinity, decimal,
//                                            0x/0o/0b; NaN when not numeric
//     jsParseDecimalPrefix(units, from) -> (value, end)?   longest
//                                            StrDecimalLiteral prefix (for
//                                            parseFloat); nil if none
//     jsDigitsToDouble(digits, radix)      digit values (0..<radix) of an
//                                            integer to a Double (parseInt;
//                                            correctly rounded for radix 10
//                                            and powers of two)
//     jsDecimalToDouble(digits, exp10)     significant decimal digits (values
//                                            0...9) * 10^exp10, correctly
//                                            rounded (Clinger fast path,
//                                            Eisel-Lemire, big-integer
//                                            fallback)
//     jsIsStrWhiteSpace(unit)              StrWhiteSpaceChar
//
//   Integer conversions
//     jsToInt32 / jsToUint32 / jsToUint16 / jsToIntegerOrInfinity / jsFmod
//     (exact IEEE fmod, the JS `%` on doubles) / jsTrunc / jsFloor
//     jsArrayIndex(units) -> UInt32?       canonical array index string
//                                            ("0".."4294967294") to its value

// MARK: Small helpers

let jsPow10Exact: [Double] = [1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11,
                              1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22]

/// Truncation toward zero without libm.
public func jsTrunc(_ x: Double) -> Double {
    guard x.magnitude < 4_503_599_627_370_496.0 else { return x }  // also NaN, inf
    let t = Double(Int64(x))
    return t == 0 && x.sign == .minus ? -0.0 : t
}

public func jsFloor(_ x: Double) -> Double {
    guard x.magnitude < 4_503_599_627_370_496.0 else { return x }
    let t = Double(Int64(x))
    return t > x ? t - 1 : (t == 0 && x.sign == .minus ? -0.0 : t)
}

/// ToUint32 (modulo 2^32 of the truncated value; NaN and infinities give 0).
public func jsToUint32(_ d: Double) -> UInt32 {
    if !d.isFinite { return 0 }
    if d.magnitude < 9.2e18 { return UInt32(truncatingIfNeeded: Int64(d)) }
    let bits = d.bitPattern
    let e = Int((bits >> 52) & 0x7FF) - 1075          // >= 10 here
    let m = (bits & ((1 << 52) - 1)) | (1 << 52)
    let low: UInt32 = e >= 32 ? 0 : UInt32(truncatingIfNeeded: m << UInt64(e))
    return d < 0 ? 0 &- low : low
}

@inline(__always) public func jsToInt32(_ d: Double) -> Int32 { Int32(bitPattern: jsToUint32(d)) }
@inline(__always) public func jsToUint16(_ d: Double) -> UInt16 { UInt16(truncatingIfNeeded: jsToUint32(d)) }

/// ToIntegerOrInfinity: NaN -> 0, -0 -> 0, infinities kept, else truncated.
public func jsToIntegerOrInfinity(_ d: Double) -> Double {
    if d.isNaN { return 0 }
    let t = jsTrunc(d)
    return t == 0 ? 0 : t
}

/// Exact floating-point remainder (sign of x), as JS `%` needs (musl's fmod).
public func jsFmod(_ x: Double, _ y: Double) -> Double {
    if y == 0 || x.isNaN || y.isNaN || x.isInfinite { return .nan }
    if y.isInfinite || x == 0 { return x }
    var ux = x.bitPattern, uy = y.bitPattern
    var ex = Int((ux >> 52) & 0x7FF), ey = Int((uy >> 52) & 0x7FF)
    let sx = ux >> 63
    let ax = ux << 1, ay = uy << 1
    if ax <= ay { return ax == ay ? 0 * x : x }
    if ex == 0 {
        var i = ux << 12
        while i >> 63 == 0 { ex -= 1; i <<= 1 }
        ux <<= UInt64(1 - ex)
    } else { ux = (ux & (UInt64.max >> 12)) | (1 << 52) }
    if ey == 0 {
        var i = uy << 12
        while i >> 63 == 0 { ey -= 1; i <<= 1 }
        uy <<= UInt64(1 - ey)
    } else { uy = (uy & (UInt64.max >> 12)) | (1 << 52) }
    while ex > ey {
        let i = ux &- uy
        if i >> 63 == 0 {
            if i == 0 { return 0 * x }
            ux = i
        }
        ux <<= 1
        ex -= 1
    }
    let i = ux &- uy
    if i >> 63 == 0 {
        if i == 0 { return 0 * x }
        ux = i
    }
    while ux >> 52 == 0 { ux <<= 1; ex -= 1 }
    if ex > 0 { ux = (ux &- (1 << 52)) | (UInt64(ex) << 52) } else { ux >>= UInt64(1 - ex) }
    return Double(bitPattern: ux | (sx << 63))
}

/// StrWhiteSpaceChar: WhiteSpace or LineTerminator.
public func jsIsStrWhiteSpace(_ c: UInt32) -> Bool {
    switch c {
    case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F,
         0x3000, 0xFEFF:
        return true
    case 0x2000...0x200A: return true
    default: return false
    }
}

/// The value of a canonical array index string (no sign, no leading zero
/// except "0", at most 4294967294), or nil.
public func jsArrayIndex<C: RandomAccessCollection>(_ s: C) -> UInt32?
where C.Element: FixedWidthInteger, C.Index == Int {
    let n = s.count
    if n == 0 || n > 10 { return nil }
    var v: UInt64 = 0
    for i in s.startIndex..<s.endIndex {
        let c = UInt32(truncatingIfNeeded: s[i])
        guard c >= 0x30 && c <= 0x39 else { return nil }
        if c == 0x30 && i == s.startIndex && n > 1 { return nil }
        v = v * 10 + UInt64(c - 0x30)
    }
    return v <= 4_294_967_294 ? UInt32(v) : nil
}

// MARK: Big integers (exact decimal digits and the strtod fallback)

/// Unsigned arbitrary-precision integer, little-endian 32-bit limbs.
struct JSBigNum {
    var limbs: [UInt32] = []

    init() {}
    init(_ v: UInt64) {
        if v != 0 { limbs.append(UInt32(truncatingIfNeeded: v)) }
        if v >> 32 != 0 { limbs.append(UInt32(truncatingIfNeeded: v >> 32)) }
    }

    var isZero: Bool { limbs.isEmpty }

    mutating func trim() { while let l = limbs.last, l == 0 { limbs.removeLast() } }

    mutating func mulAdd(_ m: UInt32, _ a: UInt32 = 0) {
        var carry = UInt64(a)
        for i in 0..<limbs.count {
            let p = UInt64(limbs[i]) * UInt64(m) + carry
            limbs[i] = UInt32(truncatingIfNeeded: p)
            carry = p >> 32
        }
        if carry != 0 { limbs.append(UInt32(carry)) }
        trim()
    }

    mutating func mulPow5(_ n: Int) {
        var k = n
        while k >= 13 { mulAdd(1_220_703_125); k -= 13 }   // 5^13
        if k > 0 {
            var p: UInt32 = 1
            for _ in 0..<k { p *= 5 }
            mulAdd(p)
        }
    }

    mutating func shiftLeft(_ n: Int) {
        if isZero || n <= 0 { return }
        let words = n / 32, bits = n % 32
        if bits != 0 {
            var carry: UInt32 = 0
            for i in 0..<limbs.count {
                let l = limbs[i]
                limbs[i] = (l << UInt32(bits)) | carry
                carry = l >> UInt32(32 - bits)
            }
            if carry != 0 { limbs.append(carry) }
        }
        if words > 0 { limbs.insert(contentsOf: [UInt32](repeating: 0, count: words), at: 0) }
    }

    /// Divides in place, returning the remainder.
    mutating func divSmall(_ d: UInt32) -> UInt32 {
        var rem: UInt64 = 0
        var i = limbs.count - 1
        while i >= 0 {
            let cur = (rem << 32) | UInt64(limbs[i])
            limbs[i] = UInt32(truncatingIfNeeded: cur / UInt64(d))
            rem = cur % UInt64(d)
            i -= 1
        }
        trim()
        return UInt32(truncatingIfNeeded: rem)
    }

    static func compare(_ a: JSBigNum, _ b: JSBigNum) -> Int {
        if a.limbs.count != b.limbs.count { return a.limbs.count < b.limbs.count ? -1 : 1 }
        var i = a.limbs.count - 1
        while i >= 0 {
            if a.limbs[i] != b.limbs[i] { return a.limbs[i] < b.limbs[i] ? -1 : 1 }
            i -= 1
        }
        return 0
    }

    /// Decimal digit values (most significant first); [0] for zero.
    func decimalDigits() -> [UInt8] {
        if isZero { return [0] }
        var n = self
        var chunks: [UInt32] = []
        while !n.isZero { chunks.append(n.divSmall(1_000_000_000)) }
        var out: [UInt8] = []
        var i = chunks.count - 1
        var first = true
        while i >= 0 {
            var c = chunks[i]
            var d = [UInt8](repeating: 0, count: 9)
            var j = 8
            while j >= 0 { d[j] = UInt8(c % 10); c /= 10; j -= 1 }
            if first {
                var k = 0
                while k < 8 && d[k] == 0 { k += 1 }
                out.append(contentsOf: d[k...])
                first = false
            } else { out.append(contentsOf: d) }
            i -= 1
        }
        return out
    }

    /// From decimal digit values.
    init(digits: [UInt8]) {
        var i = 0
        while i < digits.count {
            var chunk: UInt32 = 0, mul: UInt32 = 1
            var j = 0
            while j < 9 && i < digits.count {
                chunk = chunk * 10 + UInt32(digits[i]); mul *= 10; i += 1; j += 1
            }
            mulAdd(mul, chunk)
        }
    }
}

// MARK: Ryu (shortest round-trip digits)

@inline(__always) private func ryuPow5Bits(_ e: Int) -> Int { ((e &* 1_217_359) >> 19) + 1 }
@inline(__always) private func ryuLog10Pow2(_ e: Int) -> Int { (e &* 78_913) >> 18 }
@inline(__always) private func ryuLog10Pow5(_ e: Int) -> Int { (e &* 732_923) >> 20 }

private func ryuPow5Factor(_ v: UInt64) -> Int {
    var value = v, count = 0
    while value != 0 && value % 5 == 0 { value /= 5; count += 1 }
    return count
}

@inline(__always) private func ryuMulShift(_ m: UInt64, _ table: [UInt64], _ idx: Int, _ j: Int) -> UInt64 {
    let lo = table[2 * idx], hi = table[2 * idx + 1]
    let b0 = m.multipliedFullWidth(by: lo)
    let b2 = m.multipliedFullWidth(by: hi)
    let (sLo, c) = b2.low.addingReportingOverflow(b0.high)
    let sHi = b2.high &+ (c ? 1 : 0)
    let dist = j - 64
    // Smart shifts: correct for any 0 <= dist < 128.
    return (sHi << (64 - dist)) | (sLo >> dist)
}

/// Shortest decimal digits that round-trip: d (finite, > 0) is the double
/// nearest digits * 10^exponent. Trailing zeros are stripped.
public func jsShortestDigits(_ d: Double) -> (digits: UInt64, exponent: Int) {
    let bits = d.bitPattern
    let ieeeMantissa = bits & ((1 << 52) - 1)
    let ieeeExponent = Int((bits >> 52) & 0x7FF)
    if ieeeExponent == 0 && ieeeMantissa == 0 { return (0, 0) }
    let e2: Int
    let m2: UInt64
    if ieeeExponent == 0 { e2 = 1 - 1023 - 52 - 2; m2 = ieeeMantissa }
    else { e2 = ieeeExponent - 1023 - 52 - 2; m2 = (1 << 52) | ieeeMantissa }
    let acceptBounds = m2 & 1 == 0
    let mv = 4 * m2
    let mmShift: UInt64 = (ieeeMantissa != 0 || ieeeExponent <= 1) ? 1 : 0
    var vr: UInt64, vp: UInt64, vm: UInt64
    let e10: Int
    var vmIsTrailingZeros = false, vrIsTrailingZeros = false
    if e2 >= 0 {
        let q = ryuLog10Pow2(e2) - (e2 > 3 ? 1 : 0)
        e10 = q
        let k = 125 + ryuPow5Bits(q) - 1
        let i = -e2 + q + k
        vr = ryuMulShift(mv, jsRyuPow5InvSplit, q, i)
        vp = ryuMulShift(mv + 2, jsRyuPow5InvSplit, q, i)
        vm = ryuMulShift(mv - 1 - mmShift, jsRyuPow5InvSplit, q, i)
        if q <= 21 {
            if mv % 5 == 0 { vrIsTrailingZeros = ryuPow5Factor(mv) >= q }
            else if acceptBounds { vmIsTrailingZeros = ryuPow5Factor(mv - 1 - mmShift) >= q }
            else if ryuPow5Factor(mv + 2) >= q { vp -= 1 }
        }
    } else {
        let q = ryuLog10Pow5(-e2) - (-e2 > 1 ? 1 : 0)
        e10 = q + e2
        let i = -e2 - q
        let k = ryuPow5Bits(i) - 125
        let j = q - k
        vr = ryuMulShift(mv, jsRyuPow5Split, i, j)
        vp = ryuMulShift(mv + 2, jsRyuPow5Split, i, j)
        vm = ryuMulShift(mv - 1 - mmShift, jsRyuPow5Split, i, j)
        if q <= 1 {
            vrIsTrailingZeros = true
            if acceptBounds { vmIsTrailingZeros = mmShift == 1 } else { vp -= 1 }
        } else if q < 63 {
            vrIsTrailingZeros = mv & ((1 << UInt64(q)) - 1) == 0
        }
    }
    var removed = 0
    var lastRemovedDigit: UInt64 = 0
    var output: UInt64
    if vmIsTrailingZeros || vrIsTrailingZeros {
        while vp / 10 > vm / 10 {
            vmIsTrailingZeros = vmIsTrailingZeros && vm % 10 == 0
            vrIsTrailingZeros = vrIsTrailingZeros && lastRemovedDigit == 0
            lastRemovedDigit = vr % 10
            vr /= 10; vp /= 10; vm /= 10
            removed += 1
        }
        if vmIsTrailingZeros {
            while vm != 0 && vm % 10 == 0 {
                vrIsTrailingZeros = vrIsTrailingZeros && lastRemovedDigit == 0
                lastRemovedDigit = vr % 10
                vr /= 10; vp /= 10; vm /= 10
                removed += 1
            }
        }
        if vrIsTrailingZeros && lastRemovedDigit == 5 && vr % 2 == 0 { lastRemovedDigit = 4 }
        let up = (vr == vm && (!acceptBounds || !vmIsTrailingZeros)) || lastRemovedDigit >= 5
        output = vr + (up ? 1 : 0)
    } else {
        var roundUp = false
        if vp / 100 > vm / 100 {
            roundUp = vr % 100 >= 50
            vr /= 100; vp /= 100; vm /= 100
            removed += 2
        }
        while vp / 10 > vm / 10 {
            roundUp = vr % 10 >= 5
            vr /= 10; vp /= 10; vm /= 10
            removed += 1
        }
        output = vr + ((vr == vm || roundUp) ? 1 : 0)
    }
    var exp = e10 + removed
    while output != 0 && output % 10 == 0 { output /= 10; exp += 1 }
    return (output, exp)
}

private func jsDigitsOf(_ v: UInt64) -> [UInt8] {
    if v == 0 { return [0x30] }
    var tmp: [UInt8] = []
    var x = v
    while x != 0 { tmp.append(UInt8(0x30 + x % 10)); x /= 10 }
    return tmp.reversed()
}

private func jsAppendInt(_ out: inout [UInt8], _ v: Int) {
    if v < 0 { out.append(0x2D); out.append(contentsOf: jsDigitsOf(UInt64(-v))) }
    else { out.append(contentsOf: jsDigitsOf(UInt64(v))) }
}

private let jsNaNBytes: [UInt8] = Array("NaN".utf8)
private let jsInfinityBytes: [UInt8] = Array("Infinity".utf8)

/// ECMAScript Number::toString(x) (radix 10), as ASCII bytes.
public func jsNumberToString(_ d: Double) -> [UInt8] {
    if d.isNaN { return jsNaNBytes }
    if d == 0 { return [0x30] }
    if d.isInfinite { return d < 0 ? [0x2D] + jsInfinityBytes : jsInfinityBytes }
    var out: [UInt8] = []
    if d < 0 { out.append(0x2D) }
    let a = d.magnitude
    if a < 9_007_199_254_740_992.0 && Double(Int64(a)) == a {
        out.append(contentsOf: jsDigitsOf(UInt64(a)))
        return out
    }
    let (digits, exponent) = jsShortestDigits(a)
    let s = jsDigitsOf(digits)
    let k = s.count
    let n = exponent + k
    if k <= n && n <= 21 {
        out.append(contentsOf: s)
        for _ in 0..<(n - k) { out.append(0x30) }
    } else if 0 < n && n <= 21 {
        out.append(contentsOf: s[0..<n]); out.append(0x2E); out.append(contentsOf: s[n...])
    } else if -6 < n && n <= 0 {
        out.append(0x30); out.append(0x2E)
        for _ in 0..<(-n) { out.append(0x30) }
        out.append(contentsOf: s)
    } else {
        out.append(s[0])
        if k > 1 { out.append(0x2E); out.append(contentsOf: s[1...]) }
        out.append(0x65)
        out.append(n - 1 >= 0 ? 0x2B : 0x2D)
        jsAppendInt(&out, abs(n - 1))
    }
    return out
}

// MARK: Radix toString (V8's DoubleToRadixCString)

private let jsRadixChars: [UInt8] = Array("0123456789abcdefghijklmnopqrstuvwxyz".utf8)

@inline(__always) private func jsNextUp(_ d: Double) -> Double {
    // d is finite and >= 0 here.
    Double(bitPattern: d.bitPattern + 1)
}

@inline(__always) private func jsBinaryExponent(_ d: Double) -> Int {
    let e = Int((d.bitPattern >> 52) & 0x7FF)
    return e == 0 ? -1074 : e - 1075
}

/// Number.prototype.toString(radix) for radix 2...36 (10 uses
/// jsNumberToString). Radix is clamped into range.
public func jsNumberToRadixString(_ value: Double, _ radixIn: Int) -> [UInt8] {
    let radix = radixIn < 2 ? 2 : (radixIn > 36 ? 36 : radixIn)
    if radix == 10 || value.isNaN || value.isInfinite || value == 0 { return jsNumberToString(value) }
    let negative = value < 0
    let v = value.magnitude
    let r = Double(radix)
    var integer = jsFloor(v)
    var fraction = v - integer
    var delta = 0.5 * (jsNextUp(v) - v)
    let minDelta = Double(bitPattern: 1)
    if delta < minDelta { delta = minDelta }
    var frac: [UInt8] = []
    if fraction >= delta {
        frac.append(0x2E)
        repeat {
            fraction *= r
            delta *= r
            let digit = Int(fraction)
            frac.append(jsRadixChars[digit])
            fraction -= Double(digit)
            if fraction > 0.5 || (fraction == 0.5 && digit & 1 == 1) {
                if fraction + delta > 1 {
                    // Round up, carrying back through the digits written.
                    var cur = frac.count
                    while true {
                        cur -= 1
                        if cur == 0 { integer += 1; frac.removeAll(); break }   // reached the '.'
                        let c = frac[cur]
                        let dv = c > 0x39 ? Int(c) - 0x61 + 10 : Int(c) - 0x30
                        if dv + 1 < radix {
                            frac[cur] = jsRadixChars[dv + 1]
                            frac.removeSubrange((cur + 1)...)
                            break
                        }
                    }
                    break
                }
            }
        } while fraction >= delta && frac.count < 1200
    }
    var intRev: [UInt8] = []
    while jsBinaryExponent(integer / r) > 0 {
        integer /= r
        intRev.append(0x30)
    }
    repeat {
        // integer < 2^53 * radix here, so it converts to UInt64 exactly.
        let iv = UInt64(integer)
        let rem = iv % UInt64(radix)
        intRev.append(jsRadixChars[Int(rem)])
        integer = Double(iv / UInt64(radix))
    } while integer > 0
    var out: [UInt8] = negative ? [0x2D] : []
    out.append(contentsOf: intRev.reversed())
    out.append(contentsOf: frac)
    return out
}

// MARK: Exact decimal expansion: toFixed, toExponential, toPrecision

/// The exact decimal value of a finite x > 0: digit values (no leading or
/// trailing zeros) and point, so x = 0.d1d2d3... * 10^point.
func jsExactDecimal(_ x: Double) -> (digits: [UInt8], point: Int) {
    let bits = x.bitPattern
    let be = Int((bits >> 52) & 0x7FF)
    var m = bits & ((1 << 52) - 1)
    var e2: Int
    if be == 0 { e2 = -1074 } else { m |= 1 << 52; e2 = be - 1075 }
    while m & 1 == 0 && m != 0 { m >>= 1; e2 += 1 }
    var big = JSBigNum(m)
    var digits: [UInt8]
    var point: Int
    if e2 >= 0 {
        big.shiftLeft(e2)
        digits = big.decimalDigits()
        point = digits.count
    } else {
        big.mulPow5(-e2)
        digits = big.decimalDigits()
        point = digits.count + e2
    }
    while let l = digits.last, l == 0, digits.count > 1 { digits.removeLast() }
    return (digits, point)
}

/// Round 0.d1d2... * 10^point to `keep` significant digits, half up (the
/// spec's "if there are two such n, pick the larger n"). Returns `keep`
/// digits (padded with zeros), or [1, 0...] with point + 1 after a carry
/// out of the top digit, or [] if keep <= 0 and the value rounds to zero.
private func jsRoundHalfUp(_ digits: [UInt8], _ point: Int, _ keep: Int) -> (digits: [UInt8], point: Int) {
    if keep < 0 { return ([], point) }
    if keep >= digits.count {
        return (digits + [UInt8](repeating: 0, count: keep - digits.count), point)
    }
    var d = Array(digits[0..<keep])
    if digits[keep] >= 5 {
        var i = keep - 1
        while i >= 0 && d[i] == 9 { d[i] = 0; i -= 1 }
        if i >= 0 { d[i] += 1 } else {
            return ([1] + [UInt8](repeating: 0, count: keep > 1 ? keep - 1 : 0), point + 1)
        }
    }
    return (d, point)
}

/// Number.prototype.toFixed(f), f clamped to 0...100. Values >= 1e21 use
/// Number::toString, as the spec says.
public func jsNumberToFixed(_ x: Double, _ fIn: Int) -> [UInt8] {
    let f = fIn < 0 ? 0 : (fIn > 100 ? 100 : fIn)
    if x.isNaN { return jsNaNBytes }
    if x.magnitude >= 1e21 || x.isInfinite { return jsNumberToString(x) }
    var out: [UInt8] = x < 0 ? [0x2D] : []
    var n: [UInt8] = []                 // digits of the integer n = round(x * 10^f)
    if x != 0 {
        let (digits, point) = jsExactDecimal(x.magnitude)
        let r = jsRoundHalfUp(digits, point + f, point + f)
        n = r.digits
        if !n.isEmpty && r.point > n.count { n += [UInt8](repeating: 0, count: r.point - n.count) }
    }
    while n.count > 1 && n[0] == 0 { n.removeFirst() }
    if n.isEmpty { n = [0] }
    if f > 0 && n.count <= f { n = [UInt8](repeating: 0, count: f + 1 - n.count) + n }
    let intCount = n.count - f
    for i in 0..<intCount { out.append(0x30 + n[i]) }
    if f > 0 {
        out.append(0x2E)
        for i in intCount..<n.count { out.append(0x30 + n[i]) }
    }
    return out
}

private func jsAppendExponent(_ out: inout [UInt8], _ e: Int) {
    out.append(0x65)
    out.append(e >= 0 ? 0x2B : 0x2D)
    jsAppendInt(&out, e >= 0 ? e : -e)
}

/// Number.prototype.toExponential(f): f in 0...100 (clamped), or nil for
/// "as many digits as necessary" (the shortest round-trip digits).
public func jsNumberToExponential(_ x: Double, _ fIn: Int?) -> [UInt8] {
    if x.isNaN { return jsNaNBytes }
    if x.isInfinite { return jsNumberToString(x) }
    var out: [UInt8] = x < 0 ? [0x2D] : []
    var digits: [UInt8]
    var e: Int
    if x == 0 {
        digits = [UInt8](repeating: 0, count: (fIn ?? 0) < 0 ? 1 : min(fIn ?? 0, 100) + 1)
        e = 0
    } else if let fi = fIn {
        let f = fi < 0 ? 0 : (fi > 100 ? 100 : fi)
        let (dg, point) = jsExactDecimal(x.magnitude)
        let r = jsRoundHalfUp(dg, point, f + 1)
        digits = Array(r.digits.prefix(f + 1))
        e = r.point - 1
    } else {
        let (v, ex) = jsShortestDigits(x.magnitude)
        digits = jsDigitsOf(v).map { $0 - 0x30 }
        e = ex + digits.count - 1
    }
    out.append(0x30 + digits[0])
    if digits.count > 1 {
        out.append(0x2E)
        for d in digits[1...] { out.append(0x30 + d) }
    }
    jsAppendExponent(&out, e)
    return out
}

/// Number.prototype.toPrecision(p), p clamped to 1...100.
public func jsNumberToPrecision(_ x: Double, _ pIn: Int) -> [UInt8] {
    let p = pIn < 1 ? 1 : (pIn > 100 ? 100 : pIn)
    if x.isNaN { return jsNaNBytes }
    if x.isInfinite { return jsNumberToString(x) }
    var out: [UInt8] = x < 0 ? [0x2D] : []
    var digits: [UInt8]
    var e: Int
    if x == 0 {
        digits = [UInt8](repeating: 0, count: p)
        e = 0
    } else {
        let (dg, point) = jsExactDecimal(x.magnitude)
        let r = jsRoundHalfUp(dg, point, p)
        digits = Array(r.digits.prefix(p))
        e = r.point - 1
    }
    if e < -6 || e >= p {
        out.append(0x30 + digits[0])
        if p > 1 {
            out.append(0x2E)
            for d in digits[1...] { out.append(0x30 + d) }
        }
        jsAppendExponent(&out, e)
        return out
    }
    if e == p - 1 {
        for d in digits { out.append(0x30 + d) }
    } else if e >= 0 {
        for d in digits[0...e] { out.append(0x30 + d) }
        out.append(0x2E)
        for d in digits[(e + 1)...] { out.append(0x30 + d) }
    } else {
        out.append(0x30); out.append(0x2E)
        for _ in 0..<(-(e + 1)) { out.append(0x30) }
        for d in digits { out.append(0x30 + d) }
    }
    return out
}

// MARK: Decimal -> double (Clinger, Eisel-Lemire, big-integer fallback)

private let jsMaxKeptDigits = 800

@inline(__always) private func jsLemirePower(_ q: Int) -> Int { (((152_170 + 65_536) &* q) >> 16) + 63 }

/// Eisel-Lemire for w * 10^q: the double's bits, and whether the result is
/// known correct (false: within one ulp, needs the exact check).
func jsEiselLemire(_ w0: UInt64, _ q: Int) -> (bits: UInt64, ok: Bool) {
    let infBits: UInt64 = 0x7FF0_0000_0000_0000
    if w0 == 0 || q < -342 { return (0, true) }
    if q > 308 { return (infBits, true) }
    let lz = w0.leadingZeroBitCount
    let w = w0 << UInt64(lz)
    let idx = 2 * (q + 342)
    let tLo = jsLemirePow5[idx], tHi = jsLemirePow5[idx + 1]
    var (fpHi, fpLo) = w.multipliedFullWidth(by: tHi)
    let precisionMask: UInt64 = UInt64.max >> 55
    if fpHi & precisionMask == precisionMask {
        let sp = w.multipliedFullWidth(by: tLo)
        let (s, c) = fpLo.addingReportingOverflow(sp.high)
        fpLo = s
        if c { fpHi &+= 1 }
    }
    var ok = true
    if fpLo == UInt64.max && (q < -27 || q > 55) { ok = false }
    let upperbit = Int(fpHi >> 63)
    let shift = upperbit + 64 - 52 - 3
    var mantissa = fpHi >> UInt64(shift)
    var power2 = jsLemirePower(q) + upperbit - lz + 1023
    if power2 <= 0 {
        if -power2 + 1 >= 64 { return (0, ok) }
        mantissa >>= UInt64(-power2 + 1)
        mantissa += mantissa & 1
        mantissa >>= 1
        power2 = mantissa < (1 << 52) ? 0 : 1
        return ((UInt64(power2) << 52) | mantissa, ok)
    }
    if fpLo <= 1 && q >= -4 && q <= 23 && mantissa & 3 == 1 {
        if (mantissa << UInt64(shift)) == fpHi { mantissa &= ~1 }
    }
    mantissa += mantissa & 1
    mantissa >>= 1
    if mantissa >= (2 << 52) { mantissa = 1 << 52; power2 += 1 }
    mantissa &= ~(1 << 52)
    if power2 >= 0x7FF { return (infBits, ok) }
    return ((UInt64(power2) << 52) | mantissa, ok)
}

/// Compare digits * 10^exp10 (plus a nonzero tail if `truncated`) with
/// the halfway point between `b` and the next double up. b is finite, >= 0.
private func jsCompareHalfway(_ big: JSBigNum, _ exp10: Int, _ truncated: Bool, _ b: Double) -> Int {
    let bits = b.bitPattern
    let be = Int((bits >> 52) & 0x7FF)
    var m = bits & ((1 << 52) - 1)
    let e: Int
    if be == 0 { e = -1074 } else { m |= 1 << 52; e = be - 1075 }
    var l = big
    var r = JSBigNum(2 * m + 1)
    var binL = 0, binR = e - 1
    if exp10 >= 0 { l.mulPow5(exp10); binL = exp10 } else { r.mulPow5(-exp10); binR -= exp10 }
    if binL > binR { l.shiftLeft(binL - binR) } else { r.shiftLeft(binR - binL) }
    let c = JSBigNum.compare(l, r)
    return c == 0 && truncated ? 1 : c
}

/// The double nearest to D * 10^exp10, where D is the integer with the
/// given decimal digit values (most significant first). `truncated` means
/// nonzero digits followed that were dropped (a sticky bit).
public func jsDecimalToDouble(_ digitsIn: [UInt8], _ exp10In: Int, truncated truncIn: Bool = false) -> Double {
    // Normalize: no leading zeros, at most jsMaxKeptDigits, no trailing zeros.
    var start = 0
    while start < digitsIn.count && digitsIn[start] == 0 { start += 1 }
    if start == digitsIn.count { return 0 }
    var end = digitsIn.count
    var exp10 = exp10In
    var truncated = truncIn
    if end - start > jsMaxKeptDigits {
        for i in (start + jsMaxKeptDigits)..<end where digitsIn[i] != 0 { truncated = true; break }
        exp10 = jsSatAdd(exp10, end - start - jsMaxKeptDigits)
        end = start + jsMaxKeptDigits
    }
    while end > start + 1 && digitsIn[end - 1] == 0 { end -= 1; exp10 = jsSatAdd(exp10, 1) }
    let n = end - start
    if n + exp10 > 310 { return .infinity }
    if n + exp10 < -324 { return 0 }
    var w: UInt64 = 0
    let fast = min(n, 19)
    for i in start..<(start + fast) { w = w * 10 + UInt64(digitsIn[i]) }
    if n <= 19 && !truncated {
        if w <= (1 << 53) && exp10 >= -22 && exp10 <= 22 {
            let dw = Double(w)
            return exp10 < 0 ? dw / jsPow10Exact[-exp10] : dw * jsPow10Exact[exp10]
        }
        let r = jsEiselLemire(w, exp10)
        if r.ok { return Double(bitPattern: r.bits) }
        return jsDecimalSlow(Array(digitsIn[start..<end]), exp10, truncated, Double(bitPattern: r.bits))
    }
    let q = exp10 + (n - 19)
    let a = jsEiselLemire(w, q)
    if a.ok {
        let b = jsEiselLemire(w + 1, q)
        if b.ok && a.bits == b.bits { return Double(bitPattern: a.bits) }
    }
    return jsDecimalSlow(Array(digitsIn[start..<end]), exp10, truncated, Double(bitPattern: a.bits))
}

@inline(__always) func jsSatAdd(_ a: Int, _ b: Int) -> Int {
    let (r, o) = a.addingReportingOverflow(b)
    if o { return b > 0 ? Int.max / 2 : Int.min / 2 }
    return r > 1 << 40 ? 1 << 40 : (r < -(1 << 40) ? -(1 << 40) : r)
}

/// The exact path: starting near `guess`, step one ulp at a time until the
/// value lies in the guess's rounding interval.
func jsDecimalSlow(_ digits: [UInt8], _ exp10: Int, _ truncated: Bool, _ guessIn: Double) -> Double {
    let big = JSBigNum(digits: digits)
    var b = guessIn.isInfinite ? Double.greatestFiniteMagnitude : (guessIn.isNaN ? 0 : guessIn.magnitude)
    var steps = 0
    while steps < 64 {
        steps += 1
        let c = jsCompareHalfway(big, exp10, truncated, b)
        if c > 0 || (c == 0 && b.bitPattern & 1 == 1) {
            if b == .greatestFiniteMagnitude { return .infinity }
            // Above b's interval (or a tie that goes to the even neighbour).
            let next = Double(bitPattern: b.bitPattern + 1)
            if c == 0 { return next }
            b = next
            // Check we are not now above the lower half of next's interval:
            // loop again to compare against next's upper halfway point; the
            // lower bound is guaranteed since value > halfway(b, next).
            continue
        }
        // value <= halfway(b, next): check the lower halfway point.
        if b == 0 { return 0 }
        let prev = Double(bitPattern: b.bitPattern - 1)
        let cl = jsCompareHalfway(big, exp10, truncated, prev)
        if cl < 0 || (cl == 0 && prev.bitPattern & 1 == 0) {
            if cl == 0 { return prev }
            b = prev
            continue
        }
        return b
    }
    return b
}

// MARK: StringToNumber and parseFloat

@inline(__always) private func jsUnit<C: RandomAccessCollection>(_ s: C, _ i: Int) -> UInt32
where C.Element: FixedWidthInteger, C.Index == Int {
    UInt32(truncatingIfNeeded: s[i])
}

/// Longest prefix of s[from...] that is a StrDecimalLiteral (optional sign,
/// "Infinity", or digits with an optional fraction and exponent). Returns
/// the value and the index just past it, or nil if there is none.
public func jsParseDecimalPrefix<C: RandomAccessCollection>(_ s: C, _ from: Int) -> (value: Double, end: Int)?
where C.Element: FixedWidthInteger, C.Index == Int {
    var i = from
    let end = s.endIndex
    var negative = false
    if i < end {
        let c = jsUnit(s, i)
        if c == 0x2B || c == 0x2D { negative = c == 0x2D; i += 1 }
    }
    // "Infinity"
    if i < end && jsUnit(s, i) == 0x49 {
        let word: [UInt8] = jsInfinityBytes
        if end - i >= word.count {
            var match = true
            for k in 0..<word.count where jsUnit(s, i + k) != UInt32(word[k]) { match = false; break }
            if match { return (negative ? -.infinity : .infinity, i + word.count) }
        }
        return nil
    }
    var digits: [UInt8] = []
    var truncated = false
    var exp10 = 0
    var sawDigit = false
    // Integer part.
    while i < end {
        let c = jsUnit(s, i)
        guard c >= 0x30 && c <= 0x39 else { break }
        sawDigit = true
        if digits.count < jsMaxKeptDigits {
            if !(digits.isEmpty && c == 0x30) { digits.append(UInt8(c - 0x30)) }
        } else {
            exp10 = jsSatAdd(exp10, 1)
            if c != 0x30 { truncated = true }
        }
        i += 1
    }
    // Fraction.
    if i < end && jsUnit(s, i) == 0x2E {
        var j = i + 1
        var fracDigit = false
        while j < end {
            let c = jsUnit(s, j)
            guard c >= 0x30 && c <= 0x39 else { break }
            fracDigit = true
            if digits.count < jsMaxKeptDigits {
                if !(digits.isEmpty && c == 0x30) { digits.append(UInt8(c - 0x30)) }
                exp10 = jsSatAdd(exp10, -1)
            } else if c != 0x30 { truncated = true }
            j += 1
        }
        if sawDigit || fracDigit { i = j; sawDigit = true }
    }
    if !sawDigit { return nil }
    // Exponent: only if at least one digit follows.
    if i < end && (jsUnit(s, i) | 0x20) == 0x65 {
        var j = i + 1
        var eneg = false
        if j < end {
            let c = jsUnit(s, j)
            if c == 0x2B || c == 0x2D { eneg = c == 0x2D; j += 1 }
        }
        var ev = 0
        var expDigit = false
        while j < end {
            let c = jsUnit(s, j)
            guard c >= 0x30 && c <= 0x39 else { break }
            expDigit = true
            if ev < 100_000_000 { ev = ev * 10 + Int(c - 0x30) }
            j += 1
        }
        if expDigit {
            i = j
            exp10 = jsSatAdd(exp10, eneg ? -ev : ev)
        }
    }
    let v = digits.isEmpty ? 0.0 : jsDecimalToDouble(digits, exp10, truncated: truncated)
    return (negative ? -v : v, i)
}

/// Round mantissa * 2^exp2 (plus a nonzero tail if sticky) to a double.
/// exp2 >= 0 (integers only).
private func jsRoundBinary(_ mantissa: UInt64, _ exp2: Int, _ sticky: Bool) -> Double {
    if mantissa == 0 { return 0 }
    let lz = mantissa.leadingZeroBitCount
    let m = mantissa << UInt64(lz)
    var e = exp2 - lz                       // value = m * 2^e
    var top = m >> 11
    let rem = m & 0x7FF
    let up = rem > 0x400 || (rem == 0x400 && (sticky || top & 1 == 1))
    if up {
        top += 1
        if top == 1 << 53 { top >>= 1; e += 1 }
    }
    let biased = e + 11 + 52 + 1023
    if biased >= 0x7FF { return .infinity }
    return Double(bitPattern: (UInt64(biased) << 52) | (top & ((1 << 52) - 1)))
}

/// An integer given as digit values (each < radix, most significant first)
/// to the nearest double. Exact rounding for radix 10 and powers of two;
/// other radices accumulate in doubles (the spec allows approximation past
/// 20 significant digits).
public func jsDigitsToDouble(_ digits: [UInt8], _ radix: Int) -> Double {
    if radix == 10 { return jsDecimalToDouble(digits, 0) }
    var shift = 0
    switch radix {
    case 2: shift = 1
    case 4: shift = 2
    case 8: shift = 3
    case 16: shift = 4
    case 32: shift = 5
    default: break
    }
    if shift > 0 {
        var acc: UInt64 = 0, exp2 = 0, sticky = false
        for d in digits {
            if acc >> 58 == 0 { acc = (acc << UInt64(shift)) | UInt64(d) }
            else {
                exp2 = jsSatAdd(exp2, shift)
                if d != 0 { sticky = true }
            }
        }
        return jsRoundBinary(acc, exp2, sticky)
    }
    var v = 0.0
    for d in digits { v = v * Double(radix) + Double(d) }
    return v
}

/// ECMAScript StringToNumber on JS code units (UInt8 Latin-1 or UInt16).
public func jsStringToNumber<C: RandomAccessCollection>(_ s: C) -> Double
where C.Element: FixedWidthInteger, C.Index == Int {
    var a = s.startIndex, b = s.endIndex
    while a < b && jsIsStrWhiteSpace(jsUnit(s, a)) { a += 1 }
    while b > a && jsIsStrWhiteSpace(jsUnit(s, b - 1)) { b -= 1 }
    if a == b { return 0 }
    if b - a > 2 && jsUnit(s, a) == 0x30 {
        let p = jsUnit(s, a + 1) | 0x20
        var radix = 0
        if p == 0x78 { radix = 16 } else if p == 0x6F { radix = 8 } else if p == 0x62 { radix = 2 }
        if radix != 0 {
            var digits: [UInt8] = []
            var started = false
            for i in (a + 2)..<b {
                let c = jsUnit(s, i)
                var d = 99
                if c >= 0x30 && c <= 0x39 { d = Int(c - 0x30) }
                else if (c | 0x20) >= 0x61 && (c | 0x20) <= 0x66 { d = Int((c | 0x20) - 0x61 + 10) }
                if d >= radix { return .nan }
                if d != 0 || started { digits.append(UInt8(d)); started = true }
            }
            return jsDigitsToDouble(digits, radix)
        }
    }
    let sub = s[a..<b]
    guard let r = jsParseDecimalPrefix(sub, a), r.end == b else { return .nan }
    return r.value
}
