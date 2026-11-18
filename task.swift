// Phase H3: cooperative kernel tasks. Phase S: on every CPU.
//
// A Task is a stack, a saved rsp and an inbox. Switching is cooperative:
// a task runs until it calls yield(), blocks in waitEvent() on an empty
// inbox, or returns. The timer never switches tasks. The main loop
// (runMainLoop) is task 0, on the boot stack: it polls the devices, routes
// events into inboxes, runs the ready tasks, and sleeps when there are none.
//
// Only the register save/restore is assembly (context_switch and the
// first-run trampoline in cpu.S); scheduling, canaries and the watchdog are
// here. No reference is held across the switch on a task's way out (see
// exitCurrentTask), so a finished task is freed by whichever task runs next
// on that CPU.
//
// Phase S (SMP):
// - Affinity. Every task is `.cpu(n)` or `.any`; spawn's default is
//   `.cpu(0)`, so task 0, the shells, terminals, the WM and the fs (none of
//   them locked) only ever run on CPU 0. `.any` tasks may run anywhere and
//   may touch only SMP-safe code (heap, pmm, scheduler, inboxes, print).
// - One shared run queue, filtered by affinity, plus `all` and `nextID`,
//   behind `schedLock` (IRQ-saving). Task state changes and the inbox
//   (Task.post / waitEvent) are under it too, so a wakeup can't be lost.
// - Per CPU (CPUSched, reached through PerCPU.sched): the current task, the
//   idle task (an AP's boot stack; CPU 0 has none: task 0 is always
//   runnable there) and the zombies, freed by the next task on that CPU.
// - Cross-CPU handoff. Task.onCPU (rspSlot[1]) is 1 while some CPU is on the
//   task's stack. The picker dequeues under the lock, drops the lock, spins
//   until onCPU == 0, sets it to 1, then switches. context_switch clears the
//   outgoing task's word after it has saved rsp and moved to the new stack.
// - Wakeups: a task made ready (spawn, post, yield) goes to an idle CPU that
//   may run it: `idleCPUMask` bit cleared, reschedule IPI (0xF0) sent.
//
// Lock order: schedLock -> heapLock -> pmmLock -> stdoutLock. Allocating
// (runQueue.append, inbox posts, print) under schedLock is allowed; nothing
// takes schedLock while holding any of the others, and Task.deinit takes
// only the heap and pmm locks. The lock is never held across context_switch.

/// Where a task may run.
enum Affinity: Equatable {
    case any
    case cpu(Int)

    func allows(_ cpu: Int) -> Bool {
        switch self {
        case .any: return true
        case .cpu(let n): return n == cpu
        }
    }

    /// Bit i set if CPU i may run the task.
    var mask: UInt64 {
        switch self {
        case .any: return ~0
        case .cpu(let n): return n >= 0 && n < 64 ? 1 << UInt64(n) : 0
        }
    }
}

final class Task {
    enum State: Equatable { case running, ready, blocked, finished }

    static let defaultStackSize = 64 * 1024
    /// Two words at the lowest address of every stack. An overflow runs into
    /// them before anything else; they are checked on every switch.
    static let canary: UInt64 = 0x5354_4143_4B21_C0DE

    /// Set once, by spawn under schedLock, before another CPU can see the task.
    var id: Int
    let name: String
    /// Changed only under schedLock (onCPU0 changes it for a while).
    var affinity: Affinity
    /// Changed only under schedLock.
    var state: State
    /// Touched only under schedLock (Task.post, waitEvent).
    var inbox = EventQueue()
    /// rspSlot[0]: where context_switch saves this task's rsp. rspSlot[1]:
    /// onCPU, 1 while a CPU is running on (or still leaving) this stack. Its
    /// own heap block, so the addresses are stable while the task is out.
    let rspSlot: UnsafeMutablePointer<UInt64>
    /// Lowest address of the stack (identity-mapped frames; the boot stack's
    /// lower-half alias for task 0, an AP's boot stack for its idle task),
    /// its frame count (0: not ours to free).
    let stackBottom: UInt
    let stackFrames: Int
    /// Run once on the task's own stack, then dropped.
    var body: (() -> Void)?
    /// Times this task was switched in.
    var runs = 0
    /// CPU it was last switched in on: its home, which it goes back to when
    /// that CPU is free (soft affinity; see takeRunnable). -1: never ran.
    var lastCPU = -1
    /// `ticks` when it last entered the run queue.
    var readySince: UInt64 = 0
    /// Phase 6A: the frame below the stack, unmapped in the identity map
    /// so an overflow faults (0: none).
    var guardPage: UInt = 0
    /// Phase 6B/6C: the process this task is the thread of (nil for kernel
    /// tasks), and the page tables to load when it is switched in (0: the
    /// kernel's). Set by the task itself (or before it first runs).
    var process: Process?
    var cr3: UInt64 = 0
    /// park/unpark (under schedLock): an unpark arrived since the last park.
    var wakePending = false

