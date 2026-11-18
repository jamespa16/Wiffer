// The cascade: rule index, matching, origins/specificity/order, !important,
// inheritance, custom properties and var().

enum CSSOrigin: UInt8 { case userAgent = 0, author = 1 }

struct CSSIndexedRule {
    var declarations: [CSSDeclaration]
    var order: Int
    var origin: CSSOrigin
}

struct CSSSelectorEntry {
    var selector: CSSComplexSelector
    var rule: Int32
}

struct CSSBucketSet {
    var byID: [String: [Int32]] = [:]
    var byClass: [String: [Int32]] = [:]
    var byTag: [String: [Int32]] = [:]
    var universal: [Int32] = []
}

/// All the rules of every sheet added so far, flattened (media queries are
/// evaluated when a sheet is added) and indexed by the rightmost compound's
/// id, first class or tag so an element only tests the rules that can match.
final class CSSRuleSet {
    private(set) var rules: [CSSIndexedRule] = []
    private(set) var entries: [CSSSelectorEntry] = []
    fileprivate var buckets = [CSSBucketSet(), CSSBucketSet(), CSSBucketSet()]
    private var nextOrder = 0

    init() {}

    var ruleCount: Int { rules.count }
    var selectorCount: Int { entries.count }

    func add(_ sheet: CSSStylesheet, origin: CSSOrigin, ctx: CSSContext) {
        addRules(sheet.rules, origin, ctx)
    }

    private func addRules(_ list: [CSSRule], _ origin: CSSOrigin, _ ctx: CSSContext) {
        for r in list {
            switch r {
            case .media(let q, let sub):
                if q.matches(ctx) { addRules(sub, origin, ctx) }
            case .style(let rule):
                let idx = Int32(truncatingIfNeeded: rules.count)
                var used = false
                for sel in rule.selectors {
                    let slot: Int
                    switch sel.pseudoElement {
                    case .none: slot = 0
                    case .before: slot = 1
                    case .after: slot = 2
                    case .other: continue
                    }
                    used = true
                    let e = Int32(truncatingIfNeeded: entries.count)
                    entries.append(CSSSelectorEntry(selector: sel, rule: idx))
                    let c = sel.compounds[sel.compounds.count - 1]
                    if let id = c.ids.first { buckets[slot].byID[id, default: []].append(e) }
                    else if let cl = c.classes.first { buckets[slot].byClass[cl, default: []].append(e) }
                    else if !c.tag.isEmpty { buckets[slot].byTag[c.tag, default: []].append(e) }
                    else { buckets[slot].universal.append(e) }
                }
                if used {
                    rules.append(CSSIndexedRule(declarations: rule.declarations, order: nextOrder, origin: origin))
                    nextOrder += 1
                }
            }
        }
    }
}

// MARK: - Custom properties and var()

private let cssMaxVarOutput = 10_000
private let cssMaxVarDepth = 24

final class CSSCustomResolver {
    var winners: [String: [CSSComponent]]
    var values: [String: [CSSComponent]]
    var state: [String: UInt8] = [:]
    var cycleStart: String? = nil
    var produced = 0

    init(inherited: [String: [CSSComponent]], winners: [String: [CSSComponent]]) {
        self.values = inherited
        self.winners = winners
    }

    /// Resolve every custom property this element declares.
    func resolveAll() {
        for name in winners.keys { _ = lookup(name, 0) }
    }

    func lookup(_ name: String, _ depth: Int) -> [CSSComponent]? {
        guard let raw = winners[name] else { return values[name] }
        let st = state[name] ?? 0
        if st == 2 { return values[name] }
        if st == 1 { cycleStart = name; return nil }
        if depth >= cssMaxVarDepth { values[name] = nil; state[name] = 2; return nil }
        state[name] = 1
        let saved = produced
        let out = substitute(raw, depth + 1)
        produced = saved
        state[name] = 2
        if let cs = cycleStart {
            values[name] = nil
            if cs == name { cycleStart = nil }
            return nil
        }
        values[name] = out
        return out
    }

    /// Replace var() references; nil if one can't be resolved (invalid at computed-value time).
    func substitute(_ comps: [CSSComponent], _ depth: Int) -> [CSSComponent]? {
        if depth > cssMaxVarDepth { return nil }
        var out: [CSSComponent] = []
        for c in comps {
            switch c {
            case .function(let n, let args):
                if cssLower(n) == "var" {
                    guard let name = firstName(args) else { return nil }
                    var replacement = lookup(name, depth)
                    if cycleStart != nil { return nil }
                    if replacement == nil, let fb = fallback(args) {
                        replacement = substitute(fb, depth + 1)
                    }
                    guard let r = replacement else { return nil }
                    produced += r.count
                    if produced > cssMaxVarOutput { return nil }
                    out.append(contentsOf: r)
                } else {
                    guard let inner = substitute(args, depth + 1) else { return nil }
                    out.append(.function(n, inner))
                }
            case .block(let k, let inner):
                guard let r = substitute(inner, depth + 1) else { return nil }
                out.append(.block(k, r))
            default:
                out.append(c)
                produced += 1
                if produced > cssMaxVarOutput { return nil }
            }
        }
        return out
    }

