// Scoped styles (CSS Scoping, Phase 9I): a tiny element model with tree
// scopes, hosts, slots and parts, and the cascade's shadow-tree context step.

final class ShEl: CSSElement {
    var tag: String
    var idAttr = ""
    var classList: [String] = []
    var attrs: [String: String] = [:]
    var children: [ShEl] = []
    var parent: ShEl? = nil
    /// Tree scope (set by ShTree.finish).
    var scope = CSSTreeScope()
    /// Top-level shadow elements: the host.
    var host: ShEl? = nil
    var shadowScope: Int? = nil
    var slot: ShEl? = nil
    var defined = true
    var style = CSSComputedStyle()

    init(_ tag: String, id: String = "", cls: String = "", attrs: [String: String] = [:], _ kids: [ShEl] = []) {
        self.tag = tag
        idAttr = id
        for w in cls.split(separator: " ") { classList.append(String(w)) }
        self.attrs = attrs
        for k in kids { k.parent = self; children.append(k) }
    }

    var cssTagName: String { tag }
    var cssID: String { idAttr }
    var cssClasses: [String] { classList }
    func cssAttribute(_ name: String) -> String? {
        if name == "id" && !idAttr.isEmpty { return idAttr }
        return attrs[name]
    }
    var cssParent: ShEl? { parent }
    var cssPreviousElementSibling: ShEl? {
        guard let p = parent, let i = p.children.firstIndex(where: { $0 === self }), i > 0 else { return nil }
        return p.children[i - 1]
    }
    var cssNextElementSibling: ShEl? {
        guard let p = parent, let i = p.children.firstIndex(where: { $0 === self }), i + 1 < p.children.count else { return nil }
        return p.children[i + 1]
    }
    var cssIsRoot: Bool { parent == nil && host == nil && scope.id == 0 }
    var cssTreeScope: CSSTreeScope { scope }
    var cssShadowHost: ShEl? {
        var n = self
        while let p = n.parent { n = p }
        return n.host
    }
    var cssShadowRootScope: Int? { shadowScope }
    var cssAssignedSlot: ShEl? { slot }
    var cssPartNames: [String] { (attrs["part"] ?? "").split(separator: " ").map { String($0) } }
    var cssExportParts: [(String, String)] { cssParseExportParts(attrs["exportparts"] ?? "") }
    var cssIsDefined: Bool { defined }
}

/// Attach `kids` as the shadow tree of `host` with scope id `id`.
private func shAttach(_ host: ShEl, id: Int, _ kids: [ShEl]) {
    host.shadowScope = id
    let depth = host.scope.depth + 1
    var stack: [ShEl] = []
    for k in kids { k.host = host; stack.append(k) }
    while let n = stack.popLast() {
        n.scope = CSSTreeScope(id: id, depth: depth)
        stack.append(contentsOf: n.children)
    }
}

/// Style in flat-tree order: `order` lists (element, flat parent).
private func shStyle(_ r: CSSStyleResolver, _ order: [(ShEl, ShEl?)]) {
    for (e, p) in order { e.style = r.computeStyle(e, parent: p?.style) }
}

private func shColor(_ e: ShEl) -> String { "\(e.style.color.r),\(e.style.color.g),\(e.style.color.b)" }

