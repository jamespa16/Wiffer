// The vendored WPT subset (lib/js-dom/fixtures/wpt, see tools/vendor_wpt.py):
// each test page is parsed with lib/html, its scripts run in document
// order (testharness.js and helpers from the fixtures, a testharnessreport
// shim that reports through a native hook), then DOMContentLoaded and load
// fire and the event loop runs on a virtual clock until the harness is
// done. The total subtest pass count must stay at or above the floor in
// lib/js-dom/tests/wpt-floor.txt.
//
//     WIFFER_WPT_VERBOSE=1     per-test counts and failing subtests
//     WIFFER_WPT_ONLY=substr   run only matching tests
//     WIFFER_WPT_REGEN=1       write the new floor

struct JSDOMWPTResult {
    var pass = 0
    var fail = 0
    var harness = "OK"
    var failures: [String] = []
}

let jsdomWPTRoot = "lib/js-dom/fixtures/wpt/"

let jsdomWPTReportShim = """
setup({ output: false });
add_result_callback(function (t) { __wpt_result(t.status, t.name, t.message || ""); });
add_completion_callback(function (tests, status) { __wpt_done(status.status, status.message || ""); });
"""

func jsdomWPTResolve(_ testPath: String, _ src: String) -> String? {
    if src.hasPrefix("/") { return String(src.dropFirst()) }
    var parts = testPath.split(separator: "/").map(String.init)
    parts.removeLast()
    for p in src.split(separator: "/") {
        if p == ".." { if !parts.isEmpty { parts.removeLast() } }
        else if p != "." { parts.append(String(p)) }
    }
    var s = ""
    for (i, p) in parts.enumerated() { if i > 0 { s += "/" }; s += p }
    return s
}

final class JSDOMWPTBox {
    var result = JSDOMWPTResult()
    var done = false
    var clock = 0.0
    var errors: [String] = []
    init() {}
}

func jsdomRunWPT(_ t: Tests, _ path: String) -> JSDOMWPTResult {
    guard let bytes = t.readFile(jsdomWPTRoot + path) else { return JSDOMWPTResult(pass: 0, fail: 1, harness: "MISSING") }
    let text = String(decoding: bytes, as: UTF8.self)
    var scripts: [(String, String)] = []   // (name, source)
    let doc: HTMLNode
    let harness = t.readFile(jsdomWPTRoot + "resources/testharness.js").map { String(decoding: $0, as: UTF8.self) } ?? ""
    if path.hasSuffix(".js") {
        doc = htmlParse("<!DOCTYPE html><meta charset=utf-8><title>" + path + "</title><body><div id=log></div></body>")
        scripts.append(("testharness.js", harness))
        scripts.append(("testharnessreport.js", jsdomWPTReportShim))
        for line in text.split(separator: "\n") where line.hasPrefix("// META: script=") {
            let src = String(line.dropFirst("// META: script=".count))
            if let p = jsdomWPTResolve(path, src), let b = t.readFileIfPresent(jsdomWPTRoot + p) {
                scripts.append((p, String(decoding: b, as: UTF8.self)))
            }
        }
        scripts.append((path, text))
    } else {
        doc = htmlParse(bytes)
    }
    let box = JSDOMWPTBox()
    var host = JSDOMHost()
    host.now = { box.clock }
    host.wallClock = { 1_700_000_000_000 + box.clock }
    host.reportError = { msg, _ in box.errors.append(msg) }
    let page = JSDOMPage(document: doc, url: "http://web-platform.test:8000/" + path, host: host)
    let start = hostMillis()
    let gcStress = jsdomEnv("WIFFER_JSDOM_GCSTRESS") != nil
    if gcStress { page.realm.heap.gcEveryAllocation = true }
    let limit = gcStress ? 600_000 : 20_000
    page.runtime.interruptHandler = { _ in hostMillis() - start > limit }
    let realm = page.realm
    realm.defineMethod(realm.global, "__wpt_result", length: 3) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let st = Int(try realm.toNumber(args[0]))
        let name = try realm.toSwiftString(args[1])
        if st == 0 { box.result.pass += 1 } else {
            box.result.fail += 1
            if box.result.failures.count < 50 {
                let msg = try realm.toSwiftString(args[2])
                box.result.failures.append(["PASS", "FAIL", "TIMEOUT", "NOTRUN", "PRECONDITION"][min(max(st, 0), 4)] + " " + name + ": " + String(msg.prefix(200)))
            }
        }
        return .undefined
    }
    realm.defineMethod(realm.global, "__wpt_done", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let st = Int(try realm.toNumber(args[0]))
        box.result.harness = ["OK", "ERROR", "TIMEOUT", "PRECONDITION_FAILED"][min(max(st, 0), 3)]
        if st != 0 {
            let msg = try realm.toSwiftString(args[1])
            box.result.failures.append("HARNESS " + box.result.harness + ": " + String(msg.prefix(300)))
        }
        box.done = true
        return .undefined
    }
    if path.hasSuffix(".js") {
        for (name, src) in scripts { page.runScript(src, name: name) }
    } else {
        // Scripts in document order (after the parse, as 9H runs them).
        var nodes: [HTMLNode] = []
        doc.walk { n in
            if n.isHTML("script") { nodes.append(n) }
            return true
        }
        for s in nodes {
            let type = htmlLowerASCII(s.attribute("type") ?? "")
            if !(type.isEmpty || type == "text/javascript" || type == "application/javascript" || type == "module") { continue }
            if let src = s.attribute("src") {
                if src == "/resources/testharness.js" { page.runScript(harness, name: "testharness.js", element: s); continue }
                if src == "/resources/testharnessreport.js" { page.runScript(jsdomWPTReportShim, name: "testharnessreport.js", element: s); continue }
                if let p = jsdomWPTResolve(path, src), let b = t.readFileIfPresent(jsdomWPTRoot + p) {
                    page.runScript(bytes: b, name: p, element: s)
                }
                continue
            }
            var code: [UInt8] = []
            for c in s.children where c.kind == .text { code.append(contentsOf: c.data) }
            page.runScript(bytes: code, name: path, element: s)
        }
    }
    page.finishParsing()
    page.finishLoading()
    var iterations = 0
    while !box.done && iterations < 200_000 {
        iterations += 1
        page.loop.runDueTasks()
        if box.done { break }
        guard let d = page.loop.nextDeadline() else { break }
        if d > 0 { box.clock += d }
        if box.clock > 600_000 || hostMillis() - start > limit + 10_000 { break }
    }
    if !box.done {
        box.result.harness = "INCOMPLETE"
        if box.result.failures.count < 50 { box.result.failures.append("HARNESS did not complete") }
    }
    for e in box.errors.prefix(3) { box.result.failures.append("error: " + String(e.prefix(200))) }
    page.tearDown()
    doc.teardown()
    return box.result
}

