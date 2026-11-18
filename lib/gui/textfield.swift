// A single-line text field (lib/gui).
//
// Editing: typing inserts (replacing any selection), Backspace and Delete,
// Left/Right (Ctrl: by word; Shift extends the selection; without Shift a
// selection collapses to its edge), Home/End, Ctrl-A select all, Ctrl-C/X/V
// through `guiClipboard`, Ctrl-U delete to the start, Ctrl-K delete to the
// end, Ctrl-W delete the previous word. Enter calls `onSubmit`, Escape
// `onCancel`. A press puts the caret under the pointer and dragging selects.
// The text scrolls horizontally to keep the caret visible. The caret blinks
// every 500 ms while focused (the container's tick).

final class TextField: Widget {
    private(set) var scalars: [UInt32] = []
    /// Insertion point, 0...count.
    private(set) var cursor = 0
    /// The other end of the selection (== cursor: none).
    private(set) var anchor = 0
    /// Pixels the text is scrolled left.
    private(set) var scrollX = 0
    var placeholder = "" {
        didSet { needsDraw = true }
    }
    var maxLength = 4096
    var readOnly = false
    var onSubmit: ((String) -> Void)?
    var onChange: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private var caretOn = true
    private var lastBlink = 0
    private var dragging = false
    static let padding = 4

    override var focusable: Bool { true }

    /// The text. Setting it puts the caret at the end.
    var text: String {
        get { guiString(scalars[...]) }
        set {
            var v = guiScalars(newValue)
            if v.count > maxLength { v.removeLast(v.count - maxLength) }
            scalars = v
            cursor = v.count
            anchor = cursor
            reveal()
            needsDraw = true
        }
    }

    var count: Int { scalars.count }
    var hasSelection: Bool { anchor != cursor }
    var selectionRange: Range<Int> { min(anchor, cursor)..<max(anchor, cursor) }
    var selectedText: String { guiString(scalars[selectionRange]) }

    var innerWidth: Int { max(frame.w - 2 * TextField.padding, 1) }

    // MARK: Editing

    func setCursor(_ i: Int, extend: Bool = false) {
        cursor = max(0, min(i, scalars.count))
        if !extend { anchor = cursor }
        caretOn = true
        reveal()
        needsDraw = true
    }

    func selectAll() {
        anchor = 0
        cursor = scalars.count
        reveal()
        needsDraw = true
    }

    private func changed() {
        reveal()
        needsDraw = true
        onChange?(text)
    }

    /// Replace the selection (or nothing) with `new`.
    func insert(_ new: [UInt32]) {
        guard !readOnly else { return }
        let r = selectionRange
        let room = maxLength - (scalars.count - r.count)
        let add = Array(new.prefix(max(room, 0)))
        if r.isEmpty && add.isEmpty { return }
        scalars.replaceSubrange(r, with: add)
        cursor = r.lowerBound + add.count
        anchor = cursor
        caretOn = true
        changed()
    }

    func deleteRange(_ r: Range<Int>) {
        guard !readOnly, !r.isEmpty else { return }
        scalars.removeSubrange(r)
        cursor = r.lowerBound
        anchor = cursor
        caretOn = true
        changed()
    }

    private func isWordChar(_ v: UInt32) -> Bool {
        (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) || v == 0x5F || v >= 0x80
    }

    private func wordStart(from i: Int) -> Int {
        var j = i
        while j > 0 && !isWordChar(scalars[j - 1]) { j -= 1 }
        while j > 0 && isWordChar(scalars[j - 1]) { j -= 1 }
        return j
    }

    private func wordEnd(from i: Int) -> Int {
        var j = i
        while j < scalars.count && !isWordChar(scalars[j]) { j += 1 }
        while j < scalars.count && isWordChar(scalars[j]) { j += 1 }
        return j
    }

