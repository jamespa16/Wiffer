// HTML tree builder (WHATWG "Tree construction"): infrastructure shared by
// the insertion modes in HTMLModes.swift: the stack of open elements, the
// list of active formatting elements, scope checks, insertion, and the
// adoption agency algorithm.
//
// Fragment parsing (a context element, "adjusted current node") and
// `<template>` (the "in template" mode, the stack of template insertion
// modes, contents as a separate DocumentFragment) follow the spec. Not
// implemented: scripting (the parser behaves as if scripting is disabled),
// parse error reporting. Foreign content (svg/math) is handled with generic
// namespaced elements.

public struct HTMLParseLimits {
    /// Input beyond this many bytes is ignored.
    public var maxInputBytes: Int
    /// Parsing stops once the tree has this many nodes.
    public var maxNodes: Int
    /// Open-element depth cap: deeper elements close the deepest open one
    /// first, so the tree never gets deeper than this (min 16).
    public var maxDepth: Int

    public init(maxInputBytes: Int = 16 << 20, maxNodes: Int = 300_000, maxDepth: Int = 512) {
        self.maxInputBytes = maxInputBytes
        self.maxNodes = maxNodes
        self.maxDepth = maxDepth
    }
}

enum HTMLMode {
    case initial, beforeHtml, beforeHead, inHead, inHeadNoscript, afterHead
    case inBody, text
    case inTable, inTableText, inCaption, inColumnGroup, inTableBody, inRow, inCell
    case inSelect, inSelectInTable
    case afterBody, inFrameset, afterFrameset, afterAfterBody, afterAfterFrameset
    case inTemplate
}

enum HTMLScope { case regular, listItem, button, table, select }

struct HTMLStartToken {
    var name: String
    var tag: HTMLTag
    var attrs: [HTMLAttribute]
    var selfClosing: Bool
}

struct HTMLEndToken {
    var name: String
    var tag: HTMLTag
}

final class HTMLTreeBuilder {
    let doc = HTMLNode(kind: .document)
    var tokenizer: HTMLTokenizer
    let limits: HTMLParseLimits
    var stopped = false
    var nodeCount = 1

    var mode: HTMLMode = .initial
    var originalMode: HTMLMode = .initial
    var open: [HTMLNode] = []
    /// nil entries are markers.
    var afe: [HTMLNode?] = []
    var headElement: HTMLNode? = nil
    var formElement: HTMLNode? = nil
    var framesetOK = true
    var fosterParenting = false
    var quirks = false
    var ignoreLF = false
    var tableText: [UInt32] = []
    var tableTextHasNonSpace = false
    /// Fragment parsing: the context element (nil for a document parse).
    var context: HTMLNode? = nil
    /// The stack of template insertion modes.
    var templateModes: [HTMLMode] = []
    /// The document's "allow declarative shadow roots" (htmlParse: true;
    /// fragment parsing only for the setHTMLUnsafe-style entry points).
    var allowDeclarativeShadowRoots = false
    /// Shadow roots attached by declarative shadow DOM (slots are assigned
    /// once the parse is done).
    var shadowRoots: [HTMLNode] = []

    init(input: [UInt32], limits: HTMLParseLimits) {
        self.limits = limits
        self.tokenizer = HTMLTokenizer(input: input)
        self.tokenizer.tb = self
    }

    func run() {
        tokenizer.run()
        doc.truncated = doc.truncated || stopped
    }

    // ------------------------------------------------------------ helpers

    var current: HTMLNode { open.last ?? doc }

    /// The "adjusted current node": the context element when parsing a
    /// fragment and only the root html element is open.
    var adjustedCurrent: HTMLNode? {
        if let c = context, open.count == 1 { return c }
        return open.last
    }

    var templateOnStack: Bool {
        var i = open.count - 1
        while i >= 0 { if isHTML(open[i], .template) { return true }; i -= 1 }
        return false
    }

    @inline(__always) func isHTML(_ n: HTMLNode, _ t: HTMLTag) -> Bool {
        n.tag == t && n.namespace == .html && n.kind == .element
    }
    @inline(__always) func currentIs(_ t: HTMLTag) -> Bool {
        guard let n = open.last else { return false }
        return isHTML(n, t)
    }

