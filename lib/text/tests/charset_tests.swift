private func u(_ s: String) -> [UInt8] { Array(s.utf8) }

func libTests(_ t: Tests) {
    t.section("UTF-8")
    t.equal(charsetDecodeUTF8(u("héllo €😀")), [0x68, 0xE9, 0x6C, 0x6C, 0x6F, 0x20, 0x20AC, 0x1F600], "valid")
    // WHATWG test vectors for invalid sequences.
    t.equal(charsetDecodeUTF8([0x80]), [0xFFFD], "lone continuation")
    t.equal(charsetDecodeUTF8([0xC0, 0x80]), [0xFFFD, 0xFFFD], "overlong C0")
    t.equal(charsetDecodeUTF8([0xE0, 0x80, 0x80]), [0xFFFD, 0xFFFD, 0xFFFD], "overlong E0")
    t.equal(charsetDecodeUTF8([0xED, 0xA0, 0x80]), [0xFFFD, 0xFFFD, 0xFFFD], "surrogate")
    t.equal(charsetDecodeUTF8([0xF4, 0x90, 0x80, 0x80]), [0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD], ">10FFFF")
    t.equal(charsetDecodeUTF8([0xE2, 0x82]), [0xFFFD], "truncated 3-byte")
    t.equal(charsetDecodeUTF8([0xE2, 0x82, 0x41]), [0xFFFD, 0x41], "bad continuation reprocessed")
    t.equal(charsetDecodeUTF8([0xF0, 0x9F, 0x98]), [0xFFFD], "truncated 4-byte")
    t.equal(charsetDecodeUTF8([0xFF, 0x41]), [0xFFFD, 0x41], "FF")
    t.equal(charsetDecodeUTF8([0xF0, 0x80, 0x80, 0x80]), [0xFFFD, 0xFFFD, 0xFFFD, 0xFFFD], "overlong F0")
    t.equal(charsetDecodeUTF8([0xEF, 0xBB, 0xBF, 0x41], from: 3), [0x41], "skip BOM")
    t.equal(charsetDecodeToUTF8([0xE9, 0x80], .utf8), [0xEF, 0xBF, 0xBD], "to utf8 replacement") // E9 80 -> one FFFD
    t.equal(charsetEncodeUTF8([0x1F600, 0x20AC, 0x41, 0xD800]), [0xF0, 0x9F, 0x98, 0x80, 0xE2, 0x82, 0xAC, 0x41, 0xEF, 0xBF, 0xBD], "encode")

    t.section("windows-1252")
    t.equal(charsetDecode([0x80, 0x93, 0x94, 0x41, 0xE9, 0x81, 0x9F], .windows1252),
            [0x20AC, 0x201C, 0x201D, 0x41, 0xE9, 0x81, 0x178], "table")
    t.equal(charsetDecode([0xE9], .unsupported), [0xE9], "unsupported falls back")

    t.section("UTF-16")
    t.equal(charsetDecode([0x41, 0x00, 0x3D, 0xD8, 0x00, 0xDE], .utf16le), [0x41, 0x1F600], "le surrogate pair")
    t.equal(charsetDecode([0x00, 0x41, 0xD8], .utf16be), [0x41, 0xFFFD], "be odd tail")
    t.equal(charsetDecode([0x00, 0xDC], .utf16le), [0xFFFD], "lone trail")

    t.section("labels")
    t.check(charsetEncodingForLabel("UTF-8") == .utf8, "UTF-8")
    t.check(charsetEncodingForLabel(" utf8 ") == .utf8, "utf8 trimmed")
    t.check(charsetEncodingForLabel("ISO-8859-1") == .windows1252, "latin1")
    t.check(charsetEncodingForLabel("latin1") == .windows1252, "latin1 alias")
    t.check(charsetEncodingForLabel("US-ASCII") == .windows1252, "ascii")
    t.check(charsetEncodingForLabel("windows-1252") == .windows1252, "cp1252")
    t.check(charsetEncodingForLabel("UTF-16LE") == .utf16le, "utf-16le")
    t.check(charsetEncodingForLabel("Shift_JIS") == .unsupported, "sjis unsupported")
    t.check(charsetEncodingForLabel("bogus") == nil, "unknown")
    t.check(charsetEncodingForLabel("") == nil, "empty")

    t.section("content-type charset")
    t.equal(String(decoding: charsetFromContentType(u("text/html; charset=UTF-8")) ?? [], as: UTF8.self), "UTF-8", "plain")
    t.equal(String(decoding: charsetFromContentType(u("text/html;charset=\"iso-8859-1\"; x=y")) ?? [], as: UTF8.self), "iso-8859-1", "quoted")
    t.equal(String(decoding: charsetFromContentType(u("text/html; foo=bar; CHARSET = utf-8 ")) ?? [], as: UTF8.self), "utf-8", "spaces/case")
    t.check(charsetFromContentType(u("text/html")) == nil, "none")

    t.section("detection")
    func det(_ ct: String?, _ body: [UInt8]) -> TextDetection {
        charsetDetectEncoding(contentType: ct.map { u($0) }, body: body)
    }
    var d = det("text/html; charset=windows-1252", u("<meta charset=utf-8>"))
    t.check(d.encoding == .windows1252 && d.source == .header, "header beats meta")
    d = det("text/html; charset=bogus", u("<meta charset=latin1>"))
    t.check(d.encoding == .windows1252 && d.source == .meta, "unknown header label falls through")
    d = det(nil, [0xEF, 0xBB, 0xBF] + u("<meta charset=latin1>"))
    t.check(d.encoding == .utf8 && d.source == .bom && d.bomLength == 3, "utf8 bom beats meta")
    d = det(nil, [0xFF, 0xFE, 0x41, 0])
    t.check(d.encoding == .utf16le && d.bomLength == 2, "utf16le bom")
    d = det(nil, [0xFE, 0xFF, 0, 0x41])
    t.check(d.encoding == .utf16be, "utf16be bom")
    d = det(nil, u("<html><head><meta charset=\"ISO-8859-1\"></head>"))
    t.check(d.encoding == .windows1252 && d.source == .meta, "meta charset")
    d = det(nil, u("<HTML><HEAD><META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=windows-1252\">"))
    t.check(d.encoding == .windows1252 && d.source == .meta, "meta http-equiv")
    d = det(nil, u("<meta content=\"text/html; charset=windows-1252\">"))
    t.check(d.source == .fallback, "content without http-equiv ignored")
    d = det(nil, u("<!-- <meta charset=latin1> --><meta charset=utf-8>"))
    t.check(d.encoding == .utf8 && d.source == .meta, "comment skipped")
    d = det(nil, u("<p class='x>y' title=z><meta charset=latin1>"))
    t.check(d.encoding == .windows1252, "quoted > in other tag")
    d = det(nil, u("<meta charset=utf-16le>"))
    t.check(d.encoding == .utf8 && d.source == .meta, "meta utf-16 means utf-8")
    d = det(nil, u("<meta name=x content=y>"))
    t.check(d.encoding == .utf8 && d.source == .fallback, "default utf-8")
    var late = [UInt8](repeating: 0x20, count: 1100)
    late += u("<meta charset=latin1>")
    d = det(nil, late)
    t.check(d.source == .fallback, "meta after 1024 bytes ignored")
    let doc = charsetDecodeDocument(contentType: nil, body: [0xEF, 0xBB, 0xBF, 0x68, 0x69])
    t.equal(doc.scalars, [0x68, 0x69], "decodeDocument skips BOM")

    t.section("fuzz")
    let seeds: [[UInt8]] = [
        u("<html><meta charset=\"utf-8\"><!-- x --><p a=b>héllo"), [0xEF, 0xBB, 0xBF, 0xE2, 0x82, 0xAC, 0xF0, 0x9F, 0x98, 0x80],
        u("<meta http-equiv=content-type content='text/html; charset=latin1'>"), [0xFF, 0xFE, 0x41, 0x00, 0x3D, 0xD8],
    ]
    t.fuzz("text", seeds: seeds, iterations: 20000) { data in
        let r = charsetDecodeDocument(contentType: nil, body: data)
        _ = charsetEncodeUTF8(r.scalars)
        _ = charsetDecode(data, .utf16be)
        _ = charsetFromContentType(data)
        _ = charsetFromMetaContent(data)
    }
}
