func libTests(_ t: Tests) {
    t.section("ByteReader")
    var r = ByteReader([1, 2, 3, 4, 5, 6, 7, 8, 9])
    t.check(r.u8() == 1, "u8")
    t.check(r.u16() == 0x0203, "u16")
    t.check(r.u24() == 0x040506, "u24")
    t.check(r.remaining == 3, "remaining")
    t.check(r.u32() == nil && !r.ok, "u32 past end fails")
    t.check(r.u8() == nil, "stays failed")
    var s = ByteReader([0, 3, 0xaa, 0xbb, 0xcc, 0xdd])
    if let n = s.u16(), var inner = s.sub(Int(n)) {
        t.equal(inner.bytes(3) ?? [], [0xaa, 0xbb, 0xcc], "sub bytes")
        t.check(inner.atEnd, "sub at end")
    } else { t.check(false, "length-prefixed sub") }
    t.check(s.u8() == 0xdd && s.atEnd, "after sub")
    t.check(ByteReader([1], from: 0, count: 5).ok == false, "bad window")
    t.equal(fnv1a64("a".utf8) == 0xaf63_dc4c_8601_ec8c, true, "fnv1a64")
    t.fuzz("ByteReader", seeds: [[0, 4, 1, 2, 3, 4], [0xff, 0xff]], iterations: 2000) { data in
        var r = ByteReader(data)
        while let n = r.u16(), let sub = r.sub(Int(n)) { _ = sub.remaining }
    }
}
