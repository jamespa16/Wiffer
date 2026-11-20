// Intl.DateTimeFormat and Intl.RelativeTimeFormat (en-US), plus Date's
// toLocale*String routes. See jsintl.swift for the overall design.
//
// DateTimeFormat supports weekday / year / month / day / hour / minute /
// second / fractionalSecondDigits / timeZoneName, dateStyle and timeStyle,
// hour12 and hourCycle, formatToParts, formatRange. Time zones: "UTC", fixed
// offsets ("+05:30") and a table of common IANA names with their US / EU /
// Australian / New Zealand DST rules; the default zone is the realm's
// `dateZone` (UTC unless the embedder set one).

struct JSIntlTZ {
    var id = "UTC"
    var std = 0             // standard offset, minutes
    var rule = 0            // 0 none, 1 US, 2 EU, 3 Sydney, 4 Auckland
    var stdLong = "Coordinated Universal Time"
    var dstLong = ""
    var stdShort = "UTC"
    var dstShort = ""
    var realm: JSDateZone? = nil    // the embedder's zone (default)
}

/// Day of month of the n-th (1-based) or last (n = 0) Sunday of a month.
func jsIntlSunday(_ year: Int, _ month: Int, _ n: Int) -> Int {
    let dim = jsDateDaysInMonth(year, month - 1)
    func wd(_ d: Int) -> Int { jsDateModFloor(jsDateDaysFromCivil(year, month, d) + 4, 7) }
    if n == 0 {
        var d = dim
        while wd(d) != 0 { d -= 1 }
        return d
    }
    var d = 1
    while wd(d) != 0 { d += 1 }
    return d + 7 * (n - 1)
}

func jsIntlUTCms(_ y: Int, _ m: Int, _ d: Int, minutes: Int) -> Double {
    Double(jsDateDaysFromCivil(y, m, d)) * 86_400_000 + Double(minutes) * 60_000
}

extension JSIntlTZ {
    /// (offset minutes, in DST) at UTC time t.
    func offset(_ t: Double) -> (Int, Bool) {
        if let z = realm { return (z.offsetMinutes(utc: t.isNaN ? 0 : t).0, false) }
        if rule == 0 { return (std, false) }
        guard let f = jsDateFields(t + Double(std) * 60_000) else { return (std, false) }
        let y = f.year
        var dst = false
        switch rule {
        case 1:
            let s = jsIntlUTCms(y, 3, jsIntlSunday(y, 3, 2), minutes: 120 - std)
            let e = jsIntlUTCms(y, 11, jsIntlSunday(y, 11, 1), minutes: 120 - (std + 60))
            dst = t >= s && t < e
        case 2:
            let s = jsIntlUTCms(y, 3, jsIntlSunday(y, 3, 0), minutes: 60)
            let e = jsIntlUTCms(y, 10, jsIntlSunday(y, 10, 0), minutes: 60)
            dst = t >= s && t < e
        case 3:
            let s = jsIntlUTCms(y, 10, jsIntlSunday(y, 10, 1), minutes: 120 - std)
            let e = jsIntlUTCms(y, 4, jsIntlSunday(y, 4, 1), minutes: 180 - (std + 60))
            dst = t >= s || t < e
        default:
            let s = jsIntlUTCms(y, 9, jsIntlSunday(y, 9, 0), minutes: 120 - std)
            let e = jsIntlUTCms(y, 4, jsIntlSunday(y, 4, 1), minutes: 180 - (std + 60))
            dst = t >= s || t < e
        }
        return (dst ? std + 60 : std, dst)
    }

    func gmtOffsetText(_ minutes: Int, long: Bool) -> String {
        if minutes == 0 { return "GMT" }
        let a = minutes < 0 ? -minutes : minutes
        var s = "GMT" + (minutes < 0 ? "-" : "+")
        if long {
            s += (a / 60 < 10 ? "0" : "") + String(a / 60) + ":" + (a % 60 < 10 ? "0" : "") + String(a % 60)
        } else {
            s += String(a / 60)
            if a % 60 != 0 { s += ":" + (a % 60 < 10 ? "0" : "") + String(a % 60) }
        }
        return s
    }

    /// timeZoneName text: kind 1 short, 2 long, 3 shortOffset, 4 longOffset.
    func displayName(_ t: Double, kind: Int) -> String {
        let (off, dst) = offset(t)
        if kind == 3 { return gmtOffsetText(off, long: false) }
        if kind == 4 { return gmtOffsetText(off, long: true) }
        if realm != nil {
            if off == 0 { return kind == 2 ? "Coordinated Universal Time" : "UTC" }
            return gmtOffsetText(off, long: kind == 2)
        }
        if kind == 2 {
            let l = dst ? dstLong : stdLong
            return l.isEmpty ? gmtOffsetText(off, long: true) : l
        }
        let sh = dst ? dstShort : stdShort
        return sh.isEmpty ? gmtOffsetText(off, long: false) : sh
    }
}

