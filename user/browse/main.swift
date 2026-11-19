// /bin/browse [url]: the web browser (Phase 8H). The window has a toolbar
// (back, forward, reload/stop, home, the address bar), the page, and a
// status line (progress, or the link under the pointer). The page logic is
// lib/browser (loader, history, forms) on top of lib/layout; this file is
// the window, input routing and painting. One event loop: App.run's single
// `wait` covers the window, the transports' sockets and the loader's timers.
//
// Keys: Ctrl-L address bar, Alt-Left/Right or Backspace back/forward, F5 or
// Ctrl-R reload, Escape stop, arrows/PgUp/PgDn/Space/Home/End scroll.
// Serial debug lines start with "browse: " (navigation, title, done, errors).

func say(_ s: String) { debugPrint("browse: " + s + "\n") }

func makeApp() -> App {
    guard let a = App(title: "Browser", width: 1000, height: 700) else { Process.exit(1) }
    return a
}
let app = makeApp()
let theme = app.theme
let toolbarH = 30
let statusH = 20
let scrollbarW = 10

// MARK: Fonts

let fontStart = Time.now
let registry = FontRegistry()
for b in fontBundled {
    do throws(SysError) {
        let d = try browseReadFile(b.path, max: 16 * 1024 * 1024)
        _ = registry.add(d, family: b.family, generic: b.generic, bold: b.bold, italic: b.italic)
    } catch {
        say("font " + b.path + ": " + error.message)
    }
}
let textEngine = TextEngine(registry: registry)
say("fonts loaded in \(Time.now - fontStart) ms")

// MARK: Widgets

var pageRect: Rect { Rect(0, toolbarH, app.window.width, max(app.window.height - toolbarH - statusH, 1)) }
var viewRect: Rect { let r = pageRect; return Rect(r.x, r.y, max(r.w - scrollbarW, 1), r.h) }

let backButton = app.ui.button("<", frame: Rect(4, 3, 26, 24)) { goBack() }
let forwardButton = app.ui.button(">", frame: Rect(32, 3, 26, 24)) { goForward() }
let reloadButton = app.ui.button("Reload", frame: Rect(60, 3, 58, 24)) { reloadOrStop() }
let homeButton = app.ui.button("Home", frame: Rect(120, 3, 42, 24)) { navigateTo(browserHomeURL) }
let addressBar = app.ui.textField(frame: Rect(168, 3, 600, 24))
addressBar.placeholder = "Search or enter an address"
let statusLabel = app.ui.label("", x: 6, y: 0, width: 100)
/// The in-page text editor: a TextField laid over the focused <input>.
let pageField = app.ui.textField(frame: Rect(0, 0, 10, 10))
pageField.visible = false

func layoutWidgets() {
    let w = app.window.width, h = app.window.height
    addressBar.frame = Rect(168, 3, max(w - 172, 40), 24)
    statusLabel.frame = Rect(6, h - statusH + 2, max(w - 12, 10), statusH - 4)
}
layoutWidgets()

// MARK: Loader

let loader = BrowserLoader(text: textEngine, width: viewRect.w, height: viewRect.h)
loader.clock = { Time.now }
loader.log = { say($0) }
loader.addTransport(BrowserFileTransport())

// MARK: Network (http:// and https://)

/// Options: browse [-k] [--ca file] [-r|--resolve name:ip] [url]. -k accepts any certificate;
/// --ca trusts the CA certificates in a file (concatenated DER) instead of
/// /etc/roots.der (the harness's test CA).
var insecureTLS = false
var caPath = "/etc/roots.der"
var startURL: String? = nil
func parseArgs() {
    let a = Process.args
    var i = 1
    while i < a.count {
        if a[i] == "-k" { insecureTLS = true }
        else if a[i] == "--ca" && i + 1 < a.count { i += 1; caPath = a[i] }
        else if (a[i] == "--resolve" || a[i] == "-r") && i + 1 < a.count {
            i += 1
            let parts = a[i].split(separator: ":")
            if parts.count == 2, let ip = IPv4.parse(String(parts[1])) { browseResolveOverrides.append((name: String(parts[0]), ip: ip)) }
        }
        else { startURL = a[i] }
        i += 1
    }
}
parseArgs()

