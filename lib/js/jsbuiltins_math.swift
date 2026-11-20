// Math (ROADMAP Phase 9C): no libm. sqrt is the hardware instruction;
// sin/cos/tan/atan/exp/log are fdlibm-style kernels; pow, log2, log10,
// log1p, expm1, cbrt and hypot are evaluated in double-double arithmetic
// (about 100 bits) and rounded once, so they are correctly rounded nearly
// always (log10(1000) == 3, 10 ** -2 == 0.01). Huge sin/cos arguments use
// an exact Payne-Hanek style reduction with 2/pi computed on first use.
//
// Math.random: xorshift64* per realm, state in the Math object's
// internalInt. Embedders seed it with realm.seedRandom(_:).

// MARK: Double-double

struct JSDD {
    var hi: Double
    var lo: Double
}

@inline(__always) func jsTwoSum(_ a: Double, _ b: Double) -> JSDD {
    let s = a + b
    let bb = s - a
    return JSDD(hi: s, lo: (a - (s - bb)) + (b - bb))
}

@inline(__always) func jsQuickTwoSum(_ a: Double, _ b: Double) -> JSDD {
    let s = a + b
    return JSDD(hi: s, lo: b - (s - a))
}

@inline(__always) func jsSplit(_ a: Double) -> (Double, Double) {
    let t = 134217729.0 * a
    let hi = t - (t - a)
    return (hi, a - hi)
}

@inline(__always) func jsTwoProd(_ a: Double, _ b: Double) -> JSDD {
    let p = a * b
    let (ah, al) = jsSplit(a)
    let (bh, bl) = jsSplit(b)
    return JSDD(hi: p, lo: ((ah * bh - p) + ah * bl + al * bh) + al * bl)
}

func jsDDAdd(_ a: JSDD, _ b: JSDD) -> JSDD {
    let s = jsTwoSum(a.hi, b.hi)
    let t = jsTwoSum(a.lo, b.lo)
    let u = jsQuickTwoSum(s.hi, s.lo + t.hi)
    return jsQuickTwoSum(u.hi, u.lo + t.lo)
}

func jsDDNeg(_ a: JSDD) -> JSDD { JSDD(hi: -a.hi, lo: -a.lo) }
func jsDDSub(_ a: JSDD, _ b: JSDD) -> JSDD { jsDDAdd(a, jsDDNeg(b)) }

func jsDDMul(_ a: JSDD, _ b: JSDD) -> JSDD {
    let p = jsTwoProd(a.hi, b.hi)
    let l = p.lo + (a.hi * b.lo + a.lo * b.hi)
    return jsQuickTwoSum(p.hi, l)
}

func jsDDMulD(_ a: JSDD, _ b: Double) -> JSDD {
    let p = jsTwoProd(a.hi, b)
    return jsQuickTwoSum(p.hi, p.lo + a.lo * b)
}

func jsDDDiv(_ a: JSDD, _ b: JSDD) -> JSDD {
    let q1 = a.hi / b.hi
    var r = jsDDSub(a, jsDDMulD(b, q1))
    let q2 = r.hi / b.hi
    r = jsDDSub(r, jsDDMulD(b, q2))
    let q3 = r.hi / b.hi
    let q = jsQuickTwoSum(q1, q2)
    return jsDDAdd(q, JSDD(hi: q3, lo: 0))
}

func jsDDDivD(_ a: JSDD, _ b: Double) -> JSDD { jsDDDiv(a, JSDD(hi: b, lo: 0)) }

let jsDDLn2 = JSDD(hi: 0.6931471805599453, lo: 2.3190468138462996e-17)
let jsDDPi = JSDD(hi: 3.141592653589793, lo: 1.2246467991473532e-16)
let jsDDInvLn10 = JSDD(hi: 0.4342944819032518, lo: 1.098319650216765e-17)

/// 2^k as a double (k in -1074...1023).
func jsPow2(_ k: Int) -> Double {
    if k < -1022 { return Double(bitPattern: UInt64(1) << UInt64(max(0, k + 1074))) }
    if k > 1023 { return .infinity }
    return Double(bitPattern: UInt64(k + 1023) << 52)
}

/// x * 2^k without intermediate overflow.
func jsScalb(_ xIn: Double, _ kIn: Int) -> Double {
    var x = xIn
    var k = kIn
    while k > 1000 { x *= jsPow2(1000); k -= 1000; if x.isInfinite { return x } }
    while k < -1000 { x *= jsPow2(-1000); k += 1000; if x == 0 { return x } }
    if k < -1022 {
        x *= jsPow2(-1000)
        return x * jsPow2(k + 1000)
    }
    return x * jsPow2(k)
}

