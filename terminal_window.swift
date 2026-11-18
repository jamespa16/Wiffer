// Phase L: terminal windows, and booting into the desktop.
//
// - TerminalWindow: a Window owning a Console sized to its content area (in
//   cells), a ConsoleView that renders it into `content`, and a Task running
//   Shell<WindowTerminal>. Each window's shell has its own history,
//   variables and cwd (they live in its Shell value, on its task's stack).
// - WindowTerminal: read() blocks the task in waitEvent() until a key reaches
//   its inbox (the WM's default Window.handle posts keys there); write()
//   feeds the window's Console and marks the window dirty; columns is the
//   console's current width.
// - Resize: .resize re-creates the Console at the new size in cells, keeping
//   what fits (the cursor's row stays on screen; no reflow).
// - Closing: the close box, Alt-F4 and `close <n>` go through
//   WindowManager.requestClose, whose default close() posts .close to the
//   task, then remove() drops the window's task (which posts .close again,
//   so even a plain remove() ends the shell). read() turns .close into Ctrl-C
//   (the line editor abandons the line) and `finished`, so Shell.run returns.
//   `exit` sets `finished` directly. Either way the task then removes the
//   window (a no-op if it's gone) and returns; the window, its console and
//   surface go with the last reference (the task's frame) and the task's
//   stack is freed by the next task to run. No cycles: the window holds the
//   task, the task's stack holds the window only while the shell runs.
//
// Routing (documented in ROADMAP.md Phase L):
// - Boot goes straight to the desktop (runDesktop) with one terminal, unless
//   the kernel command line (limine.conf `cmdline:`) has `nodesktop`, which
//   gives the Part 2 full-screen shell (runShellTask).
// - Serial follows focus: the WM's serialTarget is the most recently focused
//   terminal. Serial keys go to it whatever has focus, and its output is
//   mirrored to COM1 while it is the target. So a serial console (or the
//   test harness) types into the terminal last clicked, and sees its output.
//   A serial key when no terminal is open opens one.
// - print() and every other kernel message (putc) go to serial and to the
//   kernel console, which in desktop mode is off-screen: `open log` shows it
//   in a Log window. Exception and task-panic reports bypass the WM and the
//   compositor: panicFlush paints the kernel console (with the report) and
//   its red status bar straight onto the framebuffer.

// MARK: Kernel command line

/// The kernel command line from Limine (empty without one).
func kernelCmdline() -> [UInt8] {
    guard let resp = cmdline_request.response, let p = resp.pointee.cmdline else { return [] }
    var bytes: [UInt8] = []
    var i = 0
    while i < 4096 && p[i] != 0 {
        bytes.append(UInt8(bitPattern: p[i]))
        i += 1
    }
    return bytes
}

/// Is `flag` one of the command line's space-separated words?
func kernelCmdlineHas(_ flag: StaticString) -> Bool {
    let line = kernelCmdline()
    return flag.withUTF8Buffer { want in
        for word in line.split(separator: 0x20) where word.elementsEqual(want) { return true }
        return false
    }
}

// MARK: Boot

/// Part 3 boot: the desktop with one terminal, the event loop as task 0.
/// Falls back to the full-screen shell if there is no framebuffer console.
func runDesktop() -> Never {
    guard let wm = startBootDesktop() else { runShellTask() }
    if openTerminal(in: wm) == nil { print("desktop: couldn't open a terminal") }
    runMainLoop { wm.route($0) }
}

/// Switch the screen to a WM with no windows yet (the console and status bar
/// layers hidden; the kernel console keeps logging off-screen).
func startBootDesktop() -> WindowManager? {
    guard let d = display, console != nil else {
        print("desktop: no framebuffer console, using the full-screen shell")
        return nil
    }
    let wm = WindowManager(compositor: d.compositor, theme: WindowTheme(font: d.font, convert: d.color))
    d.compositor.remove(d.window)
    d.compositor.setVisible(d.status, false)
    windowManager = wm
    wm.log = true
    wm.serialFollowsFocus = true
    wm.openTerminal = openTerminalWindow
    installAppLauncher(wm) // Phase 6F
    statusNextTick = 0
    statusBarRefresh()
    print("desktop: on, \(wm.screen.w)x\(wm.screen.h), serial follows the focused terminal")
    return wm
}

// MARK: Opening terminals

/// The WM's openTerminal hook (Ctrl-Alt-T, Super+Enter, "+ Terminal", `open terminal`).
func openTerminalWindow(_ wm: WindowManager) {
    openTerminal(in: wm)
}

/// Open a terminal window running its own shell: `cols` x `rows` cells
/// (default: two fit side by side in the work area), at `origin` (default:
/// the first free slot in a grid, else cascaded). Nil if there's no memory
/// for the task's stack.
@discardableResult
func openTerminal(in wm: WindowManager, cols: Int? = nil, rows: Int? = nil, at origin: Point? = nil) -> TerminalWindow? {
    let font = wm.theme.font
    let size = defaultTerminalSize(wm)
    let w = TerminalWindow(title: "Terminal \(wm.nextID)", cols: cols ?? size.cols, rows: rows ?? size.rows,
                           font: font, palette: terminalPalette())
    guard let task = spawn("shell", { terminalMain(w, wm) }) else {
        print("terminal: no memory for a task")
        return nil
    }
    w.task = task
    wm.add(w, at: origin ?? freeSlot(wm, w))
    return w
}

