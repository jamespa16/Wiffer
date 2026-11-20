// Proxy and Reflect (ROADMAP Phase 9E). The Proxy internal methods are
// called by the exotic dispatch in jsexotic.swift (kind .proxy, flag
// .exotic, slots [target, handler], both null once revoked). Every trap
// result is checked against the spec invariants (ES2024 10.5). The VM's
// call/construct dispatch sends callable proxies to proxyCall /
// proxyConstruct.
//
// Installed: Proxy(target, handler) (constructor only), Proxy.revocable,
// Reflect.{apply, construct, defineProperty, deleteProperty, get,
// getOwnPropertyDescriptor, getPrototypeOf, has, isExtensible, ownKeys,
// preventExtensions, set, setPrototypeOf}, Reflect[@@toStringTag].

enum JSProxyTrap: Int {
    case getPrototypeOf, setPrototypeOf, isExtensible, preventExtensions, getOwnPropertyDescriptor
    case defineProperty, has, get, set, deleteProperty, ownKeys, apply, construct
}

let jsProxyTrapNames = ["getPrototypeOf", "setPrototypeOf", "isExtensible", "preventExtensions",
                        "getOwnPropertyDescriptor", "defineProperty", "has", "get", "set", "deleteProperty",
                        "ownKeys", "apply", "construct"]

/// What a proxy operation works with: target and handler (rooted for the
/// duration of the operation) and the trap, if the handler has one.
struct JSProxyCall {
    var target: JSValue
    var handler: JSValue
    var trap: JSValue?
}

extension JSRealm {
    /// Roots target and handler (the caller pops to its depth), fetches
    /// the trap. TypeError when revoked.
    func proxyBegin(_ p: JSValue, _ t: JSProxyTrap) throws(JSThrow) -> JSProxyCall {
        let handler = heap.slot(p, 1)
        let target = heap.slot(p, 0)
        guard handler.isObject && target.isObject else {
            throw throwTypeError("Cannot perform '" + jsProxyTrapNames[t.rawValue] + "' on a proxy that has been revoked")
        }
        _ = heap.root(target)
        _ = heap.root(handler)
        let key = t.rawValue < tables.trapKeys.count ? tables.trapKeys[t.rawValue] : heap.key(jsProxyTrapNames[t.rawValue])
        let trap = try getMethodOrNil(handler, key)
        if let f = trap { _ = heap.root(f) }
        return JSProxyCall(target: target, handler: handler, trap: trap)
    }

    func proxyInvariant(_ trap: JSProxyTrap, _ why: String) -> JSThrow {
        throwTypeError("'" + jsProxyTrapNames[trap.rawValue] + "' on proxy: " + why)
    }

    func proxyGetPrototypeOf(_ p: JSValue) throws(JSThrow) -> JSValue {
        try enterExotic(); defer { leaveExotic() }
        let depth = heap.rootDepth
        defer { heap.popRoots(to: depth) }
        let c = try proxyBegin(p, .getPrototypeOf)
        guard let trap = c.trap else { return try objGetPrototypeOf(c.target) }
        let hp = try call(trap, this: c.handler, args: [c.target])
        guard hp.isObject || hp.isNull else { throw proxyInvariant(.getPrototypeOf, "trap returned neither object nor null") }
        _ = heap.root(hp)
        if try objIsExtensible(c.target) { return hp }
        let tp = try objGetPrototypeOf(c.target)
        if hp != tp { throw proxyInvariant(.getPrototypeOf, "proxy target is non-extensible but the trap did not return its actual prototype") }
        return hp
    }

    func proxySetPrototypeOf(_ p: JSValue, _ v: JSValue) throws(JSThrow) -> Bool {
        try enterExotic(); defer { leaveExotic() }
        let depth = heap.rootDepth
        defer { heap.popRoots(to: depth) }
        let c = try proxyBegin(p, .setPrototypeOf)
        guard let trap = c.trap else { return try objSetPrototypeOf(c.target, v) }
        if !heap.toBoolean(try call(trap, this: c.handler, args: [c.target, v])) { return false }
        if try objIsExtensible(c.target) { return true }
        let tp = try objGetPrototypeOf(c.target)
        if v != tp { throw proxyInvariant(.setPrototypeOf, "trap returned truish for setting a new prototype on the non-extensible proxy target") }
        return true
    }

