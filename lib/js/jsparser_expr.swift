// lib/js parser, part 2: expressions, patterns and the cover grammars.
//
// Cover grammars. Array and object literals are parsed as expressions and
// converted in place to patterns when an `=` (or a for-in/of head) shows
// they were destructuring targets; parenthesised lists and `async(...)`
// calls are converted to arrow parameters when `=>` follows. Constructs
// that are only valid in a pattern (`{a = 1}`, a duplicate __proto__) set
// coverErrPos; each parseAssignment either consumes the position (it
// converted the literal), hands it up to an enclosing literal that may
// still convert (coverOK), or reports it.

extension JSParser {
    @inline(__always) func isArrow(_ n: Int32) -> Bool {
        let nd = ast.nodes[Int(n)]
        return nd.kind == .function && nd.op == JSFunctionKind.arrow.rawValue
            && nd.flags & JSNodeFlags.parenthesized == 0
    }

    func parseExpression(noIn: Bool) throws(JSSyntaxError) -> Int32 {
        let start = tok.start
        let e = try parseAssignment(noIn: noIn)
        if tok.kind != .comma { return e }
        let mark = scratch.count
        scratch.append(e)
        while try eat(.comma) { scratch.append(try parseAssignment(noIn: noIn)) }
        let (ls, lc) = finishList(mark)
        return try node(.sequence, start, ls, lc)
    }

    /// An Expression whose items may still become patterns (for heads).
    func parseExpressionCover(noIn: Bool) throws(JSSyntaxError) -> Int32 {
        let start = tok.start
        let e = try parseAssignment(noIn: noIn, coverOK: true)
        if tok.kind != .comma { return e }
        let mark = scratch.count
        scratch.append(e)
        while try eat(.comma) { scratch.append(try parseAssignment(noIn: noIn)) }
        let (ls, lc) = finishList(mark)
        return try node(.sequence, start, ls, lc)
    }

    func parseAssignment(noIn: Bool, coverOK: Bool = false) throws(JSSyntaxError) -> Int32 {
        try enter()
        defer { leave() }
        if isWord(JSWord.yield_) && fn.generator { return try parseYield(noIn: noIn) }
        let start = tok.start
        let savedErr = coverErrPos, savedMsg = coverErrMsg
        coverErrPos = -1
        let left = try parseConditional(noIn: noIn)
        if isArrow(left) {
            coverErrPos = savedErr; coverErrMsg = savedMsg
            return left
        }
        let lk = k(left)
        let kr = tok.kind.rawValue
        if kr >= JSTok.assign.rawValue && kr <= JSTok.nullishAssign.rawValue {
            let op = kr - JSTok.assign.rawValue
            if tok.kind == .assign && (lk == .object || lk == .array) && !isParen(left) {
                try toAssignTarget(left, allowPattern: true)
                coverErrPos = -1
            } else {
                try checkSimpleTarget(left)
            }
            if coverErrPos >= 0 { throw error(coverErrMsg, coverErrPos) }
            try advance()
            let right = try parseAssignment(noIn: noIn)
            coverErrPos = savedErr; coverErrMsg = savedMsg
            return try node(.assign, start, op: op, left, right)
        }
        if coverErrPos >= 0 {
            if !coverOK || !(lk == .object || lk == .array) || isParen(left) {
                throw error(coverErrMsg, coverErrPos)
            }
            if savedErr >= 0 { coverErrPos = savedErr; coverErrMsg = savedMsg }
            return left
        }
        coverErrPos = savedErr; coverErrMsg = savedMsg
        return left
    }

    func setCoverError(_ pos: Int, _ msg: String) {
        if coverErrPos < 0 { coverErrPos = pos; coverErrMsg = msg }
    }

    func startsExpression(_ t: JSToken) -> Bool {
        switch t.kind {
        case .name:
            return t.escaped || (t.value != JSWord.in_ && t.value != JSWord.instanceof_)
        case .privateName, .string, .number, .bigint, .template, .templateHead, .slash, .slashAssign,
             .lbrace, .lparen, .lbracket, .plus, .minus, .bang, .tilde, .inc, .dec:
            return true
        default:
            return false
        }
    }

    func parseYield(noIn: Bool) throws(JSSyntaxError) -> Int32 {
        let start = tok.start
        if fn.inParams { throw error("yield is not allowed in parameters", start) }
        try advance()
        var arg: Int32 = -1
        var flags: UInt16 = 0
        if !tok.nl {
            if tok.kind == .star {
                try advance()
                flags = JSNodeFlags.delegate
                arg = try parseAssignment(noIn: noIn)
            } else if startsExpression(tok) {
                arg = try parseAssignment(noIn: noIn)
            }
        }
        lastYieldAwait = start
        return try node(.yieldExpr, start, flags: flags, arg)
    }

    func parseConditional(noIn: Bool) throws(JSSyntaxError) -> Int32 {
        let start = tok.start
        let test = try parseBinary(0, noIn: noIn)
        if tok.kind != .question || isArrow(test) { return test }
        try advance()
        let cons = try parseAssignment(noIn: false)
        try expect(.colon)
        let alt = try parseAssignment(noIn: noIn)
        return try node(.conditional, start, test, cons, alt)
    }

