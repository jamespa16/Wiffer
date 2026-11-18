// Phase A: our own GDT + TSS (with an IST stack for double faults) and the IDT.
// All tables are static storage. Only the lgdt/CS reload/ltr sequence and the
// entry stubs are in cpu.S.

// MARK: GDT + TSS

/// Segment selectors (GDT index * 8). User data comes before user code, the
/// order `sysret` will expect later.
enum Selector {
    static let kernelCode: UInt16 = 0x08
    static let kernelData: UInt16 = 0x10
    static let userData: UInt16 = 0x18 | 3
    static let userCode: UInt16 = 0x20 | 3
    static let tss: UInt16 = 0x28
}

// The GDT and TSS are per CPU (PerCPU.gdt/.tss, percpu.swift): a TSS
// descriptor's busy bit means two CPUs can't ltr the same one.

/// Stack for the BSP's double-fault handler, selected through TSS.ist1. The
/// CPU aligns rsp down to 16 bytes on entry, so the array needs no extra
/// alignment. APs get theirs from PerCPU.doubleFaultStackTop (Phase R).
var doubleFaultStack = InlineArray<16384, UInt8>(repeating: 0)
let tssSize = 104

func address<T>(of value: inout T) -> UInt64 {
    withUnsafeMutablePointer(to: &value) { UInt64(UInt(bitPattern: $0)) }
}

/// Load CPU `cpu`'s own GDT and TSS (lgdt, segment reload, ltr), then point
/// its GS base at its PerCPU entry. Runs on that CPU. For an AP, set
/// perCPU[cpu].doubleFaultStackTop first.
func gdtInit(cpu: Int) {
    let e = perCPUEntry(cpu)
    if e.pointee.doubleFaultStackTop == 0 {
        guard cpu == 0 else {
            puts("gdtInit: no double-fault stack for this CPU\n")
            hcf()
        }
        e.pointee.doubleFaultStackTop = address(of: &doubleFaultStack) + UInt64(doubleFaultStack.count)
    }
    e.pointee.gdt[0] = 0
    e.pointee.gdt[1] = 0x00AF_9A00_0000_FFFF // kernel code: present, DPL0, exec/read, L=1
    e.pointee.gdt[2] = 0x00CF_9200_0000_FFFF // kernel data: present, DPL0, read/write
    e.pointee.gdt[3] = 0x00CF_F200_0000_FFFF // user data:   present, DPL3, read/write
    e.pointee.gdt[4] = 0x00AF_FA00_0000_FFFF // user code:   present, DPL3, exec/read, L=1

    let ist1 = e.pointee.doubleFaultStackTop
    e.pointee.tss[9] = UInt32(truncatingIfNeeded: ist1)
    e.pointee.tss[10] = UInt32(truncatingIfNeeded: ist1 >> 32)
    e.pointee.tss[25] = UInt32(tssSize) << 16 // I/O map base past the limit: no I/O bitmap

    // 16-byte system descriptor: type 0x9 (available 64-bit TSS), present.
    let base = address(of: &e.pointee.tss)
    let limit = UInt64(tssSize - 1)
    e.pointee.gdt[5] = (limit & 0xFFFF)
        | (base & 0xFF_FFFF) << 16
        | 0x89 << 40
        | (limit >> 16 & 0xF) << 48
        | (base >> 24 & 0xFF) << 56
    e.pointee.gdt[6] = base >> 32

    var gdtr = descriptor_ptr(limit: UInt16(e.pointee.gdt.count * 8 - 1), base: address(of: &e.pointee.gdt))
    gdt_load(&gdtr, Selector.kernelCode, Selector.kernelData, Selector.tss)
    perCPUBind(cpu: cpu) // after gdt_load: reloading GS cleared its base
    syscallInit(cpu: cpu) // Phase 6B: SYSCALL MSRs, KERNEL_GS_BASE
}

// MARK: IDT

/// 256 16-byte gates as pairs of words, one stub per vector (cpu.S).
var idt = InlineArray<512, UInt64>(repeating: 0)
let idtVectors = 256
let doubleFaultVector = 8
let breakpointVector = 3

func setGate(_ vector: Int, handler: UInt64, ist: UInt64 = 0, user: Bool = false) {
    // Present, DPL0, type 0xE (64-bit interrupt gate: IF is cleared on entry).
    // Phase 6B: DPL3 (`user`) lets ring 3 raise it with an `int` instruction.
    idt[vector * 2] = (handler & 0xFFFF)
        | UInt64(Selector.kernelCode) << 16
        | ist << 32
        | (user ? 0xEE : 0x8E) << 40
        | (handler >> 16 & 0xFFFF) << 48
    idt[vector * 2 + 1] = handler >> 32
}

func idtInit() {
    let stubs = isr_stubs()! // a pointer: no copy of the 2 KiB table onto the boot stack
    for v in 0..<idtVectors {
        // #BP (int3) is DPL3, so a user int3 is a breakpoint, not a #GP.
        setGate(v, handler: stubs[v], ist: v == doubleFaultVector ? 1 : 0, user: v == breakpointVector)
    }
    idtLoad()
}

/// Load the shared IDT on this CPU (APs call this; the gates are built once).
func idtLoad() {
    var idtr = descriptor_ptr(limit: UInt16(idtVectors * 16 - 1), base: address(of: &idt))
    lidt(&idtr)
}
