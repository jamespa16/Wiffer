// The bytecode compiler, part 2: expressions, references, destructuring,
// literals, calls and classes (see jscompiler.swift).

/// How a pattern's identifiers are stored.
enum JSBindMode {
    /// let/const/param/catch/class initialization (no TDZ or const check).
    case initialize
    /// var declarations: a plain store to the var binding.
    case assignVar
    /// destructuring assignment: any assignment target.
    case assign
}

/// An assignment target after its object/key parts are on the stack.
enum JSRefTarget {
    case binding(Int32)
    case global(Int32)
    case dynamic(Int32)
    case member(Int)
    case index
    case superMember(Int)
    case superIndex
    /// obj.#x: [obj record] on the stack.
    case privateMember
    case invalid
}

extension JSCompiler {
    // MARK: Expressions

    func emitExpr(_ n: Int32, nameHint: JSValue? = nil) throws(JSCompileError) {
        try guardStack(n)
        let node = ast[n]
        switch node.kind {
        case .number:
            let i = Int(node.a)
            try pushNumber(i >= 0 && i < ast.numbers.count ? ast.numbers[i] : .nan)
        case .string:
            try pushString(node.a)
        case .nullLit: try emit(.pushNull, 1)
        case .trueLit: try emit(.pushTrue, 1)
        case .falseLit: try emit(.pushFalse, 1)
        case .identifier:
            try emitIdentifier(n)
        case .this:
            let r = sa.ref(n)
            if r >= 0 { try emitGetBinding(r) } else { try emit(.loadGlobalThis, 1) }
        case .newTarget:
            let r = sa.ref(n)
            if r >= 0 { try emitGetBinding(r, checked: false) } else { try emit(.pushUndefined, 1) }
        case .template:
            try emitTemplate(n)
        case .taggedTemplate:
            try emitTaggedTemplate(n)
        case .regexp:
            setPos(n)
            try emit(.newRegExp, 1)
            put32(addConst(atom(node.a)))
            put32(addConst(atom(node.b)))
        case .bigint:
            // The literal's text (prefix kept, `n` and separators removed) parsed at compile time.
            var tooBig = false
            guard let b = jsBNParseString(Array(ast.str(node.a)), maxBits: heap.limits.maxBigIntBits, tooBig: &tooBig) else {
                throw fail(tooBig ? "BigInt literal too large" : "invalid BigInt literal", n)
            }
            let bv = heap.newBigInt(b)
            _ = heap.root(bv)
            try emitU32(.pushConst, addConst(bv), 1)
        case .array:
            try emitArrayLiteral(n)
        case .object:
            try emitObjectLiteral(n)
        case .function:
            var name: JSValue = .string(0)
            if node.a >= 0 { name = atom(ast[node.a].a) } else if let h = nameHint { name = h }
            let code = try compileFunction(n, name: name)
            try emitU32(.closure, addConst(code.codeObject), 1)
        case .classNode:
            try emitClass(n, nameHint: nameHint)
        case .unary:
            try emitUnary(n)
        case .update:
            try emitUpdate(n)
        case .binary:
            try emitBinary(n)
        case .assign:
            try emitAssign(n)
        case .conditional:
            let elseL = newLabel(), endL = newLabel()
            try emitCondition(node.a, falseLabel: elseL)
            try emitExpr(node.b)
            try emitJump(.jump, endL)
            try adjust(-1)
            try place(elseL)
            try emitExpr(node.c)
            try place(endL)
        case .sequence:
            let items = ast.list(node.a, node.b)
            for (i, e) in items.enumerated() {
                try emitExpr(e)
                if i < items.count - 1 { try emit(.pop, -1) }
            }
            if items.isEmpty { try emit(.pushUndefined, 1) }
        case .call:
            let callee = ast[node.a]
            if callee.kind == .superExpr {
                try emitSuperCall(n)
            } else if callee.kind == .identifier && callee.a == JSWord.eval && node.flags & JSNodeFlags.optional == 0 {
                try emitDirectEval(n)
            } else {
                try emitChain(n, forCall: false)
            }
        case .member, .index:
            if ast.kind(node.a) == .superExpr {
                try emitSuperGet(n)
            } else {
                try emitChain(n, forCall: false)
            }
        case .optionalChain:
            let l = newLabel()
            fs.optLabels.append(l)
            let d = fs.depth
            try emitChain(node.a, forCall: false)
            fs.optLabels.removeLast()
            let end = newLabel()
            try emitJump(.jump, end)
            fs.depth = d
            try place(l, dead: true)
            try emit(.pushUndefined, 1)
            try place(end)
        case .newExpr:
            try emitExpr(node.a)
            try emit(.dup, 1)
            try emitArgs(n, node.b, node.c, op: .construct)
        case .privateMember:
            try emitChain(n, forCall: false)
        case .yieldExpr:
            try emitYield(n)
        case .awaitExpr:
            try emitExpr(node.a)
            setPos(n)
            try emitAwait()
        case .importMeta:
            let r = sa.ref(n)
            if r >= 0 { try emitGetBinding(r, checked: false) } else { try emit(.pushUndefined, 1) }
        case .importCall:
            try emitExpr(node.a)
            setPos(n)
            try emit(.dynamicImport, 0)
        default:
            throw fail("unexpected expression", n)
        }
    }

    func emitIdentifier(_ n: Int32) throws(JSCompileError) {
        let name = ast[n].a
        let r = sa.ref(n)
        if r >= 0 { try emitGetBinding(r); return }
        setPos(n)
        if r == JSRefKind.dynamic { try emitU32(.getName, key(name), 1); return }
        if ast.pool.equals(name, "undefined") { try emit(.pushUndefined, 1); return }
        try emitU32(.getGlobal, key(name), 1)
    }

    // MARK: Operators

    func emitBinary(_ n: Int32) throws(JSCompileError) {
        var spine: [Int32] = []
        var x = n
        while ast.kind(x) == .binary {
            spine.append(x)
            x = ast[x].a
        }
        let privateIn = ast.kind(x) == .privateName
        if privateIn {
            try emitPrivateRecord(x)   // `#x in o`
        } else {
            try emitExpr(x)
        }
        for (si, node) in spine.reversed().enumerated() {
            let b = ast[node]
            let op = JSBinaryOp(rawValue: b.op) ?? .add
            if si == 0 && privateIn {
                try emitExpr(b.b)
                setPos(node)
                try emit(.hasPrivate, -1)
                continue
            }
            switch op {
            case .logicalAnd, .logicalOr, .nullish:
                let l = newLabel()
                let j: JSOp = op == .logicalAnd ? .jumpIfFalseKeep : op == .logicalOr ? .jumpIfTrueKeep : .jumpIfNotNullishKeep
                try emitJump(j, l)
                try emit(.pop, -1)
                try emitExpr(b.b)
                try place(l)
            default:
                try emitExpr(b.b)
                setPos(node)
                try emit(jsBinaryOpcode(op), -1)
            }
        }
    }

