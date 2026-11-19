// RegExp engine tests (Phase 9C): syntax/early errors, a table of
// pattern/subject/captures cases (spec examples and edge cases), Unicode
// properties against test262's generated property-escape data, case
// folding, step budget (ReDoS) and stack cap, and a pattern fuzzer.
//
// Strings in the tables are Swift strings, so patterns keep their
// backslashes; in subjects and expected captures "%uXXXX" stands for one
// UTF-16 code unit (for lone surrogates and control characters).

/// Swift string to UTF-16 units, with %uXXXX for a single unit.
func jsTU(_ s: String) -> [UInt16] {
    let a = Array(s.utf16)
    var out: [UInt16] = []
    var k = 0
    while k < a.count {
        if a[k] == 0x25 && k + 5 < a.count && a[k + 1] == 0x75 {
            var v: UInt16 = 0
            var ok = true
            for j in (k + 2)...(k + 5) {
                let h = jsReHex(a[j])
                if h < 0 { ok = false; break }
                v = v * 16 + UInt16(h)
            }
            if ok { out.append(v); k += 6; continue }
        }
        out.append(a[k])
        k += 1
    }
    return out
}

func jsTUString(_ u: [UInt16]) -> String {
    var s = ""
    for c in u {
        if c >= 0x20 && c < 0x7F { s += String(decoding: [UInt8(c)], as: UTF8.self) } else {
            let h: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B", "C", "D", "E", "F"]
            s += "%u"
            for sh in [12, 8, 4, 0] { s.append(h[Int((c >> UInt16(sh)) & 15)]) }
        }
    }
    return s
}

/// Run pattern/flags on subject from lastIndex: nil (no match), or the
/// captures as strings (nil for unmatched groups); "!error" / "!steps".
func jsReRun(_ pattern: String, _ flags: String, _ subject: String, from: Int = 0, steps: Int = 1_000_000) -> [String?]? {
    let prog: JSRegExpProgram
    do { prog = try jsRegExpCompile(pattern: Array(pattern.utf16), flags: Array(flags.utf16)) } catch {
        return ["!error " + error.message]
    }
    let subj = jsTU(subject)
    switch prog.exec(subj, from: from, stepLimit: steps) {
    case .noMatch: return nil
    case .stepLimit: return ["!steps"]
    case .stackLimit: return ["!stack"]
    case .match(let m):
        var out: [String?] = []
        for i in 0..<m.count {
            if m.matched(i) { out.append(jsTUString(Array(subj[m.start(i)..<m.end(i)]))) } else { out.append(nil) }
        }
        return out
    }
}

func jsReShow(_ r: [String?]?) -> String {
    guard let r = r else { return "null" }
    return "[" + r.map { $0.map { "\"" + $0 + "\"" } ?? "undefined" }.joined(separator: ", ") + "]"
}

