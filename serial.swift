// COM1 UART: polled input/output plus allocation-free number formatting.

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

/// Wait for a byte (line status bit 0), then read it. The UART stays polled:
/// the CPU sleeps in `hlt` between checks and the timer IRQ wakes it.
func getc() -> UInt8 {
    while inb(com1 + 5) & 0x01 == 0 {
        if interruptsEnabled { hlt() } // hlt with IF=0 would never wake
    }
    return inb(com1)
}

/// Spin until the transmit holding register is empty (bit 5), then write.
func putc(_ byte: UInt8) {
    while inb(com1 + 5) & 0x20 == 0 {}
    outb(com1, byte)
}

/// Write a static string, translating `\n` to `\r\n` for the terminal.
func puts(_ s: StaticString) {
    s.withUTF8Buffer { buf in
        for byte in buf {
            if byte == 0x0A { putc(0x0D) }
            putc(byte)
        }
    }
}

func newline() {
    putc(0x0D)
    putc(0x0A)
}

/// Print `value` as `0x`-prefixed, zero-padded 16-digit hex.
func printHex(_ value: UInt64) {
    puts("0x")
    var shift: UInt64 = 60
    while true {
        let nibble = UInt8(truncatingIfNeeded: (value >> shift) & 0xF)
        putc(nibble < 10 ? 0x30 + nibble : 0x61 + nibble - 10)
        if shift == 0 { break }
        shift -= 4
    }
}

/// Print `value` in decimal using a fixed stack buffer (no allocation).
func printDec(_ value: UInt64) {
    var digits = InlineArray<20, UInt8>(repeating: 0)
    var n = value
    var count = 0
    repeat {
        digits[count] = 0x30 + UInt8(truncatingIfNeeded: n % 10)
        n /= 10
        count += 1
    } while n != 0
    while count > 0 {
        count -= 1
        putc(digits[count])
    }
}