/// The task's body: the shell until it ends, then the window goes.
@inline(never)
func terminalMain(_ w: TerminalWindow, _ wm: WindowManager) {
    runTerminalShell(w)
    wm.remove(w)
}

/// Its own frame, so the shell (and its reference to the window) is gone
/// before the window is removed.
@inline(never)
func runTerminalShell(_ w: TerminalWindow) {
    var sh = Shell(terminal: WindowTerminal(window: w))
    sh.run()
}

/// Cells for a new terminal: up to 80 x 25, two side by side with 8 px gaps.
func defaultTerminalSize(_ wm: WindowManager) -> (cols: Int, rows: Int) {
    let f = wm.theme.font, a = wm.workArea
    let chromeW = 2 * Window.border, chromeH = 2 * Window.border + Window.titleHeight
    let cols = ((a.w - 3 * 8) / 2 - chromeW) / f.width
    let rows = (a.h - 2 * 8 - chromeH) / f.height
    return (max(20, min(80, cols)), max(4, min(25, rows)))
}

/// The first spot, scanning a grid of `w`-sized cells (8 px apart) from the
/// work area's top-left, that no window overlaps; nil if none.
func freeSlot(_ wm: WindowManager, _ w: Window) -> Point? {
    let a = wm.workArea, gap = 8
    var y = a.y + gap
    while y + w.frame.h <= a.maxY {
        var x = a.x + gap
        while x + w.frame.w <= a.maxX {
            let r = Rect(x, y, w.frame.w, w.frame.h)
            var free = true
            for other in wm.windows where other.frame.intersects(r) { free = false }
            if free { return Point(x, y) }
            x += w.frame.w + gap
        }
        y += w.frame.h + gap
    }
    return nil
}

/// The ANSI palette in the screen's pixel format (0xRRGGBB off-screen).
func terminalPalette() -> InlineArray<16, UInt32> {
    if let d = display { return d.palette }
    var p = InlineArray<16, UInt32>(repeating: 0)
    for i in 0..<16 { p[i] = ansiColor(i) }
    return p
}

// MARK: TerminalWindow

final class TerminalWindow: Window {
    /// Replaced on resize.
    private(set) var console: Console
    let view: ConsoleView
    /// Repaint the whole content (after a resize) on the next draw.
    private var needsClear = false
    var resizes = 0

    init(title: String, cols: Int, rows: Int, font: PSFFont, palette: InlineArray<16, UInt32>) {
        console = Console(cols: cols, rows: rows)
        view = ConsoleView(font: font, palette: palette)
        super.init(title: title, contentWidth: console.cols * font.width, contentHeight: console.rows * font.height)
        content.fill(palette[Int(console.defaultBG)])
        acceptsSerial = true
        minContentWidth = 20 * font.width
        minContentHeight = 4 * font.height
        view.showCursor = false // until focused
    }

    /// The WM drops the task when it removes the window (WindowManager.remove):
    /// tell the shell, so its task ends even without close().
    override var task: Task? {
        didSet {
            if task == nil, let old = oldValue, old.state != .finished { old.post(.close) }
        }
    }

    /// Output from the shell (WindowTerminal.write): `\n` as CR LF, into the
    /// console, and to COM1 too while this is the serial target.
    func write(_ text: String) {
        let serial = isSerialTarget
        for b in text.utf8 {
            if b == 0x0A {
                console.write(0x0D)
                if serial { serialPutc(0x0D) }
            }
            console.write(b)
            if serial { serialPutc(b) }
        }
        dirty = true
    }

    override func handle(_ event: Event) {
        switch event {
        case .resize(let w, let h):
            resizeConsole(width: w, height: h)
        case .focus(let on):
            view.showCursor = on
            console.dirty[min(console.row, console.rows - 1)] = true
            dirty = true
        default:
            super.handle(event) // keys and .close go to the task
        }
    }

    /// A console grid for a `width` x `height` px content area, keeping what fits.
    func resizeConsole(width: Int, height: Int) {
        resizes += 1
        let cols = max(width / view.font.width, 1), rows = max(height / view.font.height, 1)
        if cols != console.cols || rows != console.rows { console = console.resized(cols: cols, rows: rows) }
        needsClear = true
        dirty = true
    }

    override func draw() {
        if needsClear {
            needsClear = false
            content.fill(view.palette[Int(console.defaultBG)])
            for r in 0..<console.rows { console.dirty[r] = true }
            invalidate()
        }
        view.render(console, into: content, at: .zero) { invalidate($0) }
    }
}