    func proxyIsExtensible(_ p: JSValue) throws(JSThrow) -> Bool {
        try enterExotic(); defer { leaveExotic() }
        let depth = heap.rootDepth
        defer { heap.popRoots(to: depth) }
        let c = try proxyBegin(p, .isExtensible)
        guard let trap = c.trap else { return try objIsExtensible(c.target) }
        let b = heap.toBoolean(try call(trap, this: c.handler, args: [c.target]))
        if b != (try objIsExtensible(c.target)) { throw proxyInvariant(.isExtensible, "trap result does not reflect extensibility of proxy target") }
        return b
    }

    func proxyPreventExtensions(_ p: JSValue) throws(JSThrow) -> Bool {
        try enterExotic(); defer { leaveExotic() }
        let depth = heap.rootDepth
        defer { heap.popRoots(to: depth) }
        let c = try proxyBegin(p, .preventExtensions)
        guard let trap = c.trap else { return try objPreventExtensions(c.target) }
        let b = heap.toBoolean(try call(trap, this: c.handler, args: [c.target]))
        if b, try objIsExtensible(c.target) { throw proxyInvariant(.preventExtensions, "trap returned truish but the proxy target is extensible") }
        return b
    }

    func proxyGetOwnProperty(_ p: JSValue, _ k: JSPropertyKey) throws(JSThrow) -> JSProperty? {
        try enterExotic(); defer { leaveExotic() }
        let depth = heap.rootDepth
        defer { heap.popRoots(to: depth) }
        let c = try proxyBegin(p, .getOwnPropertyDescriptor)
        guard let trap = c.trap else { return try objGetOwnProperty(c.target, k) }
        let kv = heap.keyValue(k)
        _ = heap.root(kv)
        let res = try call(trap, this: c.handler, args: [c.target, kv])
        guard res.isObject || res.isUndefined else { throw proxyInvariant(.getOwnPropertyDescriptor, "trap returned neither object nor undefined") }
        _ = heap.root(res)
        let td = try objGetOwnProperty(c.target, k)
        if let t = td { _ = heap.root(t.value); _ = heap.root(t.getter); _ = heap.root(t.setter) }
        if res.isUndefined {
            guard let t = td else { return nil }
            if !t.configurable { throw proxyInvariant(.getOwnPropertyDescriptor, "trap returned undefined for property '" + keyDisplay(k) + "' which is non-configurable in the proxy target") }
            if !(try objIsExtensible(c.target)) { throw proxyInvariant(.getOwnPropertyDescriptor, "trap returned undefined for property '" + keyDisplay(k) + "' which exists in the non-extensible proxy target") }
            return nil
        }
        let ext = try objIsExtensible(c.target)
        let rd = try toPropertyDescriptorFull(res)
        let full = JSRealm.completeDescriptor(rd)
        if heap.validateAndApply(td, JSRealm.descriptor(full), extensible: ext) == nil {
            throw proxyInvariant(.getOwnPropertyDescriptor, "trap returned descriptor for property '" + keyDisplay(k) + "' that is incompatible with the existing property in the proxy target")
        }
        if !full.configurable {
            if td == nil || td!.configurable {
                throw proxyInvariant(.getOwnPropertyDescriptor, "trap reported non-configurability for property '" + keyDisplay(k) + "' which is either non-existent or configurable in the proxy target")
            }
            if rd.writable == false, let t = td, !t.isAccessor, t.writable {
                throw proxyInvariant(.getOwnPropertyDescriptor, "trap reported non-configurable and writable for property '" + keyDisplay(k) + "' which is non-configurable, non-writable in the proxy target")
            }
        }
        return full
    }

    func proxyDefineOwnProperty(_ p: JSValue, _ k: JSPropertyKey, _ d: JSPropertyDescriptor) throws(JSThrow) -> Bool {
        try enterExotic(); defer { leaveExotic() }
        let depth = heap.rootDepth
        defer { heap.popRoots(to: depth) }
        let c = try proxyBegin(p, .defineProperty)
        guard let trap = c.trap else { return try objDefineOwnProperty(c.target, k, d) }
        let kv = heap.keyValue(k)
        _ = heap.root(kv)
        let dobj = fromPropertyDescriptor(d)
        _ = heap.root(dobj)
        if !heap.toBoolean(try call(trap, this: c.handler, args: [c.target, kv, dobj])) { return false }
        let td = try objGetOwnProperty(c.target, k)
        let ext = try objIsExtensible(c.target)
        let settingConfigFalse = d.configurable == false
        guard let t = td else {
            if !ext { throw proxyInvariant(.defineProperty, "trap returned truish for adding property '" + keyDisplay(k) + "' to the non-extensible proxy target") }
            if settingConfigFalse { throw proxyInvariant(.defineProperty, "trap returned truish for defining non-configurable property '" + keyDisplay(k) + "' which is non-existent in the proxy target") }
            return true
        }
        if heap.validateAndApply(t, d, extensible: ext) == nil {
            throw proxyInvariant(.defineProperty, "trap returned truish for adding property '" + keyDisplay(k) + "' that is incompatible with the existing property in the proxy target")
        }
        if settingConfigFalse && t.configurable {
            throw proxyInvariant(.defineProperty, "trap returned truish for defining non-configurable property '" + keyDisplay(k) + "' which is configurable in the proxy target")
        }
        if !t.isAccessor && !t.configurable && t.writable && d.writable == false {
            throw proxyInvariant(.defineProperty, "trap returned truish for defining non-configurable property '" + keyDisplay(k) + "' which cannot be non-writable, unless there exists a corresponding non-configurable, non-writable own property of the target object")
        }
        return true
    }

