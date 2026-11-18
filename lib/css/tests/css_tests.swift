// Host tests for lib/css. A tiny element tree stands in for the DOM.

final class TestEl: CSSElement {
    var tag: String
    var idAttr = ""
    var classList: [String] = []
    var attrs: [String: String] = [:]
    var children: [TestEl] = []
    var parent: TestEl? = nil
    var hover = false
    var link = false
    var style = CSSComputedStyle()

    init(_ tag: String, id: String = "", cls: String = "", attrs: [String: String] = [:], _ kids: [TestEl] = []) {
        self.tag = tag
        idAttr = id
        var cur: [UInt8] = []
        for b in cls.utf8 {
            if b == 0x20 { if !cur.isEmpty { classList.append(String(decoding: cur, as: UTF8.self)); cur = [] } }
            else { cur.append(b) }
        }
        if !cur.isEmpty { classList.append(String(decoding: cur, as: UTF8.self)) }
        self.attrs = attrs
        for k in kids { append(k) }
    }
    func append(_ k: TestEl) { k.parent = self; children.append(k) }

    var cssTagName: String { tag }
    var cssID: String { idAttr }
    var cssClasses: [String] { classList }
    func cssAttribute(_ name: String) -> String? {
        if name == "id" && !idAttr.isEmpty { return idAttr }
        if name == "class" && !classList.isEmpty { return classList.joined(separator: " ") }
        return attrs[name]
    }
    var cssParent: TestEl? { parent }
    private func index() -> Int {
        guard let p = parent else { return 0 }
        for (i, c) in p.children.enumerated() where c === self { return i }
        return 0
    }
    var cssPreviousElementSibling: TestEl? {
        guard let p = parent else { return nil }
        let i = index()
        return i > 0 ? p.children[i - 1] : nil
    }
    var cssNextElementSibling: TestEl? {
        guard let p = parent else { return nil }
        let i = index()
        return i + 1 < p.children.count ? p.children[i + 1] : nil
    }
    var cssIsRoot: Bool { parent == nil }
    var cssIsHovered: Bool { hover }
    var cssIsLink: Bool { link }
}

func styleTree(_ el: TestEl, _ r: CSSStyleResolver, _ parent: CSSComputedStyle?) {
    el.style = r.computeStyle(el, parent: parent)
    for c in el.children { styleTree(c, r, el.style) }
}

func makeResolver(_ sheets: [String], ua: Bool = false, ctx: CSSContext = CSSContext()) -> CSSStyleResolver {
    let r = CSSStyleResolver(ctx: ctx, noUserAgent: !ua)
    for s in sheets { r.addStyleSheet(cssParseStylesheet(s)) }
    return r
}

/// Style the tree (root = first arg) with these author sheets and return `target`'s style.
func styled(_ root: TestEl, _ target: TestEl, _ sheets: [String], ua: Bool = false) -> CSSComputedStyle {
    styleTree(root, makeResolver(sheets, ua: ua), nil)
    return target.style
}

func tokDump(_ s: String) -> String {
    var out = ""
    for t in cssTokenize(Array(s.utf8)) {
        switch t {
        case .ident(let v): out += "I(\(v))"
        case .function(let v): out += "F(\(v))"
        case .atKeyword(let v): out += "@(\(v))"
        case .hash(let v, let id): out += "#(\(v)\(id ? "!" : ""))"
        case .string(let v): out += "S(\(v))"
        case .badString: out += "BS"
        case .url(let v): out += "U(\(v))"
        case .badUrl: out += "BU"
        case .delim(let c): out += "D(\(Character(UnicodeScalar(UInt8(truncatingIfNeeded: c)))))"
        case .number(let v, let i): out += "N(\(Int(v * 100))\(i ? "i" : ""))"
        case .percentage(let v): out += "%(\(Int(v * 100)))"
        case .dimension(let v, let u, _): out += "Dim(\(Int(v * 100))\(u))"
        case .whitespace: out += "_"
        case .cdo: out += "CDO"
        case .cdc: out += "CDC"
        case .colon: out += ":"
        case .semicolon: out += ";"
        case .comma: out += ","
        case .openBracket: out += "["
        case .closeBracket: out += "]"
        case .openParen: out += "("
        case .closeParen: out += ")"
        case .openBrace: out += "{"
        case .closeBrace: out += "}"
        }
    }
    return out
}

func ruleCount(_ s: CSSStylesheet) -> Int {
    var n = 0
    func go(_ rs: [CSSRule]) {
        for r in rs {
            switch r {
            case .style: n += 1
            case .media(_, let sub): go(sub)
            }
        }
    }
    go(s.rules)
    return n
}

func firstDecls(_ s: CSSStylesheet) -> [CSSDeclaration] {
    for r in s.rules { if case .style(let sr) = r { return sr.declarations } }
    return []
}

func rgba(_ c: CSSColor) -> String { "\(c.r),\(c.g),\(c.b),\(c.a)" }

func libTests(_ t: Tests) {
    testTokenizer(t)
    testParser(t)
    testSelectors(t)
    testCascade(t)
    testInheritance(t)
    testVars(t)
    testMedia(t)
    testValues(t)
    testShorthands(t)
    testUserAgent(t)
    testPseudoElements(t)
    testFuzz(t)
    testPerformance(t)
}

func testTokenizer(_ t: Tests) {
    t.section("tokenizer")
    t.equal(tokDump("a { color: #fff; width: 10px }"), "I(a)_{_I(color):_#(fff!);_I(width):_Dim(1000px)_}", "basic rule")
    t.equal(tokDump("1 1.5 -2px +.5 50% 1e3 1em 1e"), "N(100i)_N(150)_Dim(-200px)_N(50)_%(5000)_N(100000)_Dim(100em)_Dim(100e)", "numbers")
    t.equal(tokDump("\"a\\\"b\" 'c'"), "S(a\"b)_S(c)", "strings with escape")
    t.equal(tokDump("\"abc\ndef\""), "BS_I(def)S()", "bad string stops at newline")
    t.equal(tokDump("url(  a.png ) url(\"b.png\") url(a b)"), "U(a.png)_F(url)S(b.png))_BU", "url tokens")
    t.equal(tokDump("a/* c */b /* unterminated"), "I(a)I(b)_", "comments")
    t.equal(tokDump("\\66 oo b\\61r"), "I(foo)_I(bar)", "escapes in idents")
    t.equal(tokDump("<!-- --> @media #1a #a1"), "CDO_CDC_@(media)_#(1a)_#(a1!)", "cdo/cdc/at/hash")
    t.equal(tokDump("a:not(.b)"), "I(a):F(not)D(.)I(b))", "function")
    t.equal(tokDump("-->-a-- --x"), "CDCI(-a--)_I(--x)", "dashes")
    t.equal(tokDump("\"unterminated"), "S(unterminated)", "unterminated string")
    t.equal(tokDump("\\"), "D(\\)", "lone backslash")
    t.equal(tokDump("é"), "I(é)", "non-ascii ident")
}

