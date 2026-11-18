// /bin/nettest: exercises the 7E/8A system calls from ring 3: sockets (TCP,
// UDP and ICMP over the loopback, 127.0.0.1), non-blocking mode and wait,
// bad pointers and values, the per-process limit, resolve, getrandom and
// time. `nettest hold <port>` is the child the main run kills while it holds
// open sockets. Prints "ok ..." / "FAIL ..." per check and
// "nettest: N checks, M failed".

var checks = 0
var failures = 0

func check(_ name: String, _ ok: Bool) {
    checks += 1
    if ok {
        print("ok   \(name)")
    } else {
        failures += 1
        print("FAIL \(name)")
    }
}

let loopback: UInt32 = 0x7F00_0001

func fnv1a(_ data: [UInt8], _ h0: UInt64 = 0xcbf2_9ce4_8422_2325) -> UInt64 {
    var h = h0
    for b in data { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
    return h
}

func errnoOf(_ body: () throws(SysError) -> Void) -> Int {
    do throws(SysError) {
        try body()
        return 0
    } catch {
        return error.errno
    }
}

/// Wait for `events` on one fd (timeout ms); the revents.
func waitOne(_ fd: Int, _ events: Int16, _ timeout: Int = 5000) -> Int16 {
    var fds = [WaitFD(fd: Int32(fd), events: events, revents: 0)]
    let n = wait(&fds, timeoutMs: timeout)
    return n > 0 ? fds[0].revents : 0
}

let args = Process.args

// The child: open a listener, a connected pair, UDP and ICMP sockets, say
// so on stdout, then sleep until killed (the parent checks the port is
// free again afterwards).
if args.count >= 3 && args[1] == "hold" {
    let port = UInt16(Int(args[2]) ?? 0)
    var held: [Socket] = []
    do throws(SysError) {
        let l = try Socket.tcp()
        try l.bind(port: port)
        try l.listen()
        let c = try Socket.tcp()
        try c.connect(loopback, port)
        let (a, _) = try l.accept()
        _ = c.send(Array("unread".utf8)) // data the dying process never reads
        let u = try Socket.udp()
        try u.bind(port: port)
        let i = try Socket.icmp()
        held = [l, c, a, u, i]
        print("holding \(held.count)")
    } catch {
        print("hold failed: \(error.message)")
    }
    while true { Time.sleep(1000) }
}

// MARK: getrandom, time

do {
    let a = Random.bytes(32), b = Random.bytes(32)
    check("getrandom: two reads differ", a != b && a.contains(where: { $0 != 0 }))
    let big = Random.bytes(65536)
    var counts = [Int](repeating: 0, count: 256)
    for x in big { counts[Int(x)] += 1 }
    check("getrandom: 64 KiB in one call uses every byte value", counts.allSatisfy { $0 > 0 })
    check("getrandom: into null is EFAULT", syscall(SyscallNumber.getrandom, 0, 16, 0) == -Errno.EFAULT)
    check("getrandom: into a kernel address is EFAULT",
          syscall(SyscallNumber.getrandom, 0xFFFF_8000_0000_0000, 16, 0) == -Errno.EFAULT)
    var buf = [UInt8](repeating: 0, count: 16)
    let p = buf.withUnsafeMutableBytes { UInt64(UInt(bitPattern: $0.baseAddress)) }
    check("getrandom: flags are EINVAL", syscall(SyscallNumber.getrandom, p, 16, 1) == -Errno.EINVAL)
    check("getrandom: more than 64 KiB is EINVAL", syscall(SyscallNumber.getrandom, p, 65537, 0) == -Errno.EINVAL)
    check("getrandom: 0 bytes is 0", syscall(SyscallNumber.getrandom, p, 0, 0) == 0)
    buf[0] = 0
    let t = Time.unixSeconds
    check("time: after 2025-01-01 and before 2100", t > 1_735_689_600 && t < 4_102_444_800)
}

// MARK: Bad arguments

check("socket: an unknown kind is EPROTOTYPE", syscall(SyscallNumber.socket, 9, 0) == -NetErrno.EPROTOTYPE)
check("socket: unknown flags are EINVAL", syscall(SyscallNumber.socket, SocketKind.tcp, 6) == -Errno.EINVAL)
check("connect on a bad fd is EBADF", syscall(SyscallNumber.connect, 200, UInt64(loopback), 80) == -Errno.EBADF)
check("connect on the console is ENOTSOCK", syscall(SyscallNumber.connect, 1, UInt64(loopback), 80) == -NetErrno.ENOTSOCK)
check("socket_control on a pipe end is ENOTSOCK", {
    guard let (r, w) = try? File.pipe() else { return false }
    defer { r.close(); w.close() }
    return syscall(SyscallNumber.socketControl, UInt64(r.fd), SocketControl.error, 0) == -NetErrno.ENOTSOCK
}())

// MARK: TCP over the loopback

let port = UInt16(20000 + Process.pid % 20000)
do throws(SysError) {
    let l = try Socket.tcp(nonBlocking: true)
    check("tcp: connect to a port nobody listens on is ECONNREFUSED", errnoOf { () throws(SysError) in
        let s = try Socket.tcp()
        defer { s.close() }
        try s.connect(loopback, port)
    } == NetErrno.ECONNREFUSED)
    try l.bind(port: port)
    try l.listen(backlog: 4)
    check("tcp: listen gives the bound local address", l.localAddress.port == port)
    check("tcp: a second listener on the port is EADDRINUSE", errnoOf { () throws(SysError) in
        let s = try Socket.tcp()
        defer { s.close() }
        try s.bind(port: port)
        try s.listen()
    } == NetErrno.EADDRINUSE)
    check("tcp: non-blocking accept with nothing queued is EAGAIN", errnoOf { () throws(SysError) in _ = try l.accept() } == Errno.EAGAIN)

    let c = try Socket.tcp(nonBlocking: true)
    let now = try c.connectStart(loopback, port)
    check("tcp: a non-blocking connect is in progress", !now)
    check("tcp: connect again while connecting is EALREADY",
          syscall(SyscallNumber.connect, c.fdArg, UInt64(loopback), UInt64(port)) == -NetErrno.EALREADY)
    let w = waitOne(c.fd, WaitEvent.writable)
    check("tcp: wait says writable once connected", w & WaitEvent.writable != 0 && c.pendingError == 0 && c.isConnected)
    check("tcp: wait says the listener is readable", waitOne(l.fd, WaitEvent.readable) & WaitEvent.readable != 0)
    check("tcp: accept with a bad address pointer is EFAULT",
          syscall(SyscallNumber.accept, l.fdArg, 0xFFFF_8000_0000_0000) == -Errno.EFAULT)
    let (a, from) = try l.accept()
    check("tcp: accept reports the peer", from.ip == loopback && from.port == c.localAddress.port
          && a.peerAddress.port == c.localAddress.port)
    check("tcp: the accepted socket inherits non-blocking mode", a.nonBlocking)
    check("tcp: non-blocking receive with no data is EAGAIN", errnoOf { () throws(SysError) in _ = try a.receive() } == Errno.EAGAIN)

    // 1 MiB each way at once, through wait.
    var out = [UInt8](repeating: 0, count: 1 << 20)
    var x: UInt32 = 12345
    for i in 0..<out.count { x = x &* 1_103_515_245 &+ 12345; out[i] = UInt8(truncatingIfNeeded: x >> 16) }
    let want = fnv1a(out)
    var sentC = 0, sentA = 0
    var gotA: [UInt8] = [], gotC: [UInt8] = []
    var rounds = 0
    while (gotA.count < out.count || gotC.count < out.count) && rounds < 100_000 {
        rounds += 1
        var fds = [WaitFD(socket: c, events: WaitEvent.readable | (sentC < out.count ? WaitEvent.writable : 0)),
                   WaitFD(socket: a, events: WaitEvent.readable | (sentA < out.count ? WaitEvent.writable : 0))]
        if wait(&fds, timeoutMs: 5000) <= 0 { break }
        if fds[0].revents & WaitEvent.writable != 0 && sentC < out.count {
            let n = out.withUnsafeBytes { c.send(UnsafeRawBufferPointer(rebasing: $0[sentC..<min(out.count, sentC + 32768)])) }
            if n > 0 { sentC += n }
        }
        if fds[1].revents & WaitEvent.writable != 0 && sentA < out.count {
            let n = out.withUnsafeBytes { a.send(UnsafeRawBufferPointer(rebasing: $0[sentA..<min(out.count, sentA + 32768)])) }
            if n > 0 { sentA += n }
        }
        if fds[0].revents & WaitEvent.readable != 0, let d = try? c.receive() { gotC += d }
        if fds[1].revents & WaitEvent.readable != 0, let d = try? a.receive() { gotA += d }
    }
    check("tcp: 1 MiB each way through the loopback, hashes match",
          gotA.count == out.count && gotC.count == out.count && fnv1a(gotA) == want && fnv1a(gotC) == want)

    // Bad pointers lose nothing.
    c.nonBlocking = false
    a.nonBlocking = false
    check("tcp: send from null is EFAULT", syscall(SyscallNumber.sendTo, c.fdArg, 0, 10, 0, 0) == -Errno.EFAULT)
    check("tcp: send from a kernel address is EFAULT",
          syscall(SyscallNumber.sendTo, c.fdArg, 0xFFFF_8000_0000_0000, 10, 0, 0) == -Errno.EFAULT)
    _ = c.send(Array("hello".utf8))
    check("tcp: wait sees the data", waitOne(a.fd, WaitEvent.readable) & WaitEvent.readable != 0)
    check("tcp: recv into a kernel address is EFAULT",
          syscall(SyscallNumber.recvFrom, a.fdArg, 0xFFFF_8000_0000_0000, 5, 0) == -Errno.EFAULT)
    var tmp = [UInt8](repeating: 0, count: 8)
    let tp = tmp.withUnsafeMutableBytes { UInt64(UInt(bitPattern: $0.baseAddress)) }
    check("tcp: recvfrom with a bad address pointer is EFAULT",
          syscall(SyscallNumber.recvFrom, a.fdArg, tp, 8, 0x10) == -Errno.EFAULT)
    tmp[0] = 0
    // read() works on a socket too.
    check("tcp: read() gets the data the failed calls left", String(decoding: (try? a.file.read(max: 64)) ?? [], as: UTF8.self) == "hello")
    check("tcp: write() works on a socket", c.file.write("world") == 5 && String(decoding: (try? a.receive()) ?? [], as: UTF8.self) == "world")
    check("tcp: socket_control with an unknown op is EINVAL", c.control(99) == -Errno.EINVAL)
    c.noDelay = true
    check("tcp: noDelay can be set", c.noDelay)

    // Half close: the server reads end of stream, answers, closes.
    check("tcp: shutdown(write)", c.shutdown(SocketShutdown.write) == 0)
    let eof = try a.receive()
    check("tcp: the peer reads end of stream after shutdown", eof.isEmpty)
    check("tcp: wait reports hangup at end of stream", waitOne(a.fd, WaitEvent.readable) & WaitEvent.hangup != 0)
    check("tcp: send after the peer's shutdown still works", a.sendAll(Array("bye".utf8)) == 3)
    a.close()
    var tail: [UInt8] = []
    while true {
        guard let d = try? c.receive(), !d.isEmpty else { break }
        tail += d
    }
    check("tcp: the half-closed side still receives, then end of stream", String(decoding: tail, as: UTF8.self) == "bye")
    check("tcp: send after shutdown fails", c.send(Array("x".utf8)) < 0)
    c.close()
    l.close()
} catch {
    check("tcp: loopback setup (\(error.message))", false)
}

// MARK: UDP over the loopback

do throws(SysError) {
    let a = try Socket.udp()
    try a.bind(port: port)
    check("udp: a second bind of the port is EADDRINUSE", errnoOf { () throws(SysError) in
        let s = try Socket.udp()
        defer { s.close() }
        try s.bind(port: port)
    } == NetErrno.EADDRINUSE)
    let b = try Socket.udp()
    check("udp: send without a destination is EDESTADDRREQ", b.send(Array("x".utf8)) == -NetErrno.EDESTADDRREQ)
    check("udp: sendto", b.send(Array("ping".utf8), to: loopback, port: port) == 4)
    check("udp: a datagram over 1472 bytes is EMSGSIZE",
          b.send([UInt8](repeating: 1, count: 1473), to: loopback, port: port) == -NetErrno.EMSGSIZE)
    let (d, from) = try a.receiveFrom()
    check("udp: recvfrom gets the datagram and the sender", String(decoding: d, as: UTF8.self) == "ping"
          && from.ip == loopback && from.port == b.localAddress.port)
    try a.connect(loopback, b.localAddress.port)
    check("udp: send to the connected peer", a.send(Array("pong!".utf8)) == 5)
    let r = try b.receive(max: 3)
    check("udp: a short read truncates the datagram", String(decoding: r, as: UTF8.self) == "pon")
    a.nonBlocking = true
    check("udp: non-blocking recv on an empty queue is EAGAIN", errnoOf { () throws(SysError) in _ = try a.receive() } == Errno.EAGAIN)
    for i in 0..<40 { _ = b.send([UInt8(i)], to: loopback, port: port) }
    _ = waitOne(a.fd, WaitEvent.readable)
    Time.sleep(200) // (loopback datagrams are delivered by netd)
    var n = 0
    while (try? a.receive()) != nil { n += 1 }
    check("udp: the queue holds at most 32 datagrams", n == SocketLimit.datagramQueue)
    a.close()
    b.close()
} catch {
    check("udp: loopback setup (\(error.message))", false)
}

// MARK: ICMP echo (ping) over the loopback

do throws(SysError) {
    let s = try Socket.icmp()
    var msg: [UInt8] = [8, 0, 0, 0, 0, 0, 0, 7]
    msg += Array("wiffer ping".utf8)
    check("icmp: send an echo request", s.send(msg, to: loopback) == msg.count)
    check("icmp: an echo reply arrives", waitOne(s.fd, WaitEvent.readable, 3000) & WaitEvent.readable != 0)
    let (reply, from) = try s.receiveFrom()
    check("icmp: the reply has type 0, our sequence, the data and a TTL",
          reply.count == msg.count && reply[0] == 0 && reply[7] == 7 && Array(reply[8...]) == Array(msg[8...])
          && from.ip == loopback && from.ttl > 0)
    check("icmp: a message that isn't an echo request is EINVAL", s.send([0, 0, 0, 0, 0, 0, 0, 0], to: loopback) == -Errno.EINVAL)
    check("icmp: bind is EOPNOTSUPP", errnoOf { () throws(SysError) in try s.bind(port: 1) } == NetErrno.EOPNOTSUPP)
    s.close()
} catch {
    check("icmp: setup (\(error.message))", false)
}

// MARK: Limits

do {
    var opened: [Socket] = []
    var last = 0
    while opened.count < 100 {
        do throws(SysError) {
            opened.append(try Socket.udp())
        } catch {
            last = error.errno
            break
        }
    }
    check("limit: \(SocketLimit.perProcess) sockets per process, then EMFILE",
          opened.count == SocketLimit.perProcess && last == Errno.EMFILE)
    for s in opened { s.close() }
    check("limit: closing frees them", (try? Socket.udp())?.close() == 0)
}

// MARK: resolve

do {
    let a = try? DNS.resolve("10.0.2.2")
    check("resolve: an IPv4 literal answers itself", a?.addresses == [0x0A00_0202])
    check("resolve: an empty name is EINVAL", syscall(SyscallNumber.resolve, 1, 0, 0, 0, 0) == -Errno.EINVAL)
    var out = [UInt8](repeating: 0, count: 64)
    let op = out.withUnsafeMutableBytes { UInt64(UInt(bitPattern: $0.baseAddress)) }
    check("resolve: a bad name pointer is EFAULT", syscall(SyscallNumber.resolve, 0x10, 5, op, 64, 0) == -Errno.EFAULT)
    check("resolve: a bad output pointer is EFAULT",
          withPath("x.example") { syscall(SyscallNumber.resolve, $0, $1, 0xFFFF_8000_0000_0000, 64, 0) } == -Errno.EFAULT)
    check("resolve: a name with a NUL is EINVAL", withPath("a\u{0}b") { syscall(SyscallNumber.resolve, $0, $1, op, 64, 0) } == -Errno.EINVAL)
    check("resolve: unknown option bits are EINVAL",
          withPath("x.example") { syscall(SyscallNumber.resolve, $0, $1, op, 64, 1 << 60) } == -Errno.EINVAL)
    check("resolve: an invalid host name is EINVAL", errnoOf { () throws(SysError) in _ = try DNS.resolve("bad..name") } == Errno.EINVAL)
    out[0] = 0
}

// MARK: A process killed while it holds sockets

do throws(SysError) {
    let hold = port &+ 1
    let (r, w) = try File.pipe()
    let pid = try Process.spawn("/bin/nettest", args: ["nettest", "hold", "\(hold)"], stdio: (nil, w.fd, nil))
    w.close()
    var said: [UInt8] = []
    while !said.contains(0x0A) {
        guard let chunk = try? r.read(max: 64), !chunk.isEmpty else { break }
        said += chunk
    }
    r.close()
    check("hold: the child opened five sockets", String(decoding: said, as: UTF8.self) == "holding 5\n")
    Process.kill(pid)
    let st = try Process.waitpid(pid)
    check("hold: the child was killed", st.status == Int(WaitStatus.killed))
    let reuse = errnoOf { () throws(SysError) in
        let l = try Socket.tcp()
        defer { l.close() }
        try l.bind(port: hold)
        try l.listen()
        let u = try Socket.udp()
        defer { u.close() }
        try u.bind(port: hold)
    }
    check("hold: its TCP and UDP ports are free again", reuse == 0)
} catch {
    check("hold: spawn (\(error.message))", false)
}

print("nettest: \(checks) checks, \(failures) failed")
Process.exit(failures == 0 ? 0 : 1)