    func proxyHas(_ p: JSValue, _ k: JSPropertyKey) throws(JSThrow) -> Bool {
        try enterExotic(); defer { leaveExotic() }
        let depth = heap.rootDepth
        defer { heap.popRoots(to: depth) }
        let c = try proxyBegin(p, .has)
        guard let trap = c.trap else { return try objHas(c.target, k) }
        let kv = heap.keyValue(k)
        _ = heap.root(kv)
        let b = heap.toBoolean(try call(trap, this: c.handler, args: [c.target, kv]))
        if !b, let t = try objGetOwnProperty(c.target, k) {
            if !t.configurable { throw proxyInvariant(.has, "trap returned falsish for property '" + keyDisplay(k) + "' which exists in the proxy target as non-configurable") }
            if !(try objIsExtensible(c.target)) { throw proxyInvariant(.has, "trap returned falsish for property '" + keyDisplay(k) + "' but the proxy target is not extensible") }
        }
        return b
    }

    func proxyGet(_ p: JSValue, _ k: JSPropertyKey, _ receiver: JSValue) throws(JSThrow) -> JSValue {
        try enterExotic(); defer { leaveExotic() }
        let depth = heap.rootDepth
        defer { heap.popRoots(to: depth) }
        let c = try proxyBegin(p, .get)
        guard let trap = c.trap else { return try objGet(c.target, k, receiver: receiver) }
        let kv = heap.keyValue(k)
        _ = heap.root(kv)
        let v = try call(trap, this: c.handler, args: [c.target, kv, receiver])
        _ = heap.root(v)
        if let t = try objGetOwnProperty(c.target, k), !t.configurable {
            if !t.isAccessor && !t.writable && !heap.sameValue(v, t.value) {
                throw proxyInvariant(.get, "property '" + keyDisplay(k) + "' is a read-only and non-configurable data property on the proxy target but the proxy did not return its actual value")
            }
            if t.isAccessor && t.getter.isUndefined && !v.isUndefined {
                throw proxyInvariant(.get, "property '" + keyDisplay(k) + "' is a non-configurable accessor property on the proxy target and does not have a getter function, but the trap did not return 'undefined'")
            }
        }
        return v
    }

    func proxySet(_ p: JSValue, _ k: JSPropertyKey, _ v: JSValue, _ receiver: JSValue) throws(JSThrow) -> Bool {
        try enterExotic(); defer { leaveExotic() }
        let depth = heap.rootDepth
        defer { heap.popRoots(to: depth) }
        let c = try proxyBegin(p, .set)
        guard let trap = c.trap else { return try objSet(c.target, k, v, receiver: receiver) }
        let kv = heap.keyValue(k)
        _ = heap.root(kv)
        if !heap.toBoolean(try call(trap, this: c.handler, args: [c.target, kv, v, receiver])) { return false }
        if let t = try objGetOwnProperty(c.target, k), !t.configurable {
            if !t.isAccessor && !t.writable && !heap.sameValue(v, t.value) {
                throw proxyInvariant(.set, "trap returned truish for property '" + keyDisplay(k) + "' which exists in the proxy target as a non-configurable and non-writable data property with a different value")
            }
            if t.isAccessor && t.setter.isUndefined {
                throw proxyInvariant(.set, "trap returned truish for property '" + keyDisplay(k) + "' which exists in the proxy target as a non-configurable and non-writable accessor property without a setter")
            }
        }
        return true
    }