    var isMain: Bool { id == 0 }
    var stackTop: UInt { stackBottom + UInt(stackFrames * frameSize) }
    var onCPU: UnsafeMutablePointer<UInt64> { rspSlot + 1 }
    /// rspSlot[2]: user_run's saved kernel stack point while the task runs
    /// user code (0 otherwise): the syscall stack and TSS rsp0.
    var userEntry: UnsafeMutablePointer<UInt64> { rspSlot + 2 }

    init(id: Int, name: String, affinity: Affinity = .cpu(0), stackBottom: UInt, stackFrames: Int,
         body: (() -> Void)?) {
        self.id = id
        self.name = name
        self.affinity = affinity
        self.stackBottom = stackBottom
        self.stackFrames = stackFrames
        self.body = body
        state = body == nil ? .running : .ready
        rspSlot = .allocate(capacity: 3)
        rspSlot.initialize(to: 0)
        // A context with no body is the one already running (task 0, idle).
        (rspSlot + 1).initialize(to: body == nil ? 1 : 0)
        (rspSlot + 2).initialize(to: 0)
        writeCanary()
    }

    deinit {
        rspSlot.deallocate()
        if stackFrames > 0 { pmm.free(stackBottom, count: stackFrames) }
        if guardPage != 0 {
            setGuardPage(guardPage, guarded: false)
            pmm.free(guardPage)
        }
        _ = withUnsafeMutablePointer(to: &tasksFreed) { atomic_fetch_add64($0, 1) }
    }

    var canaryWords: UnsafeMutablePointer<UInt64> { UnsafeMutablePointer(bitPattern: stackBottom)! }

    func writeCanary() {
        canaryWords[0] = Task.canary
        canaryWords[1] = ~Task.canary
    }

    var canaryIntact: Bool { canaryWords[0] == Task.canary && canaryWords[1] == ~Task.canary }

    /// Queue an event; wakes the task if it is blocked waiting for one. Safe
    /// from any CPU (not from interrupt handlers: it allocates).
    func post(_ event: Event) {
        let flags = schedLock.acquireIRQ()
        inbox.post(event)
        if state == .blocked {
            state = .ready
            enqueue(self)
            wakeIdleCPU(for: self)
        }
        schedLock.releaseIRQ(flags)
    }

    /// Pre-build the stack so the first context_switch to it "returns" into
    /// task_trampoline (cpu.S), which calls task_main. Layout, matching
    /// context_switch's pops: [MXCSR | FCW << 32] r15 r14 r13 r12 rbx rbp ret.
    /// After the ret, rsp is the 16-aligned top, as the trampoline's call needs.
    func buildInitialFrame() {
        let top = stackTop & ~15
        let words = UnsafeMutablePointer<UInt64>(bitPattern: top - 8 * 8)!
        words[0] = UInt64(Task.initialMXCSR) | UInt64(Task.initialFCW) << 32
        for i in 1...6 { words[i] = 0 } // r15, r14, r13, r12, rbx, rbp
        words[7] = task_trampoline_address
        rspSlot.pointee = UInt64(top - 8 * 8)
    }

    /// Power-on defaults: all SIMD exceptions masked, round to nearest; x87
    /// all masked, 64-bit precision (what fninit sets).
    static let initialMXCSR: UInt32 = 0x1F80
    static let initialFCW: UInt16 = 0x037F
}

/// One CPU's scheduler state. Only that CPU writes it, `current` only under
/// schedLock (so other CPUs may read it under the lock: `cpus`).
final class CPUSched {
    let cpu: Int
    var current: Task?
    /// An AP's idle task (its boot stack): runs when nothing else may. Never
    /// in the run queue. Nil on CPU 0.
    var idle: Task?
    /// Finished tasks, freed by the next task to run on this CPU.
    var zombies: [Task] = []

    init(cpu: Int, current: Task, idle: Task?) {
        self.cpu = cpu
        self.current = current
        self.idle = idle
        zombies.reserveCapacity(8)
    }
}