    private func firstName(_ args: [CSSComponent]) -> String? {
        guard let f = args.first, case .token(.ident(let n)) = f, n.utf8.count >= 2, n.utf8.first == 0x2d else { return nil }
        return n
    }

    private func fallback(_ args: [CSSComponent]) -> [CSSComponent]? {
        for (k, a) in args.enumerated() {
            if case .token(.comma) = a { return Array(args[(k + 1)...]) }
        }
        return nil
    }
}

// MARK: - The resolver

private struct CSSMatch {
    var key: UInt64
    var rule: Int32
}

/// Computes styles. Create one per document, add the sheets in order (user
/// agent first, then author sheets in document order, `@import`ed sheets
/// before the sheet that imports them), then compute each element's style
/// parent-first.
final class CSSStyleResolver {
    var ctx: CSSContext
    private(set) var ruleSet = CSSRuleSet()
    private var sheets: [(CSSStylesheet, CSSOrigin)] = []
    private var winRule = [Int32](repeating: -1, count: cssPropCount)
    private var winDecl = [Int32](repeating: 0, count: cssPropCount)

    /// With the built-in user agent sheet (`cssUserAgentStyleSheet`).
    init(ctx: CSSContext = CSSContext()) {
        self.ctx = ctx
        addStyleSheet(cssUserAgentStyleSheet(), origin: .userAgent)
    }

    /// Without any user agent sheet.
    init(ctx: CSSContext, noUserAgent: Bool) {
        self.ctx = ctx
        if !noUserAgent { addStyleSheet(cssUserAgentStyleSheet(), origin: .userAgent) }
    }

    func addStyleSheet(_ sheet: CSSStylesheet, origin: CSSOrigin = .author) {
        sheets.append((sheet, origin))
        ruleSet.add(sheet, origin: origin, ctx: ctx)
    }

    /// Re-evaluate media queries after the viewport (or color scheme) changed.
    func setContext(_ newCtx: CSSContext) {
        ctx = newCtx
        let old = sheets
        ruleSet = CSSRuleSet()
        for (s, o) in old { ruleSet.add(s, origin: o, ctx: ctx) }
    }

    // MARK: Matching

    private func collect<E: CSSElement>(_ el: E, _ slot: Int, _ out: inout [CSSMatch]) {
        let b = ruleSet.buckets[slot]
        func test(_ list: [Int32]) {
            for ei in list {
                let entry = ruleSet.entries[Int(ei)]
                var budget = 20_000
                if cssMatchComplex(entry.selector, el, &budget) {
                    let rule = ruleSet.rules[Int(entry.rule)]
                    let key = UInt64(rule.origin.rawValue) << 60 | UInt64(entry.selector.specificity) << 24
                        | UInt64(truncatingIfNeeded: rule.order & 0xff_ffff)
                    out.append(CSSMatch(key: key, rule: entry.rule))
                }
            }
        }
        let id = el.cssID
        if !id.isEmpty, let l = b.byID[id] { test(l) }
        if !b.byClass.isEmpty {
            for c in el.cssClasses { if let l = b.byClass[c] { test(l) } }
        }
        if let l = b.byTag[el.cssTagName] { test(l) }
        test(b.universal)
    }

    // MARK: Computing

    /// The computed style of `el`. `parent` is the parent element's computed
    /// style (nil for the root). If `el` is the root, `ctx.rootFontSize`
    /// is updated for later `rem` units.
    func computeStyle<E: CSSElement>(_ el: E, parent: CSSComputedStyle?) -> CSSComputedStyle {
        let isRoot = el.cssIsRoot
        let s = compute(el, 0, parent ?? CSSComputedStyle(), inlineStyle: true, isRoot: isRoot)
        if isRoot { ctx.rootFontSize = s.fontSize }
        return s
    }

