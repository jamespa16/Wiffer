// Phase K4: the taskbar, the status bar grown up. A Layer in the panel band
// along the bottom of the screen, drawn procedurally (no surface of its own):
//
//   [+ Terminal] [+ Editor]  [window] [window] ...      up 0:01:23  free ...
//
// Clicking a window button focuses and raises that window; the launchers call
// the WM's openTerminal / openEditor hooks. layout(_:) (allocates) rebuilds
// the items when a window opens or closes; draw(into:) reads each window's
// current title and focus, so a retitle or focus change is just a damage of
// the button, and compositing stays allocation-free.

final class Taskbar: Layer {
    enum Action {
        case openTerminal
        case openEditor
        case focus(Window)
    }

    struct Item {
        var action: Action
        /// Screen coordinates.
        var rect: Rect
        /// Launchers only: window buttons show the window's current title.
        var label: String
    }

    static let height = 20
    static let buttonWidth = 150

    private(set) var items: [Item] = []
    /// Clock and memory, right-aligned.
    private(set) var status = ""
    var theme: WindowTheme
    /// Online CPUs and a usage meter per CPU, left of the status text. Each
    /// meter's level is the number of its inner pixel rows lit (0 when idle,
    /// meterRows when busy the whole interval), so a redraw happens only when
    /// a meter visibly changes.
    private(set) var cpuCount = onlineCPUCount()
    private(set) var cpuLevels: [Int] = []
    static let dotSize = 8
    static let dotGap = 4
    static let meterHeight = 14
    static let meterRows = meterHeight - 2

    /// Lit rows for a usage percentage: anything above 0 shows at least one.
    static func level(_ percent: Int) -> Int {
        percent <= 0 ? 0 : max(1, (min(percent, 100) * meterRows + 50) / 100)
    }

    init(screen: Rect, theme: WindowTheme) {
        self.theme = theme
        super.init(frame: Rect(screen.x, screen.maxY - Taskbar.height, screen.w, Taskbar.height),
                   band: .panel, opaque: true)
    }

    /// Width of the CPU widget: "cpu N" and one dot per CPU.
    var cpuWidth: Int {
        theme.font.textWidth("cpu \(cpuCount)") + 6 + cpuCount * (Taskbar.dotSize + Taskbar.dotGap) + 8
    }

    /// Where the CPU widget starts.
    var cpuX: Int { statusX - cpuWidth }

    /// Where the status text starts.
    var statusX: Int { frame.maxX - theme.font.textWidth(status) - 6 }

    /// Rebuild the buttons for `windows` (bottom to top; buttons go in the
    /// order the windows were opened, i.e. by id).
    func layout(_ windows: [Window]) {
        items.removeAll(keepingCapacity: true)
        let fw = theme.font.width
        var x = frame.x + 2
        let y = frame.y + 2, h = frame.h - 4
        for (action, label) in [(Action.openTerminal, "+ Terminal"), (Action.openEditor, "+ Editor")] {
            let w = (textCells(label) + 2) * fw
            items.append(Item(action: action, rect: Rect(x, y, w, h), label: label))
            x += w + 4
        }
        x += 8
        let sorted = windows.sorted { $0.id < $1.id }
        guard !sorted.isEmpty else { return }
        // Leave room for the status text (up to 48 cells, or half the bar).
        let room = max(frame.maxX - min(48 * fw + cpuWidth, frame.w / 2) - x, 0)
        let each = min(Taskbar.buttonWidth, room / sorted.count)
        guard each >= 3 * fw else { return }
        for w in sorted {
            items.append(Item(action: .focus(w), rect: Rect(x, y, each - 4, h), label: ""))
            x += each
        }
    }

    /// Set the status text; true if it changed (the caller damages).
    func setStatus(_ text: String) -> Bool {
        guard text != status else { return false }
        status = text
        return true
    }

    /// Set the CPU widget's state from per-CPU usage percentages; true if it
    /// changed (the caller damages).
    func setCPUs(count: Int, usage: [Int]) -> Bool {
        var levels: [Int] = []
        levels.reserveCapacity(count)
        for i in 0..<count { levels.append(i < usage.count ? Taskbar.level(usage[i]) : 0) }
        guard count != cpuCount || levels != cpuLevels else { return false }
        cpuCount = count
        cpuLevels = levels
        return true
    }

    /// The item under `p` (screen coordinates).
    func item(at p: Point) -> Item? {
        for i in items where i.rect.contains(p) { return i }
        return nil
    }

    /// The button for `w`, if it has one.
    func button(for w: Window) -> Item? {
        for i in items {
            if case .focus(let x) = i.action, x === w { return i }
        }
        return nil
    }

    /// Drop every reference to windows (before the taskbar is thrown away).
    func clear() { items.removeAll() }

    override func draw(into s: Surface, clip: Rect) {
        let th = theme
        s.fill(clip, th.taskbarBG)
        s.hline(x: frame.x, y: frame.y, w: frame.w, th.borderUnfocused)
        let ty = frame.y + (frame.h - th.font.height) / 2
        for i in items where i.rect.intersects(clip) {
            var bg = th.launcherBG
            var label = i.label
            if case .focus(let w) = i.action {
                bg = w.focused ? th.buttonFocusedBG : th.buttonBG
                label = w.title
            }
            s.fill(i.rect, bg)
            s.withClip(Rect(i.rect.x + 2, i.rect.y, i.rect.w - 4, i.rect.h)) {
                s.drawText(label, font: th.font, at: Point(i.rect.x + th.font.width, ty), fg: th.buttonText, bg: nil)
            }
        }
        // CPU widget: an outlined meter per CPU, filled from the bottom by
        // its usage over the last refresh interval.
        let label = "cpu \(cpuCount)"
        var dx = cpuX
        s.drawText(label, font: th.font, at: Point(dx, ty), fg: th.taskbarText, bg: nil)
        dx += th.font.textWidth(label) + 6
        let mh = min(Taskbar.meterHeight, frame.h - 2)
        let dy = frame.y + (frame.h - mh) / 2
        for i in 0..<cpuCount {
            let r = Rect(dx, dy, Taskbar.dotSize, mh)
            s.fill(r, th.borderUnfocused)
            s.fill(Rect(r.x + 1, r.y + 1, r.w - 2, r.h - 2), th.taskbarBG)
            let lit = min(i < cpuLevels.count ? cpuLevels[i] : 0, r.h - 2)
            if lit > 0 { s.fill(Rect(r.x + 1, r.maxY - 1 - lit, r.w - 2, lit), th.buttonFocusedBG) }
            dx += Taskbar.dotSize + Taskbar.dotGap
        }
        s.drawText(status, font: th.font, at: Point(statusX, ty), fg: th.taskbarText, bg: nil)
    }
}
