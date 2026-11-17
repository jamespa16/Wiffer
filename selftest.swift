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
    t.check("parseHex 0xFfA0", parseHex("0xFfA0") == 0xFFA0)
    t.check("parseHex rejects empty", parseHex("") == nil && parseHex("0x") == nil)
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
    t.check("PIC unmasks IRQ0/1/2/12 only", inb(PIC.masterData) == 0xF8 && inb(PIC.slaveData) == 0xEF)
    t.check("interrupts enabled", interruptsEnabled)
    let start = ticks
    for _ in 0..<5 { hlt() }
    t.check("ticks advance across hlt", ticks > start)
    let wait = ticks
    while ticks < wait + 10 { hlt() }
    t.check("timer keeps firing (EOI sent)", ticks >= wait + 10)

    // Phase C: frame allocator and heap.
    memoryTests(&t)

    // Phase F: PS/2 input.
    inputTests(&t)

    // Phase E: console model, font, display.
    consoleTests(&t)

    // Phase D: SSE, Float, Dictionary, Set, String ==.
    sseTests(&t)

    // Phase G: terminal, line editor, command table.
    shellTests(&t)

    // Phase M: RAM filesystem, ustar, file commands.
    fsTests(&t)

    puts("selftest: "); printDec(UInt64(t.passed)); puts(" passed, ")
    printDec(UInt64(t.failed)); puts(" failed\n")
    qemuExit(t.failed == 0 ? 0 : 1)
}