    /// (precedence, operator) of the current token as a binary operator.
    @inline(__always) func binaryInfo(noIn: Bool) -> (Int, JSBinaryOp) {
        switch tok.kind {
        case .nullish: return (1, .nullish)
        case .orOr: return (2, .logicalOr)
        case .andAnd: return (3, .logicalAnd)
        case .pipe: return (4, .bitOr)
        case .caret: return (5, .bitXor)
        case .amp: return (6, .bitAnd)
        case .eq: return (7, .eq)
        case .ne: return (7, .ne)
        case .strictEq: return (7, .strictEq)
        case .strictNe: return (7, .strictNe)
        case .lt: return (8, .lt)
        case .gt: return (8, .gt)
        case .le: return (8, .le)
        case .ge: return (8, .ge)
        case .shl: return (9, .shl)
        case .sar: return (9, .sar)
        case .shr: return (9, .shr)
        case .plus: return (10, .add)
        case .minus: return (10, .sub)
        case .star: return (11, .mul)
        case .slash: return (11, .div)
        case .percent: return (11, .mod)
        case .starStar: return (12, .exp)
        case .name:
            if tok.escaped { return (0, .add) }
            if tok.value == JSWord.instanceof_ { return (8, .instanceof) }
            if tok.value == JSWord.in_ && !noIn { return (8, .in) }
            return (0, .add)
        default: return (0, .add)
        }
    }

    func isLogical(_ n: Int32, _ ops: (JSBinaryOp, JSBinaryOp)) -> Bool {
        let nd = ast.nodes[Int(n)]
        return nd.kind == .binary && nd.flags & JSNodeFlags.parenthesized == 0
            && (nd.op == ops.0.rawValue || nd.op == ops.1.rawValue)
    }

    func parseBinary(_ minPrec: Int, noIn: Bool) throws(JSSyntaxError) -> Int32 {
        let start = tok.start
        var left: Int32
        if tok.kind == .privateName {
            // `#x in obj`
            let name = tok.value
            try advance()
            if !isWord(JSWord.in_) || noIn || minPrec > 8 { throw error("unexpected private name", start) }
            try usePrivate(name, start)
            left = try node(.privateName, start, name)
        } else {
            left = try parseUnary()
        }
        while true {
            let (prec, op) = binaryInfo(noIn: noIn)
            if prec == 0 || prec < minPrec || isArrow(left) { break }
            if op == .exp {
                let lk = k(left)
                if (lk == .unary || lk == .awaitExpr) && !isParen(left) {
                    throw error("unparenthesized unary expression can't appear on the left of '**'", tok.start)
                }
            }
            if k(left) == .privateName && op != .in { throw error("unexpected private name", start) }
            try advance()
            let right: Int32
            if op == .exp {
                try enter()
                right = try parseBinary(prec, noIn: noIn)
                leave()
            } else {
                right = try parseBinary(prec + 1, noIn: noIn)
            }
            if isArrow(right) { throw error("arrow function must be parenthesized here", Int(ast.nodes[Int(right)].start)) }
            if op == .nullish {
                if isLogical(left, (.logicalAnd, .logicalOr)) || isLogical(right, (.logicalAnd, .logicalOr)) {
                    throw error("'??' can't be mixed with '&&' or '||' without parentheses", start)
                }
            } else if op == .logicalAnd || op == .logicalOr {
                if isLogical(left, (.nullish, .nullish)) || isLogical(right, (.nullish, .nullish)) {
                    throw error("'??' can't be mixed with '&&' or '||' without parentheses", start)
                }
            }
            left = try node(.binary, start, op: op.rawValue, left, right)
        }
        if k(left) == .privateName { throw error("unexpected private name", start) }
        return left
    }

    func parseUnary() throws(JSSyntaxError) -> Int32 {
        let start = tok.start
        var op: JSUnaryOp? = nil
        switch tok.kind {
        case .plus: op = .plus
        case .minus: op = .minus
        case .bang: op = .not
        case .tilde: op = .bitNot
        case .name where !tok.escaped:
            if tok.value == JSWord.delete_ { op = .delete }
            else if tok.value == JSWord.void_ { op = .void }
            else if tok.value == JSWord.typeof_ { op = .typeof }
            else if tok.value == JSWord.await_ && fn.async {
                if fn.inParams { throw error("await is not allowed in parameters", start) }
                try enter()
                defer { leave() }
                try advance()
                let arg = try parseUnary()
                if isArrow(arg) { throw unexpected() }
                lastYieldAwait = start
                return try node(.awaitExpr, start, arg)
            }
        case .inc, .dec:
            let isInc = tok.kind == .inc
            try enter()
            defer { leave() }
            try advance()
            let arg = try parseUnary()
            try checkSimpleTarget(arg)
            return try node(.update, start, op: isInc ? 0 : 1, flags: JSNodeFlags.prefix, arg)
        default: break
        }
        if let op = op {
            try enter()
            defer { leave() }
            try advance()
            let arg = try parseUnary()
            if isArrow(arg) { throw error("arrow function must be parenthesized here", Int(ast.nodes[Int(arg)].start)) }
            if op == .delete {
                var inner = arg
                while k(inner) == .optionalChain { inner = ast.nodes[Int(inner)].a }
                if fn.strict && k(inner) == .identifier {
                    throw error("delete of an unqualified identifier in strict mode", start)
                }
                if k(inner) == .privateMember { throw error("private fields can't be deleted", start) }
            }
            return try node(.unary, start, op: op.rawValue, arg)
        }
        let e = try parseLeftHandSide()
        if (tok.kind == .inc || tok.kind == .dec) && !tok.nl && !isArrow(e) {
            try checkSimpleTarget(e)
            let isInc = tok.kind == .inc
            try advance()
            return try node(.update, start, op: isInc ? 0 : 1, e)
        }
        return e
    }

