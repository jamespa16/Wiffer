// JSON.parse / JSON.stringify (ROADMAP Phase 9C, ES2023) and the 9C
// installer entry point jsInstallBuiltins1.
//
// parse: recursive descent over the string's UTF-16 units, depth capped
// (and checked against the native stack floor); numbers go through
// jsStringToNumber (correct rounding); the reviver walk is the spec's
// InternalizeJSONProperty. stringify: replacer function or property list,
// indent, toJSON, cycle detection (TypeError), well-formed output for lone
// surrogates, depth capped.

func jsInstallBuiltins1(_ realm: JSRealm) {
    let js = realm.jsNewArray()
    realm.setIntrinsic(.arrayJoinStack, js)
    jsInstallObject(realm)
    jsInstallArray(realm)
    jsInstallNumber(realm)
    jsInstallMath(realm)
    jsInstallJSON(realm)
}

let jsJSONMaxDepth = 500

extension JSStringBuilder {
    mutating func jsTruncate(_ n: Int) {
        if n >= count { return }
        if isWide { utf16.removeSubrange(n...) } else { latin1.removeSubrange(n...) }
    }
}

struct JSJSONParser {
    let realm: JSRealm
    let units: [UInt16]
    var pos = 0

    init(realm: JSRealm, units: [UInt16]) {
        self.realm = realm
        self.units = units
    }

    func fail() -> JSThrow {
        if pos >= units.count { return realm.throwSyntaxError("Unexpected end of JSON input") }
        let c = units[pos]
        var tok = "?"
        if c < 0x80 { tok = String(UnicodeScalar(UInt8(c))) }
        else { tok = "non-ASCII character" }
        return realm.throwSyntaxError("Unexpected token " + tok + " in JSON at position " + String(pos))
    }

    mutating func skipWS() {
        while pos < units.count {
            let c = units[pos]
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { pos += 1 } else { break }
        }
    }

    mutating func parseTop() throws(JSThrow) -> JSValue {
        skipWS()
        let v = try parseValue(0)
        skipWS()
        if pos < units.count { throw fail() }
        return v
    }

    mutating func expect(_ word: [UInt8]) throws(JSThrow) {
        for b in word {
            if pos >= units.count || units[pos] != UInt16(b) { throw fail() }
            pos += 1
        }
    }

    /// The result is unrooted: attach it before allocating again.
    mutating func parseValue(_ depth: Int) throws(JSThrow) -> JSValue {
        guard pos < units.count else { throw fail() }
        let h = realm.heap
        let c = units[pos]
        switch c {
        case 0x7B: return try parseObject(depth)
        case 0x5B: return try parseArray(depth)
        case 0x22: return try parseString()
        case 0x74: try expect([0x74, 0x72, 0x75, 0x65]); return .true
        case 0x66: try expect([0x66, 0x61, 0x6C, 0x73, 0x65]); return .false
        case 0x6E: try expect([0x6E, 0x75, 0x6C, 0x6C]); return .null
        case 0x2D, 0x30...0x39: return try parseNumber()
        default: _ = h; throw fail()
        }
    }

    mutating func parseNumber() throws(JSThrow) -> JSValue {
        let start = pos
        if units[pos] == 0x2D { pos += 1 }
        guard pos < units.count else { throw fail() }
        if units[pos] == 0x30 {
            pos += 1
        } else if units[pos] >= 0x31 && units[pos] <= 0x39 {
            while pos < units.count && units[pos] >= 0x30 && units[pos] <= 0x39 { pos += 1 }
        } else { throw fail() }
        var simple = true
        if pos < units.count && units[pos] == 0x2E {
            simple = false
            pos += 1
            guard pos < units.count, units[pos] >= 0x30, units[pos] <= 0x39 else { throw fail() }
            while pos < units.count && units[pos] >= 0x30 && units[pos] <= 0x39 { pos += 1 }
        }
        if pos < units.count && (units[pos] == 0x65 || units[pos] == 0x45) {
            simple = false
            pos += 1
            if pos < units.count && (units[pos] == 0x2B || units[pos] == 0x2D) { pos += 1 }
            guard pos < units.count, units[pos] >= 0x30, units[pos] <= 0x39 else { throw fail() }
            while pos < units.count && units[pos] >= 0x30 && units[pos] <= 0x39 { pos += 1 }
        }
        let neg = units[start] == 0x2D
        let digits = pos - start - (neg ? 1 : 0)
        if simple && digits <= 9 {
            var n = 0
            for i in (start + (neg ? 1 : 0))..<pos { n = n * 10 + Int(units[i] - 0x30) }
            if neg { return n == 0 ? .double(-0.0) : .number(-n) }
            return .number(n)
        }
        return .number(jsStringToNumber(units[start..<pos]))
    }

