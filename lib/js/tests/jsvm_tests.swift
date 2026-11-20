// Host tests for lib/js's compiler and VM (Phase 9B, second half): scripts
// with expected completion values, exceptions and stack traces, the
// embedding API, interrupts and limits, a GC stress pass, deep nesting on
// a 512 KiB stack, a VM fuzz, and perf numbers.

/// (source, expected realm.evaluateToString result).
let jsVMCases: [(String, String)] = [
    // Literals and operators.
    ("1 + 2", "3"),
    ("var x = 5; x * 2", "10"),
    ("'a' + 1", "a1"),
    ("1 + 2 + '3'", "33"),
    ("0.1 + 0.2", "0.30000000000000004"),
    ("2147483647 + 1", "2147483648"),
    ("-2147483648 - 1", "-2147483649"),
    ("7 % 3 + ',' + (-7 % 3) + ',' + (5.5 % 2)", "1,-1,1.5"),
    ("2 ** 10 + ',' + 2 ** -1 + ',' + (-2) ** 3", "1024,0.5,-8"),
    ("1 / 0 + ',' + -1 / 0 + ',' + 0 / 0", "Infinity,-Infinity,NaN"),
    ("(1 << 31) + ',' + (-1 >>> 0) + ',' + (-16 >> 2) + ',' + (5 & 3) + ',' + (5 | 3) + ',' + (5 ^ 3) + ',' + ~5", "-2147483648,4294967295,-4,1,7,6,-6"),
    ("'abc' < 'abd'", "true"),
    ("'10' < '9'", "true"),
    ("10 < '9'", "false"),
    ("null == undefined", "true"),
    ("null === undefined", "false"),
    ("'1' == 1", "true"),
    ("true == 1", "true"),
    ("NaN == NaN", "false"),
    ("var o = {}; o == o", "true"),
    ("({valueOf: function(){ return 42 }}) == 42", "true"),
    ("typeof 1 + typeof 'a' + typeof undefined + typeof null + typeof {} + typeof function(){} + typeof Symbol()", "numberstringundefinedobjectobjectfunctionsymbol"),
    ("typeof notDeclared", "undefined"),
    ("!0 + ',' + !'' + ',' + !!'x'", "true,true,true"),
    ("void 0", "undefined"),
    ("var a = 1, b = (a++, a++, a); a + ',' + b", "3,3"),
    ("1 && 2", "2"),
    ("0 || 'x'", "x"),
    ("null ?? 5", "5"),
    ("0 ?? 5", "0"),
    ("var x = 0; x ||= 3; var y = 1; y &&= 4; var z; z ??= 7; x + y + z", "14"),
    ("true ? 'a' : 'b'", "a"),
    ("+'  42  ' + 1", "43"),
    ("-'3'", "-3"),
    ("'x' + {}", "x[object Object]"),
    ("[] + 1", "1"),
    ("'5' * '2'", "10"),
    ("var i = 5; i++ + ++i", "12"),
    ("var o = {a: 1}; o.a++; o.a += 2; o['a'] *= 3; o.a", "12"),
    ("var a = [1, 2]; a[1]--; --a[0]; a[0] + ',' + a[1]", "0,1"),
    ("1 instanceof Object", "false"),
    ("({}) instanceof Object", "true"),
    ("'a' in {a: 1}", "true"),
    ("0 in [5]", "true"),
    ("delete ({a: 1}).a", "true"),
    // Strings.
    ("'hello'.length", "5"),
    ("'hello'[1]", "e"),
    ("'h\\u00e9llo'.length", "5"),
    ("'\\ud83d\\ude00'.length", "2"),
    ("`a${1 + 1}b${'c'}`", "a2bc"),
    ("`x`", "x"),
    ("var n = 3; `${n}${n}`", "33"),
    // Variables, scopes, hoisting.
    ("x = 3; x", "3"),
    ("var x; typeof x", "undefined"),
    ("f(); function f() { return 1 }", "1"),
    ("var r = typeof g; function g() {} r", "function"),
    ("let a = 1; { let a = 2; } a", "1"),
    ("const c = 5; c", "5"),
    ("let x = 1; { let x = x + 1; }", "Uncaught ReferenceError: Cannot access 'x' before initialization"),
    ("const c = 1; c = 2", "Uncaught TypeError: Assignment to constant variable."),
    ("function f() { const c = 1; c = 2 } f()", "Uncaught TypeError: Assignment to constant variable."),
    ("function f() { return y; let y = 1 } f()", "Uncaught ReferenceError: Cannot access 'y' before initialization"),
    ("undefinedVariable", "Uncaught ReferenceError: undefinedVariable is not defined"),
    ("'use strict'; undeclared = 1", "Uncaught ReferenceError: undeclared is not defined"),
    ("var s = ''; for (var i = 0; i < 3; i++) { s += i } s", "012"),
    ("var fs = []; for (let i = 0; i < 3; i++) { fs[i] = function () { return i } } fs[0]() + fs[1]() + fs[2]()", "3"),
    ("var fs = []; for (var i = 0; i < 3; i++) { fs[i] = function () { return i } } fs[0]() + fs[1]() + fs[2]()", "9"),
    ("var fs = []; for (const k of [1, 2, 3]) { fs.push(() => k) } fs[0]() * 100 + fs[1]() * 10 + fs[2]()", "123"),
    ("{ function blockFn() { return 'b' } } blockFn()", "b"),
    ("(function () { if (true) { function inner() { return 7 } } return inner() })()", "7"),
    ("var x = 1; function f() { var x = 2; return x } f() + x", "3"),
    ("function f(a, b) { return arguments.length + ',' + arguments[1] } f(1, 2, 3)", "3,2"),
    ("function f(a, a) { return a } f(1, 2)", "2"),
    ("function f(a, b = a + 1, ...rest) { return a + b + rest.length } f(1) + ',' + f(1, 5, 6, 7)", "3,8"),
    ("function f(...r) { return r.length } f() + f(1, 2)", "2"),
    ("(function f() { return typeof f })()", "function"),
    ("var g = function h() { h = 1; return typeof h }; g()", "function"),
    ("var f = function () {}; f.name", "f"),
    ("var o = { m() {} , get x() { return 1 } }; o.m.name", "m"),
    ("let arrow = () => 1; arrow.name", "arrow"),
    ("(function () { return this })() === globalThis", "true"),
    ("(function () { 'use strict'; return this })()", "undefined"),
    ("this === globalThis", "true"),
    ("var o = { f() { return () => this } }; o.f()() === o", "true"),
    ("function F() { this.x = 1; return () => this.x } new F()()", "1"),
    ("(() => { return arguments })()", "Uncaught ReferenceError: arguments is not defined"),
    ("function f() { return (() => arguments[0])() } f(9)", "9"),
    // Closures.
    ("function mk() { var n = 0; return function () { return ++n } } var c = mk(); c(); c(); c()", "3"),
    ("function adder(a) { return function (b) { return function (c) { return a + b + c } } } adder(1)(2)(3)", "6"),
    ("var c1 = (function () { let x = 10; return { get: () => x, set: v => { x = v } } })(); c1.set(5); c1.get()", "5"),
    // Control flow.
    ("var s = 0; var i = 0; while (i < 10) { i++; if (i % 2) continue; s += i } s", "30"),
    ("var i = 0; do { i++ } while (i < 5); i", "5"),
    ("var s = ''; outer: for (var i = 0; i < 3; i++) { for (var j = 0; j < 3; j++) { if (j == 1) continue outer; if (i == 2) break outer; s += i + '' + j } } s", "0010"),
    ("lbl: { 1; break lbl; 2 }", "1"),
    ("var r; switch (3) { case 1: r = 'a'; break; case 3: r = 'c'; case 4: r += 'd'; break; default: r = 'z' } r", "cd"),
    ("var r = ''; switch ('x') { default: r += 'd'; case 'y': r += 'y' } r", "dy"),
    ("switch (1) { case 1: let q = 5; q }", "5"),
    ("var s = ''; for (var k in {a: 1, b: 2, c: 3}) s += k; s", "abc"),
    ("var s = ''; for (var k in [7, 8]) s += k; s", "01"),
    ("var o = {a: 1, b: 2}; var s = ''; for (var k in o) { delete o.b; s += k } s", "a"),
    ("function P() { this.own = 1 } P.prototype.inh = 2; var s = ''; for (var k in new P()) s += k; s", "owninh"),
    ("var s = 0; for (var v of [1, 2, 3]) s += v; s", "6"),
    ("var s = ''; for (var ch of 'a\\ud83d\\ude00b') s += '[' + ch.length + ']'; s", "[1][2][1]"),
    ("var s = 0; for (const [a, b] of [[1, 2], [3, 4]]) s += a * b; s", "14"),
    ("var it = { [Symbol.iterator]() { var i = 0; return { next() { return { value: i, done: i++ >= 3 } } } } }; var s = ''; for (var v of it) s += v; s", "012"),
    ("var closed = 0; var it = { [Symbol.iterator]() { return { next() { return { value: 1, done: false } }, return() { closed++; return {} } } } }; for (var v of it) break; closed", "1"),
    ("var closed = 0; var it = { [Symbol.iterator]() { return { next() { return { value: 1, done: false } }, return() { closed++; return {} } } } }; try { for (var v of it) throw 1 } catch (e) {} closed", "1"),
    ("for (var x of 5) {}", "Uncaught TypeError: 5 is not iterable"),
    // Exceptions.
    ("try { throw 1 } catch (e) { e + 1 }", "2"),
    ("try { null.x } catch (e) { e instanceof TypeError }", "true"),
    ("try { null.x } catch (e) { e.message }", "Cannot read properties of null (reading 'x')"),
    ("var r = ''; try { r += 'a'; throw 'x' } catch (e) { r += e } finally { r += 'f' } r", "axf"),
    ("function f() { try { return 'try' } finally { g = 'fin' } } var g; f() + g", "tryfin"),
    ("function f() { try { return 1 } finally { return 2 } } f()", "2"),
    ("function f() { for (var i = 0; i < 5; i++) { try { if (i == 2) break } finally { s += i } } return s } var s = ''; f()", "012"),
    ("var s = ''; for (var i = 0; i < 3; i++) { try { continue } finally { s += i } } s", "012"),
    ("function f() { try { try { throw 1 } finally { s += 'a' } } catch (e) { s += 'b' + e } finally { s += 'c' } } var s = ''; f(); s", "ab1c"),
    ("try { try { throw new Error('in') } finally { } } catch (e) { e.message }", "in"),
    ("function thrower() { throw new RangeError('deep') } function mid() { thrower() } try { mid() } catch (e) { e.name + ':' + e.message }", "RangeError:deep"),
    ("try { undefinedFn() } catch (e) { e.constructor === ReferenceError }", "true"),
    ("try { (void 0)() } catch (e) { e.message }", "undefined is not a function"),
    ("try { new 5 } catch (e) { e.message }", "5 is not a constructor"),
    ("try { throw {code: 7} } catch ({code}) { code }", "7"),
    ("try { throw 1 } catch { 'nobind' }", "nobind"),
    ("var e = new Error('m', {cause: 4}); e.cause + e.message", "4m"),
    ("String(new TypeError('bad'))", "TypeError: bad"),
    ("Object.prototype.toString.call([])", "[object Array]"),
    ("throw new Error('top')", "Uncaught Error: top"),
    ("throw 42", "Uncaught 42"),
    // Objects and prototypes.
    ("var o = {a: 1, 'b': 2, 3: 'c', [1 + 1]: 'd'}; o.a + o.b + o[3] + o[2]", "3cd"),
    ("var o = {}; o.x = 1; o['y'] = 2; Object.keys(o).length", "2"),
    ("function Animal(n) { this.name = n } Animal.prototype.speak = function () { return this.name + ' speaks' }; new Animal('Rex').speak()", "Rex speaks"),
    ("function A() {} var a = new A(); a instanceof A && a.constructor === A", "true"),
    ("var p = {greet() { return 'hi ' + this.n }}; var o = Object.create(p); o.n = 'bob'; o.greet()", "hi bob"),
    ("var o = { get x() { return this._x * 2 }, set x(v) { this._x = v } }; o.x = 5; o.x", "10"),
    ("var o = {}; Object.defineProperty(o, 'ro', {value: 1, writable: false}); o.ro = 2; o.ro", "1"),
    ("'use strict'; var o = {}; Object.defineProperty(o, 'ro', {value: 1}); o.ro = 2", "Uncaught TypeError: Cannot assign to read only property 'ro' of [object Object]"),
    ("var o = {}; Object.defineProperty(o, 'g', {get: function () { return 'got' }}); o.g", "got"),
    ("var o = Object.defineProperty({}, 'h', {value: 1, enumerable: false}); var s = ''; for (var k in o) s += k; s + Object.keys(o).length", "0"),
    ("var proto = { set v(x) { this.seen = x } }; var o = Object.create(proto); o.v = 3; o.seen + ',' + o.hasOwnProperty('v')", "3,false"),
    ("var o = {a: 1}; delete o.a; 'a' in o", "false"),
    ("'use strict'; delete Object.prototype", "Uncaught TypeError: Cannot delete property 'prototype' of function Object"),
    ("var o = {__proto__: {inh: 5}}; o.inh", "5"),
    ("var o = {a: 1, ...{b: 2, c: 3}}; o.a + o.b + o.c", "6"),
    ("var o = {toString() { return 'S' }}; '' + o + `${o}`", "SS"),
    ("var o = {valueOf() { return 2 }}; o * 3", "6"),
    ("var o = {[Symbol.toPrimitive](h) { return h }}; `${o}` + (o + '')", "stringdefault"),
    ("(5).toString() + (255).toString(16) + true.toString()", "5fftrue"),
    ("var a = [1, 2, 3]; a.length = 1; a.length + ',' + a[1]", "1,undefined"),
    ("var a = []; a[5] = 1; a.length", "6"),
    ("var a = [1, , 3]; (1 in a) + ',' + a.length", "false,3"),
    ("[1, 2, ...[3, 4], ...'ab'].length", "6"),
    ("function f(a, b, c) { return a + b + c } f(...[1, 2, 3])", "6"),
    ("function f() { return arguments.length } f(...[1, 2], 3, ...[])", "3"),
    ("Math", "[object Math]"),
    // Destructuring.
    ("var {a, b: [c, d = 4], ...rest} = {a: 1, b: [3], x: 9, y: 8}; a + c + d + rest.x + rest.y", "25"),
    ("var [x, , y = 10, ...z] = [1, 2, undefined, 4, 5]; x + y + z.length", "13"),
    ("var a, b; [a, b] = [b, a] = [1, 2]; a + ',' + b", "1,2"),
    ("var o = {}; ({x: o.p, y: o['q']} = {x: 1, y: 2}); o.p + o.q", "3"),
    ("function f({a = 5, b} = {}) { return a + (b || 0) } f() + f({a: 1, b: 2})", "8"),
    ("var {length} = 'hello'; length", "5"),
    ("var {x} = null", "Uncaught TypeError: Cannot destructure 'null' as it is null."),
    // Classes.
    ("class A { constructor(x) { this.x = x } get double() { return this.x * 2 } static make() { return new A(3) } } A.make().double", "6"),
    ("class A { m() { return 'A' } } class B extends A { m() { return super.m() + 'B' } } new B().m()", "AB"),
    ("class A { constructor(v) { this.v = v } } class B extends A { constructor() { super(7); this.w = 1 } } var b = new B(); b.v + b.w + ',' + (b instanceof A)", "8,true"),
    ("class A { constructor() { this.a = 1 } } class B extends A {} new B().a", "1"),
    ("class A { x = 1; y = this.x + 1; static s = 'st' } new A().y + A.s", "2st"),
    ("class A { static #p = 1; static p() { return A.#p } } A.p()", "1"),
    ("class A {} A()", "Uncaught TypeError: Class constructor A cannot be invoked without 'new'"),
    ("class B extends Object { constructor() { this.x = 1 } } new B()", "Uncaught ReferenceError: Cannot access 'this' before initialization"),
    ("class A { static { this.init = 'ok' } } A.init", "ok"),
    ("class A { toString() { return 'a!' } } '' + new A()", "a!"),
    ("var C = class Named { who() { return Named.name } }; new C().who()", "Named"),
    ("class A {} typeof A + ',' + Object.getPrototypeOf(A.prototype === undefined ? 1 : A.prototype) === Object.prototype", "false"),
    ("class A { get [`k${1}`]() { return 'computed' } } new A().k1", "computed"),
    ("class P { constructor() { this.t = new.target === Q } } class Q extends P {} new Q().t", "true"),
    ("var o = { m() { return super.toString === Object.prototype.toString } }; o.m()", "true"),
    // Functions.
    ("function f(a, b) { return this.v + a + b } f.call({v: 1}, 2, 3) + f.apply({v: 10}, [20, 30])", "66"),
    ("function f(a, b) { return this.v + a + b } var g = f.bind({v: 1}, 2); g(3) + ',' + g.name + ',' + g.length", "6,bound f,1"),
    ("function F(a) { this.a = a } var B = F.bind(null, 4); var o = new B(); o.a + ',' + (o instanceof F)", "4,true"),
    ("(function (a, b = 2, c) {}).length", "1"),
    ("new Function('a', 'b', 'return a * b')(6, 7)", "42"),
    ("(function foo() {}).toString()", "function foo() {}"),
    ("function* g() {} String(g())", "[object Generator]"),
    ("async function g() {} typeof g", "function"),
    ("/x/", "/x/"),
    ("10n", "Uncaught SyntaxError: not supported yet: BigInt"),
    ("var o = {f() { return 1 }}; o?.f() + (o.g?.() === undefined) + (null?.x === undefined)", "3"),
    ("var o = null; o?.a.b.c", "undefined"),
    ("var tag = (s, ...v) => s.raw[0] + s[1] + v[0]; tag`a\\n${5}b`", "a\\nb5"),
    ("function t(s) { return s } t`x` === t`x`", "false"),
    ("var f = s => s; var k = () => f`q`; k() === k()", "true"),
    // eval and with.
    ("eval('1 + 1')", "2"),
    ("var x = 1; function f() { var x = 2; return eval('x') } f()", "2"),
    ("function f() { eval('var y = 3'); return y } f()", "3"),
    ("function f() { 'use strict'; eval('var y = 3'); return typeof y } f()", "undefined"),
    ("var geval = eval; function f() { var x = 'local'; return geval('typeof x') } f()", "undefined"),
    ("function f(a) { return eval('a + arguments.length') } f(5, 6)", "7"),
    ("var o = {f() { return eval('this') }}; o.f() === o", "true"),
    ("eval('function evf() { return 9 }'); evf()", "9"),
    ("eval('let q = 1'); typeof q", "undefined"),
    ("eval('(')", "Uncaught SyntaxError: unexpected end of input"),
    ("var o = {a: 1}; with (o) { a = 2; var b = a } o.a + b", "4"),
    ("function f() { var x = 'outer'; with ({x: 'with'}) { return x } } f()", "with"),
    ("function f() { var x = 'outer'; with ({}) { return x } } f()", "outer"),
    ("var o = {m() { return this === o }}; with (o) { m() }", "true"),
    // Globals and lexical scope across scripts (single script here).
    ("let ga = 1; var gb = 2; this.ga === undefined && this.gb === 2", "true"),
    ("var u = undefined; u === void 0", "true"),
    ("globalThis.NaN !== globalThis.NaN", "true"),
    ("Symbol.iterator.toString()", "Symbol(Symbol.iterator)"),
    ("var s = Symbol('d'); var o = {[s]: 1}; o[s]", "1"),
    ("Number('12') + Boolean('') + String(5)", "125"),
    ("new Number(5) + 1", "6"),
    ("Array(3).length + Array(1, 2).length", "5"),
    ("var a = [1]; a.push(2, 3); a.length + a[2]", "6"),
    ("Array.isArray([]) && !Array.isArray({})", "true"),
    // More control flow through finally and iterators.
    ("function f() { for (const x of [1, 2, 3]) { try { if (x == 2) return x * 10 } finally { s += x } } } var s = ''; f() + s", "2012"),
    ("var s = ''; a: for (const x of [1, 2]) { for (const y of [3, 4]) { s += x + '' + y; continue a } } s", "1323"),
    ("function f() { try { throw 1 } catch (e) { return 'c' } finally { s = 'f' } } var s; f() + s", "cf"),
    ("var s = ''; try { for (var i = 0; i < 3; i++) { try { throw i } catch (e) { s += e; if (e == 1) break } } } finally { s += 'F' } s", "01F"),
    ("var r = ''; for (let i = 0; i < 3; i++) { switch (i) { case 1: continue; default: r += i } } r", "02"),
    ("function d(n) { return n ? d.call(null, n - 1) + 1 : 0 } d(5000)", "5000"),
    ("function d(n) { return n ? d.apply(null, [n - 1]) + 1 : 0 } d(3000)", "3000"),
    ("var o = { get g() { throw new Error('getter') } }; try { o.g } catch (e) { e.message }", "getter"),
    ("var log = ''; var o = { set s(v) { log += v } }; o.s = 1; (o.s = 2) + log", "212"),
    ("var o = {b: 1, a: 2, 1: 'x', 0: 'y'}; var s = ''; for (var k in o) s += k; s", "01ba"),
    ("class A { static who() { return 'A' } } class B extends A { static who() { return super.who() + 'B' } } B.who()", "AB"),
    ("class A { get v() { return 1 } } class B extends A { get v() { return super.v + 1 } } new B().v", "2"),
    ("class A { constructor() { return {custom: 1} } } new A().custom", "1"),
    ("class A {} class B extends A { constructor() { return {o: 2} } } new B().o", "2"),
    ("class B extends null {} typeof B", "function"),
    ("class B extends 5 {}", "Uncaught TypeError: Class extends value 5 is not a constructor or null"),
    ("function F() { this.t = new.target === F; return 1 } new F().t + ',' + F()", "true,1"),
    ("var x = 'g'; (function () { var x = 'l'; return [1].map ? 0 : typeof x })()", "0"),
    ("var a = [3, 4]; var [p, q] = a; var {0: z} = a; p + q + z", "10"),
    ("var o = {a: {b: {c: 5}}}; var {a: {b: {c}}} = o; c", "5"),
    ("function f([a, b] = [1, 2], {c} = {c: 3}) { return a + b + c } f()", "6"),
    ("var it = 0; var obj = { [Symbol.iterator]() { return { next() { it++; return {done: it > 2, value: it} } } } }; var [a, b, c] = obj; a + ',' + b + ',' + c", "1,2,undefined"),
    ("var x = 10; { let x = 1; { let x = 2; } x }", "1"),
    ("let f = () => { let v = 1; return () => v++ }; var g = f(); g(); g()", "2"),
    ("var o = {n: 0, inc() { this.n++; return this }}; o.inc().inc().inc().n", "3"),
    ("var a = []; a[2] = 'c'; a[0] = 'a'; a.length + a[0] + a[1] + a[2]", "3aundefinedc"),
    ("var s = 0; for (var i = 0, j = 10; i < j; i++, j--) s++; s", "5"),
    ("var n = 0; for (;;) { if (++n > 4) break } n", "5"),
    ("'abc'.foo", "undefined"),
    ("(1).foo = 2", "2"),
    ("'use strict'; (1).foo = 2", "Uncaught TypeError: Cannot assign to read only property 'foo' of 1"),
    ("undefined.foo", "Uncaught TypeError: Cannot read properties of undefined (reading 'foo')"),
    ("var a = [1, 2, 3]; a.length = 'x'", "Uncaught RangeError: Invalid array length"),
    ("var a = [1, 2, 3]; a.length = '2'; a.length", "2"),
    ("Object.prototype.toString.call(function () {}) + Object.prototype.toString.call(null)", "[object Function][object Null]"),
    ("var o = {}; o[Symbol.toStringTag] = 'Mine'; '' + o", "[object Mine]"),
    ("function f() { return typeof arguments } f()", "object"),
    ("function f() { var arguments = 3; return arguments } f()", "3"),
    ("function f() { var arguments; return typeof arguments } f()", "object"),
    ("var s = ''; for (var v of (function () { return arguments })(1, 2)) s += v; s", "12"),
    ("var v = [...new Array(2)]; v.length + String(v[0])", "2undefined"),
    ("var x = 1; var r = delete x; r + ',' + typeof x", "false,number"),
    ("globalThis.y = 1; delete y", "true"),
    ("(function () { 'use strict'; return typeof this })()", "undefined"),
    ("(function () { return typeof this }).call(5)", "object"),
    ("(function () { 'use strict'; return typeof this }).call(5)", "number"),
    // Recursion.
    ("function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2) } fib(20)", "6765"),
    ("function d(n) { return n == 0 ? 0 : 1 + d(n - 1) } d(5000)", "5000"),
    ("function inf() { return inf() } inf()", "Uncaught RangeError: Maximum call stack size exceeded"),
    ("function inf() { return inf() } try { inf() } catch (e) { e instanceof RangeError }", "true"),
    ("var o = {get x() { return this.x }}; o.x", "Uncaught RangeError: Maximum call stack size exceeded"),
    ("function f() { return f.call(null) } f()", "Uncaught RangeError: Maximum call stack size exceeded"),
    ("var o = {}; o.toString = function () { return '' + o }; '' + o", "Uncaught RangeError: Maximum call stack size exceeded"),
]

