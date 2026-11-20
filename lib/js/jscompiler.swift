// The bytecode compiler (ROADMAP Phase 9B): JSAST + JSScopeAnalysis ->
// JSCode (jsbytecode.swift documents the format). This file has the
// emitter infrastructure, functions and statements; jscompiler_expr.swift
// has expressions, references, destructuring and classes.
//
//   JSCompiler.compileScript(ast, realm:, source:) throws(JSCompileError) -> JSCode
//   JSCompiler.compileEval(ast, realm:, source:, strict:) throws(JSCompileError) -> JSCode
//
// Every heap value the compiler makes (atoms, scope infos, code objects)
// is rooted on the heap's root stack until the compile returns; the
// caller keeps the returned code's codeObject alive (a closure or root).
//
// Stack depth is tracked statically (see jsbytecode.swift); any mismatch
// is a JSCompileError("internal compiler error ..."), never bad bytecode.
// Recursion follows the AST except along left spines (binary chains,
// member/call chains), which are walked iteratively; the rest is bounded
// by a stack guard like the parser's (JSLimits.maxParseStackBytes from the
// compile's entry), so deep input is a SyntaxError, never a crash.
//
// Syntax the runtime does not support yet compiles to code that throws
// "not supported yet: ..." where it runs (generators and async functions
// when called, private class members, BigInt literals, modules, ...).

struct JSCompileError: Error {
    var message: String
    var offset: Int
}

/// A jump target. Fixups are (operand position, end of instruction).
struct JSCodeLabel {
    var pc = -1
    var depth = -1
    var fixups: [(Int, Int)] = []
}

enum JSControlKind { case loop, switch_, label, env, finally_, forOf }

enum JSExitMode { case break_, continue_, return_ }

struct JSControl {
    var kind: JSControlKind
    var labels: [Int32] = []
    var breakLabel = -1
    var continueLabel = -1
    var breakDepth = 0
    var continueDepth = 0
    /// forOf: depth with the iterator pair on the stack; finally: try depth.
    var depth = 0
    var finallyLabel = -1
    var exits: [(target: Int, mode: JSExitMode)] = []
    /// A labeled statement's own label set is consumed by the next loop.
    var isLoop: Bool { kind == .loop || kind == .forOf }
}

final class JSFuncState {
    let code = JSCode()
    var depth = 0
    var maxDepth = 0
    var nlocals = 0
    var scope: Int32 = 0
    var fnScope: Int32 = 0
    var labels: [JSCodeLabel] = []
    var controls: [JSControl] = []
    var numberConsts: [UInt64: Int] = [:]
    var valueConsts: [UInt64: Int] = [:]
    var keyIndex: [UInt64: Int] = [:]
    var freeTemps: [Int] = []
    var completionLocal = -1
    var returnLocal = -1
    var hasBlockEnvs = false
    var lastPos: UInt32 = UInt32.max
    var pos: UInt32 = 0
    /// Labels on the statement being compiled (for the loop they label).
    var pendingLabels: [Int32] = []
    /// Optional-chain short-circuit labels.
    var optLabels: [Int] = []
    var isDerivedCtor = false
    var isClassCtor = false
}

final class JSCompiler {
    let ast: JSAST
    let sa: JSScopeAnalysis
    unowned(unsafe) let realm: JSRealm
    let heap: JSHeap
    let source: JSScriptSource
    var stackFloor: UInt = 0
    var fs = JSFuncState()
    var fsStack: [JSFuncState] = []
    var atoms: [Int32: JSValue] = [:]
    var scopeInfos: [Int32: JSValue] = [:]

    init(ast: JSAST, analysis: JSScopeAnalysis, realm: JSRealm, source: JSScriptSource) {
        self.ast = ast
        self.sa = analysis
        self.realm = realm
        self.heap = realm.heap
        self.source = source
        let here = jsStackAddress()
        let budget = UInt(max(32 << 10, realm.limits.maxParseStackBytes))
        stackFloor = here > budget ? here - budget : 0
    }

    // MARK: Entry points

    static func compileScript(_ ast: JSAST, realm: JSRealm, source: JSScriptSource) throws(JSCompileError) -> JSCode {
        let sa = JSScopeAnalysis(ast: ast)
        sa.run(evalCode: false, strict: false)
        let c = JSCompiler(ast: ast, analysis: sa, realm: realm, source: source)
        return try c.compileTop(eval: false)
    }

    static func compileEval(_ ast: JSAST, realm: JSRealm, source: JSScriptSource, strict: Bool) throws(JSCompileError) -> JSCode {
        let sa = JSScopeAnalysis(ast: ast)
        sa.run(evalCode: true, strict: strict)
        let c = JSCompiler(ast: ast, analysis: sa, realm: realm, source: source)
        return try c.compileTop(eval: true)
    }

    // MARK: Errors and guards

    func fail(_ msg: String, _ n: Int32 = -1) -> JSCompileError {
        JSCompileError(message: msg, offset: n >= 0 && Int(n) < ast.nodes.count ? Int(ast[n].start) : 0)
    }

    func internalError(_ what: String) -> JSCompileError {
        JSCompileError(message: "internal compiler error: " + what, offset: Int(fs.pos))
    }

    @inline(__always) func guardStack(_ n: Int32) throws(JSCompileError) {
        if jsStackAddress() < stackFloor { throw fail("nesting too deep", n) }
    }

    // MARK: Emission

    @inline(__always) func adjust(_ d: Int) throws(JSCompileError) {
        fs.depth += d
        if fs.depth < 0 { throw internalError("stack underflow") }
        if fs.depth > fs.maxDepth { fs.maxDepth = fs.depth }
    }

    func markPos() {
        if fs.pos != fs.lastPos {
            fs.code.lines.append(JSLineEntry(pc: UInt32(fs.code.bytes.count), offset: fs.pos))
            fs.lastPos = fs.pos
        }
    }

    func setPos(_ n: Int32) { if n >= 0 { fs.pos = ast[n].start } }

    /// Emit an operand-less instruction with a stack effect.
    func emit(_ op: JSOp, _ effect: Int) throws(JSCompileError) {
        markPos()
        fs.code.bytes.append(op.rawValue)
        try adjust(effect)
    }

    func emitU8(_ op: JSOp, _ a: UInt8, _ effect: Int) throws(JSCompileError) {
        try emit(op, effect)
        fs.code.bytes.append(a)
    }

    func emitU16(_ op: JSOp, _ a: Int, _ effect: Int) throws(JSCompileError) {
        guard a >= 0 && a <= 0xFFFF else { throw fail("too many arguments") }
        try emit(op, effect)
        put16(a)
    }

