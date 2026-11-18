// Box tree construction: computed styles parent-first, ::before/::after,
// list markers, replaced elements, display: contents, and the anonymous box
// fix-ups (inline runs among blocks, block-in-inline, table structure, flex
// items). Recursion is one level per element and is bounded by
// LayoutLimits.maxDepth; deeper elements generate no boxes.

final class LayoutBuilder {
    let resolver: CSSStyleResolver
    let state: LayoutStyleState
    let limits: LayoutLimits
    var boxCount = 0
    var nodeBoxes: [ObjectIdentifier: LayoutBox] = [:]
    var imageURLs: [String] = []
    var controls: [LayoutBox] = []
    private var seenImages: Set<String> = []

    init(resolver: CSSStyleResolver, state: LayoutStyleState, limits: LayoutLimits) {
        self.resolver = resolver
        self.state = state
        self.limits = limits
    }

    /// The box for the document element, or nil (no element or display: none).
    func build(_ doc: HTMLNode) -> LayoutBox? {
        guard let html = doc.kind == .document ? doc.documentElement : doc else { return nil }
        let holder = LayoutBox(kind: .block, node: nil, style: layoutAnonStyle(CSSComputedStyle(), .block))
        buildElement(html, into: holder, parentStyle: nil, depth: 0, deco: 0, decoColor: .black, center: false)
        guard let root = holder.children.first(where: { !$0.anonymous }) ?? holder.children.first else { return nil }
        root.parent = nil
        if root.inlineLevel { root.inlineLevel = false }
        if root.kind == .inline { root.kind = .block }
        return root
    }

    private func noteImage(_ url: String) {
        if url.isEmpty || seenImages.contains(url) { return }
        seenImages.insert(url)
        imageURLs.append(url)
    }

    private func newBox(_ kind: LayoutBoxKind, _ node: HTMLNode?, _ style: CSSComputedStyle) -> LayoutBox {
        boxCount += 1
        return LayoutBox(kind: kind, node: node, style: style)
    }

    // MARK: Elements

    /// Styles the element and makes its box (no children yet). Kept out of
    /// line so the recursive builder's frames hold no CSSComputedStyle
    /// (944 bytes each): the depth limit then bounds the stack.
    @inline(never)
    private func makeElementBox(_ node: HTMLNode, _ parentStyle: LayoutBox?, _ depth: Int,
                                _ deco: UInt8, _ decoColor: CSSColor, _ center: Bool) -> LayoutBox? {
        if node.namespace != .html && node.name != "svg" && node.name != "math" { return nil }
        let el = LayoutElement(node, state)
        var style = resolver.computeStyle(el, parent: parentStyle?.style, hints: layoutHints(node))
        if style.display == .none { return nil }
        if style.fontSize > limits.maxFontSize { style.fontSize = limits.maxFontSize }
        if style.fontSize != style.fontSize { style.fontSize = 16 }
        if let bg = style.backgroundImage { noteImage(bg) }
        let name = node.name

        if style.display == .contents && !layoutIsReplacedName(name) {
            // Holds the style for the children; never appended.
            let holder = LayoutBox(kind: .inline, node: node, style: style)
            holder.isContentsHolder = true
            holder.deco = deco; holder.decoColor = decoColor; holder.legacyCenter = center
            return holder
        }

        let replacedKind = layoutReplacedKind(node)
        var kind: LayoutBoxKind
        var inlineLevel = false
        if name == "br" {
            kind = .lineBreak; inlineLevel = true
        } else if replacedKind != .none {
            kind = .replaced
            inlineLevel = style.display.isInlineLevel
        } else {
            switch style.display {
            case .block, .listItem, .contents: kind = .block
            case .inline: kind = .inline; inlineLevel = true
            case .inlineBlock: kind = .block; inlineLevel = true
            case .table: kind = .table
            case .inlineTable: kind = .table; inlineLevel = true
            case .tableRowGroup, .tableHeaderGroup, .tableFooterGroup: kind = .rowGroup
            case .tableRow: kind = .row
            case .tableCell: kind = .cell
            case .tableCaption: kind = .caption
            case .tableColumn, .tableColumnGroup: return nil
            case .flex: kind = .flex
            case .inlineFlex: kind = .flex; inlineLevel = true
            case .none: return nil
            }
        }
        let box = newBox(kind, node, style)
        box.inlineLevel = inlineLevel
        box.replaced = replacedKind
        box.depth = depth
        if nodeBoxes[ObjectIdentifier(node)] == nil { nodeBoxes[ObjectIdentifier(node)] = box }

        // text-decoration propagates to in-flow descendants, but not into
        // atomic inlines, floats or absolutely positioned boxes.
        var d = deco, dc = decoColor
        if box.isOutOfFlow || box.isAtomicInline { d = 0 }
        if style.textDecoration.rawValue != 0 { d |= style.textDecoration.rawValue; dc = style.color }
        box.deco = d
        box.decoColor = dc
        let isCenter = name == "center" || ((name == "div" || name == "p" || name == "td" || name == "th" || name == "tr" || name == "tbody")
            && node.attribute("align").map { layoutLowerASCII($0) == "center" } == true)
        box.legacyCenter = isCenter || (center && style.textAlign == .center)
        if kind == .replaced {
            setUpReplaced(box, node)
            if replacedKind.isControl { controls.append(box) }
        } else if name == "button" {
            controls.append(box)
        }
        return box
    }

