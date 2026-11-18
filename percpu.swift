// Phase P2: per-CPU data.
//
// One PerCPU entry per CPU in a fixed global array (no class), indexed by CPU
// index (0 = the BSP). IA32_GS_BASE points at the CPU's entry, at its
// lower-half alias, so thisCPU() is a single %gs:0 load. gdtInit(cpu:) sets
// it (it has to: gdt_load's reload of GS clears the base).
//
// Before the BSP's gdtInit, GS base is 0, so cpuIndex() returns 0 until
// gsBaseReady is set. An AP must run gdtInit(cpu:) before it takes any lock
// or prints (Phase R).

let maxCPUs = 64
let msrGSBase: UInt32 = 0xC000_0101

struct PerCPU {
    /// Word 0 (%gs:0): this entry's own address, as loaded into GS base.
    var selfAddress: UInt64 = 0
    /// Word 1 (%gs:8): CPU index, 0 = BSP.
    var index: UInt64 = 0
    /// Words 2-4 (Phase 6B), used by cpu.S at these fixed offsets (checked
    /// by perCPUOffsetsOK): the user rsp while the syscall stub switches
    /// stacks; the kernel stack top for syscalls (the running process's
    /// user_run point); the address of this CPU's TSS rsp0 field.
    var syscallUserRSP: UInt64 = 0
    var syscallKernelRSP: UInt64 = 0
    var tssRSP0Address: UInt64 = 0
    var apicID: UInt64 = 0
    var online = false

    /// null, kernel code64, kernel data, user data, user code64, TSS (2 slots).
    var gdt = InlineArray<7, UInt64>(repeating: 0)
    /// The 104-byte 64-bit TSS, as 32-bit words because its 64-bit fields are
    /// only 4-byte aligned. Word 1-2: rsp0, 9-10: ist1, 25 (high half): I/O map base.
    var tss = InlineArray<26, UInt32>(repeating: 0)
    /// Top of this CPU's double-fault (IST1) stack. The BSP's is the static
    /// doubleFaultStack; Phase R allocates one per AP and sets this before
    /// calling gdtInit(cpu:).
    var doubleFaultStackTop: UInt64 = 0

    // Stats, for the `cpus` command (Phase R/S fill these in).
    var switches: UInt64 = 0
    var idleTicks: UInt64 = 0
    var ipisReceived: UInt64 = 0
    var lockContention: UInt64 = 0
    /// Times the idle loop woke from hlt (APs; Phase R).
    var idleWakeups: UInt64 = 0

    // Phase R: this CPU's boot/idle stack (identity-mapped, 64 KiB) and CR3.
    // Phase S turns the AP's boot stack into that CPU's idle task.
    var stackBase: UInt64 = 0
    var stackTop: UInt64 = 0
    var cr3: UInt64 = 0

    // Phase S. `sched` is an Unmanaged<CPUSched> (task.swift: current and
    // idle task, zombies), kept as raw bits so PerCPU stays plain storage;
    // set once (CPU 0 in scheduler.start, an AP in apMain before it counts
    // itself online) and never freed.
    var sched: UInt64 = 0
    /// Watchdog (task.swift): `ticks` when the running task was switched in
    /// or last cooperated; 1 while a real task (not the idle task) runs; 1
    /// once the BSP's timer IRQ has warned about this CPU.
    var watchdogMark: UInt64 = 0
    var watchdogActive: UInt64 = 0
    var watchdogTripped: UInt64 = 0
    /// Timer ticks (100 Hz, sampled by the BSP's IRQ) at which this CPU was
    /// running a real task: off its idle task (APs), or not in idleStep's
    /// hlt (CPU 0). The taskbar's usage meters are deltas of it.
    var busyTicks: UInt64 = 0

    // Phase 6B stats (selftests, `cpus`): syscalls made on this CPU;
    // interrupts that arrived in ring 3; interrupts that arrived in ring 0
    // while a syscall was running here (inSyscall: depth, set by
    // syscall_dispatch).
    var syscalls: UInt64 = 0
    var userInterrupts: UInt64 = 0
    var syscallInterrupts: UInt64 = 0
    var inSyscall: UInt64 = 0
    /// 1 while the task running here is a process's thread. The watchdog
    /// leaves those alone: ring-3 code is preempted (6D), not trusted to yield.
    var processRunning: UInt64 = 0
}

var perCPU = InlineArray<64, PerCPU>(repeating: PerCPU())

/// Set once the BSP's GS base points at perCPU[0].
var gsBaseReady = false

/// Lower-half alias of perCPU[cpu] (see FrameAllocator.mapLowerHalf), or its
/// kernel-image address if the alias isn't mapped.
func perCPUAddress(_ cpu: Int) -> UInt64 {
    withUnsafeMutablePointer(to: &perCPU) { p in
        let entry = UInt(bitPattern: p) + UInt(cpu * MemoryLayout<PerCPU>.stride)
        return UInt64(kernelAliasMapped ? entry - kernelAliasOffset : entry)
    }
}

/// perCPU[cpu] through its stable (alias) address: fields reached through
/// `.pointee` are real addresses, never temporary copies.
func perCPUEntry(_ cpu: Int) -> UnsafeMutablePointer<PerCPU> {
    UnsafeMutablePointer<PerCPU>(bitPattern: UInt(perCPUAddress(cpu)))!
}

/// This CPU's entry. Only valid after gdtInit(cpu:) on this CPU.
func thisCPU() -> UnsafeMutablePointer<PerCPU> {
    UnsafeMutablePointer<PerCPU>(bitPattern: UInt(this_cpu_address()))!
}

/// thisCPU(), or nil this early in boot (BSP before gdtInit).
func thisCPUIfReady() -> UnsafeMutablePointer<PerCPU>? {
    gsBaseReady ? thisCPU() : nil
}

/// This CPU's index (0 before GS base is set up: only the BSP runs then).
func cpuIndex() -> UInt64 {
    gsBaseReady ? this_cpu_index() : 0
}

/// Fill in the entry's identity and point GS base at it.
func perCPUBind(cpu: Int) {
    let addr = perCPUAddress(cpu)
    let e = perCPUEntry(cpu)
    e.pointee.selfAddress = addr
    e.pointee.index = UInt64(cpu)
    wrmsr(msrGSBase, addr)
    if cpu == 0 { // APs mark themselves online later in bring-up (Phase R)
        e.pointee.online = true
        gsBaseReady = true
    }
}
