// Phase N selftests: TextBuffer (UTF-8 boundaries, load/save, tab, split and
// join, desired column, find) and EditorModel driven by scripted keys over a
// scratch FileSystem (the roadmap's type / fix a typo / Ctrl-S / Ctrl-Q
// script, prompts, scrolling, damage, status line). Called from runSelfTests.

/// Feed `keys` (plain, no modifiers) to `m`; return the last action.
@discardableResult
func feed(_ m: inout EditorModel, _ keys: [KeyEvent], _ fs: FileSystem) -> EditorAction {
    var last = EditorAction.none
    for k in keys { last = m.handle(Key(k), fs: fs) }
    return last
}

func editorText(_ m: EditorModel) -> [UInt8] { m.buffer.contents }

func rights(_ n: Int) -> [KeyEvent] { Array(repeating: .right, count: n) }

/// The roadmap's "done when" script: type several lines, move around, fix a
/// typo, Ctrl-S, Ctrl-Q; the file holds exactly the text.
@inline(never)
func editorScript() -> Bool {
    let fs = FileSystem()
    var m = EditorModel(rows: 10, cols: 40)
    guard m.open("/notes.txt", fs: fs), m.path == "/notes.txt", m.message == "/notes.txt: new file" else { return false }
    feed(&m, chars("Hello wrold\rsecond line\rthird"), fs)
    guard m.dirty, m.cursor == TextPosition(line: 2, column: 5) else { return false }
    // Up twice lands on column 5 of line 0; move to after "wro" and fix it.
    feed(&m, [.up, .up] + rights(4) + [backspaceKey, backspaceKey] + chars("or"), fs)
    guard m.buffer.lines[0] == bytes("Hello world"), m.cursor == TextPosition(line: 0, column: 9) else { return false }
    // Ctrl-End, a last line, a stray x removed with Delete after Left.
    guard m.handle(Key(.end, ctrl: true), fs: fs) == .redraw, m.cursor == TextPosition(line: 2, column: 5) else { return false }
    feed(&m, chars("\rlastx") + [.left, .delete, .end], fs)
    guard feed(&m, [ctrl(0x53)], fs) == .redraw, !m.dirty, m.message == "saved 4 lines" else { return false }
    guard (try? fs.read("/notes.txt")) == bytes("Hello world\nsecond line\nthird\nlast\n") else { return false }
    return feed(&m, [ctrl(0x51)], fs) == .quit
}

@inline(never)
func utf8Boundaries() -> Bool {
    // a(1) é(2) €(3) 😀(4) b(1): boundaries at 0 1 3 6 10 11.
    var b = TextBuffer(bytes("a\u{E9}\u{20AC}\u{1F600}b"))
    var stops: [Int] = []
    for _ in 0..<6 {
        b.moveRight()
        stops.append(b.cursor.column)
    }
    guard stops == [1, 3, 6, 10, 11, 11], b.cursorDisplayColumn == 5, b.displayWidth(line: 0) == 5 else { return false }
    b.moveLeft()
    b.moveLeft()
    guard b.cursor.column == 6, b.cursorDisplayColumn == 3 else { return false }
    // Inside a scalar snaps back to its start.
    b.setCursor(TextPosition(line: 0, column: 8))
    guard b.cursor.column == 6, b.byteColumn(line: 0, display: 4) == 10 else { return false }
    // Backspace / Delete remove a whole scalar.
    b.backspace() // the euro sign
    guard b.lines[0] == bytes("a\u{E9}\u{1F600}b"), b.cursor.column == 3 else { return false }
    b.deleteForward() // the emoji
    guard b.lines[0] == bytes("a\u{E9}b"), b.cursor.column == 3 else { return false }
    b.insert("\u{3B1}") // alpha
    guard b.lines[0] == bytes("a\u{E9}\u{3B1}b"), b.cursor.column == 5 else { return false }

    // Serial delivers UTF-8 one byte per key; stray continuations are dropped.
    let fs = FileSystem()
    var m = EditorModel(rows: 4, cols: 10)
    feed(&m, [.char(0x78), .char(0xA9), .char(0xC3), .char(0xA9), .char(0xE2), .char(0x82), .char(0xAC), .char(0x79)], fs)
    return m.buffer.lines[0] == bytes("x\u{E9}\u{20AC}y") && m.buffer.cursorDisplayColumn == 4
}

func roundTrips(_ s: StaticString) -> Bool {
    var b = TextBuffer(bytes(s))
    return b.save() == bytes(s)
}

