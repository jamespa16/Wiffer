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

    // Phase C: frame allocator and heap.
    memoryTests(&t)

    puts("selftest: "); printDec(UInt64(t.passed)); puts(" passed, ")
    printDec(UInt64(t.failed)); puts(" failed\n")
    qemuExit(t.failed == 0 ? 0 : 1)
}

/// Write to QEMU's isa-debug-exit device. Without that device, just halt.
func qemuExit(_ code: UInt8) -> Never {
    outb(0xF4, code)
    hcf()
}

final class Node {
    var next: Node?
    let value: Int
    init(_ value: Int, next: Node?) { self.value = value; self.next = next }
}

/// Snapshot of live heap usage, to check that a test returns to baseline.
/// (Frames held by the size-class free lists are not counted: they stay
/// with the heap for reuse.)
struct HeapUsage: Equatable {
    var bytes = heap.bytesInUse
    var blocks = heap.liveCount
    var largeFrames = heap.largeFrames
}

@inline(never)
func buildAndFreeList(_ count: Int) -> Int {
    var head: Node? = nil
    for i in 0..<count { head = Node(i, next: head) }
    var sum = 0
    // Unlink iteratively: dropping the head of a 10k list in one release
    // would recurse 10k deep and overflow the kernel stack.
    while let n = head { sum += n.value; head = n.next }
    return sum
}

@inline(never)
func arrayGrowth() -> Bool {
    var a: [Int] = []
    for i in 0..<1000 { a.append(i * 3) }
    var sum = 0
    for x in a { sum += x }
    return a.count == 1000 && a[999] == 2997 && sum == 3 * 999 * 1000 / 2
}

@inline(never)
func interpolation() -> Bool {
    let n = 42, m = -7
    // The literal segments are > 15 bytes, so they are pointer-backed
    // (not small strings) and go through the kernel's lower-half alias.
    let s = "first segment, long: x=\(n) y=\(m) \("and a long literal arg")"
    // Compare bytes: String == needs the Unicode normalization tables
    // (libswiftUnicodeDataTables), which the kernel doesn't link.
    let want: StaticString = "first segment, long: x=42 y=-7 and a long literal arg"
    return want.withUTF8Buffer { s.utf8.elementsEqual($0) }
}

func memoryTests(_ t: inout SelfTest) {
    t.check("pmm initialised", pmm.totalFrames > 0 && pmm.freeFrames > 0)
    t.check("pmm used + free == total", pmm.usedFrames + pmm.freeFrames == pmm.totalFrames)

    // Raw frames: allocate, check reuse after free.
    let before = pmm.freeFrames
    let f1 = pmm.allocate()
    let f2 = pmm.allocate(count: 3)
    t.check("pmm allocate", f1 != nil && f2 != nil && pmm.freeFrames == before - 4)
    t.check("pmm frames aligned", (f1 ?? 1) % UInt(frameSize) == 0 && (f2 ?? 1) % UInt(frameSize) == 0)
    if let f1, let f2 {
        pmm.free(f2, count: 3)
        pmm.free(f1)
    }
    t.check("pmm free restores count", pmm.freeFrames == before)
    t.check("pmm reuses freed frame", pmm.allocate() == f1)
    if let f1 { pmm.free(f1) }

    // Stress: 10k class instances, several rounds, no leak.
    let base = HeapUsage()
    var sums = buildAndFreeList(10_000)
    let framesAfterFirst = pmm.freeFrames
    for _ in 0..<3 { sums += buildAndFreeList(10_000) }
    t.check("10k-node list values", sums == 4 * (9_999 * 10_000 / 2))
    t.check("10k-node list no leak", HeapUsage() == base)
    t.check("free lists reused (no new frames)", pmm.freeFrames == framesAfterFirst)

    t.check("Array growth", arrayGrowth())
    t.check("Array freed", HeapUsage() == base)
    t.check("String interpolation", interpolation())
    t.check("String freed", HeapUsage() == base)

    // Large (frame-backed) allocation: freed back to the pmm, then reused.
    let framesBefore = pmm.freeFrames
    let big = UnsafeMutableRawPointer.allocate(byteCount: 10_000, alignment: 16)
    t.check("large alloc is frame-backed", heap.largeBlocks == 1 && heap.largeFrames == 3
            && pmm.freeFrames == framesBefore - 3)
    let bytes = big.bindMemory(to: UInt8.self, capacity: 10_000)
    for i in 0..<10_000 { bytes[i] = UInt8(truncatingIfNeeded: i) }
    t.check("large alloc read back", bytes[9_999] == UInt8(truncatingIfNeeded: 9_999))
    big.deallocate()
    t.check("large free returns frames", HeapUsage() == base && pmm.freeFrames == framesBefore)
    let big2 = UnsafeMutableRawPointer.allocate(byteCount: 10_000, alignment: 16)
    t.check("large alloc reuses frames", big2 == big)
    big2.deallocate()

    // Alignment is honoured for small and large blocks.
    var aligned = true
    for shift in 3...13 {
        let align = 1 << shift
        for size in [8, 100, 3_000] {
            let p = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: align)
            if UInt(bitPattern: p) % UInt(align) != 0 { aligned = false }
            p.storeBytes(of: 0xAB, toByteOffset: size - 1, as: UInt8.self)
            p.deallocate()
        }
    }
    t.check("alignment 8..8192 honoured", aligned)
    t.check("alignment tests freed", HeapUsage() == base)

    t.check("enum holding the empty array", enumEmptyArray())
    t.check("enum holding a static array", enumStaticArray())
    t.check("enum holding a literal String", enumLiteralString())

    // Heap pointers are low (identity-mapped) addresses; see mapLowerHalf.
    let node = Node(1, next: nil)
    t.check("heap objects in lower half", UInt(bitPattern: Unmanaged.passUnretained(node).toOpaque()) < 1 << 47)
    print("  heap: \(heap.bytesInUse) bytes live, free: \(pmm.freeFrames) frames")
}

/// A statically initialised array object, placed in the kernel image.
let staticPrimes = [2, 3, 5, 7, 11]

enum Payload {
    case list([Int])
    case other([Int])
    case text(String)
}

@inline(never)
func makePayload(_ k: Int) -> Payload {
    switch k {
    case 0: return .list([])                 // the empty-array singleton
    case 1: return .other(staticPrimes)      // a static object
    default: return .text("a literal longer than fifteen bytes")
    }
}

// Multi-payload enums keep their tag in pointer spare bits (the top nibble),
// so the objects they hold must be at low addresses, including static ones
// in the kernel image (reached through the build.sh rewrite + alias).

@inline(never)
func enumEmptyArray() -> Bool {
    guard case .list(var a) = makePayload(0) else { return false }
    guard a.isEmpty else { return false }
    a.append(1)
    return a.count == 1 && a[0] == 1
}

@inline(never)
func enumStaticArray() -> Bool {
    guard case .other(let p) = makePayload(1) else { return false }
    return p.count == 5 && p[0] == 2 && p[4] == 11
}

@inline(never)
func enumLiteralString() -> Bool {
    guard case .text(let s) = makePayload(2) else { return false }
    return s.utf8.count == 35 && s.utf8.first == 0x61
}