var trustStore = X509TrustStore()
var trustLoaded = false
func tlsConfig(_ host: String) -> TLSClientConfig {
    let now = Int64(Time.unixSeconds)
    if insecureTLS { return TLSClientConfig(serverName: host, trust: .insecureAcceptAny, now: now) }
    if !trustLoaded {
        trustLoaded = true
        do throws(SysError) {
            trustStore = X509TrustStore(concatenatedDER: try browseReadFile(caPath, max: 8 * 1024 * 1024))
        } catch {
            say("trust store " + caPath + ": " + error.message)
        }
    }
    return TLSClientConfig(serverName: host, trust: .roots(trustStore), now: now)
}

let http = BrowserHTTPTransport()
http.unixTime = { Time.unixSeconds }
http.openStream = { host, port, tls, _ in
    let raw = BrowseSocketStream(host: host, port: port)
    if !tls { return raw }
    return BrowserTLSStream(raw: raw, config: tlsConfig(host), random: { Random.bytes($0) })
}
loader.addTransport(http)

var history = BrowserHistory()
var scrollX = 0
var scrollY = 0
/// Scroll to apply once the page has a layout (history), or a fragment.
var pendingScroll: (Int, Int)? = nil
var pendingFragment: String? = nil
var userScrolled = false
var hoverHref: String? = nil
var hoverNode: HTMLNode? = nil
var hoverAt: Int? = nil
var hoverDisabled = false
var lastButtons = 0
/// The control the in-page field edits.
var editing: HTMLNode? = nil
/// An open <select>: its options and the list's screen rectangle.
struct Dropdown {
    var select: HTMLNode
    var options: [BrowserOption]
    var rect: Rect
    var hover: Int
}
var dropdown: Dropdown? = nil
let rowH = 18

var page: BrowserPage? { loader.page }

func maxScrollY() -> Int {
    guard let p = page else { return 0 }
    return max(Int(p.engine.documentHeight) - viewRect.h, 0)
}

func maxScrollX() -> Int {
    guard let p = page else { return 0 }
    return max(Int(p.engine.documentWidth) - viewRect.w, 0)
}

func scrollTo(x: Int, y: Int) {
    let nx = max(0, min(x, maxScrollX())), ny = max(0, min(y, maxScrollY()))
    if nx == scrollX && ny == scrollY { return }
    scrollX = nx
    scrollY = ny
    closeDropdown()
    placePageField()
    if hoverHref != nil { hoverHref = nil; refreshStatus() }
    app.requestPaint()
    say("scroll y=\(scrollY)")
}

func scrollBy(_ dy: Int) {
    userScrolled = true
    scrollTo(x: scrollX, y: scrollY + dy)
}

// MARK: Navigation

func setStatus(_ s: String) {
    if statusLabel.text != s { statusLabel.text = s }
}

func refreshStatus() {
    if let h = hoverHref { setStatus(h); return }
    setStatus(loader.statusText)
}

func updateButtons() {
    backButton.enabled = history.canGoBack
    forwardButton.enabled = history.canGoForward
    reloadButton.title = loader.isLoading ? "Stop" : "Reload"
}

/// Start loading `req`; `display` is the address bar text.
func load(_ req: BrowserRequest, display: String, viewSource: Bool, push: Bool, restore: (Int, Int)?) {
    history.saveScroll(x: scrollX, y: scrollY)
    // Same document, new fragment: just scroll.
    if !viewSource, push, req.method == "GET", let p = page, !p.isError, let frag = req.url.fragment,
       p.displayURL.utf8.first != 0x76, // not view-source
       p.url.serializedBytes(excludeFragment: true) == req.url.serializedBytes(excludeFragment: true) {
        var e = BrowserHistoryEntry(url: req.url.href)
        e.title = p.title
        history.push(e)
        addressBar.text = req.url.href
        let name = String(decoding: urlPercentDecode(frag), as: UTF8.self)
        if let y = p.engine.fragmentY(name) { userScrolled = true; scrollTo(x: 0, y: Int(y)) }
        say("fragment #" + name + " y=\(scrollY)")
        updateButtons()
        return
    }
    if push {
        var e = BrowserHistoryEntry(url: display)
        e.method = req.method
        e.body = req.body
        e.contentType = req.contentType
        history.push(e)
    }
    say("navigate " + display)
    addressBar.text = display
    pendingScroll = restore
    pendingFragment = req.url.fragment.map { String(decoding: urlPercentDecode($0), as: UTF8.self) }
    userScrolled = false
    loader.navigate(req, now: Time.now, viewSource: viewSource)
    afterLoaderWork()
}

