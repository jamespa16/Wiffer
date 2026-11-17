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

    puts("selftest: "); printDec(UInt64(t.passed)); puts(" passed, ")
    printDec(UInt64(t.failed)); puts(" failed\n")
    qemuExit(t.failed == 0 ? 0 : 1)
}

/// Write to QEMU's isa-debug-exit device. Without that device, just halt.
func qemuExit(_ code: UInt8) -> Never {
    outb(0xF4, code)
    hcf()
}
