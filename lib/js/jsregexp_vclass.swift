// `v` flag (unicodeSets, ES2024) character classes: ClassSetExpression with
// nested classes, union, `&&` intersection, `--` subtraction and
// `\q{...}` string disjunctions, plus the reserved double punctuators.
// With `i`, every operand is case folded first and complements are taken
// among the folded characters (the spec's MaybeSimpleCaseFolding and
// CharacterComplement), so the matcher just folds the input. A class with
// strings compiles to an alternation, longest strings first. Properties of
// strings (\p{RGI_Emoji} and friends) are not supported: a SyntaxError.

/// Characters plus strings (strings of length 1 are kept in `chars`).
struct JSReClassSet {
    var chars = JSReCharSet()
    var strings: [[UInt32]] = []

    mutating func addString(_ s: [UInt32]) {
        if s.count == 1 { chars.add(s[0], s[0]); return }
        for o in strings where o == s { return }
        strings.append(s)
    }
}

extension JSReParser {
    @inline(__always) func at(_ k: Int) -> UInt16 { k < n ? p[k] : 0 }

    func isDoublePunct(_ k: Int) -> Bool {
        guard k + 1 < n, p[k] == p[k + 1] else { return false }
        switch p[k] {
        case 0x26, 0x21, 0x23, 0x24, 0x25, 0x2A, 0x2B, 0x2C, 0x2E, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x40,
             0x5E, 0x60, 0x7E: return true
        default: return false
        }
    }

    /// Fold a set for v + i (identity otherwise).
    func vFold(_ s: JSReCharSet) -> JSReCharSet {
        foldRuns.isEmpty ? s : jsReCanonicalImage(s, foldRuns)
    }

    func vComplement(_ s: JSReCharSet) -> JSReCharSet {
        let c = s.inverted(max: 0x10FFFF)
        if foldRuns.isEmpty { return c }
        // Only folded characters exist in this space.
        var moved = JSReCharSet()
        for r in foldRuns {
            let start = UInt32(r & 0x1FFFFF), count = UInt32((r >> 21) & 0x7FF)
            let step: UInt32 = (r >> 32) & 1 != 0 ? 2 : 1
            var k: UInt32 = 0
            while k < count { moved.add(start + k * step, start + k * step); k += 1 }
        }
        moved.normalize()
        return c.subtracting(moved)
    }

    mutating func vCharacterClass() throws(JSRegExpError) -> Int32 {
        i += 1
        var negate = false
        if i < n && p[i] == 0x5E { negate = true; i += 1 }
        var cs = try vContents(depth: 0)
        if negate {
            if !cs.strings.isEmpty { throw err("negated character class may contain strings") }
            cs.chars = vComplement(cs.chars)
        }
        if cs.strings.isEmpty { return try addSet(cs.chars) }
        // Alternation: strings longest first, then the characters, then "".
        var strs = cs.strings
        strs.sort { $0.count > $1.count }
        var alts: [Int32] = []
        var hasEmpty = false
        for s in strs {
            if s.isEmpty { hasEmpty = true; continue }
            var terms: [Int32] = []
            for c in s { terms.append(try node(JSReNode(kind: .char, a: Int32(c)))) }
            alts.append(try seq(terms))
        }
        if !cs.chars.r.isEmpty { alts.append(try addSet(cs.chars)) }
        if hasEmpty { alts.append(try node(JSReNode(kind: .empty))) }
        if alts.count == 1 { return alts[0] }
        let start = Int32(ast.lists.count)
        ast.lists.append(contentsOf: alts)
        return try node(JSReNode(kind: .alt, child: start, count: Int32(alts.count)))
    }