    func emitU32(_ op: JSOp, _ a: Int, _ effect: Int) throws(JSCompileError) {
        try emit(op, effect)
        put32(a)
    }

    func put16(_ v: Int) {
        fs.code.bytes.append(UInt8(truncatingIfNeeded: v))
        fs.code.bytes.append(UInt8(truncatingIfNeeded: v >> 8))
    }

    func put32(_ v: Int) {
        let u = UInt32(truncatingIfNeeded: v)
        fs.code.bytes.append(UInt8(truncatingIfNeeded: u))
        fs.code.bytes.append(UInt8(truncatingIfNeeded: u >> 8))
        fs.code.bytes.append(UInt8(truncatingIfNeeded: u >> 16))
        fs.code.bytes.append(UInt8(truncatingIfNeeded: u >> 24))
    }

    func patch32(_ at: Int, _ v: Int) {
        let u = UInt32(truncatingIfNeeded: v)
        fs.code.bytes[at] = UInt8(truncatingIfNeeded: u)
        fs.code.bytes[at + 1] = UInt8(truncatingIfNeeded: u >> 8)
        fs.code.bytes[at + 2] = UInt8(truncatingIfNeeded: u >> 16)
        fs.code.bytes[at + 3] = UInt8(truncatingIfNeeded: u >> 24)
    }

    func pushInt(_ v: Int32) throws(JSCompileError) {
        try emit(.pushInt, 1)
        put32(Int(v))
    }

    func popN(_ n: Int) throws(JSCompileError) {
        if n <= 0 { return }
        if n == 1 { try emit(.pop, -1); return }
        try emitU32(.popN, n, -n)
    }

    func newLabel() -> Int {
        fs.labels.append(JSCodeLabel())
        return fs.labels.count - 1
    }

    /// Record that `label` is reached with the current depth.
    func noteTarget(_ label: Int, depth: Int) throws(JSCompileError) {
        if fs.labels[label].depth < 0 { fs.labels[label].depth = depth }
        else if fs.labels[label].depth != depth {
            throw internalError("label depth \(fs.labels[label].depth) vs \(depth)")
        }
    }

    /// A jump-family instruction to label; `targetEffect` is the stack
    /// effect on the jumping path, `effect` on the fall-through path.
    func emitJump(_ op: JSOp, _ label: Int, effect: Int = 0, targetEffect: Int? = nil) throws(JSCompileError) {
        markPos()
        fs.code.bytes.append(op.rawValue)
        let at = fs.code.bytes.count
        put32(0)
        let end = fs.code.bytes.count
        let tdepth = fs.depth + (targetEffect ?? effect)
        if tdepth < 0 { throw internalError("jump underflow") }
        try noteTarget(label, depth: tdepth)
        if fs.labels[label].pc >= 0 { patch32(at, fs.labels[label].pc - end) }
        else { fs.labels[label].fixups.append((at, end)) }
        try adjust(effect)
    }

    func jumpIfNullish(_ label: Int, pos: Int, pop: Int) throws(JSCompileError) {
        markPos()
        fs.code.bytes.append(JSOp.jumpIfNullish.rawValue)
        let at = fs.code.bytes.count
        put32(0)
        fs.code.bytes.append(UInt8(pos))
        fs.code.bytes.append(UInt8(pop))
        let end = fs.code.bytes.count
        try noteTarget(label, depth: fs.depth - pop)
        if fs.labels[label].pc >= 0 { patch32(at, fs.labels[label].pc - end) }
        else { fs.labels[label].fixups.append((at, end)) }
    }

    /// Place a label here. After an unconditional transfer (`dead`), the
    /// depth comes from the label.
    func place(_ label: Int, dead: Bool = false) throws(JSCompileError) {
        let pc = fs.code.bytes.count
        if dead {
            if fs.labels[label].depth >= 0 { fs.depth = fs.labels[label].depth }
            else { fs.labels[label].depth = fs.depth }
        } else {
            try noteTarget(label, depth: fs.depth)
        }
        fs.labels[label].pc = pc
        for (at, end) in fs.labels[label].fixups { patch32(at, pc - end) }
        fs.labels[label].fixups = []
        fs.lastPos = UInt32.max
    }

    func newLocal() -> Int {
        let i = fs.nlocals
        fs.nlocals += 1
        return i
    }

    func tempLocal() -> Int { fs.freeTemps.popLast() ?? newLocal() }
    func freeTemp(_ i: Int) { fs.freeTemps.append(i) }

    // MARK: Constants

    /// The heap atom for a pool string (rooted for the compile).
    func atom(_ id: Int32) -> JSValue {
        if let v = atoms[id] { return v }
        let units = Array(ast.str(id))
        let v = heap.intern(heap.newString(utf16: units))
        _ = heap.root(v)
        atoms[id] = v
        return v
    }

    func atomValue(_ s: String) -> JSValue {
        let v = heap.atom(s)
        _ = heap.root(v)
        return v
    }

    func addConst(_ v: JSValue) -> Int {
        if v.isNumber || v.isString {
            let k = v.isString ? (UInt64(1) << 63) | UInt64(v.handle) : v.bits
            if let i = fs.valueConsts[k] { return i }
            fs.code.constants.append(v)
            fs.valueConsts[k] = fs.code.constants.count - 1
            return fs.code.constants.count - 1
        }
        fs.code.constants.append(v)
        return fs.code.constants.count - 1
    }

    func addKey(_ k: JSPropertyKey) -> Int {
        if let i = fs.keyIndex[k.bits] { return i }
        fs.code.keys.append(k)
        fs.keyIndex[k.bits] = fs.code.keys.count - 1
        return fs.code.keys.count - 1
    }

    /// Key index for a pool string.
    func key(_ id: Int32) -> Int {
        let v = atom(id)
        return addKey(heap.propertyKey(v) ?? .atom(v.handle))
    }

    func keyNamed(_ s: String) -> Int {
        let v = atomValue(s)
        return addKey(heap.propertyKey(v) ?? .atom(v.handle))
    }

    func pushNumber(_ d: Double) throws(JSCompileError) {
        let v = JSValue.number(d)
        if v.isInt32 { try pushInt(v.asInt32); return }
        try emitU32(.pushConst, addConst(v), 1)
    }

    func pushString(_ id: Int32) throws(JSCompileError) {
        try emitU32(.pushConst, addConst(atom(id)), 1)
    }

