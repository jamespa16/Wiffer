// Phase 9G groundwork: checked mutation, the mutation hook, the document
// arena, template contents, fragment parsing entry points, serialization.

func htmlDOMErr(_ f: () throws(HTMLDOMError) -> Void) -> HTMLDOMError? {
    do { try f(); return nil } catch { return error }
}

/// Structural invariants: every child's parent and index agree with its
/// parent's child list; template contents point back at their template.
func htmlTreeConsistent(_ root: HTMLNode) -> Bool {
    var ok = true
    var stack: [HTMLNode] = [root]
    var seen = 0
    while let n = stack.popLast() {
        seen += 1
        if seen > 2_000_000 { return false }
        var i = 0
        for c in n.children {
            if c.parent !== n || c.index != i { ok = false }
            stack.append(c)
            i += 1
        }
        if let t = n.templateContents {
            if t.templateElement !== n || t.parent != nil { ok = false }
            stack.append(t)
        }
    }
    return ok
}

func htmlDOMTests(_ t: Tests) {
    t.section("DOM mutation")
    let doc = htmlParse("<!DOCTYPE html><body><div id=a><p id=p1>1</p><p id=p2>2</p></div><span id=s>s</span>")
    guard let a = doc.getElementById("a"), let p1 = doc.getElementById("p1"), let p2 = doc.getElementById("p2"),
          let s = doc.getElementById("s"), let body = doc.body else {
        t.check(false, "fixture"); return
    }
    let x = try! doc.createElement("SECTION")
    t.equal(x.name, "section", "createElement lowercases")
    t.check(x.ownerDocument === doc && x.parent == nil && !x.isConnected, "new element detached, owned")
    t.check(htmlDOMErr { () throws(HTMLDOMError) in _ = try doc.createElement("1x") } == .invalidCharacter, "bad element name")
    t.check(htmlDOMErr { () throws(HTMLDOMError) in _ = try doc.createElement("a b") } == .invalidCharacter, "space in element name")
    try! a.insertBefore(x, p2)
    t.equal(a.children.map { $0.name }, ["p", "section", "p"], "insertBefore")
    t.check(p2.index == 2 && p2.previousSibling === x && x.nextSibling === p2 && x.isConnected, "indices after insert")
    try! a.appendChild(p1)   // move within the same parent
    t.equal(a.children.map { $0.id ?? $0.name }, ["section", "p2", "p1"], "appendChild moves")
    try! body.insertBefore(p2, s)   // move to another parent
    t.equal(body.children.map { $0.id ?? $0.name }, ["a", "p2", "s"], "move across parents")
    t.check(htmlTreeConsistent(doc), "consistent after moves")
    try! a.insertBefore(x, x)   // reference is the node itself
    t.equal(a.children.map { $0.id ?? $0.name }, ["section", "p1"], "insertBefore(node, node)")
    t.check(htmlDOMErr { () throws(HTMLDOMError) in try x.appendChild(a) } == .hierarchyRequest, "ancestor into descendant")
    t.check(htmlDOMErr { () throws(HTMLDOMError) in try a.appendChild(a) } == .hierarchyRequest, "node into itself")
    t.check(htmlDOMErr { () throws(HTMLDOMError) in try a.removeChild(s) } == .notFound, "removeChild of a non-child")
    t.check(htmlDOMErr { () throws(HTMLDOMError) in try a.insertBefore(x, s) } == .notFound, "insertBefore with a foreign reference")
    t.check(htmlDOMErr { () throws(HTMLDOMError) in try doc.appendChild(doc.createTextNode("t")) } == .hierarchyRequest, "text under document")
    t.check(htmlDOMErr { () throws(HTMLDOMError) in try doc.appendChild(try doc.createElement("div")) } == .hierarchyRequest, "second document element")
    t.check(htmlDOMErr { () throws(HTMLDOMError) in try p1.appendChild(doc.createTextNode("t")) } == nil, "text under element")
    let tx = doc.createTextNode("t")
    t.check(htmlDOMErr { () throws(HTMLDOMError) in try tx.appendChild(doc.createTextNode("u")) } == .hierarchyRequest, "child of text")
    t.check(htmlDOMErr { () throws(HTMLDOMError) in try a.appendChild(doc) } == .hierarchyRequest, "document as child")
    if let dt = doc.firstChild {
        t.check(htmlDOMErr { () throws(HTMLDOMError) in try a.appendChild(dt) } == .hierarchyRequest, "doctype under element")
    }
    let removed = try! a.removeChild(p1)
    t.check(removed === p1 && p1.parent == nil && a.children.count == 1 && x.index == 0, "removeChild")
    let y = try! doc.createElement("em")
    let old = try! a.replaceChild(y, x)
    t.check(old === x && x.parent == nil && a.children.first === y && y.index == 0, "replaceChild")
    t.check(htmlDOMErr { () throws(HTMLDOMError) in _ = try a.replaceChild(x, p2) } == .notFound, "replaceChild of a non-child")
    s.remove()
    t.check(s.parent == nil && body.children.count == 2, "remove()")

    // Fragments.
    let frag = doc.createDocumentFragment()
    try! frag.appendChild(doc.createTextNode("f1"))
    try! frag.appendChild(try! doc.createElement("b"))
    try! a.insertBefore(frag, y)
    t.check(frag.children.isEmpty && a.children.count == 3 && a.children[1].name == "b" && y.index == 2, "fragment insertion moves children")
    t.check(htmlTreeConsistent(doc), "consistent after fragment insert")
    let df = doc.createDocumentFragment()
    try! df.appendChild(try! doc.createElement("x"))
    try! df.appendChild(try! doc.createElement("y"))
    if let html = doc.documentElement {
        t.check(htmlDOMErr { () throws(HTMLDOMError) in _ = try doc.replaceChild(df, html) } == .hierarchyRequest, "two elements into a document")
    }

    // cloneNode.
    let c0 = a.cloneNode()
    t.check(c0.children.isEmpty && c0.attribute("id") == "a" && c0.parent == nil && c0.ownerDocument === doc, "shallow clone")
    let c1 = a.cloneNode(deep: true)
    t.equal(htmlSerialize(c1), htmlSerialize(a), "deep clone serializes the same")
    t.check(htmlTreeConsistent(c1) && c1.children.first !== a.children.first, "deep clone is a copy")
    let dclone = doc.cloneNode(deep: true)
    t.check(dclone.kind == .document && dclone !== doc && htmlSerializeChildren(dclone) == htmlSerializeChildren(doc), "document clone")
    let other = htmlParse("<p>other")
    let imported = try! other.importNode(a, deep: true)
    t.check(imported.ownerDocument === other && htmlSerialize(imported) == htmlSerialize(a), "importNode")
    try! other.body!.appendChild(c1)   // adopts c1's subtree
    t.check(c1.ownerDocument === other && c1.children.first?.ownerDocument === other, "insertion adopts")

    // Attributes and character data.
    try! a.setAttribute("Data-X", "1")
    t.check(a.attribute("data-x") == "1" && a.getAttribute("DATA-X") == "1", "setAttribute lowercases")
    try! a.setAttribute("data-x", "2")
    t.check(a.attribute("data-x") == "2" && a.attributes.count == 2, "setAttribute replaces")
    t.check(htmlDOMErr { () throws(HTMLDOMError) in try a.setAttribute("a=b", "") } == .invalidCharacter, "bad attribute name")
    t.check(a.removeAttribute("DATA-X") && !a.hasAttribute("data-x") && !a.removeAttribute("data-x"), "removeAttribute")
    t.check((try! a.toggleAttribute("hidden")) && a.attribute("hidden") == "", "toggleAttribute on")
    t.check(!(try! a.toggleAttribute("hidden")) && !a.hasAttribute("hidden"), "toggleAttribute off")
    t.check((try! a.toggleAttribute("hidden", force: true)) && (try! a.toggleAttribute("hidden", force: true)), "toggleAttribute force")
    let svg = try! doc.createElementNS(.svg, "svg")
    try! svg.setAttribute("viewBox", "0 0 1 1")
    t.check(svg.attribute("viewBox") != nil, "SVG attribute case kept")
    tx.setData("abc")
    tx.appendData("d")
    t.equal(tx.text, "abcd", "setData/appendData")
    a.setTextContent("only")
    t.check(a.children.count == 1 && a.children[0].isText && a.textContent == "only", "setTextContent")
    a.setTextContent("")
    t.check(a.children.isEmpty, "setTextContent empty")

    t.section("mutation observers")
    let od = htmlParse("<div id=r><i>1</i><i>2</i></div>")
    guard let r = od.getElementById("r") else { t.check(false, "fixture"); return }
    var log: [HTMLMutation] = []
    let id = od.addMutationObserver { log.append($0) }
    let n1 = try! od.createElement("b")
    try! r.appendChild(n1)
    t.check(log.count == 1 && log[0].kind == .childList && log[0].target === r && log[0].addedNodes.count == 1
            && log[0].addedNodes[0] === n1 && log[0].previousSibling === r.children[1] && log[0].nextSibling == nil, "append record")
    log.removeAll()
    try! r.insertBefore(n1, r.firstChild)
    t.check(log.count == 2 && log[0].removedNodes.first === n1 && log[1].addedNodes.first === n1
            && log[1].nextSibling === r.children[1], "move = remove + insert records")
    log.removeAll()
    let ff = od.createDocumentFragment()
    try! ff.appendChild(od.createTextNode("a"))
    try! ff.appendChild(od.createTextNode("b"))
    log.removeAll()
    try! r.appendChild(ff)
    t.check(log.count == 2 && log[0].target === ff && log[0].removedNodes.count == 2 && log[1].addedNodes.count == 2, "fragment records")
    log.removeAll()
    try! r.setAttribute("class", "c")
    try! r.setAttribute("class", "d")
    r.removeAttribute("class")
    t.check(log.count == 3 && log.allSatisfy { $0.kind == .attributes && $0.attributeName == "class" }
            && log[0].oldValue == nil && log[1].oldValue == "c" && log[2].oldValue == "d", "attribute records")
    log.removeAll()
    if let tn = r.lastChild {
        tn.setData("z")
        t.check(log.count == 1 && log[0].kind == .characterData && log[0].oldValue == "b" && log[0].target === tn, "characterData record")
    }
    log.removeAll()
    let rep = od.createTextNode("rep")
    try! r.replaceChild(rep, r.children[0])
    t.check(log.count == 1 && log[0].addedNodes.first === rep && log[0].removedNodes.first === n1, "replaceChild: one record")
    log.removeAll()
    r.setInnerHTML("<p>x</p><p>y</p>")
    t.check(log.count == 2 && log[0].target.isDocumentFragment && log[1].target === r && log[1].addedNodes.count == 2 && log[1].removedNodes.count == 5, "innerHTML: one record on the element (after the parsed fragment's)")
    log.removeAll()
    var nested = 0
    let id2 = od.addMutationObserver { m in
        // An observer may mutate: re-entrant delivery.
        if m.kind == .attributes && m.attributeName == "data-a" { nested += 1; try? r.setAttribute("data-b", "1") }
    }
    try! r.setAttribute("data-a", "1")
    t.check(nested == 1 && log.count == 2 && log[1].attributeName == "data-b", "re-entrant observer")
    od.removeMutationObserver(id2)
    od.removeMutationObserver(id)
    log.removeAll()
    try! r.setAttribute("data-c", "1")
    t.check(log.isEmpty, "removed observer is silent")
    // Template contents belong to the inert document: not reported.
    let tplDoc = htmlParse("<template id=t></template>")
    var tcount = 0
    tplDoc.addMutationObserver { _ in tcount += 1 }
    if let tpl = tplDoc.getElementById("t"), let content = tpl.templateContents {
        try! content.appendChild(try! tplDoc.createElement("p"))
        t.check(tcount == 0 && content.children.count == 1, "template contents mutations are not the page's")
    }

    t.section("arena")
    var kept: HTMLNode? = nil
    var detached: HTMLNode? = nil
    do {
        let d = htmlParse("<div id=k><p id=q>x<b>y</b></p></div>")
        let before = d.arenaNodeCount
        if let q = d.getElementById("q"), let k = d.getElementById("k") {
            try! k.removeChild(q)
            detached = q
            t.check(d.arenaNodeCount == before, "detached nodes stay in the arena")
            let made = try! d.createElement("i")
            _ = made
            t.check(d.arenaNodeCount == before + 1, "created nodes join the arena")
        }
        kept = d.getElementById("k")
    }
    t.check(kept?.parent == nil && kept?.ownerDocument == nil && kept?.children.isEmpty == true, "node outliving its document")
    t.check(detached?.textContent == "xy" && detached?.parent == nil, "detached subtree outlives the document intact")
    kept = nil
    detached = nil
    do {
        // A 200 000-deep chain built bottom-up (child first): freeing it
        // must not recurse.
        let d = htmlParse("<body>")
        var root = try! d.createElement("div")
        for _ in 0..<200_000 {
            let p = try! d.createElement("div")
            try! p.appendChild(root)
            root = p
        }
        try! d.body!.appendChild(root)
        let s = htmlSerialize(root)
        t.check(s.utf8.count == 200_001 * 11, "deep serialize")
        let cl = root.cloneNode(deep: true)
        t.check(cl.firstChild?.firstChild != nil, "deep clone")
        t.check(htmlParse(s).getElementsByTagName("div").count == 200_001, "reparse deep markup (depth capped)")
    }
    t.check(true, "deep document freed without recursion")
    do {
        let d = htmlParse("<p>")
        d.teardown()
        t.check(d.arenaNodeCount == 0 && d.children.isEmpty, "teardown releases the arena")
    }

    t.section("template")
    let td = htmlParse("<!DOCTYPE html><template id=t><td>in</td><td>c</td></template><p id=o>out</p>")
    if let tpl = td.getElementById("t"), let content = tpl.templateContents {
        t.check(tpl.children.isEmpty && content.children.count == 2 && content.isDocumentFragment, "parsed into contents")
        t.check(content.ownerDocument !== td && content.ownerDocument === content.children[0].ownerDocument, "inert owner document")
        t.check(td.getElementById("o") != nil && td.getElementsByTagName("td").isEmpty, "contents are not in the tree")
        t.check(!content.children[0].isConnected, "contents are not connected")
        t.equal(tpl.innerHTML, "<td>in</td><td>c</td>", "template innerHTML")
        tpl.setInnerHTML("<tr><td>z")
        t.equal(tpl.innerHTML, "<tr><td>z</td></tr>", "template innerHTML setter")
        let cl = tpl.cloneNode(deep: true)
        t.equal(cl.innerHTML, tpl.innerHTML, "deep clone copies contents")
        t.check(cl.templateContents?.children.first !== content.children.first, "cloned contents are copies")
        t.check(htmlDOMErr { () throws(HTMLDOMError) in try content.appendChild(tpl) } == .hierarchyRequest, "host-including ancestor check")
        let other = htmlParse("")
        try! other.body!.appendChild(tpl)
        t.check(tpl.templateContents?.ownerDocument === other.templateContentsOwner, "adopting moves contents")
    }

    t.section("serialization")
    func round(_ s: String) -> String { htmlParse("<body>" + s).body?.innerHTML ?? "?" }
    for s in ["<p class=\"a&amp;&quot;b\">x &lt; y &amp; z&nbsp;w</p>",
              "<br><img src=\"a.png\" alt=\"\"><hr><input type=\"text\">",
              "<script>if (a<b && c>d) {}</script><style>p>q{}</style>",
              "<!--c--><textarea>&lt;/x&gt;</textarea><pre>a</pre>",
              "<svg viewBox=\"0 0 1 1\"><path d=\"M0\"></path><foreignObject><p>x</p></foreignObject></svg>",
              "<math><mi>x</mi></math><template><i>t</i></template>",
              "<table><tbody><tr><td>1</td></tr></tbody></table>",
              "<a href=\"x\" xlink:href=\"y\">é ✓ 😀</a>"] {
        t.equal(round(s), s, "round trip: \(s)")
    }
    t.equal(round("<p title='<\"&>'>"), "<p title=\"&lt;&quot;&amp;&gt;\"></p>", "attribute escaping")
    t.equal(round("<p>a<b>c"), "<p>a<b>c</b></p>", "end tags added")
    let sd = htmlParse("<!DOCTYPE html><title>t</title><p id=x>hi")
    t.equal(htmlSerializeChildren(sd), "<!DOCTYPE html><html><head><title>t</title></head><body><p id=\"x\">hi</p></body></html>", "document")
    if let px = sd.getElementById("x") {
        t.equal(px.outerHTML, "<p id=\"x\">hi</p>", "outerHTML")
        try! px.setOuterHTML("<b>1</b><i>2</i>")
        t.equal(sd.body?.innerHTML ?? "", "<b>1</b><i>2</i>", "outerHTML setter")
    }
    if let html = sd.documentElement {
        t.check(htmlDOMErr { () throws(HTMLDOMError) in try html.setOuterHTML("x") } == .noModificationAllowed, "outerHTML on the root")
        t.check(htmlDOMErr { () throws(HTMLDOMError) in try html.insertAdjacentHTML("beforebegin", "x") } == .noModificationAllowed, "insertAdjacentHTML beside the root")
    }
    if let b = sd.body?.firstChild {
        try! b.insertAdjacentHTML("beforeBegin", "<u>0</u>")
        try! b.insertAdjacentHTML("afterbegin", "a")
        try! b.insertAdjacentHTML("beforeend", "<s>z</s>")
        try! b.insertAdjacentHTML("afterend", "!")
        t.equal(sd.body?.innerHTML ?? "", "<u>0</u><b>a1<s>z</s></b>!<i>2</i>", "insertAdjacentHTML")
        t.check(htmlDOMErr { () throws(HTMLDOMError) in try b.insertAdjacentHTML("middle", "") } == .syntax, "insertAdjacentHTML bad position")
        t.check(htmlTreeConsistent(sd), "consistent after markup edits")
    }
    // Context-sensitive innerHTML.
    let ctxDoc = htmlParse("<table><tr id=tr></tr></table><select id=sel></select><textarea id=ta></textarea>")
    if let tr = ctxDoc.getElementById("tr") {
        tr.setInnerHTML("<td>1<td>2")
        t.equal(tr.innerHTML, "<td>1</td><td>2</td>", "innerHTML in a tr")
    }
    if let sel = ctxDoc.getElementById("sel") {
        sel.setInnerHTML("<option>a<option>b")
        t.equal(sel.innerHTML, "<option>a</option><option>b</option>", "innerHTML in a select")
    }
    if let ta = ctxDoc.getElementById("ta") {
        ta.setInnerHTML("<b>not markup</b>")
        t.check(ta.children.count == 1 && ta.children[0].isText, "innerHTML in a textarea is text")
    }
    // Serialization is a fixpoint: serialize, reparse, serialize again.
    if let w = t.readFileIfPresent("lib/html/fixtures/wikipedia-html.html") {
        let s1 = htmlSerializeChildren(htmlParse(w))
        let s2 = htmlSerializeChildren(htmlParse(s1))
        t.check(s1 == s2, "Wikipedia serialize/reparse fixpoint (\(s1.utf8.count) bytes)")
        let t0 = hostMillis()
        _ = htmlSerializeChildren(htmlParse(w))
        print("  serialize: Wikipedia parse + serialize \(hostMillis() - t0) ms")
    }

    t.section("fuzz: fragments and mutation")
    let contexts = ["body", "td", "tr", "table", "select", "template", "textarea", "svg", "math", "html", "head", "frameset"]
    let fdoc = htmlNewDocument()
    var ctxNodes: [HTMLNode] = []
    for c in contexts {
        if c == "svg", let e = try? fdoc.createElementNS(.svg, "svg") { ctxNodes.append(e); continue }
        if c == "math", let e = try? fdoc.createElementNS(.mathml, "math") { ctxNodes.append(e); continue }
        if let e = try? fdoc.createElement(c) { ctxNodes.append(e) }
    }
    let seeds: [[UInt8]] = [
        Array("<td>a<tr><th>b</table><template><col><p>x</template><option>o<select><svg><desc><p>q".utf8),
        Array("<frameset><frame></frameset><math><mi><b>x</b><annotation-xml encoding=text/html><div>".utf8),
        Array("<template><template><tr><td><template><caption>c</template></template></template><form><form>".utf8),
    ]
    t.fuzz("fragment", seeds: seeds, iterations: 2000) { data in
        guard !data.isEmpty else { return }
        let ctx = ctxNodes[Int(data[0]) % ctxNodes.count]
        let f = htmlParseFragment(data, context: ctx, limits: HTMLParseLimits(maxInputBytes: 1 << 16, maxNodes: 5000, maxDepth: 64))
        let s = htmlSerializeChildren(f)
        _ = htmlParseFragment(s, context: ctx)
        _ = htmlTreeDump(f)
    }
    t.fuzz("mutation", seeds: seeds, iterations: 1500) { data in
        let d = htmlParse(data, limits: HTMLParseLimits(maxInputBytes: 1 << 16, maxNodes: 2000, maxDepth: 64))
        var pool: [HTMLNode] = []
        d.walk { pool.append($0); return pool.count < 300 }
        pool.append(d.createDocumentFragment())
        pool.append(d.createTextNode("t"))
        var i = 0
        var steps = 0
        func next() -> Int { let v = i < data.count ? Int(data[i]) : 7 * i; i += 1; return v }
        while steps < 60 && !pool.isEmpty {
            steps += 1
            let a = pool[next() % pool.count], b = pool[next() % pool.count]
            let c: HTMLNode? = b.children.isEmpty ? nil : b.children[next() % b.children.count]
            switch next() % 9 {
            case 0: _ = try? b.appendChild(a)
            case 1: _ = try? b.insertBefore(a, c)
            case 2: if let c = c { _ = try? b.replaceChild(a, c) }
            case 3: if let c = c { _ = try? b.removeChild(c) }
            case 4: pool.append(a.cloneNode(deep: true))
            case 5: try? a.setAttribute("x\(next() % 4)", "v")
            case 6: if a.isElement || a.isDocumentFragment { a.setInnerHTML("<i>m</i>t<td>") }
            case 7: try? a.insertAdjacentHTML(["beforebegin", "afterbegin", "beforeend", "afterend"][next() % 4], "<b>z</b>")
            default: a.setTextContent("q")
            }
        }
        if !htmlTreeConsistent(d) { t.check(false, "fuzz mutation left an inconsistent tree") }
        _ = htmlSerializeChildren(d)
    }
}
