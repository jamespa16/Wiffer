// Host objects: native classes whose instances stand for Swift objects
// (ROADMAP Phase 9F). No DOM here; lib/js-dom builds on this.
//
//     final class Counter { var n = 0 }                  // any class
//
//     let cls = JSHostClass<Counter>(realm: realm, name: "Counter")
//     cls.define(methods: [
//         JSHostMethod("inc", 0) { (realm, c, args) throws(JSThrow) -> JSValue in c.n += 1; return .undefined },
//     ], accessors: [
//         JSHostAccessor("value", get: { (realm, c) throws(JSThrow) -> JSValue in .number(c.n) }),
//     ])
//     cls.exposeConstructor(length: 1) { (realm, args) throws(JSThrow) -> Counter in Counter() }
//         // `new Counter()` in script; without a constructor the global
//         // throws "Illegal constructor"
//     let v = cls.wrap(counter)        // the wrapper for this Swift object
//     cls.unwrap(v) -> Counter?        // nil for anything but a Counter wrapper
//
// A host object is a JS object of kind .host. The Swift object lives in a
// per-class table (generic over the host type: no `any`), and the object's
// internalInt is its table index (slots stay free for the host, e.g. event
// listeners, and are traced by the GC).
//
// Wrapper cache. wrap() returns the same JS object for the same Swift
// object (by identity) for as long as the wrapper lives, so `a.firstChild
// === a.firstChild` and expando properties persist. The table holds the
// Swift object strongly until the wrapper is collected. A wrapper is a GC
// root while `shouldRoot(object)` says so (evaluated at every collection;
// e.g. "the node is connected, or has expandos or listeners") or while it
// is pinned (`pin(object, true)`). Otherwise an unreachable wrapper is
// collected and a later wrap() makes a new one. Finalization only releases
// the table entry; the Swift object's deinit must not touch the JS heap.
//
// Exotic behavior (WebIDL legacy platform objects). Pass a JSHostExotic to
// the class for indexed getters (NodeList, HTMLCollection) and named
// properties (document.forms): they are exposed through the realm's
// exotic hook (jsexotic.swift), so `list[0]`, `0 in list`,
// `Object.keys(list)`, `forms.login` work, and indexed/named properties
// are read-only unless a setter is given.

public struct JSHostMethod<T: AnyObject> {
    public let name: String
    public let length: Int
    public let fn: (_ realm: JSRealm, _ this: T, _ args: JSArgs) throws(JSThrow) -> JSValue
    public init(_ name: String, _ length: Int,
                _ fn: @escaping (_ realm: JSRealm, _ this: T, _ args: JSArgs) throws(JSThrow) -> JSValue) {
        self.name = name
        self.length = length
        self.fn = fn
    }
}

public struct JSHostAccessor<T: AnyObject> {
    public let name: String
    public let get: (_ realm: JSRealm, _ this: T) throws(JSThrow) -> JSValue
    public let set: ((_ realm: JSRealm, _ this: T, _ value: JSValue) throws(JSThrow) -> Void)?
    public init(_ name: String,
                get: @escaping (_ realm: JSRealm, _ this: T) throws(JSThrow) -> JSValue,
                set: ((_ realm: JSRealm, _ this: T, _ value: JSValue) throws(JSThrow) -> Void)? = nil) {
        self.name = name
        self.get = get
        self.set = set
    }
}

/// Indexed and named property behavior for a host class.
public struct JSHostExotic<T: AnyObject> {
    /// Number of supported indices (0..<count are the indexed properties).
    public var length: ((_ this: T) -> Int)? = nil
    /// The value at a supported index (nil: not supported).
    public var indexedGet: ((_ realm: JSRealm, _ this: T, _ index: Int) throws(JSThrow) -> JSValue?)? = nil
    /// The value of a named property (nil: not supported).
    public var namedGet: ((_ realm: JSRealm, _ this: T, _ name: String) throws(JSThrow) -> JSValue?)? = nil
    /// Supported names, for Object.keys and for-in (in order).
    public var namedKeys: ((_ this: T) -> [String])? = nil
    /// Named properties show up in Object.keys (WebIDL: HTMLCollection's
    /// named properties are not enumerable).
    public var namedEnumerable = false
    /// Indexed assignment (nil: indexed properties are read-only).
    public var indexedSet: ((_ realm: JSRealm, _ this: T, _ index: Int, _ value: JSValue) throws(JSThrow) -> Bool)? = nil
    public init() {}
}

