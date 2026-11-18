// Phase 6B: ring 3 and system calls.
//
// Entry and exit (cpu.S):
// - SYSCALL lands in syscall_entry, which swaps GS, moves to the task's
//   kernel stack (PerCPU.syscallKernelRSP), builds an interrupt_frame
//   (vector 0x100) and calls syscall_dispatch with interrupts on. It
//   returns with sysretq (iretq for a non-canonical rip).
// - Interrupts and exceptions from ring 3 enter through the IDT stubs on
//   TSS rsp0, which swap GS when the saved CS has RPL 3. GS_BASE is the
//   per-CPU pointer whenever the kernel runs; KERNEL_GS_BASE holds the user
//   value (always 0: programs don't set GS) while in ring 3.
// - user_run(rip, rsp, slot) enters ring 3 the first time. It saves the
//   kernel's callee-saved state at the top of the stack it was called on,
//   and that point is the process's kernel entry stack (syscall stack and
//   TSS rsp0, reloaded by switchedIn). When the process leaves (exit, kill,
//   fault), the dispatcher returns that point to its stub instead of 0,
//   and user_leave returns from user_run. So every Swift frame unwinds
//   normally: nothing is leaked by a process that never comes back.
//
// The kernel never dereferences a user pointer except inside copyIn,
// copyOut and withUserBuffer, which check the range page by page (present,
// user, writable for copyOut; absent pages of a mapped region are faulted
// in first) and bracket the access with stac/clac (SMAP).

let msrSTAR: UInt32 = 0xC000_0081
let msrLSTAR: UInt32 = 0xC000_0082
let msrFMASK: UInt32 = 0xC000_0084
let msrKernelGSBase: UInt32 = 0xC000_0102

/// Per CPU, from gdtInit (after the GDT, TSS and GS base): EFER.SCE, STAR
/// (kernel CS 0x08, sysret base 0x10: user SS 0x1B, CS 0x23), LSTAR, FMASK
/// (IF, DF, TF, NT, AC cleared on entry), KERNEL_GS_BASE = 0 (the user GS).
func syscallInit(cpu: Int) {
    let e = perCPUEntry(cpu)
    e.pointee.tssRSP0Address = address(of: &e.pointee.tss) + 4
    wrmsr(msrEFER, rdmsr(msrEFER) | 1)
    wrmsr(msrSTAR, UInt64(0x0010) << 48 | UInt64(Selector.kernelCode) << 32)
    wrmsr(msrLSTAR, syscall_entry_address)
    wrmsr(msrFMASK, 0x0004_4700)
    wrmsr(msrKernelGSBase, 0)
}

/// cpu.S hard-codes these PerCPU offsets.
func perCPUOffsetsOK() -> Bool {
    let e = perCPUEntry(0)
    let base = UInt64(UInt(bitPattern: e))
    return address(of: &e.pointee.syscallUserRSP) - base == 16
        && address(of: &e.pointee.syscallKernelRSP) - base == 24
        && address(of: &e.pointee.tssRSP0Address) - base == 32
}

/// The frame's vector for a syscall (syscall_entry).
let syscallVector: UInt64 = 0x100

// MARK: Dispatch

@_cdecl("syscall_dispatch")
public func syscallDispatch(_ f: UnsafeMutablePointer<interrupt_frame>) -> UInt64 {
    let e = thisCPU()
    e.pointee.syscalls &+= 1
    e.pointee.inSyscall = 1
    let result = handleSyscall(f.pointee.rax, f.pointee.rdi, f.pointee.rsi, f.pointee.rdx, f.pointee.r10)
    thisCPU().pointee.inSyscall = 0 // (maybe another CPU by now)
    f.pointee.rax = UInt64(bitPattern: Int64(result))
    if f.pointee.rip >= UInt64(userSpaceEnd) { markLeaving(.killed) } // can't happen: be safe
    return userLeavePoint()
}

/// -errno as a result.
@inline(__always) func fail(_ errno: Int) -> Int { -errno }

