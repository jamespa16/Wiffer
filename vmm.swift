// Phase 6A: page tables.
//
// The kernel half (PML4 slots 0, 255 and 256-511; ROADMAP "Address space")
// is the same in every address space: a process PML4 copies those top-level
// entries, which point at shared PDPTs. Slots 1-254 are per process (user
// space). vmmInit preallocates a PDPT for every empty upper-half slot, so the
// kernel never adds a top-level entry later that older PML4s would miss.
//
// - AddressSpace: a PML4 frame and, for user spaces, the table frames under
//   slots 1-254. map/unmap/translate/protect work on 4 KiB pages; leaf
//   frames mapped with `.owned` are freed by unmap and deinit. Tables are
//   pmm frames, zeroed and edited through the identity map.
// - TLB: a user space is live on at most one CPU (processes are single
//   threaded, and switching to another task reloads CR3), so its own
//   changes need only a local invlpg. Kernel-half changes (mapMMIO, stack
//   guards) are new mappings or present -> absent (a stale entry on another
//   CPU only means a guard page that doesn't fault there yet).
// - Kernel-half edits take kernelMapLock (then pmmLock inside).
// - SMEP and SMAP are on when CPUID has them. The kernel touches user pages
//   only inside userAccessBegin/End (syscall.swift: copyIn, copyOut).

/// Page-table entry bits.
enum PTE {
    static let present: UInt64 = 1
    static let write: UInt64 = 1 << 1
    static let user: UInt64 = 1 << 2
    static let writeThrough: UInt64 = 1 << 3
    static let cacheDisable: UInt64 = 1 << 4
    static let accessed: UInt64 = 1 << 5
    static let dirty: UInt64 = 1 << 6
    /// PS in a PDPT or PD entry (1 GiB / 2 MiB page); PAT in a 4 KiB PTE.
    static let huge: UInt64 = 1 << 7
    static let global: UInt64 = 1 << 8
    /// Software bit: the frame belongs to the address space (freed with it).
    static let owned: UInt64 = 1 << 9
    /// PAT bit of a 1 GiB / 2 MiB entry.
    static let hugePAT: UInt64 = 1 << 12
    static let noExec: UInt64 = 1 << 63
    static let address: UInt64 = 0x000F_FFFF_FFFF_F000
}

/// Mapping flags (the matching PTE bits; present is implied).
struct PageFlags: OptionSet, Equatable {
    let rawValue: UInt64
    init(rawValue: UInt64) { self.rawValue = rawValue }
    static let write = PageFlags(rawValue: PTE.write)
    static let user = PageFlags(rawValue: PTE.user)
    static let uncached = PageFlags(rawValue: PTE.cacheDisable | PTE.writeThrough)
    static let owned = PageFlags(rawValue: PTE.owned)
    static let noExec = PageFlags(rawValue: PTE.noExec)
    static let all: UInt64 = PTE.write | PTE.user | PTE.cacheDisable | PTE.writeThrough | PTE.owned | PTE.noExec
}

let pageSize: UInt = 4096
/// User space: PML4 slots 1-254.
let userSpaceStart: UInt = 1 << 39
let userSpaceEnd: UInt = 255 << 39 // 0x0000_7F80_0000_0000
/// mapMMIO's window: all of PML4 slot 384 (0xffff_c000_0000_0000).
let mmioWindowBase: UInt = 0xFFFF_C000_0000_0000
let mmioWindowSize: UInt = 1 << 39

func isUserRange(_ start: UInt, _ length: UInt) -> Bool {
    start >= userSpaceStart && start < userSpaceEnd && length <= userSpaceEnd - start
}

/// A page table frame through the identity map.
@inline(__always)
func pageTable(_ phys: UInt64) -> UnsafeMutablePointer<UInt64> {
    UnsafeMutablePointer<UInt64>(bitPattern: UInt(phys & PTE.address))!
}

/// A zeroed frame for a page table (physical address), or nil.
func newTableFrame() -> UInt64? {
    guard let f = pmm.allocate() else { return nil }
    UnsafeMutableRawPointer(bitPattern: f)!.initializeMemory(as: UInt8.self, repeating: 0, count: frameSize)
    return UInt64(f)
}

// MARK: Boot setup (6A2)

/// The boot PML4 (CR3 at vmmInit); every kernel task runs on it.
var kernelCR3: UInt64 = 0
var nxEnabled = false
var smepEnabled = false
var smapEnabled = false
/// Upper-half slots that were empty and got a preallocated PDPT.
var preallocatedPDPTs = 0
var kernelMapLock = SpinLock()

