// Host tests for Phase 9E (ES2015+ runtime): generators, async functions,
// Promise and the job queue, async iteration, private class members and
// the 9B gaps, modules. Each case runs in a fresh realm: the script, then
// realm.runJobs(); the expected text is every print() line joined by
// " | ", then "Uncaught ..." if the script threw.

/// Helpers prepended to every case (no 9C built-ins needed).
let jsVM2Prelude = "function J(a){var s='';for(var i=0;i<a.length;i++){if(i)s+=',';s+=a[i]}return s}\nvar log=print;\n"

let jsVM2Cases: [(String, String)] = [
    // ---------------------------------------------------------- generators
    ("function* g() { yield 1; yield 2; return 3 } var it = g(); var a = []; for (var i = 0; i < 4; i++) { var r = it.next(); a.push(r.value + ':' + r.done) } log(J(a))",
     "1:false,2:false,3:true,undefined:true"),
    ("function* g(x) { var y = yield x; var z = yield y * 2; return z + 1 } var it = g(5); log(it.next().value, it.next(10).value, it.next(7).value)",
     "5 20 8"),
    ("function* g() { yield* [1, 2]; yield* 'ab'; return 'r' } log(J([...g()]))", "1,2,a,b"),
    ("function* h() { yield 'h1'; return 'hr' } function* g() { var r = yield* h(); yield r } log(J([...g()]))", "h1,hr"),
    ("function* g() { try { yield 1; yield 2 } finally { log('fin') } } var it = g(); it.next(); var r = it.return(9); log(r.value, r.done, it.next().done)",
     "fin | 9 true true"),
    ("function* g() { try { yield 1 } catch (e) { log('caught', e); yield 'rec' } } var it = g(); it.next(); log(it.throw('x').value); log(it.next().done)",
     "caught x | rec | true"),
    ("function* g() { yield 1 } var it = g(); try { it.throw(new Error('early')) } catch (e) { log(e.message) } log(it.next().done)",
     "early | true"),
    ("function* g() { yield 1 } var it = g(); var r = it.return(4); log(r.value, r.done, it.next().done)", "4 true true"),
    ("function* g() { try { yield 1 } finally { yield 'f'; log('end fin') } } var it = g(); it.next(); var r = it.return(9); log(r.value, r.done); r = it.next(); log(r.value, r.done)",
     "f false | end fin | 9 true"),
    ("var it; function* g() { it.next() } it = g(); try { it.next() } catch (e) { log(e.name, e.message) }",
     "TypeError Generator is already running"),
    ("function* g() { try { yield 1; yield 2 } finally { log('closed') } } var [a] = g(); log(a)", "closed | 1"),
    ("function* g() { try { yield 1; yield 2 } finally { log('closed') } } for (var x of g()) { log(x); break }", "1 | closed"),
    ("function* g() { throw new Error('in gen') } var it = g(); try { it.next() } catch (e) { log(e.message) } log(it.next().done)",
     "in gen | true"),
    ("var o = { *m(a) { yield this.v + a } , v: 10 }; log(o.m(1).next().value)", "11"),
    ("class C { *[Symbol.iterator]() { yield 1; yield 2 } static *s() { yield 's' } } log(J([...new C()]), C.s().next().value)", "1,2 s"),
    ("function* g() { yield arguments.length; yield arguments[1] } var it = g(7, 8, 9); log(it.next().value, it.next().value)", "3 8"),
    ("function* g() {} var G = Object.getPrototypeOf(g); log(typeof g.prototype, Object.getPrototypeOf(g.prototype) === G.prototype, G.prototype[Symbol.toStringTag])",
     "object true Generator"),
    ("function* g() {} try { new g() } catch (e) { log(e.name) }", "TypeError"),
    ("function* g() { var x = 0; while (true) { x = yield x + 1 } } var it = g(); it.next(); log(it.next(5).value, it.next(9).value)", "6 10"),
    // return/throw during yield*
    ("function* inner() { try { yield 1; yield 2 } finally { log('inner fin') } } function* outer() { try { yield* inner() } finally { log('outer fin') } } var o = outer(); o.next(); var r = o.return(5); log(r.value, r.done)",
     "inner fin | outer fin | 5 true"),
    ("function* inner() { try { yield 1 } catch (e) { log('inner caught', e); yield 'recovered' } } function* outer() { var r = yield* inner(); log('after', r) } var o = outer(); o.next(); log(o.throw('x').value); log(o.next().done)",
     "inner caught x | recovered | after undefined | true"),
    ("var closed = 0; var iter = { [Symbol.iterator]() { return this }, next() { return { value: 1, done: false } }, return() { closed++; return {} } }; function* g() { yield* iter } var it = g(); it.next(); try { it.throw('t') } catch (e) { log(e.name, closed) }",
     "TypeError 1"),
    ("function* inner() { var x = yield 1; return x * 2 } function* outer() { var v = yield* inner(); return v + 1 } var it = outer(); it.next(); log(it.next(20).value)", "41"),
    ("function* d(n) { if (n > 0) { yield n; yield* d(n - 1) } } var s = 0; for (var v of d(200)) s += v; log(s)", "20100"),
    ("function* g() { yield 1 } var it = g(); log(it[Symbol.iterator]() === it)", "true"),
    // --------------------------------------------------- async and ordering
    ("async function async1() { log('async1 start'); await async2(); log('async1 end') } async function async2() { log('async2') } log('script start'); async1(); new Promise(function (r) { log('promise1'); r() }).then(function () { log('promise2') }); log('script end')",
     "script start | async1 start | async2 | promise1 | script end | async1 end | promise2"),
    ("async function f() { return Promise.resolve(1) } f().then(() => log('f')); Promise.resolve().then(() => log('a')).then(() => log('b')).then(() => log('c')).then(() => log('d'))",
     "a | b | f | c | d"),
    ("(async () => { log(1); await null; log(3); await undefined; log(5) })(); Promise.resolve().then(() => log(2)).then(() => log(4))",
     "1 | 3 | 2 | 5 | 4"),
    ("setTimeoutLike = 0; Promise.resolve().then(() => log('p1')); (async () => { await { then(r) { log('then called'); r('thenable') } }; log('after thenable') })(); Promise.resolve().then(() => log('p2')).then(() => log('p3'))",
     "p1 | then called | p2 | after thenable | p3"),
    ("async function f() { throw new Error('sync throw') } var p = f(); log('returned', typeof p); p.catch(e => log('caught', e.message))",
     "returned object | caught sync throw"),
    ("async function f() { try { await Promise.reject(new Error('rej')) } catch (e) { return 'caught ' + e.message } } f().then(v => log(v))", "caught rej"),
    ("async function f(a = (() => { throw 'param' })()) {} f().catch(e => log('rejected', e))", "rejected param"),
    ("var o = { v: 7, m() { return (async () => { await 0; return this.v })() } }; o.m().then(v => log(v))", "7"),
    ("class C { async m() { await 1; return 'm' } static async s() { return 's' } } new C().m().then(log); C.s().then(log)", "s | m"),
    ("async function f() {} log(Object.getPrototypeOf(f)[Symbol.toStringTag], f.prototype === undefined); try { new f() } catch (e) { log(e.name) }",
     "AsyncFunction true | TypeError"),
    ("async function f() { for (var i = 0, s = 0; i < 1000; i++) s += await i; return s } f().then(log)", "499500"),
    ("async function f(n) { return n ? 1 + await f(n - 1) : 0 } f(100).then(log)", "100"),
    ("var log2 = []; async function f() { try { return await g() } finally { log('finally') } } async function g() { throw 'x' } f().catch(e => log('caught', e))",
     "finally | caught x"),
    // ------------------------------------------------------- async iteration
    ("async function* ag() { yield 1; await null; yield 2; return 3 } (async () => { for await (const v of ag()) log('ag', v) })()", "ag 1 | ag 2"),
    ("(async () => { for await (const v of [Promise.resolve('x'), 'y']) log(v) })()", "x | y"),
    ("async function* ag() { yield 1; yield 2 } var it = ag(); it.next().then(r => log(r.value)); it.next().then(r => log(r.value)); it.next().then(r => log(r.done))",
     "1 | 2 | true"),
    ("async function* ag() { yield 1 } ag().return(5).then(r => log(r.value, r.done))", "5 true"),
    ("async function* ag() { yield 1 } var it = ag(); it.throw(new Error('t')).catch(e => log('rej', e.message)); it.next().then(r => log(r.done))",
     "rej t | true"),
    ("async function* ag() { try { yield 1; yield 2 } finally { log('ag fin') } } (async () => { for await (const v of ag()) { log(v); break } log('after') })()",
     "1 | ag fin | after"),
    ("async function* ag() { yield* [Promise.resolve('a'), 'b']; yield* (async function* () { yield 'c'; return 'd' })() } (async () => { for await (const v of ag()) log(v) })()",
     "a | b | c"),
    ("async function* ag() { var x = yield 'first'; log('got', x); return x } var it = ag(); it.next('ignored').then(r => { log(r.value); return it.next('second') }).then(r => log(r.value, r.done))",
     "first | got second | second true"),
    ("async function* ag() { yield Promise.resolve('awaited') } ag().next().then(r => log(r.value))", "awaited"),
    ("async function* ag() { throw new Error('boom') } (async () => { try { for await (const v of ag()) {} } catch (e) { log('caught', e.message) } })()", "caught boom"),
    ("var closed = false; var it = { [Symbol.asyncIterator]() { return { next() { return Promise.resolve({ value: 1, done: false }) }, return() { closed = true; return Promise.resolve({}) } } } }; (async () => { try { for await (const v of it) throw 'err' } catch (e) { log(e, closed) } })()",
     "err true"),
    ("async function* ag() {} var AG = Object.getPrototypeOf(ag); log(AG.prototype[Symbol.toStringTag], typeof ag.prototype.next, Object.getPrototypeOf(ag.prototype) === AG.prototype)",
     "AsyncGenerator function true"),
    // ------------------------------------------------------------- Promise
    ("new Promise((res, rej) => { res(1); rej(2); res(3) }).then(v => log('v', v), e => log('e', e))", "v 1"),
    ("Promise.reject(new Error('r')).catch(e => e.message).then(log)", "r"),
    ("Promise.resolve(1).finally(() => log('fin')).then(v => log('v', v)); Promise.reject(2).finally(() => 9).catch(e => log('e', e))",
     "fin | v 1 | e 2"),
    ("Promise.all([1, Promise.resolve(2), new Promise(r => r(3))]).then(v => log('all', J(v)))", "all 1,2,3"),
    ("Promise.all([1, Promise.reject('no'), 3]).then(v => log('ok'), e => log('rej', e))", "rej no"),
    ("Promise.all([]).then(v => log('empty', v.length))", "empty 0"),
    ("Promise.allSettled([1, Promise.reject('x')]).then(v => log(v[0].status, v[0].value, v[1].status, v[1].reason))", "fulfilled 1 rejected x"),
    ("Promise.any([Promise.reject(1), Promise.resolve(2)]).then(v => log('any', v)); Promise.any([Promise.reject(1)]).catch(e => log(e.name, e.errors.length, e instanceof AggregateError))",
     "any 2 | AggregateError 1 true"),
    ("Promise.race([new Promise(() => {}), Promise.resolve('fast')]).then(log)", "fast"),
    ("var r = Promise.withResolvers(); r.promise.then(log); r.resolve('wr')", "wr"),
    ("var p = Promise.resolve(); log(Promise.resolve(p) === p, p instanceof Promise, Object.prototype.toString.call(p))", "true true [object Promise]"),
    ("var p = new Promise(r => r()); var q = p.then(() => q); q.catch(e => log(e.name))", "TypeError"),
    ("class MyP extends Promise {} var p = MyP.resolve(1); log(p instanceof MyP, p.then(() => {}) instanceof MyP)", "true true"),
    ("try { Promise() } catch (e) { log(e.name) } try { new Promise(1) } catch (e) { log(e.name) }", "TypeError | TypeError"),
    ("new Promise(() => { throw 'exec' }).catch(e => log('caught', e))", "caught exec"),
    ("Promise.resolve({ then(f) { f('thenable') } }).then(log)", "thenable"),
    ("Promise.try((a, b) => a + b, 2, 3).then(log)", "5"),
    ("var e = new AggregateError([1, 2], 'msg'); log(e.message, e.errors.length, e.name)", "msg 2 AggregateError"),
    ("var order = []; Promise.resolve().then(() => { log(1); Promise.resolve().then(() => log(3)) }).then(() => log(4)); Promise.resolve().then(() => log(2))",
     "1 | 2 | 3 | 4"),
    // ------------------------------------------------------ private members
    ("class A { #x = 1; #m() { return this.#x * 10 } get #g() { return 'g' + this.#x } set #g(v) { this.#x = v } run() { this.#g = 5; return this.#m() + ',' + this.#g } } log(new A().run())",
     "50,g5"),
    ("class A { #x; static has(o) { return #x in o } } log(A.has(new A()), A.has({})); try { class B { #y; static t(v) { return #y in v } } B.t(1) } catch (e) { log(e.name) }",
     "true false | TypeError"),
    ("class A { #x = 1; static get(o) { return o.#x } } try { A.get({}) } catch (e) { log(e.name, e.message) }",
     "TypeError Cannot read private member #x from an object whose class did not declare it"),
    ("class A { #m() {} t() { this.#m = 1 } } try { new A().t() } catch (e) { log(e.message) }", "Private method #m is not writable"),
    ("class A { get #g() { return 1 } t() { this.#g = 2 } } try { new A().t() } catch (e) { log(e.message) }", "'#g' was defined without a setter"),
    ("class A { static #c = 0; static #inc() { return ++A.#c } static run() { A.#inc(); return A.#inc() } } log(A.run())", "2"),
    ("class A { #v = 0; inc() { this.#v++; ++this.#v; this.#v += 10; return this.#v } } log(new A().inc())", "12"),
    ("class A { #a = 1; m() { var o = this; return [o.#a, this?.#a].length } } log(new A().m())", "2"),
    ("class E { constructor(o) { return o } } class F extends E { #b = 'fb'; static get(o) { return o.#b } } var o = {}; new F(o); log(F.get(o)); try { new F(o) } catch (e) { log(e.name) }",
     "fb | TypeError"),
    ("class A { #x = 1; } var a = new A(); var n = 0; for (var k in a) n++; log(Object.keys(a).length, n)", "0 0"),
    ("class A { #x = 1; getX() { return this.#x } } class B { #x = 2; getX() { return this.#x } } log(new A().getX() + new B().getX())", "3"),
    ("class Outer { #p = 'outer'; m() { class Inner { #p = 'inner'; get(o) { return o.#p } } return new Inner().get(new Inner()) + ',' + this.#p } } log(new Outer().m())",
     "inner,outer"),
    ("class A { #x = 1; static swap(o) { [o.#x] = [9]; return o.#x } } log(A.swap(new A()))", "9"),
    ("class A { #f() { return this } m() { return this.#f() === this } } log(new A().m())", "true"),
    ("class A { static #s = 's'; static { log('block', A.#s) } }", "block s"),
    // ----------------------------------------------------- computed fields
    ("var i = 0; class C { [i++] = 'a' + i; ['m' + i++]() { return 'meth' } static [i++] = 'st' } var c = new C(); log(c[0], c.m1(), C[2])", "a3 meth st"),
    ("var k = Symbol('k'); class C { [k] = 1 } log(new C()[k])", "1"),
    ("class C { static n = C.name; static x = this.n + '!' } log(C.x)", "C!"),
    // ------------------------------------------------------------ 9B gaps
    ("class S {} S.prototype.x = 1; class T extends S { k() { super['x'] += 2; return this.x } } log(new T().k())", "3"),
    ("var obj = { n: 1 }; var s = { __proto__: obj, g() { var r = super['n']++; return r + ',' + this.n } }; log(s.g())", "1,2"),
    ("function ev() { var q = 2; return eval(...['q + 1']) } log(ev())", "3"),
    ("function f(p = eval('var arguments')) {} try { f() } catch (e) { log(e.name) } function g(p = eval('var z = 1')) { return p } log(g())", "SyntaxError | undefined"),
    ("var k = 'b'; var { a, [k]: b, ...rest } = { a: 1, b: 2, c: 3 }; log(a, b, Object.keys(rest).length, rest.c, rest.b)", "1 2 1 3 undefined"),
    ("var closed = 0; var it = { [Symbol.iterator]() { return { next() { return { value: 1, done: false } }, return() { closed++; return {} } } } }; try { var [a, [b]] = it } catch (e) { log(e.name, closed) }",
     "TypeError 1"),
    ("var closed = 0; var it = { [Symbol.iterator]() { return { next() { throw 'nexterr' }, return() { closed++; return {} } } } }; try { var [d] = it } catch (e) { log(e, closed) }",
     "nexterr 0"),
    ("var closed = 0; var it = { [Symbol.iterator]() { return { next() { return { value: undefined, done: false } }, return() { closed++; return {} } } } }; try { var [a = (() => { throw 'd' })()] = it } catch (e) { log(e, closed) }",
     "d 1"),
    ("var n = 0; var o = { get m() { n++; return function () { return this === o } } }; log(o.m(), n)", "true 1"),
]

