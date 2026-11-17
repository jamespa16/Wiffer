// Phase K2/K3: the window manager.
//
// - Z-order: `windows` is bottom to top and mirrors the compositor's windows
//   band (every Window is a Layer, see window.swift).
// - Focus: clicking a window (or its taskbar button) raises and focuses it.
//   Keys go to the focused window, except the WM's shortcuts: Alt-Tab (cycle:
//   the bottom window comes to the top, so repeated presses visit them all),
//   Alt-F4 (close the focused window), Super+Enter or Ctrl-Alt-T (the
//   openTerminal hook). Keys from serial go to `serialTarget` if set (the
//   boot console's shell, whose output is what serial shows), so the serial
//   line stays a working debug console whatever has focus.
// - Mouse: the left button on the title bar drags (moves) the window, on the
//   bottom-right grip resizes it, on the close box closes it. In the content
//   area, mouse events go to the window in content-local coordinates; a
//   press there captures the pointer until every button is released.
// - Geometry: a window's title bar always stays reachable (at least
//   `minVisible` px of it on screen horizontally, all of it vertically, above
//   the taskbar); resizing enforces the window's minimum content size and
//   allocates a fresh content surface (old pixels copied in), then sends
//   .resize.
// - render(), called by Display.flush just before compositing, runs each
//   window's draw() if needed and turns its pendingDamage (and decoration
//   changes) into compositor damage. It never allocates.
//
// Boot: Part 2's full-screen shell is unchanged until the `desktop` command
// (startDesktop) switches the screen to the WM. The existing console then
// becomes the first window (ConsoleWindow, still fed by putc and still read
// by the same shell task), the main loop's router hands every event to
// windowManager.route, and Display.flush composites through render(). Phase L
// boots straight into it by calling startDesktop() unless `nodesktop` is on
// the kernel command line, and replaces the `openTerminal` hook.

/// The live WM (nil until `desktop`).
var windowManager: WindowManager? = nil

final class WindowManager {
    let compositor: Compositor
    let theme: WindowTheme
    let screen: Rect
    let taskbar: Taskbar?
    /// The screen minus the taskbar: where windows live.
    let workArea: Rect
    /// Bottom to top.
    private(set) var windows: [Window] = []
    private(set) var focused: Window?
    /// Gets keys that arrive over serial (nil: the focused window).
    var serialTarget: Window?
    /// Print "wm: ..." lines (the harness waits for them).
    var log = false
    private(set) var nextID = 1
    var cascade = 0
    /// Least width of the title bar kept on screen.
    static let minVisible = 48

    /// Launcher hooks (taskbar buttons, Super+Enter / Ctrl-Alt-T, `open`).
    /// Phase L sets openTerminal to open a TerminalWindow; openEditor opens
    /// an untitled EditorWindow (Phase N). They take the WM as a parameter so they
    /// needn't capture it (no retain cycle).
    var openTerminal: (WindowManager) -> Void = { wm in
        wm.add(PlaceholderWindow(title: "Terminal \(wm.nextID)", note: "terminal placeholder (Phase L)"))
    }
    var openEditor: (WindowManager) -> Void = { wm in
        openEditorWindow(wm, path: nil) // an untitled EditorWindow (editor_window.swift)
    }

    // Pointer state.
    enum Grab {
        case none
        /// Dragging the title bar; the grab point relative to the frame.
        case move(Window, dx: Int, dy: Int)
        /// Dragging the grip from `start`, with the content size then.
        case resize(Window, start: Point, width: Int, height: Int)
        /// A press in the content area: the window gets the pointer.
        case content(Window)
        /// A press that did something else (close, taskbar, desktop):
        /// ignore the pointer until release.
        case ignore
    }
    private(set) var grab = Grab.none
    private(set) var pointer = Point.zero
    private(set) var buttons: UInt8 = 0

    init(compositor: Compositor, theme: WindowTheme, taskbar: Bool = true) {
        self.compositor = compositor
        self.theme = theme
        screen = compositor.bounds
        if taskbar && screen.h > Taskbar.height * 4 {
            let tb = Taskbar(screen: screen, theme: theme)
            self.taskbar = tb
            workArea = Rect(screen.x, screen.y, screen.w, screen.h - Taskbar.height)
            compositor.add(tb)
        } else {
            self.taskbar = nil
            workArea = screen
        }
        windows.reserveCapacity(16)
        layoutTaskbar()
    }

    /// Take everything off the compositor and drop every window reference
    /// (tests; a WM is otherwise never torn down).
    func shutdown() {
        while let w = windows.last { remove(w) }
        if let tb = taskbar { tb.clear(); compositor.remove(tb) }
        serialTarget = nil
        grab = .none
    }