    func newNode(_ kind: HTMLNodeKind, name: String = "", tag: HTMLTag = .unknown,
                 ns: HTMLNamespace = .html, attrs: [HTMLAttribute] = [], data: [UInt8] = []) -> HTMLNode {
        nodeCount += 1
        if nodeCount > limits.maxNodes && !stopped {
            stopped = true
            doc.truncated = true
        }
        let n = HTMLNode(kind: kind, name: name, tag: tag, namespace: ns, attributes: attrs, data: data)
        doc.registerNode(n)
        return n
    }

    func clone(_ n: HTMLNode) -> HTMLNode {
        newNode(.element, name: n.name, tag: n.tag, ns: n.namespace, attrs: n.attributes)
    }

    var inForeignContent: Bool {
        guard let n = adjustedCurrent else { return false }
        return n.namespace != .html
    }

    // ------------------------------------------------------- insertion

    /// The "appropriate place for inserting a node": (parent, insert before).
    func appropriatePlace(_ override: HTMLNode? = nil) -> (HTMLNode, HTMLNode?) {
        let target = override ?? current
        var parent = target
        var before: HTMLNode? = nil
        if fosterParenting && target.kind == .element && target.namespace == .html {
            switch target.tag {
            case .table, .tbody, .tfoot, .thead, .tr:
                var lastTemplate = -1, lastTable = -1
                var i = open.count - 1
                while i >= 0 && (lastTemplate < 0 || lastTable < 0) {
                    if lastTemplate < 0 && isHTML(open[i], .template) { lastTemplate = i }
                    if lastTable < 0 && isHTML(open[i], .table) { lastTable = i }
                    i -= 1
                }
                if lastTemplate >= 0 && (lastTable < 0 || lastTemplate > lastTable) {
                    parent = open[lastTemplate]
                } else if lastTable < 0 {
                    parent = open.first ?? doc
                } else if let p = open[lastTable].parent {
                    parent = p
                    before = open[lastTable]
                } else {
                    parent = lastTable > 0 ? open[lastTable - 1] : open[0]
                }
            default: break
            }
        }
        if parent.kind == .element && parent.namespace == .html && parent.tag == .template,
           let content = parent.templateContents {
            return (content, nil)
        }
        return (parent, before)
    }

    /// A start tag "template" in the "in head" rules, with declarative
    /// shadow DOM: `<template shadowrootmode=open|closed>` attaches a shadow
    /// root to the adjusted current node and parses its contents into it
    /// (the template element itself never enters the tree).
    func templateStartTag(_ t: HTMLStartToken) {
        var modeAttr: HTMLShadowRootMode? = nil
        var clonable = false, serializable = false, delegates = false
        var slotAssignment = HTMLSlotAssignmentMode.named
        for a in t.attrs {
            switch a.name {
            case "shadowrootmode":
                let v = htmlLowerASCII(a.value)
                if v == "open" { modeAttr = .open } else if v == "closed" { modeAttr = .closed }
            case "shadowrootclonable": clonable = true
            case "shadowrootserializable": serializable = true
            case "shadowrootdelegatesfocus": delegates = true
            case "shadowrootslotassignment": if htmlLowerASCII(a.value) == "manual" { slotAssignment = .manual }
            default: break
            }
        }
        let hostCandidate = adjustedCurrent
        guard let mode = modeAttr, allowDeclarativeShadowRoots, let host = hostCandidate, host !== open.first else {
            insertHTML(t)
            pushMarker()
            framesetOK = false
            self.mode = .inTemplate
            templateModes.append(.inTemplate)
            return
        }
        pushMarker()
        framesetOK = false
        self.mode = .inTemplate
        templateModes.append(.inTemplate)
        makeRoom()
        let template = newNode(.element, name: t.name, tag: t.tag, attrs: t.attrs)
        if !host.isShadowHost, let shadow = try? host.attachShadow(mode: mode, delegatesFocus: delegates,
                                                                  slotAssignment: slotAssignment,
                                                                  clonable: clonable, serializable: serializable) {
            shadow.rare?.shadow?.declarative = true
            shadow.rare?.shadow?.availableToElementInternals = true
            template.templateStorage = shadow
            shadowRoots.append(shadow)
        } else {
            let (parent, before) = appropriatePlace()
            parent.parserInsert(template, before: before)
        }
        open.append(template)
    }

