// WeakMap, WeakSet, WeakRef, FinalizationRegistry (ROADMAP Phase 9E) and
// the 9E GC hooks.
//
// Weak entries are NOT in object slots (the GC would trace them): they live
// in Swift side tables in realm.tables, found through the owner's
// internalInt (= table id + 1). One root provider and one weak processor
// (jsInstallWeakProcessor, installed lazily) do the GC work:
//
//   ephemerons phase (repeated to a fixed point by JSHeap):
//     WeakMap/WeakSet  for a live table, an entry whose key is marked gets
//                      its value marked. A value reachable only through its
//                      own key (or through a chain of such entries) is not
//                      kept alive. Each GC cycle starts with the list of
//                      unresolved entries and shrinks it every round.
//     FinalizationRegistry  a live registry marks its cells' held values
//                      (the registry holds them strongly; targets and
//                      unregister tokens stay weak).
//   clearDead phase:
//     dead owners' tables are freed (also Map/Set indexes, whose entries
//     are in slots); entries with dead keys are dropped; dead WeakRef
//     targets are cleared; a registry cell whose target died moves its
//     held value to the registry's pending list, and
//     tables.onFinalizationCleanupNeeded is called (it must not touch the
//     heap; the embedder schedules realm.runFinalizationCleanups()).
//   root provider: WeakRef targets kept alive for the current job
//     (AddToKeptObjects; the embedder calls realm.clearKeptObjects() at the
//     end of each job), registries with pending cleanups and their held
//     values, and the recent proxy ownKeys key strings.
//
// CanBeHeldWeakly: objects and symbols not made by Symbol.for.

final class JSWeakTable {
    var owner: JSValue
    var entries: [UInt64: (key: JSValue, value: JSValue)] = [:]
    var pending: [UInt64] = []
    var cycle = -1
    init(owner: JSValue) { self.owner = owner }
}

struct JSWeakRefCell {
    var owner: JSValue
    var target: JSValue
}

final class JSFinRegistry {
    var owner: JSValue
    var cells: [(target: JSValue, held: JSValue, token: JSValue)] = []
    var pendingHeld: [JSValue] = []
    var cycle = -1
    init(owner: JSValue) { self.owner = owner }
}

extension JSRealm {
    func canBeHeldWeakly(_ v: JSValue) -> Bool {
        if v.isObject { return true }
        if v.isSymbol {
            let i = Int(v.handle)
            return i > 0 && i < heap.symbols.count && !heap.symbols[i].registryKey
        }
        return false
    }

    func weakTable(_ o: JSValue, _ kind: JSObjectKind) -> JSWeakTable? {
        guard heap.kind(o) == kind else { return nil }
        let id = Int(heap.internalInt(o)) - 1
        guard id >= 0 && id < tables.weakTables.count, let t = tables.weakTables[id], t.owner == o else { return nil }
        return t
    }

    func newWeakCollection(proto: JSValue, kind: JSObjectKind) -> JSValue {
        let o = heap.newObject(proto: proto, kind: kind)
        guard heap.kind(o) == kind else { return o }
        let t = JSWeakTable(owner: o)
        let id: Int
        if let f = tables.weakTableFree.popLast() { id = f; tables.weakTables[f] = t } else {
            id = tables.weakTables.count; tables.weakTables.append(t)
        }
        heap.setInternalInt(o, Int64(id + 1))
        jsInstallWeakProcessor(self)
        return o
    }

    func registry(_ o: JSValue) -> JSFinRegistry? {
        guard heap.kind(o) == .finalizationRegistry else { return nil }
        let id = Int(heap.internalInt(o)) - 1
        guard id >= 0 && id < tables.registries.count, let r = tables.registries[id], r.owner == o else { return nil }
        return r
    }

    /// AddToKeptObjects.
    func keepDuringJob(_ v: JSValue) {
        if tables.keptSet.insert(v.bits).inserted { tables.keptAlive.append(v) }
    }

    /// ClearKeptObjects: the embedder calls this when a job (script, task,
    /// microtask checkpoint) ends.
    public func clearKeptObjects() {
        tables.keptAlive = []
        tables.keptSet = []
    }

    /// Whether some FinalizationRegistry has callbacks to run.
    public var hasPendingFinalizationCleanups: Bool {
        for r in tables.registries { if let x = r, !x.pendingHeld.isEmpty { return true } }
        return false
    }

