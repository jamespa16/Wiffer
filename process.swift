// Phase 6C2: processes.
//
// A Process is a Task (its thread, `.any` affinity) plus an AddressSpace,
// its memory regions, an output and an exit status. Single-threaded.
//
// - The process table (`processTable`, `nextPID`) is CPU 0 data: it is
//   touched only on CPU 0, through onCPU0 from anywhere else.
// - Life cycle: spawnProcess loads the ELF and builds the stack (on the
//   caller's CPU, into an address space nobody runs yet), registers the
//   process and spawns its thread, whose body (processMain) runs user_run.
//   user_run returns when the process leaves (exit, fault, kill), and
//   processLeave frees the address space, delivers any report, and makes
//   the process a zombie on CPU 0.
// - Parents. `parent` is a pid (0: the kernel). Kernel code that spawns a
//   process and will wait for it (the shell, selftests) names itself the
//   `waiter` task: it is unparked when the process exits, and it reaps the
//   zombie (waitProcess). A zombie with parent 0 and no waiter is reaped at
//   once; a process's children are reparented to 0 when it exits (and
//   reaped if already zombies). 6E adds waitpid for processes.
// - Console and fds (6E): fds 0-2 are a ConsoleFile over the ConsoleChannel
//   the waiting shell pumps (see fileobject.swift and waitProcesses); a
//   process with no channel (a background job) logs to the kernel log.
//   processLeave closes every fd. A process spawned by another (the spawn
//   syscall) has its parent's thread as waiter and is reaped by waitpid.
// - kill sets killRequested and kicks the thread: unparks it if it's
//   blocked, or IPIs the CPU it runs on, so the next return to ring 3
//   leaves instead (userLeavePoint). A process spinning in ring 3 on CPU 0
//   has to wait for 6D's preemption.
// - No reference cycles: the thread and the process point at each other
//   until processLeave breaks both links; parents and children are pids.

enum ExitStatus: Equatable {
    case exited(Int)
    /// Killed by an exception from ring 3 (the vector).
    case faulted(UInt64)
    case killed
}

enum ProcessState: Equatable { case running, zombie }

/// All ConsoleChannel buffers (a short critical section: append or take).
var outputLock = SpinLock()

final class Process {
    let pid: Int
    /// Parent pid; 0 = the kernel. CPU 0.
    var parent: Int
    let name: String
    /// Child pids. CPU 0.
    var children: [Int] = []
    var state = ProcessState.running
    /// Set once, when it starts to leave.
    var status: ExitStatus?
    var space: AddressSpace?
    var regions: [MemoryRegion] = []
    /// Its thread, until it leaves.
    var thread: Task?
    /// The console of the command line it belongs to (6E): its fds 0-2 by
    /// default, and where a fault report goes. Nil: the kernel log.
    var output: ConsoleChannel?
    /// 6E1: open files, and the working directory (absolute).
    var fds = FdTable()
    var cwd = "/"
    /// Kernel task to unpark at exit (it will reap).
    var waiter: Task?
    var killRequested = false
    /// A fault's one-line report.
    var report: String?
    /// The last bytes passed to debug_write (selftests).
    var debugBytes: [UInt8] = []
    var entry: UInt64 = 0
    var initialStack: UInt64 = 0
    /// Frames it had mapped, and the CPU it was on, when it left (tests).
    var exitFrames = 0
    var exitCPU = -1

    init(pid: Int, parent: Int, name: String) {
        self.pid = pid
        self.parent = parent
        self.name = name
    }

    /// Record how it ends (the first reason wins) and leave at the next
    /// return to the stub.
    func exit(_ s: ExitStatus) {
        if status == nil { status = s }
    }

    func noteDebug(_ bytes: [UInt8]) {
        debugBytes.append(contentsOf: bytes)
        if debugBytes.count > 256 { debugBytes.removeFirst(debugBytes.count - 256) }
    }

