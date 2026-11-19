// Phase Q: x2APIC (MSR interface only, no MMIO), IPIs and the reserved IPI
// vectors. Device IRQs stay on the 8259 PIC; the BSP's LAPIC passes them
// through LINT0 in ExtINT (virtual-wire) mode. Without x2APIC (e.g. QEMU's
// default CPU) everything here is a no-op and the kernel runs on the PIC alone.

enum Vector {
    /// Phase 6D: the LAPIC timer (APs; preemption only).
    static let timer: UInt8 = 0xEF
    /// Phase 7F: virtio-net MSI-X (rx), aimed at CPU 0.
    static let net: UInt8 = 0x50
    static let reschedule: UInt8 = 0xF0
    static let halt: UInt8 = 0xF1
    static let ping: UInt8 = 0xF2
    static let spurious: UInt8 = 0xFF
}

enum APICReg { // x2APIC MSRs
    static let base: UInt32 = 0x1B
    static let id: UInt32 = 0x802
    static let tpr: UInt32 = 0x808
    static let eoi: UInt32 = 0x80B
    static let spurious: UInt32 = 0x80F
    static let icr: UInt32 = 0x830
    static let lint0: UInt32 = 0x835
    static let lint1: UInt32 = 0x836
    static let lvtTimer: UInt32 = 0x832
    static let timerInitial: UInt32 = 0x838
    static let timerCurrent: UInt32 = 0x839
    static let timerDivide: UInt32 = 0x83E
}

/// Set by apicInit when x2APIC was found and enabled on this (boot) CPU.
var x2apicEnabled = false
/// Vector 0xF2 deliveries to this CPU (perCPU ipisReceived; no allocation).
var apicPingCount: UInt64 { thisCPU().pointee.ipisReceived }

/// CPUID.1:ECX bit 21.
func x2apicSupported() -> Bool {
    cpuid(1, 0).ecx & (1 << 21) != 0
}

/// Enable x2APIC on the calling CPU: IA32_APIC_BASE bits 11 (enable) and 10
/// (x2APIC), software-enable via the spurious-vector register, TPR 0.
/// `bsp` programs LINT0 = ExtINT and LINT1 = NMI; APs mask both.
func apicEnableThisCPU(bsp: Bool) {
    wrmsr(APICReg.base, rdmsr(APICReg.base) | (1 << 11) | (1 << 10))
    wrmsr(APICReg.spurious, 0x100 | UInt64(Vector.spurious))
    wrmsr(APICReg.tpr, 0)
    if bsp {
        wrmsr(APICReg.lint0, 0x700) // ExtINT, unmasked
        wrmsr(APICReg.lint1, 0x400) // NMI, unmasked
    } else {
        wrmsr(APICReg.lint0, 0x10000)
        wrmsr(APICReg.lint1, 0x10000)
    }
}

/// Boot CPU setup. Call after picInit and before sti.
func apicInit() {
    guard x2apicSupported() else { return }
    apicEnableThisCPU(bsp: true)
    x2apicEnabled = true
    thisCPU().pointee.apicID = UInt64(apicID())
    puts("apic: x2APIC enabled, id "); printDec(UInt64(apicID())); puts("\n")
}

func apicID() -> UInt32 {
    x2apicEnabled ? UInt32(truncatingIfNeeded: rdmsr(APICReg.id)) : 0
}

func apicEOI() { wrmsr(APICReg.eoi, 0) }

enum IPIShorthand: UInt64 {
    case none = 0, this = 1, all = 2, others = 3
}

/// One 64-bit ICR write. `nmi` selects NMI delivery (the vector is ignored).
func apicSend(vector: UInt8, shorthand: IPIShorthand, dest: UInt32 = 0, nmi: Bool = false) {
    guard x2apicEnabled else { return }
    let mode: UInt64 = nmi ? 0x400 : 0
    wrmsr(APICReg.icr, UInt64(dest) << 32 | shorthand.rawValue << 18 | 1 << 14 | mode | UInt64(vector))
}

func sendIPI(apicID: UInt32, vector: UInt8) {
    apicSend(vector: vector, shorthand: .none, dest: apicID)
}

func sendSelfIPI(vector: UInt8) {
    apicSend(vector: vector, shorthand: .this)
}

func broadcastIPI(vector: UInt8, excludingSelf: Bool) {
    apicSend(vector: vector, shorthand: excludingSelf ? .others : .all)
}

/// NMI to one CPU, or to every other CPU when `apicID` is nil (for panics).
func sendNMI(apicID: UInt32?) {
    if let id = apicID {
        apicSend(vector: 0, shorthand: .none, dest: id, nmi: true)
    } else {
        apicSend(vector: 0, shorthand: .others, nmi: true)
    }
}

