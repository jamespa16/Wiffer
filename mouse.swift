// Phase F2: PS/2 mouse packets, the pointer state, and a cursor sprite drawn
// straight onto the Limine framebuffer.

/// A decoded movement packet. dy is in PS/2 convention: positive = up.
struct MousePacket: Equatable {
    var dx: Int
    var dy: Int
    var buttons: UInt8 // bit 0 left, 1 right, 2 middle
}

/// Assembles the standard 3-byte packets:
///   byte 0: Yovf Xovf Ysign Xsign 1 Middle Right Left
///   byte 1: dx (low 8 bits), byte 2: dy (low 8 bits)
/// Bit 3 of byte 0 is always set, so a byte without it can't start a packet:
/// skipping such bytes re-synchronises after a lost byte.
struct MousePacketParser {
    var bytes = InlineArray<3, UInt8>(repeating: 0)
    var count = 0
    /// Bytes skipped while re-syncing, and packets discarded for overflow.
    var resyncs = 0
    var overflows = 0

    mutating func feed(_ byte: UInt8) -> MousePacket? {
        if count == 0 && byte & 0x08 == 0 { resyncs += 1; return nil }
        bytes[count] = byte
        count += 1
        guard count == 3 else { return nil }
        count = 0
        let flags = bytes[0]
        if flags & 0xC0 != 0 { overflows += 1; return nil }
        var dx = Int(bytes[1]), dy = Int(bytes[2])
        if flags & 0x10 != 0 { dx -= 256 }
        if flags & 0x20 != 0 { dy -= 256 }
        return MousePacket(dx: dx, dy: dy, buttons: flags & 0x07)
    }
}

/// Pointer position in framebuffer pixels (clamped to the screen), buttons,
/// and a count of the packets applied.
struct MouseState {
    var x = 0
    var y = 0
    var buttons: UInt8 = 0
    var packets = 0
    var width = 0
    var height = 0

    mutating func reset(toCentreOf fb: RawFramebuffer?) {
        width = fb?.width ?? 0
        height = fb?.height ?? 0
        x = width / 2
        y = height / 2
    }

    mutating func apply(_ p: MousePacket) {
        x = max(0, min(width - 1, x + p.dx))
        y = max(0, min(height - 1, y - p.dy)) // screen y grows downwards
        buttons = p.buttons
        packets += 1
    }
}

var mouse = MouseState()
var mouseParser = MousePacketParser()
/// Set when a packet changed the state; cleared when the cursor is redrawn.
var mouseMoved = false

/// Apply queued mouse bytes, then move the cursor sprite if anything changed.
func pollMouse() {
    while let byte = mouseRing.pop() {
        if let packet = mouseParser.feed(byte) {
            mouse.apply(packet)
            mouseMoved = true
        }
    }
    if mouseMoved {
        mouseMoved = false
        cursorMove(x: mouse.x, y: mouse.y)
    }
}

// MARK: Raw framebuffer

/// The Limine framebuffer as 32-bit pixels. (Phase E's console has its own
/// back buffer; the cursor only needs pixel get/put.)
struct RawFramebuffer {
    var pixels: UnsafeMutablePointer<UInt32>
    var stride: Int // in pixels
    var width: Int
    var height: Int

    static var primary: RawFramebuffer? {
        guard let resp = framebuffer_request.response, resp.pointee.framebuffer_count > 0,
              let fb = resp.pointee.framebuffers[0], fb.pointee.bpp == 32,
              let base = fb.pointee.address else { return nil }
        return RawFramebuffer(pixels: base.assumingMemoryBound(to: UInt32.self),
                              stride: Int(fb.pointee.pitch / 4),
                              width: Int(fb.pointee.width), height: Int(fb.pointee.height))
    }
}

// MARK: Cursor sprite

/// Arrow pointer, hot spot top-left. X = outline, o = fill, space = clear.
let cursorArt: StaticString = """
X
XX
XoX
XooX
XoooX
XooooX
XoooooX
XooooooX
XoooooooX
XooooooooX
XoooooooooX
XooooooXXXX
XoooXooX
XooXXooX
XoX  XooX
XX   XooX
      XX
"""
let cursorWidth = 11
let cursorHeight = 17

/// Pixels under the sprite while it's shown, row-major cursorWidth wide.
var cursorSaved = InlineArray<187, UInt32>(repeating: 0)
var cursorShown = false
var cursorX = 0
var cursorY = 0

/// Save the pixels under the sprite at (x, y), then draw it (clipped).
/// Reads the framebuffer: fine for 187 pixels, but once Phase E's back
/// buffer exists, save/restore from that instead.
func cursorDraw(x: Int, y: Int) {
    guard let fb = RawFramebuffer.primary else { return }
    if cursorShown { cursorErase() }
    cursorX = x
    cursorY = y
    for row in 0..<cursorHeight where y + row < fb.height {
        for col in 0..<cursorWidth where x + col < fb.width {
            cursorSaved[row * cursorWidth + col] = fb.pixels[(y + row) * fb.stride + x + col]
        }
    }
    cursorArt.withUTF8Buffer { art in
        var row = 0, col = 0
        for c in art {
            if c == 0x0A { row += 1; col = 0; continue }
            if c != 0x20 && y + row < fb.height && x + col < fb.width {
                fb.pixels[(y + row) * fb.stride + x + col] = c == 0x58 ? 0x00_0000 : 0xFF_FFFF
            }
            col += 1
        }
    }
    cursorShown = true
}

/// Restore the pixels saved by cursorDraw.
func cursorErase() {
    guard cursorShown, let fb = RawFramebuffer.primary else { return }
    for row in 0..<cursorHeight where cursorY + row < fb.height {
        for col in 0..<cursorWidth where cursorX + col < fb.width {
            fb.pixels[(cursorY + row) * fb.stride + cursorX + col] = cursorSaved[row * cursorWidth + col]
        }
    }
    cursorShown = false
}

func cursorMove(x: Int, y: Int) {
    cursorErase()
    cursorDraw(x: x, y: y)
}
