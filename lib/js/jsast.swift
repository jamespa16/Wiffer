// lib/js AST: the parser's output and the contract for the compiler (9B).
//
// ---------------------------------------------------------------- overview
//
//     let ast = try jsParse(source, options)      // throws(JSSyntaxError)
//     let root = ast.root                          // a .script or .module node
//
// The tree is a flat array of `JSNode` values (`ast.nodes`), addressed by
// Int32 index. There is no class per node and no Swift reference inside a
// node. Each node has:
//
//     kind    JSNodeKind (one byte)
//     op      a per-kind sub-kind: operator, var kind, function kind, ...
//     flags   JSNodeFlags bits (per kind, plus `parenthesized` on any node)
//     start   byte offset of the node's first character in the source
//     end     byte offset just past its last character
//     a b c d four Int32 fields; their meaning per kind is the table below
//
// Field codes in the table:
//     N   a node index                N?  a node index, or -1 for "absent"
//     S   a string id (ast.str(id))   S?  a string id, or -1
//     #   an index into ast.numbers (Double)
//     L   a list: this field is the start in ast.lists, the next field is
//         its count; ast.list(start, count) gives the node indices.
//
// **Children always have smaller indices than their parent** (nodes are
// appended bottom-up; cover-grammar conversions rewrite a node in place),
// so a single forward pass over `nodes` visits every child before its
// parent. `ast.children(n)` returns a node's child nodes in source order.
//
// Strings. Identifier names, property names, string literal values,
// template cooked/raw text, regex pattern/flags, module specifiers and
// BigInt digits are interned in one pool (`JSStringPool`) as UTF-16 code
// units, escapes already decoded (lone surrogates are kept as-is), so two
// equal strings always have the same id and comparing names is comparing
// ids. Nothing here touches the JS heap: 9B turns pool ids into heap atoms
// when it compiles. The pool starts with the words in `JSWord` at fixed
// ids (JSWord.let_, JSWord.constructor, ...), so the compiler can compare
// against them without looking anything up.
//
// Numbers. A .number node's `a` indexes `ast.numbers`: the literal's
// correctly rounded value (simple literals on a fast path, the rest through
// jsStringToNumber / jsDigitsToDouble in jsnumber.swift). `ast.numericText`
// gives the literal's text with `_` separators removed. BigInt literals keep their text (prefix included, separators and the
// trailing `n` removed) as a string id.
//
// Positions. `start`/`end` are UTF-8 byte offsets into `ast.source`.
// `JSLineMap(ast.source).location(offset)` gives a 1-based line and column
// (in code points) for error messages and stack traces.
//
// Scopes. The parser does not build scope objects: 9B's scope analysis
// walks the tree. What the parser does record:
//   * the early errors (duplicate lexical names, let/var conflicts,
//     labels, yield/await contexts, strict-mode rules, private names...)
//     are already checked, so a returned AST is a valid program;
//   * on each .function node: `strict`, `simpleParams`, `usesArguments`
//     (the body or a nested arrow mentions `arguments`), `usesThis`
//     (`this`, `super` or `new.target` in the body or a nested arrow),
//     `hasDirectEval` (the body or anything nested calls `eval(...)`), so
//     the compiler can tell which functions need dynamic environments;
//   * .script/.module flags `strict` and `hasDirectEval` likewise.
//
// Depth. Recursive productions nest at most `JSLimits.maxASTDepth`
// levels, and after parsing the whole tree's height is checked against
// `JSLimits.maxASTHeight` (default 2000): deeper input is a SyntaxError
// ("nesting too deep"), never a stack overflow. A compiler that recurses
// once per tree level therefore recurses at most maxHeight deep.
//
// ---------------------------------------------------------- node layouts
//
//  kind            op               a          b          c          d
//  ---- programs
//  script          -                L stmts    (count)
//  module          -                L items    (count)
//  ---- statements
//  empty
//  exprStmt        -                N expr                    flag directive
//  block           -                L stmts    (count)
//  varDecl         JSVarKind        L decls    (count)
//  declarator      -                N target   N? init
//  ifStmt          -                N test     N cons     N? alt
//  forStmt         -                N? init    N? test    N? update  N body
//  forIn           -                N left     N right    N body
//  forOf           -                N left     N right    N body  flag await
//        (left: a varDecl with one declarator and no init, except Annex B
//         `for (var x = 1 in o)`; or an assignment target / pattern)
//  whileStmt       -                N test     N body
//  doWhile         -                N body     N test
//  continueStmt    -                S? label
//  breakStmt       -                S? label
//  returnStmt      -                N? arg
//  withStmt        -                N object   N body
//  switchStmt      -                N disc     L cases    (count)
//  switchCase      -                N? test    L stmts    (count)   (-1 = default)
//  labeled         -                S label    N body
//  throwStmt       -                N arg
//  tryStmt         -                N block    N? param   N? handler N? finalizer
//        (handler is -1 when there is no catch; param is -1 for `catch {`)
//  debugger
//  ---- functions and classes
//  function        JSFunctionKind   N? id      L params   (count)    N body
//        body: a .functionBody, or the expression of a concise arrow
//        (flag exprBody). params: binding targets (identifier/patterns),
//        .assignPattern for defaults, .rest for the last one.
//  functionBody    -                L stmts    (count)
//  classNode       -                N? id      N? super   L members  (count)
//  property        JSPropertyKind   N key      N? value
//        object literals, object patterns and class members. key: an
//        .identifierName, .string, .number, .bigint or .privateName node,
//        or any expression with flag computed. value: the expression; a
//        .function for methods/getters/setters; the initializer (or -1) of
//        a class field; the target pattern in an object pattern (with an
//        .assignPattern for `{a = 1}` shorthands).
//  staticBlock     -                L stmts    (count)
//  ---- expressions
//  identifier      -                S name
//  identifierName  -                S name          (a non-computed property key)
//  privateName     -                S name (no #)   (a class key, or the lhs of `#x in o`)
//  this, superExpr, nullLit, trueLit, falseLit, newTarget, importMeta, hole
//  number          -                # value                   (flags legacyOctal...)
//  bigint          -                S text
//  string          -                S value
//  regexp          -                S pattern  S flags
//  template        -                L parts    (count)
//        parts alternate: templateElement, expr, templateElement, ...
//  templateElement -                S? cooked  S raw          (cooked -1: bad escape in a tagged template)
//  taggedTemplate  -                N tag      N template
//  array           -                L elems    (count)        (hole, spread or expr)
//  object          -                L props    (count)        (property or spread)
//  spread          -                N arg
//  unary           JSUnaryOp        N arg
//  update          JSUpdateOp       N arg                     flag prefix
//  binary          JSBinaryOp       N left     N right        (&&, ||, ?? too)
//  assign          JSAssignOp       N target   N value
//  conditional     -                N test     N then     N else
//  call            -                N callee   L args     (count)  flag optional
//  newExpr         -                N callee   L args     (count)
//  member          -                N object   S name              flag optional
//  index           -                N object   N key               flag optional
//  privateMember   -                N object   S name              flag optional
//  optionalChain   -                N chain    (an a?.b... chain; short-circuits to here)
//  sequence        -                L exprs    (count)
//  yieldExpr       -                N? arg                    flag delegate
//  awaitExpr       -                N arg
//  importCall      -                N specifier
//  ---- patterns (destructuring targets, from declarations or converted
//       from array/object literals: the cover grammar)
//  arrayPattern    -                L elems    (count)        (hole, target, assignPattern, rest)
//  objectPattern   -                L props    (count)        (property op init, or rest)
//  assignPattern   -                N target   N default
//  rest            -                N target
//  ---- modules
//  importDecl      -                S from     L specs    (count)
//  importSpec      -                S imported N local         (`{ imported as local }`)
//  importDefault   -                N local
//  importNamespace -                N local
//  exportNamed     -                N? decl    L specs    (count)    S? from
//  exportSpec      -                S local    S exported      (local: the imported name with `from`)
//  exportDefault   -                N value                   flag expression (else a declaration)
//  exportAll       -                S from     S? exported     (`export * as x from`)

