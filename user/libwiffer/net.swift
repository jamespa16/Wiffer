// libwiffer, Phases 7E/7F/8A: sockets, DNS, randomness and wall-clock time
// (the calls of sysnet.swift and random.swift; ABI in abi/netcalls.swift).
//
//   let s = try Socket.tcp()                      // or .udp(), .icmp(); nonBlocking: true
//   try s.connect(ip, port)                       // blocking: until connected (throws ECONNREFUSED, ...)
//   s.connectStart(ip, port) -> Bool              // non-blocking: true if connected now, false if in
//                                                 // progress (wait writable, then s.pendingError)
//   s.send(bytes) / s.sendAll(bytes) / s.send(bytes, to: ip, port: p)   bytes sent or -errno
//   try s.receive(max:)  -> [UInt8]               // empty: end of stream; throws EAGAIN (non-blocking)
//   try s.receiveFrom(max:) -> ([UInt8], SocketAddress)
//   try s.bind(port:), try s.listen(backlog:), try s.accept() -> (Socket, SocketAddress)
//   s.shutdown(SocketShutdown.write), s.close()
//   s.nonBlocking, s.noDelay (get/set), s.pendingError, s.localAddress, s.peerAddress, s.available
//   s.file                                        // the fd as a File (read/write/wait work too)
//   WaitFD(socket: s, events: WaitEvent.readable)  // for wait(&fds, timeoutMs:)
//
//   try DNS.resolve("example.com") -> DNSAnswer   // addresses, aliases, cached
//   try DNS.resolve(name, server: ip, port: 53, nonBlocking: true)   // throws EAGAIN while pending
//   IPv4.parse("10.0.2.2") -> UInt32?, IPv4.string(ip)
//
//   Random.fill(buffer), Random.bytes(n), Random.uint64()   // the kernel's ChaCha20 DRBG
//   Time.unixSeconds                                        // RTC-based Unix time
//
// Addresses are UInt32 in host order. Throwing calls throw SysError(errno);
// `error.message` reads like "connection refused".

func netErrnoMessage(_ e: Int) -> String {
    switch e {
    case Errno.EAGAIN: return "resource temporarily unavailable"
    case Errno.ENOSYS: return "not implemented"
    case Errno.ERANGE: return "result too large"
    case NetErrno.ENODATA: return "no address for that name"
    case NetErrno.ELOOP: return "too many CNAMEs"
    case NetErrno.ENOTSOCK: return "not a socket"
    case NetErrno.EDESTADDRREQ: return "destination address required"
    case NetErrno.EMSGSIZE: return "message too long"
    case NetErrno.EPROTOTYPE: return "unknown socket kind"
    case NetErrno.EOPNOTSUPP: return "operation not supported"
    case NetErrno.EADDRINUSE: return "address already in use"
    case NetErrno.EADDRNOTAVAIL: return "address not available"
    case NetErrno.ENETDOWN: return "network is down"
    case NetErrno.ENETUNREACH: return "network unreachable"
    case NetErrno.ECONNABORTED: return "connection aborted"
    case NetErrno.ECONNRESET: return "connection reset by peer"
    case NetErrno.ENOBUFS: return "no buffer space"
    case NetErrno.EISCONN: return "already connected"
    case NetErrno.ENOTCONN: return "not connected"
    case NetErrno.ETIMEDOUT: return "connection timed out"
    case NetErrno.ECONNREFUSED: return "connection refused"
    case NetErrno.EHOSTUNREACH: return "host unreachable"
    case NetErrno.EALREADY: return "already connecting"
    case NetErrno.EINPROGRESS: return "connection in progress"
    default: return "error \(e)"
    }
}

enum IPv4 {
    /// "a.b.c.d" (each 0-255, no leading +/-), or nil.
    static func parse(_ s: String) -> UInt32? {
        var value: UInt32 = 0
        var part: UInt32 = 0
        var digits = 0
        var parts = 0
        for c in s.utf8 {
            if c == 0x2E {
                guard digits > 0, parts < 3 else { return nil }
                value = value << 8 | part
                part = 0
                digits = 0
                parts += 1
            } else if c >= 0x30 && c <= 0x39 {
                part = part * 10 + UInt32(c - 0x30)
                digits += 1
                guard digits <= 3, part <= 255 else { return nil }
            } else {
                return nil
            }
        }
        guard digits > 0, parts == 3 else { return nil }
        return value << 8 | part
    }

    static func string(_ ip: UInt32) -> String {
        "\(ip >> 24).\((ip >> 16) & 255).\((ip >> 8) & 255).\(ip & 255)"
    }
}

extension SocketAddress {
    var ipString: String { IPv4.string(ip) }
}

