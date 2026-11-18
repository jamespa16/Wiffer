// Phase 6F selftests: the window event queue, and ring-3 windows end to end
// on an off-screen WM (the `wintest` program): create, draw, present and
// composite; keys, mouse, a drag, a resize; close through the close
// request; a kill while focused; an event flood with no reader; an
// unanswered close; bad syscall arguments. Frames and heap return to
// their baselines.

/// Poll `cond` every 10 ms for up to `ms`.
func waitFor(_ ms: UInt64, _ cond: () -> Bool) -> Bool {
    let deadline = deadlineAfter(ms: ms)
    while !cond() {
        if ticks >= deadline { return false }
        _ = sleepMilliseconds(10)
    }
    return true
}

func debugHas(_ p: Process, _ text: String) -> Bool {
    has(String(decoding: p.debugBytes, as: UTF8.self), text)
}

func windowTests(_ t: inout SelfTest) {
    channelTests(&t)
    guard let me = scheduler.current, (try? vfs.lookup("/bin/wintest")) != nil,
          let font = PSFFont(font_data(), size: Int(font_psf_size)) else {
        t.check("6F: /bin/wintest and the font", false)
        return
    }
    let frames = pmm.freeFrames, splits = splitPages, heap0 = HeapUsage()
    withExtendedLifetime(font) { windowScenario(&t, me, font) }
    let leaked = frames - pmm.freeFrames - (splitPages - splits)
    if leaked != 0 { print("  pmm: \(leaked) frames leaked by the 6F tests") }
    t.check("6F: no frames leaked by windows", leaked <= 0 && userWindowFrames == 0)
    let heapNow = HeapUsage()
    if heapNow.blocks > heap0.blocks + 4 || heapNow.largeFrames > heap0.largeFrames {
        print("  heap: \(heap0.blocks) -> \(heapNow.blocks) blocks, large \(heap0.largeFrames) -> \(heapNow.largeFrames) frames")
    }
    t.check("6F: no heap leaked by windows", heapNow.blocks <= heap0.blocks + 4 && heapNow.largeFrames <= heap0.largeFrames)
}

@inline(never)
func channelTests(_ t: inout SelfTest) {
    let c = WinChannel()
    func motion(_ x: Int) -> WinEvent { WinEvent(kind: WinEventKind.mouse, mods: 0, a: Int32(x), b: 0, c: 0) }
    func key(_ k: Int) -> WinEvent { WinEvent(kind: WinEventKind.key, mods: 0, a: Int32(k), b: 0, c: 0) }
    t.check("6F2: an empty queue isn't readable", !c.isReadable && c.take(4) == nil)
    for i in 0..<1000 { c.post(motion(i)) }
    t.check("6F2: mouse motion coalesces into one record", c.count == 1 && c.coalesced == 999)
    c.post(WinEvent(kind: WinEventKind.mouse, mods: 1, a: 5, b: 5, c: 0))
    c.post(motion(7))
    t.check("6F2: a button change is its own record, motion after it is another", c.count == 3)
    let got = c.take(10) ?? []
    t.check("6F2: records come out in order, motion carrying its latest position",
            got.count == 3 && got[0].a == 999 && got[1].mods == 1 && got[2].a == 7)
    // A flood of keys with no reader: capped.
    for i in 0..<5000 { c.post(key(i & 0x7F)) }
    t.check("6F2: a key flood is capped", c.count == WinChannel.capacity && c.dropped > 4000)
    // Motion goes first when full: evicted for a key, dropped itself.
    let c2 = WinChannel()
    var alt = false
    for i in 0..<WinChannel.capacity { alt.toggle(); c2.post(alt ? motion(i) : WinEvent(kind: WinEventKind.mouse, mods: UInt16(1 + i % 2), a: 0, b: 0, c: 0)) }
    let full = c2.count
    c2.post(key(65))
    var lastIsKey = false
    if let all = c2.take(1000), let l = all.last { lastIsKey = l.kind == WinEventKind.key }
    t.check("6F2: a key evicts old motion when the queue is full", full == WinChannel.capacity && lastIsKey)
    let c3 = WinChannel()
    for i in 0..<300 { c3.post(i % 2 == 0 ? WinEvent(kind: WinEventKind.focus, mods: 0, a: 1, b: 0, c: 0) : motion(i)) }
    t.check("6F2: still capped with mixed events", c3.count <= WinChannel.capacity)
    // Resizes coalesce; a close can't be lost.
    let c4 = WinChannel()
    for i in 0..<50 { c4.post(WinEvent(kind: WinEventKind.resize, mods: 0, a: Int32(100 + i), b: 50, c: 0)) }
    for i in 0..<500 { c4.post(key(i & 63)) }
    t.check("6F2: resize events coalesce", (c4.take(1000) ?? []).first?.a == 149)
    for i in 0..<500 { c4.post(key(i & 63)) }
    let first = c4.requestClose()
    let again = c4.requestClose()
    let out = c4.take(1)
    t.check("6F2: a close request is delivered first even when the queue is full",
            !first && again && out?.first?.kind == WinEventKind.close)
    c4.shutDown()
    t.check("6F2: a shut channel takes nothing", !c4.isReadable && c4.take(4) == nil)
}

