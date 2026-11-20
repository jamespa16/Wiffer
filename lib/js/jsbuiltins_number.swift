// Number, Boolean and the global functions (ROADMAP Phase 9C, ES2023):
// Number statics and prototype (toFixed, toPrecision, toExponential,
// toLocaleString on top of jsnumber.swift), parseInt, parseFloat, isNaN,
// isFinite, encodeURI(Component), decodeURI(Component), escape, unescape.
// The constructors and Number.prototype.toString/valueOf, Boolean are in
// the base built-ins and are kept.

private func jsDigitValue(_ u: UInt16) -> Int {
    switch u {
    case 0x30...0x39: return Int(u) - 0x30
    case 0x61...0x7A: return Int(u) - 0x61 + 10
    case 0x41...0x5A: return Int(u) - 0x41 + 10
    default: return 99
    }
}

private func jsHexValue(_ u: UInt16) -> Int {
    let d = jsDigitValue(u)
    return d < 16 ? d : -1
}

private let jsHexUpper: [UInt8] = Array("0123456789ABCDEF".utf8)

/// parseInt on already-converted units.
func jsParseIntUnits(_ units: [UInt16], _ radixIn: Int32) -> Double {
    var i = 0
    let n = units.count
    while i < n && jsIsStrWhiteSpace(UInt32(units[i])) { i += 1 }
    var neg = false
    if i < n && (units[i] == 0x2B || units[i] == 0x2D) { neg = units[i] == 0x2D; i += 1 }
    var radix = Int(radixIn)
    var strip = true
    if radix != 0 {
        if radix < 2 || radix > 36 { return .nan }
        if radix != 16 { strip = false }
    } else {
        radix = 10
    }
    if strip && i + 1 < n && units[i] == 0x30 && (units[i + 1] == 0x78 || units[i + 1] == 0x58) {
        i += 2
        radix = 16
    }
    var digits: [UInt8] = []
    while i < n {
        let d = jsDigitValue(units[i])
        if d >= radix { break }
        digits.append(UInt8(d))
        i += 1
    }
    if digits.isEmpty { return .nan }
    let v = jsDigitsToDouble(digits, radix)
    return neg ? -v : v
}

func jsParseFloatUnits(_ units: [UInt16]) -> Double {
    var i = 0
    while i < units.count && jsIsStrWhiteSpace(UInt32(units[i])) { i += 1 }
    if let r = jsParseDecimalPrefix(units, i) { return r.value }
    return .nan
}

// MARK: URI coding

private func jsIsUnreservedMark(_ c: UInt16) -> Bool {
    switch c {
    case 0x2D, 0x5F, 0x2E, 0x21, 0x7E, 0x2A, 0x27, 0x28, 0x29: return true  // - _ . ! ~ * ' ( )
    default: return false
    }
}

