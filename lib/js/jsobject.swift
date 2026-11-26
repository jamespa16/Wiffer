// JS objects: property storage and the essential internal methods
// (ROADMAP Part 9, "Objects"). Everything goes through one
// getOwnProperty / defineOwnProperty path per object, which is where
// shapes and inline caches can go later (9J).
//
// Storage per object cell:
//   props     ordered [JSPropertySlot] (string and symbol keys, insertion
//             order; deleted entries are tombstones until compaction),
//             with an open-addressing hash index once there are more than
//             JSHeap.propertyHashThreshold (8) of them
//   elements  dense [JSValue] for index keys with default attributes
//             (writable, enumerable, configurable data); .hole = absent
//   sparse    [UInt32: JSPropertySlot] for other index keys (far beyond
//             the dense end, or non-default attributes, or accessors)
//   arrayLength (kind .array; "length" is virtual), proto, flags, kind,
//   slots [JSValue] and internalInt: internal slots for the VM and hosts
//             (function code + environment, primitive wrapper value, host
//             table index, ...), traced by the GC.
//
// API (on JSHeap; objects are JSValue.object(h)):
//   Creation (allocating; may GC; protect their arguments)
//     newObject(proto:kind:flags:) -> JSValue  proto is an object or .null
//     newArray(proto:elements:) -> JSValue   elements may contain .hole
//     newStringObject(proto:string:)          String exotic wrapper
//   Cell access (no allocation)
//     kind(o), flags(o) / setFlags(o, f), isCallable(v),
//     slotCount(o), slot(o, i), setSlot(o, i, v), setSlots(o, [v]),
//     internalInt(o) / setInternalInt(o, n)
//   Ordinary internal methods (no allocation, no GC, except reading an
//   index of a String wrapper whose character is >= U+0100, which makes a
//   one-character string)
//     getPrototypeOf(o), setPrototypeOf(o, p) -> Bool (cycle-checked),
//     isExtensible(o), preventExtensions(o)
//     getOwnProperty(o, k) -> JSProperty?
//     defineOwnProperty(o, k, desc) -> Bool  ValidateAndApplyProperty-
//         Descriptor, plus the Array exotic rules (index >= length grows
//         it; "length" truncates, ArraySetLength). For "length" the VM
//         must already have done ToNumber/ToUint32 and thrown RangeError
//         for an invalid length (see jsArrayLength(_:)); a non-number or
//         invalid value here just returns false.
//     deleteProperty(o, k) -> Bool           [[Delete]]
//     ownKeys(o) -> [JSPropertyKey]           [[OwnPropertyKeys]] order:
//         indices ascending, then strings, then symbols, by creation
//     hasOwnProperty(o, k), hasProperty(o, k) (prototype chain)
//     getProperty(o, k) -> JSGetResult       [[Get]] up the chain without
//         calling getters: .value(v), or .getter(fn) for the VM to call
//         with the receiver
//     setProperty(o, k, v, receiver:) -> JSSetResult   OrdinarySet without
//         calling setters: .done, .failed (TypeError in strict code), or
//         .setter(fn) for the VM to call
//     createDataProperty(o, k, v) -> Bool
//     arrayLength(o), setArrayLength(o, n) -> Bool
//   Equality on values: strictEquals, sameValue, sameValueZero; typeOf(v)
//   -> JSValue (a string); toBoolean(v); toPrimitiveNumber(v) -> Double?
//   and toPrimitiveString(v) -> JSValue? (nil for objects/symbols: the VM's
//   ToPrimitive / TypeError).
//   Store failures from the heap cap (termination) also return false.
//
// Exotic objects (Phase 9E; the full contract is at the top of
// jsexotic.swift). Arrays, String wrappers and typed arrays (integer-
// indexed exotic objects, kind .typedArray, whose elements live in an
// ArrayBuffer byte store, see jsbuiltins_typedarray.swift) are handled
// right here. Objects with flag .exotic (Proxy, host objects with exotic
// hooks) need the realm, because their internal methods can run JS:
// getProperty / setProperty stop at the first such object on the chain
// and return .exotic(obj) for the realm to finish (JSRealm.objGet /
// objSet). setProperty also returns .exotic when the receiver is exotic or
// a typed array element store needs ToNumber of an object. The other heap
// methods treat a Proxy as its target (no traps run) and a host object as
// ordinary: code that may see arbitrary objects should call the realm's
// obj* methods (jsexotic.swift), which run traps and hooks.

public enum JSObjectKind: UInt8 {
    case free, dead, ordinary, array, function, boundFunction, nativeFunction, arguments, error,
         booleanWrapper, numberWrapper, stringWrapper, symbolWrapper, bigintWrapper, date, regexp,
         map, set, weakMap, weakSet, weakRef, promise, proxy, generator, asyncGenerator, iterator,
         arrayBuffer, typedArray, dataView, environment, host, internalObject,
         // Phase 9E
         mapIterator, setIterator, finalizationRegistry,
         iteratorHelper
}

public struct JSObjectFlags: OptionSet {
    public var rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let extensible = JSObjectFlags(rawValue: 1 << 0)
    public static let callable = JSObjectFlags(rawValue: 1 << 1)
    public static let constructor = JSObjectFlags(rawValue: 1 << 2)
    /// Array: "length" is not writable.
    public static let lengthReadOnly = JSObjectFlags(rawValue: 1 << 3)
    /// Call JSHeap.finalizer when swept (host objects).
    public static let hasFinalizer = JSObjectFlags(rawValue: 1 << 4)
    public static let classConstructor = JSObjectFlags(rawValue: 1 << 5)
    public static let strict = JSObjectFlags(rawValue: 1 << 6)
    /// Internal methods dispatch through the realm (Proxy, host exotic
    /// objects): see jsexotic.swift.
    public static let exotic = JSObjectFlags(rawValue: 1 << 7)
    /// Bits 8...15 are free for the VM and embedder.
    public static let user0 = JSObjectFlags(rawValue: 1 << 8)
    public static let user1 = JSObjectFlags(rawValue: 1 << 9)
    public static let user2 = JSObjectFlags(rawValue: 1 << 10)
    public static let user3 = JSObjectFlags(rawValue: 1 << 11)
}

