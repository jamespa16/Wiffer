// The realm's base intrinsics (ROADMAP Phase 9B): the skeleton later
// built-in phases fill in (see the registration API at the top of
// jsrealm.swift).
//
// Installed here:
//   Object.prototype: toString, valueOf, hasOwnProperty, isPrototypeOf,
//     propertyIsEnumerable; Object(v), Object.getPrototypeOf,
//     Object.setPrototypeOf, Object.defineProperty, Object.keys,
//     Object.create (minimal: 9C completes Object)
//   Function.prototype: call, apply (the VM dispatches both without Swift
//     recursion), bind, toString, [Symbol.hasInstance]; Function(...)
//   Array(...), Array.isArray, Array.prototype.push / values /
//     [Symbol.iterator], %ArrayIteratorPrototype%.next
//   String(v), String.prototype.toString / valueOf / [Symbol.iterator],
//     %StringIteratorPrototype%.next
//   Number(v), Boolean(v) with toString/valueOf, Symbol(desc) with the
//     well-known symbols and Symbol.prototype.toString
//   Error, TypeError, RangeError, ReferenceError, SyntaxError, EvalError,
//     URIError (message, cause, a V8-style `stack` string),
//     Error.prototype.name / message / toString
//   globalThis, undefined, NaN, Infinity, eval (indirect; direct eval is
//     the VM's), print (realm.printHandler or realm.output)
//
// 9C owns the rest of Object/Array/String/Number/Math/JSON and may replace
// any method here by defining it again.

