// Phase 6D: preemption of ring 3, and timed waits.
//
// Preemption (6D2). Every CPU has a timer: the PIT on CPU 0 (which also
// keeps `ticks`), the LAPIC timer on the APs (apic.swift, vector 0xEF).
// Each tick bumps the CPU's sliceTicks (reset when a task is switched in).
// When a tick interrupts ring 3 and the slice (sliceLength ticks) is used
// up, interrupt_dispatch calls preemptIfSliceUsed: interrupts back on
// (the EOI is already sent), reschedule(.preempt), interrupts off, and the
// stub returns to ring 3 when the task is next switched in, wherever that
// is. The interrupted user state (the stub's frame and fxsave area) stays
// on the task's kernel stack, so the normal context_switch is all it
// takes. Ring 0 is never preempted: kernel code stays cooperative. Only
// ring-3 code holds no kernel lock and no kernel state, so the switch is
// as safe as a yield there (and may allocate).
//
// Timed waits (6D3). `sleepers` is a list of parked tasks sorted by
// deadline (in ticks), behind schedLock. A task adds itself in parkUntil
// and parks; CPU 0's timer IRQ (expireDeadlines) pops every expired entry
// and unparks it, allocation-free: popping never allocates, and enqueue
// has room (ensureRunQueueRoom). After any wakeup the task takes itself
// off the list (a no-op if the IRQ already did). Both paths are under
// schedLock and both just unpark, so an unpark before the deadline and the
// deadline expiring can race on any CPUs: whichever is first wakes the
// task, the other at worst leaves a spurious wakeup (park's callers loop).
//
// API (any task but task 0; deadlines are absolute `ticks`):
//   parkUntil(deadline) -> Bool     park until unpark(task) or the deadline;
//                                   true once the deadline has passed
//   sleepUntil(deadline, interrupted:) -> Bool   loop parkUntil until the
//                                   deadline, or until `interrupted()`
//   sleepMilliseconds(ms, interrupted:) -> Bool
//   deadlineAfter(ms:) -> UInt64    ticks + ms, rounded up to ticks
// Syscalls: sleep(ms) (-EINTR if killed) and now() -> ms since boot.

/// Timer ticks a ring-3 task may run before the timer switches away.
let sliceLength: UInt64 = 2

/// A tick on this CPU (timer IRQ; allocation-free).
@inline(__always)
func sliceTick() {
    thisCPU().pointee.sliceTicks &+= 1
}

/// From interrupt_dispatch, for a timer tick that interrupted ring 3, after
/// its EOI. Switch away if the slice is used up and something else may run
/// here (requeued like a yield; see prepareSwitch). Interrupts are on
/// across the switch, as for every other switch.
@inline(never)
func preemptIfSliceUsed() {
    let e = thisCPU()
    guard e.pointee.sliceTicks >= sliceLength, let p = currentProcess(), !p.killRequested, p.status == nil else {
        return
    }
    e.pointee.sliceTicks = 0 // nothing to switch to: check again next slice
    sti()
    reschedule(.preempt)
    cli()
}

// MARK: The deadline list

/// Items sorted by deadline (ties in insertion order). Pure data, so it is
/// tested on its own; the kernel's one (`sleepers`) is behind schedLock.
/// insert may allocate; remove and popExpired never do (as long as no copy
/// of the list is alive, which `entries` being private ensures).
struct DeadlineList<Item: AnyObject> {
    struct Entry {
        var deadline: UInt64
        var item: Item
    }

