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
//   build/hosttest/test262-results.txt    pass fail skip milliseconds per directory,
//                                         then skip reasons
//   build/hosttest/test262-failures.txt   path: [mode] message
//   build/hosttest/test262-features.txt   pass fail skip milliseconds per feature tag
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
//   WIFFER_TEST262_JOBS=n          worker processes (default: one per CPU;
//                          1 = in-process). See "Parallel run" below.
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
nonisolated(unsafe) var jsTest262DrainJobs: ((JSRealm) -> Void)? = { (realm: JSRealm) in _ = realm.runJobs() }

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
    var milliseconds = 0
}

final class JSTest262Runner {
    let budget = JSTest262Budget()
    let runtime: JSRuntime
    var harness: [String: [UInt8]] = [:]
    var gcStress = false
    // Host-agent capability selected per variant. T9 will pass this through
    // to Atomics.wait; until then all consumers of it remain feature-skipped.
    var canBlock = false
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
        if meta.async && jsTest262DrainJobs == nil { return "async" }
        let text = String(decoding: src, as: UTF8.self)
        for entry in jsTest262RunSkipSource where jsTestHas(text, entry.needle) { return entry.reason }
        return nil
    }

    /// One variant (sloppy or strict) in a fresh realm.
    func runVariant(_ meta: JSTest262Meta, _ src: [UInt8], strict: Bool, path: String) -> JSTest262Result {
        if meta.flags.contains("CanBlockIsFalse") && meta.flags.contains("CanBlockIsTrue") {
            return JSTest262Result(status: .fail, message: "conflicting CanBlock flags")
        }
        canBlock = meta.flags.contains("CanBlockIsTrue")
        // non-deterministic is informational: it never suppresses failures.
        var text: [UInt8] = []
        if strict && !meta.module { text += Array("\"use strict\";\n".utf8) }
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
        if !meta.module { text += src }
        budget.calls = 0
        budget.hit = false
        budget.deadline = hostMillis() + (gcStress ? timeoutMs * 20 : timeoutMs)
        let realm = runtime.makeRealm()
        realm.heap.gcEveryAllocation = gcStress
        realm.nowMs = {
            var tv = timeval()
            _ = gettimeofday(&tv, nil)
            return Double(tv.tv_sec) * 1000 + Double(tv.tv_usec / 1000)
        }
        var printed: [String] = []
        realm.printHandler = { (s: String) in printed.append(s) }
        installHost(realm)
        // Dynamic import is also available to script tests and their harness.
        realm.moduleLoader = { (_: JSRealm, spec: String, ref: String) -> JSModuleLoadResult in
            let url = jsTest262ResolveModule(spec, (ref.isEmpty || ref == "eval" || ref.hasPrefix("<")) ? path : ref)
            guard let bytes = hostReadFile(url) else { return .error("Cannot find module '" + spec + "'") }
            return .source(url: url, bytes: bytes)
        }
        // Separate compilation and linking from evaluation for negative tests.
        // Otherwise a runtime SyntaxError could falsely satisfy a parse test.
        if !meta.negativePhase.isEmpty {
            let depth = realm.heap.rootDepth
            var phase = "parse"
            do throws(JSThrow) {
                if meta.module {
                    let root = try realm.registerModule(url: path, bytes: src)
                    phase = "resolution"
                    if !meta.negativeParse {
                        try realm.loadModuleGraph(root)
                        try realm.linkModule(root)
                    }
                } else {
                    var source = strict && !meta.raw ? Array("\"use strict\";\n".utf8) : []
                    source += src
                    _ = try realm.compileScriptClosure(source, name: path, eval: false, strict: false)
                }
                realm.heap.popRoots(to: depth)
            } catch {
                realm.heap.popRoots(to: depth)
                let e = realm.uncaught()
                let expectedPhase = meta.negativeParse ? "parse" : meta.negativePhase
                if phase != expectedPhase {
                    return JSTest262Result(status: .fail, message: "expected error during " + expectedPhase + ", got " + phase + ": " + e.message)
                }
                return negativeResult(meta, e, realm)
            }
            if meta.negativeParse || meta.negativePhase == "resolution" {
                return JSTest262Result(status: .fail, message: "expected " + meta.negativeType + " during " + meta.negativePhase + ", phase completed")
            }
        }
        var completion = realm.evaluate(source: text, name: path)
        if meta.module, case .normal = completion {
            completion = realm.evaluateModule(source: src, name: path)
            if case .normal(let p) = completion {
                let keep = realm.heap.retain(p)
                if let drain = jsTest262DrainJobs { drain(realm) }
                let pv = realm.heap.persistent[keep.slot]
                if realm.promiseState(pv) == .rejected {
                    realm.heap.release(keep)
                    _ = realm.throwValue(realm.promiseResult(pv))
                    let u = realm.uncaught()
                    completion = .exception(u)
                } else {
                    realm.heap.release(keep)
                }
            }
        } else if meta.async, let drain = jsTest262DrainJobs {
            drain(realm)
        }
        switch completion {
        case .terminated(let why):
            return JSTest262Result(status: .fail, message: budget.hit ? "timeout" : "terminated: \(why)")
        case .exception(let e):
            if meta.negativePhase.isEmpty {
                return JSTest262Result(status: .fail, message: e.message)
            }
            return negativeResult(meta, e, realm)
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

    /// INTERPRETING.md compares the thrown value's constructor name, not
    /// its display string (which can contain misleading error names).
    func negativeResult(_ meta: JSTest262Meta, _ e: JSUncaughtException, _ realm: JSRealm) -> JSTest262Result {
        let depth = realm.heap.rootDepth
        _ = realm.heap.root(e.value)
        defer { realm.heap.popRoots(to: depth) }
        do throws(JSThrow) {
            let constructor = try realm.getV(e.value, realm.heap.key("constructor"))
            _ = realm.heap.root(constructor)
            let name = try realm.getV(constructor, realm.heap.names.name)
            if name.isString && realm.heap.swiftString(name) == meta.negativeType {
                return JSTest262Result(status: .pass, message: "")
            }
        } catch {}
        return JSTest262Result(status: .fail, message: "expected " + meta.negativeType + " (" + meta.negativePhase + "), got " + e.message)
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
        // These hooks are deliberately visible while their feature tests remain
        // skip-tagged. Calling one reports the roadmap phase instead of an
        // accidental TypeError from a missing host property.
        realm.defineMethod(o, "createRealm", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            throw jsTest262NotYet(realm, "T8 createRealm")
        }
        let agent = realm.heap.newObject(proto: realm.objectPrototype)
        realm.defineValue(o, "agent", agent, [.writable, .configurable])
        for name in ["start", "broadcast", "receiveBroadcast", "report", "getReport", "sleep", "monotonicNow", "leaving"] {
            realm.defineMethod(agent, name, length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
                throw jsTest262NotYet(realm, "T9 agent")
            }
        }
        realm.heap.popRoots(to: r.slot)
    }

    func run(path: String, src: [UInt8], meta: JSTest262Meta) -> JSTest262Result {
        if !path.hasPrefix("build/test262/test/intl402/"), let why = skipReason(meta, src) { return JSTest262Result(status: .skip, message: why) }
        var variants: [Bool] = []
        if meta.raw { variants = [false] } else if meta.onlyStrict || meta.module { variants = [true] } else if meta.noStrict { variants = [false] } else { variants = [false, true] }
        for strict in variants {
            let r = runVariant(meta, src, strict: strict, path: path)
            if r.status != .pass {
                return JSTest262Result(status: r.status, message: (strict ? "[strict] " : "[sloppy] ") + r.message)
            }
        }
        return JSTest262Result(status: .pass, message: "")
    }
}

/// A module specifier relative to the importing file (./x.js, ../x.js).
func jsTest262ResolveModule(_ spec: String, _ referrer: String) -> String {
    var parts = referrer.split(separator: "/", omittingEmptySubsequences: false).map { String($0) }
    if !parts.isEmpty { parts.removeLast() }
    for c in spec.split(separator: "/", omittingEmptySubsequences: false) {
        if c == "." { continue }
        if c == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
        parts.append(String(c))
    }
    return parts.joined(separator: "/")
}

func jsTest262DirKey(_ path: String) -> String {
    // build/test262/test/<a>/<b>[/<c>/...]; annexB gets one more level.
    let c = path.split(separator: "/")
    if c.count < 5 { return "?" }
    if c[3] == "harness" { return "harness" }
    var key = String(c[3]) + "/" + String(c[4])
    if c[3] == "annexB" && c.count > 6 { key += "/" + String(c[5]) }
    return key
}

func jsTest262Env(_ name: String) -> String? {
    guard let p = getenv(name) else { return nil }
    return String(cString: p)
}

/// Roadmap ownership of every currently skipped feature/host hook.
func jsTest262SkipPhase(_ reason: String) -> String {
    let feature = reason.hasPrefix("feature ") ? String(reason.dropFirst(8)) : reason
    switch feature {
    case "iterator-helpers", "legacy-regexp", "uint8array-base64", "upsert", "joint-iteration", "iterator-sequencing", "Math.sumPrecise", "immutable-arraybuffer", "RegExp.escape", "Error.isError", "regexp-modifiers", "regexp-duplicate-named-groups", "json-parse-with-source", "nonextensible-applies-to-private": return "T5"
    case "Array.fromAsync", "explicit-resource-management", "await-dictionary", "Symbol.dispose", "Symbol.asyncDispose", "async": return "T6"
    case "import-attributes", "import-assertions", "json-modules", "source-phase-imports", "source-phase-imports-module-source", "import-defer", "import-text", "import-bytes", "$262.AbstractModuleSource", "AbstractModuleSource": return "T7"
    case "cross-realm", "ShadowRealm", "$262.createRealm": return "T8"
    case "Atomics", "SharedArrayBuffer", "Atomics.waitAsync", "Atomics.pause", "$262.agent": return "T9"
    case "tail-call-optimization": return "T10"
    case "Temporal": return "T11"
    case "IsHTMLDDA", "$262.IsHTMLDDA", "decorators", "Intl", "Intl.Locale", "Intl-enumeration", "intl-normative-optional", "canonical-tz": return "T12"
    default: return "unassigned"
    }
}

/// `dir full sample skip-ceiling` lines. Legacy three-column rows remain readable.
/// The full ceiling also bounds any sample, without assuming a uniform skip distribution.
func jsTest262ReadFloors() -> [String: (full: Int, sample: Int, skipCeiling: Int?)] {
    var out: [String: (full: Int, sample: Int, skipCeiling: Int?)] = [:]
    guard let bytes = hostReadFile("lib/js/tests/test262-floor.txt") else { return out }
    for line in String(decoding: bytes, as: UTF8.self).split(separator: "\n") {
        if line.hasPrefix("#") { continue }
        let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if f.count >= 3, let a = Int(f[1]), let b = Int(f[2]) {
            out[String(f[0])] = (a, b, f.count >= 4 ? Int(f[3]) : nil)
        }
    }
    return out
}

func jsTest262RunTests(_ t: Tests) {
    t.section("test262 run")
    jsTest262RunnerSelfTests(t)
    t.section("test262 run")
    guard t.readFileIfPresent("build/test262/LICENSE") != nil, t.readFileIfPresent("build/test262/harness/assert.js") != nil else {
        print("note js: build/test262 absent, test262 execution run skipped (lib/js/tools/fetch_test262.sh)")
        return
    }
    let full = jsTest262Env("WIFFER_TEST262") == "full"
    let filter = jsTest262Env("WIFFER_TEST262_FILTER")
    let stride = max(1, Int(jsTest262Env("WIFFER_TEST262_STRIDE") ?? "16") ?? 16)
    var roots = "build/test262/test/built-ins build/test262/test/annexB build/test262/test/language build/test262/test/intl402 build/test262/test/harness"
    if jsTest262Env("WIFFER_TEST262_STAGING") == "1" { roots += " build/test262/test/staging" }
    let files = jsTestShellLines("find " + roots + " -name '*.js' | LC_ALL=C sort")
    let jobs = jsTest262Jobs()
    var dirs: [String: JSTest262Dir] = [:]
    var skipReasons: [String: Int] = [:]
    var features: [String: JSTest262Dir] = [:]
    var phaseSkips: [String: Int] = [:]
    var trackedFailureReasons: [String: Int] = [:]
    var failures: [UInt8] = []
    var seen: [String: Int] = [:]
    var sampled: [String] = []   // passing tests, for the GC stress rerun
    let start = host_wall_millis()
    var selected: [(path: String, idx: Int)] = []
    for path in files {
        if jsTestHas(path, "_FIXTURE") { continue }
        if let f = filter, !jsTestHas(path, f) { continue }
        let key = jsTest262DirKey(path)
        let idx = seen[key] ?? 0
        seen[key] = idx + 1
        if !full && idx % stride != 0 { continue }
        selected.append((path, idx))
    }
    let outcomes = jsTest262RunAll(selected.map { $0.path }, gcStress: false, jobs: jobs, t)
    // Merged in path order, so the reports don't depend on scheduling.
    for (i, item) in selected.enumerated() {
        let path = item.path, idx = item.idx
        let key = jsTest262DirKey(path)
        let o = outcomes[i]
        if !o.readable {
            var d = dirs[key] ?? JSTest262Dir()
            d.fail += 1
            dirs[key] = d
            failures += Array("\(path): \(o.message)\n".utf8)
            continue
        }
        let r = JSTest262Result(status: o.status, message: o.message)
        let testMilliseconds = o.milliseconds
        let scope = path.hasPrefix("build/test262/test/intl402/") ? "intl402" : (path.hasPrefix("build/test262/test/staging/") ? "staging" : "gate")
        for tag in o.features {
            let featureKey = scope + " " + tag
            var f = features[featureKey] ?? JSTest262Dir()
            switch r.status {
            case .pass: f.pass += 1
            case .fail: f.fail += 1
            case .skip: f.skip += 1
            }
            f.milliseconds += testMilliseconds
            features[featureKey] = f
        }
        var d = dirs[key] ?? JSTest262Dir()
        switch r.status {
        case .pass:
            d.pass += 1
            if idx % (stride * 8) == 0 { sampled.append(path) }
        case .fail:
            d.fail += 1
            failures += Array("\(path): \(r.message)\n".utf8)
            if scope == "intl402" {
                let why = o.skipReason.isEmpty ? "conformance (see test262-failures.txt)" : o.skipReason
                trackedFailureReasons[why, default: 0] += 1
            }
        case .skip:
            d.skip += 1
            skipReasons[scope + " " + r.message, default: 0] += 1
            if scope == "gate" { phaseSkips[jsTest262SkipPhase(r.message), default: 0] += 1 }
        }
        d.milliseconds += testMilliseconds
        dirs[key] = d
    }
    let elapsed = host_wall_millis() - start

    // Report.
    let mode = (full ? "full" : "sample 1/\(stride)") + ", \(jobs) jobs"
    var text = "# test262 execution: \(mode), \(elapsed) ms\n# dir pass fail skip milliseconds\n"
    var tp = 0, tf = 0, ts = 0
    var tracked = JSTest262Dir(), staging = JSTest262Dir()
    for (k, d) in dirs.sorted(by: { $0.key < $1.key }) {
        text += "\(k) \(d.pass) \(d.fail) \(d.skip) \(d.milliseconds)\n"
        if k == "intl402" || k.hasPrefix("intl402/") {
            tracked.pass += d.pass; tracked.fail += d.fail; tracked.skip += d.skip
        } else if k == "staging" || k.hasPrefix("staging/") {
            staging.pass += d.pass; staging.fail += d.fail; staging.skip += d.skip
        } else {
            tp += d.pass; tf += d.fail; ts += d.skip
        }
    }
    text += "TOTAL \(tp) \(tf) \(ts)\n"
    text += "TRACKED \(tracked.pass) \(tracked.fail) \(tracked.skip)\n"
    text += "STAGING \(staging.pass) \(staging.fail) \(staging.skip)\n# skip reasons\n"
    for (k, n) in skipReasons.sorted(by: { $0.value > $1.value }) { text += "# \(n) \(k)\n" }
    text += "# gated skips by roadmap phase\n"
    for (phase, n) in phaseSkips.sorted(by: { $0.key < $1.key }) { text += "# \(phase) \(n)\n" }
    text += "# intl402 failure reasons (unsupported features are failures, not skips)\n"
    for (reason, n) in trackedFailureReasons.sorted(by: { $0.key < $1.key }) { text += "# \(n) \(reason)\n" }
    _ = hostWriteFile("build/hosttest/test262-results.txt", Array(text.utf8))
    _ = hostWriteFile("build/hosttest/test262-failures.txt", failures)
    var featureText = "# test262 features: \(mode); tests may have multiple tags\n# scope feature pass fail skip milliseconds\n"
    for (tag, f) in features.sorted(by: { $0.key < $1.key }) {
        featureText += "\(tag) \(f.pass) \(f.fail) \(f.skip) \(f.milliseconds)\n"
    }
    _ = hostWriteFile("build/hosttest/test262-features.txt", Array(featureText.utf8))
    print("test262 intl402: \(tracked.pass) passed, \(tracked.fail) failed, \(tracked.skip) skipped")
    print("test262 run (\(mode)): \(tp) passed, \(tf) failed, \(ts) skipped, \(elapsed) ms (build/hosttest/test262-results.txt)")

    // Floors.
    if filter == nil {
        let floors = jsTest262ReadFloors()
        for (k, fl) in floors.sorted(by: { $0.key < $1.key }) {
            let floor = full ? fl.full : fl.sample
            let got = k == "TOTAL" ? tp : (dirs[k]?.pass ?? 0)
            if floor > 0 { t.check(got >= floor, "test262 \(k): pass \(got) >= floor \(floor)") }
            if let ceiling = fl.skipCeiling {
                let skipped = k == "TOTAL" ? ts : (dirs[k]?.skip ?? 0)
                t.check(skipped <= ceiling, "test262 \(k): skip \(skipped) <= ceiling \(ceiling)")
            }
        }
    }

    // GC stress over a small sample: a passing test must keep passing.
    if filter == nil && !sampled.isEmpty {
        // The URI code-point sweeps take about a minute each with a GC per
        // allocation; they still run in the normal pass above.
        let stress = sampled.filter { path in
            let parts = path.split(separator: "/")
            return !(parts.contains("decodeURI") || parts.contains("decodeURIComponent") || parts.contains("encodeURI") || parts.contains("encodeURIComponent"))
        }
        var diff = 0
        let s0 = host_wall_millis()
        let stressOutcomes = jsTest262RunAll(stress, gcStress: true, jobs: jobs, t)
        for (i, path) in stress.enumerated() {
            let o = stressOutcomes[i]
            if !o.readable { continue }
            if o.milliseconds > 2000 { print("test262 gc stress: slow \(path) \(o.milliseconds) ms") }
            if o.status != .pass {
                diff += 1
                print("FAIL test262 gcEveryAllocation \(path): \(o.message)")
            }
        }
        print("test262 gc stress: \(sampled.count) tests, \(diff) differ, \(host_wall_millis() - s0) ms")
        t.check(diff == 0, "test262 sample unchanged under gcEveryAllocation", "\(diff) differ")
    }
}

// MARK: Parallel run
//
// Tests are independent (each variant gets a fresh realm), so the run forks
// WIFFER_TEST262_JOBS worker processes (default: one per CPU; 1 runs
// in-process, for a debugger). Each has its own JSTest262Runner and takes the
// next test index from a counter shared across fork, writing one line per test
// to build/hosttest/test262-worker-<n>.txt; the parent merges them in path
// order. Processes, not threads: the engine and the Embedded runtime assume
// one thread, and the per-test budget (hostMillis) is per-process CPU time.
// A worker that dies (crash, runaway guard) costs only the test it was on:
// that test fails the run by name, and a new worker picks up the rest.

/// One test's result as a worker reports it.
struct JSTest262Outcome {
    var readable = true
    var status = JSTest262Status.fail
    var milliseconds = 0
    /// For a failing intl402 test: the skip reason it would have had.
    var skipReason = ""
    var features: [String] = []
    var message = ""
}

func jsTest262Jobs() -> Int {
    if let s = jsTest262Env("WIFFER_TEST262_JOBS"), let n = Int(s), n >= 1 { return n }
    return Int(host_ncpu())
}

/// Tabs and newlines out of a worker-file field (and back).
func jsTest262Escape(_ s: String) -> String {
    var out: [UInt8] = []
    for b in s.utf8 {
        switch b {
        case 0x5C: out += [0x5C, 0x5C]
        case 0x0A: out += [0x5C, 0x6E]
        case 0x09: out += [0x5C, 0x74]
        case 0x0D: out += [0x5C, 0x72]
        default: out.append(b)
        }
    }
    return String(decoding: out, as: UTF8.self)
}

func jsTest262Unescape<S: Sequence>(_ s: S) -> String where S.Element == UInt8 {
    var out: [UInt8] = []
    var esc = false
    for b in s {
        if esc {
            switch b {
            case 0x6E: out.append(0x0A)
            case 0x74: out.append(0x09)
            case 0x72: out.append(0x0D)
            default: out.append(b)
            }
            esc = false
        } else if b == 0x5C {
            esc = true
        } else {
            out.append(b)
        }
    }
    return String(decoding: out, as: UTF8.self)
}

/// A worker: run tests until the shared counter passes the end, appending
/// `index status ms skipReason features message` lines (tab-separated) to
/// `out`, flushed per test so a crash loses only the test in flight.
func jsTest262Work(_ paths: [String], gcStress: Bool, counter: UnsafeMutablePointer<Int>, out: String) {
    guard let f = fopen(out, "wb") else { return }
    defer { fclose(f) }
    let runner = JSTest262Runner()
    runner.gcStress = gcStress
    while true {
        let i = host_counter_next(counter)
        if i >= paths.count { break }
        let path = paths[i]
        var line: String
        if let src = hostReadFile(path) {
            let meta = jsTest262Meta(src)
            let t0 = hostMillis()
            let r = runner.run(path: path, src: src, meta: meta)
            let ms = hostMillis() - t0
            let status = r.status == .pass ? "p" : (r.status == .fail ? "f" : "s")
            var why = ""
            if r.status == .fail && path.hasPrefix("build/test262/test/intl402/") { why = runner.skipReason(meta, src) ?? "" }
            var tags: [String] = []
            for tag in meta.features where !tags.contains(tag) { tags.append(tag) }
            line = "\(i)\t\(status)\t\(ms)\t\(jsTest262Escape(why))\t\(tags.joined(separator: ","))\t\(jsTest262Escape(r.message))\n"
        } else {
            line = "\(i)\tr\t0\t\t\tcannot read test file\n"
        }
        let bytes = Array(line.utf8)
        _ = bytes.withUnsafeBytes { fwrite($0.baseAddress, 1, bytes.count, f) }
        fflush(f)
    }
}

/// Run `paths` across `jobs` workers; outcomes in the order of `paths`.
func jsTest262RunAll(_ paths: [String], gcStress: Bool, jobs: Int, _ t: Tests) -> [JSTest262Outcome] {
    if paths.isEmpty { return [] }
    guard let counter = host_shared_counter() else {
        t.check(false, "test262 shared counter (mmap)")
        return paths.map { _ in JSTest262Outcome(readable: false, message: "not run: no shared counter") }
    }
    defer { host_shared_counter_free(counter) }
    var outFiles: [String] = []
    var deaths: [Int32] = []
    if jobs <= 1 {
        outFiles.append("build/hosttest/test262-worker-0.txt")
        jsTest262Work(paths, gcStress: gcStress, counter: counter, out: outFiles[0])
    } else {
        var live = 0
        func spawn() -> Bool {
            let out = "build/hosttest/test262-worker-\(outFiles.count).txt"
            outFiles.append(out)
            let pid = host_fork()
            if pid == 0 {
                host_guard_start()   // the parent's watchdog thread isn't forked
                jsTest262Work(paths, gcStress: gcStress, counter: counter, out: out)
                host_exit_now(0)
            }
            if pid < 0 { return false }
            live += 1
            return true
        }
        for _ in 0..<min(jobs, paths.count) where !spawn() { break }
        if live == 0 {
            // No fork: run here rather than not at all.
            outFiles.append("build/hosttest/test262-worker-\(outFiles.count).txt")
            jsTest262Work(paths, gcStress: gcStress, counter: counter, out: outFiles[outFiles.count - 1])
        }
        while live > 0 {
            var code: Int32 = 0
            if host_wait_any(&code) < 0 { break }
            live -= 1
            if code != 0 {
                deaths.append(code)
                if host_counter_load(counter) < paths.count { _ = spawn() }
            }
        }
    }
    var outcomes: [JSTest262Outcome?] = Array(repeating: nil, count: paths.count)
    for file in outFiles {
        guard let bytes = hostReadFile(file) else { continue }
        _ = remove(file)
        for line in bytes.split(separator: 0x0A) {
            let fields = line.split(separator: 0x09, maxSplits: 5, omittingEmptySubsequences: false)
            guard fields.count == 6, let i = Int(String(decoding: fields[0], as: UTF8.self)), i >= 0, i < paths.count else { continue }
            var o = JSTest262Outcome()
            switch fields[1].first {
            case 0x70: o.status = .pass
            case 0x73: o.status = .skip
            case 0x72: o.readable = false
            default: o.status = .fail
            }
            o.milliseconds = Int(String(decoding: fields[2], as: UTF8.self)) ?? 0
            o.skipReason = jsTest262Unescape(fields[3])
            o.features = fields[4].split(separator: 0x2C).map { String(decoding: $0, as: UTF8.self) }
            o.message = jsTest262Unescape(fields[5])
            outcomes[i] = o
        }
    }
    let why = deaths.isEmpty ? "worker died" : "worker died, exit status " + deaths.map { "\($0)" }.joined(separator: "/")
    var result: [JSTest262Outcome] = []
    for (i, o) in outcomes.enumerated() {
        if let o = o { result.append(o); continue }
        t.check(false, "test262 \(paths[i])\(gcStress ? " (gcEveryAllocation)" : ""): \(why) while running it")
        result.append(JSTest262Outcome(readable: true, status: .fail, message: why))
    }
    return result
}

/// Construct the harness's Test262Error so unsupported host hooks are explicit.
func jsTest262NotYet(_ realm: JSRealm, _ phase: String) -> JSThrow {
    do throws(JSThrow) {
        let ctor = try realm.getV(realm.global, realm.heap.key("Test262Error"))
        if realm.heap.isCallable(ctor) {
            let message = realm.heap.newString("not yet: " + phase)
            let root = realm.heap.root(message)
            defer { realm.heap.popRoots(to: root.slot) }
            return realm.throwValue(try realm.construct(ctor, args: [message]))
        }
    } catch { return error }
    // Raw tests have no harness constructor.
    let value = realm.makeError(.error, "not yet: " + phase)
    let root = realm.heap.root(value)
    realm.defineValue(value, "name", realm.heap.newString("Test262Error"), [.writable, .configurable])
    let thrown = realm.throwValue(value)
    realm.heap.popRoots(to: root.slot)
    return thrown
}

/// Runner regressions independent of the fetched corpus.
func jsTest262RunnerSelfTests(_ t: Tests) {
    t.section("test262 runner selftests")
    let runner = JSTest262Runner()
    func check(_ name: String, _ source: String, _ pass: Bool = true) {
        let bytes = Array(source.utf8)
        let result = runner.run(path: "build/hosttest/test262-runner-selftest.js", src: bytes, meta: jsTest262Meta(bytes))
        t.check((result.status == .pass) == pass, "test262 runner " + name, result.message)
    }
    check("raw has no harness or strict prefix", "/*---\nflags: [raw]\n---*/\nif (typeof assert !== 'undefined' || (function(){return this})() === undefined) throw 1;")
    // The fixture is intentionally invalid module syntax: import() must reject
    // with SyntaxError from the compiler, rather than a missing-loader error.
    _ = hostWriteFile("build/hosttest/test262-runner-bad_FIXTURE.js", Array("export const = ;".utf8))
    check("script dynamic import syntax error", "/*---\nflags: [async, raw]\n---*/\nimport('./test262-runner-bad_FIXTURE.js').then(function(){print('Test262:AsyncTestFailure')}, function(e){print(e instanceof SyntaxError ? 'Test262:AsyncTestComplete' : 'Test262:AsyncTestFailure')});")
    check("resolution does not execute", "/*---\nflags: [module, raw]\nnegative:\n  phase: resolution\n  type: SyntaxError\n---*/\nthrow new SyntaxError('runtime must not satisfy resolution');", false)
    _ = hostWriteFile("build/hosttest/test262-runner-good_FIXTURE.js", Array("export const value = 42;".utf8))
    check("script dynamic import", "/*---\nflags: [async, raw]\n---*/\nimport('./test262-runner-good_FIXTURE.js').then(function(m){print(m.value === 42 ? 'Test262:AsyncTestComplete' : 'Test262:AsyncTestFailure')}, function(){print('Test262:AsyncTestFailure')});")
    check("eval dynamic import", "/*---\nflags: [async, raw]\n---*/\neval(\"import('./test262-runner-good_FIXTURE.js').then(function(m){print(m.value === 42 ? 'Test262:AsyncTestComplete' : 'Test262:AsyncTestFailure')})\");")
    check("missing export resolution", "/*---\nflags: [module, raw]\nnegative:\n  phase: resolution\n  type: SyntaxError\n---*/\nimport {missing} from './test262-runner-good_FIXTURE.js'; throw 1;")
    check("parse negative", "/*---\nflags: [raw]\nnegative:\n  phase: parse\n  type: SyntaxError\n---*/\nvar = ;")
    check("parse negative cannot match runtime", "/*---\nflags: [raw]\nnegative:\n  phase: parse\n  type: SyntaxError\n---*/\nthrow new SyntaxError();", false)
    check("runtime negative cannot match parse", "/*---\nflags: [raw]\nnegative:\n  phase: runtime\n  type: SyntaxError\n---*/\nvar = ;", false)
    check("error message cannot spoof type", "/*---\nflags: [raw]\nnegative:\n  phase: runtime\n  type: SyntaxError\n---*/\nthrow new TypeError('SyntaxError');", false)
    check("non-deterministic still fails", "/*---\nflags: [raw, non-deterministic]\n---*/\nthrow 1;", false)
    check("host clock advances", "/*---\nflags: [raw]\n---*/\nvar before = Date.now(); while(Date.now() === before) {}")
    check("CanBlock false", "/*---\nflags: [raw, CanBlockIsFalse]\n---*/")
    t.check(!runner.canBlock, "test262 main host agent cannot block")
    check("CanBlock true", "/*---\nflags: [raw, CanBlockIsTrue]\n---*/")
    t.check(runner.canBlock, "test262 blocking host agent selected")
    let hookSource = Array("/*---\nflags: [raw]\n---*/\nfor (var f of [$262.createRealm, $262.agent.start]) { try { f(); throw 1; } catch(e) { if(e.name !== 'Test262Error' || e.message.indexOf('not yet: T') !== 0) throw e; } }".utf8)
    let hookResult = runner.runVariant(jsTest262Meta(hookSource), hookSource, strict: false, path: "<host hooks>")
    t.check(hookResult.status == .pass, "test262 future hooks report phases", hookResult.message)
    var slow = JSTest262Meta()
    slow.includes = ["regExpUtils.js"]
    t.check(runner.skipReason(slow, []) == nil, "test262 code point sweeps run without a skip")
    t.check(jsTest262Meta(Array("/*---\nflags: [CanBlockIsFalse, non-deterministic]\n---*/".utf8)).flags == ["CanBlockIsFalse", "non-deterministic"], "test262 host flags preserved")
}