struct Socket {
    let fd: Int

    init(fd: Int) { self.fd = fd }

    var file: File { File(fd: fd) }
    var fdArg: UInt64 { UInt64(bitPattern: Int64(fd)) }

    static func make(_ kind: UInt64, nonBlocking: Bool) throws(SysError) -> Socket {
        Socket(fd: try checked(syscall(SyscallNumber.socket, kind, nonBlocking ? SocketFlag.nonBlocking : 0)))
    }

    static func tcp(nonBlocking: Bool = false) throws(SysError) -> Socket { try make(SocketKind.tcp, nonBlocking: nonBlocking) }
    static func udp(nonBlocking: Bool = false) throws(SysError) -> Socket { try make(SocketKind.udp, nonBlocking: nonBlocking) }
    static func icmp(nonBlocking: Bool = false) throws(SysError) -> Socket { try make(SocketKind.icmp, nonBlocking: nonBlocking) }

    /// Blocking connect (TCP: until connected; UDP/ICMP: sets the peer).
    func connect(_ ip: UInt32, _ port: UInt16) throws(SysError) {
        _ = try checked(syscall(SyscallNumber.connect, fdArg, UInt64(ip), UInt64(port)))
    }

    /// Start connecting a non-blocking socket: true if it is connected (or
    /// the peer set) already, false if in progress (wait for writable, then
    /// check `pendingError`).
    func connectStart(_ ip: UInt32, _ port: UInt16) throws(SysError) -> Bool {
        let r = syscall(SyscallNumber.connect, fdArg, UInt64(ip), UInt64(port))
        if r == -NetErrno.EINPROGRESS { return false }
        _ = try checked(r)
        return true
    }

    func bind(port: UInt16) throws(SysError) {
        _ = try checked(syscall(SyscallNumber.bind, fdArg, UInt64(port)))
    }

    func listen(backlog: Int = 8) throws(SysError) {
        _ = try checked(syscall(SyscallNumber.listen, fdArg, UInt64(max(backlog, 0))))
    }

    func accept() throws(SysError) -> (Socket, SocketAddress) {
        var a = SocketAddress()
        let r = withUnsafeMutablePointer(to: &a) { syscall(SyscallNumber.accept, fdArg, UInt64(UInt(bitPattern: $0))) }
        return (Socket(fd: try checked(r)), a)
    }

    /// Bytes sent (maybe fewer than given), or -errno.
    @discardableResult
    func send(_ bytes: UnsafeRawBufferPointer, to ip: UInt32 = 0, port: UInt16 = 0) -> Int {
        guard let base = bytes.baseAddress, bytes.count > 0 else { return 0 }
        return syscall(SyscallNumber.sendTo, fdArg, UInt64(UInt(bitPattern: base)), UInt64(bytes.count), UInt64(ip),
                       UInt64(port))
    }

    @discardableResult
    func send(_ bytes: [UInt8], to ip: UInt32 = 0, port: UInt16 = 0) -> Int {
        bytes.withUnsafeBytes { send($0, to: ip, port: port) }
    }

    /// Send everything (loops over short sends; blocking sockets). The
    /// count, or -errno if nothing could be sent.
    @discardableResult
    func sendAll(_ bytes: [UInt8]) -> Int { file.writeAll(bytes) }

    /// Bytes received into `buffer` (0: end of stream), or -errno.
    func receive(into buffer: UnsafeMutableRawBufferPointer, from: UnsafeMutablePointer<SocketAddress>? = nil) -> Int {
        guard let base = buffer.baseAddress, buffer.count > 0 else { return 0 }
        return syscall(SyscallNumber.recvFrom, fdArg, UInt64(UInt(bitPattern: base)), UInt64(buffer.count),
                       UInt64(UInt(bitPattern: from)))
    }

    /// Up to `max` bytes; empty at end of stream. Throws EAGAIN when a
    /// non-blocking socket has nothing.
    func receive(max: Int = 65536) throws(SysError) -> [UInt8] {
        try receiveFrom(max: max).0
    }

    func receiveFrom(max: Int = 65536) throws(SysError) -> ([UInt8], SocketAddress) {
        var failure = 0
        var a = SocketAddress()
        let bytes = [UInt8](unsafeUninitializedCapacity: Swift.max(max, 1)) { buf, count in
            let r = withUnsafeMutablePointer(to: &a) { receive(into: UnsafeMutableRawBufferPointer(buf), from: $0) }
            if r < 0 { failure = -r; count = 0 } else { count = r }
        }
        if failure != 0 { throw SysError(errno: failure) }
        return (bytes, a)
    }

