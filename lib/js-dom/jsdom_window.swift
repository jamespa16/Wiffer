// Window (the page realm's global object) and the objects hanging off it:
// Location, History, Navigator, Screen, MediaQueryList (matchMedia),
// Selection (stub), Performance, Storage; requestAnimationFrame and
// requestIdleCallback; atob/btoa; structuredClone. Everything that needs the
// browser goes through JSDOMHost.

final class JSDOMLocation { init() {} }
final class JSDOMHistory { init() {} }
final class JSDOMNavigator { init() {} }
final class JSDOMScreen { init() {} }
final class JSDOMSelection { init() {} }
final class JSDOMPerformance { init() {} }
final class JSDOMAnimatedRect {
    let node: HTMLNode
    init(_ n: HTMLNode) { node = n }
}
final class JSDOMStorage {
    let local: Bool
    init(local: Bool) { self.local = local }
}

extension JSDOMBindings {
    // MARK: Singletons

    func singleton<T: AnyObject>(_ cls: JSHostClass<T>, _ make: () -> T, _ slot: inout T?) -> JSValue {
        if let o = slot { return cls.wrap(o) }
        let o = make()
        slot = o
        let w = cls.wrap(o)
        cls.pin(o, true)
        return w
    }

    func locationObject() -> JSValue { singleton(classes.Location, { JSDOMLocation() }, &locationSingleton) }
    func historyObject() -> JSValue { singleton(classes.History, { JSDOMHistory() }, &historySingleton) }
    func navigatorObject() -> JSValue { singleton(classes.Navigator, { JSDOMNavigator() }, &navigatorSingleton) }
    func screenObject() -> JSValue { singleton(classes.Screen, { JSDOMScreen() }, &screenSingleton) }
    func selectionObject() -> JSValue { singleton(classes.Selection, { JSDOMSelection() }, &selectionSingleton) }
    func performanceObject() -> JSValue { singleton(classes.Performance, { JSDOMPerformance() }, &performanceSingleton) }

    // MARK: Window attributes

    func Window_window(_ w: JSDOMBindings) -> JSValue { realm.global }
    func Window_self(_ w: JSDOMBindings) -> JSValue { realm.global }
    func Window_frames(_ w: JSDOMBindings) -> JSValue { realm.global }
    func Window_globalThis(_ w: JSDOMBindings) -> JSValue { realm.global }
    func Window_parent(_ w: JSDOMBindings) -> JSValue { realm.global }
    func Window_top(_ w: JSDOMBindings) -> JSValue { realm.global }
    func Window_opener(_ w: JSDOMBindings) -> JSValue { .null }
    func Window_frameElement(_ w: JSDOMBindings) -> JSValue { .null }
    func Window_length(_ w: JSDOMBindings) -> Int { 0 }
    func Window_closed(_ w: JSDOMBindings) -> Bool { false }
    func Window_document(_ w: JSDOMBindings) -> JSValue { wrapNode(document) }
    func Window_name(_ w: JSDOMBindings) -> String { windowName }
    func Window_set_name(_ w: JSDOMBindings, _ v: String) { windowName = v }
    func Window_location(_ w: JSDOMBindings) -> JSValue { locationObject() }
    func Window_history(_ w: JSDOMBindings) -> JSValue { historyObject() }
    func Window_navigator(_ w: JSDOMBindings) -> JSValue { navigatorObject() }
    func Window_screen(_ w: JSDOMBindings) -> JSValue { screenObject() }
    func Window_performance(_ w: JSDOMBindings) -> JSValue { performanceObject() }
    func Window_event(_ w: JSDOMBindings) -> JSValue { currentEvent }
    func Window_isSecureContext(_ w: JSDOMBindings) -> Bool { url.map { $0.protocolString == "https:" || $0.hostname == "localhost" } ?? false }
    func Window_origin(_ w: JSDOMBindings) -> String { url?.origin ?? "null" }
    func Window_localStorage(_ w: JSDOMBindings) -> JSValue { singleton(classes.Storage, { JSDOMStorage(local: true) }, &localStorageSingleton) }
    func Window_sessionStorage(_ w: JSDOMBindings) -> JSValue { singleton(classes.Storage, { JSDOMStorage(local: false) }, &sessionStorageSingleton) }

    func Window_close(_ w: JSDOMBindings) {}
    func Window_stop(_ w: JSDOMBindings) {}
    func Window_focus(_ w: JSDOMBindings) {}
    func Window_blur(_ w: JSDOMBindings) {}
    func Window_print(_ w: JSDOMBindings) {}
    func Window_moveTo(_ w: JSDOMBindings, _ x: Int, _ y: Int) {}
    func Window_resizeTo(_ w: JSDOMBindings, _ x: Int, _ y: Int) {}

    func Window_open(_ w: JSDOMBindings, _ u: String, _ target: String, _ features: String) -> JSValue {
        if !u.isEmpty { host.openWindow(resolveURL(u) ?? u, target) }
        return .null
    }

    func Window_alert(_ w: JSDOMBindings, _ m: JSValue) {
        let s = m.isUndefined ? "" : ((try? toStr(m)) ?? "")
        host.alert(s)
    }
    func Window_confirm(_ w: JSDOMBindings, _ m: String) -> Bool { host.confirm(m) }
    func Window_prompt(_ w: JSDOMBindings, _ m: String, _ d: String) -> String? { host.prompt(m, d) }

