// Phase 7E: sockets for user space, and the resolver call.
//
// A socket is a FileObject (`NetSocket`), so read, write, close, dup2 and
// wait work on it like on a pipe. Its state is the network stack's
// (TCPConnection, UDPSocket, or an ICMP echo identifier), which lives on
// CPU 0, so the socket is `needsCPU0`: every method runs there (the syscall
// layer hops) except `ready()`, which returns `readyBits`, a cached copy
// recomputed on CPU 0 by `refresh()`: after every call, and from the
// stack's callbacks (TCPConnection.onEvent, UDPSocket.onReceive, the echo
// handler), which run in netd. `refresh` updates the bits before waking the
// waiters, and a waiter registers before it reads them, so no wakeup is
// lost.
//
// Data is copied in the syscall (copyIn/copyOut; `recvfrom` validates the
// destination before taking a datagram, as `read` does). Blocking calls
// park on the socket's wait list; a kill ends them with -EINTR.
// Non-blocking sockets return -EAGAIN (connect: -EINPROGRESS).
//
// Limits (abi/netcalls.swift SocketLimit): 32 sockets per creating process, 96
// in all, 128 KiB / 64 KiB TCP buffers, 32 queued datagrams. The last close
// (an exiting process's fd table included) closes the TCP connection
// gracefully (FIN, or RST with unread data, as TCPConnection.close does),
// unbinds UDP and drops the echo identifier.

/// Open user sockets (CPU 0).
var liveSockets = 0
/// Open sockets per creating pid (CPU 0).
var socketsByPid: [Int: Int] = [:]
var socketsCreated: UInt64 = 0

func tcpErrno(_ e: TCPError) -> Int {
    switch e {
    case .refused: return NetErrno.ECONNREFUSED
    case .reset: return NetErrno.ECONNRESET
    case .timedOut: return NetErrno.ETIMEDOUT
    case .unreachable: return NetErrno.EHOSTUNREACH
    case .aborted: return NetErrno.ECONNABORTED
    }
}

func icmpErrno(_ e: ICMPError) -> Int {
    e.type == ICMPType.unreachable && e.code == ICMPUnreachCode.port ? NetErrno.ECONNREFUSED : NetErrno.EHOSTUNREACH
}

typealias EchoReply = (src: IPv4Addr, ttl: UInt8, message: [UInt8])

/// Bounded FIFO; consumed replies release their payload immediately.
struct EchoReplyQueue {
    private var entries = [EchoReply?](repeating: nil, count: SocketLimit.datagramQueue)
    private var head = 0
    private(set) var count = 0
    var isEmpty: Bool { count == 0 }

    mutating func append(_ reply: EchoReply) {
        guard count < entries.count else { return }
        entries[(head + count) % entries.count] = reply
        count += 1
    }

    mutating func removeFirst() -> EchoReply {
        let reply = entries[head]!
        entries[head] = nil
        head = (head + 1) % entries.count
        count -= 1
        return reply
    }
}

final class NetSocket: FileObject {
    let kind: UInt64
    let ownerPid: Int
    var nonBlocking: Bool
    /// WaitEvent bits, recomputed on CPU 0 by refresh(); read on any CPU.
    var readyBits: Int16 = 0
    var isClosed = false
    var readShut = false

    // TCP: the connection (or listener), and the port from bind().
    var tcp: TCPConnection?
    var tcpPort: UInt16 = 0
    var noDelay = false
    // UDP: the bound socket (bound on bind, connect or the first send).
    var udp: UDPSocket?
    // UDP and ICMP: the default destination (connect).
    var peerIP: IPv4Addr = 0
    var peerPort: UInt16 = 0
    // ICMP: our echo identifier and the replies to it.
    var echoID: UInt16 = 0
    var echoQueue = EchoReplyQueue()

    init(kind: UInt64, owner: Int, nonBlocking: Bool) {
        self.kind = kind
        ownerPid = owner
        self.nonBlocking = nonBlocking
        super.init()
    }

    override var needsCPU0: Bool { true }
    override func ready() -> Int16 { readyBits }

