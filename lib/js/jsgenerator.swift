// Generators, async functions and async generators (ROADMAP Phase 9E).
//
// A suspendable function's frame is saved into a state object when it
// suspends and copied back onto the VM stack when it resumes, so a
// suspension costs a copy of the frame's region and never a Swift stack.
//
// State object (kind .generator for generators, async functions and
// module bodies; .asyncGenerator for async generators):
//   internalInt  state (bits 0-7, JSGenState) | kind << 8 (JSGenKind) |
//                saved pc << 16
//   slot 0 env register   1 new.target   2 home object
//   slot 3 async function / module: the result promise; async generator:
//          its request queue (an internal object, flat [type, value,
//          promise] triples; type 0 next, 1 throw, 2 return)
//   slot 4 module: the module record object (jsmodule.swift)
//   slot 5... the saved stack region [callee, this, locals, operands]
//          (only while suspended)
//
// The compiler (jscompiler*.swift) emits, for a generator function:
//   params; generatorStart; body           (sync and async generators)
//   generatorStart; params; body           (async functions: errors in
//                                           parameter defaults reject)
// `yield v` is yield_ (sync: {value, done:false} to the resumer) followed
// by checkResume, which on resumption sees [value, mode] (mode 0 next,
// 1 throw, 2 return): 0 continues with the value, 1 throws it, 2 jumps to
// a return that runs finally blocks. `await v` is await_ + checkResume:
// the frame suspends after PerformPromiseThen(PromiseResolve(v)) with an
// await reaction whose job resumes it (jspromise.swift).
// Generator.prototype.next/return/throw called from JS (the VM sees their
// native indices in dispatchCall) push the generator frame onto the same
// VM loop; from Swift they run a nested loop like any call. Async
// generators resume from their natives (a nested loop, returning their
// request's promise). A frame that returns or throws out completes its
// state object: a sync generator gives {value, done:true} or rethrows;
// an async function resolves or rejects its promise (and never throws to
// its caller); an async generator completes the request at the head of
// its queue and drains the rest.

enum JSGenKind {
    static let generator: UInt8 = 1
    static let asyncFunction: UInt8 = 2
    static let asyncGenerator: UInt8 = 3
    static let module: UInt8 = 4
}

enum JSGenState {
    static let suspendedStart: Int64 = 0
    static let suspendedYield: Int64 = 1
    static let executing: Int64 = 2
    static let completed: Int64 = 3
    static let awaitingReturn: Int64 = 4
}

let jsGenHeader = 5

extension JSRealm {
    // MARK: State objects

    func genState(_ g: JSValue) -> Int64 { heap.internalInt(g) & 0xFF }
    func genKind(_ g: JSValue) -> UInt8 { UInt8(truncatingIfNeeded: (heap.internalInt(g) >> 8) & 0xFF) }
    func setGenState(_ g: JSValue, _ s: Int64) {
        heap.setInternalInt(g, (heap.internalInt(g) & ~0xFF) | s)
    }

    func newGenObject(kind: UInt8, proto: JSValue) -> JSValue {
        let g = heap.newObject(proto: proto.isObject ? proto : .null,
                               kind: kind == JSGenKind.asyncGenerator ? .asyncGenerator : .generator)
        heap.setSlots(g, [JSValue](repeating: .undefined, count: jsGenHeader))
        heap.setInternalInt(g, Int64(kind) << 8 | JSGenState.executing)
        return g
    }

    /// Save frame `f` (the top frame, with sp at the end of its operands)
    /// into its state object; resumes at `pc`.
    func saveFrame(_ g: JSValue, _ f: JSFrame, pc: Int) {
        var s: [JSValue] = []
        let lo = f.base - 2
        s.reserveCapacity(jsGenHeader + max(0, sp - lo))
        s.append(env); s.append(f.newTarget); s.append(f.home)
        s.append(heap.slot(g, 3)); s.append(heap.slot(g, 4))
        var i = lo
        while i < sp { s.append(stack[i]); i += 1 }
        heap.setSlots(g, s)
        let st = heap.internalInt(g) & 0xFFFF
        heap.setInternalInt(g, st | Int64(pc) << 16)
    }

