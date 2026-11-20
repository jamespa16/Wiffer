// Blob, File and FormData (File API / XHR Standard), in memory. FormData(form)
// builds the form's entry list from the page's control state (the values
// the user typed and scripts set).

extension JSWeb {
    /// BlobPart sequence -> bytes.
    func blobParts(_ v: JSValue) throws(JSThrow) -> [UInt8] {
        if v.isUndefined { return [] }
        if !v.isObject { throw typeError("Failed to construct 'Blob': The provided value cannot be converted to a sequence.") }
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        _ = heap.root(v)
        let (it, next) = try realm.getIterator(v)
        _ = heap.root(it); _ = heap.root(next)
        var out: [UInt8] = []
        var n = 0
        while n < 100_000 {
            let (done, part) = try realm.iteratorStep(it, next)
            if done { break }
            let d2 = heap.rootDepth
            _ = heap.root(part)
            if let blob = blobClass.unwrap(part) { out += blob.bytes }
            else if let bytes = bufferSourceBytes(part) { out += bytes }
            else { out += Array(try str(part).utf8) }
            if out.count > maxBody { throw realm.throwRangeError("Blob too large") }
            heap.popRoots(to: d2)
            n += 1
        }
        return out
    }

    func blobType(_ opts: JSValue) throws(JSThrow) -> String {
        let t = try member(opts, "type")
        if t.isUndefined { return "" }
        let s = try str(t)
        for c in s.utf8 where c < 0x20 || c > 0x7e { return "" }
        return jswebLowerASCII(s)
    }

    /// The entry list of a form (HTML "constructing the entry list").
    func formEntries(_ form: HTMLNode, submitter: HTMLNode?) -> [JSWebFormEntry] {
        var out: [JSWebFormEntry] = []
        let root = form.isConnected ? (form.ownerDocument ?? form) : form
        var controls: [HTMLNode] = []
        root.walk { n in
            if n.kind == .element && n.namespace == .html,
               n.name == "input" || n.name == "select" || n.name == "textarea" || n.name == "button" || n.name == "object",
               b.formOwner(n) === form {
                controls.append(n)
            }
            return controls.count < 50_000
        }
        for c in controls {
            if b.isDisabled(c) { continue }
            let type = jswebLowerASCII(c.attribute("type") ?? "")
            if c.name == "button" || (c.name == "input" && (type == "submit" || type == "image" || type == "reset" || type == "button")) {
                if c !== submitter || type == "reset" || (c.name == "button" && type == "button") { continue }
            }
            if c.name == "input" && (type == "checkbox" || type == "radio") && !page.controlChecked(of: c) { continue }
            if c.name == "object" { continue }
            let name = c.attribute("name") ?? ""
            if c.name == "input" && type == "image" {
                let p = name.isEmpty ? "" : name + "."
                out.append(JSWebFormEntry(name: p + "x", value: "0"))
                out.append(JSWebFormEntry(name: p + "y", value: "0"))
                continue
            }
            if name.isEmpty { continue }
            if c.name == "select" {
                for o in b.selectOptions(c) where page.optionSelected(o) && !b.isDisabled(o) {
                    out.append(JSWebFormEntry(name: name, value: b.HTMLOptionElement_value(o)))
                }
                continue
            }
            if c.name == "input" && (type == "checkbox" || type == "radio") {
                out.append(JSWebFormEntry(name: name, value: c.attribute("value") ?? "on"))
                continue
            }
            if c.name == "input" && type == "file" {
                let f = JSWebBlob([], type: "application/octet-stream")
                f.name = ""
                out.append(JSWebFormEntry(name: name, value: "", file: f))
                continue
            }
            var v = page.controlValue(of: c)
            if c.name == "textarea" {
                // Normalize newlines to CRLF.
                let u = Array(v.utf8)
                var r: [UInt8] = []
                var i = 0
                while i < u.count {
                    if u[i] == 0x0d { r += [0x0d, 0x0a]; if i + 1 < u.count && u[i + 1] == 0x0a { i += 1 } }
                    else if u[i] == 0x0a { r += [0x0d, 0x0a] }
                    else { r.append(u[i]) }
                    i += 1
                }
                v = String(decoding: r, as: UTF8.self)
            }
            out.append(JSWebFormEntry(name: name, value: v))
            if c.name == "input" && (type == "text" || type == "search"), let dn = c.attribute("dirname"), !dn.isEmpty {
                out.append(JSWebFormEntry(name: dn, value: "ltr"))
            }
        }
        return out
    }

    func formValue(_ v: JSValue, _ filename: JSValue) throws(JSThrow) -> (String, JSWebBlob?) {
        if let blob = blobClass.unwrap(v) {
            let f = JSWebBlob(blob.bytes, type: blob.type)
            f.name = filename.isUndefined ? (blob.name ?? "blob") : try str(filename)
            f.lastModified = blob.lastModified
            return ("", f)
        }
        return (try str(v), nil)
    }

