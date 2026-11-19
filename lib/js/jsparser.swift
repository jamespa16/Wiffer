// lib/js parser: recursive descent from JSLexer tokens to a JSAST
// (jsast.swift documents the tree). ES2022 syntax, strict mode, the early
// errors, cover grammars for arrow parameters and destructuring
// assignment, and Annex B's web-compatibility rules for scripts.
//
// This file: entry point, token helpers, scopes, statements, functions,
// classes and modules. jsparser_expr.swift: expressions and patterns.
//
// Hostile input: recursion is counted (`enter`) and capped by
// JSLimits.maxASTDepth, the finished tree's height by maxASTHeight, and
// every loop consumes a token or fails, so the parser never traps and
// never overflows the stack.

struct JSParseOptions {
    /// Parse as a module (strict, import/export, top-level await, no HTML comments).
    var module = false
    /// Start in strict mode (scripts).
    var strict = false
    var limits = JSLimits()

    init(module: Bool = false, strict: Bool = false, limits: JSLimits = JSLimits()) {
        self.module = module
        self.strict = strict
        self.limits = limits
    }
}

/// Parse a script or module. The returned tree is a valid program.
func jsParse(_ source: [UInt8], _ options: JSParseOptions = JSParseOptions()) throws(JSSyntaxError) -> JSAST {
    if source.count > options.limits.maxSourceBytes {
        throw JSSyntaxError(message: "source too large", offset: 0, line: 1, column: 1)
    }
    let p = JSParser(source, options)
    try p.parseProgram()
    return p.ast
}

/// One function (or the top level) being parsed.
struct JSFnCtx {
    var strict = false
    /// await expressions are allowed (async function, module top level).
    var async = false
    /// await is reserved as an identifier.
    var awaitReserved = false
    var generator = false
    var arrow = false
    /// return is allowed.
    var isFunction = false
    var superProp = false
    var superCall = false
    var newTarget = false
    /// In a class field initializer or static block: `arguments` is an error.
    var noArguments = false
    var staticBlock = false
    var inParams = false
    var usesThis = false
    var usesArgs = false
    var hasEval = false
    var loopDepth = 0
    var breakDepth = 0
    var labelBase = 0
}

struct JSScope {
    /// 0 function or script top, 1 block, 2 catch, 3 module top
    var kind: UInt8
    var lexical: Set<Int32> = []
    var vars: Set<Int32> = []
    var params: Set<Int32> = []
    /// Lexical names that are plain functions in a sloppy block (Annex B
    /// lets those be declared twice).
    var sloppyFuncs: Set<Int32> = []
    init(_ kind: UInt8) { self.kind = kind }
}

struct JSLabel {
    var name: Int32
    var isLoop: Bool
}

/// Private names of one class body.
struct JSClassScope {
    /// name -> bits: 1 getter, 2 setter, 4 other, 8 static
    var declared: [Int32: UInt8] = [:]
    var refs: [(Int32, Int)] = []
}

final class JSParser {
    let ast: JSAST
    let lex: JSLexer
    let opts: JSParseOptions
    var tok = JSToken()
    var prevEnd = 0
    var peekTok = JSToken()
    var hasPeek = false

    var fn = JSFnCtx()
    var fnStack: [JSFnCtx] = []
    var scopes: [JSScope] = []
    var labels: [JSLabel] = []
    var pendingLabels = 0
    var classes: [JSClassScope] = []
    var depth = 0
    var scratch: [Int32] = []
    /// Bound names collected by binding patterns: (name, offset).
    var bound: [(Int32, Int)] = []

    /// Cover grammar bookkeeping (see parseAssignment): the position of a
    /// construct only valid in a pattern (`{a = 1}`, duplicate __proto__).
    var coverErrPos = -1
    var coverErrMsg = ""
    /// Last yield/await expression start (arrow parameters may not have them).
    var lastYieldAwait = -1
    /// Last `await` used as an identifier (async arrow parameters may not).
    var lastAwaitIdent = -1

    // Module bookkeeping.
    var exportedNames: Set<Int32> = []
    var exportRefs: [(Int32, Int)] = []

    init(_ source: [UInt8], _ options: JSParseOptions) {
        ast = JSAST(source: source)
        ast.isModule = options.module
        lex = JSLexer(ast)
        lex.htmlComments = !options.module
        opts = options
    }

    // ------------------------------------------------------------ errors

    func error(_ msg: String, _ offset: Int) -> JSSyntaxError { lex.fail(msg, offset) }

    func unexpected() -> JSSyntaxError {
        if tok.kind == .eof { return error("unexpected end of input", tok.start) }
        return error("unexpected token", tok.start)
    }

    @inline(__always) func enter() throws(JSSyntaxError) {
        depth += 1
        if depth > opts.limits.maxASTDepth { throw error("nesting too deep", tok.start) }
    }

    @inline(__always) func leave() { depth -= 1 }

    // ------------------------------------------------------------ tokens

    @inline(__always) func advance() throws(JSSyntaxError) {
        prevEnd = tok.end
        if hasPeek { tok = peekTok; hasPeek = false } else { tok = try lex.next() }
    }

    func peek() throws(JSSyntaxError) -> JSToken {
        if !hasPeek { peekTok = try lex.next(); hasPeek = true }
        return peekTok
    }

    /// The current token is the (unescaped) word `w`.
    @inline(__always) func isWord(_ w: Int32) -> Bool {
        tok.kind == .name && tok.value == w && !tok.escaped
    }

    @inline(__always) func eat(_ k: JSTok) throws(JSSyntaxError) -> Bool {
        if tok.kind == k { try advance(); return true }
        return false
    }

    func expect(_ k: JSTok) throws(JSSyntaxError) {
        if tok.kind != k { throw unexpected() }
        try advance()
    }

    func expectWord(_ w: Int32) throws(JSSyntaxError) {
        if !isWord(w) { throw unexpected() }
        try advance()
    }

    /// Automatic semicolon insertion.
    func semicolon() throws(JSSyntaxError) {
        if tok.kind == .semicolon { try advance(); return }
        if tok.kind == .rbrace || tok.kind == .eof || tok.nl { return }
        throw unexpected()
    }

    func rescanRegExp() throws(JSSyntaxError) {
        let nl = tok.nl
        hasPeek = false
        tok = try lex.rescanRegExp(tok.start)
        tok.nl = nl
    }

    func rescanTemplate() throws(JSSyntaxError) {
        hasPeek = false
        tok = try lex.rescanTemplate(tok.start)
    }

    // ------------------------------------------------------------ nodes

    @inline(__always)
    func node(_ kind: JSNodeKind, _ start: Int, op: UInt8 = 0, flags: UInt16 = 0,
              _ a: Int32 = -1, _ b: Int32 = -1, _ c: Int32 = -1, _ d: Int32 = -1) throws(JSSyntaxError) -> Int32 {
        if ast.nodes.count >= opts.limits.maxASTNodes { throw error("program too large", start) }
        ast.nodes.append(JSNode(kind: kind, op: op, flags: flags, start: UInt32(truncatingIfNeeded: start),
                                end: UInt32(truncatingIfNeeded: prevEnd), a: a, b: b, c: c, d: d))
        return Int32(truncatingIfNeeded: ast.nodes.count - 1)
    }

    @inline(__always) func k(_ n: Int32) -> JSNodeKind { ast.nodes[Int(n)].kind }

    @inline(__always) func isParen(_ n: Int32) -> Bool {
        ast.nodes[Int(n)].flags & JSNodeFlags.parenthesized != 0
    }

