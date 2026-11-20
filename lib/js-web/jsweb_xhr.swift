// XMLHttpRequest (XHR Standard), asynchronous only: open(..., false) throws
// InvalidAccessError, because a synchronous request would block the
// browser's only thread. Requests go through the same CORS layer as fetch().
// An XHR is an EventTarget object (lib/js-dom's JSDOMEventTargetObject)
// whose prototype is XMLHttpRequest.prototype and whose hostData is the
// JSWebXHR below. Progress events are plain Events with loaded / total /
// lengthComputable properties.

final class JSWebXHR {
    var readyState = 0
    var method = "GET"
    var url: URLRecord? = nil
    var headers: [(name: String, value: String)] = []
    var sendFlag = false
    var response: JSWebResponse? = nil
    var networkError = false
    var responseType = ""
    var timeout = 0
    var withCredentials = false
    var mimeOverride: String? = nil
    var job: JSWebJob? = nil
    /// Bumped by open/abort: completions and timers of older sends are ignored.
    var generation = 0
    let upload = JSDOMEventTargetObject(.EventTarget)
    init() {}
}

extension JSWeb {
    func thisXHR(_ v: JSValue, _ member: String) throws(JSThrow) -> (JSDOMEventTargetObject, JSWebXHR) {
        guard let o = b.classes.EventTargetObject.unwrap(v), o.protoOverride == xhrProto, let d = o.hostData else {
            throw typeError("Illegal invocation: XMLHttpRequest." + member)
        }
        return (o, unsafeDowncast(d, to: JSWebXHR.self))
    }

    func fireXHR(_ t: JSDOMEventTargetObject, _ type: String, progress: (Int, Int)? = nil) {
        let e = JSDOMEvent(.Event, type: type, time: b.now())
        e.isTrusted = true
        let w = b.wrapEvent(e)
        let d = heap.rootDepth
        _ = heap.root(w)
        if let (loaded, total) = progress {
            setValue(w, "loaded", .number(loaded))
            setValue(w, "total", .number(total))
            setValue(w, "lengthComputable", .bool(total > 0))
        }
        _ = try? b.dispatch(e, to: .object(t))
        heap.popRoots(to: d)
    }

    func setXHRState(_ t: JSDOMEventTargetObject, _ x: JSWebXHR, _ s: Int) {
        x.readyState = s
        fireXHR(t, "readystatechange")
    }

    /// The response's MIME type (overrideMimeType first).
    func xhrMIME(_ x: JSWebXHR) -> String {
        x.mimeOverride ?? x.response?.header("Content-Type") ?? "text/xml"
    }

    func xhrText(_ x: JSWebXHR) -> String {
        guard let r = x.response, !x.networkError else { return "" }
        return jswebDecodeText(r.body, label: jswebMIMECharset(xhrMIME(x)))
    }

    /// Request finished, failed, aborted or timed out.
    func xhrFinish(_ t: JSDOMEventTargetObject, _ x: JSWebXHR, event: String) {
        let gen = x.generation
        x.job = nil
        if x.readyState != 4 || x.sendFlag {
            x.sendFlag = false
            setXHRState(t, x, 4)
        }
        if x.generation != gen { b.classes.EventTargetObject.pin(t, false); return }
        let n = x.response?.body.count ?? 0
        if event == "load" { fireXHR(t, "progress", progress: (n, n)) }
        fireXHR(t, event, progress: event == "load" ? (n, n) : (0, 0))
        fireXHR(t, "loadend", progress: event == "load" ? (n, n) : (0, 0))
        b.classes.EventTargetObject.pin(t, false)
    }

    func xhrCancel(_ x: JSWebXHR) {
        if let j = x.job {
            j.aborted = true
            j.finished = true
            if j.netID != 0 { network.cancel(j.netID); j.netID = 0 }
            jobs[j.id] = nil
        }
        x.job = nil
    }

