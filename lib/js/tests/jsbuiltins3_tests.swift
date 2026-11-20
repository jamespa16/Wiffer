// Host tests for Phase 9E's runtime library: Proxy/Reflect (traps,
// invariants, revocation), Map/Set (order, SameValueZero, mutation during
// iteration), WeakMap/WeakSet/WeakRef/FinalizationRegistry (collection by
// the GC, ephemeron chains), ArrayBuffer/DataView/typed arrays
// (conversions, endianness, detach), the exotic-object host hook, a GC
// stress pass and a Proxy-heavy fuzz.

let jsBuiltins3Cases: [(String, String)] = [
    // ------------------------------------------------------------ Proxy
    ("var log = []; var p = new Proxy({a: 1}, { get(t, k, r) { log.push('get ' + String(k)); return Reflect.get(t, k, r) } }); p.a + ',' + log.join()", "1,get a"),
    ("var p = new Proxy({}, { has(t, k) { return k === 'x' } }); ('x' in p) + ',' + ('y' in p)", "true,false"),
    ("var p = new Proxy({}, { set(t, k, v) { t[k] = v * 2; return true } }); p.a = 5; p.a", "10"),
    ("var p = new Proxy({a: 1}, { deleteProperty(t, k) { return false } }); delete p.a", "false"),
    ("'use strict'; var p = new Proxy({a: 1}, { deleteProperty(t, k) { return false } }); try { delete p.a } catch (e) { e.name }", "TypeError"),
    ("var p = new Proxy({}, { ownKeys() { return ['b', 'a', Symbol.iterator] } }); Reflect.ownKeys(p).length + ',' + Object.keys(p).length", "3,0"),
    ("var p = new Proxy({}, { ownKeys() { return ['b', 'a'] }, getOwnPropertyDescriptor(t, k) { return {value: k, enumerable: true, configurable: true} } }); Object.keys(p).join()", "b,a"),
    ("var p = new Proxy({}, { ownKeys() { return ['a', 'a'] } }); try { Reflect.ownKeys(p) } catch (e) { e.name }", "TypeError"),
    ("var t = {}; Object.defineProperty(t, 'x', {value: 1}); var p = new Proxy(t, { ownKeys() { return [] } }); try { Reflect.ownKeys(p) } catch (e) { e.name }", "TypeError"),
    ("var t = {}; Object.defineProperty(t, 'x', {value: 1}); var p = new Proxy(t, { get() { return 2 } }); try { p.x } catch (e) { e.name }", "TypeError"),
    ("var t = {}; Object.defineProperty(t, 'x', {value: 1}); var p = new Proxy(t, { get() { return 1 } }); p.x", "1"),
    ("var t = {}; Object.defineProperty(t, 'x', {value: 1}); var p = new Proxy(t, { has() { return false } }); try { 'x' in p } catch (e) { e.name }", "TypeError"),
    ("var t = {}; Object.defineProperty(t, 'x', {value: 1}); var p = new Proxy(t, { set() { return true } }); try { Reflect.set(p, 'x', 2) } catch (e) { e.name }", "TypeError"),
    ("var t = {}; Object.defineProperty(t, 'x', {value: 1}); var p = new Proxy(t, { deleteProperty() { return true } }); try { delete p.x } catch (e) { e.name }", "TypeError"),
    ("var t = {}; Object.preventExtensions(t); var p = new Proxy(t, { isExtensible() { return true } }); try { Reflect.isExtensible(p) } catch (e) { e.name }", "TypeError"),
    ("var p = new Proxy({}, { preventExtensions() { return true } }); try { Reflect.preventExtensions(p) } catch (e) { e.name }", "TypeError"),
    ("var t = {}; Object.preventExtensions(t); var p = new Proxy(t, { getPrototypeOf() { return Array.prototype } }); try { Object.getPrototypeOf(p) } catch (e) { e.name }", "TypeError"),
    ("var p = new Proxy({}, { getPrototypeOf() { return Array.prototype } }); (Object.getPrototypeOf(p) === Array.prototype) + ',' + (p instanceof Array)", "true,true"),
    ("var p = new Proxy({}, { getPrototypeOf() { return 1 } }); try { Reflect.getPrototypeOf(p) } catch (e) { e.name }", "TypeError"),
    ("var p = new Proxy({}, { setPrototypeOf() { return false } }); Reflect.setPrototypeOf(p, null)", "false"),
    ("var p = new Proxy({}, { defineProperty(t, k, d) { return true } }); try { Reflect.defineProperty(p, 'x', {value: 1, configurable: false}) } catch (e) { e.name }", "TypeError"),
    ("var p = new Proxy({}, { defineProperty(t, k, d) { t[k] = d.value + 1; return true } }); Reflect.defineProperty(p, 'x', {value: 1, writable: true, enumerable: true, configurable: true}) + ',' + p.x", "true,2"),
    ("var p = new Proxy({}, { getOwnPropertyDescriptor() { return {value: 1, configurable: false} } }); try { Reflect.getOwnPropertyDescriptor(p, 'x') } catch (e) { e.name }", "TypeError"),
    ("var p = new Proxy({x: 1}, { getOwnPropertyDescriptor(t, k) { return Reflect.getOwnPropertyDescriptor(t, k) } }); var d = Reflect.getOwnPropertyDescriptor(p, 'x'); d.value + ',' + d.writable + d.enumerable + d.configurable", "1,truetruetrue"),
    ("var p = new Proxy(function (a, b) { return a + b }, { apply(t, th, args) { return t(...args) * 10 } }); p(1, 2) + ',' + typeof p", "30,function"),
    ("var p = new Proxy(function () {}, { construct(t, args, nt) { return {n: args.length, same: nt === p} } }); var o = new p(1, 2, 3); o.n + ',' + o.same", "3,true"),
    ("var p = new Proxy(function () {}, { construct() { return 1 } }); try { new p() } catch (e) { e.name }", "TypeError"),
    ("var p = new Proxy({}, {}); try { p() } catch (e) { e.name }", "TypeError"),
    ("class A { constructor(x) { this.x = x } } var P = new Proxy(A, {}); new P(4).x + ',' + (new P(1) instanceof A)", "4,true"),
    ("var r = Proxy.revocable({a: 1}, {}); var before = r.proxy.a; r.revoke(); r.revoke(); try { r.proxy.a } catch (e) { before + e.name }", "1TypeError"),
    ("var r = Proxy.revocable({}, {}); r.revoke(); try { 'a' in r.proxy } catch (e) { e.name }", "TypeError"),
    ("try { Proxy({}, {}) } catch (e) { e.name }", "TypeError"),
    ("try { new Proxy(1, {}) } catch (e) { e.name }", "TypeError"),
    ("Proxy.length + ',' + Proxy.name + ',' + ('prototype' in Proxy)", "2,Proxy,false"),
    ("var p = new Proxy([1, 2, 3], {}); Array.isArray(p) + ',' + p.length + ',' + p[1]", "true,3,2"),
    ("var p = new Proxy({}, { get(t, k) { return k === 'then' ? undefined : 'v_' + String(k) } }); p.foo + p[1]", "v_foov_1"),
    ("var o = Object.create(new Proxy({}, { get(t, k, r) { return r === o ? 'recv' : 'other' } })); o.zz", "recv"),
    ("var log = []; var o = Object.create(new Proxy({}, { set(t, k, v, r) { log.push(k); return Reflect.set(t, k, v, r) } })); o.q = 1; log.join() + ',' + o.hasOwnProperty('q')", "q,true"),
    ("var log = []; var p = new Proxy({a: 1, b: 2}, { ownKeys(t) { log.push('ownKeys'); return Reflect.ownKeys(t) }, getOwnPropertyDescriptor(t, k) { log.push('gopd ' + k); return Reflect.getOwnPropertyDescriptor(t, k) } }); var s = ''; for (var k in p) s += k; s + ':' + log.join()", "ab:ownKeys,gopd a,gopd b"),
    ("var p = new Proxy({a: 1, b: 2}, {}); var o = {...p}; o.a + o.b", "3"),
    ("var p = new Proxy({}, { has(t, k) { return true }, get(t, k) { return k === Symbol.unscopables ? undefined : 7 } }); with (p) { zzz }", "7"),
    ("var p = new Proxy({}, {}); var q = new Proxy(p, {}); q.x = 3; p.x + ',' + q.x", "3,3"),
    ("var t = []; var p = new Proxy(t, {}); p.push(1, 2); t.length + ',' + p.length", "2,2"),
    ("var p = new Proxy({}, { get: 1 }); try { p.x } catch (e) { e.name }", "TypeError"),
    ("var h = {}; var p = new Proxy({x: 1}, h); var a = p.x; h.get = function () { return 2 }; a + ',' + p.x", "1,2"),
    ("var p = new Proxy({}, { getOwnPropertyDescriptor() { return undefined } }); Object.prototype.hasOwnProperty.call(p, 'x')", "false"),
    ("var deep = {v: 1}; for (var i = 0; i < 100; i++) deep = new Proxy(deep, {}); deep.v", "1"),
    ("var deep = {v: 1}; for (var i = 0; i < 5000; i++) deep = new Proxy(deep, {}); try { deep.v } catch (e) { e.name }", "RangeError"),
    ("var p = new Proxy({}, { get(t, k, r) { return r[k] } }); try { p.x } catch (e) { e.name }", "RangeError"),
    // ---------------------------------------------------------- Reflect
    ("Reflect.ownKeys({b: 1, 2: 1, a: 1, 1: 1, [Symbol.iterator]: 1}).map(String).join()", "1,2,b,a,Symbol(Symbol.iterator)"),
    ("Reflect.apply(function (a, b) { return a > b ? a : b }, null, [3, 9])", "9"),
    ("class B { constructor() { this.nt = new.target } } class C {} var o = Reflect.construct(B, [], C); (o instanceof C) + ',' + (o.nt === C)", "true,true"),
    ("try { Reflect.construct(function () {}, [], {}) } catch (e) { e.name }", "TypeError"),
    ("var o = {}; Reflect.defineProperty(o, 'x', {value: 1}) + ',' + Reflect.defineProperty(o, 'x', {value: 2})", "true,false"),
    ("var o = {get g() { return this.v }}; Reflect.get(o, 'g', {v: 42})", "42"),
    ("var o = {set s(v) { this.v = v }}; var r = {}; Reflect.set(o, 's', 5, r); r.v + ',' + o.v", "5,undefined"),
    ("var o = Object.freeze({a: 1}); Reflect.set(o, 'a', 2) + ',' + Reflect.deleteProperty(o, 'a') + ',' + Reflect.isExtensible(o)", "false,false,false"),
    ("Reflect.has({a: 1}, 'a') + ',' + Reflect.has(Object.create({b: 1}), 'b') + ',' + Reflect.getPrototypeOf([]) === Array.prototype", "false"),
    ("try { Reflect.get(1, 'a') } catch (e) { e.name }", "TypeError"),
    ("Object.prototype.toString.call(Reflect)", "[object Reflect]"),
    ("var r = {}; Reflect.set({}, 'x', 1, r); Reflect.getOwnPropertyDescriptor(r, 'x').enumerable", "true"),
    ("var t = {}; var res = Reflect.setPrototypeOf(t, t); res", "false"),
    // -------------------------------------------------------------- Map
    ("var m = new Map([[1, 'a'], ['1', 'b'], [NaN, 'n'], [-0, 'z']]); [m.get(1), m.get('1'), m.get(NaN), m.get(0), m.size].join()", "a,b,n,z,4"),
    ("var m = new Map(); m.set('k', 1).set('k', 2); m.size + ',' + m.get('k')", "1,2"),
    ("var m = new Map(); var s = 'a' + 'b'; m.set(s, 1); m.get('ab') + ',' + m.has('a' + 'b')", "1,true"),
    ("var m = new Map([[3, 0], [1, 0], [2, 0]]); [...m.keys()].join()", "3,1,2"),
    ("var m = new Map([[1, 1], [2, 2], [3, 3]]); var out = []; for (var [k] of m) { out.push(k); if (k === 1) { m.delete(2); m.set(4, 4) } } out.join()", "1,3,4"),
    ("var m = new Map([[1, 1], [2, 2]]); var out = []; for (var [k] of m) { out.push(k); if (k === 1) { m.clear(); m.set(9, 9) } } out.join()", "1,9"),
    ("var m = new Map(); for (var i = 0; i < 1000; i++) m.set(i, i); var it = m.keys(); it.next(); for (var i = 0; i < 990; i++) m.delete(i); var r = []; for (var x of it) r.push(x); r.join()", "990,991,992,993,994,995,996,997,998,999"),
    ("var m = new Map(); for (var i = 0; i < 20000; i++) { m.set('k' + i, i); if (i >= 10) m.delete('k' + (i - 10)) } m.size + ',' + m.get('k19999') + ',' + m.has('k5')", "10,19999,false"),
    ("var m = new Map([[1, 'a']]); var e = m.entries().next().value; e[0] + e[1] + ',' + Object.prototype.toString.call(m.entries())", "1a,[object Map Iterator]"),
    ("var s = ''; new Map([[1, 'x'], [2, 'y']]).forEach(function (v, k, mm) { s += k + v + (mm instanceof Map) }); s", "1xtrue2ytrue"),
    ("try { Map() } catch (e) { e.name }", "TypeError"),
    ("try { Map.prototype.get.call({}, 1) } catch (e) { e.name }", "TypeError"),
    ("try { new Map([1]) } catch (e) { e.name }", "TypeError"),
    ("var g = Map.groupBy([1, 2, 3, 4, 5], x => x % 2 ? 'odd' : 'even'); g.get('odd').join() + ';' + g.get('even').join()", "1,3,5;2,4"),
    ("Map[Symbol.species] === Map", "true"),
    ("var o = {}; var m = new Map([[o, 1]]); m.get(o) + ',' + m.get({})", "1,undefined"),
    ("class MyMap extends Map { constructor(x) { super(x); this.extra = 1 } } var mm = new MyMap([[1, 2]]); mm.get(1) + mm.extra + ',' + (mm instanceof Map)", "3,true"),
    // -------------------------------------------------------------- Set
    ("var s = new Set([1, 2, 2, '2', NaN, NaN, -0, 0]); s.size + ',' + [...s].map(String).join()", "5,1,2,2,NaN,0"),
    ("var s = new Set('hello'); [...s].join('')", "helo"),
    ("var s = new Set([1, 2, 3]); var out = []; var once = true; s.forEach(v => { out.push(v); if (v === 1 && once) { once = false; s.delete(1); s.add(1) } }); out.join()", "1,2,3,1"),
    ("var s = new Set([1]); (s.keys === s.values) + ',' + (s[Symbol.iterator] === s.values) + ',' + [...s.entries()][0].join()", "true,true,1,1"),
    ("[...new Set([1, 2, 3]).union(new Set([3, 4]))].join()", "1,2,3,4"),
    ("[...new Set([1, 2, 3]).intersection(new Set([3, 2, 9]))].join()", "2,3"),
    ("[...new Set([1, 2, 3]).difference(new Set([2]))].join()", "1,3"),
    ("[...new Set([1, 2]).symmetricDifference(new Set([2, 3]))].join()", "1,3"),
    ("new Set([1]).isSubsetOf(new Set([1, 2])) + ',' + new Set([1, 2]).isSupersetOf(new Set([2])) + ',' + new Set([1]).isDisjointFrom(new Set([2]))", "true,true,true"),
    ("try { new Set([1]).union({size: NaN, has() {}, keys() {}}) } catch (e) { e.name }", "TypeError"),
    ("[...new Set([1, 2]).union(new Map([[3, 'x']]))].join()", "1,2,3"),
    ("Object.prototype.toString.call(new Set()) + Object.prototype.toString.call(new Set().values())", "[object Set][object Set Iterator]"),
    // ---------------------------------------------- WeakMap / WeakSet / refs
    ("var k = {}; var w = new WeakMap([[k, 1]]); w.get(k) + ',' + w.has({}) + ',' + w.delete(k) + ',' + w.has(k)", "1,false,true,false"),
    ("try { new WeakMap().set(1, 1) } catch (e) { e.name }", "TypeError"),
    ("try { new WeakSet().add(Symbol.for('reg')) } catch (e) { e.name }", "TypeError"),
    ("var s = Symbol('x'); var w = new WeakMap(); w.set(s, 5); w.get(s)", "5"),
    ("var o = {}; var ws = new WeakSet([o]); ws.has(o) + ',' + ws.has({})", "true,false"),
    ("var o = {}; var r = new WeakRef(o); r.deref() === o", "true"),
    ("try { new WeakRef(1) } catch (e) { e.name }", "TypeError"),
    ("var fr = new FinalizationRegistry(() => {}); var t = {}; fr.register(t, 1, t); fr.unregister(t) + ',' + fr.unregister(t)", "true,false"),
    ("try { var fr = new FinalizationRegistry(() => {}); var t = {}; fr.register(t, t) } catch (e) { e.name }", "TypeError"),
    ("Object.prototype.toString.call(new WeakMap()) + Object.prototype.toString.call(new WeakRef({}))", "[object WeakMap][object WeakRef]"),
    // ------------------------------------------------------ typed arrays
    ("var a = new Uint8Array([1, 256, -1, 1.7, NaN]); a.join()", "1,0,255,1,0"),
    ("var a = new Uint8ClampedArray([1.5, 2.5, -3, 300, 0.5000001, NaN, 254.5, 253.5]); a.join()", "2,2,0,255,1,0,254,254"),
    ("var a = new Int8Array([127, 128, -129, 255]); a.join()", "127,-128,127,-1"),
    ("new Int16Array([32768, -32769, 65535]).join() + ';' + new Uint16Array([-1, 65536]).join()", "-32768,32767,-1;65535,0"),
    ("new Int32Array([2147483648, -2147483649, 4294967296.5]).join() + ';' + new Uint32Array([-1, 4294967296]).join()", "-2147483648,2147483647,0;4294967295,0"),
    ("var f = new Float32Array([0.1, 1e40, -1e-50, NaN]); f[0] + ',' + f[1] + ',' + Object.is(f[2], -0) + ',' + f[3]", "0.10000000149011612,Infinity,true,NaN"),
    ("var f = new Float64Array([0.1, -0]); f[0] + ',' + Object.is(f[1], -0)", "0.1,true"),
    ("var h = new Float16Array([1, 65504, 65520, 0.1, 5.960464477539063e-8, 1e-8, -2.5]); Array.from(h).join()", "1,65504,Infinity,0.0999755859375,5.960464477539063e-8,0,-2.5"),
    ("var a = new Uint8Array(4); a[0] = '5'; a[1] = {valueOf() { return 7 }}; a[2] = true; a.join()", "5,7,1,0"),
    ("var a = new Uint8Array(2); a[5] = 1; a['-0'] = 1; a[1.5] = 1; a.foo = 1; Object.keys(a).join() + ',' + a[5] + ',' + a['-0'] + ',' + ('1.5' in a) + ',' + a.foo", "0,1,foo,undefined,undefined,false,1"),
    ("var a = new Uint8Array(2); Object.getPrototypeOf(a).__x = 1; Uint8Array.prototype[7] = 'p'; a[7] + ',' + ('7' in a)", "undefined,false"),
    ("var a = new Int8Array(3); Reflect.defineProperty(a, 0, {value: 5}) + ',' + Reflect.defineProperty(a, 1, {value: 5, configurable: false}) + ',' + Reflect.defineProperty(a, 9, {value: 1}) + ',' + a[0]", "true,false,false,5"),
    ("var a = new Int8Array([1]); delete a[0]", "false"),
    ("var a = new Int8Array([1]); delete a[1]", "true"),
    ("var d = Object.getOwnPropertyDescriptor(new Uint8Array([9]), 0); d.value + ',' + d.writable + d.enumerable + d.configurable", "9,truetruetrue"),
    ("var b = new ArrayBuffer(8); var u = new Uint32Array(b); u[0] = 0x01020304; var v = new Uint8Array(b); v.join()", "4,3,2,1,0,0,0,0"),
    ("var b = new ArrayBuffer(8); var v = new Uint8Array(b, 2, 3); v.length + ',' + v.byteOffset + ',' + v.byteLength", "3,2,3"),
    ("try { new Uint16Array(new ArrayBuffer(4), 1) } catch (e) { e.name }", "RangeError"),
    ("try { new Uint16Array(new ArrayBuffer(3)) } catch (e) { e.name }", "RangeError"),
    ("try { new Uint8Array(new ArrayBuffer(4), 2, 3) } catch (e) { e.name }", "RangeError"),
    ("try { new Uint8Array(-1) } catch (e) { e.name }", "RangeError"),
    ("try { Uint8Array(1) } catch (e) { e.name }", "TypeError"),
    ("var TA = Object.getPrototypeOf(Int8Array); try { new TA() } catch (e) { e.name + ',' + TA.name + ',' + (Object.getPrototypeOf(Int8Array.prototype) === TA.prototype) }", "TypeError,TypedArray,true"),
    ("Uint8Array.BYTES_PER_ELEMENT + Float64Array.prototype.BYTES_PER_ELEMENT + ',' + Int16Array.length + ',' + Int16Array.name", "9,3,Int16Array"),
    ("var a = new Uint8Array([3, 1, 2]); var b = new Float64Array(a); b[0] = 0.5; a.join() + ';' + b.join()", "3,1,2;0.5,1,2"),
    ("new Uint8Array(new Set([5, 6])).join() + ';' + new Int8Array({length: 2, 0: 1, 1: 2}).join()", "5,6;1,2"),
    ("Uint8Array.from([1, 2, 3], x => x * 2).join() + ';' + Int8Array.of(1, -1, 300).join()", "2,4,6;1,-1,44"),
    ("var a = new Int8Array([5, 1, 4]); a.sort().join() + ';' + new Float64Array([3, NaN, -0, 0, -1]).sort().join() + ';' + new Int8Array([1, 2, 3]).sort((x, y) => y - x).join()", "1,4,5;-1,0,0,3,NaN;3,2,1"),
    ("var a = new Uint8Array([1, 2, 3, 4, 5]); a.subarray(1, 3).join() + ';' + a.slice(-2).join() + ';' + a.subarray(2).byteOffset", "2,3;4,5;2"),
    ("var a = new Uint8Array([1, 2, 3, 4, 5]); var s = a.subarray(1, 3); s[0] = 9; a.join()", "1,9,3,4,5"),
    ("var a = new Uint8Array([1, 2, 3, 4, 5]); a.copyWithin(0, 3).join() + ';' + new Uint8Array([1, 2, 3, 4, 5]).copyWithin(2, 0).join()", "4,5,3,4,5;1,2,1,2,3"),
    ("var a = new Uint8Array(5); a.set([1, 2], 1); a.set(new Uint8Array([7]), 4); a.join()", "0,1,2,0,7"),
    ("var a = new Uint8Array(4); try { a.set([1, 2], 3) } catch (e) { e.name }", "RangeError"),
    ("var b = new Uint8Array([1, 2, 3, 4]); var ov = new Uint8Array(b.buffer, 1, 3); b.set(ov); b.join()", "2,3,4,4"),
    ("var a = new Int16Array([1, 2, 3]); a.map(x => x * 2).join() + ';' + a.filter(x => x & 1).join() + ';' + a.reduce((s, x) => s + x) + ';' + a.reduceRight((s, x) => s + '' + x, '')", "2,4,6;1,3;6;321"),
    ("var a = new Int16Array([1, 2, 3]); a.indexOf(2) + ',' + a.lastIndexOf(3) + ',' + a.includes(3) + ',' + a.find(x => x > 1) + ',' + a.findLastIndex(x => x < 3) + ',' + a.at(-1)", "1,2,true,2,1,3"),
    ("var a = new Float32Array([NaN]); a.includes(NaN) + ',' + a.indexOf(NaN)", "true,-1"),
    ("var a = new Uint8Array([1, 2, 3]); a.fill(7, 1).join() + ';' + a.reverse().join() + ';' + a.toReversed().join() + ';' + a.with(0, 9).join() + ';' + a.toSorted().join()", "1,7,7;7,7,1;1,7,7;9,7,1;1,7,7"),
    ("var a = new Uint8Array([1, 2]); [...a.keys()].join() + ';' + [...a.entries()].join('|') + ';' + [...a].join() + ';' + (a[Symbol.iterator] === a.values)", "0,1;0,1|1,2;1,2;true"),
    ("Object.prototype.toString.call(new Uint8Array(1)) + ',' + new Float64Array(1)[Symbol.toStringTag] + ',' + Object.getOwnPropertyDescriptor(Object.getPrototypeOf(Int8Array.prototype), Symbol.toStringTag).get.call(3)", "[object Uint8Array],Float64Array,undefined"),
    ("class MyTA extends Uint8Array {} var m = new MyTA(3); var s = m.map(x => x + 1); (s instanceof MyTA) + ',' + s.join()", "true,1,1,1"),
    ("var a = new Uint8Array(3); a.constructor = {[Symbol.species]: function (n) { return new Uint8Array(1) }}; try { a.slice() } catch (e) { e.name }", "TypeError"),
    ("var s = ''; for (var k in new Uint8Array(3)) s += k; s", "012"),
    ("var a = new Uint8Array(3); (function () { try { Object.freeze(a); return 'frozen' } catch (e) { return e.name } })()", "TypeError"),
    ("var a = new Uint8Array(1e5); for (var i = 0; i < a.length; i++) a[i] = i; var s = 0; for (var i = 0; i < a.length; i++) s += a[i]; s", "12742320"),
    // -------------------------------------------------- ArrayBuffer detach
    ("var b = new ArrayBuffer(8); var t = b.transfer(); b.byteLength + ',' + b.detached + ',' + t.byteLength + ',' + t.detached", "0,true,8,false"),
    ("var b = new ArrayBuffer(4); var u = new Uint8Array(b); u[0] = 9; var t = b.transfer(8); var v = new Uint8Array(t); u.length + ',' + u[0] + ',' + v.length + ',' + v[0] + ',' + u.byteLength", "0,undefined,8,9,0"),
    ("var b = new ArrayBuffer(4); var u = new Uint8Array(b); b.transfer(); try { u.fill(1) } catch (e) { e.name }", "TypeError"),
    ("var b = new ArrayBuffer(4); b.transfer(); try { b.slice() } catch (e) { e.name }", "TypeError"),
    ("var b = new ArrayBuffer(4); var dv = new DataView(b); b.transfer(); try { dv.getInt8(0) } catch (e) { e.name }", "TypeError"),
    ("var b = new ArrayBuffer(4); var u = new Uint8Array(b); b.transfer(); u[0] = 1; u[0] + ',' + Object.keys(u).length + ',' + (0 in u)", "undefined,0,false"),
    ("var b = new ArrayBuffer(4); b.transfer(); try { new Uint8Array(b) } catch (e) { e.name }", "TypeError"),
    ("var b = new ArrayBuffer(8); new Uint8Array(b).set([1, 2, 3, 4, 5]); var s = b.slice(1, -3); new Uint8Array(s).join() + ',' + s.byteLength", "2,3,4,5,4"),
    ("ArrayBuffer.isView(new DataView(new ArrayBuffer(1))) + ',' + ArrayBuffer.isView(new Int8Array(1)) + ',' + ArrayBuffer.isView({})", "true,true,false"),
    ("var b = new ArrayBuffer(2, {maxByteLength: 8}); var u = new Uint8Array(b); var f = new Uint8Array(b, 0, 2); b.resize(6); u.length + ',' + f.length + ',' + b.resizable + ',' + b.maxByteLength", "6,2,true,8"),
    ("var b = new ArrayBuffer(4, {maxByteLength: 8}); var f = new Uint8Array(b, 2, 2); b.resize(3); f.length + ',' + f.byteOffset + ',' + (function () { try { f.fill(0); return 'ok' } catch (e) { return e.name } })()", "0,0,TypeError"),
    ("var b = new ArrayBuffer(4, {maxByteLength: 8}); try { b.resize(9) } catch (e) { e.name }", "RangeError"),
    ("try { new ArrayBuffer(4, {maxByteLength: 2}) } catch (e) { e.name }", "RangeError"),
    ("try { new ArrayBuffer(2 ** 40) } catch (e) { e.name }", "RangeError"),
    // ------------------------------------------------------------ DataView
    ("var dv = new DataView(new ArrayBuffer(8)); dv.setUint16(0, 0x1234); dv.setUint16(2, 0x1234, true); [dv.getUint8(0), dv.getUint8(1), dv.getUint8(2), dv.getUint8(3)].join()", "18,52,52,18"),
    ("var dv = new DataView(new ArrayBuffer(8)); dv.setFloat64(0, 3.141592653589793); dv.getFloat64(0) + ',' + dv.getUint8(0) + ',' + dv.getFloat64(0, true)", "3.141592653589793,64,3.207375630676366e-192"),
    ("var dv = new DataView(new ArrayBuffer(4)); dv.setInt32(0, -2); dv.getInt32(0) + ',' + dv.getUint32(0) + ',' + dv.getInt16(2) + ',' + dv.getUint32(0, true)", "-2,4294967294,-2,4278190079"),
    ("var dv = new DataView(new ArrayBuffer(4)); dv.setFloat32(0, 1.5, true); dv.getFloat32(0, true) + ',' + dv.getUint8(3)", "1.5,63"),
    ("var dv = new DataView(new ArrayBuffer(2)); dv.setFloat16(0, 1.5); dv.getFloat16(0) + ',' + dv.getUint16(0).toString(16)", "1.5,3e00"),
    ("var dv = new DataView(new ArrayBuffer(4), 1, 2); dv.byteOffset + ',' + dv.byteLength + ',' + (function () { try { dv.getUint16(1) } catch (e) { return e.name } })()", "1,2,RangeError"),
    ("var dv = new DataView(new ArrayBuffer(4)); try { dv.getInt8(-1) } catch (e) { e.name }", "RangeError"),
    ("try { new DataView({}) } catch (e) { e.name }", "TypeError"),
    ("try { new DataView(new ArrayBuffer(2), 3) } catch (e) { e.name }", "RangeError"),
    ("Object.prototype.toString.call(new DataView(new ArrayBuffer(1))) + Object.prototype.toString.call(new ArrayBuffer(1))", "[object DataView][object ArrayBuffer]"),
    // ------------------------------------------------------ AggregateError
    ("var e = new AggregateError([1, 2], 'm', {cause: 'c'}); e.errors.join() + ',' + e.message + ',' + e.cause + ',' + e.name + ',' + (e instanceof Error)", "1,2,m,c,AggregateError,true"),
    ("new Error('x', {cause: 0}).cause", "0"),
]

