// Scope analysis for the compiler (ROADMAP Phase 9B): one iterative pass
// over a script's (or eval body's) AST builds the scope tree, declares
// every binding (var hoisting to the function scope, let/const/class in
// blocks, function declarations, parameters, catch parameters, the class
// and named-function-expression self names, and the pseudo bindings `this`,
// `new.target`, the home object and the active function), records every
// identifier reference, then resolves the references:
//
//   * a binding referenced from a nested function is `captured` and lives
//     in a heap environment; every other binding is a stack local;
//   * a function that contains `with` or direct `eval` (or encloses one)
//     is `allHeap`: all its bindings live in named heap environments so
//     dynamic lookups can find them;
//   * a reference that crosses a `with` scope, a function with a sloppy
//     direct eval (which may declare new vars) or the top of eval code is
//     `dynamic` (looked up by name at run time);
//   * an unresolved reference at script level is a global (looked up by
//     name on the global lexical record, then the global object).
//
// The walk is iterative (an explicit task stack), so tree height costs no
// Swift stack. Outputs (used by JSCompiler):
//   scopes[], bindings[]; nodeScope[node] for scope-making nodes (function,
//   block, for/for-in/for-of with lexical bindings, switch, catch handler
//   block, with, class); ref(node) for identifier / this / new.target
//   nodes; superRefs for `super` (home object, this, active function,
//   new.target); annexB[functionNode] = var binding to copy a sloppy block
//   function into.

enum JSScopeKind: UInt8 {
    case script, eval, function, block, catchClause, forLoop, switchBlock, classBody, with, fieldInit
    /// A module body (Phase 9E): every top-level binding lives in the
    /// module environment (jsmodule.swift).
    case module
}

enum JSBindingKind: UInt8 {
    case var_, let_, const_, class_, classInner, function, blockFunction, param, catchParam
    case calleeName, arguments, this_, newTarget, home, funcObj
    /// Hidden class-scope bindings (Phase 9E): a private name's record
    /// (JSPseudoName.privateName) or a computed field key
    /// (JSPseudoName.computedField).
    case hidden
    /// An imported binding (modules): its env slot holds an import record
    /// (or a namespace object); reads go through getModuleBinding.
    case import_
}

/// Pseudo names (never pool ids, which are >= 0).
enum JSPseudoName {
    static let this_: Int32 = -2
    static let newTarget: Int32 = -3
    static let home: Int32 = -4
    static let funcObj: Int32 = -5
    /// `#x` (pool id of "x") in the class scope that declares it.
    static func privateName(_ id: Int32) -> Int32 { -0x4000_0000 - id }
    /// Modules: the `*default*` export binding and the import.meta object.
    static let moduleDefault: Int32 = -6
    static let importMeta: Int32 = -7
    /// The key of the computed class field at property node n.
    static func computedField(_ n: Int32) -> Int32 { -0x2000_0000 - n }
}

/// Resolution results other than a binding id.
enum JSRefKind {
    static let global: Int32 = -1
    static let dynamic: Int32 = -2
    static let scriptThis: Int32 = -3
    static let none: Int32 = -4
}

struct JSBinding {
    var name: Int32
    var kind: JSBindingKind
    var scope: Int32
    /// Byte offset where the binding is initialized (end of its declarator),
    /// for the textual TDZ check of stack locals.
    var declEnd: UInt32 = 0
    var captured = false
    var used = false
    /// Some reference may see it uninitialized (needs hole init + checks).
    var needsTDZ = false
    var inEnv = false
    /// Env slot (>= 2) when inEnv; else the local index (set by the compiler).
    var slot: Int32 = -1
    /// `var arguments` in a function that gets an arguments object.
    var isArgumentsVar = false

    var isLexical: Bool {
        kind == .let_ || kind == .const_ || kind == .class_ || kind == .classInner
    }
    var isConst: Bool { kind == .const_ || kind == .classInner || kind == .import_ }
}

struct JSScopeRec {
    var kind: JSScopeKind
    var parent: Int32
    /// The nearest function-like scope (script, eval, function, fieldInit).
    var fn: Int32
    var node: Int32
    var names: [Int32: Int32] = [:]
    var bindings: [Int32] = []
    var hasEnv = false
    var envCount: Int32 = 2
    // Function-like scopes only.
    var strict = false
    var isArrow = false
    var allHeap = false
    /// Contains a sloppy direct eval itself (may declare vars here).
    var sloppyEval = false
    var usesArguments = false
    var funcKind: JSFunctionKind = .normal