    /// LeftHandSideExpression: new, call and member expressions.
    func parseLeftHandSide() throws(JSSyntaxError) -> Int32 {
        let start = tok.start
        let base: Int32
        if isWord(JSWord.new_) {
            base = try parseNew()
        } else if isWord(JSWord.super_) {
            base = try parseSuper()
        } else if isWord(JSWord.import_) {
            base = try parseImportExpr(allowCall: true)
        } else {
            base = try parsePrimary()
        }
        return try parseSuffixes(base, start, allowCall: true)
    }

    func parseNew() throws(JSSyntaxError) -> Int32 {
        let start = tok.start
        try enter()
        defer { leave() }
        try advance() // new
        if tok.kind == .dot {
            try advance()
            if !isWord(JSWord.target) { throw unexpected() }
            if !fn.newTarget { throw error("new.target is only valid in functions", start) }
            try advance()
            fn.usesThis = true
            return try node(.newTarget, start)
        }
        let cstart = tok.start
        var callee: Int32
        if isWord(JSWord.new_) {
            callee = try parseNew()
        } else if isWord(JSWord.super_) {
            callee = try parseSuper()
            if k(callee) == .call { throw unexpected() }
        } else if isWord(JSWord.import_) {
            callee = try parseImportExpr(allowCall: false)
        } else {
            callee = try parsePrimary()
        }
        if isArrow(callee) { throw unexpected() }
        callee = try parseSuffixes(callee, cstart, allowCall: false)
        var ls: Int32 = Int32(truncatingIfNeeded: ast.lists.count), lc: Int32 = 0
        if tok.kind == .lparen {
            (ls, lc) = try parseArguments()
        }
        return try node(.newExpr, start, callee, ls, lc)
    }

    func parseSuper() throws(JSSyntaxError) -> Int32 {
        let start = tok.start
        try advance()
        fn.usesThis = true
        if tok.kind == .lparen {
            if !fn.superCall { throw error("'super' call is only valid in derived class constructors", start) }
            let sup = try node(.superExpr, start)
            let (ls, lc) = try parseArguments()
            return try node(.call, start, sup, ls, lc)
        }
        if tok.kind == .dot || tok.kind == .lbracket {
            if !fn.superProp { throw error("'super' is only valid in methods", start) }
            return try node(.superExpr, start)
        }
        throw error("unexpected 'super'", start)
    }

    func parseImportExpr(allowCall: Bool) throws(JSSyntaxError) -> Int32 {
        let start = tok.start
        try advance() // import
        if tok.kind == .dot {
            try advance()
            if !isWord(JSWord.meta) { throw unexpected() }
            if !opts.module { throw error("import.meta is only valid in modules", start) }
            try advance()
            return try node(.importMeta, start)
        }
        if tok.kind == .lparen && allowCall {
            try advance()
            let arg = try parseAssignment(noIn: false)
            try expect(.rparen)
            return try node(.importCall, start, arg)
        }
        throw unexpected()
    }

    func parseArguments() throws(JSSyntaxError) -> (Int32, Int32) {
        try expect(.lparen)
        let mark = scratch.count
        while tok.kind != .rparen {
            if tok.kind == .ellipsis {
                let s = tok.start
                try advance()
                let a = try parseAssignment(noIn: false)
                scratch.append(try node(.spread, s, a))
            } else {
                scratch.append(try parseAssignment(noIn: false))
            }
            if tok.kind != .rparen { try expect(.comma) }
        }
        try advance()
        return finishList(mark)
    }

