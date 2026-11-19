// The page loader: one document and its subresources, driven from the app's
// event loop (one `wait`, no threads).
//
//   let loader = BrowserLoader(text: textEngine, width: w, height: h)
//   loader.addTransport(fileTransport); loader.addTransport(httpTransport)
//   loader.navigate(BrowserRequest(url: u), now: Time.now)
//   loop: wait for the transports' fds or loader.timeout(now:), then
//         loader.pump(now:) and look at loader.takeChanges()
//
// Sequence: fetch the document -> decode (charset) and parse -> start every
// <link rel=stylesheet> (and their @imports, depth 4) and every <img src> at
// once -> the first layout when the CSS is in (or after `cssTimeout` ms) ->
// images decode as they arrive and relayout in batches (`relayoutDelay`) ->
// background images found by layout are fetched too -> done. stop() cancels
// everything still in flight and shows what has arrived.

struct BrowserChanges {
    /// A new document replaced the old one (reset scroll, focus, overlays).
    var newPage = false
    /// The page was laid out again: repaint (and re-apply a pending scroll).
    var layout = false
    var title = false
    /// Progress or status text changed.
    var status = false
    /// Loading ended (completed, stopped or failed).
    var finished = false

    init() {}
    var any: Bool { newPage || layout || title || status || finished }
}

/// Decoded images of a page by the URL as the page wrote it.
final class BrowserImageStore {
    var bitmaps: [String: ImageBitmap] = [:]
    var bytes = 0
    init() {}
    func size(_ key: String) -> (Int, Int)? { bitmaps[key].map { ($0.width, $0.height) } }
}

final class BrowserPage {
    /// The document's URL (after redirects). For view-source, the source's URL.
    let url: URLRecord
    /// What the address bar shows ("about:home", "view-source:...").
    let displayURL: String
    let base: URLRecord
    let document: HTMLNode
    let engine: LayoutEngine
    let forms = BrowserFormState()
    let images = BrowserImageStore()
    let isError: Bool
    let sourceSize: Int

    init(url: URLRecord, displayURL: String, document: HTMLNode, engine: LayoutEngine, isError: Bool, sourceSize: Int) {
        self.url = url
        self.displayURL = displayURL
        self.document = document
        self.engine = engine
        self.isError = isError
        self.sourceSize = sourceSize
        var b = url
        if let bh = document.firstElement(where: { $0.name == "base" && $0.attribute("href") != nil }),
           let h = bh.attribute("href"), let r = url.resolve(h) { b = r }
        base = b
    }

    var title: String { engine.title.isEmpty ? displayURL : engine.title }

    func resolve(_ s: String) -> URLRecord? { base.resolve(s) }

    /// Push the form state into the engine (call after changing `forms`).
    func syncForms() {
        engine.controlValues = forms.values
        engine.controlChecked = forms.checked
    }
}

enum BrowserPhase: Equatable { case idle, document, subresources, done }

struct BrowserTimings {
    var started = 0
    var documentMs = 0
    var parseMs = 0
    var firstLayoutMs = 0
    var styleMs = 0
    var layoutMs = 0
    var totalMs = 0
    init() {}
}

private final class BrowserSheetNode {
    var sheet: CSSStylesheet? = nil
    var children: [BrowserSheetNode] = []
    var pending = true
    let media: CSSMediaQueryList?
    let depth: Int
    init(media: CSSMediaQueryList?, depth: Int) { self.media = media; self.depth = depth }

    var complete: Bool {
        if pending { return false }
        for c in children where !c.complete { return false }
        return true
    }

    func flatten(_ ctx: CSSContext, into out: inout [CSSStylesheet]) {
        for c in children where c.media.map({ $0.queries.isEmpty || $0.matches(ctx) }) ?? true { c.flatten(ctx, into: &out) }
        if let s = sheet { out.append(s) }
    }
}