    func throwError(_ kind: JSErrorKind, _ msg: String) throws(JSCompileError) {
        let m = atomValue(msg)
        try emit(.throwError, 0)
        fs.code.bytes.append(kind.rawValue)
        put32(addConst(m))
    }

    func notSupported(_ what: String) throws(JSCompileError) {
        try throwError(.syntaxError, "not supported yet: " + what)
    }

    // MARK: Scopes

    /// The scope info object for a scope with an environment.
    func scopeInfo(_ s: Int32) -> JSValue {
        if let v = scopeInfos[s] { return v }
        let sc = sa.scopes[Int(s)]
        let info = heap.newObject(proto: .null, kind: .internalObject, flags: [.extensible])
        _ = heap.root(info)
        var template = [JSValue](repeating: .undefined, count: max(0, Int(sc.envCount) - 2))
        for b in sc.bindings {
            let bd = sa.bindings[Int(b)]
            guard bd.inEnv && bd.slot >= 2 else { continue }
            let t = Int(bd.slot) - 2
            if t < template.count && (bd.isLexical || bd.kind == .this_ && isDerivedScope(s)) { template[t] = .hole }
            if bd.name >= 0 {
                var v = bd.slot
                if bd.isConst { v |= JSScopeSlot.constFlag }
                if bd.isLexical { v |= JSScopeSlot.lexicalFlag }
                let a = atom(bd.name)
                _ = heap.defineOwnProperty(info, heap.propertyKey(a) ?? .atom(a.handle),
                                           .data(.int32(v), [.writable]))
            }
        }
        heap.setSlots(info, template)
        var flags: Int64 = 0
        if sc.isFunctionLike && !(sc.kind == .eval && !sc.strict) { flags |= 1 }
        heap.setInternalInt(info, flags)
        scopeInfos[s] = info
        return info
    }

    func isDerivedScope(_ s: Int32) -> Bool {
        let sc = sa.scopes[Int(s)]
        return sc.kind == .function && sc.funcKind == .derivedConstructor
    }

    /// Enter a scope: locals for its stack bindings, its environment, TDZ.
    func enterScope(_ s: Int32) throws(JSCompileError) {
        fs.scope = s
        let sc = sa.scopes[Int(s)]
        for b in sc.bindings {
            let bd = sa.bindings[Int(b)]
            if bd.inEnv || bd.slot >= 0 || sc.kind == .script { continue }
            if bd.name < 0 && !bd.used { continue }
            sa.bindings[Int(b)].slot = Int32(newLocal())
        }
        if sc.hasEnv {
            try emitU32(.pushEnv, addConst(scopeInfo(s)), 0)
            fs.controls.append(JSControl(kind: .env))
        }
        for b in sc.bindings {
            let bd = sa.bindings[Int(b)]
            if !bd.inEnv && bd.slot >= 0 && bd.isLexical && bd.needsTDZ && sc.kind != .script {
                try emit(.pushHole, 1)
                try emitU32(.putLocal, Int(bd.slot), -1)
            }
        }
    }

    func exitScope(_ s: Int32) throws(JSCompileError) {
        let sc = sa.scopes[Int(s)]
        if sc.hasEnv {
            try emit(.popEnv, 0)
            fs.controls.removeLast()
        }
        fs.scope = sc.parent
    }

    /// Environments between the current scope and `target` (exclusive).
    func hops(to target: Int32) throws(JSCompileError) -> Int {
        var n = 0
        var s = fs.scope
        while s != target {
            if s < 0 { throw internalError("scope not on chain") }
            if sa.scopes[Int(s)].hasEnv { n += 1 }
            s = sa.scopes[Int(s)].parent
        }
        return n
    }

    // MARK: Bindings

    func bindingKeyName(_ b: Int32) -> Int {
        let bd = sa.bindings[Int(b)]
        if bd.name >= 0 { return key(bd.name) }
        return keyNamed(bd.kind == .this_ ? "this" : "new.target")
    }

    func needsCheck(_ b: Int32) -> Bool {
        let bd = sa.bindings[Int(b)]
        if bd.kind == .this_ { return isDerivedScope(bd.scope) }
        return bd.isLexical && bd.needsTDZ
    }

    func emitGetBinding(_ b: Int32, checked: Bool? = nil) throws(JSCompileError) {
        let bd = sa.bindings[Int(b)]
        let check = checked ?? needsCheck(b)
        if bd.inEnv {
            let h = try hops(to: bd.scope)
            guard h <= 0xFFFF else { throw fail("nesting too deep") }
            try emit(check ? .getEnvChecked : .getEnv, 1)
            put16(h); put32(Int(bd.slot))
            if check { put32(bindingKeyName(b)) }
        } else {
            guard bd.slot >= 0 else { throw internalError("binding without slot") }
            if check {
                try emit(.getLocalChecked, 1)
                put32(Int(bd.slot)); put32(bindingKeyName(b))
            } else {
                try emitU32(.getLocal, Int(bd.slot), 1)
            }
        }
    }

    /// Store the top of stack into a binding (consumes it). `initialize`:
    /// a declaration's initialization (no TDZ or const check).
    func emitPutBinding(_ b: Int32, initialize: Bool) throws(JSCompileError) {
        let bd = sa.bindings[Int(b)]
        if !initialize {
            if bd.isConst {
                if bd.needsTDZ { try emitGetBinding(b); try emit(.pop, -1) }
                try throwError(.typeError, "Assignment to constant variable.")
                try adjust(-1)
                return
            }
            if bd.kind == .calleeName {
                if sa.scopes[Int(bd.scope)].strict {
                    try throwError(.typeError, "Assignment to constant variable.")
                    try adjust(-1)
                } else {
                    try emit(.pop, -1)
                }
                return
            }
        }
        let check = !initialize && bd.isLexical && bd.needsTDZ
        if bd.inEnv {
            let h = try hops(to: bd.scope)
            guard h <= 0xFFFF else { throw fail("nesting too deep") }
            try emit(check ? .putEnvChecked : .putEnv, -1)
            put16(h); put32(Int(bd.slot))
            if check { put32(bindingKeyName(b)) }
        } else {
            guard bd.slot >= 0 else { throw internalError("binding without slot") }
            if check {
                try emit(.putLocalChecked, -1)
                put32(Int(bd.slot)); put32(bindingKeyName(b))
            } else {
                try emitU32(.putLocal, Int(bd.slot), -1)
            }
        }
    }

    /// The binding for a pseudo name visible from the current scope.
    func pseudoBinding(_ name: Int32) -> Int32 {
        var s = fs.scope
        while s >= 0 {
            if let b = sa.scopes[Int(s)].names[name] { return b }
            s = sa.scopes[Int(s)].parent
        }
        return -1
    }