    func makeRoom() {
        if open.count >= max(16, limits.maxDepth) { open.removeLast() }
    }

    @discardableResult
    func insertElement(name: String, tag: HTMLTag, ns: HTMLNamespace = .html,
                       attrs: [HTMLAttribute], push: Bool = true) -> HTMLNode {
        makeRoom()
        let node = newNode(.element, name: name, tag: tag, ns: ns, attrs: attrs)
        let (parent, before) = appropriatePlace()
        parent.parserInsert(node, before: before)
        if push { open.append(node) }
        return node
    }

    @discardableResult
    func insertHTML(_ t: HTMLStartToken) -> HTMLNode {
        insertElement(name: t.name, tag: t.tag, attrs: t.attrs)
    }

    /// Void element: insert without leaving it open.
    func insertVoid(_ t: HTMLStartToken) {
        insertElement(name: t.name, tag: t.tag, attrs: t.attrs, push: false)
    }

    func insertHTMLNamed(_ tag: HTMLTag, _ name: String) -> HTMLNode {
        insertElement(name: name, tag: tag, attrs: [])
    }

    func insertCharacter(_ c: UInt32) {
        let (parent, before) = appropriatePlace()
        if parent.kind == .document { return }
        // Append to the adjacent text node if there is one.
        if let b = before {
            if let i = parent.childIndex(b), i > 0, parent.children[i - 1].kind == .text {
                htmlAppendUTF8(&parent.children[i - 1].data, c)
                return
            }
        } else if let last = parent.children.last, last.kind == .text {
            htmlAppendUTF8(&last.data, c)
            return
        }
        let t = newNode(.text)
        htmlAppendUTF8(&t.data, c)
        parent.parserInsert(t, before: before)
    }

    func insertComment(_ data: [UInt8], into parent: HTMLNode? = nil) {
        let n = newNode(.comment, data: data)
        if let p = parent { p.parserAppend(n); return }
        let (pp, before) = appropriatePlace()
        pp.parserInsert(n, before: before)
    }

    func pop() { if !open.isEmpty { open.removeLast() } }

    func popUntil(_ tag: HTMLTag) {
        while let n = open.last {
            open.removeLast()
            if isHTML(n, tag) { break }
        }
    }
    func popUntilHeading() {
        while let n = open.last {
            open.removeLast()
            if isHeading(n) { break }
        }
    }
    func popUntilNode(_ node: HTMLNode) {
        while let n = open.last {
            open.removeLast()
            if n === node { break }
        }
    }

    func isHeading(_ n: HTMLNode) -> Bool {
        guard n.kind == .element && n.namespace == .html else { return false }
        switch n.tag {
        case .h1, .h2, .h3, .h4, .h5, .h6: return true
        default: return false
        }
    }

    func indexInOpen(_ n: HTMLNode) -> Int? {
        var i = open.count - 1
        while i >= 0 { if open[i] === n { return i }; i -= 1 }
        return nil
    }

    func removeFromOpen(_ n: HTMLNode) {
        if let i = indexInOpen(n) { open.remove(at: i) }
    }

    // ----------------------------------------------------------- scope

    func isScopeBoundary(_ n: HTMLNode, _ s: HTMLScope) -> Bool {
        if s == .select {
            return !(n.namespace == .html && (n.tag == .optgroup || n.tag == .option))
        }
        switch n.namespace {
        case .html:
            switch n.tag {
            case .table, .template: return true
            case .applet, .caption, .html, .td, .th, .marquee, .object:
                return s != .table
            case .ol, .ul: return s == .listItem
            case .button: return s == .button
            default: return false
            }
        case .mathml:
            if s == .table { return false }
            switch n.name {
            case "mi", "mo", "mn", "ms", "mtext", "annotation-xml": return true
            default: return false
            }
        case .svg:
            if s == .table { return false }
            switch n.name {
            case "foreignObject", "desc", "title": return true
            default: return false
            }
        }
    }

