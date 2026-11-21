// Scripts in the browser (ROADMAP Phase 9H): one BrowserScripts per scripted
// document, owned by its BrowserPage and driven by the loader.
//
//   * Loading. Every <script> the parser made is collected in document order:
//     classic (no type, or a JavaScript MIME type), module (type=module),
//     anything else ignored; `nomodule` classic scripts are skipped (modules
//     are supported). External sources are fetched through the loader at
//     once, beside the stylesheets. Classic scripts run after the parse, in
//     document order, as if `defer` (the design decision: lib/html parses
//     the whole document in one call), and only once the stylesheets that
//     were in the document have arrived (or the CSS timeout passed), so
//     layout queries see styled boxes. `async` scripts (and async modules)
//     run as they arrive. Modules: the import graph is pre-fetched through
//     the loader (realm.moduleRequests), then evaluated by the realm's
//     synchronous module loader from the fetched sources. After the ordered
//     list: DOMContentLoaded; once nothing is pending (subresources and
//     async scripts): load.
//   * Script-inserted scripts (createElement + appendChild, document.write)
//     are found through a lib/html mutation observer; inline ones run as the
//     next task (not synchronously inside the insertion: the DOM operation is
//     still on the Swift stack), external ones when they arrive. innerHTML
//     scripts never run (lib/html's scriptAlreadyStarted flag).
//   * Charset: BOM, then the response's Content-Type charset, then the
//     element's charset attribute, then the document's encoding.
//   * Time budget: every task gets `budgetMs` (5 s); past it the interrupt
//     handler asks the app (`hooks.hung`), which shows "This page's script
//     is not responding" (Stop script / Wait). Stop terminates the script and
//     switches scripts off for the page; Wait extends the budget.
//   * Errors are counted and logged, never fatal.
//
// Debug lines (through the loader's log): `script <url> N ms`, `console
// <level> <text>`, `js error <url>:<line>: <message>`, `event
// DOMContentLoaded|load N ms`, `js budget exceeded <url>`.

enum BrowserHungDecision { case keepRunning, stop, wait }

/// Lets the page's host closures reach their BrowserScripts once it exists.
final class BrowserScriptSink {
    unowned(unsafe) var scripts: BrowserScripts? = nil
    init() {}
}

/// What the app supplies for scripted pages (UI, navigation, cookies).
/// Every member has a harmless default (host tests).
struct BrowserScriptHooks {
    /// console output, already formatted.
    var console: (JSConsoleLevel, String) -> Void = { _, _ in }
    /// location = ..., link activation, form submission, reload, history.go.
    /// Called while a script runs: the app must defer the navigation until
    /// the script returns.
    var navigate: (_ url: String, _ replace: Bool) -> Void = { _, _ in }
    var followHyperlink: (_ link: HTMLNode, _ url: String) -> Void = { _, _ in }
    var submitForm: (_ form: HTMLNode, _ submitter: HTMLNode?) -> Void = { _, _ in }
    var reload: () -> Void = {}
    var historyPush: (_ id: Int, _ url: String, _ replace: Bool) -> Void = { _, _, _ in }
    var historyGo: (_ delta: Int) -> Void = { _ in }
    var historyLength: () -> Int = { 1 }
    var getCookie: (URLRecord) -> String = { _ in "" }
    var setCookie: (URLRecord, String) -> Void = { _, _ in }
    var scrollPosition: () -> (Double, Double) = { (0, 0) }
    var scrollTo: (Double, Double) -> Void = { _, _ in }
    var focusChanged: (HTMLNode?) -> Void = { _ in }
    var controlChanged: (HTMLNode) -> Void = { _ in }
    var alert: (String) -> Void = { _ in }
    var confirm: (String) -> Bool = { _ in false }
    var prompt: (String, String) -> String? = { _, _ in nil }
    /// The budget ran out `elapsed` ms into a task: show the bar and say
    /// what the user chose (called again every interrupt check until then).
    var hung: (_ elapsed: Int) -> BrowserHungDecision = { _ in .stop }
    /// Wall clock ms since 1970 (Date.now()).
    var wallClock: () -> Double = { 0 }
    init() {}
}

