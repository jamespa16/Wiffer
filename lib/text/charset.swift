// lib/text: character decoding for web content (ROADMAP Phase 8B).
//
//   - charsetEncodingForLabel: WHATWG encoding label lookup (common labels)
//   - charsetDecode / charsetDecodeUTF8: bytes -> Unicode scalars / UTF-8 with
//     U+FFFD replacement, per the WHATWG decoders (UTF-8, windows-1252 incl.
//     the ISO-8859-1 / latin1 / ascii labels, UTF-16LE/BE)
//   - charsetDetectEncoding: header charset, then BOM, then the <meta> prescan
//     of the first 1024 bytes, then UTF-8
//
// Everything works on [UInt8] and never traps on bad input.

enum TextEncoding: Equatable {
    case utf8
    case windows1252
    case utf16le
    case utf16be
    /// A known label of a legacy multi-byte encoding (Shift_JIS, GBK, Big5,
    /// EUC-*, ...) that this library does not decode. charsetDecode treats it as
    /// windows-1252 so the page is at least readable; callers can check.
    case unsupported
}

enum TextEncodingSource: Equatable {
    case header, bom, meta, fallback
}

struct TextDetection: Equatable {
    var encoding: TextEncoding
    var source: TextEncodingSource
    /// Length of a BOM to skip (0, 2 or 3).
    var bomLength: Int
}

// MARK: byte helpers

@inline(__always) func charsetIsASCIIWhitespace(_ c: UInt8) -> Bool {
    c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0c || c == 0x0d
}

@inline(__always) func charsetLower(_ c: UInt8) -> UInt8 {
    (c >= 0x41 && c <= 0x5a) ? c + 32 : c
}

/// ASCII-lowercased copy with leading/trailing ASCII whitespace removed.
func charsetTrimLower(_ s: [UInt8]) -> [UInt8] {
    var a = 0, b = s.count
    while a < b && charsetIsASCIIWhitespace(s[a]) { a += 1 }
    while b > a && charsetIsASCIIWhitespace(s[b - 1]) { b -= 1 }
    var out: [UInt8] = []
    out.reserveCapacity(b - a)
    for i in a..<b { out.append(charsetLower(s[i])) }
    return out
}

// MARK: labels

private func charsetLabelTable() -> [(String, TextEncoding)] {
    return [
    ("utf-8", .utf8), ("utf8", .utf8), ("unicode-1-1-utf-8", .utf8),
    ("unicode11utf8", .utf8), ("unicode20utf8", .utf8), ("x-unicode20utf8", .utf8),
    ("utf-16le", .utf16le), ("utf-16", .utf16le), ("ucs-2", .utf16le),
    ("unicode", .utf16le), ("csunicode", .utf16le), ("iso-10646-ucs-2", .utf16le),
    ("unicodefeff", .utf16le),
    ("utf-16be", .utf16be), ("unicodefffe", .utf16be),
    // windows-1252 and everything WHATWG folds into it
    ("windows-1252", .windows1252), ("cp1252", .windows1252), ("x-cp1252", .windows1252),
    ("iso-8859-1", .windows1252), ("iso8859-1", .windows1252), ("iso_8859-1", .windows1252),
    ("iso88591", .windows1252), ("latin1", .windows1252), ("l1", .windows1252),
    ("ascii", .windows1252), ("us-ascii", .windows1252), ("cp819", .windows1252),
    ("ibm819", .windows1252), ("csisolatin1", .windows1252), ("iso-ir-100", .windows1252),
    ("iso_8859-1:1987", .windows1252), ("ansi_x3.4-1968", .windows1252),
    ("iso-8859-9", .windows1252), ("latin5", .windows1252), // close enough
    // known but not decoded
    ("shift_jis", .unsupported), ("shift-jis", .unsupported), ("sjis", .unsupported),
    ("x-sjis", .unsupported), ("ms_kanji", .unsupported), ("windows-31j", .unsupported),
    ("euc-jp", .unsupported), ("iso-2022-jp", .unsupported),
    ("euc-kr", .unsupported), ("ks_c_5601-1987", .unsupported),
    ("gbk", .unsupported), ("gb2312", .unsupported), ("gb18030", .unsupported),
    ("x-gbk", .unsupported), ("big5", .unsupported), ("big5-hkscs", .unsupported),
    ("iso-8859-2", .unsupported), ("iso-8859-5", .unsupported), ("iso-8859-7", .unsupported),
    ("iso-8859-15", .unsupported), ("windows-1250", .unsupported),
    ("windows-1251", .unsupported), ("windows-1253", .unsupported),
    ("windows-1254", .unsupported), ("koi8-r", .unsupported), ("koi8-u", .unsupported),
    ]
}