    func hasInScope(_ s: HTMLScope, _ match: (HTMLNode) -> Bool) -> Bool {
        var i = open.count - 1
        while i >= 0 {
            let n = open[i]
            if match(n) { return true }
            if isScopeBoundary(n, s) { return false }
            i -= 1
        }
        return false
    }

    func hasInScope(_ tag: HTMLTag, _ s: HTMLScope = .regular) -> Bool {
        hasInScope(s) { self.isHTML($0, tag) }
    }
    func hasNodeInScope(_ node: HTMLNode, _ s: HTMLScope = .regular) -> Bool {
        hasInScope(s) { $0 === node }
    }
    func hasHeadingInScope() -> Bool {
        hasInScope(.regular) { self.isHeading($0) }
    }

    // ----------------------------------------------------- implied end tags

    func isImpliedEndTag(_ n: HTMLNode) -> Bool {
        guard n.kind == .element && n.namespace == .html else { return false }
        switch n.tag {
        case .dd, .dt, .li, .optgroup, .option, .p, .rb, .rp, .rt, .rtc: return true
        default: return false
        }
    }

    func generateImpliedEndTags(except: HTMLTag = .unknown) {
        while let n = open.last, isImpliedEndTag(n), n.tag != except { open.removeLast() }
    }
    func generateAllImpliedEndTags() {
        while let n = open.last {
            if isImpliedEndTag(n) { open.removeLast(); continue }
            if n.namespace == .html {
                switch n.tag {
                case .caption, .colgroup, .tbody, .td, .tfoot, .th, .thead, .tr: open.removeLast(); continue
                default: break
                }
            }
            break
        }
    }

    func closePElement() {
        generateImpliedEndTags(except: .p)
        popUntil(.p)
    }
    func closePIfInButtonScope() {
        if hasInScope(.p, .button) { closePElement() }
    }

    // ---------------------------------------------------------- categories

    func isSpecial(_ n: HTMLNode) -> Bool {
        switch n.namespace {
        case .html:
            switch n.tag {
            case .address, .applet, .area, .article, .aside, .base, .basefont, .bgsound, .blockquote,
                 .body, .br, .button, .caption, .center, .col, .colgroup, .dd, .details, .dir, .div,
                 .dl, .dt, .embed, .fieldset, .figcaption, .figure, .footer, .form, .frame, .frameset,
                 .h1, .h2, .h3, .h4, .h5, .h6, .head, .header, .hgroup, .hr, .html, .iframe, .img,
                 .input, .keygen, .li, .link, .listing, .main, .marquee, .menu, .meta, .nav, .noembed,
                 .noframes, .noscript, .object, .ol, .p, .param, .plaintext, .pre, .script, .search,
                 .section, .select, .source, .style, .summary, .table, .tbody, .td, .template,
                 .textarea, .tfoot, .th, .thead, .title, .tr, .track, .ul, .wbr, .xmp:
                return true
            default: return false
            }
        case .mathml:
            switch n.name {
            case "mi", "mo", "mn", "ms", "mtext", "annotation-xml": return true
            default: return false
            }
        case .svg:
            switch n.name {
            case "foreignObject", "desc", "title": return true
            default: return false
            }
        }
    }

    func isFormatting(_ tag: HTMLTag) -> Bool {
        switch tag {
        case .a, .b, .big, .code, .em, .font, .i, .nobr, .s, .small, .strike, .strong, .tt, .u: return true
        default: return false
        }
    }

    func isMathTextIntegrationPoint(_ n: HTMLNode) -> Bool {
        guard n.namespace == .mathml else { return false }
        switch n.name {
        case "mi", "mo", "mn", "ms", "mtext": return true
        default: return false
        }
    }

    func isHTMLIntegrationPoint(_ n: HTMLNode) -> Bool {
        switch n.namespace {
        case .svg:
            switch n.name {
            case "foreignObject", "desc", "title": return true
            default: return false
            }
        case .mathml:
            guard n.name == "annotation-xml", let e = n.attribute("encoding") else { return false }
            let l = htmlLowerASCII(e)
            return l == "text/html" || l == "application/xhtml+xml"
        case .html: return false
        }
    }

