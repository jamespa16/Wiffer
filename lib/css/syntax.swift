// CSS Syntax Level 3 parsing: rules, at-rules and declarations, with the
// spec's error recovery (skip what isn't understood, resume at the next rule
// or declaration). Works on the flat token array; nesting is tracked with an
// explicit stack, so hostile nesting cannot overflow the call stack.

struct CSSStyleRule {
    var selectors: [CSSComplexSelector]
    var declarations: [CSSDeclaration]
}

enum CSSRule {
    case style(CSSStyleRule)
    case media(CSSMediaQueryList, [CSSRule])
}

struct CSSImportRule {
    /// As written in the stylesheet (resolved by `resolveURL` if one was given).
    var url: String
    var media: CSSMediaQueryList
}

struct CSSStylesheet {
    var rules: [CSSRule] = []
    /// `@import`s in order. The cascade takes sheets in order, so the browser
    /// fetches these and adds each (if its media matches) before this sheet.
    var imports: [CSSImportRule] = []
    init() {}
}

let cssMaxComponentDepth = 32
let cssMaxRuleDepth = 8

/// Build a component-value tree from tokens[lo..<hi]. Nesting deeper than
/// `cssMaxComponentDepth` is dropped.
func cssBuildComponents(_ t: [CSSToken], _ lo: Int, _ hi: Int, keepWS: Bool) -> [CSSComponent] {
    struct Frame { var kind: UInt8; var name: String; var items: [CSSComponent] }
    var stack: [Frame] = [Frame(kind: 0, name: "", items: [])]
    var overflow = 0
    func close(_ stack: inout [Frame]) {
        let f = stack.removeLast()
        let c: CSSComponent = f.kind == 1 ? .function(f.name, f.items) : .block(f.kind, f.items)
        stack[stack.count - 1].items.append(c)
    }
    var k = max(lo, 0)
    let end = min(hi, t.count)
    while k < end {
        let tok = t[k]
        k += 1
        switch tok {
        case .function(let n):
            if overflow > 0 || stack.count > cssMaxComponentDepth { overflow += 1 }
            else { stack.append(Frame(kind: 1, name: n, items: [])) }
        case .openParen:
            if overflow > 0 || stack.count > cssMaxComponentDepth { overflow += 1 }
            else { stack.append(Frame(kind: 0x28, name: "", items: [])) }
        case .openBracket:
            if overflow > 0 || stack.count > cssMaxComponentDepth { overflow += 1 }
            else { stack.append(Frame(kind: 0x5b, name: "", items: [])) }
        case .openBrace:
            if overflow > 0 || stack.count > cssMaxComponentDepth { overflow += 1 }
            else { stack.append(Frame(kind: 0x7b, name: "", items: [])) }
        case .closeParen, .closeBracket, .closeBrace:
            if overflow > 0 { overflow -= 1; continue }
            let want: UInt8
            switch tok {
            case .closeParen: want = 0x28
            case .closeBracket: want = 0x5b
            default: want = 0x7b
            }
            let top = stack[stack.count - 1]
            if stack.count > 1 && (top.kind == want || (top.kind == 1 && want == 0x28)) { close(&stack) }
        case .whitespace:
            if keepWS && overflow == 0 { stack[stack.count - 1].items.append(.token(tok)) }
        default:
            if overflow == 0 { stack[stack.count - 1].items.append(.token(tok)) }
        }
    }
    while stack.count > 1 { close(&stack) }
    return stack[0].items
}

/// Components back to a flat token list.
func cssFlatten(_ comps: [CSSComponent]) -> [CSSToken] {
    var out: [CSSToken] = []
    func go(_ c: [CSSComponent], _ depth: Int) {
        if depth > cssMaxComponentDepth + 2 { return }
        for item in c {
            switch item {
            case .token(let t): out.append(t)
            case .function(let n, let args): out.append(.function(n)); go(args, depth + 1); out.append(.closeParen)
            case .block(let k, let inner):
                out.append(k == 0x28 ? .openParen : (k == 0x5b ? .openBracket : .openBrace))
                go(inner, depth + 1)
                out.append(k == 0x28 ? .closeParen : (k == 0x5b ? .closeBracket : .closeBrace))
            }
        }
    }
    go(comps, 0)
    return out
}

