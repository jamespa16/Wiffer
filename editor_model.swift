// Phase N3: the text editor's key handling, as a plain struct.
//
// EditorModel owns a TextBuffer, the file's path, the viewport (first
// visible line and column, and how many rows and columns of text fit), a
// status message and the status-line prompt. It knows nothing about
// windows: the EditorWindow view (Phase N2) feeds it keys, asks
// takeDamage() what to redraw and draws visibleText(row:) plus
// statusLine(width:). Selftests drive it with scripted keys.
//
// Keys (control codes are matched with or without `ctrl`, so serial input,
// which has no modifiers, works too):
//   arrows, Home/End           move            PgUp/PgDn   a screenful
//   Ctrl-Home / Ctrl-End       start/end of file
//   Ctrl-S save   Ctrl-O open (prompt)   Ctrl-F find (prompt; Enter on an
//   empty prompt repeats the last search)   Ctrl-Q quit (asks
//   "save changes? (y/n/esc)" when dirty)   Esc clears the message.

enum EditorAction: Equatable {
    /// Nothing visible changed.
    case none
    /// Something changed: call takeDamage() and draw.
    case redraw
    /// Close the editor.
    case quit
}

/// What the status line is asking for.
enum EditorPrompt: Equatable {
    case none
    case open
    case find
    case saveAs
    /// "save changes? (y/n/esc)" before quitting.
    case saveBeforeQuit
}

/// What to redraw since the last takeDamage().
struct EditorDamage: Equatable {
    /// Redraw every row (scrolled, loaded or resized).
    var full: Bool
    /// Buffer lines whose text changed. The upper bound can pass the line
    /// count: those rows held lines that are gone and need clearing.
    var lines: Range<Int>?
    /// The cursor's line at the last draw (repaint it without the cursor)...
    var oldCursorLine: Int
    /// ...and now.
    var cursorLine: Int
}

struct EditorModel {
    var buffer = TextBuffer()
    /// Absolute path, or "" for a buffer that has never been saved.
    private(set) var path = ""
    /// Relative paths typed at the prompts are resolved against this.
    var cwd = "/"

    // Viewport, in buffer lines and scalar columns.
    private(set) var topLine = 0
    private(set) var leftColumn = 0
    private(set) var rows: Int
    private(set) var cols: Int

    /// Shown in the status line until the next key.
    var message = ""
    private(set) var prompt = EditorPrompt.none
    /// UTF-8 typed at the prompt so far.
    private(set) var promptInput: [UInt8] = []
    private(set) var lastSearch: [UInt8] = []

    /// A multi-byte UTF-8 scalar arriving one byte per key (serial input).
    private var pendingUTF8: [UInt8] = []
    /// The save-as prompt came from "save changes? y": quit once saved.
    private var quitAfterSave = false
    private var fullRedraw = true
    private var drawnCursorLine = 0

    init(rows: Int, cols: Int) {
        self.rows = max(rows, 1)
        self.cols = max(cols, 1)
    }

    var cursor: TextPosition { buffer.cursor }
    var dirty: Bool { buffer.dirty }

    // MARK: Files

    /// Load `path` (resolved against cwd). A missing file opens as a new,
    /// empty buffer with that path; other errors leave the buffer alone.
    @discardableResult
    mutating func open(_ path: String, fs: FileSystem) -> Bool {
        let p = FileSystem.normalize(path, cwd: cwd)
        do throws(FSError) {
            let bytes = try fs.read(p)
            buffer.load(bytes)
            message = "\(p): \(EditorModel.lineCount(bytes)) lines"
        } catch {
            guard error == .notFound else {
                message = "open: \(p): \(error.message)"
                return false
            }
            buffer.load([])
            message = "\(p): new file"
        }
        self.path = p
        topLine = 0
        leftColumn = 0
        fullRedraw = true
        return true
    }

