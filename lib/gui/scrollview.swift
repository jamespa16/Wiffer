// A scrolling viewport over content of a given size (lib/gui).
//
// The content is whatever `drawContent` paints: it is called with the
// surface (clipped to the viewport), the viewport rect and the window
// position of the content's (0, 0) (viewport origin minus the scroll
// offset). Bars appear when the content is larger than the viewport.
// Scrolling: the wheel (3 lines), dragging a thumb, clicking a track (a
// page), and, when focused, arrows (a line), PgUp/PgDn (a page), Home/End.

final class ScrollView: Widget {
    static let barWidth = 12
    static let lineStep = 16
    var contentWidth: Int {
        didSet { clampScroll(); needsDraw = true }
    }
    var contentHeight: Int {
        didSet { clampScroll(); needsDraw = true }
    }
    private(set) var scrollX = 0
    private(set) var scrollY = 0
    /// Paint the content: (surface, viewport, window position of content (0, 0)).
    var drawContent: ((Surface, Rect, Point) -> Void)?
    var onScroll: (() -> Void)?
    private enum Drag { case none, vertical(grab: Int), horizontal(grab: Int) }
    private var drag = Drag.none

    init(frame: Rect, contentWidth: Int = 0, contentHeight: Int = 0) {
        self.contentWidth = contentWidth
        self.contentHeight = contentHeight
        super.init(frame: frame)
    }

    override var focusable: Bool { true }

    override var frame: Rect {
        didSet { clampScroll() }
    }

    // MARK: Geometry

    var needsVertical: Bool { contentHeight > frame.h || (contentWidth > frame.w && contentHeight > frame.h - ScrollView.barWidth) }
    var needsHorizontal: Bool { contentWidth > frame.w || (needsVertical && contentWidth > frame.w - ScrollView.barWidth) }

    /// The area content shows in (window coordinates).
    var viewport: Rect {
        let v = needsVertical, h = needsHorizontal
        return Rect(frame.x, frame.y, frame.w - (v ? ScrollView.barWidth : 0), frame.h - (h ? ScrollView.barWidth : 0))
    }

    var maxScrollX: Int { max(contentWidth - viewport.w, 0) }
    var maxScrollY: Int { max(contentHeight - viewport.h, 0) }

    private var verticalTrack: Rect {
        let v = viewport
        return Rect(frame.maxX - ScrollView.barWidth, frame.y, ScrollView.barWidth, v.h)
    }

    private var horizontalTrack: Rect {
        let v = viewport
        return Rect(frame.x, frame.maxY - ScrollView.barWidth, v.w, ScrollView.barWidth)
    }

    /// The thumb of a bar: (offset, length) along the track.
    private func thumb(track: Int, view: Int, content: Int, scroll: Int) -> (Int, Int) {
        guard content > view, track > 0 else { return (0, track) }
        let len = max(track * view / content, 16)
        let range = max(track - len, 0)
        let maxScroll = content - view
        return (maxScroll == 0 ? 0 : range * scroll / maxScroll, min(len, track))
    }

    var verticalThumb: Rect {
        let t = verticalTrack
        let (o, l) = thumb(track: t.h, view: viewport.h, content: contentHeight, scroll: scrollY)
        return Rect(t.x, t.y + o, t.w, l)
    }

    var horizontalThumb: Rect {
        let t = horizontalTrack
        let (o, l) = thumb(track: t.w, view: viewport.w, content: contentWidth, scroll: scrollX)
        return Rect(t.x + o, t.y, l, t.h)
    }

    // MARK: Scrolling

    private func clampScroll() {
        scrollX = max(0, min(scrollX, maxScrollX))
        scrollY = max(0, min(scrollY, maxScrollY))
    }

    func scrollTo(x: Int, y: Int) {
        let nx = max(0, min(x, maxScrollX)), ny = max(0, min(y, maxScrollY))
        guard nx != scrollX || ny != scrollY else { return }
        scrollX = nx
        scrollY = ny
        needsDraw = true
        onScroll?()
    }

