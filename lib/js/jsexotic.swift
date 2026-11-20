// Exotic objects: the realm-level internal methods and the exotic-object
// hook (ROADMAP Phase 9E). This is the contract Proxy (9E) and host objects
// (9F: NodeList indexed getters, document.forms named properties, ...) use.
//
// ===================================================== the internal methods
//
// Every object has the spec's essential internal methods. JSRealm exposes
// them in throwing form; they run Proxy traps and host hooks and are the
// ONLY correct way for native code to operate on an object it did not make
// itself (built-ins taking user objects: Object.keys, JSON.stringify, ...):
//
//   objGetPrototypeOf(o) -> JSValue          [[GetPrototypeOf]]
//   objSetPrototypeOf(o, p) -> Bool          [[SetPrototypeOf]]
//   objIsExtensible(o) -> Bool               [[IsExtensible]]
//   objPreventExtensions(o) -> Bool          [[PreventExtensions]]
//   objGetOwnProperty(o, k) -> JSProperty?   [[GetOwnProperty]]
//   objDefineOwnProperty(o, k, d) -> Bool    [[DefineOwnProperty]]
//   objHas(o, k) -> Bool                     [[HasProperty]]
//   objGet(o, k, receiver:) -> JSValue       [[Get]] (getters called)
//   objSet(o, k, v, receiver:) -> Bool       [[Set]] (setters called)
//   objDelete(o, k) -> Bool                  [[Delete]]
//   objOwnKeys(o) -> [JSPropertyKey]         [[OwnPropertyKeys]]
//   (all `throws(JSThrow)`; o must be an object; arguments are the
//   caller's to root, results are unrooted)
//   Helpers: objDefinePropertyOrThrow, objCreateDataPropertyOrThrow,
//   objDeletePropertyOrThrow, objSetOrThrow(strict), fromPropertyDescriptor
//   (descriptor -> object), completeDescriptor, isArray(v) (sees through
//   proxies), isConstructor(v).
//
// For ordinary objects (and arrays, String wrappers, typed arrays, whose
// exotic rules need no JS and live in the heap, see jsobject.swift) these
// cost one flag test on top of the JSHeap method. The VM's property
// instructions use the heap fast paths and fall into these when the heap
// answers `.exotic(obj)` (JSGetResult / JSSetResult).
//
// ======================================================= the exotic hook
//
// An object is exotic when it has flag JSObjectFlags.exotic. Dispatch is a
// switch on its kind (no existentials):
//   kind .proxy     the Proxy internal methods (jsbuiltins_proxy.swift);
//                   slots [target, handler], both null once revoked.
//   any other kind  a host handler: a JSExoticHandler registered with
//                   realm.registerExoticHandler(h) -> id and attached with
//                   realm.makeExotic(o, handler: id) (sets the flag; the id
//                   lives in the cell, not in slots or internalInt, so a
//                   host object keeps those for itself).
//
// JSExoticHandler: every field is optional; nil, or a hook returning nil,
// means "do the ordinary thing" (the object's own ordinary storage, its
// prototype). That makes WebIDL legacy platform objects short:
//   getOwnProperty(realm, o, k) -> JSProperty?   supported index/name ->
//       the property; nil -> ordinary own property lookup
//   defineOwnProperty(realm, o, k, desc) -> Bool?
//   deleteProperty(realm, o, k) -> Bool?
//   ownKeys(realm, o) -> [JSPropertyKey]         keys reported BEFORE the
//       ordinary own keys (duplicates dropped): supported indices, names
//   has(realm, o, k) -> Bool?                    optional fast path; else
//       getOwnProperty, then the prototype chain
//   get(realm, o, k, receiver) -> JSValue?       optional fast path; else
//       getOwnProperty (getters are called), then the prototype chain
//   set(realm, o, k, v, receiver) -> Bool?       optional; else OrdinarySet
//       on top of getOwnProperty / defineOwnProperty
//   setPrototypeOf(realm, o, p) -> Bool?         (immutable-prototype objects)
//   preventExtensions(realm, o) -> Bool?
// Hooks may allocate and run JS (they `throws(JSThrow)`); the object being
// operated on is rooted by the caller. Heap-level methods (heap.getOwnProperty
// ...) do NOT see hooks: for host exotics they act on the ordinary storage.
//
// Depth: proxies forwarding to proxies recurse in Swift; the nesting is
// capped (tables.exoticDepth, 2000, plus the VM's stack floor), a RangeError.

