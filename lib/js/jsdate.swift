// ECMAScript Date core (ROADMAP Phase 9C): pure functions on time values.
//
// A time value is a Double: milliseconds since 1970-01-01T00:00:00Z, NaN for
// an invalid date, otherwise an integer with |t| <= 8.64e15. No VM types are
// used here; the Date built-ins wrap these.
//
// API (all free functions, prefix jsDate; constants jsDateMaxTime etc.)
//
//   Spec math (ECMA-262 21.4.1):
//     jsDateDay(t) / jsDateTimeWithinDay(t)       floor division by 86400000
//     jsDateDaysInYear(y), jsDateYearFromTime(t), jsDateMonthFromTime(t)
//     (0...11), jsDateDateFromTime(t) (1...31), jsDateWeekDay(t) (0 = Sunday),
//     jsDateHour/Minute/Second/MsFromTime(t)       NaN in -> NaN out
//     jsDateMakeTime(h, m, s, ms), jsDateMakeDay(year, month, date),
//     jsDateMakeDate(day, time), jsDateTimeClip(t)  (spec semantics: non-finite
//       -> NaN, month/date out of range normalised, truncation of args)
//     jsDateFromComponents(year, month, date, h, m, s, ms)
//       MakeDate(MakeDay(yr, ...), MakeTime(...)) where 0 <= trunc(year) <= 99
//       maps to 1900 + year (the multi-argument Date / Date.UTC rule). No clip,
//       no zone: callers apply jsDateUTC(_, zone) for local components, then
//       jsDateTimeClip.
//     jsDateFields(t) -> JSDateFields?            all the fields at once
//
//   Time zone: JSDateZone (struct; JSDateZone.utc is the default everywhere).
//     zone.offsetMs(utc: t)            local = utc + offset
//     zone.offsetMs(local: t)          offset to subtract from a local time
//     zone.name(utc: t)                "Coordinated Universal Time"
//     A zone is a base offset plus an optional sorted list of
//     JSDateZoneTransition (start in UTC ms, new offset in minutes, name), so
//     DST rules can be added later without touching the callers.
//     jsDateLocalTime(t, zone), jsDateUTC(localT, zone) (no TimeClip; NaN
//       passes through), jsDateTimezoneOffsetMinutes(t, zone).
//
//   Parsing (Date.parse and new Date(string)):
//     jsDateParse(units, zone) -> Double      any RandomAccessCollection of
//       UInt8/UInt16 with Int index (so [UInt16] JS strings work). Returns a
//       clipped time value or NaN. Accepts the ECMAScript format (date-only =
//       UTC, date-time without offset = local, +-YYYYYY years), toString /
//       toUTCString output, RFC 2822/1123 with zone names (GMT UTC UT Z EST EDT
//       CST CDT MST MDT PST PDT, +-hhmm), "Nov 19 2026", "2026/11/19 14:00",
//       "November 19, 2026 10:00:00", "11/19/2026", "19 Nov 2026 2:00 PM".
//       Input longer than jsDateMaxParseLength units is NaN.
//
//   Formatting (all return [UInt8] ASCII; invalid dates give "Invalid Date"
//   except toISOString):
//     jsDateToISOString(t) -> [UInt8]?   nil for NaN (throw RangeError); years
//                                        outside 0...9999 use +-YYYYYY
//     jsDateToString(t, zone), jsDateToDateString(t, zone),
//     jsDateToTimeString(t, zone), jsDateToUTCString(t)
//     jsDateToLocaleString / ...DateString / ...TimeString (t, zone)
//       en-US: "11/19/2026, 2:00:00 PM", "11/19/2026", "2:00:00 PM"
//   Date.UTC / Date.now live in the built-ins.

public let jsDateMaxTime: Double = 8.64e15
public let jsDateMsPerDay: Double = 86_400_000
public let jsDateMaxParseLength = 512

// MARK: Zones

public struct JSDateZoneTransition {
    public var startUTC: Double
    public var offsetMinutes: Int
    public var name: [UInt8]
    public init(startUTC: Double, offsetMinutes: Int, name: [UInt8]) {
        self.startUTC = startUTC; self.offsetMinutes = offsetMinutes; self.name = name
    }
}