    // MARK: Regions (6C3)

    func region(containing addr: UInt) -> Int? {
        regions.firstIndex { addr >= $0.start && addr < $0.end }
    }

    func rangeIsFree(_ start: UInt, _ end: UInt) -> Bool {
        !regions.contains { $0.start < end && start < $0.end }
    }

    /// A page fault on an absent page: allocate it if a region covers it
    /// and allows the access (bit 1 of the error code: write, bit 4: fetch).
    func demandFault(_ addr: UInt, errorCode: UInt64) -> Bool {
        guard let space, let i = region(containing: addr) else { return false }
        let prot = regions[i].prot
        if errorCode & 2 != 0 && prot & MapProt.write == 0 { return false }
        if errorCode & 16 != 0 && prot & MapProt.exec == 0 { return false }
        let page = addr & ~(pageSize - 1)
        if space.translate(page) != nil { return false } // present: a protection fault
        return mapZeroed(space, page, pages: 1, flags: regions[i].flags)
    }

    /// map(hint, len, prot): a new anonymous region, lazily allocated.
    func mapAnonymous(hint: UInt, length: UInt64, prot: UInt64) -> Int {
        guard length > 0, length <= 1 << 40, prot & ~(MapProt.read | MapProt.write | MapProt.exec) == 0,
              prot & (MapProt.write | MapProt.exec) != MapProt.write | MapProt.exec else { return fail(Errno.EINVAL) }
        guard regions.count < 65536 else { return fail(Errno.ENOMEM) }
        let len = (UInt(length) + pageSize - 1) & ~(pageSize - 1)
        var start: UInt = 0
        if hint != 0 && hint % pageSize == 0 && isUserRange(hint, len) && rangeIsFree(hint, hint + len) {
            start = hint
        } else {
            // First fit from mapBase, over the regions in address order.
            var at = UInt(UserLayout.mapBase)
            let sorted = regions.sorted { $0.start < $1.start }
            for r in sorted where r.end > at {
                if r.start >= at + len { break }
                at = max(at, r.end)
            }
            guard isUserRange(at, len), at + len <= UInt(UserLayout.stackTop - UserLayout.stackSize) - pageSize else {
                return fail(Errno.ENOMEM)
            }
            start = at
        }
        regions.append(MemoryRegion(start: start, end: start + len, prot: prot | MapProt.read))
        return Int(start)
    }

    /// Split regions so that `addr` is a boundary.
    func splitRegions(at addr: UInt) {
        guard let i = region(containing: addr), regions[i].start != addr else { return }
        var tail = regions[i]
        tail.start = addr
        regions[i].end = addr
        regions.append(tail)
    }

    /// unmap(addr, len): drop the regions (and pages) in the range.
    func unmapRange(_ addr: UInt, _ length: UInt64) -> Int {
        guard addr % pageSize == 0, length > 0, length <= 1 << 46 else { return fail(Errno.EINVAL) }
        let end = addr + ((UInt(length) + pageSize - 1) & ~(pageSize - 1))
        guard isUserRange(addr, end - addr), let space else { return fail(Errno.EINVAL) }
        splitRegions(at: addr)
        splitRegions(at: end)
        regions.removeAll { $0.start >= addr && $0.end <= end }
        space.unmap(addr, count: Int((end - addr) / pageSize))
        return 0
    }

