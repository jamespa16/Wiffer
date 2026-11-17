// Phase N1: the text editor's buffer model.
//
// Lines of UTF-8 bytes (no "\n" stored), a cursor in bytes that always sits
// on a scalar boundary, and a "desired column" (in scalars) that vertical
// movement aims for, so moving through a short line and on to a long one
// lands back where it started. Columns shown to people (and used by the
// view) are scalar counts: the PSF font draws one cell per scalar.
//
// The buffer also records which lines changed since the view last asked
// (`takeChangedLines`), so the editor window can redraw only those rows.

/// A place in a TextBuffer: line index and byte offset within the line.
struct TextPosition: Comparable {
    var line: Int
    var column: Int

    init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    static func < (a: TextPosition, b: TextPosition) -> Bool {
        a.line < b.line || (a.line == b.line && a.column < b.column)
    }
}

/// Is `b` a UTF-8 continuation byte (10xxxxxx)?
@inline(__always)
func isUTF8Continuation(_ b: UInt8) -> Bool { b & 0xC0 == 0x80 }

/// The UTF-8 encoding of `scalar`.
func utf8Bytes(_ scalar: Unicode.Scalar) -> [UInt8] {
    let v = scalar.value
    if v < 0x80 { return [UInt8(v)] }
    if v < 0x800 { return [UInt8(0xC0 | (v >> 6)), UInt8(0x80 | (v & 0x3F))] }
    if v < 0x10000 {
        return [UInt8(0xE0 | (v >> 12)), UInt8(0x80 | ((v >> 6) & 0x3F)), UInt8(0x80 | (v & 0x3F))]
    }
    return [UInt8(0xF0 | (v >> 18)), UInt8(0x80 | ((v >> 12) & 0x3F)),
            UInt8(0x80 | ((v >> 6) & 0x3F)), UInt8(0x80 | (v & 0x3F))]
}

/// Bytes in the UTF-8 sequence that `lead` starts (1 for ASCII and for
/// bytes that can't start a sequence).
func utf8SequenceLength(_ lead: UInt8) -> Int {
    if lead & 0xE0 == 0xC0 { return 2 }
    if lead & 0xF0 == 0xE0 { return 3 }
    if lead & 0xF8 == 0xF0 { return 4 }
    return 1
}

struct TextBuffer {
    /// Never empty: an empty buffer is one empty line.
    private(set) var lines: [[UInt8]] = [[]]
    private(set) var cursor = TextPosition(line: 0, column: 0)
    /// Scalar column that up/down movement aims for.
    private(set) var desiredColumn = 0
    /// Changed since load or the last save.
    private(set) var dirty = false
    /// The file ended with "\n" (saved files keep that).
    var endsWithNewline = false
    /// The file was empty when loaded: once it has text, save adds a final
    /// "\n" (the usual convention for a new file).
    private var startedEmpty = true
    /// Lines changed since the last takeChangedLines(); its upper bound can
    /// pass `lines.count` when lines were removed (those rows need clearing).
    private var changed: Range<Int>? = nil

    static let tabWidth = 4

    init() {}

    init(_ bytes: [UInt8]) { load(bytes) }

    var lineCount: Int { lines.count }

    var currentLine: [UInt8] { lines[cursor.line] }

    // MARK: Load and save

    /// Replace the contents with `bytes` (split on "\n"); cursor to the
    /// start, clean.
    mutating func load(_ bytes: [UInt8]) {
        let old = lines.count
        lines = []
        var current: [UInt8] = []
        for b in bytes {
            if b == 0x0A {
                lines.append(current)
                current = []
            } else {
                current.append(b)
            }
        }
        endsWithNewline = bytes.last == 0x0A
        // "a\nb" ends with the "b" line; "a\nb\n" has no empty line after it.
        if !endsWithNewline || lines.isEmpty { lines.append(current) }
        startedEmpty = bytes.isEmpty
        cursor = TextPosition(line: 0, column: 0)
        desiredColumn = 0
        dirty = false
        changed = 0..<max(old, lines.count)
    }

    /// The contents as file bytes. Clears `dirty`.
    mutating func save() -> [UInt8] {
        var out: [UInt8] = []
        for (i, l) in lines.enumerated() {
            if i > 0 { out.append(0x0A) }
            out += l
        }
        if endsWithNewline || (startedEmpty && !out.isEmpty) {
            out.append(0x0A)
            endsWithNewline = true
        }
        startedEmpty = out.isEmpty
        dirty = false
        return out
    }

    /// The bytes save() would return, without clearing `dirty`.
    var contents: [UInt8] {
        var copy = self
        return copy.save()
    }

