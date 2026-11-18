// Phase H selftests: modifier keys (H2), the event queue (H1), and tasks
// (H3): a 10,000-message ping-pong between two tasks that checks the
// callee-saved registers, MXCSR and the x87 control word across every wait,
// then that the heap and frame allocator are back where they started. Also
// the stack canary and the watchdog. Called from runSelfTests, which the
// shell's `selftest` command runs in the shell's own task.

func decodeKeys(_ codes: [UInt8]) -> [Key] {
    var d = ScancodeDecoder()
    var keys: [Key] = []
    for c in codes { if let k = d.feedKey(c) { keys.append(k) } }
    return keys
}

func keyTests(_ t: inout SelfTest) {
    let a = KeyEvent.char(0x61)
    t.check("key: alt+a", decodeKeys([0x38, 0x1E]) == [Key(a, alt: true)])
    t.check("key: alt released", decodeKeys([0x38, 0xB8, 0x1E]) == [Key(a)])
    var d = ScancodeDecoder()
    let altGr = [0xE0, 0x38, 0x1E].compactMap { d.feedKey($0) }
    t.check("key: AltGr (E0 38) is alt", altGr == [Key(a, alt: true)] && d.altGr && !d.leftAlt)
    t.check("key: F1-F10, F11, F12",
            decodeKeys([0x3B, 0xBB, 0x3C, 0x44, 0x57, 0x58, 0xD8]).map { $0.code }
            == [.function(1), .function(2), .function(10), .function(11), .function(12)])
    t.check("key: alt+F4", decodeKeys([0x38, 0x3E]).first?.isAlt(.function(4)) == true)
    t.check("key: alt+tab", decodeKeys([0x38, 0x0F]).first?.isAlt(.char(0x09)) == true)
    t.check("key: super press once, meta on held keys, off after release",
            decodeKeys([0xE0, 0x5B, 0xE0, 0x5B, 0x1C, 0xE0, 0xDB, 0x1C])
            == [Key(.superKey, meta: true), Key(.char(0x0D), meta: true), Key(.char(0x0D))])
    t.check("key: right super (E0 5C)", decodeKeys([0xE0, 0x5C, 0x1E]) == [Key(.superKey, meta: true), Key(a, meta: true)])
    let ctrlS = decodeKeys([0x1D, 0x1F])
    t.check("key: ctrl+s keeps 0x13, isCtrl(\"s\")",
            ctrlS == [Key(.char(0x13), ctrl: true)] && ctrlS[0].isCtrl("s") && ctrlS[0].isCtrl("S")
            && !ctrlS[0].isCtrl("a") && !Key(.char(0x13)).isCtrl("s"))
    t.check("key: shift flag", decodeKeys([0x2A, 0x1E]) == [Key(.char(0x41), shift: true)])
    t.check("key: ctrl+home", decodeKeys([0x1D, 0xE0, 0x47]) == [Key(.home, ctrl: true)])
    t.check("key: plain feed() still yields KeyEvents", decode([0x38, 0x1E, 0x3B]) == [a, .function(1)])
}

func eventQueueTests(_ t: inout SelfTest) {
    var q = EventQueue()
    q.post(.tick(1))
    q.postMouse(x: 1, y: 2, buttons: 0)
    q.postMouse(x: 3, y: 4, buttons: 0) // coalesced
    q.postMouse(x: 3, y: 4, buttons: 1) // button change: kept separate
    q.post(.key(Key(.up)))
    t.check("event queue: count with mouse coalescing", q.count == 4)
    t.check("event queue: FIFO",
            q.next() == .tick(1) && q.next() == .mouse(x: 3, y: 4, buttons: 0)
            && q.next() == .mouse(x: 3, y: 4, buttons: 1) && q.next() == .key(Key(.up)) && q.next() == nil)
    t.check("event queue: drained reuses its storage", q.isEmpty && q.head == 0 && q.events.capacity >= 4)
    q.post(.key(Key(.down)))
    q.postMouse(x: 5, y: 5, buttons: 0) // previous tail isn't a mouse event
    t.check("event queue: no coalescing across a key", q.count == 2)
}

// MARK: Ping-pong

