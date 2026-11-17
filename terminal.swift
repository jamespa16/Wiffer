// Phase G1: the terminal the shell talks to, hidden behind a protocol so the
// same (generic, specialised) shell runs on the live machine or on a scripted
// terminal in the selftests. Generics rather than `any Terminal`: existentials
// are limited in Embedded Swift.

protocol Terminal {
    /// Block until the next key.
    mutating func read() -> KeyEvent
    /// Write UTF-8 text with ANSI escapes. `\n` means "new line" (the
    /// terminal sends CR LF where needed).
    mutating func write(_ text: String)
    /// Width in columns: the line editor keeps a line on one row.
    var columns: Int { get }
    /// Phase L: the session is over (its window closed, or `exit`), so
    /// Shell.run returns. Default: never.
    var finished: Bool { get }
    /// The shell's `exit`: end the session after this command. False if this
    /// terminal can't end (the boot shell). Default: can't.
    mutating func requestExit() -> Bool
}

extension Terminal {
    var finished: Bool { false }
    mutating func requestExit() -> Bool { false }
}

/// The machine's own terminal: output to COM1 and the framebuffer console,
/// input from serial (escape sequences decoded) or the PS/2 keyboard.
struct LiveTerminal: Terminal {
    mutating func read() -> KeyEvent { readKey() }

    mutating func write(_ text: String) {
        for byte in text.utf8 {
            if byte == 0x0A { putc(0x0D) }
            putc(byte)
        }
    }

    var columns: Int { console?.cols ?? 80 }
}

/// A terminal for tests: keys come from a script, output is recorded and
/// also fed to an off-screen Console, so a test can check what a user would
/// see (cursor movement, erases and all).
struct ScriptedTerminal: Terminal {
    var keys: [KeyEvent]
    var next = 0
    /// Set if the shell read past the end of the script (it then gets Enter).
    var overran = false
    var output: [UInt8] = []
    let screen: Console
    let columns: Int

    init(_ keys: [KeyEvent], cols: Int = 60, rows: Int = 12) {
        self.keys = keys
        screen = Console(cols: cols, rows: rows)
        columns = cols
    }

    mutating func read() -> KeyEvent {
        guard next < keys.count else { overran = true; return .char(0x0D) }
        next += 1
        return keys[next - 1]
    }

    mutating func write(_ text: String) {
        for byte in text.utf8 {
            if byte == 0x0A { record(0x0D) }
            record(byte)
        }
    }

    mutating func record(_ byte: UInt8) {
        output.append(byte)
        screen.write(byte)
    }

    /// Everything written so far, then forget it.
    mutating func take() -> String {
        defer { output.removeAll() }
        return String(decoding: output, as: UTF8.self)
    }
}

// MARK: Serial escape sequences

/// Turns the bytes a serial terminal sends into KeyEvents. Arrows are
/// ESC [ A/B/C/D (or ESC O A... in application mode), Home/End ESC [ H/F,
/// ESC [ 1~ / 4~ (also 7~ / 8~), Delete ESC [ 3~, Insert 2~, PgUp/PgDn 5~/6~.
/// Modifier parameters (ESC [ 1;5C) are ignored. Unknown sequences are
/// dropped. A lone ESC is held until the next byte, or until `timeout()`
/// (the caller decides when the line has gone quiet).
struct EscapeDecoder {
    enum State { case ground, escape, csi, ss3 }
    var state = State.ground
    /// First CSI parameter; later ones (modifiers) are ignored.
    var param = 0
    var firstParamDone = false
    var events: [KeyEvent] = []

    var pending: Bool { state != .ground }

    mutating func feed(_ b: UInt8) {
        switch state {
        case .ground:
            if b == 0x1B { state = .escape } else { events.append(.char(b)) }
        case .escape:
            switch b {
            case 0x5B: state = .csi; param = 0; firstParamDone = false // [
            case 0x4F: state = .ss3 // O
            case 0x1B: events.append(.char(0x1B)) // ESC ESC: the first was a key
            default: // ESC x (e.g. Alt-x): the Escape key, then x
                events.append(.char(0x1B))
                state = .ground
                feed(b)
            }
        case .csi:
            switch b {
            case 0x30...0x39:
                if !firstParamDone { param = min(param * 10 + Int(b - 0x30), 9999) }
            case 0x3B: firstParamDone = true // ;
            case 0x20...0x2F, 0x3C...0x3F: break // intermediates, private markers
            case 0x40...0x7E:
                state = .ground
                if let key = csiKey(b) { events.append(key) }
            default: // a control byte aborts the sequence and counts as itself
                state = .ground
                feed(b)
            }
        case .ss3:
            state = .ground
            if let key = finalKey(b) { events.append(key) }
        }
    }

    /// The line went quiet mid-sequence: a lone ESC was the Escape key;
    /// anything longer was garbage.
    mutating func timeout() {
        if state == .escape { events.append(.char(0x1B)) }
        state = .ground
    }

    mutating func pop() -> KeyEvent? {
        events.isEmpty ? nil : events.removeFirst()
    }

    func csiKey(_ final: UInt8) -> KeyEvent? {
        guard final == 0x7E else { return finalKey(final) } // ~
        switch param {
        case 1, 7: return .home
        case 2: return .insert
        case 3: return .delete
        case 4, 8: return .end
        case 5: return .pageUp
        case 6: return .pageDown
        default: return nil
        }
    }

    func finalKey(_ final: UInt8) -> KeyEvent? {
        switch final {
        case 0x41: return .up // A
        case 0x42: return .down // B
        case 0x43: return .right // C
        case 0x44: return .left // D
        case 0x48: return .home // H
        case 0x46: return .end // F
        default: return nil
        }
    }
}