    // --------------------------------------------- active formatting elements

    func pushFormatting(_ node: HTMLNode) {
        var count = 0
        var firstMatch = -1
        var i = afe.count - 1
        while i >= 0 {
            guard let e = afe[i] else { break }
            if e.name == node.name && e.namespace == node.namespace && htmlSameAttrs(e.attributes, node.attributes) {
                count += 1
                firstMatch = i
            }
            i -= 1
        }
        if count >= 3 { afe.remove(at: firstMatch) }
        if afe.count >= 512 {
            if let k = afe.firstIndex(where: { $0 != nil }) { afe.remove(at: k) }
        }
        afe.append(node)
    }

    func pushMarker() { afe.append(nil) }

    func clearFormattingToMarker() {
        while let e = afe.popLast() { if e == nil { break } }
    }

    func afeIndex(_ n: HTMLNode) -> Int? {
        var i = afe.count - 1
        while i >= 0 { if let e = afe[i], e === n { return i }; i -= 1 }
        return nil
    }

    func reconstructFormatting() {
        guard !afe.isEmpty else { return }
        var i = afe.count - 1
        guard let last = afe[i] else { return }
        if indexInOpen(last) != nil { return }
        while i > 0 {
            i -= 1
            if let e = afe[i], indexInOpen(e) == nil { continue }
            i += 1
            break
        }
        while i < afe.count {
            if let e = afe[i] {
                makeRoom()
                let n = clone(e)
                let (parent, before) = appropriatePlace()
                parent.parserInsert(n, before: before)
                open.append(n)
                afe[i] = n
            }
            i += 1
        }
    }

    // ---------------------------------------------------- adoption agency

    func adoptionAgency(_ tag: HTMLTag, _ name: String) {
        if let cur = open.last, isHTML(cur, tag), afeIndex(cur) == nil {
            open.removeLast()
            return
        }
        var outer = 0
        while outer < 8 {
            outer += 1
            // Formatting element: last entry after the last marker with this tag.
            var feIdx = -1
            var i = afe.count - 1
            while i >= 0 {
                guard let e = afe[i] else { break }
                if isHTML(e, tag) { feIdx = i; break }
                i -= 1
            }
            if feIdx < 0 { anyOtherEndTag(name, tag); return }
            let fe = afe[feIdx]!
            guard let feStack = indexInOpen(fe) else { afe.remove(at: feIdx); return }
            if !hasNodeInScope(fe) { return }
            var furthestIdx = -1
            var k = feStack + 1
            while k < open.count {
                if isSpecial(open[k]) { furthestIdx = k; break }
                k += 1
            }
            if furthestIdx < 0 {
                while open.count > feStack { open.removeLast() }
                afe.remove(at: feIdx)
                return
            }
            let furthest = open[furthestIdx]
            let common = open[feStack - 1 >= 0 ? feStack - 1 : 0]
            var bookmark = feIdx
            var node = furthest
            var last = furthest
            var nodeIdx = furthestIdx
            var inner = 0
            while true {
                inner += 1
                nodeIdx -= 1
                if nodeIdx < 0 { break }
                node = open[nodeIdx]
                if node === fe { break }
                if inner > 3, let ai = afeIndex(node) {
                    afe.remove(at: ai)
                    if ai < bookmark { bookmark -= 1 }
                }
                guard let ai = afeIndex(node) else {
                    open.remove(at: nodeIdx)
                    continue
                }
                let n = clone(node)
                afe[ai] = n
                open[nodeIdx] = n
                node = n
                if last === furthest { bookmark = ai + 1 }
                last.parserDetach()
                node.parserAppend(last)
                last = node
            }
            // Insert `last` at the appropriate place with `common` as target.
            last.parserDetach()
            let (parent, before) = appropriatePlace(common)
            parent.parserInsert(last, before: before)
            let n = clone(fe)
            let moved = furthest.children
            furthest.children = []
            for c in moved { n.parserAppend(c) }
            furthest.parserAppend(n)
            if let ai = afeIndex(fe) {
                afe.remove(at: ai)
                if ai < bookmark { bookmark -= 1 }
            }
            afe.insert(n, at: min(max(bookmark, 0), afe.count))
            removeFromOpen(fe)
            if let fi = indexInOpen(furthest) { open.insert(n, at: fi + 1) } else { open.append(n) }
        }
    }

