// Phase H3: cooperative kernel tasks.
//
// A Task is a stack, a saved rsp and an inbox. Switching is cooperative:
// a task runs until it calls yield(), blocks in waitEvent() on an empty
// inbox, or returns. The timer never switches tasks, so the heap and the
// console need no locks. The main loop (runMainLoop) is task 0, on the boot
// stack: it polls the devices, routes events into inboxes, runs the ready
// tasks, and sleeps when there are none.
//
// Only the register save/restore is assembly (context_switch and the
// first-run trampoline in cpu.S); scheduling, canaries and the watchdog are
// here. No reference is held across the switch on a task's way out (see
// exitCurrentTask), so a finished task is freed by whichever task runs next.

final class Task {
    enum State: Equatable { case running, ready, blocked, finished }

    static let defaultStackSize = 64 * 1024
    /// Two words at the lowest address of every stack. An overflow runs into
    /// them before anything else; they are checked on every switch.
    static let canary: UInt64 = 0x5354_4143_4B21_C0DE

    let id: Int
    let name: String
    var state: State
    var inbox = EventQueue()
    /// Where context_switch saves this task's rsp. Its own heap block, so the
    /// address is stable while the task is switched out.
    let rspSlot: UnsafeMutablePointer<UInt64>
    /// Lowest address of the stack (identity-mapped frames; the boot stack's
    /// lower-half alias for task 0), its frame count (0: not ours to free).
    let stackBottom: UInt
    let stackFrames: Int
    /// Run once on the task's own stack, then dropped.
    var body: (() -> Void)?
    /// Times this task was switched in.
    var runs = 0

    var isMain: Bool { id == 0 }
    var stackTop: UInt { stackBottom + UInt(stackFrames * frameSize) }

    init(id: Int, name: String, stackBottom: UInt, stackFrames: Int, body: (() -> Void)?) {
        self.id = id
        self.name = name
        self.stackBottom = stackBottom
        self.stackFrames = stackFrames
        self.body = body
        state = body == nil ? .running : .ready
        rspSlot = .allocate(capacity: 1)
        rspSlot.initialize(to: 0)
        writeCanary()
    }

    deinit {
        rspSlot.deallocate()
        if stackFrames > 0 { pmm.free(stackBottom, count: stackFrames) }
    }

    var canaryWords: UnsafeMutablePointer<UInt64> { UnsafeMutablePointer(bitPattern: stackBottom)! }

    func writeCanary() {
        canaryWords[0] = Task.canary
        canaryWords[1] = ~Task.canary
    }

    var canaryIntact: Bool { canaryWords[0] == Task.canary && canaryWords[1] == ~Task.canary }