    func Window_postMessage(_ w: JSDOMBindings, _ msg: JSValue, _ origin: JSValue, _ transfer: JSValue) {
        let p = heap.retain(msg)
        loop.queueTask { [unowned(unsafe) self] in
            let e = JSDOMEvent(.MessageEvent, type: "message", time: self.now())
            e.isTrusted = true
            let ev = self.wrapEvent(e)
            let d = self.heap.rootDepth
            _ = self.heap.root(ev)
            self.setHiddenSlot(ev, 0, self.heap[p])
            self.heap.release(p)
            self.messageOrigin = self.url?.origin ?? "null"
            _ = try? self.dispatch(e, to: .window)
            self.heap.popRoots(to: d)
            self.loop.performMicrotaskCheckpoint()
        }
    }

    // MARK: Viewport and scrolling

    func Window_innerWidth(_ w: JSDOMBindings) -> Int { host.viewport().0 }
    func Window_innerHeight(_ w: JSDOMBindings) -> Int { host.viewport().1 }
    func Window_outerWidth(_ w: JSDOMBindings) -> Int { host.viewport().0 }
    func Window_outerHeight(_ w: JSDOMBindings) -> Int { host.viewport().1 }
    func Window_scrollX(_ w: JSDOMBindings) -> Double { host.scrollPosition().0 }
    func Window_scrollY(_ w: JSDOMBindings) -> Double { host.scrollPosition().1 }
    func Window_screenX(_ w: JSDOMBindings) -> Int { 0 }
    func Window_screenY(_ w: JSDOMBindings) -> Int { 0 }
    func Window_devicePixelRatio(_ w: JSDOMBindings) -> Double { host.devicePixelRatio }

    func Window_scroll(_ w: JSDOMBindings, _ a: JSValue, _ b: JSValue) {
        let (x, y) = scrollArgs(a, b)
        let (sx, sy) = host.scrollPosition()
        host.scrollTo(max(0, (x ?? sx).isNaN ? 0 : (x ?? sx)), max(0, (y ?? sy).isNaN ? 0 : (y ?? sy)))
    }
    func Window_scrollBy(_ w: JSDOMBindings, _ a: JSValue, _ b: JSValue) {
        let (x, y) = scrollArgs(a, b)
        let (sx, sy) = host.scrollPosition()
        host.scrollTo(max(0, sx + (x ?? 0)), max(0, sy + (y ?? 0)))
    }

    func Window_getSelection(_ w: JSDOMBindings) -> JSValue { selectionObject() }

    // MARK: matchMedia

    func mediaContext() -> CSSContext {
        var c = CSSContext()
        let (w, h) = host.viewport()
        c.viewportWidth = Double(max(1, w))
        c.viewportHeight = Double(max(1, h))
        c.darkColorScheme = host.darkColorScheme
        return c
    }

    func Window_matchMedia(_ w: JSDOMBindings, _ q: String) throws(JSThrow) -> JSValue {
        let o = JSDOMEventTargetObject(.MediaQueryList)
        o.media = q
        o.mediaList = cssParseMediaQueryList(q)
        o.matches = o.mediaList.matches(mediaContext())
        mediaLists.append(o)
        if mediaLists.count > 10_000 { mediaLists.removeFirst() }
        return classes.EventTargetObject.wrap(o)
    }

    func MediaQueryList_media(_ o: JSDOMEventTargetObject) -> String { o.media }
    func MediaQueryList_matches(_ o: JSDOMEventTargetObject) -> Bool { o.matches }
    func MediaQueryList_addListener(_ o: JSDOMEventTargetObject, _ cb: JSValue) throws(JSThrow) {
        try EventTarget_addEventListener(.object(o), "change", cb, .undefined)
    }
    func MediaQueryList_removeListener(_ o: JSDOMEventTargetObject, _ cb: JSValue) throws(JSThrow) {
        try EventTarget_removeEventListener(.object(o), "change", cb, .undefined)
    }

    /// Re-evaluate every MediaQueryList (after a viewport change) and fire
    /// `change` on those that flipped.
    func evaluateMediaQueries() {
        let ctx = mediaContext()
        for o in mediaLists {
            let m = o.mediaList.matches(ctx)
            if m == o.matches { continue }
            o.matches = m
            let e = JSDOMEvent(.MediaQueryListEvent, type: "change", time: now())
            e.isTrusted = true
            e.media = o.media
            e.matches = m
            _ = try? dispatch(e, to: .object(o))
        }
    }

    // MARK: Animation frames and idle callbacks

    func Window_requestAnimationFrame(_ w: JSDOMBindings, _ cb: JSValue) throws(JSThrow) -> Int {
        if rafCallbacks.count >= 100_000 { throw realm.throwRangeError("too many animation frame callbacks") }
        let id = nextRAF
        nextRAF += 1
        rafCallbacks.append((id: id, fn: cb))
        host.requestAnimationFrame()
        return id
    }

    func Window_cancelAnimationFrame(_ w: JSDOMBindings, _ id: Int) {
        rafCallbacks.removeAll { $0.id == id }
    }

