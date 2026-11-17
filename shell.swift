// Part 1 serial shell: line editing, parsing, and built-in commands.
// The line buffer is fixed-size stack storage; commands may use the heap.

/// A view of `line[start..<end]` without copying.
struct Span {
    var start: Int
    var end: Int
    var isEmpty: Bool { start >= end }
}

struct Shell {
    var line = InlineArray<128, UInt8>(repeating: 0)
    var len = 0

    mutating func run() -> Never {
        puts("Type 'help' for commands.\n")
        prompt()
        while true {
            let byte = getc()
            switch byte {
            case 0x0D, 0x0A: // Enter
                newline()
                execute()
                len = 0
                prompt()
            case 0x7F, 0x08: // Backspace / Delete
                if len > 0 {
                    len -= 1
                    puts("\u{8} \u{8}")
                }
            case 0..<32:
                break // ignore other control bytes
            default:
                if len < line.count {
                    line[len] = byte
                    len += 1
                    putc(byte)
                }
            }
        }
    }

    func prompt() { puts("> ") }

    // MARK: Parsing helpers

    func equals(_ span: Span, _ name: StaticString) -> Bool {
        name.withUTF8Buffer { buf in
            guard buf.count == span.end - span.start else { return false }
            for i in 0..<buf.count where buf[i] != line[span.start + i] { return false }
            return true
        }
    }

    func write(_ span: Span) {
        var i = span.start
        while i < span.end { putc(line[i]); i += 1 }
    }

    /// Skip leading spaces, then return the next space-delimited word.
    func word(from: Int) -> Span {
        var s = from
        while s < len && line[s] == 0x20 { s += 1 }
        var e = s
        while e < len && line[e] != 0x20 { e += 1 }
        return Span(start: s, end: e)
    }

    /// Parse a hex number with an optional `0x` prefix.
    func parseHex(_ span: Span) -> UInt64? {
        var i = span.start
        if span.end - i > 2 && line[i] == 0x30 && (line[i + 1] | 0x20) == 0x78 { i += 2 }
        guard i < span.end, span.end - i <= 16 else { return nil }
        var value: UInt64 = 0
        while i < span.end {
            let c = line[i] | 0x20 // fold to lower case
            let digit: UInt8
            switch c {
            case 0x30...0x39: digit = c - 0x30
            case 0x61...0x66: digit = c - 0x61 + 10
            default: return nil
            }
            value = value << 4 | UInt64(digit)
            i += 1
        }
        return value
    }

    // MARK: Dispatch

    func execute() {
        let cmd = word(from: 0)
        if cmd.isEmpty { return }
        var argStart = cmd.end
        while argStart < len && line[argStart] == 0x20 { argStart += 1 }
        let args = Span(start: argStart, end: len)

        if equals(cmd, "help") {
            puts("""
            help            show this list
            echo <text>     print text
            clear           clear the screen
            fb              framebuffer info
            mem             memory map, frame and heap stats
            peek <hex>      read a 64-bit value at an address
            uptime          time since boot (timer ticks at 100 Hz)
            fault <kind>    raise an exception: ud, de, pf, gp, df
            halt            stop the CPU
            reboot          reset via the keyboard controller
            selftest        run kernel self-checks (exits QEMU under --test)

            """)
        } else if equals(cmd, "echo") {
            write(args)
            newline()
        } else if equals(cmd, "clear") {
            puts("\u{1B}[2J\u{1B}[H")
        } else if equals(cmd, "halt") {
            puts("Halted.\n")
            consoleFlush()
            hcf()
        } else if equals(cmd, "reboot") {
            puts("Rebooting...\n")
            consoleFlush()
            reboot()
        } else if equals(cmd, "selftest") {
            runSelfTests()
        } else if equals(cmd, "fb") {
            framebufferInfo()
        } else if equals(cmd, "mem") {
            memoryInfo()
        } else if equals(cmd, "uptime") {
            uptime()
        } else if equals(cmd, "fault") {
            let kind = word(from: args.start)
            if equals(kind, "ud") {
                fault_invalid_opcode()
            } else if equals(kind, "de") {
                fault_divide_by_zero()
            } else if equals(kind, "pf") {
                // User-half address: Limine maps nothing there. Store a nonzero
                // value: for 0, -Osize emits `andq $0, (mem)`, which faults as a read.
                UnsafeMutablePointer<UInt64>(bitPattern: 0x0000_7000_0000_0000)!.pointee = 0x5A5A
            } else if equals(kind, "gp") {
                // Non-canonical: bits 63:47 aren't all equal.
                printHex(UnsafePointer<UInt64>(bitPattern: UInt(0xDEAD_0000_0000_0000))!.pointee)
            } else if equals(kind, "df") {
                fault_double()
            }
            puts("usage: fault <ud|de|pf|gp|df>\n")
        } else if equals(cmd, "peek") {
            guard let addr = parseHex(word(from: args.start)) else {
                puts("usage: peek <hex addr>\n")
                return
            }
            guard addr & 7 == 0, let ptr = UnsafePointer<UInt64>(bitPattern: UInt(addr)) else {
                puts("peek: address must be non-null and 8-byte aligned\n")
                return
            }
            printHex(addr)
            puts(": ")
            printHex(ptr.pointee)
            newline()
        } else {
            puts("unknown command: ")
            write(cmd)
            newline()
        }
    }
}