    /// protect(addr, len, prot): every page in the range must be in a region.
    func protectRange(_ addr: UInt, _ length: UInt64, prot: UInt64) -> Int {
        guard addr % pageSize == 0, length > 0, length <= 1 << 46,
              prot & ~(MapProt.read | MapProt.write | MapProt.exec) == 0,
              prot & (MapProt.write | MapProt.exec) != MapProt.write | MapProt.exec else { return fail(Errno.EINVAL) }
        let end = addr + ((UInt(length) + pageSize - 1) & ~(pageSize - 1))
        guard isUserRange(addr, end - addr), let space else { return fail(Errno.EINVAL) }
        var at = addr
        let sorted = regions.sorted { $0.start < $1.start }
        for r in sorted where r.end > at && r.start <= at { at = r.end; if at >= end { break } }
        guard at >= end else { return fail(Errno.ENOMEM) }
        splitRegions(at: addr)
        splitRegions(at: end)
        for i in regions.indices where regions[i].start >= addr && regions[i].end <= end {
            regions[i].prot = prot | MapProt.read
            space.protect(regions[i].start, count: Int((regions[i].end - regions[i].start) / pageSize),
                          flags: regions[i].flags)
        }
        return 0
    }
}

// MARK: The process table (CPU 0)

var processTable: [Process] = []
var nextPID = 1
/// Processes created and reaped so far.
var processesSpawned = 0
var processesReaped = 0

func findProcess(_ pid: Int) -> Process? { processTable.first { $0.pid == pid } }

/// Remove a zombie from the table. CPU 0.
func reap(_ p: Process) {
    if let i = processTable.firstIndex(where: { $0 === p }) {
        processTable.remove(at: i)
        processesReaped += 1
    }
    if let parent = findProcess(p.parent), let i = parent.children.firstIndex(of: p.pid) {
        parent.children.remove(at: i)
    }
}

/// Print a whole string (no newline added) to the kernel log. CPU 0.
func printRaw(_ text: String) {
    stdoutLock.acquire()
    for b in text.utf8 {
        if b == 0x0A { putc(0x0D) }
        putc(b)
    }
    stdoutLock.release()
}

// MARK: Spawning

/// Start `path` (resolved against `cwd`, from the VFS: rootfs or /disk)
/// with `argv` (argv[0] included). The process is running when this
/// returns. `waiter` (usually the caller) will reap it.
func spawnProcess(path: String, cwd: String = "/", argv: [String], output: ConsoleChannel?, waiter: Task?,
                  affinity: Affinity = .any, stdio: [FileObject?]? = nil) throws(ExecError) -> Process {
    guard let file = onCPU0({ () -> [UInt8]? in try? vfs.read(path, cwd: cwd) }) else { throw .notFound }
    guard let space = AddressSpace() else { throw .noMemory }
    let image = try loadELF(file, into: space)
    let sp = try buildInitialStack(space, argv: argv, image: image)
    let name = String(FileSystem.components(path, cwd: cwd).last ?? path)
    return try startProcess(name: name, space: space, regions: image.regions, entry: image.entry, stack: sp,
                            output: output, waiter: waiter, affinity: affinity, cwd: FileSystem.normalize(cwd),
                            stdio: stdio)
}

/// Selftests (6B): run `code` (a few hand-assembled bytes) at
/// UserLayout.imageBase (read + exec), with `data` at imageBase + 4 KiB
/// (read + write) and a normal stack.
func spawnBlob(_ name: String, code: [UInt8], data: [UInt8] = [], output: ConsoleChannel?, waiter: Task?,
               affinity: Affinity = .any) throws(ExecError) -> Process {
    guard let space = AddressSpace() else { throw .noMemory }
    let base = UInt(UserLayout.imageBase)
    let rx = MapProt.read | MapProt.exec, rw = MapProt.read | MapProt.write
    guard code.count <= frameSize, data.count <= frameSize,
          mapZeroed(space, base, pages: 1, flags: regionFlags(rx)),
          mapZeroed(space, base + pageSize, pages: 1, flags: regionFlags(rw)),
          code.withUnsafeBytes({ space.write(base, $0) }), data.withUnsafeBytes({ space.write(base + pageSize, $0) })
    else { throw .noMemory }
    var image = LoadedImage()
    image.entry = UInt64(base)
    image.regions = [MemoryRegion(start: base, end: base + pageSize, prot: rx),
                     MemoryRegion(start: base + pageSize, end: base + 2 * pageSize, prot: rw)]
    let sp = try buildInitialStack(space, argv: [name], image: image)
    return try startProcess(name: name, space: space, regions: image.regions, entry: image.entry, stack: sp,
                            output: output, waiter: waiter, affinity: affinity)
}

