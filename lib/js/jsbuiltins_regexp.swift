// The RegExp object (ROADMAP Phase 9C): constructor, compile cache, exec
// with lastIndex / groups / indices, test, toString, the flag getters,
// Symbol.match / matchAll / replace / search / split (spec algorithms, with
// species construction for split), and the RegExp String Iterator. The
// engine is jsregexp*.swift; this file is the JS-visible layer.
//
// Objects: kind .regexp, internalInt = index into JSBuiltins2State's program
// table (freed by the GC finalizer hook in JSRealm.finalize), slots =
// [source string, flags string] exactly as given, plus the own `lastIndex`
// property. `realm.regExpCreate` (regex literals) is set here.
//
// Engine outcomes: .stepLimit becomes the uncatchable termination
// JSTerminationReason.regexSteps (ReDoS), .stackLimit a RangeError.
//
// Fast paths: when the receiver is a real RegExp whose `exec` is the
// built-in one (and, for replace/split, whose `flags` agree with its program),
// Symbol.replace / match / split run the matcher directly instead of building
// a result array per match. They are observably identical to the spec loops
// (same lastIndex reads and writes, matches collected before callbacks run).
//
// Not implemented: the legacy static properties (RegExp.$1, lastMatch, ...).

/// State of the String / RegExp / Symbol / Date built-ins, one per realm.
final class JSBuiltins2State {
    var regExpPrograms: [JSRegExpProgram?] = []
    var regExpFree: [Int] = []
    let regExpCache = JSRegExpCache(capacity: 128)
    // Pinned property keys.
    var kFlags: JSPropertyKey = .index(0)
    var kExec: JSPropertyKey = .index(0)
    var kSource: JSPropertyKey = .index(0)
    var kGroups: JSPropertyKey = .index(0)
    var kIndices: JSPropertyKey = .index(0)
    var kToISOString: JSPropertyKey = .index(0)
    /// hasIndices, global, ignoreCase, multiline, dotAll, unicode, unicodeSets, sticky.
    var flagKeys: [JSPropertyKey] = []

    func addProgram(_ p: JSRegExpProgram) -> Int {
        if let f = regExpFree.popLast() { regExpPrograms[f] = p; return f }
        regExpPrograms.append(p)
        return regExpPrograms.count - 1
    }

    func releaseRegExp(_ id: Int) {
        guard id >= 0 && id < regExpPrograms.count else { return }
        regExpPrograms[id] = nil
        regExpFree.append(id)
    }
}

private func b2PinKey(_ heap: JSHeap, _ s: String) -> JSPropertyKey {
    .atom(heap.pinAtom(heap.newString(s)).handle)
}

extension JSRealm {
    func regExpProgram(_ o: JSValue) -> JSRegExpProgram? {
        guard heap.kind(o) == .regexp else { return nil }
        let id = Int(heap.internalInt(o))
        guard id >= 0 && id < b2.regExpPrograms.count else { return nil }
        return b2.regExpPrograms[id]
    }

    /// RegExpAlloc.
    func regExpAlloc(_ newTarget: JSValue) throws(JSThrow) -> JSValue {
        let proto = try prototype(forNewTarget: newTarget, default: .regExpPrototype)
        let rd = heap.rootDepth
        defer { heap.popRoots(to: rd) }
        _ = heap.root(proto)
        let o = heap.newObject(proto: proto, kind: .regexp, flags: [.extensible, .hasFinalizer])
        heap.setInternalInt(o, -1)
        _ = heap.setSlots(o, [.string(0), .string(0)])
        _ = heap.defineOwnProperty(o, heap.names.lastIndex, .data(.int32(0), [.writable]))
        return o
    }

    /// RegExpInitialize (also used by Annex B compile()).
    func regExpInitialize(_ o: JSValue, _ pattern: JSValue, _ flags: JSValue) throws(JSThrow) -> JSValue {
        let rd = heap.rootDepth
        defer { heap.popRoots(to: rd) }
        _ = heap.root(o)
        let p: JSValue = pattern.isUndefined ? .string(0) : try b2Str(pattern)
        let f: JSValue = flags.isUndefined ? .string(0) : try b2Str(flags)
        let pu = heap.stringUnits(p), fu = heap.stringUnits(f)
        guard let fl = JSRegExpFlags(units: fu) else {
            throw throwSyntaxError("Invalid flags supplied to RegExp constructor '" + heap.swiftString(f) + "'")
        }
        let prog: JSRegExpProgram
        do throws(JSRegExpError) {
            prog = try b2.regExpCache.program(pattern: pu, flags: fl)
        } catch {
            throw throwSyntaxError("Invalid regular expression: /" + heap.swiftString(p) + "/" + heap.swiftString(f)
                                   + ": " + error.message)
        }
        try setV(o, heap.names.lastIndex, .int32(0), strict: true)
        let old = Int(heap.internalInt(o))
        if old >= 0 { b2.releaseRegExp(old) }
        heap.setInternalInt(o, Int64(b2.addProgram(prog)))
        heap.setSlot(o, 0, p)
        heap.setSlot(o, 1, f)
        return o
    }