    private func buildElement(_ node: HTMLNode, into parent: LayoutBox, parentStyle: LayoutBox?, depth: Int,
                              deco: UInt8, decoColor: CSSColor, center: Bool) {
        if depth > limits.maxDepth || boxCount >= limits.maxBoxes { return }
        guard let box = makeElementBox(node, parentStyle, depth, deco, decoColor, center) else { return }
        if box.isContentsHolder {
            buildChildren(node, into: parent, styleBox: box, depth: depth + 1, deco: deco, decoColor: decoColor, center: center)
            return
        }
        if box.kind != .replaced && box.kind != .lineBreak {
            addPseudo(box, .before, depth)
            buildChildren(node, into: box, styleBox: box, depth: depth + 1, deco: box.deco, decoColor: box.decoColor, center: box.legacyCenter)
            addPseudo(box, .after, depth)
            if box.style.display == .listItem { makeMarker(box) }
            fixUp(box)
        }
        parent.append(box)
    }

    @inline(never)
    private func makeTextBox(_ c: HTMLNode, _ styleBox: LayoutBox, _ depth: Int, _ deco: UInt8, _ decoColor: CSSColor) -> LayoutBox {
        let t = newBox(.text, c, styleBox.style)
        t.inlineLevel = true
        t.raw = layoutTransform(textDecodeUTF8(c.data), styleBox.style.textTransform)
        t.deco = deco
        t.decoColor = decoColor
        t.depth = depth
        return t
    }

    private func buildChildren(_ node: HTMLNode, into box: LayoutBox, styleBox: LayoutBox, depth: Int,
                               deco: UInt8, decoColor: CSSColor, center: Bool) {
        // List numbering (ol start, li value).
        var counter = 1
        if node.name == "ol", let s = node.attribute("start"), let v = layoutParseInt(s) { counter = v }
        for c in node.children {
            if boxCount >= limits.maxBoxes { break }
            switch c.kind {
            case .element:
                let before = box.children.count
                buildElement(c, into: box, parentStyle: styleBox, depth: depth, deco: deco, decoColor: decoColor, center: center)
                if box.children.count > before, let li = box.children.last, li.node === c, li.style.display == .listItem {
                    if let v = c.attribute("value"), let k = layoutParseInt(v) { counter = k }
                    setListValue(li, counter)
                    counter = counter < Int.max - 1 ? counter + 1 : counter
                }
            case .text:
                if c.data.isEmpty { continue }
                box.append(makeTextBox(c, styleBox, depth, deco, decoColor))
            default:
                continue
            }
        }
    }

    @inline(never)
    private func setListValue(_ li: LayoutBox, _ counter: Int) {
        li.listValue = counter
        if let m = li.marker { m.listValue = counter; m.raw = layoutMarkerText(li.style.listStyleType, counter) }
        else if li.style.listStylePosition == .inside, let f = li.children.first, f.pseudo == .marker {
            f.raw = layoutMarkerText(li.style.listStyleType, counter)
        }
    }