let msrEFER: UInt32 = 0xC000_0080

/// CPU 0, after pmm.initialize and before any address space or AP exists.
func vmmInit() {
    kernelCR3 = read_cr3()
    let pml4 = pageTable(kernelCR3)
    for slot in 256..<512 where pml4[slot] & PTE.present == 0 {
        guard let pdpt = newTableFrame() else {
            puts("vmm: no memory for kernel PDPTs\n")
            hcf()
        }
        pml4[slot] = pdpt | PTE.present | PTE.write
        preallocatedPDPTs += 1
    }
    write_cr3(kernelCR3)
    cpuProtectionInit()
    print("vmm: \(preallocatedPDPTs) kernel PDPTs preallocated, NX \(nxEnabled ? "on" : "off"), SMEP \(smepEnabled ? "on" : "off"), SMAP \(smapEnabled ? "on" : "off")")
}

/// Every CPU: check EFER.NXE and turn on SMEP/SMAP if CPUID has them.
func cpuProtectionInit() {
    nxEnabled = rdmsr(msrEFER) & (1 << 11) != 0
    let leaf7 = cpuid(7, 0)
    let smep = cpuid(0, 0).eax >= 7 && leaf7.ebx & (1 << 7) != 0
    let smap = cpuid(0, 0).eax >= 7 && leaf7.ebx & (1 << 20) != 0
    var cr4 = read_cr4()
    if smep { cr4 |= 1 << 20 }
    if smap { cr4 |= 1 << 21 }
    write_cr4(cr4)
    smepEnabled = smep
    smapEnabled = smap
}

/// Bracket a kernel access to user pages (SMAP). Must not switch tasks in
/// between: AC lives in RFLAGS, which context_switch doesn't carry.
@inline(__always) func userAccessBegin() { if smapEnabled { stac() } }
@inline(__always) func userAccessEnd() { if smapEnabled { clac() } }

/// Load the kernel's page tables if this CPU isn't already on them.
func enterKernelAddressSpace() {
    if read_cr3() != kernelCR3 { write_cr3(kernelCR3) }
}

// MARK: AddressSpace (6A1)

final class AddressSpace {
    /// Physical address of the PML4.
    let root: UInt64
    let isKernel: Bool
    /// Page table frames below slots 1-254 (user spaces), and owned leaf
    /// frames currently mapped.
    private(set) var tableFrames = 0
    private(set) var ownedFrames = 0

    /// The boot PML4 (not freed). Valid after vmmInit.
    static let kernel = AddressSpace(kernelRoot: kernelCR3)

    private init(kernelRoot: UInt64) {
        root = kernelRoot & PTE.address
        isKernel = true
    }

    /// A new user address space with the kernel half shared. Nil without memory.
    init?() {
        guard let f = newTableFrame() else { return nil }
        root = f
        isKernel = false
        let mine = pageTable(f), kernel = pageTable(kernelCR3)
        mine[0] = kernel[0] & ~PTE.user
        for slot in 255..<512 { mine[slot] = kernel[slot] & ~PTE.user }
    }

    deinit {
        guard !isKernel else { return }
        if read_cr3() & PTE.address == root { enterKernelAddressSpace() }
        let pml4 = pageTable(root)
        for s in 1..<255 where pml4[s] & PTE.present != 0 {
            let pdpt = pageTable(pml4[s])
            for i in 0..<512 where pdpt[i] & PTE.present != 0 {
                let pd = pageTable(pdpt[i])
                for j in 0..<512 where pd[j] & PTE.present != 0 {
                    let pt = pageTable(pd[j])
                    for k in 0..<512 where pt[k] & (PTE.present | PTE.owned) == PTE.present | PTE.owned {
                        pmm.free(UInt(pt[k] & PTE.address))
                    }
                    pmm.free(UInt(pd[j] & PTE.address))
                }
                pmm.free(UInt(pdpt[i] & PTE.address))
            }
            pmm.free(UInt(pml4[s] & PTE.address))
        }
        pmm.free(UInt(root))
    }

    /// This space is loaded on the calling CPU.
    var isActive: Bool { read_cr3() & PTE.address == root }

    /// Load it (CR3) on this CPU.
    func activate() {
        if !isActive { write_cr3(root) }
    }

    /// May this space map `virt`? User spaces: slots 1-254. The kernel
    /// space: only the upper half (the lower-half slots are aliases).
    func allowed(_ virt: UInt) -> Bool {
        isKernel ? virt >= 0xFFFF_8000_0000_0000 : (virt >= userSpaceStart && virt < userSpaceEnd)
    }