func startProcess(name: String, space: AddressSpace, regions: [MemoryRegion], entry: UInt64, stack: UInt64,
                  output: ConsoleChannel?, waiter: Task?, affinity: Affinity, cwd: String = "/",
                  stdio: [FileObject?]? = nil) throws(ExecError) -> Process {
    let stackRegion = MemoryRegion(start: UInt(UserLayout.stackTop - UserLayout.stackSize),
                                   end: UInt(UserLayout.stackTop), prot: MapProt.read | MapProt.write)
    let parentPID = currentProcess()?.pid ?? 0
    let p = onCPU0 { () -> Process in
        let p = Process(pid: nextPID, parent: parentPID, name: name)
        nextPID += 1
        processTable.append(p)
        processesSpawned += 1
        findProcess(parentPID)?.children.append(p.pid)
        return p
    }
    p.space = space
    p.regions = regions + [stackRegion]
    p.entry = entry
    p.initialStack = stack
    p.output = output
    p.waiter = waiter
    p.cwd = cwd
    // fds 0-2: the given objects, else the console (EOF in, log out if it
    // has no pump), else the kernel-log console.
    if let stdio {
        for (i, o) in stdio.enumerated() { if let o { _ = p.fds.set(i, o) } }
    } else {
        let console = ConsoleFile(output ?? ConsoleChannel(reader: nil))
        for i in 0..<3 { _ = p.fds.set(i, console) }
    }
    let thread = spawn(name, affinity: affinity, setup: { t in
        t.process = p
        p.thread = t
    }, { processMain() })
    guard thread != nil else {
        p.fds.closeAll()
        p.space = nil
        onCPU0 { p.state = .zombie; reap(p) }
        throw .noMemory
    }
    return p
}

/// The thread's body. Non-capturing, and no references live across
/// user_run (processEnter and processLeave hold them).
@inline(never)
func processMain() {
    let (rip, rsp, slot) = processEnter()
    guard let slot else { return }
    user_run(rip, rsp, slot)
    processLeave()
}

@inline(never)
func processEnter() -> (UInt64, UInt64, UnsafeMutablePointer<UInt64>?) {
    guard let me = scheduler.current, let p = me.process, let space = p.space, p.status == nil,
          !p.killRequested else {
        return (0, 0, nil)
    }
    me.cr3 = space.root
    space.activate()
    return (p.entry, p.initialStack, me.userEntry)
}

/// After user_run returned (or the process never started): tear down,
/// report, become a zombie (CPU 0) and wake the waiter.
@inline(never)
func processLeave() {
    guard let me = scheduler.current, let p = me.process else { return }
    me.userEntry.pointee = 0
    me.cr3 = 0
    enterKernelAddressSpace()
    if p.status == nil { p.status = .killed }
    if p.status == .killed && p.report == nil { p.report = "pid \(p.pid) (\(p.name)): killed" }
    p.exitFrames = p.space?.ownedFrames ?? 0
    p.exitCPU = currentCPU()
    p.regions = []
    p.space = nil // frees its page tables and frames
    p.fds.closeAll() // pipes see their end go; written files reach the disk
    if let r = p.report {
        if let out = p.output {
            out.write(Array((r + "\n").utf8)) { false }
        } else {
            onCPU0 { print(r) }
        }
    }
    onCPU0 {
        p.state = .zombie
        for c in p.children {
            guard let child = findProcess(c) else { continue }
            child.parent = 0
            if child.waiter === me { child.waiter = nil } // this process was its waiter (waitpid)
            if child.state == .zombie && child.waiter == nil { reap(child) }
        }
        p.children = []
        if let w = p.waiter {
            unpark(w)
        } else if findProcess(p.parent) == nil {
            reap(p)
        }
    }
    p.thread = nil
    me.process = nil
}

