// Public entry points: parse, and the html5lib "tree dump" serializer.

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
    doc.assignIndices()
    return doc
}

public func htmlParse(_ string: String, limits: HTMLParseLimits = HTMLParseLimits()) -> HTMLNode {
    htmlParse(Array(string.utf8), limits: limits)
}

/// The html5lib "tree dump" format (one node per line, `| ` prefix,
/// two-space indentation per level, attributes sorted by name).
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
