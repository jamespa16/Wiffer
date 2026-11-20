// Host tests for lib/js. Each part of the engine has its own test file;
// this is the single entry point hosttest.sh calls.

func libTests(_ t: Tests) {
    jsParserTests(t)
    jsCoreTests(t)
    jsDateTests(t)
    jsRegExpTests(t)
    jsVMTests(t)
    jsBuiltins2Tests(t)
    jsBuiltins1Tests(t)
    jsBuiltins3Tests(t)
    jsTest262RunTests(t)
}
