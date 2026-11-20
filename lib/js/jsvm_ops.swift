// The VM's abstract operations (ROADMAP Phase 9B): conversions, operators,
// property access that may call accessors, name resolution through
// environments, environments themselves, iteration, eval and classes.
//
// Public helpers for natives (all may run JS, so they throw(JSThrow)):
//   toPrimitive(v, hint:)  toNumber(v)  toStringValue(v) -> string value
//   toPropertyKey(v) -> JSPropertyKey  toObject(v)  toLength(v) -> Int
//   getV(v, key) (primitives use their prototype)  setV(o, key, v, strict:)
//   looseEquals(a, b)  instanceOf(v, target)  getIterator(v) /
//   iteratorStep(it, next) / iteratorClose(it, next)
//   prototypeFromConstructor(newTarget, default intrinsic)
//   jsPowNumber(x, y): Number::exponentiate (no libm).

public enum JSHint { case default_, number, string }

/// Where a name was found by a dynamic lookup.
enum JSNameLoc {
    case slot(JSValue, Int, Int32)
    case prop(JSValue)
    case with(JSValue)
    case lex
    case global
    case none
}

extension JSRealm {
    // MARK: Conversions

    public func toPrimitive(_ v: JSValue, hint: JSHint = .default_) throws(JSThrow) -> JSValue {
        guard v.isObject else { return v }
        let r = heap.root(v)
        defer { heap.popRoots(to: r.slot) }
        let ex = try getV(v, .symbol(heap.symbolsWellKnown.toPrimitive.handle))
        if !ex.isNullish {
            guard heap.isCallable(ex) else { throw throwTypeError("Symbol.toPrimitive is not a function") }
            let h = hint == .number ? "number" : hint == .string ? "string" : "default"
            let res = try call(ex, this: v, args: [heap.atom(h)])
            if res.isObject { throw throwTypeError("Cannot convert object to primitive value") }
            return res
        }
        let order = hint == .string ? [heap.names.toString, heap.names.valueOf] : [heap.names.valueOf, heap.names.toString]
        for k in order {
            let m = try getV(v, k)
            if heap.isCallable(m) {
                let res = try call(m, this: v, args: [])
                if !res.isObject { return res }
            }
        }
        throw throwTypeError("Cannot convert object to primitive value")
    }

    public func toNumber(_ v: JSValue) throws(JSThrow) -> Double {
        if let d = heap.toPrimitiveNumber(v) { return d }
        if v.isObject { return try toNumber(try toPrimitive(v, hint: .number)) }
        if v.isSymbol { throw throwTypeError("Cannot convert a Symbol value to a number") }
        throw throwTypeError("Cannot convert a BigInt value to a number")
    }

    public func toStringValue(_ v: JSValue) throws(JSThrow) -> JSValue {
        if let s = heap.toPrimitiveString(v) { return s }
        if v.isObject { return try toStringValue(try toPrimitive(v, hint: .string)) }
        if v.isSymbol { throw throwTypeError("Cannot convert a Symbol value to a string") }
        throw throwTypeError("Cannot convert a BigInt value to a string")
    }

    /// ToString as Swift text.
    public func toSwiftString(_ v: JSValue) throws(JSThrow) -> String { heap.swiftString(try toStringValue(v)) }

    public func toPropertyKey(_ v: JSValue) throws(JSThrow) -> JSPropertyKey {
        if let k = heap.propertyKey(v) { return k }
        if v.isObject {
            let p = try toPrimitive(v, hint: .string)
            if let k = heap.propertyKey(p) { return k }
            return try toPropertyKey(try toStringValue(p))
        }
        return try toPropertyKey(try toStringValue(v))
    }

    public func toObject(_ v: JSValue) throws(JSThrow) -> JSValue {
        if v.isObject { return v }
        if v.isNullish { throw throwTypeError("Cannot convert undefined or null to object") }
        if v.isString { return heap.newStringObject(proto: intrinsic(.stringPrototype), string: v) }
        let (proto, kind): (JSValue, JSObjectKind) =
            v.isNumber ? (intrinsic(.numberPrototype), .numberWrapper)
            : v.isBool ? (intrinsic(.booleanPrototype), .booleanWrapper)
            : v.isSymbol ? (intrinsic(.symbolPrototype), .symbolWrapper)
            : (intrinsic(.bigintPrototype), .bigintWrapper)
        let r = heap.root(v)
        let o = heap.newObject(proto: proto, kind: kind)
        heap.setSlots(o, [v])
        heap.popRoots(to: r.slot)
        return o
    }

    /// ToLength.
    public func toLength(_ v: JSValue) throws(JSThrow) -> Int {
        let d = jsToIntegerOrInfinity(try toNumber(v))
        if d <= 0 { return 0 }
        return d >= 9007199254740991 ? 9007199254740991 : Int(d)
    }

    func keyDisplay(_ k: JSPropertyKey) -> String {
        if k.isIndex { return String(k.index) }
        if k.isSymbol {
            let d = heap.symbolDescription(.symbol(k.handle))
            return "Symbol(" + (d.isString ? heap.swiftString(d) : "") + ")"
        }
        return heap.swiftString(.string(k.handle))
    }

