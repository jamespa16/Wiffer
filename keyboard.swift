// Phase F1: scancode set 1 decoding (US layout) into KeyEvents.
// Phase H2: Alt / AltGr, Super and F1-F12, with the modifiers carried in a
// `Key` (events.swift). The input wait (readKey) is in events.swift.

/// One keypress. ASCII (and control codes: Enter = \r, Backspace = 0x08,
/// Tab = 0x09, Esc = 0x1B, Ctrl-letter = 0x01...0x1A) arrives as `.char`;
/// navigation keys get their own cases.
enum KeyEvent: Equatable {
    case char(UInt8)
    case up, down, left, right
    case home, end, pageUp, pageDown
    case insert, delete
    /// F1...F12 (payload 1...12).
    case function(UInt8)
    /// The Windows / Super key itself (sent once per press; while it is
    /// held, other keys arrive with `Key.meta` set).
    case superKey
}

/// Scancode set 1 (what the 8042 delivers with translation on) -> ASCII,
/// indexed by make code 0x00...0x39. 0 = not a character (modifiers etc.).
let scancodeBase: StaticString =
    "\0\u{1B}1234567890-=\u{8}\tqwertyuiop[]\r\0asdfghjkl;'`\0\\zxcvbnm,./\0*\0 "
let scancodeShift: StaticString =
    "\0\u{1B}!@#$%^&*()_+\u{8}\tQWERTYUIOP{}\r\0ASDFGHJKL:\"~\0|ZXCVBNM<>?\0*\0 "
/// Keypad 0x47...0x53 with Num Lock on.
let scancodeKeypad: StaticString = "789-456+1230."

struct ScancodeDecoder {
    var leftShift = false, rightShift = false
    var leftCtrl = false, rightCtrl = false
    /// Left Alt (38) and right Alt / AltGr (E0 38).
    var leftAlt = false, rightAlt = false
    /// Windows / Super keys (E0 5B, E0 5C).
    var leftSuper = false, rightSuper = false
    var capsLock = false, numLock = false
    /// Caps/Num Lock keys held: typematic repeat must not toggle again.
    var capsHeld = false, numHeld = false
    /// The previous byte was 0xE0.
    var extended = false
    /// Bytes left to skip of an 0xE1 sequence (Pause).
    var skip = 0

    var shift: Bool { leftShift || rightShift }
    var ctrl: Bool { leftCtrl || rightCtrl }
    var alt: Bool { leftAlt || rightAlt }
    var altGr: Bool { rightAlt }
    var meta: Bool { leftSuper || rightSuper }

    /// Feed one scancode byte; returns the key when a key press completes.
    mutating func feed(_ code: UInt8) -> KeyEvent? { feedKey(code)?.code }

    /// Feed one scancode byte; returns the key, with the modifiers held at
    /// the time, when a key press completes.
    mutating func feedKey(_ code: UInt8) -> Key? {
        guard let event = decode(code) else { return nil }
        return Key(event, ctrl: ctrl, alt: alt, shift: shift, meta: meta)
    }

    mutating func decode(_ code: UInt8) -> KeyEvent? {
        if skip > 0 { skip -= 1; return nil }
        if code == 0xE0 { extended = true; return nil }
        if code == 0xE1 { skip = 5; return nil } // E1 1D 45 E1 9D C5
        let e0 = extended
        extended = false
        let release = code & 0x80 != 0
        let make = code & 0x7F

        // Modifiers: track press and release.
        switch (e0, make) {
        case (false, 0x2A): leftShift = !release; return nil
        case (false, 0x36): rightShift = !release; return nil
        case (true, 0x2A), (true, 0x36): return nil // fake shifts around nav keys
        case (false, 0x1D): leftCtrl = !release; return nil
        case (true, 0x1D): rightCtrl = !release; return nil
        case (false, 0x38): leftAlt = !release; return nil
        case (true, 0x38): rightAlt = !release; return nil // AltGr
        case (true, 0x5B), (true, 0x5C):
            let held = leftSuper || rightSuper
            if make == 0x5B { leftSuper = !release } else { rightSuper = !release }
            return !release && !held ? .superKey : nil // not on typematic repeat
        case (false, 0x3A):
            if !release && !capsHeld { capsLock.toggle() }
            capsHeld = !release
            return nil
        case (false, 0x45):
            if !release && !numHeld { numLock.toggle() }
            numHeld = !release
            return nil
        default: break
        }
        if release { return nil }

        if e0 {
            switch make {
            case 0x1C: return .char(0x0D) // keypad Enter
            case 0x35: return .char(0x2F) // keypad /
            default: return navigation(make)
            }
        }
        if (0x3B...0x44).contains(make) { return .function(make - 0x3A) } // F1-F10
        if make == 0x57 || make == 0x58 { return .function(make - 0x4C) } // F11, F12
        if (0x47...0x53).contains(make) {
            if numLock && make != 0x4A && make != 0x4E {
                return .char(byte(scancodeKeypad, Int(make) - 0x47))
            }
            if make == 0x4A { return .char(0x2D) } // keypad -
            if make == 0x4E { return .char(0x2B) } // keypad +
            return navigation(make)
        }

        let base = byte(scancodeBase, Int(make))
        guard base != 0 else { return nil }
        let isLetter = base >= 0x61 && base <= 0x7A
        var c = base
        if isLetter {
            if shift != capsLock { c -= 0x20 } // Caps applies to letters only
        } else if shift {
            c = byte(scancodeShift, Int(make))
        }
        // Ctrl-letter (and Ctrl-[ \ ]) -> control code.
        if ctrl && (isLetter || base == 0x5B || base == 0x5C || base == 0x5D) {
            c = base & 0x1F
        }
        return .char(c)
    }

    /// Cursor-block keys: E0-prefixed, or the keypad with Num Lock off.
    func navigation(_ make: UInt8) -> KeyEvent? {
        switch make {
        case 0x47: return .home
        case 0x48: return .up
        case 0x49: return .pageUp
        case 0x4B: return .left
        case 0x4D: return .right
        case 0x4F: return .end
        case 0x50: return .down
        case 0x51: return .pageDown
        case 0x52: return .insert
        case 0x53: return .delete
        default: return nil
        }
    }

    func byte(_ table: StaticString, _ index: Int) -> UInt8 {
        table.withUTF8Buffer { index < $0.count ? $0[index] : 0 }
    }
}

var keyboardDecoder = ScancodeDecoder()