/// Table of zones: lowercase name -> (canonical id, std offset, rule, names).
func jsIntlZoneLookup(_ name: String) -> JSIntlTZ? {
    var lower: [UInt8] = []
    for b in name.utf8 { lower.append(b >= 0x41 && b <= 0x5A ? b + 32 : b) }
    let n = String(decoding: lower, as: UTF8.self)
    func z(_ id: String, _ std: Int, _ rule: Int, _ sl: String, _ dl: String, _ ss: String, _ ds: String) -> JSIntlTZ {
        var t = JSIntlTZ()
        t.id = id; t.std = std; t.rule = rule; t.stdLong = sl; t.dstLong = dl; t.stdShort = ss; t.dstShort = ds
        return t
    }
    switch n {
    case "utc", "gmt", "etc/utc", "etc/gmt", "z", "etc/zulu", "zulu", "etc/uct", "uct": return z("UTC", 0, 0, "Coordinated Universal Time", "", "UTC", "")
    case "america/new_york", "us/eastern", "america/toronto", "america/detroit": return z(n == "america/toronto" ? "America/Toronto" : "America/New_York", -300, 1, "Eastern Standard Time", "Eastern Daylight Time", "EST", "EDT")
    case "america/chicago", "us/central", "america/winnipeg": return z("America/Chicago", -360, 1, "Central Standard Time", "Central Daylight Time", "CST", "CDT")
    case "america/denver", "us/mountain": return z("America/Denver", -420, 1, "Mountain Standard Time", "Mountain Daylight Time", "MST", "MDT")
    case "america/phoenix": return z("America/Phoenix", -420, 0, "Mountain Standard Time", "", "MST", "")
    case "america/los_angeles", "us/pacific", "america/vancouver": return z(n == "america/vancouver" ? "America/Vancouver" : "America/Los_Angeles", -480, 1, "Pacific Standard Time", "Pacific Daylight Time", "PST", "PDT")
    case "america/anchorage": return z("America/Anchorage", -540, 1, "Alaska Standard Time", "Alaska Daylight Time", "AKST", "AKDT")
    case "pacific/honolulu": return z("Pacific/Honolulu", -600, 0, "Hawaii-Aleutian Standard Time", "", "HST", "")
    case "america/mexico_city": return z("America/Mexico_City", -360, 0, "Central Standard Time", "", "CST", "")
    case "america/sao_paulo": return z("America/Sao_Paulo", -180, 0, "Brasilia Standard Time", "", "", "")
    case "america/argentina/buenos_aires", "america/buenos_aires": return z("America/Argentina/Buenos_Aires", -180, 0, "Argentina Standard Time", "", "", "")
    case "europe/london": return z("Europe/London", 0, 2, "Greenwich Mean Time", "British Summer Time", "GMT", "")
    case "europe/dublin": return z("Europe/Dublin", 0, 2, "Greenwich Mean Time", "Irish Standard Time", "GMT", "")
    case "europe/lisbon": return z("Europe/Lisbon", 0, 2, "Western European Standard Time", "Western European Summer Time", "", "")
    case "europe/paris", "europe/berlin", "europe/madrid", "europe/rome", "europe/amsterdam", "europe/brussels",
         "europe/vienna", "europe/zurich", "europe/stockholm", "europe/oslo", "europe/copenhagen", "europe/prague",
         "europe/warsaw", "europe/budapest":
        // Canonical id: capitalize after the start and each "/" or "_".
        var idb: [UInt8] = []
        var up = true
        for ch in name.utf8 {
            if ch == 0x2F || ch == 0x5F { idb.append(ch); up = true; continue }
            let lc = ch >= 0x41 && ch <= 0x5A ? ch + 32 : ch
            idb.append(up && lc >= 0x61 && lc <= 0x7A ? lc - 32 : lc)
            up = false
        }
        let id = String(decoding: idb, as: UTF8.self)
        return z(id, 60, 2, "Central European Standard Time", "Central European Summer Time", "", "")
    case "europe/athens", "europe/helsinki", "europe/kiev", "europe/kyiv", "europe/bucharest", "europe/sofia":
        let id = n == "europe/athens" ? "Europe/Athens" : n == "europe/helsinki" ? "Europe/Helsinki" : n == "europe/bucharest" ? "Europe/Bucharest" : n == "europe/sofia" ? "Europe/Sofia" : "Europe/Kiev"
        return z(id, 120, 2, "Eastern European Standard Time", "Eastern European Summer Time", "", "")
    case "europe/moscow": return z("Europe/Moscow", 180, 0, "Moscow Standard Time", "", "", "")
    case "europe/istanbul": return z("Europe/Istanbul", 180, 0, "GMT+03:00", "", "", "")
    case "asia/tokyo": return z("Asia/Tokyo", 540, 0, "Japan Standard Time", "", "", "")
    case "asia/seoul": return z("Asia/Seoul", 540, 0, "Korean Standard Time", "", "", "")
    case "asia/shanghai": return z("Asia/Shanghai", 480, 0, "China Standard Time", "", "", "")
    case "asia/hong_kong": return z("Asia/Hong_Kong", 480, 0, "Hong Kong Standard Time", "", "", "")
    case "asia/singapore": return z("Asia/Singapore", 480, 0, "Singapore Standard Time", "", "", "")
    case "asia/kolkata", "asia/calcutta": return z("Asia/Calcutta", 330, 0, "India Standard Time", "", "", "")
    case "asia/dubai": return z("Asia/Dubai", 240, 0, "Gulf Standard Time", "", "", "")
    case "asia/bangkok": return z("Asia/Bangkok", 420, 0, "Indochina Time", "", "", "")
    case "asia/jakarta": return z("Asia/Jakarta", 420, 0, "Western Indonesia Time", "", "", "")
    case "asia/karachi": return z("Asia/Karachi", 300, 0, "Pakistan Standard Time", "", "", "")
    case "asia/manila": return z("Asia/Manila", 480, 0, "Philippine Standard Time", "", "", "")
    case "australia/sydney", "australia/melbourne": return z(n == "australia/sydney" ? "Australia/Sydney" : "Australia/Melbourne", 600, 3, "Australian Eastern Standard Time", "Australian Eastern Daylight Time", "", "")
    case "australia/brisbane": return z("Australia/Brisbane", 600, 0, "Australian Eastern Standard Time", "", "", "")
    case "australia/perth": return z("Australia/Perth", 480, 0, "Australian Western Standard Time", "", "", "")
    case "pacific/auckland": return z("Pacific/Auckland", 720, 4, "New Zealand Standard Time", "New Zealand Daylight Time", "", "")
    case "africa/johannesburg": return z("Africa/Johannesburg", 120, 0, "South Africa Standard Time", "", "", "")
    case "africa/cairo": return z("Africa/Cairo", 120, 0, "Eastern European Standard Time", "", "", "")
    case "africa/lagos": return z("Africa/Lagos", 60, 0, "West Africa Standard Time", "", "", "")
    case "africa/nairobi": return z("Africa/Nairobi", 180, 0, "East Africa Time", "", "", "")
    default: return nil
    }
}

