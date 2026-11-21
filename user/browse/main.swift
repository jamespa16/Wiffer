// /bin/browse [url]: the web browser (Phase 8H, scripts Phase 9H). The window
// has a toolbar (back, forward, reload/stop, home, the JS switch, the address
// bar), the page, an optional console panel, and a status line (progress,
// script errors, or the link under the pointer). The page logic is lib/browser
// (loader, history, forms, scripts) on top of lib/layout and lib/js-dom; this
// file is the window, input routing and painting. One event loop: App.run's
// single `wait` covers the window, the transports' sockets and the loader's
// timers (CSS deadline, JS timers, the next rendering step).
//
// With scripts on, input is "dispatch the DOM event, then do the default
// action unless it was canceled": link following, checkbox toggling, submit
// buttons and labels are the page's activation behavior (JSDOMPage), and the
// page owns focus and form control values.
//
// Keys: Ctrl-L address bar, Alt-Left/Right or Backspace back/forward, F5 or
// Ctrl-R reload, Escape stop, Ctrl-Shift-J console, arrows/PgUp/PgDn/Space/
// Home/End scroll. Serial debug lines start with "browse: ".

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
let consoleH = 170

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

var consoleOpen = false
var pageRect: Rect {
    Rect(0, toolbarH, app.window.width, max(app.window.height - toolbarH - statusH - (consoleOpen ? consoleH : 0), 1))
}
var viewRect: Rect { let r = pageRect; return Rect(r.x, r.y, max(r.w - scrollbarW, 1), r.h) }
var consoleRect: Rect { Rect(0, pageRect.maxY + 1, app.window.width, consoleH - 1) }

let backButton = app.ui.button("<", frame: Rect(4, 3, 26, 24)) { goBack() }
let forwardButton = app.ui.button(">", frame: Rect(32, 3, 26, 24)) { goForward() }
let reloadButton = app.ui.button("Reload", frame: Rect(60, 3, 58, 24)) { reloadOrStop() }
let homeButton = app.ui.button("Home", frame: Rect(120, 3, 42, 24)) { navigateTo(browserHomeURL) }
let jsButton = app.ui.button("JS", frame: Rect(164, 3, 50, 24)) { toggleJS() }
let addressBar = app.ui.textField(frame: Rect(218, 3, 550, 24))
addressBar.placeholder = "Search or enter an address"
let statusLabel = app.ui.label("", x: 6, y: 0, width: 100)
/// The in-page text editor: a TextField laid over the focused <input>.
let pageField = app.ui.textField(frame: Rect(0, 0, 10, 10))
pageField.visible = false
/// The console panel's input line.
let consoleField = app.ui.textField(frame: Rect(0, 0, 10, 10))
consoleField.placeholder = "Evaluate in the page"
consoleField.visible = false

func layoutWidgets() {
    let w = app.window.width, h = app.window.height
    addressBar.frame = Rect(218, 3, max(w - 222, 40), 24)
    statusLabel.frame = Rect(6, h - statusH + 2, max(w - 12, 10), statusH - 4)
    let c = consoleRect
    consoleField.frame = Rect(4, c.maxY - 24, max(w - 8, 20), 22)
    consoleField.visible = consoleOpen
}
layoutWidgets()

// MARK: Loader

let loader = BrowserLoader(text: textEngine, width: viewRect.w, height: viewRect.h)
loader.clock = { Time.now }
loader.log = { say($0) }
loader.addTransport(BrowserFileTransport())

// MARK: Options and network (http:// and https://)