/// Parse address-bar style text (or a link target already absolute) and go.
func navigateTo(_ text: String, push: Bool = true, restore: (Int, Int)? = nil, method: String = "GET",
                body: [UInt8] = [], contentType: String? = nil) {
    guard let norm = browserNormalizeInput(text) else { return }
    var viewSource = false
    var target = norm
    if norm.hasPrefix("view-source:") {
        viewSource = true
        target = browserNormalizeInput(String(norm.dropFirst(12))) ?? ""
    }
    guard let u = URLRecord.parseOrNil(target) else {
        loader.fail(.badRedirect, url: URLRecord.parseOrNil("about:blank") ?? URLRecord(), now: Time.now)
        afterLoaderWork()
        return
    }
    var req = BrowserRequest(url: u)
    req.method = method
    req.body = body
    req.contentType = contentType
    load(req, display: viewSource ? "view-source:" + u.href : (target.hasPrefix("about:") ? target : u.href),
         viewSource: viewSource, push: push, restore: restore)
}

func goBack() {
    history.saveScroll(x: scrollX, y: scrollY)
    guard let e = history.back() else { return }
    navigateTo(e.url, push: false, restore: (e.scrollX, e.scrollY), method: e.method, body: e.body, contentType: e.contentType)
    updateButtons()
}

func goForward() {
    history.saveScroll(x: scrollX, y: scrollY)
    guard let e = history.forward() else { return }
    navigateTo(e.url, push: false, restore: (e.scrollX, e.scrollY), method: e.method, body: e.body, contentType: e.contentType)
    updateButtons()
}

func reloadOrStop() {
    if loader.isLoading {
        loader.stop(now: Time.now)
        afterLoaderWork()
        return
    }
    guard let e = history.current else { return }
    history.saveScroll(x: scrollX, y: scrollY)
    navigateTo(e.url, push: false, restore: (scrollX, scrollY), method: e.method, body: e.body, contentType: e.contentType)
}

addressBar.onSubmit = { text in
    app.ui.setFocus(nil)
    navigateTo(text)
}
addressBar.onCancel = {
    addressBar.text = page?.displayURL ?? ""
    app.ui.setFocus(nil)
}

/// Follow a link (href as written in the page).
func follow(_ href: String) {
    guard let p = page else { return }
    let lower = href.utf8.prefix(11).map { $0 >= 0x41 && $0 <= 0x5a ? $0 + 32 : $0 }
    if lower.starts(with: Array("javascript:".utf8)) { setStatus("JavaScript links don't work (no JavaScript)"); return }
    guard let u = p.resolve(href) else { return }
    say("click link " + u.href)
    load(BrowserRequest(url: u), display: u.href, viewSource: false, push: true, restore: nil)
}

// MARK: Loader results

func afterLoaderWork() {
    let c = loader.takeChanges()
    if c.newPage {
        scrollX = 0
        scrollY = 0
        hoverHref = nil
        hoverNode = nil
        hoverAt = nil
        hoverDisabled = false
        editing = nil
        pageField.visible = false
        if app.ui.focused === pageField { app.ui.setFocus(nil) }
        dropdown = nil
        if let p = page {
            if app.ui.focused !== addressBar { addressBar.text = p.displayURL }
            history.setURL(p.displayURL.hasPrefix("about:") || p.displayURL.hasPrefix("view-source:") ? p.displayURL : p.url.href)
            if history.current == nil { history.push(BrowserHistoryEntry(url: p.displayURL)) }
        }
    }
    if c.title, let p = page {
        var t = p.title
        if t.utf8.count > 120 { t = String(decoding: Array(t.utf8.prefix(117)), as: UTF8.self) + "..." }
        app.window.setTitle(t)
        history.setTitle(t)
        say("title '" + t + "'")
    }
    if c.layout {
        if !userScrolled {
            if let (x, y) = pendingScroll {
                scrollX = max(0, min(x, maxScrollX()))
                scrollY = max(0, min(y, maxScrollY()))
            } else if let f = pendingFragment, let p = page, let y = p.engine.fragmentY(f) {
                scrollY = max(0, min(Int(y), maxScrollY()))
            }
        }
        scrollX = min(scrollX, maxScrollX())
        scrollY = min(scrollY, maxScrollY())
        placePageField()
        app.requestPaint()
    }
    if c.finished {
        pendingScroll = nil
        pendingFragment = nil
    }
    if c.any { refreshStatus(); updateButtons() }
}

// MARK: Forms

