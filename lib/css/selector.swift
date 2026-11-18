// Selectors: parsing, specificity and matching. Matching is generic over
// `CSSElement` (no existentials in Embedded Swift); the DOM conforms to it.

protocol CSSElement {
    /// Lowercase local name ("div"). Matched against type selectors.
    var cssTagName: String { get }
    /// The id attribute ("" when absent).
    var cssID: String { get }
    /// The class attribute split on whitespace.
    var cssClasses: [String] { get }
    /// An attribute value by lowercase name.
    func cssAttribute(_ name: String) -> String?
    /// The parent element; nil for the root (and for a root whose parent is the document).
    var cssParent: Self? { get }
    var cssPreviousElementSibling: Self? { get }
    var cssNextElementSibling: Self? { get }
    /// The document element.
    var cssIsRoot: Bool { get }
    /// The pointer is over this element (or a descendant).
    var cssIsHovered: Bool { get }
    /// An `a`/`area` element with an href (`:link`, `:any-link`).
    var cssIsLink: Bool { get }
    var cssIsChecked: Bool { get }
    var cssIsDisabled: Bool { get }
    /// No element or non-empty text children (`:empty`).
    var cssIsEmpty: Bool { get }
    /// 1-based index among the parent's element children.
    var cssSiblingIndex: Int { get }
    /// Number of element children of the parent (including this one).
    var cssSiblingCount: Int { get }
}

extension CSSElement {
    var cssIsRoot: Bool { cssParent == nil }
    var cssIsHovered: Bool { false }
    var cssIsLink: Bool { false }
    var cssIsChecked: Bool { false }
    var cssIsDisabled: Bool { false }
    var cssIsEmpty: Bool { false }
    var cssSiblingIndex: Int {
        var n = 1
        var cur = cssPreviousElementSibling
        while let p = cur { n += 1; cur = p.cssPreviousElementSibling }
        return n
    }
    var cssSiblingCount: Int {
        var n = cssSiblingIndex
        var cur = cssNextElementSibling
        while let p = cur { n += 1; cur = p.cssNextElementSibling }
        return n
    }
}

enum CSSAttrOp: UInt8 { case exists, equals, includes, dashMatch, prefix, suffix, substring }

struct CSSAttrSelector {
    var name: String
    var op: CSSAttrOp
    var value: String
    var caseInsensitive: Bool
}

enum CSSPseudoClass: UInt8 {
    case firstChild, lastChild, onlyChild, firstOfType, lastOfType, onlyOfType
    case link, visited, hover, root, empty, checked, disabled, enabled
    case never, always
}

enum CSSNthKind: UInt8 { case child, lastChild, ofType, lastOfType }

struct CSSNthSelector {
    var kind: CSSNthKind
    var a: Int
    var b: Int
}

enum CSSPseudoElement: UInt8 {
    case none, before, after
    /// Valid syntax that this engine never generates (::selection, ::first-line, ...).
    case other
}

enum CSSCombinator: UInt8 { case descendant, child, adjacent, general }

struct CSSCompound {
    var tag = ""                      // "" matches any
    var ids: [String] = []
    var classes: [String] = []
    var attrs: [CSSAttrSelector] = []
    var pseudos: [CSSPseudoClass] = []
    var nths: [CSSNthSelector] = []
    var negations: [CSSComplexSelector] = []     // :not(a, b) = none of these match
    var anyOf: [[CSSComplexSelector]] = []       // :is(...)/:where(...) lists
}

struct CSSComplexSelector {
    var compounds: [CSSCompound] = []
    /// combinators[k] joins compounds[k] and compounds[k + 1].
    var combinators: [CSSCombinator] = []
    var pseudoElement = CSSPseudoElement.none
    /// ids << 20 | classes/attributes/pseudo-classes << 10 | types/pseudo-elements.
    var specificity: UInt32 = 0
}

let cssMaxSelectorCompounds = 32
let cssMaxSelectorDepth = 6

// MARK: - Token range helpers

/// Index just past the construct starting at `i` (a block, function or plain
/// token), and whether it was closed before the end. Iterative.
func cssMatchEnd(_ t: [CSSToken], _ i: Int, _ end: Int) -> (Int, Bool) {
    guard i < end else { return (end, true) }
    var stack: [UInt8] = []
    var k = i
    while k < end {
        switch t[k] {
        case .function, .openParen: stack.append(0x29)
        case .openBracket: stack.append(0x5d)
        case .openBrace: stack.append(0x7d)
        case .closeParen: if stack.last == 0x29 { stack.removeLast() }
        case .closeBracket: if stack.last == 0x5d { stack.removeLast() }
        case .closeBrace: if stack.last == 0x7d { stack.removeLast() }
        default: break
        }
        k += 1
        if stack.isEmpty { return (k, true) }
    }
    return (end, false)
}

