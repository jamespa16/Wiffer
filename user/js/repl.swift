// The REPL: a raw-mode line editor (arrows, Home/End, Ctrl-A/E/U/K/W, history),
// multi-line input while the parse error is "unexpected end of input",
// results printed with jsInspect. Timers keep running while it waits for a
// key; Ctrl-C while a script runs terminates it.

struct JSLineEditor {
    var history: [String] = []
    var buf: [UInt32] = []
    var cursor = 0
    var prompt = "> "
    var histIndex = 0
    var saved: [UInt32] = []
    var esc = 0                      // 0 none, 1 saw ESC, 2 saw ESC [
    var escParam = 0
    var utf8Need = 0
    var utf8Value: UInt32 = 0

    static func encode(_ scalars: ArraySlice<UInt32>) -> [UInt8] {
        var out: [UInt8] = []
        for c in scalars {
            if c < 0x80 { out.append(UInt8(c)) }
            else if c < 0x800 { out.append(UInt8(0xC0 | (c >> 6))); out.append(UInt8(0x80 | (c & 0x3F))) }
            else if c < 0x10000 {
                out.append(UInt8(0xE0 | (c >> 12))); out.append(UInt8(0x80 | ((c >> 6) & 0x3F)))
                out.append(UInt8(0x80 | (c & 0x3F)))
            } else {
                out.append(UInt8(0xF0 | ((c >> 18) & 7))); out.append(UInt8(0x80 | ((c >> 12) & 0x3F)))
                out.append(UInt8(0x80 | ((c >> 6) & 0x3F))); out.append(UInt8(0x80 | (c & 0x3F)))
            }
        }
        return out
    }
}

/// Redraw the whole line: prompt, text, cursor.
func jsReplRedraw(_ sh: JSShell, _ ed: JSLineEditor) {
    var bytes: [UInt8] = [0x0D]
    bytes.append(contentsOf: Array(ed.prompt.utf8))
    bytes.append(contentsOf: JSLineEditor.encode(ed.buf[...]))
    bytes.append(contentsOf: Array("\u{1B}[K".utf8))
    let back = ed.buf.count - ed.cursor
    if back > 0 { bytes.append(contentsOf: Array("\u{1B}[\(back)D".utf8)) }
    sh.flush()
    File.stdout.writeAll(bytes)
}

func jsReplSet(_ ed: inout JSLineEditor, _ text: [UInt32]) {
    ed.buf = text
    ed.cursor = text.count
}

enum JSReadResult {
    case line(String)
    case eof
    case cancel
}

