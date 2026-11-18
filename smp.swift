// Phase R: AP bring-up through Limine's MP request.
//
// Sequencing (kernelMain): smpInit() runs right after the BSP's first `sti`,
// once pmm, heap, the IDT, x2APIC and the PIT tick exist, and before fsInit
// and the desktop. For each AP the BSP allocates a 64 KiB stack and a 16 KiB
// double-fault stack from the pmm (identity-mapped), fills in perCPU[i], and
// last of all writes the AP's goto_address (mp_start). The BSP then waits up
// to smpTimeoutTicks timer ticks (1 s, interrupts on, `hlt` between checks)
// for every AP to count itself in, and prints `smp: N CPUs online`.
//
// An AP runs ap_entry (kernel's first code on it: SSE on, then a never-inlined
// continuation), moves to its own lower-half stack, loads its GDT/TSS/GS
// (gdtInit(cpu:) -- before it prints or takes a lock), the shared IDT and
// x2APIC (LINTs masked), records its CR3, marks itself online, and parks in
// apIdleLoop(). APs print nothing: all output comes from the BSP.
//
// With no MP response, no x2APIC, or one CPU: `smp: 1 CPU online`, nothing else.

let smpTimeoutTicks: UInt64 = 100 // 1 s at 100 Hz
let apStackSize = 65536
let apDoubleFaultStackSize = 16384

/// CPUs Limine reported (BSP included, capped at maxCPUs); 1 without MP.
var smpReported = 1
/// CPUs we started (BSP + APs we gave a stack and a goto_address).
var smpStarted = 1
/// APs that have counted themselves in (atomic, written by the APs).
var apsOnline: UInt64 = 0

/// How many CPUs are online (BSP included).
func onlineCPUCount() -> Int {
    var n = 0
    for i in 0..<smpStarted where perCPUEntry(i).pointee.online { n += 1 }
    return n
}

func smpInit() {
    let bsp = perCPUEntry(0)
    bsp.pointee.cr3 = read_cr3()
    guard x2apicEnabled, let resp = mp_request.response,
          resp.pointee.flags & UInt32(LIMINE_MP_RESPONSE_X86_64_X2APIC) != 0,
          let cpus = resp.pointee.cpus else {
        print("smp: 1 CPU online")
        return
    }
    let reported = min(Int(resp.pointee.cpu_count), maxCPUs)
    smpReported = max(reported, 1)
    let bspID = resp.pointee.bsp_lapic_id
    var next = 1
    for n in 0..<reported {
        guard let info = cpus[n] else { continue }
        if info.pointee.lapic_id == bspID { continue }
        guard next < maxCPUs, let stack = pmm.allocate(count: apStackSize / frameSize),
              let df = pmm.allocate(count: apDoubleFaultStackSize / frameSize) else {
            print("smp: out of memory for CPU \(next)")
            break
        }
        let e = perCPUEntry(next)
        e.pointee.apicID = UInt64(info.pointee.lapic_id)
        e.pointee.stackBase = UInt64(stack)
        e.pointee.stackTop = UInt64(stack) + UInt64(apStackSize)
        e.pointee.doubleFaultStackTop = UInt64(df) + UInt64(apDoubleFaultStackSize)
        apSchedInit(cpu: next) // Phase S: its boot context will be its idle task
        mp_start(info, UInt64(next), apEntry) // last: the AP starts now
        next += 1
    }
    smpStarted = next

    let deadline = ticks + smpTimeoutTicks
    while ticks < deadline && withUnsafeMutablePointer(to: &apsOnline, { atomic_load64($0) }) < UInt64(next - 1) {
        hlt()
    }
    let up = onlineCPUCount()
    if up < next { print("smp: only \(up) of \(next) CPUs came up") }
    print("smp: \(up) CPU\(up == 1 ? "" : "s") online")
    for i in 1..<next where perCPUEntry(i).pointee.online && perCPUEntry(i).pointee.cr3 != bsp.pointee.cr3 {
        print("smp: CPU \(i) CR3 differs from the BSP's")
    }
}