    func parseSuffixes(_ base: Int32, _ start: Int, allowCall: Bool) throws(JSSyntaxError) -> Int32 {
        var e = base
        var chain = false
        let b = ast.nodes[Int(base)]
        var asyncCover = allowCall && b.kind == .identifier && b.a == JSWord.async_
            && b.flags & JSNodeFlags.parenthesized == 0 && Int(b.end) - Int(b.start) == 5
            && tok.kind == .lparen && !tok.nl
        var steps = 0
        while true {
            if isArrow(e) { break }
            steps += 1
            switch tok.kind {
            case .dot:
                try advance()
                if tok.kind == .privateName {
                    let name = tok.value
                    try usePrivate(name, tok.start)
                    try advance()
                    e = try node(.privateMember, start, e, name)
                } else if tok.kind == .name {
                    let name = tok.value
                    try advance()
                    e = try node(.member, start, e, name)
                } else {
                    throw unexpected()
                }
            case .questionDot:
                if !allowCall { throw error("optional chain is not allowed in 'new'", tok.start) }
                chain = true
                try advance()
                switch tok.kind {
                case .lparen:
                    let (ls, lc) = try parseArguments()
                    e = try node(.call, start, flags: JSNodeFlags.optional, e, ls, lc)
                case .lbracket:
                    try advance()
                    let key = try parseExpression(noIn: false)
                    try expect(.rbracket)
                    e = try node(.index, start, flags: JSNodeFlags.optional, e, key)
                case .privateName:
                    let name = tok.value
                    try usePrivate(name, tok.start)
                    try advance()
                    e = try node(.privateMember, start, flags: JSNodeFlags.optional, e, name)
                case .name:
                    let name = tok.value
                    try advance()
                    e = try node(.member, start, flags: JSNodeFlags.optional, e, name)
                default:
                    throw unexpected()
                }
            case .lbracket:
                try advance()
                let key = try parseExpression(noIn: false)
                try expect(.rbracket)
                e = try node(.index, start, e, key)
            case .lparen:
                if !allowCall { return chain ? try node(.optionalChain, start, e) : e }
                if asyncCover && steps == 1 {
                    let r = try parseAsyncCallOrArrow(start, e)
                    if isArrow(r) { return r }
                    e = r
                } else {
                    let callee = ast.nodes[Int(e)]
                    let (ls, lc) = try parseArguments()
                    if callee.kind == .identifier && callee.a == JSWord.eval { fn.hasEval = true }
                    e = try node(.call, start, e, ls, lc)
                }
            case .template, .templateHead:
                if chain { throw error("tagged template in an optional chain", tok.start) }
                let t = try parseTemplate(tagged: true)
                e = try node(.taggedTemplate, start, e, t)
            default:
                return chain ? try node(.optionalChain, start, e) : e
            }
            asyncCover = false
        }
        return chain ? try node(.optionalChain, start, e) : e
    }

    /// `async(...)`: a call, or the parameters of an async arrow.
    func parseAsyncCallOrArrow(_ start: Int, _ callee: Int32) throws(JSSyntaxError) -> Int32 {
        let savedErr = coverErrPos, savedMsg = coverErrMsg
        coverErrPos = -1
        try advance() // (
        let mark = scratch.count
        var spreadComma = false
        while tok.kind != .rparen {
            if tok.kind == .ellipsis {
                let s = tok.start
                try advance()
                let a = try parseAssignment(noIn: false, coverOK: true)
                scratch.append(try node(.spread, s, a))
                if tok.kind == .comma { spreadComma = true }
            } else {
                scratch.append(try parseAssignment(noIn: false, coverOK: true))
            }
            if tok.kind != .rparen { try expect(.comma) }
        }
        try advance()
        if tok.kind == .arrow && !tok.nl {
            if lastYieldAwait >= start { throw error("await is not allowed in arrow parameters", lastYieldAwait) }
            if lastAwaitIdent >= start { throw error("'await' is not a valid parameter name here", lastAwaitIdent) }
            if spreadComma { throw error("rest parameter must be last", start) }
            var i = mark
            while i < scratch.count {
                try toBindingTarget(scratch[i], last: i == scratch.count - 1)
                i += 1
            }
            coverErrPos = savedErr; coverErrMsg = savedMsg
            return try parseArrowBody(start, mark, async: true, noIn: false)
        }
        if coverErrPos >= 0 { throw error(coverErrMsg, coverErrPos) }
        coverErrPos = savedErr; coverErrMsg = savedMsg
        let (ls, lc) = finishList(mark)
        return try node(.call, start, callee, ls, lc)
    }

    // ------------------------------------------------------------ primary

