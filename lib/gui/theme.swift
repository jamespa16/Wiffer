// Phase 6F3: the widget kit's shared types (lib/gui).
//
// lib/gui is the toolkit behind Wiffer's GUI programs: widgets drawn into a
// Surface (surface.swift: Point, Rect, Surface, PSFFont), fed GUIEvents
// decoded from the kernel's WinEvent records (abi/syscalls.swift). It has no
// system calls of its own, so it is tested on the host (`./run.sh
// --hosttest gui`). The window, event loop and font live in libwiffer
// (user/libwiffer/gui/: AppWindow and App); a program lists `gui` in its
// LIBS.
//
// Pixels are 0x00RRGGBB, the same format as a window's buffer.

/// The font is Spleen 8x16 (monospace): every cell is this wide.
let guiCellWidth = 8

struct GUITheme {
    var font: PSFFont
    var background: UInt32 = 0xF0F0F0
    var text: UInt32 = 0x1A1A1A
    var disabledText: UInt32 = 0x8C8C8C
    var buttonFace: UInt32 = 0xDCDCDC
    var buttonHover: UInt32 = 0xE9EFFA
    var buttonPressed: UInt32 = 0xB5C6E2
    var buttonBorder: UInt32 = 0x6E6E6E
    var fieldBackground: UInt32 = 0xFFFFFF
    var fieldBorder: UInt32 = 0x6E6E6E
    var focusBorder: UInt32 = 0x1E5AA8
    var selection: UInt32 = 0x1E5AA8
    var selectionText: UInt32 = 0xFFFFFF
    var caret: UInt32 = 0x101010
    var scrollTrack: UInt32 = 0xE2E2E2
    var scrollThumb: UInt32 = 0xA6A6A6
    var scrollThumbActive: UInt32 = 0x6E6E6E
    var accent: UInt32 = 0x1E5AA8

    init(font: PSFFont) { self.font = font }
}

/// A key press: `code` is a byte value for characters (Ctrl-letters are the
/// control codes, ctrl set) or a WinKey constant.
struct GUIKeyEvent: Equatable {
    var code: Int
    var ctrl = false
    var alt = false
    var shift = false
    var meta = false

    init(code: Int, ctrl: Bool = false, alt: Bool = false, shift: Bool = false, meta: Bool = false) {
        self.code = code
        self.ctrl = ctrl
        self.alt = alt
        self.shift = shift
        self.meta = meta
    }

    init(_ e: WinEvent) {
        code = Int(e.a)
        ctrl = e.mods & WinMod.ctrl != 0
        alt = e.mods & WinMod.alt != 0
        shift = e.mods & WinMod.shift != 0
        meta = e.mods & WinMod.meta != 0
    }

    /// The character typed, if it is printable and not a shortcut.
    var character: UInt32? {
        guard !ctrl, !alt, !meta, code >= 0x20, code < 0x100, code != 0x7F else { return nil }
        return UInt32(code)
    }

    /// Ctrl plus this letter (pass the lower-case ASCII letter).
    func isCtrl(_ letter: UInt8) -> Bool {
        ctrl && !alt && code == Int(letter & 0x1F)
    }

    static let enter = 0x0D
    static let escape = 0x1B
    static let tab = 0x09
    static let backspace = 0x08
}

enum GUIEvent: Equatable {
    case key(GUIKeyEvent)
    /// Position in window coordinates, buttons held (WinButton bits), wheel
    /// lines (positive = scroll up).
    case mouse(x: Int, y: Int, buttons: Int, wheel: Int)
    case resize(width: Int, height: Int)
    case focus(Bool)
    case close
}

/// A kernel record as a GUIEvent (nil for an unknown kind).
func guiDecode(_ e: WinEvent) -> GUIEvent? {
    switch e.kind {
    case WinEventKind.key: return .key(GUIKeyEvent(e))
    case WinEventKind.mouse: return .mouse(x: Int(e.a), y: Int(e.b), buttons: Int(e.mods), wheel: Int(e.c))
    case WinEventKind.resize: return .resize(width: Int(e.a), height: Int(e.b))
    case WinEventKind.focus: return .focus(e.a != 0)
    case WinEventKind.close: return .close
    default: return nil
    }
}

/// The records in `bytes` (whole 16-byte records, little endian).
func guiDecodeRecords(_ bytes: [UInt8]) -> [WinEvent] {
    var out: [WinEvent] = []
    var i = 0
    func u32(_ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }
    while i + WinEvent.size <= bytes.count {
        out.append(WinEvent(kind: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8,
                            mods: UInt16(bytes[i + 2]) | UInt16(bytes[i + 3]) << 8,
                            a: Int32(bitPattern: u32(i + 4)), b: Int32(bitPattern: u32(i + 8)),
                            c: Int32(bitPattern: u32(i + 12))))
        i += WinEvent.size
    }
    return out
}

/// The process-wide clipboard the text fields share (Ctrl-C/X/V). One per
/// program: there is no system clipboard yet.
var guiClipboard = ""

/// Unicode scalars of `s`.
func guiScalars(_ s: String) -> [UInt32] {
    var out: [UInt32] = []
    for u in s.unicodeScalars { out.append(u.value) }
    return out
}

/// A String from scalars (invalid ones become U+FFFD).
func guiString(_ scalars: ArraySlice<UInt32>) -> String {
    var s = String()
    for v in scalars { s.unicodeScalars.append(Unicode.Scalar(v) ?? "\u{FFFD}") }
    return s
}
