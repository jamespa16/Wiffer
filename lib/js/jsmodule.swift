// ES modules (ROADMAP Phase 9E item 5): module records, loading through a
// host callback, linking, evaluation with top-level await, namespace
// objects, dynamic import() and import.meta. lib/js does no I/O.
//
// ============================================================ host API
//
//   realm.moduleLoader = { (realm: JSRealm, specifier: String, referrer: String) -> JSModuleLoadResult in
//       // resolve `specifier` against `referrer` (the importing module's
//       // url, or the script name for import() in a classic script) and
//       // return .source(url: canonicalURL, bytes: utf8) or .error(message)
//   }
//       Called synchronously while a module graph is loaded. The url is the
//       module's identity: the same url always yields the same module
//       record (the source is not asked for again). An .error becomes a
//       TypeError for the importer (a rejected import() promise, or an
//       .exception from evaluateModule). A host that fetches over the
//       network can pre-fetch a graph with realm.moduleRequests(source:)
//       and answer from its cache.
//   realm.evaluateModule(source:name:) -> JSCompletion
//       Run `source` as the root module with url `name` (dependencies via
//       moduleLoader). Load, parse and link errors are .exception
//       (SyntaxError for parse, unresolvable imports and ambiguous star
//       exports; TypeError from the loader). Otherwise .normal(promise):
//       the evaluation promise, settled once the graph (including
//       top-level await) has run: drain realm.runJobs() and read
//       realm.promiseState/promiseResult. A module that throws without
//       awaiting is reported at once as .exception.
//   realm.importModule(_ specifier:, referrer:) -> JSCompletion
//       The same for a module named through the loader.
//   realm.moduleNamespace(url:) -> JSValue?   a loaded module's namespace
//       object (created on demand; unrooted)
//   realm.moduleRequests(source:) -> [String]?   the specifiers a module
//       source imports, in order (nil on a syntax error); no evaluation
//   realm.importMetaHook: ((JSRealm, String, JSValue) -> Void)?
//       HostGetImportMetaProperties: called with (url, meta object) when a
//       module is linked; `import.meta.url` is already set to the url.
//
// import() (in scripts and modules) returns a promise and loads, links
// and evaluates in a job, then resolves to the namespace object.
//
// =========================================================== internals
//
// A module body compiles (JSCompiler.compileModule) into two closures over
// the module environment (a heap env made from the module scope info, all
// top-level bindings in it): `init` instantiates the hoisted functions at
// link time (so cycles can call them early) and `body` runs the rest as an
// async-function-like frame (genKind module: top-level await suspends
// it; its promise settles when it completes). An imported binding's env
// slot holds an import record (internal object, flag user2: slot 0 the
// exporting module's env, internalInt the slot) or a namespace object; the
// getModuleBinding instruction dereferences it (TDZ included). Evaluation
// follows the spec's InnerModuleEvaluation with the async-module
// algorithms (pending dependency counts, async parents, execution order).

public enum JSModuleLoadResult {
    case source(url: String, bytes: [UInt8])
    case error(String)
}

public typealias JSModuleLoader = (_ realm: JSRealm, _ specifier: String, _ referrer: String) -> JSModuleLoadResult

/// What the compiler learns about a module's imports and exports.
struct JSModuleInfo {
    var requests: [String] = []
    /// importName nil: a namespace import.
    var imports: [(request: Int, importName: String?, slot: Int)] = []
    var localExports: [(name: String, slot: Int)] = []
    /// importName nil: `export * as name from`.
    var indirectExports: [(name: String, request: Int, importName: String?)] = []
    var starExports: [Int] = []
    var metaSlot = -1
    var hasTLA = false
}

enum JSModuleStatus {
    static let new = 0, linking = 1, linked = 2, evaluating = 3, evaluatingAsync = 4, evaluated = 5
}

final class JSModuleRecord {
    let url: String
    var info: JSModuleInfo
    var status = JSModuleStatus.new
    var bodyCode: JSValue = .undefined
    var initCode: JSValue = .undefined
    var scopeInfo: JSValue = .undefined
    var env: JSValue = .undefined
    var body: JSValue = .undefined
    var namespace: JSValue = .undefined
    var topPromise: JSValue = .undefined
    var error: JSValue = .undefined
    var hasError = false
    var requested: [Int] = []
    var dfsIndex = 0, dfsAncestor = 0, cycleRoot = -1
    var asyncEvaluation = false
    var asyncOrder = 0
    var pendingDeps = 0
    var asyncParents: [Int] = []