/// Substring test (Embedded String has no contains(String)).
func jsHas(_ s: String, _ sub: String) -> Bool {
    let a = Array(s.utf8), b = Array(sub.utf8)
    if b.isEmpty { return true }
    if b.count > a.count { return false }
    for i in 0...(a.count - b.count) {
        var j = 0
        while j < b.count && a[i + j] == b[j] { j += 1 }
        if j == b.count { return true }
    }
    return false
}

func jsVMTests(_ t: Tests) {
    jsVMScriptTests(t, stress: false)
    jsVMEmbeddingTests(t)
    jsVMLimitTests(t)
    jsVMDeepTests(t)
    jsVMStressTests(t)
    jsVMFuzz(t)
    jsVMPerf(t)
}

func jsVMScriptTests(_ t: Tests, stress: Bool) {
    t.section(stress ? "vm scripts (gcEveryAllocation)" : "vm scripts")
    let rt = JSRuntime(limits: JSLimits())
    for (src, want) in jsVMCases {
        if stress && (jsHas(src, "fib(20)") || jsHas(src, "d(5000)") || jsHas(src, "inf()")
                      || jsHas(src, "this.x }") || jsHas(src, "f.call(null)") || jsHas(src, "'' + o }")) {
            continue
        }
        let realm = rt.makeRealm()
        realm.heap.gcEveryAllocation = stress
        t.equal(realm.evaluateToString(src), want, src)
    }
}