func screenRect(_ r: LayoutRect) -> Rect {
    let v = viewRect
    return Rect(v.x + Int(r.x) - scrollX, v.y + Int(r.y) - scrollY, max(Int(r.w), 1), max(Int(r.h), 1))
}

func placePageField() {
    guard let n = editing, let p = page else { return }
    guard let r = p.engine.rect(of: n) else { commitPageField(); return }
    var f = screenRect(r)
    f.h = max(f.h, 20)
    f.w = max(f.w, 40)
    if !viewRect.contains(Point(f.x, f.y)) || !viewRect.contains(Point(f.maxX - 1, f.maxY - 1)) { commitPageField(); return }
    pageField.frame = f
}

func commitPageField() {
    guard let n = editing, let p = page else { pageField.visible = false; editing = nil; return }
    p.forms.values[ObjectIdentifier(n)] = pageField.text
    p.syncForms()
    editing = nil
    pageField.visible = false
    if app.ui.focused === pageField { app.ui.setFocus(nil) }
    app.requestPaint()
}

func beginEditing(_ n: HTMLNode) {
    guard let p = page else { return }
    commitPageField()
    editing = n
    pageField.text = browserControlValue(n, p.forms)
    pageField.secure = browserControlType(n) == "password"
    pageField.visible = true
    placePageField()
    guard editing != nil else { return }
    app.ui.setFocus(pageField)
    pageField.setCursor(pageField.count)
}

pageField.onChange = { text in
    guard let n = editing, let p = page else { return }
    p.forms.values[ObjectIdentifier(n)] = text
    p.syncForms()
}
pageField.onSubmit = { _ in
    guard let n = editing else { return }
    let isTextarea = n.name == "textarea"
    commitPageField()
    if !isTextarea, let form = browserFormOwner(n) { submit(form, submitter: browserDefaultButton(form)) }
}
pageField.onCancel = { commitPageField() }

func submit(_ form: HTMLNode, submitter: HTMLNode?) {
    guard let p = page else { return }
    commitPageField()
    guard let req = browserFormSubmission(form, submitter: submitter, p.forms, documentURL: p.url, base: p.base) else { return }
    say("submit " + req.method + " " + req.url.href)
    load(req, display: req.url.href, viewSource: false, push: true, restore: nil)
}

func openDropdown(_ select: HTMLNode) {
    guard let p = page, let r = p.engine.rect(of: select) else { return }
    let opts = browserSelectOptions(select)
    if opts.isEmpty { return }
    let sr = screenRect(r)
    var widest = sr.w
    for o in opts { widest = max(widest, theme.font.textWidth(o.label) + 16) }
    let rows = min(opts.count, max((viewRect.h - 8) / rowH, 1))
    var y = sr.maxY
    if y + rows * rowH > viewRect.maxY { y = max(viewRect.y, sr.y - rows * rowH) }
    dropdown = Dropdown(select: select, options: opts, rect: Rect(sr.x, y, min(widest, viewRect.w), rows * rowH + 2),
                        hover: browserSelectedIndex(select, p.forms))
    app.requestPaint()
}

func closeDropdown() {
    if dropdown != nil { dropdown = nil; app.requestPaint() }
}

func chooseDropdown(_ i: Int) {
    guard let d = dropdown, let p = page else { return }
    if i >= 0 && i < d.options.count && !d.options[i].disabled {
        browserSelectOption(d.select, i, p.forms)
        p.syncForms()
        say("select '" + d.options[i].label + "'")
    }
    closeDropdown()
}

/// A click on a form control in the page.
func activate(_ n: HTMLNode) {
    guard let p = page, !browserIsDisabled(n) else { return }
    if browserIsTextControl(n) { beginEditing(n); return }
    commitPageField()
    let type = browserControlType(n)
    switch type {
    case "checkbox", "radio":
        if browserToggle(n, p.forms) { p.syncForms(); app.requestPaint() }
    case "select":
        openDropdown(n)
    case "submit", "image":
        if let f = browserFormOwner(n) { submit(f, submitter: n) }
    case "reset":
        if let f = browserFormOwner(n) { browserResetForm(f, p.forms); p.syncForms(); app.requestPaint() }
    default:
        break
    }
}

// MARK: Painting