    init(url: String, info: JSModuleInfo) {
        self.url = url
        self.info = info
    }

    func mark(_ h: JSHeap) {
        for v in [bodyCode, initCode, scopeInfo, env, body, namespace, topPromise, error] { h.markValue(v) }
    }
}

enum JSExportResolution {
    case binding(Int, Int)
    case namespace(Int)
    case notFound
    case ambiguous
}

// MARK: Compiler

extension JSCompiler {
    static func compileModule(_ ast: JSAST, realm: JSRealm, source: JSScriptSource)
        throws(JSCompileError) -> (JSCode, JSCode, JSModuleInfo, JSValue) {
        let sa = JSScopeAnalysis(ast: ast)
        sa.run(evalCode: false, strict: true, module: true)
        let c = JSCompiler(ast: ast, analysis: sa, realm: realm, source: source)
        return try c.compileModuleTop()
    }

    func moduleSlot(_ name: Int32) throws(JSCompileError) -> Int {
        guard let b = sa.scopes[0].names[name], sa.bindings[Int(b)].inEnv else { throw internalError("module binding") }
        return Int(sa.bindings[Int(b)].slot)
    }

    func compileModuleTop() throws(JSCompileError) -> (JSCode, JSCode, JSModuleInfo, JSValue) {
        let top: Int32 = 0
        let rn = ast[ast.root]
        let stmts = ast.list(rn.a, rn.b)
        let info0 = scopeInfo(top)
        // init: the hoisted function declarations.
        fs = JSFuncState()
        fs.code.kind = .function
        fs.code.strict = true
        fs.code.source = source
        fs.code.sourceEnd = UInt32(truncatingIfNeeded: ast.source.count)
        fs.fnScope = top
        fs.scope = top
        var decls: [Int32] = []
        var anonDefault: Int32 = -1
        for s in stmts {
            let n = ast[s]
            switch n.kind {
            case .function: decls.append(s)
            case .exportNamed where n.a >= 0 && ast.kind(n.a) == .function: decls.append(n.a)
            case .exportDefault where n.flags & JSNodeFlags.expression == 0 && ast.kind(n.a) == .function:
                if ast[n.a].a >= 0 { decls.append(n.a) } else { anonDefault = n.a }
            default: break
            }
        }
        try hoistFunctions(decls[...], scope: top)
        if anonDefault >= 0 {
            let code = try compileFunction(anonDefault, name: atomValue("default"))
            try emitU32(.closure, addConst(code.codeObject), 1)
            guard let b = sa.scopes[0].names[JSPseudoName.moduleDefault] else { throw internalError("default binding") }
            try emitPutBinding(b, initialize: true)
        }
        try emit(.retUndefined, 0)
        let initCode = try finishFunction(name: .string(0), nameHint: nil)
        // body
        fs = JSFuncState()
        fs.code.kind = .function
        fs.code.strict = true
        fs.code.genKind = JSGenKind.module
        fs.genKind = JSGenKind.module
        fs.code.source = source
        fs.code.sourceEnd = UInt32(truncatingIfNeeded: ast.source.count)
        fs.fnScope = top
        fs.scope = top
        computeBlockEnvs(top)
        try emit(.generatorStart, 0)
        try emitPseudoPrologue(top)
        for s in stmts { try emitStatement(s) }
        try emit(.retUndefined, 0)
        let body = try finishFunction(name: .string(0), nameHint: nil)
        var info = try moduleInfo(stmts)
        info.hasTLA = moduleHasTLA
        return (body, initCode, info, info0)
    }

    /// import / export statements in the body.
    func emitModuleStatement(_ n: Int32) throws(JSCompileError) {
        let node = ast[n]
        switch node.kind {
        case .exportNamed:
            if node.a >= 0 { try emitStatement(node.a) }
        case .exportDefault:
            let v = node.a
            let isDecl = node.flags & JSNodeFlags.expression == 0
            let vk = ast.kind(v)
            if isDecl && vk == .function { return }
            if isDecl && vk == .classNode && ast[v].a >= 0 {
                try emitClass(v, nameHint: nil)
                try emitDeclInit(ast[v].a)
                return
            }
            try emitExpr(v, nameHint: atomValue("default"))
            guard let b = sa.scopes[0].names[JSPseudoName.moduleDefault] else { throw internalError("default binding") }
            try emitPutBinding(b, initialize: true)
        default:
            break
        }
    }

