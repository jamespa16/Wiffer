// Phase G selftests: the line editor and dispatcher on a ScriptedTerminal
// (keys in, output recorded and rendered on an off-screen Console), the
// serial escape decoder, and the command table (called from runSelfTests).

let enterKey = KeyEvent.char(0x0D)
let backspaceKey = KeyEvent.char(0x7F)
let tabKey = KeyEvent.char(0x09)

func ctrl(_ letter: UInt8) -> KeyEvent { .char(letter & 0x1F) }

func scriptedShell(_ keys: [KeyEvent]) -> Shell<ScriptedTerminal> {
    Shell(terminal: ScriptedTerminal(keys))
}

/// Edit one line typed as `keys` (ending in Enter): the editor must return
/// `want`, consume exactly the script, and leave `screen` on row 0.
@inline(never)
func edits(_ keys: [KeyEvent], _ want: String, _ screen: StaticString) -> Bool {
    var sh = scriptedShell(keys)
    let line = sh.readLine()
    return line == want && !sh.term.overran && sh.term.next == keys.count
        && rowIs(sh.term.screen, 0, screen) && sh.term.screen.row == 1 && sh.term.screen.col == 0
}

func lefts(_ n: Int) -> [KeyEvent] { Array(repeating: .left, count: n) }

@inline(never)
func historyBrowsing() -> Bool {
    var sh = scriptedShell(chars("echo one\r") + chars("echo two\r") + chars("echo two\r") + chars("  \r")
                           + chars("dr") + [.up, .up, .up, .down, .down, enterKey]
                           + [.up, .up, enterKey] + [.down, .up, ctrl(0x50), .end, enterKey])
    for _ in 0..<4 { sh.step() }
    // Blank lines and repeats aren't remembered.
    guard sh.history == ["echo one", "echo two"] else { return false }
    // Rows: "> echo one", "one", "> echo two", "two", "> echo two", "two", ">", "> dr".
    let draft = sh.readLine()
    guard draft == "dr", rowIs(sh.term.screen, 7, "> dr") else { return false }
    let older = sh.readLine()
    guard older == "echo one", rowIs(sh.term.screen, 8, "> echo one") else { return false }
    // Down at the newest entry does nothing; Ctrl-P is Up.
    let viaCtrlP = sh.readLine()
    return viaCtrlP == "echo one" && rowIs(sh.term.screen, 9, "> echo one") && !sh.term.overran
}

/// The editor redraws a recalled line over a longer one: ESC[K clears the rest.
@inline(never)
func historyRedrawClears() -> Bool {
    var sh = scriptedShell(chars("x\r") + chars("a long line here") + [.up, enterKey])
    sh.step()
    let line = sh.readLine()
    return line == "x" && rowIs(sh.term.screen, 2, "> x")
}

@inline(never)
func ambiguousCompletion(_ typed: StaticString, _ want: String, _ list: StaticString, _ again: StaticString) -> Bool {
    var sh = scriptedShell(chars(typed) + [tabKey, enterKey])
    let line = sh.readLine()
    let s = sh.term.screen
    return line == want && rowIs(s, 1, list) && rowIs(s, 2, again) && !sh.term.overran
}

func serialEvents(_ bytes: StaticString) -> [KeyEvent] {
    var d = EscapeDecoder()
    var out: [KeyEvent] = []
    bytes.withUTF8Buffer { for b in $0 { d.feed(b) } }
    while let e = d.pop() { out.append(e) }
    return out
}

@inline(never)
func splitEscape() -> Bool {
    var d = EscapeDecoder()
    var ok = true
    for b: UInt8 in [0x1B, 0x5B, 0x33] {
        d.feed(b)
        ok = ok && d.pop() == nil && d.pending
    }
    d.feed(0x7E)
    ok = ok && d.pop() == .delete && !d.pending
    d.feed(0x1B) // lone ESC: held, then the Escape key on timeout
    ok = ok && d.pop() == nil
    d.timeout()
    ok = ok && d.pop() == .char(0x1B) && d.pop() == nil && !d.pending
    d.feed(0x1B); d.feed(0x5B) // timeout mid-CSI: dropped
    d.timeout()
    d.feed(0x41)
    return ok && d.pop() == .char(0x41) && d.pop() == nil
}