// MARK: - Parsing

struct CSSSelectorParser {
    let t: [CSSToken]
    var i = 0
    let end: Int

    init(_ tokens: [CSSToken]) { t = tokens; end = tokens.count }

    mutating func skipWS() {
        while i < end, case .whitespace = t[i] { i += 1 }
    }

    /// A comma-separated selector list; nil if any member is invalid.
    mutating func parseList(_ depth: Int) -> [CSSComplexSelector]? {
        guard depth <= cssMaxSelectorDepth else { return nil }
        var out: [CSSComplexSelector] = []
        while true {
            guard let s = parseComplex(depth) else { return nil }
            out.append(s)
            skipWS()
            if i >= end { break }
            if case .comma = t[i] { i += 1; continue }
            return nil
        }
        return out
    }

    mutating func parseComplex(_ depth: Int) -> CSSComplexSelector? {
        var sel = CSSComplexSelector()
        skipWS()
        var spec: UInt32 = 0
        while true {
            guard let (c, s) = parseCompound(depth) else { return nil }
            sel.compounds.append(c)
            if sel.compounds.count > cssMaxSelectorCompounds { return nil }
            spec = cssAddSpecificity(spec, s)
            // A pseudo-element must be last; parseCompound records it in lastPseudo.
            if lastPseudo != .none {
                sel.pseudoElement = lastPseudo
                lastPseudo = .none
                spec = cssAddSpecificity(spec, 1)
                skipWS()
                if i < end { if case .comma = t[i] { break } else { return nil } }
                break
            }
            var sawWS = false
            while i < end, case .whitespace = t[i] { i += 1; sawWS = true }
            if i >= end { break }
            if case .comma = t[i] { break }
            if case .delim(let d) = t[i], d == 0x3e || d == 0x2b || d == 0x7e {
                i += 1
                skipWS()
                sel.combinators.append(d == 0x3e ? .child : (d == 0x2b ? .adjacent : .general))
                if i >= end { return nil }
                continue
            }
            if sawWS { sel.combinators.append(.descendant); continue }
            return nil
        }
        sel.specificity = spec
        return sel
    }

    var lastPseudo = CSSPseudoElement.none

    /// One compound selector and its specificity.
    mutating func parseCompound(_ depth: Int) -> (CSSCompound, UInt32)? {
        var c = CSSCompound()
        var spec: UInt32 = 0
        var any = false
        if i < end {
            if case .ident(let n) = t[i] { c.tag = cssLower(n); i += 1; any = true; spec = 1 }
            else if case .delim(0x2a) = t[i] { i += 1; any = true }
        }
        loop: while i < end {
            switch t[i] {
            case .hash(let name, let isID):
                guard isID else { return nil }
                c.ids.append(name); i += 1; any = true
                spec = cssAddSpecificity(spec, 1 << 20)
            case .delim(0x2e):
                guard i + 1 < end, case .ident(let n) = t[i + 1] else { return nil }
                c.classes.append(n); i += 2; any = true
                spec = cssAddSpecificity(spec, 1 << 10)
            case .openBracket:
                let (e, closed) = cssMatchEnd(t, i, end)
                guard closed, let a = cssParseAttrSelector(t, i + 1, e - 1) else { return nil }
                c.attrs.append(a); i = e; any = true
                spec = cssAddSpecificity(spec, 1 << 10)
            case .colon:
                i += 1
                var double = false
                if i < end, case .colon = t[i] { double = true; i += 1 }
                guard i < end else { return nil }
                if case .ident(let n) = t[i] {
                    i += 1
                    let l = cssLower(n)
                    if double || l == "before" || l == "after" || l == "first-line" || l == "first-letter" {
                        switch l {
                        case "before": lastPseudo = .before
                        case "after": lastPseudo = .after
                        default: lastPseudo = .other
                        }
                        any = true
                        break loop
                    }
                    c.pseudos.append(cssSimplePseudoClass(l))
                    any = true
                    spec = cssAddSpecificity(spec, 1 << 10)
                } else if case .function(let fname) = t[i], !double {
                    let (e, closed) = cssMatchEnd(t, i, end)
                    let argEnd = closed ? e - 1 : e
                    let args = Array(t[(i + 1)..<argEnd])
                    i = e
                    guard let s = parseFunctionalPseudo(cssLower(fname), args, &c, depth) else { return nil }
                    spec = cssAddSpecificity(spec, s)
                    any = true
                } else if double, case .function = t[i] {
                    // ::part(), ::slotted(), ...: valid, never matches.
                    let (e, _) = cssMatchEnd(t, i, end)
                    i = e
                    lastPseudo = .other
                    any = true
                    break loop
                } else { return nil }
            default:
                break loop
            }
        }
        return any ? (c, spec) : nil
    }