final class BrowserScriptItem {
    unowned(unsafe) let node: HTMLNode
    let isModule: Bool
    let isAsync: Bool
    /// The src URL (nil: inline).
    let src: URLRecord?
    /// Source bytes (UTF-8) once known.
    var source: [UInt8]? = nil
    var failed = false
    var done = false
    /// Script-inserted (not part of the parser's ordered list).
    let dynamic: Bool
    /// Modules: the root's name (url) and its graph's fetches still out.
    var moduleName = ""
    var modulesPending = 0
    /// Module URLs already counted for this item's graph.
    var visited: Set<String> = []
    init(node: HTMLNode, isModule: Bool, isAsync: Bool, src: URLRecord?, dynamic: Bool) {
        self.node = node; self.isModule = isModule; self.isAsync = isAsync; self.src = src; self.dynamic = dynamic
    }
    var ready: Bool { failed || (source != nil && modulesPending == 0) }
}

/// Classic script MIME types (HTML "JavaScript MIME type essence match").
func browserIsJavaScriptType(_ t: String) -> Bool {
    switch t {
    case "application/ecmascript", "application/javascript", "application/x-ecmascript", "application/x-javascript",
         "text/ecmascript", "text/javascript", "text/javascript1.0", "text/javascript1.1", "text/javascript1.2",
         "text/javascript1.3", "text/javascript1.4", "text/javascript1.5", "text/jscript", "text/livescript",
         "text/x-ecmascript", "text/x-javascript":
        return true
    default:
        return false
    }
}

private func browserLowerTrim(_ s: String) -> String {
    var b = Array(s.utf8)
    while let l = b.last, l == 0x20 || l == 0x09 || l == 0x0a || l == 0x0d || l == 0x0c { b.removeLast() }
    var i = 0
    while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0a || b[i] == 0x0d || b[i] == 0x0c { i += 1 }
    return String(decoding: b[i...].map { $0 >= 0x41 && $0 <= 0x5a ? $0 + 32 : $0 }, as: UTF8.self)
}

/// "classic", "module", or nil (not a script to run).
func browserScriptKind(_ n: HTMLNode) -> String? {
    if let t = n.attribute("type") {
        let l = browserLowerTrim(t)
        if l.isEmpty { return "classic" }
        if l == "module" { return "module" }
        var essence = ""
        for c in l.unicodeScalars { if c == ";" { break }; if c != " " { essence.unicodeScalars.append(c) } }
        return browserIsJavaScriptType(essence) ? "classic" : nil
    }
    if let lang = n.attribute("language"), !lang.isEmpty {
        return browserIsJavaScriptType("text/" + browserLowerTrim(lang)) ? "classic" : nil
    }
    return "classic"
}

/// "<url>:<line>" for an error's first stack frame, else the script name.
func browserErrorLocation(_ stack: String, fallback: String) -> String {
    func digits(_ b: ArraySlice<UInt8>) -> Bool { !b.isEmpty && b.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } }
    let prefix = Array("    at ".utf8)
    for line in stack.split(separator: "\n") {
        var l = Array(line.utf8)
        guard l.count > prefix.count, Array(l[0..<prefix.count]) == prefix else { continue }
        l = Array(l[prefix.count...])
        if l.last == 0x29, let open = l.lastIndex(of: 0x28) { l = Array(l[(open + 1)..<(l.count - 1)]) }
        // name:line:col -> name:line
        if let c = l.lastIndex(of: 0x3a) {
            let head = l[..<c]
            if let c2 = head.lastIndex(of: 0x3a), digits(head[(c2 + 1)...]), digits(l[(c + 1)...]) {
                return String(decoding: head, as: UTF8.self)
            }
            if digits(l[(c + 1)...]) { return String(decoding: l, as: UTF8.self) }
        }
        return String(decoding: l, as: UTF8.self)
    }
    return fallback + ":0"
}