public typealias JSExoticGetOwn = (_ realm: JSRealm, _ o: JSValue, _ k: JSPropertyKey) throws(JSThrow) -> JSProperty?
public typealias JSExoticDefine = (_ realm: JSRealm, _ o: JSValue, _ k: JSPropertyKey, _ d: JSPropertyDescriptor) throws(JSThrow) -> Bool?
public typealias JSExoticKeyOp = (_ realm: JSRealm, _ o: JSValue, _ k: JSPropertyKey) throws(JSThrow) -> Bool?
public typealias JSExoticOwnKeys = (_ realm: JSRealm, _ o: JSValue) throws(JSThrow) -> [JSPropertyKey]
public typealias JSExoticGet = (_ realm: JSRealm, _ o: JSValue, _ k: JSPropertyKey, _ receiver: JSValue) throws(JSThrow) -> JSValue?
public typealias JSExoticSet = (_ realm: JSRealm, _ o: JSValue, _ k: JSPropertyKey, _ v: JSValue, _ receiver: JSValue) throws(JSThrow) -> Bool?
public typealias JSExoticSetProto = (_ realm: JSRealm, _ o: JSValue, _ p: JSValue) throws(JSThrow) -> Bool?
public typealias JSExoticObjOp = (_ realm: JSRealm, _ o: JSValue) throws(JSThrow) -> Bool?

public struct JSExoticHandler {
    public var getOwnProperty: JSExoticGetOwn? = nil
    public var defineOwnProperty: JSExoticDefine? = nil
    public var deleteProperty: JSExoticKeyOp? = nil
    public var ownKeys: JSExoticOwnKeys? = nil
    public var has: JSExoticKeyOp? = nil
    public var get: JSExoticGet? = nil
    public var set: JSExoticSet? = nil
    public var setPrototypeOf: JSExoticSetProto? = nil
    public var preventExtensions: JSExoticObjOp? = nil
    public init() {}
}

/// Per-realm state for Phase 9E (one stored property on JSRealm).
public final class JSRealmTables {
    var exoticHandlers: [JSExoticHandler] = []
    var exoticDepth = 0
    /// Handler id of mapped arguments objects (jsarguments.swift), -1 until used.
    var argumentsHandler = -1
    /// Proxy trap names (pinned atoms), in JSProxyTrap order.
    var trapKeys: [JSPropertyKey] = []
    // Map / Set hash indexes (jsbuiltins_collections.swift).
    var mapIndexes: [JSMapIndex?] = []
    var mapIndexFree: [Int] = []
    // WeakMap / WeakSet / WeakRef / FinalizationRegistry (jsbuiltins_weak.swift).
    var weakTables: [JSWeakTable?] = []
    var weakTableFree: [Int] = []
    var weakRefs: [JSWeakRefCell?] = []
    var weakRefFree: [Int] = []
    var registries: [JSFinRegistry?] = []
    var registryFree: [Int] = []
    var keptAlive: [JSValue] = []
    var keptSet = Set<UInt64>()
    var weakCycle = -1
    var gcHooksInstalled = false
    var revokeNative = -1
    var recentKeys: [[JSValue]] = []
    /// Called from inside a GC (must not touch the heap) when a
    /// FinalizationRegistry has cleanup work: the embedder schedules a task
    /// that calls realm.runFinalizationCleanups().
    public var onFinalizationCleanupNeeded: (() -> Void)? = nil
    init() {}
}

extension JSHeap {
    /// The exotic handler id of a non-array object (kept in the cell's
    /// otherwise unused arrayLength field).
    func exoticHandlerID(_ o: JSValue) -> Int {
        guard let i = objectIndex(o), objects[i].kind != .array else { return -1 }
        return Int(objects[i].arrayLength) - 1
    }
    func setExoticHandlerID(_ o: JSValue, _ id: Int) {
        guard let i = objectIndex(o), objects[i].kind != .array, id >= 0, id < Int(UInt32.max) else { return }
        objects[i].arrayLength = UInt32(id + 1)
        objects[i].flags.insert(.exotic)
    }