public final class JSHostClass<T: AnyObject> {
    unowned(unsafe) public let realm: JSRealm
    public let name: String
    /// The class prototype (kept alive by the class).
    public private(set) var prototype: JSValue = .undefined
    var items: [T?] = []
    var handles: [JSHandle] = []
    var pinned: [Bool] = []
    var freeSlots: [Int] = []
    var byIdentity: [ObjectIdentifier: Int] = [:]
    var exoticID = -1
    var exotic: JSHostExotic<T>? = nil
    /// GC-root condition, evaluated at every collection.
    public var shouldRoot: ((_ object: T) -> Bool)? = nil

    /// A class whose prototype inherits `parent` (default Object.prototype).
    public init(realm: JSRealm, name: String, parent: JSValue? = nil, exotic: JSHostExotic<T>? = nil) {
        self.realm = realm
        self.name = name
        let depth = realm.heap.rootDepth
        let p = realm.heap.newObject(proto: parent ?? realm.objectPrototype)
        _ = realm.heap.root(p)
        prototype = p
        realm.heap.popRoots(to: depth)
        self.exotic = exotic
        _ = realm.heap.addRootProvider { [self] h in self.markRoots(h) }
        let prev = realm.hostFinalizer
        realm.hostFinalizer = { [self] (h: JSHandle, ii: Int64) in
            if !self.release(handle: h, index: Int(ii)) { prev?(h, ii) }
        }
        if let e = exotic { exoticID = realm.registerExoticHandler(makeHandler(e)) }
    }

    func markRoots(_ h: JSHeap) {
        h.markValue(prototype)
        var i = 0
        while i < items.count {
            if let item = items[i], pinned[i] || (shouldRoot?(item) ?? false) { h.markValue(.object(handles[i])) }
            i += 1
        }
    }

    /// Finalizer hook: true when (handle, index) was one of ours.
    func release(handle h: JSHandle, index i: Int) -> Bool {
        guard i >= 0 && i < items.count, handles[i] == h, let item = items[i] else { return false }
        byIdentity[ObjectIdentifier(item)] = nil
        items[i] = nil
        pinned[i] = false
        freeSlots.append(i)
        return true
    }

    // MARK: Prototype table

