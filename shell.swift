// Phase G: the shell, in ordinary Swift on top of a generic Terminal.
//
// - Line editor (G2): cursor movement and insertion anywhere in the line,
//   Home/End, Backspace/Delete, Ctrl-A/E/B/F/U/K/L/C/D, history on Up/Down
//   (keeping the line being typed), tab completion over command names. The
//   screen is updated with plain ANSI (CR, ESC[K, ESC[nC/D), which both a
//   serial terminal and the framebuffer console understand.
// - Dispatcher (G1): a table of commands; `help` is generated from it.
// - Commands (G3) write through the terminal, so tests can capture them.

struct Command<T: Terminal> {
    let name: String
    /// Argument synopsis, for help ("<text>").
    let args: String
    let help: String
    let run: (inout Shell<T>, [Substring]) -> Void
}

struct Shell<T: Terminal> {
    var term: T
    var commands: [Command<T>] = []
    var history: [String] = []
    /// Variables for `set`/`get`/`vars` (Phase D: Dictionary with String keys).
    var vars: [String: Int] = [:]
    /// Phase M: the filesystem and this shell's current directory (a path).
    var fs: FileSystem = vfs
    var cwd = "/"

    /// Bold green "> ". Its visible width is promptWidth.
    let prompt = "\u{1B}[1;32m> \u{1B}[0m"
    let promptWidth = 2
    static var historyLimit: Int { 100 }

    // Line editor state: UTF-8 bytes, cursor as a byte index on a scalar
    // boundary. Widths on screen count scalars (one cell each).
    var line: [UInt8] = []
    var cursor = 0
    /// History position while editing (history.count = the new line), and
    /// the new line, saved while browsing.
    var historyIndex = 0
    var draft: [UInt8] = []
    /// A UTF-8 sequence arriving one byte (key event) at a time.
    var utf8Pending: [UInt8] = []
    var utf8Need = 0

    init(terminal: T) {
        term = terminal
        commands = Shell.builtins() + Shell.fileCommands() + Shell.desktopCommands()
            + Shell.editorCommands() + Shell.terminalCommands()
    }

    /// Until the terminal says the session is over (Phase L: `exit`, or the
    /// terminal window closed); forever on the boot shell.
    mutating func run() {
        say("Type 'help' for commands.")
        while !term.finished { step() }
    }

    /// Read one line, remember it, run it. Returns the line.
    @discardableResult
    mutating func step() -> String {
        let text = readLine()
        remember(text)
        execute(text)
        return text
    }

    // MARK: Output

    mutating func write(_ text: String) { term.write(text) }
    mutating func say(_ text: String) { term.write(text + "\n") }

    // MARK: Line editor

    /// Longest line (in cells) that fits on one terminal row after the prompt.
    var maxWidth: Int { max(term.columns - promptWidth - 1, 8) }

    mutating func readLine() -> String {
        line = []
        cursor = 0
        historyIndex = history.count
        draft = []
        utf8Need = 0
        write(prompt)
        while true {
            switch term.read() {
            case .left: left()
            case .right: right()
            case .home: home()
            case .end: end()
            case .up: historyUp()
            case .down: historyDown()
            case .delete: delete()
            case .insert, .pageUp, .pageDown, .function, .superKey: break
            case .char(let c):
                switch c {
                case 0x0D, 0x0A: // Enter
                    end()
                    write("\n")
                    return text(line[...])
                case 0x7F, 0x08: backspace()
                case 0x09: complete()
                case 0x01: home() // Ctrl-A
                case 0x05: end() // Ctrl-E
                case 0x02: left() // Ctrl-B
                case 0x06: right() // Ctrl-F
                case 0x04: delete() // Ctrl-D
                case 0x0B: killToEnd() // Ctrl-K
                case 0x15: killToStart() // Ctrl-U
                case 0x0C: // Ctrl-L
                    write("\u{1B}[2J\u{1B}[H")
                    redraw()
                case 0x10: historyUp() // Ctrl-P
                case 0x0E: historyDown() // Ctrl-N
                case 0x03: // Ctrl-C: abandon the line
                    end()
                    write("^C\n")
                    line = []
                    return ""
                case 0..<0x20: break // other control keys (and a lone Esc)
                default: typed(c)
                }
            }
        }
    }