/// Run `lines` on a scripted shell; return everything they printed.
@inline(never)
func transcript(_ lines: StaticString) -> String {
    var sh = scriptedShell(chars(lines))
    while sh.term.next < sh.term.keys.count { sh.step() }
    // Drop the echo: lines starting with the prompt (its SGR escape).
    var result = ""
    for l in outputLines(sh.term.take()) where l.utf8.first != 0x1B {
        result += l + "\n"
    }
    return result
}

/// Split terminal output at CR LF. (On bytes: "\r\n" is one Character.)
func outputLines(_ s: String) -> [String] {
    var lines: [String] = []
    var current: [UInt8] = []
    for b in s.utf8 {
        if b == 0x0A {
            if current.last == 0x0D { current.removeLast() }
            lines.append(String(decoding: current, as: UTF8.self))
            current = []
        } else {
            current.append(b)
        }
    }
    if !current.isEmpty { lines.append(String(decoding: current, as: UTF8.self)) }
    return lines
}

@inline(never)
func helpFromTable() -> Bool {
    var sh = scriptedShell([])
    sh.help()
    let lines = outputLines(sh.term.take())
    guard lines.count == sh.commands.count else { return false }
    for (l, c) in zip(lines, sh.commands) {
        // name (and args) from column 0, help from column 16.
        guard l.hasPrefix(c.name), l.utf8.count == 16 + c.help.utf8.count, l.hasSuffix(c.help) else { return false }
    }
    return lines[0] == "help            show this list"
        && lines.contains("set <name> <n>  set a shell variable (an integer)")
}

@inline(never)
func tableIsSane() -> Bool {
    let commands = Shell<ScriptedTerminal>.builtins()
    var names = Set<String>()
    for c in commands {
        guard !c.help.isEmpty, !c.name.isEmpty, !c.name.utf8.contains(0x20) else { return false }
        names.insert(c.name)
    }
    let required = ["help", "echo", "clear", "fb", "mem", "peek", "uptime", "mouse", "fault", "halt",
                    "reboot", "selftest", "set", "get", "vars", "history", "color"]
    return names.count == commands.count && required.allSatisfy { names.contains($0) }
}

/// A String built at run time from a StaticString over 15 bytes (pointer-
/// backed, so it goes through the C3 lower-half alias).
@inline(never)
func stringFromStaticString() -> Bool {
    let ss: StaticString = "a static string longer than fifteen bytes"
    let s = ss.withUTF8Buffer { String(decoding: $0, as: UTF8.self) }
    var d: [String: Int] = [:]
    d[s] = 1
    return s == "a static string longer than fifteen bytes" && s.count == 41
        && d["a static string longer than fifteen bytes"] == 1 && s + "!" == "\(s)!"
}

@inline(never)
func colorCommandWorks() -> Bool {
    guard let c = console else { return true }
    let (fg, bg) = (c.defaultFG, c.defaultBG)
    let set = colorCommand(["yellow", "blue"])
    let ok = set == "color: yellow on blue" && c.defaultFG == 3 && c.defaultBG == 4
        && c.blank.bg == 4 && colorCommand(["pink", "red"]) == "color: unknown colour: pink"
        && colorCommand(["red"]).hasPrefix("usage: color")
    c.setDefaultColors(fg: fg, bg: bg)
    return ok && c.defaultFG == fg && c.defaultBG == bg
}

/// Splitting into [Substring] and interpolating the pieces, small and long.
@inline(never)
func substrings() -> Bool {
    let short = opaque("bogus 1"), long = opaque("a much longer string,  more words")
    let w = short.split(separator: " "), v = long.split(separator: " ")
    return w.count == 2 && "x: \(w[0])" == "x: bogus" && v.count == 6 && "\(v[1])|\(v[5])" == "much|words"
        && "\(long[long.startIndex...])" == long
}

