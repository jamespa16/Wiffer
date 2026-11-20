// String built-ins (ROADMAP Phase 9C): String.fromCharCode / fromCodePoint /
// raw and every String.prototype method of ECMAScript 2023 including the
// Annex B ones (substr, trimLeft/Right, the HTML methods), the Unicode case
// mapping and normalization (jsstringunicode.swift) and the RegExp-facing
// methods (match, matchAll, replace, replaceAll, search, split), which
// dispatch through Symbol.match & co. to jsbuiltins_regexp.swift.
//
// The constructor and @@iterator are the base skeleton's (jsbuiltins_base).
//
// Shared helpers for this file and the RegExp / Date / Symbol files are
// prefixed `b2` (b2Rooted, b2GetMethod, ...): they are internal to lib/js.

// MARK: Shared helpers

/// Wraps a native so every heap root it pushes is popped when it returns.
func b2Rooted(_ f: @escaping JSNativeFunction) -> JSNativeFunction {
    return { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let rd = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: rd) }
        return try f(realm, args)
    }
}

extension JSHeap {
    /// Appends units [from, to) of a heap string to a builder.
    func b2Append(_ sb: inout JSStringBuilder, _ v: JSValue, _ from: Int = 0, _ toIn: Int = Int.max) {
        guard let i = stringCell(v) else { return }
        let n = strings[i].count
        let to = toIn < n ? toIn : n
        let f = from > 0 ? from : 0
        if f >= to { return }
        if strings[i].isWide {
            sb.widen()
            sb.utf16.append(contentsOf: strings[i].utf16[f..<to])
        } else {
            sb.append(ascii: Array(strings[i].latin1[f..<to]))
        }
    }

    /// Forward search of `pat` in a heap string from `from`; -1 if none.
    func b2IndexOf(_ s: JSValue, _ pat: [UInt16], _ from: Int) -> Int {
        guard let i = stringCell(s) else { return pat.isEmpty && from == 0 ? 0 : -1 }
        if strings[i].isWide {
            return strings[i].utf16.withUnsafeBufferPointer { b2FindForward($0, pat, from) }
        }
        return strings[i].latin1.withUnsafeBufferPointer { b2FindForward($0, pat, from) }
    }

    /// Backward search: the largest start <= `from`; -1 if none.
    func b2LastIndexOf(_ s: JSValue, _ pat: [UInt16], _ from: Int) -> Int {
        guard let i = stringCell(s) else { return pat.isEmpty && from >= 0 ? 0 : -1 }
        if strings[i].isWide {
            return strings[i].utf16.withUnsafeBufferPointer { b2FindBackward($0, pat, from) }
        }
        return strings[i].latin1.withUnsafeBufferPointer { b2FindBackward($0, pat, from) }
    }

    /// Does the string have `pat` starting at `at`?
    func b2HasAt(_ s: JSValue, _ pat: [UInt16], _ at: Int) -> Bool {
        let n = stringLength(s)
        if at < 0 || at + pat.count > n { return false }
        var k = 0
        while k < pat.count {
            if charCode(s, at + k) != pat[k] { return false }
            k += 1
        }
        return true
    }
}

func b2FindForward<S: RandomAccessCollection>(_ s: S, _ pat: [UInt16], _ fromIn: Int) -> Int
    where S.Element: FixedWidthInteger & UnsignedInteger, S.Index == Int {
    let n = s.count, m = pat.count
    let from = fromIn < 0 ? 0 : fromIn
    if m == 0 { return from <= n ? from : -1 }
    if from > n - m { return -1 }
    if m <= 8 {
        let first = pat[0]
        var i = from
        let last = n - m
        while i <= last {
            if UInt16(truncatingIfNeeded: s[i]) == first {
                var k = 1
                while k < m && UInt16(truncatingIfNeeded: s[i + k]) == pat[k] { k += 1 }
                if k == m { return i }
            }
            i += 1
        }
        return -1
    }
    // Knuth-Morris-Pratt: linear even for hostile inputs.
    var fail = [Int32](repeating: 0, count: m)
    var k = 0
    var q = 1
    while q < m {
        while k > 0 && pat[k] != pat[q] { k = Int(fail[k - 1]) }
        if pat[k] == pat[q] { k += 1 }
        fail[q] = Int32(k)
        q += 1
    }
    k = 0
    var i = from
    while i < n {
        let u = UInt16(truncatingIfNeeded: s[i])
        while k > 0 && pat[k] != u { k = Int(fail[k - 1]) }
        if pat[k] == u { k += 1 }
        if k == m { return i - m + 1 }
        i += 1
    }
    return -1
}

