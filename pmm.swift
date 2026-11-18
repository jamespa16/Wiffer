// Physical frame allocator: one bit per 4 KiB frame (1 = used), covering
// physical addresses 0 up to the end of the highest USABLE memmap entry.
// The bitmap lives in the first USABLE region big enough to hold it and is
// accessed through the HHDM. Only USABLE entries are ever handed out, so
// BOOTLOADER_RECLAIMABLE memory (Limine responses, our stack) stays intact.
//
// This code must not allocate: it runs underneath the Swift heap.
// allocate/free hold pmmLock (IRQ-saving spinlock, spinlock.swift).

let frameSize = 4096

/// Kernel image address H is also mapped at H - kernelAliasOffset (see
/// mapLowerHalf). Must match the String literal rewrite in build.sh.
let kernelAliasOffset: UInt = 0xffff_8000_0000_0000

struct FrameAllocator {
    /// Virtual address of physical 0 (Limine HHDM offset).
    var hhdmOffset: UInt = 0
    var bitmap: UnsafeMutablePointer<UInt64>? = nil
    /// Number of frames the bitmap covers (index = phys / frameSize).
    var frameCount = 0
    /// USABLE frames (the bitmap's own frames count as used).
    var totalFrames = 0
    var usedFrames = 0
    var bitmapPhys: UInt = 0
    var bitmapFrames = 0
    /// Next-fit search start.
    var hint = 0

    var freeFrames: Int { totalFrames - usedFrames }