    private var entries: [Entry] = []

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }
    /// The earliest deadline, or .max when empty.
    var next: UInt64 { entries.first?.deadline ?? .max }

    func contains(_ item: Item) -> Bool { entries.contains { $0.item === item } }

    mutating func reserve(_ n: Int) { entries.reserveCapacity(n) }

    mutating func insert(_ item: Item, deadline: UInt64) {
        var i = entries.count
        while i > 0 && entries[i - 1].deadline > deadline { i -= 1 }
        entries.insert(Entry(deadline: deadline, item: item), at: i)
    }

    /// Take `item` off the list. False if it wasn't on it.
    @discardableResult
    mutating func remove(_ item: Item) -> Bool {
        guard let i = entries.firstIndex(where: { $0.item === item }) else { return false }
        entries.remove(at: i)
        return true
    }

    /// The first item due at `now` (deadline <= now), removed; nil if none.
    mutating func popExpired(_ now: UInt64) -> Item? {
        guard let first = entries.first, first.deadline <= now else { return nil }
        entries.remove(at: 0)
        return first.item
    }
}

/// Parked tasks with a deadline. Under schedLock.
var sleepers = DeadlineList<Task>()
/// sleepers.next, readable without the lock (the IRQ's fast path).
var nextSleeperDeadline: UInt64 = .max
/// Tasks woken by their deadline (stats, selftests).
var deadlineWakeups: UInt64 = 0

/// Under schedLock.
func publishNextDeadline() {
    withUnsafeMutablePointer(to: &nextSleeperDeadline) { atomic_store64($0, sleepers.next) }
}

/// CPU 0's timer IRQ, after `ticks` advanced: unpark every task whose
/// deadline has come. Allocation-free; interrupts are off, so taking
/// schedLock can't deadlock (it's only ever held with interrupts off).
func expireDeadlines() {
    let now = ticks
    guard now >= withUnsafeMutablePointer(to: &nextSleeperDeadline, { atomic_load64($0) }) else { return }
    schedLock.acquire()
    while let task = sleepers.popExpired(now) {
        deadlineWakeups &+= 1
        unparkLocked(task)
    }
    publishNextDeadline()
    schedLock.release()
}

// MARK: Timed park and sleep

/// The `ticks` value `ms` milliseconds from now, rounded up to whole ticks.
func deadlineAfter(ms: UInt64) -> UInt64 {
    let capped = min(ms, 1 << 40)
    return ticks &+ (capped * timerHz + 999) / 1000
}

/// Park the current task until unpark(it) or `ticks >= deadline`, whichever
/// comes first. Returns true if the deadline has passed. Wakeups can be
/// spurious (as with park), so callers loop on their own condition.
/// `.max` means no deadline (a plain park). Task 0 (and code before the
/// scheduler starts) can't block: it gets an immediate return.
@discardableResult
func parkUntil(_ deadline: UInt64) -> Bool {
    guard let me = scheduler.current, !me.isMain else { return ticks >= deadline }
    if deadline == .max { park(); return false }
    if ticks >= deadline { return true }
    schedLock.withIRQsOff {
        sleepers.insert(me, deadline: deadline)
        publishNextDeadline()
    }
    // An expiry between here and the block sets wakePending: no lost wakeup.
    reschedule(.park)
    schedLock.withIRQsOff {
        if sleepers.remove(me) { publishNextDeadline() }
    }
    return ticks >= deadline
}

/// Sleep until `ticks >= deadline`, ignoring other wakeups, unless
/// `interrupted()` (checked at each wakeup) says stop. True if the deadline
/// was reached. Task 0 busy-waits (it can't block).
@discardableResult
func sleepUntil(_ deadline: UInt64, interrupted: () -> Bool = { false }) -> Bool {
    while ticks < deadline {
        if interrupted() { return false }
        parkUntil(deadline)
    }
    return true
}

@discardableResult
func sleepMilliseconds(_ ms: UInt64, interrupted: () -> Bool = { false }) -> Bool {
    sleepUntil(deadlineAfter(ms: ms), interrupted: interrupted)
}

// MARK: Syscalls

/// sleep(ms): 0, or -EINTR if the process was killed while asleep.
func sysSleep(_ p: Process, _ ms: UInt64) -> Int {
    if ms == 0 { yield(); return 0 }
    return sleepMilliseconds(ms, interrupted: { p.killRequested }) ? 0 : fail(Errno.EINTR)
}