    /// A printable byte: ASCII goes in directly, UTF-8 once complete.
    mutating func typed(_ c: UInt8) {
        switch c {
        case 0x80...0xBF:
            guard utf8Need > 0 else { return } // stray continuation byte
            utf8Pending.append(c)
            utf8Need -= 1
            if utf8Need == 0 { insert(utf8Pending) }
        case 0xC2...0xF4:
            utf8Pending = [c]
            utf8Need = c >= 0xF0 ? 3 : c >= 0xE0 ? 2 : 1
        case 0x80...0xFF:
            utf8Need = 0
        default:
            utf8Need = 0
            insert([c])
        }
    }

    func text(_ bytes: ArraySlice<UInt8>) -> String { String(decoding: bytes, as: UTF8.self) }

    /// Cells taken by `bytes` (scalars: UTF-8 bytes that aren't continuations).
    func width(_ bytes: ArraySlice<UInt8>) -> Int {
        var n = 0
        for b in bytes where b & 0xC0 != 0x80 { n += 1 }
        return n
    }

    mutating func back(_ n: Int) { if n > 0 { write("\u{1B}[\(n)D") } }
    mutating func forward(_ n: Int) { if n > 0 { write("\u{1B}[\(n)C") } }

    /// Byte index of the scalar before / after the cursor.
    func previous(_ i: Int) -> Int {
        var j = i - 1
        while j > 0 && line[j] & 0xC0 == 0x80 { j -= 1 }
        return j
    }

    func following(_ i: Int) -> Int {
        var j = i + 1
        while j < line.count && line[j] & 0xC0 == 0x80 { j += 1 }
        return j
    }

    mutating func insert(_ bytes: [UInt8]) {
        guard width(line[...]) + width(bytes[...]) <= maxWidth else { return }
        line.insert(contentsOf: bytes, at: cursor)
        cursor += bytes.count
        let tail = line[cursor...]
        write(text(bytes[...]) + text(tail))
        back(width(tail))
    }

    mutating func backspace() {
        guard cursor > 0 else { return }
        let start = previous(cursor)
        line.removeSubrange(start..<cursor)
        cursor = start
        let tail = line[cursor...]
        if tail.isEmpty {
            write("\u{8} \u{8}")
        } else {
            write("\u{8}" + text(tail) + " ")
            back(width(tail) + 1)
        }
    }

    mutating func delete() {
        guard cursor < line.count else { return }
        line.removeSubrange(cursor..<following(cursor))
        let tail = line[cursor...]
        write(text(tail) + " ")
        back(width(tail) + 1)
    }

    mutating func left() {
        guard cursor > 0 else { return }
        cursor = previous(cursor)
        write("\u{1B}[D")
    }

    mutating func right() {
        guard cursor < line.count else { return }
        cursor = following(cursor)
        write("\u{1B}[C")
    }

    mutating func home() {
        back(width(line[..<cursor]))
        cursor = 0
    }

    mutating func end() {
        forward(width(line[cursor...]))
        cursor = line.count
    }

    mutating func killToEnd() {
        guard cursor < line.count else { return }
        line.removeSubrange(cursor...)
        write("\u{1B}[K")
    }

    mutating func killToStart() {
        guard cursor > 0 else { return }
        line.removeSubrange(..<cursor)
        cursor = 0
        redraw()
    }

    /// Reprint the prompt and line from column 0, erase what's left of an
    /// older (longer) line, and put the cursor back.
    mutating func redraw() {
        write("\r" + prompt + text(line[...]) + "\u{1B}[K")
        back(width(line[cursor...]))
    }

    mutating func replaceLine(_ bytes: [UInt8]) {
        line = bytes
        cursor = line.count
        redraw()
    }

    mutating func historyUp() {
        guard historyIndex > 0 else { return }
        if historyIndex == history.count { draft = line }
        historyIndex -= 1
        replaceLine(Array(history[historyIndex].utf8))
    }

    mutating func historyDown() {
        guard historyIndex < history.count else { return }
        historyIndex += 1
        replaceLine(historyIndex == history.count ? draft : Array(history[historyIndex].utf8))
    }

