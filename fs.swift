// Phase M1: an in-memory filesystem (VFS).
//
// A tree of FSNode objects: directories hold children by name, files hold
// their bytes in a heap [UInt8]. Paths are split on "/" and resolved
// lexically ("." and ".." with no symlinks to worry about), either absolute
// or relative to a caller-supplied current directory, which each Shell keeps
// as a path (not a node) so a removed directory can't leave it dangling.
//
// Errors are thrown as FSError (typed throws: no existential `any Error`,
// which Embedded Swift can't box), never traps.
//
// Parent links are strong. The cycles they make are broken when a node
// leaves the tree (remove, or FileSystem's deinit): detach() clears every
// parent link in the subtree, so it frees as soon as nothing else holds it.
//
// Phase Y: mounts. `mount(volume, at:)` loads a whole FAT32 volume into
// FSNodes under an empty directory (the mount point, which holds the
// FATVolume). Reads never touch the disk. Every change below a mount point
// goes to the volume first, and the RAM tree changes only if that succeeded
// (a FATVolume call that throws leaves the disk as it was), so the two stay
// the same. Rules under a mount:
// - Names match with ASCII case folded, as on FAT: `cat /disk/README.TXT`
//   reads /disk/readme.txt, and `write /disk/A` replaces an existing
//   /disk/a, keeping its spelling. Creating (create, mkdir, rename's
//   target) a name that matches a different existing entry gives .exists;
//   renaming an entry to another case of its own name is allowed.
// - touch on an existing file changes only the RAM tick (no disk write).
// - append is a whole-file rewrite (FAT has no partial write).
// - `rm -r` removes bottom-up, one FAT call per entry; an error stops it
//   with what was removed so far gone from both sides.
// - rename only within one mount (else .crossDevice, as is RAM <-> mount);
//   a mount point, or a directory holding one, can't be removed or renamed
//   (.busy).
// Outside mounts nothing changed: lookups are exact, as before.

enum FSError: Error, Equatable {
    case notFound
    case exists
    case notADirectory
    case isADirectory
    case notEmpty
    /// Empty path where a name is needed, or an operation on "/" itself.
    case invalidPath
    /// rename of a directory into itself or one of its descendants.
    case invalidMove
    // Phase Y (mounted volumes):
    /// The disk failed (or a device that timed out earlier).
    case io
    case noSpace
    /// A name the volume can't store (FAT: * ? : " < > | \ and so on).
    case invalidName
    /// The volume's structures don't make sense.
    case corrupt
    /// rename between two filesystems (RAM and a mount, or two mounts).
    case crossDevice
    /// The path is (or holds) a mount point, or is already mounted on.
    case busy
    /// unmount of a directory that isn't a mount point.
    case notMounted

    var message: String {
        switch self {
        case .notFound: return "no such file or directory"
        case .exists: return "already exists"
        case .notADirectory: return "not a directory"
        case .isADirectory: return "is a directory"
        case .notEmpty: return "directory not empty"
        case .invalidPath: return "invalid path"
        case .invalidMove: return "can't move a directory into itself"
        case .io: return "I/O error"
        case .noSpace: return "no space left on device"
        case .invalidName: return "invalid name"
        case .corrupt: return "filesystem is corrupt"
        case .crossDevice: return "can't move across filesystems"
        case .busy: return "mount point busy"
        case .notMounted: return "not a mount point"
        }
    }

    init(_ e: FATError) {
        switch e {
        case .notFound: self = .notFound
        case .exists: self = .exists
        case .notADirectory: self = .notADirectory
        case .isADirectory: self = .isADirectory
        case .notEmpty: self = .notEmpty
        case .invalidName: self = .invalidName
        case .noSpace: self = .noSpace
        case .io: self = .io
        case .corrupt, .notFAT32: self = .corrupt
        }
    }
}

enum FSKind: Equatable {
    case file
    case directory
}

final class FSNode {
    private(set) var name: String
    let kind: FSKind
    /// File bytes (always empty for a directory).
    var contents: [UInt8] = []
    /// Directory entries by name (always empty for a file).
    var children: [String: FSNode] = [:]
    /// nil for the root and for nodes no longer in a tree.
    fileprivate(set) var parent: FSNode?
    /// Timer tick (100 Hz since boot) of the last change.
    var modified: UInt64
    /// Phase Y: the volume mounted on this directory, or nil.
    fileprivate(set) var volume: FATVolume? = nil

    init(name: String, kind: FSKind, modified: UInt64 = ticks) {
        self.name = name
        self.kind = kind
        self.modified = modified
    }

    var isDirectory: Bool { kind == .directory }
    /// Bytes in a file; 0 for a directory.
    var size: Int { contents.count }

    /// Children sorted by name.
    var sortedChildren: [FSNode] {
        var list: [FSNode] = []
        for name in children.keys.sorted() { list.append(children[name]!) }
        return list
    }