    /// Push a saved frame back (state becomes executing).
    func restoreFrame(_ g: JSValue, mode: UInt8, entry: Bool) throws(JSThrow) {
        let n = heap.slotCount(g) - jsGenHeader
        let callee = heap.slot(g, jsGenHeader)
        guard n >= 2, let code = codeFor(function: callee) else { throw throwTypeError("Generator state is invalid") }
        if frames.count >= limits.maxCallDepth { throw throwRangeError("Maximum call stack size exceeded") }
        budget -= 1
        if budget <= 0 { try checkInterrupt() }
        try ensureStack(n + code.maxStack + 16)
        let base = sp + 2
        for i in 0..<n { stack[sp + i] = heap.slot(g, jsGenHeader + i) }
        sp += n
        let info = heap.internalInt(g)
        frames.append(JSFrame(code: code, pc: Int(info >> 16), base: base, callee: callee, this: stack[base - 1],
                              newTarget: heap.slot(g, 1), home: heap.slot(g, 2), callerEnv: env, mode: mode,
                              entry: entry, gen: g))
        env = heap.slot(g, 0)
        var hdr: [JSValue] = []
        for i in 0..<jsGenHeader { hdr.append(heap.slot(g, i)) }
        heap.setSlots(g, hdr)
        setGenState(g, JSGenState.executing)
    }

    /// The value handed to the caller of a frame (after it is popped).
    @inline(__always) func pushResult(_ r: JSValue, _ mode: UInt8) {
        if mode == JSFrameMode.discard { return }
        push(r)
        if mode == JSFrameMode.getterForCall {
            let a = stack[sp - 1]; stack[sp - 1] = stack[sp - 2]; stack[sp - 2] = a
        }
    }

    /// A frame of a suspendable function returned `r`: complete its state
    /// object; returns the value for the caller.
    func genReturned(_ g: JSValue, _ r: JSValue) throws(JSThrow) -> JSValue {
        let k = heap.root(r)
        defer { heap.popRoots(to: k.slot) }
        switch genKind(g) {
        case JSGenKind.generator:
            setGenState(g, JSGenState.completed)
            return try iterResult(r, done: true)
        case JSGenKind.asyncGenerator:
            setGenState(g, JSGenState.completed)
            try asyncGenCompleteStep(g, ok: true, r, done: true)
            try asyncGenDrainQueue(g)
            return .undefined
        default:
            let p = heap.slot(g, 3)
            setGenState(g, JSGenState.completed)
            try resolvePromise(p, r)
            if genKind(g) == JSGenKind.module { try moduleBodyFinished(g, ok: true, r) }
            return p
        }
    }

    /// An exception left a suspendable frame: nil for a sync generator
    /// (keep unwinding), else the value for the caller (the exception was
    /// turned into a rejection).
    func genThrewOut(_ g: JSValue) throws(JSThrow) -> JSValue? {
        if genKind(g) == JSGenKind.generator {
            setGenState(g, JSGenState.completed)
            return nil
        }
        let e = takeException()
        let k = heap.root(e)
        defer { heap.popRoots(to: k.slot) }
        setGenState(g, JSGenState.completed)
        if genKind(g) == JSGenKind.asyncGenerator {
            try asyncGenCompleteStep(g, ok: false, e, done: true)
            try asyncGenDrainQueue(g)
            return .undefined
        }
        let p = heap.slot(g, 3)
        rejectPromise(p, e)
        if genKind(g) == JSGenKind.module { try moduleBodyFinished(g, ok: false, e) }
        return p
    }

    // MARK: Sync generators