/// (pattern, flags, subject, expected) — expected nil means no match.
let jsReMatchCases: [(String, String, String, [String?]?)] = [
    // Basics, alternation order, classes.
    ("abc", "", "xxabcxx", ["abc"]),
    ("a|ab", "", "abc", ["a"]),
    ("((a)|(ab))((c)|(bc))", "", "abc", ["abc", "a", "a", nil, "bc", nil, "bc"]),
    ("a[a-z]{2,4}", "", "abcdefghi", ["abcde"]),
    ("a[a-z]{2,4}?", "", "abcdefghi", ["abc"]),
    ("(aa|aabaac|ba|b|c)*", "", "aabaac", ["aaba", "ba"]),
    ("^(a+)\\1*,\\1+$", "", "aaaaaaaaaa,aaaaaaaaaaaaaaa", ["aaaaaaaaaa,aaaaaaaaaaaaaaa", "aaaaa"]),
    ("(z)((a+)?(b+)?(c))*", "", "zaacbbbcac", ["zaacbbbcac", "z", "ac", "a", nil, "c"]),
    ("(a*)*", "", "b", ["", nil]),
    ("(a*)b\\1+", "", "baaaac", ["b", ""]),
    ("(?=(a+))", "", "baaabac", ["", "aaa"]),
    ("(?=(a+))a*b\\1", "", "baaabac", ["aba", "a"]),
    ("(.*?)a(?!(a+)b\\2c)\\2(.*)", "", "baaabaac", ["baaabaac", "ba", nil, "abaac"]),
    ("(a*)+", "", "b", ["", ""]),
    ("(a?b??)*", "", "ab", ["ab", "b"]),
    ("(a|ab)(c|bcd)(d*)", "", "abcd", ["abcd", "a", "bcd", ""]),
    ("((a)|b)+", "", "ab", ["ab", "b", nil]),
    ("(?:(a)|b)*", "", "ab", ["ab", nil]),
    ("(a)?(b)?", "", "b", ["b", nil, "b"]),
    ("(a)|\\1b", "", "b", ["b", nil]),
    ("\\1(a)", "", "aa", ["a", "a"]),
    ("(\\2)(a)", "", "a", ["a", "", "a"]),
    ("a||b", "", "b", [""]),
    ("|", "", "x", [""]),
    ("", "", "", [""]),
    ("x*", "", "", [""]),
    ("[]", "", "a", nil),
    ("[^]", "", "\n", ["\n"]),
    ("[^]*", "", "a\nb", ["a\nb"]),
    ("[a-c]+", "", "xxabcabd", ["abcab"]),
    ("[^a-c]+", "", "abcxyz", ["xyz"]),
    ("[-a]+", "", "a-a", ["a-a"]),
    ("[a-]+", "", "a-a", ["a-a"]),
    ("[--0]+", "", "-./0", ["-./0"]),
    ("\\d+\\s\\w+", "", "x 12 ab_9!", ["12 ab_9"]),
    ("\\D\\S\\W", "", "1a b?", [" b?"]),
    ("[\\d.]+", "", "v1.25x", ["1.25"]),
    ("\\s+", "", "a%u00A0%u2028%uFEFF%u3000b", ["%u00A0%u2028%uFEFF%u3000"]),
    ("\\s", "", "%u180E", nil),
    // Quantifiers.
    ("a+?", "", "aaa", ["a"]),
    ("a*?b", "", "aab", ["aab"]),
    ("(a+?)(a*)", "", "aaa", ["aaa", "a", "aa"]),
    ("a{2,}?", "", "aaaa", ["aa"]),
    ("a{2}", "", "aaaa", ["aa"]),
    ("a{0}", "", "aaa", [""]),
    ("(a){0}", "", "aaa", ["", nil]),
    ("a{0,4294967295}", "", "aaa", ["aaa"]),
    ("a{2147483648}", "", "aaa", nil),
    ("a{3,5}b", "", "aab aaaab", ["aaaab"]),
    ("(?:ab){2,3}", "", "abababab", ["ababab"]),
    ("(?:ab){2,3}?", "", "abababab", ["abab"]),
    ("(ab){2}", "", "abab", ["abab", "ab"]),
    ("(?:a|b)*?c", "", "abbc", ["abbc"]),
    ("(a|b)*c", "", "abbc", ["abbc", "b"]),
    ("(?:(a)|(b))+", "", "ab", ["ab", nil, "b"]),
    ("(?:(a)|b(\\1))+", "", "aba", ["aba", "a", nil]),
    ("(?:a?)*?b", "", "aab", ["aab"]),
    ("(?:a*){2,}b", "", "b", ["b"]),
    ("(?:a*?){3}b", "", "aab", ["aab"]),
    ("(?:(?=(abc)))a", "", "abc", ["a", "abc"]),
    ("(?:(?=(abc)))?a", "", "abc", ["a", nil]),
    ("(?:(?=(abc))){1,1}a", "", "abc", ["a", "abc"]),
    ("(?:(?=(abc))){0,1}a", "", "abc", ["a", nil]),
    ("(?=(a))?a", "", "a", ["a", nil]),
    ("(?=a)*a", "", "a", ["a"]),
    ("x(?:a|())*y", "", "xay", ["xay", nil]),
    ("(?:()|a)*b", "", "aab", ["aab", nil]),
    ("(?:a|())*?b", "", "aab", ["aab", nil]),
    ("(a|)*b", "", "aab", ["aab", "a"]),
    ("(?:x|y{0,})+z", "", "xyz", ["xyz"]),
    // Anchors, \b, multiline, dotAll.
    ("^abc$", "", "abc", ["abc"]),
    ("^b", "", "a\nb", nil),
    ("^b", "m", "a\nb", ["b"]),
    ("a$", "", "a\nb", nil),
    ("a$", "m", "a\nb", ["a"]),
    ("^$", "m", "a\n\nb", [""]),
    ("a.b", "", "a\nb", nil),
    ("a.b", "", "a%u2028b", nil),
    ("a.b", "s", "a\nb", ["a\nb"]),
    ("a.c", "", "a%uD800c", ["a%uD800c"]),
    ("\\bfoo\\b", "", "a foo b", ["foo"]),
    ("\\bfoo\\b", "", "afoo b", nil),
    ("\\Boo\\B", "", "food", ["oo"]),
    ("\\b", "", "", nil),
    ("\\B", "", "", [""]),
    ("^\\b$", "", "", nil),
    ("(?:^|,)x", "", "a,x", [",x"]),
    // Lookaround.
    ("(?=a)a", "", "ba", ["a"]),
    ("a(?!b)", "", "abac", ["a"]),
    ("(?!(a))\\1b", "", "b", ["b", nil]),
    ("(?=(a))\\1", "", "a", ["a", "a"]),
    ("(?<=\\$)\\d+(\\.\\d*)?", "", "cost $10.53", ["10.53", ".53"]),
    ("(?<!\\$)\\d+(?:\\.\\d*)", "", "cost 10.53", ["10.53"]),
    ("(?<!\\$)\\d+", "", "$10 53", ["0"]),
    ("(?<=(\\d+)(\\d+))$", "", "1053", ["", "1", "053"]),
    ("(?<=(b+))c", "", "abbbbbbc", ["c", "bbbbbb"]),
    ("(?<=(b\\d+))c", "", "ab1234c", ["c", "b1234"]),
    ("(?<=((?:b\\d{2})+))c", "", "ab12b23b34c", ["c", "b12b23b34"]),
    ("(?<=^abc)def", "", "abcdef", ["def"]),
    ("(?<=^[a-c]{3})def", "", "abcdef", ["def"]),
    ("(?<=\\1(a))b", "", "aab", ["b", "a"]),
    ("(?<=(a)\\1)b", "", "aab", ["b", "a"]),
    ("(?<=a(?=b))b", "", "ab", ["b"]),
    ("(?<!abc)\\w\\w\\w", "", "abcdef", ["abc"]),
    ("(?<=a|bc)d", "", "xbcd", ["d"]),
    ("(?<=(?<a>\\w){3})f", "", "abcdef", ["f", "c"]),
    ("(?<=([abc])+)$", "", "abc", ["", "a"]),
    ("(?<!(^|[ab]))\\w{2}", "", "abcdef", ["de", nil]),
    ("(?<=ab(?=c)\\wd)\\w\\w", "", "abcdef", ["ef"]),
    ("(?<=a.)c", "s", "a\nc", ["c"]),
    ("(?<=\\b)\\w", "", " ab", ["a"]),
    ("(?<=𝒜)b", "u", "𝒜b", ["b"]),
    ("(?<=.)b", "u", "𝒜b", ["b"]),
    ("(?<=^.)b", "u", "𝒜b", ["b"]),
    ("(?<=^.)b", "", "𝒜b", nil),
    // Named groups and \k.
    ("(?<year>\\d{4})-(?<month>\\d{2})", "", "on 2020-12-01", ["2020-12", "2020", "12"]),
    ("(?<a>x)\\k<a>", "", "xx", ["xx", "x"]),
    ("\\k<a>(?<a>x)", "", "x", ["x", "x"]),
    ("(?<a>x)|\\k<a>y", "", "y", ["y", nil]),
    ("(?<\\u0061>x)\\k<a>", "", "xx", ["xx", "x"]),
    ("(?<a\\u{62}>x)\\k<ab>", "", "xx", ["xx", "x"]),
    ("(?<$𝒜>.)\\k<$𝒜>", "u", "zz", ["zz", "z"]),
    ("(?<$𝒜>.)", "", "z", ["z", "z"]),
    ("\\k", "", "k", ["k"]),
    ("\\k<a>", "", "k<a>", ["k<a>"]),
    ("[\\k]", "", "k", ["k"]),
    // Backreferences.
    ("(a)\\1", "i", "aA", ["aA", "a"]),
    ("(abc)\\1", "", "abcABC", nil),
    ("(abc)\\1", "i", "abcABC", ["abcABC", "abc"]),
    ("(.)\\1", "iu", "\u{10400}\u{10428}", ["\u{10400}\u{10428}", "\u{10400}"]),
    ("(.)\\1", "i", "%u017Fs", nil),
    ("(.)\\1", "iu", "%u017Fs", ["%u017Fs", "%u017F"]),
    ("(a)\\1\\1", "", "aaa", ["aaa", "a"]),
    ("(a)(?:\\1)*", "", "aaaa", ["aaaa", "a"]),
    ("(?:(a)|b)\\1c", "", "bc", ["bc", nil]),
    ("(a)\\10", "", "aa0", nil),
    ("(a)\\10", "", "a%u0008", ["a%u0008", "a"]),
    // Escapes and Annex B.
    ("\\0", "", "%u0000", ["%u0000"]),
    ("[\\b]", "", "%u0008", ["%u0008"]),
    ("\\t\\n\\v\\f\\r", "", "%u0009%u000A%u000B%u000C%u000D", ["%u0009%u000A%u000B%u000C%u000D"]),
    ("\\cJ\\cj", "", "\n\n", ["\n\n"]),
    ("\\x41\\u0042\\u{43}", "u", "ABC", ["ABC"]),
    ("\\u{2}", "", "uu", ["uu"]),
    ("\\x4", "", "x4", ["x4"]),
    ("\\x", "", "x", ["x"]),
    ("\\u12", "", "u12", ["u12"]),
    ("\\c", "", "\\c", ["\\c"]),
    ("\\c1", "", "\\c1", ["\\c1"]),
    ("[\\c]+", "", "c\\", ["c\\"]),
    ("[\\c1]", "", "%u0011", ["%u0011"]),
    ("[\\c_]", "", "%u001F", ["%u001F"]),
    ("[\\c*]+", "", "\\c*", ["\\c*"]),
    ("\\8\\9", "", "89", ["89"]),
    ("\\1", "", "%u0001", ["%u0001"]),
    ("\\101", "", "A", ["A"]),
    ("\\08", "", "%u00008", ["%u00008"]),
    ("\\377", "", "%u00FF", ["%u00FF"]),
    ("\\400", "", "%u00200", ["%u00200"]),
    ("[\\1-\\3]+", "", "%u0001%u0003", ["%u0001%u0003"]),
    ("[\\8]", "", "8", ["8"]),
    ("a{", "", "a{", ["a{"]),
    ("a{1", "", "a{1", ["a{1"]),
    ("a{1,", "", "a{1,", ["a{1,"]),
    ("a{,2}", "", "a{,2}", ["a{,2}"]),
    ("{", "", "{", ["{"]),
    ("}", "", "}", ["}"]),
    ("]", "", "]", ["]"]),
    ("x{1}{", "", "x{", ["x{"]),
    ("\\p{L}", "", "p{L}", ["p{L}"]),
    ("[\\d-a]+", "", "1-a", ["1-a"]),
    ("[a-\\d]+", "", "-a5", ["-a5"]),
    ("[\\s-\\d]+", "", " -1", [" -1"]),
    ("\\a\\e\\_", "", "ae_", ["ae_"]),
    ("\\-", "", "-", ["-"]),
    ("[\\-]", "u", "-", ["-"]),
    ("\\/", "u", "/", ["/"]),
    ("\\$", "", "$", ["$"]),
    ("\\B", "", "a", nil),
    ("[\\B]", "", "B", ["B"]),
    // Unicode mode.
    ("^.$", "u", "😀", ["😀"]),
    ("^.$", "", "😀", nil),
    ("^..$", "", "😀", ["😀"]),
    ("\\u{1F600}", "u", "x😀", ["😀"]),
    ("\\uD83D\\uDE00", "u", "x😀", ["😀"]),
    ("\\uD83D", "u", "😀", nil),
    ("\\uD83D", "", "😀", ["%uD83D"]),
    ("\\uDE00", "u", "😀", nil),
    ("\\uDE00", "u", "%uDE00", ["%uDE00"]),
    ("[😀-😂]", "u", "😁", ["😁"]),
    ("[😀]", "", "😀", ["%uD83D"]),
    ("😀+", "", "😀%uDE00", ["😀%uDE00"]),
    ("😀+", "u", "😀😀", ["😀😀"]),
    ("[^a]", "u", "😀", ["😀"]),
    ("[^a]", "", "😀", ["%uD83D"]),
    ("^[^x]$", "u", "%uD83D", ["%uD83D"]),
    ("\\S", "u", "😀", ["😀"]),
    ("^.$", "su", "\n", ["\n"]),
    ("a.", "u", "a%uDE00", ["a%uDE00"]),
    ("\\W", "u", "😀", ["😀"]),
    ("(?:)", "u", "😀", [""]),
    // Case-insensitive.
    ("abc", "i", "xABC", ["ABC"]),
    ("[a-z]+", "i", "HeLLo1", ["HeLLo"]),
    ("[A-Z]+", "i", "heLLo1", ["heLLo"]),
    ("\\u212A", "i", "k", nil),
    ("\\u212A", "iu", "k", ["k"]),
    ("k", "iu", "%u212A", ["%u212A"]),
    ("[k]", "iu", "%u212A", ["%u212A"]),
    ("[%u212A]", "iu", "K", nil),
    ("[\\u212A]", "iu", "K", ["K"]),
    ("s", "i", "%u017F", nil),
    ("s", "iu", "%u017F", ["%u017F"]),
    ("ß", "i", "SS", nil),
    ("ß", "i", "ẞ", nil),
    ("ß", "iu", "ẞ", ["ẞ"]),
    ("[^a]", "i", "A", nil),
    ("[^a]", "iu", "A", nil),
    ("\\W", "iu", "%u017F", nil),
    ("\\W", "iu", "S", nil),
    ("\\W", "i", "%u017F", ["%u017F"]),
    ("\\w", "iu", "%u212A", ["%u212A"]),
    ("[\\W\\d]", "iu", "S", nil),
    ("[^\\W]", "iu", "%u017F", ["%u017F"]),
    ("\\b", "iu", "%u017F", [""]),
    ("\\b", "i", "%u017F", nil),
    ("σ", "i", "Σς", ["Σ"]),
    ("ς", "i", "Σ", ["Σ"]),
    ("ς", "iu", "σ", ["σ"]),
    ("[α-ω]+", "i", "ΑΒΓ", ["ΑΒΓ"]),
    ("\u{10400}", "iu", "\u{10428}", ["\u{10428}"]),
    ("\u{10400}", "i", "\u{10428}", nil),
    ("ǆ", "i", "ǅ", ["ǅ"]),
    ("ǆ", "i", "Ǆ", ["Ǆ"]),
    ("i", "i", "İ", nil),
    ("i", "iu", "ı", nil),
    ("[^\\u0000-\\u0060\\u007B-\\uFFFF]", "i", "A", nil),
    ("\\p{Lu}", "iu", "a", ["a"]),
    ("\\P{Lu}", "iu", "A", ["A"]),
    ("[\\p{Ll}]", "iu", "Q", ["Q"]),
    // Unicode properties.
    ("\\p{Lu}+", "u", "abCDe", ["CD"]),
    ("\\p{L}+", "u", "1héllo2", ["héllo"]),
    ("\\p{Script=Greek}+", "u", "aαβγb", ["αβγ"]),
    ("\\p{sc=Grek}", "u", "%u0342", nil),
    ("\\p{scx=Grek}", "u", "%u0342", ["%u0342"]),
    ("\\p{scx=Hira}", "u", "%u30FC", ["%u30FC"]),
    ("\\p{sc=Hira}", "u", "%u30FC", nil),
    ("\\P{Any}", "u", "a😀", nil),
    ("\\p{Any}", "u", "😀", ["😀"]),
    ("\\p{ASCII}+", "u", "éab", ["ab"]),
    ("\\p{Assigned}", "u", "%u0378", nil),
    ("\\p{Emoji_Presentation}", "u", "x😀", ["😀"]),
    ("[\\p{N}-]+", "u", "1-2x", ["1-2"]),
    ("\\p{Nd}+", "u", "x٣٤y", ["٣٤"]),
    ("[^\\P{Lu}]", "u", "aB", ["B"]),
    ("\\p{White_Space}", "u", "a%u2003", ["%u2003"]),
    ("\\p{space}", "u", "a%u2003", ["%u2003"]),
    // Sticky and flags that don't change matching.
    ("a", "y", "ba", nil),
    ("a", "g", "ba", ["a"]),
    ("a", "d", "ba", ["a"]),
    ("^a", "y", "ab", ["a"]),
]