final class BrowserScripts {
    let page: JSDOMPage
    let web: JSWeb
    unowned(unsafe) let loader: BrowserLoader
    let url: URLRecord
    let documentEncoding: TextEncoding
    var items: [BrowserScriptItem] = []
    /// Index of the next item in the ordered (parser, non-async) list.
    var nextOrdered = 0
    /// Module sources by URL (nil while being fetched, empty+failed set on error).
    var moduleSources: [String: [UInt8]] = [:]
    var moduleFailed: Set<String> = []
    /// Modules being fetched, and the items waiting for each.
    var moduleWaiters: [String: [BrowserScriptItem]] = [:]
    var inlineModules = 0
    var observerID = 0
    var errors = 0
    var scriptsRun = 0
    var scriptMs = 0
    var domContentLoaded = false
    var loadFired = false
    /// Off after the user stopped a runaway script (or the page went away).
    var stopped = false
    var budgetMs = 5000
    var deadline = Int.max
    var taskStart = 0
    var hungLogged = false
    var maxScripts = 2000
    var maxModules = 500
    /// Scripts may grow the document to this many nodes (9J: a million
    /// script-made nodes, each with a JS wrapper and later layout boxes,
    /// would exhaust a 1 GiB machine long before the JS heap cap). Past it
    /// the running script is terminated and scripts are stopped for the page.
    var maxDocumentNodes = 100_000
    /// ms since navigation start, for the event lines.
    let started: Int

    init(document: HTMLNode, url: URLRecord, base: URLRecord, loader: BrowserLoader, encoding: TextEncoding, started: Int) {
        self.loader = loader
        self.url = url
        self.started = started
        documentEncoding = encoding
        let hooks = loader.scriptHooks
        var host = JSDOMHost()
        let clock = loader.clock
        host.now = { Double(clock()) }
        host.wallClock = hooks.wallClock
        host.navigate = hooks.navigate
        host.reload = hooks.reload
        host.historyPush = hooks.historyPush
        host.historyGo = hooks.historyGo
        host.historyLength = hooks.historyLength
        host.followHyperlink = { link, u, _ in hooks.followHyperlink(link, u) }
        host.submitForm = hooks.submitForm
        host.openWindow = { u, _ in hooks.navigate(u, false) }
        let docURL = url
        host.getCookie = { hooks.getCookie(docURL) }
        host.setCookie = { s in hooks.setCookie(docURL, s) }
        host.scrollPosition = hooks.scrollPosition
        host.scrollTo = hooks.scrollTo
        host.focusChanged = hooks.focusChanged
        host.controlChanged = hooks.controlChanged
        host.alert = hooks.alert
        host.confirm = hooks.confirm
        host.prompt = hooks.prompt
        host.viewport = { [unowned(unsafe) loader] in (loader.viewportWidth, loader.viewportHeight) }
        host.imageSize = { [unowned(unsafe) loader] u in loader.page?.images.sizeByURL(u) }
        host.imagePending = { [unowned(unsafe) loader] u in loader.imagePending(u) }
        host.requestAnimationFrame = { [unowned(unsafe) loader] in loader.scheduleFrame() }
        host.layout = { [unowned(unsafe) loader] in loader.page?.engine }
        // JSDOMPage copies the host for some hooks (console, termination):
        // route those that need self through a box filled in below.
        let sink = BrowserScriptSink()
        host.console = { level, text in sink.scripts?.console(level, text) }
        host.reportError = { msg, stack in sink.scripts?.reportError(msg, stack) }
        host.reportTermination = { why in sink.scripts?.reportTermination(why) }
        host.beginTask = { sink.scripts?.beginTask() }
        var limits = JSLimits()
        limits.heapBytes = loader.scriptHeapBytes
        page = JSDOMPage(document: document, url: url.href, host: host, limits: limits)
        let net = JSWebNetwork()
        web = JSWeb(page: page, network: net)
        unowned(unsafe) let me = self
        sink.scripts = self
        page.loop.beginTask = { me.beginTask() }
        page.runtime.interruptHandler = { _ in me.interrupt() }
        net.start = { req, done in loader.startFetch(req, done) }
        net.cancel = { id in loader.cancelFetch(id) }
        // Storage per origin, in memory for the browser's lifetime.
        let origin = url.origin
        if let items = loader.localStorage[origin] { page.bindings.storageItems = items }
        if let items = loader.sessionStorage[origin] { page.bindings.sessionItems = items }
        page.bindings.host.storageChanged = { items in loader.localStorage[origin] = items }
        observerID = document.addMutationObserver { m in me.mutated(m) }
        _ = base
    }

    deinit { tearDown() }

    var tornDown = false

    /// The page goes away (navigation): stop everything.
    func tearDown() {
        if tornDown { return }
        tornDown = true
        loader.sessionStorage[url.origin] = page.bindings.sessionItems
        stopped = true
        page.document.removeMutationObserver(observerID)
        observerID = -1
        web.tearDown()
        page.runtime.interruptHandler = nil
        page.tearDown()
    }

