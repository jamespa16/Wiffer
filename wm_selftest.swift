// Phase K selftests: the window manager off-screen, on a small compositor
// with a test front surface, driven by synthetic events: hit testing, focus
// and z-order, keys to the focused window, Alt-Tab, Alt-F4 and the close
// box, move and resize (with clamping), the taskbar, decoration pixels, and
// that a WM torn down leaves the heap where it was (no retain cycles).
// Called from runSelfTests.

/// Records what the WM sends it; fills its content with `color` in draw().
final class TestWindow: Window {
    var events: [Event] = []
    var draws = 0
    var closeCalls = 0
    var allowClose = true
    let color: UInt32

    init(_ title: String, _ w: Int, _ h: Int, color: UInt32) {
        self.color = color
        super.init(title: title, contentWidth: w, contentHeight: h)
        events.reserveCapacity(64)
    }

    override func handle(_ event: Event) {
        if events.count < 64 { events.append(event) }
    }

    override func draw() {
        draws += 1
        content.fill(color)
        invalidate()
    }

    override func close() -> Bool {
        closeCalls += 1
        return allowClose
    }

    func keys() -> Int {
        var n = 0
        for e in events { if case .key = e { n += 1 } }
        return n
    }

    func got(_ e: Event) -> Bool { events.contains(e) }
}

func wmClick(_ wm: WindowManager, _ p: Point) {
    wm.route(.mouse(x: p.x, y: p.y, buttons: 1))
    wm.route(.mouse(x: p.x, y: p.y, buttons: 0))
}

func wmDrag(_ wm: WindowManager, _ from: Point, _ to: Point) {
    wm.route(.mouse(x: from.x, y: from.y, buttons: 1))
    wm.route(.mouse(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2, buttons: 1))
    wm.route(.mouse(x: to.x, y: to.y, buttons: 1))
    wm.route(.mouse(x: to.x, y: to.y, buttons: 0))
}

func centre(_ r: Rect) -> Point { Point(r.x + r.w / 2, r.y + r.h / 2) }

/// Every corner of `r` is inside some pending damage rect.
func damageCovers(_ c: Compositor, _ r: Rect) -> Bool {
    let corners = [Point(r.x, r.y), Point(r.maxX - 1, r.y), Point(r.x, r.maxY - 1), Point(r.maxX - 1, r.maxY - 1)]
    for p in corners {
        var inside = false
        for i in 0..<c.damageCount where c.damageRect(i).contains(p) { inside = true }
        if !inside { return false }
    }
    return true
}

func wmTests(_ t: inout SelfTest) {
    guard let font = PSFFont(font_data(), size: Int(font_psf_size)) else {
        t.check("wm: font", false)
        return
    }
    let before = HeapUsage()
    var classes = InlineArray<16, Int>(repeating: 0)
    for i in 0..<heapClassCount { classes[i] = heap.liveBlocks[i] }
    // (The font's glyph map must outlive the measurement: Swift may free it
    // right after its last use.)
    let after = withExtendedLifetime(font) {
        wmScenario(&t, font)
        return HeapUsage()
    }
    t.check("wm: torn down, heap back to baseline (no retain cycles)", after == before)
    if after != before {
        print("  heap: \(before.blocks) -> \(after.blocks) blocks, \(before.bytes) -> \(after.bytes) bytes, large \(before.largeFrames) -> \(after.largeFrames)")
        for i in 0..<heapClassCount where heap.liveBlocks[i] != classes[i] {
            print("  class \(Heap.classSize(i)): \(classes[i]) -> \(heap.liveBlocks[i])")
        }
    }
}