func testParser(_ t: Tests) {
    t.section("parser")
    var s = cssParseStylesheet("a { color: red } b { width: 1px } /* c */ c { margin: 0 }")
    t.equal(ruleCount(s), 3, "three rules")
    s = cssParseStylesheet("a { color: red; ; width: ; foo ; margin: 1px 2px }")
    t.equal(firstDecls(s).count, 1 + 4, "bad declarations skipped (color + 4 margins)")
    s = cssParseStylesheet("a, { color: red } b { color: blue }")
    t.equal(ruleCount(s), 1, "invalid selector list drops the rule, next survives")
    s = cssParseStylesheet("} a { color: red } }")
    t.equal(ruleCount(s), 1, "stray closing braces")
    s = cssParseStylesheet("a { color: red; b { color: blue } width: 5px }")
    t.equal(firstDecls(s).count, 2, "nested block ends an item")
    s = cssParseStylesheet("a { color: red")
    t.equal(firstDecls(s).count, 1, "unclosed block at EOF is kept")
    s = cssParseStylesheet("@font-face { font-family: x; src: url(a.woff) } @keyframes k { from { top: 0 } to { top: 1px } } p { margin: 0 }")
    t.equal(ruleCount(s), 1, "font-face and keyframes ignored")
    s = cssParseStylesheet("@import url(a.css); @import 'b.css' screen and (min-width: 100px); @charset \"x\"; a { color: red } @import 'late.css';")
    t.equal(s.imports.count, 2, "imports reported")
    t.equal(s.imports[0].url, "a.css", "import url()")
    t.equal(s.imports[1].url, "b.css", "import string")
    var c = CSSContext()
    t.check(s.imports[1].media.matches(c), "import media matches 1024px")
    c.viewportWidth = 50
    t.check(!s.imports[1].media.matches(c), "import media doesn't match 50px")
    s = cssParseStylesheet("@media screen { a { color: red } @media (min-width: 10px) { b { color: blue } } } @unknown foo; @unknown { x { y: z } } p { top: 0 }")
    t.equal(ruleCount(s), 3, "nested media and unknown at-rules")
    s = cssParseStylesheet("a { color: red !important; width: 1px ! important; height: 2px !IMPORTANT; margin: 0 }")
    var imp = 0
    for d in firstDecls(s) where d.important { imp += 1 }
    t.equal(imp, 3, "important flags")
    s = cssParseStylesheet("a { background: url(a;b.png) }")
    t.equal(firstDecls(s).count, 3, "url with semicolon inside")
    s = cssParseStylesheet("a { color: red;; } ;; b { color: blue }")
    t.equal(ruleCount(s), 1, "top-level semicolons join the next prelude, as in the spec (b is lost)")
    s = cssParseStylesheet("a { width: calc(1px + (2px; } b { color: red }")
    t.equal(ruleCount(s), 0, "unbalanced paren swallows the rest (like browsers)")
    s = cssParseStylesheet("@supports (display: flex) { a { color: red } } @supports (display: grid) { b { color: red } } @supports not (foo: bar) { c { color: red } } @supports (color: red) and (width: 1px) { d { top: 0 } } @supports selector(a > b) { e { top: 0 } }")
    t.equal(ruleCount(s), 4, "@supports: flex yes, grid no, not(unknown) yes, and yes, selector() yes")
    s = cssParseStylesheet("@layer base { a { color: red } } @layer x, y;")
    t.equal(ruleCount(s), 1, "@layer block contents kept")
    // Deep nesting must not overflow anything.
    var deep = "a { width: "
    for _ in 0..<20000 { deep += "(" }
    s = cssParseStylesheet(deep)
    t.check(true, "deep parens survive")
    var deepFn = "a { width: "
    for _ in 0..<20000 { deepFn += "calc(" }
    s = cssParseStylesheet(deepFn + "1px" + String(repeating: ")", count: 20000) + " }")
    t.check(ruleCount(s) == 0, "deep calc nesting is invalid, no crash")
    var deepMedia = ""
    for _ in 0..<2000 { deepMedia += "@media screen{" }
    s = cssParseStylesheet(deepMedia + "a{color:red}")
    t.check(true, "deep @media survives")
    var deepSel = "a"
    for _ in 0..<5000 { deepSel += ":not(" }
    s = cssParseStylesheet(deepSel + "b { color: red }")
    t.equal(ruleCount(s), 0, "deep :not nesting rejected")
}

func testSelectors(_ t: Tests) {
    t.section("selectors")
    let li1 = TestEl("li", cls: "item first")
    let li2 = TestEl("li", id: "second", cls: "item", attrs: ["data-x": "foo-bar baz", "lang": "en-US"])
    let li3 = TestEl("li", cls: "item last")
    let ul = TestEl("ul", cls: "list", [li1, li2, li3])
    let p = TestEl("p", [TestEl("span", cls: "a b")])
    let span = p.children[0]
    let body = TestEl("body", [ul, p])
    let html = TestEl("html", [body])
    li2.link = true
    li2.hover = true
    func m(_ sel: String, _ el: TestEl) -> Bool {
        guard let l = cssParseSelectorList(sel) else { t.check(false, "parse \(sel)"); return false }
        for s in l where cssMatches(s, el) { return true }
        return false
    }
    t.check(m("li", li1), "type")
    t.check(!m("div", li1), "type mismatch")
    t.check(m("*", li1), "universal")
    t.check(m(".item", li1) && m(".first", li1) && !m(".last", li1), "class")
    t.check(m("li.item.first", li1) && !m("li.item.last", li1), "compound classes")
    t.check(m("#second", li2) && !m("#second", li1), "id")
    t.check(m("ul li", li1), "descendant")
    t.check(m("body li", li1), "descendant, deeper")
    t.check(!m("p li", li1), "descendant mismatch")
    t.check(m("ul > li", li1) && !m("body > li", li1), "child")
    t.check(m("li + li", li2) && !m("li + li", li1), "adjacent")
    t.check(m("li ~ li", li3) && m("li.first ~ li.last", li3) && !m("li.last ~ li.first", li1), "general sibling")
    t.check(m("ul + p", p), "adjacent across types")
    t.check(m("html > body > ul.list > li:first-child", li1), "long chain")
    t.check(m("[data-x]", li2) && !m("[data-x]", li1), "attr exists")
    t.check(m("[data-x=\"foo-bar baz\"]", li2) && !m("[data-x=foo]", li2), "attr equals")
    t.check(m("[data-x~=baz]", li2) && !m("[data-x~=foo]", li2), "attr includes")
    t.check(m("[lang|=en]", li2) && !m("[lang|=e]", li2), "attr dash match")
    t.check(m("[data-x^=foo]", li2) && !m("[data-x^=bar]", li2), "attr prefix")
    t.check(m("[data-x$=baz]", li2) && !m("[data-x$=bar]", li2), "attr suffix")
    t.check(m("[data-x*=\"o-b\"]", li2) && !m("[data-x*=zzz]", li2), "attr substring")
    t.check(m("[data-x=\"FOO-BAR BAZ\" i]", li2) && !m("[data-x=\"FOO-BAR BAZ\"]", li2), "attr i flag")
    t.check(m("li:first-child", li1) && !m("li:first-child", li2), ":first-child")
    t.check(m("li:last-child", li3) && !m("li:last-child", li2), ":last-child")
    t.check(m("p:only-child", p) == false && m("span:only-child", span), ":only-child")
    t.check(m("li:nth-child(2)", li2) && !m("li:nth-child(2)", li1), "nth-child(2)")
    t.check(m("li:nth-child(odd)", li1) && m("li:nth-child(odd)", li3) && !m("li:nth-child(odd)", li2), "odd")
    t.check(m("li:nth-child(even)", li2) && !m("li:nth-child(even)", li1), "even")
    t.check(m("li:nth-child(2n+1)", li3) && m("li:nth-child( 2n + 1 )", li1) && !m("li:nth-child(2n+1)", li2), "2n+1")
    t.check(m("li:nth-child(n+2)", li2) && m("li:nth-child(n+2)", li3) && !m("li:nth-child(n+2)", li1), "n+2")
    t.check(m("li:nth-child(-n+2)", li1) && m("li:nth-child(-n+2)", li2) && !m("li:nth-child(-n+2)", li3), "-n+2")
    t.check(m("li:nth-child(3n)", li3) && !m("li:nth-child(3n)", li2), "3n")
    t.check(m("li:nth-last-child(1)", li3) && m("li:nth-last-child(2)", li2), "nth-last-child")
    t.check(m("li:nth-of-type(2)", li2) && m("p:nth-of-type(1)", p) && m("li:first-of-type", li1) && m("li:last-of-type", li3), "of-type")
    t.check(m("li:not(.last)", li1) && !m("li:not(.last)", li3), ":not")
    t.check(m("li:not(.last, .first)", li2) && !m("li:not(.last, .first)", li1), ":not list")
    t.check(m("li:is(.first, .last)", li1) && !m("li:is(.first, .last)", li2), ":is")
    t.check(m(":link", li2) && !m(":link", li1) && m("li:any-link", li2), ":link")
    t.check(!m(":visited", li2), ":visited never")
    t.check(m("li:hover", li2) && !m("li:hover", li1), ":hover")
    t.check(m(":root", html) && !m(":root", body) && m("html:root", html), ":root")
    t.check(!m("li:active", li1) && !m("li:focus", li1), "unmatched dynamic pseudos")
    t.check(m("ul li, p", li1) && m("ul li, p", p), "selector list")
    t.check(m("span.a.b", span) && m("p span", span) && m("body p > span", span), "mixed")
    t.check(cssParseSelectorList("li:nth-child(foo)") == nil, "bad nth rejected")
    t.check(cssParseSelectorList("a >") == nil && cssParseSelectorList("> a") == nil, "dangling combinator")
    t.check(cssParseSelectorList("a..b") == nil && cssParseSelectorList("#1a") == nil, "bad simple selectors")
    t.check(cssParseSelectorList("a,,b") == nil && cssParseSelectorList("") == nil, "empty members")
    t.check(cssParseSelectorList("a[") == nil && cssParseSelectorList("a[b=]") == nil, "bad attribute")

    t.section("specificity")
    func spec(_ s: String) -> UInt32 { cssParseSelectorList(s)?.first?.specificity ?? 9999 }
    func abc(_ a: UInt32, _ b: UInt32, _ c: UInt32) -> UInt32 { a << 20 | b << 10 | c }
    t.check(spec("*") == 0, "* = 0,0,0")
    t.check(spec("li") == abc(0, 0, 1), "li")
    t.check(spec("ul li") == abc(0, 0, 2), "ul li")
    t.check(spec("ul ol li.red") == abc(0, 1, 3), "ul ol li.red")
    t.check(spec("li.red.level") == abc(0, 2, 1), "li.red.level")
    t.check(spec("#x34y") == abc(1, 0, 0), "#id")
    t.check(spec("li[a=b]:hover") == abc(0, 2, 1), "attr and pseudo-class")
    t.check(spec("a::before") == abc(0, 0, 2), "pseudo-element")
    t.check(spec("li:not(#s)") == abc(1, 0, 1), ":not takes its argument's")
    t.check(spec(":is(.a, #b) x") == abc(1, 0, 1), ":is takes the most specific")
    t.check(spec(":where(#a) x") == abc(0, 0, 1), ":where is zero")
    t.check(spec("a:nth-child(2)") == abc(0, 1, 1), "nth-child counts as a pseudo-class")
    t.check(abc(0, 1, 0) > abc(0, 0, 255), "class beats many types")
}

