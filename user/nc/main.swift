// /bin/nc: a TCP (or UDP) pipe between the terminal and the network.
//
//   nc [-u] [-v] <host> <port>      connect (TCP), or send to (UDP)
//   nc -l [-v] <port>               listen for one TCP connection
//
// stdin goes to the socket and the socket to stdout, through one wait()
// loop. End of input (Ctrl-D) half-closes the connection (TCP shutdown);
// nc exits when the peer closes (TCP) or on Ctrl-C.

var listenMode = false
var udp = false
var verbose = false
var words: [String] = []
for a in Process.args.dropFirst() {
    switch a {
    case "-l": listenMode = true
    case "-u": udp = true
    case "-v": verbose = true
    default: words.append(a)
    }
}

func usage() -> Never {
    File.stderr.write("usage: nc [-u] [-v] <host> <port> | nc -l [-v] <port>\n")
    Process.exit(2)
}

func die(_ s: String) -> Never {
    File.stderr.write("nc: " + s + "\n")
    Process.exit(1)
}

func note(_ s: String) {
    if verbose { File.stderr.write("nc: " + s + "\n") }
}

func port(_ s: String) -> UInt16 {
    guard let p = Int(s), p > 0, p < 65536 else { die("bad port '\(s)'") }
    return UInt16(p)
}

var sock: Socket
do throws(SysError) {
    if listenMode {
        guard words.count == 1, !udp else { usage() }
        let l = try Socket.tcp()
        try l.bind(port: port(words[0]))
        try l.listen(backlog: 1)
        note("listening on port \(words[0])")
        let (c, from) = try l.accept()
        l.close()
        note("connection from \(from.ipString):\(from.port)")
        sock = c
    } else {
        guard words.count == 2 else { usage() }
        var ip = IPv4.parse(words[0])
        if ip == nil {
            ip = try DNS.resolve(words[0]).addresses.first
        }
        guard let addr = ip else { die("\(words[0]): no address") }
        sock = udp ? try Socket.udp() : try Socket.tcp()
        try sock.connect(addr, port(words[1]))
        note("connected to \(IPv4.string(addr)):\(words[1])")
    }
} catch {
    die(error.message)
}

var stdinOpen = true
var buffer = [UInt8](repeating: 0, count: 16384)
var received = 0
var sent = 0
while true {
    var fds = [WaitFD(socket: sock, events: WaitEvent.readable)]
    if stdinOpen { fds.append(WaitFD(fd: 0, events: WaitEvent.readable, revents: 0)) }
    let n = wait(&fds, timeoutMs: -1)
    if n < 0 { die("wait: \(SysError(errno: -n).message)") }
    if fds[0].revents & (WaitEvent.readable | WaitEvent.hangup) != 0 {
        let got = buffer.withUnsafeMutableBytes { sock.receive(into: $0) }
        if got < 0 { die(SysError(errno: -got).message) }
        if got == 0 { break } // the peer closed
        received += got
        File.stdout.writeAll(Array(buffer[0..<got]))
    }
    if stdinOpen && fds.count > 1 && fds[1].revents & (WaitEvent.readable | WaitEvent.hangup) != 0 {
        let got = buffer.withUnsafeMutableBytes { File.stdin.read(into: $0) }
        if got <= 0 {
            stdinOpen = false
            if !udp { sock.shutdown(SocketShutdown.write) }
            note("end of input: sent \(sent) bytes")
            if udp { break }
        } else {
            let r = sock.sendAll(Array(buffer[0..<got]))
            if r < 0 { die(SysError(errno: -r).message) }
            sent += got
        }
    }
}
note("closed: received \(received) bytes, sent \(sent)")
sock.close()