/// log of a positive finite dd (double-double precision).
func jsDDLog(_ a: JSDD) -> JSDD {
    var hi = a.hi, lo = a.lo
    var e = Int((hi.bitPattern >> 52) & 0x7FF)
    if e == 0 {
        hi *= 4503599627370496.0; lo *= 4503599627370496.0
        e = Int((hi.bitPattern >> 52) & 0x7FF) - 52
    }
    var k = e - 1023
    var m = Double(bitPattern: (hi.bitPattern & 0x000F_FFFF_FFFF_FFFF) | 0x3FF0_0000_0000_0000)
    var ml = lo * jsPow2(-k)
    if m > 1.4142135623730951 { m /= 2; ml /= 2; k += 1 }
    let mdd = JSDD(hi: m, lo: ml)
    let one = JSDD(hi: 1, lo: 0)
    let s = jsDDDiv(jsDDSub(mdd, one), jsDDAdd(mdd, one))
    let s2 = jsDDMul(s, s)
    // sum = s * (1 + s2/3 + s2^2/5 + ...), Horner from the top.
    var acc = JSDD(hi: 0, lo: 0)
    var n = 41
    while n >= 1 {
        acc = jsDDAdd(jsDDMul(acc, s2), jsDDDivD(one, Double(n)))
        n -= 2
    }
    let series = jsDDMul(jsDDMulD(s, 2), acc)
    return jsDDAdd(series, jsDDMulD(jsDDLn2, Double(k)))
}

/// exp of a dd, returned as (mantissa dd, exponent k): value = m * 2^k.
func jsDDExpParts(_ a: JSDD) -> (JSDD, Int) {
    let k = Int(jsMathRound(a.hi / 0.6931471805599453))
    let r0 = jsDDSub(a, jsDDMulD(jsDDLn2, Double(k)))
    let r = JSDD(hi: r0.hi / 512, lo: r0.lo / 512)
    // expm1(r) by Taylor.
    var term = r
    var sum = r
    var n = 2.0
    while n <= 14 {
        term = jsDDDivD(jsDDMul(term, r), n)
        sum = jsDDAdd(sum, term)
        n += 1
    }
    for _ in 0..<9 {
        // (1+s)^2 - 1 = 2s + s^2
        sum = jsDDAdd(jsDDMulD(sum, 2), jsDDMul(sum, sum))
    }
    return (jsDDAdd(sum, JSDD(hi: 1, lo: 0)), k)
}

func jsDDToDouble(_ m: JSDD, _ k: Int) -> Double {
    jsScalb(m.hi + m.lo, k)
}

// MARK: Basic helpers

func jsMathFloor(_ x: Double) -> Double { x == 0 ? x : jsFloor(x) }
func jsMathCeil(_ x: Double) -> Double {
    if x == 0 || !x.isFinite { return x }
    let r = -jsFloor(-x)
    return r == 0 && x < 0 ? -0.0 : r
}
func jsMathRound(_ x: Double) -> Double {
    if !x.isFinite || x == 0 || x.magnitude >= 4503599627370496.0 { return x }
    if x < 0 && x >= -0.5 { return -0.0 }
    let f = jsFloor(x)
    return x - f >= 0.5 ? f + 1 : f
}

@inline(__always) func jsHighWord(_ x: Double) -> Int32 { Int32(bitPattern: UInt32(truncatingIfNeeded: x.bitPattern >> 32)) }
@inline(__always) func jsFromWords(_ hi: UInt32, _ lo: UInt32) -> Double {
    Double(bitPattern: (UInt64(hi) << 32) | UInt64(lo))
}
@inline(__always) func jsLowWord(_ x: Double) -> UInt32 { UInt32(truncatingIfNeeded: x.bitPattern) }

// MARK: exp / log (fdlibm)

func jsMathExp(_ x: Double) -> Double {
    if x.isNaN { return .nan }
    if x > 709.782712893384 { return .infinity }
    if x < -745.1332191019411 { return 0 }
    if x.magnitude < 5.551115123125783e-17 { return 1 + x }
    let (m, k) = jsDDExpParts(JSDD(hi: x, lo: 0))
    return jsDDToDouble(m, k)
}

func jsMathLog(_ xIn: Double) -> Double {
    var x = xIn
    if x.isNaN { return .nan }
    if x < 0 { return .nan }
    if x == 0 { return -.infinity }
    if x.isInfinite { return x }
    let ln2_hi = Double(bitPattern: 0x3FE62E42FEE00000), ln2_lo = Double(bitPattern: 0x3DEA39EF35793C76)
    let Lg1 = 6.666666666666735130e-01, Lg2 = 3.999999999940941908e-01, Lg3 = 2.857142874366239149e-01
    let Lg4 = 2.222219843214978396e-01, Lg5 = 1.818357216161805012e-01, Lg6 = 1.531383769920937332e-01
    let Lg7 = 1.479819860511658591e-01
    var hx = Int(jsHighWord(x))
    var k = 0
    if hx < 0x00100000 {
        k -= 54
        x *= 18014398509481984.0
        hx = Int(jsHighWord(x))
    }
    k += (hx >> 20) - 1023
    hx &= 0x000FFFFF
    let i = (hx + 0x95F64) & 0x100000
    x = jsFromWords(UInt32(hx | (i ^ 0x3FF00000)), jsLowWord(x))
    k += i >> 20
    let f = x - 1.0
    let dk = Double(k)
    if (0x000FFFFF & (2 + hx)) < 3 {
        if f == 0 {
            if k == 0 { return 0 }
            return dk * ln2_hi + dk * ln2_lo
        }
        let R = f * f * (0.5 - 0.33333333333333333 * f)
        if k == 0 { return f - R }
        return dk * ln2_hi - ((R - dk * ln2_lo) - f)
    }
    let s = f / (2.0 + f)
    let z = s * s
    var ii = hx - 0x6147A
    let w = z * z
    let j = 0x6B851 - hx
    let t1 = w * (Lg2 + w * (Lg4 + w * Lg6))
    let t2 = z * (Lg1 + w * (Lg3 + w * (Lg5 + w * Lg7)))
    ii |= j
    let R = t2 + t1
    if ii > 0 {
        let hfsq = 0.5 * f * f
        if k == 0 { return f - (hfsq - s * (hfsq + R)) }
        return dk * ln2_hi - ((hfsq - (s * (hfsq + R) + dk * ln2_lo)) - f)
    }
    if k == 0 { return f - s * (f - R) }
    return dk * ln2_hi - ((s * (f - R) - dk * ln2_lo) - f)
}