private func jsCheckStack(_ t: Tests) {
    let rt = JSRuntime()
    let realm = rt.makeRealm()
    let src = "function inner() {\n  throw new TypeError('boom')\n}\nfunction outer() { inner() }\nouter()"
    guard case .exception(let e) = realm.evaluate(source: src, name: "trace.js") else {
        t.check(false, "stack trace script throws")
        return
    }
    t.equal(e.message, "TypeError: boom", "uncaught message")
    t.check(e.stack.hasPrefix("TypeError: boom\n    at inner (trace.js:2:9)"), "stack: inner frame", e.stack)
    t.check(jsHas(e.stack, "at outer (trace.js:4:20)"), "stack: outer frame", e.stack)
    t.check(jsHas(e.stack, "at trace.js:5:1"), "stack: top level", e.stack)
    guard case .exception(let e2) = realm.evaluate(source: "function f() { throw 'str' }\nf()", name: "s.js") else {
        t.check(false, "non-error throw")
        return
    }
    t.equal(e2.message, "str", "non-error message")
    t.check(jsHas(e2.stack, "at f (s.js:1:16)") && jsHas(e2.stack, "at s.js:2:1"), "trace of a thrown string", e2.stack)
    guard case .exception(let e3) = realm.evaluate(source: "\n  let = ;", name: "syn.js") else {
        t.check(false, "syntax error")
        return
    }
    t.check(e3.message.hasPrefix("SyntaxError:") && jsHas(e3.stack, "syn.js:2:"), "syntax error location", e3.stack)
}

