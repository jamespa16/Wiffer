// Host tests for lib/gui: text field editing, buttons, scroll views, the
// container's routing and damage, event decoding.

private func key(_ code: Int, ctrl: Bool = false, shift: Bool = false) -> GUIKeyEvent {
    GUIKeyEvent(code: code, ctrl: ctrl, shift: shift)
}

private func type(_ f: TextField, _ s: String) {
    for u in s.unicodeScalars { _ = f.key(key(Int(u.value))) }
}

func libTests(_ t: Tests) {
    guard let data = t.readFile("fonts/spleen-8x16.psfu"),
          let font = data.withUnsafeBufferPointer({ PSFFont($0.baseAddress!, size: data.count) }) else {
        t.check(false, "font loads")
        return
    }
    withExtendedLifetime(data) {
        textFieldTests(t, font)
        buttonTests(t, font)
        scrollTests(t, font)
        containerTests(t, font)
        decodeTests(t)
    }
}

private func textFieldTests(_ t: Tests, _ font: PSFFont) {
    t.section("TextField")
    let f = TextField(frame: Rect(0, 0, 200, 24))
    type(f, "hello")
    t.equal(f.text, "hello", "typing inserts")
    t.check(f.cursor == 5 && !f.hasSelection, "cursor at end")
    _ = f.key(key(WinKey.left))
    _ = f.key(key(WinKey.left))
    type(f, "XY")
    t.equal(f.text, "helXYlo", "insert in the middle")
    _ = f.key(key(GUIKeyEvent.backspace))
    t.equal(f.text, "helXlo", "backspace")
    _ = f.key(key(WinKey.delete))
    t.equal(f.text, "helXo", "delete")
    _ = f.key(key(WinKey.home))
    t.check(f.cursor == 0, "home")
    _ = f.key(key(GUIKeyEvent.backspace))
    t.equal(f.text, "helXo", "backspace at start does nothing")
    _ = f.key(key(WinKey.end))
    _ = f.key(key(WinKey.delete))
    t.equal(f.text, "helXo", "delete at end does nothing")
    // Selection.
    _ = f.key(key(WinKey.left, shift: true))
    _ = f.key(key(WinKey.left, shift: true))
    t.equal(f.selectedText, "Xo", "shift-left selects")
    type(f, "!")
    t.equal(f.text, "hel!", "typing replaces the selection")
    _ = f.key(key(0x01, ctrl: true))
    t.equal(f.selectedText, "hel!", "ctrl-a selects all")
    _ = f.key(key(0x03, ctrl: true))
    t.equal(guiClipboard, "hel!", "ctrl-c copies")
    _ = f.key(key(WinKey.left))
    t.check(f.cursor == 0 && !f.hasSelection, "left collapses a selection to its start")
    _ = f.key(key(WinKey.end))
    _ = f.key(key(0x16, ctrl: true))
    t.equal(f.text, "hel!hel!", "ctrl-v pastes")
    _ = f.key(key(WinKey.home, shift: true))
    _ = f.key(key(0x18, ctrl: true))
    t.check(f.text == "" && guiClipboard == "hel!hel!", "ctrl-x cuts")
    // Words and kills.
    f.text = "one two  three"
    _ = f.key(key(WinKey.left, ctrl: true))
    t.check(f.cursor == 9, "ctrl-left jumps a word")
    _ = f.key(key(0x17, ctrl: true))
    t.equal(f.text, "one three", "ctrl-w deletes the previous word")
    _ = f.key(key(0x15, ctrl: true))
    t.equal(f.text, "three", "ctrl-u deletes to the start")
    _ = f.key(key(WinKey.home))
    _ = f.key(key(0x0B, ctrl: true))
    t.equal(f.text, "", "ctrl-k deletes to the end")
    // Callbacks, limits, keys it must not eat.
    var submitted = ""
    var changes = 0
    f.onSubmit = { submitted = $0 }
    f.onChange = { _ in changes += 1 }
    type(f, "go")
    t.check(f.key(key(GUIKeyEvent.enter)) && submitted == "go" && changes == 2, "enter submits; onChange per edit")
    t.check(!f.key(key(GUIKeyEvent.tab)), "tab is not used")
    t.check(!f.key(key(GUIKeyEvent.escape)), "escape without onCancel is not used")
    f.maxLength = 4
    f.text = "abcdefgh"
    t.equal(f.text, "abcd", "maxLength truncates a set text")
    type(f, "z")
    t.equal(f.text, "abcd", "maxLength stops typing")
    f.readOnly = true
    _ = f.key(key(GUIKeyEvent.backspace))
    t.equal(f.text, "abcd", "readOnly ignores edits")
    f.readOnly = false
    f.maxLength = 4096
    // Hit testing and scrolling.
    f.text = "0123456789"
    t.equal(f.index(at: Point(TextField.padding + 3 * 8 + 1, 5)), 3, "click maps to a character boundary")
    t.equal(f.index(at: Point(-50, 5)), 0, "click left of the text")
    t.equal(f.index(at: Point(500, 5)), 10, "click right of the text")
    let narrow = TextField(frame: Rect(0, 0, 60, 24))
    narrow.text = "the quick brown fox"
    t.check(narrow.scrollX > 0 && narrow.cursor * 8 - narrow.scrollX < narrow.innerWidth, "caret stays visible when typing past the end")
    _ = narrow.key(key(WinKey.home))
    t.equal(narrow.scrollX, 0, "home scrolls back")
    // Drag selects.
    narrow.mouseDown(Point(TextField.padding, 5))
    narrow.mouseMove(Point(TextField.padding + 24, 5), buttons: 1)
    narrow.mouseUp(Point(TextField.padding + 24, 5))
    t.equal(narrow.selectedText, "the", "dragging selects")
    // Drawing never crashes and puts ink in the field.
    let s = Surface(width: 200, height: 24, color: 0)
    let th = GUITheme(font: font)
    f.hasFocus = true
    f.text = "Hi"
    f.draw(s, th)
    var ink = 0
    for y in 0..<24 { for x in 0..<200 where s.pixel(x, y) == th.text { ink += 1 } }
    t.check(ink > 10, "text is drawn")
    t.check(s.pixel(100, 12) == th.fieldBackground, "field background")
    // Fuzz: random keys never crash and keep invariants.
    var rng = TestRandom(seed: 7)
    let g = TextField(frame: Rect(0, 0, 80, 24))
    g.maxLength = 50
    for _ in 0..<5000 {
        let codes = [0x20 + rng.below(90), WinKey.left, WinKey.right, WinKey.home, WinKey.end, WinKey.delete,
                     GUIKeyEvent.backspace, 0x1F & Int(UInt8(0x61 + rng.below(26)))]
        _ = g.key(GUIKeyEvent(code: codes[rng.below(codes.count)], ctrl: rng.below(4) == 0, shift: rng.below(3) == 0))
        if g.cursor < 0 || g.cursor > g.count || g.count > 50 || g.scrollX < 0 {
            t.check(false, "invariants hold under random keys")
            return
        }
    }
    t.check(true, "invariants hold under random keys")
}