/// WHATWG "get an encoding": ASCII-case-insensitive, surrounding whitespace
/// ignored. nil for an unknown label.
func charsetEncodingForLabel(_ label: [UInt8]) -> TextEncoding? {
    let l = charsetTrimLower(label)
    if l.isEmpty || l.count > 40 { return nil }
    for (name, enc) in charsetLabelTable() {
        if Array(name.utf8) == l { return enc }
    }
    return nil
}

func charsetEncodingForLabel(_ label: String) -> TextEncoding? {
    charsetEncodingForLabel(Array(label.utf8))
}

// MARK: decoding

/// windows-1252 0x80...0x9F.
private let charsetCP1252High: [UInt16] = [
    0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
    0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
]

let charsetReplacement: UInt32 = 0xFFFD

/// WHATWG UTF-8 decoder (no BOM handling). Invalid sequences give one U+FFFD
/// per maximal subpart, exactly as the spec's decoder does.
func charsetDecodeUTF8(_ bytes: [UInt8], from start: Int = 0) -> [UInt32] {
    var out: [UInt32] = []
    out.reserveCapacity(bytes.count)
    var needed = 0
    var seen = 0
    var cp: UInt32 = 0
    var lower: UInt8 = 0x80
    var upper: UInt8 = 0xBF
    var i = max(start, 0)
    let n = bytes.count
    while i < n {
        let b = bytes[i]
        if needed == 0 {
            switch b {
            case 0x00...0x7F: out.append(UInt32(b))
            case 0xC2...0xDF: needed = 1; cp = UInt32(b & 0x1F)
            case 0xE0...0xEF:
                if b == 0xE0 { lower = 0xA0 }
                if b == 0xED { upper = 0x9F }
                needed = 2; cp = UInt32(b & 0x0F)
            case 0xF0...0xF4:
                if b == 0xF0 { lower = 0x90 }
                if b == 0xF4 { upper = 0x8F }
                needed = 3; cp = UInt32(b & 0x07)
            default: out.append(charsetReplacement)
            }
            i += 1
            continue
        }
        if b < lower || b > upper {
            cp = 0; needed = 0; seen = 0; lower = 0x80; upper = 0xBF
            out.append(charsetReplacement)
            continue // reprocess this byte
        }
        lower = 0x80; upper = 0xBF
        cp = (cp << 6) | UInt32(b & 0x3F)
        seen += 1
        i += 1
        if seen == needed {
            out.append(cp)
            cp = 0; needed = 0; seen = 0
        }
    }
    if needed != 0 { out.append(charsetReplacement) }
    return out
}

func charsetDecodeWindows1252(_ bytes: [UInt8], from start: Int = 0) -> [UInt32] {
    var out: [UInt32] = []
    out.reserveCapacity(bytes.count)
    var i = max(start, 0)
    while i < bytes.count {
        let b = bytes[i]
        if b >= 0x80 && b < 0xA0 { out.append(UInt32(charsetCP1252High[Int(b) - 0x80])) }
        else { out.append(UInt32(b)) }
        i += 1
    }
    return out
}