    /// Run the callbacks queued before this frame (HTML "run the animation
    /// frame callbacks"), each as its own callback with a checkpoint.
    func runAnimationFrames(_ t: Double) {
        let batch = rafCallbacks
        rafCallbacks = []
        if batch.isEmpty { return }
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        for r in batch { _ = heap.root(r.fn) }
        for r in batch {
            if realm.isTerminating { break }
            _ = try? runScriptCallback(r.fn, this: realm.global, args: [.number(t)])
        }
    }

    func Window_requestIdleCallback(_ w: JSDOMBindings, _ cb: JSValue, _ options: JSValue) throws(JSThrow) -> Int {
        let id = nextRAF
        nextRAF += 1
        idleCallbacks.append((id: id, fn: cb))
        loop.queueTask { [unowned(unsafe) self] in
            guard let i = self.idleCallbacks.firstIndex(where: { $0.id == id }) else { return }
            let f = self.idleCallbacks[i].fn
            self.idleCallbacks.remove(at: i)
            let d = self.heap.rootDepth
            _ = self.heap.root(f)
            let deadline = self.newObject()
            _ = self.heap.root(deadline)
            self.realm.defineMethod(deadline, "timeRemaining", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
                .number(10)
            }
            self.setProp(deadline, "didTimeout", .false)
            _ = try? self.runScriptCallback(f, this: self.realm.global, args: [deadline])
            self.heap.popRoots(to: d)
        }
        return id
    }

    func Window_cancelIdleCallback(_ w: JSDOMBindings, _ id: Int) { idleCallbacks.removeAll { $0.id == id } }

    // MARK: Base64, errors, structuredClone

    func Window_btoa(_ w: JSDOMBindings, _ s: String) throws(JSThrow) -> String {
        var bytes: [UInt8] = []
        for u in s.unicodeScalars {
            if u.value > 0xff { throw throwDOM("InvalidCharacterError", "The string to be encoded contains characters outside of the Latin1 range.") }
            bytes.append(UInt8(u.value))
        }
        let t = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
        var out: [UInt8] = []
        var i = 0
        while i < bytes.count {
            let b0 = Int(bytes[i]), b1 = i + 1 < bytes.count ? Int(bytes[i + 1]) : 0, b2 = i + 2 < bytes.count ? Int(bytes[i + 2]) : 0
            out.append(t[b0 >> 2])
            out.append(t[((b0 & 3) << 4) | (b1 >> 4)])
            out.append(i + 1 < bytes.count ? t[((b1 & 15) << 2) | (b2 >> 6)] : 0x3d)
            out.append(i + 2 < bytes.count ? t[b2 & 63] : 0x3d)
            i += 3
        }
        return String(decoding: out, as: UTF8.self)
    }

    func Window_atob(_ w: JSDOMBindings, _ s: String) throws(JSThrow) -> String {
        var vals: [Int] = []
        for b in s.utf8 {
            if htmlIsSpaceByte(b) { continue }
            switch b {
            case 0x41...0x5a: vals.append(Int(b - 0x41))
            case 0x61...0x7a: vals.append(Int(b - 0x61) + 26)
            case 0x30...0x39: vals.append(Int(b - 0x30) + 52)
            case 0x2b: vals.append(62)
            case 0x2f: vals.append(63)
            case 0x3d: vals.append(-1)
            default: throw throwDOM("InvalidCharacterError", "The string to be decoded is not correctly encoded.")
            }
        }
        // Padding only at the end, total length a multiple of 4 (or no padding).
        if let firstPad = vals.firstIndex(of: -1) {
            if vals.count % 4 != 0 || vals[firstPad...].contains(where: { $0 != -1 }) || vals.count - firstPad > 2 {
                throw throwDOM("InvalidCharacterError", "The string to be decoded is not correctly encoded.")
            }
            vals = Array(vals[..<firstPad])
        }
        if vals.count % 4 == 1 { throw throwDOM("InvalidCharacterError", "The string to be decoded is not correctly encoded.") }
        var out = ""
        var buf = 0, bits = 0
        for v in vals {
            buf = ((buf << 6) | v) & 0xFFFFFF
            bits += 6
            if bits >= 8 {
                bits -= 8
                out.unicodeScalars.append(Unicode.Scalar(UInt8((buf >> bits) & 0xff)))
            }
        }
        return out
    }

    func Window_reportError(_ w: JSDOMBindings, _ e: JSValue) {
        let msg = realm.safeToString(e)
        reportError(message: "Uncaught " + msg, value: e)
        host.reportError("Uncaught " + msg, "")
    }

    func Window_structuredClone(_ w: JSDOMBindings, _ v: JSValue, _ options: JSValue) throws(JSThrow) -> JSValue {
        var memo: [(JSValue, JSValue)] = []
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        return try cloneValue(v, &memo, depth: 0)
    }