    func jsBinaryOpcode(_ op: JSBinaryOp) -> JSOp {
        switch op {
        case .add: return .add
        case .sub: return .sub
        case .mul: return .mul
        case .div: return .div
        case .mod: return .mod
        case .exp: return .exp
        case .shl: return .shl
        case .sar: return .sar
        case .shr: return .shr
        case .lt: return .lt
        case .gt: return .gt
        case .le: return .le
        case .ge: return .ge
        case .eq: return .eq
        case .ne: return .ne
        case .strictEq: return .strictEq
        case .strictNe: return .strictNe
        case .bitAnd: return .bitAnd
        case .bitOr: return .bitOr
        case .bitXor: return .bitXor
        case .in: return .inOp
        case .instanceof: return .instanceOf
        case .logicalAnd, .logicalOr, .nullish: return .nop
        }
    }

    func jsAssignOpcode(_ op: JSAssignOp) -> JSOp {
        switch op {
        case .add: return .add
        case .sub: return .sub
        case .mul: return .mul
        case .div: return .div
        case .mod: return .mod
        case .exp: return .exp
        case .shl: return .shl
        case .sar: return .sar
        case .shr: return .shr
        case .bitAnd: return .bitAnd
        case .bitOr: return .bitOr
        case .bitXor: return .bitXor
        default: return .nop
        }
    }

    func emitUnary(_ n: Int32) throws(JSCompileError) {
        let node = ast[n]
        let op = JSUnaryOp(rawValue: node.op) ?? .void
        switch op {
        case .minus:
            if ast.kind(node.a) == .number {
                let i = Int(ast[node.a].a)
                try pushNumber(-(i >= 0 && i < ast.numbers.count ? ast.numbers[i] : .nan))
            } else {
                try emitExpr(node.a)
                try emit(.neg, 0)
            }
        case .plus: try emitExpr(node.a); try emit(.plus, 0)
        case .not: try emitExpr(node.a); try emit(.not, 0)
        case .bitNot: try emitExpr(node.a); try emit(.bitNot, 0)
        case .void: try emitExpr(node.a); try emit(.pop, -1); try emit(.pushUndefined, 1)
        case .typeof:
            if ast.kind(node.a) == .identifier {
                let r = sa.ref(node.a)
                let name = ast[node.a].a
                if r >= 0 { try emitGetBinding(r) }
                else if r == JSRefKind.dynamic { try emitU32(.getNameOrUndef, key(name), 1) }
                else { try emitU32(.getGlobalOrUndef, key(name), 1) }
            } else {
                try emitExpr(node.a)
            }
            try emit(.typeOf, 0)
        case .delete:
            try emitDelete(node.a)
        }
    }

    func emitDelete(_ t: Int32) throws(JSCompileError) {
        let tn = ast[t]
        setPos(t)
        switch tn.kind {
        case .identifier:
            let r = sa.ref(t)
            if r >= 0 { try emit(.pushFalse, 1) }
            else { try emitU32(.deleteName, key(tn.a), 1) }
        case .member where ast.kind(tn.a) != .superExpr:
            try emitExpr(tn.a)
            try emitU32(.deleteField, key(tn.b), 0)
        case .index where ast.kind(tn.a) != .superExpr:
            try emitExpr(tn.a)
            try emitExpr(tn.b)
            try emit(.deleteElem, -1)
        case .member, .index:
            try throwError(.referenceError, "Unsupported reference to 'super'")
            try adjust(1)
        case .optionalChain:
            // delete a?.b: undefined base -> true.
            try emitExpr(t)
            try emit(.pop, -1)
            try emit(.pushTrue, 1)
        default:
            try emitExpr(t)
            try emit(.pop, -1)
            try emit(.pushTrue, 1)
        }
    }

    // MARK: References

    /// Push the parts of an assignment target.
    func prepareRef(_ t: Int32) throws(JSCompileError) -> JSRefTarget {
        let tn = ast[t]
        switch tn.kind {
        case .identifier:
            let r = sa.ref(t)
            if r >= 0 { return .binding(r) }
            return r == JSRefKind.dynamic ? .dynamic(tn.a) : .global(tn.a)
        case .member:
            if ast.kind(tn.a) == .superExpr {
                try emitSuperBase(tn.a)
                return .superMember(key(tn.b))
            }
            try emitExpr(tn.a)
            return .member(key(tn.b))
        case .index:
            if ast.kind(tn.a) == .superExpr {
                try emitSuperBase(tn.a)
                try emitExpr(tn.b)
                return .superIndex
            }
            try emitExpr(tn.a)
            try emitExpr(tn.b)
            return .index
        case .privateMember:
            try emitExpr(tn.a)
            try emitPrivateRecord(t)
            return .privateMember
        default:
            // Runtime errors for function call assignment targets (sloppy
            // f() = 1): evaluate the call, then throw before the right side.
            try emitExpr(t)
            try emit(.pop, -1)
            try throwError(.referenceError, "Invalid left-hand side in assignment")
            return .invalid
        }
    }

    /// Duplicate the parts and get the current value: [parts] -> [parts old].
    func getRefKeep(_ r: JSRefTarget) throws(JSCompileError) {
        switch r {
        case .binding(let b): try emitGetBinding(b)
        case .global(let name): try emitU32(.getGlobal, key(name), 1)
        case .dynamic(let name): try emitU32(.getName, key(name), 1)
        case .member(let k): try emit(.dup, 1); try emitU32(.getField, k, 0)
        case .index: try emit(.dup2, 2); try emit(.getElem, -1)
        case .superMember(let k): try emit(.dup2, 2); try emitU32(.getSuperField, k, -1)
        case .superIndex: try emit(.dup3, 3); try emit(.getSuperElem, -2)
        case .privateMember: try emit(.dup2, 2); try emit(.getPrivate, -1)
        case .invalid:
            try emit(.pushUndefined, 1)
        }
    }