    override func key(_ k: GUIKeyEvent) -> Bool {
        if k.ctrl && !k.alt {
            if k.isCtrl(0x61) { selectAll(); return true } // a
            if k.isCtrl(0x63) { // c
                if hasSelection { guiClipboard = selectedText }
                return true
            }
            if k.isCtrl(0x78) { // x
                if hasSelection { guiClipboard = selectedText; deleteRange(selectionRange) }
                return true
            }
            if k.isCtrl(0x76) { insert(guiScalars(guiClipboard)); return true } // v
            if k.isCtrl(0x75) { deleteRange(0..<cursor); return true } // u
            if k.isCtrl(0x6B) { deleteRange(cursor..<scalars.count); return true } // k
            if k.isCtrl(0x77) { // w
                deleteRange(hasSelection ? selectionRange : wordStart(from: cursor)..<cursor)
                return true
            }
            switch k.code {
            case WinKey.left: setCursor(wordStart(from: cursor), extend: k.shift); return true
            case WinKey.right: setCursor(wordEnd(from: cursor), extend: k.shift); return true
            case WinKey.home: setCursor(0, extend: k.shift); return true
            case WinKey.end: setCursor(scalars.count, extend: k.shift); return true
            default: break
            }
            return false
        }
        if k.alt || k.meta { return false }
        if let c = k.character { insert([c]); return true }
        switch k.code {
        case GUIKeyEvent.backspace, 0x7F:
            deleteRange(hasSelection ? selectionRange : max(cursor - 1, 0)..<cursor)
        case WinKey.delete:
            deleteRange(hasSelection ? selectionRange : cursor..<min(cursor + 1, scalars.count))
        case WinKey.left:
            if hasSelection && !k.shift { setCursor(selectionRange.lowerBound) } else { setCursor(cursor - 1, extend: k.shift) }
        case WinKey.right:
            if hasSelection && !k.shift { setCursor(selectionRange.upperBound) } else { setCursor(cursor + 1, extend: k.shift) }
        case WinKey.home: setCursor(0, extend: k.shift)
        case WinKey.end: setCursor(scalars.count, extend: k.shift)
        case GUIKeyEvent.enter, 0x0A: onSubmit?(text)
        case GUIKeyEvent.escape:
            guard onCancel != nil else { return false }
            onCancel?()
        default: return false
        }
        return true
    }

    // MARK: Scrolling and the pointer

    /// Scroll so the caret is inside the field.
    private func reveal() {
        let x = cursor * guiCellWidth
        let total = scalars.count * guiCellWidth + 1
        if x - scrollX > innerWidth - 1 { scrollX = x - innerWidth + 1 }
        if x < scrollX { scrollX = x }
        scrollX = max(0, min(scrollX, max(total - innerWidth, 0)))
    }

    /// The caret position (character index) nearest window point `p`.
    func index(at p: Point) -> Int {
        let rel = p.x - (frame.x + TextField.padding) + scrollX
        return max(0, min((rel + guiCellWidth / 2) / guiCellWidth, scalars.count))
    }

    override func mouseDown(_ p: Point) {
        dragging = true
        setCursor(index(at: p))
    }

    override func mouseMove(_ p: Point, buttons: Int) {
        guard dragging, buttons & Int(WinButton.left) != 0 else { return }
        setCursor(index(at: p), extend: true)
    }

    override func mouseUp(_ p: Point) { dragging = false }

    override func focusChanged() {
        caretOn = true
        lastBlink = 0
    }

    override func nextTick(_ now: Int) -> Int? {
        guard hasFocus else { return nil }
        if lastBlink == 0 { lastBlink = now }
        return max(lastBlink + 500 - now, 0)
    }

    override func tick(_ now: Int) {
        caretOn.toggle()
        lastBlink = now
        needsDraw = true
    }

    // MARK: Drawing

    override func draw(_ s: Surface, _ theme: GUITheme) {
        s.fill(frame, theme.fieldBackground)
        s.frame(frame, hasFocus ? theme.focusBorder : theme.fieldBorder)
        let font = theme.font
        let inner = Rect(frame.x + TextField.padding, frame.y + 1, innerWidth, frame.h - 2)
        let ty = frame.y + (frame.h - font.height) / 2
        let ox = inner.x - scrollX
        let fg = enabled ? theme.text : theme.disabledText
        s.withClip(inner) {
            if scalars.isEmpty && !placeholder.isEmpty && !hasFocus {
                s.drawText(placeholder, font: font, at: Point(inner.x, ty), fg: theme.disabledText, bg: nil)
                return
            }
            let sel = selectionRange
            if !sel.isEmpty {
                s.fill(Rect(ox + sel.lowerBound * guiCellWidth, ty, sel.count * guiCellWidth, font.height), theme.selection)
            }
            var x = ox
            for (i, v) in scalars.enumerated() {
                if x + guiCellWidth > inner.x && x < inner.maxX {
                    s.drawGlyph(codepoint: v, font: font, at: Point(x, ty), fg: sel.contains(i) ? theme.selectionText : fg, bg: nil)
                }
                x += guiCellWidth
            }
            if hasFocus && caretOn && !hasSelection {
                s.fill(Rect(ox + cursor * guiCellWidth, ty, 1, font.height), theme.caret)
            }
        }
    }
}