    func cloneValue(_ v: JSValue, _ memo: inout [(JSValue, JSValue)], depth: Int) throws(JSThrow) -> JSValue {
        if !v.isObject {
            if v.isSymbol { throw throwDOM("DataCloneError", "Symbols can not be cloned.") }
            return v
        }
        if depth > 256 { throw throwDOM("DataCloneError", "The object is too deeply nested.") }
        for (a, b) in memo where a == v { return b }
        if heap.isCallable(v) || heap.kind(v) == .host { throw throwDOM("DataCloneError", "The object can not be cloned.") }
        let isArr = try realm.isArray(v)
        let out = isArr ? array([]) : newObject()
        _ = heap.root(out)
        memo.append((v, out))
        if heap.kind(v) == .date {
            let c = try realm.construct(realm.intrinsic(.dateConstructor), args: [v])
            _ = heap.root(c)
            return c
        }
        for k in try realm.objOwnKeys(v) where !k.isSymbol {
            guard let p = try realm.objGetOwnProperty(v, k), p.enumerable else { continue }
            let x = try realm.objGet(v, k, receiver: v)
            _ = heap.root(x)
            let c = try cloneValue(x, &memo, depth: depth + 1)
            _ = heap.root(c)
            _ = heap.createDataProperty(out, k, c)
        }
        return out
    }

    // MARK: Location

    func Location_href(_ l: JSDOMLocation) throws(JSThrow) -> String { url?.href ?? "about:blank" }
    func Location_set_href(_ l: JSDOMLocation, _ v: String) throws(JSThrow) { try navigate(v, replace: false) }
    func Location_origin(_ l: JSDOMLocation) -> String { url?.origin ?? "null" }
    func Location_protocol(_ l: JSDOMLocation) throws(JSThrow) -> String { url?.protocolString ?? "about:" }
    func Location_host(_ l: JSDOMLocation) throws(JSThrow) -> String { url?.hostWithPort ?? "" }
    func Location_hostname(_ l: JSDOMLocation) throws(JSThrow) -> String { url?.hostname ?? "" }
    func Location_port(_ l: JSDOMLocation) throws(JSThrow) -> String { url?.portString ?? "" }
    func Location_pathname(_ l: JSDOMLocation) throws(JSThrow) -> String { url?.pathname ?? "blank" }
    func Location_search(_ l: JSDOMLocation) throws(JSThrow) -> String { url?.search ?? "" }
    func Location_hash(_ l: JSDOMLocation) throws(JSThrow) -> String { url?.hash ?? "" }

    func locationWith(_ f: (inout URLRecord) -> Void) throws(JSThrow) {
        guard var u = url else { return }
        f(&u)
        try navigate(u.href, replace: false)
    }
    func Location_set_protocol(_ l: JSDOMLocation, _ v: String) throws(JSThrow) {
        try locationWith { u in
            var s = Array(v.utf8)
            if let i = s.firstIndex(of: 0x3a) { s = Array(s[..<i]) }
            if !s.isEmpty { u.scheme = s }
        }
    }
    func Location_set_host(_ l: JSDOMLocation, _ v: String) throws(JSThrow) {
        guard let u = url else { return }
        try navigate(u.protocolString + "//" + v + u.pathname + u.search + u.hash, replace: false)
    }
    func Location_set_hostname(_ l: JSDOMLocation, _ v: String) throws(JSThrow) { try Location_set_host(l, v) }
    func Location_set_port(_ l: JSDOMLocation, _ v: String) throws(JSThrow) {
        try locationWith { u in u.port = v.isEmpty ? nil : UInt16(min(max(jsdomParseInteger(v) ?? 0, 0), 65535)) }
    }
    func Location_set_pathname(_ l: JSDOMLocation, _ v: String) throws(JSThrow) {
        guard let u = url else { return }
        try navigate(u.protocolString + "//" + u.hostWithPort + (v.hasPrefix("/") ? v : "/" + v) + u.search + u.hash, replace: false)
    }
    func Location_set_search(_ l: JSDOMLocation, _ v: String) throws(JSThrow) {
        try locationWith { u in
            var s = Array(v.utf8)
            if s.first == 0x3f { s.removeFirst() }
            u.query = s.isEmpty ? nil : s
        }
    }
    func Location_set_hash(_ l: JSDOMLocation, _ v: String) throws(JSThrow) {
        try locationWith { u in
            var s = Array(v.utf8)
            if s.first == 0x23 { s.removeFirst() }
            u.fragment = s
        }
    }
    func Location_assign(_ l: JSDOMLocation, _ v: String) throws(JSThrow) { try navigate(v, replace: false) }
    func Location_replace(_ l: JSDOMLocation, _ v: String) throws(JSThrow) { try navigate(v, replace: true) }
    func Location_reload(_ l: JSDOMLocation) { host.reload() }
    func Location_ancestorOrigins(_ l: JSDOMLocation) -> JSValue { array([]) }

    /// location assignment: a fragment-only change is handled here (URL,
    /// history entry via host.historyPush, hashchange); anything else is
    /// the browser's navigation.
    func navigate(_ target: String, replace: Bool) throws(JSThrow) {
        guard let resolved = resolveURL(target), let nu = URLRecord.parseOrNil(resolved) else {
            throw throwDOM("SyntaxError", "'" + target + "' is not a valid URL.")
        }
        if let cur = url, cur.serializedBytes(excludeFragment: true) == nu.serializedBytes(excludeFragment: true), nu.fragment != nil {
            let old = cur.href
            url = nu
            let id = nextStateID
            nextStateID += 1
            currentStateID = id
            host.historyPush(id, nu.href, replace)
            if old != nu.href { queueHashChange(old, nu.href) }
            return
        }
        host.navigate(nu.href, replace)
    }