/// Make `sched` CPU `cpu`'s (once, never freed).
func cpuSchedInstall(_ sched: CPUSched, cpu: Int) {
    let bits = UInt(bitPattern: Unmanaged.passRetained(sched).toOpaque())
    perCPUEntry(cpu).pointee.sched = UInt64(bits)
}

func cpuSched(_ cpu: Int) -> CPUSched? {
    let bits = perCPUEntry(cpu).pointee.sched
    guard bits != 0, let p = UnsafeRawPointer(bitPattern: UInt(bits)) else { return nil }
    return Unmanaged<CPUSched>.fromOpaque(p).takeUnretainedValue()
}

/// This CPU's scheduler state; nil before scheduler.start (CPU 0) or apMain.
func thisSched() -> CPUSched? {
    guard let e = thisCPUIfReady(), e.pointee.sched != 0 else { return nil }
    return cpuSched(Int(e.pointee.index))
}

/// The CPU the caller runs on (0 = BSP). For `.any` tasks this can change
/// at every yield or wait.
func currentCPU() -> Int { Int(cpuIndex()) }

/// The scheduler's shared state, behind schedLock. A class (one reference,
/// fields accessed in place) so no CPU ever copies the arrays.
final class Scheduler {
    var main: Task? = nil
    /// Ready tasks, in the order they will run (each CPU takes the first it
    /// may run).
    var runQueue: [Task] = []
    /// Every task that hasn't finished (task 0 first). Idle tasks aren't in it.
    var all: [Task] = []
    var nextID = 1
    var switches = 0
    var started = false

    /// The task running on this CPU; nil until start() makes the boot
    /// context task 0 (on an AP, its idle task until something else runs).
    var current: Task? { thisSched()?.current }
    /// This CPU's zombies (a copy).
    var zombies: [Task] { thisSched()?.zombies ?? [] }

    /// A task this CPU would take now is waiting in the run queue (as its
    /// idle context would: see takeRunnable).
    var hasReady: Bool {
        let cpu = currentCPU()
        let flags = schedLock.acquireIRQ()
        defer { schedLock.releaseIRQ(flags) }
        return runnableIndex(cpu, stealing: true) != nil
    }

    /// Tasks not yet finished (task 0 included).
    var taskCount: Int {
        schedLock.withIRQsOff { all.count }
    }

    /// Make the running context (the boot stack) task 0. Idempotent. CPU 0.
    func start() {
        guard !started else { return }
        runQueue.reserveCapacity(32) // so the queues don't reallocate in use
        all.reserveCapacity(32)
        let bottom = UInt(address(of: &bootStack)) - kernelAliasOffset
        let boot = Task(id: 0, name: "main", stackBottom: bottom, stackFrames: 0, body: nil)
        boot.lastCPU = 0
        cpuSchedInstall(CPUSched(cpu: 0, current: boot, idle: nil), cpu: 0)
        schedLock.withIRQsOff {
            main = boot
            all.append(boot)
        }
        perCPUEntry(0).pointee.watchdogActive = 1
        watchdogPet()
        watchdogArmed = true
        started = true
    }
}

let scheduler = Scheduler()
/// Task objects freed so far, on any CPU (selftests wait on it).
var tasksFreed: UInt64 = 0
var schedLock = SpinLock()

/// Bit i set while CPU i is idle (an AP in its idle loop's hlt, CPU 0 in
/// idleStep's hlt). Set under schedLock after finding nothing to run;
/// cleared by a waker (under schedLock) when it sends the IPI.
var idleCPUMask: UInt64 = 0
/// Where the next wakeup's search for an idle CPU starts (spreads tasks).
var wakeCursor = 0

/// After `task` became ready: wake one idle CPU (not this one) that may run
/// it. Under schedLock, so an idle CPU either sees the task in the queue
/// before it sleeps or has its bit set by then.
func wakeIdleCPU(for task: Task) {
    let me = cpuIndex()
    let idle = withUnsafeMutablePointer(to: &idleCPUMask) { atomic_load64($0) }
    let allowed = idle & task.affinity.mask & ~(1 << me)
    guard allowed != 0, x2apicEnabled else { return }
    func wake(_ cpu: Int) {
        _ = withUnsafeMutablePointer(to: &idleCPUMask) { atomic_fetch_and64($0, ~(1 << UInt64(cpu))) }
        sendIPI(apicID: UInt32(perCPUEntry(cpu).pointee.apicID), vector: Vector.reschedule)
    }
    // Its home CPU first, if that one is idle (soft affinity).
    let home = task.lastCPU
    if softAffinity && home >= 0 && home < 64 && allowed & (1 << UInt64(home)) != 0 { wake(home); return }
    // Else spread: prefer an idle AP; CPU 0 (the desktop) only if it's the
    // only choice.
    let candidates = allowed & ~1 != 0 ? allowed & ~1 : allowed
    let n = max(smpStarted, 1)
    for k in 0..<n {
        let cpu = (wakeCursor + 1 + k) % n
        guard candidates & (1 << UInt64(cpu)) != 0 else { continue }
        wakeCursor = cpu
        wake(cpu)
        return
    }
}

