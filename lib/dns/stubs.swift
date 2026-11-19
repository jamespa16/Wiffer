// Host-test stand-ins for the kernel pieces net_dns.swift touches (IPv4
// address, UDP socket, the stack's clock and timers). lib/dns/SRCS pulls in
// the kernel's net_dns.swift itself, so the real parser and resolver are
// what the tests run.

typealias IPv4Addr = UInt32

struct UDPDatagram {
    var src: IPv4Addr
    var srcPort: UInt16
    var data: [UInt8]
}

final class UDPSocket {
    var onReceive: (() -> Void)?
    var sent: [[UInt8]] = []
    var closed = false
    var inbox: [UDPDatagram] = []
    func send(to: IPv4Addr, port: UInt16, _ data: [UInt8]) -> Bool { sent.append(data); return true }
    func receive() -> UDPDatagram? { inbox.isEmpty ? nil : inbox.removeFirst() }
    func close() { closed = true }
}

final class NetStack {
    var dns: IPv4Addr = 0x0A00_0203
    var now: UInt64 = 0
    var timers: [(UInt64, () -> Void)] = []
    func udpBind() -> UDPSocket? { UDPSocket() }
    func schedule(after ticks: UInt64, _ f: @escaping () -> Void) { timers.append((now &+ ticks, f)) }
}

var dnsStubRNG: UInt64 = 0x1234_5678_9abc_def0
func netRandom() -> UInt64 {
    dnsStubRNG = dnsStubRNG &* 6364136223846793005 &+ 1442695040888963407
    return dnsStubRNG >> 16
}
