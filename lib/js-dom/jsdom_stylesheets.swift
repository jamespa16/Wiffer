// Constructable stylesheets and adoptedStyleSheets (ROADMAP Phase 9I).
//
// A CSSStyleSheet made by script (`new CSSStyleSheet()`) keeps its rules
// as text, one string per top-level rule (cssRules, insertRule,
// deleteRule, replace / replaceSync), and lib/css parses the whole list
// when lib/layout needs it. Documents and shadow roots adopt sheets
// through `adoptedStyleSheets`: a plain JS array per root here (the spec's
// ObservableArray is approximated by re-reading the array in a microtask
// after every read, which catches `push` / `splice` on it). Each change
// is delivered to the page's LayoutEngine (JSDOMHost.layout) with
// setAdoptedStyleSheets(_:for:); JSDOMPage.syncAdoptedStyleSheets()
// re-delivers everything (a new engine for the same document).
//
// Only constructed sheets exist as objects: `style.sheet` and
// document.styleSheets are still absent.

final class JSDOMStyleSheet {
    var rules: [JSDOMCSSRule] = []
    var disabled = false
    var media = ""
    var baseURL: String? = nil
    var disallowModification = false
    var parsedCache: CSSStylesheet? = nil
    init() {}
}

final class JSDOMCSSRule {
    var text: String
    var sheet: JSDOMStyleSheet?
    init(_ t: String, _ s: JSDOMStyleSheet?) { text = t; sheet = s }
}

final class JSDOMCSSRuleList {
    let sheet: JSDOMStyleSheet
    init(_ s: JSDOMStyleSheet) { sheet = s }
}

struct JSDOMAdoptedList {
    let root: HTMLNode
    var array: JSValue
    var sheets: [JSDOMStyleSheet]
}

final class JSDOMSheetState {
    var adopted: [ObjectIdentifier: JSDOMAdoptedList] = [:]
    var all: [JSDOMStyleSheet] = []
    var recheckScheduled = false
    var rechecker: JSValue = .undefined
    init() {}

    func mark(_ h: JSHeap) {
        for (_, a) in adopted { h.markValue(a.array) }
        h.markValue(rechecker)
    }

    /// Break sheet <-> rule cycles (page teardown).
    func release() {
        for s in all {
            for r in s.rules { r.sheet = nil }
            s.rules = []
        }
        all = []
        adopted = [:]
    }
}

let jsdomMaxSheetRules = 100_000

/// Split CSS text into top-level rule texts: a block rule ends at its
/// closing brace, a statement at-rule at a top-level semicolon. Comments
/// are dropped, strings kept.
func jsdomSplitRules(_ text: String) -> [String] {
    let b = Array(text.utf8)
    var out: [String] = []
    var cur: [UInt8] = []
    var depth = 0
    var i = 0
    func flush(_ cur: inout [UInt8], _ out: inout [String]) {
        let s = jsdomTrimCSS(cur)
        if !s.isEmpty && out.count < jsdomMaxSheetRules { out.append(s) }
        cur = []
    }
    while i < b.count {
        let c = b[i]
        if c == 0x2f && i + 1 < b.count && b[i + 1] == 0x2a {   // /* comment */
            i += 2
            while i + 1 < b.count && !(b[i] == 0x2a && b[i + 1] == 0x2f) { i += 1 }
            i = min(i + 2, b.count)
            cur.append(0x20)
            continue
        }
        if c == 0x22 || c == 0x27 {   // string
            cur.append(c)
            i += 1
            while i < b.count && b[i] != c {
                if b[i] == 0x5c && i + 1 < b.count { cur.append(b[i]); i += 1 }
                if b[i] == 0x0a { break }
                cur.append(b[i])
                i += 1
            }
            if i < b.count { cur.append(b[i]); i += 1 }
            continue
        }
        cur.append(c)
        i += 1
        if c == 0x7b { depth += 1 }
        else if c == 0x7d {
            depth -= 1
            if depth <= 0 { depth = 0; flush(&cur, &out) }
        } else if c == 0x3b && depth == 0 {
            flush(&cur, &out)
        }
    }
    // Blocks still open at the end close there (CSS parsing at EOF).
    if depth > 0 && !jsdomTrimCSS(cur).isEmpty {
        cur.append(0x20)
        while depth > 0 { cur.append(0x7d); depth -= 1 }
    }
    flush(&cur, &out)
    return out
}

func jsdomTrimCSS(_ b: [UInt8]) -> String {
    var lo = 0
    var hi = b.count
    func ws(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d || c == 0x0c }
    while lo < hi && ws(b[lo]) { lo += 1 }
    while hi > lo && ws(b[hi - 1]) { hi -= 1 }
    return String(decoding: b[lo..<hi], as: UTF8.self)
}