    func b2Advance(_ s: JSValue, _ index: Int, _ unicode: Bool) -> Int {
        if !unicode { return index + 1 }
        if index + 1 >= heap.stringLength(s) { return index + 1 }
        return index + (heap.codePoint(s, index) > 0xFFFF ? 2 : 1)
    }

    /// RegExpBuiltinExec up to the engine match (lastIndex handling included).
    func regExpBuiltinMatch(_ r: JSValue, _ s: JSValue, _ prog: JSRegExpProgram) throws(JSThrow) -> JSRegExpMatch? {
        let li = try getV(r, heap.names.lastIndex)
        var lastIndex = try toLength(li)
        let global = prog.flags.global, sticky = prog.flags.sticky
        if !global && !sticky { lastIndex = 0 }
        if lastIndex > heap.stringLength(s) {
            if global || sticky { try setV(r, heap.names.lastIndex, .int32(0), strict: true) }
            return nil
        }
        switch heap.regExpExec(prog, s, from: lastIndex) {
        case .noMatch:
            if global || sticky { try setV(r, heap.names.lastIndex, .int32(0), strict: true) }
            return nil
        case .stepLimit:
            heap.requestTermination(.regexSteps)
            throw JSThrow()
        case .stackLimit:
            throw throwRangeError("Maximum call stack size exceeded")
        case .match(let m):
            if global || sticky { try setV(r, heap.names.lastIndex, .number(m.end(0)), strict: true) }
            return m
        }
    }

    /// RegExpBuiltinExec: the result array or null.
    func regExpBuiltinExec(_ r: JSValue, _ s: JSValue) throws(JSThrow) -> JSValue {
        guard let prog = regExpProgram(r) else { throw throwTypeError("RegExp.prototype.exec called on an incompatible receiver") }
        guard let m = try regExpBuiltinMatch(r, s, prog) else { return .null }
        return try b2RegExpResultArray(prog, s, m)
    }

    /// RegExpExec(R, S).
    func regExpExecAbstract(_ r: JSValue, _ s: JSValue) throws(JSThrow) -> JSValue {
        let exec = try getV(r, b2.kExec)
        if exec.isObject && exec == intrinsic(.regExpExecFn) && heap.kind(r) == .regexp {
            return try regExpBuiltinExec(r, s)
        }
        if heap.isCallable(exec) {
            let res = try call(exec, this: r, args: [s])
            guard res.isObject || res.isNull else { throw throwTypeError("object null or an Object expected from exec") }
            return res
        }
        guard heap.kind(r) == .regexp else { throw throwTypeError("RegExp.prototype.exec called on an incompatible receiver") }
        return try regExpBuiltinExec(r, s)
    }

    /// The exec result array (index, input, groups, indices).
    func b2RegExpResultArray(_ prog: JSRegExpProgram, _ s: JSValue, _ m: JSRegExpMatch) throws(JSThrow) -> JSValue {
        let rd = heap.rootDepth
        defer { heap.popRoots(to: rd) }
        let a = b2NewArray()
        _ = heap.root(a)
        _ = heap.createDataProperty(a, heap.names.index, .number(m.start(0)))
        _ = heap.createDataProperty(a, heap.names.input, s)
        let n = prog.captureCount
        var i = 0
        while i <= n {
            var v: JSValue = .undefined
            if m.matched(i) { v = heap.substring(s, m.start(i), m.end(i)) }
            _ = heap.createDataProperty(a, .index(UInt32(i)), v)
            i += 1
        }
        if heap.termination != nil { throw JSThrow() }
        var groups: JSValue = .undefined
        if !prog.namedGroups.isEmpty {
            groups = heap.newObject(proto: .null)
            _ = heap.root(groups)
            for g in prog.namedGroups {
                let kv = heap.newString(utf16: g.name)
                _ = heap.root(kv)
                if let key = heap.propertyKey(kv) {
                    let v = heap.getOwnProperty(a, .index(UInt32(g.index)))?.value ?? .undefined
                    _ = heap.createDataProperty(groups, key, v)
                }
            }
        }
        _ = heap.createDataProperty(a, b2.kGroups, groups)
        if prog.flags.hasIndices {
            let ia = b2NewArray()
            _ = heap.root(ia)
            i = 0
            while i <= n {
                var v: JSValue = .undefined
                if m.matched(i) {
                    v = heap.newArray(proto: arrayPrototype, elements: [.number(m.start(i)), .number(m.end(i))])
                }
                _ = heap.createDataProperty(ia, .index(UInt32(i)), v)
                i += 1
            }
            var ig: JSValue = .undefined
            if !prog.namedGroups.isEmpty {
                ig = heap.newObject(proto: .null)
                _ = heap.root(ig)
                for g in prog.namedGroups {
                    let kv = heap.newString(utf16: g.name)
                    _ = heap.root(kv)
                    if let key = heap.propertyKey(kv) {
                        let v = heap.getOwnProperty(ia, .index(UInt32(g.index)))?.value ?? .undefined
                        _ = heap.createDataProperty(ig, key, v)
                    }
                }
            }
            _ = heap.createDataProperty(ia, b2.kGroups, ig)
            _ = heap.createDataProperty(a, b2.kIndices, ia)
        }
        return a
    }