    /// Push `this` as seen from the current scope.
    func emitThis() throws(JSCompileError) {
        let b = pseudoBinding(JSPseudoName.this_)
        if b < 0 { try emit(.loadGlobalThis, 1); return }
        if sa.bindings[Int(b)].slot < 0 && !sa.bindings[Int(b)].inEnv {
            try emit(.loadThis, 1)   // unused binding never materialized
            return
        }
        try emitGetBinding(b)
    }

    func emitPseudo(_ name: Int32) throws(JSCompileError) {
        let b = pseudoBinding(name)
        if b < 0 || (sa.bindings[Int(b)].slot < 0 && !sa.bindings[Int(b)].inEnv) {
            try emit(.pushUndefined, 1)
            return
        }
        try emitGetBinding(b, checked: false)
    }

    // MARK: Top level

    func compileTop(eval: Bool) throws(JSCompileError) -> JSCode {
        let root = ast.root
        if ast.isModule { throw fail("not supported yet: modules") }
        let top: Int32 = 0
        fs = JSFuncState()
        fs.code.kind = eval ? .eval : .script
        fs.code.strict = sa.scopes[0].strict
        fs.code.source = source
        fs.code.sourceStart = 0
        fs.code.sourceEnd = UInt32(truncatingIfNeeded: ast.source.count)
        fs.fnScope = top
        fs.scope = top
        computeBlockEnvs(top)
        fs.completionLocal = newLocal()
        let rn = ast[root]
        let stmts = ast.list(rn.a, rn.b)
        if eval {
            try enterScope(top)
            try emitPseudoPrologue(top)
            if !sa.scopes[0].strict {
                for b in sa.scopes[0].bindings {
                    let bd = sa.bindings[Int(b)]
                    if (bd.kind == .var_) && bd.name >= 0 { try emitU32(.declareVar, key(bd.name), 0) }
                }
            }
        } else {
            try emitGlobalDeclarations()
        }
        try hoistFunctions(stmts, scope: top)
        for s in stmts { try emitStatement(s) }
        try emitU32(.getLocal, fs.completionLocal, 1)
        try emit(.ret, -1)
        return try finishFunction(name: .string(0), nameHint: nil)
    }

    func computeBlockEnvs(_ fnScope: Int32) {
        fs.hasBlockEnvs = false
        for (i, s) in sa.scopes.enumerated() where s.fn == fnScope && Int32(i) != fnScope && s.hasEnv {
            fs.hasBlockEnvs = true
            break
        }
    }

    /// Script-level declarations: lexical first (conflict checks), then
    /// vars, then functions (bound by hoistFunctions).
    func emitGlobalDeclarations() throws(JSCompileError) {
        let sc = sa.scopes[0]
        for b in sc.bindings {
            let bd = sa.bindings[Int(b)]
            guard bd.name >= 0 else { continue }
            if bd.isLexical {
                try emit(.declareLex, 0)
                put32(key(bd.name))
                fs.code.bytes.append(bd.isConst ? 1 : 0)
            }
        }
        for b in sc.bindings {
            let bd = sa.bindings[Int(b)]
            guard bd.name >= 0 else { continue }
            if bd.kind == .var_ { try emitU32(.declareVar, key(bd.name), 0) }
        }
    }

    /// Prologue for the pseudo bindings of a function-like scope.
    func emitPseudoPrologue(_ s: Int32) throws(JSCompileError) {
        let sc = sa.scopes[Int(s)]
        for b in sc.bindings {
            let bd = sa.bindings[Int(b)]
            guard bd.slot >= 0 || bd.inEnv else { continue }
            switch bd.kind {
            case .this_:
                if sc.kind == .function && sc.funcKind == .derivedConstructor {
                    try emit(.pushHole, 1)
                } else {
                    try emit(.loadThis, 1)
                }
            case .newTarget: try emit(.loadNewTarget, 1)
            case .home: try emit(.loadHomeObject, 1)
            case .funcObj, .calleeName: try emit(.loadCallee, 1)
            default: continue
            }
            try emitPutBinding(b, initialize: true)
        }
    }

    /// Function declarations at the top of a statement list (scope entry).
    func hoistFunctions(_ stmts: ArraySlice<Int32>, scope: Int32) throws(JSCompileError) {
        let sc = sa.scopes[Int(scope)]
        for s in stmts {
            let n = ast[s]
            guard n.kind == .function, n.a >= 0,
                  n.flags & JSNodeFlags.declaration != 0, n.flags & JSNodeFlags.expression == 0 else { continue }
            setPos(s)
            let code = try compileFunction(s, name: atom(ast[n.a].a))
            try emitU32(.closure, addConst(code.codeObject), 1)
            let name = ast[n.a].a
            if sc.kind == .script || (sc.kind == .eval && !sc.strict) {
                try emitU32(.declareFunc, key(name), -1)
            } else {
                guard let b = sc.names[name] else { throw internalError("function binding") }
                try emitPutBinding(b, initialize: true)
            }
        }
    }

    // MARK: Functions