/// (pattern, flags, valid)
let jsReSyntaxCases: [(String, String, Bool)] = [
    ("(?<>a)", "", false), ("(?<>a)", "u", false), ("a{2,1}", "", false), ("a{2,1}", "u", false),
    ("\\u{1F_639}", "u", false), ("\\u{110000}", "u", false), ("\\u{10FFFF}", "u", true), ("\\u{1,}", "u", false),
    ("\\M", "u", false), ("\\M", "", true), ("\\k<a>", "u", false), ("\\k<a>(?<b>x)", "", false),
    ("\\k<a>(?<ab>a)", "u", false), ("\\k<a/", "u", false), ("\\k<a(?<a>a)", "", false), ("\\k<>", "u", false),
    ("\\k", "u", false), ("\\k(?<a>.)", "", false), ("\\c0", "u", false), ("\\c0", "", true), ("\\8", "u", false),
    ("\\1", "u", false), ("(a)\\1", "u", true), ("{2}", "", false), ("{2,3}", "", false), ("{2,}", "", false),
    ("{", "u", false), ("}", "u", false), ("]", "u", false), ("[%-\\d]", "u", false), ("[\\s-\\d]", "u", false),
    ("[\\d-a]", "u", false), ("[--\\d]", "u", false), ("[\\d-]", "u", true), ("[-\\d]", "u", true),
    ("(?<ab>a)\\k<a>", "", false), ("(?<aa)", "", false), ("(?<a>a)\\k<ab>", "u", false),
    ("(?<a>a)(?<b>b)(?<a>a)", "", false), ("(?<a>a)(?<a>a)", "u", false), ("(?<a>\\a)", "u", false),
    ("(?<a>.)\\k<a", "", false), ("(?<a>.)\\k", "", false), ("(?<a\\uDCA4>.)", "", false),
    ("(?<a\\uD83D\\uDF12>.)", "", false), ("(?<a\\uD835\\uDC9C>.)", "", true), ("(?<a\\u{1D49C}>.)", "", true),
    ("(?<a\\uD801>.)", "u", false), ("(?<a\\u{110000}>.)", "u", false), ("(?<a\\>.)", "", false),
    ("(?<a:>a)", "", false), ("(?<42a>a)", "", false), ("(?<$❞>a)", "", false), ("(?<:a>a)", "", false),
    ("(?<a𝒜>.)", "", true), ("(?<π>a)", "", true), ("(?<$_\\u200C\\u200D>a)", "", true),
    (".(?=.){2,3}", "u", false), (".(?=.)?", "u", false), (".(?=.)?", "", true), (".(?!.){2,3}", "", true),
    (".(?<=.){2,3}", "", false), (".(?<=.)?", "", false), (".(?<!.)?", "u", false), ("?", "", false),
    ("*", "", false), ("+", "", false), ("a**", "", false), ("a???", "", false), ("a{1}{2}", "", false),
    ("a{1}?", "", true), ("^*", "", false), ("$+", "", false), ("\\b*", "", false), ("\\B{1}", "u", false),
    ("(", "", false), (")", "", false), ("(?", "", false), ("(?a)", "", false), ("(?:", "", false),
    ("[", "", false), ("[a", "", false), ("[a-", "", false), ("[z-a]", "", false), ("[\\u{1F600}-\\u{1F5FF}]", "u", false),
    ("\\", "", false), ("a\\", "", false), ("[\\", "", false), ("\\x1", "u", false), ("\\u12", "u", false),
    ("\\p{L}", "u", true), ("\\p{L}", "", true), ("\\p{Ascii}", "u", false), ("\\p{ASCII}", "u", true),
    ("\\p{InScript=Adlam}", "u", false), ("\\p{IsScript=Adlam}", "u", false), ("\\p{Script=Adlam}", "u", true),
    ("\\p{sc=Adlm}", "u", true), ("\\p{scx=Qaai}", "u", true), ("\\p{Script}", "u", false), ("\\p{gc}", "u", false),
    ("\\p{General_Category=Letter}", "u", true), ("\\p{gc=L}", "u", true), ("\\p{L=gc}", "u", false),
    ("\\p{Letter}", "u", true), ("\\p{lu}", "u", false), ("\\p{ Lu}", "u", false), ("\\p{Lu", "u", false),
    ("\\p", "u", false), ("\\pL", "u", false), ("\\p{}", "u", false), ("\\p{=}", "u", false), ("\\p{gc=}", "u", false),
    ("\\p{=Lu}", "u", false), ("\\p{ASCII=Yes}", "u", false), ("\\p{WSpace}", "u", false), ("\\p{space}", "u", true),
    ("\\p{Block=Adlam}", "u", false), ("\\p{RGI_Emoji}", "u", false), ("\\P{Any}", "u", true),
    ("[\\p{L}-z]", "u", false), ("[\\p{L}]", "u", true), ("[\\p{N}--]", "u", false), ("\\p{L}", "v", true),
    ("\\00", "u", false), ("\\0", "u", true), ("[\\0]", "u", true), ("[\\00]", "u", false), ("[\\1]", "u", false),
    ("[\\B]", "u", false), ("\\-", "u", false), ("[\\-]", "u", true), ("\\/", "u", true), ("\\a", "u", false),
    ("[\\k]", "", true), ("[\\k](?<a>.)", "", false), ("\\k<a>", "", true), ("\\k<a>(?<a>.)", "", true),
    ("(?<a>.)|(?<a>.)", "", false), ("a{9007199254740993,9007199254740992}", "", false),
    ("a{9007199254740991}", "", true), ("x{2147483648,2147483647}", "", false), ("\\u{2}", "", true),
    ("(?=a){1}", "", true), ("[a-\\b]", "", false), ("[\\b-\\n]", "", true), ("\\c", "u", false),
    ("[\\c]", "u", false), ("[\\c1]", "", true), ("[\\c1]", "u", false), ("\\u{0000000041}", "u", true),
    ("a", "gg", false), ("a", "uv", false), ("a", "x", false), ("a", "dgimsuy", true),
]

