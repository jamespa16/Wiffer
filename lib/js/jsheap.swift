// JSHeap: the JS heap and its garbage collector (ROADMAP Part 9, "Values,
// objects and memory"). Strings, symbols, objects (closures, environments
// and host objects are objects of some JSObjectKind) and bigints live in
// cell arrays indexed by 32-bit handles, each with a free list. The GC is
// precise, non-moving mark-and-sweep, run when the bytes allocated since
// the last cycle pass a threshold (max(4 MiB, live bytes after the last
// cycle), so the heap may double between cycles).
//
// API (the VM contract):
//   JSHeap(limits:)              one heap per realm; handles 0 are reserved
//                                sentinels: "" (string 0), a dead
//                                non-extensible object (object 0, writes
//                                dropped), a symbol and a bigint zero.
//   gcEveryAllocation            stress mode: a full collection at every
//                                allocation (finds missing roots).
//   collectGarbage()             a full collection now.
//   safePoint()                  the VM calls this at its interrupt checks:
//                                collects if growth (property/element
//                                stores, which never collect) asked for it,
//                                and may set the heap-limit termination.
//   termination                  nil, or why the script must stop. Set to
//                                .heapLimit when live bytes stay over
//                                limits.heapBytes after a full GC. Sticky
//                                until clearTermination(). While it is set,
//                                allocations return the sentinel handles and
//                                stores that would grow an object fail, so
//                                memory stays bounded while the VM unwinds.
//                                The VM must check it at interrupt points
//                                and after allocating instructions; native
//                                loops that allocate must check it too.
//   requestTermination(r)        the VM/embedder's budget (interrupt,
//                                regex steps) uses the same flag.
//
//   When GC can run: ONLY inside the allocating calls (newObject, newArray,
//   newString..., concat, substring, numberToString, keyValue, atom,
//   newSymbol, ...), safePoint() and collectGarbage(). Allocating calls
//   protect their own value arguments. Any other handle held in a Swift
//   local across an allocating call must be rooted:
//
//   Roots
//     addRootProvider { heap in heap.markValue(v) ... } -> id
//                                the VM registers its value stack, frames
//                                and environments; called every cycle.
//                                removeRootProvider(id).
//     retain(v) -> JSPersistent / release(p) / heap[p] get/set
//                                persistent roots: realm globals, intrinsic
//                                prototypes, host-object wrapper tables.
//     root(v) -> JSRooted, heap[r] get/set, rootDepth, popRoots(to:),
//     withRootScope { ... }      explicit scopes for native code (a stack;
//                                popping restores the depth).
//     markValue(v), markKey(k)   for root providers and weak processors.
//     addWeakProcessor { heap, phase in ... } -> id
//                                ephemeron hook (WeakMap/WeakSet, 9E):
//                                phase .ephemerons runs repeatedly after
//                                marking until every processor returns
//                                false (return true if you marked anything,
//                                e.g. a value whose key isLive); phase
//                                .clearDead runs once before the sweep (drop
//                                entries whose key is not isLive). The
//                                processor must not allocate.
//     isLive(v) during a weak processor: marked this cycle.
//   Host objects: objects with flag .hasFinalizer get `finalizer(handle,
//   internalInt)` called when swept (free the host table slot; must not
//   touch the heap).
//
//   Stats: liveBytes (estimate: after last GC + allocated since), gcCount,
//   objectCount / stringCount / symbolCount (live cells).

public enum JSWeakPhase { case ephemerons, clearDead }

/// A persistent root slot (JSHeap.retain).
public struct JSPersistent: Equatable { public let slot: Int }

/// An explicitly rooted value on the heap's root stack (JSHeap.root).
public struct JSRooted: Equatable { public let slot: Int }

struct JSBigIntCell {
    var negative = false
    var limbs: [UInt32] = []
}

@inline(__always) func jsBitTest(_ bits: [UInt64], _ i: Int) -> Bool {
    bits[i >> 6] & (1 << UInt64(i & 63)) != 0
}
@inline(__always) func jsBitSet(_ bits: inout [UInt64], _ i: Int) { bits[i >> 6] |= 1 << UInt64(i & 63) }
@inline(__always) func jsBitClear(_ bits: inout [UInt64], _ i: Int) { bits[i >> 6] &= ~(1 << UInt64(i & 63)) }
/// Sets bit i; returns whether it was already set.
@inline(__always) func jsBitTestAndSet(_ bits: inout [UInt64], _ i: Int) -> Bool {
    let w = i >> 6, m: UInt64 = 1 << UInt64(i & 63)
    if bits[w] & m != 0 { return true }
    bits[w] |= m
    return false
}