    func say(_ text: @autoclosure () -> String) { if log { print("wm: " + text()) } }

    func window(id: Int) -> Window? {
        for w in windows where w.id == id { return w }
        return nil
    }

    func index(of w: Window) -> Int? {
        for i in 0..<windows.count where windows[i] === w { return i }
        return nil
    }

    // MARK: Opening and closing

    /// Show `w` (placed at `origin`, or cascaded if nil), on top, focused
    /// unless `focus` is false.
    func add(_ w: Window, at origin: Point? = nil, focus: Bool = true) {
        guard index(of: w) == nil else { return }
        w.id = nextID
        nextID += 1
        w.theme = theme
        w.focused = false
        // Fit inside the work area.
        let maxContent = Window.contentSize(frameWidth: workArea.w, frameHeight: workArea.h)
        if w.content.width > maxContent.w || w.content.height > maxContent.h {
            setContentSize(w, min(w.content.width, maxContent.w), min(w.content.height, maxContent.h), notify: false)
        }
        var p = origin ?? Point(workArea.x + 32 + 32 * (cascade % 8), workArea.y + 24 + 28 * (cascade % 8))
        if origin == nil { cascade += 1 }
        p = clampedOrigin(w, p)
        compositor.setFrame(w, Rect(origin: p, w: w.frame.w, h: w.frame.h))
        w.dirty = true
        w.invalidate()
        windows.append(w)
        compositor.add(w)
        layoutTaskbar()
        say("open #\(w.id) \(describe(w)) '\(w.title)'")
        if focus || focused == nil { self.focus(w) }
    }

    /// Take `w` off the screen for good (no questions asked). Focus passes
    /// to the window now on top.
    func remove(_ w: Window) {
        guard let i = index(of: w) else { return }
        windows.remove(at: i)
        compositor.remove(w)
        switch grab {
        case .move(let g, _, _), .resize(let g, _, _, _), .content(let g):
            if g === w { grab = .ignore }
        default: break
        }
        if serialTarget === w { serialTarget = nil }
        w.task = nil
        let wasFocused = focused === w
        w.focused = false
        if wasFocused { focused = nil }
        layoutTaskbar()
        say("close #\(w.id)")
        if wasFocused, let top = windows.last { focus(top) }
    }

    /// The user asked to close `w` (close box, Alt-F4, `close`): removed if
    /// it's closable and its close() agrees.
    func requestClose(_ w: Window) {
        guard w.closable, index(of: w) != nil else { return }
        if w.close() { remove(w) }
    }

    // MARK: Focus and z-order

    /// Put `w` on top of the other windows.
    func raise(_ w: Window) {
        guard let i = index(of: w), i != windows.count - 1 else { return }
        windows.remove(at: i)
        windows.append(w)
        compositor.raise(w)
    }

    /// Raise `w` and give it the keyboard (nil: nobody).
    func focus(_ w: Window?) {
        if let w { raise(w) }
        guard focused !== w else { return }
        if let old = focused {
            old.focused = false
            damageChrome(old)
            old.handle(.focus(false))
        }
        focused = w
        if let w {
            w.focused = true
            damageChrome(w)
            w.handle(.focus(true))
            say("focus #\(w.id)")
        }
    }

    /// Alt-Tab: bring the bottom window to the top (so N presses visit all
    /// N windows).
    func cycleFocus() {
        guard let bottom = windows.first else { return }
        focus(bottom)
    }

    // MARK: Geometry

    /// `p` adjusted so `w`'s title bar stays reachable.
    func clampedOrigin(_ w: Window, _ p: Point) -> Point {
        let a = workArea, vis = min(WindowManager.minVisible, w.frame.w)
        let x = max(a.x - w.frame.w + vis, min(p.x, a.maxX - vis))
        let y = max(a.y, min(p.y, a.maxY - Window.titleHeight - Window.border))
        return Point(x, y)
    }

    /// Move `w`'s frame to `p` (clamped); damages the old and new frames.
    func move(_ w: Window, to p: Point) {
        compositor.move(w, to: clampedOrigin(w, p))
    }

    /// Resize `w`'s content area (clamped to its minimum and to the work
    /// area), then send it .resize.
    func resize(_ w: Window, contentWidth: Int, contentHeight: Int) {
        guard w.resizable else { return }
        let maxContent = Window.contentSize(frameWidth: workArea.w, frameHeight: workArea.h)
        let cw = max(min(w.minContentWidth, maxContent.w), min(contentWidth, maxContent.w))
        let ch = max(min(w.minContentHeight, maxContent.h), min(contentHeight, maxContent.h))
        setContentSize(w, cw, ch, notify: true)
    }

