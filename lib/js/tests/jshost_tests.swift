// Host tests for Phase 9F host objects (jshost.swift) with toy host classes.

final class JSToyCounter {
    var n: Int
    var tag = ""
    init(_ n: Int) { self.n = n }
}

final class JSToyBag {
    var items: [String]
    var named: [(String, Int)]
    init(_ items: [String], _ named: [(String, Int)] = []) { self.items = items; self.named = named }
}

final class JSHostFixture {
    let rt = JSRuntime(limits: JSLimits.small)
    let realm: JSRealm
    let counters: JSHostClass<JSToyCounter>
    let bags: JSHostClass<JSToyBag>
    var all: [JSToyCounter] = []
    var lines: [String] = []

    init(gc: Bool = false) {
        realm = rt.makeRealm()
        realm.heap.gcEveryAllocation = gc
        counters = JSHostClass<JSToyCounter>(realm: realm, name: "Counter")
        var ex = JSHostExotic<JSToyBag>()
        ex.length = { b in b.items.count }
        ex.indexedGet = { (realm: JSRealm, b: JSToyBag, i: Int) throws(JSThrow) -> JSValue? in
            i < b.items.count ? realm.string(b.items[i]) : nil
        }
        ex.namedGet = { (realm: JSRealm, b: JSToyBag, name: String) throws(JSThrow) -> JSValue? in
            for (n, v) in b.named where n == name { return .number(v) }
            return nil
        }
        ex.namedKeys = { b in b.named.map { $0.0 } }
        bags = JSHostClass<JSToyBag>(realm: realm, name: "Bag", exotic: ex)
        counters.define(methods: [
            JSHostMethod("inc", 0) { (realm: JSRealm, c: JSToyCounter, args: JSArgs) throws(JSThrow) -> JSValue in
                c.n += args.count > 0 ? Int(try realm.toNumber(args[0])) : 1
                return .number(c.n)
            },
        ], accessors: [
            JSHostAccessor("value", get: { (realm: JSRealm, c: JSToyCounter) throws(JSThrow) -> JSValue in .number(c.n) },
                           set: { (realm: JSRealm, c: JSToyCounter, v: JSValue) throws(JSThrow) -> Void in c.n = Int(try realm.toNumber(v)) }),
        ])
        counters.exposeConstructor(length: 1) { [unowned(unsafe) self] (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSToyCounter in
            let c = JSToyCounter(args.count > 0 ? Int(try realm.toNumber(args[0])) : 0)
            self.all.append(c)
            return c
        }
        bags.define(methods: [
            JSHostMethod("item", 1) { (realm: JSRealm, b: JSToyBag, args: JSArgs) throws(JSThrow) -> JSValue in
                let i = Int(try realm.toNumber(args[0]))
                return i >= 0 && i < b.items.count ? realm.string(b.items[i]) : .null
            },
            JSHostMethod("size", 0) { (realm: JSRealm, b: JSToyBag, args: JSArgs) throws(JSThrow) -> JSValue in .number(b.items.count) },
        ])
        bags.define(accessors: [
            JSHostAccessor("length", get: { (realm: JSRealm, b: JSToyBag) throws(JSThrow) -> JSValue in .number(b.items.count) }),
        ])
        bags.exposeConstructor()
        // Script-visible factories returning the wrapper for fixed Swift objects.
        let shared = JSToyCounter(100)
        all.append(shared)
        let bag = JSToyBag(["a", "b", "c"], [("x", 10), ("y", 20)])
        realm.defineMethod(realm.global, "shared", length: 0) { [unowned(unsafe) self] (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            self.counters.wrap(shared)
        }
        realm.defineMethod(realm.global, "bag", length: 0) { [unowned(unsafe) self] (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            self.bags.wrap(bag)
        }
        jsInstallConsole(realm) { [unowned(unsafe) self] _, text in self.lines.append(text) }
    }

    func run(_ src: String) -> String {
        switch realm.evaluate(source: src, name: "t") {
        case .normal(let v):
            let d = realm.heap.rootDepth
            _ = realm.heap.root(v)
            let s = realm.heap.isCallable(v) || v.isObject ? jsInspect(realm, v) : (try? realm.toSwiftString(v)) ?? "?"
            realm.heap.popRoots(to: d)
            return s
        case .exception(let e): return "!" + e.message
        case .terminated: return "!terminated"
        }
    }
}

func jsHostTests(_ t: Tests) {
    t.section("9F host objects")
    for gc in [false, true] {
        let suffix = gc ? " (GC stress)" : ""
        let f = JSHostFixture(gc: gc)
        t.equal(f.run("var c = new Counter(5); c.inc() + ',' + c.inc(10) + ',' + c.value"), "6,16,16", "methods and accessors" + suffix)
        t.equal(f.run("c.value = 3; c.value"), "3", "accessor setter" + suffix)
        t.equal(f.run("c instanceof Counter && Object.getPrototypeOf(c) === Counter.prototype && c.constructor === Counter"), "true", "prototype and constructor" + suffix)
        t.equal(f.run("try { Counter.prototype.inc.call({}) } catch (e) { e.name + ': ' + e.message }"),
                "TypeError: Illegal invocation: Counter.inc", "Illegal invocation" + suffix)
        t.equal(f.run("try { Counter.prototype.inc.call(new Bag()) } catch (e) { e.name }"), "TypeError", "another class is rejected" + suffix)
        t.equal(f.run("try { new Bag() } catch (e) { e.message }"), "Illegal constructor: Bag", "Illegal constructor" + suffix)
        t.equal(f.run("try { Counter(1) } catch (e) { e.name }"), "TypeError", "constructor needs new" + suffix)
        t.equal(f.run("shared() === shared() && shared().value === 100"), "true", "wrapper identity" + suffix)
        t.equal(f.run("shared().expando = 7; shared().expando"), "7", "expando properties persist while the wrapper lives" + suffix)
        t.equal(f.run("class Sub extends Counter {}; var s = new Sub(2); (s instanceof Sub) + ',' + s.inc()"), "true,3", "subclassing" + suffix)
        // Exotic: indexed and named.
        t.equal(f.run("var b = bag(); b[0] + b[2] + ',' + b[3] + ',' + b.length + ',' + b.size()"), "ac,undefined,3,3", "indexed getter" + suffix)
        t.equal(f.run("b.x + ',' + b.y + ',' + b.z + ',' + ('x' in b) + ',' + (1 in b) + ',' + (7 in b)"), "10,20,undefined,true,true,false", "named getter and has" + suffix)
        t.equal(f.run("Object.keys(b).join()"), "0,1,2", "keys: indices only, named are not enumerable" + suffix)
        t.equal(f.run("Reflect.ownKeys(b).join()"), "0,1,2,x,y", "ownKeys lists indices then names" + suffix)
        t.equal(f.run("b[0] = 'zz'; b[0] + ',' + delete b[0] + ',' + b[0]"), "a,false,a", "indexed properties are read-only" + suffix)
        t.equal(f.run("'use strict'; try { b[0] = 1 } catch (e) { e.name }"), "TypeError", "strict assignment to an indexed property throws" + suffix)
        t.equal(f.run("b.extra = 5; b.extra + ',' + Object.keys(b).join()"), "5,0,1,2,extra", "ordinary expandos still work" + suffix)
        t.equal(f.run("JSON.stringify(Array.prototype.slice.call(b))"), "[\"a\",\"b\",\"c\"]", "array-likes work with Array.prototype" + suffix)
        t.equal(f.run("Object.getOwnPropertyDescriptor(b, '1').value + ',' + Object.getOwnPropertyDescriptor(b, '1').writable"), "b,false", "descriptor of an indexed property" + suffix)
    }
    // The wrapper cache and its GC roots.
    let f = JSHostFixture()
    let c1 = JSToyCounter(1)
    let w1 = f.counters.wrap(c1)
    t.check(f.counters.wrap(c1) == w1 && f.counters.existingWrapper(for: c1) == w1, "wrap returns the cached wrapper")
    t.check(f.counters.unwrap(w1) === c1, "unwrap returns the Swift object")
    t.check(f.counters.unwrap(f.bags.wrap(JSToyBag([]))) == nil, "unwrap rejects another class")
    t.check(f.counters.unwrap(.int32(1)) == nil && f.counters.unwrap(f.realm.global) == nil, "unwrap rejects non-wrappers")
    f.realm.heap.collectGarbage()
    t.equal(f.counters.liveCount, 0, "unreachable wrappers are collected")
    // Pinned wrappers survive, with their expandos.
    let c2 = JSToyCounter(2)
    var w2 = f.counters.wrap(c2)
    _ = f.realm.heap.defineOwnProperty(w2, f.realm.heap.key("mark"), .data(.int32(42)))
    f.counters.pin(c2, true)
    w2 = .undefined
    f.realm.heap.collectGarbage()
    t.check(f.counters.existingWrapper(for: c2) != nil, "a pinned wrapper survives collection")
    if let again = f.counters.existingWrapper(for: c2) {
        t.equal(f.realm.heap.getOwnProperty(again, f.realm.heap.key("mark"))?.value.asInt32 ?? 0, 42, "its expando is intact")
    }
    f.counters.pin(c2, false)
    f.realm.heap.collectGarbage()
    t.check(f.counters.existingWrapper(for: c2) == nil, "an unpinned wrapper is collected")
    // shouldRoot decides at each collection.
    var keep = true
    let c3 = JSToyCounter(3)
    f.counters.shouldRoot = { c in c === c3 && keep }
    _ = f.counters.wrap(c3)
    f.realm.heap.collectGarbage()
    t.check(f.counters.existingWrapper(for: c3) != nil, "shouldRoot keeps the wrapper")
    keep = false
    f.realm.heap.collectGarbage()
    t.check(f.counters.existingWrapper(for: c3) == nil, "and lets it go when the condition changes")
    // A wrapper gets a new identity after it was collected, the Swift object is the same.
    let w3 = f.counters.wrap(c3)
    t.check(f.counters.unwrap(w3) === c3, "re-wrapping a collected object works")
    // Slots stay free for the host and are traced.
    let holder = f.counters.wrap(JSToyCounter(9))
    let r = f.realm.heap.root(holder)
    let s = f.realm.string("held")
    _ = f.realm.heap.setSlots(holder, [s])
    f.realm.heap.collectGarbage()
    t.equal(f.realm.heap.swiftString(f.realm.heap.slot(f.realm.heap[r], 0)), "held", "host slots are traced by the GC")
}