/// now(): milliseconds since boot (the 100 Hz tick, so 10 ms steps).
func sysNow() -> Int {
    Int(ticks * 1000 / timerHz)
}

// MARK: Selftests

final class DeadlineProbe {
    let id: Int
    init(_ id: Int) { self.id = id }
}

/// Shared with helper tasks through raw words (no captures of locals).
var preemptTestWords = InlineArray<8, UInt64>(repeating: 0)

func preemptWord(_ i: Int) -> UnsafeMutablePointer<UInt64> {
    withUnsafeMutablePointer(to: &preemptTestWords) {
        UnsafeMutableRawPointer($0).assumingMemoryBound(to: UInt64.self) + i
    }
}

/// Spawn a program as the caller's child (it waits) on `affinity`.
func spawnForTest(_ argv: [String], affinity: Affinity) -> Process? {
    guard let me = scheduler.current, let name = argv.first else { return nil }
    return try? spawnProcess(path: "/bin/" + name, argv: argv, output: ProcessOutput(reader: me), waiter: me,
                             affinity: affinity)
}

/// Yield until `cond` or `limit` ticks pass. The result of `cond`.
func yieldUntil(_ limit: UInt64, _ cond: () -> Bool) -> Bool {
    let end = ticks + limit
    while !cond() && ticks < end { yield(); cpu_pause() }
    return cond()
}

func deadlineListTests(_ t: inout SelfTest) {
    var list = DeadlineList<DeadlineProbe>()
    let a = DeadlineProbe(1), b = DeadlineProbe(2), c = DeadlineProbe(3), d = DeadlineProbe(4), e = DeadlineProbe(5)
    t.check("6D: empty deadline list: next is .max, nothing expires", list.next == .max && list.popExpired(.max) == nil)
    list.insert(a, deadline: 30)
    list.insert(b, deadline: 10)
    list.insert(c, deadline: 20)
    list.insert(d, deadline: 10)
    list.insert(e, deadline: 40)
    t.check("6D: deadline list sorted on insert", list.count == 5 && list.next == 10)
    let first = list.popExpired(15), second = list.popExpired(15), none = list.popExpired(15)
    t.check("6D: expired in deadline order, ties first-in first", first === b && second === d && none == nil)
    t.check("6D: remove takes an entry out once", list.remove(c) && !list.remove(c) && !list.contains(c)
            && list.next == 30)
    let x = list.popExpired(100), y = list.popExpired(100)
    t.check("6D: the rest expire in order, list empty", x === a && y === e && list.isEmpty && list.next == .max)
    t.check("6D: removing from an empty list", !list.remove(a))
}