    /// Move scratch[mark...] into ast.lists; returns (start, count).
    func finishList(_ mark: Int) -> (Int32, Int32) {
        let start = Int32(truncatingIfNeeded: ast.lists.count)
        let count = Int32(truncatingIfNeeded: scratch.count - mark)
        ast.lists.append(contentsOf: scratch[mark...])
        scratch.removeSubrange(mark...)
        return (start, count)
    }

    // ------------------------------------------------------------ scopes

    func pushScope(_ kind: UInt8) { scopes.append(JSScope(kind)) }
    func popScope() { scopes.removeLast() }

    func declareLexical(_ name: Int32, _ pos: Int, sloppyFunction: Bool = false) throws(JSSyntaxError) {
        let i = scopes.count - 1
        if i < 0 { return }
        if scopes[i].lexical.contains(name) {
            if sloppyFunction && scopes[i].sloppyFuncs.contains(name) { return }
            throw error("redeclaration of '\(ast.text(name))'", pos)
        }
        if scopes[i].vars.contains(name) || scopes[i].params.contains(name) {
            throw error("redeclaration of '\(ast.text(name))'", pos)
        }
        scopes[i].lexical.insert(name)
        if sloppyFunction { scopes[i].sloppyFuncs.insert(name) }
    }

    func declareVar(_ name: Int32, _ pos: Int, forOf: Bool = false) throws(JSSyntaxError) {
        var i = scopes.count - 1
        while i >= 0 {
            if scopes[i].lexical.contains(name) {
                throw error("redeclaration of '\(ast.text(name))'", pos)
            }
            if forOf && scopes[i].kind == 2 && scopes[i].params.contains(name) {
                throw error("redeclaration of '\(ast.text(name))'", pos)
            }
            scopes[i].vars.insert(name)
            if scopes[i].kind == 0 || scopes[i].kind == 3 { break }
            i -= 1
        }
    }

    /// A function declaration at the top of a function or script body.
    func declareTopFunction(_ name: Int32, _ pos: Int) throws(JSSyntaxError) {
        let i = scopes.count - 1
        if i < 0 { return }
        if scopes[i].lexical.contains(name) { throw error("redeclaration of '\(ast.text(name))'", pos) }
        scopes[i].vars.insert(name)
    }

    func declareBound(_ mark: Int, _ kind: JSVarKind, forOf: Bool = false) throws(JSSyntaxError) {
        var i = mark
        while i < bound.count {
            let (name, pos) = bound[i]
            if kind == .var {
                try declareVar(name, pos, forOf: forOf)
            } else {
                if name == JSWord.let_ { throw error("'let' is not a valid lexical name", pos) }
                try declareLexical(name, pos)
            }
            i += 1
        }
        bound.removeSubrange(mark...)
    }

    // ------------------------------------------------------------ contexts

    func pushFn(_ f: JSFnCtx) {
        fnStack.append(fn)
        fn = f
        fn.labelBase = labels.count
    }

    func popFn() {
        let child = fn
        fn = fnStack.removeLast()
        if child.hasEval { fn.hasEval = true }
        if child.arrow {
            if child.usesThis { fn.usesThis = true }
            if child.usesArgs { fn.usesArgs = true }
        }
    }

    // ------------------------------------------------------------ identifiers

    /// Check a name used as a binding identifier or identifier reference.
    func checkIdentifier(_ t: JSToken, binding: Bool) throws(JSSyntaxError) {
        let id = t.value
        if id < JSWord.reservedCount {
            throw error("unexpected reserved word", t.start)
        }
        if id <= JSWord.yield_ {
            if fn.strict && JSWord.isStrictReserved(id) {
                throw error("'\(ast.text(id))' is reserved in strict mode", t.start)
            }
            if id == JSWord.yield_ && (fn.generator || (fn.inParams && fn.generator)) {
                throw error("'yield' is not a valid identifier here", t.start)
            }
        } else if id == JSWord.await_ {
            if fn.awaitReserved || fn.async || opts.module {
                throw error("'await' is not a valid identifier here", t.start)
            }
            lastAwaitIdent = t.start
        } else if id == JSWord.eval || id == JSWord.arguments {
            if binding && fn.strict { throw error("cannot bind '\(ast.text(id))' in strict mode", t.start) }
            if id == JSWord.arguments && !binding {
                if fn.noArguments { throw error("'arguments' is not allowed in class field initializers", t.start) }
                fn.usesArgs = true
            }
        }
    }

    /// The current token as a binding identifier; consumes it.
    func parseBindingIdentifier() throws(JSSyntaxError) -> Int32 {
        guard tok.kind == .name else { throw unexpected() }
        try checkIdentifier(tok, binding: true)
        let start = tok.start, id = tok.value
        bound.append((id, start))
        try advance()
        return try node(.identifier, start, id)
    }

    // ------------------------------------------------------------ program

    func parseProgram() throws(JSSyntaxError) {
        fn.strict = opts.strict || opts.module
        if opts.module {
            fn.async = true
            fn.awaitReserved = true
        }
        pushScope(opts.module ? 3 : 0)
        try advance()
        let mark = scratch.count
        var flags: UInt16 = 0
        if !opts.module {
            if try parseDirectives() { flags |= JSNodeFlags.hasUseStrict }
        }
        while tok.kind != .eof {
            scratch.append(try parseStatementListItem())
        }
        if opts.module {
            for (name, pos) in exportRefs {
                let s = scopes[0]
                if !s.lexical.contains(name) && !s.vars.contains(name) {
                    throw error("export of undeclared '\(ast.text(name))'", pos)
                }
            }
        }
        if fn.strict { flags |= JSNodeFlags.strict }
        if fn.hasEval { flags |= JSNodeFlags.hasDirectEval }
        let (ls, lc) = finishList(mark)
        prevEnd = tok.end
        ast.root = try node(opts.module ? .module : .script, 0, flags: flags, ls, lc)
        if ast.height() > opts.limits.maxASTHeight { throw error("nesting too deep", 0) }
    }

    /// The directive prologue at the start of a body; statements go to
    /// scratch. Returns whether it contained "use strict" (fn.strict is set).
    func parseDirectives() throws(JSSyntaxError) -> Bool {
        var useStrict = false
        var octalPos = -1
        while tok.kind == .string {
            let t = tok
            let stmt = try parseStatementListItem()
            scratch.append(stmt)
            let s = ast.nodes[Int(stmt)]
            guard s.kind == .exprStmt else { break }
            let e = ast.nodes[Int(s.a)]
            guard e.kind == .string && Int(e.start) == t.start && Int(e.end) == t.end
                    && e.flags & JSNodeFlags.parenthesized == 0 else { break }
            ast.nodes[Int(stmt)].flags |= JSNodeFlags.directive
            if t.flags & JSNodeFlags.octalEscape != 0 && octalPos < 0 { octalPos = t.start }
            if t.end - t.start == 12 && isUseStrictRaw(t.start + 1) {
                useStrict = true
                if !fn.strict {
                    fn.strict = true
                    if octalPos >= 0 { throw error("octal escape sequences are not allowed in strict mode", octalPos) }
                    // The token after the directive was read before strict
                    // mode started; recheck it.
                    if tok.kind == .name && JSWord.isStrictReserved(tok.value) && tok.value != JSWord.yield_
                        && tok.value != JSWord.let_ && tok.value != JSWord.static_ {
                        // parsed later with strict set: nothing to do
                    }
                }
            }
        }
        return useStrict
    }

