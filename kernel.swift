// Embedded Swift kernel entry point, booted by Limine in 64-bit long mode.

@_cdecl("kernel_main")
public func kernelMain() -> Never {
    serialInit()

    // Limine zeroes the third word if it supports our base revision.
    guard limine_base_revision.2 == 0 else {
        puts("Limine base revision not supported\n")
        hcf()
    }
    puts("Hello from Embedded Swift!\n")

    // Descriptor tables first so any fault after this point gets a report.
    gdtInit()
    idtInit()

    // Frame allocator next: the Swift heap draws its memory from it, so no
    // allocation (classes, Array, String, print) may happen before this.
    guard pmm.initialize() else {
        puts("pmm: no usable memory map / HHDM\n")
        hcf()
    }
    // The framebuffer console needs the heap. Output so far was kept in
    // earlyLog and is replayed onto the screen.
    consoleInit()
    print("free: \(pmm.freeFrames) frames")

    // PIC is remapped before any IRQ can arrive, then the timer, then sti.
    picInit()
    pitInit()
    ps2Init() // unmasks IRQ1/IRQ2/IRQ12 if the devices answer
    sti()
    puts("GDT, IDT, PIC, PIT and PS/2 ready; interrupts on.\n")

    if ps2.mouse { cursorDraw(x: mouse.x, y: mouse.y) }

    var shell = Shell()
    shell.run()
}