/// The kind of a node (see the layout table at the top of the file).
enum JSNodeKind: UInt8 {
    case script, module
    case empty, exprStmt, block, varDecl, declarator, ifStmt, forStmt, forIn, forOf
    case whileStmt, doWhile, continueStmt, breakStmt, returnStmt, withStmt
    case switchStmt, switchCase, labeled, throwStmt, tryStmt, debugger
    case function, functionBody, classNode, property, staticBlock
    case identifier, identifierName, privateName
    case this, superExpr, nullLit, trueLit, falseLit, newTarget, importMeta, hole
    case number, bigint, string, regexp, template, templateElement, taggedTemplate
    case array, object, spread, unary, update, binary, assign, conditional
    case call, newExpr, member, index, privateMember, optionalChain, sequence
    case yieldExpr, awaitExpr, importCall
    case arrayPattern, objectPattern, assignPattern, rest
    case importDecl, importSpec, importDefault, importNamespace
    case exportNamed, exportSpec, exportDefault, exportAll
}

enum JSVarKind: UInt8 { case `var`, `let`, `const` }

enum JSFunctionKind: UInt8 {
    case normal, arrow, method, getter, setter, classConstructor, derivedConstructor
}

enum JSPropertyKind: UInt8 {
    /// `key: value` (or a shorthand, or a pattern property)
    case initializer
    case method, getter, setter
    /// a class field: value is the initializer or -1
    case field
}

