// RegExp pattern parser (ECMA-262 2022, 22.2.1, plus Annex B.1.2 outside
// unicode mode) with every early error. Iterative: open groups live on an
// explicit stack (at most JSReParser.maxNesting deep), so hostile nesting
// can't overflow the Swift stack. Produces a JSReAST for the compiler.
//
// Mode summary (see the spec for the grammar):
//   unicode (u/v): pattern read as code points; strict escapes (identity
//     escapes only for syntax characters and '/', '-' in classes); \p{..};
//     lone '{' '}' ']' are errors; lookaheads can't be quantified;
//     \1 beyond the group count is an error; class ranges with \d etc. are
//     errors; \u{...} escapes.
//   non-unicode (Annex B): code units; \c without a letter is a literal
//     backslash; legacy octal escapes; \8 \9 identity; a decimal escape
//     beyond the group count falls back to octal/identity; '{' that isn't
//     a quantifier is literal; quantified lookaheads; [\d-z] is a union.
//     \k is an identity escape unless the pattern has a named group (the
//     [+NamedCaptureGroups] reparse rule), in which case it must name one.

enum JSReKind: UInt8 {
    case empty, char, dot, set, seq, alt, group, look, quant, backref, bol, eol, wordB, notWordB
}

/// One AST node. Fields per kind:
///   char      a = code point (unicode mode) or code unit
///   set       a = index into ast.sets, flag 1 = [^...] (inverted after
///             case folding)
///   seq/alt   child = first index in ast.lists, count = number of items
///   group     a = capture number (1-based), child
///   look      flag = 0 (?=  1 (?!  2 (?<=  3 (?<!, child
///   quant     a = min, b = max (-1: unbounded), flag 1 = greedy, child;
///             c, d: groups c+1...d are inside (reset every iteration)
///   backref   a = capture number
struct JSReNode {
    var kind: JSReKind
    var flag: UInt8 = 0
    var a: Int32 = 0
    var b: Int32 = 0
    var c: Int32 = 0
    var d: Int32 = 0
    var child: Int32 = -1
    var count: Int32 = 0
}

struct JSReAST {
    var nodes: [JSReNode] = []
    var lists: [Int32] = []
    var sets: [JSReCharSet] = []
    var root: Int32 = -1
    var captureCount = 0
    /// Name of group i+1, [] if unnamed.
    var groupNames: [[UInt16]] = []
}

func jsReParse(_ p: [UInt16], _ f: JSRegExpFlags) throws(JSRegExpError) -> JSReAST {
    var ps = JSReParser(p, f)
    try ps.parse()
    return ps.ast
}

private struct JSReFrame {
    var kind: UInt8          // 0 root, 1 capturing group, 2 (?: ), 3 lookaround
    var a: Int32             // capture number / lookaround kind
    var capStart: Int32      // captures before this group
    var alts: [Int32] = []
    var terms: [Int32] = []
}

@inline(__always) func jsReIsLead(_ u: UInt32) -> Bool { u >= 0xD800 && u <= 0xDBFF }
@inline(__always) func jsReIsTrail(_ u: UInt32) -> Bool { u >= 0xDC00 && u <= 0xDFFF }
@inline(__always) func jsReIsDigit(_ u: UInt16) -> Bool { u >= 0x30 && u <= 0x39 }
@inline(__always) func jsReIsLetter(_ u: UInt16) -> Bool { (u | 0x20) >= 0x61 && (u | 0x20) <= 0x7A }
@inline(__always) func jsReHex(_ u: UInt16) -> Int {
    if u >= 0x30 && u <= 0x39 { return Int(u) - 0x30 }
    if u >= 0x61 && u <= 0x66 { return Int(u) - 0x61 + 10 }
    if u >= 0x41 && u <= 0x46 { return Int(u) - 0x41 + 10 }
    return -1
}