    func parsePrimary() throws(JSSyntaxError) -> Int32 {
        let start = tok.start
        switch tok.kind {
        case .name:
            let t = tok
            if !t.escaped {
                switch t.value {
                case JSWord.this_:
                    try advance()
                    fn.usesThis = true
                    return try node(.this, start)
                case JSWord.null_: try advance(); return try node(.nullLit, start)
                case JSWord.true_: try advance(); return try node(.trueLit, start)
                case JSWord.false_: try advance(); return try node(.falseLit, start)
                case JSWord.function_: return try parseFunctionExpression(start, async: false)
                case JSWord.class_: return try parseClass(isDecl: false)
                case JSWord.new_: return try parseNew()
                case JSWord.async_:
                    let p = try peek()
                    if p.kind == .name && !p.nl && !p.escaped && p.value == JSWord.function_ {
                        try advance()
                        return try parseFunctionExpression(start, async: true)
                    }
                    if p.kind == .name && !p.nl {
                        // async x => ...
                        try advance()
                        let pt = tok
                        let savedFn = fn
                        fn.async = true
                        fn.awaitReserved = true
                        do { try checkIdentifier(pt, binding: true) } catch { fn = savedFn; throw error }
                        fn = savedFn
                        try advance()
                        if tok.kind != .arrow || tok.nl { throw unexpected() }
                        let mark = scratch.count
                        scratch.append(try node(.identifier, pt.start, pt.value))
                        return try parseArrowBody(start, mark, async: true, noIn: false)
                    }
                default: break
                }
            }
            try checkIdentifier(t, binding: false)
            try advance()
            let id = try node(.identifier, start, t.value)
            if tok.kind == .arrow && !tok.nl {
                let mark = scratch.count
                scratch.append(id)
                return try parseArrowBody(start, mark, async: false, noIn: false)
            }
            return id
        case .number:
            if fn.strict && tok.flags & (JSNodeFlags.legacyOctal | JSNodeFlags.nonOctalDecimal) != 0 {
                throw error("legacy octal literals are not allowed in strict mode", start)
            }
            let t = tok
            try advance()
            return try node(.number, start, flags: t.flags, t.value)
        case .string:
            if fn.strict && tok.flags & JSNodeFlags.octalEscape != 0 {
                throw error("octal escape sequences are not allowed in strict mode", start)
            }
            let t = tok
            try advance()
            return try node(.string, start, flags: t.flags, t.value)
        case .bigint:
            let t = tok
            try advance()
            return try node(.bigint, start, t.value)
        case .template, .templateHead:
            return try parseTemplate(tagged: false)
        case .slash, .slashAssign:
            try rescanRegExp()
            let t = tok
            try checkRegExpFlags(t.value2, t.start)
            try advance()
            return try node(.regexp, start, t.value, t.value2)
        case .lparen:
            return try parseParen()
        case .lbracket:
            return try parseArrayLiteral()
        case .lbrace:
            return try parseObjectLiteral()
        case .privateName:
            throw error("unexpected private name", start)
        default:
            throw unexpected()
        }
    }

    func checkRegExpFlags(_ id: Int32, _ pos: Int) throws(JSSyntaxError) {
        var seen: UInt32 = 0
        for u in ast.str(id) {
            let bit: UInt32
            switch u {
            case 0x64: bit = 1    // d
            case 0x67: bit = 2    // g
            case 0x69: bit = 4    // i
            case 0x6D: bit = 8    // m
            case 0x73: bit = 16   // s
            case 0x75: bit = 32   // u
            case 0x76: bit = 64   // v
            case 0x79: bit = 128  // y
            default: throw error("invalid regular expression flags", pos)
            }
            if seen & bit != 0 { throw error("duplicate regular expression flag", pos) }
            seen |= bit
        }
        if seen & 96 == 96 { throw error("regular expression flags 'u' and 'v' can't be combined", pos) }
    }

    func parseTemplate(tagged: Bool) throws(JSSyntaxError) -> Int32 {
        let start = tok.start
        let mark = scratch.count
        while true {
            let t = tok
            if !tagged && t.value < 0 { throw error("invalid escape sequence in template", t.start) }
            try advance()
            scratch.append(try node(.templateElement, t.start, t.value, t.value2))
            if t.kind == .template || t.kind == .templateTail { break }
            scratch.append(try parseExpression(noIn: false))
            if tok.kind != .rbrace { throw unexpected() }
            try rescanTemplate()
        }
        let (ls, lc) = finishList(mark)
        return try node(.template, start, ls, lc)
    }

    /// `( ... )`: a parenthesised expression or arrow parameters.
    func parseParen() throws(JSSyntaxError) -> Int32 {
        let start = tok.start
        try advance() // (
        let mark = scratch.count
        if tok.kind == .rparen {
            try advance()
            if tok.kind != .arrow || tok.nl { throw unexpected() }
            return try parseArrowBody(start, mark, async: false, noIn: false)
        }
        let savedErr = coverErrPos, savedMsg = coverErrMsg
        coverErrPos = -1
        var restSeen = false, trailing = false
        while true {
            if tok.kind == .ellipsis {
                let s = tok.start
                try advance()
                let bmark = bound.count
                let t = try parseBindingTarget()
                bound.removeSubrange(bmark...)
                scratch.append(try node(.rest, s, t))
                restSeen = true
                break
            }
            scratch.append(try parseAssignment(noIn: false, coverOK: true))
            if tok.kind != .comma { break }
            try advance()
            if tok.kind == .rparen { trailing = true; break }
        }
        try expect(.rparen)
        if tok.kind == .arrow && !tok.nl {
            if lastYieldAwait >= start { throw error("yield/await is not allowed in arrow parameters", lastYieldAwait) }
            var i = mark
            while i < scratch.count {
                try toBindingTarget(scratch[i], last: i == scratch.count - 1)
                i += 1
            }
            coverErrPos = savedErr; coverErrMsg = savedMsg
            return try parseArrowBody(start, mark, async: false, noIn: false)
        }
        if restSeen || trailing { throw unexpected() }
        if coverErrPos >= 0 { throw error(coverErrMsg, coverErrPos) }
        coverErrPos = savedErr; coverErrMsg = savedMsg
        if scratch.count - mark == 1 {
            let e = scratch.removeLast()
            ast.nodes[Int(e)].flags |= JSNodeFlags.parenthesized
            return e
        }
        let (ls, lc) = finishList(mark)
        return try node(.sequence, start + 1, flags: JSNodeFlags.parenthesized, ls, lc)
    }