/// ln of a positive finite x as a correctly rounded double.
func jsMathLogDD(_ x: Double) -> JSDD { jsDDLog(JSDD(hi: x, lo: 0)) }

func jsMathLog2(_ x: Double) -> Double {
    if x.isNaN || x < 0 { return .nan }
    if x == 0 { return -.infinity }
    if x.isInfinite { return x }
    let l = jsDDMul(jsMathLogDD(x), JSDD(hi: 1.4426950408889634, lo: 2.0355273740931033e-17))
    return l.hi + l.lo
}

func jsMathLog10(_ x: Double) -> Double {
    if x.isNaN || x < 0 { return .nan }
    if x == 0 { return -.infinity }
    if x.isInfinite { return x }
    let l = jsDDMul(jsMathLogDD(x), jsDDInvLn10)
    return l.hi + l.lo
}

func jsMathLog1p(_ x: Double) -> Double {
    if x.isNaN || x < -1 { return .nan }
    if x == -1 { return -.infinity }
    if x.isInfinite { return x }
    let ax = x.magnitude
    if ax < 1e-5 { return x - x * x / 2 + x * x * x / 3 - x * x * x * x / 4 }
    let l = jsDDLog(jsTwoSum(1, x))
    return l.hi + l.lo
}

func jsMathExpm1(_ x: Double) -> Double {
    if x.isNaN || x == 0 { return x }
    if x > 709.782712893384 { return .infinity }
    if x < -40 { return -1 }
    let ax = x.magnitude
    if ax < 1e-5 { return x + x * x / 2 + x * x * x / 6 + x * x * x * x / 24 }
    let (m, k) = jsDDExpParts(JSDD(hi: x, lo: 0))
    if k == 0 {
        let r = jsDDSub(m, JSDD(hi: 1, lo: 0))
        return r.hi + r.lo
    }
    let scaled = jsDDSub(JSDD(hi: jsScalb(m.hi, k), lo: jsScalb(m.lo, k)), JSDD(hi: 1, lo: 0))
    return scaled.hi + scaled.lo
}

func jsMathPowAccurate(_ x: Double, _ y: Double) -> Double {
    // x finite non-zero, y finite non-zero (specials handled by the caller).
    let ax = x.magnitude
    let L = jsMathLogDD(ax)
    var p = jsTwoProd(L.hi, y)
    p = jsQuickTwoSum(p.hi, p.lo + L.lo * y)
    if p.hi > 710 { return .infinity }
    if p.hi < -746 { return 0 }
    let (m, k) = jsDDExpParts(p)
    return jsDDToDouble(m, k)
}

// MARK: Trig

private let jsPio2_1 = 1.57079632673412561417e+00
private let jsPio2_1t = 6.07710050650619224932e-11
private let jsPio2_2 = 6.07710050630396597660e-11
private let jsPio2_2t = 2.02226624879595063154e-21
private let jsPio2_3 = 2.02226624871116645580e-21
private let jsPio2_3t = 8.47842766036889956997e-32

private func jsKSin(_ x: Double, _ y: Double, _ iy: Int) -> Double {
    let S1 = -1.66666666666666324348e-01, S2 = 8.33333333332248946124e-03, S3 = -1.98412698298579493134e-04
    let S4 = 2.75573137070700676789e-06, S5 = -2.50507602534068634195e-08, S6 = 1.58969099521155010221e-10
    let z = x * x
    let v = z * x
    let r = S2 + z * (S3 + z * (S4 + z * (S5 + z * S6)))
    if iy == 0 { return x + v * (S1 + z * r) }
    return x - ((z * (0.5 * y - v * r) - y) - v * S1)
}

private func jsKCos(_ x: Double, _ y: Double) -> Double {
    let C1 = 4.16666666666666019037e-02, C2 = -1.38888888888741095749e-03, C3 = 2.48015872894767294178e-05
    let C4 = -2.75573143513906633035e-07, C5 = 2.08757232129817482790e-09, C6 = -1.13596475577881948265e-11
    let z = x * x
    let r = z * (C1 + z * (C2 + z * (C3 + z * (C4 + z * (C5 + z * C6)))))
    let ix = jsHighWord(x) & 0x7FFFFFFF
    if ix < 0x3FD33333 { return 1.0 - (0.5 * z - (z * r - x * y)) }
    let qx: Double = ix > 0x3FE90000 ? 0.28125 : jsFromWords(UInt32(ix - 0x00200000), 0)
    let hz = 0.5 * z - qx
    let a = 1.0 - qx
    return a - (hz - (z * r - x * y))
}

