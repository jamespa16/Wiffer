// Map and Set (ROADMAP Phase 9E): insertion-ordered hash tables keyed by
// SameValueZero.
//
// Storage. Entries live in the collection object's slots (so the GC traces
// them): Map [k0 v0 k1 v1 ...], Set [k0 k1 ...]; a deleted entry's key is
// .hole. A Swift side index (JSMapIndex in realm.tables.mapIndexes, found
// through the object's internalInt = index id + 1) maps keys to entry
// positions by open addressing; it hashes strings by content and numbers by
// value (-0 is +0, one NaN). The index is freed by the 9E weak processor
// once the object is dead (jsbuiltins_weak.swift).
//
// Iteration robust to mutation: an iterator (kind .mapIterator /
// .setIterator, slots [collection], internalInt = next position) walks
// positions in order, skipping holes, so entries added during iteration are
// visited and deleted ones are not. When holes pile up the table is
// compacted and every live iterator registered on it is moved to the same
// logical place; clear() is a compaction to nothing, so iterators then see
// only entries added afterwards (the spec's behavior).
//
// Installed: Map (get set has delete clear size forEach keys values
// entries @@iterator @@toStringTag, Map.groupBy, @@species), Set (add has
// delete clear size forEach values keys entries @@iterator, the ES2025
// set methods union intersection difference symmetricDifference isSubsetOf
// isSupersetOf isDisjointFrom, @@species), %MapIteratorPrototype%,
// %SetIteratorPrototype%.

final class JSMapIndex {
    var owner: JSValue
    let stride: Int
    /// Entry positions; -1 empty, -2 deleted.
    var table: [Int32] = [Int32](repeating: -1, count: 8)
    var used = 0          // table cells not empty (live + deleted)
    var entries = 0       // positions in slots (holes included)
    var live = 0
    var iterators: [JSHandle] = []
    var iteratorsAtPrune = 0

    init(owner: JSValue, stride: Int) { self.owner = owner; self.stride = stride }
}

extension JSRealm {
    // MARK: Index plumbing

    func mapIndex(_ o: JSValue) -> JSMapIndex? {
        let id = Int(heap.internalInt(o)) - 1
        guard id >= 0 && id < tables.mapIndexes.count else { return nil }
        guard let ix = tables.mapIndexes[id], ix.owner == o else { return nil }
        return ix
    }

    /// A new Map (stride 2) or Set (stride 1) object.
    func newCollection(proto: JSValue, set: Bool) -> JSValue {
        let o = heap.newObject(proto: proto, kind: set ? .set : .map)
        guard heap.kind(o) == (set ? .set : .map) else { return o }
        let ix = JSMapIndex(owner: o, stride: set ? 1 : 2)
        let id: Int
        if let f = tables.mapIndexFree.popLast() { id = f; tables.mapIndexes[f] = ix } else {
            id = tables.mapIndexes.count; tables.mapIndexes.append(ix)
        }
        heap.setInternalInt(o, Int64(id + 1))
        jsInstallWeakProcessor(self)
        return o
    }

    /// SameValueZero-normalized key (-0 -> +0) and its hash.
    func mapNormalize(_ k: JSValue) -> JSValue {
        if k.isNumber { let d = k.numberValue; return d == 0 ? .int32(0) : .number(d) }
        return k
    }

    func mapHash(_ k: JSValue) -> UInt32 {
        if k.isString, let i = heap.stringCell(k) { return heap.stringHash(i) }
        var x = k.bits &* 0x9E37_79B9_7F4A_7C15
        x ^= x >> 31
        return UInt32(truncatingIfNeeded: x)
    }

    /// Position of key, or -1.
    func mapFind(_ ix: JSMapIndex, _ key: JSValue) -> Int {
        let k = mapNormalize(key)
        let mask = ix.table.count - 1
        var p = Int(mapHash(k)) & mask
        var n = 0
        while n <= mask {
            let e = Int(ix.table[p])
            if e == -1 { return -1 }
            if e >= 0 {
                let stored = heap.slot(ix.owner, e * ix.stride)
                if stored == k || (k.isString && stored.isString && heap.stringsEqual(stored, k)) { return e }
            }
            p = (p + 1) & mask
            n += 1
        }
        return -1
    }