func jsVMEmbeddingTests(_ t: Tests) {
    t.section("vm embedding")
    jsCheckStack(t)
    let rt = JSRuntime()
    let realm = rt.makeRealm()
    // Natives.
    var calls = 0
    realm.defineMethod(realm.global, "twice", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        calls += 1
        let f = args[0]
        let a = try realm.call(f, this: .undefined, args: [.int32(1)])
        return try realm.call(f, this: .undefined, args: [a])
    }
    t.equal(realm.evaluateToString("twice(x => x * 10)"), "100", "native calls back into JS")
    t.equal(calls, 1, "native called once")
    realm.defineMethod(realm.global, "fail", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        throw realm.throwRangeError("from native")
    }
    t.equal(realm.evaluateToString("try { fail() } catch (e) { e.message }"), "from native", "native throws")
    t.equal(realm.evaluateToString("var n = 0; function rec() { n++; twice(rec) } try { rec() } catch (e) { e.constructor.name + n }"),
            "RangeError64", "native nesting cap")
    // Script state persists; lexical globals are shared between scripts.
    t.equal(realm.evaluateToString("let shared = 41; var gv = 1"), "undefined", "declare")
    t.equal(realm.evaluateToString("shared + gv"), "42", "second script sees let and var")
    t.equal(realm.evaluateToString("let shared = 1"), "Uncaught SyntaxError: Identifier 'shared' has already been declared", "redeclare let")
    t.equal(realm.evaluateToString("const k = 1; k"), "1", "const")
    t.equal(realm.evaluateToString("k = 2"), "Uncaught TypeError: Assignment to constant variable.", "global const")
    // print.
    _ = realm.evaluate(source: "print('a', 1, {}); print()")
    t.check(realm.output == ["a 1 [object Object]", ""], "print output", "\(realm.output)")
    var printed: [String] = []
    realm.printHandler = { printed.append($0) }
    _ = realm.evaluate(source: "print('via handler')")
    t.check(printed == ["via handler"], "print handler")
    // Calling JS from Swift.
    _ = realm.evaluate(source: "function add(a, b) { return a + b }")
    var gotAdd: JSValue = .undefined
    if case .normal(let f) = realm.evaluate(source: "add") { gotAdd = f }
    let r = realm.heap.root(gotAdd)
    do throws(JSThrow) {
        let v = try realm.call(gotAdd, this: .undefined, args: [.int32(2), .int32(3)])
        t.check(v == .int32(5), "realm.call from Swift")
    } catch { t.check(false, "realm.call threw") }
    realm.heap.popRoots(to: r.slot)
    // A disassembly mentions the opcodes.
    let ast = try? jsParse(Array("function f(a) { return a + 1 }".utf8))
    if let a = ast {
        let src = JSScriptSource(name: "d.js", source: a.source)
        do throws(JSCompileError) {
            let code = try JSCompiler.compileScript(a, realm: realm, source: src)
            let text = jsDisassemble(code, heap: realm.heap, codes: { realm.code(ofCodeObject: $0) })
            t.check(jsHas(text, "closure <code f>") && jsHas(text, "declareFunc f") && jsHas(text, "add"),
                    "disassembly", text)
        } catch { t.check(false, "compile for disassembly") }
    }
}