struct JSReParser {
    /// Open groups at once; deeper is a SyntaxError (the compiler recurses
    /// about twice per level).
    static let maxNesting = 256
    /// AST nodes per pattern.
    static let maxNodes = 1 << 20

    let p: [UInt16]
    let n: Int
    var i = 0
    let u: Bool
    let ignoreCase: Bool
    let sets: Bool              // v flag: ClassSetExpression syntax
    var foldRuns: [UInt64] = [] // v + i: simple case folding for set operations
    var named = false
    var totalCaps = 0
    var ast = JSReAST()
    var namedRefs: [(node: Int32, name: [UInt16])] = []

    init(_ p: [UInt16], _ f: JSRegExpFlags) {
        self.p = p
        n = p.count
        u = f.unicodeMode
        ignoreCase = f.ignoreCase
        sets = f.unicodeSets
        if sets && ignoreCase { foldRuns = jsReDecodeCaseTable(unicode: true) }
    }

    func err(_ m: String) -> JSRegExpError { JSRegExpError(m) }

    mutating func node(_ nd: JSReNode) throws(JSRegExpError) -> Int32 {
        if ast.nodes.count >= JSReParser.maxNodes { throw err("regular expression too large") }
        ast.nodes.append(nd)
        return Int32(ast.nodes.count - 1)
    }

    mutating func addSet(_ s: JSReCharSet, inverted: Bool = false) throws(JSRegExpError) -> Int32 {
        ast.sets.append(s)
        return try node(JSReNode(kind: .set, flag: inverted ? 1 : 0, a: Int32(ast.sets.count - 1)))
    }

    /// Count capturing groups and see whether any is named (the
    /// [N] parameter and the DecimalEscape early error need them up front).
    func prescan() -> (Int, Bool) {
        var caps = 0, names = false
        var k = 0, inClass = false
        while k < n {
            let c = p[k]
            if c == 0x5C { k += 2; continue }
            if inClass {
                if c == 0x5D { inClass = false }
            } else if c == 0x5B {
                inClass = true
            } else if c == 0x28 {
                if k + 1 < n && p[k + 1] == 0x3F {
                    if k + 3 < n && p[k + 2] == 0x3C && p[k + 3] != 0x3D && p[k + 3] != 0x21 {
                        caps += 1; names = true
                    }
                } else {
                    caps += 1
                }
            }
            k += 1
        }
        return (caps, names)
    }

    /// The next pattern character (a code point in unicode mode) and its length.
    @inline(__always) func peekChar() -> (UInt32, Int) {
        let c = UInt32(p[i])
        if u && jsReIsLead(c) && i + 1 < n && jsReIsTrail(UInt32(p[i + 1])) {
            return (0x10000 + ((c - 0xD800) << 10) + (UInt32(p[i + 1]) - 0xDC00), 2)
        }
        return (c, 1)
    }