func charsetDecodeUTF16(_ bytes: [UInt8], bigEndian: Bool, from start: Int = 0) -> [UInt32] {
    var out: [UInt32] = []
    out.reserveCapacity(bytes.count / 2)
    var i = max(start, 0)
    var lead: UInt32 = 0
    var haveLead = false
    while i + 1 < bytes.count {
        let a = UInt32(bytes[i]), b = UInt32(bytes[i + 1])
        let unit = bigEndian ? (a << 8 | b) : (b << 8 | a)
        i += 2
        if haveLead {
            haveLead = false
            if unit >= 0xDC00 && unit <= 0xDFFF {
                out.append(0x10000 + ((lead - 0xD800) << 10) + (unit - 0xDC00))
                continue
            }
            out.append(charsetReplacement) // lone lead; reprocess this unit
        }
        if unit >= 0xD800 && unit <= 0xDBFF { lead = unit; haveLead = true }
        else if unit >= 0xDC00 && unit <= 0xDFFF { out.append(charsetReplacement) }
        else { out.append(unit) }
    }
    if haveLead || i < bytes.count { out.append(charsetReplacement) }
    return out
}

/// Decode `bytes` (skipping `from` leading bytes, e.g. a BOM) to scalars.
func charsetDecode(_ bytes: [UInt8], _ encoding: TextEncoding, from start: Int = 0) -> [UInt32] {
    switch encoding {
    case .utf8: return charsetDecodeUTF8(bytes, from: start)
    case .utf16le: return charsetDecodeUTF16(bytes, bigEndian: false, from: start)
    case .utf16be: return charsetDecodeUTF16(bytes, bigEndian: true, from: start)
    case .windows1252, .unsupported: return charsetDecodeWindows1252(bytes, from: start)
    }
}

