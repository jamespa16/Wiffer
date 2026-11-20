// Intl.NumberFormat and Intl.PluralRules (en-US), plus the Number and BigInt
// toLocaleString routes. See jsintl.swift for the overall design.
//
// Numbers are formatted from their shortest decimal digits (what ICU does:
// 1.005 with two fraction digits gives "1.01"), rounded half away from zero
// ("halfExpand"). BigInts use their exact digits.
//
// Supported: style decimal / percent / currency (symbols for USD EUR GBP
// JPY CNY INR KRW CAD AUD MXN BRL, code otherwise; currencyDisplay symbol /
// narrowSymbol / code / name; currencySign accounting) / unit (a table of
// common units, short / narrow / long), minimumIntegerDigits, fraction and
// significant digit options, useGrouping (true / false / "always" / "auto" /
// "min2"), notation standard / scientific / engineering / compact (short and
// long), signDisplay, format (bound getter), formatToParts, formatRange,
// resolvedOptions.

/// Decimal digits of a non-negative value: digits[i] sits at position
/// exp - i (so 123.4 is [1,2,3,4] with exp 2). Zero has no digits.
struct JSIntlDecimal {
    var digits: [UInt8] = []
    var exp = 0

    var isZero: Bool { digits.isEmpty }

    init() {}
    init(double m: Double) {
        if m == 0 || !m.isFinite { return }
        let (d, e10) = jsShortestDigits(m)
        var ds: [UInt8] = []
        var v = d
        while v > 0 { ds.append(UInt8(v % 10)); v /= 10 }
        ds.reverse()
        digits = ds
        exp = ds.count - 1 + e10
        trimZeros()
    }
    init(asciiDigits a: [UInt8]) {
        var ds = a.map { $0 &- 0x30 }
        var lead = 0
        while lead < ds.count && ds[lead] == 0 { lead += 1 }
        ds.removeFirst(lead)
        digits = ds
        exp = ds.count - 1
        trimZeros()
    }

    mutating func trimZeros() {
        while let l = digits.last, l == 0 { digits.removeLast() }
        if digits.isEmpty { exp = 0 }
    }

    /// Keep the digits at positions >= lastKept; round half away from zero.
    mutating func round(toPosition lastKept: Int) {
        if digits.isEmpty { return }
        let k = exp - lastKept + 1
        if k >= digits.count { return }
        if k < 0 { digits = []; exp = 0; return }
        if k == 0 {
            if digits[0] >= 5 { digits = [1]; exp = lastKept } else { digits = []; exp = 0 }
            return
        }
        let up = digits[k] >= 5
        digits.removeSubrange(k...)
        if up {
            var i = k - 1
            while i >= 0 && digits[i] == 9 { digits[i] = 0; i -= 1 }
            if i >= 0 { digits[i] += 1 } else {
                digits.insert(1, at: 0)
                exp += 1
            }
        }
        trimZeros()
    }

    /// Multiply by 10^n.
    mutating func shift(_ n: Int) { if !digits.isEmpty { exp += n } }
}

struct JSIntlNumberOptions {
    var style = 0               // 0 decimal, 1 percent, 2 currency, 3 unit
    var currency = ""
    var currencyDisplay = 0     // 0 symbol, 1 narrowSymbol, 2 code, 3 name
    var accounting = false
    var unit = ""
    var unitDisplay = 0         // 0 short, 1 narrow, 2 long
    var minInt = 1
    var minFrac = 0
    var maxFrac = 3
    var minSig = 0
    var maxSig = 0              // 0 = fraction digits
    var compactRounding = false
    var grouping = 1            // 0 false, 1 auto, 2 always, 3 min2
    var notation = 0            // 0 standard, 1 scientific, 2 engineering, 3 compact
    var compactLong = false
    var signDisplay = 0         // 0 auto, 1 never, 2 always, 3 exceptZero, 4 negative
    var locale = "en-US"

    init() {}
    init(resolved o: JSValue, heap: JSHeap) {
        locale = heap.intlRawString(o, "locale", "en-US")
        switch heap.intlRawString(o, "style") {
        case "percent": style = 1
        case "currency": style = 2
        case "unit": style = 3
        default: style = 0
        }
        currency = heap.intlRawString(o, "currency")
        switch heap.intlRawString(o, "currencyDisplay") {
        case "narrowSymbol": currencyDisplay = 1
        case "code": currencyDisplay = 2
        case "name": currencyDisplay = 3
        default: currencyDisplay = 0
        }
        accounting = heap.intlRawString(o, "currencySign") == "accounting"
        unit = heap.intlRawString(o, "unit")
        switch heap.intlRawString(o, "unitDisplay") {
        case "narrow": unitDisplay = 1
        case "long": unitDisplay = 2
        default: unitDisplay = 0
        }
        minInt = heap.intlRawInt(o, "minimumIntegerDigits", 1)
        minFrac = heap.intlRawInt(o, "minimumFractionDigits", 0)
        maxFrac = heap.intlRawInt(o, "maximumFractionDigits", 3)
        minSig = heap.intlRawInt(o, "minimumSignificantDigits", 0)
        maxSig = heap.intlRawInt(o, "maximumSignificantDigits", 0)
        compactRounding = heap.intlRawString(o, "roundingPriority") == "morePrecision"
        let g = heap.intlRaw(o, "useGrouping")
        if g.isString {
            switch heap.swiftString(g) {
            case "always": grouping = 2
            case "min2": grouping = 3
            default: grouping = 1
            }
        } else if g.isBool { grouping = g.boolValue ? 1 : 0 }
        switch heap.intlRawString(o, "notation") {
        case "scientific": notation = 1
        case "engineering": notation = 2
        case "compact": notation = 3
        default: notation = 0
        }
        compactLong = heap.intlRawString(o, "compactDisplay") == "long"
        switch heap.intlRawString(o, "signDisplay") {
        case "never": signDisplay = 1
        case "always": signDisplay = 2
        case "exceptZero": signDisplay = 3
        case "negative": signDisplay = 4
        default: signDisplay = 0
        }
    }
}

