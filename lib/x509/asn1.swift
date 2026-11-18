// lib/x509: ASN.1 DER, X.509 certificates, chain validation and the root
// store (ROADMAP Phase 8A). Pure Swift; every byte is treated as hostile.
//
// ASN.1 DER reader (X.690), strict:
//
//   var r = ASN1Reader(der)                 // a reader over a byte array
//   let seq = r.next()                      // ASN1Element?, nil at end/error
//   r.failed                                // true once anything was bad
//   var kids = seq.children()               // ASN1Reader? (constructed only;
//                                           // nil past ASN1Reader.maxDepth)
//   kids.expect(ASN1.sequence)              // next element if it has the tag
//   kids.optional(context: 0)               // next element if it is [0]
//   el.is(ASN1.integer), el.tagClass/tagNumber/constructed
//   el.content / el.contentBytes / el.encoded (header + content)
//   el.integer() -> [UInt8]? (minimal, two's complement content)
//   el.unsignedInteger() -> [UInt8]? (non-negative, leading zero dropped)
//   el.smallInt() -> Int?   el.boolean() -> Bool?   el.null() -> Bool
//   el.oid() -> ASN1OID?    el.bitString() -> [UInt8]? (no unused bits)
//   el.bitStringBits() -> (bytes, unusedBits)?   el.octetString()
//   el.time() -> Int64? (UTCTime / GeneralizedTime -> Unix seconds)
//   el.string() -> String? (UTF8/Printable/IA5/Visible/Numeric strictly;
//                           T61/Teletex as Latin-1, BMP, Universal leniently)
//
// Only definite, minimally encoded lengths are accepted (DER); tags up to
// 2^21 in high-tag form; lengths up to 2^32-1 and always inside the parent.
// Elements share the input array (no copies until contentBytes/encoded).

enum ASN1 {
    static let universal: UInt8 = 0, application: UInt8 = 1, contextSpecific: UInt8 = 2, privateClass: UInt8 = 3

    /// Universal tags as (number, constructed).
    struct Tag: Equatable {
        let tagClass: UInt8
        let number: UInt32
        let constructed: Bool
    }
    static let boolean = Tag(tagClass: 0, number: 1, constructed: false)
    static let integer = Tag(tagClass: 0, number: 2, constructed: false)
    static let bitString = Tag(tagClass: 0, number: 3, constructed: false)
    static let octetString = Tag(tagClass: 0, number: 4, constructed: false)
    static let null = Tag(tagClass: 0, number: 5, constructed: false)
    static let objectIdentifier = Tag(tagClass: 0, number: 6, constructed: false)
    static let enumerated = Tag(tagClass: 0, number: 10, constructed: false)
    static let utf8String = Tag(tagClass: 0, number: 12, constructed: false)
    static let sequence = Tag(tagClass: 0, number: 16, constructed: true)
    static let set = Tag(tagClass: 0, number: 17, constructed: true)
    static let numericString = Tag(tagClass: 0, number: 18, constructed: false)
    static let printableString = Tag(tagClass: 0, number: 19, constructed: false)
    static let t61String = Tag(tagClass: 0, number: 20, constructed: false)
    static let ia5String = Tag(tagClass: 0, number: 22, constructed: false)
    static let utcTime = Tag(tagClass: 0, number: 23, constructed: false)
    static let generalizedTime = Tag(tagClass: 0, number: 24, constructed: false)
    static let visibleString = Tag(tagClass: 0, number: 26, constructed: false)
    static let universalString = Tag(tagClass: 0, number: 28, constructed: false)
    static let bmpString = Tag(tagClass: 0, number: 30, constructed: false)

    /// [n] context-specific, constructed (EXPLICIT tags and IMPLICIT
    /// SEQUENCEs) or primitive (IMPLICIT primitives).
    static func context(_ n: UInt32, constructed: Bool = true) -> Tag {
        Tag(tagClass: 2, number: n, constructed: constructed)
    }
}

/// An object identifier: its DER content bytes (compared directly).
struct ASN1OID: Equatable {
    let bytes: [UInt8]

    init(der: [UInt8]) { bytes = der }