private struct BrowserJob {
    enum Kind { case sheet, image }
    var kind: Kind
    var key: String
    var url: URLRecord
    var transport: Int
    var slot = -1
    var sheet: BrowserSheetNode? = nil
    var received = 0
}

final class BrowserLoader {
    let text: TextEngine
    private(set) var transports: [BrowserTransport] = []
    private(set) var page: BrowserPage? = nil
    private(set) var phase = BrowserPhase.idle
    private(set) var viewportWidth: Int
    private(set) var viewportHeight: Int

    /// ms to wait for stylesheets before the first layout.
    var cssTimeout = 3000
    /// ms to gather image arrivals into one relayout.
    var relayoutDelay = 250
    var maxImages = 400
    var maxSheets = 64
    /// Largest decoded image (width x height x 4).
    var imageMaxBytes = 32 * 1024 * 1024
    /// All decoded images of a page together.
    var pageImageBudget = 192 * 1024 * 1024
    var maxDocumentBytes = 16 * 1024 * 1024
    /// Milliseconds clock for timings (the app passes Time.now).
    var clock: () -> Int = { 0 }
    /// Debug log lines (the app sends them to serial).
    var log: ((String) -> Void)? = nil

    private var nextID = 1
    private var docID: Int? = nil
    private var docTransport = 0
    private var docRequest: BrowserRequest? = nil
    private var docViewSource = false
    private var docReceived = 0
    private var docTotal: Int? = nil
    private var jobs: [Int: BrowserJob] = [:]
    private var slotRoots: [Int: BrowserSheetNode] = [:]
    private var sheetCount = 0
    private var requestedImages: Set<String> = []
    private var laidOut = false
    private var cssDeadline = 0
    private var relayoutAt: Int? = nil
    private var changes = BrowserChanges()
    private(set) var timings = BrowserTimings()
    private(set) var lastError: BrowserLoadError? = nil
    /// Subresources started and finished for the current page, and bytes in.
    private(set) var resourcesStarted = 0
    private(set) var resourcesDone = 0
    private(set) var bytesReceived = 0

    init(text: TextEngine, width: Int, height: Int) {
        self.text = text
        viewportWidth = max(1, width)
        viewportHeight = max(1, height)
    }

    func addTransport(_ t: BrowserTransport) { transports.append(t) }

    var isLoading: Bool { phase == .document || phase == .subresources }

    func takeChanges() -> BrowserChanges {
        let c = changes
        changes = BrowserChanges()
        return c
    }

    // MARK: Navigation

    private func transportIndex(_ scheme: String) -> Int? {
        for (i, t) in transports.enumerated() where t.handles(scheme) { return i }
        return nil
    }

    /// Load `req` as the new document. `viewSource` shows its source instead.
    func navigate(_ req: BrowserRequest, now: Int, viewSource: Bool = false) {
        cancelAll()
        lastError = nil
        timings = BrowserTimings()
        timings.started = now
        docRequest = req
        docViewSource = viewSource
        docReceived = 0
        docTotal = nil
        let scheme = String(decoding: req.url.scheme, as: UTF8.self)
        if scheme == "about" && !viewSource {
            let p = req.url.pathname
            if p == "blank" { showHTML(browserBlankPage, url: req.url, display: "about:blank", now: now); return }
            if p == "home" { showHTML(browserHomePage(), url: req.url, display: browserHomeURL, now: now); return }
            fail(.unsupportedScheme(req.url.href), url: req.url, now: now)
            return
        }
        guard let ti = transportIndex(scheme) else {
            fail(.unsupportedScheme(scheme + ":"), url: req.url, now: now)
            return
        }
        let id = nextID
        nextID += 1
        docID = id
        docTransport = ti
        phase = .document
        changes.status = true
        log?("load " + req.url.href)
        transports[ti].start(id, req, now: now)
    }

    /// Show an HTML string as a page (about: pages, error pages).
    func showHTML(_ html: String, url: URLRecord, display: String, now: Int, isError: Bool = false) {
        cancelAll()
        install(Array(html.utf8), url: url, display: display, isError: isError, now: now)
    }

