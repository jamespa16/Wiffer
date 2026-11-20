// Host tests for lib/js's compiler and VM (Phase 9B, second half).

/// Each case: source, expected evaluateToString result.
let jsVMCases: [(String, String)] = [
    ("1 + 2", "3"),
    ("var x = 5; x * 2", "10"),
    ("'a' + 1", "a1"),
]

func jsVMTests(_ t: Tests) {
    t.section("vm basics")
    let rt = JSRuntime(limits: JSLimits())
    for (src, want) in jsVMCases {
        let realm = rt.makeRealm()
        t.equal(realm.evaluateToString(src), want, src)
    }
}