    /// From dotted arcs, for constants: ASN1OID(arcs: [1, 2, 840, 113549]).
    init(arcs: [UInt64]) {
        var out: [UInt8] = []
        func base128(_ v: UInt64) {
            var tmp: [UInt8] = [UInt8(v & 0x7f)]
            var x = v >> 7
            while x > 0 { tmp.append(UInt8(x & 0x7f) | 0x80); x >>= 7 }
            out.append(contentsOf: tmp.reversed())
        }
        if arcs.count >= 2 { base128(arcs[0] * 40 + arcs[1]) }
        var i = 2
        while i < arcs.count { base128(arcs[i]); i += 1 }
        bytes = out
    }

    /// Dotted-decimal form ("1.2.840.113549.1.1.11"); arcs over 64 bits
    /// print as "?".
    var dotted: String {
        var arcs: [String] = []
        var v: UInt64 = 0
        var bits = 0
        var first = true
        for b in bytes {
            if bits > 56 { return arcs.joined(separator: ".") + ".?" }
            v = v << 7 | UInt64(b & 0x7f)
            bits += 7
            if b & 0x80 == 0 {
                if first {
                    let a = v < 40 ? 0 : (v < 80 ? 1 : 2)
                    arcs.append(String(a)); arcs.append(String(v - UInt64(a) * 40))
                    first = false
                } else { arcs.append(String(v)) }
                v = 0; bits = 0
            }
        }
        return arcs.joined(separator: ".")
    }
}

struct ASN1Element {
    let tagClass: UInt8
    let constructed: Bool
    let tagNumber: UInt32
    let data: [UInt8]
    let start: Int          // first header byte
    let contentStart: Int
    let end: Int            // one past the last content byte
    let depth: Int

    var tag: ASN1.Tag { ASN1.Tag(tagClass: tagClass, number: tagNumber, constructed: constructed) }
    func `is`(_ t: ASN1.Tag) -> Bool { tag == t }
    var length: Int { end - contentStart }
    var content: ArraySlice<UInt8> { data[contentStart..<end] }
    var contentBytes: [UInt8] { Array(data[contentStart..<end]) }
    /// The whole TLV, header included (what signatures and DN compares use).
    var encoded: [UInt8] { Array(data[start..<end]) }

    /// A reader over the contents of a constructed element.
    func children() -> ASN1Reader? {
        guard constructed, depth + 1 <= ASN1Reader.maxDepth else { return nil }
        return ASN1Reader(data, start: contentStart, end: end, depth: depth + 1)
    }

    /// A reader over the contents read as DER (OCTET STRING wrappers such as
    /// extension values; primitive elements whose content is itself DER).
    func contentReader() -> ASN1Reader? {
        guard depth + 1 <= ASN1Reader.maxDepth else { return nil }
        return ASN1Reader(data, start: contentStart, end: end, depth: depth + 1)
    }

    /// INTEGER content: non-empty and minimally encoded (two's complement).
    func integer() -> [UInt8]? {
        guard !constructed, length > 0 else { return nil }
        if length > 1 {
            let a = data[contentStart], b = data[contentStart + 1]
            if a == 0 && b & 0x80 == 0 { return nil }
            if a == 0xff && b & 0x80 != 0 { return nil }
        }
        return contentBytes
    }

    /// A non-negative INTEGER as unsigned big-endian bytes (no sign byte).
    func unsignedInteger() -> [UInt8]? {
        guard let v = integer(), v[0] & 0x80 == 0 else { return nil }
        if v.count > 1 && v[0] == 0 { return Array(v[1...]) }
        return v
    }

    /// A small non-negative INTEGER (or ENUMERATED).
    func smallInt() -> Int? {
        guard let v = integer(), v[0] & 0x80 == 0, v.count <= 7 else { return nil }
        var x = 0
        for b in v { x = x << 8 | Int(b) }
        return x
    }

    func boolean() -> Bool? {
        guard self.is(ASN1.boolean), length == 1 else { return nil }
        switch data[contentStart] {
        case 0x00: return false
        case 0xff: return true
        default: return nil   // DER: TRUE is 0xff
        }
    }

    func null() -> Bool { self.is(ASN1.null) && length == 0 }

    func oid() -> ASN1OID? {
        guard self.is(ASN1.objectIdentifier), length > 0, length <= 128 else { return nil }
        guard data[end - 1] & 0x80 == 0 else { return nil }
        var atStart = true
        for i in contentStart..<end {
            let b = data[i]
            if atStart && b == 0x80 { return nil }   // non-minimal subidentifier
            atStart = b & 0x80 == 0
        }
        return ASN1OID(der: contentBytes)
    }