    func log(_ s: String) { loader.log?(s) }

    // MARK: Hooks from the page

    func console(_ level: JSConsoleLevel, _ text: String) {
        loader.scriptHooks.console(level, text)
        let name: String
        switch level {
        case .log: name = "log"
        case .info: name = "info"
        case .debug: name = "debug"
        case .warn: name = "warn"
        case .error: name = "error"
        }
        var t = ""
        var n = 0
        for u in text.unicodeScalars {
            if n >= 400 { t += "..."; break }
            if u == "\n" { t += "\\n" } else if u == "\r" { continue } else { t.unicodeScalars.append(u) }
            n += 1
        }
        log("console " + name + " " + t)
    }

    var currentName = ""

    func reportError(_ message: String, _ stack: String) {
        errors += 1
        loader.noteScriptError()
        let loc = browserErrorLocation(stack, fallback: currentName.isEmpty ? url.href : currentName)
        log("js error " + loc + ": " + message)
    }

    func reportTermination(_ why: JSTerminationReason) {
        errors += 1
        loader.noteScriptError()
        switch why {
        case .heapLimit: log("js error " + (currentName.isEmpty ? url.href : currentName) + ":0: out of memory (heap limit)")
        case .interrupted: log("js stopped " + url.href)
        case .regexSteps: log("js error " + (currentName.isEmpty ? url.href : currentName) + ":0: terminated (regular expression step limit)")
        default: log("js error " + (currentName.isEmpty ? url.href : currentName) + ":0: terminated")
        }
    }

    func beginTask() {
        let now = loader.clock()
        taskStart = now
        deadline = now + budgetMs
        hungLogged = false
    }

    /// The VM's interrupt check: true terminates the running script.
    func interrupt() -> Bool {
        if stopped { return true }
        if page.document.arenaSlotCount > maxDocumentNodes {
            log("js error " + (currentName.isEmpty ? url.href : currentName) + ":0: terminated (more than "
                + String(maxDocumentNodes) + " document nodes)")
            stop()
            return true
        }
        let now = loader.clock()
        if now < deadline { return false }
        if !hungLogged {
            hungLogged = true
            log("js budget exceeded " + url.href)
        }
        switch loader.scriptHooks.hung(now - taskStart) {
        case .keepRunning:
            return false
        case .wait:
            deadline = now + budgetMs
            hungLogged = false
            return false
        case .stop:
            stop()
            return true
        }
    }

    /// Switch scripts off for this page (Stop script).
    func stop() {
        if stopped { return }
        stopped = true
        page.loop.clearAll()
        log("script stopped " + url.href)
        loader.scriptsChanged()
    }

    // MARK: Collecting

    /// The parser's scripts, in document order. Starts their fetches.
    func collect() {
        var nodes: [HTMLNode] = []
        page.document.walk { n in
            if n.kind == .element && n.name == "script" && (n.namespace == .html || n.namespace == .svg) { nodes.append(n) }
            return nodes.count < maxScripts
        }
        for n in nodes { prepare(n, dynamic: false) }
    }

    /// HTML "prepare the script element", simplified.
    func prepare(_ n: HTMLNode, dynamic: Bool) {
        if n.scriptAlreadyStarted || stopped { return }
        if let t = n.attribute("type"), browserLowerTrim(t) == "importmap" {
            n.scriptAlreadyStarted = true
            registerImportMap(n)
            return
        }
        guard let kind = browserScriptKind(n) else { return }
        let hasSrc = n.hasAttribute("src")
        if !hasSrc && n.textContent.isEmpty && dynamic { return }   // may get text or src later
        n.scriptAlreadyStarted = true
        if kind == "classic" && n.hasAttribute("nomodule") { return }
        if items.count >= maxScripts { return }
        let isModule = kind == "module"
        var src: URLRecord? = nil
        if hasSrc {
            let s = n.attribute("src") ?? ""
            guard !s.isEmpty, let u = loader.page?.resolve(s) else {
                queueElementEvent("error", n)
                return
            }
            src = u
        }
        let isAsync: Bool
        if isModule { isAsync = n.hasAttribute("async") || dynamic }
        else { isAsync = (hasSrc && n.hasAttribute("async")) || (dynamic && hasSrc) }
        let item = BrowserScriptItem(node: n, isModule: isModule, isAsync: isAsync, src: src, dynamic: dynamic)
        items.append(item)
        if let u = src {
            if isModule {
                item.moduleName = u.href
                item.modulesPending = 1
                item.visited.insert(u.href)
                item.source = []
                requestModule(u.href, for: item)
            } else {
                loader.fetchScript(u, item: item)
            }
        } else {
            let text = Array(n.textContent.utf8)
            if isModule {
                inlineModules += 1
                item.moduleName = url.href + "#module" + String(inlineModules)
                item.source = text
                moduleSources[item.moduleName] = text
                scanImports(item.moduleName, text, for: item)
            } else {
                item.source = text
            }
        }
        if dynamic {
            loader.scheduleScripts()
        }
    }