    /// A short description of a value for TypeError messages.
    func describeForError(_ v: JSValue) -> String {
        if v.isString {
            let s = heap.swiftString(v)
            return "\"" + (s.utf8.count > 40 ? String(s.prefix(40)) + "..." : s) + "\""
        }
        if v.isSymbol || !v.isObject { return safeToString(v) }
        if heap.isCallable(v) { return "function " + functionName(v) }
        return heap.kind(v) == .array ? "[object Array]" : "[object Object]"
    }

    // MARK: Properties

    /// [[Get]] with the receiver; primitives read their prototype.
    public func getV(_ o: JSValue, _ k: JSPropertyKey) throws(JSThrow) -> JSValue {
        if o.isObject {
            switch heap.getProperty(o, k) {
            case .value(let v): return v
            case .getter(let g): return try call(g, this: o, args: [])
            }
        }
        return try getPrimitive(o, k)
    }

    func primitivePrototype(_ o: JSValue) -> JSValue {
        if o.isString { return intrinsic(.stringPrototype) }
        if o.isNumber { return intrinsic(.numberPrototype) }
        if o.isBool { return intrinsic(.booleanPrototype) }
        if o.isSymbol { return intrinsic(.symbolPrototype) }
        return intrinsic(.bigintPrototype)
    }

    func getPrimitive(_ o: JSValue, _ k: JSPropertyKey) throws(JSThrow) -> JSValue {
        if o.isNullish {
            throw throwTypeError("Cannot read properties of " + (o.isNull ? "null" : "undefined")
                                 + " (reading '" + keyDisplay(k) + "')")
        }
        if o.isString {
            if k.isIndex {
                let i = Int(k.index)
                if i < heap.stringLength(o) { return heap.singleUnitString(heap.charCode(o, i), protecting: o) }
            } else if k == heap.names.length {
                return .number(heap.stringLength(o))
            }
        }
        switch heap.getProperty(primitivePrototype(o), k) {
        case .value(let v): return v
        case .getter(let g): return try call(g, this: o, args: [])
        }
    }

    /// [[Set]] with an accessor call; failures throw in strict code.
    public func setV(_ o: JSValue, _ k: JSPropertyKey, _ v: JSValue, strict: Bool) throws(JSThrow) {
        if o.isNullish {
            throw throwTypeError("Cannot set properties of " + (o.isNull ? "null" : "undefined")
                                 + " (setting '" + keyDisplay(k) + "')")
        }
        var value = v
        if o.isObject && k == heap.names.length && heap.kind(o) == .array && !value.isNumber {
            let r = heap.root(v)
            defer { heap.popRoots(to: r.slot) }
            value = try arrayLengthValue(v)
        }
        let target = o.isObject ? o : primitivePrototype(o)
        switch heap.setProperty(target, k, value, receiver: o) {
        case .done: return
        case .failed:
            if o.isObject && k == heap.names.length && heap.kind(o) == .array && jsArrayLength(value) == nil {
                throw throwRangeError("Invalid array length")
            }
            if strict { throw throwTypeError("Cannot assign to read only property '" + keyDisplay(k) + "' of " + describeForError(o)) }
        case .setter(let s):
            _ = try call(s, this: o, args: [v])
        }
    }

    func arrayLengthValue(_ v: JSValue) throws(JSThrow) -> JSValue {
        let d = try toNumber(v)
        let u = jsToUint32(d)
        if Double(u) != d { throw throwRangeError("Invalid array length") }
        return .number(Int(u))
    }

    /// Stack [obj v] -> [v]; a setter becomes a JS call (returns true when
    /// a frame was pushed).
    func putProperty(_ o: JSValue, _ k: JSPropertyKey, strict: Bool) throws(JSThrow) -> Bool {
        if o.isNullish {
            throw throwTypeError("Cannot set properties of " + (o.isNull ? "null" : "undefined")
                                 + " (setting '" + keyDisplay(k) + "')")
        }
        var v = stack[sp - 1]
        if o.isObject && k == heap.names.length && heap.kind(o) == .array && !v.isNumber {
            v = try arrayLengthValue(v)
        }
        let target = o.isObject ? o : primitivePrototype(o)
        switch heap.setProperty(target, k, v, receiver: o) {
        case .done: break
        case .failed:
            if o.isObject && k == heap.names.length && heap.kind(o) == .array && jsArrayLength(v) == nil {
                throw throwRangeError("Invalid array length")
            }
            if strict { throw throwTypeError("Cannot assign to read only property '" + keyDisplay(k) + "' of " + describeForError(o)) }
        case .setter(let s):
            try ensureStack(4)
            let val = stack[sp - 1]
            stack[sp - 2] = val
            stack[sp - 1] = s
            push(o)
            push(val)
            return try dispatchCall(1, mode: JSFrameMode.discard)
        }
        stack[sp - 2] = stack[sp - 1]
        sp -= 1
        return false
    }

    func deleteProperty(_ o: JSValue, _ k: JSPropertyKey, strict: Bool) throws(JSThrow) -> Bool {
        if o.isNullish {
            throw throwTypeError("Cannot convert undefined or null to object")
        }
        var ok = true
        if o.isObject {
            ok = heap.deleteProperty(o, k)
        } else if o.isString {
            ok = !(k == heap.names.length || (k.isIndex && Int(k.index) < heap.stringLength(o)))
        }
        if !ok && strict { throw throwTypeError("Cannot delete property '" + keyDisplay(k) + "' of " + describeForError(o)) }
        return ok
    }

