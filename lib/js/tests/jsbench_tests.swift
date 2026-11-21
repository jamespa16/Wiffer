// Benchmarks (ROADMAP Phase 9J): lib/js/fixtures/bench/*.js (richards,
// deltablue, a JSON round trip, a regex-heavy script, string building and
// globals). By default each runs once at scale 1 as a correctness check
// (the scripts verify their own results; the expected values come from
// node). With WIFFER_JS_BENCH=1 each runs at its full scale, best of
// WIFFER_JS_BENCH_REPEAT (default 3) runs, and the time is printed:
//
//     WIFFER_JS_BENCH=1 ./run.sh --hosttest js
//     WIFFER_JS_BENCH=richards,json ./run.sh --hosttest js   (some of them)
//     WIFFER_JS_BENCH=path/to/file.js ...                    (any script)
//
// The same files run under QEMU as `js /js/bench/<name>.js` (they print
// "bench <name> <ms> ms" through console.log).

let jsBenchScripts: [(name: String, scale1: String)] = [
    ("richards", "2322/928"),
    ("deltablue", "99/2490"),
    ("json", "249668"),
    ("regex", "111208"),
    ("strings", "100000/629007/45000450000"),
]

func jsBenchTests(_ t: Tests) {
    t.section("bench")
    let sel = jsTest262Env("WIFFER_JS_BENCH")
    let full = sel != nil
    var list = jsBenchScripts.map { (path: "lib/js/fixtures/bench/" + $0.name + ".js", name: $0.name, want: $0.scale1) }
    if let sel = sel, sel != "1" {
        let names = sel.split(separator: ",").map { String($0) }
        list = list.filter { names.contains($0.name) }
        for n in names where n.hasSuffix(".js") { list.append((path: n, name: n, want: "")) }
    }
    let reps = max(1, Int(jsTest262Env("WIFFER_JS_BENCH_REPEAT") ?? "") ?? 3)
    let rt = JSRuntime()
    for (path, name, want) in list {
        guard let bytes = t.readFile(path) else { continue }
        let src = String(decoding: bytes, as: UTF8.self)
        if !full {
            let realm = rt.makeRealm()
            _ = realm.evaluateToString("var benchScale = 1")
            t.equal(realm.evaluateToString(src, name: name + ".js"), want, "bench " + name + " (scale 1)")
            continue
        }
        var best = Int.max
        var got = ""
        var r = 0
        while r < reps {
            let realm = rt.makeRealm()
            let start = hostMillis()
            got = realm.evaluateToString(src, name: name + ".js")
            best = min(best, hostMillis() - start)
            r += 1
        }
        t.check(!got.hasPrefix("Uncaught") && !got.hasPrefix("terminated"), "bench " + name + " runs", got)
        print("js bench: " + name + " " + String(best) + " ms (" + got + ")")
    }
}
