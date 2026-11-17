// Phase F: the 8042 PS/2 controller and the interrupt side of the keyboard
// (IRQ1) and mouse (IRQ12). The handlers only read port 0x60 and push the
// byte into a fixed ring buffer; decoding happens in the main loop
// (keyboard.swift, mouse.swift). Nothing here allocates.

enum PS2 {
    static let data: UInt16 = 0x60
    static let status: UInt16 = 0x64   // read
    static let command: UInt16 = 0x64  // write
    static let outputFull: UInt8 = 0x01 // status: a byte is waiting at 0x60
    static let inputFull: UInt8 = 0x02  // status: controller hasn't taken our last write
    static let ack: UInt8 = 0xFA
    /// Status polls before giving up, so a missing or wedged controller can't
    /// hang boot. Generous: a device ACK can take a few ms on real hardware.
    static let timeout = 100_000

    // Controller configuration byte.
    static let configIRQ1: UInt8 = 0x01
    static let configIRQ12: UInt8 = 0x02
    static let configKeyboardClockOff: UInt8 = 0x10
    static let configMouseClockOff: UInt8 = 0x20
    static let configTranslate: UInt8 = 0x40 // set 2 -> set 1 on port 0x60
}

/// What ps2Init found.
struct PS2Devices {
    var controller = false
    var keyboard = false
    var mouse = false
    var config: UInt8 = 0
}

var ps2 = PS2Devices()

// MARK: Ring buffer

/// Single-producer (an IRQ handler), single-consumer (the main loop) byte
/// queue. The producer only writes `head`, the consumer only writes `tail`,
/// and both are accessed in place on the global (inout on a stored global is
/// an address, never a copy-back), so neither side clobbers the other's index.
/// One slot stays empty to tell full from empty; on overflow the new byte is
/// dropped and counted.
///
/// Visibility: the consumer polls between `hlt()` calls, whose asm has a
/// "memory" clobber, so `head` is reloaded every time round the loop. Inside
/// `pop`, compiler barriers keep the slot read after the `head` check and
/// before the `tail` store. On one CPU that is all the ordering needed: the
/// handler always runs to completion between two consumer instructions.
struct ByteRing {
    static let capacity = 128 // power of two
    var bytes = InlineArray<128, UInt8>(repeating: 0)
    var head = 0
    var tail = 0
    var dropped = 0

    var isEmpty: Bool { head == tail }

    /// Producer side (interrupts off).
    mutating func push(_ byte: UInt8) {
        let next = (head + 1) & (ByteRing.capacity - 1)
        if next == tail { dropped &+= 1; return }
        bytes[head] = byte
        head = next
    }

    /// Consumer side.
    mutating func pop() -> UInt8? {
        let h = head
        compiler_barrier()
        if h == tail { return nil }
        let byte = bytes[tail]
        compiler_barrier()
        tail = (tail + 1) & (ByteRing.capacity - 1)
        return byte
    }
}

var keyboardRing = ByteRing()
var mouseRing = ByteRing()

// MARK: IRQ handlers (called from handleIRQ before the EOI)

func keyboardIRQ() {
    keyboardRing.push(inb(PS2.data))
}

func mouseIRQ() {
    mouseRing.push(inb(PS2.data))
}

// MARK: Controller access, with timeouts

func ps2WaitWritable() -> Bool {
    for _ in 0..<PS2.timeout where inb(PS2.status) & PS2.inputFull == 0 { return true }
    return false
}

func ps2WaitReadable() -> Bool {
    for _ in 0..<PS2.timeout where inb(PS2.status) & PS2.outputFull != 0 { return true }
    return false
}

func ps2Command(_ cmd: UInt8) -> Bool {
    guard ps2WaitWritable() else { return false }
    outb(PS2.command, cmd)
    return true
}

func ps2WriteData(_ byte: UInt8) -> Bool {
    guard ps2WaitWritable() else { return false }
    outb(PS2.data, byte)
    return true
}

func ps2ReadData() -> UInt8? {
    guard ps2WaitReadable() else { return nil }
    return inb(PS2.data)
}

/// Discard anything waiting in the output buffer (bounded: a broken
/// controller may report "full" forever).
func ps2Flush() {
    for _ in 0..<256 {
        if inb(PS2.status) & PS2.outputFull == 0 { return }
        _ = inb(PS2.data)
    }
}

/// Send a command byte to the keyboard, or to the mouse via 0xD4, and wait
/// for its ACK (skipping a few unrelated bytes, e.g. a stray scancode).
func ps2DeviceCommand(_ byte: UInt8, mouse: Bool) -> Bool {
    if mouse { guard ps2Command(0xD4) else { return false } }
    guard ps2WriteData(byte) else { return false }
    for _ in 0..<8 {
        guard let reply = ps2ReadData() else { return false }
        if reply == PS2.ack { return true }
    }
    return false
}

/// Bring up the 8042 with scancode translation on, then the keyboard and
/// mouse. Devices are configured with IRQs off (replies are polled), then
/// IRQ1/IRQ12 are enabled in the controller and unmasked at the PIC. Must
/// run after picInit and before sti.
func ps2Init() {
    // A missing controller floats the bus: status reads as 0xFF.
    guard inb(PS2.status) != 0xFF,
          ps2Command(0xAD), ps2Command(0xA7) // disable both ports
    else { puts("ps2: no controller\n"); return }
    ps2Flush()

    guard ps2Command(0x20), let original = ps2ReadData() else {
        puts("ps2: config read timed out\n"); return
    }
    var config = original
    config &= ~(PS2.configIRQ1 | PS2.configIRQ12 | PS2.configKeyboardClockOff | PS2.configMouseClockOff)
    config |= PS2.configTranslate
    guard ps2Command(0x60), ps2WriteData(config) else {
        puts("ps2: config write timed out\n"); return
    }
    ps2.controller = true

    // Port 1: keyboard. Re-enable scanning (F4) in case firmware disabled it.
    _ = ps2Command(0xAE)
    ps2.keyboard = ps2DeviceCommand(0xF4, mouse: false)

    // Port 2: mouse. Enable it, set defaults (F6), enable reporting (F4).
    _ = ps2Command(0xA8)
    ps2.mouse = ps2DeviceCommand(0xF6, mouse: true) && ps2DeviceCommand(0xF4, mouse: true)

    // Drop any leftover replies so they don't decode as input, then turn the
    // device interrupts on.
    ps2Flush()
    config |= PS2.configIRQ1
    if ps2.mouse { config |= PS2.configIRQ12 } else { config |= PS2.configMouseClockOff }
    guard ps2Command(0x60), ps2WriteData(config) else {
        puts("ps2: config write timed out\n"); return
    }
    ps2.config = config

    picUnmask(1)
    if ps2.mouse {
        picUnmask(2)  // cascade: the slave PIC's IRQs arrive through IRQ2
        picUnmask(12)
    }
    mouse.reset(toCentreOf: RawFramebuffer.primary)
    puts(ps2.keyboard ? "ps2: keyboard" : "ps2: no keyboard")
    puts(ps2.mouse ? ", mouse\n" : ", no mouse\n")
}