/// Run one case: script + job drain; the printed lines (and an uncaught
/// exception) joined by " | ".
func jsVM2Run(_ realm: JSRealm, _ src: String) -> String {
    var lines: [String] = []
    realm.printHandler = { (s: String) in lines.append(s) }
    switch realm.evaluate(source: jsVM2Prelude + src, name: "case.js") {
    case .normal: break
    case .exception(let e): lines.append("Uncaught " + e.message)
    case .terminated: lines.append("terminated")
    }
    _ = realm.runJobs()
    return lines.joined(separator: " | ")
}

func jsVM2Tests(_ t: Tests) {
    jsVM2ScriptTests(t, stress: false)
    jsVM2ScriptTests(t, stress: true)
    jsVM2JobTests(t)
    jsVM2Fuzz(t)
}

func jsVM2ScriptTests(_ t: Tests, stress: Bool) {
    t.section(stress ? "vm2 scripts (gcEveryAllocation)" : "vm2 scripts")
    let start = hostMillis()
    let rt = JSRuntime(limits: JSLimits())
    for (src, want) in jsVM2Cases {
        if stress && (jsHas(src, "d(200)") || jsHas(src, "i < 1000")) { continue }
        let realm = rt.makeRealm()
        realm.heap.gcEveryAllocation = stress
        t.equal(jsVM2Run(realm, src), want, src)
    }
    if stress { print("js vm2: gcEveryAllocation pass \(hostMillis() - start) ms") }
}