public final class JSHeap {
    public var limits: JSLimits
    /// Stress mode: collect at every allocation.
    public var gcEveryAllocation = false
    public private(set) var termination: JSTerminationReason? = nil
    /// Called for swept objects with .hasFinalizer (host objects).
    public var finalizer: ((JSHandle, Int64) -> Void)? = nil

    // Cells, liveness and mark bits, free lists.
    var strings: [JSStringCell] = []
    var symbols: [JSSymbolCell] = []
    var objects: [JSObjectCell] = []
    var bigints: [JSBigIntCell] = []
    var stringLive: [UInt64] = [], symbolLive: [UInt64] = [], objectLive: [UInt64] = [], bigintLive: [UInt64] = []
    var stringMarks: [UInt64] = [], symbolMarks: [UInt64] = [], objectMarks: [UInt64] = [], bigintMarks: [UInt64] = []
    var stringFree: [JSHandle] = [], symbolFree: [JSHandle] = [], objectFree: [JSHandle] = [], bigintFree: [JSHandle] = []
    var markStack: [JSHandle] = []

    // Atoms.
    var atomTable: [JSHandle] = []
    var atomCount = 0
    var pinned: [JSValue] = []
    /// The 256 one-unit Latin-1 strings (pinned atoms).
    var unitStrings: [JSValue] = []
    public private(set) var names = JSCommonNames()
    public private(set) var symbolsWellKnown = JSWellKnownSymbols()

    // Roots.
    var rootStack: [JSValue] = []
    var persistent: [JSValue] = []
    var persistentFree: [Int] = []
    var rootProviders: [(id: Int, fn: (JSHeap) -> Void)] = []
    var weakProcessors: [(id: Int, fn: (JSHeap, JSWeakPhase) -> Bool)] = []
    var nextCallbackID = 1

    // Accounting.
    var liveBytesAfterGC = 0
    var bytesSinceGC = 0
    var gcThreshold = JSHeap.minGCBytes
    var gcRequested = false
    var collecting = false
    public private(set) var gcCount = 0
    static let minGCBytes = 4 << 20

    public init(limits: JSLimits = JSLimits()) {
        self.limits = limits
        // Sentinels at handle 0.
        _ = allocStringSlot(JSStringCell())
        _ = allocSymbolSlot(JSSymbolCell())
        var dead = JSObjectCell()
        dead.kind = .dead
        _ = allocObjectSlot(dead)
        _ = allocBigIntSlot(JSBigIntCell())
        makeNames()
    }

    private func makeNames() {
        func k(_ s: String) -> JSPropertyKey { .atom(pinAtom(newString(s)).handle) }
        var n = JSCommonNames()
        n.length = k("length"); n.prototype = k("prototype"); n.constructor = k("constructor")
        n.name = k("name"); n.message = k("message"); n.toString = k("toString"); n.valueOf = k("valueOf")
        n.value = k("value"); n.writable = k("writable"); n.enumerable = k("enumerable")
        n.configurable = k("configurable"); n.get = k("get"); n.set = k("set"); n.callee = k("callee")
        n.caller = k("caller"); n.arguments = k("arguments"); n.undefined = k("undefined"); n.null = k("null")
        n.true_ = k("true"); n.false_ = k("false"); n.number = k("number"); n.string = k("string")
        n.boolean = k("boolean"); n.symbol = k("symbol"); n.object = k("object"); n.function = k("function")
        n.bigint = k("bigint"); n.NaN = k("NaN"); n.Infinity = k("Infinity"); n.negativeInfinity = k("-Infinity")
        n.empty = .atom(0); n.lastIndex = k("lastIndex"); n.index = k("index"); n.input = k("input")
        n.done = k("done"); n.next = k("next"); n.then = k("then"); n.stack = k("stack"); n.cause = k("cause")
        n.errors = k("errors"); n.raw = k("raw"); n.default_ = k("default")
        names = n
        var t: [JSValue] = []
        for b in 0..<256 { t.append(pinAtom(newString(latin1: [UInt8(b)]))) }
        unitStrings = t
        func sym(_ s: String) -> JSValue {
            let v = newSymbol(description: pinAtom(newString("Symbol." + s)))
            pinned.append(v)
            return v
        }
        var w = JSWellKnownSymbols()
        w.asyncIterator = sym("asyncIterator"); w.hasInstance = sym("hasInstance")
        w.isConcatSpreadable = sym("isConcatSpreadable"); w.iterator = sym("iterator"); w.match = sym("match")
        w.matchAll = sym("matchAll"); w.replace = sym("replace"); w.search = sym("search")
        w.species = sym("species"); w.split = sym("split"); w.toPrimitive = sym("toPrimitive")
        w.toStringTag = sym("toStringTag"); w.unscopables = sym("unscopables")
        symbolsWellKnown = w
    }