func jsReSyntaxTests(_ t: Tests) {
    t.section("regexp syntax")
    for (p, f, valid) in jsReSyntaxCases {
        let r = jsRegExpValidate(pattern: Array(p.utf16), flags: Array(f.utf16))
        t.check((r == nil) == valid, "/\(p)/\(f) \(valid ? "valid" : "invalid")", r ?? "accepted")
    }
}

func jsReMatchTests(_ t: Tests) {
    t.section("regexp match")
    for (p, f, s, want) in jsReMatchCases {
        let got = jsReRun(p, f, s)
        let wantT = want.map { $0.map { $0.map { jsTUString(jsTU($0)) } } }
        t.check(jsReShow(got) == jsReShow(wantT), "/\(p)/\(f) on \"\(s)\"", "got \(jsReShow(got)), want \(jsReShow(wantT))")
    }
}

func jsReAPITests(_ t: Tests) {
    t.section("regexp api")
    // lastIndex and sticky.
    t.equal(jsReShow(jsReRun("a", "y", "ba", from: 1)), "[\"a\"]", "sticky at lastIndex")
    t.equal(jsReShow(jsReRun("a", "y", "bba", from: 1)), "null", "sticky doesn't scan")
    t.equal(jsReShow(jsReRun("a", "", "aba", from: 1)), "[\"a\"]", "scan from lastIndex")
    t.equal(jsReShow(jsReRun("a", "", "aba", from: 4)), "null", "lastIndex past the end")
    t.equal(jsReShow(jsReRun("$", "", "ab", from: 2)), "[\"\"]", "empty match at the end")
    t.equal(jsReShow(jsReRun("^b", "", "ab", from: 1)), "null", "^ is not lastIndex")
    t.equal(jsReShow(jsReRun("^b", "m", "a\nb", from: 1)), "[\"b\"]", "^m scans")
    if let p = try? jsRegExpCompile(pattern: Array("(?<=a)b|(?<x>c)(d)?".utf16), flags: Array("gd".utf16)) {
        t.equal(p.captureCount, 2, "captureCount")
        t.check(p.groupNames.count == 3 && p.groupNames[1] == Array("x".utf16) && p.groupNames[2].isEmpty, "groupNames")
        t.check(p.namedGroups.count == 1 && p.namedGroups[0].index == 1, "namedGroups")
        t.check(p.flags.global && p.flags.hasIndices && !p.flags.sticky, "flags")
        t.equal(p.flags.string, "dg", "flags string")
        if case .match(let m) = p.exec(Array("xxcz".utf16), from: 0) {
            t.check(m.start(0) == 2 && m.end(0) == 3 && m.start(1) == 2 && m.end(1) == 3 && !m.matched(2), "indices")
        } else { t.check(false, "match") }
        // Latin-1 storage matches the same.
        let bytes: [UInt8] = Array("ab".utf8)
        if case .match(let m) = p.exec(bytes, from: 0) { t.check(m.start(0) == 1, "latin1 subject") } else { t.check(false, "latin1 subject") }
        t.check(!p.disassemble().isEmpty, "disassemble")
    } else { t.check(false, "compile") }
    // Unicode lastIndex inside a surrogate pair moves back to the pair.
    if let p = try? jsRegExpCompile(pattern: Array(".".utf16), flags: Array("u".utf16)) {
        if case .match(let m) = p.exec(jsTU("%uD83D%uDE00"), from: 1) {
            t.check(m.start(0) == 0 && m.end(0) == 2, "u: lastIndex in a pair")
        } else { t.check(false, "u: lastIndex in a pair") }
    }
    // Heap strings.
    let heap = JSHeap()
    if let p = try? jsRegExpCompile(pattern: Array("b+".utf16), flags: Array("".utf16)) {
        let s1 = heap.newString("abbbc"), s2 = heap.newString("ab\u{3b1}bb")
        if case .match(let m) = heap.regExpExec(p, s1, from: 0) { t.check(m.start(0) == 1 && m.end(0) == 4, "heap latin1") } else { t.check(false, "heap latin1") }
        if case .match(let m) = heap.regExpExec(p, s2, from: 2) { t.check(m.start(0) == 3 && m.end(0) == 5, "heap utf16") } else { t.check(false, "heap utf16") }
    }
    // Cache.
    let cache = JSRegExpCache(capacity: 2)
    let a1 = try? cache.program(pattern: Array("a".utf16), flags: JSRegExpFlags())
    let a2 = try? cache.program(pattern: Array("a".utf16), flags: JSRegExpFlags())
    let ai = try? cache.program(pattern: Array("a".utf16), flags: JSRegExpFlags(units: Array("i".utf16)) ?? JSRegExpFlags())
    t.check(a1 != nil && a1 === a2 && a1 !== ai, "cache hit")
    var bad = false
    do { _ = try cache.program(pattern: Array("(".utf16), flags: JSRegExpFlags()) } catch { bad = true }
    t.check(bad, "cache compile error")
    // u-mode + ignoreCase word characters: only U+017F and U+212A fold into \w.
    let runs = jsReDecodeCaseTable(unicode: true)
    var extra: [UInt32] = []
    for c in UInt32(0x80)...0x10FFFF {
        let f = jsReCanonicalize(c, runs, unicode: true)
        if f < 0x80 && jsReIsWordChar(f) { extra.append(c) }
    }
    t.check(extra == [0x17F, 0x212A], "u+i extra word characters", "\(extra)")
    let up = jsReDecodeCaseTable(unicode: false)
    t.equal(Int(jsReCanonicalize(0xE9, up, unicode: false)), 0xC9, "upper é")
    t.equal(Int(jsReCanonicalize(0xDF, up, unicode: false)), 0xDF, "upper ß stays (two units)")
    t.equal(Int(jsReCanonicalize(0x17F, up, unicode: false)), 0x17F, "upper ſ stays (non-ASCII to ASCII)")
    t.equal(Int(jsReCanonicalize(0x1C5, up, unicode: false)), 0x1C4, "upper ǅ")
    t.equal(Int(jsReCanonicalize(0x3C2, up, unicode: false)), 0x3A3, "upper ς")
    t.equal(Int(jsReCanonicalize(0x1E9E, runs, unicode: true)), 0xDF, "fold ẞ")
    t.equal(Int(jsReCanonicalize(0x10400, runs, unicode: true)), 0x10428, "fold Deseret")
}

