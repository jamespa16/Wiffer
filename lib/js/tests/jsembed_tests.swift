// Host tests for Phase 9F: console / jsInspect / jsFormat and JSEventLoop.

/// Run `src` in a fresh realm with console installed; returns the lines
/// the sink saw ("L:" log, "W:" warn, "E:" error prefixes only when asked).
func jsEmbedRun(_ src: String, gc: Bool = false, tagLevels: Bool = false) -> [String] {
    let rt = JSRuntime(limits: JSLimits.small)
    let realm = rt.makeRealm()
    realm.heap.gcEveryAllocation = gc
    var lines: [String] = []
    jsInstallConsole(realm, now: { 0 }) { level, text in
        if tagLevels {
            let p: String
            switch level {
            case .log: p = "log"
            case .info: p = "info"
            case .debug: p = "debug"
            case .warn: p = "warn"
            case .error: p = "error"
            }
            lines.append(p + ":" + text)
        } else { lines.append(text) }
    }
    switch realm.evaluate(source: src, name: "t") {
    case .exception(let e): lines.append("!" + e.message)
    case .terminated: lines.append("!terminated")
    case .normal: break
    }
    return lines
}

func jsEmbedInspect(_ src: String, gc: Bool = false) -> String {
    let rt = JSRuntime(limits: JSLimits.small)
    let realm = rt.makeRealm()
    realm.heap.gcEveryAllocation = gc
    switch realm.evaluate(source: src, name: "t") {
    case .normal(let v):
        let d = realm.heap.rootDepth
        _ = realm.heap.root(v)
        let s = jsInspect(realm, v)
        realm.heap.popRoots(to: d)
        return s
    case .exception(let e): return "!" + e.message
    case .terminated: return "!terminated"
    }
}

func jsEqLines(_ t: Tests, _ got: [String], _ want: [String], _ label: String) {
    var g = "", w = ""
    for l in got { g += "[" + l + "]" }
    for l in want { w += "[" + l + "]" }
    t.check(got == want, label, "got " + g + " want " + w)
}

let jsInspectCases: [(String, String)] = [
    ("1", "1"), ("-0", "-0"), ("'a'", "'a'"), ("\"it's\"", "\"it's\""), ("'a\\nb'", "'a\\nb'"),
    ("undefined", "undefined"), ("null", "null"), ("true", "true"), ("Symbol('x')", "Symbol(x)"),
    ("[]", "[]"), ("({})", "{}"), ("[1, 2, 3]", "[ 1, 2, 3 ]"),
    ("({a: 1, b: 'x', 'c-d': null})", "{ a: 1, b: 'x', 'c-d': null }"),
    ("({a: {b: {c: {d: 1}}}})", "{ a: { b: { c: [Object] } } }"),
    ("[[[[1]]]]", "[ [ [ [Array] ] ] ]"),
    ("[1, , 3]", "[ 1, <1 empty item>, 3 ]"),
    ("[, , ,]", "[ <3 empty items> ]"),
    ("function f() {}; f", "[Function: f]"),
    ("(function () {})", "[Function (anonymous)]"),
    ("class A {}; A", "[class A]"),
    ("class A {}; class B extends A {}; B", "[class B extends A]"),
    ("class A { constructor() { this.x = 1 } }; new A()", "A { x: 1 }"),
    ("Object.create(null)", "[Object: null prototype] {}"),
    ("var o = {}; o.self = o; o", "<ref *1> { self: [Circular *1] }"),
    ("({get a() { return 1 }, set b(v) {}, get c() { return 1 }, set c(v) {}})", "{ a: [Getter], b: [Setter], c: [Getter/Setter] }"),
    ("new Error('boom').message", "'boom'"),
    ("new Date(0)", "1970-01-01T00:00:00.000Z"),
    ("/a+b/gi", "/a+b/gi"),
    ("new Map([[1, 'a'], ['k', {x: 1}]])", "Map(2) { 1 => 'a', 'k' => { x: 1 } }"),
    ("new Set([1, 2, 'x'])", "Set(3) { 1, 2, 'x' }"),
    ("new Map()", "Map(0) {}"),
    ("Promise.resolve(4)", "Promise { 4 }"),
    ("new Promise(() => {})", "Promise { <pending> }"),
    ("var p = Promise.reject(1); p.catch(() => {}); p", "Promise { <rejected> 1 }"),
    ("new Number(3)", "[Number: 3]"),
    ("new String('s')", "[String: 's']"),
    ("[1.5, 'a', null, undefined]", "[ 1.5, 'a', null, undefined ]"),
    ("({[Symbol('k')]: 1})", "{ [Symbol(k)]: 1 }"),
    ("var a = [1, 2]; a.extra = 3; a", "[ 1, 2, extra: 3 ]"),
    ("Array.from({length: 120}, (_, i) => i)",
     "[\n   0,  1,  2,  3,  4,  5,  6,  7,  8,  9, 10, 11,\n  12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,\n  24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35,\n  36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47,\n  48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59,\n  60, 61, 62, 63, 64, 65, 66, 67, 68, 69, 70, 71,\n  72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83,\n  84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95,\n  96, 97, 98, 99,\n  ... 20 more items\n]"),
    ("({aaaaaaaaaaaa: 'bbbbbbbbbbbbbbbbbbbb', cccccccccccc: 'dddddddddddddddddddd', eeeeeeeeeeee: 'ffffffffffffffffffff'})",
     "{\n  aaaaaaaaaaaa: 'bbbbbbbbbbbbbbbbbbbb',\n  cccccccccccc: 'dddddddddddddddddddd',\n  eeeeeeeeeeee: 'ffffffffffffffffffff'\n}"),
]