    func moduleInfo(_ stmts: ArraySlice<Int32>) throws(JSCompileError) -> JSModuleInfo {
        var info = JSModuleInfo()
        var reqIndex: [String: Int] = [:]
        func req(_ id: Int32) -> Int {
            let s = ast.text(id)
            if let i = reqIndex[s] { return i }
            info.requests.append(s)
            reqIndex[s] = info.requests.count - 1
            return info.requests.count - 1
        }
        var importLocals: [Int32: (Int, String?)] = [:]
        for s in stmts {
            let n = ast[s]
            switch n.kind {
            case .importDecl:
                let r = req(n.a)
                for sp in ast.list(n.b, n.c) {
                    let sn = ast[sp]
                    var local: Int32 = -1
                    var name: String? = nil
                    switch sn.kind {
                    case .importSpec: local = sn.b; name = ast.text(sn.a)
                    case .importDefault: local = sn.a; name = "default"
                    default: local = sn.a
                    }
                    guard local >= 0 else { continue }
                    let id = ast[local].a
                    info.imports.append((r, name, try moduleSlot(id)))
                    importLocals[id] = (r, name)
                }
            case .exportNamed where n.d >= 0: _ = req(n.d)
            case .exportAll: _ = req(n.a)
            default: break
            }
        }
        for s in stmts {
            let n = ast[s]
            switch n.kind {
            case .exportNamed:
                if n.a >= 0 {
                    let d = ast[n.a]
                    var names: [(Int32, Int32)] = []
                    if d.kind == .varDecl {
                        for dc in ast.list(d.a, d.b) { sa.patternNames(ast[dc].a, &names) }
                    } else if d.a >= 0 {
                        names.append((ast[d.a].a, d.a))
                    }
                    for (id, _) in names { info.localExports.append((ast.text(id), try moduleSlot(id))) }
                } else if n.d >= 0 {
                    let r = req(n.d)
                    for sp in ast.list(n.b, n.c) {
                        let sn = ast[sp]
                        info.indirectExports.append((ast.text(sn.b), r, ast.text(sn.a)))
                    }
                } else {
                    for sp in ast.list(n.b, n.c) {
                        let sn = ast[sp]
                        if let (r, nm) = importLocals[sn.a], let name = nm {
                            info.indirectExports.append((ast.text(sn.b), r, name))
                        } else {
                            info.localExports.append((ast.text(sn.b), try moduleSlot(sn.a)))
                        }
                    }
                }
            case .exportDefault:
                let v = n.a
                if n.flags & JSNodeFlags.expression == 0 && (ast.kind(v) == .function || ast.kind(v) == .classNode) && ast[v].a >= 0 {
                    info.localExports.append(("default", try moduleSlot(ast[ast[v].a].a)))
                } else {
                    info.localExports.append(("default", try moduleSlot(JSPseudoName.moduleDefault)))
                }
            case .exportAll:
                let r = req(n.a)
                if n.b >= 0 { info.indirectExports.append((ast.text(n.b), r, nil)) } else { info.starExports.append(r) }
            default: break
            }
        }
        if let b = sa.scopes[0].names[JSPseudoName.importMeta], sa.bindings[Int(b)].inEnv {
            info.metaSlot = Int(sa.bindings[Int(b)].slot)
        }
        return info
    }
}

// MARK: Runtime

extension JSRealm {
    public var moduleLoader: JSModuleLoader? {
        get { es.moduleLoader }
        set { es.moduleLoader = newValue }
    }
    public var importMetaHook: ((JSRealm, String, JSValue) -> Void)? {
        get { es.importMetaHook }
        set { es.importMetaHook = newValue }
    }

    func moduleRec(_ i: Int) -> JSModuleRecord { es.moduleRecords[i] }

