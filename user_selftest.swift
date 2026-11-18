// Phase 6B and 6C selftests: ring 3 with hand-assembled blobs (no ELF),
// then ELF programs from /bin, memory syscalls, and spawn/exit leaks.
// They run in the selftest task (CPU 0), which waits for each process.

/// Little-endian bytes of a 32- or 64-bit immediate.
func imm32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) } }
func imm64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * UInt64($0))) } }

/// mov eax, n; syscall.
func blobSyscall(_ n: UInt64) -> [UInt8] { [0xB8] + imm32(UInt32(n)) + [0x0F, 0x05] }
/// mov rdi, rax; exit(rdi).
let blobExitRAX: [UInt8] = [0x48, 0x89, 0xC7] + blobSyscall(SyscallNumber.exit) + [0x0F, 0x0B]

struct BlobRun {
    var status: ExitStatus = .killed
    var output = ""
    var debug: [UInt8] = []
    var pid = 0
    var cpu = -1
}

/// Run a process to the end (as its waiter), collecting its output. While
/// it runs, `during` is called once per timer tick (e.g. to send IPIs).
func runToExit(_ p: Process, during: (() -> Void)? = nil) -> BlobRun {
    var r = BlobRun()
    r.pid = p.pid
    if let during {
        var last = ticks
        while p.state != .zombie {
            if ticks != last { last = ticks; during() }
            yield()
            cpu_pause()
        }
    }
    var bytes: [UInt8] = []
    r.status = waitProcess(p, sink: { bytes += $0 })
    r.output = String(decoding: bytes, as: UTF8.self)
    r.debug = p.debugBytes
    r.cpu = p.exitCPU
    return r
}

func runBlob(_ name: String, _ code: [UInt8], data: [UInt8] = [], cpu: Int? = nil,
             during: (() -> Void)? = nil) -> BlobRun {
    guard let me = scheduler.current else { return BlobRun() }
    let affinity: Affinity = cpu.map { .cpu($0) } ?? .any
    do throws(ExecError) {
        let p = try spawnBlob(name, code: code, data: data, output: ProcessOutput(reader: me), waiter: me,
                              affinity: affinity)
        return runToExit(p, during: during)
    } catch {
        print("  blob \(name): \(error.message)")
        return BlobRun()
    }
}

func runProgramForTest(_ argv: [String]) -> BlobRun {
    guard let me = scheduler.current, let name = argv.first else { return BlobRun() }
    do throws(ExecError) {
        let p = try spawnProcess(path: "/bin/" + name, argv: argv, output: ProcessOutput(reader: me), waiter: me)
        return runToExit(p)
    } catch {
        print("  \(name): \(error.message)")
        return BlobRun()
    }
}

/// Does this CPU have balanced GS state (GS_BASE = its PerCPU entry,
/// KERNEL_GS_BASE = the user value 0)? Checked by a task pinned there.
func gsBalanced(on cpu: Int) -> Bool {
    var result: UInt64 = 2
    let slot = withUnsafeMutablePointer(to: &result) { $0 }
    let freedBefore = withUnsafeMutablePointer(to: &tasksFreed) { atomic_load64($0) }
    guard spawn("gscheck", affinity: .cpu(cpu), {
        let ok = rdmsr(msrGSBase) == perCPUAddress(cpu) && rdmsr(msrKernelGSBase) == 0
        atomic_store64(slot, ok ? 1 : 0)
    }) != nil else { return false }
    var spins = 0
    while atomic_load64(slot) == 2 && spins < 100_000 { yield(); cpu_pause(); spins += 1 }
    while withUnsafeMutablePointer(to: &tasksFreed, { atomic_load64($0) }) == freedBefore && spins < 200_000 {
        yield(); spins += 1
    }
    return atomic_load64(slot) == 1
}

let base = UInt64(UserLayout.imageBase)

