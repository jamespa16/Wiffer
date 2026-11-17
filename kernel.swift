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

    if let resp = framebuffer_request.response, resp.pointee.framebuffer_count > 0,
       let fb = resp.pointee.framebuffers[0] {
        drawGradient(fb)
        puts("Framebuffer drawn.\n")
    } else {
        puts("No framebuffer.\n")
    }

    var shell = Shell()
    shell.run()
}
