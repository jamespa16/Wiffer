// Phase 9A host tests: lexer, parser, AST shape, early errors, limits,
// the fuzzer, then the corpus and test262 (jstest262_tests.swift).

func jsTestParse(_ src: String, module: Bool = false, strict: Bool = false) -> String {
    do {
        let ast = try jsParse(Array(src.utf8), JSParseOptions(module: module, strict: strict))
        return ast.dump(ast.root)
    } catch {
        return "error: \(error.message) @\(error.line):\(error.column)"
    }
}

func jsTestOK(_ src: String, module: Bool = false, strict: Bool = false) -> Bool {
    (try? jsParse(Array(src.utf8), JSParseOptions(module: module, strict: strict))) != nil
}

/// The dump of the first statement's expression: `(script (expr X))` -> X.
func jsTestExpr(_ src: String) -> String {
    let d = jsTestParse(src)
    var pre = "(script (expr "
    if d.hasPrefix(pre + "directive ") { pre += "directive " }
    guard d.hasPrefix(pre) && d.hasSuffix("))") else { return d }
    return String(d.dropFirst(pre.count).dropLast(2))
}

func jsParserTests(_ t: Tests) {
    jsLexerTests(t)
    jsASTShapeTests(t)
    jsValidSyntaxTests(t)
    jsEarlyErrorTests(t)
    jsLimitTests(t)
    jsParserFuzz(t)
    jsCorpusTests(t)
    jsTest262Tests(t)
}

// MARK: lexer

