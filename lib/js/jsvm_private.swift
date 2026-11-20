// Private class members (ROADMAP Phase 9E): #fields, #methods, #accessors,
// static ones, `#x in o` brand checks.
//
// A private name is a private record (an internal object made by the
// newPrivateName instruction once per class evaluation): slot 0 a fresh
// symbol flagged isPrivate (description "#x"), slot 1 the method or
// getter, slot 2 the setter; internalInt = JSPrivateKind. The compiler
// keeps each record in a hidden class-scope binding (jsscope.swift).
//
// A private element lives on the object as an own property slot keyed by
// that symbol, reached only through the raw slot helpers below: they skip
// the prototype chain, extensibility and any exotic behavior (Proxy),
// and heap.ownKeys never lists private symbols, so no reflection API
// (Object.getOwnPropertySymbols, Reflect.ownKeys, spread, freeze, JSON)
// can see or change one. Methods are non-writable data slots and
// accessors accessor slots, so the brand check for a method is the
// presence of its slot.

enum JSPrivateKind {
    static let field: Int64 = 0
    static let method: Int64 = 1
    static let accessor: Int64 = 2
}

extension JSHeap {
    func isPrivateSymbol(_ h: UInt32) -> Bool {
        let i = Int(h)
        return i > 0 && i < symbols.count && symbols[i].isPrivate
    }

    func newPrivateSymbol(description: JSValue) -> JSValue {
        let s = newSymbol(description: description)
        let i = Int(s.handle)
        if i > 0 && i < symbols.count { symbols[i].isPrivate = true }
        return s
    }

    /// The own slot index of a private key, or -1 (no exotic behavior).
    func privateSlotIndex(_ o: JSValue, _ k: JSPropertyKey) -> (Int, Int) {
        guard let i = objectIndex(o) else { return (-1, -1) }
        return (i, findSlot(i, k))
    }

    func privateAdd(_ o: JSValue, _ k: JSPropertyKey, value: JSValue, setter: JSValue,
                    _ attrs: JSPropertyAttributes) -> Bool {
        guard let i = objectIndex(o) else { return false }
        return appendSlot(i, JSPropertySlot(key: k, value: value, setter: setter, attributes: attrs))
    }
}

extension JSRealm {
    func privateDescription(_ rec: JSValue) -> String {
        let d = heap.symbolDescription(heap.slot(rec, 0))
        return d.isString ? heap.swiftString(d) : "#<private>"
    }

    func privateKey(_ rec: JSValue) throws(JSThrow) -> JSPropertyKey {
        let s = heap.slot(rec, 0)
        guard s.isSymbol else { throw throwTypeError("invalid private name") }
        return .symbol(s.handle)
    }

    /// PrivateGet: .value(v) or .getter(fn) for the VM to call.
    func privateGet(_ o: JSValue, _ rec: JSValue) throws(JSThrow) -> JSGetResult {
        let k = try privateKey(rec)
        let (i, j) = heap.privateSlotIndex(o, k)
        guard j >= 0 else {
            throw throwTypeError("Cannot read private member " + privateDescription(rec) + " from an object whose class did not declare it")
        }
        let s = heap.objects[i].props[j]
        if s.attributes.contains(.accessor) {
            if s.value.isUndefined { throw throwTypeError("'" + privateDescription(rec) + "' was defined without a getter") }
            return .getter(s.value)
        }
        return .value(s.value)
    }

    /// PrivateSet: nil when stored, else a setter to call.
    func privateSet(_ o: JSValue, _ rec: JSValue, _ v: JSValue) throws(JSThrow) -> JSValue? {
        let k = try privateKey(rec)
        let (i, j) = heap.privateSlotIndex(o, k)
        guard j >= 0 else {
            throw throwTypeError("Cannot write private member " + privateDescription(rec) + " to an object whose class did not declare it")
        }
        let s = heap.objects[i].props[j]
        if s.attributes.contains(.accessor) {
            if s.setter.isUndefined { throw throwTypeError("'" + privateDescription(rec) + "' was defined without a setter") }
            return s.setter
        }
        if !s.attributes.contains(.writable) {
            throw throwTypeError("Private method " + privateDescription(rec) + " is not writable")
        }
        heap.objects[i].props[j].value = v
        return nil
    }

    /// PrivateFieldAdd (field initializers).
    func privateDefine(_ o: JSValue, _ rec: JSValue, _ v: JSValue) throws(JSThrow) {
        let k = try privateKey(rec)
        guard o.isObject else { throw throwTypeError("Cannot define a private field on a non-object") }
        if heap.privateSlotIndex(o, k).1 >= 0 {
            throw throwTypeError("Cannot initialize " + privateDescription(rec) + " twice on the same object")
        }
        if !heap.privateAdd(o, k, value: v, setter: .undefined, [.writable]) { throw JSThrow() }
    }

    /// PrivateMethodOrAccessorAdd (instance brands and static methods).
    func privateAddBrand(_ o: JSValue, _ rec: JSValue) throws(JSThrow) {
        let k = try privateKey(rec)
        guard o.isObject else { throw throwTypeError("Cannot add a private method to a non-object") }
        if heap.privateSlotIndex(o, k).1 >= 0 {
            throw throwTypeError("Cannot initialize private methods of class " + privateDescription(rec) + " twice on the same object")
        }
        let ok: Bool
        if heap.internalInt(rec) == JSPrivateKind.accessor {
            ok = heap.privateAdd(o, k, value: heap.slot(rec, 1), setter: heap.slot(rec, 2), [.accessor])
        } else {
            ok = heap.privateAdd(o, k, value: heap.slot(rec, 1), setter: .undefined, [])
        }
        if !ok { throw JSThrow() }
    }

    func privateHas(_ o: JSValue, _ rec: JSValue) throws(JSThrow) -> Bool {
        guard o.isObject else {
            throw throwTypeError("Cannot use 'in' operator to search for '" + privateDescription(rec) + "' in " + describeForError(o))
        }
        return heap.privateSlotIndex(o, try privateKey(rec)).1 >= 0
    }

    /// CopyDataProperties excluding the keys in an array (an object
    /// pattern's rest after computed keys: the keys are collected at run
    /// time; Phase 9E gap).
    func copyDataPropertiesExcludingArray(into target: JSValue, from src: JSValue, keys: JSValue) throws(JSThrow) {
        if src.isNullish { return }
        let s = try toObject(src)
        let r = heap.root(s)
        defer { heap.popRoots(to: r.slot) }
        var excluded = Set<UInt64>()
        let n = Int(heap.arrayLength(keys))
        for i in 0..<n {
            if case .value(let kv) = heap.getProperty(keys, .index(UInt32(i))) {
                excluded.insert(try toPropertyKey(kv).bits)
            }
        }
        for k in heap.ownKeys(s) where !excluded.contains(k.bits) {
            guard let p = heap.getOwnProperty(s, k), p.enumerable else { continue }
            let v = try getV(s, k)
            _ = heap.createDataProperty(target, k, v)
        }
    }

    func newPrivateRecord(_ description: JSValue, kind: Int64) -> JSValue {
        let r = heap.root(description)
        defer { heap.popRoots(to: r.slot) }
        let s = heap.newPrivateSymbol(description: description)
        _ = heap.root(s)
        let rec = heap.newObject(proto: .null, kind: .internalObject)
        heap.setSlots(rec, [s, .undefined, .undefined])
        heap.setInternalInt(rec, kind)
        return rec
    }
}