enum JSUnaryOp: UInt8 { case minus, plus, not, bitNot, typeof, void, delete }

enum JSUpdateOp: UInt8 { case increment, decrement }

enum JSBinaryOp: UInt8 {
    case add, sub, mul, div, mod, exp, shl, sar, shr
    case lt, gt, le, ge, eq, ne, strictEq, strictNe
    case bitAnd, bitOr, bitXor, `in`, instanceof
    case logicalAnd, logicalOr, nullish
}

enum JSAssignOp: UInt8 {
    case assign, add, sub, mul, div, mod, exp, shl, sar, shr
    case bitAnd, bitOr, bitXor, logicalAnd, logicalOr, nullish
}

/// Flag bits in JSNode.flags. The meaning depends on the kind; values for
/// different kinds overlap.
enum JSNodeFlags {
    /// Any expression written in parentheses.
    static let parenthesized: UInt16 = 0x8000

    // .function
    static let async: UInt16 = 0x0001
    static let generator: UInt16 = 0x0002
    static let declaration: UInt16 = 0x0004      // also .classNode
    static let strict: UInt16 = 0x0008           // also .script/.module
    static let exprBody: UInt16 = 0x0010
    static let simpleParams: UInt16 = 0x0020
    static let usesArguments: UInt16 = 0x0040
    static let usesThis: UInt16 = 0x0080
    static let hasDirectEval: UInt16 = 0x0100    // also .script/.module
    static let hasUseStrict: UInt16 = 0x0200     // the body has its own "use strict"
    static let expression: UInt16 = 0x0400       // a function/class expression (and .exportDefault: an expression)

    // .property
    static let computed: UInt16 = 0x0001
    static let shorthand: UInt16 = 0x0002
    static let isStatic: UInt16 = 0x0004
    static let coverInit: UInt16 = 0x0008        // `{a = 1}`: only valid once converted to a pattern
    static let privateKey: UInt16 = 0x0010

    // .call .member .index .privateMember: this link is `?.`
    static let optional: UInt16 = 0x0001
    // .update
    static let prefix: UInt16 = 0x0001
    // .yieldExpr
    static let delegate: UInt16 = 0x0001
    // .forOf
    static let await: UInt16 = 0x0001
    // .exprStmt: part of a directive prologue
    static let directive: UInt16 = 0x0001
    // .array: a spread is followed by a comma, so it can't become a rest
    static let spreadNotLast: UInt16 = 0x0001

    // .number
    static let legacyOctal: UInt16 = 0x0002      // 017 (a strict-mode error, checked)
    static let nonOctalDecimal: UInt16 = 0x0004  // 08, 09
    // .string
    static let octalEscape: UInt16 = 0x0002      // "\01", "\8" (a strict-mode error, checked)
}

struct JSNode {
    var kind: JSNodeKind
    var op: UInt8
    var flags: UInt16
    var start: UInt32
    var end: UInt32
    var a: Int32
    var b: Int32
    var c: Int32
    var d: Int32
}

/// Field layout codes (see the table at the top).
enum JSField: UInt8 { case none, node, optNode, str, optStr, num, list, count }