    func formEntryValue(_ e: JSWebFormEntry) -> JSValue {
        if let f = e.file { return blobClass.wrap(f) }
        return js(e.value)
    }

    func installBlobAndFormData() {
        let web = self
        blobClass = JSHostClass<JSWebBlob>(realm: realm, name: "Blob")
        typealias BM = JSHostMethod<JSWebBlob>
        typealias BA = JSHostAccessor<JSWebBlob>
        blobClass.define(methods: [
            BM("text", 0) { (realm: JSRealm, bl: JSWebBlob, args: JSArgs) throws(JSThrow) -> JSValue in
                let bytes = bl.bytes
                return try web.settled { () throws(JSThrow) -> JSValue in web.js(jswebDecodeText(bytes)) }
            },
            BM("arrayBuffer", 0) { (realm: JSRealm, bl: JSWebBlob, args: JSArgs) throws(JSThrow) -> JSValue in
                let bytes = bl.bytes
                return try web.settled { () throws(JSThrow) -> JSValue in try web.realm.newArrayBuffer(bytes: bytes) }
            },
            BM("bytes", 0) { (realm: JSRealm, bl: JSWebBlob, args: JSArgs) throws(JSThrow) -> JSValue in
                let bytes = bl.bytes
                return try web.settled { () throws(JSThrow) -> JSValue in try web.uint8Array(bytes) }
            },
            BM("slice", 0) { (realm: JSRealm, bl: JSWebBlob, args: JSArgs) throws(JSThrow) -> JSValue in
                let n = bl.bytes.count
                func rel(_ v: JSValue, _ dflt: Int) throws(JSThrow) -> Int {
                    if v.isUndefined { return dflt }
                    let x = try realm.toNumber(v)
                    if x.isNaN { return 0 }
                    if x < 0 { return max(n + Int(max(x, -Double(n))), 0) }
                    return min(Int(min(x, Double(n))), n)
                }
                let s = try rel(args[0], 0), e = try rel(args[1], n)
                let t = args[2].isUndefined ? "" : jswebLowerASCII(try web.str(args[2]))
                return web.blobClass.wrap(JSWebBlob(s < e ? Array(bl.bytes[s..<e]) : [], type: t))
            },
        ], accessors: [
            BA("size", get: { (realm: JSRealm, bl: JSWebBlob) throws(JSThrow) -> JSValue in .number(bl.bytes.count) }),
            BA("type", get: { (realm: JSRealm, bl: JSWebBlob) throws(JSThrow) -> JSValue in web.js(bl.type) }),
            BA("name", get: { (realm: JSRealm, bl: JSWebBlob) throws(JSThrow) -> JSValue in bl.name.map { web.js($0) } ?? .undefined }),
            BA("lastModified", get: { (realm: JSRealm, bl: JSWebBlob) throws(JSThrow) -> JSValue in
                bl.name == nil ? .undefined : .number(bl.lastModified)
            }),
        ])
        setToStringTag(blobClass.prototype, "Blob")
        blobClass.exposeConstructor(length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSWebBlob in
            JSWebBlob(try web.blobParts(args[0]), type: try web.blobType(args[1]))
        }
        // File: a Blob with a name (same class; `new File(parts, name, opts)`).
        let fileProto = heap.newObject(proto: blobClass.prototype)
        let d = heap.rootDepth
        _ = heap.root(fileProto)
        b.keep.append(fileProto)
        realm.defineConstructor("File", length: 2, prototype: fileProto) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            if !args.isConstruct { throw web.typeError("Failed to construct 'File': Please use the 'new' operator.") }
            if args.count < 2 { throw web.typeError("Failed to construct 'File': 2 arguments required.") }
            let f = JSWebBlob(try web.blobParts(args[0]), type: try web.blobType(args[2]))
            f.name = try web.str(args[1])
            let lm = try web.member(args[2], "lastModified")
            f.lastModified = lm.isUndefined ? web.b.host.wallClock() : try realm.toNumber(lm)
            let w = web.blobClass.wrap(f)
            let d2 = web.heap.rootDepth
            _ = web.heap.root(w)
            _ = web.heap.setPrototypeOf(w, fileProto)
            web.heap.popRoots(to: d2)
            return w
        }
        setToStringTag(fileProto, "File")
        heap.popRoots(to: d)