/// Stand-ins for 9C built-ins these tests use, defined only when missing
/// (so once 9C lands its real methods are what runs).
let jsBuiltins3Prelude = """
    (function () {
      var d = function (o, n, f) { if (!Object.prototype.hasOwnProperty.call(o, n)) Object.defineProperty(o, n, {value: f, writable: true, configurable: true}) };
      var A = Array.prototype;
      d(A, 'join', function (sep) { sep = sep === undefined ? ',' : String(sep); var s = ''; for (var i = 0; i < this.length; i++) { if (i) s += sep; var v = this[i]; if (v !== undefined && v !== null) s += String(v) } return s });
      d(A, 'toString', function () { return this.join() });
      d(A, 'map', function (f) { var r = []; for (var i = 0; i < this.length; i++) r.push(f(this[i], i, this)); return r });
      d(Array, 'from', function (x, f) { var r = []; if (x != null && typeof x[Symbol.iterator] === 'function') { for (var v of x) r.push(v) } else { for (var i = 0; i < x.length; i++) r.push(x[i]) } return f ? r.map(f) : r });
      d(Object, 'is', function (a, b) { return a === b ? (a !== 0 || 1 / a === 1 / b) : (a !== a && b !== b) });
      d(Object, 'getOwnPropertyDescriptor', function (o, k) { return Reflect.getOwnPropertyDescriptor(Object(o), k) });
      d(Object, 'preventExtensions', function (o) { if (!Reflect.preventExtensions(o)) throw new TypeError('preventExtensions'); return o });
      d(Object, 'isExtensible', function (o) { return Reflect.isExtensible(o) });
      d(Object, 'freeze', function (o) { var ks = Reflect.ownKeys(o); for (var i = 0; i < ks.length; i++) { var p = Reflect.getOwnPropertyDescriptor(o, ks[i]); var nd = 'value' in p ? {configurable: false, writable: false} : {configurable: false}; if (!Reflect.defineProperty(o, ks[i], nd)) throw new TypeError('freeze') } Object.preventExtensions(o); return o });
    })();
    """