func testCascade(_ t: Tests) {
    t.section("cascade")
    func make() -> (TestEl, TestEl) {
        let d = TestEl("div", id: "x", cls: "a b")
        return (TestEl("html", [TestEl("body", [d])]), d)
    }
    var (root, d) = make()
    var st = styled(root, d, ["div { color: red } div { color: blue }"])
    t.equal(rgba(st.color), "0,0,255,255", "later rule wins at equal specificity")
    (root, d) = make()
    st = styled(root, d, ["div { color: red } .a { color: blue } div { color: green }"])
    t.equal(rgba(st.color), "0,0,255,255", "class beats type regardless of order")
    (root, d) = make()
    st = styled(root, d, [".a { color: red } #x { color: blue } div.a.b { color: green }"])
    t.equal(rgba(st.color), "0,0,255,255", "id beats classes")
    (root, d) = make()
    st = styled(root, d, ["div { color: red !important } #x { color: blue }"])
    t.equal(rgba(st.color), "255,0,0,255", "!important beats specificity")
    (root, d) = make()
    st = styled(root, d, ["#x { color: red !important } div { color: blue !important }"])
    t.equal(rgba(st.color), "255,0,0,255", "among important, specificity")
    (root, d) = make()
    d.attrs["style"] = "color: green"
    st = styled(root, d, ["#x { color: red }"])
    t.equal(rgba(st.color), "0,128,0,255", "style attribute beats id")
    (root, d) = make()
    d.attrs["style"] = "color: green"
    st = styled(root, d, ["#x { color: red !important }"])
    t.equal(rgba(st.color), "255,0,0,255", "author !important beats style attribute")
    (root, d) = make()
    d.attrs["style"] = "color: green !important"
    st = styled(root, d, ["#x { color: red !important }"])
    t.equal(rgba(st.color), "0,128,0,255", "important style attribute beats important rule")
    // Origins: author normal beats UA normal; UA important beats author important.
    let r = CSSStyleResolver(ctx: CSSContext(), noUserAgent: true)
    r.addStyleSheet(cssParseStylesheet("div { color: red; width: 10px !important }"), origin: .userAgent)
    r.addStyleSheet(cssParseStylesheet("div { color: blue; width: 20px !important }"))
    (root, d) = make()
    styleTree(root, r, nil)
    t.equal(rgba(d.style.color), "0,0,255,255", "author normal beats user-agent normal")
    t.equal(Int(d.style.width.lp.px), 10, "user-agent !important beats author !important")
    // Sheet order.
    (root, d) = make()
    st = styled(root, d, ["div { color: red }", "div { color: blue }"])
    t.equal(rgba(st.color), "0,0,255,255", "later sheet wins")
    // Invalid values don't override.
    (root, d) = make()
    st = styled(root, d, ["div { color: red } div { color: notacolor; width: -5px; width: 10px }"])
    t.equal(rgba(st.color), "255,0,0,255", "invalid declaration ignored, earlier value stays")
    t.equal(Int(st.width.lp.px), 10, "negative width invalid, later valid wins")
    // Fallback declarations
    (root, d) = make()
    st = styled(root, d, ["div { display: flex; display: foo }"])
    t.check(st.display == .flex, "unknown keyword falls back to earlier declaration")
    // Descendant rule matched through hierarchy; sibling-order independent.
    (root, d) = make()
    st = styled(root, d, ["html body div.a { width: 1px } body > div { width: 2px }"])
    t.equal(Int(st.width.lp.px), 1, "more specific descendant rule")
    // Rules from the middle of a selector list.
    (root, d) = make()
    st = styled(root, d, ["p, #x, span { width: 7px }"])
    t.equal(Int(st.width.lp.px), 7, "selector list member")
    // Media in cascade.
    (root, d) = make()
    st = styled(root, d, ["div { width: 1px } @media (min-width: 2000px) { div { width: 2px } } @media (max-width: 2000px) { div { width: 3px } }"])
    t.equal(Int(st.width.lp.px), 3, "media rules take part in order")
    // Hover.
    (root, d) = make()
    let rr = makeResolver(["div { color: red } div:hover { color: blue }"])
    d.hover = true
    styleTree(root, rr, nil)
    t.equal(rgba(d.style.color), "0,0,255,255", ":hover applies when flagged")
    // Re-evaluation on viewport change.
    let r2 = makeResolver(["div { width: 1px } @media (min-width: 2000px) { div { width: 2px } }"])
    (root, d) = make()
    styleTree(root, r2, nil)
    t.equal(Int(d.style.width.lp.px), 1, "narrow viewport")
    var c2 = r2.ctx
    c2.viewportWidth = 3000
    r2.setContext(c2)
    styleTree(root, r2, nil)
    t.equal(Int(d.style.width.lp.px), 2, "wide viewport after setContext")
}

