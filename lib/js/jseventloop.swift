// JSEventLoop: the task queue, timers and microtask checkpoint an embedder
// (/bin/js, the browser) drives (ROADMAP Phase 9F).
//
//     let loop = JSEventLoop(realm: realm, clock: { nowMs })   // installs the
//         // globals setTimeout, setInterval, clearTimeout, clearInterval,
//         // queueMicrotask
//     loop.beginTask = { deadline = now + 5000 }        // before every task
//     loop.reportException = { e in ... }               // uncaught in a task
//     loop.reportTermination = { why in ... }           // budget / heap cap
//
//     // /bin/js: run until nothing is left (sleeping between timers).
//     loop.runUntilIdle(sleep: { ms in Time.sleep(ms) })
//
//     // The browser: one step per App.run wake-up.
//     loop.queueTask { ... }                // a Swift task (network, input)
//     loop.runDueTasks()                    // everything due now, each
//                                           // followed by a microtask checkpoint
//     let ms = loop.nextDeadline()          // nil: idle; 0: work now;
//                                           // else ms until the next timer
//
// Timers follow HTML's timer initialisation steps: the delay is ToNumber'd
// (NaN and negatives are 0), and a timer created while its nesting level is
// above 5 (nested timeouts, or an interval's repeats) waits at least 4 ms.
// Callbacks run as tasks in (due time, creation order) order.
//
// The microtask checkpoint is `performMicrotaskCheckpoint()`: it drains the
// queue behind queueMicrotask and, when the VM's Promise job queue exists
// (9E), that too (the single place to wire it).

public final class JSEventLoop {
    public unowned(unsafe) let realm: JSRealm
    let clock: () -> Double

    struct Timer {
        var id: Int
        var seq: Int
        var due: Double
        var interval: Double      // < 0: a one-shot
        var nesting: Int
        var callback: JSPersistent
        var args: [JSPersistent]
    }
    var timers: [Timer] = []
    var nextTimerID = 1
    var nextSeq = 0
    /// Nesting level of the timer callback running now (0 outside one).
    var currentNesting = 0

    var tasks: [() -> Void] = []
    var taskHead = 0
    var microtasks: [JSPersistent] = []
    var microHead = 0
    var inCheckpoint = false

    /// Timer limits: a page may not hold more than this many pending timers.
    public var maxTimers = 100_000
    /// Called before each task or timer callback (reset the time budget).
    public var beginTask: (() -> Void)? = nil
    public var reportException: ((JSUncaughtException) -> Void)? = nil
    public var reportTermination: ((JSTerminationReason) -> Void)? = nil

    public init(realm: JSRealm, clock: @escaping () -> Double) {
        self.realm = realm
        self.clock = clock
        install()
    }

    // MARK: Swift tasks

    /// Queue a Swift task (runs on the next runDueTasks).
    public func queueTask(_ task: @escaping () -> Void) { tasks.append(task) }

    /// Queue a JS callback as a task, e.g. a DOM event listener call.
    public func queueCallback(_ f: JSValue, this: JSValue = .undefined, args: [JSValue] = []) {
        let pf = realm.heap.retain(f)
        let pt = realm.heap.retain(this)
        var pa: [JSPersistent] = []
        for a in args { pa.append(realm.heap.retain(a)) }
        tasks.append { [self] in
            runJS(realm.heap[pf], this: realm.heap[pt], args: pa.map { realm.heap[$0] })
            realm.heap.release(pf)
            realm.heap.release(pt)
            for p in pa { realm.heap.release(p) }
        }
    }

    /// Run one JS callback as a top-level call (budget, exception and
    /// termination reporting included), without a microtask checkpoint.
    public func runJS(_ f: JSValue, this: JSValue, args: [JSValue]) {
        beginTask?()
        let c = realm.runCallback(f, this: this, args: args)
        handle(c)
    }

    func handle(_ c: JSCompletion) {
        switch c {
        case .normal: break
        case .exception(let e): reportException?(e)
        case .terminated(let why): reportTermination?(why)
        }
    }

    /// Report the outcome of a script the embedder ran itself (evaluate).
    public func report(_ c: JSCompletion) { handle(c) }

    // MARK: Microtasks