// MARK: - Declarations

/// Parse a declaration list (a style rule's block or a style="" attribute).
func cssParseDeclarationTokens(_ t: [CSSToken], _ lo: Int, _ hi: Int, resolveURL: ((String) -> String)?) -> [CSSDeclaration] {
    var out: [CSSDeclaration] = []
    var i = lo
    while i < hi {
        switch t[i] {
        case .whitespace, .semicolon: i += 1; continue
        default: break
        }
        // The declaration runs to the next top-level ';'. A nested {} block ends
        // the item (a nested rule, which we don't support) unless this is a custom property.
        var isCustom = false
        if case .ident(let n) = t[i], n.utf8.count >= 2, n.utf8.first == 0x2d, n.utf8.dropFirst().first == 0x2d { isCustom = true }
        var j = i
        var endOfItem = hi
        var consumed = hi
        scan: while j < hi {
            switch t[j] {
            case .semicolon:
                endOfItem = j; consumed = j + 1
                break scan
            case .openBrace where !isCustom:
                let (e, _) = cssMatchEnd(t, j, hi)
                endOfItem = e; consumed = e
                break scan
            case .function, .openParen, .openBracket, .openBrace:
                j = cssMatchEnd(t, j, hi).0
            default:
                j += 1
            }
        }
        let start = i
        i = max(consumed, i + 1)
        // ident ws* ':' value
        guard case .ident(let name) = t[start] else { continue }
        var k = start + 1
        while k < endOfItem, case .whitespace = t[k] { k += 1 }
        guard k < endOfItem, case .colon = t[k] else { continue }
        k += 1
        var vend = endOfItem
        // !important at the end.
        var important = false
        var e = vend
        while e > k, case .whitespace = t[e - 1] { e -= 1 }
        if e - 1 >= k, case .ident(let imp) = t[e - 1], cssLower(imp) == "important" {
            var b = e - 2
            while b >= k, case .whitespace = t[b] { b -= 1 }
            if b >= k, case .delim(0x21) = t[b] { important = true; vend = b }
        }
        let comps = cssBuildComponents(t, k, vend, keepWS: false)
        let isCustomName = name.utf8.count >= 2 && name.utf8.first == 0x2d && name.utf8.dropFirst().first == 0x2d
        if comps.isEmpty && !isCustomName { continue }
        out.append(contentsOf: cssMakeDeclarations(name: name, comps, important: important, resolveURL: resolveURL))
    }
    return out
}

// MARK: - Stylesheet

struct CSSStylesheetParser {
    let t: [CSSToken]
    let resolveURL: ((String) -> String)?

    init(_ tokens: [CSSToken], resolveURL: ((String) -> String)?) { t = tokens; self.resolveURL = resolveURL }

    /// End of an at-rule prelude: (index, 0 = EOF, 1 = ';', 2 = '{').
    func scanAtRule(_ from: Int, _ hi: Int) -> (Int, Int) {
        var k = from
        while k < hi {
            switch t[k] {
            case .semicolon: return (k, 1)
            case .openBrace: return (k, 2)
            case .function, .openParen, .openBracket:
                k = cssMatchEnd(t, k, hi).0
            default: k += 1
            }
        }
        return (hi, 0)
    }