func jsLexerTests(_ t: Tests) {
    t.section("lexer")
    t.check(JSWord.reservedCount == 36, "reserved word count")
    let pool = JSStringPool()
    for (i, w) in jsWordList.enumerated() {
        t.check(pool.equals(Int32(i), w), "word \(i) interned at its fixed id")
    }
    t.check(pool.equals(JSWord.yield_, "yield") && pool.equals(JSWord.as_, "as")
            && pool.equals(JSWord.proto, "__proto__") && pool.equals(JSWord.useStrict, "use strict"),
            "JSWord constants")
    // Unicode identifiers.
    t.check(jsIsIDStart(0x00E9) && jsIsIDStart(0x4E00) && jsIsIDStart(0x1D400), "ID_Start")
    t.check(!jsIsIDStart(0x0301) && jsIsIDContinue(0x0301) && jsIsIDContinue(0x0660), "ID_Continue")
    t.check(!jsIsIDStart(0x2E2F) && !jsIsIDContinue(0x00D7), "not identifier")
    t.equal(jsTestExpr("caf\u{E9}"), "(id \"caf\u{E9}\")", "UTF-8 identifier")
    t.equal(jsTestExpr("\\u0061b\\u{63}"), "(id \"abc\")", "escaped identifier")
    t.equal(jsTestExpr("\u{1D400}x"), "(id \"\u{1D400}x\")", "astral identifier")
    t.check(!jsTestOK("\\u0030abc"), "escape must be ID_Start")
    t.check(!jsTestOK("var \\u0069f = 1"), "escaped keyword is not an identifier")
    t.check(!jsTestOK("\\u0069f (1) {}"), "escaped keyword is not a keyword")
    // Numbers.
    let nums: [(String, String)] = [
        ("0x1F", "31"), ("0o17", "15"), ("0b101", "5"), ("017", "15"), ("019", "19"), ("08.5", "8.5e0"),
        ("1_000_000", "1000000"), (".5", "5e-1"), ("5.", "5"), ("1e3", "1000"), ("1E-2", "1e-2"),
        ("0.1", "1e-1"), ("9007199254740993", "9007199254740992"),
        ("0x1fffffffffffff1", "144115188075855856"), ("1e400", "Infinity"), ("0", "0"),
    ]
    for (src, want) in nums { t.equal(jsTestExpr(src), "(num \(want))", "number \(src)") }
    if let ast = try? jsParse(Array("0.30000000000000004; 123456789012345678901234567890; 2.2250738585072014e-308".utf8)) {
        t.check(ast.numbers.count == 3 && ast.numbers[0] == 0.30000000000000004
                && ast.numbers[1] == 1.2345678901234568e29 && ast.numbers[2] == 2.2250738585072014e-308,
                "slow-path numbers are correctly rounded")
    } else { t.check(false, "slow-path numbers parse") }
    t.equal(jsTestExpr("0x1_Fn"), "(bigint \"0x1F\")", "bigint")
    for bad in ["1_", "1__0", "0_1", "0x", "0x_1", "1n.5", "1.5n", "017n", "08n", "3in x", "1e", "1e+", "0b2", "._1"] {
        t.check(!jsTestOK(bad), "bad number \(bad)")
    }
    t.check(jsTestOK("1..toString(); 1 .x; 1.0.x"), "member access on numbers")
    // Strings.
    t.equal(jsTestExpr("'a\\n\\x41\\u0042\\u{1F600}\\\n'"), "(str \"a\nAB\u{1F600}\")", "string escapes")
    t.equal(jsTestExpr("'\\101'"), "(str \"A\")", "legacy octal escape")
    t.check(!jsTestOK("'use strict'; '\\101'"), "octal escape in strict")
    t.check(!jsTestOK("'use strict'; '\\8'"), "\\8 in strict")
    t.check(jsTestOK("'\\0'") && jsTestOK("'use strict'; '\\0'"), "\\0 is fine")
    t.check(!jsTestOK("'abc"), "unterminated string")
    t.check(!jsTestOK("'a\nb'"), "newline in string")
    t.check(jsTestOK("'a\u{2028}b'"), "U+2028 in string (ES2019)")
    t.check(!jsTestOK("'\\x4'") && !jsTestOK("'\\u{110000}'") && !jsTestOK("'\\u12'"), "bad escapes")
    // Templates.
    t.equal(jsTestExpr("`a${1}b${x}c`"),
            "(template (quasi \"a\" \"a\") (num 1) (quasi \"b\" \"b\") (id \"x\") (quasi \"c\" \"c\"))", "template")
    t.equal(jsTestExpr("`\\n\r\n`"), "(template (quasi \"\n\n\" \"\\n\n\"))", "template cooked/raw, CRLF")
    t.equal(jsTestExpr("tag`\\unicode`"), "(tagged (id \"tag\") (template (quasi - \"\\unicode\")))", "bad escape in tagged template")
    t.check(!jsTestOK("`\\unicode`"), "bad escape in untagged template")
    t.check(!jsTestOK("`\\01`"), "octal escape in template")
    t.check(jsTestOK("`${ {a: `${`x`}`}.a }`"), "nested templates and braces")
    t.check(!jsTestOK("`abc"), "unterminated template")
    // Regex vs division.
    t.equal(jsTestExpr("/a[/]b/gi"), "(regexp \"a[/]b\" \"gi\")", "regex with class")
    t.equal(jsTestExpr("a / b / c"), "(binary / (binary / (id \"a\") (id \"b\")) (id \"c\"))", "division")
    t.equal(jsTestExpr("a\n/b/g"), "(binary / (binary / (id \"a\") (id \"b\")) (id \"g\"))", "division across lines")
    t.check(jsTestOK("x = y / 2 / z; if (a) /re/.test(b); {}/re/; (1)/2; a++ / 2; x = /=/"), "regex positions")
    t.check(jsTestOK("function* g(){ yield /re/ }") && jsTestOK("return_ = typeof /x/"), "regex after yield/typeof")
    t.equal(jsTestParse("{}\n/foo/"), "(script (block) (expr (regexp \"foo\" \"\")))", "regex after block")
    t.check(!jsTestOK("/a/gg") && !jsTestOK("/a/x") && !jsTestOK("/a/uv"), "bad regex flags")
    t.check(!jsTestOK("/abc") && !jsTestOK("/a\nb/"), "unterminated regex")
    // Comments.
    t.check(jsTestOK("a /* x */ + /* y\n */ b // z"), "comments")
    t.check(!jsTestOK("/* abc"), "unterminated comment")
    t.check(jsTestOK("x = 1 <!-- comment\n--> also a comment\ny = 2"), "HTML-like comments in scripts")
    t.check(jsTestOK("/*\n*/ --> comment"), "--> after a multi-line comment")
    t.check(!jsTestOK("<!-- y", module: true) && !jsTestOK("x\n--> y", module: true), "no HTML comments in modules")
    t.equal(jsTestExpr("a --> b"), "(binary > (update -- (id \"a\")) (id \"b\"))", "--> mid-line is an operator")
    t.check(jsTestOK("#!/usr/bin/env node\nx"), "hashbang")
    t.check(jsTestOK("\u{FEFF}x\u{A0}=\u{3000}1"), "Unicode whitespace")
}

// MARK: AST shape