func jsVMLimitTests(_ t: Tests) {
    t.section("vm limits")
    // Interrupt: an infinite loop is terminated by the embedder's budget.
    let rt = JSRuntime(limits: JSLimits.small)
    var checks = 0
    rt.interruptHandler = { _ in checks += 1; return checks > 50 }
    let realm = rt.makeRealm()
    let c = realm.evaluate(source: "var n = 0; try { while (true) { n++ } } finally { n = -1 }")
    if case .terminated(let why) = c { t.check(why == .interrupted, "interrupt reason") } else { t.check(false, "loop terminated") }
    t.check(realm.evaluateToString("n") != "-1", "finally does not run on termination")
    checks = 0
    let c2 = realm.evaluate(source: "function r() { r2() } function r2() { for (;;) {} } try { r() } catch (e) { 'caught' }")
    if case .terminated = c2 { t.check(true, "termination is uncatchable") } else { t.check(false, "termination is uncatchable") }
    rt.interruptHandler = nil
    t.equal(realm.evaluateToString("1 + 1"), "2", "realm usable after termination")
    // Heap cap: allocation without end terminates, uncatchably.
    let rt2 = JSRuntime(limits: JSLimits.small)
    let r2 = rt2.makeRealm()
    let c3 = r2.evaluate(source: "var a = []; try { while (true) a.push({x: [1, 2, 3, 4]}) } catch (e) { 'caught' }")
    if case .terminated(let why) = c3 { t.check(why == .heapLimit, "heap cap reason") } else { t.check(false, "heap cap terminates") }
    _ = r2.evaluate(source: "a = null")
    r2.heap.collectGarbage()
    t.equal(r2.evaluateToString("var b = [1, 2]; b.length"), "2", "realm usable after heap cap")
    // String length limit is a RangeError.
    t.equal(r2.evaluateToString("var s = 'x'; try { while (true) s += s } catch (e) { e.name }"), "RangeError", "string length cap")
    // Call depth under small limits.
    t.equal(r2.evaluateToString("var d = 0; function f() { d++; f() } try { f() } catch (e) {} d"), "499", "maxCallDepth 500 (the script is a frame)")
}

