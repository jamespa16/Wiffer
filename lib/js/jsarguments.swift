// Mapped (aliased) arguments objects (ECMAScript 10.4.4, sloppy functions
// with simple parameter lists), built on the exotic-object hook
// (jsexotic.swift).
//
// How it works. The scope analysis (JSScopeAnalysis.markMappedParams) puts
// every parameter of such a function into its heap environment, so a
// parameter has a stable home (an env slot) that outlives the frame. The
// compiler emits `mapArg paramIndex envSlot` after the prologue; the VM calls
// `realm.mapArgument`. The arguments object (kind .arguments) keeps
//     slot 0        the function's environment
//     slot 1 + i    int32 env slot while argument i is mapped, else -1
// and gets the exotic flag with the realm's arguments handler: reading a
// mapped index reads the environment, writing (an ordinary [[Set]] ends in
// [[DefineOwnProperty]]) writes it, and defineProperty with an accessor or
// writable:false, and delete, unmap it, exactly as the spec's [[ParameterMap]].
// Unmapped arguments objects (strict code, complex parameters) are plain
// ordinary objects and never take this path.

extension JSRealm {
    /// The environment slot index mapped to key `k` of arguments object `o`, or nil.
    func argumentsMappedSlot(_ o: JSValue, _ k: JSPropertyKey) -> Int? {
        guard k.isIndex else { return nil }
        let i = Int(k.index)
        let n = heap.slotCount(o)
        guard i + 1 < n else { return nil }
        let s = heap.slot(o, 1 + i)
        guard s.isInt32, s.asInt32 >= 0 else { return nil }
        return Int(s.asInt32)
    }

    func argumentsMappedValue(_ o: JSValue, _ s: Int) -> JSValue {
        heap.slot(heap.slot(o, 0), s)
    }

    func argumentsUnmap(_ o: JSValue, _ k: JSPropertyKey) {
        if k.isIndex { heap.setSlot(o, 1 + Int(k.index), .int32(-1)) }
    }

    /// VM: `mapArg i slot` (the arguments object is the top of the stack).
    func mapArgument(_ args: JSValue, index i: Int, envSlot: Int) {
        guard args.isObject, i >= 0, i + 1 < heap.slotCount(args) else { return }
        heap.setSlot(args, 0, env)
        heap.setSlot(args, 1 + i, .int32(Int32(truncatingIfNeeded: envSlot)))
        if tables.argumentsHandler < 0 { tables.argumentsHandler = registerExoticHandler(makeArgumentsHandler()) }
        if !heap.flags(args).contains(.exotic) { makeExotic(args, handler: tables.argumentsHandler) }
    }

    func makeArgumentsHandler() -> JSExoticHandler {
        var h = JSExoticHandler()
        h.getOwnProperty = { (realm: JSRealm, o: JSValue, k: JSPropertyKey) throws(JSThrow) -> JSProperty? in
            guard var p = realm.heap.getOwnProperty(o, k) else { return nil }
            if let s = realm.argumentsMappedSlot(o, k), !p.isAccessor { p.value = realm.argumentsMappedValue(o, s) }
            return p
        }
        h.get = { (realm: JSRealm, o: JSValue, k: JSPropertyKey, receiver: JSValue) throws(JSThrow) -> JSValue? in
            if let s = realm.argumentsMappedSlot(o, k) { return realm.argumentsMappedValue(o, s) }
            return nil
        }
        h.defineOwnProperty = { (realm: JSRealm, o: JSValue, k: JSPropertyKey, d: JSPropertyDescriptor) throws(JSThrow) -> Bool? in
            guard let s = realm.argumentsMappedSlot(o, k) else { return nil }
            var nd = d
            if d.isDataDescriptor && d.value == nil && d.writable == false {
                nd.value = realm.argumentsMappedValue(o, s)
            }
            if !realm.heap.defineOwnProperty(o, k, nd) { return false }
            if d.isAccessorDescriptor {
                realm.argumentsUnmap(o, k)
            } else {
                if let v = d.value { realm.heap.setSlot(realm.heap.slot(o, 0), s, v) }
                if d.writable == false { realm.argumentsUnmap(o, k) }
            }
            return true
        }
        h.deleteProperty = { (realm: JSRealm, o: JSValue, k: JSPropertyKey) throws(JSThrow) -> Bool? in
            let mapped = realm.argumentsMappedSlot(o, k) != nil
            let r = realm.heap.deleteProperty(o, k)
            if r && mapped { realm.argumentsUnmap(o, k) }
            return r
        }
        return h
    }
}
