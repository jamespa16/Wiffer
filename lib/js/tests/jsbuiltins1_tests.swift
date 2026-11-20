// Host tests for the 9C built-ins: Object, Array, Number, Math, JSON and the
// global functions. Scripts evaluate to a string compared with the expected
// text; the same list runs again under gcEveryAllocation, and JSON.parse is
// fuzzed with mutated documents.

let jsB1Cases: [(String, String)] = [
    // ---- Object
    ("Object.keys({b:1,a:2,1:3}).join()", "1,b,a"),
    ("Object.values({a:1,b:2}).join()", "1,2"),
    ("Object.entries({a:1,b:[2]}).join('|')", "a,1|b,2"),
    ("JSON.stringify(Object.fromEntries([['a',1],['b',2]]))", "{\"a\":1,\"b\":2}"),
    ("var o = Object.assign({a:1},{b:2},null,{a:3}); o.a + ',' + o.b", "3,2"),
    ("var o = Object.create({x:1},{y:{value:2,enumerable:true}}); o.x + ',' + o.y + ',' + Object.keys(o)", "1,2,y"),
    ("var o = {}; Object.defineProperties(o,{a:{value:1},b:{get:function(){return 5}}}); o.a + ',' + o.b + ',' + Object.keys(o).length", "1,5,0"),
    ("var d = Object.getOwnPropertyDescriptor({get a(){return 1}}, 'a'); typeof d.get + ',' + d.set + ',' + d.enumerable + ',' + d.configurable", "function,undefined,true,true"),
    ("JSON.stringify(Object.getOwnPropertyDescriptors({a:1}))", "{\"a\":{\"value\":1,\"writable\":true,\"enumerable\":true,\"configurable\":true}}"),
    ("Object.getOwnPropertyNames([1,2]).join()", "0,1,length"),
    ("var s = Symbol('q'); var o = {[s]:1, a:2}; Object.getOwnPropertySymbols(o).length + ',' + Object.getOwnPropertyNames(o)", "1,a"),
    ("var o = Object.freeze({a:1}); o.a = 2; delete o.a; o.a + ',' + Object.isFrozen(o) + ',' + Object.isSealed(o) + ',' + Object.isExtensible(o)", "1,true,true,false"),
    ("'use strict'; var o = Object.freeze([1]); try { o.push(2) } catch (e) { e.constructor === TypeError }", "true"),
    ("var o = Object.seal({a:1}); o.a = 2; delete o.a; o.b = 1; o.a + ',' + Object.isFrozen(o) + ',' + Object.isSealed(o)", "2,false,true"),
    ("Object.isFrozen(1) + ',' + Object.isFrozen(Object.preventExtensions({}))", "true,true"),
    ("Object.is(NaN,NaN) + ',' + Object.is(0,-0) + ',' + Object.is('a','a')", "true,false,true"),
    ("Object.hasOwn({a:1},'a') + ',' + Object.hasOwn({a:1},'b') + ',' + Object.hasOwn([], 'length')", "true,false,true"),
    ("var g = Object.groupBy([1,2,3,4,5], function(x){ return x % 2 ? 'odd' : 'even' }); Object.getPrototypeOf(g) + ',' + g.odd + '|' + g.even", "null,1,3,5|2,4"),
    ("Object.getPrototypeOf(Object.setPrototypeOf({}, null))", "null"),
    ("try { Object.setPrototypeOf(Object.prototype, {}) } catch (e) { e.name }", "TypeError"),
    ("var a = {}; var b = Object.create(a); try { Object.setPrototypeOf(a, b) } catch (e) { e.name }", "TypeError"),
    ("Object.prototype.toString.call(null) + Object.prototype.toString.call([]) + Object.prototype.toString.call(function(){}) + Object.prototype.toString.call(1) + Object.prototype.toString.call(true)", "[object Null][object Array][object Function][object Number][object Boolean]"),
    ("var o = {[Symbol.toStringTag]: 'Foo'}; String(o)", "[object Foo]"),
    ("Object.prototype.toString.call(Math) + Object.prototype.toString.call(JSON)", "[object Math][object JSON]"),
    ("(function(){ return Object.prototype.toString.call(arguments) })()", "[object Arguments]"),
    ("({a:1}).propertyIsEnumerable('a') + ',' + [].propertyIsEnumerable('length')", "true,false"),
    ("var p = {}; var o = Object.create(p); p.isPrototypeOf(o) + ',' + o.isPrototypeOf(p)", "true,false"),
    ("var o = {}; o.__proto__ = Array.prototype; o instanceof Array", "true"),
    ("({}).__proto__ === Object.prototype", "true"),
    ("var o = {}; o.__defineGetter__('x', function(){ return 7 }); o.x + ',' + typeof o.__lookupGetter__('x') + ',' + o.__lookupSetter__('x')", "7,function,undefined"),
    ("({a:1}).toLocaleString()", "[object Object]"),
    ("Object.entries('ab').join('|')", "0,a|1,b"),
    ("try { Object.keys(null) } catch (e) { e.name }", "TypeError"),
    ("Object.getOwnPropertyNames('ab').join()", "0,1,length"),
    ("var log = []; var o = {get a(){ log.push('a'); return 1 }, get b(){ log.push('b'); return 2 }}; Object.assign({}, o); log.join()", "a,b"),
    ("Object.defineProperty([], 'length', {value: 3}).length", "3"),
    // ---- Array statics
    ("Array.isArray([]) + ',' + Array.isArray({}) + ',' + Array.isArray(Array.prototype)", "true,false,true"),
    ("Array.of(1,2,3).join() + ',' + Array.of(7).length", "1,2,3,1"),
    ("Array.from('abc').join()", "a,b,c"),
    ("Array.from({length:3}, function(v, i){ return i * 2 }).join()", "0,2,4"),
    ("Array.from(new Array(3)).length + ',' + Array.from([1,,3]).join()", "3,1,,3"),
    ("Array.from({length:2, 0:'x', 1:'y'}).join()", "x,y"),
    ("function C(n){ this.n = n } var r = Array.from.call(C, {length:2, 0:1, 1:2}); r.n + ',' + r.length + ',' + (r instanceof C)", "2,2,true"),
    ("var it = {[Symbol.iterator]: function(){ var i = 0; return {next: function(){ return i < 3 ? {value: i++, done: false} : {done: true} }} }}; Array.from(it).join()", "0,1,2"),
    ("var closed = 0; var it = {[Symbol.iterator]: function(){ return {next: function(){ return {value:1, done:false} }, return: function(){ closed++; return {} }} }}; try { Array.from(it, function(){ throw 1 }) } catch (e) {} closed", "1"),
    ("try { Array.from([], 5) } catch (e) { e.name }", "TypeError"),
    ("class A extends Array {} var a = A.from([1,2]); a instanceof A", "true"),
    ("Array[Symbol.species] === Array", "true"),
    // ---- Array.prototype
    ("[1,2,3].concat([4,5],6,[[7]]).join('|')", "1|2|3|4|5|6|7"),
    ("var a = [1]; a.length = 3; a.concat([4]).length + ',' + (1 in a.concat([4]))", "4,false"),
    ("var o = {length:2, 0:'a', 1:'b', [Symbol.isConcatSpreadable]: true}; [0].concat(o).join()", "0,a,b"),
    ("var a = [1,2]; a[Symbol.isConcatSpreadable] = false; [0].concat(a).length", "2"),
    ("[1,2,3,4,5].copyWithin(0,3).join()", "4,5,3,4,5"),
    ("[1,2,3,4,5].copyWithin(1,0,3).join()", "1,1,2,3,5"),
    ("[1,2,3,4,5].copyWithin(-2,-4,-3).join()", "1,2,3,2,5"),
    ("[1,2,3].fill(0).join() + ',' + [1,2,3].fill(9,1,2).join() + ',' + [1,2,3].fill(7,-1).join()", "0,0,0,1,9,3,1,2,7"),
    ("[1,2,3].every(function(x){return x>0}) + ',' + [1,2,3].some(function(x){return x>2}) + ',' + [].every(function(){return false})", "true,true,true"),
    ("[1,2,3].map(function(x){return x*2}).join()", "2,4,6"),
    ("[1,,3].map(function(x){return x*2}).length + ',' + (1 in [1,,3].map(function(x){return x}))", "3,false"),
    ("[1,2,3,4].filter(function(x){return x%2}).join()", "1,3"),
    ("var s = 0; [1,,3].forEach(function(x){ s += x }); s", "4"),
    ("[1,2,3].find(function(x){return x>1}) + ',' + [1,2,3].findIndex(function(x){return x>1}) + ',' + [1,2,3].findLast(function(x){return x<3}) + ',' + [1,2,3].findLastIndex(function(x){return x<3}) + ',' + [1].find(function(){return false})", "2,1,2,1,undefined"),
    ("[1,[2,[3,[4]]]].flat().join('|') + ',' + [1,[2,[3,[4]]]].flat(Infinity).join('|') + ',' + [1,[2,[3]]].flat(0).length", "1|2|3,4,1|2|3|4,2"),
    ("[1,2].flatMap(function(x){return [x,x*10]}).join()", "1,10,2,20"),
    ("[1,2,3].includes(2) + ',' + [NaN].includes(NaN) + ',' + [NaN].indexOf(NaN) + ',' + [1,2,3].includes(1,1) + ',' + [,].includes(undefined) + ',' + [,].indexOf(undefined)", "true,true,-1,false,true,-1"),
    ("[1,2,1].indexOf(1,1) + ',' + [1,2,1].lastIndexOf(1) + ',' + [1,2,1].lastIndexOf(1,-2) + ',' + [1,2,1].indexOf(1,-1) + ',' + [0].indexOf(-0)", "2,2,0,2,0"),
    ("[1,null,undefined,[2,3]].join('-')", "1---2,3"),
    ("[1,2,3].join(undefined) + ',' + [].join() + ',' + [null].join() + ',' + [1].join(1)", "1,2,3,,,1"),
    ("var a = [1,2]; a.push(a); a.join()", "1,2,"),
    ("var a = [1,2,3]; a.pop() + ',' + a.length + ',' + [].pop()", "3,2,undefined"),
    ("var a = [1]; a.push(2,3) + ',' + a.join()", "3,1,2,3"),
    ("var a = [1,2,3]; a.shift() + ',' + a.join() + ',' + [].shift()", "1,2,3,undefined"),
    ("var a = [3]; a.unshift(1,2) + ',' + a.join()", "3,1,2,3"),
    ("[1,2,3].reduce(function(a,b){return a+b}) + ',' + [1,2,3].reduce(function(a,b){return a+b}, 10) + ',' + [[1],[2]].reduceRight(function(a,b){return a.concat(b)}).join()", "6,16,2,1"),
    ("try { [].reduce(function(){}) } catch (e) { e.name }", "TypeError"),
    ("[1,2,3].reverse().join() + ',' + [1,,3].reverse().length + ',' + (1 in [1,,3].reverse())", "3,2,1,3,false"),
    ("[1,2,3,4].slice(1,3).join() + ',' + [1,2,3].slice(-2).join() + ',' + [1,2,3].slice(5).length + ',' + [1,2,3].slice().join()", "2,3,2,3,0,1,2,3"),
    ("[3,1,2].sort().join() + ',' + [10,9,1].sort().join() + ',' + [10,9,1].sort(function(a,b){return a-b}).join()", "1,2,3,1,10,9,1,9,10"),
    ("[3,undefined,1,,2].sort().length + ',' + [3,undefined,1,,2].sort().join('|')", "5,1|2|3||"),
    ("var a = [3,undefined,1,,2]; a.sort(); (4 in a) + ',' + (3 in a) + ',' + a[3]", "false,true,undefined"),
    ("var r = []; for (var i = 0; i < 50; i++) r.push({k: i % 5, i: i}); r.sort(function(a,b){return a.k-b.k}); r.slice(0,12).map(function(x){return x.i}).join()", "0,5,10,15,20,25,30,35,40,45,1,6"),
    ("try { [2,1].sort(function(){ throw new RangeError('x') }) } catch (e) { e.name }", "RangeError"),
    ("try { [].sort(5) } catch (e) { e.name }", "TypeError"),
    ("var a = [5,4,3,2,1]; a.sort(function(x,y){ a.length = 0; return x - y }); a.length", "5"),
    ("['b','a','C'].sort().join()", "C,a,b"),
    ("[1,2,3,4,5].splice(1,2).join()", "2,3"),
    ("var a = [1,2,3,4,5]; a.splice(1,2,'a','b','c'); a.join()", "1,a,b,c,4,5"),
    ("var a = [1,2,3]; a.splice(1); a.join() + ',' + [1,2,3].splice().length + ',' + [1,2,3].splice(-1,1)", "1,0,3"),
    ("var a = [1,2,3]; a.splice(1,0,9); a.join()", "1,9,2,3"),
    ("var o = {length:3, 0:'a', 1:'b', 2:'c'}; Array.prototype.splice.call(o, 0, 1); o.length + ',' + o[0] + ',' + o[1] + ',' + (2 in o)", "2,b,c,false"),
    ("[1,2,3].at(-1) + ',' + [1,2,3].at(5) + ',' + [1,2,3].at(0)", "3,undefined,1"),
    ("var a = [1,2,3]; var b = a.toReversed(); a.join() + '|' + b.join()", "1,2,3|3,2,1"),
    ("var a = [3,1,2]; var b = a.toSorted(); a.join() + '|' + b.join()", "3,1,2|1,2,3"),
    ("[1,2,3].toSpliced(1,1,'x','y').join() + ',' + [1,2,3].toSpliced().join()", "1,x,y,3,1,2,3"),
    ("[1,2,3].with(1,9).join() + ',' + [1,2,3].with(-1,0).join()", "1,9,3,1,2,0"),
    ("try { [1].with(1,0) } catch (e) { e.name }", "RangeError"),
    ("[1,,3].toSorted().length + ',' + [1,,3].toReversed().hasOwnProperty(1)", "3,true"),
    ("Array.from([1,2].entries()).join('|') + ',' + Array.from([5,6].keys()).join() + ',' + Array.from([5,6].values()).join()", "0,1|1,2,0,1,5,6"),
    ("var it = [1].entries(); var r = it.next(); r.value.join() + ',' + r.done + ',' + it.next().done", "0,1,false,true"),
    ("Object.keys(Array.prototype[Symbol.unscopables]).join() + ',' + Object.getPrototypeOf(Array.prototype[Symbol.unscopables])", "at,copyWithin,entries,fill,find,findIndex,findLast,findLastIndex,flat,flatMap,includes,keys,toReversed,toSorted,toSpliced,values,null"),
    ("Array.prototype.map.call('abc', function(c){ return c + c }).join()", "aa,bb,cc"),
    ("Array.prototype.push.call({length: 1}, 5)", "2"),
    ("var o = {length: 2**53 - 1}; try { Array.prototype.push.call(o, 1) } catch (e) { e.name }", "TypeError"),
    ("var a = [1,2,3]; var n = 0; a.forEach(function(x){ if (n++ == 0) a.push(4) }); n", "3"),
    ("var a = [1,2,3]; var r = []; a.forEach(function(x, i){ r.push(x); if (i == 0) a.length = 1 }); r.join()", "1"),
    ("var a = [1,2,3]; Object.defineProperty(a, 1, {get: function(){ a.length = 0; return 9 }, configurable: true}); a.map(function(x){ return x }).join('|')", "1|9|"),
    ("class A extends Array {} var a = new A(); a.push(1,2,3); (a.map(function(x){return x}) instanceof A) + ',' + (a.filter(function(){return true}) instanceof A) + ',' + (a.slice() instanceof A)", "true,true,true"),
    ("var a = [1,2,3]; a.constructor = {[Symbol.species]: function(n){ return {length:0, n: n} }}; var r = a.map(function(x){return x}); r.n + ',' + r[1]", "3,2"),
    ("[].concat.length + ',' + [].push.length + ',' + [].splice.length + ',' + Array.from.length + ',' + [].slice.name", "1,1,2,1,slice"),
    ("var a = new Array(5); a.length + ',' + a.indexOf(undefined) + ',' + a.findIndex(function(x){return x === undefined})", "5,-1,0"),
    ("var a = []; a[4294967294] = 1; a.length + ',' + a.indexOf(1, 4294967290)", "4294967295,4294967294"),
    ("[0, -0].map(function(x){ return 1 / x }).join()", "Infinity,-Infinity"),
    ("[1,2,3].toString() + ',' + Array.prototype.toString.call({join: function(){ return 'J' }}) + ',' + Array.prototype.toString.call({})", "1,2,3,J,[object Object]"),
    ("[1.5, 2].toLocaleString()", "1.5,2"),
    ("[[1,[2]],3].toString()", "1,2,3"),
    // ---- Number
    ("Number.EPSILON + ',' + Number.MAX_SAFE_INTEGER + ',' + Number.MIN_SAFE_INTEGER + ',' + Number.MAX_VALUE + ',' + Number.MIN_VALUE", "2.220446049250313e-16,9007199254740991,-9007199254740991,1.7976931348623157e+308,5e-324"),
    ("Number.isInteger(5) + ',' + Number.isInteger(5.5) + ',' + Number.isInteger('5') + ',' + Number.isSafeInteger(2**53) + ',' + Number.isNaN('x') + ',' + Number.isFinite('1') + ',' + isNaN('x') + ',' + isFinite('1')", "true,false,false,false,false,false,true,true"),
    ("Number.parseInt === parseInt && Number.parseFloat === parseFloat", "true"),
    ("parseInt('  42px') + ',' + parseInt('0x1f') + ',' + parseInt('-0') + ',' + parseInt('z', 36) + ',' + parseInt('12', 2) + ',' + parseInt('') + ',' + parseInt('9', 8) + ',' + parseInt('11', 37) + ',' + 1/parseInt('-0')", "42,31,0,35,1,NaN,NaN,NaN,-Infinity"),
    ("parseInt('123456789012345678901234567890') + ',' + parseInt('0b11') + ',' + parseInt('0x') + ',' + parseInt('10', 0) + ',' + parseInt('0x10', 16)", "1.2345678901234568e+29,0,NaN,10,16"),
    ("parseFloat('3.14abc') + ',' + parseFloat('  -1e3x') + ',' + parseFloat('.5') + ',' + parseFloat('Infinityx') + ',' + parseFloat('abc') + ',' + parseFloat('1e') + ',' + parseFloat('-.5e-2')", "3.14,-1000,0.5,Infinity,NaN,1,-0.005"),
    ("(255).toString(16) + ',' + (255).toString(2) + ',' + (-255).toString(36) + ',' + (0.5).toString(2)", "ff,11111111,-73,0.1"),
    ("try { (1).toString(1) } catch (e) { e.name }", "RangeError"),
    ("(1234.5678).toFixed(2) + ',' + (0.5).toFixed(0) + ',' + (1.005).toFixed(2) + ',' + (1e21).toFixed(2) + ',' + (-1.5).toFixed(0) + ',' + (0).toFixed(2) + ',' + (123.456).toFixed()", "1234.57,1,1.00,1e+21,-2,0.00,123"),
    ("(2.5).toFixed(0) + ',' + (10.235).toFixed(2) + ',' + (-0.0000001).toFixed(2) + ',' + NaN.toFixed(1)", "3,10.23,-0.00,NaN"),
    ("try { (1).toFixed(101) } catch (e) { e.name }", "RangeError"),
    ("(123.456).toPrecision(4) + ',' + (0.000123).toPrecision(2) + ',' + (123456).toPrecision(2) + ',' + (1).toPrecision(5) + ',' + (1.25).toPrecision(2) + ',' + (15).toPrecision() + ',' + (1e21).toPrecision(3)", "123.5,0.00012,1.2e+5,1.0000,1.3,15,1.00e+21"),
    ("try { (1).toPrecision(0) } catch (e) { e.name }", "RangeError"),
    ("(123456).toExponential(2) + ',' + (0).toExponential() + ',' + (0.00015).toExponential() + ',' + (1.5).toExponential(0) + ',' + (-12).toExponential(1) + ',' + Infinity.toExponential(200)", "1.23e+5,0e+0,1.5e-4,2e+0,-1.2e+1,Infinity"),
    ("(1234567.891).toLocaleString() + ',' + (0).toLocaleString() + ',' + (-1234.5).toLocaleString() + ',' + (0.12345).toLocaleString() + ',' + (999.9996).toLocaleString()", "1,234,567.891,0,-1,234.5,0.123,1,000"),
    ("new Number(5) + 1 + ',' + typeof new Number(5) + ',' + Number('0b101') + ',' + Number('  12  ') + ',' + Number('1_0') + ',' + Number(null) + ',' + Number(undefined) + ',' + Number([5])", "6,object,5,12,NaN,0,NaN,5"),
    ("Number.prototype.valueOf.call(7) + ',' + (function(){ try { Number.prototype.valueOf.call('x') } catch (e) { return e.name } })()", "7,TypeError"),
    ("new Boolean(false) ? 'y' : 'n'", "y"),
    ("Boolean('') + ',' + Boolean('0') + ',' + true.toString() + ',' + new Boolean(true).valueOf()", "false,true,true,true"),
    // ---- globals
    ("encodeURIComponent('a b&c/d?é€😀')", "a%20b%26c%2Fd%3F%C3%A9%E2%82%AC%F0%9F%98%80"),
    ("encodeURI('http://x.com/a b?q=1&r=é#h')", "http://x.com/a%20b?q=1&r=%C3%A9#h"),
    ("decodeURIComponent('a%20b%26%C3%A9%E2%82%AC%F0%9F%98%80') === 'a b&é€😀'", "true"),
    ("decodeURI('%41%26%23%2f') ", "A%26%23%2f"),
    ("try { decodeURIComponent('%') } catch (e) { e.name }", "URIError"),
    ("try { decodeURIComponent('%C3') } catch (e) { e.name }", "URIError"),
    ("try { decodeURIComponent('%C0%80') } catch (e) { e.name }", "URIError"),
    ("try { decodeURIComponent('%ED%A0%80') } catch (e) { e.name }", "URIError"),
    ("try { encodeURIComponent('\\ud800') } catch (e) { e.name }", "URIError"),
    ("try { encodeURIComponent('\\udc00x') } catch (e) { e.name }", "URIError"),
    ("encodeURIComponent('\\ud83d\\ude00')", "%F0%9F%98%80"),
    ("escape('a b+c/é€')", "a%20b+c/%E9%u20AC"),
    ("unescape('a%20b%E9%u20AC%zz%u12')", "a bé€%zz%u12"),
    ("(globalThis === this) + ',' + typeof globalThis.Math", "true,object"),
    // ---- Math
    ("Math.abs(-5) + ',' + Math.abs(-0) + ',' + Math.sign(-3) + ',' + Math.sign(0) + ',' + 1/Math.sign(-0) + ',' + Math.trunc(-4.7) + ',' + 1/Math.trunc(-0.5)", "5,0,-1,0,-Infinity,-4,-Infinity"),
    ("Math.floor(-1.5) + ',' + Math.ceil(-1.5) + ',' + 1/Math.ceil(-0.5) + ',' + Math.floor(1.5) + ',' + Math.ceil(1.2)", "-2,-1,-Infinity,1,2"),
    ("Math.round(2.5) + ',' + Math.round(-2.5) + ',' + Math.round(0.49999999999999994) + ',' + 1/Math.round(-0.2) + ',' + Math.round(1.4) + ',' + Math.round(2**52 + 1) + ',' + Math.round(-0.5)", "3,-2,0,-Infinity,1,4503599627370497,0"),
    ("Math.max() + ',' + Math.min() + ',' + Math.max(1,3,2) + ',' + Math.min(1,NaN) + ',' + 1/Math.max(-0,0) + ',' + 1/Math.min(0,-0) + ',' + Math.max('5', 3)", "-Infinity,Infinity,3,NaN,Infinity,-Infinity,5"),
    ("Math.sqrt(16) + ',' + Math.sqrt(2) + ',' + Math.sqrt(-1) + ',' + Math.cbrt(27) + ',' + Math.cbrt(-8) + ',' + Math.cbrt(2) + ',' + Math.hypot(3,4) + ',' + Math.hypot() + ',' + Math.hypot(NaN, Infinity) + ',' + Math.hypot(1e200, 1e200)", "4,1.4142135623730951,NaN,3,-2,1.2599210498948732,5,0,Infinity,1.414213562373095e+200"),
    ("Math.pow(2,10) + ',' + Math.pow(2,0.5) + ',' + Math.pow(10,-2) + ',' + Math.pow(-8, 1/3) + ',' + Math.pow(0,0) + ',' + Math.pow(NaN,0) + ',' + Math.pow(1,Infinity) + ',' + Math.pow(10, 308) + ',' + Math.pow(1.1, 10) + ',' + 2**-1074 + ',' + 10**21", "1024,1.4142135623730951,0.01,NaN,1,1,NaN,1e+308,2.5937424601000023,5e-324,1e+21"),
    ("Math.exp(1) + ',' + Math.exp(0) + ',' + Math.exp(-1) + ',' + Math.exp(710) + ',' + Math.exp(-746) + ',' + Math.exp(10) + ',' + Math.expm1(1) + ',' + Math.expm1(1e-10) + ',' + Math.expm1(-0)", "2.718281828459045,1,0.36787944117144233,Infinity,0,22026.465794806718,1.7182818284590453,1.00000000005e-10,0"),
    ("Math.log(1) + ',' + Math.log(Math.E) + ',' + Math.log(10) + ',' + Math.log(0) + ',' + Math.log(-1) + ',' + Math.log2(8) + ',' + Math.log2(1024) + ',' + Math.log10(1000) + ',' + Math.log10(0.001) + ',' + Math.log1p(1) + ',' + (Math.abs(Math.log1p(1e-10) / 1e-10 - 1) < 1e-9) + ',' + Math.log2(3)", "0,1,2.302585092994046,-Infinity,NaN,3,10,3,-3,0.6931471805599453,true,1.584962500721156"),
    ("Math.sin(0) + ',' + Math.sin(1) + ',' + Math.cos(1) + ',' + Math.tan(1) + ',' + Math.sin(Math.PI) + ',' + Math.cos(Math.PI) + ',' + Math.sin(-0) + ',' + Math.sin(Infinity) + ',' + Math.cos(Math.PI/2)", "0,0.8414709848078965,0.5403023058681398,1.5574077246549023,1.2246467991473532e-16,-1,0,NaN,6.123233995736766e-17"),
    ("function near(a, b) { return Math.abs(a - b) <= 4e-16 * Math.abs(b) } [near(Math.sin(1e6), -0.3499935021712929), near(Math.cos(1e6), 0.9367521275331447), near(Math.sin(1e22), -0.8522008497671888), near(Math.cos(1e22), 0.5232147853951389), near(Math.tan(1e22), -1.6287782256068988)].join()", "true,true,true,true,true"),
    ("Math.atan(1) + ',' + Math.atan(0.5) + ',' + Math.atan(2) + ',' + Math.atan(Infinity) + ',' + Math.atan2(1,1) + ',' + Math.atan2(-1,-1) + ',' + Math.atan2(0,-0) + ',' + 1/Math.atan2(-0,1) + ',' + Math.atan2(1,0) + ',' + Math.atan2(Infinity,-Infinity)", "0.7853981633974483,0.4636476090008061,1.1071487177940904,1.5707963267948966,0.7853981633974483,-2.356194490192345,3.141592653589793,-Infinity,1.5707963267948966,2.356194490192345"),
    ("Math.asin(1) + ',' + Math.asin(0.5) + ',' + Math.acos(0.5) + ',' + Math.acos(-1) + ',' + Math.acos(1) + ',' + Math.asin(2) + ',' + Math.acos(0)", "1.5707963267948966,0.5235987755982989,1.0471975511965979,3.141592653589793,0,NaN,1.5707963267948966"),
    ("Math.sinh(1) + ',' + Math.cosh(1) + ',' + Math.tanh(1) + ',' + Math.sinh(-0) + ',' + Math.tanh(100) + ',' + Math.cosh(0) + ',' + Math.asinh(1) + ',' + Math.acosh(2) + ',' + Math.atanh(0.5) + ',' + Math.atanh(1) + ',' + Math.acosh(0.5)", "1.1752011936438014,1.5430806348152437,0.7615941559557649,0,1,1,0.881373587019543,1.3169578969248166,0.5493061443340549,Infinity,NaN"),
    ("Math.fround(5.5) + ',' + Math.fround(5.05) + ',' + Math.fround(2**128) + ',' + Math.clz32(1) + ',' + Math.clz32(0) + ',' + Math.clz32(-1) + ',' + Math.imul(0xffffffff, 5) + ',' + Math.imul(2**31, 2) + ',' + Math.imul(3, 4)", "5.5,5.050000190734863,Infinity,31,32,0,-5,0,12"),
    ("var ok = true; for (var i = 0; i < 200; i++) { var r = Math.random(); if (!(r >= 0 && r < 1)) ok = false } ok", "true"),
    ("Math.PI + ',' + Math.E + ',' + Math.LN2 + ',' + Math.SQRT2 + ',' + Math.LOG2E + ',' + Math.SQRT1_2 + ',' + Math.LN10 + ',' + Math.LOG10E", "3.141592653589793,2.718281828459045,0.6931471805599453,1.4142135623730951,1.4426950408889634,0.7071067811865476,2.302585092994046,0.4342944819032518"),
    ("Math.max.length + ',' + Math.hypot.length + ',' + Math.atan2.length + ',' + Object.getOwnPropertyDescriptor(Math, 'PI').writable", "2,2,2,false"),
    // ---- JSON.parse
    ("JSON.parse('{\"a\":[1,2,{\"b\":null}],\"c\":\"x\"}').a[2].b", "null"),
    ("JSON.parse(' [1, 2.5, -3e2, 0, -0, 1E+2, true, false, null, \"s\"] ').join()", "1,2.5,-300,0,0,100,true,false,,s"),
    ("1 / JSON.parse('-0')", "-Infinity"),
    ("JSON.parse('\"\\\\u0041\\\\n\\\\/\\\\\"\"')", "A\n/\""),
    ("JSON.parse('\"\\\\ud83d\\\\ude00\"').length", "2"),
    ("JSON.parse('123456789012345678901234567890')", "1.2345678901234568e+29"),
    ("JSON.parse('0.1') + JSON.parse('1e-7') + ',' + JSON.parse('9007199254740993')", "0.10000010000000001,9007199254740992"),
    ("JSON.parse('{\"__proto__\": 1}').__proto__", "1"),
    ("Object.keys(JSON.parse('{\"b\":1,\"a\":2,\"b\":3}')).join() + JSON.parse('{\"b\":1,\"a\":2,\"b\":3}').b", "b,a3"),
    ("JSON.parse('[1,2,3]', function(k, v){ return typeof v === 'number' ? v * 2 : v }).join()", "2,4,6"),
    ("var log = []; JSON.parse('{\"a\":{\"b\":1},\"c\":[2]}', function(k, v){ log.push(k); return v }); log.join('|')", "b|a|0|c|"),
    ("JSON.parse('{\"a\":1,\"b\":2}', function(k, v){ return k === 'a' ? undefined : v }).hasOwnProperty('a')", "false"),
    ("JSON.parse('5', function(k, v){ return this[''] + 1 })", "6"),
    ("['', '{', '[1,]', '{\"a\":1,}', '01', '1.', '.5', '+1', \"'a'\", '\"a', '\"\\n\"', 'nul', 'tru', '[1 2]', '{a:1}', '1 2', '\"\\\\x\"', '\"\\\\u12\"', 'NaN', 'undefined', '-', '1e', '\\u00a01'].map(function(s){ try { JSON.parse(s); return 'ok' } catch (e) { return e.name[0] } }).join('')", "SSSSSSSSSSSSSSSSSSSSSSS"),
    ("try { JSON.parse('{\"a\":x}') } catch (e) { e.message }", "Unexpected token x in JSON at position 5"),
    ("try { JSON.parse('') } catch (e) { e.message }", "Unexpected end of JSON input"),
    ("var s = ''; for (var i = 0; i < 10000; i++) s += '['; try { JSON.parse(s) } catch (e) { e.name }", "RangeError"),
    ("var s = ''; for (var i = 0; i < 100; i++) s += '['; for (var i = 0; i < 100; i++) s += ']'; JSON.parse(s).length", "1"),
    ("JSON.parse(null) + ',' + JSON.parse(true) + ',' + JSON.parse(12)", "null,true,12"),
    // ---- JSON.stringify
    ("JSON.stringify({a:1,b:[1,2,{c:3}],d:'x',e:null,f:undefined,g:function(){},h:Symbol()})", "{\"a\":1,\"b\":[1,2,{\"c\":3}],\"d\":\"x\",\"e\":null}"),
    ("JSON.stringify([undefined, function(){}, Symbol(), NaN, Infinity, -0])", "[null,null,null,null,null,0]"),
    ("JSON.stringify(undefined) + ',' + JSON.stringify(function(){}) + ',' + JSON.stringify(null) + ',' + JSON.stringify('a\"b\\\\\\n\\u0001') + ',' + JSON.stringify(1e21) + ',' + JSON.stringify(true)", "undefined,undefined,null,\"a\\\"b\\\\\\n\\u0001\",1e+21,true"),
    ("JSON.stringify('\\ud800') + JSON.stringify('\\udc00\\ud800') + JSON.stringify('\\ud83d\\ude00') + JSON.stringify('\\u2028')", "\"\\ud800\"\"\\udc00\\ud800\"\"😀\"\"\u{2028}\""),
    ("JSON.stringify({a:[1,{b:2}],c:{}}, null, 2)", "{\n  \"a\": [\n    1,\n    {\n      \"b\": 2\n    }\n  ],\n  \"c\": {}\n}"),
    ("JSON.stringify([[],{}], null, '--')", "[\n--[],\n--{}\n]"),
    ("JSON.stringify({a:1}, null, 20).length + ',' + JSON.stringify({a:1}, null, 'abcdefghijklmnop').length", "20,20"),
    ("JSON.stringify({a:1,b:2,c:3}, ['c','a','x'])", "{\"c\":3,\"a\":1}"),
    ("JSON.stringify({a:1,b:[1,2]}, function(k, v){ return typeof v === 'number' ? v + 1 : v })", "{\"a\":2,\"b\":[2,3]}"),
    ("JSON.stringify({a:1,b:2}, function(k, v){ return k === 'a' ? undefined : v })", "{\"b\":2}"),
    ("JSON.stringify({toJSON: function(k){ return 'J' + k }}) + JSON.stringify({a:{toJSON: function(k){ return k }}})", "\"J\"{\"a\":\"a\"}"),
    ("JSON.stringify([new Number(1), new String('s'), new Boolean(false)])", "[1,\"s\",false]"),
    ("var a = {}; a.a = a; try { JSON.stringify(a) } catch (e) { e.name }", "TypeError"),
    ("var a = [[]]; a[0][0] = a; try { JSON.stringify(a) } catch (e) { e.name }", "TypeError"),
    ("var o = {}; var p = {x: o, y: o}; JSON.stringify(p)", "{\"x\":{},\"y\":{}}"),
    ("var a = []; for (var i = 0; i < 3000; i++) a = [a]; try { JSON.stringify(a) } catch (e) { e.name }", "RangeError"),
    ("JSON.stringify({[Symbol()]: 1, a: 1})", "{\"a\":1}"),
    ("JSON.stringify(Object.create({inherited: 1}))", "{}"),
    ("JSON.stringify('a', function(k, v){ return v + '!' })", "\"a!\""),
    ("JSON.stringify({a:1}, null, new Number(1))", "{\n \"a\": 1\n}"),
    ("JSON.stringify({1:1, a:2, 0:0})", "{\"0\":0,\"1\":1,\"a\":2}"),
    ("JSON.stringify({a: 0.1 + 0.2, b: 1e-7, c: 123456789012345680000})", "{\"a\":0.30000000000000004,\"b\":1e-7,\"c\":123456789012345680000}"),
    ("JSON[Symbol.toStringTag] + typeof JSON.parse + JSON.stringify.length", "JSONfunction3"),
]