    public func moduleRequests(source: [UInt8]) -> [String]? {
        guard let ast = try? jsParse(source, JSParseOptions(module: true, strict: true, limits: limits)) else { return nil }
        var out: [String] = []
        let rn = ast[ast.root]
        for s in ast.list(rn.a, rn.b) {
            let n = ast[s]
            var id: Int32 = -1
            switch n.kind {
            case .importDecl: id = n.a
            case .exportNamed: id = n.d
            case .exportAll: id = n.a
            default: break
            }
            if id >= 0 {
                let t = ast.text(id)
                if !out.contains(t) { out.append(t) }
            }
        }
        return out
    }

    /// Parse and compile a module; returns its index (no dependencies yet).
    func registerModule(url: String, bytes: [UInt8]) throws(JSThrow) -> Int {
        if let i = es.moduleMap[url] { return i }
        let ast: JSAST
        do throws(JSSyntaxError) {
            ast = try jsParse(bytes, JSParseOptions(module: true, strict: true, limits: limits))
        } catch {
            exception = makeError(.syntaxError, error.message)
            trace = [JSTraceEntry(name: "", location: url + ":" + String(error.line) + ":" + String(error.column))]
            throw JSThrow()
        }
        let src = JSScriptSource(name: url, source: bytes)
        let depth = heap.rootDepth
        defer { heap.popRoots(to: depth) }
        let compiled: (JSCode, JSCode, JSModuleInfo, JSValue)
        do throws(JSCompileError) {
            compiled = try JSCompiler.compileModule(ast, realm: self, source: src)
        } catch {
            exception = makeError(.syntaxError, error.message)
            let (l, c) = src.lineMap.location(error.offset)
            trace = [JSTraceEntry(name: "", location: url + ":" + String(l) + ":" + String(c))]
            throw JSThrow()
        }
        let rec = JSModuleRecord(url: url, info: compiled.2)
        rec.bodyCode = compiled.0.codeObject
        rec.initCode = compiled.1.codeObject
        rec.scopeInfo = compiled.3
        let idx = es.moduleRecords.count
        es.moduleRecords.append(rec)
        es.moduleMap[url] = idx
        let h = heap.newObject(proto: .null, kind: .internalObject)
        heap.setInternalInt(h, Int64(idx))
        es.modules.append(h)
        return idx
    }

    /// HostLoadImportedModule through the embedder's loader.
    func hostLoadModule(_ specifier: String, referrer: String) throws(JSThrow) -> Int {
        guard let loader = es.moduleLoader else {
            throw throwTypeError("Cannot load module '" + specifier + "': no module loader")
        }
        switch loader(self, specifier, referrer) {
        case .error(let m): throw throwTypeError(m)
        case .source(let url, let bytes):
            if let i = es.moduleMap[url] { return i }
            return try registerModule(url: url, bytes: bytes)
        }
    }

    /// Load every module the graph from `root` needs.
    func loadModuleGraph(_ root: Int) throws(JSThrow) {
        var work = [root]
        var seen: Set<Int> = [root]
        while let m = work.popLast() {
            let rec = moduleRec(m)
            if rec.requested.count != rec.info.requests.count {
                var reqs: [Int] = []
                for s in rec.info.requests { reqs.append(try hostLoadModule(s, referrer: rec.url)) }
                rec.requested = reqs
            }
            for r in rec.requested where seen.insert(r).inserted { work.append(r) }
            if seen.count > 100_000 { throw throwRangeError("Too many modules") }
        }
    }

    // MARK: Linking

    func resolveExport(_ m: Int, _ name: String, _ set: inout [(Int, String)], depth: Int = 0) -> JSExportResolution {
        if depth > 1000 { return .notFound }
        for (a, b) in set where a == m && b == name { return .notFound }
        set.append((m, name))
        let rec = moduleRec(m)
        for e in rec.info.localExports where e.name == name { return .binding(m, e.slot) }
        for e in rec.info.indirectExports where e.name == name {
            guard e.request < rec.requested.count else { return .notFound }
            let target = rec.requested[e.request]
            guard let imp = e.importName else { return .namespace(target) }
            return resolveExport(target, imp, &set, depth: depth + 1)
        }
        if name == "default" { return .notFound }
        var star: JSExportResolution = .notFound
        for r in rec.info.starExports where r < rec.requested.count {
            let res = resolveExport(rec.requested[r], name, &set, depth: depth + 1)
            switch res {
            case .ambiguous: return .ambiguous
            case .notFound: continue
            default:
                switch (star, res) {
                case (.notFound, _): star = res
                case (.binding(let a, let b), .binding(let c, let d)): if a != c || b != d { return .ambiguous }
                case (.namespace(let a), .namespace(let c)): if a != c { return .ambiguous }
                default: return .ambiguous
                }
            }
        }
        return star
    }

