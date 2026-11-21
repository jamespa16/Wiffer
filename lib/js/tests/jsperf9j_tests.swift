// Phase 9J performance work: regression tests for string ropes and the
// property fast paths (each script also under gcEveryAllocation).

let jsPerf9JCases: [(String, String)] = [
    // Ropes: long left and right chains, read in different ways.
    ("var s = ''; for (var i = 0; i < 100000; i++) s += 'x'; s.length + ':' + s.charCodeAt(99999) + ':' + s.indexOf('y')", "100000:120:-1"),
    ("var s = ''; for (var i = 0; i < 50000; i++) s = String.fromCharCode(97 + i % 26) + s; s.slice(0, 3) + s.length", "baz50000"),
    ("var a = 'a'.repeat(200), b = 'b'.repeat(200); var r = a + b; var t = r + r; t === a + b + a + b", "true"),
    ("var w = '\\u00e9'.repeat(150) + '\\u4e2d'.repeat(150); var r = 'x'.repeat(300) + w; r.length + ':' + r.charCodeAt(299) + ':' + r.charCodeAt(599) + ':' + r.charCodeAt(400)", "600:120:20013:233"),
    ("var r = 'k'.repeat(300) + 'z'; var o = {}; o[r] = 1; o['k'.repeat(300) + 'z'] + ':' + Object.keys(o)[0].length", "1:301"),
    ("var s = ''; for (var i = 0; i < 1000; i++) s += 'ab,'; s.split(',').length + ':' + /(ab,){999}/.test(s) + ':' + s.replace(/ab/g, 'c').length", "1001:true:2000"),
    ("var s = ''; for (var i = 0; i < 400; i++) s += i % 10; JSON.stringify(s).length + ':' + JSON.parse(JSON.stringify({s: s})).s.length", "402:400"),
    ("var s = 'x'.repeat(300); var parts = []; for (var i = 0; i < 20; i++) { s += i; parts.push(s); } parts[5].length + ':' + parts[19].slice(-4) + ':' + (parts[0] < parts[1])", "306:1819:true"),
    ("var s = 'y'.repeat(256); var t = s + ''; var u = '' + s; (t === s) + ':' + (u === s) + ':' + (s + s).length", "true:true:512"),
    ("var r = 'q'.repeat(300) + 'w'.repeat(300); typeof r + ':' + (r == 'q'.repeat(300) + 'w'.repeat(300)) + ':' + r.toUpperCase().slice(298, 302)", "string:true:QQWW"),
    // Property fast paths: accessors, prototypes, non-writable, length.
    ("var p = {get g() { return 7 }}; var o = Object.create(p); o.a = 1; (o.g + o.a) + ':' + ('length' in [])", "8:true"),
    ("var o = {}; Object.defineProperty(o, 'x', {value: 1, writable: false}); o.x = 2; o.x", "1"),
    ("var o = {set x(v) { this.y = v * 2 }}; o.x = 4; o.y", "8"),
    ("var a = [1, 2, 3]; var s = new String('abcd'); a.length + s.length + 'xyz'.length", "10"),
    ("var o = {}; for (var i = 0; i < 40; i++) o['k' + i] = i; delete o.k3; var s = 0; for (var i = 0; i < 40; i++) s += o['k' + i] || 0; s + ':' + o.k39", "777:39"),
]

