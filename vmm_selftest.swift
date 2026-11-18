// Phase 6A selftests: page tables, address spaces, MMIO, stack guards.

func vmmTests(_ t: inout SelfTest) {
    let kernel = AddressSpace.kernel
    t.check("vmm: kernel CR3 is the boot PML4", kernelCR3 != 0 && kernel.root == kernelCR3 & PTE.address)
    t.check("vmm: kernel runs on its own PML4", read_cr3() == kernelCR3)
    var upperFull = true
    let pml4 = pageTable(kernelCR3)
    for slot in 256..<512 where pml4[slot] & PTE.present == 0 { upperFull = false }
    t.check("vmm: every upper-half PML4 slot has a PDPT", upperFull)
    // Identity map, image alias, HHDM, kernel image: all present, none user.
    var kernelSupervisor = true
    if let frame = pmm.allocate() {
        let image = UInt(address(of: &bootStack))
        for probe in [frame, image - kernelAliasOffset, frame + pmm.hhdmOffset, image] {
            guard let (_, f) = kernel.translate(probe), !f.contains(.user) else { kernelSupervisor = false; continue }
        }
        pmm.free(frame)
    }
    t.check("vmm: kernel mappings are supervisor-only", kernelSupervisor)
    t.check("vmm: EFER.NXE set", nxEnabled && rdmsr(msrEFER) & (1 << 11) != 0)
    let leaf7 = cpuid(7, 0).ebx
    t.check("vmm: SMEP on iff CPUID has it", smepEnabled == (leaf7 & (1 << 7) != 0)
            && (read_cr4() & (1 << 20) != 0) == smepEnabled)
    t.check("vmm: SMAP on iff CPUID has it", smapEnabled == (leaf7 & (1 << 20) != 0)
            && (read_cr4() & (1 << 21) != 0) == smapEnabled)
    if !smapEnabled { puts("  note SMAP not available: user-access brackets are no-ops\n") }

    // Map / translate / protect / unmap in a fresh space.
    let baseline = pmm.freeFrames
    var ok = true
    if let space = AddressSpace(), let f = pmm.allocate() {
        let v: UInt = 0x0000_0100_0000_0000
        ok = space.map(v, f, flags: [.write, .user, .noExec, .owned])
        if let (p, fl) = space.translate(v + 0x123) {
            t.check("vmm: map + translate round trip", ok && p == f + 0x123)
            t.check("vmm: flags read back", fl.contains(.write) && fl.contains(.user) && fl.contains(.noExec)
                    && fl.contains(.owned))
        } else {
            t.check("vmm: map + translate round trip", false)
            t.check("vmm: flags read back", false)
        }
        t.check("vmm: double map refused", !space.map(v, f, flags: [.user]))
        t.check("vmm: kernel half refused", !space.map(0xFFFF_9000_0000_0000, f, flags: []) && !space.map(0x1000, f, flags: []))
        space.protect(v, flags: [.user])
        let ro = space.translate(v)
        t.check("vmm: protect drops write, keeps owned", ro != nil && !ro!.flags.contains(.write) && ro!.flags.contains(.owned))
        t.check("vmm: kernel half shared", space.translate(UInt(address(of: &bootStack)))?.phys
                == kernel.translate(UInt(address(of: &bootStack)))?.phys)
        space.unmap(v)
        t.check("vmm: unmap", space.translate(v) == nil && space.ownedFrames == 0)
        t.check("vmm: unmap freed the owned frame", pmm.freeFrames == baseline - 1 - space.tableFrames)
    }
    t.check("vmm: deinit returns every frame", pmm.freeFrames == baseline)

    // A page visible only inside a space: enter it (CR3), read, leave.
    let magic: UInt64 = 0x5741_4646_4C45_5221
    var seenInside = false, goneOutside = false
    if let space = AddressSpace(), let f = pmm.allocate() {
        UnsafeMutablePointer<UInt64>(bitPattern: f)!.pointee = magic
        let v: UInt = 0x0000_2000_0000_0000
        _ = space.map(v, f, flags: [.owned]) // supervisor page in user space
        let flags = irq_save() // nothing may switch tasks while it's loaded
        space.activate()
        seenInside = UnsafePointer<UInt64>(bitPattern: v)!.pointee == magic
        enterKernelAddressSpace()
        irq_restore(flags)
        goneOutside = kernel.translate(v) == nil && read_cr3() == kernelCR3
    }
    t.check("vmm: test page visible in its space (CR3 in)", seenInside)
    t.check("vmm: and not in the kernel's (CR3 out)", goneOutside)
    t.check("vmm: no frames leaked", pmm.freeFrames == baseline)

    // MMIO: the framebuffer through mapMMIO and through the HHDM.
    if let resp = framebuffer_request.response, resp.pointee.framebuffer_count > 0,
       let fb = resp.pointee.framebuffers[0], let hhdmPtr = fb.pointee.address {
        let hhdm = hhdmPtr.assumingMemoryBound(to: UInt32.self)
        let phys = UInt(bitPattern: hhdmPtr) - pmm.hhdmOffset
        if let mmio = mapMMIO(phys + 64, 4096) {
            let m = mmio.assumingMemoryBound(to: UInt32.self)
            let saved = hhdm[16]
            m[0] = 0x00A5_5A5A
            let viaHHDM = hhdm[16]
            hhdm[16] = 0x005A_A5A5
            let viaMMIO = m[0]
            hhdm[16] = saved
            t.check("vmm: mapMMIO of the framebuffer matches the HHDM", viaHHDM == 0x00A5_5A5A && viaMMIO == 0x005A_A5A5)
            let mf = AddressSpace.kernel.translate(UInt(bitPattern: mmio))?.flags
            t.check("vmm: MMIO mapping is uncached, NX, supervisor", mf != nil && mf!.contains(.uncached)
                    && mf!.contains(.noExec) && !mf!.contains(.user))
        } else {
            t.check("vmm: mapMMIO of the framebuffer matches the HHDM", false)
        }
    }

    // Guard page below a new task's stack.
    var guardAbsent = false, stackPresent = false
    var guardPhys: UInt = 0
    let freed = withUnsafeMutablePointer(to: &tasksFreed) { atomic_load64($0) }
    if let task = spawn("guarded", { }) {
        guardPhys = task.guardPage
        guardAbsent = guardPhys != 0 && guardPhys == task.stackBottom - pageSize && !identityMapped(guardPhys)
        stackPresent = identityMapped(task.stackBottom)
    }
    t.check("vmm: page below a task stack is unmapped", guardAbsent)
    t.check("vmm: the stack itself is mapped", stackPresent)
    var spins = 0
    while withUnsafeMutablePointer(to: &tasksFreed, { atomic_load64($0) }) == freed && spins < 1000 { yield(); spins += 1 }
    t.check("vmm: guard page mapped again after the task is freed", guardPhys != 0 && identityMapped(guardPhys))
}
