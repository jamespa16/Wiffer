// Host tests for lib/js's runtime data layer: JSValue, JSHeap/GC,
// objects, strings and number conversions (Phase 9B, first half).

private func jsAscii(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }
private func jsBytes(_ s: String) -> [UInt8] { Array(s.utf8) }
private func jsD(_ bits: UInt64) -> Double { Double(bitPattern: bits) }
private func jsNum(_ s: String) -> Double { jsStringToNumber(Array(s.utf8)) }
private func jsU16(_ s: String) -> [UInt16] { JSStringBuilder(s).units }

func jsCoreTests(_ t: Tests) {
    jsValueTests(t)
    jsNumberToStringTests(t)
    jsStringToNumberTests(t)
    jsNumberFormatTests(t)
    jsIntegerTests(t)
    jsStringTests(t)
    jsObjectTests(t)
    jsArrayTests(t)
    jsChainTests(t)
    jsGCTests(t)
    jsStressTests(t)
    jsHeapLimitTests(t)
    jsNumberFuzz(t)
    jsPerfTests(t)
}

// MARK: Values

private func jsValueTests(_ t: Tests) {
    t.section("value")
    t.check(JSValue.number(3.0).isInt32, "3.0 is int32")
    t.check(JSValue.number(-0.0).isDouble, "-0 stays double")
    t.check(JSValue.number(2147483648.0).isDouble, "2^31 is double")
    t.check(JSValue.number(-2147483648.0).isInt32, "-2^31 is int32")
    t.check(JSValue.number(0.5).isDouble, "0.5 double")
    t.equal(JSValue.double(Double(bitPattern: 0xFFF8_1234_0000_0001)).bits, 0x7FF8_0000_0000_0000, "NaN canonical")
    t.check(JSValue.double(-.nan).isNumber, "-NaN is a number")
    t.check(JSValue.double(-.infinity).isDouble && JSValue.double(-.infinity).numberValue == -.infinity, "-inf")
    t.check(JSValue.int32(-7).numberValue == -7, "int32 payload")
    t.check(JSValue.undefined.type == .undefined && JSValue.null.type == .null, "types")
    t.check(JSValue.true.type == .boolean && JSValue.bool(false) == .false, "bools")
    t.check(JSValue.object(5).isObject && JSValue.object(5).handle == 5, "object handle")
    t.check(JSValue.string(9).isString && !JSValue.string(9).isNumber, "string not number")
    t.check(JSValue.symbol(1).type == .symbol && JSValue.bigint(1).type == .bigint, "symbol/bigint")
    t.check(!JSValue.hole.isUndefined && JSValue.hole.isHole, "hole")
    t.check(MemoryLayout<JSValue>.size == 8, "8 bytes")
    t.check(jsSameValueNumber(.nan, .nan) && !jsSameValueNumber(0, -0.0), "SameValue numbers")
    let h = JSHeap()
    t.check(h.sameValue(.number(1.0), .int32(1)), "sameValue int32/double forms")
    t.check(!h.strictEquals(.nan, .nan) && h.sameValueZero(.nan, .nan), "NaN equality")
    t.check(h.strictEquals(.double(0), .double(-0.0)) && !h.sameValue(.double(0), .double(-0.0)), "zeros")
    t.check(h.strictEquals(h.newString("ab"), h.newString("ab")), "strings by content")
    t.equal(h.swiftString(h.typeOf(.null)), "object", "typeof null")
    t.equal(h.swiftString(h.typeOf(.int32(1))), "number", "typeof 1")
    t.equal(h.swiftString(h.typeOf(h.newString("x"))), "string", "typeof str")
    t.check(!h.toBoolean(h.newString("")) && h.toBoolean(h.newString("0")), "ToBoolean strings")
    t.check(!h.toBoolean(.double(.nan)) && !h.toBoolean(.double(-0.0)) && h.toBoolean(.int32(-1)), "ToBoolean numbers")
    t.equal(h.toPrimitiveNumber(h.newString(" 0x10 ")) ?? -1, 16, "ToNumber string")
    t.check(h.toPrimitiveNumber(.undefined)?.isNaN == true && h.toPrimitiveNumber(.null) == 0, "ToNumber undefined/null")
    t.equal(h.swiftString(h.toPrimitiveString(.double(0.1)) ?? .undefined), "0.1", "ToString 0.1")
    t.equal(h.swiftString(h.toPrimitiveString(.true) ?? .undefined), "true", "ToString true")
}

// MARK: Number -> string

private func jsNumberToStringTests(_ t: Tests) {
    t.section("number toString")
    let cases: [(Double, String)] = [
        (0.1 + 0.2, "0.30000000000000004"), (5e-324, "5e-324"), (1e21, "1e+21"), (1e20, "100000000000000000000"),
        (-0.0, "0"), (.nan, "NaN"), (.infinity, "Infinity"), (-.infinity, "-Infinity"), (0.1, "0.1"),
        (123.456, "123.456"), (1e-7, "1e-7"), (0.000001, "0.000001"), (1.5e-6, "0.0000015"),
        (1.7976931348623157e308, "1.7976931348623157e+308"), (9007199254740992, "9007199254740992"),
        (9007199254740993, "9007199254740992"), (2.2250738585072014e-308, "2.2250738585072014e-308"),
        (-1.5, "-1.5"), (1e100, "1e+100"), (123e-20, "1.23e-18"), (4294967295, "4294967295"),
        (1.2e21, "1.2e+21"), (12345678901234567890, "12345678901234567000"), (0.5, "0.5"),
        (2.5e-5, "0.000025"), (100, "100"), (1e15 + 0.3, "1000000000000000.2"), (1 / 3.0, "0.3333333333333333"),
    ]
    for (d, s) in cases { t.equal(jsAscii(jsNumberToString(d)), s, "toString \(s)") }
    var bad = 0
    for (b, s) in jsVecToString where jsAscii(jsNumberToString(jsD(b))) != s {
        bad += 1
        if bad < 5 { t.check(false, "vector toString", "bits \(hex(beBytes(b))) got \(jsAscii(jsNumberToString(jsD(b)))) want \(s)") }
    }
    t.equal(bad, 0, "toString vectors (\(jsVecToString.count))")

    t.section("number radix")
    let radix: [(Double, Int, String)] = [
        (255, 16, "ff"), (-255, 2, "-11111111"), (0.5, 2, "0.1"), (255.5, 16, "ff.8"), (35, 36, "z"),
        (0.1, 2, "0.0001100110011001100110011001100110011001100110011001101"), (-0.0, 16, "0"),
        (.nan, 16, "NaN"), (.infinity, 2, "Infinity"), (1e21, 10, "1e+21"), (8, 8, "10"),
        (0.25, 4, "0.1"), (3.75, 2, "11.11"), (4294967296, 16, "100000000"),
        (1152921504606846976, 2, "1" + String(repeating: "0", count: 60)), (1e300, 36, "")]
    for (d, r, s) in radix where !s.isEmpty {
        t.equal(jsAscii(jsNumberToRadixString(d, r)), s, "\(d) radix \(r)")
    }
    // Round trip of the radix forms for integers and binary fractions.
    var rng = TestRandom(seed: 77)
    var radixBad = 0
    for _ in 0..<2000 {
        let r = 2 + rng.below(35)
        let v = Double(rng.next() >> UInt64(11 + rng.below(40)))
        let s = jsNumberToRadixString(v, r)
        var digits: [UInt8] = []
        for c in s { digits.append(c <= 0x39 ? c - 0x30 : c - 0x61 + 10) }
        if jsDigitsToDouble(digits, r) != v && v < 9007199254740992 { radixBad += 1 }
    }
    t.equal(radixBad, 0, "radix integer round trip")
    t.check(jsNumberToRadixString(1e300, 36).count > 100, "1e300 radix 36 is long")
    t.check(jsNumberToRadixString(5e-324, 2).count > 1000, "5e-324 radix 2 terminates")
}