    /// Write the buffer to `path` ("saved N lines"). With no path yet, asks
    /// for one first and returns false.
    @discardableResult
    mutating func save(fs: FileSystem) -> Bool {
        guard !path.isEmpty else {
            begin(.saveAs)
            return false
        }
        let bytes = buffer.contents
        do throws(FSError) {
            try fs.write(path, bytes)
        } catch {
            message = "save: \(path): \(error.message)"
            return false
        }
        _ = buffer.save() // clears dirty
        message = "saved \(EditorModel.lineCount(bytes)) lines"
        return true
    }

    /// Lines in file bytes (a final line without "\n" counts).
    static func lineCount(_ bytes: [UInt8]) -> Int {
        var n = 0
        for b in bytes where b == 0x0A { n += 1 }
        if let last = bytes.last, last != 0x0A { n += 1 }
        return n
    }

    // MARK: Viewport

    /// The text area is `rows` x `cols` cells (gutter and status line excluded).
    mutating func resize(rows: Int, cols: Int) {
        self.rows = max(rows, 1)
        self.cols = max(cols, 1)
        fullRedraw = true
        scrollToCursor()
    }

    /// Scroll so the cursor is inside the viewport.
    mutating func scrollToCursor() {
        let oldTop = topLine, oldLeft = leftColumn
        let line = buffer.cursor.line
        if line < topLine { topLine = line }
        if line >= topLine + rows { topLine = line - rows + 1 }
        let col = buffer.cursorDisplayColumn
        if col < leftColumn { leftColumn = col }
        if col >= leftColumn + cols { leftColumn = col - cols + 1 }
        if topLine != oldTop || leftColumn != oldLeft { fullRedraw = true }
    }

    /// Text-area row of buffer line `line`, if it's on screen.
    func row(ofLine line: Int) -> Int? {
        line >= topLine && line < topLine + rows ? line - topLine : nil
    }

    /// The bytes to draw on text row `row`: the line from leftColumn, at most
    /// `cols` scalars. nil past the end of the buffer.
    func visibleText(row: Int) -> ArraySlice<UInt8>? {
        let line = topLine + row
        guard row >= 0 && row < rows && line < buffer.lineCount else { return nil }
        let start = buffer.byteColumn(line: line, display: leftColumn)
        let end = buffer.byteColumn(line: line, display: leftColumn + cols)
        return buffer.lines[line][start..<end]
    }

    /// The cursor's cell in the text area.
    var cursorCell: (row: Int, col: Int) {
        (buffer.cursor.line - topLine, buffer.cursorDisplayColumn - leftColumn)
    }

    /// Cursor to a text-area cell (a mouse click).
    mutating func click(row: Int, col: Int) {
        buffer.setCursor(line: topLine + max(row, 0), display: leftColumn + max(col, 0))
        scrollToCursor()
    }

    /// What changed since the last call; the view redraws exactly that
    /// (plus the status line).
    mutating func takeDamage() -> EditorDamage {
        let d = EditorDamage(full: fullRedraw, lines: buffer.takeChangedLines(),
                             oldCursorLine: drawnCursorLine, cursorLine: buffer.cursor.line)
        fullRedraw = false
        drawnCursorLine = buffer.cursor.line
        return d
    }

    // MARK: Keys

    mutating func handle(_ key: Key, fs: FileSystem) -> EditorAction {
        let action: EditorAction
        switch prompt {
        case .none: action = handleEdit(key, fs: fs)
        case .saveBeforeQuit: action = handleQuitPrompt(key, fs: fs)
        default: action = handlePrompt(key, fs: fs)
        }
        if action != .quit { scrollToCursor() }
        return action
    }