func timedParkTests(_ t: inout SelfTest) {
    guard let me = scheduler.current, !me.isMain else { return }
    // A timed park that runs out.
    var t0 = ticks
    var expired = false // (a wakeup left over from an earlier test may end the first park early)
    while !expired && ticks < t0 + 20 { expired = parkUntil(t0 + 5) }
    let waited = ticks - t0
    t.check("6D: parkUntil(+5) times out after 5 ticks", expired && waited >= 5 && waited <= 7)
    t.check("6D: the deadline list is empty again", schedLock.withIRQsOff { sleepers.isEmpty }
            && nextSleeperDeadline == .max)
    t0 = ticks
    t.check("6D: sleepMilliseconds(50) takes 5 ticks", sleepMilliseconds(50) && ticks - t0 >= 5 && ticks - t0 <= 7)
    t.check("6D: a past deadline returns at once", parkUntil(ticks) && parkUntil(0))

    // Unparked long before its deadline, on another CPU when there is one.
    let cpu = smpStarted > 1 ? 1 : 0
    for i in 0..<8 { preemptWord(i).pointee = 0 }
    let done = preemptWord(0), result = preemptWord(1), elapsed = preemptWord(2)
    let helper = spawn("timedpark", affinity: .cpu(cpu)) {
        let start = ticks
        let timedOut = parkUntil(start + 1000)
        atomic_store64(preemptWord(1), timedOut ? 1 : 2)
        atomic_store64(preemptWord(2), ticks - start)
        atomic_store64(preemptWord(0), 1)
    }
    // Wait until it's parked (blocked, on the list), then unpark it.
    let parked = yieldUntil(100) {
        guard let helper else { return false }
        return schedLock.withIRQsOff { helper.state == .blocked && sleepers.contains(helper) }
    }
    if let helper { unpark(helper) }
    let woke = yieldUntil(100) { atomic_load64(done) == 1 }
    t.check("6D: unpark before the deadline wakes a timed park (from another CPU)", parked && woke
            && atomic_load64(result) == 2 && atomic_load64(elapsed) < 50)
    _ = yieldUntil(50) { schedLock.withIRQsOff { sleepers.isEmpty } }
    t.check("6D: an early wakeup leaves the list", schedLock.withIRQsOff { sleepers.isEmpty })

    // Deadline expiry wakes tasks on every CPU (CPU 0's IRQ unparks them).
    let n = max(smpStarted, 1)
    preemptWord(3).pointee = 0
    preemptWord(4).pointee = 0
    let base = ticks + 3
    let woken0 = deadlineWakeups
    for k in 0..<n {
        spawn("sleeper\(k)", affinity: .cpu(k)) {
            let deadline = base + UInt64(k)
            sleepUntil(deadline)
            if ticks >= deadline && ticks <= deadline + 3 { _ = atomic_fetch_add64(preemptWord(4), 1) }
            _ = atomic_fetch_add64(preemptWord(3), 1)
        }
    }
    let allWoke = yieldUntil(200) { atomic_load64(preemptWord(3)) == UInt64(n) }
    t.check("6D: a sleeper per CPU wakes on time", allWoke && atomic_load64(preemptWord(4)) == UInt64(n)
            && deadlineWakeups >= woken0 + UInt64(n))

    // Race: unparks landing on and around deadlines, from this CPU, while
    // the helper parks with 1-tick deadlines over and over.
    preemptWord(5).pointee = 0
    let racer = spawn("parkrace", affinity: .cpu(cpu)) {
        for _ in 0..<300 { parkUntil(ticks + 1) }
        atomic_store64(preemptWord(5), 1)
    }
    var unparks = 0
    let raced = yieldUntil(1000) {
        if let racer, unparks < 100_000 { unpark(racer); unparks += 1 }
        return atomic_load64(preemptWord(5)) == 1
    }
    _ = yieldUntil(50) { schedLock.withIRQsOff { sleepers.isEmpty } }
    t.check("6D: unpark/deadline races: no hang, list empty", raced && schedLock.withIRQsOff { sleepers.isEmpty })
}