    @inline(never)
    private func addPseudo(_ box: LayoutBox, _ which: LayoutPseudo, _ depth: Int) {
        guard let n = box.node else { return }
        guard let s = resolver.computePseudoStyle(LayoutElement(n, state), which == .before ? .before : .after,
                                                  elementStyle: box.style) else { return }
        let deco = box.deco, dc = box.decoColor
        if s.display == .none { return }
        var style = s
        if style.fontSize > limits.maxFontSize { style.fontSize = limits.maxFontSize }
        let kind: LayoutBoxKind
        var inl = false
        switch style.display {
        case .inline: kind = .inline; inl = true
        case .inlineBlock: kind = .block; inl = true
        case .flex: kind = .flex
        case .inlineFlex: kind = .flex; inl = true
        default: kind = .block
        }
        let p = newBox(kind, box.node, style)
        p.pseudo = which
        p.inlineLevel = inl
        p.depth = depth + 1
        var d = deco, c = dc
        if p.isOutOfFlow || p.isAtomicInline { d = 0 }
        if style.textDecoration.rawValue != 0 { d |= style.textDecoration.rawValue; c = style.color }
        p.deco = d; p.decoColor = c
        var text = ""
        for i in style.contentItems { text += i }
        if !text.isEmpty {
            let t = newBox(.text, box.node, style)
            t.pseudo = which
            t.inlineLevel = true
            t.raw = layoutTransform(textScalars(text), style.textTransform)
            t.deco = d; t.decoColor = c
            p.append(t)
        }
        if let bg = style.backgroundImage { noteImage(bg) }
        fixUp(p)
        box.append(p)
    }

    @inline(never)
    private func makeMarker(_ li: LayoutBox) {
        let s = li.style
        if s.listStyleType == .none { return }
        if s.listStylePosition == .inside {
            let t = newBox(.text, li.node, s)
            t.pseudo = .marker
            t.inlineLevel = true
            t.raw = layoutMarkerText(s.listStyleType, 1)
            t.parent = li
            li.children.insert(t, at: 0)
            return
        }
        let m = newBox(.marker, li.node, s)
        m.pseudo = .marker
        m.raw = layoutMarkerText(s.listStyleType, 1)
        m.parent = li
        li.marker = m
    }

    private func setUpReplaced(_ box: LayoutBox, _ node: HTMLNode) {
        switch box.replaced {
        case .image:
            if let s = node.attribute("src") { box.src = s; noteImage(s) }
            if let a = node.attribute("alt"), !a.isEmpty { box.label = a }
        case .button:
            if node.name == "input" {
                let t = layoutLowerASCII(node.attribute("type") ?? "")
                box.label = node.attribute("value") ?? (t == "reset" ? "Reset" : (t == "submit" ? "Submit" : (t == "file" ? "Choose File" : "")))
            }
        case .textInput, .password:
            box.label = node.attribute("value") ?? ""
            if box.label.isEmpty, let p = node.attribute("placeholder") { box.label = p; box.labelIsPlaceholder = true }
        case .select:
            var label: String? = nil
            var first: String? = nil
            node.walk { n in
                if n.kind == .element && n.name == "option" {
                    let txt = layoutCollapseSpaces(n.textContent)
                    if first == nil { first = txt }
                    if n.attribute("selected") != nil && label == nil { label = txt }
                    if box.options.count < 1000 { box.options.append(txt) }
                }
                return true
            }
            box.label = label ?? first ?? ""
        case .textarea:
            box.label = node.textContent
        default:
            break
        }
    }

    // MARK: Fix-ups

    @inline(never)
    private func fixUp(_ box: LayoutBox) {
        switch box.kind {
        case .inline:
            var hasBlock = false
            for c in box.children where !c.inlineLevel && !c.isOutOfFlow { hasBlock = true; break }
            if hasBlock {
                // Block-in-inline: the inline becomes a block box (a
                // simplification of the spec's split into anonymous blocks).
                box.kind = .block
                box.inlineLevel = false
                fixBlockContainer(box)
            }
        case .block, .cell, .caption:
            fixBlockContainer(box)
        case .table: fixTable(box)
        case .rowGroup: fixRowGroup(box)
        case .row: fixRow(box)
        case .flex: fixFlex(box)
        default: break
        }
    }

    private func isTableInternal(_ b: LayoutBox) -> Bool {
        b.kind == .row || b.kind == .rowGroup || b.kind == .cell || b.kind == .caption
    }

    private func isCollapsibleWhitespace(_ b: LayoutBox) -> Bool {
        guard b.kind == .text, b.style.whiteSpace.collapsesSpaces else { return false }
        for c in b.raw where !(c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d || c == 0x0c) { return false }
        return true
    }