    /// Generator.prototype.next/return/throw (mode 0/1/2) from the VM:
    /// pushes the generator's frame (true) or the result (false).
    /// `drop`: the [f this args] values to pop from the stack first.
    func resumeGenerator(_ g: JSValue, _ v: JSValue, mode: Int, callMode: UInt8, drop: Int) throws(JSThrow) -> Bool {
        guard g.isObject && heap.kind(g) == .generator && genKind(g) == JSGenKind.generator else {
            throw throwTypeError((mode == 0 ? "next" : mode == 1 ? "throw" : "return") + " method called on incompatible receiver " + describeForError(g))
        }
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        _ = heap.root(g); _ = heap.root(v)
        sp -= drop
        let st = genState(g)
        if st == JSGenState.executing { throw throwTypeError("Generator is already running") }
        if st == JSGenState.suspendedStart && mode != 0 { setGenState(g, JSGenState.completed) }
        if genState(g) == JSGenState.completed {
            if mode == 1 { throw throwValue(v) }
            pushResult(try iterResult(mode == 2 ? v : .undefined, done: true), callMode)
            return false
        }
        try restoreFrame(g, mode: callMode, entry: false)
        if st != JSGenState.suspendedStart {
            push(v)
            push(.int32(Int32(mode)))
        }
        return true
    }

    // MARK: await

    /// Resume a frame suspended at await (the await reaction job).
    func resumeAwait(_ g: JSValue, _ v: JSValue, mode: Int) throws(JSThrow) {
        try enterNative()
        nativeDepth += 1
        defer { nativeDepth -= 1 }
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        _ = heap.root(g); _ = heap.root(v)
        let start = sp
        do throws(JSThrow) {
            try restoreFrame(g, mode: JSFrameMode.normal, entry: true)
            push(v)
            push(.int32(Int32(mode)))
            _ = try execute()
        } catch {
            sp = start
            throw error
        }
        sp = start
    }

    // MARK: Async generators

    func asyncGenQueue(_ g: JSValue) -> JSValue { heap.slot(g, 3) }

    /// AsyncGenerator.prototype.next/throw/return.
    func asyncGenEnqueue(_ g: JSValue, type: Int, _ v: JSValue) throws(JSThrow) -> JSValue {
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        _ = heap.root(g); _ = heap.root(v)
        let p = newPromise()
        _ = heap.root(p)
        guard g.isObject && heap.kind(g) == .asyncGenerator else {
            rejectPromise(p, makeError(.typeError, "AsyncGenerator method called on incompatible receiver"))
            return p
        }
        var st = genState(g)
        if type == 1 && st == JSGenState.suspendedStart { setGenState(g, JSGenState.completed); st = JSGenState.completed }
        if st == JSGenState.completed && type != 2 {
            if type == 1 { rejectPromise(p, v) } else { try resolvePromise(p, try iterResult(.undefined, done: true)) }
            return p
        }
        let q = asyncGenQueue(g)
        heap.appendSlotValue(q, .int32(Int32(type)))
        heap.appendSlotValue(q, v)
        heap.appendSlotValue(q, p)
        if type == 2 && (st == JSGenState.suspendedStart || st == JSGenState.completed) {
            setGenState(g, JSGenState.awaitingReturn)
            try asyncGenAwaitReturn(g)
        } else if st == JSGenState.suspendedStart || st == JSGenState.suspendedYield {
            try asyncGenResume(g, type: type, v, fromStart: st == JSGenState.suspendedStart)
        }
        return p
    }

    func asyncGenResume(_ g: JSValue, type: Int, _ v: JSValue, fromStart: Bool) throws(JSThrow) {
        try enterNative()
        nativeDepth += 1
        defer { nativeDepth -= 1 }
        let start = sp
        do throws(JSThrow) {
            try restoreFrame(g, mode: JSFrameMode.normal, entry: true)
            if !fromStart {
                push(v)
                push(.int32(Int32(type)))
            }
            _ = try execute()
        } catch {
            sp = start
            throw error
        }
        sp = start
    }