    func scrollBy(dx: Int, dy: Int) { scrollTo(x: scrollX + dx, y: scrollY + dy) }

    /// Scroll the least amount that shows `r` (content coordinates).
    func ensureVisible(_ r: Rect) {
        let v = viewport
        var x = scrollX, y = scrollY
        if r.x < x { x = r.x } else if r.maxX > x + v.w { x = r.maxX - v.w }
        if r.y < y { y = r.y } else if r.maxY > y + v.h { y = r.maxY - v.h }
        scrollTo(x: x, y: y)
    }

    // MARK: Events

    override func mouseWheel(_ p: Point, delta: Int) {
        scrollBy(dx: 0, dy: -delta * 3 * ScrollView.lineStep)
    }

    override func mouseDown(_ p: Point) {
        if needsVertical && verticalTrack.contains(p) {
            let t = verticalThumb
            if t.contains(p) { drag = .vertical(grab: p.y - t.y) }
            else { scrollBy(dx: 0, dy: p.y < t.y ? -viewport.h : viewport.h) }
        } else if needsHorizontal && horizontalTrack.contains(p) {
            let t = horizontalThumb
            if t.contains(p) { drag = .horizontal(grab: p.x - t.x) }
            else { scrollBy(dx: p.x < t.x ? -viewport.w : viewport.w, dy: 0) }
        }
        needsDraw = true
    }

    override func mouseMove(_ p: Point, buttons: Int) {
        switch drag {
        case .vertical(let grab):
            let t = verticalTrack, th = verticalThumb
            let range = t.h - th.h
            if range > 0 { scrollTo(x: scrollX, y: (p.y - grab - t.y) * maxScrollY / range) }
        case .horizontal(let grab):
            let t = horizontalTrack, th = horizontalThumb
            let range = t.w - th.w
            if range > 0 { scrollTo(x: (p.x - grab - t.x) * maxScrollX / range, y: scrollY) }
        case .none: break
        }
    }

    override func mouseUp(_ p: Point) {
        drag = .none
        needsDraw = true
    }

    override func key(_ k: GUIKeyEvent) -> Bool {
        if k.ctrl || k.alt { return false }
        let v = viewport
        switch k.code {
        case WinKey.up: scrollBy(dx: 0, dy: -ScrollView.lineStep)
        case WinKey.down: scrollBy(dx: 0, dy: ScrollView.lineStep)
        case WinKey.left: scrollBy(dx: -ScrollView.lineStep, dy: 0)
        case WinKey.right: scrollBy(dx: ScrollView.lineStep, dy: 0)
        case WinKey.pageUp: scrollBy(dx: 0, dy: -v.h)
        case WinKey.pageDown: scrollBy(dx: 0, dy: v.h)
        case WinKey.home: scrollTo(x: scrollX, y: 0)
        case WinKey.end: scrollTo(x: scrollX, y: maxScrollY)
        default: return false
        }
        return true
    }

    // MARK: Drawing

    override func draw(_ s: Surface, _ theme: GUITheme) {
        let v = viewport
        s.fill(v, theme.fieldBackground)
        if let drawContent {
            s.withClip(v) { drawContent(s, v, Point(v.x - scrollX, v.y - scrollY)) }
        }
        var active = false
        if case .vertical = drag { active = true }
        if needsVertical {
            s.fill(verticalTrack, theme.scrollTrack)
            s.fill(verticalThumb.intersection(verticalTrack), active ? theme.scrollThumbActive : theme.scrollThumb)
        }
        active = false
        if case .horizontal = drag { active = true }
        if needsHorizontal {
            s.fill(horizontalTrack, theme.scrollTrack)
            s.fill(horizontalThumb.intersection(horizontalTrack), active ? theme.scrollThumbActive : theme.scrollThumb)
        }
        if needsVertical && needsHorizontal {
            s.fill(Rect(frame.maxX - ScrollView.barWidth, frame.maxY - ScrollView.barWidth, ScrollView.barWidth,
                        ScrollView.barWidth), theme.scrollTrack)
        }
        s.frame(frame, hasFocus ? theme.focusBorder : theme.fieldBorder)
    }
}