    /// Compile a function node into a new JSCode (with its code object).
    func compileFunction(_ n: Int32, name: JSValue) throws(JSCompileError) -> JSCode {
        try guardStack(n)
        let node = ast[n]
        let fkind = JSFunctionKind(rawValue: node.op) ?? .normal
        if sa.stubs.contains(n) {
            let what = node.flags & JSNodeFlags.generator != 0 ? "generator functions" : "async functions"
            return try stubFunction(n, name: name, what: what)
        }
        guard let fscope = sa.nodeScope[n] else { throw internalError("function scope") }
        fsStack.append(fs)
        fs = JSFuncState()
        defer { fs = fsStack.removeLast() }
        let code = fs.code
        code.source = source
        code.sourceStart = node.start
        code.sourceEnd = node.end
        code.strict = node.flags & JSNodeFlags.strict != 0
        switch fkind {
        case .normal: code.kind = .function; code.hasPrototype = true; code.isConstructor = true
        case .arrow: code.kind = .arrow
        case .method: code.kind = .method
        case .getter: code.kind = .getter
        case .setter: code.kind = .setter
        case .classConstructor: code.kind = .classConstructor; code.isConstructor = true
        case .derivedConstructor: code.kind = .derivedConstructor; code.isConstructor = true
        }
        fs.isDerivedCtor = fkind == .derivedConstructor
        fs.isClassCtor = fkind == .classConstructor || fkind == .derivedConstructor
        fs.fnScope = fscope
        fs.scope = fscope
        computeBlockEnvs(fscope)
        // Parameters arrive in locals 0..<nparams.
        let params = ast.list(node.b, node.c)
        var simple: [Int32: Int] = [:]
        var np = 0
        var length = -1
        var hasRest = false
        for (i, p) in params.enumerated() {
            let pk = ast.kind(p)
            if pk == .rest { hasRest = true; break }
            if pk == .assignPattern && length < 0 { length = i }
            np += 1
        }
        code.nparams = np
        code.length = length < 0 ? np : length
        fs.nlocals = np
        if hasRest {
            code.restLocal = newLocal()
        }
        // Simple parameters bind their own local (the last duplicate wins).
        let fsc = sa.scopes[Int(fscope)]
        for (i, p) in params.enumerated() where i < np && ast.kind(p) == .identifier {
            if let b = fsc.names[ast[p].a] { simple[b] = i }
        }
        for (b, i) in simple where !sa.bindings[Int(b)].inEnv { sa.bindings[Int(b)].slot = Int32(i) }
        // The arguments object.
        var argsBinding: Int32 = -1
        if let b = fsc.names[JSWord.arguments] {
            let k = sa.bindings[Int(b)].kind
            if k == .arguments || sa.bindings[Int(b)].isArgumentsVar { argsBinding = b }
        }
        try enterScope(fscope)
        if argsBinding >= 0 {
            let bd = sa.bindings[Int(argsBinding)]
            if bd.inEnv {
                let t = newLocal()
                code.argumentsLocal = t
                try emitU32(.getLocal, t, 1)
                try emitPutBinding(argsBinding, initialize: true)
            } else {
                code.argumentsLocal = Int(bd.slot)
            }
        }
        try emitPseudoPrologue(fscope)
        // Captured simple parameters move to the environment.
        for (b, i) in simple where sa.bindings[Int(b)].inEnv {
            try emitU32(.getLocal, i, 1)
            try emitPutBinding(b, initialize: true)
        }
        // Patterns, defaults and the rest parameter.
        for (i, p) in params.enumerated() {
            let pk = ast.kind(p)
            if pk == .identifier { continue }
            setPos(p)
            if pk == .rest {
                try emitU32(.getLocal, code.restLocal, 1)
                try emitBindingInit(ast[p].a, mode: .initialize)
            } else {
                try emitU32(.getLocal, i, 1)
                try emitBindingInit(p, mode: .initialize)
            }
        }
        if fkind == .classConstructor {
            try emitThis()
            try emit(.loadCallee, 1)
            try emit(.runFieldInit, -2)
        }
        // Body.
        let body = node.d
        if node.flags & JSNodeFlags.exprBody != 0 || ast.kind(body) != .functionBody {
            setPos(body)
            try emitExpr(body)
            try emitReturn(fromValue: true)
        } else {
            let stmts = ast.list(ast[body].a, ast[body].b)
            try hoistFunctions(stmts, scope: fscope)
            for s in stmts { try emitStatement(s) }
            fs.pos = node.end > 0 ? node.end - 1 : 0
            try emitReturn(fromValue: false)
        }
        return try finishFunction(name: name, nameHint: nil)
    }

    func stubFunction(_ n: Int32, name: JSValue, what: String) throws(JSCompileError) -> JSCode {
        fsStack.append(fs)
        fs = JSFuncState()
        defer { fs = fsStack.removeLast() }
        let node = ast[n]
        fs.code.source = source
        fs.code.sourceStart = node.start
        fs.code.sourceEnd = node.end
        fs.code.stub = what
        fs.code.kind = (JSFunctionKind(rawValue: node.op) ?? .normal) == .arrow ? .arrow : .function
        var np = 0
        for p in ast.list(node.b, node.c) {
            let k = ast.kind(p)
            if k == .rest || k == .assignPattern { break }
            np += 1
        }
        fs.code.length = np
        fs.pos = node.start
        try notSupported(what)
        return try finishFunction(name: name, nameHint: nil)
    }

    func finishFunction(name: JSValue, nameHint: JSValue?) throws(JSCompileError) -> JSCode {
        for l in fs.labels where !l.fixups.isEmpty { throw internalError("unplaced label") }
        let code = fs.code
        code.name = name.isString ? name : .string(0)
        code.nlocals = fs.nlocals
        code.maxStack = fs.maxDepth + 2
        code.finish()
        code.codeObject = realm.makeCodeObject(code)
        _ = heap.root(code.codeObject)
        return code
    }

    /// `return` (value on the stack when fromValue): through finally blocks
    /// and for-of iterator closes.
    func emitReturn(fromValue: Bool) throws(JSCompileError) {
        if !fromValue {
            if fs.isDerivedCtor {
                try emit(.pushUndefined, 1)
            } else {
                try emit(.retUndefined, 0)
                return
            }
        }
        var needsWalk = false
        for c in fs.controls where c.kind == .finally_ || c.kind == .forOf { needsWalk = true; break }
        if !needsWalk {
            try emitFinalReturn()
            return
        }
        if fs.returnLocal < 0 { fs.returnLocal = newLocal() }
        try emitU32(.putLocal, fs.returnLocal, -1)
        try emitJumpOut(target: -1, mode: .return_, from: fs.controls.count - 1)
    }

    /// The value is on the stack.
    func emitFinalReturn() throws(JSCompileError) {
        if fs.isDerivedCtor {
            let b = pseudoBinding(JSPseudoName.this_)
            if b >= 0 && (sa.bindings[Int(b)].inEnv || sa.bindings[Int(b)].slot >= 0) {
                try emitGetBinding(b, checked: false)
            } else {
                try emit(.pushHole, 1)
            }
            try emit(.retDerived, -2)
        } else {
            try emit(.ret, -1)
        }
    }

    /// Leave nested controls down to `target` (an index in fs.controls, -1
    /// for return), starting at control `from`. Routes through finally
    /// blocks; the code after this is unreachable.
    func emitJumpOut(target: Int, mode: JSExitMode, from: Int) throws(JSCompileError) {
        var j = from
        while j > target {
            let c = fs.controls[j]
            switch c.kind {
            case .env:
                try emit(.popEnv, 0)
            case .forOf:
                try popN(fs.depth - c.depth)
                try emit(.iterClose, -2)
            case .finally_:
                try popN(fs.depth - c.depth)
                if mode == .return_ { try emitU32(.getLocal, fs.returnLocal, 1) } else { try emit(.pushUndefined, 1) }
                fs.controls[j].exits.append((target, mode))
                try pushInt(Int32(fs.controls[j].exits.count + 1))
                try emitJump(.jump, c.finallyLabel)
                try adjust(-2)
                return
            default: break
            }
            j -= 1
        }
        if mode == .return_ {
            try emitU32(.getLocal, fs.returnLocal, 1)
            try emitFinalReturn()
            try adjust(1)   // dead code continues at the pre-return depth
            try adjust(-1)
            return
        }
        let c = fs.controls[target]
        let (label, depth) = mode == .break_ ? (c.breakLabel, c.breakDepth) : (c.continueLabel, c.continueDepth)
        let saved = fs.depth
        if c.kind == .forOf && mode == .break_ {
            try popN(fs.depth - c.depth)
            try emit(.iterClose, -2)
        }
        try popN(fs.depth - depth)
        try emitJump(.jump, label)
        fs.depth = saved
    }

