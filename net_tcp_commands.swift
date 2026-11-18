// Part 7 (Phase 7D): TCP test commands for the shell. Phase 7F moves real
// tools (fetch, nc) to /bin; these stay as harness checks.
//
//   tcpget <ip> <port> [path]   HTTP/1.0 GET; prints the status line, the body
//                               size and its FNV-1a 64 hash, time and speed
//   tcplisten <port>            accept one connection and echo it until the
//                               peer closes; prints the byte count and hash
//   netstat                     TCP connections and listeners

func tcpParsePort(_ s: Substring) -> UInt16? {
    guard let n = parseInt(s), n > 0, n < 65536 else { return nil }
    return UInt16(n)
}

func tcpgetCommand(_ args: [Substring], say: (String) -> Void) {
    guard args.count == 2 || args.count == 3, let ip = parseIPv4(args[0]), let port = tcpParsePort(args[1]) else {
        say("usage: tcpget <ip> <port> [path]")
        return
    }
    let path = args.count == 3 ? String(args[2]) : "/"
    guard let stack = netStack else { say("tcpget: no network interface"); return }
    guard let c = TCPConnection.connect(stack, to: ip, port: port) else { say("tcpget: cannot open a connection"); return }
    let start = ticks
    netBlock(timeout: 3000) { c.connected || c.error != nil || c.isClosed }
    guard c.connected else {
        say("tcpget: " + (netInterrupted ? "interrupted" : (c.error?.message ?? "connection timed out")))
        c.abort()
        return
    }
    let request = Array("GET \(path) HTTP/1.0\r\nHost: \(ipString(ip))\r\nUser-Agent: wiffer-tcpget\r\n\r\n".utf8)
    var off = 0
    while off < request.count {
        let n = c.send(request, from: off)
        if n < 0 { break }
        off += n
        if n == 0 { netBlock(timeout: 500) { c.writable } }
    }
    var header: [UInt8] = []
    var inBody = false
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    var body = 0
    var total = 0
    var buf = [UInt8](repeating: 0, count: 65536)
    var problem: String? = nil
    while true {
        let n = buf.withUnsafeMutableBytes { c.receive(into: $0) }
        if n > 0 {
            total += n
            if inBody {
                hash = fnv1a64(buf[0..<n], hash)
                body += n
            } else {
                header.append(contentsOf: buf[0..<n])
                var end = -1
                var i = 0
                while i + 3 < header.count {
                    if header[i] == 13 && header[i + 1] == 10 && header[i + 2] == 13 && header[i + 3] == 10 { end = i; break }
                    i += 1
                }
                if end >= 0 {
                    inBody = true
                    let rest = header[(end + 4)...]
                    hash = fnv1a64(rest, hash)
                    body += rest.count
                    header.removeSubrange(end..<header.count)
                } else if header.count > 16384 {
                    problem = "header too long"
                    break
                }
            }
            continue
        }
        if c.eof || c.error != nil { break }
        if !netBlock(timeout: 3000, { c.readable }) {
            problem = netInterrupted ? "interrupted" : "timed out waiting for data"
            break
        }
    }
    let ms = (ticks &- start) * 10
    if let e = c.error { problem = e.message }
    c.close()
    var status = ""
    for b in header {
        if b == 13 || b == 10 { break }
        status.append(Character(Unicode.Scalar(b < 128 ? b : 63)))
    }
    if !status.isEmpty { say("tcpget: \(status)") }
    if let problem { say("tcpget: \(problem)") }
    let rate = ms > 0 ? UInt64(total) * 1000 / 1024 / ms : 0
    say("tcpget: \(body) body bytes (\(total) received), fnv1a \(hexDigits(hash, 16)), \(ms) ms, \(rate) KiB/s")
}