    /// Queue an event; wakes the task if it is blocked waiting for one.
    func post(_ event: Event) {
        inbox.post(event)
        if state == .blocked {
            state = .ready
            scheduler.runQueue.append(self)
        }
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

struct Scheduler {
    /// The running task; nil until start() makes the boot context task 0.
    var current: Task? = nil
    var main: Task? = nil
    /// Ready tasks, in the order they will run.
    var runQueue: [Task] = []
    /// Every task that hasn't finished (task 0 first).
    var all: [Task] = []
    /// Finished tasks, freed by the next task to run.
    var zombies: [Task] = []
    var nextID = 0
    var switches = 0

    var started: Bool { current != nil }
    var hasReady: Bool { !runQueue.isEmpty }

    /// Make the running context (the boot stack) task 0. Idempotent.
    mutating func start() {
        guard current == nil else { return }
        runQueue.reserveCapacity(32) // so the queues don't reallocate in use
        all.reserveCapacity(32)
        let bottom = UInt(address(of: &bootStack)) - kernelAliasOffset
        let boot = Task(id: 0, name: "main", stackBottom: bottom, stackFrames: 0, body: nil)
        nextID = 1
        current = boot
        main = boot
        all.append(boot)
        watchdogPet()
        watchdogArmed = true
    }
}

var scheduler = Scheduler()

/// Create a task that runs `body` on its own stack, and make it ready. It
/// runs the next time the current task yields or blocks. Nil if there is no
/// memory for the stack.
@discardableResult
func spawn(_ name: String, stackSize: Int = Task.defaultStackSize, _ body: @escaping () -> Void) -> Task? {
    scheduler.start()
    let frames = (max(stackSize, 4096) + frameSize - 1) / frameSize
    guard let bottom = pmm.allocate(count: frames) else { return nil }
    let task = Task(id: scheduler.nextID, name: name, stackBottom: bottom, stackFrames: frames, body: body)
    scheduler.nextID += 1
    task.buildInitialFrame()
    scheduler.all.append(task)
    scheduler.runQueue.append(task)
    return task
}

/// Let every other ready task run once, then continue. A no-op when nothing
/// else is ready.
func yield() {
    guard let me = scheduler.current, scheduler.hasReady else { return }
    me.state = .ready
    scheduler.runQueue.append(me)
    reschedule()
}

/// The next event in the current task's inbox, blocking until there is one.
/// Task 0 must not call this (it is the one that fills inboxes).
func waitEvent() -> Event {
    guard let me = scheduler.current else { taskPanic("waitEvent before the scheduler started") }
    while true {
        if let event = me.inbox.next() { return event }
        guard !me.isMain else { taskPanic("the main task can't block") }
        me.state = .blocked
        reschedule()
    }
}

/// The next key in the current task's inbox (other events are dropped).
func waitKey() -> Key {
    while true {
        if case .key(let key) = waitEvent() { return key }
    }
}

/// Switch to the head of the run queue, if any. The current task's state
/// says what happens to it: requeued by the caller (yield), blocked (woken
/// by post) or finished (freed by the next task).
@inline(never)
func reschedule() {
    guard let regs = prepareSwitch() else { return }
    context_switch(regs.0, regs.1)
    afterSwitch()
}

/// All the bookkeeping of a switch, done before it, so no Swift reference
/// lives in the frame that calls context_switch. Returns where to save the
/// current rsp and the rsp to load, or nil to keep running.
@inline(never)
func prepareSwitch() -> (UnsafeMutablePointer<UInt64>, UInt64)? {
    guard let prev = scheduler.current else { return nil }
    guard !scheduler.runQueue.isEmpty else {
        if prev.state == .ready { prev.state = .running; return nil } // nothing else to run
        taskPanic("deadlock: no task is ready")
    }
    let next = scheduler.runQueue.removeFirst()
    if !prev.canaryIntact { taskPanic("stack overflow (canary) in the task switching out") }
    if !next.canaryIntact { taskPanic("stack overflow (canary) in the task switching in") }
    watchdogSwitch(from: prev)
    if prev.state == .running { prev.state = .ready } // shouldn't happen, but don't lose it
    next.state = .running
    next.runs += 1
    scheduler.current = next
    scheduler.switches += 1
    if next === prev { return nil }
    return (prev.rspSlot, next.rspSlot.pointee)
}

/// Runs on the incoming task's stack after every switch: free the tasks that
/// finished (none of them is the one running).
func afterSwitch() {
    guard !scheduler.zombies.isEmpty else { return }
    for dead in scheduler.zombies {
        if let i = scheduler.all.firstIndex(where: { $0 === dead }) { scheduler.all.remove(at: i) }
    }
    scheduler.zombies.removeAll() // frees their stacks, unless someone still holds them
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

/// Leave for good. The finished task is in `zombies`, so its stack and rsp
/// slot stay valid through the context_switch; the next task frees them.
@inline(never)
func exitCurrentTask() -> Never {
    let (save, load) = prepareExit()
    context_switch(save, load)
    taskPanic("a finished task was resumed")
}

@inline(never)
func prepareExit() -> (UnsafeMutablePointer<UInt64>, UInt64) {
    guard let me = scheduler.current, !me.isMain else { taskPanic("the main task returned") }
    me.state = .finished
    scheduler.zombies.append(me)
    guard let switchTo = prepareSwitch() else { taskPanic("no task to run after exit") }
    return switchTo
}

func taskPanic(_ why: StaticString) -> Never {
    statusBarAlert(" *** TASK PANIC: system halted (see serial) ***")
    puts("\ntask panic: ")
    puts(why)
    newline()
    qemuExit(1)
}

/// The event loop, as task 0: poll the devices, hand each event to `route`
/// (which posts it into some task's inbox), let the ready tasks run, and
/// sleep when none are ready.
func runMainLoop(_ route: (Event) -> Void) -> Never {
    scheduler.start()
    while true {
        pollEvents()
        while let event = events.next() { route(event) }
        if scheduler.hasReady { yield() } else { idleStep() }
    }
}

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

// MARK: Watchdog

// Plain globals, because the timer IRQ reads them (no allocation, no
// classes). A task that runs longer than watchdogLimit ticks without
// switching or sleeping in idleStep gets a serial warning from the IRQ (the
// only code that still runs while it spins), then a report and a status-bar
// alert once it finally lets go.

var watchdogArmed = false
/// `ticks` when the running task was switched in, or last idled.
var watchdogMark: UInt64 = 0
var watchdogLimit: UInt64 = timerHz
/// Set by the IRQ once per overrun.
var watchdogTripped = false
var watchdogTrips = 0
/// Show the status-bar alert until this tick.
var watchdogAlertUntil: UInt64 = 0

func watchdogPet() {
    watchdogMark = ticks
}

/// Timer IRQ (interrupts.swift). Allocation-free; raw serial only, because
/// the console may be in the middle of an update.
func watchdogTick() {
    guard watchdogArmed, !watchdogTripped, ticks &- watchdogMark > watchdogLimit else { return }
    watchdogTripped = true
    let message: StaticString = "\r\n[watchdog: a task has not yielded within the limit]\r\n"
    message.withUTF8Buffer { for b in $0 { serialPutc(b) } }
}

/// On a switch away from `prev`: report an overrun, restart the clock.
func watchdogSwitch(from prev: Task) {
    if watchdogTripped {
        watchdogTripped = false
        watchdogTrips += 1
        watchdogAlertUntil = ticks + 5 * timerHz
        print("watchdog: task \(prev.id) (\(prev.name)) ran \((ticks &- watchdogMark) * 1000 / timerHz) ms without yielding")
    }
    watchdogPet()
}

/// Called right after the status bar is redrawn: keep the alert on top.
func watchdogStatus() {
    if ticks < watchdogAlertUntil {
        statusBarAlert(" *** watchdog: a task ran over 1 s without yielding (see serial) ***")
    }
}