    /// Drain the microtask queue. After a termination the queue is dropped.
    public func performMicrotaskCheckpoint() {
        if inCheckpoint { return }
        inCheckpoint = true
        defer { inCheckpoint = false }
        var guardCount = 0
        while microHead < microtasks.count && guardCount < 10_000_000 {
            guardCount += 1
            let p = microtasks[microHead]
            microHead += 1
            let f = realm.heap[p]
            realm.heap.release(p)
            beginMicrotask()
            let c = realm.runCallback(f, this: .undefined, args: [])
            handle(c)
            if case .terminated = c { dropMicrotasks() }
        }
        dropMicrotasks()
        drainVMJobs()
    }

    func beginMicrotask() {}

    func dropMicrotasks() {
        for i in microHead..<microtasks.count { realm.heap.release(microtasks[i]) }
        microtasks.removeAll(keepingCapacity: true)
        microHead = 0
    }

    /// 9E: run the VM's Promise jobs here (and report unhandled rejections).
    func drainVMJobs() {}

    // MARK: Timers

    func addTimer(_ f: JSValue, delay d: Double, args: [JSValue], repeating: Bool) -> Int {
        var delay = d.isNaN || d < 0 ? 0.0 : d
        if delay > 2_147_483_647 { delay = 2_147_483_647 }
        delay = delay.rounded(.down)
        let nesting = currentNesting + 1
        if nesting > 5 && delay < 4 { delay = 4 }
        let id = nextTimerID
        nextTimerID += 1
        nextSeq += 1
        var pa: [JSPersistent] = []
        for a in args { pa.append(realm.heap.retain(a)) }
        timers.append(Timer(id: id, seq: nextSeq, due: clock() + delay, interval: repeating ? delay : -1,
                            nesting: nesting, callback: realm.heap.retain(f), args: pa))
        return id
    }

    func removeTimer(at i: Int) {
        let t = timers.remove(at: i)
        realm.heap.release(t.callback)
        for p in t.args { realm.heap.release(p) }
    }

    public func clearTimer(_ id: Int) {
        for i in 0..<timers.count where timers[i].id == id {
            removeTimer(at: i)
            return
        }
    }

    /// Cancel everything (the page is going away).
    public func clearAll() {
        while !timers.isEmpty { removeTimer(at: timers.count - 1) }
        while taskHead < tasks.count { taskHead += 1 }
        tasks.removeAll()
        taskHead = 0
        dropMicrotasks()
    }

    public var pendingTimerCount: Int { timers.count }

    /// Index of the timer to run next: earliest due, then oldest.
    func earliestTimer() -> Int? {
        var best = -1
        for i in 0..<timers.count {
            if best < 0 || timers[i].due < timers[best].due
                || (timers[i].due == timers[best].due && timers[i].seq < timers[best].seq) { best = i }
        }
        return best < 0 ? nil : best
    }

    // MARK: Running

    public var hasPendingWork: Bool { taskHead < tasks.count || microHead < microtasks.count || !timers.isEmpty }

    /// Milliseconds until something is due: nil when idle, 0 when a task
    /// is ready now.
    public func nextDeadline() -> Double? {
        if taskHead < tasks.count || microHead < microtasks.count { return 0 }
        guard let i = earliestTimer() else { return nil }
        return max(0, timers[i].due - clock())
    }

    /// Run the next ready task or due timer (with its microtask checkpoint).
    /// Returns false when nothing was ready.
    @discardableResult
    public func runOneTask() -> Bool {
        if microHead < microtasks.count { performMicrotaskCheckpoint(); return true }
        if taskHead < tasks.count {
            let t = tasks[taskHead]
            taskHead += 1
            if taskHead == tasks.count { tasks.removeAll(keepingCapacity: true); taskHead = 0 }
            beginTask?()
            t()
            performMicrotaskCheckpoint()
            return true
        }
        guard let i = earliestTimer(), timers[i].due <= clock() else { return false }
        let t = timers[i]
        let f = realm.heap[t.callback]
        let args = t.args.map { realm.heap[$0] }
        if t.interval >= 0 {
            timers[i].due = max(t.due, clock() - 1_000) + t.interval   // don't burst after a stall
            if timers[i].due < clock() { timers[i].due = clock() + t.interval }
            timers[i].nesting = t.nesting + 1
            nextSeq += 1
            timers[i].seq = nextSeq
            if timers[i].nesting > 5 && timers[i].interval < 4 {
                timers[i].interval = 4
                timers[i].due = max(timers[i].due, clock() + 4)
            }
        } else {
            // Keep the callback and args alive through the call: take them
            // out of the table only afterwards.
            timers[i].interval = -2
        }
        let saved = currentNesting
        currentNesting = t.nesting
        runJS(f, this: realm.global, args: args)
        currentNesting = saved
        if t.interval < 0 {
            for j in 0..<timers.count where timers[j].id == t.id { removeTimer(at: j); break }
        }
        performMicrotaskCheckpoint()
        return true
    }