func jsBuiltins3Tests(_ t: Tests) {
    // Debug aid: WIFFER_JS_EVAL=file runs one script (prelude first) and
    // prints its completion.
    if let path = jsTest262Env("WIFFER_JS_EVAL"), let src = hostReadFile(path) {
        let realm = JSRuntime().makeRealm()
        _ = realm.evaluate(source: jsBuiltins3Prelude, name: "prelude.js")
        print("WIFFER_JS_EVAL: " + realm.evaluateToString(String(decoding: src, as: UTF8.self)))
    }
    jsBuiltins3Scripts(t, stress: false)
    jsBuiltins3GC(t)
    jsBuiltins3Exotic(t)
    jsBuiltins3Scripts(t, stress: true)
    jsBuiltins3Fuzz(t)
    jsBuiltins3Perf(t)
}

func jsBuiltins3Scripts(_ t: Tests, stress: Bool) {
    t.section(stress ? "9E runtime scripts (gcEveryAllocation)" : "9E runtime scripts")
    let rt = JSRuntime(limits: JSLimits())
    let start = hostMillis()
    for (src, want) in jsBuiltins3Cases {
        if stress && (jsHas(src, "1e5") || jsHas(src, "20000") || jsHas(src, "5000") || jsHas(src, "1000;")
                      || jsHas(src, "2 ** 40")) { continue }
        let realm = rt.makeRealm()
        _ = realm.evaluate(source: jsBuiltins3Prelude, name: "prelude.js")
        realm.heap.gcEveryAllocation = stress
        let t0 = hostMillis()
        t.equal(realm.evaluateToString(src), want, src)
        if stress && hostMillis() - t0 > 1500 { print("js 9E: slow under stress (\(hostMillis() - t0) ms): " + src) }
    }
    if stress { print("js 9E: gcEveryAllocation pass \(hostMillis() - start) ms") }
}