@inline(never)
func newlinePreservation() -> Bool {
    guard roundTrips("a\nb"), roundTrips("a\nb\n"), roundTrips(""), roundTrips("\n"), roundTrips("\n\n"),
          roundTrips("x\n\ny") else { return false }
    let b1 = TextBuffer(bytes("a\nb\n")), b2 = TextBuffer(bytes("a\nb")), b3 = TextBuffer(bytes("\n"))
    guard b1.lines == [bytes("a"), bytes("b")], b1.endsWithNewline, b2.lines == [bytes("a"), bytes("b")],
          !b2.endsWithNewline, b3.lines == [[]] else { return false }
    // Edits keep the ending; an empty file gets a final newline once it has text.
    var b = TextBuffer(bytes("one"))
    b.moveEnd()
    b.insert(bytes: bytes("!"))
    guard b.dirty, b.save() == bytes("one!"), !b.dirty else { return false }
    var e = TextBuffer(bytes(""))
    e.insert(bytes: bytes("new"))
    guard e.save() == bytes("new\n") else { return false }
    // ...and deleting it all again keeps the final newline.
    e.moveToEnd()
    for _ in 0..<3 { e.backspace() }
    return e.save() == bytes("\n")
}

@inline(never)
func tabStops() -> Bool {
    var b = TextBuffer()
    b.insertTab()
    guard b.lines[0] == bytes("    ") else { return false }
    b.insert(bytes: bytes("ab"))
    b.insert("\t")
    guard b.lines[0] == bytes("    ab  "), b.cursor.column == 8 else { return false }
    var u = TextBuffer(bytes("\u{E9}"))
    u.moveEnd()
    u.insertTab() // display column 1 -> 3 spaces
    return u.lines[0] == bytes("\u{E9}   ") && u.cursorDisplayColumn == 4
}

@inline(never)
func splitAndJoin() -> Bool {
    var b = TextBuffer(bytes("hello world\nend"))
    b.setCursor(TextPosition(line: 0, column: 5))
    b.insertNewline()
    guard b.lines == [bytes("hello"), bytes(" world"), bytes("end")], b.cursor == TextPosition(line: 1, column: 0) else {
        return false
    }
    b.backspace() // joins back
    guard b.lines == [bytes("hello world"), bytes("end")], b.cursor == TextPosition(line: 0, column: 5) else { return false }
    b.moveEnd()
    b.deleteForward() // joins "end" on
    guard b.lines == [bytes("hello worldend")], b.cursor.column == 11 else { return false }
    b.moveEnd()
    b.deleteForward() // at the very end: nothing
    b.moveToStart()
    b.backspace() // at the very start: nothing
    guard b.lines == [bytes("hello worldend")] else { return false }
    // splitLine/joinLines elsewhere move the cursor with its text.
    b.setCursor(TextPosition(line: 0, column: 13))
    b.splitLine(at: TextPosition(line: 0, column: 11))
    guard b.lines == [bytes("hello world"), bytes("end")], b.cursor == TextPosition(line: 1, column: 2) else { return false }
    b.joinLines(at: 0)
    return b.lines == [bytes("hello worldend")] && b.cursor == TextPosition(line: 0, column: 13)
}

@inline(never)
func desiredColumn() -> Bool {
    var b = TextBuffer(bytes("a long first line\nab\n\u{E9}\u{E9}\u{E9}\u{E9}\u{E9}\u{E9}\u{E9}\u{E9}\u{E9}\u{E9}\u{E9}\nlast line is long"))
    b.setCursor(TextPosition(line: 0, column: 10))
    b.moveDown()
    guard b.cursor == TextPosition(line: 1, column: 2) else { return false }
    b.moveDown() // display column 10 of a line of two-byte scalars
    guard b.cursor == TextPosition(line: 2, column: 20), b.cursorDisplayColumn == 10 else { return false }
    b.moveDown()
    guard b.cursor == TextPosition(line: 3, column: 10) else { return false }
    b.moveUp(3)
    guard b.cursor == TextPosition(line: 0, column: 10) else { return false }
    // Horizontal movement resets it.
    b.moveDown()
    b.moveLeft()
    b.moveDown()
    guard b.cursor == TextPosition(line: 2, column: 2) else { return false }
    b.moveUp(10)
    b.moveHome()
    b.moveDown(10)
    return b.cursor == TextPosition(line: 3, column: 0)
}

@inline(never)
func findWraps() -> Bool {
    let b = TextBuffer(bytes("foo bar\nbaz foo qux\nfo"))
    let n = bytes("foo")
    return b.find(n, from: TextPosition(line: 0, column: 0)) == TextPosition(line: 0, column: 0)
        && b.find(n, from: TextPosition(line: 0, column: 1)) == TextPosition(line: 1, column: 4)
        && b.find(n, from: TextPosition(line: 1, column: 5)) == TextPosition(line: 0, column: 0)
        && b.find(n, from: TextPosition(line: 2, column: 0)) == TextPosition(line: 0, column: 0)
        && TextBuffer(bytes("xx ab xx")).find(bytes("ab"), from: TextPosition(line: 0, column: 4)) == TextPosition(line: 0, column: 3)
        && b.find(bytes("zzz"), from: TextPosition(line: 0, column: 0)) == nil
        && b.find([], from: TextPosition(line: 0, column: 0)) == nil
}