    /// A new content surface of `cw` x `ch` (the old pixels copied into its
    /// top-left), and the frame to match.
    func setContentSize(_ w: Window, _ cw: Int, _ ch: Int, notify: Bool) {
        guard cw != w.content.width || ch != w.content.height else { return }
        let s = Surface(width: max(cw, 1), height: max(ch, 1), color: theme.contentBG)
        s.blit(from: w.content, src: w.content.bounds, to: .zero)
        w.content = s
        let size = Window.frameSize(contentWidth: s.width, contentHeight: s.height)
        compositor.setFrame(w, Rect(origin: w.frame.origin, w: size.w, h: size.h))
        w.pendingDamage = .empty
        w.invalidate()
        w.dirty = true
        if notify { w.handle(.resize(width: s.width, height: s.height)) }
    }

    // MARK: Hit testing

    struct Hit {
        var window: Window
        var part: WindowPart
    }

    /// The topmost window part under `p` (nil over the desktop or taskbar).
    func hitTest(_ p: Point) -> Hit? {
        if let tb = taskbar, tb.frame.contains(p) { return nil }
        var i = windows.count - 1
        while i >= 0 {
            if let part = windows[i].part(at: p) { return Hit(window: windows[i], part: part) }
            i -= 1
        }
        return nil
    }

    // MARK: Events

    /// Handle one event from the main loop.
    func route(_ event: Event) {
        switch event {
        case .key(let k): key(k)
        case .mouse(let x, let y, let b): mouse(Point(x, y), b)
        default: break
        }
    }

    func key(_ k: Key) {
        if k.serial, let t = serialTarget {
            t.handle(.key(k))
            return
        }
        if shortcut(k) { return }
        focused?.handle(.key(k))
    }

    /// The WM's own keys. True if `k` was one (and was handled).
    func shortcut(_ k: Key) -> Bool {
        if k.isAlt(.char(0x09)) { cycleFocus(); return true }
        if k.isAlt(.function(4)) {
            if let w = focused { requestClose(w) }
            return true
        }
        let ctrlAltT = k.ctrl && k.alt && (k.code == .char(0x14) || k.code == .char(0x74) || k.code == .char(0x54))
        if (k.meta && k.code == .char(0x0D)) || ctrlAltT {
            openTerminal(self)
            return true
        }
        return false
    }

    func mouse(_ p: Point, _ b: UInt8) {
        let pressed = b & 1 != 0 && buttons & 1 == 0
        let released = b & 1 == 0 && buttons & 1 != 0
        pointer = p
        buttons = b
        switch grab {
        case .move(let w, let dx, let dy):
            move(w, to: Point(p.x - dx, p.y - dy))
            if released { grab = .none; say("move #\(w.id) \(describe(w))") }
            return
        case .resize(let w, let start, let cw, let ch):
            resize(w, contentWidth: cw + p.x - start.x, contentHeight: ch + p.y - start.y)
            if released { grab = .none; say("resize #\(w.id) \(describe(w))") }
            return
        case .content(let w):
            deliver(w, p, b)
            if b == 0 { grab = .none }
            return
        case .ignore:
            if b & 1 == 0 { grab = .none }
            return
        case .none:
            break
        }
        if pressed {
            press(p, b)
            return
        }
        // Hovering, or another button: content only.
        if let hit = hitTest(p), hit.part == .content {
            deliver(hit.window, p, b)
            if b != 0 { grab = .content(hit.window) }
        }
    }

    /// The left button went down at `p`.
    func press(_ p: Point, _ b: UInt8) {
        grab = .ignore
        if let tb = taskbar, tb.frame.contains(p) {
            if let item = tb.item(at: p) { activate(item.action) }
            return
        }
        guard let hit = hitTest(p) else { return }
        let w = hit.window
        focus(w)
        switch hit.part {
        case .close: requestClose(w)
        case .title: grab = .move(w, dx: p.x - w.frame.x, dy: p.y - w.frame.y)
        case .resize: grab = .resize(w, start: p, width: w.content.width, height: w.content.height)
        case .border: break
        case .content:
            grab = .content(w)
            deliver(w, p, b)
        }
    }

    func activate(_ action: Taskbar.Action) {
        switch action {
        case .openTerminal: openTerminal(self)
        case .openEditor: openEditor(self)
        case .focus(let w): focus(w)
        }
    }