    private func isUseStrictRaw(_ at: Int) -> Bool {
        let w: StaticString = "use strict"
        let p = w.utf8Start
        let src = ast.source
        for i in 0..<10 { if at + i >= src.count || src[at + i] != p[i] { return false } }
        return true
    }

    // ------------------------------------------------------------ statements

    func parseStatementListItem() throws(JSSyntaxError) -> Int32 {
        if tok.kind == .name && !tok.escaped {
            switch tok.value {
            case JSWord.function_:
                return try parseFunctionDeclaration(tok.start, async: false, inBlock: scopes.last?.kind == 1 || scopes.last?.kind == 2)
            case JSWord.class_:
                return try parseClass(isDecl: true)
            case JSWord.const_:
                return try parseLexicalDeclaration(.const)
            case JSWord.let_:
                if try isLetDeclaration() { return try parseLexicalDeclaration(.let) }
            case JSWord.async_:
                let p = try peek()
                if p.kind == .name && p.value == JSWord.function_ && !p.escaped && !p.nl {
                    let start = tok.start
                    try advance()
                    return try parseFunctionDeclaration(start, async: true, inBlock: scopes.last?.kind == 1 || scopes.last?.kind == 2)
                }
            case JSWord.import_:
                let p = try peek()
                if p.kind != .lparen && p.kind != .dot {
                    if !opts.module { throw error("import declarations may only appear in a module", tok.start) }
                    if scopes.count != 1 || !fnStack.isEmpty { throw error("import must be at the top level", tok.start) }
                    return try parseImport()
                }
            case JSWord.export_:
                if !opts.module { throw error("export declarations may only appear in a module", tok.start) }
                if scopes.count != 1 || !fnStack.isEmpty { throw error("export must be at the top level", tok.start) }
                return try parseExport()
            default: break
            }
        }
        return try parseStatement()
    }

    /// `let` starts a declaration if followed by [, { or a name.
    func isLetDeclaration() throws(JSSyntaxError) -> Bool {
        let p = try peek()
        if p.kind == .lbracket || p.kind == .lbrace { return true }
        if p.kind == .name {
            // `let` then a reserved word on the next line is `let;` + statement
            if p.nl && p.value < JSWord.reservedCount && !p.escaped { return false }
            return true
        }
        return false
    }

    func parseLexicalDeclaration(_ kind: JSVarKind) throws(JSSyntaxError) -> Int32 {
        let start = tok.start
        try advance()
        let n = try parseDeclarations(kind, start, inFor: false)
        try semicolon()
        ast.nodes[Int(n)].end = UInt32(truncatingIfNeeded: prevEnd)
        return n
    }

    /// Declarators after var/let/const (already consumed).
    func parseDeclarations(_ kind: JSVarKind, _ start: Int, inFor: Bool) throws(JSSyntaxError) -> Int32 {
        let mark = scratch.count
        while true {
            let dstart = tok.start
            let bmark = bound.count
            let target = try parseBindingTarget()
            var initv: Int32 = -1
            if tok.kind == .assign {
                try advance()
                initv = try parseAssignment(noIn: inFor)
            } else if !(inFor && (isWord(JSWord.of) || isWord(JSWord.in_))) {
                if kind == .const { throw error("missing initializer in const declaration", tok.start) }
                if k(target) != .identifier { throw error("missing initializer in destructuring declaration", tok.start) }
            }
            let forOf = inFor && isWord(JSWord.of)
            try declareBound(bmark, kind, forOf: forOf)
            scratch.append(try node(.declarator, dstart, target, initv))
            if tok.kind != .comma { break }
            try advance()
        }
        let (ls, lc) = finishList(mark)
        return try node(.varDecl, start, op: kind.rawValue, ls, lc)
    }

    func parseStatement() throws(JSSyntaxError) -> Int32 {
        try enter()
        defer { leave() }
        let myLabels = pendingLabels
        pendingLabels = 0
        let start = tok.start
        switch tok.kind {
        case .lbrace:
            return try parseBlock()
        case .semicolon:
            try advance()
            return try node(.empty, start)
        case .name where !tok.escaped:
            switch tok.value {
            case JSWord.var_:
                try advance()
                let n = try parseDeclarations(.var, start, inFor: false)
                try semicolon()
                ast.nodes[Int(n)].end = UInt32(truncatingIfNeeded: prevEnd)
                return n
            case JSWord.if_: return try parseIf()
            case JSWord.for_: return try parseFor(myLabels)
            case JSWord.while_:
                try advance()
                try expect(.lparen)
                let test = try parseExpression(noIn: false)
                try expect(.rparen)
                let body = try parseLoopBody(myLabels)
                return try node(.whileStmt, start, test, body)
            case JSWord.do_:
                try advance()
                let body = try parseLoopBody(myLabels)
                try expectWord(JSWord.while_)
                try expect(.lparen)
                let test = try parseExpression(noIn: false)
                try expect(.rparen)
                _ = try eat(.semicolon)
                return try node(.doWhile, start, body, test)
            case JSWord.continue_, JSWord.break_:
                return try parseJump(tok.value == JSWord.continue_)
            case JSWord.return_:
                if !fn.isFunction { throw error("return outside of a function", start) }
                try advance()
                var arg: Int32 = -1
                if tok.kind != .semicolon && tok.kind != .rbrace && tok.kind != .eof && !tok.nl {
                    arg = try parseExpression(noIn: false)
                }
                try semicolon()
                return try node(.returnStmt, start, arg)
            case JSWord.with_:
                if fn.strict { throw error("with is not allowed in strict mode", start) }
                try advance()
                try expect(.lparen)
                let obj = try parseExpression(noIn: false)
                try expect(.rparen)
                let body = try parseSubStatement()
                return try node(.withStmt, start, obj, body)
            case JSWord.switch_: return try parseSwitch()
            case JSWord.throw_:
                try advance()
                if tok.nl { throw error("no line break is allowed after 'throw'", tok.start) }
                let arg = try parseExpression(noIn: false)
                try semicolon()
                return try node(.throwStmt, start, arg)
            case JSWord.try_: return try parseTry()
            case JSWord.debugger_:
                try advance()
                try semicolon()
                return try node(.debugger, start)
            case JSWord.function_:
                throw error("function declarations are not allowed here", start)
            case JSWord.class_:
                throw error("class declarations are not allowed here", start)
            case JSWord.const_:
                throw error("lexical declarations are not allowed here", start)
            case JSWord.let_:
                if try peek().kind == .lbracket { throw error("lexical declarations are not allowed here", start) }
            case JSWord.async_:
                let p = try peek()
                if p.kind == .name && p.value == JSWord.function_ && !p.escaped && !p.nl {
                    throw error("async function declarations are not allowed here", start)
                }
            case JSWord.import_:
                let p = try peek()
                if p.kind != .lparen && p.kind != .dot {
                    throw error(opts.module ? "import must be at the top level" : "import declarations may only appear in a module", start)
                }
            case JSWord.export_:
                throw error(opts.module ? "export must be at the top level" : "export declarations may only appear in a module", start)
            default: break
            }
        default: break
        }
        // Expression statement or labelled statement.
        let isName = tok.kind == .name
        let labelTok = tok
        let expr = try parseExpression(noIn: false)
        if isName && tok.kind == .colon && k(expr) == .identifier && !isParen(expr)
            && Int(ast.nodes[Int(expr)].end) == labelTok.end {
            return try parseLabeled(start, labelTok, myLabels)
        }
        try semicolon()
        return try node(.exprStmt, start, expr)
    }