private func beBytes(_ v: UInt64) -> [UInt8] {
    var o: [UInt8] = []
    for i in 0..<8 { o.append(UInt8(truncatingIfNeeded: v >> UInt64(56 - 8 * i))) }
    return o
}

// MARK: String -> number

private func jsStringToNumberTests(_ t: Tests) {
    t.section("StringToNumber")
    let cases: [(String, Double)] = [
        ("", 0), ("   ", 0), ("  12  ", 12), ("0x1F", 31), ("0X1f", 31), ("0o17", 15), ("0b101", 5),
        ("Infinity", .infinity), ("-Infinity", -.infinity), ("+Infinity", .infinity), (".5", 0.5),
        ("5.", 5), ("00012", 12), ("1e400", .infinity), ("1e-400", 0), ("-1e-400", -0.0),
        ("2.2250738585072011e-308", 2.225073858507201e-308), ("2.2250738585072012e-308", 2.2250738585072014e-308),
        ("9007199254740993", 9007199254740992), ("0x20000000000001", 9007199254740992),
        ("0x20000000000003", 9007199254740996), ("1E3", 1000), ("+1.5e+2", 150), ("-.5e-1", -0.05),
        ("0.1", 0.1), ("0.30000000000000004", 0.30000000000000004), ("4.9e-324", 5e-324), ("2.4e-324", 0),
        ("2.5e-324", 5e-324), ("1.7976931348623157e308", 1.7976931348623157e308),
        ("1.7976931348623158e308", 1.7976931348623157e308), ("1.7976931348623159e308", .infinity),
        ("123456789012345678901234567890", 1.2345678901234568e29), ("0.000001", 0.000001),
        ("\u{A0} 5 \u{FEFF}", 5), ("\u{2028}3\u{3000}", 3), ("\t\n\r\u{0B}\u{0C}7", 7),
        ("0x" + String(repeating: "f", count: 300), .infinity), ("0b" + String(repeating: "1", count: 53), 9007199254740991),
        ("0." + String(repeating: "0", count: 400) + "1e400", 0.1),
        (String(repeating: "1", count: 1000) + "e-999", 1.1111111111111112),
    ]
    for (s, want) in cases {
        let got = jsStringToNumber(jsU16(s))
        t.check(got.bitPattern == want.bitPattern, "StringToNumber \"\(s.utf8.count > 40 ? "<long>" : s)\"",
                "got \(jsAscii(jsNumberToString(got)))")
    }
    for s in ["-0x1", "0x", "infinity", "1e", "1e+", ".", "1_000", "1 2", "0b2", "0o8", "0xg", "e5", "+", "-",
              "Infinityx", "NaN", "1..2", "0x1.5", "++1", "\u{200B}1"] {
        t.check(jsNum(s).isNaN, "NaN for \"\(s)\"")
    }
    t.check(jsNum("-0").bitPattern == (-0.0).bitPattern, "-0 keeps its sign")
    // parseFloat-style prefixes.
    let pf: [(String, Double, Int)] = [("1.5e+x", 1.5, 3), ("12abc", 12, 2), ("-.5.5", -0.5, 3), ("1e5e", 1e5, 3),
                                       ("Infinityx", .infinity, 8)]
    for (s, v, end) in pf {
        let r = jsParseDecimalPrefix(jsBytes(s), 0)
        t.check(r?.value == v && r?.end == end, "prefix \(s)")
    }
    t.check(jsParseDecimalPrefix(jsBytes("x1"), 0) == nil && jsParseDecimalPrefix(jsBytes("-"), 0) == nil, "no prefix")

    var bad = 0
    for (s, b) in jsVecStrtod {
        let got = jsNum(s)
        if got.bitPattern != b {
            bad += 1
            if bad < 5 { t.check(false, "strtod vector", "\(s.utf8.count > 60 ? "<long>" : s): got \(jsAscii(jsNumberToString(got)))") }
        }
    }
    t.equal(bad, 0, "strtod vectors (\(jsVecStrtod.count))")
}

// MARK: toFixed / toExponential / toPrecision