// MARK: Currency and unit data

func jsIntlCurrencyDigits(_ c: String) -> Int {
    switch c {
    case "JPY", "KRW", "VND", "CLP", "ISK", "UGX", "XAF", "XOF", "PYG", "RWF": return 0
    case "BHD", "KWD", "OMR", "JOD", "TND": return 3
    default: return 2
    }
}

func jsIntlCurrencySymbol(_ c: String, narrow: Bool) -> String? {
    switch c {
    case "USD": return "$"
    case "EUR": return "\u{20AC}"
    case "GBP": return "\u{00A3}"
    case "JPY": return "\u{00A5}"
    case "INR": return "\u{20B9}"
    case "KRW": return "\u{20A9}"
    case "CNY": return narrow ? "\u{00A5}" : "CN\u{00A5}"
    case "CAD": return narrow ? "$" : "CA$"
    case "AUD": return narrow ? "$" : "A$"
    case "MXN": return narrow ? "$" : "MX$"
    case "BRL": return "R$"
    case "NZD": return narrow ? "$" : "NZ$"
    case "HKD": return narrow ? "$" : "HK$"
    case "ILS": return "\u{20AA}"
    case "VND": return "\u{20AB}"
    case "TWD": return narrow ? "$" : "NT$"
    case "PHP": return "\u{20B1}"
    default: return nil
    }
}

func jsIntlCurrencyName(_ c: String, plural: Bool) -> String {
    switch c {
    case "USD": return plural ? "US dollars" : "US dollar"
    case "EUR": return plural ? "euros" : "euro"
    case "GBP": return plural ? "British pounds" : "British pound"
    case "JPY": return "Japanese yen"
    case "CNY": return "Chinese yuan"
    case "INR": return plural ? "Indian rupees" : "Indian rupee"
    case "CAD": return plural ? "Canadian dollars" : "Canadian dollar"
    case "AUD": return plural ? "Australian dollars" : "Australian dollar"
    case "CHF": return plural ? "Swiss francs" : "Swiss franc"
    case "MXN": return plural ? "Mexican pesos" : "Mexican peso"
    case "BRL": return plural ? "Brazilian reals" : "Brazilian real"
    case "KRW": return "South Korean won"
    default: return c
    }
}

/// (short, narrow, long singular, long plural) for a sanctioned simple unit.
func jsIntlSimpleUnit(_ u: String) -> (String, String, String, String)? {
    switch u {
    case "acre": return ("ac", "ac", "acre", "acres")
    case "bit": return ("bit", "bit", "bit", "bits")
    case "byte": return ("byte", "B", "byte", "bytes")
    case "celsius": return ("\u{00B0}C", "\u{00B0}C", "degree Celsius", "degrees Celsius")
    case "centimeter": return ("cm", "cm", "centimeter", "centimeters")
    case "day": return ("day", "d", "day", "days")
    case "degree": return ("deg", "\u{00B0}", "degree", "degrees")
    case "fahrenheit": return ("\u{00B0}F", "\u{00B0}", "degree Fahrenheit", "degrees Fahrenheit")
    case "fluid-ounce": return ("fl oz", "fl oz", "fluid ounce", "fluid ounces")
    case "foot": return ("ft", "\u{2032}", "foot", "feet")
    case "gallon": return ("gal", "gal", "gallon", "gallons")
    case "gigabit": return ("Gb", "Gb", "gigabit", "gigabits")
    case "gigabyte": return ("GB", "GB", "gigabyte", "gigabytes")
    case "gram": return ("g", "g", "gram", "grams")
    case "hectare": return ("ha", "ha", "hectare", "hectares")
    case "hour": return ("hr", "h", "hour", "hours")
    case "inch": return ("in", "\u{2033}", "inch", "inches")
    case "kilobit": return ("kb", "kb", "kilobit", "kilobits")
    case "kilobyte": return ("kB", "kB", "kilobyte", "kilobytes")
    case "kilogram": return ("kg", "kg", "kilogram", "kilograms")
    case "kilometer": return ("km", "km", "kilometer", "kilometers")
    case "liter": return ("L", "L", "liter", "liters")
    case "megabit": return ("Mb", "Mb", "megabit", "megabits")
    case "megabyte": return ("MB", "MB", "megabyte", "megabytes")
    case "meter": return ("m", "m", "meter", "meters")
    case "microsecond": return ("\u{03BC}s", "\u{03BC}s", "microsecond", "microseconds")
    case "mile": return ("mi", "mi", "mile", "miles")
    case "mile-scandinavian": return ("smi", "smi", "mile-scandinavian", "miles-scandinavian")
    case "milliliter": return ("mL", "mL", "milliliter", "milliliters")
    case "millimeter": return ("mm", "mm", "millimeter", "millimeters")
    case "millisecond": return ("ms", "ms", "millisecond", "milliseconds")
    case "minute": return ("min", "m", "minute", "minutes")
    case "month": return ("mth", "m", "month", "months")
    case "nanosecond": return ("ns", "ns", "nanosecond", "nanoseconds")
    case "ounce": return ("oz", "oz", "ounce", "ounces")
    case "percent": return ("%", "%", "percent", "percent")
    case "petabyte": return ("PB", "PB", "petabyte", "petabytes")
    case "pound": return ("lb", "#", "pound", "pounds")
    case "second": return ("sec", "s", "second", "seconds")
    case "stone": return ("st", "st", "stone", "stone")
    case "terabit": return ("Tb", "Tb", "terabit", "terabits")
    case "terabyte": return ("TB", "TB", "terabyte", "terabytes")
    case "week": return ("wk", "w", "week", "weeks")
    case "yard": return ("yd", "yd", "yard", "yards")
    case "year": return ("yr", "y", "year", "years")
    default: return nil
    }
}

