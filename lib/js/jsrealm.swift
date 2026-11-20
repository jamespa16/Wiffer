// JSRealm: one global environment with its own heap, VM state, intrinsics
// and native-function table (ROADMAP Phase 9B, embedding API first cut).
//
// ============================================================ embedding
//
//     let rt = JSRuntime(limits: JSLimits())        // engine-wide settings
//     rt.interruptHandler = { realm in elapsed > 5s } // true = terminate
//     let realm = rt.makeRealm()                    // fresh globals
//     switch realm.evaluate(source: bytes, name: "page.js") {
//     case .normal(let v):        ...   // v: valid until the next allocation
//     case .exception(let e):     ...   // e.message, e.stack (strings), e.value
//     case .terminated(let why):  ...   // heap cap or interrupt; realm reusable
//     }
//
// Values handed to Swift are raw handles: root them (heap.root /
// heap.retain, see jsheap.swift) before anything else allocates.
//
// ===================================================== native functions
//
// A native function is a Swift closure with this exact shape (write the
// signature out in full, `-> JSValue` included: Embedded Swift needs the
// typed throw spelled out):
//
//     { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in ... }
//
//   args.this, args.count, args[i] (undefined past the end), args.callee,
//   args.newTarget (undefined for a call; the constructor for `new`),
//   args.isConstruct. Argument values live on the VM stack, so they stay
//   rooted for the whole call; anything the native allocates and keeps in
//   a Swift local across another allocation must be rooted
//   (heap.withRootScope { heap.root(v) ... }).
//
//   To throw: `throw realm.throwTypeError("msg")` (also throwRangeError,
//   throwError(kind, msg), throwValue(v)). Every realm helper that can run
//   JS (get, set, call, toString, toNumber, ...) `throws(JSThrow)`:
//   propagate it with `try`. A JSThrow may also be a termination (heap cap
//   or interrupt); never swallow it in a loop: check
//   `realm.isTerminating` after catching one.
//
// Registration (for the built-in agents: 9C core built-ins, RegExp, Date,
// 9E/9F):
//
//   let idx = realm.registerNative("push", length: 1) { (realm, args) throws(JSThrow) -> JSValue in ... }
//   let f = realm.newNativeFunction(idx)                      // a function object
//   realm.defineMethod(obj, "push", length: 1) { ... }        // register + define, non-enumerable
//   realm.defineGetter(obj, "size") { ... }                   // accessor property
//   realm.defineConstructor("Map", length: 0, prototype: p) { ... }
//        // a global constructor: F.prototype = p (fixed), p.constructor = F
//   realm.defineValue(obj, "PI", .double(3.14159), [])        // data property
//   realm.defineGlobal("Math", mathObject)
//   realm.intrinsic(.arrayPrototype) / realm.setIntrinsic(.mapPrototype, p)
//
// Install functions: each built-in file provides
//     func jsInstallXxx(_ realm: JSRealm)
// and adds one line to JSRealm.installBuiltins() below (the only shared
// edit). Add intrinsic slots by adding cases to JSIntrinsic (before
// `count`); they are GC roots automatically.
//
// Hooks: realm.regExpCreate (the RegExp agent sets it: regex literals call
// it with pattern and flags strings), realm.printHandler (print()),
// realm.hostFinalizer (host objects with .hasFinalizer).

public struct JSThrow: Error {
    public init() {}
}

public typealias JSNativeFunction = (_ realm: JSRealm, _ args: JSArgs) throws(JSThrow) -> JSValue

/// Regex literal hook: (realm, pattern string, flags string) -> RegExp object.
public typealias JSRegExpCreate = (_ realm: JSRealm, _ pattern: JSValue, _ flags: JSValue) throws(JSThrow) -> JSValue

/// A native call's arguments (they live on the VM stack).
public struct JSArgs {
    unowned(unsafe) let realm: JSRealm
    let base: Int
    public let count: Int
    public let this: JSValue
    public let callee: JSValue
    public let newTarget: JSValue