func jsIntlTimeZoneNames() -> [String] {
    ["Africa/Cairo", "Africa/Johannesburg", "Africa/Lagos", "Africa/Nairobi", "America/Anchorage", "America/Chicago",
     "America/Denver", "America/Los_Angeles", "America/Mexico_City", "America/New_York", "America/Phoenix",
     "America/Sao_Paulo", "America/Toronto", "America/Vancouver", "Asia/Bangkok", "Asia/Calcutta", "Asia/Dubai",
     "Asia/Hong_Kong", "Asia/Jakarta", "Asia/Karachi", "Asia/Manila", "Asia/Seoul", "Asia/Shanghai", "Asia/Singapore",
     "Asia/Tokyo", "Australia/Brisbane", "Australia/Melbourne", "Australia/Perth", "Australia/Sydney", "Europe/Amsterdam",
     "Europe/Athens", "Europe/Berlin", "Europe/Brussels", "Europe/Dublin", "Europe/Helsinki", "Europe/Istanbul",
     "Europe/Lisbon", "Europe/London", "Europe/Madrid", "Europe/Moscow", "Europe/Paris", "Europe/Rome", "Europe/Stockholm",
     "Europe/Vienna", "Europe/Warsaw", "Europe/Zurich", "Pacific/Auckland", "Pacific/Honolulu", "UTC"]
}

/// "+05:30", "-0800", "+01": a fixed offset zone.
func jsIntlOffsetZone(_ s: String) -> JSIntlTZ? {
    let b = Array(s.utf8)
    guard b.count >= 3, b[0] == 0x2B || b[0] == 0x2D else { return nil }
    func dig(_ i: Int) -> Int? { i < b.count && b[i] >= 0x30 && b[i] <= 0x39 ? Int(b[i] - 0x30) : nil }
    guard let h1 = dig(1), let h2 = dig(2) else { return nil }
    var m = 0
    if b.count == 5, let m1 = dig(3), let m2 = dig(4) { m = m1 * 10 + m2 }
    else if b.count == 6, b[3] == 0x3A, let m1 = dig(4), let m2 = dig(5) { m = m1 * 10 + m2 }
    else if b.count != 3 { return nil }
    let h = h1 * 10 + h2
    guard h < 24, m < 60 else { return nil }
    var t = JSIntlTZ()
    let total = (b[0] == 0x2D ? -1 : 1) * (h * 60 + m)
    t.std = total
    let a = total < 0 ? -total : total
    t.id = String(decoding: [b[0]], as: UTF8.self) + (a / 60 < 10 ? "0" : "") + String(a / 60) + ":" + (a % 60 < 10 ? "0" : "") + String(a % 60)
    t.stdLong = ""; t.stdShort = ""
    return t
}

