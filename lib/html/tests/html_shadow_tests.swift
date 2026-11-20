// Phase 9I groundwork: shadow roots, slots (named, manual, flattening,
// slotchange signals), the flat tree, declarative shadow DOM in the parser
// and fragment parser, getHTML, cloning, custom element state. Many checks
// follow WPT shadow-dom/ and shadow-dom/declarative/ cases.

private func shDoc(_ s: String) -> HTMLNode { htmlParse("<!DOCTYPE html><body>" + s) }

private func shNames(_ ns: [HTMLNode]) -> String {
    var out: [String] = []
    for n in ns {
        if n.kind == .text { out.append("#" + n.text) } else { out.append(n.attribute("id") ?? n.name) }
    }
    return out.joined(separator: ",")
}

/// Every slot's stored assignment equals a from-scratch "find slottables",
/// and every slottable's assigned slot agrees.
func htmlSlotsConsistent(_ doc: HTMLNode) -> Bool {
    var ok = true
    doc.walkShadowIncluding { n in
        if n.isSlot {
            let want = n.findSlottables()
            let have = n.rare?.assignedNodes ?? []
            if want.count != have.count { ok = false; return false }
            for i in 0..<want.count where want[i] !== have[i] { ok = false }
            for a in have where a.rare?.assignedSlot !== n { ok = false }
        }
        if n.isSlottable, let s = n.rare?.assignedSlot {
            if !(s.rare?.assignedNodes.contains { $0 === n } ?? false) { ok = false }
        }
        return ok
    }
    return ok
}

