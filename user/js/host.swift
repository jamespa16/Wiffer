// /bin/js: the embedder glue. One JSShell owns the runtime, the realm, the
// event loop, the output buffer and the time budget.

/// Days since the epoch of a civil date (proleptic Gregorian).
func jsShellDaysFromCivil(_ y: Int, _ m: Int, _ d: Int) -> Int {
    let yy = m <= 2 ? y - 1 : y
    let era = (yy >= 0 ? yy : yy - 399) / 400
    let yoe = yy - era * 400
    let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146097 + doe - 719468
}

func jsShellSysInfo() -> SysInfo {
    var s = SysInfo()
    _ = withUnsafeMutablePointer(to: &s) { syscall(SyscallNumber.sysinfo, UInt64(UInt(bitPattern: $0))) }
    return s
}

final class JSShell {
    var runtime: JSRuntime
    var realm: JSRealm! = nil
    var loop: JSEventLoop! = nil
    var out: [UInt8] = []
    /// Wall-clock budget per top-level task in ms (0: none).
    var budgetMs = 5000
    var deadline = 0
    var timedOut = false
    var interrupted = false
    var terminated = false
    /// Poll the terminal for Ctrl-C (the REPL, in raw mode).
    var watchInterrupt = false
    var lastPoll = 0
    var typeahead: [UInt8] = []
    var heapMiB = 64
    var failed = false
    let epochBaseMs: Double
    let bootBase: Int

    init(heapMiB: Int, budgetMs: Int) {
        self.heapMiB = heapMiB
        self.budgetMs = budgetMs
        var limits = JSLimits()
        limits.heapBytes = heapMiB << 20
        runtime = JSRuntime(limits: limits)
        let i = jsShellSysInfo()
        let days = jsShellDaysFromCivil(Int(i.year), Int(i.month), Int(i.day))
        epochBaseMs = Double(days) * 86_400_000 + Double(i.hour) * 3_600_000 + Double(i.minute) * 60_000
            + Double(i.second) * 1000
        bootBase = Time.now
        realm = runtime.makeRealm()
        runtime.interruptHandler = { [unowned(unsafe) self] _ in self.shouldInterrupt() }
        var seed: UInt64 = 0
        let r = withUnsafeMutablePointer(to: &seed) { syscall(SyscallNumber.getrandom, UInt64(UInt(bitPattern: $0)), 8, 0) }
        if r == 8 { realm.seedRandom(seed) } else { realm.seedRandom(UInt64(truncatingIfNeeded: wiffer_rdtsc())) }
        realm.nowMs = { [unowned(unsafe) self] in self.wallMs() }
        loop = JSEventLoop(realm: realm, clock: { Double(Time.now) })
        loop.beginTask = { [unowned(unsafe) self] in self.beginTask() }
        loop.reportException = { [unowned(unsafe) self] e in self.reportException(e) }
        loop.reportTermination = { [unowned(unsafe) self] why in self.reportTermination(why) }
        realm.printHandler = { [unowned(unsafe) self] s in self.write(1, s + "\n") }
        jsInstallConsole(realm, now: { Double(Time.now) }) { [unowned(unsafe) self] level, text in
            self.write(level == .warn || level == .error ? 2 : 1, text + "\n")
        }
        loop.reportRejection = { [unowned(unsafe) self] text in self.write(2, text + "\n"); self.failed = true }
        realm.moduleLoader = { (realm: JSRealm, specifier: String, referrer: String) -> JSModuleLoadResult in
            jsShellLoadModule(specifier, referrer)
        }
        installPerformance()
    }

    func wallMs() -> Double { epochBaseMs + Double(Time.now - bootBase) }

    func installPerformance() {
        let heap = realm.heap
        let perf = heap.newObject(proto: realm.objectPrototype, kind: .ordinary, flags: [.extensible])
        realm.defineGlobal("performance", perf)
        let origin = Time.now
        realm.defineMethod(perf, "now", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            .number(Double(Time.now - origin))
        }
    }

    // MARK: Output

    func write(_ fd: Int, _ s: String) {
        if fd == 2 { flush() }
        if fd == 1 {
            out.append(contentsOf: Array(s.utf8))
            if out.count > 8192 { flush() }
        } else {
            File.stderr.writeAll(Array(s.utf8))
        }
    }

    func flush() {
        if !out.isEmpty {
            File.stdout.writeAll(out)
            out.removeAll(keepingCapacity: true)
        }
    }