/// Put a ready task at the back of the run queue. Under schedLock.
func enqueue(_ task: Task) {
    task.readySince = ticks
    scheduler.runQueue.append(task)
}

func setIdle(_ on: Bool) {
    let bit: UInt64 = 1 << cpuIndex()
    withUnsafeMutablePointer(to: &idleCPUMask) {
        if on { _ = atomic_fetch_or64($0, bit) } else { _ = atomic_fetch_and64($0, ~bit) }
    }
}

/// Create a task that runs `body` on its own stack, and make it ready. It
/// runs the next time a CPU it may run on switches or idles. Nil if there is
/// no memory for the stack, or `.cpu(n)` names a CPU that isn't online.
/// Phase 6A: the stack gets an unmapped guard page below it. `setup` runs
/// on the new task before any CPU can run it (Phase 6C: a process's thread).
@discardableResult
func spawn(_ name: String, affinity: Affinity = .cpu(0), stackSize: Int = Task.defaultStackSize,
           setup: ((Task) -> Void)? = nil, _ body: @escaping () -> Void) -> Task? {
    scheduler.start()
    if case .cpu(let n) = affinity {
        guard n >= 0 && n < smpStarted && perCPUEntry(n).pointee.online else { return nil }
    }
    let frames = (max(stackSize, 4096) + frameSize - 1) / frameSize
    guard let base = pmm.allocate(count: frames + 1) else { return nil }
    let task = Task(id: -1, name: name, affinity: affinity, stackBottom: base + UInt(frameSize), stackFrames: frames,
                    body: body)
    if setGuardPage(base, guarded: true) { task.guardPage = base } else { pmm.free(base) }
    task.buildInitialFrame()
    setup?(task)
    schedLock.withIRQsOff {
        task.id = scheduler.nextID
        scheduler.nextID += 1
        scheduler.all.append(task)
        enqueue(task)
        wakeIdleCPU(for: task)
    }
    return task
}

/// Let every other ready task (that this CPU may run) run once, then
/// continue. A no-op when there is none, e.g. on an AP with nothing else
/// runnable.
func yield() {
    guard scheduler.current != nil else { return }
    reschedule(.yield)
}

/// The next event in the current task's inbox, blocking until there is one.
/// Task 0 must not call this (it is the one that fills inboxes).
func waitEvent() -> Event {
    guard let me = scheduler.current else { taskPanic("waitEvent before the scheduler started") }
    while true {
        if let event = schedLock.withIRQsOff({ me.inbox.next() }) { return event }
        guard !me.isMain else { taskPanic("the main task can't block") }
        reschedule(.block) // re-checks the inbox under the lock before blocking
    }
}

/// The next key in the current task's inbox (other events are dropped).
func waitKey() -> Key {
    while true {
        if case .key(let key) = waitEvent() { return key }
    }
}

enum SwitchReason { case yield, block, exit, park }

// MARK: park / unpark (Phase 6C)

/// Block the current task until unpark(it), unless an unpark already came
/// since the last park. Wakeups can be spurious (a post to the inbox wakes
/// it too), so callers loop on their own condition. Not for task 0.
func park() {
    guard let me = scheduler.current, !me.isMain else { return }
    reschedule(.park)
}

/// Wake `task` from park (or make its next park return at once). Any CPU.
func unpark(_ task: Task) {
    let flags = schedLock.acquireIRQ()
    task.wakePending = true
    if task.state == .blocked {
        task.state = .ready
        enqueue(task)
        wakeIdleCPU(for: task)
    }
    schedLock.releaseIRQ(flags)
}

// MARK: onCPU0 (Parts 6-7 "Scheduling")