private func buttonTests(_ t: Tests, _ font: PSFFont) {
    t.section("Button")
    let b = Button("OK", frame: Rect(10, 10, 60, 24))
    var clicks = 0
    b.onClick = { clicks += 1 }
    b.mouseDown(Point(20, 20))
    b.mouseUp(Point(20, 20))
    t.equal(clicks, 1, "press and release inside clicks")
    b.mouseDown(Point(20, 20))
    b.mouseMove(Point(200, 200), buttons: 1)
    b.mouseUp(Point(200, 200))
    t.equal(clicks, 1, "release outside does not click")
    b.mouseDown(Point(20, 20))
    b.mouseMove(Point(200, 200), buttons: 1)
    b.mouseMove(Point(20, 20), buttons: 1)
    b.mouseUp(Point(20, 20))
    t.equal(clicks, 2, "dragging out and back in clicks")
    t.check(b.key(key(GUIKeyEvent.enter)) && b.key(key(0x20)) && clicks == 4, "enter and space click")
    let th = GUITheme(font: font)
    let s = Surface(width: 80, height: 40, color: 0)
    b.draw(s, th)
    t.check(s.pixel(40, 22) != 0 || s.pixel(15, 12) == th.buttonFace, "button face drawn")
    t.check(s.pixel(10, 10) == th.buttonBorder, "button border drawn")
}