    /// Every successive match for the global/sticky loops of match, replace
    /// and split, with the same lastIndex effects as the spec loop: the
    /// caller set lastIndex to 0 first; it is 0 again at the end.
    func b2CollectMatches(_ r: JSValue, _ s: JSValue, _ prog: JSRegExpProgram, _ unicode: Bool) throws(JSThrow) -> [JSRegExpMatch] {
        var out: [JSRegExpMatch] = []
        let len = heap.stringLength(s)
        var pos = 0
        while pos <= len {
            switch heap.regExpExec(prog, s, from: pos) {
            case .noMatch:
                pos = len + 1
            case .stepLimit:
                heap.requestTermination(.regexSteps)
                throw JSThrow()
            case .stackLimit:
                throw throwRangeError("Maximum call stack size exceeded")
            case .match(let m):
                out.append(m)
                pos = m.end(0) == m.start(0) || m.end(0) <= pos ? b2Advance(s, max(m.end(0), pos), unicode) : m.end(0)
            }
            if heap.termination != nil { throw JSThrow() }
        }
        try setV(r, heap.names.lastIndex, .int32(0), strict: true)
        return out
    }

    /// The receiver's program when the fast paths apply (see the file header).
    func b2FastProgram(_ rx: JSValue, flags: JSValue?) -> JSRegExpProgram? {
        guard heap.kind(rx) == .regexp, let prog = regExpProgram(rx) else { return nil }
        guard case .value(let e) = heap.getProperty(rx, b2.kExec), e.isObject, e == intrinsic(.regExpExecFn) else { return nil }
        if let f = flags {
            let canon = Array(prog.flags.string.utf16)
            if heap.stringUnits(f) != canon { return nil }
        }
        return prog
    }

    func b2ThisRegExp(_ args: JSArgs, _ name: String) throws(JSThrow) -> JSValue {
        guard args.this.isObject else {
            throw throwTypeError("RegExp.prototype." + name + " called on incompatible receiver " + describeForError(args.this))
        }
        return args.this
    }

    /// Source with `/` and line terminators escaped (EscapeRegExpPattern).
    func b2EscapedSource(_ src: JSValue) -> JSValue {
        let u = heap.stringUnits(src)
        if u.isEmpty { return heap.newString("(?:)") }
        var out: [UInt16] = []
        out.reserveCapacity(u.count + 4)
        var inClass = false
        var i = 0
        while i < u.count {
            let c = u[i]
            if c == 0x5C && i + 1 < u.count {
                let d = u[i + 1]
                out.append(0x5C)
                switch d {
                case 0x0A: out.append(0x6E)
                case 0x0D: out.append(0x72)
                case 0x2028: out.append(contentsOf: Array("u2028".utf16))
                case 0x2029: out.append(contentsOf: Array("u2029".utf16))
                default: out.append(d)
                }
                i += 2
                continue
            }
            if c == 0x5B { inClass = true } else if c == 0x5D { inClass = false }
            switch c {
            case 0x2F where !inClass: out.append(0x5C); out.append(0x2F)
            case 0x0A: out.append(contentsOf: Array("\\n".utf16))
            case 0x0D: out.append(contentsOf: Array("\\r".utf16))
            case 0x2028: out.append(contentsOf: Array("\\u2028".utf16))
            case 0x2029: out.append(contentsOf: Array("\\u2029".utf16))
            default: out.append(c)
            }
            i += 1
        }
        return heap.newString(utf16: out)
    }
}

// MARK: Installation