// MARK: Options

struct JSIntlDateOptions {
    var weekday = 0, year = 0, month = 0, day = 0      // see intlDateCode tables
    var hour = 0, minute = 0, second = 0, fsd = 0, tzName = 0
    var dateStyle = 0, timeStyle = 0
    var hour12 = true
    var h23 = false             // hourCycle h23 / h24 (24-hour clock)
    var tz = JSIntlTZ()

    init() {}
    init(resolved o: JSValue, heap: JSHeap, realmZone: JSDateZone) {
        func code(_ k: String, _ names: [String]) -> Int {
            let v = heap.intlRawString(o, k)
            for (i, n) in names.enumerated() where n == v { return i + 1 }
            return 0
        }
        weekday = code("weekday", ["narrow", "short", "long"])
        year = code("year", ["numeric", "2-digit"])
        month = code("month", ["numeric", "2-digit", "narrow", "short", "long"])
        day = code("day", ["numeric", "2-digit"])
        hour = code("hour", ["numeric", "2-digit"])
        minute = code("minute", ["numeric", "2-digit"])
        second = code("second", ["numeric", "2-digit"])
        fsd = heap.intlRawInt(o, "fractionalSecondDigits", 0)
        tzName = code("timeZoneName", ["short", "long", "shortOffset", "longOffset", "shortGeneric", "longGeneric"])
        dateStyle = code("dateStyle", ["full", "long", "medium", "short"])
        timeStyle = code("timeStyle", ["full", "long", "medium", "short"])
        let hc = heap.intlRawString(o, "hourCycle", "h12")
        h23 = hc == "h23" || hc == "h24"
        hour12 = !h23
        let id = heap.intlRawString(o, "timeZone", "UTC")
        if let z = jsIntlZoneLookup(id) { tz = z }
        else if let z = jsIntlOffsetZone(id) { tz = z }
        else { tz = JSIntlTZ() }
        if heap.intlRawString(o, "_realmZone") == "1" { tz.realm = realmZone }
    }
}

let jsIntlMonthNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
let jsIntlDayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

func jsIntlPad(_ v: Int, _ w: Int) -> String {
    var s = String(v < 0 ? -v : v)
    while s.utf8.count < w { s = "0" + s }
    return v < 0 ? "-" + s : s
}

/// The en-US parts for time value t.
func jsIntlDateParts(_ t: Double, _ oIn: JSIntlDateOptions) -> [JSIntlPart] {
    var o = oIn
    // Styles expand to components.
    switch o.dateStyle {
    case 1: o.weekday = 3; o.month = 5; o.day = 1; o.year = 1
    case 2: o.month = 5; o.day = 1; o.year = 1
    case 3: o.month = 4; o.day = 1; o.year = 1
    case 4: o.month = 1; o.day = 1; o.year = 2
    default: break
    }
    switch o.timeStyle {
    case 1: o.hour = 1; o.minute = 2; o.second = 2; o.tzName = 2
    case 2: o.hour = 1; o.minute = 2; o.second = 2; o.tzName = 1
    case 3: o.hour = 1; o.minute = 2; o.second = 2
    case 4: o.hour = 1; o.minute = 2
    default: break
    }
    let (off, _) = o.tz.offset(t)
    guard let f = jsDateFields(t + Double(off) * 60_000) else { return [] }
    func lit(_ s: String) -> JSIntlPart { JSIntlPart(type: "literal", text: intlU16(s)) }
    func part(_ ty: String, _ s: String) -> JSIntlPart { JSIntlPart(type: ty, text: intlU16(s)) }
    var date: [JSIntlPart] = []
    // ---- date
    let wdText: String? = o.weekday == 0 ? nil : (o.weekday == 3 ? jsIntlDayNames[f.weekday] : o.weekday == 2 ? String(jsIntlDayNames[f.weekday].prefix(3)) : String(jsIntlDayNames[f.weekday].prefix(1)))
    var yText: String? = nil
    if o.year != 0 { yText = o.year == 2 ? jsIntlPad(((f.year % 100) + 100) % 100, 2) : String(f.year) }
    var dText: String? = nil
    if o.day != 0 { dText = o.day == 2 ? jsIntlPad(f.day, 2) : String(f.day) }
    if o.month >= 3 {
        let full = jsIntlMonthNames[f.month]
        let mText = o.month == 5 ? full : o.month == 4 ? String(full.prefix(3)) : String(full.prefix(1))
        if let w = wdText { date.append(part("weekday", w)); date.append(lit(", ")) }
        date.append(part("month", mText))
        if let d = dText { date.append(lit(" ")); date.append(part("day", d)) }
        if let y = yText { date.append(lit(dText != nil ? ", " : " ")); date.append(part("year", y)) }
    } else {
        var items: [JSIntlPart] = []
        if o.month != 0 { items.append(part("month", o.month == 2 ? jsIntlPad(f.month + 1, 2) : String(f.month + 1))) }
        if let d = dText { items.append(part("day", d)) }
        if let y = yText { items.append(part("year", y)) }
        if let w = wdText {
            date.append(part("weekday", w))
            if !items.isEmpty { date.append(lit(", ")) }
        }
        for (i, p) in items.enumerated() {
            if i > 0 { date.append(lit("/")) }
            date.append(p)
        }
    }
    // ---- time
    var time: [JSIntlPart] = []
    let hasTime = o.hour != 0 || o.minute != 0 || o.second != 0 || o.fsd > 0
    if hasTime {
        var h = f.hour
        var period = ""
        if o.hour != 0 && o.hour12 {
            period = h >= 12 ? "PM" : "AM"
            h = h % 12
            if h == 0 { h = 12 }
        }
        if o.hour != 0 {
            let pad = !o.hour12 || o.hour == 2
            time.append(part("hour", pad ? jsIntlPad(h, 2) : String(h)))
        }
        if o.minute != 0 {
            if !time.isEmpty { time.append(lit(":")) }
            time.append(part("minute", o.hour != 0 || o.second != 0 || o.minute == 2 ? jsIntlPad(f.minute, 2) : String(f.minute)))
        }
        if o.second != 0 {
            if !time.isEmpty { time.append(lit(":")) }
            time.append(part("second", o.minute != 0 || o.hour != 0 || o.second == 2 ? jsIntlPad(f.second, 2) : String(f.second)))
        }
        if o.fsd > 0 {
            if !time.isEmpty { time.append(lit(o.second != 0 ? "." : ":")) }
            let ms = jsIntlPad(f.ms, 3)
            time.append(part("fractionalSecond", String(ms.prefix(o.fsd))))
        }
        if !period.isEmpty { time.append(lit(" ")); time.append(part("dayPeriod", period)) }
    }
    var tzp: [JSIntlPart] = []
    if o.tzName != 0 { tzp = [part("timeZoneName", o.tz.displayName(t, kind: o.tzName > 4 ? o.tzName - 4 : o.tzName))] }
    // ---- join
    var out = date
    if !time.isEmpty {
        if !out.isEmpty {
            let at = o.dateStyle == 1 || o.dateStyle == 2 || (o.dateStyle == 0 && o.month == 5)
            out.append(lit(at ? " at " : ", "))
        }
        out.append(contentsOf: time)
        if !tzp.isEmpty { out.append(lit(" ")); out.append(contentsOf: tzp) }
    } else if !tzp.isEmpty {
        if !out.isEmpty { out.append(lit(", ")) }
        out.append(contentsOf: tzp)
    }
    return out
}