public struct JSDateZone {
    public var baseOffsetMinutes: Int
    public var baseName: [UInt8]
    /// Sorted by startUTC.
    public var transitions: [JSDateZoneTransition]

    public init(baseOffsetMinutes: Int, baseName: [UInt8], transitions: [JSDateZoneTransition] = []) {
        self.baseOffsetMinutes = baseOffsetMinutes; self.baseName = baseName
        self.transitions = transitions
    }

    public static var utc: JSDateZone {
        JSDateZone(baseOffsetMinutes: 0, baseName: Array("Coordinated Universal Time".utf8))
    }

    func offsetMinutes(utc t: Double) -> (Int, [UInt8]) {
        var off = baseOffsetMinutes, nm = baseName
        for tr in transitions {
            if tr.startUTC <= t { off = tr.offsetMinutes; nm = tr.name } else { break }
        }
        return (off, nm)
    }

    public func offsetMs(utc t: Double) -> Double {
        if t.isNaN { return 0 }
        return Double(offsetMinutes(utc: t).0) * 60_000
    }

    public func name(utc t: Double) -> [UInt8] { offsetMinutes(utc: t.isNaN ? 0 : t).1 }

    /// Offset for a local time value (the amount to subtract to get UTC).
    public func offsetMs(local t: Double) -> Double {
        if t.isNaN { return 0 }
        if transitions.isEmpty { return Double(baseOffsetMinutes) * 60_000 }
        let guess = t - Double(offsetMinutes(utc: t).0) * 60_000
        return offsetMs(utc: guess)
    }
}

public func jsDateLocalTime(_ t: Double, _ zone: JSDateZone = .utc) -> Double {
    t.isFinite ? t + zone.offsetMs(utc: t) : Double.nan
}

public func jsDateUTC(_ local: Double, _ zone: JSDateZone = .utc) -> Double {
    local.isFinite ? local - zone.offsetMs(local: local) : Double.nan
}

public func jsDateTimezoneOffsetMinutes(_ t: Double, _ zone: JSDateZone = .utc) -> Double {
    t.isFinite ? 0.0 - zone.offsetMs(utc: t) / 60_000 : Double.nan
}

// MARK: Spec math

@inline(__always) func jsDateDivFloor(_ a: Int, _ b: Int) -> Int {
    let q = a / b
    return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
}
@inline(__always) func jsDateModFloor(_ a: Int, _ b: Int) -> Int {
    let r = a % b
    return (r != 0 && (r < 0) != (b < 0)) ? r + b : r
}

public func jsDateDay(_ t: Double) -> Double { jsFloor(t / jsDateMsPerDay) }

public func jsDateTimeWithinDay(_ t: Double) -> Double {
    guard t.isFinite else { return Double.nan }
    let r = jsFmod(t, jsDateMsPerDay)
    return (r < 0 ? r + jsDateMsPerDay : r) + 0.0
}

public func jsDateIsLeap(_ y: Int) -> Bool {
    (jsDateModFloor(y, 4) == 0 && jsDateModFloor(y, 100) != 0) || jsDateModFloor(y, 400) == 0
}

public func jsDateDaysInYear(_ y: Double) -> Double {
    guard y.isFinite, y.magnitude < 1e9 else { return Double.nan }
    return jsDateIsLeap(Int(y)) ? 366 : 365
}

func jsDateDaysInMonth(_ y: Int, _ m: Int) -> Int {  // m 0...11
    switch m {
    case 1: return jsDateIsLeap(y) ? 29 : 28
    case 3, 5, 8, 10: return 30
    default: return 31
    }
}

/// Days since 1970-01-01 of a proleptic Gregorian date (m 1...12).
func jsDateDaysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
    let y = m <= 2 ? y0 - 1 : y0
    let era = jsDateDivFloor(y, 400)
    let yoe = y - era * 400
    let mp = (m + 9) % 12
    let doy = (153 * mp + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146_097 + doe - 719_468
}

/// (year, month 1...12, day 1...31) of a day number.
func jsDateCivilFromDays(_ z0: Int) -> (Int, Int, Int) {
    let z = z0 + 719_468
    let era = jsDateDivFloor(z, 146_097)
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
    let y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp < 10 ? mp + 3 : mp - 9
    return (m <= 2 ? y + 1 : y, m, d)
}

