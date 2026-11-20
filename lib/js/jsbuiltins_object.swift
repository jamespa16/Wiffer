// Object constructor and Object.prototype (ROADMAP Phase 9C, ES2023).
//
// Installed by jsInstallObject(realm), after the base built-ins; it
// redefines the few base methods (Object.prototype.toString, ...) with the
// complete versions. Also hosts the small helpers the other 9C files share:
//
//   realm.jsIndexKey(i)            property key for an integer index
//                                  (index key, or a string key >= 2^32-1)
//   realm.jsNewArray(elements)     a fresh Array
//   realm.jsCheckAlloc()           throws if the heap cap terminated us
//   realm.jsFromDescriptor(p)      FromPropertyDescriptor
//   realm.jsForOf(iterable) { v in ... }   iterate with IteratorClose on
//                                  throw or early stop (body returns
//                                  false to stop)

extension JSRealm {
    func jsIndexKey(_ i: Int) throws(JSThrow) -> JSPropertyKey {
        if i >= 0 && i < 0xFFFF_FFFF { return .index(UInt32(i)) }
        return try toPropertyKey(.number(i))
    }

    func jsNewArray(_ elements: [JSValue] = []) -> JSValue {
        heap.newArray(proto: arrayPrototype, elements: elements)
    }

    func jsCheckAlloc() throws(JSThrow) {
        if heap.termination != nil { throw JSThrow() }
    }

    /// Root a string or symbol key's value for the rest of the scope.
    func jsRootKey(_ k: JSPropertyKey) {
        if k.isString { _ = heap.root(.string(k.handle)) } else if k.isSymbol { _ = heap.root(.symbol(k.handle)) }
    }

    /// FromPropertyDescriptor (allocates; the result is unrooted).
    func jsFromDescriptor(_ p: JSProperty) -> JSValue {
        let h = heap
        let depth = h.rootDepth
        defer { h.popRoots(to: depth) }
        // A host hook may return a fresh, unrooted value.
        _ = h.root(p.value); _ = h.root(p.getter); _ = h.root(p.setter)
        let o = h.newObject(proto: objectPrototype)
        _ = h.root(o)
        let n = h.names
        if p.isAccessor {
            _ = h.createDataProperty(o, n.get, p.getter)
            _ = h.createDataProperty(o, n.set, p.setter)
        } else {
            _ = h.createDataProperty(o, n.value, p.value)
            _ = h.createDataProperty(o, n.writable, .bool(p.writable))
        }
        _ = h.createDataProperty(o, n.enumerable, .bool(p.enumerable))
        _ = h.createDataProperty(o, n.configurable, .bool(p.configurable))
        return o
    }

    /// Iterate `iterable`; `body` returns false to stop early. The iterator
    /// is closed when the body throws or stops.
    func jsForOf(_ iterable: JSValue, _ body: (JSValue) throws(JSThrow) -> Bool) throws(JSThrow) {
        let depth = heap.rootDepth
        defer { heap.popRoots(to: depth) }
        _ = heap.root(iterable)
        let (it, next) = try getIterator(iterable)
        _ = heap.root(it)
        _ = heap.root(next)
        var n = 0
        while true {
            let (done, v) = try iteratorStep(it, next)
            if done { return }
            let d2 = heap.rootDepth
            _ = heap.root(v)
            var keepGoing = true
            do throws(JSThrow) {
                keepGoing = try body(v)
            } catch {
                if !isTerminating {
                    let saved = exception
                    _ = heap.root(saved)
                    try? iteratorClose(it, next)
                    exception = saved
                }
                throw error
            }
            heap.popRoots(to: d2)
            if !keepGoing {
                try iteratorClose(it, next)
                return
            }
            n += 1
            if n & 1023 == 0 { try checkInterrupt() }
        }
    }

    /// The object's [[SetPrototypeOf]] with the immutable-prototype rule of
    /// %Object.prototype%.
    func jsSetPrototype(_ o: JSValue, _ p: JSValue) throws(JSThrow) -> Bool {
        if o == objectPrototype { return p == (try objGetPrototypeOf(o)) }
        return (try objSetPrototypeOf(o, p))
    }