/// The field codes of a, b, c, d for one kind.
func jsNodeLayout(_ k: JSNodeKind) -> (JSField, JSField, JSField, JSField) {
    switch k {
    case .script, .module, .block, .varDecl, .functionBody, .staticBlock, .template,
         .array, .object, .sequence, .arrayPattern, .objectPattern:
        return (.list, .count, .none, .none)
    case .exprStmt, .throwStmt, .spread, .unary, .update, .awaitExpr, .importCall,
         .optionalChain, .rest, .importDefault, .importNamespace, .exportDefault:
        return (.node, .none, .none, .none)
    case .returnStmt, .yieldExpr: return (.optNode, .none, .none, .none)
    case .declarator: return (.node, .optNode, .none, .none)
    case .ifStmt: return (.node, .node, .optNode, .none)
    case .forStmt: return (.optNode, .optNode, .optNode, .node)
    case .forIn, .forOf, .conditional: return (.node, .node, .node, .none)
    case .whileStmt, .doWhile, .withStmt, .binary, .assign, .taggedTemplate, .index,
         .assignPattern:
        return (.node, .node, .none, .none)
    case .continueStmt, .breakStmt: return (.optStr, .none, .none, .none)
    case .switchStmt, .call, .newExpr: return (.node, .list, .count, .none)
    case .switchCase: return (.optNode, .list, .count, .none)
    case .labeled: return (.str, .node, .none, .none)
    case .tryStmt: return (.node, .optNode, .optNode, .optNode)
    case .function: return (.optNode, .list, .count, .node)
    case .classNode: return (.optNode, .optNode, .list, .count)
    case .property: return (.node, .optNode, .none, .none)
    case .identifier, .identifierName, .privateName, .bigint, .string:
        return (.str, .none, .none, .none)
    case .number: return (.num, .none, .none, .none)
    case .regexp: return (.str, .str, .none, .none)
    case .templateElement: return (.optStr, .str, .none, .none)
    case .member, .privateMember: return (.node, .str, .none, .none)
    case .importDecl: return (.str, .list, .count, .none)
    case .importSpec: return (.str, .node, .none, .none)
    case .exportNamed: return (.optNode, .list, .count, .optStr)
    case .exportSpec: return (.str, .str, .none, .none)
    case .exportAll: return (.str, .optStr, .none, .none)
    case .empty, .debugger, .this, .superExpr, .nullLit, .trueLit, .falseLit,
         .newTarget, .importMeta, .hole:
        return (.none, .none, .none, .none)
    }
}

/// Words interned first, at fixed ids, in this order (JSWord's constants).
/// 0..<reservedCount are the always-reserved words, then the strict-mode
/// reserved words up to `yield`, then contextual words.
let jsWordList: [StaticString] = [
    "break", "case", "catch", "class", "const", "continue", "debugger", "default",
    "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for",
    "function", "if", "import", "in", "instanceof", "new", "null", "return", "super",
    "switch", "this", "throw", "true", "try", "typeof", "var", "void", "while", "with",
    "implements", "interface", "let", "package", "private", "protected", "public",
    "static", "yield",
    "await", "async", "get", "set", "of", "from", "as", "target", "meta", "eval",
    "arguments", "constructor", "prototype", "__proto__", "use strict",
]

/// Fixed string ids of the words in jsWordList.
enum JSWord {
    static let break_: Int32 = 0, case_: Int32 = 1, catch_: Int32 = 2, class_: Int32 = 3
    static let const_: Int32 = 4, continue_: Int32 = 5, debugger_: Int32 = 6, default_: Int32 = 7
    static let delete_: Int32 = 8, do_: Int32 = 9, else_: Int32 = 10, enum_: Int32 = 11
    static let export_: Int32 = 12, extends_: Int32 = 13, false_: Int32 = 14, finally_: Int32 = 15
    static let for_: Int32 = 16, function_: Int32 = 17, if_: Int32 = 18, import_: Int32 = 19
    static let in_: Int32 = 20, instanceof_: Int32 = 21, new_: Int32 = 22, null_: Int32 = 23
    static let return_: Int32 = 24, super_: Int32 = 25, switch_: Int32 = 26, this_: Int32 = 27
    static let throw_: Int32 = 28, true_: Int32 = 29, try_: Int32 = 30, typeof_: Int32 = 31
    static let var_: Int32 = 32, void_: Int32 = 33, while_: Int32 = 34, with_: Int32 = 35
    static let implements_: Int32 = 36, interface_: Int32 = 37, let_: Int32 = 38
    static let package_: Int32 = 39, private_: Int32 = 40, protected_: Int32 = 41
    static let public_: Int32 = 42, static_: Int32 = 43, yield_: Int32 = 44
    static let await_: Int32 = 45, async_: Int32 = 46, get: Int32 = 47, set: Int32 = 48
    static let of: Int32 = 49, from: Int32 = 50, as_: Int32 = 51, target: Int32 = 52
    static let meta: Int32 = 53, eval: Int32 = 54, arguments: Int32 = 55
    static let constructor: Int32 = 56, prototype: Int32 = 57, proto: Int32 = 58
    static let useStrict: Int32 = 59