    mutating func hex4() throws(JSThrow) -> UInt16 {
        var v = 0
        for _ in 0..<4 {
            guard pos < units.count else { throw fail() }
            let c = units[pos]
            var d = -1
            if c >= 0x30 && c <= 0x39 { d = Int(c) - 0x30 }
            else if c >= 0x61 && c <= 0x66 { d = Int(c) - 0x61 + 10 }
            else if c >= 0x41 && c <= 0x46 { d = Int(c) - 0x41 + 10 }
            if d < 0 { throw fail() }
            v = v * 16 + d
            pos += 1
        }
        return UInt16(v)
    }

    mutating func parseString() throws(JSThrow) -> JSValue {
        pos += 1   // opening quote
        let start = pos
        // Fast path: no escapes.
        while pos < units.count {
            let c = units[pos]
            if c == 0x22 {
                let v = realm.heap.newString(utf16: Array(units[start..<pos]))
                pos += 1
                try realm.jsCheckAlloc()
                return v
            }
            if c == 0x5C || c < 0x20 { break }
            pos += 1
        }
        var b = JSStringBuilder()
        for i in start..<pos { b.append(unit: units[i]) }
        while true {
            guard pos < units.count else { throw fail() }
            let c = units[pos]
            if c == 0x22 { pos += 1; break }
            if c < 0x20 { throw fail() }
            if c == 0x5C {
                pos += 1
                guard pos < units.count else { throw fail() }
                let e = units[pos]
                pos += 1
                switch e {
                case 0x22: b.append(unit: 0x22)
                case 0x5C: b.append(unit: 0x5C)
                case 0x2F: b.append(unit: 0x2F)
                case 0x62: b.append(unit: 0x08)
                case 0x66: b.append(unit: 0x0C)
                case 0x6E: b.append(unit: 0x0A)
                case 0x72: b.append(unit: 0x0D)
                case 0x74: b.append(unit: 0x09)
                case 0x75: b.append(unit: try hex4())
                default: pos -= 1; throw fail()
                }
            } else {
                b.append(unit: c)
                pos += 1
            }
            if !realm.heap.canMakeString(length: b.count) { throw realm.throwRangeError("Invalid string length") }
        }
        let v = realm.heap.newString(b)
        try realm.jsCheckAlloc()
        return v
    }

    mutating func parseArray(_ depth: Int) throws(JSThrow) -> JSValue {
        let h = realm.heap
        if depth >= jsJSONMaxDepth { throw realm.throwRangeError("JSON nesting too deep") }
        try realm.enterNative()
        pos += 1
        let rd = h.rootDepth
        defer { h.popRoots(to: rd) }
        let a = realm.jsNewArray()
        _ = h.root(a)
        try realm.jsCheckAlloc()
        skipWS()
        if pos < units.count && units[pos] == 0x5D { pos += 1; return a }
        var n: UInt32 = 0
        while true {
            skipWS()
            let v = try parseValue(depth + 1)
            if !h.createDataProperty(a, .index(n), v) { try realm.jsCheckAlloc() }
            n += 1
            skipWS()
            guard pos < units.count else { throw fail() }
            if units[pos] == 0x2C { pos += 1; continue }
            if units[pos] == 0x5D { pos += 1; break }
            throw fail()
        }
        return a
    }