    /// An error page for `err` while loading `url`.
    func fail(_ err: BrowserLoadError, url: URLRecord, now: Int) {
        lastError = err
        log?("error " + url.href + ": " + err.title + ": " + err.detail)
        showHTML(browserErrorPage(title: err.title, detail: err.detail, url: url.href), url: url, display: url.href,
                 now: now, isError: true)
    }

    /// Cancel everything in flight; keep (and lay out) what has arrived.
    func stop(now: Int) {
        let wasLoading = isLoading
        let hadDocument = docID != nil
        cancelAll()
        if hadDocument && page == nil { phase = .idle }
        if page != nil && !laidOut { relayout(now: now) }
        if page != nil { phase = .done }
        if wasLoading { changes.finished = true; changes.status = true; log?("stopped") }
    }

    private func cancelAll() {
        if let d = docID { transports[docTransport].cancel(d) }
        docID = nil
        for (id, j) in jobs { transports[j.transport].cancel(id) }
        jobs = [:]
        relayoutAt = nil
    }

    func setViewport(width: Int, height: Int) {
        let w = max(1, width), h = max(1, height)
        if w == viewportWidth && h == viewportHeight { return }
        viewportWidth = w
        viewportHeight = h
        guard let p = page else { return }
        p.engine.setViewport(width: w, height: h)
        if laidOut { relayout(now: clock()) }
    }

    // MARK: The event loop

    /// ms until pump() has something to do (0: now), or nil (only fd events).
    func timeout(now: Int) -> Int? {
        for t in transports where t.hasImmediateWork { return 0 }
        var best: Int? = nil
        func consider(_ at: Int) { let d = max(0, at - now); best = best.map { min($0, d) } ?? d }
        if page != nil && phase == .subresources && !laidOut {
            if sheetsPending == 0 { return 0 }
            consider(cssDeadline)
        }
        if let r = relayoutAt { consider(jobs.isEmpty ? now : r) }
        if phase == .subresources && laidOut && jobs.isEmpty { return 0 }
        for t in transports { if let d = t.nextDeadline(now: now) { consider(d) } }
        return best
    }

    private var sheetsPending: Int {
        var n = 0
        for (_, r) in slotRoots where !r.complete { n += 1 }
        return n
    }

    /// Make progress: poll transports, handle what arrived, lay out when due.
    func pump(now: Int) {
        for t in transports { t.poll(now: now) }
        for (i, t) in transports.enumerated() {
            if t.events.isEmpty { continue }
            let evs = t.events
            t.events = []
            for e in evs { handle(e, transport: i, now: now) }
        }
        guard page != nil, phase == .subresources else { return }
        if !laidOut {
            if sheetsPending == 0 || now >= cssDeadline {
                if sheetsPending > 0 { log?("css timeout: laying out without \(sheetsPending) sheet(s)") }
                relayout(now: now)
            }
        } else if let r = relayoutAt, now >= r || jobs.isEmpty {
            relayout(now: now)
        }
        if laidOut && jobs.isEmpty && relayoutAt == nil && phase == .subresources {
            phase = .done
            timings.totalMs = clock() - timings.started
            changes.finished = true
            changes.status = true
            if let p = page {
                log?("done " + p.displayURL + " in \(timings.totalMs) ms (document \(timings.documentMs), parse \(timings.parseMs), "
                     + "first layout \(timings.firstLayoutMs), style \(timings.styleMs), layout \(timings.layoutMs); "
                     + "\(resourcesDone)/\(resourcesStarted) resources, \(bytesReceived) bytes)")
            }
        }
    }