    mutating func parse() throws(JSRegExpError) {
        let (caps, names) = prescan()
        totalCaps = caps
        named = u || names
        var stack: [JSReFrame] = [JSReFrame(kind: 0, a: 0, capStart: 0)]
        while true {
            if i >= n {
                if stack.count > 1 { throw err("unterminated group") }
                ast.root = try finish(&stack[0])
                break
            }
            let top = stack.count - 1
            let c = p[i]
            switch c {
            case 0x7C: // |
                i += 1
                let alt = try seq(stack[top].terms)
                stack[top].alts.append(alt)
                stack[top].terms.removeAll()
            case 0x29: // )
                if stack.count == 1 { throw err("unmatched ')'") }
                i += 1
                var fr = stack.removeLast()
                let body = try finish(&fr)
                var nd = body
                var quantifiable = true
                if fr.kind == 1 {
                    nd = try node(JSReNode(kind: .group, a: fr.a, child: body))
                } else if fr.kind == 3 {
                    nd = try node(JSReNode(kind: .look, flag: UInt8(fr.a), child: body))
                    quantifiable = !u && fr.a < 2
                }
                try term(&stack[stack.count - 1], nd, capStart: fr.capStart, quantifiable: quantifiable)
            case 0x28: // (
                if stack.count > JSReParser.maxNesting { throw err("regular expression too deeply nested") }
                stack.append(try openGroup())
            case 0x5E: // ^
                i += 1
                try term(&stack[top], try node(JSReNode(kind: .bol)), capStart: 0, quantifiable: false)
            case 0x24: // $
                i += 1
                try term(&stack[top], try node(JSReNode(kind: .eol)), capStart: 0, quantifiable: false)
            case 0x5C: // \
                let cs = Int32(ast.captureCount)
                let (nd, q) = try atomEscape()
                try term(&stack[top], nd, capStart: cs, quantifiable: q)
            case 0x5B: // [
                let nd = try characterClass()
                try term(&stack[top], nd, capStart: Int32(ast.captureCount), quantifiable: true)
            case 0x2E: // .
                i += 1
                try term(&stack[top], try node(JSReNode(kind: .dot)), capStart: Int32(ast.captureCount), quantifiable: true)
            case 0x2A, 0x2B, 0x3F: // * + ?
                throw err("nothing to repeat")
            case 0x7B: // {
                if scanBraced(i) != nil { throw err("nothing to repeat") }
                if u { throw err("lone quantifier brackets") }
                i += 1
                try term(&stack[top], try node(JSReNode(kind: .char, a: 0x7B)), capStart: Int32(ast.captureCount), quantifiable: true)
            case 0x7D, 0x5D: // } ]
                if u { throw err("lone quantifier brackets") }
                i += 1
                try term(&stack[top], try node(JSReNode(kind: .char, a: Int32(c))), capStart: Int32(ast.captureCount), quantifiable: true)
            default:
                let (cp, len) = peekChar()
                i += len
                try term(&stack[top], try node(JSReNode(kind: .char, a: Int32(cp))), capStart: Int32(ast.captureCount), quantifiable: true)
            }
        }
        for r in namedRefs {
            var found = -1
            for (k, name) in ast.groupNames.enumerated() where name == r.name { found = k + 1; break }
            if found < 0 { throw err("invalid named capture referenced") }
            ast.nodes[Int(r.node)].a = Int32(found)
        }
    }

    mutating func seq(_ terms: [Int32]) throws(JSRegExpError) -> Int32 {
        if terms.isEmpty { return try node(JSReNode(kind: .empty)) }
        if terms.count == 1 { return terms[0] }
        let start = Int32(ast.lists.count)
        ast.lists.append(contentsOf: terms)
        return try node(JSReNode(kind: .seq, child: start, count: Int32(terms.count)))
    }

    mutating private func finish(_ fr: inout JSReFrame) throws(JSRegExpError) -> Int32 {
        fr.alts.append(try seq(fr.terms))
        fr.terms.removeAll()
        if fr.alts.count == 1 { return fr.alts[0] }
        let start = Int32(ast.lists.count)
        ast.lists.append(contentsOf: fr.alts)
        return try node(JSReNode(kind: .alt, child: start, count: Int32(fr.alts.count)))
    }

    /// Append a term, wrapping it in a quantifier if one follows.
    mutating private func term(_ fr: inout JSReFrame, _ nd: Int32, capStart: Int32, quantifiable: Bool) throws(JSRegExpError) {
        guard let q = try quantifier() else { fr.terms.append(nd); return }
        if !quantifiable { throw err("nothing to repeat") }
        let qn = try node(JSReNode(kind: .quant, flag: q.greedy ? 1 : 0, a: q.min, b: q.max,
                                   c: capStart, d: Int32(ast.captureCount), child: nd))
        fr.terms.append(qn)
    }