public struct JSDateFields {
    public var year: Int
    public var month: Int      // 0...11
    public var day: Int        // 1...31
    public var hour: Int
    public var minute: Int
    public var second: Int
    public var ms: Int
    public var weekday: Int    // 0 = Sunday
}

public func jsDateFields(_ t: Double) -> JSDateFields? {
    guard t.isFinite, t.magnitude < 1e17 else { return nil }
    let ms = Int(jsFloor(t))
    let days = jsDateDivFloor(ms, 86_400_000)
    let tod = ms - days * 86_400_000
    let (y, m, d) = jsDateCivilFromDays(days)
    return JSDateFields(year: y, month: m - 1, day: d, hour: tod / 3_600_000,
                        minute: (tod / 60_000) % 60, second: (tod / 1000) % 60, ms: tod % 1000,
                        weekday: jsDateModFloor(days + 4, 7))
}

public func jsDateYearFromTime(_ t: Double) -> Double { jsDateFields(t).map { Double($0.year) } ?? .nan }
public func jsDateMonthFromTime(_ t: Double) -> Double { jsDateFields(t).map { Double($0.month) } ?? .nan }
public func jsDateDateFromTime(_ t: Double) -> Double { jsDateFields(t).map { Double($0.day) } ?? .nan }
public func jsDateWeekDay(_ t: Double) -> Double { jsDateFields(t).map { Double($0.weekday) } ?? .nan }
public func jsDateHourFromTime(_ t: Double) -> Double { jsDateFields(t).map { Double($0.hour) } ?? .nan }
public func jsDateMinuteFromTime(_ t: Double) -> Double { jsDateFields(t).map { Double($0.minute) } ?? .nan }
public func jsDateSecondFromTime(_ t: Double) -> Double { jsDateFields(t).map { Double($0.second) } ?? .nan }
public func jsDateMsFromTime(_ t: Double) -> Double { jsDateFields(t).map { Double($0.ms) } ?? .nan }

public func jsDateMakeTime(_ h: Double, _ m: Double, _ s: Double, _ ms: Double) -> Double {
    guard h.isFinite, m.isFinite, s.isFinite, ms.isFinite else { return Double.nan }
    return jsTrunc(h) * 3_600_000 + jsTrunc(m) * 60_000 + jsTrunc(s) * 1000 + jsTrunc(ms)
}

public func jsDateMakeDay(_ year: Double, _ month: Double, _ date: Double) -> Double {
    guard year.isFinite, month.isFinite, date.isFinite else { return Double.nan }
    let y = jsTrunc(year), m = jsTrunc(month), dt = jsTrunc(date)
    let yAdd = jsFloor(m / 12)
    let ym = y + yAdd
    guard ym.magnitude < 400_000 else { return Double.nan }
    let mn = Int(m - yAdd * 12)
    let days = jsDateDaysFromCivil(Int(ym), mn + 1, 1)
    return Double(days) + dt - 1
}

public func jsDateMakeDate(_ day: Double, _ time: Double) -> Double {
    guard day.isFinite, time.isFinite else { return Double.nan }
    let tv = day * jsDateMsPerDay + time
    return tv.isFinite ? tv : Double.nan
}

public func jsDateTimeClip(_ t: Double) -> Double {
    guard t.isFinite, t.magnitude <= jsDateMaxTime else { return Double.nan }
    return jsTrunc(t) + 0.0
}

public func jsDateFromComponents(_ year: Double, _ month: Double, _ date: Double,
                                 _ h: Double, _ m: Double, _ s: Double, _ ms: Double) -> Double {
    var y = year
    if y.isFinite {
        let yi = jsTrunc(y)
        if yi >= 0 && yi <= 99 { y = 1900 + yi }
    }
    return jsDateMakeDate(jsDateMakeDay(y, month, date), jsDateMakeTime(h, m, s, ms))
}

// MARK: Parsing

enum JSDateISOResult { case noMatch, invalid, ok(Double) }

@inline(__always) func jsDateIsDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

func jsDateLower(_ c: UInt8) -> UInt8 { (c >= 0x41 && c <= 0x5a) ? c + 32 : c }

/// Reads exactly `n` digits at i.
func jsDateDigits(_ a: [UInt8], _ i: inout Int, _ n: Int) -> Int? {
    guard i + n <= a.count else { return nil }
    var v = 0
    for k in 0..<n {
        let c = a[i + k]
        guard jsDateIsDigit(c) else { return nil }
        v = v * 10 + Int(c - 0x30)
    }
    i += n
    return v
}