    /// Remove the head request and settle its promise.
    func asyncGenCompleteStep(_ g: JSValue, ok: Bool, _ v: JSValue, done: Bool) throws(JSThrow) {
        let q = asyncGenQueue(g)
        let n = heap.slotCount(q)
        guard n >= 3 else { return }
        let p = heap.slot(q, 2)
        var rest: [JSValue] = []
        for i in 3..<n { rest.append(heap.slot(q, i)) }
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        _ = heap.root(p); _ = heap.root(v)
        heap.setSlots(q, rest)
        if !ok { rejectPromise(p, v); return }
        let r = try iterResult(v, done: done)
        _ = heap.root(r)
        try resolvePromise(p, r)
    }

    func asyncGenDrainQueue(_ g: JSValue) throws(JSThrow) {
        var steps = 0
        while steps < 1_000_000 {
            steps += 1
            let q = asyncGenQueue(g)
            guard heap.slotCount(q) >= 3 else { return }
            let type = heap.slot(q, 0).asInt32
            if type == 2 {
                setGenState(g, JSGenState.awaitingReturn)
                try asyncGenAwaitReturn(g)
                return
            }
            if type == 1 {
                try asyncGenCompleteStep(g, ok: false, heap.slot(q, 1), done: true)
            } else {
                try asyncGenCompleteStep(g, ok: true, .undefined, done: true)
            }
        }
    }

    func asyncGenAwaitReturn(_ g: JSValue) throws(JSThrow) {
        let q = asyncGenQueue(g)
        let v = heap.slot(q, 1)
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        _ = heap.root(g)
        let p: JSValue
        do throws(JSThrow) {
            p = try promiseResolve(v)
        } catch {
            if heap.termination != nil { throw error }
            let e = takeException()
            _ = heap.root(e)
            setGenState(g, JSGenState.completed)
            try asyncGenCompleteStep(g, ok: false, e, done: true)
            try asyncGenDrainQueue(g)
            return
        }
        performPromiseThen(p, g, .undefined, JSCapability(promise: .undefined, resolve: .undefined, reject: .undefined), type: 2)
    }

    func asyncGenAwaitReturnSettled(_ g: JSValue, _ v: JSValue, rejected: Bool) throws(JSThrow) {
        setGenState(g, JSGenState.completed)
        try asyncGenCompleteStep(g, ok: !rejected, v, done: true)
        try asyncGenDrainQueue(g)
    }

    // MARK: Async iteration

    /// GetIterator(v, async): [iterator, next].
    func getAsyncIterator(_ v: JSValue) throws(JSThrow) -> (JSValue, JSValue) {
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        _ = heap.root(v)
        let m = try getV(v, .symbol(heap.symbolsWellKnown.asyncIterator.handle))
        if m.isNullish {
            let (it, next) = try getIterator(v)
            _ = heap.root(it); _ = heap.root(next)
            let w = heap.newObject(proto: intrinsic(.asyncFromSyncIteratorPrototype))
            heap.setSlots(w, [it, next])
            _ = heap.root(w)
            return (w, try getV(w, heap.names.next))
        }
        guard heap.isCallable(m) else { throw throwTypeError(describeForError(v) + " is not async iterable") }
        let it = try call(m, this: v, args: [])
        guard it.isObject else { throw throwTypeError("Result of the Symbol.asyncIterator method is not an object") }
        _ = heap.root(it)
        return (it, try getV(it, heap.names.next))
    }