    var isFunctionLike: Bool { kind == .script || kind == .eval || kind == .function || kind == .fieldInit || kind == .module }
}

final class JSScopeAnalysis {
    let ast: JSAST
    var scopes: [JSScopeRec] = []
    var bindings: [JSBinding] = []
    var nodeScope: [Int32: Int32] = [:]
    /// Instance and static field-initializer scopes per class node.
    var classFieldScope: [Int32: Int32] = [:]
    var classStaticScope: [Int32: Int32] = [:]
    /// Resolution per node (identifiers, this, new.target): a binding id or
    /// a JSRefKind value.
    var refs: [Int32: Int32] = [:]
    /// super: node << 3 | pseudo index (0 home, 1 this, 2 funcObj, 3 newTarget).
    var superRefs: [Int64: Int32] = [:]
    var annexB: [Int32: Int32] = [:]
    /// Function nodes whose bodies are not compiled (generators, async).
    var stubs: Set<Int32> = []

    private var pending: [(node: Int32, scope: Int32, name: Int32, key: Int64)] = []
    private var annexCandidates: [(fnNode: Int32, name: Int32, block: Int32)] = []

    init(ast: JSAST) { self.ast = ast }

    // MARK: Building

    @discardableResult
    func newScope(_ kind: JSScopeKind, parent: Int32, node: Int32) -> Int32 {
        let id = Int32(scopes.count)
        let fn: Int32
        switch kind {
        case .script, .eval, .function, .fieldInit, .module: fn = id
        default: fn = parent >= 0 ? scopes[Int(parent)].fn : id
        }
        var s = JSScopeRec(kind: kind, parent: parent, fn: fn, node: node)
        if parent >= 0 && kind != .function && kind != .fieldInit { s.strict = scopes[Int(parent)].strict }
        scopes.append(s)
        return id
    }

    @discardableResult
    func declare(_ name: Int32, _ kind: JSBindingKind, in scope: Int32, end: UInt32) -> Int32 {
        if let b = scopes[Int(scope)].names[name] {
            // Redeclaration (var/var, function over var, duplicate params):
            // the parser checked the legal ones. A function declaration
            // takes over a var's kind; a later param wins its slot.
            let old = bindings[Int(b)].kind
            if kind == .function && (old == .var_ || old == .function) { bindings[Int(b)].kind = .function }
            if kind == .param && old == .param { bindings[Int(b)].declEnd = end }
            return b
        }
        let id = Int32(bindings.count)
        bindings.append(JSBinding(name: name, kind: kind, scope: scope, declEnd: end))
        scopes[Int(scope)].names[name] = id
        scopes[Int(scope)].bindings.append(id)
        return id
    }

    func varScope(_ s: Int32) -> Int32 { scopes[Int(s)].fn }

    /// Binding identifiers in a pattern (iterative).
    func patternNames(_ root: Int32, _ out: inout [(Int32, Int32)]) {
        var stack: [Int32] = [root]
        while let n = stack.popLast() {
            if n < 0 { continue }
            let node = ast[n]
            switch node.kind {
            case .identifier: out.append((node.a, n))
            case .arrayPattern:
                for c in ast.list(node.a, node.b).reversed() { stack.append(c) }
            case .objectPattern:
                for c in ast.list(node.a, node.b).reversed() { stack.append(c) }
            case .property: stack.append(node.b)
            case .assignPattern: stack.append(node.a)
            case .rest: stack.append(node.a)
            default: break
            }
        }
    }

    /// Whether a statement list declares anything lexically.
    func hasLexical(_ stmts: ArraySlice<Int32>) -> Bool {
        for s in stmts {
            let n = ast[s]
            switch n.kind {
            case .varDecl where n.op != JSVarKind.var.rawValue: return true
            case .classNode, .function: return true
            default: continue
            }
        }
        return false
    }

    func record(_ node: Int32, _ scope: Int32, _ name: Int32) {
        pending.append((node, scope, name, -1))
    }

    func recordSuper(_ node: Int32, _ scope: Int32, _ which: Int64, _ name: Int32) {
        pending.append((node, scope, name, Int64(node) << 3 | which))
    }