    /// `{n}`, `{n,}` or `{n,m}` at k: (min, max or -1, length), saturated.
    func scanBraced(_ k0: Int) -> (Int, Int, Int)? {
        var k = k0
        guard k < n, p[k] == 0x7B else { return nil }
        k += 1
        func digits(_ k: inout Int) -> Int? {
            var v = 0
            let s = k
            while k < n && jsReIsDigit(p[k]) {
                v = v * 10 + Int(p[k] - 0x30)
                if v > 1 << 53 { v = 1 << 53 }
                k += 1
            }
            return k > s ? v : nil
        }
        guard let lo = digits(&k), k < n else { return nil }
        if p[k] == 0x7D { return (lo, lo, k + 1 - k0) }
        guard p[k] == 0x2C else { return nil }
        k += 1
        if k < n && p[k] == 0x7D { return (lo, -1, k + 1 - k0) }
        guard let hi = digits(&k), k < n, p[k] == 0x7D else { return nil }
        return (lo, hi, k + 1 - k0)
    }

    /// {n,m} at k with both numbers too big to hold: compare the digits.
    func bracedOutOfOrder(_ k0: Int) -> Bool {
        var k = k0 + 1
        func run(_ k: inout Int) -> ArraySlice<UInt16> {
            while k < n && p[k] == 0x30 { k += 1 }
            let s = k
            while k < n && jsReIsDigit(p[k]) { k += 1 }
            return p[s..<k]
        }
        let a = run(&k)
        k += 1
        let b = run(&k)
        if a.count != b.count { return a.count > b.count }
        for (x, y) in zip(a, b) where x != y { return x > y }
        return false
    }

    mutating func quantifier() throws(JSRegExpError) -> (min: Int32, max: Int32, greedy: Bool)? {
        guard i < n else { return nil }
        var lo = 0, hi = -1
        switch p[i] {
        case 0x2A: i += 1
        case 0x2B: lo = 1; i += 1
        case 0x3F: hi = 1; i += 1
        case 0x7B:
            guard let (a, b, len) = scanBraced(i) else { return nil }
            if b >= 0 && a > b { throw err("numbers out of order in {} quantifier") }
            if b >= 0 && a == b && a == 1 << 53 && bracedOutOfOrder(i) {
                throw err("numbers out of order in {} quantifier")
            }
            lo = a; hi = b; i += len
        default: return nil
        }
        var greedy = true
        if i < n && p[i] == 0x3F { greedy = false; i += 1 }
        let maxI = Int(Int32.max)
        return (Int32(min(lo, maxI)), hi < 0 || hi >= maxI ? -1 : Int32(hi), greedy)
    }

    mutating private func openGroup() throws(JSRegExpError) -> JSReFrame {
        i += 1
        let caps = Int32(ast.captureCount)
        if i < n && p[i] == 0x3F {
            guard i + 1 < n else { throw err("invalid group") }
            switch p[i + 1] {
            case 0x3A: i += 2; return JSReFrame(kind: 2, a: 0, capStart: caps)
            case 0x3D: i += 2; return JSReFrame(kind: 3, a: 0, capStart: caps)
            case 0x21: i += 2; return JSReFrame(kind: 3, a: 1, capStart: caps)
            case 0x3C:
                if i + 2 < n && p[i + 2] == 0x3D { i += 3; return JSReFrame(kind: 3, a: 2, capStart: caps) }
                if i + 2 < n && p[i + 2] == 0x21 { i += 3; return JSReFrame(kind: 3, a: 3, capStart: caps) }
                i += 2
                let name = try groupName()
                for other in ast.groupNames where other == name { throw err("duplicate capture group name") }
                ast.captureCount += 1
                ast.groupNames.append(name)
                return JSReFrame(kind: 1, a: Int32(ast.captureCount), capStart: caps)
            default:
                throw err("invalid group")
            }
        }
        ast.captureCount += 1
        ast.groupNames.append([])
        return JSReFrame(kind: 1, a: Int32(ast.captureCount), capStart: caps)
    }