    /// HHDM virtual address of a physical address.
    func virt(_ phys: UInt) -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(bitPattern: phys &+ hhdmOffset)!
    }

    /// Physical address of an HHDM virtual address.
    func phys(_ virt: UnsafeMutableRawPointer) -> UInt {
        UInt(bitPattern: virt) &- hhdmOffset
    }

    func isUsed(_ i: Int) -> Bool {
        bitmap![i >> 6] & (1 << UInt64(i & 63)) != 0
    }

    func setUsed(_ i: Int, _ used: Bool) {
        if used { bitmap![i >> 6] |= 1 << UInt64(i & 63) }
        else { bitmap![i >> 6] &= ~(1 << UInt64(i & 63)) }
    }

    /// Build the bitmap from the Limine memory map and identity-map the lower
    /// half. Returns false if the memmap/HHDM responses are missing, no region
    /// can hold the bitmap, or the lower-half mapping can't be installed.
    mutating func initialize() -> Bool {
        guard let hhdm = hhdm_request.response,
              let resp = memmap_request.response, let entries = resp.pointee.entries
        else { return false }
        hhdmOffset = UInt(hhdm.pointee.offset)
        let count = Int(resp.pointee.entry_count)

        var top: UInt64 = 0
        for i in 0..<count {
            guard let e = entries[i], e.pointee.type == UInt64(LIMINE_MEMMAP_USABLE) else { continue }
            top = max(top, e.pointee.base + e.pointee.length)
        }
        frameCount = Int(top / UInt64(frameSize))
        let words = (frameCount + 63) / 64
        bitmapFrames = (words * 8 + frameSize - 1) / frameSize

        // Place the bitmap at the start of the first USABLE region that fits.
        var placed = false
        for i in 0..<count {
            guard let e = entries[i], e.pointee.type == UInt64(LIMINE_MEMMAP_USABLE) else { continue }
            let base = max((e.pointee.base + UInt64(frameSize - 1)) & ~UInt64(frameSize - 1),
                           UInt64(frameSize)) // never at physical 0
            let end = e.pointee.base + e.pointee.length
            if base < end && end - base >= UInt64(bitmapFrames * frameSize) {
                bitmapPhys = UInt(base)
                placed = true
                break
            }
        }
        guard placed else { return false }
        bitmap = virt(bitmapPhys).bindMemory(to: UInt64.self, capacity: words)

        // Everything used, then free the whole frames inside USABLE entries.
        for w in 0..<words { bitmap![w] = ~0 }
        totalFrames = 0
        for i in 0..<count {
            guard let e = entries[i], e.pointee.type == UInt64(LIMINE_MEMMAP_USABLE) else { continue }
            let first = Int((e.pointee.base + UInt64(frameSize - 1)) / UInt64(frameSize))
            let last = Int((e.pointee.base + e.pointee.length) / UInt64(frameSize))
            var f = first
            while f < last { setUsed(f, false); f += 1 }
            if last > first { totalFrames += last - first }
        }
        // Frame 0 stays reserved so physical address 0 is never handed out.
        if frameCount > 0 && !isUsed(0) { setUsed(0, true); totalFrames -= 1 }
        // Reserve the bitmap's own frames.
        let bitmapFirst = Int(bitmapPhys) / frameSize
        for f in bitmapFirst..<(bitmapFirst + bitmapFrames) { setUsed(f, true) }
        usedFrames = bitmapFrames
        hint = bitmapFirst + bitmapFrames
        return mapLowerHalf()
    }

    /// Install two lower-half aliases by copying top-level page-table entries
    /// (no new page tables; the PDPTs are shared):
    ///
    /// - PML4[0] = the HHDM's entry: physical memory identity-mapped at
    ///   virtual == physical. The heap hands out these addresses.
    /// - PML4[255] = PML4[511]: the kernel image (0xffffffff80000000+) is
    ///   also readable at H - kernelAliasOffset (0x00007fff80000000+).
    ///   build.sh rewrites String literal constants to use this alias.
    ///
    /// Why: Swift uses the top bits of pointers as spare/discriminator bits
    /// (String's _StringObject keeps only the low 60 bits of its address and
    /// puts flags in the top nibble; multi-payload enums store tags there).
    /// So heap objects and String literals must sit at low, user-space-like
    /// addresses, not at 0xffff8000_0000_0000+.
    func mapLowerHalf() -> Bool {
        let span: UInt = 1 << 39 // one PML4 entry covers 512 GiB
        guard hhdmOffset % span == 0 else { return false }
        let cr3 = read_cr3()
        let pml4 = virt(UInt(cr3 & 0x000F_FFFF_FFFF_F000)).assumingMemoryBound(to: UInt64.self)
        func alias(_ to: Int, _ from: Int) -> Bool {
            let entry = pml4[from]
            guard entry & 1 != 0 else { return false }
            if pml4[to] & 1 == 0 { pml4[to] = entry; return true }
            // Already present: fine only if it is the same alias.
            return pml4[to] & 0x000F_FFFF_FFFF_F000 == entry & 0x000F_FFFF_FFFF_F000
        }
        let kernelSlot = 511, kernelAliasSlot = 255
        let kernelSlotBase: UInt = 0xffff_0000_0000_0000 | UInt(kernelSlot) << 39 // sign-extended
        guard UInt(kernelAliasSlot) << 39 == kernelSlotBase &- kernelAliasOffset,
              alias(0, Int((hhdmOffset / span) & 511)),
              alias(kernelAliasSlot, kernelSlot) else { return false }
        write_cr3(cr3) // flush the TLB
        return true
    }

    /// Identity-mapped (lower-half) pointer for a physical address.
    func identity(_ phys: UInt) -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(bitPattern: phys)!
    }

    /// Allocate `count` physically contiguous frames. Returns the physical
    /// address of the first, or nil if no run is free.
    mutating func allocate(count: Int = 1) -> UInt? {
        guard count > 0, bitmap != nil else { return nil }
        let flags = pmmLock.acquireIRQ()
        defer { pmmLock.releaseIRQ(flags) }
        guard count <= freeFrames else { return nil }
        // Two passes: from the hint to the end, then from 0.
        for pass in 0..<2 {
            var i = pass == 0 ? hint : 0
            let limit = pass == 0 ? frameCount : min(hint + count, frameCount)
            var runStart = i, runLength = 0
            while i < limit {
                // Skip fully used words quickly when not inside a run.
                if runLength == 0 && i & 63 == 0 && bitmap![i >> 6] == ~0 {
                    i += 64
                    runStart = i
                    continue
                }
                if isUsed(i) {
                    runLength = 0
                    runStart = i + 1
                } else {
                    runLength += 1
                    if runLength == count {
                        for f in runStart..<(runStart + count) { setUsed(f, true) }
                        usedFrames += count
                        hint = runStart + count
                        return UInt(runStart * frameSize)
                    }
                }
                i += 1
            }
        }
        return nil
    }

    /// Free `count` frames starting at physical address `phys`.
    mutating func free(_ phys: UInt, count: Int = 1) {
        let flags = pmmLock.acquireIRQ()
        defer { pmmLock.releaseIRQ(flags) }
        let first = Int(phys) / frameSize
        guard phys % UInt(frameSize) == 0, count > 0, first + count <= frameCount else {
            puts("pmm: bad free at "); printHex(UInt64(phys)); newline()
            return
        }
        for f in first..<(first + count) {
            if !isUsed(f) {
                puts("pmm: double free of frame "); printHex(UInt64(f * frameSize)); newline()
                continue
            }
            setUsed(f, false)
            usedFrames -= 1
        }
        if first < hint { hint = first }
    }
}

var pmm = FrameAllocator()
