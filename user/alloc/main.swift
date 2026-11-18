// /bin/alloc: real Swift allocation in ring 3 (Array, String, Dictionary,
// class instances, large blocks), freed and redone a few rounds, then a
// checksum that doesn't depend on Dictionary order or the hash seed.
// The expected value is checked by the harness and the kernel selftest.

final class Node {
    let value: Int
    var next: Node?
    init(_ value: Int, _ next: Node?) { self.value = value; self.next = next }
}

func round() -> UInt64 {
    var total: UInt64 = 0
    var arrays: [[Int]] = []
    for i in 0..<200 {
        var a: [Int] = []
        for j in 0..<(i * 10) { a.append(i * j) }
        arrays.append(a)
    }
    for a in arrays { for x in a { total &+= UInt64(x) } }

    var d: [String: Int] = [:]
    for i in 0..<2000 { d["key\(i)"] = i * i }
    for (k, v) in d { total &+= UInt64(v) &+ UInt64(k.utf8.count) }
    d.removeAll()

    var s = ""
    for i in 0..<1000 { s += String(i) }
    total &+= UInt64(s.utf8.count)

    var head: Node? = nil
    for i in 0..<5000 { head = Node(i, head) }
    while let n = head { total &+= UInt64(n.value); head = n.next }

    let big = [UInt8](repeating: 7, count: 1 << 20)
    var sum: UInt64 = 0
    for b in big { sum &+= UInt64(b) }
    total &+= sum
    return total
}

var checksum: UInt64 = 0
for _ in 0..<3 { checksum &+= round() }
print("alloc: checksum \(checksum)")