    func superGet(this: JSValue, home: JSValue, _ k: JSPropertyKey) throws(JSThrow) -> JSValue {
        guard home.isObject else { throw throwSyntaxError("'super' keyword unexpected here") }
        let p = heap.getPrototypeOf(home)
        guard p.isObject else { throw throwTypeError("Cannot read properties of null (reading '" + keyDisplay(k) + "')") }
        switch heap.getProperty(p, k) {
        case .value(let v): return v
        case .getter(let g): return try call(g, this: this, args: [])
        }
    }

    func superSet(this: JSValue, home: JSValue, _ k: JSPropertyKey, _ v: JSValue, strict: Bool) throws(JSThrow) {
        guard home.isObject else { throw throwSyntaxError("'super' keyword unexpected here") }
        let p = heap.getPrototypeOf(home)
        guard p.isObject else { throw throwTypeError("Cannot set properties of null") }
        switch heap.setProperty(p, k, v, receiver: this) {
        case .done: return
        case .failed: if strict { throw throwTypeError("Cannot assign to read only property '" + keyDisplay(k) + "'") }
        case .setter(let s): _ = try call(s, this: this, args: [v])
        }
    }

    func defineMethodProperty(_ o: JSValue, _ k: JSPropertyKey, _ fn: JSValue, flags: UInt8) throws(JSThrow) {
        if flags & JSMethodFlags.home != 0 { heap.setSlot(fn, 2, o) }
        let en: Bool = flags & JSMethodFlags.enumerable != 0
        let d: JSPropertyDescriptor
        if flags & JSMethodFlags.getter != 0 {
            d = JSPropertyDescriptor(getter: fn, enumerable: en, configurable: true)
        } else if flags & JSMethodFlags.setter != 0 {
            d = JSPropertyDescriptor(setter: fn, enumerable: en, configurable: true)
        } else {
            d = JSPropertyDescriptor(value: fn, writable: true, enumerable: en, configurable: true)
        }
        if !heap.defineOwnProperty(o, k, d) { throw throwTypeError("Cannot redefine property: " + keyDisplay(k)) }
    }

    func prototypeFromConstructor(_ nt: JSValue, _ dflt: JSIntrinsic) throws(JSThrow) -> JSValue {
        guard nt.isObject else { return intrinsic(dflt) }
        let p = try getV(nt, heap.names.prototype)
        return p.isObject ? p : intrinsic(dflt)
    }

    /// For natives: the prototype for `new` (args.newTarget), or the
    /// intrinsic for a plain call.
    public func prototype(forNewTarget nt: JSValue, default dflt: JSIntrinsic) throws(JSThrow) -> JSValue {
        try prototypeFromConstructor(nt, dflt)
    }

    // MARK: Operators

    func addSlow(_ a: JSValue, _ b: JSValue) throws(JSThrow) -> JSValue {
        let depth = heap.rootDepth
        defer { heap.popRoots(to: depth) }
        let pa = try toPrimitive(a)
        _ = heap.root(pa)
        let pb = try toPrimitive(b)
        _ = heap.root(pb)
        if pa.isString || pb.isString {
            let sa = try toStringValue(pa)
            _ = heap.root(sa)
            let sb = try toStringValue(pb)
            guard let r = heap.concat(sa, sb) else { throw throwRangeError("Invalid string length") }
            return r
        }
        return .number(try toNumber(pa) + toNumber(pb))
    }

    func compareOp(_ op: JSOp, _ a: JSValue, _ b: JSValue) throws(JSThrow) -> Bool {
        let depth = heap.rootDepth
        defer { heap.popRoots(to: depth) }
        let pa = try toPrimitive(a, hint: .number)
        _ = heap.root(pa)
        let pb = try toPrimitive(b, hint: .number)
        if pa.isString && pb.isString {
            let c = heap.compareStrings(pa, pb)
            switch op {
            case .lt: return c < 0
            case .gt: return c > 0
            case .le: return c <= 0
            default: return c >= 0
            }
        }
        let x = try toNumber(pa), y = try toNumber(pb)
        switch op {
        case .lt: return x < y
        case .gt: return x > y
        case .le: return x <= y
        default: return x >= y
        }
    }

    public func looseEquals(_ a: JSValue, _ b: JSValue) throws(JSThrow) -> Bool {
        var x = a, y = b
        var steps = 0
        while steps < 8 {
            steps += 1
            if x.isNumber && y.isNumber { return x.numberValue == y.numberValue }
            if x.type == y.type { return heap.strictEquals(x, y) }
            if x.isNullish && y.isNullish { return true }
            if x.isNullish || y.isNullish { return false }
            if x.isNumber && y.isString { return x.numberValue == heap.stringToNumber(y) }
            if x.isString && y.isNumber { return heap.stringToNumber(x) == y.numberValue }
            if x.isBool { x = .number(x.boolValue ? 1 : 0); continue }
            if y.isBool { y = .number(y.boolValue ? 1 : 0); continue }
            if x.isObject && !y.isObject {
                let r = heap.root(y)
                x = try toPrimitive(x)
                heap.popRoots(to: r.slot)
                continue
            }
            if y.isObject && !x.isObject {
                let r = heap.root(x)
                y = try toPrimitive(y)
                heap.popRoots(to: r.slot)
                continue
            }
            return false
        }
        return false
    }