public struct JSPropertyAttributes: OptionSet {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let writable = JSPropertyAttributes(rawValue: 1)
    public static let enumerable = JSPropertyAttributes(rawValue: 2)
    public static let configurable = JSPropertyAttributes(rawValue: 4)
    /// An accessor property (value = getter, setter = setter).
    public static let accessor = JSPropertyAttributes(rawValue: 8)
    /// Writable, enumerable, configurable: what assignment creates.
    public static let `default`: JSPropertyAttributes = [.writable, .enumerable, .configurable]
}

/// A stored property: for accessors, value is the getter.
struct JSPropertySlot {
    var key: JSPropertyKey
    var value: JSValue
    var setter: JSValue
    var attributes: JSPropertyAttributes
}

/// A complete own property (what [[GetOwnProperty]] returns).
public struct JSProperty: Equatable {
    /// The data value (undefined for accessors).
    public var value: JSValue
    public var getter: JSValue
    public var setter: JSValue
    public var attributes: JSPropertyAttributes

    public var isAccessor: Bool { attributes.contains(.accessor) }
    public var writable: Bool { attributes.contains(.writable) }
    public var enumerable: Bool { attributes.contains(.enumerable) }
    public var configurable: Bool { attributes.contains(.configurable) }

    public static func data(_ v: JSValue, _ a: JSPropertyAttributes = .default) -> JSProperty {
        JSProperty(value: v, getter: .undefined, setter: .undefined, attributes: a.subtracting(.accessor))
    }
    public static func accessor(get g: JSValue, set s: JSValue, _ a: JSPropertyAttributes) -> JSProperty {
        JSProperty(value: .undefined, getter: g, setter: s,
                   attributes: a.subtracting(.writable).union(.accessor))
    }
}

/// A (possibly partial) property descriptor, as Object.defineProperty
/// takes it. nil fields are absent.
public struct JSPropertyDescriptor {
    public var value: JSValue?
    public var getter: JSValue?
    public var setter: JSValue?
    public var writable: Bool?
    public var enumerable: Bool?
    public var configurable: Bool?

    public init(value: JSValue? = nil, getter: JSValue? = nil, setter: JSValue? = nil,
                writable: Bool? = nil, enumerable: Bool? = nil, configurable: Bool? = nil) {
        self.value = value; self.getter = getter; self.setter = setter
        self.writable = writable; self.enumerable = enumerable; self.configurable = configurable
    }

    /// A complete data descriptor.
    public static func data(_ v: JSValue, _ a: JSPropertyAttributes = .default) -> JSPropertyDescriptor {
        JSPropertyDescriptor(value: v, writable: a.contains(.writable), enumerable: a.contains(.enumerable),
                             configurable: a.contains(.configurable))
    }
    /// A complete accessor descriptor (pass .undefined for a missing half).
    public static func accessor(get g: JSValue, set s: JSValue, _ a: JSPropertyAttributes = [.configurable])
        -> JSPropertyDescriptor {
        JSPropertyDescriptor(getter: g, setter: s, enumerable: a.contains(.enumerable),
                             configurable: a.contains(.configurable))
    }

    public var isAccessorDescriptor: Bool { getter != nil || setter != nil }
    public var isDataDescriptor: Bool { value != nil || writable != nil }
    public var isGenericDescriptor: Bool { !isAccessorDescriptor && !isDataDescriptor }
    var isEmpty: Bool { isGenericDescriptor && enumerable == nil && configurable == nil }
}

public enum JSGetResult: Equatable {
    case value(JSValue)
    /// Call this getter with the original receiver as `this`.
    case getter(JSValue)
    /// The lookup reached an object with flag .exotic (no earlier object
    /// on the chain had the key): finish with realm.objGet(obj, key,
    /// receiver: original receiver).
    case exotic(JSValue)
}

public enum JSSetResult: Equatable {
    case done
    /// Rejected (non-writable, no setter, not extensible): TypeError in
    /// strict mode code, silently ignored otherwise.
    case failed
    /// Call this setter with the receiver as `this` and the value.
    case setter(JSValue)
    /// The ordinary algorithm can't finish here (an .exotic object on the
    /// chain, an exotic receiver, or a typed array store that needs
    /// ToNumber of an object): finish with realm.objSet(obj, key, value,
    /// receiver: original receiver), which may run JS.
    case exotic(JSValue)
}

struct JSObjectCell {
    var kind: JSObjectKind = .free
    var flags: JSObjectFlags = []
    var proto: JSValue = .null
    var arrayLength: UInt32 = 0
    var deletedCount: Int32 = 0
    var internalInt: Int64 = 0
    var props = JSPropStore()
    var index: [Int32] = []
    var elements: [JSValue] = []
    var sparse: [UInt32: JSPropertySlot] = [:]
    var slots: [JSValue] = []
}

/// The array length for a number value, or nil (RangeError in the VM).
public func jsArrayLength(_ v: JSValue) -> UInt32? {
    if v.isInt32 { return v.asInt32 >= 0 ? UInt32(v.asInt32) : nil }
    guard v.isNumber else { return nil }
    let d = v.numberValue
    guard d >= 0 && d <= 4_294_967_295 && d == jsTrunc(d) else { return nil }
    return UInt32(d)
}