    func mapRehash(_ ix: JSMapIndex) {
        var size = 8
        while size < ix.live * 2 + 8 { size *= 2 }
        var t = [Int32](repeating: -1, count: size)
        let mask = size - 1
        var used = 0
        for e in 0..<ix.entries {
            let k = heap.slot(ix.owner, e * ix.stride)
            if k.isHole { continue }
            var p = Int(mapHash(k)) & mask
            while t[p] != -1 { p = (p + 1) & mask }
            t[p] = Int32(e)
            used += 1
        }
        ix.table = t
        ix.used = used
    }

    /// Insert or update. False when the heap refuses to grow.
    func mapPut(_ ix: JSMapIndex, _ key: JSValue, _ value: JSValue) -> Bool {
        let k = mapNormalize(key)
        let e = mapFind(ix, k)
        if e >= 0 {
            if ix.stride == 2 { heap.setSlot(ix.owner, e * 2 + 1, value) }
            return true
        }
        if ix.entries >= limits.maxDenseArrayLength { return false }
        guard heap.pushSlot(ix.owner, k) else { return false }
        if ix.stride == 2 { guard heap.pushSlot(ix.owner, value) else { return false } }
        let pos = ix.entries
        ix.entries += 1
        ix.live += 1
        if (ix.used + 1) * 2 > ix.table.count {
            mapRehash(ix)
        } else {
            let mask = ix.table.count - 1
            var p = Int(mapHash(k)) & mask
            while ix.table[p] >= 0 { p = (p + 1) & mask }
            if ix.table[p] == -1 { ix.used += 1 }
            ix.table[p] = Int32(pos)
        }
        return true
    }

    func mapRemove(_ ix: JSMapIndex, _ key: JSValue) -> Bool {
        let k = mapNormalize(key)
        let mask = ix.table.count - 1
        var p = Int(mapHash(k)) & mask
        var n = 0
        while n <= mask {
            let e = Int(ix.table[p])
            if e == -1 { return false }
            if e >= 0 {
                let stored = heap.slot(ix.owner, e * ix.stride)
                if stored == k || (k.isString && stored.isString && heap.stringsEqual(stored, k)) {
                    ix.table[p] = -2
                    heap.setSlot(ix.owner, e * ix.stride, .hole)
                    if ix.stride == 2 { heap.setSlot(ix.owner, e * 2 + 1, .undefined) }
                    ix.live -= 1
                    let holes = ix.entries - ix.live
                    if holes > 16 && holes > ix.live { mapCompact(ix) }
                    return true
                }
            }
            p = (p + 1) & mask
            n += 1
        }
        return false
    }

    /// Drop holes; move registered iterators to the same logical place.
    func mapCompact(_ ix: JSMapIndex) {
        var newPos = [Int](repeating: 0, count: ix.entries + 1)
        var vals: [JSValue] = []
        vals.reserveCapacity(ix.live * ix.stride)
        var n = 0
        for e in 0..<ix.entries {
            newPos[e] = n
            let k = heap.slot(ix.owner, e * ix.stride)
            if k.isHole { continue }
            vals.append(k)
            if ix.stride == 2 { vals.append(heap.slot(ix.owner, e * 2 + 1)) }
            n += 1
        }
        newPos[ix.entries] = n
        // Iterators still walking this collection.
        let itKind: JSObjectKind = ix.stride == 2 ? .mapIterator : .setIterator
        var keep: [JSHandle] = []
        for h in ix.iterators {
            let it = JSValue.object(h)
            guard heap.kind(it) == itKind, heap.slot(it, 0) == ix.owner else { continue }
            let pos = Int(heap.internalInt(it))
            heap.setInternalInt(it, Int64(newPos[max(0, min(pos, ix.entries))]))
            keep.append(h)
        }
        ix.iterators = keep
        ix.iteratorsAtPrune = keep.count
        heap.setSlots(ix.owner, vals)
        ix.entries = n
        ix.live = n
        mapRehash(ix)
    }

    func mapClear(_ ix: JSMapIndex) {
        for e in 0..<ix.entries { heap.setSlot(ix.owner, e * ix.stride, .hole) }
        ix.live = 0
        mapCompact(ix)
    }

    func mapRegisterIterator(_ ix: JSMapIndex, _ it: JSValue) {
        ix.iterators.append(it.handle)
        if ix.iterators.count > 2 * ix.iteratorsAtPrune + 32 {
            let itKind: JSObjectKind = ix.stride == 2 ? .mapIterator : .setIterator
            ix.iterators = ix.iterators.filter { h in
                heap.kind(.object(h)) == itKind && heap.slot(.object(h), 0) == ix.owner
            }
            ix.iteratorsAtPrune = ix.iterators.count
        }
    }