    func mutated(_ m: HTMLMutation) {
        if stopped { return }
        switch m.kind {
        case .childList:
            if m.target.kind == .element && m.target.name == "script" && m.target.isConnected && !m.addedNodes.isEmpty {
                // Text added to an empty script.
                prepare(m.target, dynamic: true)
            }
            for a in m.addedNodes where a.isConnected && a.ownerDocument === page.document && a.kind == .element {
                var found: [HTMLNode] = []
                a.walk { n in
                    if n.kind == .element && (n.name == "script" || n.name == "img") { found.append(n) }
                    return found.count < 1000
                }
                for s in found {
                    if s.name == "img" { if let src = s.attribute("src") { loader.imageAdded(src) } }
                    else { prepare(s, dynamic: true) }
                }
            }
        case .attributes:
            if m.attributeName == "src" && m.target.kind == .element && m.target.isConnected {
                if m.target.name == "script" { prepare(m.target, dynamic: true) }
                else if m.target.name == "img", let src = m.target.attribute("src") { loader.imageAdded(src) }
            }
        default:
            break
        }
    }

    // MARK: Arrivals

    /// Decode a script body: BOM, Content-Type charset, charset attribute, document.
    func decode(_ body: [UInt8], contentType: [UInt8]?, element: HTMLNode) -> [UInt8] {
        var enc = documentEncoding
        if let cs = contentType.flatMap({ charsetFromContentType($0) }), let e = charsetEncodingForLabel(cs), e != .unsupported { enc = e }
        else if let a = element.attribute("charset"), let e = charsetEncodingForLabel(a), e != .unsupported { enc = e }
        var start = 0
        if body.count >= 3 && body[0] == 0xef && body[1] == 0xbb && body[2] == 0xbf { enc = .utf8; start = 3 }
        else if body.count >= 2 && body[0] == 0xff && body[1] == 0xfe { enc = .utf16le; start = 2 }
        else if body.count >= 2 && body[0] == 0xfe && body[1] == 0xff { enc = .utf16be; start = 2 }
        if enc == .utf8 && start == 0 { return body }
        return charsetDecodeToUTF8(body, enc, from: start)
    }

    func scriptArrived(_ item: BrowserScriptItem, _ resp: BrowserResponse?) {
        guard let r = resp, r.status < 400 else {
            item.failed = true
            log("subresource failed: " + (item.src?.href ?? "") + ": script")
            return
        }
        item.source = decode(r.body, contentType: r.contentType, element: item.node)
    }

    func requestModule(_ u: String, for item: BrowserScriptItem) {
        if let src = moduleSources[u] {
            scanImports(u, src, for: item)
            item.modulesPending -= 1
            return
        }
        if moduleFailed.contains(u) {
            item.modulesPending -= 1
            return
        }
        if var w = moduleWaiters[u] {
            w.append(item)
            moduleWaiters[u] = w
            return
        }
        if moduleWaiters.count + moduleSources.count >= maxModules {
            moduleFailed.insert(u)
            item.modulesPending -= 1
            return
        }
        moduleWaiters[u] = [item]
        guard let rec = URLRecord.parseOrNil(u) else {
            moduleArrived(u, nil)
            return
        }
        loader.fetchModule(rec, key: u)
    }

    /// Resolve a module specifier: relative or absolute URLs, and bare
    /// specifiers through the page's import map (9J: GitHub's React bundles
    /// import "react").
    func resolveModule(_ spec: String, referrer: String) -> String? {
        let b = Array(spec.utf8)
        let relative = spec.hasPrefix("/") || spec.hasPrefix("./") || spec.hasPrefix("../")
        var asURL: String? = nil
        if relative {
            guard let base = URLRecord.parseOrNil(referrer) ?? loader.page?.base else { return nil }
            asURL = base.resolve(b)?.href
        } else if let u = URLRecord.parseOrNil(spec) {
            asURL = u.href
        }
        if !importMap.isEmpty, let mapped = importMapLookup(asURL ?? spec, referrer: referrer) { return mapped }
        return asURL
    }