    /// A mouse event for `w`'s content, in content-local coordinates.
    func deliver(_ w: Window, _ p: Point, _ b: UInt8) {
        let l = w.local(p)
        w.handle(.mouse(x: l.x, y: l.y, buttons: b))
    }

    // MARK: Drawing

    /// Let windows draw, and turn what they changed into damage. Called just
    /// before compositing; never allocates.
    func render() {
        for w in windows {
            if w.needsDraw() {
                w.dirty = false
                w.draw()
            }
            if !w.pendingDamage.isEmpty {
                compositor.damage(w.pendingDamage.offsetBy(w.contentRect.origin).intersection(w.contentRect))
                w.pendingDamage = .empty
            }
            if w.chromeDirty { damageChrome(w) }
        }
    }

    /// Repaint `w`'s decorations and its taskbar button.
    func damageChrome(_ w: Window) {
        w.chromeDirty = false
        compositor.damage(w.frame) // the border and title bar; cheap enough
        if let tb = taskbar, let b = tb.button(for: w) { compositor.damage(b.rect) }
    }

    func layoutTaskbar() {
        guard let tb = taskbar else { return }
        tb.layout(windows)
        compositor.damage(tb)
    }

    /// Clock and memory in the taskbar (statusBarRefresh, twice a second).
    func refreshStatus(_ text: String) {
        guard let tb = taskbar, tb.setStatus(text) else { return }
        compositor.damage(tb)
    }

    func describe(_ w: Window) -> String {
        "x=\(w.frame.x) y=\(w.frame.y) w=\(w.frame.w) h=\(w.frame.h)"
    }
}

// MARK: The boot console as a window

/// The kernel console (what putc writes and the boot shell reads from) in a
/// window: its content is the console grid, rendered by its own ConsoleView.
/// The shell keeps running in `task`; keys reach it through the default
/// Window.handle. Not closable: it's the serial console's shell.
final class ConsoleWindow: Window {
    let console: Console
    let view: ConsoleView

    init(console: Console, font: PSFFont, palette: InlineArray<16, UInt32>, title: String, task: Task?) {
        self.console = console
        view = ConsoleView(font: font, palette: palette)
        super.init(title: title, contentWidth: console.cols * font.width, contentHeight: console.rows * font.height,
                   task: task)
        content.fill(palette[Int(console.defaultBG)])
        closable = false
        for r in 0..<console.rows { console.dirty[r] = true }
    }

    /// The console changes behind our back (putc): look every frame (cheap:
    /// only dirty rows and the cursor are redrawn).
    override func needsDraw() -> Bool { true }

    override func draw() {
        view.render(console, into: content, at: .zero) { invalidate($0) }
    }

    override func handle(_ event: Event) {
        if case .resize = event {
            for r in 0..<console.rows { console.dirty[r] = true }
        }
        super.handle(event)
    }
}

// MARK: Placeholder app

/// Stands in for terminal and editor windows until Phases L and N: a
/// coloured content area that shows the last key and marks every click (at
/// its window-local position).
final class PlaceholderWindow: Window {
    var note: String
    var lastKey = "key: none"
    var clickText = "clicks: 0"
    var clicks: [Point] = []
    var clickCount = 0
    var keyCount = 0
    var resizes = 0
    private var lastButtons: UInt8 = 0

    init(title: String, note: String, width: Int = 360, height: Int = 200) {
        self.note = note
        super.init(title: title, contentWidth: width, contentHeight: height)
        clicks.reserveCapacity(32)
    }

    override func handle(_ event: Event) {
        switch event {
        case .key(let k):
            keyCount += 1
            if case .char(let c) = k.code, c >= 0x20 && c < 0x7F {
                lastKey = "key: '" + String(decoding: [c], as: UTF8.self) + "'"
            } else {
                lastKey = "key: (special)"
            }
            dirty = true
        case .mouse(let x, let y, let b):
            if b & 1 != 0 && lastButtons & 1 == 0 {
                clickCount += 1
                if clicks.count == 32 { clicks.removeFirst() }
                clicks.append(Point(x, y))
                clickText = "clicks: \(clickCount) last at \(x),\(y)"
                dirty = true
            }
            lastButtons = b
        case .resize:
            resizes += 1
            dirty = true
        default:
            break
        }
    }

