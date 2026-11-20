// A minimal `Intl` (ROADMAP Phase 9E item 6): libraries call it unguarded,
// so it has to exist and behave for en-US. Files:
//   jsintl.swift          this file: the Intl namespace, locale negotiation,
//                         option reading, Intl.ListFormat, Intl.Locale
//   jsintl_number.swift   Intl.NumberFormat, Intl.PluralRules,
//                         Number/BigInt toLocaleString
//   jsintl_date.swift     Intl.DateTimeFormat, Intl.RelativeTimeFormat,
//                         Date toLocale*String
//   jsintl_collator.swift Intl.Collator, String.prototype.localeCompare
//
// Scope. Only English data exists: every requested locale whose language is
// "en" resolves to itself (the formatting is en-US), anything else falls
// back to "en-US" (supportedLocalesOf lists only the English ones). Time
// zones: UTC, fixed offsets ("+01:00") and a small table of common IANA
// zones with their US/EU/AU DST rules (jsintl_date.swift). No calendars
// other than gregory, no numbering systems other than latn.
//
// Objects. An Intl object is an ordinary object whose slots are
// [tag (int32, JSIntlKind), resolved options object, ...]. The resolved
// options object is exactly what resolvedOptions() returns (a copy); the
// format code decodes it into a Swift struct on every call (cheap) so
// there is no side table to free. Native code reads it with
// `heap.intlRaw`, which never runs JS.
//
// API (JSRealm): intlNumberFormatString(x, locales, options) and friends
// are used by the toLocale* methods; jsInstallIntl installs everything
// (one line in installBuiltins).

enum JSIntlKind: Int32 {
    case numberFormat = 0x1A01, dateTimeFormat, pluralRules, collator, relativeTimeFormat, listFormat, locale
}

/// A formatted piece: type ("integer", "literal", ...) and text.
struct JSIntlPart {
    var type: String
    var text: [UInt16]
    /// RelativeTimeFormat number parts carry their unit.
    var unit: String = ""
}

@inline(__always) func intlU16(_ s: String) -> [UInt16] { Array(s.utf16) }

func intlPartsText(_ parts: [JSIntlPart]) -> [UInt16] {
    var out: [UInt16] = []
    for p in parts { out.append(contentsOf: p.text) }
    return out
}

extension JSHeap {
    /// An own data property of one of our resolved-options objects (no JS).
    func intlRaw(_ o: JSValue, _ name: String) -> JSValue {
        if case .value(let v) = getProperty(o, key(name)) { return v }
        return .undefined
    }
    func intlRawString(_ o: JSValue, _ name: String, _ dflt: String = "") -> String {
        let v = intlRaw(o, name)
        return v.isString ? swiftString(v) : dflt
    }
    func intlRawInt(_ o: JSValue, _ name: String, _ dflt: Int = 0) -> Int {
        let v = intlRaw(o, name)
        return v.isNumber ? Int(v.numberValue) : dflt
    }
    func intlRawBool(_ o: JSValue, _ name: String, _ dflt: Bool = false) -> Bool {
        let v = intlRaw(o, name)
        return v.isBool ? v.boolValue : dflt
    }
}

extension JSRealm {
    // MARK: Objects

    func intlNew(proto: JSValue, kind: JSIntlKind, resolved: JSValue) -> JSValue {
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        _ = heap.root(proto); _ = heap.root(resolved)
        let o = heap.newObject(proto: proto)
        heap.setSlots(o, [.int32(kind.rawValue), resolved, .undefined, .undefined])
        return o
    }

    /// `this` check: returns the resolved options object.
    func intlThis(_ v: JSValue, _ kind: JSIntlKind, _ method: String) throws(JSThrow) -> JSValue {
        if v.isObject, heap.kind(v) == .ordinary, heap.slotCount(v) >= 2,
           heap.slot(v, 0) == .int32(kind.rawValue) {
            return heap.slot(v, 1)
        }
        throw throwTypeError("Method " + method + " called on incompatible receiver " + describeForError(v))
    }