    /// [parts value] -> [value].
    func storeRefKeep(_ r: JSRefTarget) throws(JSCompileError) {
        switch r {
        case .binding(let b):
            let bd = sa.bindings[Int(b)]
            if !bd.inEnv && bd.slot >= 0 && !bd.isConst && bd.kind != .calleeName && !(bd.isLexical && bd.needsTDZ) {
                try emitU32(.setLocal, Int(bd.slot), 0)
            } else {
                try emit(.dup, 1)
                try emitPutBinding(b, initialize: false)
            }
        case .global(let name):
            try emit(.dup, 1)
            try emitU32(.putGlobal, key(name), -1)
        case .dynamic(let name):
            try emit(.dup, 1)
            try emitU32(.putName, key(name), -1)
        case .member(let k): try emitU32(.putField, k, -1)
        case .index: try emit(.putElem, -2)
        case .superMember(let k): try emitU32(.putSuperField, k, -2)
        case .superIndex: try emit(.putSuperElem, -3)
        case .privateMember: try emit(.putPrivate, -2)
        case .invalid:
            try throwError(.referenceError, "Invalid left-hand side in assignment")
        }
    }

    /// [parts value] -> [] for a resolved identifier (declarations).
    func emitStoreRef(_ r: Int32, name: Int32, initialize: Bool) throws(JSCompileError) {
        if r >= 0 { try emitPutBinding(r, initialize: initialize); return }
        if r == JSRefKind.dynamic { try emitU32(.putName, key(name), -1); return }
        if initialize, let b = sa.scopes[0].names[name], sa.bindings[Int(b)].isLexical,
           sa.scopes[0].kind == .script {
            try emitU32(.initLex, key(name), -1)
            return
        }
        try emitU32(.putGlobal, key(name), -1)
    }

    func emitAssign(_ n: Int32) throws(JSCompileError) {
        let node = ast[n]
        let op = JSAssignOp(rawValue: node.op) ?? .assign
        let tk = ast.kind(node.a)
        if op == .assign && (tk == .arrayPattern || tk == .objectPattern) {
            try emitExpr(node.b)
            try emit(.dup, 1)
            try emitBindingInit(node.a, mode: .assign)
            return
        }
        let hint: JSValue? = tk == .identifier ? atom(ast[node.a].a) : nil
        let r = try prepareRef(node.a)
        setPos(n)
        switch op {
        case .assign:
            try emitExpr(node.b, nameHint: hint)
            setPos(n)
            try storeRefKeep(r)
        case .logicalAnd, .logicalOr, .nullish:
            try getRefKeep(r)
            let short = newLabel(), done = newLabel()
            let j: JSOp = op == .logicalAnd ? .jumpIfFalseKeep : op == .logicalOr ? .jumpIfTrueKeep : .jumpIfNotNullishKeep
            try emitJump(j, short)
            try emit(.pop, -1)
            try emitExpr(node.b, nameHint: hint)
            try storeRefKeep(r)
            try emitJump(.jump, done)
            // [parts old] -> [old]
            try place(short, dead: true)
            let parts = refParts(r)
            if parts > 0 {
                if parts == 1 { try emit(.swap, 0); try emit(.pop, -1) }
                else if parts == 2 { try emit(.rot3, 0); try popN(2) }
                else { try emit(.rot4, 0); try popN(3) }
            }
            try place(done)
        default:
            try getRefKeep(r)
            try emitExpr(node.b)
            setPos(n)
            try emit(jsAssignOpcode(op), -1)
            try storeRefKeep(r)
        }
    }

    func refParts(_ r: JSRefTarget) -> Int {
        switch r {
        case .member: return 1
        case .index, .superMember, .privateMember: return 2
        case .superIndex: return 3
        default: return 0
        }
    }

    func emitUpdate(_ n: Int32) throws(JSCompileError) {
        let node = ast[n]
        let inc = node.op == JSUpdateOp.increment.rawValue
        let prefix = node.flags & JSNodeFlags.prefix != 0
        let r = try prepareRef(node.a)
        setPos(n)
        try getRefKeep(r)
        if prefix {
            try emit(inc ? .inc : .dec, 0)
            try storeRefKeep(r)
            return
        }
        try emit(.toNumeric, 0)
        let parts = refParts(r)
        if parts == 3 {
            // [this home key old]: keep the old value in a temp.
            let tmp = tempLocal()
            try emitU32(.setLocal, tmp, 0)
            try emit(inc ? .inc : .dec, 0)
            try storeRefKeep(r)
            try emit(.pop, -1)
            try emitU32(.getLocal, tmp, 1)
            freeTemp(tmp)
            return
        }
        try emit(.dup, 1)
        if parts == 1 { try emit(.rot3, 0) } else if parts == 2 { try emit(.rot4, 0) }
        try emit(inc ? .inc : .dec, 0)
        try storeRefKeep(r)
        try emit(.pop, -1)
    }

    // MARK: Calls and member chains

    func isChainLink(_ x: Int32) -> Bool {
        let n = ast[x]
        switch n.kind {
        case .member, .index: return ast.kind(n.a) != .superExpr
        case .privateMember: return true
        case .call:
            let c = ast[n.a]
            if c.kind == .superExpr { return false }
            if c.kind == .identifier && c.a == JSWord.eval && n.flags & JSNodeFlags.optional == 0 { return false }
            return true
        default: return false
        }
    }

