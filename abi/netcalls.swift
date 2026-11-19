// The socket, DNS, randomness and time part of the system call ABI (Phases
// 7E, 7F and 8A), compiled into the kernel and every program like
// abi/syscalls.swift. `SyscallNumber.socket` (50) and `.getrandom` (60) are
// declared there; the rest of the 50-69 range is here.
//
// Addresses are IPv4 as a UInt32 in host order (10.0.2.2 is 0x0A00_0202)
// and ports as plain integers, passed in registers: no sockaddr structs on
// the way in. Calls that report an address (accept, recvfrom) store a
// SocketAddress.
//
// Blocking: every call blocks (connect until connected or refused, accept
// until a connection is queued, read/recv until data or end of stream,
// write/send until there is room) unless the socket is non-blocking
// (`SocketFlag.nonBlocking` at socket(), or SocketControl.nonBlocking),
// when it returns -EAGAIN instead (connect: -EINPROGRESS; wait for
// writable, then ask SocketControl.error). A kill ends any wait with
// -EINTR. `wait` (34) works on sockets: readable (data, end of stream, an
// error, or a connection to accept), writable (connected with send space,
// or an error), hangup (the peer closed, or the connection failed).

extension SyscallNumber {
    // socket(kind: SocketKind, flags: SocketFlag) -> fd        = 50
    /// connect(fd, ip, port). TCP: open the connection. UDP and ICMP: set
    /// the default destination for write/send.
    static let connect: UInt64 = 51
    /// bind(fd, port): the local port (TCP before listen or connect; UDP).
    /// Any local address. Port 0 picks an ephemeral port (UDP).
    static let bind: UInt64 = 52
    /// listen(fd, backlog) (TCP, after bind).
    static let listen: UInt64 = 53
    /// accept(fd, addrOut) -> new fd. addrOut (0: don't) gets the peer's
    /// SocketAddress. The new socket inherits non-blocking mode.
    static let accept: UInt64 = 54
    /// sendto(fd, buf, len, ip, port) -> bytes sent. ip 0: the connected
    /// peer (that's `send`). TCP ignores ip/port. A UDP datagram is at most
    /// SocketLimit.maxDatagram bytes (-EMSGSIZE); an ICMP one is an echo
    /// request (see SocketKind.icmp).
    static let sendTo: UInt64 = 55
    /// recvfrom(fd, buf, len, addrOut) -> bytes (0: end of stream, TCP).
    /// addrOut (0: don't) gets the sender's SocketAddress. One datagram per
    /// call for UDP and ICMP (truncated to len).
    static let recvFrom: UInt64 = 56
    /// shutdown(fd, how: SocketShutdown).
    static let shutdown: UInt64 = 57
    /// socket_control(fd, op: SocketControl, value) -> Int: options and
    /// state (see SocketControl).
    static let socketControl: UInt64 = 58
    /// resolve(name, nameLen, out, outLen, options) -> bytes stored in out:
    /// a DNS lookup through the kernel resolver (its cache is shared by
    /// every process). `out` receives a ResolveRecord. `options`: bits 0-47
    /// a server (ip << 16 | port; 0: the configured one), plus ResolveOption
    /// bits. Errors: -ENOENT (no such name), -ENODATA (no IPv4 address),
    /// -ETIMEDOUT, -EIO (server failure), -EMSGSIZE (truncated reply),
    /// -ELOOP (too many CNAMEs), -EINVAL (bad name), -ENETDOWN (no network).
    /// With ResolveOption.nonBlocking: -EAGAIN while the query runs (call
    /// again later; the answer, or the error, is kept for a while).
    static let resolve: UInt64 = 59
    // getrandom(buf, len, flags) -> len                         = 60
    //   ChaCha20 DRBG output (abi: `RandomFlag`, none defined yet: pass 0).
    //   At most 65536 bytes per call (-EINVAL above that).
    /// time() -> Unix seconds (UTC, from the RTC at boot plus the uptime).
    static let time: UInt64 = 61
}