private func jsNumberFormatTests(_ t: Tests) {
    t.section("number format")
    let fixed: [(Double, Int, String)] = [
        (1.005, 2, "1.00"), (0.5, 0, "1"), (2.5, 0, "3"), (-1.5, 0, "-2"), (1e21, 2, "1e+21"), (0, 2, "0.00"),
        (-0.0, 2, "0.00"), (-0.0000001, 2, "-0.00"), (0.1, 20, "0.10000000000000000555"), (123.456, 0, "123"),
        (0.000001, 3, "0.000"), (999.995, 2, "1000.00"), (9.995, 2, "9.99"), (0.95, 1, "0.9"), (99.5, 0, "100"),
        (1.45, 1, "1.4"), (5e-324, 2, "0.00"), (1, 100, "1." + String(repeating: "0", count: 100)),
        (1e20, 2, "100000000000000000000.00"), (.nan, 2, "NaN"),
    ]
    for (x, f, s) in fixed { t.equal(jsAscii(jsNumberToFixed(x, f)), s, "toFixed(\(x), \(f))") }
    let expo: [(Double, Int?, String)] = [
        (123.456, 2, "1.23e+2"), (0, nil, "0e+0"), (0, 2, "0.00e+0"), (123.456, nil, "1.23456e+2"),
        (1e-7, nil, "1e-7"), (9.99, 1, "1.0e+1"), (-5e-324, nil, "-5e-324"), (1.5, 0, "2e+0"),
        (.infinity, 2, "Infinity"),
    ]
    for (x, f, s) in expo { t.equal(jsAscii(jsNumberToExponential(x, f)), s, "toExponential(\(x))") }
    let prec: [(Double, Int, String)] = [
        (123456, 2, "1.2e+5"), (0.00001, 1, "0.00001"), (1e-7, 1, "1e-7"), (123.456, 4, "123.5"),
        (0, 3, "0.00"), (999.9, 3, "1.00e+3"), (0.000123, 2, "0.00012"), (100, 3, "100"), (-1.5, 1, "-2"),
        (1e21, 3, "1.00e+21"),
    ]
    for (x, p, s) in prec { t.equal(jsAscii(jsNumberToPrecision(x, p)), s, "toPrecision(\(x), \(p))") }
    var bad = 0
    for (b, f, p, sf, se, sp) in jsVecFormat {
        let x = jsD(b)
        let gf = jsAscii(jsNumberToFixed(x, f)), ge = jsAscii(jsNumberToExponential(x, f))
        let gp = jsAscii(jsNumberToPrecision(x, p))
        if gf != sf || ge != se || gp != sp {
            bad += 1
            if bad < 5 { t.check(false, "format vector", "\(sf)/\(se)/\(sp) got \(gf)/\(ge)/\(gp)") }
        }
    }
    t.equal(bad, 0, "format vectors (\(jsVecFormat.count))")
}

private func jsIntegerTests(_ t: Tests) {
    t.section("integers")
    let i32: [(Double, Int32)] = [(4294967301, 5), (-1, -1), (2147483648, -2147483648), (1e20, 1661992960),
                                  (.nan, 0), (.infinity, 0), (-0.5, 0), (4294967295.5, -1), (-4294967297, -1),
                                  (1.8e308, 0), (-2147483649, 2147483647)]
    for (d, w) in i32 { t.equal(Int(jsToInt32(d)), Int(w), "ToInt32(\(d))") }
    t.equal(Int(jsToUint32(-1)), 4294967295, "ToUint32(-1)")
    t.equal(Int(jsToUint16(65537)), 1, "ToUint16")
    t.check(jsToIntegerOrInfinity(-0.7).bitPattern == 0 && jsToIntegerOrInfinity(.nan) == 0, "ToIntegerOrInfinity")
    let fm: [(Double, Double, Double)] = [(5.5, 2, 1.5), (-5.5, 2, -1.5), (1e308, 3, 2), (0.3, 0.1, 0.09999999999999998),
                                          (5, .infinity, 5), (5e-324 * 7, 5e-324 * 2, 5e-324),
                                          (1.7976931348623157e308, 1.1e-300, 5.016509347536917e-301)]
    for (a, b, r) in fm { t.check(jsFmod(a, b) == r, "fmod(\(a), \(b))", "got \(jsAscii(jsNumberToString(jsFmod(a, b))))") }
    t.check(jsFmod(1, 0).isNaN && jsFmod(.infinity, 1).isNaN, "fmod NaN cases")
    t.check(jsFmod(-4, 2).bitPattern == (-0.0).bitPattern, "fmod keeps -0")
    t.check(jsArrayIndex(jsBytes("0")) == 0 && jsArrayIndex(jsBytes("4294967294")) == 4294967294, "array index")
    t.check(jsArrayIndex(jsBytes("4294967295")) == nil && jsArrayIndex(jsBytes("01")) == nil &&
            jsArrayIndex(jsBytes("-1")) == nil && jsArrayIndex(jsBytes("")) == nil, "not array index")
}

// MARK: Strings