/// Weak collections against the real collector.
func jsBuiltins3GC(_ t: Tests) {
    t.section("9E weak collections and GC")
    let rt = JSRuntime()
    let realm = rt.makeRealm()
    _ = realm.evaluate(source: jsBuiltins3Prelude, name: "prelude.js")
    var gcN = 0
    realm.defineMethod(realm.global, "gc", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        realm.heap.collectGarbage()
        gcN += 1
        return .undefined
    }
    realm.defineMethod(realm.global, "clearKept", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        realm.clearKeptObjects()
        return .undefined
    }
    realm.defineMethod(realm.global, "weakSize", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        guard let w = realm.weakTable(args[0], realm.heap.kind(args[0])) else { return .int32(-1) }
        return .number(w.entries.count)
    }
    // Entries with dead keys go; strong ones stay.
    t.equal(realm.evaluateToString("""
        var wm = new WeakMap(); var keep = [];
        for (var i = 0; i < 100; i++) { var k = {i: i}; wm.set(k, {payload: i}); if (i % 10 == 0) keep.push(k) }
        k = null; gc(); weakSize(wm) + ',' + wm.get(keep[3]).payload
        """), "10,30", "WeakMap: only strongly held keys survive")
    // A value that references its own key does not keep it alive.
    t.equal(realm.evaluateToString("""
        var wm2 = new WeakMap(); (function () { for (var i = 0; i < 50; i++) { var k = {}; wm2.set(k, {back: k}) } })();
        gc(); weakSize(wm2)
        """), "0", "ephemeron: value -> key cycle collected")
    // Ephemeron chain: k0 strong; k_i maps to k_{i+1}, inserted in reverse.
    t.equal(realm.evaluateToString("""
        var wm3 = new WeakMap(); var ks = []; for (var i = 0; i < 200; i++) ks.push({n: i});
        for (var i = 198; i >= 0; i--) wm3.set(ks[i], ks[i + 1]);
        var head = ks[0]; ks = null; gc();
        var n = 0; for (var c = head; c; c = wm3.get(c)) n++; n + ',' + weakSize(wm3)
        """), "200,199", "ephemeron chain kept from its strong head")
    t.equal(realm.evaluateToString("head = null; gc(); weakSize(wm3)"), "0", "chain collected once the head dies")
    // A WeakMap held only through a weak value.
    t.equal(realm.evaluateToString("""
        var outer = new WeakMap(); var ok = {}; (function () { var inner = new WeakMap(); var ik = {}; inner.set(ik, 'deep'); outer.set(ok, [inner, ik]) })();
        gc(); var pair = outer.get(ok); pair[0].get(pair[1])
        """), "deep", "WeakMap reachable through another WeakMap's value")
    // WeakSet.
    t.equal(realm.evaluateToString("""
        var ws = new WeakSet(); var held = {}; ws.add(held); (function () { for (var i = 0; i < 30; i++) ws.add({}) })();
        gc(); weakSize(ws) + ',' + ws.has(held)
        """), "1,true", "WeakSet collects dead members")
    // WeakRef: kept during the job, cleared after.
    t.equal(realm.evaluateToString("""
        var wr; (function () { wr = new WeakRef({v: 1}) })(); gc(); typeof wr.deref()
        """), "object", "WeakRef target kept for the current job")
    t.equal(realm.evaluateToString("clearKept(); gc(); typeof wr.deref()"), "undefined", "WeakRef cleared after ClearKeptObjects")
    // FinalizationRegistry.
    var cleanupSignals = 0
    realm.tables.onFinalizationCleanupNeeded = { cleanupSignals += 1 }
    t.equal(realm.evaluateToString("""
        var cleaned = []; var fr = new FinalizationRegistry(h => cleaned.push(h)); var tok = {};
        (function () { fr.register({}, 'a'); fr.register({}, 'b', tok); fr.register({}, 'c', tok) })();
        fr.unregister(tok); var stay = {}; fr.register(stay, 's'); gc(); cleaned.length
        """), "0", "cleanup callbacks are not run inside the GC")
    t.check(cleanupSignals > 0, "host notified of pending cleanup")
    t.check(realm.hasPendingFinalizationCleanups, "cleanup pending")
    do throws(JSThrow) { try realm.runFinalizationCleanups() } catch { t.check(false, "cleanup threw") }
    t.equal(realm.evaluateToString("cleaned.join()"), "a", "only the registered, unregistered-token-free target is cleaned")
    // Dead registries and collections free their tables.
    t.equal(realm.evaluateToString("""
        (function () { for (var i = 0; i < 100; i++) { new Map([[i, i]]); new WeakMap(); new Set([i]) } })(); gc(); 'ok'
        """), "ok", "throwaway collections")
    var liveMaps = 0, liveWeak = 0
    for m in realm.tables.mapIndexes where m != nil { liveMaps += 1 }
    for w in realm.tables.weakTables where w != nil { liveWeak += 1 }
    t.check(liveMaps < 10 && liveWeak < 10, "side tables freed", "maps \(liveMaps) weak \(liveWeak)")
    // ArrayBuffer stores are freed with their buffers.
    t.equal(realm.evaluateToString("""
        (function () { for (var i = 0; i < 200; i++) new Uint8Array(1 << 16) })(); gc(); var keepBuf = new Uint8Array(1 << 20); keepBuf.length
        """), "1048576", "buffers")
    var stores = 0, bytes = 0
    for s in realm.heap.byteStores where !s.isEmpty { stores += 1; bytes += s.count }
    t.check(stores <= 2 && bytes >= 1 << 20, "dead buffers released", "\(stores) stores, \(bytes) bytes")
    t.check(gcN > 5, "gc ran")
    // Map iterator survives compaction under GC.
    t.equal(realm.evaluateToString("""
        var mm = new Map(); for (var i = 0; i < 100; i++) mm.set({i: i}, i);
        var it = mm.values(); it.next(); var ks = [...mm.keys()]; for (var i = 0; i < 90; i++) mm.delete(ks[i]); ks = null; gc();
        [...it].join()
        """), "90,91,92,93,94,95,96,97,98,99", "Map iterator after compaction and GC")
}