func jsIntlUnitNames() -> [String] {
    var out: [String] = []
    for u in ["acre", "bit", "byte", "celsius", "centimeter", "day", "degree", "fahrenheit", "fluid-ounce", "foot", "gallon",
              "gigabit", "gigabyte", "gram", "hectare", "hour", "inch", "kilobit", "kilobyte", "kilogram", "kilometer",
              "liter", "megabit", "megabyte", "meter", "microsecond", "mile", "mile-scandinavian", "milliliter",
              "millimeter", "millisecond", "minute", "month", "nanosecond", "ounce", "percent", "petabyte", "pound",
              "second", "stone", "terabit", "terabyte", "week", "yard", "year"] { out.append(u) }
    return out
}

/// Whether `u` is "x" or "x-per-y" with sanctioned parts.
func jsIntlValidUnit(_ u: String) -> Bool {
    if jsIntlSimpleUnit(u) != nil { return true }
    let parts = u.components(separatedByString: "-per-")
    if parts.count == 2, jsIntlSimpleUnit(parts[0]) != nil, jsIntlSimpleUnit(parts[1]) != nil { return true }
    return false
}

extension String {
    /// Split on a separator string (no Foundation).
    func components(separatedByString sep: String) -> [String] {
        let s = Array(self.utf8), p = Array(sep.utf8)
        var out: [String] = []
        var start = 0, i = 0
        while i + p.count <= s.count {
            if Array(s[i..<(i + p.count)]) == p {
                out.append(String(decoding: s[start..<i], as: UTF8.self))
                i += p.count; start = i
            } else { i += 1 }
        }
        out.append(String(decoding: s[start...], as: UTF8.self))
        return out
    }
}

// MARK: Formatting

/// Round `d` per the options: significant digits, fraction digits, or the
/// compact default (integer once there are three digits, else two
/// significant digits).
func jsIntlRound(_ d: inout JSIntlDecimal, _ o: JSIntlNumberOptions) {
    if o.compactRounding {
        if d.exp >= 2 { d.round(toPosition: 0) } else { d.round(toPosition: d.exp - 1) }
        return
    }
    if o.maxSig > 0 {
        d.round(toPosition: d.exp - o.maxSig + 1)
    } else {
        d.round(toPosition: -o.maxFrac)
    }
}

/// (integer digits, fraction digits) as ASCII, padded per the options.
func jsIntlDigitStrings(_ d: JSIntlDecimal, _ o: JSIntlNumberOptions) -> ([UInt8], [UInt8]) {
    var intPart: [UInt8] = []
    if d.digits.isEmpty || d.exp < 0 {
        intPart = [0x30]
    } else {
        for i in 0...d.exp { intPart.append(i < d.digits.count ? d.digits[i] + 0x30 : 0x30) }
    }
    var frac: [UInt8] = []
    if !d.digits.isEmpty {
        let lastPos = d.exp - d.digits.count + 1
        if lastPos < 0 {
            var p = -1
            while p >= lastPos {
                let i = d.exp - p
                frac.append(i >= 0 && i < d.digits.count ? d.digits[i] + 0x30 : 0x30)
                p -= 1
            }
        }
    }
    var minFrac = o.minFrac
    if o.compactRounding { minFrac = 0 }
    else if o.maxSig > 0 {
        minFrac = d.digits.isEmpty ? max(0, o.minSig - 1) : (d.exp >= 0 ? max(0, o.minSig - (d.exp + 1)) : (-d.exp - 1) + o.minSig)
    }
    while frac.count < minFrac { frac.append(0x30) }
    while intPart.count < o.minInt { intPart.insert(0x30, at: 0) }
    return (intPart, frac)
}

/// Integer digits with group separators as parts.
func jsIntlGroup(_ intDigits: [UInt8], grouping: Int, into parts: inout [JSIntlPart]) {
    let n = intDigits.count
    let group = grouping == 2 || (grouping == 1 && n > 3) || (grouping == 3 && n > 4)
    if !group || n <= 3 {
        parts.append(JSIntlPart(type: "integer", text: intDigits.map { UInt16($0) }))
        return
    }
    var cur: [UInt16] = []
    for (i, c) in intDigits.enumerated() {
        if i > 0 && (n - i) % 3 == 0 {
            parts.append(JSIntlPart(type: "integer", text: cur)); cur = []
            parts.append(JSIntlPart(type: "group", text: [0x2C]))
        }
        cur.append(UInt16(c))
    }
    parts.append(JSIntlPart(type: "integer", text: cur))
}