    /// The child called `name`; with `folded` (under a mount), matching
    /// with ASCII case folded, as FAT does.
    fileprivate func child(_ name: String, folded: Bool) -> FSNode? {
        if let c = children[name] { return c }
        guard folded else { return nil }
        for (key, c) in children where fatNamesMatch(key, name) { return c }
        return nil
    }

    fileprivate func adopt(_ child: FSNode, as newName: String) {
        child.name = newName
        child.parent = self
        children[newName] = child
        modified = ticks
    }

    /// Take this node out of its parent directory (its subtree stays intact).
    fileprivate func unlink() {
        guard let p = parent else { return }
        p.children[name] = nil
        p.modified = ticks
        parent = nil
    }

    /// Unlink and clear all parent links below, so the subtree has no
    /// cycles left and frees once nothing else holds it.
    fileprivate func detach() {
        unlink()
        clearParents()
    }

    private func clearParents() {
        for (_, child) in children {
            child.parent = nil
            child.clearParents()
        }
    }
}

final class FileSystem {
    let root = FSNode(name: "", kind: .directory)
    /// Phase Y: mount points, in mount order.
    private(set) var mounts: [FSNode] = []

    deinit { root.detach() }

    // MARK: Paths

    /// `path` resolved against `cwd` (itself absolute) into components from
    /// the root, with "." and ".." applied ("/.." is "/").
    static func components(_ path: String, cwd: String = "/") -> [String] {
        var parts: [String] = []
        func apply(_ p: String) {
            for c in p.split(separator: "/") {
                if c == "." { continue }
                if c == ".." {
                    if !parts.isEmpty { parts.removeLast() }
                    continue
                }
                parts.append(String(c))
            }
        }
        if !path.hasPrefix("/") { apply(cwd) }
        apply(path)
        return parts
    }

    /// The canonical absolute form of `path`: "/", or "/a/b".
    static func normalize(_ path: String, cwd: String = "/") -> String {
        join(components(path, cwd: cwd))
    }

    static func join(_ parts: [String]) -> String {
        if parts.isEmpty { return "/" }
        var s = ""
        for p in parts { s += "/" + p }
        return s
    }

    /// Absolute path of a node in this tree.
    func path(of node: FSNode) -> String {
        var parts: [String] = []
        var n = node
        while let p = n.parent {
            parts.append(n.name)
            n = p
        }
        return FileSystem.join(parts.reversed())
    }

    // MARK: Lookup

    func lookup(_ path: String, cwd: String = "/") throws(FSError) -> FSNode {
        try node(FileSystem.components(path, cwd: cwd)[...])
    }

    func exists(_ path: String, cwd: String = "/") -> Bool {
        (try? lookup(path, cwd: cwd)) != nil
    }

    private func node(_ parts: ArraySlice<String>) throws(FSError) -> FSNode {
        var n = root
        var folded = false // below a mount point
        for p in parts {
            guard n.isDirectory else { throw .notADirectory }
            guard let next = n.child(p, folded: folded) else { throw .notFound }
            n = next
            if n.volume != nil { folded = true }
        }
        return n
    }

    /// The directory that would hold `path`, and the last component's name.
    private func parentAndName(_ path: String, cwd: String) throws(FSError) -> (FSNode, String) {
        let parts = FileSystem.components(path, cwd: cwd)
        guard let name = parts.last else { throw .invalidPath }
        let dir = try node(parts.dropLast())
        guard dir.isDirectory else { throw .notADirectory }
        return (dir, name)
    }

    // MARK: Creating

    /// A new empty file. Throws `.exists` if anything is already there.
    @discardableResult
    func create(_ path: String, cwd: String = "/") throws(FSError) -> FSNode {
        try make(path, cwd: cwd, kind: .file)
    }

    /// A new directory. With `parents`, missing directories on the way are
    /// made too, and an existing directory at `path` is not an error.
    @discardableResult
    func mkdir(_ path: String, cwd: String = "/", parents: Bool = false) throws(FSError) -> FSNode {
        guard parents else { return try make(path, cwd: cwd, kind: .directory) }
        var n = root
        var mount: FSNode? = nil
        for p in FileSystem.components(path, cwd: cwd) {
            if let next = n.child(p, folded: mount != nil) {
                guard next.isDirectory else { throw .notADirectory }
                n = next
            } else {
                if let mount {
                    let at = volumePath(n, mount) + [p]
                    try onDisk(mount) { (v: FATVolume) throws(FATError) in try v.mkdir(at) }
                }
                let d = FSNode(name: p, kind: .directory)
                n.adopt(d, as: p)
                n = d
            }
            if n.volume != nil { mount = n }
        }
        return n
    }