func testInheritance(_ t: Tests) {
    t.section("inheritance")
    let span = TestEl("span", cls: "s")
    let p = TestEl("p", [span])
    let root = TestEl("html", [TestEl("body", [p])])
    var st = styled(root, span, ["body { color: red; font-size: 20px; margin-left: 10px; font-weight: bold; text-decoration: underline; border-top: 1px solid }"])
    t.equal(rgba(st.color), "255,0,0,255", "color inherits")
    t.equal(Int(st.fontSize), 20, "font-size inherits")
    t.equal(st.fontWeight, 700, "font-weight inherits")
    t.equal(Int(st.marginLeft.lp.px), 0, "margin does not inherit")
    t.check(!st.textDecoration.hasUnderline, "text-decoration does not inherit in the cascade")
    t.equal(Int(st.borderTopWidth), 0, "border does not inherit")
    st = styled(root, span, ["body { margin-left: 10px; color: red } p { margin-left: inherit; color: initial } span { color: unset; margin-left: unset; font-size: unset }"])
    t.equal(rgba(st.color), "0,0,0,255", "unset on an inherited property inherits (p's color is initial black)") // p color: initial = black; span unset inherits black
    t.equal(rgba(p.style.color), "0,0,0,255", "initial resets color")
    t.equal(Int(p.style.marginLeft.lp.px), 10, "inherit keyword takes the parent's margin")
    t.equal(Int(st.marginLeft.lp.px), 0, "unset on non-inherited property is initial")
    // em units
    st = styled(root, span, ["body { font-size: 20px } p { font-size: 1.5em; margin-left: 2em } span { font-size: 50%; padding-left: 3em }"])
    t.equal(Int(p.style.fontSize), 30, "font-size: 1.5em of parent")
    t.equal(Int(p.style.marginLeft.lp.px), 60, "margin 2em uses the element's own font-size")
    t.equal(Int(st.fontSize), 15, "font-size 50%")
    t.equal(Int(st.paddingLeft.px), 45, "padding 3em")
    st = styled(root, span, ["html { font-size: 10px } p { font-size: 2rem; width: 5rem }"])
    t.equal(Int(p.style.fontSize), 20, "rem uses root font size")
    t.equal(Int(p.style.width.lp.px), 50, "rem width")
    st = styled(root, span, ["body { font-size: larger } p { font-size: smaller } span { font-size: x-large }"])
    t.equal(Int(p.style.fontSize * 100), Int(16 * 1.2 / 1.2 * 100), "larger then smaller")
    t.equal(Int(st.fontSize), 24, "x-large keyword")
    st = styled(root, span, ["body { font-weight: bold } p { font-weight: bolder } span { font-weight: lighter }"])
    t.equal(p.style.fontWeight, 900, "bolder")
    t.equal(st.fontWeight, 700, "lighter than 900 is 700")
    st = styled(root, span, ["body { line-height: 1.5; font-size: 10px } p { font-size: 20px }"])
    t.equal(Int(st.lineHeightPx), 30, "unitless line-height inherits as a number")
    st = styled(root, span, ["body { line-height: 150%; font-size: 10px } p { font-size: 20px }"])
    t.equal(Int(st.lineHeightPx), 15, "percentage line-height computes to px at the declaring element")
    st = styled(root, span, ["body { font-family: Arial, 'Helvetica Neue', sans-serif }"])
    t.equal(st.fontFamily.count, 3, "font-family list")
    t.equal(st.fontFamily[1], "Helvetica Neue", "quoted family")
    st = styled(root, span, ["body { font-family: Times New Roman, serif }"])
    t.equal(st.fontFamily[0], "Times New Roman", "unquoted multi-word family")
    // blockification
    st = styled(root, span, ["span { float: left }"])
    t.check(st.display == .block, "float blockifies inline")
    st = styled(root, span, ["span { position: absolute; float: right }"])
    t.check(st.display == .block && st.float == .none, "absolute positioning cancels float and blockifies")
    // Border width zero without style; currentColor default.
    st = styled(root, span, ["body { color: #123456 } span { border-width: 4px; border-bottom: 2px solid }"])
    t.equal(Int(st.borderTopWidth), 0, "border width ignored without style")
    t.equal(Int(st.borderBottomWidth), 2, "border-bottom 2px solid")
    t.equal(rgba(st.borderBottomColor), "18,52,86,255", "border color defaults to currentColor")
    st = styled(root, span, ["span { color: red; border: 1px solid blue; border-left-color: currentcolor }"])
    t.equal(rgba(st.borderTopColor), "0,0,255,255", "explicit border color")
    t.equal(rgba(st.borderLeftColor), "255,0,0,255", "currentcolor keyword")
}