    @discardableResult
    func shutdown(_ how: UInt64 = SocketShutdown.write) -> Int { syscall(SyscallNumber.shutdown, fdArg, how) }

    @discardableResult
    func close() -> Int { file.close() }

    func control(_ op: UInt64, _ value: UInt64 = UInt64.max) -> Int {
        syscall(SyscallNumber.socketControl, fdArg, op, value)
    }

    var nonBlocking: Bool {
        get { control(SocketControl.nonBlocking) == 1 }
        nonmutating set { _ = control(SocketControl.nonBlocking, newValue ? 1 : 0) }
    }

    var noDelay: Bool {
        get { control(SocketControl.noDelay) == 1 }
        nonmutating set { _ = control(SocketControl.noDelay, newValue ? 1 : 0) }
    }

    /// The socket's error as a positive errno (0: none), e.g. after a
    /// non-blocking connect.
    var pendingError: Int { max(0, control(SocketControl.error)) }
    var isConnected: Bool { control(SocketControl.connected) == 1 }
    var available: Int { max(0, control(SocketControl.available)) }

    var localAddress: (ip: UInt32, port: UInt16) {
        let v = max(0, control(SocketControl.localAddress))
        return (UInt32(truncatingIfNeeded: v >> 16), UInt16(truncatingIfNeeded: v))
    }

    var peerAddress: (ip: UInt32, port: UInt16) {
        let v = max(0, control(SocketControl.peerAddress))
        return (UInt32(truncatingIfNeeded: v >> 16), UInt16(truncatingIfNeeded: v))
    }
}

extension WaitFD {
    init(socket: Socket, events: Int16) {
        self.init(fd: Int32(socket.fd), events: events, revents: 0)
    }

    init(file: File, events: Int16) {
        self.init(fd: Int32(file.fd), events: events, revents: 0)
    }
}

struct DNSAnswer {
    var addresses: [UInt32] = []
    /// CNAMEs followed, in order.
    var aliases: [String] = []
    var cached = false
}

enum DNS {
    /// Look `name` up (an IPv4 literal answers itself). `server` 0: the
    /// configured DNS server. Throws ENOENT (no such name), ENODATA,
    /// ETIMEDOUT, ...; with `nonBlocking`, EAGAIN while the query runs
    /// (ask again later; the kernel keeps the answer for 10 s).
    static func resolve(_ name: String, server: UInt32 = 0, port: UInt16 = 53, nonBlocking: Bool = false)
        throws(SysError) -> DNSAnswer {
        var out = [UInt8](repeating: 0, count: ResolveRecord.maxSize)
        var options: UInt64 = server == 0 ? 0 : UInt64(server) << 16 | UInt64(port)
        if nonBlocking { options |= ResolveOption.nonBlocking }
        let r = withPath(name) { p, n in
            out.withUnsafeMutableBytes { o in
                syscall(SyscallNumber.resolve, p, n, UInt64(UInt(bitPattern: o.baseAddress)), UInt64(o.count), options)
            }
        }
        let used = try checked(r)
        var answer = DNSAnswer()
        guard used >= ResolveRecord.headerSize else { return answer }
        let count = Int(out[0])
        answer.cached = out[1] != 0
        let aliasCount = Int(out[2])
        var at = ResolveRecord.headerSize
        for _ in 0..<count where at + 4 <= used {
            answer.addresses.append(UInt32(out[at]) | UInt32(out[at + 1]) << 8 | UInt32(out[at + 2]) << 16
                                    | UInt32(out[at + 3]) << 24)
            at += 4
        }
        for _ in 0..<aliasCount {
            var end = at
            while end < used && out[end] != 0 { end += 1 }
            guard end < used else { break }
            answer.aliases.append(String(decoding: out[at..<end], as: UTF8.self))
            at = end + 1
        }
        return answer
    }
}

enum Random {
    /// Fill `buffer` from the kernel's DRBG.
    static func fill(_ buffer: UnsafeMutableRawBufferPointer) {
        var off = 0
        while off < buffer.count, let base = buffer.baseAddress {
            let n = min(65536, buffer.count - off)
            let r = syscall(SyscallNumber.getrandom, UInt64(UInt(bitPattern: base + off)), UInt64(n), 0)
            guard r > 0 else { return }
            off += r
        }
    }

    static func bytes(_ count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: max(count, 0))
        out.withUnsafeMutableBytes { fill($0) }
        return out
    }

    static func uint64() -> UInt64 {
        var v: UInt64 = 0
        withUnsafeMutableBytes(of: &v) { fill($0) }
        return v
    }
}

extension Time {
    /// Unix seconds (UTC), from the RTC.
    static var unixSeconds: Int { syscall(SyscallNumber.time) }
}