/// The command table is a statically initialised array whose Strings point
/// at literals in the kernel image (build.sh rewrites those to the alias).
@inline(never)
func staticTableStrings() -> Bool {
    let live = Shell<LiveTerminal>.builtins(), scripted = Shell<ScriptedTerminal>.builtins()
    guard live.count == scripted.count else { return false }
    for (a, b) in zip(live, scripted) where a.name != b.name || a.help != b.help || a.help.utf8.count < 8 {
        return false
    }
    return live[0].help == "show this list" && live[2].help.utf8.count == 16
}

func shellTests(_ t: inout SelfTest) {
    let base = HeapUsage()

    // Line editor.
    t.check("edit: plain line", edits(chars("echo hi\r"), "echo hi", "> echo hi"))
    t.check("edit: insert mid-line (ecXX, left x2, ho, End, BS x2, ' hi')",
            edits(chars("ecXX") + lefts(2) + chars("ho") + [.end, backspaceKey, backspaceKey]
                  + chars(" hi\r"), "echo hi", "> echo hi"))
    t.check("edit: backspace mid-line", edits(chars("abXcd") + lefts(2) + [backspaceKey, enterKey], "abcd", "> abcd"))
    t.check("edit: backspace at start does nothing",
            edits(chars("ab") + [.home, backspaceKey, enterKey], "ab", "> ab"))
    t.check("edit: delete mid-line",
            edits(chars("abXcd") + [.home, .right, .right, .delete, enterKey], "abcd", "> abcd"))
    t.check("edit: delete at end does nothing, Ctrl-D deletes",
            edits(chars("abXc") + [.delete, .left, .left, ctrl(0x44), enterKey], "abc", "> abc"))
    t.check("edit: Home/End", edits(chars("bc") + [.home] + chars("a") + [.end] + chars("d\r"), "abcd", "> abcd"))
    t.check("edit: Ctrl-A/E/B/F",
            edits(chars("bd") + [ctrl(0x41)] + chars("a") + [ctrl(0x46)] + chars("c") + [ctrl(0x45)]
                  + chars("e") + [ctrl(0x42)] + chars("!\r"), "abcd!e", "> abcd!e"))
    t.check("edit: Ctrl-K kills to end", edits(chars("hello world") + lefts(6) + [ctrl(0x4B), enterKey], "hello", "> hello"))
    t.check("edit: Ctrl-U kills to start", edits(chars("junk") + [.left, ctrl(0x55), enterKey], "k", "> k"))
    t.check("edit: Ctrl-C abandons the line", edits(chars("abc") + [.left, ctrl(0x43)], "", "> abc^C"))
    t.check("edit: Ctrl-L clears and redraws",
            { () -> Bool in
                var sh = scriptedShell(chars("x\r") + chars("ab") + [ctrl(0x4C), .left] + chars("c\r"))
                sh.step()
                return sh.readLine() == "acb" && rowIs(sh.term.screen, 0, "> acb") && sh.term.screen.row == 1
            }())
    t.check("edit: UTF-8 scalar is one cell",
            { () -> Bool in
                var sh = scriptedShell(chars("caf") + [.char(0xC3), .char(0xA9), .left] + chars("X\r"))
                let line = sh.readLine()
                let s = sh.term.screen
                return line == "cafX\u{E9}" && s.cell(0, 5).ch == 0x58 && s.cell(0, 6).ch == 0xE9
            }())
    t.check("edit: line limited to the terminal width",
            { () -> Bool in
                var sh = Shell(terminal: ScriptedTerminal(Array(repeating: .char(0x61), count: 30) + [enterKey], cols: 20))
                return sh.readLine().utf8.count == 17
            }())

    // History and completion.
    t.check("history: up/down, in-progress line restored, no blanks/repeats", historyBrowsing())
    t.check("history: recalled line erases a longer one", historyRedrawClears())
    t.check("complete: unique (upt -> 'uptime ')", edits(chars("upt") + [tabKey, enterKey], "uptime ", "> uptime"))
    t.check("complete: unique mid-word keeps the rest",
            edits(chars("hist x") + lefts(2) + [tabKey, enterKey], "history x", "> history x"))
    t.check("complete: ambiguous lists and reprints (h)",
            ambiguousCompletion("h", "h", "halt  help  history", "> h"))
    t.check("complete: ambiguous extends to common prefix (mo -> mou)",
            ambiguousCompletion("mo", "mou", "mount  mouse", "> mou"))
    t.check("complete: no match, or past the first word, does nothing",
            edits(chars("zz") + [tabKey, enterKey], "zz", "> zz")
            && edits(chars("echo up") + [tabKey, enterKey], "echo up", "> echo up"))

    // Serial escape sequences.
    t.check("serial: ESC [ A/B/C/D/H/F",
            serialEvents("\u{1B}[A\u{1B}[B\u{1B}[C\u{1B}[D\u{1B}[H\u{1B}[F") == [.up, .down, .right, .left, .home, .end])
    t.check("serial: ESC [ n ~ (Home/End/Delete/Insert/PgUp/PgDn)",
            serialEvents("\u{1B}[1~\u{1B}[4~\u{1B}[3~\u{1B}[7~\u{1B}[8~\u{1B}[2~\u{1B}[5~\u{1B}[6~")
            == [.home, .end, .delete, .home, .end, .insert, .pageUp, .pageDown])
    t.check("serial: ESC O A/D (application mode), modifiers ignored",
            serialEvents("\u{1B}OA\u{1B}OD\u{1B}[1;5C") == [.up, .left, .right])
    t.check("serial: unknown CSI dropped, text passes through",
            serialEvents("a\u{1B}[Zb\r\u{7F}") == chars("ab\r\u{7F}"))
    t.check("serial: ESC x -> Esc, x; ESC ESC [A -> Esc, up",
            serialEvents("\u{1B}x\u{1B}\u{1B}[A") == [.char(0x1B), .char(0x78), .char(0x1B), .up])
    t.check("serial: control byte aborts a CSI", serialEvents("\u{1B}[1\r") == [.char(0x0D)])
    t.check("serial: sequence split across reads, lone ESC timeout", splitEscape())

    // Dispatcher and commands.
    t.check("table: unique names, all with help, all required commands", tableIsSane())
    t.check("help is generated from the table", helpFromTable())
    t.check("dispatch: unknown command", transcript("bogus 1 2\r") == "unknown command: bogus\n")
    t.check("dispatch: blank line runs nothing", transcript("   \r") == "")
    t.check("dispatch: echo keeps inner spacing", transcript("echo  spaced   out \r") == "spaced   out\n")
    t.check("dispatch: set/get/vars",
            transcript("set b 2\rset a -1\rset a 1\rget a\rget zz\rget\rset x 1x\rset x\rvars\r")
            == "1\nget: not set: zz\nusage: get <name>\nusage: set <name> <integer>\nusage: set <name> <integer>\na = 1\nb = 2\n(2 variables)\n")
    t.check("dispatch: history lists numbered lines", transcript("echo x\rhistory\r") == "x\n   1  echo x\n   2  history\n")
    t.check("dispatch: peek and fault usage",
            transcript("peek\rpeek 0\rpeek 0x12345678901234567\rfault\rfault zz\r")
            == "usage: peek <hex addr>\npeek: address must be non-null and 8-byte aligned\nusage: peek <hex addr>\nusage: fault <ud|de|pf|gp|df|ap>\nusage: fault <ud|de|pf|gp|df|ap>\n")
    t.check("format: hex, uptime",
            hex(0xFFA0) == "0x000000000000ffa0" && hex(UInt64.max) == "0xffffffffffffffff"
            && uptimeInfo().hasPrefix("uptime: ") && uptimeInfo().hasSuffix(" ticks)"))
    t.check("parse: Int, colours",
            parseInt("-7") == -7 && parseInt("+7") == nil && parseInt("1x") == nil
            && parseInt("99999999999999999999") == nil
            && parseColor("red") == 1 && parseColor("brightred") == 9 && parseColor("grey") == 8
            && parseColor("15") == 15 && parseColor("16") == nil && parseColor("pink") == nil
            && parseColor("-1") == nil && colorName(11) == "brightyellow")
    t.check("color: sets and restores console defaults", colorCommandWorks())
    t.check("String from a >15-byte StaticString", stringFromStaticString())
    t.check("[Substring] split and interpolation", substrings())
    t.check("static command table: literal Strings readable", staticTableStrings())
    t.check("shell tests freed their memory", HeapUsage() == base)
}