/// Read one line with editing. Runs due timers while waiting.
func jsReadLine(_ sh: JSShell, _ ed: inout JSLineEditor) -> JSReadResult {
    ed.buf = []
    ed.cursor = 0
    ed.histIndex = ed.history.count
    ed.esc = 0
    jsReplRedraw(sh, ed)
    var pending = sh.typeahead
    sh.typeahead = []
    while true {
        if pending.isEmpty {
            // Timers and tasks first, then block for input.
            if let d = sh.loop.nextDeadline() {
                if d <= 0 {
                    File.stdout.writeAll(Array("\r\u{1B}[K".utf8))
                    sh.loop.runDueTasks()
                    sh.flush()
                    jsReplRedraw(sh, ed)
                    continue
                }
            }
            var fds = [WaitFD(fd: 0, events: WaitEvent.readable, revents: 0)]
            var timeout = -1
            if let d = sh.loop.nextDeadline() { timeout = max(1, Int(d.rounded(.up))) }
            let r = wait(&fds, timeoutMs: timeout)
            if r <= 0 { continue }
            guard let chunk = try? File.stdin.read(max: 256) else { return .eof }
            if chunk.isEmpty { return .eof }
            pending = chunk
        }
        let b = pending.removeFirst()
        if ed.esc == 1 {
            if b == 0x5B { ed.esc = 2; ed.escParam = 0; continue }
            ed.esc = 0
            continue
        }
        if ed.esc == 2 {
            if b >= 0x30 && b <= 0x39 { ed.escParam = ed.escParam * 10 + Int(b - 0x30); continue }
            if b == 0x3B { continue }
            ed.esc = 0
            switch b {
            case 0x41: // up
                if ed.histIndex > 0 {
                    if ed.histIndex == ed.history.count { ed.saved = ed.buf }
                    ed.histIndex -= 1
                    jsReplSet(&ed, Array(ed.history[ed.histIndex].unicodeScalars.map { $0.value }))
                }
            case 0x42: // down
                if ed.histIndex < ed.history.count {
                    ed.histIndex += 1
                    if ed.histIndex == ed.history.count { jsReplSet(&ed, ed.saved) }
                    else { jsReplSet(&ed, Array(ed.history[ed.histIndex].unicodeScalars.map { $0.value })) }
                }
            case 0x43: if ed.cursor < ed.buf.count { ed.cursor += 1 }      // right
            case 0x44: if ed.cursor > 0 { ed.cursor -= 1 }                 // left
            case 0x48: ed.cursor = 0                                       // home
            case 0x46: ed.cursor = ed.buf.count                            // end
            case 0x7E:
                if ed.escParam == 3 && ed.cursor < ed.buf.count { ed.buf.remove(at: ed.cursor) }
                else if ed.escParam == 1 { ed.cursor = 0 }
                else if ed.escParam == 4 { ed.cursor = ed.buf.count }
            default: break
            }
            jsReplRedraw(sh, ed)
            continue
        }
        if ed.utf8Need > 0 {
            if b & 0xC0 == 0x80 {
                ed.utf8Value = ed.utf8Value << 6 | UInt32(b & 0x3F)
                ed.utf8Need -= 1
                if ed.utf8Need == 0 && ed.buf.count < 4096 {
                    ed.buf.insert(ed.utf8Value, at: ed.cursor)
                    ed.cursor += 1
                    jsReplRedraw(sh, ed)
                }
                continue
            }
            ed.utf8Need = 0
        }
        switch b {
        case 0x1B: ed.esc = 1
        case 0x0D, 0x0A:
            File.stdout.writeAll([0x0A])
            let line = String(decoding: JSLineEditor.encode(ed.buf[...]), as: UTF8.self)
            return .line(line)
        case 0x03:
            File.stdout.writeAll(Array("^C\n".utf8))
            return .cancel
        case 0x04:
            if ed.buf.isEmpty { File.stdout.writeAll([0x0A]); return .eof }
            if ed.cursor < ed.buf.count { ed.buf.remove(at: ed.cursor) }
            jsReplRedraw(sh, ed)
        case 0x7F, 0x08:
            if ed.cursor > 0 { ed.cursor -= 1; ed.buf.remove(at: ed.cursor) }
            jsReplRedraw(sh, ed)
        case 0x01: ed.cursor = 0; jsReplRedraw(sh, ed)
        case 0x05: ed.cursor = ed.buf.count; jsReplRedraw(sh, ed)
        case 0x0B: ed.buf.removeSubrange(ed.cursor...); jsReplRedraw(sh, ed)
        case 0x15: ed.buf.removeSubrange(0..<ed.cursor); ed.cursor = 0; jsReplRedraw(sh, ed)
        case 0x17:
            var n = ed.cursor
            while n > 0 && ed.buf[n - 1] == 0x20 { n -= 1 }
            while n > 0 && ed.buf[n - 1] != 0x20 { n -= 1 }
            ed.buf.removeSubrange(n..<ed.cursor)
            ed.cursor = n
            jsReplRedraw(sh, ed)
        case 0x0C:
            File.stdout.writeAll(Array("\u{1B}[2J\u{1B}[H".utf8))
            jsReplRedraw(sh, ed)
        case 0x09:
            for _ in 0..<2 where ed.buf.count < 4096 { ed.buf.insert(0x20, at: ed.cursor); ed.cursor += 1 }
            jsReplRedraw(sh, ed)
        case 0x20...0x7E:
            if ed.buf.count < 4096 {
                ed.buf.insert(UInt32(b), at: ed.cursor)
                ed.cursor += 1
                if ed.cursor == ed.buf.count { File.stdout.writeAll([b]) } else { jsReplRedraw(sh, ed) }
            }
        case 0xC2...0xDF: ed.utf8Need = 1; ed.utf8Value = UInt32(b & 0x1F)
        case 0xE0...0xEF: ed.utf8Need = 2; ed.utf8Value = UInt32(b & 0x0F)
        case 0xF0...0xF4: ed.utf8Need = 3; ed.utf8Value = UInt32(b & 0x07)
        default: break
        }
    }
}

func jsRunRepl(_ sh: JSShell) {
    let old = Console.setMode(ConsoleMode.raw | ConsoleMode.passInterrupt)
    sh.watchInterrupt = old >= 0
    File.stdout.writeAll(Array("Wiffer JavaScript. Ctrl-D exits, Ctrl-C stops a running script.\n".utf8))
    var ed = JSLineEditor()
    var pendingSource = ""
    while true {
        ed.prompt = pendingSource.isEmpty ? "> " : "... "
        let r = jsReadLine(sh, &ed)
        var line = ""
        switch r {
        case .eof:
            if old >= 0 { Console.setMode(UInt64(old)) }
            return
        case .cancel:
            pendingSource = ""
            continue
        case .line(let s):
            line = s
        }
        if pendingSource.isEmpty && line.isEmpty { continue }
        if !line.isEmpty && (ed.history.isEmpty || ed.history[ed.history.count - 1] != line) {
            ed.history.append(line)
            if ed.history.count > 200 { ed.history.removeFirst() }
        }
        let source = pendingSource.isEmpty ? line : pendingSource + "\n" + line
        sh.beginTask()
        let c = sh.realm.evaluate(source: source, name: "repl")
        switch c {
        case .normal(let v):
            pendingSource = ""
            let heap = sh.realm.heap
            let depth = heap.rootDepth
            _ = heap.root(v)
            let text = jsInspect(sh.realm, v)
            heap.popRoots(to: depth)
            sh.write(1, text + "\n")
        case .exception(let e):
            if e.message.hasSuffix("unexpected end of input") && e.message.hasPrefix("SyntaxError") {
                pendingSource = source
                continue
            }
            pendingSource = ""
            sh.write(2, "Uncaught " + (e.stack.isEmpty ? e.message : e.stack) + "\n")
        case .terminated(let why):
            pendingSource = ""
            sh.reportTermination(why)
            sh.failed = false
            sh.terminated = false
        }
        sh.loop.performMicrotaskCheckpoint()
        sh.flush()
    }
}
