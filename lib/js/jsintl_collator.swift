// Intl.Collator and String.prototype.localeCompare (English only).
//
// A small stand-in for ICU's root collation: strings are decomposed (NFD)
// and compared in three passes. Primary: base characters, case and accents
// ignored; whitespace and punctuation sort before digits, digits before
// letters, letters alphabetically. Secondary: accents. Tertiary: case, with
// lowercase first. `sensitivity` picks the passes (base: primary; accent:
// primary + secondary; case: primary + tertiary; variant: all three),
// `numeric` compares digit runs by value, `ignorePunctuation` skips
// whitespace and punctuation, `caseFirst: "upper"` flips the tertiary pass.

struct JSIntlCollation {
    var sensitivity = 3         // 0 base, 1 accent, 2 case, 3 variant
    var numeric = false
    var ignorePunctuation = false
    var upperFirst = false
}

private struct JSCollElem {
    var primary: UInt32 = 0     // class << 24 | value
    var accent: UInt32 = 0
    var upper = false
    var digitRun: [UInt8] = []  // numeric: the digits of a run
}

private func jsCollIsPunct(_ c: UInt32) -> Bool {
    if c < 0x80 {
        return !((c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A))
    }
    return (c >= 0x2000 && c <= 0x206F) || (c >= 0xA0 && c <= 0xBF) || c == 0xD7 || c == 0xF7 || (c >= 0x20A0 && c <= 0x20CF)
}

private func jsCollElements(_ units: [UInt16], _ opt: JSIntlCollation) -> [JSCollElem] {
    let nfd = jsStringNormalize(units, .nfd)
    var out: [JSCollElem] = []
    var i = 0
    while i < nfd.count {
        var c = UInt32(nfd[i])
        var step = 1
        if c >= 0xD800 && c < 0xDC00 && i + 1 < nfd.count && nfd[i + 1] >= 0xDC00 && nfd[i + 1] < 0xE000 {
            c = 0x10000 + ((c - 0xD800) << 10) + (UInt32(nfd[i + 1]) - 0xDC00)
            step = 2
        }
        i += step
        // Combining marks attach to the previous element's accent weight.
        if (c >= 0x300 && c <= 0x36F) || (c >= 0x1AB0 && c <= 0x1AFF) || (c >= 0x20D0 && c <= 0x20FF) {
            if !out.isEmpty { out[out.count - 1].accent = out[out.count - 1].accent &* 31 &+ c }
            continue
        }
        var e = JSCollElem()
        if c >= 0x30 && c <= 0x39 {
            if opt.numeric {
                var run: [UInt8] = [UInt8(c - 0x30)]
                while i < nfd.count && nfd[i] >= 0x30 && nfd[i] <= 0x39 { run.append(UInt8(nfd[i] - 0x30)); i += 1 }
                var lead = 0
                while lead < run.count - 1 && run[lead] == 0 { lead += 1 }
                run.removeFirst(lead)
                e.primary = (2 << 24) | UInt32(run.count)
                e.digitRun = run
            } else {
                e.primary = (2 << 24) | (c - 0x30)
            }
        } else if jsCollIsPunct(c) {
            if opt.ignorePunctuation { continue }
            e.primary = ((c == 0x20 || c == 0xA0 || (c >= 0x2000 && c <= 0x200A) || c < 0x20) ? 0 : 1) << 24 | c
        } else {
            // A letter (or anything else): fold case.
            var base = c
            if c >= 0x41 && c <= 0x5A { base = c + 32; e.upper = true }
            else if c >= 0x80 {
                let low = jsStringToLower([UInt16(truncatingIfNeeded: c)])
                if c < 0x10000, low.count == 1, UInt32(low[0]) != c { base = UInt32(low[0]); e.upper = true }
            }
            e.primary = (3 << 24) | base
        }
        out.append(e)
    }
    return out
}

/// Three-way comparison (-1, 0, 1) of two UTF-16 strings.
func jsIntlCollate(_ a: [UInt16], _ b: [UInt16], _ opt: JSIntlCollation) -> Int {
    let x = jsCollElements(a, opt), y = jsCollElements(b, opt)
    let n = min(x.count, y.count)
    var i = 0
    while i < n {
        if x[i].primary != y[i].primary { return x[i].primary < y[i].primary ? -1 : 1 }
        if opt.numeric && !x[i].digitRun.isEmpty {
            // Same length of run: compare the digits.
            for k in 0..<x[i].digitRun.count where k < y[i].digitRun.count && x[i].digitRun[k] != y[i].digitRun[k] {
                return x[i].digitRun[k] < y[i].digitRun[k] ? -1 : 1
            }
        }
        i += 1
    }
    if x.count != y.count { return x.count < y.count ? -1 : 1 }
    if opt.sensitivity == 1 || opt.sensitivity == 3 {
        for k in 0..<n where x[k].accent != y[k].accent {
            // No accent sorts before an accent.
            if x[k].accent == 0 { return -1 }
            if y[k].accent == 0 { return 1 }
            return x[k].accent < y[k].accent ? -1 : 1
        }
    }
    if opt.sensitivity == 2 || opt.sensitivity == 3 {
        for k in 0..<n where x[k].upper != y[k].upper {
            let lowerFirst = !opt.upperFirst
            return (x[k].upper == !lowerFirst) ? -1 : 1
        }
    }
    return 0
}