func jsDateParseISO(_ a: [UInt8], _ zone: JSDateZone) -> JSDateISOResult {
    let n = a.count
    var i = 0
    var year = 0
    if n > 0 && (a[0] == 0x2b || a[0] == 0x2d) {
        let neg = a[0] == 0x2d
        i = 1
        guard let y = jsDateDigits(a, &i, 6) else { return .noMatch }
        if neg && y == 0 { return .invalid }
        year = neg ? -y : y
    } else {
        guard let y = jsDateDigits(a, &i, 4) else { return .noMatch }
        year = y
    }
    var month = 1, day = 1
    var hour = 0, minute = 0, second = 0, ms = 0
    var hasTime = false
    var offsetMin: Int? = nil
    if i < n && a[i] == 0x2d {
        i += 1
        guard let m = jsDateDigits(a, &i, 2) else { return .noMatch }
        month = m
        if i < n && a[i] == 0x2d {
            i += 1
            guard let d = jsDateDigits(a, &i, 2) else { return .noMatch }
            day = d
        }
    }
    if i < n {
        guard a[i] == 0x54 || a[i] == 0x74 || a[i] == 0x20 else { return .noMatch }
        i += 1
        hasTime = true
        guard let h = jsDateDigits(a, &i, 2) else { return .noMatch }
        hour = h
        guard i < n, a[i] == 0x3a else { return .noMatch }
        i += 1
        guard let mi = jsDateDigits(a, &i, 2) else { return .noMatch }
        minute = mi
        if i < n && a[i] == 0x3a {
            i += 1
            guard let s = jsDateDigits(a, &i, 2) else { return .noMatch }
            second = s
            if i < n && (a[i] == 0x2e || a[i] == 0x2c) {
                i += 1
                var cnt = 0, v = 0
                while i < n && jsDateIsDigit(a[i]) {
                    if cnt < 3 { v = v * 10 + Int(a[i] - 0x30) }
                    cnt += 1; i += 1
                }
                guard cnt > 0 else { return .noMatch }
                while cnt < 3 { v *= 10; cnt += 1 }
                ms = v
            }
        }
        if i < n && (a[i] == 0x5a || a[i] == 0x7a) {
            i += 1; offsetMin = 0
        } else if i < n && (a[i] == 0x2b || a[i] == 0x2d) {
            let neg = a[i] == 0x2d
            i += 1
            guard let oh = jsDateDigits(a, &i, 2) else { return .noMatch }
            if i < n && a[i] == 0x3a { i += 1 }
            guard let om = jsDateDigits(a, &i, 2) else { return .noMatch }
            guard oh <= 23, om <= 59 else { return .invalid }
            offsetMin = (neg ? -1 : 1) * (oh * 60 + om)
        }
        guard i == n else { return .noMatch }
    }
    guard month >= 1, month <= 12, day >= 1, day <= jsDateDaysInMonth(year, month - 1) else { return .invalid }
    if hour == 24 {
        guard minute == 0, second == 0, ms == 0 else { return .invalid }
    } else {
        guard hour < 24 else { return .invalid }
    }
    guard minute < 60, second < 60 else { return .invalid }
    let dayN = jsDateMakeDay(Double(year), Double(month - 1), Double(day))
    var t = jsDateMakeDate(dayN, jsDateMakeTime(Double(hour), Double(minute), Double(second), Double(ms)))
    if let o = offsetMin {
        t -= Double(o) * 60_000
    } else if hasTime {
        t = jsDateUTC(t, zone)
    }
    return .ok(jsDateTimeClip(t))
}

let jsDateMonthNames: [[UInt8]] = ["january", "february", "march", "april", "may", "june", "july",
    "august", "september", "october", "november", "december"].map { Array($0.utf8) }
let jsDateDayNames: [[UInt8]] = ["sunday", "monday", "tuesday", "wednesday", "thursday",
    "friday", "saturday"].map { Array($0.utf8) }

func jsDateIsPrefixName(_ w: [UInt8], _ full: [UInt8]) -> Bool {
    guard w.count >= 3, w.count <= full.count else { return false }
    for k in 0..<w.count where w[k] != full[k] { return false }
    return true
}