    private func make(_ path: String, cwd: String, kind: FSKind) throws(FSError) -> FSNode {
        let (dir, name) = try parentAndName(path, cwd: cwd)
        let mount = mountPoint(of: dir)
        guard dir.child(name, folded: mount != nil) == nil else { throw .exists }
        if let mount {
            let at = volumePath(dir, mount) + [name]
            try onDisk(mount) { (v: FATVolume) throws(FATError) in
                if kind == .file { try v.write(at, []) } else { try v.mkdir(at) }
            }
        }
        let n = FSNode(name: name, kind: kind)
        dir.adopt(n, as: name)
        return n
    }

    /// Create an empty file if there is nothing at `path`, else just mark it
    /// modified now.
    @discardableResult
    func touch(_ path: String, cwd: String = "/") throws(FSError) -> FSNode {
        if let n = try? lookup(path, cwd: cwd) {
            n.modified = ticks
            return n
        }
        return try create(path, cwd: cwd)
    }

    // MARK: Contents

    func read(_ path: String, cwd: String = "/") throws(FSError) -> [UInt8] {
        let n = try lookup(path, cwd: cwd)
        guard !n.isDirectory else { throw .isADirectory }
        return n.contents
    }

    /// Replace (or with `append`, extend) a file's bytes, creating it if
    /// it doesn't exist.
    @discardableResult
    func write(_ path: String, _ bytes: [UInt8], cwd: String = "/", append: Bool = false) throws(FSError) -> FSNode {
        let (dir, name) = try parentAndName(path, cwd: cwd)
        let mount = mountPoint(of: dir)
        let found = dir.child(name, folded: mount != nil)
        if let found, found.isDirectory { throw .isADirectory }
        if let mount { // the whole file, under the existing spelling
            let at = volumePath(dir, mount) + [found?.name ?? name]
            let whole = append ? (found?.contents ?? []) + bytes : bytes
            try onDisk(mount) { (v: FATVolume) throws(FATError) in try v.write(at, whole) }
        }
        let n: FSNode
        if let existing = found {
            n = existing
        } else {
            n = FSNode(name: name, kind: .file)
            dir.adopt(n, as: name)
        }
        if append { n.contents += bytes } else { n.contents = bytes }
        n.modified = ticks
        return n
    }

    // MARK: Removing and renaming

    /// Remove a file or an empty directory (any directory if `recursive`).
    func remove(_ path: String, cwd: String = "/", recursive: Bool = false) throws(FSError) {
        let n = try lookup(path, cwd: cwd)
        guard n.parent != nil else { throw .invalidPath } // the root
        if !mounts.isEmpty {
            guard !holdsMount(n) else { throw .busy }
            guard recursive || n.children.isEmpty else { throw .notEmpty }
            if let mount = mountPoint(of: n) { return try removeOnDisk(n, mount) }
        }
        guard recursive || n.children.isEmpty else { throw .notEmpty }
        n.detach()
    }

    /// Remove `n` and everything below it from its volume, bottom-up, each
    /// entry leaving the RAM tree once it's gone from the disk.
    private func removeOnDisk(_ n: FSNode, _ mount: FSNode) throws(FSError) {
        for c in Array(n.children.values) { try removeOnDisk(c, mount) }
        let at = volumePath(n, mount)
        try onDisk(mount) { (v: FATVolume) throws(FATError) in try v.remove(at) }
        n.detach()
    }

    /// Move `from` to exactly `to` (whose parent directory must exist).
    /// Throws `.exists` if `to` is taken; renaming a path to itself is a no-op.
    func rename(_ from: String, to: String, cwd: String = "/") throws(FSError) {
        let src = FileSystem.components(from, cwd: cwd)
        let dst = FileSystem.components(to, cwd: cwd)
        let n = try node(src[...])
        guard n.parent != nil, !dst.isEmpty else { throw .invalidPath }
        if src == dst { return }
        if dst.count > src.count && Array(dst[..<src.count]) == src { throw .invalidMove }
        let (dir, name) = try parentAndName(to, cwd: cwd)
        if !mounts.isEmpty {
            guard !holdsMount(n) else { throw .busy }
            // Into itself, by nodes: under a mount the paths may differ in case.
            var up: FSNode? = dir
            while let a = up {
                if a === n { throw .invalidMove }
                up = a.parent
            }
            let mount = mountPoint(of: dir)
            guard mountPoint(of: n) === mount else { throw .crossDevice }
            if let t = dir.child(name, folded: mount != nil), t !== n { throw .exists }
            if let mount {
                let old = volumePath(n, mount), new = volumePath(dir, mount) + [name]
                try onDisk(mount) { (v: FATVolume) throws(FATError) in try v.rename(old, to: new) }
            }
        }
        guard dir.children[name] == nil || dir.children[name] === n else { throw .exists }
        n.unlink()
        dir.adopt(n, as: name)
        n.modified = ticks
    }