/// The number itself (no sign, currency...): integer / group / decimal /
/// fraction parts, compact and exponent suffixes.
func jsIntlNumberBody(_ dec: JSIntlDecimal, _ o: JSIntlNumberOptions, isZero: inout Bool) -> [JSIntlPart] {
    var parts: [JSIntlPart] = []
    var d = dec
    var suffix: [JSIntlPart] = []
    if o.notation == 3 {
        // Compact: pick the magnitude, round, and bump if rounding carried over.
        var k = d.isZero ? 0 : min(max(d.exp / 3, 0), 4)
        var sc = d
        if !sc.isZero { sc.exp -= 3 * k }
        jsIntlRound(&sc, o)
        if !sc.isZero && sc.exp >= 3 && k < 4 {
            // Rounding carried into the next magnitude (999999 -> 1M).
            k += 1
            sc = d
            sc.exp -= 3 * k
            jsIntlRound(&sc, o)
        }
        d = sc
        if k > 0 {
            if o.compactLong {
                suffix.append(JSIntlPart(type: "literal", text: [0x20]))
                let names = ["", "thousand", "million", "billion", "trillion"]
                suffix.append(JSIntlPart(type: "compact", text: intlU16(names[k])))
            } else {
                let names = ["", "K", "M", "B", "T"]
                suffix.append(JSIntlPart(type: "compact", text: intlU16(names[k])))
            }
        }
    } else if o.notation == 1 || o.notation == 2 {
        var e = d.isZero ? 0 : d.exp
        if o.notation == 2 { e = Int(jsFloor(Double(e) / 3)) * 3 }
        var m = d
        if !m.isZero { m.exp -= e }
        jsIntlRound(&m, o)
        if !m.isZero && m.exp >= (o.notation == 2 ? 3 : 1) { e += (o.notation == 2 ? 3 : 1); m.exp -= (o.notation == 2 ? 3 : 1) }
        d = m
        suffix.append(JSIntlPart(type: "exponentSeparator", text: [0x45]))
        if e < 0 { suffix.append(JSIntlPart(type: "exponentMinusSign", text: [0x2D])) }
        suffix.append(JSIntlPart(type: "exponentInteger", text: intlU16(String(e < 0 ? -e : e))))
    } else {
        jsIntlRound(&d, o)
    }
    isZero = d.isZero
    let (ip, fp) = jsIntlDigitStrings(d, o)
    jsIntlGroup(ip, grouping: o.grouping, into: &parts)
    if !fp.isEmpty {
        parts.append(JSIntlPart(type: "decimal", text: [0x2E]))
        parts.append(JSIntlPart(type: "fraction", text: fp.map { UInt16($0) }))
    }
    parts.append(contentsOf: suffix)
    return parts
}

/// Full formatting of a value (negative sign, currency, percent, unit).
/// `dec` is the magnitude; `negative` the sign (also for -0).
func jsIntlFormatParts(_ dec: JSIntlDecimal?, negative: Bool, nan: Bool, infinite: Bool, _ o: JSIntlNumberOptions) -> [JSIntlPart] {
    var body: [JSIntlPart] = []
    var isZero = false
    if nan {
        body = [JSIntlPart(type: "nan", text: intlU16("NaN"))]
    } else if infinite {
        body = [JSIntlPart(type: "infinity", text: [0x221E])]
    } else if var d = dec {
        if o.style == 1 { d.shift(2) }
        body = jsIntlNumberBody(d, o, isZero: &isZero)
    }
    // Sign.
    var sign: [JSIntlPart] = []
    let neg = negative && !nan
    switch o.signDisplay {
    case 1: break
    case 2:
        if nan { sign = [JSIntlPart(type: "plusSign", text: [0x2B])] }
        else { sign = [JSIntlPart(type: neg ? "minusSign" : "plusSign", text: [neg ? 0x2D : 0x2B])] }
    case 3:
        if !nan && !isZero {
            sign = [JSIntlPart(type: neg ? "minusSign" : "plusSign", text: [neg ? 0x2D : 0x2B])]
        }
    case 4:
        if neg && !isZero && !nan { sign = [JSIntlPart(type: "minusSign", text: [0x2D])] }
    default:
        if neg { sign = [JSIntlPart(type: "minusSign", text: [0x2D])] }
    }
    let parenthesize = o.style == 2 && o.accounting && !sign.isEmpty && sign[0].type == "minusSign"
    var out: [JSIntlPart] = []
    if parenthesize { out.append(JSIntlPart(type: "literal", text: [0x28])) } else { out.append(contentsOf: sign) }
    switch o.style {
    case 2:
        let plural = !(body.count == 1 && body[0].text == [0x31])
        if o.currencyDisplay == 3 {
            out.append(contentsOf: body)
            out.append(JSIntlPart(type: "literal", text: [0x20]))
            out.append(JSIntlPart(type: "currency", text: intlU16(jsIntlCurrencyName(o.currency, plural: plural))))
        } else {
            var sym = o.currency
            if o.currencyDisplay != 2, let s = jsIntlCurrencySymbol(o.currency, narrow: o.currencyDisplay == 1) { sym = s }
            out.append(JSIntlPart(type: "currency", text: intlU16(sym)))
            if let last = sym.utf8.last, (last | 0x20) >= 0x61 && (last | 0x20) <= 0x7A {
                out.append(JSIntlPart(type: "literal", text: [0xA0]))
            }
            out.append(contentsOf: body)
        }
    case 1:
        out.append(contentsOf: body)
        out.append(JSIntlPart(type: "percentSign", text: [0x25]))
    case 3:
        out.append(contentsOf: body)
        let plural = !(body.count == 1 && body[0].text == [0x31])
        var txt = o.unit
        let pieces = o.unit.components(separatedByString: "-per-")
        func name(_ u: String) -> String {
            guard let n = jsIntlSimpleUnit(u) else { return u }
            switch o.unitDisplay {
            case 2: return plural ? n.3 : n.2
            case 1: return n.1
            default: return n.0
            }
        }
        if pieces.count == 2 {
            if o.unitDisplay == 2 {
                txt = (plural ? jsIntlSimpleUnit(pieces[0])?.3 : jsIntlSimpleUnit(pieces[0])?.2) ?? pieces[0]
                txt += " per " + (jsIntlSimpleUnit(pieces[1])?.2 ?? pieces[1])
            } else if pieces[0] == "mile" && pieces[1] == "hour" { txt = "mph" }
            else { txt = name(pieces[0]) + "/" + (pieces[1] == "hour" && o.unitDisplay != 2 ? "h" : name(pieces[1])) }
        } else { txt = name(o.unit) }
        let tight = o.unitDisplay == 1 || (o.unitDisplay == 0 && (o.unit == "percent" || o.unit == "celsius" || o.unit == "fahrenheit"))
        if !tight || o.unitDisplay == 2 || (o.unitDisplay == 1 && txt.utf8.count > 2 && o.unit != "celsius" && o.unit != "fahrenheit" && o.unit != "degree") {
            out.append(JSIntlPart(type: "literal", text: [0x20]))
        }
        out.append(JSIntlPart(type: "unit", text: intlU16(txt)))
    default:
        out.append(contentsOf: body)
    }
    if parenthesize { out.append(JSIntlPart(type: "literal", text: [0x29])) }
    return out
}