func jsDateZoneOffset(_ w: [UInt8]) -> Int? {
    switch String(decoding: w, as: UTF8.self) {
    case "gmt", "utc", "ut", "z": return 0
    case "est": return -300
    case "edt": return -240
    case "cst": return -360
    case "cdt": return -300
    case "mst": return -420
    case "mdt": return -360
    case "pst": return -480
    case "pdt": return -420
    default: return nil
    }
}

struct JSDateNum { var value: Int; var digits: Int; var negated: Bool }

func jsDateParseLegacy(_ a: [UInt8], _ zone: JSDateZone) -> Double {
    let n = a.count
    var i = 0
    var nums: [JSDateNum] = []
    var month: Int? = nil
    var hour: Int? = nil, minute = 0, second = 0, ms = 0
    var ampm = 0  // 1 am, 2 pm
    var offsetMin: Int? = nil
    var negNext = false
    var lastWasNumber = false
    var afterZone = false
    let nan = Double.nan

    while i < n {
        let c = a[i]
        if c == 0x20 || c == 0x2c || c == 0x09 || c == 0x0a || c == 0x0d {
            i += 1; lastWasNumber = false; continue
        }
        if c == 0x28 {  // (comment)
            var depth = 0
            while i < n {
                if a[i] == 0x28 { depth += 1 } else if a[i] == 0x29 { depth -= 1; if depth == 0 { i += 1; break } }
                i += 1
            }
            if depth != 0 { return nan }
            lastWasNumber = false
            continue
        }
        if jsDateIsDigit(c) {
            var v = 0, cnt = 0
            while i < n && jsDateIsDigit(a[i]) {
                guard cnt < 9 else { return nan }
                v = v * 10 + Int(a[i] - 0x30); cnt += 1; i += 1
            }
            if i < n && a[i] == 0x3a {  // time
                guard hour == nil, !negNext else { return nan }
                hour = v
                i += 1
                var mc = 0, mv = 0
                while i < n && jsDateIsDigit(a[i]) && mc < 2 { mv = mv * 10 + Int(a[i] - 0x30); mc += 1; i += 1 }
                guard mc > 0 else { return nan }
                minute = mv
                if i < n && a[i] == 0x3a {
                    i += 1
                    var sc = 0, sv = 0
                    while i < n && jsDateIsDigit(a[i]) && sc < 2 { sv = sv * 10 + Int(a[i] - 0x30); sc += 1; i += 1 }
                    guard sc > 0 else { return nan }
                    second = sv
                    if i < n && a[i] == 0x2e {
                        i += 1
                        var fc = 0, fv = 0
                        while i < n && jsDateIsDigit(a[i]) {
                            if fc < 3 { fv = fv * 10 + Int(a[i] - 0x30) }
                            fc += 1; i += 1
                        }
                        guard fc > 0 else { return nan }
                        var k = min(fc, 3)
                        while k < 3 { fv *= 10; k += 1 }
                        ms = fv
                    }
                }
                lastWasNumber = false
                continue
            }
            guard nums.count < 4 else { return nan }
            nums.append(JSDateNum(value: v, digits: cnt, negated: negNext))
            negNext = false
            lastWasNumber = true
            continue
        }
        if (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) {
            var w: [UInt8] = []
            while i < n && ((a[i] >= 0x41 && a[i] <= 0x5a) || (a[i] >= 0x61 && a[i] <= 0x7a)) {
                guard w.count < 16 else { return nan }
                w.append(jsDateLower(a[i])); i += 1
            }
            if i < n && a[i] == 0x2e { i += 1 }  // "Nov."
            let ordinal = w == [0x73, 0x74] || w == [0x6e, 0x64] || w == [0x72, 0x64] || w == [0x74, 0x68]
            if lastWasNumber && ordinal {
                lastWasNumber = false; continue  // 1st 2nd 3rd 4th
            }
            lastWasNumber = false
            if w == [0x61, 0x6d] || w == [0x70, 0x6d] {
                guard ampm == 0, hour != nil else { return nan }
                ampm = w[0] == 0x61 ? 1 : 2
                continue
            }
            if let z = jsDateZoneOffset(w) {
                guard offsetMin == nil else { return nan }
                offsetMin = z; afterZone = true
                continue
            }
            var found = false
            for k in 0..<12 where jsDateIsPrefixName(w, jsDateMonthNames[k]) {
                guard month == nil else { return nan }
                month = k + 1; found = true; break
            }
            if found { continue }
            for k in 0..<7 where jsDateIsPrefixName(w, jsDateDayNames[k]) { found = true; break }
            if found { continue }
            return nan
        }
        if c == 0x2b || c == 0x2d {
            let prevSpace = i == 0 || a[i - 1] == 0x20 || a[i - 1] == 0x2c
            let hasDigit = i + 1 < n && jsDateIsDigit(a[i + 1])
            let offsetOK = hour != nil || afterZone
            let canOffset = offsetOK && (offsetMin == nil || (afterZone && offsetMin == 0))
            if hasDigit && canOffset {
                let neg = c == 0x2d
                i += 1
                var v = 0, cnt = 0
                while i < n && jsDateIsDigit(a[i]) && cnt < 4 { v = v * 10 + Int(a[i] - 0x30); cnt += 1; i += 1 }
                var oh = 0, om = 0
                if cnt <= 2 {
                    oh = v
                    if i < n && a[i] == 0x3a {
                        i += 1
                        var mc = 0, mv = 0
                        while i < n && jsDateIsDigit(a[i]) && mc < 2 { mv = mv * 10 + Int(a[i] - 0x30); mc += 1; i += 1 }
                        guard mc == 2 else { return nan }
                        om = mv
                    }
                } else if cnt == 4 {
                    oh = v / 100; om = v % 100
                } else { return nan }
                guard oh <= 23, om <= 59 else { return nan }
                offsetMin = (neg ? -1 : 1) * (oh * 60 + om)
                afterZone = false; lastWasNumber = false
                continue
            }
            if c == 0x2d && prevSpace && hasDigit && !negNext {
                // "-0001": a negative year (toString of years before 0)
                negNext = true; i += 1; continue
            }
            if c == 0x2d { i += 1; continue }  // "19-Nov-2026", "2026-11-19"
            return nan
        }
        if c == 0x2f || c == 0x2e {
            i += 1; lastWasNumber = false; continue
        }
        return nan
    }
    if negNext { return nan }

    func fixYear(_ x: JSDateNum) -> Int {
        if x.negated { return -x.value }
        if x.digits <= 2 { return x.value < 50 ? 2000 + x.value : 1900 + x.value }
        return x.value
    }
    var year = 0, mon = 0, day = 1
    var neg: JSDateNum? = nil
    var rest: [JSDateNum] = []
    for x in nums { if x.negated { neg = x } else { rest.append(x) } }
    if let m = month {
        mon = m
        if let ny = neg {
            guard rest.count == 1 else { return nan }
            year = fixYear(ny); day = rest[0].value
        } else if rest.count == 2 {
            if rest[0].digits >= 3 || rest[0].value > 31 {
                year = fixYear(rest[0]); day = rest[1].value
            } else {
                day = rest[0].value; year = fixYear(rest[1])
            }
        } else if rest.count == 1 && (rest[0].digits >= 3 || rest[0].value > 31) {
            year = fixYear(rest[0]); day = 1
        } else { return nan }
    } else {
        guard neg == nil, rest.count == 3 else { return nan }
        if rest[0].digits >= 3 || rest[0].value > 31 {
            year = fixYear(rest[0]); mon = rest[1].value; day = rest[2].value
        } else {
            mon = rest[0].value; day = rest[1].value; year = fixYear(rest[2])
        }
    }
    guard mon >= 1, mon <= 12, day >= 1, year.magnitude < 400_000,
          day <= jsDateDaysInMonth(year, mon - 1) else { return nan }
    var h = hour ?? 0
    if ampm != 0 {
        guard h >= 1, h <= 12 else { return nan }
        if h == 12 { h = 0 }
        if ampm == 2 { h += 12 }
    }
    if h == 24 {
        guard minute == 0, second == 0, ms == 0 else { return nan }
    } else {
        guard h < 24 else { return nan }
    }
    guard minute < 60, second < 60 else { return nan }
    let dayN = jsDateMakeDay(Double(year), Double(mon - 1), Double(day))
    var t = jsDateMakeDate(dayN, jsDateMakeTime(Double(h), Double(minute), Double(second), Double(ms)))
    if let o = offsetMin { t -= Double(o) * 60_000 } else { t = jsDateUTC(t, zone) }
    return jsDateTimeClip(t)
}