extension JSHeap {
    static let propertyHashThreshold = 8
    static let maxProtoChain = 100_000

    // MARK: Creation

    @inline(__always) func objectIndex(_ v: JSValue) -> Int? {
        let i = Int(v.handle)
        return v.isObject && i > 0 && i < objects.count && objects[i].kind != .free ? i : nil
    }

    public func newObject(proto: JSValue, kind: JSObjectKind = .ordinary,
                          flags: JSObjectFlags = [.extensible]) -> JSValue {
        guard beforeAllocation(112, proto, .undefined) else { return .object(0) }
        var c = JSObjectCell()
        c.kind = kind == .free ? .ordinary : kind
        c.flags = flags
        c.proto = proto.isObject ? proto : .null
        return .object(allocObjectSlot(c))
    }

    /// An Array exotic object holding `elements` (holes allowed).
    public func newArray(proto: JSValue, elements: [JSValue] = []) -> JSValue {
        // Protect the element values during a collection.
        let depth = rootStack.count
        rootStack.append(contentsOf: elements)
        let ok = beforeAllocation(112 + elements.count * 8, proto, .undefined)
        popRoots(to: depth)
        guard ok else { return .object(0) }
        var c = JSObjectCell()
        c.kind = .array
        c.flags = [.extensible]
        c.proto = proto.isObject ? proto : .null
        let n = min(elements.count, limits.maxDenseArrayLength)
        c.elements = n == elements.count ? elements : Array(elements[0..<n])
        c.arrayLength = UInt32(n)
        return .object(allocObjectSlot(c))
    }

    /// A String exotic object wrapping string s.
    public func newStringObject(proto: JSValue, string s: JSValue) -> JSValue {
        guard beforeAllocation(120, proto, s) else { return .object(0) }
        var c = JSObjectCell()
        c.kind = .stringWrapper
        c.flags = [.extensible]
        c.proto = proto.isObject ? proto : .null
        c.slots = [s.isString ? s : .string(0)]
        return .object(allocObjectSlot(c))
    }

    // MARK: Cell access

    public func kind(_ o: JSValue) -> JSObjectKind {
        if o.isObject && o.handle == 0 { return .dead }
        guard let i = objectIndex(o) else { return .free }
        return objects[i].kind
    }
    public func setKind(_ o: JSValue, _ k: JSObjectKind) {
        guard let i = objectIndex(o), k != .free, k != .dead else { return }
        objects[i].kind = k
    }
    public func flags(_ o: JSValue) -> JSObjectFlags {
        guard let i = objectIndex(o) else { return [] }
        return objects[i].flags
    }
    public func setFlags(_ o: JSValue, _ f: JSObjectFlags) {
        guard let i = objectIndex(o) else { return }
        objects[i].flags = f
    }
    public func isCallable(_ v: JSValue) -> Bool {
        guard let i = objectIndex(v) else { return false }
        return objects[i].flags.contains(.callable)
    }
    public func slotCount(_ o: JSValue) -> Int {
        guard let i = objectIndex(o) else { return 0 }
        return objects[i].slots.count
    }
    public func slot(_ o: JSValue, _ n: Int) -> JSValue {
        let i = Int(o.handle)
        guard o.isObject, i > 0, n >= 0 else { return .undefined }
        // Borrow the cell in place (no copy of the cell's arrays).
        return objects.withUnsafeBufferPointer { b -> JSValue in
            guard i < b.count else { return .undefined }
            return b[i].slots.withUnsafeBufferPointer { s in n < s.count ? s[n] : .undefined }
        }
    }
    public func setSlot(_ o: JSValue, _ n: Int, _ v: JSValue) {
        let i = Int(o.handle)
        guard o.isObject, i > 0, n >= 0 else { return }
        objects.withUnsafeMutableBufferPointer { b in
            guard i < b.count, b[i].kind != .free else { return }
            b[i].slots.withUnsafeMutableBufferPointer { s in if n < s.count { s[n] = v } }
        }
    }
    /// Replaces the internal slots (counted as growth; false if refused).
    @discardableResult
    public func setSlots(_ o: JSValue, _ s: [JSValue]) -> Bool {
        guard let i = objectIndex(o) else { return false }
        let delta = s.count - objects[i].slots.count
        if delta > 0 && !noteGrowth(delta * 8) { return false }
        objects[i].slots = s
        return true
    }
    public func internalInt(_ o: JSValue) -> Int64 {
        guard let i = objectIndex(o) else { return 0 }
        return objects[i].internalInt
    }
    public func setInternalInt(_ o: JSValue, _ n: Int64) {
        guard let i = objectIndex(o) else { return }
        objects[i].internalInt = n
    }

    // MARK: Prototype and extensibility

    public func getPrototypeOf(_ o: JSValue) -> JSValue {
        guard let i = objectIndex(o) else { return .null }
        if objects[i].kind == .proxy { return proxyFallback(o) { t in getPrototypeOf(t) } ?? .null }
        return objects[i].proto
    }

    /// OrdinarySetPrototypeOf: false if not extensible or it would make a
    /// cycle.
    public func setPrototypeOf(_ o: JSValue, _ p: JSValue) -> Bool {
        guard let i = objectIndex(o) else { return false }
        guard p.isNull || p.isObject else { return false }
        if objects[i].kind == .proxy { return proxyFallback(o) { t in setPrototypeOf(t, p) } ?? false }
        if objects[i].proto == p { return true }
        if !objects[i].flags.contains(.extensible) { return false }
        var cur = p
        var steps = 0
        while let j = objectIndex(cur) {
            if j == i { return false }
            if objects[j].kind == .proxy { break }
            cur = objects[j].proto
            steps += 1
            if steps > JSHeap.maxProtoChain { return false }
        }
        objects[i].proto = p
        return true
    }