private func jsStringTests(_ t: Tests) {
    t.section("string")
    let h = JSHeap()
    let a = h.newString("hello")
    t.check(h.isLatin1(a) && h.stringLength(a) == 5, "latin1")
    let e = h.newString("caf\u{E9}")
    t.check(h.isLatin1(e) && h.charCode(e, 3) == 0xE9, "e-acute stays latin1")
    let w = h.newString("a\u{1F600}b")
    t.check(!h.isLatin1(w) && h.stringLength(w) == 4, "emoji is two units")
    t.equal(Int(h.charCode(w, 1)), 0xD83D, "high surrogate")
    t.equal(Int(h.codePoint(w, 1)), 0x1F600, "codePointAt joins")
    t.equal(Int(h.codePoint(w, 2)), 0xDE00, "codePointAt on low half")
    t.equal(h.swiftString(w), "a\u{1F600}b", "UTF-8 round trip")
    let lone = h.newString(utf16: [0x61, 0xD800, 0x62, 0xDC00])
    t.equal(h.stringLength(lone), 4, "lone surrogates kept")
    t.equal(h.swiftString(lone), "a\u{FFFD}b\u{FFFD}", "lone surrogates at the edge")
    let narrow = h.newString(utf16: [0x41, 0xFF])
    t.check(h.isLatin1(narrow) && h.stringsEqual(narrow, h.newString("A\u{FF}")), "utf16 narrows")
    let c = h.concat(a, w)!
    t.check(h.stringLength(c) == 9 && !h.isLatin1(c) && h.swiftString(c) == "helloa\u{1F600}b", "concat wide")
    t.check(h.concat(a, .string(0))! == a, "concat empty")
    let sub = h.substring(c, 6, 8)
    t.check(h.stringUnits(sub) == [0xD83D, 0xDE00], "substring wide")
    t.check(h.isLatin1(h.substring(c, 0, 5)), "substring narrows")
    t.check(h.stringLength(h.substring(c, -5, 100)) == 9, "substring clamps")
    t.equal(h.compareStrings(h.newString("a"), h.newString("b")), -1, "a < b")
    t.equal(h.compareStrings(h.newString("ab"), h.newString("a")), 1, "ab > a")
    t.equal(h.compareStrings(h.newString("\u{FF}"), h.newString("\u{100}")), -1, "cross-width compare")
    t.equal(h.compareStrings(h.newString(utf16: [0xD800]), h.newString(utf16: [0xFF61])), -1, "code unit order, not code point")
    t.check(h.stringsEqual(h.newString(utf16: jsU16("\u{1F600}")), h.newString("\u{1F600}")), "wide equality")
    let bad = h.newString(JSStringBuilder())
    t.check(bad == .string(0), "empty is handle 0")
    var b = JSStringBuilder()
    b.append(utf8: [0x61, 0xC3, 0x28, 0xED, 0xA0, 0x80, 0xF0, 0x9F, 0x98])
    t.equal(b.units.count, 5, "invalid UTF-8 replaced")
    t.equal(h.stringToNumber(h.newString(" 1e3 ")), 1000, "stringToNumber")
    t.equal(h.swiftString(h.numberToString(-1.25)), "-1.25", "numberToString")

    t.section("atoms and keys")
    let x1 = h.atom("foo"), x2 = h.intern(h.newString("foo"))
    t.check(x1 == x2, "atoms unique")
    t.check(h.key("foo") == .atom(x1.handle), "key from atom")
    t.check(h.key("42") == .index(42), "\"42\" is an index key")
    t.check(h.propertyKey(h.newString("42")) == .index(42), "string 42 -> index")
    t.check(h.propertyKey(h.newString("042"))?.isString == true, "042 is a string key")
    t.check(h.propertyKey(h.newString("4294967295"))?.isString == true, "2^32-1 is a string key")
    t.check(h.propertyKey(.int32(7)) == .index(7), "7 -> index")
    t.check(h.propertyKey(.double(4294967294)) == .index(4294967294), "max index")
    t.check(h.propertyKey(.int32(-1)) == h.key("-1"), "-1 -> \"-1\"")
    t.check(h.propertyKey(.double(1.5)) == h.key("1.5"), "1.5 -> \"1.5\"")
    t.check(h.propertyKey(.double(-0.0)) == .index(0), "-0 -> \"0\"")
    t.check(h.propertyKey(.true) == h.key("true") && h.propertyKey(.undefined) == h.key("undefined"), "bool/undefined keys")
    t.check(h.propertyKey(h.newObject(proto: .null)) == nil, "objects need ToPrimitive")
    let sym = h.newSymbol(description: h.newString("s"))
    t.check(h.propertyKey(sym) == .symbol(sym.handle), "symbol key")
    t.equal(h.swiftString(h.symbolDescription(h.symbolsWellKnown.iterator)), "Symbol.iterator", "well-known")
    t.equal(h.swiftString(h.keyValue(.index(12))), "12", "keyValue index")
    t.check(h.key("") == .atom(0), "empty key")

    t.section("string limits")
    var lim = JSLimits.small
    lim.maxStringLength = 10
    let hs = JSHeap(limits: lim)
    let s6 = hs.newString("abcdef")
    t.check(hs.concat(s6, s6) == nil, "concat over limit is nil")
    t.equal(hs.stringLength(hs.newString("0123456789abc")), 10, "constructor cuts to the limit")
    t.check(hs.canMakeString(length: 10) && !hs.canMakeString(length: 11), "canMakeString")
}

// MARK: Objects