    public subscript(_ i: Int) -> JSValue {
        i >= 0 && i < count ? realm.stack[base + i] : .undefined
    }
    public var isConstruct: Bool { !newTarget.isUndefined }
    /// The arguments as an array (copies; fine for short lists).
    public var values: [JSValue] {
        var out: [JSValue] = []
        out.reserveCapacity(count)
        for i in 0..<count { out.append(realm.stack[base + i]) }
        return out
    }
}

struct JSNativeEntry {
    var fn: JSNativeFunction
    var name: String
    var length: Int
}

/// Intrinsic objects. Add new cases before `count`.
public enum JSIntrinsic: Int {
    case objectPrototype, functionPrototype, arrayPrototype, stringPrototype, numberPrototype
    case booleanPrototype, symbolPrototype, bigintPrototype
    case errorPrototype, typeErrorPrototype, rangeErrorPrototype, referenceErrorPrototype
    case syntaxErrorPrototype, evalErrorPrototype, uriErrorPrototype, aggregateErrorPrototype
    case iteratorPrototype, arrayIteratorPrototype, stringIteratorPrototype
    case regExpPrototype, datePrototype
    case objectConstructor, functionConstructor, arrayConstructor, stringConstructor
    case numberConstructor, booleanConstructor, symbolConstructor, errorConstructor
    case typeErrorConstructor, rangeErrorConstructor, referenceErrorConstructor
    case syntaxErrorConstructor, evalErrorConstructor, uriErrorConstructor, aggregateErrorConstructor
    case regExpConstructor, dateConstructor
    case eval, arrayValues, stringIterator, throwTypeError
    // Phase 9E (jspromise.swift, jsgenerator.swift).
    case promisePrototype, promiseConstructor, generatorPrototype, asyncGeneratorPrototype
    case generatorFunctionPrototype, asyncFunctionPrototype, asyncGeneratorFunctionPrototype
    case asyncIteratorPrototype, asyncFromSyncIteratorPrototype
    case symbolRegistry, regExpExecFn, regExpStringIteratorPrototype
    case arrayJoinStack, mathObject
    case count
}

/// One VM call frame (see jsbytecode.swift for the stack layout).
struct JSFrame {
    unowned(unsafe) var code: JSCode
    /// Saved pc (the return address) while a callee runs.
    var pc: Int
    var base: Int
    var callee: JSValue
    var this: JSValue
    var newTarget: JSValue
    var home: JSValue
    var callerEnv: JSValue
    var mode: UInt8
    var entry: Bool
    /// The generator / async state object of a suspendable frame
    /// (jsgenerator.swift), else undefined.
    var gen: JSValue = .undefined
}

enum JSFrameMode {
    static let normal: UInt8 = 0
    /// A [[Construct]]: a non-object result becomes `this`.
    static let construct: UInt8 = 1
    /// A setter call: the result is dropped (the assigned value is below).
    static let discard: UInt8 = 2
    /// A getter run for a method call (`o.m()`): [o] -> [result o].
    static let getterForCall: UInt8 = 3
}

/// An uncaught exception.
public struct JSUncaughtException {
    /// The thrown value (unrooted: root it before allocating).
    public let value: JSValue
    /// ToString of the value ("TypeError: x is not a function").
    public let message: String
    /// The message plus "    at ..." lines.
    public let stack: String
}

public enum JSCompletion {
    case normal(JSValue)
    case exception(JSUncaughtException)
    case terminated(JSTerminationReason)
}

struct JSTraceEntry {
    var name: String
    var location: String
}

public final class JSRealm {
    public let runtime: JSRuntime
    public let heap: JSHeap
    public var limits: JSLimits { heap.limits }

    // VM state (jsvm.swift).
    var stack: UnsafeMutablePointer<JSValue>
    var stackCap: Int
    var sp = 0
    var frames: [JSFrame] = []
    var env: JSValue = .undefined
    var exception: JSValue = .undefined
    var nativeDepth = 0
    var budget = 0
    var stackFloor: UInt = 0
    var curPC = 0
    var trace: [JSTraceEntry] = []