    mutating func parseObject(_ depth: Int) throws(JSThrow) -> JSValue {
        let h = realm.heap
        if depth >= jsJSONMaxDepth { throw realm.throwRangeError("JSON nesting too deep") }
        try realm.enterNative()
        pos += 1
        let rd = h.rootDepth
        defer { h.popRoots(to: rd) }
        let o = h.newObject(proto: realm.objectPrototype)
        _ = h.root(o)
        try realm.jsCheckAlloc()
        skipWS()
        if pos < units.count && units[pos] == 0x7D { pos += 1; return o }
        while true {
            skipWS()
            guard pos < units.count, units[pos] == 0x22 else { throw fail() }
            let d2 = h.rootDepth
            let kv = try parseString()
            _ = h.root(kv)
            skipWS()
            guard pos < units.count, units[pos] == 0x3A else { throw fail() }
            pos += 1
            skipWS()
            let v = try parseValue(depth + 1)
            _ = h.root(v)
            if let k = h.propertyKey(kv) {
                _ = h.root(h.keyValue(k))
                if !h.createDataProperty(o, k, v) { try realm.jsCheckAlloc() }
            }
            h.popRoots(to: d2)
            skipWS()
            guard pos < units.count else { throw fail() }
            if units[pos] == 0x2C { pos += 1; continue }
            if units[pos] == 0x7D { pos += 1; break }
            throw fail()
        }
        return o
    }
}

extension JSRealm {
    /// InternalizeJSONProperty(holder, name).
    func jsInternalize(_ holder: JSValue, _ name: JSPropertyKey, _ reviver: JSValue) throws(JSThrow) -> JSValue {
        try enterNative()
        let h = heap
        let rd = h.rootDepth
        defer { h.popRoots(to: rd) }
        _ = h.root(holder)
        jsRootKey(name)
        let val = try getV(holder, name)
        _ = h.root(val)
        if val.isObject {
            if jsIsArray(val) {
                let len = try arrLength(val)
                var i = 0
                while i < len {
                    let k = try jsIndexKey(i)
                    let nv = try jsInternalize(val, k, reviver)
                    _ = h.root(nv)
                    if nv.isUndefined { _ = h.deleteProperty(val, k) } else { _ = h.createDataProperty(val, k, nv) }
                    try jsCheckAlloc()
                    i += 1
                    try jsTick(i)
                }
            } else {
                for k in h.ownKeys(val) where !k.isSymbol {
                    guard let p = h.getOwnProperty(val, k), p.enumerable else { continue }
                    let nv = try jsInternalize(val, k, reviver)
                    _ = h.root(nv)
                    if nv.isUndefined { _ = h.deleteProperty(val, k) } else { _ = h.createDataProperty(val, k, nv) }
                    try jsCheckAlloc()
                }
            }
        }
        let kv = h.keyValue(name)
        _ = h.root(kv)
        return try call(reviver, this: holder, args: [kv, val])
    }
}

final class JSJSONWriter {
    let realm: JSRealm
    var b = JSStringBuilder()
    var replacer: JSValue = .undefined
    var propertyList: [JSPropertyKey]? = nil
    var gap: [UInt16] = []
    var indent: [UInt16] = []
    var stack: [UInt32] = []

    init(realm: JSRealm) { self.realm = realm }

    func quote(_ s: JSValue) {
        let units = realm.heap.stringUnits(s)
        b.append(unit: 0x22)
        let hex: [UInt8] = Array("0123456789abcdef".utf8)
        var i = 0
        while i < units.count {
            let c = units[i]
            switch c {
            case 0x22: b.append(unit: 0x5C); b.append(unit: 0x22)
            case 0x5C: b.append(unit: 0x5C); b.append(unit: 0x5C)
            case 0x08: b.append(unit: 0x5C); b.append(unit: 0x62)
            case 0x0C: b.append(unit: 0x5C); b.append(unit: 0x66)
            case 0x0A: b.append(unit: 0x5C); b.append(unit: 0x6E)
            case 0x0D: b.append(unit: 0x5C); b.append(unit: 0x72)
            case 0x09: b.append(unit: 0x5C); b.append(unit: 0x74)
            default:
                var esc = c < 0x20
                if c >= 0xD800 && c <= 0xDBFF {
                    if i + 1 < units.count && units[i + 1] >= 0xDC00 && units[i + 1] <= 0xDFFF {
                        b.append(unit: c); b.append(unit: units[i + 1]); i += 2; continue
                    }
                    esc = true
                } else if c >= 0xDC00 && c <= 0xDFFF { esc = true }
                if esc {
                    b.append(unit: 0x5C); b.append(unit: 0x75)
                    b.append(unit: UInt16(hex[Int(c >> 12)])); b.append(unit: UInt16(hex[Int((c >> 8) & 15)]))
                    b.append(unit: UInt16(hex[Int((c >> 4) & 15)])); b.append(unit: UInt16(hex[Int(c & 15)]))
                } else { b.append(unit: c) }
            }
            i += 1
        }
        b.append(unit: 0x22)
    }