    mutating func parseFunctionalPseudo(_ name: String, _ args: [CSSToken], _ c: inout CSSCompound, _ depth: Int) -> UInt32? {
        switch name {
        case "not", "is", "where", "matches", "-webkit-any", "-moz-any", "any":
            var p = CSSSelectorParser(args)
            guard let list = p.parseList(depth + 1) else { return nil }
            var maxSpec: UInt32 = 0
            for s in list where s.pseudoElement == .none && s.specificity > maxSpec { maxSpec = s.specificity }
            for s in list where s.pseudoElement != .none { return nil }
            if name == "not" {
                c.negations.append(contentsOf: list)
                return maxSpec
            }
            c.anyOf.append(list)
            return name == "where" ? 0 : maxSpec
        case "nth-child", "nth-last-child", "nth-of-type", "nth-last-of-type":
            guard let (a, b) = cssParseNth(args) else { return nil }
            let kind: CSSNthKind = name == "nth-child" ? .child : (name == "nth-last-child" ? .lastChild
                : (name == "nth-of-type" ? .ofType : .lastOfType))
            c.nths.append(CSSNthSelector(kind: kind, a: a, b: b))
            return 1 << 10
        default:
            // :lang(), :dir(), :has() and friends: never match (:has is too costly to support).
            c.pseudos.append(.never)
            return 1 << 10
        }
    }
}

func cssAddSpecificity(_ a: UInt32, _ b: UInt32) -> UInt32 {
    let ia = min(1023, (a >> 20) + (b >> 20))
    let ib = min(1023, ((a >> 10) & 1023) + ((b >> 10) & 1023))
    let ic = min(1023, (a & 1023) + (b & 1023))
    return ia << 20 | ib << 10 | ic
}

private func cssSimplePseudoClass(_ n: String) -> CSSPseudoClass {
    switch n {
    case "first-child": return .firstChild
    case "last-child": return .lastChild
    case "only-child": return .onlyChild
    case "first-of-type": return .firstOfType
    case "last-of-type": return .lastOfType
    case "only-of-type": return .onlyOfType
    case "link", "any-link": return .link
    case "visited": return .visited
    case "hover": return .hover
    case "root", "scope": return .root
    case "empty": return .empty
    case "checked": return .checked
    case "disabled": return .disabled
    case "enabled": return .enabled
    case "defined": return .always
    default: return .never        // :active, :focus, :target, unknown, ...
    }
}

private func cssParseAttrSelector(_ t: [CSSToken], _ from: Int, _ to: Int) -> CSSAttrSelector? {
    var k = from
    func skip() { while k < to, case .whitespace = t[k] { k += 1 } }
    skip()
    guard k < to, case .ident(let n) = t[k] else { return nil }
    let name = cssLower(n)
    k += 1
    skip()
    if k >= to { return CSSAttrSelector(name: name, op: .exists, value: "", caseInsensitive: false) }
    var op = CSSAttrOp.equals
    guard case .delim(let d) = t[k] else { return nil }
    if d == 0x3d { k += 1 }
    else {
        guard k + 1 < to, case .delim(0x3d) = t[k + 1] else { return nil }
        switch d {
        case 0x7e: op = .includes
        case 0x7c: op = .dashMatch
        case 0x5e: op = .prefix
        case 0x24: op = .suffix
        case 0x2a: op = .substring
        default: return nil
        }
        k += 2
    }
    skip()
    guard k < to else { return nil }
    var value = ""
    switch t[k] {
    case .ident(let v): value = v
    case .string(let v): value = v
    case .number(let v, true): value = cssIntString(Int(v))
    default: return nil
    }
    k += 1
    skip()
    var ci = false
    if k < to {
        guard case .ident(let f) = t[k] else { return nil }
        let lf = cssLower(f)
        if lf == "i" { ci = true } else if lf != "s" { return nil }
        k += 1
        skip()
        if k < to { return nil }
    }
    return CSSAttrSelector(name: name, op: op, value: value, caseInsensitive: ci)
}

