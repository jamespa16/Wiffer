// BigInt built-ins (ROADMAP Phase 9E): the BigInt function (not a
// constructor), asIntN/asUintN, and the prototype (toString(radix),
// toLocaleString, valueOf, @@toStringTag). Arithmetic lives in
// jsbigint.swift / jsbigint_ops.swift.

extension JSRealm {
    func thisBigInt(_ t: JSValue) throws(JSThrow) -> JSValue {
        if t.isBigInt { return t }
        if heap.kind(t) == .bigintWrapper { return heap.slot(t, 0) }
        throw throwTypeError("BigInt.prototype method called on incompatible receiver " + describeForError(t))
    }

    /// ToIndex for a bits argument (RangeError over 2^53 - 1).
    func bigintBitsArg(_ v: JSValue) throws(JSThrow) -> Int {
        if v.isUndefined { return 0 }
        let d = jsToIntegerOrInfinity(try toNumber(v))
        if d < 0 || d > 9007199254740991 { throw throwRangeError("Invalid value: not (convertible to) a safe integer") }
        return Int(d)
    }
}

func jsInstallBigInt(_ realm: JSRealm) {
    let heap = realm.heap
    let bp = realm.intrinsic(.bigintPrototype)
    let ctor = realm.defineConstructor("BigInt", length: 1, prototype: bp) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        if args.isConstruct { throw realm.throwTypeError("BigInt is not a constructor") }
        let rd = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: rd) }
        let prim = try realm.toPrimitive(args[0], hint: .number)
        _ = realm.heap.root(prim)
        if prim.isNumber { return try realm.numberToBigInt(prim.numberValue) }
        return try realm.toBigInt(prim)
    }
    realm.defineMethod(ctor, "asIntN", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let bits = try realm.bigintBitsArg(args[0])
        let b = try realm.toBigInt(args[1])
        let x = realm.heap.bigintValue(b)
        // Already in range: nothing to wrap (and no size limit to hit).
        if bits > jsBNBitLength(x.mag) { return b }
        if bits > realm.limits.maxBigIntBits { throw realm.bigintTooBig() }
        return try realm.makeBigInt(jsBNAsIntN(bits, x))
    }
    realm.defineMethod(ctor, "asUintN", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let bits = try realm.bigintBitsArg(args[0])
        let b = try realm.toBigInt(args[1])
        let x = realm.heap.bigintValue(b)
        if !x.negative && bits >= jsBNBitLength(x.mag) { return b }
        if bits > realm.limits.maxBigIntBits { throw realm.bigintTooBig() }
        return try realm.makeBigInt(jsBNAsUintN(bits, x))
    }
    realm.defineMethod(bp, "valueOf", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        try realm.thisBigInt(args.this)
    }
    realm.defineMethod(bp, "toString", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let b = try realm.thisBigInt(args.this)
        var radix = 10
        if !args[0].isUndefined {
            let r = jsToIntegerOrInfinity(try realm.toNumber(args[0]))
            guard r >= 2 && r <= 36 else { throw realm.throwRangeError("toString() radix must be between 2 and 36") }
            radix = Int(r)
        }
        return realm.heap.bigintToString(b, radix: radix)
    }
    realm.defineMethod(bp, "toLocaleString", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let b = try realm.thisBigInt(args.this)
        return try realm.jsLocaleBigInt(b, args[0], args[1])
    }
    _ = heap.defineOwnProperty(bp, .symbol(heap.symbolsWellKnown.toStringTag.handle),
                               .data(realm.string("BigInt"), [.configurable]))
}

extension JSRealm {
    /// BigInt.prototype.toLocaleString: en-US digit grouping.
    func jsLocaleBigInt(_ b: JSValue, _ locales: JSValue, _ options: JSValue) throws(JSThrow) -> JSValue {
        let x = heap.bigintValue(b)
        let digits = jsBNMagToDigits(x.mag, radix: 10)
        var out: [UInt8] = x.negative ? [0x2D] : []
        for (i, d) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(0x2C) }
            out.append(d)
        }
        return heap.newString(latin1: out)
    }
}
