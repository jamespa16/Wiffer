// Host tests for the rest of Phase 9E: mapped arguments objects, BigInt
// (arithmetic vectors, operators, conversions, typed arrays), a BigInt
// fuzz against fixed reference vectors, Intl, and structuredClone. Every
// script case runs again under gcEveryAllocation.

let jsBuiltins4ArgumentsCases: [(String, String)] = [
    ("function f(a) { arguments[0] = 9; return a } f(1)", "9"),
    ("function f(a) { a = 7; return arguments[0] } f(1)", "7"),
    ("function f(a, b) { b = 5; return arguments.length + ',' + arguments[1] } f(1)", "1,undefined"),
    ("function f(a, b) { arguments[1] = 5; return b } f(1)", "undefined"),
    ("function f(a, b) { arguments[1] = 5; return b } f(1, 2)", "5"),
    ("function f(a) { 'use strict'; arguments[0] = 9; return a } f(1)", "1"),
    ("function f(a = 0) { arguments[0] = 9; return a } f(1)", "1"),
    ("function f(a) { delete arguments[0]; arguments[0] = 9; return a } f(1)", "1"),
    ("function f(a) { Object.defineProperty(arguments, '0', {value: 3}); return a } f(1)", "3"),
    ("function f(a) { Object.defineProperty(arguments, '0', {writable: false}); a = 4; return arguments[0] } f(1)", "1"),
    ("function f(a) { Object.defineProperty(arguments, '0', {value: 8, writable: false}); a = 4; return arguments[0] + ',' + a } f(1)", "8,4"),
    ("function f(a) { Object.defineProperty(arguments, '0', {get() { return 5 }}); a = 4; return arguments[0] } f(1)", "5"),
    ("function f(a) { var d = Object.getOwnPropertyDescriptor(arguments, '0'); a = 2; return d.value + ',' + Object.getOwnPropertyDescriptor(arguments, '0').value } f(1)", "1,2"),
    ("function f(a) { return function () { a = 6; return arguments[0] }() } f(1)", "undefined"),
    ("function f(a) { var g = function () { a = 6 }; g(); return arguments[0] } f(1)", "6"),
    ("function f(a, a2) { return Object.keys(arguments).join() } f(1, 2)", "0,1"),
    ("function f(a, a) { a = 3; return arguments[0] + ',' + arguments[1] } f(1, 2)", "1,3"),
    ("function f(a) { arguments.length = 0; a = 5; return arguments[0] } f(1)", "5"),
    ("function f(a) { var args = arguments; return (function () { args[0] = 'x'; return a })() } f(1)", "x"),
    ("function f(a) { eval('a = 11'); return arguments[0] } f(1)", "11"),
    ("function f(a) { arguments[0] = 2; return Object.getOwnPropertyDescriptor(arguments, '0').value } f(1)", "2"),
    ("function f(a) { Object.freeze(arguments); a = 5; return arguments[0] } f(1)", "1"),
    ("function f(a) { return Object.prototype.toString.call(arguments) } f(1)", "[object Arguments]"),
    ("function f(a, b) { arguments[0] = 3; return [...arguments].join() } f(1, 2)", "3,2"),
    ("function f(a, b, c) { a = 1; return arguments.length + ',' + arguments[2] } f(5)", "1,undefined"),
    ("function* g(a) { arguments[0] = 4; yield a } g(1).next().value", "4"),
    ("var o = { m(a) { a = 3; return arguments[0] } }; o.m(1)", "3"),
    ("function f(a) { return (() => { arguments[0] = 5; return a })() } f(1)", "5"),
    ("function f(a) { 'use strict'; a = 3; return arguments[0] } f(1)", "1"),
]

func jsBuiltins4Tests(_ t: Tests) {
    if let path = jsTest262Env("WIFFER_JS_EVAL4"), let src = hostReadFile(path) {
        let realm = JSRuntime().makeRealm()
        print("WIFFER_JS_EVAL4: " + realm.evaluateToString(String(decoding: src, as: UTF8.self)))
    }
    jsBuiltins4Scripts(t, stress: false)
    jsBuiltins4Scripts(t, stress: true)
}

func jsBuiltins4Scripts(_ t: Tests, stress: Bool) {
    t.section(stress ? "9E tail scripts (gcEveryAllocation)" : "9E tail scripts")
    let rt = JSRuntime(limits: JSLimits())
    var all = jsBuiltins4ArgumentsCases
    all += jsBuiltins4BigIntCases
    all += jsBuiltins4IntlCases
    for (src, want) in all {
        let realm = rt.makeRealm()
        realm.heap.gcEveryAllocation = stress
        t.equal(realm.evaluateToString(src), want, src)
    }
}