    /// Heap-level view of a Proxy (no traps): run body on the final
    /// non-proxy target; nil when revoked.
    @inline(__always) func proxyFallback<R>(_ o: JSValue, _ body: (JSValue) -> R) -> R? {
        var t = o
        var n = 0
        while kind(t) == .proxy {
            t = slot(t, 0)
            n += 1
            if n > 100_000 { return nil }
        }
        guard t.isObject && t.handle != 0 else { return nil }
        return body(t)
    }
}

extension JSRealm {
    // MARK: Registration

    public func registerExoticHandler(_ h: JSExoticHandler) -> Int {
        tables.exoticHandlers.append(h)
        return tables.exoticHandlers.count - 1
    }

    /// Make o (a host object, not an array or proxy) dispatch through
    /// handler `id`.
    public func makeExotic(_ o: JSValue, handler id: Int) {
        guard id >= 0 && id < tables.exoticHandlers.count else { return }
        let k = heap.kind(o)
        guard k != .array && k != .proxy && k != .typedArray && k != .stringWrapper else { return }
        heap.setExoticHandlerID(o, id)
    }

    @inline(__always) func isExotic(_ o: JSValue) -> Bool { heap.flags(o).contains(.exotic) }

    func hostHandler(_ o: JSValue) -> JSExoticHandler? {
        let id = heap.exoticHandlerID(o)
        return id >= 0 && id < tables.exoticHandlers.count ? tables.exoticHandlers[id] : nil
    }

    /// Guards Swift recursion through exotic objects (proxy -> proxy ...).
    func enterExotic() throws(JSThrow) {
        if heap.termination != nil { throw JSThrow() }
        if tables.exoticDepth >= 2000 || (stackFloor != 0 && jsStackAddress() < stackFloor) {
            throw throwRangeError("Maximum call stack size exceeded")
        }
        tables.exoticDepth += 1
    }
    @inline(__always) func leaveExotic() { tables.exoticDepth -= 1 }

    // MARK: [[GetPrototypeOf]] [[SetPrototypeOf]] [[IsExtensible]] [[PreventExtensions]]

    public func objGetPrototypeOf(_ o: JSValue) throws(JSThrow) -> JSValue {
        if isExotic(o) && heap.kind(o) == .proxy { return try proxyGetPrototypeOf(o) }
        return heap.getPrototypeOf(o)
    }

    public func objSetPrototypeOf(_ o: JSValue, _ p: JSValue) throws(JSThrow) -> Bool {
        if isExotic(o) {
            if heap.kind(o) == .proxy { return try proxySetPrototypeOf(o, p) }
            if let h = hostHandler(o)?.setPrototypeOf, let r = try h(self, o, p) { return r }
        }
        return heap.setPrototypeOf(o, p)
    }

    public func objIsExtensible(_ o: JSValue) throws(JSThrow) -> Bool {
        if isExotic(o) && heap.kind(o) == .proxy { return try proxyIsExtensible(o) }
        return heap.isExtensible(o)
    }

    public func objPreventExtensions(_ o: JSValue) throws(JSThrow) -> Bool {
        if isExotic(o) {
            if heap.kind(o) == .proxy { return try proxyPreventExtensions(o) }
            if let h = hostHandler(o)?.preventExtensions, let r = try h(self, o) { return r }
        }
        if heap.kind(o) == .typedArray && heap.typedArrayIsLengthTracking(o) {
            // Resizable-buffer views can't be frozen in place.
            if !heap.isExtensible(o) { return true }
            return false
        }
        return heap.preventExtensions(o)
    }

    // MARK: [[GetOwnProperty]] [[DefineOwnProperty]]

    public func objGetOwnProperty(_ o: JSValue, _ k: JSPropertyKey) throws(JSThrow) -> JSProperty? {
        if isExotic(o) {
            if heap.kind(o) == .proxy { return try proxyGetOwnProperty(o, k) }
            if let h = hostHandler(o)?.getOwnProperty, let p = try h(self, o, k) { return p }
        }
        return heap.getOwnProperty(o, k)
    }