    /// A member/call chain, walked iteratively along the left spine.
    /// forCall leaves [function this] instead of the value.
    func emitChain(_ n: Int32, forCall: Bool) throws(JSCompileError) {
        var spine: [Int32] = []
        var x = n
        while isChainLink(x) {
            spine.append(x)
            x = ast[x].a
        }
        guard let first = spine.last else {
            if forCall { try emitCallee(x) } else { try emitExpr(x) }
            return
        }
        if ast.kind(first) == .call { try emitCallee(x) } else { try emitExpr(x) }
        var i = spine.count - 1
        while i >= 0 {
            let node = spine[i]
            let nd = ast[node]
            let wantThis = (i > 0 && ast.kind(spine[i - 1]) == .call) || (i == 0 && forCall)
            let optional = nd.flags & JSNodeFlags.optional != 0
            switch nd.kind {
            case .member:
                if optional { try jumpIfNullish(try optLabel(), pos: 0, pop: 1) }
                setPos(node)
                if wantThis { try emitU32(.getFieldForCall, key(nd.b), 1) }
                else { try emitU32(.getField, key(nd.b), 0) }
            case .index:
                if optional { try jumpIfNullish(try optLabel(), pos: 0, pop: 1) }
                try emitExpr(nd.b)
                setPos(node)
                try emit(wantThis ? .getElemForCall : .getElem, wantThis ? 0 : -1)
            case .privateMember:
                if optional { try jumpIfNullish(try optLabel(), pos: 0, pop: 1) }
                setPos(node)
                if wantThis {
                    try emit(.dup, 1)
                    try emitPrivateRecord(node)
                    try emit(.getPrivate, -1)
                    try emit(.swap, 0)
                } else {
                    try emitPrivateRecord(node)
                    try emit(.getPrivate, -1)
                }
            default: // call: [f this] on the stack
                if optional { try jumpIfNullish(try optLabel(), pos: 1, pop: 2) }
                try emitArgs(node, nd.b, nd.c, op: .call)
                if wantThis { try emit(.pushUndefined, 1) }
            }
            i -= 1
        }
    }

    func optLabel() throws(JSCompileError) -> Int {
        guard let l = fs.optLabels.last else { throw internalError("optional link outside a chain") }
        return l
    }

    /// Push [function this] for a call's callee that is not a chain link.
    func emitCallee(_ x: Int32) throws(JSCompileError) {
        let n = ast[x]
        switch n.kind {
        case .identifier:
            let r = sa.ref(x)
            if r == JSRefKind.dynamic {
                setPos(x)
                try emitU32(.getNameForCall, key(n.a), 2)
                return
            }
            try emitIdentifier(x)
            try emit(.pushUndefined, 1)
        case .member where ast.kind(n.a) == .superExpr:
            try emitSuperGet(x)
            try emitSuperThis(n.a)
        case .index where ast.kind(n.a) == .superExpr:
            try emitSuperGet(x)
            try emitSuperThis(n.a)
        case .member, .index, .call, .privateMember:
            try emitChain(x, forCall: true)
        default:
            try emitExpr(x)
            try emit(.pushUndefined, 1)
        }
    }

    /// Push the private record a `#x` reference resolves to.
    func emitPrivateRecord(_ n: Int32) throws(JSCompileError) {
        let r = sa.ref(n)
        guard r >= 0 else { throw fail("undeclared private name", n) }
        try emitGetBinding(r, checked: false)
    }

    /// Arguments and the call instruction. The stack holds [f this] (call,
    /// directEval with an extra slot) or [f newTarget] (construct).
    func emitArgs(_ callNode: Int32, _ start: Int32, _ count: Int32, op: JSOp) throws(JSCompileError) {
        let args = ast.list(start, count)
        var spread = false
        for a in args where ast.kind(a) == .spread { spread = true; break }
        if spread {
            try emitU32(.newArray, args.count, 1)
            for a in args {
                if ast.kind(a) == .spread {
                    try emitExpr(ast[a].a)
                    try emit(.appendSpread, -1)
                } else {
                    try emitExpr(a)
                    try emit(.appendElem, -1)
                }
            }
            setPos(callNode)
            let aop: JSOp = op == .construct ? .constructArray : op == .superCall ? .superCallArray : .callArray
            try emit(aop, -2)
            return
        }
        for a in args { try emitExpr(a) }
        setPos(callNode)
        let extra = op == .directEval ? 2 : 1
        if op == .directEval {
            guard args.count < 0x8000 else { throw fail("too many arguments") }
            try emitU16(op, args.count | (fs.inParams ? 0x8000 : 0), -(args.count + extra))
            return
        }
        try emitU16(op, args.count, -(args.count + extra))
    }

    func emitDirectEval(_ n: Int32) throws(JSCompileError) {
        let node = ast[n]
        try emitIdentifier(node.a)
        let t = sa.ref(n)
        if t >= 0 { try emitGetBinding(t) } else { try emit(.loadGlobalThis, 1) }
        let nt = sa.superRef(n, 3)
        if nt >= 0 { try emitGetBinding(nt, checked: false) } else { try emit(.pushUndefined, 1) }
        var spread = false
        for a in ast.list(node.b, node.c) where ast.kind(a) == .spread { spread = true; break }
        if spread {
            try emitU32(.newArray, 0, 1)
            for a in ast.list(node.b, node.c) {
                if ast.kind(a) == .spread {
                    try emitExpr(ast[a].a)
                    try emit(.appendSpread, -1)
                } else {
                    try emitExpr(a)
                    try emit(.appendElem, -1)
                }
            }
            setPos(n)
            try emitU16(.directEvalArray, 0, -3)
            return
        }
        try emitArgs(n, node.b, node.c, op: .directEval)
    }

    // MARK: super

    func superBinding(_ superNode: Int32, _ which: Int64) throws(JSCompileError) -> Int32 {
        let b = sa.superRef(superNode, which)
        if b < 0 { throw fail("'super' is not valid here", superNode) }
        return b
    }

    /// [this home]
    func emitSuperBase(_ superNode: Int32) throws(JSCompileError) {
        try emitSuperThis(superNode)
        try emitGetBinding(try superBinding(superNode, 0), checked: false)
    }

    func emitSuperThis(_ superNode: Int32) throws(JSCompileError) {
        try emitGetBinding(try superBinding(superNode, 1))
    }

    /// super.x / super[x] as a value.
    func emitSuperGet(_ n: Int32) throws(JSCompileError) {
        let node = ast[n]
        try emitSuperBase(node.a)
        setPos(n)
        if node.kind == .member {
            try emitU32(.getSuperField, key(node.b), -1)
        } else {
            try emitExpr(node.b)
            try emit(.getSuperElem, -2)
        }
    }

    func emitSuperCall(_ n: Int32) throws(JSCompileError) {
        let node = ast[n]
        let sup = node.a
        let fo = try superBinding(sup, 2)
        try emitGetBinding(fo, checked: false)
        let nt = try superBinding(sup, 3)
        try emitGetBinding(nt, checked: false)
        try emitArgs(n, node.b, node.c, op: .superCall)
        let tb = try superBinding(sup, 1)
        try emitGetBinding(tb, checked: false)
        try emit(.checkThisInit, -1)
        try emit(.dup, 1)
        try emitPutBinding(tb, initialize: true)
        try emit(.dup, 1)
        try emitGetBinding(fo, checked: false)
        try emit(.runFieldInit, -2)
    }