    func newline() {
        if gap.isEmpty { return }
        b.append(unit: 0x0A)
        for u in indent { b.append(unit: u) }
    }

    /// Serialize holder[key]; false when the value is undefined-like.
    func property(_ holder: JSValue, _ key: JSPropertyKey, _ depth: Int) throws(JSThrow) -> Bool {
        let realm = self.realm
        let h = realm.heap
        let rd = h.rootDepth
        defer { h.popRoots(to: rd) }
        realm.jsRootKey(key)
        var value = try realm.getV(holder, key)
        _ = h.root(value)
        if value.isObject || value.isBigInt {
            let tj = try realm.getV(value, h.key("toJSON"))
            _ = h.root(tj)
            if h.isCallable(tj) {
                let kv = h.keyValue(key)
                _ = h.root(kv)
                value = try realm.call(tj, this: value, args: [kv])
                _ = h.root(value)
            }
        }
        if !replacer.isUndefined && h.isCallable(replacer) {
            let kv = h.keyValue(key)
            _ = h.root(kv)
            value = try realm.call(replacer, this: holder, args: [kv, value])
            _ = h.root(value)
        }
        if value.isObject {
            switch h.kind(value) {
            case .numberWrapper: value = .number(try realm.toNumber(value))
            case .stringWrapper: value = try realm.toStringValue(value); _ = h.root(value)
            case .booleanWrapper: value = h.slot(value, 0)
            case .bigintWrapper: value = h.slot(value, 0)
            default: break
            }
        }
        if value.isNull { b.append(ascii: Array("null".utf8)); return true }
        if value.isBool { b.append(ascii: Array((value.boolValue ? "true" : "false").utf8)); return true }
        if value.isString { quote(value); return try check() }
        if value.isNumber {
            let d = value.numberValue
            b.append(ascii: d.isFinite ? jsNumberToString(d) : Array("null".utf8))
            return true
        }
        if value.isBigInt { throw realm.throwTypeError("Do not know how to serialize a BigInt") }
        if value.isObject && !h.isCallable(value) {
            if realm.jsIsArray(value) { try array(value, depth) } else { try object(value, depth) }
            return try check()
        }
        return false
    }

    func check() throws(JSThrow) -> Bool {
        if !realm.heap.canMakeString(length: b.count) { throw realm.throwRangeError("Invalid string length") }
        try realm.jsCheckAlloc()
        return true
    }

    func enter(_ v: JSValue, _ depth: Int) throws(JSThrow) {
        if depth >= jsJSONMaxDepth { throw realm.throwRangeError("JSON nesting too deep") }
        try realm.enterNative()
        for s in stack where s == v.handle { throw realm.throwTypeError("Converting circular structure to JSON") }
        stack.append(v.handle)
    }

    func object(_ v: JSValue, _ depth: Int) throws(JSThrow) {
        let h = realm.heap
        try enter(v, depth)
        defer { stack.removeLast() }
        let stepback = indent
        indent.append(contentsOf: gap)
        var keys: [JSPropertyKey] = []
        if let pl = propertyList { keys = pl } else {
            for k in h.ownKeys(v) where !k.isSymbol {
                if let p = h.getOwnProperty(v, k), p.enumerable { keys.append(k) }
            }
        }
        let rd = h.rootDepth
        defer { h.popRoots(to: rd) }
        for k in keys { realm.jsRootKey(k) }
        b.append(unit: 0x7B)
        var any = false
        for k in keys {
            let mark = b.count
            if any { b.append(unit: 0x2C) }
            newline()
            quote(h.keyValue(k))
            b.append(unit: 0x3A)
            if !gap.isEmpty { b.append(unit: 0x20) }
            if try property(v, k, depth + 1) { any = true } else { b.jsTruncate(mark) }
        }
        indent = stepback
        if any { newline() }
        b.append(unit: 0x7D)
    }