    func parseArrayLiteral() throws(JSSyntaxError) -> Int32 {
        let start = tok.start
        try advance() // [
        let mark = scratch.count
        while tok.kind != .rbracket {
            if tok.kind == .comma {
                let s = tok.start
                try advance()
                scratch.append(try node(.hole, s))
                continue
            }
            if tok.kind == .ellipsis {
                let s = tok.start
                try advance()
                let a = try parseAssignment(noIn: false, coverOK: true)
                let sp = try node(.spread, s, a)
                if tok.kind == .comma { ast.nodes[Int(sp)].flags |= JSNodeFlags.spreadNotLast }
                scratch.append(sp)
            } else {
                scratch.append(try parseAssignment(noIn: false, coverOK: true))
            }
            if tok.kind != .rbracket { try expect(.comma) }
        }
        try advance()
        let (ls, lc) = finishList(mark)
        return try node(.array, start, ls, lc)
    }

    func parseObjectLiteral() throws(JSSyntaxError) -> Int32 {
        let start = tok.start
        try advance() // {
        let mark = scratch.count
        var sawProto = false
        while tok.kind != .rbrace {
            if tok.kind == .ellipsis {
                let s = tok.start
                try advance()
                let a = try parseAssignment(noIn: false, coverOK: true)
                scratch.append(try node(.spread, s, a))
            } else {
                scratch.append(try parseObjectMember(&sawProto))
            }
            if tok.kind != .rbrace { try expect(.comma) }
        }
        try advance()
        let (ls, lc) = finishList(mark)
        return try node(.object, start, ls, lc)
    }

    /// The token after a get/set/async prefix makes it a modifier (not the key).
    func isModifierFollower(_ p: JSToken) -> Bool {
        switch p.kind {
        case .lparen, .colon, .comma, .rbrace, .assign, .eof: return false
        default: return true
        }
    }

    func parseObjectMember(_ sawProto: inout Bool) throws(JSSyntaxError) -> Int32 {
        let start = tok.start
        var async = false, generator = false
        var pkind = JSPropertyKind.initializer
        if isWord(JSWord.async_) {
            let p = try peek()
            if isModifierFollower(p) && !p.nl { try advance(); async = true }
        }
        if tok.kind == .star { try advance(); generator = true }
        if !async && !generator && (isWord(JSWord.get) || isWord(JSWord.set)) {
            let p = try peek()
            if isModifierFollower(p) {
                pkind = isWord(JSWord.get) ? .getter : .setter
                try advance()
            }
        }
        let keyTok = tok
        var flags: UInt16 = 0
        let key = try parsePropertyKey(allowPrivate: false, &flags)
        if tok.kind == .lparen {
            let fkind: JSFunctionKind = pkind == .getter ? .getter : pkind == .setter ? .setter : .method
            let f = try parseFunctionRest(tok.start, id: -1, kind: fkind, async: async, generator: generator, flags: 0)
            let op: JSPropertyKind = pkind == .initializer ? .method : pkind
            return try node(.property, start, op: op.rawValue, flags: flags, key, f)
        }
        if async || generator || pkind != .initializer { throw unexpected() }
        if tok.kind == .colon {
            try advance()
            let value = try parseAssignment(noIn: false, coverOK: true)
            if flags & JSNodeFlags.computed == 0 {
                let kn = ast.nodes[Int(key)]
                if (kn.kind == .identifierName || kn.kind == .string) && kn.a == JSWord.proto {
                    if sawProto { setCoverError(keyTok.start, "duplicate __proto__ property") }
                    sawProto = true
                }
            }
            return try node(.property, start, flags: flags, key, value)
        }
        // Shorthand.
        guard keyTok.kind == .name else { throw unexpected() }
        try checkIdentifier(keyTok, binding: false)
        let id = try node(.identifier, keyTok.start, keyTok.value)
        if tok.kind == .assign {
            try advance()
            let def = try parseAssignment(noIn: false)
            let ap = try node(.assignPattern, keyTok.start, id, def)
            setCoverError(keyTok.start, "invalid shorthand property initializer")
            return try node(.property, start, flags: flags | JSNodeFlags.shorthand | JSNodeFlags.coverInit, key, ap)
        }
        return try node(.property, start, flags: flags | JSNodeFlags.shorthand, key, id)
    }