/// CSSRule.type for a rule text.
func jsdomRuleType(_ text: String) -> Int {
    guard text.hasPrefix("@") else { return 1 }
    var name: [UInt8] = []
    for c in text.utf8.dropFirst() {
        if (c >= 0x61 && c <= 0x7a) || (c >= 0x41 && c <= 0x5a) || c == 0x2d { name.append(c | 0x20) } else { break }
    }
    switch String(decoding: name, as: UTF8.self) {
    case "charset": return 2
    case "import": return 3
    case "media": return 4
    case "font-face": return 5
    case "page": return 6
    case "keyframes", "-webkit-keyframes": return 7
    case "namespace": return 10
    case "supports": return 12
    default: return 0
    }
}

extension JSDOMBindings {
    // MARK: CSSStyleSheet

    func CSSStyleSheet_constructor(_ options: JSValue, newTarget: JSValue) throws(JSThrow) -> JSValue {
        let s = JSDOMStyleSheet()
        s.baseURL = url?.href
        if options.isObject {
            let base = try realm.getV(options, heap.key("baseURL"))
            if !base.isUndefined {
                let b = try toStr(base)
                guard let r = resolveURL(b) else { throw throwDOM("NotAllowedError", "Failed to construct 'CSSStyleSheet': the baseURL is not valid.") }
                s.baseURL = r
            }
            let m = try realm.getV(options, heap.key("media"))
            if !m.isUndefined {
                if m.isObject, case .value(let t) = heap.getProperty(m, heap.key("mediaText")), t.isString { s.media = heap.swiftString(t) }
                else { s.media = try toStr(m) }
            }
            s.disabled = heap.toBoolean(try realm.getV(options, heap.key("disabled")))
        } else if !options.isUndefined && !options.isNull {
            throw realm.throwTypeError("Failed to construct 'CSSStyleSheet': The provided value is not of type 'CSSStyleSheetInit'.")
        }
        if sheets.all.count < 100_000 { sheets.all.append(s) }
        let w = classes.CSSStyleSheet.wrap(s)
        try adoptNewTarget(w, newTarget, .CSSStyleSheet)
        return w
    }

    func CSSStyleSheet_type(_ s: JSDOMStyleSheet) -> String { "text/css" }
    func CSSStyleSheet_href(_ s: JSDOMStyleSheet) -> String? { nil }
    func CSSStyleSheet_ownerNode(_ s: JSDOMStyleSheet) -> JSValue { .null }
    func CSSStyleSheet_parentStyleSheet(_ s: JSDOMStyleSheet) -> JSValue { .null }
    func CSSStyleSheet_title(_ s: JSDOMStyleSheet) -> String? { nil }
    func CSSStyleSheet_media(_ s: JSDOMStyleSheet) -> JSValue { str(s.media) }
    func CSSStyleSheet_ownerRule(_ s: JSDOMStyleSheet) -> JSValue { .null }
    func CSSStyleSheet_disabled(_ s: JSDOMStyleSheet) -> Bool { s.disabled }
    func CSSStyleSheet_set_disabled(_ s: JSDOMStyleSheet, _ v: Bool) {
        if s.disabled == v { return }
        s.disabled = v
        sheetChanged(s)
    }
    func CSSStyleSheet_cssRules(_ s: JSDOMStyleSheet) -> JSValue { classes.CSSRuleList.wrap(JSDOMCSSRuleList(s)) }

    func CSSStyleSheet_insertRule(_ s: JSDOMStyleSheet, _ rule: String, _ index: Int) throws(JSThrow) -> Int {
        if s.disallowModification { throw throwDOM("NotAllowedError", "Failed to execute 'insertRule' on 'CSSStyleSheet': a replace() is in progress.") }
        if index > s.rules.count {
            throw throwDOM("IndexSizeError", "Failed to execute 'insertRule' on 'CSSStyleSheet': The index provided (" + String(index) + ") is larger than the maximum index (" + String(s.rules.count) + ").")
        }
        let parts = jsdomSplitRules(rule)
        guard parts.count == 1, let text = parts.first, jsdomRuleIsValid(text) else {
            throw throwDOM("SyntaxError", "Failed to execute 'insertRule' on 'CSSStyleSheet': Failed to parse the rule '" + rule + "'.")
        }
        if jsdomRuleType(text) == 3 {
            throw throwDOM("SyntaxError", "Failed to execute 'insertRule' on 'CSSStyleSheet': Can't insert @import rules into a constructed stylesheet.")
        }
        if s.rules.count >= jsdomMaxSheetRules { throw realm.throwRangeError("too many rules") }
        s.rules.insert(JSDOMCSSRule(text, s), at: index)
        sheetChanged(s)
        return index
    }