/// `text` contains `sub` (bytes; Embedded Swift has no substring search).
func has(_ text: String, _ sub: String) -> Bool {
    let a = Array(text.utf8), b = Array(sub.utf8)
    guard !b.isEmpty else { return true }
    guard a.count >= b.count else { return false }
    for i in 0...(a.count - b.count) where a[i] == b[0] && Array(a[i..<(i + b.count)]) == b { return true }
    return false
}

func ringThreeTests(_ t: inout SelfTest) {
    t.check("6B: PerCPU offsets match cpu.S", perCPUOffsetsOK())
    t.check("6B: EFER.SCE, LSTAR, STAR set", rdmsr(msrEFER) & 1 == 1 && rdmsr(msrLSTAR) == syscall_entry_address
            && rdmsr(msrSTAR) >> 32 == 0x0010_0008)
    t.check("6B: #BP gate is DPL3, others DPL0", (idt[3 * 2] >> 45) & 3 == 3 && (idt[13 * 2] >> 45) & 3 == 0)
    // exit(42). (Run once first so the tables' arrays have grown.)
    let exit42 = [0xBF] + imm32(42) + blobSyscall(SyscallNumber.exit) + [0x0F, 0x0B]
    _ = runBlob("exit42", exit42)
    let frames0 = pmm.freeFrames, splits0 = splitPages
    let heap0 = HeapUsage()
    let r1 = runBlob("exit42", exit42)
    t.check("6B: exit(42) from ring 3", r1.status == .exited(42))

    // debug_write("hello, ring3") from the data page, then exit(result).
    let message = Array("hello, ring3".utf8)
    let leaRDI: [UInt8] = [0x48, 0x8D, 0x3D] + imm32(0x1000 - 7) // lea rdi, [rip + data]
    let dbg = leaRDI + [0xBE] + imm32(UInt32(message.count)) + blobSyscall(SyscallNumber.debugWrite) + blobExitRAX
    puts("  (debug_write: ")
    let r2 = runBlob("debug", dbg, data: message)
    puts(")\n")
    t.check("6B: debug_write prints and returns its length", r2.status == .exited(message.count) && r2.debug == message)

    // A kernel pointer to debug_write: -EFAULT, not a crash.
    let bad = [0x48, 0xBF] + imm64(0xFFFF_FFFF_8000_0000) + [0xBE] + imm32(8)
        + blobSyscall(SyscallNumber.debugWrite) + blobExitRAX
    t.check("6B: copyIn rejects a kernel address (-EFAULT)", runBlob("efault", bad).status == .exited(-Errno.EFAULT))
    let unmapped = [0x48, 0xBF] + imm64(base + 0x10_0000) + [0xBE] + imm32(8)
        + blobSyscall(SyscallNumber.debugWrite) + blobExitRAX
    t.check("6B: copyIn rejects unmapped user memory", runBlob("efault2", unmapped).status == .exited(-Errno.EFAULT))
    t.check("6B: unknown syscall is -ENOSYS", runBlob("nosys", blobSyscall(77) + blobExitRAX).status
            == .exited(-Errno.ENOSYS))

    // Faults: killed with a report, never a panic.
    let readKernel = [0x48, 0xB8] + imm64(0xFFFF_FFFF_8000_0000) + [0x48, 0x8B, 0x00] + blobExitRAX
    let rk = runBlob("rdkernel", readKernel)
    t.check("6B: reading kernel memory is a page fault", rk.status == .faulted(14)
            && has(rk.output, "(rdkernel): page fault at 0xffff_ffff_8000_0000, rip 0x100_0000_000a"))
    let execData = [0x48, 0xB8] + imm64(base + 0x1000) + [0xFF, 0xE0]
    let rx = runBlob("execdata", execData, data: [0xC3])
    t.check("6B: executing a data page is a page fault (NX)", rx.status == .faulted(14)
            && has(rx.output, "page fault at 0x100_0000_1000, rip 0x100_0000_1000"))
    let rh = runBlob("hlt", [0xF4])
    t.check("6B: hlt in ring 3 is #GP", rh.status == .faulted(13) && has(rh.output, "(hlt): general protection fault"))
    t.check("6B: cli in ring 3 is #GP", runBlob("cli", [0xFA]).status == .faulted(13))
    t.check("6B: in in ring 3 is #GP", runBlob("in", [0xE4, 0x60]).status == .faulted(13))
    t.check("6B: out in ring 3 is #GP", runBlob("out", [0xE6, 0x80]).status == .faulted(13))
    let ru = runBlob("ud", [0x0F, 0x0B])
    t.check("6B: ud2 is #UD", ru.status == .faulted(6) && has(ru.output, "invalid opcode, rip 0x100_0000_0000"))
    t.check("6B: int3 is #BP", runBlob("bp", [0xCC]).status == .faulted(3))
    t.check("6B: div by zero is #DE", runBlob("de", [0x31, 0xC9, 0xF7, 0xF1]).status == .faulted(0))

    // A busy loop sees interrupts come and go (swapgs balanced): PIT ticks
    // on CPU 0, ping IPIs on the APs. rax = sum of 1 + 3k, k < n.
    let n: UInt32 = 40_000_000
    let loop: [UInt8] = [0xB9] + imm32(n) + [0x31, 0xC0, 0xBB] + imm32(1)
        + [0x48, 0x01, 0xD8, 0x48, 0x83, 0xC3, 0x03, 0x48, 0xFF, 0xC9, 0x75, 0xF4] + blobExitRAX
    let want = Int(n) + 3 * Int(n) * (Int(n) - 1) / 2
    let cpus = max(smpStarted, 1)
    var allExit = true, allIRQs = true, allGS = true, allSyscallIRQs = true, ranThere = true
    // testWaitIRQs(3, 100): halts in a syscall until 3 interrupts arrive.
    let waitIRQ: [UInt8] = [0xBF] + imm32(3) + [0xBE] + imm32(100) + blobSyscall(SyscallNumber.testWaitIRQs) + blobExitRAX
    for cpu in 0..<cpus where perCPUEntry(cpu).pointee.online {
        let e = perCPUEntry(cpu)
        let ping = {
            if cpu != 0 { sendIPI(apicID: UInt32(e.pointee.apicID), vector: Vector.ping) }
        }
        let u0 = e.pointee.userInterrupts
        let r = runBlob("loop", loop, cpu: cpu, during: ping)
        if r.status != .exited(want) { allExit = false; print("  cpu \(cpu): loop \(r.status)") }
        if e.pointee.userInterrupts == u0 { allIRQs = false; print("  cpu \(cpu): no interrupts in ring 3") }
        if r.cpu != cpu { ranThere = false; print("  cpu \(cpu): ran on \(r.cpu)") }
        let w = runBlob("irqwait", waitIRQ, cpu: cpu, during: ping)
        if case .exited(let seen) = w.status, seen >= 3 {} else { allSyscallIRQs = false; print("  cpu \(cpu): irqwait \(w.status)") }
        if !gsBalanced(on: cpu) { allGS = false; print("  cpu \(cpu): GS not balanced") }
    }
    t.check("6B: the same busy loop exits right on every CPU", allExit && ranThere)
    t.check("6B: interrupts land in ring 3 on every CPU", allIRQs)
    t.check("6B: interrupts nest in a syscall on every CPU", allSyscallIRQs)
    t.check("6B: GS_BASE / KERNEL_GS_BASE balanced on every CPU", allGS)

    // exit and debug_write on every CPU.
    var everyCPU = true
    for cpu in 0..<cpus where perCPUEntry(cpu).pointee.online {
        let r = runBlob("debug", dbg, data: message, cpu: cpu)
        if r.status != .exited(message.count) || r.debug != message { everyCPU = false }
    }
    t.check("6B: debug_write + exit on every CPU", everyCPU)

    // yield() in a loop: the thread leaves and resumes inside syscalls.
    let yields: [UInt8] = [0xB9] + imm32(50) + [0x51] + blobSyscall(SyscallNumber.yield) + [0x59, 0x48, 0xFF, 0xC9, 0x75, 0xF3]
        + [0xBF] + imm32(7) + blobSyscall(SyscallNumber.exit)
    t.check("6B: yield syscalls", runBlob("yields", yields).status == .exited(7))

    t.check("6B: no frames leaked by user blobs", pmm.freeFrames == frames0 - (splitPages - splits0))
    t.check("6B: no heap leaked by user blobs", HeapUsage() == heap0 || heapWithin(heap0))
}