/// An AP's first code (Limine calls it in 64-bit mode on its own small HHDM
/// stack, interrupts off). Like kernel_main: SSE first, then on. build.sh
/// checks this function and apEnterStack for xmm instructions.
@_cdecl("ap_entry")
public func apEntry(_ info: UnsafeMutablePointer<limine_mp_info>?) {
    enableSSE()
    apEnterStack(info!)
}

/// Leave Limine's high-memory AP stack for this CPU's lower-half stack (same
/// Swift tag-bit reasoning as enterBootStack), then run apMain there.
@inline(never)
func apEnterStack(_ info: UnsafeMutablePointer<limine_mp_info>) -> Never {
    let cpu = info.pointee.extra_argument
    let top = perCPUEntry(Int(cpu)).pointee.stackTop & ~15
    switch_stack_arg(top, cpu) { apMain(Int($0)) }
}

@inline(never)
func apMain(_ cpu: Int) -> Never {
    gdtInit(cpu: cpu) // first: builds this CPU's GDT/TSS, loads them and GS base
    idtLoad()
    cpuProtectionInit() // Phase 6A: SMEP/SMAP in this CPU's CR4
    apicEnableThisCPU(bsp: false)
    let e = thisCPU()
    e.pointee.cr3 = read_cr3()
    e.pointee.online = true
    _ = withUnsafeMutablePointer(to: &apsOnline) { atomic_fetch_add64($0, 1) }
    apIdleLoop()
}

// apIdleLoop (the AP's idle task) is in task.swift.

// MARK: Panics on any CPU

/// 0 = no panic, else the panicking CPU's index + 1 (first CPU wins).
var panicOwner: UInt64 = 0
/// CPUs that stopped for a panic (halt IPI or NMI).
var cpusHalted: UInt64 = 0

/// Start a panic or exception report. The first CPU to get here stops every
/// other online CPU (halt IPI 0xF1; an NMI for those that haven't stopped
/// within ~10 ms, e.g. spinning with interrupts off) and returns to write
/// its report. A CPU that loses the race (or an NMI'd one) just halts. A
/// nested panic on the winning CPU carries on. Allocation-free, no locks.
func panicBegin() {
    let me = cpuIndex() + 1
    let won = withUnsafeMutablePointer(to: &panicOwner) { atomic_cas64($0, 0, me) } != 0
    if !won {
        if withUnsafeMutablePointer(to: &panicOwner, { atomic_load64($0) }) == me { return }
        panicHaltThisCPU()
    }
    guard x2apicEnabled, smpStarted > 1 else { return }
    let others = UInt64(onlineCPUCount() - 1)
    guard others > 0 else { return }
    broadcastIPI(vector: Vector.halt, excludingSelf: true)
    if !waitForHalted(others) {
        sendNMI(apicID: nil)
        _ = waitForHalted(others)
    }
}

/// Spin up to ~10 ms (by the TSC, assuming >= 1 GHz; capped in spins too)
/// for `n` CPUs to report themselves halted.
func waitForHalted(_ n: UInt64) -> Bool {
    let start = rdtsc()
    var spins = 0
    while withUnsafeMutablePointer(to: &cpusHalted, { atomic_load64($0) }) < n {
        if rdtsc() &- start > 10_000_000 || spins > 50_000_000 { return false }
        cpu_pause()
        spins += 1
    }
    return true
}

/// Stop this CPU for good (another CPU is panicking).
func panicHaltThisCPU() -> Never {
    cli()
    _ = withUnsafeMutablePointer(to: &cpusHalted) { atomic_fetch_add64($0, 1) }
    hcf()
}

// MARK: cpus command, selftests