private func jsKTan(_ xIn: Double, _ yIn: Double, _ odd: Bool) -> Double {
    // tan(x + y) on |x| <= pi/4; odd: return -1/tan.
    let T: [Double] = [3.33333333333334091986e-01, 1.33333333333201242699e-01, 5.39682539762260521377e-02,
                       2.18694882948595424599e-02, 8.86323982359930005737e-03, 3.59207910759131235356e-03,
                       1.45620945432529025516e-03, 5.88041240820264096874e-04, 2.46463134818469906812e-04,
                       7.81794442939557092300e-05, 7.14072491382608190305e-05, -1.85586374855275456654e-05,
                       2.59073051863633712884e-05]
    let pio4 = 7.85398163397448278999e-01, pio4lo = 3.06161699786838301793e-17
    var x = xIn, y = yIn
    let hx = jsHighWord(x)
    let ix = hx & 0x7FFFFFFF
    if ix < 0x3E300000 {
        if !odd { return x }
        return -1.0 / (x + y)
    }
    let big = ix >= 0x3FE59428
    if big {
        if hx < 0 { x = -x; y = -y }
        let z = pio4 - x
        let w = pio4lo - y
        x = z + w
        y = 0
    }
    let z = x * x
    let w = z * z
    var r = T[1] + w * (T[3] + w * (T[5] + w * (T[7] + w * (T[9] + w * T[11]))))
    let v = z * (T[2] + w * (T[4] + w * (T[6] + w * (T[8] + w * (T[10] + w * T[12])))))
    let s = z * x
    r = y + z * (s * (r + v) + y)
    r += T[0] * s
    let ww = x + r
    if big {
        let vv = odd ? -1.0 : 1.0
        // (1 - ((hx>>30)&2)) is the sign of the original x.
        let sign = hx < 0 ? -1.0 : 1.0
        return sign * (vv - 2.0 * (x - (ww * ww / (ww + vv) - r)))
    }
    if !odd { return ww }
    let zz = Double(bitPattern: ww.bitPattern & 0xFFFFFFFF00000000)
    let vv = r - (zz - x)
    let a = -1.0 / ww
    let t = Double(bitPattern: a.bitPattern & 0xFFFFFFFF00000000)
    let ss = 1.0 + t * zz
    return t + a * (ss + t * vv)
}

nonisolated(unsafe) private var jsTwoOverPi: [UInt32] = []   // little-endian limbs, F = 1280 fractional bits
private let jsTwoOverPiFrac = 1280

private func jsBigCmp(_ a: [UInt32], _ b: [UInt32]) -> Int {
    var i = max(a.count, b.count) - 1
    while i >= 0 {
        let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
        if x != y { return x < y ? -1 : 1 }
        i -= 1
    }
    return 0
}
private func jsBigSub(_ a: inout [UInt32], _ b: [UInt32]) {
    var borrow: Int64 = 0
    for i in 0..<a.count {
        var d = Int64(a[i]) - borrow - (i < b.count ? Int64(b[i]) : 0)
        if d < 0 { d += 1 << 32; borrow = 1 } else { borrow = 0 }
        a[i] = UInt32(d)
    }
}
private func jsBigAdd(_ a: inout [UInt32], _ b: [UInt32]) {
    var c: UInt64 = 0
    for i in 0..<a.count {
        let s = UInt64(a[i]) + (i < b.count ? UInt64(b[i]) : 0) + c
        a[i] = UInt32(truncatingIfNeeded: s)
        c = s >> 32
    }
}
private func jsBigDivSmall(_ a: inout [UInt32], _ d: UInt32) {
    var r: UInt64 = 0
    var i = a.count - 1
    while i >= 0 {
        let cur = (r << 32) | UInt64(a[i])
        a[i] = UInt32(cur / UInt64(d))
        r = cur % UInt64(d)
        i -= 1
    }
}
private func jsBigIsZero(_ a: [UInt32]) -> Bool { for x in a where x != 0 { return false }; return true }

/// 2/pi with 1280 fractional bits (computed once: Machin's formula, then a
/// binary long division).
private func jsComputeTwoOverPi() -> [UInt32] {
    let F = jsTwoOverPiFrac
    let limbs = F / 32 + 3
    // arctan(1/n) in fixed point (F fractional bits).
    func arctanInv(_ n: UInt32) -> [UInt32] {
        var term = [UInt32](repeating: 0, count: limbs)
        term[F / 32] = 1                       // 1.0
        jsBigDivSmall(&term, n)
        var sum = term
        var k: UInt32 = 1
        var negate = true
        let n2 = n * n
        while !jsBigIsZero(term) {
            jsBigDivSmall(&term, n2)
            k += 2
            var t = term
            jsBigDivSmall(&t, k)
            if negate { jsBigSub(&sum, t) } else { jsBigAdd(&sum, t) }
            negate = !negate
        }
        return sum
    }
    var a5 = arctanInv(5)
    var a239 = arctanInv(239)
    // pi = 16 atan(1/5) - 4 atan(1/239)
    func mulSmall(_ a: inout [UInt32], _ m: UInt32) {
        var c: UInt64 = 0
        for i in 0..<a.count {
            let p = UInt64(a[i]) * UInt64(m) + c
            a[i] = UInt32(truncatingIfNeeded: p)
            c = p >> 32
        }
    }
    mulSmall(&a5, 16)
    mulSmall(&a239, 4)
    var pi = a5
    jsBigSub(&pi, a239)
    // q = floor(2^(2F+1) / pi): binary long division.
    let totalBits = 2 * F + 2
    var rem = [UInt32](repeating: 0, count: limbs + 1)
    var q = [UInt32](repeating: 0, count: limbs)
    var piX = pi
    piX.append(0)
    var bit = totalBits - 1
    while bit >= 0 {
        // rem = rem << 1 | (bit == 2F+1 ? 1 : 0)
        var carry: UInt32 = bit == 2 * F + 1 ? 1 : 0
        for i in 0..<rem.count {
            let nc = rem[i] >> 31
            rem[i] = (rem[i] << 1) | carry
            carry = nc
        }
        if jsBigCmp(rem, piX) >= 0 {
            jsBigSub(&rem, piX)
            if bit / 32 < q.count { q[bit / 32] |= UInt32(1) << UInt32(bit % 32) }
        }
        bit -= 1
    }
    return q
}