    private mutating func handleEdit(_ key: Key, fs: FileSystem) -> EditorAction {
        if case .char(let c) = key.code, c >= 0x80, !key.alt, !key.meta {
            return typeUTF8(c) ? .redraw : .none
        }
        pendingUTF8 = []
        let hadMessage = !message.isEmpty
        message = ""
        switch key.code {
        case .char(let c):
            switch c {
            case 0x0D, 0x0A: buffer.insertNewline()
            case 0x08, 0x7F: buffer.backspace()
            case 0x09: buffer.insertTab()
            case 0x1B: return hadMessage ? .redraw : .none
            case 0x13: save(fs: fs) // Ctrl-S
            case 0x0F: // Ctrl-O
                if buffer.dirty {
                    message = "unsaved changes: Ctrl-S first"
                } else {
                    begin(.open)
                }
            case 0x06: begin(.find) // Ctrl-F
            case 0x11: // Ctrl-Q
                guard buffer.dirty else { return .quit }
                begin(.saveBeforeQuit)
            case 0x20..<0x7F:
                if key.alt || key.meta { return hadMessage ? .redraw : .none }
                buffer.insert(bytes: [c])
            default: return hadMessage ? .redraw : .none
            }
        case .left: buffer.moveLeft()
        case .right: buffer.moveRight()
        case .up: buffer.moveUp()
        case .down: buffer.moveDown()
        case .home: if key.ctrl { buffer.moveToStart() } else { buffer.moveHome() }
        case .end: if key.ctrl { buffer.moveToEnd() } else { buffer.moveEnd() }
        case .pageUp: page(-rows)
        case .pageDown: page(rows)
        case .delete: buffer.deleteForward()
        default: return hadMessage ? .redraw : .none
        }
        return .redraw
    }

    /// Collect a multi-byte scalar; insert it once complete. Stray
    /// continuation bytes are dropped.
    private mutating func typeUTF8(_ b: UInt8) -> Bool {
        if isUTF8Continuation(b) {
            guard !pendingUTF8.isEmpty else { return false }
            pendingUTF8.append(b)
        } else {
            pendingUTF8 = utf8SequenceLength(b) > 1 ? [b] : []
            return false
        }
        guard pendingUTF8.count == utf8SequenceLength(pendingUTF8[0]) else { return false }
        message = ""
        buffer.insert(bytes: pendingUTF8)
        pendingUTF8 = []
        return true
    }

    /// Move the cursor and the view by `delta` lines.
    private mutating func page(_ delta: Int) {
        let maxTop = max(buffer.lineCount - rows, 0)
        let newTop = min(max(topLine + delta, 0), maxTop)
        if newTop != topLine {
            topLine = newTop
            fullRedraw = true
        }
        if delta < 0 { buffer.pageUp(-delta) } else { buffer.pageDown(delta) }
    }

    private mutating func begin(_ p: EditorPrompt) {
        prompt = p
        promptInput = []
    }

    private mutating func endPrompt() {
        prompt = .none
        promptInput = []
        quitAfterSave = false
    }

    /// Typing at the open / find / save-as prompt.
    private mutating func handlePrompt(_ key: Key, fs: FileSystem) -> EditorAction {
        guard case .char(let c) = key.code else { return .none }
        switch c {
        case 0x1B: // Esc
            endPrompt()
            message = ""
        case 0x08, 0x7F:
            while let last = promptInput.popLast(), isUTF8Continuation(last) {}
        case 0x0D, 0x0A:
            return commitPrompt(fs: fs)
        case 0x20..<0x7F, 0x80...0xFF:
            if key.alt || key.meta { return .none }
            promptInput.append(c)
        default:
            return .none
        }
        return .redraw
    }

    private mutating func commitPrompt(fs: FileSystem) -> EditorAction {
        let kind = prompt
        let input = promptInput
        let quit = quitAfterSave
        endPrompt()
        switch kind {
        case .open:
            if !input.isEmpty { open(String(decoding: input, as: UTF8.self), fs: fs) }
        case .find:
            if !input.isEmpty { lastSearch = input }
            findNext()
        case .saveAs:
            guard !input.isEmpty else { break }
            path = FileSystem.normalize(String(decoding: input, as: UTF8.self), cwd: cwd)
            if save(fs: fs) && quit { return .quit }
        default:
            break
        }
        return .redraw
    }

