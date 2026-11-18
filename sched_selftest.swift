// Phase S selftests: the SMP scheduler. Four `.any` tasks hammer a spinlocked
// counter and the heap; two `.any` tasks ping-pong 10,000 messages with
// check_callee_saved across every wait (and so across migrations); a
// `.cpu(2)` task never leaves CPU 2; `cpus` shows the running task. With one
// CPU, all of it runs on CPU 0 (and the CPU-2 test is skipped).
// Run from the shell's task (on CPU 0), which waits by yielding, so CPU 0
// takes part too.

var hammerLock = SpinLock()
/// Under hammerLock.
var hammerCount = 0
/// Atomic: tasks done, and the CPUs they were seen on.
var hammerDone: UInt64 = 0
var hammerCPUs: UInt64 = 0
var hammerBad: UInt64 = 0

let hammerTasks = 4
let hammerIterations = 100_000

func atomicLoad(_ p: UnsafeMutablePointer<UInt64>) -> UInt64 { atomic_load64(p) }

/// Note the calling CPU in an atomic bitmask.
func markCPU(_ mask: inout UInt64) {
    let bit: UInt64 = 1 << UInt64(currentCPU())
    _ = withUnsafeMutablePointer(to: &mask) { atomic_fetch_or64($0, bit) }
}

@inline(never)
func hammerBody() {
    var bad: UInt64 = 0
    for i in 0..<hammerIterations {
        hammerLock.acquire()
        hammerCount += 1
        hammerLock.release()
        // Allocate and free an array of 1-8 words, and check its contents.
        let a = [Int](repeating: opaque(i), count: 1 + i & 7)
        if a.count != 1 + i & 7 || a[a.count - 1] != i { bad += 1 }
        if i % 1000 == 0 {
            markCPU(&hammerCPUs)
            yield() // a chance to move (or let CPU 0's tasks run)
        }
    }
    markCPU(&hammerCPUs)
    _ = withUnsafeMutablePointer(to: &hammerBad) { atomic_fetch_add64($0, bad) }
    _ = withUnsafeMutablePointer(to: &hammerDone) { atomic_fetch_add64($0, 1) }
}

/// Yield until `n` more Task objects have been freed than `before` (tasks
/// that finished on an AP are freed there, a moment after they finish).
func waitTasksFreed(since before: UInt64, _ n: Int, seconds: UInt64 = 10) -> Bool {
    let deadline = ticks + seconds * timerHz
    while withUnsafeMutablePointer(to: &tasksFreed, { atomicLoad($0) }) < before + UInt64(n) && ticks < deadline {
        yield()
    }
    yield() // this CPU's own zombies
    return withUnsafeMutablePointer(to: &tasksFreed, { atomicLoad($0) }) >= before + UInt64(n)
}

func popCount(_ x: UInt64) -> Int { x.nonzeroBitCount }

@inline(never)
func hammerTest(_ t: inout SelfTest) {
    let cpus = onlineCPUCount()
    hammerCount = 0
    hammerDone = 0
    hammerCPUs = 0
    hammerBad = 0
    let base = HeapUsage(), frames = pmm.freeFrames
    let freed = withUnsafeMutablePointer(to: &tasksFreed) { atomicLoad($0) }
    let start = ticks
    var spawned = 0
    for _ in 0..<hammerTasks where spawn("hammer", affinity: .any, { hammerBody() }) != nil { spawned += 1 }
    let deadline = ticks + 60 * timerHz
    while withUnsafeMutablePointer(to: &hammerDone, { atomicLoad($0) }) < UInt64(spawned) && ticks < deadline {
        yield()
    }
    let elapsed = ticks - start
    let allFreed = waitTasksFreed(since: freed, spawned)
    let count = hammerLock.withIRQsOff { hammerCount }
    t.check("sched: 4 .any tasks x 100k locked increments, exact count",
            spawned == hammerTasks && count == hammerTasks * hammerIterations)
    t.check("sched: hammer arrays intact", hammerBad == 0)
    t.check("sched: hammer tasks freed", allFreed)
    t.check("sched: heap live count back to baseline", HeapUsage() == base)
    t.check("sched: hammer stacks returned", pmm.freeFrames == frames)
    if cpus == 1 {
        t.check("sched: one CPU: all .any work ran on CPU 0", hammerCPUs == 1)
    } else {
        t.check("sched: hammer tasks ran on more than one CPU", popCount(hammerCPUs) >= 2)
    }
    print("  sched: hammer \(elapsed * 1000 / timerHz) ms on CPUs mask \(hammerCPUs), lock contended \(hammerLock.contended)x")
}