    /// The 4 KiB leaf entry for `virt`, creating tables if asked. Nil if a
    /// table is missing (and not created), memory ran out, or a huge page
    /// is in the way.
    func leaf(_ virt: UInt, create: Bool) -> UnsafeMutablePointer<UInt64>? {
        var table = pageTable(root)
        var shift: UInt = 39
        while shift > 12 {
            let i = Int((virt >> shift) & 511)
            var e = table[i]
            if e & PTE.present == 0 {
                guard create, let f = newTableFrame() else { return nil }
                e = f | PTE.present | PTE.write | (isKernel ? 0 : PTE.user)
                table[i] = e
                if !isKernel { tableFrames += 1 }
            } else if e & PTE.huge != 0 {
                return nil
            }
            table = pageTable(e)
            shift -= 9
        }
        return table + Int((virt >> 12) & 511)
    }

    func invalidate(_ virt: UInt) {
        if isKernel || isActive { invlpg(UInt64(virt)) }
    }

    /// Map `count` pages from `virt` to `phys` (both page-aligned). Fails,
    /// mapping nothing new, if any page is outside this space's range or
    /// already mapped.
    @discardableResult
    func map(_ virt: UInt, _ phys: UInt, count: Int = 1, flags: PageFlags) -> Bool {
        guard virt % pageSize == 0, phys % pageSize == 0, count > 0 else { return false }
        let bytes = UInt(count) * pageSize
        guard allowed(virt), allowed(virt &+ bytes &- 1), virt &+ bytes > virt else { return false }
        for i in 0..<count {
            if let e = leaf(virt + UInt(i) * pageSize, create: false), e.pointee & PTE.present != 0 { return false }
        }
        var bits = flags.rawValue & PageFlags.all
        if !nxEnabled { bits &= ~PTE.noExec }
        for i in 0..<count {
            let v = virt + UInt(i) * pageSize
            guard let e = leaf(v, create: true) else {
                // Out of memory for a table: undo, leaving the frames to the caller.
                for j in 0..<i {
                    let u = virt + UInt(j) * pageSize
                    guard let p = leaf(u, create: false) else { continue }
                    if p.pointee & PTE.owned != 0 { ownedFrames -= 1 }
                    p.pointee = 0
                    invalidate(u)
                }
                return false
            }
            e.pointee = UInt64(phys + UInt(i) * pageSize) | PTE.present | bits
            if bits & PTE.owned != 0 { ownedFrames += 1 }
        }
        return true
    }

    /// Unmap `count` pages from `virt`, freeing owned frames. Pages that
    /// aren't mapped are skipped.
    func unmap(_ virt: UInt, count: Int = 1) {
        for i in 0..<count {
            let v = virt &+ UInt(i) * pageSize
            guard allowed(v), let e = leaf(v, create: false), e.pointee & PTE.present != 0 else { continue }
            let old = e.pointee
            e.pointee = 0
            invalidate(v)
            if old & PTE.owned != 0 {
                ownedFrames -= 1
                pmm.free(UInt(old & PTE.address))
            }
        }
    }

    /// Where `virt` maps to (any page size), and the leaf's flags. Nil if unmapped.
    func translate(_ virt: UInt) -> (phys: UInt, flags: PageFlags)? {
        var table = pageTable(root)
        var shift: UInt = 39
        while true {
            let e = table[Int((virt >> shift) & 511)]
            guard e & PTE.present != 0 else { return nil }
            if shift == 12 || (shift < 39 && e & PTE.huge != 0) {
                let size: UInt = 1 << shift
                let base = UInt(e & PTE.address) & ~(size - 1)
                return (base | (virt & (size - 1)), PageFlags(rawValue: e & PageFlags.all))
            }
            table = pageTable(e)
            shift -= 9
        }
    }

    /// Change the flags of the mapped pages in the range (the owned bit is
    /// kept). False if any page is outside the range this space may map.
    @discardableResult
    func protect(_ virt: UInt, count: Int = 1, flags: PageFlags) -> Bool {
        var bits = flags.rawValue & PageFlags.all & ~PTE.owned
        if !nxEnabled { bits &= ~PTE.noExec }
        for i in 0..<count {
            let v = virt &+ UInt(i) * pageSize
            guard allowed(v) else { return false }
            guard let e = leaf(v, create: false), e.pointee & PTE.present != 0 else { continue }
            e.pointee = (e.pointee & (PTE.address | PTE.owned)) | PTE.present | bits
            invalidate(v)
        }
        return true
    }