app.onPaint = { s in
    let pr = pageRect
    let v = viewRect
    if let p = page {
        let images = p.images
        p.engine.paint(into: s.pixels + v.y * s.stride + v.x, stride: s.stride, width: v.w, height: v.h,
                       scrollX: Double(scrollX), scrollY: Double(scrollY),
                       images: { images.bitmaps[$0] })
    } else {
        s.fill(v, 0xFFFFFF)
    }
    // Scrollbar.
    let track = Rect(pr.maxX - scrollbarW, pr.y, scrollbarW, pr.h)
    s.fill(track, theme.scrollTrack)
    let total = maxScrollY() + v.h
    if total > v.h {
        let th = max(v.h * v.h / total, 16)
        let ty = pr.y + (v.h - th) * scrollY / max(maxScrollY(), 1)
        s.fill(Rect(track.x + 2, ty, scrollbarW - 4, th), theme.scrollThumb)
    }
    // Toolbar and status separators.
    s.fill(Rect(0, toolbarH - 1, pr.w, 1), theme.buttonBorder)
    s.fill(Rect(0, pr.maxY, pr.w, 1), theme.buttonBorder)
    // An open dropdown.
    if let d = dropdown {
        s.fill(d.rect, theme.fieldBackground)
        s.frame(d.rect, theme.focusBorder)
        let first = max(0, min(d.hover - d.rect.h / rowH + 1, d.options.count - d.rect.h / rowH))
        var y = d.rect.y + 1
        var i = first
        while i < d.options.count && y + rowH <= d.rect.maxY {
            let o = d.options[i]
            let r = Rect(d.rect.x + 1, y, d.rect.w - 2, rowH)
            if i == d.hover { s.fill(r, theme.selection) }
            s.withClip(r) {
                _ = s.drawText(o.label, font: theme.font, at: Point(r.x + 6, r.y + 1),
                               fg: i == d.hover ? theme.selectionText : (o.disabled ? theme.disabledText : theme.text), bg: nil)
            }
            y += rowH
            i += 1
        }
    }
}

func dropdownRow(at p: Point) -> Int? {
    guard let d = dropdown, d.rect.contains(p) else { return nil }
    let first = max(0, min(d.hover - d.rect.h / rowH + 1, d.options.count - d.rect.h / rowH))
    let i = first + (p.y - d.rect.y - 1) / rowH
    return i >= 0 && i < d.options.count ? i : nil
}

// MARK: Input

func pageKey(_ k: GUIKeyEvent) -> Bool {
    let v = viewRect
    if let d = dropdown {
        switch k.code {
        case WinKey.up: dropdown?.hover = max(d.hover - 1, 0); app.requestPaint()
        case WinKey.down: dropdown?.hover = min(d.hover + 1, d.options.count - 1); app.requestPaint()
        case GUIKeyEvent.enter, 0x20: chooseDropdown(d.hover)
        case GUIKeyEvent.escape: closeDropdown()
        default: break
        }
        return true
    }
    switch k.code {
    case WinKey.up: scrollBy(-40)
    case WinKey.down: scrollBy(40)
    case WinKey.left: userScrolled = true; scrollTo(x: scrollX - 40, y: scrollY)
    case WinKey.right: userScrolled = true; scrollTo(x: scrollX + 40, y: scrollY)
    case WinKey.pageUp: scrollBy(-(v.h - 40))
    case WinKey.pageDown: scrollBy(v.h - 40)
    case 0x20: scrollBy(k.shift ? -(v.h - 40) : v.h - 40)
    case WinKey.home: userScrolled = true; scrollTo(x: 0, y: 0)
    case WinKey.end: userScrolled = true; scrollTo(x: scrollX, y: maxScrollY())
    case GUIKeyEvent.backspace: goBack()
    default: return false
    }
    return true
}

func globalKey(_ k: GUIKeyEvent) -> Bool {
    if k.isCtrl(0x6c) { // Ctrl-L
        commitPageField()
        app.ui.setFocus(addressBar)
        addressBar.selectAll()
        return true
    }
    if k.alt && k.code == WinKey.left { goBack(); return true }
    if k.alt && k.code == WinKey.right { goForward(); return true }
    if k.code == WinKey.function + 5 || k.isCtrl(0x72) { // F5, Ctrl-R
        if loader.isLoading { loader.stop(now: Time.now); afterLoaderWork() }
        reloadOrStop()
        return true
    }
    if k.code == GUIKeyEvent.escape && loader.isLoading && app.ui.focused !== addressBar {
        loader.stop(now: Time.now)
        afterLoaderWork()
        return true
    }
    return false
}