    func queueHashChange(_ old: String, _ new: String) {
        loop.queueTask { [unowned(unsafe) self] in
            let e = JSDOMEvent(.HashChangeEvent, type: "hashchange", time: self.now())
            e.bubbles = false
            e.isTrusted = true
            e.oldURL = old
            e.newURL = new
            _ = try? self.dispatch(e, to: .window)
        }
    }

    // MARK: History

    func History_length(_ h: JSDOMHistory) -> Int { max(1, host.historyLength()) }
    func History_scrollRestoration(_ h: JSDOMHistory) -> String { scrollRestorationManual ? "manual" : "auto" }
    func History_set_scrollRestoration(_ h: JSDOMHistory, _ v: String) {
        if v == "manual" { scrollRestorationManual = true } else if v == "auto" { scrollRestorationManual = false }
    }
    func History_state(_ h: JSDOMHistory) -> JSValue { historyStates[currentStateID] ?? .null }
    func History_go(_ h: JSDOMHistory, _ d: Int) { if d == 0 { host.reload() } else { host.historyGo(d) } }
    func History_back(_ h: JSDOMHistory) { host.historyGo(-1) }
    func History_forward(_ h: JSDOMHistory) { host.historyGo(1) }

    func History_pushState(_ h: JSDOMHistory, _ data: JSValue, _ unused: String, _ u: String?) throws(JSThrow) {
        try changeState(data, u, replace: false)
    }
    func History_replaceState(_ h: JSDOMHistory, _ data: JSValue, _ unused: String, _ u: String?) throws(JSThrow) {
        try changeState(data, u, replace: true)
    }

    func changeState(_ data: JSValue, _ u: String?, replace: Bool) throws(JSThrow) {
        var newURL = url
        if let s = u {
            guard let r = resolveURL(s), let nu = URLRecord.parseOrNil(r) else {
                throw throwDOM("SecurityError", "The URL '" + s + "' is not valid.")
            }
            if let cur = url, !cur.sameOrigin(as: nu) || cur.scheme != nu.scheme {
                throw throwDOM("SecurityError", "A history state object with URL '" + nu.href + "' cannot be created in a document with origin '" + cur.origin + "'.")
            }
            newURL = nu
        }
        let cloned = try Window_structuredClone(self, data, .undefined)
        let id: Int
        if replace {
            id = currentStateID == 0 ? nextStateID : currentStateID
            if currentStateID == 0 { nextStateID += 1 }
        } else {
            id = nextStateID
            nextStateID += 1
        }
        historyStates[id] = cloned
        if historyStates.count > 1000, let oldest = historyStates.keys.min(), oldest != id { historyStates[oldest] = nil }
        currentStateID = id
        url = newURL
        host.historyPush(id, newURL?.href ?? "about:blank", replace)
    }

    /// The browser moved to another entry of this document (back/forward).
    func popState(id: Int, url u: String) {
        let old = url?.href ?? ""
        url = URLRecord.parseOrNil(u) ?? url
        currentStateID = id
        let e = JSDOMEvent(.PopStateEvent, type: "popstate", time: now())
        e.isTrusted = true
        let w = wrapEvent(e)
        let d = heap.rootDepth
        _ = heap.root(w)
        setHiddenSlot(w, 0, historyStates[id] ?? .null)
        _ = try? dispatch(e, to: .window)
        heap.popRoots(to: d)
        if let nu = url, URLRecord.parseOrNil(old).map({ $0.serializedBytes(excludeFragment: true) == nu.serializedBytes(excludeFragment: true) }) == true,
           old != nu.href {
            queueHashChange(old, nu.href)
        }
    }

    // MARK: Navigator, Screen

    func Navigator_userAgent(_ n: JSDOMNavigator) -> String { host.userAgent }
    func Navigator_appCodeName(_ n: JSDOMNavigator) -> String { "Mozilla" }
    func Navigator_appName(_ n: JSDOMNavigator) -> String { "Netscape" }
    func Navigator_appVersion(_ n: JSDOMNavigator) -> String {
        let ua = host.userAgent
        return ua.hasPrefix("Mozilla/") ? String(ua.dropFirst(8)) : ua
    }
    func Navigator_platform(_ n: JSDOMNavigator) -> String { "Wiffer" }
    func Navigator_product(_ n: JSDOMNavigator) -> String { "Gecko" }
    func Navigator_productSub(_ n: JSDOMNavigator) -> String { "20030107" }
    func Navigator_vendor(_ n: JSDOMNavigator) -> String { "" }
    func Navigator_vendorSub(_ n: JSDOMNavigator) -> String { "" }
    func Navigator_language(_ n: JSDOMNavigator) -> String { host.languages.first ?? "en-US" }
    func Navigator_languages(_ n: JSDOMNavigator) -> JSValue {
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        var vals: [JSValue] = []
        for l in host.languages { let s = str(l); _ = heap.root(s); vals.append(s) }
        let a = array(vals)
        _ = heap.root(a)
        _ = heap.preventExtensions(a)
        return a
    }
    func Navigator_onLine(_ n: JSDOMNavigator) -> Bool { host.onLine }
    func Navigator_cookieEnabled(_ n: JSDOMNavigator) -> Bool { true }
    func Navigator_webdriver(_ n: JSDOMNavigator) -> Bool { false }
    func Navigator_pdfViewerEnabled(_ n: JSDOMNavigator) -> Bool { false }
    func Navigator_hardwareConcurrency(_ n: JSDOMNavigator) -> Int { 1 }
    func Navigator_maxTouchPoints(_ n: JSDOMNavigator) -> Int { 0 }
    func Navigator_doNotTrack(_ n: JSDOMNavigator) -> String { "unspecified" }
    func Navigator_javaEnabled(_ n: JSDOMNavigator) -> Bool { false }
    func Navigator_sendBeacon(_ n: JSDOMNavigator, _ u: String, _ data: JSValue) -> Bool { true }
    func Navigator_clipboard(_ n: JSDOMNavigator) -> JSValue { .undefined }
    func Navigator_serviceWorker(_ n: JSDOMNavigator) -> JSValue { .undefined }

