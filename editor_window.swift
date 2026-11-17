// Phase N2: the text editor's view, a Window driving an EditorModel.
//
// EditorWindow needs no task: the model is event-driven, so handle(_:)
// feeds it keys and clicks directly, then turns model.takeDamage() into a
// set of text rows to repaint (changed lines plus the old and new cursor
// lines, or everything after a scroll, load or resize). draw(), which runs
// inside the compositor flush, paints just those rows and the status line
// and never allocates: everything that allocates (the status-line text, the
// title) is computed in handle(_:).
//
// Layout of the content area, in font cells:
//
//   +------+-----------------------------------+
//   |   1  | text row 0 (from model.leftColumn) |   gutter: line numbers,
//   |   2  | text row 1                         |   right-aligned, at least
//   |  ... | ...                                |   3 digits plus a space
//   +------+-----------------------------------+
//   | /notes.txt [+]  saved 3 lines  Ln 2, Col 5 |   status line (bottom)
//   +-------------------------------------------+
//
// The text cursor is a block (inverted cell) while focused, an outline when
// not, and moves to the status line while the model is prompting.
//
// Quitting: Ctrl-Q (model .quit) removes the window from its WM. The close
// box / Alt-F4 call close(): a clean buffer closes at once; a dirty one
// gets the model's "save changes? (y/n/esc)" prompt and close() returns
// false, and the answer later quits (removing the window) or not.
//
// The window keeps an unowned(unsafe) reference to the WM that shows it
// (set by openEditorWindow) to remove itself on quit: there is no `weak` in
// Embedded Swift and a strong reference would be a retain cycle. The WM
// outlives its windows (shutdown() removes them all first).

/// The editor's colours, in the target surface's pixel format.
struct EditorColors {
    var background: UInt32
    var text: UInt32
    var gutterBG: UInt32
    var gutterText: UInt32
    var statusBG: UInt32
    var statusText: UInt32
    /// The block cursor (the glyph under it is drawn in `background`).
    var cursor: UInt32

    static let rgb = (
        background: UInt32(0x1A1D23), text: UInt32(0xD8DEE9),
        gutterBG: UInt32(0x2B303B), gutterText: UInt32(0x7A8394),
        statusBG: UInt32(0x2E7D32), statusText: UInt32(0xFFFFFF),
        cursor: UInt32(0xFFCC33)
    )

    init(convert: (UInt32) -> UInt32 = { $0 }) {
        let c = EditorColors.rgb
        background = convert(c.background)
        text = convert(c.text)
        gutterBG = convert(c.gutterBG)
        gutterText = convert(c.gutterText)
        statusBG = convert(c.statusBG)
        statusText = convert(c.statusText)
        cursor = convert(c.cursor)
    }
}

final class EditorWindow: Window {
    private(set) var model: EditorModel
    let fs: FileSystem
    let font: PSFFont
    let colors: EditorColors
    /// The WM showing this window (see the header comment).
    unowned(unsafe) var manager: WindowManager?

    // Layout, in cells (relayout()).
    private(set) var gutterCols = 4
    private(set) var textRows = 1
    private(set) var textCols = 1
    private(set) var totalCols = 1

    // What draw() must repaint (filled in by absorb()).
    private var pendingFull = true
    /// Text rows to repaint (sized by relayout, so draw() needn't allocate).
    private var rowDirty: [Bool] = []
    private var statusDirty = true
    /// The status line, exactly totalCols scalars (UTF-8), and where its
    /// caret goes while prompting.
    private var statusText: [UInt8] = []
    private var statusCaret: Int? = nil
    /// The text cursor was drawn in the text area at the last absorb.
    private var cursorInText = true
    private var lastButtons: UInt8 = 0

    /// For tests: text rows the last draw() repainted (bit n = row n, rows
    /// past 63 not recorded), whether it was a full repaint and whether it
    /// repainted the status line; draw() calls so far.
    private(set) var paintedRows: UInt64 = 0
    private(set) var paintedFull = false
    private(set) var paintedStatus = false
    private(set) var draws = 0

    /// An editor of `cols` x `rows` text cells (plus gutter and status
    /// line). Open a file with load(_:) (or use openEditorWindow).
    init(font: PSFFont, fs: FileSystem, cwd: String = "/", colors: EditorColors = EditorColors(),
         cols: Int = 76, rows: Int = 24) {
        self.font = font
        self.fs = fs
        self.colors = colors
        model = EditorModel(rows: rows, cols: cols)
        model.cwd = cwd
        let gutter = EditorWindow.gutterColumns(lines: 1)
        super.init(title: "untitled", contentWidth: (cols + gutter) * font.width,
                   contentHeight: (rows + 1) * font.height)
        minContentWidth = (gutter + 8) * font.width
        minContentHeight = 3 * font.height
        content.fill(colors.background)
        relayout()
        absorb()
    }

    /// Load `path` (relative to the model's cwd). False if it can't be
    /// opened (e.g. a directory); the reason is in model.message.
    @discardableResult
    func load(_ path: String) -> Bool {
        let ok = model.open(path, fs: fs)
        absorb()
        return ok
    }