    // MARK: Literals

    func emitTemplate(_ n: Int32) throws(JSCompileError) {
        let node = ast[n]
        let parts = Array(ast.list(node.a, node.b))
        guard !parts.isEmpty else { try emitU32(.pushConst, addConst(.string(0)), 1); return }
        func cooked(_ e: Int32) -> Int32 { ast[e].a }
        let first = cooked(parts[0])
        var have = false
        if first >= 0 && ast.pool.length(first) > 0 { try pushString(first); have = true }
        var i = 1
        while i + 1 < parts.count + 1 && i < parts.count {
            try emitExpr(parts[i])
            try emit(.toStringOp, 0)
            if have { try emit(.add, -1) }
            have = true
            if i + 1 < parts.count {
                let c = cooked(parts[i + 1])
                if c >= 0 && ast.pool.length(c) > 0 {
                    try pushString(c)
                    try emit(.add, -1)
                }
            }
            i += 2
        }
        if !have { try emitU32(.pushConst, addConst(.string(0)), 1) }
    }

    func emitTaggedTemplate(_ n: Int32) throws(JSCompileError) {
        let node = ast[n]
        try emitCallee(node.a)
        let t = ast[node.b]
        let parts = Array(ast.list(t.a, t.b))
        // The template object descriptor: [cooked0, raw0, cooked1, raw1...].
        var desc: [JSValue] = []
        var exprs: [Int32] = []
        for (i, p) in parts.enumerated() {
            if i % 2 == 0 {
                let e = ast[p]
                desc.append(e.a >= 0 ? atom(e.a) : .undefined)
                desc.append(atom(e.b))
            } else {
                exprs.append(p)
            }
        }
        let d = heap.newObject(proto: .null, kind: .internalObject, flags: [])
        _ = heap.root(d)
        heap.setSlots(d, desc)
        heap.setInternalInt(d, 1)
        try emitU32(.templateObject, addConst(d), 1)
        for e in exprs { try emitExpr(e) }
        setPos(n)
        try emitU16(.call, 1 + exprs.count, -(exprs.count + 2))
    }

    func emitArrayLiteral(_ n: Int32) throws(JSCompileError) {
        let node = ast[n]
        let elems = ast.list(node.a, node.b)
        try emitU32(.newArray, elems.count, 1)
        for e in elems {
            switch ast.kind(e) {
            case .hole: try emit(.appendHole, 0)
            case .spread:
                try emitExpr(ast[e].a)
                setPos(e)
                try emit(.appendSpread, -1)
            default:
                try emitExpr(e)
                try emit(.appendElem, -1)
            }
        }
    }

    /// The key index of a non-computed property key node, or nil.
    func staticKey(_ k: Int32) throws(JSCompileError) -> Int? {
        let kn = ast[k]
        switch kn.kind {
        case .identifierName, .string: return key(kn.a)
        case .number:
            let i = Int(kn.a)
            let d = i >= 0 && i < ast.numbers.count ? ast.numbers[i] : 0
            let s = heap.numberToString(d)
            let r = heap.root(s)
            let pk = heap.propertyKey(s) ?? .atom(0)
            if pk.isString { _ = heap.root(.string(pk.handle)) }
            _ = r
            return addKey(pk)
        case .bigint:
            let s = bigintKeyString(kn)
            let pk = heap.propertyKey(s) ?? .atom(0)
            if pk.isString { _ = heap.root(.string(pk.handle)) }
            return addKey(pk)
        default: return nil
        }
    }

    /// A function name for a non-computed key ("get x" for getters).
    func keyName(_ k: Int32, prefix: String = "") -> JSValue {
        let kn = ast[k]
        switch kn.kind {
        case .identifierName, .string:
            if prefix.isEmpty { return atom(kn.a) }
            return atomValue(prefix + ast.text(kn.a))
        case .number:
            let i = Int(kn.a)
            let d = i >= 0 && i < ast.numbers.count ? ast.numbers[i] : 0
            let s = heap.swiftString(heap.numberToString(d))
            return atomValue(prefix + s)
        case .bigint:
            return atomValue(prefix + heap.swiftString(bigintKeyString(kn)))
        default: return .string(0)
        }
    }

    /// The property key text of a BigInt literal key (`{1n: x}` is "1").
    func bigintKeyString(_ kn: JSNode) -> JSValue {
        var tooBig = false
        guard let b = jsBNParseString(Array(ast.str(kn.a)), maxBits: heap.limits.maxBigIntBits, tooBig: &tooBig) else {
            return .string(0)
        }
        let v = heap.newBigInt(b)
        _ = heap.root(v)
        let s = heap.bigintToString(v)
        _ = heap.root(s)
        return s
    }

    func emitObjectLiteral(_ n: Int32) throws(JSCompileError) {
        let node = ast[n]
        try emit(.newObject, 1)
        for p in ast.list(node.a, node.b) {
            let pn = ast[p]
            setPos(p)
            if pn.kind == .spread {
                try emitExpr(pn.a)
                try emit(.copyDataProps, -1)
                continue
            }
            guard pn.kind == .property else { throw fail("unexpected property", p) }
            let computed = pn.flags & JSNodeFlags.computed != 0
            let pkind = JSPropertyKind(rawValue: pn.op) ?? .initializer
            if ast.kind(pn.a) == .privateName {
                try notSupported("private names in object literals")
                continue
            }
            if pkind == .initializer {
                let kn = ast[pn.a]
                if !computed && pn.flags & JSNodeFlags.shorthand == 0 && (kn.kind == .identifierName || kn.kind == .string)
                    && kn.a == JSWord.proto {
                    try emitExpr(pn.b)
                    try emit(.setProto, -1)
                    continue
                }
                if computed {
                    try emitExpr(pn.a)
                    try emit(.toPropertyKey, 0)
                    try emitExpr(pn.b)
                    try emit(.defineElem, -2)
                } else {
                    guard let k = try staticKey(pn.a) else { throw fail("bad key", p) }
                    try emitExpr(pn.b, nameHint: keyName(pn.a))
                    try emitU32(.defineField, k, -1)
                }
                continue
            }
            var flags: UInt8 = JSMethodFlags.enumerable | JSMethodFlags.home
            var prefix = ""
            if pkind == .getter { flags |= JSMethodFlags.getter; prefix = "get " }
            if pkind == .setter { flags |= JSMethodFlags.setter; prefix = "set " }
            try emitMethodDefinition(pn, flags: flags, prefix: prefix)
        }
    }