    /// The prototype for `new Intl.X` (honours new.target).
    func intlProto(_ args: JSArgs) throws(JSThrow) -> JSValue {
        let nt = args.isConstruct ? args.newTarget : args.callee
        let p = try getV(nt, heap.names.prototype)
        if p.isObject { return p }
        return try getV(args.callee, heap.names.prototype)
    }

    // MARK: Options

    func intlOptions(_ v: JSValue) throws(JSThrow) -> JSValue {
        if v.isUndefined { return heap.newObject(proto: .null) }
        if v.isNull { throw throwTypeError("Cannot convert undefined or null to object") }
        return try toObject(v)
    }

    /// GetOption for strings: nil when absent; RangeError when not allowed.
    func intlGetString(_ o: JSValue, _ name: String, _ allowed: [String]) throws(JSThrow) -> String? {
        let v = try getV(o, heap.key(name))
        if v.isUndefined { return nil }
        let s = heap.swiftString(try toStringValue(v))
        if !allowed.isEmpty && !allowed.contains(s) {
            throw throwRangeError("Value " + s + " out of range for Intl options property " + name)
        }
        return s
    }

    func intlGetBool(_ o: JSValue, _ name: String) throws(JSThrow) -> Bool? {
        let v = try getV(o, heap.key(name))
        if v.isUndefined { return nil }
        return heap.toBoolean(v)
    }

    /// GetNumberOption: nil when absent; RangeError outside min...max.
    func intlGetNumber(_ o: JSValue, _ name: String, _ lo: Int, _ hi: Int) throws(JSThrow) -> Int? {
        let v = try getV(o, heap.key(name))
        if v.isUndefined { return nil }
        let d = try toNumber(v)
        if d.isNaN || d < Double(lo) || d > Double(hi) { throw throwRangeError(name + " value is out of range.") }
        return Int(jsFloor(d))
    }

    func intlDefine(_ o: JSValue, _ name: String, _ v: JSValue) {
        _ = heap.createDataProperty(o, heap.key(name), v)
    }
    func intlDefine(_ o: JSValue, _ name: String, _ s: String) {
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        _ = heap.root(o)
        let v = heap.newString(s)
        _ = heap.root(v)
        _ = heap.createDataProperty(o, heap.key(name), v)
    }

    // MARK: Locales

    /// CanonicalizeLocaleList (strings or an array-like of them).
    func intlCanonicalizeLocales(_ v: JSValue) throws(JSThrow) -> [String] {
        if v.isUndefined { return [] }
        var tags: [String] = []
        if v.isString {
            tags.append(try intlCanonTag(heap.swiftString(v)))
            return tags
        }
        if v.isNull { throw throwTypeError("Cannot convert undefined or null to object") }
        let o = try toObject(v)
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        _ = heap.root(o)
        if heap.kind(o) == .ordinary && heap.slotCount(o) >= 2 && heap.slot(o, 0) == .int32(JSIntlKind.locale.rawValue) {
            return [heap.swiftString(heap.intlRaw(heap.slot(o, 1), "tag"))]
        }
        let n = try toLength(try getV(o, heap.names.length))
        var i = 0
        while i < n && i < 1000 {
            let k = try toPropertyKey(.number(i))
            if try objHas(o, k) {
                let e = try getV(o, k)
                guard e.isString || e.isObject else { throw throwTypeError("Language ID should be string or object.") }
                let s = e.isString ? e : try toStringValue(e)
                _ = heap.root(s)
                let t = try intlCanonTag(heap.swiftString(s))
                if !tags.contains(t) { tags.append(t) }
            }
            i += 1
        }
        return tags
    }