    /// CPU 0: recompute readyBits, then wake waiters.
    func refresh() {
        var r: Int16 = 0
        if isClosed {
            r = WaitEvent.readable | WaitEvent.writable | WaitEvent.hangup
        } else if kind == SocketKind.tcp {
            if let c = tcp {
                if c.isListener {
                    if !c.acceptQueue.isEmpty { r |= WaitEvent.readable }
                } else {
                    if c.readable || readShut { r |= WaitEvent.readable }
                    if c.writable { r |= WaitEvent.writable }
                    if c.error != nil || c.eof || (c.isClosed && !c.readable) { r |= WaitEvent.hangup }
                }
            } else {
                r = WaitEvent.writable | WaitEvent.hangup // not connected
            }
        } else if kind == SocketKind.udp {
            if readShut || !(udp?.queue.isEmpty ?? true) { r |= WaitEvent.readable }
            r |= WaitEvent.writable
        } else {
            if readShut || !echoQueue.isEmpty { r |= WaitEvent.readable }
            r |= WaitEvent.writable
        }
        readyBits = r
        notify()
        // Packets to ourselves (loopback) wait in the stack's local queue
        // for netd: wake it now rather than at the main loop's next tick.
        netPollHook()
    }

    func watch(_ c: TCPConnection) {
        c.onEvent = { [self] _ in refresh() }
    }

    func watch(_ u: UDPSocket) {
        u.onReceive = { [self] in refresh() }
    }

    /// The local address (ip << 16 | port).
    var localAddress: Int {
        let ip = netStack?.ip ?? 0
        if let c = tcp { return Int(c.localIP == 0 ? ip : c.localIP) << 16 | Int(c.localPort) }
        if kind == SocketKind.tcp { return tcpPort == 0 ? 0 : Int(ip) << 16 | Int(tcpPort) }
        if let u = udp { return Int(ip) << 16 | Int(u.port) }
        return kind == SocketKind.icmp ? Int(ip) << 16 | Int(echoID) : 0
    }

    var peerAddress: Int {
        if let c = tcp { return c.isListener ? 0 : Int(c.remoteIP) << 16 | Int(c.remotePort) }
        return peerIP == 0 ? 0 : Int(peerIP) << 16 | Int(peerPort)
    }

    /// CPU 0: one read. `.wouldBlock` becomes -EAGAIN when non-blocking.
    func receive(_ max: Int) -> (IOResult, SocketAddress) {
        defer { refresh() }
        var from = SocketAddress()
        var result = IOResult.wouldBlock
        if isClosed { return (.error(Errno.EBADF), from) }
        switch kind {
        case SocketKind.tcp:
            guard let c = tcp else { return (.error(NetErrno.ENOTCONN), from) }
            guard !c.isListener else { return (.error(Errno.EINVAL), from) }
            from.ip = c.remoteIP
            from.port = c.remotePort
            if readShut { return (.data([]), from) }
            let d = c.receive(max: max)
            if !d.isEmpty {
                result = .data(d)
            } else if c.eof {
                result = .data([])
            } else if let e = c.error {
                result = .error(tcpErrno(e))
            } else if c.isClosed {
                result = .data([])
            }
        case SocketKind.udp:
            guard let u = udp else { return (.error(NetErrno.ENOTCONN), from) }
            if let e = u.lastError {
                u.lastError = nil
                return (.error(icmpErrno(e)), from)
            }
            if let dg = u.receive() {
                from.ip = dg.src
                from.port = dg.srcPort
                result = .data(dg.data.count <= max ? dg.data : Array(dg.data[0..<max]))
            } else if readShut {
                result = .data([])
            }
        default:
            if !echoQueue.isEmpty {
                let r = echoQueue.removeFirst()
                from.ip = r.src
                from.ttl = r.ttl
                result = .data(r.message.count <= max ? r.message : Array(r.message[0..<max]))
            } else if readShut {
                result = .data([])
            }
        }
        if case .wouldBlock = result, nonBlocking { result = .error(Errno.EAGAIN) }
        return (result, from)
    }