public func jsDateParse<C: RandomAccessCollection>(_ s: C, _ zone: JSDateZone = .utc) -> Double
where C.Element: FixedWidthInteger, C.Index == Int {
    let n = s.count
    guard n > 0, n <= jsDateMaxParseLength else { return Double.nan }
    var a: [UInt8] = []
    a.reserveCapacity(n)
    for i in s.startIndex..<s.endIndex {
        let u = UInt32(truncatingIfNeeded: s[i])
        a.append(u < 0x80 ? UInt8(u) : 0xff)
    }
    // Trim ASCII whitespace.
    var lo = 0, hi = a.count
    while lo < hi && (a[lo] == 0x20 || a[lo] == 0x09 || a[lo] == 0x0a || a[lo] == 0x0d) { lo += 1 }
    while hi > lo && (a[hi - 1] == 0x20 || a[hi - 1] == 0x09 || a[hi - 1] == 0x0a || a[hi - 1] == 0x0d) { hi -= 1 }
    if lo >= hi { return Double.nan }
    if lo != 0 || hi != a.count { a = Array(a[lo..<hi]) }
    switch jsDateParseISO(a, zone) {
    case .ok(let v): return v
    case .invalid: return Double.nan
    case .noMatch: return jsDateParseLegacy(a, zone)
    }
}