private func jsObjectTests(_ t: Tests) {
    t.section("object")
    let h = JSHeap()
    let o = h.newObject(proto: .null)
    let ka = h.key("a"), kb = h.key("b"), kc = h.key("c")
    t.check(h.createDataProperty(o, ka, .int32(1)), "create a")
    t.check(h.getOwnProperty(o, ka) == .data(.int32(1)), "get a")
    t.check(h.defineOwnProperty(o, kb, .data(.int32(2), [.enumerable])), "define b read-only")
    t.check(!h.defineOwnProperty(o, kb, JSPropertyDescriptor(value: .int32(3))), "can't change non-writable")
    t.check(h.defineOwnProperty(o, kb, JSPropertyDescriptor(value: .int32(2))), "same value ok")
    t.check(!h.defineOwnProperty(o, kb, JSPropertyDescriptor(configurable: true)), "can't make configurable")
    t.check(!h.defineOwnProperty(o, kb, JSPropertyDescriptor(enumerable: false)), "can't change enumerable")
    t.check(!h.defineOwnProperty(o, kb, JSPropertyDescriptor(getter: .undefined)), "can't become accessor")
    t.check(h.defineOwnProperty(o, kb, JSPropertyDescriptor(writable: false)), "writable false again ok")
    t.check(h.setProperty(o, kb, .int32(9), receiver: o) == .failed, "set non-writable fails")
    t.check(!h.deleteProperty(o, kb), "delete non-configurable fails")
    // Accessors.
    let getter = h.newObject(proto: .null, flags: [.extensible, .callable])
    t.check(h.defineOwnProperty(o, kc, .accessor(get: getter, set: .undefined, [.configurable, .enumerable])), "accessor")
    let pc = h.getOwnProperty(o, kc)
    t.check(pc?.isAccessor == true && pc?.getter == getter && pc?.setter == .undefined, "accessor fields")
    t.check(h.getProperty(o, kc) == .getter(getter), "get returns the getter")
    t.check(h.setProperty(o, kc, .int32(1), receiver: o) == .failed, "no setter: set fails")
    t.check(h.defineOwnProperty(o, kc, JSPropertyDescriptor(value: .int32(5))), "accessor -> data")
    let pc2 = h.getOwnProperty(o, kc)
    t.check(pc2?.isAccessor == false && pc2?.value == .int32(5) && pc2?.writable == false && pc2?.enumerable == true,
            "converted keeps enumerable/configurable, writable false")
    t.check(h.defineOwnProperty(o, kc, JSPropertyDescriptor(setter: getter)), "data -> accessor")
    t.check(h.getOwnProperty(o, kc)?.setter == getter && h.getOwnProperty(o, kc)?.getter == .undefined, "set only")
    // Generic descriptor on a missing property makes undefined, all false.
    let kd = h.key("d")
    t.check(h.defineOwnProperty(o, kd, JSPropertyDescriptor()) && h.getOwnProperty(o, kd) == .data(.undefined, []), "generic")
    // Extensibility.
    h.preventExtensions(o)
    t.check(!h.createDataProperty(o, h.key("z"), .int32(1)) && !h.isExtensible(o), "not extensible")
    t.check(h.setProperty(o, ka, .int32(10), receiver: o) == .done && h.getProperty(o, ka) == .value(.int32(10)), "existing writable ok")
    // Key order.
    let p = h.newObject(proto: .null)
    let sy = h.newSymbol(description: .undefined)
    _ = h.createDataProperty(p, h.key("z"), .int32(0))
    _ = h.createDataProperty(p, .symbol(sy.handle), .int32(0))
    _ = h.createDataProperty(p, .index(10), .int32(0))
    _ = h.createDataProperty(p, h.key("a"), .int32(0))
    _ = h.createDataProperty(p, .index(2), .int32(0))
    _ = h.createDataProperty(p, .index(100_000), .int32(0))
    _ = h.defineOwnProperty(p, .index(5), .data(.int32(0), [.enumerable]))
    _ = h.createDataProperty(p, h.key("4294967295"), .int32(0))
    let keys = h.ownKeys(p)
    let want: [JSPropertyKey] = [.index(2), .index(5), .index(10), .index(100_000), h.key("z"), h.key("a"),
                                 h.key("4294967295"), .symbol(sy.handle)]
    t.check(keys == want, "OwnPropertyKeys order", "\(keys.count) keys")
    t.check(h.deleteProperty(p, h.key("z")) && !h.hasOwnProperty(p, h.key("z")), "delete")
    _ = h.createDataProperty(p, h.key("z"), .int32(1))
    t.check(h.ownKeys(p).firstIndex(of: h.key("z")) == 6, "re-added key goes last")
    t.check(h.getOwnProperty(p, .index(5))?.writable == false, "sparse index attributes")
    t.check(h.defineOwnProperty(p, .index(5), JSPropertyDescriptor(value: .int32(3))) == false, "sparse non-writable")

    t.section("property storage at scale")
    let big = h.newObject(proto: .null)
    var names: [JSPropertyKey] = []
    for i in 0..<20_000 { names.append(h.key("p\(i)")) }
    var okAdd = true
    for (i, k) in names.enumerated() where !h.createDataProperty(big, k, .int32(Int32(i))) { okAdd = false }
    t.check(okAdd, "20k properties added")
    t.check(h.objects[Int(big.handle)].index.count >= 40_000, "hash index built")
    var okGet = true
    for (i, k) in names.enumerated() where h.getProperty(big, k) != .value(.int32(Int32(i))) { okGet = false }
    t.check(okGet, "20k lookups")
    for i in stride(from: 0, to: 20_000, by: 2) { _ = h.deleteProperty(big, names[i]) }
    var okAfter = true
    for (i, k) in names.enumerated() {
        let has = h.hasOwnProperty(big, k)
        if has != (i % 2 == 1) { okAfter = false }
    }
    t.check(okAfter, "lookups after deleting half (compaction)")
    let order = h.ownKeys(big)
    t.check(order.count == 10_000 && order.first == names[1] && order.last == names[19_999], "order after compaction")
    // Under the threshold: linear, no index.
    let small = h.newObject(proto: .null)
    for i in 0..<JSHeap.propertyHashThreshold { _ = h.createDataProperty(small, h.key("s\(i)"), .int32(0)) }
    t.check(h.objects[Int(small.handle)].index.isEmpty, "no index at the threshold")
    _ = h.createDataProperty(small, h.key("one-more"), .int32(1))
    t.check(!h.objects[Int(small.handle)].index.isEmpty, "index past the threshold")
    t.check(h.getProperty(small, h.key("s3")) == .value(.int32(0)), "lookup through new index")
    // Internal slots and kinds.
    let f = h.newObject(proto: .null, kind: .function, flags: [.extensible, .callable])
    h.setSlots(f, [.int32(1), o])
    t.check(h.slot(f, 1) == o && h.slotCount(f) == 2 && h.isCallable(f) && h.kind(f) == .function, "slots")
    t.equal(h.swiftString(h.typeOf(f)), "function", "typeof function")
    h.setInternalInt(f, 99)
    t.check(h.internalInt(f) == 99 && h.slot(f, 5) == .undefined, "internalInt, slot out of range")
    // The dead sentinel refuses writes.
    t.check(!h.createDataProperty(.object(0), ka, .int32(1)) && h.getOwnProperty(.object(0), ka) == nil, "sentinel")
    // String wrapper.
    let sw = h.newStringObject(proto: .null, string: h.newString("h\u{100}"))
    t.check(h.getOwnProperty(sw, .index(0)) == .data(h.unitStrings[0x68], [.enumerable]), "wrapper index")
    t.check(h.swiftString(h.getOwnProperty(sw, .index(1))?.value ?? .undefined) == "\u{100}", "wrapper wide index")
    t.check(h.getOwnProperty(sw, h.names.length) == .data(.int32(2), []), "wrapper length")
    t.check(!h.createDataProperty(sw, .index(0), .int32(1)) && !h.deleteProperty(sw, .index(1)), "wrapper read-only")
    _ = h.createDataProperty(sw, .index(5), .int32(1))
    t.check(h.ownKeys(sw) == [.index(0), .index(1), .index(5), h.names.length], "wrapper keys")
}