    func parseRules(_ lo: Int, _ hi: Int, depth: Int, top: Bool,
                    rules: inout [CSSRule], imports: inout [CSSImportRule], sawRule: inout Bool) {
        var i = lo
        while i < hi {
            switch t[i] {
            case .whitespace, .cdo, .cdc:
                i += 1
            case .atKeyword(let rawName):
                let name = cssLower(rawName)
                let (pe, kind) = scanAtRule(i + 1, hi)
                let preludeLo = i + 1
                var cLo = 0, cHi = 0
                var next = pe
                if kind == 2 {
                    let (be, closed) = cssMatchEnd(t, pe, hi)
                    cLo = pe + 1
                    cHi = closed ? be - 1 : be
                    next = be
                } else if kind == 1 { next = pe + 1 }
                i = max(next, i + 1)
                switch name {
                case "charset": break
                case "import":
                    if top && !sawRule { parseImport(preludeLo, pe, &imports) }
                case "media":
                    sawRule = true
                    guard kind == 2, depth < cssMaxRuleDepth else { break }
                    let list = cssParseMediaQueryList(cssBuildComponents(t, preludeLo, pe, keepWS: false))
                    var sub: [CSSRule] = []
                    var subImports: [CSSImportRule] = []
                    var saw = true
                    parseRules(cLo, cHi, depth: depth + 1, top: false, rules: &sub, imports: &subImports, sawRule: &saw)
                    if !sub.isEmpty { rules.append(.media(list, sub)) }
                case "supports":
                    sawRule = true
                    guard kind == 2, depth < cssMaxRuleDepth else { break }
                    if cssEvalSupports(cssBuildComponents(t, preludeLo, pe, keepWS: true)) {
                        var subImports: [CSSImportRule] = []
                        var saw = true
                        parseRules(cLo, cHi, depth: depth + 1, top: false, rules: &rules, imports: &subImports, sawRule: &saw)
                    }
                case "layer", "-moz-document", "document":
                    sawRule = true
                    guard kind == 2, depth < cssMaxRuleDepth else { break }
                    if name == "layer" {
                        var subImports: [CSSImportRule] = []
                        var saw = true
                        parseRules(cLo, cHi, depth: depth + 1, top: false, rules: &rules, imports: &subImports, sawRule: &saw)
                    }
                default:
                    sawRule = true      // @font-face, @keyframes, @page, ...: parsed and ignored
                }
            case .closeBrace:
                i += 1
            default:
                // Qualified rule: prelude up to the '{'.
                var k = i
                var open = -1
                while k < hi {
                    if case .openBrace = t[k] { open = k; break }
                    switch t[k] {
                    case .function, .openParen, .openBracket: k = cssMatchEnd(t, k, hi).0
                    default: k += 1
                    }
                }
                if open < 0 { i = hi; continue }
                let (be, closed) = cssMatchEnd(t, open, hi)
                let cHi = closed ? be - 1 : be
                let selTokens = Array(t[i..<open])
                i = be
                sawRule = true
                guard let sels = cssParseSelectorList(selTokens) else { continue }
                let decls = cssParseDeclarationTokens(t, open + 1, cHi, resolveURL: resolveURL)
                if !decls.isEmpty { rules.append(.style(CSSStyleRule(selectors: sels, declarations: decls))) }
            }
        }
    }

    func parseImport(_ lo: Int, _ hi: Int, _ imports: inout [CSSImportRule]) {
        let comps = cssBuildComponents(t, lo, hi, keepWS: false)
        guard !comps.isEmpty else { return }
        var url: String? = nil
        switch comps[0] {
        case .token(.string(let s)): url = s
        case .token(.url(let s)): url = s
        case .function(let n, let args):
            if cssLower(n) == "url", args.count == 1, case .token(.string(let s)) = args[0] { url = s }
        default: break
        }
        guard let u = url else { return }
        var rest: [CSSComponent] = []
        for c in comps.dropFirst() {
            if case .function(let n, _) = c {
                let l = cssLower(n)
                if l == "layer" || l == "supports" { continue }
            }
            if case .token(.ident(let n)) = c, cssLower(n) == "layer" { continue }
            rest.append(c)
        }
        imports.append(CSSImportRule(url: resolveURL?(u) ?? u, media: cssParseMediaQueryList(rest)))
    }
}

func cssParseStylesheet(_ bytes: [UInt8], resolveURL: ((String) -> String)? = nil) -> CSSStylesheet {
    let toks = cssTokenize(bytes)
    var sheet = CSSStylesheet()
    var saw = false
    let p = CSSStylesheetParser(toks, resolveURL: resolveURL)
    p.parseRules(0, toks.count, depth: 0, top: true, rules: &sheet.rules, imports: &sheet.imports, sawRule: &saw)
    return sheet
}

func cssParseStylesheet(_ source: String, resolveURL: ((String) -> String)? = nil) -> CSSStylesheet {
    cssParseStylesheet(Array(source.utf8), resolveURL: resolveURL)
}

/// The declarations of a style="" attribute.
func cssParseInlineStyle(_ source: String, resolveURL: ((String) -> String)? = nil) -> [CSSDeclaration] {
    let toks = cssTokenize(Array(source.utf8))
    return cssParseDeclarationTokens(toks, 0, toks.count, resolveURL: resolveURL)
}