    /// Run pending FinalizationRegistry cleanup callbacks (the embedder
    /// calls this from a task after onFinalizationCleanupNeeded). An
    /// exception from a callback propagates after the registry's remaining
    /// held values are put back.
    public func runFinalizationCleanups() throws(JSThrow) {
        var i = 0
        while i < tables.registries.count {
            if let r = tables.registries[i], !r.pendingHeld.isEmpty {
                let depth = heap.rootDepth
                defer { heap.popRoots(to: depth) }
                _ = heap.root(r.owner)
                let cb = heap.slot(r.owner, 0)
                _ = heap.root(cb)
                while !r.pendingHeld.isEmpty {
                    let held = r.pendingHeld.removeFirst()
                    _ = heap.root(held)
                    if heap.isCallable(cb) { _ = try call(cb, this: .undefined, args: [held]) }
                }
            }
            i += 1
        }
    }
}

/// Installs the 9E root provider and weak processor once per realm.
func jsInstallWeakProcessor(_ realm: JSRealm) {
    let t = realm.tables
    if t.gcHooksInstalled { return }
    t.gcHooksInstalled = true
    _ = realm.heap.addRootProvider { [unowned(unsafe) realm] h in
        let t = realm.tables
        for v in t.keptAlive { h.markValue(v) }
        for r in t.registries {
            if let x = r, !x.pendingHeld.isEmpty {
                h.markValue(x.owner)
                for v in x.pendingHeld { h.markValue(v) }
            }
        }
        for l in t.recentKeys { for v in l { h.markValue(v) } }
    }
    _ = realm.heap.addWeakProcessor { [unowned(unsafe) realm] h, phase in
        let t = realm.tables
        switch phase {
        case .ephemerons:
            var marked = false
            let cycle = h.gcCount
            for case let w? in t.weakTables where h.isLive(w.owner) {
                if w.cycle != cycle {
                    w.cycle = cycle
                    w.pending = []
                    for (k, e) in w.entries where !h.isLive(e.value) { w.pending.append(k) }
                }
                if w.pending.isEmpty { continue }
                var keep: [UInt64] = []
                for k in w.pending {
                    guard let e = w.entries[k] else { continue }
                    if h.isLive(e.value) { continue }
                    if h.isLive(e.key) { h.markValue(e.value); marked = true } else { keep.append(k) }
                }
                w.pending = keep
            }
            for case let r? in t.registries where h.isLive(r.owner) && r.cycle != cycle {
                r.cycle = cycle
                for c in r.cells where !h.isLive(c.held) { h.markValue(c.held); marked = true }
            }
            return marked
        case .clearDead:
            var needCleanup = false
            for i in 0..<t.mapIndexes.count {
                if let m = t.mapIndexes[i], !h.isLive(m.owner) { t.mapIndexes[i] = nil; t.mapIndexFree.append(i) }
            }
            for i in 0..<t.weakTables.count {
                guard let w = t.weakTables[i] else { continue }
                if !h.isLive(w.owner) { t.weakTables[i] = nil; t.weakTableFree.append(i); continue }
                var dead: [UInt64] = []
                for (k, e) in w.entries where !h.isLive(e.key) { dead.append(k) }
                for k in dead { w.entries[k] = nil }
                w.pending = []
            }
            for i in 0..<t.weakRefs.count {
                guard let c = t.weakRefs[i] else { continue }
                if !h.isLive(c.owner) { t.weakRefs[i] = nil; t.weakRefFree.append(i); continue }
                if !h.isLive(c.target) { t.weakRefs[i]!.target = .undefined }
            }
            for i in 0..<t.registries.count {
                guard let r = t.registries[i] else { continue }
                if !h.isLive(r.owner) { t.registries[i] = nil; t.registryFree.append(i); continue }
                var keep: [(target: JSValue, held: JSValue, token: JSValue)] = []
                for var c in r.cells {
                    if !h.isLive(c.target) {
                        r.pendingHeld.append(c.held)
                        needCleanup = true
                        continue
                    }
                    if !h.isLive(c.token) { c.token = .undefined }
                    keep.append(c)
                }
                r.cells = keep
            }
            if needCleanup { t.onFinalizationCleanupNeeded?() }
            return false
        }
    }
}

