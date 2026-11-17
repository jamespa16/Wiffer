// Phase N2 selftests: EditorWindow off-screen, on a small compositor and WM
// with a scratch FileSystem: open a file, rendered pixels (gutter, line
// numbers, text, block cursor, status line), repaints limited to the
// damaged rows, scrolling, click-to-place, resize, close while dirty
// (refused, then "y" saves and the window goes), the openEditor hook, the
// `edit` command without a desktop, and that drawing never allocates and
// a torn-down WM leaves the heap where it was. Called from runSelfTests.

func editorWindowTests(_ t: inout SelfTest) {
    guard let font = PSFFont(font_data(), size: Int(font_psf_size)) else {
        t.check("editor window: font", false)
        return
    }
    let before = HeapUsage()
    let after = withExtendedLifetime(font) {
        editorWindowScenario(&t, font)
        return HeapUsage()
    }
    t.check("editor window: torn down, heap back to baseline", after == before)
    if after != before {
        print("  heap: \(before.blocks) -> \(after.blocks) blocks, \(before.bytes) -> \(after.bytes) bytes")
    }

    // `edit` needs the desktop.
    if windowManager == nil {
        var sh = Shell(terminal: ScriptedTerminal(chars("edit /notes.txt\r")))
        _ = sh.step()
        t.check("editor window: edit without a desktop says so",
                containsBytes(sh.term.output, bytes("edit: run `desktop` first")))
    }
}

func containsBytes(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
    guard needle.count <= hay.count else { return false }
    for i in 0...(hay.count - needle.count) where hay[i..<(i + needle.count)].elementsEqual(needle) { return true }
    return false
}

/// Bit mask of rows.
func rowBits(_ rows: Int...) -> UInt64 {
    var m: UInt64 = 0
    for r in rows { m |= UInt64(1) << UInt64(r) }
    return m
}

