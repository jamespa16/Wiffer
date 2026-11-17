// Embedded Swift kernel entry point, booted by Limine in 64-bit long mode.

func drawGradient(_ fb: UnsafeMutablePointer<limine_framebuffer>) {
    let f = fb.pointee
    guard f.bpp == 32, let base = f.address else { return }
    let pixels = base.assumingMemoryBound(to: UInt32.self)
    let stride = Int(f.pitch / 4)
    let w = Int(f.width), h = Int(f.height)
    for y in 0..<h {
        for x in 0..<w {
            let r = UInt32(x * 255 / w), g = UInt32(y * 255 / h), b: UInt32 = 0x80
            pixels[y * stride + x] = (r << 16) | (g << 8) | b
        }
    }
}

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
    print("free: \(pmm.freeFrames) frames")

    // PIC is remapped before any IRQ can arrive, then the timer, then sti.
    picInit()
    pitInit()
    ps2Init() // unmasks IRQ1/IRQ2/IRQ12 if the devices answer
    sti()
    puts("GDT, IDT, PIC, PIT and PS/2 ready; interrupts on.\n")

    if let resp = framebuffer_request.response, resp.pointee.framebuffer_count > 0,
       let fb = resp.pointee.framebuffers[0] {
        drawGradient(fb)
        if ps2.mouse { cursorDraw(x: mouse.x, y: mouse.y) }
        puts("Framebuffer drawn.\n")
    } else {
        puts("No framebuffer.\n")
    }

    var shell = Shell()
    shell.run()
}