    public func instanceOf(_ v: JSValue, _ target: JSValue) throws(JSThrow) -> Bool {
        guard target.isObject else { throw throwTypeError("Right-hand side of 'instanceof' is not an object") }
        let h = try getV(target, .symbol(heap.symbolsWellKnown.hasInstance.handle))
        if !h.isNullish && h != intrinsic(.functionPrototype) {
            guard heap.isCallable(h) else { throw throwTypeError("Symbol.hasInstance is not a function") }
            if h != intrinsic(.throwTypeError) {
                return heap.toBoolean(try call(h, this: target, args: [v]))
            }
        }
        guard heap.isCallable(target) else { throw throwTypeError("Right-hand side of 'instanceof' is not callable") }
        return try ordinaryHasInstance(target, v)
    }

    func ordinaryHasInstance(_ c: JSValue, _ v: JSValue) throws(JSThrow) -> Bool {
        var cc = c
        var steps = 0
        while heap.kind(cc) == .boundFunction && steps < 10_000 { cc = heap.slot(cc, 0); steps += 1 }
        guard v.isObject else { return false }
        let p = try getV(cc, heap.names.prototype)
        guard p.isObject else { throw throwTypeError("Function has non-object prototype in instanceof check") }
        var o = heap.getPrototypeOf(v)
        steps = 0
        while o.isObject && steps < JSHeap.maxProtoChain {
            if o == p { return true }
            o = heap.getPrototypeOf(o)
            steps += 1
        }
        return false
    }

    // MARK: Environments

    func newEnvironment(parent: JSValue, info: JSValue) -> JSValue {
        var flags: JSObjectFlags = [.extensible]
        if heap.internalInt(info) & 1 != 0 { flags.insert(.user1) }
        let e = heap.newObject(proto: .null, kind: .environment, flags: flags)
        var slots: [JSValue] = [parent, info]
        let n = heap.slotCount(info)
        slots.reserveCapacity(n + 2)
        for i in 0..<n { slots.append(heap.slot(info, i)) }
        heap.setSlots(e, slots)
        return e
    }

    func cloneEnvironment(_ e: JSValue) -> JSValue {
        let c = heap.newObject(proto: .null, kind: .environment, flags: heap.flags(e))
        var slots: [JSValue] = []
        let n = heap.slotCount(e)
        for i in 0..<n { slots.append(heap.slot(e, i)) }
        heap.setSlots(c, slots)
        return c
    }

    func newWithEnvironment(parent: JSValue, object: JSValue) -> JSValue {
        let e = heap.newObject(proto: .null, kind: .environment, flags: [.user0])
        heap.setSlots(e, [parent, .undefined, object])
        return e
    }

    func lookupName(_ k: JSPropertyKey) throws(JSThrow) -> JSNameLoc {
        var e = env
        var steps = 0
        while e.isObject && steps < 100_000 {
            let fl = heap.flags(e)
            if fl.contains(.user0) {
                let o = heap.slot(e, 2)
                if heap.hasProperty(o, k) {
                    let u = try getV(o, .symbol(heap.symbolsWellKnown.unscopables.handle))
                    var blocked = false
                    if u.isObject { blocked = heap.toBoolean(try getV(u, k)) }
                    if !blocked { return .with(o) }
                }
            } else {
                let info = heap.slot(e, 1)
                if info.isObject, let p = heap.getOwnProperty(info, k), p.value.isInt32 {
                    let v = p.value.asInt32
                    return .slot(e, Int(v & JSScopeSlot.indexMask), v)
                }
                if fl.contains(.user1) && heap.hasOwnProperty(e, k) { return .prop(e) }
            }
            e = heap.slot(e, 0)
            steps += 1
        }
        if heap.hasOwnProperty(globalLex, k) { return .lex }
        if heap.hasProperty(global, k) { return .global }
        return .none
    }

    func notDefined(_ k: JSPropertyKey) -> JSThrow {
        throwReferenceError(keyDisplay(k) + " is not defined")
    }

    func tdz(_ k: JSPropertyKey) -> JSThrow {
        throwReferenceError("Cannot access '" + keyDisplay(k) + "' before initialization")
    }

    func getName(_ k: JSPropertyKey, orUndefined: Bool) throws(JSThrow) -> JSValue {
        switch try lookupName(k) {
        case .slot(let e, let i, _):
            let v = heap.slot(e, i)
            if v.isHole { throw tdz(k) }
            return v
        case .prop(let e): return try getV(e, k)
        case .with(let o): return try getV(o, k)
        case .lex, .global: return try getGlobal(k, orUndefined: orUndefined)
        case .none:
            if orUndefined { return .undefined }
            throw notDefined(k)
        }
    }

    func putName(_ k: JSPropertyKey, _ v: JSValue, strict: Bool) throws(JSThrow) {
        switch try lookupName(k) {
        case .slot(let e, let i, let fl):
            if fl & JSScopeSlot.lexicalFlag != 0 && heap.slot(e, i).isHole { throw tdz(k) }
            if fl & JSScopeSlot.constFlag != 0 { throw throwTypeError("Assignment to constant variable.") }
            heap.setSlot(e, i, v)
        case .prop(let e): try setV(e, k, v, strict: strict)
        case .with(let o): try setV(o, k, v, strict: strict)
        case .lex, .global: try putGlobal(k, v, strict: strict)
        case .none:
            if strict { throw notDefined(k) }
            try setV(global, k, v, strict: false)
        }
    }