private func jsArrayTests(_ t: Tests) {
    t.section("array")
    let h = JSHeap()
    let a = h.newArray(proto: .null, elements: [.int32(1), .hole, .int32(3)])
    t.equal(Int(h.arrayLength(a)), 3, "length")
    t.check(h.getOwnProperty(a, .index(1)) == nil && h.getProperty(a, .index(2)) == .value(.int32(3)), "hole")
    t.check(h.getOwnProperty(a, h.names.length) == .data(.int32(3), [.writable]), "length property")
    t.check(h.createDataProperty(a, .index(3), .int32(4)) && h.arrayLength(a) == 4, "append grows length")
    t.check(h.createDataProperty(a, .index(1_000_000), .int32(5)) && h.arrayLength(a) == 1_000_001, "far index")
    t.check(h.objects[Int(a.handle)].elements.count == 4 && h.objects[Int(a.handle)].sparse.count == 1, "far index is sparse")
    t.check(h.ownKeys(a) == [.index(0), .index(2), .index(3), .index(1_000_000), h.names.length], "array keys")
    t.check(h.setArrayLength(a, 2) && h.arrayLength(a) == 2 && h.getOwnProperty(a, .index(3)) == nil &&
            h.getOwnProperty(a, .index(1_000_000)) == nil, "truncate")
    _ = h.defineOwnProperty(a, .index(5), .data(.int32(6), [.writable, .enumerable]))
    t.check(h.arrayLength(a) == 6, "non-configurable index")
    t.check(!h.setArrayLength(a, 1) && h.arrayLength(a) == 6 && h.getOwnProperty(a, .index(1)) == nil,
            "truncation stops at non-configurable")
    t.check(h.getOwnProperty(a, .index(0)) == .data(.int32(1)), "kept element below")
    t.check(h.defineOwnProperty(a, h.names.length, JSPropertyDescriptor(writable: false)), "freeze length")
    t.check(!h.createDataProperty(a, .index(6), .int32(0)), "no growth past read-only length")
    t.check(h.setProperty(a, .index(0), .int32(9), receiver: a) == .done, "write below length ok")
    t.check(!h.defineOwnProperty(a, h.names.length, JSPropertyDescriptor(value: .int32(10))), "length read-only")
    t.check(!h.defineOwnProperty(a, h.names.length, JSPropertyDescriptor(enumerable: true)), "length not enumerable")
    t.check(!h.defineOwnProperty(a, h.names.length, JSPropertyDescriptor(value: .double(1.5))), "invalid length")
    t.check(jsArrayLength(.double(4294967295)) == 4294967295 && jsArrayLength(.int32(-1)) == nil, "jsArrayLength")
    t.check(!h.deleteProperty(a, h.names.length), "length not deletable")
    // Dense growth by appending stays dense.
    let d = h.newArray(proto: .null)
    for i in 0..<10_000 { _ = h.createDataProperty(d, .index(UInt32(i)), .int32(Int32(i))) }
    t.check(h.objects[Int(d.handle)].elements.count == 10_000 && h.objects[Int(d.handle)].sparse.isEmpty, "dense appends")
    t.check(h.getProperty(d, .index(9_999)) == .value(.int32(9_999)), "dense read")
    // length grows via a define with value.
    t.check(h.setArrayLength(d, 20_000) && h.arrayLength(d) == 20_000 && h.getOwnProperty(d, .index(15_000)) == nil, "grow length")
    t.check(h.setArrayLength(d, 0) && h.ownKeys(d) == [h.names.length], "clear")
    // Ordinary object with index keys and an accessor element.
    let o = h.newObject(proto: .null)
    _ = h.defineOwnProperty(o, .index(1), .accessor(get: .undefined, set: .undefined, [.configurable]))
    t.check(h.getOwnProperty(o, .index(1))?.isAccessor == true, "accessor index")
    t.check(h.getProperty(o, .index(1)) == .value(.undefined), "getter undefined reads undefined")
}

private func jsChainTests(_ t: Tests) {
    t.section("prototype chain")
    let h = JSHeap()
    let proto = h.newObject(proto: .null)
    let o = h.newObject(proto: proto)
    let kx = h.key("x"), ky = h.key("y"), kz = h.key("z")
    _ = h.createDataProperty(proto, kx, .int32(1))
    t.check(h.getProperty(o, kx) == .value(.int32(1)) && h.hasProperty(o, kx) && !h.hasOwnProperty(o, kx), "inherited")
    t.check(h.setProperty(o, kx, .int32(2), receiver: o) == .done, "set shadows")
    t.check(h.getOwnProperty(o, kx) == .data(.int32(2)) && h.getProperty(proto, kx) == .value(.int32(1)), "own copy made")
    _ = h.defineOwnProperty(proto, ky, .data(.int32(1), []))
    t.check(h.setProperty(o, ky, .int32(2), receiver: o) == .failed && !h.hasOwnProperty(o, ky), "inherited read-only blocks")
    let setter = h.newObject(proto: .null, flags: [.extensible, .callable])
    _ = h.defineOwnProperty(proto, kz, .accessor(get: .undefined, set: setter))
    t.check(h.setProperty(o, kz, .int32(1), receiver: o) == .setter(setter), "inherited setter")
    t.check(h.getProperty(o, h.key("missing")) == .value(.undefined), "missing")
    t.check(h.setProperty(o, kx, .int32(3), receiver: .int32(1)) == .failed, "primitive receiver")
    t.check(!h.setPrototypeOf(proto, o), "cycle refused")
    t.check(h.setPrototypeOf(o, .null) && h.getPrototypeOf(o) == .null, "proto null")
    h.preventExtensions(o)
    t.check(!h.setPrototypeOf(o, proto) && h.setPrototypeOf(o, .null), "non-extensible proto")
    // A long chain is walked iteratively.
    var cur = h.newObject(proto: .null)
    _ = h.createDataProperty(cur, kx, .int32(42))
    for _ in 0..<5_000 { cur = h.newObject(proto: cur) }
    t.check(h.getProperty(cur, kx) == .value(.int32(42)), "5000-deep chain")
}

// MARK: GC