    public func isExtensible(_ o: JSValue) -> Bool {
        guard let i = objectIndex(o) else { return false }
        if objects[i].kind == .proxy { return proxyFallback(o) { t in isExtensible(t) } ?? false }
        return objects[i].flags.contains(.extensible)
    }

    @discardableResult
    public func preventExtensions(_ o: JSValue) -> Bool {
        guard let i = objectIndex(o) else { return o.isObject }
        if objects[i].kind == .proxy { return proxyFallback(o) { t in preventExtensions(t) } ?? false }
        objects[i].flags.remove(.extensible)
        return true
    }

    // MARK: Slot lookup (the hash index)

    /// The slot of key k in cell i, or -1. Borrows the cell's arrays in
    /// place: plain `objects[i].props[j]` reads retained and released the
    /// arrays on every probe (9J: half of all VM time in richards).
    func findSlot(_ i: Int, _ k: JSPropertyKey) -> Int {
        return objects.withUnsafeBufferPointer { ob -> Int in
            guard i >= 0 && i < ob.count, let base = ob.baseAddress else { return -1 }
            let c = base + i
            let pb = c.pointee.props
            do {
                let n = pb.count
                let m = c.pointee.index.count
                if m == 0 {
                    var j = 0
                    while j < n {
                        if pb[j].key == k { return j }
                        j += 1
                    }
                    return -1
                }
                return c.pointee.index.withUnsafeBufferPointer { ib -> Int in
                    let mask = m - 1
                    var p = Int(k.hashValue32) & mask
                    var probes = 0
                    while probes < m {
                        let e = Int(ib[p])
                        if e < 0 { return -1 }
                        if e < n && pb[e].key == k { return e }
                        p = (p + 1) & mask
                        probes += 1
                    }
                    return -1
                }
            }
        }
    }

    /// Kind, flags and prototype of cell i (in range), read in place.
    @inline(__always) func cellHeader(_ i: Int) -> (kind: JSObjectKind, flags: JSObjectFlags, proto: JSValue) {
        return objects.withUnsafeBufferPointer { ob in (ob[i].kind, ob[i].flags, ob[i].proto) }
    }

    /// Slot j of cell i (both in range), read in place.
    @inline(__always) func propSlot(_ i: Int, _ j: Int) -> JSPropertySlot { objects[i].props[j] }

    /// Fills a just-made object (no properties yet) with dense elements
    /// and distinct new property slots, without the defineOwnProperty
    /// checks (arguments objects, 9J). No allocation, so no GC.
    func fillFreshObject(_ o: JSValue, elements: [JSValue], props: [JSPropertySlot]) {
        guard let i = objectIndex(o), objects[i].props.isEmpty, objects[i].elements.isEmpty else { return }
        guard noteGrowth(elements.count * 8 + props.count * 32) else { return }
        objects[i].elements = elements
        if objects[i].kind == .array { objects[i].arrayLength = UInt32(elements.count) }
        for p in props { objects[i].props.append(p) }
        if objects[i].props.count > JSHeap.propertyHashThreshold { rebuildIndex(i) }
    }

    func rebuildIndex(_ i: Int) {
        let n = objects[i].props.count
        var size = 16
        while size < n * 2 + 2 { size *= 2 }
        var table = [Int32](repeating: -1, count: size)
        let mask = size - 1
        for j in 0..<n {
            let k = objects[i].props[j].key
            if k == .deleted { continue }
            var p = Int(k.hashValue32) & mask
            while table[p] >= 0 { p = (p + 1) & mask }
            table[p] = Int32(j)
        }
        objects[i].index = table
    }

    func appendSlot(_ i: Int, _ s: JSPropertySlot) -> Bool {
        guard noteGrowth(32) else { return false }
        objects[i].props.append(s)
        let n = objects[i].props.count
        if objects[i].index.isEmpty {
            if n > JSHeap.propertyHashThreshold { rebuildIndex(i) }
        } else if n * 2 > objects[i].index.count {
            rebuildIndex(i)
        } else {
            let mask = objects[i].index.count - 1
            var p = Int(s.key.hashValue32) & mask
            while objects[i].index[p] >= 0 { p = (p + 1) & mask }
            objects[i].index[p] = Int32(n - 1)
        }
        return true
    }

    func removeSlot(_ i: Int, _ j: Int) {
        objects[i].props[j] = JSPropertySlot(key: .deleted, value: .undefined, setter: .undefined, attributes: [])
        objects[i].deletedCount += 1
        let dead = Int(objects[i].deletedCount)
        if dead >= 8 && dead * 2 >= objects[i].props.count {
            objects[i].props.removeAll { $0.key == .deleted }
            objects[i].deletedCount = 0
            if objects[i].props.count > JSHeap.propertyHashThreshold { rebuildIndex(i) } else { objects[i].index = [] }
        }
    }

    // MARK: [[GetOwnProperty]]

    @inline(__always) static func property(_ s: JSPropertySlot) -> JSProperty {
        if s.attributes.contains(.accessor) {
            return JSProperty(value: .undefined, getter: s.value, setter: s.setter, attributes: s.attributes)
        }
        return JSProperty(value: s.value, getter: .undefined, setter: .undefined, attributes: s.attributes)
    }