    // MARK: this checks

    func thisMap(_ v: JSValue, _ fn: String) throws(JSThrow) -> JSMapIndex {
        guard heap.kind(v) == .map, let ix = mapIndex(v) else {
            throw throwTypeError("Method Map.prototype." + fn + " called on incompatible receiver " + describeForError(v))
        }
        return ix
    }
    func thisSet(_ v: JSValue, _ fn: String) throws(JSThrow) -> JSMapIndex {
        guard heap.kind(v) == .set, let ix = mapIndex(v) else {
            throw throwTypeError("Method Set.prototype." + fn + " called on incompatible receiver " + describeForError(v))
        }
        return ix
    }

    /// Iterator kinds in the flags: user0 keys, user1 values, both entries.
    func newCollectionIterator(_ o: JSValue, _ ix: JSMapIndex, keys: Bool, values: Bool) -> JSValue {
        let r = heap.root(o)
        defer { heap.popRoots(to: r.slot) }
        let isMap = ix.stride == 2
        var f: JSObjectFlags = [.extensible]
        if keys { f.insert(.user0) }
        if values { f.insert(.user1) }
        let it = heap.newObject(proto: intrinsic(isMap ? .mapIteratorPrototype : .setIteratorPrototype),
                                kind: isMap ? .mapIterator : .setIterator, flags: f)
        heap.setSlots(it, [o])
        mapRegisterIterator(ix, it)
        return it
    }

    /// The next entry of a collection iterator: nil when done.
    func collectionIteratorNext(_ it: JSValue) -> (JSValue, JSValue)? {
        let o = heap.slot(it, 0)
        guard o.isObject, let ix = mapIndex(o) else { heap.setSlot(it, 0, .undefined); return nil }
        var pos = Int(heap.internalInt(it))
        while pos < ix.entries {
            let k = heap.slot(o, pos * ix.stride)
            pos += 1
            if k.isHole { continue }
            heap.setInternalInt(it, Int64(pos))
            return (k, ix.stride == 2 ? heap.slot(o, pos * 2 - 1) : k)
        }
        heap.setSlot(it, 0, .undefined)
        return nil
    }

    func makeEntryPair(_ a: JSValue, _ b: JSValue) -> JSValue {
        heap.newArray(proto: arrayPrototype, elements: [a, b])
    }

    /// Calls f(item) for each value an iterable produces, closing the
    /// iterator if f throws.
    func iterate(_ iterable: JSValue, _ f: (JSValue) throws(JSThrow) -> Void) throws(JSThrow) {
        let depth = heap.rootDepth
        defer { heap.popRoots(to: depth) }
        let (it, next) = try getIterator(iterable)
        let ri = heap.root(it)
        let rn = heap.root(next)
        let rv = heap.root(.undefined)
        while true {
            let (done, v) = try iteratorStep(heap[ri], heap[rn])
            if done { return }
            heap[rv] = v
            do throws(JSThrow) {
                try f(v)
            } catch {
                if !isTerminating {
                    let ex = exception
                    let re = heap.root(ex)
                    do throws(JSThrow) { try iteratorClose(heap[ri], heap[rn]) } catch {}
                    exception = heap[re]
                }
                throw error
            }
        }
    }
}

extension JSHeap {
    /// Append one internal slot (counted as growth; false if refused).
    public func pushSlot(_ o: JSValue, _ v: JSValue) -> Bool {
        guard let i = objectIndex(o), noteGrowth(8) else { return false }
        objects[i].slots.append(v)
        return true
    }
}