    /// Wrap stray table parts in an anonymous table.
    private func wrapTableParts(_ box: LayoutBox) {
        var hasPart = false
        for c in box.children where isTableInternal(c) { hasPart = true; break }
        if !hasPart { return }
        var out: [LayoutBox] = []
        var cur: LayoutBox? = nil
        for c in box.children {
            if isTableInternal(c) || (cur != nil && isCollapsibleWhitespace(c)) {
                if cur == nil {
                    let t = newBox(.table, nil, layoutAnonStyle(box.style, .table))
                    t.anonymous = true
                    t.parent = box
                    out.append(t)
                    cur = t
                }
                cur!.append(c)
            } else {
                if let t = cur { fixTable(t) }
                cur = nil
                out.append(c)
            }
        }
        if let t = cur { fixTable(t) }
        box.children = out
    }

    private func fixBlockContainer(_ box: LayoutBox) {
        wrapTableParts(box)
        var hasBlock = false, hasInline = false
        for c in box.children {
            if c.isOutOfFlow { continue }
            if c.inlineLevel { hasInline = true } else { hasBlock = true }
        }
        if !hasBlock {
            box.childrenInline = hasInline || !box.children.isEmpty
            return
        }
        box.childrenInline = false
        if !hasInline { return }
        // Wrap each run of inline-level children (with the floats and
        // absolutely positioned boxes among them) in an anonymous block;
        // runs of collapsible whitespace disappear.
        var out: [LayoutBox] = []
        var run: [LayoutBox] = []
        func flush() {
            if run.isEmpty { return }
            var meaningful = false
            for c in run where !c.isOutOfFlow && !isCollapsibleWhitespace(c) { meaningful = true; break }
            if meaningful {
                let a = newBox(.block, nil, layoutAnonStyle(box.style, .block))
                a.anonymous = true
                a.childrenInline = true
                a.deco = box.deco; a.decoColor = box.decoColor
                a.legacyCenter = box.legacyCenter
                a.depth = box.depth + 1
                for c in run { a.append(c) }
                a.parent = box
                out.append(a)
            } else {
                for c in run where c.isOutOfFlow { out.append(c) }
            }
            run.removeAll()
        }
        for c in box.children {
            if c.inlineLevel || (c.isOutOfFlow && !run.isEmpty) { run.append(c) }
            else { flush(); out.append(c) }
        }
        flush()
        box.children = out
    }

    private func fixTable(_ t: LayoutBox) {
        var out: [LayoutBox] = []
        var group: LayoutBox? = nil   // anonymous row group collecting rows
        var row: LayoutBox? = nil     // anonymous row collecting cells
        var cell: LayoutBox? = nil    // anonymous cell collecting other content
        func endCell() { if let c = cell { fixBlockContainer(c) }; cell = nil }
        func endRow() { endCell(); row = nil }
        func ensureGroup() -> LayoutBox {
            if let g = group { return g }
            let g = newBox(.rowGroup, nil, layoutAnonStyle(t.style, .tableRowGroup))
            g.anonymous = true
            g.parent = t
            out.append(g)
            group = g
            return g
        }
        func ensureRow() -> LayoutBox {
            if let r = row { return r }
            let r = newBox(.row, nil, layoutAnonStyle(t.style, .tableRow))
            r.anonymous = true
            ensureGroup().append(r)
            row = r
            return r
        }
        for c in t.children {
            switch c.kind {
            case .caption:
                endRow(); group = nil
                c.parent = t; out.append(c)
            case .rowGroup:
                endRow(); group = nil
                c.parent = t; out.append(c)
            case .row:
                endRow()
                ensureGroup().append(c)
            case .cell:
                endCell()
                ensureRow().append(c)
            default:
                if isCollapsibleWhitespace(c) { continue }
                if c.isOutOfFlow && cell == nil { c.parent = t; out.append(c); continue }
                if cell == nil {
                    let a = newBox(.cell, nil, layoutAnonStyle(t.style, .tableCell))
                    a.anonymous = true
                    ensureRow().append(a)
                    cell = a
                }
                cell!.append(c)
            }
        }
        endRow()
        t.children = out
    }

