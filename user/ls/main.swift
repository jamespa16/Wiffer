// /bin/ls [path...]: list directories (sizes in bytes), like the built-in.
func padLeft(_ s: String, _ n: Int) -> String {
    var out = s
    while out.utf8.count < n { out = " " + out }
    return out
}

func lastComponent(_ path: String) -> String {
    var name = ""
    for part in path.split(separator: "/") { name = String(part) }
    return name.isEmpty ? "/" : name
}

var paths = Array(Process.args.dropFirst())
if paths.isEmpty { paths = ["."] }
var failed = false
for path in paths {
    do throws(SysError) {
        let info = try FS.stat(path)
        if paths.count > 1 { print("\(path):") }
        if info.kind == StatKind.directory {
            for e in try FS.list(path) {
                print(e.isDirectory ? "          " + e.name + "/" : padLeft("\(e.size)", 8) + "  " + e.name)
            }
        } else {
            print(padLeft("\(info.size)", 8) + "  " + lastComponent(path))
        }
    } catch {
        File.stderr.write("ls: \(path): \(error.message)\n")
        failed = true
    }
}
Process.exit(failed ? 1 : 0)