extension JSRealm {
    /// The magnitude decimal and sign of a Number or BigInt value.
    func intlNumericParts(_ v: JSValue, _ o: JSIntlNumberOptions) -> [JSIntlPart] {
        if v.isBigInt {
            let b = heap.bigintValue(v)
            let digits = jsBNMagToDigits(b.mag, radix: 10)
            return jsIntlFormatParts(JSIntlDecimal(asciiDigits: digits), negative: b.negative, nan: false, infinite: false, o)
        }
        let x = v.numberValue
        if x.isNaN { return jsIntlFormatParts(nil, negative: false, nan: true, infinite: false, o) }
        let neg = x < 0 || (x == 0 && x.sign == .minus)
        if x.isInfinite { return jsIntlFormatParts(nil, negative: neg, nan: false, infinite: true, o) }
        return jsIntlFormatParts(JSIntlDecimal(double: x.magnitude), negative: neg, nan: false, infinite: false, o)
    }

    /// InitializeNumberFormat: the resolved options object.
    func intlNumberResolve(_ locales: JSValue, _ options: JSValue) throws(JSThrow) -> JSValue {
        let loc = try intlLocale(locales)
        let opts = try intlOptions(options)
        let d0 = heap.rootDepth
        defer { heap.popRoots(to: d0) }
        _ = heap.root(opts)
        _ = try intlGetString(opts, "localeMatcher", ["lookup", "best fit"])
        _ = try intlGetString(opts, "numberingSystem", [])
        let style = try intlGetString(opts, "style", ["decimal", "percent", "currency", "unit"]) ?? "decimal"
        var currency = try intlGetString(opts, "currency", [])
        if let c = currency {
            let u = Array(c.utf8)
            guard u.count == 3 && u.allSatisfy({ ($0 | 0x20) >= 0x61 && ($0 | 0x20) <= 0x7A }) else {
                throw throwRangeError("Invalid currency code : " + c)
            }
            currency = String(decoding: u.map { $0 >= 0x61 ? $0 - 32 : $0 }, as: UTF8.self)
        } else if style == "currency" { throw throwTypeError("Currency code is required with currency style.") }
        let currencyDisplay = try intlGetString(opts, "currencyDisplay", ["code", "symbol", "narrowSymbol", "name"]) ?? "symbol"
        let currencySign = try intlGetString(opts, "currencySign", ["standard", "accounting"]) ?? "standard"
        let unit = try intlGetString(opts, "unit", [])
        if let u = unit, !jsIntlValidUnit(u) { throw throwRangeError("Invalid unit argument for Intl.NumberFormat() '" + u + "'") }
        if style == "unit" && unit == nil { throw throwTypeError("Unit is required with unit style.") }
        let unitDisplay = try intlGetString(opts, "unitDisplay", ["short", "narrow", "long"]) ?? "short"
        let notation = try intlGetString(opts, "notation", ["standard", "scientific", "engineering", "compact"]) ?? "standard"
        // Digit options.
        var mnfdDefault = 0, mxfdDefault = 3
        if style == "currency" && notation == "standard" {
            let c = jsIntlCurrencyDigits(currency ?? "USD")
            mnfdDefault = c; mxfdDefault = c
        } else if style == "percent" { mxfdDefault = 0 }
        let mnid = try intlGetNumber(opts, "minimumIntegerDigits", 1, 21) ?? 1
        let mnfdRaw = try getV(opts, heap.key("minimumFractionDigits"))
        let mxfdRaw = try getV(opts, heap.key("maximumFractionDigits"))
        let mnsdRaw = try getV(opts, heap.key("minimumSignificantDigits"))
        let mxsdRaw = try getV(opts, heap.key("maximumSignificantDigits"))
        func checked(_ v: JSValue, _ name: String, _ lo: Int, _ hi: Int) throws(JSThrow) -> Int? {
            if v.isUndefined { return nil }
            let d = try toNumber(v)
            if d.isNaN || d < Double(lo) || d > Double(hi) { throw throwRangeError(name + " value is out of range.") }
            return Int(jsFloor(d))
        }
        var mnfd = try checked(mnfdRaw, "minimumFractionDigits", 0, 100)
        var mxfd = try checked(mxfdRaw, "maximumFractionDigits", 0, 100)
        var mnsd = try checked(mnsdRaw, "minimumSignificantDigits", 1, 21)
        var mxsd = try checked(mxsdRaw, "maximumSignificantDigits", 1, 21)
        var compactRounding = false
        let res = heap.newObject(proto: objectPrototype)
        _ = heap.root(res)
        if mnsd != nil || mxsd != nil {
            mnsd = mnsd ?? 1
            mxsd = mxsd ?? 21
            if mnsd! > mxsd! { throw throwRangeError("maximumSignificantDigits value is out of range.") }
        } else if mnfd != nil || mxfd != nil {
            if mnfd == nil { mnfd = min(mnfdDefault, mxfd!) }
            else if mxfd == nil { mxfd = max(mxfdDefault, mnfd!) }
            else if mnfd! > mxfd! { throw throwRangeError("maximumFractionDigits value is out of range.") }
        } else if notation == "compact" {
            compactRounding = true
            mnfd = 0; mxfd = 0
        } else {
            mnfd = mnfdDefault; mxfd = mxfdDefault
        }
        let useGrouping = try getV(opts, heap.key("useGrouping"))
        var grouping: JSValue = .undefined     // undefined: the string below
        var groupingStr = notation == "compact" ? "min2" : "auto"
        if !useGrouping.isUndefined {
            if useGrouping.isBool {
                if useGrouping.boolValue { groupingStr = "always" } else { grouping = .false }
            } else if useGrouping.isString {
                let s = heap.swiftString(useGrouping)
                if s == "true" || s == "false" { groupingStr = "auto" }
                else if s == "min2" || s == "auto" || s == "always" { groupingStr = s }
                else { throw throwRangeError("Value " + s + " out of range for Intl.NumberFormat options property useGrouping") }
            } else if !heap.toBoolean(useGrouping) { grouping = .false }
            else { groupingStr = "always" }
        }
        let compactDisplay = try intlGetString(opts, "compactDisplay", ["short", "long"]) ?? "short"
        let signDisplay = try intlGetString(opts, "signDisplay", ["auto", "never", "always", "exceptZero", "negative"]) ?? "auto"
        // Resolved options object, in the spec's order.
        intlDefine(res, "locale", loc)
        intlDefine(res, "numberingSystem", "latn")
        intlDefine(res, "style", style)
        if style == "currency" {
            intlDefine(res, "currency", currency ?? "USD")
            intlDefine(res, "currencyDisplay", currencyDisplay)
            intlDefine(res, "currencySign", currencySign)
        }
        if style == "unit" {
            intlDefine(res, "unit", unit ?? "")
            intlDefine(res, "unitDisplay", unitDisplay)
        }
        intlDefine(res, "minimumIntegerDigits", .int32(Int32(mnid)))
        if mnsd != nil && mxsd != nil {
            intlDefine(res, "minimumSignificantDigits", .int32(Int32(mnsd!)))
            intlDefine(res, "maximumSignificantDigits", .int32(Int32(mxsd!)))
        } else {
            intlDefine(res, "minimumFractionDigits", .int32(Int32(mnfd ?? 0)))
            intlDefine(res, "maximumFractionDigits", .int32(Int32(mxfd ?? 0)))
            if compactRounding {
                intlDefine(res, "minimumSignificantDigits", .int32(1))
                intlDefine(res, "maximumSignificantDigits", .int32(2))
            }
        }
        if grouping.isUndefined { intlDefine(res, "useGrouping", groupingStr) } else { intlDefine(res, "useGrouping", grouping) }
        intlDefine(res, "notation", notation)
        if notation == "compact" { intlDefine(res, "compactDisplay", compactDisplay) }
        intlDefine(res, "signDisplay", signDisplay)
        intlDefine(res, "roundingIncrement", .int32(1))
        intlDefine(res, "roundingMode", "halfExpand")
        intlDefine(res, "roundingPriority", compactRounding ? "morePrecision" : "auto")
        intlDefine(res, "trailingZeroDisplay", "auto")
        if compactRounding {
            // The compact default is not "significant digits": keep the plain
            // 0/0 fraction digits for the formatter.
            _ = heap.deleteProperty(res, heap.key("minimumSignificantDigits"))
            _ = heap.deleteProperty(res, heap.key("maximumSignificantDigits"))
        }
        return res
    }

