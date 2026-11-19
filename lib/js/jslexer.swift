// lib/js lexer: the ES2022 lexical grammar (ECMA-262 §12) plus Annex B
// HTML-like comments.
//
// The lexer is driven by the parser (jsparser.swift). It always reads `/`
// as division and `}` as a punctuator; the parser, which knows whether an
// expression may start, asks for a rescan as a regex literal
// (`rescanRegExp`) or as a template continuation (`rescanTemplate`). That
// is how the `/` ambiguity and `${ }` nesting are resolved, with no lexer
// state beyond the read position.
//
// Strict-mode-only rules (legacy octal literals and escapes) are not
// errors here; the token carries flags and the parser decides.

enum JSTok: UInt8 {
    case eof, name, privateName, string, number, bigint
    case template, templateHead, templateMiddle, templateTail, regexp
    case lbrace, rbrace, lparen, rparen, lbracket, rbracket
    case dot, ellipsis, semicolon, comma, colon, question, questionDot, arrow
    case lt, gt, le, ge, eq, ne, strictEq, strictNe
    case plus, minus, star, slash, percent, starStar, inc, dec
    case shl, sar, shr, amp, pipe, caret, bang, tilde, andAnd, orOr, nullish
    // Same order as JSAssignOp.
    case assign, plusAssign, minusAssign, starAssign, slashAssign, percentAssign
    case starStarAssign, shlAssign, sarAssign, shrAssign, ampAssign, pipeAssign
    case caretAssign, andAndAssign, orOrAssign, nullishAssign
}

struct JSToken {
    var kind: JSTok = .eof
    /// A line terminator came before this token (for ASI).
    var nl = false
    /// A name written with \u escapes (so never a keyword).
    var escaped = false
    /// Number/string flags (JSNodeFlags), or for templates 1 = bad escape.
    var flags: UInt16 = 0
    var start = 0
    var end = 0
    /// name/string/privateName/bigint: string id. number: numbers index.
    /// template parts: cooked string id (-1 when invalid). regexp: pattern.
    var value: Int32 = -1
    /// template parts: raw string id. regexp: flags string id.
    var value2: Int32 = -1
}

let jsPow10: [Double] = [1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11,
                         1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22]