func jsReIsWordChar(_ c: UInt32) -> Bool {
    (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39) || c == 0x5F
}

func jsReLimitTests(_ t: Tests) {
    t.section("regexp limits")
    // ReDoS: catastrophic backtracking ends on the step budget, quickly.
    let evil: [(String, String)] = [
        ("(a+)+$", String(repeating: "a", count: 30) + "b"),
        ("(a|a)*b", String(repeating: "a", count: 40)),
        ("(a|aa)+$", String(repeating: "a", count: 60) + "b"),
        ("(.*a){20}", String(repeating: "a", count: 40)),
        ("^(\\w+\\s?)*$", "An input string that takes a long time or even makes this regex to hang!"),
        ("(?=(a+)+$)x", String(repeating: "a", count: 40) + "b"),
        ("(?<=x(a+)+)b", String(repeating: "a", count: 30) + "b"),
    ]
    for (p, s) in evil {
        let start = hostMillis()
        let r = jsReRun(p, "", s, steps: JSLimits().maxRegexSteps)
        let ms = hostMillis() - start
        t.check(jsReShow(r) == "[\"!steps\"]", "/\(p)/ terminates on the step budget", jsReShow(r))
        t.check(ms < 2000, "/\(p)/ budget is quick", "\(ms) ms")
        if p == "(a+)+$" { print("js regexp: (a+)+$ on 30 a's + b hit the 10M step budget in \(ms) ms") }
    }
    // Big but linear work fits the budget.
    let long = String(repeating: "ab", count: 100_000)
    t.check(jsReShow(jsReRun("(?:ab)*$", "", long, steps: JSLimits().maxRegexSteps)).count > 10, "long linear match")
    t.equal(jsReShow(jsReRun("[^x]*y", "", String(repeating: "a", count: 5000), steps: JSLimits().maxRegexSteps)), "[\"!steps\"]", "quadratic scan hits the budget")
    // The backtrack stack cap.
    if let p = try? jsRegExpCompile(pattern: Array("(a|b)*c".utf16), flags: Array("".utf16)) {
        p.maxBacktrackEntries = 10_000
        let s = Array(String(repeating: "ab", count: 50_000).utf16)
        if case .stackLimit = p.exec(s, from: 0, stepLimit: 100_000_000) { t.check(true, "stack cap") } else { t.check(false, "stack cap") }
        p.maxBacktrackEntries = 4 << 20
        let r = p.exec(Array((String(repeating: "ab", count: 50_000) + "c").utf16), from: 0, stepLimit: 100_000_000)
        if case .match(let m) = r { t.check(m.end(0) == 100_001, "deep backtrack stack ok") } else { t.check(false, "deep backtrack stack ok") }
    }
    // Deep nesting is an error, not a crash.
    let deep = String(repeating: "(", count: 100_000) + String(repeating: ")", count: 100_000)
    t.check(jsRegExpValidate(pattern: Array(deep.utf16), flags: [UInt16]()) != nil, "deep nesting rejected")
    let ok = String(repeating: "(?:", count: 200) + "a" + String(repeating: ")*", count: 200)
    t.check(jsReShow(jsReRun(ok, "", "aaa")) == "[\"aaa\"]", "200 nested quantified groups")
    let wide = String(repeating: "a|", count: 50_000) + "b"
    t.check(jsReShow(jsReRun(wide, "", "b")) == "[\"b\"]", "50k alternatives")
    // Timing: a simple scan over 1 MB.
    let big = Array((String(repeating: "x", count: 1_000_000) + "needle").utf16)
    if let p = try? jsRegExpCompile(pattern: Array("ne+dle".utf16), flags: Array("".utf16)),
       let q = try? jsRegExpCompile(pattern: Array("[a-n]e+dle".utf16), flags: Array("i".utf16)) {
        let t0 = hostMillis()
        let r1 = p.exec(big, from: 0, stepLimit: Int.max)
        let t1 = hostMillis()
        let r2 = q.exec(big, from: 0, stepLimit: Int.max)
        let t2 = hostMillis()
        if case .match = r1, case .match = r2 { t.check(true, "1 MB scans") } else { t.check(false, "1 MB scans") }
        print("js regexp: 1 MB scan, literal first char \(t1 - t0) ms, class first \(t2 - t1) ms")
    }
}

