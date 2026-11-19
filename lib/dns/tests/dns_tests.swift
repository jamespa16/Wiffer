// The kernel's DNS parser and resolver (net_dns.swift, compiled here
// through lib/dns/SRCS): hand-built replies, then a mutation fuzz of the
// parser and of whole replies fed to a resolver (ROADMAP 8I).

private func dnsName(_ n: String) -> [UInt8] {
    var out: [UInt8] = []
    for l in n.split(separator: ".") { out.append(UInt8(l.utf8.count)); out += Array(l.utf8) }
    out.append(0)
    return out
}

private func dnsReply(id: UInt16, name: String, rcode: UInt16 = 0, answers: [[UInt8]]) -> [UInt8] {
    var m: [UInt8] = [UInt8(id >> 8), UInt8(id & 255), 0x81, 0x80 | UInt8(rcode), 0, 1, 0, UInt8(answers.count), 0, 0, 0, 0]
    m += dnsName(name) + [0, 1, 0, 1]
    for a in answers { m += a }
    return m
}

private func aRR(_ ip: [UInt8], ttl: UInt32 = 60) -> [UInt8] {
    [0xC0, 12, 0, 1, 0, 1, UInt8(ttl >> 24), UInt8((ttl >> 16) & 255), UInt8((ttl >> 8) & 255), UInt8(ttl & 255), 0, 4] + ip
}

private func cnameRR(_ target: String) -> [UInt8] {
    let t = dnsName(target)
    return [0xC0, 12, 0, 5, 0, 1, 0, 0, 0, 60, 0, UInt8(t.count)] + t
}

func libTests(_ t: Tests) {
    t.section("parse")
    let good = dnsReply(id: 7, name: "example.com", answers: [cnameRR("www.example.com"), aRR([93, 184, 216, 34])])
    if let m = parseDNS(good) {
        t.equal(m.answers.count, 2, "two answers")
        t.check(m.questions.first?.name == Array("example.com".utf8), "question name")
    } else { t.check(false, "good reply parses") }
    // A compression pointer loop and a forward pointer are refused.
    var loop = dnsReply(id: 1, name: "a.b", answers: [])
    loop[12] = 0xC0; loop[13] = 12
    t.check(parseDNS(loop) == nil, "self-pointing name rejected")
    t.check(parseDNS(Array(good.prefix(20))) == nil, "truncated reply rejected")

    t.section("resolver")
    let stack = NetStack()
    let r = DNSResolver(stack: stack)
    let q = r.start("example.com", server: 0x0A00_0203)
    let id = q.id
    r.handle(q, UDPDatagram(src: 0x0A00_0203, srcPort: 53,
                            data: dnsReply(id: id, name: "example.com", answers: [aRR([1, 2, 3, 4])])))
    t.check(q.state == .done && q.addresses == [0x0102_0304], "an A answer resolves")

    t.section("fuzz")
    let seeds: [[UInt8]] = [good, dnsReply(id: 9, name: "a.b.c.d.example.org", answers: [aRR([1, 1, 1, 1]), aRR([2, 2, 2, 2])]),
                            dnsReply(id: 3, name: "x.test", rcode: 3, answers: []),
                            dnsReply(id: 4, name: "example.com", answers: [cnameRR("a.example.com"), cnameRR("b.example.com")]),
                            [0xC0, 0x0C, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]]
    t.fuzz("parseDNS", seeds: seeds, iterations: 30000) { data in
        _ = parseDNS(data)
        _ = dnsReadName(data, 12)
        _ = dnsReadName(data, 0)
    }
    // Whole replies into a live query, with the id patched to match so the
    // resolver goes past its checks (CNAME chains, caching).
    var accepted = 0
    t.fuzz("resolver", seeds: seeds, iterations: 20000) { data in
        let s = NetStack()
        let rr = DNSResolver(stack: s)
        let qq = rr.start("example.com", server: 0x0A00_0203)
        var d = data
        if d.count >= 2 { d[0] = UInt8(qq.id >> 8); d[1] = UInt8(qq.id & 255) }
        rr.handle(qq, UDPDatagram(src: 0x0A00_0203, srcPort: 53, data: d))
        if rr.repliesAccepted > 0 { accepted += 1 }
    }
    t.check(accepted > 100, "some mutants get past the resolver's checks", "\(accepted)")
}