    override func draw() {
        guard let th = theme else { return }
        let s = content, fh = th.font.height
        s.fill(th.appBG)
        s.drawText(title, font: th.font, at: Point(8, 8), fg: th.appInk, bg: nil)
        s.drawText(note, font: th.font, at: Point(8, 8 + fh), fg: th.appInk, bg: nil)
        s.drawText(lastKey, font: th.font, at: Point(8, 8 + 3 * fh), fg: th.appInk, bg: nil)
        s.drawText(clickText, font: th.font, at: Point(8, 8 + 4 * fh), fg: th.appInk, bg: nil)
        for p in clicks { s.fill(Rect(p.x - 2, p.y - 2, 5, 5), th.appMarker) }
        invalidate()
    }
}

// MARK: Switching the screen to the desktop

/// Turn the boot screen into the desktop: the console becomes the first
/// window (owned by `task`, the shell reading it), the status bar becomes
/// the taskbar. Returns a line for the shell.
func startDesktop(task: Task?) -> String {
    if windowManager != nil { return "desktop: already running" }
    guard let d = display, let con = console else { return "desktop: no framebuffer console" }
    let wm = WindowManager(compositor: d.compositor, theme: WindowTheme(font: d.font, convert: d.color))
    d.compositor.remove(d.window)
    d.compositor.setVisible(d.status, false)
    let cw = ConsoleWindow(console: con, font: d.font, palette: d.palette, title: "Wiffer shell", task: task)
    cw.view.showCursor = d.showCursor
    windowManager = wm
    wm.log = true
    wm.add(cw, at: Point((wm.workArea.w - cw.frame.w) / 2, wm.workArea.y))
    wm.serialTarget = cw
    statusNextTick = 0
    statusBarRefresh()
    var line = "desktop: on, \(wm.screen.w)x\(wm.screen.h), work area \(wm.workArea.w)x\(wm.workArea.h)"
    if let tb = wm.taskbar { line += ", taskbar at y=\(tb.frame.y)" }
    return line
}

// MARK: Shell commands

extension Shell {
    static func desktopCommands() -> [Command<T>] {
        [
            Command(name: "desktop", args: "", help: "switch the screen to the window manager") { sh, _ in
                let me = scheduler.current
                sh.say(startDesktop(task: me?.isMain == false ? me : nil))
            },
            Command(name: "windows", args: "", help: "list windows (top last) and taskbar buttons") { sh, _ in
                guard let wm = windowManager else { sh.say("windows: no desktop (try 'desktop')"); return }
                for w in wm.windows {
                    sh.say("window #\(w.id) \(wm.describe(w))\(w.focused ? " focused" : "") '\(w.title)'")
                }
                if let tb = wm.taskbar {
                    for i in tb.items {
                        var label = i.label
                        if case .focus(let w) = i.action { label = "#\(w.id)" }
                        sh.say("button x=\(i.rect.x) y=\(i.rect.y) w=\(i.rect.w) h=\(i.rect.h) '\(label)'")
                    }
                }
            },
            Command(name: "open", args: "<app>", help: "open a window: terminal, editor") { sh, args in
                guard let wm = windowManager else { sh.say("open: no desktop (try 'desktop')"); return }
                switch args.first ?? "" {
                case "terminal": wm.openTerminal(wm)
                case "editor": wm.openEditor(wm)
                default: sh.say("usage: open terminal|editor")
                }
            },
            Command(name: "close", args: "<n>", help: "close window #n") { sh, args in
                guard let wm = windowManager else { sh.say("close: no desktop"); return }
                guard args.count == 1, let n = parseInt(args[0]), let w = wm.window(id: n) else {
                    sh.say("usage: close <window number> (see 'windows')")
                    return
                }
                if !w.closable { sh.say("close: #\(n) can't be closed") }
                wm.requestClose(w)
            },
            Command(name: "warp", args: "<x> <y>", help: "move the mouse pointer (for tests)") { sh, args in
                guard args.count == 2, let x = parseInt(args[0]), let y = parseInt(args[1]) else {
                    sh.say("usage: warp <x> <y>")
                    return
                }
                sh.say(warpPointer(x, y))
            },
        ]
    }
}

/// Put the pointer at (x, y) (clamped), as if the mouse had moved there.
func warpPointer(_ x: Int, _ y: Int) -> String {
    pollMouse() // apply packets already queued first
    guard mouse.width > 0 && mouse.height > 0 else { return "warp: no screen" }
    mouse.x = max(0, min(mouse.width - 1, x))
    mouse.y = max(0, min(mouse.height - 1, y))
    cursorMove(x: mouse.x, y: mouse.y)
    events.postMouse(x: mouse.x, y: mouse.y, buttons: mouse.buttons)
    return "warp: x=\(mouse.x) y=\(mouse.y)"
}