    func jsBuiltinTag(_ o: JSValue) -> String {
        // 9E: a proxy for an array is "Array" (IsArray sees through proxies).
        if heap.kind(o) == .proxy, heap.proxyFallback(o, { t in heap.kind(t) == .array }) == true { return "Array" }
        switch heap.kind(o) {
        case .array: return "Array"
        case .function, .nativeFunction, .boundFunction: return "Function"
        case .error: return "Error"
        case .booleanWrapper: return "Boolean"
        case .numberWrapper: return "Number"
        case .stringWrapper: return "String"
        case .date: return "Date"
        case .regexp: return "RegExp"
        case .arguments: return "Arguments"
        default: return heap.isCallable(o) ? "Function" : "Object"
        }
    }

    /// SetIntegrityLevel.
    func jsSetIntegrity(_ o: JSValue, frozen: Bool) throws(JSThrow) -> Bool {
        let h = heap
        guard (try objPreventExtensions(o)) else { return false }
        for k in (try objOwnKeys(o)) {
            if frozen {
                guard let p = (try objGetOwnProperty(o, k)) else { continue }
                var d = JSPropertyDescriptor(configurable: false)
                if !p.isAccessor { d.writable = false }
                if !(try objDefineOwnProperty(o, k, d)) {
                    try jsCheckAlloc()
                    throw throwTypeError("Cannot freeze property " + keyDisplay(k))
                }
            } else {
                if !(try objDefineOwnProperty(o, k, JSPropertyDescriptor(configurable: false))) {
                    try jsCheckAlloc()
                    throw throwTypeError("Cannot seal property " + keyDisplay(k))
                }
            }
        }
        return true
    }

    func jsTestIntegrity(_ o: JSValue, frozen: Bool) throws(JSThrow) -> Bool {
        let h = heap
        if (try objIsExtensible(o)) { return false }
        for k in (try objOwnKeys(o)) {
            guard let p = (try objGetOwnProperty(o, k)) else { continue }
            if p.configurable { return false }
            if frozen && !p.isAccessor && p.writable { return false }
        }
        return true
    }

    /// [[DefineOwnProperty]] for Object.defineProperty(ies): Array "length"
    /// descriptors get ArraySetLength's ToUint32/ToNumber coercion first.
    func jsDefineOwn(_ o: JSValue, _ k: JSPropertyKey, _ dIn: JSPropertyDescriptor) throws(JSThrow) -> Bool {
        var d = dIn
        if k == heap.names.length && heap.kind(o) == .array, let v = d.value {
            let u = jsToUint32(try toNumber(v))
            let n = try toNumber(v)
            if Double(u) != n { throw throwRangeError("Invalid array length") }
            d.value = .number(Int(u))
        }
        return (try objDefineOwnProperty(o, k, d))
    }

    /// ObjectDefineProperties(o, props).
    func jsDefineProperties(_ o: JSValue, _ propsIn: JSValue) throws(JSThrow) {
        let h = heap
        let depth = h.rootDepth
        defer { h.popRoots(to: depth) }
        let props = try toObject(propsIn)
        _ = h.root(props)
        var keys: [JSPropertyKey] = []
        var descs: [JSPropertyDescriptor] = []
        // Descriptor values stay rooted on the root stack.
        for k in (try objOwnKeys(props)) {
            guard let pr = (try objGetOwnProperty(props, k)), pr.enumerable else { continue }
            let dv = try getV(props, k)
            _ = h.root(dv)
            let d = try toPropertyDescriptor(dv)
            if let v = d.value { _ = h.root(v) }
            if let g = d.getter { _ = h.root(g) }
            if let s = d.setter { _ = h.root(s) }
            jsRootKey(k)
            keys.append(k)
            descs.append(d)
        }
        for i in 0..<keys.count {
            if !(try jsDefineOwn(o, keys[i], descs[i])) {
                try jsCheckAlloc()
                throw throwTypeError("Cannot define property " + keyDisplay(keys[i]))
            }
        }
    }
}