    // MARK: Budget

    func beginTask() {
        timedOut = false
        interrupted = false
        deadline = Time.now + budgetMs
        lastPoll = Time.now
    }

    func shouldInterrupt() -> Bool {
        let now = Time.now
        if budgetMs > 0 && now >= deadline { timedOut = true; return true }
        if watchInterrupt && now - lastPoll >= 50 {
            lastPoll = now
            if pollCtrlC() { interrupted = true; return true }
        }
        return false
    }

    /// Non-blocking look at the terminal: Ctrl-C (0x03) interrupts, anything
    /// else is kept as typeahead for the next prompt.
    func pollCtrlC() -> Bool {
        var fds = [WaitFD(fd: 0, events: WaitEvent.readable, revents: 0)]
        var found = false
        var guardN = 0
        while guardN < 16 && wait(&fds, timeoutMs: 0) > 0 && fds[0].revents & WaitEvent.readable != 0 {
            guardN += 1
            fds[0].revents = 0
            guard let chunk = try? File.stdin.read(max: 64), !chunk.isEmpty else { break }
            for b in chunk {
                if b == 0x03 { found = true } else if typeahead.count < 4096 { typeahead.append(b) }
            }
        }
        return found
    }

    // MARK: Reporting

    func reportException(_ e: JSUncaughtException) {
        let text = e.stack.isEmpty ? e.message : e.stack
        write(2, "Uncaught " + text + "\n")
        failed = true
    }

    func reportTermination(_ why: JSTerminationReason) {
        flush()
        switch why {
        case .interrupted:
            if interrupted { write(2, "script terminated: interrupted (Ctrl-C)\n") }
            else { write(2, "script terminated: time budget exceeded (\(budgetMs) ms)\n") }
        case .heapLimit: write(2, "script terminated: heap limit exceeded (\(heapMiB) MiB)\n")
        case .regexSteps: write(2, "script terminated: regular expression too slow\n")
        }
        failed = true
        terminated = true
        loop.clearAll()
    }

    /// Run source as a classic script, with the budget.
    @discardableResult
    func run(_ source: [UInt8], name: String) -> JSCompletion {
        beginTask()
        let c = realm.evaluate(source: source, name: name)
        switch c {
        case .normal: break
        case .exception(let e): reportException(e)
        case .terminated(let why): reportTermination(why)
        }
        return c
    }
}

// MARK: Modules

/// `spec` resolved against the directory of `referrer`, with . and .. folded.
func jsShellResolve(_ spec: String, _ referrer: String) -> String {
    var path = spec
    if !spec.hasPrefix("/") {
        var dir = referrer
        if let slash = dir.lastIndex(of: "/") { dir = String(dir[dir.startIndex...slash]) } else { dir = "" }
        path = dir + spec
    }
    var parts: [String] = []
    var cur = ""
    func flush() {
        if cur == ".." { if !parts.isEmpty { parts.removeLast() } }
        else if cur != "." && !cur.isEmpty { parts.append(cur) }
        cur = ""
    }
    for c in path { if c == "/" { flush() } else { cur.append(c) } }
    flush()
    var out = ""
    for p in parts { out += "/" + p }
    if !path.hasPrefix("/") && !referrer.hasPrefix("/") {
        // Relative to the working directory: keep it relative.
        out = String(out.dropFirst())
    }
    return out
}

func jsShellLoadModule(_ spec: String, _ referrer: String) -> JSModuleLoadResult {
    let url = jsShellResolve(spec, referrer)
    do throws(SysError) {
        let f = try File.open(url)
        let bytes = try f.readAll()
        f.close()
        return .source(url: url, bytes: bytes)
    } catch {
        return .error("cannot load module '" + url + "': " + error.message)
    }
}

extension JSShell {
    /// Run `source` as the root module and wait for its promise (top-level
    /// await included) through the event loop.
    func runModule(_ source: [UInt8], name: String) {
        beginTask()
        switch realm.evaluateModule(source: source, name: name) {
        case .exception(let e): reportException(e)
        case .terminated(let why): reportTermination(why)
        case .normal(let p):
            let depth = realm.heap.rootDepth
            let root = realm.heap.root(p)
            loop.performMicrotaskCheckpoint()
            if realm.promiseState(realm.heap[root]) == .rejected {
                failed = true
            }
            realm.heap.popRoots(to: depth)
        }
    }
}