// MARK: Formatting

func jsDateAppendInt(_ out: inout [UInt8], _ v: Int, _ width: Int) {
    var digits: [UInt8] = []
    var x = v < 0 ? -v : v
    if x == 0 { digits.append(0x30) }
    while x > 0 { digits.append(UInt8(x % 10) + 0x30); x /= 10 }
    var k = digits.count
    while k < width { out.append(0x30); k += 1 }
    var j = digits.count
    while j > 0 { j -= 1; out.append(digits[j]) }
}

func jsDateAppend(_ out: inout [UInt8], _ s: String) { out.append(contentsOf: Array(s.utf8)) }

let jsDateShortMonths = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
let jsDateShortDays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

func jsDateAppendYear(_ out: inout [UInt8], _ y: Int) {
    if y < 0 { out.append(0x2d) }
    jsDateAppendInt(&out, y, 4)
}

public func jsDateToISOString(_ t: Double) -> [UInt8]? {
    guard let f = jsDateFields(t), t.magnitude <= jsDateMaxTime else { return nil }
    var o: [UInt8] = []
    if f.year >= 0 && f.year <= 9999 {
        jsDateAppendInt(&o, f.year, 4)
    } else {
        o.append(f.year < 0 ? 0x2d : 0x2b)
        jsDateAppendInt(&o, f.year, 6)
    }
    o.append(0x2d); jsDateAppendInt(&o, f.month + 1, 2)
    o.append(0x2d); jsDateAppendInt(&o, f.day, 2)
    o.append(0x54); jsDateAppendInt(&o, f.hour, 2)
    o.append(0x3a); jsDateAppendInt(&o, f.minute, 2)
    o.append(0x3a); jsDateAppendInt(&o, f.second, 2)
    o.append(0x2e); jsDateAppendInt(&o, f.ms, 3)
    o.append(0x5a)
    return o
}

let jsDateInvalid: [UInt8] = Array("Invalid Date".utf8)

func jsDateAppendDatePart(_ o: inout [UInt8], _ f: JSDateFields) {
    jsDateAppend(&o, jsDateShortDays[f.weekday]); o.append(0x20)
    jsDateAppend(&o, jsDateShortMonths[f.month]); o.append(0x20)
    jsDateAppendInt(&o, f.day, 2); o.append(0x20)
    jsDateAppendYear(&o, f.year)
}