func jsBuiltins1Tests(_ t: Tests) {
    jsB1Run(t, stress: false)
    jsB1Run(t, stress: true)
    jsB1Misc(t)
    jsB1JSONFuzz(t)
}

private func jsB1Run(_ t: Tests, stress: Bool) {
    t.section(stress ? "builtins1 (gcEveryAllocation)" : "builtins1")
    let rt = JSRuntime(limits: JSLimits())
    for (src, want) in jsB1Cases {
        if stress && (jsHas(src, "3000") || jsHas(src, "10000") || jsHas(src, "1e22") || jsHas(src, "1e6")
                      || jsHas(src, "i < 200")) { continue }
        let realm = rt.makeRealm()
        realm.heap.gcEveryAllocation = stress
        t.equal(realm.evaluateToString(src), want, src)
    }
}

private func jsB1Misc(_ t: Tests) {
    t.section("builtins1 misc")
    let rt = JSRuntime(limits: JSLimits())
    let r1 = rt.makeRealm(), r2 = rt.makeRealm(), r3 = rt.makeRealm()
    r1.seedRandom(42); r2.seedRandom(42); r3.seedRandom(43)
    let a = r1.evaluateToString("Math.random() + ',' + Math.random()")
    t.equal(a, r2.evaluateToString("Math.random() + ',' + Math.random()"), "seeded random reproducible")
    t.check(a != r3.evaluateToString("Math.random() + ',' + Math.random()"), "different seed differs")
    let r = rt.makeRealm()
    t.equal(r.evaluateToString("var a = []; for (var i = 0; i < 5000; i++) a.push((i * 7919) % 1009); a.sort(function(x,y){return x-y}); var ok = true; for (var i = 1; i < a.length; i++) if (a[i-1] > a[i]) ok = false; ok"), "true", "sort 5000 numbers")
    t.equal(r.evaluateToString("var a = []; for (var i = 0; i < 3000; i++) a.push(i); a.sort(); a[1] + ',' + a[2] + ',' + a[10] + ',' + a[2999]"), "1,10,1006,999", "default sort is by string")
    let rt2 = JSRuntime(limits: JSLimits.small)
    var n = 0
    rt2.interruptHandler = { _ in n += 1; return n > 50 }
    let r4 = rt2.makeRealm()
    t.equal(r4.evaluateToString("var o = {length: 2**53 - 1}; Array.prototype.fill.call(o, 1); 'done'"), "terminated: interrupted", "native loop is interruptible")
    let rt3 = JSRuntime(limits: JSLimits.small)
    let r5 = rt3.makeRealm()
    t.equal(r5.evaluateToString("try { new Array(-1) } catch (e) { e.name }"), "RangeError", "bad array length")
    // Math identities over a range (a wrong constant shows up as a large error).
    var worst = 0.0
    var x = 0.001
    while x < 1000 {
        let e = jsMathExp(jsMathLog(x))
        worst = max(worst, ((e - x) / x).magnitude)
        let s = jsMathSin(x), c = jsMathCos(x)
        worst = max(worst, (s * s + c * c - 1).magnitude)
        worst = max(worst, ((jsMathTan(x) - s / c) / jsMathTan(x)).magnitude)
        worst = max(worst, ((jsMathAtan(jsMathTan(0.001 * x)) - 0.001 * x) / (0.001 * x)).magnitude)
        let p = jsMathPowAccurate(x, 0.5)
        worst = max(worst, ((p - x.squareRoot()) / p).magnitude)
        worst = max(worst, ((jsMathExp(jsMathLog2(x) * 0.6931471805599453) - x) / x).magnitude)
        x *= 1.0137
    }
    t.check(worst < 4e-15, "math identities", "worst \(worst)")
}