func handleSyscall(_ n: UInt64, _ a1: UInt64, _ a2: UInt64, _ a3: UInt64, _ a4: UInt64) -> Int {
    guard let p = currentProcess() else { return fail(Errno.ENOSYS) }
    switch n {
    case SyscallNumber.exit:
        p.exit(.exited(Int(Int64(bitPattern: a1))))
        return 0
    case SyscallNumber.yield:
        yield()
        return 0
    case SyscallNumber.debugWrite:
        return sysDebugWrite(p, a1, a2)
    case SyscallNumber.getpid:
        return p.pid
    case SyscallNumber.write:
        return sysWrite(p, a1, a2, a3)
    case SyscallNumber.map:
        return p.mapAnonymous(hint: UInt(a1), length: a2, prot: a3)
    case SyscallNumber.unmap:
        return p.unmapRange(UInt(a1), a2)
    case SyscallNumber.protect:
        return p.protectRange(UInt(a1), a2, prot: a3)
    case SyscallNumber.testWaitIRQs:
        return sysTestWaitIRQs(a1, a2)
    default:
        return fail(Errno.ENOSYS)
    }
}

/// Raw bytes to COM1 (not the console: it isn't safe off CPU 0). The last
/// few are kept on the process for selftests.
func sysDebugWrite(_ p: Process, _ buf: UInt64, _ len: UInt64) -> Int {
    guard len <= 4096 else { return fail(Errno.EINVAL) }
    guard let bytes = copyIn(buf, Int(len)) else { return fail(Errno.EFAULT) }
    stdoutLock.acquire()
    for b in bytes {
        if b == 0x0A { serialPutc(0x0D) }
        serialPutc(b)
    }
    stdoutLock.release()
    p.noteDebug(bytes)
    return bytes.count
}

/// write(fd, buf, len): fds 1 and 2 go to the process's output (6C; 6E
/// replaces this with real file descriptors).
func sysWrite(_ p: Process, _ fd: UInt64, _ buf: UInt64, _ len: UInt64) -> Int {
    guard fd == 1 || fd == 2 else { return fail(Errno.EBADF) }
    guard len <= 1 << 30 else { return fail(Errno.EINVAL) }
    var done = 0
    while done < Int(len) {
        let n = min(Int(len) - done, 4096)
        guard let bytes = copyIn(buf + UInt64(done), n) else { return done > 0 ? done : fail(Errno.EFAULT) }
        p.emit(bytes)
        done += n
        if p.killRequested { break }
    }
    return done
}

/// Selftests: wait with interrupts on until `count` interrupts have hit
/// this CPU in ring 0 during this syscall, or `limit` ticks pass.
func sysTestWaitIRQs(_ count: UInt64, _ limit: UInt64) -> Int {
    let e = thisCPU()
    let start = e.pointee.syscallInterrupts
    let deadline = ticks &+ min(limit, 1000)
    while e.pointee.syscallInterrupts &- start < count && ticks < deadline {
        e.pointee.inSyscall = 1
        cpu_pause()
    }
    return Int(e.pointee.syscallInterrupts &- start)
}

// MARK: Leaving user mode

func currentProcess() -> Process? { scheduler.current?.process }

/// Mark the current process as leaving (exit, fault, kill).
func markLeaving(_ status: ExitStatus) {
    currentProcess()?.exit(status)
}

/// What a stub returning to ring 3 should do: 0 to return, or user_run's
/// stack point when the process is leaving (it exited, faulted or was
/// killed).
func userLeavePoint() -> UInt64 {
    guard let me = scheduler.current, let p = me.process else { return 0 }
    if p.killRequested && p.status == nil { p.status = .killed }
    guard p.status != nil else { return 0 }
    return me.userEntry.pointee
}

// MARK: Faults from ring 3 (6B4)