    // MARK: Statements

    func emitStatements(_ stmts: ArraySlice<Int32>) throws(JSCompileError) {
        for s in stmts { try emitStatement(s) }
    }

    func emitStatement(_ n: Int32) throws(JSCompileError) {
        try guardStack(n)
        let node = ast[n]
        setPos(n)
        let startDepth = fs.depth
        switch node.kind {
        case .empty, .debugger:
            break
        case .exprStmt:
            try emitExpr(node.a)
            if fs.completionLocal >= 0 { try emitU32(.putLocal, fs.completionLocal, -1) }
            else { try emit(.pop, -1) }
        case .varDecl:
            try emitVarDecl(n)
        case .function:
            // Hoisted; Annex B copies a block function into its var binding.
            if let vb = sa.annexB[n], node.a >= 0, let bb = sa.scopes[Int(fs.scope)].names[ast[node.a].a] {
                try emitGetBinding(bb, checked: false)
                if sa.scopes[Int(sa.bindings[Int(vb)].scope)].kind == .script {
                    try emitU32(.putGlobal, key(ast[node.a].a), -1)
                } else if sa.bindings[Int(vb)].slot >= 0 || sa.bindings[Int(vb)].inEnv {
                    try emitPutBinding(vb, initialize: true)
                } else {
                    try emitU32(.putName, key(ast[node.a].a), -1)
                }
            }
        case .classNode:
            try emitClass(n, nameHint: nil)
            if node.a >= 0 { try emitDeclInit(node.a) } else { try emit(.pop, -1) }
        case .returnStmt:
            if node.a >= 0 {
                try emitExpr(node.a)
                try emitReturn(fromValue: true)
            } else {
                try emitReturn(fromValue: false)
            }
            fs.depth = startDepth
        case .ifStmt:
            let elseL = newLabel(), endL = newLabel()
            try emitCondition(node.a, falseLabel: elseL)
            try emitStatement(node.b)
            if node.c >= 0 {
                try emitJump(.jump, endL)
                try place(elseL, dead: true)
                try emitStatement(node.c)
                try place(endL)
            } else {
                try place(elseL)
                try place(endL)
            }
        case .block:
            try emitBlock(n)
        case .whileStmt:
            try emitWhile(n)
        case .doWhile:
            try emitDoWhile(n)
        case .forStmt:
            try emitFor(n)
        case .forIn:
            try emitForIn(n)
        case .forOf:
            if node.flags & JSNodeFlags.await != 0 { try notSupported("for await") }
            else { try emitForOf(n) }
        case .continueStmt, .breakStmt:
            try emitBreakContinue(n)
            fs.depth = startDepth
        case .throwStmt:
            try emitExpr(node.a)
            setPos(n)
            try emit(.throwOp, -1)
        case .tryStmt:
            try emitTry(n)
        case .switchStmt:
            try emitSwitch(n)
        case .labeled:
            try emitLabeled(n)
        case .withStmt:
            try emitExpr(node.a)
            guard let w = sa.nodeScope[n] else { throw internalError("with scope") }
            try emit(.enterWith, -1)
            fs.scope = w
            fs.controls.append(JSControl(kind: .env))
            try emitStatement(node.b)
            fs.controls.removeLast()
            try emit(.popEnv, 0)
            fs.scope = sa.scopes[Int(w)].parent
        case .importDecl, .exportNamed, .exportDefault, .exportAll:
            try notSupported("modules")
        default:
            // An expression in statement position (should not happen).
            try emitExpr(n)
            try emit(.pop, -1)
        }
        if fs.depth != startDepth { throw internalError("statement depth \(fs.depth) vs \(startDepth)") }
    }

    func emitBlock(_ n: Int32) throws(JSCompileError) {
        let node = ast[n]
        let stmts = ast.list(node.a, node.b)
        if let s = sa.nodeScope[n] {
            try enterScope(s)
            try hoistFunctions(stmts, scope: s)
            try emitStatements(stmts)
            try exitScope(s)
        } else {
            try emitStatements(stmts)
        }
    }

    func emitVarDecl(_ n: Int32) throws(JSCompileError) {
        let node = ast[n]
        let kind = JSVarKind(rawValue: node.op) ?? .var
        for d in ast.list(node.a, node.b) {
            let dn = ast[d]
            setPos(d)
            if dn.b < 0 {
                if kind == .var { continue }
                try emit(.pushUndefined, 1)
            } else {
                let hint: JSValue? = ast.kind(dn.a) == .identifier ? atom(ast[dn.a].a) : nil
                try emitExpr(dn.b, nameHint: hint)
            }
            try emitBindingInit(dn.a, mode: kind == .var ? .assignVar : .initialize)
        }
    }

    /// Initialize the declared identifier `idNode` from the stack.
    func emitDeclInit(_ idNode: Int32) throws(JSCompileError) {
        let r = sa.ref(idNode)
        try emitStoreRef(r, name: ast[idNode].a, initialize: true)
    }

    /// Jump to falseLabel when the expression is falsy (with && / || / !
    /// short circuits).
    func emitCondition(_ n: Int32, falseLabel: Int) throws(JSCompileError) {
        try emitExpr(n)
        try emitJump(.jumpIfFalse, falseLabel, effect: -1)
    }

    func takeLabels() -> [Int32] {
        let l = fs.pendingLabels
        fs.pendingLabels = []
        return l
    }

    func pushLoop(_ breakL: Int, _ contL: Int, labels: [Int32], kind: JSControlKind = .loop,
                  contDepth: Int? = nil) {
        var c = JSControl(kind: kind)
        c.labels = labels
        c.breakLabel = breakL
        c.continueLabel = contL
        c.breakDepth = fs.depth
        c.continueDepth = contDepth ?? fs.depth
        c.depth = contDepth ?? fs.depth
        fs.controls.append(c)
    }