    func parsePropertyKey(allowPrivate: Bool, _ flags: inout UInt16) throws(JSSyntaxError) -> Int32 {
        let start = tok.start
        let t = tok
        switch tok.kind {
        case .name:
            try advance()
            return try node(.identifierName, start, t.value)
        case .string:
            if fn.strict && t.flags & JSNodeFlags.octalEscape != 0 {
                throw error("octal escape sequences are not allowed in strict mode", start)
            }
            try advance()
            return try node(.string, start, flags: t.flags, t.value)
        case .number:
            if fn.strict && t.flags & (JSNodeFlags.legacyOctal | JSNodeFlags.nonOctalDecimal) != 0 {
                throw error("legacy octal literals are not allowed in strict mode", start)
            }
            try advance()
            return try node(.number, start, flags: t.flags, t.value)
        case .bigint:
            try advance()
            return try node(.bigint, start, t.value)
        case .lbracket:
            try advance()
            let e = try parseAssignment(noIn: false)
            try expect(.rbracket)
            flags |= JSNodeFlags.computed
            return e
        case .privateName where allowPrivate:
            try advance()
            flags |= JSNodeFlags.privateKey
            return try node(.privateName, start, t.value)
        default:
            throw unexpected()
        }
    }

    // ------------------------------------------------------------ patterns

    /// BindingIdentifier or BindingPattern (declarations, parameters, catch).
    func parseBindingTarget() throws(JSSyntaxError) -> Int32 {
        try enter()
        defer { leave() }
        switch tok.kind {
        case .lbracket: return try parseArrayBindingPattern()
        case .lbrace: return try parseObjectBindingPattern()
        case .name: return try parseBindingIdentifier()
        default: throw unexpected()
        }
    }

    func parseBindingElement() throws(JSSyntaxError) -> Int32 {
        let start = tok.start
        let t = try parseBindingTarget()
        if tok.kind == .assign {
            try advance()
            let d = try parseAssignment(noIn: false)
            return try node(.assignPattern, start, t, d)
        }
        return t
    }

    func parseArrayBindingPattern() throws(JSSyntaxError) -> Int32 {
        let start = tok.start
        try advance() // [
        let mark = scratch.count
        while tok.kind != .rbracket {
            if tok.kind == .comma {
                let s = tok.start
                try advance()
                scratch.append(try node(.hole, s))
                continue
            }
            if tok.kind == .ellipsis {
                let s = tok.start
                try advance()
                let t = try parseBindingTarget()
                scratch.append(try node(.rest, s, t))
                if tok.kind != .rbracket { throw error("rest element must be last", tok.start) }
                break
            }
            scratch.append(try parseBindingElement())
            if tok.kind != .rbracket { try expect(.comma) }
        }
        try expect(.rbracket)
        let (ls, lc) = finishList(mark)
        return try node(.arrayPattern, start, ls, lc)
    }

    func parseObjectBindingPattern() throws(JSSyntaxError) -> Int32 {
        let start = tok.start
        try advance() // {
        let mark = scratch.count
        while tok.kind != .rbrace {
            let s = tok.start
            if tok.kind == .ellipsis {
                try advance()
                let id = try parseBindingIdentifier()
                scratch.append(try node(.rest, s, id))
                if tok.kind != .rbrace { throw error("rest element must be last", tok.start) }
                break
            }
            let keyTok = tok
            var flags: UInt16 = 0
            let key = try parsePropertyKey(allowPrivate: false, &flags)
            if tok.kind == .colon {
                try advance()
                let v = try parseBindingElement()
                scratch.append(try node(.property, s, flags: flags, key, v))
            } else {
                guard keyTok.kind == .name && flags & JSNodeFlags.computed == 0 else { throw unexpected() }
                try checkIdentifier(keyTok, binding: true)
                bound.append((keyTok.value, keyTok.start))
                var v = try node(.identifier, keyTok.start, keyTok.value)
                if tok.kind == .assign {
                    try advance()
                    let d = try parseAssignment(noIn: false)
                    v = try node(.assignPattern, keyTok.start, v, d)
                }
                scratch.append(try node(.property, s, flags: flags | JSNodeFlags.shorthand, key, v))
            }
            if tok.kind != .rbrace { try expect(.comma) }
        }
        try advance()
        let (ls, lc) = finishList(mark)
        return try node(.objectPattern, start, ls, lc)
    }

    /// Target of `=`, `+=`, `++`: an identifier or a member expression.
    func checkSimpleTarget(_ n: Int32) throws(JSSyntaxError) {
        let nd = ast.nodes[Int(n)]
        switch nd.kind {
        case .identifier:
            if fn.strict && (nd.a == JSWord.eval || nd.a == JSWord.arguments) {
                throw error("cannot assign to '\(ast.text(nd.a))' in strict mode", Int(nd.start))
            }
        case .member, .index, .privateMember:
            break
        default:
            throw error("invalid assignment target", Int(nd.start))
        }
    }