    /// The body of if/with/labels: a statement, or (Annex B, sloppy) a
    /// plain function declaration as if in its own block.
    func parseSubStatement(allowFunction: Bool = false) throws(JSSyntaxError) -> Int32 {
        if allowFunction && !fn.strict && isWord(JSWord.function_) {
            let p = try peek()
            if p.kind == .star { throw error("generator declarations are not allowed here", tok.start) }
            pushScope(1)
            let f = try parseFunctionDeclaration(tok.start, async: false, inBlock: true)
            popScope()
            return f
        }
        return try parseStatement()
    }

    func parseLoopBody(_ myLabels: Int) throws(JSSyntaxError) -> Int32 {
        var i = labels.count - myLabels
        while i < labels.count { labels[i].isLoop = true; i += 1 }
        fn.loopDepth += 1
        fn.breakDepth += 1
        defer { fn.loopDepth -= 1; fn.breakDepth -= 1 }
        return try parseStatement()
    }

    func parseBlock() throws(JSSyntaxError) -> Int32 {
        let start = tok.start
        try expect(.lbrace)
        pushScope(1)
        let mark = scratch.count
        while tok.kind != .rbrace {
            if tok.kind == .eof { throw unexpected() }
            scratch.append(try parseStatementListItem())
        }
        try advance()
        popScope()
        let (ls, lc) = finishList(mark)
        return try node(.block, start, ls, lc)
    }

    func parseIf() throws(JSSyntaxError) -> Int32 {
        let start = tok.start
        try advance()
        try expect(.lparen)
        let test = try parseExpression(noIn: false)
        try expect(.rparen)
        let cons = try parseSubStatement(allowFunction: true)
        var alt: Int32 = -1
        if isWord(JSWord.else_) {
            try advance()
            alt = try parseSubStatement(allowFunction: true)
        }
        return try node(.ifStmt, start, test, cons, alt)
    }

    func parseJump(_ isContinue: Bool) throws(JSSyntaxError) -> Int32 {
        let start = tok.start
        try advance()
        var label: Int32 = -1
        if tok.kind == .name && !tok.nl && !(tok.value < JSWord.reservedCount && !tok.escaped) {
            try checkIdentifier(tok, binding: false)
            label = tok.value
            var found = false
            var i = labels.count - 1
            while i >= fn.labelBase {
                if labels[i].name == label {
                    if isContinue && !labels[i].isLoop { throw error("continue target is not a loop", tok.start) }
                    found = true
                    break
                }
                i -= 1
            }
            if !found { throw error("undefined label '\(ast.text(label))'", tok.start) }
            try advance()
        } else if isContinue ? fn.loopDepth == 0 : fn.breakDepth == 0 {
            throw error(isContinue ? "continue outside of a loop" : "break outside of a loop or switch", start)
        }
        try semicolon()
        return try node(isContinue ? .continueStmt : .breakStmt, start, label)
    }

    func parseLabeled(_ start: Int, _ t: JSToken, _ myLabels: Int) throws(JSSyntaxError) -> Int32 {
        // The identifier was already checked as a reference.
        if t.value == JSWord.yield_ && (fn.generator || fn.strict) { throw error("invalid label", t.start) }
        if t.value == JSWord.await_ && (fn.async || fn.awaitReserved || opts.module) { throw error("invalid label", t.start) }
        var i = labels.count - 1
        while i >= fn.labelBase {
            if labels[i].name == t.value { throw error("duplicate label '\(ast.text(t.value))'", t.start) }
            i -= 1
        }
        // The expression node for the label is left unused in the tree.
        try advance() // ':'
        labels.append(JSLabel(name: t.value, isLoop: false))
        pendingLabels = myLabels + 1
        defer { labels.removeLast() }
        let body: Int32
        if isWord(JSWord.function_) {
            pendingLabels = 0
            if fn.strict { throw error("function declarations are not allowed here", tok.start) }
            if try peek().kind == .star { throw error("generator declarations are not allowed here", tok.start) }
            body = try parseFunctionDeclaration(tok.start, async: false, inBlock: scopes.last?.kind == 1 || scopes.last?.kind == 2)
        } else {
            body = try parseStatement()
        }
        return try node(.labeled, start, t.value, body)
    }

    func parseFor(_ myLabels: Int) throws(JSSyntaxError) -> Int32 {
        let start = tok.start
        try advance()
        var isAwait = false
        if isWord(JSWord.await_) {
            if !fn.async || fn.inParams { throw error("for await is only valid in async functions", tok.start) }
            isAwait = true
            try advance()
        }
        try expect(.lparen)
        pushScope(1)
        defer { popScope() }
        var initv: Int32 = -1
        if tok.kind == .semicolon {
            if isAwait { throw unexpected() }
        } else {
            let istart = tok.start
            var declKind: JSVarKind? = nil
            if isWord(JSWord.var_) { declKind = .var }
            else if isWord(JSWord.const_) { declKind = .const }
            else if isWord(JSWord.let_) {
                let p = try peek()
                if p.kind == .lbracket || p.kind == .lbrace || (p.kind == .name && !(p.value == JSWord.in_ && !p.escaped)) {
                    declKind = .let
                }
            }
            if let dk = declKind {
                try advance()
                let decl = try parseDeclarations(dk, istart, inFor: true)
                let d = ast.nodes[Int(decl)]
                if isWord(JSWord.of) || isWord(JSWord.in_) {
                    let isOf = isWord(JSWord.of)
                    if d.b != 1 { throw error("only one binding is allowed in a for-\(isOf ? "of" : "in") head", istart) }
                    let decl0 = ast.lists[Int(d.a)]
                    let dn = ast.nodes[Int(decl0)]
                    if dn.b >= 0 {
                        // Annex B: `for (var x = 1 in o)` in sloppy mode.
                        if isOf || fn.strict || dk != .var || k(dn.a) != .identifier {
                            throw error("for-\(isOf ? "of" : "in") declarations may not have initializers", istart)
                        }
                    }
                    return try parseForInOf(start, decl, isOf: isOf, isAwait: isAwait, myLabels)
                }
                if isAwait { throw unexpected() }
                initv = decl
            } else {
                let startsWithLet = isWord(JSWord.let_)
                let startsWithAsync = isWord(JSWord.async_)
                let savedErr = coverErrPos
                coverErrPos = -1
                let e = try parseExpressionCover(noIn: true)
                if isWord(JSWord.of) || isWord(JSWord.in_) {
                    let isOf = isWord(JSWord.of)
                    if isOf && startsWithLet { throw error("for-of may not start with 'let'", istart) }
                    if isOf && !isAwait && startsWithAsync && k(e) == .identifier && !isParen(e)
                        && ast.nodes[Int(e)].a == JSWord.async_ {
                        throw error("for-of may not start with 'async of'", istart)
                    }
                    try toAssignTarget(e, allowPattern: true)
                    coverErrPos = savedErr
                    return try parseForInOf(start, e, isOf: isOf, isAwait: isAwait, myLabels)
                }
                if coverErrPos >= 0 { throw error(coverErrMsg, coverErrPos) }
                coverErrPos = savedErr
                if isAwait { throw unexpected() }
                initv = e
            }
        }
        try expect(.semicolon)
        var test: Int32 = -1, update: Int32 = -1
        if tok.kind != .semicolon { test = try parseExpression(noIn: false) }
        try expect(.semicolon)
        if tok.kind != .rparen { update = try parseExpression(noIn: false) }
        try expect(.rparen)
        let body = try parseLoopBody(myLabels)
        return try node(.forStmt, start, initv, test, update, body)
    }