// MARK: Waiting and killing

/// Block until every process of a command line has exited, then reap them
/// (the caller must be their waiter, on CPU 0). This is the console's pump:
/// on every wakeup it copies the console's output to `sink`, feeds the keys
/// `keys()` returns (and whether the window closed) to the console's line
/// discipline, echoing through `sink`, and kills the processes on Ctrl-C
/// or a close. The console is detached at the end.
func waitProcesses(_ procs: [Process], console: ConsoleChannel?, sink: ([UInt8]) -> Void = { _ in },
                   keys: () -> (keys: [KeyEvent], closed: Bool) = { ([], false) }) -> [ExitStatus] {
    while true {
        var done = true
        for p in procs where p.state != .zombie { done = false } // before the last take: nothing comes after
        if let console {
            let bytes = console.take()
            if !bytes.isEmpty { sink(bytes) }
        }
        if done { break }
        let (typed, closed) = keys()
        var interrupt = closed
        for k in typed {
            guard let console else { break }
            let r = console.feed(k)
            if !r.echo.isEmpty { sink(r.echo) }
            if r.interrupt { interrupt = true }
        }
        if interrupt { for p in procs { killProcess(p.pid) } }
        park()
    }
    var out: [ExitStatus] = []
    for p in procs {
        reap(p)
        p.waiter = nil
        p.output = nil
        out.append(p.status ?? .killed)
    }
    console?.detach()
    return out
}

/// One process, with `interrupt` polled on every wakeup (true kills it).
func waitProcess(_ p: Process, sink: ([UInt8]) -> Void = { _ in }, interrupt: () -> Bool = { false }) -> ExitStatus {
    let statuses = waitProcesses([p], console: p.output, sink: sink, keys: { ([], interrupt()) })
    return statuses[0]
}

/// Ask a process to exit. False if there's no such running process. CPU 0.
@discardableResult
func killProcess(_ pid: Int) -> Bool {
    guard let p = findProcess(pid), p.state == .running else { return false }
    p.killRequested = true
    if let t = p.thread { kick(t) }
    return true
}

/// Make `task` notice a kill soon: unpark it if blocked, IPI its CPU if
/// it's running elsewhere (the interrupt's return to ring 3 checks).
func kick(_ task: Task) {
    let flags = schedLock.acquireIRQ()
    let running = task.state == .running
    let cpu = task.lastCPU
    schedLock.releaseIRQ(flags)
    if running {
        if cpu >= 0 && cpu != currentCPU() && x2apicEnabled {
            sendIPI(apicID: UInt32(perCPUEntry(cpu).pointee.apicID), vector: Vector.reschedule)
        }
    } else {
        unpark(task)
    }
}

// MARK: ps

func psLines() -> [String] {
    var lines = ["  pid  ppid  state    cpu  name"]
    let rows = schedLock.withIRQsOff { () -> [(Process, Int)] in
        processTable.map { ($0, $0.thread?.lastCPU ?? -1) }
    }
    for (p, cpu) in rows {
        let state = p.state == .zombie ? "zombie" : (p.killRequested ? "killing" : "running")
        lines.append(pad("\(p.pid)", 5, left: true) + pad("\(p.parent)", 6, left: true) + "  " + pad(state, 7)
                     + pad(cpu >= 0 ? "\(cpu)" : "-", 5, left: true) + "  " + p.name)
    }
    return lines
}

/// One line for a finished process, or nil when there's nothing to say.
func exitSummary(_ name: String, _ status: ExitStatus) -> String? {
    switch status {
    case .exited(0): return nil
    case .exited(let code): return "\(name): exit status \(code)"
    case .faulted, .killed: return nil // the report already said
    }
}
