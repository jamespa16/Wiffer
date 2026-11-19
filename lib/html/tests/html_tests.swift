func htmlMaxDepth(_ doc: HTMLNode) -> Int {
    var best = 0
    var stack: [(HTMLNode, Int)] = [(doc, 0)]
    while let (n, d) = stack.popLast() {
        if d > best { best = d }
        for c in n.children { stack.append((c, d + 1)) }
    }
    return best
}

func htmlCountNodes(_ doc: HTMLNode) -> Int {
    var n = 0
    doc.walk { _ in n += 1; return true }
    return n
}

func htmlRepeat(_ s: String, _ n: Int) -> [UInt8] {
    var out: [UInt8] = []
    let b = Array(s.utf8)
    out.reserveCapacity(b.count * n)
    for _ in 0..<n { out.append(contentsOf: b) }
    return out
}

func libTests(_ t: Tests) {
    t.section("smoke")
    let d = htmlParse("<!DOCTYPE html><p>Hi &amp; bye<b>x</p>")
    t.equal(htmlTreeDump(d), "| <!DOCTYPE html>\n| <html>\n|   <head>\n|   <body>\n|     <p>\n|       \"Hi & bye\"\n|       <b>\n|         \"x\"\n", "smoke dump")

    t.section("entities")
    var found = 0
    var o = 0
    let recs = htmlEntityRecords.utf8Start
    for _ in 0..<htmlEntityCount {
        let len = Int(recs[o]) - 0x30
        var name: [UInt8] = []
        for k in 0..<len { name.append(recs[o + 1 + k]) }
        if htmlEntityFind(name, len) != nil { found += 1 }
        o += 1 + len + 4
    }
    t.equal(found, htmlEntityCount, "every table entry is found by binary search")
    t.equal(htmlEntityCount, 2231, "entity count")
    func text(_ s: String) -> String { htmlParse(s).body?.textContent ?? "?" }
    t.equal(text("&amp;&lt;&gt;&quot;&nbsp;"), "&<>\"\u{a0}", "basic entities")
    t.equal(text("&ampx &notit; &not;"), "&x \u{ac}it; \u{ac}", "legacy no-semicolon and longest match")
    t.equal(text("&NotEqualTilde;"), "\u{2242}\u{338}", "two code points")
    t.equal(text("&#65;&#x42;&#X43;&#0;&#x110000;&#xD800;&#128;&#x81;"), "ABC\u{fffd}\u{fffd}\u{fffd}\u{20ac}\u{81}", "numeric references")
    t.equal(text("&#;&#x;&bogus;&"), "&#;&#x;&bogus;&", "invalid references stay literal")
    let a = htmlParse("<a title=\"&ampx=1 &amp=2 &amp;\" href='?a=1&copy=2&copy;'>")
    t.equal(a.getElementsByTagName("a").first?.attribute("title") ?? "", "&ampx=1 &amp=2 &", "attribute legacy rule")
    t.equal(a.getElementsByTagName("a").first?.attribute("href") ?? "", "?a=1&copy=2\u{a9}", "attribute href")

    t.section("input")
    t.equal(text("a\r\nb\rc"), "a\nb\nc", "CRLF normalization")
    t.equal(Array(htmlParse([0x61, 0xff, 0xc3, 0x28, 0xe2, 0x82, 0x61]).body?.textContent.utf8 ?? "".utf8),
            [0x61, 0xef, 0xbf, 0xbd, 0xef, 0xbf, 0xbd, 0x28, 0xef, 0xbf, 0xbd, 0x61], "invalid UTF-8")
    t.equal(text("a\u{0}b"), "ab", "NUL in body ignored")

    t.section("DOM")
    let doc = htmlParse("<!DOCTYPE html><html><body><div id=a class='x  y'><p class=y>1<p id=b>2</div><span class=x>3</span>")
    t.check(doc.getElementById("b")?.name == "p", "getElementById")
    t.equal(doc.getElementsByClassName("y").count, 2, "by class")
    t.equal(doc.getElementsByTagName("p").count, 2, "by tag")
    t.equal(doc.getElementById("a")?.classNames.count ?? 0, 2, "classNames")
    t.equal(doc.body?.textContent ?? "", "123", "textContent")
    t.check(doc.getElementById("b")?.previousSibling?.name == "p", "previousSibling")
    t.check(doc.getElementById("a")?.nextSibling?.name == "span", "nextSibling")
    t.check(doc.getElementById("b")?.parentElement?.name == "div", "parentElement")
    t.check(doc.head != nil && doc.documentElement?.name == "html", "head/documentElement")
    doc.teardown()
    t.equal(doc.children.count, 0, "teardown")

    t.section("limits")
    let deep = htmlRepeat("<div>", 200_000)
    let dd = htmlParse(deep)
    t.check(htmlMaxDepth(dd) <= 520, "depth capped: \(htmlMaxDepth(dd))")
    let dd2 = htmlParse(htmlRepeat("<b><i><table><tr><td>", 50_000))
    t.check(htmlMaxDepth(dd2) <= 530, "depth capped (formatting/tables): \(htmlMaxDepth(dd2))")
    let big = htmlParse(htmlRepeat("<p>x", 50_000), limits: HTMLParseLimits(maxInputBytes: 1 << 20, maxNodes: 1000, maxDepth: 64))
    t.check(big.truncated && htmlCountNodes(big) <= 1010, "node limit")
    let cut = htmlParse(htmlRepeat("a", 5000), limits: HTMLParseLimits(maxInputBytes: 100, maxNodes: 1000, maxDepth: 64))
    t.check(cut.truncated && (cut.body?.textContent.utf8.count ?? 0) == 100, "byte budget")
    let nested = htmlParse(htmlRepeat("<b>", 100_000) + htmlRepeat("<p>", 1000))
    t.check(htmlMaxDepth(nested) <= 530, "unclosed formatting")
    _ = htmlParse(htmlRepeat("<a href=x><a>", 50_000))
    _ = htmlParse(htmlRepeat("<svg><g><foreignObject><div>", 20_000))
    _ = htmlParse(htmlRepeat("<!--", 100_000))
    _ = htmlParse(htmlRepeat("<x a=1 a=2 b", 100_000))

    html5libTests(t)
    htmlDOMTests(t)

    t.section("fuzz")
    var seeds: [[UInt8]] = [
        Array("<!DOCTYPE html><html><head><title>t</title><style>p{}</style></head><body><table><tr><td><b>x<i>y</b>z</table><svg><foreignObject><p>q</svg><select><option>a<option>b</select><!-- c --><script><!--<script></script>".utf8),
        Array("<p>&amp;&#x41;&notit;<a href='x'>l<a>m</a><ul><li>1<li>2</ul><frameset><frame></frameset>".utf8),
        Array("<math><mi><b></b></mi><annotation-xml encoding='text/html'><p></annotation-xml></math><![CDATA[x]]><?pi?></x>".utf8),
    ]
    if let w = t.readFileIfPresent("lib/html/fixtures/wikipedia-html.html") { seeds.append(Array(w.prefix(8000))) }
    if let f = t.readFileIfPresent("lib/html/fixtures/tests1.dat") { seeds.append(Array(f.prefix(6000))) }
    if let f = t.readFileIfPresent("lib/html/fixtures/tests16.dat") { seeds.append(Array(f.prefix(6000))) }
    t.fuzz("html", seeds: seeds, iterations: 3000) { data in
        let d = htmlParse(data, limits: HTMLParseLimits(maxInputBytes: 1 << 20, maxNodes: 50_000, maxDepth: 64))
        _ = htmlTreeDump(d)
    }

    t.section("speed")
    if let w = t.readFileIfPresent("lib/html/fixtures/wikipedia-html.html") {
        let t0 = hostMillis()
        var nodes = 0
        for _ in 0..<5 { nodes = htmlCountNodes(htmlParse(w)) }
        let ms = max(1, (hostMillis() - t0) / 5)
        print("  speed: \(w.count / 1024) KB Wikipedia article, \(nodes) nodes: \(ms) ms per parse (\(w.count / ms / 1024) MB/s)")
    }
}