    // MARK: Slots

    @inline(__always) private func grow(_ bits: inout [UInt64], _ count: Int) {
        while bits.count * 64 < count { bits.append(0) }
    }

    func allocStringSlot(_ c: JSStringCell) -> JSHandle {
        if let h = stringFree.popLast() { strings[Int(h)] = c; jsBitSet(&stringLive, Int(h)); return h }
        strings.append(c)
        let i = strings.count - 1
        grow(&stringLive, strings.count); grow(&stringMarks, strings.count)
        jsBitSet(&stringLive, i)
        return JSHandle(i)
    }

    func allocSymbolSlot(_ c: JSSymbolCell) -> JSHandle {
        if let h = symbolFree.popLast() { symbols[Int(h)] = c; jsBitSet(&symbolLive, Int(h)); return h }
        symbols.append(c)
        let i = symbols.count - 1
        grow(&symbolLive, symbols.count); grow(&symbolMarks, symbols.count)
        jsBitSet(&symbolLive, i)
        return JSHandle(i)
    }

    func allocObjectSlot(_ c: JSObjectCell) -> JSHandle {
        if let h = objectFree.popLast() { objects[Int(h)] = c; jsBitSet(&objectLive, Int(h)); return h }
        objects.append(c)
        let i = objects.count - 1
        grow(&objectLive, objects.count); grow(&objectMarks, objects.count)
        jsBitSet(&objectLive, i)
        return JSHandle(i)
    }

    func allocBigIntSlot(_ c: JSBigIntCell) -> JSHandle {
        if let h = bigintFree.popLast() { bigints[Int(h)] = c; jsBitSet(&bigintLive, Int(h)); return h }
        bigints.append(c)
        let i = bigints.count - 1
        grow(&bigintLive, bigints.count); grow(&bigintMarks, bigints.count)
        jsBitSet(&bigintLive, i)
        return JSHandle(i)
    }

    // MARK: Allocation accounting

    /// Called before every allocation of `bytes`. May collect (protecting a
    /// and b). False: terminating, the caller returns a sentinel.
    func beforeAllocation(_ bytes: Int, _ a: JSValue, _ b: JSValue) -> Bool {
        if termination == .heapLimit { return false }
        if collecting { return true }
        bytesSinceGC += bytes
        if gcEveryAllocation || bytesSinceGC >= gcThreshold || liveBytesAfterGC + bytesSinceGC > limits.heapBytes {
            rootStack.append(a)
            rootStack.append(b)
            collectGarbage()
            rootStack.removeLast(2)
            bytesSinceGC = bytes
            if liveBytesAfterGC + bytes > limits.heapBytes {
                termination = .heapLimit
                return false
            }
        }
        return true
    }

    /// Growth of an existing cell (property and element stores). Never
    /// collects; asks for a collection at the next safePoint. False when
    /// the store must fail (terminating, or far over the cap).
    func noteGrowth(_ bytes: Int) -> Bool {
        if termination == .heapLimit { return false }
        bytesSinceGC += bytes
        let total = liveBytesAfterGC + bytesSinceGC
        if bytesSinceGC >= gcThreshold || total > limits.heapBytes { gcRequested = true }
        if total > limits.heapBytes + limits.heapBytes / 4 {
            // Over the cap by a quarter without reaching a safe point.
            termination = .heapLimit
            return false
        }
        return true
    }

    /// The VM's interrupt-check hook. Every value the VM holds must be
    /// reachable from a root provider here.
    public func safePoint() {
        if termination == .heapLimit || collecting { return }
        if gcRequested || gcEveryAllocation {
            collectGarbage()
            if liveBytesAfterGC > limits.heapBytes { termination = .heapLimit }
        }
    }