    func intlFormatNumeric(_ v: JSValue, _ res: JSValue) -> [UInt16] {
        let o = JSIntlNumberOptions(resolved: res, heap: heap)
        return intlPartsText(intlNumericParts(v, o))
    }

    /// Number.prototype.toLocaleString / BigInt.prototype.toLocaleString.
    func intlToLocaleNumber(_ v: JSValue, _ locales: JSValue, _ options: JSValue) throws(JSThrow) -> JSValue {
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        if locales.isUndefined && options.isUndefined {
            return heap.newString(utf16: intlPartsText(intlNumericParts(v, JSIntlNumberOptions())))
        }
        let res = try intlNumberResolve(locales, options)
        _ = heap.root(res)
        return heap.newString(utf16: intlFormatNumeric(v, res))
    }
}

// MARK: Plural rules

/// en plural category for a number with the given visible fraction digits.
func jsIntlPluralCategory(_ x: Double, ordinal: Bool, visibleFraction v: Int) -> String {
    let a = x.magnitude
    if !a.isFinite { return "other" }
    if ordinal {
        if a != jsFloor(a) { return "other" }
        let n10 = jsFmod(a, 10), n100 = jsFmod(a, 100)
        if n10 == 1 && n100 != 11 { return "one" }
        if n10 == 2 && n100 != 12 { return "two" }
        if n10 == 3 && n100 != 13 { return "few" }
        return "other"
    }
    return a == 1 && v == 0 ? "one" : "other"
}