    /// [target] -> [target] with a method/getter/setter defined.
    func emitMethodDefinition(_ pn: JSNode, flags: UInt8, prefix: String) throws(JSCompileError) {
        let computed = pn.flags & JSNodeFlags.computed != 0
        guard pn.b >= 0 else { throw internalError("method without function") }
        if computed {
            try emitExpr(pn.a)
            try emit(.toPropertyKey, 0)
            let code = try compileFunction(pn.b, name: .string(0))
            try emitU32(.closure, addConst(code.codeObject), 1)
            try emitU8(.defineMethodElem, flags, -2)
        } else {
            guard let k = try staticKey(pn.a) else { throw internalError("method key") }
            let code = try compileFunction(pn.b, name: keyName(pn.a, prefix: prefix))
            try emitU32(.closure, addConst(code.codeObject), 1)
            try emit(.defineMethod, -1)
            put32(k)
            fs.code.bytes.append(flags)
        }
    }

    // MARK: Destructuring

    /// Store the value on the stack into a binding target (consumes it).
    func emitBindingInit(_ t: Int32, mode: JSBindMode) throws(JSCompileError) {
        try guardStack(t)
        let tn = ast[t]
        switch tn.kind {
        case .identifier:
            if mode == .assign {
                let r = try prepareRef(t)
                try storeRefKeep(r)
                try emit(.pop, -1)
            } else {
                try emitStoreRef(sa.ref(t), name: tn.a, initialize: mode == .initialize)
            }
        case .assignPattern:
            let l = newLabel()
            try emit(.dup, 1)
            try emit(.pushUndefined, 1)
            try emit(.strictEq, -1)
            try emitJump(.jumpIfFalse, l, effect: -1)
            try emit(.pop, -1)
            let hint: JSValue? = ast.kind(tn.a) == .identifier ? atom(ast[tn.a].a) : nil
            try emitExpr(tn.b, nameHint: hint)
            try place(l)
            try emitBindingInit(tn.a, mode: mode)
        case .objectPattern:
            try emitObjectPattern(t, mode: mode)
        case .arrayPattern:
            try emitArrayPattern(t, mode: mode)
        case .member, .index, .privateMember:
            let tmp = tempLocal()
            try emitU32(.putLocal, tmp, -1)
            let r = try prepareRef(t)
            try emitU32(.getLocal, tmp, 1)
            try storeRefKeep(r)
            try emit(.pop, -1)
            freeTemp(tmp)
        case .call:
            // for (f() in o): the call runs each iteration, then throws.
            try emit(.pop, -1)
            try emitExpr(t)
            try emit(.pop, -1)
            try throwError(.referenceError, "Invalid left-hand side in assignment")
        default:
            try emit(.pop, -1)
            try throwError(.referenceError, "Invalid destructuring assignment target")
        }
    }

    func emitObjectPattern(_ t: Int32, mode: JSBindMode) throws(JSCompileError) {
        let tn = ast[t]
        setPos(t)
        try emit(.checkObjectCoercible, 0)
        var excluded: [JSValue] = []
        var hasRest = false, hasComputed = false
        for p in ast.list(tn.a, tn.b) {
            if ast.kind(p) == .rest { hasRest = true }
            if ast.kind(p) == .property && ast[p].flags & JSNodeFlags.computed != 0 { hasComputed = true }
        }
        // With computed keys and a rest element, the excluded keys are
        // collected at run time in an array.
        var keysTmp = -1
        if hasRest && hasComputed {
            keysTmp = tempLocal()
            try emitU32(.newArray, 0, 1)
            try emitU32(.putLocal, keysTmp, -1)
        }
        for p in ast.list(tn.a, tn.b) {
            let pn = ast[p]
            if pn.kind == .rest && keysTmp >= 0 {
                try emit(.dup, 1)
                try emitU32(.getLocal, keysTmp, 1)
                try emit(.objectRestDynamic, -1)
                try emitBindingInit(pn.a, mode: mode)
                continue
            }
            if pn.kind == .rest {
                let d = heap.newObject(proto: .null, kind: .internalObject, flags: [])
                _ = heap.root(d)
                heap.setSlots(d, excluded)
                try emit(.dup, 1)
                try emitU32(.objectRest, addConst(d), 0)
                try emitBindingInit(pn.a, mode: mode)
                continue
            }
            guard pn.kind == .property else { continue }
            try emit(.dup, 1)
            if pn.flags & JSNodeFlags.computed != 0 {
                try emitExpr(pn.a)
                try emit(.toPropertyKey, 0)
                if keysTmp >= 0 {
                    try emit(.dup, 1)
                    try emitU32(.getLocal, keysTmp, 1)
                    try emit(.swap, 0)
                    try emit(.appendElem, -1)
                    try emit(.pop, -1)
                }
                try emit(.getElem, -1)
            } else {
                guard let k = try staticKey(pn.a) else { throw fail("bad pattern key", p) }
                let kk = fs.code.keys[k]
                let kv = heap.keyValue(kk)
                _ = heap.root(kv)
                excluded.append(kv)
                if keysTmp >= 0 {
                    try emitU32(.getLocal, keysTmp, 1)
                    try emitU32(.pushConst, addConst(kv), 1)
                    try emit(.appendElem, -1)
                    try emit(.pop, -1)
                }
                try emitU32(.getField, k, 0)
            }
            guard pn.b >= 0 else { throw internalError("pattern property target") }
            try emitBindingInit(pn.b, mode: mode)
        }
        try emit(.pop, -1)
        if keysTmp >= 0 { freeTemp(keysTmp) }
    }

