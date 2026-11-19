// lib/js host tests: the parser's (jsparser_tests.swift, Phase 9A) and the
// value/heap layer's (jscore_tests.swift).

func libTests(_ t: Tests) {
    jsParserTests(t)
    jsCoreTests(t)
}