    // MARK: Layout

    /// Gutter width for `lines` lines: the digits (at least 3) and a space.
    static func gutterColumns(lines: Int) -> Int {
        var digits = 1, n = max(lines, 1)
        while n >= 10 { n /= 10; digits += 1 }
        return max(digits, 3) + 1
    }

    /// Recompute the cell layout from the content size and line count, and
    /// tell the model its viewport (which asks for a full redraw).
    private func relayout() {
        let cw = font.width, ch = font.height
        totalCols = max(content.width / cw, 1)
        textRows = max(content.height / ch - 1, 1)
        gutterCols = EditorWindow.gutterColumns(lines: model.buffer.lineCount)
        textCols = max(totalCols - gutterCols, 1)
        model.resize(rows: textRows, cols: textCols)
        if rowDirty.count != textRows { rowDirty = Array(repeating: false, count: textRows) }
        pendingFull = true
    }

    /// y of the status line (the bottom cell row of the content).
    private var statusY: Int { max(content.height - font.height, 0) }

    // MARK: Events

    override func handle(_ event: Event) {
        switch event {
        case .key(let k):
            if model.handle(k, fs: fs) == .quit {
                quit()
                return
            }
            absorb()
        case .mouse(let x, let y, let b):
            let pressed = b & 1 != 0 && lastButtons & 1 == 0
            lastButtons = b
            guard pressed, model.prompt == .none else { return }
            click(x: x, y: y)
        case .focus:
            markRow(model.cursorCell.row)
            setNeedsDraw()
        case .resize:
            relayout()
            absorb()
        default:
            break // .close comes through close(); no task to tell
        }
    }

    /// A left click at content-local (x, y): place the cursor there (a
    /// click in the gutter goes to the start of the line).
    func click(x: Int, y: Int) {
        let row = y / font.height
        guard x >= 0, y >= 0, row < textRows else { return }
        model.click(row: row, col: max(x / font.width - gutterCols, 0))
        absorb()
    }

    override func close() -> Bool {
        guard model.dirty else { return true }
        if model.prompt != .saveBeforeQuit {
            if model.prompt != .none { _ = model.handle(Key(.char(0x1B)), fs: fs) } // drop other prompts
            _ = model.handle(Key(.char(0x11)), fs: fs) // Ctrl-Q: asks "save changes?"
        }
        absorb()
        return false
    }

    /// The model said quit: leave the screen.
    private func quit() {
        if let wm = manager { wm.remove(self) }
    }

    // MARK: Damage

    private func markRow(_ r: Int) {
        if r >= 0 && r < rowDirty.count { rowDirty[r] = true }
    }

    /// Fold the model's damage into what draw() repaints, and refresh the
    /// status line and title. May allocate (runs from handle, not draw).
    private func absorb() {
        // A line count crossing a power of ten widens the gutter.
        if EditorWindow.gutterColumns(lines: model.buffer.lineCount) != gutterCols { relayout() }
        let d = model.takeDamage()
        if d.full { pendingFull = true }
        if !pendingFull {
            if let lines = d.lines {
                let lo = max(lines.lowerBound, model.topLine) - model.topLine
                let hi = min(lines.upperBound, model.topLine + textRows) - model.topLine
                if lo < hi { for r in lo..<hi { markRow(r) } }
            }
            if let r = model.row(ofLine: d.oldCursorLine) { markRow(r) }
            if let r = model.row(ofLine: d.cursorLine) { markRow(r) }
            let inText = model.prompt == .none
            if inText != cursorInText { markRow(model.cursorCell.row) }
        }
        cursorInText = model.prompt == .none
        let s = Array(model.statusLine(width: totalCols).utf8)
        let caret = model.statusCursorColumn(width: totalCols)
        if s != statusText || caret != statusCaret {
            statusText = s
            statusCaret = caret
            statusDirty = true
        }
        let t = windowTitle
        if t != title { title = t }
        setNeedsDraw()
    }

    /// "/notes.txt", "/notes.txt [+]" when modified, or "untitled".
    var windowTitle: String {
        let name = model.path.isEmpty ? "untitled" : model.path
        return model.dirty ? name + " [+]" : name
    }

    // MARK: Drawing (never allocates)

    override func draw() {
        draws += 1
        paintedRows = 0
        paintedStatus = false
        paintedFull = pendingFull
        if pendingFull {
            content.fill(colors.background)
            for r in 0..<textRows { paintRow(r) }
            statusDirty = true
            invalidate()
        } else {
            for r in 0..<rowDirty.count where rowDirty[r] { paintRow(r) }
        }
        if statusDirty { paintStatus() }
        for r in 0..<rowDirty.count { rowDirty[r] = false }
        pendingFull = false
        statusDirty = false
    }