func b2FindBackward<S: RandomAccessCollection>(_ s: S, _ pat: [UInt16], _ fromIn: Int) -> Int
    where S.Element: FixedWidthInteger & UnsignedInteger, S.Index == Int {
    let n = s.count, m = pat.count
    var from = fromIn
    if from > n - m { from = n - m }
    if from < 0 { return -1 }
    if m == 0 { return from }
    if m <= 8 {
        var i = from
        let first = pat[0]
        while i >= 0 {
            if UInt16(truncatingIfNeeded: s[i]) == first {
                var k = 1
                while k < m && UInt16(truncatingIfNeeded: s[i + k]) == pat[k] { k += 1 }
                if k == m { return i }
            }
            i -= 1
        }
        return -1
    }
    // KMP on the reversed pattern, scanning backwards.
    var rp = [UInt16](repeating: 0, count: m)
    var t = 0
    while t < m { rp[t] = pat[m - 1 - t]; t += 1 }
    var fail = [Int32](repeating: 0, count: m)
    var k = 0
    var q = 1
    while q < m {
        while k > 0 && rp[k] != rp[q] { k = Int(fail[k - 1]) }
        if rp[k] == rp[q] { k += 1 }
        fail[q] = Int32(k)
        q += 1
    }
    k = 0
    var i = from + m - 1
    while i >= 0 {
        let u = UInt16(truncatingIfNeeded: s[i])
        while k > 0 && rp[k] != u { k = Int(fail[k - 1]) }
        if rp[k] == u { k += 1 }
        if k == m { return i }
        i -= 1
    }
    return -1
}

extension JSRealm {
    /// GetMethod: undefined for null/undefined, TypeError if not callable.
    func b2GetMethod(_ v: JSValue, _ k: JSPropertyKey) throws(JSThrow) -> JSValue {
        let f = try getV(v, k)
        if f.isNullish { return .undefined }
        guard heap.isCallable(f) else { throw throwTypeError(keyDisplay(k) + " is not a function") }
        return f
    }

    /// ToIntegerOrInfinity(ToNumber(v)).
    func b2ToInt(_ v: JSValue) throws(JSThrow) -> Double {
        if v.isInt32 { return Double(v.asInt32) }
        return jsToIntegerOrInfinity(try toNumber(v))
    }

    /// ToString, keeping the result rooted until the enclosing b2Rooted native returns.
    func b2Str(_ v: JSValue) throws(JSThrow) -> JSValue {
        let s = v.isString ? v : try toStringValue(v)
        _ = heap.root(s)
        return s
    }

    /// RequireObjectCoercible(this) then ToString.
    func b2This(_ args: JSArgs, _ method: String) throws(JSThrow) -> JSValue {
        let t = args.this
        if t.isNullish { throw throwTypeError("String.prototype." + method + " called on null or undefined") }
        return try b2Str(t)
    }

    func b2WellKnown(_ s: JSValue) -> JSPropertyKey { .symbol(s.handle) }

    /// IsRegExp.
    func b2IsRegExp(_ v: JSValue) throws(JSThrow) -> Bool {
        guard v.isObject else { return false }
        let m = try getV(v, b2WellKnown(heap.symbolsWellKnown.match))
        if !m.isUndefined { return heap.toBoolean(m) }
        return heap.kind(v) == .regexp
    }

    /// A fresh empty Array (rooted by the caller).
    func b2NewArray() -> JSValue { heap.newArray(proto: arrayPrototype) }

    func b2ArrayPush(_ a: JSValue, _ v: JSValue) {
        _ = heap.createDataProperty(a, .index(heap.arrayLength(a)), v)
    }

    /// The finished builder as a string, or a RangeError if it is too long.
    func b2Finish(_ sb: JSStringBuilder) throws(JSThrow) -> JSValue {
        if sb.count > limits.maxStringLength { throw throwRangeError("Invalid string length") }
        return heap.newString(sb)
    }

    func b2CheckLength(_ sb: JSStringBuilder) throws(JSThrow) {
        if sb.count > limits.maxStringLength { throw throwRangeError("Invalid string length") }
    }

    func b2IsConstructor(_ v: JSValue) -> Bool { v.isObject && heap.flags(v).contains(.constructor) }