    func parseForInOf(_ start: Int, _ left: Int32, isOf: Bool, isAwait: Bool, _ myLabels: Int) throws(JSSyntaxError) -> Int32 {
        if isAwait && !isOf { throw unexpected() }
        try advance() // of / in
        let right = isOf ? try parseAssignment(noIn: false) : try parseExpression(noIn: false)
        try expect(.rparen)
        let body = try parseLoopBody(myLabels)
        return try node(isOf ? .forOf : .forIn, start, flags: isAwait ? JSNodeFlags.await : 0, left, right, body)
    }

    func parseSwitch() throws(JSSyntaxError) -> Int32 {
        let start = tok.start
        try advance()
        try expect(.lparen)
        let disc = try parseExpression(noIn: false)
        try expect(.rparen)
        try expect(.lbrace)
        pushScope(1)
        fn.breakDepth += 1
        let mark = scratch.count
        var sawDefault = false
        while tok.kind != .rbrace {
            let cstart = tok.start
            var test: Int32 = -1
            if isWord(JSWord.case_) {
                try advance()
                test = try parseExpression(noIn: false)
            } else if isWord(JSWord.default_) {
                if sawDefault { throw error("more than one default clause in switch", cstart) }
                sawDefault = true
                try advance()
            } else {
                throw unexpected()
            }
            try expect(.colon)
            let bmark = scratch.count
            while tok.kind != .rbrace && !isWord(JSWord.case_) && !isWord(JSWord.default_) {
                if tok.kind == .eof { throw unexpected() }
                scratch.append(try parseStatementListItem())
            }
            let (ls, lc) = finishList(bmark)
            scratch.append(try node(.switchCase, cstart, test, ls, lc))
        }
        try advance()
        fn.breakDepth -= 1
        popScope()
        let (ls, lc) = finishList(mark)
        return try node(.switchStmt, start, disc, ls, lc)
    }

    func parseTry() throws(JSSyntaxError) -> Int32 {
        let start = tok.start
        try advance()
        let block = try parseBlock()
        var param: Int32 = -1, handler: Int32 = -1, fin: Int32 = -1
        if isWord(JSWord.catch_) {
            try advance()
            pushScope(2)
            if try eat(.lparen) {
                let bmark = bound.count
                param = try parseBindingTarget()
                if k(param) == .identifier {
                    scopes[scopes.count - 1].params.insert(ast.nodes[Int(param)].a)
                    bound.removeSubrange(bmark...)
                } else {
                    try declareBound(bmark, .let)
                }
                try expect(.rparen)
            }
            let hstart = tok.start
            try expect(.lbrace)
            let mark = scratch.count
            while tok.kind != .rbrace {
                if tok.kind == .eof { throw unexpected() }
                scratch.append(try parseStatementListItem())
            }
            try advance()
            popScope()
            let (ls, lc) = finishList(mark)
            handler = try node(.block, hstart, ls, lc)
        }
        if isWord(JSWord.finally_) {
            try advance()
            fin = try parseBlock()
        }
        if handler < 0 && fin < 0 { throw error("missing catch or finally after try", tok.start) }
        return try node(.tryStmt, start, block, param, handler, fin)
    }

    // ------------------------------------------------------------ functions

    /// `function` [*] name (...) {...} as a declaration; `async` (if any)
    /// was consumed and `start` is its offset.
    func parseFunctionDeclaration(_ start: Int, async: Bool, inBlock: Bool, defaultExport: Bool = false) throws(JSSyntaxError) -> Int32 {
        try advance() // function
        let generator = try eat(.star)
        var id: Int32 = -1
        if tok.kind == .name {
            let nameTok = tok
            // Declarations check the name in the enclosing context.
            try checkIdentifier(tok, binding: true)
            try advance()
            id = try node(.identifier, nameTok.start, nameTok.value)
            let name = nameTok.value
            if inBlock {
                try declareLexical(name, nameTok.start, sloppyFunction: !fn.strict && !async && !generator)
            } else if scopes.last?.kind == 3 {
                try declareLexical(name, nameTok.start)
            } else {
                try declareTopFunction(name, nameTok.start)
            }
        } else if !defaultExport {
            throw unexpected()
        }
        return try parseFunctionRest(start, id: id, kind: .normal, async: async, generator: generator,
                                     flags: JSNodeFlags.declaration)
    }

    func parseFunctionExpression(_ start: Int, async: Bool) throws(JSSyntaxError) -> Int32 {
        try advance() // function
        let generator = try eat(.star)
        var id: Int32 = -1
        if tok.kind == .name {
            // The name is checked in the function's own context.
            var saved = fn
            saved.generator = generator
            saved.async = async
            saved.awaitReserved = async || (fn.awaitReserved && opts.module)
            if !opts.module && !async { saved.awaitReserved = false }
            let outer = fn
            fn = saved
            let nameTok = tok
            do { try checkIdentifier(tok, binding: true) } catch { fn = outer; throw error }
            fn = outer
            try advance()
            id = try node(.identifier, nameTok.start, nameTok.value)
        }
        return try parseFunctionRest(start, id: id, kind: .normal, async: async, generator: generator,
                                     flags: JSNodeFlags.expression)
    }

    /// Parameters and body of any non-arrow function; tok is at '('.
    func parseFunctionRest(_ start: Int, id: Int32, kind: JSFunctionKind, async: Bool, generator: Bool,
                           flags: UInt16, classCtx: Bool = false) throws(JSSyntaxError) -> Int32 {
        try enter()
        defer { leave() }
        var f = JSFnCtx()
        f.strict = fn.strict || classCtx
        f.async = async
        f.awaitReserved = async || opts.module
        f.generator = generator
        f.isFunction = true
        f.newTarget = true
        f.superProp = kind != .normal
        f.superCall = kind == .derivedConstructor
        let savedYA = lastYieldAwait, savedAI = lastAwaitIdent
        pushFn(f)
        pushScope(0)
        let savedLabels = labels
        labels = []
        fn.labelBase = 0
        let savedPending = pendingLabels
        pendingLabels = 0
        defer {
            labels = savedLabels
            pendingLabels = savedPending
            lastYieldAwait = savedYA
            lastAwaitIdent = savedAI
        }

        try expect(.lparen)
        let bmark = bound.count
        let pmark = scratch.count
        fn.inParams = true
        var simple = true
        while tok.kind != .rparen {
            let pstart = tok.start
            if tok.kind == .ellipsis {
                try advance()
                let t = try parseBindingTarget()
                simple = false
                scratch.append(try node(.rest, pstart, t))
                if tok.kind != .rparen { throw error("rest parameter must be last", tok.start) }
                break
            }
            let t = try parseBindingTarget()
            if k(t) != .identifier { simple = false }
            if tok.kind == .assign {
                try advance()
                let def = try parseAssignment(noIn: false)
                simple = false
                scratch.append(try node(.assignPattern, pstart, t, def))
            } else {
                scratch.append(t)
            }
            if tok.kind != .comma { break }
            try advance()
        }
        try expect(.rparen)
        fn.inParams = false
        let (ps, pc) = finishList(pmark)
        if kind == .getter && pc != 0 { throw error("getters take no parameters", start) }
        if kind == .setter && (pc != 1 || k(ast.lists[Int(ps)]) == .rest) {
            throw error("setters take exactly one parameter", start)
        }
        let params = Array(bound[bmark...])
        bound.removeSubrange(bmark...)
        for (name, _) in params { scopes[scopes.count - 1].params.insert(name) }

        let body = try parseFunctionBody(simpleParams: simple)
        let strict = fn.strict
        try checkParams(params, strict: strict,
                        noDuplicates: strict || !simple || kind != .normal)
        if strict && !(fnStack.last?.strict ?? false) && id >= 0 {
            let name = ast.nodes[Int(id)].a
            if name == JSWord.eval || name == JSWord.arguments || JSWord.isStrictReserved(name) {
                throw error("invalid function name in strict mode", Int(ast.nodes[Int(id)].start))
            }
        }
        var fl = flags
        if async { fl |= JSNodeFlags.async }
        if generator { fl |= JSNodeFlags.generator }
        if strict { fl |= JSNodeFlags.strict }
        if simple { fl |= JSNodeFlags.simpleParams }
        if fn.usesArgs { fl |= JSNodeFlags.usesArguments }
        if fn.usesThis { fl |= JSNodeFlags.usesThis }
        if fn.hasEval { fl |= JSNodeFlags.hasDirectEval }
        if ast.nodes[Int(body)].op == 1 { fl |= JSNodeFlags.hasUseStrict; ast.nodes[Int(body)].op = 0 }
        popScope()
        popFn()
        return try node(.function, start, op: kind.rawValue, flags: fl, id, ps, pc, body)
    }