/// Write to QEMU's isa-debug-exit device. Without that device, just halt.
func qemuExit(_ code: UInt8) -> Never {
    consoleFlush()
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
    // Compare bytes (String == is tested separately, in sseTests).
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
    let (largeBefore, largeFramesBefore) = (heap.largeBlocks, heap.largeFrames) // e.g. console buffers
    let big = UnsafeMutableRawPointer.allocate(byteCount: 10_000, alignment: 16)
    t.check("large alloc is frame-backed", heap.largeBlocks == largeBefore + 1
            && heap.largeFrames == largeFramesBefore + 3
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

// MARK: Phase F

func decode(_ codes: [UInt8]) -> [KeyEvent] {
    var d = ScancodeDecoder()
    var events: [KeyEvent] = []
    for c in codes { if let e = d.feed(c) { events.append(e) } }
    return events
}

func chars(_ s: StaticString) -> [KeyEvent] {
    s.withUTF8Buffer { buf in buf.map { KeyEvent.char($0) } }
}

func parsePackets(_ bytes: [UInt8]) -> [MousePacket] {
    var p = MousePacketParser()
    var packets: [MousePacket] = []
    for b in bytes { if let pk = p.feed(b) { packets.append(pk) } }
    return packets
}

func inputTests(_ t: inout SelfTest) {
    t.check("8042 keyboard and mouse found", ps2.controller && ps2.keyboard && ps2.mouse)
    t.check("8042 IRQs + translation on", ps2.config & 0x43 == 0x43)
    t.check("scancode tables cover 0x00-0x39",
            scancodeBase.utf8CodeUnitCount == 0x3A && scancodeShift.utf8CodeUnitCount == 0x3A)

    // Scancode set 1 decoding.
    t.check("a, z, 1, space", decode([0x1E, 0x9E, 0x2C, 0x02, 0x39]) == chars("az1 "))
    t.check("shift+a -> A", decode([0x2A, 0x1E]) == chars("A"))
    t.check("shift release -> a", decode([0x2A, 0x1E, 0x9E, 0xAA, 0x1E]) == chars("Aa"))
    t.check("right shift + 1 -> !", decode([0x36, 0x02, 0xB6, 0x02]) == chars("!1"))
    t.check("caps+a -> A, caps+1 -> 1", decode([0x3A, 0xBA, 0x1E, 0x02]) == chars("A1"))
    t.check("caps+shift+a -> a", decode([0x3A, 0xBA, 0x2A, 0x1E]) == chars("a"))
    t.check("caps repeat toggles once", decode([0x3A, 0x3A, 0x3A, 0xBA, 0x1E]) == chars("A"))
    t.check("ctrl+c -> 0x03", decode([0x1D, 0x2E, 0x9D, 0x2E]) == [.char(0x03), .char(0x63)])
    t.check("right ctrl (E0 1D) + a -> 0x01", decode([0xE0, 0x1D, 0x1E]) == [.char(0x01)])
    t.check("enter, backspace, tab, esc",
            decode([0x1C, 0x0E, 0x0F, 0x01]) == [.char(0x0D), .char(0x08), .char(0x09), .char(0x1B)])
    t.check("E0 48 -> up, release ignored", decode([0xE0, 0x48, 0xE0, 0xC8]) == [.up])
    t.check("E0 arrows/home/end/delete/pgup/pgdn",
            decode([0xE0, 0x50, 0xE0, 0x4B, 0xE0, 0x4D, 0xE0, 0x47, 0xE0, 0x4F,
                    0xE0, 0x53, 0xE0, 0x49, 0xE0, 0x51])
            == [.down, .left, .right, .home, .end, .delete, .pageUp, .pageDown])
    t.check("E0 fake shift ignored", decode([0xE0, 0x2A, 0xE0, 0x47, 0xE0, 0xAA, 0x1E]) == [.home, .char(0x61)])
    t.check("keypad enter (E0 1C) -> \\r", decode([0xE0, 0x1C]) == [.char(0x0D)])
    t.check("keypad 8: up, then 8 with num lock", decode([0x48, 0x45, 0xC5, 0x48]) == [.up, .char(0x38)])
    t.check("pause (E1 ...) swallowed", decode([0xE1, 0x1D, 0x45, 0xE1, 0x9D, 0xC5, 0x1E]) == chars("a"))
    t.check("releases alone emit nothing", decode([0x9E, 0xAA, 0x81]).isEmpty)

    // Ring buffer: FIFO order, drop when full.
    var ring = ByteRing()
    for i in 0..<200 { ring.push(UInt8(truncatingIfNeeded: i)) }
    var popped: [UInt8] = []
    while let b = ring.pop() { popped.append(b) }
    t.check("ring keeps capacity-1 bytes in order",
            popped.count == ByteRing.capacity - 1 && popped.first == 0 && popped.last == 126
            && ring.dropped == 200 - (ByteRing.capacity - 1))

    // Mouse packets.
    t.check("mouse packet +dx +dy", parsePackets([0x08, 5, 3]) == [MousePacket(dx: 5, dy: 3, buttons: 0)])
    t.check("mouse packet -dx (sign bit), left button",
            parsePackets([0x19, 0xFB, 0x00]) == [MousePacket(dx: -5, dy: 0, buttons: 1)])
    t.check("mouse packet -dy, right+middle",
            parsePackets([0x2E, 0x00, 0xFE]) == [MousePacket(dx: 0, dy: -2, buttons: 6)])
    t.check("mouse re-sync after bad first byte",
            parsePackets([0x01, 0x08, 1, 2, 0x08, 3, 4]) == [MousePacket(dx: 1, dy: 2, buttons: 0),
                                                            MousePacket(dx: 3, dy: 4, buttons: 0)])
    t.check("mouse overflow packet discarded",
            parsePackets([0x48, 1, 1, 0x08, 7, 0]) == [MousePacket(dx: 7, dy: 0, buttons: 0)])

    var m = MouseState()
    m.width = 100; m.height = 50; m.x = 10; m.y = 10
    m.apply(MousePacket(dx: 5, dy: 3, buttons: 1))
    t.check("mouse apply: y is screen-down", m.x == 15 && m.y == 7 && m.buttons == 1)
    m.apply(MousePacket(dx: -200, dy: -200, buttons: 0))
    t.check("mouse clamps low/high", m.x == 0 && m.y == 49)
    m.apply(MousePacket(dx: 255, dy: 255, buttons: 0))
    t.check("mouse clamps high/low", m.x == 99 && m.y == 0)
}

// MARK: Phase D

/// Opaque to the optimizer, so Float maths happens at run time.
@inline(never)
func opaque<T>(_ value: T) -> T { value }

@inline(never)
func floatArithmetic() -> Bool {
    let a: Float = opaque(1.5), b: Float = opaque(2.0)
    let d: Double = opaque(10.0)
    return a * b == 3.0 && a + b == 3.5 && b / a > 1.333 && b / a < 1.334
        && d / 4 == 2.5 && Int(a * 7) == 10 && Float(opaque(3)) * a == 4.5
        && (d * d).squareRoot() == d && kernelCeil(opaque(2.25)) == 3
        && kernelCeil(opaque(-2.75)) == -2 && kernelCeil(opaque(5.0)) == 5
}

@inline(never)
func dictionaryBasics() -> Bool {
    var d: [String: Int] = [:]
    d["one"] = 1
    d["two"] = 2
    d["a key longer than fifteen bytes"] = 3
    guard d.count == 3, d["one"] == 1, d["two"] == 2, d["a key longer than fifteen bytes"] == 3,
          d["three"] == nil else { return false }
    d["one"] = 11
    guard d.removeValue(forKey: "two") == 2, d["two"] == nil, d.count == 2, d["one"] == 11 else {
        return false
    }
    // Grow through several resizes, then remove everything.
    for i in 0..<1000 { d["k\(i)"] = i }
    guard d.count == 1002, d["k0"] == 0, d["k999"] == 999 else { return false }
    for i in 0..<1000 where d.removeValue(forKey: "k\(i)") != i { return false }
    return d.count == 2 && d["k500"] == nil
}

@inline(never)
func setBasics() -> Bool {
    var s: Set<String> = ["red", "green"]
    let (inserted, _) = s.insert("blue")
    let (again, _) = s.insert("red")
    let primes: Set<Int> = [2, 3, 5, 7, 11]
    let odds = Set((0..<12).filter { $0 % 2 == 1 })
    return inserted && !again && s.count == 3 && s.contains("green") && !s.contains("pink")
        && primes.intersection(odds) == [3, 5, 7, 11] && primes.union(odds).count == 7
}

@inline(never)
func stringEquality() -> Bool {
    let composed = opaque("caf\u{E9}")      // é as one scalar
    let decomposed = opaque("cafe\u{301}")  // e + combining acute
    var d: [String: Int] = [:]
    d[composed] = 1
    // Long (pointer-backed) strings take a different path from small ones.
    let longComposed = opaque("a string longer than fifteen bytes: caf\u{E9}")
    let longDecomposed = opaque("a string longer than fifteen bytes: cafe\u{301}")
    // A, A + ring, angstrom sign: all canonically equivalent.
    let ring = opaque("\u{C5}"), aRing = opaque("A\u{30A}"), angstrom = opaque("\u{212B}")
    return composed == decomposed && !(composed < decomposed) && !(decomposed < composed)
        && longComposed == longDecomposed && ring == aRing && aRing == angstrom
        && opaque("abc") != opaque("abd") && opaque("abc") < opaque("abd")
        && "\(opaque(4))2" == "42" && d[decomposed] == 1 && composed.count == 4
        && decomposed.unicodeScalars.count == 5
}

/// The kernel runs on bootStack's lower-half alias (see enterBootStack).
@inline(never)
func stackInLowerHalf() -> Bool {
    var local = 0
    return withUnsafeMutablePointer(to: &local) { UInt(bitPattern: $0) < 1 << 47 }
}

/// Hold two values in xmm0/xmm15 across `n` timer ticks; true if unchanged.
func xmmSurvivesTicks(_ n: UInt64) -> Bool {
    let a: UInt64 = 0x0123_4567_89AB_CDEF, b: UInt64 = 0xFEDC_BA98_7654_3210
    let out = UnsafeMutablePointer<UInt64>.allocate(capacity: 2)
    defer { out.deallocate() }
    let start = ticks
    sse_hold_across_ticks(a, b, &ticks, n, out)
    return ticks >= start + n && out[0] == a && out[1] == b
}

func sseTests(_ t: inout SelfTest) {
    t.check("SSE enabled (CR0.MP, !EM, CR4.OSFXSR, OSXMMEXCPT)", sseEnabled)
    t.check("Float/Double arithmetic (1.5 * 2.0 == 3.0)", floatArithmetic())

    t.check("kernel stack in lower half", stackInLowerHalf())
    let base = HeapUsage()
    t.check("Dictionary insert/lookup/remove", dictionaryBasics())
    t.check("Set insert/contains/algebra", setBasics())
    t.check("String == (Unicode canonical equivalence)", stringEquality())
    t.check("Dictionary/Set/String freed", HeapUsage() == base)

    // Interrupts must not leak SSE state into the interrupted code.
    let mxcsr = read_mxcsr()
    t.check("xmm preserved across timer ticks", xmmSurvivesTicks(5))
    sseClobberInIRQ = true
    let survived = xmmSurvivesTicks(5)
    let mxcsrAfter = read_mxcsr()
    let floatsAfter = floatArithmetic()
    sseClobberInIRQ = false
    t.check("xmm preserved when the IRQ handler clobbers SSE", survived)
    t.check("MXCSR preserved when the IRQ handler changes it", mxcsrAfter == mxcsr)
    t.check("Float maths correct under SSE-clobbering IRQs", floatsAfter)
}