/// an+b microsyntax.
func cssParseNth(_ args: [CSSToken]) -> (Int, Int)? {
    var s: [UInt8] = []
    for tok in args {
        switch tok {
        case .whitespace: s.append(0x20)
        case .ident(let n): s.append(contentsOf: Array(cssLower(n).utf8))
        case .number(let v, let isInt):
            guard isInt, abs(v) < 1e7 else { return nil }
            var prev: UInt8 = 0
            for b in s.reversed() where b != 0x20 { prev = b; break }
            if v >= 0 && prev != 0 && prev != 0x2b && prev != 0x2d { s.append(0x2b) }
            s.append(contentsOf: Array(cssIntString(Int(v)).utf8))
        case .dimension(let v, let u, let isInt):
            guard isInt, abs(v) < 1e7 else { return nil }
            s.append(contentsOf: Array(cssIntString(Int(v)).utf8))
            s.append(contentsOf: Array(cssLower(u).utf8))
        case .delim(let d):
            guard d == 0x2b || d == 0x2d else { return nil }
            s.append(UInt8(d))
        default: return nil
        }
    }
    // Strip spaces (the grammar allows them only around the sign, which we accept loosely).
    var core: [UInt8] = []
    for b in s where b != 0x20 { core.append(b) }
    if core.isEmpty { return nil }
    let str = String(decoding: core, as: UTF8.self)
    if str == "odd" { return (2, 1) }
    if str == "even" { return (2, 0) }
    var nPos = -1
    for (k, b) in core.enumerated() where b == 0x6e { nPos = k; break }
    func parseInt(_ b: ArraySlice<UInt8>) -> Int? {
        var neg = false
        var v = 0
        var any = false
        var first = true
        for c in b {
            if first && (c == 0x2b || c == 0x2d) { neg = c == 0x2d; first = false; continue }
            first = false
            guard c >= 0x30 && c <= 0x39 else { return nil }
            v = v * 10 + Int(c - 0x30)
            if v > 10_000_000 { return nil }
            any = true
        }
        return any ? (neg ? -v : v) : nil
    }
    if nPos < 0 {
        guard let b = parseInt(core[...]) else { return nil }
        return (0, b)
    }
    let aPart = core[0..<nPos]
    var a: Int
    if aPart.isEmpty || aPart == [0x2b] { a = 1 }
    else if aPart == [0x2d] { a = -1 }
    else { guard let v = parseInt(aPart) else { return nil }; a = v }
    let rest = core[(nPos + 1)...]
    if rest.isEmpty { return (a, 0) }
    guard let b = parseInt(rest), rest.first == 0x2b || rest.first == 0x2d else { return nil }
    return (a, b)
}

func cssParseSelectorList(_ tokens: [CSSToken]) -> [CSSComplexSelector]? {
    var p = CSSSelectorParser(tokens)
    guard let l = p.parseList(0), !l.isEmpty else { return nil }
    return l
}

func cssParseSelectorList(_ s: String) -> [CSSComplexSelector]? {
    cssParseSelectorList(cssTokenize(Array(s.utf8)))
}

// MARK: - Matching

@inline(__always) func cssNthMatches(_ a: Int, _ b: Int, _ idx: Int) -> Bool {
    if a == 0 { return idx == b }
    let d = idx - b
    return d % a == 0 && d / a >= 0
}

private func cssTypeIndex<E: CSSElement>(_ el: E) -> Int {
    var n = 1
    let tag = el.cssTagName
    var cur = el.cssPreviousElementSibling
    while let p = cur { if p.cssTagName == tag { n += 1 }; cur = p.cssPreviousElementSibling }
    return n
}

private func cssTypeCount<E: CSSElement>(_ el: E) -> Int {
    var n = cssTypeIndex(el)
    let tag = el.cssTagName
    var cur = el.cssNextElementSibling
    while let p = cur { if p.cssTagName == tag { n += 1 }; cur = p.cssNextElementSibling }
    return n
}

private func cssAttrMatches(_ a: CSSAttrSelector, _ value: String) -> Bool {
    var v = Array(value.utf8)
    var want = Array(a.value.utf8)
    if a.caseInsensitive {
        for k in 0..<v.count where v[k] >= 0x41 && v[k] <= 0x5a { v[k] += 32 }
        for k in 0..<want.count where want[k] >= 0x41 && want[k] <= 0x5a { want[k] += 32 }
    }
    switch a.op {
    case .exists: return true
    case .equals: return v == want
    case .prefix: return !want.isEmpty && v.starts(with: want)
    case .suffix: return !want.isEmpty && v.count >= want.count && Array(v[(v.count - want.count)...]) == want
    case .substring:
        if want.isEmpty || want.count > v.count { return false }
        var s = 0
        while s + want.count <= v.count {
            var ok = true
            for k in 0..<want.count where v[s + k] != want[k] { ok = false; break }
            if ok { return true }
            s += 1
        }
        return false
    case .dashMatch:
        if v == want { return true }
        return v.count > want.count && v.starts(with: want) && v[want.count] == 0x2d
    case .includes:
        if want.isEmpty { return false }
        var s = 0
        while s < v.count {
            while s < v.count && cssIsWS(Int(v[s])) { s += 1 }
            var e = s
            while e < v.count && !cssIsWS(Int(v[e])) { e += 1 }
            if e > s && Array(v[s..<e]) == want { return true }
            s = e
        }
        return false
    }
}

