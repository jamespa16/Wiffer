// Phase K1: windows.
//
// A Window *is* a compositor Layer (in the windows band): its frame is the
// outer frame, decorations included. The WM draws the decorations
// procedurally in draw(into:clip:) (border, title bar with the title and a
// close box, a resize grip), straight into the back buffer while
// compositing, and blits the app's `content` surface into the content area.
// So there is no separate frame layer or frame surface: the app only ever
// owns a content-sized Surface, and a focus change is just a damage of the
// frame.
//
// Apps subclass Window and override:
//   - handle(_:)  events from the WM: .key (when focused), .mouse in
//                 content-local coordinates, .focus(Bool), .resize(w, h)
//                 (content size; `content` is already the new surface),
//                 .close (default: forwarded to `task`).
//   - draw()      repaint `content`; called by the WM before compositing when
//                 needsDraw() (default: `dirty`). Call invalidate(_:) for what
//                 changed so it reaches the screen. Should not allocate (it
//                 runs inside consoleFlush, also on the exception path).
//   - close()     the user asked to close (close box, Alt-F4): return true to
//                 let the WM remove the window, false to keep it (e.g. "save
//                 changes?"); call WindowManager.remove(_:) later yourself.
//
// No back references: a window doesn't know its WM or compositor (Embedded
// Swift has no `weak`, and the compositor already holds the window as a
// layer). Damage goes through `pendingDamage`, which the WM collects.

/// Decoration colours (in the target surface's pixel format) and the font
/// for titles. Set on a window by WindowManager.add.
struct WindowTheme {
    var font: PSFFont
    var borderFocused: UInt32
    var borderUnfocused: UInt32
    var titleFocused: UInt32
    var titleUnfocused: UInt32
    var titleTextFocused: UInt32
    var titleTextUnfocused: UInt32
    var closeFocused: UInt32
    var closeUnfocused: UInt32
    var closeInk: UInt32
    var contentBG: UInt32
    var grip: UInt32
    // Taskbar.
    var taskbarBG: UInt32
    var taskbarText: UInt32
    var buttonBG: UInt32
    var buttonFocusedBG: UInt32
    var buttonText: UInt32
    var launcherBG: UInt32
    // Placeholder apps.
    var appBG: UInt32
    var appInk: UInt32
    var appMarker: UInt32

    /// 0xRRGGBB values; `convert` maps them into the pixel format.
    static let rgb = (
        borderFocused: UInt32(0x55FFFF), borderUnfocused: UInt32(0x606060),
        titleFocused: UInt32(0x1E5AA8), titleUnfocused: UInt32(0x3C3C3C),
        titleTextFocused: UInt32(0xFFFFFF), titleTextUnfocused: UInt32(0xA0A0A0),
        closeFocused: UInt32(0xD03030), closeUnfocused: UInt32(0x707070), closeInk: UInt32(0xFFFFFF),
        contentBG: UInt32(0x000000), grip: UInt32(0x55FFFF),
        taskbarBG: UInt32(0x202830), taskbarText: UInt32(0xD0D0D0),
        buttonBG: UInt32(0x384858), buttonFocusedBG: UInt32(0x1E5AA8), buttonText: UInt32(0xFFFFFF),
        launcherBG: UInt32(0x2E7D32),
        appBG: UInt32(0x203040), appInk: UInt32(0xFFFFFF), appMarker: UInt32(0xFFFF00)
    )

    init(font: PSFFont, convert: (UInt32) -> UInt32 = { $0 }) {
        let c = WindowTheme.rgb
        self.font = font
        borderFocused = convert(c.borderFocused)
        borderUnfocused = convert(c.borderUnfocused)
        titleFocused = convert(c.titleFocused)
        titleUnfocused = convert(c.titleUnfocused)
        titleTextFocused = convert(c.titleTextFocused)
        titleTextUnfocused = convert(c.titleTextUnfocused)
        closeFocused = convert(c.closeFocused)
        closeUnfocused = convert(c.closeUnfocused)
        closeInk = convert(c.closeInk)
        contentBG = convert(c.contentBG)
        grip = convert(c.grip)
        taskbarBG = convert(c.taskbarBG)
        taskbarText = convert(c.taskbarText)
        buttonBG = convert(c.buttonBG)
        buttonFocusedBG = convert(c.buttonFocusedBG)
        buttonText = convert(c.buttonText)
        launcherBG = convert(c.launcherBG)
        appBG = convert(c.appBG)
        appInk = convert(c.appInk)
        appMarker = convert(c.appMarker)
    }
}

/// What part of a window a point is over (WindowManager.hitTest).
enum WindowPart: Equatable {
    case title
    case close
    /// The bottom-right resize grip.
    case resize
    /// The border elsewhere (focuses, nothing more).
    case border
    case content
}

class Window: Layer {
    /// Decoration metrics (pixels).
    static let border = 2
    static let titleHeight = 20
    static let closeSize = 14
    /// The resize grip: this many pixels square at the bottom-right corner.
    static let gripSize = 12

    /// Assigned by WindowManager.add (0 until then).
    var id = 0
    var title: String {
        didSet { chromeDirty = true }
    }
    /// The app's pixels, exactly the content area's size. Replaced by the WM
    /// on resize (the old pixels are copied into the top-left of the new one).
    var content: Surface
    /// The task running this window's app, if any. The default handle(_:)
    /// forwards keys and .close to it. Dropped by WindowManager.remove.
    var task: Task?
    /// Set by the WM.
    var focused = false
    /// Needs draw() before the next composite.
    var dirty = true
    var closable = true
    var resizable = true
    /// Smallest content size a resize may make.
    var minContentWidth = 96
    var minContentHeight = 32
    /// Content-local area changed since the WM last looked (invalidate).
    var pendingDamage = Rect.empty
    /// Title or focus changed: the WM repaints the decorations.
    var chromeDirty = false
    var theme: WindowTheme?