    func getNameForCall(_ k: JSPropertyKey) throws(JSThrow) -> (JSValue, JSValue) {
        if case .with(let o) = try lookupName(k) { return (try getV(o, k), o) }
        return (try getName(k, orUndefined: false), .undefined)
    }

    func deleteName(_ k: JSPropertyKey) throws(JSThrow) -> Bool {
        switch try lookupName(k) {
        case .slot, .lex: return false
        case .prop(let e): return heap.deleteProperty(e, k)
        case .with(let o): return heap.deleteProperty(o, k)
        case .global: return heap.deleteProperty(global, k)
        case .none: return true
        }
    }

    // MARK: Globals

    func getGlobal(_ k: JSPropertyKey, orUndefined: Bool) throws(JSThrow) -> JSValue {
        if globalLexCount > 0, let p = heap.getOwnProperty(globalLex, k) {
            if p.value.isHole { throw tdz(k) }
            return p.value
        }
        switch heap.getProperty(global, k) {
        case .value(let v):
            if v.isUndefined && !orUndefined && !heap.hasProperty(global, k) { throw notDefined(k) }
            return v
        case .getter(let g):
            return try call(g, this: global, args: [])
        }
    }

    func putGlobal(_ k: JSPropertyKey, _ v: JSValue, strict: Bool) throws(JSThrow) {
        if globalLexCount > 0, let p = heap.getOwnProperty(globalLex, k) {
            if p.value.isHole { throw tdz(k) }
            if !p.writable { throw throwTypeError("Assignment to constant variable.") }
            _ = heap.setProperty(globalLex, k, v, receiver: globalLex)
            return
        }
        if strict && !heap.hasProperty(global, k) { throw notDefined(k) }
        try setV(global, k, v, strict: strict)
    }

    func varEnv() -> JSValue? {
        var e = env
        var steps = 0
        while e.isObject && steps < 100_000 {
            let fl = heap.flags(e)
            if !fl.contains(.user0) && fl.contains(.user1) { return e }
            e = heap.slot(e, 0)
            steps += 1
        }
        return nil
    }

    func alreadyDeclared(_ k: JSPropertyKey) -> JSThrow {
        throwSyntaxError("Identifier '" + keyDisplay(k) + "' has already been declared")
    }

    func declareVar(_ k: JSPropertyKey, isEval: Bool) throws(JSThrow) {
        if isEval, let e = varEnv() {
            let info = heap.slot(e, 1)
            if info.isObject && heap.hasOwnProperty(info, k) { return }
            if !heap.hasOwnProperty(e, k) {
                _ = heap.defineOwnProperty(e, k, .data(.undefined, [.writable, .enumerable, .configurable]))
            }
            return
        }
        if heap.hasOwnProperty(globalLex, k) { throw alreadyDeclared(k) }
        if !heap.hasOwnProperty(global, k) {
            let a: JSPropertyAttributes = isEval ? [.writable, .enumerable, .configurable] : [.writable, .enumerable]
            _ = heap.defineOwnProperty(global, k, .data(.undefined, a))
        }
    }

    func declareFunc(_ k: JSPropertyKey, _ v: JSValue, isEval: Bool) throws(JSThrow) {
        if isEval, let e = varEnv() {
            let info = heap.slot(e, 1)
            if info.isObject, let p = heap.getOwnProperty(info, k), p.value.isInt32 {
                heap.setSlot(e, Int(p.value.asInt32 & JSScopeSlot.indexMask), v)
                return
            }
            _ = heap.defineOwnProperty(e, k, .data(v, [.writable, .enumerable, .configurable]))
            return
        }
        if heap.hasOwnProperty(globalLex, k) { throw alreadyDeclared(k) }
        let existing = heap.getOwnProperty(global, k)
        if existing == nil || existing?.configurable == true {
            let a: JSPropertyAttributes = isEval ? [.writable, .enumerable, .configurable] : [.writable, .enumerable]
            if !heap.defineOwnProperty(global, k, .data(v, a)) { throw throwTypeError("Cannot define global function") }
        } else {
            try setV(global, k, v, strict: false)
        }
    }

    func declareLex(_ k: JSPropertyKey, isConst: Bool) throws(JSThrow) {
        if heap.hasOwnProperty(globalLex, k) { throw alreadyDeclared(k) }
        if let p = heap.getOwnProperty(global, k), !p.configurable { throw alreadyDeclared(k) }
        _ = heap.defineOwnProperty(globalLex, k, .data(.hole, isConst ? [.writable, .enumerable] : [.writable]))
        globalLexCount += 1
    }

    func initLex(_ k: JSPropertyKey, _ v: JSValue) {
        let isConst = heap.getOwnProperty(globalLex, k)?.enumerable ?? false
        _ = heap.defineOwnProperty(globalLex, k, .data(v, isConst ? [.enumerable] : [.writable]))
    }

    // MARK: Iteration

