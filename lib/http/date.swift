// HTTP / cookie date parsing (RFC 6265 section 5.1.1, which also accepts
// the three HTTP-date formats), and Unix time arithmetic.

/// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant).
func httpDaysFromCivil(_ y: Int, _ m: Int, _ d: Int) -> Int {
    let yy = m <= 2 ? y - 1 : y
    let era = (yy >= 0 ? yy : yy - 399) / 400
    let yoe = yy - era * 400
    let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146097 + doe - 719468
}

private func httpIsDateDelimiter(_ c: UInt8) -> Bool {
    c == 0x09 || (c >= 0x20 && c <= 0x2f) || (c >= 0x3b && c <= 0x40) || (c >= 0x5b && c <= 0x60) || (c >= 0x7b && c <= 0x7e)
}

private func httpIsDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

/// Leading run of 1...maxDigits digits; returns (value, count).
private func httpLeadingDigits(_ t: [UInt8], _ from: Int, _ maxDigits: Int) -> (Int, Int)? {
    var v = 0, n = 0
    while from + n < t.count && n < maxDigits && httpIsDigit(t[from + n]) {
        v = v * 10 + Int(t[from + n] - 0x30); n += 1
    }
    return n == 0 ? nil : (v, n)
}

/// Parse a cookie/HTTP date to Unix seconds; nil if invalid.
func httpParseDate(_ s: [UInt8]) -> Int? {
    var tokens: [[UInt8]] = []
    var cur: [UInt8] = []
    for c in s {
        if httpIsDateDelimiter(c) { if !cur.isEmpty { tokens.append(cur); cur = [] } }
        else { cur.append(c) }
        if cur.count > 64 { return nil }
    }
    if !cur.isEmpty { tokens.append(cur) }
    var hour = -1, minute = 0, second = 0
    var day = -1, month = -1, year = -1
    let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    for t in tokens {
        if hour < 0, let (h, n1) = httpLeadingDigits(t, 0, 2), n1 < t.count, t[n1] == 0x3a,
           let (m, n2) = httpLeadingDigits(t, n1 + 1, 2), n1 + 1 + n2 < t.count, t[n1 + 1 + n2] == 0x3a,
           let (sec, _) = httpLeadingDigits(t, n1 + 2 + n2, 2) {
            hour = h; minute = m; second = sec
            continue
        }
        if day < 0, let (d, _) = httpLeadingDigits(t, 0, 2) { day = d; continue }
        if month < 0, t.count >= 3 {
            let p = [httpLower(t[0]), httpLower(t[1]), httpLower(t[2])]
            var found = -1
            for (k, name) in months.enumerated() where Array(name.utf8) == p { found = k + 1 }
            if found > 0 { month = found; continue }
        }
        if year < 0, let (y, _) = httpLeadingDigits(t, 0, 4) { year = y; continue }
    }
    if hour < 0 || day < 0 || month < 0 || year < 0 { return nil }
    if year >= 70 && year <= 99 { year += 1900 } else if year >= 0 && year <= 69 { year += 2000 }
    if day < 1 || day > 31 || year < 1601 || hour > 23 || minute > 59 || second > 59 { return nil }
    let mdays = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    let limit = (month == 2 && leap) ? 29 : mdays[month - 1]
    if day > limit { return nil }
    return httpDaysFromCivil(year, month, day) * 86400 + hour * 3600 + minute * 60 + second
}
