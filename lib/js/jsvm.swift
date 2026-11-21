// The bytecode interpreter (ROADMAP Phase 9B). See jsbytecode.swift for
// the instruction set and frame layout, jsvm_ops.swift for the abstract
// operations and property helpers.
//
// Calls. A JS-to-JS call (call/construct/getter/setter instructions)
// pushes a JSFrame and continues in the same loop: no Swift recursion.
// Native code that calls back into JS (realm.call / construct, ToPrimitive
// calling valueOf, ...) runs a nested execute() that returns when its
// entry frame returns; that nesting is capped by limits.maxNativeNesting
// and by a stack-address floor, both a RangeError. JS call depth is capped
// by limits.maxCallDepth (RangeError "Maximum call stack size exceeded").
//
// Exceptions. A throw sets realm.exception and propagates a JSThrow; the
// loop's catch unwinds frames, looking up each one's handler table, and
// rethrows out of execute() at the entry frame. During a termination
// (heap.termination set) handlers are skipped, so no catch or finally runs.
//
// Interrupts. `budget` counts down at every backward jump and every JS
// function entry; at zero (limits.interruptInterval) the VM runs
// heap.safePoint() (GC), checks heap.termination and asks the runtime's
// interruptHandler whether to stop.
//
// Suspension (for 9E's generators/async): a frame's whole state is the
// JSFrame plus its stack region [base - 2, sp) and the env register, so a
// suspended frame can be saved into a heap object and resumed later.

extension JSRealm {
    @inline(__always) func push(_ v: JSValue) {
        stack[sp] = v
        sp += 1
    }

    @inline(__always) func pop() -> JSValue {
        sp -= 1
        return stack[sp]
    }

    /// Make room for n more values above sp.
    func ensureStack(_ n: Int) throws(JSThrow) {
        if sp + n <= stackCap { return }
        var cap = stackCap
        while cap < sp + n { cap *= 2 }
        if cap > (1 << 22) { throw throwRangeError("Maximum call stack size exceeded") }
        let s = UnsafeMutablePointer<JSValue>.allocate(capacity: cap)
        s.initialize(repeating: .undefined, count: cap)
        for i in 0..<stackCap { s[i] = stack[i] }
        stack.deinitialize(count: stackCap)
        stack.deallocate()
        stack = s
        stackCap = cap
    }

    func checkInterrupt() throws(JSThrow) {
        budget = max(1, limits.interruptInterval)
        heap.safePoint()
        if heap.termination != nil { throw JSThrow() }
        if let h = runtime.interruptHandler, h(self) {
            heap.requestTermination(.interrupted)
            throw JSThrow()
        }
    }

    // MARK: Swift -> JS

    func enterNative() throws(JSThrow) {
        if heap.termination != nil { throw JSThrow() }
        if nativeDepth >= limits.maxNativeNesting || jsStackAddress() < stackFloor {
            throw throwRangeError("Maximum call stack size exceeded")
        }
    }

    /// Call any callable (native re-entry).
    public func call(_ f: JSValue, this: JSValue, args: [JSValue]) throws(JSThrow) -> JSValue {
        try enterNative()
        nativeDepth += 1
        defer { nativeDepth -= 1 }
        try ensureStack(args.count + 18)
        let start = sp
        push(f)
        push(this)
        for a in args { push(a) }
        do throws(JSThrow) {
            if try dispatchCall(args.count, mode: JSFrameMode.normal) {
                frames[frames.count - 1].entry = true
                return try execute()
            }
            return pop()
        } catch {
            sp = start
            throw error
        }
    }

    /// [[Construct]] from Swift.
    public func construct(_ f: JSValue, args: [JSValue], newTarget: JSValue? = nil) throws(JSThrow) -> JSValue {
        try enterNative()
        nativeDepth += 1
        defer { nativeDepth -= 1 }
        try ensureStack(args.count + 18)
        let start = sp
        push(f)
        push(newTarget ?? f)
        for a in args { push(a) }
        do throws(JSThrow) {
            if try dispatchConstruct(args.count) {
                frames[frames.count - 1].entry = true
                return try execute()
            }
            return pop()
        } catch {
            sp = start
            throw error
        }
    }

    // MARK: Call dispatch

    /// Stack: [f this args...]. Pushes a frame (true) or runs a native and
    /// pushes its result (false; nothing for mode .discard).
    func dispatchCall(_ argcIn: Int, mode: UInt8) throws(JSThrow) -> Bool {
        var argc = argcIn
        var steps = 0
        while true {
            let f = stack[sp - argc - 2]
            switch heap.kind(f) {
            case .function:
                if heap.flags(f).contains(.classConstructor) {
                    throw throwTypeError("Class constructor \(functionName(f)) cannot be invoked without 'new'")
                }
                try enterFunction(f, argc: argc, mode: mode, newTarget: .undefined, this: stack[sp - argc - 1])
                return true
            case .nativeFunction:
                let idx = Int(heap.internalInt(f))
                if idx == callNativeIndex || idx == applyNativeIndex {
                    // Function.prototype.call/apply: rewrite the stack and
                    // dispatch again (no Swift recursion).
                    argc = idx == callNativeIndex ? shiftForCall(argc) : try spreadForApply(argc)
                    steps += 1
                    if steps > 10_000 { throw throwRangeError("Maximum call stack size exceeded") }
                    continue
                }
                let gb = es.genResumeBase
                if idx >= gb && idx < gb + 3 && gb >= 0 {
                    // Generator.prototype.next/throw/return: resume the
                    // generator's frame in this loop (jsgenerator.swift).
                    let g = stack[sp - argc - 1]
                    let v = argc > 0 ? stack[sp - argc] : JSValue.undefined
                    let m = idx - gb
                    let pushed = try resumeGenerator(g, v, mode: m == 0 ? 0 : m == 1 ? 1 : 2, callMode: mode,
                                                     drop: argc + 2)
                    return pushed
                }
                let r = try callNative(f, argc: argc, this: stack[sp - argc - 1], newTarget: .undefined)
                sp -= argc + 2
                pushResult(r, mode)
                return false
            case .boundFunction:
                argc = try unbind(f, argc: argc, construct: false)
                steps += 1
                if steps > 10_000 { throw throwRangeError("Maximum call stack size exceeded") }
            case .proxy where heap.isCallable(f):
                // 9E: the apply trap (jsbuiltins_proxy.swift).
                try dispatchProxyCall(argc, mode: mode)
                return false
            default:
                throw throwTypeError(describeForError(f) + " is not a function")
            }
        }
    }

    /// [call fn a0 a1...] -> [fn a0 a1...].
    func shiftForCall(_ argc: Int) -> Int {
        let fpos = sp - argc - 2
        var i = fpos
        while i < sp - 1 { stack[i] = stack[i + 1]; i += 1 }
        sp -= 1
        if argc == 0 { push(.undefined); return 0 }
        return argc - 1
    }

    /// [apply fn thisArg arrayLike] -> [fn thisArg elements...].
    func spreadForApply(_ argc: Int) throws(JSThrow) -> Int {
        let fpos = sp - argc - 2
        let fn = stack[fpos + 1]
        let thisArg = argc > 0 ? stack[fpos + 2] : JSValue.undefined
        let arr = argc > 1 ? stack[fpos + 3] : JSValue.undefined
        stack[fpos] = fn
        stack[fpos + 1] = thisArg
        if arr.isNullish { sp = fpos + 2; return 0 }
        guard arr.isObject else { throw throwTypeError("CreateListFromArrayLike called on non-object") }
        stack[fpos + 2] = arr
        sp = fpos + 3
        let n = heap.kind(arr) == .array ? Int(heap.arrayLength(arr)) : try toLength(try getV(arr, heap.names.length))
        if n > 1 << 16 { throw throwRangeError("Maximum call stack size exceeded") }
        try ensureStack(n + 16)
        for i in 0..<n { push(try getV(stack[fpos + 2], .index(UInt32(i)))) }
        var i = fpos + 2
        while i < sp - 1 { stack[i] = stack[i + 1]; i += 1 }
        sp -= 1
        return n
    }