    /// Validates a BCP 47 tag (structurally) and canonicalizes its case.
    func intlCanonTag(_ s: String) throws(JSThrow) -> String {
        let bytes = Array(s.utf8)
        var subs: [[UInt8]] = []
        var cur: [UInt8] = []
        for b in bytes {
            if b == 0x2D || b == 0x5F {
                if cur.isEmpty { throw throwRangeError("Incorrect locale information provided") }
                subs.append(cur); cur = []
            } else if (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) {
                cur.append(b)
            } else { throw throwRangeError("Incorrect locale information provided") }
        }
        if cur.isEmpty { throw throwRangeError("Incorrect locale information provided") }
        subs.append(cur)
        func lower(_ x: [UInt8]) -> [UInt8] { x.map { $0 >= 0x41 && $0 <= 0x5A ? $0 + 32 : $0 } }
        func isAlpha(_ x: [UInt8]) -> Bool { x.allSatisfy { ($0 | 0x20) >= 0x61 && ($0 | 0x20) <= 0x7A } }
        let lang = lower(subs[0])
        guard isAlpha(lang), lang.count >= 2, lang.count <= 8, lang.count != 4 else {
            throw throwRangeError("Incorrect locale information provided")
        }
        var out: [[UInt8]] = [lang]
        var i = 1
        var seenExt = false
        while i < subs.count {
            let p = subs[i]
            let l = lower(p)
            if seenExt {
                out.append(l)
            } else if p.count == 1 {
                seenExt = true
                out.append(l)
            } else if p.count == 4 && isAlpha(p) && out.count == 1 {
                out.append([l[0] - 32] + l[1...])
            } else if (p.count == 2 && isAlpha(p)) || (p.count == 3 && p.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }) {
                out.append(p.map { $0 >= 0x61 && $0 <= 0x7A ? $0 - 32 : $0 })
            } else if p.count >= 4 && p.count <= 8 {
                out.append(l)
            } else {
                throw throwRangeError("Incorrect locale information provided")
            }
            i += 1
        }
        var r: [UInt8] = []
        for (k, p) in out.enumerated() {
            if k > 0 { r.append(0x2D) }
            r.append(contentsOf: p)
        }
        return String(decoding: r, as: UTF8.self)
    }

    /// Only English has data: the first requested English tag (without
    /// extensions) or "en-US".
    func intlResolveLocale(_ tags: [String]) -> String {
        for t in tags {
            if let b = intlEnglishBase(t) { return b }
        }
        return "en-US"
    }

    /// "en", "en-GB" ... (no extension, no variants), nil for other languages.
    func intlEnglishBase(_ tag: String) -> String? {
        let parts = tag.split(separator: "-", omittingEmptySubsequences: false)
        guard let l = parts.first, l == "en" else { return nil }
        var out = "en"
        var i = 1
        if i < parts.count && parts[i].utf8.count == 4 { out += "-" + String(parts[i]); i += 1 }
        if i < parts.count && (parts[i].utf8.count == 2 || (parts[i].utf8.count == 3 && parts[i].utf8.first.map { $0 >= 0x30 && $0 <= 0x39 } == true)) {
            out += "-" + String(parts[i])
        }
        return out
    }

    /// Reads the `locales` argument and returns the resolved locale.
    func intlLocale(_ locales: JSValue) throws(JSThrow) -> String {
        intlResolveLocale(try intlCanonicalizeLocales(locales))
    }

    func intlSupportedLocalesOf(_ locales: JSValue, _ options: JSValue) throws(JSThrow) -> JSValue {
        let tags = try intlCanonicalizeLocales(locales)
        if !options.isUndefined {
            let o = try intlOptions(options)
            _ = try intlGetString(o, "localeMatcher", ["lookup", "best fit"])
        }
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        var vals: [JSValue] = []
        for t in tags where intlEnglishBase(t) != nil {
            let v = heap.newString(t)
            _ = heap.root(v)
            vals.append(v)
        }
        return heap.newArray(proto: arrayPrototype, elements: vals)
    }

    /// Install `Intl.<name>` as a constructor with `prototype`; the prototype
    /// gets @@toStringTag "Intl.<name>" and supportedLocalesOf is a static.
    @discardableResult
    func intlDefineClass(_ intl: JSValue, _ name: String, length: Int, proto: JSValue,
                         _ fn: @escaping JSNativeFunction) -> JSValue {
        let r = heap.root(intl)
        _ = heap.root(proto)
        let f = newNativeFunction(registerNative(name, length: length, fn), constructor: true)
        _ = heap.root(f)
        _ = heap.defineOwnProperty(f, heap.names.prototype, .data(proto, []))
        _ = heap.defineOwnProperty(proto, heap.names.constructor, .data(f, [.writable, .configurable]))
        _ = heap.defineOwnProperty(proto, .symbol(heap.symbolsWellKnown.toStringTag.handle),
                                   .data(string("Intl." + name), [.configurable]))
        _ = heap.defineOwnProperty(intl, heap.key(name), .data(f, [.writable, .configurable]))
        defineMethod(f, "supportedLocalesOf", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            try realm.intlSupportedLocalesOf(args[0], args[1])
        }
        heap.popRoots(to: r.slot)
        return f
    }
}