    private func fixRowGroup(_ g: LayoutBox) {
        var out: [LayoutBox] = []
        var row: LayoutBox? = nil
        var cell: LayoutBox? = nil
        for c in g.children {
            if c.kind == .row { if let x = cell { fixBlockContainer(x) }; cell = nil; row = nil; out.append(c); continue }
            if isCollapsibleWhitespace(c) { continue }
            if row == nil {
                let r = newBox(.row, nil, layoutAnonStyle(g.style, .tableRow))
                r.anonymous = true
                r.parent = g
                out.append(r)
                row = r
            }
            if c.kind == .cell { if let x = cell { fixBlockContainer(x) }; cell = nil; row!.append(c); continue }
            if cell == nil {
                let a = newBox(.cell, nil, layoutAnonStyle(g.style, .tableCell))
                a.anonymous = true
                row!.append(a)
                cell = a
            }
            cell!.append(c)
        }
        if let x = cell { fixBlockContainer(x) }
        g.children = out
    }

    private func fixRow(_ r: LayoutBox) {
        var out: [LayoutBox] = []
        var cell: LayoutBox? = nil
        for c in r.children {
            if c.kind == .cell { if let x = cell { fixBlockContainer(x) }; cell = nil; out.append(c); continue }
            if isCollapsibleWhitespace(c) { continue }
            if cell == nil {
                let a = newBox(.cell, nil, layoutAnonStyle(r.style, .tableCell))
                a.anonymous = true
                a.parent = r
                out.append(a)
                cell = a
            }
            cell!.append(c)
        }
        if let x = cell { fixBlockContainer(x) }
        r.children = out
    }

    private func fixFlex(_ f: LayoutBox) {
        var out: [LayoutBox] = []
        var run: [LayoutBox] = []
        func flush() {
            if run.isEmpty { return }
            var meaningful = false
            for c in run where !isCollapsibleWhitespace(c) { meaningful = true; break }
            if meaningful {
                let a = newBox(.block, nil, layoutAnonStyle(f.style, .block))
                a.anonymous = true
                a.childrenInline = true
                a.deco = f.deco; a.decoColor = f.decoColor
                for c in run { a.append(c) }
                a.parent = f
                out.append(a)
            }
            run.removeAll()
        }
        for c in f.children {
            if c.isAbs { flush(); out.append(c); continue }
            if c.kind == .text || c.kind == .lineBreak { run.append(c); continue }
            flush()
            // Blockify the item.
            c.inlineLevel = false
            if c.kind == .inline { c.kind = .block; fixBlockContainer(c) }
            if c.kind == .cell || c.kind == .row || c.kind == .rowGroup || c.kind == .caption {
                let t = newBox(.table, nil, layoutAnonStyle(f.style, .table))
                t.anonymous = true
                t.append(c)
                fixTable(t)
                t.parent = f
                out.append(t)
                continue
            }
            out.append(c)
        }
        flush()
        f.children = out
    }
}

// MARK: - Helpers

/// A style for an anonymous box: inherited properties from `parent`, initial
/// values (with zero borders) for the rest.
func layoutAnonStyle(_ parent: CSSComputedStyle, _ display: CSSDisplay) -> CSSComputedStyle {
    var s = CSSComputedStyle()
    s.inheritProperties(from: parent)
    s.display = display
    s.borderTopWidth = 0; s.borderRightWidth = 0; s.borderBottomWidth = 0; s.borderLeftWidth = 0
    if display == .table { s.borderSpacingH = parent.borderSpacingH; s.borderSpacingV = parent.borderSpacingV }
    return s
}

func layoutLowerASCII(_ s: String) -> String {
    var out: [UInt8] = []
    for b in s.utf8 { out.append(b >= 0x41 && b <= 0x5a ? b + 32 : b) }
    return String(decoding: out, as: UTF8.self)
}

func layoutParseInt(_ s: String) -> Int? {
    var n = 0, any = false, neg = false, started = false
    for b in s.utf8 {
        if !started && (b == 0x20 || b == 0x09 || b == 0x0a) { continue }
        if !started && (b == 0x2d || b == 0x2b) { started = true; neg = b == 0x2d; continue }
        started = true
        if b >= 0x30 && b <= 0x39 { n = min(n * 10 + Int(b - 0x30), 100_000_000); any = true } else { break }
    }
    return any ? (neg ? -n : n) : nil
}

func layoutCollapseSpaces(_ s: String) -> String {
    var out: [UInt8] = []
    var sp = true
    for b in s.utf8 {
        if b == 0x20 || b == 0x09 || b == 0x0a || b == 0x0d || b == 0x0c {
            if !sp { out.append(0x20); sp = true }
        } else { out.append(b); sp = false }
    }
    while out.last == 0x20 { out.removeLast() }
    return String(decoding: out, as: UTF8.self)
}