    /// SpeciesConstructor(O, default).
    func b2SpeciesConstructor(_ o: JSValue, _ dflt: JSValue) throws(JSThrow) -> JSValue {
        let c = try getV(o, heap.names.constructor)
        if c.isUndefined { return dflt }
        guard c.isObject else { throw throwTypeError("object.constructor is not an object") }
        let s = try getV(c, b2WellKnown(heap.symbolsWellKnown.species))
        if s.isNullish { return dflt }
        if b2IsConstructor(s) { return s }
        throw throwTypeError("object.constructor[Symbol.species] is not a constructor")
    }

    /// Index clamped for slice-like relative arguments.
    func b2Rel(_ d: Double, _ len: Int) -> Int {
        if d < 0 {
            let t = Double(len) + d
            return t <= 0 ? 0 : Int(t)
        }
        return d >= Double(len) ? len : Int(d)
    }

    func b2Clamp(_ d: Double, _ lo: Int, _ hi: Int) -> Int {
        if d <= Double(lo) { return lo }
        if d >= Double(hi) { return hi }
        return Int(d)
    }

    /// GetSubstitution. `captures` hold strings or undefined (rooted by the caller).
    func b2GetSubstitution(_ matched: JSValue, _ str: JSValue, _ position: Int, _ captures: [JSValue],
                           _ namedCaptures: JSValue, _ replacement: JSValue) throws(JSThrow) -> JSValue {
        let tpl = heap.stringUnits(replacement)
        let n = tpl.count
        var sb = JSStringBuilder()
        let strLen = heap.stringLength(str)
        let matchLen = heap.stringLength(matched)
        var i = 0
        while i < n {
            let c = tpl[i]
            if c != 0x24 || i + 1 >= n {
                sb.append(unit: c)
                i += 1
                continue
            }
            let d = tpl[i + 1]
            if d == 0x24 { sb.append(unit: 0x24); i += 2 }
            else if d == 0x60 { heap.b2Append(&sb, str, 0, position); i += 2 }
            else if d == 0x26 { heap.b2Append(&sb, matched); i += 2 }
            else if d == 0x27 {
                let tail = position + matchLen
                if tail < strLen { heap.b2Append(&sb, str, tail) }
                i += 2
            } else if d >= 0x30 && d <= 0x39 {
                var digitCount = 1
                var index = Int(d - 0x30)
                if i + 2 < n && tpl[i + 2] >= 0x30 && tpl[i + 2] <= 0x39 {
                    let two = index * 10 + Int(tpl[i + 2] - 0x30)
                    if two <= captures.count { digitCount = 2; index = two }
                }
                if index >= 1 && index <= captures.count {
                    let cap = captures[index - 1]
                    if !cap.isUndefined { heap.b2Append(&sb, cap) }
                } else {
                    var k = 0
                    while k < 1 + digitCount { sb.append(unit: tpl[i + k]); k += 1 }
                }
                i += 1 + digitCount
            } else if d == 0x3C {
                var gt = -1
                var k = i + 2
                while k < n { if tpl[k] == 0x3E { gt = k; break }; k += 1 }
                if gt < 0 || namedCaptures.isUndefined {
                    sb.append(unit: 0x24); sb.append(unit: 0x3C)
                    i += 2
                } else {
                    let name = heap.newString(utf16: Array(tpl[(i + 2)..<gt]))
                    _ = heap.root(name)
                    let key = try toPropertyKey(name)
                    let cap = try getV(namedCaptures, key)
                    if !cap.isUndefined {
                        let cs = try toStringValue(cap)
                        heap.b2Append(&sb, cs)
                    }
                    i = gt + 1
                }
            } else {
                sb.append(unit: c)
                i += 1
            }
            try b2CheckLength(sb)
        }
        return try b2Finish(sb)
    }

    /// RegExpCreate(P, F) from JS values (undefined allowed).
    func b2RegExpCreateValue(_ p: JSValue, _ f: JSValue) throws(JSThrow) -> JSValue {
        let o = try regExpAlloc(intrinsic(.regExpConstructor))
        _ = heap.root(o)
        return try regExpInitialize(o, p, f)
    }
}

// MARK: Installation

func jsInstallString(_ realm: JSRealm) {
    let heap = realm.heap
    let sp = realm.intrinsic(.stringPrototype)
    let sc = realm.intrinsic(.stringConstructor)
    jsInstallStringStatics(realm, sc)
    jsInstallStringBasic(realm, sp)
    jsInstallStringSearch(realm, sp)
    jsInstallStringTransform(realm, sp)
    jsInstallStringRegExpMethods(realm, sp)
    jsInstallStringHTML(realm, sp)
    _ = heap
}

