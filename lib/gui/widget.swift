// Widgets and the container that routes events to them (lib/gui).
//
// Positions are window coordinates (the buffer's pixels); there is no layout
// engine: set `frame`s. A widget redraws only when `needsDraw` is set (every
// state change does that itself). Container.render() paints the dirty ones
// and returns the damaged rect for win_present.
//
// Mouse: a press goes to the topmost visible, enabled widget under the
// pointer, which also takes the keyboard focus if it is focusable and keeps
// the pointer (capture) until the buttons are released. Keys go to the
// focused widget; Tab and Shift-Tab move the focus when it doesn't use them.

class Widget {
    var frame: Rect {
        didSet { if frame != oldValue { stale = stale.union(oldValue); needsDraw = true } }
    }
    var visible = true {
        didSet { if visible != oldValue { stale = stale.union(frame); needsDraw = true } }
    }
    var enabled = true {
        didSet { if enabled != oldValue { needsDraw = true } }
    }
    /// Set by the container.
    var hasFocus = false {
        didSet { if hasFocus != oldValue { needsDraw = true; focusChanged() } }
    }
    var hover = false {
        didSet { if hover != oldValue { needsDraw = true } }
    }
    var needsDraw = true
    /// Where the widget used to be (to repaint the background there).
    var stale = Rect.empty

    init(frame: Rect) { self.frame = frame }

    var focusable: Bool { false }

    func invalidate() { needsDraw = true }

    /// Paint into `s` (its clip is the frame). The background was cleared.
    func draw(_ s: Surface, _ theme: GUITheme) {}

    /// Left button pressed at `p` (window coordinates).
    func mouseDown(_ p: Point) {}
    /// The pointer moved (while captured: possibly outside the frame).
    func mouseMove(_ p: Point, buttons: Int) {}
    func mouseUp(_ p: Point) {}
    func mouseWheel(_ p: Point, delta: Int) {}
    /// A key while focused. True if used.
    func key(_ k: GUIKeyEvent) -> Bool { false }
    func focusChanged() {}
    /// Time passes (`now` in ms). Called when `nextTick` says so.
    func tick(_ now: Int) {}
    /// Milliseconds until this widget wants `tick`, or nil.
    func nextTick(_ now: Int) -> Int? { nil }
}

final class Container {
    var theme: GUITheme
    private(set) var widgets: [Widget] = []
    private(set) var focused: Widget?
    private var captured: Widget?
    private var lastButtons = 0

    init(theme: GUITheme) { self.theme = theme }

    @discardableResult
    func add<W: Widget>(_ w: W) -> W {
        widgets.append(w)
        w.needsDraw = true
        return w
    }

    func remove(_ w: Widget) {
        guard let i = widgets.firstIndex(where: { $0 === w }) else { return }
        widgets.remove(at: i)
        stale = stale.union(w.frame).union(w.stale)
        if focused === w { focused = nil }
        if captured === w { captured = nil }
    }

    /// Areas of removed widgets still to repaint.
    private var stale = Rect.empty

    // MARK: Convenience constructors

    @discardableResult
    func label(_ text: String, x: Int, y: Int, width: Int? = nil) -> Label {
        let w = width ?? theme.font.textWidth(text)
        return add(Label(text, frame: Rect(x, y, w, theme.font.height)))
    }

    @discardableResult
    func button(_ title: String, frame: Rect, onClick: @escaping () -> Void) -> Button {
        let b = add(Button(title, frame: frame))
        b.onClick = onClick
        return b
    }

    @discardableResult
    func textField(frame: Rect, text: String = "") -> TextField {
        let f = add(TextField(frame: frame))
        f.text = text
        return f
    }

    // MARK: Focus

    func setFocus(_ w: Widget?) {
        guard focused !== w else { return }
        focused?.hasFocus = false
        focused = w
        w?.hasFocus = true
    }

    /// Tab order is the order widgets were added.
    func focusNext(reverse: Bool = false) {
        var order: [Widget] = []
        for w in widgets where w.focusable && w.visible && w.enabled { order.append(w) }
        guard !order.isEmpty else { return }
        var i = order.firstIndex(where: { $0 === focused }) ?? (reverse ? 0 : -1)
        i = reverse ? (i - 1 + order.count) % order.count : (i + 1) % order.count
        setFocus(order[i])
    }

    /// The window lost or gained the keyboard: carets stop blinking, etc.
    func windowFocus(_ on: Bool) {
        if !on { captured = nil; lastButtons = 0 }
        focused?.hasFocus = on
    }

    // MARK: Events

    func topmost(at p: Point) -> Widget? {
        var i = widgets.count - 1
        while i >= 0 {
            let w = widgets[i]
            if w.visible && w.enabled && w.frame.contains(p) { return w }
            i -= 1
        }
        return nil
    }

    func handle(_ event: GUIEvent) {
        switch event {
        case .key(let k): handleKey(k)
        case .mouse(let x, let y, let buttons, let wheel): handleMouse(Point(x, y), buttons: buttons, wheel: wheel)
        case .focus(let on): windowFocus(on)
        case .resize, .close: break
        }
    }

    func handleKey(_ k: GUIKeyEvent) {
        if let f = focused, f.enabled, f.key(k) { return }
        if k.code == GUIKeyEvent.tab && !k.ctrl && !k.alt { focusNext(reverse: k.shift) }
    }