    /// A directory's entries sorted by name, or a file by itself.
    func list(_ path: String, cwd: String = "/") throws(FSError) -> [FSNode] {
        let n = try lookup(path, cwd: cwd)
        return n.isDirectory ? n.sortedChildren : [n]
    }

    // MARK: Usage

    struct Usage: Equatable {
        var bytes = 0
        var files = 0
        var directories = 0
    }

    /// Totals over the whole tree (the root counts as a directory).
    var usage: Usage {
        var u = Usage()
        func walk(_ n: FSNode) {
            if n.volume != nil { return } // a mount: df shows each volume
            if n.isDirectory {
                u.directories += 1
                for (_, c) in n.children { walk(c) }
            } else {
                u.files += 1
                u.bytes += n.size
            }
        }
        walk(root)
        return u
    }

    // MARK: Mounts (Phase Y)

    /// Load `volume` into FSNodes under the empty directory `path` and send
    /// every later change below it to the volume. Not on "/", not on or
    /// below another mount, and one mount per volume (.busy).
    func mount(_ volume: FATVolume, at path: String, cwd: String = "/") throws(FSError) {
        let n = try lookup(path, cwd: cwd)
        guard n.isDirectory else { throw .notADirectory }
        guard n.parent != nil else { throw .invalidPath }
        guard mountPoint(of: n) == nil, mountPoint(for: volume) == nil else { throw .busy }
        guard n.children.isEmpty else { throw .notEmpty }
        do throws(FATError) {
            try load(volume, volume.rootCluster, into: n, depth: 0)
        } catch {
            for c in Array(n.children.values) { c.detach() }
            throw FSError(error)
        }
        n.volume = volume
        n.modified = ticks
        mounts.append(n)
    }

    /// Sync the volume mounted at `path` and drop its nodes, leaving the
    /// empty directory. Every change was already flushed (write-through),
    /// so a failing sync (FSInfo, flush) is ignored: nothing is lost.
    func unmount(at path: String, cwd: String = "/") throws(FSError) {
        let n = try lookup(path, cwd: cwd)
        guard let v = n.volume else { throw .notMounted }
        _ = try? v.sync()
        for c in Array(n.children.values) { c.detach() }
        n.volume = nil
        n.modified = ticks
        mounts.removeAll(where: { $0 === n })
    }

    /// The mount point holding `volume`, if it's mounted here.
    func mountPoint(for volume: FATVolume) -> FSNode? {
        mounts.first(where: { $0.volume === volume })
    }

    /// The mount point at or above `n` (nil: plain RAM).
    func mountPoint(of n: FSNode) -> FSNode? {
        if mounts.isEmpty { return nil }
        var up: FSNode? = n
        while let a = up {
            if a.volume != nil { return a }
            up = a.parent
        }
        return nil
    }

    /// Is `n` a mount point, or above one?
    private func holdsMount(_ n: FSNode) -> Bool {
        for m in mounts {
            var up: FSNode? = m
            while let a = up {
                if a === n { return true }
                up = a.parent
            }
        }
        return false
    }

    /// `n`'s path from the root of the volume mounted at `mount`.
    private func volumePath(_ n: FSNode, _ mount: FSNode) -> [String] {
        var parts: [String] = []
        var a = n
        while a !== mount, let p = a.parent {
            parts.append(a.name)
            a = p
        }
        return parts.reversed()
    }

    /// Run a volume call for a change under `mount`, as FSError.
    private func onDisk(_ mount: FSNode, _ body: (FATVolume) throws(FATError) -> Void) throws(FSError) {
        guard let v = mount.volume else { return }
        do throws(FATError) { try body(v) } catch { throw FSError(error) }
    }

    /// Copy the directory at `cluster` (and below) into `dir`. A child is
    /// linked in before its own subtree loads, so a failure part-way leaves
    /// one tree that detach() frees. Depth-limited, against directory loops.
    private func load(_ volume: FATVolume, _ cluster: UInt32, into dir: FSNode, depth: Int) throws(FATError) {
        guard depth < 64 else { throw .corrupt }
        let listing = try volume.loadDir(cluster)
        for e in listing.entries {
            let c = FSNode(name: e.name, kind: e.isDirectory ? .directory : .file)
            dir.adopt(c, as: e.name)
            if e.isDirectory {
                try load(volume, e.cluster, into: c, depth: depth + 1)
            } else {
                c.contents = try volume.contents(of: e)
            }
        }
    }
}

/// The kernel's filesystem, seeded from the boot module by fsInit. Created on
/// first use (a plain optional: no lazy-global initialiser).
var bootFS: FileSystem? = nil

var vfs: FileSystem {
    if let f = bootFS { return f }
    let f = FileSystem()
    bootFS = f
    return f
}