func jsASTShapeTests(_ t: Tests) {
    t.section("ast shape")
    let cases: [(String, String)] = [
        ("let {a, b: [c = 1, ...d], ...e} = f;",
         "(script (var let (decl (object-pattern (prop shorthand (name \"a\") (id \"a\")) (prop (name \"b\") (array-pattern (assign-pattern (id \"c\") (num 1)) (rest (id \"d\")))) (rest (id \"e\"))) (id \"f\"))))"),
        ("[a, b] = [b, a]",
         "(script (expr (assign = (array-pattern (id \"a\") (id \"b\")) (array (id \"b\") (id \"a\")))))"),
        ("({a = 1, b: {c}} = x)",
         "(script (expr (assign = paren (object-pattern (prop shorthand (name \"a\") (assign-pattern (id \"a\") (num 1))) (prop (name \"b\") (object-pattern (prop shorthand (name \"c\") (id \"c\"))))) (id \"x\"))))"),
        ("(a, b = 2, ...c) => a",
         "(script (expr (function arrow expr-body - (id \"a\") (assign-pattern (id \"b\") (num 2)) (rest (id \"c\")) (id \"a\"))))"),
        ("async x => await x",
         "(script (expr (function arrow async expr-body - (id \"x\") (await (id \"x\")))))"),
        ("async (a) => {}", "(script (expr (function arrow async - (id \"a\") (body))))"),
        ("async(a)", "(script (expr (call (id \"async\") (id \"a\"))))"),
        ("a?.b.c(d)?.[e]",
         "(script (expr (chain (index ?. (call (member (member ?. (id \"a\") \"b\") \"c\") (id \"d\")) (id \"e\")))))"),
        ("a ?? b || c ? d : e", "error: '??' can't be mixed with '&&' or '||' without parentheses @1:1"),
        ("a ** b ** c", "(script (expr (binary ** (id \"a\") (binary ** (id \"b\") (id \"c\")))))"),
        ("a = b += c ||= d",
         "(script (expr (assign = (id \"a\") (assign += (id \"b\") (assign ||= (id \"c\") (id \"d\"))))))"),
        ("class A extends B { static #x = 1; get y() { return this.#x } static { this.z = 1 } constructor() { super() } }",
         "(script (class (id \"A\") (id \"B\") (prop field static (private \"x\") (num 1)) (prop get (name \"y\") (function get - (body (return (private-member (this) \"x\"))))) (static-block (expr (assign = (member (this) \"z\") (num 1)))) (prop method (name \"constructor\") (function derived-ctor - (body (expr (call (super))))))))"),
        ("for (const [k, v] of m) ;",
         "(script (for-of (var const (decl (array-pattern (id \"k\") (id \"v\")) -)) (id \"m\") (empty)))"),
        ("for await (x of y) ;", "error: for await is only valid in async functions @1:5"),
        ("label: for (;;) { continue label; }",
         "(script (label \"label\" (for - - - (block (continue \"label\")))))"),
        ("new a.b(c).d", "(script (expr (member (new (member (id \"a\") \"b\") (id \"c\")) \"d\")))"),
        ("new new a()()", "(script (expr (new (new (id \"a\")))))"),
        ("x = {get a() {}, set a(v) {}, async *b() {}, [c]: 1, 'd': 2, 3: 3, e, ...f}",
         "(script (expr (assign = (id \"x\") (object (prop get (name \"a\") (function get - (body))) (prop set (name \"a\") (function set - (id \"v\") (body))) (prop method (name \"b\") (function method async * - (body))) (prop computed (id \"c\") (num 1)) (prop (str \"d\") (num 2)) (prop (num 3) (num 3)) (prop shorthand (name \"e\") (id \"e\")) (spread (id \"f\"))))))"),
        ("a\n++b", "(script (expr (id \"a\")) (expr (update ++ prefix (id \"b\"))))"),
        ("return", "error: return outside of a function @1:1"),
        ("function f() { return\n1 }", "(script (function (id \"f\") (body (return -) (expr (num 1)))))"),
        ("'use strict'; x", "(script strict (expr directive (str \"use strict\")) (expr (id \"x\")))"),
        ("#x in y", "error: private name '#x' outside a class @1:1"),
        ("class C { #x; m(o) { return #x in o } }",
         "(script (class (id \"C\") - (prop field (private \"x\") -) (prop method (name \"m\") (function method - (id \"o\") (body (return (binary in (private \"x\") (id \"o\"))))))))"),
        ("if (a) function f(){}", "(script (if (id \"a\") (function (id \"f\") (body)) -))"),
        ("do x; while (y) z", "(script (do-while (expr (id \"x\")) (id \"y\")) (expr (id \"z\")))"),
        ("let\nx = 1", "(script (var let (decl (id \"x\") (num 1))))"),
        ("var let = 1; let\n[a] = b", "(script (var var (decl (id \"let\") (num 1))) (var let (decl (array-pattern (id \"a\")) (id \"b\"))))"),
        ("a = b\n(c)", "(script (expr (assign = (id \"a\") (call (id \"b\") (id \"c\")))))"),
        ("x => {}\n(1)", "(script (expr (function arrow - (id \"x\") (body))) (expr (num paren 1)))"),
        ("yield = 1; async = 2; let = 3; of = 4",
         "(script (expr (assign = (id \"yield\") (num 1))) (expr (assign = (id \"async\") (num 2))) (expr (assign = (id \"let\") (num 3))) (expr (assign = (id \"of\") (num 4))))"),
    ]
    for (src, want) in cases { t.equal(jsTestParse(src), want, "shape: \(src)") }
    t.equal(jsTestParse("import d, {a as b, \"c d\" as e} from 'm'; export {b as \"x y\"}; export * as ns from 'n'; export default 1;", module: true),
            "(module strict (import \"m\" (import-default (id \"d\")) (import-spec \"a\" (id \"b\")) (import-spec \"c d\" (id \"e\"))) (export - (export-spec \"b\" \"x y\") -) (export-all \"n\" \"ns\") (export-default (num 1)))",
            "module shape")

    // Positions and flags.
    if let ast = try? jsParse(Array("function f(a) {\n  return arguments[0] + this.x\n}".utf8)) {
        let f = ast.list(ast[ast.root].a, ast[ast.root].b).first ?? 0
        let fn = ast[f]
        t.check(fn.kind == .function && fn.start == 0 && Int(fn.end) == ast.source.count, "function span")
        t.check(fn.flags & JSNodeFlags.usesArguments != 0 && fn.flags & JSNodeFlags.usesThis != 0, "usesArguments/usesThis")
        t.check(fn.flags & JSNodeFlags.simpleParams != 0 && fn.flags & JSNodeFlags.strict == 0, "simple, sloppy")
        var ok = true
        for i in 0..<ast.nodes.count {
            let n = ast.nodes[i]
            if n.start > n.end || Int(n.end) > ast.source.count { ok = false }
            ast.forEachChild(Int32(i)) { c in if c >= Int32(i) { ok = false } }
        }
        t.check(ok, "every node: start <= end, children before parent")
        let ret = ast.nodes.firstIndex { $0.kind == .returnStmt } ?? 0
        let loc = JSLineMap(ast.source).location(Int(ast.nodes[ret].start))
        t.check(loc.line == 2 && loc.column == 3, "line/column of return", "\(loc.line):\(loc.column)")
    } else { t.check(false, "position sample parses") }
    if let ast = try? jsParse(Array("function f() { eval('x') } function g() { 'use strict'; return () => this }".utf8)) {
        let fs = ast.nodes.filter { $0.kind == .function }
        t.check(fs.count == 3, "three functions")
        t.check(fs[0].flags & JSNodeFlags.hasDirectEval != 0, "direct eval flagged")
        t.check(ast[ast.root].flags & JSNodeFlags.hasDirectEval != 0, "eval flag reaches the script")
        t.check(fs[2].flags & JSNodeFlags.strict != 0 && fs[2].flags & JSNodeFlags.hasUseStrict != 0, "use strict function")
        t.check(fs[1].flags & JSNodeFlags.strict != 0 && fs[1].flags & JSNodeFlags.usesThis != 0, "strict arrow captures this")
        t.check(fs[2].flags & JSNodeFlags.usesThis != 0, "arrow this propagates to the function")
    } else { t.check(false, "flag sample parses") }
    if let ast = try? jsParse(Array("x = 1.5; y = 'x'; z = x".utf8)) {
        let ids = ast.nodes.filter { $0.kind == .identifier && ast.pool.equals($0.a, "x") }
        t.check(ids.count == 2 && ids[0].a == ids[1].a, "names are interned")
        let s = ast.nodes.first { $0.kind == .string }
        t.check(s?.a == ids[0].a, "string 'x' and name x share an id")
    }
}