/// An exception in ring 3: a demand fault on a mapped region is served,
/// anything else ends the process with a one-line report. Returns the
/// stub's leave value (0: resume the user code).
@inline(never)
func userException(_ f: UnsafeMutablePointer<interrupt_frame>) -> UInt64 {
    let vector = f.pointee.vector
    let cr2 = vector == 14 ? read_cr2() : 0
    guard let p = currentProcess() else { exceptionReport(f.pointee) }
    if vector == 14 && f.pointee.error_code & 1 == 0 && p.demandFault(UInt(cr2), errorCode: f.pointee.error_code) {
        return userLeavePoint()
    }
    var what: String
    switch vector {
    case 0: what = "divide error"
    case 3: what = "breakpoint"
    case 6: what = "invalid opcode"
    case 13: what = "general protection fault"
    case 14: what = "page fault at \(groupedHex(cr2))"
    default: what = "exception \(vector)"
    }
    p.report = "pid \(p.pid) (\(p.name)): \(what), rip \(groupedHex(f.pointee.rip))"
    p.exit(.faulted(vector))
    return userLeavePoint()
}

/// `0x100_0000_1234`: lower-case hex, no leading zeros, `_` every 4 digits.
func groupedHex(_ value: UInt64) -> String {
    var digits: [UInt8] = []
    var v = value
    var n = 0
    repeat {
        if n > 0 && n % 4 == 0 { digits.append(0x5F) }
        let d = UInt8(v & 0xF)
        digits.append(d < 10 ? 0x30 + d : 0x61 + d - 10)
        v >>= 4
        n += 1
    } while v != 0
    return "0x" + String(decoding: digits.reversed(), as: UTF8.self)
}

// MARK: User memory access

/// Check that every page of [addr, addr + len) is user-accessible in the
/// current process (writable too, if `write`), faulting in absent pages of
/// its mapped regions. The process's address space must be the active one.
func userRangeReady(_ p: Process, _ addr: UInt, _ len: Int, write: Bool) -> Bool {
    guard len >= 0, let space = p.space, space.isActive else { return false }
    guard len > 0 else { return true }
    guard isUserRange(addr, UInt(len)) else { return false }
    var page = addr & ~(pageSize - 1)
    let end = addr + UInt(len)
    while page < end {
        var t = space.translate(page)
        if t == nil {
            guard p.demandFault(page, errorCode: write ? 2 : 0) else { return false }
            t = space.translate(page)
        }
        guard let (_, flags) = t, flags.contains(.user), !write || flags.contains(.write) else { return false }
        page += pageSize
    }
    return true
}

/// Bytes from the current process's memory, or nil (-EFAULT).
func copyIn(_ addr: UInt64, _ len: Int) -> [UInt8]? {
    guard let p = currentProcess(), userRangeReady(p, UInt(addr), len, write: false) else { return nil }
    guard len > 0 else { return [] }
    return [UInt8](unsafeUninitializedCapacity: len) { buf, count in
        userAccessBegin()
        buf.baseAddress!.update(from: UnsafePointer<UInt8>(bitPattern: UInt(addr))!, count: len)
        userAccessEnd()
        count = len
    }
}

/// Copy bytes into the current process's memory. False (-EFAULT) if the
/// range isn't writable user memory.
func copyOut(_ addr: UInt64, _ bytes: [UInt8]) -> Bool {
    guard let p = currentProcess(), userRangeReady(p, UInt(addr), bytes.count, write: true) else { return false }
    guard !bytes.isEmpty else { return true }
    bytes.withUnsafeBufferPointer { src in
        userAccessBegin()
        UnsafeMutablePointer<UInt8>(bitPattern: UInt(addr))!.update(from: src.baseAddress!, count: src.count)
        userAccessEnd()
    }
    return true
}

/// Run `body` on the current process's memory in place (no copy). `body`
/// must not block, yield or fault. Nil if the range isn't valid.
func withUserBuffer<R>(_ addr: UInt64, _ len: Int, write: Bool, _ body: (UnsafeMutableRawBufferPointer) -> R) -> R? {
    guard let p = currentProcess(), userRangeReady(p, UInt(addr), len, write: write) else { return nil }
    userAccessBegin()
    defer { userAccessEnd() }
    return body(UnsafeMutableRawBufferPointer(start: UnsafeMutableRawPointer(bitPattern: UInt(addr)), count: len))
}