    public func objDefineOwnProperty(_ o: JSValue, _ k: JSPropertyKey, _ d: JSPropertyDescriptor) throws(JSThrow) -> Bool {
        if isExotic(o) {
            if heap.kind(o) == .proxy { return try proxyDefineOwnProperty(o, k, d) }
            if let h = hostHandler(o)?.defineOwnProperty, let r = try h(self, o, k, d) { return r }
        }
        if heap.kind(o) == .typedArray, let x = heap.typedArrayNumericIndex(k), let v = d.value, heap.toPrimitiveNumber(v) == nil {
            // TypedArray [[DefineOwnProperty]] with a value that needs ToNumber.
            guard let i = heap.objectIndex(o), heap.typedArrayValidIndex(i, x) else { return false }
            if d.configurable == false || d.enumerable == false || d.isAccessorDescriptor || d.writable == false { return false }
            let r = heap.root(o)
            defer { heap.popRoots(to: r.slot) }
            try typedArraySetElementJS(o, x, v)
            return true
        }
        return heap.defineOwnProperty(o, k, d)
    }

    // MARK: [[HasProperty]]

    public func objHas(_ o: JSValue, _ k: JSPropertyKey) throws(JSThrow) -> Bool {
        var cur = o
        var steps = 0
        let r = heap.root(o)
        defer { heap.popRoots(to: r.slot) }
        while cur.isObject {
            if isExotic(cur) {
                if heap.kind(cur) == .proxy { return try proxyHas(cur, k) }
                let h = hostHandler(cur)
                if let f = h?.has, let b = try f(self, cur, k) { return b }
                if try objGetOwnProperty(cur, k) != nil { return true }
            } else {
                guard let i = heap.objectIndex(cur) else { return false }
                if heap.objects[i].kind == .typedArray, let x = heap.typedArrayNumericIndex(k) {
                    return heap.typedArrayValidIndex(i, x)
                }
                if heap.hasOwnProperty(cur, k) { return true }
            }
            cur = heap.getPrototypeOf(cur)
            heap[r] = cur
            steps += 1
            if steps > JSHeap.maxProtoChain { break }
        }
        return false
    }

    // MARK: [[Get]]

    public func objGet(_ o: JSValue, _ k: JSPropertyKey, receiver: JSValue) throws(JSThrow) -> JSValue {
        var cur = o
        var steps = 0
        let r = heap.root(o)
        defer { heap.popRoots(to: r.slot) }
        while true {
            switch heap.getProperty(cur, k) {
            case .value(let v): return v
            case .getter(let g): return try call(g, this: receiver, args: [])
            case .exotic(let e):
                if heap.kind(e) == .proxy { return try proxyGet(e, k, receiver) }
                if let f = hostHandler(e)?.get, let v = try f(self, e, k, receiver) { return v }
                if let p = try objGetOwnProperty(e, k) {
                    if p.isAccessor { return p.getter.isUndefined ? .undefined : try call(p.getter, this: receiver, args: []) }
                    return p.value
                }
                cur = heap.getPrototypeOf(e)
                heap[r] = cur
                if !cur.isObject { return .undefined }
            }
            steps += 1
            if steps > JSHeap.maxProtoChain { return .undefined }
        }
    }

    // MARK: [[Set]]

    public func objSet(_ o: JSValue, _ k: JSPropertyKey, _ v: JSValue, receiver: JSValue) throws(JSThrow) -> Bool {
        switch heap.setProperty(o, k, v, receiver: receiver) {
        case .done: return true
        case .failed: return false
        case .setter(let s):
            _ = try call(s, this: receiver, args: [v])
            return true
        case .exotic(let e): return try objSetSlow(e, k, v, receiver: receiver)
        }
    }