    /// CPU 0: one write (TCP: as much as fits; else one datagram).
    func send(_ bytes: [UInt8], to ip: IPv4Addr, port: UInt16) -> IOResult {
        defer { refresh() }
        if isClosed { return .error(Errno.EBADF) }
        guard let stack = netStack else { return .error(NetErrno.ENETDOWN) }
        switch kind {
        case SocketKind.tcp:
            guard let c = tcp, !c.isListener else { return .error(NetErrno.ENOTCONN) }
            if bytes.isEmpty { return .count(0) }
            let n = c.send(bytes)
            if n > 0 { return .count(n) }
            if n < 0 { return .error(c.error.map(tcpErrno) ?? Errno.EPIPE) }
            return nonBlocking ? .error(Errno.EAGAIN) : .wouldBlock
        case SocketKind.udp:
            let dst = ip != 0 ? ip : peerIP, dport = ip != 0 ? port : peerPort
            guard dst != 0, dport != 0 else { return .error(NetErrno.EDESTADDRREQ) }
            guard bytes.count <= SocketLimit.maxDatagram, bytes.count + 28 <= stack.dev.mtu else {
                return .error(NetErrno.EMSGSIZE)
            }
            if udp == nil {
                guard let u = stack.udpBind(0) else { return .error(NetErrno.ENOBUFS) }
                udp = u
                watch(u)
            }
            return udp!.send(to: dst, port: dport, bytes, src: dst >> 24 == 127 ? dst : nil) ? .count(bytes.count) : .error(NetErrno.ENETUNREACH)
        default:
            let dst = ip != 0 ? ip : peerIP
            guard dst != 0 else { return .error(NetErrno.EDESTADDRREQ) }
            guard bytes.count >= 8, bytes[0] == ICMPType.echoRequest, bytes[1] == 0 else { return .error(Errno.EINVAL) }
            guard bytes.count + 28 <= stack.dev.mtu else { return .error(NetErrno.EMSGSIZE) }
            return stack.sendEchoMessage(to: dst, id: echoID, bytes) ? .count(bytes.count) : .error(NetErrno.ENETUNREACH)
        }
    }

    override func tryRead(_ max: Int) -> IOResult { receive(max).0 }
    override func tryWrite(_ bytes: [UInt8]) -> IOResult { send(bytes, to: 0, port: 0) }

    /// The last fd closed (CPU 0): release the stack's side.
    override func lastClose() {
        guard !isClosed else { return }
        isClosed = true
        if let c = tcp {
            c.onEvent = nil
            c.close()
            tcp = nil
        }
        if let u = udp {
            u.onReceive = nil
            u.close()
            udp = nil
        }
        if echoID != 0 { netStack?.echoHandlers[echoID] = nil }
        echoQueue = EchoReplyQueue()
        liveSockets -= 1
        let left = (socketsByPid[ownerPid] ?? 1) - 1
        socketsByPid[ownerPid] = left > 0 ? left : nil
        refresh()
    }
}

/// CPU 0: a new socket, counted against `pid`; nil with the errno if a
/// limit is reached.
func makeSocket(kind: UInt64, pid: Int, nonBlocking: Bool) -> (NetSocket?, Int) {
    guard let stack = netStack else { return (nil, NetErrno.ENETDOWN) }
    guard liveSockets < SocketLimit.total else { return (nil, NetErrno.ENOBUFS) }
    guard (socketsByPid[pid] ?? 0) < SocketLimit.perProcess else { return (nil, Errno.EMFILE) }
    let s = NetSocket(kind: kind, owner: pid, nonBlocking: nonBlocking)
    if kind == SocketKind.icmp {
        var id: UInt16 = 0
        for _ in 0..<64 {
            let c = UInt16(truncatingIfNeeded: netRandom() >> 24)
            if c != 0 && stack.echoHandlers[c] == nil { id = c; break }
        }
        guard id != 0 else { return (nil, NetErrno.ENOBUFS) }
        s.echoID = id
        stack.echoHandlers[id] = { [s] src, ttl, message in
            guard s.echoQueue.count < SocketLimit.datagramQueue else { return }
            s.echoQueue.append((src, ttl, message))
            s.refresh()
        }
    }
    liveSockets += 1
    socketsCreated &+= 1
    socketsByPid[pid] = (socketsByPid[pid] ?? 0) + 1
    s.refresh()
    return (s, 0)
}