    /// A plain, non-generator, non-async function declaration in a
    /// statement position. These are the Annex B (B.3.3) block-level
    /// function declaration candidates.
    func isBlockFunctionCandidate(_ cn: JSNode) -> Bool {
        cn.kind == .function
            && cn.flags & JSNodeFlags.declaration != 0
            && cn.flags & JSNodeFlags.expression == 0
            && cn.flags & (JSNodeFlags.async | JSNodeFlags.generator) == 0
            && cn.a >= 0
    }

    // MARK: The walk

    /// Analyse a script (or eval body when `evalCode`).
    func run(evalCode: Bool, strict: Bool, module: Bool = false) {
        let root = ast.root
        let rn = ast[root]
        let top = newScope(module ? .module : evalCode ? .eval : .script, parent: -1, node: root)
        scopes[Int(top)].strict = module || strict || rn.flags & JSNodeFlags.strict != 0
        if module {
            declare(JSPseudoName.this_, .this_, in: top, end: 0)
            declare(JSPseudoName.importMeta, .hidden, in: top, end: 0)
            scopes[Int(top)].allHeap = true
        }
        if evalCode {
            declare(JSPseudoName.this_, .this_, in: top, end: 0)
            declare(JSPseudoName.newTarget, .newTarget, in: top, end: 0)
            declare(JSPseudoName.home, .home, in: top, end: 0)
            scopes[Int(top)].allHeap = true
        }
        nodeScope[root] = top
        var stack: [(Int32, Int32)] = []
        for s in ast.list(rn.a, rn.b).reversed() { stack.append((s, top)) }
        walk(&stack)
        finishFunctions()
        resolve()
        assignLocations()
    }