/// The exotic-object host hook (what 9F's NodeList uses).
func jsBuiltins3Exotic(_ t: Tests) {
    t.section("9E exotic host hook")
    let rt = JSRuntime()
    let realm = rt.makeRealm()
    _ = realm.evaluate(source: jsBuiltins3Prelude, name: "prelude.js")
    var items: [Int32] = [10, 20, 30]
    var h = JSExoticHandler()
    h.getOwnProperty = { (realm: JSRealm, o: JSValue, k: JSPropertyKey) throws(JSThrow) -> JSProperty? in
        if k.isIndex && Int(k.index) < items.count { return .data(.int32(items[Int(k.index)]), [.enumerable, .configurable]) }
        if k == realm.heap.names.length { return .data(.number(items.count), []) }
        return nil
    }
    h.defineOwnProperty = { (realm: JSRealm, o: JSValue, k: JSPropertyKey, d: JSPropertyDescriptor) throws(JSThrow) -> Bool? in
        k.isIndex ? false : nil
    }
    h.deleteProperty = { (realm: JSRealm, o: JSValue, k: JSPropertyKey) throws(JSThrow) -> Bool? in
        k.isIndex && Int(k.index) < items.count ? false : nil
    }
    h.ownKeys = { (realm: JSRealm, o: JSValue) throws(JSThrow) -> [JSPropertyKey] in
        var out: [JSPropertyKey] = []
        for i in 0..<items.count { out.append(.index(UInt32(i))) }
        return out
    }
    let id = realm.registerExoticHandler(h)
    let list = realm.heap.newObject(proto: realm.objectPrototype, kind: .host)
    realm.makeExotic(list, handler: id)
    realm.defineGlobal("list", list)
    t.equal(realm.evaluateToString("list[1] + ',' + list.length + ',' + list[5] + ',' + (2 in list) + ',' + (3 in list)"), "20,3,undefined,true,false", "indexed getter")
    t.equal(realm.evaluateToString("list.expando = 'e'; list.expando + ',' + Object.keys(list).join()"), "e,0,1,2,expando", "expandos and ownKeys order")
    t.equal(realm.evaluateToString("'use strict'; try { list[0] = 5; 'no' } catch (e) { e.name }"), "TypeError", "indexed set rejected")
    t.equal(realm.evaluateToString("delete list[0]"), "false", "indexed delete rejected")
    t.equal(realm.evaluateToString("var s = 0; for (var k in list) s += list[k] | 0; s"), "60", "for-in")
    items.append(40)
    t.equal(realm.evaluateToString("list[3] + ',' + list.length + ',' + Object.create(list)[3]"), "40,4,40", "live view, inherited lookup")
    t.equal(realm.evaluateToString("var p = new Proxy(list, {}); p[2] + ',' + Reflect.ownKeys(p).length"), "30,5", "proxy over a host exotic")
}