func jsVM2JobTests(_ t: Tests) {
    t.section("vm2 job queue")
    let rt = JSRuntime()
    let realm = rt.makeRealm()
    // Unhandled rejections: reported after the drain unless handled.
    var unhandled: [String] = []
    var tracked: [String] = []
    realm.unhandledRejectionHandler = { (r: JSRealm, p: JSValue, v: JSValue) in unhandled.append(r.safeToString(v)) }
    realm.promiseRejectionTracker = { (r: JSRealm, p: JSValue, op: JSPromiseRejectionOperation) in
        tracked.append(op == .reject ? "reject" : "handle")
    }
    _ = realm.evaluate(source: "var late = Promise.reject('late'); Promise.reject('lost'); var h = Promise.reject('handled'); h.catch(() => {}); Promise.resolve().then(() => { throw 'in then' })")
    t.check(realm.hasPendingJobs, "jobs pending after the script")
    _ = realm.runJobs()
    t.check(!realm.hasPendingJobs, "queue drained")
    t.equal(unhandled.joined(separator: ","), "late,lost,in then", "unhandled rejection callback")
    t.equal(tracked.joined(separator: ","), "reject,reject,reject,handle,reject", "rejection tracker")
    unhandled = []
    _ = realm.evaluate(source: "late.catch(() => {})")
    _ = realm.runJobs()
    t.equal(unhandled.count, 0, "handled later: not reported again")
    t.equal(tracked.last ?? "", "handle", "tracker sees the late handler")
    // enqueueJob / enqueueHostJob and errors from jobs.
    var errors: [String] = []
    realm.jobErrorHandler = { (r: JSRealm, e: JSUncaughtException) in errors.append(e.message) }
    var out: [String] = []
    realm.printHandler = { (s: String) in out.append(s) }
    if case .normal(let f) = realm.evaluate(source: "(function (a, b) { print('cb', a, b) })") {
        realm.enqueueJob(f, args: [.int32(1), .int32(2)])
    }
    realm.enqueueHostJob { (realm: JSRealm) throws(JSThrow) -> Void in
        out.append("host")
        throw realm.throwTypeError("host job failed")
    }
    _ = realm.evaluate(source: "queueLike = 1; Promise.resolve().then(() => print('promise job'))")
    t.equal(realm.pendingJobCount, 3, "pending job count")
    _ = realm.runJobs()
    t.equal(out.joined(separator: ","), "cb 1 2,host,promise job", "job order (FIFO)")
    t.equal(errors.joined(separator: ","), "TypeError: host job failed", "job error handler")
    // A runaway microtask loop is terminated by the interrupt handler.
    let rt2 = JSRuntime(limits: JSLimits.small)
    var checks = 0
    rt2.interruptHandler = { _ in checks += 1; return checks > 20 }
    let r2 = rt2.makeRealm()
    _ = r2.evaluate(source: "function spin() { Promise.resolve().then(spin) } spin()")
    if case .terminated(let why) = r2.runJobs() { t.check(why == .interrupted, "microtask loop: interrupt") } else { t.check(false, "microtask loop terminated") }
    t.check(!r2.hasPendingJobs, "terminated drain drops the queue")
    rt2.interruptHandler = nil
    t.equal(r2.evaluateToString("1 + 1"), "2", "realm usable after a terminated drain")
}

func jsVM2Fuzz(_ t: Tests) {
    t.section("vm2 fuzz")
    var seeds: [[UInt8]] = []
    for (src, _) in jsVM2Cases where !jsHas(src, "d(200)") { seeds.append(Array((jsVM2Prelude + src).utf8)) }
    let rt = JSRuntime(limits: JSLimits.small)
    var budget = 0
    rt.interruptHandler = { _ in budget += 1; return budget > 3 }
    let realm = rt.makeRealm()
    realm.printHandler = { _ in }
    var n = 0
    t.fuzz("vm2", seeds: seeds, iterations: 10000) { m in
        budget = 0
        n += 1
        if n % 500 == 0 { realm.heap.collectGarbage() }
        _ = realm.evaluate(source: m, name: "fuzz.js")
        _ = realm.runJobs()
    }
    let fresh = rt.makeRealm()
    t.equal(fresh.evaluateToString("1 + 1"), "2", "after fuzz")
}