/// Options: browse [-k] [--ca file] [-r|--resolve name:ip] [--nojs] [url]. -k
/// accepts any certificate; --ca trusts the CA certificates in a file
/// (concatenated DER) instead of /etc/roots.der (the harness's test CA);
/// --nojs turns scripts off (Part 8 behavior).
var insecureTLS = false
var caPath = "/etc/roots.der"
var startURL: String? = nil
var jsEnabled = true
func parseArgs() {
    let a = Process.args
    var i = 1
    while i < a.count {
        if a[i] == "-k" { insecureTLS = true }
        else if a[i] == "--nojs" { jsEnabled = false }
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
loader.scriptsEnabled = jsEnabled
jsButton.title = jsEnabled ? "JS" : "no JS"

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
/// The control the in-page field edits, and its value when editing began.
var editing: HTMLNode? = nil
var editStartValue = ""
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
/// The page's script environment, while its scripts run, for UI code: each
/// use starts a new task budget (input handlers are tasks).
var sp: JSDOMPage? {
    guard let s = loader.page?.scripts, !s.stopped else { return nil }
    s.beginTask()
    return s.page
}
/// The same without touching the budget (for hooks called while a script runs).
var scriptPage: JSDOMPage? {
    guard let s = loader.page?.scripts, !s.stopped else { return nil }
    return s.page
}

// MARK: Deferred actions (never navigate while a script is on the stack)

var deferred: [() -> Void] = []
func later(_ f: @escaping () -> Void) { deferred.append(f) }
func runDeferred() {
    var n = 0
    while !deferred.isEmpty && n < 64 {
        let f = deferred.removeFirst()
        f()
        n += 1
    }
}

func maxScrollY() -> Int {
    guard let p = page else { return 0 }
    return max(Int(p.engine.documentHeight) - viewRect.h, 0)
}

func maxScrollX() -> Int {
    guard let p = page else { return 0 }
    return max(Int(p.engine.documentWidth) - viewRect.w, 0)
}

var scrollEventPending = false

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
    if scriptPage != nil { scrollEventPending = true }
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
        if let s = sp {
            // The page's location does it (URL, history entry, hashchange).
            try? s.bindings.navigate(req.url.href, replace: false)
            return
        }
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

/// Move `delta` entries through history (same-document entries fire popstate).
func go(_ delta: Int) {
    history.saveScroll(x: scrollX, y: scrollY)
    var e: BrowserHistoryEntry? = nil
    var k = 0
    while k < abs(delta) {
        guard let x = delta < 0 ? history.back() : history.forward() else { break }
        e = x
        k += 1
    }
    guard let entry = e else { return }
    if let p = page, entry.documentID != 0, entry.documentID == p.documentID, let s = sp {
        if app.ui.focused !== addressBar { addressBar.text = entry.url }
        say("popstate " + entry.url)
        s.popState(id: entry.stateID, url: entry.url)
        userScrolled = true
        scrollTo(x: entry.scrollX, y: entry.scrollY)
        afterScriptInput()
        updateButtons()
        return
    }
    navigateTo(entry.url, push: false, restore: (entry.scrollX, entry.scrollY), method: entry.method, body: entry.body,
               contentType: entry.contentType)
    updateButtons()
}

func goBack() { go(-1) }
func goForward() { go(1) }

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

func toggleJS() {
    jsEnabled = !jsEnabled
    loader.scriptsEnabled = jsEnabled
    jsButton.title = jsEnabled ? "JS" : "no JS"
    say("javascript " + (jsEnabled ? "on" : "off"))
    if !loader.isLoading, history.current != nil { reloadOrStop() }
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
    if lower.starts(with: Array("javascript:".utf8)) {
        guard let s = sp else { setStatus("JavaScript links don't work (JavaScript is off)"); return }
        let code = String(decoding: urlPercentDecode(Array(href.utf8.dropFirst(11))), as: UTF8.self)
        s.runScript(code, name: p.url.href)
        afterScriptInput()
        return
    }
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
        hoverElement = nil
        pressTarget = nil
        editing = nil
        pageField.visible = false
        if app.ui.focused === pageField { app.ui.setFocus(nil) }
        dropdown = nil
        consoleLines = []
        if let p = page {
            if app.ui.focused !== addressBar { addressBar.text = p.displayURL }
            history.setURL(p.displayURL.hasPrefix("about:") || p.displayURL.hasPrefix("view-source:") ? p.displayURL : p.url.href)
            if history.current == nil { history.push(BrowserHistoryEntry(url: p.displayURL)) }
            history.setDocument(p.documentID)
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

/// After the page's scripts ran for an input event (or the console).
func afterScriptInput() {
    loader.afterScripts(now: Time.now)
    afterLoaderWork()
    if consoleOpen { app.requestPaint() }
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
    if let s = sp, pageField.text != editStartValue { s.fireEvent("change", at: n, bubbles: true) }
}

func beginEditing(_ n: HTMLNode) {
    guard let p = page else { return }
    if editing === n { return }
    commitPageField()
    editing = n
    pageField.text = sp.map { $0.controlValue(of: n) } ?? browserControlValue(n, p.forms)
    editStartValue = pageField.text
    pageField.secure = browserControlType(n) == "password"
    pageField.visible = true
    placePageField()
    guard editing != nil else { return }
    app.ui.setFocus(pageField)
    pageField.setCursor(pageField.count)
    if let s = sp, s.focusedNode !== n { s.setFocus(n) }
}

/// Mirror a control's state from the page into the form state the engine paints.
func syncControl(_ n: HTMLNode) {
    guard let p = page, let s = scriptPage else { return }
    let id = ObjectIdentifier(n)
    if n.name == "select" {
        let opts = browserSelectOptions(n)
        if let i = opts.firstIndex(where: { s.optionSelected($0.node) }) {
            p.forms.selected[id] = i
            p.forms.values[id] = opts[i].label
        }
    } else if n.name == "input" && (browserControlType(n) == "checkbox" || browserControlType(n) == "radio") {
        p.forms.checked[id] = s.controlChecked(of: n)
    } else if n.name == "input" || n.name == "textarea" {
        let v = s.controlValue(of: n)
        p.forms.values[id] = v
        if n === editing && pageField.text != v { pageField.text = v }
    }
    p.syncForms()
    app.requestPaint()
}

pageField.onChange = { text in
    guard let n = editing, let p = page else { return }
    p.forms.values[ObjectIdentifier(n)] = text
    p.syncForms()
    if let s = sp {
        s.setUserValue(n, text)
        afterScriptInput()
    }
}
pageField.onSubmit = { _ in
    guard let n = editing else { return }
    let isTextarea = n.name == "textarea"
    commitPageField()
    if isTextarea { return }
    guard let form = browserFormOwner(n) else {
        // Enter in a field outside a form: the page's keydown handlers ran
        // already (TodoMVC adds an item); the field keeps the focus.
        if sp != nil && n.isConnected { beginEditing(n) }
        return
    }
    if let s = sp {
        // Implicit submission: click the default button, else submit.
        let queued = deferred.count
        if let btn = browserDefaultButton(form), !browserIsDisabled(btn) { s.dispatchMouse("click", at: btn) }
        else { s.bindings.submitForm(form, submitter: nil) }
        afterScriptInput()
        // A submit handler that cancelled (validation) queued no submission
        // or navigation: the field keeps the focus, as in other browsers.
        if deferred.count == queued && editing == nil && n.isConnected && (s.focusedNode === n || s.focusedNode == nil) { beginEditing(n) }
        return
    }
    submit(form, submitter: browserDefaultButton(form))
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
        say("select '" + d.options[i].label + "'")
        if let s = sp {
            s.bindings.HTMLSelectElement_set_selectedIndex(d.select, i)
            var info = JSDOMInputInfo()
            info.inputType = "insertReplacementText"
            s.dispatchInput("input", at: d.select, info)
            s.fireEvent("change", at: d.select, bubbles: true)
            syncControl(d.select)
            afterScriptInput()
        } else {
            browserSelectOption(d.select, i, p.forms)
            p.syncForms()
        }
    }
    closeDropdown()
}

/// A click on a form control in the page (scripts off).
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

// MARK: Script hooks (lib/browser calls these while a page's script runs)

func installScriptHooks() {
    var h = BrowserScriptHooks()
    h.console = { level, text in consoleAppend(level, text) }
    h.navigate = { url, replace in
        later {
            if replace, var cur = history.current { cur.url = url; cur.stateID = 0; cur.documentID = 0; history.replaceCurrent(cur) }
            navigateTo(url, push: !replace)
        }
    }
    h.followHyperlink = { _, url in later { follow(url) } }
    h.submitForm = { form, submitter in later { submit(form, submitter: submitter) } }
    h.reload = { later { reloadOrStop() } }
    h.historyPush = { id, url, replace in
        history.saveScroll(x: scrollX, y: scrollY)
        let oldFragment = history.current.flatMap { URLRecord.parseOrNil($0.url)?.fragment }
        var e = history.current ?? BrowserHistoryEntry(url: url)
        if !replace { e = BrowserHistoryEntry(url: url); e.title = page?.title ?? "" }
        e.url = url
        e.stateID = id
        e.documentID = page?.documentID ?? 0
        if replace { history.replaceCurrent(e) } else { history.push(e) }
        if app.ui.focused !== addressBar { addressBar.text = url }
        if let u = URLRecord.parseOrNil(url), let f = u.fragment, f != (oldFragment ?? []) {
            let name = String(decoding: urlPercentDecode(f), as: UTF8.self)
            later {
                if let p = page, let y = p.engine.fragmentY(name) { userScrolled = true; scrollTo(x: 0, y: Int(y)) }
                say("fragment #" + name + " y=\(scrollY)")
            }
        }
        updateButtons()
    }
    h.historyGo = { d in later { go(d) } }
    h.historyLength = { history.entries.count }
    h.getCookie = { u in String(decoding: http.cookies.documentCookie(for: u, now: Time.unixSeconds), as: UTF8.self) }
    h.setCookie = { u, s in _ = http.cookies.setCookie(Array(s.utf8), from: u, now: Time.unixSeconds, fromScript: true) }
    h.scrollPosition = { (Double(scrollX), Double(scrollY)) }
    h.scrollTo = { x, y in
        userScrolled = true
        scrollTo(x: Int(x.isFinite ? x : 0), y: Int(y.isFinite ? y : 0))
    }
    h.focusChanged = { n in
        later {
            if let n = n, browserIsTextControl(n), !browserIsDisabled(n) { beginEditing(n) }
            else if editing != nil && n !== editing { commitPageField() }
        }
    }
    h.controlChanged = { n in syncControl(n) }
    h.alert = { m in say("alert '" + m + "'"); consoleAppend(.info, "alert: " + m); setStatus("Alert: " + m) }
    h.confirm = { m in say("confirm '" + m + "'"); return false }
    h.prompt = { m, _ in say("prompt '" + m + "'"); return nil }
    h.hung = { ms in hungUI(ms) }
    h.wallClock = { Double(Time.unixSeconds) * 1000 + Double(Time.now % 1000) }
    loader.scriptHooks = h
}
installScriptHooks()

// MARK: Console panel (Ctrl-Shift-J)

var consoleLines: [(level: JSConsoleLevel, text: String)] = []

func consoleAppend(_ level: JSConsoleLevel, _ text: String) {
    for l in text.split(separator: "\n", omittingEmptySubsequences: false) {
        consoleLines.append((level: level, text: String(l)))
    }
    if consoleLines.count > 500 { consoleLines.removeFirst(consoleLines.count - 500) }
    if consoleOpen { app.requestPaint() }
}

func toggleConsole() {
    consoleOpen = !consoleOpen
    layoutWidgets()
    closeDropdown()
    loader.setViewport(width: viewRect.w, height: viewRect.h)
    afterLoaderWork()
    scrollTo(x: scrollX, y: scrollY)
    placePageField()
    if consoleOpen { app.ui.setFocus(consoleField) } else if app.ui.focused === consoleField { app.ui.setFocus(nil) }
    say("console " + (consoleOpen ? "open" : "closed"))
    app.requestPaint()
}

consoleField.onSubmit = { text in
    consoleField.text = ""
    if text.isEmpty { return }
    consoleAppend(.log, "> " + text)
    guard let s = sp else { consoleAppend(.warn, "(scripts are off for this page)"); return }
    let out = s.evaluateForConsole(text)
    consoleAppend(out.hasPrefix("Uncaught") ? .error : .log, out)
    say("console eval " + out)
    afterScriptInput()
}
consoleField.onCancel = { toggleConsole() }

func paintConsole(_ s: Surface) {
    let r = consoleRect
    s.fill(r, theme.fieldBackground)
    s.fill(Rect(0, r.y - 1, r.w, 1), theme.buttonBorder)
    let lineH = theme.font.height + 2
    let area = Rect(r.x + 4, r.y + 2, r.w - 8, r.h - 30)
    let rows = max(area.h / lineH, 1)
    let first = max(0, consoleLines.count - rows)
    var y = area.y
    s.withClip(area) {
        var i = first
        while i < consoleLines.count {
            let l = consoleLines[i]
            let col: UInt32
            switch l.level {
            case .error: col = 0xC02020
            case .warn: col = 0xA06000
            case .debug: col = 0x707070
            default: col = theme.text
            }
            _ = s.drawText(l.text, font: theme.font, at: Point(area.x, y), fg: col, bg: nil)
            y += lineH
            i += 1
        }
    }
}

// MARK: "This page's script is not responding"

var hungShown = false
var hungLastPoll = 0
var hungStopRect = Rect(0, 0, 0, 0)
var hungWaitRect = Rect(0, 0, 0, 0)
var quitAfterHang = false

func drawHungBar() {
    let s = app.window.surface
    s.setClip(nil)
    let bar = Rect(0, pageRect.y, app.window.width, 34)
    s.fill(bar, 0xFFF0B0)
    s.fill(Rect(0, bar.maxY - 1, bar.w, 1), 0xC0A040)
    _ = s.drawText("This page's script is not responding.", font: theme.font, at: Point(10, bar.y + 9), fg: 0x302000, bg: nil)
    let tx = 10 + theme.font.textWidth("This page's script is not responding.") + 20
    hungStopRect = Rect(tx, bar.y + 5, 100, 24)
    hungWaitRect = Rect(tx + 110, bar.y + 5, 60, 24)
    for (r, label) in [(hungStopRect, "Stop script"), (hungWaitRect, "Wait")] {
        s.fill(r, theme.buttonFace)
        s.frame(r, theme.buttonBorder)
        s.drawTextCentered(label, font: theme.font, in: r, fg: theme.text)
    }
    app.window.present(bar)
}

/// Called from the script's interrupt checks once its budget ran out: show
/// the bar, poll the window, and say what the user chose.
func hungUI(_ elapsed: Int) -> BrowserHungDecision {
    let now = Time.now
    if !hungShown {
        hungShown = true
        hungLastPoll = 0
        say("script not responding (\(elapsed) ms)")
        drawHungBar()
    }
    if now - hungLastPoll < 50 { return .keepRunning }
    hungLastPoll = now
    var decision = BrowserHungDecision.keepRunning
    for e in app.window.readEvents() {
        switch e {
        case .mouse(let x, let y, let b, _):
            if b & Int(WinButton.left) != 0 {
                if hungStopRect.contains(Point(x, y)) { decision = .stop }
                else if hungWaitRect.contains(Point(x, y)) { decision = .wait }
            }
        case .key(let k):
            if k.code == GUIKeyEvent.escape { decision = .stop }
            else if k.code == GUIKeyEvent.enter { decision = .wait }
        case .close:
            quitAfterHang = true
            decision = .stop
        default:
            break
        }
        if decision != .keepRunning { break }
    }
    if decision != .keepRunning {
        hungShown = false
        say(decision == .stop ? "script stop chosen" : "script wait chosen")
        app.requestPaint()
        lastButtons = 0
    }
    return decision
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
    s.fill(Rect(0, app.window.height - statusH, pr.w, 1), theme.buttonBorder)
    if consoleOpen { paintConsole(s) }
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

// MARK: DOM events for input

var pressTarget: HTMLNode? = nil
var hoverElement: HTMLNode? = nil

func elementOf(_ n: HTMLNode?) -> HTMLNode? {
    var c = n
    var k = 0
    while let x = c, x.kind != .element, k < 10_000 { c = x.parent; k += 1 }
    return c
}

func mouseInfo(_ pt: Point, buttons: Int, button: Int = 0, detail: Int = 1) -> JSDOMInputInfo {
    var i = JSDOMInputInfo()
    let v = viewRect
    i.clientX = Double(pt.x - v.x)
    i.clientY = Double(pt.y - v.y)
    i.screenX = Double(pt.x)
    i.screenY = Double(pt.y)
    i.button = button
    i.buttons = buttons & Int(WinButton.left) != 0 ? 1 : 0
    i.detail = detail
    return i
}

/// The element that takes focus for a click on `n` (nil: none).
func focusTarget(_ n: HTMLNode?) -> HTMLNode? {
    var c = n
    var k = 0
    while let x = c, k < 10_000 {
        if x.kind == .element {
            switch x.name {
            case "input", "select", "textarea", "button":
                if !browserIsDisabled(x) && browserControlType(x) != "hidden" { return x }
            case "a", "area":
                if x.hasAttribute("href") { return x }
            default:
                if x.hasAttribute("tabindex") { return x }
            }
        }
        c = x.parent
        k += 1
    }
    return nil
}

func ancestors(_ n: HTMLNode) -> [HTMLNode] {
    var out: [HTMLNode] = []
    var c: HTMLNode? = n
    while let x = c, out.count < 10_000 { out.append(x); c = x.parent }
    return out
}

func commonAncestor(_ a: HTMLNode, _ b: HTMLNode) -> HTMLNode? {
    let aa = ancestors(a)
    var c: HTMLNode? = b
    var k = 0
    while let x = c, k < 10_000 {
        if aa.contains(where: { $0 === x }) { return x.kind == .element ? x : nil }
        c = x.parent
        k += 1
    }
    return nil
}

/// mouseover/out/enter/leave when the element under the pointer changes.
func hoverChanged(_ s: JSDOMPage, to el: HTMLNode?, _ info: JSDOMInputInfo) {
    let old = hoverElement
    if old === el { return }
    hoverElement = el
    var i = info
    if let o = old, o.isConnected { i.relatedTarget = el; s.dispatchMouse("mouseout", at: o, i) }
    if let n = el { i.relatedTarget = old; s.dispatchMouse("mouseover", at: n, i) }
    let oldChain = old.map { ancestors($0) } ?? []
    let newChain = el.map { ancestors($0) } ?? []
    for o in oldChain where o.kind == .element && o.isConnected && !newChain.contains(where: { $0 === o }) {
        i.relatedTarget = el
        s.dispatchMouse("mouseleave", at: o, i)
    }
    for n in newChain.reversed() where n.kind == .element && !oldChain.contains(where: { $0 === n }) {
        i.relatedTarget = old
        s.dispatchMouse("mouseenter", at: n, i)
    }
}

/// KeyboardEvent fields for a key press.
func keyInfo(_ k: GUIKeyEvent) -> JSDOMInputInfo {
    var i = JSDOMInputInfo()
    i.ctrlKey = k.ctrl
    i.altKey = k.alt
    i.shiftKey = k.shift
    i.metaKey = k.meta
    switch k.code {
    case WinKey.up: i.key = "ArrowUp"; i.code = "ArrowUp"; i.keyCode = 38
    case WinKey.down: i.key = "ArrowDown"; i.code = "ArrowDown"; i.keyCode = 40
    case WinKey.left: i.key = "ArrowLeft"; i.code = "ArrowLeft"; i.keyCode = 37
    case WinKey.right: i.key = "ArrowRight"; i.code = "ArrowRight"; i.keyCode = 39
    case WinKey.home: i.key = "Home"; i.code = "Home"; i.keyCode = 36
    case WinKey.end: i.key = "End"; i.code = "End"; i.keyCode = 35
    case WinKey.pageUp: i.key = "PageUp"; i.code = "PageUp"; i.keyCode = 33
    case WinKey.pageDown: i.key = "PageDown"; i.code = "PageDown"; i.keyCode = 34
    case WinKey.insert: i.key = "Insert"; i.code = "Insert"; i.keyCode = 45
    case WinKey.delete, 0x7f: i.key = "Delete"; i.code = "Delete"; i.keyCode = 46
    case GUIKeyEvent.enter, 0x0a: i.key = "Enter"; i.code = "Enter"; i.keyCode = 13; i.charCode = 13
    case GUIKeyEvent.escape: i.key = "Escape"; i.code = "Escape"; i.keyCode = 27
    case GUIKeyEvent.backspace: i.key = "Backspace"; i.code = "Backspace"; i.keyCode = 8
    case GUIKeyEvent.tab: i.key = "Tab"; i.code = "Tab"; i.keyCode = 9
    case (WinKey.function + 1)...(WinKey.function + 12):
        let n = k.code - WinKey.function
        i.key = "F" + String(n); i.code = i.key; i.keyCode = 111 + n
    default:
        if k.code >= 0x20 && k.code < 0x110000, let u = Unicode.Scalar(UInt32(k.code)) {
            var s = ""
            s.unicodeScalars.append(u)
            i.key = s
            i.charCode = k.code
            if k.code >= 0x61 && k.code <= 0x7a { i.keyCode = k.code - 32; i.code = "Key" + String(Unicode.Scalar(UInt8(k.code - 32))) }
            else if k.code >= 0x41 && k.code <= 0x5a { i.keyCode = k.code; i.code = "Key" + s }
            else if k.code >= 0x30 && k.code <= 0x39 { i.keyCode = k.code; i.code = "Digit" + s }
            else if k.code == 0x20 { i.keyCode = 32; i.code = "Space" }
            else { i.keyCode = k.code < 0x80 ? k.code : 0 }
        } else {
            i.key = "Unidentified"
        }
    }
    return i
}

/// keydown (and keypress) at the focused element: true if canceled.
func dispatchKeyDown(_ k: GUIKeyEvent) -> Bool {
    guard let s = sp else { return false }
    let info = keyInfo(k)
    var canceled = s.dispatchKey("keydown", info)
    if !canceled && (info.charCode != 0) && !k.ctrl && !k.alt { canceled = s.dispatchKey("keypress", info) }
    later {
        if let s2 = sp { s2.dispatchKey("keyup", info); afterScriptInput() }
    }
    afterScriptInput()
    return canceled
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
    if dispatchKeyDown(k) { return true }
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
    default: return sp != nil
    }
    return true
}

func globalKey(_ k: GUIKeyEvent) -> Bool {
    if k.ctrl && k.shift && (k.code == 0x0a || k.code == 0x4a || k.code == 0x6a) { // Ctrl-Shift-J
        toggleConsole()
        return true
    }
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
    let left = Int(WinButton.left)
    let pressed = buttons & left != 0 && lastButtons & left == 0
    let released = buttons & left == 0 && lastButtons & left != 0
    lastButtons = buttons
    if wheel != 0 {
        if let d = dropdown, d.rect.contains(pt) {
            dropdown?.hover = max(0, min(d.hover - wheel, d.options.count - 1))
            app.requestPaint()
        } else {
            if let s = sp, let p = page, viewRect.contains(pt) {
                let v = viewRect
                let hit = p.engine.hitTest(x: Double(pt.x - v.x), y: Double(pt.y - v.y), scrollX: Double(scrollX), scrollY: Double(scrollY))
                if let n = elementOf(hit.node) {
                    var info = mouseInfo(pt, buttons: buttons)
                    info.deltaY = Double(-wheel * 60)
                    let canceled = s.dispatch(event: "wheel", kind: .wheel, to: n, info)
                    afterScriptInput()
                    if canceled { return true }
                }
            }
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
    if consoleOpen && consoleRect.contains(pt) { return false }
    let v = viewRect
    guard pageRect.contains(pt) else {
        if hoverHref != nil { hoverHref = nil; refreshStatus() }
        if released { pressTarget = nil }
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
    if let s = sp {
        // Scripts on: DOM events first, then the defaults the page doesn't do.
        let target = elementOf(hit.node) ?? p.document.body ?? p.document
        if pressed {
            if app.ui.focused === addressBar { addressBar.text = p.displayURL }
            if app.ui.focused !== pageField { app.ui.setFocus(nil) }
            let info = mouseInfo(pt, buttons: buttons)
            let c1 = s.dispatchMouse("pointerdown", at: target, info)
            let c2 = s.dispatchMouse("mousedown", at: target, info)
            pressTarget = target
            if !c1 && !c2 {
                let f = focusTarget(target)
                if editing != nil && f !== editing { commitPageField() }
                s.setFocus(f)
            }
            afterScriptInput()
            return true
        }
        if released {
            let info = mouseInfo(pt, buttons: buttons)
            s.dispatchMouse("pointerup", at: target, info)
            s.dispatchMouse("mouseup", at: target, info)
            if let pt0 = pressTarget, let ct = commonAncestor(pt0, target) {
                let canceled = s.dispatchMouse("click", at: ct, info)
                if !canceled, let c = hit.control, browserControlType(c) == "select", !browserIsDisabled(c) { openDropdown(c) }
            }
            pressTarget = nil
            afterScriptInput()
            return true
        }
        if buttons == 0 {
            hoverChanged(s, to: target, mouseInfo(pt, buttons: 0, detail: 0))
            s.dispatchMouse("mousemove", at: target, mouseInfo(pt, buttons: 0, detail: 0))
            afterScriptInput()
        }
    } else if pressed {
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
        if let f = app.ui.focused, f === addressBar || f === consoleField { return false }
        if let f = app.ui.focused, f === pageField {
            // The page sees the key first (keydown can cancel the edit).
            return dispatchKeyDown(k)
        }
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
    if !deferred.isEmpty || scrollEventPending { return 0 }
    var best = loader.timeout(now: Time.now)
    if let h = hoverAt { let d = max(0, h - Time.now); best = best.map { min($0, d) } ?? d }
    return best
}

app.onIdle = {
    let now = Time.now
    runDeferred()
    if scrollEventPending {
        scrollEventPending = false
        if let s = sp { s.scrolled(); afterScriptInput() }
    }
    loader.pump(now: now)
    afterLoaderWork()
    runDeferred()
    applyHover()
    if quitAfterHang { app.quit() }
}

app.dynamicWaits = {
    var out: [WaitFD] = []
    for t in loader.transports { for d in t.waitDescriptors() { out.append(WaitFD(fd: Int32(d.fd), events: d.events, revents: 0)) } }
    return out
}
app.onDynamicReady = { _ in } // onIdle pumps every transport after each wait

say("ready \(app.window.width)x\(app.window.height)" + (jsEnabled ? "" : " (no JavaScript)"))
navigateTo(startURL ?? browserHomeURL)
updateButtons()
let code = app.run()
for t in loader.transports { t.shutdown() }
say("exit")
Process.exit(code)