    func stringWrapperLength(_ i: Int) -> Int {
        guard objects[i].kind == .stringWrapper, let s = objects[i].slots.first else { return -1 }
        return stringLength(s)
    }

    public func getOwnProperty(_ o: JSValue, _ k: JSPropertyKey) -> JSProperty? {
        guard let i = objectIndex(o) else { return nil }
        if objects[i].kind == .typedArray, let x = typedArrayNumericIndex(k) {
            guard let v = typedArrayElement(i, x) else { return nil }
            return .data(v)
        }
        if objects[i].kind == .proxy { return proxyFallback(o) { t in getOwnProperty(t, k) } ?? nil }
        if k.isIndex {
            let idx = Int(k.index)
            if objects[i].kind == .stringWrapper {
                let s = objects[i].slots.first ?? .string(0)
                if idx < stringLength(s) {
                    let ch = singleUnitString(charCode(s, idx), protecting: o)
                    return .data(ch, [.enumerable])
                }
            }
            if idx < objects[i].elements.count {
                let v = objects[i].elements[idx]
                if !v.isHole { return .data(v) }
            }
            if !objects[i].sparse.isEmpty, let s = objects[i].sparse[k.index] { return JSHeap.property(s) }
            return nil
        }
        if k == names.length {
            if objects[i].kind == .array {
                let ro = objects[i].flags.contains(.lengthReadOnly)
                return .data(.number(Int(objects[i].arrayLength)), ro ? [] : [.writable])
            }
            if objects[i].kind == .stringWrapper {
                return .data(.number(stringWrapperLength(i)), [])
            }
        }
        let j = findSlot(i, k)
        return j < 0 ? nil : JSHeap.property(propSlot(i, j))
    }

    /// A one-unit string (Latin-1 units are cached and pinned).
    func singleUnitString(_ u: UInt16, protecting o: JSValue) -> JSValue {
        if u < 0x100 {
            return Int(u) < unitStrings.count ? unitStrings[Int(u)] : .string(0)
        }
        let r = root(o)
        let v = newString(utf16: [u])
        popRoots(to: r.slot)
        return v
    }

    public func hasOwnProperty(_ o: JSValue, _ k: JSPropertyKey) -> Bool {
        guard let i = objectIndex(o) else { return false }
        if objects[i].kind == .typedArray, let x = typedArrayNumericIndex(k) { return typedArrayValidIndex(i, x) }
        if objects[i].kind == .proxy { return proxyFallback(o) { t in hasOwnProperty(t, k) } ?? false }
        if k.isIndex {
            let idx = Int(k.index)
            if idx < stringWrapperLength(i) { return true }
            if idx < objects[i].elements.count && !objects[i].elements[idx].isHole { return true }
            return !objects[i].sparse.isEmpty && objects[i].sparse[k.index] != nil
        }
        if k == names.length && (objects[i].kind == .array || objects[i].kind == .stringWrapper) { return true }
        return findSlot(i, k) >= 0
    }

    // MARK: [[DefineOwnProperty]]

    /// ValidateAndApplyPropertyDescriptor: the resulting property, or nil
    /// if the definition is rejected.
    func validateAndApply(_ current: JSProperty?, _ d: JSPropertyDescriptor, extensible: Bool) -> JSProperty? {
        guard let cur = current else {
            if !extensible { return nil }
            var a: JSPropertyAttributes = []
            if d.enumerable == true { a.insert(.enumerable) }
            if d.configurable == true { a.insert(.configurable) }
            if d.isAccessorDescriptor {
                return .accessor(get: d.getter ?? .undefined, set: d.setter ?? .undefined, a)
            }
            if d.writable == true { a.insert(.writable) }
            return .data(d.value ?? .undefined, a)
        }
        if d.isEmpty { return cur }
        if !cur.configurable {
            if d.configurable == true { return nil }
            if let e = d.enumerable, e != cur.enumerable { return nil }
            if !d.isGenericDescriptor && d.isAccessorDescriptor != cur.isAccessor { return nil }
            if cur.isAccessor {
                if let g = d.getter, !sameValue(g, cur.getter) { return nil }
                if let s = d.setter, !sameValue(s, cur.setter) { return nil }
            } else if !cur.writable {
                if d.writable == true { return nil }
                if let v = d.value, !sameValue(v, cur.value) { return nil }
            }
        }
        var r = cur
        if d.isDataDescriptor && cur.isAccessor {
            var a = cur.attributes.intersection([.enumerable, .configurable])
            if d.writable == true { a.insert(.writable) }
            r = .data(d.value ?? .undefined, a)
        } else if d.isAccessorDescriptor && !cur.isAccessor {
            r = .accessor(get: d.getter ?? .undefined, set: d.setter ?? .undefined,
                          cur.attributes.intersection([.enumerable, .configurable]))
        } else {
            if let v = d.value { r.value = v }
            if let g = d.getter { r.getter = g }
            if let s = d.setter { r.setter = s }
            if let w = d.writable { if w { r.attributes.insert(.writable) } else { r.attributes.remove(.writable) } }
        }
        if let e = d.enumerable { if e { r.attributes.insert(.enumerable) } else { r.attributes.remove(.enumerable) } }
        if let c = d.configurable { if c { r.attributes.insert(.configurable) } else { r.attributes.remove(.configurable) } }
        return r
    }

    @inline(__always) static func slot(_ k: JSPropertyKey, _ p: JSProperty) -> JSPropertySlot {
        p.isAccessor ? JSPropertySlot(key: k, value: p.getter, setter: p.setter, attributes: p.attributes)
                     : JSPropertySlot(key: k, value: p.value, setter: .undefined, attributes: p.attributes)
    }