    /// Words that can never be identifiers (`break` ... `with`).
    static let reservedCount: Int32 = 36
    /// Reserved in strict mode too (`implements` ... `yield`).
    static func isStrictReserved(_ id: Int32) -> Bool { id >= 36 && id <= 44 }
}

/// Interned UTF-16 strings (see "Strings" at the top). Id equality is
/// string equality.
struct JSStringPool {
    private(set) var units: [UInt16] = []
    /// starts[i] ..< starts[i + 1] is string i's slice of units.
    private(set) var starts: [UInt32] = [0]
    private var hashes: [UInt32] = []
    private var table: [Int32] = [Int32](repeating: 0, count: 256)  // id + 1, 0 = empty

    init() {
        var tmp: [UInt16] = []
        for w in jsWordList {
            tmp.removeAll(keepingCapacity: true)
            let p = w.utf8Start
            for i in 0..<w.utf8CodeUnitCount { tmp.append(UInt16(p[i])) }
            _ = intern(tmp[...])
        }
    }

    var count: Int { starts.count - 1 }

    func string(_ id: Int32) -> ArraySlice<UInt16> {
        let i = Int(id)
        guard i >= 0 && i < count else { return [] }
        return units[Int(starts[i])..<Int(starts[i + 1])]
    }

    func length(_ id: Int32) -> Int {
        let i = Int(id)
        guard i >= 0 && i < count else { return 0 }
        return Int(starts[i + 1] &- starts[i])
    }

    @inline(__always) static func mix(_ h: UInt32, _ u: UInt16) -> UInt32 {
        (h ^ UInt32(u)) &* 16777619
    }

    /// Intern a slice of UTF-16 units.
    mutating func intern(_ s: ArraySlice<UInt16>) -> Int32 {
        var h: UInt32 = 2166136261
        for u in s { h = JSStringPool.mix(h, u) }
        let mask = table.count - 1
        var slot = Int(h) & mask
        while true {
            let e = table[slot]
            if e == 0 { break }
            let id = Int(e - 1)
            if hashes[id] == h {
                let a = Int(starts[id]), b = Int(starts[id + 1])
                if b - a == s.count {
                    var same = true
                    var j = a
                    for u in s { if units[j] != u { same = false; break }; j += 1 }
                    if same { return Int32(id) }
                }
            }
            slot = (slot + 1) & mask
        }
        let id = count
        units.append(contentsOf: s)
        starts.append(UInt32(truncatingIfNeeded: units.count))
        hashes.append(h)
        table[slot] = Int32(id + 1)
        if count * 2 > table.count { grow() }
        return Int32(id)
    }

    /// Intern ASCII bytes p[from..<to] (the lexer's identifier fast path).
    mutating func internASCII(_ p: UnsafePointer<UInt8>, _ from: Int, _ to: Int) -> Int32 {
        var h: UInt32 = 2166136261
        var i = from
        while i < to { h = JSStringPool.mix(h, UInt16(p[i])); i += 1 }
        let mask = table.count - 1
        var slot = Int(h) & mask
        let n = to - from
        while true {
            let e = table[slot]
            if e == 0 { break }
            let id = Int(e - 1)
            if hashes[id] == h {
                let a = Int(starts[id])
                if Int(starts[id + 1]) - a == n {
                    var k = 0
                    while k < n && units[a + k] == UInt16(p[from + k]) { k += 1 }
                    if k == n { return Int32(id) }
                }
            }
            slot = (slot + 1) & mask
        }
        let id = count
        i = from
        while i < to { units.append(UInt16(p[i])); i += 1 }
        starts.append(UInt32(truncatingIfNeeded: units.count))
        hashes.append(h)
        table[slot] = Int32(id + 1)
        if count * 2 > table.count { grow() }
        return Int32(id)
    }

    private mutating func grow() {
        let size = table.count * 2
        var t = [Int32](repeating: 0, count: size)
        let mask = size - 1
        for id in 0..<count {
            var slot = Int(hashes[id]) & mask
            while t[slot] != 0 { slot = (slot + 1) & mask }
            t[slot] = Int32(id + 1)
        }
        table = t
    }

    /// True if string `id` is exactly the ASCII text `s`.
    func equals(_ id: Int32, _ s: StaticString) -> Bool {
        let str = string(id)
        guard str.count == s.utf8CodeUnitCount else { return false }
        let p = s.utf8Start
        var i = 0
        for u in str { if u != UInt16(p[i]) { return false }; i += 1 }
        return true
    }

