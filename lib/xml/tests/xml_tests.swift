// Host tests for lib/xml.

private func dump(_ n: XMLNode, _ out: inout String) {
    if n.kind == .text { out += "\"" + String(decoding: n.text, as: UTF8.self) + "\""; return }
    out += "<" + n.localName
    if !n.namespace.isEmpty && n.namespace != xmlNamespaceSVG { out += "{" + n.namespace + "}" }
    for a in n.attributes { out += " " + a.name + "=" + a.value }
    out += ">"
    for c in n.children { dump(c, &out) }
    out += "</>"
}

private func parsed(_ s: String) -> String {
    let d = xmlParse(s)
    var out = ""
    if let r = d.root { dump(r, &out) }
    return out
}

func libTests(_ t: Tests) {
    t.section("basics")
    t.equal(parsed("<svg xmlns='http://www.w3.org/2000/svg'><g id=\"a\"/>hi</svg>"),
            "<svg xmlns=http://www.w3.org/2000/svg><g id=a></>\"hi\"</>", "simple")
    let d = xmlParse("<?xml version=\"1.0\"?>\n<!DOCTYPE svg PUBLIC \"-//W3C//DTD SVG 1.1//EN\" \"x\">\n<!-- c --><svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\"><use xlink:href=\"#a\"/></svg>")
    t.check(d.wellFormed, "prolog well-formed")
    t.equal(d.root?.localName ?? "", "svg", "root name")
    t.equal(d.root?.namespace ?? "", xmlNamespaceSVG, "svg ns")
    let use = d.root?.children.first
    t.equal(use?.attribute(namespace: xmlNamespaceXLink, "href") ?? "", "#a", "xlink:href by ns")
    t.equal(use?.namespace ?? "", xmlNamespaceSVG, "default ns inherited")

    t.section("entities")
    t.equal(parsed("<a b='&lt;&amp;&#65;&#x42;&quot;'>&gt;&apos;&#x1F600;&bogus;&#0;</a>"),
            "<a b=<&AB\">\">'\u{1F600}&bogus;\u{FFFD}\"</>", "refs")
    t.equal(parsed("<a b='x\ny\tz'/>"), "<a b=x y z></>", "attr whitespace normalized")
    t.equal(parsed("<a><![CDATA[<x>&amp;]]></a>"), "<a>\"<x>&amp;\"</>", "cdata")

    t.section("no custom entities")
    let bomb = """
    <?xml version="1.0"?>
    <!DOCTYPE lolz [
     <!ENTITY lol "lol">
     <!ENTITY lol2 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">
     <!ENTITY lol3 "&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;">
    ]>
    <lolz>&lol3;</lolz>
    """
    t.equal(parsed(bomb), "<lolz>\"&lol3;\"</>", "billion laughs is inert")
    t.equal(parsed("<!DOCTYPE x [ <!ENTITY a \"]>\"> ]><r/>"), "<r></>", "quoted ] in subset")

    t.section("recovery")
    let r1 = xmlParse("<a><b><c></a>")
    t.check(!r1.wellFormed, "mismatch flagged")
    t.equal(parsed("<a><b><c></a>"), "<a><b><c></></></>", "close to match")
    t.equal(parsed("<a></x>t</a>"), "<a>\"t\"</>", "stray end tag")
    t.equal(parsed("<a x=1 y>"), "<a x=1 y=></>", "unquoted and bare attrs")
    t.equal(parsed("<a/><b/>"), "<a></>", "second root ignored")
    t.equal(parsed("<a x='1' x='2'/>"), "<a x=1></>", "duplicate attr")
    t.equal(parsed("\u{FEFF}<a/>"), "<a></>", "bom")

    t.section("limits")
    var deep = ""
    for _ in 0..<1000 { deep += "<g>" }
    var lim = XMLLimits()
    lim.maxDepth = 64
    let dd = xmlParse(deep, limits: lim)
    t.check(dd.truncated, "depth limit truncates")
    var depth = 0
    var n = dd.root
    while let x = n { depth += 1; n = x.children.first }
    t.check(depth <= 64, "depth capped", "\(depth)")
    var many = "<r>"
    for _ in 0..<5000 { many += "<p/>" }
    many += "</r>"
    lim = XMLLimits(); lim.maxNodes = 1000
    let md = xmlParse(many, limits: lim)
    t.check(md.truncated && md.nodeCount <= 1000, "node limit")
    lim = XMLLimits(); lim.maxInputBytes = 10
    t.check(xmlParse(many, limits: lim).truncated, "input limit")

    t.section("fuzz")
    let seeds: [[UInt8]] = [
        Array("<?xml version='1.0'?><!DOCTYPE s [<!ENTITY x 'y'>]><svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 10 10'><path d='M0 0L10 10z' fill='&#x23;f00'/><![CDATA[x]]><!--c--></svg>".utf8),
        Array("<a:b xmlns:a='u'><a:c a:d='1'>t&amp;&lt;</a:c></a:b>".utf8),
        Array(bomb.utf8),
    ]
    t.fuzz("xml", seeds: seeds, iterations: 20000) { m in
        let d = xmlParse(m)
        if let r = d.root { _ = r.textContent }
    }
}
