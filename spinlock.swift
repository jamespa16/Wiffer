// Phase P1: spinlocks.
//
// Locks are plain structs kept in global `var`s (static storage), so they have
// one fixed address. Every access to the shared `owner` word goes through the
// bridge.h atomics on that address; the other fields are only touched by the
// CPU holding the lock. Methods are `mutating` so Swift hands them the
// global's address (Embedded Swift does no dynamic exclusivity checks).
//
// Lock order: heap -> pmm -> stdout. Nothing may allocate while holding the
// stdout lock (the console's write path doesn't), so the heap and pmm can
// print diagnostics while holding their own locks.
//
// This code must not allocate (the heap uses it).

/// Why an acquire or release is invalid. A test predicate for the panic path.
enum LockMisuse: Equatable {
    case recursive   // acquire() by the CPU that already holds it
    case notOwner    // release() by a CPU that doesn't hold it
}

/// Test-and-test-and-set spinlock. Records the owning CPU, panics on a
/// recursive acquire, and counts contended acquires.
struct SpinLock {
    /// 0 = free, else the owning CPU's index + 1.
    var owner: UInt64 = 0
    /// Acquires that found the lock held and had to spin.
    var contended: UInt64 = 0
    var acquisitions: UInt64 = 0

    var ownerWord: UInt64 {
        mutating get { withUnsafeMutablePointer(to: &owner) { atomic_load64($0) } }
    }

    mutating func isHeldByThisCPU() -> Bool { ownerWord == cpuIndex() + 1 }

    /// What acquire() would panic about on this CPU right now, if anything.
    mutating func checkAcquire() -> LockMisuse? { isHeldByThisCPU() ? .recursive : nil }
    mutating func checkRelease() -> LockMisuse? { isHeldByThisCPU() ? nil : .notOwner }

    mutating func tryAcquire() -> Bool {
        let me = cpuIndex() + 1
        guard withUnsafeMutablePointer(to: &owner, { atomic_cas64($0, 0, me) }) != 0 else { return false }
        acquisitions &+= 1
        return true
    }

    mutating func acquire() {
        if checkAcquire() != nil { lockPanic("recursive spinlock acquire") }
        if tryAcquire() { return }
        // Test-and-test-and-set: spin on plain loads, retry the CAS when free.
        while true {
            while ownerWord != 0 { cpu_pause() }
            if tryAcquire() { break }
        }
        contended &+= 1
        noteContention()
    }

    mutating func release() {
        if checkRelease() != nil { lockPanic("spinlock released by a CPU that doesn't hold it") }
        withUnsafeMutablePointer(to: &owner) { atomic_store64($0, 0) }
    }

    /// irq_save, then acquire. Returns the saved flags for releaseIRQ.
    mutating func acquireIRQ() -> UInt64 {
        let flags = irq_save()
        acquire()
        return flags
    }

    /// release, then irq_restore.
    mutating func releaseIRQ(_ flags: UInt64) {
        release()
        irq_restore(flags)
    }

    /// Run `body` holding the lock with interrupts off on this CPU.
    mutating func withIRQsOff<R>(_ body: () -> R) -> R {
        let flags = acquireIRQ()
        defer { releaseIRQ(flags) }
        return body()
    }
}

/// Spinlock the owning CPU may take again (stdout: print can nest). Released
/// when the depth returns to 0. Interrupts stay as they are: no handler
/// prints, except the dying paths, which use acquireForPanic.
struct RecursiveSpinLock {
    /// 0 = free, else the owning CPU's index + 1.
    var owner: UInt64 = 0
    /// Nesting depth; only the owner touches it.
    var depth: UInt64 = 0
    var contended: UInt64 = 0
    var acquisitions: UInt64 = 0

    var ownerWord: UInt64 {
        mutating get { withUnsafeMutablePointer(to: &owner) { atomic_load64($0) } }
    }

    mutating func isHeldByThisCPU() -> Bool { ownerWord == cpuIndex() + 1 }

    /// Take the lock (or nest) without spinning. False if another CPU holds it.
    mutating func tryAcquire() -> Bool {
        let me = cpuIndex() + 1
        if ownerWord == me { depth += 1; return true }
        guard withUnsafeMutablePointer(to: &owner, { atomic_cas64($0, 0, me) }) != 0 else { return false }
        depth = 1
        acquisitions &+= 1
        return true
    }

    mutating func acquire() {
        if tryAcquire() { return }
        while true {
            while ownerWord != 0 { cpu_pause() }
            if tryAcquire() { break }
        }
        contended &+= 1
        noteContention()
    }

    mutating func release() {
        guard isHeldByThisCPU(), depth > 0 else {
            lockPanic("recursive spinlock released by a CPU that doesn't hold it")
        }
        depth -= 1
        if depth == 0 { withUnsafeMutablePointer(to: &owner) { atomic_store64($0, 0) } }
    }

    /// For exception and panic paths: try for a bounded number of spins, then
    /// take the lock anyway (the kernel is dying, output matters more). Never
    /// released. Returns false if the lock had to be stolen.
    mutating func acquireForPanic(spins: Int = 1_000_000) -> Bool {
        var n = 0
        while n < spins {
            if tryAcquire() { return true }
            cpu_pause()
            n += 1
        }
        depth = 1
        withUnsafeMutablePointer(to: &owner) { atomic_store64($0, cpuIndex() + 1) }
        return false
    }
}

/// The heap (heap.swift), the frame allocator (pmm.swift) and the output
/// paths (print, puts, printHex, printDec).
var heapLock = SpinLock()
var pmmLock = SpinLock()
var stdoutLock = RecursiveSpinLock()

/// Per-CPU contention count, for the `cpus` command.
func noteContention() {
    if let cpu = thisCPUIfReady() { cpu.pointee.lockContention &+= 1 }
}

/// A misused lock is a kernel bug: report it and halt. Allocation-free.
func lockPanic(_ why: StaticString) -> Never {
    taskPanic(why)
}