    /// Jump to the next match of lastSearch after the cursor (wrapping).
    mutating func findNext() {
        guard !lastSearch.isEmpty else { return }
        let needle = String(decoding: lastSearch, as: UTF8.self)
        let after = TextPosition(line: buffer.cursor.line, column: buffer.cursor.column + 1)
        guard let p = buffer.find(lastSearch, from: after) else {
            message = "not found: \(needle)"
            return
        }
        message = p < after ? "wrapped: \(needle)" : ""
        buffer.setCursor(p)
    }

    /// "save changes? (y/n/esc)".
    private mutating func handleQuitPrompt(_ key: Key, fs: FileSystem) -> EditorAction {
        guard case .char(let c) = key.code else { return .none }
        switch c {
        case 0x79, 0x59: // y
            endPrompt()
            if path.isEmpty {
                begin(.saveAs)
                quitAfterSave = true
                return .redraw
            }
            return save(fs: fs) ? .quit : .redraw
        case 0x6E, 0x4E: // n
            endPrompt()
            return .quit
        case 0x1B:
            endPrompt()
            message = ""
            return .redraw
        default:
            return .none
        }
    }

    // MARK: Status line

    private var promptLabel: String {
        switch prompt {
        case .none: return ""
        case .open: return "open: "
        case .find:
            return lastSearch.isEmpty ? "find: " : "find [\(String(decoding: lastSearch, as: UTF8.self))]: "
        case .saveAs: return "save as: "
        case .saveBeforeQuit: return "save changes? (y/n/esc) "
        }
    }

    /// The status line, exactly `width` scalars: "path [+]  message ...
    /// Ln x, Col y", or the prompt and what has been typed (its tail, if
    /// it's too long).
    func statusLine(width: Int) -> String {
        guard width > 0 else { return "" }
        if prompt != .none {
            let text = Array(promptLabel.utf8) + promptInput
            let n = scalarCount(text[...])
            return String(decoding: padded(dropScalars(text[...], max(n - (width - 1), 0)), width), as: UTF8.self)
        }
        var left = Array((path.isEmpty ? "[no name]" : path).utf8)
        if buffer.dirty { left += Array(" [+]".utf8) }
        if !message.isEmpty { left += Array("  ".utf8) + Array(message.utf8) }
        let right = Array("Ln \(buffer.cursor.line + 1), Col \(buffer.cursorDisplayColumn + 1)".utf8)
        let rightWidth = scalarCount(right[...])
        let room = width - rightWidth - 1
        guard room > 0 else { return String(decoding: padded(right[...], width), as: UTF8.self) }
        var line = padded(left[...], room)
        line += [0x20] + right
        return String(decoding: line, as: UTF8.self)
    }

    /// Where the text cursor goes in the status line while prompting.
    func statusCursorColumn(width: Int) -> Int? {
        guard prompt != .none else { return nil }
        let n = scalarCount((Array(promptLabel.utf8) + promptInput)[...])
        return min(n, width - 1)
    }
}

private func scalarCount(_ s: ArraySlice<UInt8>) -> Int {
    var n = 0
    for b in s where !isUTF8Continuation(b) { n += 1 }
    return n
}

/// `s` without its first `n` scalars.
private func dropScalars(_ s: ArraySlice<UInt8>, _ n: Int) -> ArraySlice<UInt8> {
    var seen = 0
    var i = s.startIndex
    while i < s.endIndex {
        if !isUTF8Continuation(s[i]) {
            if seen == n { break }
            seen += 1
        }
        i += 1
    }
    return s[i...]
}

/// `s` cut or space-padded to exactly `width` scalars.
private func padded(_ s: ArraySlice<UInt8>, _ width: Int) -> [UInt8] {
    var out: [UInt8] = []
    var n = 0
    var i = s.startIndex
    while i < s.endIndex {
        if !isUTF8Continuation(s[i]) {
            if n == width { break }
            n += 1
        }
        out.append(s[i])
        i += 1
    }
    while n < width {
        out.append(0x20)
        n += 1
    }
    return out
}