    /// "Any other end tag" in the body insertion mode.
    func anyOtherEndTag(_ name: String, _ tag: HTMLTag) {
        var i = open.count - 1
        while i >= 0 {
            let node = open[i]
            if node.namespace == .html && node.name == name {
                generateImpliedEndTags(except: node.tag)
                while open.count > i { open.removeLast() }
                return
            }
            if isSpecial(node) { return }
            i -= 1
        }
    }

    // ---------------------------------------------------- reset insertion mode

    func resetInsertionMode() {
        var i = open.count - 1
        while i >= 0 {
            var n = open[i]
            let isLast = i == 0
            if isLast, let c = context { n = c }
            if n.namespace == .html && n.kind == .element {
                switch n.tag {
                case .select:
                    var j = isLast ? -1 : i - 1
                    while j >= 0 {
                        let a = open[j]
                        if isHTML(a, .template) { break }
                        if isHTML(a, .table) { mode = .inSelectInTable; return }
                        j -= 1
                    }
                    mode = .inSelect
                    return
                case .td, .th:
                    if !isLast { mode = .inCell; return }
                case .tr: mode = .inRow; return
                case .tbody, .thead, .tfoot: mode = .inTableBody; return
                case .caption: mode = .inCaption; return
                case .colgroup: mode = .inColumnGroup; return
                case .table: mode = .inTable; return
                case .head:
                    if !isLast { mode = .inHead; return }
                case .body: mode = .inBody; return
                case .frameset: mode = .inFrameset; return
                case .template: mode = templateModes.last ?? .inBody; return
                case .html:
                    mode = headElement == nil ? .beforeHead : .afterHead
                    return
                default: break
                }
            }
            if isLast { mode = .inBody; return }
            i -= 1
        }
        mode = .inBody
    }

    // ---------------------------------------------------------- token entry

    func char(_ c: UInt32) {
        if stopped { return }
        if ignoreLF {
            ignoreLF = false
            if c == 0x0a { return }
        }
        if let n = adjustedCurrent, n.namespace != .html {
            if !(isMathTextIntegrationPoint(n) || isHTMLIntegrationPoint(n)) {
                foreignChar(c)
                return
            }
        }
        modeChar(c)
    }

    func startTag(name: String, attrs: [HTMLAttribute], selfClosing: Bool) {
        if stopped { return }
        ignoreLF = false
        let t = HTMLStartToken(name: name, tag: HTMLTag.lookup(name), attrs: attrs, selfClosing: selfClosing)
        dispatchStart(t)
    }

    func dispatchStart(_ t: HTMLStartToken) {
        if let n = adjustedCurrent, n.namespace != .html {
            var html = false
            if isMathTextIntegrationPoint(n) && t.name != "mglyph" && t.name != "malignmark" { html = true }
            else if n.namespace == .mathml && n.name == "annotation-xml" && t.name == "svg" { html = true }
            else if isHTMLIntegrationPoint(n) { html = true }
            if !html { foreignStart(t); return }
        }
        modeStart(t)
    }

    func endTag(name: String) {
        if stopped { return }
        ignoreLF = false
        let t = HTMLEndToken(name: name, tag: HTMLTag.lookup(name))
        dispatchEnd(t)
    }

    func dispatchEnd(_ t: HTMLEndToken) {
        if let n = adjustedCurrent, n.namespace != .html {
            foreignEnd(t)
            return
        }
        modeEnd(t)
    }

    func comment(_ data: [UInt8]) {
        if stopped { return }
        ignoreLF = false
        modeComment(data)
    }