func jsInstallBaseBuiltins(_ realm: JSRealm) {
    let heap = realm.heap
    // Native 0: Function.prototype itself (returns undefined).
    _ = realm.registerNative("", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in .undefined }
    let op = realm.objectPrototype
    let fp = realm.functionPrototype
    _ = heap.defineOwnProperty(fp, heap.names.length, .data(.int32(0), [.configurable]))
    _ = heap.defineOwnProperty(fp, heap.names.name, .data(.string(0), [.configurable]))

    func proto(_ i: JSIntrinsic, kind: JSObjectKind = .ordinary, slot: JSValue? = nil) -> JSValue {
        let p = heap.newObject(proto: op, kind: kind)
        if let s = slot { heap.setSlots(p, [s]) }
        realm.setIntrinsic(i, p)
        return p
    }
    let ap = heap.newArray(proto: op)
    realm.setIntrinsic(.arrayPrototype, ap)
    let sp = heap.newStringObject(proto: op, string: .string(0))
    realm.setIntrinsic(.stringPrototype, sp)
    let np = proto(.numberPrototype, kind: .numberWrapper, slot: .int32(0))
    let bp = proto(.booleanPrototype, kind: .booleanWrapper, slot: .false)
    let syp = proto(.symbolPrototype)
    _ = proto(.bigintPrototype)
    let itp = proto(.iteratorPrototype)
    let aitp = heap.newObject(proto: itp)
    realm.setIntrinsic(.arrayIteratorPrototype, aitp)
    let sitp = heap.newObject(proto: itp)
    realm.setIntrinsic(.stringIteratorPrototype, sitp)
    let iterKey = JSPropertyKey.symbol(heap.symbolsWellKnown.iterator.handle)
    let tagKey = JSPropertyKey.symbol(heap.symbolsWellKnown.toStringTag.handle)

    // %ThrowTypeError%
    let tte = realm.newNativeFunction(realm.registerNative("", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        throw realm.throwTypeError("'caller', 'callee', and 'arguments' properties may not be accessed")
    })
    heap.preventExtensions(tte)
    realm.setIntrinsic(.throwTypeError, tte)

    // ------------------------------------------------------------ Object
    realm.defineMethod(op, "toString", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let t = args.this
        if t.isUndefined { return realm.string("[object Undefined]") }
        if t.isNull { return realm.string("[object Null]") }
        let o = try realm.toObject(t)
        var tag: String
        switch realm.heap.kind(o) {
        case .array: tag = "Array"
        case .function, .nativeFunction, .boundFunction: tag = "Function"
        case .error: tag = "Error"
        case .booleanWrapper: tag = "Boolean"
        case .numberWrapper: tag = "Number"
        case .stringWrapper: tag = "String"
        case .date: tag = "Date"
        case .regexp: tag = "RegExp"
        case .arguments: tag = "Arguments"
        default: tag = "Object"
        }
        let r = realm.heap.root(o)
        defer { realm.heap.popRoots(to: r.slot) }
        let st = try realm.getV(o, .symbol(realm.heap.symbolsWellKnown.toStringTag.handle))
        if st.isString { tag = realm.heap.swiftString(st) }
        return realm.string("[object " + tag + "]")
    }
    realm.defineMethod(op, "valueOf", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        try realm.toObject(args.this)
    }
    realm.defineMethod(op, "hasOwnProperty", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let k = try realm.toPropertyKey(args[0])
        let o = try realm.toObject(args.this)
        return .bool((try realm.objGetOwnProperty(o, k)) != nil)
    }
    realm.defineMethod(op, "isPrototypeOf", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        guard args[0].isObject else { return .false }
        let o = try realm.toObject(args.this)
        var p = try realm.objGetPrototypeOf(args[0])
        var n = 0
        while p.isObject && n < JSHeap.maxProtoChain {
            if p == o { return .true }
            p = try realm.objGetPrototypeOf(p)
            n += 1
        }
        return .false
    }
    realm.defineMethod(op, "propertyIsEnumerable", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let k = try realm.toPropertyKey(args[0])
        let o = try realm.toObject(args.this)
        return .bool((try realm.objGetOwnProperty(o, k))?.enumerable ?? false)
    }
    let objectCtor = realm.defineConstructor("Object", length: 1, prototype: op) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        if args.isConstruct && args.newTarget != args.callee {
            return realm.heap.newObject(proto: try realm.prototype(forNewTarget: args.newTarget, default: .objectPrototype))
        }
        let v = args[0]
        if v.isNullish { return realm.heap.newObject(proto: realm.objectPrototype) }
        return try realm.toObject(v)
    }
    realm.setIntrinsic(.objectConstructor, objectCtor)
    realm.defineMethod(objectCtor, "getPrototypeOf", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let o = try realm.toObject(args[0])
        return try realm.objGetPrototypeOf(o)
    }
    realm.defineMethod(objectCtor, "setPrototypeOf", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let o = args[0], p = args[1]
        if o.isNullish { throw realm.throwTypeError("Object.setPrototypeOf called on null or undefined") }
        guard p.isObject || p.isNull else { throw realm.throwTypeError("Object prototype may only be an Object or null") }
        if o.isObject, !(try realm.objSetPrototypeOf(o, p)) { throw realm.throwTypeError("Cyclic or non-extensible prototype") }
        return o
    }
    realm.defineMethod(objectCtor, "create", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let p = args[0]
        guard p.isObject || p.isNull else { throw realm.throwTypeError("Object prototype may only be an Object or null") }
        let o = realm.heap.newObject(proto: p)
        if !args[1].isUndefined {
            let r = realm.heap.root(o)
            defer { realm.heap.popRoots(to: r.slot) }
            let props = try realm.toObject(args[1])
            _ = realm.heap.root(props)
            for k in try realm.objOwnKeys(props) {
                guard let pr = try realm.objGetOwnProperty(props, k), pr.enumerable else { continue }
                let d = try realm.toPropertyDescriptor(try realm.getV(props, k))
                if !realm.heap.defineOwnProperty(o, k, d) { throw realm.throwTypeError("Cannot define property " + realm.keyDisplay(k)) }
            }
        }
        return o
    }
    realm.defineMethod(objectCtor, "defineProperty", length: 3) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let o = args[0]
        guard o.isObject else { throw realm.throwTypeError("Object.defineProperty called on non-object") }
        let k = try realm.toPropertyKey(args[1])
        let d = try realm.toPropertyDescriptor(args[2])
        if !(try realm.objDefineOwnProperty(o, k, d)) { throw realm.throwTypeError("Cannot redefine property: " + realm.keyDisplay(k)) }
        return o
    }
    realm.defineMethod(objectCtor, "keys", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let o = try realm.toObject(args[0])
        let r = realm.heap.root(o)
        defer { realm.heap.popRoots(to: r.slot) }
        let a = realm.heap.newArray(proto: realm.arrayPrototype)
        _ = realm.heap.root(a)
        for k in try realm.objOwnKeys(o) where !k.isSymbol {
            guard let p = try realm.objGetOwnProperty(o, k), p.enumerable else { continue }
            _ = realm.heap.createDataProperty(a, .index(realm.heap.arrayLength(a)), realm.heap.keyValue(k))
        }
        return a
    }

    // ---------------------------------------------------------- Function
    realm.callNativeIndex = realm.registerNative("call", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        guard realm.heap.isCallable(args.this) else { throw realm.throwTypeError("Function.prototype.call called on a non-function") }
        var rest: [JSValue] = []
        if args.count > 1 { for i in 1..<args.count { rest.append(args[i]) } }
        return try realm.call(args.this, this: args[0], args: rest)
    }
    _ = heap.defineOwnProperty(fp, heap.key("call"), .data(realm.newNativeFunction(realm.callNativeIndex), [.writable, .configurable]))
    realm.applyNativeIndex = realm.registerNative("apply", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        guard realm.heap.isCallable(args.this) else { throw realm.throwTypeError("Function.prototype.apply called on a non-function") }
        let arr = args[1]
        var list: [JSValue] = []
        if !arr.isNullish {
            guard arr.isObject else { throw realm.throwTypeError("CreateListFromArrayLike called on non-object") }
            let n = try realm.toLength(try realm.getV(arr, realm.heap.names.length))
            if n > 1 << 16 { throw realm.throwRangeError("Maximum call stack size exceeded") }
            for i in 0..<n { list.append(try realm.getV(arr, .index(UInt32(i)))) }
        }
        return try realm.call(args.this, this: args[0], args: list)
    }
    _ = heap.defineOwnProperty(fp, heap.key("apply"), .data(realm.newNativeFunction(realm.applyNativeIndex), [.writable, .configurable]))
    realm.defineMethod(fp, "bind", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let target = args.this
        guard realm.heap.isCallable(target) else { throw realm.throwTypeError("Bind must be called on a function") }
        let h = realm.heap
        var flags: JSObjectFlags = [.extensible, .callable]
        if h.flags(target).contains(.constructor) { flags.insert(.constructor) }
        let b = h.newObject(proto: h.getPrototypeOf(target), kind: .boundFunction, flags: flags)
        let r = h.root(b)
        defer { h.popRoots(to: r.slot) }
        var slots: [JSValue] = [target, args[0]]
        if args.count > 1 { for i in 1..<args.count { slots.append(args[i]) } }
        h.setSlots(b, slots)
        var len = 0.0
        if h.hasOwnProperty(target, h.names.length) {
            let l = try realm.getV(target, h.names.length)
            if l.isNumber {
                let d = jsToIntegerOrInfinity(l.numberValue)
                len = max(0, d - Double(max(0, args.count - 1)))
            }
        }
        _ = h.defineOwnProperty(b, h.names.length, .data(.number(len), [.configurable]))
        let nm = try realm.getV(target, h.names.name)
        let s = realm.string("bound " + (nm.isString ? h.swiftString(nm) : ""))
        _ = h.defineOwnProperty(b, h.names.name, .data(s, [.configurable]))
        return b
    }
    realm.defineMethod(fp, "toString", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let f = args.this
        let h = realm.heap
        guard h.isCallable(f) else { throw realm.throwTypeError("Function.prototype.toString requires that 'this' be a Function") }
        if h.kind(f) == .function, let c = realm.codeFor(function: f), let src = c.source {
            let a = Int(c.sourceStart), b = Int(c.sourceEnd)
            if a >= 0 && b <= src.bytes.count && a < b {
                var sb = JSStringBuilder()
                sb.append(utf8: Array(src.bytes[a..<b]))
                return h.newString(sb)
            }
        }
        return realm.string("function " + realm.functionName(f) + "() { [native code] }")
    }
    realm.defineMethod(fp, "[Symbol.hasInstance]", length: 1, key: .symbol(heap.symbolsWellKnown.hasInstance.handle)) {
        (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        guard realm.heap.isCallable(args.this) else { return .false }
        return .bool(try realm.ordinaryHasInstance(args.this, args[0]))
    }
    let funcCtor = realm.defineConstructor("Function", length: 1, prototype: fp) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        var params: [String] = []
        var body = ""
        for i in 0..<args.count {
            let s = try realm.toSwiftString(args[i])
            if i == args.count - 1 { body = s } else { params.append(s) }
        }
        let src = "(function anonymous(" + params.joined(separator: ",") + "\n) {\n" + body + "\n})"
        let depth = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: depth) }
        let closure = try realm.compileScriptClosure(Array(src.utf8), name: "anonymous", eval: true, strict: false)
        return try realm.call(closure, this: realm.global, args: [])
    }
    realm.setIntrinsic(.functionConstructor, funcCtor)

    // ------------------------------------------------------------- Array
    let arrayCtor = realm.defineConstructor("Array", length: 1, prototype: ap) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let p = try realm.prototype(forNewTarget: args.newTarget, default: .arrayPrototype)
        if args.count == 1 && args[0].isNumber {
            guard let n = jsArrayLength(args[0]) else { throw realm.throwRangeError("Invalid array length") }
            let a = h.newArray(proto: p)
            _ = h.setArrayLength(a, n)
            return a
        }
        return h.newArray(proto: p, elements: args.values)
    }
    realm.setIntrinsic(.arrayConstructor, arrayCtor)
    realm.defineMethod(arrayCtor, "isArray", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        .bool(try realm.isArray(args[0]))
    }
    realm.defineMethod(ap, "push", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let o = try realm.toObject(args.this)
        if h.kind(o) == .array && !h.flags(o).contains(.lengthReadOnly) {
            for i in 0..<args.count {
                let n = h.arrayLength(o)
                if n == UInt32.max || !h.createDataProperty(o, .index(n), args[i]) {
                    if h.termination != nil { throw JSThrow() }
                    throw realm.throwTypeError("Cannot add property to array")
                }
            }
            return .number(Int(h.arrayLength(o)))
        }
        let r = h.root(o)
        defer { h.popRoots(to: r.slot) }
        var n = try realm.toLength(try realm.getV(o, h.names.length))
        for i in 0..<args.count {
            try realm.setV(o, try realm.toPropertyKey(.number(n)), args[i], strict: true)
            n += 1
        }
        try realm.setV(o, h.names.length, .number(n), strict: true)
        return .number(n)
    }
    let values = realm.defineMethod(ap, "values", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let o = try realm.toObject(args.this)
        let r = realm.heap.root(o)
        defer { realm.heap.popRoots(to: r.slot) }
        let it = realm.heap.newObject(proto: realm.intrinsic(.arrayIteratorPrototype), kind: .iterator)
        realm.heap.setSlots(it, [o])
        return it
    }
    _ = heap.defineOwnProperty(ap, iterKey, .data(values, [.writable, .configurable]))
    realm.setIntrinsic(.arrayValues, values)
    realm.defineMethod(aitp, "next", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let it = args.this
        guard realm.heap.kind(it) == .iterator, !realm.heap.flags(it).contains(.user3) else {
            throw realm.throwTypeError("next method called on an incompatible receiver")
        }
        let (done, v) = try realm.iteratorStep(it, .hole)
        return try realm.iterResult(v, done: done)
    }
    _ = heap.defineOwnProperty(aitp, tagKey, .data(realm.string("Array Iterator"), [.configurable]))
    realm.defineMethod(itp, "[Symbol.iterator]", length: 0, key: iterKey) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        args.this
    }

    // ------------------------------------------------------------ String
    let stringCtor = realm.defineConstructor("String", length: 1, prototype: sp) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        var s: JSValue = .string(0)
        if args.count > 0 {
            if args[0].isSymbol && !args.isConstruct { return realm.string(realm.safeToString(args[0])) }
            s = try realm.toStringValue(args[0])
        }
        if !args.isConstruct { return s }
        let r = realm.heap.root(s)
        defer { realm.heap.popRoots(to: r.slot) }
        let p = try realm.prototype(forNewTarget: args.newTarget, default: .stringPrototype)
        return realm.heap.newStringObject(proto: p, string: s)
    }
    realm.setIntrinsic(.stringConstructor, stringCtor)
    let thisString: JSNativeFunction = { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let t = args.this
        if t.isString { return t }
        if realm.heap.kind(t) == .stringWrapper { return realm.heap.slot(t, 0) }
        throw realm.throwTypeError("String.prototype.toString requires that 'this' be a String")
    }
    realm.defineMethod(sp, "toString", length: 0, thisString)
    realm.defineMethod(sp, "valueOf", length: 0, thisString)
    let strIter = realm.defineMethod(sp, "[Symbol.iterator]", length: 0, key: iterKey) {
        (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        if args.this.isNullish { throw realm.throwTypeError("String.prototype[Symbol.iterator] called on null or undefined") }
        let s = try realm.toStringValue(args.this)
        let r = realm.heap.root(s)
        defer { realm.heap.popRoots(to: r.slot) }
        let it = realm.heap.newObject(proto: realm.intrinsic(.stringIteratorPrototype), kind: .iterator, flags: [.extensible, .user3])
        realm.heap.setSlots(it, [s])
        return it
    }
    realm.setIntrinsic(.stringIterator, strIter)
    realm.defineMethod(sitp, "next", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let it = args.this
        guard realm.heap.kind(it) == .iterator, realm.heap.flags(it).contains(.user3) else {
            throw realm.throwTypeError("next method called on an incompatible receiver")
        }
        let (done, v) = try realm.iteratorStep(it, .hole)
        return try realm.iterResult(v, done: done)
    }
    _ = heap.defineOwnProperty(sitp, tagKey, .data(realm.string("String Iterator"), [.configurable]))

    // ----------------------------------------------- Number and Boolean
    let numberCtor = realm.defineConstructor("Number", length: 1, prototype: np) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let n: JSValue = args.count > 0 ? .number(try realm.toNumber(args[0])) : .int32(0)
        if !args.isConstruct { return n }
        let p = try realm.prototype(forNewTarget: args.newTarget, default: .numberPrototype)
        let o = realm.heap.newObject(proto: p, kind: .numberWrapper)
        realm.heap.setSlots(o, [n])
        return o
    }
    realm.setIntrinsic(.numberConstructor, numberCtor)
    realm.defineMethod(np, "valueOf", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        try realm.thisNumber(args.this)
    }
    realm.defineMethod(np, "toString", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let n = try realm.thisNumber(args.this)
        var radix = 10
        if !args[0].isUndefined {
            let r = jsToIntegerOrInfinity(try realm.toNumber(args[0]))
            guard r >= 2 && r <= 36 else { throw realm.throwRangeError("toString() radix must be between 2 and 36") }
            radix = Int(r)
        }
        if radix == 10 { return realm.heap.numberToString(n.numberValue) }
        return realm.heap.newString(latin1: jsNumberToRadixString(n.numberValue, radix))
    }
    let booleanCtor = realm.defineConstructor("Boolean", length: 1, prototype: bp) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let b = JSValue.bool(realm.heap.toBoolean(args[0]))
        if !args.isConstruct { return b }
        let p = try realm.prototype(forNewTarget: args.newTarget, default: .booleanPrototype)
        let o = realm.heap.newObject(proto: p, kind: .booleanWrapper)
        realm.heap.setSlots(o, [b])
        return o
    }
    realm.setIntrinsic(.booleanConstructor, booleanCtor)
    let thisBool: JSNativeFunction = { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let t = args.this
        if t.isBool { return t }
        if realm.heap.kind(t) == .booleanWrapper { return realm.heap.slot(t, 0) }
        throw realm.throwTypeError("Boolean.prototype.valueOf requires that 'this' be a Boolean")
    }
    realm.defineMethod(bp, "valueOf", length: 0, thisBool)
    realm.defineMethod(bp, "toString", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let t = args.this
        let b = t.isBool ? t : realm.heap.kind(t) == .booleanWrapper ? realm.heap.slot(t, 0) : JSValue.undefined
        guard b.isBool else { throw realm.throwTypeError("Boolean.prototype.toString requires that 'this' be a Boolean") }
        return realm.heap.toPrimitiveString(b) ?? .string(0)
    }

    // ------------------------------------------------------------ Symbol
    let symbolCtor = realm.newNativeFunction(realm.registerNative("Symbol", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        if args.isConstruct { throw realm.throwTypeError("Symbol is not a constructor") }
        let d: JSValue = args[0].isUndefined ? .undefined : try realm.toStringValue(args[0])
        return realm.heap.newSymbol(description: d)
    })
    realm.setIntrinsic(.symbolConstructor, symbolCtor)
    realm.defineGlobal("Symbol", symbolCtor)
    _ = heap.defineOwnProperty(symbolCtor, heap.names.prototype, .data(syp, []))
    _ = heap.defineOwnProperty(syp, heap.names.constructor, .data(symbolCtor, [.writable, .configurable]))
    let w = heap.symbolsWellKnown
    let wk: [(String, JSValue)] = [("asyncIterator", w.asyncIterator), ("hasInstance", w.hasInstance),
        ("isConcatSpreadable", w.isConcatSpreadable), ("iterator", w.iterator), ("match", w.match),
        ("matchAll", w.matchAll), ("replace", w.replace), ("search", w.search), ("species", w.species),
        ("split", w.split), ("toPrimitive", w.toPrimitive), ("toStringTag", w.toStringTag),
        ("unscopables", w.unscopables)]
    for (n, s) in wk { realm.defineValue(symbolCtor, n, s, []) }
    realm.defineMethod(syp, "toString", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let t = args.this
        let s = t.isSymbol ? t : realm.heap.kind(t) == .symbolWrapper ? realm.heap.slot(t, 0) : JSValue.undefined
        guard s.isSymbol else { throw realm.throwTypeError("Symbol.prototype.toString requires that 'this' be a Symbol") }
        return realm.string(realm.safeToString(s))
    }

    // ------------------------------------------------------------ Errors
    let ep = proto(.errorPrototype)
    realm.defineValue(ep, "name", realm.string("Error"))
    realm.defineValue(ep, "message", .string(0))
    realm.defineMethod(ep, "toString", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let o = args.this
        guard o.isObject else { throw realm.throwTypeError("Error.prototype.toString called on non-object") }
        let h = realm.heap
        let nv = try realm.getV(o, h.names.name)
        let name = nv.isUndefined ? "Error" : try realm.toSwiftString(nv)
        let mv = try realm.getV(o, h.names.message)
        let msg = mv.isUndefined ? "" : try realm.toSwiftString(mv)
        if name.isEmpty { return realm.string(msg) }
        if msg.isEmpty { return realm.string(name) }
        return realm.string(name + ": " + msg)
    }
    let errorCtor = jsDefineErrorConstructor(realm, .error, ep)
    realm.setIntrinsic(.errorConstructor, errorCtor)
    let kinds: [(JSErrorKind, JSIntrinsic, JSIntrinsic)] = [
        (.typeError, .typeErrorPrototype, .typeErrorConstructor),
        (.rangeError, .rangeErrorPrototype, .rangeErrorConstructor),
        (.referenceError, .referenceErrorPrototype, .referenceErrorConstructor),
        (.syntaxError, .syntaxErrorPrototype, .syntaxErrorConstructor),
        (.evalError, .evalErrorPrototype, .evalErrorConstructor),
        (.uriError, .uriErrorPrototype, .uriErrorConstructor),
    ]
    for (k, pi, ci) in kinds {
        let p = heap.newObject(proto: ep)
        realm.setIntrinsic(pi, p)
        realm.defineValue(p, "name", realm.string(jsErrorKindName(k)))
        realm.defineValue(p, "message", .string(0))
        let c = jsDefineErrorConstructor(realm, k, p)
        _ = heap.setPrototypeOf(c, errorCtor)
        realm.setIntrinsic(ci, c)
    }

    // ----------------------------------------------------------- Globals
    let g = realm.global
    realm.defineValue(g, "globalThis", g, [.writable, .configurable])
    realm.defineValue(g, "undefined", .undefined, [])
    realm.defineValue(g, "NaN", .nan, [])
    realm.defineValue(g, "Infinity", .double(.infinity), [])
    let evalFn = realm.defineMethod(g, "eval", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let x = args[0]
        guard x.isString else { return x }
        let src = Array(realm.heap.swiftString(x).utf8)
        let depth = realm.heap.rootDepth
        defer { realm.heap.popRoots(to: depth) }
        let closure = try realm.compileScriptClosure(src, name: "eval", eval: true, strict: false)
        return try realm.call(closure, this: realm.global, args: [])
    }
    realm.setIntrinsic(.eval, evalFn)
    realm.defineMethod(g, "print", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        var parts: [String] = []
        for i in 0..<args.count { parts.append(try realm.toSwiftString(args[i])) }
        let line = parts.joined(separator: " ")
        if let h = realm.printHandler { h(line) } else { realm.output.append(line) }
        return .undefined
    }
}

