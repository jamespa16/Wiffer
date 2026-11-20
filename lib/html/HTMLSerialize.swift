// The HTML fragment serializing algorithm (WHATWG "Serializing HTML
// fragments"): the innerHTML / outerHTML getters. Iterative (explicit
// stack), so any depth is safe.
//
// Escaping follows the current spec: text escapes & < > and U+00A0;
// attribute values escape & " < > and U+00A0. Void elements have no end
// tag; children of style, script, xmp, iframe, noembed, noframes and
// plaintext are written raw (noscript too would be, with scripting on);
// a template serializes its contents. Foreign elements are written the same
// way (no self-closing syntax), as browsers do.

/// innerHTML: serialize the node's children (a template's contents).
public func htmlSerializeChildren(_ node: HTMLNode) -> String {
    var out: [UInt8] = []
    htmlSerializeInto(&out, node, includeSelf: false)
    return String(decoding: out, as: UTF8.self)
}

/// outerHTML: serialize the node itself.
public func htmlSerialize(_ node: HTMLNode) -> String {
    var out: [UInt8] = []
    htmlSerializeInto(&out, node, includeSelf: true)
    return String(decoding: out, as: UTF8.self)
}

func htmlSerializesAsVoid(_ n: HTMLNode) -> Bool {
    guard n.kind == .element && n.namespace == .html else { return false }
    switch n.tag {
    case .area, .base, .basefont, .bgsound, .br, .col, .embed, .frame, .hr, .img, .input, .keygen,
         .link, .meta, .param, .source, .track, .wbr:
        return true
    default: return false
    }
}

func htmlIsRawTextParent(_ n: HTMLNode?) -> Bool {
    guard let n = n, n.kind == .element && n.namespace == .html else { return false }
    switch n.tag {
    case .style, .script, .xmp, .iframe, .noembed, .noframes, .plaintext: return true
    default: return false
    }
}

/// Which shadow roots getHTML writes out.
struct HTMLSerializeShadows {
    var serializable = false
    var roots: [HTMLNode] = []

    func includes(_ host: HTMLNode) -> HTMLNode? {
        guard let s = host.attachedShadowRoot else { return nil }
        if serializable && s.serializable { return s }
        for r in roots where r === s { return s }
        return nil
    }
}

func htmlSerializeInto(_ out: inout [UInt8], _ node: HTMLNode, includeSelf: Bool,
                       shadows: HTMLSerializeShadows = HTMLSerializeShadows()) {
    func put(_ s: StaticString) {
        let p = s.utf8Start
        var i = 0
        while i < s.utf8CodeUnitCount { out.append(p[i]); i += 1 }
    }
    func childList(_ n: HTMLNode) -> [HTMLNode] {
        if let t = n.templateContents { return t.children }
        return n.children
    }
    let anyShadows = shadows.serializable || !shadows.roots.isEmpty
    // (node, step): 0 = start, 1 = end tag, 2 = a shadow root's template
    // start (node = the shadow root), 3 = its end tag.
    var stack: [(HTMLNode, UInt8)] = []
    func pushChildren(_ n: HTMLNode) {
        let kids = childList(n)
        var i = kids.count - 1
        while i >= 0 { stack.append((kids[i], 0)); i -= 1 }
        if anyShadows, n.kind == .element, let s = shadows.includes(n) { stack.append((s, 2)) }
    }
    if includeSelf {
        stack.append((node, 0))
    } else {
        pushChildren(node)
    }
    while let (n, step) = stack.popLast() {
        if step == 1 {
            put("</")
            out.append(contentsOf: n.name.utf8)
            put(">")
            continue
        }
        if step == 2 {
            put("<template shadowrootmode=\"")
            if n.shadowRootMode == .closed { put("closed") } else { put("open") }
            put("\"")
            if n.delegatesFocus { put(" shadowrootdelegatesfocus=\"\"") }
            if n.serializable { put(" shadowrootserializable=\"\"") }
            if n.clonable { put(" shadowrootclonable=\"\"") }
            put(">")
            stack.append((n, 3))
            var i = n.children.count - 1
            while i >= 0 { stack.append((n.children[i], 0)); i -= 1 }
            continue
        }
        if step == 3 {
            put("</template>")
            continue
        }
        switch n.kind {
        case .element:
            put("<")
            out.append(contentsOf: n.name.utf8)
            for a in n.attributes {
                put(" ")
                out.append(contentsOf: a.name.utf8)
                put("=\"")
                htmlEscape(&out, a.value.utf8, attribute: true)
                put("\"")
            }
            put(">")
            if htmlSerializesAsVoid(n) { continue }
            stack.append((n, 1))
            pushChildren(n)
        case .text:
            if htmlIsRawTextParent(n.parent) { out.append(contentsOf: n.data) }
            else { htmlEscape(&out, n.data, attribute: false) }
        case .comment:
            put("<!--")
            out.append(contentsOf: n.data)
            put("-->")
        case .doctype:
            put("<!DOCTYPE ")
            out.append(contentsOf: n.name.utf8)
            put(">")
        case .document, .documentFragment:
            var i = n.children.count - 1
            while i >= 0 { stack.append((n.children[i], 0)); i -= 1 }
        }
    }
}

/// The spec's "escaping a string" over UTF-8.
func htmlEscape<S: Sequence>(_ out: inout [UInt8], _ bytes: S, attribute: Bool) where S.Element == UInt8 {
    var pendingC2 = false
    for b in bytes {
        if pendingC2 {
            pendingC2 = false
            if b == 0xa0 { out.append(contentsOf: [0x26, 0x6e, 0x62, 0x73, 0x70, 0x3b]); continue }   // &nbsp;
            out.append(0xc2)
        }
        switch b {
        case 0x26: out.append(contentsOf: [0x26, 0x61, 0x6d, 0x70, 0x3b])            // &amp;
        case 0x3c: out.append(contentsOf: [0x26, 0x6c, 0x74, 0x3b])                  // &lt;
        case 0x3e: out.append(contentsOf: [0x26, 0x67, 0x74, 0x3b])                  // &gt;
        case 0x22 where attribute: out.append(contentsOf: [0x26, 0x71, 0x75, 0x6f, 0x74, 0x3b])  // &quot;
        case 0xc2: pendingC2 = true
        default: out.append(b)
        }
    }
    if pendingC2 { out.append(0xc2) }
}