// MARK: valid syntax

let jsValidSamples: [String] = [
    "var a, b = 1, c;", "let [x, , y = 2, ...z] = arr;", "const {a: {b}, ...r} = o;",
    "function f(a = 1, {b, c} = {}, [d] = [], ...e) {}", "function* g() { yield; yield* h(); yield\n1 }",
    "async function f() { await x; for await (const y of z) {} }", "async function* ag() { yield await 1 }",
    "class A { a = 1; static b; #c = 2; static #d() {} get #e() {} set #e(v) {} static async *[Symbol.iterator]() {} 'constructor'() {} }",
    "class B extends (A, C) { constructor() { super(); super.x; super[y](); new.target } }",
    "class C { static { var await_ = 1; } static x = this; static async = 1; get = 2; set; static }",
    "class D { get\nx() {} static\nm() {} async\nn() {} }",
    "o = { __proto__: a, ['__proto__']: b, __proto__() {} }", "({ __proto__: a, __proto__: b } = x)",
    "label: { break label; }", "a: b: while (1) { continue a; }",
    "switch (x) { case 1: let y; break; default: }", "try {} catch {} finally {}", "try {} catch ([a, b]) {}",
    "for (var i = 0, n = a.length; i < n; i++) {}", "for (x in y); for (x of y); for (let [a] of b); for (var {c} in d);",
    "for (let in x);", "for (async.x of y);", "for ((async) of y);", "for (var x = 1 in y);",
    "if (a) b; else if (c) d; else e", "with (o) x", "debugger;", ";;;",
    "a?.(b)?.c?.[d]", "x = a ? b : c ? d : e", "x = (a, b)", "x = a ?? b", "x = (a || b) ?? c",
    "x &&= y; x ||= y; x ??= y; x **= 2; x >>>= 1", "x = -a ** 2".isEmpty ? "" : "x = (-a) ** 2",
    "x = typeof a === 'b' && !c instanceof D", "x = a in b", "delete a.b; void 0; typeof x",
    "x = `a${`b${c}`}`", "x = tag`a${b}c`", "x = String.raw`\\u`",
    "x = function* () {}; y = async function () {}; z = async () => {}; w = async function* () {}",
    "x = class { }; y = class Named extends Object {}", "x = new.target".isEmpty ? "" : "function f() { x = new.target }",
    "x = (a, b) => ({a, b}); y = () => () => 1; z = async (...args) => args",
    "x = a => b => c", "x = ([a] = [], {b} = {}) => a + b", "(function () { 'use strict'; })",
    "x = { if: 1, class: 2, new: 3, typeof: 4 }; x.if; x.class", "x = { get: 1, set: 2, async: 3, static: 4 }",
    "x = { get() {}, set() {}, async() {}, static() {} }", "x = { async *gen() {}, async get() {} }",
    "var yield, async, await, let, static, implements, of, get, set;", "x = yield => yield", "x = async => async",
    "var \\u{61}wait;", "x = { 'a-b': 1, 0x10: 2, 1e3: 3, 1n: 4 }", "x = [, , 1, , ]",
    "x = a\n?.5:1", "x = a?.5:1", "x = 0\n.toString()", "a = b ? c : d => e",
    "new Foo; new Foo.Bar(); new (foo())(); new foo.bar[baz]`x`", "x = import.meta".isEmpty ? "" : "import('x').then()",
    "async function f() { await import('x') }", "(async () => { await 1 })()",
    "label: function f() {}", "if (x) function f() {} else function g() {}",
    "{ function f() {} function f() {} }", "var f; function f() {}", "function f(a, a) {}",
    "x = 08; y = 0777; z = '\\08'", "var arguments; eval = 1; arguments = 2", "function eval() {}",
    "a\n++\nb", "throw x;", "x = /[/]/; y = /\\//; z = /a/dgimsuy", "x = /(?<name>a)\\k<name>/",
    "x = 1_000.000_1e1_0", "x = 0b1_0n + 0xF_Fn + 0o7_7n", "x = .5e-3",
    "var \\u0076ar2;", "x = { \\u0069f: 1 }", "x.\\u0069f", "class E { static async *#m() {} }",
    "x = function f(f) { var f; }", "try {} catch (e) { var e; }", "try {} catch (e) { for (var e in x); }",
    "function f() { 'use strict'; return this }", "'use strict'; var public_ = 1",
    "export_ = import_ = 1", "x = a!=b!==c==d===e", "x = a<<b>>c>>>d", "x=a<b>c<=d>=e",
    "x = !~-+a", "x = a++ + ++b - b-- - --a", "x = a+ +b - -c",
    "while (false) ; do ; while (false)", "do {} while (false) x", "x\n++y",
]