    /// Define methods (non-enumerable) and accessors on the prototype. A
    /// call with a `this` that is not one of ours throws TypeError.
    public func define(methods: [JSHostMethod<T>] = [], accessors: [JSHostAccessor<T>] = []) {
        let proto = prototype
        for m in methods {
            let fn = m.fn
            let cname = name
            realm.defineMethod(proto, m.name, length: m.length) { [self] (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
                guard let t = self.unwrap(args.this) else {
                    throw realm.throwTypeError("Illegal invocation: " + cname + "." + m.name)
                }
                return try fn(realm, t, args)
            }
        }
        for a in accessors {
            let g = a.get
            let s = a.set
            let cname = name
            let setter: JSNativeFunction? = s == nil ? nil : { [self] (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
                guard let t = self.unwrap(args.this) else {
                    throw realm.throwTypeError("Illegal invocation: " + cname + "." + a.name)
                }
                try s!(realm, t, args[0])
                return .undefined
            }
            realm.defineGetter(proto, a.name, setter: setter) { [self] (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
                guard let t = self.unwrap(args.this) else {
                    throw realm.throwTypeError("Illegal invocation: " + cname + "." + a.name)
                }
                return try g(realm, t)
            }
        }
    }

    /// Define the global constructor. `construct` makes the Swift object for
    /// `new Name(...)`; nil means "Illegal constructor".
    @discardableResult
    public func exposeConstructor(length: Int = 0,
                                  construct: ((_ realm: JSRealm, _ args: JSArgs) throws(JSThrow) -> T)? = nil) -> JSValue {
        let cname = name
        return realm.defineConstructor(name, length: length, prototype: prototype) { [self] (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            guard let c = construct else { throw realm.throwTypeError("Illegal constructor: " + cname) }
            if !args.isConstruct { throw realm.throwTypeError("Class constructor " + cname + " cannot be invoked without 'new'") }
            let obj = try c(realm, args)
            var proto = self.prototype
            if args.newTarget.isObject {
                let p = try realm.getV(args.newTarget, realm.heap.names.prototype)
                if p.isObject { proto = p }
            }
            let w = self.wrap(obj)
            if w.isObject && proto.handle != self.prototype.handle { _ = realm.heap.setPrototypeOf(w, proto) }
            return w
        }
    }

    // MARK: Wrapping

    /// The wrapper for `obj`: the existing one while it lives, else a new
    /// one (undefined after a termination).
    public func wrap(_ obj: T) -> JSValue {
        let id = ObjectIdentifier(obj)
        if let i = byIdentity[id] { return .object(handles[i]) }
        let heap = realm.heap
        let o = heap.newObject(proto: prototype, kind: .host, flags: [.extensible, .hasFinalizer])
        if o.handle == 0 { return .undefined }
        var i: Int
        if let f = freeSlots.popLast() {
            i = f
            items[i] = obj
            handles[i] = o.handle
            pinned[i] = false
        } else {
            i = items.count
            items.append(obj)
            handles.append(o.handle)
            pinned.append(false)
        }
        byIdentity[id] = i
        heap.setInternalInt(o, Int64(i))
        if exoticID >= 0 { realm.makeExotic(o, handler: exoticID) }
        return o
    }

    /// The live wrapper for `obj`, if it has one (no allocation).
    public func existingWrapper(for obj: T) -> JSValue? {
        if let i = byIdentity[ObjectIdentifier(obj)] { return .object(handles[i]) }
        return nil
    }

    /// The Swift object behind a wrapper of this class.
    public func unwrap(_ v: JSValue) -> T? {
        guard v.isObject, realm.heap.kind(v) == .host else { return nil }
        let i = Int(realm.heap.internalInt(v))
        guard i >= 0 && i < items.count, handles[i] == v.handle else { return nil }
        return items[i]
    }

    /// Keep (or stop keeping) `obj`'s wrapper alive regardless of reachability.
    public func pin(_ obj: T, _ on: Bool) {
        if let i = byIdentity[ObjectIdentifier(obj)] { pinned[i] = on }
    }

    /// Wrappers currently in the table (for tests and diagnostics).
    public var liveCount: Int { items.count - freeSlots.count }

    // MARK: Exotic hooks

    func hostObject(_ o: JSValue) -> T? { unwrap(o) }

    func makeHandler(_ e: JSHostExotic<T>) -> JSExoticHandler {
        var h = JSExoticHandler()
        h.getOwnProperty = { [self] (realm: JSRealm, o: JSValue, k: JSPropertyKey) throws(JSThrow) -> JSProperty? in
            guard let t = self.unwrap(o) else { return nil }
            if k.isIndex, let g = e.indexedGet {
                if let v = try g(realm, t, Int(k.index)) {
                    return .data(v, e.indexedSet == nil ? [.enumerable, .configurable] : [.writable, .enumerable, .configurable])
                }
                return nil
            }
            if k.isString, let g = e.namedGet {
                // Own properties and the prototype's win over named ones
                // (the [LegacyOverrideBuiltIns] case is not modelled).
                if realm.heap.getOwnProperty(o, k) != nil { return nil }
                let n = realm.heap.swiftString(realm.heap.keyValue(k))
                if let v = try g(realm, t, n) {
                    return .data(v, e.namedEnumerable ? [.enumerable, .configurable] : [.configurable])
                }
            }
            return nil
        }
        h.get = { [self] (realm: JSRealm, o: JSValue, k: JSPropertyKey, receiver: JSValue) throws(JSThrow) -> JSValue? in
            guard k.isIndex, let g = e.indexedGet, let t = self.unwrap(o) else { return nil }
            return try g(realm, t, Int(k.index)) ?? .undefined
        }
        h.set = { [self] (realm: JSRealm, o: JSValue, k: JSPropertyKey, v: JSValue, receiver: JSValue) throws(JSThrow) -> Bool? in
            guard k.isIndex, let t = self.unwrap(o), let g = e.indexedGet else { return nil }
            if let s = e.indexedSet { return try s(realm, t, Int(k.index), v) }
            if try g(realm, t, Int(k.index)) != nil { return false }
            return nil
        }
        h.defineOwnProperty = { [self] (realm: JSRealm, o: JSValue, k: JSPropertyKey, d: JSPropertyDescriptor) throws(JSThrow) -> Bool? in
            guard k.isIndex, let t = self.unwrap(o), let g = e.indexedGet else { return nil }
            if try g(realm, t, Int(k.index)) != nil { return false }
            return nil
        }
        h.deleteProperty = { [self] (realm: JSRealm, o: JSValue, k: JSPropertyKey) throws(JSThrow) -> Bool? in
            guard let t = self.unwrap(o) else { return nil }
            if k.isIndex, let g = e.indexedGet, try g(realm, t, Int(k.index)) != nil { return false }
            if k.isString, let g = e.namedGet, realm.heap.getOwnProperty(o, k) == nil {
                let n = realm.heap.swiftString(realm.heap.keyValue(k))
                if try g(realm, t, n) != nil { return false }
            }
            return nil
        }
        h.ownKeys = { [self] (realm: JSRealm, o: JSValue) throws(JSThrow) -> [JSPropertyKey] in
            guard let t = self.unwrap(o) else { return [] }
            var keys: [JSPropertyKey] = []
            if let len = e.length {
                let n = min(len(t), 1 << 24)
                var i = 0
                while i < n { keys.append(.index(UInt32(i))); i += 1 }
            }
            if let nk = e.namedKeys {
                for name in nk(t) { keys.append(realm.heap.key(name)) }
            }
            return keys
        }
        return h
    }
}