/// Error numbers for the network calls (the Linux values).
enum NetErrno {
    static let ENODATA: Int = 61
    static let ELOOP: Int = 40
    static let ENOTSOCK: Int = 88
    static let EDESTADDRREQ: Int = 89
    static let EMSGSIZE: Int = 90
    static let EPROTOTYPE: Int = 91
    static let EOPNOTSUPP: Int = 95
    static let EADDRINUSE: Int = 98
    static let EADDRNOTAVAIL: Int = 99
    static let ENETDOWN: Int = 100
    static let ENETUNREACH: Int = 101
    static let ECONNABORTED: Int = 103
    static let ECONNRESET: Int = 104
    static let ENOBUFS: Int = 105
    static let EISCONN: Int = 106
    static let ENOTCONN: Int = 107
    static let ETIMEDOUT: Int = 110
    static let ECONNREFUSED: Int = 111
    static let EHOSTUNREACH: Int = 113
    static let EALREADY: Int = 114
    static let EINPROGRESS: Int = 115
}

/// socket() kinds.
enum SocketKind {
    static let tcp: UInt64 = 1
    static let udp: UInt64 = 2
    /// ICMP echo ("ping socket"): send an 8-byte echo header (type 8, code
    /// 0; the checksum and identifier are filled in by the kernel) plus
    /// data to an address; receive the echo replies to this socket's
    /// identifier, header included, with the sender and TTL.
    static let icmp: UInt64 = 3
}

/// socket() flags.
enum SocketFlag {
    static let nonBlocking: UInt64 = 1
}

/// shutdown() `how` bits.
enum SocketShutdown {
    /// Reads return end of stream from now on.
    static let read: UInt64 = 1
    /// TCP: send FIN after the queued data (a half close; keep reading).
    static let write: UInt64 = 2
    static let both: UInt64 = 3
}

/// socket_control() operations. `value` UInt64.max only asks (where
/// setting applies); the result is the old value.
enum SocketControl {
    /// 0 or 1.
    static let nonBlocking: UInt64 = 0
    /// The socket's error as a positive errno (0: none): a failed connect
    /// (ECONNREFUSED, ETIMEDOUT, EHOSTUNREACH), a reset (ECONNRESET), an
    /// ICMP error for UDP (cleared by reading it). Read-only.
    static let error: UInt64 = 1
    /// ip << 16 | port, or 0. Read-only.
    static let localAddress: UInt64 = 2
    static let peerAddress: UInt64 = 3
    /// TCP: disable Nagle (1) or enable it (0).
    static let noDelay: UInt64 = 4
    /// Bytes (TCP) or datagrams (UDP, ICMP) waiting to be read. Read-only.
    static let available: UInt64 = 5
    /// TCP: 1 once connected (ESTABLISHED or later), 0 before. Read-only.
    static let connected: UInt64 = 6
}

/// resolve() option bits (above the 48-bit server field).
enum ResolveOption {
    static let serverMask: UInt64 = (1 << 48) - 1
    static let nonBlocking: UInt64 = 1 << 48
}

/// What resolve() stores: a 4-byte header (address count, 1 if the answer
/// came from the cache, alias count, 0), the addresses (UInt32 each, host
/// order, little endian), then each alias (a CNAME followed, in order) as a
/// NUL-terminated name. Returns the bytes used; -ERANGE if outLen is too
/// small (ResolveRecord.maxSize always fits).
enum ResolveRecord {
    static let headerSize = 4
    static let maxAddresses = 16
    static let maxSize = 4096
}

/// accept/recvfrom's address (8 bytes).
struct SocketAddress {
    var ip: UInt32 = 0
    var port: UInt16 = 0
    /// recvfrom on an ICMP socket: the reply's TTL; else 0.
    var ttl: UInt8 = 0
    var reserved: UInt8 = 0
}

/// Kernel limits on sockets (the calls fail with -EMFILE / -ENOBUFS).
enum SocketLimit {
    /// Open sockets one process may have created (accepted ones count).
    static let perProcess = 32
    /// User sockets in the whole system.
    static let total = 96
    /// Largest UDP payload (MTU 1500 - IP and UDP headers; no fragments).
    static let maxDatagram = 1472
    /// Datagrams queued per UDP/ICMP socket (more are dropped).
    static let datagramQueue = 32
    /// TCP buffers per socket.
    static let tcpReceiveBuffer = 128 * 1024
    static let tcpSendBuffer = 64 * 1024
}