func jsInstallRegExp(_ realm: JSRealm) {
    let heap = realm.heap
    let st = realm.b2
    st.kFlags = b2PinKey(heap, "flags")
    st.kExec = b2PinKey(heap, "exec")
    st.kSource = b2PinKey(heap, "source")
    st.kGroups = b2PinKey(heap, "groups")
    st.kIndices = b2PinKey(heap, "indices")
    st.kToISOString = b2PinKey(heap, "toISOString")
    for n in ["hasIndices", "global", "ignoreCase", "multiline", "dotAll", "unicode", "unicodeSets", "sticky"] {
        st.flagKeys.append(b2PinKey(heap, n))
    }
    let op = realm.objectPrototype
    let rp = heap.newObject(proto: op)
    realm.setIntrinsic(.regExpPrototype, rp)
    let ctor = realm.defineConstructor("RegExp", length: 2, prototype: rp, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let pattern = args[0], flags = args[1]
        let patternIsRegExp = try realm.b2IsRegExp(pattern)
        var newTarget = args.newTarget
        if !args.isConstruct {
            newTarget = args.callee
            if patternIsRegExp && flags.isUndefined {
                let pc = try realm.getV(pattern, realm.heap.names.constructor)
                if pc == newTarget { return pattern }
            }
        }
        var p = pattern, f = flags
        if pattern.isObject && realm.heap.kind(pattern) == .regexp {
            p = realm.heap.slot(pattern, 0)
            if flags.isUndefined { f = realm.heap.slot(pattern, 1) }
        } else if patternIsRegExp {
            p = try realm.getV(pattern, realm.b2.kSource)
            if flags.isUndefined { f = try realm.getV(pattern, realm.b2.kFlags) }
        }
        _ = realm.heap.root(p)
        _ = realm.heap.root(f)
        let o = try realm.regExpAlloc(newTarget)
        _ = realm.heap.root(o)
        return try realm.regExpInitialize(o, p, f)
    })
    realm.setIntrinsic(.regExpConstructor, ctor)
    realm.defineGetter(ctor, "[Symbol.species]", key: .symbol(heap.symbolsWellKnown.species.handle)) {
        (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in args.this
    }
    realm.regExpCreate = { (realm: JSRealm, pattern: JSValue, flags: JSValue) throws(JSThrow) -> JSValue in
        let rd = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: rd) }
        return try realm.b2RegExpCreateValue(pattern, flags)
    }
    jsInstallRegExpBasics(realm, rp)
    jsInstallRegExpSymbols(realm, rp)
}

private func jsInstallRegExpBasics(_ realm: JSRealm, _ rp: JSValue) {
    let heap = realm.heap
    let exec = realm.defineMethod(rp, "exec", length: 1, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let r = args.this
        guard r.isObject, realm.heap.kind(r) == .regexp else {
            throw realm.throwTypeError("RegExp.prototype.exec called on incompatible receiver " + realm.describeForError(r))
        }
        let s = try realm.b2Str(args[0])
        return try realm.regExpBuiltinExec(r, s)
    })
    realm.setIntrinsic(.regExpExecFn, exec)
    realm.defineMethod(rp, "test", length: 1, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let r = try realm.b2ThisRegExp(args, "test")
        let s = try realm.b2Str(args[0])
        if let prog = realm.b2FastProgram(r, flags: nil) {
            return .bool(try realm.regExpBuiltinMatch(r, s, prog) != nil)
        }
        return .bool(!(try realm.regExpExecAbstract(r, s)).isNull)
    })
    realm.defineMethod(rp, "toString", length: 0, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let r = try realm.b2ThisRegExp(args, "toString")
        let src = try realm.b2Str(try realm.getV(r, realm.b2.kSource))
        let fl = try realm.b2Str(try realm.getV(r, realm.b2.kFlags))
        var sb = JSStringBuilder()
        sb.append("/")
        realm.heap.b2Append(&sb, src)
        sb.append("/")
        realm.heap.b2Append(&sb, fl)
        return try realm.b2Finish(sb)
    })
    realm.defineMethod(rp, "compile", length: 2, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let o = args.this
        guard o.isObject, realm.heap.kind(o) == .regexp else {
            throw realm.throwTypeError("RegExp.prototype.compile called on incompatible receiver " + realm.describeForError(o))
        }
        var p = args[0], f = args[1]
        if p.isObject && realm.heap.kind(p) == .regexp {
            if !f.isUndefined { throw realm.throwTypeError("flags must be undefined when the pattern is a RegExp") }
            f = realm.heap.slot(p, 1)
            p = realm.heap.slot(p, 0)
        }
        return try realm.regExpInitialize(o, p, f)
    })
    let bits: [(String, UInt8)] = [("hasIndices", JSRegExpFlags.hasIndices), ("global", JSRegExpFlags.global),
        ("ignoreCase", JSRegExpFlags.ignoreCase), ("multiline", JSRegExpFlags.multiline),
        ("dotAll", JSRegExpFlags.dotAll), ("unicode", JSRegExpFlags.unicode),
        ("unicodeSets", JSRegExpFlags.unicodeSets), ("sticky", JSRegExpFlags.sticky)]
    for (name, bit) in bits {
        realm.defineGetter(rp, name) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let t = args.this
            guard t.isObject else { throw realm.throwTypeError("RegExp.prototype." + name + " getter called on non-object " + realm.describeForError(t)) }
            if realm.heap.kind(t) != .regexp {
                if t == realm.intrinsic(.regExpPrototype) { return .undefined }
                throw realm.throwTypeError("RegExp.prototype." + name + " getter called on non-RegExp object")
            }
            guard let prog = realm.regExpProgram(t) else { return .false }
            return .bool(prog.flags.has(bit))
        }
    }
    realm.defineGetter(rp, "flags") { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let t = args.this
        guard t.isObject else { throw realm.throwTypeError("RegExp.prototype.flags getter called on non-object " + realm.describeForError(t)) }
        let letters: [UInt8] = [0x64, 0x67, 0x69, 0x6D, 0x73, 0x75, 0x76, 0x79]
        var out: [UInt8] = []
        for k in 0..<8 {
            let v = try realm.getV(t, realm.b2.flagKeys[k])
            if realm.heap.toBoolean(v) { out.append(letters[k]) }
        }
        return realm.heap.newString(latin1: out)
    }
    realm.defineGetter(rp, "source") { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let t = args.this
        guard t.isObject else { throw realm.throwTypeError("RegExp.prototype.source getter called on non-object " + realm.describeForError(t)) }
        if realm.heap.kind(t) != .regexp {
            if t == realm.intrinsic(.regExpPrototype) { return realm.string("(?:)") }
            throw realm.throwTypeError("RegExp.prototype.source getter called on non-RegExp object")
        }
        return realm.b2EscapedSource(realm.heap.slot(t, 0))
    }
    _ = heap
}