/// An Error constructor of one kind, with `prototype` p.
func jsDefineErrorConstructor(_ realm: JSRealm, _ kind: JSErrorKind, _ p: JSValue) -> JSValue {
    let name = jsErrorKindName(kind)
    let dflt: JSIntrinsic
    switch kind {
    case .error: dflt = .errorPrototype
    case .typeError: dflt = .typeErrorPrototype
    case .rangeError: dflt = .rangeErrorPrototype
    case .referenceError: dflt = .referenceErrorPrototype
    case .syntaxError: dflt = .syntaxErrorPrototype
    case .evalError: dflt = .evalErrorPrototype
    case .uriError: dflt = .uriErrorPrototype
    case .aggregateError: dflt = .aggregateErrorPrototype
    }
    return realm.defineConstructor(name, length: 1, prototype: p) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let depth = h.rootDepth
        defer { h.popRoots(to: depth) }
        let proto = args.isConstruct ? try realm.prototype(forNewTarget: args.newTarget, default: dflt) : realm.intrinsic(dflt)
        _ = h.root(proto)
        var msg: JSValue = .undefined
        if !args[0].isUndefined {
            msg = try realm.toStringValue(args[0])
            _ = h.root(msg)
        }
        let e = realm.makeErrorObject(kind, message: msg, proto: proto)
        _ = h.root(e)
        let opts = args[1]
        if opts.isObject && h.hasProperty(opts, h.names.cause) {
            let c = try realm.getV(opts, h.names.cause)
            _ = h.defineOwnProperty(e, h.names.cause, .data(c, [.writable, .configurable]))
        }
        return e
    }
}

