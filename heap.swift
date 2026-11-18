// Kernel heap behind the Embedded Swift allocation hooks.
//
// Small requests (payload <= 2 KiB) use power-of-two size classes 16 B .. 2 KiB,
// each with its own free list. A class block is a 16-byte header followed by
// the class-sized payload; blocks are carved from 16 KiB chunks of contiguous
// frames taken from the frame allocator (and never returned to it).
// Heap memory is addressed through the lower-half identity map (virtual ==
// physical), not the HHDM: see FrameAllocator.mapLowerHalf for why.
// Larger requests get their own run of whole frames, returned to the frame
// allocator on free.
//
// Every returned pointer is preceded by a BlockHeader that records the class
// (or the frame count for large blocks), because `_swift_deallocate` may be
// called with size == -1. Alignments above 16 are honoured by sliding the
// payload forward inside a bigger block; the header records that padding.
//
// This code must not allocate (no classes, arrays, strings, or print).
// The allocation hooks hold heapLock (IRQ-saving spinlock, spinlock.swift);
// refills and large blocks then take pmmLock inside it.

let heapMagicLive: UInt32 = 0x4845_4150   // "HEAP"
let heapMagicFree: UInt32 = 0x4652_4545   // "FREE"
let heapLargeKind: UInt32 = 0xFFFF_FFFF
let heapClassCount = 8                    // 16, 32, ..., 2048
let heapMinClass = 16
let heapMaxClass = 2048
let heapChunkFrames = 4                   // 16 KiB refill chunks

/// 16 bytes, immediately before every pointer handed to Swift.
struct BlockHeader {
    var magic: UInt32
    /// Size-class index, or heapLargeKind.
    var kind: UInt32
    /// Bytes between the start of the block and this header.
    var padding: UInt32
    /// Frames backing a large block (0 for class blocks).
    var frames: UInt32
}

struct Heap {
    /// Free-list heads per class (address of a free block, 0 = empty).
    var freeLists = InlineArray<8, UInt>(repeating: 0)
    /// Live blocks per class.
    var liveBlocks = InlineArray<8, Int>(repeating: 0)
    var largeBlocks = 0
    var largeFrames = 0
    /// Frames taken from the frame allocator for class chunks.
    var chunkFrames = 0
    var allocations = 0
    var deallocations = 0

    static func classSize(_ index: Int) -> Int { heapMinClass << index }

    /// Bytes held by live allocations (class size or whole frames).
    var bytesInUse: Int {
        var total = largeFrames * frameSize
        for i in 0..<heapClassCount { total += liveBlocks[i] * Heap.classSize(i) }
        return total
    }

    var liveCount: Int {
        var total = largeBlocks
        for i in 0..<heapClassCount { total += liveBlocks[i] }
        return total
    }

    /// Carve a fresh chunk of frames into blocks for class `index`.
    mutating func refill(_ index: Int) -> Bool {
        var frames = heapChunkFrames
        var phys = pmm.allocate(count: frames)
        if phys == nil { frames = 1; phys = pmm.allocate(count: 1) }
        guard let phys else { return false }
        chunkFrames += frames
        let blockSize = 16 + Heap.classSize(index)
        let base = phys // identity-mapped: see FrameAllocator.mapLowerHalf
        let n = frames * frameSize / blockSize
        // Push in reverse so blocks come out in address order.
        var k = n
        while k > 0 {
            k -= 1
            pushFree(index, base + UInt(k * blockSize))
        }
        return true
    }

    mutating func allocate(size: Int, alignment: Int) -> UnsafeMutableRawPointer? {
        let align = max(alignment, 16)
        guard align & (align - 1) == 0, size >= 0, size <= Int.max / 2 else { return nil }
        let slack = align - 16 // worst-case payload shift to reach `align`
        let need = max(size, 1) + slack

        var block: UInt
        var kind: UInt32
        var frames = 0
        if need <= heapMaxClass {
            var index = 0
            while Heap.classSize(index) < need { index += 1 }
            if freeLists[index] == 0 && !refill(index) { return nil }
            block = freeLists[index]
            freeLists[index] = link(block).pointee
            liveBlocks[index] += 1
            kind = UInt32(index)
        } else {
            frames = (16 + need + frameSize - 1) / frameSize
            guard let phys = pmm.allocate(count: frames) else { return nil }
            block = phys
            largeBlocks += 1
            largeFrames += frames
            kind = heapLargeKind
        }
        let payload = (block + 16 + UInt(align - 1)) & ~UInt(align - 1)
        let header = UnsafeMutablePointer<BlockHeader>(bitPattern: payload - 16)!
        header.pointee = BlockHeader(magic: heapMagicLive, kind: kind,
                                     padding: UInt32(payload - 16 - block),
                                     frames: UInt32(frames))
        allocations += 1
        return UnsafeMutableRawPointer(bitPattern: payload)
    }

    mutating func deallocate(_ ptr: UnsafeMutableRawPointer) {
        let payload = UInt(bitPattern: ptr)
        let header = UnsafeMutablePointer<BlockHeader>(bitPattern: payload - 16)!
        let h = header.pointee
        guard h.magic == heapMagicLive,
              h.kind == heapLargeKind || h.kind < UInt32(heapClassCount) else {
            puts(h.magic == heapMagicFree ? "heap: double free at " : "heap: bad free at ")
            printHex(UInt64(payload)); newline()
            return
        }
        header.pointee.magic = heapMagicFree
        let block = payload - 16 - UInt(h.padding)
        deallocations += 1
        if h.kind == heapLargeKind {
            largeBlocks -= 1
            largeFrames -= Int(h.frames)
            pmm.free(block, count: Int(h.frames))
        } else {
            let index = Int(h.kind)
            liveBlocks[index] -= 1
            pushFree(index, block)
        }
    }

    // A free block's link lives at block+8: inside the block, but clear of
    // the header's magic word (at block+0 when padding is 0, else >= block+16),
    // so a second free of the same pointer still sees heapMagicFree.
    func link(_ block: UInt) -> UnsafeMutablePointer<UInt> {
        UnsafeMutablePointer<UInt>(bitPattern: block + 8)!
    }

    mutating func pushFree(_ index: Int, _ block: UInt) {
        link(block).pointee = freeLists[index]
        freeLists[index] = block
    }
}

var heap = Heap()

// MARK: Embedded Swift platform hooks (EmbeddedPlatform.h)

@_cdecl("_swift_allocate")
public func swiftAllocate(_ alignment: UInt, _ size: UInt, _ flags: UInt64) -> UnsafeMutableRawPointer? {
    guard size <= UInt(Int.max / 2), alignment <= UInt(Int.max / 2) else { return nil }
    let saved = heapLock.acquireIRQ()
    defer { heapLock.releaseIRQ(saved) }
    let p = heap.allocate(size: Int(size), alignment: Int(alignment))
    if let p, flags & 1 != 0 { // SWIFT_ALLOC_ZERO_MEMORY
        p.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
    }
    return p
}

@_cdecl("_swift_deallocate")
public func swiftDeallocate(_ ptr: UnsafeMutableRawPointer, _ alignment: UInt, _ size: UInt, _ flags: UInt64) {
    let saved = heapLock.acquireIRQ()
    defer { heapLock.releaseIRQ(saved) }
    heap.deallocate(ptr)
}
