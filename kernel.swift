// Embedded Swift kernel entry point, booted by Limine in 64-bit long mode.

let com1: UInt16 = 0x3F8

func serialInit() {
    outb(com1 + 1, 0x00) // disable interrupts
    outb(com1 + 3, 0x80) // enable DLAB
    outb(com1 + 0, 0x03) // divisor 3 -> 38400 baud
    outb(com1 + 1, 0x00)
    outb(com1 + 3, 0x03) // 8N1
    outb(com1 + 2, 0xC7) // enable FIFO
    outb(com1 + 4, 0x0B) // RTS/DSR
}

func serialWrite(_ s: StaticString) {
    s.withUTF8Buffer { buf in
        for byte in buf {
            while inb(com1 + 5) & 0x20 == 0 {} // wait for transmit empty
            outb(com1, byte)
        }
    }
}

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
        serialWrite("Limine base revision not supported\n")
        hcf()
    }
    serialWrite("Hello from Embedded Swift!\n")

    if let resp = framebuffer_request.response, resp.pointee.framebuffer_count > 0,
       let fb = resp.pointee.framebuffers[0] {
        drawGradient(fb)
        serialWrite("Framebuffer drawn.\n")
    } else {
        serialWrite("No framebuffer.\n")
    }

    serialWrite("Halting.\n")
    hcf()
}