/// Run `body` on CPU 0, where the unlocked subsystems live (fs, WM,
/// terminals, the process table, later the network stack): pin the current
/// task to CPU 0, yield until it is there, run the body, then restore its
/// affinity. Runs `body` directly if already pinned there (or before the
/// scheduler exists). It must not be called with interrupts off.
func onCPU0<R>(_ body: () -> R) -> R {
    guard let me = scheduler.current, !me.isMain, !(me.affinity == .cpu(0) && currentCPU() == 0) else {
        return body()
    }
    let saved = schedLock.withIRQsOff { () -> Affinity in
        let a = me.affinity
        me.affinity = .cpu(0)
        return a
    }
    while currentCPU() != 0 { yield() }
    let result = body()
    schedLock.withIRQsOff { me.affinity = saved }
    return result
}

/// Switch to the next task this CPU may run, if any. `why` says what
/// happens to the current task: requeued (yield), blocked (woken by post)
/// or finished (freed by the next task on this CPU).
@inline(never)
func reschedule(_ why: SwitchReason) {
    guard let (save, load) = prepareSwitch(why) else { return }
    switchStacks(save, load)
    afterSwitch()
}

/// The handoff: wait until no CPU is on `load`'s stack (its previous CPU
/// may still be inside context_switch), claim it, and switch. Raw pointers
/// only: nothing here keeps a task alive.
@inline(__always)
func switchStacks(_ save: UnsafeMutablePointer<UInt64>, _ load: UnsafeMutablePointer<UInt64>) {
    let onCPU = load + 1
    while atomic_load64(onCPU) != 0 { cpu_pause() }
    atomic_store64(onCPU, 1)
    context_switch(save, atomic_load64(load), save + 1)
}

// MARK: Soft affinity
//
// A task goes back to the CPU it last ran on (its home) when it can, so it
// isn't bounced between CPUs. Only a CPU with nothing else to do (its idle
// context: an AP's idle task, CPU 0's main task, or a task that is
// blocking or exiting) takes another CPU's task, and only if:
// - the task never ran (no home), on an AP; or
// - its home is busy running something else; or
// - it has waited stealDelayTicks in the queue (its home didn't come).
// CPU 0 runs the desktop, so it takes a task homed elsewhere (or a new one)
// only after that delay, or when no AP may run it: APs get first claim.
// A busy CPU that yields picks only tasks homed on it, so CPUs that each
// have work don't trade tasks back and forth.

/// Queue time after which any CPU allowed to may take a task (2 ticks: at
/// least 10 ms).
let stealDelayTicks: UInt64 = 2

/// Off: every CPU takes the first task it may run, and wakeups ignore the
/// home CPU (the Phase S behaviour). The .any ping-pong selftest turns it
/// off to keep stressing cross-CPU handoff, which homes otherwise avoid.
var softAffinity = true

/// Online CPUs, as a mask.
func onlineCPUMask() -> UInt64 {
    var mask: UInt64 = 0
    for i in 0..<max(smpStarted, 1) where perCPUEntry(i).pointee.online { mask |= 1 << UInt64(i) }
    return mask == 0 ? 1 : mask
}

/// `cpu` is `task`'s home: it last ran there, or it may run nowhere else.
func isHome(_ task: Task, _ cpu: Int, online: UInt64) -> Bool {
    task.lastCPU == cpu || task.affinity.mask & online == 1 << UInt64(cpu)
}

/// CPU `cpu`, in its idle context, may take `task` (not homed on it) now.
func mayAdopt(_ task: Task, _ cpu: Int, online: UInt64, now: UInt64) -> Bool {
    if now &- task.readySince >= stealDelayTicks { return true }
    if cpu == 0 { return task.affinity.mask & online & ~1 == 0 } // no AP may run it
    let home = task.lastCPU
    guard home >= 0 && home < 64 else { return true } // never ran: any AP may start it
    return perCPUEntry(home).pointee.watchdogActive != 0 // home is busy with another task
}

/// Index of the task CPU `cpu` should run next: the first homed on it, else
/// (when `stealing`) the first it may adopt. Under schedLock.
func runnableIndex(_ cpu: Int, stealing: Bool) -> Int? {
    guard softAffinity else { return scheduler.runQueue.firstIndex(where: { $0.affinity.allows(cpu) }) }
    let online = onlineCPUMask()
    if let i = scheduler.runQueue.firstIndex(where: { $0.affinity.allows(cpu) && isHome($0, cpu, online: online) }) {
        return i
    }
    guard stealing else { return nil }
    let now = ticks
    return scheduler.runQueue.firstIndex(where: {
        $0.affinity.allows(cpu) && mayAdopt($0, cpu, online: online, now: now)
    })
}

