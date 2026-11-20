// html5lib tree-construction fixtures (lib/html/fixtures/*.dat, MIT licensed,
// see fixtures/LICENSE): parse #data, compare the tree dump with #document.
// Fragment cases (#document-fragment) parse with the given context element
// through htmlParseFragment. #script-on cases parse with the scripting flag
// (`scripting: true`). Failures are written to
// build/hosttest/html5lib-failures.txt; the run fails if the pass count
// drops below the recorded floor.

let html5libFiles: [String] = [
    "tests1", "tests2", "tests3", "tests4", "tests5", "tests6", "tests7", "tests8", "tests9",
    "tests10", "tests11", "tests12", "tests14", "tests15", "tests16", "tests17", "tests18",
    "tests19", "tests20", "tests21", "tests22", "tests23", "tests24", "tests25", "tests26",
    "adoption01", "adoption02", "blocks", "comments01", "doctype01", "entities01", "entities02",
    "html5test-com", "inbody01", "isindex", "main-element", "math", "menuitem-element",
    "namespace-sensitivity", "noscript01", "pending-spec-changes", "quirks01", "ruby",
    "scriptdata01", "search-element", "svg", "tables01", "template", "tests_innerHTML_1",
    "tricky01", "void-in-phrasing", "webkit01", "webkit02", "foreign-fragment",
]

struct Html5libCase {
    var data: [UInt8] = []
    var expected: [UInt8] = []
    var fragment = false
    var context: [UInt8] = []
    var scriptOn = false
}

func html5libParseFile(_ bytes: [UInt8]) -> [Html5libCase] {
    var cases: [Html5libCase] = []
    var cur: Html5libCase? = nil
    var section = ""
    var lines: [[UInt8]] = []
    var start = 0
    var i = 0
    while i <= bytes.count {
        if i == bytes.count || bytes[i] == 0x0a {
            if !(i == bytes.count && start == i) { lines.append(Array(bytes[start..<i])) }
            start = i + 1
        }
        i += 1
    }
    func finish() {
        guard var c = cur else { return }
        // Trailing blank line(s) after the document belong to the separator.
        while c.expected.last == 0x0a && c.expected.count >= 2 && c.expected[c.expected.count - 2] == 0x0a {
            c.expected.removeLast()
        }
        if c.data.last == 0x0a { c.data.removeLast() }
        cases.append(c)
        cur = nil
    }
    for line in lines {
        let s = String(decoding: line, as: UTF8.self)
        if s == "#data" { finish(); cur = Html5libCase(); section = "data"; continue }
        if cur == nil { continue }
        if s == "#errors" || s == "#new-errors" || s == "#document" || s == "#document-fragment"
            || s == "#script-on" || s == "#script-off" {
            section = s
            if s == "#document-fragment" { cur!.fragment = true }
            if s == "#script-on" { cur!.scriptOn = true }
            continue
        }
        switch section {
        case "data": cur!.data.append(contentsOf: line); cur!.data.append(0x0a)
        case "#document": cur!.expected.append(contentsOf: line); cur!.expected.append(0x0a)
        case "#document-fragment": if cur!.context.isEmpty { cur!.context = line }
        default: break
        }
    }
    finish()
    // The #data block's final newline is stripped in finish(); the expected
    // dump ends with exactly one newline after trimming separators.
    return cases
}

func html5libTests(_ t: Tests) {
    t.section("html5lib")
    var totalPass = 0, totalFail = 0, totalSkip = 0
    var tplPass = 0, tplFail = 0
    var fragPass = 0, fragFail = 0
    let ctxDoc = htmlNewDocument()   // owns the fragment contexts
    var report: [UInt8] = []
    for name in html5libFiles {
        guard let bytes = t.readFileIfPresent("lib/html/fixtures/\(name).dat") else { continue }
        var pass = 0, fail = 0, skip = 0
        var n = 0
        for c in html5libParseFile(bytes) {
            n += 1
            var got: [UInt8]
            if c.fragment {
                guard let ctx = html5libContext(c.context, ctxDoc) else { skip += 1; continue }
                got = Array(htmlTreeDump(htmlParseFragment(c.data, context: ctx, scripting: c.scriptOn)).utf8)
            } else {
                got = Array(htmlTreeDump(htmlParse(c.data, scripting: c.scriptOn)).utf8)
            }
            var want = c.expected
            while got.last == 0x0a { got.removeLast() }
            while want.last == 0x0a { want.removeLast() }
            if got == want { pass += 1; if c.fragment { fragPass += 1 } } else {
                if c.fragment { fragFail += 1 }
                fail += 1
                report.append(contentsOf: Array("=== \(name) #\(n)\n".utf8))
                report.append(contentsOf: c.data)
                report.append(contentsOf: Array("\n--- want\n".utf8))
                report.append(contentsOf: want)
                report.append(contentsOf: Array("\n--- got\n".utf8))
                report.append(contentsOf: got)
                report.append(0x0a)
            }
        }
        print("  html5lib \(name): \(pass)/\(pass + fail) passed, \(skip) skipped")
        totalPass += pass; totalFail += fail; totalSkip += skip
        if name == "template" { tplPass = pass; tplFail = fail }
    }
    _ = hostWriteFile("build/hosttest/html5lib-failures.txt", report)
    let rate = totalPass * 1000 / max(1, totalPass + totalFail)
    print("html5lib tree construction: \(totalPass)/\(totalPass + totalFail) passed (\(rate / 10).\(rate % 10)%), \(totalSkip) skipped")
    print("  fragment cases: \(fragPass)/\(fragPass + fragFail); template.dat: \(tplPass)/\(tplPass + tplFail)")
    t.check(totalPass >= html5libPassFloor, "html5lib pass count \(totalPass) >= floor \(html5libPassFloor)")
}

let html5libPassFloor = 1703

/// A fragment case's context: "td", "svg path", "math mi".
func html5libContext(_ line: [UInt8], _ doc: HTMLNode) -> HTMLNode? {
    let parts = htmlSplitWhitespace(String(decoding: line, as: UTF8.self))
    if parts.count == 2 {
        let ns: HTMLNamespace = parts[0] == "svg" ? .svg : .mathml
        return try? doc.createElementNS(ns, parts[1])
    }
    guard parts.count == 1 else { return nil }
    return try? doc.createElement(parts[0])
}