@inline(__always) func jsIsASCIIIdentStart(_ c: UInt8) -> Bool {
    (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || c == 0x24 || c == 0x5F
}

@inline(__always) func jsIsASCIIIdentPart(_ c: UInt8) -> Bool {
    jsIsASCIIIdentStart(c) || (c >= 0x30 && c <= 0x39)
}

@inline(__always) func jsHexValue(_ c: UInt8) -> Int {
    if c >= 0x30 && c <= 0x39 { return Int(c) - 0x30 }
    if c >= 0x61 && c <= 0x66 { return Int(c) - 0x61 + 10 }
    if c >= 0x41 && c <= 0x46 { return Int(c) - 0x41 + 10 }
    return -1
}

private func jsB64(_ c: UInt8) -> UInt64 {
    if c >= 0x41 && c <= 0x5A { return UInt64(c - 0x41) }
    if c >= 0x61 && c <= 0x7A { return UInt64(c - 0x61 + 26) }
    if c >= 0x30 && c <= 0x39 { return UInt64(c - 0x30 + 52) }
    return c == 0x2B ? 62 : 63
}

private func jsInRangeTable(_ cp: UInt32, _ table: StaticString, _ count: Int) -> Bool {
    let p = table.utf8Start
    var lo = 0, hi = count - 1
    while lo <= hi {
        let mid = (lo + hi) >> 1
        var v: UInt64 = 0
        for k in 0..<7 { v = v << 6 | jsB64(p[mid * 7 + k]) }
        let first = UInt32(v & 0x1FFFFF), last = UInt32(v >> 21)
        if cp < first { hi = mid - 1 } else if cp > last { lo = mid + 1 } else { return true }
    }
    return false
}

/// Unicode ID_Start (for code points >= 0x80; ASCII is handled inline).
func jsIsIDStart(_ cp: UInt32) -> Bool {
    if cp < 0x80 { return jsIsASCIIIdentStart(UInt8(cp)) }
    return jsInRangeTable(cp, jsIDStartTable, jsIDStartTableCount)
}

/// Unicode ID_Continue, plus $ and the ZWNJ/ZWJ that IdentifierPart allows.
func jsIsIDContinue(_ cp: UInt32) -> Bool {
    if cp < 0x80 { return jsIsASCIIIdentPart(UInt8(cp)) }
    if cp == 0x200C || cp == 0x200D { return true }
    return jsInRangeTable(cp, jsIDStartTable, jsIDStartTableCount)
        || jsInRangeTable(cp, jsIDContinueOnlyTable, jsIDContinueOnlyTableCount)
}

/// WhiteSpace beyond ASCII: NBSP, ZWNBSP and category Zs.
func jsIsUnicodeSpace(_ cp: UInt32) -> Bool {
    switch cp {
    case 0xA0, 0xFEFF, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000: return true
    default: return false
    }
}

final class JSLexer {
    let ast: JSAST
    let n: Int
    private let buf: UnsafeMutablePointer<UInt8>
    var pos = 0
    /// Script goal (HTML-like comments are allowed); false for modules.
    var htmlComments = true
    private var scratch: [UInt16] = []

    init(_ ast: JSAST) {
        self.ast = ast
        n = ast.source.count
        buf = UnsafeMutablePointer<UInt8>.allocate(capacity: n + 1)
        ast.source.withUnsafeBufferPointer { src in
            if let b = src.baseAddress { buf.initialize(from: b, count: n) }
        }
        buf[n] = 0
        // A hashbang comment (ES2023, but every engine takes it).
        if n >= 2 && buf[0] == 0x23 && buf[1] == 0x21 {
            pos = 2
            while pos < n && !isLineTerminatorAt(pos) { pos += 1 }
        }
    }

    deinit { buf.deallocate() }

    @inline(__always) func at(_ i: Int) -> UInt8 { i < n && i >= 0 ? buf[i] : 0 }

    func fail(_ msg: String, _ offset: Int) -> JSSyntaxError {
        let loc = JSLineMap(ast.source).location(offset)
        return JSSyntaxError(message: msg, offset: offset, line: loc.line, column: loc.column)
    }

    /// The code point at i and its byte length (invalid UTF-8: U+FFFD, 1).
    @inline(__always) func decode(_ i: Int) -> (UInt32, Int) {
        let c0 = at(i)
        if c0 < 0x80 { return (UInt32(c0), 1) }
        if c0 >= 0xC2 && c0 < 0xE0 {
            let c1 = at(i + 1)
            if c1 & 0xC0 == 0x80 { return (UInt32(c0 & 0x1F) << 6 | UInt32(c1 & 0x3F), 2) }
        } else if c0 >= 0xE0 && c0 < 0xF0 {
            let c1 = at(i + 1), c2 = at(i + 2)
            if c1 & 0xC0 == 0x80 && c2 & 0xC0 == 0x80 {
                let cp = UInt32(c0 & 0x0F) << 12 | UInt32(c1 & 0x3F) << 6 | UInt32(c2 & 0x3F)
                if cp >= 0x800 { return (cp, 3) }
            }
        } else if c0 >= 0xF0 && c0 < 0xF5 {
            let c1 = at(i + 1), c2 = at(i + 2), c3 = at(i + 3)
            if c1 & 0xC0 == 0x80 && c2 & 0xC0 == 0x80 && c3 & 0xC0 == 0x80 {
                let cp = UInt32(c0 & 0x07) << 18 | UInt32(c1 & 0x3F) << 12
                    | UInt32(c2 & 0x3F) << 6 | UInt32(c3 & 0x3F)
                if cp >= 0x10000 && cp <= 0x10FFFF { return (cp, 4) }
            }
        }
        return (0xFFFD, 1)
    }

    @inline(__always) func isLineTerminatorAt(_ i: Int) -> Bool {
        let c = at(i)
        if c == 0x0A || c == 0x0D { return true }
        return c == 0xE2 && at(i + 1) == 0x80 && (at(i + 2) == 0xA8 || at(i + 2) == 0xA9)
    }

    @inline(__always) private func appendUnit(_ cp: UInt32) {
        if cp < 0x10000 {
            scratch.append(UInt16(cp))
        } else {
            let v = cp - 0x10000
            scratch.append(UInt16(0xD800 + (v >> 10)))
            scratch.append(UInt16(0xDC00 + (v & 0x3FF)))
        }
    }

    // ------------------------------------------------------------ skipping

    /// Skip whitespace and comments; returns whether a line terminator was
    /// crossed.
    private func skipTrivia() throws(JSSyntaxError) -> Bool {
        var nl = pos == 0
        let startPos = pos
        while pos < n {
            let c = buf[pos]
            switch c {
            case 0x20, 0x09, 0x0B, 0x0C:
                pos += 1
            case 0x0A, 0x0D:
                pos += 1; nl = true
            case 0x2F: // '/'
                let d = at(pos + 1)
                if d == 0x2F {
                    pos += 2
                    skipLine()
                } else if d == 0x2A {
                    let open = pos
                    pos += 2
                    var closed = false
                    while pos < n {
                        let e = buf[pos]
                        if e == 0x2A && at(pos + 1) == 0x2F { pos += 2; closed = true; break }
                        if e == 0x0A || e == 0x0D { nl = true; pos += 1; continue }
                        if e == 0xE2 && isLineTerminatorAt(pos) { nl = true; pos += 3; continue }
                        pos += 1
                    }
                    if !closed { throw fail("unterminated comment", open) }
                } else {
                    return nl
                }
            case 0x3C: // '<!--'
                if htmlComments && at(pos + 1) == 0x21 && at(pos + 2) == 0x2D && at(pos + 3) == 0x2D {
                    pos += 4
                    skipLine()
                } else {
                    return nl
                }
            case 0x2D: // '-->' at the start of a line
                if htmlComments && (nl || startPos == 0) && at(pos + 1) == 0x2D && at(pos + 2) == 0x3E {
                    pos += 3
                    skipLine()
                } else {
                    return nl
                }
            default:
                if c < 0x80 { return nl }
                let (cp, len) = decode(pos)
                if cp == 0x2028 || cp == 0x2029 {
                    nl = true; pos += len
                } else if jsIsUnicodeSpace(cp) {
                    pos += len
                } else {
                    return nl
                }
            }
        }
        return nl
    }

    private func skipLine() {
        while pos < n {
            let c = buf[pos]
            if c == 0x0A || c == 0x0D { return }
            if c == 0xE2 && isLineTerminatorAt(pos) { return }
            pos += 1
        }
    }

    // ------------------------------------------------------------ tokens

    func next() throws(JSSyntaxError) -> JSToken {
        var t = JSToken()
        t.nl = try skipTrivia()
        t.start = pos
        if pos >= n { t.kind = .eof; t.end = pos; return t }
        let c = buf[pos]
        if jsIsASCIIIdentStart(c) || c == 0x5C || c >= 0x80 {
            if c >= 0x80 {
                let (cp, _) = decode(pos)
                if !jsIsIDStart(cp) { throw fail("unexpected character", pos) }
            }
            try scanName(&t)
            return t
        }
        if c >= 0x30 && c <= 0x39 { try scanNumber(&t); return t }
        pos += 1
        switch c {
        case 0x22, 0x27: try scanString(&t, c)
        case 0x60: try scanTemplate(&t, head: true)
        case 0x7B: t.kind = .lbrace
        case 0x7D: t.kind = .rbrace
        case 0x28: t.kind = .lparen
        case 0x29: t.kind = .rparen
        case 0x5B: t.kind = .lbracket
        case 0x5D: t.kind = .rbracket
        case 0x3B: t.kind = .semicolon
        case 0x2C: t.kind = .comma
        case 0x3A: t.kind = .colon
        case 0x7E: t.kind = .tilde
        case 0x2E:
            let d = at(pos)
            if d >= 0x30 && d <= 0x39 { pos -= 1; try scanNumber(&t); return t }
            if d == 0x2E && at(pos + 1) == 0x2E { pos += 2; t.kind = .ellipsis } else { t.kind = .dot }
        case 0x3F: // ?
            let d = at(pos)
            if d == 0x2E && !(at(pos + 1) >= 0x30 && at(pos + 1) <= 0x39) { pos += 1; t.kind = .questionDot }
            else if d == 0x3F {
                pos += 1
                if at(pos) == 0x3D { pos += 1; t.kind = .nullishAssign } else { t.kind = .nullish }
            } else { t.kind = .question }
        case 0x3D: // =
            if at(pos) == 0x3D {
                pos += 1
                if at(pos) == 0x3D { pos += 1; t.kind = .strictEq } else { t.kind = .eq }
            } else if at(pos) == 0x3E { pos += 1; t.kind = .arrow } else { t.kind = .assign }
        case 0x21: // !
            if at(pos) == 0x3D {
                pos += 1
                if at(pos) == 0x3D { pos += 1; t.kind = .strictNe } else { t.kind = .ne }
            } else { t.kind = .bang }
        case 0x3C: // <
            if at(pos) == 0x3C {
                pos += 1
                if at(pos) == 0x3D { pos += 1; t.kind = .shlAssign } else { t.kind = .shl }
            } else if at(pos) == 0x3D { pos += 1; t.kind = .le } else { t.kind = .lt }
        case 0x3E: // >
            if at(pos) == 0x3E {
                pos += 1
                if at(pos) == 0x3E {
                    pos += 1
                    if at(pos) == 0x3D { pos += 1; t.kind = .shrAssign } else { t.kind = .shr }
                } else if at(pos) == 0x3D { pos += 1; t.kind = .sarAssign } else { t.kind = .sar }
            } else if at(pos) == 0x3D { pos += 1; t.kind = .ge } else { t.kind = .gt }
        case 0x2B: // +
            if at(pos) == 0x2B { pos += 1; t.kind = .inc }
            else if at(pos) == 0x3D { pos += 1; t.kind = .plusAssign } else { t.kind = .plus }
        case 0x2D: // -
            if at(pos) == 0x2D { pos += 1; t.kind = .dec }
            else if at(pos) == 0x3D { pos += 1; t.kind = .minusAssign } else { t.kind = .minus }
        case 0x2A: // *
            if at(pos) == 0x2A {
                pos += 1
                if at(pos) == 0x3D { pos += 1; t.kind = .starStarAssign } else { t.kind = .starStar }
            } else if at(pos) == 0x3D { pos += 1; t.kind = .starAssign } else { t.kind = .star }
        case 0x2F: // / (division; the parser rescans regex literals)
            if at(pos) == 0x3D { pos += 1; t.kind = .slashAssign } else { t.kind = .slash }
        case 0x25:
            if at(pos) == 0x3D { pos += 1; t.kind = .percentAssign } else { t.kind = .percent }
        case 0x26: // &
            if at(pos) == 0x26 {
                pos += 1
                if at(pos) == 0x3D { pos += 1; t.kind = .andAndAssign } else { t.kind = .andAnd }
            } else if at(pos) == 0x3D { pos += 1; t.kind = .ampAssign } else { t.kind = .amp }
        case 0x7C: // |
            if at(pos) == 0x7C {
                pos += 1
                if at(pos) == 0x3D { pos += 1; t.kind = .orOrAssign } else { t.kind = .orOr }
            } else if at(pos) == 0x3D { pos += 1; t.kind = .pipeAssign } else { t.kind = .pipe }
        case 0x5E:
            if at(pos) == 0x3D { pos += 1; t.kind = .caretAssign } else { t.kind = .caret }
        case 0x23: // #name
            let d = at(pos)
            var ok = jsIsASCIIIdentStart(d) || d == 0x5C
            if d >= 0x80 { ok = jsIsIDStart(decode(pos).0) }
            if !ok { throw fail("unexpected character '#'", pos - 1) }
            try scanName(&t)
            t.kind = .privateName
        default:
            throw fail("unexpected character", pos - 1)
        }
        t.end = pos
        return t
    }

    // ------------------------------------------------------------ names

    /// IdentifierName starting at pos (t.start is set by the caller; for
    /// private names it points at '#').
    private func scanName(_ t: inout JSToken) throws(JSSyntaxError) {
        let begin = pos
        while pos < n && jsIsASCIIIdentPart(buf[pos]) { pos += 1 }
        let c = at(pos)
        if c != 0x5C && c < 0x80 {
            t.kind = .name
            t.value = ast.pool.internASCII(UnsafePointer(buf), begin, pos)
            t.end = pos
            return
        }
        // Slow path: escapes or non-ASCII.
        scratch.removeAll(keepingCapacity: true)
        var i = begin
        while i < pos { scratch.append(UInt16(buf[i])); i += 1 }
        while pos < n {
            let d = buf[pos]
            if jsIsASCIIIdentPart(d) { scratch.append(UInt16(d)); pos += 1; continue }
            if d == 0x5C {
                let esc = pos
                if at(pos + 1) != 0x75 { throw fail("invalid escape in identifier", esc) }
                pos += 2
                guard let cp = scanUnicodeEscapeBody() else { throw fail("invalid escape in identifier", esc) }
                let first = scratch.isEmpty
                if first ? !jsIsIDStart(cp) : !jsIsIDContinue(cp) {
                    throw fail("invalid identifier character", esc)
                }
                appendUnit(cp)
                t.escaped = true
                continue
            }
            if d >= 0x80 {
                let (cp, len) = decode(pos)
                if !jsIsIDContinue(cp) { break }
                appendUnit(cp)
                pos += len
                continue
            }
            break
        }
        t.kind = .name
        t.value = ast.pool.intern(scratch[...])
        t.end = pos
    }

    /// After `\u`: XXXX or {X...}; nil if malformed or above 0x10FFFF.
    private func scanUnicodeEscapeBody() -> UInt32? {
        if at(pos) == 0x7B {
            pos += 1
            var v: UInt32 = 0
            var digits = 0
            while true {
                let c = at(pos)
                if c == 0x7D { pos += 1; break }
                let h = jsHexValue(c)
                if h < 0 { return nil }
                v = v * 16 + UInt32(h)
                if v > 0x10FFFF { return nil }
                digits += 1
                pos += 1
            }
            return digits == 0 ? nil : v
        }
        var v: UInt32 = 0
        for _ in 0..<4 {
            let h = jsHexValue(at(pos))
            if h < 0 { return nil }
            v = v * 16 + UInt32(h)
            pos += 1
        }
        return v
    }

    // ------------------------------------------------------------ numbers

    private func scanNumber(_ t: inout JSToken) throws(JSSyntaxError) {
        let begin = pos
        var value: Double = 0
        var flags: UInt16 = 0
        var isBigInt = false
        let c0 = at(pos), c1 = at(pos + 1)
        if c0 == 0x30 && (c1 | 0x20 == 0x78 || c1 | 0x20 == 0x6F || c1 | 0x20 == 0x62) {
            let radix: Double = c1 | 0x20 == 0x78 ? 16 : c1 | 0x20 == 0x6F ? 8 : 2
            pos += 2
            var digits = 0
            var lastSep = false
            while true {
                let c = at(pos)
                if c == 0x5F {
                    if digits == 0 || lastSep { throw fail("invalid numeric separator", pos) }
                    lastSep = true; pos += 1; continue
                }
                let h = jsHexValue(c)
                if h < 0 || Double(h) >= radix { break }
                value = value * radix + Double(h)
                digits += 1
                lastSep = false
                pos += 1
            }
            if lastSep { throw fail("invalid numeric separator", pos - 1) }
            if digits == 0 { throw fail("missing digits after radix prefix", begin) }
            if value >= 9007199254740992 { value = jsDigitsToDouble(digitValues(begin + 2, pos), Int(radix)) }
            if at(pos) == 0x6E { pos += 1; isBigInt = true }
        } else if c0 == 0x30 && c1 >= 0x30 && c1 <= 0x39 {
            // Legacy octal (017) or a NonOctalDecimalIntegerLiteral (08, 09).
            var octal = true
            var i = pos + 1
            while at(i) >= 0x30 && at(i) <= 0x39 { if at(i) >= 0x38 { octal = false }; i += 1 }
            if octal {
                pos += 1
                while at(pos) >= 0x30 && at(pos) <= 0x37 {
                    value = value * 8 + Double(at(pos) - 0x30); pos += 1
                }
                flags |= JSNodeFlags.legacyOctal
                if value >= 9007199254740992 { value = jsDigitsToDouble(digitValues(begin + 1, pos), 8) }
            } else {
                flags |= JSNodeFlags.nonOctalDecimal
                try scanDecimal(&value, &flags, allowSeparators: false)
            }
            if at(pos) == 0x5F { throw fail("invalid numeric separator", pos) }
        } else {
            let hasDot = try scanDecimal(&value, &flags, allowSeparators: true)
            if at(pos) == 0x6E {
                if hasDot { throw fail("invalid BigInt literal", begin) }
                pos += 1; isBigInt = true
            }
        }
        // The literal must not run into an identifier or another digit.
        let c = at(pos)
        if jsIsASCIIIdentPart(c) || c == 0x5C || (c >= 0x80 && jsIsIDStart(decode(pos).0)) {
            throw fail("identifier starts immediately after numeric literal", pos)
        }
        t.start = begin
        t.end = pos
        if isBigInt {
            t.kind = .bigint
            scratch.removeAll(keepingCapacity: true)
            for i in begin..<(pos - 1) where buf[i] != 0x5F { scratch.append(UInt16(buf[i])) }
            t.value = ast.pool.intern(scratch[...])
        } else {
            t.kind = .number
            t.flags = flags
            t.value = Int32(truncatingIfNeeded: ast.numbers.count)
            ast.numbers.append(value)
        }
    }

    /// Digit values of buf[from..<to], separators skipped.
    private func digitValues(_ from: Int, _ to: Int) -> [UInt8] {
        var out: [UInt8] = []
        for i in from..<to where buf[i] != 0x5F { out.append(UInt8(truncatingIfNeeded: jsHexValue(buf[i]))) }
        return out
    }

    /// DecimalLiteral from pos (also `.5`). Returns whether it had a
    /// fraction or exponent (no BigInt then).
    @discardableResult
    private func scanDecimal(_ value: inout Double, _ flags: inout UInt16,
                             allowSeparators: Bool) throws(JSSyntaxError) -> Bool {
        let litStart = pos
        var mant: UInt64 = 0
        var sig = 0           // significant digits taken into mant
        var dropped = 0       // integer digits beyond 19 (scale up)
        var exp10 = 0
        var nonFinite = false
        var sawDotOrExp = false
        let leadingZero = at(pos) == 0x30

        func digits(_ frac: Bool) throws(JSSyntaxError) -> Int {
            var count = 0
            var lastSep = false
            while true {
                let c = at(pos)
                if c == 0x5F {
                    if !allowSeparators || count == 0 || lastSep {
                        throw fail("invalid numeric separator", pos)
                    }
                    lastSep = true; pos += 1; continue
                }
                if c < 0x30 || c > 0x39 { break }
                let d = UInt64(c - 0x30)
                if mant == 0 && d == 0 {
                    if frac { exp10 -= 1 }
                } else if sig < 19 {
                    mant = mant * 10 + d
                    sig += 1
                    if frac { exp10 -= 1 }
                } else {
                    if !frac { dropped += 1 }
                    if d != 0 { nonFinite = true }  // digits lost: inexact
                }
                count += 1
                lastSep = false
                pos += 1
            }
            if lastSep { throw fail("invalid numeric separator", pos - 1) }
            return count
        }

        var intDigits = 0
        if at(pos) != 0x2E {
            if leadingZero && at(pos + 1) == 0x5F && allowSeparators {
                throw fail("invalid numeric separator", pos + 1)
            }
            intDigits = try digits(false)
        }
        if at(pos) == 0x2E {
            sawDotOrExp = true
            pos += 1
            let f = try digits(true)
            if intDigits == 0 && f == 0 { throw fail("invalid number", pos) }
        }
        let ce = at(pos)
        if ce == 0x65 || ce == 0x45 {
            sawDotOrExp = true
            pos += 1
            var neg = false
            if at(pos) == 0x2B || at(pos) == 0x2D { neg = at(pos) == 0x2D; pos += 1 }
            var e = 0
            var count = 0
            var lastSep = false
            while true {
                let c = at(pos)
                if c == 0x5F {
                    if !allowSeparators || count == 0 || lastSep { throw fail("invalid numeric separator", pos) }
                    lastSep = true; pos += 1; continue
                }
                if c < 0x30 || c > 0x39 { break }
                if e < 100000 { e = e * 10 + Int(c - 0x30) }
                count += 1
                lastSep = false
                pos += 1
            }
            if count == 0 || lastSep { throw fail("missing exponent digits", pos) }
            exp10 += neg ? -e : e
        }
        exp10 += dropped
        if mant == 0 {
            value = 0
        } else if mant < (1 << 53) && exp10 >= -22 && exp10 <= 22 && !nonFinite {
            value = exp10 >= 0 ? Double(mant) * jsPow10[exp10] : Double(mant) / jsPow10[-exp10]
        } else if mant < (1 << 53) && exp10 > 22 && exp10 <= 22 + 15 && !nonFinite
                    && Double(mant) * jsPow10[exp10 - 22] < 9007199254740992 {
            value = Double(mant) * jsPow10[exp10 - 22] * 1e22
        } else {
            // Correctly rounded slow path (jsnumber.swift).
            var text: [UInt8] = []
            for i in litStart..<pos where buf[i] != 0x5F { text.append(buf[i]) }
            value = jsStringToNumber(text)
        }
        return sawDotOrExp
    }

    // ------------------------------------------------------------ strings

    private func scanString(_ t: inout JSToken, _ quote: UInt8) throws(JSSyntaxError) {
        let begin = pos
        // Fast path: ASCII without escapes.
        var i = pos
        while i < n {
            let c = buf[i]
            if c == quote || c == 0x5C || c >= 0x80 || c == 0x0A || c == 0x0D { break }
            i += 1
        }
        if i < n && buf[i] == quote {
            t.kind = .string
            t.value = ast.pool.internASCII(UnsafePointer(buf), begin, i)
            pos = i + 1
            return
        }
        scratch.removeAll(keepingCapacity: true)
        while pos < i { scratch.append(UInt16(buf[pos])); pos += 1 }
        var flags: UInt16 = 0
        while true {
            if pos >= n { throw fail("unterminated string", begin - 1) }
            let c = buf[pos]
            if c == quote { pos += 1; break }
            if c == 0x0A || c == 0x0D { throw fail("unterminated string", begin - 1) }
            if c == 0x5C {
                pos += 1
                let r = scanEscape(template: false)
                if r == 2 { throw fail("invalid escape sequence", pos - 1) }
                if r == 1 { flags |= JSNodeFlags.octalEscape }
                continue
            }
            if c < 0x80 { scratch.append(UInt16(c)); pos += 1; continue }
            let (cp, len) = decode(pos)
            appendUnit(cp)
            pos += len
        }
        t.kind = .string
        t.flags = flags
        t.value = ast.pool.intern(scratch[...])
    }

    /// After a backslash: append the escape's value to scratch. Returns 0
    /// for a plain escape, 1 for a legacy octal or \8 \9 escape (strings
    /// only), 2 for a malformed escape.
    private func scanEscape(template: Bool) -> Int {
        let c = at(pos)
        if pos >= n { return 2 }
        pos += 1
        switch c {
        case 0x6E: scratch.append(10)
        case 0x74: scratch.append(9)
        case 0x72: scratch.append(13)
        case 0x62: scratch.append(8)
        case 0x66: scratch.append(12)
        case 0x76: scratch.append(11)
        case 0x0A: break
        case 0x0D: if at(pos) == 0x0A { pos += 1 }
        case 0x30...0x37:
            let d1 = at(pos)
            if c == 0x30 && !(d1 >= 0x30 && d1 <= 0x39) { scratch.append(0); return 0 }
            if template { return 2 }
            var v = UInt32(c - 0x30)
            if d1 >= 0x30 && d1 <= 0x37 {
                v = v * 8 + UInt32(d1 - 0x30); pos += 1
                let d2 = at(pos)
                if c <= 0x33 && d2 >= 0x30 && d2 <= 0x37 { v = v * 8 + UInt32(d2 - 0x30); pos += 1 }
            }
            scratch.append(UInt16(v))
            return 1
        case 0x38, 0x39:
            if template { return 2 }
            scratch.append(UInt16(c))
            return 1
        case 0x78:
            let h1 = jsHexValue(at(pos)), h2 = jsHexValue(at(pos + 1))
            if h1 < 0 || h2 < 0 { return 2 }
            pos += 2
            scratch.append(UInt16(h1 * 16 + h2))
        case 0x75:
            guard let cp = scanUnicodeEscapeBody() else { return 2 }
            appendUnit(cp)
        default:
            if c < 0x80 { scratch.append(UInt16(c)); return 0 }
            pos -= 1
            let (cp, len) = decode(pos)
            pos += len
            if cp == 0x2028 || cp == 0x2029 { return 0 }  // line continuation
            appendUnit(cp)
        }
        return 0
    }

    // ------------------------------------------------------------ templates

    /// Template characters from pos (just after '`' or '}') up to '`' or
    /// '${'. Cooked value in value (-1 if an escape is invalid), raw in value2.
    private func scanTemplate(_ t: inout JSToken, head: Bool) throws(JSSyntaxError) {
        let begin = pos
        scratch.removeAll(keepingCapacity: true)
        var bad = false
        var rawEnd = 0
        var tail = false
        while true {
            if pos >= n { throw fail("unterminated template literal", begin - 1) }
            let c = buf[pos]
            if c == 0x60 { rawEnd = pos; pos += 1; tail = true; break }
            if c == 0x24 && at(pos + 1) == 0x7B { rawEnd = pos; pos += 2; break }
            if c == 0x5C {
                pos += 1
                if scanEscape(template: true) != 0 { bad = true }
                continue
            }
            if c == 0x0D {
                pos += 1
                if at(pos) == 0x0A { pos += 1 }
                scratch.append(10)
                continue
            }
            if c < 0x80 { scratch.append(UInt16(c)); pos += 1; continue }
            let (cp, len) = decode(pos)
            appendUnit(cp)
            pos += len
        }
        t.value = bad ? -1 : ast.pool.intern(scratch[...])
        t.flags = bad ? 1 : 0
        // Raw: the source text with CR and CRLF normalised to LF.
        scratch.removeAll(keepingCapacity: true)
        var i = begin
        while i < rawEnd {
            let c = buf[i]
            if c == 0x0D {
                scratch.append(10)
                i += at(i + 1) == 0x0A ? 2 : 1
                continue
            }
            if c < 0x80 { scratch.append(UInt16(c)); i += 1; continue }
            let (cp, len) = decode(i)
            appendUnit(cp)
            i += len
        }
        t.value2 = ast.pool.intern(scratch[...])
        if head { t.kind = tail ? .template : .templateHead } else { t.kind = tail ? .templateTail : .templateMiddle }
    }

    /// Rescan from the `}` at `offset` as a template middle or tail.
    func rescanTemplate(_ offset: Int) throws(JSSyntaxError) -> JSToken {
        pos = offset + 1
        var t = JSToken()
        t.start = offset
        try scanTemplate(&t, head: false)
        t.end = pos
        return t
    }

    // ------------------------------------------------------------ regexps

    /// Rescan from the `/` at `offset` as a regular expression literal.
    func rescanRegExp(_ offset: Int) throws(JSSyntaxError) -> JSToken {
        pos = offset + 1
        var inClass = false
        let bodyStart = pos
        while true {
            if pos >= n || isLineTerminatorAt(pos) { throw fail("unterminated regular expression", offset) }
            let c = buf[pos]
            if c == 0x5C {
                pos += 1
                if pos >= n || isLineTerminatorAt(pos) { throw fail("unterminated regular expression", offset) }
                pos += decode(pos).1
                continue
            }
            if c == 0x5B { inClass = true } else if c == 0x5D { inClass = false }
            else if c == 0x2F && !inClass { break }
            pos += c < 0x80 ? 1 : decode(pos).1
        }
        let bodyEnd = pos
        pos += 1
        let flagStart = pos
        while pos < n {
            let c = buf[pos]
            if jsIsASCIIIdentPart(c) { pos += 1; continue }
            if c == 0x5C { throw fail("escape in regular expression flags", pos) }
            if c >= 0x80 {
                let (cp, len) = decode(pos)
                if jsIsIDContinue(cp) { pos += len; continue }
            }
            break
        }
        var t = JSToken()
        t.kind = .regexp
        t.start = offset
        t.end = pos
        scratch.removeAll(keepingCapacity: true)
        var i = bodyStart
        while i < bodyEnd {
            let (cp, len) = decode(i)
            appendUnit(cp)
            i += len
        }
        t.value = ast.pool.intern(scratch[...])
        scratch.removeAll(keepingCapacity: true)
        i = flagStart
        while i < pos {
            let (cp, len) = decode(i)
            appendUnit(cp)
            i += len
        }
        t.value2 = ast.pool.intern(scratch[...])
        return t
    }
}