    func exportedNames(_ m: Int, _ visited: inout Set<Int>) -> [String] {
        if !visited.insert(m).inserted { return [] }
        let rec = moduleRec(m)
        var out: [String] = []
        for e in rec.info.localExports { out.append(e.name) }
        for e in rec.info.indirectExports { out.append(e.name) }
        for r in rec.info.starExports where r < rec.requested.count {
            for n in exportedNames(rec.requested[r], &visited) where n != "default" && !out.contains(n) { out.append(n) }
        }
        return out
    }

    /// GetModuleNamespace.
    func moduleNamespaceObject(_ m: Int) throws(JSThrow) -> JSValue {
        let rec = moduleRec(m)
        if rec.namespace.isObject { return rec.namespace }
        var visited = Set<Int>()
        var names: [String] = []
        for n in exportedNames(m, &visited) {
            var set: [(Int, String)] = []
            switch resolveExport(m, n, &set) {
            case .binding, .namespace: names.append(n)
            default: break
            }
        }
        names.sort { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }
        let ns = heap.newObject(proto: .null)
        rec.namespace = ns
        for n in names {
            var set: [(Int, String)] = []
            let res = resolveExport(m, n, &set)
            let d = heap.rootDepth
            switch res {
            case .binding(let mi, let slot):
                let g = nativeClosure(es.namespaceGetterFn, [moduleRec(mi).env, .int32(Int32(slot)), heap.atom(n)])
                _ = heap.root(g)
                _ = heap.defineOwnProperty(ns, heap.key(n), .accessor(get: g, set: .undefined, [.enumerable]))
            case .namespace(let mi):
                let v = try moduleNamespaceObject(mi)
                _ = heap.root(v)
                _ = heap.defineOwnProperty(ns, heap.key(n), .data(v, [.writable, .enumerable]))
            default: break
            }
            heap.popRoots(to: d)
        }
        _ = heap.defineOwnProperty(ns, .symbol(heap.symbolsWellKnown.toStringTag.handle), .data(string("Module"), []))
        _ = heap.preventExtensions(ns)
        return ns
    }

    public func moduleNamespace(url: String) -> JSValue? {
        guard let i = es.moduleMap[url], moduleRec(i).status >= JSModuleStatus.linked else { return nil }
        return try? moduleNamespaceObject(i)
    }