/// Reduce huge |x|: returns (n mod 4, y0, y1) with x = n*pi/2 + y0 + y1.
private func jsReduceHuge(_ x: Double) -> (Int, Double, Double) {
    if jsTwoOverPi.isEmpty { jsTwoOverPi = jsComputeTwoOverPi() }
    let K = jsTwoOverPi
    let bits = x.magnitude.bitPattern
    let e = Int((bits >> 52) & 0x7FF) - 1075
    let m = (bits & 0x000F_FFFF_FFFF_FFFF) | 0x0010_0000_0000_0000
    // P = m * K (limbs).
    var P = [UInt32](repeating: 0, count: K.count + 3)
    let mlo = UInt64(m & 0xFFFF_FFFF), mhi = UInt64(m >> 32)
    var c: UInt64 = 0
    for i in 0..<K.count {
        let p = UInt64(K[i]) * mlo + c + UInt64(P[i])
        P[i] = UInt32(truncatingIfNeeded: p)
        c = p >> 32
    }
    var j = K.count
    while c != 0 { P[j] = UInt32(truncatingIfNeeded: c); c >>= 32; j += 1 }
    c = 0
    for i in 0..<K.count {
        let p = UInt64(K[i]) * mhi + c + UInt64(P[i + 1])
        P[i + 1] = UInt32(truncatingIfNeeded: p)
        c = p >> 32
    }
    j = K.count + 1
    while c != 0 && j < P.count { let s = UInt64(P[j]) + c; P[j] = UInt32(truncatingIfNeeded: s); c = s >> 32; j += 1 }
    // value = P * 2^(e - F). Shift: s = F - e bits to the right.
    let s = jsTwoOverPiFrac - e
    func bit(_ i: Int) -> UInt64 {
        if i < 0 { return 0 }
        let w = i / 32
        return w < P.count ? UInt64((P[w] >> UInt32(i % 32)) & 1) : 0
    }
    var nmod = 0
    if s >= 0 {
        nmod = Int(bit(s) | (bit(s + 1) << 1))
    }
    // Fraction: 106 bits just below the binary point (bits s-1 ... s-106).
    var fHi = 0.0, fLo = 0.0
    var scale = 0.5
    var acc: UInt64 = 0
    var cnt = 0
    var part = 0
    var k = s - 1
    while part < 2 {
        acc = 0; cnt = 0
        var sc = scale
        var v = 0.0
        while cnt < 53 {
            if bit(k) == 1 { v += sc }
            sc *= 0.5
            k -= 1
            cnt += 1
        }
        if part == 0 { fHi = v } else { fLo = v }
        scale = sc
        part += 1
    }
    _ = acc
    var f = JSDD(hi: fHi, lo: fLo)
    if f.hi >= 0.5 {
        nmod += 1
        f = jsDDSub(f, JSDD(hi: 1, lo: 0))
    }
    var y = jsDDMul(f, JSDD(hi: 1.5707963267948966, lo: 6.123233995736766e-17))
    if x < 0 {
        y = jsDDNeg(y)
        nmod = (4 - (nmod & 3)) & 3
    }
    return (nmod & 3, y.hi, y.lo)
}

/// (n mod 4, y0, y1): x = n*pi/2 + y0 + y1, |y0| <= pi/4 (finite x).
private func jsRemPio2(_ x: Double) -> (Int, Double, Double) {
    let ix = jsHighWord(x) & 0x7FFFFFFF
    if ix >= 0x413921FB { return jsReduceHuge(x) }  // |x| >= 2^20 * pi/2
    let invpio2 = 6.36619772367581382433e-01
    let n = Int(x * invpio2 + (x < 0 ? -0.5 : 0.5))
    let fn = Double(n)
    var r = x - fn * jsPio2_1
    var w = fn * jsPio2_1t
    var y0 = r - w
    let j = Int(ix >> 20)
    var i = j - Int((jsHighWord(y0) >> 20) & 0x7FF)
    if i > 16 {
        let t = r
        w = fn * jsPio2_2
        r = t - w
        w = fn * jsPio2_2t - ((t - r) - w)
        y0 = r - w
        i = j - Int((jsHighWord(y0) >> 20) & 0x7FF)
        if i > 49 {
            let t2 = r
            w = fn * jsPio2_3
            r = t2 - w
            w = fn * jsPio2_3t - ((t2 - r) - w)
            y0 = r - w
        }
    }
    let y1 = (r - y0) - w
    return (n & 3, y0, y1)
}