    /// BIT STRING: the bytes and the count of unused bits in the last byte
    /// (DER: those bits must be zero).
    func bitStringBits() -> (bytes: [UInt8], unusedBits: Int)? {
        guard !constructed, tagClass == 0 || tagClass == 2, length >= 1 else { return nil }
        let unused = Int(data[contentStart])
        guard unused <= 7 else { return nil }
        if length == 1 { return unused == 0 ? ([], 0) : nil }
        let last = data[end - 1]
        guard last & UInt8((1 << unused) - 1) == 0 else { return nil }
        return (Array(data[(contentStart + 1)..<end]), unused)
    }

    /// BIT STRING with no unused bits (keys and signatures).
    func bitString() -> [UInt8]? {
        guard self.is(ASN1.bitString), let b = bitStringBits(), b.unusedBits == 0 else { return nil }
        return b.bytes
    }

    func octetString() -> [UInt8]? {
        guard self.is(ASN1.octetString) else { return nil }
        return contentBytes
    }

    /// UTCTime (YYMMDDHHMMSSZ, 1950–2049) or GeneralizedTime
    /// (YYYYMMDDHHMMSSZ) as Unix seconds. Fractions and offsets are refused
    /// (RFC 5280 4.1.2.5).
    func time() -> Int64? {
        let digitsStart: Int
        var year: Int
        if self.is(ASN1.utcTime) {
            guard length == 13 else { return nil }
            guard let yy = digits(contentStart, 2) else { return nil }
            year = yy < 50 ? 2000 + yy : 1900 + yy
            digitsStart = contentStart + 2
        } else if self.is(ASN1.generalizedTime) {
            guard length == 15, let y = digits(contentStart, 4) else { return nil }
            year = y
            digitsStart = contentStart + 4
        } else { return nil }
        guard data[end - 1] == 0x5a,   // 'Z'
              let mo = digits(digitsStart, 2), let d = digits(digitsStart + 2, 2),
              let h = digits(digitsStart + 4, 2), let mi = digits(digitsStart + 6, 2),
              let s = digits(digitsStart + 8, 2) else { return nil }
        guard mo >= 1, mo <= 12, d >= 1, d <= asn1DaysInMonth(year, mo), h <= 23, mi <= 59, s <= 59 else { return nil }
        return asn1UnixTime(year: year, month: mo, day: d, hour: h, minute: mi, second: s)
    }

    private func digits(_ at: Int, _ n: Int) -> Int? {
        guard at >= contentStart, at + n <= end else { return nil }
        var v = 0
        for i in at..<(at + n) {
            let c = data[i]
            guard c >= 0x30, c <= 0x39 else { return nil }
            v = v * 10 + Int(c - 0x30)
        }
        return v
    }

    /// A directory string as Swift text. Invalid UTF-8 is repaired (U+FFFD)
    /// rather than refused: names are for display and comparison only.
    func string() -> String? {
        guard tagClass == 0, !constructed else { return nil }
        switch tagNumber {
        case 12, 18, 19, 22, 26:   // UTF8, Numeric, Printable, IA5, Visible
            return String(decoding: content, as: UTF8.self)
        case 20:                   // T61/Teletex: in practice Latin-1
            var s = ""
            for b in content { s.unicodeScalars.append(Unicode.Scalar(b)) }
            return s
        case 30:                   // BMPString: UCS-2 big-endian
            guard length % 2 == 0 else { return nil }
            var units: [UInt16] = []
            var i = contentStart
            while i + 1 < end { units.append(UInt16(data[i]) << 8 | UInt16(data[i + 1])); i += 2 }
            return String(decoding: units, as: UTF16.self)
        case 28:                   // UniversalString: UCS-4 big-endian
            guard length % 4 == 0 else { return nil }
            var s = ""
            var i = contentStart
            while i + 3 < end {
                let v = UInt32(data[i]) << 24 | UInt32(data[i + 1]) << 16 | UInt32(data[i + 2]) << 8 | UInt32(data[i + 3])
                s.unicodeScalars.append(Unicode.Scalar(v) ?? "\u{FFFD}")
                i += 4
            }
            return s
        default: return nil
        }
    }
}

/// Sequential reader over DER elements in [start, end) of a byte array.
struct ASN1Reader {
    /// Nesting limit (X.509 needs about 10).
    static let maxDepth = 24

    let data: [UInt8]
    private(set) var offset: Int
    let end: Int
    let depth: Int
    private(set) var failed = false

