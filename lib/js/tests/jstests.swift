// Host tests for lib/js. Each part of the engine has its own test file;
// this is the single entry point hosttest.sh calls.

func libTests(_ t: Tests) {
    // WIFFER_JS_BENCH=1: only the benchmarks, at full scale (jsbench_tests.swift).
    if jsTest262Env("WIFFER_JS_BENCH") != nil { jsBenchTests(t); return }
    jsParserTests(t)
    jsCoreTests(t)
    jsDateTests(t)
    jsRegExpTests(t)
    jsVMTests(t)
    jsVM2Tests(t)
    jsBuiltins2Tests(t)
    jsBuiltins1Tests(t)
    jsEmbedTests(t)
    jsHostTests(t)
    jsBuiltins3Tests(t)
    jsBuiltins4Tests(t)
    jsBenchTests(t)
    jsTest262RunTests(t)
}
