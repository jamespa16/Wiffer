// Symbol built-ins (ROADMAP Phase 9C): completes the skeleton's Symbol
// constructor with the global registry (Symbol.for / keyFor), `description`,
// valueOf, @@toPrimitive and @@toStringTag. The well-known symbols are
// defined by jsbuiltins_base. The registry is an ordinary null-prototype
// object (intrinsic .symbolRegistry) mapping key strings to symbols, so the
// GC keeps registered symbols alive.

extension JSRealm {
    func b2ThisSymbol(_ t: JSValue) throws(JSThrow) -> JSValue {
        if t.isSymbol { return t }
        if heap.kind(t) == .symbolWrapper { return heap.slot(t, 0) }
        throw throwTypeError("Symbol.prototype method called on incompatible receiver " + describeForError(t))
    }
}

func jsInstallSymbol(_ realm: JSRealm) {
    let heap = realm.heap
    let sc = realm.intrinsic(.symbolConstructor)
    let sp = realm.intrinsic(.symbolPrototype)
    realm.setIntrinsic(.symbolRegistry, heap.newObject(proto: .null))

    realm.defineMethod(sc, "for", length: 1, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let k = try realm.b2Str(args[0])
        let reg = realm.intrinsic(.symbolRegistry)
        guard let key = realm.heap.propertyKey(k) else { return .undefined }
        if let p = realm.heap.getOwnProperty(reg, key) { return p.value }
        let sym = realm.heap.newSymbol(description: k)
        _ = realm.heap.root(sym)
        let idx = Int(sym.handle)
        if idx < realm.heap.symbols.count { realm.heap.symbols[idx].registryKey = true }
        _ = realm.heap.defineOwnProperty(reg, key, .data(sym, [.writable, .enumerable, .configurable]))
        return sym
    })
    realm.defineMethod(sc, "keyFor", length: 1, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let s = args[0]
        guard s.isSymbol else { throw realm.throwTypeError(realm.safeToString(s) + " is not a symbol") }
        let idx = Int(s.handle)
        if idx < realm.heap.symbols.count && realm.heap.symbols[idx].registryKey {
            return realm.heap.symbols[idx].description
        }
        return .undefined
    })
    realm.defineGetter(sp, "description") { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let s = try realm.b2ThisSymbol(args.this)
        return realm.heap.symbolDescription(s)
    }
    realm.defineMethod(sp, "valueOf", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        try realm.b2ThisSymbol(args.this)
    }
    let tp = realm.defineMethod(sp, "[Symbol.toPrimitive]", length: 1, key: .symbol(heap.symbolsWellKnown.toPrimitive.handle)) {
        (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        try realm.b2ThisSymbol(args.this)
    }
    _ = heap.defineOwnProperty(sp, .symbol(heap.symbolsWellKnown.toPrimitive.handle), .data(tp, [.configurable]))
    _ = heap.defineOwnProperty(sp, .symbol(heap.symbolsWellKnown.toStringTag.handle),
                               .data(realm.string("Symbol"), [.configurable]))
}