private func jsIsAlnum(_ c: UInt16) -> Bool {
    (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
}

private func jsIsURIReserved(_ c: UInt16) -> Bool {
    switch c {
    case 0x3B, 0x2F, 0x3F, 0x3A, 0x40, 0x26, 0x3D, 0x2B, 0x24, 0x2C: return true  // ; / ? : @ & = + $ ,
    default: return false
    }
}

extension JSRealm {
    func jsURIEncode(_ sv: JSValue, component: Bool) throws(JSThrow) -> JSValue {
        let units = heap.stringUnits(sv)
        var out: [UInt8] = []
        out.reserveCapacity(units.count)
        var k = 0
        let n = units.count
        while k < n {
            let c = units[k]
            if jsIsAlnum(c) || jsIsUnreservedMark(c) || (!component && (jsIsURIReserved(c) || c == 0x23)) {
                out.append(UInt8(c))
                k += 1
                continue
            }
            var cp = UInt32(c)
            if c >= 0xDC00 && c <= 0xDFFF { throw throwError(.uriError, "URI malformed") }
            if c >= 0xD800 && c <= 0xDBFF {
                k += 1
                guard k < n, units[k] >= 0xDC00, units[k] <= 0xDFFF else { throw throwError(.uriError, "URI malformed") }
                cp = 0x10000 + ((UInt32(c) - 0xD800) << 10) + (UInt32(units[k]) - 0xDC00)
            }
            var utf8: [UInt8] = []
            jsAppendUTF8(&utf8, cp)
            for b in utf8 {
                out.append(0x25)
                out.append(jsHexUpper[Int(b >> 4)])
                out.append(jsHexUpper[Int(b & 15)])
            }
            k += 1
            if out.count > heap.limits.maxStringLength { throw throwRangeError("Invalid string length") }
        }
        let r = heap.newString(latin1: out)
        try jsCheckAlloc()
        return r
    }

    func jsURIDecode(_ sv: JSValue, component: Bool) throws(JSThrow) -> JSValue {
        let units = heap.stringUnits(sv)
        let n = units.count
        var b = JSStringBuilder()
        var k = 0
        while k < n {
            let c = units[k]
            if c != 0x25 { b.append(unit: c); k += 1; continue }
            let start = k
            guard k + 2 < n, jsHexValue(units[k + 1]) >= 0, jsHexValue(units[k + 2]) >= 0 else {
                throw throwError(.uriError, "URI malformed")
            }
            let byte = UInt32(jsHexValue(units[k + 1]) * 16 + jsHexValue(units[k + 2]))
            k += 2
            if byte & 0x80 == 0 {
                let ch = UInt16(byte)
                if !component && (jsIsURIReserved(ch) || ch == 0x23) {
                    for j in start...k { b.append(unit: units[j]) }
                } else {
                    b.append(unit: ch)
                }
            } else {
                var need = 0
                var cp: UInt32 = 0
                var minCP: UInt32 = 0
                if byte & 0xE0 == 0xC0 { need = 1; cp = byte & 0x1F; minCP = 0x80 }
                else if byte & 0xF0 == 0xE0 { need = 2; cp = byte & 0x0F; minCP = 0x800 }
                else if byte & 0xF8 == 0xF0 { need = 3; cp = byte & 0x07; minCP = 0x10000 }
                else { throw throwError(.uriError, "URI malformed") }
                if k + 3 * need >= n { throw throwError(.uriError, "URI malformed") }
                var j = 0
                while j < need {
                    k += 1
                    guard units[k] == 0x25, jsHexValue(units[k + 1]) >= 0, jsHexValue(units[k + 2]) >= 0 else {
                        throw throwError(.uriError, "URI malformed")
                    }
                    let cb = UInt32(jsHexValue(units[k + 1]) * 16 + jsHexValue(units[k + 2]))
                    if cb & 0xC0 != 0x80 { throw throwError(.uriError, "URI malformed") }
                    cp = (cp << 6) | (cb & 0x3F)
                    k += 2
                    j += 1
                }
                if cp < minCP || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF) {
                    throw throwError(.uriError, "URI malformed")
                }
                b.append(codePoint: cp)
            }
            k += 1
            if !heap.canMakeString(length: b.count) { throw throwRangeError("Invalid string length") }
        }
        let r = heap.newString(b)
        try jsCheckAlloc()
        return r
    }

    /// "1,234.568"-style en-US formatting (up to 3 fraction digits).
    func jsNumberLocale(_ x: Double) -> String {
        if x.isNaN { return "NaN" }
        if x.isInfinite { return x < 0 ? "-\u{221E}" : "\u{221E}" }
        if x.magnitude >= 1e21 { return String(decoding: jsNumberToString(x), as: UTF8.self) }
        var s = jsNumberToFixed(x, 3)
        // Strip trailing zeros of the fraction.
        if let dot = s.firstIndex(of: 0x2E) {
            while let l = s.last, l == 0x30 { s.removeLast() }
            if s.last == 0x2E { s.removeLast() }
            _ = dot
        }
        var neg = false
        if s.first == 0x2D { neg = true; s.removeFirst() }
        var intPart: [UInt8] = []
        var frac: [UInt8] = []
        var inFrac = false
        for c in s {
            if c == 0x2E { inFrac = true; continue }
            if inFrac { frac.append(c) } else { intPart.append(c) }
        }
        var grouped: [UInt8] = []
        for (i, c) in intPart.enumerated() {
            if i > 0 && (intPart.count - i) % 3 == 0 { grouped.append(0x2C) }
            grouped.append(c)
        }
        var out = grouped
        if !frac.isEmpty { out.append(0x2E); out.append(contentsOf: frac) }
        var str = String(decoding: out, as: UTF8.self)
        if neg && !(str == "0") { str = "-" + str }
        return str
    }
}

