// JSRuntime and script evaluation (ROADMAP Phase 9B, embedding API).
//
//   JSRuntime(limits:)          engine-wide settings, shared by its realms
//     .limits                   copied into each new realm's heap
//     .interruptHandler         called at the VM's interrupt checks (every
//                               limits.interruptInterval backward jumps or
//                               calls); return true to terminate the script
//                               (uncatchable, finally blocks don't run)
//     .makeRealm() -> JSRealm   a fresh realm (own heap, globals, built-ins)
//
//   realm.evaluate(source:name:) -> JSCompletion   run a classic script
//     (global code; var/function declarations become global properties,
//     let/const/class go to the global lexical scope shared by every script
//     in the realm). Parse errors and early errors are .exception with a
//     SyntaxError. A termination unwinds everything and is reported as
//     .terminated(reason); the flag is then cleared so the realm can run
//     again (the heap may terminate again at once if it is still full).
//   realm.call(f, this:, args:) throws(JSThrow) -> JSValue   call any
//     callable from Swift (the native re-entry path, nesting-capped).
//   realm.construct(f, args:, newTarget:) throws(JSThrow) -> JSValue
//   realm.uncaught() -> JSUncaughtException   describe the pending
//     exception after a JSThrow (message + stack strings).

public final class JSRuntime {
    public var limits: JSLimits
    public var interruptHandler: ((JSRealm) -> Bool)? = nil

    public init(limits: JSLimits = JSLimits()) {
        self.limits = limits
    }

    public func makeRealm() -> JSRealm { JSRealm(runtime: self) }
}

extension JSRealm {
    public func evaluate(source: String, name: String = "<script>") -> JSCompletion {
        evaluate(source: Array(source.utf8), name: name)
    }

    public func evaluate(source: [UInt8], name: String = "<script>") -> JSCompletion {
        let outer = nativeDepth == 0 && frames.isEmpty
        if outer { stackFloor = jsVMStackFloor(limits) }
        let depth = heap.rootDepth
        defer { heap.popRoots(to: depth) }
        let closure: JSValue
        do throws(JSThrow) {
            closure = try compileScriptClosure(source, name: name, eval: false, strict: false)
        } catch {
            return finishCompletion(outer: outer)
        }
        do throws(JSThrow) {
            let v = try call(closure, this: global, args: [])
            if outer && heap.termination == .interrupted { heap.clearTermination() }
            return .normal(v)
        } catch {
            return finishCompletion(outer: outer)
        }
    }

    func finishCompletion(outer: Bool) -> JSCompletion {
        if let t = heap.termination {
            if outer {
                heap.clearTermination()
                resetVM()
            }
            return .terminated(t)
        }
        let u = uncaught()
        exception = .undefined
        trace = []
        return .exception(u)
    }

    /// After a termination: drop every frame and value.
    func resetVM() {
        frames = []
        sp = 0
        env = .undefined
        exception = .undefined
        trace = []
        nativeDepth = 0
    }

    /// Parse and compile; a syntax error becomes a pending SyntaxError.
    func compileScriptClosure(_ source: [UInt8], name: String, eval: Bool, strict: Bool,
                              env: JSValue = .undefined) throws(JSThrow) -> JSValue {
        let ast: JSAST
        do throws(JSSyntaxError) {
            ast = try jsParse(source, JSParseOptions(module: false, strict: strict, limits: limits))
        } catch {
            exception = makeError(.syntaxError, error.message)
            trace = [JSTraceEntry(name: "", location: name + ":" + String(error.line) + ":" + String(error.column))]
            throw JSThrow()
        }
        scriptCount += 1
        let src = JSScriptSource(name: name, source: source)
        let depth = heap.rootDepth
        let code: JSCode
        do throws(JSCompileError) {
            code = eval ? try JSCompiler.compileEval(ast, realm: self, source: src, strict: strict)
                        : try JSCompiler.compileScript(ast, realm: self, source: src)
        } catch {
            heap.popRoots(to: depth)
            exception = makeError(.syntaxError, error.message)
            let (l, c) = src.lineMap.location(error.offset)
            trace = [JSTraceEntry(name: "", location: name + ":" + String(l) + ":" + String(c))]
            throw JSThrow()
        }
        _ = heap.root(code.codeObject)
        let f = makeClosure(code, env: env)
        heap.popRoots(to: depth)
        _ = heap.root(f)
        return f
    }

    /// The pending exception as strings (does not clear it).
    public func uncaught() -> JSUncaughtException {
        let v = exception
        let r = heap.root(v)
        defer { heap.popRoots(to: r.slot) }
        let message = safeToString(v)
        var stack = message
        if v.isObject, case .value(let s) = heap.getProperty(v, heap.names.stack), s.isString {
            stack = heap.swiftString(s)
        } else {
            for t in trace {
                stack += "\n    at " + (t.name.isEmpty ? t.location : t.name + " (" + t.location + ")")
            }
        }
        if v.isObject, heap.kind(v) == .error, !trace.isEmpty, !stack.contains("\n") {
            for t in trace {
                stack += "\n    at " + (t.name.isEmpty ? t.location : t.name + " (" + t.location + ")")
            }
        }
        return JSUncaughtException(value: v, message: message, stack: stack)
    }

    /// ToString that never throws (for reporting): errors as "Name: msg".
    public func safeToString(_ v: JSValue) -> String {
        if v.isObject && heap.kind(v) == .error {
            var name = "Error", msg = ""
            if case .value(let n) = heap.getProperty(v, heap.names.name), n.isString { name = heap.swiftString(n) }
            if case .value(let m) = heap.getProperty(v, heap.names.message), m.isString { msg = heap.swiftString(m) }
            return msg.isEmpty ? name : name + ": " + msg
        }
        if v.isSymbol {
            let d = heap.symbolDescription(v)
            return "Symbol(" + (d.isString ? heap.swiftString(d) : "") + ")"
        }
        if let s = heap.toPrimitiveString(v) { return heap.swiftString(s) }
        let saved = exception
        let savedTrace = trace
        defer { exception = saved; trace = savedTrace }
        if heap.termination != nil { return "[object]" }
        do throws(JSThrow) {
            let s = try toStringValue(v)
            return heap.swiftString(s)
        } catch {
            return "[object]"
        }
    }

    /// Evaluate and render the completion as text (tests and the shell):
    /// the value's ToString, "Uncaught <message>", or "terminated".
    public func evaluateToString(_ source: String, name: String = "<script>") -> String {
        switch evaluate(source: source, name: name) {
        case .normal(let v): return safeToString(v)
        case .exception(let e): return "Uncaught " + e.message
        case .terminated(let r):
            switch r {
            case .heapLimit: return "terminated: heap limit"
            case .interrupted: return "terminated: interrupted"
            case .regexSteps: return "terminated: regex steps"
            }
        }
    }
}

/// Stack floor for native re-entry from here (the VM throws a RangeError
/// instead of recursing past it).
func jsVMStackFloor(_ limits: JSLimits) -> UInt {
    let here = jsStackAddress()
    let budget = UInt(max(32 << 10, limits.maxParseStackBytes / 2 + (64 << 10)))
    return here > budget ? here - budget : 0
}
