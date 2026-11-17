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

/// null, kernel code64, kernel data, user data, user code64, TSS (2 slots).
var gdt = InlineArray<7, UInt64>(repeating: 0)

/// The 104-byte 64-bit TSS, as 32-bit words because its 64-bit fields are
/// only 4-byte aligned. Word 1-2: rsp0, 9-10: ist1, 25 (high half): I/O map base.
var tss = InlineArray<26, UInt32>(repeating: 0)
let tssSize = 104

/// Stack for the double-fault handler, selected through TSS.ist1. The CPU
/// aligns rsp down to 16 bytes on entry, so the array needs no extra alignment.
var doubleFaultStack = InlineArray<16384, UInt8>(repeating: 0)

func address<T>(of value: inout T) -> UInt64 {
    withUnsafeMutablePointer(to: &value) { UInt64(UInt(bitPattern: $0)) }
}

func gdtInit() {
    gdt[1] = 0x00AF_9A00_0000_FFFF // kernel code: present, DPL0, exec/read, L=1
    gdt[2] = 0x00CF_9200_0000_FFFF // kernel data: present, DPL0, read/write
    gdt[3] = 0x00CF_F200_0000_FFFF // user data:   present, DPL3, read/write
    gdt[4] = 0x00AF_FA00_0000_FFFF // user code:   present, DPL3, exec/read, L=1

    let ist1 = address(of: &doubleFaultStack) + UInt64(doubleFaultStack.count)
    tss[9] = UInt32(truncatingIfNeeded: ist1)
    tss[10] = UInt32(truncatingIfNeeded: ist1 >> 32)
    tss[25] = UInt32(tssSize) << 16 // I/O map base past the limit: no I/O bitmap

    // 16-byte system descriptor: type 0x9 (available 64-bit TSS), present.
    let base = address(of: &tss)
    let limit = UInt64(tssSize - 1)
    gdt[5] = (limit & 0xFFFF)
        | (base & 0xFF_FFFF) << 16
        | 0x89 << 40
        | (limit >> 16 & 0xF) << 48
        | (base >> 24 & 0xFF) << 56
    gdt[6] = base >> 32

    var gdtr = descriptor_ptr(limit: UInt16(gdt.count * 8 - 1), base: address(of: &gdt))
    gdt_load(&gdtr, Selector.kernelCode, Selector.kernelData, Selector.tss)
}

// MARK: IDT

/// 256 16-byte gates as pairs of words. Vectors without a stub stay
/// not-present (an interrupt there raises #NP, which gets reported).
var idt = InlineArray<512, UInt64>(repeating: 0)
let idtVectors = 256
let doubleFaultVector = 8

func setGate(_ vector: Int, handler: UInt64, ist: UInt64 = 0) {
    // Present, DPL0, type 0xE (64-bit interrupt gate: IF is cleared on entry).
    idt[vector * 2] = (handler & 0xFFFF)
        | UInt64(Selector.kernelCode) << 16
        | ist << 32
        | 0x8E << 40
        | (handler >> 16 & 0xFFFF) << 48
    idt[vector * 2 + 1] = handler >> 32
}

func idtInit() {
    withUnsafePointer(to: isr_stub_table) { table in
        table.withMemoryRebound(to: UInt64.self, capacity: 48) { stubs in
            for v in 0..<48 {
                setGate(v, handler: stubs[v], ist: v == doubleFaultVector ? 1 : 0)
            }
        }
    }
    var idtr = descriptor_ptr(limit: UInt16(idtVectors * 16 - 1), base: address(of: &idt))
    lidt(&idtr)
}