/// Install a socket in the process's fd table (closing it again if full).
func installSocket(_ p: Process, _ s: NetSocket) -> Int {
    guard let fd = p.fds.install(s) else {
        onCPU0 { s.lastClose() }
        return fail(Errno.EMFILE)
    }
    return fd
}

func socketArg(_ p: Process, _ fd: UInt64) -> (NetSocket?, Int) {
    guard fd < UInt64(FdTable.maxFDs), let f = p.fds.get(Int(fd)) else { return (nil, Errno.EBADF) }
    guard let s = f as? NetSocket else { return (nil, NetErrno.ENOTSOCK) }
    return (s, 0)
}

/// Park until `cond` (run on CPU 0) holds: 0, or -EINTR if killed.
func socketWait(_ p: Process, _ s: NetSocket, _ cond: () -> Bool) -> Int {
    guard let me = scheduler.current else { return fail(Errno.EINTR) }
    while true {
        s.waits.add(me)
        let done = onCPU0(cond)
        if !done && !p.killRequested { park() }
        s.waits.remove(me)
        if done { return 0 }
        if p.killRequested { return fail(Errno.EINTR) }
    }
}

func copyOutAddress(_ out: UInt64, _ a: SocketAddress) -> Bool {
    guard out != 0 else { return true }
    var v = a
    let bytes = withUnsafeBytes(of: &v) { Array($0) }
    return copyOut(out, bytes)
}

// MARK: The calls

/// Syscalls 50-69 (handleSyscall's default case): -ENOSYS for the rest.
func netSyscall(_ p: Process, _ n: UInt64, _ a1: UInt64, _ a2: UInt64, _ a3: UInt64, _ a4: UInt64,
                _ a5: UInt64) -> Int {
    switch n {
    case SyscallNumber.socket: return sysSocket(p, a1, a2)
    case SyscallNumber.connect: return sysConnect(p, a1, a2, a3)
    case SyscallNumber.bind: return sysBind(p, a1, a2)
    case SyscallNumber.listen: return sysListen(p, a1, a2)
    case SyscallNumber.accept: return sysAccept(p, a1, a2)
    case SyscallNumber.sendTo: return sysSendTo(p, a1, a2, a3, a4, a5)
    case SyscallNumber.recvFrom: return sysRecvFrom(p, a1, a2, a3, a4)
    case SyscallNumber.shutdown: return sysShutdown(p, a1, a2)
    case SyscallNumber.socketControl: return sysSocketControl(p, a1, a2, a3)
    case SyscallNumber.resolve: return sysResolve(p, a1, a2, a3, a4, a5)
    case SyscallNumber.getrandom: return sysGetrandom(p, a1, a2, a3)
    case SyscallNumber.time: return sysTime()
    default: return fail(Errno.ENOSYS)
    }
}

/// socket(kind, flags) -> fd.
func sysSocket(_ p: Process, _ kind: UInt64, _ flags: UInt64) -> Int {
    guard kind == SocketKind.tcp || kind == SocketKind.udp || kind == SocketKind.icmp else {
        return fail(NetErrno.EPROTOTYPE)
    }
    guard flags & ~SocketFlag.nonBlocking == 0 else { return fail(Errno.EINVAL) }
    let (s, e) = onCPU0 { makeSocket(kind: kind, pid: p.pid, nonBlocking: flags & SocketFlag.nonBlocking != 0) }
    guard let s else { return fail(e) }
    return installSocket(p, s)
}