    /// OrdinarySet through the dispatched internal methods, from o (after
    /// heap.setProperty answered .exotic(o)).
    func objSetSlow(_ o: JSValue, _ k: JSPropertyKey, _ v: JSValue, receiver: JSValue) throws(JSThrow) -> Bool {
        let depth = heap.rootDepth
        defer { heap.popRoots(to: depth) }
        let rc = heap.root(o)
        _ = heap.root(v)
        _ = heap.root(receiver)
        var cur = o
        var own: JSProperty? = nil
        var steps = 0
        while true {
            if isExotic(cur) {
                if heap.kind(cur) == .proxy { return try proxySet(cur, k, v, receiver) }
                if let f = hostHandler(cur)?.set, let b = try f(self, cur, k, v, receiver) { return b }
            } else if heap.kind(cur) == .typedArray, let x = heap.typedArrayNumericIndex(k) {
                if cur == receiver {
                    try typedArraySetElementJS(cur, x, v)
                    return true
                }
                guard let i = heap.objectIndex(cur), heap.typedArrayValidIndex(i, x) else { return true }
                own = .data(.undefined)
                break
            }
            if let p = try objGetOwnProperty(cur, k) { own = p; break }
            let parent = try objGetPrototypeOf(cur)
            if !parent.isObject { break }
            cur = parent
            heap[rc] = cur
            steps += 1
            if steps > JSHeap.maxProtoChain { break }
        }
        let desc = own ?? .data(.undefined)
        if desc.isAccessor {
            if desc.setter.isUndefined { return false }
            _ = try call(desc.setter, this: receiver, args: [v])
            return true
        }
        if !desc.writable { return false }
        guard receiver.isObject else { return false }
        if let ex = try objGetOwnProperty(receiver, k) {
            if ex.isAccessor || !ex.writable { return false }
            return try objDefineOwnProperty(receiver, k, JSPropertyDescriptor(value: v))
        }
        return try objDefineOwnProperty(receiver, k, .data(v))
    }

    // MARK: [[Delete]] [[OwnPropertyKeys]]

    public func objDelete(_ o: JSValue, _ k: JSPropertyKey) throws(JSThrow) -> Bool {
        if isExotic(o) {
            if heap.kind(o) == .proxy { return try proxyDelete(o, k) }
            if let h = hostHandler(o)?.deleteProperty, let r = try h(self, o, k) { return r }
        }
        return heap.deleteProperty(o, k)
    }

    public func objOwnKeys(_ o: JSValue) throws(JSThrow) -> [JSPropertyKey] {
        if isExotic(o) {
            if heap.kind(o) == .proxy { return try proxyOwnKeys(o) }
            if let h = hostHandler(o)?.ownKeys {
                var out = try h(self, o)
                var seen = Set<UInt64>()
                for k in out { seen.insert(k.bits) }
                for k in heap.ownKeys(o) where !seen.contains(k.bits) { out.append(k) }
                return out
            }
        }
        return heap.ownKeys(o)
    }

    // MARK: Helpers

    public func objDefinePropertyOrThrow(_ o: JSValue, _ k: JSPropertyKey, _ d: JSPropertyDescriptor) throws(JSThrow) {
        if !(try objDefineOwnProperty(o, k, d)) { throw throwTypeError("Cannot redefine property: " + keyDisplay(k)) }
    }
    public func objCreateDataPropertyOrThrow(_ o: JSValue, _ k: JSPropertyKey, _ v: JSValue) throws(JSThrow) {
        if !(try objDefineOwnProperty(o, k, .data(v))) {
            if heap.termination != nil { throw JSThrow() }
            throw throwTypeError("Cannot define property " + keyDisplay(k))
        }
    }
    public func objDeletePropertyOrThrow(_ o: JSValue, _ k: JSPropertyKey) throws(JSThrow) {
        if !(try objDelete(o, k)) { throw throwTypeError("Cannot delete property '" + keyDisplay(k) + "'") }
    }
    public func objSetOrThrow(_ o: JSValue, _ k: JSPropertyKey, _ v: JSValue, strict: Bool = true) throws(JSThrow) {
        if !(try objSet(o, k, v, receiver: o)) && strict {
            if heap.termination != nil { throw JSThrow() }
            throw throwTypeError("Cannot assign to read only property '" + keyDisplay(k) + "'")
        }
    }