/// Ctrl-Q on a dirty buffer asks; Esc stays, n quits unsaved, y saves and quits.
@inline(never)
func quitPrompt() -> Bool {
    let fs = FileSystem()
    _ = try? fs.write("/f", bytes("old\n"))
    var m = EditorModel(rows: 4, cols: 20)
    m.open("/f", fs: fs)
    guard feed(&m, [ctrl(0x51)], fs) == .quit else { return false } // clean: just quits
    feed(&m, chars("new "), fs)
    guard feed(&m, [ctrl(0x51)], fs) == .redraw, m.prompt == .saveBeforeQuit,
          m.statusLine(width: 26) == "save changes? (y/n/esc)   " else { return false }
    guard feed(&m, [.char(0x7A)], fs) == .none, feed(&m, [.char(0x1B)], fs) == .redraw, m.prompt == .none else {
        return false
    }
    guard feed(&m, [ctrl(0x51), .char(0x6E)], fs) == .quit, (try? fs.read("/f")) == bytes("old\n") else { return false }
    var m2 = m
    guard feed(&m2, [ctrl(0x51), .char(0x79)], fs) == .quit, (try? fs.read("/f")) == bytes("new old\n") else { return false }
    // No path yet: y asks for one, then quits once saved.
    var u = EditorModel(rows: 4, cols: 20)
    feed(&u, chars("hi"), fs)
    guard feed(&u, [ctrl(0x51), .char(0x79)], fs) == .redraw, u.prompt == .saveAs else { return false }
    return feed(&u, chars("/new\r"), fs) == .quit && (try? fs.read("/new")) == bytes("hi\n") && u.path == "/new"
}

/// Ctrl-O and Ctrl-F prompts, with backspace and Esc in them.
@inline(never)
func editorPrompts() -> Bool {
    let fs = FileSystem()
    _ = try? fs.mkdir("/d")
    _ = try? fs.write("/d/a.txt", bytes("alpha\nbeta gamma\ndelta beta\n"))
    var m = EditorModel(rows: 4, cols: 30)
    m.cwd = "/d"
    feed(&m, [ctrl(0x4F)] + chars("a.tx"), fs)
    guard m.prompt == .open, m.statusLine(width: 12) == "open: a.tx  ", m.statusCursorColumn(width: 12) == 10 else {
        return false
    }
    feed(&m, [backspaceKey] + chars("xt\r"), fs)
    guard m.prompt == .none, m.path == "/d/a.txt", m.message == "/d/a.txt: 3 lines", m.buffer.lineCount == 3 else {
        return false
    }
    // Opening a directory fails and keeps the buffer.
    feed(&m, [ctrl(0x4F)] + chars("/d\r"), fs)
    guard m.path == "/d/a.txt", m.message == "open: /d: is a directory" else { return false }
    // Find, then find again with an empty prompt, then wrap.
    feed(&m, [ctrl(0x46)] + chars("beta\r"), fs)
    guard m.cursor == TextPosition(line: 1, column: 0), m.message == "" else { return false }
    feed(&m, [ctrl(0x46)], fs)
    guard m.statusLine(width: 14) == "find [beta]:  " else { return false }
    feed(&m, [enterKey], fs)
    guard m.cursor == TextPosition(line: 2, column: 6) else { return false }
    feed(&m, [ctrl(0x46), enterKey], fs)
    guard m.cursor == TextPosition(line: 1, column: 0), m.message == "wrapped: beta" else { return false }
    feed(&m, [ctrl(0x46)] + chars("zeta\r"), fs)
    guard m.message == "not found: zeta", m.cursor == TextPosition(line: 1, column: 0) else { return false }
    // Esc cancels a prompt; Ctrl-O refuses while dirty.
    feed(&m, [ctrl(0x4F)] + chars("zz") + [.char(0x1B)], fs)
    guard m.prompt == .none, m.path == "/d/a.txt" else { return false }
    feed(&m, chars("!") + [ctrl(0x4F)], fs)
    return m.prompt == .none && m.message == "unsaved changes: Ctrl-S first"
}