// Deep nesting on a 512 KiB stack: never a crash.
var jsVMDeepResults: [String] = []

private func jsVMDeepBody() {
    let rt = JSRuntime()
    let realm = rt.makeRealm()
    var cases: [String] = []
    cases.append(String(repeating: "1 + ", count: 1990) + "1")
    cases.append("var a = {}; a.b = a; a" + String(repeating: ".b", count: 1990) + " === a")
    cases.append("var f = function () { return f }; f" + String(repeating: "()", count: 1990) + " === f")
    cases.append(String(repeating: "(", count: 300) + "1" + String(repeating: ")", count: 300))
    cases.append(String(repeating: "function f() {", count: 150) + String(repeating: "}", count: 150) + "1")
    cases.append(String(repeating: "if (1) ", count: 500) + "1")
    cases.append("var x = 0; " + String(repeating: "x = ", count: 300) + "1")
    cases.append(String(repeating: "[", count: 300) + String(repeating: "]", count: 300) + ".length")
    cases.append(String(repeating: "{", count: 400) + "2" + String(repeating: "}", count: 400))
    cases.append(String(repeating: "a => ", count: 200) + "1; 3")
    cases.append(String(repeating: "x ? 1 : ", count: 400) + "1; 4")
    for c in cases { jsVMDeepResults.append(realm.evaluateToString(c)) }
    // Native re-entry depth under the default limits: a RangeError.
    jsVMDeepResults.append(realm.evaluateToString("var o = {}; var n = 0; o.valueOf = function () { n++; return +o }; try { +o } catch (e) { e.name + (n <= 64) }"))
}