    /// `{ directives statements }` in the current function context.
    func parseFunctionBody(simpleParams: Bool) throws(JSSyntaxError) -> Int32 {
        let start = tok.start
        try expect(.lbrace)
        let mark = scratch.count
        let wasStrict = fn.strict
        let useStrict = try parseDirectives()
        if useStrict && !simpleParams {
            throw error("\"use strict\" is not allowed in a function with non-simple parameters", start)
        }
        _ = wasStrict
        while tok.kind != .rbrace {
            if tok.kind == .eof { throw unexpected() }
            scratch.append(try parseStatementListItem())
        }
        try advance()
        let (ls, lc) = finishList(mark)
        // op 1 carries "has use strict" up to the function node.
        return try node(.functionBody, start, op: useStrict ? 1 : 0, ls, lc)
    }

    func checkParams(_ params: [(Int32, Int)], strict: Bool, noDuplicates: Bool) throws(JSSyntaxError) {
        if strict {
            for (name, pos) in params {
                if name == JSWord.eval || name == JSWord.arguments {
                    throw error("cannot bind '\(ast.text(name))' in strict mode", pos)
                }
                if JSWord.isStrictReserved(name) {
                    throw error("'\(ast.text(name))' is reserved in strict mode", pos)
                }
            }
        }
        if noDuplicates && params.count > 1 {
            var seen: Set<Int32> = []
            for (name, pos) in params {
                if !seen.insert(name).inserted { throw error("duplicate parameter '\(ast.text(name))'", pos) }
            }
        }
    }

    /// An arrow function from already-parsed parameters (scratch[pmark...],
    /// converted to binding targets); tok is at `=>`.
    func parseArrowBody(_ start: Int, _ pmark: Int, async: Bool, noIn: Bool) throws(JSSyntaxError) -> Int32 {
        if tok.nl { throw unexpected() }
        try advance() // =>
        try enter()
        defer { leave() }
        var f = fn
        f.arrow = true
        f.async = async
        f.awaitReserved = async || fn.awaitReserved || fn.async || opts.module
        f.generator = false
        f.inParams = false
        f.usesThis = false
        f.usesArgs = false
        f.hasEval = false
        f.loopDepth = 0
        f.breakDepth = 0
        f.isFunction = true
        let (ps, pc) = finishList(pmark)
        // Bound names of the parameters.
        let bmark = bound.count
        var simple = true
        for p in ast.list(ps, pc) {
            if k(p) != .identifier { simple = false }
            collectBoundNames(p)
        }
        let params = Array(bound[bmark...])
        bound.removeSubrange(bmark...)
        let savedYA = lastYieldAwait, savedAI = lastAwaitIdent
        pushFn(f)
        pushScope(0)
        let savedLabels = labels
        labels = []
        fn.labelBase = 0
        let savedPending = pendingLabels
        pendingLabels = 0
        defer {
            labels = savedLabels
            pendingLabels = savedPending
            lastYieldAwait = savedYA
            lastAwaitIdent = savedAI
        }
        for (name, pos) in params {
            if async && name == JSWord.await_ { throw error("'await' is not a valid parameter name here", pos) }
            scopes[scopes.count - 1].params.insert(name)
        }
        var fl: UInt16 = JSNodeFlags.expression
        let body: Int32
        if tok.kind == .lbrace {
            body = try parseFunctionBody(simpleParams: simple)
            if ast.nodes[Int(body)].op == 1 { fl |= JSNodeFlags.hasUseStrict; ast.nodes[Int(body)].op = 0 }
        } else {
            let savedErr = coverErrPos
            coverErrPos = -1
            body = try parseAssignment(noIn: noIn)
            coverErrPos = savedErr
            fl |= JSNodeFlags.exprBody
        }
        try checkParams(params, strict: fn.strict, noDuplicates: true)
        if async { fl |= JSNodeFlags.async }
        if fn.strict { fl |= JSNodeFlags.strict }
        if simple { fl |= JSNodeFlags.simpleParams }
        if fn.usesArgs { fl |= JSNodeFlags.usesArguments }
        if fn.usesThis { fl |= JSNodeFlags.usesThis }
        if fn.hasEval { fl |= JSNodeFlags.hasDirectEval }
        popScope()
        popFn()
        return try node(.function, start, op: JSFunctionKind.arrow.rawValue, flags: fl, -1, ps, pc, body)
    }

    /// Append the names bound by a (converted) binding target to `bound`.
    func collectBoundNames(_ n: Int32) {
        var stack: [Int32] = [n]
        var guardCount = 0
        while let x = stack.popLast() {
            guardCount += 1
            if guardCount > 10_000_000 { return }
            let nd = ast.nodes[Int(x)]
            switch nd.kind {
            case .identifier: bound.append((nd.a, Int(nd.start)))
            case .assignPattern: stack.append(nd.a)
            case .rest: stack.append(nd.a)
            case .arrayPattern, .objectPattern:
                for c in ast.list(nd.a, nd.b).reversed() { stack.append(c) }
            case .property: if nd.b >= 0 { stack.append(nd.b) }
            default: break
            }
        }
    }

    // ------------------------------------------------------------ classes

