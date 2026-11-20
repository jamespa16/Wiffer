// Array constructor statics and Array.prototype (ROADMAP Phase 9C, ES2023).
//
// Every prototype method is generic over array-likes (it reads `length`
// and goes through Get/Has/Set/Delete), with dense fast paths for plain
// arrays underneath the element primitives (arrGet, arrHas, arrDefine) and
// a few whole-array shortcuts (push, pop, shift, ...) that apply only when
// the array is dense without holes. Loops tick the interrupt budget so a
// script cannot hang inside a native method.
//
// The helpers are shared with the other 9C files:
//   realm.arrGet / arrHas / arrSet / arrDelete / arrDefine / arrLength
//   realm.jsIsArray(v), realm.jsSpeciesCreate(original, length)
//   heap.plainDenseElements(o) -> [JSValue]?   (dense array without holes)

extension JSHeap {
    /// A present dense element (nil when absent, a hole or not stored
    /// densely): no getter can be involved.
    @inline(__always) func denseElement(_ o: JSValue, _ i: Int) -> JSValue? {
        let h = Int(o.handle)
        guard o.isObject, h > 0, h < objects.count, i >= 0, i < objects[h].elements.count else { return nil }
        let v = objects[h].elements[i]
        return v.isHole ? nil : v
    }

    /// The elements of an Array object whose store is fully dense: no
    /// holes, no sparse part, length equal to the element count, a
    /// writable length.
    func plainDenseElements(_ o: JSValue) -> [JSValue]? {
        guard let i = objectIndex(o), objects[i].kind == .array, objects[i].sparse.isEmpty,
              !objects[i].flags.contains(.lengthReadOnly),
              Int(objects[i].arrayLength) == objects[i].elements.count else { return nil }
        for v in objects[i].elements where v.isHole { return nil }
        return objects[i].elements
    }

    /// Replace the element store of a plain dense array (the caller checked
    /// plainDenseElements and that the array may grow).
    func replaceDenseElements(_ o: JSValue, _ e: [JSValue]) -> Bool {
        guard let i = objectIndex(o), objects[i].kind == .array, e.count <= limits.maxDenseArrayLength else { return false }
        if e.count > objects[i].elements.count {
            guard objects[i].flags.contains(.extensible), noteGrowth((e.count - objects[i].elements.count) * 8) else { return false }
        }
        objects[i].elements = e
        objects[i].arrayLength = UInt32(e.count)
        return true
    }

    /// True when no object on o's prototype chain has index properties (so a
    /// Set of a new index cannot reach a setter or a read-only property).
    func protoChainIndexFree(_ o: JSValue) -> Bool {
        guard let i = objectIndex(o) else { return false }
        var cur = objects[i].proto
        var n = 0
        while let j = objectIndex(cur) {
            if !objects[j].elements.isEmpty || !objects[j].sparse.isEmpty { return false }
            let k = objects[j].kind
            if k == .proxy || k == .stringWrapper || k == .typedArray { return false }
            cur = objects[j].proto
            n += 1
            if n > 64 { return false }
        }
        return true
    }

    /// Append at index == length of an extensible plain array.
    func appendDense(_ o: JSValue, _ idx: Int, _ v: JSValue) -> Bool {
        guard let i = objectIndex(o), objects[i].kind == .array, objects[i].flags.contains(.extensible),
              !objects[i].flags.contains(.lengthReadOnly), Int(objects[i].arrayLength) == idx,
              objects[i].elements.count == idx, idx < limits.maxDenseArrayLength, idx < 0xFFFF_FFFE,
              noteGrowth(8) else { return false }
        objects[i].elements.append(v)
        objects[i].arrayLength = UInt32(idx + 1)
        return true
    }
}

let jsMaxSafeInteger = 9007199254740991

extension JSRealm {
    // MARK: Element primitives

    func arrGet(_ o: JSValue, _ i: Int) throws(JSThrow) -> JSValue {
        if let v = heap.denseElement(o, i) { return v }
        return try getV(o, try jsIndexKey(i))
    }

    func arrHas(_ o: JSValue, _ i: Int) throws(JSThrow) -> Bool {
        if heap.denseElement(o, i) != nil { return true }
        return heap.hasProperty(o, try jsIndexKey(i))
    }

    /// Set(O, i, v, true).
    func arrSet(_ o: JSValue, _ i: Int, _ v: JSValue) throws(JSThrow) {
        try setV(o, try jsIndexKey(i), v, strict: true)
    }

    /// DeletePropertyOrThrow.
    func arrDelete(_ o: JSValue, _ i: Int) throws(JSThrow) {
        let k = try jsIndexKey(i)
        if !heap.deleteProperty(o, k) {
            try jsCheckAlloc()
            throw throwTypeError("Cannot delete property '" + keyDisplay(k) + "' of " + describeForError(o))
        }
    }

    /// CreateDataPropertyOrThrow.
    func arrDefine(_ o: JSValue, _ i: Int, _ v: JSValue) throws(JSThrow) {
        if heap.appendDense(o, i, v) { return }
        let k = try jsIndexKey(i)
        if !heap.createDataProperty(o, k, v) {
            try jsCheckAlloc()
            throw throwTypeError("Cannot add property " + keyDisplay(k) + ", object is not extensible")
        }
    }

    /// LengthOfArrayLike.
    func arrLength(_ o: JSValue) throws(JSThrow) -> Int {
        if heap.kind(o) == .array { return Int(heap.arrayLength(o)) }
        return try toLength(try getV(o, heap.names.length))
    }

    func arrSetLength(_ o: JSValue, _ n: Int) throws(JSThrow) {
        if heap.kind(o) == .array && heap.flags(o).contains(.lengthReadOnly) {
            throw throwTypeError("Cannot assign to read only property 'length' of object '[object Array]'")
        }
        try setV(o, heap.names.length, .number(n), strict: true)
    }

    func jsIsArray(_ v: JSValue) -> Bool { v.isObject && heap.kind(v) == .array }

    func jsIsConstructor(_ v: JSValue) -> Bool {
        v.isObject && heap.flags(v).contains(.constructor)
    }