func pageMouse(_ x: Int, _ y: Int, _ buttons: Int, _ wheel: Int) -> Bool {
    let pt = Point(x, y)
    let pressed = buttons & Int(WinButton.left) != 0 && lastButtons & Int(WinButton.left) == 0
    lastButtons = buttons
    if wheel != 0 {
        if let d = dropdown, d.rect.contains(pt) {
            dropdown?.hover = max(0, min(d.hover - wheel, d.options.count - 1))
            app.requestPaint()
        } else {
            scrollBy(-wheel * 60)
        }
        return true
    }
    if dropdown != nil {
        if let i = dropdownRow(at: pt) {
            if pressed { chooseDropdown(i) } else if dropdown?.hover != i { dropdown?.hover = i; app.requestPaint() }
            return true
        }
        if pressed { closeDropdown(); return true }
    }
    if pageField.visible && (pageField.frame.contains(pt) || app.ui.focused === pageField && buttons != 0 && !pressed) {
        return false
    }
    let v = viewRect
    guard pageRect.contains(pt) else {
        if hoverHref != nil { hoverHref = nil; refreshStatus() }
        return false
    }
    guard let p = page else { return true }
    if !v.contains(pt) {
        // The scrollbar: a click pages towards it.
        if pressed {
            let total = maxScrollY() + v.h
            let th = max(v.h * v.h / max(total, 1), 16)
            let ty = v.y + (v.h - th) * scrollY / max(maxScrollY(), 1)
            scrollBy(pt.y < ty ? -(v.h - 40) : (pt.y > ty + th ? v.h - 40 : 0))
        }
        return true
    }
    let hit = p.engine.hitTest(x: Double(pt.x - v.x), y: Double(pt.y - v.y), scrollX: Double(scrollX), scrollY: Double(scrollY))
    if pressed {
        if app.ui.focused === addressBar { addressBar.text = p.displayURL }
        app.ui.setFocus(nil)
        if let c = hit.control { activate(c); return true }
        commitPageField()
        if let n = hit.node, let label = browserEnclosingLabel(n), let target = browserLabelTarget(label) {
            activate(target)
            return true
        }
        if let h = hit.href { follow(h); return true }
        return true
    }
    if buttons == 0 {
        var h: String? = nil
        if let href = hit.href { h = p.resolve(href)?.href ?? href }
        if h != hoverHref { hoverHref = h; refreshStatus() }
        if !hoverDisabled && hit.node !== hoverNode {
            hoverNode = hit.node
            hoverAt = Time.now + 60
        }
    }
    return true
}

app.onEvent = { e in
    switch e {
    case .key(let k):
        if globalKey(k) { return true }
        if let f = app.ui.focused, f === addressBar || f === pageField { return false }
        if k.code == GUIKeyEvent.tab { return false }
        return pageKey(k)
    case .mouse(let x, let y, let b, let w):
        return pageMouse(x, y, b, w)
    case .focus(let on):
        if !on { lastButtons = 0 }
        return false
    default:
        return false
    }
}

app.onResize = { w, h in
    layoutWidgets()
    closeDropdown()
    loader.setViewport(width: viewRect.w, height: viewRect.h)
    afterLoaderWork()
    scrollTo(x: scrollX, y: scrollY)
    placePageField()
}

// MARK: The loop

func applyHover() {
    guard let at = hoverAt, Time.now >= at else { return }
    hoverAt = nil
    guard let p = page, !loader.isLoading || true else { return }
    let t0 = Time.now
    if p.engine.setHover(hoverNode) {
        p.engine.update()
        app.requestPaint()
        let ms = Time.now - t0
        if ms > 250 {
            hoverDisabled = true
            say("hover took \(ms) ms: hover effects off for this page")
        }
    }
}

app.nextTimeout = {
    var best = loader.timeout(now: Time.now)
    if let h = hoverAt { let d = max(0, h - Time.now); best = best.map { min($0, d) } ?? d }
    return best
}

app.onIdle = {
    let now = Time.now
    loader.pump(now: now)
    afterLoaderWork()
    applyHover()
}

app.dynamicWaits = {
    var out: [WaitFD] = []
    for t in loader.transports { for d in t.waitDescriptors() { out.append(WaitFD(fd: Int32(d.fd), events: d.events, revents: 0)) } }
    return out
}
app.onDynamicReady = { _ in } // onIdle pumps every transport after each wait

say("ready \(app.window.width)x\(app.window.height)")
navigateTo(startURL ?? browserHomeURL)
updateButtons()
let code = app.run()
for t in loader.transports { t.shutdown() }
say("exit")
Process.exit(code)
