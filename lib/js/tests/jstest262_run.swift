// test262 execution runner (ROADMAP Phase 9D).
//
// Runs the test/built-ins, test/annexB/built-ins, test/language and
// test/annexB/language tests of the pinned test262 commit (fetched by
// lib/js/tools/fetch_test262.sh into build/test262; without it the run is
// skipped, not failed). Each test runs in a fresh realm: harness assert.js
// and sta.js, the test's `includes`, then the test itself, once sloppy and
// once strict unless a flag says otherwise (strict = the whole concatenation
// behind a "use strict" directive, as the official runner does). A
// `$262` host object gives evalScript, gc, global, detachArrayBuffer and
// clearKeptObjects; tests that need createRealm or agent are skipped with that reason
// (jstest262_skip.swift). A per-test budget (interruptHandler) makes a hang
// a failure.
//
// Results, per directory (test/<a>/<b>, annexB one level deeper):
//   build/hosttest/test262-results.txt    pass fail skip per directory,
//                                         then skip reasons
//   build/hosttest/test262-failures.txt   path: [mode] message
// The run fails if the pass count of a directory listed in
// lib/js/tests/test262-floor.txt drops below its floor.
//
// Modes (environment):
//   (default, --hosttest)  a fixed deterministic sample: every 16th test of
//                          each directory (sorted by path). Floors: the
//                          "sample" column.
//   WIFFER_TEST262=full    every test (./run.sh --test262). Floors: "full".
//   WIFFER_TEST262_FILTER=substr   only paths containing substr (no floor
//                          check; for working on one directory).
//   WIFFER_TEST262_STRIDE=n        sample stride (default 16).
//
// Raising floors: see "test262 floors" in ROADMAP.md Phase 9D: run
// `./run.sh --test262` and `./run.sh --hosttest js`, and copy each
// directory's pass count from build/hosttest/test262-results.txt into the
// matching column of test262-floor.txt (a little below if the number is
// flaky). Never lower a floor without saying why in the commit.
//
// Async tests (flags: async) need the microtask queue. HOOK: set
// `jsTest262DrainJobs` (below) to a closure that runs the realm's pending
// jobs; until then async tests are "skip: async".

/// HOOK (Phase 9E, Promise and microtasks): run the realm's job queue to
/// completion. nil = async tests are skipped.
nonisolated(unsafe) var jsTest262DrainJobs: ((JSRealm) -> Void)? = nil

final class JSTest262Budget {
    var deadline = 0
    var calls = 0
    var hit = false
}

enum JSTest262Status { case pass, fail, skip }

struct JSTest262Result {
    var status: JSTest262Status
    var message: String
}

struct JSTest262Dir {
    var pass = 0
    var fail = 0
    var skip = 0
}

final class JSTest262Runner {
    let budget = JSTest262Budget()
    let runtime: JSRuntime
    var harness: [String: [UInt8]] = [:]
    var gcStress = false
    var timeoutMs = 4000

    init() {
        var lim = JSLimits()
        lim.heapBytes = 128 << 20
        runtime = JSRuntime(limits: lim)
        let b = budget
        runtime.interruptHandler = { (realm: JSRealm) -> Bool in
            b.calls += 1
            if hostMillis() > b.deadline { b.hit = true; return true }
            return false
        }
    }

    func harnessFile(_ name: String) -> [UInt8]? {
        if let h = harness[name] { return h }
        guard let src = hostReadFile("build/test262/harness/" + name) else { return nil }
        harness[name] = src
        return src
    }

    func skipReason(_ meta: JSTest262Meta, _ src: [UInt8]) -> String? {
        for f in meta.features where jsTest262RunSkipFeatures.contains(f) { return "feature " + f }
        if meta.module { return "module" }
        if meta.async && jsTest262DrainJobs == nil { return "async" }
        let text = String(decoding: src, as: UTF8.self)
        for entry in jsTest262RunSkipSource where jsTestHas(text, entry.needle) { return entry.reason }
        return nil
    }