    func parseClass(isDecl: Bool, defaultExport: Bool = false) throws(JSSyntaxError) -> Int32 {
        let start = tok.start
        try advance() // class
        let outerStrict = fn.strict
        fn.strict = true
        defer { fn.strict = outerStrict }
        var id: Int32 = -1
        if tok.kind == .name && !isWord(JSWord.extends_) {
            let nameTok = tok
            try checkIdentifier(tok, binding: true)
            if nameTok.value == JSWord.let_ { throw error("'let' is not a valid class name", nameTok.start) }
            try advance()
            id = try node(.identifier, nameTok.start, nameTok.value)
            if isDecl { try declareLexical(nameTok.value, nameTok.start) }
        } else if isDecl && !defaultExport {
            throw unexpected()
        }
        var superClass: Int32 = -1
        if isWord(JSWord.extends_) {
            try advance()
            superClass = try parseLeftHandSide()
        }
        try expect(.lbrace)
        classes.append(JSClassScope())
        let mark = scratch.count
        var sawCtor = false
        while tok.kind != .rbrace {
            if try eat(.semicolon) { continue }
            if tok.kind == .eof { throw unexpected() }
            let m = try parseClassMember(derived: superClass >= 0)
            let mn = ast.nodes[Int(m)]
            if mn.kind == .property && mn.b >= 0 && k(mn.b) == .function {
                let fk = ast.nodes[Int(mn.b)].op
                if fk == JSFunctionKind.classConstructor.rawValue || fk == JSFunctionKind.derivedConstructor.rawValue {
                    if sawCtor { throw error("a class may only have one constructor", Int(mn.start)) }
                    sawCtor = true
                }
            }
            scratch.append(m)
        }
        try advance()
        // Private names used but not declared here go to the outer class.
        let cs = classes.removeLast()
        for (name, pos) in cs.refs where cs.declared[name] == nil {
            if classes.isEmpty { throw error("undeclared private name '#\(ast.text(name))'", pos) }
            classes[classes.count - 1].refs.append((name, pos))
        }
        let (ls, lc) = finishList(mark)
        return try node(.classNode, start, flags: isDecl ? JSNodeFlags.declaration : JSNodeFlags.expression,
                        id, superClass, ls, lc)
    }

    func declarePrivate(_ name: Int32, _ bits: UInt8, _ pos: Int) throws(JSSyntaxError) {
        let i = classes.count - 1
        if name == JSWord.constructor { throw error("'#constructor' is not allowed", pos) }
        if let old = classes[i].declared[name] {
            // Only a getter + setter pair with the same staticness.
            let acc: UInt8 = 3
            if old & acc != 0 && bits & acc != 0 && old & acc != bits & acc && old & 8 == bits & 8 && old & 4 == 0 {
                classes[i].declared[name] = old | bits
                return
            }
            throw error("duplicate private name '#\(ast.text(name))'", pos)
        }
        classes[i].declared[name] = bits
    }

    func usePrivate(_ name: Int32, _ pos: Int) throws(JSSyntaxError) {
        if classes.isEmpty { throw error("private name '#\(ast.text(name))' outside a class", pos) }
        classes[classes.count - 1].refs.append((name, pos))
    }

    func parseClassMember(derived: Bool) throws(JSSyntaxError) -> Int32 {
        let start = tok.start
        var isStatic = false
        if isWord(JSWord.static_) {
            let p = try peek()
            if p.kind != .lparen && p.kind != .assign && p.kind != .semicolon && p.kind != .rbrace {
                try advance()
                isStatic = true
                if tok.kind == .lbrace { return try parseStaticBlock(start) }
            }
        }
        var async = false, generator = false
        var pkind = JSPropertyKind.method
        if isWord(JSWord.async_) {
            let p = try peek()
            if p.kind != .lparen && p.kind != .assign && p.kind != .semicolon && p.kind != .rbrace && !p.nl {
                try advance()
                async = true
            }
        }
        if tok.kind == .star { try advance(); generator = true }
        if !async && !generator && (isWord(JSWord.get) || isWord(JSWord.set)) {
            let p = try peek()
            if p.kind != .lparen && p.kind != .assign && p.kind != .semicolon && p.kind != .rbrace {
                pkind = isWord(JSWord.get) ? .getter : .setter
                try advance()
            }
        }
        let keyStart = tok.start
        let keyTok = tok
        var flags: UInt16 = isStatic ? JSNodeFlags.isStatic : 0
        let key = try parsePropertyKey(allowPrivate: true, &flags)
        let isPrivate = flags & JSNodeFlags.privateKey != 0
        let computed = flags & JSNodeFlags.computed != 0
        let keyName: Int32 = (!computed && (k(key) == .identifierName || k(key) == .string || k(key) == .privateName))
            ? ast.nodes[Int(key)].a : -1
        if tok.kind == .lparen {
            var fkind: JSFunctionKind = pkind == .getter ? .getter : pkind == .setter ? .setter : .method
            let isCtor = !isStatic && !isPrivate && keyName == JSWord.constructor
            if isCtor {
                if pkind != .method || async || generator { throw error("invalid constructor", keyStart) }
                fkind = derived ? .derivedConstructor : .classConstructor
            }
            if isStatic && keyName == JSWord.prototype && !isPrivate {
                throw error("classes may not have a static method named 'prototype'", keyStart)
            }
            if isPrivate {
                let bits: UInt8 = (pkind == .getter ? 1 : pkind == .setter ? 2 : 4) | (isStatic ? 8 : 0)
                try declarePrivate(keyName, bits, keyStart)
            }
            let f = try parseFunctionRest(tok.start, id: -1, kind: fkind, async: async, generator: generator,
                                          flags: 0, classCtx: true)
            return try node(.property, start, op: (pkind == .method ? JSPropertyKind.method : pkind).rawValue,
                            flags: flags, key, f)
        }
        // A field.
        if async || generator || pkind != .method {
            _ = keyTok
            throw unexpected()
        }
        if keyName == JSWord.constructor && !isPrivate {
            throw error("classes may not have a field named 'constructor'", keyStart)
        }
        if isStatic && keyName == JSWord.prototype && !isPrivate {
            throw error("classes may not have a static field named 'prototype'", keyStart)
        }
        if isPrivate { try declarePrivate(keyName, 4 | (isStatic ? 8 : 0), keyStart) }
        var value: Int32 = -1
        if tok.kind == .assign {
            try advance()
            var f = fn
            f.arrow = false
            f.async = false
            f.generator = false
            f.awaitReserved = true
            f.isFunction = false
            f.superProp = true
            f.superCall = false
            f.newTarget = true
            f.noArguments = true
            f.inParams = false
            f.usesThis = false
            f.usesArgs = false
            f.hasEval = false
            f.loopDepth = 0
            f.breakDepth = 0
            pushFn(f)
            let savedLabels = labels
            labels = []
            value = try parseAssignment(noIn: false)
            labels = savedLabels
            let child = fn
            fn = fnStack.removeLast()
            if child.hasEval { fn.hasEval = true }
        }
        try semicolon()
        return try node(.property, start, op: JSPropertyKind.field.rawValue, flags: flags, key, value)
    }

    func parseStaticBlock(_ start: Int) throws(JSSyntaxError) -> Int32 {
        try expect(.lbrace)
        var f = JSFnCtx()
        f.strict = true
        f.awaitReserved = true
        f.superProp = true
        f.newTarget = true
        f.noArguments = true
        f.staticBlock = true
        pushFn(f)
        pushScope(0)
        let savedLabels = labels
        labels = []
        let mark = scratch.count
        while tok.kind != .rbrace {
            if tok.kind == .eof { throw unexpected() }
            scratch.append(try parseStatementListItem())
        }
        try advance()
        labels = savedLabels
        popScope()
        let child = fn
        fn = fnStack.removeLast()
        if child.hasEval { fn.hasEval = true }
        let (ls, lc) = finishList(mark)
        return try node(.staticBlock, start, ls, lc)
    }

    // ------------------------------------------------------------ modules