    /// Copy bytes into this space's pages (mapped or not, active or not)
    /// through the identity map. False if a page in the range isn't mapped.
    func write(_ virt: UInt, _ bytes: UnsafeRawBufferPointer) -> Bool {
        var done = 0
        while done < bytes.count {
            let v = virt &+ UInt(done)
            guard let (phys, _) = translate(v) else { return false }
            let n = min(bytes.count - done, Int(pageSize - (v % pageSize)))
            UnsafeMutableRawPointer(bitPattern: phys)!.copyMemory(from: bytes.baseAddress! + done, byteCount: n)
            done += n
        }
        return true
    }
}

// MARK: MMIO (6A3)

var mmioNext: UInt = mmioWindowBase

/// Map `size` bytes of device memory at `phys` uncached, writable and NX
/// into the kernel's MMIO window. Nil if the window or memory runs out.
func mapMMIO(_ phys: UInt, _ size: Int) -> UnsafeMutableRawPointer? {
    guard size > 0 else { return nil }
    let first = phys & ~(pageSize - 1)
    let pages = Int((phys + UInt(size) - first + pageSize - 1) / pageSize)
    let flags = kernelMapLock.acquireIRQ()
    defer { kernelMapLock.releaseIRQ(flags) }
    let virt = mmioNext
    guard UInt(pages + 1) * pageSize <= mmioWindowBase &+ mmioWindowSize &- virt,
          AddressSpace.kernel.map(virt, first, count: pages, flags: [.write, .noExec, .uncached]) else { return nil }
    mmioNext = virt + UInt(pages + 1) * pageSize // and an unmapped page after it
    return UnsafeMutableRawPointer(bitPattern: virt + (phys - first))
}

// MARK: Stack guard pages (6A4)

/// Split the huge page holding `entry` (a PDPT entry for 1 GiB, a PD entry
/// for 2 MiB) into a table of the next size down with the same mappings.
func splitHuge(_ entry: UnsafeMutablePointer<UInt64>, oneGiB: Bool) -> Bool {
    let e = entry.pointee
    guard let table = newTableFrame() else { return false }
    let t = pageTable(table)
    let pat = e & PTE.hugePAT != 0
    let keep = e & (PTE.present | PTE.write | PTE.user | PTE.writeThrough | PTE.cacheDisable | PTE.accessed
                    | PTE.dirty | PTE.global | PTE.noExec)
    if oneGiB {
        let base = e & PTE.address & ~UInt64((1 << 30) - 1)
        for i in 0..<512 { t[i] = (base + UInt64(i) << 21) | keep | PTE.huge | (pat ? PTE.hugePAT : 0) }
    } else {
        let base = e & PTE.address & ~UInt64((1 << 21) - 1)
        for i in 0..<512 { t[i] = (base + UInt64(i) << 12) | keep | (pat ? PTE.huge : 0) }
    }
    let dir = e & (PTE.present | PTE.write | PTE.user | PTE.writeThrough | PTE.cacheDisable | PTE.accessed | PTE.noExec)
    entry.pointee = table | dir
    return true
}

/// The 4 KiB identity-map entry for physical frame `phys`, splitting huge
/// pages on the way. Under kernelMapLock.
func identityLeaf(_ phys: UInt) -> UnsafeMutablePointer<UInt64>? {
    var table = pageTable(kernelCR3)
    var shift: UInt = 39
    while shift > 12 {
        let entry = table + Int((phys >> shift) & 511)
        guard entry.pointee & PTE.present != 0 else { return nil }
        if shift < 39 && entry.pointee & PTE.huge != 0 {
            guard splitHuge(entry, oneGiB: shift == 30) else { return nil }
            splitPages += 1
        }
        table = pageTable(entry.pointee)
        shift -= 9
    }
    return table + Int((phys >> 12) & 511)
}

/// Huge pages split so far (each cost one page table frame).
var splitPages = 0

/// Make the identity mapping of frame `phys` absent (a guard page below a
/// stack) or present again. The HHDM alias shares the tables, so it follows.
@discardableResult
func setGuardPage(_ phys: UInt, guarded: Bool) -> Bool {
    guard kernelCR3 != 0 else { return false } // before vmmInit
    let flags = kernelMapLock.acquireIRQ()
    defer { kernelMapLock.releaseIRQ(flags) }
    guard let e = identityLeaf(phys) else { return false }
    if guarded { e.pointee &= ~PTE.present } else { e.pointee |= PTE.present }
    invlpg(UInt64(phys))
    invlpg(UInt64(phys &+ pmm.hhdmOffset))
    return true
}

/// For selftests: is `phys` mapped in the identity map right now?
func identityMapped(_ phys: UInt) -> Bool {
    AddressSpace.kernel.translate(phys) != nil
}