extension Console {
    /// A copy at `newCols` x `newRows`: the top-left of the grid, shifted up
    /// if needed so the cursor's row stays on screen; colours and attributes
    /// carried over. No reflow.
    func resized(cols newCols: Int, rows newRows: Int) -> Console {
        let c = Console(cols: newCols, rows: newRows)
        let blankCell = Cell(ch: 0x20, fg: defaultFG, bg: defaultBG)
        for i in 0..<c.cells.count { c.cells[i] = blankCell }
        let cursorRow = min(row, rows - 1)
        let shift = max(0, cursorRow - (c.rows - 1))
        let copyCols = min(cols, c.cols)
        var r = 0
        while r < c.rows && r + shift < rows {
            for col in 0..<copyCols { c.cells[r * c.cols + col] = cells[(r + shift) * cols + col] }
            r += 1
        }
        c.row = cursorRow - shift
        c.col = min(col, c.cols)
        c.defaultFG = defaultFG
        c.defaultBG = defaultBG
        c.fg = fg
        c.bg = bg
        c.bold = bold
        c.scrollCount = scrollCount + shift
        return c
    }
}

// MARK: WindowTerminal

/// The Terminal a terminal window's shell talks to. Runs on the window's task.
struct WindowTerminal: Terminal {
    let window: TerminalWindow
    private(set) var finished = false

    init(window: TerminalWindow) { self.window = window }

    /// The next key from the task's inbox. After .close: Ctrl-C (the line
    /// editor drops the line) with `finished` set, so the shell stops.
    mutating func read() -> KeyEvent {
        guard !finished else { return .char(0x03) }
        while true {
            switch waitEvent() {
            case .key(let k): return k.code
            case .close:
                finished = true
                return .char(0x03)
            default: break
            }
        }
    }

    mutating func write(_ text: String) { window.write(text) }

    var columns: Int { window.console.cols }

    mutating func requestExit() -> Bool {
        finished = true
        return true
    }
}

extension Shell {
    static func terminalCommands() -> [Command<T>] {
        [
            Command(name: "exit", args: "", help: "close this terminal window") { sh, _ in
                if !sh.term.requestExit() { sh.say("exit: the boot shell can't exit") }
            },
        ]
    }
}

// MARK: Log window

/// The kernel console (everything putc writes: print(), WM and boot
/// messages, selftest output) in a window, its newest lines at the bottom.
/// `open log`. Its view clears the console's dirty flags, so only one window
/// may show the kernel console at a time.
final class LogWindow: Window {
    let console: Console
    let view: ConsoleView

    init(console: Console, font: PSFFont, palette: InlineArray<16, UInt32>, width: Int, height: Int) {
        self.console = console
        view = ConsoleView(font: font, palette: palette)
        view.showCursor = false
        super.init(title: "Log", contentWidth: width, contentHeight: height)
        content.fill(palette[Int(console.defaultBG)])
        for r in 0..<console.rows { console.dirty[r] = true }
    }

    /// putc changes the console behind our back: look every frame (only
    /// dirty rows are redrawn).
    override func needsDraw() -> Bool { true }

    override func draw() {
        let y = min(0, content.height - console.rows * view.font.height)
        view.render(console, into: content, at: Point(0, y)) { invalidate($0) }
    }

    override func handle(_ event: Event) {
        if case .resize = event {
            content.fill(view.palette[Int(console.defaultBG)])
            for r in 0..<console.rows { console.dirty[r] = true }
            invalidate()
        }
    }
}

/// `open log`: show the kernel console in a window (or focus the one that does).
func openLogWindow(_ wm: WindowManager) -> String {
    guard let con = console else { return "open log: no kernel console" }
    for w in wm.windows where w is LogWindow || w is ConsoleWindow {
        wm.focus(w)
        return "open log: already open as #\(w.id)"
    }
    let f = wm.theme.font
    let w = LogWindow(console: con, font: f, palette: terminalPalette(),
                      width: min(con.cols, 100) * f.width, height: min(con.rows, 30) * f.height)
    wm.add(w)
    return "open log: #\(w.id)"
}

// MARK: Panic screen

/// Show a dying kernel's report: in desktop mode, paint the kernel console
/// and its chrome (the status bar, red by now) straight onto the framebuffer,
/// bypassing the WM and the compositor; otherwise the usual flush. Never
/// allocates.
func panicFlush() {
    guard windowManager != nil, let d = display, let c = console else {
        consoleFlush()
        return
    }
    d.paintPanic(c)
}

extension Display {
    /// The Part 2 screen (status bar, frame, console) drawn directly on the
    /// framebuffer. Never allocates, never reads the framebuffer.
    func paintPanic(_ c: Console) {
        let fw = font.width, fh = font.height
        for r in 0..<rows {
            for col in 0..<cols where !inViewport(r, col) {
                let cell = chrome[r * cols + col]
                front.drawGlyph(font.glyph(cell.ch), font: font, at: Point(col * fw, r * fh),
                                fg: palette[Int(cell.fg & 15)], bg: palette[Int(cell.bg & 15)])
            }
        }
        for r in 0..<c.rows { c.dirty[r] = true }
        let viewport = Rect(originCol * fw, originRow * fh, viewCols * fw, viewRows * fh)
        front.withClip(viewport) {
            view.render(c, into: front, at: viewport.origin) { _ in }
        }
    }
}