    /// Add a submitted line to the history (not blanks or repeats).
    mutating func remember(_ text: String) {
        guard text.utf8.contains(where: { $0 != 0x20 }), history.last != text else { return }
        history.append(text)
        if history.count > Shell.historyLimit { history.removeFirst() }
    }

    /// Tab: complete the command name before the cursor. One match: complete
    /// it plus a space. Several: extend to their common prefix, list them, and
    /// reprint the prompt and line.
    mutating func complete() {
        let prefix = Array(line[..<cursor])
        guard !prefix.contains(0x20) else { return } // only the first word
        var matches: [String] = []
        for c in commands where c.name.utf8.starts(with: prefix) { matches.append(c.name) }
        guard let first = matches.first else { return }
        if matches.count == 1 {
            var rest = Array(first.utf8.dropFirst(prefix.count))
            if cursor == line.count || line[cursor] != 0x20 { rest.append(0x20) }
            insert(rest)
            return
        }
        var common = Array(first.utf8)
        for m in matches.dropFirst() {
            var n = 0
            for b in m.utf8 {
                guard n < common.count, common[n] == b else { break }
                n += 1
            }
            common.removeSubrange(n...)
        }
        if common.count > prefix.count { insert(Array(common[prefix.count...])) }
        let list = matches.sorted()
        var out = "\n"
        for (i, m) in list.enumerated() { out += (i == 0 ? "" : "  ") + m }
        say(out)
        redraw()
    }

    // MARK: Dispatch

    mutating func execute(_ text: String) {
        let words = text.split(separator: " ")
        guard let name = words.first else { return }
        guard let command = commands.first(where: { $0.name == name }) else {
            say("unknown command: \(name)")
            return
        }
        command.run(&self, Array(words.dropFirst()))
    }

    mutating func help() {
        for c in commands {
            let synopsis = c.args.isEmpty ? c.name : c.name + " " + c.args
            say(pad(synopsis, 15) + " " + c.help)
        }
    }

    // MARK: Commands

    static func builtins() -> [Command<T>] {
        [
            Command(name: "help", args: "", help: "show this list") { sh, _ in sh.help() },
            Command(name: "echo", args: "<text>", help: "print text") { sh, args in
                // The words are slices of one line: print it from the first
                // to the end of the last, inner spacing kept.
                guard let first = args.first, let last = args.last else { sh.say(""); return }
                sh.say(String(first.base[first.startIndex..<last.endIndex]))
            },
            Command(name: "clear", args: "", help: "clear the screen") { sh, _ in
                sh.write("\u{1B}[2J\u{1B}[H")
            },
            Command(name: "fb", args: "", help: "framebuffer info") { sh, _ in
                sh.say(framebufferInfo())
            },
            Command(name: "mem", args: "", help: "memory map, frame and heap stats") { sh, _ in
                for l in memoryInfo() { sh.say(l) }
            },
            Command(name: "cpus", args: "", help: "per-CPU state: APIC id, switches, wakeups, IPIs") { sh, _ in
                for l in cpusInfo() { sh.say(l) }
            },
            Command(name: "peek", args: "<hex>", help: "read a 64-bit value at an address") { sh, args in
                guard args.count == 1, let addr = parseHex(args[0]) else {
                    sh.say("usage: peek <hex addr>")
                    return
                }
                guard addr & 7 == 0, let ptr = UnsafePointer<UInt64>(bitPattern: UInt(addr)) else {
                    sh.say("peek: address must be non-null and 8-byte aligned")
                    return
                }
                sh.say("\(hex(addr)): \(hex(ptr.pointee))")
            },
            Command(name: "uptime", args: "", help: "time since boot (timer ticks at 100 Hz)") { sh, _ in
                sh.say(uptimeInfo())
            },
            Command(name: "mouse", args: "", help: "PS/2 mouse position and buttons") { sh, _ in
                sh.say(mouseInfo())
            },
            Command(name: "gfx", args: "", help: "compositor layers and damage stats") { sh, _ in
                sh.say(compositorInfo())
            },
            Command(name: "fault", args: "<kind>", help: "raise an exception: ud, de, pf, gp, df") { sh, args in
                if args.count == 1 { raiseFault(String(args[0])) }
                sh.say("usage: fault <ud|de|pf|gp|df>")
            },
            Command(name: "halt", args: "", help: "stop the CPU") { sh, _ in
                sh.say("Halted.")
                consoleFlush()
                hcf()
            },
            Command(name: "reboot", args: "", help: "reset via the keyboard controller") { sh, _ in
                sh.say("Rebooting...")
                consoleFlush()
                reboot()
            },
            Command(name: "selftest", args: "", help: "run kernel self-checks (exits QEMU under --test)") { _, _ in
                runSelfTests()
            },
            Command(name: "set", args: "<name> <n>", help: "set a shell variable (an integer)") { sh, args in
                guard args.count == 2, let value = parseInt(args[1]) else {
                    sh.say("usage: set <name> <integer>")
                    return
                }
                sh.vars[String(args[0])] = value
            },
            Command(name: "get", args: "<name>", help: "print a shell variable") { sh, args in
                guard let name = args.first else { sh.say("usage: get <name>"); return }
                if let value = sh.vars[String(name)] {
                    sh.say("\(value)")
                } else {
                    sh.say("get: not set: \(name)")
                }
            },
            Command(name: "vars", args: "", help: "list shell variables") { sh, _ in
                for name in sh.vars.keys.sorted() { sh.say("\(name) = \(sh.vars[name]!)") }
                sh.say("(\(sh.vars.count) variables)")
            },
            Command(name: "history", args: "", help: "list the command history") { sh, _ in
                for (i, line) in sh.history.enumerated() { sh.say(pad("\(i + 1)", 4, left: true) + "  " + line) }
            },
            Command(name: "color", args: "<fg> <bg>", help: "console colours: names or 0-15") { sh, args in
                sh.say(colorCommand(args))
            },
        ]
    }
}