    /// ArrayCreate(length).
    func jsArrayCreate(_ len: Int) throws(JSThrow) -> JSValue {
        guard len <= 0xFFFF_FFFF, let n = UInt32(exactly: len) else { throw throwRangeError("Invalid array length") }
        let a = jsNewArray()
        if n > 0 {
            let r = heap.root(a)
            defer { heap.popRoots(to: r.slot) }
            if !heap.setArrayLength(a, n) { try jsCheckAlloc(); throw throwRangeError("Invalid array length") }
        }
        try jsCheckAlloc()
        return a
    }

    /// ArraySpeciesCreate.
    func jsSpeciesCreate(_ orig: JSValue, _ len: Int) throws(JSThrow) -> JSValue {
        if !jsIsArray(orig) { return try jsArrayCreate(len) }
        let h = heap
        let depth = h.rootDepth
        defer { h.popRoots(to: depth) }
        var c = try getV(orig, h.names.constructor)
        _ = h.root(c)
        if c.isObject {
            if c == intrinsic(.arrayConstructor) { return try jsArrayCreate(len) }
            c = try getV(c, .symbol(h.symbolsWellKnown.species.handle))
            _ = h.root(c)
            if c.isNull { c = .undefined }
        }
        if c.isUndefined { return try jsArrayCreate(len) }
        guard jsIsConstructor(c) else { throw throwTypeError("object.constructor[Symbol.species] is not a constructor") }
        let r = try construct(c, args: [.number(len)])
        guard r.isObject else { throw throwTypeError("species constructor did not return an object") }
        return r
    }

    /// Clamp a ToIntegerOrInfinity result into 0...len (relative indices:
    /// negative values count from the end).
    func jsRelIndex(_ v: JSValue, _ len: Int, _ dflt: Int) throws(JSThrow) -> Int {
        if v.isUndefined { return dflt }
        let d = jsToIntegerOrInfinity(try toNumber(v))
        if d < 0 {
            let r = Double(len) + d
            return r < 0 ? 0 : Int(r)
        }
        return d > Double(len) ? len : Int(d)
    }

    func jsCallable(_ v: JSValue, _ what: String) throws(JSThrow) {
        guard heap.isCallable(v) else { throw throwTypeError(describeForError(v) + " is not a function") }
    }

    /// Append a string value to a builder (range checked by the caller).
    func jsAppend(_ b: inout JSStringBuilder, _ s: JSValue) {
        if let bytes = heap.latin1Bytes(s) {
            b.append(ascii: bytes)
        } else {
            for u in heap.stringUnits(s) { b.append(unit: u) }
        }
    }

    func jsTick(_ n: Int) throws(JSThrow) {
        if n & 1023 == 1023 { try checkInterrupt() }
    }
}

/// Rooted context of a generic Array method call.
struct JSArrCtx {
    var depth: Int
    var o: JSValue
    var len: Int
}

extension JSRealm {
    /// ToObject(this) rooted, plus its length. Pop with
    /// `defer { heap.popRoots(to: c.depth) }`.
    func jsArrEnter(_ args: JSArgs) throws(JSThrow) -> JSArrCtx {
        let depth = heap.rootDepth
        do throws(JSThrow) {
            let o = try toObject(args.this)
            _ = heap.root(o)
            let len = try arrLength(o)
            return JSArrCtx(depth: depth, o: o, len: len)
        } catch {
            heap.popRoots(to: depth)
            throw error
        }
    }

    // MARK: Sorting

    /// Stable merge sort of `a` (indices into the caller's data); `gt(x, y)`
    /// is true when x must come after y.
    func jsMergeSort(_ a: inout [Int], _ gt: (Int, Int) throws(JSThrow) -> Bool) throws(JSThrow) {
        let n = a.count
        if n < 2 { return }
        var src = a
        var dst = a
        var width = 1
        // Insertion-sort runs of 8 first.
        let run = 8
        var s = 0
        while s < n {
            let e = min(s + run, n)
            var i = s + 1
            while i < e {
                let x = src[i]
                var j = i - 1
                while j >= s {
                    if try gt(src[j], x) { src[j + 1] = src[j]; j -= 1 } else { break }
                }
                src[j + 1] = x
                i += 1
            }
            s = e
        }
        width = run
        while width < n {
            var lo = 0
            while lo < n {
                let mid = min(lo + width, n), hi = min(lo + 2 * width, n)
                var i = lo, j = mid, k = lo
                while i < mid && j < hi {
                    if try gt(src[i], src[j]) { dst[k] = src[j]; j += 1 } else { dst[k] = src[i]; i += 1 }
                    k += 1
                }
                while i < mid { dst[k] = src[i]; i += 1; k += 1 }
                while j < hi { dst[k] = src[j]; j += 1; k += 1 }
                lo = hi
            }
            swap(&src, &dst)
            width *= 2
        }
        a = src
    }

    /// Sort `items` (rooted by the caller) per SortCompare; returns the
    /// sorted values. Undefined values go last without comparison.
    func jsSortValues(_ items: [JSValue], _ cmp: JSValue) throws(JSThrow) -> [JSValue] {
        let h = heap
        let depth = h.rootDepth
        defer { h.popRoots(to: depth) }
        // Hold every item (and key string) on the root stack.
        let holder = h.newArray(proto: arrayPrototype, elements: items)
        _ = h.root(holder)
        try jsCheckAlloc()
        var idx: [Int] = []
        var undefs: [Int] = []
        idx.reserveCapacity(items.count)
        for i in 0..<items.count {
            if items[i].isUndefined { undefs.append(i) } else { idx.append(i) }
        }
        if cmp.isUndefined {
            var keys = [JSValue](repeating: .undefined, count: items.count)
            var allInt = true
            for i in idx where !(items[i].isInt32) { allInt = false; break }
            if !allInt {
                let kh = h.newArray(proto: arrayPrototype)
                _ = h.root(kh)
                for i in idx {
                    let k = try toStringValue(items[i])
                    keys[i] = k
                    _ = h.createDataProperty(kh, .index(UInt32(truncatingIfNeeded: i)), k)
                    try jsCheckAlloc()
                }
            }
            var ticks = 0
            if allInt {
                // Compare ints as decimal strings without allocating.
                try jsMergeSort(&idx) { (x: Int, y: Int) throws(JSThrow) -> Bool in
                    ticks += 1
                    if ticks & 0xFFFF == 0 { try self.checkInterrupt() }
                    return jsCompareIntStrings(items[x].asInt32, items[y].asInt32) > 0
                }
            } else {
                try jsMergeSort(&idx) { (x: Int, y: Int) throws(JSThrow) -> Bool in
                    ticks += 1
                    if ticks & 0xFFFF == 0 { try self.checkInterrupt() }
                    return h.compareStrings(keys[x], keys[y]) > 0
                }
            }
        } else {
            try jsMergeSort(&idx) { (x: Int, y: Int) throws(JSThrow) -> Bool in
                let r = try self.call(cmp, this: .undefined, args: [items[x], items[y]])
                let d = try self.toNumber(r)
                return d > 0
            }
        }
        var out: [JSValue] = []
        out.reserveCapacity(items.count)
        for i in idx { out.append(items[i]) }
        for i in undefs { out.append(items[i]) }
        return out
    }
}