private func scrollTests(_ t: Tests, _ font: PSFFont) {
    t.section("ScrollView")
    let v = ScrollView(frame: Rect(0, 0, 100, 100), contentWidth: 80, contentHeight: 400)
    t.check(v.needsVertical && !v.needsHorizontal, "vertical bar only")
    t.equal(v.maxScrollY, 300, "max scroll")
    v.scrollTo(x: 0, y: 1000)
    t.equal(v.scrollY, 300, "clamped")
    v.scrollTo(x: 0, y: 0)
    var scrolls = 0
    v.onScroll = { scrolls += 1 }
    _ = v.key(key(WinKey.pageDown))
    t.check(v.scrollY == 100 && scrolls == 1, "page down")
    _ = v.key(key(WinKey.end))
    t.equal(v.scrollY, 300, "end")
    v.mouseWheel(Point(5, 5), delta: 1)
    t.equal(v.scrollY, 300 - 48, "wheel up scrolls up")
    v.scrollTo(x: 0, y: 0)
    v.ensureVisible(Rect(0, 380, 10, 10))
    t.equal(v.scrollY, 290, "ensureVisible scrolls just enough")
    // Thumb dragging.
    v.scrollTo(x: 0, y: 0)
    let th = v.verticalThumb
    v.mouseDown(Point(th.x + 2, th.y + 2))
    v.mouseMove(Point(th.x + 2, th.y + 2 + 20), buttons: 1)
    v.mouseUp(Point(th.x + 2, th.y + 22))
    t.check(v.scrollY > 0, "dragging the thumb scrolls")
    // Content drawing gets the right origin.
    var origin = Point.zero
    v.drawContent = { _, _, o in origin = o }
    v.scrollTo(x: 0, y: 40)
    let s = Surface(width: 100, height: 100, color: 0)
    v.draw(s, GUITheme(font: font))
    t.check(origin == Point(0, -40), "content origin is offset by the scroll")
    // Shrinking the frame re-clamps.
    v.scrollTo(x: 0, y: 300)
    v.frame = Rect(0, 0, 100, 350)
    t.equal(v.scrollY, 50, "resize clamps the scroll")
    let h = ScrollView(frame: Rect(0, 0, 100, 100), contentWidth: 300, contentHeight: 300)
    t.check(h.needsVertical && h.needsHorizontal && h.viewport == Rect(0, 0, 88, 88), "both bars shrink the viewport")
}