/// Parse the generated property-escape tests in test262 (when present):
/// every \p{...} set must equal the listed code points exactly.
func jsRePropertyTests(_ t: Tests) {
    t.section("regexp unicode properties")
    let files = jsTestShellLines("ls build/test262/test/built-ins/RegExp/property-escapes/generated/*.js 2>/dev/null")
    if files.isEmpty {
        print("note js: build/test262 absent, property-escape data checks skipped")
        // A few fixed checks instead.
        t.check(jsRePropertySet(lone: Array("Lu".utf16))?.contains(0x41) == true, "Lu has A")
        return
    }
    var checked = 0, failed = 0, matched = 0
    for path in files {
        guard let src = t.readFileIfPresent(path) else { continue }
        let text = Array(src)
        var k = 0
        func find(_ s: String, _ from: Int) -> Int {
            let p = Array(s.utf8)
            var i = from
            while i + p.count <= text.count {
                if text[i] == p[0] {
                    var ok = true
                    for j in 1..<p.count where text[i + j] != p[j] { ok = false; break }
                    if ok { return i }
                }
                i += 1
            }
            return -1
        }
        while true {
            let b = find("buildString({", k)
            if b < 0 { break }
            let e = find("});", b)
            if e < 0 { break }
            // Hex numbers in order: lone code points, then range pairs.
            let rangesAt = find("ranges:", b)
            var lone: [UInt32] = [], pairs: [UInt32] = []
            var i = b
            while i < e {
                if text[i] == 0x30 && i + 1 < e && text[i + 1] == 0x78 {
                    var v: UInt32 = 0
                    i += 2
                    while i < e, jsHexValue(text[i]) >= 0 { v = v * 16 + UInt32(jsHexValue(text[i])); i += 1 }
                    if rangesAt >= 0 && i > rangesAt { pairs.append(v) } else { lone.append(v) }
                    continue
                }
                i += 1
            }
            var want = JSReCharSet()
            for c in lone { want.add(c, c) }
            var j = 0
            while j + 1 < pairs.count { want.add(pairs[j], pairs[j + 1]); j += 2 }
            want.normalize()
            // The regexes that use this set, up to the next buildString.
            let next = find("buildString({", e)
            let stop = next < 0 ? text.count : next
            var r = e
            while true {
                let a = find("/^\\", r)
                if a < 0 || a >= stop { break }
                let z = find("+$/u", a)
                if z < 0 || z >= stop { break }
                let body = Array(text[(a + 2)..<z])    // \p{...}
                r = z + 4
                guard body.count > 4 else { continue }
                let negate = body[1] == 0x50
                let inner = Array(body[3..<(body.count - 1)]).map { UInt16($0) }
                var got: JSReCharSet?
                if let eq = inner.firstIndex(of: 0x3D) {
                    got = jsRePropertySet(name: Array(inner[..<eq]), value: Array(inner[(eq + 1)...]))
                } else {
                    got = jsRePropertySet(lone: inner)
                }
                if negate { got = got?.inverted(max: 0x10FFFF) }
                checked += 1
                let label = String(decoding: body, as: UTF8.self)
                if got?.r != want.r {
                    failed += 1
                    if failed < 10 { t.check(false, "\(path): \(label)", "\(got?.r.count ?? -1) vs \(want.r.count) range ends") }
                }
                // Through the matcher too, on a sample of the set.
                if checked % 7 == 0 {
                    var units: [UInt16] = []
                    var n = 0
                    var q = 0
                    while q < want.r.count && n < 3000 {
                        var c = want.r[q]
                        while c <= want.r[q + 1] && n < 3000 {
                            if c >= 0x10000 {
                                units.append(UInt16(0xD800 + ((c - 0x10000) >> 10))); units.append(UInt16(0xDC00 + ((c - 0x10000) & 0x3FF)))
                            } else { units.append(UInt16(c)) }
                            n += 1
                            c += c < 0xD800 || c > 0xDFFF ? 1 : 0x800    // skip the surrogate block (lone halves would pair up)
                        }
                        q += 2
                    }
                    let pat = Array(text[(a + 1)..<(z + 2)]).map { UInt16($0) }
                    if let prog = try? jsRegExpCompile(pattern: pat, flags: Array("u".utf16)) {
                        if case .match = prog.exec(units, from: 0) { matched += 1 } else if !units.isEmpty {
                            t.check(false, "\(path): \(label) matches its symbols")
                        }
                    } else { t.check(false, "\(path): \(label) compiles") }
                }
            }
            k = e
        }
    }
    print("js regexp: \(checked) property sets checked against test262 data (\(failed) differ), \(matched) run through the matcher")
    t.check(checked > 1500 && failed == 0, "unicode property sets", "\(checked) checked, \(failed) differ")
}