    var intrinsics: [JSValue]
    public private(set) var global: JSValue = .undefined
    var globalLex: JSValue = .undefined
    var globalLexCount = 0
    var natives: [JSNativeEntry] = []
    var codes: [JSCode?] = []
    var freeCodes: [Int] = []
    var scriptCount = 0
    var callNativeIndex = -1
    var applyNativeIndex = -1
    /// Phase 9E state: the job queue, promise hooks, generator natives,
    /// modules (jspromise.swift, jsgenerator.swift, jsmodule.swift).
    let es = JSESState()

    /// print(): nil collects lines in `output`.
    public var printHandler: ((String) -> Void)? = nil
    public var output: [String] = []
    public var regExpCreate: JSRegExpCreate? = nil
    /// Date.now() / new Date(): milliseconds since the epoch (nil: 0, so host tests are deterministic).
    public var nowMs: (() -> Double)? = nil
    /// The local time zone for Date (UTC by default).
    public var dateZone: JSDateZone = .utc
    /// State of the String/RegExp/Symbol/Date built-ins (jsbuiltins_regexp.swift).
    let b2 = JSBuiltins2State()
    /// Finalizer for host objects (embedder; called during GC sweep, must
    /// not touch the heap).
    public var hostFinalizer: ((JSHandle, Int64) -> Void)? = nil

    init(runtime: JSRuntime) {
        self.runtime = runtime
        heap = JSHeap(limits: runtime.limits)
        stackCap = 4096
        stack = UnsafeMutablePointer<JSValue>.allocate(capacity: stackCap)
        stack.initialize(repeating: .undefined, count: stackCap)
        intrinsics = [JSValue](repeating: .undefined, count: JSIntrinsic.count.rawValue)
        budget = max(1, runtime.limits.interruptInterval)
        _ = heap.addRootProvider { [unowned(unsafe) self] h in self.markRoots(h) }
        heap.finalizer = { [unowned(unsafe) self] h, ii in self.finalize(h, ii) }
        setUpGlobals()
        installBuiltins()
    }

    deinit {
        stack.deinitialize(count: stackCap)
        stack.deallocate()
    }

    /// The built-in installers, in order. Later phases add one line each.
    func installBuiltins() {
        jsInstallBaseBuiltins(self)
        jsInstallBuiltins1(self)
        jsInstallString(self)
        jsInstallRegExp(self)
        jsInstallSymbol(self)
        jsInstallDate(self)
        jsInstallPromise(self)
        jsInstallGenerators(self)
    }

    func markRoots(_ h: JSHeap) {
        var i = 0
        while i < sp { h.markValue(stack[i]); i += 1 }
        for f in frames {
            h.markValue(f.callee); h.markValue(f.this); h.markValue(f.newTarget)
            h.markValue(f.home); h.markValue(f.callerEnv); h.markValue(f.gen)
        }
        es.mark(h)
        h.markValue(env)
        h.markValue(exception)
        h.markValue(global)
        h.markValue(globalLex)
        for v in intrinsics { h.markValue(v) }
    }

    func finalize(_ h: JSHandle, _ ii: Int64) {
        let o = JSValue.object(h)
        if heap.kind(o) == .internalObject && heap.flags(o).contains(.user0) {
            let id = Int(ii)
            if id >= 0 && id < codes.count && codes[id] != nil {
                codes[id] = nil
                freeCodes.append(id)
            }
            return
        }
        if heap.kind(o) == .regexp { b2.releaseRegExp(Int(ii)); return }
        hostFinalizer?(h, ii)
    }

    private func setUpGlobals() {
        let op = heap.newObject(proto: .null)
        intrinsics[JSIntrinsic.objectPrototype.rawValue] = op
        let fp = heap.newObject(proto: op, kind: .nativeFunction, flags: [.extensible, .callable])
        intrinsics[JSIntrinsic.functionPrototype.rawValue] = fp
        global = heap.newObject(proto: op)
        globalLex = heap.newObject(proto: .null)
    }