    /// FromPropertyDescriptor (only the fields present).
    public func fromPropertyDescriptor(_ d: JSPropertyDescriptor) -> JSValue {
        let depth = heap.rootDepth
        defer { heap.popRoots(to: depth) }
        if let v = d.value { _ = heap.root(v) }
        if let g = d.getter { _ = heap.root(g) }
        if let s = d.setter { _ = heap.root(s) }
        let o = heap.newObject(proto: objectPrototype)
        let n = heap.names
        if let v = d.value { _ = heap.createDataProperty(o, n.value, v) }
        if let w = d.writable { _ = heap.createDataProperty(o, n.writable, .bool(w)) }
        if let g = d.getter { _ = heap.createDataProperty(o, n.get, g) }
        if let s = d.setter { _ = heap.createDataProperty(o, n.set, s) }
        if let e = d.enumerable { _ = heap.createDataProperty(o, n.enumerable, .bool(e)) }
        if let c = d.configurable { _ = heap.createDataProperty(o, n.configurable, .bool(c)) }
        return o
    }

    public func fromProperty(_ p: JSProperty) -> JSValue { fromPropertyDescriptor(JSRealm.descriptor(p)) }

    static func descriptor(_ p: JSProperty) -> JSPropertyDescriptor {
        if p.isAccessor {
            return JSPropertyDescriptor(getter: p.getter, setter: p.setter, enumerable: p.enumerable, configurable: p.configurable)
        }
        return JSPropertyDescriptor(value: p.value, writable: p.writable, enumerable: p.enumerable, configurable: p.configurable)
    }

    /// CompletePropertyDescriptor.
    public static func completeDescriptor(_ d: JSPropertyDescriptor) -> JSProperty {
        var a: JSPropertyAttributes = []
        if d.enumerable == true { a.insert(.enumerable) }
        if d.configurable == true { a.insert(.configurable) }
        if d.isAccessorDescriptor { return .accessor(get: d.getter ?? .undefined, set: d.setter ?? .undefined, a) }
        if d.writable == true { a.insert(.writable) }
        return .data(d.value ?? .undefined, a)
    }

    /// ToPropertyDescriptor through the dispatched [[HasProperty]]/[[Get]].
    public func toPropertyDescriptorFull(_ v: JSValue) throws(JSThrow) -> JSPropertyDescriptor {
        guard v.isObject else { throw throwTypeError("Property description must be an object") }
        if !isExotic(v) { return try toPropertyDescriptor(v) }
        let depth = heap.rootDepth
        defer { heap.popRoots(to: depth) }
        _ = heap.root(v)
        var d = JSPropertyDescriptor()
        let n = heap.names
        if try objHas(v, n.enumerable) { d.enumerable = heap.toBoolean(try objGet(v, n.enumerable, receiver: v)) }
        if try objHas(v, n.configurable) { d.configurable = heap.toBoolean(try objGet(v, n.configurable, receiver: v)) }
        if try objHas(v, n.value) { let x = try objGet(v, n.value, receiver: v); _ = heap.root(x); d.value = x }
        if try objHas(v, n.writable) { d.writable = heap.toBoolean(try objGet(v, n.writable, receiver: v)) }
        if try objHas(v, n.get) {
            let g = try objGet(v, n.get, receiver: v)
            if !g.isUndefined && !heap.isCallable(g) { throw throwTypeError("Getter must be a function") }
            _ = heap.root(g); d.getter = g
        }
        if try objHas(v, n.set) {
            let s = try objGet(v, n.set, receiver: v)
            if !s.isUndefined && !heap.isCallable(s) { throw throwTypeError("Setter must be a function") }
            _ = heap.root(s); d.setter = s
        }
        if d.isAccessorDescriptor && d.isDataDescriptor {
            throw throwTypeError("Invalid property descriptor. Cannot both specify accessors and a value or writable attribute")
        }
        return d
    }

    /// IsArray (sees through proxies; TypeError on a revoked one).
    public func isArray(_ v: JSValue) throws(JSThrow) -> Bool {
        var cur = v
        var n = 0
        while true {
            let k = heap.kind(cur)
            if k == .array { return true }
            if k != .proxy { return false }
            let t = heap.slot(cur, 0)
            if !t.isObject { throw throwTypeError("Cannot perform 'IsArray' on a proxy that has been revoked") }
            cur = t
            n += 1
            if n > 100_000 { return false }
        }
    }

    public func isConstructor(_ v: JSValue) -> Bool { v.isObject && heap.flags(v).contains(.constructor) }