    func forInIterator(_ v: JSValue) throws(JSThrow) -> JSValue {
        if v.isNullish {
            let it = heap.newObject(proto: .null, kind: .internalObject)
            heap.setSlots(it, [.undefined])
            heap.setInternalInt(it, 1)
            return it
        }
        let o = try toObject(v)
        let r = heap.root(o)
        defer { heap.popRoots(to: r.slot) }
        var keys: [JSValue] = [o]
        var seen = Set<UInt64>()
        var cur = o
        var steps = 0
        while cur.isObject && steps < JSHeap.maxProtoChain {
            for k in heap.ownKeys(cur) where !k.isSymbol {
                if seen.insert(k.bits).inserted, let p = heap.getOwnProperty(cur, k), p.enumerable {
                    keys.append(k.isIndex ? .number(Int(k.index)) : .string(k.handle))
                }
            }
            cur = heap.getPrototypeOf(cur)
            steps += 1
        }
        let it = heap.newObject(proto: .null, kind: .internalObject)
        heap.setSlots(it, keys)
        heap.setInternalInt(it, 1)
        return it
    }

    /// The next key string, or undefined when done.
    func forInNextKey(_ it: JSValue) -> JSValue {
        var i = Int(heap.internalInt(it))
        let n = heap.slotCount(it)
        let o = heap.slot(it, 0)
        while i < n {
            let kv = heap.slot(it, i)
            i += 1
            let k: JSPropertyKey = kv.isString ? .atom(kv.handle) : .index(UInt32(truncatingIfNeeded: Int(kv.numberValue)))
            if heap.hasProperty(o, k) {
                heap.setInternalInt(it, Int64(i))
                return kv.isString ? kv : heap.numberToString(kv.numberValue)
            }
        }
        heap.setInternalInt(it, Int64(n))
        return .undefined
    }

    /// GetIterator: (iterator, next method); next is .hole for the VM's
    /// own array/string iteration (Array.prototype.values or
    /// String.prototype[@@iterator] not replaced).
    public func getIterator(_ v: JSValue) throws(JSThrow) -> (JSValue, JSValue) {
        let sym = JSPropertyKey.symbol(heap.symbolsWellKnown.iterator.handle)
        if v.isObject, case .value(let m) = heap.getProperty(v, sym), m == intrinsic(.arrayValues), m.isObject {
            let it = heap.newObject(proto: .null, kind: .iterator)
            heap.setSlots(it, [v])
            return (it, .hole)
        }
        if v.isString, case .value(let m) = heap.getProperty(intrinsic(.stringPrototype), sym),
           m == intrinsic(.stringIterator), m.isObject {
            let it = heap.newObject(proto: .null, kind: .iterator, flags: [.user3])
            heap.setSlots(it, [v])
            return (it, .hole)
        }
        let m = try getV(v, sym)
        guard heap.isCallable(m) else { throw throwTypeError(describeForError(v) + " is not iterable") }
        let it = try call(m, this: v, args: [])
        guard it.isObject else { throw throwTypeError("Result of the Symbol.iterator method is not an object") }
        let r = heap.root(it)
        defer { heap.popRoots(to: r.slot) }
        let next = try getV(it, heap.names.next)
        return (it, next)
    }

    /// (done, value).
    public func iteratorStep(_ it: JSValue, _ next: JSValue) throws(JSThrow) -> (Bool, JSValue) {
        if next.isHole {
            let src = heap.slot(it, 0)
            let i = Int(heap.internalInt(it))
            if heap.flags(it).contains(.user3) {
                let n = heap.stringLength(src)
                if i >= n { return (true, .undefined) }
                let cp = heap.codePoint(src, i)
                let len = cp > 0xFFFF ? 2 : 1
                heap.setInternalInt(it, Int64(i + len))
                if len == 1 { return (false, heap.singleUnitString(heap.charCode(src, i), protecting: it)) }
                return (false, heap.substring(src, i, i + len))
            }
            if src.isUndefined { return (true, .undefined) }
            let len = heap.kind(src) == .array ? Int(heap.arrayLength(src)) : try toLength(try getV(src, heap.names.length))
            if i >= len {
                heap.setSlot(it, 0, .undefined)
                return (true, .undefined)
            }
            heap.setInternalInt(it, Int64(i + 1))
            let k: JSPropertyKey = i < 0xFFFF_FFFF ? .index(UInt32(i)) : try toPropertyKey(.number(i))
            return (false, try getV(src, k))
        }
        guard heap.isCallable(next) else { throw throwTypeError("iterator.next is not a function") }
        let res = try call(next, this: it, args: [])
        guard res.isObject else { throw throwTypeError("Iterator result " + describeForError(res) + " is not an object") }
        let r = heap.root(res)
        defer { heap.popRoots(to: r.slot) }
        if heap.toBoolean(try getV(res, heap.names.done)) { return (true, .undefined) }
        return (false, try getV(res, heap.names.value))
    }

    public func iteratorClose(_ it: JSValue, _ next: JSValue) throws(JSThrow) {
        if next.isHole || next.isNull { return }
        let ret = try getV(it, heap.key("return"))
        if ret.isNullish { return }
        guard heap.isCallable(ret) else { throw throwTypeError("iterator.return is not a function") }
        let res = try call(ret, this: it, args: [])
        if !res.isObject { throw throwTypeError("Iterator result " + describeForError(res) + " is not an object") }
    }