func jsInstallCollections(_ realm: JSRealm) {
    let heap = realm.heap
    let op = realm.objectPrototype
    let iterKey = JSPropertyKey.symbol(heap.symbolsWellKnown.iterator.handle)
    let tagKey = JSPropertyKey.symbol(heap.symbolsWellKnown.toStringTag.handle)
    let speciesKey = JSPropertyKey.symbol(heap.symbolsWellKnown.species.handle)
    let depth = heap.rootDepth
    defer { heap.popRoots(to: depth) }

    let speciesGetter: JSNativeFunction = { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in args.this }

    // ---------------------------------------------------------------- Map
    let mp = heap.newObject(proto: op)
    _ = heap.root(mp)
    realm.setIntrinsic(.mapPrototype, mp)
    let mapCtor = realm.defineConstructor("Map", length: 0, prototype: mp) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        if !args.isConstruct { throw realm.throwTypeError("Constructor Map requires 'new'") }
        let h = realm.heap
        let proto = try realm.prototype(forNewTarget: args.newTarget, default: .mapPrototype)
        let m = realm.newCollection(proto: proto, set: false)
        let r = h.root(m)
        defer { h.popRoots(to: r.slot) }
        let it = args[0]
        if it.isNullish { return m }
        let adder = try realm.getV(m, h.key("set"))
        guard h.isCallable(adder) else { throw realm.throwTypeError("'set' returned for property 'set' of object '#<Map>' is not a function") }
        _ = h.root(adder)
        try realm.iterate(it) { (entry: JSValue) throws(JSThrow) -> Void in
            guard entry.isObject else { throw realm.throwTypeError("Iterator value " + realm.describeForError(entry) + " is not an entry object") }
            let k = try realm.getV(entry, .index(0))
            let rk = h.root(k)
            let v = try realm.getV(entry, .index(1))
            _ = h.root(v)
            _ = try realm.call(adder, this: m, args: [k, v])
            h.popRoots(to: rk.slot)
        }
        return m
    }
    _ = heap.root(mapCtor)
    realm.setIntrinsic(.mapConstructor, mapCtor)
    realm.defineGetter(mapCtor, "[Symbol.species]", key: speciesKey, speciesGetter)
    realm.defineMethod(mapCtor, "groupBy", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        guard h.isCallable(args[1]) else { throw realm.throwTypeError("callback is not a function") }
        if args[0].isNullish { throw realm.throwTypeError("Map.groupBy called on null or undefined") }
        let m = realm.newCollection(proto: realm.intrinsic(.mapPrototype), set: false)
        let r = h.root(m)
        defer { h.popRoots(to: r.slot) }
        guard let ix = realm.mapIndex(m) else { return m }
        var n = 0.0
        let cb = args[1]
        try realm.iterate(args[0]) { (v: JSValue) throws(JSThrow) -> Void in
            let key = try realm.call(cb, this: .undefined, args: [v, .number(n)])
            n += 1
            let rk = h.root(key)
            defer { h.popRoots(to: rk.slot) }
            let e = realm.mapFind(ix, key)
            var group: JSValue
            if e >= 0 { group = h.slot(m, e * 2 + 1) } else {
                group = h.newArray(proto: realm.arrayPrototype)
                _ = h.root(group)
                if !realm.mapPut(ix, key, group) { throw realm.throwRangeError("Map maximum size exceeded") }
            }
            if !h.createDataProperty(group, .index(h.arrayLength(group)), v) { throw realm.throwRangeError("Invalid array length") }
        }
        return m
    }
    realm.defineMethod(mp, "get", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let ix = try realm.thisMap(args.this, "get")
        let e = realm.mapFind(ix, args[0])
        return e >= 0 ? realm.heap.slot(args.this, e * 2 + 1) : .undefined
    }
    realm.defineMethod(mp, "set", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let ix = try realm.thisMap(args.this, "set")
        if !realm.mapPut(ix, args[0], args[1]) {
            if realm.isTerminating { throw JSThrow() }
            throw realm.throwRangeError("Map maximum size exceeded")
        }
        return args.this
    }
    realm.defineMethod(mp, "has", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        .bool(realm.mapFind(try realm.thisMap(args.this, "has"), args[0]) >= 0)
    }
    realm.defineMethod(mp, "delete", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        .bool(realm.mapRemove(try realm.thisMap(args.this, "delete"), args[0]))
    }
    realm.defineMethod(mp, "clear", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        realm.mapClear(try realm.thisMap(args.this, "clear"))
        return .undefined
    }
    realm.defineGetter(mp, "size") { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        .number(try realm.thisMap(args.this, "size").live)
    }
    func forEach(_ isSet: Bool) -> JSNativeFunction { return { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let ix = isSet ? try realm.thisSet(args.this, "forEach") : try realm.thisMap(args.this, "forEach")
        let f = args[0]
        guard h.isCallable(f) else { throw realm.throwTypeError(realm.describeForError(f) + " is not a function") }
        // Walk like an iterator (registered, so compaction keeps our place).
        let it = realm.newCollectionIterator(args.this, ix, keys: true, values: true)
        let r = h.root(it)
        defer { h.popRoots(to: r.slot) }
        while let (k, v) = realm.collectionIteratorNext(it) {
            let rk = h.root(k)
            _ = h.root(v)
            _ = try realm.call(f, this: args[1], args: [v, k, args.this])
            h.popRoots(to: rk.slot)
        }
        return .undefined
    } }
    realm.defineMethod(mp, "forEach", length: 1, forEach(false))
    realm.defineMethod(mp, "keys", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        realm.newCollectionIterator(args.this, try realm.thisMap(args.this, "keys"), keys: true, values: false)
    }
    realm.defineMethod(mp, "values", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        realm.newCollectionIterator(args.this, try realm.thisMap(args.this, "values"), keys: false, values: true)
    }
    let mapEntries = realm.defineMethod(mp, "entries", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        realm.newCollectionIterator(args.this, try realm.thisMap(args.this, "entries"), keys: true, values: true)
    }
    _ = heap.defineOwnProperty(mp, iterKey, .data(mapEntries, [.writable, .configurable]))
    _ = heap.defineOwnProperty(mp, tagKey, .data(realm.string("Map"), [.configurable]))

    // ---------------------------------------------------------------- Set
    let stp = heap.newObject(proto: op)
    _ = heap.root(stp)
    realm.setIntrinsic(.setPrototype, stp)
    let setCtor = realm.defineConstructor("Set", length: 0, prototype: stp) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        if !args.isConstruct { throw realm.throwTypeError("Constructor Set requires 'new'") }
        let h = realm.heap
        let proto = try realm.prototype(forNewTarget: args.newTarget, default: .setPrototype)
        let s = realm.newCollection(proto: proto, set: true)
        let r = h.root(s)
        defer { h.popRoots(to: r.slot) }
        let it = args[0]
        if it.isNullish { return s }
        let adder = try realm.getV(s, h.key("add"))
        guard h.isCallable(adder) else { throw realm.throwTypeError("'add' of Set is not a function") }
        _ = h.root(adder)
        try realm.iterate(it) { (v: JSValue) throws(JSThrow) -> Void in
            _ = try realm.call(adder, this: s, args: [v])
        }
        return s
    }
    _ = heap.root(setCtor)
    realm.setIntrinsic(.setConstructor, setCtor)
    realm.defineGetter(setCtor, "[Symbol.species]", key: speciesKey, speciesGetter)
    realm.defineMethod(stp, "add", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let ix = try realm.thisSet(args.this, "add")
        if !realm.mapPut(ix, args[0], .undefined) {
            if realm.isTerminating { throw JSThrow() }
            throw realm.throwRangeError("Set maximum size exceeded")
        }
        return args.this
    }
    realm.defineMethod(stp, "has", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        .bool(realm.mapFind(try realm.thisSet(args.this, "has"), args[0]) >= 0)
    }
    realm.defineMethod(stp, "delete", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        .bool(realm.mapRemove(try realm.thisSet(args.this, "delete"), args[0]))
    }
    realm.defineMethod(stp, "clear", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        realm.mapClear(try realm.thisSet(args.this, "clear"))
        return .undefined
    }
    realm.defineGetter(stp, "size") { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        .number(try realm.thisSet(args.this, "size").live)
    }
    realm.defineMethod(stp, "forEach", length: 1, forEach(true))
    let setValues = realm.defineMethod(stp, "values", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        realm.newCollectionIterator(args.this, try realm.thisSet(args.this, "values"), keys: false, values: true)
    }
    _ = heap.defineOwnProperty(stp, heap.key("keys"), .data(setValues, [.writable, .configurable]))
    _ = heap.defineOwnProperty(stp, iterKey, .data(setValues, [.writable, .configurable]))
    realm.defineMethod(stp, "entries", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        realm.newCollectionIterator(args.this, try realm.thisSet(args.this, "entries"), keys: true, values: true)
    }
    _ = heap.defineOwnProperty(stp, tagKey, .data(realm.string("Set"), [.configurable]))
    jsInstallSetMethods(realm, stp)

    // ---------------------------------------------------------- iterators
    for isMap in [true, false] {
        let p = heap.newObject(proto: realm.intrinsic(.iteratorPrototype))
        _ = heap.root(p)
        realm.setIntrinsic(isMap ? .mapIteratorPrototype : .setIteratorPrototype, p)
        realm.defineMethod(p, "next", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let it = args.this
            let h = realm.heap
            guard h.kind(it) == (isMap ? .mapIterator : .setIterator) else {
                throw realm.throwTypeError("next method called on an incompatible receiver " + realm.describeForError(it))
            }
            guard let (k, v) = realm.collectionIteratorNext(it) else { return try realm.iterResult(.undefined, done: true) }
            let f = h.flags(it)
            if f.contains(.user0) && f.contains(.user1) {
                let depth = h.rootDepth
                defer { h.popRoots(to: depth) }
                _ = h.root(k); _ = h.root(v)
                return try realm.iterResult(realm.makeEntryPair(k, v), done: false)
            }
            return try realm.iterResult(f.contains(.user0) ? k : v, done: false)
        }
        _ = heap.defineOwnProperty(p, tagKey, .data(realm.string(isMap ? "Map Iterator" : "Set Iterator"), [.configurable]))
    }
}