    func array(_ v: JSValue, _ depth: Int) throws(JSThrow) {
        try enter(v, depth)
        defer { stack.removeLast() }
        let stepback = indent
        indent.append(contentsOf: gap)
        let len = try realm.arrLength(v)
        b.append(unit: 0x5B)
        var i = 0
        while i < len {
            if i > 0 { b.append(unit: 0x2C) }
            newline()
            let k = try realm.jsIndexKey(i)
            if !(try property(v, k, depth + 1)) { b.append(ascii: Array("null".utf8)) }
            i += 1
            try realm.jsTick(i)
        }
        indent = stepback
        if len > 0 { newline() }
        b.append(unit: 0x5D)
    }
}

func jsInstallJSON(_ realm: JSRealm) {
    let heap = realm.heap
    let j = heap.newObject(proto: realm.objectPrototype)
    let r = heap.root(j)
    defer { heap.popRoots(to: r.slot) }
    realm.defineGlobal("JSON", j)
    _ = heap.defineOwnProperty(j, .symbol(heap.symbolsWellKnown.toStringTag.handle),
                               .data(realm.string("JSON"), [.configurable]))
    realm.defineMethod(j, "parse", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let depth = h.rootDepth
        defer { h.popRoots(to: depth) }
        let text = try realm.toStringValue(args[0])
        _ = h.root(text)
        var p = JSJSONParser(realm: realm, units: h.stringUnits(text))
        let v = try p.parseTop()
        _ = h.root(v)
        let reviver = args[1]
        if h.isCallable(reviver) {
            let root = h.newObject(proto: realm.objectPrototype)
            _ = h.root(root)
            _ = h.createDataProperty(root, h.names.empty, v)
            try realm.jsCheckAlloc()
            return try realm.jsInternalize(root, h.names.empty, reviver)
        }
        return v
    }
    realm.defineMethod(j, "stringify", length: 3) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let depth = h.rootDepth
        defer { h.popRoots(to: depth) }
        let w = JSJSONWriter(realm: realm)
        let rep = args[1]
        if rep.isObject {
            if h.isCallable(rep) { w.replacer = rep }
            else if realm.jsIsArray(rep) {
                let len = try realm.arrLength(rep)
                var list: [JSPropertyKey] = []
                let hold = realm.jsNewArray()
                _ = h.root(hold)
                var i = 0
                while i < len {
                    let e = try realm.arrGet(rep, i)
                    _ = h.root(e)
                    var item: JSValue = .undefined
                    if e.isString { item = e }
                    else if e.isNumber { item = try realm.toStringValue(e) }
                    else if e.isObject && (h.kind(e) == .stringWrapper || h.kind(e) == .numberWrapper) {
                        item = try realm.toStringValue(e)
                    }
                    if item.isString, let k = h.propertyKey(item) {
                        _ = h.root(item)
                        _ = h.createDataProperty(hold, .index(UInt32(truncatingIfNeeded: i)), h.keyValue(k))
                        if !list.contains(k) { list.append(k) }
                    }
                    i += 1
                    try realm.jsTick(i)
                }
                w.propertyList = list
            }
        }
        var space = args[2]
        if space.isObject {
            if h.kind(space) == .numberWrapper { space = .number(try realm.toNumber(space)) }
            else if h.kind(space) == .stringWrapper { space = try realm.toStringValue(space) }
        }
        if space.isNumber {
            let n = Int(min(10, jsToIntegerOrInfinity(space.numberValue)))
            if n >= 1 { w.gap = [UInt16](repeating: 0x20, count: n) }
        } else if space.isString {
            w.gap = Array(h.stringUnits(space).prefix(10))
        }
        _ = h.root(w.replacer)
        let wrapper = h.newObject(proto: realm.objectPrototype)
        _ = h.root(wrapper)
        _ = h.createDataProperty(wrapper, h.names.empty, args[0])
        try realm.jsCheckAlloc()
        if !(try w.property(wrapper, h.names.empty, 0)) { return .undefined }
        let out = h.newString(w.b)
        try realm.jsCheckAlloc()
        return out
    }
}