/// Append one scalar as UTF-8 (surrogates and out-of-range become U+FFFD).
func charsetAppendUTF8(_ cp: UInt32, to out: inout [UInt8]) {
    var c = cp
    if c > 0x10FFFF || (c >= 0xD800 && c <= 0xDFFF) { c = charsetReplacement }
    if c < 0x80 { out.append(UInt8(c)) }
    else if c < 0x800 {
        out.append(UInt8(0xC0 | (c >> 6))); out.append(UInt8(0x80 | (c & 0x3F)))
    } else if c < 0x10000 {
        out.append(UInt8(0xE0 | (c >> 12)))
        out.append(UInt8(0x80 | ((c >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (c & 0x3F)))
    } else {
        out.append(UInt8(0xF0 | (c >> 18)))
        out.append(UInt8(0x80 | ((c >> 12) & 0x3F)))
        out.append(UInt8(0x80 | ((c >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (c & 0x3F)))
    }
}

func charsetEncodeUTF8(_ scalars: [UInt32]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(scalars.count)
    for s in scalars { charsetAppendUTF8(s, to: &out) }
    return out
}

/// Decode to well-formed UTF-8 bytes.
func charsetDecodeToUTF8(_ bytes: [UInt8], _ encoding: TextEncoding, from start: Int = 0) -> [UInt8] {
    charsetEncodeUTF8(charsetDecode(bytes, encoding, from: start))
}

// MARK: detection

/// The charset parameter of a Content-Type value ("text/html; charset=UTF-8"),
/// as a label (not yet looked up).
func charsetFromContentType(_ value: [UInt8]) -> [UInt8]? {
    let n = value.count
    var i = 0
    while i < n && value[i] != 0x3b { i += 1 } // skip the media type
    while i < n {
        i += 1 // past ';'
        while i < n && charsetIsASCIIWhitespace(value[i]) { i += 1 }
        var name: [UInt8] = []
        while i < n && value[i] != 0x3d && value[i] != 0x3b { name.append(charsetLower(value[i])); i += 1 }
        var val: [UInt8] = []
        if i < n && value[i] == 0x3d {
            i += 1
            while i < n && charsetIsASCIIWhitespace(value[i]) { i += 1 }
            if i < n && value[i] == 0x22 {
                i += 1
                while i < n && value[i] != 0x22 {
                    if value[i] == 0x5c && i + 1 < n { i += 1 }
                    val.append(value[i]); i += 1
                }
                if i < n { i += 1 }
                while i < n && value[i] != 0x3b { i += 1 }
            } else {
                while i < n && value[i] != 0x3b { val.append(value[i]); i += 1 }
            }
        }
        while let l = name.last, charsetIsASCIIWhitespace(l) { name.removeLast() }
        if name == Array("charset".utf8) {
            while let l = val.last, charsetIsASCIIWhitespace(l) { val.removeLast() }
            if !val.isEmpty { return val }
        }
    }
    return nil
}

/// Extract an encoding label from a <meta content="..."> value
/// ("text/html; charset=utf-8").
func charsetFromMetaContent(_ v: [UInt8]) -> [UInt8]? {
    let key = Array("charset".utf8)
    let n = v.count
    var i = 0
    while i + key.count <= n {
        var match = true
        for k in 0..<key.count where charsetLower(v[i + k]) != key[k] { match = false; break }
        if !match { i += 1; continue }
        var j = i + key.count
        while j < n && charsetIsASCIIWhitespace(v[j]) { j += 1 }
        if j >= n || v[j] != 0x3d { i += 1; continue }
        j += 1
        while j < n && charsetIsASCIIWhitespace(v[j]) { j += 1 }
        if j >= n { return nil }
        var out: [UInt8] = []
        if v[j] == 0x22 || v[j] == 0x27 {
            let q = v[j]; j += 1
            while j < n && v[j] != q { out.append(v[j]); j += 1 }
            if j >= n { return nil }
        } else {
            while j < n && !charsetIsASCIIWhitespace(v[j]) && v[j] != 0x3b { out.append(v[j]); j += 1 }
        }
        return out.isEmpty ? nil : out
    }
    return nil
}

private func charsetMatchAt(_ b: [UInt8], _ n: Int, _ i: Int, _ s: String) -> Bool {
    let u = Array(s.utf8)
    if i < 0 || i + u.count > n { return false }
    for k in 0..<u.count where charsetLower(b[i + k]) != u[k] { return false }
    return true
}

private func charsetIsAlpha(_ c: UInt8) -> Bool {
    (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a)
}

/// One attribute for the prescan ("get an attribute"). Returns nil at the end
/// of the tag. Names and values are lowercased.
private func charsetPrescanAttribute(_ bytes: [UInt8], _ n: Int, _ i: inout Int) -> ([UInt8], [UInt8])? {
    while i < n && (charsetIsASCIIWhitespace(bytes[i]) || bytes[i] == 0x2f) { i += 1 }
    if i >= n || bytes[i] == 0x3e { return nil }
    var name: [UInt8] = [], value: [UInt8] = []
    while true {
        if i >= n { return (name, value) }
        let c = bytes[i]
        if c == 0x3d && !name.isEmpty { break }
        if charsetIsASCIIWhitespace(c) { break }
        if c == 0x2f || c == 0x3e { return (name, value) }
        name.append(charsetLower(c)); i += 1
    }
    while i < n && charsetIsASCIIWhitespace(bytes[i]) { i += 1 }
    if i >= n || bytes[i] != 0x3d { return (name, value) }
    i += 1
    while i < n && charsetIsASCIIWhitespace(bytes[i]) { i += 1 }
    if i >= n { return (name, value) }
    let c = bytes[i]
    if c == 0x22 || c == 0x27 {
        i += 1
        while i < n && bytes[i] != c { value.append(charsetLower(bytes[i])); i += 1 }
        if i < n { i += 1 }
        return (name, value)
    }
    if c == 0x3e { return (name, value) }
    while i < n && !charsetIsASCIIWhitespace(bytes[i]) && bytes[i] != 0x3e {
        value.append(charsetLower(bytes[i])); i += 1
    }
    return (name, value)
}

/// The HTML "prescan a byte stream to determine its encoding" algorithm over
/// the first 1024 bytes. Returns the encoding found in a <meta>, or nil.
func charsetPrescanMeta(_ bytes: [UInt8]) -> TextEncoding? {
    let n = min(bytes.count, 1024)
    var i = 0
    while i < n {
        if charsetMatchAt(bytes, n, i, "<!--") {
            var j = i + 2
            var found = false
            while j + 2 < n {
                if bytes[j] == 0x2d && bytes[j + 1] == 0x2d && bytes[j + 2] == 0x3e { found = true; break }
                j += 1
            }
            if !found { return nil }
            i = j + 3
            continue
        }
        if charsetMatchAt(bytes, n, i, "<meta") && i + 5 < n
            && (charsetIsASCIIWhitespace(bytes[i + 5]) || bytes[i + 5] == 0x2f) {
            i += 5
            var seen: [[UInt8]] = []
            var contentValue: [UInt8]? = nil
            var gotPragma = false
            var needPragma: Bool? = nil
            var charset: TextEncoding? = nil
            while let (name, value) = charsetPrescanAttribute(bytes, n, &i) {
                if seen.contains(name) { continue }
                seen.append(name)
                if name == Array("http-equiv".utf8) {
                    if value == Array("content-type".utf8) { gotPragma = true }
                } else if name == Array("content".utf8) {
                    contentValue = value
                } else if name == Array("charset".utf8) {
                    charset = charsetEncodingForLabel(value); needPragma = false
                }
            }
            if let cv = contentValue, charset == nil && needPragma == nil {
                if let lab = charsetFromMetaContent(cv), let e = charsetEncodingForLabel(lab) {
                    charset = e; needPragma = true
                }
            }
            guard let np = needPragma, let cs = charset else { continue }
            if np && !gotPragma { continue }
            if cs == .utf16le || cs == .utf16be { return .utf8 }
            return cs
        }
        if i + 1 < n && bytes[i] == 0x3c
            && (charsetIsAlpha(bytes[i + 1]) || (bytes[i + 1] == 0x2f && i + 2 < n && charsetIsAlpha(bytes[i + 2]))) {
            i += 1
            if bytes[i] == 0x2f { i += 1 }
            while i < n && !charsetIsASCIIWhitespace(bytes[i]) && bytes[i] != 0x3e && bytes[i] != 0x2f { i += 1 }
            while charsetPrescanAttribute(bytes, n, &i) != nil {}
            i += 1
            continue
        }
        if i + 1 < n && bytes[i] == 0x3c && (bytes[i + 1] == 0x21 || bytes[i + 1] == 0x2f || bytes[i + 1] == 0x3f) {
            while i < n && bytes[i] != 0x3e { i += 1 }
            i += 1
            continue
        }
        i += 1
    }
    return nil
}

/// Pick the encoding for a document: Content-Type charset, then BOM, then
/// the <meta> prescan, then UTF-8. An unknown header label falls through to
/// the next step. (Note: the HTML spec lets a BOM beat the header; the
/// roadmap order is header first, which is what this does.)
func charsetDetectEncoding(contentType: [UInt8]?, body: [UInt8]) -> TextDetection {
    let hasUTF8BOM = body.count >= 3 && body[0] == 0xEF && body[1] == 0xBB && body[2] == 0xBF
    if let ct = contentType, let label = charsetFromContentType(ct),
       let enc = charsetEncodingForLabel(label) {
        return TextDetection(encoding: enc, source: .header,
                             bomLength: (enc == .utf8 && hasUTF8BOM) ? 3 : 0)
    }
    if hasUTF8BOM { return TextDetection(encoding: .utf8, source: .bom, bomLength: 3) }
    if body.count >= 2 && body[0] == 0xFF && body[1] == 0xFE {
        return TextDetection(encoding: .utf16le, source: .bom, bomLength: 2)
    }
    if body.count >= 2 && body[0] == 0xFE && body[1] == 0xFF {
        return TextDetection(encoding: .utf16be, source: .bom, bomLength: 2)
    }
    if let e = charsetPrescanMeta(body) {
        return TextDetection(encoding: e, source: .meta, bomLength: 0)
    }
    return TextDetection(encoding: .utf8, source: .fallback, bomLength: 0)
}

/// Detect and decode in one step.
func charsetDecodeDocument(contentType: [UInt8]?, body: [UInt8]) -> (scalars: [UInt32], detection: TextDetection) {
    let d = charsetDetectEncoding(contentType: contentType, body: body)
    return (charsetDecode(body, d.encoding, from: d.bomLength), d)
}