    init(_ data: [UInt8]) {
        self.data = data; offset = 0; end = data.count; depth = 0
    }

    init(_ data: [UInt8], start: Int, end: Int, depth: Int) {
        self.data = data
        let s = min(max(start, 0), data.count)
        offset = s
        self.end = min(max(end, s), data.count)
        self.depth = depth
    }

    var atEnd: Bool { offset >= end }

    /// Peek at the next element's tag without consuming it.
    func peekTag() -> ASN1.Tag? {
        var copy = self
        return copy.next()?.tag
    }

    /// The next element, or nil at the end or on malformed input (then
    /// `failed` is set and stays set).
    mutating func next() -> ASN1Element? {
        guard !failed, offset < end else { return nil }
        let start = offset
        var p = offset
        let first = data[p]; p += 1
        let cls = first >> 6
        let cons = first & 0x20 != 0
        var num = UInt32(first & 0x1f)
        if num == 0x1f {
            // High-tag-number form: base-128, minimal, at least 31.
            num = 0
            var count = 0
            while true {
                guard p < end, count < 3 else { return fail() }
                let b = data[p]; p += 1
                if count == 0 && b == 0x80 { return fail() }
                num = num << 7 | UInt32(b & 0x7f)
                count += 1
                if b & 0x80 == 0 { break }
            }
            guard num >= 31 else { return fail() }
        }
        guard p < end else { return fail() }
        let l0 = data[p]; p += 1
        var len = 0
        if l0 < 0x80 {
            len = Int(l0)
        } else {
            let n = Int(l0 & 0x7f)
            guard n >= 1, n <= 4, end - p >= n else { return fail() }   // 0x80: indefinite
            guard data[p] != 0 else { return fail() }                   // non-minimal
            for i in 0..<n { len = len << 8 | Int(data[p + i]) }
            p += n
            guard len >= 0x80 else { return fail() }                    // should be short form
        }
        guard len <= end - p else { return fail() }
        offset = p + len
        return ASN1Element(tagClass: cls, constructed: cons, tagNumber: num, data: data,
                           start: start, contentStart: p, end: p + len, depth: depth)
    }

    /// The next element if it has tag `t`; otherwise nil and failed.
    mutating func expect(_ t: ASN1.Tag) -> ASN1Element? {
        guard let e = next() else { failed = true; return nil }
        guard e.is(t) else { failed = true; return nil }
        return e
    }

    /// The next element if it has tag `t` (OPTIONAL / DEFAULT fields);
    /// otherwise nil, consuming nothing.
    mutating func optional(_ t: ASN1.Tag) -> ASN1Element? {
        guard peekTag() == t else { return nil }
        return next()
    }

    mutating func optional(context n: UInt32, constructed: Bool = true) -> ASN1Element? {
        optional(ASN1.context(n, constructed: constructed))
    }

    private mutating func fail() -> ASN1Element? { failed = true; return nil }
}

func asn1IsLeap(_ y: Int) -> Bool { (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 }

func asn1DaysInMonth(_ y: Int, _ m: Int) -> Int {
    switch m {
    case 2: return asn1IsLeap(y) ? 29 : 28
    case 4, 6, 9, 11: return 30
    default: return 31
    }
}

/// Days since 1970-01-01 of a proleptic Gregorian date (H. Hinnant's
/// days_from_civil).
func asn1DaysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
    let y = m <= 2 ? y0 - 1 : y0
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let mp = m > 2 ? m - 3 : m + 9
    let doy = (153 * mp + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146097 + doe - 719468
}

func asn1UnixTime(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) -> Int64 {
    Int64(asn1DaysFromCivil(year, month, day)) * 86400 + Int64(hour * 3600 + minute * 60 + second)
}

/// "2026-11-18 12:00:00Z" for messages.
func asn1FormatTime(_ t: Int64) -> String {
    var days = Int(t >= 0 ? t / 86400 : (t - 86399) / 86400)
    let secs = Int(t - Int64(days) * 86400)
    // civil_from_days
    days += 719468
    let era = (days >= 0 ? days : days - 146096) / 146097
    let doe = days - era * 146097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
    var y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp < 10 ? mp + 3 : mp - 9
    if m <= 2 { y += 1 }
    func two(_ v: Int) -> String { v < 10 ? "0" + String(v) : String(v) }
    return "\(y)-\(two(m))-\(two(d)) \(two(secs / 3600)):\(two(secs / 60 % 60)):\(two(secs % 60))Z"
}