private func jsInstallStringStatics(_ realm: JSRealm, _ sc: JSValue) {
    realm.defineMethod(sc, "fromCharCode", length: 1, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        var units: [UInt16] = []
        units.reserveCapacity(args.count)
        for i in 0..<args.count { units.append(jsToUint16(try realm.toNumber(args[i]))) }
        return realm.heap.newString(utf16: units)
    })
    realm.defineMethod(sc, "fromCodePoint", length: 1, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        var units: [UInt16] = []
        units.reserveCapacity(args.count)
        for i in 0..<args.count {
            let d = try realm.toNumber(args[i])
            if d.isNaN || d != jsTrunc(d) || d < 0 || d > 1114111 {
                throw realm.throwRangeError("Invalid code point " + realm.safeToString(args[i]))
            }
            jsAppendCodePoint(&units, UInt32(d))
        }
        return realm.heap.newString(utf16: units)
    })
    realm.defineMethod(sc, "raw", length: 1, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let cooked = try realm.toObject(args[0])
        _ = realm.heap.root(cooked)
        let rawV = try realm.getV(cooked, realm.heap.names.raw)
        let literals = try realm.toObject(rawV)
        _ = realm.heap.root(literals)
        let count = try realm.toLength(try realm.getV(literals, realm.heap.names.length))
        if count <= 0 { return .string(0) }
        var sb = JSStringBuilder()
        var i = 0
        while i < count {
            let key: JSPropertyKey = i < 0xFFFF_FFFF ? .index(UInt32(i)) : try realm.toPropertyKey(.number(i))
            let lit = try realm.toStringValue(try realm.getV(literals, key))
            realm.heap.b2Append(&sb, lit)
            try realm.b2CheckLength(sb)
            if i + 1 == count { break }
            if i + 1 <= args.count - 1 {
                let sub = try realm.toStringValue(args[i + 1])
                realm.heap.b2Append(&sb, sub)
                try realm.b2CheckLength(sb)
            }
            i += 1
        }
        return try realm.b2Finish(sb)
    })
}