    func linkModule(_ root: Int) throws(JSThrow) {
        guard moduleRec(root).status == JSModuleStatus.new else { return }
        var list: [Int] = []
        var work = [root]
        var seen: Set<Int> = [root]
        while let m = work.popLast() {
            list.append(m)
            for r in moduleRec(m).requested where moduleRec(r).status == JSModuleStatus.new && seen.insert(r).inserted {
                work.append(r)
            }
        }
        do throws(JSThrow) {
            for m in list {
                let rec = moduleRec(m)
                rec.status = JSModuleStatus.linking
                rec.env = newEnvironment(parent: .undefined, info: rec.scopeInfo)
                if rec.info.metaSlot >= 0 {
                    let meta = heap.newObject(proto: .null)
                    heap.setSlot(rec.env, rec.info.metaSlot, meta)
                    _ = heap.createDataProperty(meta, heap.key("url"), string(rec.url))
                    es.importMetaHook?(self, rec.url, meta)
                }
            }
            for m in list {
                let rec = moduleRec(m)
                for imp in rec.info.imports {
                    guard imp.request < rec.requested.count else { throw throwSyntaxError("module request missing") }
                    let target = rec.requested[imp.request]
                    var value: JSValue
                    if let name = imp.importName {
                        var set: [(Int, String)] = []
                        switch resolveExport(target, name, &set) {
                        case .binding(let mi, let slot):
                            let ir = heap.newObject(proto: .null, kind: .internalObject, flags: [.user2])
                            heap.setSlots(ir, [moduleRec(mi).env])
                            heap.setInternalInt(ir, Int64(slot))
                            value = ir
                        case .namespace(let mi):
                            value = try moduleNamespaceObject(mi)
                        case .ambiguous:
                            throw throwSyntaxError("The requested module '" + rec.info.requests[imp.request] + "' contains conflicting star exports for name '" + name + "'")
                        case .notFound:
                            throw throwSyntaxError("The requested module '" + rec.info.requests[imp.request] + "' does not provide an export named '" + name + "'")
                        }
                    } else {
                        value = try moduleNamespaceObject(target)
                    }
                    heap.setSlot(rec.env, imp.slot, value)
                }
                // Indirect exports must resolve too.
                for e in rec.info.indirectExports where e.importName != nil {
                    var set: [(Int, String)] = []
                    switch resolveExport(m, e.name, &set) {
                    case .binding, .namespace: break
                    default:
                        throw throwSyntaxError("The requested module '" + rec.info.requests[e.request] + "' does not provide an export named '" + (e.importName ?? "") + "'")
                    }
                }
            }
            for m in list {
                let rec = moduleRec(m)
                guard let ic = code(ofCodeObject: rec.initCode), let bc = code(ofCodeObject: rec.bodyCode) else {
                    throw throwTypeError("module code missing")
                }
                let initFn = makeClosure(ic, env: rec.env)
                let r = heap.root(initFn)
                rec.body = makeClosure(bc, env: rec.env)
                _ = try call(initFn, this: .undefined, args: [])
                heap.popRoots(to: r.slot)
            }
        } catch {
            for m in list {
                let rec = moduleRec(m)
                rec.status = JSModuleStatus.new
                rec.env = .undefined
                rec.namespace = .undefined
                rec.body = .undefined
            }
            throw error
        }
        for m in list { moduleRec(m).status = JSModuleStatus.linked }
    }

    // MARK: Evaluation

    /// Evaluate(): the module's evaluation promise.
    func evaluateModuleRecord(_ root: Int) throws(JSThrow) -> JSValue {
        var m = root
        let st = moduleRec(m).status
        if (st == JSModuleStatus.evaluatingAsync || st == JSModuleStatus.evaluated) && moduleRec(m).cycleRoot >= 0 {
            m = moduleRec(m).cycleRoot
        }
        let rec = moduleRec(m)
        if rec.topPromise.isObject { return rec.topPromise }
        let p = newPromise()
        rec.topPromise = p
        var stack: [Int] = []
        do throws(JSThrow) {
            _ = try innerModuleEvaluation(m, &stack, 0, depth: 0)
            if !rec.asyncEvaluation { try resolvePromise(p, .undefined) }
        } catch {
            if heap.termination != nil { throw error }
            let e = takeException()
            let r = heap.root(e)
            defer { heap.popRoots(to: r.slot) }
            for s in stack {
                let sr = moduleRec(s)
                sr.status = JSModuleStatus.evaluated
                sr.hasError = true
                sr.error = e
            }
            rec.status = JSModuleStatus.evaluated
            rec.hasError = true
            rec.error = e
            rejectPromise(p, e)
        }
        return p
    }

