// A small XML parser for hostile input (ROADMAP Phase 8J): elements,
// attributes, namespaces, character references and the five predefined
// entities, CDATA, comments. Processing instructions and the XML
// declaration are skipped. A DOCTYPE (internal subset included) is skipped
// and never interpreted: there are no custom or external entities, so no
// billion-laughs. An unknown entity reference stays as literal text.
//
// The parser is lenient, like a recovering browser parser rather than a
// validating one: a mismatched end tag closes up to the matching open
// element (or is ignored), and the document ends wherever the input does.
// `XMLDocument.wellFormed` says whether anything had to be recovered.
// Limits (XMLLimits) bound input size, depth, node count and attributes.

let xmlNamespaceSVG = "http://www.w3.org/2000/svg"
let xmlNamespaceXLink = "http://www.w3.org/1999/xlink"
let xmlNamespaceXML = "http://www.w3.org/XML/1998/namespace"

struct XMLLimits {
    var maxInputBytes = 8 << 20
    var maxDepth = 256
    var maxNodes = 200_000
    var maxAttributes = 512
    /// Total bytes of text and attribute values kept.
    var maxTextBytes = 16 << 20
    init() {}
}

struct XMLAttribute {
    /// The qualified name as written ("xlink:href", "viewBox").
    var name: String
    var localName: String
    /// Namespace URI of the prefix ("" for unprefixed attributes).
    var namespace: String
    var value: String
}

enum XMLNodeKind: UInt8 { case element, text }

final class XMLNode {
    let kind: XMLNodeKind
    /// Element: the qualified name. Text: "".
    let name: String
    let localName: String
    /// Element namespace URI ("" if none is in scope).
    let namespace: String
    var attributes: [XMLAttribute]
    /// Text content (UTF-8).
    var text: [UInt8]
    unowned(unsafe) var parent: XMLNode?
    var children: [XMLNode] = []

    init(kind: XMLNodeKind, name: String, localName: String, namespace: String, attributes: [XMLAttribute] = [], text: [UInt8] = []) {
        self.kind = kind; self.name = name; self.localName = localName; self.namespace = namespace
        self.attributes = attributes; self.text = text
    }

    /// Value of the attribute with this qualified name.
    func attribute(_ name: String) -> String? {
        for a in attributes where a.name == name { return a.value }
        return nil
    }

    /// Value of an attribute by namespace and local name.
    func attribute(namespace: String, _ local: String) -> String? {
        for a in attributes where a.localName == local && a.namespace == namespace { return a.value }
        return nil
    }