    /// [arr iterable] -> [arr] (the iterable is on the stack, rooted).
    func appendSpread(_ arr: JSValue, _ v: JSValue) throws(JSThrow) {
        let (it, next) = try getIterator(v)
        try ensureStack(2)
        push(it)
        push(next)
        defer { sp -= 2 }
        while true {
            let (done, x) = try iteratorStep(stack[sp - 2], stack[sp - 1])
            if done { break }
            if !heap.createDataProperty(arr, .index(heap.arrayLength(arr)), x) {
                if heap.termination != nil { throw JSThrow() }
                throw throwRangeError("Invalid array length")
            }
        }
    }

    /// CopyDataProperties (object spread and rest).
    func copyDataProperties(into target: JSValue, from src: JSValue, excluding: JSValue) throws(JSThrow) {
        if src.isNullish { return }
        let s = try toObject(src)
        let r = heap.root(s)
        defer { heap.popRoots(to: r.slot) }
        var excluded = Set<UInt64>()
        if excluding.isObject {
            for i in 0..<heap.slotCount(excluding) {
                if let k = heap.propertyKey(heap.slot(excluding, i)) { excluded.insert(k.bits) }
            }
        }
        for k in heap.ownKeys(s) where !excluded.contains(k.bits) {
            guard let p = heap.getOwnProperty(s, k), p.enumerable else { continue }
            let v = try getV(s, k)
            _ = heap.createDataProperty(target, k, v)
        }
    }

    /// [f this arr] -> [f this a0 a1 ...]; returns the count.
    func spreadArgs() throws(JSThrow) -> Int {
        let arr = stack[sp - 1]
        let n = Int(heap.arrayLength(arr))
        if n > 1 << 16 { throw throwRangeError("Maximum call stack size exceeded") }
        try ensureStack(n + 16)
        sp -= 1
        for i in 0..<n {
            if case .value(let v) = heap.getProperty(arr, .index(UInt32(i))) { push(v) } else { push(.undefined) }
        }
        return n
    }

    // MARK: super(), eval, classes, templates

    /// [funcObj newTarget args] -> [superConstructor newTarget args].
    func prepareSuperCall(_ argc: Int) throws(JSThrow) {
        let fo = stack[sp - argc - 2]
        let sup = heap.getPrototypeOf(fo)
        guard sup.isObject && heap.flags(sup).contains(.constructor) else {
            throw throwTypeError("Super constructor " + describeForError(sup) + " of anonymous class is not a constructor")
        }
        if stack[sp - argc - 1].isUndefined { throw throwSyntaxError("'super' keyword unexpected here") }
        stack[sp - argc - 2] = sup
    }

    /// [f this newTarget args] -> a direct eval (frame pushed: true) or a
    /// plain call.
    func directEval(_ argc: Int, strict: Bool, inParams: Bool = false) throws(JSThrow) -> Bool {
        let fpos = sp - argc - 3
        let f = stack[fpos]
        if f == intrinsic(.eval) && f.isObject {
            if argc == 0 {
                sp = fpos
                push(.undefined)
                return false
            }
            let x = stack[fpos + 3]
            if !x.isString {
                sp = fpos
                push(x)
                return false
            }
            let thisV = stack[fpos + 1], nt = stack[fpos + 2]
            let src = Array(heap.swiftString(x).utf8)
            let depth = heap.rootDepth
            let closure = try compileScriptClosure(src, name: "eval", eval: true, strict: strict, env: env)
            stack[fpos] = closure
            stack[fpos + 1] = thisV
            sp = fpos + 2
            heap.popRoots(to: depth)
            if inParams && !strict, let c = codeFor(function: closure), c.declaresArguments {
                throw throwSyntaxError("eval in a parameter list cannot declare 'arguments'")
            }
            let home = frames.isEmpty ? JSValue.undefined : frames[frames.count - 1].home
            try enterFunction(closure, argc: 0, mode: JSFrameMode.normal, newTarget: nt, this: thisV)
            frames[frames.count - 1].home = home
            return true
        }
        // Not the intrinsic: an ordinary call (drop newTarget, this undefined).
        var i = fpos + 2
        while i < sp - 1 { stack[i] = stack[i + 1]; i += 1 }
        stack[fpos + 1] = .undefined
        sp -= 1
        return try dispatchCall(argc, mode: JSFrameMode.normal)
    }

    /// [heritage?] -> [constructor prototype].
    func newClass(_ co: JSValue, hasHeritage: Bool) throws(JSThrow) {
        guard let c = code(ofCodeObject: co) else { throw throwTypeError("bad class") }
        var protoParent = objectPrototype
        var ctorParent = functionPrototype
        if hasHeritage {
            let h = stack[sp - 1]
            if h.isNull {
                protoParent = .null
            } else {
                guard h.isObject && heap.flags(h).contains(.constructor) else {
                    throw throwTypeError("Class extends value " + describeForError(h) + " is not a constructor or null")
                }
                let pp = try getV(h, heap.names.prototype)
                guard pp.isObject || pp.isNull else {
                    throw throwTypeError("Class extends value does not have valid prototype property")
                }
                protoParent = pp
                ctorParent = h
            }
        }
        try ensureStack(4)
        push(protoParent)
        let proto = heap.newObject(proto: protoParent)
        stack[sp - 1] = proto
        let f = makeClosure(c, env: env, home: proto)
        if !heap.setPrototypeOf(f, ctorParent) { throw throwTypeError("bad class heritage") }
        _ = heap.defineOwnProperty(f, heap.names.prototype, .data(proto, []))
        _ = heap.defineOwnProperty(proto, heap.names.constructor, .data(f, [.writable, .configurable]))
        if hasHeritage {
            stack[sp - 2] = f
        } else {
            stack[sp - 1] = f
            push(proto)
        }
    }