// MARK: Realm

extension JSRealm {
    /// InitializeDateTimeFormat: the resolved options object.
    /// required: 0 any, 1 date, 2 time; defaults: 0 all, 1 date, 2 time.
    func intlDateResolve(_ locales: JSValue, _ options: JSValue, required: Int, defaults: Int) throws(JSThrow) -> JSValue {
        let loc = try intlLocale(locales)
        let opts = try intlOptions(options)
        let d0 = heap.rootDepth
        defer { heap.popRoots(to: d0) }
        _ = heap.root(opts)
        _ = try intlGetString(opts, "localeMatcher", ["lookup", "best fit"])
        _ = try intlGetString(opts, "calendar", [])
        _ = try intlGetString(opts, "numberingSystem", [])
        let hour12 = try intlGetBool(opts, "hour12")
        let hourCycle = try intlGetString(opts, "hourCycle", ["h11", "h12", "h23", "h24"])
        var tzId = "UTC"
        var useRealmZone = true
        let tzv = try getV(opts, heap.key("timeZone"))
        if !tzv.isUndefined {
            let name = heap.swiftString(try toStringValue(tzv))
            if let z = jsIntlZoneLookup(name) { tzId = z.id; useRealmZone = false }
            else if let z = jsIntlOffsetZone(name) { tzId = z.id; useRealmZone = false }
            else { throw throwRangeError("Invalid time zone specified: " + name) }
        } else if dateZone.baseOffsetMinutes != 0 || !dateZone.transitions.isEmpty {
            let off = dateZone.baseOffsetMinutes
            let a = off < 0 ? -off : off
            tzId = (off < 0 ? "-" : "+") + jsIntlPad(a / 60, 2) + ":" + jsIntlPad(a % 60, 2)
        }
        let weekday = try intlGetString(opts, "weekday", ["narrow", "short", "long"])
        let era = try intlGetString(opts, "era", ["narrow", "short", "long"])
        let year = try intlGetString(opts, "year", ["2-digit", "numeric"])
        let month = try intlGetString(opts, "month", ["2-digit", "numeric", "narrow", "short", "long"])
        let day = try intlGetString(opts, "day", ["2-digit", "numeric"])
        let dayPeriod = try intlGetString(opts, "dayPeriod", ["narrow", "short", "long"])
        let hour = try intlGetString(opts, "hour", ["2-digit", "numeric"])
        let minute = try intlGetString(opts, "minute", ["2-digit", "numeric"])
        let second = try intlGetString(opts, "second", ["2-digit", "numeric"])
        let fsd = try intlGetNumber(opts, "fractionalSecondDigits", 1, 3)
        let tzName = try intlGetString(opts, "timeZoneName", ["short", "long", "shortOffset", "longOffset", "shortGeneric", "longGeneric"])
        _ = try intlGetString(opts, "formatMatcher", ["basic", "best fit"])
        let dateStyle = try intlGetString(opts, "dateStyle", ["full", "long", "medium", "short"])
        let timeStyle = try intlGetString(opts, "timeStyle", ["full", "long", "medium", "short"])
        var needDefaults = true
        var yearV = year, monthV = month, dayV = day, hourV = hour, minuteV = minute, secondV = second
        if dateStyle != nil || timeStyle != nil {
            if weekday != nil || era != nil || year != nil || month != nil || day != nil || dayPeriod != nil || hour != nil
                || minute != nil || second != nil || fsd != nil || tzName != nil {
                throw throwTypeError("Can't set option " + (weekday != nil ? "weekday" : year != nil ? "year" : month != nil ? "month" : day != nil ? "day" : hour != nil ? "hour" : minute != nil ? "minute" : second != nil ? "second" : "timeZoneName") + " when " + (dateStyle != nil ? "dateStyle" : "timeStyle") + " is used")
            }
            if required == 1 && timeStyle != nil { throw throwTypeError("Invalid option : timeStyle") }
            if required == 2 && dateStyle != nil { throw throwTypeError("Invalid option : dateStyle") }
            needDefaults = false
        } else {
            if required == 0 || required == 1 {
                if weekday != nil || year != nil || month != nil || day != nil { needDefaults = false }
            }
            if required == 0 || required == 2 {
                if dayPeriod != nil || hour != nil || minute != nil || second != nil || fsd != nil { needDefaults = false }
            }
            if needDefaults && (defaults == 0 || defaults == 1) { yearV = "numeric"; monthV = "numeric"; dayV = "numeric" }
            if needDefaults && (defaults == 0 || defaults == 2) { hourV = "numeric"; minuteV = "numeric"; secondV = "numeric" }
        }
        let res = heap.newObject(proto: objectPrototype)
        _ = heap.root(res)
        intlDefine(res, "locale", loc)
        intlDefine(res, "calendar", "gregory")
        intlDefine(res, "numberingSystem", "latn")
        intlDefine(res, "timeZone", tzId)
        if useRealmZone { intlDefine(res, "_realmZone", "1") }
        let usesHour = hourV != nil || timeStyle != nil
        if usesHour {
            var hc = "h12"
            if let h12 = hour12 { hc = h12 ? "h12" : "h23" } else if let c = hourCycle { hc = c }
            intlDefine(res, "hourCycle", hc)
            intlDefine(res, "hour12", .bool(hc == "h11" || hc == "h12"))
        }
        if let v = weekday { intlDefine(res, "weekday", v) }
        if let v = era { intlDefine(res, "era", v) }
        if let v = yearV { intlDefine(res, "year", v) }
        if let v = monthV { intlDefine(res, "month", v) }
        if let v = dayV { intlDefine(res, "day", v) }
        if let v = dayPeriod { intlDefine(res, "dayPeriod", v) }
        if let v = hourV { intlDefine(res, "hour", usesHour && !(hour12 ?? true) && v == "numeric" ? "2-digit" : v) }
        if let v = minuteV { intlDefine(res, "minute", hourV != nil ? "2-digit" : v) }
        if let v = secondV { intlDefine(res, "second", minuteV != nil ? "2-digit" : v) }
        if let v = fsd { intlDefine(res, "fractionalSecondDigits", .int32(Int32(v))) }
        if let v = tzName { intlDefine(res, "timeZoneName", v) }
        if let v = dateStyle { intlDefine(res, "dateStyle", v) }
        if let v = timeStyle { intlDefine(res, "timeStyle", v) }
        return res
    }