/// Parse-only run over test262's RegExp built-in tests (when present).
func jsReTest262Tests(_ t: Tests) {
    t.section("regexp test262 parse")
    let files = jsTestShellLines("find build/test262/test/built-ins/RegExp build/test262/test/annexB/built-ins/RegExp -name '*.js' 2>/dev/null | sort")
    if files.isEmpty { print("note js: build/test262 absent, RegExp parse run skipped"); return }
    let skip = jsTest262SkipFeatures + ["regexp-v-flag"]
    var pass = 0, fail = 0, skipped = 0, neg = 0
    var report: [UInt8] = []
    for path in files {
        if jsTestHas(path, "_FIXTURE") { continue }
        guard let src = t.readFileIfPresent(path) else { continue }
        let meta = jsTest262Meta(src)
        if meta.features.contains(where: { skip.contains($0) }) { skipped += 1; continue }
        var ok = true
        var why = ""
        do {
            _ = try jsParse(src, JSParseOptions(module: meta.module, strict: meta.onlyStrict))
            if meta.negativeParse { ok = false; why = "parsed, expected SyntaxError" }
        } catch {
            if !meta.negativeParse { ok = false; why = "\(error.message) @\(error.line):\(error.column)" }
        }
        if meta.negativeParse { neg += 1 }
        if ok { pass += 1 } else { fail += 1; report.append(contentsOf: Array("\(path): \(why)\n".utf8)) }
    }
    _ = hostWriteFile("build/hosttest/test262-regexp-parse-failures.txt", report)
    print("test262 RegExp parse: \(pass) passed, \(fail) failed (\(neg) negative), \(skipped) skipped")
    t.check(pass >= jsReTest262ParseFloor, "test262 RegExp parse pass count \(pass) >= floor \(jsReTest262ParseFloor)")
}