    func Screen_width(_ s: JSDOMScreen) -> Int { host.screenSize().0 }
    func Screen_height(_ s: JSDOMScreen) -> Int { host.screenSize().1 }
    func Screen_availWidth(_ s: JSDOMScreen) -> Int { host.screenSize().0 }
    func Screen_availHeight(_ s: JSDOMScreen) -> Int { host.screenSize().1 }
    func Screen_colorDepth(_ s: JSDOMScreen) -> Int { 24 }
    func Screen_pixelDepth(_ s: JSDOMScreen) -> Int { 24 }
    func Screen_orientation(_ s: JSDOMScreen) -> JSValue {
        let o = newObject()
        let d = heap.rootDepth
        _ = heap.root(o)
        let (w, h) = host.screenSize()
        setProp(o, "type", str(w >= h ? "landscape-primary" : "portrait-primary"))
        setProp(o, "angle", .number(0))
        heap.popRoots(to: d)
        return o
    }

    // MARK: Selection (a stub: nothing is ever selected)

    func Selection_anchorNode(_ s: JSDOMSelection) -> JSValue { .null }
    func Selection_anchorOffset(_ s: JSDOMSelection) -> Int { 0 }
    func Selection_focusNode(_ s: JSDOMSelection) -> JSValue { .null }
    func Selection_focusOffset(_ s: JSDOMSelection) -> Int { 0 }
    func Selection_isCollapsed(_ s: JSDOMSelection) -> Bool { true }
    func Selection_rangeCount(_ s: JSDOMSelection) -> Int { 0 }
    func Selection_type(_ s: JSDOMSelection) -> String { "None" }
    func Selection_getRangeAt(_ s: JSDOMSelection, _ i: Int) -> JSValue { .null }
    func Selection_addRange(_ s: JSDOMSelection, _ r: JSValue) {}
    func Selection_removeAllRanges(_ s: JSDOMSelection) {}
    func Selection_collapse(_ s: JSDOMSelection, _ n: JSValue, _ o: Int) {}
    func Selection_selectAllChildren(_ s: JSDOMSelection, _ n: JSValue) {}
    func Selection_toString(_ s: JSDOMSelection) -> String { "" }

    // MARK: Performance

    func Performance_now(_ p: JSDOMPerformance) -> Double { now() }
    func Performance_timeOrigin(_ p: JSDOMPerformance) -> Double { timeOrigin }
    func Performance_mark(_ p: JSDOMPerformance, _ name: String, _ o: JSValue) {
        marks.append((name, now()))
        if marks.count > 10_000 { marks.removeFirst() }
    }
    func Performance_measure(_ p: JSDOMPerformance, _ name: String, _ a: JSValue, _ b: JSValue) {}
    func Performance_clearMarks(_ p: JSDOMPerformance, _ name: String?) {
        if let n = name { marks.removeAll { $0.0 == n } } else { marks = [] }
    }
    func Performance_clearMeasures(_ p: JSDOMPerformance, _ name: String?) {}
    func markEntries(_ filter: (String) -> Bool) -> JSValue {
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        var vals: [JSValue] = []
        for (n, t) in marks where filter(n) {
            let o = newObject()
            _ = heap.root(o)
            setProp(o, "name", str(n))
            setProp(o, "entryType", str("mark"))
            setProp(o, "startTime", .number(t))
            setProp(o, "duration", .number(0))
            vals.append(o)
        }
        return array(vals)
    }
    func Performance_getEntries(_ p: JSDOMPerformance) -> JSValue { markEntries { _ in true } }
    func Performance_getEntriesByType(_ p: JSDOMPerformance, _ t: String) -> JSValue {
        t == "mark" ? markEntries { _ in true } : array([])
    }
    func Performance_getEntriesByName(_ p: JSDOMPerformance, _ n: String, _ t: String?) -> JSValue {
        t == nil || t == "mark" ? markEntries { $0 == n } : array([])
    }
    func Performance_toJSON(_ p: JSDOMPerformance) -> JSValue {
        let o = newObject()
        let d = heap.rootDepth
        _ = heap.root(o)
        setProp(o, "timeOrigin", .number(timeOrigin))
        heap.popRoots(to: d)
        return o
    }

