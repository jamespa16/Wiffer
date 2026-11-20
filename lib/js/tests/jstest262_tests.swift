// test262 parser run and the real-script corpus (Phase 9A).
//
// test262: lib/js/tools/fetch_test262.sh puts a pinned commit in
// build/test262 (gitignored). When it's there, every test under
// test/language and test/annexB/language is parsed (not run): a test
// with `negative: phase: parse` must fail to parse, every other must
// parse, in each mode its flags ask for (sloppy and strict by default,
// onlyStrict, noStrict/raw, module). Features newer than ES2022 syntax
// are skipped. Failures go to build/hosttest/test262-parse-failures.txt
// and the run fails if the pass count drops below the floor. Without
// build/test262 the run is skipped (not failed).

/// Raise by hand when the parser gets better (ROADMAP Phase 9A results).
let jsTest262ParseFloor = 23_785

/// Post-ES2022 syntax, skipped.
let jsTest262SkipFeatures: [String] = [
    "decorators", "import-attributes", "import-assertions", "json-modules",
    "source-phase-imports", "source-phase-imports-module-source", "import-defer",
    "explicit-resource-management", "regexp-modifiers", "regexp-duplicate-named-groups",
    "import-text", "import-bytes",
]

/// Lines of a shell command's output.
func jsTestShellLines(_ cmd: String) -> [String] {
    guard let p = host_popen(cmd) else { return [] }
    var out: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = buf.withUnsafeMutableBytes { fread($0.baseAddress, 1, 65536, p) }
        if n <= 0 { break }
        out.append(contentsOf: buf[0..<n])
    }
    _ = host_pclose(p)
    var lines: [String] = []
    var start = 0
    for i in 0..<out.count where out[i] == 0x0A {
        if i > start { lines.append(String(decoding: out[start..<i], as: UTF8.self)) }
        start = i + 1
    }
    return lines
}

func jsTestHas<S: StringProtocol>(_ s: S, _ p: String) -> Bool {
    let a = Array(s.utf8), b = Array(p.utf8)
    if b.isEmpty { return true }
    if a.count < b.count { return false }
    for i in 0...(a.count - b.count) where a[i] == b[0] {
        var ok = true
        for j in 1..<b.count where a[i + j] != b[j] { ok = false; break }
        if ok { return true }
    }
    return false
}

struct JSTest262Meta {
    /// negative: phase parse or early (parse-only run).
    var negativeParse = false
    var negativePhase = ""
    var negativeType = ""
    var onlyStrict = false
    var noStrict = false
    var module = false
    var raw = false
    var async = false
    var features: [String] = []
    var includes: [String] = []
    var flags: [String] = []
}

/// The frontmatter (/*--- ... ---*/) of a test262 file: flags, includes,
/// features and negative phase/type. (Shared by the parse-only run and the
/// execution runner, jstest262_run.swift.)
func jsTest262Meta(_ src: [UInt8]) -> JSTest262Meta {
    var m = JSTest262Meta()
    func find(_ pat: String, from: Int) -> Int {
        let p = Array(pat.utf8)
        var i = from
        while i + p.count <= src.count {
            if src[i] == p[0] {
                var ok = true
                for j in 1..<p.count where src[i + j] != p[j] { ok = false; break }
                if ok { return i }
            }
            i += 1
        }
        return -1
    }
    let a = find("/*---", from: 0)
    if a < 0 { return m }
    let b = find("---*/", from: a)
    if b < 0 { return m }
    var lines: [String] = []
    var ls = a
    for i in a...b where i == b || src[i] == 0x0A {
        var e = i
        if e > ls && src[e - 1] == 0x0D { e -= 1 }
        lines.append(String(decoding: src[ls..<e], as: UTF8.self))
        ls = i + 1
    }
    func items(_ s: Substring) -> [String] {
        var out: [String] = []
        for f in s.split(separator: ",") {
            let t = String(f.filter { $0 != " " && $0 != "[" && $0 != "]" && $0 != "\t" })
            if !t.isEmpty { out.append(t) }
        }
        return out
    }
    var cur = ""
    for line in lines {
        let trimmed = line.drop(while: { $0 == " " })
        let indented = line.first == " "
        if !indented {
            cur = ""
            for key in ["negative", "features", "includes", "flags"] where trimmed.hasPrefix(key + ":") {
                cur = key
                let rest = trimmed.dropFirst(key.count + 1)
                let list = items(rest)
                switch key {
                case "features": m.features += list
                case "includes": m.includes += list
                case "flags": m.flags += list
                default: break
                }
            }
            continue
        }
        if cur == "negative" {
            if trimmed.hasPrefix("phase:") {
                m.negativePhase = String(trimmed.dropFirst(6).filter { $0 != " " })
                if m.negativePhase == "parse" || m.negativePhase == "early" { m.negativeParse = true }
            } else if trimmed.hasPrefix("type:") {
                m.negativeType = String(trimmed.dropFirst(5).filter { $0 != " " })
            }
        } else if trimmed.hasPrefix("- ") {
            let item = String(trimmed.dropFirst(2).filter { $0 != " " })
            switch cur {
            case "features": m.features.append(item)
            case "includes": m.includes.append(item)
            case "flags": m.flags.append(item)
            default: break
            }
        }
    }
    m.onlyStrict = m.flags.contains("onlyStrict")
    m.noStrict = m.flags.contains("noStrict") || m.flags.contains("raw")
    m.module = m.flags.contains("module")
    m.raw = m.flags.contains("raw")
    m.async = m.flags.contains("async")
    return m
}