/// connect(fd, ip, port).
func sysConnect(_ p: Process, _ fd: UInt64, _ ip: UInt64, _ port: UInt64) -> Int {
    let (sock, e) = socketArg(p, fd)
    guard let s = sock else { return fail(e) }
    guard ip != 0, ip <= 0xFFFF_FFFF, port <= 0xFFFF, port != 0 || s.kind == SocketKind.icmp else {
        return fail(Errno.EINVAL)
    }
    let addr = IPv4Addr(ip), dport = UInt16(port)
    // 0: done; 1: TCP connecting; else -errno.
    let r = onCPU0 { () -> Int in
        defer { s.refresh() }
        guard let stack = netStack else { return fail(NetErrno.ENETDOWN) }
        guard !s.isClosed else { return fail(Errno.EBADF) }
        switch s.kind {
        case SocketKind.tcp:
            if let c = s.tcp { return fail(c.connected || c.isListener ? NetErrno.EISCONN : NetErrno.EALREADY) }
            guard !stack.isBroadcast(addr), !isMulticastIP(addr) else { return fail(NetErrno.ENETUNREACH) }
            var options = TCPOptions()
            options.recvBuffer = SocketLimit.tcpReceiveBuffer
            options.sendBuffer = SocketLimit.tcpSendBuffer
            options.noDelay = s.noDelay
            guard let c = TCPConnection.connect(stack, to: addr, port: dport, localPort: s.tcpPort, options: options) else {
                if stack.ip == 0 && addr >> 24 != 127 { return fail(NetErrno.ENETDOWN) }
                return fail(s.tcpPort != 0 ? NetErrno.EADDRINUSE : NetErrno.ENOBUFS)
            }
            s.tcp = c
            s.watch(c)
            return 1
        case SocketKind.udp:
            if s.udp == nil {
                guard let u = stack.udpBind(0) else { return fail(NetErrno.ENOBUFS) }
                s.udp = u
                s.watch(u)
            }
            s.peerIP = addr
            s.peerPort = dport
            return 0
        default:
            s.peerIP = addr
            return 0
        }
    }
    guard r == 1 else { return r }
    if s.nonBlocking { return fail(NetErrno.EINPROGRESS) }
    let w = socketWait(p, s) { s.isClosed || s.tcp.map { $0.connected || $0.error != nil || $0.isClosed } ?? true }
    guard w == 0 else { return w }
    return onCPU0 { () -> Int in
        guard let c = s.tcp else { return fail(Errno.EBADF) }
        if let e = c.error { return fail(tcpErrno(e)) }
        return c.connected ? 0 : fail(NetErrno.ECONNABORTED)
    }
}

/// bind(fd, port).
func sysBind(_ p: Process, _ fd: UInt64, _ port: UInt64) -> Int {
    let (sock, e) = socketArg(p, fd)
    guard let s = sock else { return fail(e) }
    guard port <= 0xFFFF else { return fail(Errno.EINVAL) }
    let lport = UInt16(port)
    return onCPU0 { () -> Int in
        defer { s.refresh() }
        guard let stack = netStack else { return fail(NetErrno.ENETDOWN) }
        guard !s.isClosed else { return fail(Errno.EBADF) }
        switch s.kind {
        case SocketKind.tcp:
            guard s.tcp == nil, s.tcpPort == 0 else { return fail(Errno.EINVAL) }
            if lport == 0 {
                guard let e = stack.tcp.ephemeralPort() else { return fail(NetErrno.EADDRINUSE) }
                s.tcpPort = e
            } else {
                guard stack.tcp.listener(port: lport) == nil else { return fail(NetErrno.EADDRINUSE) }
                s.tcpPort = lport
            }
            return 0
        case SocketKind.udp:
            guard s.udp == nil else { return fail(Errno.EINVAL) }
            guard let u = stack.udpBind(lport) else { return fail(NetErrno.EADDRINUSE) }
            s.udp = u
            s.watch(u)
            return 0
        default:
            return fail(NetErrno.EOPNOTSUPP)
        }
    }
}

/// listen(fd, backlog).
func sysListen(_ p: Process, _ fd: UInt64, _ backlog: UInt64) -> Int {
    let (sock, e) = socketArg(p, fd)
    guard let s = sock else { return fail(e) }
    guard s.kind == SocketKind.tcp else { return fail(NetErrno.EOPNOTSUPP) }
    guard backlog <= 1 << 20 else { return fail(Errno.EINVAL) }
    return onCPU0 { () -> Int in
        defer { s.refresh() }
        guard let stack = netStack else { return fail(NetErrno.ENETDOWN) }
        guard !s.isClosed else { return fail(Errno.EBADF) }
        if let c = s.tcp { return c.isListener ? 0 : fail(NetErrno.EISCONN) }
        if s.tcpPort == 0 {
            guard let e = stack.tcp.ephemeralPort() else { return fail(NetErrno.EADDRINUSE) }
            s.tcpPort = e
        }
        var options = TCPOptions()
        options.recvBuffer = SocketLimit.tcpReceiveBuffer
        options.sendBuffer = SocketLimit.tcpSendBuffer
        options.noDelay = s.noDelay
        guard let l = TCPConnection.listen(stack, port: s.tcpPort, backlog: max(1, min(Int(backlog), 64)),
                                           options: options) else { return fail(NetErrno.EADDRINUSE) }
        s.tcp = l
        s.watch(l)
        return 0
    }
}

