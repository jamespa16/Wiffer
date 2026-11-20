// Host tests for the String / RegExp / Symbol / Date built-ins (Phase 9C).
// Scripts run in a fresh realm after a small prelude (J joins an array
// with "|"); each is run again with a GC at every allocation.

let jsBuiltins2Prelude = "function J(a){var s='';for(var i=0;i<a.length;i++){s+=(i?'|':'')+a[i]}return s}"

let jsBuiltins2Cases: [(String, String)] = [
    // String basics.
    ("'abc'.at(-1) + 'abc'.at(5)", "cundefined"),
    ("'abc'.charAt(1) + '|' + 'abc'.charAt(9) + '|' + 'abc'.charCodeAt(1) + '|' + 'abc'.charCodeAt(9)", "b||98|NaN"),
    ("'\\ud83d\\ude00'.codePointAt(0) + ',' + '\\ud83d\\ude00'.codePointAt(1) + ',' + 'a'.codePointAt(3)", "128512,56832,undefined"),
    ("'a'.concat('b', 1, null)", "ab1null"),
    ("'abcdef'.slice(-3, -1) + '|' + 'abcdef'.slice(2) + '|' + 'abcdef'.substring(4, 1) + '|' + 'abcdef'.substr(-3, 2)", "de|cdef|bcd|de"),
    ("'abc'.repeat(3) + '|' + 'x'.repeat(0)", "abcabcabc|"),
    ("try { 'x'.repeat(-1) } catch (e) { e.name }", "RangeError"),
    ("try { 'x'.repeat(2 ** 30) } catch (e) { e.name }", "RangeError"),
    ("'5'.padStart(3, '0') + '|' + 'abc'.padEnd(8, '12') + '|' + 'abc'.padStart(2)", "005|abc12121|abc"),
    ("'  a b \\n'.trim() + '|' + ' x '.trimStart() + '|' + ' x '.trimEnd() + '|'", "a b|x | x|"),
    ("String.prototype.trimLeft === String.prototype.trimStart", "true"),
    ("'abcabc'.indexOf('c') + ',' + 'abcabc'.indexOf('c', 3) + ',' + 'abcabc'.lastIndexOf('c') + ',' + 'abcabc'.lastIndexOf('c', 4) + ',' + 'abc'.indexOf('') + ',' + 'abc'.indexOf('', 9) + ',' + 'abc'.lastIndexOf('')", "2,5,5,2,0,3,3"),
    ("var s = 'ab'.repeat(5000) + 'c'; s.indexOf('abababababababababc') + ',' + ('a'.repeat(100000) + 'b').indexOf('a'.repeat(50000) + 'b') + ',' + s.lastIndexOf('abababababababababab')", "9982,50000,9980"),
    ("'abc'.includes('b') + ',' + 'abc'.startsWith('b', 1) + ',' + 'abc'.endsWith('b', 2) + ',' + 'abc'.endsWith('')", "true,true,true,true"),
    ("try { 'a'.includes(/a/) } catch (e) { e.name }", "TypeError"),
    ("'a'.localeCompare('b') + ',' + 'b'.localeCompare('a') + ',' + 'a'.localeCompare('a') + ',' + 'a\\u0308'.localeCompare('\\u00e4')", "-1,1,0,0"),
    ("'\\ud800'.isWellFormed() + ',' + 'ab'.isWellFormed() + ',' + ('a\\ud800').toWellFormed().charCodeAt(1)", "false,true,65533"),
    ("String.fromCharCode(72, 105, 0x10041) + String.fromCodePoint(0x1F600).length", "HiA2"),
    ("try { String.fromCodePoint(-1) } catch (e) { e.name }", "RangeError"),
    ("String.raw`a${1}b\\n${2}c`", "a1b\\n2c"),
    ("String.raw({raw: ['x', 'y', 'z']}, 1, 2, 3)", "x1y2z"),
    ("'a'.anchor('x\"y') + 'b'.bold() + 'c'.fontsize(3) + 'd'.sup()", "<a name=\"x&quot;y\">a</a><b>b</b><font size=\"3\">c</font><sup>d</sup>"),
    ("J([...'a\\ud83d\\ude00b'])", "a|\u{1F600}|b"),
    // Case mapping and normalization.
    ("'Stra\\u00dfe'.toUpperCase() + '|' + 'ABC'.toLowerCase() + '|' + '\\u0130'.toLowerCase().length + '|' + '\\ufb01'.toUpperCase()", "STRASSE|abc|2|FI"),
    ("'\\u03a3'.toLowerCase() + ',' + 'A\\u03a3'.toLowerCase() + ',' + 'A\\u03a3B'.toLowerCase() + ',' + 'A.\\u03a3'.toLowerCase()", "\u{3C3},a\u{3C2},a\u{3C3}b,a.\u{3C2}"),
    ("'\\ud801\\udc00'.toLowerCase().codePointAt(0).toString(16) + ',' + '\\ud801\\udc28'.toUpperCase().codePointAt(0).toString(16)", "10428,10400"),
    ("'\\u00e9'.normalize('NFD').length + ',' + 'e\\u0301'.normalize().length + ',' + '\\ufb01'.normalize('NFKC') + ',' + '\\u1e9b\\u0323'.normalize('NFC').length + ',' + '\\u1e9b\\u0323'.normalize('NFD').length + ',' + '\\u1e9b\\u0323'.normalize('NFKD').length", "2,1,fi,2,3,3"),
    ("'\\uac01'.normalize('NFD').length + ',' + '\\u1100\\u1161\\u11a8'.normalize('NFC').charCodeAt(0).toString(16) + ',' + 'a\\u0323\\u0307'.normalize('NFC').length + ',' + 'a\\u0307\\u0323'.normalize('NFC').length", "3,ac01,2,2"),
    ("try { 'a'.normalize('x') } catch (e) { e.name }", "RangeError"),
    // Symbol.
    ("var a = Symbol.for('k'); (a === Symbol.for('k')) + ',' + Symbol.keyFor(a) + ',' + Symbol.keyFor(Symbol('k')) + ',' + Symbol.keyFor(Symbol.iterator)", "true,k,undefined,undefined"),
    ("Symbol('d').description + ',' + Symbol().description + ',' + Symbol('d').toString() + ',' + Object(Symbol('w')).description", "d,undefined,Symbol(d),w"),
    ("var s = Symbol('v'); (s.valueOf() === s) + ',' + (Object(s)[Symbol.toPrimitive]() === s) + ',' + Object.prototype.toString.call(s)", "true,true,[object Symbol]"),
    ("try { Symbol.keyFor('x') } catch (e) { e.name }", "TypeError"),
    // RegExp basics.
    ("var r = /a(b)?c/g; var m = r.exec('xacabc'); m[0] + ',' + m[1] + ',' + m.index + ',' + r.lastIndex + ',' + m.input + ',' + m.groups", "ac,undefined,1,3,xacabc,undefined"),
    ("var r = /(?<y>\\d{4})-(?<m>\\d\\d)/; var m = r.exec('on 2026-11'); m.groups.y + m.groups.m + ',' + m.index", "202611,3"),
    ("var m = /b(c)/d.exec('abcd'); J(m.indices[0]) + ',' + J(m.indices[1]) + ',' + m.indices.groups", "1|3,2|3,undefined"),
    ("var r = /a/y; r.lastIndex = 1; var x = r.test('ba'); x + ',' + r.lastIndex + ',' + r.test('ba') + ',' + r.lastIndex", "true,2,false,0"),
    ("/a/gimsuyd.flags + ',' + /a/.flags + ',' + /a/g.global + ',' + /a/.sticky + ',' + /a/v.unicodeSets + ',' + /[/]\\//.source + ',' + new RegExp('/').source + ',' + new RegExp('').source", "dgimsuy,,true,false,true,[/]\\/,\\/,(?:)"),
    ("new RegExp('a\\nb').source + ',' + String(/x/gi) + ',' + RegExp.prototype.toString.call({source: 'S', flags: 'F'})", "a\\nb,/x/gi,/S/F"),
    ("var r = /a/g; var q = new RegExp(r); var p = new RegExp(r, 'i'); (q !== r) + ',' + q.flags + ',' + p.flags + ',' + (RegExp(r) === r)", "true,g,i,true"),
    ("try { new RegExp('(') } catch (e) { e.name }", "SyntaxError"),
    ("try { new RegExp('a', 'gg') } catch (e) { e.name }", "SyntaxError"),
    ("Object.prototype.toString.call(/x/) + ',' + (/x/ instanceof RegExp) + ',' + RegExp.prototype.source + ',' + RegExp.prototype.global", "[object RegExp],true,(?:),undefined"),
    ("try { RegExp.prototype.exec.call({}, 'a') } catch (e) { e.name }", "TypeError"),
    ("var r = /a/; r.compile('b', 'g'); r.source + r.flags + r.test('b')", "bgtrue"),
    ("RegExp[Symbol.species] === RegExp", "true"),
    // Unicode mode and lastIndex.
    ("var r = /./gu; var s = '\\ud83d\\ude00x'; var o = []; while (r.exec(s) && o.length < 9) { o.push(r.lastIndex); }; J(o)", "2|3"),
    ("var r = /(?:)/g; var s = '\\ud83d\\ude00'; J(s.match(r))+ ',' + J(s.match(/(?:)/gu)) + ',' + J(s.match(/./gu)).length", "||,|,2"),
    ("'\\ud83d\\ude00'.replace(/(?:)/gu, '-') + ',' + '\\ud83d\\ude00'.replace(/(?:)/g, '-').length", "-\u{1F600}-,5"),
    ("/\\ud83d/u.test('\\ud83d\\ude00') + ',' + /\\ud83d/.test('\\ud83d\\ude00') + ',' + /^.$/u.test('\\ud83d\\ude00') + ',' + /^.$/.test('\\ud83d\\ude00')", "false,true,true,false"),
    // match / matchAll / search.
    ("J('a1b22c333'.match(/\\d+/g)) + ',' + 'abc'.match(/x/g) + ',' + J('abc'.match(/(b)/)) + ',' + 'abc'.match('b').index", "1|22|333,null,b|b,1"),
    ("var o = []; for (var m of 'a1b22'.matchAll(/\\d+/g)) o.push(m[0] + '@' + m.index); J(o)", "1@1|22@3"),
    ("try { 'a'.matchAll(/a/) } catch (e) { e.name }", "TypeError"),
    ("Object.prototype.toString.call('a'.matchAll(/a/g)) + ',' + 'abc'.search(/c/) + ',' + 'abc'.search('z')", "[object RegExp String Iterator],2,-1"),
    // replace.
    ("'abc'.replace('b', '[$&|$`|$\\'|$$]')", "a[b|a|c|$]c"),
    ("'abcabc'.replace(/b/g, '<$&>') + ',' + 'abc'.replace(/(a)(b)?/, '$2$1$3$01$10') + ',' + 'abc'.replace(/(?<x>b)/, '[$<x>][$<y>][$<x]')", "a<b>ca<b>c,ba$3aa0c,a[b][][$<x]c"),
    ("'abc'.replace(/(b)/, function (m, p1, off, str) { return '(' + m + p1 + off + str + ')' }) + ',' + 'aXbX'.replace(/x/gi, function () { return arguments.length })", "a(bb1abc)c,a3b3"),
    ("'abc'.replace(/(?<n>b)/, function () { return typeof arguments[arguments.length - 1] + arguments[arguments.length - 1].n })", "aobjectbc"),
    ("'aaa'.replaceAll('a', 'b') + ',' + 'abab'.replaceAll(/b/g, 'X') + ',' + 'ab'.replaceAll('', '-') + ',' + 'abc'.replaceAll('b', (m, p) => p)", "bbb,aXaX,-a-b-,a1c"),
    ("try { 'a'.replaceAll(/a/, 'b') } catch (e) { e.name }", "TypeError"),
    ("'x'.replace('x', '$0$1') + ',' + 'abc'.replace(/(.)/g, '$1$1')", "$0$1,aabbcc"),
    ("var r = /a/g; r.lastIndex = 5; 'aa'.replace(r, 'b') + r.lastIndex", "bb0"),
    // split.
    ("J('a,b,,c'.split(',')) + ';' + J('abc'.split('')) + ';' + J('abc'.split()) + ';' + J(''.split(',')) + ';' + J(''.split('')).length + ';' + J('a,b,c'.split(',', 2))", "a|b||c;a|b|c;abc;;0;a|b"),
    ("J('a1b2c'.split(/\\d/)) + ';' + J('a1b2c'.split(/(\\d)/)) + ';' + J('abc'.split(/(?:)/)) + ';' + J('abc'.split(/b/, 1)) + ';' + J(''.split(/a/)) + ';' + ''.split(/(?:)/).length", "a|b|c;a|1|b|2|c;a|b|c;a;;0"),
    ("J('\\ud83d\\ude00a'.split(/(?:)/u)).length + ',' + '\\ud83d\\ude00a'.split(/(?:)/).length + ',' + J('test'.split(/(?=s)/)) + ',' + J('ab'.split(/a*?/)) + ',' + J('ab'.split(/a*/))", "4,3,te|st,a|b,|b"),
    ("var c = 0; class R extends RegExp { exec(s) { c++; return super.exec(s) } }; J('a-b'.split(new R('-'))) + ',' + (c > 0)", "a|b,true"),
    ("var r = /-/; r.constructor = {[Symbol.species]: function (p, f) { return new RegExp(p, f + 'g') }}; J('a-b-c'.split(r))", "a|b|c"),
    // exec overriding and custom Symbol methods.
    ("var r = /a/; r.exec = function () { return null }; r.test('a') + ',' + 'a'.replace(r, 'b')", "false,a"),
    ("var o = {[Symbol.replace](s, r) { return 'R' + s + r }, [Symbol.split](s, l) { return 'S' + s + l }, [Symbol.search](s) { return 'Q' + s }, [Symbol.match](s) { return 'M' + s }}; 'x'.replace(o, 'y') + 'x'.split(o, 3) + 'x'.search(o) + 'x'.match(o)", "RxySx3QxMx"),
    // ReDoS and limits.
    ("/(a+)+$/.test('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab')", "terminated: regex steps"),
    ("try { /(a+)+$/.test('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab') } catch (e) { 'caught' }", "terminated: regex steps"),
    ("/(?:)/ instanceof Object", "true"),
    // Date.
    ("new Date(0).toISOString() + ',' + new Date(2026, 10, 19, 14, 5, 6, 7).getTime() + ',' + Date.UTC(2026, 10, 19) + ',' + Date.UTC(99, 0)", "1970-01-01T00:00:00.000Z,1795097106007,1795046400000,915148800000"),
    ("new Date(NaN).getTime() + ',' + new Date('x').getFullYear() + ',' + String(new Date(NaN)) + ',' + new Date(NaN).toJSON()", "NaN,NaN,Invalid Date,null"),
    ("try { new Date(NaN).toISOString() } catch (e) { e.name }", "RangeError"),
    ("Date.now() + ',' + new Date().getTime() + ',' + typeof Date() + ',' + Date.length + ',' + Date.UTC.length", "0,0,string,7,7"),
    ("var d = new Date(Date.UTC(2020, 0, 31)); d.setUTCMonth(1); d.toISOString()", "2020-03-02T00:00:00.000Z"),
    ("var d = new Date(0); d.setUTCDate(0); d.setUTCHours(25, 61, 61, 1001); d.toISOString()", "1970-01-01T02:02:02.001Z"),
    ("var d = new Date(NaN); var r = d.setFullYear(2000); r + ',' + d.toISOString() + ',' + new Date(NaN).setMonth(1)", "946684800000,2000-01-01T00:00:00.000Z,NaN"),
    ("var d = new Date(8.64e15); d.setUTCMilliseconds(1); d.getTime() + ',' + new Date(8.64e15 + 1).getTime() + ',' + new Date(-8.64e15).getUTCFullYear()", "NaN,NaN,-271821"),
    ("var d = new Date(Date.UTC(2020, 5, 15, 12, 30, 45, 123)); J([d.getUTCDay(), d.getDay(), d.getUTCHours(), d.getMinutes(), d.getSeconds(), d.getMilliseconds(), d.getTimezoneOffset(), d.getYear()])", "1|1|12|30|45|123|0|120"),
    ("var d = new Date(0); d.setYear(99); d.getFullYear() + ',' + d.setYear(NaN) + ',' + Date.prototype.toGMTString === Date.prototype.toUTCString", "false"),
    ("new Date(0).toString() + '|' + new Date(0).toUTCString() + '|' + new Date(0).toDateString() + '|' + new Date(0).toLocaleString()", "Thu Jan 01 1970 00:00:00 GMT+0000 (Coordinated Universal Time)|Thu, 01 Jan 1970 00:00:00 GMT|Thu Jan 01 1970|1/1/1970, 12:00:00 AM"),
    ("Date.parse('2026-11-19T10:00:00Z') + ',' + Date.parse('Thu, 01 Jan 1970 00:00:01 GMT') + ',' + Date.parse('nope')", "1795082400000,1000,NaN"),
    ("new Date(new Date(5)).getTime() + ',' + new Date('1970-01-01T00:00:00.005Z').getTime() + ',' + new Date(2020, 0).getTime() + ',' + new Date(70, 0).getFullYear()", "5,5,1577836800000,1970"),
    ("var d = new Date(7); (d + 1) + ',' + (d - 1) + ',' + (d[Symbol.toPrimitive]('number')) + ',' + JSON_ok", "Uncaught ReferenceError: JSON_ok is not defined"),
    ("var d = new Date(7); d[Symbol.toPrimitive]('default').slice(0, 3) + (d - 1) + (+d)", "Thu67"),
    ("try { Date.prototype.getTime.call({}) } catch (e) { e.name }", "TypeError"),
    ("Object.prototype.toString.call(new Date(0)) + ',' + new Date(0).toJSON() + ',' + Date.prototype.toJSON.call({toISOString() { return 'z' }, valueOf() { return 1 }})", "[object Date],1970-01-01T00:00:00.000Z,z"),
]

func jsBuiltins2Tests(_ t: Tests) {
    t.section("builtins2")
    for stress in [false, true] {
        if stress { t.section("builtins2 (gcEveryAllocation)") }
        for (src, want) in jsBuiltins2Cases {
            let realm = JSRuntime().makeRealm()
            _ = realm.evaluate(source: jsBuiltins2Prelude)
            realm.heap.gcEveryAllocation = stress
            t.equal(realm.evaluateToString(src), want, src)
        }
    }
    t.section("builtins2 clock")
    let rt = JSRuntime()
    let realm = rt.makeRealm()
    realm.nowMs = { 1_000_000 }
    t.equal(realm.evaluateToString("Date.now() + ',' + new Date().toISOString()"), "1000000,1970-01-01T00:16:40.000Z", "nowMs hook")
    // The step budget terminates ReDoS; the realm is reusable afterwards.
    t.equal(realm.evaluateToString("/(a+)+$/.test('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab')"), "terminated: regex steps", "redos terminated")
    t.equal(realm.evaluateToString("'ok'"), "ok", "realm usable after regex termination")
}