    func emitWhile(_ n: Int32) throws(JSCompileError) {
        let node = ast[n]
        let labels = takeLabels()
        let top = newLabel(), brk = newLabel()
        try place(top)
        try emitCondition(node.a, falseLabel: brk)
        pushLoop(brk, top, labels: labels)
        try emitStatement(node.b)
        fs.controls.removeLast()
        try emitJump(.jump, top)
        try place(brk, dead: true)
    }

    func emitDoWhile(_ n: Int32) throws(JSCompileError) {
        let node = ast[n]
        let labels = takeLabels()
        let top = newLabel(), cont = newLabel(), brk = newLabel()
        try place(top)
        pushLoop(brk, cont, labels: labels)
        try emitStatement(node.a)
        fs.controls.removeLast()
        try place(cont)
        try emitExpr(node.b)
        try emitJump(.jumpIfTrue, top, effect: -1)
        try place(brk)
    }

    func emitFor(_ n: Int32) throws(JSCompileError) {
        let node = ast[n]
        let labels = takeLabels()
        let scope = sa.nodeScope[n]
        if let s = scope { try enterScope(s) }
        if node.a >= 0 {
            if ast.kind(node.a) == .varDecl { try emitVarDecl(node.a) }
            else { try emitExpr(node.a); try emit(.pop, -1) }
        }
        let top = newLabel(), cont = newLabel(), brk = newLabel()
        try place(top)
        if node.b >= 0 { try emitCondition(node.b, falseLabel: brk) }
        pushLoop(brk, cont, labels: labels)
        try emitStatement(node.d)
        fs.controls.removeLast()
        try place(cont)
        if let s = scope, sa.scopes[Int(s)].hasEnv { try emit(.cloneEnv, 0) }
        if node.c >= 0 { try emitExpr(node.c); try emit(.pop, -1) }
        try emitJump(.jump, top)
        try place(brk, dead: true)
        if let s = scope { try exitScope(s) }
    }

    /// Assign the value on the stack to a for-in/of left side.
    func emitForTarget(_ left: Int32) throws(JSCompileError) {
        if ast.kind(left) == .varDecl {
            let vd = ast[left]
            let kind = JSVarKind(rawValue: vd.op) ?? .var
            guard let d = ast.list(vd.a, vd.b).first else { throw internalError("for declaration") }
            try emitBindingInit(ast[d].a, mode: kind == .var ? .assignVar : .initialize)
        } else {
            try emitBindingInit(left, mode: .assign)
        }
    }

    func emitForIn(_ n: Int32) throws(JSCompileError) {
        let node = ast[n]
        let labels = takeLabels()
        // Annex B: for (var x = init in o)
        if ast.kind(node.a) == .varDecl, let d = ast.list(ast[node.a].a, ast[node.a].b).first, ast[d].b >= 0 {
            try emitExpr(ast[d].b)
            try emitBindingInit(ast[d].a, mode: .assignVar)
        }
        try emitExpr(node.b)
        try emit(.forInStart, 0)
        let cont = newLabel(), done = newLabel(), brk = newLabel()
        try place(cont)
        try emitJump(.forInNext, done, effect: 1, targetEffect: 0)
        let scope = sa.nodeScope[n]
        if let s = scope { try enterScope(s) }
        try emitForTarget(node.a)
        pushLoop(brk, cont, labels: labels, contDepth: fs.depth)
        fs.controls[fs.controls.count - 1].breakDepth = fs.depth - 1
        if let s = scope, sa.scopes[Int(s)].hasEnv {
            // The per-iteration env is popped before continuing.
            fs.controls[fs.controls.count - 1].continueLabel = newLabel()
            let c2 = fs.controls[fs.controls.count - 1].continueLabel
            try emitStatement(node.c)
            fs.controls.removeLast()
            try place(c2)
            try exitScope(s)
            try emitJump(.jump, cont)
        } else {
            try emitStatement(node.c)
            fs.controls.removeLast()
            if let s = scope { try exitScope(s) }
            try emitJump(.jump, cont)
        }
        try place(done, dead: true)
        try emit(.pop, -1)
        try place(brk)
    }

    func emitForOf(_ n: Int32) throws(JSCompileError) {
        let node = ast[n]
        let labels = takeLabels()
        try emitExpr(node.b)
        setPos(n)
        try emit(.getIterator, 1)
        let iterDepth = fs.depth
        let cont = newLabel(), done = newLabel(), brk = newLabel(), landing = newLabel()
        try place(cont)
        try emitJump(.iterNext, done, effect: 1, targetEffect: 0)
        let start = fs.code.bytes.count
        let scope = sa.nodeScope[n]
        if let s = scope { try enterScope(s) }
        try emitForTarget(node.a)
        var c = JSControl(kind: .forOf)
        c.labels = labels
        c.breakLabel = brk
        c.continueLabel = cont
        c.breakDepth = iterDepth - 2
        c.continueDepth = iterDepth
        c.depth = iterDepth
        if let s = scope, sa.scopes[Int(s)].hasEnv {
            // Remove the env control pushed by enterScope from under the
            // loop: continue pops it explicitly.
            c.continueLabel = newLabel()
            fs.controls.append(c)
            try emitStatement(node.c)
            fs.controls.removeLast()
            try place(c.continueLabel)
            try exitScope(s)
        } else {
            fs.controls.append(c)
            try emitStatement(node.c)
            fs.controls.removeLast()
            if let s = scope { try exitScope(s) }
        }
        let end = fs.code.bytes.count
        try emitJump(.jump, cont)
        // An exception in the body closes the iterator.
        fs.depth = iterDepth
        try place(landing, dead: true)
        fs.labels[landing].depth = iterDepth
        try adjust(1)
        try emit(.iterCloseThrow, -3)
        fs.code.handlers.append(JSHandler(start: UInt32(start), end: UInt32(end), target: UInt32(fs.labels[landing].pc),
                                          depth: UInt32(iterDepth)))
        try place(done, dead: true)
        try popN(2)
        try place(brk)
    }

    func emitBreakContinue(_ n: Int32) throws(JSCompileError) {
        let node = ast[n]
        let isBreak = node.kind == .breakStmt
        let label = node.a
        var target = -1
        var i = fs.controls.count - 1
        while i >= 0 {
            let c = fs.controls[i]
            if label >= 0 {
                if c.labels.contains(label) && (isBreak || c.isLoop) { target = i; break }
            } else if isBreak ? (c.isLoop || c.kind == .switch_) : c.isLoop {
                target = i
                break
            }
            i -= 1
        }
        guard target >= 0 else { throw fail("break or continue target not found", n) }
        try emitJumpOut(target: target, mode: isBreak ? .break_ : .continue_, from: fs.controls.count - 1)
    }