    func CSSStyleSheet_deleteRule(_ s: JSDOMStyleSheet, _ index: Int) throws(JSThrow) {
        if s.disallowModification { throw throwDOM("NotAllowedError", "Failed to execute 'deleteRule' on 'CSSStyleSheet': a replace() is in progress.") }
        guard index >= 0 && index < s.rules.count else {
            throw throwDOM("IndexSizeError", "Failed to execute 'deleteRule' on 'CSSStyleSheet': The index provided (" + String(index) + ") is outside the range [0, " + String(s.rules.count) + ").")
        }
        s.rules[index].sheet = nil
        s.rules.remove(at: index)
        sheetChanged(s)
    }

    func CSSStyleSheet_addRule(_ s: JSDOMStyleSheet, _ sel: String, _ style: String, _ index: JSValue) throws(JSThrow) -> Int {
        var text = sel + " { " + style
        if !style.isEmpty { text += " " }
        text += "}"
        let i = index.isUndefined ? s.rules.count : try toUnsignedLong(index)
        _ = try CSSStyleSheet_insertRule(s, text, i)
        return -1
    }

    func CSSStyleSheet_removeRule(_ s: JSDOMStyleSheet, _ index: Int) throws(JSThrow) {
        try CSSStyleSheet_deleteRule(s, index)
    }

    /// Replace the rules from text (@import rules are dropped in
    /// constructed sheets).
    func setSheetText(_ s: JSDOMStyleSheet, _ text: String) {
        for r in s.rules { r.sheet = nil }
        s.rules = []
        for t in jsdomSplitRules(text) where jsdomRuleType(t) != 3 && jsdomRuleIsValid(t) {
            s.rules.append(JSDOMCSSRule(t, s))
        }
        sheetChanged(s)
    }

    func CSSStyleSheet_replaceSync(_ s: JSDOMStyleSheet, _ text: String) throws(JSThrow) {
        if s.disallowModification { throw throwDOM("NotAllowedError", "Failed to execute 'replaceSync' on 'CSSStyleSheet': a replace() is in progress.") }
        setSheetText(s, text)
    }

    func CSSStyleSheet_replace(_ s: JSDOMStyleSheet, _ text: String) -> JSValue {
        let p = realm.newPromise()
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        _ = heap.root(p)
        if s.disallowModification {
            let e = domException("NotAllowedError", "Failed to execute 'replace' on 'CSSStyleSheet': a replace() is in progress.")
            _ = heap.root(e)
            realm.rejectPromise(p, e)
            return p
        }
        setSheetText(s, text)
        let w = classes.CSSStyleSheet.wrap(s)
        _ = heap.root(w)
        _ = try? realm.resolvePromise(p, w)
        return p
    }

    /// The parsed form lib/layout gets.
    func parsedSheet(_ s: JSDOMStyleSheet) -> CSSStylesheet {
        if let c = s.parsedCache { return c }
        var text = ""
        for r in s.rules { text += r.text; text += "\n" }
        if !s.media.isEmpty { text = "@media " + s.media + " {\n" + text + "}\n" }
        let base = s.baseURL.flatMap { URLRecord.parseOrNil($0) }
        let parsed = cssParseStylesheet(text, resolveURL: { (u: String) -> String in
            guard let b = base, let r = URLRecord.parseOrNil(u, base: b) else { return u }
            return r.href
        })
        s.parsedCache = parsed
        return parsed
    }

    func sheetChanged(_ s: JSDOMStyleSheet) {
        s.parsedCache = nil
        for (_, a) in sheets.adopted where a.sheets.contains(where: { $0 === s }) { deliverAdopted(a.root) }
    }

    // MARK: CSSRuleList, CSSRule

    func exotic_CSSRuleList() -> JSHostExotic<JSDOMCSSRuleList> {
        var e = JSHostExotic<JSDOMCSSRuleList>()
        e.length = { l in l.sheet.rules.count }
        e.indexedGet = { [unowned(unsafe) self] (realm: JSRealm, l: JSDOMCSSRuleList, i: Int) throws(JSThrow) -> JSValue? in
            i >= 0 && i < l.sheet.rules.count ? self.classes.CSSRule.wrap(l.sheet.rules[i]) : nil
        }
        return e
    }
    func CSSRuleList_item(_ l: JSDOMCSSRuleList, _ i: Int) -> JSValue {
        i >= 0 && i < l.sheet.rules.count ? classes.CSSRule.wrap(l.sheet.rules[i]) : .null
    }
    func CSSRuleList_length(_ l: JSDOMCSSRuleList) -> Int { l.sheet.rules.count }