@inline(never)
func editorWindowScenario(_ t: inout SelfTest, _ font: PSFFont) {
    let front = Surface(width: 800, height: 600, color: 0xDEAD)
    let comp = Compositor(front: front)
    comp.add(PatternLayer(frame: comp.bounds, color: 0x102030))
    let wm = WindowManager(compositor: comp, theme: WindowTheme(font: font))
    let fs = FileSystem()
    _ = try? fs.write("/notes.txt", bytes("one\ntwo\nthree\n"))
    let colors = EditorColors()
    let cw = font.width, ch = font.height

    guard let w = openEditorWindow(wm, path: "notes.txt", fs: fs, cwd: "/", colors: colors).window else {
        t.check("editor window: opens /notes.txt", false)
        wm.shutdown()
        return
    }
    let m = { w.model }
    t.check("editor window: opens, focused, titled with the path",
            wm.focused === w && w.title == "/notes.txt" && m().buffer.lineCount == 3 && m().path == "/notes.txt"
            && w.manager === wm)
    t.check("editor window: layout (76x24 text cells, 4-col gutter, status line)",
            w.content.width == 80 * cw && w.content.height == 25 * ch && w.gutterCols == 4
            && w.textRows == 24 && w.textCols == 76 && m().rows == 24 && m().cols == 76)

    func flush() {
        wm.render()
        comp.composite()
    }
    func px(_ x: Int, _ y: Int) -> UInt32 { // content-local
        let c = w.contentRect
        return front.pixel(c.x + x, c.y + y) ?? 0
    }
    /// Pixels of colour `c` in text cell (row, col) (col counts from the gutter's left).
    func inked(_ row: Int, _ col: Int, _ c: UInt32) -> Int {
        var n = 0
        for y in 0..<ch { for x in 0..<cw where px(col * cw + x, row * ch + y) == c { n += 1 } }
        return n
    }
    flush()
    let g = w.gutterCols
    t.check("editor window: first draw is full", w.draws == 1 && w.paintedFull && w.paintedStatus)
    t.check("editor window: gutter with line numbers",
            px(1, 1) == colors.gutterBG && inked(0, 2, colors.gutterText) > 4 && inked(0, 1, colors.gutterText) == 0
            && inked(2, 2, colors.gutterText) > 4 && inked(3, 2, colors.gutterText) == 0
            && px((g - 1) * cw + 3, 3) == colors.gutterBG)
    t.check("editor window: text drawn after the gutter",
            inked(1, g, colors.text) > 4 && inked(1, g + 3, colors.text) == 0 && px((g + 10) * cw, ch + 3) == colors.background)
    t.check("editor window: block cursor at 1,1",
            inked(0, g, colors.cursor) > 20 && inked(0, g, colors.background) > 4 && inked(0, g + 1, colors.cursor) == 0)
    let sy = w.content.height - ch
    t.check("editor window: status line at the bottom",
            px(w.content.width - 2, sy + 1) == colors.statusBG && px(0, sy - 1) != colors.statusBG
            && inked(24, 0, colors.statusText) > 4)

    // Typing repaints only the cursor's row (and the status line); drawing
    // doesn't allocate.
    wm.route(.key(Key(.char(0x58)))) // X
    let heapBefore = HeapUsage()
    flush()
    t.check("editor window: draw doesn't allocate", HeapUsage() == heapBefore)
    t.check("editor window: typing repaints one row",
            !w.paintedFull && w.paintedRows == rowBits(0) && w.paintedStatus && m().buffer.lines[0] == bytes("Xone"))
    t.check("editor window: title shows modified", w.title == "/notes.txt [+]")
    wm.route(.key(Key(.down)))
    flush()
    t.check("editor window: cursor move repaints old and new rows",
            w.paintedRows == rowBits(0, 1) && inked(1, g + 1, colors.cursor) > 20 && inked(0, g + 1, colors.cursor) == 0)
    wm.route(.key(Key(.char(0x0D)))) // split line 1: rows 1... repaint
    flush()
    t.check("editor window: newline repaints from the split down",
            w.paintedRows == rowBits(1, 2, 3) && m().buffer.lineCount == 4)
    flush()
    t.check("editor window: nothing to do, nothing painted", w.draws == 4)

    // Click to place the cursor (content-local pixels -> cells minus the gutter).
    let c = w.contentRect
    wmClick(wm, Point(c.x + (g + 2) * cw + 3, c.y + 3 * ch + 5))
    flush()
    t.check("editor window: click places the cursor",
            m().cursor == TextPosition(line: 3, column: 2) && w.paintedRows == rowBits(2, 3) && !w.paintedFull)
    wmClick(wm, Point(c.x + 3, c.y + 0 * ch + 2)) // in the gutter: start of line
    flush()
    t.check("editor window: click in the gutter goes to column 1", m().cursor == TextPosition(line: 0, column: 0))
    wmClick(wm, Point(c.x + 40 * cw, c.y + 20 * ch)) // below the text: last line
    t.check("editor window: click past the text clamps", m().cursor.line == 3)

    // Resize: the model gets the new viewport; full repaint at the new size.
    wm.resize(w, contentWidth: 40 * cw, contentHeight: 10 * ch)
    flush()
    t.check("editor window: resize relayouts",
            w.textRows == 9 && w.textCols == 36 && m().rows == 9 && m().cols == 36 && w.paintedFull
            && px(40 * cw - 2, 9 * ch + 2) == colors.statusBG)

    // Vertical scrolling keeps the cursor in view; the gutter widens past 999 lines.
    for _ in 0..<12 { wm.route(.key(Key(.char(0x0D)))) }
    flush()
    t.check("editor window: scrolls down with the cursor",
            m().topLine > 0 && m().cursorCell.row == 8 && w.paintedFull)
    // Horizontal scrolling.
    for _ in 0..<50 { wm.route(.key(Key(.char(0x61)))) }
    flush()
    t.check("editor window: scrolls right on a long line",
            m().leftColumn > 0 && m().cursorCell.col == 35 && inked(8, g + 35, colors.cursor) > 20)

    // Close while dirty: refused, the model asks; "y" saves and closes.
    wm.requestClose(w)
    flush()
    t.check("editor window: close while dirty is refused and asks",
            wm.index(of: w) != nil && m().prompt == .saveBeforeQuit && w.paintedStatus)
    wm.route(.key(Key(.char(0x1B)))) // esc: keep editing
    t.check("editor window: esc keeps it open", wm.index(of: w) != nil && m().prompt == .none)
    wm.route(.key(Key(.char(0x11), ctrl: true))) // Ctrl-Q asks too
    t.check("editor window: Ctrl-Q while dirty asks", m().prompt == .saveBeforeQuit && wm.index(of: w) != nil)
    let want = m().buffer.contents
    wm.route(.key(Key(.char(0x79)))) // y
    t.check("editor window: y saves and closes",
            wm.index(of: w) == nil && wm.focused == nil && (try? fs.read("/notes.txt")) == want && want.count > 60)

    // The taskbar's + Editor hook: an untitled editor; Ctrl-Q closes a clean one.
    wm.openEditor(wm)
    t.check("editor window: openEditor opens an untitled editor",
            wm.windows.count == 1 && wm.windows[0].title == "untitled" && wm.focused === wm.windows[0])
    wm.route(.key(Key(.char(0x11), ctrl: true)))
    t.check("editor window: Ctrl-Q closes a clean editor", wm.windows.isEmpty)

    // A file that can't be opened: no window.
    _ = try? fs.mkdir("/dir")
    let bad = openEditorWindow(wm, path: "/dir", fs: fs, colors: colors)
    t.check("editor window: a directory isn't opened", bad.window == nil && wm.windows.isEmpty && bad.message.hasPrefix("open: /dir"))

    // A 1000-line file widens the gutter; Ctrl-F's prompt puts a caret in
    // the status line and hides the text cursor.
    var big: [UInt8] = []
    for _ in 0..<1000 { big += bytes("line\n") }
    _ = try? fs.write("/big.txt", big)
    if let b = openEditorWindow(wm, path: "/big.txt", fs: fs, colors: colors).window {
        flush()
        let bc = b.contentRect
        func bpx(_ x: Int, _ y: Int) -> UInt32 { front.pixel(bc.x + x, bc.y + y) ?? 0 }
        t.check("editor window: gutter widens for 1000 lines",
                b.gutterCols == 5 && b.textCols == 75 && b.model.cols == 75 && bpx(5 * cw + 1, 1) == colors.cursor)
        wm.route(.key(Key(.char(0x06), ctrl: true))) // Ctrl-F
        flush()
        let caretX = textCells("find: ") * cw
        t.check("editor window: prompt caret in the status line, text cursor hidden",
                b.model.prompt == .find && bpx(caretX + 1, b.content.height - ch + 1) == colors.statusText
                && bpx(5 * cw + 1, 1) != colors.cursor && b.paintedRows == rowBits(0))
        wm.requestClose(b)
        t.check("editor window: a clean editor closes from the close box", wm.windows.isEmpty)
    } else {
        t.check("editor window: opens /big.txt", false)
    }

    wm.shutdown()
}