    /// The style of `el`'s ::before or ::after, or nil when no rule applies or
    /// its `content` is none/normal. `attr()` items are filled in from `el`.
    func computePseudoStyle<E: CSSElement>(_ el: E, _ pseudo: CSSPseudoElement, elementStyle: CSSComputedStyle) -> CSSComputedStyle? {
        let slot = pseudo == .before ? 1 : (pseudo == .after ? 2 : 0)
        guard slot != 0 else { return nil }
        if ruleSet.buckets[slot].byID.isEmpty && ruleSet.buckets[slot].byClass.isEmpty
            && ruleSet.buckets[slot].byTag.isEmpty && ruleSet.buckets[slot].universal.isEmpty { return nil }
        var s = compute(el, slot, elementStyle, inlineStyle: false, isRoot: false)
        guard s.contentKind == .items else { return nil }
        var items: [String] = []
        for i in s.contentItems {
            if i.utf8.first == 1 {
                let name = cssLower(String(i.dropFirst()))
                items.append(el.cssAttribute(name) ?? "")
            } else { items.append(i) }
        }
        s.contentItems = items
        return s
    }

    private func compute<E: CSSElement>(_ el: E, _ slot: Int, _ parent: CSSComputedStyle, inlineStyle: Bool, isRoot: Bool) -> CSSComputedStyle {
        var matches: [CSSMatch] = []
        collect(el, slot, &matches)
        var inline: [CSSDeclaration] = []
        if inlineStyle, let attr = el.cssAttribute("style"), !attr.isEmpty {
            inline = cssParseInlineStyle(attr)
        }
        if matches.count > 1 { matches.sort { $0.key < $1.key } }

        // Winners per property: (rule or -2 for inline, declaration index).
        for k in 0..<cssPropCount { winRule[k] = -1 }
        var customWinners: [String: [CSSComponent]] = [:]
        var hasPending = false

        func take(_ d: CSSDeclaration, _ rule: Int32, _ idx: Int) {
            if d.kind == .custom { customWinners[d.name] = d.raw; return }
            if d.kind == .pending { hasPending = true }
            winRule[Int(d.prop.rawValue)] = rule
            winDecl[Int(d.prop.rawValue)] = Int32(truncatingIfNeeded: idx)
        }
        // 1. normal declarations: user agent, then author (specificity, order), then style=""
        for m in matches {
            let ds = ruleSet.rules[Int(m.rule)].declarations
            for (i, d) in ds.enumerated() where !d.important { take(d, m.rule, i) }
        }
        for (i, d) in inline.enumerated() where !d.important { take(d, -2, i) }
        // 2. author !important (rules, then style="")
        for m in matches where ruleSet.rules[Int(m.rule)].origin == .author {
            let ds = ruleSet.rules[Int(m.rule)].declarations
            for (i, d) in ds.enumerated() where d.important { take(d, m.rule, i) }
        }
        for (i, d) in inline.enumerated() where d.important { take(d, -2, i) }
        // 3. user agent !important beats everything
        for m in matches where ruleSet.rules[Int(m.rule)].origin == .userAgent {
            let ds = ruleSet.rules[Int(m.rule)].declarations
            for (i, d) in ds.enumerated() where d.important { take(d, m.rule, i) }
        }

        var style = CSSComputedStyle()
        style.inheritProperties(from: parent)

        // Custom properties.
        var custom: CSSCustomResolver? = nil
        if !customWinners.isEmpty || hasPending {
            let r = CSSCustomResolver(inherited: parent.customProperties, winners: customWinners)
            r.resolveAll()
            style.customProperties = r.values
            custom = r
        }

        let defaults = CSSComputedStyle()
        var explicit = [Bool](repeating: false, count: cssPropCount)
        for k in 0..<(cssPropCount - 1) {
            let rule = winRule[k]
            if rule == -1 { continue }
            let prop = CSSProp(rawValue: UInt8(k)) ?? .custom
            var d: CSSDeclaration
            if rule == -2 { d = inline[Int(winDecl[k])] }
            else { d = ruleSet.rules[Int(rule)].declarations[Int(winDecl[k])] }
            explicit[k] = true
            if d.kind == .pending {
                // Substitute var() and parse as the declared (shorthand) property.
                var resolved: CSSDeclaration? = nil
                if let r = custom, let comps = r.substitute(d.raw, 0), !comps.isEmpty,
                   let expanded = cssExpandDeclaration(d.name, comps, resolveURL: nil) {
                    for e in expanded where e.prop == prop { resolved = e; break }
                }
                if let r = resolved { d = r } else { d = CSSDeclaration(prop: prop, kind: .unset) }
            }
            switch d.kind {
            case .value: style.apply(prop, d.value, parent: parent, ctx: ctx)
            case .initial:
                // The initial value of a border color is currentColor (finalize fills it in).
                switch prop {
                case .borderTopColor, .borderRightColor, .borderBottomColor, .borderLeftColor: explicit[k] = false
                default: style.copyProperty(prop, from: defaults)
                }
            case .inherit: style.copyProperty(prop, from: parent)
            default: // unset
                style.copyProperty(prop, from: cssIsInherited(prop) ? parent : defaults)
            }
        }
        style.finalize(explicit: explicit, isRoot: isRoot)
        return style
    }
}