    /// ToDateTimeValue: undefined is now; a clipped time value or RangeError.
    func intlTimeValue(_ v: JSValue) throws(JSThrow) -> Double {
        let t: Double = v.isUndefined ? b2DateNow() : try toNumber(v)
        let c = jsDateTimeClip(t)
        if c.isNaN { throw throwRangeError("Invalid time value") }
        return c
    }

    func intlDateFormat(_ t: Double, _ res: JSValue) -> [JSIntlPart] {
        jsIntlDateParts(t, JSIntlDateOptions(resolved: res, heap: heap, realmZone: dateZone))
    }

    /// Date.prototype.toLocale*String.
    func intlToLocaleDate(_ t: Double, _ locales: JSValue, _ options: JSValue, required: Int, defaults: Int) throws(JSThrow) -> JSValue {
        if t.isNaN { return string("Invalid Date") }
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        let res = try intlDateResolve(locales, options, required: required, defaults: defaults)
        _ = heap.root(res)
        return heap.newString(utf16: intlPartsText(intlDateFormat(t, res)))
    }
}

// MARK: RelativeTimeFormat

func jsIntlRelativeUnit(_ s: String) -> Int? {
    switch s {
    case "second", "seconds": return 0
    case "minute", "minutes": return 1
    case "hour", "hours": return 2
    case "day", "days": return 3
    case "week", "weeks": return 4
    case "month", "months": return 5
    case "quarter", "quarters": return 6
    case "year", "years": return 7
    default: return nil
    }
}