private func jsInstallRegExpSymbols(_ realm: JSRealm, _ rp: JSValue) {
    let w = realm.heap.symbolsWellKnown
    let kLast = realm.heap.names.lastIndex

    // @@match
    realm.defineMethod(rp, "[Symbol.match]", length: 1, key: .symbol(w.match.handle), b2Rooted {
        (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let rx = try realm.b2ThisRegExp(args, "[Symbol.match]")
        let s = try realm.b2Str(args[0])
        let flags = try realm.b2Str(try realm.getV(rx, realm.b2.kFlags))
        if realm.heap.b2IndexOf(flags, [0x67], 0) < 0 { return try realm.regExpExecAbstract(rx, s) }
        let fu = realm.heap.b2IndexOf(flags, [0x75], 0) >= 0 || realm.heap.b2IndexOf(flags, [0x76], 0) >= 0
        try realm.setV(rx, kLast, .int32(0), strict: true)
        let a = realm.b2NewArray()
        _ = realm.heap.root(a)
        if let prog = realm.b2FastProgram(rx, flags: flags) {
            let ms = try realm.b2CollectMatches(rx, s, prog, fu)
            if ms.isEmpty { return .null }
            for m in ms {
                realm.b2ArrayPush(a, realm.heap.substring(s, m.start(0), m.end(0)))
                if realm.heap.termination != nil { throw JSThrow() }
            }
            return a
        }
        var n = 0
        while true {
            let rd = realm.heap.rootDepth
            let result = try realm.regExpExecAbstract(rx, s)
            if result.isNull { return n == 0 ? .null : a }
            _ = realm.heap.root(result)
            let ms = try realm.b2Str(try realm.getV(result, .index(0)))
            realm.b2ArrayPush(a, ms)
            if realm.heap.stringLength(ms) == 0 {
                let thisIndex = try realm.toLength(try realm.getV(rx, kLast))
                try realm.setV(rx, kLast, .number(realm.b2Advance(s, thisIndex, fu)), strict: true)
            }
            n += 1
            realm.heap.popRoots(to: rd)
            if realm.heap.termination != nil { throw JSThrow() }
        }
    })

    // @@matchAll
    realm.defineMethod(rp, "[Symbol.matchAll]", length: 1, key: .symbol(w.matchAll.handle), b2Rooted {
        (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let r = try realm.b2ThisRegExp(args, "[Symbol.matchAll]")
        let s = try realm.b2Str(args[0])
        let c = try realm.b2SpeciesConstructor(r, realm.intrinsic(.regExpConstructor))
        let flags = try realm.b2Str(try realm.getV(r, realm.b2.kFlags))
        let matcher = try realm.construct(c, args: [r, flags])
        _ = realm.heap.root(matcher)
        let li = try realm.toLength(try realm.getV(r, kLast))
        try realm.setV(matcher, kLast, .number(li), strict: true)
        var bits: Int64 = 0
        if realm.heap.b2IndexOf(flags, [0x67], 0) >= 0 { bits |= 1 }
        if realm.heap.b2IndexOf(flags, [0x75], 0) >= 0 || realm.heap.b2IndexOf(flags, [0x76], 0) >= 0 { bits |= 2 }
        let it = realm.heap.newObject(proto: realm.intrinsic(.regExpStringIteratorPrototype), kind: .ordinary, flags: [.extensible, .user2])
        _ = realm.heap.setSlots(it, [matcher, s])
        realm.heap.setInternalInt(it, bits)
        return it
    })

    // The RegExp String Iterator.
    let itp = realm.heap.newObject(proto: realm.intrinsic(.iteratorPrototype))
    realm.setIntrinsic(.regExpStringIteratorPrototype, itp)
    realm.defineMethod(itp, "next", length: 0, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let it = args.this
        guard it.isObject, realm.heap.kind(it) == .ordinary, realm.heap.flags(it).contains(.user2),
              realm.heap.slotCount(it) == 2 else {
            throw realm.throwTypeError("next method called on an incompatible receiver")
        }
        let bits = realm.heap.internalInt(it)
        if bits & 4 != 0 { return try realm.iterResult(.undefined, done: true) }
        let r = realm.heap.slot(it, 0), s = realm.heap.slot(it, 1)
        let match = try realm.regExpExecAbstract(r, s)
        if match.isNull {
            realm.heap.setInternalInt(it, bits | 4)
            return try realm.iterResult(.undefined, done: true)
        }
        _ = realm.heap.root(match)
        if bits & 1 == 0 {
            realm.heap.setInternalInt(it, bits | 4)
            return try realm.iterResult(match, done: false)
        }
        let ms = try realm.b2Str(try realm.getV(match, .index(0)))
        if realm.heap.stringLength(ms) == 0 {
            let thisIndex = try realm.toLength(try realm.getV(r, kLast))
            try realm.setV(r, kLast, .number(realm.b2Advance(s, thisIndex, bits & 2 != 0)), strict: true)
        }
        return try realm.iterResult(match, done: false)
    })
    _ = realm.heap.defineOwnProperty(itp, .symbol(w.toStringTag.handle),
                                     .data(realm.string("RegExp String Iterator"), [.configurable]))

    // @@search
    realm.defineMethod(rp, "[Symbol.search]", length: 1, key: .symbol(w.search.handle), b2Rooted {
        (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let rx = try realm.b2ThisRegExp(args, "[Symbol.search]")
        let s = try realm.b2Str(args[0])
        let previous = try realm.getV(rx, kLast)
        _ = realm.heap.root(previous)
        if !realm.heap.sameValue(previous, .int32(0)) { try realm.setV(rx, kLast, .int32(0), strict: true) }
        let result = try realm.regExpExecAbstract(rx, s)
        _ = realm.heap.root(result)
        let current = try realm.getV(rx, kLast)
        if !realm.heap.sameValue(current, previous) { try realm.setV(rx, kLast, previous, strict: true) }
        if result.isNull { return .int32(-1) }
        return try realm.getV(result, realm.heap.names.index)
    })

    // @@replace
    realm.defineMethod(rp, "[Symbol.replace]", length: 2, key: .symbol(w.replace.handle), b2Rooted {
        (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let rx = try realm.b2ThisRegExp(args, "[Symbol.replace]")
        let s = try realm.b2Str(args[0])
        let len = realm.heap.stringLength(s)
        var replaceValue = args[1]
        let functional = realm.heap.isCallable(replaceValue)
        if !functional { replaceValue = try realm.b2Str(replaceValue) }
        let flags = try realm.b2Str(try realm.getV(rx, realm.b2.kFlags))
        let global = realm.heap.b2IndexOf(flags, [0x67], 0) >= 0
        var fu = false
        if global {
            fu = realm.heap.b2IndexOf(flags, [0x75], 0) >= 0 || realm.heap.b2IndexOf(flags, [0x76], 0) >= 0
            try realm.setV(rx, kLast, .int32(0), strict: true)
        }
        var sb = JSStringBuilder()
        var next = 0
        if let prog = realm.b2FastProgram(rx, flags: flags) {
            var ms: [JSRegExpMatch] = []
            if global { ms = try realm.b2CollectMatches(rx, s, prog, fu) }
            else if let m = try realm.regExpBuiltinMatch(rx, s, prog) { ms = [m] }
            for m in ms {
                let rd = realm.heap.rootDepth
                let matched = realm.heap.substring(s, m.start(0), m.end(0))
                _ = realm.heap.root(matched)
                var caps: [JSValue] = []
                var i = 1
                while i <= prog.captureCount {
                    var v: JSValue = .undefined
                    if m.matched(i) { v = realm.heap.substring(s, m.start(i), m.end(i)) }
                    _ = realm.heap.root(v)
                    caps.append(v)
                    i += 1
                }
                var named: JSValue = .undefined
                if !prog.namedGroups.isEmpty {
                    named = realm.heap.newObject(proto: .null)
                    _ = realm.heap.root(named)
                    for g in prog.namedGroups {
                        let kv = realm.heap.newString(utf16: g.name)
                        _ = realm.heap.root(kv)
                        if let key = realm.heap.propertyKey(kv) {
                            _ = realm.heap.createDataProperty(named, key, caps[g.index - 1])
                        }
                    }
                }
                try realm.b2ReplaceEmit(&sb, &next, functional, replaceValue, s, matched, m.start(0), caps, named)
                realm.heap.popRoots(to: rd)
                if realm.heap.termination != nil { throw JSThrow() }
            }
        } else {
            let results = realm.b2NewArray()
            _ = realm.heap.root(results)
            while true {
                let rd = realm.heap.rootDepth
                let result = try realm.regExpExecAbstract(rx, s)
                if result.isNull { break }
                _ = realm.heap.root(result)
                realm.b2ArrayPush(results, result)
                if !global { break }
                let ms = try realm.b2Str(try realm.getV(result, .index(0)))
                if realm.heap.stringLength(ms) == 0 {
                    let thisIndex = try realm.toLength(try realm.getV(rx, kLast))
                    try realm.setV(rx, kLast, .number(realm.b2Advance(s, thisIndex, fu)), strict: true)
                }
                realm.heap.popRoots(to: rd)
                if realm.heap.termination != nil { throw JSThrow() }
            }
            let count = Int(realm.heap.arrayLength(results))
            var ri = 0
            while ri < count {
                let rd = realm.heap.rootDepth
                let result = try realm.getV(results, .index(UInt32(ri)))
                let resultLength = try realm.toLength(try realm.getV(result, realm.heap.names.length))
                let nCaptures = max(resultLength - 1, 0)
                let matched = try realm.b2Str(try realm.getV(result, .index(0)))
                var position = try realm.b2ToInt(try realm.getV(result, realm.heap.names.index))
                position = position < 0 ? 0 : (position > Double(len) ? Double(len) : position)
                var caps: [JSValue] = []
                var n = 1
                while n <= nCaptures {
                    var capN = try realm.getV(result, try realm.toPropertyKey(.number(n)))
                    if !capN.isUndefined { capN = try realm.b2Str(capN) }
                    _ = realm.heap.root(capN)
                    caps.append(capN)
                    n += 1
                }
                var named = try realm.getV(result, realm.b2.kGroups)
                _ = realm.heap.root(named)
                if !functional && !named.isUndefined {
                    named = try realm.toObject(named)
                    _ = realm.heap.root(named)
                }
                try realm.b2ReplaceEmit(&sb, &next, functional, replaceValue, s, matched, Int(position), caps, named, namedForSubstitution: true)
                realm.heap.popRoots(to: rd)
                if realm.heap.termination != nil { throw JSThrow() }
                ri += 1
            }
        }
        if next >= len { return try realm.b2Finish(sb) }
        realm.heap.b2Append(&sb, s, next)
        return try realm.b2Finish(sb)
    })

    // @@split
    realm.defineMethod(rp, "[Symbol.split]", length: 2, key: .symbol(w.split.handle), b2Rooted {
        (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let rx = try realm.b2ThisRegExp(args, "[Symbol.split]")
        let s = try realm.b2Str(args[0])
        let c = try realm.b2SpeciesConstructor(rx, realm.intrinsic(.regExpConstructor))
        let flags = try realm.b2Str(try realm.getV(rx, realm.b2.kFlags))
        let fu = realm.heap.b2IndexOf(flags, [0x75], 0) >= 0 || realm.heap.b2IndexOf(flags, [0x76], 0) >= 0
        var newFlags = flags
        if realm.heap.b2IndexOf(flags, [0x79], 0) < 0 {
            newFlags = try realm.b2Str(realm.heap.concat(flags, realm.string("y")) ?? flags)
        }
        let splitter = try realm.construct(c, args: [rx, newFlags])
        _ = realm.heap.root(splitter)
        let a = realm.b2NewArray()
        _ = realm.heap.root(a)
        let lim: UInt32 = args[1].isUndefined ? UInt32.max : jsToUint32(try realm.toNumber(args[1]))
        if lim == 0 { return a }
        let size = realm.heap.stringLength(s)
        if size == 0 {
            let z = try realm.regExpExecAbstract(splitter, s)
            if !z.isNull { return a }
            realm.b2ArrayPush(a, s)
            return a
        }
        var p = 0
        var count: UInt32 = 0
        if let prog = realm.b2FastProgram(splitter, flags: nil) {
            // Scan with a non-sticky program: the first match at or after q is
            // the first position at which the sticky loop would succeed.
            var fl2 = prog.flags
            fl2.bits &= ~JSRegExpFlags.sticky
            let scan: JSRegExpProgram
            do throws(JSRegExpError) {
                scan = try realm.b2.regExpCache.program(pattern: prog.source, flags: fl2)
            } catch {
                throw realm.throwSyntaxError(error.message)
            }
            var q = 0
            while q < size {
                var found: JSRegExpMatch? = nil
                switch realm.heap.regExpExec(scan, s, from: q) {
                case .noMatch: break
                case .stepLimit:
                    realm.heap.requestTermination(.regexSteps)
                    throw JSThrow()
                case .stackLimit:
                    throw realm.throwRangeError("Maximum call stack size exceeded")
                case .match(let m): found = m
                }
                guard let m = found, m.start(0) < size else { break }
                let qq = m.start(0)
                let e = min(m.end(0), size)
                if e == p {
                    q = realm.b2Advance(s, max(qq, q), fu)
                    continue
                }
                realm.b2ArrayPush(a, realm.heap.substring(s, p, qq))
                count += 1
                if count == lim { return a }
                p = e
                var i = 1
                while i <= prog.captureCount {
                    var v: JSValue = .undefined
                    if m.matched(i) { v = realm.heap.substring(s, m.start(i), m.end(i)) }
                    realm.b2ArrayPush(a, v)
                    count += 1
                    if count == lim { return a }
                    i += 1
                }
                q = p
                if realm.heap.termination != nil { throw JSThrow() }
            }
            realm.b2ArrayPush(a, realm.heap.substring(s, p, size))
            return a
        }
        var q = 0
        while q < size {
            let rd = realm.heap.rootDepth
            try realm.setV(splitter, kLast, .number(q), strict: true)
            let z = try realm.regExpExecAbstract(splitter, s)
            if z.isNull {
                q = realm.b2Advance(s, q, fu)
            } else {
                _ = realm.heap.root(z)
                var e = try realm.toLength(try realm.getV(splitter, kLast))
                e = min(e, size)
                if e == p {
                    q = realm.b2Advance(s, q, fu)
                } else {
                    realm.b2ArrayPush(a, realm.heap.substring(s, p, q))
                    count += 1
                    if count == lim { return a }
                    p = e
                    let nc = max(try realm.toLength(try realm.getV(z, realm.heap.names.length)) - 1, 0)
                    var i = 1
                    while i <= nc {
                        let v = try realm.getV(z, try realm.toPropertyKey(.number(i)))
                        realm.b2ArrayPush(a, v)
                        count += 1
                        if count == lim { return a }
                        i += 1
                    }
                    q = p
                }
            }
            realm.heap.popRoots(to: rd)
            if realm.heap.termination != nil { throw JSThrow() }
        }
        realm.b2ArrayPush(a, realm.heap.substring(s, p, size))
        return a
    })
}

extension JSRealm {
    /// One match of Symbol.replace: call the replacer or expand the template,
    /// and append to the result if the match lies at or after `next`.
    func b2ReplaceEmit(_ sb: inout JSStringBuilder, _ next: inout Int, _ functional: Bool, _ replaceValue: JSValue,
                       _ s: JSValue, _ matched: JSValue, _ position: Int, _ captures: [JSValue], _ named: JSValue,
                       namedForSubstitution: Bool = true) throws(JSThrow) {
        var replacement: JSValue
        if functional {
            var cargs: [JSValue] = [matched]
            cargs.append(contentsOf: captures)
            cargs.append(.number(position))
            cargs.append(s)
            if !named.isUndefined { cargs.append(named) }
            let rv = try call(replaceValue, this: .undefined, args: cargs)
            replacement = try toStringValue(rv)
        } else {
            replacement = try b2GetSubstitution(matched, s, position, captures, named, replaceValue)
        }
        if position >= next {
            heap.b2Append(&sb, s, next, position)
            heap.b2Append(&sb, replacement)
            next = position + heap.stringLength(matched)
            try b2CheckLength(sb)
        }
    }
}