private func jsInstallStringBasic(_ realm: JSRealm, _ sp: JSValue) {
    realm.defineMethod(sp, "at", length: 1, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let s = try realm.b2This(args, "at")
        let len = realm.heap.stringLength(s)
        let d = try realm.b2ToInt(args[0])
        let k = d >= 0 ? d : Double(len) + d
        if k < 0 || k >= Double(len) { return .undefined }
        return realm.heap.singleUnitString(realm.heap.charCode(s, Int(k)), protecting: s)
    })
    realm.defineMethod(sp, "charAt", length: 1, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let s = try realm.b2This(args, "charAt")
        let d = try realm.b2ToInt(args[0])
        if d < 0 || d >= Double(realm.heap.stringLength(s)) { return .string(0) }
        return realm.heap.singleUnitString(realm.heap.charCode(s, Int(d)), protecting: s)
    })
    realm.defineMethod(sp, "charCodeAt", length: 1, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let s = try realm.b2This(args, "charCodeAt")
        let d = try realm.b2ToInt(args[0])
        if d < 0 || d >= Double(realm.heap.stringLength(s)) { return .nan }
        return .int32(Int32(realm.heap.charCode(s, Int(d))))
    })
    realm.defineMethod(sp, "codePointAt", length: 1, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let s = try realm.b2This(args, "codePointAt")
        let d = try realm.b2ToInt(args[0])
        if d < 0 || d >= Double(realm.heap.stringLength(s)) { return .undefined }
        return .number(Int(realm.heap.codePoint(s, Int(d))))
    })
    realm.defineMethod(sp, "concat", length: 1, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let s = try realm.b2This(args, "concat")
        var sb = JSStringBuilder()
        realm.heap.b2Append(&sb, s)
        for i in 0..<args.count {
            let a = try realm.b2Str(args[i])
            realm.heap.b2Append(&sb, a)
            try realm.b2CheckLength(sb)
        }
        return try realm.b2Finish(sb)
    })
    realm.defineMethod(sp, "slice", length: 2, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let s = try realm.b2This(args, "slice")
        let len = realm.heap.stringLength(s)
        let from = realm.b2Rel(try realm.b2ToInt(args[0]), len)
        let to = args[1].isUndefined ? len : realm.b2Rel(try realm.b2ToInt(args[1]), len)
        if from >= to { return .string(0) }
        return realm.heap.substring(s, from, to)
    })
    realm.defineMethod(sp, "substring", length: 2, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let s = try realm.b2This(args, "substring")
        let len = realm.heap.stringLength(s)
        let a = realm.b2Clamp(try realm.b2ToInt(args[0]), 0, len)
        let b = args[1].isUndefined ? len : realm.b2Clamp(try realm.b2ToInt(args[1]), 0, len)
        return realm.heap.substring(s, min(a, b), max(a, b))
    })
    realm.defineMethod(sp, "substr", length: 2, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let s = try realm.b2This(args, "substr")
        let size = realm.heap.stringLength(s)
        let start = realm.b2Rel(try realm.b2ToInt(args[0]), size)
        let l = args[1].isUndefined ? Double(size) : try realm.b2ToInt(args[1])
        let length = realm.b2Clamp(l, 0, size)
        let end = min(start + length, size)
        if start >= end { return .string(0) }
        return realm.heap.substring(s, start, end)
    })
    realm.defineMethod(sp, "repeat", length: 1, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let s = try realm.b2This(args, "repeat")
        let n = try realm.b2ToInt(args[0])
        if n < 0 || n == Double.infinity { throw realm.throwRangeError("Invalid count value: " + realm.safeToString(args[0])) }
        let len = realm.heap.stringLength(s)
        if n == 0 || len == 0 { return .string(0) }
        if n * Double(len) > Double(realm.limits.maxStringLength) { throw realm.throwRangeError("Invalid string length") }
        var sb = JSStringBuilder()
        var i = 0
        let cnt = Int(n)
        while i < cnt {
            realm.heap.b2Append(&sb, s)
            i += 1
        }
        return realm.heap.newString(sb)
    })
    let pad: (Bool) -> JSNativeFunction = { (atStart: Bool) -> JSNativeFunction in
        return b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let s = try realm.b2This(args, atStart ? "padStart" : "padEnd")
            let maxLen = try realm.toLength(args[0])
            let len = realm.heap.stringLength(s)
            if maxLen <= len { return s }
            var filler: JSValue = .undefined
            if !args[1].isUndefined { filler = try realm.b2Str(args[1]) }
            let fl = filler.isUndefined ? 1 : realm.heap.stringLength(filler)
            if fl == 0 { return s }
            if maxLen > realm.limits.maxStringLength { throw realm.throwRangeError("Invalid string length") }
            let fillLen = maxLen - len
            var pb = JSStringBuilder()
            var done = 0
            while done < fillLen {
                if filler.isUndefined {
                    pb.append(unit: 0x20)
                    done += 1
                } else {
                    let take = min(fl, fillLen - done)
                    realm.heap.b2Append(&pb, filler, 0, take)
                    done += take
                }
            }
            var sb = JSStringBuilder()
            if atStart { sb.append(contentsOf: pb); realm.heap.b2Append(&sb, s) }
            else { realm.heap.b2Append(&sb, s); sb.append(contentsOf: pb) }
            return realm.heap.newString(sb)
        }
    }
    realm.defineMethod(sp, "padEnd", length: 1, pad(false))
    realm.defineMethod(sp, "padStart", length: 1, pad(true))

    func trimmer(_ name: String, _ left: Bool, _ right: Bool) -> JSValue {
        return realm.defineMethod(sp, name, length: 0, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let s = try realm.b2This(args, name)
            let len = realm.heap.stringLength(s)
            var a = 0, b = len
            if left { while a < b && jsIsWhiteSpaceOrLT(realm.heap.charCode(s, a)) { a += 1 } }
            if right { while b > a && jsIsWhiteSpaceOrLT(realm.heap.charCode(s, b - 1)) { b -= 1 } }
            if a == 0 && b == len { return s }
            return realm.heap.substring(s, a, b)
        })
    }
    _ = trimmer("trim", true, true)
    let ts = trimmer("trimStart", true, false)
    let te = trimmer("trimEnd", false, true)
    realm.defineValue(sp, "trimLeft", ts)
    realm.defineValue(sp, "trimRight", te)

    realm.defineMethod(sp, "isWellFormed", length: 0, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let s = try realm.b2This(args, "isWellFormed")
        let u = realm.heap.stringUnits(s)
        var i = 0
        while i < u.count {
            let c = u[i]
            if c >= 0xD800 && c <= 0xDBFF {
                if i + 1 < u.count && u[i + 1] >= 0xDC00 && u[i + 1] <= 0xDFFF { i += 2; continue }
                return .false
            }
            if c >= 0xDC00 && c <= 0xDFFF { return .false }
            i += 1
        }
        return .true
    })
    realm.defineMethod(sp, "toWellFormed", length: 0, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let s = try realm.b2This(args, "toWellFormed")
        var u = realm.heap.stringUnits(s)
        var i = 0
        var changed = false
        while i < u.count {
            let c = u[i]
            if c >= 0xD800 && c <= 0xDBFF {
                if i + 1 < u.count && u[i + 1] >= 0xDC00 && u[i + 1] <= 0xDFFF { i += 2; continue }
                u[i] = 0xFFFD; changed = true
            } else if c >= 0xDC00 && c <= 0xDFFF { u[i] = 0xFFFD; changed = true }
            i += 1
        }
        return changed ? realm.heap.newString(utf16: u) : s
    })
}