    func installXHR() {
        let web = self
        let etProto = b.protos[JSDOMInterface.EventTarget.rawValue]
        xhrProto = heap.newObject(proto: etProto)
        xhrUploadProto = heap.newObject(proto: etProto)
        let proto = xhrProto
        setToStringTag(proto, "XMLHttpRequest")
        setToStringTag(xhrUploadProto, "XMLHttpRequestUpload")
        let names = ["UNSENT", "OPENED", "HEADERS_RECEIVED", "LOADING", "DONE"]

        func method(_ name: String, _ len: Int, _ f: @escaping (JSDOMEventTargetObject, JSWebXHR, JSArgs) throws(JSThrow) -> JSValue) {
            realm.defineMethod(proto, name, length: len) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
                let (t, x) = try web.thisXHR(args.this, name)
                return try f(t, x, args)
            }
        }
        func accessor(_ name: String, _ g: @escaping (JSDOMEventTargetObject, JSWebXHR) throws(JSThrow) -> JSValue,
                      _ s: ((JSDOMEventTargetObject, JSWebXHR, JSValue) throws(JSThrow) -> Void)? = nil) {
            var setter: JSNativeFunction? = nil
            if let st = s {
                setter = { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
                    let (t, x) = try web.thisXHR(args.this, name)
                    try st(t, x, args[0])
                    return .undefined
                }
            }
            realm.defineGetter(proto, name, setter: setter) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
                let (t, x) = try web.thisXHR(args.this, name)
                return try g(t, x)
            }
        }

        method("open", 2) { (t: JSDOMEventTargetObject, x: JSWebXHR, args: JSArgs) throws(JSThrow) -> JSValue in
            if args.count < 2 { throw web.typeError("Failed to execute 'open' on 'XMLHttpRequest': 2 arguments required.") }
            let m = try web.str(args[0])
            if !jswebIsToken(m) { throw web.b.throwDOM("SyntaxError", "'" + m + "' is not a valid HTTP method.") }
            if jswebIsForbiddenMethod(m) { throw web.b.throwDOM("SecurityError", "'" + m + "' HTTP method is unsupported.") }
            let s = try web.str(args[1])
            guard let resolved = web.b.resolveURL(s), var u = URLRecord.parseOrNil(resolved) else {
                throw web.b.throwDOM("SyntaxError", "Invalid URL")
            }
            if args.count >= 3 && !web.heap.toBoolean(args[2]) {
                throw web.b.throwDOM("InvalidAccessError",
                                     "Synchronous XMLHttpRequest is not supported (it would block the page); use async requests or fetch().")
            }
            if !args[3].isNullish { u.username = Array(try web.str(args[3]).utf8) }
            if !args[4].isNullish { u.password = Array(try web.str(args[4]).utf8) }
            web.xhrCancel(x)
            x.generation += 1
            x.method = jswebNormalizeMethod(m)
            x.url = u
            x.headers = []
            x.sendFlag = false
            x.response = nil
            x.networkError = false
            if let w = web.b.classes.EventTargetObject.existingWrapper(for: t) { web.b.setHiddenSlot(w, 0, .undefined) }
            if x.readyState != 1 { web.setXHRState(t, x, 1) }
            return .undefined
        }
        method("setRequestHeader", 2) { (t: JSDOMEventTargetObject, x: JSWebXHR, args: JSArgs) throws(JSThrow) -> JSValue in
            if x.readyState != 1 || x.sendFlag { throw web.b.throwDOM("InvalidStateError", "The object's state must be OPENED.") }
            let n = try web.str(args[0])
            let v = jswebTrimHTTPSpace(try web.str(args[1]))
            if !jswebIsToken(n) { throw web.b.throwDOM("SyntaxError", "'" + n + "' is not a valid HTTP header field name.") }
            if !jswebIsHeaderValue(v) { throw web.b.throwDOM("SyntaxError", "'" + v + "' is not a valid HTTP header field value.") }
            if jswebIsForbiddenRequestHeader(n) { return .undefined }
            if let i = x.headers.firstIndex(where: { jswebEqualsIgnoreCase($0.name, n) }) {
                x.headers[i].value += ", " + v
            } else if x.headers.count < 1000 {
                x.headers.append((name: n, value: v))
            }
            return .undefined
        }
        method("send", 0) { (t: JSDOMEventTargetObject, x: JSWebXHR, args: JSArgs) throws(JSThrow) -> JSValue in
            if x.readyState != 1 || x.sendFlag { throw web.b.throwDOM("InvalidStateError", "The object's state must be OPENED.") }
            guard let u = x.url else { return .undefined }
            web.xhrCount += 1
            var p = JSWebFetchParams(url: u)
            p.api = "XMLHttpRequest"
            p.method = x.method
            p.headers = x.headers
            if x.method != "GET" && x.method != "HEAD", let (bytes, type) = try web.extractBody(args[0]) {
                p.body = bytes
                if let ty = type, !x.headers.contains(where: { jswebEqualsIgnoreCase($0.name, "Content-Type") }) {
                    p.headers.append((name: "Content-Type", value: ty))
                }
            }
            p.credentials = x.withCredentials ? "include" : "same-origin"
            x.sendFlag = true
            web.b.classes.EventTargetObject.pin(t, true)
            web.fireXHR(t, "loadstart", progress: (0, 0))
            if !x.sendFlag || x.readyState != 1 { return .undefined }   // aborted or reopened by a listener
            let job = JSWebJob(id: web.nextJob)
            web.nextJob += 1
            web.jobs[job.id] = job
            x.job = job
            let gen = x.generation
            if x.timeout > 0, let w = web.b.classes.EventTargetObject.existingWrapper(for: t) {
                let d = web.heap.rootDepth
                _ = web.heap.root(w)
                let st = try web.get(web.realm.global, "setTimeout")
                _ = web.heap.root(st)
                let cb = web.xhrTimeoutCallback()
                _ = try? web.realm.call(st, this: .undefined, args: [cb, .number(x.timeout), w, .number(gen)])
                web.heap.popRoots(to: d)
            }
            web.corsFetch(p, job: job) { outcome in
                if x.generation != gen || job.aborted { return }
                web.jobs[job.id] = nil
                job.finished = true
                switch outcome {
                case .networkError:
                    x.networkError = true
                    x.response = nil
                    web.xhrFinish(t, x, event: "error")
                case .response(let r, _):
                    var rr = r
                    if rr.body.count > web.maxBody { rr.body = Array(rr.body.prefix(web.maxBody)) }
                    rr.headers = rr.headers.filter { !jswebEqualsIgnoreCase($0.name, "Set-Cookie") && !jswebEqualsIgnoreCase($0.name, "Set-Cookie2") }
                    x.response = rr
                    web.setXHRState(t, x, 2)
                    if x.generation != gen { return }
                    web.setXHRState(t, x, 3)
                    if x.generation != gen { return }
                    web.fireXHR(t, "progress", progress: (rr.body.count, rr.body.count))
                    if x.generation != gen { return }
                    x.sendFlag = false
                    web.xhrFinish(t, x, event: "load")
                }
            }
            return .undefined
        }
        method("abort", 0) { (t: JSDOMEventTargetObject, x: JSWebXHR, args: JSArgs) throws(JSThrow) -> JSValue in
            let active = x.job != nil
            web.xhrCancel(x)
            x.generation += 1
            if (x.readyState == 1 && x.sendFlag) || x.readyState == 2 || x.readyState == 3 || active {
                x.networkError = true
                x.response = nil
                x.sendFlag = false
                web.setXHRState(t, x, 4)
                web.fireXHR(t, "abort", progress: (0, 0))
                web.fireXHR(t, "loadend", progress: (0, 0))
            }
            web.b.classes.EventTargetObject.pin(t, false)
            if x.readyState == 4 { x.readyState = 0 }
            return .undefined
        }
        method("getResponseHeader", 1) { (t: JSDOMEventTargetObject, x: JSWebXHR, args: JSArgs) throws(JSThrow) -> JSValue in
            let n = try web.str(args[0])
            guard x.readyState >= 2, let r = x.response else { return .null }
            var out: String? = nil
            for h in r.headers where jswebEqualsIgnoreCase(h.name, n) { out = out.map { $0 + ", " + h.value } ?? h.value }
            return web.b.strOrNull(out)
        }
        method("getAllResponseHeaders", 0) { (t: JSDOMEventTargetObject, x: JSWebXHR, args: JSArgs) throws(JSThrow) -> JSValue in
            guard x.readyState >= 2, let r = x.response else { return web.js("") }
            let h = JSWebHeaders(0)
            for x in r.headers { h.list.append((name: jswebLowerASCII(x.name), value: x.value)) }
            var s = ""
            for (k, v) in h.sortedCombined() { s += k + ": " + v + "\r\n" }
            return web.js(s)
        }
        method("overrideMimeType", 1) { (t: JSDOMEventTargetObject, x: JSWebXHR, args: JSArgs) throws(JSThrow) -> JSValue in
            if x.readyState >= 3 { throw web.b.throwDOM("InvalidStateError", "The object's state must not be LOADING or DONE.") }
            x.mimeOverride = try web.str(args[0])
            return .undefined
        }

        accessor("readyState", { (t: JSDOMEventTargetObject, x: JSWebXHR) throws(JSThrow) -> JSValue in .number(x.readyState) })
        accessor("status", { (t: JSDOMEventTargetObject, x: JSWebXHR) throws(JSThrow) -> JSValue in .number(x.networkError ? 0 : (x.response?.status ?? 0)) })
        accessor("statusText", { (t: JSDOMEventTargetObject, x: JSWebXHR) throws(JSThrow) -> JSValue in web.js(x.networkError ? "" : (x.response?.statusText ?? "")) })
        accessor("responseURL", { (t: JSDOMEventTargetObject, x: JSWebXHR) throws(JSThrow) -> JSValue in
            var u = x.response?.url
            u?.fragment = nil
            return web.js(x.networkError ? "" : (u?.href ?? ""))
        })
        accessor("responseText", { (t: JSDOMEventTargetObject, x: JSWebXHR) throws(JSThrow) -> JSValue in
            if x.responseType != "" && x.responseType != "text" {
                throw web.b.throwDOM("InvalidStateError", "The value is only accessible if the object's 'responseType' is '' or 'text' (was '" + x.responseType + "').")
            }
            if x.readyState < 3 { return web.js("") }
            return web.js(web.xhrText(x))
        })
        accessor("response", { (t: JSDOMEventTargetObject, x: JSWebXHR) throws(JSThrow) -> JSValue in
            if x.responseType == "" || x.responseType == "text" { return web.js(x.readyState < 3 ? "" : web.xhrText(x)) }
            if x.readyState != 4 || x.networkError || x.response == nil { return .null }
            guard let w = web.b.classes.EventTargetObject.existingWrapper(for: t) else { return .null }
            let cached = web.b.hiddenSlot(w, 0)
            if !cached.isUndefined { return cached }
            let body = x.response?.body ?? []
            var v: JSValue = .null
            switch x.responseType {
            case "json":
                do throws(JSThrow) { v = try web.jsonParse(jswebDecodeText(body)) } catch {
                    if web.realm.isTerminating { throw error }
                    _ = web.realm.takeException()
                    v = .null
                }
            case "arraybuffer": v = try web.realm.newArrayBuffer(bytes: body)
            case "blob": v = web.blobClass.wrap(JSWebBlob(body, type: jswebLowerASCII(web.xhrMIME(x))))
            case "document":
                let doc = htmlParse(body)
                web.b.extraDocuments.append(doc)
                v = web.b.wrapNode(doc)
            default: v = .null
            }
            let d = web.heap.rootDepth
            _ = web.heap.root(v)
            web.b.setHiddenSlot(w, 0, v)
            web.heap.popRoots(to: d)
            return v
        })
        accessor("responseXML", { (t: JSDOMEventTargetObject, x: JSWebXHR) throws(JSThrow) -> JSValue in
            if x.responseType != "" && x.responseType != "document" {
                throw web.b.throwDOM("InvalidStateError", "The value is only accessible if the object's 'responseType' is '' or 'document'.")
            }
            guard x.readyState == 4, !x.networkError, let r = x.response else { return .null }
            let e = jswebMIMEEssence(web.xhrMIME(x))
            if e != "text/html" && x.responseType != "document" { return .null }
            let doc = htmlParse(r.body)
            web.b.extraDocuments.append(doc)
            return web.b.wrapNode(doc)
        })
        accessor("responseType", { (t: JSDOMEventTargetObject, x: JSWebXHR) throws(JSThrow) -> JSValue in web.js(x.responseType) }) {
            (t: JSDOMEventTargetObject, x: JSWebXHR, v: JSValue) throws(JSThrow) -> Void in
            let s = try web.str(v)
            if !["", "arraybuffer", "blob", "document", "json", "text"].contains(s) { return }
            if x.readyState >= 3 { throw web.b.throwDOM("InvalidStateError", "The response type cannot be set if the object's state is LOADING or DONE.") }
            x.responseType = s
        }
        accessor("timeout", { (t: JSDOMEventTargetObject, x: JSWebXHR) throws(JSThrow) -> JSValue in .number(x.timeout) }) {
            (t: JSDOMEventTargetObject, x: JSWebXHR, v: JSValue) throws(JSThrow) -> Void in
            x.timeout = try web.b.toUnsignedLong(v)
        }
        accessor("withCredentials", { (t: JSDOMEventTargetObject, x: JSWebXHR) throws(JSThrow) -> JSValue in .bool(x.withCredentials) }) {
            (t: JSDOMEventTargetObject, x: JSWebXHR, v: JSValue) throws(JSThrow) -> Void in
            if x.readyState > 1 || x.sendFlag { throw web.b.throwDOM("InvalidStateError", "The value may only be set if the object's state is UNSENT or OPENED.") }
            x.withCredentials = web.heap.toBoolean(v)
        }
        accessor("upload", { (t: JSDOMEventTargetObject, x: JSWebXHR) throws(JSThrow) -> JSValue in
            x.upload.protoOverride = web.xhrUploadProto
            return web.b.classes.EventTargetObject.wrap(x.upload)
        })
        for ev in ["readystatechange", "loadstart", "progress", "abort", "error", "load", "timeout", "loadend"] {
            accessor("on" + ev, { (t: JSDOMEventTargetObject, x: JSWebXHR) throws(JSThrow) -> JSValue in
                web.b.getEventHandler(.object(t), ev, forwardToWindow: false)
            }) { (t: JSDOMEventTargetObject, x: JSWebXHR, v: JSValue) throws(JSThrow) -> Void in
                try web.b.setEventHandler(.object(t), ev, v, forwardToWindow: false)
            }
        }
        for ev in ["loadstart", "progress", "abort", "error", "load", "timeout", "loadend"] {
            let key = "on" + ev
            realm.defineGetter(xhrUploadProto, key, setter: { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
                guard let o = web.b.classes.EventTargetObject.unwrap(args.this) else { throw web.typeError("Illegal invocation") }
                try web.b.setEventHandler(.object(o), ev, args[0], forwardToWindow: false)
                return .undefined
            }) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
                guard let o = web.b.classes.EventTargetObject.unwrap(args.this) else { throw web.typeError("Illegal invocation") }
                return web.b.getEventHandler(.object(o), ev, forwardToWindow: false)
            }
        }

        let ctor = realm.defineConstructor("XMLHttpRequest", length: 0, prototype: proto) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            if !args.isConstruct { throw web.typeError("Failed to construct 'XMLHttpRequest': Please use the 'new' operator.") }
            let t = JSDOMEventTargetObject(.EventTarget)
            t.protoOverride = web.xhrProto
            t.hostData = JSWebXHR()
            let w = web.b.classes.EventTargetObject.wrap(t)
            if args.newTarget.isObject {
                let p = try realm.getV(args.newTarget, realm.heap.names.prototype)
                if p.isObject && p != web.xhrProto {
                    let d = web.heap.rootDepth
                    _ = web.heap.root(w)
                    _ = web.heap.setPrototypeOf(w, p)
                    web.heap.popRoots(to: d)
                }
            }
            return w
        }
        for (i, n) in names.enumerated() {
            realm.defineValue(ctor, n, .number(i), [])
            realm.defineValue(proto, n, .number(i), [])
        }
    }

    /// The shared timer callback: (xhr wrapper, generation).
    func xhrTimeoutCallback() -> JSValue {
        if timeoutFn.isObject { return timeoutFn }
        let web = self
        let idx = realm.registerNative("xhrTimeout", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            guard let (t, x) = try? web.thisXHR(args[0], "timeout") else { return .undefined }
            let gen = Int(try realm.toNumber(args[1]))
            if x.generation != gen || x.job == nil { return .undefined }
            web.xhrCancel(x)
            x.networkError = true
            x.response = nil
            web.xhrFinish(t, x, event: "timeout")
            return .undefined
        }
        timeoutFn = realm.newNativeFunction(idx)
        return timeoutFn
    }
}