func cssShadowTests(_ t: Tests) {
    t.section("scoped styles")

    // Selector parsing.
    do {
        func spec(_ s: String) -> UInt32 { cssParseSelectorList(s)?.first?.specificity ?? 9999 }
        t.equal(Int(spec(":host")), 1 << 10, ":host specificity")
        t.equal(Int(spec(":host(.a)")), 2 << 10, ":host(.a) specificity")
        t.equal(Int(spec("::slotted(p)")), 2, "::slotted(p) specificity")
        t.equal(Int(spec("::slotted(.x)")), (1 << 10) + 1, "::slotted(.x) specificity")
        t.equal(Int(spec("x-a::part(foo)")), 2, "::part specificity")
        t.check(cssParseSelectorList("::slotted(a b)") == nil, "::slotted takes one compound")
        t.check(cssParseSelectorList(":host(a > b)") == nil, ":host() takes one compound")
        t.check(cssParseSelectorList("::part()") == nil, "::part() needs a name")
        t.check(cssParseSelectorList("::slotted(p) span") == nil, "nothing after ::slotted")
        t.check(cssParseSelectorList(":is(::slotted(p))") == nil, "no ::slotted inside :is")
        t.check(cssParseSelectorList("::part(a b)")?.first?.parts ?? [] == ["a", "b"], "::part names")
        t.check(cssParseSelectorList(":host-context(.x)") != nil, ":host-context parses (never matches)")
        t.equal(cssParseExportParts("a, b : c, bad:, d:e:f").map { $0.0 + ">" + $0.1 }.joined(separator: " "), "a>a b>c", "exportparts parsing")
    }

    // doc: html > body > div#h.dark (host, scope 1) [light: p#light, b#unslotted]
    // shadow 1: style-less div.inner(part=label) > slot#s ; x-in#h2 (exportparts "x:y", host of scope 2)
    // shadow 2: span#sp (part="x z")
    let light = ShEl("p", id: "light")
    let unslotted = ShEl("b", id: "unslotted", attrs: ["slot": "nope"])
    let h = ShEl("div", id: "h", cls: "dark", [light, unslotted])
    let body = ShEl("body", [h, ShEl("div", id: "plain")])
    let html = ShEl("html", [body])
    let s = ShEl("slot", id: "s")
    let inner = ShEl("div", cls: "inner", attrs: ["part": "label"], [s])
    let sp = ShEl("span", id: "sp", attrs: ["part": "x z"])
    let h2 = ShEl("x-in", id: "h2", attrs: ["exportparts": "x:y"])
    shAttach(h, id: 1, [inner, h2])
    shAttach(h2, id: 2, [sp])
    light.slot = s
    let plain = body.children[1]
    // Flat tree order: html, body, h, inner, s, light, h2, sp, plain.
    let order: [(ShEl, ShEl?)] = [(html, nil), (body, html), (h, body), (inner, h), (s, inner), (light, s), (h2, h), (sp, h2),
                                  (unslotted, h), (plain, body)]

    func run(doc: String, shadow: String = "", shadow2: String = "") {
        let r = makeResolver([doc])
        if !shadow.isEmpty { r.setScopeSheets(1, [cssParseStylesheet(shadow)]) }
        if !shadow2.isEmpty { r.setScopeSheets(2, [cssParseStylesheet(shadow2)]) }
        shStyle(r, order)
    }

    run(doc: "div { color: rgb(255,0,0) } span { color: rgb(1,1,1) }", shadow: "div { color: rgb(0,0,255) }")
    t.equal(shColor(plain), "255,0,0", "document rule applies in the document")
    t.equal(shColor(inner), "0,0,255", "shadow rule applies in its tree")
    t.equal(shColor(h), "255,0,0", "shadow `div` doesn't match the (featureless) host")
    t.equal(shColor(sp), "255,0,0", "document `span` does not reach a shadow tree; color inherits through the flat tree")

    run(doc: "#h { color: rgb(255,0,0) }", shadow: ":host { color: rgb(0,128,0); background-color: rgb(0,0,9) } .dark { color: rgb(9,9,9) }")
    t.equal(shColor(h), "255,0,0", "outer normal rule beats :host (context step)")
    t.equal(Int(h.style.backgroundColor.b), 9, ":host applies where the outer tree is silent")
    run(doc: "#h { color: rgb(255,0,0) }", shadow: ":host { color: rgb(0,128,0) !important }")
    t.equal(shColor(h), "0,128,0", ":host !important beats outer normal")
    run(doc: "#h { color: rgb(255,0,0) !important }", shadow: ":host { color: rgb(0,128,0) !important }")
    t.equal(shColor(h), "0,128,0", "inner !important beats outer !important")
    h.attrs["style"] = "color: rgb(7,7,7)"
    run(doc: "", shadow: ":host { color: rgb(0,128,0) }")
    t.equal(shColor(h), "7,7,7", "host style attribute beats :host")
    h.attrs["style"] = "color: rgb(7,7,7) !important"
    run(doc: "", shadow: ":host { color: rgb(0,128,0) !important }")
    t.equal(shColor(h), "0,128,0", "inner !important beats the host's style attribute !important")
    h.attrs["style"] = nil

    run(doc: "", shadow: ":host(.dark) .inner { color: rgb(1,2,3) } :host(.light) .inner { background-color: rgb(1,1,1) } :host > div { border-top-width: 3px; border-top-style: solid }")
    t.equal(shColor(inner), "1,2,3", ":host(.dark) as an ancestor")
    t.check(inner.style.backgroundColor.a == 0, ":host(.light) doesn't match")
    t.equal(Int(inner.style.borderTopWidth), 3, ":host > div")
    run(doc: "", shadow: "div :host { color: rgb(1,1,1) } :host:hover { color: rgb(2,2,2) } :host.dark { color: rgb(3,3,3) }")
    t.equal(shColor(h), "0,0,0", ":host has no ancestors in its shadow tree; :host.dark never matches")

    run(doc: "p { color: rgb(255,0,0) }", shadow: "::slotted(p) { color: rgb(0,0,255); background-color: rgb(0,0,5) } #s::slotted(*) { border-top-width: 2px; border-top-style: solid } ::slotted(b) { color: rgb(9,9,9) }")
    t.equal(shColor(light), "255,0,0", "the light tree's own rule beats ::slotted")
    t.equal(Int(light.style.backgroundColor.b), 5, "::slotted(p) applies")
    t.equal(Int(light.style.borderTopWidth), 2, "#s::slotted(*)")
    t.check(unslotted.style.color.r != 9, "::slotted doesn't reach an unassigned child")
    run(doc: "", shadow: "::slotted(p) { color: rgb(0,0,255) }")
    t.equal(shColor(light), "0,0,255", "::slotted without competition")

    run(doc: "::part(label) { color: rgb(0,9,0) } #h::part(label) { background-color: rgb(0,0,7) } #plain::part(label) { border-top-width: 4px; border-top-style: solid } ::part(y) { color: rgb(0,0,8) } ::part(x) { background-color: rgb(1,0,0) }",
        shadow: ".inner { color: rgb(255,0,0) }")
    t.equal(shColor(inner), "0,9,0", "::part from outside beats the shadow tree's own rule (outer context)")
    t.equal(Int(inner.style.backgroundColor.b), 7, "#h::part(label)")
    t.equal(Int(inner.style.borderTopWidth), 0, "::part checks the host")
    t.equal(shColor(sp), "0,0,8", "exportparts renames x to y for the outer tree")
    t.check(sp.style.backgroundColor.r != 1, "unexported name doesn't reach the document")
    run(doc: "", shadow: "x-in::part(x) { color: rgb(0,0,3) } x-in::part(x z) { background-color: rgb(0,0,4) } x-in::part(x q) { border-top-width: 4px; border-top-style: solid }")
    t.equal(shColor(sp), "0,0,3", "::part from the enclosing shadow tree")
    t.equal(Int(sp.style.backgroundColor.b), 4, "::part(x z) needs both names")
    t.equal(Int(sp.style.borderTopWidth), 0, "missing name: no match")

    // Custom properties follow the flat tree.
    run(doc: "#h { --accent: rgb(4,5,6) }", shadow: ".inner { color: var(--accent) }")
    t.equal(shColor(inner), "4,5,6", "custom property from the host reaches the shadow tree")

    // :defined
    let ce = ShEl("my-el")
    ce.defined = false
    let wrap = ShEl("div", [ce])
    let r = makeResolver([":not(:defined) { display: none } :defined { color: rgb(1,1,1) }"])
    wrap.style = r.computeStyle(wrap, parent: nil)
    ce.style = r.computeStyle(ce, parent: wrap.style)
    t.check(ce.style.display == .none && wrap.style.color.r == 1, ":defined / :not(:defined)")
}