    /// One variant (sloppy or strict) in a fresh realm.
    func runVariant(_ meta: JSTest262Meta, _ src: [UInt8], strict: Bool, path: String) -> JSTest262Result {
        var text: [UInt8] = []
        if strict { text += Array("\"use strict\";\n".utf8) }
        if !meta.raw {
            var files = ["assert.js", "sta.js"]
            if meta.async { files.append("doneprintHandle.js") }
            for inc in meta.includes where !files.contains(inc) { files.append(inc) }
            for f in files {
                guard let h = harnessFile(f) else { return JSTest262Result(status: .fail, message: "missing harness file " + f) }
                text += h
                text.append(0x0A)
            }
        }
        text += src
        budget.calls = 0
        budget.hit = false
        budget.deadline = hostMillis() + (gcStress ? timeoutMs * 20 : timeoutMs)
        let realm = runtime.makeRealm()
        realm.heap.gcEveryAllocation = gcStress
        var printed: [String] = []
        realm.printHandler = { (s: String) in printed.append(s) }
        installHost(realm)
        let completion = realm.evaluate(source: text, name: path)
        if meta.async, let drain = jsTest262DrainJobs {
            drain(realm)
        }
        switch completion {
        case .terminated(let why):
            return JSTest262Result(status: .fail, message: budget.hit ? "timeout" : "terminated: \(why)")
        case .exception(let e):
            if meta.negativePhase.isEmpty {
                return JSTest262Result(status: .fail, message: e.message)
            }
            if jsTestHas(e.message, meta.negativeType) { return JSTest262Result(status: .pass, message: "") }
            return JSTest262Result(status: .fail, message: "expected \(meta.negativeType) (\(meta.negativePhase)), got " + e.message)
        case .normal:
            if !meta.negativePhase.isEmpty {
                return JSTest262Result(status: .fail, message: "expected \(meta.negativeType) (\(meta.negativePhase)), ran to completion")
            }
            if meta.async {
                var done = false
                for line in printed {
                    if jsTestHas(line, "Test262:AsyncTestFailure") { return JSTest262Result(status: .fail, message: line) }
                    if jsTestHas(line, "Test262:AsyncTestComplete") { done = true }
                }
                if !done { return JSTest262Result(status: .fail, message: "async test never completed") }
            }
            return JSTest262Result(status: .pass, message: "")
        }
    }

    /// `$262`: evalScript, gc, global, detachArrayBuffer (9E),
    /// clearKeptObjects (createRealm and agent are skip-tagged).
    func installHost(_ realm: JSRealm) {
        let o = realm.heap.newObject(proto: realm.objectPrototype)
        let r = realm.heap.root(o)
        realm.defineGlobal("$262", o)
        realm.defineValue(o, "global", realm.global, [.writable, .configurable])
        realm.defineMethod(o, "gc", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            realm.heap.collectGarbage()
            return .undefined
        }
        realm.defineMethod(o, "detachArrayBuffer", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            if !realm.detachArrayBuffer(args[0]) { throw realm.throwTypeError("not an ArrayBuffer") }
            return .null
        }
        realm.defineMethod(o, "clearKeptObjects", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            realm.clearKeptObjects()
            return .undefined
        }
        realm.defineMethod(o, "evalScript", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let s = try realm.toStringValue(args[0])
            let bytes = Array(realm.heap.swiftString(s).utf8)
            switch realm.evaluate(source: bytes, name: "<evalScript>") {
            case .normal(let v): return v
            case .exception(let e): throw realm.throwValue(e.value)
            case .terminated: throw JSThrow()
            }
        }
        realm.heap.popRoots(to: r.slot)
    }

    func run(path: String, src: [UInt8], meta: JSTest262Meta) -> JSTest262Result {
        if let why = skipReason(meta, src) { return JSTest262Result(status: .skip, message: why) }
        var variants: [Bool] = []
        if meta.onlyStrict { variants = [true] } else if meta.noStrict { variants = [false] } else { variants = [false, true] }
        for strict in variants {
            let r = runVariant(meta, src, strict: strict, path: path)
            if r.status != .pass {
                return JSTest262Result(status: r.status, message: (strict ? "[strict] " : "[sloppy] ") + r.message)
            }
        }
        return JSTest262Result(status: .pass, message: "")
    }
}

func jsTest262DirKey(_ path: String) -> String {
    // build/test262/test/<a>/<b>[/<c>/...]; annexB gets one more level.
    let c = path.split(separator: "/")
    if c.count < 6 { return "?" }
    var key = String(c[3]) + "/" + String(c[4])
    if c[3] == "annexB" && c.count > 6 { key += "/" + String(c[5]) }
    return key
}

func jsTest262Env(_ name: String) -> String? {
    guard let p = getenv(name) else { return nil }
    return String(cString: p)
}

/// "dir full sample" lines.
func jsTest262ReadFloors() -> [String: (full: Int, sample: Int)] {
    var out: [String: (full: Int, sample: Int)] = [:]
    guard let bytes = hostReadFile("lib/js/tests/test262-floor.txt") else { return out }
    for line in String(decoding: bytes, as: UTF8.self).split(separator: "\n") {
        if line.hasPrefix("#") { continue }
        let f = line.split(separator: " ")
        if f.count == 3, let a = Int(f[1]), let b = Int(f[2]) { out[String(f[0])] = (a, b) }
    }
    return out
}