    /// An import map: (scope URL prefix, "" for top-level imports) with its
    /// specifier map, scopes longest first. Values are absolute URLs.
    var importMap: [(scope: String, map: [(key: String, url: String)])] = []

    /// <script type=importmap>: merged into the page's map (inline only; a
    /// map after the first module fetch still applies to later ones).
    func registerImportMap(_ n: HTMLNode) {
        guard n.attribute("src") == nil, let base = loader.page?.base else {
            log("js error " + url.href + ":0: external import maps are not supported")
            return
        }
        guard let top = BrowserJSONLite.parseObject(Array(n.textContent.utf8)) else {
            log("js error " + url.href + ":0: invalid import map")
            return
        }
        func entries(_ v: BrowserJSONLite.Value) -> [(key: String, url: String)] {
            guard case .object(let pairs) = v else { return [] }
            var out: [(key: String, url: String)] = []
            for (k, val) in pairs {
                guard case .string(let target) = val, let u = base.resolve(Array(target.utf8)) else { continue }
                var key = k
                if k.hasPrefix("/") || k.hasPrefix("./") || k.hasPrefix("../") { key = base.resolve(Array(k.utf8))?.href ?? k }
                out.append((key: key, url: u.href))
            }
            return out
        }
        for (k, v) in top {
            if k == "imports" {
                importMap.append((scope: "", map: entries(v)))
            } else if k == "scopes", case .object(let scopes) = v {
                for (sk, sv) in scopes {
                    let prefix = base.resolve(Array(sk.utf8))?.href ?? sk
                    importMap.append((scope: prefix, map: entries(sv)))
                }
            }
        }
        importMap.sort { $0.scope.utf8.count > $1.scope.utf8.count }
    }

    /// The import map's URL for `spec` (exact key, else the longest key
    /// ending in "/" that prefixes it), scopes matching the referrer first.
    func importMapLookup(_ spec: String, referrer: String) -> String? {
        for (scope, map) in importMap where scope.isEmpty || referrer.hasPrefix(scope) {
            if let e = map.first(where: { $0.key == spec }) { return e.url }
            var best: (key: String, url: String)? = nil
            for e in map where e.key.hasSuffix("/") && spec.hasPrefix(e.key) {
                if best == nil || e.key.utf8.count > best!.key.utf8.count { best = e }
            }
            if let e = best { return e.url + String(decoding: Array(spec.utf8).dropFirst(e.key.utf8.count), as: UTF8.self) }
        }
        return nil
    }

    /// Count (and fetch) the modules `source` imports, transitively through
    /// the ones already here.
    func scanImports(_ name: String, _ source: [UInt8], for item: BrowserScriptItem) {
        guard let reqs = page.realm.moduleRequests(source: source) else { return }   // a SyntaxError shows at evaluation
        for spec in reqs {
            guard let u = resolveModule(spec, referrer: name) else { continue }   // reported at link time
            if item.visited.contains(u) || item.visited.count >= maxModules { continue }
            item.visited.insert(u)
            if let s = moduleSources[u] { scanImports(u, s, for: item); continue }
            if moduleFailed.contains(u) { continue }
            item.modulesPending += 1
            requestModule(u, for: item)
        }
    }

    func moduleArrived(_ key: String, _ resp: BrowserResponse?) {
        let waiters = moduleWaiters.removeValue(forKey: key) ?? []
        if let r = resp, r.status < 400 {
            let body = decode(r.body, contentType: r.contentType, element: page.document)
            moduleSources[key] = body
            for w in waiters { scanImports(key, body, for: w) }
        } else {
            moduleFailed.insert(key)
            log("subresource failed: " + key + ": module")
        }
        for w in waiters { w.modulesPending -= 1 }
    }

    // MARK: Running

    var pendingCount: Int { items.reduce(0) { $0 + ($1.done ? 0 : 1) } }
    var allDone: Bool { items.allSatisfy { $0.done } }