/// The task CPU `cpu` should run next (runnableIndex), removed. With
/// `force`, failing that, any task it may run at all (the caller has
/// nothing else to switch to). Under schedLock.
func takeRunnable(_ cpu: Int, stealing: Bool, force: Bool = false) -> Task? {
    if let i = runnableIndex(cpu, stealing: stealing) { return scheduler.runQueue.remove(at: i) }
    guard force, let i = scheduler.runQueue.firstIndex(where: { $0.affinity.allows(cpu) }) else { return nil }
    return scheduler.runQueue.remove(at: i)
}

/// All the bookkeeping of a switch, under schedLock and before it, so no
/// Swift reference lives in the frame that calls context_switch. Returns
/// where to save the current rsp and the incoming task's rsp slot, or nil
/// to keep running.
@inline(never)
func prepareSwitch(_ why: SwitchReason) -> (UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>)? {
    guard let sched = thisSched(), let prev = sched.current else { return nil }
    let flags = schedLock.acquireIRQ()
    defer { schedLock.releaseIRQ(flags) }
    if why == .block && !prev.inbox.isEmpty { return nil } // an event arrived: don't sleep
    if why == .park && prev.wakePending { prev.wakePending = false; return nil } // already unparked
    let next: Task
    // Yielding from a real task: only tasks homed here (no stealing while
    // busy). Blocking or exiting, or task 0 yielding, is this CPU's idle
    // context. CPU 0 has no idle task, so a block or exit there must find
    // something (task 0 is always queued then; `force` is a safety net).
    // Phase 6C: a yield by a task that may no longer run here (onCPU0) is
    // a move: it must leave, to the idle task if nothing else is ready.
    let moving = why == .yield && !prev.affinity.allows(sched.cpu)
    let stealing = why != .yield || prev.isMain || moving
    let force = (why != .yield || moving) && sched.idle == nil
    if let n = takeRunnable(sched.cpu, stealing: stealing, force: force) {
        next = n
    } else if why == .yield && !moving {
        watchdogSwitch(from: prev, toIdle: false) // cooperating counts, even with no switch
        return nil
    } else if let idle = sched.idle, idle !== prev {
        next = idle
    } else if moving {
        return nil // CPU 0 with nothing else ready: try again later
    } else {
        taskPanic("deadlock: no task is ready")
    }
    if !prev.canaryIntact { taskPanic("stack overflow (canary) in the task switching out") }
    if !next.canaryIntact { taskPanic("stack overflow (canary) in the task switching in") }
    watchdogSwitch(from: prev, toIdle: next === sched.idle)
    switch why {
    case .yield:
        prev.state = .ready
        enqueue(prev)
        wakeIdleCPU(for: prev)
    case .block, .park:
        prev.state = .blocked
    case .exit:
        prev.state = .finished
        sched.zombies.append(prev)
    }
    switchedIn(next, sched)
    return (prev.rspSlot, next.rspSlot)
}

/// Bookkeeping for the task about to run on this CPU. Under schedLock.
func switchedIn(_ next: Task, _ sched: CPUSched) {
    next.state = .running
    next.runs += 1
    next.lastCPU = sched.cpu
    sched.current = next
    scheduler.switches += 1
    let e = thisCPU()
    e.pointee.switches &+= 1
    e.pointee.inSyscall = 0 // (stats: the incoming task sets it again)
    e.pointee.processRunning = next.process != nil ? 1 : 0
    // Phase 6B: its page tables, and the kernel stack ring 3 enters on.
    let cr3 = next.cr3 != 0 ? next.cr3 : kernelCR3
    if cr3 != 0 && read_cr3() != cr3 { write_cr3(cr3) }
    let entry = next.userEntry.pointee
    if entry != 0 {
        e.pointee.syscallKernelRSP = entry
        e.pointee.tss[1] = UInt32(truncatingIfNeeded: entry)
        e.pointee.tss[2] = UInt32(truncatingIfNeeded: entry >> 32)
    }
}

/// Runs on the incoming task's stack after every switch: free the tasks that
/// finished on this CPU (none of them is the one running). Their deinit
/// (heap, pmm) runs outside schedLock.
func afterSwitch() {
    guard let sched = thisSched(), !sched.zombies.isEmpty else { return }
    schedLock.withIRQsOff {
        for dead in sched.zombies {
            if let i = scheduler.all.firstIndex(where: { $0 === dead }) { scheduler.all.remove(at: i) }
        }
    }
    sched.zombies.removeAll(keepingCapacity: true) // frees their stacks, unless someone still holds them
}