    /// A window whose content area is `contentWidth` x `contentHeight`, with
    /// its outer frame's top-left at `origin` (WindowManager.add may place
    /// it instead).
    init(title: String, contentWidth: Int, contentHeight: Int, at origin: Point = .zero, task: Task? = nil) {
        self.title = title
        self.task = task
        content = Surface(width: max(contentWidth, 1), height: max(contentHeight, 1))
        let size = Window.frameSize(contentWidth: content.width, contentHeight: content.height)
        super.init(frame: Rect(origin: origin, w: size.w, h: size.h), band: .windows, opaque: true)
    }

    // MARK: Geometry

    static func frameSize(contentWidth: Int, contentHeight: Int) -> (w: Int, h: Int) {
        (contentWidth + 2 * border, contentHeight + 2 * border + titleHeight)
    }

    static func contentSize(frameWidth: Int, frameHeight: Int) -> (w: Int, h: Int) {
        (frameWidth - 2 * border, frameHeight - 2 * border - titleHeight)
    }

    /// The content area in screen coordinates.
    var contentRect: Rect {
        Rect(frame.x + Window.border, frame.y + Window.border + Window.titleHeight, content.width, content.height)
    }

    /// The title bar (inside the border) in screen coordinates.
    var titleRect: Rect {
        Rect(frame.x + Window.border, frame.y + Window.border, frame.w - 2 * Window.border, Window.titleHeight)
    }

    var closeRect: Rect {
        let t = titleRect, s = Window.closeSize
        return Rect(t.maxX - s - 3, t.y + (t.h - s) / 2, s, s)
    }

    var gripRect: Rect {
        Rect(frame.maxX - Window.gripSize, frame.maxY - Window.gripSize, Window.gripSize, Window.gripSize)
    }

    /// Which part of the window `p` (screen coordinates) is over, or nil if
    /// it's outside the frame.
    func part(at p: Point) -> WindowPart? {
        guard frame.contains(p) else { return nil }
        if closable && closeRect.contains(p) { return .close }
        if resizable && gripRect.contains(p) { return .resize }
        if titleRect.contains(p) { return .title }
        if contentRect.contains(p) { return .content }
        return .border
    }

    /// Screen point -> content-local point.
    func local(_ p: Point) -> Point {
        let c = contentRect
        return Point(p.x - c.x, p.y - c.y)
    }

    // MARK: For subclasses

    /// Event from the WM. Default: keys and .close go to `task`.
    func handle(_ event: Event) {
        guard let task else { return }
        switch event {
        case .key, .close: task.post(event)
        default: break
        }
    }

    /// Repaint `content` (and invalidate what changed). Default: nothing.
    func draw() {}

    /// Does draw() need calling? Default: `dirty`.
    func needsDraw() -> Bool { dirty }

    /// The user asked to close the window. Return true to let the WM remove
    /// it. Default: tell the task (.close) and agree.
    func close() -> Bool {
        handle(.close)
        return true
    }

    /// Mark a content-local rect (nil: all of it) for the screen.
    func invalidate(_ r: Rect? = nil) {
        pendingDamage = pendingDamage.union((r ?? content.bounds).intersection(content.bounds))
    }

    /// Mark the window for draw() before the next composite.
    func setNeedsDraw() { dirty = true }

    // MARK: Compositing (the WM's decorations)

    /// Paint the decorations and content inside `clip`. Never allocates.
    override func draw(into s: Surface, clip: Rect) {
        let c = contentRect
        let inner = c.intersection(clip)
        if !inner.isEmpty {
            s.blit(from: content, src: inner.offsetBy(dx: -c.x, dy: -c.y), to: inner.origin)
        }
        if c.contains(clip) && !(resizable && gripRect.intersects(clip)) { return }
        guard let th = theme else {
            // Not themed yet: plain grey decorations.
            s.withClip(clip) { s.fill(frame, 0x808080) }
            s.blit(from: content, src: inner.offsetBy(dx: -c.x, dy: -c.y), to: inner.origin)
            return
        }
        let f = focused
        // Border: two 1-px outlines.
        let borderColor = f ? th.borderFocused : th.borderUnfocused
        s.frame(frame, borderColor)
        s.frame(Rect(frame.x + 1, frame.y + 1, frame.w - 2, frame.h - 2), borderColor)
        // Title bar and title text (clipped short of the close box).
        let t = titleRect
        s.fill(t, f ? th.titleFocused : th.titleUnfocused)
        let textClip = Rect(t.x + 4, t.y, (closable ? closeRect.x - 4 : t.maxX - 4) - (t.x + 4), t.h)
        s.withClip(textClip) {
            s.drawText(title, font: th.font, at: Point(t.x + 6, t.y + (t.h - th.font.height) / 2),
                       fg: f ? th.titleTextFocused : th.titleTextUnfocused, bg: nil)
        }
        if closable {
            let b = closeRect
            s.fill(b, f ? th.closeFocused : th.closeUnfocused)
            // A 2-px wide X, 3 px in from the box's edges.
            let n = b.w - 6
            for i in 0..<n {
                s.fill(Rect(b.x + 3 + i, b.y + 3 + i, 2, 1), th.closeInk)
                s.fill(Rect(b.maxX - 5 - i, b.y + 3 + i, 2, 1), th.closeInk)
            }
        }
        if resizable {
            // Three short diagonal strokes over the content's corner.
            let g = gripRect
            for k in 0..<3 {
                let off = 3 + k * 3
                for i in 0..<off {
                    s.plot(g.maxX - 3 - i, g.maxY - 3 - off + i + 1, th.grip)
                }
            }
        }
    }
}