/// Proxy-heavy fuzz: mutants of the case scripts with traps everywhere.
func jsBuiltins3Fuzz(_ t: Tests) {
    t.section("9E fuzz")
    var seeds: [[UInt8]] = []
    for (src, _) in jsBuiltins3Cases where !jsHas(src, "1e5") && !jsHas(src, "20000") && !jsHas(src, "5000") {
        seeds.append(Array(src.utf8))
    }
    seeds.append(Array("""
        var h = {get(t,k,r){return Reflect.get(t,k,r)},set(t,k,v,r){return Reflect.set(t,k,v,r)},has(t,k){return k in t},
        ownKeys(t){return Reflect.ownKeys(t)},getOwnPropertyDescriptor(t,k){return Reflect.getOwnPropertyDescriptor(t,k)},
        defineProperty(t,k,d){return Reflect.defineProperty(t,k,d)},deleteProperty(t,k){return delete t[k]},
        getPrototypeOf(t){return Reflect.getPrototypeOf(t)},setPrototypeOf(t,p){return Reflect.setPrototypeOf(t,p)},
        apply(t,th,a){return Reflect.apply(t,th,a)},construct(t,a,n){return Reflect.construct(t,a,n)}};
        var P = new Proxy(function(){ return this }, h); var o = new Proxy({a:[1,2]}, h); o.b = new Proxy(new Map([[1,o]]), h);
        for (var k in o) o[k]; Object.keys(o); new P(); P.call(o); delete o.a; Object.setPrototypeOf(o, P);
        var ta = new Proxy(new Uint8Array(4), h); ta[1] = 300; [...new Set([ta[1], o])].length
        """.utf8))
    let rt = JSRuntime(limits: JSLimits.small)
    var budget = 0
    rt.interruptHandler = { _ in budget += 1; return budget > 3 }
    let realm = rt.makeRealm()
    _ = realm.evaluate(source: jsBuiltins3Prelude, name: "prelude.js")
    var n = 0
    t.fuzz("9e", seeds: seeds, iterations: 15000) { m in
        budget = 0
        n += 1
        if n % 500 == 0 { realm.heap.collectGarbage() }
        _ = realm.evaluate(source: m, name: "fuzz9e.js")
        realm.clearKeptObjects()
        do throws(JSThrow) { try realm.runFinalizationCleanups() } catch {}
    }
    let fresh = rt.makeRealm()
    t.equal(fresh.evaluateToString("new Proxy({a: 2}, {}).a + new Map([[1, 1]]).size"), "3", "after fuzz")
}