private func jsB1JSONFuzz(_ t: Tests) {
    t.section("builtins1 JSON fuzz")
    let seeds: [[UInt8]] = [
        Array("{\"a\":[1,2.5e3,{\"b\":null}],\"c\":\"x\\u0041\\n\",\"d\":true}".utf8),
        Array("[[[[1,-0,0.5]]],\"\\ud83d\\ude00\",{\"\":{}}]".utf8),
        Array("  {\"k\" : [ ] , \"z\":{\"y\":[false,null]}}".utf8),
    ]
    let rt = JSRuntime(limits: JSLimits.small)
    let realm = rt.makeRealm()
    _ = realm.evaluateToString("this.__fz = function(s){ try { return JSON.stringify(JSON.parse(s)) } catch (e) { return e.name } }")
    t.fuzz("json parse", seeds: seeds, iterations: 6000) { bytes in
        let h = realm.heap
        let depth = h.rootDepth
        defer { h.popRoots(to: depth) }
        let s = h.newString(latin1: bytes)
        _ = h.root(s)
        let g = realm.global
        let f = h.getOwnProperty(g, h.key("__fz"))?.value ?? .undefined
        if h.isCallable(f) { _ = try? realm.call(f, this: .undefined, args: [s]) }
    }
    t.check(true, "json fuzz completed")
}