/// The heap after a test may hold the same live blocks plus capacity that
/// arrays kept (scheduler queues): allow a few blocks of slack, no bytes.
func heapWithin(_ before: HeapUsage) -> Bool {
    let now = HeapUsage()
    if now != before { print("  heap: \(before.bytes) bytes / \(before.blocks) blocks -> \(now.bytes) / \(now.blocks)") }
    return now.blocks == before.blocks && now.largeFrames == before.largeFrames
}

func processTests(_ t: inout SelfTest) {
    guard (try? vfs.lookup("/bin/hello")) != nil else {
        t.check("6C: /bin/hello in the rootfs", false)
        return
    }
    let hello = runProgramForTest(["hello"])
    t.check("6C: hello prints from ring 3", hello.status == .exited(0) && hello.output == "Hello from ring 3!\n")
    let args = runProgramForTest(["args", "one", "two words"])
    t.check("6C: args sees argc and argv", args.output == "argc=3\nargv[0]=args\nargv[1]=one\nargv[2]=two words\n")
    let alloc = runProgramForTest(["alloc"])
    t.check("6C: alloc: Array, String, Dictionary in ring 3", alloc.status == .exited(0)
            && alloc.output == "alloc: checksum 67415360436\n")

    let kinds: [(String, ExitStatus, String)] = [
        ("null", .faulted(14), "page fault at 0x8,"), ("write", .faulted(14), "page fault at 0x100_0000_"),
        ("exec", .faulted(14), "page fault at 0x4000_"), ("kernel", .faulted(14), "page fault at 0xffff_ffff_8000_0000"),
        ("ident", .faulted(14), "page fault at 0x10_0000"), ("ud", .faulted(6), "invalid opcode"),
        ("trap", .faulted(6), "invalid opcode"), ("de", .faulted(0), "divide error"), ("bp", .faulted(3), "breakpoint"),
        ("hlt", .faulted(13), "general protection"), ("cli", .faulted(13), "general protection"),
        ("io", .faulted(13), "general protection"), ("stack", .faulted(14), "page fault at 0x7f7f_ffef_f"),
        ("exit", .exited(3), ""),
    ]
    var allReported = true
    for (kind, status, text) in kinds {
        let r = runProgramForTest(["crash", kind])
        let ok = r.status == status && has(r.output, text) && has(r.output, "(crash): ") == (status != .exited(3))
        if !ok { allReported = false; print("  crash \(kind): \(r.status) '\(r.output)'") }
    }
    t.check("6C: every crash kind is reported", allReported)

    // map, demand faults, protect, then a write to the read-only page.
    let mapProtect: [UInt8] = [0xBF] + imm32(0) + [0xBE] + imm32(0x2000) + [0xBA] + imm32(3) + blobSyscall(SyscallNumber.map)
        + [0x48, 0x89, 0xC3, 0x48, 0xC7, 0x03, 0x55, 0, 0, 0, 0x48, 0xC7, 0x83] + imm32(0x1000) + imm32(0x66)
        + [0x48, 0x89, 0xDF, 0xBE] + imm32(0x1000) + [0xBA] + imm32(1) + blobSyscall(SyscallNumber.protect)
        + [0x48, 0x8B, 0x03, 0x48, 0x89, 0x03] + blobExitRAX
    let mp = runBlob("mapprot", mapProtect)
    t.check("6C: map, demand fault, protect, then a write faults", mp.status == .faulted(14)
            && has(mp.output, "page fault at 0x4000_0000_0000,"))
    // W+X refused; unmap then touch faults.
    let wx: [UInt8] = [0xBF] + imm32(0) + [0xBE] + imm32(0x1000) + [0xBA] + imm32(6) + blobSyscall(SyscallNumber.map) + blobExitRAX
    t.check("6C: map refuses write + exec", runBlob("wx", wx).status == .exited(-Errno.EINVAL))
    let unmapTouch: [UInt8] = [0xBF] + imm32(0) + [0xBE] + imm32(0x1000) + [0xBA] + imm32(3) + blobSyscall(SyscallNumber.map)
        + [0x48, 0x89, 0xC3, 0x48, 0xC7, 0x03, 0x55, 0, 0, 0] + [0x48, 0x89, 0xDF, 0xBE] + imm32(0x1000)
        + blobSyscall(SyscallNumber.unmap) + [0x48, 0x8B, 0x03] + blobExitRAX
    t.check("6C: unmap, then a read faults", runBlob("unmap", unmapTouch).status == .faulted(14))

    // Bad ELF files are refused without leaking.
    if let file = try? vfs.read("/bin/hello") {
        func refused(_ f: [UInt8]) -> Bool {
            guard let space = AddressSpace() else { return false }
            do throws(ExecError) { _ = try loadELF(f, into: space); return false } catch { return true }
        }
        var noMagic = file; noMagic[1] = 0x46
        var dyn = file; dyn[16] = 3
        var rwx = file
        let ph = Int(le(file, 32, 8))
        rwx[ph + 4] = 7 // first PT_LOAD: R+W+X
        var high = file
        for i in 0..<8 { high[ph + 16 + i] = 0xFF } // vaddr in the kernel half
        var outside = file
        outside[ph + 8 + 7] = 0x10 // offset past the end
        let short = Array(file[0..<100])
        let frames = pmm.freeFrames
        t.check("6C: ELF loader refuses bad files", refused(noMagic) && refused(dyn) && refused(rwx) && refused(high)
                && refused(outside) && refused(short) && refused([]))
        t.check("6C: refused ELF files leak nothing", pmm.freeFrames == frames)
    }

    // kill: a spinning process on another CPU is stopped (IPI).
    if onlineCPUCount() > 1, let me = scheduler.current {
        do throws(ExecError) {
            let p = try spawnProcess(path: "/bin/spin", argv: ["spin"], output: ProcessOutput(reader: me), waiter: me,
                                     affinity: .cpu(1))
            let start = ticks
            while ticks - start < 10 { yield(); cpu_pause() }
            let listed = psLines().contains { $0.hasSuffix("spin") && has($0, "running") }
            killProcess(p.pid)
            let r = runToExit(p)
            t.check("6C: ps lists a running spin", listed)
            t.check("6C: kill stops a spin running on another CPU", r.status == .killed && has(r.output, "killed"))
        } catch {
            t.check("6C: kill stops a spin running on another CPU", false)
        }
    }

    // 100 spawns return pmm and heap to their baseline.
    _ = runProgramForTest(["hello"])
    let frames = pmm.freeFrames, splits = splitPages, heap0 = HeapUsage()
    let spawned = processesSpawned
    var allOK = true
    for _ in 0..<100 where runProgramForTest(["hello"]).output != "Hello from ring 3!\n" { allOK = false }
    t.check("6C: 100 spawns of hello all print", allOK && processesSpawned == spawned + 100)
    t.check("6C: process table empty after reaping", processTable.isEmpty)
    let leaked = frames - pmm.freeFrames - (splitPages - splits)
    if leaked != 0 { print("  pmm: \(leaked) frames leaked over 100 spawns") }
    t.check("6C: pmm back to baseline after 100 spawns", leaked == 0)
    t.check("6C: heap back to baseline after 100 spawns", HeapUsage() == heap0 || heapWithin(heap0))
}
