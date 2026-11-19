// /bin/browse: file:// URLs through the libwiffer File API (BrowserTransport).
// Reads are synchronous (the RAM fs and /disk answer at once), so requests
// queue up and poll() serves one at a time between window events.

/// A whole file, read with one stat and as few reads as possible.
func browseReadFile(_ path: String, max: Int) throws(SysError) -> [UInt8] {
    let size = Int(try FS.stat(path).size)
    if size > max { throw SysError(errno: Errno.ENOMEM) }
    let f = try File.open(path)
    defer { _ = f.close() }
    var out = [UInt8](repeating: 0, count: size)
    var got = 0
    while got < size {
        let r = out.withUnsafeMutableBytes { b in
            f.read(into: UnsafeMutableRawBufferPointer(rebasing: b[got...]))
        }
        if r < 0 { throw SysError(errno: -r) }
        if r == 0 { break }
        got += r
    }
    if got < size { out.removeSubrange(got...) }
    return out
}

final class BrowserFileTransport: BrowserTransport {
    private var queue: [(id: Int, req: BrowserRequest)] = []
    var maxBytes = 32 * 1024 * 1024

    override init() { super.init() }

    override func handles(_ scheme: String) -> Bool { scheme == "file" }

    override func start(_ id: Int, _ req: BrowserRequest, now: Int) { queue.append((id: id, req: req)) }

    override func cancel(_ id: Int) { queue.removeAll { $0.id == id } }

    override var hasImmediateWork: Bool { !queue.isEmpty }

    override func poll(now: Int) {
        guard !queue.isEmpty else { return }
        let (id, req) = queue.removeFirst()
        let path = String(decoding: urlPercentDecode(Array(req.url.pathname.utf8)), as: UTF8.self)
        do throws(SysError) {
            let st = try FS.stat(path)
            if st.kind == StatKind.directory {
                var u = req.url
                if !path.hasSuffix("/") { u.path.append([]) } // .../dir -> .../dir/
                var r = BrowserResponse(url: u)
                var list: [(name: String, isDirectory: Bool, size: Int)] = []
                for e in try FS.list(path) { list.append((name: e.name, isDirectory: e.isDirectory, size: Int(e.size))) }
                r.directory = list
                events.append(.done(id: id, r))
                return
            }
            var r = BrowserResponse(url: req.url)
            r.body = try browseReadFile(path, max: maxBytes)
            r.contentType = browseFileType(path)
            events.append(.progress(id: id, received: r.body.count, total: r.body.count))
            events.append(.done(id: id, r))
        } catch {
            if error.errno == Errno.ENOENT || error.errno == Errno.ENOTDIR {
                events.append(.failed(id: id, .fileNotFound(path)))
            } else if error.errno == Errno.ENOMEM {
                events.append(.failed(id: id, .tooLarge))
            } else {
                events.append(.failed(id: id, .fileError(path + ": " + error.message)))
            }
        }
    }
}

/// A Content-Type from the file name (nil: let the loader sniff).
func browseFileType(_ path: String) -> [UInt8]? {
    var ext = ""
    var sawDot = false
    for u in path.unicodeScalars {
        if u == "." { ext = ""; sawDot = true } else if u == "/" { ext = ""; sawDot = false } else { ext.unicodeScalars.append(u) }
    }
    if !sawDot { return nil }
    var lower = ""
    for u in ext.unicodeScalars { lower.unicodeScalars.append(u.value >= 0x41 && u.value <= 0x5a ? Unicode.Scalar(u.value + 32)! : u) }
    switch lower {
    case "html", "htm", "xhtml": return Array("text/html".utf8)
    case "css": return Array("text/css".utf8)
    case "png": return Array("image/png".utf8)
    case "gif": return Array("image/gif".utf8)
    case "jpg", "jpeg": return Array("image/jpeg".utf8)
    case "txt", "md", "swift", "c", "h", "s", "py", "sh", "conf", "js", "json", "xml": return Array("text/plain".utf8)
    default: return nil
    }
}