func testVars(_ t: Tests) {
    t.section("var()")
    func one(_ css: String, _ prop: (CSSComputedStyle) -> String) -> String {
        let span = TestEl("span")
        let root = TestEl("html", [TestEl("body", [span])])
        return prop(styled(root, span, [css]))
    }
    func color(_ css: String) -> String { one(css) { rgba($0.color) } }
    func width(_ css: String) -> String { one(css) { "\(Int($0.width.lp.px))/\(Int($0.width.lp.pct))" } }
    t.equal(color(":root { --c: red } span { color: var(--c) }"), "255,0,0,255", "basic")
    t.equal(color("html { --c: red } span { color: var(--c) }"), "255,0,0,255", "inherited custom property")
    t.equal(color("span { color: var(--missing, blue) }"), "0,0,255,255", "fallback")
    t.equal(color("span { color: red; color: var(--missing) }"), "0,0,0,255", "invalid at computed-value time -> unset (inherited initial)")
    t.equal(color("span { --a: var(--b); --b: green; color: var(--a) }"), "0,128,0,255", "custom property referencing another")
    t.equal(color("span { --a: var(--missing, var(--b, yellow)); color: var(--a) }"), "255,255,0,255", "nested fallbacks")
    t.equal(color("span { --a: var(--b); --b: var(--a); color: var(--a) }"), "0,0,0,255", "cycle makes both invalid")
    t.equal(color("span { --a: var(--b); --b: var(--a); color: var(--a, blue) }"), "0,0,255,255", "cycle -> guaranteed-invalid -> fallback")
    t.equal(color("span { --a: var(--a); color: var(--a) }"), "0,0,0,255", "self cycle")
    t.equal(color("span { --a: var(--b); --b: var(--c); --c: var(--a); color: var(--a) }"), "0,0,0,255", "three-cycle")
    t.equal(color("span { --x: 1; --c: rgb(var(--r, 10), 20, 30) ; color: var(--c) }"), "10,20,30,255", "var inside a function")
    t.equal(width("span { --w: 10px; width: var(--w) }"), "10/0", "length")
    t.equal(width("span { --w: 10; width: calc(var(--w) * 2px) }"), "20/0", "var inside calc")
    t.equal(width("span { --w: 50%; width: var(--w) }"), "0/50", "percentage")
    t.equal(width("span { --a: 3px; --b: var(--a) var(--a); margin: var(--b); width: 5px }"), "5/0", "multi-value")
    let span = TestEl("span")
    let root = TestEl("html", [TestEl("body", [span])])
    var st = styled(root, span, ["span { --m: 4px 8px; margin: var(--m) }"])
    t.equal(Int(st.marginTop.lp.px) + Int(st.marginLeft.lp.px) * 10, 84, "shorthand with var expands (top 4, left 8)")
    st = styled(root, span, ["span { --b: 2px solid red; border: var(--b) }"])
    t.equal(Int(st.borderTopWidth), 2, "border shorthand from var")
    t.equal(rgba(st.borderTopColor), "255,0,0,255", "border color from var")
    st = styled(root, span, ["span { --a: 1px; } span { --a: 2px !important } span { --a: 3px; width: var(--a) }"])
    t.equal(Int(st.width.lp.px), 2, "important custom property")
    st = styled(root, span, ["html { --x: 7px } body { --x: 9px } span { width: var(--x) }"])
    t.equal(Int(st.width.lp.px), 9, "nearest ancestor wins")
    st = styled(root, span, ["span { --e: ; width: 3px var(--e) }"])
    t.equal(Int(st.width.lp.px), 3, "empty custom property substitutes nothing")
    st = styled(root, span, ["span { --e: 9px; width: 3px var(--e) }"])
    t.check(st.width.kind == .auto, "invalid multi-value width at computed-value time leaves default (auto)")
    // Expansion cap: exponential blow-up must not hang or crash.
    var blow = "span { --a0: x x x x x x x x x x; "
    for i in 1..<12 { blow += "--a\(i): var(--a\(i - 1)) var(--a\(i - 1)) var(--a\(i - 1)) var(--a\(i - 1)) var(--a\(i - 1)) var(--a\(i - 1)) var(--a\(i - 1)) var(--a\(i - 1)) var(--a\(i - 1)) var(--a\(i - 1)); " }
    blow += "width: 4px; color: var(--a11) }"
    st = styled(root, span, [blow])
    t.equal(Int(st.width.lp.px), 4, "billion-laughs var() expansion is capped")
    var chain = "span { --v0: 1px; "
    for i in 1..<400 { chain += "--v\(i): var(--v\(i - 1)); " }
    chain += "width: var(--v399) }"
    st = styled(root, span, [chain])
    t.check(st.width.kind == .auto || st.width.lp.px == 1, "long var chain doesn't crash")
    t.equal(rgba(styled(root, span, ["span { --C: red; color: var(--c, blue) }"]).color), "0,0,255,255", "custom property names are case-sensitive")
}

func testMedia(_ t: Tests) {
    t.section("media")
    var ctx = CSSContext()
    ctx.viewportWidth = 800
    ctx.viewportHeight = 600
    func q(_ s: String) -> Bool { cssParseMediaQueryList(s).matches(ctx) }
    t.check(q(""), "empty list matches")
    t.check(q("all") && q("screen") && !q("print"), "types")
    t.check(q("only screen") && !q("not screen") && q("not print"), "only / not")
    t.check(q("(min-width: 800px)") && !q("(min-width: 801px)"), "min-width")
    t.check(q("(max-width: 800px)") && !q("(max-width: 799px)"), "max-width")
    t.check(q("screen and (min-width: 600px) and (max-width: 900px)"), "and chain")
    t.check(!q("screen and (min-width: 900px)"), "and fails")
    t.check(q("print, screen"), "comma list")
    t.check(q("(min-width: 50em)") && !q("(min-width: 51em)"), "em in media = 16px")
    t.check(q("(min-height: 600px)") && !q("(min-height: 601px)"), "min-height")
    t.check(q("(prefers-color-scheme: light)") && !q("(prefers-color-scheme: dark)"), "prefers-color-scheme")
    t.check(q("(orientation: landscape)") && !q("(orientation: portrait)"), "orientation")
    t.check(q("(width >= 800px)") && !q("(width > 800px)") && q("(400px <= width <= 900px)"), "range syntax")
    t.check(q("(min-width: 100px) or (min-width: 5000px)") && !q("(min-width: 5000px) or (min-width: 6000px)"), "or")
    t.check(q("not (min-width: 5000px)") && !q("not (min-width: 100px)"), "not condition")
    t.check(!q("(unknown-feature: 3)") && !q("tv"), "unknown feature/type is false")
    t.check(q("(hover: hover)") && q("(-webkit-min-device-pixel-ratio: 1)") && !q("(min-resolution: 2dppx)"), "hover and dpr")
    t.check(q("(color)") && q("(min-resolution: 96dpi)"), "boolean color, dpi")
    ctx.printMedia = true
    t.check(q("print") && !q("screen"), "print context")
    ctx.printMedia = false
    ctx.darkColorScheme = true
    t.check(q("(prefers-color-scheme: dark)"), "dark scheme")
}