extension JSRealm {
    /// { value, done } (allocates).
    public func iterResult(_ v: JSValue, done: Bool) throws(JSThrow) -> JSValue {
        let r = heap.root(v)
        defer { heap.popRoots(to: r.slot) }
        let o = heap.newObject(proto: objectPrototype)
        _ = heap.createDataProperty(o, heap.names.value, v)
        _ = heap.createDataProperty(o, heap.names.done, .bool(done))
        return o
    }

    func thisNumber(_ t: JSValue) throws(JSThrow) -> JSValue {
        if t.isNumber { return t }
        if heap.kind(t) == .numberWrapper { return heap.slot(t, 0) }
        throw throwTypeError("Number.prototype method called on incompatible receiver")
    }

    /// ToPropertyDescriptor.
    public func toPropertyDescriptor(_ v: JSValue) throws(JSThrow) -> JSPropertyDescriptor {
        guard v.isObject else { throw throwTypeError("Property description must be an object") }
        let r = heap.root(v)
        defer { heap.popRoots(to: r.slot) }
        var d = JSPropertyDescriptor()
        let n = heap.names
        if heap.hasProperty(v, n.enumerable) { d.enumerable = heap.toBoolean(try getV(v, n.enumerable)) }
        if heap.hasProperty(v, n.configurable) { d.configurable = heap.toBoolean(try getV(v, n.configurable)) }
        if heap.hasProperty(v, n.value) { d.value = try getV(v, n.value); _ = heap.root(d.value ?? .undefined) }
        if heap.hasProperty(v, n.writable) { d.writable = heap.toBoolean(try getV(v, n.writable)) }
        if heap.hasProperty(v, n.get) {
            let g = try getV(v, n.get)
            if !g.isUndefined && !heap.isCallable(g) { throw throwTypeError("Getter must be a function") }
            d.getter = g
            _ = heap.root(g)
        }
        if heap.hasProperty(v, n.set) {
            let s = try getV(v, n.set)
            if !s.isUndefined && !heap.isCallable(s) { throw throwTypeError("Setter must be a function") }
            d.setter = s
            _ = heap.root(s)
        }
        if d.isAccessorDescriptor && d.isDataDescriptor {
            throw throwTypeError("Invalid property descriptor. Cannot both specify accessors and a value or writable attribute")
        }
        return d
    }
}