private func jsInstallStringSearch(_ realm: JSRealm, _ sp: JSValue) {
    realm.defineMethod(sp, "indexOf", length: 1, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let s = try realm.b2This(args, "indexOf")
        let pat = try realm.b2Str(args[0])
        let pos = try realm.b2ToInt(args[1])
        let len = realm.heap.stringLength(s)
        let start = realm.b2Clamp(pos, 0, len)
        return .number(realm.heap.b2IndexOf(s, realm.heap.stringUnits(pat), start))
    })
    realm.defineMethod(sp, "lastIndexOf", length: 1, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let s = try realm.b2This(args, "lastIndexOf")
        let pat = try realm.b2Str(args[0])
        let numPos = try realm.toNumber(args[1])
        let pos = numPos.isNaN ? Double.infinity : jsToIntegerOrInfinity(numPos)
        let len = realm.heap.stringLength(s)
        let start = realm.b2Clamp(pos, 0, len)
        return .number(realm.heap.b2LastIndexOf(s, realm.heap.stringUnits(pat), start))
    })
    realm.defineMethod(sp, "includes", length: 1, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let s = try realm.b2This(args, "includes")
        if try realm.b2IsRegExp(args[0]) { throw realm.throwTypeError("First argument to String.prototype.includes must not be a regular expression") }
        let pat = try realm.b2Str(args[0])
        let pos = try realm.b2ToInt(args[1])
        let start = realm.b2Clamp(pos, 0, realm.heap.stringLength(s))
        return .bool(realm.heap.b2IndexOf(s, realm.heap.stringUnits(pat), start) >= 0)
    })
    realm.defineMethod(sp, "startsWith", length: 1, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let s = try realm.b2This(args, "startsWith")
        if try realm.b2IsRegExp(args[0]) { throw realm.throwTypeError("First argument to String.prototype.startsWith must not be a regular expression") }
        let pat = try realm.b2Str(args[0])
        let pos = try realm.b2ToInt(args[1])
        let start = realm.b2Clamp(pos, 0, realm.heap.stringLength(s))
        return .bool(realm.heap.b2HasAt(s, realm.heap.stringUnits(pat), start))
    })
    realm.defineMethod(sp, "endsWith", length: 1, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let s = try realm.b2This(args, "endsWith")
        if try realm.b2IsRegExp(args[0]) { throw realm.throwTypeError("First argument to String.prototype.endsWith must not be a regular expression") }
        let pat = try realm.b2Str(args[0])
        let len = realm.heap.stringLength(s)
        let end = args[1].isUndefined ? len : realm.b2Clamp(try realm.b2ToInt(args[1]), 0, len)
        let pu = realm.heap.stringUnits(pat)
        return .bool(realm.heap.b2HasAt(s, pu, end - pu.count))
    })
    realm.defineMethod(sp, "localeCompare", length: 1, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let s = try realm.b2This(args, "localeCompare")
        let that = try realm.b2Str(args[0])
        let a = jsStringNormalize(realm.heap.stringUnits(s), .nfc)
        let b = jsStringNormalize(realm.heap.stringUnits(that), .nfc)
        let n = min(a.count, b.count)
        var i = 0
        while i < n {
            if a[i] != b[i] { return .int32(a[i] < b[i] ? -1 : 1) }
            i += 1
        }
        return .int32(a.count == b.count ? 0 : (a.count < b.count ? -1 : 1))
    })
}