func jsEmbedTests(_ t: Tests) {
    t.section("9F console and inspect")
    for (src, want) in jsInspectCases {
        t.equal(jsEmbedInspect(src), want, "inspect: \(src)")
    }
    // A deep, cyclic graph under GC stress.
    t.equal(jsEmbedInspect("var o = {a: [1, {b: 2}]}; o.a.push(o); o", gc: true),
            "<ref *1> { a: [ 1, { b: 2 }, [Circular *1] ] }", "inspect under GC stress")
    t.check(jsEmbedInspect("new Error('boom')").hasPrefix("Error: boom"), "inspect error prints its stack")

    jsEqLines(t, jsEmbedRun("console.log('a', 1, {x: 2}, [3])"), ["a 1 { x: 2 } [ 3 ]"], "log joins arguments")
    jsEqLines(t, jsEmbedRun("console.log('%s|%d|%i|%f|%j|%%|%c.|%o|%O', 'x', '42.5', 42.9, '1.5e1', {a: 1}, 'css', [1], {b: 2})"),
            ["x|42.5|42|15|{\"a\":1}|%|.|[ 1 ]|{ b: 2 }"], "format specifiers")
    jsEqLines(t, jsEmbedRun("console.log('%s', 'a', 'b', 3)"), ["a b 3"], "extra arguments are appended")
    jsEqLines(t, jsEmbedRun("console.log('%d%%', 5); console.log('100%', 1); console.log('%s')"), ["5%", "100% 1", "%s"], "percent edge cases")
    jsEqLines(t, jsEmbedRun("console.log(); console.log('')"), ["", ""], "empty log")
    jsEqLines(t, jsEmbedRun("console.warn('w'); console.error('e'); console.info('i'); console.debug('d')", tagLevels: true),
            ["warn:w", "error:e", "info:i", "debug:d"], "levels")
    jsEqLines(t, jsEmbedRun("console.assert(true, 'no'); console.assert(false, 'yes %s', 'x'); console.assert(0)", tagLevels: true),
            ["error:Assertion failed: yes x", "error:Assertion failed"], "assert")
    jsEqLines(t, jsEmbedRun("console.count(); console.count(); console.count('k'); console.countReset(); console.count()"),
            ["default: 1", "default: 2", "k: 1", "default: 1"], "count")
    jsEqLines(t, jsEmbedRun("console.group('G'); console.log('a\\nb'); console.group(); console.log('c'); console.groupEnd(); console.groupEnd(); console.log('d')"),
            ["G", "  a\n  b", "    c", "d"], "group indents")
    jsEqLines(t, jsEmbedRun("console.time('t'); console.timeEnd('t'); console.timeEnd('t')", tagLevels: true),
            ["log:t: 0ms", "warn:Timer 't' does not exist"], "time")
    jsEqLines(t, jsEmbedRun("console.table([{a: 1, b: 'x'}, {a: 2}])"),
            ["\u{250C}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{252C}\u{2500}\u{2500}\u{2500}\u{252C}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2510}\n"
             + "\u{2502} (index) \u{2502} a \u{2502}  b  \u{2502}\n"
             + "\u{251C}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{253C}\u{2500}\u{2500}\u{2500}\u{253C}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2524}\n"
             + "\u{2502}    0    \u{2502} 1 \u{2502} 'x' \u{2502}\n"
             + "\u{2502}    1    \u{2502} 2 \u{2502}     \u{2502}\n"
             + "\u{2514}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2534}\u{2500}\u{2500}\u{2500}\u{2534}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2518}"],
            "table")
    jsEqLines(t, jsEmbedRun("console.log([1,2,3].map(x => x * 2), 'é\\u{1F600}')", gc: true), ["[ 2, 4, 6 ] é\u{1F600}"], "log under GC stress")

    jsEventLoopTests(t)
}