func jsdomWPTTests(_ t: Tests) {
    t.section("wpt")
    guard let list = t.readFile(jsdomWPTRoot + "tests.txt") else { t.check(false, "wpt tests.txt"); return }
    let only = jsdomEnv("WIFFER_WPT_ONLY")
    let verbose = jsdomEnv("WIFFER_WPT_VERBOSE") != nil
    var pass = 0, fail = 0, files = 0, clean = 0
    let start = hostMillis()
    for line in String(decoding: list, as: UTF8.self).split(separator: "\n") {
        let path = String(line)
        if path.isEmpty { continue }
        if let o = only, !jsdomHasSubstring(path, o) { continue }
        host_guard_label("js-dom: wpt " + path)
        let t1 = hostMillis()
        let r = jsdomRunWPT(t, path)
        let elapsed = hostMillis() - t1
        files += 1
        pass += r.pass
        fail += r.fail
        if r.fail == 0 && r.harness == "OK" { clean += 1 }
        if verbose {
            var line = "wpt " + path + ": " + String(r.pass) + "/" + String(r.pass + r.fail)
            line += " " + r.harness + " " + String(elapsed) + " ms"
            print(line)
            for f in r.failures { print("    " + f) }
        }
    }
    let ms = hostMillis() - start
    var summary = "wpt: " + String(pass) + "/" + String(pass + fail)
    summary += " subtests pass, " + String(clean) + "/" + String(files)
    summary += " files clean (" + String(ms) + " ms)"
    print(summary)
    if only != nil { return }
    if jsdomEnv("WIFFER_WPT_REGEN") != nil {
        _ = hostWriteFile("lib/js-dom/tests/wpt-floor.txt", Array((String(pass) + "\n").utf8))
        return
    }
    let floor = t.readFile("lib/js-dom/tests/wpt-floor.txt").flatMap { jsdomParseInteger(String(decoding: $0, as: UTF8.self)) } ?? 0
    t.check(pass >= floor, "wpt pass count " + String(pass) + " >= floor " + String(floor))
}

func jsdomEnv(_ name: String) -> String? {
    guard let p = getenv(name) else { return nil }
    return String(cString: p)
}