        formDataClass = JSHostClass<JSWebFormData>(realm: realm, name: "FormData")
        typealias FM = JSHostMethod<JSWebFormData>
        formDataClass.define(methods: [
            FM("append", 2) { (realm: JSRealm, fd: JSWebFormData, args: JSArgs) throws(JSThrow) -> JSValue in
                if args.count < 2 { throw web.typeError("Failed to execute 'append' on 'FormData': 2 arguments required.") }
                let (v, f) = try web.formValue(args[1], args[2])
                if fd.entries.count < 100_000 { fd.entries.append(JSWebFormEntry(name: try web.str(args[0]), value: v, file: f)) }
                return .undefined
            },
            FM("set", 2) { (realm: JSRealm, fd: JSWebFormData, args: JSArgs) throws(JSThrow) -> JSValue in
                if args.count < 2 { throw web.typeError("Failed to execute 'set' on 'FormData': 2 arguments required.") }
                let n = try web.str(args[0])
                let (v, f) = try web.formValue(args[1], args[2])
                let e = JSWebFormEntry(name: n, value: v, file: f)
                if let i = fd.entries.firstIndex(where: { $0.name == n }) {
                    fd.entries[i] = e
                    var j = fd.entries.count - 1
                    while j > i { if fd.entries[j].name == n { fd.entries.remove(at: j) }; j -= 1 }
                } else {
                    fd.entries.append(e)
                }
                return .undefined
            },
            FM("delete", 1) { (realm: JSRealm, fd: JSWebFormData, args: JSArgs) throws(JSThrow) -> JSValue in
                let n = try web.str(args[0])
                fd.entries.removeAll { $0.name == n }
                return .undefined
            },
            FM("get", 1) { (realm: JSRealm, fd: JSWebFormData, args: JSArgs) throws(JSThrow) -> JSValue in
                let n = try web.str(args[0])
                for e in fd.entries where e.name == n { return web.formEntryValue(e) }
                return .null
            },
            FM("getAll", 1) { (realm: JSRealm, fd: JSWebFormData, args: JSArgs) throws(JSThrow) -> JSValue in
                let n = try web.str(args[0])
                let d = web.heap.rootDepth
                defer { web.heap.popRoots(to: d) }
                var vals: [JSValue] = []
                for e in fd.entries where e.name == n { let v = web.formEntryValue(e); _ = web.heap.root(v); vals.append(v) }
                return web.array(vals)
            },
            FM("has", 1) { (realm: JSRealm, fd: JSWebFormData, args: JSArgs) throws(JSThrow) -> JSValue in
                let n = try web.str(args[0])
                return .bool(fd.entries.contains { $0.name == n })
            },
            FM("forEach", 1) { (realm: JSRealm, fd: JSWebFormData, args: JSArgs) throws(JSThrow) -> JSValue in
                let f = args[0]
                if !web.heap.isCallable(f) { throw web.typeError("FormData.forEach: callback is not a function") }
                var i = 0
                while i < fd.entries.count {
                    let e = fd.entries[i]
                    let d = web.heap.rootDepth
                    let ks = web.js(e.name); _ = web.heap.root(ks)
                    let vs = web.formEntryValue(e); _ = web.heap.root(vs)
                    _ = try realm.call(f, this: args[1], args: [vs, ks, args.this])
                    web.heap.popRoots(to: d)
                    i += 1
                }
                return .undefined
            },
            FM("entries", 0) { (realm: JSRealm, fd: JSWebFormData, args: JSArgs) throws(JSThrow) -> JSValue in
                let l = fd.entries
                return try web.listIterator(l.count, kind: 2) { (i: Int) throws(JSThrow) -> (String, JSValue) in (l[i].name, web.formEntryValue(l[i])) }
            },
            FM("keys", 0) { (realm: JSRealm, fd: JSWebFormData, args: JSArgs) throws(JSThrow) -> JSValue in
                let l = fd.entries
                return try web.listIterator(l.count, kind: 0) { (i: Int) throws(JSThrow) -> (String, JSValue) in (l[i].name, .undefined) }
            },
            FM("values", 0) { (realm: JSRealm, fd: JSWebFormData, args: JSArgs) throws(JSThrow) -> JSValue in
                let l = fd.entries
                return try web.listIterator(l.count, kind: 1) { (i: Int) throws(JSThrow) -> (String, JSValue) in (l[i].name, web.formEntryValue(l[i])) }
            },
        ])
        aliasIterator(formDataClass.prototype, "entries")
        setToStringTag(formDataClass.prototype, "FormData")
        formDataClass.exposeConstructor(length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSWebFormData in
            let fd = JSWebFormData()
            if !args[0].isUndefined {
                guard let form = web.b.nodeClass.unwrap(args[0]), form.kind == .element, form.name == "form" else {
                    throw web.typeError("Failed to construct 'FormData': parameter 1 is not of type 'HTMLFormElement'.")
                }
                var submitter: HTMLNode? = nil
                if !args[1].isNullish {
                    guard let s = web.b.nodeClass.unwrap(args[1]), web.b.formOwner(s) === form else {
                        throw realm.throwTypeError("Failed to construct 'FormData': The specified element is not a submit button of this form.")
                    }
                    submitter = s
                }
                fd.entries = web.formEntries(form, submitter: submitter)
            }
            return fd
        }
    }
}