/// First code of every task, reached from task_trampoline (cpu.S).
@_cdecl("task_main")
public func taskMain() -> Never {
    afterSwitch()
    runCurrentBody()
    exitCurrentTask()
}

/// Its own frame, so the body closure (and its captures) are released when
/// it returns.
@inline(never)
func runCurrentBody() {
    guard let me = scheduler.current, let body = me.body else { return }
    me.body = nil
    body()
}

/// Leave for good. The finished task is in this CPU's zombies, so its stack
/// and rsp slot stay valid through the context_switch; the next task on
/// this CPU frees them.
@inline(never)
func exitCurrentTask() -> Never {
    let (save, load) = prepareExit()
    switchStacks(save, load)
    taskPanic("a finished task was resumed")
}

@inline(never)
func prepareExit() -> (UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>) {
    guard let me = scheduler.current, !me.isMain else { taskPanic("the main task returned") }
    guard let switchTo = prepareSwitch(.exit) else { taskPanic("no task to run after exit") }
    return switchTo
}

func taskPanic(_ why: StaticString) -> Never {
    panicBegin() // stop the other CPUs first (first CPU to panic wins)
    _ = stdoutLock.acquireForPanic() // bounded spin, then write anyway
    statusBarAlert(" *** TASK PANIC: system halted (see serial) ***")
    puts("\ntask panic: ")
    puts(why)
    puts(" (cpu ")
    printDec(cpuIndex())
    puts(")")
    newline()
    panicFlush()
    qemuExit(1)
}

// MARK: AP idle task

/// An AP's scheduler state: its boot context (the stack it will run on)
/// becomes its idle task. Built by the BSP in smpInit before it starts the
/// AP, so APs allocate nothing while booting.
func apSchedInit(cpu: Int) {
    let e = perCPUEntry(cpu)
    let idle = Task(id: -1, name: "idle", affinity: .cpu(cpu), stackBottom: UInt(e.pointee.stackBase),
                    stackFrames: 0, body: nil)
    idle.lastCPU = cpu
    schedLock.withIRQsOff {
        idle.id = scheduler.nextID
        scheduler.nextID += 1
    }
    cpuSchedInstall(CPUSched(cpu: cpu, current: idle, idle: idle), cpu: cpu)
}

/// The AP's idle loop (its idle task): run whatever this CPU may run, else
/// sleep until a reschedule IPI. The check and the sleep can't race a
/// wakeup: interrupts are off from the check (which sets this CPU's idle
/// bit under schedLock) to `sti; hlt`, and a pending IPI ends the hlt.
func apIdleLoop() -> Never {
    while true {
        cli()
        if let (save, load) = idlePick() {
            sti()
            switchStacks(save, load)
            afterSwitch()
            continue
        }
        sti_hlt()
        thisCPU().pointee.idleWakeups &+= 1
    }
}

/// Interrupts are off. The next task for this CPU (switched in), or nil
/// with this CPU marked idle.
@inline(never)
func idlePick() -> (UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>)? {
    guard let sched = thisSched(), let idle = sched.idle else { return nil }
    schedLock.acquire()
    defer { schedLock.release() }
    guard let next = takeRunnable(sched.cpu, stealing: true) else {
        setIdle(true)
        thisCPU().pointee.watchdogActive = 0
        return nil
    }
    setIdle(false)
    if !next.canaryIntact { taskPanic("stack overflow (canary) in the task switching in") }
    watchdogSwitch(from: idle, toIdle: false)
    idle.state = .ready
    switchedIn(next, sched)
    return (idle.rspSlot, next.rspSlot)
}

// MARK: Main loop

/// The event loop, as task 0: poll the devices, hand each event to `route`
/// (which posts it into some task's inbox), let the ready tasks run, and
/// sleep when none are ready.
func runMainLoop(_ route: (Event) -> Void) -> Never {
    scheduler.start()
    while true {
        pollEvents()
        wakeDueDeadlines() // Phase 6E4: timed waits (deadline.swift)
        while let event = events.next() { route(event) }
        if scheduler.hasReady {
            // Busy (e.g. CPU 0 running a share of `par`): still redraw,
            // once per tick, before letting the tasks run.
            let t = ticks
            if t != lastBusyRefresh { lastBusyRefresh = t; refreshStep() }
            yield()
        } else {
            idleStep()
        }
    }
}

/// `ticks` at the main loop's last refresh while tasks were ready.
var lastBusyRefresh: UInt64 = 0