// MARK: Install

func jsInstallIntl(_ realm: JSRealm) {
    let heap = realm.heap
    let intl = heap.newObject(proto: realm.objectPrototype)
    _ = heap.root(intl)
    _ = heap.defineOwnProperty(intl, .symbol(heap.symbolsWellKnown.toStringTag.handle),
                               .data(realm.string("Intl"), [.configurable]))
    realm.defineGlobal("Intl", intl)
    realm.defineMethod(intl, "getCanonicalLocales", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let tags = try realm.intlCanonicalizeLocales(args[0])
        let d = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: d) }
        var vals: [JSValue] = []
        for t in tags { let v = realm.heap.newString(t); _ = realm.heap.root(v); vals.append(v) }
        return realm.heap.newArray(proto: realm.arrayPrototype, elements: vals)
    }
    realm.defineMethod(intl, "supportedValuesOf", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let k = realm.heap.swiftString(try realm.toStringValue(args[0]))
        var items: [String]
        switch k {
        case "calendar": items = ["gregory"]
        case "collation": items = ["default"]
        case "currency": items = ["AUD", "BRL", "CAD", "CHF", "CNY", "EUR", "GBP", "INR", "JPY", "KRW", "MXN", "USD"]
        case "numberingSystem": items = ["latn"]
        case "timeZone": items = jsIntlTimeZoneNames()
        case "unit": items = jsIntlUnitNames()
        default: throw realm.throwRangeError("Invalid key : " + k)
        }
        let d = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: d) }
        var vals: [JSValue] = []
        for t in items { let v = realm.heap.newString(t); _ = realm.heap.root(v); vals.append(v) }
        return realm.heap.newArray(proto: realm.arrayPrototype, elements: vals)
    }
    jsInstallIntlNumber(realm, intl)
    jsInstallIntlDate(realm, intl)
    jsInstallIntlCollator(realm, intl)
    jsInstallIntlMisc(realm, intl)
}

// MARK: ListFormat and Locale

extension JSRealm {
    /// Strings of an iterable (ListFormat): TypeError for non-strings.
    func intlStringList(_ v: JSValue) throws(JSThrow) -> [JSValue] {
        if v.isUndefined { return [] }
        let d = heap.rootDepth
        var out: [JSValue] = []
        let (it, next) = try getIterator(v)
        _ = heap.root(it); _ = heap.root(next)
        while true {
            let (done, x) = try iteratorStep(it, next)
            if done { break }
            _ = heap.root(x)
            if !x.isString {
                heap.popRoots(to: d)
                throw throwTypeError("Iterable yielded " + describeForError(x) + " which is not a string")
            }
            out.append(x)
            if out.count > 100_000 { heap.popRoots(to: d); throw throwRangeError("Invalid list length") }
        }
        // The elements stay rooted until the caller's scope ends.
        return out
    }
}