/// Order of two int32 values compared as their decimal strings.
func jsCompareIntStrings(_ a: Int32, _ b: Int32) -> Int {
    if a == b { return 0 }
    func digits(_ v: Int32) -> [UInt8] {
        var out: [UInt8] = []
        var m = v < 0 ? UInt32(bitPattern: 0 &- v) : UInt32(v)
        if v == Int32.min { m = 2147483648 }
        if m == 0 { out.append(0x30) }
        while m > 0 { out.append(UInt8(0x30 + m % 10)); m /= 10 }
        if v < 0 { out.append(0x2D) }
        out.reverse()
        return out
    }
    let x = digits(a), y = digits(b)
    var i = 0
    while i < x.count && i < y.count {
        if x[i] != y[i] { return x[i] < y[i] ? -1 : 1 }
        i += 1
    }
    return x.count == y.count ? 0 : (x.count < y.count ? -1 : 1)
}

func jsInstallArray(_ realm: JSRealm) {
    let heap = realm.heap
    let ap = realm.arrayPrototype
    let ac = realm.intrinsic(.arrayConstructor)
    let iterKey = JSPropertyKey.symbol(heap.symbolsWellKnown.iterator.handle)
    let tagKey = JSPropertyKey.symbol(heap.symbolsWellKnown.toStringTag.handle)

    // ------------------------------------------------------------ statics
    realm.defineMethod(ac, "isArray", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        .bool(realm.jsIsArray(args[0]))
    }
    realm.defineGetter(ac, "[Symbol.species]", key: .symbol(heap.symbolsWellKnown.species.handle)) {
        (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in args.this
    }
    realm.defineMethod(ac, "of", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let depth = h.rootDepth
        defer { h.popRoots(to: depth) }
        let n = args.count
        var a: JSValue
        if realm.jsIsConstructor(args.this) {
            a = try realm.construct(args.this, args: [.number(n)])
            guard a.isObject else { throw realm.throwTypeError("constructor did not return an object") }
        } else {
            a = try realm.jsArrayCreate(n)
        }
        _ = h.root(a)
        for i in 0..<n { try realm.arrDefine(a, i, args[i]) }
        try realm.arrSetLength(a, n)
        return a
    }
    realm.defineMethod(ac, "from", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let depth = h.rootDepth
        defer { h.popRoots(to: depth) }
        let c = args.this
        let items = args[0], mapFn = args[1], thisArg = args[2]
        let mapping = !mapFn.isUndefined
        if mapping { try realm.jsCallable(mapFn, "mapfn") }
        if items.isNullish { throw realm.throwTypeError(realm.describeForError(items) + " is not iterable") }
        let m = try realm.getV(items, iterKey)
        _ = h.root(m)
        if !m.isNullish {
            guard h.isCallable(m) else { throw realm.throwTypeError("Symbol.iterator is not a function") }
            var a: JSValue
            if realm.jsIsConstructor(c) {
                a = try realm.construct(c, args: [])
                guard a.isObject else { throw realm.throwTypeError("constructor did not return an object") }
            } else {
                a = realm.jsNewArray()
            }
            _ = h.root(a)
            var it: JSValue, next: JSValue
            if m == realm.intrinsic(.arrayValues) && items.isObject && h.kind(items) == .array {
                it = h.newObject(proto: .null, kind: .iterator)
                _ = h.root(it)
                h.setSlots(it, [items])
                next = .hole
            } else {
                it = try realm.call(m, this: items, args: [])
                _ = h.root(it)
                guard it.isObject else { throw realm.throwTypeError("Result of the Symbol.iterator method is not an object") }
                next = try realm.getV(it, h.names.next)
                _ = h.root(next)
            }
            var k = 0
            while true {
                let (done, v) = try realm.iteratorStep(it, next)
                if done { break }
                let d2 = h.rootDepth
                _ = h.root(v)
                do throws(JSThrow) {
                    var mv = v
                    if mapping {
                        mv = try realm.call(mapFn, this: thisArg, args: [v, .number(k)])
                        _ = h.root(mv)
                    }
                    try realm.arrDefine(a, k, mv)
                } catch {
                    if !realm.isTerminating {
                        let saved = realm.exception
                        _ = h.root(saved)
                        try? realm.iteratorClose(it, next)
                        realm.exception = saved
                    }
                    throw error
                }
                h.popRoots(to: d2)
                k += 1
                try realm.jsTick(k)
            }
            try realm.arrSetLength(a, k)
            return a
        }
        let src = try realm.toObject(items)
        _ = h.root(src)
        let len = try realm.arrLength(src)
        var a: JSValue
        if realm.jsIsConstructor(c) {
            a = try realm.construct(c, args: [.number(len)])
            guard a.isObject else { throw realm.throwTypeError("constructor did not return an object") }
        } else {
            a = try realm.jsArrayCreate(len)
        }
        _ = h.root(a)
        let sr = h.root(.undefined)
        for k in 0..<len {
            var v = try realm.arrGet(src, k)
            h[sr] = v
            if mapping { v = try realm.call(mapFn, this: thisArg, args: [v, .number(k)]); h[sr] = v }
            try realm.arrDefine(a, k, v)
            try realm.jsTick(k)
        }
        try realm.arrSetLength(a, len)
        return a
    }

    // ---------------------------------------------------- array iterators
    // keys()/entries() iterators: kind .iterator with user1 (keys) or user2
    // (entries); values() iterators are the base ones.
    func makeIterator(_ realm: JSRealm, _ this: JSValue, _ flag: JSObjectFlags) throws(JSThrow) -> JSValue {
        let o = try realm.toObject(this)
        let r = realm.heap.root(o)
        defer { realm.heap.popRoots(to: r.slot) }
        var fl: JSObjectFlags = [.extensible]
        fl.formUnion(flag)
        let it = realm.heap.newObject(proto: realm.intrinsic(.arrayIteratorPrototype), kind: .iterator, flags: fl)
        realm.heap.setSlots(it, [o])
        return it
    }
    realm.defineMethod(ap, "keys", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        try makeIterator(realm, args.this, .user1)
    }
    realm.defineMethod(ap, "entries", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        try makeIterator(realm, args.this, .user2)
    }
    realm.defineMethod(realm.intrinsic(.arrayIteratorPrototype), "next", length: 0) {
        (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let it = args.this
        let h = realm.heap
        guard h.kind(it) == .iterator, !h.flags(it).contains(.user3) else {
            throw realm.throwTypeError("next method called on an incompatible receiver")
        }
        let fl = h.flags(it)
        if !fl.contains(.user1) && !fl.contains(.user2) {
            let (done, v) = try realm.iteratorStep(it, .hole)
            return try realm.iterResult(v, done: done)
        }
        let src = h.slot(it, 0)
        let i = Int(h.internalInt(it))
        if src.isUndefined { return try realm.iterResult(.undefined, done: true) }
        let len = try realm.arrLength(src)
        if i >= len {
            h.setSlot(it, 0, .undefined)
            return try realm.iterResult(.undefined, done: true)
        }
        h.setInternalInt(it, Int64(i + 1))
        if fl.contains(.user1) { return try realm.iterResult(.number(i), done: false) }
        let v = try realm.arrGet(src, i)
        let pair = h.root(v)
        defer { h.popRoots(to: pair.slot) }
        let e = realm.jsNewArray([.number(i), v])
        return try realm.iterResult(e, done: false)
    }

    // ------------------------------------------------------------ push/pop
    realm.defineMethod(ap, "push", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let c = try realm.jsArrEnter(args)
        defer { h.popRoots(to: c.depth) }
        let o = c.o
        var n = c.len
        if n + args.count > jsMaxSafeInteger { throw realm.throwTypeError("Pushing " + String(args.count) + " elements on an array-like of length " + String(n) + " is disallowed, as the total surpasses 2**53-1") }
        let free = h.protoChainIndexFree(o)
        for i in 0..<args.count {
            if free && h.appendDense(o, n, args[i]) { n += 1; continue }
            try realm.arrSet(o, n, args[i])
            n += 1
        }
        try realm.jsCheckAlloc()
        try realm.arrSetLength(o, n)
        return .number(n)
    }
    realm.defineMethod(ap, "pop", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let c = try realm.jsArrEnter(args)
        defer { h.popRoots(to: c.depth) }
        if c.len == 0 {
            try realm.arrSetLength(c.o, 0)
            return .undefined
        }
        let v = try realm.arrGet(c.o, c.len - 1)
        _ = h.root(v)
        try realm.arrDelete(c.o, c.len - 1)
        try realm.arrSetLength(c.o, c.len - 1)
        return v
    }
    realm.defineMethod(ap, "shift", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let c = try realm.jsArrEnter(args)
        defer { h.popRoots(to: c.depth) }
        let o = c.o, len = c.len
        if len == 0 {
            try realm.arrSetLength(o, 0)
            return .undefined
        }
        if var e = h.plainDenseElements(o), e.count == len {
            let first = e.removeFirst()
            if h.replaceDenseElements(o, e) { return first }
        }
        let first = try realm.arrGet(o, 0)
        _ = h.root(first)
        let sr = h.root(.undefined)
        var k = 1
        while k < len {
            if try realm.arrHas(o, k) {
                let v = try realm.arrGet(o, k)
                h[sr] = v
                try realm.arrSet(o, k - 1, v)
            } else {
                try realm.arrDelete(o, k - 1)
            }
            try realm.jsTick(k)
            k += 1
        }
        try realm.arrDelete(o, len - 1)
        try realm.arrSetLength(o, len - 1)
        return first
    }
    realm.defineMethod(ap, "unshift", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let c = try realm.jsArrEnter(args)
        defer { h.popRoots(to: c.depth) }
        let o = c.o, len = c.len, argc = args.count
        if argc > 0 {
            if len + argc > jsMaxSafeInteger { throw realm.throwTypeError("Invalid array length") }
            if var e = h.plainDenseElements(o), e.count == len, len + argc < h.limits.maxDenseArrayLength {
                e.insert(contentsOf: args.values, at: 0)
                if h.replaceDenseElements(o, e) { return .number(e.count) }
            }
            let sr = h.root(.undefined)
            var k = len
            while k > 0 {
                if try realm.arrHas(o, k - 1) {
                    let v = try realm.arrGet(o, k - 1)
                    h[sr] = v
                    try realm.arrSet(o, k + argc - 1, v)
                } else {
                    try realm.arrDelete(o, k + argc - 1)
                }
                try realm.jsTick(k)
                k -= 1
            }
            for j in 0..<argc { try realm.arrSet(o, j, args[j]) }
        }
        try realm.arrSetLength(o, len + argc)
        return .number(len + argc)
    }

    // ------------------------------------------------------------- concat
    realm.defineMethod(ap, "concat", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let c = try realm.jsArrEnter(args)
        defer { h.popRoots(to: c.depth) }
        let a = try realm.jsSpeciesCreate(c.o, 0)
        _ = h.root(a)
        var n = 0
        let spreadKey = JSPropertyKey.symbol(h.symbolsWellKnown.isConcatSpreadable.handle)
        let sr = h.root(.undefined)
        for ai in -1..<args.count {
            let e = ai < 0 ? c.o : args[ai]
            var spreadable = false
            if e.isObject {
                let s = try realm.getV(e, spreadKey)
                spreadable = s.isUndefined ? realm.jsIsArray(e) : h.toBoolean(s)
            }
            if spreadable {
                let len = try realm.arrLength(e)
                if n + len > jsMaxSafeInteger { throw realm.throwTypeError("Invalid array length") }
                if let src = h.plainDenseElements(e), src.count == len, n == Int(h.arrayLength(a)), h.kind(a) == .array,
                   h.denseElement(a, n) == nil, len > 0, h.appendDense(a, n, src[0]) {
                    var j = 1
                    while j < len {
                        if !h.appendDense(a, n + j, src[j]) { try realm.arrDefine(a, n + j, src[j]) }
                        j += 1
                    }
                    n += len
                    continue
                }
                var k = 0
                while k < len {
                    if try realm.arrHas(e, k) {
                        let v = try realm.arrGet(e, k)
                        h[sr] = v
                        try realm.arrDefine(a, n, v)
                    }
                    n += 1
                    k += 1
                    try realm.jsTick(k)
                }
            } else {
                if n >= jsMaxSafeInteger { throw realm.throwTypeError("Invalid array length") }
                try realm.arrDefine(a, n, e)
                n += 1
            }
        }
        try realm.arrSetLength(a, n)
        return a
    }

    // --------------------------------------------------------- copyWithin
    realm.defineMethod(ap, "copyWithin", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let c = try realm.jsArrEnter(args)
        defer { h.popRoots(to: c.depth) }
        let o = c.o, len = c.len
        var to = try realm.jsRelIndex(args[0], len, 0)
        var from = try realm.jsRelIndex(args[1], len, 0)
        let fin = try realm.jsRelIndex(args[2], len, len)
        var count = min(fin - from, len - to)
        var dir = 1
        if from < to && to < from + count {
            dir = -1
            from += count - 1
            to += count - 1
        }
        let sr = h.root(.undefined)
        var n = 0
        while count > 0 {
            if try realm.arrHas(o, from) {
                let v = try realm.arrGet(o, from)
                h[sr] = v
                try realm.arrSet(o, to, v)
            } else {
                try realm.arrDelete(o, to)
            }
            from += dir
            to += dir
            count -= 1
            n += 1
            try realm.jsTick(n)
        }
        return o
    }

    // --------------------------------------------------------------- fill
    realm.defineMethod(ap, "fill", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let c = try realm.jsArrEnter(args)
        defer { h.popRoots(to: c.depth) }
        let o = c.o, len = c.len
        var k = try realm.jsRelIndex(args[1], len, 0)
        let fin = try realm.jsRelIndex(args[2], len, len)
        var n = 0
        while k < fin {
            try realm.arrSet(o, k, args[0])
            k += 1
            n += 1
            try realm.jsTick(n)
        }
        return o
    }

    // ------------------------------------ every/some/forEach/map/filter
    // kind: 0 every, 1 some, 2 forEach, 3 map, 4 filter
    func iterMethod(_ kind: Int) -> JSNativeFunction {
        return { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let h = realm.heap
            let c = try realm.jsArrEnter(args)
            defer { h.popRoots(to: c.depth) }
            let o = c.o, len = c.len
            let cb = args[0], thisArg = args[1]
            try realm.jsCallable(cb, "callback")
            var a: JSValue = .undefined
            if kind == 3 { a = try realm.jsSpeciesCreate(o, len); _ = h.root(a) }
            else if kind == 4 { a = try realm.jsSpeciesCreate(o, 0); _ = h.root(a) }
            let sr = h.root(.undefined)
            var to = 0
            var k = 0
            while k < len {
                if try realm.arrHas(o, k) {
                    let v = try realm.arrGet(o, k)
                    h[sr] = v
                    let r = try realm.call(cb, this: thisArg, args: [v, .number(k), o])
                    switch kind {
                    case 0: if !h.toBoolean(r) { return .false }
                    case 1: if h.toBoolean(r) { return .true }
                    case 2: break
                    case 3:
                        _ = h.root(r)
                        try realm.arrDefine(a, k, r)
                    default:
                        if h.toBoolean(r) { try realm.arrDefine(a, to, v); to += 1 }
                    }
                }
                k += 1
                try realm.jsTick(k)
            }
            switch kind {
            case 0: return .true
            case 1: return .false
            case 2: return .undefined
            default: return a
            }
        }
    }
    realm.defineMethod(ap, "every", length: 1, iterMethod(0))
    realm.defineMethod(ap, "some", length: 1, iterMethod(1))
    realm.defineMethod(ap, "forEach", length: 1, iterMethod(2))
    realm.defineMethod(ap, "map", length: 1, iterMethod(3))
    realm.defineMethod(ap, "filter", length: 1, iterMethod(4))

    // ------------------------------------------------------ find family
    // mode: 0 find, 1 findIndex, 2 findLast, 3 findLastIndex
    func findMethod(_ mode: Int) -> JSNativeFunction {
        return { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let h = realm.heap
            let c = try realm.jsArrEnter(args)
            defer { h.popRoots(to: c.depth) }
            let o = c.o, len = c.len
            let cb = args[0], thisArg = args[1]
            try realm.jsCallable(cb, "predicate")
            let last = mode >= 2
            let sr = h.root(.undefined)
            var n = 0
            var k = last ? len - 1 : 0
            while last ? k >= 0 : k < len {
                let v = try realm.arrGet(o, k)
                h[sr] = v
                let r = try realm.call(cb, this: thisArg, args: [v, .number(k), o])
                if h.toBoolean(r) { return mode & 1 == 1 ? .number(k) : v }
                k += last ? -1 : 1
                n += 1
                try realm.jsTick(n)
            }
            return mode & 1 == 1 ? .number(-1) : .undefined
        }
    }
    realm.defineMethod(ap, "find", length: 1, findMethod(0))
    realm.defineMethod(ap, "findIndex", length: 1, findMethod(1))
    realm.defineMethod(ap, "findLast", length: 1, findMethod(2))
    realm.defineMethod(ap, "findLastIndex", length: 1, findMethod(3))

    // ------------------------------------------------------ flat/flatMap
    func flatten(_ realm: JSRealm, _ target: JSValue, _ source: JSValue, _ sourceLen: Int, _ start: Int,
                 _ depth: Double, _ mapper: JSValue, _ thisArg: JSValue) throws(JSThrow) -> Int {
        let h = realm.heap
        try realm.enterNative()
        let rd = h.rootDepth
        defer { h.popRoots(to: rd) }
        let sr = h.root(.undefined)
        var targetIndex = start
        var k = 0
        while k < sourceLen {
            if try realm.arrHas(source, k) {
                var el = try realm.arrGet(source, k)
                h[sr] = el
                if !mapper.isUndefined {
                    el = try realm.call(mapper, this: thisArg, args: [el, .number(k), source])
                    h[sr] = el
                }
                if depth > 0 && realm.jsIsArray(el) {
                    let n = try realm.arrLength(el)
                    targetIndex = try flatten(realm, target, el, n, targetIndex, depth - 1, .undefined, .undefined)
                } else {
                    if targetIndex >= jsMaxSafeInteger { throw realm.throwTypeError("Invalid array length") }
                    try realm.arrDefine(target, targetIndex, el)
                    targetIndex += 1
                }
            }
            k += 1
            try realm.jsTick(k)
        }
        return targetIndex
    }
    realm.defineMethod(ap, "flat", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let c = try realm.jsArrEnter(args)
        defer { h.popRoots(to: c.depth) }
        var depth = 1.0
        if !args[0].isUndefined {
            depth = jsToIntegerOrInfinity(try realm.toNumber(args[0]))
            if depth < 0 { depth = 0 }
        }
        let a = try realm.jsSpeciesCreate(c.o, 0)
        _ = h.root(a)
        _ = try flatten(realm, a, c.o, c.len, 0, depth, .undefined, .undefined)
        return a
    }
    realm.defineMethod(ap, "flatMap", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let c = try realm.jsArrEnter(args)
        defer { h.popRoots(to: c.depth) }
        try realm.jsCallable(args[0], "mapper")
        let a = try realm.jsSpeciesCreate(c.o, 0)
        _ = h.root(a)
        _ = try flatten(realm, a, c.o, c.len, 0, 1, args[0], args[1])
        return a
    }

    // ------------------------------------------ includes/indexOf/lastIndexOf
    realm.defineMethod(ap, "includes", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let c = try realm.jsArrEnter(args)
        defer { h.popRoots(to: c.depth) }
        if c.len == 0 { return .false }
        var k = try realm.jsRelIndex(args[1], c.len, 0)
        while k < c.len {
            let v = try realm.arrGet(c.o, k)
            if h.sameValueZero(v, args[0]) { return .true }
            k += 1
            try realm.jsTick(k)
        }
        return .false
    }
    realm.defineMethod(ap, "indexOf", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let c = try realm.jsArrEnter(args)
        defer { h.popRoots(to: c.depth) }
        if c.len == 0 { return .number(-1) }
        var k = try realm.jsRelIndex(args[1], c.len, 0)
        while k < c.len {
            if try realm.arrHas(c.o, k) {
                let v = try realm.arrGet(c.o, k)
                if h.strictEquals(v, args[0]) { return .number(k) }
            }
            k += 1
            try realm.jsTick(k)
        }
        return .number(-1)
    }
    realm.defineMethod(ap, "lastIndexOf", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let c = try realm.jsArrEnter(args)
        defer { h.popRoots(to: c.depth) }
        if c.len == 0 { return .number(-1) }
        var k = c.len - 1
        if args.count > 1 {
            let d = jsToIntegerOrInfinity(try realm.toNumber(args[1]))
            if d == -Double.infinity { return .number(-1) }
            if d >= 0 { k = d >= Double(c.len - 1) ? c.len - 1 : Int(d) }
            else {
                let r = Double(c.len) + d
                if r < 0 { return .number(-1) }
                k = Int(r)
            }
        }
        while k >= 0 {
            if try realm.arrHas(c.o, k) {
                let v = try realm.arrGet(c.o, k)
                if h.strictEquals(v, args[0]) { return .number(k) }
            }
            k -= 1
            try realm.jsTick(k)
        }
        return .number(-1)
    }

    // ---------------------------------------------------------- join etc.
    func joinImpl(_ realm: JSRealm, _ o: JSValue, _ len: Int, _ sep: JSValue, locale: Bool) throws(JSThrow) -> JSValue {
        let h = realm.heap
        // Cycle detection: objects currently being joined.
        let stack = realm.intrinsic(.arrayJoinStack)
        let depthNow = Int(h.arrayLength(stack))
        for i in 0..<depthNow where h.denseElement(stack, i) == o { return .string(0) }
        if depthNow >= 1000 { throw realm.throwRangeError("Maximum call stack size exceeded") }
        _ = h.createDataProperty(stack, .index(UInt32(depthNow)), o)
        defer { _ = h.setArrayLength(stack, UInt32(depthNow)) }
        let rd = h.rootDepth
        defer { h.popRoots(to: rd) }
        var sepUnits: JSValue = h.atom(",")
        if !sep.isUndefined { sepUnits = try realm.toStringValue(sep) }
        _ = h.root(sepUnits)
        var b = JSStringBuilder()
        let sr = h.root(.undefined)
        var k = 0
        while k < len {
            if k > 0 { realm.jsAppend(&b, sepUnits) }
            let e = try realm.arrGet(o, k)
            h[sr] = e
            if !e.isNullish {
                var s: JSValue
                if locale {
                    let f = try realm.getV(e, h.key("toLocaleString"))
                    h[sr] = f
                    guard h.isCallable(f) else { throw realm.throwTypeError("toLocaleString is not a function") }
                    let r = try realm.call(f, this: e, args: [])
                    h[sr] = r
                    s = try realm.toStringValue(r)
                } else {
                    s = try realm.toStringValue(e)
                }
                h[sr] = s
                realm.jsAppend(&b, s)
            }
            if !h.canMakeString(length: b.count) { throw realm.throwRangeError("Invalid string length") }
            k += 1
            try realm.jsTick(k)
        }
        let r = h.newString(b)
        try realm.jsCheckAlloc()
        return r
    }
    realm.defineMethod(ap, "join", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let c = try realm.jsArrEnter(args)
        defer { realm.heap.popRoots(to: c.depth) }
        return try joinImpl(realm, c.o, c.len, args[0], locale: false)
    }
    realm.defineMethod(ap, "toLocaleString", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let c = try realm.jsArrEnter(args)
        defer { realm.heap.popRoots(to: c.depth) }
        return try joinImpl(realm, c.o, c.len, .undefined, locale: true)
    }
    realm.defineMethod(ap, "toString", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let depth = h.rootDepth
        defer { h.popRoots(to: depth) }
        let o = try realm.toObject(args.this)
        _ = h.root(o)
        let f = try realm.getV(o, h.key("join"))
        if h.isCallable(f) { return try realm.call(f, this: o, args: []) }
        let ots = try realm.getV(realm.objectPrototype, h.names.toString)
        return try realm.call(ots, this: o, args: [])
    }

    // -------------------------------------------------------- reduce(Right)
    func reduceMethod(_ right: Bool) -> JSNativeFunction {
        return { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let h = realm.heap
            let c = try realm.jsArrEnter(args)
            defer { h.popRoots(to: c.depth) }
            let o = c.o, len = c.len
            let cb = args[0]
            try realm.jsCallable(cb, "callback")
            var k = right ? len - 1 : 0
            let step = right ? -1 : 1
            let acc = h.root(.undefined)
            let sr = h.root(.undefined)
            if args.count >= 2 {
                h[acc] = args[1]
            } else {
                var found = false
                while right ? k >= 0 : k < len {
                    if try realm.arrHas(o, k) {
                        h[acc] = try realm.arrGet(o, k)
                        found = true
                        k += step
                        break
                    }
                    k += step
                    try realm.jsTick(k)
                }
                if !found { throw realm.throwTypeError("Reduce of empty array with no initial value") }
            }
            while right ? k >= 0 : k < len {
                if try realm.arrHas(o, k) {
                    let v = try realm.arrGet(o, k)
                    h[sr] = v
                    h[acc] = try realm.call(cb, this: .undefined, args: [h[acc], v, .number(k), o])
                }
                k += step
                try realm.jsTick(k)
            }
            return h[acc]
        }
    }
    realm.defineMethod(ap, "reduce", length: 1, reduceMethod(false))
    realm.defineMethod(ap, "reduceRight", length: 1, reduceMethod(true))

    // ------------------------------------------------------------ reverse
    realm.defineMethod(ap, "reverse", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let c = try realm.jsArrEnter(args)
        defer { h.popRoots(to: c.depth) }
        let o = c.o, len = c.len
        if var e = h.plainDenseElements(o), e.count == len {
            e.reverse()
            if h.replaceDenseElements(o, e) { return o }
        }
        let mid = len / 2
        let ra = h.root(.undefined), rb = h.root(.undefined)
        var lower = 0
        while lower < mid {
            let upper = len - lower - 1
            let lowerExists = try realm.arrHas(o, lower)
            var lv: JSValue = .undefined
            if lowerExists { lv = try realm.arrGet(o, lower); h[ra] = lv }
            let upperExists = try realm.arrHas(o, upper)
            var uv: JSValue = .undefined
            if upperExists { uv = try realm.arrGet(o, upper); h[rb] = uv }
            if lowerExists && upperExists {
                try realm.arrSet(o, lower, uv)
                try realm.arrSet(o, upper, lv)
            } else if upperExists {
                try realm.arrSet(o, lower, uv)
                try realm.arrDelete(o, upper)
            } else if lowerExists {
                try realm.arrDelete(o, lower)
                try realm.arrSet(o, upper, lv)
            }
            lower += 1
            try realm.jsTick(lower)
        }
        return o
    }

    // -------------------------------------------------------------- slice
    realm.defineMethod(ap, "slice", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let c = try realm.jsArrEnter(args)
        defer { h.popRoots(to: c.depth) }
        let o = c.o, len = c.len
        var k = try realm.jsRelIndex(args[0], len, 0)
        let fin = try realm.jsRelIndex(args[1], len, len)
        let count = max(fin - k, 0)
        let a = try realm.jsSpeciesCreate(o, count)
        _ = h.root(a)
        var n = 0
        let sr = h.root(.undefined)
        while k < fin {
            if try realm.arrHas(o, k) {
                let v = try realm.arrGet(o, k)
                h[sr] = v
                try realm.arrDefine(a, n, v)
            }
            k += 1
            n += 1
            try realm.jsTick(n)
        }
        try realm.arrSetLength(a, n)
        return a
    }

    // --------------------------------------------------------------- sort
    realm.defineMethod(ap, "sort", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let cmp = args[0]
        if !cmp.isUndefined && !h.isCallable(cmp) {
            throw realm.throwTypeError("The comparison function must be either a function or undefined")
        }
        let c = try realm.jsArrEnter(args)
        defer { h.popRoots(to: c.depth) }
        let o = c.o, len = c.len
        var items: [JSValue] = []
        let hold = realm.jsNewArray()
        _ = h.root(hold)
        var k = 0
        while k < len {
            if try realm.arrHas(o, k) {
                let v = try realm.arrGet(o, k)
                _ = h.createDataProperty(hold, .index(UInt32(truncatingIfNeeded: items.count)), v)
                try realm.jsCheckAlloc()
                items.append(v)
            }
            k += 1
            try realm.jsTick(k)
        }
        let sorted = try realm.jsSortValues(items, cmp)
        for (j, v) in sorted.enumerated() { try realm.arrSet(o, j, v) }
        var j = sorted.count
        while j < len {
            if try realm.arrHas(o, j) { try realm.arrDelete(o, j) }
            j += 1
            try realm.jsTick(j)
        }
        return o
    }

    // ------------------------------------------------------------- splice
    realm.defineMethod(ap, "splice", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let c = try realm.jsArrEnter(args)
        defer { h.popRoots(to: c.depth) }
        let o = c.o, len = c.len
        let start = try realm.jsRelIndex(args[0], len, 0)
        var insertCount = 0
        var delCount = 0
        if args.count == 0 {
        } else if args.count == 1 {
            delCount = len - start
        } else {
            insertCount = args.count - 2
            let d = jsToIntegerOrInfinity(try realm.toNumber(args[1]))
            delCount = d < 0 ? 0 : (d > Double(len - start) ? len - start : Int(d))
        }
        if len + insertCount - delCount > jsMaxSafeInteger { throw realm.throwTypeError("Invalid array length") }
        let a = try realm.jsSpeciesCreate(o, delCount)
        _ = h.root(a)
        let sr = h.root(.undefined)
        var k = 0
        while k < delCount {
            if try realm.arrHas(o, start + k) {
                let v = try realm.arrGet(o, start + k)
                h[sr] = v
                try realm.arrDefine(a, k, v)
            }
            k += 1
            try realm.jsTick(k)
        }
        try realm.arrSetLength(a, delCount)
        // Dense whole-array path.
        if var e = h.plainDenseElements(o), e.count == len, len - delCount + insertCount < h.limits.maxDenseArrayLength {
            var items: [JSValue] = []
            if insertCount > 0 { for i in 0..<insertCount { items.append(args[2 + i]) } }
            e.replaceSubrange(start..<(start + delCount), with: items)
            if h.replaceDenseElements(o, e) { return a }
        }
        if insertCount < delCount {
            k = start
            while k < len - delCount {
                let from = k + delCount, to = k + insertCount
                if try realm.arrHas(o, from) {
                    let v = try realm.arrGet(o, from)
                    h[sr] = v
                    try realm.arrSet(o, to, v)
                } else {
                    try realm.arrDelete(o, to)
                }
                k += 1
                try realm.jsTick(k)
            }
            k = len
            while k > len - delCount + insertCount {
                try realm.arrDelete(o, k - 1)
                k -= 1
                try realm.jsTick(k)
            }
        } else if insertCount > delCount {
            k = len - delCount
            while k > start {
                let from = k + delCount - 1, to = k + insertCount - 1
                if try realm.arrHas(o, from) {
                    let v = try realm.arrGet(o, from)
                    h[sr] = v
                    try realm.arrSet(o, to, v)
                } else {
                    try realm.arrDelete(o, to)
                }
                k -= 1
                try realm.jsTick(k)
            }
        }
        if insertCount > 0 { for i in 0..<insertCount { try realm.arrSet(o, start + i, args[2 + i]) } }
        try realm.arrSetLength(o, len - delCount + insertCount)
        return a
    }

    // ----------------------------------------------------------------- at
    realm.defineMethod(ap, "at", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let c = try realm.jsArrEnter(args)
        defer { realm.heap.popRoots(to: c.depth) }
        let d = jsToIntegerOrInfinity(try realm.toNumber(args[0]))
        let r = d >= 0 ? d : Double(c.len) + d
        if r < 0 || r >= Double(c.len) { return .undefined }
        return try realm.arrGet(c.o, Int(r))
    }

    // ------------------------------------- toReversed/toSorted/toSpliced/with
    realm.defineMethod(ap, "toReversed", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let c = try realm.jsArrEnter(args)
        defer { h.popRoots(to: c.depth) }
        let a = try realm.jsArrayCreate(c.len)
        _ = h.root(a)
        let sr = h.root(.undefined)
        var k = 0
        while k < c.len {
            let v = try realm.arrGet(c.o, c.len - k - 1)
            h[sr] = v
            try realm.arrDefine(a, k, v)
            k += 1
            try realm.jsTick(k)
        }
        return a
    }
    realm.defineMethod(ap, "toSorted", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let cmp = args[0]
        if !cmp.isUndefined && !h.isCallable(cmp) {
            throw realm.throwTypeError("The comparison function must be either a function or undefined")
        }
        let c = try realm.jsArrEnter(args)
        defer { h.popRoots(to: c.depth) }
        let a = try realm.jsArrayCreate(c.len)
        _ = h.root(a)
        let hold = realm.jsNewArray()
        _ = h.root(hold)
        var items: [JSValue] = []
        items.reserveCapacity(min(c.len, 1 << 20))
        var k = 0
        while k < c.len {
            let v = try realm.arrGet(c.o, k)
            _ = h.createDataProperty(hold, .index(UInt32(truncatingIfNeeded: k)), v)
            try realm.jsCheckAlloc()
            items.append(v)
            k += 1
            try realm.jsTick(k)
        }
        let sorted = try realm.jsSortValues(items, cmp)
        for (j, v) in sorted.enumerated() { try realm.arrDefine(a, j, v) }
        return a
    }
    realm.defineMethod(ap, "toSpliced", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let c = try realm.jsArrEnter(args)
        defer { h.popRoots(to: c.depth) }
        let o = c.o, len = c.len
        let start = try realm.jsRelIndex(args[0], len, 0)
        var insertCount = 0
        var skip = 0
        if args.count == 0 {
        } else if args.count == 1 {
            skip = len - start
        } else {
            insertCount = args.count - 2
            let d = jsToIntegerOrInfinity(try realm.toNumber(args[1]))
            skip = d < 0 ? 0 : (d > Double(len - start) ? len - start : Int(d))
        }
        let newLen = len + insertCount - skip
        if newLen > jsMaxSafeInteger { throw realm.throwTypeError("Invalid array length") }
        let a = try realm.jsArrayCreate(newLen)
        _ = h.root(a)
        let sr = h.root(.undefined)
        var i = 0
        while i < start {
            let v = try realm.arrGet(o, i)
            h[sr] = v
            try realm.arrDefine(a, i, v)
            i += 1
            try realm.jsTick(i)
        }
        var r = start
        if insertCount > 0 {
            for j in 0..<insertCount { try realm.arrDefine(a, i, args[2 + j]); i += 1 }
        }
        r = start + skip
        while i < newLen {
            let v = try realm.arrGet(o, r)
            h[sr] = v
            try realm.arrDefine(a, i, v)
            i += 1
            r += 1
            try realm.jsTick(i)
        }
        return a
    }
    realm.defineMethod(ap, "with", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let c = try realm.jsArrEnter(args)
        defer { h.popRoots(to: c.depth) }
        let rel = jsToIntegerOrInfinity(try realm.toNumber(args[0]))
        let actual = rel >= 0 ? rel : Double(c.len) + rel
        if actual >= Double(c.len) || actual < 0 { throw realm.throwRangeError("Invalid index") }
        let idx = Int(actual)
        let a = try realm.jsArrayCreate(c.len)
        _ = h.root(a)
        let sr = h.root(.undefined)
        var k = 0
        while k < c.len {
            let v = k == idx ? args[1] : try realm.arrGet(c.o, k)
            h[sr] = v
            try realm.arrDefine(a, k, v)
            k += 1
            try realm.jsTick(k)
        }
        return a
    }

    // --------------------------------------------------------- unscopables
    let unscop = heap.newObject(proto: .null)
    let r = heap.root(unscop)
    for n in ["at", "copyWithin", "entries", "fill", "find", "findIndex", "findLast", "findLastIndex",
              "flat", "flatMap", "includes", "keys", "toReversed", "toSorted", "toSpliced", "values"] {
        _ = heap.createDataProperty(unscop, heap.key(n), .true)
    }
    _ = heap.defineOwnProperty(ap, .symbol(heap.symbolsWellKnown.unscopables.handle), .data(unscop, [.configurable]))
    heap.popRoots(to: r.slot)
    _ = iterKey
    _ = tagKey
}