func jsDateAppendTimePart(_ o: inout [UInt8], _ f: JSDateFields, _ t: Double, _ zone: JSDateZone) {
    jsDateAppendInt(&o, f.hour, 2); o.append(0x3a)
    jsDateAppendInt(&o, f.minute, 2); o.append(0x3a)
    jsDateAppendInt(&o, f.second, 2)
    jsDateAppend(&o, " GMT")
    let off = Int(zone.offsetMs(utc: t) / 60_000)
    o.append(off < 0 ? 0x2d : 0x2b)
    let m = off < 0 ? -off : off
    jsDateAppendInt(&o, m / 60, 2); jsDateAppendInt(&o, m % 60, 2)
    let nm = zone.name(utc: t)
    if !nm.isEmpty { jsDateAppend(&o, " ("); o.append(contentsOf: nm); o.append(0x29) }
}

public func jsDateToString(_ t: Double, _ zone: JSDateZone = .utc) -> [UInt8] {
    guard t.isFinite, let f = jsDateFields(jsDateLocalTime(t, zone)) else { return jsDateInvalid }
    var o: [UInt8] = []
    jsDateAppendDatePart(&o, f); o.append(0x20)
    jsDateAppendTimePart(&o, f, t, zone)
    return o
}

public func jsDateToDateString(_ t: Double, _ zone: JSDateZone = .utc) -> [UInt8] {
    guard t.isFinite, let f = jsDateFields(jsDateLocalTime(t, zone)) else { return jsDateInvalid }
    var o: [UInt8] = []
    jsDateAppendDatePart(&o, f)
    return o
}

public func jsDateToTimeString(_ t: Double, _ zone: JSDateZone = .utc) -> [UInt8] {
    guard t.isFinite, let f = jsDateFields(jsDateLocalTime(t, zone)) else { return jsDateInvalid }
    var o: [UInt8] = []
    jsDateAppendTimePart(&o, f, t, zone)
    return o
}

public func jsDateToUTCString(_ t: Double) -> [UInt8] {
    guard let f = jsDateFields(t) else { return jsDateInvalid }
    var o: [UInt8] = []
    jsDateAppend(&o, jsDateShortDays[f.weekday]); jsDateAppend(&o, ", ")
    jsDateAppendInt(&o, f.day, 2); o.append(0x20)
    jsDateAppend(&o, jsDateShortMonths[f.month]); o.append(0x20)
    jsDateAppendYear(&o, f.year); o.append(0x20)
    jsDateAppendInt(&o, f.hour, 2); o.append(0x3a)
    jsDateAppendInt(&o, f.minute, 2); o.append(0x3a)
    jsDateAppendInt(&o, f.second, 2)
    jsDateAppend(&o, " GMT")
    return o
}

func jsDateAppendLocaleDate(_ o: inout [UInt8], _ f: JSDateFields) {
    jsDateAppendInt(&o, f.month + 1, 1); o.append(0x2f)
    jsDateAppendInt(&o, f.day, 1); o.append(0x2f)
    if f.year < 0 { o.append(0x2d) }
    jsDateAppendInt(&o, f.year, 1)
}

func jsDateAppendLocaleTime(_ o: inout [UInt8], _ f: JSDateFields) {
    let h12 = f.hour % 12 == 0 ? 12 : f.hour % 12
    jsDateAppendInt(&o, h12, 1); o.append(0x3a)
    jsDateAppendInt(&o, f.minute, 2); o.append(0x3a)
    jsDateAppendInt(&o, f.second, 2)
    jsDateAppend(&o, f.hour < 12 ? " AM" : " PM")
}

public func jsDateToLocaleString(_ t: Double, _ zone: JSDateZone = .utc) -> [UInt8] {
    guard t.isFinite, let f = jsDateFields(jsDateLocalTime(t, zone)) else { return jsDateInvalid }
    var o: [UInt8] = []
    jsDateAppendLocaleDate(&o, f); jsDateAppend(&o, ", "); jsDateAppendLocaleTime(&o, f)
    return o
}

public func jsDateToLocaleDateString(_ t: Double, _ zone: JSDateZone = .utc) -> [UInt8] {
    guard t.isFinite, let f = jsDateFields(jsDateLocalTime(t, zone)) else { return jsDateInvalid }
    var o: [UInt8] = []
    jsDateAppendLocaleDate(&o, f)
    return o
}

public func jsDateToLocaleTimeString(_ t: Double, _ zone: JSDateZone = .utc) -> [UInt8] {
    guard t.isFinite, let f = jsDateFields(jsDateLocalTime(t, zone)) else { return jsDateInvalid }
    var o: [UInt8] = []
    jsDateAppendLocaleTime(&o, f)
    return o
}