    func handleMouse(_ p: Point, buttons: Int, wheel: Int) {
        let was = lastButtons & Int(WinButton.left) != 0
        let now = buttons & Int(WinButton.left) != 0
        lastButtons = buttons
        let under = captured ?? topmost(at: p)
        for w in widgets { w.hover = w === under && (captured == nil || w.frame.contains(p)) }
        if wheel != 0, let w = captured ?? topmost(at: p) { w.mouseWheel(p, delta: wheel) }
        if now && !was {
            guard let w = topmost(at: p) else { setFocus(nil); return }
            if w.focusable { setFocus(w) }
            captured = w
            w.mouseDown(p)
        } else if now {
            captured?.mouseMove(p, buttons: buttons)
        } else if was {
            if let w = captured { w.mouseUp(p) }
            captured = nil
            for w in widgets { w.hover = w === topmost(at: p) }
        } else {
            topmost(at: p)?.mouseMove(p, buttons: buttons)
        }
    }

    // MARK: Time

    func tick(_ now: Int) {
        for w in widgets {
            if let d = w.nextTick(now), d <= 0 { w.tick(now) }
        }
    }

    /// Shortest delay any widget wants (ms), or nil.
    func nextTick(_ now: Int) -> Int? {
        var best: Int? = nil
        for w in widgets {
            if let d = w.nextTick(now) { best = best.map { min($0, d) } ?? d }
        }
        return best
    }

    // MARK: Drawing

    /// Everything repaints, over a freshly painted background: leftover
    /// stale areas (a widget hidden since the last render) must not clear
    /// what the app has just painted there.
    func invalidateAll() {
        stale = .empty
        for w in widgets { w.stale = .empty; w.needsDraw = true }
    }

    /// Paint dirty widgets (and what overlaps them) into `s`; the damaged
    /// rect, or .empty if nothing changed.
    @discardableResult
    func render(into s: Surface) -> Rect {
        var damage = Rect.empty
        // Anything overlapping a dirty widget above it must repaint too.
        var changed = true
        while changed {
            changed = false
            for (i, w) in widgets.enumerated() where w.needsDraw || !w.stale.isEmpty {
                let area = w.frame.union(w.stale)
                for j in widgets.indices where j != i && !widgets[j].needsDraw && widgets[j].frame.intersects(area) {
                    widgets[j].needsDraw = true
                    changed = true
                }
            }
        }
        var clearAreas: [Rect] = []
        if !stale.isEmpty { clearAreas.append(stale.intersection(s.bounds)); stale = .empty }
        for w in widgets where w.needsDraw {
            clearAreas.append((w.visible ? w.frame : .empty).union(w.stale))
            w.stale = .empty
        }
        for a in clearAreas where !a.isEmpty {
            s.fill(a.intersection(s.bounds), theme.background)
            damage = damage.union(a.intersection(s.bounds))
        }
        for w in widgets where w.needsDraw {
            w.needsDraw = false
            guard w.visible else { continue }
            s.withClip(w.frame) { w.draw(s, theme) }
        }
        return damage
    }
}

// MARK: Label

enum GUIAlignment { case left, center, right }

final class Label: Widget {
    var text: String {
        didSet { if text != oldValue { needsDraw = true } }
    }
    /// nil: the theme's text colour.
    var color: UInt32? {
        didSet { needsDraw = true }
    }
    var background: UInt32? {
        didSet { needsDraw = true }
    }
    var alignment = GUIAlignment.left {
        didSet { needsDraw = true }
    }

    init(_ text: String, frame: Rect) {
        self.text = text
        super.init(frame: frame)
    }

    override func draw(_ s: Surface, _ theme: GUITheme) {
        if let background { s.fill(frame, background) }
        let tw = theme.font.textWidth(text)
        var x = frame.x
        switch alignment {
        case .left: break
        case .center: x += (frame.w - tw) / 2
        case .right: x += frame.w - tw
        }
        let y = frame.y + (frame.h - theme.font.height) / 2
        s.drawText(text, font: theme.font, at: Point(x, y), fg: enabled ? (color ?? theme.text) : theme.disabledText,
                   bg: nil)
    }
}

// MARK: Button

final class Button: Widget {
    var title: String {
        didSet { if title != oldValue { needsDraw = true } }
    }
    var onClick: (() -> Void)?
    private(set) var pressed = false

    init(_ title: String, frame: Rect) {
        self.title = title
        super.init(frame: frame)
    }

    override var focusable: Bool { true }

    func click() { onClick?() }

    override func mouseDown(_ p: Point) {
        pressed = true
        needsDraw = true
    }

    override func mouseMove(_ p: Point, buttons: Int) {
        let inside = frame.contains(p)
        if pressed != (inside && buttons & Int(WinButton.left) != 0) {
            pressed = inside && buttons & Int(WinButton.left) != 0
            needsDraw = true
        }
    }

    override func mouseUp(_ p: Point) {
        let fire = pressed && frame.contains(p)
        pressed = false
        needsDraw = true
        if fire { click() }
    }

    override func key(_ k: GUIKeyEvent) -> Bool {
        if !k.ctrl && !k.alt && (k.code == GUIKeyEvent.enter || k.code == 0x20) {
            click()
            return true
        }
        return false
    }

    override func draw(_ s: Surface, _ theme: GUITheme) {
        let face = !enabled ? theme.buttonFace : pressed ? theme.buttonPressed : hover ? theme.buttonHover : theme.buttonFace
        s.fill(frame, face)
        s.frame(frame, hasFocus ? theme.focusBorder : theme.buttonBorder)
        if hasFocus { s.frame(Rect(frame.x + 1, frame.y + 1, frame.w - 2, frame.h - 2), theme.focusBorder) }
        let r = pressed ? frame.offsetBy(dx: 1, dy: 1) : frame
        s.drawTextCentered(title, font: theme.font, in: r, fg: enabled ? theme.text : theme.disabledText)
    }
}
