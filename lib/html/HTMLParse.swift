// Public entry points: parse a document, parse a fragment (the HTML
// fragment parsing algorithm), and the html5lib "tree dump" format.

/// Parse an HTML document from UTF-8 bytes. Never traps; malformed input
/// produces the tree a browser would build. `limits` bounds memory and
/// depth (see HTMLParseLimits); `document.truncated` reports a cut-short parse.
public func htmlParse(_ bytes: [UInt8], limits: HTMLParseLimits = HTMLParseLimits()) -> HTMLNode {
    let (scalars, cut) = htmlDecodeInput(bytes, maxBytes: limits.maxInputBytes)
    let tb = HTMLTreeBuilder(input: scalars, limits: limits)
    tb.run()
    tb.tokenizer.tb = nil
    let doc = tb.doc
    doc.truncated = doc.truncated || cut
    doc.docState?.quirks = tb.quirks
    doc.templateContentsOwner.docState?.quirks = tb.quirks
    doc.assignIndices()
    return doc
}

/// The HTML fragment parsing algorithm (innerHTML, outerHTML,
/// insertAdjacentHTML): parse `bytes` as if inside `context` (an element),
/// and return the result as a DocumentFragment owned by the context's
/// document. Nothing is inserted anywhere; no observers are notified.
/// `fragment.truncated` reports a cut-short parse.
public func htmlParseFragment(_ bytes: [UInt8], context: HTMLNode,
                              limits: HTMLParseLimits = HTMLParseLimits()) -> HTMLNode {
    let owner = context.documentForCreation
    let (scalars, cut) = htmlDecodeInput(bytes, maxBytes: limits.maxInputBytes)
    let tb = HTMLTreeBuilder(input: scalars, limits: limits)
    tb.quirks = owner.quirksMode
    tb.doc.docState?.quirks = tb.quirks
    tb.context = context
    if context.kind == .element && context.namespace == .html {
        switch context.tag {
        case .title, .textarea: tb.tokenizer.state = .rcdata
        case .style, .xmp, .iframe, .noembed, .noframes: tb.tokenizer.state = .rawtext
        case .script: tb.tokenizer.state = .scriptData
        case .plaintext: tb.tokenizer.state = .plaintext
        default: break   // noscript: data (scripting is off)
        }
    }
    let root = tb.newNode(.element, name: "html", tag: .html)
    tb.doc.parserAppend(root)
    tb.open = [root]
    if context.kind == .element && context.namespace == .html && context.tag == .template {
        tb.templateModes.append(.inTemplate)
    }
    tb.resetInsertionMode()
    var f: HTMLNode? = context
    var guardCount = 0
    while let n = f, guardCount < 100_000 {
        if n.kind == .element && n.namespace == .html && n.tag == .form { tb.formElement = n; break }
        f = n.parent
        guardCount += 1
    }
    tb.run()
    tb.tokenizer.tb = nil
    let frag = owner.createDocumentFragment()
    let kids = root.children
    root.children = []
    for c in kids { frag.parserAppend(c) }   // adopts into the owner document
    frag.truncated = tb.doc.truncated || cut
    frag.assignIndices()
    return frag
}

public func htmlParseFragment(_ string: String, context: HTMLNode,
                              limits: HTMLParseLimits = HTMLParseLimits()) -> HTMLNode {
    htmlParseFragment(Array(string.utf8), context: context, limits: limits)
}

public func htmlParse(_ string: String, limits: HTMLParseLimits = HTMLParseLimits()) -> HTMLNode {
    htmlParse(Array(string.utf8), limits: limits)
}

/// The html5lib "tree dump" format (one node per line, `| ` prefix,
/// two-space indentation per level, attributes sorted by name) of a
/// document's or fragment's children. A template's contents appear as a
/// `content` line under it.
public func htmlTreeDump(_ doc: HTMLNode) -> String {
    var out: [UInt8] = []
    func put(_ s: String) { out.append(contentsOf: s.utf8) }
    // Explicit stack of (node, depth).
    var stack: [(HTMLNode, Int)] = []
    var i = doc.children.count - 1
    while i >= 0 { stack.append((doc.children[i], 0)); i -= 1 }
    while let (n, depth) = stack.popLast() {
        put("| ")
        var d = 0
        while d < depth { put("  "); d += 1 }
        switch n.kind {
        case .document: break
        case .documentFragment: put("content")
        case .doctype:
            put("<!DOCTYPE ")
            put(n.name)
            if n.publicID != nil || n.systemID != nil {
                put(" \"")
                put(n.publicID ?? "")
                put("\" \"")
                put(n.systemID ?? "")
                put("\"")
            }
            put(">")
        case .comment:
            put("<!-- ")
            out.append(contentsOf: n.data)
            put(" -->")
        case .text:
            put("\"")
            out.append(contentsOf: n.data)
            put("\"")
        case .element:
            put("<")
            switch n.namespace {
            case .svg: put("svg ")
            case .mathml: put("math ")
            case .html: break
            }
            put(n.name)
            put(">")
            // Attributes sorted by display name (insertion sort; lists are short).
            var attrs: [(String, String)] = []
            for at in n.attributes {
                attrs.append((at.isNamespaced ? htmlReplaceColon(at.name) : at.name, at.value))
            }
            var a = 1
            while a < attrs.count {
                var b = a
                while b > 0 && htmlBytesLess(attrs[b].0, attrs[b - 1].0) {
                    attrs.swapAt(b, b - 1)
                    b -= 1
                }
                a += 1
            }
            for at in attrs {
                out.append(0x0a)
                put("| ")
                var d2 = 0
                while d2 <= depth { put("  "); d2 += 1 }
                put(at.0)
                put("=\"")
                put(at.1)
                put("\"")
            }
        }
        out.append(0x0a)
        if n.kind == .element, let t = n.templateContents { stack.append((t, depth + 1)) }
        var k = n.children.count - 1
        while k >= 0 { stack.append((n.children[k], depth + 1)); k -= 1 }
    }
    return String(decoding: out, as: UTF8.self)
}

private func htmlBytesLess(_ a: String, _ b: String) -> Bool {
    var ia = a.utf8.makeIterator()
    var ib = b.utf8.makeIterator()
    while true {
        let x = ia.next(), y = ib.next()
        guard let xx = x else { return y != nil }
        guard let yy = y else { return false }
        if xx != yy { return xx < yy }
    }
}

private func htmlReplaceColon(_ s: String) -> String {
    var out: [UInt8] = []
    var done = false
    for b in s.utf8 {
        if b == 0x3a && !done { out.append(0x20); done = true } else { out.append(b) }
    }
    return String(decoding: out, as: UTF8.self)
}