    func doctype(name: [UInt8]?, publicID: [UInt8]?, systemID: [UInt8]?, forceQuirks: Bool) {
        if stopped { return }
        ignoreLF = false
        guard mode == .initial else { return }
        let n = newNode(.doctype, name: name.map { String(decoding: $0, as: UTF8.self) } ?? "")
        n.publicID = publicID.map { String(decoding: $0, as: UTF8.self) }
        n.systemID = systemID.map { String(decoding: $0, as: UTF8.self) }
        doc.parserAppend(n)
        quirks = htmlDoctypeQuirks(name: n.name, publicID: n.publicID, systemID: n.systemID, forceQuirks: forceQuirks)
        doc.docState?.quirks = quirks
        mode = .beforeHtml
    }

    func eof() {
        if stopped { return }
        modeEOF()
        stopped = true
    }
}

// ------------------------------------------------------------------ utils

func htmlLowerASCII(_ s: String) -> String {
    var needs = false
    for b in s.utf8 where b >= 0x41 && b <= 0x5a { needs = true; break }
    if !needs { return s }
    var out: [UInt8] = []
    out.reserveCapacity(s.utf8.count)
    for b in s.utf8 { out.append(b >= 0x41 && b <= 0x5a ? b + 0x20 : b) }
    return String(decoding: out, as: UTF8.self)
}

func htmlSameAttrs(_ a: [HTMLAttribute], _ b: [HTMLAttribute]) -> Bool {
    if a.count != b.count { return false }
    for x in a {
        var found = false
        for y in b where y.name == x.name { found = (y.value == x.value); break }
        if !found { return false }
    }
    return true
}

private func htmlHasPrefix(_ s: String, _ p: StaticString) -> Bool {
    let n = p.utf8CodeUnitCount
    if s.utf8.count < n { return false }
    let pp = p.utf8Start
    var i = 0
    for b in s.utf8 {
        if i >= n { break }
        if b != pp[i] { return false }
        i += 1
    }
    return true
}

func htmlDoctypeQuirks(name: String, publicID: String?, systemID: String?, forceQuirks: Bool) -> Bool {
    if forceQuirks || name != "html" { return true }
    if let s = systemID, htmlLowerASCII(s) == "http://www.ibm.com/data/dtd/v11/ibmxhtml1-transitional.dtd" { return true }
    guard let p0 = publicID else { return false }
    let p = htmlLowerASCII(p0)
    switch p {
    case "-//w3o//dtd w3 html strict 3.0//en//", "-/w3c/dtd html 4.0 transitional/en", "html": return true
    default: break
    }
    if htmlHasPrefix(p, "+//silmaril//dtd html pro v0r11 19970101//") || htmlHasPrefix(p, "-//as//dtd html 3.0 aswedit + extensions//")
        || htmlHasPrefix(p, "-//advasoft ltd//dtd html 3.0 aswedit + extensions//") || htmlHasPrefix(p, "-//ietf//dtd html")
        || htmlHasPrefix(p, "-//metrius//dtd metrius presentational//") || htmlHasPrefix(p, "-//microsoft//dtd internet explorer ")
        || htmlHasPrefix(p, "-//netscape comm. corp.//dtd ") || htmlHasPrefix(p, "-//o'reilly and associates//dtd html ")
        || htmlHasPrefix(p, "-//softquad") || htmlHasPrefix(p, "-//spyglass//dtd html 2.0 extended//")
        || htmlHasPrefix(p, "-//sq//dtd html 2.0 hotmetal + extensions//") || htmlHasPrefix(p, "-//sun microsystems corp.//dtd hotjava")
        || htmlHasPrefix(p, "-//w3c//dtd html 3") || htmlHasPrefix(p, "-//w3c//dtd html 4.0 ")
        || htmlHasPrefix(p, "-//w3c//dtd html experimental ") || htmlHasPrefix(p, "-//w3c//dtd w3 html//")
        || htmlHasPrefix(p, "-//w3o//dtd w3 html 3.0//") || htmlHasPrefix(p, "-//webtechs//dtd mozilla html") {
        return true
    }
    if systemID == nil && (htmlHasPrefix(p, "-//w3c//dtd html 4.01 frameset//") || htmlHasPrefix(p, "-//w3c//dtd html 4.01 transitional//")) {
        return true
    }
    return false
}