func jsValidSyntaxTests(_ t: Tests) {
    t.section("valid syntax")
    for s in jsValidSamples where !s.isEmpty {
        let r = jsTestParse(s)
        t.check(!r.hasPrefix("error"), "parses: \(s)", r)
    }
    let modules: [String] = [
        "import x from 'a'; import * as ns from 'b'; import {a, b as c} from 'c'; import 'd';",
        "export const a = 1; export function f() {} export class C {} export { a as b, f as default };",
        "export default function () {}", "export default class {}", "export default async function f() {}",
        "export * from 'x'; export * as y from 'z'; export { q } from 'r'; export { 'a b' as c } from 'd';",
        "await x; for await (const y of z) {}", "x = import.meta.url", "export default (a, b) => a + b;",
        "let x; export { x };", "export var v; var w; export { w as v2 }",
    ]
    for s in modules {
        let r = jsTestParse(s, module: true)
        t.check(!r.hasPrefix("error"), "module parses: \(s)", r)
    }
}

// MARK: early errors

let jsInvalidSamples: [String] = [
    // duplicate lexical names, let/var conflicts
    "let a; let a;", "let a; var a;", "var a; let a;", "const a = 1; function a() {}", "let a; { var a; }",
    "{ let a; var a; }", "function f(a) { let a; }", "try {} catch (e) { let e; }", "try {} catch ([e]) { var e; }",
    "class A {} class A {}", "let [a, a] = x;", "for (let a of b) { var a; }", "switch (x) { case 1: let a; case 2: let a; }",
    "'use strict'; { function f() {} function f() {} }", "{ function* f() {} function f() {} }",
    "{ async function f() {} function f() {} }", "let let = 1;", "const let = 1;", "for (let let of x);",
    "class let {}", "let a, b, a;",
    // strict mode
    "'use strict'; with (a) {}", "'use strict'; var yield;", "'use strict'; var let;", "'use strict'; var static;",
    "'use strict'; var implements;", "'use strict'; eval = 1;", "'use strict'; arguments++;", "'use strict'; delete x;",
    "'use strict'; delete (x);", "'use strict'; x = 017;", "'use strict'; x = 08;", "'use strict'; function f(a, a) {}",
    "function f(a, a) { 'use strict' }", "function eval() { 'use strict' }", "function f(eval) { 'use strict' }",
    "function f(a = 1) { 'use strict' }", "function f() { '\\07'; 'use strict'; }", "'use strict'; function arguments() {}",
    "'use strict'; ({eval} = x);", "'use strict'; [arguments] = x;", "'use strict'; if (x) function f() {}",
    "'use strict'; label: function f() {}", "class C { m() { with (x) {} } }", "class C extends (x = 017) {}",
    // yield/await contexts
    "function* g() { var yield; }", "function* g(x = yield) {}", "function* g() { function* yield() {} }",
    "async function f() { var await; }", "async function f(x = await 1) {}", "async function f() { function await() {} ; await: 1 }",
    "async (await) => 1", "async (x = await 1) => 1", "function* g() { (x = yield) => 1 }",
    "async function f() { (x = await 1) => 1 }", "await x", "function f() { await x }", "x = await => 1".isEmpty ? "" : "async await => 1",
    "class C { static { await; } }", "class C { static { var await; } }", "class C { static { arguments; } }",
    "class C { x = arguments; }", "class C { x = () => arguments; }", "function* g() { yield\n* 1 }",
    "for await (x of y);", "async function f() { for await (x in y); }",
    // classes
    "class A { constructor() {} constructor() {} }", "class A { get constructor() {} }", "class A { *constructor() {} }",
    "class A { async constructor() {} }", "class A { constructor = 1 }", "class A { static prototype() {} }",
    "class A { static prototype = 1 }", "class A { #constructor() {} }", "class A { #a; #a; }",
    "class A { get #a() {} get #a() {} }", "class A { static get #a() {} set #a(v) {} }", "class A { m() { this.#x } }",
    "this.#x", "class A { #a; m() { delete this.#a } }", "class A { constructor() { super() } }",
    "function f() { super.x }", "x = { m() { super() } }", "class A extends B { m() { super() } }",
    "class A { #x; m() { return #y in this } }", "class A { a b }", "class A { m() {} = 1 }", "class A { get a(x) {} }",
    "class A { set a() {} }", "class A { set a(...x) {} }", "x = { get a(b) {} }", "x = { set a(b, c) {} }",
    // destructuring and cover grammars
    "({a = 1})", "({a = 1}).b", "x = {a = 1}", "[{a = 1}.b] = x", "({a: 1} = x)", "[a + b] = x", "[...a, b] = x",
    "[...a,] = x", "({...a,} = x)", "({...{a}} = x)", "({a}) = x", "([a]) = x", "[(a = 1)] = x", "({get a() {}} = x)",
    "(a, b) = x", "a + b = c", "a++ = 1", "++a++", "(a => a) = 1", "x = (a, ...b)", "x = (...a)", "x = (a,)",
    "x = ()", "(a.b) => 1", "((a)) => 1", "([a.b]) => 1", "({a: b.c}) => 1", "(a, a) => 1", "({a, a}) => 1",
    "(...a = 1) => 1", "(...a, b) => 1", "x = a\n=> 1", "x = async a\n=> 1", "async (...a,) => 1",
    "({a: 1, __proto__: 1, __proto__: 2})", "x = {__proto__: 1, '__proto__': 2}", "for ({a = 1}.b of x);",
    "for (let x = 1 of y);", "for (let x = 1 in y);", "'use strict'; for (var x = 1 in y);", "for (var [x] = 1 in y);",
    "for (var x, y of z);", "for (let of x);", "for (async of x);", "for (a = 1 of x);", "for (const x;;);",
    "const x;", "let [a];", "var {b};", "x => {} ? a : b", "a + x => x", "!x => x", "x = y => z + 1 = 2",
    // operators
    "a ?? b || c", "a || b ?? c", "a && b ?? c", "-a ** 2", "typeof a ** 2", "async function f() { await a ** 2 }",
    "a?.b = 1", "a?.b++", "new a?.b()", "a?.b`x`", "delete a?.#x".isEmpty ? "" : "class C { #x; m() { delete this?.#x } }",
    "super", "new.target", "x = new.target", "() => new.target", "import.meta", "new import('x')", "import(...a)",
    "import()", "import(a, b, c)",
    // statements
    "break;", "continue;", "if (x) break;", "label: label: x", "a: { continue a; }", "while (x) { break b; }",
    "function f() { a: while (1) { function g() { break a; } } }", "if (x) let y = 1;", "if (x) const y = 1;",
    "if (x) class C {}", "while (x) function f() {}", "do function f() {} while (0)", "if (x) function* g() {}",
    "if (x) async function f() {}", "label: function* g() {}", "while (1) label: function f() {}",
    "switch (x) { default: default: }", "try {}", "throw\nx", "x = 1 y = 2", "var x = 1 var y", "{ a b }",
    "for (;;) let [x] = 1", "for (let.x of y);", "a?.b`x`.c", "with (a) let [x] = 1",
    // modules
    "import x from 'a';", "export var x;", "{ import x from 'a'; }", "export { x };",
    "function f() { export var x; }",
]