// MARK: Formatting and parsing

/// Pad `s` with spaces to `n` characters (on the left if `left`).
func pad(_ s: String, _ n: Int, left: Bool = false) -> String {
    var fill = ""
    var count = s.utf8.count
    while count < n { fill += " "; count += 1 }
    return left ? fill + s : s + fill
}

/// `0x`-prefixed, zero-padded 16-digit hex.
func hex(_ value: UInt64) -> String {
    var bytes: [UInt8] = [0x30, 0x78]
    var shift: UInt64 = 64
    while shift > 0 {
        shift -= 4
        let nibble = UInt8(truncatingIfNeeded: (value >> shift) & 0xF)
        bytes.append(nibble < 10 ? 0x30 + nibble : 0x61 + nibble - 10)
    }
    return String(decoding: bytes, as: UTF8.self)
}

/// Hex with an optional `0x` prefix, at most 16 digits.
func parseHex(_ s: Substring) -> UInt64? {
    var digits = s
    if digits.utf8.count > 2 && (digits.hasPrefix("0x") || digits.hasPrefix("0X")) {
        digits = digits.dropFirst(2)
    }
    guard !digits.isEmpty, digits.utf8.count <= 16 else { return nil }
    return UInt64(digits, radix: 16)
}

/// Decimal with an optional leading `-`; nil on overflow or junk.
func parseInt(_ s: Substring) -> Int? {
    guard s.first != "+" else { return nil }
    return Int(s)
}

// MARK: Command bodies

func reboot() -> Never {
    // Wait for the keyboard controller input buffer to drain, then pulse reset.
    while inb(0x64) & 0x02 != 0 {}
    outb(0x64, 0xFE)
    hcf()
}

/// `fault <kind>`: returns only for an unknown kind.
func raiseFault(_ kind: String) {
    switch kind {
    case "ud": fault_invalid_opcode()
    case "de": fault_divide_by_zero()
    case "pf":
        // User-half address: Limine maps nothing there. Store a nonzero
        // value: for 0, -Osize emits `andq $0, (mem)`, which faults as a read.
        UnsafeMutablePointer<UInt64>(bitPattern: 0x0000_7000_0000_0000)!.pointee = 0x5A5A
    case "gp":
        // Non-canonical: bits 63:47 aren't all equal.
        printHex(UnsafePointer<UInt64>(bitPattern: UInt(0xDEAD_0000_0000_0000))!.pointee)
    case "df": fault_double()
    default: break
    }
}