func testValues(_ t: Tests) {
    t.section("colors")
    func col(_ v: String) -> String {
        let s = cssParseStylesheet("a { color: \(v) }")
        let d = firstDecls(s)
        guard let f = d.first, case .color(let c) = f.value else { return "invalid" }
        switch c {
        case .rgba(let x): return rgba(x)
        case .currentColor: return "current"
        }
    }
    t.equal(col("red"), "255,0,0,255", "named")
    t.equal(col("RebeccaPurple"), "102,51,153,255", "named, mixed case")
    t.equal(col("transparent"), "0,0,0,0", "transparent")
    t.equal(col("currentColor"), "current", "currentColor")
    t.equal(col("#f00"), "255,0,0,255", "#rgb")
    t.equal(col("#f008"), "255,0,0,136", "#rgba")
    t.equal(col("#ff8000"), "255,128,0,255", "#rrggbb")
    t.equal(col("#ff800080"), "255,128,0,128", "#rrggbbaa")
    t.equal(col("#ff"), "invalid", "bad hex length")
    t.equal(col("#gggggg"), "invalid", "bad hex digits")
    t.equal(col("rgb(1, 2, 3)"), "1,2,3,255", "rgb legacy")
    t.equal(col("rgba(1, 2, 3, 0.5)"), "1,2,3,128", "rgba")
    t.equal(col("rgb(1 2 3)"), "1,2,3,255", "rgb space syntax")
    t.equal(col("rgb(1 2 3 / 50%)"), "1,2,3,128", "rgb with slash alpha")
    t.equal(col("rgb(100%, 0%, 50%)"), "255,0,128,255", "rgb percentages")
    t.equal(col("rgb(300, -5, 3)"), "255,0,3,255", "rgb clamps")
    t.equal(col("rgb(1, 2)"), "invalid", "rgb arity")
    t.equal(col("hsl(0, 100%, 50%)"), "255,0,0,255", "hsl red")
    t.equal(col("hsl(120deg 100% 25%)"), "0,128,0,255", "hsl green")
    t.equal(col("hsla(240, 100%, 50%, 0.5)"), "0,0,255,128", "hsla")
    t.equal(col("hsl(0.5turn, 100%, 50%)"), "0,255,255,255", "hsl turn")
    t.equal(col("notacolor"), "invalid", "unknown name")
    var allNamed = 0
    for n in ["aliceblue", "darkslategrey", "lightgoldenrodyellow", "mediumspringgreen", "yellowgreen", "tan", "navy"] where col(n) != "invalid" { allNamed += 1 }
    t.equal(allNamed, 7, "named samples")
    t.equal(col("lightgoldenrodyellow"), "250,250,210,255", "long name value")

    t.section("lengths")
    func len(_ prop: String, _ v: String, fs: Double = 16) -> String {
        let span = TestEl("span")
        let root = TestEl("html", [TestEl("body", [span])])
        let st = styled(root, span, ["html { font-size: \(Int(fs))px } span { \(prop): \(v) }"])
        let d: CSSDimension
        switch prop {
        case "width": d = st.width
        case "margin-left": d = st.marginLeft
        default: d = st.height
        }
        if d.kind == .auto { return "auto" }
        if d.kind == .none { return "none" }
        let lp = d.lp
        return "\(Int((lp.px * 100).rounded()))/\(Int(lp.pct * 100))"
    }
    t.equal(len("width", "10px"), "1000/0", "px")
    t.equal(len("width", "2em"), "3200/0", "em")
    t.equal(len("width", "2rem", fs: 10), "2000/0", "rem")
    t.equal(len("width", "50%"), "0/5000", "percent stays")
    t.equal(len("width", "12pt"), "1600/0", "pt")
    t.equal(len("width", "1pc"), "1600/0", "pc")
    t.equal(len("width", "1in"), "9600/0", "in")
    t.equal(len("width", "2.54cm"), "9600/0", "cm")
    t.equal(len("width", "25.4mm"), "9600/0", "mm")
    t.equal(len("width", "10vw"), "10240/0", "vw (1024 wide)")
    t.equal(len("width", "10vh"), "7680/0", "vh (768 tall)")
    t.equal(len("width", "10vmin"), "7680/0", "vmin")
    t.equal(len("width", "2ex"), "1600/0", "ex ~ 0.5em")
    t.equal(len("width", "auto"), "auto", "auto")
    t.equal(len("width", "0"), "0/0", "unitless zero")
    t.equal(len("width", "5"), "auto", "unitless nonzero invalid")
    t.equal(len("width", "-5px"), "auto", "negative width invalid")
    t.equal(len("margin-left", "-5px"), "-500/0", "negative margin ok")
    t.equal(len("margin-left", "auto"), "auto", "margin auto")
    t.equal(len("width", "calc(100% - 20px)"), "-2000/10000", "calc(100% - 20px)")
    t.equal(len("width", "calc(1em + 2px)"), "1800/0", "calc em+px")
    t.equal(len("width", "calc(2 * (3px + 1px))"), "800/0", "calc nested")
    t.equal(len("width", "calc(100px / 4)"), "2500/0", "calc division")
    t.equal(len("width", "calc(10px * 2 - 50% / 2)"), "2000/-2500", "calc mixed")
    t.equal(len("width", "calc(1px + 2)"), "auto", "calc type error")
    t.equal(len("width", "calc(1px * 2px)"), "auto", "calc length*length invalid")
    t.equal(len("width", "calc(1px+2px)"), "auto", "calc needs spaces around +")
    t.equal(len("width", "calc(100px / 0)"), "auto", "calc division by zero")
    let span = TestEl("span")
    let root = TestEl("html", [TestEl("body", [span])])
    var st = styled(root, span, ["span { width: min(100%, 600px) }"])
    t.check(st.width.lp.pct == 100 && st.width.lp.resolve(1000) == 600 && st.width.lp.resolve(400) == 400, "min(100%, 600px)")
    st = styled(root, span, ["span { width: max(50%, 200px) }"])
    t.check(st.width.lp.resolve(300) == 200 && st.width.lp.resolve(1000) == 500, "max(50%, 200px)")
    st = styled(root, span, ["span { font-size: clamp(10px, 2vw, 30px) }"])
    t.equal(Int(st.fontSize), 20, "clamp() with vw: 2vw of 1024 = 20.48")
    st = styled(root, span, ["span { width: 12.5% ; padding: 1% 2% }"])
    t.check(st.paddingTop.pct == 1 && st.paddingLeft.pct == 2 && st.width.lp.pct == 12.5, "percent values")
}