    func emitArrayPattern(_ t: Int32, mode: JSBindMode) throws(JSCompileError) {
        let tn = ast[t]
        setPos(t)
        try emit(.getIterator, 1)
        // An exception while binding the elements closes the iterator
        // (unless the iterator itself threw: its record is null then).
        let pdepth = fs.depth
        let start = fs.code.bytes.count
        for e in ast.list(tn.a, tn.b) {
            switch ast.kind(e) {
            case .hole:
                try emit(.iterStepValue, 1)
                try emit(.pop, -1)
            case .rest:
                try emit(.iterRest, 1)
                try emitBindingInit(ast[e].a, mode: mode)
            default:
                try emit(.iterStepValue, 1)
                try emitBindingInit(e, mode: mode)
            }
        }
        let end = fs.code.bytes.count
        try emit(.iterClose, -2)
        if end > start {
            let after = newLabel(), landing = newLabel()
            try emitJump(.jump, after)
            fs.depth = pdepth
            try place(landing, dead: true)
            fs.labels[landing].depth = pdepth
            fs.code.handlers.append(JSHandler(start: UInt32(start), end: UInt32(end),
                                              target: UInt32(fs.labels[landing].pc), depth: UInt32(pdepth)))
            try adjust(1)
            try emit(.iterCloseThrow, -3)
            fs.depth = pdepth - 2
            try place(after, dead: true)
        }
    }

    // MARK: Classes

    /// A class definition: leaves the constructor on the stack.
    func emitClass(_ n: Int32, nameHint: JSValue?) throws(JSCompileError) {
        let node = ast[n]
        setPos(n)
        guard let cs = sa.nodeScope[n] else { throw internalError("class scope") }
        let members = Array(ast.list(node.c, node.d))
        var className: JSValue = .string(0)
        if node.a >= 0 { className = atom(ast[node.a].a) } else if let h = nameHint { className = h }
        // Unsupported member forms throw when the class is evaluated.
        for m in members {
            let mn = ast[m]
            guard mn.kind == .property else { continue }
        }
        try enterScope(cs)
        // Private names: one fresh record per class evaluation.
        var privDone: Set<Int32> = []
        for m in members {
            let mn = ast[m]
            guard mn.kind == .property, ast.kind(mn.a) == .privateName else { continue }
            let id = ast[mn.a].a
            if !privDone.insert(id).inserted { continue }
            guard let b = sa.scopes[Int(cs)].names[JSPseudoName.privateName(id)] else { throw internalError("private name binding") }
            let pk = JSPropertyKind(rawValue: mn.op) ?? .method
            let kind: UInt8 = pk == .field ? 0 : pk == .method ? 1 : 2
            try emit(.newPrivateName, 1)
            put32(addConst(atomValue("#" + ast.text(id))))
            fs.code.bytes.append(kind)
            try emitPutBinding(b, initialize: true)
        }
        let derived = node.b >= 0
        if derived { try emitExpr(node.b) }
        var ctorFn: Int32 = -1
        var hasInstanceFields = false
        var hasStatic = false
        for m in members {
            let mn = ast[m]
            if mn.kind == .staticBlock { hasStatic = true; continue }
            guard mn.kind == .property else { continue }
            if mn.op == JSPropertyKind.field.rawValue {
                if mn.flags & JSNodeFlags.isStatic != 0 { hasStatic = true } else { hasInstanceFields = true }
                continue
            }
            if ast.kind(mn.a) == .privateName && mn.flags & JSNodeFlags.isStatic == 0 { hasInstanceFields = true }
            if mn.b >= 0 {
                let fk = ast[mn.b].op
                if fk == JSFunctionKind.classConstructor.rawValue || fk == JSFunctionKind.derivedConstructor.rawValue {
                    ctorFn = mn.b
                }
            }
        }
        let ctorCode: JSCode
        if ctorFn >= 0 {
            ctorCode = try compileFunction(ctorFn, name: className)
        } else {
            ctorCode = try compileDefaultConstructor(n, derived: derived, name: className)
        }
        ctorCode.hasPrototype = false
        ctorCode.sourceStart = node.start
        ctorCode.sourceEnd = node.end
        try emit(.newClass, derived ? 1 : 2)
        put32(addConst(ctorCode.codeObject))
        fs.code.bytes.append(derived ? 1 : 0)
        // [ctor proto]
        var staticPrivate: [Int32] = []
        for m in members {
            let mn = ast[m]
            guard mn.kind == .property, mn.b != ctorFn else { continue }
            let isStatic = mn.flags & JSNodeFlags.isStatic != 0
            if mn.op == JSPropertyKind.field.rawValue {
                // A computed field key is evaluated here, in member order.
                if mn.flags & JSNodeFlags.computed != 0 && ast.kind(mn.a) != .privateName {
                    guard let b = sa.scopes[Int(cs)].names[JSPseudoName.computedField(m)] else { throw internalError("field key binding") }
                    setPos(m)
                    try emitExpr(mn.a)
                    try emit(.toPropertyKey, 0)
                    try emitPutBinding(b, initialize: true)
                }
                continue
            }
            let pkind = JSPropertyKind(rawValue: mn.op) ?? .method
            if ast.kind(mn.a) == .privateName {
                // [ctor proto] -> the function goes into the private record.
                let id = ast[mn.a].a
                guard let b = sa.scopes[Int(cs)].names[JSPseudoName.privateName(id)], mn.b >= 0 else { throw internalError("private method") }
                setPos(m)
                let prefix = pkind == .getter ? "get " : pkind == .setter ? "set " : ""
                if isStatic { try emit(.swap, 0) }
                let code = try compileFunction(mn.b, name: atomValue(prefix + "#" + ast.text(id)))
                try emitU32(.closure, addConst(code.codeObject), 1)
                try emit(.over, 1)
                try emit(.setHomeObject, -1)
                try emitGetBinding(b, checked: false)
                try emit(.swap, 0)
                try emitU8(.setPrivateMethod, pkind == .getter ? 1 : pkind == .setter ? 2 : 0, -2)
                if isStatic {
                    try emit(.swap, 0)
                    if !staticPrivate.contains(id) { staticPrivate.append(id) }
                }
                continue
            }
            var flags: UInt8 = JSMethodFlags.home
            var prefix = ""
            if pkind == .getter { flags |= JSMethodFlags.getter; prefix = "get " }
            if pkind == .setter { flags |= JSMethodFlags.setter; prefix = "set " }
            setPos(m)
            if isStatic { try emit(.swap, 0) }
            try emitMethodDefinition(mn, flags: flags, prefix: prefix)
            if isStatic { try emit(.swap, 0) }
        }
        if hasInstanceFields {
            let fi = try compileFieldInit(n, isStatic: false)
            try emitU32(.closure, addConst(fi.codeObject), 1)
            try emit(.setFieldInit, -1)
        }
        try emit(.pop, -1)
        // [ctor]: static private methods, then static fields and blocks.
        for id in staticPrivate {
            guard let b = sa.scopes[Int(cs)].names[JSPseudoName.privateName(id)] else { throw internalError("private name") }
            try emit(.dup, 1)
            try emitGetBinding(b, checked: false)
            try emit(.addPrivateBrand, -1)
            try emit(.pop, -1)
        }
        // The inner name is bound before static fields and blocks run.
        if node.a >= 0, let inner = sa.scopes[Int(cs)].names[ast[node.a].a] {
            try emit(.dup, 1)
            try emitPutBinding(inner, initialize: true)
        }
        if hasStatic {
            let si = try compileFieldInit(n, isStatic: true)
            try emitU32(.closure, addConst(si.codeObject), 1)
            try emit(.over, 1)
            try emit(.setHomeObject, -1)
            try emit(.over, 1)
            try emitU16(.call, 0, -1)
            try emit(.pop, -1)
        }
        try exitScope(cs)
    }

