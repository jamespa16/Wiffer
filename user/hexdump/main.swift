// /bin/hexdump [file]: canonical hex + ASCII, 16 bytes a row:
//   00000000  48 65 6c 6c 6f 0a                                 |Hello.|
let digits: [UInt8] = Array("0123456789abcdef".utf8)

func hex(_ v: Int, _ width: Int) -> String {
    var out: [UInt8] = []
    var shift = (width - 1) * 4
    while shift >= 0 {
        out.append(digits[(v >> shift) & 15])
        shift -= 4
    }
    return String(decoding: out, as: UTF8.self)
}

func row(_ offset: Int, _ bytes: ArraySlice<UInt8>) {
    var line = hex(offset, 8) + " "
    for i in 0..<16 {
        if i == 8 { line += " " }
        if i < bytes.count {
            line += " " + hex(Int(bytes[bytes.startIndex + i]), 2)
        } else {
            line += "   "
        }
    }
    line += "  |"
    for b in bytes { line += b >= 0x20 && b < 0x7F ? String(Character(Unicode.Scalar(b))) : "." }
    print(line + "|")
}

var source = File.stdin
var name = "stdin"
if let path = Process.args.dropFirst().first {
    name = path
    do throws(SysError) {
        source = try File.open(path)
    } catch {
        File.stderr.write("hexdump: \(path): \(error.message)\n")
        Process.exit(1)
    }
}
var offset = 0
var pending: [UInt8] = []
while true {
    guard let chunk = try? source.read(max: 4096) else {
        File.stderr.write("hexdump: \(name): read error\n")
        Process.exit(1)
    }
    if chunk.isEmpty { break }
    pending.append(contentsOf: chunk)
    while pending.count >= 16 {
        row(offset, pending[0..<16])
        offset += 16
        pending.removeFirst(16)
    }
}
if !pending.isEmpty {
    row(offset, pending[...])
    offset += pending.count
}
print(hex(offset, 8))