    func proxyDelete(_ p: JSValue, _ k: JSPropertyKey) throws(JSThrow) -> Bool {
        try enterExotic(); defer { leaveExotic() }
        let depth = heap.rootDepth
        defer { heap.popRoots(to: depth) }
        let c = try proxyBegin(p, .deleteProperty)
        guard let trap = c.trap else { return try objDelete(c.target, k) }
        let kv = heap.keyValue(k)
        _ = heap.root(kv)
        if !heap.toBoolean(try call(trap, this: c.handler, args: [c.target, kv])) { return false }
        guard let t = try objGetOwnProperty(c.target, k) else { return true }
        if !t.configurable { throw proxyInvariant(.deleteProperty, "trap returned truish for property '" + keyDisplay(k) + "' which is non-configurable in the proxy target") }
        if !(try objIsExtensible(c.target)) { throw proxyInvariant(.deleteProperty, "trap returned truish for property '" + keyDisplay(k) + "' but the proxy target is non-extensible") }
        return true
    }

    func proxyOwnKeys(_ p: JSValue) throws(JSThrow) -> [JSPropertyKey] {
        try enterExotic(); defer { leaveExotic() }
        let depth = heap.rootDepth
        defer { heap.popRoots(to: depth) }
        let c = try proxyBegin(p, .ownKeys)
        guard let trap = c.trap else { return try objOwnKeys(c.target) }
        let arr = try call(trap, this: c.handler, args: [c.target])
        _ = heap.root(arr)
        let list = try listFromArrayLike(arr, keysOnly: true)
        var keys: [JSPropertyKey] = []
        var seen = Set<UInt64>()
        for v in list {
            guard let k = heap.propertyKey(v) else { continue }
            if !seen.insert(k.bits).inserted { throw proxyInvariant(.ownKeys, "trap returned duplicate entries") }
            keys.append(k)
        }
        // The keys' strings must survive until the caller uses them.
        let ext = try objIsExtensible(c.target)
        let tkeys = try objOwnKeys(c.target)
        var config: [JSPropertyKey] = [], nonconfig: [JSPropertyKey] = []
        for k in tkeys {
            if let d = try objGetOwnProperty(c.target, k), !d.configurable { nonconfig.append(k) } else { config.append(k) }
        }
        if ext && nonconfig.isEmpty { return jsKeepKeys(keys, depth) }
        var unchecked = seen
        for k in nonconfig {
            if unchecked.remove(k.bits) == nil {
                throw proxyInvariant(.ownKeys, "trap result did not include '" + keyDisplay(k) + "'")
            }
        }
        if ext { return jsKeepKeys(keys, depth) }
        for k in config {
            if unchecked.remove(k.bits) == nil {
                throw proxyInvariant(.ownKeys, "trap result did not include '" + keyDisplay(k) + "'")
            }
        }
        if !unchecked.isEmpty { throw proxyInvariant(.ownKeys, "trap returned extra keys but proxy target is non-extensible") }
        return jsKeepKeys(keys, depth)
    }

    /// Atom keys returned from a trap are interned strings nothing else
    /// may reference: the last 16 key lists stay rooted (tables.recentKeys,
    /// marked by the 9E root provider) so callers can use them like a
    /// heap.ownKeys result.
    func jsKeepKeys(_ k: [JSPropertyKey], _ depth: Int) -> [JSPropertyKey] {
        var vals: [JSValue] = []
        for x in k where x.isString || x.isSymbol { vals.append(heap.keyValue(x)) }
        if tables.recentKeys.count >= 16 { tables.recentKeys.removeFirst() }
        tables.recentKeys.append(vals)
        return k
    }

    /// [[Call]] of a callable proxy.
    func proxyCall(_ p: JSValue, this: JSValue, args: [JSValue]) throws(JSThrow) -> JSValue {
        try enterExotic(); defer { leaveExotic() }
        let depth = heap.rootDepth
        defer { heap.popRoots(to: depth) }
        for a in args { _ = heap.root(a) }
        _ = heap.root(this)
        let c = try proxyBegin(p, .apply)
        guard let trap = c.trap else { return try call(c.target, this: this, args: args) }
        let arr = heap.newArray(proto: arrayPrototype, elements: args)
        _ = heap.root(arr)
        return try call(trap, this: c.handler, args: [c.target, this, arr])
    }

