// Phase 8A (randomness) and 7F (wall-clock time for user space): the
// kernel's random number generator behind `getrandom`, and `time`.
//
// The generator is lib/crypto's ChaChaDRBG (fast key erasure; build.sh
// compiles chacha.swift, sha2.swift, common.swift, tables.swift and
// drbg.swift into the kernel), behind `rngLock`. Seeding (randomInit, at
// boot): 32 RDSEED words when the CPU has RDSEED, else 32 RDRAND words, plus
// 64 RDTSC readings taken around port I/O (jitter), the RTC time and the
// boot tick count. Interrupt timing is extra input: the keyboard, mouse and
// NIC interrupt handlers call `entropyAddInterrupt`, which only xors the TSC
// into a fixed pool (no allocation, no lock: a torn update just mixes
// differently); `getrandom` folds that pool (with fresh RDRAND/RDSEED words)
// into the DRBG every `reseedInterval` requests and whenever enough
// interrupts arrived since the last reseed.
//
// Without RDRAND/RDSEED (not on QEMU's -cpu max) the seed is TSC jitter and
// interrupt timing only, which is weak; `randomSource` says which was used
// (shown by `random` in the shell selftest output).

var rngLock = SpinLock()
var kernelRNG = ChaChaDRBG(seed: [])
var rngSeeded = false
/// "rdseed", "rdrand" or "jitter" (no hardware source).
var randomSource = "none"
var randomRequests: UInt64 = 0
var randomReseeds: UInt64 = 0
let reseedInterval: UInt64 = 256

/// Interrupt timing pool: written by IRQ handlers (lock-free, no allocation).
var entropyPool = InlineArray<8, UInt64>(repeating: 0)
var entropyEvents: UInt64 = 0
var entropyEventsAtReseed: UInt64 = 0

/// From an interrupt handler: mix the TSC into the pool.
@inline(__always)
func entropyAddInterrupt(_ tag: UInt64) {
    let n = entropyEvents
    entropyEvents = n &+ 1
    let i = Int(n & 7)
    let t = rdtsc() ^ (tag << 56)
    entropyPool[i] = (entropyPool[i] << 7 | entropyPool[i] >> 57) ^ t
}

var hasRDRAND: Bool { cpuid(1, 0).ecx & (1 << 30) != 0 }
var hasRDSEED: Bool { cpuid(7, 0).ebx & (1 << 18) != 0 }

func appendLE(_ out: inout [UInt8], _ v: UInt64) {
    for i in 0..<8 { out.append(UInt8(truncatingIfNeeded: v >> UInt64(8 * i))) }
}

/// Hardware words (RDSEED, else RDRAND), `count` of them; empty if neither.
func hardwareEntropy(_ count: Int) -> [UInt8] {
    var out: [UInt8] = []
    let seed = hasRDSEED, rand = hasRDRAND
    for _ in 0..<count {
        var v: UInt64 = 0
        if seed && rdseed64(&v) != 0 {
            appendLE(&out, v)
        } else if rand && rdrand64(&v) != 0 {
            appendLE(&out, v)
        }
    }
    return out
}

/// Boot (CPU 0, after the RTC and the PIT are up).
func randomInit() {
    var seed: [UInt8] = []
    seed += hardwareEntropy(32)
    randomSource = hasRDSEED ? "rdseed" : hasRDRAND ? "rdrand" : "jitter"
    // TSC jitter: how long a few slow port reads take varies a little.
    var last = rdtsc()
    for _ in 0..<64 {
        _ = inb(0x80)
        _ = inb(0x61)
        let t = rdtsc()
        appendLE(&seed, t &- last)
        last = t
    }
    appendLE(&seed, UInt64(bitPattern: bootUnixSeconds()))
    appendLE(&seed, ticks)
    let flags = rngLock.acquireIRQ()
    kernelRNG = ChaChaDRBG(seed: seed)
    rngSeeded = true
    rngLock.releaseIRQ(flags)
    for i in 0..<seed.count { seed[i] = 0 }
}