    /// RegExpIdentifierName then '>' (i is just after '<').
    mutating func groupName() throws(JSRegExpError) -> [UInt16] {
        var name: [UInt16] = []
        while true {
            guard i < n else { throw err("invalid capture group name") }
            var cp = UInt32(p[i])
            if cp == 0x3E {
                if name.isEmpty { throw err("invalid capture group name") }
                i += 1
                return name
            }
            if cp == 0x5C {
                i += 1
                guard i < n, p[i] == 0x75, let v = unicodeEscape(unicode: true) else {
                    throw err("invalid capture group name")
                }
                cp = v
            } else {
                i += 1
                if jsReIsLead(cp) && i < n && jsReIsTrail(UInt32(p[i])) {
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (UInt32(p[i]) - 0xDC00)
                    i += 1
                }
            }
            let ok = name.isEmpty ? jsIsIDStart(cp) : jsIsIDContinue(cp)
            if !ok { throw err("invalid capture group name") }
            if cp >= 0x10000 {
                name.append(UInt16(0xD800 + ((cp - 0x10000) >> 10)))
                name.append(UInt16(0xDC00 + ((cp - 0x10000) & 0x3FF)))
            } else {
                name.append(UInt16(cp))
            }
        }
    }

    /// RegExpUnicodeEscapeSequence with i at the 'u'. nil (i unchanged) if
    /// it isn't one. `unicode` allows \u{...} and joins \uLEAD\uTRAIL.
    mutating func unicodeEscape(unicode: Bool) -> UInt32? {
        let save = i
        i += 1
        if unicode && i < n && p[i] == 0x7B {
            i += 1
            var v: UInt32 = 0
            let s = i
            while i < n && jsReHex(p[i]) >= 0 {
                v = v * 16 + UInt32(jsReHex(p[i]))
                if v > 0x10FFFF { i = save; return nil }
                i += 1
            }
            if i == s || i >= n || p[i] != 0x7D { i = save; return nil }
            i += 1
            return v
        }
        guard let v = hex4(i) else { i = save; return nil }
        i += 4
        if unicode && jsReIsLead(v) && i + 5 < n && p[i] == 0x5C && p[i + 1] == 0x75, let t = hex4(i + 2), jsReIsTrail(t) {
            i += 6
            return 0x10000 + ((v - 0xD800) << 10) + (t - 0xDC00)
        }
        return v
    }

    func hex4(_ k: Int) -> UInt32? {
        guard k + 4 <= n else { return nil }
        var v: UInt32 = 0
        for j in k..<(k + 4) {
            let h = jsReHex(p[j])
            if h < 0 { return nil }
            v = v * 16 + UInt32(h)
        }
        return v
    }

    /// LegacyOctalEscapeSequence starting at i (p[i] is an octal digit).
    mutating func legacyOctal() -> UInt32 {
        let first = UInt32(p[i] - 0x30)
        var v = first
        i += 1
        let maxDigits = first <= 3 ? 2 : 1
        var k = 0
        while k < maxDigits && i < n && p[i] >= 0x30 && p[i] <= 0x37 {
            v = v * 8 + UInt32(p[i] - 0x30)
            i += 1
            k += 1
        }
        return v
    }