/// GetSetRecord: (size, has, keys) of a set-like argument.
struct JSSetRecord {
    var obj: JSValue
    var size: Double
    var has: JSValue
    var keys: JSValue
}

extension JSRealm {
    func getSetRecord(_ o: JSValue) throws(JSThrow) -> JSSetRecord {
        guard o.isObject else { throw throwTypeError("set-like argument must be an object") }
        let rawSize = try getV(o, heap.key("size"))
        let n = try toNumber(rawSize)
        if n.isNaN { throw throwTypeError("set-like size is NaN") }
        let size = jsToIntegerOrInfinity(n)
        if size < 0 { throw throwRangeError("set-like size is negative") }
        let has = try getV(o, heap.key("has"))
        guard heap.isCallable(has) else { throw throwTypeError("set-like 'has' is not a function") }
        _ = heap.root(has)
        let keys = try getV(o, heap.key("keys"))
        guard heap.isCallable(keys) else { throw throwTypeError("set-like 'keys' is not a function") }
        _ = heap.root(keys)
        return JSSetRecord(obj: o, size: size, has: has, keys: keys)
    }

    /// Iterate the set-like's keys() (next read once).
    func iterateSetLikeKeys(_ rec: JSSetRecord, _ f: (JSValue) throws(JSThrow) -> Bool) throws(JSThrow) {
        let depth = heap.rootDepth
        defer { heap.popRoots(to: depth) }
        let it = try call(rec.keys, this: rec.obj, args: [])
        guard it.isObject else { throw throwTypeError("keys() result is not an object") }
        let ri = heap.root(it)
        let next = try getV(it, heap.names.next)
        let rn = heap.root(next)
        let rv = heap.root(.undefined)
        while true {
            let (done, v) = try iteratorStep(heap[ri], heap[rn])
            if done { return }
            heap[rv] = v
            if !(try f(v)) {
                try iteratorClose(heap[ri], heap[rn])
                return
            }
        }
    }