    public func requestTermination(_ r: JSTerminationReason) { termination = r }
    public func clearTermination() { termination = nil }

    /// Estimated bytes in use (live after the last GC plus allocated since).
    public var liveBytes: Int { liveBytesAfterGC + bytesSinceGC }

    public var objectCount: Int { jsPopCount(objectLive) }
    public var stringCount: Int { jsPopCount(stringLive) }
    public var symbolCount: Int { jsPopCount(symbolLive) }

    // MARK: Roots

    public func addRootProvider(_ fn: @escaping (JSHeap) -> Void) -> Int {
        let id = nextCallbackID; nextCallbackID += 1
        rootProviders.append((id, fn))
        return id
    }
    public func removeRootProvider(_ id: Int) { rootProviders.removeAll { $0.id == id } }

    public func addWeakProcessor(_ fn: @escaping (JSHeap, JSWeakPhase) -> Bool) -> Int {
        let id = nextCallbackID; nextCallbackID += 1
        weakProcessors.append((id, fn))
        return id
    }
    public func removeWeakProcessor(_ id: Int) { weakProcessors.removeAll { $0.id == id } }

    public func retain(_ v: JSValue) -> JSPersistent {
        if let s = persistentFree.popLast() { persistent[s] = v; return JSPersistent(slot: s) }
        persistent.append(v)
        return JSPersistent(slot: persistent.count - 1)
    }
    public func release(_ p: JSPersistent) {
        guard p.slot >= 0 && p.slot < persistent.count else { return }
        persistent[p.slot] = .undefined
        persistentFree.append(p.slot)
    }
    public subscript(p: JSPersistent) -> JSValue {
        get { p.slot >= 0 && p.slot < persistent.count ? persistent[p.slot] : .undefined }
        set { if p.slot >= 0 && p.slot < persistent.count { persistent[p.slot] = newValue } }
    }

    public func root(_ v: JSValue) -> JSRooted {
        rootStack.append(v)
        return JSRooted(slot: rootStack.count - 1)
    }
    public subscript(r: JSRooted) -> JSValue {
        get { r.slot >= 0 && r.slot < rootStack.count ? rootStack[r.slot] : .undefined }
        set { if r.slot >= 0 && r.slot < rootStack.count { rootStack[r.slot] = newValue } }
    }
    public var rootDepth: Int { rootStack.count }
    public func popRoots(to depth: Int) {
        if depth >= 0 && depth < rootStack.count { rootStack.removeSubrange(depth...) }
    }
    /// Runs body; every root(v) made inside is dropped afterwards.
    public func withRootScope<R, E: Error>(_ body: () throws(E) -> R) throws(E) -> R {
        let depth = rootStack.count
        defer { popRoots(to: depth) }
        return try body()
    }

    // MARK: Marking

    @inline(__always) public func markValue(_ v: JSValue) {
        guard v.isHeapValue else { return }
        let h = Int(v.handle)
        switch v.bits & JSValue.tagMask {
        case JSValue.tagString:
            if h < strings.count { jsBitSet(&stringMarks, h) }
        case JSValue.tagObject:
            if h < objects.count && !jsBitTestAndSet(&objectMarks, h) { markStack.append(JSHandle(h)) }
        case JSValue.tagSymbol:
            if h < symbols.count && !jsBitTestAndSet(&symbolMarks, h) { markValue(symbols[h].description) }
        case JSValue.tagBigInt:
            if h < bigints.count { jsBitSet(&bigintMarks, h) }
        default: break
        }
    }

    @inline(__always) public func markKey(_ k: JSPropertyKey) {
        if k.isString { markValue(.string(k.handle)) } else if k.isSymbol { markValue(.symbol(k.handle)) }
    }

    /// During a weak processor: was v reached this cycle? Primitives are
    /// always live.
    public func isLive(_ v: JSValue) -> Bool {
        guard v.isHeapValue else { return true }
        let h = Int(v.handle)
        switch v.bits & JSValue.tagMask {
        case JSValue.tagString: return h < strings.count && jsBitTest(stringMarks, h)
        case JSValue.tagObject: return h < objects.count && jsBitTest(objectMarks, h)
        case JSValue.tagSymbol: return h < symbols.count && jsBitTest(symbolMarks, h)
        case JSValue.tagBigInt: return h < bigints.count && jsBitTest(bigintMarks, h)
        default: return true
        }
    }