    /// `\` AtomEscape outside a class (i at the backslash). Returns the node
    /// and whether it may be quantified.
    mutating func atomEscape() throws(JSRegExpError) -> (Int32, Bool) {
        i += 1
        guard i < n else { throw err("\\ at end of pattern") }
        let c = p[i]
        switch c {
        case 0x62: i += 1; return (try node(JSReNode(kind: .wordB)), false)
        case 0x42: i += 1; return (try node(JSReNode(kind: .notWordB)), false)
        case 0x31...0x39:
            let s = i
            var v = 0
            while i < n && jsReIsDigit(p[i]) {
                v = v * 10 + Int(p[i] - 0x30)
                if v > 1 << 30 { v = 1 << 30 }
                i += 1
            }
            if v <= totalCaps { return (try node(JSReNode(kind: .backref, a: Int32(v))), true) }
            if u { throw err("invalid escape") }
            i = s
            if c >= 0x38 { i += 1; return (try node(JSReNode(kind: .char, a: Int32(c))), true) }
            return (try node(JSReNode(kind: .char, a: Int32(legacyOctal()))), true)
        case 0x30:
            if i + 1 < n && jsReIsDigit(p[i + 1]) {
                if u { throw err("invalid decimal escape") }
                return (try node(JSReNode(kind: .char, a: Int32(legacyOctal()))), true)
            }
            i += 1
            return (try node(JSReNode(kind: .char, a: 0)), true)
        case 0x64, 0x44, 0x73, 0x53, 0x77, 0x57:
            i += 1
            return (try addSet(classEscapeSet(c)), true)
        case 0x70 where u, 0x50 where u:
            return (try addSet(try propertyEscape()), true)
        case 0x6B where named:
            i += 1
            guard i < n, p[i] == 0x3C else { throw err("invalid named reference") }
            i += 1
            let name: [UInt16]
            do { name = try groupName() } catch { throw err("invalid named reference") }
            let nd = try node(JSReNode(kind: .backref, a: 0))
            namedRefs.append((node: nd, name: name))
            return (nd, true)
        default:
            let cp = try characterEscape(inClass: false)
            return (try node(JSReNode(kind: .char, a: Int32(cp))), true)
        }
    }

    /// CharacterEscape (i at the character after the backslash).
    mutating func characterEscape(inClass: Bool) throws(JSRegExpError) -> UInt32 {
        let c = p[i]
        switch c {
        case 0x66: i += 1; return 12
        case 0x6E: i += 1; return 10
        case 0x72: i += 1; return 13
        case 0x74: i += 1; return 9
        case 0x76: i += 1; return 11
        case 0x63: // c
            if i + 1 < n && jsReIsLetter(p[i + 1]) { i += 2; return UInt32(p[i - 1] % 32) }
            if !u && inClass && i + 1 < n && (jsReIsDigit(p[i + 1]) || p[i + 1] == 0x5F) {
                i += 2; return UInt32(p[i - 1] % 32)
            }
            if u { throw err("invalid unicode escape") }
            return 0x5C // Annex B: a literal backslash; the 'c' is read next
        case 0x78: // x
            if i + 2 < n {
                let h1 = jsReHex(p[i + 1]), h2 = jsReHex(p[i + 2])
                if h1 >= 0 && h2 >= 0 { i += 3; return UInt32(h1 * 16 + h2) }
            }
            if u { throw err("invalid escape") }
            i += 1
            return 0x78
        case 0x75: // u
            if let v = unicodeEscape(unicode: u) { return v }
            if u { throw err("invalid unicode escape") }
            i += 1
            return 0x75
        default:
            if u {
                switch c {
                case 0x5E, 0x24, 0x5C, 0x2E, 0x2A, 0x2B, 0x3F, 0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D, 0x7C, 0x2F:
                    i += 1
                    return UInt32(c)
                case 0x2D where inClass:
                    i += 1
                    return 0x2D
                default:
                    throw err("invalid escape")
                }
            }
            if c == 0x6B && named { throw err("invalid escape") }
            i += 1
            return UInt32(c)
        }
    }

    func classEscapeSet(_ c: UInt16) -> JSReCharSet {
        var s = JSReCharSet()
        switch c | 0x20 {
        case 0x64: s.add(0x30, 0x39)
        case 0x73: jsReAddSpace(&s)
        default:
            s.add(0x30, 0x39); s.add(0x41, 0x5A); s.add(0x5F, 0x5F); s.add(0x61, 0x7A)
            if u && ignoreCase { s.add(0x17F, 0x17F); s.add(0x212A, 0x212A) }
        }
        s.normalize()
        if c < 0x60 { s = s.inverted(max: u ? 0x10FFFF : 0xFFFF) }
        return s
    }