    // MARK: Intrinsics

    public func intrinsic(_ i: JSIntrinsic) -> JSValue { intrinsics[i.rawValue] }
    public func setIntrinsic(_ i: JSIntrinsic, _ v: JSValue) { intrinsics[i.rawValue] = v }
    public var objectPrototype: JSValue { intrinsics[JSIntrinsic.objectPrototype.rawValue] }
    public var functionPrototype: JSValue { intrinsics[JSIntrinsic.functionPrototype.rawValue] }
    public var arrayPrototype: JSValue { intrinsics[JSIntrinsic.arrayPrototype.rawValue] }

    // MARK: Native registration

    /// Add a native to the table; returns its index.
    public func registerNative(_ name: String, length: Int, _ fn: @escaping JSNativeFunction) -> Int {
        natives.append(JSNativeEntry(fn: fn, name: name, length: length))
        return natives.count - 1
    }

    /// A function object for native `index`. `constructor`: `new` is
    /// allowed (the native sees args.newTarget).
    public func newNativeFunction(_ index: Int, constructor: Bool = false, name: String? = nil) -> JSValue {
        guard index >= 0 && index < natives.count else { return .undefined }
        var flags: JSObjectFlags = [.extensible, .callable]
        if constructor { flags.insert(.constructor) }
        let f = heap.newObject(proto: functionPrototype, kind: .nativeFunction, flags: flags)
        heap.setInternalInt(f, Int64(index))
        let r = heap.root(f)
        let e = natives[index]
        _ = heap.defineOwnProperty(f, heap.names.length, .data(.number(e.length), [.configurable]))
        let nm = heap.newString(name ?? e.name)
        _ = heap.defineOwnProperty(f, heap.names.name, .data(nm, [.configurable]))
        heap.popRoots(to: r.slot)
        return f
    }

    /// Define a method (writable, configurable, not enumerable). `name` may
    /// be "@@iterator" style for a well-known symbol: pass `key:` instead.
    @discardableResult
    public func defineMethod(_ obj: JSValue, _ name: String, length: Int, key: JSPropertyKey? = nil,
                             _ fn: @escaping JSNativeFunction) -> JSValue {
        let idx = registerNative(name, length: length, fn)
        let r = heap.root(obj)
        let f = newNativeFunction(idx)
        _ = heap.root(f)
        _ = heap.defineOwnProperty(obj, key ?? heap.key(name), .data(f, [.writable, .configurable]))
        heap.popRoots(to: r.slot)
        return f
    }

    /// Define an accessor with a native getter (and optional setter).
    public func defineGetter(_ obj: JSValue, _ name: String, key: JSPropertyKey? = nil,
                             setter: JSNativeFunction? = nil, _ getter: @escaping JSNativeFunction) {
        let r = heap.root(obj)
        let g = newNativeFunction(registerNative("get " + name, length: 0, getter))
        _ = heap.root(g)
        var s: JSValue = .undefined
        if let st = setter {
            s = newNativeFunction(registerNative("set " + name, length: 1, st))
            _ = heap.root(s)
        }
        _ = heap.defineOwnProperty(obj, key ?? heap.key(name), .accessor(get: g, set: s, [.configurable]))
        heap.popRoots(to: r.slot)
    }

    /// A global constructor function with a fixed `prototype`.
    @discardableResult
    public func defineConstructor(_ name: String, length: Int, prototype: JSValue,
                                  _ fn: @escaping JSNativeFunction) -> JSValue {
        let r = heap.root(prototype)
        let f = newNativeFunction(registerNative(name, length: length, fn), constructor: true)
        _ = heap.root(f)
        if prototype.isObject {
            _ = heap.defineOwnProperty(f, heap.names.prototype, .data(prototype, []))
            _ = heap.defineOwnProperty(prototype, heap.names.constructor, .data(f, [.writable, .configurable]))
        }
        defineGlobal(name, f)
        heap.popRoots(to: r.slot)
        return f
    }