    func CSSRule_cssText(_ r: JSDOMCSSRule) -> String { r.text }
    func CSSRule_set_cssText(_ r: JSDOMCSSRule, _ v: String) {}
    func CSSRule_type(_ r: JSDOMCSSRule) -> Int { jsdomRuleType(r.text) }
    func CSSRule_parentRule(_ r: JSDOMCSSRule) -> JSValue { .null }
    func CSSRule_parentStyleSheet(_ r: JSDOMCSSRule) -> JSValue {
        guard let s = r.sheet else { return .null }
        return classes.CSSStyleSheet.wrap(s)
    }
    func CSSRule_selectorText(_ r: JSDOMCSSRule) -> String {
        guard jsdomRuleType(r.text) == 1, let i = r.text.firstIndex(of: "{") else { return "" }
        return jsdomTrimCSS(Array(r.text[r.text.startIndex..<i].utf8))
    }

    // MARK: adoptedStyleSheets

    func DocumentOrShadowRoot_adoptedStyleSheets(_ n: HTMLNode) throws(JSThrow) -> JSValue {
        let id = ObjectIdentifier(n)
        if let a = sheets.adopted[id] {
            scheduleAdoptedRecheck()
            return a.array
        }
        let arr = array([])
        sheets.adopted[id] = JSDOMAdoptedList(root: n, array: arr, sheets: [])
        scheduleAdoptedRecheck()
        return arr
    }

    func DocumentOrShadowRoot_set_adoptedStyleSheets(_ n: HTMLNode, _ v: JSValue) throws(JSThrow) {
        let c = ctx(n.kind == .document ? "Document" : "ShadowRoot", "adoptedStyleSheets")
        let vals = try toSequence(v, c) { (x: JSValue) throws(JSThrow) -> JSValue in x }
        var list: [JSDOMStyleSheet] = []
        for x in vals {
            guard let s = classes.CSSStyleSheet.unwrap(x) else {
                throw typeError(c, "Failed to convert value to 'CSSStyleSheet'.")
            }
            list.append(s)
        }
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        for x in vals { _ = heap.root(x) }
        let arr = array(vals)
        sheets.adopted[ObjectIdentifier(n)] = JSDOMAdoptedList(root: n, array: arr, sheets: list)
        deliverAdopted(n)
    }

    /// After a read of adoptedStyleSheets: look at the arrays again in a
    /// microtask (push / splice / index assignment on them).
    func scheduleAdoptedRecheck() {
        if sheets.recheckScheduled { return }
        sheets.recheckScheduled = true
        if !sheets.rechecker.isObject {
            unowned(unsafe) let b = self
            let idx = realm.registerNative("recheckAdoptedStyleSheets", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
                b.recheckAdopted()
                return .undefined
            }
            sheets.rechecker = realm.newNativeFunction(idx)
        }
        realm.enqueueJob(sheets.rechecker, args: [])
    }

    func recheckAdopted() {
        sheets.recheckScheduled = false
        for (id, a) in sheets.adopted {
            var list: [JSDOMStyleSheet] = []
            var len = 0.0
            if case .value(let l) = heap.getProperty(a.array, heap.names.length), let x = try? realm.toNumber(l) { len = x }
            var i = 0
            let n = len.isFinite ? min(Int(max(len, 0)), jsdomMaxSheetRules) : 0
            while i < n {
                if case .value(let x) = heap.getProperty(a.array, .index(UInt32(i))), let s = classes.CSSStyleSheet.unwrap(x) {
                    list.append(s)
                }
                i += 1
            }
            var same = list.count == a.sheets.count
            if same { for (x, y) in zip(list, a.sheets) where x !== y { same = false; break } }
            if same { continue }
            sheets.adopted[id]?.sheets = list
            deliverAdopted(a.root)
        }
    }

    /// Hand a root's adopted sheets (enabled ones, parsed) to lib/layout.
    func deliverAdopted(_ root: HTMLNode) {
        guard let engine = host.layout() else { return }
        let list = sheets.adopted[ObjectIdentifier(root)]?.sheets ?? []
        var parsed: [CSSStylesheet] = []
        for s in list where !s.disabled { parsed.append(parsedSheet(s)) }
        if root.kind == .document && root !== document { return }
        engine.setAdoptedStyleSheets(parsed, for: root)
    }

    func syncAllAdopted() {
        for (_, a) in sheets.adopted { deliverAdopted(a.root) }
    }
}

/// A rule lib/css keeps (style rules must parse; at-rules are kept).
func jsdomRuleIsValid(_ text: String) -> Bool {
    if text.hasPrefix("@") { return true }
    guard text.hasSuffix("}"), let i = text.firstIndex(of: "{") else { return false }
    return cssParseSelectorList(String(text[text.startIndex..<i])) != nil
}
