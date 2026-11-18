// CSS Syntax Level 3 tokenizer. Input is UTF-8 bytes; it never traps and
// every loop advances, so hostile input only costs time linear in its size.

enum CSSToken {
    case ident(String)
    case function(String)
    case atKeyword(String)
    case hash(String, Bool)          // value, is a valid identifier (an id)
    case string(String)
    case badString
    case url(String)
    case badUrl
    case delim(UInt32)
    case number(Double, Bool)        // value, is an integer
    case percentage(Double)
    case dimension(Double, String, Bool)
    case whitespace
    case cdo, cdc
    case colon, semicolon, comma
    case openBracket, closeBracket, openParen, closeParen, openBrace, closeBrace
}

/// Largest stylesheet (bytes) the parser looks at; the rest is ignored.
let cssMaxInputBytes = 4 << 20

@inline(__always) func cssIsDigit(_ c: Int) -> Bool { c >= 0x30 && c <= 0x39 }
@inline(__always) func cssIsHexDigit(_ c: Int) -> Bool {
    (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
}
@inline(__always) func cssIsNameStart(_ c: Int) -> Bool {
    (c >= 0x61 && c <= 0x7a) || (c >= 0x41 && c <= 0x5a) || c == 0x5f || c >= 0x80
}
@inline(__always) func cssIsNameChar(_ c: Int) -> Bool { cssIsNameStart(c) || cssIsDigit(c) || c == 0x2d }
@inline(__always) func cssIsWS(_ c: Int) -> Bool { c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d || c == 0x0c }

func cssLower(_ s: String) -> String {
    var needs = false
    for b in s.utf8 where b >= 0x41 && b <= 0x5a { needs = true; break }
    if !needs { return s }
    var out: [UInt8] = []
    out.reserveCapacity(s.utf8.count)
    for b in s.utf8 { out.append(b >= 0x41 && b <= 0x5a ? b + 32 : b) }
    return String(decoding: out, as: UTF8.self)
}

func cssAppendUTF8(_ out: inout [UInt8], _ cp: UInt32) {
    var c = cp
    if c == 0 || c > 0x10ffff || (c >= 0xd800 && c <= 0xdfff) { c = 0xfffd }
    if c < 0x80 { out.append(UInt8(c)) }
    else if c < 0x800 { out.append(UInt8(0xc0 | (c >> 6))); out.append(UInt8(0x80 | (c & 0x3f))) }
    else if c < 0x10000 {
        out.append(UInt8(0xe0 | (c >> 12))); out.append(UInt8(0x80 | ((c >> 6) & 0x3f)))
        out.append(UInt8(0x80 | (c & 0x3f)))
    } else {
        out.append(UInt8(0xf0 | (c >> 18))); out.append(UInt8(0x80 | ((c >> 12) & 0x3f)))
        out.append(UInt8(0x80 | ((c >> 6) & 0x3f))); out.append(UInt8(0x80 | (c & 0x3f)))
    }
}

func cssIntString(_ v: Int) -> String {
    if v == 0 { return "0" }
    var n = v < 0 ? (v == Int.min ? Int.max : -v) : v
    var d: [UInt8] = []
    while n > 0 { d.append(UInt8(0x30 + n % 10)); n /= 10 }
    if v < 0 { d.append(0x2d) }
    d.reverse()
    return String(decoding: d, as: UTF8.self)
}

struct CSSTokenizer {
    let s: [UInt8]
    var i = 0

    init(_ bytes: [UInt8]) { s = bytes.count > cssMaxInputBytes ? Array(bytes[0..<cssMaxInputBytes]) : bytes }

    @inline(__always) func ch(_ k: Int) -> Int { k >= 0 && k < s.count ? Int(s[k]) : -1 }

    func validEscape(_ k: Int) -> Bool {
        let c = ch(k + 1)
        return ch(k) == 0x5c && c != -1 && c != 0x0a && c != 0x0d && c != 0x0c
    }

    func wouldStartIdent(_ k: Int) -> Bool {
        let c0 = ch(k)
        if c0 == 0x2d {
            let c1 = ch(k + 1)
            return cssIsNameStart(c1) || c1 == 0x2d || validEscape(k + 1)
        }
        if cssIsNameStart(c0) { return true }
        if c0 == 0x5c { return validEscape(k) }
        return false
    }

    func wouldStartNumber(_ k: Int) -> Bool {
        let c0 = ch(k)
        if c0 == 0x2b || c0 == 0x2d {
            let c1 = ch(k + 1)
            if cssIsDigit(c1) { return true }
            return c1 == 0x2e && cssIsDigit(ch(k + 2))
        }
        if c0 == 0x2e { return cssIsDigit(ch(k + 1)) }
        return cssIsDigit(c0)
    }

    /// `i` is just after the backslash.
    mutating func appendEscape(_ out: inout [UInt8]) {
        let c = ch(i)
        if c == -1 { cssAppendUTF8(&out, 0xfffd); return }
        if cssIsHexDigit(c) {
            var v: UInt32 = 0
            var n = 0
            while n < 6 && cssIsHexDigit(ch(i)) {
                let d = ch(i)
                let x = d <= 0x39 ? d - 0x30 : (d | 0x20) - 0x61 + 10
                v = v &* 16 &+ UInt32(x)
                i += 1; n += 1
            }
            if cssIsWS(ch(i)) { i += 1 }
            cssAppendUTF8(&out, v)
        } else {
            out.append(UInt8(c)); i += 1
        }
    }

    mutating func consumeName() -> String {
        var out: [UInt8] = []
        while true {
            let c = ch(i)
            if cssIsNameChar(c) { out.append(UInt8(c)); i += 1 }
            else if validEscape(i) { i += 1; appendEscape(&out) }
            else { break }
        }
        return String(decoding: out, as: UTF8.self)
    }

    mutating func consumeNumber() -> (Double, Bool) {
        var neg = false
        var isInt = true
        if ch(i) == 0x2b { i += 1 } else if ch(i) == 0x2d { neg = true; i += 1 }
        var v = 0.0
        while cssIsDigit(ch(i)) { v = min(v * 10 + Double(ch(i) - 0x30), 1e12); i += 1 }
        if ch(i) == 0x2e && cssIsDigit(ch(i + 1)) {
            isInt = false
            i += 1
            var scale = 0.1
            while cssIsDigit(ch(i)) {
                v += Double(ch(i) - 0x30) * scale
                scale *= 0.1
                i += 1
            }
        }
        if ch(i) == 0x65 || ch(i) == 0x45 {
            var k = i + 1
            var eneg = false
            if ch(k) == 0x2b || ch(k) == 0x2d { eneg = ch(k) == 0x2d; k += 1 }
            if cssIsDigit(ch(k)) {
                isInt = false
                var e = 0
                while cssIsDigit(ch(k)) { e = min(e * 10 + (ch(k) - 0x30), 400); k += 1 }
                i = k
                var m = 1.0
                var n = 0
                while n < e && m < 1e300 { m *= 10; n += 1 }
                v = eneg ? v / m : v * m
            }
        }
        v = min(v, 1e9)
        return (neg ? -v : v, isInt)
    }

    mutating func consumeNumeric() -> CSSToken {
        let (v, isInt) = consumeNumber()
        if wouldStartIdent(i) { return .dimension(v, consumeName(), isInt) }
        if ch(i) == 0x25 { i += 1; return .percentage(v) }
        return .number(v, isInt)
    }

    mutating func consumeString(_ quote: Int) -> CSSToken {
        var out: [UInt8] = []
        while true {
            let c = ch(i)
            if c == -1 { break }
            if c == quote { i += 1; break }
            if c == 0x0a || c == 0x0d || c == 0x0c { return .badString }
            if c == 0x5c {
                let n = ch(i + 1)
                if n == -1 { i += 1; continue }
                if n == 0x0a || n == 0x0d || n == 0x0c { i += 2; continue }
                i += 1
                appendEscape(&out)
                continue
            }
            out.append(UInt8(c)); i += 1
        }
        return .string(String(decoding: out, as: UTF8.self))
    }

    mutating func consumeBadUrlRemnants() {
        while true {
            let c = ch(i)
            if c == -1 { return }
            if c == 0x29 { i += 1; return }
            if validEscape(i) { i += 2 } else { i += 1 }
        }
    }

    mutating func consumeUrl() -> CSSToken {
        var out: [UInt8] = []
        while cssIsWS(ch(i)) { i += 1 }
        while true {
            let c = ch(i)
            if c == -1 { break }
            if c == 0x29 { i += 1; break }
            if cssIsWS(c) {
                while cssIsWS(ch(i)) { i += 1 }
                if ch(i) == 0x29 { i += 1; break }
                if ch(i) == -1 { break }
                consumeBadUrlRemnants()
                return .badUrl
            }
            if c == 0x22 || c == 0x27 || c == 0x28 || c < 0x20 || c == 0x7f {
                consumeBadUrlRemnants()
                return .badUrl
            }
            if c == 0x5c {
                if validEscape(i) { i += 1; appendEscape(&out) }
                else { consumeBadUrlRemnants(); return .badUrl }
                continue
            }
            out.append(UInt8(c)); i += 1
        }
        return .url(String(decoding: out, as: UTF8.self))
    }

    mutating func consumeIdentLike() -> CSSToken {
        let name = consumeName()
        if ch(i) == 0x28 {
            i += 1
            if cssLower(name) == "url" {
                var k = i
                while cssIsWS(ch(k)) { k += 1 }
                let q = ch(k)
                if q == 0x22 || q == 0x27 { return .function(name) }
                return consumeUrl()
            }
            return .function(name)
        }
        return .ident(name)
    }

    mutating func skipComments() {
        while ch(i) == 0x2f && ch(i + 1) == 0x2a {
            i += 2
            while i < s.count && !(s[i] == 0x2a && ch(i + 1) == 0x2f) { i += 1 }
            i = min(i + 2, s.count)
        }
    }

    mutating func next() -> CSSToken? {
        skipComments()
        let c = ch(i)
        if c == -1 { return nil }
        if cssIsWS(c) {
            while cssIsWS(ch(i)) { i += 1 }
            return .whitespace
        }
        switch c {
        case 0x22, 0x27:
            i += 1
            return consumeString(c)
        case 0x23: // #
            if cssIsNameChar(ch(i + 1)) || validEscape(i + 1) {
                let isID = wouldStartIdent(i + 1)
                i += 1
                return .hash(consumeName(), isID)
            }
            i += 1
            return .delim(0x23)
        case 0x28: i += 1; return .openParen
        case 0x29: i += 1; return .closeParen
        case 0x2c: i += 1; return .comma
        case 0x3a: i += 1; return .colon
        case 0x3b: i += 1; return .semicolon
        case 0x5b: i += 1; return .openBracket
        case 0x5d: i += 1; return .closeBracket
        case 0x7b: i += 1; return .openBrace
        case 0x7d: i += 1; return .closeBrace
        case 0x2b:
            if wouldStartNumber(i) { return consumeNumeric() }
            i += 1; return .delim(0x2b)
        case 0x2d:
            if wouldStartNumber(i) { return consumeNumeric() }
            if ch(i + 1) == 0x2d && ch(i + 2) == 0x3e { i += 3; return .cdc }
            if wouldStartIdent(i) { return consumeIdentLike() }
            i += 1; return .delim(0x2d)
        case 0x2e:
            if wouldStartNumber(i) { return consumeNumeric() }
            i += 1; return .delim(0x2e)
        case 0x3c:
            if ch(i + 1) == 0x21 && ch(i + 2) == 0x2d && ch(i + 3) == 0x2d { i += 4; return .cdo }
            i += 1; return .delim(0x3c)
        case 0x40:
            if wouldStartIdent(i + 1) { i += 1; return .atKeyword(consumeName()) }
            i += 1; return .delim(0x40)
        case 0x5c:
            if validEscape(i) { return consumeIdentLike() }
            i += 1; return .delim(0x5c)
        default:
            if cssIsDigit(c) { return consumeNumeric() }
            if cssIsNameStart(c) { return consumeIdentLike() }
            i += 1
            return .delim(UInt32(c))
        }
    }
}

func cssTokenize(_ bytes: [UInt8]) -> [CSSToken] {
    var t = CSSTokenizer(bytes)
    var out: [CSSToken] = []
    while let tok = t.next() { out.append(tok) }
    return out
}