    /// The string as Swift text (lone surrogates become U+FFFD).
    func text(_ id: Int32) -> String { jsUTF16ToString(string(id)) }
}

/// UTF-16 to a Swift String (lone surrogates become U+FFFD).
func jsUTF16ToString(_ s: ArraySlice<UInt16>) -> String {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(s.count)
    var i = s.startIndex
    while i < s.endIndex {
        var cp = UInt32(s[i])
        i += 1
        if cp >= 0xD800 && cp < 0xDC00, i < s.endIndex, s[i] >= 0xDC00 && s[i] < 0xE000 {
            cp = 0x10000 + ((cp - 0xD800) << 10) + (UInt32(s[i]) - 0xDC00)
            i += 1
        } else if cp >= 0xD800 && cp < 0xE000 {
            cp = 0xFFFD
        }
        jsAppendUTF8(&bytes, cp)
    }
    return String(decoding: bytes, as: UTF8.self)
}

/// A syntax error: a message and the byte offset it refers to.
struct JSSyntaxError: Error {
    var message: String
    var offset: Int
    /// 1-based line and column (code points) of `offset`.
    var line: Int
    var column: Int
}

/// Byte offset to line and column.
struct JSLineMap {
    /// Byte offsets where each line starts.
    private(set) var lineStarts: [Int] = [0]
    private let source: [UInt8]

    init(_ source: [UInt8]) {
        self.source = source
        var i = 0
        let n = source.count
        while i < n {
            let c = source[i]
            if c == 0x0A {
                lineStarts.append(i + 1)
            } else if c == 0x0D {
                if i + 1 < n && source[i + 1] == 0x0A { i += 1 }
                lineStarts.append(i + 1)
            } else if c == 0xE2 && i + 2 < n && source[i + 1] == 0x80
                        && (source[i + 2] == 0xA8 || source[i + 2] == 0xA9) {
                i += 2
                lineStarts.append(i + 1)
            }
            i += 1
        }
    }

    /// 1-based (line, column); the column counts code points.
    func location(_ offset: Int) -> (line: Int, column: Int) {
        let off = max(0, min(offset, source.count))
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) >> 1
            if lineStarts[mid] <= off { lo = mid } else { hi = mid - 1 }
        }
        var col = 1
        var i = lineStarts[lo]
        while i < off {
            if source[i] & 0xC0 != 0x80 { col += 1 }
            i += 1
        }
        return (lo + 1, col)
    }
}

/// The parsed program.
final class JSAST {
    let source: [UInt8]
    var nodes: [JSNode] = []
    var lists: [Int32] = []
    var pool = JSStringPool()
    var numbers: [Double] = []
    /// The .script or .module node.
    var root: Int32 = -1
    var isModule = false

    init(source: [UInt8]) { self.source = source }

    @inline(__always) subscript(_ n: Int32) -> JSNode { nodes[Int(n)] }

    func kind(_ n: Int32) -> JSNodeKind { nodes[Int(n)].kind }

    /// A list's node indices.
    func list(_ start: Int32, _ count: Int32) -> ArraySlice<Int32> {
        lists[Int(start)..<Int(start + count)]
    }

    func str(_ id: Int32) -> ArraySlice<UInt16> { pool.string(id) }
    func text(_ id: Int32) -> String { pool.text(id) }

    /// The literal's source text with `_` separators removed (for .number
    /// nodes and BigInt).
    func numericText(_ n: Int32) -> [UInt8] {
        let node = nodes[Int(n)]
        var out: [UInt8] = []
        var i = Int(node.start)
        while i < Int(node.end) && i < source.count {
            if source[i] != 0x5F && source[i] != 0x6E { out.append(source[i]) }
            i += 1
        }
        return out
    }

    /// Child nodes of n in source order.
    func children(_ n: Int32) -> [Int32] {
        var out: [Int32] = []
        forEachChild(n) { out.append($0) }
        return out
    }

    func forEachChild(_ n: Int32, _ body: (Int32) -> Void) {
        let node = nodes[Int(n)]
        let lay = jsNodeLayout(node.kind)
        visitField(lay.0, node.a, node.b, body)
        visitField(lay.1, node.b, node.c, body)
        visitField(lay.2, node.c, node.d, body)
        visitField(lay.3, node.d, 0, body)
    }