/// Timer IRQ (BSP, 100 Hz): count a busy tick for every CPU running a real
/// task right now. An AP is busy while its watchdog is active (off its idle
/// task); CPU 0 while it isn't in idleStep's hlt (its idle bit; the IRQ that
/// samples it is what wakes that hlt). Allocation- and lock-free word reads.
func cpuUsageTick() {
    for i in 0..<max(smpStarted, 1) {
        let e = perCPUEntry(i)
        let busy = i == 0 ? idleCPUMask & 1 == 0 : e.pointee.watchdogActive != 0
        if busy { e.pointee.busyTicks &+= 1 }
    }
}

/// Per-CPU usage in percent since the previous call, for the taskbar (called
/// twice a second): the share of timer ticks each CPU spent busy. A
/// statistical sample at 100 Hz, so it's a meter, not an exact account.
var usageLastTicks: UInt64 = 0
var usageLastBusy = InlineArray<64, UInt64>(repeating: 0)
func cpuUsagePercent() -> [Int] {
    let n = max(smpStarted, 1)
    let now = ticks
    let elapsed = now &- usageLastTicks
    usageLastTicks = now
    var out: [Int] = []
    out.reserveCapacity(n)
    for i in 0..<n {
        let b = perCPUEntry(i).pointee.busyTicks
        let delta = b &- usageLastBusy[i]
        usageLastBusy[i] = b
        out.append(elapsed == 0 ? 0 : Int(min(delta * 100 / elapsed, 100)))
    }
    return out
}

func cpusInfo() -> [String] {
    var lines = ["cpu  apic  online  task  switches  wakeups  ipis  contention"]
    let names = currentTaskNames()
    for i in 0..<smpStarted {
        let e = perCPUEntry(i)
        lines.append("\(i)  \(e.pointee.apicID)  \(e.pointee.online ? "yes" : "no")  \(names[i])  \(e.pointee.switches)  \(e.pointee.idleWakeups)  \(e.pointee.ipisReceived)  \(e.pointee.lockContention)")
    }
    return lines
}

func smpBringUpTests(_ t: inout SelfTest) {
    let up = onlineCPUCount()
    t.check("smp: every started CPU is online", up == smpStarted)
    t.check("smp: online count == CPUs Limine reported", up == smpReported)
    if smpStarted == 1 { puts("  note single CPU: AP ping and CR3 checks are trivial\n") }
    var cr3Same = true, stacksOK = true
    for i in 1..<max(smpStarted, 1) {
        let e = perCPUEntry(i)
        if e.pointee.cr3 != perCPUEntry(0).pointee.cr3 { cr3Same = false }
        if e.pointee.stackTop - e.pointee.stackBase != UInt64(apStackSize) || e.pointee.stackTop >= 1 << 47 { stacksOK = false }
    }
    t.check("smp: every AP's CR3 equals the BSP's", cr3Same)
    t.check("smp: AP stacks are 64 KiB, lower-half", stacksOK)
    var pinged = true
    for i in 1..<max(smpStarted, 1) {
        let e = perCPUEntry(i)
        let before = withUnsafeMutablePointer(to: &e.pointee.ipisReceived) { atomic_load64($0) }
        let wakes = e.pointee.idleWakeups
        sendIPI(apicID: UInt32(e.pointee.apicID), vector: Vector.ping)
        var spins = 0
        while withUnsafeMutablePointer(to: &e.pointee.ipisReceived, { atomic_load64($0) }) == before && spins < 20_000_000 {
            spins += 1; cpu_pause()
        }
        if e.pointee.ipisReceived == before { pinged = false; puts("  smp: CPU "); printDec(UInt64(i)); puts(" did not answer\n") }
        _ = wakes
    }
    t.check("smp: ping IPI reaches every AP", pinged)
    var woke = true
    for i in 1..<max(smpStarted, 1) where perCPUEntry(i).pointee.idleWakeups == 0 { woke = false }
    t.check("smp: every AP idles in hlt and wakes", woke)
}
