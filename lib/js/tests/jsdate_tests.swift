// Host tests for jsdate.swift.

func jsDateTests(_ t: Tests) {
    func P(_ s: String) -> Double { jsDateParse(Array(s.utf8)) }
    func S(_ b: [UInt8]?) -> String { b.map { String(decoding: $0, as: UTF8.self) } ?? "nil" }
    func eqNum(_ got: Double, _ want: Double, _ label: String) {
        let ok = (got.isNaN && want.isNaN) || (got == want && got.sign == want.sign)
        t.check(ok, label, "got \(got), want \(want)")
    }

    t.section("date math")
    t.equal(jsDateYearFromTime(0), 1970, "year 0")
    t.equal(jsDateWeekDay(0), 4, "weekday of epoch")
    t.equal(jsDateMonthFromTime(951782400000), 1, "feb 29 2000 month")
    t.equal(jsDateDateFromTime(951782400000), 29, "feb 29 2000 date")
    t.equal(jsDateDateFromTime(-1), 31, "-1 is Dec 31 1969")
    t.equal(jsDateHourFromTime(-1), 23, "-1 hour")
    t.equal(jsDateMsFromTime(-1), 999, "-1 ms")
    t.equal(S(jsDateToISOString(jsDateMaxTime)), "+275760-09-13T00:00:00.000Z", "max time")
    t.equal(S(jsDateToISOString(-jsDateMaxTime)), "-271821-04-20T00:00:00.000Z", "min time")
    t.equal(S(jsDateToISOString(1e12)), "2001-09-09T01:46:40.000Z", "1e12")
    t.equal(S(jsDateToISOString(Double.nan)), "nil", "iso nan")
    eqNum(jsDateTimeClip(8.64e15 + 1), .nan, "clip over")
    eqNum(jsDateTimeClip(8.64e15), 8.64e15, "clip max")
    eqNum(jsDateTimeClip(-0.0), 0.0, "clip -0")
    eqNum(jsDateTimeClip(1.9), 1, "clip trunc")
    eqNum(jsDateTimeClip(-1.9), -1, "clip trunc neg")
    eqNum(jsDateTimeClip(.infinity), .nan, "clip inf")
    eqNum(jsDateMakeDay(2000, 12, 1), jsDateMakeDay(2001, 0, 1), "month 12 rolls")
    eqNum(jsDateMakeDay(2000, -1, 1), jsDateMakeDay(1999, 11, 1), "month -1 rolls")
    eqNum(jsDateMakeDay(2000, 1, 30), jsDateMakeDay(2000, 2, 1), "feb 30 leap")
    eqNum(jsDateMakeDay(1970, 0, 1), 0, "makeday epoch")
    eqNum(jsDateMakeDay(.nan, 0, 1), .nan, "makeday nan")
    eqNum(jsDateMakeDay(1970, .infinity, 1), .nan, "makeday inf")
    eqNum(jsDateMakeDay(1e9, 0, 1), .nan, "makeday huge year")
    eqNum(jsDateMakeDay(1970, 0, 1.9), 0, "makeday trunc date")
    eqNum(jsDateMakeTime(1, 2, 3, 4), 3_723_004, "maketime")
    eqNum(jsDateMakeTime(1, .nan, 3, 4), .nan, "maketime nan")
    eqNum(jsDateMakeTime(-1.5, 0, 0, 0), -3_600_000, "maketime trunc")
    eqNum(jsDateMakeDate(1, 5), 86_400_005, "makedate")
    eqNum(jsDateMakeDate(.infinity, 5), .nan, "makedate inf")
    eqNum(jsDateMakeDate(1e305, 1e300), .nan, "makedate overflow")
    eqNum(jsDateDaysInYear(1900), 365, "1900")
    eqNum(jsDateDaysInYear(2000), 366, "2000")
    eqNum(jsDateDaysInYear(2024), 366, "2024")
    eqNum(jsDateDaysInYear(-1), 365, "-1")
    eqNum(jsDateDaysInYear(0), 366, "year 0 leap")
    eqNum(jsDateDay(-1), -1, "day(-1)")
    eqNum(jsDateTimeWithinDay(-1), 86_399_999, "twd(-1)")
    eqNum(jsDateFromComponents(99, 0, 1, 0, 0, 0, 0), jsDateMakeDate(jsDateMakeDay(1999, 0, 1), 0), "yr 99")
    eqNum(jsDateFromComponents(100, 0, 1, 0, 0, 0, 0), jsDateMakeDate(jsDateMakeDay(100, 0, 1), 0), "yr 100")
    eqNum(jsDateFromComponents(-1, 0, 1, 0, 0, 0, 0), jsDateMakeDate(jsDateMakeDay(-1, 0, 1), 0), "yr -1")
    let y0 = jsDateMakeDate(jsDateMakeDay(0, 0, 1), 0)
    t.equal(S(jsDateToISOString(y0)), "0000-01-01T00:00:00.000Z", "year 0 iso")
    t.equal(S(jsDateToISOString(jsDateMakeDate(jsDateMakeDay(-1, 0, 1), 0))), "-000001-01-01T00:00:00.000Z", "year -1 iso")
    t.equal(S(jsDateToISOString(jsDateMakeDate(jsDateMakeDay(10000, 0, 1), 0))), "+010000-01-01T00:00:00.000Z", "year 10000 iso")
    eqNum(y0, -62_167_219_200_000, "year 0 value")

    var bad = 0
    var tv = -jsDateMaxTime
    while tv <= jsDateMaxTime {
        guard let f = jsDateFields(tv) else { bad += 1; break }
        let r = jsDateMakeDate(jsDateMakeDay(Double(f.year), Double(f.month), Double(f.day)),
                               jsDateMakeTime(Double(f.hour), Double(f.minute), Double(f.second), Double(f.ms)))
        if r != tv { bad += 1 }
        tv += 8_640_000_007_919
    }
    t.equal(bad, 0, "fields round trip")
    bad = 0
    var d = -800_000
    while d < 800_000 {
        let (y, m, dd) = jsDateCivilFromDays(d)
        if jsDateDaysFromCivil(y, m, dd) != d { bad += 1 }
        d += 1
    }
    t.equal(bad, 0, "civil round trip")

    t.section("zones")
    let est = JSDateZone(baseOffsetMinutes: -300, baseName: Array("EST".utf8))
    eqNum(jsDateLocalTime(0, est), -18_000_000, "local est")
    eqNum(jsDateUTC(-18_000_000, est), 0, "utc est")
    eqNum(jsDateTimezoneOffsetMinutes(0, est), 300, "tz offset")
    eqNum(jsDateTimezoneOffsetMinutes(0), 0, "tz offset utc")
    let dst = JSDateZone(baseOffsetMinutes: -300, baseName: Array("EST".utf8), transitions: [
        JSDateZoneTransition(startUTC: 1_000_000_000_000, offsetMinutes: -240, name: Array("EDT".utf8))])
    eqNum(dst.offsetMs(utc: 0), -18_000_000, "before transition")
    eqNum(dst.offsetMs(utc: 1_000_000_000_000), -14_400_000, "after transition")
    eqNum(jsDateUTC(1_000_000_000_000 - 14_400_000, dst), 1_000_000_000_000, "local after")
    t.equal(S(jsDateToString(0, est)), "Wed Dec 31 1969 19:00:00 GMT-0500 (EST)", "toString zone")

    t.section("parse: ISO")
    let nov19 = 1_795_046_400_000.0
    eqNum(P("2026-11-19"), nov19, "date only")
    eqNum(P("2026-11"), nov19 - 18 * 86_400_000, "year-month")
    eqNum(P("2026"), 1_767_225_600_000, "year only")
    eqNum(P("2026-11-19T14:00:00Z"), 1_795_096_800_000, "Z")
    eqNum(P("2026-11-19T14:00Z"), 1_795_096_800_000, "no seconds")
    eqNum(P("2026-11-19T14:00:00.123Z"), 1_795_096_800_123, "ms")
    eqNum(P("2026-11-19T14:00:00.1Z"), 1_795_096_800_100, "ms 1 digit")
    eqNum(P("2026-11-19T14:00:00.123456Z"), 1_795_096_800_123, "ms truncated")
    eqNum(P("2026-11-19T14:00:00+05:30"), 1_795_096_800_000 - 19_800_000, "offset")
    eqNum(P("2026-11-19T14:00:00-08:00"), 1_795_096_800_000 + 28_800_000, "neg offset")
    eqNum(P("2026-11-19T14:00:00"), 1_795_096_800_000, "local = UTC for now")
    eqNum(P("2026-11-19T24:00:00Z"), nov19 + 86_400_000, "24:00")
    eqNum(P("2026-11-19T24:00:01Z"), .nan, "24:00:01")
    eqNum(P("2026-11-19T25:00:00Z"), .nan, "25h")
    eqNum(P("2026-13-01"), .nan, "month 13")
    eqNum(P("2026-02-29"), .nan, "feb 29 non-leap")
    eqNum(P("2024-02-29"), 1_709_164_800_000, "feb 29 leap")
    eqNum(P("2026-11-19T14:60:00Z"), .nan, "min 60")
    eqNum(P("+275760-09-13T00:00:00.000Z"), 8.64e15, "max")
    eqNum(P("+275760-09-13T00:00:00.001Z"), .nan, "max+1")
    eqNum(P("-271821-04-20T00:00:00.000Z"), -8.64e15, "min")
    eqNum(P("-271821-04-19T23:59:59.999Z"), .nan, "min-1")
    eqNum(P("-000000-01-01T00:00:00Z"), .nan, "-000000")
    eqNum(P("+000000-01-01T00:00:00Z"), y0, "+000000")
    eqNum(P("-000001-01-01T00:00:00Z"), jsDateMakeDate(jsDateMakeDay(-1, 0, 1), 0), "-000001")
    eqNum(P("1970-01-01T00:00:00Z"), 0, "epoch")
    eqNum(P("  2026-11-19  "), nov19, "trimmed")
    eqNum(P(""), .nan, "empty")
    eqNum(P("x"), .nan, "junk")

    t.section("parse: legacy")
    let thu = 1_795_096_800_000.0
    eqNum(P("Thu Nov 19 2026 14:00:00 GMT+0000 (Coordinated Universal Time)"), thu, "toString")
    eqNum(P("Thu Nov 19 2026 14:00:00 GMT+0100 (CET)"), thu - 3_600_000, "toString +0100")
    eqNum(P("Thu, 19 Nov 2026 14:00:00 GMT"), thu, "toUTCString")
    eqNum(P("Tue, 19 Nov 2026 14:00:00 GMT"), thu, "wrong weekday ignored")
    eqNum(P("Thu, 19 Nov 2026 14:00:00 UTC"), thu, "UTC")
    eqNum(P("Thu, 19 Nov 2026 14:00:00 UT"), thu, "UT")
    eqNum(P("Thu, 19 Nov 2026 14:00:00 Z"), thu, "Z word")
    eqNum(P("Thu, 19 Nov 2026 09:00:00 EST"), thu, "EST")
    eqNum(P("Thu, 19 Nov 2026 10:00:00 EDT"), thu, "EDT")
    eqNum(P("Thu, 19 Nov 2026 08:00:00 CST"), thu, "CST")
    eqNum(P("Thu, 19 Nov 2026 09:00:00 CDT"), thu, "CDT")
    eqNum(P("Thu, 19 Nov 2026 07:00:00 MST"), thu, "MST")
    eqNum(P("Thu, 19 Nov 2026 08:00:00 MDT"), thu, "MDT")
    eqNum(P("Thu, 19 Nov 2026 06:00:00 PST"), thu, "PST")
    eqNum(P("Thu, 19 Nov 2026 07:00:00 PDT"), thu, "PDT")
    eqNum(P("Thu, 19 Nov 2026 14:00:00 +0000"), thu, "+0000")
    eqNum(P("Thu, 19 Nov 2026 14:00:00 -0500"), thu + 18_000_000, "-0500")
    eqNum(P("Thu, 19 Nov 2026 14:00:00 +05:30"), thu - 19_800_000, "+05:30")
    eqNum(P("Thu, 19 Nov 2026 14:00 GMT"), thu, "no seconds")
    eqNum(P("Nov 19 2026"), nov19, "Nov 19 2026")
    eqNum(P("Nov 19, 2026"), nov19, "Nov 19, 2026")
    eqNum(P("19 Nov 2026"), nov19, "19 Nov 2026")
    eqNum(P("19-Nov-2026"), nov19, "19-Nov-2026")
    eqNum(P("November 19, 2026"), nov19, "November 19, 2026")
    eqNum(P("November 19, 2026 10:00:00"), 1_795_082_400_000, "November with time")
    eqNum(P("Nov 19th 2026"), nov19, "ordinal")
    eqNum(P("2026/11/19"), nov19, "2026/11/19")
    eqNum(P("2026/11/19 14:00"), thu, "2026/11/19 14:00")
    eqNum(P("2026-11-19 14:00:00"), thu, "space separated")
    eqNum(P("2026-11-19 14:00:00 GMT"), thu, "space + GMT")
    eqNum(P("11/19/2026"), nov19, "m/d/y")
    eqNum(P("11/19/2026 2:00 PM"), thu, "pm")
    eqNum(P("11/19/2026, 2:00:00 PM"), thu, "toLocaleString form")
    eqNum(P("11/19/2026 12:00 AM"), nov19, "12 am")
    eqNum(P("11/19/2026 12:30 PM"), nov19 + 12.5 * 3_600_000, "12:30 pm")
    eqNum(P("11/19/2026 13:00 PM"), .nan, "13 pm")
    eqNum(P("11/19/26"), nov19, "2-digit year")
    eqNum(P("11/19/99"), P("11/19/1999"), "2-digit year 99")
    eqNum(P("Sat Jan 01 -0001 00:00:00 GMT+0000"), jsDateMakeDate(jsDateMakeDay(-1, 0, 1), 0), "negative year toString")
    eqNum(P("Sat, 01 Jan -0001 00:00:00 GMT"), jsDateMakeDate(jsDateMakeDay(-1, 0, 1), 0), "negative year utc")
    eqNum(P("Sat Jan 01 0000 00:00:00 GMT+0000"), y0, "year 0 toString")
    eqNum(P("Nov 31 2026"), .nan, "nov 31")
    eqNum(P("Foo 19 2026"), .nan, "bad month")
    eqNum(P("Nov 19"), .nan, "no year")
    eqNum(P("19 2026"), .nan, "no month")
    eqNum(P("Nov 19 2026 25:00"), .nan, "bad hour")
    eqNum(P("Nov 19 2026 10:00 GMT GMT"), .nan, "double zone")
    eqNum(P("Nov 19 2026 (unterminated"), .nan, "open paren")
    eqNum(P("Nov 19 2026 \u{e9}"), .nan, "non ascii")
    for tv2 in [0.0, thu, -1.0, 8.64e15, -8.64e15, y0, 1e12, -62_198_755_200_000] {
        let secs = tv2 - jsDateMsFromTime(tv2)
        eqNum(P(S(jsDateToString(tv2))), secs, "roundtrip toString \(tv2)")
        eqNum(P(S(jsDateToUTCString(tv2))), secs, "roundtrip toUTCString \(tv2)")
        eqNum(P(S(jsDateToISOString(tv2))), tv2, "roundtrip iso \(tv2)")
    }
    eqNum(jsDateParse(Array("2026-11-19".utf16)), nov19, "utf16 input")
    eqNum(jsDateParse([UInt16](repeating: 0x31, count: 600)), .nan, "too long")

    t.section("format")
    t.equal(S(jsDateToString(thu)), "Thu Nov 19 2026 14:00:00 GMT+0000 (Coordinated Universal Time)", "toString")
    t.equal(S(jsDateToDateString(thu)), "Thu Nov 19 2026", "toDateString")
    t.equal(S(jsDateToTimeString(thu)), "14:00:00 GMT+0000 (Coordinated Universal Time)", "toTimeString")
    t.equal(S(jsDateToUTCString(thu)), "Thu, 19 Nov 2026 14:00:00 GMT", "toUTCString")
    t.equal(S(jsDateToLocaleString(thu)), "11/19/2026, 2:00:00 PM", "toLocaleString")
    t.equal(S(jsDateToLocaleDateString(thu)), "11/19/2026", "toLocaleDateString")
    t.equal(S(jsDateToLocaleTimeString(thu)), "2:00:00 PM", "toLocaleTimeString")
    t.equal(S(jsDateToLocaleTimeString(0)), "12:00:00 AM", "midnight")
    t.equal(S(jsDateToLocaleTimeString(12 * 3_600_000)), "12:00:00 PM", "noon")
    t.equal(S(jsDateToISOString(thu + 5)), "2026-11-19T14:00:00.005Z", "iso ms pad")
    t.equal(S(jsDateToString(.nan)), "Invalid Date", "invalid toString")
    t.equal(S(jsDateToUTCString(.nan)), "Invalid Date", "invalid toUTCString")
    t.equal(S(jsDateToLocaleString(.nan)), "Invalid Date", "invalid locale")
    t.equal(S(jsDateToString(y0)), "Sat Jan 01 0000 00:00:00 GMT+0000 (Coordinated Universal Time)", "year 0 toString")
    t.equal(S(jsDateToString(jsDateMakeDate(jsDateMakeDay(-1, 0, 1), 0))), "Fri Jan 01 -0001 00:00:00 GMT+0000 (Coordinated Universal Time)", "year -1 toString")

    t.section("parse fuzz")
    let seedStrings = [
        "2026-11-19T14:00:00.123+05:30", "Thu, 19 Nov 2026 14:00:00 GMT", "Nov 19 2026",
        "2026/11/19 14:00", "November 19, 2026 10:00:00", "+275760-09-13T00:00:00.000Z",
        "Thu Nov 19 2026 14:00:00 GMT+0000 (Coordinated Universal Time)", "11/19/2026, 2:00:00 PM",
        "-271821-04-20T00:00:00.000Z", "99999999999999999999-1-1",
    ]
    var seeds: [[UInt8]] = []
    for s in seedStrings { seeds.append(Array(s.utf8)) }
    t.fuzz("jsdate", seeds: seeds, iterations: 20000) { b in
        let v = jsDateParse(b)
        if !v.isNaN && (v.magnitude > jsDateMaxTime || v != jsTrunc(v)) { t.check(false, "parse result out of range") }
    }
}
