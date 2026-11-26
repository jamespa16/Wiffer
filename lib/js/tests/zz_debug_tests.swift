// Temporary debug: dump AST + scope analysis + run a snippet.
func jsDebugTests(_ t: Tests) {
    if jsTest262Env("WIFFER_JS_DEBUG") == nil { return }
    let src = jsTest262Env("WIFFER_JS_DEBUG_SRC") ?? "switch (1) { case 1: function f() { return 'declaration'; } } assert.sameValue(typeof f, 'function');"
    do {
        let ast = try jsParse([UInt8](src.utf8), JSParseOptions(module: false, strict: false, limits: JSLimits.small))
        print("=== AST ===")
        print(ast.dump(ast.root))
        let sa = JSScopeAnalysis(ast: ast)
        sa.run(evalCode: false, strict: false)
        print("=== SCOPES ===")
        for (i, sc) in sa.scopes.enumerated() {
            print("scope[\(i)] kind=\(scopeKindName(sc.kind)) parent=\(sc.parent) fn=\(sc.fn) strict=\(sc.strict) hasEnv=\(sc.hasEnv) envCount=\(sc.envCount) bindings=\(sc.bindings)")
        }
        print("=== BINDINGS ===")
        for (i, b) in sa.bindings.enumerated() {
            let nm = b.name >= 0 && b.name < ast.pool.count ? ast.pool.text(b.name) : "-"
            print("binding[\(i)] name=\(nm) kind=\(bindingKindName(b.kind)) scope=\(b.scope) slot=\(b.slot) inEnv=\(b.inEnv) captured=\(b.captured) used=\(b.used)")
        }
        print("=== ANNEX B ===")
        for (n, b) in sa.annexB { print("annexB[\(n)] -> binding \(b)") }
        print("=== REFS ===")
        for (n, b) in sa.refs { print("refs[\(n)] -> binding \(b)") }
    } catch {
        print("parse error: \(error)")
    }
    func scopeKindName(_ k: JSScopeKind) -> String {
        switch k {
        case .script: return "script"
        case .eval: return "eval"
        case .function: return "function"
        case .block: return "block"
        case .catchClause: return "catchClause"
        case .forLoop: return "forLoop"
        case .switchBlock: return "switchBlock"
        case .classBody: return "classBody"
        case .with: return "with"
        case .fieldInit: return "fieldInit"
        case .module: return "module"
        }
    }
    func bindingKindName(_ k: JSBindingKind) -> String {
        switch k {
        case .var_: return "var_"
        case .let_: return "let_"
        case .const_: return "const_"
        case .class_: return "class_"
        case .classInner: return "classInner"
        case .function: return "function"
        case .blockFunction: return "blockFunction"
        case .param: return "param"
        case .catchParam: return "catchParam"
        case .calleeName: return "calleeName"
        case .arguments: return "arguments"
        case .this_: return "this_"
        case .newTarget: return "newTarget"
        case .home: return "home"
        case .funcObj: return "funcObj"
        case .hidden: return "hidden"
        case .import_: return "import_"
        }
    }
    let rt = JSRuntime(limits: JSLimits.small)
    let realm = rt.makeRealm()
    switch realm.evaluate(source: src, name: "tdbg") {
    case .normal(let v):
        let d = realm.heap.rootDepth
        _ = realm.heap.root(v)
        print("=== RESULT: normal === \(realm.heap.swiftString(v))")
        realm.heap.popRoots(to: d)
    case .exception(let e):
        print("=== RESULT: exception === \(e.message)")
    case .terminated(let r):
        print("=== RESULT: terminated === \(r)")
    }
}