    /// Run every task that is ready now (bounded, so a timer that always
    /// re-arms with delay 0 cannot starve the caller).
    public func runDueTasks(limit: Int = 1000) {
        var n = 0
        while n < limit && runOneTask() { n += 1 }
    }

    /// Run until no task, microtask or timer is left. `sleep(ms)` waits for
    /// the next timer; `shouldStop` lets the embedder break out (Ctrl-C).
    public func runUntilIdle(sleep: (Int) -> Void, shouldStop: () -> Bool = { false }) {
        performMicrotaskCheckpoint()
        while hasPendingWork && !shouldStop() {
            if runOneTask() { continue }
            if let d = nextDeadline(), d > 0 { sleep(Int(d.rounded(.up))) }
        }
    }

    // MARK: Globals

    func install() {
        let r = realm
        let g = r.global
        r.defineMethod(g, "setTimeout", length: 1) { [self] (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            try self.jsSetTimer(realm, args, repeating: false)
        }
        r.defineMethod(g, "setInterval", length: 1) { [self] (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            try self.jsSetTimer(realm, args, repeating: true)
        }
        let clear: JSNativeFunction = { [self] (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let v = args[0]
            if v.isNullish { return .undefined }
            let d = try realm.toNumber(v)
            if d == d.rounded(.towardZero) && d >= 1 && d < 2_147_483_648 { self.clearTimer(Int(d)) }
            return .undefined
        }
        r.defineMethod(g, "clearTimeout", length: 1, clear)
        r.defineMethod(g, "clearInterval", length: 1, clear)
        r.defineMethod(g, "queueMicrotask", length: 1) { [self] (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let f = args[0]
            if !realm.heap.isCallable(f) { throw realm.throwTypeError("queueMicrotask: argument is not a function") }
            if self.microtasks.count - self.microHead >= self.maxTimers { throw realm.throwRangeError("too many microtasks") }
            self.microtasks.append(realm.heap.retain(f))
            return .undefined
        }
    }

    func jsSetTimer(_ realm: JSRealm, _ args: JSArgs, repeating: Bool) throws(JSThrow) -> JSValue {
        let f = args[0]
        if !realm.heap.isCallable(f) {
            throw realm.throwTypeError((repeating ? "setInterval" : "setTimeout") + ": callback is not a function")
        }
        if timers.count >= maxTimers { throw realm.throwRangeError("too many timers") }
        let d = args.count > 1 ? try realm.toNumber(args[1]) : 0
        var extra: [JSValue] = []
        if args.count > 2 { for i in 2..<args.count { extra.append(args[i]) } }
        return .number(addTimer(f, delay: d, args: extra, repeating: repeating))
    }
}

extension JSRealm {
    /// Call `f` as a top-level task (like evaluate): sets up the stack
    /// floor, turns an uncaught exception or a termination into a
    /// JSCompletion and leaves the realm reusable.
    public func runCallback(_ f: JSValue, this: JSValue, args: [JSValue]) -> JSCompletion {
        let outer = nativeDepth == 0 && frames.isEmpty
        if outer { stackFloor = jsVMStackFloor(limits) }
        let depth = heap.rootDepth
        defer { heap.popRoots(to: depth) }
        do throws(JSThrow) {
            let v = try call(f, this: this, args: args)
            if outer && heap.termination == .interrupted { heap.clearTermination() }
            return .normal(v)
        } catch {
            return finishCompletion(outer: outer)
        }
    }
}