    public func defineOwnProperty(_ o: JSValue, _ k: JSPropertyKey, _ d: JSPropertyDescriptor) -> Bool {
        guard let i = objectIndex(o) else { return false }
        let kindI = objects[i].kind
        if kindI == .typedArray, let x = typedArrayNumericIndex(k) { return typedArrayDefine(i, x, d) }
        if kindI == .proxy { return proxyFallback(o) { t in defineOwnProperty(t, k, d) } ?? false }
        if k.isIndex {
            let idx = k.index
            if kindI == .array && idx >= objects[i].arrayLength && objects[i].flags.contains(.lengthReadOnly) {
                return false
            }
            if Int(idx) < stringWrapperLength(i) {
                let cur = getOwnProperty(o, k)
                return validateAndApply(cur, d, extensible: false) == cur
            }
            let cur = getOwnProperty(o, k)
            guard let fin = validateAndApply(cur, d, extensible: objects[i].flags.contains(.extensible)) else {
                return false
            }
            if let c = cur, c == fin { return true }
            guard storeIndexed(i, idx, fin) else { return false }
            if kindI == .array && idx >= objects[i].arrayLength { objects[i].arrayLength = idx + 1 }
            return true
        }
        if k == names.length {
            if kindI == .array { return arraySetLength(i, d) }
            if kindI == .stringWrapper {
                let cur = getOwnProperty(o, k)
                return validateAndApply(cur, d, extensible: false) == cur
            }
        }
        let j = findSlot(i, k)
        if j < 0 {
            guard let fin = validateAndApply(nil, d, extensible: objects[i].flags.contains(.extensible)) else {
                return false
            }
            return appendSlot(i, JSHeap.slot(k, fin))
        }
        let cur = JSHeap.property(objects[i].props[j])
        guard let fin = validateAndApply(cur, d, extensible: true) else { return false }
        objects[i].props[j] = JSHeap.slot(k, fin)
        return true
    }

    /// Store an index property into the dense or sparse element store.
    func storeIndexed(_ i: Int, _ idx: UInt32, _ p: JSProperty) -> Bool {
        let n = objects[i].elements.count
        let plain = !p.isAccessor && p.attributes == .default
        let x = Int(idx)
        if plain && (x < n || (x <= n + max(16, n / 2) && x < limits.maxDenseArrayLength)) {
            if x >= n {
                guard noteGrowth((x + 1 - n) * 8) else { return false }
                if x > n { objects[i].elements.append(contentsOf: [JSValue](repeating: .hole, count: x - n)) }
                objects[i].elements.append(p.value)
            } else {
                objects[i].elements[x] = p.value
            }
            if !objects[i].sparse.isEmpty { objects[i].sparse[idx] = nil }
            return true
        }
        if x < n { objects[i].elements[x] = .hole }
        if objects[i].sparse[idx] == nil { guard noteGrowth(48) else { return false } }
        objects[i].sparse[idx] = JSHeap.slot(.index(idx), p)
        return true
    }

    /// ArraySetLength.
    func arraySetLength(_ i: Int, _ d: JSPropertyDescriptor) -> Bool {
        let ro = objects[i].flags.contains(.lengthReadOnly)
        let oldLen = objects[i].arrayLength
        let cur = JSProperty.data(.number(Int(oldLen)), ro ? [] : [.writable])
        var newLen = oldLen
        var desc = d
        if let v = d.value {
            guard let n = jsArrayLength(v) else { return false }
            newLen = n
            desc.value = .number(Int(n))
        }
        // Validate as an ordinary definition (catches enumerable/
        // configurable/accessor changes and a read-only length change).
        let deferReadOnly = newLen < oldLen && d.writable == false
        if deferReadOnly { desc.writable = nil }
        guard let fin = validateAndApply(cur, desc, extensible: true) else { return false }
        if newLen < oldLen {
            if objects[i].elements.count > Int(newLen) { objects[i].elements.removeSubrange(Int(newLen)...) }
            if !objects[i].sparse.isEmpty {
                var keys: [UInt32] = []
                for (key, _) in objects[i].sparse where key >= newLen { keys.append(key) }
                keys.sort(by: >)
                for key in keys {
                    if let s = objects[i].sparse[key], !s.attributes.contains(.configurable) {
                        objects[i].arrayLength = key + 1
                        if !fin.writable || deferReadOnly { objects[i].flags.insert(.lengthReadOnly) }
                        return false
                    }
                    objects[i].sparse[key] = nil
                }
            }
            // Trailing holes left in the dense store are harmless.
        }
        objects[i].arrayLength = newLen
        if !fin.writable || deferReadOnly { objects[i].flags.insert(.lengthReadOnly) }
        return true
    }

    public func createDataProperty(_ o: JSValue, _ k: JSPropertyKey, _ v: JSValue) -> Bool {
        defineOwnProperty(o, k, .data(v))
    }

    public func arrayLength(_ o: JSValue) -> UInt32 {
        guard let i = objectIndex(o), objects[i].kind == .array else { return 0 }
        return objects[i].arrayLength
    }

    public func setArrayLength(_ o: JSValue, _ n: UInt32) -> Bool {
        guard let i = objectIndex(o), objects[i].kind == .array else { return false }
        return arraySetLength(i, JSPropertyDescriptor(value: .number(Int(n))))
    }

    // MARK: [[Delete]]