    /// Run what is ready. `stylesReady`: the document's stylesheets are in.
    /// Returns true if something ran.
    @discardableResult
    func pump(stylesReady: Bool) -> Bool {
        if stopped {
            for i in items where !i.done { i.done = true }
            if !domContentLoaded { domContentLoaded = true }
            return false
        }
        var ran = false
        // Async and dynamic scripts, as they arrive.
        for item in items where !item.done && (item.isAsync || item.dynamic) && item.ready {
            if !stylesReady && !item.dynamic { continue }
            execute(item)
            ran = true
            if stopped { return ran }
        }
        // The ordered list.
        if stylesReady {
            while nextOrdered < items.count {
                let item = items[nextOrdered]
                if item.done || item.isAsync || item.dynamic { nextOrdered += 1; continue }
                if !item.ready { break }
                execute(item)
                ran = true
                nextOrdered += 1
                if stopped { break }
            }
            if !domContentLoaded && orderedDone {
                domContentLoaded = true
                let t0 = loader.clock()
                beginTask()
                page.finishParsing()
                log("event DOMContentLoaded \(t0 - started) ms")
                ran = true
            }
        }
        return ran
    }

    var orderedDone: Bool {
        for item in items where !item.done && !item.isAsync && !item.dynamic { return false }
        return true
    }

    /// Everything is in: the load event (once).
    func fireLoad() {
        if loadFired || stopped || !domContentLoaded { return }
        loadFired = true
        let t0 = loader.clock()
        beginTask()
        page.finishLoading()
        log("event load \(t0 - started) ms")
    }

    func execute(_ item: BrowserScriptItem) {
        item.done = true
        beginTask()
        if item.failed {
            page.fireElementEvent("error", at: item.node)
            return
        }
        guard item.node.isConnected || !item.dynamic else { return }
        let name = item.src?.href ?? url.href
        currentName = name
        let t0 = loader.clock()
        if item.isModule {
            runModule(item)
        } else {
            page.runScript(bytes: item.source ?? [], name: name, element: item.node)
        }
        let ms = loader.clock() - t0
        scriptsRun += 1
        scriptMs += ms
        currentName = ""
        log("script " + (item.isModule ? item.moduleName : name) + " \(ms) ms")
        if item.src != nil { beginTask(); page.fireElementEvent("load", at: item.node) }
    }

    func runModule(_ item: BrowserScriptItem) {
        let realm = page.realm
        let sources = moduleSources
        unowned(unsafe) let me = self
        realm.moduleLoader = { (realm: JSRealm, specifier: String, referrer: String) -> JSModuleLoadResult in
            guard let u = me.resolveModule(specifier, referrer: referrer) else {
                return .error("Failed to resolve module specifier \"" + specifier + "\"")
            }
            if let s = me.moduleSources[u] ?? sources[u] { return .source(url: u, bytes: s) }
            return .error("Failed to fetch module " + u + " (dynamic import() of a module that was not pre-fetched)")
        }
        beginTask()
        let c = realm.evaluateModule(source: moduleSources[item.moduleName] ?? [], name: item.moduleName)
        switch c {
        case .normal(let p):
            let d = realm.heap.rootDepth
            _ = realm.heap.root(p)
            page.loop.performMicrotaskCheckpoint()
            if realm.isPromise(p), realm.promiseState(p) == .rejected {
                let v = realm.promiseResult(p)
                let msg = realm.safeToString(v)
                var stack = msg
                if v.isObject, case .value(let s) = realm.heap.getProperty(v, realm.heap.names.stack), s.isString {
                    stack = realm.heap.swiftString(s)
                }
                page.bindings.reportError(message: msg, value: v)
                reportError(msg, stack)
            }
            realm.heap.popRoots(to: d)
        default:
            page.loop.report(c)
            page.loop.performMicrotaskCheckpoint()
        }
    }

    /// An image arrived (or failed): load / error at the <img> elements using it.
    func imageEvent(_ key: String, ok: Bool) {
        if stopped { return }
        var imgs: [HTMLNode] = []
        page.document.walk { n in
            if n.kind == .element && n.name == "img" && n.attribute("src") == key { imgs.append(n) }
            return imgs.count < 1000
        }
        for n in imgs { beginTask(); page.fireElementEvent(ok ? "load" : "error", at: n) }
    }

    func elementEvent(_ type: String, _ n: HTMLNode) {
        if stopped { return }
        beginTask()
        page.fireElementEvent(type, at: n)
    }