    /// [[Construct]] of a constructor proxy.
    func proxyConstruct(_ p: JSValue, args: [JSValue], newTarget: JSValue) throws(JSThrow) -> JSValue {
        try enterExotic(); defer { leaveExotic() }
        let depth = heap.rootDepth
        defer { heap.popRoots(to: depth) }
        for a in args { _ = heap.root(a) }
        _ = heap.root(newTarget)
        let c = try proxyBegin(p, .construct)
        guard let trap = c.trap else { return try construct(c.target, args: args, newTarget: newTarget) }
        let arr = heap.newArray(proto: arrayPrototype, elements: args)
        _ = heap.root(arr)
        let o = try call(trap, this: c.handler, args: [c.target, arr, newTarget])
        guard o.isObject else { throw proxyInvariant(.construct, "trap returned non-object") }
        return o
    }

    /// ProxyCreate.
    public func proxyCreate(_ target: JSValue, _ handler: JSValue) throws(JSThrow) -> JSValue {
        guard target.isObject && handler.isObject else {
            throw throwTypeError("Cannot create proxy with a non-object as target or handler")
        }
        var flags: JSObjectFlags = [.exotic, .extensible]
        if heap.isCallable(target) { flags.insert(.callable) }
        if heap.flags(target).contains(.constructor) { flags.insert(.constructor) }
        let depth = heap.rootDepth
        defer { heap.popRoots(to: depth) }
        _ = heap.root(target)
        _ = heap.root(handler)
        let p = heap.newObject(proto: .null, kind: .proxy, flags: flags)
        heap.setSlots(p, [target, handler])
        return p
    }

    /// The VM's call dispatch for a proxy at stack [p this args...]: runs
    /// it and leaves the result (or nothing for discard mode).
    func dispatchProxyCall(_ argc: Int, mode: UInt8) throws(JSThrow) {
        let base = sp - argc - 2
        let p = stack[base], thisV = stack[base + 1]
        var args: [JSValue] = []
        args.reserveCapacity(argc)
        for i in 0..<argc { args.append(stack[base + 2 + i]) }
        let r = try proxyCall(p, this: thisV, args: args)
        sp = base
        if mode != JSFrameMode.discard { push(r) }
    }

    /// The VM's construct dispatch for a proxy at [p newTarget args...].
    func dispatchProxyConstruct(_ argc: Int) throws(JSThrow) {
        let base = sp - argc - 2
        let p = stack[base], nt = stack[base + 1]
        var args: [JSValue] = []
        args.reserveCapacity(argc)
        for i in 0..<argc { args.append(stack[base + 2 + i]) }
        let r = try proxyConstruct(p, args: args, newTarget: nt)
        sp = base
        push(r)
    }
}