    /// ClassContents up to and including the closing ']'.
    mutating func vContents(depth: Int) throws(JSRegExpError) -> JSReClassSet {
        if depth > JSReParser.maxNesting { throw err("regular expression too deeply nested") }
        guard i < n else { throw err("unterminated character class") }
        if p[i] == 0x5D { i += 1; return JSReClassSet() }
        var (acc, wasRange) = try vOperand(depth: depth, allowRange: true)
        if at(i) == 0x26 && at(i + 1) == 0x26 || at(i) == 0x2D && at(i + 1) == 0x2D {
            let opc = p[i]
            if wasRange { throw err("invalid set operation in character class") }
            while true {
                guard i < n else { throw err("unterminated character class") }
                if p[i] == 0x5D { i += 1; break }
                guard at(i) == opc && at(i + 1) == opc else { throw err("invalid set operation in character class") }
                i += 2
                if opc == 0x26 && at(i) == 0x26 { throw err("invalid set operation in character class") }
                let (rhs, _) = try vOperand(depth: depth, allowRange: false)
                if opc == 0x26 {
                    var out = JSReClassSet()
                    out.chars = acc.chars.subtracting(acc.chars.subtracting(rhs.chars))
                    for s in acc.strings where rhs.strings.contains(where: { $0 == s }) { out.strings.append(s) }
                    acc = out
                } else {
                    acc.chars = acc.chars.subtracting(rhs.chars)
                    acc.strings = acc.strings.filter { s in !rhs.strings.contains(where: { $0 == s }) }
                }
            }
            return acc
        }
        while true {
            guard i < n else { throw err("unterminated character class") }
            if p[i] == 0x5D { i += 1; break }
            if at(i) == 0x26 && at(i + 1) == 0x26 || at(i) == 0x2D && at(i + 1) == 0x2D {
                throw err("invalid set operation in character class")
            }
            let (rhs, _) = try vOperand(depth: depth, allowRange: true)
            acc.chars.add(rhs.chars)
            for s in rhs.strings { acc.addString(s) }
        }
        acc.chars.normalize()
        return acc
    }

    /// One ClassSetOperand (or ClassSetRange when allowed). Returns the
    /// folded set and whether it was a range.
    mutating func vOperand(depth: Int, allowRange: Bool) throws(JSRegExpError) -> (JSReClassSet, Bool) {
        guard i < n else { throw err("unterminated character class") }
        var out = JSReClassSet()
        if p[i] == 0x5B {
            i += 1
            var negate = false
            if i < n && p[i] == 0x5E { negate = true; i += 1 }
            out = try vContents(depth: depth + 1)
            if negate {
                if !out.strings.isEmpty { throw err("negated character class may contain strings") }
                out.chars = vComplement(out.chars)
            }
            return (out, false)
        }
        if p[i] == 0x5C && i + 1 < n {
            let e = p[i + 1]
            switch e {
            case 0x64, 0x44, 0x73, 0x53, 0x77, 0x57:
                i += 2
                out.chars = vFold(classEscapeSet(e))
                return (out, false)
            case 0x70, 0x50:
                i += 1
                out.chars = vFold(try propertyEscape())
                return (out, false)
            case 0x71: // \q{...}
                guard at(i + 2) == 0x7B else { throw err("invalid escape") }
                i += 3
                var cur: [UInt32] = []
                while true {
                    guard i < n else { throw err("unterminated class string disjunction") }
                    if p[i] == 0x7D { i += 1; out.addString(cur); break }
                    if p[i] == 0x7C { i += 1; out.addString(cur); cur = []; continue }
                    cur.append(try vSetCharacter())
                }
                if !foldRuns.isEmpty {
                    out.strings = out.strings.map { $0.map { jsReCanonicalize($0, foldRuns, unicode: true) } }
                }
                out.chars.normalize()
                out.chars = vFold(out.chars)
                return (out, false)
            default: break
            }
        }
        let a = try vSetCharacter()
        if allowRange && at(i) == 0x2D && at(i + 1) != 0x2D {
            i += 1
            guard i < n else { throw err("unterminated character class") }
            if p[i] == 0x5B || (p[i] == 0x5C && (jsReIsLetter(at(i + 1)) && "dDsSwWpPq".utf16.contains(at(i + 1)))) {
                throw err("invalid character class range")
            }
            let b = try vSetCharacter()
            if a > b { throw err("range out of order in character class") }
            out.chars.add(a, b)
            out.chars = vFold(out.chars)
            return (out, true)
        }
        out.chars.add(a, a)
        out.chars = vFold(out.chars)
        return (out, false)
    }

    /// ClassSetCharacter.
    mutating func vSetCharacter() throws(JSRegExpError) -> UInt32 {
        guard i < n else { throw err("unterminated character class") }
        let c = p[i]
        if c == 0x5C {
            i += 1
            guard i < n else { throw err("\\ at end of pattern") }
            let e = p[i]
            switch e {
            case 0x62: i += 1; return 8
            case 0x26, 0x2D, 0x21, 0x23, 0x25, 0x2C, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x40, 0x60, 0x7E:
                i += 1; return UInt32(e)
            case 0x30:
                if i + 1 < n && jsReIsDigit(p[i + 1]) { throw err("invalid class escape") }
                i += 1; return 0
            case 0x31...0x39: throw err("invalid class escape")
            default: return try characterEscape(inClass: true)
            }
        }
        switch c {
        case 0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x2D, 0x7C:
            throw err("invalid character in character class")
        default: break
        }
        if isDoublePunct(i) { throw err("invalid set operation in character class") }
        let (cp, len) = peekChar()
        i += len
        return cp
    }
}