/// Fill `buffer` with DRBG output. Any CPU; not from interrupt handlers.
func randomFill(_ buffer: UnsafeMutableRawBufferPointer) {
    if !rngSeeded { randomInit() }
    randomRequests &+= 1
    if randomRequests % reseedInterval == 0 || entropyEvents &- entropyEventsAtReseed >= 64 {
        var more = hardwareEntropy(4)
        for i in 0..<8 { appendLE(&more, entropyPool[i]) }
        appendLE(&more, rdtsc())
        let flags = rngLock.acquireIRQ()
        kernelRNG.reseed(more)
        entropyEventsAtReseed = entropyEvents
        randomReseeds &+= 1
        rngLock.releaseIRQ(flags)
    }
    // At most 4 KiB per lock hold (interrupts are off meanwhile).
    var off = 0
    while off < buffer.count {
        let n = min(4096, buffer.count - off)
        let flags = rngLock.acquireIRQ()
        kernelRNG.fill(UnsafeMutableRawBufferPointer(rebasing: buffer[off..<off + n]))
        rngLock.releaseIRQ(flags)
        off += n
    }
}

func randomBytes(_ n: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: max(n, 0))
    out.withUnsafeMutableBytes { randomFill($0) }
    return out
}

/// getrandom(buf, len, flags) -> len.
func sysGetrandom(_ p: Process, _ buf: UInt64, _ len: UInt64, _ flags: UInt64) -> Int {
    guard flags == 0 else { return fail(Errno.EINVAL) }
    guard len <= 65536 else { return fail(Errno.EINVAL) }
    let n = Int(len)
    guard n > 0 else { return 0 }
    guard userRangeReady(p, UInt(buf), n, write: true) else { return fail(Errno.EFAULT) }
    let bytes = randomBytes(n)
    return copyOut(buf, bytes) ? n : fail(Errno.EFAULT)
}

// MARK: Wall-clock time

/// Days since 1970-01-01 of a proleptic Gregorian date (Howard Hinnant's
/// days_from_civil).
func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
    let y = month <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let mp = (month + 9) % 12
    let doy = (153 * mp + 2) / 5 + day - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146097 + doe - 719468
}

func unixSeconds(_ t: RTCTime) -> Int64 {
    Int64(daysFromCivil(t.year, t.month, t.day)) * 86400 + Int64(t.hour * 3600 + t.minute * 60 + t.second)
}

/// Unix seconds at tick `bootTimeTicks` (read once, on CPU 0).
var bootTime: Int64 = 0
var bootTimeTicks: UInt64 = 0
var bootTimeRead = false

func bootUnixSeconds() -> Int64 {
    if !bootTimeRead {
        bootTime = unixSeconds(rtcNow())
        bootTimeTicks = ticks
        bootTimeRead = true
    }
    return bootTime
}

/// Now, in Unix seconds (the RTC at boot plus the uptime).
func unixTimeNow() -> Int64 {
    let base = bootTimeRead ? bootTime : onCPU0 { bootUnixSeconds() }
    return base + Int64((ticks &- bootTimeTicks) / timerHz)
}

func sysTime() -> Int { Int(unixTimeNow()) }

// MARK: Selftest

func randomTests(_ t: inout SelfTest) {
    t.check("random: Unix time of 2026-11-18 12:34:56", unixSeconds((2026, 11, 18, 12, 34, 56)) == 1_795_005_296)
    t.check("random: Unix time of the epoch and a leap day",
            unixSeconds((1970, 1, 1, 0, 0, 0)) == 0 && unixSeconds((2024, 2, 29, 0, 0, 0)) == 1_709_164_800)
    let now = unixTimeNow()
    t.check("random: time() is after 2025 and before 2100", now > 1_735_689_600 && now < 4_102_444_800)
    let a = randomBytes(32), b = randomBytes(32)
    t.check("random: two outputs differ and aren't all zero", a != b && a.contains(where: { $0 != 0 }))
    let big = randomBytes(10000)
    var counts = [Int](repeating: 0, count: 256)
    for x in big { counts[Int(x)] += 1 }
    t.check("random: 10000 bytes use every byte value, none over 100 times",
            counts.allSatisfy { $0 > 0 && $0 < 100 })
    t.check("random: seeded (RDSEED, RDRAND or jitter)", rngSeeded && randomSource != "none")
    // The DRBG itself (lib/crypto has the vectors): same seed, same output;
    // the state moves on after each request.
    var d1 = ChaChaDRBG(seed: [1, 2, 3]), d2 = ChaChaDRBG(seed: [1, 2, 3])
    let x = d1.generate(40)
    t.check("random: ChaChaDRBG is deterministic per seed and never repeats", x == d2.generate(40) && d1.generate(40) != x)
}
