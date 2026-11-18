// Phase 6C1: loading static x86-64 ELF executables into an address space.
//
// Only ET_EXEC, EM_X86_64, 64-bit little-endian, with every PT_LOAD inside
// user space (PML4 slots 1-254) and none both writable and executable (W^X).
// No PT_INTERP or PT_DYNAMIC. Each segment's pages get fresh zeroed frames
// (owned by the space) with the segment's own permissions, and its file
// bytes are copied in through the identity map; the rest is .bss. Two
// segments may not share a page (user/user.ld page-aligns them). The file
// is untrusted: every offset and size is checked before use.

/// Why exec failed.
enum ExecError: Error {
    case notFound
    case notExecutable(StaticString)
    case noMemory
    case tooManyArguments

    var message: String {
        switch self {
        case .notFound: return "no such file"
        case .notExecutable(let why): return "not an executable: \(why)"
        case .noMemory: return "out of memory"
        case .tooManyArguments: return "argument list too long"
        }
    }
}

/// A user memory region: [start, end), page-aligned, with MapProt bits.
/// Absent pages inside one are allocated (zeroed) on first touch.
struct MemoryRegion: Equatable {
    var start: UInt
    var end: UInt
    var prot: UInt64

    /// Page flags for this region's pages.
    var flags: PageFlags { regionFlags(prot) }
}

func regionFlags(_ prot: UInt64) -> PageFlags {
    var f: PageFlags = [.user, .owned]
    if prot & MapProt.write != 0 { f.insert(.write) }
    if prot & MapProt.exec == 0 { f.insert(.noExec) }
    return f
}

/// What the stack's auxv and the entry need.
struct LoadedImage {
    var entry: UInt64 = 0
    var phdr: UInt64 = 0
    var phnum: UInt64 = 0
    var regions: [MemoryRegion] = []
}

/// Little-endian reads; the caller checked `o + size <= b.count`.
@inline(__always) func le(_ b: [UInt8], _ o: Int, _ size: Int) -> UInt64 {
    var v: UInt64 = 0
    for i in (0..<size).reversed() { v = v << 8 | UInt64(b[o + i]) }
    return v
}

let elfMaxFile = 64 << 20
let elfMaxPhnum = 64

/// Map `pages` zeroed, owned frames at `virt` with `flags`. False (with
/// what was mapped left to the space's deinit) when memory runs out.
func mapZeroed(_ space: AddressSpace, _ virt: UInt, pages: Int, flags: PageFlags) -> Bool {
    for i in 0..<pages {
        guard let f = pmm.allocate() else { return false }
        UnsafeMutableRawPointer(bitPattern: f)!.initializeMemory(as: UInt8.self, repeating: 0, count: frameSize)
        guard space.map(virt + UInt(i) * pageSize, f, flags: flags) else {
            pmm.free(f)
            return false
        }
    }
    return true
}