func jsInstallIntlMisc(_ realm: JSRealm, _ intl: JSValue) {
    let heap = realm.heap
    // ---------------------------------------------------------- ListFormat
    let lfp = heap.newObject(proto: realm.objectPrototype)
    _ = heap.root(lfp)
    realm.intlDefineClass(intl, "ListFormat", length: 0, proto: lfp) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        if !args.isConstruct { throw realm.throwTypeError("Constructor Intl.ListFormat requires 'new'") }
        let proto = try realm.intlProto(args)
        let loc = try realm.intlLocale(args[0])
        let opts = try realm.intlOptions(args[1])
        let d = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: d) }
        _ = realm.heap.root(opts)
        let type = try realm.intlGetString(opts, "type", ["conjunction", "disjunction", "unit"]) ?? "conjunction"
        let style = try realm.intlGetString(opts, "style", ["long", "short", "narrow"]) ?? "long"
        let res = realm.heap.newObject(proto: realm.objectPrototype)
        _ = realm.heap.root(res)
        realm.intlDefine(res, "locale", loc)
        realm.intlDefine(res, "type", type)
        realm.intlDefine(res, "style", style)
        return realm.intlNew(proto: proto, kind: .listFormat, resolved: res)
    }
    func listParts(_ realm: JSRealm, _ this: JSValue, _ list: JSValue, _ method: String) throws(JSThrow) -> [JSIntlPart] {
        let res = try realm.intlThis(this, .listFormat, method)
        let items = try realm.intlStringList(list)
        let type = realm.heap.intlRawString(res, "type")
        let style = realm.heap.intlRawString(res, "style")
        return jsIntlListParts(items.map { realm.heap.stringUnits($0) }, type: type, style: style)
    }
    realm.defineMethod(lfp, "format", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let d = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: d) }
        let parts = try listParts(realm, args.this, args[0], "Intl.ListFormat.prototype.format")
        return realm.heap.newString(utf16: intlPartsText(parts))
    }
    realm.defineMethod(lfp, "formatToParts", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let d = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: d) }
        let parts = try listParts(realm, args.this, args[0], "Intl.ListFormat.prototype.formatToParts")
        return realm.intlPartsArray(parts)
    }
    realm.defineMethod(lfp, "resolvedOptions", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let res = try realm.intlThis(args.this, .listFormat, "Intl.ListFormat.prototype.resolvedOptions")
        return realm.intlCopyOptions(res)
    }
    // -------------------------------------------------------------- Locale
    let lop = heap.newObject(proto: realm.objectPrototype)
    _ = heap.root(lop)
    realm.intlDefineClass(intl, "Locale", length: 1, proto: lop) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        if !args.isConstruct { throw realm.throwTypeError("Constructor Intl.Locale requires 'new'") }
        let proto = try realm.intlProto(args)
        guard args[0].isString || args[0].isObject else { throw realm.throwTypeError("First argument to Intl.Locale constructor can't be empty or missing") }
        let d = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: d) }
        var tag: String
        if args[0].isObject, realm.heap.kind(args[0]) == .ordinary, realm.heap.slotCount(args[0]) >= 2,
           realm.heap.slot(args[0], 0) == .int32(JSIntlKind.locale.rawValue) {
            tag = realm.heap.intlRawString(realm.heap.slot(args[0], 1), "tag")
        } else {
            tag = try realm.intlCanonTag(realm.heap.swiftString(try realm.toStringValue(args[0])))
        }
        let opts = try realm.intlOptions(args[1])
        _ = realm.heap.root(opts)
        // Options override language / script / region.
        let parts = tag.split(separator: "-", omittingEmptySubsequences: false).map { String($0) }
        var lang = parts[0], script = "", region = "", rest: [String] = []
        var i = 1
        if i < parts.count && parts[i].utf8.count == 4 { script = parts[i]; i += 1 }
        if i < parts.count && (parts[i].utf8.count == 2 || parts[i].utf8.count == 3 && parts[i].utf8.first.map { $0 >= 0x30 && $0 <= 0x39 } == true) { region = parts[i]; i += 1 }
        while i < parts.count { rest.append(parts[i]); i += 1 }
        if let l = try realm.intlGetString(opts, "language", []) { lang = try realm.intlCanonTag(l) }
        if let s = try realm.intlGetString(opts, "script", []) { script = String(try realm.intlCanonTag("en-" + s).dropFirst(3)) }
        if let r = try realm.intlGetString(opts, "region", []) { region = String(try realm.intlCanonTag("en-" + r).dropFirst(3)) }
        var full = lang
        if !script.isEmpty { full += "-" + script }
        if !region.isEmpty { full += "-" + region }
        let base = full
        for r in rest { full += "-" + r }
        let res = realm.heap.newObject(proto: .null)
        _ = realm.heap.root(res)
        realm.intlDefine(res, "tag", full)
        realm.intlDefine(res, "baseName", base)
        realm.intlDefine(res, "language", lang)
        if !script.isEmpty { realm.intlDefine(res, "script", script) }
        if !region.isEmpty { realm.intlDefine(res, "region", region) }
        return realm.intlNew(proto: proto, kind: .locale, resolved: res)
    }
    for name in ["baseName", "language", "script", "region"] {
        realm.defineGetter(lop, name) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let res = try realm.intlThis(args.this, .locale, "Intl.Locale.prototype." + name)
            return realm.heap.intlRaw(res, name)
        }
    }
    realm.defineMethod(lop, "toString", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let res = try realm.intlThis(args.this, .locale, "Intl.Locale.prototype.toString")
        return realm.heap.intlRaw(res, "tag")
    }
    realm.defineMethod(lop, "maximize", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        _ = try realm.intlThis(args.this, .locale, "Intl.Locale.prototype.maximize")
        return args.this
    }
    realm.defineMethod(lop, "minimize", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        _ = try realm.intlThis(args.this, .locale, "Intl.Locale.prototype.minimize")
        return args.this
    }
}