    /// %AsyncFromSyncIteratorPrototype% next (0), throw (1), return (2).
    func asyncFromSyncStep(_ w: JSValue, _ v: JSValue, mode: Int, hasArg: Bool) throws(JSThrow) -> JSValue {
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        let p = newPromise()
        _ = heap.root(p)
        let it = heap.slot(w, 0), next = heap.slot(w, 1)
        _ = heap.root(it); _ = heap.root(next); _ = heap.root(v)
        do throws(JSThrow) {
            var done = false, value: JSValue = .undefined
            if mode == 0 && next.isHole {
                (done, value) = try iteratorStep(it, next)
            } else {
                var f = next
                if mode != 0 {
                    f = try getV(it, heap.key(mode == 1 ? "throw" : "return"))
                    if f.isNullish {
                        if mode == 2 {
                            try resolvePromise(p, try iterResult(v, done: true))
                            return p
                        }
                        try iteratorClose(it, next)
                        throw throwTypeError("The iterator does not provide a 'throw' method")
                    }
                }
                let res = try call(f, this: it, args: hasArg ? [v] : [])
                guard res.isObject else { throw throwTypeError("Iterator result " + describeForError(res) + " is not an object") }
                _ = heap.root(res)
                done = heap.toBoolean(try getV(res, heap.names.done))
                value = try getV(res, heap.names.value)
            }
            _ = heap.root(value)
            let wrapper = try promiseResolve(value)
            performPromiseThen(wrapper, .undefined, .undefined,
                               JSCapability(promise: p, resolve: .undefined, reject: .undefined),
                               type: 3 | (done ? 0x100 : 0))
        } catch {
            if heap.termination != nil { throw error }
            rejectPromise(p, takeException())
        }
        return p
    }

    // MARK: Closures

    func makeGeneratorClosure(_ code: JSCode, env: JSValue, home: JSValue) -> JSValue {
        var flags: JSObjectFlags = [.extensible, .callable]
        if code.strict { flags.insert(.strict) }
        let depth = heap.rootDepth
        defer { heap.popRoots(to: depth) }
        _ = heap.root(env)
        _ = heap.root(home)
        let proto: JSValue
        switch code.genKind {
        case JSGenKind.generator: proto = intrinsic(.generatorFunctionPrototype)
        case JSGenKind.asyncFunction: proto = intrinsic(.asyncFunctionPrototype)
        case JSGenKind.asyncGenerator: proto = intrinsic(.asyncGeneratorFunctionPrototype)
        default: proto = functionPrototype
        }
        let f = heap.newObject(proto: proto.isObject ? proto : functionPrototype, kind: .function, flags: flags)
        _ = heap.root(f)
        heap.setSlots(f, [code.codeObject, env, home, .undefined])
        heap.setInternalInt(f, Int64(code.id))
        _ = heap.defineOwnProperty(f, heap.names.length, .data(.number(code.length), [.configurable]))
        _ = heap.defineOwnProperty(f, heap.names.name, .data(code.name, [.configurable]))
        if code.genKind == JSGenKind.generator || code.genKind == JSGenKind.asyncGenerator {
            let pp = intrinsic(code.genKind == JSGenKind.generator ? .generatorPrototype : .asyncGeneratorPrototype)
            let p = heap.newObject(proto: pp)
            _ = heap.defineOwnProperty(f, heap.names.prototype, .data(p, [.writable]))
        }
        return f
    }
}

// MARK: Built-ins

/// Function(...)-style constructors for the generator/async kinds.
func jsDynamicFunction(_ realm: JSRealm, _ args: JSArgs, _ keyword: String) throws(JSThrow) -> JSValue {
    var params: [String] = []
    var body = ""
    for i in 0..<args.count {
        let s = try realm.toSwiftString(args[i])
        if i == args.count - 1 { body = s } else { params.append(s) }
    }
    let src = "(" + keyword + " anonymous(" + params.joined(separator: ",") + "\n) {\n" + body + "\n})"
    let depth = realm.heap.rootDepth
    defer { realm.heap.popRoots(to: depth) }
    let closure = try realm.compileScriptClosure(Array(src.utf8), name: "anonymous", eval: true, strict: false)
    return try realm.call(closure, this: realm.global, args: [])
}