let jsInvalidModules: [String] = [
    "export { x };", "export { a as b }; let a; export { c as b }; let c;", "export default 1; export default 2;",
    "let x; export { x, x };", "export { 'a' }; ", "export { if };", "import { 'a b' } from 'x';", "var await;",
    "await: 1", "function f() { await x }", "x = { await }", "import { a, a } from 'x';", "let a; import { a } from 'x';",
    "<!-- x", "x\n--> y", "with (a) {}", "x = 017", "export default function f() {} function f() {}",
    "function f() {} function f() {}", "export { a as '\\uD800' } from 'x'; ", "new.target", "export let await = 1",
]

func jsEarlyErrorTests(_ t: Tests) {
    t.section("early errors")
    for s in jsInvalidSamples where !s.isEmpty {
        t.check(!jsTestOK(s), "rejects: \(s)")
    }
    for s in jsInvalidModules {
        t.check(!jsTestOK(s, module: true), "module rejects: \(s)")
    }
    // Errors carry positions.
    do {
        _ = try jsParse(Array("var a = 1;\nlet b;\nlet b;".utf8))
        t.check(false, "duplicate let")
    } catch {
        t.check(error.line == 3 && error.column == 5 && error.offset == 22, "error position", "\(error.line):\(error.column) @\(error.offset)")
    }
}