    /// A module export/import name: an IdentifierName or a string literal
    /// (which must be well-formed Unicode). Returns the string id.
    func parseModuleExportName(_ isString: inout Bool) throws(JSSyntaxError) -> Int32 {
        if tok.kind == .string {
            let id = tok.value
            var i = 0
            let s = ast.str(id)
            var prevHigh = false
            for u in s {
                let high = u >= 0xD800 && u < 0xDC00, low = u >= 0xDC00 && u < 0xE000
                if low && !prevHigh { throw error("module export name is not well-formed Unicode", tok.start) }
                if prevHigh && !low { throw error("module export name is not well-formed Unicode", tok.start) }
                prevHigh = high
                i += 1
            }
            if prevHigh { throw error("module export name is not well-formed Unicode", tok.start) }
            isString = true
            try advance()
            return id
        }
        guard tok.kind == .name else { throw unexpected() }
        isString = false
        let id = tok.value
        try advance()
        return id
    }

    func parseModuleSpecifier() throws(JSSyntaxError) -> Int32 {
        guard tok.kind == .string else { throw unexpected() }
        let id = tok.value
        try advance()
        return id
    }

    func parseImport() throws(JSSyntaxError) -> Int32 {
        let start = tok.start
        try advance() // import
        let mark = scratch.count
        if tok.kind == .string {
            let from = try parseModuleSpecifier()
            try semicolon()
            let (ls, lc) = finishList(mark)
            return try node(.importDecl, start, from, ls, lc)
        }
        let bmark = bound.count
        if tok.kind == .name {
            let s = tok.start
            let local = try parseBindingIdentifier()
            scratch.append(try node(.importDefault, s, local))
            if tok.kind == .comma {
                try advance()
                if tok.kind != .star && tok.kind != .lbrace { throw unexpected() }
            } else if !isWord(JSWord.from) {
                throw unexpected()
            }
        }
        if tok.kind == .star {
            let s = tok.start
            try advance()
            try expectWord(JSWord.as_)
            let local = try parseBindingIdentifier()
            scratch.append(try node(.importNamespace, s, local))
        } else if tok.kind == .lbrace {
            try advance()
            while tok.kind != .rbrace {
                let s = tok.start
                let nameTok = tok
                var isString = false
                let imported = try parseModuleExportName(&isString)
                let local: Int32
                if isWord(JSWord.as_) {
                    try advance()
                    local = try parseBindingIdentifier()
                } else {
                    if isString { throw error("a string import name needs 'as'", s) }
                    try checkIdentifier(nameTok, binding: true)
                    bound.append((imported, s))
                    local = try node(.identifier, s, imported)
                }
                scratch.append(try node(.importSpec, s, imported, local))
                if tok.kind != .comma { break }
                try advance()
            }
            try expect(.rbrace)
        }
        try expectWord(JSWord.from)
        let from = try parseModuleSpecifier()
        try semicolon()
        try declareBound(bmark, .let)
        let (ls, lc) = finishList(mark)
        return try node(.importDecl, start, from, ls, lc)
    }

    func addExportedName(_ name: Int32, _ pos: Int) throws(JSSyntaxError) {
        if !exportedNames.insert(name).inserted { throw error("duplicate export '\(ast.text(name))'", pos) }
    }

    func parseExport() throws(JSSyntaxError) -> Int32 {
        let start = tok.start
        try advance() // export
        if tok.kind == .star {
            try advance()
            var exported: Int32 = -1
            if isWord(JSWord.as_) {
                try advance()
                let p = tok.start
                var isString = false
                exported = try parseModuleExportName(&isString)
                try addExportedName(exported, p)
            }
            try expectWord(JSWord.from)
            let from = try parseModuleSpecifier()
            try semicolon()
            return try node(.exportAll, start, from, exported)
        }
        if isWord(JSWord.default_) {
            let dpos = tok.start
            try addExportedName(JSWord.default_, dpos)
            try advance()
            let s = tok.start
            if isWord(JSWord.function_) {
                let f = try parseFunctionDeclaration(s, async: false, inBlock: false, defaultExport: true)
                return try node(.exportDefault, start, f)
            }
            if isWord(JSWord.async_) {
                let p = try peek()
                if p.kind == .name && p.value == JSWord.function_ && !p.escaped && !p.nl {
                    try advance()
                    let f = try parseFunctionDeclaration(s, async: true, inBlock: false, defaultExport: true)
                    return try node(.exportDefault, start, f)
                }
            }
            if isWord(JSWord.class_) {
                let c = try parseClass(isDecl: true, defaultExport: true)
                return try node(.exportDefault, start, c)
            }
            let e = try parseAssignment(noIn: false)
            try semicolon()
            return try node(.exportDefault, start, flags: JSNodeFlags.expression, e)
        }
        let mark = scratch.count
        if tok.kind == .lbrace {
            try advance()
            var locals: [(Int32, Int, Bool, JSToken)] = []
            while tok.kind != .rbrace {
                let s = tok.start
                let localTok = tok
                var localIsString = false
                let local = try parseModuleExportName(&localIsString)
                var exported = local
                if isWord(JSWord.as_) {
                    try advance()
                    var isString = false
                    let p = tok.start
                    exported = try parseModuleExportName(&isString)
                    try addExportedName(exported, p)
                } else {
                    try addExportedName(exported, s)
                }
                locals.append((local, s, localIsString, localTok))
                scratch.append(try node(.exportSpec, s, local, exported))
                if tok.kind != .comma { break }
                try advance()
            }
            try expect(.rbrace)
            var from: Int32 = -1
            if isWord(JSWord.from) {
                try advance()
                from = try parseModuleSpecifier()
            } else {
                for (local, pos, isString, t) in locals {
                    if isString { throw error("a string export name needs 'from'", pos) }
                    if local < JSWord.reservedCount || JSWord.isStrictReserved(local) || local == JSWord.await_ {
                        _ = t
                        throw error("unexpected reserved word", pos)
                    }
                    exportRefs.append((local, pos))
                }
            }
            try semicolon()
            let (ls, lc) = finishList(mark)
            return try node(.exportNamed, start, -1, ls, lc, from)
        }
        // export declaration
        let declStart = tok.start
        var decl: Int32
        let bmark = scopes[0].lexical.count + scopes[0].vars.count
        _ = bmark
        if isWord(JSWord.var_) {
            try advance()
            decl = try parseDeclarations(.var, declStart, inFor: false)
            try semicolon()
        } else if isWord(JSWord.let_) || isWord(JSWord.const_) {
            let kind: JSVarKind = isWord(JSWord.let_) ? .let : .const
            try advance()
            decl = try parseDeclarations(kind, declStart, inFor: false)
            try semicolon()
        } else if isWord(JSWord.function_) {
            decl = try parseFunctionDeclaration(declStart, async: false, inBlock: false)
        } else if isWord(JSWord.async_) {
            try advance()
            if !isWord(JSWord.function_) || tok.nl { throw unexpected() }
            decl = try parseFunctionDeclaration(declStart, async: true, inBlock: false)
        } else if isWord(JSWord.class_) {
            decl = try parseClass(isDecl: true)
        } else {
            throw unexpected()
        }
        ast.nodes[Int(decl)].end = UInt32(truncatingIfNeeded: prevEnd)
        // Exported names: the declaration's bound names.
        let dn = ast.nodes[Int(decl)]
        if dn.kind == .varDecl {
            let b0 = bound.count
            for d in ast.list(dn.a, dn.b) { collectBoundNames(ast.nodes[Int(d)].a) }
            let names = Array(bound[b0...])
            bound.removeSubrange(b0...)
            for (name, pos) in names { try addExportedName(name, pos) }
        } else if dn.a >= 0 {
            let idn = ast.nodes[Int(dn.a)]
            try addExportedName(idn.a, Int(idn.start))
        }
        let (ls, lc) = finishList(mark)
        return try node(.exportNamed, start, decl, ls, lc, -1)
    }
}