func jsInstallGenerators(_ realm: JSRealm) {
    let heap = realm.heap
    let es = realm.es
    let fp = realm.functionPrototype
    let tagKey = JSPropertyKey.symbol(heap.symbolsWellKnown.toStringTag.handle)
    func tag(_ o: JSValue, _ s: String) {
        _ = heap.defineOwnProperty(o, tagKey, .data(realm.string(s), [.configurable]))
    }

    let aip = heap.newObject(proto: realm.objectPrototype)
    realm.setIntrinsic(.asyncIteratorPrototype, aip)
    realm.defineMethod(aip, "[Symbol.asyncIterator]", length: 0, key: .symbol(heap.symbolsWellKnown.asyncIterator.handle)) {
        (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in args.this
    }

    // %GeneratorPrototype%: next/return/throw are registered consecutively;
    // the VM intercepts calls to them (dispatchCall).
    let gp = heap.newObject(proto: realm.intrinsic(.iteratorPrototype))
    realm.setIntrinsic(.generatorPrototype, gp)
    let names = ["next", "throw", "return"]
    var first = -1
    for (i, n) in names.enumerated() {
        let idx = realm.registerNative(n, length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            // Reached only if a caller bypasses dispatchCall.
            try realm.call(args.callee, this: args.this, args: [args[0]])
        }
        if i == 0 { first = idx }
        let f = realm.newNativeFunction(idx)
        _ = heap.defineOwnProperty(gp, heap.key(n), .data(f, [.writable, .configurable]))
    }
    es.genResumeBase = first
    tag(gp, "Generator")

    let gfp = heap.newObject(proto: fp)
    realm.setIntrinsic(.generatorFunctionPrototype, gfp)
    _ = heap.defineOwnProperty(gfp, heap.names.prototype, .data(gp, [.configurable]))
    _ = heap.defineOwnProperty(gp, heap.names.constructor, .data(gfp, [.configurable]))
    tag(gfp, "GeneratorFunction")

    // %AsyncGeneratorPrototype%
    let agp = heap.newObject(proto: aip)
    realm.setIntrinsic(.asyncGeneratorPrototype, agp)
    for (i, n) in names.enumerated() {
        realm.defineMethod(agp, n, length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            try realm.asyncGenEnqueue(args.this, type: i, args[0])
        }
    }
    tag(agp, "AsyncGenerator")
    let agfp = heap.newObject(proto: fp)
    realm.setIntrinsic(.asyncGeneratorFunctionPrototype, agfp)
    _ = heap.defineOwnProperty(agfp, heap.names.prototype, .data(agp, [.configurable]))
    _ = heap.defineOwnProperty(agp, heap.names.constructor, .data(agfp, [.configurable]))
    tag(agfp, "AsyncGeneratorFunction")

    // %AsyncFunction.prototype%
    let afp = heap.newObject(proto: fp)
    realm.setIntrinsic(.asyncFunctionPrototype, afp)
    tag(afp, "AsyncFunction")

    // %AsyncFromSyncIteratorPrototype%
    let afs = heap.newObject(proto: aip)
    realm.setIntrinsic(.asyncFromSyncIteratorPrototype, afs)
    for (i, n) in ["next", "throw", "return"].enumerated() {
        realm.defineMethod(afs, n, length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            try realm.asyncFromSyncStep(args.this, args[0], mode: i, hasArg: args.count > 0)
        }
    }

    // The constructors (not globals): reachable as X.prototype.constructor.
    let ctorFC = realm.intrinsic(.functionConstructor)
    let kinds: [(JSValue, String, String)] = [(gfp, "GeneratorFunction", "function*"),
                                              (agfp, "AsyncGeneratorFunction", "async function*"),
                                              (afp, "AsyncFunction", "async function")]
    for (proto, name, kw) in kinds {
        let c = realm.newNativeFunction(realm.registerNative(name, length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            try jsDynamicFunction(realm, args, kw)
        }, constructor: true)
        if ctorFC.isObject { _ = heap.setPrototypeOf(c, ctorFC) }
        _ = heap.defineOwnProperty(c, heap.names.prototype, .data(proto, []))
        _ = heap.defineOwnProperty(proto, heap.names.constructor, .data(c, [.configurable]))
    }
}