    /// Stack: [f newTarget args...].
    func dispatchConstruct(_ argcIn: Int) throws(JSThrow) -> Bool {
        var argc = argcIn
        var steps = 0
        while true {
            let f = stack[sp - argc - 2]
            guard heap.flags(f).contains(.constructor) else {
                throw throwTypeError(describeForError(f) + " is not a constructor")
            }
            switch heap.kind(f) {
            case .function:
                guard let code = codeFor(function: f) else { throw throwTypeError("bad function") }
                let nt = stack[sp - argc - 1]
                var this: JSValue = .hole
                if code.kind != .derivedConstructor {
                    let proto = try prototypeFromConstructor(nt, .objectPrototype)
                    this = heap.newObject(proto: proto)
                }
                stack[sp - argc - 1] = this
                let r = heap.root(nt)
                defer { heap.popRoots(to: r.slot) }
                try enterFunction(f, argc: argc, mode: JSFrameMode.construct, newTarget: nt, this: this)
                return true
            case .nativeFunction:
                let nt = stack[sp - argc - 1]
                let r = try callNative(f, argc: argc, this: .undefined, newTarget: nt)
                sp -= argc + 2
                guard r.isObject else { throw throwTypeError("constructor did not return an object") }
                push(r)
                return false
            case .boundFunction:
                argc = try unbind(f, argc: argc, construct: true)
                steps += 1
                if steps > 10_000 { throw throwRangeError("Maximum call stack size exceeded") }
            case .proxy:
                // 9E: the construct trap (jsbuiltins_proxy.swift).
                try dispatchProxyConstruct(argc)
                return false
            default:
                throw throwTypeError(describeForError(f) + " is not a constructor")
            }
        }
    }

    /// Replace a bound function on the stack by its target, inserting the
    /// bound arguments. Returns the new argument count.
    func unbind(_ f: JSValue, argc: Int, construct: Bool) throws(JSThrow) -> Int {
        let n = heap.slotCount(f)
        let target = heap.slot(f, 0)
        let nb = max(0, n - 2)
        try ensureStack(nb + 16)
        let argBase = sp - argc
        var i = sp - 1
        while i >= argBase { stack[i + nb] = stack[i]; i -= 1 }
        for j in 0..<nb { stack[argBase + j] = heap.slot(f, 2 + j) }
        sp += nb
        stack[argBase - 2] = target
        if construct {
            if stack[argBase - 1] == f { stack[argBase - 1] = target }
        } else {
            stack[argBase - 1] = heap.slot(f, 1)
        }
        return argc + nb
    }

    func callNative(_ f: JSValue, argc: Int, this: JSValue, newTarget: JSValue) throws(JSThrow) -> JSValue {
        let idx = Int(heap.internalInt(f))
        guard idx >= 0 && idx < natives.count else { return .undefined }
        if heap.termination != nil { throw JSThrow() }
        let args = JSArgs(realm: self, base: sp - argc, count: argc, this: this, callee: f, newTarget: newTarget)
        let fn = natives[idx].fn
        return try fn(self, args)
    }

    /// Push a frame for compiled code. Stack: [f this args...].
    func enterFunction(_ f: JSValue, argc: Int, mode: UInt8, newTarget: JSValue, this: JSValue) throws(JSThrow) {
        guard let code = codeFor(function: f) else { throw throwTypeError("bad function") }
        if frames.count >= limits.maxCallDepth { throw throwRangeError("Maximum call stack size exceeded") }
        budget -= 1
        if budget <= 0 { try checkInterrupt() }
        let base = sp - argc
        let np = code.nparams
        let nl = code.nlocals
        try ensureStack(max(argc, np) + nl + code.maxStack + 16)
        var argsObj: JSValue = .undefined, rest: JSValue = .undefined
        if code.argumentsLocal >= 0 {
            push(makeArguments(base: base, argc: argc, callee: f, strict: code.strict,
                               mapped: code.mappedArguments ? min(argc, np) : 0))
        }
        if code.restLocal >= 0 {
            var vals: [JSValue] = []
            if argc > np { for i in np..<argc { vals.append(stack[base + i]) } }
            push(heap.newArray(proto: arrayPrototype, elements: vals))
            rest = pop()
        }
        if code.argumentsLocal >= 0 { argsObj = pop() }
        if argc < np { for i in argc..<np { stack[base + i] = .undefined } }
        if nl > np { for i in np..<nl { stack[base + i] = .undefined } }
        sp = base + nl
        if code.argumentsLocal >= 0 && code.argumentsLocal < nl { stack[base + code.argumentsLocal] = argsObj }
        if code.restLocal >= 0 && code.restLocal < nl { stack[base + code.restLocal] = rest }
        frames.append(JSFrame(code: code, pc: 0, base: base, callee: f, this: this, newTarget: newTarget,
                              home: heap.slot(f, 2), callerEnv: env, mode: mode, entry: false))
        env = heap.slot(f, 1)
    }

    func makeArguments(base: Int, argc: Int, callee: JSValue, strict: Bool, mapped: Int = 0) -> JSValue {
        var vals: [JSValue] = []
        vals.reserveCapacity(argc)
        for i in 0..<argc { vals.append(stack[base + i]) }
        let a = heap.newObject(proto: objectPrototype, kind: .arguments)
        let r = heap.root(a)
        if mapped > 0 {
            // Mapped arguments (jsarguments.swift): slot 0 = env, slot 1 + i = env slot of arg i or -1.
            var ms: [JSValue] = [.undefined]
            for _ in 0..<mapped { ms.append(.int32(-1)) }
            heap.setSlots(a, ms)
        }
        // Filled in place (9J: four defineOwnProperty calls per arguments
        // object were most of a call's cost): dense elements, then length,
        // @@iterator and callee, which are fresh keys on a fresh object.
        var props: [JSPropertySlot] = [
            JSPropertySlot(key: heap.names.length, value: .number(argc), setter: .undefined, attributes: [.writable, .configurable])]
        let it = intrinsic(.arrayValues)
        if it.isObject {
            props.append(JSPropertySlot(key: .symbol(heap.symbolsWellKnown.iterator.handle), value: it, setter: .undefined,
                                        attributes: [.writable, .configurable]))
        }
        if !strict {
            props.append(JSPropertySlot(key: heap.names.callee, value: callee, setter: .undefined, attributes: [.writable, .configurable]))
        } else {
            // Strict arguments: callee is a %ThrowTypeError% accessor, not configurable.
            let tte = intrinsic(.throwTypeError)
            props.append(JSPropertySlot(key: heap.names.callee, value: tte, setter: tte, attributes: [.accessor]))
        }
        heap.fillFreshObject(a, elements: vals, props: props)
        heap.popRoots(to: r.slot)
        return a
    }

    func functionName(_ f: JSValue) -> String {
        if case .value(let n) = heap.getProperty(f, heap.names.name), n.isString { return heap.swiftString(n) }
        return "anonymous"
    }

    // MARK: The loop