func layoutIsReplacedName(_ n: String) -> Bool {
    switch n {
    case "img", "input", "select", "textarea", "iframe", "video", "canvas", "embed", "object", "svg", "meter", "progress", "audio":
        return true
    default: return false
    }
}

func layoutReplacedKind(_ node: HTMLNode) -> LayoutReplacedKind {
    switch node.name {
    case "img": return .image
    case "input":
        switch layoutLowerASCII(node.attribute("type") ?? "text") {
        case "checkbox": return .checkbox
        case "radio": return .radio
        case "submit", "reset", "button", "file": return .button
        case "image": return .image
        case "password": return .password
        default: return .textInput
        }
    case "select": return .select
    case "textarea": return .textarea
    case "iframe", "video", "canvas", "embed", "svg": return .frame
    case "object": return node.attribute("data") != nil ? .frame : .none
    case "meter", "progress", "audio": return .other
    default: return .none
    }
}

func layoutUpper(_ c: UInt32) -> UInt32 {
    switch c {
    case 0x61...0x7a: return c - 32
    case 0xe0...0xfe where c != 0xf7: return c - 32
    case 0x3b1...0x3c9 where c != 0x3c2: return c - 32
    case 0x430...0x44f: return c - 32
    case 0x450...0x45f: return c - 80
    default: return c
    }
}

func layoutLowerScalar(_ c: UInt32) -> UInt32 {
    switch c {
    case 0x41...0x5a: return c + 32
    case 0xc0...0xde where c != 0xd7: return c + 32
    case 0x391...0x3a9 where c != 0x3a2: return c + 32
    case 0x410...0x42f: return c + 32
    case 0x400...0x40f: return c + 80
    default: return c
    }
}

func layoutTransform(_ s: [UInt32], _ t: CSSTextTransform) -> [UInt32] {
    switch t {
    case .none: return s
    case .uppercase: return s.map(layoutUpper)
    case .lowercase: return s.map(layoutLowerScalar)
    case .capitalize:
        var out = s
        var start = true
        for i in 0..<out.count {
            let c = out[i]
            let letter = (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c >= 0xc0 || (c >= 0x30 && c <= 0x39)
            if letter { if start { out[i] = layoutUpper(c) }; start = false }
            else if c == 0x20 || c == 0x09 || c == 0x0a || c == 0x2d || c == 0x28 || c == 0x22 { start = true }
        }
        return out
    }
}

private func layoutAlpha(_ n0: Int, _ base: UInt32) -> [UInt32] {
    var n = n0
    if n <= 0 { return textScalars("\(n0)") }
    var out: [UInt32] = []
    while n > 0 && out.count < 16 { n -= 1; out.insert(base + UInt32(n % 26), at: 0); n /= 26 }
    return out
}

private func layoutRoman(_ n0: Int, upper: Bool) -> [UInt32] {
    if n0 <= 0 || n0 >= 4000 { return textScalars("\(n0)") }
    let vals = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1]
    let syms = ["m", "cm", "d", "cd", "c", "xc", "l", "xl", "x", "ix", "v", "iv", "i"]
    var n = n0
    var s = ""
    for (i, v) in vals.enumerated() { while n >= v { s += syms[i]; n -= v } }
    let r = textScalars(s)
    return upper ? r.map(layoutUpper) : r
}

/// The marker text for a list item ("1. ", "• ", ...).
func layoutMarkerText(_ t: CSSListStyleType, _ n: Int) -> [UInt32] {
    var s: [UInt32]
    switch t {
    case .none: return []
    case .disc: return [0x2022, 0x20]
    case .circle: return [0x25e6, 0x20]
    case .square: return [0x25aa, 0x20]
    case .decimal: s = textScalars("\(n)")
    case .decimalLeadingZero: s = textScalars(n >= 0 && n < 10 ? "0\(n)" : "\(n)")
    case .lowerRoman: s = layoutRoman(n, upper: false)
    case .upperRoman: s = layoutRoman(n, upper: true)
    case .lowerAlpha: s = layoutAlpha(n, 0x61)
    case .upperAlpha: s = layoutAlpha(n, 0x41)
    case .lowerGreek: s = n >= 1 && n <= 24 ? [0x3b1 + UInt32(n - 1) + (n > 17 ? 1 : 0)] : textScalars("\(n)")
    }
    s.append(0x2e)
    s.append(0x20)
    return s
}