// MARK: limits

/// Each nesting shape at `n` levels: (prefix, middle, suffix).
let jsDeepShapes: [(String, String, String)] = [
    ("(", "1", ")"), ("[", "1", "]"), ("x={a:", "1", "}"), ("a(", "1", ")"), ("!", "1", ""), ("- ", "1", ""),
    ("a=", "1", ""), ("a?b:", "1", ""), ("{", "", "}"), ("if(1)", ";", ""), ("function f(){", "", "}"),
    ("()=>", "1", ""), ("`${", "1", "}`"), ("new ", "a", ""), ("a**", "1", ""), ("[", "a", "]=1"),
    ("x=>", "1", ""), ("class A extends ", "B", "{}"), ("a[", "1", "]"), ("while(1)", ";", ""),
    ("function f(a=[", "1", "]){}"), ("let [", "a", "]=1"), ("async()=>", "1", ""), ("typeof ", "1", ""), ("yield_ = function*(){yield ", "1", "}"),
]

func jsDeep(_ shape: (String, String, String), _ n: Int) -> [UInt8] {
    var s: [UInt8] = []
    if shape.0 == "let [" {
        // A nested binding pattern: let [[[a]]] = 1
        s = Array("let ".utf8)
        for _ in 0..<n { s.append(0x5B) }
        s.append(0x61)
        for _ in 0..<n { s.append(0x5D) }
        s.append(contentsOf: Array("=1".utf8))
        return s
    }
    for _ in 0..<n { s.append(contentsOf: Array(shape.0.utf8)) }
    s.append(contentsOf: Array(shape.1.utf8))
    for _ in 0..<n { s.append(contentsOf: Array(shape.2.utf8)) }
    return s
}