func jsInstallWeakBuiltins(_ realm: JSRealm) {
    let heap = realm.heap
    let op = realm.objectPrototype
    let tagKey = JSPropertyKey.symbol(heap.symbolsWellKnown.toStringTag.handle)
    let depth = heap.rootDepth
    defer { heap.popRoots(to: depth) }

    // ------------------------------------------------------------ WeakMap
    let wmp = heap.newObject(proto: op)
    _ = heap.root(wmp)
    realm.setIntrinsic(.weakMapPrototype, wmp)
    _ = realm.defineConstructor("WeakMap", length: 0, prototype: wmp) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        if !args.isConstruct { throw realm.throwTypeError("Constructor WeakMap requires 'new'") }
        let h = realm.heap
        let proto = try realm.prototype(forNewTarget: args.newTarget, default: .weakMapPrototype)
        let m = realm.newWeakCollection(proto: proto, kind: .weakMap)
        let r = h.root(m)
        defer { h.popRoots(to: r.slot) }
        if args[0].isNullish { return m }
        let adder = try realm.getV(m, h.key("set"))
        guard h.isCallable(adder) else { throw realm.throwTypeError("WeakMap.prototype.set is not a function") }
        _ = h.root(adder)
        try realm.iterate(args[0]) { (entry: JSValue) throws(JSThrow) -> Void in
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
    func thisWeak(_ realm: JSRealm, _ v: JSValue, _ kind: JSObjectKind, _ fn: String) throws(JSThrow) -> JSWeakTable {
        guard let t = realm.weakTable(v, kind) else {
            throw realm.throwTypeError("Method " + (kind == .weakMap ? "WeakMap" : "WeakSet") + ".prototype." + fn
                                       + " called on incompatible receiver " + realm.describeForError(v))
        }
        return t
    }
    realm.defineMethod(wmp, "get", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let t = try thisWeak(realm, args.this, .weakMap, "get")
        return t.entries[args[0].bits]?.value ?? .undefined
    }
    realm.defineMethod(wmp, "set", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let t = try thisWeak(realm, args.this, .weakMap, "set")
        guard realm.canBeHeldWeakly(args[0]) else { throw realm.throwTypeError("Invalid value used as weak map key") }
        if t.entries[args[0].bits] == nil && !realm.heap.noteGrowth(48) { throw JSThrow() }
        t.entries[args[0].bits] = (args[0], args[1])
        return args.this
    }
    realm.defineMethod(wmp, "has", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        .bool(try thisWeak(realm, args.this, .weakMap, "has").entries[args[0].bits] != nil)
    }
    realm.defineMethod(wmp, "delete", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let t = try thisWeak(realm, args.this, .weakMap, "delete")
        return .bool(t.entries.removeValue(forKey: args[0].bits) != nil)
    }
    _ = heap.defineOwnProperty(wmp, tagKey, .data(realm.string("WeakMap"), [.configurable]))

    // ------------------------------------------------------------ WeakSet
    let wsp = heap.newObject(proto: op)
    _ = heap.root(wsp)
    realm.setIntrinsic(.weakSetPrototype, wsp)
    _ = realm.defineConstructor("WeakSet", length: 0, prototype: wsp) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        if !args.isConstruct { throw realm.throwTypeError("Constructor WeakSet requires 'new'") }
        let h = realm.heap
        let proto = try realm.prototype(forNewTarget: args.newTarget, default: .weakSetPrototype)
        let s = realm.newWeakCollection(proto: proto, kind: .weakSet)
        let r = h.root(s)
        defer { h.popRoots(to: r.slot) }
        if args[0].isNullish { return s }
        let adder = try realm.getV(s, h.key("add"))
        guard h.isCallable(adder) else { throw realm.throwTypeError("WeakSet.prototype.add is not a function") }
        _ = h.root(adder)
        try realm.iterate(args[0]) { (v: JSValue) throws(JSThrow) -> Void in
            _ = try realm.call(adder, this: s, args: [v])
        }
        return s
    }
    realm.defineMethod(wsp, "add", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let t = try thisWeak(realm, args.this, .weakSet, "add")
        guard realm.canBeHeldWeakly(args[0]) else { throw realm.throwTypeError("Invalid value used in weak set") }
        if t.entries[args[0].bits] == nil && !realm.heap.noteGrowth(48) { throw JSThrow() }
        t.entries[args[0].bits] = (args[0], .true)
        return args.this
    }
    realm.defineMethod(wsp, "has", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        .bool(try thisWeak(realm, args.this, .weakSet, "has").entries[args[0].bits] != nil)
    }
    realm.defineMethod(wsp, "delete", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let t = try thisWeak(realm, args.this, .weakSet, "delete")
        return .bool(t.entries.removeValue(forKey: args[0].bits) != nil)
    }
    _ = heap.defineOwnProperty(wsp, tagKey, .data(realm.string("WeakSet"), [.configurable]))

    // ------------------------------------------------------------ WeakRef
    let wrp = heap.newObject(proto: op)
    _ = heap.root(wrp)
    realm.setIntrinsic(.weakRefPrototype, wrp)
    _ = realm.defineConstructor("WeakRef", length: 1, prototype: wrp) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        if !args.isConstruct { throw realm.throwTypeError("Constructor WeakRef requires 'new'") }
        guard realm.canBeHeldWeakly(args[0]) else { throw realm.throwTypeError("WeakRef: invalid target") }
        let proto = try realm.prototype(forNewTarget: args.newTarget, default: .weakRefPrototype)
        let o = realm.heap.newObject(proto: proto, kind: .weakRef)
        guard realm.heap.kind(o) == .weakRef else { throw JSThrow() }
        let t = realm.tables
        let cell = JSWeakRefCell(owner: o, target: args[0])
        let id: Int
        if let f = t.weakRefFree.popLast() { id = f; t.weakRefs[f] = cell } else { id = t.weakRefs.count; t.weakRefs.append(cell) }
        realm.heap.setInternalInt(o, Int64(id + 1))
        jsInstallWeakProcessor(realm)
        realm.keepDuringJob(args[0])
        return o
    }
    realm.defineMethod(wrp, "deref", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let o = args.this
        let id = Int(realm.heap.internalInt(o)) - 1
        guard realm.heap.kind(o) == .weakRef, id >= 0, id < realm.tables.weakRefs.count,
              let c = realm.tables.weakRefs[id], c.owner == o else {
            throw realm.throwTypeError("WeakRef.prototype.deref called on incompatible receiver")
        }
        if !c.target.isUndefined { realm.keepDuringJob(c.target) }
        return c.target
    }
    _ = heap.defineOwnProperty(wrp, tagKey, .data(realm.string("WeakRef"), [.configurable]))

    // ----------------------------------------------- FinalizationRegistry
    let frp = heap.newObject(proto: op)
    _ = heap.root(frp)
    realm.setIntrinsic(.finalizationRegistryPrototype, frp)
    _ = realm.defineConstructor("FinalizationRegistry", length: 1, prototype: frp) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        if !args.isConstruct { throw realm.throwTypeError("Constructor FinalizationRegistry requires 'new'") }
        guard realm.heap.isCallable(args[0]) else { throw realm.throwTypeError("FinalizationRegistry: cleanup must be callable") }
        let proto = try realm.prototype(forNewTarget: args.newTarget, default: .finalizationRegistryPrototype)
        let o = realm.heap.newObject(proto: proto, kind: .finalizationRegistry)
        guard realm.heap.kind(o) == .finalizationRegistry else { throw JSThrow() }
        realm.heap.setSlots(o, [args[0]])
        let t = realm.tables
        let r = JSFinRegistry(owner: o)
        let id: Int
        if let f = t.registryFree.popLast() { id = f; t.registries[f] = r } else { id = t.registries.count; t.registries.append(r) }
        realm.heap.setInternalInt(o, Int64(id + 1))
        jsInstallWeakProcessor(realm)
        return o
    }
    realm.defineMethod(frp, "register", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        guard let r = realm.registry(args.this) else { throw realm.throwTypeError("FinalizationRegistry.prototype.register called on incompatible receiver") }
        let target = args[0], held = args[1], token = args[2]
        guard realm.canBeHeldWeakly(target) else { throw realm.throwTypeError("FinalizationRegistry.prototype.register: invalid target") }
        if realm.heap.sameValue(target, held) { throw realm.throwTypeError("FinalizationRegistry.prototype.register: target and holdings must not be same") }
        if !realm.canBeHeldWeakly(token) && !token.isUndefined { throw realm.throwTypeError("FinalizationRegistry.prototype.register: invalid unregister token") }
        if !realm.heap.noteGrowth(48) { throw JSThrow() }
        r.cells.append((target, held, token))
        return .undefined
    }
    realm.defineMethod(frp, "unregister", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        guard let r = realm.registry(args.this) else { throw realm.throwTypeError("FinalizationRegistry.prototype.unregister called on incompatible receiver") }
        let token = args[0]
        guard realm.canBeHeldWeakly(token) else { throw realm.throwTypeError("Invalid unregisterToken") }
        let before = r.cells.count
        r.cells.removeAll { !$0.token.isUndefined && $0.token == token }
        return .bool(r.cells.count != before)
    }
    _ = heap.defineOwnProperty(frp, tagKey, .data(realm.string("FinalizationRegistry"), [.configurable]))
}