    private func walk(_ stack: inout [(Int32, Int32)]) {
        while let (n, scope) = stack.popLast() {
            if n < 0 { continue }
            let node = ast[n]
            switch node.kind {
            case .identifier:
                record(n, scope, node.a)
            case .this:
                record(n, scope, JSPseudoName.this_)
            case .newTarget:
                record(n, scope, JSPseudoName.newTarget)
            case .privateMember:
                record(n, scope, JSPseudoName.privateName(node.b))
                stack.append((node.a, scope))
            case .privateName:
                record(n, scope, JSPseudoName.privateName(node.a))
            case .importMeta:
                record(n, scope, JSPseudoName.importMeta)
            case .importDecl:
                for sp in ast.list(node.b, node.c) {
                    let sn = ast[sp]
                    let local = sn.kind == .importSpec ? sn.b : sn.a
                    if local >= 0 && ast.kind(local) == .identifier { declare(ast[local].a, .import_, in: scope, end: 0) }
                }
            case .exportNamed:
                if node.a >= 0 { stack.append((node.a, scope)) }
            case .exportAll:
                break
            case .exportDefault:
                let v = node.a
                let isDecl = node.flags & JSNodeFlags.expression == 0
                let vk = ast.kind(v)
                if isDecl && (vk == .function || vk == .classNode) && ast[v].a >= 0 {
                    stack.append((v, scope))
                } else {
                    let b = declare(JSPseudoName.moduleDefault, isDecl && vk == .function ? .function : .let_, in: scope, end: node.end)
                    bindings[Int(b)].used = true
                    stack.append((v, scope))
                }
            case .superExpr:
                recordSuper(n, scope, 0, JSPseudoName.home)
                recordSuper(n, scope, 1, JSPseudoName.this_)
                recordSuper(n, scope, 2, JSPseudoName.funcObj)
                recordSuper(n, scope, 3, JSPseudoName.newTarget)
            case .function:
                walkFunction(n, scope, &stack)
            case .classNode:
                walkClass(n, scope, &stack)
            case .ifStmt:
                // Clause-level functions (if (x) function f() {}) are
                // block-level declarations (B.3.3).
                for c in [node.b, node.c] {
                    guard c >= 0 else { continue }
                    if isBlockFunctionCandidate(ast[c]) {
                        walkFunction(c, scope, &stack, forceBlockFunction: true)
                    } else {
                        stack.append((c, scope))
                    }
                }
                stack.append((node.a, scope))
                break
            case .block:
                let stmts = ast.list(node.a, node.b)
                var s = scope
                if hasLexical(stmts) {
                    s = newScope(.block, parent: scope, node: n)
                    nodeScope[n] = s
                }
                for c in stmts.reversed() { stack.append((c, s)) }
            case .varDecl:
                let kind = JSVarKind(rawValue: node.op) ?? .var
                var names: [(Int32, Int32)] = []
                for d in ast.list(node.a, node.b) {
                    names.removeAll(keepingCapacity: true)
                    let dn = ast[d]
                    patternNames(dn.a, &names)
                    for (name, _) in names {
                        switch kind {
                        case .var: declare(name, .var_, in: varScope(scope), end: dn.end)
                        case .let: declare(name, .let_, in: scope, end: dn.end)
                        case .const: declare(name, .const_, in: scope, end: dn.end)
                        }
                    }
                    stack.append((dn.b, scope))
                    stack.append((dn.a, scope))
                }
            case .forStmt:
                var s = scope
                if node.a >= 0 && ast[node.a].kind == .varDecl && ast[node.a].op != JSVarKind.var.rawValue {
                    s = newScope(.forLoop, parent: scope, node: n)
                    nodeScope[n] = s
                }
                stack.append((node.d, s)); stack.append((node.c, s))
                stack.append((node.b, s)); stack.append((node.a, s))
            case .forIn, .forOf:
                var s = scope
                if ast[node.a].kind == .varDecl && ast[node.a].op != JSVarKind.var.rawValue {
                    s = newScope(.forLoop, parent: scope, node: n)
                    nodeScope[n] = s
                }
                stack.append((node.c, s))
                stack.append((node.b, scope))
                stack.append((node.a, s))
            case .switchStmt:
                var lexical = false
                for c in ast.list(node.b, node.c) {
                    let cn = ast[c]
                    if hasLexical(ast.list(cn.b, cn.c)) { lexical = true; break }
                }
                var s = scope
                if lexical {
                    s = newScope(.switchBlock, parent: scope, node: n)
                    nodeScope[n] = s
                }
                for c in ast.list(node.b, node.c).reversed() {
                    let cn = ast[c]
                    for st in ast.list(cn.b, cn.c).reversed() {
                        let stn = ast[st]
                        if isBlockFunctionCandidate(stn) {
                            walkFunction(st, s, &stack, forceBlockFunction: true)
                        } else {
                            stack.append((st, s))
                        }
                    }
                    stack.append((cn.a, s))
                }
                stack.append((node.a, scope))
            case .tryStmt:
                stack.append((node.d, scope))
                if node.c >= 0 {
                    let c = newScope(.catchClause, parent: scope, node: node.c)
                    nodeScope[node.c] = c
                    if node.b >= 0 {
                        var names: [(Int32, Int32)] = []
                        patternNames(node.b, &names)
                        for (name, _) in names { declare(name, .catchParam, in: c, end: 0) }
                    }
                    let h = ast[node.c]
                    for st in ast.list(h.a, h.b).reversed() {
                        let stn = ast[st]
                        if isBlockFunctionCandidate(stn) {
                            walkFunction(st, c, &stack, forceBlockFunction: true)
                        } else {
                            stack.append((st, c))
                        }
                    }
                    stack.append((node.b, c))
                }
                stack.append((node.a, scope))
            case .withStmt:
                let w = newScope(.with, parent: scope, node: n)
                nodeScope[n] = w
                markAllHeap(scope)
                stack.append((node.b, w))
                stack.append((node.a, scope))
            case .call:
                let callee = ast[node.a]
                if callee.kind == .identifier && callee.a == JSWord.eval && node.flags & JSNodeFlags.optional == 0 {
                    let f = scopes[Int(scope)].fn
                    if !scopes[Int(scope)].strict { scopes[Int(f)].sloppyEval = true }
                    markAllHeap(scope)
                    // The eval code may use this / new.target / arguments.
                    record(n, scope, JSPseudoName.this_)
                    recordSuper(n, scope, 3, JSPseudoName.newTarget)
                    recordSuper(n, scope, 0, JSPseudoName.home)
                    record(-1, scope, JSWord.arguments)
                }
                if callee.kind == .superExpr {
                    // super(...): only the active function, new.target and this.
                    recordSuper(node.a, scope, 1, JSPseudoName.this_)
                    recordSuper(node.a, scope, 2, JSPseudoName.funcObj)
                    recordSuper(node.a, scope, 3, JSPseudoName.newTarget)
                    for c in ast.list(node.b, node.c).reversed() { stack.append((c, scope)) }
                } else {
                    for c in ast.list(node.b, node.c).reversed() { stack.append((c, scope)) }
                    stack.append((node.a, scope))
                }
            default:
                ast.forEachChild(n) { stack.append(($0, scope)) }
            }
        }
    }

