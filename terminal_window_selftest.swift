// Phase L selftests: terminal windows on an off-screen WM with real tasks.
// Two terminals side by side, each with its own shell (variables, history),
// keys only reaching the focused one; serial following focus; resizing the
// console keeping what fits; every way of closing a terminal (exit, the
// close box, Alt-F4, requestClose as `close <n>` does, a plain remove)
// ending its task; and the heap and frame allocator back where they started.
// Called from runSelfTests (in the shell's task, so it can yield to the
// terminal tasks).

/// Row of `c` that contains `text` (ASCII), or nil.
func consoleFind(_ c: Console, _ text: StaticString) -> Int? {
    text.withUTF8Buffer { want in
        guard want.count <= c.cols else { return nil }
        for r in 0..<c.rows {
            var start = 0
            while start + want.count <= c.cols {
                var match = true
                for i in 0..<want.count where c.cell(r, start + i).ch != UInt32(want[i]) {
                    match = false
                    break
                }
                if match { return r }
                start += 1
            }
        }
        return nil
    }
}

/// Type `text` and Enter through the WM (to the focused window).
func wmType(_ wm: WindowManager, _ text: StaticString) {
    text.withUTF8Buffer { for b in $0 { wm.route(.key(Key(.char(b)))) } }
    wm.route(.key(Key(.char(0x0D))))
}

/// Let the other tasks run until each is blocked with an empty inbox and
/// finished ones are freed. False on timeout (5 s).
func settleTasks() -> Bool {
    let deadline = ticks + 5 * timerHz
    while ticks < deadline {
        if otherTasksSettled() { return true }
        yield()
    }
    return false
}

func consoleResizeTests(_ t: inout SelfTest) {
    let c = Console(cols: 10, rows: 4)
    feed(c, Array("one\r\ntwo\r\nthree\r\nfour".utf8))
    let small = c.resized(cols: 3, rows: 2)
    t.check("terminal: shrinking keeps the cursor's rows (top-left of them)",
            rowIs(small, 0, "thr") && rowIs(small, 1, "fou") && small.row == 1 && small.col == 3
            && small.scrollCount == c.scrollCount + 2)
    let big = c.resized(cols: 12, rows: 6)
    t.check("terminal: growing keeps everything, blanks the rest",
            rowIs(big, 0, "one") && rowIs(big, 3, "four") && rowIs(big, 5, "") && big.row == 3 && big.col == 4)
    feed(big, Array("\r\nfive".utf8))
    t.check("terminal: the resized console carries on", rowIs(big, 4, "five"))
}

func terminalWindowTests(_ t: inout SelfTest) {
    consoleResizeTests(&t)
    guard let font = PSFFont(font_data(), size: Int(font_psf_size)) else {
        t.check("terminal: font", false)
        return
    }
    t.check("terminal: no other tasks busy", settleTasks())
    let tasksBefore = scheduler.taskCount
    let before = HeapUsage(), frames = pmm.freeFrames, chunks = heap.chunkFrames
    // Measured while the font (its 128 KiB glyph map) is still alive.
    let (after, framesAfter, chunksAfter) = withExtendedLifetime(font) {
        terminalScenario(&t, font)
        _ = settleTasks()
        return (HeapUsage(), pmm.freeFrames, heap.chunkFrames)
    }
    t.check("terminal: every task ended", scheduler.taskCount == tasksBefore)
    t.check("terminal: heap back to baseline (windows, consoles, shells freed)", after == before)
    t.check("terminal: task stacks returned to the frame allocator", framesAfter + (chunksAfter - chunks) == frames)
    if framesAfter + (chunksAfter - chunks) != frames {
        print("  frames: free \(frames) -> \(framesAfter), heap chunks \(chunks) -> \(chunksAfter)")
    }
    if after != before {
        print("  heap: \(before.blocks) -> \(after.blocks) blocks, \(before.bytes) -> \(after.bytes) bytes")
    }
}