func htmlShadowTests(_ t: Tests) {
    t.section("shadow roots")
    do {
        let d = shDoc("<div id=h><span id=a>a</span></div><table id=tb></table><x-foo id=x></x-foo>")
        let h = d.getElementById("h")!, x = d.getElementById("x")!, tb = d.getElementById("tb")!
        let s = try! h.attachShadow(mode: .open)
        t.check(s.isShadowRoot && s.kind == .documentFragment && s.host === h && h.shadowRoot === s, "attachShadow: open root")
        t.check(s.parent == nil && !h.children.contains { $0 === s }, "shadow root is not a child")
        t.check(s.isConnected && s.ownerDocument === d, "shadow root connected, same document")
        t.check(htmlDOMErr { () throws(HTMLDOMError) in _ = try h.attachShadow(mode: .open) } == .notSupported, "second attachShadow: NotSupportedError")
        t.check(htmlDOMErr { () throws(HTMLDOMError) in _ = try tb.attachShadow(mode: .open) } == .notSupported, "table can't host")
        let svg = try! d.createElementNS(.svg, "g")
        t.check(htmlDOMErr { () throws(HTMLDOMError) in _ = try svg.attachShadow(mode: .open) } == .notSupported, "non-HTML can't host")
        let cs = try! x.attachShadow(mode: .closed, delegatesFocus: true, slotAssignment: .manual, clonable: true, serializable: true)
        t.check(x.shadowRoot == nil && x.attachedShadowRoot === cs && cs.shadowRootMode == .closed, "closed root hidden from shadowRoot")
        t.check(cs.delegatesFocus && cs.slotAssignment == .manual && cs.clonable && cs.serializable, "init flags kept")
        t.check(htmlDOMErr { () throws(HTMLDOMError) in _ = try d.createElement("x-a").attachShadow(mode: .open, customElementShadowDisabled: true) } == .notSupported,
                "disableShadow definition: NotSupportedError")
        for name in ["article", "aside", "blockquote", "body", "div", "footer", "h1", "h6", "header", "main", "nav", "p", "section", "span", "my-el"] {
            t.check((try? d.createElement(name).attachShadow(mode: .open)) != nil, "valid host <\(name)>")
        }
        for name in ["a", "button", "img", "input", "template", "slot", "font-face"] {
            t.check((try? d.createElement(name).attachShadow(mode: .open)) == nil, "invalid host <\(name)>")
        }

        // Tree membership, roots, getElementById stopping at the boundary.
        let inner = try! d.createElement("p")
        try! inner.setAttribute("id", "in")
        try! s.appendChild(inner)
        t.check(inner.rootNode === s && inner.rootNode(composed: true) === d && inner.isConnected, "rootNode / composed / isConnected")
        t.check(d.getElementById("in") == nil && s.getElementById("in") === inner, "getElementById stops at the shadow boundary")
        t.check(d.getElementsByTagName("p").isEmpty, "document queries don't enter shadow trees")
        t.check(h.contains(inner) == false && h.isShadowIncludingInclusiveAncestor(of: inner), "contains vs shadow-including")
        t.check(htmlDOMErr { () throws(HTMLDOMError) in try inner.appendChild(h) } == .hierarchyRequest, "host-including ancestor check crosses the shadow root")
        t.check(htmlDOMErr { () throws(HTMLDOMError) in _ = try d.importNode(s) } == .notSupported, "importNode(shadowRoot): NotSupportedError")
        t.check(htmlDOMErr { () throws(HTMLDOMError) in try d.adoptNode(s) } == .hierarchyRequest, "adoptNode(shadowRoot): HierarchyRequestError")
        t.check(inner.retargeted(against: d) === h && inner.retargeted(against: inner) === inner, "retarget")
        t.check(htmlTreeConsistent(s), "shadow tree consistent")

        // Mutation records from inside the shadow tree.
        var log: [HTMLMutation] = []
        let oid = d.addMutationObserver { log.append($0) }
        try! inner.setAttribute("class", "c")
        try! s.appendChild(d.createTextNode("t"))
        t.check(log.count == 2 && log[0].kind == .attributes && log[0].target === inner && log[1].kind == .childList
                && log[1].target === s && log[1].target.isConnected, "records inside a shadow tree")
        log.removeAll()
        let host2 = try! d.createElement("div")
        try! d.body!.appendChild(host2)
        log.removeAll()
        _ = try! host2.attachShadow(mode: .open)
        t.check(log.count == 1 && log[0].kind == .shadowRootAttached && log[0].target === host2, "shadowRootAttached record")
        d.removeMutationObserver(oid)
    }

    t.section("slots")
    do {
        let d = shDoc("<div id=h><span id=a slot=x>a</span><b id=b>b</b>text<i id=c slot=y>c</i></div>")
        let h = d.getElementById("h")!
        let a = d.getElementById("a")!, b = d.getElementById("b")!, c = d.getElementById("c")!
        let s = try! h.attachShadow(mode: .open)
        var log: [HTMLMutation] = []
        let oid = d.addMutationObserver { if $0.kind == .slotchange { log.append($0) } }
        s.setInnerHTML("<slot id=sx name=x><em>fb</em></slot><p><slot id=def></slot></p><slot id=sx2 name=x></slot>")
        let sx = s.getElementById("sx")!, def = s.getElementById("def")!, sx2 = s.getElementById("sx2")!
        t.equal(shNames(sx.assignedNodes()), "a", "named slot takes slot=x")
        t.equal(shNames(def.assignedNodes()), "b,#text", "default slot takes unnamed element and text")
        t.check(sx2.assignedNodes().isEmpty, "second slot with the same name takes nothing")
        t.check(a.assignedSlot === sx && b.assignedSlot === def && c.assignedSlot == nil, "assignedSlot")
        t.check(log.count == 2 && log.contains { $0.target === sx } && log.contains { $0.target === def }, "slotchange for both filled slots")
        t.equal(shNames(h.flatTreeChildren), "sx,p,sx2", "host's flat children = shadow root's children")
        t.equal(shNames(sx.flatTreeChildren), "a", "slot's flat children = assigned nodes")
        t.equal(shNames(sx2.flatTreeChildren), "", "empty slot without fallback")
        t.check(a.flatTreeParent === sx && c.flatTreeParent == nil && sx.flatTreeParent === h, "flatTreeParent")
        t.check(sx.firstElement { $0.name == "em" }!.flatTreeParent == nil, "fallback hidden while assigned")
        t.check(!c.isInFlatTree && a.isInFlatTree, "isInFlatTree")

        log.removeAll()
        try! c.setAttribute("slot", "x")
        t.equal(shNames(sx.assignedNodes()), "a,c", "slot attribute change reassigns")
        t.check(log.count == 1 && log[0].target === sx, "one slotchange")
        log.removeAll()
        try! sx.setAttribute("name", "z")
        t.equal(shNames(sx2.assignedNodes()), "a,c", "renaming the first slot hands its nodes to the next")
        t.check(sx.assignedNodes().isEmpty && sx.flatTreeChildren.first?.name == "em", "renamed slot shows its fallback")
        t.check(log.count == 2, "slotchange on both slots")
        log.removeAll()
        try! h.removeChild(a)
        t.equal(shNames(sx2.assignedNodes()), "c", "removed light child unassigned")
        t.check(a.assignedSlot == nil && a.rare?.assignedSlot == nil, "removed child forgets its slot")
        try! h.insertBefore(a, h.firstChild)
        t.equal(shNames(sx2.assignedNodes()), "a,c", "inserted light child assigned in tree order")
        let def2 = try! d.createElement("slot")
        try! s.insertBefore(def2, s.firstChild)
        t.check(def2.assignedNodes().count == 2 && def.assignedNodes().isEmpty, "new earlier default slot takes over")
        try! s.removeChild(def2)
        t.equal(shNames(def.assignedNodes()), "b,#text", "removing it gives them back")
        t.check(def2.assignedNodes().isEmpty, "removed slot is empty")
        log.removeAll()
        try! sx.appendChild(d.createTextNode("more fallback"))
        t.check(log.count == 1 && log[0].target === sx, "fallback change on an empty slot signals")
        // Flattening through a nested shadow tree.
        let p = s.firstElement { $0.name == "p" }!
        let inner = try! d.createElement("div")
        try! p.appendChild(inner)
        let s2 = try! inner.attachShadow(mode: .open)
        let fwd = try! d.createElement("slot")
        try! inner.appendChild(fwd)   // forwards the outer default slot's... (a slot as a slottable)
        let s2slot = try! d.createElement("slot")
        try! s2.appendChild(s2slot)
        t.equal(shNames(s2slot.assignedNodes()), "slot", "slot assigned as a slottable")
        t.equal(shNames(s2slot.assignedNodes(flatten: true)), "", "flatten: empty forwarded slot gives its (no) fallback")
        try! fwd.setAttribute("name", "x")
        t.equal(shNames(s2slot.assignedNodes(flatten: true)), "a,c", "flatten through a forwarding slot")
        t.equal(shNames(s2slot.assignedElements(flatten: true)), "a,c", "assignedElements(flatten)")
        t.check(htmlSlotsConsistent(d), "slot state consistent")
        d.removeMutationObserver(oid)
    }

    t.section("manual slot assignment")
    do {
        let d = shDoc("<div id=h><span id=a slot=x>a</span><b id=b>b</b></div><div id=other></div>")
        let h = d.getElementById("h")!, a = d.getElementById("a")!, b = d.getElementById("b")!
        let s = try! h.attachShadow(mode: .open, slotAssignment: .manual)
        s.setInnerHTML("<slot id=s1 name=x></slot><slot id=s2></slot>")
        let s1 = s.getElementById("s1")!, s2 = s.getElementById("s2")!
        t.check(s1.assignedNodes().isEmpty && s2.assignedNodes().isEmpty, "manual: names ignored")
        s2.assign([b, a])
        t.equal(shNames(s2.assignedNodes()), "b,a", "manual: assigned in assign() order")
        s1.assign([a])
        t.equal(shNames(s1.assignedNodes()), "a", "reassigning moves the node")
        t.equal(shNames(s2.assignedNodes()), "b", "and takes it from the old slot")
        t.check(s2.manuallyAssignedNodes.count == 1, "manuallyAssignedNodes updated")
        let other = d.getElementById("other")!
        try! other.appendChild(b)
        t.check(s2.assignedNodes().isEmpty, "node moved out of the host is not assigned")
        try! h.appendChild(b)
        t.equal(shNames(s2.assignedNodes()), "b", "and is again once back")
        s2.assign([])
        t.check(s2.assignedNodes().isEmpty && b.assignedSlot == nil, "assign() clears")
        t.check(htmlSlotsConsistent(d), "manual state consistent")
    }

    t.section("declarative shadow DOM")
    do {
        let d = htmlParse("""
        <!DOCTYPE html><body><div id=h><template shadowrootmode=open shadowrootdelegatesfocus shadowrootclonable shadowrootserializable>\
        <style>p{color:red}</style><p>in <slot></slot></p></template><span>light</span></div>\
        <div id=c><template shadowrootmode=CLOSED><b>closed</b></template></div>\
        <div id=n><template shadowrootmode=bogus>plain</template></div>\
        <table id=t><template shadowrootmode=open>x</template></table>\
        <div id=two><template shadowrootmode=open>1</template><template shadowrootmode=open>2</template></div>
        """)
        let h = d.getElementById("h")!
        guard let s = h.shadowRoot else { t.check(false, "declarative root attached"); return }
        t.check(s.isDeclarativeShadowRoot && s.delegatesFocus && s.clonable && s.serializable && s.availableToElementInternals,
                "declarative flags")
        t.check(h.children.count == 1 && h.children[0].name == "span", "template not in the light tree")
        t.check(s.children.count == 2 && s.children[1].name == "p", "contents parsed into the shadow root")
        let slot = s.firstElement { $0.isSlot }!
        t.equal(shNames(slot.assignedNodes()), "span", "slots assigned after the parse")
        t.check(htmlTreeConsistent(s), "indices assigned in shadow trees")
        let c = d.getElementById("c")!
        t.check(c.shadowRoot == nil && c.attachedShadowRoot?.shadowRootMode == .closed, "closed (case-insensitive)")
        let n = d.getElementById("n")!
        t.check(!n.isShadowHost && n.children.first?.name == "template", "invalid mode: a plain template")
        let tb = d.getElementById("t")!
        t.check(!tb.isShadowHost, "table host fails: template kept")
        let two = d.getElementById("two")!
        t.check(two.shadowRoot?.textContent == "1" && two.children.count == 1 && two.children[0].name == "template",
                "second declarative template on a host stays a template")
        let dump = htmlTreeDump(d)
        t.check(shContains(dump, "#shadow-root (open)") && shContains(dump, "#shadow-root (closed)"), "tree dump shows shadow roots")
        // attachShadow over a declarative root of the same mode: emptied and reused.
        let again = try? h.attachShadow(mode: .open)
        t.check(again === s && s.children.isEmpty && !s.isDeclarativeShadowRoot, "attachShadow reuses a declarative root")
        t.check(htmlDOMErr { () throws(HTMLDOMError) in _ = try c.attachShadow(mode: .open) } == .notSupported, "mode mismatch: NotSupportedError")

        // Opt-out (DOMParser) and fragment parsing.
        let off = htmlParse("<div><template shadowrootmode=open>x</template></div>", declarativeShadowRoots: false)
        t.check(off.body!.children[0].children.first?.name == "template", "declarativeShadowRoots: false")
        let host = try! d.createElement("div")
        host.setInnerHTML("<div><template shadowrootmode=open>x</template></div>")
        t.check(!host.children[0].isShadowHost && host.children[0].children.first?.name == "template", "innerHTML never attaches")
        host.setHTMLUnsafe("<div id=i><template shadowrootmode=open><i>y</i><slot></slot></template>q</div>")
        let i = host.children[0]
        t.check(i.isShadowHost && i.shadowRoot?.textContent == "y", "setHTMLUnsafe attaches")
        t.check(i.shadowRoot!.firstElement { $0.isSlot }!.assignedNodes().count == 1, "setHTMLUnsafe assigns slots")
        let self2 = try! d.createElement("div")
        self2.setHTMLUnsafe("<template shadowrootmode=open><b>me</b></template>light")
        t.check(self2.shadowRoot?.textContent == "me" && self2.textContent == "light", "top-level template attaches to the element itself")
        // Nested declarative roots and roots inside template contents.
        let nd = htmlParse("<div id=o><template shadowrootmode=open><div id=m><template shadowrootmode=open><i>deep</i></template></div></template></div>")
        let deep = nd.getElementById("o")?.shadowRoot?.getElementById("m")?.shadowRoot
        t.check(deep?.textContent == "deep", "nested declarative roots")
        let td = htmlParse("<template id=t><div><template shadowrootmode=open>z</template></div></template>")
        let tc = td.getElementById("t")?.templateContents?.children.first
        t.check(tc?.isShadowHost == true, "declarative root inside template contents")

        // getHTML and cloning.
        let gh = htmlParse("<div id=h><template shadowrootmode=open shadowrootserializable><b>s</b></template><i>l</i></div>")
        let ghost = gh.getElementById("h")!
        t.equal(gh.body!.getHTML(serializableShadowRoots: true),
                "<div id=\"h\"><template shadowrootmode=\"open\" shadowrootserializable=\"\"><b>s</b></template><i>l</i></div>", "getHTML serializable")
        t.equal(gh.body!.getHTML(), "<div id=\"h\"><i>l</i></div>", "getHTML without options")
        t.equal(gh.body!.innerHTML, "<div id=\"h\"><i>l</i></div>", "innerHTML skips shadow roots")
        let rt = htmlParse("<body>" + gh.body!.getHTML(serializableShadowRoots: true))
        t.check(rt.getElementById("h")?.shadowRoot?.textContent == "s", "getHTML round-trips")
        t.check(ghost.cloneNode(deep: true).isShadowHost == false, "non-clonable root not cloned")
        let cl = d.getElementById("c")!   // closed, not clonable
        t.check(!cl.cloneNode(deep: true).isShadowHost, "closed non-clonable")
        let cp = htmlParse("<div id=h><template shadowrootmode=open shadowrootclonable><slot></slot><b>x</b></template><i>l</i></div>")
        let cph = cp.getElementById("h")!
        let shallow = cph.cloneNode(deep: false)
        t.check(shallow.shadowRoot?.textContent == "x" && shallow.children.isEmpty, "clonable root copied even when shallow")
        let deepc = cph.cloneNode(deep: true)
        t.check(deepc.shadowRoot!.firstElement { $0.isSlot }!.assignedNodes().count == 1, "clone's slots assigned")
        t.check(deepc.shadowRoot!.isDeclarativeShadowRoot, "clone keeps declarative")
    }

    t.section("custom element state")
    do {
        let valid = ["a-b", "my-element", "x-", "a-é", "math-α", "a.b-c", "a_b-c"]
        let invalid = ["ab", "A-b", "a-B", "-ab", "1-a", "annotation-xml", "font-face", "missing-glyph", "a b-c", "a-b!", ""]
        for v in valid { t.check(htmlIsValidCustomElementName(v), "valid custom name \(v)") }
        for v in invalid { t.check(!htmlIsValidCustomElementName(v), "invalid custom name '\(v)'") }
        let d = shDoc("<my-el id=m></my-el><div id=v></div>")
        let m = d.getElementById("m")!, v = d.getElementById("v")!
        t.check(m.customElementState == .undefined && !m.isDefined, "parsed custom element: undefined")
        t.check(v.customElementState == .uncustomized && v.isDefined, "div: uncustomized")
        t.check(try! d.createElementNS(.svg, "my-el").customElementState == .uncustomized, "foreign: uncustomized")
        var log: [HTMLMutation] = []
        let oid = d.addMutationObserver { log.append($0) }
        m.setCustomElementState(.custom)
        t.check(m.isDefined && log.count == 1 && log[0].kind == .customElementState, "custom: defined, record")
        m.setCustomElementState(.failed)
        t.check(!m.isDefined, "failed: not defined")
        d.removeMutationObserver(oid)
    }

    t.section("shadow ownership")
    do {
        // Freeing a document with shadow trees and slots; nodes that survive keep working.
        var survivor: HTMLNode? = nil
        var slotKeep: HTMLNode? = nil
        do {
            let d = htmlParse("<div id=h><template shadowrootmode=open><slot id=s></slot></template><span id=a>x</span></div>")
            survivor = d.getElementById("a")
            slotKeep = d.getElementById("h")?.shadowRoot?.getElementById("s")
            t.check(survivor?.assignedSlot === slotKeep, "assigned before teardown")
        }
        t.check(survivor?.rare?.assignedSlot == nil && slotKeep?.assignedNodes().isEmpty == true, "links dropped with the document")
        // A deep chain of shadow hosts frees without recursion.
        let d2 = htmlNewDocument()
        var cur = try! d2.createElement("div")
        let top = cur
        for _ in 0..<20_000 {
            let s = try! cur.attachShadow(mode: .open)
            let next = try! d2.createElement("div")
            try! s.appendChild(next)
            cur = next
        }
        t.check(top.attachedShadowRoot != nil, "deep shadow chain built")
        d2.teardown()
        t.check(true, "deep shadow chain freed")
    }

    t.section("fuzz: shadow mutation")
    do {
        var rng = TestRandom(seed: 99)
        var bad = 0
        for round in 0..<60 {
            let d = htmlParse("<div id=h0><p slot=a>1</p><p>2</p>t</div><div id=h1><b slot=b>3</b></div>")
            var hosts: [HTMLNode] = []
            for n in d.body!.children where n.kind == .element { if let s = try? n.attachShadow(mode: rng.below(2) == 0 ? .open : .closed, slotAssignment: rng.below(5) == 0 ? .manual : .named) { s.setInnerHTML("<slot name=a></slot><div><slot></slot></div><slot name=b>fb</slot>"); hosts.append(n) } }
            var opLog: [String] = []
            for _ in 0..<40 {
                var all: [HTMLNode] = []
                d.walkShadowIncluding { n in if n.kind == .element || n.kind == .text || n.isShadowRoot { all.append(n) }; return true }
                let x = all[rng.below(all.count)]
                let y = all[rng.below(all.count)]
                let op = rng.below(7)
                opLog.append("\(op) x=\(x.name)\(x.isShadowRoot ? "#sr" : "")[\(x.attribute("slot") ?? "")] y=\(y.name)\(y.isShadowRoot ? "#sr" : "")")
                switch op {
                case 0: _ = try? x.setAttribute("slot", ["a", "b", "c", ""][rng.below(4)])
                case 1: if x.isSlot { _ = try? x.setAttribute("name", ["a", "b", ""][rng.below(3)]) } else { _ = x.removeAttribute("slot") }
                case 2: _ = try? y.appendChild(x)
                case 3: if let p = x.parent, !x.isShadowRoot, p.kind != .document { _ = try? p.removeChild(x) }
                case 4: _ = try? y.insertBefore(d.createTextNode("n"), y.firstChild)
                case 5: if x.isSlot { x.assign(all.filter { $0.isSlottable && rng.below(3) == 0 }) }
                default: if x.kind == .element { _ = try? x.appendChild(try! d.createElement(rng.below(2) == 0 ? "slot" : "span")) }
                }
                if !htmlSlotsConsistent(d) || !htmlTreeConsistent(d) { bad += 1; break }
            }
            if bad > 0 { t.check(false, "shadow fuzz round \(round)", opLog.suffix(4).joined(separator: " | ")); break }
        }
        t.check(bad == 0, "slot assignment matches from-scratch after random mutations")
    }
}

private func shContains(_ s: String, _ sub: String) -> Bool {
    let a = Array(s.utf8), b = Array(sub.utf8)
    if b.isEmpty { return true }
    var i = 0
    while i + b.count <= a.count {
        if Array(a[i..<(i + b.count)]) == b { return true }
        i += 1
    }
    return false
}