/// Viewport follows the cursor; damage reports changed lines and cursor moves.
@inline(never)
func editorViewport() -> Bool {
    let fs = FileSystem()
    var m = EditorModel(rows: 3, cols: 5)
    _ = m.takeDamage()
    feed(&m, chars("abc"), fs)
    let d1 = m.takeDamage()
    guard d1 == EditorDamage(full: false, lines: 0..<1, oldCursorLine: 0, cursorLine: 0) else { return false }
    feed(&m, chars("defg"), fs) // column 7 of 5: scrolls right
    guard m.leftColumn == 3, m.cursorCell.row == 0, m.cursorCell.col == 4,
          m.visibleText(row: 0) == bytes("defg")[...], m.takeDamage().full else { return false }
    feed(&m, [.home], fs)
    guard m.leftColumn == 0, m.takeDamage().full else { return false }
    feed(&m, [.end] + chars("\r\r\r"), fs) // line 3 of 3 rows: scrolls down
    guard m.topLine == 1, m.cursorCell.row == 2, m.visibleText(row: 2) == bytes("")[...], m.visibleText(row: 3) == nil else {
        return false
    }
    _ = m.takeDamage()
    feed(&m, [.up], fs)
    guard m.takeDamage() == EditorDamage(full: false, lines: nil, oldCursorLine: 3, cursorLine: 2) else { return false }
    feed(&m, [backspaceKey], fs) // join: line 1 onwards, including the vanished last row
    guard m.takeDamage() == EditorDamage(full: false, lines: 1..<4, oldCursorLine: 2, cursorLine: 1) else { return false }
    // Page down/up and Ctrl-Home over a longer file.
    var p = EditorModel(rows: 3, cols: 10)
    p.buffer.load(bytes("0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n"))
    feed(&p, [.pageDown], fs)
    guard p.topLine == 3, p.cursor.line == 3 else { return false }
    feed(&p, [.pageDown, .pageDown, .pageDown], fs)
    guard p.topLine == 7, p.cursor.line == 9 else { return false }
    feed(&p, [.pageUp], fs)
    guard p.topLine == 4, p.cursor.line == 6 else { return false }
    guard p.handle(Key(.home, ctrl: true), fs: fs) == .redraw, p.topLine == 0, p.cursor.line == 0 else { return false }
    p.click(row: 2, col: 9)
    return p.cursor == TextPosition(line: 2, column: 1)
}

@inline(never)
func editorStatusLine() -> Bool {
    let fs = FileSystem()
    var m = EditorModel(rows: 3, cols: 20)
    guard m.statusLine(width: 30) == "[no name]          Ln 1, Col 1" else { return false }
    m.open("/a.txt", fs: fs)
    feed(&m, chars("x\u{E9}"), fs)
    guard m.statusLine(width: 30) == "/a.txt [+]         Ln 1, Col 3" else { return false }
    feed(&m, [ctrl(0x53)], fs)
    guard m.statusLine(width: 34) == "/a.txt  saved 1 lines  Ln 1, Col 3" else { return false }
    // Narrow: the left part is cut; Esc clears the message.
    guard m.statusLine(width: 16) == "/a.t Ln 1, Col 3", m.statusLine(width: 5) == "Ln 1," else { return false }
    feed(&m, [.char(0x1B)], fs)
    return m.message == "" && m.statusLine(width: 20) == "/a.txt   Ln 1, Col 3"
}

/// A load / edit / save cycle on a scratch FileSystem frees everything.
@inline(never)
func editorCycle() -> Bool {
    let fs = FileSystem()
    _ = try? fs.write("/t", bytes("line one\nline two\n"))
    var m = EditorModel(rows: 5, cols: 20)
    m.open("/t", fs: fs)
    feed(&m, [.down, .end] + chars(" more\r\u{E9}t\u{E9}\t") + [ctrl(0x46)] + chars("two\r") + [ctrl(0x53)], fs)
    _ = m.takeDamage()
    _ = m.statusLine(width: 40)
    return (try? fs.read("/t")) == bytes("line one\nline two more\n\u{E9}t\u{E9} \n")
}

func editorTests(_ t: inout SelfTest) {
    let base = HeapUsage()
    t.check("editor: type, fix a typo, Ctrl-S, Ctrl-Q saves exact bytes", editorScript())
    t.check("text buffer: cursor stays on UTF-8 scalar boundaries", utf8Boundaries())
    t.check("text buffer: trailing newline (or not) preserved", newlinePreservation())
    t.check("text buffer: tab inserts spaces to the next multiple of 4", tabStops())
    t.check("text buffer: split and join lines", splitAndJoin())
    t.check("text buffer: up/down keep the desired column", desiredColumn())
    t.check("text buffer: find wraps past the end", findWraps())
    t.check("editor: quit while dirty asks save? y/n/esc", quitPrompt())
    t.check("editor: open and find prompts", editorPrompts())
    t.check("editor: viewport scrolling, paging, damage", editorViewport())
    t.check("editor: status line", editorStatusLine())
    t.check("editor: load/edit/save cycle", editorCycle())
    t.check("editor tests freed their memory (live blocks)", HeapUsage() == base)
}