    func setValuesSnapshot(_ ix: JSMapIndex) -> [JSValue] {
        var out: [JSValue] = []
        for e in 0..<ix.entries {
            let k = heap.slot(ix.owner, e)
            if !k.isHole { out.append(k) }
        }
        return out
    }
}

func jsInstallSetMethods(_ realm: JSRealm, _ stp: JSValue) {
    func newSetFrom(_ realm: JSRealm, _ vals: [JSValue]) throws(JSThrow) -> JSValue {
        let h = realm.heap
        let depth = h.rootDepth
        defer { h.popRoots(to: depth) }
        for v in vals { _ = h.root(v) }
        let s = realm.newCollection(proto: realm.intrinsic(.setPrototype), set: true)
        guard let ix = realm.mapIndex(s) else { return s }
        _ = h.root(s)
        for v in vals where !realm.mapPut(ix, v, .undefined) {
            if realm.isTerminating { throw JSThrow() }
            throw realm.throwRangeError("Set maximum size exceeded")
        }
        return s
    }
    realm.defineMethod(stp, "union", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let ix = try realm.thisSet(args.this, "union")
        let depth = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: depth) }
        let rec = try realm.getSetRecord(args[0])
        var vals = realm.setValuesSnapshot(ix)
        for v in vals { _ = realm.heap.root(v) }
        try realm.iterateSetLikeKeys(rec) { (v: JSValue) throws(JSThrow) -> Bool in
            _ = realm.heap.root(v); vals.append(realm.mapNormalize(v)); return true
        }
        return try newSetFrom(realm, vals)
    }
    realm.defineMethod(stp, "intersection", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let ix = try realm.thisSet(args.this, "intersection")
        let depth = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: depth) }
        let rec = try realm.getSetRecord(args[0])
        var out: [JSValue] = []
        if Double(ix.live) <= rec.size {
            var e = 0
            while e < ix.entries {
                let k = realm.heap.slot(ix.owner, e)
                e += 1
                if k.isHole { continue }
                _ = realm.heap.root(k)
                if realm.heap.toBoolean(try realm.call(rec.has, this: rec.obj, args: [k])) { out.append(k) }
            }
        } else {
            try realm.iterateSetLikeKeys(rec) { (v: JSValue) throws(JSThrow) -> Bool in
                if realm.mapFind(ix, v) >= 0 { _ = realm.heap.root(v); out.append(realm.mapNormalize(v)) }
                return true
            }
        }
        return try newSetFrom(realm, out)
    }
    realm.defineMethod(stp, "difference", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let ix = try realm.thisSet(args.this, "difference")
        let depth = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: depth) }
        let rec = try realm.getSetRecord(args[0])
        let res = try newSetFrom(realm, realm.setValuesSnapshot(ix))
        _ = realm.heap.root(res)
        guard let rx = realm.mapIndex(res) else { return res }
        if Double(ix.live) <= rec.size {
            var e = 0
            while e < ix.entries {
                let k = realm.heap.slot(ix.owner, e)
                e += 1
                if k.isHole { continue }
                _ = realm.heap.root(k)
                if realm.heap.toBoolean(try realm.call(rec.has, this: rec.obj, args: [k])) { _ = realm.mapRemove(rx, k) }
            }
        } else {
            try realm.iterateSetLikeKeys(rec) { (v: JSValue) throws(JSThrow) -> Bool in
                _ = realm.mapRemove(rx, v); return true
            }
        }
        return res
    }
    realm.defineMethod(stp, "symmetricDifference", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let ix = try realm.thisSet(args.this, "symmetricDifference")
        let depth = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: depth) }
        let rec = try realm.getSetRecord(args[0])
        let res = try newSetFrom(realm, realm.setValuesSnapshot(ix))
        _ = realm.heap.root(res)
        guard let rx = realm.mapIndex(res) else { return res }
        try realm.iterateSetLikeKeys(rec) { (v: JSValue) throws(JSThrow) -> Bool in
            if realm.mapFind(ix, v) >= 0 { _ = realm.mapRemove(rx, v) } else if !realm.mapPut(rx, v, .undefined) {
                throw realm.throwRangeError("Set maximum size exceeded")
            }
            return true
        }
        return res
    }
    realm.defineMethod(stp, "isSubsetOf", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let ix = try realm.thisSet(args.this, "isSubsetOf")
        let depth = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: depth) }
        let rec = try realm.getSetRecord(args[0])
        if Double(ix.live) > rec.size { return .false }
        var e = 0
        while e < ix.entries {
            let k = realm.heap.slot(ix.owner, e)
            e += 1
            if k.isHole { continue }
            if !realm.heap.toBoolean(try realm.call(rec.has, this: rec.obj, args: [k])) { return .false }
        }
        return .true
    }
    realm.defineMethod(stp, "isSupersetOf", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let ix = try realm.thisSet(args.this, "isSupersetOf")
        let depth = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: depth) }
        let rec = try realm.getSetRecord(args[0])
        if Double(ix.live) < rec.size { return .false }
        var ok = true
        try realm.iterateSetLikeKeys(rec) { (v: JSValue) throws(JSThrow) -> Bool in
            if realm.mapFind(ix, v) < 0 { ok = false; return false }
            return true
        }
        return .bool(ok)
    }
    realm.defineMethod(stp, "isDisjointFrom", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let ix = try realm.thisSet(args.this, "isDisjointFrom")
        let depth = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: depth) }
        let rec = try realm.getSetRecord(args[0])
        if Double(ix.live) <= rec.size {
            var e = 0
            while e < ix.entries {
                let k = realm.heap.slot(ix.owner, e)
                e += 1
                if k.isHole { continue }
                if realm.heap.toBoolean(try realm.call(rec.has, this: rec.obj, args: [k])) { return .false }
            }
            return .true
        }
        var ok = true
        try realm.iterateSetLikeKeys(rec) { (v: JSValue) throws(JSThrow) -> Bool in
            if realm.mapFind(ix, v) >= 0 { ok = false; return false }
            return true
        }
        return .bool(ok)
    }
}