/// Set by jsDeepThread (runs on a 512 KB stack).
var jsDeepResults: [Bool] = []

func jsDeepThreadBody() {
    // Every shape just under the default depth limit must parse (or fail
    // cleanly) without overflowing a 512 KB stack, and 100 000 deep is a
    // SyntaxError.
    jsDeepResults = []
    let limits = JSLimits()
    for shape in jsDeepShapes {
        let ok = (try? jsParse(jsDeep(shape, 120), JSParseOptions(limits: limits))) != nil
        jsDeepResults.append(ok)
        // Right at the limit: may parse or fail, but must not overflow.
        _ = try? jsParse(jsDeep(shape, limits.maxASTDepth - 2), JSParseOptions(limits: limits))
    }
    for shape in jsDeepShapes {
        var failed = false
        do { _ = try jsParse(jsDeep(shape, 100_000)) } catch { failed = error.message == "nesting too deep" }
        jsDeepResults.append(failed)
    }
}

func jsLimitTests(_ t: Tests) {
    t.section("limits")
    let r = host_run_with_stack(512 << 10, { _ in jsDeepThreadBody(); return nil }, nil)
    t.check(r == 0, "512 KB stack thread runs")
    let n = jsDeepShapes.count
    if jsDeepResults.count == 2 * n {
        for i in 0..<n {
            let shape = jsDeepShapes[i]
            t.check(jsDeepResults[i], "\(shape.0)...\(shape.2) 120 deep parses")
            t.check(jsDeepResults[n + i], "\(shape.0)...\(shape.2) 100 000 deep is 'nesting too deep'")
        }
    } else {
        t.check(false, "deep results", "\(jsDeepResults.count)")
    }
    // A long left-associative chain is bounded by maxASTHeight, not recursion.
    var chain = "x"
    for _ in 0..<3000 { chain += "+x" }
    t.check(!jsTestOK(chain), "3000-term chain exceeds maxASTHeight")
    var short = "x"
    for _ in 0..<1500 { short += "+x" }
    t.check(jsTestOK(short), "1500-term chain parses")
    // Source size and node count.
    var small = JSLimits.small
    small.maxSourceBytes = 100
    t.check((try? jsParse(Array(String(repeating: " ", count: 101).utf8), JSParseOptions(limits: small))) == nil, "source size limit")
    var nodes = JSLimits()
    nodes.maxASTNodes = 50
    t.check((try? jsParse(Array(String(repeating: "x;", count: 60).utf8), JSParseOptions(limits: nodes))) == nil, "node limit")
}

// MARK: fuzz

func jsParserFuzz(_ t: Tests) {
    t.section("fuzz")
    var seeds: [[UInt8]] = jsValidSamples.filter { !$0.isEmpty }.map { Array($0.utf8) }
    seeds.append(contentsOf: jsInvalidSamples.filter { !$0.isEmpty }.prefix(60).map { Array($0.utf8) })
    for name in ["jquery-3.7.1.js", "vue-3.5.13.global.js", "three-0.170.0.module.js", "lit-core-3.2.1.min.module.js"] {
        if let b = t.readFileIfPresent("lib/js/fixtures/corpus/\(name)") {
            var i = 0
            while i < b.count && seeds.count < 400 {
                seeds.append(Array(b[i..<min(b.count, i + 3000)]))
                i += 97_000
            }
        }
    }
    var parsed = 0
    let opts = [JSParseOptions(limits: .small), JSParseOptions(module: true, limits: .small),
                JSParseOptions(strict: true, limits: .small)]
    var which = 0
    t.fuzz("js parser", seeds: seeds, iterations: 30_000) { input in
        which += 1
        if let ast = try? jsParse(input, opts[which % 3]) {
            parsed += 1
            _ = ast.dump(ast.root).count
        }
    }
    t.check(parsed > 100, "some fuzz inputs parse", "\(parsed)")
}