func jsTest262Tests(_ t: Tests) {
    t.section("test262 parse")
    guard t.readFileIfPresent("build/test262/LICENSE") != nil else {
        print("note js: build/test262 absent, test262 parse run skipped (lib/js/tools/fetch_test262.sh)")
        return
    }
    let files = jsTestShellLines("find build/test262/test/language build/test262/test/annexB/language -name '*.js' | sort")
    var pass = 0, fail = 0, skip = 0
    var negPass = 0, negFail = 0
    var report: [UInt8] = []
    var dirStats: [String: (Int, Int)] = [:]
    let start = hostMillis()
    for path in files {
        if jsTestHas(path, "_FIXTURE") { continue }
        guard let src = t.readFileIfPresent(path) else { continue }
        let meta = jsTest262Meta(src)
        if meta.features.contains(where: { jsTest262SkipFeatures.contains($0) }) { skip += 1; continue }
        var modes: [JSParseOptions] = []
        if meta.module {
            modes.append(JSParseOptions(module: true))
        } else {
            if !meta.onlyStrict { modes.append(JSParseOptions(strict: false)) }
            if !meta.noStrict { modes.append(JSParseOptions(strict: true)) }
        }
        var ok = true
        var why = ""
        for o in modes {
            do {
                _ = try jsParse(src, o)
                if meta.negativeParse { ok = false; why = "parsed (\(o.strict ? "strict" : o.module ? "module" : "sloppy")), expected SyntaxError" }
            } catch {
                if !meta.negativeParse {
                    ok = false
                    why = "\(o.strict ? "strict" : o.module ? "module" : "sloppy"): \(error.message) @\(error.line):\(error.column)"
                }
            }
            if !ok { break }
        }
        // Per-directory stats: test/language/<dir>/...
        let comps = path.split(separator: "/")
        let dir = comps.count > 4 ? comps[3] + "/" + comps[4] : "?"
        var st = dirStats[dir] ?? (0, 0)
        if ok {
            pass += 1; st.0 += 1
            if meta.negativeParse { negPass += 1 }
        } else {
            fail += 1; st.1 += 1
            if meta.negativeParse { negFail += 1 }
            report.append(contentsOf: Array("\(path): \(why)\n".utf8))
        }
        dirStats[dir] = st
    }
    _ = hostWriteFile("build/hosttest/test262-parse-failures.txt", report)
    var table = ""
    for (d, st) in dirStats.sorted(by: { $0.key < $1.key }) where st.1 > 0 {
        table += " \(d) \(st.0)/\(st.0 + st.1)"
    }
    print("test262 parse: \(pass) passed, \(fail) failed (\(negPass)/\(negPass + negFail) negative), \(skip) skipped, \(hostMillis() - start) ms")
    print("test262 parse failures by dir:\(table)")
    t.check(pass >= jsTest262ParseFloor, "test262 parse pass count \(pass) >= floor \(jsTest262ParseFloor)")
}

let jsCorpusFiles: [String] = [
    "jquery-3.7.1.js", "lodash-4.17.21.js", "preact-10.24.3.module.js", "vue-3.5.13.global.js",
    "three-0.170.0.module.js", "lit-core-3.2.1.min.module.js", "lobsters-application.module.js",
    "lobsters-user.module.js",
]

func jsCorpusTests(_ t: Tests) {
    t.section("corpus")
    for name in jsCorpusFiles {
        guard let src = t.readFile("lib/js/fixtures/corpus/\(name)") else { continue }
        let module = name.hasSuffix(".module.js")
        do {
            let ast = try jsParse(src, JSParseOptions(module: module))
            t.check(ast.nodes.count > src.count / 40, "\(name): plausible node count", "\(ast.nodes.count) nodes")
        } catch {
            t.check(false, "\(name) parses", "\(error.message) @\(error.line):\(error.column)")
        }
    }

    t.section("speed")
    // three.js: 1.3 MB of modern (ES2017+) code. Best of 5 runs.
    if let src = t.readFile("lib/js/fixtures/corpus/three-0.170.0.module.js") {
        var best = Int.max
        var nodes = 0
        for _ in 0..<5 {
            let s = hostMillis()
            if let ast = try? jsParse(src, JSParseOptions(module: true)) { nodes = ast.nodes.count }
            best = min(best, hostMillis() - s)
        }
        let kb = src.count / 1024
        print("js parse speed: three.js \(kb) KiB, \(nodes) nodes, \(best) ms (\(best > 0 ? kb * 1000 / best / 1024 : 0) MiB/s)")
        t.check(best < 1000, "1.3 MB parses in under a second", "\(best) ms")
    }
}