    // MARK: Storage (in memory, per page; JSDOMHost.storage hooks persist it)

    func storageItems(_ s: JSDOMStorage) -> [(String, String)] { s.local ? storageItems : sessionItems }
    func setStorageItems(_ s: JSDOMStorage, _ v: [(String, String)]) {
        if s.local { storageItems = v; host.storageChanged(v) } else { sessionItems = v }
    }

    func Storage_length(_ s: JSDOMStorage) -> Int { storageItems(s).count }
    func Storage_key(_ s: JSDOMStorage, _ i: Int) -> String? {
        let it = storageItems(s)
        return i >= 0 && i < it.count ? it[i].0 : nil
    }
    func Storage_getItem(_ s: JSDOMStorage, _ k: String) -> String? {
        for (a, b) in storageItems(s) where a == k { return b }
        return nil
    }
    func Storage_setItem(_ s: JSDOMStorage, _ k: String, _ v: String) throws(JSThrow) {
        var it = storageItems(s)
        var total = k.utf8.count + v.utf8.count
        for (a, b) in it where a != k { total += a.utf8.count + b.utf8.count }
        if total > 5_000_000 { throw throwDOM("QuotaExceededError", "The quota has been exceeded.") }
        if let i = it.firstIndex(where: { $0.0 == k }) { it[i].1 = v } else { it.append((k, v)) }
        setStorageItems(s, it)
    }
    func Storage_removeItem(_ s: JSDOMStorage, _ k: String) {
        var it = storageItems(s)
        it.removeAll { $0.0 == k }
        setStorageItems(s, it)
    }
    func Storage_clear(_ s: JSDOMStorage) { setStorageItems(s, []) }

    func exotic_Storage() -> JSHostExotic<JSDOMStorage> {
        var e = JSHostExotic<JSDOMStorage>()
        e.namedGet = { [unowned(unsafe) self] (realm: JSRealm, s: JSDOMStorage, name: String) throws(JSThrow) -> JSValue? in
            self.Storage_getItem(s, name).map { self.str($0) }
        }
        e.namedKeys = { [unowned(unsafe) self] s in self.storageItems(s).map { $0.0 } }
        e.namedEnumerable = true
        e.namedSet = { [unowned(unsafe) self] (realm: JSRealm, s: JSDOMStorage, name: String, v: JSValue) throws(JSThrow) -> Bool in
            try self.Storage_setItem(s, name, try self.toStr(v))
            return true
        }
        e.namedDelete = { [unowned(unsafe) self] (realm: JSRealm, s: JSDOMStorage, name: String) throws(JSThrow) -> Bool in
            if self.Storage_getItem(s, name) == nil { return false }
            self.Storage_removeItem(s, name)
            return true
        }
        return e
    }

    // MARK: SVG

    func SVGElement_ownerSVGElement(_ n: HTMLNode) -> JSValue {
        var x = n.parent
        while let p = x, p.kind == .element {
            if p.namespace == .svg && p.name == "svg" { return wrapNode(p) }
            x = p.parent
        }
        return .null
    }
    func SVGElement_viewportElement(_ n: HTMLNode) -> JSValue { SVGElement_ownerSVGElement(n) }
    func SVGGraphicsElement_getBBox(_ n: HTMLNode, _ o: JSValue) -> JSValue {
        guard let r = layoutRect(n) else { return rectValue(0, 0, 0, 0) }
        var x = r.x, y = r.y
        // Relative to the nearest <svg> (approximation: no transforms).
        var p = n.parent
        while let q = p, q.kind == .element {
            if q.namespace == .svg && q.name == "svg", let sr = layoutRect(q) { x -= sr.x; y -= sr.y; break }
            p = q.parent
        }
        return rectValue(x, y, r.w, r.h)
    }
    func SVGGraphicsElement_getCTM(_ n: HTMLNode) -> JSValue { .null }
    func SVGGraphicsElement_getScreenCTM(_ n: HTMLNode) -> JSValue { .null }
    func SVGGeometryElement_getTotalLength(_ n: HTMLNode) -> Double { 0 }
    func SVGSVGElement_viewBox(_ n: HTMLNode) -> JSValue { classes.SVGAnimatedRect.wrap(JSDOMAnimatedRect(n)) }
    func SVGSVGElement_width(_ n: HTMLNode) -> JSValue { lengthObject(n, "width") }
    func SVGSVGElement_height(_ n: HTMLNode) -> JSValue { lengthObject(n, "height") }
    func lengthObject(_ n: HTMLNode, _ attr: String) -> JSValue {
        let o = newObject()
        let d = heap.rootDepth
        _ = heap.root(o)
        let base = newObject()
        _ = heap.root(base)
        let v = n.attribute(attr).flatMap { jsdomParseFloat(String($0.utf8.prefix { ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2e || $0 == 0x2d }.map { Character(Unicode.Scalar($0)) })) } ?? 0
        setProp(base, "value", .number(v))
        setProp(o, "baseVal", base)
        setProp(o, "animVal", base)
        heap.popRoots(to: d)
        return o
    }
    func SVGSVGElement_createSVGPoint(_ n: HTMLNode) -> JSValue {
        let o = newObject()
        let d = heap.rootDepth
        _ = heap.root(o)
        setProp(o, "x", .number(0))
        setProp(o, "y", .number(0))
        heap.popRoots(to: d)
        return o
    }
    func SVGAnimatedRect_baseVal(_ r: JSDOMAnimatedRect) -> JSValue {
        var vals: [Double] = []
        if let vb = r.node.attribute("viewBox") {
            var cur: [UInt8] = []
            for b in vb.utf8 {
                if htmlIsSpaceByte(b) || b == 0x2c {
                    if !cur.isEmpty { vals.append(jsdomParseFloat(String(decoding: cur, as: UTF8.self)) ?? 0); cur = [] }
                } else { cur.append(b) }
            }
            if !cur.isEmpty { vals.append(jsdomParseFloat(String(decoding: cur, as: UTF8.self)) ?? 0) }
        }
        if vals.count != 4 { return rectValue(0, 0, 0, 0) }
        return rectValue(vals[0], vals[1], vals[2], vals[3])
    }
    func SVGAnimatedRect_animVal(_ r: JSDOMAnimatedRect) -> JSValue { SVGAnimatedRect_baseVal(r) }