func jsMathSin(_ x: Double) -> Double {
    if !x.isFinite { return .nan }
    let ix = jsHighWord(x) & 0x7FFFFFFF
    if ix <= 0x3FE921FB { return ix < 0x3E500000 ? x : jsKSin(x, 0, 0) }
    let (n, y0, y1) = jsRemPio2(x)
    switch n {
    case 0: return jsKSin(y0, y1, 1)
    case 1: return jsKCos(y0, y1)
    case 2: return -jsKSin(y0, y1, 1)
    default: return -jsKCos(y0, y1)
    }
}

func jsMathCos(_ x: Double) -> Double {
    if !x.isFinite { return .nan }
    let ix = jsHighWord(x) & 0x7FFFFFFF
    if ix <= 0x3FE921FB { return ix < 0x3E46A09E ? 1 : jsKCos(x, 0) }
    let (n, y0, y1) = jsRemPio2(x)
    switch n {
    case 0: return jsKCos(y0, y1)
    case 1: return -jsKSin(y0, y1, 1)
    case 2: return -jsKCos(y0, y1)
    default: return jsKSin(y0, y1, 1)
    }
}

func jsMathTan(_ x: Double) -> Double {
    if !x.isFinite { return .nan }
    let ix = jsHighWord(x) & 0x7FFFFFFF
    if ix <= 0x3FE921FB { return jsKTan(x, 0, false) }
    let (n, y0, y1) = jsRemPio2(x)
    return jsKTan(y0, y1, n & 1 == 1)
}

private let jsAtanHi: [Double] = [4.63647609000806093515e-01, 7.85398163397448278999e-01,
                                  9.82793723247329054082e-01, 1.57079632679489655800e+00]
private let jsAtanLo: [Double] = [2.26987774529616870924e-17, 3.06161699786838301793e-17,
                                  1.39033110312309984516e-17, 6.12323399573676603587e-17]
private let jsAT: [Double] = [3.33333333333329318027e-01, -1.99999999998764832476e-01, 1.42857142725034663711e-01,
                              -1.11111104054623557880e-01, 9.09088713343650656196e-02, -7.69187620504482999495e-02,
                              6.66107313738753120669e-02, -5.83357013379057348645e-02, 4.97687799461593236017e-02,
                              -3.65315727442169155270e-02, 1.62858201153657823623e-02]

func jsMathAtan(_ xIn: Double) -> Double {
    var x = xIn
    if x.isNaN { return .nan }
    let neg = x < 0 || (x == 0 && x.sign == .minus)
    let ax = x.magnitude
    if ax >= 7.378697629483821e19 { return neg ? -jsAtanHi[3] - jsAtanLo[3] : jsAtanHi[3] + jsAtanLo[3] }
    var id = -1
    if ax < 0.4375 {
        if ax < 7.450580596923828e-09 { return x }
    } else {
        x = ax
        if ax < 1.1875 {
            if ax < 0.6875 { id = 0; x = (2.0 * ax - 1.0) / (2.0 + ax) }
            else { id = 1; x = (ax - 1.0) / (ax + 1.0) }
        } else if ax < 2.4375 {
            id = 2; x = (ax - 1.5) / (1.0 + 1.5 * ax)
        } else {
            id = 3; x = -1.0 / ax
        }
    }
    let z = x * x
    let w = z * z
    let s1 = z * (jsAT[0] + w * (jsAT[2] + w * (jsAT[4] + w * (jsAT[6] + w * (jsAT[8] + w * jsAT[10])))))
    let s2 = w * (jsAT[1] + w * (jsAT[3] + w * (jsAT[5] + w * (jsAT[7] + w * jsAT[9]))))
    if id < 0 { return x - x * (s1 + s2) }
    let r = jsAtanHi[id] - ((x * (s1 + s2) - jsAtanLo[id]) - x)
    return neg ? -r : r
}

func jsMathAtan2(_ y: Double, _ x: Double) -> Double {
    if x.isNaN || y.isNaN { return .nan }
    let pi = 3.1415926535897931160, piLo = 1.2246467991473531772e-16
    func sgn(_ v: Double, _ s: Double) -> Double { s.sign == .minus ? -v : v }
    if y == 0 {
        if x > 0 || (x == 0 && x.sign == .plus) { return y }
        return sgn(pi, y)
    }
    if x == 0 { return sgn(pi / 2, y) }
    if x.isInfinite {
        if y.isInfinite { return x > 0 ? sgn(pi / 4, y) : sgn(3 * pi / 4, y) }
        return x > 0 ? sgn(0, y) : sgn(pi, y)
    }
    if y.isInfinite { return sgn(pi / 2, y) }
    let k = Int((y.magnitude.bitPattern >> 52) & 0x7FF) - Int((x.magnitude.bitPattern >> 52) & 0x7FF)
    var z: Double
    if k > 60 { z = pi / 2 + 0.5 * piLo }
    else if x < 0 && k < -60 { z = 0 }
    else { z = jsMathAtan((y / x).magnitude) }
    if x > 0 { return sgn(z, y) }
    return sgn(pi - (z - piLo), y)
}

