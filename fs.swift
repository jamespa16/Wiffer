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

    var message: String {
        switch self {
        case .notFound: return "no such file or directory"
        case .exists: return "already exists"
        case .notADirectory: return "not a directory"
        case .isADirectory: return "is a directory"
        case .notEmpty: return "directory not empty"
        case .invalidPath: return "invalid path"
        case .invalidMove: return "can't move a directory into itself"
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
        for p in parts {
            guard n.isDirectory else { throw .notADirectory }
            guard let next = n.children[p] else { throw .notFound }
            n = next
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
        for p in FileSystem.components(path, cwd: cwd) {
            if let next = n.children[p] {
                guard next.isDirectory else { throw .notADirectory }
                n = next
            } else {
                let d = FSNode(name: p, kind: .directory)
                n.adopt(d, as: p)
                n = d
            }
        }
        return n
    }

    private func make(_ path: String, cwd: String, kind: FSKind) throws(FSError) -> FSNode {
        let (dir, name) = try parentAndName(path, cwd: cwd)
        guard dir.children[name] == nil else { throw .exists }
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
        let n: FSNode
        if let existing = dir.children[name] {
            guard !existing.isDirectory else { throw .isADirectory }
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
        guard recursive || n.children.isEmpty else { throw .notEmpty }
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
        guard dir.children[name] == nil else { throw .exists }
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