func jsVMDeepTests(_ t: Tests) {
    t.section("vm deep nesting")
    jsVMDeepResults = []
    let r = host_run_with_stack(512 << 10, { _ in jsVMDeepBody(); return nil }, nil)
    t.check(r == 0, "512 KB thread")
    let want = ["1991", "true", "true", "1", "1", "1", "1", "1", "2", "3", "4", "RangeErrortrue"]
    t.equal(jsVMDeepResults.count, want.count, "deep results")
    for (i, w) in want.enumerated() where i < jsVMDeepResults.count {
        let got = jsVMDeepResults[i]
        t.check(got == w || jsHas(got, "nesting too deep"), "deep case \(i)", got)
        if got != w { print("js vm: deep case \(i): \(got)") }
    }
}

func jsVMStressTests(_ t: Tests) {
    let start = hostMillis()
    jsVMScriptTests(t, stress: true)
    // A closure/object workload with a GC at every allocation.
    let rt = JSRuntime()
    let realm = rt.makeRealm()
    realm.heap.gcEveryAllocation = true
    let src = """
        function node(v, next) { return { v: v, next: next, get: () => v } }
        var list = null;
        for (let i = 0; i < 300; i++) list = node(i, list);
        var s = 0; for (var n = list; n; n = n.next) s += n.get();
        class P { constructor(x) { this.x = x } sum(o) { return this.x + o.x } }
        var acc = 0; for (let i = 0; i < 50; i++) acc += new P(i).sum(new P(1));
        var str = ''; for (var k in {a: 1, b: 2}) str += `${k}${[1, 2, ...'xy'].length}`;
        s + ',' + acc + ',' + str
        """
    t.equal(realm.evaluateToString(src), "44850,1275,a4b4", "workload under gcEveryAllocation")
    t.check(realm.heap.gcCount > 1000, "many collections", "\(realm.heap.gcCount)")
    print("js vm: gcEveryAllocation pass \(hostMillis() - start) ms")
}