func jsInstallObject(_ realm: JSRealm) {
    let heap = realm.heap
    let op = realm.objectPrototype
    let oc = realm.intrinsic(.objectConstructor)
    let tagKey = JSPropertyKey.symbol(heap.symbolsWellKnown.toStringTag.handle)

    // ------------------------------------------------- Object.prototype
    realm.defineMethod(op, "toString", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let t = args.this
        if t.isUndefined { return realm.string("[object Undefined]") }
        if t.isNull { return realm.string("[object Null]") }
        let h = realm.heap
        let depth = h.rootDepth
        defer { h.popRoots(to: depth) }
        let o = try realm.toObject(t)
        _ = h.root(o)
        var tag = realm.jsBuiltinTag(o)
        let st = try realm.getV(o, .symbol(h.symbolsWellKnown.toStringTag.handle))
        if st.isString { tag = h.swiftString(st) }
        return realm.string("[object " + tag + "]")
    }
    realm.defineMethod(op, "toLocaleString", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let f = try realm.getV(args.this, realm.heap.names.toString)
        guard realm.heap.isCallable(f) else { throw realm.throwTypeError("toString is not a function") }
        return try realm.call(f, this: args.this, args: [])
    }
    realm.defineMethod(op, "valueOf", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        try realm.toObject(args.this)
    }
    realm.defineMethod(op, "hasOwnProperty", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let depth = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: depth) }
        let k = try realm.toPropertyKey(args[0])
        realm.jsRootKey(k)
        let o = try realm.toObject(args.this)
        return .bool(((try realm.objGetOwnProperty(o, k)) != nil))
    }
    realm.defineGetter(op, "__proto__", setter: { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let t = args.this
        if t.isNullish { throw realm.throwTypeError("Object.prototype.__proto__ called on null or undefined") }
        let p = args[0]
        guard p.isObject || p.isNull else { return .undefined }
        guard t.isObject else { return .undefined }
        if !(try realm.jsSetPrototype(t, p)) { throw realm.throwTypeError("Cyclic __proto__ value or object is not extensible") }
        return .undefined
    }) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let o = try realm.toObject(args.this)
        return (try realm.objGetPrototypeOf(o))
    }
    realm.defineMethod(op, "__defineGetter__", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let o = try realm.toObject(args.this)
        guard realm.heap.isCallable(args[1]) else { throw realm.throwTypeError("Object.prototype.__defineGetter__: Expecting function") }
        let k = try realm.toPropertyKey(args[0])
        let d = JSPropertyDescriptor(getter: args[1], enumerable: true, configurable: true)
        if !(try realm.objDefineOwnProperty(o, k, d)) { throw realm.throwTypeError("Cannot define property " + realm.keyDisplay(k)) }
        return .undefined
    }
    realm.defineMethod(op, "__defineSetter__", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let o = try realm.toObject(args.this)
        guard realm.heap.isCallable(args[1]) else { throw realm.throwTypeError("Object.prototype.__defineSetter__: Expecting function") }
        let k = try realm.toPropertyKey(args[0])
        let d = JSPropertyDescriptor(setter: args[1], enumerable: true, configurable: true)
        if !(try realm.objDefineOwnProperty(o, k, d)) { throw realm.throwTypeError("Cannot define property " + realm.keyDisplay(k)) }
        return .undefined
    }
    let lookup: (Bool) -> JSNativeFunction = { (getter: Bool) -> JSNativeFunction in
        return { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            var o = try realm.toObject(args.this)
            let k = try realm.toPropertyKey(args[0])
            var steps = 0
            while o.isObject && steps < JSHeap.maxProtoChain {
                if let p = (try realm.objGetOwnProperty(o, k)) {
                    if p.isAccessor { return getter ? p.getter : p.setter }
                    return .undefined
                }
                o = (try realm.objGetPrototypeOf(o))
                steps += 1
            }
            return .undefined
        }
    }
    realm.defineMethod(op, "__lookupGetter__", length: 1, lookup(true))
    realm.defineMethod(op, "__lookupSetter__", length: 1, lookup(false))

    // ------------------------------------------------------- statics
    realm.defineMethod(oc, "getPrototypeOf", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let o = try realm.toObject(args[0])
        return (try realm.objGetPrototypeOf(o))
    }
    realm.defineMethod(oc, "setPrototypeOf", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let o = args[0], p = args[1]
        if o.isNullish { throw realm.throwTypeError("Object.setPrototypeOf called on null or undefined") }
        guard p.isObject || p.isNull else { throw realm.throwTypeError("Object prototype may only be an Object or null") }
        if o.isObject, !(try realm.jsSetPrototype(o, p)) { throw realm.throwTypeError("Cyclic __proto__ value or object is not extensible") }
        return o
    }
    realm.defineMethod(oc, "create", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let p = args[0]
        guard p.isObject || p.isNull else { throw realm.throwTypeError("Object prototype may only be an Object or null") }
        let h = realm.heap
        let depth = h.rootDepth
        defer { h.popRoots(to: depth) }
        let o = h.newObject(proto: p)
        _ = h.root(o)
        try realm.jsCheckAlloc()
        if !args[1].isUndefined { try realm.jsDefineProperties(o, args[1]) }
        return o
    }
    realm.defineMethod(oc, "defineProperty", length: 3) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let o = args[0]
        guard o.isObject else { throw realm.throwTypeError("Object.defineProperty called on non-object") }
        let h = realm.heap
        let depth = h.rootDepth
        defer { h.popRoots(to: depth) }
        let k = try realm.toPropertyKey(args[1])
        realm.jsRootKey(k)
        let d = try realm.toPropertyDescriptor(args[2])
        if !(try realm.jsDefineOwn(o, k, d)) {
            try realm.jsCheckAlloc()
            throw realm.throwTypeError("Cannot redefine property: " + realm.keyDisplay(k))
        }
        return o
    }
    realm.defineMethod(oc, "defineProperties", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let o = args[0]
        guard o.isObject else { throw realm.throwTypeError("Object.defineProperties called on non-object") }
        try realm.jsDefineProperties(o, args[1])
        return o
    }
    realm.defineMethod(oc, "getOwnPropertyDescriptor", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let depth = h.rootDepth
        defer { h.popRoots(to: depth) }
        let o = try realm.toObject(args[0])
        _ = h.root(o)
        let k = try realm.toPropertyKey(args[1])
        realm.jsRootKey(k)
        guard let p = (try realm.objGetOwnProperty(o, k)) else { return .undefined }
        return realm.jsFromDescriptor(p)
    }
    realm.defineMethod(oc, "getOwnPropertyDescriptors", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let depth = h.rootDepth
        defer { h.popRoots(to: depth) }
        let o = try realm.toObject(args[0])
        _ = h.root(o)
        let res = h.newObject(proto: realm.objectPrototype)
        _ = h.root(res)
        for k in (try realm.objOwnKeys(o)) {
            guard let p = (try realm.objGetOwnProperty(o, k)) else { continue }
            let d = realm.jsFromDescriptor(p)
            _ = h.root(d)
            _ = h.createDataProperty(res, k, d)
        }
        try realm.jsCheckAlloc()
        return res
    }
    let ownNames: (Bool) -> JSNativeFunction = { (symbols: Bool) -> JSNativeFunction in
        return { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let h = realm.heap
            let depth = h.rootDepth
            defer { h.popRoots(to: depth) }
            let o = try realm.toObject(args[0])
            _ = h.root(o)
            let a = realm.jsNewArray()
            _ = h.root(a)
            var n: UInt32 = 0
            for k in (try realm.objOwnKeys(o)) where k.isSymbol == symbols {
                let d2 = h.rootDepth
                let kv = symbols ? JSValue.symbol(k.handle) : h.keyValue(k)
                _ = h.root(kv)
                _ = h.createDataProperty(a, .index(n), kv)
                n += 1
                h.popRoots(to: d2)
            }
            try realm.jsCheckAlloc()
            return a
        }
    }
    realm.defineMethod(oc, "getOwnPropertyNames", length: 1, ownNames(false))
    realm.defineMethod(oc, "getOwnPropertySymbols", length: 1, ownNames(true))

    // keys / values / entries: 0 / 1 / 2.
    let enumerable: (Int) -> JSNativeFunction = { (mode: Int) -> JSNativeFunction in
        return { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let h = realm.heap
            let depth = h.rootDepth
            defer { h.popRoots(to: depth) }
            let o = try realm.toObject(args[0])
            _ = h.root(o)
            let a = realm.jsNewArray()
            _ = h.root(a)
            var n: UInt32 = 0
            var count = 0
            for k in (try realm.objOwnKeys(o)) where !k.isSymbol {
                guard let p = (try realm.objGetOwnProperty(o, k)), p.enumerable else { continue }
                let d2 = h.rootDepth
                var item: JSValue
                if mode == 0 {
                    item = h.keyValue(k)
                } else {
                    let kv = h.keyValue(k)
                    _ = h.root(kv)
                    let v = p.isAccessor || h.kind(o) == .proxy ? try realm.getV(o, k) : (p.value)
                    _ = h.root(v)
                    item = mode == 1 ? v : realm.jsNewArray([kv, v])
                }
                _ = h.root(item)
                _ = h.createDataProperty(a, .index(n), item)
                n += 1
                h.popRoots(to: d2)
                count += 1
                if count & 1023 == 0 { try realm.checkInterrupt() }
            }
            try realm.jsCheckAlloc()
            return a
        }
    }
    realm.defineMethod(oc, "keys", length: 1, enumerable(0))
    realm.defineMethod(oc, "values", length: 1, enumerable(1))
    realm.defineMethod(oc, "entries", length: 1, enumerable(2))

    realm.defineMethod(oc, "assign", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let depth = h.rootDepth
        defer { h.popRoots(to: depth) }
        let to = try realm.toObject(args[0])
        _ = h.root(to)
        if args.count > 1 {
            for i in 1..<args.count {
                let src = args[i]
                if src.isNullish { continue }
                let d2 = h.rootDepth
                let from = try realm.toObject(src)
                _ = h.root(from)
                for k in (try realm.objOwnKeys(from)) {
                    guard let p = (try realm.objGetOwnProperty(from, k)), p.enumerable else { continue }
                    let v = try realm.getV(from, k)
                    _ = h.root(v)
                    try realm.setV(to, k, v, strict: true)
                }
                h.popRoots(to: d2)
            }
        }
        return to
    }
    realm.defineMethod(oc, "fromEntries", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        if args[0].isNullish { throw realm.throwTypeError("Object.fromEntries requires an iterable") }
        let depth = h.rootDepth
        defer { h.popRoots(to: depth) }
        let o = h.newObject(proto: realm.objectPrototype)
        _ = h.root(o)
        try realm.jsForOf(args[0]) { (item: JSValue) throws(JSThrow) -> Bool in
            guard item.isObject else { throw realm.throwTypeError("Iterator value " + realm.describeForError(item) + " is not an entry object") }
            let k = try realm.getV(item, .index(0))
            _ = h.root(k)
            let v = try realm.getV(item, .index(1))
            _ = h.root(v)
            let pk = try realm.toPropertyKey(k)
            realm.jsRootKey(pk)
            if !h.createDataProperty(o, pk, v) { try realm.jsCheckAlloc() }
            return true
        }
        return o
    }
    realm.defineMethod(oc, "groupBy", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        if args[0].isNullish { throw realm.throwTypeError("Object.groupBy requires an iterable") }
        guard h.isCallable(args[1]) else { throw realm.throwTypeError("callback is not a function") }
        let depth = h.rootDepth
        defer { h.popRoots(to: depth) }
        let res = h.newObject(proto: .null)
        _ = h.root(res)
        let cb = args[1]
        var idx = 0
        try realm.jsForOf(args[0]) { (item: JSValue) throws(JSThrow) -> Bool in
            let kv = try realm.call(cb, this: .undefined, args: [item, .number(idx)])
            _ = h.root(kv)
            let k = try realm.toPropertyKey(kv)
            realm.jsRootKey(k)
            var group: JSValue
            if let p = (try realm.objGetOwnProperty(res, k)) { group = p.value } else {
                group = realm.jsNewArray()
                _ = h.root(group)
                _ = h.createDataProperty(res, k, group)
            }
            _ = h.createDataProperty(group, .index(h.arrayLength(group)), item)
            try realm.jsCheckAlloc()
            idx += 1
            return true
        }
        return res
    }
    realm.defineMethod(oc, "hasOwn", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let depth = h.rootDepth
        defer { h.popRoots(to: depth) }
        let o = try realm.toObject(args[0])
        _ = h.root(o)
        let k = try realm.toPropertyKey(args[1])
        realm.jsRootKey(k)
        return .bool(((try realm.objGetOwnProperty(o, k)) != nil))
    }
    realm.defineMethod(oc, "is", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        .bool(realm.heap.sameValue(args[0], args[1]))
    }
    realm.defineMethod(oc, "isExtensible", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        if !args[0].isObject { return .false }
        return .bool(try realm.objIsExtensible(args[0]))
    }
    realm.defineMethod(oc, "preventExtensions", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        if args[0].isObject, !(try realm.objPreventExtensions(args[0])) { throw realm.throwTypeError("Cannot prevent extensions") }
        return args[0]
    }
    realm.defineMethod(oc, "freeze", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        if args[0].isObject { _ = try realm.jsSetIntegrity(args[0], frozen: true) }
        return args[0]
    }
    realm.defineMethod(oc, "seal", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        if args[0].isObject { _ = try realm.jsSetIntegrity(args[0], frozen: false) }
        return args[0]
    }
    realm.defineMethod(oc, "isFrozen", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        if !args[0].isObject { return .true }
        return .bool(try realm.jsTestIntegrity(args[0], frozen: true))
    }
    realm.defineMethod(oc, "isSealed", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        if !args[0].isObject { return .true }
        return .bool(try realm.jsTestIntegrity(args[0], frozen: false))
    }
    _ = tagKey
}
