// /bin/ping [-c count] <host>: ICMP echo through an ICMP socket (7F), with
// the shell built-in's output.

var count = 4
var target: String? = nil
let argv = Process.args
var i = 1
func usage() -> Never {
    print("usage: ping [-c count] <host>")
    Process.exit(2)
}
while i < argv.count {
    if argv[i] == "-c" {
        guard i + 1 < argv.count, let n = Int(argv[i + 1]), n >= 1, n <= 1000 else { usage() }
        count = n
        i += 2
    } else {
        guard target == nil else { usage() }
        target = argv[i]
        i += 1
    }
}
guard let target else { usage() }

var address: UInt32
if let a = IPv4.parse(target) {
    address = a
} else {
    do throws(SysError) {
        guard let a = try DNS.resolve(target).addresses.first else {
            print("ping: \(target): no address")
            Process.exit(1)
        }
        address = a
    } catch {
        print("ping: \(target): \(error.errno == Errno.ENOENT ? "NXDOMAIN (no such name)" : error.message)")
        Process.exit(1)
    }
}

let sock: Socket
do throws(SysError) {
    sock = try Socket.icmp()
} catch {
    print("ping: \(error.message)")
    Process.exit(1)
}

print("PING \(IPv4.string(address)): 32 data bytes")
var received = 0
for seq in 1...count {
    var msg: [UInt8] = [8, 0, 0, 0, 0, 0, UInt8(truncatingIfNeeded: seq >> 8), UInt8(truncatingIfNeeded: seq)]
    for k in 0..<32 { msg.append(UInt8(truncatingIfNeeded: 0x61 + k)) }
    let sentAt = Time.now
    if sock.send(msg, to: address) < 0 {
        print("ping: cannot send (no route)")
        break
    }
    // Wait up to a second for this sequence number's reply.
    var got = false
    while !got {
        let left = sentAt + 1000 - Time.now
        if left <= 0 { break }
        var fds = [WaitFD(socket: sock, events: WaitEvent.readable)]
        if wait(&fds, timeoutMs: left) <= 0 { break }
        guard let (reply, from) = try? sock.receiveFrom(max: 1500), reply.count >= 8 else { continue }
        let rseq = Int(reply[6]) << 8 | Int(reply[7])
        guard rseq == seq & 0xFFFF else { continue }
        got = true
        received += 1
        let ms = Time.now - sentAt
        print("\(reply.count) bytes from \(from.ipString): icmp_seq=\(seq) ttl=\(from.ttl) time=" + (ms == 0 ? "<10" : "\(ms)") + " ms")
    }
    if !got { print("Request timeout for icmp_seq \(seq)") }
    if seq < count {
        let wait = sentAt + 1000 - Time.now
        if wait > 0 { Time.sleep(wait) }
    }
}
print("\(count) packets transmitted, \(received) received, \((count - received) * 100 / count)% packet loss")
sock.close()
Process.exit(received > 0 ? 0 : 1)
