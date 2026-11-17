// Embedded Swift kernel entry point, booted by Limine in 64-bit long mode.

/// The ELF entry point (linker.ld ENTRY). SSE must be on before any code
/// compiled with SSE runs, and the compiler may use xmm registers in any
/// function, prologue included (e.g. to zero the Shell's line buffer). So this
/// function does nothing but enable SSE (integer-only, inlined) and call on,
/// never inlined into it; build.sh fails the build if kernel_main or
/// kernelEntry contains any xmm instruction. Limine enters with rsp as if
/// after a call (16-byte aligned + 8), so the SysV alignment holds for Swift.
@_cdecl("kernel_main")
public func kernelEntry() -> Never {
    enableSSE()
    enterBootStack()
}

/// 64 KiB kernel stack in .bss, used through its lower-half alias.
var bootStack = InlineArray<65536, UInt8>(repeating: 0)

/// Leave Limine's stack, which is HHDM memory (0xffff8000...), for bootStack
/// at its lower-half alias (0x00007fff8...). Stack addresses end up inside
/// Swift values too: e.g. String == on small strings wraps a stack copy of
/// their bytes in a String, and Swift keeps flags in the top pointer bits
/// (ROADMAP C3), so on a high stack canonical equivalence silently failed.
/// The alias needs PML4[255]; mapLowerHalf installs it (pmm.initialize does
/// it again later, harmlessly). If that fails, stay put: pmm.initialize will
/// fail the same way and report it.
@inline(never)
func enterBootStack() -> Never {
    if let hhdm = hhdm_request.response {
        pmm.hhdmOffset = UInt(hhdm.pointee.offset)
        if pmm.mapLowerHalf() {
            let top = (UInt(address(of: &bootStack)) + UInt(bootStack.count) - kernelAliasOffset) & ~15
            switch_stack(UInt64(top)) { kernelMain() }
        }
    }
    kernelMain()
}

@inline(never)
func kernelMain() -> Never {
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