    func drainMarkStack() {
        while let h = markStack.popLast() {
            let i = Int(h)
            markValue(objects[i].proto)
            for p in objects[i].props where p.key != .deleted {
                markKey(p.key)
                markValue(p.value)
                markValue(p.setter)
            }
            for e in objects[i].elements { markValue(e) }
            if !objects[i].sparse.isEmpty {
                for (_, p) in objects[i].sparse { markValue(p.value); markValue(p.setter) }
            }
            for s in objects[i].slots { markValue(s) }
        }
    }

    // MARK: Collection

    public func collectGarbage() {
        if collecting { return }
        collecting = true
        defer { collecting = false }
        for i in 0..<stringMarks.count { stringMarks[i] = 0 }
        for i in 0..<symbolMarks.count { symbolMarks[i] = 0 }
        for i in 0..<objectMarks.count { objectMarks[i] = 0 }
        for i in 0..<bigintMarks.count { bigintMarks[i] = 0 }
        // Sentinels and pinned values.
        markValue(.string(0)); markValue(.symbol(0)); markValue(.object(0)); markValue(.bigint(0))
        for v in pinned { markValue(v) }
        for v in persistent { markValue(v) }
        for v in rootStack { markValue(v) }
        for p in rootProviders { p.fn(self) }
        drainMarkStack()
        // Ephemerons: iterate to a fixed point.
        if !weakProcessors.isEmpty {
            var rounds = 0
            while rounds < 1_000_000 {
                rounds += 1
                var changed = false
                for p in weakProcessors where p.fn(self, .ephemerons) { changed = true }
                drainMarkStack()
                if !changed { break }
            }
            for p in weakProcessors { _ = p.fn(self, .clearDead) }
        }
        sweep()
        gcCount += 1
        gcRequested = false
        bytesSinceGC = 0
        gcThreshold = max(JSHeap.minGCBytes, liveBytesAfterGC)
    }

    private func sweep() {
        var live = 0
        // Objects.
        var i = objects.count - 1
        while i >= 1 {
            if jsBitTest(objectLive, i) {
                if jsBitTest(objectMarks, i) {
                    live += JSHeap.objectBytes(objects[i])
                } else {
                    if objects[i].flags.contains(.hasFinalizer), let f = finalizer {
                        f(JSHandle(i), objects[i].internalInt)
                    }
                    objects[i] = JSObjectCell()
                    jsBitClear(&objectLive, i)
                    objectFree.append(JSHandle(i))
                }
            }
            i -= 1
        }
        // Strings (atoms included: their table is rebuilt if one dies).
        var atomDied = false
        i = strings.count - 1
        while i >= 1 {
            if jsBitTest(stringLive, i) {
                if jsBitTest(stringMarks, i) {
                    live += JSHeap.stringCellBytes + strings[i].count * (strings[i].isWide ? 2 : 1)
                } else {
                    if strings[i].isAtom { atomDied = true }
                    strings[i] = JSStringCell()
                    jsBitClear(&stringLive, i)
                    stringFree.append(JSHandle(i))
                }
            }
            i -= 1
        }
        if atomDied { rebuildAtomTable(minimum: 64) }
        i = symbols.count - 1
        while i >= 1 {
            if jsBitTest(symbolLive, i) {
                if jsBitTest(symbolMarks, i) { live += 32 } else {
                    symbols[i] = JSSymbolCell()
                    jsBitClear(&symbolLive, i)
                    symbolFree.append(JSHandle(i))
                }
            }
            i -= 1
        }
        i = bigints.count - 1
        while i >= 1 {
            if jsBitTest(bigintLive, i) {
                if jsBitTest(bigintMarks, i) { live += 32 + bigints[i].limbs.count * 4 } else {
                    bigints[i] = JSBigIntCell()
                    jsBitClear(&bigintLive, i)
                    bigintFree.append(JSHandle(i))
                }
            }
            i -= 1
        }
        liveBytesAfterGC = live
    }

    static func objectBytes(_ c: JSObjectCell) -> Int {
        var n = 112 + c.props.count * 32 + c.elements.count * 8 + c.slots.count * 8
        if !c.index.isEmpty { n += c.index.count * 4 }
        if !c.sparse.isEmpty { n += c.sparse.count * 48 }
        return n
    }
}

func jsPopCount(_ bits: [UInt64]) -> Int {
    var n = 0
    for w in bits { n += w.nonzeroBitCount }
    return n
}