/// Part 2 on Phase H: the shell runs in its own task (LiveTerminal.read
/// blocks on that task's inbox) and the main loop sends it every key.
func runShellTask() -> Never {
    guard let shell = spawn("shell", { var sh = Shell(terminal: LiveTerminal()); sh.run() }) else {
        puts("tasks: no memory for the shell's stack\n")
        hcf()
    }
    runMainLoop { event in
        if let wm = windowManager {
            wm.route(event) // Phase K: after `desktop`, the WM routes everything
        } else if case .key = event {
            shell.post(event)
        }
    }
}

/// Every task but task 0 and the caller is blocked with an empty inbox, and
/// this CPU has no zombies (settled; selftests).
func otherTasksSettled() -> Bool {
    guard let sched = thisSched() else { return true }
    if !sched.zombies.isEmpty { return false }
    let me = sched.current
    return schedLock.withIRQsOff {
        for task in scheduler.all where !task.isMain && task !== me {
            if task.state != .blocked || !task.inbox.isEmpty { return false }
        }
        return true
    }
}

/// Per CPU: its index and the name of the task running there ("-" if the
/// CPU has no scheduler state).
func currentTaskNames() -> [String] {
    var names: [String] = []
    names.reserveCapacity(smpStarted)
    schedLock.withIRQsOff {
        for i in 0..<smpStarted { names.append(cpuSched(i)?.current?.name ?? "-") }
    }
    return names
}

// MARK: Watchdog

// Per CPU (PerCPU.watchdogMark/Active/Tripped), checked by the BSP's timer
// IRQ (no allocation, no locks, no classes). A task that runs longer than
// watchdogLimit ticks without switching, yielding or sleeping in idleStep
// gets a raw serial warning from the IRQ (the only code that still runs on
// CPU 0 while it spins there), then a report and a status-bar alert once it
// finally lets go.

var watchdogArmed = false
var watchdogLimit: UInt64 = timerHz
/// Overruns reported (under schedLock).
var watchdogTrips = 0
/// Show the status-bar alert until this tick.
var watchdogAlertUntil: UInt64 = 0

/// Set by the IRQ once per overrun on this CPU.
var watchdogTripped: Bool {
    get { thisCPU().pointee.watchdogTripped != 0 }
    set { thisCPU().pointee.watchdogTripped = newValue ? 1 : 0 }
}

func watchdogPet() {
    thisCPU().pointee.watchdogMark = ticks
}

/// Timer IRQ (interrupts.swift), on the BSP. Allocation-free; raw serial
/// only, because the console may be in the middle of an update.
func watchdogTick() {
    guard watchdogArmed else { return }
    let now = ticks
    for i in 0..<smpStarted {
        let e = perCPUEntry(i)
        guard e.pointee.watchdogActive != 0, e.pointee.watchdogTripped == 0, e.pointee.processRunning == 0,
              now &- e.pointee.watchdogMark > watchdogLimit else { continue }
        e.pointee.watchdogTripped = 1
        let head: StaticString = "\r\n[watchdog: a task has not yielded within the limit"
        head.withUTF8Buffer { for b in $0 { serialPutc(b) } }
        if i != 0 {
            let on: StaticString = " (cpu "
            on.withUTF8Buffer { for b in $0 { serialPutc(b) } }
            if i >= 10 { serialPutc(UInt8(48 + i / 10)) }
            serialPutc(UInt8(48 + i % 10))
            serialPutc(0x29)
        }
        let tail: StaticString = "]\r\n"
        tail.withUTF8Buffer { for b in $0 { serialPutc(b) } }
    }
}

/// On a switch away from `prev` (or a yield that kept it): report an
/// overrun, restart the clock. Under schedLock.
func watchdogSwitch(from prev: Task, toIdle: Bool) {
    let e = thisCPU()
    if e.pointee.watchdogTripped != 0 {
        watchdogTrips += 1
        watchdogAlertUntil = ticks + 5 * timerHz
        let cpu = e.pointee.index
        print("watchdog: task \(prev.id) (\(prev.name)) ran \((ticks &- e.pointee.watchdogMark) * 1000 / timerHz) ms without yielding\(cpu == 0 ? "" : " on cpu \(cpu)")")
        e.pointee.watchdogTripped = 0
    }
    e.pointee.watchdogMark = ticks
    if e.pointee.index != 0 { e.pointee.watchdogActive = toIdle ? 0 : 1 }
}

/// Called right after the status bar is redrawn: keep the alert on top.
func watchdogStatus() {
    if ticks < watchdogAlertUntil {
        statusBarAlert(" *** watchdog: a task ran over 1 s without yielding (see serial) ***")
    }
}
