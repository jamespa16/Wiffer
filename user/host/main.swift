// /bin/host <name> [server[:port]]: a DNS lookup through the kernel
// resolver (the resolve call, 7E), with the shell built-in's output.

let argv = Process.args
guard argv.count == 2 || argv.count == 3 else {
    print("usage: host <name> [server[:port]]")
    Process.exit(2)
}
var server: UInt32 = 0
var port: UInt16 = 53
if argv.count == 3 {
    let parts = argv[2].split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count <= 2, let a = IPv4.parse(String(parts[0])) else {
        print("host: bad server '\(argv[2])'")
        Process.exit(2)
    }
    server = a
    if parts.count == 2 {
        guard let p = Int(String(parts[1])), p > 0, p < 65536 else {
            print("host: bad port in '\(argv[2])'")
            Process.exit(2)
        }
        port = UInt16(p)
    }
}
let name = argv[1]

/// The resolver's wording for each error (DNSError.message in the kernel).
func dnsMessage(_ errno: Int) -> String {
    switch errno {
    case Errno.ENOENT: return "NXDOMAIN (no such name)"
    case NetErrno.ENODATA: return "no IPv4 address in the answer"
    case NetErrno.ETIMEDOUT: return "no answer from the DNS server (timed out)"
    case Errno.EIO: return "the DNS server reported an error"
    case NetErrno.EMSGSIZE: return "reply truncated (TCP fallback not supported)"
    case NetErrno.ELOOP: return "too many CNAMEs"
    case Errno.EINVAL: return "invalid host name"
    case NetErrno.ENETDOWN: return "no DNS server, or the query could not be sent"
    default: return SysError(errno: errno).message
    }
}

do throws(SysError) {
    let a = try DNS.resolve(name, server: server, port: port)
    var owner = name
    for alias in a.aliases {
        print("\(owner) is an alias for \(alias).")
        owner = alias
    }
    for ip in a.addresses { print("\(owner) has address \(IPv4.string(ip))") }
    if a.cached { print("(cached)") }
} catch {
    print("Host \(name) not found: \(dnsMessage(error.errno))")
    Process.exit(1)
}