    public func defineValue(_ obj: JSValue, _ name: String, _ v: JSValue,
                            _ attrs: JSPropertyAttributes = [.writable, .configurable]) {
        let r = heap.root(obj)
        _ = heap.root(v)
        _ = heap.defineOwnProperty(obj, heap.key(name), .data(v, attrs))
        heap.popRoots(to: r.slot)
    }

    /// A global binding (writable, configurable, not enumerable).
    public func defineGlobal(_ name: String, _ v: JSValue) {
        defineValue(global, name, v, [.writable, .configurable])
    }

    /// A string value.
    public func string(_ s: String) -> JSValue { heap.newString(s) }

    // MARK: Code objects

    /// Wrap a compiled JSCode in its heap code object (constants as slots).
    func makeCodeObject(_ code: JSCode) -> JSValue {
        var slots = code.constants
        for k in code.keys where k.isString || k.isSymbol { slots.append(heap.keyValue(k)) }
        slots.append(code.name)
        let depth = heap.rootDepth
        for s in slots { _ = heap.root(s) }
        let o = heap.newObject(proto: .null, kind: .internalObject, flags: [.user0, .hasFinalizer])
        heap.popRoots(to: depth)
        heap.setSlots(o, slots)
        let id: Int
        if let f = freeCodes.popLast() { id = f; codes[f] = code } else { id = codes.count; codes.append(code) }
        code.id = id
        heap.setInternalInt(o, Int64(id))
        return o
    }

    @inline(__always) func codeFor(function f: JSValue) -> JSCode? {
        let id = Int(heap.internalInt(f))
        guard id >= 0 && id < codes.count else { return nil }
        return codes[id]
    }

    func code(ofCodeObject o: JSValue) -> JSCode? {
        guard heap.kind(o) == .internalObject && heap.flags(o).contains(.user0) else { return nil }
        let id = Int(heap.internalInt(o))
        guard id >= 0 && id < codes.count else { return nil }
        return codes[id]
    }

    /// Update a constant (template objects are made on first use).
    func setConstant(_ code: JSCode, _ i: Int, _ v: JSValue) {
        guard i >= 0 && i < code.constants.count else { return }
        code.setConstant(i, v)
        heap.setSlot(code.codeObject, i, v)
    }

    /// A closure over `env` for compiled code.
    func makeClosure(_ code: JSCode, env: JSValue, home: JSValue = .undefined) -> JSValue {
        if code.genKind != 0 { return makeGeneratorClosure(code, env: env, home: home) }
        var flags: JSObjectFlags = [.extensible, .callable]
        if code.isConstructor { flags.insert(.constructor) }
        if code.kind == .classConstructor || code.kind == .derivedConstructor { flags.insert(.classConstructor) }
        if code.strict { flags.insert(.strict) }
        let depth = heap.rootDepth
        _ = heap.root(env)
        _ = heap.root(home)
        let f = heap.newObject(proto: functionPrototype, kind: .function, flags: flags)
        _ = heap.root(f)
        heap.setSlots(f, [code.codeObject, env, home, .undefined])
        heap.setInternalInt(f, Int64(code.id))
        _ = heap.defineOwnProperty(f, heap.names.length, .data(.number(code.length), [.configurable]))
        _ = heap.defineOwnProperty(f, heap.names.name, .data(code.name, [.configurable]))
        if code.hasPrototype {
            let p = heap.newObject(proto: objectPrototype)
            _ = heap.defineOwnProperty(p, heap.names.constructor, .data(f, [.writable, .configurable]))
            _ = heap.defineOwnProperty(f, heap.names.prototype, .data(p, [.writable]))
        }
        heap.popRoots(to: depth)
        return f
    }

    // MARK: Errors

    /// A new error object of a kind with a message (and a stack string).
    public func makeError(_ kind: JSErrorKind, _ message: String) -> JSValue {
        let depth = heap.rootDepth
        let m = heap.newString(message)
        _ = heap.root(m)
        let e = makeErrorObject(kind, message: m, proto: .undefined)
        heap.popRoots(to: depth)
        return e
    }