    func emitLabeled(_ n: Int32) throws(JSCompileError) {
        // Collect a chain of labels: `a: b: while (...)`.
        var labels: [Int32] = []
        var body = n
        while ast.kind(body) == .labeled {
            labels.append(ast[body].a)
            body = ast[body].b
        }
        switch ast.kind(body) {
        case .whileStmt, .doWhile, .forStmt, .forIn, .forOf:
            fs.pendingLabels = labels
            try emitStatement(body)
            fs.pendingLabels = []
        default:
            let brk = newLabel()
            var c = JSControl(kind: .label)
            c.labels = labels
            c.breakLabel = brk
            c.breakDepth = fs.depth
            fs.controls.append(c)
            try emitStatement(body)
            fs.controls.removeLast()
            try place(brk)
        }
    }

    func emitSwitch(_ n: Int32) throws(JSCompileError) {
        let node = ast[n]
        try emitExpr(node.a)
        let scope = sa.nodeScope[n]
        if let s = scope { try enterScope(s) }
        let cases = Array(ast.list(node.b, node.c))
        var caseLabels: [Int] = []
        var defaultIndex = -1
        for (i, c) in cases.enumerated() {
            let l = newLabel()
            caseLabels.append(l)
            let cn = ast[c]
            if cn.a < 0 { defaultIndex = i; continue }
            setPos(c)
            try emit(.dup, 1)
            try emitExpr(cn.a)
            try emit(.strictEq, -1)
            try emitJump(.jumpIfTrue, l, effect: -1)
        }
        let endL = newLabel(), brk = newLabel()
        try emitJump(.jump, defaultIndex >= 0 ? caseLabels[defaultIndex] : endL)
        var ctl = JSControl(kind: .switch_)
        ctl.breakLabel = brk
        ctl.breakDepth = fs.depth - 1
        fs.controls.append(ctl)
        if let s = scope {
            var all: [Int32] = []
            for c in cases { all.append(contentsOf: ast.list(ast[c].b, ast[c].c)) }
            try hoistFunctions(all[...], scope: s)
        }
        for (i, c) in cases.enumerated() {
            try place(caseLabels[i], dead: true)
            try emitStatements(ast.list(ast[c].b, ast[c].c))
        }
        fs.controls.removeLast()
        try place(endL)
        try emit(.pop, -1)
        try place(brk)
        if let s = scope { try exitScope(s) }
    }

    func emitTry(_ n: Int32) throws(JSCompileError) {
        let node = ast[n]
        let hasFinally = node.d >= 0
        let tryDepth = fs.depth
        var envSave = -1
        if fs.hasBlockEnvs {
            envSave = tempLocal()
            try emitU32(.saveEnv, envSave, 0)
        }
        var fin = -1
        let finallyStart = fs.code.bytes.count
        if hasFinally {
            fin = newLabel()
            var c = JSControl(kind: .finally_)
            c.depth = tryDepth
            c.finallyLabel = fin
            fs.controls.append(c)
        }
        let after = newLabel()
        // try block
        let start = fs.code.bytes.count
        try emitBlock(node.a)
        let end = fs.code.bytes.count
        if node.c >= 0 {
            try emitJump(.jump, after)
            // catch
            let landing = newLabel()
            fs.labels[landing].depth = tryDepth
            try place(landing, dead: true)
            fs.code.handlers.append(JSHandler(start: UInt32(start), end: UInt32(end),
                                              target: UInt32(fs.labels[landing].pc), depth: UInt32(tryDepth)))
            try adjust(1)
            if envSave >= 0 { try emitU32(.restoreEnv, envSave, 0) }
            guard let cs = sa.nodeScope[node.c] else { throw internalError("catch scope") }
            try enterScope(cs)
            if node.b >= 0 { try emitBindingInit(node.b, mode: .initialize) } else { try emit(.pop, -1) }
            let h = ast[node.c]
            let stmts = ast.list(h.a, h.b)
            try hoistFunctions(stmts, scope: cs)
            try emitStatements(stmts)
            try exitScope(cs)
        }
        try place(after)
        if hasFinally {
            let finEnd = fs.code.bytes.count
            var ctl = fs.controls.removeLast()
            // Normal completion.
            try emit(.pushUndefined, 1)
            try pushInt(0)
            try emitJump(.jump, fin)
            // Exception: (exc, 1).
            let landing = newLabel()
            fs.depth = tryDepth
            try place(landing, dead: true)
            fs.labels[landing].depth = tryDepth
            fs.code.handlers.append(JSHandler(start: UInt32(finallyStart), end: UInt32(finEnd),
                                              target: UInt32(fs.labels[landing].pc), depth: UInt32(tryDepth)))
            try adjust(1)
            if envSave >= 0 { try emitU32(.restoreEnv, envSave, 0) }
            try pushInt(1)
            try emitJump(.jump, fin)
            fs.depth = tryDepth + 2
            try place(fin, dead: true)
            try emitBlock(node.d)
            // Dispatch: kind 0 falls through, 1 rethrows, k >= 2 exits.
            ctl.exits = fs.controls.count >= 0 ? ctl.exits : []
            let exits = ctl.exits
            markPos()
            fs.code.bytes.append(JSOp.finallyDispatch.rawValue)
            put16(exits.count)
            var tableAt: [Int] = []
            for _ in exits { tableAt.append(fs.code.bytes.count); put32(0) }
            let tableEnd = fs.code.bytes.count
            var exitLabels: [Int] = []
            for at in tableAt {
                let l = newLabel()
                fs.labels[l].fixups.append((at, tableEnd))
                fs.labels[l].depth = tryDepth + 1
                exitLabels.append(l)
            }
            let fallDepth = tryDepth
            let done = newLabel()
            fs.depth = fallDepth
            try emitJump(.jump, done)
            for (i, e) in exits.enumerated() {
                try place(exitLabels[i], dead: true)
                if e.mode == .return_ {
                    if fs.returnLocal < 0 { fs.returnLocal = newLocal() }
                    try emitU32(.putLocal, fs.returnLocal, -1)
                } else {
                    try emit(.pop, -1)
                }
                try emitJumpOut(target: e.target, mode: e.mode, from: fs.controls.count - 1)
                fs.depth = tryDepth
            }
            try place(done, dead: true)
        }
        if envSave >= 0 { freeTemp(envSave) }
    }
}