/// accept(fd, addrOut) -> fd.
func sysAccept(_ p: Process, _ fd: UInt64, _ addrOut: UInt64) -> Int {
    let (sock, e) = socketArg(p, fd)
    guard let s = sock else { return fail(e) }
    if addrOut != 0 && !userRangeReady(p, UInt(addrOut), 8, write: true) { return fail(Errno.EFAULT) }
    while true {
        var errno = 0
        var from = SocketAddress()
        let child = onCPU0 { () -> NetSocket? in
            defer { s.refresh() }
            guard !s.isClosed, let l = s.tcp, l.isListener else { errno = Errno.EINVAL; return nil }
            guard let c = l.accept() else {
                if s.nonBlocking { errno = Errno.EAGAIN }
                return nil
            }
            let (n, e) = makeSocket(kind: SocketKind.tcp, pid: p.pid, nonBlocking: s.nonBlocking)
            guard let n else {
                c.abort()
                errno = e
                return nil
            }
            n.tcp = c
            n.noDelay = s.noDelay
            n.watch(c)
            n.refresh()
            from.ip = c.remoteIP
            from.port = c.remotePort
            return n
        }
        if let child {
            let nfd = installSocket(p, child)
            if nfd >= 0 && !copyOutAddress(addrOut, from) { return fail(Errno.EFAULT) }
            return nfd
        }
        if errno != 0 { return fail(errno) }
        let w = socketWait(p, s) { s.isClosed || !(s.tcp?.acceptQueue.isEmpty ?? true) || !(s.tcp?.isListener ?? false) }
        guard w == 0 else { return w }
    }
}

/// sendto(fd, buf, len, ip, port).
func sysSendTo(_ p: Process, _ fd: UInt64, _ buf: UInt64, _ len: UInt64, _ ip: UInt64, _ port: UInt64) -> Int {
    let (sock, e) = socketArg(p, fd)
    guard let s = sock else { return fail(e) }
    if s.kind == SocketKind.tcp { return sysWrite(p, fd, buf, len) }
    guard ip <= 0xFFFF_FFFF, port <= 0xFFFF else { return fail(Errno.EINVAL) }
    guard len <= UInt64(SocketLimit.maxDatagram) else { return fail(NetErrno.EMSGSIZE) }
    guard let bytes = copyIn(buf, Int(len)) else { return fail(Errno.EFAULT) }
    switch blockingIO(p, s, WaitEvent.writable, { s.send(bytes, to: IPv4Addr(ip), port: UInt16(port)) }) {
    case .count(let n): return n
    case .error(let e): return fail(e)
    default: return fail(Errno.EIO)
    }
}

/// recvfrom(fd, buf, len, addrOut).
func sysRecvFrom(_ p: Process, _ fd: UInt64, _ buf: UInt64, _ len: UInt64, _ addrOut: UInt64) -> Int {
    let (sock, e) = socketArg(p, fd)
    guard let s = sock else { return fail(e) }
    guard len <= 1 << 40 else { return fail(Errno.EINVAL) }
    let n = min(Int(len), maxIOChunk)
    guard n > 0 else { return 0 }
    // Check both destinations first: a datagram can't be put back.
    guard userRangeReady(p, UInt(buf), n, write: true) else { return fail(Errno.EFAULT) }
    if addrOut != 0 && !userRangeReady(p, UInt(addrOut), 8, write: true) { return fail(Errno.EFAULT) }
    var from = SocketAddress()
    let r = blockingIO(p, s, WaitEvent.readable) { () -> IOResult in
        let (r, a) = s.receive(n)
        from = a
        return r
    }
    switch r {
    case .data(let bytes):
        guard copyOut(buf, bytes), copyOutAddress(addrOut, from) else { return fail(Errno.EFAULT) }
        return bytes.count
    case .error(let e): return fail(e)
    default: return fail(Errno.EIO)
    }
}

