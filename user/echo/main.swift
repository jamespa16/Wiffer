// /bin/echo [-n] words...: the words, joined by single spaces.
var args = Array(Process.args.dropFirst())
var addNewline = true
if args.first == "-n" {
    addNewline = false
    args.removeFirst()
}
var line = ""
for (i, a) in args.enumerated() {
    if i > 0 { line += " " }
    line += a
}
if addNewline { line += "\n" }
File.stdout.write(line)
