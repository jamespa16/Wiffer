// /bin/wc [file...]: "lines words bytes [name]" for each file (or stdin);
// with several files, a "total" line too.
struct Counts {
    var lines = 0, words = 0, bytes = 0
}

func count(_ f: File) -> Counts? {
    var c = Counts()
    var inWord = false
    while true {
        guard let chunk = try? f.read(max: 4096) else { return nil }
        if chunk.isEmpty { return c }
        c.bytes += chunk.count
        for b in chunk {
            if b == 0x0A { c.lines += 1 }
            let space = b == 0x20 || b == 0x0A || b == 0x09 || b == 0x0D
            if space { inWord = false } else if !inWord { inWord = true; c.words += 1 }
        }
    }
}

func show(_ c: Counts, _ name: String?) {
    print("\(c.lines) \(c.words) \(c.bytes)" + (name.map { " " + $0 } ?? ""))
}

let names = Array(Process.args.dropFirst())
var total = Counts()
var failed = false
if names.isEmpty {
    if let c = count(File.stdin) { show(c, nil) } else { failed = true }
}
for name in names {
    do throws(SysError) {
        let f = try File.open(name)
        if let c = count(f) {
            show(c, name)
            total.lines += c.lines
            total.words += c.words
            total.bytes += c.bytes
        } else {
            File.stderr.write("wc: \(name): read error\n")
            failed = true
        }
        f.close()
    } catch {
        File.stderr.write("wc: \(name): \(error.message)\n")
        failed = true
    }
}
if names.count > 1 { show(total, "total") }
Process.exit(failed ? 1 : 0)