    /// CreateListFromArrayLike (with an optional key-type restriction).
    public func listFromArrayLike(_ v: JSValue, keysOnly: Bool = false) throws(JSThrow) -> [JSValue] {
        guard v.isObject else { throw throwTypeError("CreateListFromArrayLike called on non-object") }
        let depth = heap.rootDepth
        defer { heap.popRoots(to: depth) }
        _ = heap.root(v)
        let n = try toLength(try objGet(v, heap.names.length, receiver: v))
        if n > limits.maxDenseArrayLength { throw throwRangeError("Too many elements") }
        var out: [JSValue] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let x = try objGet(v, .index(UInt32(truncatingIfNeeded: i)), receiver: v)
            if keysOnly && !x.isString && !x.isSymbol { throw throwTypeError(describeForError(x) + " is not a valid property name") }
            _ = heap.root(x)
            out.append(x)
        }
        return out
    }

    /// GetMethod: undefined/null -> nil; non-callable -> TypeError.
    func getMethodOrNil(_ o: JSValue, _ k: JSPropertyKey) throws(JSThrow) -> JSValue? {
        let f = try getV(o, k)
        if f.isNullish { return nil }
        guard heap.isCallable(f) else { throw throwTypeError(keyDisplay(k) + " is not a function") }
        return f
    }

    /// SpeciesConstructor(o, default).
    public func speciesConstructor(_ o: JSValue, default dflt: JSValue) throws(JSThrow) -> JSValue {
        let c = try getV(o, heap.names.constructor)
        if c.isUndefined { return dflt }
        guard c.isObject else { throw throwTypeError("object.constructor is not an object") }
        let r = heap.root(c)
        defer { heap.popRoots(to: r.slot) }
        let s = try getV(c, .symbol(heap.symbolsWellKnown.species.handle))
        if s.isNullish { return dflt }
        guard isConstructor(s) else { throw throwTypeError("object.constructor[Symbol.species] is not a constructor") }
        return s
    }
}


/// Phase 9E's built-ins, in dependency order (one line in
/// JSRealm.installBuiltins).
func jsInstallES2015Runtime(_ realm: JSRealm) {
    jsInstallProxyReflect(realm)
    jsInstallCollections(realm)
    jsInstallWeakBuiltins(realm)
    jsInstallTypedArrays(realm)
    jsInstallAggregateError(realm)
}

/// AggregateError (when the Error built-ins have not made it).
func jsInstallAggregateError(_ realm: JSRealm) {
    let heap = realm.heap
    if realm.intrinsic(.aggregateErrorConstructor).isObject { return }
    let ep = realm.intrinsic(.errorPrototype)
    let p = heap.newObject(proto: ep)
    let r = heap.root(p)
    defer { heap.popRoots(to: r.slot) }
    realm.setIntrinsic(.aggregateErrorPrototype, p)
    realm.defineValue(p, "name", realm.string("AggregateError"))
    realm.defineValue(p, "message", .string(0))
    let c = realm.defineConstructor("AggregateError", length: 2, prototype: p) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let depth = h.rootDepth
        defer { h.popRoots(to: depth) }
        let proto = args.isConstruct ? try realm.prototype(forNewTarget: args.newTarget, default: .aggregateErrorPrototype)
                                     : realm.intrinsic(.aggregateErrorPrototype)
        _ = h.root(proto)
        var msg: JSValue = .undefined
        if !args[1].isUndefined { msg = try realm.toStringValue(args[1]); _ = h.root(msg) }
        let e = realm.makeErrorObject(.aggregateError, message: msg, proto: proto)
        _ = h.root(e)
        let opts = args[2]
        if opts.isObject, try realm.objHas(opts, h.names.cause) {
            let cv = try realm.getV(opts, h.names.cause)
            _ = h.defineOwnProperty(e, h.names.cause, .data(cv, [.writable, .configurable]))
        }
        var list: [JSValue] = []
        try realm.iterate(args[0]) { (v: JSValue) throws(JSThrow) -> Void in _ = h.root(v); list.append(v) }
        let arr = h.newArray(proto: realm.arrayPrototype, elements: list)
        _ = h.defineOwnProperty(e, h.names.errors, .data(arr, [.writable, .configurable]))
        return e
    }
    realm.setIntrinsic(.aggregateErrorConstructor, c)
    let ec = realm.intrinsic(.errorConstructor)
    if ec.isObject { _ = heap.setPrototypeOf(c, ec) }
}