    var textContent: String {
        var out: [UInt8] = []
        var stack: [XMLNode] = [self]
        var budget = 1_000_000
        while let n = stack.popLast(), budget > 0 {
            budget -= 1
            if n.kind == .text { out.append(contentsOf: n.text); continue }
            var i = n.children.count - 1
            while i >= 0 { stack.append(n.children[i]); i -= 1 }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

final class XMLDocument {
    var root: XMLNode?
    var wellFormed = true
    /// A limit cut the parse short.
    var truncated = false
    var nodeCount = 0
    init() {}
}

private struct XMLNSScope {
    var prefix: String
    var uri: String
    var depth: Int
}

/// Parse UTF-8 bytes (a UTF-8 BOM is skipped). Never traps.
func xmlParse(_ input: [UInt8], limits: XMLLimits = XMLLimits()) -> XMLDocument {
    var p = XMLParser(input, limits)
    p.run()
    return p.doc
}

func xmlParse(_ s: String, limits: XMLLimits = XMLLimits()) -> XMLDocument { xmlParse(Array(s.utf8), limits: limits) }

private func xmlIsSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d }
private func xmlIsNameChar(_ c: UInt8) -> Bool {
    switch c {
    case 0x61...0x7a, 0x41...0x5a, 0x30...0x39, 0x2d, 0x2e, 0x5f, 0x3a: return true
    default: return c >= 0x80
    }
}

private struct XMLParser {
    let b: [UInt8]
    let end: Int
    var i = 0
    let limits: XMLLimits
    let doc = XMLDocument()
    var stack: [XMLNode] = []
    var scopes: [XMLNSScope] = []
    var textBytes = 0
    var pendingText: [UInt8] = []

    init(_ input: [UInt8], _ limits: XMLLimits) {
        b = input
        self.limits = limits
        end = min(input.count, max(0, limits.maxInputBytes))
        if input.count > end { doc.truncated = true }
        if end >= 3 && input[0] == 0xef && input[1] == 0xbb && input[2] == 0xbf { i = 3 }
    }

    func at(_ k: Int) -> UInt8 { k < end && k >= 0 ? b[k] : 0 }

    func startsWith(_ s: StaticString, _ k: Int) -> Bool {
        let n = s.utf8CodeUnitCount
        if k + n > end { return false }
        let p = s.utf8Start
        for j in 0..<n where b[k + j] != p[j] { return false }
        return true
    }

    /// Index of the first occurrence of `s` at or after k, or end.
    func find(_ s: StaticString, from k: Int) -> Int {
        let n = s.utf8CodeUnitCount
        let p = s.utf8Start
        guard n > 0 else { return k }
        var j = k
        while j + n <= end {
            if b[j] == p[0] {
                var ok = true
                for q in 1..<n where b[j + q] != p[q] { ok = false; break }
                if ok { return j }
            }
            j += 1
        }
        return end
    }

    mutating func run() {
        while i < end && !doc.truncated {
            if b[i] == 0x3c {
                flushText()
                if startsWith("<!--", i) {
                    let e = find("-->", from: i + 4)
                    if e >= end { doc.wellFormed = false }
                    i = min(end, e + 3)
                } else if startsWith("<![CDATA[", i) {
                    let s = i + 9
                    let e = find("]]>", from: s)
                    if e >= end { doc.wellFormed = false }
                    appendText(s, e)
                    flushText()
                    i = min(end, e + 3)
                } else if startsWith("<?", i) {
                    let e = find("?>", from: i + 2)
                    i = min(end, e + 2)
                } else if startsWith("<!", i) {
                    skipDoctype()
                } else if at(i + 1) == 0x2f {
                    endTag()
                } else if xmlIsNameChar(at(i + 1)) {
                    startTag()
                } else {
                    doc.wellFormed = false
                    appendText(i, i + 1)
                    i += 1
                }
            } else {
                // Text up to the next '<'.
                var e = i
                while e < end && b[e] != 0x3c { e += 1 }
                appendDecoded(i, e)
                i = e
            }
        }
        flushText()
        if !stack.isEmpty { doc.wellFormed = false }
    }

    /// <!DOCTYPE ...> with an optional [internal subset]: skipped, quotes and
    /// brackets respected, nothing interpreted.
    mutating func skipDoctype() {
        var j = i + 2
        var bracket = 0
        var quote: UInt8 = 0
        var steps = 0
        while j < end && steps < 1 << 24 {
            steps += 1
            let c = b[j]
            if quote != 0 { if c == quote { quote = 0 }; j += 1; continue }
            if c == 0x22 || c == 0x27 { quote = c }
            else if c == 0x5b { bracket += 1 }
            else if c == 0x5d { bracket = max(0, bracket - 1) }
            else if c == 0x3e && bracket == 0 { j += 1; break }
            j += 1
        }
        i = min(j, end)
    }

    mutating func countNode() -> Bool {
        if doc.nodeCount >= limits.maxNodes { doc.truncated = true; return false }
        doc.nodeCount += 1
        return true
    }

    mutating func appendText(_ s: Int, _ e: Int) {
        if e <= s || stack.isEmpty { return }
        let n = e - s
        if textBytes + n > limits.maxTextBytes { doc.truncated = true; return }
        textBytes += n
        pendingText.append(contentsOf: b[s..<e])
    }

    mutating func appendDecoded(_ s: Int, _ e: Int) {
        if e <= s || stack.isEmpty { return }
        var out: [UInt8] = []
        decode(s, e, into: &out, attr: false)
        if textBytes + out.count > limits.maxTextBytes { doc.truncated = true; return }
        textBytes += out.count
        pendingText.append(contentsOf: out)
    }

    mutating func flushText() {
        if pendingText.isEmpty { return }
        defer { pendingText = [] }
        guard let parent = stack.last, countNode() else { return }
        if let last = parent.children.last, last.kind == .text {
            last.text.append(contentsOf: pendingText)
            return
        }
        let t = XMLNode(kind: .text, name: "", localName: "", namespace: "", text: pendingText)
        t.parent = parent
        parent.children.append(t)
    }

    /// Decode character and predefined entity references in b[s..<e].
    /// Attribute values also normalize tab/newline/CR to spaces.
    func decode(_ s: Int, _ e: Int, into out: inout [UInt8], attr: Bool) {
        var k = s
        while k < e {
            let c = b[k]
            if c == 0x26 {
                var semi = k + 1
                while semi < e && semi - k <= 12 && b[semi] != 0x3b { semi += 1 }
                if semi < e && b[semi] == 0x3b {
                    if let cp = entity(k + 1, semi) {
                        xmlAppendUTF8(cp, &out)
                        k = semi + 1
                        continue
                    }
                }
                out.append(c); k += 1
                continue
            }
            if attr && (c == 0x09 || c == 0x0a || c == 0x0d) {
                // CRLF counts as one newline.
                if c == 0x0d && k + 1 < e && b[k + 1] == 0x0a { k += 1 }
                out.append(0x20); k += 1; continue
            }
            if !attr && c == 0x0d {
                out.append(0x0a)
                if k + 1 < e && b[k + 1] == 0x0a { k += 1 }
                k += 1; continue
            }
            out.append(c); k += 1
        }
    }

    func entity(_ s: Int, _ e: Int) -> UInt32? {
        let n = e - s
        if n <= 0 { return nil }
        if b[s] == 0x23 {
            var v: UInt32 = 0
            var k = s + 1
            var hex = false
            if k < e && (b[k] == 0x78) { hex = true; k += 1 }
            if k >= e { return nil }
            while k < e {
                let c = b[k]
                var d: UInt32
                switch c {
                case 0x30...0x39: d = UInt32(c - 0x30)
                case 0x61...0x66 where hex: d = UInt32(c - 0x61 + 10)
                case 0x41...0x46 where hex: d = UInt32(c - 0x41 + 10)
                default: return nil
                }
                v = v * (hex ? 16 : 10) + d
                if v > 0x10ffff { return nil }
                k += 1
            }
            if v == 0 || (v >= 0xd800 && v <= 0xdfff) { return 0xfffd }
            return v
        }
        func eq(_ w: StaticString) -> Bool {
            n == w.utf8CodeUnitCount && startsWith(w, s)
        }
        if eq("lt") { return 0x3c }
        if eq("gt") { return 0x3e }
        if eq("amp") { return 0x26 }
        if eq("quot") { return 0x22 }
        if eq("apos") { return 0x27 }
        if eq("nbsp") { return 0xa0 }   // common in hand-written SVG; harmless
        return nil
    }

    mutating func readName() -> String? {
        let s = i
        while i < end && xmlIsNameChar(b[i]) { i += 1 }
        if i == s { return nil }
        return String(decoding: b[s..<i], as: UTF8.self)
    }

    mutating func skipSpace() { while i < end && xmlIsSpace(b[i]) { i += 1 } }

    func split(_ q: String) -> (String, String) {
        var pre: [UInt8] = []
        var local: [UInt8] = []
        var seen = false
        for c in q.utf8 {
            if c == 0x3a && !seen { seen = true; continue }
            if seen { local.append(c) } else { pre.append(c) }
        }
        if !seen { return ("", q) }
        return (String(decoding: pre, as: UTF8.self), String(decoding: local, as: UTF8.self))
    }

    func lookup(_ prefix: String) -> String {
        if prefix == "xml" { return xmlNamespaceXML }
        var k = scopes.count - 1
        while k >= 0 {
            if scopes[k].prefix == prefix { return scopes[k].uri }
            k -= 1
        }
        // Undeclared xlink: is common in sloppy files.
        if prefix == "xlink" { return xmlNamespaceXLink }
        return ""
    }

    mutating func startTag() {
        i += 1
        guard let qname = readName() else { doc.wellFormed = false; return }
        var raw: [(String, String)] = []
        var selfClose = false
        var steps = 0
        while i < end && steps < 100_000 {
            steps += 1
            skipSpace()
            if i >= end { break }
            let c = b[i]
            if c == 0x3e { i += 1; break }
            if c == 0x2f && at(i + 1) == 0x3e { selfClose = true; i += 2; break }
            guard let an = readName() else {
                doc.wellFormed = false
                i += 1
                continue
            }
            skipSpace()
            var value = ""
            if at(i) == 0x3d {
                i += 1
                skipSpace()
                let q = at(i)
                if q == 0x22 || q == 0x27 {
                    let s = i + 1
                    var e = s
                    while e < end && b[e] != q { e += 1 }
                    if e >= end { doc.wellFormed = false }
                    var out: [UInt8] = []
                    decode(s, min(e, end), into: &out, attr: true)
                    if textBytes + out.count > limits.maxTextBytes { doc.truncated = true; return }
                    textBytes += out.count
                    value = String(decoding: out, as: UTF8.self)
                    i = min(end, e + 1)
                } else {
                    // Unquoted (not XML, but recover).
                    doc.wellFormed = false
                    let s = i
                    while i < end && !xmlIsSpace(b[i]) && b[i] != 0x3e { i += 1 }
                    var out: [UInt8] = []
                    decode(s, i, into: &out, attr: true)
                    value = String(decoding: out, as: UTF8.self)
                }
            } else { doc.wellFormed = false }
            if raw.count < limits.maxAttributes {
                var dup = false
                for (n, _) in raw where n == an { dup = true; break }
                if dup { doc.wellFormed = false } else { raw.append((an, value)) }
            }
        }
        if stack.count >= limits.maxDepth {
            doc.wellFormed = false
            doc.truncated = true
            return
        }
        guard countNode() else { return }
        let depth = stack.count + 1
        // Namespace declarations first.
        for (n, v) in raw {
            if n == "xmlns" { scopes.append(XMLNSScope(prefix: "", uri: v, depth: depth)) }
            else if n.utf8.count > 6 && n.hasPrefix("xmlns:") {
                scopes.append(XMLNSScope(prefix: String(n.dropFirst(6)), uri: v, depth: depth))
            }
        }
        var attrs: [XMLAttribute] = []
        attrs.reserveCapacity(raw.count)
        for (n, v) in raw {
            let (pre, local) = split(n)
            let ns: String
            if pre.isEmpty { ns = n == "xmlns" ? "http://www.w3.org/2000/xmlns/" : "" }
            else if pre == "xmlns" { ns = "http://www.w3.org/2000/xmlns/" }
            else { ns = lookup(pre) }
            attrs.append(XMLAttribute(name: n, localName: local, namespace: ns, value: v))
        }
        let (pre, local) = split(qname)
        let el = XMLNode(kind: .element, name: qname, localName: local, namespace: lookup(pre), attributes: attrs)
        if let parent = stack.last {
            el.parent = parent
            parent.children.append(el)
        } else if doc.root == nil {
            doc.root = el
        } else {
            // A second root element: ignore it (and its subtree).
            doc.wellFormed = false
            if !selfClose { skipSubtree(qname) }
            popScopes(depth)
            return
        }
        if selfClose { popScopes(depth) } else { stack.append(el) }
    }

    /// Skip to the end tag matching an ignored element (depth-counted).
    mutating func skipSubtree(_ name: String) {
        var d = 1
        var steps = 0
        while i < end && d > 0 && steps < 1 << 24 {
            steps += 1
            if b[i] == 0x3c {
                if at(i + 1) == 0x2f { d -= 1 }
                else if xmlIsNameChar(at(i + 1)) {
                    var j = i + 1
                    while j < end && b[j] != 0x3e { j += 1 }
                    if !(j > 0 && j < end && b[j - 1] == 0x2f) { d += 1 }
                    i = j
                    continue
                }
            }
            i += 1
        }
        while i < end && b[i] != 0x3e { i += 1 }
        i = min(end, i + 1)
    }

    mutating func popScopes(_ depth: Int) {
        while let s = scopes.last, s.depth >= depth { scopes.removeLast() }
    }

    mutating func endTag() {
        i += 2
        let name = readName() ?? ""
        while i < end && b[i] != 0x3e { i += 1 }
        i = min(end, i + 1)
        // Close up to the matching open element; ignore a stray end tag.
        var k = stack.count - 1
        while k >= 0 && stack[k].name != name { k -= 1 }
        if k < 0 { doc.wellFormed = false; return }
        if k != stack.count - 1 { doc.wellFormed = false }
        while stack.count > k { stack.removeLast() }
        popScopes(k + 1)
        if stack.isEmpty {
            // Anything after the root element is ignored (comments, PIs, space).
            i = end
        }
    }
}

func xmlAppendUTF8(_ c: UInt32, _ out: inout [UInt8]) {
    if c < 0x80 { out.append(UInt8(c)) }
    else if c < 0x800 {
        out.append(UInt8(0xc0 | (c >> 6))); out.append(UInt8(0x80 | (c & 0x3f)))
    } else if c < 0x10000 {
        out.append(UInt8(0xe0 | (c >> 12))); out.append(UInt8(0x80 | ((c >> 6) & 0x3f))); out.append(UInt8(0x80 | (c & 0x3f)))
    } else {
        out.append(UInt8(0xf0 | (c >> 18))); out.append(UInt8(0x80 | ((c >> 12) & 0x3f)))
        out.append(UInt8(0x80 | ((c >> 6) & 0x3f))); out.append(UInt8(0x80 | (c & 0x3f)))
    }
}