func tcplistenCommand(_ args: [Substring], say: (String) -> Void) {
    guard args.count == 1, let port = tcpParsePort(args[0]) else { say("usage: tcplisten <port>"); return }
    guard let stack = netStack else { say("tcplisten: no network interface"); return }
    guard let l = TCPConnection.listen(stack, port: port, backlog: 1) else { say("tcplisten: port \(port) is in use"); return }
    say("tcplisten: listening on port \(port)")
    netBlock(timeout: 6000) { l.readable }
    guard let c = l.accept() else {
        l.close()
        say("tcplisten: " + (netInterrupted ? "interrupted" : "no connection"))
        return
    }
    l.close()
    say("tcplisten: connection from \(ipString(c.remoteIP)):\(c.remotePort)")
    var pending: [UInt8] = []
    var echoed = 0
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    var problem: String? = nil
    while true {
        var progress = false
        if pending.count < 65536 {
            let chunk = c.receive(max: 65536 - pending.count)
            if !chunk.isEmpty {
                hash = fnv1a64(chunk, hash)
                pending.append(contentsOf: chunk)
                progress = true
            }
        }
        if !pending.isEmpty {
            let n = c.send(pending)
            if n < 0 { problem = c.error?.message ?? "cannot send"; break }
            if n > 0 {
                pending.removeFirst(n)
                echoed += n
                progress = true
            }
        }
        if let e = c.error { problem = e.message; break }
        if c.eof && pending.isEmpty { break }
        // Wait only for what makes progress now: bytes to read with room for
        // them, or send space for what is pending. (`readable` alone stays
        // true at EOF, and the loop would spin without yielding to netd.)
        if !progress && !netBlock(timeout: 3000, {
            c.error != nil || (pending.count < 65536 && c.available > 0) || (!pending.isEmpty && c.sendSpace > 0)
                || (pending.isEmpty && c.eof)
        }) {
            problem = netInterrupted ? "interrupted" : "timed out"
            break
        }
    }
    c.close()
    netBlock(timeout: 300) { c.isClosed }
    if let problem { say("tcplisten: \(problem)") }
    say("tcplisten: echoed \(echoed) bytes, fnv1a \(hexDigits(hash, 16))")
}

func netstatLines() -> [String] {
    guard let tcp = netStack?.tcp else { return ["no network interface"] }
    var lines = ["proto local                 remote                state        recv-q send-q"]
    func pad(_ s: String, _ n: Int) -> String { s.count >= n ? s + " " : s + String(repeating: " ", count: n - s.count) }
    for l in tcp.listeners {
        lines.append("tcp   " + pad("*:\(l.localPort)", 22) + pad("*:*", 22) + pad(l.state.name, 13) + "\(l.acceptQueue.count)/\(l.backlog)")
    }
    for c in tcp.connections {
        lines.append("tcp   " + pad("\(ipString(c.localIP)):\(c.localPort)", 22) + pad("\(ipString(c.remoteIP)):\(c.remotePort)", 22)
                     + pad(c.state.name, 13) + pad("\(c.available)", 7) + "\(c.sendBuf.count)")
    }
    let s = tcp.stats
    lines.append("segments in \(s.segsIn) out \(s.segsOut), retransmits \(s.retransmits) (fast \(s.fastRetransmits), timeouts \(s.timeouts)), resets in \(s.resetsReceived) out \(s.resetsSent), bad \(s.badHeader + s.badChecksum)")
    return lines
}

extension Shell {
    static func tcpCommands() -> [Command<T>] {
        [
            Command(name: "tcpget", args: "<ip> <p>", help: "HTTP/1.0 GET over TCP (tcpget ip port [path]): body size, FNV-1a, speed") { sh, args in
                tcpgetCommand(args) { sh.say($0) }
            },
            Command(name: "tcplisten", args: "<p>", help: "accept one TCP connection on port p and echo it back") { sh, args in
                tcplistenCommand(args) { sh.say($0) }
            },
            Command(name: "netstat", args: "", help: "TCP connections and listeners") { sh, _ in
                for l in netstatLines() { sh.say(l) }
            },
        ]
    }
}