/// en list patterns.
func jsIntlListParts(_ items: [[UInt16]], type: String, style: String) -> [JSIntlPart] {
    var parts: [JSIntlPart] = []
    let n = items.count
    for (i, it) in items.enumerated() {
        if i > 0 {
            var sep: String
            if i == n - 1 {
                switch type {
                case "conjunction":
                    sep = style == "long" ? (n == 2 ? " and " : ", and ") : style == "short" ? (n == 2 ? " & " : ", & ") : (n == 2 ? ", " : ", ")
                case "disjunction": sep = n == 2 ? " or " : ", or "
                default: sep = style == "narrow" ? " " : ", "
                }
            } else {
                sep = type == "unit" && style == "narrow" ? " " : ", "
            }
            parts.append(JSIntlPart(type: "literal", text: intlU16(sep)))
        }
        parts.append(JSIntlPart(type: "element", text: it))
    }
    return parts
}

extension JSRealm {
    /// [{type, value}, ...] as a JS array.
    func intlPartsArray(_ parts: [JSIntlPart]) -> JSValue {
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        var objs: [JSValue] = []
        for p in parts {
            let o = heap.newObject(proto: objectPrototype)
            _ = heap.root(o)
            let t = heap.newString(p.type)
            _ = heap.root(t)
            let v = heap.newString(utf16: p.text)
            _ = heap.root(v)
            _ = heap.createDataProperty(o, heap.key("type"), t)
            _ = heap.createDataProperty(o, heap.key("value"), v)
            if !p.unit.isEmpty {
                let u = heap.newString(p.unit)
                _ = heap.root(u)
                _ = heap.createDataProperty(o, heap.key("unit"), u)
            }
            objs.append(o)
        }
        return heap.newArray(proto: arrayPrototype, elements: objs)
    }

    /// A fresh plain copy of a resolved-options object (resolvedOptions()).
    func intlCopyOptions(_ res: JSValue) -> JSValue {
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        let o = heap.newObject(proto: objectPrototype)
        _ = heap.root(o)
        for k in heap.ownKeys(res) {
            if case .value(let v) = heap.getProperty(res, k) { _ = heap.createDataProperty(o, k, v) }
        }
        return o
    }
}