    public func deleteProperty(_ o: JSValue, _ k: JSPropertyKey) -> Bool {
        guard let i = objectIndex(o) else { return o.isObject }
        if objects[i].kind == .typedArray, let x = typedArrayNumericIndex(k) { return !typedArrayValidIndex(i, x) }
        if objects[i].kind == .proxy { return proxyFallback(o) { t in deleteProperty(t, k) } ?? false }
        if k.isIndex {
            let x = Int(k.index)
            if x < stringWrapperLength(i) { return false }
            if x < objects[i].elements.count && !objects[i].elements[x].isHole {
                objects[i].elements[x] = .hole
                if x == objects[i].elements.count - 1 {
                    while let l = objects[i].elements.last, l.isHole { objects[i].elements.removeLast() }
                }
                return true
            }
            if !objects[i].sparse.isEmpty, let s = objects[i].sparse[k.index] {
                if !s.attributes.contains(.configurable) { return false }
                objects[i].sparse[k.index] = nil
            }
            return true
        }
        if k == names.length && (objects[i].kind == .array || objects[i].kind == .stringWrapper) { return false }
        let j = findSlot(i, k)
        if j < 0 { return true }
        if !objects[i].props[j].attributes.contains(.configurable) { return false }
        removeSlot(i, j)
        return true
    }

    // MARK: [[OwnPropertyKeys]]

    public func ownKeys(_ o: JSValue) -> [JSPropertyKey] {
        guard let i = objectIndex(o) else { return [] }
        if objects[i].kind == .proxy { return proxyFallback(o) { t in ownKeys(t) } ?? [] }
        var out: [JSPropertyKey] = []
        let swLen = stringWrapperLength(i)
        if swLen > 0 { for x in 0..<swLen { out.append(.index(UInt32(x))) } }
        if objects[i].kind == .typedArray {
            let n = typedArrayLength(i)
            if n > 0 { out.reserveCapacity(n + 4); for x in 0..<n { out.append(.index(UInt32(truncatingIfNeeded: x))) } }
        }
        // Indices: dense and sparse, merged in ascending order.
        var sparseKeys: [UInt32] = []
        if !objects[i].sparse.isEmpty {
            for (key, _) in objects[i].sparse { sparseKeys.append(key) }
            sparseKeys.sort()
        }
        var s = 0
        let n = objects[i].elements.count
        for x in 0..<n where !objects[i].elements[x].isHole {
            while s < sparseKeys.count && sparseKeys[s] < UInt32(x) { out.append(.index(sparseKeys[s])); s += 1 }
            out.append(.index(UInt32(x)))
        }
        while s < sparseKeys.count { out.append(.index(sparseKeys[s])); s += 1 }
        if objects[i].kind == .array || objects[i].kind == .stringWrapper { out.append(names.length) }
        for p in objects[i].props where p.key.isString { out.append(p.key) }
        // Private names (Phase 9E, jsvm_private.swift) are own slots but never keys.
        for p in objects[i].props where p.key.isSymbol && !isPrivateSymbol(p.key.handle) { out.append(p.key) }
        return out
    }

    // MARK: Prototype chain: [[Get]], [[Set]], [[HasProperty]]

    public func getProperty(_ o: JSValue, _ k: JSPropertyKey) -> JSGetResult {
        var cur = o
        var steps = 0
        // Fast path (9J): string and symbol keys on ordinary cells read the
        // slot in place, with no JSProperty built and no array retained.
        if !k.isIndex {
            let isLength = k == names.length
            while let i = objectIndex(cur) {
                let h = cellHeader(i)
                if h.flags.contains(.exotic) { return .exotic(cur) }
                if h.kind == .typedArray || (isLength && (h.kind == .array || h.kind == .stringWrapper)) { break }
                let j = findSlot(i, k)
                if j >= 0 {
                    let p = propSlot(i, j)
                    if p.attributes.contains(.accessor) { return p.value.isUndefined ? .value(.undefined) : .getter(p.value) }
                    return .value(p.value)
                }
                cur = h.proto
                steps += 1
                if steps > JSHeap.maxProtoChain { return .value(.undefined) }
            }
            if !cur.isObject { return .value(.undefined) }
        }
        while let i = objectIndex(cur) {
            if objects[i].flags.contains(.exotic) { return .exotic(cur) }
            if objects[i].kind == .typedArray, let x = typedArrayNumericIndex(k) {
                return .value(typedArrayElement(i, x) ?? .undefined)
            }
            // Fast paths: dense element, plain slot.
            if k.isIndex {
                let x = Int(k.index)
                if x < objects[i].elements.count {
                    let v = objects[i].elements[x]
                    if !v.isHole { return .value(v) }
                }
            }
            if let p = getOwnProperty(cur, k) {
                if p.isAccessor { return p.getter.isUndefined ? .value(.undefined) : .getter(p.getter) }
                return .value(p.value)
            }
            cur = objects[i].proto
            steps += 1
            if steps > JSHeap.maxProtoChain { break }
        }
        return .value(.undefined)
    }

    public func hasProperty(_ o: JSValue, _ k: JSPropertyKey) -> Bool {
        var cur = o
        var steps = 0
        while let i = objectIndex(cur) {
            if objects[i].kind == .proxy {
                // No traps here (JSRealm.objHas runs them): the target.
                cur = proxyFallback(cur) { t in t } ?? .null
                steps += 1
                if steps > JSHeap.maxProtoChain { break }
                continue
            }
            if objects[i].kind == .typedArray, let x = typedArrayNumericIndex(k) { return typedArrayValidIndex(i, x) }
            if hasOwnProperty(cur, k) { return true }
            cur = objects[i].proto
            steps += 1
            if steps > JSHeap.maxProtoChain { break }
        }
        return false
    }