private func jsInstallStringTransform(_ realm: JSRealm, _ sp: JSValue) {
    func caseMethod(_ name: String, _ upper: Bool) {
        realm.defineMethod(sp, name, length: 0, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let s = try realm.b2This(args, name)
            let u = realm.heap.stringUnits(s)
            let r = upper ? jsStringToUpper(u) : jsStringToLower(u)
            if r.count > realm.limits.maxStringLength { throw realm.throwRangeError("Invalid string length") }
            if r == u { return s }
            return realm.heap.newString(utf16: r)
        })
    }
    caseMethod("toLowerCase", false)
    caseMethod("toUpperCase", true)
    caseMethod("toLocaleLowerCase", false)
    caseMethod("toLocaleUpperCase", true)
    realm.defineMethod(sp, "normalize", length: 0, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let s = try realm.b2This(args, "normalize")
        var form = JSNormForm.nfc
        if !args[0].isUndefined {
            let f = realm.heap.swiftString(try realm.b2Str(args[0]))
            switch f {
            case "NFC": form = .nfc
            case "NFD": form = .nfd
            case "NFKC": form = .nfkc
            case "NFKD": form = .nfkd
            default: throw realm.throwRangeError("The normalization form should be one of NFC, NFD, NFKC, NFKD.")
            }
        }
        let u = realm.heap.stringUnits(s)
        let r = jsStringNormalize(u, form)
        if r.count > realm.limits.maxStringLength { throw realm.throwRangeError("Invalid string length") }
        if r == u { return s }
        return realm.heap.newString(utf16: r)
    })
}

