// Phase M2: unpack the boot module (a ustar archive of rootfs/, made by
// build.sh) into the RAM filesystem.
//
// ustar is a sequence of 512-byte headers, each followed by the file's data
// rounded up to 512 bytes, ending in zero blocks. Header fields used here:
//   0   name[100]   124 size[12] (octal)   148 chksum[8] (octal)
//   156 typeflag    257 magic "ustar"      345 prefix[155]
// Module memory is HHDM (and BOOTLOADER-owned): every name and file body is
// copied into heap Strings / arrays, and no pointer into it is kept.

enum UstarError: Error, Equatable {
    /// A header or file body runs past the end of the archive.
    case truncated(offset: Int)
    /// Not a ustar header (no magic), or the checksum doesn't match.
    case badHeader(offset: Int)
    /// The archive's paths clash with the tree (e.g. a file where a directory
    /// is needed).
    case conflict(offset: Int, FSError)

    var message: String {
        switch self {
        case .truncated(let at): return "truncated at byte \(at)"
        case .badHeader(let at): return "bad header at byte \(at)"
        case .conflict(let at, let e): return "entry at byte \(at): \(e.message)"
        }
    }
}

struct UstarStats: Equatable {
    var files = 0
    var directories = 0
    var bytes = 0
    /// Entries of other types (links, devices, ...), ignored.
    var skipped = 0
}

let ustarBlock = 512

/// Parse an octal header field: optional leading spaces, digits, then NUL or
/// space. nil if there are no digits or a stray character.
func ustarOctal(_ field: UnsafeRawBufferPointer) -> Int? {
    var value = 0
    var digits = 0
    var i = 0
    while i < field.count && field[i] == 0x20 { i += 1 }
    while i < field.count {
        let b = field[i]
        if b == 0 || b == 0x20 { break }
        guard b >= 0x30 && b <= 0x37, value < Int.max >> 3 else { return nil }
        value = value << 3 | Int(b - 0x30)
        digits += 1
        i += 1
    }
    return digits > 0 ? value : nil
}

/// A NUL-terminated (or full-width) header string, copied to the heap.
func ustarString(_ field: UnsafeRawBufferPointer) -> String {
    var n = 0
    while n < field.count && field[n] != 0 { n += 1 }
    return String(decoding: UnsafeRawBufferPointer(rebasing: field[0..<n]), as: UTF8.self)
}

/// The header checksum: every byte summed, the checksum field counted as spaces.
func ustarChecksum(_ header: UnsafeRawBufferPointer) -> Int {
    var sum = 0
    for i in 0..<ustarBlock { sum += (i >= 148 && i < 156) ? 0x20 : Int(header[i]) }
    return sum
}

/// Unpack every file and directory in `tar` into `fs`, under its root.
/// Existing files are overwritten; missing parent directories are made.
@discardableResult
func unpackUstar(_ tar: UnsafeRawBufferPointer, into fs: FileSystem) throws(UstarError) -> UstarStats {
    var stats = UstarStats()
    var at = 0
    while at + ustarBlock <= tar.count {
        let header = UnsafeRawBufferPointer(rebasing: tar[at..<at + ustarBlock])
        if !header.contains(where: { $0 != 0 }) { return stats } // end-of-archive block
        func field(_ start: Int, _ length: Int) -> UnsafeRawBufferPointer {
            UnsafeRawBufferPointer(rebasing: header[start..<start + length])
        }
        let magic = field(257, 5)
        guard magic.elementsEqual([0x75, 0x73, 0x74, 0x61, 0x72]), // "ustar"
              let size = ustarOctal(field(124, 12)), let sum = ustarOctal(field(148, 8)),
              sum == ustarChecksum(header) else {
            throw .badHeader(offset: at)
        }
        let body = at + ustarBlock
        guard size <= tar.count - body else { throw .truncated(offset: at) }

        var path = ustarString(field(0, 100))
        let prefix = ustarString(field(345, 155))
        if !prefix.isEmpty { path = prefix + "/" + path }
        let parts = FileSystem.components(path)

        do throws(FSError) {
            switch header[156] {
            case 0x30, 0x00, 0x37: // '0', NUL (old tar), '7' contiguous: a regular file
                if !parts.isEmpty {
                    try fs.mkdir(FileSystem.join(Array(parts.dropLast())), parents: true)
                    let bytes = Array(UnsafeRawBufferPointer(rebasing: tar[body..<body + size]))
                    try fs.write(FileSystem.join(parts), bytes)
                    stats.files += 1
                    stats.bytes += size
                }
            case 0x35: // '5': directory ("./" is the root, already there)
                if !parts.isEmpty {
                    try fs.mkdir(FileSystem.join(parts), parents: true)
                    stats.directories += 1
                }
            default:
                stats.skipped += 1
            }
        } catch {
            throw .conflict(offset: at, error)
        }
        at = body + (size + ustarBlock - 1) / ustarBlock * ustarBlock
    }
    // No end-of-archive blocks: accept it if it ended on an entry boundary.
    guard at == tar.count else { throw .truncated(offset: at) }
    return stats
}

/// The boot module to unpack: the one whose cmdline (limine.conf
/// module_string) is "rootfs", else the first.
func rootfsModule() -> UnsafeRawBufferPointer? {
    guard let resp = module_request.response, let modules = resp.pointee.modules else { return nil }
    let count = Int(resp.pointee.module_count)
    var chosen: UnsafeMutablePointer<limine_file>? = nil
    for i in 0..<count {
        guard let f = modules[i] else { continue }
        if chosen == nil { chosen = f }
        if let s = f.pointee.string, cStringIs(s, "rootfs") { chosen = f; break }
    }
    guard let f = chosen, let base = f.pointee.address else { return nil }
    return UnsafeRawBufferPointer(start: base, count: Int(f.pointee.size))
}

func cStringIs(_ s: UnsafePointer<CChar>, _ want: StaticString) -> Bool {
    want.withUTF8Buffer { w in
        for i in 0..<w.count where UInt8(bitPattern: s[i]) != w[i] { return false }
        return s[w.count] == 0
    }
}

/// Boot step (after the heap is up): seed the RAM fs from the rootfs module
/// and show /motd.
func fsInit() {
    let fs = vfs
    guard let tar = rootfsModule() else {
        print("fs: no rootfs module; starting empty")
        return
    }
    do throws(UstarError) {
        let s = try unpackUstar(tar, into: fs)
        print("fs: rootfs.tar: \(s.files) files, \(s.directories) directories, \(s.bytes) bytes")
    } catch {
        print("fs: rootfs.tar: \(error.message)")
    }
    if let motd = try? fs.read("/motd") {
        for b in motd {
            if b == 0x0A { putc(0x0D) }
            putc(b)
        }
    }
}