func jsPerf9JTests(_ t: Tests) {
    t.section("9J ropes and fast paths")
    let rt = JSRuntime()
    for stress in [false, true] {
        for (src, want) in jsPerf9JCases {
            let realm = rt.makeRealm()
            realm.heap.gcEveryAllocation = stress && !jsHas(src, "100000") && !jsHas(src, "50000")
            t.equal(realm.evaluateToString(src), want, (stress ? "[gc] " : "") + src)
        }
    }
    // Global inline caches: each step reuses the functions compiled in step
    // one, whose caches were filled before the global changed.
    let g = rt.makeRealm()
    let steps: [(String, String)] = [
        ("var gx = 1; var gy = 2; function rx() { return gx } function wx(v) { gx = v; return gx } function ry() { return typeof gy === 'undefined' ? 'none' : gy } rx() + wx(5) + ry()", "8"),
        ("rx() + ':' + wx(6)", "5:6"),
        ("delete globalThis.gy; ry()", "2"),
        ("globalThis.gz = 3; Object.defineProperty(globalThis, 'gq', {value: 9, configurable: true, writable: false}); function rq() { return gq } function wq() { gq = 10; return gq } rq() + wq()", "18"),
        ("Object.defineProperty(globalThis, 'gq', {get: function () { return 42 }, configurable: true}); rq()", "42"),
        ("let gl = 7; function rl() { return gl } function wl() { gl++; return gl } rl() + wl()", "15"),
        ("rl() + wl()", "17"),
        ("const gc = 1; function wc() { gc = 2 } try { wc() } catch (e) { e.name }", "TypeError"),
        ("try { wc() } catch (e) { e.name }", "TypeError"),
        ("function rt() { return tdz } try { rt() } catch (e) { e.name }", "ReferenceError"),
        ("let tdz = 'ok'; rt()", "ok"),
        ("for (var i = 0; i < 40; i++) globalThis['pad' + i] = i; for (var i = 0; i < 40; i += 2) delete globalThis['pad' + i]; rx() + ':' + pad39", "6:39"),
        ("var shadow = 'var'; function rs() { return shadow } rs()", "var"),
    ]
    for (src, want) in steps { t.equal(g.evaluateToString(src), want, "global IC: " + src) }

    // A rope over the length limit is a RangeError, not a trap.
    var lim = JSLimits()
    lim.maxStringLength = 1000
    let small = JSRuntime(limits: lim).makeRealm()
    t.equal(small.evaluateToString("try { var s = 'x'.repeat(600); s + s } catch (e) { e.name }"), "RangeError", "rope over maxStringLength")
    // Ropes kept only by other ropes survive a collection.
    let realm = rt.makeRealm()
    _ = realm.evaluateToString("var keep = []; for (var i = 0; i < 50; i++) { var s = 'r'.repeat(260) + i; keep.push(s + s); }")
    realm.heap.collectGarbage()
    t.equal(realm.evaluateToString("keep[49].length + ':' + keep[49].slice(260, 262) + ':' + keep[10].slice(-2)"), "524:49:10", "ropes survive GC")
    // A rope flattened past the heap cap terminates instead of allocating.
    var capped = JSLimits()
    capped.heapBytes = 8 << 20
    let cr = JSRuntime(limits: capped).makeRealm()
    t.equal(cr.evaluateToString("var s = 'x'.repeat(6 << 20); var t = s + s; var r = t.indexOf('y'); for (var i = 0; i < 1e6; i++) {} r"), "terminated: heap limit", "rope flatten over the heap cap")
}

/// Whole-engine fuzz under GC stress (9J): mutants of the VM case scripts
/// and the rope/fast-path cases, run with a collection at every allocation
/// and a tiny interrupt budget. The plain VM fuzz (jsvm_tests.swift) runs
/// 20 000 mutants without GC stress; this sample finds missing roots.
func jsFuzz9JTests(_ t: Tests) {
    t.section("9J gc-stress fuzz")
    var seeds: [[UInt8]] = []
    for (src, _) in jsVMCases where !jsHas(src, "inf()") && !jsHas(src, "d(5000)") { seeds.append(Array(src.utf8)) }
    for (src, _) in jsPerf9JCases where !jsHas(src, "100000") && !jsHas(src, "50000") { seeds.append(Array(src.utf8)) }
    let rt = JSRuntime(limits: JSLimits.small)
    var budget = 0
    rt.interruptHandler = { _ in budget += 1; return budget > 2 }
    let realm = rt.makeRealm()
    realm.heap.gcEveryAllocation = true
    let start = hostMillis()
    var n = 0
    t.fuzz("vm gc stress", seeds: seeds, iterations: 400) { m in
        budget = 0
        n += 1
        _ = realm.evaluate(source: m, name: "fuzz.js")
    }
    realm.heap.gcEveryAllocation = false
    t.equal(rt.makeRealm().evaluateToString("('a'.repeat(300) + 'b').length"), "301", "after gc-stress fuzz")
    print("js 9j gc-stress fuzz: \(n) mutants, \(hostMillis() - start) ms")
}