func jsMathAsin(_ x: Double) -> Double {
    if x.isNaN || x.magnitude > 1 { return .nan }
    if x.magnitude < 7.450580596923828e-09 { return x }
    return jsMathAtan2(x, ((1 - x) * (1 + x)).squareRoot())
}

func jsMathAcos(_ x: Double) -> Double {
    if x.isNaN || x.magnitude > 1 { return .nan }
    if x == 1 { return 0 }
    if x == -1 { return 3.141592653589793 }
    return 2 * jsMathAtan2((1 - x).squareRoot(), (1 + x).squareRoot())
}

// MARK: Hyperbolic and friends

func jsMathSinh(_ x: Double) -> Double {
    if x.isNaN || x.isInfinite || x == 0 { return x }
    let ax = x.magnitude
    var r: Double
    if ax < 22 {
        if ax < 3.725290298461914e-09 { return x }
        let t = jsMathExpm1(ax)
        r = ax < 1 ? 0.5 * (2.0 * t - t * t / (t + 1.0)) : 0.5 * (t + t / (t + 1.0))
    } else if ax < 709.782712893384 {
        r = 0.5 * jsMathExp(ax)
    } else {
        let w = jsMathExp(0.5 * ax)
        r = 0.5 * w * w
    }
    return x < 0 ? -r : r
}

func jsMathCosh(_ x: Double) -> Double {
    if x.isNaN { return .nan }
    let ax = x.magnitude
    if ax.isInfinite { return .infinity }
    if ax < 0.34657359027997264 {
        let t = jsMathExpm1(ax)
        let w = 1 + t
        if ax < 3.725290298461914e-09 { return w }
        return 1 + (t * t) / (w + w)
    }
    if ax < 22 {
        let t = jsMathExp(ax)
        return 0.5 * t + 0.5 / t
    }
    if ax < 709.782712893384 { return 0.5 * jsMathExp(ax) }
    let w = jsMathExp(0.5 * ax)
    return 0.5 * w * w
}

func jsMathTanh(_ x: Double) -> Double {
    if x.isNaN { return .nan }
    if x.isInfinite { return x > 0 ? 1 : -1 }
    if x == 0 { return x }
    let ax = x.magnitude
    var z: Double
    if ax < 22 {
        if ax < 5.551115123125783e-17 { return x }
        if ax >= 1 {
            let t = jsMathExpm1(2 * ax)
            z = 1 - 2 / (t + 2)
        } else {
            let t = jsMathExpm1(-2 * ax)
            z = -t / (t + 2)
        }
    } else { z = 1 }
    return x < 0 ? -z : z
}

func jsMathAsinh(_ x: Double) -> Double {
    if x.isNaN || x.isInfinite || x == 0 { return x }
    let ax = x.magnitude
    var w: Double
    if ax < 3.725290298461914e-09 { return x }
    if ax > 268435456.0 { w = jsMathLog(ax) + 0.6931471805599453 }
    else if ax > 2 { w = jsMathLog(2 * ax + 1 / ((x * x + 1).squareRoot() + ax)) }
    else { let t = x * x; w = jsMathLog1p(ax + t / (1 + (1 + t).squareRoot())) }
    return x < 0 ? -w : w
}

func jsMathAcosh(_ x: Double) -> Double {
    if x.isNaN || x < 1 { return .nan }
    if x == 1 { return 0 }
    if x.isInfinite { return x }
    if x >= 268435456.0 { return jsMathLog(x) + 0.6931471805599453 }
    if x > 2 { return jsMathLog(2 * x - 1 / (x + (x * x - 1).squareRoot())) }
    let t = x - 1
    return jsMathLog1p(t + (2 * t + t * t).squareRoot())
}

func jsMathAtanh(_ x: Double) -> Double {
    if x.isNaN || x.magnitude > 1 { return .nan }
    if x == 1 { return .infinity }
    if x == -1 { return -.infinity }
    let ax = x.magnitude
    if ax < 3.725290298461914e-09 { return x }
    var t: Double
    if ax < 0.5 { t = ax + ax; t = 0.5 * jsMathLog1p(t + t * ax / (1 - ax)) }
    else { t = 0.5 * jsMathLog1p((ax + ax) / (1 - ax)) }
    return x < 0 ? -t : t
}

func jsMathCbrt(_ x: Double) -> Double {
    if x.isNaN || x.isInfinite || x == 0 { return x }
    let ax = x.magnitude
    let L = jsDDDivD(jsMathLogDD(ax), 3)
    let (m, k) = jsDDExpParts(L)
    var r = jsDDToDouble(m, k)
    // Snap to an exact cube root when one exists.
    let rr = jsMathRound(r)
    if rr * rr * rr == ax { r = rr }
    return x < 0 ? -r : r
}

func jsMathHypot(_ vals: [Double]) -> Double {
    var inf = false, nan = false
    var mx = 0.0
    for v in vals {
        if v.isInfinite { inf = true }
        if v.isNaN { nan = true }
        if v.magnitude > mx { mx = v.magnitude }
    }
    if inf { return .infinity }
    if nan { return .nan }
    if mx == 0 { return 0 }
    let e = Int((mx.bitPattern >> 52) & 0x7FF) - 1023
    let sc = jsScalb(1, -e)
    var sum = JSDD(hi: 0, lo: 0)
    for v in vals {
        let s = v * sc
        sum = jsDDAdd(sum, jsTwoProd(s, s))
    }
    let r = sum.hi.squareRoot()
    // One Newton correction in double-double.
    let r2 = jsTwoProd(r, r)
    let diff = jsDDSub(sum, r2)
    let res = r + (diff.hi + diff.lo) / (2 * r)
    return jsScalb(res, e)
}