private func jsGCTests(_ t: Tests) {
    t.section("gc")
    let h = JSHeap()
    let base = h.objectCount
    // A cycle with nothing pointing at it.
    var a = h.newObject(proto: .null)
    var b = h.newObject(proto: a)
    _ = h.createDataProperty(a, h.key("b"), b)
    _ = h.createDataProperty(b, h.key("a"), a)
    a = .undefined; b = .undefined
    t.equal(h.objectCount, base + 2, "two objects")
    h.collectGarbage()
    t.equal(h.objectCount, base, "cycle collected")
    // Rooted values survive, with their children.
    let r = h.root(h.newObject(proto: .null))
    let child = h.newObject(proto: .null)
    _ = h.createDataProperty(h[r], h.key("child"), child)
    _ = h.createDataProperty(child, h.key("s"), h.newString("survivor string"))
    let pers = h.retain(h.newArray(proto: .null, elements: [h.newString("in array")]))
    var providerValues: [JSValue] = [h.newObject(proto: .null)]
    let pid = h.addRootProvider { heap in for v in providerValues { heap.markValue(v) } }
    let garbage = h.newObject(proto: .null)
    _ = h.createDataProperty(garbage, h.key("t"), h.newString("temporary"))
    h.collectGarbage()
    t.equal(h.objectCount, base + 4, "rooted survive, garbage freed")
    if case .value(let c) = h.getProperty(h[r], h.key("child")), case .value(let s) = h.getProperty(c, h.key("s")) {
        t.equal(h.swiftString(s), "survivor string", "child data intact")
    } else { t.check(false, "child reachable") }
    if case .value(let s) = h.getProperty(h[pers], .index(0)) { t.equal(h.swiftString(s), "in array", "persistent") }
    // Free cells are reused.
    let before = h.objects.count
    _ = h.newObject(proto: .null)
    t.equal(h.objects.count, before, "free list reuse")
    providerValues = []
    h.removeRootProvider(pid)
    h.release(pers)
    h.popRoots(to: r.slot)
    h.collectGarbage()
    t.equal(h.objectCount, base, "everything unrooted is gone")
    // Scopes.
    let depth = h.rootDepth
    let kept: JSValue = h.withRootScope {
        let x = h.root(h.newObject(proto: .null))
        _ = h.root(h.newString("y"))
        h.collectGarbage()
        return h[x]
    }
    t.check(h.rootDepth == depth && h.kind(kept) == .ordinary, "root scope pops; value lived through GC in scope")
    h.collectGarbage()
    t.check(h.kind(kept) == .free, "scope root released")
    // Atoms die unless pinned; names survive.
    let atomsBefore = h.atomCount
    for i in 0..<100 { _ = h.atom("tmp-atom-\(i)") }
    t.equal(h.atomCount, atomsBefore + 100, "atoms made")
    h.collectGarbage()
    t.equal(h.atomCount, atomsBefore, "unreferenced atoms collected")
    t.check(h.key("length") == h.names.length, "pinned names stay unique")
    let keyHolder = h.retain(h.newObject(proto: .null))
    _ = h.createDataProperty(h[keyHolder], h.key("keyed-by-atom"), .int32(1))
    h.collectGarbage()
    t.check(h.getProperty(h[keyHolder], h.key("keyed-by-atom")) == .value(.int32(1)), "atoms used as keys survive")
    // Symbols: description strings traced.
    let sym = h.retain(h.newSymbol(description: h.newString("desc")))
    h.collectGarbage()
    t.equal(h.swiftString(h.symbolDescription(h[sym])), "desc", "symbol description kept")
    // Allocation protects its arguments.
    h.gcEveryAllocation = true
    let p = h.newObject(proto: h.newObject(proto: .null))
    let pp = h.getPrototypeOf(p)
    _ = h.root(p)
    _ = h.newObject(proto: .null)
    t.check(h.kind(pp) == .ordinary, "proto argument protected")
    let arr = h.newArray(proto: .null, elements: [h.newString("e0")])
    _ = h.root(arr)
    if case .value(let e0) = h.getProperty(arr, .index(0)) {
        _ = h.newObject(proto: .null)
        t.equal(h.swiftString(e0), "e0", "newArray protected its elements")
    }
    h.gcEveryAllocation = false
    // Ephemerons: value kept only while the key is live.
    let wm = h.retain(h.newObject(proto: .null, kind: .weakMap))
    var table: [(key: JSValue, value: JSValue)] = []
    let liveKey = h.retain(h.newObject(proto: .null))
    table.append((h[liveKey], h.newString("live value")))
    let deadKeyValue = h.newObject(proto: .null)
    table.append((h.newObject(proto: .null), deadKeyValue))
    // A chain: key2's value is key3, key3's value a string; key2 is live.
    let key3 = h.newObject(proto: .null)
    table.append((h[liveKey], key3))
    table.append((key3, h.newString("via chain")))
    _ = wm
    let wid = h.addWeakProcessor { heap, phase in
        var marked = false
        switch phase {
        case .ephemerons:
            for e in table where heap.isLive(e.key) && !heap.isLive(e.value) { heap.markValue(e.value); marked = true }
        case .clearDead:
            table.removeAll { !heap.isLive($0.key) }
        }
        return marked
    }
    h.collectGarbage()
    t.equal(table.count, 3, "dead key's entry removed")
    t.check(h.kind(deadKeyValue) == .free, "dead key's value collected")
    t.check(table.count == 3 && h.swiftString(table[2].value) == "via chain", "ephemeron chain kept")
    h.removeWeakProcessor(wid)
    // Finalizers for host objects.
    var finalized: [Int64] = []
    h.finalizer = { _, n in finalized.append(n) }
    let host = h.newObject(proto: .null, kind: .host, flags: [.extensible, .hasFinalizer])
    h.setInternalInt(host, 1234)
    h.collectGarbage()
    t.check(finalized == [1234], "host finalizer ran")
    t.check(h.gcCount > 5, "gc count")
}

private func jsStressTests(_ t: Tests) {
    t.section("gc stress")
    // A small workload under gcEveryAllocation: anything not rooted
    // correctly would be freed and reused, and the checks below would see
    // other objects' data.
    let h = JSHeap()
    h.gcEveryAllocation = true
    let list = h.retain(h.newArray(proto: .null))
    let kv = h.key("v"), kn = h.key("next")
    var head = h.root(JSValue.null)
    for i in 0..<300 {
        let node = h.root(h.newObject(proto: .null))
        _ = h.createDataProperty(h[node], kv, h.numberToString(Double(i)))
        _ = h.createDataProperty(h[node], kn, h[head])
        h[head] = h[node]
        let prefix = h.root(h.newString("item "))
        let s = h.concat(h[prefix], h.numberToString(Double(i)))!
        _ = h.createDataProperty(h[list], .index(UInt32(i)), s)
        h.popRoots(to: node.slot)
        _ = h.newString("garbage \(i)")
    }
    var ok = true
    var cur = h[head]
    var i = 299
    while cur.isObject {
        if case .value(let v) = h.getProperty(cur, kv), h.swiftString(v) == "\(i)" {} else { ok = false; break }
        if case .value(let s) = h.getProperty(h[list], .index(UInt32(i))), h.swiftString(s) == "item \(i)" {} else { ok = false; break }
        guard case .value(let n) = h.getProperty(cur, kn) else { ok = false; break }
        cur = n
        i -= 1
    }
    t.check(ok && i == -1, "linked list intact under gcEveryAllocation", "stopped at \(i)")
    t.check(h.gcCount > 1000, "collected at every allocation")
    h.gcEveryAllocation = false
}

private func jsHeapLimitTests(_ t: Tests) {
    t.section("heap limit")
    var lim = JSLimits.small
    lim.heapBytes = 2 << 20
    let h = JSHeap(limits: lim)
    let keep = h.retain(h.newArray(proto: .null))
    var n: UInt32 = 0
    while h.termination == nil && n < 1_000_000 {
        let o = h.newObject(proto: .null)
        _ = h.createDataProperty(h[keep], .index(n), o)
        n += 1
    }
    t.check(h.termination == .heapLimit, "terminated at the cap", "after \(n)")
    t.check(h.newObject(proto: .null) == .object(0) && h.newString("x") == .string(0), "sentinels while terminating")
    t.check(!h.createDataProperty(h[keep], h.key("more"), .int32(1)), "growth refused")
    t.check(h.liveBytes < 4 << 20, "memory stayed bounded", "\(h.liveBytes)")
    // Growth alone (no allocation) still hits the cap.
    let h2 = JSHeap(limits: lim)
    let big = h2[h2.retain(h2.newArray(proto: .null))]
    var ok = true
    var i: UInt32 = 0
    while h2.termination == nil && i < 10_000_000 {
        if !h2.createDataProperty(big, .index(i), .int32(1)) { ok = false }
        if i % 1000 == 0 { h2.safePoint() }
        i += 1
    }
    t.check(h2.termination == .heapLimit && ok, "element growth terminates at a safe point", "\(i)")
    t.check(!h2.createDataProperty(big, .index(i), .int32(1)), "stores fail once terminated")
    // Garbage does not count: a loop of temporaries never terminates.
    let h3 = JSHeap(limits: lim)
    for j in 0..<200_000 { _ = h3.newString("temporary string number \(j)") }
    t.check(h3.termination == nil && h3.gcCount > 0, "garbage is collected, not terminated")
    h.clearTermination()
    t.check(h.termination == nil, "clearTermination")
}