/// Vectors 0xF0 and up, from interrupt_dispatch. No allocation.
func apicInterrupt(_ vector: UInt8) {
    if vector == Vector.spurious { return } // spurious: no EOI
    if vector == Vector.ping { thisCPU().pointee.ipisReceived &+= 1 }
    if x2apicEnabled { apicEOI() }
    if vector == Vector.halt { panicHaltThisCPU() }
    // 0xF0 (reschedule) needs nothing else: waking from hlt is the point (the
    // idle loop then rechecks the run queue).
}

// MARK: LAPIC timer (Phase 6D1)
//
// Every AP runs its LAPIC timer periodically at timerHz, on vector 0xEF, to
// preempt ring 3 (preempt.swift). CPU 0 keeps the PIT: it is the clock
// (`ticks`), it preempts CPU 0, and it measures the LAPIC timer once at
// boot (apicTimerCalibrate): QEMU's LAPICs all count at the same rate.

/// LAPIC timer counts per timer tick (divide by 16); 0 until calibrated
/// (no x2APIC: no AP timers, and no APs either).
var apicTimerCountPerTick: UInt64 = 0
/// Divide configuration 0b0011: divide by 16.
let apicTimerDivide: UInt64 = 0x3

/// Count the BSP's LAPIC timer over `calibrationTicks` PIT ticks. Needs
/// interrupts on (the PIT advancing `ticks`). Leaves the BSP's timer off.
func apicTimerCalibrate() {
    guard x2apicEnabled, interruptsEnabled else { return }
    let calibrationTicks: UInt64 = 5
    wrmsr(APICReg.timerDivide, apicTimerDivide)
    wrmsr(APICReg.lvtTimer, 0x10000 | UInt64(Vector.timer)) // masked, one-shot
    let edge = ticks
    while ticks == edge { hlt() } // start on a tick edge
    let start = ticks
    wrmsr(APICReg.timerInitial, 0xFFFF_FFFF)
    while ticks < start + calibrationTicks { hlt() }
    let left = rdmsr(APICReg.timerCurrent)
    wrmsr(APICReg.timerInitial, 0)
    apicTimerCountPerTick = max((0xFFFF_FFFF - left) / calibrationTicks, 1)
    puts("apic: LAPIC timer "); printDec(apicTimerCountPerTick); puts(" counts per tick (/16)\n")
}

/// Start this CPU's LAPIC timer: periodic, unmasked, every tick. An AP, in
/// apMain, once its IDT is loaded.
func apicTimerStart() {
    guard x2apicEnabled, apicTimerCountPerTick != 0 else { return }
    wrmsr(APICReg.timerDivide, apicTimerDivide)
    wrmsr(APICReg.lvtTimer, 0x20000 | UInt64(Vector.timer)) // periodic
    wrmsr(APICReg.timerInitial, apicTimerCountPerTick)
}

/// Vector 0xEF: EOI, then count the tick for the slice (preempt.swift).
func apicTimerInterrupt() {
    apicEOI()
    thisCPU().pointee.lapicTicks &+= 1
    sliceTick()
}

func apicTests(_ t: inout SelfTest) {
    t.check("IDT: all 256 vectors present", (idt[0xF0 * 2] >> 47) & 1 == 1 && (idt[255 * 2] >> 47) & 1 == 1)
    if !x2apicEnabled {
        puts("  note x2APIC not available (default CPU): APIC tests skipped\n")
        t.check("x2APIC absent: PIC-only", !x2apicEnabled)
        return
    }
    t.check("x2APIC enabled in IA32_APIC_BASE", rdmsr(APICReg.base) & 0xC00 == 0xC00)
    t.check("spurious vector register", rdmsr(APICReg.spurious) == 0x1FF)
    t.check("LINT0 ExtINT, LINT1 NMI", rdmsr(APICReg.lint0) == 0x700 && rdmsr(APICReg.lint1) == 0x400)
    let before = apicPingCount
    sendSelfIPI(vector: Vector.ping)
    var spins = 0
    while apicPingCount == before && spins < 10_000_000 { spins += 1; cpu_pause() }
    t.check("self-IPI 0xF2 counted", apicPingCount == before + 1)
    let b2 = apicPingCount
    sendIPI(apicID: apicID(), vector: Vector.ping)
    spins = 0
    while apicPingCount == b2 && spins < 10_000_000 { spins += 1; cpu_pause() }
    t.check("physical-destination IPI to self", apicPingCount == b2 + 1)
    // The timer still ticks after IPIs (EOI sent, PIC path intact).
    let tk = ticks
    while ticks < tk + 3 { hlt() }
    t.check("PIC timer ticks through LINT0", ticks >= tk + 3)
    // 6D1: the BSP's LAPIC timer was measured (and left off).
    t.check("6D: LAPIC timer calibrated, BSP timer off", apicTimerCountPerTick > 0
            && rdmsr(APICReg.timerInitial) == 0)
}