/// shutdown(fd, how).
func sysShutdown(_ p: Process, _ fd: UInt64, _ how: UInt64) -> Int {
    let (sock, e) = socketArg(p, fd)
    guard let s = sock else { return fail(e) }
    guard how != 0, how & ~SocketShutdown.both == 0 else { return fail(Errno.EINVAL) }
    return onCPU0 { () -> Int in
        defer { s.refresh() }
        guard !s.isClosed else { return fail(Errno.EBADF) }
        if s.kind == SocketKind.tcp && (s.tcp == nil || s.tcp!.isListener) { return fail(NetErrno.ENOTCONN) }
        if how & SocketShutdown.read != 0 { s.readShut = true }
        if how & SocketShutdown.write != 0, let c = s.tcp { c.shutdown() }
        return 0
    }
}

/// socket_control(fd, op, value).
func sysSocketControl(_ p: Process, _ fd: UInt64, _ op: UInt64, _ value: UInt64) -> Int {
    let (sock, e) = socketArg(p, fd)
    guard let s = sock else { return fail(e) }
    let asks = value == UInt64.max
    return onCPU0 { () -> Int in
        defer { s.refresh() }
        switch op {
        case SocketControl.nonBlocking:
            let old = s.nonBlocking ? 1 : 0
            if !asks {
                guard value <= 1 else { return fail(Errno.EINVAL) }
                s.nonBlocking = value == 1
            }
            return old
        case SocketControl.error:
            if let c = s.tcp, let err = c.error { return tcpErrno(err) }
            if let u = s.udp, let err = u.lastError {
                u.lastError = nil
                return icmpErrno(err)
            }
            return 0
        case SocketControl.localAddress:
            return s.localAddress
        case SocketControl.peerAddress:
            return s.peerAddress
        case SocketControl.noDelay:
            guard s.kind == SocketKind.tcp else { return fail(NetErrno.EOPNOTSUPP) }
            let old = s.noDelay ? 1 : 0
            if !asks {
                guard value <= 1 else { return fail(Errno.EINVAL) }
                s.noDelay = value == 1
                s.tcp?.noDelay = s.noDelay
            }
            return old
        case SocketControl.available:
            if let c = s.tcp { return c.isListener ? c.acceptQueue.count : c.available }
            if let u = s.udp { return u.queue.count }
            return s.echoQueue.count
        case SocketControl.connected:
            return (s.tcp?.connected ?? false) ? 1 : 0
        default:
            return fail(Errno.EINVAL)
        }
    }
}

// MARK: resolve

func dnsErrno(_ e: DNSError?) -> Int {
    switch e {
    case .badName?: return Errno.EINVAL
    case .noServer?, .sendFailed?: return NetErrno.ENETDOWN
    case .timeout?: return NetErrno.ETIMEDOUT
    case .nxdomain?: return Errno.ENOENT
    case .serverFailure?: return Errno.EIO
    case .noAddress?: return NetErrno.ENODATA
    case .truncated?: return NetErrno.EMSGSIZE
    case .tooManyCNAMEs?: return NetErrno.ELOOP
    case nil: return Errno.EIO
    }
}

/// An in-flight (or recently finished) user lookup, shared by processes
/// asking the same name of the same server.
final class ResolveEntry {
    let name: String
    let server: UInt64
    let query: DNSQuery
    var waiters: [Task] = []
    var finishedAt: UInt64 = 0

    init(name: String, server: UInt64, query: DNSQuery) {
        self.name = name
        self.server = server
        self.query = query
    }
}

/// CPU 0. Finished entries are kept 10 s for non-blocking callers.
var resolveTable: [ResolveEntry] = []
let maxResolveEntries = 32