    private func handle(_ e: BrowserTransportEvent, transport: Int, now: Int) {
        switch e {
        case .progress(let id, let received, let total):
            if id == docID {
                docReceived = received
                docTotal = total
                changes.status = true
            } else if var j = jobs[id] {
                j.received = received
                jobs[id] = j
            }
        case .done(let id, let resp):
            if id == docID {
                docID = nil
                bytesReceived += resp.body.count
                timings.documentMs = now - timings.started
                documentArrived(resp, now: now)
            } else if let j = jobs.removeValue(forKey: id) {
                resourcesDone += 1
                bytesReceived += resp.body.count
                changes.status = true
                subresourceArrived(j, resp, now: now)
            }
        case .failed(let id, let err):
            if id == docID {
                docID = nil
                fail(err, url: docRequest?.url ?? URLRecord(), now: now)
            } else if let j = jobs.removeValue(forKey: id) {
                resourcesDone += 1
                changes.status = true
                log?("subresource failed: " + j.url.href + ": " + err.title)
                if j.kind == .sheet, let n = j.sheet { n.pending = false; sheetSettled(j.slot) }
            }
        }
    }

    // MARK: Documents

    private func lowerType(_ ct: [UInt8]?) -> String {
        guard let ct = ct else { return "" }
        var out: [UInt8] = []
        for c in ct {
            if c == 0x3b { break }
            if c == 0x20 || c == 0x09 { continue }
            out.append(c >= 0x41 && c <= 0x5a ? c + 32 : c)
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Guess a type for a body with no (useful) Content-Type.
    private func sniff(_ body: [UInt8], _ url: URLRecord) -> String {
        let path = url.pathname
        func ends(_ s: String) -> Bool { path.utf8.count >= s.utf8.count && path.hasSuffix(s) }
        if ends(".html") || ends(".htm") || ends(".xhtml") || ends("/") { return "text/html" }
        switch imageSniff(body) {
        case .png: return "image/png"
        case .gif: return "image/gif"
        case .jpeg: return "image/jpeg"
        case .svg: return "image/svg+xml"
        default: break
        }
        var i = 0
        while i < body.count && i < 512 && (body[i] == 0x20 || body[i] == 0x0a || body[i] == 0x0d || body[i] == 0x09 || body[i] == 0xef || body[i] == 0xbb || body[i] == 0xbf) { i += 1 }
        if i < body.count && body[i] == 0x3c { return "text/html" }
        var binary = false
        for b in body.prefix(512) where b == 0 { binary = true }
        return binary ? "application/octet-stream" : "text/plain"
    }

    private func documentArrived(_ resp: BrowserResponse, now: Int) {
        let req = docRequest ?? BrowserRequest(url: resp.url)
        if resp.body.count > maxDocumentBytes { fail(.tooLarge, url: resp.url, now: now); return }
        let display = docViewSource ? "view-source:" + resp.url.href : resp.url.href
        if docViewSource {
            install(Array(browserViewSourcePage(resp.body, url: resp.url.href).utf8), url: resp.url, display: display,
                    isError: false, now: now)
            return
        }
        _ = req
        if let d = resp.directory {
            install(Array(browserDirectoryPage(path: resp.url.pathname, entries: d).utf8), url: resp.url,
                    display: display, isError: false, now: now)
            return
        }
        if resp.status >= 400 && resp.body.isEmpty {
            let e = BrowserLoadError.badResponse("HTTP \(resp.status)")
            lastError = e
            install(Array(browserErrorPage(title: "HTTP \(resp.status)", detail: "The server answered with status \(resp.status).",
                                           url: resp.url.href).utf8), url: resp.url, display: display, isError: true, now: now)
            return
        }
        var type = lowerType(resp.contentType)
        if type.isEmpty || type == "application/octet-stream" || type == "text/plain" && resp.url.scheme == Array("file".utf8) {
            type = sniff(resp.body, resp.url)
        }
        let name = resp.url.pathname.split(separator: "/").last.map { String($0) } ?? resp.url.href
        if type == "text/html" || type == "application/xhtml+xml" {
            let det = charsetDetectEncoding(contentType: resp.contentType, body: resp.body)
            var bytes = resp.body
            if det.encoding != .utf8 || det.bomLength > 0 {
                bytes = charsetDecodeToUTF8(resp.body, det.encoding, from: min(det.bomLength, resp.body.count))
            }
            install(bytes, url: resp.url, display: display, isError: resp.status >= 400, now: now)
        } else if type.hasPrefix("image/") {
            let key = resp.url.href
            install(Array(browserImagePage(url: key, title: name).utf8), url: resp.url, display: display, isError: false, now: now,
                    seed: (key, resp.body))
        } else if type.hasPrefix("text/") || type.hasSuffix("json") || type.hasSuffix("javascript") || type.hasSuffix("xml") {
            install(Array(browserPlainTextPage(resp.body, title: name).utf8), url: resp.url, display: display, isError: false, now: now)
        } else {
            let e = BrowserLoadError.badResponse("can't show " + (type.isEmpty ? "this file" : type))
            lastError = e
            install(Array(browserErrorPage(title: "Can't show this file", detail: "The browser can't display " + type + " content.",
                                           url: resp.url.href).utf8), url: resp.url, display: display, isError: true, now: now)
        }
    }

    /// Parse `html` (UTF-8) and make it the current page.
    private func install(_ html: [UInt8], url: URLRecord, display: String, isError: Bool, now: Int,
                         seed: (String, [UInt8])? = nil) {
        let t0 = clock()
        let doc = htmlParse(html)
        let engine = LayoutEngine(document: doc, text: text, viewportWidth: viewportWidth, viewportHeight: viewportHeight)
        engine.clock = clock
        let p = BrowserPage(url: url, displayURL: display, document: doc, engine: engine, isError: isError, sourceSize: html.count)
        let base = p.base
        engine.resolveURL = { s in base.resolve(s)?.href ?? s }
        let store = p.images
        engine.imageSize = { key in store.size(key) }
        timings.parseMs = clock() - t0
        page = p
        phase = .subresources
        laidOut = false
        relayoutAt = nil
        slotRoots = [:]
        sheetCount = 0
        requestedImages = []
        resourcesStarted = 0
        resourcesDone = 0
        bytesReceived = html.count
        cssDeadline = now + cssTimeout
        changes.newPage = true
        changes.title = true
        changes.status = true
        log?("page " + display + " title '" + p.title + "'")
        if let (k, b) = seed { storeImage(p, key: k, b) }
        // Stylesheets.
        for (i, src) in engine.styleSources.enumerated() {
            guard let href = src.href, let u = base.resolve(href) else { continue }
            let node = BrowserSheetNode(media: nil, depth: 0)
            if startSheet(u, node: node, slot: i, now: now) { slotRoots[i] = node }
        }
        // Images in the markup (background images come after the first layout).
        for img in doc.getElementsByTagName("img") {
            if let src = img.attribute("src") { requestImage(src, now: now) }
        }
    }

    // MARK: Subresources

    private func start(_ job: BrowserJob, _ req: BrowserRequest, now: Int) -> Bool {
        let id = nextID
        nextID += 1
        jobs[id] = job
        resourcesStarted += 1
        transports[job.transport].start(id, req, now: now)
        return true
    }

    private func startSheet(_ u: URLRecord, node: BrowserSheetNode, slot: Int, now: Int) -> Bool {
        guard sheetCount < maxSheets, let ti = transportIndex(String(decoding: u.scheme, as: UTF8.self)) else { return false }
        sheetCount += 1
        var req = BrowserRequest(url: u)
        req.kind = .stylesheet
        var job = BrowserJob(kind: .sheet, key: u.href, url: u, transport: ti)
        job.slot = slot
        job.sheet = node
        return start(job, req, now: now)
    }

    private func requestImage(_ key: String, now: Int) {
        guard let p = page, !key.isEmpty, !requestedImages.contains(key), requestedImages.count < maxImages else { return }
        requestedImages.insert(key)
        if p.images.bitmaps[key] != nil { return }
        guard let u = p.resolve(key), let ti = transportIndex(String(decoding: u.scheme, as: UTF8.self)) else { return }
        var req = BrowserRequest(url: u)
        req.kind = .image
        _ = start(BrowserJob(kind: .image, key: key, url: u, transport: ti), req, now: now)
    }

    private func subresourceArrived(_ j: BrowserJob, _ resp: BrowserResponse, now: Int) {
        guard let p = page else { return }
        switch j.kind {
        case .sheet:
            guard let node = j.sheet else { return }
            node.pending = false
            if resp.status < 400 {
                let sheetURL = resp.url
                var sheet = cssParseStylesheet(resp.body, resolveURL: { s in sheetURL.resolve(s)?.href ?? s })
                if node.depth < 4 {
                    for imp in sheet.imports {
                        guard let u = sheetURL.resolve(imp.url) else { continue }
                        let child = BrowserSheetNode(media: imp.media, depth: node.depth + 1)
                        if startSheet(u, node: child, slot: j.slot, now: now) { node.children.append(child) }
                    }
                }
                sheet.imports = []
                node.sheet = sheet
            }
            sheetSettled(j.slot)
        case .image:
            if resp.status < 400 { storeImage(p, key: j.key, resp.body) }
            relayoutAt = relayoutAt ?? (now + relayoutDelay)
        }
    }

    private func storeImage(_ p: BrowserPage, key: String, _ body: [UInt8]) {
        if p.images.bytes >= pageImageBudget { return }
        let cap = min(imageMaxBytes, pageImageBudget - p.images.bytes)
        do throws(ImageError) {
            let bmp = try imageDecode(body, maxBytes: cap)
            p.images.bitmaps[key] = bmp
            p.images.bytes += bmp.width * bmp.height * 4
            p.engine.imagesChanged()
        } catch {
            log?("image " + key + ": can't decode")
        }
    }

    private func sheetSettled(_ slot: Int) {
        guard let p = page, let root = slotRoots[slot], root.complete else { return }
        var ctx = CSSContext()
        ctx.viewportWidth = Double(viewportWidth)
        ctx.viewportHeight = Double(viewportHeight)
        var sheets: [CSSStylesheet] = []
        root.flatten(ctx, into: &sheets)
        p.engine.setStyleSheets(slot: slot, sheets)
        slotRoots[slot] = nil
        if laidOut { relayoutAt = relayoutAt ?? clock() }
    }

    /// Restyle/relayout now and fetch any newly referenced images.
    func relayout(now: Int) {
        guard let p = page else { return }
        let t0 = clock()
        p.engine.update()
        let ms = clock() - t0
        if !laidOut { timings.firstLayoutMs = ms }
        timings.styleMs = p.engine.timings.styleMs
        timings.layoutMs = p.engine.timings.layoutMs
        laidOut = true
        relayoutAt = nil
        changes.layout = true
        if phase == .subresources {
            for k in p.engine.imageURLs { requestImage(k, now: now) }
        }
    }

    /// Progress text for the status line.
    var statusText: String {
        switch phase {
        case .idle: return ""
        case .document:
            var s = "Loading " + (docRequest?.url.hostname ?? "")
            if s == "Loading " { s = "Loading" }
            if docReceived > 0 {
                s += ": \(docReceived / 1024) KB"
                if let t = docTotal, t > 0 { s += " of \(t / 1024) KB" }
            }
            for t in transports where !t.activity.isEmpty { return s + " (" + t.activity + ")" }
            return s + "..."
        case .subresources:
            if !laidOut { return "Waiting for stylesheets (\(resourcesDone)/\(resourcesStarted))" }
            return "Loading \(resourcesDone)/\(resourcesStarted) resources, \(bytesReceived / 1024) KB"
        case .done:
            if lastError != nil { return "Error" }
            return "Done in \(timings.totalMs) ms"
        }
    }
}
