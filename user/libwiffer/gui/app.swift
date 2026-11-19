// libwiffer, Phase 6F: the application loop (see lib/gui and appwindow.swift).
//
//   let app = App(title: "Clock", width: 240, height: 120)!
//   app.onPaint = { s in ... }          custom background painting
//   app.ui.button(...)                  widgets (Container)
//   app.tickInterval = 1000             onTick every second
//   app.onTick = { now in ...; app.requestPaint() }
//   exit(app.run())
//
// run() is one `wait` on the window (plus any `watch`ed fds) with a timeout
// for the next tick or caret blink: nothing busy-waits. Events are decoded
// and handed to `onEvent` first (return true to consume), then to the widgets.
// A resize event adopts the new buffer, calls `onResize`, and repaints
// everything. A close event calls `onClose` (default: quit).

final class App {
    let window: AppWindow
    let ui: Container
    var theme: GUITheme { ui.theme }

    var onPaint: ((Surface) -> Void)?
    var onEvent: ((GUIEvent) -> Bool)?
    var onResize: ((Int, Int) -> Void)?
    /// Return true to let the window close.
    var onClose: (() -> Bool)?
    var onTick: ((Int) -> Void)?
    /// ms between onTick calls; nil: none.
    var tickInterval: Int?
    private var nextTickAt = 0
    private var paintRequested = true
    private var running = true
    private var exitCode: Int32 = 0
    private var watched: [(fd: Int, events: Int16, handler: (Int16) -> Void)] = []
    /// Phase 8H: fds that change from one wait to the next (a browser's
    /// sockets), asked for before every wait; `onDynamicReady` gets them back
    /// with revents filled in.
    var dynamicWaits: (() -> [WaitFD])?
    var onDynamicReady: (([WaitFD]) -> Void)?
    /// ms until the program wants `onIdle` again (0: right away; nil: no limit).
    var nextTimeout: (() -> Int?)?
    /// Runs after every wait (events, watched fds and ticks handled first).
    var onIdle: (() -> Void)?

    init?(title: String, width: Int, height: Int) {
        guard let font = GUIFont.spleen, let w = AppWindow.create(title: title, width: width, height: height) else {
            return nil
        }
        window = w
        ui = Container(theme: GUITheme(font: font))
    }

    /// Repaint the whole window (onPaint, then every widget) at the next
    /// opportunity.
    func requestPaint() { paintRequested = true }

    func quit(_ code: Int32 = 0) {
        exitCode = code
        running = false
    }

    /// Call `handler(revents)` when `fd` is ready for `events` (WaitEvent
    /// bits): for sockets and pipes beside the window.
    func watch(fd: Int, events: Int16, _ handler: @escaping (Int16) -> Void) {
        watched.append((fd: fd, events: events, handler: handler))
    }

    private func paintAll() {
        let s = window.surface
        s.setClip(nil)
        s.fill(ui.theme.background)
        onPaint?(s)
        ui.invalidateAll()
        ui.render(into: s)
        window.present()
    }

    private func flush() {
        if paintRequested {
            paintRequested = false
            paintAll()
        } else {
            let d = ui.render(into: window.surface)
            if !d.isEmpty { window.present(d) }
        }
    }

    private func handle(_ e: GUIEvent) {
        if let onEvent, onEvent(e) { return }
        switch e {
        case .resize:
            window.adoptResize()
            onResize?(window.width, window.height)
            paintRequested = true
        case .close:
            if onClose?() ?? true { quit() }
        default:
            ui.handle(e)
        }
    }

    /// Run until `quit` (or a close). Returns the exit code.
    func run() -> Int32 {
        nextTickAt = Time.now + (tickInterval ?? 0)
        while running {
            flush()
            let now = Time.now
            var timeout = -1
            if let i = tickInterval { timeout = max(nextTickAt - now, 0); _ = i }
            if let d = ui.nextTick(now) { timeout = timeout < 0 ? d : min(timeout, d) }
            if let d = nextTimeout?() { timeout = timeout < 0 ? max(d, 0) : min(timeout, max(d, 0)) }
            var fds = [WaitFD(fd: Int32(window.fd), events: WaitEvent.readable, revents: 0)]
            for w in watched { fds.append(WaitFD(fd: Int32(w.fd), events: w.events, revents: 0)) }
            let dynamicStart = fds.count
            if let d = dynamicWaits?() { fds += d.prefix(64 - fds.count) }
            let r = wait(&fds, timeoutMs: timeout)
            if r < 0 { return 1 } // killed
            if fds[0].revents & WaitEvent.readable != 0 {
                var pending = window.readEvents()
                var resizes = 0
                for e in pending { if case .resize = e { resizes += 1 } }
                // Several queued resizes: only the last matters.
                for e in pending {
                    if case .resize = e, resizes > 1 { resizes -= 1; continue }
                    handle(e)
                }
                pending.removeAll()
            }
            for (i, w) in watched.enumerated() where fds[i + 1].revents != 0 { w.handler(fds[i + 1].revents) }
            if dynamicStart < fds.count { onDynamicReady?(Array(fds[dynamicStart...])) }
            let t = Time.now
            if let i = tickInterval, t >= nextTickAt {
                nextTickAt = t + i
                onTick?(t)
            }
            ui.tick(t)
            onIdle?()
        }
        window.close()
        return exitCode
    }
}