    /// Convert an expression to an assignment target in place
    /// (destructuring assignment and for-in/of heads).
    func toAssignTarget(_ n: Int32, allowPattern: Bool) throws(JSSyntaxError) {
        try enter()
        defer { leave() }
        let nd = ast.nodes[Int(n)]
        let paren = nd.flags & JSNodeFlags.parenthesized != 0
        switch nd.kind {
        case .identifier, .member, .index, .privateMember:
            try checkSimpleTarget(n)
        case .array where !paren && allowPattern:
            ast.nodes[Int(n)].kind = .arrayPattern
            let elems = Array(ast.list(nd.a, nd.b))
            for (i, e) in elems.enumerated() {
                let en = ast.nodes[Int(e)]
                switch en.kind {
                case .hole: break
                case .spread:
                    if i != elems.count - 1 || en.flags & JSNodeFlags.spreadNotLast != 0 {
                        throw error("rest element must be last", Int(en.start))
                    }
                    if k(en.a) == .assign && !isParen(en.a) { throw error("rest element may not have a default", Int(en.start)) }
                    ast.nodes[Int(e)].kind = .rest
                    try toAssignTarget(en.a, allowPattern: true)
                default:
                    try toAssignElement(e)
                }
            }
        case .object where !paren && allowPattern:
            ast.nodes[Int(n)].kind = .objectPattern
            let props = Array(ast.list(nd.a, nd.b))
            for (i, p) in props.enumerated() {
                let pn = ast.nodes[Int(p)]
                if pn.kind == .spread {
                    if i != props.count - 1 { throw error("rest element must be last", Int(pn.start)) }
                    let ak = k(pn.a)
                    if ak != .identifier && ak != .member && ak != .index && ak != .privateMember {
                        throw error("invalid rest element", Int(pn.start))
                    }
                    ast.nodes[Int(p)].kind = .rest
                    try checkSimpleTarget(pn.a)
                    continue
                }
                if pn.op != JSPropertyKind.initializer.rawValue {
                    throw error("invalid destructuring target", Int(pn.start))
                }
                ast.nodes[Int(p)].flags &= ~JSNodeFlags.coverInit
                if pn.flags & JSNodeFlags.shorthand != 0 {
                    let v = ast.nodes[Int(pn.b)]
                    if v.kind == .assignPattern { try checkSimpleTarget(v.a) } else { try checkSimpleTarget(pn.b) }
                } else {
                    try toAssignElement(pn.b)
                }
            }
        default:
            throw error("invalid assignment target", Int(nd.start))
        }
    }

    /// An element of an array/object assignment pattern: a target or a
    /// target with a default (`a = 1` becomes an assignPattern).
    func toAssignElement(_ e: Int32) throws(JSSyntaxError) {
        let en = ast.nodes[Int(e)]
        if en.kind == .assign && en.flags & JSNodeFlags.parenthesized == 0 {
            if en.op != JSAssignOp.assign.rawValue { throw error("invalid destructuring target", Int(en.start)) }
            ast.nodes[Int(e)].kind = .assignPattern
            ast.nodes[Int(e)].op = 0
            // The target was already checked when the assignment was parsed.
            return
        }
        try toAssignTarget(e, allowPattern: true)
    }

    /// Convert a cover element to a binding target for arrow parameters.
    /// `last`: it may be a rest element.
    func toBindingTarget(_ n: Int32, last: Bool = false, top: Bool = true) throws(JSSyntaxError) {
        try enter()
        defer { leave() }
        let nd = ast.nodes[Int(n)]
        if nd.flags & JSNodeFlags.parenthesized != 0 { throw error("invalid parameter", Int(nd.start)) }
        switch nd.kind {
        case .identifier:
            break
        case .assign:
            if nd.op != JSAssignOp.assign.rawValue { throw error("invalid parameter", Int(nd.start)) }
            ast.nodes[Int(n)].kind = .assignPattern
            try toBindingTarget(nd.a, top: false)
        case .assignPattern:
            try toBindingTarget(nd.a, top: false)
        case .rest:
            if top && !last { throw error("rest parameter must be last", Int(nd.start)) }
            try toBindingTarget(nd.a, top: false)
        case .spread:
            if !last || nd.flags & JSNodeFlags.spreadNotLast != 0 { throw error("rest element must be last", Int(nd.start)) }
            ast.nodes[Int(n)].kind = .rest
            if k(nd.a) == .assign || k(nd.a) == .assignPattern { throw error("rest element may not have a default", Int(nd.start)) }
            try toBindingTarget(nd.a, top: false)
        case .array, .arrayPattern:
            ast.nodes[Int(n)].kind = .arrayPattern
            let elems = Array(ast.list(nd.a, nd.b))
            for (i, e) in elems.enumerated() where k(e) != .hole {
                try toBindingTarget(e, last: i == elems.count - 1, top: false)
            }
        case .object, .objectPattern:
            ast.nodes[Int(n)].kind = .objectPattern
            let props = Array(ast.list(nd.a, nd.b))
            for (i, p) in props.enumerated() {
                let pn = ast.nodes[Int(p)]
                if pn.kind == .spread || pn.kind == .rest {
                    if i != props.count - 1 { throw error("rest element must be last", Int(pn.start)) }
                    if k(pn.a) != .identifier || isParen(pn.a) { throw error("invalid rest element", Int(pn.start)) }
                    ast.nodes[Int(p)].kind = .rest
                    continue
                }
                if pn.op != JSPropertyKind.initializer.rawValue { throw error("invalid parameter", Int(pn.start)) }
                ast.nodes[Int(p)].flags &= ~JSNodeFlags.coverInit
                try toBindingTarget(pn.b, top: false)
            }
        default:
            throw error("invalid parameter", Int(nd.start))
        }
    }
}