    @inline(__always)
    private func visitField(_ code: JSField, _ v: Int32, _ next: Int32, _ body: (Int32) -> Void) {
        switch code {
        case .node: body(v)
        case .optNode: if v >= 0 { body(v) }
        case .list:
            var i = Int(v)
            let e = i + Int(next)
            while i < e && i < lists.count { body(lists[i]); i += 1 }
        default: break
        }
    }

    /// The tree's height (1 for a leaf), in one pass over the node array
    /// (children come before parents).
    func height() -> Int {
        var h = [UInt16](repeating: 1, count: nodes.count)
        var best = 0
        for i in 0..<nodes.count {
            var m: UInt16 = 0
            forEachChild(Int32(i)) { c in
                let ci = Int(c)
                if ci < i && h[ci] > m { m = h[ci] }
            }
            h[i] = m == UInt16.max ? m : m + 1
            if Int(h[i]) > best { best = Int(h[i]) }
        }
        return best
    }

    // ------------------------------------------------------------ dumping

    /// An S-expression for tests: `(kind op payload children...)`.
    func dump(_ n: Int32) -> String {
        var out = ""
        dump(n, into: &out, depth: 0)
        return out
    }

    private func dump(_ n: Int32, into out: inout String, depth: Int) {
        if n < 0 || Int(n) >= nodes.count { out += "-"; return }
        if depth > 200 { out += "..."; return }
        let node = nodes[Int(n)]
        out += "(" + jsNodeKindName(node.kind)
        if let op = jsNodeOpName(node) { out += " " + op }
        if node.flags & JSNodeFlags.parenthesized != 0 { out += " paren" }
        jsAppendFlagNames(node, &out)
        let lay = jsNodeLayout(node.kind)
        let codes = [lay.0, lay.1, lay.2, lay.3]
        let vals = [node.a, node.b, node.c, node.d]
        for i in 0..<4 {
            switch codes[i] {
            case .node: out += " "; dump(vals[i], into: &out, depth: depth + 1)
            case .optNode:
                out += " "
                if vals[i] < 0 { out += "-" } else { dump(vals[i], into: &out, depth: depth + 1) }
            case .str: out += " " + jsQuote(pool.text(vals[i]))
            case .optStr: out += " " + (vals[i] < 0 ? "-" : jsQuote(pool.text(vals[i])))
            case .num:
                let v = Int(vals[i]) < numbers.count && vals[i] >= 0 ? numbers[Int(vals[i])] : 0
                out += " " + jsFormatTestNumber(v)
            case .list:
                if i + 1 < 4 {
                    for c in list(vals[i], vals[i + 1]) { out += " "; dump(c, into: &out, depth: depth + 1) }
                }
            default: break
            }
        }
        out += ")"
    }
}

func jsQuote(_ s: String) -> String { "\"" + s + "\"" }

/// Number formatting for AST dumps only (integers exactly, else a short
/// approximation); the real Number-to-String is 9B's job.
func jsFormatTestNumber(_ v: Double) -> String {
    if v.isNaN { return "NaN" }
    if v.isInfinite { return v < 0 ? "-Infinity" : "Infinity" }
    if v == v.rounded() && abs(v) < 1e18 { return String(Int64(v)) }
    var x = abs(v)
    var e = 0
    while x >= 10 { x /= 10; e += 1 }
    while x < 1 { x *= 10; e -= 1 }
    var digits = ""
    for i in 0..<12 {
        let d = Int(x)
        digits += String(d)
        if i == 0 { digits += "." }
        x = (x - Double(d)) * 10
    }
    while digits.hasSuffix("0") { digits.removeLast() }
    if digits.hasSuffix(".") { digits.removeLast() }
    return (v < 0 ? "-" : "") + digits + "e" + String(e)
}