    func errorPrototype(_ kind: JSErrorKind) -> JSValue {
        switch kind {
        case .error: return intrinsic(.errorPrototype)
        case .typeError: return intrinsic(.typeErrorPrototype)
        case .rangeError: return intrinsic(.rangeErrorPrototype)
        case .referenceError: return intrinsic(.referenceErrorPrototype)
        case .syntaxError: return intrinsic(.syntaxErrorPrototype)
        case .evalError: return intrinsic(.evalErrorPrototype)
        case .uriError: return intrinsic(.uriErrorPrototype)
        case .aggregateError: return intrinsic(.aggregateErrorPrototype)
        }
    }

    /// message: a string or undefined; proto: undefined for the intrinsic.
    func makeErrorObject(_ kind: JSErrorKind, message: JSValue, proto: JSValue) -> JSValue {
        let depth = heap.rootDepth
        _ = heap.root(message)
        let p = proto.isObject ? proto : errorPrototype(kind)
        let e = heap.newObject(proto: p, kind: .error)
        _ = heap.root(e)
        if message.isString {
            _ = heap.defineOwnProperty(e, heap.names.message, .data(message, [.writable, .configurable]))
        }
        let st = heap.newString(errorStack(e, kind: kind, message: message))
        _ = heap.defineOwnProperty(e, heap.names.stack, .data(st, [.writable, .configurable]))
        heap.popRoots(to: depth)
        return e
    }

    func errorStack(_ e: JSValue, kind: JSErrorKind, message: JSValue) -> String {
        var name = jsErrorKindName(kind)
        if case .value(let n) = heap.getProperty(e, heap.names.name), n.isString { name = heap.swiftString(n) }
        var s = name
        if message.isString && heap.stringLength(message) > 0 { s += ": " + heap.swiftString(message) }
        s += currentStackTrace()
        return s
    }

    /// "\n    at f (file:line:col)" lines for the live frames.
    func currentStackTrace(limit: Int = 32) -> String {
        var s = ""
        var i = frames.count - 1
        var n = 0
        while i >= 0 && n < limit {
            let f = frames[i]
            let pc = i == frames.count - 1 ? curPC : max(0, f.pc - 1)
            s += "\n    at " + frameDescription(f.code, pc)
            i -= 1
            n += 1
        }
        return s
    }

    func frameDescription(_ code: JSCode, _ pc: Int) -> String {
        let loc = code.location(at: pc)
        if code.kind == .script || code.kind == .eval { return loc }
        let nm = heap.swiftString(code.name)
        return (nm.isEmpty ? "<anonymous>" : nm) + " (" + loc + ")"
    }

    /// Set the pending exception and return the JSThrow to throw.
    public func throwValue(_ v: JSValue) -> JSThrow {
        exception = v
        return JSThrow()
    }

    public func throwError(_ kind: JSErrorKind, _ message: String) -> JSThrow {
        throwValue(makeError(kind, message))
    }
    public func throwTypeError(_ message: String) -> JSThrow { throwError(.typeError, message) }
    public func throwRangeError(_ message: String) -> JSThrow { throwError(.rangeError, message) }
    public func throwReferenceError(_ message: String) -> JSThrow { throwError(.referenceError, message) }
    public func throwSyntaxError(_ message: String) -> JSThrow { throwError(.syntaxError, message) }

    /// The pending exception value (after catching a JSThrow).
    public var pendingException: JSValue { exception }
    /// True while a termination (heap cap, interrupt) is unwinding.
    public var isTerminating: Bool { heap.termination != nil }
}

func jsErrorKindName(_ k: JSErrorKind) -> String {
    switch k {
    case .error: return "Error"
    case .typeError: return "TypeError"
    case .rangeError: return "RangeError"
    case .referenceError: return "ReferenceError"
    case .syntaxError: return "SyntaxError"
    case .evalError: return "EvalError"
    case .uriError: return "URIError"
    case .aggregateError: return "AggregateError"
    }
}