func testShorthands(_ t: Tests) {
    t.section("shorthands")
    let span = TestEl("span")
    let root = TestEl("html", [TestEl("body", [span])])
    func s(_ css: String) -> CSSComputedStyle { styled(root, span, ["span { \(css) }"]) }
    var st = s("margin: 1px")
    t.check(st.marginTop.lp.px == 1 && st.marginRight.lp.px == 1 && st.marginBottom.lp.px == 1 && st.marginLeft.lp.px == 1, "margin 1 value")
    st = s("margin: 1px 2px")
    t.check(st.marginTop.lp.px == 1 && st.marginRight.lp.px == 2 && st.marginBottom.lp.px == 1 && st.marginLeft.lp.px == 2, "margin 2 values")
    st = s("margin: 1px 2px 3px")
    t.check(st.marginTop.lp.px == 1 && st.marginRight.lp.px == 2 && st.marginBottom.lp.px == 3 && st.marginLeft.lp.px == 2, "margin 3 values")
    st = s("margin: 1px 2px 3px 4px")
    t.check(st.marginTop.lp.px == 1 && st.marginRight.lp.px == 2 && st.marginBottom.lp.px == 3 && st.marginLeft.lp.px == 4, "margin 4 values")
    st = s("margin: 0 auto")
    t.check(st.marginLeft.isAuto && st.marginRight.isAuto && !st.marginTop.isAuto, "margin: 0 auto")
    st = s("margin: 1px 2px 3px 4px 5px")
    t.check(st.marginTop.lp.px == 0, "margin with 5 values is invalid")
    st = s("padding: 1px 2px")
    t.check(st.paddingTop.px == 1 && st.paddingLeft.px == 2, "padding")
    st = s("margin: 5px; margin-top: 9px")
    t.check(st.marginTop.lp.px == 9 && st.marginBottom.lp.px == 5, "longhand after shorthand")
    st = s("margin-top: 9px; margin: 5px")
    t.check(st.marginTop.lp.px == 5, "shorthand after longhand")
    st = s("border: 2px dashed red")
    t.check(st.borderLeftWidth == 2 && st.borderTopStyle == .dashed && rgba(st.borderBottomColor) == "255,0,0,255", "border")
    st = s("border: solid")
    t.check(st.borderTopWidth == 3 && st.borderTopStyle == .solid, "border: solid has medium width")
    st = s("border: none")
    t.check(st.borderTopWidth == 0 && st.borderTopStyle == .none, "border: none")
    st = s("border: 1px solid; border-top: none")
    t.check(st.borderTopWidth == 0 && st.borderBottomWidth == 1, "border-top override")
    st = s("border-width: 1px 2px; border-style: solid; border-color: red green")
    t.check(st.borderTopWidth == 1 && st.borderRightWidth == 2 && rgba(st.borderRightColor) == "0,128,0,255" && rgba(st.borderTopColor) == "255,0,0,255", "border-width/style/color")
    st = s("border: thick solid")
    t.check(st.borderTopWidth == 5, "thick")
    st = s("border: 1px foo red")
    t.check(st.borderTopStyle == .none, "invalid border dropped")
    st = s("background: #fff url(img.png) no-repeat center top")
    t.check(rgba(st.backgroundColor) == "255,255,255,255" && st.backgroundImage == "img.png" && st.backgroundRepeat == .noRepeat, "background shorthand")
    st = s("background-color: red; background: none")
    t.check(st.backgroundColor.a == 0 && st.backgroundImage == nil, "background: none resets")
    st = s("background: url('a b.png')")
    t.check(st.backgroundImage == "a b.png", "background quoted url")
    st = s("background: linear-gradient(red, blue)")
    t.check(st.backgroundImage == nil, "gradient ignored")
    st = s("background-image: url(x.png); background-color: rgba(0,0,0,.5)")
    t.check(st.backgroundImage == "x.png" && st.backgroundColor.a == 128, "background longhands")
    st = s("font: italic bold 12px/1.5 Arial, sans-serif")
    t.check(st.fontStyle == .italic && st.fontWeight == 700 && st.fontSize == 12 && st.lineHeight.kind == .number && st.lineHeight.value == 1.5 && st.fontFamily.count == 2, "font shorthand")
    st = s("font: 14px serif")
    t.check(st.fontSize == 14 && st.fontFamily == ["serif"] && st.lineHeight.kind == .normal, "font minimal")
    st = s("font: 12px")
    t.check(st.fontSize == 16, "font without family invalid")
    st = s("font: 600 1em/20px 'Open Sans'")
    t.check(st.fontWeight == 600 && st.lineHeight.kind == .length && st.lineHeight.value == 20 && st.fontFamily == ["Open Sans"], "font weight number, px line-height")
    st = s("list-style: square inside")
    t.check(st.listStyleType == .square && st.listStylePosition == .inside, "list-style")
    st = s("list-style: none")
    t.check(st.listStyleType == .none, "list-style none")
    st = s("overflow: hidden auto")
    t.check(st.overflowX == .hidden && st.overflowY == .auto, "overflow two values")
    st = s("overflow: scroll")
    t.check(st.overflowX == .scroll && st.overflowY == .scroll, "overflow one value")
    st = s("flex: 1")
    t.check(st.flexGrow == 1 && st.flexShrink == 1 && st.flexBasis.lp.pct == 0 && st.flexBasis.isLength, "flex: 1 -> 1 1 0%")
    st = s("flex: 2 3 10px")
    t.check(st.flexGrow == 2 && st.flexShrink == 3 && st.flexBasis.lp.px == 10, "flex: 2 3 10px")
    st = s("flex: none")
    t.check(st.flexGrow == 0 && st.flexShrink == 0 && st.flexBasis.isAuto, "flex: none")
    st = s("flex: auto")
    t.check(st.flexGrow == 1 && st.flexShrink == 1 && st.flexBasis.isAuto, "flex: auto")
    st = s("flex: 1 1 auto")
    t.check(st.flexGrow == 1 && st.flexBasis.isAuto, "flex: 1 1 auto")
    st = s("flex-flow: column wrap")
    t.check(st.flexDirection == .column && st.flexWrap == .wrap, "flex-flow")
    st = s("gap: 4px 8px")
    t.check(st.rowGap.px == 4 && st.columnGap.px == 8, "gap")
    st = s("gap: 6px")
    t.check(st.rowGap.px == 6 && st.columnGap.px == 6, "gap one value")
    st = s("border-spacing: 3px 5px")
    t.check(st.borderSpacingH == 3 && st.borderSpacingV == 5, "border-spacing")
    st = s("border-collapse: collapse; table-layout: fixed")
    t.check(st.borderCollapse == .collapse && st.tableLayout == .fixed, "table props")
    st = s("text-decoration: underline line-through")
    t.check(st.textDecoration.hasUnderline && st.textDecoration.hasLineThrough && !st.textDecoration.hasOverline, "text-decoration")
    st = s("text-decoration: underline red wavy")
    t.check(st.textDecoration.hasUnderline, "text-decoration ignores color/style")
    st = s("text-decoration: none")
    t.check(st.textDecoration == .none, "text-decoration none")
    st = s("inset: 1px 2px 3px 4px; position: absolute")
    t.check(st.top.lp.px == 1 && st.right.lp.px == 2 && st.bottom.lp.px == 3 && st.left.lp.px == 4, "inset")
    st = s("margin-inline: auto; padding-block: 3px")
    t.check(st.marginLeft.isAuto && st.marginRight.isAuto && st.paddingTop.px == 3, "logical shorthands")
    st = s("display: inline-flex; justify-content: space-between; align-items: center; align-self: flex-end")
    t.check(st.display == .inlineFlex && st.justifyContent == .spaceBetween && st.alignItems == .center && st.alignSelf == .flexEnd, "flex keywords")
    st = s("position: absolute; top: 1px; left: 50%; z-index: 7; float: right; clear: both")
    t.check(st.position == .absolute && st.zIndex == 7 && st.left.lp.pct == 50 && st.clear == .both, "positioning")
    st = s("z-index: auto")
    t.check(st.zIndex == nil, "z-index auto")
    st = s("opacity: 0.5")
    t.check(st.opacity == 0.5, "opacity")
    st = s("opacity: 150%")
    t.check(st.opacity == 1, "opacity clamps")
    st = s("box-sizing: border-box; white-space: pre-wrap; text-align: center; text-transform: uppercase; text-indent: 2em")
    t.check(st.boxSizing == .borderBox && st.whiteSpace == .preWrap && st.textAlign == .center && st.textTransform == .uppercase && st.textIndent.px == 32, "misc text/box")
    st = s("vertical-align: middle")
    t.check(st.verticalAlign.kind == .middle, "vertical-align keyword")
    st = s("vertical-align: 5px")
    t.check(st.verticalAlign.kind == .length && st.verticalAlign.lengthPx == 5, "vertical-align length")
    st = s("visibility: hidden; cursor: pointer; max-width: none; min-height: 10px; max-height: 50%")
    t.check(st.visibility == .hidden && st.cursor == "pointer" && st.maxWidth.kind == .none && st.minHeight.lp.px == 10 && st.maxHeight.lp.pct == 50, "visibility, cursor, min/max")
    st = s("unknown-prop: 1; -webkit-foo: bar; color: red")
    t.check(rgba(st.color) == "255,0,0,255", "unknown properties ignored")
    st = s("-webkit-box-sizing: border-box")
    t.check(st.boxSizing == .borderBox, "-webkit-box-sizing alias")
    st = s("COLOR: Red; Display: BLOCK")
    t.check(rgba(st.color) == "255,0,0,255" && st.display == .block, "case-insensitive names and keywords")
}

func testUserAgent(_ t: Tests) {
    t.section("user agent sheet")
    let a = TestEl("a", attrs: ["href": "x"])
    a.link = true
    let li = TestEl("li")
    let ul = TestEl("ul", [li])
    let ul2 = TestEl("ul", [TestEl("li")])
    ul.append(ul2)
    let h1 = TestEl("h1")
    let b = TestEl("b")
    let table = TestEl("table", [TestEl("tbody", [TestEl("tr", [TestEl("td")])])])
    let hidden = TestEl("div", attrs: ["hidden": ""])
    let body = TestEl("body", [h1, a, ul, b, table, hidden, TestEl("script"), TestEl("p"), TestEl("pre"), TestEl("code")])
    let html = TestEl("html", [TestEl("head", [TestEl("title")]), body])
    let r = CSSStyleResolver(ctx: CSSContext())
    styleTree(html, r, nil)
    t.check(html.style.display == .block && body.style.display == .block, "html/body block")
    t.equal(Int(body.style.marginLeft.lp.px), 8, "body margin 8px")
    t.check(html.children[0].style.display == .none && html.children[0].children[0].style.display == .none, "head/title hidden")
    t.check(body.children[6].style.display == .none, "script hidden")
    t.check(hidden.style.display == .none, "[hidden]")
    t.check(h1.style.fontWeight == 700 && Int(h1.style.fontSize) == 32 && Int(h1.style.marginTop.lp.px) == 21, "h1: bold 2em, margin .67em")
    t.check(rgba(a.style.color) == "0,0,238,255" && a.style.textDecoration.hasUnderline, "a:link blue underline")
    t.check(li.style.display == .listItem && ul.style.listStyleType == .disc && ul2.style.listStyleType == .circle, "lists; nested ul circle")
    t.check(Int(ul.style.paddingLeft.px) == 40 && Int(ul.style.marginTop.lp.px) == 16 && Int(ul2.style.marginTop.lp.px) == 0, "ul padding/margins, nested margin 0")
    t.check(b.style.fontWeight == 700, "b bolder")
    t.check(table.style.display == .table && table.children[0].style.display == .tableRowGroup && table.children[0].children[0].children[0].style.display == .tableCell, "table display types")
    t.check(Int(table.style.borderSpacingH) == 2 && Int(table.children[0].children[0].children[0].style.paddingLeft.px) == 1, "table spacing and cell padding")
    t.check(body.children[8].style.whiteSpace == .pre && body.children[9].style.fontFamily == ["monospace"], "pre, code")
    t.check(Int(body.children[7].style.marginTop.lp.px) == 16, "p margin 1em")
    let uaSheet = cssUserAgentStyleSheet()
    t.check(ruleCount(uaSheet) > 60, "UA sheet parsed fully (\(ruleCount(uaSheet)) rules)")
}