extension JSRealm {
    func intlCollatorResolve(_ locales: JSValue, _ options: JSValue) throws(JSThrow) -> JSValue {
        let loc = try intlLocale(locales)
        let opts = try intlOptions(options)
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        _ = heap.root(opts)
        let usage = try intlGetString(opts, "usage", ["sort", "search"]) ?? "sort"
        _ = try intlGetString(opts, "localeMatcher", ["lookup", "best fit"])
        _ = try intlGetString(opts, "collation", [])
        let numeric = try intlGetBool(opts, "numeric") ?? false
        let caseFirst = try intlGetString(opts, "caseFirst", ["upper", "lower", "false"]) ?? "false"
        let sensitivity = try intlGetString(opts, "sensitivity", ["base", "accent", "case", "variant"]) ?? "variant"
        let ignore = try intlGetBool(opts, "ignorePunctuation") ?? false
        let res = heap.newObject(proto: objectPrototype)
        _ = heap.root(res)
        intlDefine(res, "locale", loc)
        intlDefine(res, "usage", usage)
        intlDefine(res, "sensitivity", sensitivity)
        intlDefine(res, "ignorePunctuation", .bool(ignore))
        intlDefine(res, "collation", "default")
        intlDefine(res, "numeric", .bool(numeric))
        intlDefine(res, "caseFirst", caseFirst)
        return res
    }

    func intlCollation(_ res: JSValue) -> JSIntlCollation {
        var c = JSIntlCollation()
        switch heap.intlRawString(res, "sensitivity") {
        case "base": c.sensitivity = 0
        case "accent": c.sensitivity = 1
        case "case": c.sensitivity = 2
        default: c.sensitivity = 3
        }
        c.numeric = heap.intlRawBool(res, "numeric")
        c.ignorePunctuation = heap.intlRawBool(res, "ignorePunctuation")
        c.upperFirst = heap.intlRawString(res, "caseFirst") == "upper"
        return c
    }
}

func jsInstallIntlCollator(_ realm: JSRealm, _ intl: JSValue) {
    let heap = realm.heap
    let cp = heap.newObject(proto: realm.objectPrototype)
    _ = heap.root(cp)
    realm.intlDefineClass(intl, "Collator", length: 0, proto: cp) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let proto = try realm.intlProto(args)
        let d = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: d) }
        _ = realm.heap.root(proto)
        let res = try realm.intlCollatorResolve(args[0], args[1])
        return realm.intlNew(proto: proto, kind: .collator, resolved: res)
    }
    let boundCompare = realm.registerNative("", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let c = realm.heap.slot(args.callee, 0)
        let res = realm.heap.slot(c, 1)
        let a = try realm.toStringValue(args[0])
        let d = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: d) }
        _ = realm.heap.root(a)
        let b = try realm.toStringValue(args[1])
        return .int32(Int32(jsIntlCollate(realm.heap.stringUnits(a), realm.heap.stringUnits(b), realm.intlCollation(res))))
    }
    realm.defineGetter(cp, "compare") { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        _ = try realm.intlThis(args.this, .collator, "get Intl.Collator.prototype.compare")
        let cached = realm.heap.slot(args.this, 2)
        if cached.isObject { return cached }
        let f = realm.nativeClosure(boundCompare, [args.this])
        realm.heap.setSlot(args.this, 2, f)
        return f
    }
    realm.defineMethod(cp, "resolvedOptions", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let res = try realm.intlThis(args.this, .collator, "Intl.Collator.prototype.resolvedOptions")
        return realm.intlCopyOptions(res)
    }
    // String.prototype.localeCompare.
    let sp = realm.intrinsic(.stringPrototype)
    realm.defineMethod(sp, "localeCompare", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let this = args.this
        if this.isNullish { throw realm.throwTypeError("String.prototype.localeCompare called on null or undefined") }
        let d = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: d) }
        let s = try realm.toStringValue(this)
        _ = realm.heap.root(s)
        let that = try realm.toStringValue(args[0])
        _ = realm.heap.root(that)
        var opt = JSIntlCollation()
        if !args[1].isUndefined || !args[2].isUndefined {
            let res = try realm.intlCollatorResolve(args[1], args[2])
            opt = realm.intlCollation(res)
        }
        return .int32(Int32(jsIntlCollate(realm.heap.stringUnits(s), realm.heap.stringUnits(that), opt)))
    }
}