func loadELF(_ file: [UInt8], into space: AddressSpace) throws(ExecError) -> LoadedImage {
    guard file.count >= 64, file.count <= elfMaxFile else { throw .notExecutable("bad size") }
    guard file[0] == 0x7F, file[1] == 0x45, file[2] == 0x4C, file[3] == 0x46 else { throw .notExecutable("no ELF magic") }
    guard file[4] == 2, file[5] == 1, file[6] == 1 else { throw .notExecutable("not 64-bit little-endian ELF") }
    guard le(file, 16, 2) == 2 else { throw .notExecutable("not ET_EXEC") }
    guard le(file, 18, 2) == 62 else { throw .notExecutable("not x86-64") }
    let entry = le(file, 24, 8)
    let phoff = le(file, 32, 8)
    let phentsize = le(file, 54, 2)
    let phnum = le(file, 56, 2)
    guard phentsize == 56, phnum >= 1, phnum <= UInt64(elfMaxPhnum),
          phoff <= UInt64(file.count), UInt64(file.count) - phoff >= phnum * 56 else {
        throw .notExecutable("bad program headers")
    }
    var image = LoadedImage()
    image.entry = entry
    image.phnum = phnum
    var entryOK = false
    var phdrFromLoad: UInt64 = 0
    for k in 0..<Int(phnum) {
        let h = Int(phoff) + k * 56
        let type = le(file, h, 4)
        let flags = le(file, h + 4, 4)
        let offset = le(file, h + 8, 8)
        let vaddr = le(file, h + 16, 8)
        let filesz = le(file, h + 32, 8)
        let memsz = le(file, h + 40, 8)
        switch type {
        case 3, 2: throw .notExecutable("dynamically linked") // PT_INTERP, PT_DYNAMIC
        case 6: image.phdr = vaddr // PT_PHDR
        case 1: break // PT_LOAD, below
        default: continue
        }
        guard type == 1, memsz > 0 else { continue }
        guard filesz <= memsz, offset <= UInt64(file.count), UInt64(file.count) - offset >= filesz else {
            throw .notExecutable("segment outside the file")
        }
        guard vaddr <= UInt64(UInt.max) - memsz, isUserRange(UInt(vaddr), UInt(memsz)) else {
            throw .notExecutable("segment outside user space")
        }
        let w = flags & 2 != 0, x = flags & 1 != 0
        guard !(w && x) else { throw .notExecutable("segment both writable and executable") }
        let start = UInt(vaddr) & ~(pageSize - 1)
        let end = (UInt(vaddr + memsz) + pageSize - 1) & ~(pageSize - 1)
        let pages = Int((end - start) / pageSize)
        guard pages <= pmm.freeFrames else { throw .noMemory }
        for i in 0..<pages where space.translate(start + UInt(i) * pageSize) != nil {
            throw .notExecutable("segments share a page")
        }
        let prot = MapProt.read | (w ? MapProt.write : 0) | (x ? MapProt.exec : 0)
        guard mapZeroed(space, start, pages: pages, flags: regionFlags(prot)) else { throw .noMemory }
        if filesz > 0 {
            let ok = file.withUnsafeBytes { raw in
                space.write(UInt(vaddr), UnsafeRawBufferPointer(rebasing: raw[Int(offset)..<Int(offset + filesz)]))
            }
            guard ok else { throw .noMemory }
        }
        image.regions.append(MemoryRegion(start: start, end: end, prot: prot))
        if x && entry >= vaddr && entry < vaddr + memsz { entryOK = true }
        if phoff >= offset && phoff - offset < filesz { phdrFromLoad = vaddr + (phoff - offset) }
    }
    guard !image.regions.isEmpty else { throw .notExecutable("nothing to load") }
    guard entryOK else { throw .notExecutable("entry point outside the code") }
    if image.phdr == 0 { image.phdr = phdrFromLoad }
    return image
}

/// Lay out the initial stack (SysV): argc, argv pointers, NULL, an empty
/// envp (NULL), auxv pairs, then the argument strings above. Maps the pages
/// it uses; the rest of the stack region is allocated on demand. Returns
/// the initial rsp (16-byte aligned, pointing at argc).
func buildInitialStack(_ space: AddressSpace, argv: [String], image: LoadedImage) throws(ExecError) -> UInt64 {
    guard argv.count <= UserLayout.maxArgs else { throw .tooManyArguments }
    var strings: [UInt8] = []
    var offsets: [Int] = []
    for a in argv {
        offsets.append(strings.count)
        strings.append(contentsOf: a.utf8)
        strings.append(0)
        guard strings.count <= UserLayout.maxArgBytes else { throw .tooManyArguments }
    }
    let top = UInt(UserLayout.stackTop)
    let stringsAt = (top - UInt(strings.count)) & ~15
    var words: [UInt64] = [UInt64(argv.count)]
    for o in offsets { words.append(UInt64(stringsAt) + UInt64(o)) }
    words.append(0) // argv end
    words.append(0) // envp end
    let aux: [(UInt64, UInt64)] = [(AuxKey.phdr, image.phdr), (AuxKey.phent, 56), (AuxKey.phnum, image.phnum),
                                   (AuxKey.pagesz, UInt64(pageSize)), (AuxKey.entry, image.entry), (AuxKey.null, 0)]
    for (k, v) in aux { words.append(k); words.append(v) }
    let sp = (stringsAt - UInt(words.count * 8)) & ~15
    let first = sp & ~(pageSize - 1)
    guard mapZeroed(space, first, pages: Int((top - first) / pageSize),
                    flags: regionFlags(MapProt.read | MapProt.write)) else { throw .noMemory }
    let ok = words.withUnsafeBytes { space.write(sp, $0) } && strings.withUnsafeBytes { space.write(stringsAt, $0) }
    guard ok else { throw .noMemory }
    return UInt64(sp)
}