    /// `\p{...}` / `\P{...}` with i at the p.
    mutating func propertyEscape() throws(JSRegExpError) -> JSReCharSet {
        let negate = p[i] == 0x50
        i += 1
        guard i < n, p[i] == 0x7B else { throw err("invalid property name") }
        i += 1
        var name: [UInt16] = [], value: [UInt16] = []
        var sawEq = false
        while true {
            guard i < n else { throw err("invalid property name") }
            let c = p[i]
            i += 1
            if c == 0x7D { break }
            if c == 0x3D && !sawEq { sawEq = true; continue }
            let ok = jsReIsLetter(c) || c == 0x5F || (sawEq && jsReIsDigit(c))
            if !ok { throw err("invalid property name") }
            if sawEq { value.append(c) } else { name.append(c) }
        }
        if name.isEmpty || (sawEq && value.isEmpty) { throw err("invalid property name") }
        guard var s = sawEq ? jsRePropertySet(name: name, value: value) : jsRePropertySet(lone: name) else {
            throw err("invalid property name")
        }
        if negate { s = s.inverted(max: 0x10FFFF) }
        return s
    }

    /// One ClassAtom: a character, or a set for a class escape.
    mutating func classAtom() throws(JSRegExpError) -> (UInt32, JSReCharSet?) {
        let c = p[i]
        if c != 0x5C {
            let (cp, len) = peekChar()
            i += len
            return (cp, nil)
        }
        i += 1
        guard i < n else { throw err("\\ at end of pattern") }
        let e = p[i]
        switch e {
        case 0x62: i += 1; return (8, nil)
        case 0x2D where u: i += 1; return (0x2D, nil)
        case 0x64, 0x44, 0x73, 0x53, 0x77, 0x57:
            i += 1
            return (0, classEscapeSet(e))
        case 0x70 where u, 0x50 where u:
            return (0, try propertyEscape())
        case 0x30:
            if i + 1 < n && jsReIsDigit(p[i + 1]) {
                if u { throw err("invalid class escape") }
                return (legacyOctal(), nil)
            }
            i += 1
            return (0, nil)
        case 0x31...0x39:
            if u { throw err("invalid class escape") }
            if e >= 0x38 { i += 1; return (UInt32(e), nil) }
            return (legacyOctal(), nil)
        default:
            return (try characterEscape(inClass: true), nil)
        }
    }

    mutating func characterClass() throws(JSRegExpError) -> Int32 {
        if sets { return try vCharacterClass() }
        i += 1
        var negate = false
        if i < n && p[i] == 0x5E { negate = true; i += 1 }
        var set = JSReCharSet()
        while true {
            guard i < n else { throw err("unterminated character class") }
            if p[i] == 0x5D { i += 1; break }
            let (a, aset) = try classAtom()
            if i + 1 < n && p[i] == 0x2D && p[i + 1] != 0x5D {
                i += 1
                let (b, bset) = try classAtom()
                if aset != nil || bset != nil {
                    if u { throw err("invalid character class range") }
                    if let s = aset { set.add(s) } else { set.add(a, a) }
                    set.add(0x2D, 0x2D)
                    if let s = bset { set.add(s) } else { set.add(b, b) }
                } else {
                    if a > b { throw err("range out of order in character class") }
                    set.add(a, b)
                }
            } else if let s = aset {
                set.add(s)
            } else {
                set.add(a, a)
            }
        }
        set.normalize()
        return try addSet(set, inverted: negate)
    }
}

/// WhiteSpace and LineTerminator (\s).
func jsReAddSpace(_ s: inout JSReCharSet) {
    s.add(0x09, 0x0D); s.add(0x20, 0x20); s.add(0xA0, 0xA0); s.add(0x1680, 0x1680)
    s.add(0x2000, 0x200A); s.add(0x2028, 0x2029); s.add(0x202F, 0x202F); s.add(0x205F, 0x205F)
    s.add(0x3000, 0x3000); s.add(0xFEFF, 0xFEFF)
}