    // MARK: Columns

    /// Scalars before byte `column` of `line` (the on-screen column).
    func displayColumn(line: Int, column: Int) -> Int {
        var n = 0
        let l = lines[line]
        var i = 0
        while i < column && i < l.count {
            if !isUTF8Continuation(l[i]) { n += 1 }
            i += 1
        }
        return n
    }

    /// The cursor's on-screen column (0-based).
    var cursorDisplayColumn: Int { displayColumn(line: cursor.line, column: cursor.column) }

    /// Byte offset of scalar column `display` in `line` (clamped to the end).
    func byteColumn(line: Int, display: Int) -> Int {
        let l = lines[line]
        var i = 0, n = 0
        while i < l.count {
            if !isUTF8Continuation(l[i]) {
                if n == display { return i }
                n += 1
            }
            i += 1
        }
        return l.count
    }

    /// Scalars in `line`.
    func displayWidth(line: Int) -> Int { displayColumn(line: line, column: lines[line].count) }

    private func previousBoundary(_ line: Int, _ column: Int) -> Int {
        let l = lines[line]
        var i = column - 1
        while i > 0 && isUTF8Continuation(l[i]) { i -= 1 }
        return max(i, 0)
    }

    private func nextBoundary(_ line: Int, _ column: Int) -> Int {
        let l = lines[line]
        var i = column + 1
        while i < l.count && isUTF8Continuation(l[i]) { i += 1 }
        return min(i, l.count)
    }

    // MARK: Changed lines

    private mutating func markChanged(_ r: Range<Int>) {
        if let c = changed {
            changed = min(c.lowerBound, r.lowerBound)..<max(c.upperBound, r.upperBound)
        } else {
            changed = r
        }
    }

    /// Lines changed since the last call (nil if none), then forget them.
    /// The upper bound may exceed lineCount: rows past the end were lines
    /// that are gone.
    mutating func takeChangedLines() -> Range<Int>? {
        defer { changed = nil }
        return changed
    }

    /// Lines changed since the last takeChangedLines(), without clearing.
    var changedLines: Range<Int>? { changed }

    // MARK: Cursor

    /// Put the cursor at `p`, clamped to the text and moved back onto a
    /// scalar boundary.
    mutating func setCursor(_ p: TextPosition) {
        let line = min(max(p.line, 0), lines.count - 1)
        var col = min(max(p.column, 0), lines[line].count)
        while col > 0 && col < lines[line].count && isUTF8Continuation(lines[line][col]) { col -= 1 }
        cursor = TextPosition(line: line, column: col)
        desiredColumn = cursorDisplayColumn
    }

    /// Cursor to scalar column `display` of `line` (e.g. for a mouse click).
    mutating func setCursor(line: Int, display: Int) {
        let l = min(max(line, 0), lines.count - 1)
        setCursor(TextPosition(line: l, column: byteColumn(line: l, display: max(display, 0))))
    }

    private mutating func moveVertically(to line: Int) {
        let l = min(max(line, 0), lines.count - 1)
        cursor = TextPosition(line: l, column: byteColumn(line: l, display: desiredColumn))
    }

    /// One scalar left; from the start of a line, to the end of the one above.
    mutating func moveLeft() {
        if cursor.column > 0 {
            cursor.column = previousBoundary(cursor.line, cursor.column)
        } else if cursor.line > 0 {
            cursor.line -= 1
            cursor.column = lines[cursor.line].count
        }
        desiredColumn = cursorDisplayColumn
    }

    /// One scalar right; from the end of a line, to the start of the next.
    mutating func moveRight() {
        if cursor.column < lines[cursor.line].count {
            cursor.column = nextBoundary(cursor.line, cursor.column)
        } else if cursor.line < lines.count - 1 {
            cursor.line += 1
            cursor.column = 0
        }
        desiredColumn = cursorDisplayColumn
    }

    mutating func moveUp(_ n: Int = 1) { moveVertically(to: cursor.line - n) }
    mutating func moveDown(_ n: Int = 1) { moveVertically(to: cursor.line + n) }

    mutating func moveHome() {
        cursor.column = 0
        desiredColumn = 0
    }

    mutating func moveEnd() {
        cursor.column = lines[cursor.line].count
        desiredColumn = cursorDisplayColumn
    }

    /// Up or down a page of `rows` lines (keeps the desired column).
    mutating func pageUp(_ rows: Int) { moveUp(max(rows, 1)) }
    mutating func pageDown(_ rows: Int) { moveDown(max(rows, 1)) }

    mutating func moveToStart() { setCursor(TextPosition(line: 0, column: 0)) }