let jsReTest262ParseFloor = 1_598

/// Mutated patterns against fixed subjects: compiling and matching must
/// never trap, whatever the pattern.
func jsReFuzzTests(_ t: Tests) {
    t.section("regexp fuzz")
    var seeds: [[UInt8]] = []
    for (p, _, _, _) in jsReMatchCases { seeds.append(Array(p.utf8)) }
    for (p, _, _) in jsReSyntaxCases { seeds.append(Array(p.utf8)) }
    let subjects: [[UInt16]] = [
        jsTU("aaaaaaaaaaaaaaaaaaab"), jsTU("abc ABC 123 _-_ xyz\n%u017F%u212A"), jsTU("😀%uD83D%uDE00%uDE00x"),
        jsTU("2020-12-01 $10.53 foo.bar(baz)"), [],
    ]
    let flagSets = ["", "i", "u", "iu", "m", "s", "y", "gimsuy", "v"]
    var n = 0
    var compiled = 0
    t.fuzz("regexp patterns", seeds: seeds, iterations: 40_000) { bytes in
        var units: [UInt16] = []
        for (k, b) in bytes.enumerated() {
            // Mostly ASCII, sometimes a wide or surrogate unit.
            if b >= 0xF0 { units.append(0xD800 + UInt16(b & 0x0F) * 0x80 + UInt16(k & 0x7F)) } else if b >= 0x80 { units.append(UInt16(b) * 0x21) } else { units.append(UInt16(b)) }
        }
        n += 1
        let flags = flagSets[n % flagSets.count]
        _ = jsRegExpValidate(pattern: units, flags: Array(flags.utf16))
        guard let p = try? jsRegExpCompile(pattern: units, flags: Array(flags.utf16)) else { return }
        compiled += 1
        p.maxBacktrackEntries = 20_000
        for s in subjects {
            _ = p.exec(s, from: n % 3, stepLimit: 20_000)
        }
    }
    print("js regexp fuzz: \(n) patterns, \(compiled) compiled")
}

func jsRegExpTests(_ t: Tests) {
    jsReSyntaxTests(t)
    jsReMatchTests(t)
    jsReAPITests(t)
    jsReLimitTests(t)
    jsRePropertyTests(t)
    jsReTest262Tests(t)
    jsReFuzzTests(t)
}
