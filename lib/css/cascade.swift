// The cascade: rule index, matching, origins/specificity/order, !important,
// inheritance, custom properties and var().

enum CSSOrigin: UInt8 { case userAgent = 0, author = 1 }

struct CSSIndexedRule {
    var declarations: [CSSDeclaration]
    var order: Int
    var origin: CSSOrigin
    var hasImportant: Bool
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
    /// Selectors whose subject is `:host` / `:host(...)` (per pseudo slot:
    /// none, ::before, ::after), `::slotted(...)` and `::part(...)` ones.
    /// They only apply from a shadow root's sheets (or, for parts, to the
    /// shadow trees of the scope's hosts), so they are kept apart.
    fileprivate var hostEntries: [[Int32]] = [[], [], []]
    fileprivate var slottedEntries: [Int32] = []
    fileprivate var partEntries: [Int32] = []
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
                    if sel.slotted != nil { if slot == 0 { slottedEntries.append(e) }; continue }
                    if sel.parts != nil { if slot == 0 { partEntries.append(e) }; continue }
                    if c.hostArgs != nil { hostEntries[slot].append(e); continue }
                    if let id = c.ids.first { buckets[slot].byID[id, default: []].append(e) }
                    else if let cl = c.classes.first { buckets[slot].byClass[cl, default: []].append(e) }
                    else if !c.tag.isEmpty { buckets[slot].byTag[c.tag, default: []].append(e) }
                    else { buckets[slot].universal.append(e) }
                }
                if used {
                    var imp = false
                    for d in rule.declarations where d.important { imp = true; break }
                    rules.append(CSSIndexedRule(declarations: rule.declarations, order: nextOrder, origin: origin, hasImportant: imp))
                    nextOrder += 1
                }
            }
        }
    }

    /// Any selector for this pseudo slot (0 none, 1 ::before, 2 ::after)?
    func hasRules(slot: Int) -> Bool {
        let b = buckets[slot]
        return !b.byID.isEmpty || !b.byClass.isEmpty || !b.byTag.isEmpty || !b.universal.isEmpty || !hostEntries[slot].isEmpty
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

/// One block of declarations that applies to an element: a rule of one of
/// the rule sets in play, the style attribute, or the presentational hints.
/// `key` orders normal declarations, `importantKey` !important ones (later
/// wins in both).
private struct CSSMatch {
    var key: UInt64
    var importantKey: UInt64
    var rule: Int32       // -2 style="", -3 hints
    var set: UInt8        // index into the resolver's per-compute rule set list
    var hasImportant: Bool
}

/// Cascade sort keys: [class 2 bits][context 6][element-attached 1]
/// [specificity 30][order 24]. Normal: class 0 user agent, 1 author, and
/// context 63 - depth (an outer tree's declaration beats an inner one).
/// Important: class 2 author, 3 user agent, and context = depth (inner wins).
@inline(__always) private func cssCascadeKey(_ cls: UInt64, _ ctx: Int, _ attached: Bool, _ spec: UInt32, _ order: Int) -> UInt64 {
    let c = UInt64(max(0, min(63, ctx)))
    return cls << 61 | c << 55 | (attached ? 1 << 54 : 0) | UInt64(spec & 0x3fff_ffff) << 24
        | UInt64(truncatingIfNeeded: order & 0xff_ffff)
}

/// Computes styles. Create one per document, add the sheets in order (user
/// agent first, then author sheets in document order, `@import`ed sheets
/// before the sheet that imports them), then compute each element's style
/// parent-first.
final class CSSStyleResolver {
    var ctx: CSSContext
    private(set) var ruleSet = CSSRuleSet()
    private var sheets: [(CSSStylesheet, CSSOrigin)] = []
    /// Shadow root scopes (CSSTreeScope.id): their author sheets, in order
    /// (`<style>`/`<link>` in the shadow tree, then adoptedStyleSheets).
    private var scopeSheets: [Int: [CSSStylesheet]] = [:]
    private(set) var scopeRules: [Int: CSSRuleSet] = [:]
    private var winRule = [Int32](repeating: -1, count: cssPropCount)
    private var winDecl = [Int32](repeating: 0, count: cssPropCount)
    private var sets: [CSSRuleSet] = []

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
        var rebuilt: [Int: CSSRuleSet] = [:]
        for (id, list) in scopeSheets {
            let rs = CSSRuleSet()
            for s in list { rs.add(s, origin: .author, ctx: ctx) }
            rebuilt[id] = rs
        }
        scopeRules = rebuilt
    }

    /// The author style sheets of a shadow root scope (CSSTreeScope.id,
    /// never 0), replacing any it had. An empty list removes the scope.
    func setScopeSheets(_ scope: Int, _ list: [CSSStylesheet]) {
        if scope == 0 { return }
        if list.isEmpty { scopeSheets[scope] = nil; scopeRules[scope] = nil; return }
        scopeSheets[scope] = list
        let rs = CSSRuleSet()
        for s in list { rs.add(s, origin: .author, ctx: ctx) }
        scopeRules[scope] = rs
    }

    func clearScopes() {
        scopeSheets = [:]
        scopeRules = [:]
    }

    /// Every rule set: the document's, then each scope's.
    var allRuleSets: [CSSRuleSet] {
        var out = [ruleSet]
        for (_, r) in scopeRules { out.append(r) }
        return out
    }

    // MARK: Matching

    private func setIndex(_ rs: CSSRuleSet) -> UInt8 {
        for (i, s) in sets.enumerated() where s === rs { return UInt8(truncatingIfNeeded: i) }
        sets.append(rs)
        return UInt8(truncatingIfNeeded: sets.count - 1)
    }

    private func addMatch(_ rs: CSSRuleSet, _ si: UInt8, _ entry: CSSSelectorEntry, _ depth: Int, _ out: inout [CSSMatch]) {
        let rule = rs.rules[Int(entry.rule)]
        let spec = entry.selector.specificity
        let ua = rule.origin == .userAgent
        let key = cssCascadeKey(ua ? 0 : 1, ua ? 0 : 63 - depth, false, spec, rule.order + 1)
        let ik = cssCascadeKey(ua ? 3 : 2, ua ? 0 : depth, false, spec, rule.order + 1)
        out.append(CSSMatch(key: key, importantKey: ik, rule: entry.rule, set: si, hasImportant: rule.hasImportant))
    }

    /// Rules of `rs` whose subject compound fits `el` (by bucket).
    /// `authorOnly`/`uaOnly` filter by origin.
    private func collectBuckets<E: CSSElement>(_ rs: CSSRuleSet, _ el: E, _ slot: Int, _ depth: Int, skipAuthor: Bool,
                                               _ out: inout [CSSMatch]) {
        let b = rs.buckets[slot]
        var si: UInt8 = 255
        func test(_ list: [Int32]) {
            for ei in list {
                let entry = rs.entries[Int(ei)]
                if skipAuthor && rs.rules[Int(entry.rule)].origin == .author { continue }
                var budget = 20_000
                if cssMatchComplex(entry.selector, el, &budget) {
                    if si == 255 { si = setIndex(rs) }
                    addMatch(rs, si, entry, depth, &out)
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

    private func collect<E: CSSElement>(_ el: E, _ slot: Int, _ out: inout [CSSMatch]) {
        let scope = el.cssTreeScope
        if scope.id == 0 {
            collectBuckets(ruleSet, el, slot, 0, skipAuthor: false, &out)
        } else {
            // A shadow tree: the user agent rules, then its own sheets only.
            collectBuckets(ruleSet, el, slot, scope.depth, skipAuthor: true, &out)
            if let rs = scopeRules[scope.id] { collectBuckets(rs, el, slot, scope.depth, skipAuthor: false, &out) }
        }
        if scopeRules.isEmpty { return }
        // :host rules of the element's own shadow root (an inner context).
        if let hs = el.cssShadowRootScope, let rs = scopeRules[hs], !rs.hostEntries[slot].isEmpty {
            let si = setIndex(rs)
            for ei in rs.hostEntries[slot] {
                let entry = rs.entries[Int(ei)]
                var budget = 20_000
                if cssMatchComplex(entry.selector, el, &budget, featureless: true) { addMatch(rs, si, entry, scope.depth + 1, &out) }
            }
        }
        if slot != 0 { return }
        // ::slotted rules of the scopes the element is slotted into (inner contexts).
        var sl = el.cssAssignedSlot
        var k = 0
        while let s = sl, k < 64 {
            let ss = s.cssTreeScope
            if let rs = scopeRules[ss.id], !rs.slottedEntries.isEmpty {
                let si = setIndex(rs)
                for ei in rs.slottedEntries {
                    let entry = rs.entries[Int(ei)]
                    var budget = 20_000
                    if cssMatchSlotted(entry.selector, el, scope: ss.id, &budget) { addMatch(rs, si, entry, ss.depth, &out) }
                }
            }
            sl = s.cssAssignedSlot
            k += 1
        }
        // ::part rules of the scopes outside (outer contexts).
        if scope.id != 0 && !el.cssPartNames.isEmpty {
            var h = el.cssShadowHost
            var j = 0
            while let host = h, j < 32 {
                let hs = host.cssTreeScope
                let rs: CSSRuleSet? = hs.id == 0 ? ruleSet : scopeRules[hs.id]
                if let r = rs, !r.partEntries.isEmpty {
                    let si = setIndex(r)
                    for ei in r.partEntries {
                        let entry = r.entries[Int(ei)]
                        var budget = 20_000
                        if cssMatchPart(entry.selector, el, scope: hs.id, &budget) { addMatch(r, si, entry, hs.depth, &out) }
                    }
                }
                h = host.cssShadowHost
                j += 1
            }
        }
    }

    /// Any ::before/::after rule anywhere (doc or scopes) for this slot?
    private func anyRules(slot: Int) -> Bool {
        if ruleSet.hasRules(slot: slot) { return true }
        for (_, r) in scopeRules where r.hasRules(slot: slot) { return true }
        return false
    }

    // MARK: Computing

    /// The computed style of `el`. `parent` is the parent element's computed
    /// style (nil for the root). If `el` is the root, `ctx.rootFontSize`
    /// is updated for later `rem` units.
    ///
    /// `hints` are HTML presentational hints (`bgcolor`, `width`, ...): they
    /// cascade as author declarations with specificity zero that precede every
    /// author rule, so any author rule (or `style=""`) beats them.
    func computeStyle<E: CSSElement>(_ el: E, parent: CSSComputedStyle?, hints: [CSSDeclaration] = []) -> CSSComputedStyle {
        let isRoot = el.cssIsRoot
        let s = compute(el, 0, parent ?? CSSComputedStyle(), inlineStyle: true, isRoot: isRoot, hints: hints)
        if isRoot { ctx.rootFontSize = s.fontSize }
        return s
    }

    /// The style of `el`'s ::before or ::after, or nil when no rule applies or
    /// its `content` is none/normal. `attr()` items are filled in from `el`.
    func computePseudoStyle<E: CSSElement>(_ el: E, _ pseudo: CSSPseudoElement, elementStyle: CSSComputedStyle) -> CSSComputedStyle? {
        let slot = pseudo == .before ? 1 : (pseudo == .after ? 2 : 0)
        guard slot != 0 else { return nil }
        if !anyRules(slot: slot) { return nil }
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

    private func compute<E: CSSElement>(_ el: E, _ slot: Int, _ parent: CSSComputedStyle, inlineStyle: Bool, isRoot: Bool,
                                        hints: [CSSDeclaration] = []) -> CSSComputedStyle {
        sets.removeAll(keepingCapacity: true)
        var matches: [CSSMatch] = []
        collect(el, slot, &matches)
        var inline: [CSSDeclaration] = []
        if inlineStyle, let attr = el.cssAttribute("style"), !attr.isEmpty {
            inline = cssParseInlineStyle(attr)
        }
        // The style attribute and hints belong to the element's own tree context.
        let own = el.cssTreeScope.depth
        if !hints.isEmpty {
            matches.append(CSSMatch(key: cssCascadeKey(1, 63 - own, false, 0, 0), importantKey: 0, rule: -3, set: 0, hasImportant: false))
        }
        if !inline.isEmpty {
            var imp = false
            for d in inline where d.important { imp = true; break }
            matches.append(CSSMatch(key: cssCascadeKey(1, 63 - own, true, 0, 0), importantKey: cssCascadeKey(2, own, true, 0, 0),
                                    rule: -2, set: 0, hasImportant: imp))
        }
        if matches.count > 1 { matches.sort { $0.key < $1.key } }

        // Winners per property: (index into matches; declaration index).
        for k in 0..<cssPropCount { winRule[k] = -1 }
        var customWinners: [String: [CSSComponent]] = [:]
        var hasPending = false

        func decls(_ m: CSSMatch) -> [CSSDeclaration] {
            if m.rule == -2 { return inline }
            if m.rule == -3 { return hints }
            return sets[Int(m.set)].rules[Int(m.rule)].declarations
        }
        func take(_ d: CSSDeclaration, _ mi: Int, _ idx: Int) {
            if d.kind == .custom { customWinners[d.name] = d.raw; return }
            if d.kind == .pending { hasPending = true }
            winRule[Int(d.prop.rawValue)] = Int32(truncatingIfNeeded: mi)
            winDecl[Int(d.prop.rawValue)] = Int32(truncatingIfNeeded: idx)
        }
        // 1. Normal declarations in cascade order: user agent, then author
        //    (outer tree contexts last; within one: hints, rules by
        //    specificity and order, style="").
        for (mi, m) in matches.enumerated() {
            for (i, d) in decls(m).enumerated() where !d.important { take(d, mi, i) }
        }
        // 2. !important: author (inner contexts last; style="" after rules
        //    within one), then user agent.
        var imp: [(UInt64, Int)] = []
        for (mi, m) in matches.enumerated() where m.hasImportant { imp.append((m.importantKey, mi)) }
        if imp.count > 1 { imp.sort { $0.0 < $1.0 } }
        for (_, mi) in imp {
            for (i, d) in decls(matches[mi]).enumerated() where d.important { take(d, mi, i) }
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
            var d = decls(matches[Int(rule)])[Int(winDecl[k])]
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