    func beginSynthetic(_ scope: Int32, kind: JSCodeKind, start: UInt32, end: UInt32) {
        fsStack.append(fs)
        fs = JSFuncState()
        fs.code.source = source
        fs.code.kind = kind
        fs.code.strict = true
        fs.code.sourceStart = start
        fs.code.sourceEnd = end
        fs.fnScope = scope
        fs.scope = scope
        fs.pos = start
    }

    func compileDefaultConstructor(_ n: Int32, derived: Bool, name: JSValue) throws(JSCompileError) -> JSCode {
        let node = ast[n]
        guard let cs = sa.nodeScope[n] else { throw internalError("class scope") }
        beginSynthetic(cs, kind: derived ? .derivedConstructor : .classConstructor, start: node.start, end: node.end)
        defer { fs = fsStack.removeLast() }
        fs.code.isConstructor = true
        if derived {
            fs.code.restLocal = newLocal()
            try emit(.loadCallee, 1)
            try emit(.loadNewTarget, 1)
            try emitU32(.getLocal, fs.code.restLocal, 1)
            try emit(.superCallArray, -2)
            try emit(.dup, 1)
            try emit(.loadCallee, 1)
            try emit(.runFieldInit, -2)
            try emit(.ret, -1)
        } else {
            try emit(.loadThis, 1)
            try emit(.loadCallee, 1)
            try emit(.runFieldInit, -2)
            try emit(.retUndefined, 0)
        }
        return try finishFunction(name: name, nameHint: nil)
    }

    /// The instance-field initializer (this = the new object) or the static
    /// initializer (this = the class: static fields and blocks in order).
    func compileFieldInit(_ n: Int32, isStatic: Bool) throws(JSCompileError) -> JSCode {
        let node = ast[n]
        guard let s = isStatic ? sa.classStaticScope[n] : sa.classFieldScope[n] else {
            throw internalError("field scope")
        }
        beginSynthetic(s, kind: .fieldInit, start: node.start, end: node.end)
        defer { fs = fsStack.removeLast() }
        computeBlockEnvs(s)
        try enterScope(s)
        try emitPseudoPrologue(s)
        // Instance private methods and accessors come before the fields.
        if !isStatic {
            var done: Set<Int32> = []
            for m in ast.list(node.c, node.d) {
                let mn = ast[m]
                guard mn.kind == .property, mn.op != JSPropertyKind.field.rawValue, ast.kind(mn.a) == .privateName,
                      mn.flags & JSNodeFlags.isStatic == 0 else { continue }
                let id = ast[mn.a].a
                if !done.insert(id).inserted { continue }
                let b = pseudoBinding(JSPseudoName.privateName(id))
                if b < 0 { throw internalError("private brand") }
                setPos(m)
                try emitThis()
                try emitGetBinding(b, checked: false)
                try emit(.addPrivateBrand, -1)
                try emit(.pop, -1)
            }
        }
        for m in ast.list(node.c, node.d) {
            let mn = ast[m]
            setPos(m)
            if mn.kind == .staticBlock {
                guard isStatic else { continue }
                let blk = try compileStaticBlock(m)
                try emitU32(.closure, addConst(blk.codeObject), 1)
                try emitThis()
                try emit(.setHomeObject, -1)
                try emitThis()
                try emitU16(.call, 0, -1)
                try emit(.pop, -1)
                continue
            }
            guard mn.kind == .property, mn.op == JSPropertyKind.field.rawValue,
                  (mn.flags & JSNodeFlags.isStatic != 0) == isStatic else { continue }
            if ast.kind(mn.a) == .privateName {
                let id = ast[mn.a].a
                let b = pseudoBinding(JSPseudoName.privateName(id))
                if b < 0 { throw internalError("private field") }
                try emitThis()
                try emitGetBinding(b, checked: false)
                if mn.b >= 0 { try emitExpr(mn.b, nameHint: atomValue("#" + ast.text(id))) } else { try emit(.pushUndefined, 1) }
                try emit(.definePrivate, -3)
                continue
            }
            if mn.flags & JSNodeFlags.computed != 0 {
                let b = pseudoBinding(JSPseudoName.computedField(m))
                if b < 0 { throw internalError("computed field") }
                try emitThis()
                try emitGetBinding(b, checked: false)
                if mn.b >= 0 { try emitExpr(mn.b) } else { try emit(.pushUndefined, 1) }
                try emit(.defineElem, -2)
                try emit(.pop, -1)
                continue
            }
            guard let k = try staticKey(mn.a) else { throw internalError("field key") }
            try emitThis()
            if mn.b >= 0 { try emitExpr(mn.b, nameHint: keyName(mn.a)) } else { try emit(.pushUndefined, 1) }
            try emitU32(.defineField, k, -1)
            try emit(.pop, -1)
        }
        try emit(.retUndefined, 0)
        return try finishFunction(name: .string(0), nameHint: nil)
    }

    func compileStaticBlock(_ m: Int32) throws(JSCompileError) -> JSCode {
        let mn = ast[m]
        guard let s = sa.nodeScope[m] else { throw internalError("static block scope") }
        beginSynthetic(s, kind: .method, start: mn.start, end: mn.end)
        defer { fs = fsStack.removeLast() }
        computeBlockEnvs(s)
        try enterScope(s)
        try emitPseudoPrologue(s)
        let stmts = ast.list(mn.a, mn.b)
        try hoistFunctions(stmts, scope: s)
        for st in stmts { try emitStatement(st) }
        try emit(.retUndefined, 0)
        return try finishFunction(name: .string(0), nameHint: nil)
    }
}