// MARK: Commands

func reboot() -> Never {
    // Wait for the keyboard controller input buffer to drain, then pulse reset.
    while inb(0x64) & 0x02 != 0 {}
    outb(0x64, 0xFE)
    hcf()
}

func uptime() {
    let t = ticks
    let hundredths = t % timerHz * 100 / timerHz
    puts("uptime: "); printDec(t / timerHz); puts(".")
    if hundredths < 10 { putc(0x30) }
    printDec(hundredths); puts(" s ("); printDec(t); puts(" ticks)\n")
}

func framebufferInfo() {
    guard let resp = framebuffer_request.response, resp.pointee.framebuffer_count > 0,
          let fb = resp.pointee.framebuffers[0] else {
        puts("no framebuffer\n")
        return
    }
    let f = fb.pointee
    puts("framebuffer: ")
    printDec(f.width); puts("x"); printDec(f.height)
    puts(", "); printDec(UInt64(f.bpp)); puts(" bpp, pitch ")
    printDec(f.pitch)
    puts(", at ")
    printHex(UInt64(UInt(bitPattern: f.address)))
    newline()
}

func memoryInfo() {
    guard let resp = memmap_request.response, let entries = resp.pointee.entries else {
        puts("no memory map\n")
        return
    }
    var usable: UInt64 = 0
    var total: UInt64 = 0
    for i in 0..<Int(resp.pointee.entry_count) {
        guard let e = entries[i] else { continue }
        total += e.pointee.length
        if e.pointee.type == UInt64(LIMINE_MEMMAP_USABLE) { usable += e.pointee.length }
    }
    let mib = { (frames: Int) in (frames * frameSize) >> 20 }
    print("memory map: \(resp.pointee.entry_count) entries, usable \(usable >> 20) MiB, all \(total >> 20) MiB (incl. reserved/MMIO)")
    print("frames: \(pmm.totalFrames) total (\(mib(pmm.totalFrames)) MiB), \(pmm.usedFrames) used (\(mib(pmm.usedFrames)) MiB), \(pmm.freeFrames) free (\(mib(pmm.freeFrames)) MiB)")
    print("heap: \(heap.bytesInUse) bytes in \(heap.liveCount) blocks, \(heap.chunkFrames) chunk frames, \(heap.allocations) allocs / \(heap.deallocations) frees")
    var classes = "heap classes:"
    for i in 0..<heapClassCount where heap.liveBlocks[i] > 0 {
        classes += " \(Heap.classSize(i))B:\(heap.liveBlocks[i])"
    }
    print(classes + " large:\(heap.largeBlocks) (\(heap.largeFrames) frames)")
}