func jsTest262RunTests(_ t: Tests) {
    t.section("test262 run")
    guard t.readFileIfPresent("build/test262/LICENSE") != nil, t.readFileIfPresent("build/test262/harness/assert.js") != nil else {
        print("note js: build/test262 absent, test262 execution run skipped (lib/js/tools/fetch_test262.sh)")
        return
    }
    let full = jsTest262Env("WIFFER_TEST262") == "full"
    let filter = jsTest262Env("WIFFER_TEST262_FILTER")
    let stride = max(1, Int(jsTest262Env("WIFFER_TEST262_STRIDE") ?? "16") ?? 16)
    let files = jsTestShellLines("find build/test262/test/built-ins build/test262/test/annexB/built-ins build/test262/test/language build/test262/test/annexB/language -name '*.js' | LC_ALL=C sort")
    let runner = JSTest262Runner()
    var dirs: [String: JSTest262Dir] = [:]
    var skipReasons: [String: Int] = [:]
    var failures: [UInt8] = []
    var seen: [String: Int] = [:]
    var sampled: [String] = []   // passing tests, for the GC stress rerun
    let start = hostMillis()
    for path in files {
        if jsTestHas(path, "_FIXTURE") { continue }
        if let f = filter, !jsTestHas(path, f) { continue }
        let key = jsTest262DirKey(path)
        let idx = seen[key] ?? 0
        seen[key] = idx + 1
        if !full && idx % stride != 0 { continue }
        guard let src = hostReadFile(path) else { continue }
        let meta = jsTest262Meta(src)
        let r = runner.run(path: path, src: src, meta: meta)
        var d = dirs[key] ?? JSTest262Dir()
        switch r.status {
        case .pass:
            d.pass += 1
            if idx % (stride * 8) == 0 { sampled.append(path) }
        case .fail:
            d.fail += 1
            failures += Array("\(path): \(r.message)\n".utf8)
        case .skip:
            d.skip += 1
            skipReasons[r.message, default: 0] += 1
        }
        dirs[key] = d
    }
    let elapsed = hostMillis() - start

    // Report.
    let mode = full ? "full" : "sample 1/\(stride)"
    var text = "# test262 execution: \(mode), \(elapsed) ms\n# dir pass fail skip\n"
    var tp = 0, tf = 0, ts = 0
    for (k, d) in dirs.sorted(by: { $0.key < $1.key }) {
        text += "\(k) \(d.pass) \(d.fail) \(d.skip)\n"
        tp += d.pass; tf += d.fail; ts += d.skip
    }
    text += "TOTAL \(tp) \(tf) \(ts)\n# skip reasons\n"
    for (k, n) in skipReasons.sorted(by: { $0.value > $1.value }) { text += "# \(n) \(k)\n" }
    _ = hostWriteFile("build/hosttest/test262-results.txt", Array(text.utf8))
    _ = hostWriteFile("build/hosttest/test262-failures.txt", failures)
    print("test262 run (\(mode)): \(tp) passed, \(tf) failed, \(ts) skipped, \(elapsed) ms (build/hosttest/test262-results.txt)")

    // Floors.
    if filter == nil {
        let floors = jsTest262ReadFloors()
        for (k, fl) in floors.sorted(by: { $0.key < $1.key }) {
            let floor = full ? fl.full : fl.sample
            let got = k == "TOTAL" ? tp : (dirs[k]?.pass ?? 0)
            if floor > 0 { t.check(got >= floor, "test262 \(k): pass \(got) >= floor \(floor)") }
        }
    }

    // GC stress over a small sample: a passing test must keep passing.
    if filter == nil && !sampled.isEmpty {
        runner.gcStress = true
        var diff = 0
        let s0 = hostMillis()
        for path in sampled {
            guard let src = hostReadFile(path) else { continue }
            let t0 = hostMillis()
            let r = runner.run(path: path, src: src, meta: jsTest262Meta(src))
            if hostMillis() - t0 > 2000 { print("test262 gc stress: slow \(path) \(hostMillis() - t0) ms") }
            if r.status != .pass {
                diff += 1
                print("FAIL test262 gcEveryAllocation \(path): \(r.message)")
            }
        }
        runner.gcStress = false
        print("test262 gc stress: \(sampled.count) tests, \(diff) differ, \(hostMillis() - s0) ms")
        t.check(diff == 0, "test262 sample unchanged under gcEveryAllocation", "\(diff) differ")
    }
}