func mouseInfo() -> String {
    guard ps2.mouse else { return "mouse: none" }
    pollMouse()
    return "mouse: x=\(mouse.x) y=\(mouse.y) buttons=\(mouse.buttons) packets=\(mouse.packets) (screen \(mouse.width)x\(mouse.height), resyncs \(mouseParser.resyncs), overflows \(mouseParser.overflows))"
}

func uptimeInfo() -> String {
    let t = ticks
    let hundredths = t % timerHz * 100 / timerHz
    return "uptime: \(t / timerHz).\(hundredths < 10 ? "0" : "")\(hundredths) s (\(t) ticks)"
}

func framebufferInfo() -> String {
    guard let resp = framebuffer_request.response, resp.pointee.framebuffer_count > 0,
          let fb = resp.pointee.framebuffers[0] else {
        return "no framebuffer"
    }
    let f = fb.pointee
    // The address is formatted as text: no HHDM pointer ends up in a String.
    return "framebuffer: \(f.width)x\(f.height), \(f.bpp) bpp, pitch \(f.pitch), at \(hex(UInt64(UInt(bitPattern: f.address))))"
}

func memoryInfo() -> [String] {
    guard let resp = memmap_request.response, let entries = resp.pointee.entries else {
        return ["no memory map"]
    }
    var usable: UInt64 = 0
    var total: UInt64 = 0
    for i in 0..<Int(resp.pointee.entry_count) {
        guard let e = entries[i] else { continue }
        total += e.pointee.length
        if e.pointee.type == UInt64(LIMINE_MEMMAP_USABLE) { usable += e.pointee.length }
    }
    let mib = { (frames: Int) in (frames * frameSize) >> 20 }
    var classes = "heap classes:"
    for i in 0..<heapClassCount where heap.liveBlocks[i] > 0 {
        classes += " \(Heap.classSize(i))B:\(heap.liveBlocks[i])"
    }
    return [
        "memory map: \(resp.pointee.entry_count) entries, usable \(usable >> 20) MiB, all \(total >> 20) MiB (incl. reserved/MMIO)",
        "frames: \(pmm.totalFrames) total (\(mib(pmm.totalFrames)) MiB), \(pmm.usedFrames) used (\(mib(pmm.usedFrames)) MiB), \(pmm.freeFrames) free (\(mib(pmm.freeFrames)) MiB)",
        "heap: \(heap.bytesInUse) bytes in \(heap.liveCount) blocks, \(heap.chunkFrames) chunk frames, \(heap.allocations) allocs / \(heap.deallocations) frees",
        classes + " large:\(heap.largeBlocks) (\(heap.largeFrames) frames)",
    ]
}

let colorNames = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]

/// A colour by name ("red", "brightred", "grey") or number 0-15.
func parseColor(_ s: Substring) -> UInt8? {
    if let n = Int(s) { return n >= 0 && n < 16 ? UInt8(n) : nil }
    if s == "grey" || s == "gray" { return 8 }
    var name = s
    var bright: UInt8 = 0
    if name.hasPrefix("bright") { name = name.dropFirst(6); bright = 8 }
    guard let i = colorNames.firstIndex(where: { $0 == name }) else { return nil }
    return UInt8(i) + bright
}

func colorName(_ c: UInt8) -> String {
    (c >= 8 ? "bright" : "") + colorNames[Int(c & 7)]
}

/// `color <fg> <bg>`: set the console's default colours (what SGR 0/39/49
/// return to), recolouring what's on screen. No arguments: show them.
func colorCommand(_ args: [Substring]) -> String {
    guard let c = console else { return "color: no console" }
    if args.isEmpty {
        return "color: \(colorName(c.defaultFG)) (\(c.defaultFG)) on \(colorName(c.defaultBG)) (\(c.defaultBG))"
    }
    guard args.count == 2 else { return "usage: color <fg> <bg> (names like red, brightred, or 0-15)" }
    guard let fg = parseColor(args[0]) else { return "color: unknown colour: \(args[0])" }
    guard let bg = parseColor(args[1]) else { return "color: unknown colour: \(args[1])" }
    c.setDefaultColors(fg: fg, bg: bg)
    return "color: \(colorName(fg)) on \(colorName(bg))"
}