// MARK: Event loop

final class JSLoopClock {
    var now = 0.0
}

func jsLoopRun(_ src: String, steps: [Double] = [], gc: Bool = false, rejections: Bool = false) -> [String] {
    let rt = JSRuntime(limits: JSLimits.small)
    let realm = rt.makeRealm()
    realm.heap.gcEveryAllocation = gc
    let clock = JSLoopClock()
    let loop = JSEventLoop(realm: realm, clock: { clock.now })
    var lines: [String] = []
    jsInstallConsole(realm, now: { clock.now }) { _, text in lines.append(text) }
    loop.reportException = { e in lines.append("!" + e.message) }
    loop.reportRejection = { text in if rejections { lines.append(text.hasPrefix("Uncaught (in promise) Error: nope") ? "Uncaught (in promise) Error: nope" : text) } }
    switch realm.evaluate(source: src, name: "t") {
    case .exception(let e): lines.append("!" + e.message)
    default: break
    }
    loop.performMicrotaskCheckpoint()
    loop.runDueTasks()
    var guardN = 0
    while let d = loop.nextDeadline(), guardN < 1000 {
        guardN += 1
        clock.now += max(d, 0)
        loop.runDueTasks()
    }
    return lines
}

func jsEventLoopTests(_ t: Tests) {
    t.section("9F event loop")
    jsEqLines(t, jsLoopRun("setTimeout(() => console.log('b'), 20); setTimeout(() => console.log('a'), 10); console.log('s')"),
            ["s", "a", "b"], "timers run in due order")
    jsEqLines(t, jsLoopRun("setTimeout(() => console.log(1), 0); setTimeout(() => console.log(2), 0); queueMicrotask(() => console.log('m'))"),
            ["m", "1", "2"], "microtasks run before timers, equal timers in creation order")
    jsEqLines(t, jsLoopRun("setTimeout((a, b) => console.log(a + b), 1, 'x', 'y')"), ["xy"], "timer arguments")
    jsEqLines(t, jsLoopRun("var n = 0; var id = setInterval(() => { console.log('i' + ++n); if (n == 3) clearInterval(id) }, 10)"),
            ["i1", "i2", "i3"], "interval and clearInterval")
    jsEqLines(t, jsLoopRun("var id = setTimeout(() => console.log('no'), 5); clearTimeout(id); clearTimeout(12345); clearTimeout()"),
            [], "clearTimeout")
    jsEqLines(t, jsLoopRun("setTimeout(() => { throw new Error('x') }, 1); setTimeout(() => console.log('after'), 2)"),
            ["!Error: x", "after"], "an exception in a timer is reported, the loop goes on")
    jsEqLines(t, jsLoopRun("setTimeout(() => { queueMicrotask(() => console.log('m')); console.log('t') }, 1); setTimeout(() => console.log('u'), 1)"),
            ["t", "m", "u"], "a microtask checkpoint follows every task")
    jsEqLines(t, jsLoopRun("queueMicrotask(() => { console.log('a'); queueMicrotask(() => console.log('c')) }); queueMicrotask(() => console.log('b'))"),
            ["a", "b", "c"], "nested microtasks drain in order")
    jsEqLines(t, jsLoopRun("try { setTimeout('x') } catch (e) { console.log(e.name) } try { queueMicrotask(1) } catch (e) { console.log(e.name) }"),
            ["TypeError", "TypeError"], "non-function callbacks")
    // HTML nesting clamp: from the 6th nested timer on, at least 4 ms.
    let rt = JSRuntime(limits: JSLimits.small)
    let realm = rt.makeRealm()
    let clock = JSLoopClock()
    let loop = JSEventLoop(realm: realm, clock: { clock.now })
    _ = realm.evaluate(source: "var n = 0; function go() { if (++n < 10) setTimeout(go, 0) } go()", name: "t")
    var times: [Double] = []
    var guardN = 0
    while loop.hasPendingWork && guardN < 100 {
        guardN += 1
        if !loop.runOneTask() {
            if let d = loop.nextDeadline() { clock.now += d }
            continue
        }
        times.append(clock.now)
    }
    // Levels 1-5 wait 0 ms, then 4 ms each from level 6.
    var ts = ""
    for x in times { ts += "\(x) " }
    t.check(times == [0, 0, 0, 0, 0, 4, 8, 12, 16], "nested timers clamp to 4 ms after five levels", ts)
    // Promises: jobs drain in the checkpoint, after the sync code and before timers.
    jsEqLines(t, jsLoopRun("setTimeout(() => console.log('timer'), 0); Promise.resolve(1).then(v => console.log('then' + v)); (async () => { await null; console.log('async') })(); console.log('sync')"),
              ["sync", "then1", "async", "timer"], "promise jobs run at the checkpoint")
    jsEqLines(t, jsLoopRun("Promise.reject(new Error('nope')); Promise.reject(7).catch(() => {})", rejections: true),
              ["Uncaught (in promise) Error: nope"], "unhandled rejections are reported")
    jsEqLines(t, jsLoopRun("var w = new WeakRef({}); queueMicrotask(() => console.log(typeof w.deref()))"),
              ["object"], "WeakRef and queueMicrotask")
    // Timers survive GC.
    jsEqLines(t, jsLoopRun("var f = (function (x) { return () => console.log(x.v) })({v: 'kept'}); setTimeout(f, 5); f = null; setTimeout(() => console.log('x'), 6)", gc: true),
            ["kept", "x"], "callbacks are GC roots")
    // clearAll drops everything.
    let rt2 = JSRuntime(limits: JSLimits.small)
    let realm2 = rt2.makeRealm()
    let loop2 = JSEventLoop(realm: realm2, clock: { 0 })
    _ = realm2.evaluate(source: "setTimeout(() => {}, 100); queueMicrotask(() => {})", name: "t")
    t.check(loop2.hasPendingWork && loop2.pendingTimerCount == 1, "pending work reported")
    loop2.clearAll()
    t.check(!loop2.hasPendingWork && loop2.nextDeadline() == nil, "clearAll leaves the loop idle")
}
