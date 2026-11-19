func jsTestParse(_ src: String, module: Bool = false, strict: Bool = false) -> String {
    do {
        let ast = try jsParse(Array(src.utf8), JSParseOptions(module: module, strict: strict))
        return ast.dump(ast.root)
    } catch {
        return "error: \(error.message) @\(error.line):\(error.column)"
    }
}

func jsParserTests(_ t: Tests) {
    t.section("basic")
    t.equal(jsTestParse("var x = 1;"), "(script (var var (decl (id \"x\") (num 1))))", "var")
    jsCorpusTests(t)
    jsTest262Tests(t)
}