/// One ping-pong task's own counters (never written by the other task,
/// which may be running at the same time on another CPU).
final class WaitStats {
    var errors = 0
    /// OR of check_callee_saved results: which registers didn't survive.
    var clobbered: UInt32 = 0
    /// Waits that returned on a different CPU from the one they started on.
    var migrations = 0
    /// Bit i: ran on CPU i.
    var cpus: UInt64 = 0
}

/// Shared by the two ping-pong tasks (and the test that waits for them).
final class PingPong {
    var ping: Task? = nil
    var pong: Task? = nil
    var rounds = 0
    let pingStats = WaitStats()
    let pongStats = WaitStats()
    var pingSum: Double = 0
    var pongSum: Double = 0
}

/// What the last pingPongWait received, per CPU: stored right after
/// waitEvent returns and read right after check_callee_saved returns, with
/// no switch in between, so the slot of the CPU we're on is ours.
let pingPongLast: UnsafeMutablePointer<Event?> = {
    let p = UnsafeMutablePointer<Event?>.allocate(capacity: maxCPUs)
    p.initialize(repeating: nil, count: maxCPUs)
    return p
}()

/// Called through check_callee_saved, which holds known values in every
/// callee-saved register (and MXCSR/FCW) across this wait, i.e. across a
/// task switch (and, for `.any` tasks, maybe a move to another CPU).
func pingPongWait() {
    let e = waitEvent()
    pingPongLast[currentCPU()] = e
}

@inline(never)
func checkedWait(_ seed: UInt64, mxcsr: UInt32, fcw: UInt32, _ stats: WaitStats) -> Event? {
    let before = currentCPU()
    stats.cpus |= 1 << UInt64(before)
    stats.clobbered |= check_callee_saved(pingPongWait, seed, mxcsr, fcw)
    let after = currentCPU()
    stats.cpus |= 1 << UInt64(after)
    if after != before { stats.migrations += 1 }
    defer { pingPongLast[after] = nil }
    return pingPongLast[after]
}

// Different control values in each task, so a switch that didn't save them
// would leak one task's into the other: round up / round down, and 53-bit /
// 24-bit x87 precision.
let pingMXCSR: UInt32 = 0x5F80, pingFCW: UInt32 = 0x027F
let pongMXCSR: UInt32 = 0x3F80, pongFCW: UInt32 = 0x007F

/// Result of one run, checked by the caller after every object is freed.
struct PingPongResult {
    var finished = false
    var rounds = 0
    var errors = 0
    var clobbered: UInt32 = 0
    var sumsOK = false
    var switches = 0
    var stacksLow = false
    var bothRan = false
    var pingCPUs: UInt64 = 0
    var pongCPUs: UInt64 = 0
    var migrations = 0
}

@inline(never)
func runPingPong(_ n: Int, affinity: Affinity = .cpu(0)) -> PingPongResult {
    var r = PingPongResult()
    let box = PingPong()
    let switchesBefore = scheduler.switches
    // Both tasks exist before either sends: ping waits for a go message.
    box.ping = spawn("ping", affinity: affinity) {
        _ = waitEvent()
        for i in 0..<n {
            box.pong?.post(.message(2 * i))
            let reply = checkedWait(UInt64(i) << 8, mxcsr: pingMXCSR, fcw: pingFCW, box.pingStats)
            if reply != .message(2 * i + 1) { box.pingStats.errors += 1 }
            box.pingSum += Double(opaque(i)) * 0.5
        }
        box.pong?.post(.close)
    }
    box.pong = spawn("pong", affinity: affinity) {
        var k: UInt64 = 0x1_0000_0000
        while true {
            k += 1
            switch checkedWait(k << 8, mxcsr: pongMXCSR, fcw: pongFCW, box.pongStats) {
            case .message(let v)?:
                box.rounds += 1
                box.pongSum += Double(opaque(v)) / 2
                box.ping?.post(.message(v + 1))
            case .close?: return
            default: box.pongStats.errors += 1
            }
        }
    }
    guard let ping = box.ping, let pong = box.pong else { return r }
    ping.post(.message(-1))
    r.stacksLow = ping.stackTop < 1 << 47 && pong.stackTop < 1 << 47 && ping.stackBottom & 0xFFF == 0
    let deadline = ticks + 60 * timerHz
    while (ping.state != .finished || pong.state != .finished) && ticks < deadline { yield() }
    r.finished = ping.state == .finished && pong.state == .finished
    r.bothRan = ping.runs > 0 && pong.runs > 0
    r.rounds = box.rounds
    r.errors = box.pingStats.errors + box.pongStats.errors
    r.clobbered = box.pingStats.clobbered | box.pongStats.clobbered
    r.pingCPUs = box.pingStats.cpus
    r.pongCPUs = box.pongStats.cpus
    r.migrations = box.pingStats.migrations + box.pongStats.migrations
    // sum(i/2) over 0..<n, both ways (pong sees 2i, halves it to i, so its
    // sum is 2 * pingSum's).
    let want = Double(n - 1) * Double(n) / 4
    r.sumsOK = box.pingSum == want && box.pongSum == 2 * want
    r.switches = scheduler.switches - switchesBefore
    box.ping = nil
    box.pong = nil
    return r
}