func jsInstallNumber(_ realm: JSRealm) {
    let heap = realm.heap
    let nc = realm.intrinsic(.numberConstructor)
    let np = realm.intrinsic(.numberPrototype)
    let g = realm.global

    // ---------------------------------------------------------- constants
    realm.defineValue(nc, "EPSILON", .double(2.220446049250313e-16), [])
    realm.defineValue(nc, "MAX_SAFE_INTEGER", .double(9007199254740991), [])
    realm.defineValue(nc, "MIN_SAFE_INTEGER", .double(-9007199254740991), [])
    realm.defineValue(nc, "MAX_VALUE", .double(Double.greatestFiniteMagnitude), [])
    realm.defineValue(nc, "MIN_VALUE", .double(Double.leastNonzeroMagnitude), [])
    realm.defineValue(nc, "NaN", .nan, [])
    realm.defineValue(nc, "NEGATIVE_INFINITY", .double(-Double.infinity), [])
    realm.defineValue(nc, "POSITIVE_INFINITY", .double(Double.infinity), [])

    // ------------------------------------------------------------ globals
    let parseIntFn = realm.defineMethod(g, "parseInt", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let s = try realm.toStringValue(args[0])
        let r = realm.heap.root(s)
        defer { realm.heap.popRoots(to: r.slot) }
        let radix = jsToInt32(try realm.toNumber(args[1]))
        return .number(jsParseIntUnits(realm.heap.stringUnits(s), radix))
    }
    let parseFloatFn = realm.defineMethod(g, "parseFloat", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let s = try realm.toStringValue(args[0])
        return .number(jsParseFloatUnits(realm.heap.stringUnits(s)))
    }
    realm.defineValue(nc, "parseInt", parseIntFn)
    realm.defineValue(nc, "parseFloat", parseFloatFn)
    realm.defineMethod(g, "isNaN", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        .bool(try realm.toNumber(args[0]).isNaN)
    }
    realm.defineMethod(g, "isFinite", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        .bool(try realm.toNumber(args[0]).isFinite)
    }
    realm.defineMethod(nc, "isNaN", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        .bool(args[0].isNumber && args[0].numberValue.isNaN)
    }
    realm.defineMethod(nc, "isFinite", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        .bool(args[0].isNumber && args[0].numberValue.isFinite)
    }
    realm.defineMethod(nc, "isInteger", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let v = args[0]
        guard v.isNumber else { return .false }
        let d = v.numberValue
        return .bool(d.isFinite && jsTrunc(d) == d)
    }
    realm.defineMethod(nc, "isSafeInteger", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let v = args[0]
        guard v.isNumber else { return .false }
        let d = v.numberValue
        return .bool(d.isFinite && jsTrunc(d) == d && d.magnitude <= 9007199254740991)
    }

    // URI functions.
    let uriFns: [(String, Bool, Bool)] = [("encodeURI", true, false), ("encodeURIComponent", true, true),
                                          ("decodeURI", false, false), ("decodeURIComponent", false, true)]
    for (name, enc, comp) in uriFns {
        realm.defineMethod(g, name, length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let s = try realm.toStringValue(args[0])
            let r = realm.heap.root(s)
            defer { realm.heap.popRoots(to: r.slot) }
            return enc ? try realm.jsURIEncode(s, component: comp) : try realm.jsURIDecode(s, component: comp)
        }
    }
    realm.defineMethod(g, "escape", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let s = try realm.toStringValue(args[0])
        let units = realm.heap.stringUnits(s)
        var out: [UInt8] = []
        for u in units {
            if jsIsAlnum(u) || u == 0x40 || u == 0x2A || u == 0x5F || u == 0x2B || u == 0x2D || u == 0x2E || u == 0x2F {
                out.append(UInt8(u))
            } else if u < 256 {
                out.append(0x25)
                out.append(jsHexUpper[Int(u >> 4)])
                out.append(jsHexUpper[Int(u & 15)])
            } else {
                out.append(0x25)
                out.append(0x75)
                out.append(jsHexUpper[Int(u >> 12)])
                out.append(jsHexUpper[Int((u >> 8) & 15)])
                out.append(jsHexUpper[Int((u >> 4) & 15)])
                out.append(jsHexUpper[Int(u & 15)])
            }
            if out.count > realm.heap.limits.maxStringLength { throw realm.throwRangeError("Invalid string length") }
        }
        let r = realm.heap.newString(latin1: out)
        try realm.jsCheckAlloc()
        return r
    }
    realm.defineMethod(g, "unescape", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let s = try realm.toStringValue(args[0])
        let units = realm.heap.stringUnits(s)
        let n = units.count
        var b = JSStringBuilder()
        var k = 0
        while k < n {
            var c = units[k]
            if c == 0x25 {
                if k + 5 < n && units[k + 1] == 0x75 {
                    let a = jsHexValue(units[k + 2]), bb = jsHexValue(units[k + 3])
                    let cc = jsHexValue(units[k + 4]), dd = jsHexValue(units[k + 5])
                    if a >= 0 && bb >= 0 && cc >= 0 && dd >= 0 {
                        c = UInt16(a << 12 | bb << 8 | cc << 4 | dd)
                        k += 5
                    }
                } else if k + 2 < n {
                    let a = jsHexValue(units[k + 1]), bb = jsHexValue(units[k + 2])
                    if a >= 0 && bb >= 0 {
                        c = UInt16(a << 4 | bb)
                        k += 2
                    }
                }
            }
            b.append(unit: c)
            k += 1
        }
        let r = realm.heap.newString(b)
        try realm.jsCheckAlloc()
        return r
    }

    // ------------------------------------------------------ Number.prototype
    realm.defineMethod(np, "toFixed", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let x = try realm.thisNumber(args.this).numberValue
        let f = jsToIntegerOrInfinity(try realm.toNumber(args[0]))
        if !f.isFinite || f < 0 || f > 100 { throw realm.throwRangeError("toFixed() digits argument must be between 0 and 100") }
        if !x.isFinite { return realm.heap.numberToString(x) }
        let r = realm.heap.newString(latin1: jsNumberToFixed(x, Int(f)))
        try realm.jsCheckAlloc()
        return r
    }
    realm.defineMethod(np, "toExponential", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let x = try realm.thisNumber(args.this).numberValue
        let f = jsToIntegerOrInfinity(try realm.toNumber(args[0]))
        if !x.isFinite { return realm.heap.numberToString(x) }
        if !f.isFinite || f < 0 || f > 100 { throw realm.throwRangeError("toExponential() argument must be between 0 and 100") }
        let r = realm.heap.newString(latin1: jsNumberToExponential(x, args[0].isUndefined ? nil : Int(f)))
        try realm.jsCheckAlloc()
        return r
    }
    realm.defineMethod(np, "toPrecision", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let x = try realm.thisNumber(args.this).numberValue
        if args[0].isUndefined { return realm.heap.numberToString(x) }
        let p = jsToIntegerOrInfinity(try realm.toNumber(args[0]))
        if !x.isFinite { return realm.heap.numberToString(x) }
        if !p.isFinite || p < 1 || p > 100 { throw realm.throwRangeError("toPrecision() argument must be between 1 and 100") }
        let r = realm.heap.newString(latin1: jsNumberToPrecision(x, Int(p)))
        try realm.jsCheckAlloc()
        return r
    }
    realm.defineMethod(np, "toLocaleString", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let x = try realm.thisNumber(args.this).numberValue
        return realm.string(realm.jsNumberLocale(x))
    }
    _ = heap
}