@inline(never)
func wmScenario(_ t: inout SelfTest, _ font: PSFFont) {
    let front = Surface(width: 640, height: 400, color: 0xDEAD)
    let comp = Compositor(front: front)
    comp.add(PatternLayer(frame: comp.bounds, color: 0x102030))
    let theme = WindowTheme(font: font)
    let wm = WindowManager(compositor: comp, theme: theme)
    t.check("wm: taskbar along the bottom, work area above it",
            wm.taskbar?.frame == Rect(0, 380, 640, 20) && wm.workArea == Rect(0, 0, 640, 380))

    // K1: geometry of a window.
    let a = TestWindow("A", 200, 100, color: 0xA0)
    let b = TestWindow("B", 200, 100, color: 0xB0)
    wm.add(a, at: Point(20, 20))
    wm.add(b, at: Point(100, 60))
    t.check("wm: frame = content + border + title bar",
            a.frame == Rect(20, 20, 204, 124) && a.contentRect == Rect(22, 42, 200, 100)
            && a.titleRect == Rect(22, 22, 200, 20))
    t.check("wm: ids, z-order, newest focused",
            a.id == 1 && b.id == 2 && wm.windows.count == 2 && wm.windows[1] === b && wm.focused === b
            && b.focused && !a.focused && comp.index(of: a)! < comp.index(of: b)!)
    t.check("wm: focus events", b.got(.focus(true)) && a.got(.focus(true)) && a.got(.focus(false)))

    // K2: hit testing.
    func hit(_ p: Point) -> (Int, WindowPart)? {
        guard let h = wm.hitTest(p) else { return nil }
        return (h.window.id, h.part)
    }
    func isHit(_ p: Point, _ id: Int, _ part: WindowPart) -> Bool {
        guard let h = hit(p) else { return false }
        return h.0 == id && h.1 == part
    }
    t.check("wm: hit title bar", isHit(Point(110, 70), 2, .title) && isHit(Point(30, 25), 1, .title))
    t.check("wm: hit close box", isHit(centre(b.closeRect), 2, .close))
    t.check("wm: hit resize grip", isHit(Point(b.frame.maxX - 2, b.frame.maxY - 2), 2, .resize))
    t.check("wm: hit content (topmost window wins)", isHit(Point(150, 120), 2, .content) && isHit(Point(40, 60), 1, .content))
    t.check("wm: hit border", isHit(Point(b.frame.x, b.frame.y + 50), 2, .border))
    t.check("wm: nothing over the desktop or taskbar", hit(Point(600, 300)) == nil && hit(Point(5, 390)) == nil)

    // Keys go to the focused window only.
    wm.route(.key(Key(.char(0x61))))
    t.check("wm: keys to the focused window", b.keys() == 1 && a.keys() == 0)

    // Click to raise and focus.
    wmClick(wm, Point(30, 25))
    t.check("wm: click raises and focuses", wm.focused === a && a.focused && !b.focused
            && wm.windows[1] === a && comp.index(of: a)! > comp.index(of: b)!)
    wm.route(.key(Key(.char(0x62))))
    t.check("wm: keys follow focus", a.keys() == 1 && b.keys() == 1)

    // Content clicks arrive in window-local coordinates; a press captures.
    a.events.removeAll()
    wmClick(wm, Point(40, 70)) // content origin (22, 42)
    t.check("wm: content mouse in local coordinates",
            a.got(.mouse(x: 18, y: 28, buttons: 1)) && a.got(.mouse(x: 18, y: 28, buttons: 0)))
    a.events.removeAll()
    wm.route(.mouse(x: 40, y: 70, buttons: 1))
    wm.route(.mouse(x: 300, y: 300, buttons: 1)) // dragged outside, over b
    wm.route(.mouse(x: 300, y: 300, buttons: 0))
    t.check("wm: a content press captures the pointer",
            a.got(.mouse(x: 278, y: 258, buttons: 1)) && a.got(.mouse(x: 278, y: 258, buttons: 0))
            && b.events.allSatisfy { if case .mouse = $0 { return false } else { return true } })

    // Alt-Tab cycles through every window; shortcuts aren't delivered.
    let c = TestWindow("C", 120, 60, color: 0xC0)
    wm.add(c, at: Point(300, 200))
    var order: [Int] = []
    for _ in 0..<3 {
        wm.route(.key(Key(.char(0x09), alt: true)))
        order.append(wm.focused?.id ?? 0)
    }
    t.check("wm: Alt-Tab cycles focus", order == [2, 1, 3] && wm.windows[2] === c)
    t.check("wm: shortcuts aren't passed on", c.keys() == 0 && a.keys() == 0 && b.keys() == 1)

    // Alt-F4 asks the focused window; it may refuse.
    c.allowClose = false
    wm.route(.key(Key(.function(4), alt: true)))
    t.check("wm: Alt-F4 asks, refusal keeps the window", c.closeCalls == 1 && wm.windows.count == 3)
    c.allowClose = true
    wm.route(.key(Key(.function(4), alt: true)))
    t.check("wm: Alt-F4 closes, focus to the new top",
            c.closeCalls == 2 && wm.windows.count == 2 && wm.index(of: c) == nil && comp.index(of: c) == nil
            && wm.focused === wm.windows[1] && wm.focused!.focused && !c.focused)

    // The close box.
    wmClick(wm, Point(110, 70)) // b's title: b on top
    wmClick(wm, centre(b.closeRect))
    t.check("wm: close box closes", b.closeCalls == 1 && wm.windows.count == 1 && wm.focused === a)
    let unclosable = TestWindow("U", 100, 40, color: 0xD0)
    unclosable.closable = false
    wm.add(unclosable, at: Point(400, 20))
    wm.route(.key(Key(.function(4), alt: true)))
    t.check("wm: unclosable windows stay", unclosable.closeCalls == 0 && wm.windows.count == 2
            && unclosable.part(at: centre(unclosable.closeRect)) == .title)
    wm.remove(unclosable)

    // K3: drag the title bar to move; old and new frames are damaged.
    comp.composite()
    let old = a.frame
    wmDrag(wm, Point(30, 25), Point(130, 85))
    t.check("wm: drag moves the window", a.frame == Rect(120, 80, 204, 124))
    t.check("wm: move damages old and new frames", damageCovers(comp, old) && damageCovers(comp, a.frame))
    t.check("wm: release ends the drag", { wm.route(.mouse(x: 0, y: 0, buttons: 0)); return a.frame.x == 120 }())
    // Clamping: the title bar stays reachable.
    let grab = Point(a.frame.x + 10, a.frame.y + 5)
    wmDrag(wm, grab, Point(grab.x - 2000, grab.y - 2000))
    t.check("wm: clamped at top-left", a.frame.x == 48 - 204 && a.frame.y == 0)
    let grab2 = Point(a.frame.maxX - 30, a.frame.y + 5)
    wmDrag(wm, grab2, Point(grab2.x + 5000, grab2.y + 5000))
    t.check("wm: clamped at bottom-right, title above the taskbar",
            a.frame.x == 640 - 48 && a.frame.y == 380 - Window.titleHeight - Window.border
            && a.titleRect.intersection(wm.workArea).w >= 48 - Window.border
            && a.titleRect.intersection(wm.workArea).h == Window.titleHeight)
    wm.move(a, to: Point(20, 20))

    // Resize from the grip: new content surface, .resize, minimum size.
    a.events.removeAll()
    let oldContent = a.content
    let g = Point(a.frame.maxX - 3, a.frame.maxY - 3)
    wmDrag(wm, g, Point(g.x + 50, g.y + 30))
    t.check("wm: grip drag resizes", a.content.width == 250 && a.content.height == 130
            && a.frame == Rect(20, 20, 254, 154) && a.content !== oldContent)
    t.check("wm: resize sends .resize", a.got(.resize(width: 225, height: 115)) && a.got(.resize(width: 250, height: 130)))
    let g2 = Point(a.frame.maxX - 3, a.frame.maxY - 3)
    wmDrag(wm, g2, Point(g2.x - 1000, g2.y - 1000))
    t.check("wm: minimum size enforced", a.content.width == a.minContentWidth && a.content.height == a.minContentHeight)
    let g3 = Point(a.frame.maxX - 3, a.frame.maxY - 3)
    wmDrag(wm, g3, Point(g3.x + 5000, g3.y + 5000))
    t.check("wm: at most the work area", a.content.width == 640 - 4 && a.content.height == 380 - 24)
    wm.resize(a, contentWidth: 200, contentHeight: 100)

    // K4: taskbar buttons.
    guard let tb = wm.taskbar else { return }
    // Phase T: CPU usage meters (rows lit per percentage, redraw on change).
    let rows = Taskbar.meterRows
    t.check("wm: CPU meter levels (idle, any use, half, full)",
            Taskbar.level(0) == 0 && Taskbar.level(1) == 1 && Taskbar.level(50) == rows / 2
                && Taskbar.level(100) == rows && Taskbar.level(250) == rows)
    let first = tb.setCPUs(count: 2, usage: [100, 0])
    t.check("wm: CPU meters change only when a level does",
            tb.setCPUs(count: 2, usage: [100, 0]) == false && tb.setCPUs(count: 2, usage: [100, 1])
                && tb.cpuLevels == [rows, 1] && (first || tb.cpuCount == 2))
    let b2 = TestWindow("B2", 160, 80, color: 0xB2)
    wm.add(b2, at: Point(300, 150))
    var opened = 0, edited = 0
    wm.openTerminal = { _ in opened += 1 }
    wm.openEditor = { _ in edited += 1 }
    t.check("wm: taskbar has launchers then a button per window",
            tb.items.count == 4 && tb.button(for: a) != nil && tb.button(for: b2) != nil
            && tb.item(at: centre(tb.items[0].rect)).map { if case .openTerminal = $0.action { return true }; return false } == true)
    wmClick(wm, centre(tb.items[0].rect))
    wmClick(wm, centre(tb.items[1].rect))
    t.check("wm: + Terminal / + Editor call the hooks", opened == 1 && edited == 1)
    wmClick(wm, centre(tb.button(for: a)!.rect))
    t.check("wm: window button focuses and raises", wm.focused === a && wm.windows.last === a)
    wmClick(wm, Point(tb.items[1].rect.maxX + 3, 390)) // between buttons
    t.check("wm: taskbar gap does nothing", wm.focused === a && opened == 1)
    wm.route(.key(Key(.char(0x14), ctrl: true, alt: true)))
    wm.route(.key(Key(.char(0x0D), meta: true)))
    t.check("wm: Ctrl-Alt-T and Super+Enter open a terminal", opened == 3 && a.keys() == 0)

    // Serial keys go to the serial target, whatever has focus.
    wm.serialTarget = b2
    wm.route(.key(Key(.char(0x63), serial: true)))
    wm.route(.key(Key(.char(0x64))))
    t.check("wm: serial keys to the serial target", b2.keys() == 1 && a.keys() == 1)
    wm.serialTarget = nil

    // Pixels: content, decorations in focus colours, the taskbar.
    let beforeRender = HeapUsage()
    a.dirty = true
    wm.render()
    comp.composite()
    let drew = a.draws
    wm.render()
    t.check("wm: render and composite don't allocate", HeapUsage() == beforeRender && a.draws == drew)
    a.invalidate(Rect(0, 0, 2, 2))
    a.invalidate(Rect(0, a.content.height - 2, 2, 2))
    t.check("wm: preserves disjoint window invalidations", a.pendingDamageCount == 2)
    wm.render()
    comp.composite()
    t.check("wm: copies only disjoint damaged pixels", comp.stats.pixels == 8 && a.pendingDamageCount == 0)
    func px(_ p: Point) -> UInt32 { front.pixel(p.x, p.y) ?? 0 }
    let at = a.titleRect, bt = b2.titleRect
    t.check("wm: content composited", px(centre(a.contentRect)) == 0xA0 && px(centre(b2.contentRect)) == 0xB2)
    t.check("wm: focused title bar and border",
            px(Point(at.maxX - Window.closeSize - 8, at.y + 1)) == theme.titleFocused
            && px(Point(a.frame.x, a.frame.y + 40)) == theme.borderFocused
            && px(centre(a.closeRect)) != theme.titleFocused)
    t.check("wm: unfocused title bar and border",
            px(Point(bt.maxX - Window.closeSize - 8, bt.y + 1)) == theme.titleUnfocused
            && px(Point(b2.frame.maxX - 1, b2.frame.y + 40)) == theme.borderUnfocused)
    t.check("wm: taskbar drawn, focused button highlighted",
            px(Point(639, 395)) == theme.taskbarBG && px(Point(tb.button(for: a)!.rect.maxX - 2, 384)) == theme.buttonFocusedBG
            && px(Point(tb.button(for: b2)!.rect.maxX - 2, 384)) == theme.buttonBG)
    // Swap focus by clicking b2: the colours swap.
    wmClick(wm, Point(bt.x + 100, bt.y + 5))
    wm.render()
    comp.composite()
    t.check("wm: click swaps focus colours",
            px(Point(at.maxX - Window.closeSize - 8, at.y + 1)) == theme.titleUnfocused
            && px(Point(bt.maxX - Window.closeSize - 8, bt.y + 1)) == theme.titleFocused)

    // A placeholder app marks clicks at their local position.
    let p = PlaceholderWindow(title: "P", note: "n", width: 120, height: 90)
    wm.add(p, at: Point(400, 40))
    wmClick(wm, Point(p.contentRect.x + 60, p.contentRect.y + 70))
    wm.render()
    comp.composite()
    t.check("wm: placeholder marks a click locally",
            p.clicks == [Point(60, 70)] && px(Point(p.contentRect.x + 60, p.contentRect.y + 70)) == theme.appMarker
            && px(Point(p.contentRect.x + 110, p.contentRect.y + 50)) == theme.appBG)

    wm.openTerminal = { _ in }
    wm.openEditor = { _ in }
    wm.shutdown()
    t.check("wm: shutdown empties the screen", wm.windows.isEmpty && wm.focused == nil && comp.layers.count == 1)
}