@inline(never)
func terminalScenario(_ t: inout SelfTest, _ font: PSFFont) {
    let front = Surface(width: 640, height: 400, color: 0xDEAD)
    let comp = Compositor(front: front)
    comp.add(PatternLayer(frame: comp.bounds, color: 0x102030))
    let wm = WindowManager(compositor: comp, theme: WindowTheme(font: font))
    wm.openTerminal = openTerminalWindow
    defer { wm.shutdown() }

    guard let a = openTerminal(in: wm, cols: 36, rows: 10), let b = openTerminal(in: wm, cols: 36, rows: 10) else {
        t.check("terminal: open two", false)
        return
    }
    t.check("terminal: two side by side, the newer focused",
            a.frame.y == b.frame.y && a.frame.maxX < b.frame.x && wm.focused === b && a.title == "Terminal 1"
            && b.title == "Terminal 2")
    t.check("terminal: console sized to the content area",
            a.console.cols == 36 && a.console.rows == 10 && a.content.width == 36 * 8 && a.content.height == 160)
    t.check("terminal: both shells start", settleTasks()
            && rowIs(a.console, 0, "Type 'help' for commands.") && rowIs(b.console, 1, "> "))

    // Keys go to the focused terminal only; each shell has its own variables.
    wmType(wm, "set x 2")
    wmType(wm, "echo only-in-b")
    _ = settleTasks()
    wmClick(wm, centre(a.contentRect))
    t.check("terminal: click focuses the other", wm.focused === a && a.view.showCursor && !b.view.showCursor)
    wmType(wm, "set x 1")
    wmType(wm, "get x")
    _ = settleTasks()
    t.check("terminal: typing in one doesn't echo in the other",
            consoleFind(b.console, "only-in-b") != nil && consoleFind(a.console, "only-in-b") == nil
            && consoleFind(b.console, "set x 1") == nil)
    t.check("terminal: get in A", rowIs(a.console, 2, "> get x") && rowIs(a.console, 3, "1"))
    wmClick(wm, centre(b.contentRect))
    wmType(wm, "get x")
    _ = settleTasks()
    t.check("terminal: B keeps its own variable", rowIs(b.console, 4, "> get x") && rowIs(b.console, 5, "2"))
    wmType(wm, "history")
    _ = settleTasks()
    t.check("terminal: B's history is its own",
            consoleFind(b.console, "   1  set x 2") != nil && consoleFind(b.console, "   3  get x") != nil
            && consoleFind(b.console, "set x 1") == nil)

    // Drawn into the window, composited.
    wm.render()
    comp.composite()
    var ink = 0
    let row0 = b.contentRect
    for x in row0.x..<(row0.x + 25 * 8) {
        for y in row0.y..<(row0.y + 16) where front.pixel(x, y) == b.view.palette[7] { ink += 1 }
    }
    t.check("terminal: text rendered on screen", ink > 100)

    // Serial follows focus.
    wm.serialFollowsFocus = true
    wmClick(wm, centre(a.contentRect))
    let toA = wm.serialTarget === a && a.isSerialTarget
    wmClick(wm, centre(b.contentRect))
    t.check("terminal: serial follows the focused terminal", toA && wm.serialTarget === b && !a.isSerialTarget)
    wm.serialFollowsFocus = false
    wm.serialTarget = nil

    // Resize: the grid follows the content area, the prompt stays.
    wm.resize(b, contentWidth: 30 * 8 + 5, contentHeight: 5 * 16 + 7)
    t.check("terminal: resize re-creates the console",
            b.console.cols == 30 && b.console.rows == 5 && b.console.cell(b.console.row, 0).ch == 0x3E)
    wmType(wm, "echo resized")
    _ = settleTasks()
    t.check("terminal: the shell carries on after a resize", rowIs(b.console, 4, "> ") && rowIs(b.console, 3, "resized"))
    wm.resize(b, contentWidth: 40 * 8, contentHeight: 12 * 16)
    t.check("terminal: grow again", b.console.cols == 40 && b.console.rows == 12 && rowIs(b.console, 3, "resized"))
    wm.render()
    comp.composite()

    // Closing: `exit`.
    wmType(wm, "exit")
    t.check("terminal: exit closes the window", settleTasks() && wm.index(of: b) == nil && wm.focused === a)
    // Ctrl-Alt-T, then the close box.
    wm.route(.key(Key(.char(0x14), ctrl: true, alt: true)))
    if let c = wm.windows.last as? TerminalWindow, c !== a {
        _ = settleTasks()
        wmClick(wm, centre(c.closeRect))
        t.check("terminal: Ctrl-Alt-T opens one, the close box closes it",
                settleTasks() && wm.index(of: c) == nil && rowIs(c.console, 1, "> ^C"))
    } else {
        t.check("terminal: Ctrl-Alt-T opens a terminal", false)
    }
    // requestClose (`close <n>`), and a plain remove().
    if let d = openTerminal(in: wm), let e = openTerminal(in: wm) {
        _ = settleTasks()
        wm.requestClose(d)
        wm.remove(e)
        t.check("terminal: requestClose and remove end the shells", settleTasks() && wm.windows.count == 1)
    } else {
        t.check("terminal: open two more", false)
    }
    // Alt-F4 on the last one, with a half-typed line (abandoned, not run).
    wm.focus(a)
    for ch in "exit".utf8 { wm.route(.key(Key(.char(ch)))) }
    wm.route(.key(Key(.function(4), alt: true)))
    t.check("terminal: Alt-F4 closes it", settleTasks() && wm.windows.isEmpty && wm.focused == nil)
}