/// A task that only returns: it is freed, with its stack.
@inline(never)
func shortLivedTasks() -> Bool {
    var ran = 0
    for _ in 0..<20 { spawn("short") { ran += 1 } }
    let deadline = ticks + 10 * timerHz
    while ran < 20 && ticks < deadline { yield() }
    yield() // let the last one's successor free it
    return ran == 20 && scheduler.zombies.isEmpty
}

@inline(never)
func canaryDetects() -> Bool {
    guard let frame = pmm.allocate() else { return false }
    let victim = Task(id: -1, name: "victim", stackBottom: frame, stackFrames: 1, body: {})
    let fresh = victim.canaryIntact
    victim.canaryWords[1] = 0
    let caught = !victim.canaryIntact
    victim.writeCanary()
    return fresh && caught && victim.canaryIntact && victim.state == .ready
}

func taskTests(_ t: inout SelfTest) {
    keyTests(&t)
    eventQueueTests(&t)

    yield() // flush any watchdog report from the tests before
    let inTask = scheduler.current.map { !$0.isMain && $0.name == "shell" } ?? false
    t.check("tasks: selftest runs in the shell task", inTask)
    t.check("tasks: main task's canary intact", scheduler.main?.canaryIntact == true)
    t.check("tasks: current task's canary intact", scheduler.current?.canaryIntact == true)

    _ = pingPongLast // allocated once, before the baseline
    let base = HeapUsage(), frames = pmm.freeFrames
    let r = runPingPong(10_000)
    t.check("tasks: ping-pong 10,000 messages finished", r.finished && r.rounds == 10_000 && r.bothRan)
    t.check("tasks: every reply was the right message", r.errors == 0)
    t.check("tasks: rbx rbp r12-r15 survive every switch", r.clobbered & 0x3F == 0)
    t.check("tasks: MXCSR and x87 control word are per task", r.clobbered & 0xC0 == 0)
    t.check("tasks: Double maths in both tasks", r.sumsOK)
    t.check("tasks: stacks identity-mapped, page aligned", r.stacksLow)
    t.check("tasks: at least 20,000 switches", r.switches >= 20_000)
    t.check("tasks: heap back to baseline", HeapUsage() == base)
    t.check("tasks: stacks returned to the frame allocator", pmm.freeFrames == frames)
    print("  tasks: \(r.switches) switches for 10,000 round trips")

    t.check("tasks: 20 short-lived tasks run and are freed", shortLivedTasks())
    t.check("tasks: short-lived tasks freed", HeapUsage() == base && pmm.freeFrames == frames)
    t.check("tasks: canary corruption detected", canaryDetects())

    // Watchdog, with a 30 ms limit: spin (in hlt, but without yielding).
    let limit = watchdogLimit, trips = watchdogTrips
    watchdogLimit = 3
    watchdogPet()
    let start = ticks
    while ticks < start + 6 { hlt() }
    let tripped = watchdogTripped
    let canReport = scheduler.hasReady
    yield() // the switch reports it
    watchdogLimit = limit
    watchdogAlertUntil = 0
    t.check("tasks: watchdog trips on a task that doesn't yield", tripped)
    t.check("tasks: watchdog reported at the next switch", !canReport || (watchdogTrips == trips + 1 && !watchdogTripped))
}