    func markAllHeap(_ scope: Int32) {
        var f = scopes[Int(scope)].fn
        while f >= 0 {
            scopes[Int(f)].allHeap = true
            let p = scopes[Int(f)].parent
            if p < 0 { break }
            f = scopes[Int(p)].fn
        }
    }

    private func walkFunction(_ n: Int32, _ scope: Int32, _ stack: inout [(Int32, Int32)], forceBlockFunction: Bool = false) {
        let node = ast[n]
        let kind = JSFunctionKind(rawValue: node.op) ?? .normal
        let isDecl = node.flags & JSNodeFlags.declaration != 0 && node.flags & JSNodeFlags.expression == 0
        if isDecl && node.a >= 0 {
            let name = ast[node.a].a
            let sc = scopes[Int(scope)]
            if !forceBlockFunction && sc.isFunctionLike {
                declare(name, .function, in: scope, end: node.start)
            } else {
                declare(name, .blockFunction, in: scope, end: node.start)
                if !sc.strict && node.flags & (JSNodeFlags.async | JSNodeFlags.generator) == 0 {
                    annexCandidates.append((n, name, scope))
                }
            }
            record(node.a, scope, name)
        }
        let f = newScope(.function, parent: scope, node: n)
        nodeScope[n] = f
        scopes[Int(f)].strict = node.flags & JSNodeFlags.strict != 0
        scopes[Int(f)].isArrow = kind == .arrow
        scopes[Int(f)].funcKind = kind
        scopes[Int(f)].usesArguments = node.flags & JSNodeFlags.usesArguments != 0
        if kind != .arrow {
            declare(JSPseudoName.this_, .this_, in: f, end: 0)
            declare(JSPseudoName.newTarget, .newTarget, in: f, end: 0)
            if kind != .normal { declare(JSPseudoName.home, .home, in: f, end: 0) }
            if kind == .derivedConstructor || kind == .classConstructor {
                declare(JSPseudoName.funcObj, .funcObj, in: f, end: 0)
            }
        }
        var names: [(Int32, Int32)] = []
        for p in ast.list(node.b, node.c) {
            names.removeAll(keepingCapacity: true)
            patternNames(p, &names)
            for (name, _) in names { declare(name, .param, in: f, end: ast[p].end) }
        }
        if node.d >= 0 {
            let body = ast[node.d]
            if node.flags & JSNodeFlags.exprBody != 0 || body.kind != .functionBody {
                stack.append((node.d, f))
            } else {
                for s in ast.list(body.a, body.b).reversed() { stack.append((s, f)) }
            }
        }
        for p in ast.list(node.b, node.c).reversed() { stack.append((p, f)) }
    }