    /// Run from the top frame (an entry frame) until it returns.
    func execute() throws(JSThrow) -> JSValue {
        let heap = self.heap
        var t = frames.count - 1
        var code = frames[t].code
        var bc = UnsafePointer(code.code)
        var consts = UnsafePointer(code.constPtr)
        var keys = UnsafePointer(code.keyPtr)
        var pc = frames[t].pc
        var base = frames[t].base
        var opPC = pc
        while true {
            do throws(JSThrow) {
                while true {
                    opPC = pc
                    curPC = pc
                    guard let op = JSOp(rawValue: bc[pc]) else { throw throwSyntaxError("bad bytecode") }
                    switch op {
                    case .nop, .debugger:
                        pc += 1
                    case .pop:
                        sp -= 1; pc += 1
                    case .popN:
                        sp -= jsReadU32(bc, pc + 1); pc += 5
                    case .dup:
                        push(stack[sp - 1]); pc += 1
                    case .dup2:
                        let a = stack[sp - 2], b = stack[sp - 1]
                        push(a); push(b); pc += 1
                    case .swap:
                        let a = stack[sp - 1]; stack[sp - 1] = stack[sp - 2]; stack[sp - 2] = a; pc += 1
                    case .rot3:
                        let c = stack[sp - 1]
                        stack[sp - 1] = stack[sp - 2]; stack[sp - 2] = stack[sp - 3]; stack[sp - 3] = c
                        pc += 1
                    case .rot4:
                        let d = stack[sp - 1]
                        stack[sp - 1] = stack[sp - 2]; stack[sp - 2] = stack[sp - 3]; stack[sp - 3] = stack[sp - 4]
                        stack[sp - 4] = d
                        pc += 1
                    case .over:
                        push(stack[sp - 2]); pc += 1
                    case .pushUndefined: push(.undefined); pc += 1
                    case .pushNull: push(.null); pc += 1
                    case .pushTrue: push(.true); pc += 1
                    case .pushFalse: push(.false); pc += 1
                    case .pushHole: push(.hole); pc += 1
                    case .pushInt:
                        push(.int32(Int32(truncatingIfNeeded: jsReadI32(bc, pc + 1)))); pc += 5
                    case .pushConst:
                        push(consts[jsReadU32(bc, pc + 1)]); pc += 5
                    case .getLocal:
                        push(stack[base + jsReadU32(bc, pc + 1)]); pc += 5
                    case .putLocal:
                        sp -= 1
                        stack[base + jsReadU32(bc, pc + 1)] = stack[sp]; pc += 5
                    case .setLocal:
                        stack[base + jsReadU32(bc, pc + 1)] = stack[sp - 1]; pc += 5
                    case .getLocalChecked:
                        let v = stack[base + jsReadU32(bc, pc + 1)]
                        if v.isHole { throw tdzError(code, jsReadU32(bc, pc + 5)) }
                        push(v); pc += 9
                    case .putLocalChecked:
                        let i = base + jsReadU32(bc, pc + 1)
                        if stack[i].isHole { throw tdzError(code, jsReadU32(bc, pc + 5)) }
                        sp -= 1
                        stack[i] = stack[sp]; pc += 9
                    case .getEnv, .getEnvChecked:
                        let e = envAt(jsReadU16(bc, pc + 1))
                        let v = heap.slot(e, jsReadU32(bc, pc + 3))
                        if op == .getEnvChecked {
                            if v.isHole { throw tdzError(code, jsReadU32(bc, pc + 7)) }
                            pc += 11
                        } else { pc += 7 }
                        push(v)
                    case .putEnv, .setEnv, .putEnvChecked:
                        let e = envAt(jsReadU16(bc, pc + 1))
                        let s = jsReadU32(bc, pc + 3)
                        if op == .putEnvChecked {
                            if heap.slot(e, s).isHole { throw tdzError(code, jsReadU32(bc, pc + 7)) }
                            pc += 11
                        } else { pc += 7 }
                        heap.setSlot(e, s, stack[sp - 1])
                        if op != .setEnv { sp -= 1 }
                    case .pushEnv:
                        env = newEnvironment(parent: env, info: consts[jsReadU32(bc, pc + 1)])
                        pc += 5
                    case .popEnv:
                        env = heap.slot(env, 0); pc += 1
                    case .cloneEnv:
                        env = cloneEnvironment(env); pc += 1
                    case .saveEnv:
                        stack[base + jsReadU32(bc, pc + 1)] = env; pc += 5
                    case .restoreEnv:
                        env = stack[base + jsReadU32(bc, pc + 1)]; pc += 5
                    case .enterWith:
                        let o = try toObject(stack[sp - 1])
                        stack[sp - 1] = o
                        env = newWithEnvironment(parent: env, object: o)
                        sp -= 1; pc += 1
                    case .getName, .getNameOrUndef:
                        push(try getName(keys[jsReadU32(bc, pc + 1)], orUndefined: op == .getNameOrUndef))
                        pc += 5
                    case .putName:
                        try putName(keys[jsReadU32(bc, pc + 1)], stack[sp - 1], strict: code.strict)
                        sp -= 1; pc += 5
                    case .getNameForCall:
                        let (f, th) = try getNameForCall(keys[jsReadU32(bc, pc + 1)])
                        push(f); push(th); pc += 5
                    case .deleteName:
                        push(.bool(try deleteName(keys[jsReadU32(bc, pc + 1)]))); pc += 5
                    case .getGlobal, .getGlobalOrUndef, .getGlobalForCall:
                        let ki = jsReadU32(bc, pc + 1)
                        if let v = cachedGlobal(code, ki) {
                            push(v)
                        } else {
                            push(try getGlobal(keys[ki], orUndefined: op == .getGlobalOrUndef))
                            fillGlobalCache(code, ki)
                        }
                        if op == .getGlobalForCall { push(.undefined) }
                        pc += 5
                    case .putGlobal:
                        let ki = jsReadU32(bc, pc + 1)
                        if !cachedPutGlobal(code, ki, stack[sp - 1]) {
                            try putGlobal(keys[ki], stack[sp - 1], strict: code.strict)
                            fillGlobalCache(code, ki)
                        }
                        sp -= 1; pc += 5
                    case .declareVar:
                        try declareVar(keys[jsReadU32(bc, pc + 1)], isEval: code.kind == .eval)
                        pc += 5
                    case .declareFunc:
                        try declareFunc(keys[jsReadU32(bc, pc + 1)], stack[sp - 1], isEval: code.kind == .eval)
                        sp -= 1; pc += 5
                    case .declareLex:
                        try declareLex(keys[jsReadU32(bc, pc + 1)], isConst: bc[pc + 5] != 0)
                        pc += 6
                    case .initLex:
                        initLex(keys[jsReadU32(bc, pc + 1)], stack[sp - 1])
                        sp -= 1; pc += 5
                    case .getField:
                        let k = keys[jsReadU32(bc, pc + 1)]
                        pc += 5
                        let o = stack[sp - 1]
                        if o.isObject {
                            switch heap.getProperty(o, k) {
                            case .value(let v): stack[sp - 1] = v
                            case .getter(let g):
                                stack[sp - 1] = g
                                push(o)
                                frames[t].pc = pc
                                if try dispatchCall(0, mode: JSFrameMode.normal) {
                                    t = frames.count - 1; code = frames[t].code; bc = UnsafePointer(code.code); consts = UnsafePointer(code.constPtr); keys = UnsafePointer(code.keyPtr)
                                    pc = frames[t].pc; base = frames[t].base
                                }
                            case .exotic(let e):
                                // 9E: Proxy / host exotic on the chain (jsexotic.swift).
                                frames[t].pc = pc
                                stack[sp - 1] = try exoticGet(e, k, receiver: o)
                            }
                        } else {
                            stack[sp - 1] = try getPrimitive(o, k)
                        }
                    case .putField:
                        let k = keys[jsReadU32(bc, pc + 1)]
                        pc += 5
                        frames[t].pc = pc
                        if try putProperty(stack[sp - 2], k, strict: code.strict) {
                            t = frames.count - 1; code = frames[t].code; bc = UnsafePointer(code.code); consts = UnsafePointer(code.constPtr); keys = UnsafePointer(code.keyPtr)
                            pc = frames[t].pc; base = frames[t].base
                        }
                    case .getElem:
                        pc += 1
                        let o = stack[sp - 2], kv = stack[sp - 1]
                        if o.isObject && kv.isInt32 && kv.asInt32 >= 0 {
                            if case .value(let v) = heap.getProperty(o, .index(UInt32(kv.asInt32))) {
                                sp -= 1; stack[sp - 1] = v
                                break
                            }
                        }
                        let k = try toPropertyKey(kv)
                        sp -= 1
                        if o.isObject {
                            switch heap.getProperty(o, k) {
                            case .value(let v): stack[sp - 1] = v
                            case .getter(let g):
                                stack[sp - 1] = g
                                push(o)
                                frames[t].pc = pc
                                if try dispatchCall(0, mode: JSFrameMode.normal) {
                                    t = frames.count - 1; code = frames[t].code; bc = UnsafePointer(code.code); consts = UnsafePointer(code.constPtr); keys = UnsafePointer(code.keyPtr)
                                    pc = frames[t].pc; base = frames[t].base
                                }
                            case .exotic(let e):
                                // 9E: Proxy / host exotic on the chain (jsexotic.swift).
                                frames[t].pc = pc
                                stack[sp - 1] = try exoticGet(e, k, receiver: o)
                            }
                        } else {
                            stack[sp - 1] = try getPrimitive(o, k)
                        }
                    case .putElem:
                        pc += 1
                        let o = stack[sp - 3], kv = stack[sp - 2]
                        if o.isObject && kv.isInt32 && kv.asInt32 >= 0 {
                            let v = stack[sp - 1]
                            if heap.setProperty(o, .index(UInt32(kv.asInt32)), v, receiver: o) == .done {
                                sp -= 2; stack[sp - 1] = v
                                break
                            }
                        }
                        let k = try toPropertyKey(kv)
                        // [obj key v] -> [obj v]
                        stack[sp - 2] = stack[sp - 1]
                        sp -= 1
                        frames[t].pc = pc
                        if try putProperty(stack[sp - 2], k, strict: code.strict) {
                            t = frames.count - 1; code = frames[t].code; bc = UnsafePointer(code.code); consts = UnsafePointer(code.constPtr); keys = UnsafePointer(code.keyPtr)
                            pc = frames[t].pc; base = frames[t].base
                        }
                    case .getFieldForCall:
                        let o = stack[sp - 1]
                        let k = keys[jsReadU32(bc, pc + 1)]
                        pc += 5
                        if o.isObject, case .getter(let g) = heap.getProperty(o, k) {
                            // A getter for a method call runs as a frame: [o g o] -> [result o].
                            try ensureStack(3)
                            push(g); push(o)
                            frames[t].pc = pc
                            if try dispatchCall(0, mode: JSFrameMode.getterForCall) {
                                t = frames.count - 1; code = frames[t].code; bc = UnsafePointer(code.code); consts = UnsafePointer(code.constPtr); keys = UnsafePointer(code.keyPtr); pc = frames[t].pc; base = frames[t].base
                            }
                            break
                        }
                        stack[sp - 1] = try getV(o, k)
                        push(o)
                    case .getElemForCall:
                        let o = stack[sp - 2]
                        let k = try toPropertyKey(stack[sp - 1])
                        stack[sp - 2] = try getV(o, k)
                        stack[sp - 1] = o; pc += 1
                    case .deleteField:
                        stack[sp - 1] = .bool(try deleteProperty(stack[sp - 1], keys[jsReadU32(bc, pc + 1)],
                                                                 strict: code.strict))
                        pc += 5
                    case .deleteElem:
                        let k = try toPropertyKey(stack[sp - 1])
                        sp -= 1
                        stack[sp - 1] = .bool(try deleteProperty(stack[sp - 1], k, strict: code.strict))
                        pc += 1
                    case .getSuperField:
                        let v = try superGet(this: stack[sp - 2], home: stack[sp - 1], keys[jsReadU32(bc, pc + 1)])
                        sp -= 1; stack[sp - 1] = v; pc += 5
                    case .getSuperElem:
                        let k = try toPropertyKey(stack[sp - 1])
                        let v = try superGet(this: stack[sp - 3], home: stack[sp - 2], k)
                        sp -= 2; stack[sp - 1] = v; pc += 1
                    case .putSuperField:
                        let v = stack[sp - 1]
                        try superSet(this: stack[sp - 3], home: stack[sp - 2], keys[jsReadU32(bc, pc + 1)], v,
                                     strict: code.strict)
                        sp -= 2; stack[sp - 1] = v; pc += 5
                    case .putSuperElem:
                        let v = stack[sp - 1]
                        let k = try toPropertyKey(stack[sp - 2])
                        try superSet(this: stack[sp - 4], home: stack[sp - 3], k, v, strict: code.strict)
                        sp -= 3; stack[sp - 1] = v; pc += 1
                    case .newObject:
                        push(heap.newObject(proto: objectPrototype)); pc += 1
                    case .newArray:
                        push(heap.newArray(proto: arrayPrototype)); pc += 5
                    case .defineField:
                        let k = keys[jsReadU32(bc, pc + 1)]
                        if !heap.createDataProperty(stack[sp - 2], k, stack[sp - 1]) {
                            throw throwTypeError("Cannot define property " + keyDisplay(k))
                        }
                        sp -= 1; pc += 5
                    case .defineElem:
                        let k = try toPropertyKey(stack[sp - 2])
                        if !heap.createDataProperty(stack[sp - 3], k, stack[sp - 1]) {
                            throw throwTypeError("Cannot define property " + keyDisplay(k))
                        }
                        sp -= 2; pc += 1
                    case .defineMethod:
                        let k = keys[jsReadU32(bc, pc + 1)]
                        try defineMethodProperty(stack[sp - 2], k, stack[sp - 1], flags: bc[pc + 5])
                        sp -= 1; pc += 6
                    case .defineMethodElem:
                        let k = try toPropertyKey(stack[sp - 2])
                        try defineMethodProperty(stack[sp - 3], k, stack[sp - 1], flags: bc[pc + 1])
                        sp -= 2; pc += 2
                    case .appendElem:
                        let a = stack[sp - 2]
                        _ = heap.createDataProperty(a, .index(heap.arrayLength(a)), stack[sp - 1])
                        sp -= 1; pc += 1
                    case .appendHole:
                        let a = stack[sp - 1]
                        _ = heap.setArrayLength(a, heap.arrayLength(a) &+ 1)
                        pc += 1
                    case .appendSpread:
                        try appendSpread(stack[sp - 2], stack[sp - 1])
                        sp -= 1; pc += 1
                    case .copyDataProps:
                        try copyDataProperties(into: stack[sp - 2], from: stack[sp - 1], excluding: .undefined)
                        sp -= 1; pc += 1
                    case .objectRest:
                        let o = heap.newObject(proto: objectPrototype)
                        push(o)
                        try copyDataProperties(into: o, from: stack[sp - 2], excluding: consts[jsReadU32(bc, pc + 1)])
                        sp -= 1; stack[sp - 1] = o; pc += 5
                    case .setProto:
                        let p = stack[sp - 1]
                        if p.isObject || p.isNull { _ = heap.setPrototypeOf(stack[sp - 2], p) }
                        sp -= 1; pc += 1
                    case .closure:
                        let co = consts[jsReadU32(bc, pc + 1)]
                        guard let c = self.code(ofCodeObject: co) else { throw throwTypeError("bad closure") }
                        push(makeClosure(c, env: env)); pc += 5
                    case .newRegExp:
                        let p = consts[jsReadU32(bc, pc + 1)], fl = consts[jsReadU32(bc, pc + 5)]
                        guard let make = regExpCreate else { throw throwSyntaxError("not supported yet: RegExp") }
                        push(try make(self, p, fl)); pc += 9
                    case .templateObject:
                        let i = jsReadU32(bc, pc + 1)
                        push(try templateObject(code, i)); pc += 5
                    case .newClass:
                        let co = consts[jsReadU32(bc, pc + 1)]
                        try newClass(co, hasHeritage: bc[pc + 5] != 0)
                        pc += 6
                    case .setHomeObject:
                        heap.setSlot(stack[sp - 2], 2, stack[sp - 1])
                        sp -= 1; pc += 1
                    case .setFieldInit:
                        let fi = stack[sp - 1]
                        heap.setSlot(fi, 2, stack[sp - 2])
                        heap.setSlot(stack[sp - 3], 3, fi)
                        sp -= 1; pc += 1
                    // Arithmetic.
                    case .add:
                        let a = stack[sp - 2], b = stack[sp - 1]
                        if a.isInt32 && b.isInt32 {
                            let (r, o) = a.asInt32.addingReportingOverflow(b.asInt32)
                            stack[sp - 2] = o ? .double(Double(a.asInt32) + Double(b.asInt32)) : .int32(r)
                        } else if a.isNumber && b.isNumber {
                            stack[sp - 2] = .number(a.numberValue + b.numberValue)
                        } else {
                            stack[sp - 2] = try addSlow(a, b)
                        }
                        sp -= 1; pc += 1
                    case .sub:
                        let a = stack[sp - 2], b = stack[sp - 1]
                        if a.isInt32 && b.isInt32 {
                            let (r, o) = a.asInt32.subtractingReportingOverflow(b.asInt32)
                            stack[sp - 2] = o ? .double(Double(a.asInt32) - Double(b.asInt32)) : .int32(r)
                        } else if a.isNumber && b.isNumber {
                            stack[sp - 2] = .number(a.numberValue - b.numberValue)
                        } else {
                            stack[sp - 2] = try numericOp(.sub, a, b)
                        }
                        sp -= 1; pc += 1
                    case .mul, .div, .mod, .exp:
                        let a = stack[sp - 2], b = stack[sp - 1]
                        if a.isNumber && b.isNumber {
                            let x = a.numberValue, y = b.numberValue
                            let r: Double
                            switch op {
                            case .mul: r = x * y
                            case .div: r = x / y
                            case .mod: r = jsFmod(x, y)
                            default: r = jsPowNumber(x, y)
                            }
                            stack[sp - 2] = .number(r)
                        } else {
                            stack[sp - 2] = try numericOp(op, a, b)
                        }
                        sp -= 1; pc += 1
                    case .shl, .sar, .shr, .bitAnd, .bitOr, .bitXor:
                        let a = stack[sp - 2], b = stack[sp - 1]
                        let r: JSValue
                        if a.isInt32 && b.isInt32 {
                            let x = a.asInt32, y = b.asInt32
                            switch op {
                            case .shl: r = .int32(x << (y & 31))
                            case .sar: r = .int32(x >> (y & 31))
                            case .shr: r = .number(Double(UInt32(bitPattern: x) >> UInt32(y & 31)))
                            case .bitAnd: r = .int32(x & y)
                            case .bitOr: r = .int32(x | y)
                            default: r = .int32(x ^ y)
                            }
                        } else {
                            r = try numericOp(op, a, b)
                        }
                        stack[sp - 2] = r
                        sp -= 1; pc += 1
                    case .lt, .gt, .le, .ge:
                        let a = stack[sp - 2], b = stack[sp - 1]
                        let r: Bool
                        if a.isInt32 && b.isInt32 {
                            let x = a.asInt32, y = b.asInt32
                            switch op {
                            case .lt: r = x < y
                            case .gt: r = x > y
                            case .le: r = x <= y
                            default: r = x >= y
                            }
                        } else {
                            r = try compareOp(op, a, b)
                        }
                        stack[sp - 2] = .bool(r)
                        sp -= 1; pc += 1
                    case .eq, .ne:
                        let r = try looseEquals(stack[sp - 2], stack[sp - 1])
                        stack[sp - 2] = .bool(op == .eq ? r : !r)
                        sp -= 1; pc += 1
                    case .strictEq, .strictNe:
                        let a = stack[sp - 2], b = stack[sp - 1]
                        let r = a.bits == b.bits ? !a.isDouble || !a.asDouble.isNaN : heap.strictEquals(a, b)
                        stack[sp - 2] = .bool(op == .strictEq ? r : !r)
                        sp -= 1; pc += 1
                    case .instanceOf:
                        let r = try instanceOf(stack[sp - 2], stack[sp - 1])
                        sp -= 1; stack[sp - 1] = .bool(r); pc += 1
                    case .inOp:
                        let o = stack[sp - 1]
                        guard o.isObject else { throw throwTypeError("Cannot use 'in' operator to search for a key in " + describeForError(o)) }
                        let k = try toPropertyKey(stack[sp - 2])
                        sp -= 1; stack[sp - 1] = .bool(try objHas(o, k)); pc += 1
                    case .neg:
                        let a = stack[sp - 1]
                        if a.isInt32 && a.asInt32 != 0 && a.asInt32 != Int32.min { stack[sp - 1] = .int32(-a.asInt32) }
                        else if a.isNumber { stack[sp - 1] = .number(-a.numberValue) }
                        else { stack[sp - 1] = try numericUnary(.neg, a) }
                        pc += 1
                    case .plus:
                        let a = stack[sp - 1]
                        if !a.isNumber { stack[sp - 1] = .number(try toNumber(a)) }
                        pc += 1
                    case .toNumeric:
                        let a = stack[sp - 1]
                        if !a.isNumber { stack[sp - 1] = try toNumeric(a) }
                        pc += 1
                    case .not:
                        stack[sp - 1] = .bool(!heap.toBoolean(stack[sp - 1])); pc += 1
                    case .bitNot:
                        let a = stack[sp - 1]
                        stack[sp - 1] = a.isInt32 ? .int32(~a.asInt32) : try numericUnary(.bitNot, a); pc += 1
                    case .typeOf:
                        stack[sp - 1] = heap.typeOf(stack[sp - 1]); pc += 1
                    case .inc, .dec:
                        let a = stack[sp - 1]
                        if a.isInt32 {
                            let (r, o) = op == .inc ? a.asInt32.addingReportingOverflow(1) : a.asInt32.subtractingReportingOverflow(1)
                            stack[sp - 1] = o ? .double(Double(a.asInt32) + (op == .inc ? 1 : -1)) : .int32(r)
                        } else if a.isNumber {
                            let x = a.numberValue
                            stack[sp - 1] = .number(op == .inc ? x + 1 : x - 1)
                        } else {
                            stack[sp - 1] = try numericUnary(op, a)
                        }
                        pc += 1
                    case .toStringOp:
                        let a = stack[sp - 1]
                        if !a.isString { stack[sp - 1] = try toStringValue(a) }
                        pc += 1
                    case .toPropertyKey:
                        let a = stack[sp - 1]
                        if a.isObject { stack[sp - 1] = try toPrimitive(a, hint: .string) }
                        pc += 1
                    // Control.
                    case .jump:
                        let off = jsReadI32(bc, pc + 1)
                        pc += 5 + off
                        if off < 0 {
                            budget -= 1
                            if budget <= 0 { try checkInterrupt() }
                        }
                    case .jumpIfTrue, .jumpIfFalse:
                        sp -= 1
                        let v = stack[sp]
                        let b = v.isBool ? v.boolValue : heap.toBoolean(v)
                        let off = jsReadI32(bc, pc + 1)
                        pc += 5
                        if b == (op == .jumpIfTrue) {
                            pc += off
                            if off < 0 {
                                budget -= 1
                                if budget <= 0 { try checkInterrupt() }
                            }
                        }
                    case .jumpIfTrueKeep, .jumpIfFalseKeep:
                        let b = heap.toBoolean(stack[sp - 1])
                        let off = jsReadI32(bc, pc + 1)
                        pc += 5
                        if b == (op == .jumpIfTrueKeep) { pc += off }
                    case .jumpIfNotNullishKeep:
                        let off = jsReadI32(bc, pc + 1)
                        pc += 5
                        if !stack[sp - 1].isNullish { pc += off }
                    case .jumpIfUndefinedKeep:
                        let off = jsReadI32(bc, pc + 1)
                        pc += 5
                        if stack[sp - 1].isUndefined { pc += off }
                    case .jumpIfNullish:
                        let off = jsReadI32(bc, pc + 1)
                        let pos = Int(bc[pc + 5]), n = Int(bc[pc + 6])
                        pc += 7
                        if sp - 1 - pos >= base && stack[sp - 1 - pos].isNullish {
                            sp -= n
                            pc += off
                        }
                    case .call, .construct:
                        let argc = jsReadU16(bc, pc + 1)
                        pc += 3
                        frames[t].pc = pc
                        let pushed = op == .call ? try dispatchCall(argc, mode: JSFrameMode.normal) : try dispatchConstruct(argc)
                        if pushed {
                            t = frames.count - 1; code = frames[t].code; bc = UnsafePointer(code.code); consts = UnsafePointer(code.constPtr); keys = UnsafePointer(code.keyPtr)
                            pc = frames[t].pc; base = frames[t].base
                        }
                    case .callArray, .constructArray, .superCallArray:
                        pc += 1
                        frames[t].pc = pc
                        let argc = try spreadArgs()
                        var pushed: Bool
                        if op == .callArray {
                            pushed = try dispatchCall(argc, mode: JSFrameMode.normal)
                        } else {
                            if op == .superCallArray { try prepareSuperCall(argc) }
                            pushed = try dispatchConstruct(argc)
                        }
                        if pushed {
                            t = frames.count - 1; code = frames[t].code; bc = UnsafePointer(code.code); consts = UnsafePointer(code.constPtr); keys = UnsafePointer(code.keyPtr)
                            pc = frames[t].pc; base = frames[t].base
                        }
                    case .superCall:
                        let argc = jsReadU16(bc, pc + 1)
                        pc += 3
                        frames[t].pc = pc
                        try prepareSuperCall(argc)
                        if try dispatchConstruct(argc) {
                            t = frames.count - 1; code = frames[t].code; bc = UnsafePointer(code.code); consts = UnsafePointer(code.constPtr); keys = UnsafePointer(code.keyPtr)
                            pc = frames[t].pc; base = frames[t].base
                        }
                    case .directEval:
                        // Bit 15 of the count: the call is in a parameter list.
                        let raw = jsReadU16(bc, pc + 1)
                        pc += 3
                        frames[t].pc = pc
                        if try directEval(raw & 0x7FFF, strict: code.strict, inParams: raw & 0x8000 != 0) {
                            t = frames.count - 1; code = frames[t].code; bc = UnsafePointer(code.code); consts = UnsafePointer(code.constPtr); keys = UnsafePointer(code.keyPtr)
                            pc = frames[t].pc; base = frames[t].base
                        }
                    case .ret, .retUndefined, .retDerived:
                        var r: JSValue = .undefined
                        if op == .ret { r = pop() }
                        else if op == .retDerived {
                            let th = pop()
                            let v = pop()
                            if v.isObject { r = v }
                            else if !v.isUndefined { throw throwTypeError("Derived constructors may only return object or undefined") }
                            else if th.isHole { throw throwReferenceError("Must call super constructor in derived class before accessing 'this' or returning from derived constructor") }
                            else { r = th }
                        }
                        if frames[t].gen.isObject { r = try genReturned(frames[t].gen, r) }
                        let f = frames.removeLast()
                        sp = f.base - 2
                        env = f.callerEnv
                        if f.mode == JSFrameMode.construct && !r.isObject { r = f.this }
                        if f.entry { return r }
                        pushResult(r, f.mode)
                        t = frames.count - 1; code = frames[t].code; bc = UnsafePointer(code.code); consts = UnsafePointer(code.constPtr); keys = UnsafePointer(code.keyPtr); pc = frames[t].pc; base = frames[t].base
                    case .throwOp:
                        exception = pop()
                        throw JSThrow()
                    case .throwError:
                        let kind = JSErrorKind(rawValue: bc[pc + 1]) ?? .error
                        let m = consts[jsReadU32(bc, pc + 2)]
                        exception = makeErrorObject(kind, message: m, proto: .undefined)
                        throw JSThrow()
                    // Iteration.
                    case .forInStart:
                        stack[sp - 1] = try forInIterator(stack[sp - 1]); pc += 1
                    case .forInNext:
                        let off = jsReadI32(bc, pc + 1)
                        pc += 5
                        let k = forInNextKey(stack[sp - 1])
                        if k.isUndefined { pc += off } else { push(k) }
                    case .getIterator:
                        let (it, next) = try getIterator(stack[sp - 1])
                        stack[sp - 1] = it
                        push(next); pc += 1
                    case .iterNext:
                        let off = jsReadI32(bc, pc + 1)
                        pc += 5
                        let (done, v) = try iteratorStep(stack[sp - 2], stack[sp - 1])
                        if done { pc += off } else { push(v) }
                    case .iterStepValue:
                        if stack[sp - 1].isNull {
                            push(.undefined)
                        } else {
                            // The record is done (null) while next() runs: if
                            // it throws, the iterator is not closed.
                            let next = stack[sp - 1]
                            let nr = heap.root(next)
                            stack[sp - 1] = .null
                            let (done, v) = try iteratorStep(stack[sp - 2], next)
                            heap.popRoots(to: nr.slot)
                            if !done { stack[sp - 1] = next }
                            push(done ? .undefined : v)
                        }
                        pc += 1
                    case .iterRest:
                        let a = heap.newArray(proto: arrayPrototype)
                        push(a)
                        if !stack[sp - 2].isNull {
                            let next = stack[sp - 2]
                            let nr = heap.root(next)
                            stack[sp - 2] = .null
                            while true {
                                let (done, v) = try iteratorStep(stack[sp - 3], next)
                                if done { break }
                                _ = heap.createDataProperty(a, .index(heap.arrayLength(a)), v)
                                if heap.termination != nil { throw JSThrow() }
                            }
                            heap.popRoots(to: nr.slot)
                        }
                        pc += 1
                    case .iterClose:
                        try iteratorClose(stack[sp - 2], stack[sp - 1])
                        sp -= 2; pc += 1
                    case .iterCloseThrow:
                        let exc = stack[sp - 1]
                        if heap.termination == nil {
                            do throws(JSThrow) { try iteratorClose(stack[sp - 3], stack[sp - 2]) } catch {
                                if heap.termination != nil { throw JSThrow() }
                            }
                        }
                        sp -= 3
                        exception = exc
                        throw JSThrow()
                    // Function state.
                    case .loadThis:
                        var v = frames[t].this
                        if !code.strict && code.kind != .script && code.kind != .eval {
                            if v.isNullish { v = global } else if !v.isObject && !v.isHole { v = try toObject(v) }
                        }
                        push(v); pc += 1
                    case .loadGlobalThis:
                        push(global); pc += 1
                    case .loadNewTarget:
                        push(frames[t].newTarget); pc += 1
                    case .loadCallee:
                        push(frames[t].callee); pc += 1
                    case .loadHomeObject:
                        push(frames[t].home); pc += 1
                    case .runFieldInit:
                        pc += 1
                        let fi = heap.slot(stack[sp - 1], 3)
                        if heap.isCallable(fi) {
                            // [this f] -> [fi this], result dropped.
                            stack[sp - 1] = stack[sp - 2]
                            stack[sp - 2] = fi
                            frames[t].pc = pc
                            if try dispatchCall(0, mode: JSFrameMode.discard) {
                                t = frames.count - 1; code = frames[t].code; bc = UnsafePointer(code.code); consts = UnsafePointer(code.constPtr); keys = UnsafePointer(code.keyPtr)
                                pc = frames[t].pc; base = frames[t].base
                            }
                        } else {
                            sp -= 2
                        }
                    case .finallyDispatch:
                        let n = jsReadU16(bc, pc + 1)
                        let end = pc + 3 + 4 * n
                        let kind = stack[sp - 1]
                        sp -= 1
                        let k = kind.isInt32 ? Int(kind.asInt32) : 0
                        if k == 0 {
                            sp -= 1
                            pc = end
                        } else if k == 1 {
                            exception = pop()
                            throw JSThrow()
                        } else if k - 2 < n {
                            pc = end + jsReadI32(bc, pc + 3 + 4 * (k - 2))
                        } else {
                            sp -= 1
                            pc = end
                        }
                    case .checkThisInit:
                        if !stack[sp - 1].isHole { throw throwReferenceError("Super constructor may only be called once") }
                        sp -= 1; pc += 1
                    case .checkObjectCoercible:
                        let v = stack[sp - 1]
                        if v.isNullish { throw throwTypeError("Cannot destructure '" + safeToString(v) + "' as it is " + (v.isNull ? "null." : "undefined.")) }
                        pc += 1
                    // Phase 9E: generators and async functions (jsgenerator.swift).
                    case .generatorStart:
                        pc += 1
                        let kind = code.genKind
                        if kind == JSGenKind.asyncFunction || kind == JSGenKind.module {
                            if !frames[t].gen.isObject {
                                let g = newGenObject(kind: kind, proto: .null)
                                frames[t].gen = g
                                let p = newPromise()
                                heap.setSlot(g, 3, p)
                            }
                            break
                        }
                        var proto = try getV(frames[t].callee, heap.names.prototype)
                        if !proto.isObject {
                            proto = intrinsic(kind == JSGenKind.asyncGenerator ? .asyncGeneratorPrototype : .generatorPrototype)
                        }
                        let g = newGenObject(kind: kind, proto: proto)
                        frames[t].gen = g
                        if kind == JSGenKind.asyncGenerator {
                            let q = heap.newObject(proto: .null, kind: .internalObject)
                            heap.setSlot(g, 3, q)
                        }
                        saveFrame(g, frames[t], pc: pc)
                        setGenState(g, JSGenState.suspendedStart)
                        let f = frames.removeLast()
                        sp = f.base - 2
                        env = f.callerEnv
                        if f.entry { return g }
                        pushResult(g, f.mode)
                        t = frames.count - 1; code = frames[t].code; bc = UnsafePointer(code.code); consts = UnsafePointer(code.constPtr); keys = UnsafePointer(code.keyPtr); pc = frames[t].pc; base = frames[t].base
                    case .yield_, .yieldRaw:
                        pc += 1
                        if op == .yield_ { stack[sp - 1] = try iterResult(stack[sp - 1], done: false) }
                        let r = pop()
                        let g = frames[t].gen
                        guard g.isObject else { throw throwSyntaxError("yield outside a generator") }
                        saveFrame(g, frames[t], pc: pc)
                        setGenState(g, JSGenState.suspendedYield)
                        let f = frames.removeLast()
                        sp = f.base - 2
                        env = f.callerEnv
                        if f.entry { return r }
                        pushResult(r, f.mode)
                        t = frames.count - 1; code = frames[t].code; bc = UnsafePointer(code.code); consts = UnsafePointer(code.constPtr); keys = UnsafePointer(code.keyPtr); pc = frames[t].pc; base = frames[t].base
                    case .asyncGenYield:
                        pc += 1
                        let g = frames[t].gen
                        guard g.isObject else { throw throwSyntaxError("yield outside a generator") }
                        try asyncGenCompleteStep(g, ok: true, stack[sp - 1], done: false)
                        let q = asyncGenQueue(g)
                        if heap.slotCount(q) >= 3 {
                            // A queued request resumes at once.
                            stack[sp - 1] = heap.slot(q, 1)
                            push(heap.slot(q, 0))
                            break
                        }
                        sp -= 1
                        saveFrame(g, frames[t], pc: pc)
                        setGenState(g, JSGenState.suspendedYield)
                        let f = frames.removeLast()
                        sp = f.base - 2
                        env = f.callerEnv
                        if f.entry { return JSValue.undefined }
                        pushResult(JSValue.undefined, f.mode)
                        t = frames.count - 1; code = frames[t].code; bc = UnsafePointer(code.code); consts = UnsafePointer(code.constPtr); keys = UnsafePointer(code.keyPtr); pc = frames[t].pc; base = frames[t].base
                    case .await_:
                        pc += 1
                        let g = frames[t].gen
                        guard g.isObject else { throw throwSyntaxError("await is only valid in async functions") }
                        let p = try promiseResolve(stack[sp - 1])
                        stack[sp - 1] = p
                        performPromiseThen(p, g, .undefined, JSCapability(promise: .undefined, resolve: .undefined, reject: .undefined), type: 1)
                        sp -= 1
                        saveFrame(g, frames[t], pc: pc)
                        let r: JSValue = genKind(g) == JSGenKind.asyncGenerator ? .undefined : heap.slot(g, 3)
                        let f = frames.removeLast()
                        sp = f.base - 2
                        env = f.callerEnv
                        if f.entry { return r }
                        pushResult(r, f.mode)
                        t = frames.count - 1; code = frames[t].code; bc = UnsafePointer(code.code); consts = UnsafePointer(code.constPtr); keys = UnsafePointer(code.keyPtr); pc = frames[t].pc; base = frames[t].base
                    case .checkResume:
                        let off = jsReadI32(bc, pc + 1)
                        pc += 5
                        let m = stack[sp - 1]
                        sp -= 1
                        if m == .int32(1) { exception = pop(); throw JSThrow() }
                        if m == .int32(2) { pc += off }
                    case .resumeIsReturn:
                        let off = jsReadI32(bc, pc + 1)
                        pc += 5
                        if stack[sp - 1] == .int32(2) { sp -= 1; pc += off }
                    case .yieldStarCall:
                        // [it next received mode] -> [it next mode result]
                        let off = jsReadI32(bc, pc + 1)
                        pc += 5
                        let mv = stack[sp - 1]
                        let m: Int32 = mv.isInt32 ? mv.asInt32 : 0
                        let it = stack[sp - 4], next = stack[sp - 3]
                        if m == 0 && next.isHole {
                            let (d, v) = try iteratorStep(it, next)
                            sp -= 2
                            push(.int32(0))
                            push(try iterResult(v, done: d))
                            break
                        }
                        var fn = next
                        if m != 0 {
                            fn = try getV(it, heap.key(m == 1 ? "throw" : "return"))
                            if fn.isNullish {
                                if m == 2 { sp -= 1; pc += off; break }
                                try iteratorClose(stack[sp - 4], stack[sp - 3])
                                throw throwTypeError("The iterator does not provide a 'throw' method")
                            }
                        }
                        let recv = stack[sp - 2]
                        sp -= 2
                        try ensureStack(6)
                        push(.int32(m)); push(fn); push(stack[sp - 4]); push(recv)
                        frames[t].pc = pc
                        if try dispatchCall(1, mode: JSFrameMode.normal) {
                            t = frames.count - 1; code = frames[t].code; bc = UnsafePointer(code.code); consts = UnsafePointer(code.constPtr); keys = UnsafePointer(code.keyPtr); pc = frames[t].pc; base = frames[t].base
                        }
                    case .yieldStarResult:
                        // [it next mode result] -> [it next result] or, when
                        // done, [it next value] at the done / return target.
                        let offDone = jsReadI32(bc, pc + 1), offRet = jsReadI32(bc, pc + 5)
                        pc += 9
                        let res = stack[sp - 1]
                        guard res.isObject else { throw throwTypeError("Iterator result " + describeForError(res) + " is not an object") }
                        if heap.toBoolean(try getV(res, heap.names.done)) {
                            let v = try getV(stack[sp - 1], heap.names.value)
                            let wasReturn = stack[sp - 2] == .int32(2)
                            sp -= 2
                            push(v)
                            pc += wasReturn ? offRet : offDone
                        } else {
                            stack[sp - 2] = stack[sp - 1]
                            sp -= 1
                        }
                    case .getAsyncIterator:
                        let (it, next) = try getAsyncIterator(stack[sp - 1])
                        stack[sp - 1] = it
                        push(next); pc += 1
                    case .asyncIterResult:
                        let off = jsReadI32(bc, pc + 1)
                        pc += 5
                        let res = stack[sp - 1]
                        guard res.isObject else { throw throwTypeError("Iterator result " + describeForError(res) + " is not an object") }
                        if heap.toBoolean(try getV(res, heap.names.done)) {
                            sp -= 1
                            pc += off
                        } else {
                            stack[sp - 1] = try getV(stack[sp - 1], heap.names.value)
                        }
                    case .asyncReturnCall:
                        // [it next] -> [result of it.return(), or hole]
                        let ignore = bc[pc + 1] != 0
                        pc += 2
                        var r: JSValue = .hole
                        do throws(JSThrow) {
                            let f = try getV(stack[sp - 2], heap.key("return"))
                            if !f.isNullish { r = try call(f, this: stack[sp - 2], args: []) }
                        } catch {
                            if !ignore || heap.termination != nil { throw error }
                            _ = takeException()
                            r = .hole
                        }
                        sp -= 2
                        push(r)
                    case .checkObject:
                        if !stack[sp - 1].isObject { throw throwTypeError("Iterator result " + describeForError(stack[sp - 1]) + " is not an object") }
                        pc += 1
                    case .dup3:
                        let a = stack[sp - 3], b = stack[sp - 2], c = stack[sp - 1]
                        push(a); push(b); push(c); pc += 1
                    case .getterThisSwap:
                        pc += 1
                    // Phase 9E: private names (jsvm_private.swift).
                    case .newPrivateName:
                        let d = consts[jsReadU32(bc, pc + 1)]
                        let kind = Int64(bc[pc + 5])
                        pc += 6
                        push(newPrivateRecord(d, kind: kind))
                    case .getPrivate:
                        // [obj rec] -> [value]; a getter runs as a frame.
                        pc += 1
                        switch try privateGet(stack[sp - 2], stack[sp - 1]) {
                        case .value(let v):
                            sp -= 1; stack[sp - 1] = v
                        case .getter(let g):
                            let o = stack[sp - 2]
                            stack[sp - 2] = g; stack[sp - 1] = o
                            frames[t].pc = pc
                            if try dispatchCall(0, mode: JSFrameMode.normal) {
                                t = frames.count - 1; code = frames[t].code; bc = UnsafePointer(code.code); consts = UnsafePointer(code.constPtr); keys = UnsafePointer(code.keyPtr); pc = frames[t].pc; base = frames[t].base
                            }
                        case .exotic:
                            // Private elements are raw own slots: never exotic.
                            throw throwTypeError("invalid private access")
                        }
                    case .putPrivate:
                        // [obj rec v] -> [v]; a setter runs as a frame.
                        pc += 1
                        if let st = try privateSet(stack[sp - 3], stack[sp - 2], stack[sp - 1]) {
                            let o = stack[sp - 3], v = stack[sp - 1]
                            try ensureStack(2)
                            stack[sp - 3] = v; stack[sp - 2] = st; stack[sp - 1] = o
                            push(v)
                            frames[t].pc = pc
                            if try dispatchCall(1, mode: JSFrameMode.discard) {
                                t = frames.count - 1; code = frames[t].code; bc = UnsafePointer(code.code); consts = UnsafePointer(code.constPtr); keys = UnsafePointer(code.keyPtr); pc = frames[t].pc; base = frames[t].base
                            }
                        } else {
                            stack[sp - 3] = stack[sp - 1]
                            sp -= 2
                        }
                    case .definePrivate:
                        try privateDefine(stack[sp - 3], stack[sp - 2], stack[sp - 1])
                        sp -= 3; pc += 1
                    case .hasPrivate:
                        let r = try privateHas(stack[sp - 1], stack[sp - 2])
                        sp -= 1; stack[sp - 1] = .bool(r); pc += 1
                    case .addPrivateBrand:
                        try privateAddBrand(stack[sp - 2], stack[sp - 1])
                        sp -= 1; pc += 1
                    case .setPrivateMethod:
                        let w = bc[pc + 1]
                        heap.setSlot(stack[sp - 2], w == 2 ? 2 : 1, stack[sp - 1])
                        sp -= 2; pc += 2
                    case .objectRestDynamic:
                        // [src excludedKeysArray] -> [rest]
                        pc += 1
                        let o = heap.newObject(proto: objectPrototype)
                        push(o)
                        try copyDataPropertiesExcludingArray(into: o, from: stack[sp - 3], keys: stack[sp - 2])
                        sp -= 2; stack[sp - 1] = o
                    case .directEvalArray:
                        pc += 3
                        frames[t].pc = pc
                        let argc = try spreadArgs()
                        if try directEval(argc, strict: code.strict) {
                            t = frames.count - 1; code = frames[t].code; bc = UnsafePointer(code.code); consts = UnsafePointer(code.constPtr); keys = UnsafePointer(code.keyPtr); pc = frames[t].pc; base = frames[t].base
                        }
                    // Phase 9E: modules (jsmodule.swift).
                    case .getModuleBinding:
                        let v = stack[sp - 1]
                        if v.isObject && heap.kind(v) == .internalObject && heap.flags(v).contains(.user2) {
                            let x = heap.slot(heap.slot(v, 0), Int(heap.internalInt(v)))
                            if x.isHole { throw tdzError(code, jsReadU32(bc, pc + 1)) }
                            stack[sp - 1] = x
                        } else if v.isHole {
                            throw tdzError(code, jsReadU32(bc, pc + 1))
                        }
                        pc += 5
                    case .dynamicImport:
                        pc += 1
                        stack[sp - 1] = try dynamicImport(stack[sp - 1], referrer: code.source?.name ?? "")
                    case .importMeta:
                        throw throwSyntaxError("import.meta outside a module")
                    case .mapArg:
                        mapArgument(stack[sp - 1], index: jsReadU32(bc, pc + 1), envSlot: jsReadU32(bc, pc + 5))
                        pc += 9
                    }
                }
            } catch {
                // Unwind to a handler or out of this execute().
                var p = opPC
                while true {
                    t = frames.count - 1
                    let f = frames[t]
                    if heap.termination == nil, let h = findHandler(f.code, p) {
                        sp = f.base + f.code.nlocals + Int(h.depth)
                        push(exception)
                        exception = .undefined
                        trace = []
                        code = f.code; bc = UnsafePointer(code.code); consts = UnsafePointer(code.constPtr); keys = UnsafePointer(code.keyPtr)
                        pc = Int(h.target); base = f.base
                        break
                    }
                    if heap.termination == nil && trace.count < 32 && !(exception.isObject && heap.kind(exception) == .error) {
                        let nm = heap.swiftString(f.code.name)
                        let isTop = f.code.kind == .script || f.code.kind == .eval
                        trace.append(JSTraceEntry(name: isTop ? "" : (nm.isEmpty ? "<anonymous>" : nm),
                                                  location: f.code.location(at: p)))
                    }
                    frames.removeLast()
                    sp = f.base - 2
                    env = f.callerEnv
                    if f.gen.isObject && heap.termination == nil, let r = try genThrewOut(f.gen) {
                        // An async frame: the exception rejected its promise.
                        if f.entry { return r }
                        pushResult(r, f.mode)
                        t = frames.count - 1; code = frames[t].code; bc = UnsafePointer(code.code); consts = UnsafePointer(code.constPtr); keys = UnsafePointer(code.keyPtr); pc = frames[t].pc; base = frames[t].base
                        break
                    }
                    if f.entry { throw JSThrow() }
                    p = max(0, frames[frames.count - 1].pc - 1)
                }
            }
        }
    }

    func findHandler(_ code: JSCode, _ pc: Int) -> JSHandler? {
        let p = UInt32(truncatingIfNeeded: pc)
        for h in code.handlers where p >= h.start && p < h.end { return h }
        return nil
    }

    @inline(__always) func envAt(_ hops: Int) -> JSValue {
        var e = env
        var i = 0
        while i < hops { e = heap.slot(e, 0); i += 1 }
        return e
    }

    func tdzError(_ code: JSCode, _ keyIndex: Int) -> JSThrow {
        let k = keyIndex < code.keys.count ? code.keys[keyIndex] : heap.names.undefined
        return throwReferenceError("Cannot access '" + keyDisplay(k) + "' before initialization")
    }
}