// MARK: Fuzz

private func jsNumberFuzz(_ t: Tests) {
    t.section("number fuzz")
    var rng = TestRandom(seed: 0x9b)
    var rtBad = 0
    for k in 0..<200_000 {
        var d = Double(bitPattern: rng.next())
        if k % 4 == 1 { d = Double(rng.next() % 1_000_000) / Double(1 + rng.below(100_000)) }
        if k % 4 == 2 { d = Double(bitPattern: rng.next() >> 12) }      // subnormal
        if !d.isFinite { continue }
        let s = jsNumberToString(d)
        if jsStringToNumber(s).bitPattern != (d == 0 ? 0 : d.bitPattern) { rtBad += 1 }
    }
    t.equal(rtBad, 0, "200k toString -> StringToNumber round trips")
    // Shortness: dropping a digit must not round-trip (checked on a sample).
    var longBad = 0
    for _ in 0..<20_000 {
        let d = Double(bitPattern: rng.next() & 0x7FEF_FFFF_FFFF_FFFF)
        if d == 0 || !d.isFinite { continue }
        let (digits, e) = jsShortestDigits(d)
        if digits >= 10 {
            let shorter = (digits + 5) / 10
            var ds: [UInt8] = []
            var x = shorter
            while x > 0 { ds.insert(UInt8(x % 10), at: 0); x /= 10 }
            if jsDecimalToDouble(ds, e + 1) == d { longBad += 1 }
            let down = digits / 10
            ds = []; x = down
            while x > 0 { ds.insert(UInt8(x % 10), at: 0); x /= 10 }
            if !ds.isEmpty && jsDecimalToDouble(ds, e + 1) == d { longBad += 1 }
        }
    }
    t.equal(longBad, 0, "shortest: one digit fewer never round-trips")
    // The exact path agrees with the fast path from a wrong guess.
    var slowBad = 0
    for _ in 0..<3_000 {
        var ds: [UInt8] = []
        for _ in 0..<(1 + rng.below(30)) { ds.append(UInt8(rng.below(10))) }
        if ds[0] == 0 { ds[0] = 1 }
        let e = rng.below(640) - 330
        let fast = jsDecimalToDouble(ds, e)
        if !fast.isFinite || fast == 0 { continue }
        let off = Double(bitPattern: fast.bitPattern &+ (rng.below(2) == 0 ? 1 : UInt64.max))
        if jsDecimalSlow(ds, e, false, off) != fast { slowBad += 1 }
    }
    t.equal(slowBad, 0, "big-integer path agrees with Eisel-Lemire")
    // Hostile strings never trap.
    let seeds: [[UInt8]] = [jsBytes("  -12.5e+3 "), jsBytes("0x1fFf"), jsBytes("Infinity"), jsBytes(".5e-400"),
                            jsBytes("0b1010"), jsBytes("0o777"), jsBytes(String(repeating: "9", count: 900) + ".9e-999")]
    t.fuzz("StringToNumber", seeds: seeds, iterations: 30_000) { bytes in
        let v = jsStringToNumber(bytes)
        _ = jsParseDecimalPrefix(bytes, 0)
        if v.isFinite { _ = jsNumberToString(v); _ = jsNumberToFixed(v, Int(bytes.first ?? 0) % 101) }
        _ = jsNumberToPrecision(v, Int(bytes.last ?? 1) % 101)
        _ = jsNumberToRadixString(v, 2 + Int(bytes.count % 35))
    }
    let h = JSHeap()
    t.fuzz("string keys", seeds: seeds, iterations: 5_000) { bytes in
        let s = h.newString(latin1: bytes)
        if let k = h.propertyKey(s) { _ = h.keyValue(k) }
        _ = h.stringToNumber(s)
    }
}

// MARK: Performance

private func jsPerfTests(_ t: Tests) {
    t.section("perf")
    let h = JSHeap()
    let kx = h.key("x")
    // 1M dead objects, one collection.
    h.gcThreshold = Int.max
    let d0 = hostMillis()
    for _ in 0..<1_000_000 { _ = h.createDataProperty(h.newObject(proto: .null), kx, .int32(1)) }
    let deadAlloc = hostMillis() - d0
    let d1 = hostMillis()
    h.collectGarbage()
    let deadGC = hostMillis() - d1
    print("js perf: 1M objects alloc+set with no GC \(deadAlloc) ms, then one GC sweeping all 1M \(deadGC) ms; cell \(MemoryLayout<JSObjectCell>.stride) bytes")
    let start = hostMillis()
    for i in 0..<1_000_000 {
        let o = h.newObject(proto: .null)
        _ = h.createDataProperty(o, kx, .int32(Int32(truncatingIfNeeded: i)))
    }
    let allocMs = hostMillis() - start
    let gcStart = hostMillis()
    h.collectGarbage()
    let gcMs = hostMillis() - gcStart
    // 1M live objects: mark and sweep with everything reachable.
    let keep = h.retain(h.newArray(proto: .null))
    for i in 0..<1_000_000 {
        let o = h.newObject(proto: .null)
        _ = h.createDataProperty(o, kx, .int32(1))
        _ = h.createDataProperty(h[keep], .index(UInt32(i)), o)
    }
    let liveStart = hostMillis()
    h.collectGarbage()
    let liveMs = hostMillis() - liveStart
    print("js perf: 1M objects alloc+set \(allocMs) ms (\(h.gcCount) GCs incl.), full GC of garbage \(gcMs) ms, full GC with 1M live \(liveMs) ms, live \(h.liveBytes >> 20) MiB")
    t.check(h.objectCount > 1_000_000, "1M live objects survive")
    let s0 = hostMillis()
    var acc = 0.0
    for i in 0..<200_000 { acc += jsStringToNumber(jsNumberToString(Double(i) * 1.1)) }
    print("js perf: 200k number toString+parse \(hostMillis() - s0) ms (\(acc > 0))")
}