func jsNodeKindName(_ k: JSNodeKind) -> String {
    switch k {
    case .script: return "script"
    case .module: return "module"
    case .empty: return "empty"
    case .exprStmt: return "expr"
    case .block: return "block"
    case .varDecl: return "var"
    case .declarator: return "decl"
    case .ifStmt: return "if"
    case .forStmt: return "for"
    case .forIn: return "for-in"
    case .forOf: return "for-of"
    case .whileStmt: return "while"
    case .doWhile: return "do-while"
    case .continueStmt: return "continue"
    case .breakStmt: return "break"
    case .returnStmt: return "return"
    case .withStmt: return "with"
    case .switchStmt: return "switch"
    case .switchCase: return "case"
    case .labeled: return "label"
    case .throwStmt: return "throw"
    case .tryStmt: return "try"
    case .debugger: return "debugger"
    case .function: return "function"
    case .functionBody: return "body"
    case .classNode: return "class"
    case .property: return "prop"
    case .staticBlock: return "static-block"
    case .identifier: return "id"
    case .identifierName: return "name"
    case .privateName: return "private"
    case .this: return "this"
    case .superExpr: return "super"
    case .nullLit: return "null"
    case .trueLit: return "true"
    case .falseLit: return "false"
    case .newTarget: return "new.target"
    case .importMeta: return "import.meta"
    case .hole: return "hole"
    case .number: return "num"
    case .bigint: return "bigint"
    case .string: return "str"
    case .regexp: return "regexp"
    case .template: return "template"
    case .templateElement: return "quasi"
    case .taggedTemplate: return "tagged"
    case .array: return "array"
    case .object: return "object"
    case .spread: return "spread"
    case .unary: return "unary"
    case .update: return "update"
    case .binary: return "binary"
    case .assign: return "assign"
    case .conditional: return "cond"
    case .call: return "call"
    case .newExpr: return "new"
    case .member: return "member"
    case .index: return "index"
    case .privateMember: return "private-member"
    case .optionalChain: return "chain"
    case .sequence: return "seq"
    case .yieldExpr: return "yield"
    case .awaitExpr: return "await"
    case .importCall: return "import()"
    case .arrayPattern: return "array-pattern"
    case .objectPattern: return "object-pattern"
    case .assignPattern: return "assign-pattern"
    case .rest: return "rest"
    case .importDecl: return "import"
    case .importSpec: return "import-spec"
    case .importDefault: return "import-default"
    case .importNamespace: return "import-ns"
    case .exportNamed: return "export"
    case .exportSpec: return "export-spec"
    case .exportDefault: return "export-default"
    case .exportAll: return "export-all"
    }
}

let jsBinaryOpNames: [String] = ["+", "-", "*", "/", "%", "**", "<<", ">>", ">>>",
    "<", ">", "<=", ">=", "==", "!=", "===", "!==", "&", "|", "^", "in", "instanceof",
    "&&", "||", "??"]
let jsAssignOpNames: [String] = ["=", "+=", "-=", "*=", "/=", "%=", "**=", "<<=", ">>=",
    ">>>=", "&=", "|=", "^=", "&&=", "||=", "??="]
let jsUnaryOpNames: [String] = ["-", "+", "!", "~", "typeof", "void", "delete"]

func jsNodeOpName(_ node: JSNode) -> String? {
    let op = Int(node.op)
    switch node.kind {
    case .binary: return op < jsBinaryOpNames.count ? jsBinaryOpNames[op] : "?"
    case .assign: return op < jsAssignOpNames.count ? jsAssignOpNames[op] : "?"
    case .unary: return op < jsUnaryOpNames.count ? jsUnaryOpNames[op] : "?"
    case .update: return op == 0 ? "++" : "--"
    case .varDecl: return op == 0 ? "var" : op == 1 ? "let" : "const"
    case .function:
        let names = ["", "arrow", "method", "get", "set", "ctor", "derived-ctor"]
        return op == 0 || op >= names.count ? nil : names[op]
    case .property:
        let names = ["", "method", "get", "set", "field"]
        return op == 0 || op >= names.count ? nil : names[op]
    default: return nil
    }
}

private func jsAppendFlagNames(_ node: JSNode, _ out: inout String) {
    let f = node.flags
    switch node.kind {
    case .function:
        if f & JSNodeFlags.async != 0 { out += " async" }
        if f & JSNodeFlags.generator != 0 { out += " *" }
        if f & JSNodeFlags.exprBody != 0 { out += " expr-body" }
    case .property:
        if f & JSNodeFlags.isStatic != 0 { out += " static" }
        if f & JSNodeFlags.computed != 0 { out += " computed" }
        if f & JSNodeFlags.shorthand != 0 { out += " shorthand" }
    case .call, .member, .index, .privateMember:
        if f & JSNodeFlags.optional != 0 { out += " ?." }
    case .update:
        if f & JSNodeFlags.prefix != 0 { out += " prefix" }
    case .yieldExpr:
        if f & JSNodeFlags.delegate != 0 { out += " *" }
    case .forOf:
        if f & JSNodeFlags.await != 0 { out += " await" }
    case .exprStmt:
        if f & JSNodeFlags.directive != 0 { out += " directive" }
    case .script, .module:
        if f & JSNodeFlags.strict != 0 { out += " strict" }
    default: break
    }
}