    public func setProperty(_ o: JSValue, _ k: JSPropertyKey, _ v: JSValue, receiver: JSValue) -> JSSetResult {
        // Fast path: own writable dense element or own writable data slot.
        if o == receiver, let i = objectIndex(o), !objects[i].flags.contains(.exotic) {
            if k.isIndex {
                let x = Int(k.index)
                if x < objects[i].elements.count && !objects[i].elements[x].isHole {
                    objects[i].elements[x] = v
                    return .done
                }
            } else if k != names.length || (objects[i].kind != .array && objects[i].kind != .stringWrapper) {
                let j = findSlot(i, k)
                if j >= 0 {
                    let a = objects[i].props[j].attributes
                    if a.contains(.writable) && !a.contains(.accessor) {
                        objects[i].props[j].value = v
                        return .done
                    }
                }
            }
        }
        if let ri = objectIndex(receiver), objects[ri].flags.contains(.exotic) { return .exotic(o) }
        var cur = o
        var steps = 0
        while let i = objectIndex(cur) {
            if objects[i].flags.contains(.exotic) { return .exotic(cur) }
            if objects[i].kind == .typedArray, let x = typedArrayNumericIndex(k) {
                // TypedArray [[Set]]: the receiver itself stores (ToNumber
                // of a non-primitive needs the realm); another receiver
                // sees an invalid index as done, a valid one as a writable
                // data property (OrdinarySet below).
                if cur == receiver {
                    if typedArrayNeedsRealm(cur, v) { return .exotic(cur) }
                    typedArraySetElementValue(i, x, v)
                    return .done
                }
                if !typedArrayValidIndex(i, x) { return .done }
                break
            }
            if let p = getOwnProperty(cur, k) {
                if p.isAccessor { return p.setter.isUndefined ? .failed : .setter(p.setter) }
                if !p.writable { return .failed }
                break
            }
            cur = objects[i].proto
            steps += 1
            if steps > JSHeap.maxProtoChain { break }
        }
        guard receiver.isObject else { return .failed }
        if kind(receiver) == .typedArray && typedArrayNumericIndex(k) != nil && typedArrayNeedsRealm(receiver, v) {
            return .exotic(o)
        }
        if let existing = getOwnProperty(receiver, k) {
            if existing.isAccessor || !existing.writable { return .failed }
            return defineOwnProperty(receiver, k, JSPropertyDescriptor(value: v)) ? .done : .failed
        }
        return createDataProperty(receiver, k, v) ? .done : .failed
    }

    // MARK: Values

    public func strictEquals(_ a: JSValue, _ b: JSValue) -> Bool {
        if a.isNumber && b.isNumber { return a.numberValue == b.numberValue }
        if a.isString && b.isString { return stringsEqual(a, b) }
        if a.isBigInt && b.isBigInt { return bigintsEqual(a, b) }
        return a.bits == b.bits && !a.isDouble
    }

    public func sameValue(_ a: JSValue, _ b: JSValue) -> Bool {
        if a.isNumber && b.isNumber { return jsSameValueNumber(a.numberValue, b.numberValue) }
        if a.isString && b.isString { return stringsEqual(a, b) }
        if a.isBigInt && b.isBigInt { return bigintsEqual(a, b) }
        return a.bits == b.bits
    }

    public func sameValueZero(_ a: JSValue, _ b: JSValue) -> Bool {
        if a.isNumber && b.isNumber {
            let x = a.numberValue, y = b.numberValue
            return x == y || (x.isNaN && y.isNaN)
        }
        return sameValue(a, b)
    }

    public func toBoolean(_ v: JSValue) -> Bool {
        if v.isBool { return v.boolValue }
        if v.isInt32 { return v.asInt32 != 0 }
        if v.isDouble { let d = v.asDouble; return !(d == 0 || d.isNaN) }
        if v.isString { return stringLength(v) != 0 }
        if v.isNullish || v.isHole { return false }
        if v.isBigInt {
            let i = Int(v.handle)
            return i < bigints.count && !bigints[i].limbs.isEmpty
        }
        return true
    }

    /// typeof, as an atom string value.
    public func typeOf(_ v: JSValue) -> JSValue {
        let k: JSPropertyKey
        switch v.type {
        case .undefined: k = names.undefined
        case .null: k = names.object
        case .boolean: k = names.boolean
        case .number: k = names.number
        case .string: k = names.string
        case .symbol: k = names.symbol
        case .bigint: k = names.bigint
        case .object: k = isCallable(v) ? names.function : names.object
        }
        return .string(k.handle)
    }

    /// ToNumber for primitives; nil for objects (ToPrimitive first),
    /// symbols and bigints (TypeError).
    public func toPrimitiveNumber(_ v: JSValue) -> Double? {
        if v.isNumber { return v.numberValue }
        if v.isUndefined { return .nan }
        if v.isNull { return 0 }
        if v.isBool { return v.boolValue ? 1 : 0 }
        if v.isString { return stringToNumber(v) }
        return nil
    }

    /// ToString for primitives (allocates for numbers); nil for objects
    /// (ToPrimitive first) and symbols (TypeError).
    public func toPrimitiveString(_ v: JSValue) -> JSValue? {
        if v.isString { return v }
        if v.isNumber {
            if v.isInt32 && v.asInt32 >= 0 && v.asInt32 < 10 {
                return singleUnitString(UInt16(0x30 + v.asInt32), protecting: .undefined)
            }
            return numberToString(v.numberValue)
        }
        if v.isUndefined { return .string(names.undefined.handle) }
        if v.isNull { return .string(names.null.handle) }
        if v.isBool { return .string((v.boolValue ? names.true_ : names.false_).handle) }
        if v.isBigInt { return bigintToString(v) }
        return nil
    }
}
