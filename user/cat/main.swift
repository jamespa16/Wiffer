// /bin/cat [file...]: copy files (or stdin, with no files or "-") to stdout.
func copy(_ f: File) -> Bool {
    while true {
        guard let chunk = try? f.read(max: 4096) else { return false }
        if chunk.isEmpty { return true }
        if File.stdout.writeAll(chunk) < 0 { return false }
    }
}

let names = Array(Process.args.dropFirst())
var failed = false
if names.isEmpty {
    if !copy(File.stdin) { failed = true }
}
for name in names {
    if name == "-" {
        if !copy(File.stdin) { failed = true }
        continue
    }
    do throws(SysError) {
        let f = try File.open(name)
        if !copy(f) { File.stderr.write("cat: \(name): read error\n"); failed = true }
        f.close()
    } catch {
        File.stderr.write("cat: \(name): \(error.message)\n")
        failed = true
    }
}
Process.exit(failed ? 1 : 0)