    mutating func moveToEnd() {
        let last = lines.count - 1
        setCursor(TextPosition(line: last, column: lines[last].count))
    }

    // MARK: Editing

    /// Insert raw UTF-8 bytes (one or more whole scalars, no "\n") at the cursor.
    mutating func insert(bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        lines[cursor.line].insert(contentsOf: bytes, at: cursor.column)
        cursor.column += bytes.count
        desiredColumn = cursorDisplayColumn
        dirty = true
        markChanged(cursor.line..<cursor.line + 1)
    }

    /// Insert one scalar; "\n" splits the line and "\t" inserts spaces.
    mutating func insert(_ scalar: Unicode.Scalar) {
        switch scalar.value {
        case 0x0A: insertNewline()
        case 0x09: insertTab()
        default: insert(bytes: utf8Bytes(scalar))
        }
    }

    /// Spaces up to the next multiple of tabWidth.
    mutating func insertTab() {
        let n = TextBuffer.tabWidth - cursorDisplayColumn % TextBuffer.tabWidth
        insert(bytes: [UInt8](repeating: 0x20, count: n))
    }

    /// Split the line at the cursor; the cursor goes to the start of the new line.
    mutating func insertNewline() {
        splitLine(at: cursor)
        cursor = TextPosition(line: cursor.line + 1, column: 0)
        desiredColumn = 0
    }

    /// Split line `p.line` at byte `p.column` (the cursor stays put unless it
    /// was after the split point on that line).
    mutating func splitLine(at p: TextPosition) {
        let l = lines[p.line]
        let col = min(p.column, l.count)
        lines[p.line] = Array(l[..<col])
        lines.insert(Array(l[col...]), at: p.line + 1)
        if cursor.line > p.line {
            cursor.line += 1
        } else if cursor.line == p.line && cursor.column > col {
            cursor = TextPosition(line: p.line + 1, column: cursor.column - col)
        }
        dirty = true
        markChanged(p.line..<lines.count)
    }

    /// Append line `line + 1` to `line` (no-op on the last line). A cursor
    /// on the removed line moves with its text.
    mutating func joinLines(at line: Int) {
        guard line >= 0 && line + 1 < lines.count else { return }
        let joinColumn = lines[line].count
        let oldCount = lines.count
        lines[line] += lines[line + 1]
        lines.remove(at: line + 1)
        if cursor.line == line + 1 {
            cursor = TextPosition(line: line, column: joinColumn + cursor.column)
        } else if cursor.line > line + 1 {
            cursor.line -= 1
        }
        dirty = true
        markChanged(line..<oldCount)
    }

    /// Delete the scalar before the cursor, or join with the line above.
    mutating func backspace() {
        if cursor.column > 0 {
            let start = previousBoundary(cursor.line, cursor.column)
            lines[cursor.line].removeSubrange(start..<cursor.column)
            cursor.column = start
            dirty = true
            markChanged(cursor.line..<cursor.line + 1)
        } else if cursor.line > 0 {
            joinLines(at: cursor.line - 1)
        }
        desiredColumn = cursorDisplayColumn
    }

    /// Delete the scalar at the cursor, or join the next line onto this one.
    mutating func deleteForward() {
        if cursor.column < lines[cursor.line].count {
            let end = nextBoundary(cursor.line, cursor.column)
            lines[cursor.line].removeSubrange(cursor.column..<end)
            dirty = true
            markChanged(cursor.line..<cursor.line + 1)
        } else {
            joinLines(at: cursor.line)
        }
        desiredColumn = cursorDisplayColumn
    }

    // MARK: Find

    /// The first match of `needle` (within one line) at or after `from`,
    /// wrapping past the end to the start of the buffer. nil if there is
    /// none (or `needle` is empty or contains "\n").
    func find(_ needle: [UInt8], from: TextPosition) -> TextPosition? {
        guard !needle.isEmpty, !needle.contains(0x0A) else { return nil }
        let start = min(max(from.line, 0), lines.count - 1)
        // Every line once, starting with `start` from `from.column`, then
        // `start` again up to `from.column` (the wrapped part).
        for step in 0...lines.count {
            let li = (start + step) % lines.count
            let l = lines[li]
            let lo = step == 0 ? max(from.column, 0) : 0
            let hi = step == lines.count ? min(from.column + needle.count - 1, l.count) : l.count
            guard hi - lo >= needle.count else { continue }
            var i = lo
            while i + needle.count <= hi {
                if l[i] == needle[0] && l[i..<i + needle.count].elementsEqual(needle) {
                    return TextPosition(line: li, column: i)
                }
                i += 1
            }
        }
        return nil
    }
}