    func queueElementEvent(_ type: String, _ n: HTMLNode) {
        page.loop.queueTask { [unowned(unsafe) self] in self.page.fireElementEvent(type, at: n) }
    }
}

/// A small JSON reader for import maps: objects, strings (with escapes),
/// and other values skipped. Bounded depth and size; nil on bad input.
enum BrowserJSONLite {
    indirect enum Value { case string(String), object([(String, Value)]), other }

    static func parseObject(_ b: [UInt8]) -> [(String, Value)]? {
        guard b.count <= 1 << 20 else { return nil }
        var i = 0
        guard let v = value(b, &i, depth: 0) else { return nil }
        skipSpace(b, &i)
        guard i == b.count, case .object(let pairs) = v else { return nil }
        return pairs
    }

    static func skipSpace(_ b: [UInt8], _ i: inout Int) {
        while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0a || b[i] == 0x0d { i += 1 }
    }

    static func value(_ b: [UInt8], _ i: inout Int, depth: Int) -> Value? {
        skipSpace(b, &i)
        guard i < b.count, depth < 32 else { return nil }
        switch b[i] {
        case 0x22:
            guard let s = string(b, &i) else { return nil }
            return .string(s)
        case 0x7b:
            i += 1
            var pairs: [(String, Value)] = []
            skipSpace(b, &i)
            if i < b.count && b[i] == 0x7d { i += 1; return .object(pairs) }
            while true {
                skipSpace(b, &i)
                guard i < b.count, b[i] == 0x22, let k = string(b, &i) else { return nil }
                skipSpace(b, &i)
                guard i < b.count, b[i] == 0x3a else { return nil }
                i += 1
                guard let v = value(b, &i, depth: depth + 1) else { return nil }
                pairs.append((k, v))
                skipSpace(b, &i)
                guard i < b.count else { return nil }
                if b[i] == 0x2c { i += 1; continue }
                if b[i] == 0x7d { i += 1; return .object(pairs) }
                return nil
            }
        case 0x5b:
            i += 1
            skipSpace(b, &i)
            if i < b.count && b[i] == 0x5d { i += 1; return .other }
            while true {
                guard value(b, &i, depth: depth + 1) != nil else { return nil }
                skipSpace(b, &i)
                guard i < b.count else { return nil }
                if b[i] == 0x2c { i += 1; continue }
                if b[i] == 0x5d { i += 1; return .other }
                return nil
            }
        default:
            // true, false, null, numbers: skipped up to a delimiter.
            let start = i
            while i < b.count, b[i] != 0x2c, b[i] != 0x7d, b[i] != 0x5d, b[i] != 0x20, b[i] != 0x0a, b[i] != 0x0d, b[i] != 0x09 { i += 1 }
            return i > start ? .other : nil
        }
    }

    static func string(_ b: [UInt8], _ i: inout Int) -> String? {
        guard i < b.count, b[i] == 0x22 else { return nil }
        i += 1
        var out: [UInt8] = []
        while i < b.count {
            let c = b[i]
            if c == 0x22 { i += 1; return String(decoding: out, as: UTF8.self) }
            if c == 0x5c {
                guard i + 1 < b.count else { return nil }
                let e = b[i + 1]
                i += 2
                switch e {
                case 0x6e: out.append(0x0a)
                case 0x74: out.append(0x09)
                case 0x72: out.append(0x0d)
                case 0x62: out.append(0x08)
                case 0x66: out.append(0x0c)
                case 0x75:
                    guard i + 4 <= b.count else { return nil }
                    var v: UInt32 = 0
                    for k in 0..<4 {
                        let h = b[i + k]
                        let d: UInt32
                        if h >= 0x30 && h <= 0x39 { d = UInt32(h - 0x30) }
                        else if h >= 0x61 && h <= 0x66 { d = UInt32(h - 0x61 + 10) }
                        else if h >= 0x41 && h <= 0x46 { d = UInt32(h - 0x41 + 10) }
                        else { return nil }
                        v = v * 16 + d
                    }
                    i += 4
                    let scalar = Unicode.Scalar(v) ?? Unicode.Scalar(0xFFFD)!
                    out.append(contentsOf: Array(String(Character(scalar)).utf8))
                default: out.append(e)
                }
                continue
            }
            out.append(c)
            i += 1
        }
        return nil
    }
}