    private func walkClass(_ n: Int32, _ scope: Int32, _ stack: inout [(Int32, Int32)]) {
        let node = ast[n]
        let isDecl = node.flags & JSNodeFlags.declaration != 0
        if isDecl && node.a >= 0 {
            declare(ast[node.a].a, .class_, in: scope, end: node.end)
            record(node.a, scope, ast[node.a].a)
        }
        let c = newScope(.classBody, parent: scope, node: n)
        scopes[Int(c)].strict = true
        nodeScope[n] = c
        if node.a >= 0 {
            let inner = declare(ast[node.a].a, .classInner, in: c, end: node.end)
            _ = inner
        }
        var fi: Int32 = -1, fs: Int32 = -1
        func fieldScope(_ isStatic: Bool) -> Int32 {
            if isStatic {
                if fs < 0 {
                    fs = newScope(.fieldInit, parent: c, node: n)
                    setupFieldScope(fs)
                    classStaticScope[n] = fs
                }
                return fs
            }
            if fi < 0 {
                fi = newScope(.fieldInit, parent: c, node: n)
                setupFieldScope(fi)
                classFieldScope[n] = fi
            }
            return fi
        }
        // Private names and computed field keys: hidden class-scope
        // bindings, referenced from the initializer scopes that use them.
        for m in ast.list(node.c, node.d) {
            let mn = ast[m]
            guard mn.kind == .property else { continue }
            let isStatic = mn.flags & JSNodeFlags.isStatic != 0
            if ast.kind(mn.a) == .privateName {
                let pn = JSPseudoName.privateName(ast[mn.a].a)
                if scopes[Int(c)].names[pn] == nil { declare(pn, .hidden, in: c, end: 0) }
                if mn.op != JSPropertyKind.field.rawValue && !isStatic { record(-1, fieldScope(false), pn) }
                if mn.op == JSPropertyKind.field.rawValue { record(-1, fieldScope(isStatic), pn) }
                if let b = scopes[Int(c)].names[pn] { bindings[Int(b)].used = true }
            } else if mn.op == JSPropertyKind.field.rawValue && mn.flags & JSNodeFlags.computed != 0 {
                let ck = JSPseudoName.computedField(m)
                let b = declare(ck, .hidden, in: c, end: 0)
                bindings[Int(b)].used = true
                record(-1, fieldScope(isStatic), ck)
            }
        }
        for m in ast.list(node.c, node.d).reversed() {
            let mn = ast[m]
            if mn.kind == .staticBlock {
                let s = fieldScope(true)
                let blk = newScope(.function, parent: s, node: m)
                scopes[Int(blk)].strict = true
                scopes[Int(blk)].funcKind = .method
                declare(JSPseudoName.this_, .this_, in: blk, end: 0)
                declare(JSPseudoName.newTarget, .newTarget, in: blk, end: 0)
                declare(JSPseudoName.home, .home, in: blk, end: 0)
                nodeScope[m] = blk
                for st in ast.list(mn.a, mn.b).reversed() { stack.append((st, blk)) }
                continue
            }
            guard mn.kind == .property else { continue }
            let isStatic = mn.flags & JSNodeFlags.isStatic != 0
            if mn.op == JSPropertyKind.field.rawValue {
                if mn.b >= 0 { stack.append((mn.b, fieldScope(isStatic))) }
                else { _ = fieldScope(isStatic) }
            } else if mn.b >= 0 {
                stack.append((mn.b, c))
            }
            if mn.flags & JSNodeFlags.computed != 0 { stack.append((mn.a, c)) }
        }
        if node.b >= 0 { stack.append((node.b, c)) }
    }

    private func setupFieldScope(_ s: Int32) {
        scopes[Int(s)].strict = true
        scopes[Int(s)].funcKind = .method
        declare(JSPseudoName.this_, .this_, in: s, end: 0)
        declare(JSPseudoName.newTarget, .newTarget, in: s, end: 0)
        declare(JSPseudoName.home, .home, in: s, end: 0)
    }

    // MARK: After the walk

    private func finishFunctions() {
        // Annex B block functions: a var binding in the function scope too,
        // unless that would clash with a lexical binding or a parameter.
        for (fnNode, name, block) in annexCandidates {
            let f = scopes[Int(block)].fn
            var clash = false
            var s = scopes[Int(block)].parent
            while s >= 0 && s != f {
                if let b = scopes[Int(s)].names[name], bindings[Int(b)].kind != .var_ { clash = true; break }
                s = scopes[Int(s)].parent
            }
            if let b = scopes[Int(f)].names[name] {
                let k = bindings[Int(b)].kind
                if k != .var_ && k != .function { clash = true }
            }
            if clash { continue }
            let kind: JSBindingKind = scopes[Int(f)].kind == .eval && !scopes[Int(f)].strict ? .var_ : .var_
            annexB[fnNode] = declare(name, kind, in: f, end: 0)
        }
        // The arguments object.
        for i in 0..<scopes.count where scopes[i].kind == .function && !scopes[i].isArrow {
            guard scopes[i].usesArguments || scopes[i].allHeap else { continue }
            let id = Int32(i)
            if let b = scopes[i].names[JSWord.arguments] {
                let k = bindings[Int(b)].kind
                if k == .var_ { bindings[Int(b)].isArgumentsVar = true }
                if k == .var_ || k == .arguments { markMappedParams(i) }
                continue
            }
            declare(JSWord.arguments, .arguments, in: id, end: 0)
            markMappedParams(i)
        }
        // Named function expressions see their own name.
        for i in 0..<scopes.count where scopes[i].kind == .function {
            let fnode = ast[scopes[i].node]
            guard fnode.kind == .function, fnode.a >= 0,
                  fnode.flags & JSNodeFlags.declaration == 0 || fnode.flags & JSNodeFlags.expression != 0 else { continue }
            let name = ast[fnode.a].a
            if scopes[i].names[name] == nil { declare(name, .calleeName, in: Int32(i), end: 0) }
        }
    }