@inline(never)
func windowScenario(_ t: inout SelfTest, _ me: Task, _ font: PSFFont) {
    let front = Surface(width: 640, height: 400, color: 0)
    let comp = Compositor(front: front)
    comp.add(PatternLayer(frame: comp.bounds, color: 0x102030))
    let wm = WindowManager(compositor: comp, theme: WindowTheme(font: font))
    let base = PlaceholderWindow(title: "base", note: "")
    wm.add(base, at: Point(400, 20))
    testWindowManager = wm
    defer {
        testWindowManager = nil
        wm.shutdown()
    }
    func start(_ args: [String]) -> Process? {
        try? spawnProcess(path: "/bin/wintest", argv: args, output: ConsoleChannel(reader: me), waiter: me)
    }
    func userWindow() -> UserWindow? { wm.windows.last as? UserWindow }

    // The bad-argument program.
    let bad = runProgramForTest(["wintest", "bad"])
    t.check("6F1: bad window syscall arguments fail cleanly", bad.status == .exited(0))
    t.check("6F1: the bad-argument program leaves no windows", wm.windows.count == 1 && userWindowFrames == 0)

    // Create, draw, present, composite.
    guard let p = start(["wintest"]) else { t.check("6F1: spawn wintest", false); return }
    let opened = waitFor(5000) { wm.windows.count == 2 }
    guard opened, let win = userWindow() else {
        t.check("6F1: win_create opens a window", false)
        _ = waitProcess(p, interrupt: { true })
        return
    }
    t.check("6F1: win_create opens a focused window of the asked size",
            win.title == "wintest" && win.content.width == 220 && win.content.height == 140 && wm.focused === win
            && win.contentIsBuffer && win.bufferWidth == 220)
    t.check("6F1: the buffer is mapped in the process, not owned",
            win.userAddress >= UInt(UserLayout.mapBase) && p.space?.translate(win.userAddress)?.phys == win.bufferPhys
            && p.space?.translate(win.userAddress)?.flags.contains(.owned) == false)
    let drawn = waitFor(5000) { win.content.pixel(10, 70) == 0x2040C0 }
    t.check("6F3: the program drew into the shared buffer (marker rectangle)", drawn)
    _ = waitFor(2000) { win.presents > 0 }
    wm.render()
    comp.composite()
    let cr = win.contentRect
    t.check("6F2: present reaches the compositor's output", front.pixel(cr.x + 10, cr.y + 70) == 0x2040C0)
    t.check("6F3: widgets drawn (the button's border)", front.pixel(cr.x + 10, cr.y + 10) == 0x6E6E6E)

    // Keys and the mouse.
    wm.key(Key(.char(0x61)))
    t.check("6F2: a key reaches the program", waitFor(3000) { debugHas(p, "ev key 97") })
    wm.key(Key(.left, ctrl: true))
    t.check("6F2: modifiers and special keys", waitFor(3000) { debugHas(p, "ev key \(WinKey.left) ctrl=true") })
    wmClick(wm, Point(cr.x + 20, cr.y + 20))
    t.check("6F2: a click reaches the program's button", waitFor(3000) { debugHas(p, "ev click 1") })
    t.check("6F2: mouse events carry content-local positions", debugHas(p, "ev mouse 20 20 b=1"))
    wmClick(wm, Point(cr.x + 30, cr.y + 110))
    for c in "hi" { wm.key(Key(.char(UInt8(c.asciiValue ?? 0x20)))) }
    wm.key(Key(.char(0x0D)))
    t.check("6F3: a text field takes typing and Enter", waitFor(3000) { debugHas(p, "ev submit hi") })

    // Drag the window by its title bar.
    let before = win.frame
    wmDrag(wm, Point(before.x + 60, before.y + 8), Point(before.x + 100, before.y + 48))
    t.check("6F2: dragging moves the window", win.frame.x == before.x + 40 && win.frame.y == before.y + 40)
    wm.render()
    comp.composite()
    t.check("6F2: the moved window is drawn where it went",
            front.pixel(win.contentRect.x + 10, win.contentRect.y + 70) == 0x2040C0)

    // Focus change reaches the program.
    wm.focus(base)
    t.check("6F2: losing focus is an event", waitFor(3000) { debugHas(p, "ev focus 0") })
    wm.focus(win)

    // Resize with the grip: the program adopts a new buffer.
    let oldAddress = win.userAddress, oldPhys = win.bufferPhys
    let grip = Point(win.frame.maxX - 3, win.frame.maxY - 3)
    wmDrag(wm, grip, Point(grip.x + 60, grip.y + 40))
    t.check("6F1: the WM resizes the window's content", win.content.width == 280 || win.content.height == 180)
    let adopted = waitFor(5000) { win.contentIsBuffer && win.bufferWidth == win.content.width }
    t.check("6F1: win_resize maps a new buffer of the new size", adopted && win.bufferWidth == 280 && win.bufferHeight == 180
            && win.bufferPhys != oldPhys && win.userAddress != oldAddress)
    t.check("6F1: the old buffer is unmapped", p.space?.translate(oldAddress) == nil)
    t.check("6F1: the new buffer is mapped", p.space?.translate(win.userAddress)?.phys == win.bufferPhys)
    t.check("6F3: the resize event and the redraw arrived", debugHas(p, "ev adopted 280 180")
            && waitFor(3000) { win.content.pixel(270, 70) == 0x2040C0 })

    // Closing: the close box asks, the program agrees.
    wm.requestClose(win)
    t.check("6F2: the close request is an event", waitFor(3000) { debugHas(p, "ev close") || p.state == .zombie })
    let status = waitProcess(p)
    t.check("6F1: the program exits on close and the window is gone",
            status == .exited(0) && wm.windows.count == 1 && wm.focused === base && userWindowFrames == 0)

    // A process killed while its window is focused.
    guard let q = start(["wintest"]), waitFor(5000, { wm.windows.count == 2 }), let w2 = userWindow() else {
        t.check("6F: second window", false)
        return
    }
    t.check("6F: the second window is focused", wm.focused === w2)
    let framesOpen = pmm.freeFrames
    killProcess(q.pid)
    let killed = waitProcess(q)
    t.check("6F: killing the process closes its window and focus moves on",
            killed == .killed && wm.windows.count == 1 && wm.focused === base)
    t.check("6F: the window's frames came back", pmm.freeFrames > framesOpen && userWindowFrames == 0)

    // Event flood, nobody reading.
    guard let r = start(["wintest", "noread"]), waitFor(5000, { wm.windows.count == 2 }), let w3 = userWindow() else {
        t.check("6F2: noread window", false)
        return
    }
    let heapBefore = heap.bytesInUse
    for i in 0..<20000 {
        w3.handle(.mouse(x: i & 255, y: i & 127, buttons: UInt8(i / 500 & 1)))
        w3.handle(.key(Key(.char(UInt8(0x20 + i % 90)))))
    }
    t.check("6F2: an event flood with no reader stays capped", w3.channel.count <= WinChannel.capacity
            && w3.channel.dropped > 10000)
    t.check("6F2: and kernel memory didn't grow", heap.bytesInUse <= heapBefore + 4096)
    // An unanswered close request twice: the process is killed.
    wm.requestClose(w3)
    wm.requestClose(w3)
    t.check("6F2: a second unanswered close kills a hung program", waitProcess(r) == .killed && wm.windows.count == 1)
}