    /// Repaint text row `r`: its line number, its visible text, the cursor.
    private func paintRow(_ r: Int) {
        guard r >= 0 && r < textRows else { return }
        if r < 64 { paintedRows |= UInt64(1) << UInt64(r) }
        let cw = font.width, ch = font.height, y = r * ch
        let gutterW = gutterCols * cw
        content.fill(Rect(0, y, gutterW, ch), colors.gutterBG)
        content.fill(Rect(gutterW, y, content.width - gutterW, ch), colors.background)
        let line = model.topLine + r
        if line < model.buffer.lineCount {
            // Line number, right-aligned before the gutter's last column.
            var n = line + 1, col = gutterCols - 2
            repeat {
                content.drawGlyph(codepoint: UInt32(0x30 + n % 10), font: font, at: Point(col * cw, y),
                                  fg: colors.gutterText, bg: colors.gutterBG)
                n /= 10
                col -= 1
            } while n > 0 && col >= 0
        }
        let cursor = model.cursorCell
        let cursorCol = cursorInText && cursor.row == r && cursor.col >= 0 && cursor.col < textCols ? cursor.col : -1
        var col = 0
        if let text = model.visibleText(row: r) {
            forEachScalar(text) { cp in
                let c = cp < 0x20 || cp == 0x7F ? 0x20 : cp // tabs and controls show as blanks
                let block = col == cursorCol && focused
                content.drawGlyph(codepoint: c, font: font, at: Point(gutterW + col * cw, y),
                                  fg: block ? colors.background : colors.text,
                                  bg: block ? colors.cursor : colors.background)
                col += 1
            }
        }
        if cursorCol >= 0 {
            let cell = Rect(gutterW + cursorCol * cw, y, cw, ch)
            if !focused {
                content.frame(cell, colors.cursor)
            } else if cursorCol >= col {
                content.fill(cell, colors.cursor) // past the end of the line
            }
        }
        invalidate(Rect(0, y, content.width, ch))
    }

    private func paintStatus() {
        paintedStatus = true
        let cw = font.width, ch = font.height, y = statusY
        let r = Rect(0, y, content.width, content.height - y)
        content.fill(r, colors.statusBG)
        var col = 0
        let caret = statusCaret ?? -1
        forEachScalar(statusText[...]) { cp in
            let block = col == caret
            content.drawGlyph(codepoint: cp, font: font, at: Point(col * cw, y),
                              fg: block ? colors.statusBG : colors.statusText,
                              bg: block ? colors.statusText : colors.statusBG)
            col += 1
        }
        if caret >= col { content.fill(Rect(caret * cw, y, cw, ch), colors.statusText) }
        invalidate(r)
    }
}

/// Call `body` with each Unicode scalar value in UTF-8 `bytes` (malformed
/// sequences give U+FFFD). Never allocates.
func forEachScalar(_ bytes: ArraySlice<UInt8>, _ body: (UInt32) -> Void) {
    var i = bytes.startIndex
    while i < bytes.endIndex {
        let lead = bytes[i]
        let n = utf8SequenceLength(lead)
        var cp: UInt32
        switch n {
        case 2: cp = UInt32(lead & 0x1F)
        case 3: cp = UInt32(lead & 0x0F)
        case 4: cp = UInt32(lead & 0x07)
        default: cp = lead < 0x80 ? UInt32(lead) : 0xFFFD
        }
        var j = i + 1
        if n > 1 {
            while j < bytes.endIndex && j < i + n && isUTF8Continuation(bytes[j]) {
                cp = cp << 6 | UInt32(bytes[j] & 0x3F)
                j += 1
            }
            if j - i != n { cp = 0xFFFD }
        }
        body(cp)
        i = j
    }
}

// MARK: Opening editors

/// Open an editor window on `wm`: `path` loaded (relative to `cwd`) or an
/// untitled buffer. Returns nil (and the reason) if the file can't be
/// opened.
@discardableResult
func openEditorWindow(_ wm: WindowManager, path: String?, fs: FileSystem = vfs, cwd: String = "/",
                      colors: EditorColors? = nil) -> (window: EditorWindow?, message: String) {
    let w = EditorWindow(font: wm.theme.font, fs: fs, cwd: cwd,
                         colors: colors ?? EditorColors(convert: { display?.color($0) ?? $0 }))
    if let path, !w.load(path) { return (nil, w.model.message) }
    w.manager = wm
    wm.add(w)
    return (w, w.model.message)
}

extension Shell {
    static func editorCommands() -> [Command<T>] {
        [
            Command(name: "edit", args: "<path>", help: "edit a file in a new window (desktop only)") { sh, args in
                guard let wm = windowManager else {
                    sh.say("edit: run `desktop` first")
                    return
                }
                guard args.count <= 1 else {
                    sh.say("usage: edit [path]")
                    return
                }
                let r = openEditorWindow(wm, path: args.first.map { String($0) }, fs: sh.fs, cwd: sh.cwd)
                if let w = r.window {
                    sh.say("edit: window #\(w.id): \(r.message.isEmpty ? w.windowTitle : r.message)")
                } else {
                    sh.say("edit: \(r.message)")
                }
            },
        ]
    }
}
