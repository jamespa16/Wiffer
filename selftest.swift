// In-kernel self-checks, run by the `selftest` command (used by ./run.sh --test).
// Each phase adds its checks to runSelfTests(). Results go to serial, and the
// pass/fail code goes to QEMU's isa-debug-exit device on port 0xF4, so QEMU
// exits with status (code << 1) | 1: 1 = all passed, 3 = something failed.

struct SelfTest {
    var passed = 0
    var failed = 0

    mutating func check(_ name: StaticString, _ condition: Bool) {
        puts(condition ? "  ok   " : "  FAIL ")
        puts(name)
        newline()
        if condition { passed += 1 } else { failed += 1 }
    }
}

func runSelfTests() -> Never {
    var t = SelfTest()
    puts("selftest:\n")

    // Part 1: formatting and parsing helpers.
    var shell = Shell()
    ("0xFfA0" as StaticString).withUTF8Buffer { buf in
        for i in 0..<buf.count { shell.line[i] = buf[i] }
        shell.len = buf.count
    }
    t.check("parseHex 0xFfA0", shell.parseHex(Span(start: 0, end: 6)) == 0xFFA0)
    t.check("parseHex rejects empty", shell.parseHex(Span(start: 0, end: 0)) == nil)
    t.check("framebuffer present", (framebuffer_request.response?.pointee.framebuffer_count ?? 0) > 0)
    t.check("memory map present", (memmap_request.response?.pointee.entry_count ?? 0) > 0)

    // Phase A: descriptor tables.
    let gdtr = read_gdtr()
    t.check("GDT loaded", gdtr.base == address(of: &gdt) && Int(gdtr.limit) == gdt.count * 8 - 1)
    t.check("CS/SS are kernel selectors", read_cs() == Selector.kernelCode && read_ss() == Selector.kernelData)
    t.check("TSS loaded (TR)", read_tr() == Selector.tss)
    t.check("TSS ist1 = top of #DF stack",
            UInt64(tss[10]) << 32 | UInt64(tss[9]) == address(of: &doubleFaultStack) + UInt64(doubleFaultStack.count))
    let idtr = read_idtr()
    t.check("IDT loaded", idtr.base == address(of: &idt) && Int(idtr.limit) == idtVectors * 16 - 1)
    t.check("#DF gate uses IST1", (idt[doubleFaultVector * 2] >> 32) & 7 == 1)
    t.check("IRQ gates present", (idt[47 * 2] >> 47) & 1 == 1 && (idt[48 * 2] >> 47) & 1 == 0)

    // Phase B: PIC, timer, idle.
    t.check("PIC masks all but IRQ0", inb(PIC.masterData) == 0xFE && inb(PIC.slaveData) == 0xFF)
    t.check("interrupts enabled", interruptsEnabled)
    let start = ticks
    for _ in 0..<5 { hlt() }
    t.check("ticks advance across hlt", ticks > start)
    let wait = ticks
    while ticks < wait + 10 { hlt() }
    t.check("timer keeps firing (EOI sent)", ticks >= wait + 10)

    puts("selftest: "); printDec(UInt64(t.passed)); puts(" passed, ")
    printDec(UInt64(t.failed)); puts(" failed\n")
    qemuExit(t.failed == 0 ? 0 : 1)
}

/// Write to QEMU's isa-debug-exit device. Without that device, just halt.
func qemuExit(_ code: UInt8) -> Never {
    outb(0xF4, code)
    hcf()
}