private func jsInstallStringRegExpMethods(_ realm: JSRealm, _ sp: JSValue) {
    let w = realm.heap.symbolsWellKnown
    let matchSym = JSPropertyKey.symbol(w.match.handle)
    let matchAllSym = JSPropertyKey.symbol(w.matchAll.handle)
    let replaceSym = JSPropertyKey.symbol(w.replace.handle)
    let searchSym = JSPropertyKey.symbol(w.search.handle)
    let splitSym = JSPropertyKey.symbol(w.split.handle)

    func regexpDispatch(_ name: String, _ sym: JSPropertyKey) {
        realm.defineMethod(sp, name, length: 1, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let o = args.this
            if o.isNullish { throw realm.throwTypeError("String.prototype." + name + " called on null or undefined") }
            let rx = args[0]
            if rx.isObject {
                if name == "matchAll", try realm.b2IsRegExp(rx) {
                    let flags = try realm.getV(rx, realm.b2.kFlags)
                    if flags.isNullish { throw realm.throwTypeError("flags is null or undefined") }
                    let fs = try realm.b2Str(flags)
                    if realm.heap.b2IndexOf(fs, [0x67], 0) < 0 {
                        throw realm.throwTypeError("String.prototype.matchAll called with a non-global RegExp argument")
                    }
                }
                let m = try realm.b2GetMethod(rx, sym)
                if !m.isUndefined { return try realm.call(m, this: rx, args: [o]) }
            }
            let s = try realm.b2Str(o)
            let flagsArg: JSValue = name == "matchAll" ? realm.string("g") : .undefined
            _ = realm.heap.root(flagsArg)
            let re = try realm.b2RegExpCreateValue(rx, flagsArg)
            _ = realm.heap.root(re)
            let f = try realm.b2GetMethod(re, sym)
            return try realm.call(f, this: re, args: [s])
        })
    }
    regexpDispatch("match", matchSym)
    regexpDispatch("matchAll", matchAllSym)
    regexpDispatch("search", searchSym)

    realm.defineMethod(sp, "split", length: 2, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let o = args.this
        if o.isNullish { throw realm.throwTypeError("String.prototype.split called on null or undefined") }
        let sepV = args[0], limitV = args[1]
        if sepV.isObject {
            let splitter = try realm.b2GetMethod(sepV, splitSym)
            if !splitter.isUndefined { return try realm.call(splitter, this: sepV, args: [o, limitV]) }
        }
        let s = try realm.b2Str(o)
        let lim: UInt32 = limitV.isUndefined ? UInt32.max : jsToUint32(try realm.toNumber(limitV))
        let r = try realm.b2Str(sepV)
        let a = realm.b2NewArray()
        _ = realm.heap.root(a)
        if lim == 0 { return a }
        if sepV.isUndefined { realm.b2ArrayPush(a, s); return a }
        let sepLen = realm.heap.stringLength(r)
        let len = realm.heap.stringLength(s)
        if sepLen == 0 {
            var i = 0
            while i < len && UInt32(i) < lim {
                realm.b2ArrayPush(a, realm.heap.singleUnitString(realm.heap.charCode(s, i), protecting: a))
                i += 1
                if realm.heap.termination != nil { throw JSThrow() }
            }
            return a
        }
        if len == 0 { realm.b2ArrayPush(a, s); return a }
        let pat = realm.heap.stringUnits(r)
        var i = 0
        var j = realm.heap.b2IndexOf(s, pat, 0)
        while j >= 0 {
            realm.b2ArrayPush(a, realm.heap.substring(s, i, j))
            if realm.heap.arrayLength(a) >= lim { return a }
            if realm.heap.termination != nil { throw JSThrow() }
            i = j + sepLen
            j = realm.heap.b2IndexOf(s, pat, i)
        }
        realm.b2ArrayPush(a, realm.heap.substring(s, i, len))
        return a
    })

    let replaceImpl: (Bool) -> JSNativeFunction = { (all: Bool) -> JSNativeFunction in
        return b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let o = args.this
            let name = all ? "replaceAll" : "replace"
            if o.isNullish { throw realm.throwTypeError("String.prototype." + name + " called on null or undefined") }
            let searchV = args[0]
            var replaceV = args[1]
            if searchV.isObject {
                if all, try realm.b2IsRegExp(searchV) {
                    let flags = try realm.getV(searchV, realm.b2.kFlags)
                    if flags.isNullish { throw realm.throwTypeError("flags is null or undefined") }
                    let fs = try realm.b2Str(flags)
                    if realm.heap.b2IndexOf(fs, [0x67], 0) < 0 {
                        throw realm.throwTypeError("replaceAll must be called with a global RegExp")
                    }
                }
                let replacer = try realm.b2GetMethod(searchV, replaceSym)
                if !replacer.isUndefined { return try realm.call(replacer, this: searchV, args: [o, replaceV]) }
            }
            let s = try realm.b2Str(o)
            let search = try realm.b2Str(searchV)
            let functional = realm.heap.isCallable(replaceV)
            if !functional { replaceV = try realm.b2Str(replaceV) }
            let pat = realm.heap.stringUnits(search)
            let searchLen = pat.count
            let len = realm.heap.stringLength(s)
            var positions: [Int] = []
            var pos = realm.heap.b2IndexOf(s, pat, 0)
            if pos < 0 { return s }
            if !all { positions.append(pos) } else {
                let adv = max(1, searchLen)
                while pos >= 0 {
                    positions.append(pos)
                    pos = realm.heap.b2IndexOf(s, pat, pos + adv)
                }
            }
            var sb = JSStringBuilder()
            var last = 0
            for p in positions {
                realm.heap.b2Append(&sb, s, last, p)
                if functional {
                    let rv = try realm.call(replaceV, this: .undefined, args: [search, .number(p), s])
                    let rs = try realm.toStringValue(rv)
                    realm.heap.b2Append(&sb, rs)
                } else {
                    let rs = try realm.b2GetSubstitution(search, s, p, [], .undefined, replaceV)
                    realm.heap.b2Append(&sb, rs)
                }
                try realm.b2CheckLength(sb)
                last = p + searchLen
            }
            if last < len { realm.heap.b2Append(&sb, s, last) }
            return try realm.b2Finish(sb)
        }
    }
    realm.defineMethod(sp, "replace", length: 2, replaceImpl(false))
    realm.defineMethod(sp, "replaceAll", length: 2, replaceImpl(true))
}

private func jsInstallStringHTML(_ realm: JSRealm, _ sp: JSValue) {
    func html(_ name: String, _ tag: String, _ attr: String) {
        realm.defineMethod(sp, name, length: attr.isEmpty ? 0 : 1, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let s = try realm.b2This(args, name)
            var sb = JSStringBuilder()
            sb.append("<" + tag)
            if !attr.isEmpty {
                let v = try realm.b2Str(args[0])
                sb.append(" " + attr + "=\"")
                let u = realm.heap.stringUnits(v)
                for c in u {
                    if c == 0x22 { sb.append("&quot;") } else { sb.append(unit: c) }
                }
                sb.append("\"")
            }
            sb.append(">")
            realm.heap.b2Append(&sb, s)
            sb.append("</" + tag + ">")
            return try realm.b2Finish(sb)
        })
    }
    html("anchor", "a", "name")
    html("big", "big", "")
    html("blink", "blink", "")
    html("bold", "b", "")
    html("fixed", "tt", "")
    html("fontcolor", "font", "color")
    html("fontsize", "font", "size")
    html("italics", "i", "")
    html("link", "a", "href")
    html("small", "small", "")
    html("strike", "strike", "")
    html("sub", "sub", "")
    html("sup", "sup", "")
}