@inline(never)
func anyPingPongTest(_ t: inout SelfTest) {
    let cpus = onlineCPUCount()
    let base = HeapUsage(), frames = pmm.freeFrames
    let freed = withUnsafeMutablePointer(to: &tasksFreed) { atomicLoad($0) }
    let r = runPingPong(10_000, affinity: .any)
    let allFreed = waitTasksFreed(since: freed, 2)
    t.check("sched: .any ping-pong 10,000 messages finished", r.finished && r.rounds == 10_000 && r.bothRan)
    t.check("sched: .any ping-pong replies all right", r.errors == 0 && r.sumsOK)
    t.check("sched: callee-saved, MXCSR, FCW survive (with migrations)", r.clobbered == 0)
    t.check("sched: .any ping-pong freed, heap back to baseline", allFreed && HeapUsage() == base && pmm.freeFrames == frames)
    if cpus >= 3 {
        t.check("sched: ping and pong seen on different CPUs", popCount(r.pingCPUs | r.pongCPUs) >= 2)
        t.check("sched: tasks migrated between CPUs mid-wait", r.migrations > 0)
    } else {
        puts("  note fewer than 3 CPUs: 'seen on different CPUs' and migration checks skipped\n")
        if cpus == 1 { t.check("sched: one CPU: ping-pong ran on CPU 0", r.pingCPUs | r.pongCPUs == 1) }
    }
    print("  sched: .any ping-pong CPUs ping \(r.pingCPUs) pong \(r.pongCPUs), \(r.migrations) migrations")
}

/// CPU mask the pinned task was seen on (atomic).
var pinnedCPUs: UInt64 = 0
var pinnedDone: UInt64 = 0

@inline(never)
func pinnedTest(_ t: inout SelfTest) {
    guard onlineCPUCount() >= 3 else {
        puts("  note fewer than 3 CPUs: .cpu(2) pinning test skipped\n")
        t.check("sched: .cpu(n) for a CPU that isn't online is refused", spawn("nope", affinity: .cpu(2), {}) == nil)
        return
    }
    pinnedCPUs = 0
    pinnedDone = 0
    let rounds = 200
    let task = spawn("pinned", affinity: .cpu(2)) {
        for _ in 0..<rounds {
            markCPU(&pinnedCPUs)
            yield()
            markCPU(&pinnedCPUs)
            _ = waitEvent() // blocks: CPU 2 goes idle, a post wakes it there
            markCPU(&pinnedCPUs)
        }
        _ = withUnsafeMutablePointer(to: &pinnedDone) { atomic_fetch_add64($0, 1) }
    }
    guard let task else { t.check("sched: .cpu(2) task spawned", false); return }
    var posted = 0
    let deadline = ticks + 20 * timerHz
    while withUnsafeMutablePointer(to: &pinnedDone, { atomicLoad($0) }) == 0 && ticks < deadline {
        if posted < rounds { task.post(.message(posted)); posted += 1 }
        yield()
    }
    let finished = withUnsafeMutablePointer(to: &pinnedDone) { atomicLoad($0) } == 1
    let ranOnly2 = pinnedCPUs == 1 << 2 && task.lastCPU == 2
    t.check("sched: .cpu(2) task finished (yields and blocking waits)", finished)
    t.check("sched: .cpu(2) task only ever ran on CPU 2", ranOnly2)
    let doneBy = ticks + 5 * timerHz
    while task.state != .finished && ticks < doneBy { yield() }
    t.check("sched: .cpu(2) task exits there", task.state == .finished)
    if !ranOnly2 { print("  sched: pinned task CPU mask \(pinnedCPUs)") }
}

func schedTests(_ t: inout SelfTest) {
    t.check("sched: selftest runs on CPU 0, pinned there",
            currentCPU() == 0 && scheduler.current?.affinity == .cpu(0))
    let names = currentTaskNames()
    t.check("sched: cpus shows this task on CPU 0", names.first == "shell")
    var idleOK = true
    for i in 1..<max(smpStarted, 1) where names[i] != "idle" { idleOK = false }
    t.check("sched: idle APs run their idle task", idleOK)
    hammerTest(&t)
    anyPingPongTest(&t)
    pinnedTest(&t)
}