func jsInstallIntlDate(_ realm: JSRealm, _ intl: JSValue) {
    let heap = realm.heap
    // ------------------------------------------------------ DateTimeFormat
    let dfp = heap.newObject(proto: realm.objectPrototype)
    _ = heap.root(dfp)
    realm.intlDefineClass(intl, "DateTimeFormat", length: 0, proto: dfp) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let proto = try realm.intlProto(args)
        let d = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: d) }
        _ = realm.heap.root(proto)
        let res = try realm.intlDateResolve(args[0], args[1], required: 0, defaults: 1)
        return realm.intlNew(proto: proto, kind: .dateTimeFormat, resolved: res)
    }
    let boundFormat = realm.registerNative("", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let df = realm.heap.slot(args.callee, 0)
        let res = realm.heap.slot(df, 1)
        let t = try realm.intlTimeValue(args[0])
        let d = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: d) }
        return realm.heap.newString(utf16: intlPartsText(realm.intlDateFormat(t, res)))
    }
    realm.defineGetter(dfp, "format") { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        _ = try realm.intlThis(args.this, .dateTimeFormat, "get Intl.DateTimeFormat.prototype.format")
        let cached = realm.heap.slot(args.this, 2)
        if cached.isObject { return cached }
        let f = realm.nativeClosure(boundFormat, [args.this])
        realm.heap.setSlot(args.this, 2, f)
        return f
    }
    realm.defineMethod(dfp, "formatToParts", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let res = try realm.intlThis(args.this, .dateTimeFormat, "Intl.DateTimeFormat.prototype.formatToParts")
        let t = try realm.intlTimeValue(args[0])
        let d = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: d) }
        return realm.intlPartsArray(realm.intlDateFormat(t, res))
    }
    func rangeParts(_ realm: JSRealm, _ args: JSArgs, _ name: String) throws(JSThrow) -> [JSIntlPart] {
        let res = try realm.intlThis(args.this, .dateTimeFormat, "Intl.DateTimeFormat.prototype." + name)
        if args[0].isUndefined || args[1].isUndefined { throw realm.throwTypeError("startDate and endDate are required") }
        let a = try realm.intlTimeValue(args[0])
        let b = try realm.intlTimeValue(args[1])
        let pa = realm.intlDateFormat(a, res), pb = realm.intlDateFormat(b, res)
        if intlPartsText(pa) == intlPartsText(pb) { return pa }
        return pa + [JSIntlPart(type: "literal", text: [0x2009, 0x2013, 0x2009])] + pb
    }
    realm.defineMethod(dfp, "formatRange", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let d = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: d) }
        return realm.heap.newString(utf16: intlPartsText(try rangeParts(realm, args, "formatRange")))
    }
    realm.defineMethod(dfp, "formatRangeToParts", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let d = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: d) }
        return realm.intlPartsArray(try rangeParts(realm, args, "formatRangeToParts"))
    }
    realm.defineMethod(dfp, "resolvedOptions", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let res = try realm.intlThis(args.this, .dateTimeFormat, "Intl.DateTimeFormat.prototype.resolvedOptions")
        let copy = realm.intlCopyOptions(res)
        _ = realm.heap.deleteProperty(copy, realm.heap.key("_realmZone"))
        return copy
    }
    // Date.prototype.toLocale*String.
    let dp = realm.intrinsic(.datePrototype)
    func dateMethod(_ name: String, _ required: Int, _ defaults: Int) {
        realm.defineMethod(dp, name, length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let t = try realm.b2ThisTime(args.this)
            return try realm.intlToLocaleDate(t, args[0], args[1], required: required, defaults: defaults)
        }
    }
    dateMethod("toLocaleString", 0, 0)
    dateMethod("toLocaleDateString", 1, 1)
    dateMethod("toLocaleTimeString", 2, 2)
    // ------------------------------------------------- RelativeTimeFormat
    let rtp = heap.newObject(proto: realm.objectPrototype)
    _ = heap.root(rtp)
    realm.intlDefineClass(intl, "RelativeTimeFormat", length: 0, proto: rtp) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        if !args.isConstruct { throw realm.throwTypeError("Constructor Intl.RelativeTimeFormat requires 'new'") }
        let proto = try realm.intlProto(args)
        let d = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: d) }
        _ = realm.heap.root(proto)
        let loc = try realm.intlLocale(args[0])
        let opts = try realm.intlOptions(args[1])
        _ = realm.heap.root(opts)
        _ = try realm.intlGetString(opts, "localeMatcher", ["lookup", "best fit"])
        _ = try realm.intlGetString(opts, "numberingSystem", [])
        let style = try realm.intlGetString(opts, "style", ["long", "short", "narrow"]) ?? "long"
        let numeric = try realm.intlGetString(opts, "numeric", ["always", "auto"]) ?? "always"
        let res = realm.heap.newObject(proto: realm.objectPrototype)
        _ = realm.heap.root(res)
        realm.intlDefine(res, "locale", loc)
        realm.intlDefine(res, "style", style)
        realm.intlDefine(res, "numeric", numeric)
        realm.intlDefine(res, "numberingSystem", "latn")
        return realm.intlNew(proto: proto, kind: .relativeTimeFormat, resolved: res)
    }
    func relParts(_ realm: JSRealm, _ args: JSArgs, _ name: String) throws(JSThrow) -> [JSIntlPart] {
        let res = try realm.intlThis(args.this, .relativeTimeFormat, "Intl.RelativeTimeFormat.prototype." + name)
        let value = try realm.toNumber(args[0])
        let unitStr = realm.heap.swiftString(try realm.toStringValue(args[1]))
        guard value.isFinite else { throw realm.throwRangeError("Value need to be finite number for Intl.RelativeTimeFormat.prototype." + name + "()") }
        guard let u = jsIntlRelativeUnit(unitStr) else { throw realm.throwRangeError("Invalid unit argument for " + name + "() '" + unitStr + "'") }
        let style = realm.heap.intlRawString(res, "style")
        let auto = realm.heap.intlRawString(res, "numeric") == "auto"
        let unitName = ["second", "minute", "hour", "day", "week", "month", "quarter", "year"][u]
        func lit(_ s: String) -> JSIntlPart { JSIntlPart(type: "literal", text: intlU16(s)) }
        if auto {
            let special: [Int: [String]] = [
                3: ["yesterday", "today", "tomorrow"], 7: ["last year", "this year", "next year"],
                5: ["last month", "this month", "next month"], 4: ["last week", "this week", "next week"],
                6: ["last quarter", "this quarter", "next quarter"],
            ]
            if u == 0 && value == 0 { return [lit("now")] }
            if u == 1 && value == 0 { return [lit("this minute")] }
            if u == 2 && value == 0 { return [lit("this hour")] }
            if let names = special[u], value == -1 || value == 0 || value == 1 {
                var s = names[Int(value) + 1]
                if style != "long" {
                    s = s.replacingPlain("quarter", "qtr.").replacingPlain("month", "mo.").replacingPlain("week", "wk.").replacingPlain("year", "yr.")
                }
                return [lit(s)]
            }
        }
        let neg = value < 0 || (value == 0 && value.sign == .minus)
        var o = JSIntlNumberOptions()
        o.signDisplay = 1
        var numParts = jsIntlFormatParts(JSIntlDecimal(double: value.magnitude), negative: false, nan: false, infinite: false, o)
        for i in 0..<numParts.count where numParts[i].type == "integer" || numParts[i].type == "fraction" || numParts[i].type == "decimal" || numParts[i].type == "group" {
            numParts[i].unit = unitName
        }
        let plural = !(value.magnitude == 1)
        var label: String
        if style == "long" {
            label = unitName + (plural ? "s" : "")
        } else {
            switch u {
            case 0: label = "sec."
            case 1: label = "min."
            case 2: label = "hr."
            case 3: label = plural ? "days" : "day"
            case 4: label = "wk."
            case 5: label = "mo."
            case 6: label = plural ? "qtrs." : "qtr."
            default: label = "yr."
            }
        }
        var out: [JSIntlPart] = []
        if !neg { out.append(lit("in ")) }
        out.append(contentsOf: numParts)
        out.append(lit(" " + label + (neg ? " ago" : "")))
        return out
    }
    realm.defineMethod(rtp, "format", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let d = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: d) }
        return realm.heap.newString(utf16: intlPartsText(try relParts(realm, args, "format")))
    }
    realm.defineMethod(rtp, "formatToParts", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let d = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: d) }
        return realm.intlPartsArray(try relParts(realm, args, "formatToParts"))
    }
    realm.defineMethod(rtp, "resolvedOptions", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let res = try realm.intlThis(args.this, .relativeTimeFormat, "Intl.RelativeTimeFormat.prototype.resolvedOptions")
        return realm.intlCopyOptions(res)
    }
}

extension String {
    /// Replace every occurrence of `a` by `b` (plain text, no Foundation).
    func replacingPlain(_ a: String, _ b: String) -> String {
        let parts = self.components(separatedByString: a)
        var out = parts[0]
        for p in parts.dropFirst() { out += b + p }
        return out
    }
}
