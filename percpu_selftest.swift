// Phase P selftests: spinlocks, the per-CPU block and GS base, per-CPU
// GDT/TSS, and the locks around the allocators and output. Single CPU:
// "another CPU" is simulated by writing a different owner into a lock.

func smpPrepTests(_ t: inout SelfTest) {
    spinLockTests(&t)
    recursiveLockTests(&t)
    perCPUTests(&t)
    lockedAllocatorTests(&t)
}

/// An owner word for a CPU that isn't this one.
let otherCPUOwner: UInt64 = 7 + 1

func spinLockTests(_ t: inout SelfTest) {
    var lock = SpinLock()
    let me = cpuIndex() + 1
    t.check("spinlock: starts free", lock.ownerWord == 0 && lock.checkAcquire() == nil)
    let took = lock.tryAcquire()
    t.check("spinlock: tryAcquire takes a free lock", took && lock.ownerWord == me)
    t.check("spinlock: tryAcquire fails while held", !lock.tryAcquire())
    t.check("spinlock: recursive acquire is caught", lock.checkAcquire() == .recursive)
    t.check("spinlock: owner may release", lock.checkRelease() == nil)
    lock.release()
    t.check("spinlock: release frees it", lock.ownerWord == 0 && lock.checkAcquire() == nil)
    t.check("spinlock: release when not held is caught", lock.checkRelease() == .notOwner)

    lock.acquire()
    let held = lock.ownerWord == me
    lock.release()
    t.check("spinlock: acquire/release", held && lock.ownerWord == 0 && lock.acquisitions == 2)
    t.check("spinlock: uncontended acquires not counted", lock.contended == 0)

    // Held by some other CPU: not ours, so not a recursion; try fails.
    lock.owner = otherCPUOwner
    t.check("spinlock: held elsewhere, not recursive",
            lock.checkAcquire() == nil && lock.checkRelease() == .notOwner && !lock.tryAcquire())
    lock.owner = 0

    // IRQ-saving variant.
    let flags = lock.acquireIRQ()
    let offInside = !interruptsEnabled && lock.isHeldByThisCPU()
    lock.releaseIRQ(flags)
    t.check("spinlock: acquireIRQ disables interrupts", offInside)
    t.check("spinlock: releaseIRQ restores them", interruptsEnabled && lock.ownerWord == 0)
    let v = lock.withIRQsOff { interruptsEnabled ? 0 : 42 }
    t.check("spinlock: withIRQsOff runs with interrupts off", v == 42 && interruptsEnabled && lock.ownerWord == 0)
    cli()
    let f2 = lock.acquireIRQ()
    lock.releaseIRQ(f2)
    let stayedOff = !interruptsEnabled
    sti()
    t.check("spinlock: releaseIRQ leaves interrupts off if they were", stayedOff)
}

func recursiveLockTests(_ t: inout SelfTest) {
    var lock = RecursiveSpinLock()
    lock.acquire()
    lock.acquire()
    let nested = lock.depth == 2 && lock.isHeldByThisCPU()
    lock.release()
    let stillHeld = lock.depth == 1 && lock.isHeldByThisCPU()
    lock.release()
    t.check("recursive lock: nests on the owning CPU", nested && stillHeld)
    t.check("recursive lock: free after the last release", lock.ownerWord == 0 && lock.depth == 0)
    t.check("recursive lock: counts outermost acquires only", lock.acquisitions == 1)

    lock.owner = otherCPUOwner
    t.check("recursive lock: tryAcquire fails if another CPU holds it", !lock.tryAcquire())
    let clean = lock.acquireForPanic(spins: 100)
    t.check("recursive lock: panic path steals after a bounded spin",
            !clean && lock.isHeldByThisCPU() && lock.depth == 1)
    lock.release()
    t.check("recursive lock: panic path takes a free lock cleanly", lock.acquireForPanic(spins: 100))

    t.check("stdout lock free between prints", stdoutLock.ownerWord == 0 && stdoutLock.depth == 0)
}

func perCPUTests(_ t: inout SelfTest) {
    t.check("percpu: GS base set up", gsBaseReady)
    t.check("percpu: thisCPU().index == 0", thisCPU().pointee.index == 0 && cpuIndex() == 0)
    t.check("percpu: GS base is the BSP's block",
            rdmsr(msrGSBase) == perCPUAddress(0) && this_cpu_address() == perCPUAddress(0)
            && thisCPU().pointee.selfAddress == perCPUAddress(0))
    t.check("percpu: %gs:8 matches the index field (layout)", this_cpu_index() == thisCPU().pointee.index)
    t.check("percpu: block at a lower-half address", perCPUAddress(0) < 1 << 47)
    t.check("percpu: BSP online", perCPU[0].online && !perCPU[1].online)
    t.check("percpu: GDT is the BSP's own", read_gdtr().base == address(of: &perCPUEntry(0).pointee.gdt))

    // gdtInit(cpu:) for another index: load CPU 1's tables here, then the
    // BSP's again. Interrupts off, no locks or output in between.
    let e1 = perCPUEntry(1)
    e1.pointee.doubleFaultStackTop = address(of: &doubleFaultStack) + UInt64(doubleFaultStack.count)
    let flags = irq_save()
    gdtInit(cpu: 1)
    let gdtr1 = read_gdtr(), tr1 = read_tr()
    let gs1 = rdmsr(msrGSBase), index1 = this_cpu_index()
    gdtInit(cpu: 0)
    irq_restore(flags)
    e1.pointee = PerCPU() // leave the entry clean for AP bring-up
    t.check("percpu: gdtInit(cpu: 1) loads CPU 1's GDT and TSS",
            gdtr1.base == address(of: &e1.pointee.gdt) && tr1 == Selector.tss)
    t.check("percpu: gdtInit(cpu: 1) points GS at CPU 1's block",
            gs1 == perCPUAddress(1) && index1 == 1)
    t.check("percpu: back on the BSP's tables",
            read_gdtr().base == address(of: &perCPUEntry(0).pointee.gdt)
            && read_tr() == Selector.tss && cpuIndex() == 0 && rdmsr(msrGSBase) == perCPUAddress(0))
}

func lockedAllocatorTests(_ t: inout SelfTest) {
    t.check("heap/pmm locks free between calls", heapLock.ownerWord == 0 && pmmLock.ownerWord == 0)
    let heapBefore = heapLock.acquisitions, pmmBefore = pmmLock.acquisitions
    let p = UnsafeMutableRawPointer.allocate(byteCount: 10_000, alignment: 16) // frame-backed
    p.deallocate()
    t.check("heap and pmm take their locks", heapLock.acquisitions == heapBefore + 2
            && pmmLock.acquisitions == pmmBefore + 2)
    t.check("heap/pmm locks released", heapLock.ownerWord == 0 && pmmLock.ownerWord == 0)
    t.check("interrupts still on after allocating", interruptsEnabled)
    t.check("no lock contention on one CPU",
            heapLock.contended == 0 && pmmLock.contended == 0 && stdoutLock.contended == 0)
}