func preemptionTests(_ t: inout SelfTest) {
    guard scheduler.current != nil else { return }
    let n = max(smpStarted, 1)
    // 6D1: every AP's LAPIC timer runs at about the PIT's rate.
    if n > 1 {
        var before: [UInt64] = []
        for i in 1..<n { before.append(perCPUEntry(i).pointee.lapicTicks) }
        let t0 = ticks
        while ticks < t0 + 20 { yield(); cpu_pause() }
        var ok = true
        for i in 1..<n {
            let d = perCPUEntry(i).pointee.lapicTicks &- before[i - 1]
            if d < 15 || d > 25 { ok = false; print("  cpu \(i): \(d) LAPIC ticks in 20 PIT ticks") }
        }
        t.check("6D: every AP's LAPIC timer ticks at ~100 Hz", ok)
    }

    // A spin pinned to CPU 0 (where this test runs): the test task still
    // gets the CPU back, so the spin is preempted; kill then works.
    let pre0 = perCPUEntry(0).pointee.preemptions
    guard let spin0 = spawnForTest(["spin"], affinity: .cpu(0)) else {
        t.check("6D: spawn spin on cpu 0", false)
        return
    }
    let started = yieldUntil(100) { spin0.thread.map { $0.runs > 0 } ?? false }
    var t0 = ticks
    sleepUntil(t0 + 10)
    let late = ticks - (t0 + 10)
    if late > 3 { print("  sleeper woke \(late) ticks late") }
    t.check("6D: a sleeper on cpu 0 wakes on time beside a spin there", started && late <= 3)
    t.check("6D: the spin on cpu 0 was preempted", perCPUEntry(0).pointee.preemptions > pre0
            && spin0.state == .running)

    // A preempted alloc still computes the right checksum.
    if let alloc = spawnForTest(["alloc"], affinity: .cpu(0)) {
        var bytes: [UInt8] = []
        let status = waitProcess(alloc, sink: { bytes += $0 })
        let out = String(decoding: bytes, as: UTF8.self)
        t.check("6D: alloc preempted beside a spin: checksum 67415360436",
                status == .exited(0) && has(out, "alloc: checksum 67415360436"))
    } else {
        t.check("6D: spawn alloc", false)
    }
    t0 = ticks
    killProcess(spin0.pid)
    let status = waitProcess(spin0)
    t.check("6D: kill stops a spin on cpu 0", status == .killed && ticks - t0 < 20)

    // One spin per CPU: every CPU (APs through their LAPIC timer) preempts,
    // and a task pinned to each CPU still runs there.
    var spins: [Process] = []
    for k in 0..<n { if let p = spawnForTest(["spin"], affinity: .cpu(k)) { spins.append(p) } }
    let preBefore = (0..<n).map { perCPUEntry($0).pointee.preemptions }
    _ = yieldUntil(100) { spins.allSatisfy { $0.thread.map { $0.runs > 0 } ?? false } }
    preemptWord(6).pointee = 0
    for k in 0..<n {
        spawn("beside\(k)", affinity: .cpu(k)) { _ = atomic_fetch_add64(preemptWord(6), 1) }
    }
    let ran = yieldUntil(100) { atomic_load64(preemptWord(6)) == UInt64(n) }
    t0 = ticks
    while ticks < t0 + 10 { yield(); cpu_pause() }
    var everyCPU = true
    for k in 0..<n where perCPUEntry(k).pointee.preemptions <= preBefore[k] { everyCPU = false }
    t.check("6D: a spin per CPU: a task pinned to each CPU still runs", spins.count == n && ran)
    t.check("6D: every CPU preempted its spin", everyCPU)
    for p in spins { killProcess(p.pid) }
    var killed = true
    for p in spins where waitProcess(p) != .killed { killed = false }
    t.check("6D: every spin killed", killed)

    // sleep(500) from ring 3 takes 500 ms, give or take a tick.
    if let p = spawnForTest(["sleep", "-v", "500"], affinity: .any) {
        let t1 = ticks
        var bytes: [UInt8] = []
        let st = waitProcess(p, sink: { bytes += $0 })
        let out = String(decoding: bytes, as: UTF8.self)
        let spent = ticks - t1
        let ok = st == .exited(0) && (has(out, "slept 490 ms") || has(out, "slept 500 ms") || has(out, "slept 510 ms"))
        t.check("6D: /bin/sleep 500 sleeps 500 ms +- a tick", ok && spent >= 49 && spent <= 53)
        if !ok || spent < 49 || spent > 53 { print("  sleep said: \(out) (\(spent) ticks)") }
    } else {
        t.check("6D: spawn sleep", false)
    }
    // kill wakes a sleeping process (-EINTR) at once.
    if let p = spawnForTest(["sleep", "100000"], affinity: .any) {
        _ = yieldUntil(100) { p.thread.map { th in schedLock.withIRQsOff { th.state == .blocked } } ?? false }
        let t1 = ticks
        killProcess(p.pid)
        let st = waitProcess(p)
        t.check("6D: kill wakes a sleeping process", st == .killed && ticks - t1 < 20)
    }
}

func preemptTests(_ t: inout SelfTest) {
    deadlineListTests(&t)
    timedParkTests(&t)
    preemptionTests(&t)
}