func jsInstallProxyReflect(_ realm: JSRealm) {
    let heap = realm.heap
    var tk: [JSPropertyKey] = []
    for n in jsProxyTrapNames { tk.append(.atom(heap.pinAtom(heap.newString(n)).handle)) }
    realm.tables.trapKeys = tk

    // ------------------------------------------------------------- Proxy
    let proxyCtor = realm.newNativeFunction(realm.registerNative("Proxy", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        if !args.isConstruct { throw realm.throwTypeError("Constructor Proxy requires 'new'") }
        return try realm.proxyCreate(args[0], args[1])
    }, constructor: true)
    realm.defineGlobal("Proxy", proxyCtor)
    realm.defineMethod(proxyCtor, "revocable", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let depth = h.rootDepth
        defer { h.popRoots(to: depth) }
        let p = try realm.proxyCreate(args[0], args[1])
        _ = h.root(p)
        let revoke = realm.newNativeFunction(jsProxyRevokeNative(realm), name: "")
        _ = h.root(revoke)
        h.setSlots(revoke, [p])
        let o = h.newObject(proto: realm.objectPrototype)
        _ = h.root(o)
        _ = h.createDataProperty(o, h.key("proxy"), p)
        _ = h.createDataProperty(o, h.key("revoke"), revoke)
        return o
    }

    // ----------------------------------------------------------- Reflect
    let reflect = heap.newObject(proto: realm.objectPrototype)
    let rr = heap.root(reflect)
    realm.defineGlobal("Reflect", reflect)
    _ = heap.defineOwnProperty(reflect, .symbol(heap.symbolsWellKnown.toStringTag.handle), .data(realm.string("Reflect"), [.configurable]))
    func target(_ realm: JSRealm, _ v: JSValue, _ fn: String) throws(JSThrow) -> JSValue {
        guard v.isObject else { throw realm.throwTypeError("Reflect." + fn + " called on non-object") }
        return v
    }
    realm.defineMethod(reflect, "apply", length: 3) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        guard realm.heap.isCallable(args[0]) else { throw realm.throwTypeError("Reflect.apply target is not a function") }
        let list = try realm.listFromArrayLike(args[2])
        let depth = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: depth) }
        for v in list { _ = realm.heap.root(v) }
        return try realm.call(args[0], this: args[1], args: list)
    }
    realm.defineMethod(reflect, "construct", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        guard realm.isConstructor(args[0]) else { throw realm.throwTypeError("Reflect.construct target is not a constructor") }
        let nt = args.count > 2 ? args[2] : args[0]
        guard realm.isConstructor(nt) else { throw realm.throwTypeError("Reflect.construct newTarget is not a constructor") }
        let list = try realm.listFromArrayLike(args[1])
        let depth = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: depth) }
        for v in list { _ = realm.heap.root(v) }
        return try realm.construct(args[0], args: list, newTarget: nt)
    }
    realm.defineMethod(reflect, "defineProperty", length: 3) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let o = try target(realm, args[0], "defineProperty")
        let k = try realm.toPropertyKey(args[1])
        let d = try realm.toPropertyDescriptorFull(args[2])
        let depth = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: depth) }
        if let v = d.value { _ = realm.heap.root(v) }
        return .bool(try realm.objDefineOwnProperty(o, k, d))
    }
    realm.defineMethod(reflect, "deleteProperty", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let o = try target(realm, args[0], "deleteProperty")
        return .bool(try realm.objDelete(o, try realm.toPropertyKey(args[1])))
    }
    realm.defineMethod(reflect, "get", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let o = try target(realm, args[0], "get")
        let k = try realm.toPropertyKey(args[1])
        return try realm.objGet(o, k, receiver: args.count > 2 ? args[2] : o)
    }
    realm.defineMethod(reflect, "getOwnPropertyDescriptor", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let o = try target(realm, args[0], "getOwnPropertyDescriptor")
        guard let p = try realm.objGetOwnProperty(o, try realm.toPropertyKey(args[1])) else { return .undefined }
        return realm.fromProperty(p)
    }
    realm.defineMethod(reflect, "getPrototypeOf", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        try realm.objGetPrototypeOf(try target(realm, args[0], "getPrototypeOf"))
    }
    realm.defineMethod(reflect, "has", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let o = try target(realm, args[0], "has")
        return .bool(try realm.objHas(o, try realm.toPropertyKey(args[1])))
    }
    realm.defineMethod(reflect, "isExtensible", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        .bool(try realm.objIsExtensible(try target(realm, args[0], "isExtensible")))
    }
    realm.defineMethod(reflect, "ownKeys", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let o = try target(realm, args[0], "ownKeys")
        let keys = try realm.objOwnKeys(o)
        let h = realm.heap
        let depth = h.rootDepth
        defer { h.popRoots(to: depth) }
        var vals: [JSValue] = []
        vals.reserveCapacity(keys.count)
        for k in keys { let v = h.keyValue(k); _ = h.root(v); vals.append(v) }
        return h.newArray(proto: realm.arrayPrototype, elements: vals)
    }
    realm.defineMethod(reflect, "preventExtensions", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        .bool(try realm.objPreventExtensions(try target(realm, args[0], "preventExtensions")))
    }
    realm.defineMethod(reflect, "set", length: 3) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let o = try target(realm, args[0], "set")
        let k = try realm.toPropertyKey(args[1])
        return .bool(try realm.objSet(o, k, args[2], receiver: args.count > 3 ? args[3] : o))
    }
    realm.defineMethod(reflect, "setPrototypeOf", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let o = try target(realm, args[0], "setPrototypeOf")
        let p = args[1]
        guard p.isObject || p.isNull else { throw realm.throwTypeError("Object prototype may only be an Object or null") }
        return .bool(try realm.objSetPrototypeOf(o, p))
    }
    heap.popRoots(to: rr.slot)
}

/// The shared native behind every revoke function (the proxy is in the
/// function object's slot 0).
func jsProxyRevokeNative(_ realm: JSRealm) -> Int {
    if realm.tables.revokeNative >= 0 { return realm.tables.revokeNative }
    let idx = realm.registerNative("", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let p = realm.heap.slot(args.callee, 0)
        if realm.heap.kind(p) == .proxy {
            realm.heap.setSlot(p, 0, .null)
            realm.heap.setSlot(p, 1, .null)
        }
        realm.heap.setSlot(args.callee, 0, .null)
        return .undefined
    }
    realm.tables.revokeNative = idx
    return idx
}