func jsBuiltins3Perf(_ t: Tests) {
    t.section("9E perf")
    func run(_ name: String, _ src: String, _ want: String) {
        let realm = JSRuntime().makeRealm()
        let start = hostMillis()
        let got = realm.evaluateToString(src)
        print("js 9E perf: \(name) \(hostMillis() - start) ms")
        t.equal(got, want, name)
    }
    run("Map set/get 200k", "var m = new Map(); for (var i = 0; i < 200000; i++) m.set(i, i); var s = 0; for (var i = 0; i < 200000; i++) s += m.get(i); s", "19999900000")
    run("Map string keys 100k", "var m = new Map(); for (var i = 0; i < 100000; i++) m.set('k' + i, i); m.get('k99999')", "99999")
    run("Uint8Array 1M writes+reads (globals)", "var a = new Uint8Array(1 << 20); for (var i = 0; i < a.length; i++) a[i] = i; var s = 0; for (var i = 0; i < a.length; i++) s += a[i]; s", "133693440")
    run("Uint8Array 1M writes+reads, in a function", "(function () { var a = new Uint8Array(1 << 20); var n = a.length; for (var i = 0; i < n; i++) a[i] = i; var s = 0; for (var i = 0; i < n; i++) s += a[i]; return s })()", "133693440")
    run("Float64Array 1M writes+reads, in a function", "(function () { var a = new Float64Array(1 << 20); for (var i = 0; i < a.length; i++) a[i] = i * 0.5; var s = 0; for (var i = 0; i < a.length; i++) s += a[i]; return s })()", "274877644800")
    run("Proxy get 100k", "var p = new Proxy({x: 1}, { get(t, k) { return t[k] } }); var s = 0; for (var i = 0; i < 100000; i++) s += p.x; s", "100000")
}