func cssMatchCompound<E: CSSElement>(_ c: CSSCompound, _ el: E, _ budget: inout Int) -> Bool {
    if !c.tag.isEmpty && el.cssTagName != c.tag { return false }
    for id in c.ids where el.cssID != id { return false }
    if !c.classes.isEmpty {
        let have = el.cssClasses
        for k in c.classes where !have.contains(k) { return false }
    }
    for a in c.attrs {
        guard let v = el.cssAttribute(a.name) else { return false }
        if !cssAttrMatches(a, v) { return false }
    }
    for p in c.pseudos {
        switch p {
        case .firstChild: if el.cssSiblingIndex != 1 { return false }
        case .lastChild: if el.cssSiblingIndex != el.cssSiblingCount { return false }
        case .onlyChild: if el.cssSiblingCount != 1 { return false }
        case .firstOfType: if cssTypeIndex(el) != 1 { return false }
        case .lastOfType: if cssTypeIndex(el) != cssTypeCount(el) { return false }
        case .onlyOfType: if cssTypeCount(el) != 1 { return false }
        case .link: if !el.cssIsLink { return false }
        case .hover: if !el.cssIsHovered { return false }
        case .root: if !el.cssIsRoot { return false }
        case .empty: if !el.cssIsEmpty { return false }
        case .checked: if !el.cssIsChecked { return false }
        case .disabled: if !el.cssIsDisabled { return false }
        case .enabled: if el.cssIsDisabled { return false }
        case .always: break
        case .visited, .never: return false
        }
    }
    for n in c.nths {
        var idx: Int
        switch n.kind {
        case .child: idx = el.cssSiblingIndex
        case .lastChild: idx = el.cssSiblingCount - el.cssSiblingIndex + 1
        case .ofType: idx = cssTypeIndex(el)
        case .lastOfType: idx = cssTypeCount(el) - cssTypeIndex(el) + 1
        }
        if !cssNthMatches(n.a, n.b, idx) { return false }
    }
    for s in c.negations where cssMatchComplex(s, el, &budget) { return false }
    for list in c.anyOf {
        var hit = false
        for s in list where cssMatchComplex(s, el, &budget) { hit = true; break }
        if !hit { return false }
    }
    return true
}

private func cssMatchFrom<E: CSSElement>(_ s: CSSComplexSelector, _ idx: Int, _ el: E, _ budget: inout Int) -> Bool {
    budget -= 1
    if budget < 0 { return false }
    if !cssMatchCompound(s.compounds[idx], el, &budget) { return false }
    if idx == 0 { return true }
    switch s.combinators[idx - 1] {
    case .child:
        guard let p = el.cssParent else { return false }
        return cssMatchFrom(s, idx - 1, p, &budget)
    case .descendant:
        var cur = el.cssParent
        while let p = cur {
            if cssMatchFrom(s, idx - 1, p, &budget) { return true }
            if budget < 0 { return false }
            cur = p.cssParent
        }
        return false
    case .adjacent:
        guard let p = el.cssPreviousElementSibling else { return false }
        return cssMatchFrom(s, idx - 1, p, &budget)
    case .general:
        var cur = el.cssPreviousElementSibling
        while let p = cur {
            if cssMatchFrom(s, idx - 1, p, &budget) { return true }
            if budget < 0 { return false }
            cur = p.cssPreviousElementSibling
        }
        return false
    }
}

/// Does `el` match the selector (ignoring its pseudo-element)? `budget` caps
/// the work on hostile selector/tree combinations.
func cssMatchComplex<E: CSSElement>(_ s: CSSComplexSelector, _ el: E, _ budget: inout Int) -> Bool {
    guard !s.compounds.isEmpty else { return false }
    return cssMatchFrom(s, s.compounds.count - 1, el, &budget)
}

func cssMatches<E: CSSElement>(_ s: CSSComplexSelector, _ el: E) -> Bool {
    var budget = 50_000
    return cssMatchComplex(s, el, &budget)
}