func jsVMFuzz(_ t: Tests) {
    t.section("vm fuzz")
    var seeds: [[UInt8]] = []
    for (src, _) in jsVMCases where !jsHas(src, "inf()") && !jsHas(src, "d(5000)") { seeds.append(Array(src.utf8)) }
    let rt = JSRuntime(limits: JSLimits.small)
    var budget = 0
    rt.interruptHandler = { _ in budget += 1; return budget > 3 }
    let realm = rt.makeRealm()
    var n = 0
    t.fuzz("vm", seeds: seeds, iterations: 20000) { m in
        budget = 0
        n += 1
        if n % 500 == 0 { _ = rt; realm.heap.collectGarbage() }
        _ = realm.evaluate(source: m, name: "fuzz.js")
    }
    let fresh = rt.makeRealm()
    t.equal(fresh.evaluateToString("1 + 1"), "2", "after fuzz")
}

func jsVMPerf(_ t: Tests) {
    t.section("vm perf")
    let rt = JSRuntime()
    func run(_ name: String, _ src: String, _ want: String) {
        let realm = rt.makeRealm()
        let start = hostMillis()
        let got = realm.evaluateToString(src)
        let ms = hostMillis() - start
        t.equal(got, want, name)
        print("js vm perf: \(name) \(ms) ms")
    }
    run("fib(25)", "function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2) } fib(25)", "75025")
    run("closure calls 1M", "(function () { function mk() { var c = 0; return () => ++c } var f = mk(); for (var i = 0; i < 1000000; i++) f(); return f() })()", "1000001")
    run("property get/set 1M", "(function () { var o = {a: 1, b: 2}; var s = 0; for (var i = 0; i < 1000000; i++) { o.a = i; s += o.a + o.b } return s })()", "500001500000")
    run("property loop 1M, globals", "var o = {a: 1, b: 2}; var s = 0; for (var i = 0; i < 1000000; i++) { o.a = i; s += o.a + o.b } s", "500001500000")
    run("array index 1M", "(function () { var a = []; for (var i = 0; i < 1000; i++) a[i] = i; var s = 0; for (var j = 0; j < 1000; j++) for (var i = 0; i < 1000; i++) s += a[i]; return s })()", "499500000")
    run("method calls + new 300k", "(function () { class V { constructor(x) { this.x = x } add(o) { return new V(this.x + o.x) } } var v = new V(0), one = new V(1); for (var i = 0; i < 300000; i++) v = v.add(one); return v.x })()", "300000")
    run("string += 100k", "(function () { var s = ''; for (var i = 0; i < 100000; i++) s += 'x'; return s.length })()", "100000")
}