/// resolve(name, len, out, outLen, options).
func sysResolve(_ p: Process, _ namePtr: UInt64, _ nameLen: UInt64, _ out: UInt64, _ outLen: UInt64,
                _ options: UInt64) -> Int {
    guard nameLen > 0 else { return fail(Errno.EINVAL) }
    guard nameLen <= 255 else { return fail(Errno.ENAMETOOLONG) }
    guard outLen >= UInt64(ResolveRecord.headerSize + 4), outLen <= 1 << 20 else { return fail(Errno.ERANGE) }
    guard options & ~(ResolveOption.serverMask | ResolveOption.nonBlocking) == 0 else { return fail(Errno.EINVAL) }
    guard let raw = copyIn(namePtr, Int(nameLen)) else { return fail(Errno.EFAULT) }
    guard !raw.contains(0) else { return fail(Errno.EINVAL) }
    let outSize = min(Int(outLen), ResolveRecord.maxSize)
    guard userRangeReady(p, UInt(out), outSize, write: true) else { return fail(Errno.EFAULT) }
    let server = options & ResolveOption.serverMask
    let nonBlocking = options & ResolveOption.nonBlocking != 0
    let name = String(decoding: raw, as: UTF8.self)

    if let literal = parseIPv4(Substring(name)) { return storeResolveRecord(out, outSize, [literal], [], cached: false) }

    guard let me = scheduler.current else { return fail(Errno.EINTR) }
    var entry: ResolveEntry?
    var errno = 0
    onCPU0 {
        guard let stack = netStack, let resolver = stack.resolver else { errno = NetErrno.ENETDOWN; return }
        let now = ticks
        resolveTable.removeAll { $0.finishedAt != 0 && now &- $0.finishedAt > 1000 }
        if let i = resolveTable.firstIndex(where: { $0.name == name && $0.server == server }) {
            let e = resolveTable[i]
            if e.query.state == .pending || nonBlocking {
                entry = e
                return
            }
            resolveTable.remove(at: i) // finished: a blocking caller asks again
        }
        var ip: IPv4Addr? = nil
        var port: UInt16 = 53
        if server != 0 {
            ip = IPv4Addr(truncatingIfNeeded: server >> 16)
            let pt = UInt16(truncatingIfNeeded: server)
            if pt != 0 { port = pt }
        }
        let q = resolver.start(name, server: ip, port: port)
        let e = ResolveEntry(name: name, server: server, query: q)
        entry = e
        guard q.state == .pending else { return } // cached, or failed at once
        guard resolveTable.count < maxResolveEntries else { errno = NetErrno.ENOBUFS; entry = nil; return }
        q.onFinish = { [e] in
            e.finishedAt = ticks
            for t in e.waiters { unpark(t) }
            e.query.onFinish = nil // (it held the entry)
        }
        resolveTable.append(e)
    }
    guard let e = entry else { return fail(errno) }
    while true {
        var pending = false
        onCPU0 {
            pending = e.query.state == .pending
            if pending && !nonBlocking { e.waiters.append(me) }
            if !pending, let i = resolveTable.firstIndex(where: { $0 === e }), nonBlocking || e.waiters.isEmpty {
                resolveTable.remove(at: i)
            }
        }
        if !pending { break }
        if nonBlocking { return fail(Errno.EAGAIN) }
        if !p.killRequested { park() }
        onCPU0 { e.waiters.removeAll { $0 === me } }
        if p.killRequested { return fail(Errno.EINTR) }
    }
    let q = e.query
    guard q.state == .done else { return fail(dnsErrno(q.error)) }
    let aliases = q.aliases.map { String(decoding: $0, as: UTF8.self) }
    return storeResolveRecord(out, outSize, q.addresses, aliases, cached: q.fromCache)
}

func storeResolveRecord(_ out: UInt64, _ size: Int, _ addresses: [IPv4Addr], _ aliases: [String], cached: Bool) -> Int {
    let n = min(addresses.count, ResolveRecord.maxAddresses)
    guard ResolveRecord.headerSize + 4 * n <= size else { return fail(Errno.ERANGE) }
    var bytes: [UInt8] = [UInt8(n), cached ? 1 : 0, 0, 0]
    for a in addresses.prefix(n) {
        for i in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: a >> UInt32(8 * i))) }
    }
    var aliasCount = 0
    for a in aliases where aliasCount < 255 {
        let b = Array(a.utf8)
        guard bytes.count + b.count + 1 <= size else { break }
        bytes += b
        bytes.append(0)
        aliasCount += 1
    }
    bytes[2] = UInt8(aliasCount)
    return copyOut(out, bytes) ? bytes.count : fail(Errno.EFAULT)
}