private func containerTests(_ t: Tests, _ font: PSFFont) {
    t.section("Container")
    let c = Container(theme: GUITheme(font: font))
    var clicked = 0
    let b = c.button("Go", frame: Rect(10, 10, 60, 24)) { clicked += 1 }
    let f = c.textField(frame: Rect(10, 50, 120, 24))
    let l = c.label("hi", x: 10, y: 90)
    let s = Surface(width: 200, height: 120, color: 0)
    var d = c.render(into: s)
    t.check(!d.isEmpty && s.pixel(10, 10) == c.theme.buttonBorder, "first render paints the widgets")
    d = c.render(into: s)
    t.check(d.isEmpty, "nothing dirty, nothing damaged")
    // Mouse: click the button.
    c.handle(.mouse(x: 20, y: 20, buttons: 1, wheel: 0))
    t.check(c.focused === b, "press focuses the button")
    c.handle(.mouse(x: 20, y: 20, buttons: 0, wheel: 0))
    t.equal(clicked, 1, "click through the container")
    d = c.render(into: s)
    t.check(d.intersects(b.frame) && !d.intersects(f.frame), "only the button repainted")
    // Tab cycles, keys go to the focused widget.
    c.handle(.key(key(GUIKeyEvent.tab)))
    t.check(c.focused === f, "tab moves to the field")
    c.handle(.key(key(0x41)))
    t.equal(f.text, "A", "keys reach the focused field")
    c.handle(.key(key(GUIKeyEvent.tab, shift: true)))
    t.check(c.focused === b, "shift-tab goes back")
    c.handle(.mouse(x: 30, y: 60, buttons: 1, wheel: 0))
    c.handle(.mouse(x: 30, y: 60, buttons: 0, wheel: 0))
    t.check(c.focused === f, "clicking the field focuses it")
    c.handle(.mouse(x: 190, y: 110, buttons: 1, wheel: 0))
    t.check(c.focused == nil, "clicking nothing drops the focus")
    c.handle(.mouse(x: 190, y: 110, buttons: 0, wheel: 0))
    // Hide, move: the old area is repainted with the background.
    _ = c.render(into: s)
    l.visible = false
    d = c.render(into: s)
    t.check(d.intersects(Rect(10, 90, 16, 16)) && s.pixel(12, 98) == c.theme.background, "hiding repaints the background")
    b.frame = Rect(100, 10, 60, 24)
    d = c.render(into: s)
    t.check(d.intersects(Rect(10, 10, 60, 24)) && d.intersects(Rect(100, 10, 60, 24)), "moving damages old and new")
    t.check(s.pixel(12, 12) == c.theme.background, "old spot cleared")
    // A widget hidden and then a full repaint (App.paintAll: the app paints
    // its page, invalidateAll, render): the page must survive under the
    // hidden widget's old area.
    let pf = c.textField(frame: Rect(140, 40, 50, 24))
    _ = c.render(into: s)
    pf.visible = false
    c.invalidateAll()
    s.fill(Rect(0, 0, 200, 120), 0x123456)  // the app's page
    _ = c.render(into: s)
    t.check(s.pixel(150, 50) == 0x123456, "a hidden widget leaves the page alone on a full repaint")
    pf.visible = true
    _ = c.render(into: s)
    pf.visible = false
    s.fill(Rect(0, 0, 200, 120), 0x654321)
    c.invalidateAll()
    _ = c.render(into: s)
    t.check(s.pixel(150, 50) == 0x654321, "hidden since the last render: still no gray block")
    // Overlap: a widget under a dirty one repaints too.
    let top = c.label("TOP", x: 100, y: 10, width: 40)
    _ = c.render(into: s)
    b.invalidate()
    _ = c.render(into: s)
    t.check(!top.needsDraw, "overlapping widget redrawn in the same pass")
    // Blink.
    f.hasFocus = true
    t.check(c.nextTick(1000) != nil, "a focused field wants a tick")
    c.remove(f)
    t.check(c.focused == nil || c.focused !== f, "removed widget is not focused")
}

private func decodeTests(_ t: Tests) {
    t.section("events")
    let e = WinEvent(kind: WinEventKind.key, mods: WinMod.ctrl | WinMod.shift, a: Int32(WinKey.left), b: 0, c: 0)
    if case .key(let k)? = guiDecode(e) {
        t.check(k.code == WinKey.left && k.ctrl && k.shift && !k.alt && k.character == nil, "key decode")
    } else { t.check(false, "key decode") }
    t.check(GUIKeyEvent(code: 0x41).character == 0x41 && GUIKeyEvent(code: 0x41, ctrl: true).character == nil, "character")
    t.check(guiDecode(WinEvent(kind: 99, mods: 0, a: 0, b: 0, c: 0)) == nil, "unknown kind")
    let raw: [UInt8] = [2, 0, 1, 0, 10, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 1, 0, 0, 0, 5, 0, 0, 0]
    let recs = guiDecodeRecords(raw)
    t.check(recs.count == 1 && guiDecode(recs[0]) == .mouse(x: 10, y: -1, buttons: 1, wheel: 1), "record bytes decode (partial tail ignored)")
    t.equal(MemoryLayout<WinEvent>.size, 16, "WinEvent is 16 bytes")
    t.equal(MemoryLayout<WinInfo>.size, 24, "WinInfo is 24 bytes")
}