    // MARK: Extras

    /// Globals that are not generated: aliases and constructors' legacy names.
    func installWindowExtras() {
        let g = realm.global
        // webkitURL-style legacy aliases scripts probe for.
        if ctors[JSDOMInterface.CSSStyleDeclaration.rawValue].isObject {
            realm.defineGlobal("CSS2Properties", ctors[JSDOMInterface.CSSStyleDeclaration.rawValue])
        }
        _ = g
        installNamedPropertiesObject()
        // NodeFilter's constants (TreeWalker / NodeIterator are not here).
        let nf = newObject()
        keep.append(nf)
        let consts: [(String, Int)] = [("FILTER_ACCEPT", 1), ("FILTER_REJECT", 2), ("FILTER_SKIP", 3),
            ("SHOW_ALL", 0xFFFF_FFFF), ("SHOW_ELEMENT", 0x1), ("SHOW_ATTRIBUTE", 0x2), ("SHOW_TEXT", 0x4),
            ("SHOW_CDATA_SECTION", 0x8), ("SHOW_ENTITY_REFERENCE", 0x10), ("SHOW_ENTITY", 0x20),
            ("SHOW_PROCESSING_INSTRUCTION", 0x40), ("SHOW_COMMENT", 0x80), ("SHOW_DOCUMENT", 0x100),
            ("SHOW_DOCUMENT_TYPE", 0x200), ("SHOW_DOCUMENT_FRAGMENT", 0x400), ("SHOW_NOTATION", 0x800)]
        for (k, v) in consts { realm.defineValue(nf, k, .number(Double(v)), [.enumerable]) }
        realm.defineGlobal("NodeFilter", nf)
    }

    /// The window's named properties object (HTML "Named access on the
    /// Window object"): between Window.prototype and EventTarget.prototype,
    /// it exposes elements by id (and embed / form / img / object by name),
    /// so `window.myId` and a bare `myId` work. The first element in tree
    /// order wins (no HTMLCollection for duplicates). The name index is
    /// rebuilt when the DOM changed.
    func installNamedPropertiesObject() {
        let et = protos[JSDOMInterface.EventTarget.rawValue]
        let o = heap.newObject(proto: et)
        if !o.isObject { return }
        keep.append(o)
        var h = JSExoticHandler()
        h.getOwnProperty = { [unowned(unsafe) self] (realm: JSRealm, o: JSValue, k: JSPropertyKey) throws(JSThrow) -> JSProperty? in
            guard k.isString else { return nil }
            if realm.heap.getOwnProperty(o, k) != nil { return nil }
            switch realm.heap.getProperty(realm.heap.getPrototypeOf(o), k) {
            case .value(let v): if !v.isUndefined { return nil }
            case .getter, .exotic: return nil
            }
            let name = realm.heap.swiftString(realm.heap.keyValue(k))
            guard let el = self.windowNamedElement(name) else { return nil }
            // Writable: `window.x = v` / `var`-less assignment shadow it.
            return .data(self.wrapNode(el), [.writable, .configurable])
        }
        let id = realm.registerExoticHandler(h)
        realm.makeExotic(o, handler: id)
        _ = heap.setPrototypeOf(protos[JSDOMInterface.Window.rawValue], o)
    }

    func windowNamedElement(_ name: String) -> HTMLNode? {
        if name.isEmpty { return nil }
        if namedIndexVersion != mutationVersion || namedIndex == nil {
            var idx: [String: HTMLNode] = [:]
            var count = 0
            document.walk { n in
                if n.kind != .element { return true }
                count += 1
                if count > 1_000_000 { return false }
                if let i = n.attribute("id"), !i.isEmpty, idx[i] == nil { idx[i] = n }
                if n.namespace == .html, n.name == "embed" || n.name == "form" || n.name == "img" || n.name == "object",
                   let nm = n.attribute("name"), !nm.isEmpty, idx[nm] == nil {
                    idx[nm] = n
                }
                return true
            }
            namedIndex = idx
            namedIndexVersion = mutationVersion
        }
        return namedIndex?[name]
    }
}