    func templateObject(_ code: JSCode, _ i: Int) throws(JSThrow) -> JSValue {
        let d = code.constants[i]
        if heap.kind(d) == .array { return d }
        let n = heap.slotCount(d) / 2
        let depth = heap.rootDepth
        defer { heap.popRoots(to: depth) }
        var cooked: [JSValue] = [], raw: [JSValue] = []
        for j in 0..<n { cooked.append(heap.slot(d, 2 * j)); raw.append(heap.slot(d, 2 * j + 1)) }
        let ra = heap.newArray(proto: arrayPrototype, elements: raw)
        _ = heap.root(ra)
        let ca = heap.newArray(proto: arrayPrototype, elements: cooked)
        _ = heap.root(ca)
        for a in [ra, ca] {
            for j in 0..<n { _ = heap.defineOwnProperty(a, .index(UInt32(j)), JSPropertyDescriptor(writable: false, configurable: false)) }
        }
        _ = heap.defineOwnProperty(ca, heap.names.raw, .data(ra, []))
        for a in [ra, ca] {
            _ = heap.defineOwnProperty(a, heap.names.length, JSPropertyDescriptor(writable: false))
            heap.preventExtensions(a)
        }
        setConstant(code, i, ca)
        return ca
    }
}

// MARK: Numbers

/// Number::exponentiate without libm (exact for small integer powers).
public func jsPowNumber(_ x: Double, _ y: Double) -> Double {
    if y.isNaN { return .nan }
    if y == 0 { return 1 }
    if x.isNaN { return .nan }
    let ax = x.magnitude
    if y.isInfinite {
        if ax == 1 { return .nan }
        return (ax > 1) == (y > 0) ? .infinity : 0
    }
    if x.isInfinite {
        let oddInt = jsIsOddInteger(y)
        if x > 0 { return y > 0 ? .infinity : 0 }
        if y > 0 { return oddInt ? -.infinity : .infinity }
        return oddInt ? -0.0 : 0
    }
    if x == 0 {
        let oddInt = jsIsOddInteger(y)
        if x.sign == .plus { return y > 0 ? 0 : .infinity }
        if y > 0 { return oddInt ? -0.0 : 0 }
        return oddInt ? -.infinity : .infinity
    }
    let isInt = jsTrunc(y) == y
    if x < 0 && !isInt { return .nan }
    if isInt && y.magnitude <= 1073741824.0 {
        var n = UInt64(y.magnitude)
        var b = ax, r = 1.0
        while n > 0 {
            if n & 1 != 0 { r *= b }
            b *= b
            n >>= 1
        }
        if y < 0 { r = 1 / r }
        return x < 0 && jsIsOddInteger(y) ? -r : r
    }
    let r = jsExpNumber(y * jsLogNumber(ax))
    return x < 0 && jsIsOddInteger(y) ? -r : r
}

func jsIsOddInteger(_ y: Double) -> Bool {
    guard jsTrunc(y) == y && y.magnitude < 9007199254740992 else { return false }
    return Int64(y) & 1 != 0
}

/// Natural log for finite x > 0 (atanh series after a mantissa split).
func jsLogNumber(_ xIn: Double) -> Double {
    var x = xIn
    var e = 0
    if x < 2.2250738585072014e-308 { x *= 4503599627370496.0; e = -52 }
    let bits = x.bitPattern
    e += Int((bits >> 52) & 0x7FF) - 1023
    var m = Double(bitPattern: (bits & 0x000F_FFFF_FFFF_FFFF) | 0x3FF0_0000_0000_0000)
    if m > 1.4142135623730951 { m /= 2; e += 1 }
    let s = (m - 1) / (m + 1), s2 = s * s
    var term = s, sum = 0.0
    var k = 1.0
    for _ in 0..<40 {
        sum += term / k
        term *= s2
        k += 2
        if term.magnitude < 1e-20 { break }
    }
    return 2 * sum + Double(e) * 0.6931471805599453
}

/// e^x (range reduction by ln 2, Taylor series).
func jsExpNumber(_ x: Double) -> Double {
    if x.isNaN { return .nan }
    if x > 709.8 { return .infinity }
    if x < -745.2 { return 0 }
    let ln2 = 0.6931471805599453
    let k = (x / ln2).rounded()
    let r = x - k * ln2
    var term = 1.0, sum = 1.0
    for i in 1..<30 {
        term *= r / Double(i)
        sum += term
        if term.magnitude < 1e-18 { break }
    }
    var ki = Int(k)
    var result = sum
    while ki > 1000 { result *= 8.98846567431158e307; ki -= 1023 }
    while ki < -1000 { result *= 2.2250738585072014e-308; ki += 1022 }
    return result * Double(sign: .plus, exponent: ki, significand: 1.0)
}