// MARK: Install

extension JSRealm {
    /// Seed Math.random (any value; zero is replaced).
    public func seedRandom(_ seed: UInt64) {
        let m = intrinsic(.mathObject)
        heap.setInternalInt(m, Int64(bitPattern: seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed))
    }
}

func jsInstallMath(_ realm: JSRealm) {
    let heap = realm.heap
    let m = heap.newObject(proto: realm.objectPrototype)
    realm.setIntrinsic(.mathObject, m)
    realm.defineGlobal("Math", m)
    realm.seedRandom(0x853C_49E6_748F_EA9B)
    _ = heap.defineOwnProperty(m, .symbol(heap.symbolsWellKnown.toStringTag.handle),
                               .data(realm.string("Math"), [.configurable]))
    let consts: [(String, Double)] = [("E", 2.718281828459045), ("LN10", 2.302585092994046), ("LN2", 0.6931471805599453),
        ("LOG10E", 0.4342944819032518), ("LOG2E", 1.4426950408889634), ("PI", 3.141592653589793),
        ("SQRT1_2", 0.7071067811865476), ("SQRT2", 1.4142135623730951)]
    for (n, v) in consts { realm.defineValue(m, n, .double(v), []) }

    func unary(_ name: String, _ f: @escaping (Double) -> Double) {
        realm.defineMethod(m, name, length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            .number(f(try realm.toNumber(args[0])))
        }
    }
    unary("abs") { (x: Double) -> Double in x.magnitude }
    unary("floor", jsMathFloor)
    unary("ceil", jsMathCeil)
    unary("round", jsMathRound)
    unary("trunc") { (x: Double) -> Double in x == 0 ? x : jsTrunc(x) }
    unary("sign") { (x: Double) -> Double in x.isNaN || x == 0 ? x : (x < 0 ? -1 : 1) }
    unary("sqrt") { (x: Double) -> Double in x.squareRoot() }
    unary("cbrt", jsMathCbrt)
    unary("exp", jsMathExp)
    unary("expm1", jsMathExpm1)
    unary("log", jsMathLog)
    unary("log2", jsMathLog2)
    unary("log10", jsMathLog10)
    unary("log1p", jsMathLog1p)
    unary("sin", jsMathSin)
    unary("cos", jsMathCos)
    unary("tan", jsMathTan)
    unary("asin", jsMathAsin)
    unary("acos", jsMathAcos)
    unary("atan", jsMathAtan)
    unary("sinh", jsMathSinh)
    unary("cosh", jsMathCosh)
    unary("tanh", jsMathTanh)
    unary("asinh", jsMathAsinh)
    unary("acosh", jsMathAcosh)
    unary("atanh", jsMathAtanh)
    unary("fround") { (x: Double) -> Double in Double(Float(x)) }
    realm.defineMethod(m, "clz32", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        .number(jsToUint32(try realm.toNumber(args[0])).leadingZeroBitCount)
    }
    realm.defineMethod(m, "imul", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let a = jsToInt32(try realm.toNumber(args[0]))
        let b = jsToInt32(try realm.toNumber(args[1]))
        return .int32(a &* b)
    }
    realm.defineMethod(m, "atan2", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let y = try realm.toNumber(args[0])
        let x = try realm.toNumber(args[1])
        return .number(jsMathAtan2(y, x))
    }
    realm.defineMethod(m, "pow", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let x = try realm.toNumber(args[0])
        let y = try realm.toNumber(args[1])
        return .number(jsPowNumber(x, y))
    }
    realm.defineMethod(m, "hypot", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        var vals: [Double] = []
        for i in 0..<args.count { vals.append(try realm.toNumber(args[i])) }
        return .number(jsMathHypot(vals))
    }
    func minmax(_ name: String, _ isMax: Bool) {
        realm.defineMethod(m, name, length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            var vals: [Double] = []
            for i in 0..<args.count { vals.append(try realm.toNumber(args[i])) }
            var r = isMax ? -Double.infinity : Double.infinity
            var nan = false
            for v in vals {
                if v.isNaN { nan = true; continue }
                if isMax {
                    if v > r || (v == 0 && r == 0 && v.sign == .plus) { r = v }
                } else {
                    if v < r || (v == 0 && r == 0 && v.sign == .minus) { r = v }
                }
            }
            return .number(nan ? Double.nan : r)
        }
    }
    minmax("max", true)
    minmax("min", false)
    realm.defineMethod(m, "random", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let mo = realm.intrinsic(.mathObject)
        var s = UInt64(bitPattern: realm.heap.internalInt(mo))
        s ^= s >> 12
        s ^= s << 25
        s ^= s >> 27
        realm.heap.setInternalInt(mo, Int64(bitPattern: s))
        let r = (s &* 0x2545_F491_4F6C_DD1D) >> 11
        return .double(Double(r) * 1.1102230246251565e-16)
    }
}