func jsInstallIntlNumber(_ realm: JSRealm, _ intl: JSValue) {
    let heap = realm.heap
    // -------------------------------------------------------- NumberFormat
    let nfp = heap.newObject(proto: realm.objectPrototype)
    _ = heap.root(nfp)
    let nfCtor = realm.intlDefineClass(intl, "NumberFormat", length: 0, proto: nfp) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let proto = try realm.intlProto(args)
        let d = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: d) }
        _ = realm.heap.root(proto)
        let res = try realm.intlNumberResolve(args[0], args[1])
        return realm.intlNew(proto: proto, kind: .numberFormat, resolved: res)
    }
    _ = nfCtor
    let boundFormat = realm.registerNative("", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let nf = realm.heap.slot(args.callee, 0)
        let res = realm.heap.slot(nf, 1)
        let v = try realm.toNumeric(args[0])
        let d = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: d) }
        _ = realm.heap.root(v)
        return realm.heap.newString(utf16: realm.intlFormatNumeric(v, res))
    }
    realm.defineGetter(nfp, "format") { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        _ = try realm.intlThis(args.this, .numberFormat, "get Intl.NumberFormat.prototype.format")
        let cached = realm.heap.slot(args.this, 2)
        if cached.isObject { return cached }
        let f = realm.nativeClosure(boundFormat, [args.this])
        realm.heap.setSlot(args.this, 2, f)
        return f
    }
    realm.defineMethod(nfp, "formatToParts", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let res = try realm.intlThis(args.this, .numberFormat, "Intl.NumberFormat.prototype.formatToParts")
        let v = try realm.toNumeric(args[0])
        let d = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: d) }
        _ = realm.heap.root(v)
        let o = JSIntlNumberOptions(resolved: res, heap: realm.heap)
        return realm.intlPartsArray(realm.intlNumericParts(v, o))
    }
    func rangeParts(_ realm: JSRealm, _ args: JSArgs, _ name: String) throws(JSThrow) -> [JSIntlPart] {
        let res = try realm.intlThis(args.this, .numberFormat, "Intl.NumberFormat.prototype." + name)
        if args[0].isUndefined || args[1].isUndefined { throw realm.throwTypeError("start and end are required") }
        let a = try realm.toNumeric(args[0])
        _ = realm.heap.root(a)
        let b = try realm.toNumeric(args[1])
        _ = realm.heap.root(b)
        if (a.isNumber && a.numberValue.isNaN) || (b.isNumber && b.numberValue.isNaN) { throw realm.throwRangeError("Invalid time value") }
        let o = JSIntlNumberOptions(resolved: res, heap: realm.heap)
        let pa = realm.intlNumericParts(a, o), pb = realm.intlNumericParts(b, o)
        if intlPartsText(pa) == intlPartsText(pb) {
            return [JSIntlPart(type: "approximatelySign", text: [0x7E])] + pa
        }
        let sep = o.style == 2 || o.style == 3 ? [UInt16(0x20), 0x2013, 0x20] : [UInt16(0x2013)]
        return pa + [JSIntlPart(type: "literal", text: sep)] + pb
    }
    realm.defineMethod(nfp, "formatRange", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let d = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: d) }
        return realm.heap.newString(utf16: intlPartsText(try rangeParts(realm, args, "formatRange")))
    }
    realm.defineMethod(nfp, "formatRangeToParts", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let d = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: d) }
        return realm.intlPartsArray(try rangeParts(realm, args, "formatRangeToParts"))
    }
    realm.defineMethod(nfp, "resolvedOptions", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let res = try realm.intlThis(args.this, .numberFormat, "Intl.NumberFormat.prototype.resolvedOptions")
        return realm.intlCopyOptions(res)
    }
    // Number / BigInt toLocaleString.
    let np = realm.intrinsic(.numberPrototype)
    realm.defineMethod(np, "toLocaleString", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let x = try realm.thisNumber(args.this)
        return try realm.intlToLocaleNumber(x, args[0], args[1])
    }
    let bp = realm.intrinsic(.bigintPrototype)
    realm.defineMethod(bp, "toLocaleString", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let b = try realm.thisBigInt(args.this)
        return try realm.intlToLocaleNumber(b, args[0], args[1])
    }
    // ---------------------------------------------------------- PluralRules
    let prp = heap.newObject(proto: realm.objectPrototype)
    _ = heap.root(prp)
    realm.intlDefineClass(intl, "PluralRules", length: 0, proto: prp) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        if !args.isConstruct { throw realm.throwTypeError("Constructor Intl.PluralRules requires 'new'") }
        let proto = try realm.intlProto(args)
        let d = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: d) }
        _ = realm.heap.root(proto)
        let loc = try realm.intlLocale(args[0])
        let opts = try realm.intlOptions(args[1])
        _ = realm.heap.root(opts)
        let type = try realm.intlGetString(opts, "type", ["cardinal", "ordinal"]) ?? "cardinal"
        let mnid = try realm.intlGetNumber(opts, "minimumIntegerDigits", 1, 21) ?? 1
        var mnfd = try realm.intlGetNumber(opts, "minimumFractionDigits", 0, 100)
        var mxfd = try realm.intlGetNumber(opts, "maximumFractionDigits", 0, 100)
        let mnsd = try realm.intlGetNumber(opts, "minimumSignificantDigits", 1, 21)
        var mxsd = try realm.intlGetNumber(opts, "maximumSignificantDigits", 1, 21)
        let res = realm.heap.newObject(proto: realm.objectPrototype)
        _ = realm.heap.root(res)
        realm.intlDefine(res, "locale", loc)
        realm.intlDefine(res, "type", type)
        realm.intlDefine(res, "minimumIntegerDigits", .int32(Int32(mnid)))
        if mnsd != nil || mxsd != nil {
            mxsd = mxsd ?? 21
            realm.intlDefine(res, "minimumSignificantDigits", .int32(Int32(mnsd ?? 1)))
            realm.intlDefine(res, "maximumSignificantDigits", .int32(Int32(mxsd!)))
        } else {
            if mnfd == nil && mxfd == nil { mnfd = 0; mxfd = 3 }
            else if mnfd == nil { mnfd = min(0, mxfd!) }
            else if mxfd == nil { mxfd = max(3, mnfd!) }
            else if mnfd! > mxfd! { throw realm.throwRangeError("maximumFractionDigits value is out of range.") }
            realm.intlDefine(res, "minimumFractionDigits", .int32(Int32(mnfd!)))
            realm.intlDefine(res, "maximumFractionDigits", .int32(Int32(mxfd!)))
        }
        let cats: [String] = type == "ordinal" ? ["few", "one", "two", "other"] : ["one", "other"]
        var vals: [JSValue] = []
        for c in cats { let s = realm.heap.newString(c); _ = realm.heap.root(s); vals.append(s) }
        let arr = realm.heap.newArray(proto: realm.arrayPrototype, elements: vals)
        _ = realm.heap.root(arr)
        _ = realm.heap.createDataProperty(res, realm.heap.key("pluralCategories"), arr)
        realm.intlDefine(res, "roundingIncrement", .int32(1))
        realm.intlDefine(res, "roundingMode", "halfExpand")
        realm.intlDefine(res, "roundingPriority", "auto")
        realm.intlDefine(res, "trailingZeroDisplay", "auto")
        return realm.intlNew(proto: proto, kind: .pluralRules, resolved: res)
    }
    func pluralSelect(_ realm: JSRealm, _ res: JSValue, _ x: Double) -> String {
        var o = JSIntlNumberOptions()
        o.minFrac = realm.heap.intlRawInt(res, "minimumFractionDigits", 0)
        o.maxFrac = realm.heap.intlRawInt(res, "maximumFractionDigits", 3)
        o.minSig = realm.heap.intlRawInt(res, "minimumSignificantDigits", 0)
        o.maxSig = realm.heap.intlRawInt(res, "maximumSignificantDigits", 0)
        var dec = JSIntlDecimal(double: x.magnitude)
        jsIntlRound(&dec, o)
        let (_, frac) = jsIntlDigitStrings(dec, o)
        return jsIntlPluralCategory(x, ordinal: realm.heap.intlRawString(res, "type") == "ordinal", visibleFraction: frac.count)
    }
    realm.defineMethod(prp, "select", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let res = try realm.intlThis(args.this, .pluralRules, "Intl.PluralRules.prototype.select")
        let x = try realm.toNumber(args[0])
        return realm.string(pluralSelect(realm, res, x))
    }
    realm.defineMethod(prp, "selectRange", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let res = try realm.intlThis(args.this, .pluralRules, "Intl.PluralRules.prototype.selectRange")
        if args[0].isUndefined || args[1].isUndefined { throw realm.throwTypeError("start and end are required") }
        _ = try realm.toNumber(args[0])
        let y = try realm.toNumber(args[1])
        return realm.string(pluralSelect(realm, res, y))
    }
    realm.defineMethod(prp, "resolvedOptions", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let res = try realm.intlThis(args.this, .pluralRules, "Intl.PluralRules.prototype.resolvedOptions")
        return realm.intlCopyOptions(res)
    }
}