    /// Mapped arguments objects (jsarguments.swift): a sloppy function with
    /// only simple parameters and an `arguments` object keeps its parameters
    /// in heap environment slots (as if captured) so the arguments object
    /// can alias them for as long as it lives.
    private func markMappedParams(_ i: Int) {
        let sc = scopes[i]
        guard !sc.strict, sc.node >= 0 else { return }
        let node = ast[sc.node]
        guard node.kind == .function else { return }
        let params = ast.list(node.b, node.c)
        if params.isEmpty { return }
        for p in params where ast.kind(p) != .identifier { return }
        for p in params {
            if let b = sc.names[ast[p].a], bindings[Int(b)].kind == .param { bindings[Int(b)].captured = true }
        }
    }

    private func resolve() {
        for r in pending {
            var s = r.scope
            let useFn = scopes[Int(s)].fn
            var dynamic = false
            var found: Int32 = -1
            while s >= 0 {
                let sc = scopes[Int(s)]
                if let b = sc.names[r.name] { found = b; break }
                if sc.kind == .with { dynamic = true }
                if sc.isFunctionLike && sc.sloppyEval { dynamic = true }
                if sc.kind == .eval { dynamic = true }
                s = sc.parent
            }
            var result: Int32
            if found >= 0 {
                let b = Int(found)
                let bscope = scopes[Int(bindings[b].scope)]
                bindings[b].used = true
                if bscope.kind == .script {
                    result = dynamic ? JSRefKind.dynamic : JSRefKind.global
                } else if bscope.kind == .eval && !bscope.strict
                            && (bindings[b].kind == .var_ || bindings[b].kind == .function) {
                    result = JSRefKind.dynamic
                } else {
                    if bscope.fn != useFn { bindings[b].captured = true }
                    result = dynamic ? JSRefKind.dynamic : found
                    if bindings[b].isLexical && r.node >= 0 {
                        let start = ast[r.node].start
                        if start < bindings[b].declEnd || bscope.kind == .switchBlock || bscope.fn != useFn {
                            bindings[b].needsTDZ = true
                        }
                    }
                    if bindings[b].isLexical && dynamic { bindings[b].needsTDZ = true }
                }
            } else if r.name == JSPseudoName.this_ {
                result = JSRefKind.scriptThis
            } else if r.name < 0 {
                result = JSRefKind.none
            } else {
                result = dynamic ? JSRefKind.dynamic : JSRefKind.global
            }
            if r.key >= 0 { superRefs[r.key] = result } else if r.node >= 0 { refs[r.node] = result }
        }
        pending = []
    }

    private func assignLocations() {
        for i in 0..<scopes.count {
            let sc = scopes[i]
            if sc.kind == .script { continue }
            let f = scopes[Int(sc.fn)]
            let allHeap = f.allHeap || f.kind == .eval
            for b in sc.bindings {
                let bi = Int(b)
                if sc.kind == .eval && !sc.strict && (bindings[bi].kind == .var_ || bindings[bi].kind == .function) {
                    continue   // declared at run time in the caller's var scope
                }
                let pseudo = bindings[bi].name < 0
                if pseudo && !bindings[bi].used && !allHeap { continue }
                if allHeap || bindings[bi].captured {
                    bindings[bi].inEnv = true
                    bindings[bi].slot = scopes[i].envCount
                    scopes[i].envCount += 1
                    if bindings[bi].isLexical { bindings[bi].needsTDZ = true }
                }
            }
            if scopes[i].envCount > 2 || sc.kind == .with || (sc.isFunctionLike && sc.sloppyEval)
                || sc.kind == .eval {
                scopes[i].hasEnv = true
            }
        }
    }

    // MARK: Queries

    func ref(_ node: Int32) -> Int32 { refs[node] ?? JSRefKind.global }
    func superRef(_ node: Int32, _ which: Int64) -> Int32 { superRefs[Int64(node) << 3 | which] ?? JSRefKind.none }

    /// The binding a function-like scope has for a pseudo name, or -1.
    func pseudo(_ scope: Int32, _ name: Int32) -> Int32 { scopes[Int(scope)].names[name] ?? -1 }
}