func testPseudoElements(_ t: Tests) {
    t.section("pseudo-elements")
    let span = TestEl("span", cls: "x", attrs: ["title": "Hi"])
    let root = TestEl("html", [TestEl("body", [span])])
    let r = makeResolver([
        ".x::before { color: red } .x:after { content: \"]\" } .x::after { color: blue }",
        "span::before { content: attr(title) \"!\" } p::before { content: none } .x::first-line { color: green }",
        "span { color: black }",
    ], ua: false)
    styleTree(root, r, nil)
    t.equal(rgba(span.style.color), "0,0,0,255", "element style unaffected by pseudo rules")
    let b = r.computePseudoStyle(span, .before, elementStyle: span.style)
    let a = r.computePseudoStyle(span, .after, elementStyle: span.style)
    t.check(b != nil && a != nil, "before and after exist")
    t.equal(b?.contentItems.joined(separator: "|") ?? "nil", "Hi|!", "attr() and string content (later rule wins)")
    t.equal(rgba(b?.color ?? CSSColor.white), "255,0,0,255", "::before color")
    t.equal(a?.contentItems.joined(separator: "|") ?? "nil", "]", ":after single-colon legacy form")
    t.equal(rgba(a?.color ?? CSSColor.white), "0,0,255,255", "::after color")
    let p = TestEl("p")
    root.children[0].append(p)
    styleTree(root, r, nil)
    t.check(r.computePseudoStyle(p, .before, elementStyle: p.style) == nil, "content: none -> no pseudo box")
    t.check(r.computePseudoStyle(p, .after, elementStyle: p.style) == nil, "no rule -> no pseudo box")
    t.check(cssParseSelectorList("a::before")?.first?.pseudoElement == .before && cssParseSelectorList("a:after")?.first?.pseudoElement == .after, "pseudo-element parsing")
}

func testFuzz(_ t: Tests) {
    t.section("fuzz")
    let seeds: [[UInt8]] = [
        Array("a { color: red; margin: 1px 2px } .b > c:not(.d)::before { content: \"x\" } @media (min-width: 5px) { e { top: 0 } }".utf8),
        Array("@import url(x.css) screen; @font-face { src: url(a) } p:nth-child(2n+1) { background: #fff url(i.png) no-repeat; font: 12px/1.5 Arial } :root { --a: var(--b, calc(1px + 2%)) }".utf8),
        Array("@supports (display: grid) and (not (x: y)) { a[href^='http' i] { width: calc(100% - 2em); color: rgba(0 0 0 / 50%) } } /* c */ <!-- --> \\66 oo { }".utf8),
        Array("a { width: min(1px, 2%) ; flex: 1 1 0; border: 1px solid hsl(120deg 50% 50%) !important } li + li ~ b { x: y }".utf8),
    ]
    let el = TestEl("a", id: "i", cls: "b d", attrs: ["href": "http://x", "style": "color: red"])
    let root = TestEl("html", [TestEl("body", [TestEl("li"), TestEl("li", [TestEl("b"), el])])])
    t.fuzz("css-parse", seeds: seeds, iterations: 6000) { data in
        let sheet = cssParseStylesheet(data)
        let r = CSSStyleResolver(ctx: CSSContext(), noUserAgent: true)
        r.addStyleSheet(sheet)
        styleTree(root, r, nil)
        _ = r.computePseudoStyle(el, .before, elementStyle: el.style)
    }
    t.fuzz("css-selector", seeds: [Array("a.b#c[d=e]:not(.f):nth-child(2n+1) > g ~ h + i::before".utf8)], iterations: 4000) { data in
        _ = cssParseSelectorList(cssTokenize(data))
        _ = cssParseMediaQueryList(String(decoding: data, as: UTF8.self))
        _ = cssParseInlineStyle(String(decoding: data, as: UTF8.self))
    }
}

func testPerformance(_ t: Tests) {
    t.section("performance")
    // A few thousand rules over a few thousand elements.
    var css = ""
    let tags = ["div", "span", "p", "a", "li", "ul", "h2", "td"]
    for i in 0..<3000 {
        switch i % 6 {
        case 0: css += ".c\(i % 400) { color: #\(i % 10)\(i % 7)\(i % 5)abc; margin: \(i % 9)px }\n"
        case 1: css += "#id\(i) { padding: \(i % 5)px }\n"
        case 2: css += "\(tags[i % 8]).c\(i % 300) > \(tags[(i + 3) % 8]) { width: \(i % 100)px }\n"
        case 3: css += "\(tags[i % 8]) { font-size: \(10 + i % 5)px }\n"
        case 4: css += ".c\(i % 200) .c\(i % 150):first-child { border: 1px solid red }\n"
        default: css += "[data-k=\"v\(i % 50)\"], .c\(i % 120) + .c\(i % 77) { height: \(i % 40)px; background-color: rgb(\(i % 256), 1, 2) }\n"
        }
    }
    let sheet = cssParseStylesheet(css)
    var rng = TestRandom(seed: 42)
    let root = TestEl("html")
    var all: [TestEl] = [root]
    var count = 1
    func build(_ parent: TestEl, _ depth: Int) {
        let kids = 2 + rng.below(4)
        for _ in 0..<kids {
            if count >= 4000 { return }
            let e = TestEl(tags[rng.below(8)], id: rng.below(4) == 0 ? "id\(rng.below(3000))" : "", cls: "c\(rng.below(400)) c\(rng.below(300))", attrs: rng.below(5) == 0 ? ["data-k": "v\(rng.below(50))"] : [:])
            count += 1
            all.append(e)
            parent.append(e)
            if depth < 9 { build(e, depth + 1) }
        }
    }
    while count < 4000 { let n = all[rng.below(all.count)]; build(n, 6) }
    let t0 = hostMillis()
    let resolver = CSSStyleResolver(ctx: CSSContext())
    resolver.addStyleSheet(sheet)
    let t1 = hostMillis()
    styleTree(root, resolver, nil)
    let t2 = hostMillis()
    print("perf: \(ruleCount(sheet)) rules, \(resolver.ruleSet.selectorCount) selectors, \(all.count) elements: build index \(t1 - t0) ms, cascade \(t2 - t1) ms (parse of \(css.utf8.count / 1024) KB included in tests below)")
    let p0 = hostMillis()
    _ = cssParseStylesheet(css)
    print("perf: parse \(css.utf8.count / 1024) KB in \(hostMillis() - p0) ms")
    t.check(t2 - t1 < 5000, "cascade over 3000 rules x 4000 elements finishes in reasonable time")
    t.check(root.style.fontSize > 0, "styled")
}