    func innerModuleEvaluation(_ m: Int, _ stack: inout [Int], _ indexIn: Int, depth: Int) throws(JSThrow) -> Int {
        var index = indexIn
        let rec = moduleRec(m)
        if rec.status == JSModuleStatus.evaluatingAsync || rec.status == JSModuleStatus.evaluated {
            if rec.hasError { throw throwValue(rec.error) }
            return index
        }
        if rec.status == JSModuleStatus.evaluating { return index }
        if depth > 2000 { throw throwRangeError("Module graph too deep") }
        rec.status = JSModuleStatus.evaluating
        rec.dfsIndex = index
        rec.dfsAncestor = index
        rec.pendingDeps = 0
        index += 1
        stack.append(m)
        for r0 in rec.requested {
            index = try innerModuleEvaluation(r0, &stack, index, depth: depth + 1)
            var r = r0
            let req = moduleRec(r)
            if req.status == JSModuleStatus.evaluating {
                rec.dfsAncestor = min(rec.dfsAncestor, req.dfsAncestor)
            } else {
                if req.cycleRoot >= 0 { r = req.cycleRoot }
                if moduleRec(r).hasError { throw throwValue(moduleRec(r).error) }
            }
            if moduleRec(r).asyncEvaluation {
                rec.pendingDeps += 1
                moduleRec(r).asyncParents.append(m)
            }
        }
        if rec.pendingDeps > 0 || rec.info.hasTLA {
            rec.asyncEvaluation = true
            es.asyncOrder += 1
            rec.asyncOrder = es.asyncOrder
            if rec.pendingDeps == 0 { try executeModuleAsync(m) }
        } else {
            try executeModuleSync(m)
        }
        if rec.dfsAncestor == rec.dfsIndex {
            while let s = stack.popLast() {
                let sr = moduleRec(s)
                sr.status = sr.asyncEvaluation ? JSModuleStatus.evaluatingAsync : JSModuleStatus.evaluated
                sr.cycleRoot = m
                if s == m { break }
            }
        }
        return index
    }

    func executeModuleSync(_ m: Int) throws(JSThrow) {
        let p = try call(moduleRec(m).body, this: .undefined, args: [])
        guard isPromise(p) else { return }
        heap.setInternalInt(p, heap.internalInt(p) | 8)
        if heap.internalInt(p) & 3 == 2 { throw throwValue(heap.slot(p, 0)) }
    }

    func executeModuleAsync(_ m: Int) throws(JSThrow) {
        let p = try call(moduleRec(m).body, this: .undefined, args: [])
        guard isPromise(p) else { return }
        let r = heap.root(p)
        defer { heap.popRoots(to: r.slot) }
        performPromiseThen(p, es.modules[m], .undefined,
                           JSCapability(promise: .undefined, resolve: .undefined, reject: .undefined), type: 4)
    }

    /// Reaction type 4: an async module finished, or a dynamic import's
    /// evaluation promise settled (flag user3: [module handle, promise]).
    func moduleReaction(_ h: JSValue, _ v: JSValue, rejected: Bool) throws(JSThrow) {
        if heap.flags(h).contains(.user3) {
            let m = Int(heap.internalInt(heap.slot(h, 0)))
            let p = heap.slot(h, 1)
            if rejected { rejectPromise(p, v); return }
            do throws(JSThrow) {
                try resolvePromise(p, try moduleNamespaceObject(m))
            } catch {
                if heap.termination != nil { throw error }
                rejectPromise(p, takeException())
            }
            return
        }
        let m = Int(heap.internalInt(h))
        guard m >= 0 && m < es.moduleRecords.count else { return }
        if rejected { asyncModuleRejected(m, v) } else { try asyncModuleFulfilled(m) }
    }

    func asyncModuleFulfilled(_ m: Int) throws(JSThrow) {
        let rec = moduleRec(m)
        if rec.status == JSModuleStatus.evaluated { return }
        rec.asyncEvaluation = false
        rec.status = JSModuleStatus.evaluated
        if rec.topPromise.isObject { try resolvePromise(rec.topPromise, .undefined) }
        var list: [Int] = []
        gatherAvailableAncestors(m, &list)
        list.sort { moduleRec($0).asyncOrder < moduleRec($1).asyncOrder }
        for p in list {
            let pr = moduleRec(p)
            if pr.status == JSModuleStatus.evaluated && pr.hasError { continue }
            if pr.info.hasTLA {
                try executeModuleAsync(p)
            } else {
                do throws(JSThrow) {
                    try executeModuleSync(p)
                } catch {
                    if heap.termination != nil { throw error }
                    asyncModuleRejected(p, takeException())
                    continue
                }
                pr.asyncEvaluation = false
                pr.status = JSModuleStatus.evaluated
                if pr.topPromise.isObject { try resolvePromise(pr.topPromise, .undefined) }
            }
        }
    }

    func gatherAvailableAncestors(_ m: Int, _ list: inout [Int]) {
        for p in moduleRec(m).asyncParents {
            let pr = moduleRec(p)
            let root = pr.cycleRoot >= 0 ? pr.cycleRoot : p
            if list.contains(p) || moduleRec(root).hasError { continue }
            pr.pendingDeps -= 1
            if pr.pendingDeps == 0 {
                list.append(p)
                if !pr.info.hasTLA { gatherAvailableAncestors(p, &list) }
            }
        }
    }

