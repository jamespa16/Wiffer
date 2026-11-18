// Interrupt dispatch (called from the cpu.S stubs), exception reports, the
// 8259 PIC, and the PIT timer. Handlers never allocate and do minimal work.

// MARK: Dispatcher

@_cdecl("interrupt_dispatch")
public func interruptDispatch(_ frame: UnsafeMutablePointer<interrupt_frame>) {
    let vector = frame.pointee.vector
    if sseClobberInIRQ && vector >= 32 { sse_clobber_all() } // SSE selftest
    if vector < 32 {
        exceptionReport(frame.pointee)
    } else if vector < 48 {
        handleIRQ(UInt8(truncatingIfNeeded: vector - 32))
    } else if vector >= 0xF0 {
        apicInterrupt(UInt8(truncatingIfNeeded: vector))
    }
}

// MARK: Exceptions

/// QEMU exit code written to isa-debug-exit after an exception report, so a
/// test sees status (2 << 1) | 1 = 5. Without that device the write is ignored.
let exceptionExitCode: UInt8 = 2

func exceptionName(_ vector: UInt64) -> StaticString {
    switch vector {
    case 0: return "#DE divide error"
    case 1: return "#DB debug"
    case 2: return "NMI"
    case 3: return "#BP breakpoint"
    case 4: return "#OF overflow"
    case 5: return "#BR bound range exceeded"
    case 6: return "#UD invalid opcode"
    case 7: return "#NM device not available"
    case 8: return "#DF double fault"
    case 10: return "#TS invalid TSS"
    case 11: return "#NP segment not present"
    case 12: return "#SS stack-segment fault"
    case 13: return "#GP general protection fault"
    case 14: return "#PF page fault"
    case 16: return "#MF x87 floating-point error"
    case 17: return "#AC alignment check"
    case 18: return "#MC machine check"
    case 19: return "#XM SIMD floating-point error"
    case 20: return "#VE virtualization exception"
    case 21: return "#CP control protection"
    default: return "reserved exception"
    }
}

/// Never allocates (puts/printHex and the console's write and flush don't):
/// the heap may be what faulted. On screen: a white-on-red header and
/// footer, and the status bar turns red.
func exceptionReport(_ f: interrupt_frame) -> Never {
    _ = stdoutLock.acquireForPanic() // bounded spin, then write anyway
    statusBarAlert(" *** EXCEPTION: system halted (see the report below) ***")
    // Reset attributes first: the fault may have hit mid-way through output.
    puts("\u{1B}[0m\n\u{1B}[1;97;41m*** EXCEPTION "); printDec(f.vector); puts(": ")
    puts(exceptionName(f.vector)); puts(" ***\u{1B}[0m")
    puts("\n    cpu    "); printDec(cpuIndex())
    puts("\n    error  "); printHex(f.error_code)
    puts("\n    rip    "); printHex(f.rip)
    puts("\n    rsp    "); printHex(f.rsp)
    puts("\n    rflags "); printHex(f.rflags)
    if f.vector == 14 {
        puts("\n    cr2    "); printHex(read_cr2())
    }
    puts("\n\u{1B}[1;97;41m*** System halted. ***\u{1B}[0m\n")
    panicFlush() // on the desktop: straight to the framebuffer (Phase L)
    outb(0xF4, exceptionExitCode)
    hcf()
}

// MARK: 8259 PIC

enum PIC {
    static let masterCommand: UInt16 = 0x20, masterData: UInt16 = 0x21
    static let slaveCommand: UInt16 = 0xA0, slaveData: UInt16 = 0xA1
    static let vectorBase: UInt8 = 0x20
    static let eoi: UInt8 = 0x20
    /// Mask bits at init: everything off except IRQ0 (timer). ps2Init
    /// unmasks IRQ1 (keyboard), IRQ2 (cascade) and IRQ12 (mouse).
    static let masterMask: UInt8 = 0xFE
    static let slaveMask: UInt8 = 0xFF
}

/// Remap IRQ0-15 to vectors 0x20-0x2F (out of the CPU exception range).
func picInit() {
    outb(PIC.masterCommand, 0x11); io_wait() // ICW1: init, expect ICW4
    outb(PIC.slaveCommand, 0x11); io_wait()
    outb(PIC.masterData, PIC.vectorBase); io_wait() // ICW2: vector offsets
    outb(PIC.slaveData, PIC.vectorBase + 8); io_wait()
    outb(PIC.masterData, 0x04); io_wait() // ICW3: slave on IRQ2
    outb(PIC.slaveData, 0x02); io_wait() //       slave cascade identity
    outb(PIC.masterData, 0x01); io_wait() // ICW4: 8086 mode
    outb(PIC.slaveData, 0x01); io_wait()
    outb(PIC.masterData, PIC.masterMask)
    outb(PIC.slaveData, PIC.slaveMask)
}

func picUnmask(_ irq: UInt8) {
    let port = irq < 8 ? PIC.masterData : PIC.slaveData
    outb(port, inb(port) & ~(1 << (irq & 7)))
}

func picEOI(_ irq: UInt8) {
    if irq >= 8 { outb(PIC.slaveCommand, PIC.eoi) }
    outb(PIC.masterCommand, PIC.eoi)
}

/// In-service register: tells a real IRQ7/IRQ15 from a spurious one.
func picInService(_ command: UInt16) -> UInt8 {
    outb(command, 0x0B) // OCW3: read ISR
    return inb(command)
}

func handleIRQ(_ irq: UInt8) {
    // Spurious interrupts: no EOI for the chip that raised it (the master
    // still needs one for a spurious IRQ15, which came through the cascade).
    if irq == 7 && picInService(PIC.masterCommand) & 0x80 == 0 { return }
    if irq == 15 && picInService(PIC.slaveCommand) & 0x80 == 0 {
        outb(PIC.masterCommand, PIC.eoi)
        return
    }
    switch irq {
    case 0: ticks &+= 1; watchdogTick()
    case 1: keyboardIRQ()
    case 12: mouseIRQ()
    default: break
    }
    picEOI(irq) // IRQ8-15: slave, then master
}

// MARK: PIT timer

let timerHz: UInt64 = 100
let pitBaseHz: UInt64 = 1_193_182

/// Incremented by IRQ0. 64-bit aligned stores are atomic on x86-64, and the
/// hlt/sti/cli helpers clobber memory, so the main loop rereads it.
var ticks: UInt64 = 0

/// Channel 0, lobyte/hibyte, mode 3 (square wave) at ~timerHz.
func pitInit() {
    let divisor = UInt16(pitBaseHz / timerHz)
    outb(0x43, 0x36)
    outb(0x40, UInt8(truncatingIfNeeded: divisor))
    outb(0x40, UInt8(truncatingIfNeeded: divisor >> 8))
}

var interruptsEnabled: Bool { read_rflags() & 0x200 != 0 }