    func asyncModuleRejected(_ m: Int, _ e: JSValue) {
        let rec = moduleRec(m)
        if rec.status == JSModuleStatus.evaluated && rec.hasError { return }
        rec.hasError = true
        rec.error = e
        rec.status = JSModuleStatus.evaluated
        rec.asyncEvaluation = false
        for p in rec.asyncParents { asyncModuleRejected(p, e) }
        if rec.topPromise.isObject { rejectPromise(rec.topPromise, e) }
    }

    func moduleBodyFinished(_ g: JSValue, ok: Bool, _ v: JSValue) throws(JSThrow) {}

    // MARK: Entry points

    func runModule(_ load: () throws(JSThrow) -> Int) -> JSCompletion {
        let outer = nativeDepth == 0 && frames.isEmpty
        if outer { stackFloor = jsVMStackFloor(limits) }
        let depth = heap.rootDepth
        defer { heap.popRoots(to: depth) }
        do throws(JSThrow) {
            let m = try load()
            try loadModuleGraph(m)
            try linkModule(m)
            let p = try evaluateModuleRecord(m)
            if heap.internalInt(p) & 3 == 2 {
                heap.setInternalInt(p, heap.internalInt(p) | 8)
                if let i = es.pendingRejections.firstIndex(of: p) { es.pendingRejections.remove(at: i) }
                throw throwValue(heap.slot(p, 0))
            }
            if outer && heap.termination == .interrupted { heap.clearTermination() }
            return .normal(p)
        } catch {
            return finishCompletion(outer: outer)
        }
    }

    public func evaluateModule(source: [UInt8], name: String) -> JSCompletion {
        runModule { () throws(JSThrow) -> Int in try self.registerModule(url: name, bytes: source) }
    }

    public func evaluateModule(source: String, name: String) -> JSCompletion {
        evaluateModule(source: Array(source.utf8), name: name)
    }

    public func importModule(_ specifier: String, referrer: String = "") -> JSCompletion {
        runModule { () throws(JSThrow) -> Int in try self.hostLoadModule(specifier, referrer: referrer) }
    }

    /// import(specifier): a promise; the work happens in a job.
    func dynamicImport(_ specifier: JSValue, referrer: String) throws(JSThrow) -> JSValue {
        let p = newPromise()
        let r = heap.root(p)
        defer { heap.popRoots(to: r.slot) }
        do throws(JSThrow) {
            let s = try toStringValue(specifier)
            _ = heap.root(s)
            let ref = string(referrer)
            enqueue(JSJob(kind: 5, a: p, b: s, c: ref))
        } catch {
            if heap.termination != nil { throw error }
            rejectPromise(p, takeException())
        }
        return p
    }

    func continueDynamicImport(_ p: JSValue, _ spec: JSValue, _ referrer: JSValue) throws(JSThrow) {
        do throws(JSThrow) {
            let m = try hostLoadModule(heap.swiftString(spec), referrer: heap.swiftString(referrer))
            try loadModuleGraph(m)
            try linkModule(m)
            let ep = try evaluateModuleRecord(m)
            let r = heap.root(ep)
            defer { heap.popRoots(to: r.slot) }
            let cont = heap.newObject(proto: .null, kind: .internalObject, flags: [.user3])
            heap.setSlots(cont, [es.modules[m], p])
            _ = heap.root(cont)
            performPromiseThen(ep, cont, .undefined,
                               JSCapability(promise: .undefined, resolve: .undefined, reject: .undefined), type: 4)
        } catch {
            if heap.termination != nil { throw error }
            rejectPromise(p, takeException())
        }
    }
}

func jsInstallModules(_ realm: JSRealm) {
    realm.es.namespaceGetterFn = realm.registerNative("", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let env = h.slot(args.callee, 0), slot = h.slot(args.callee, 1)
        let v = h.slot(env, slot.isInt32 ? Int(slot.asInt32) : 0)
        if v.isHole {
            throw realm.throwReferenceError("Cannot access '" + h.swiftString(h.slot(args.callee, 2)) + "' before initialization")
        }
        return v
    }
}
