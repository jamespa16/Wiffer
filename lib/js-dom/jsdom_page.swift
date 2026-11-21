// JSDOMPage: one document's script environment (ROADMAP Phase 9G), and
// JSDOMHost: everything browser-specific, as closures lib/browser fills in
// (Phase 9H). OS-free: the host tests drive a page with the defaults.
//
//     var host = JSDOMHost()
//     host.now = { clock.ms }                         // monotonic ms
//     host.console = { level, text in ... }
//     host.layout = { [unowned tab] in tab.engine }   // forced layout
//     host.navigate = { url, replace in ... }         // location = ...
//     let page = JSDOMPage(document: doc, url: "https://example.com/", host: host)
//     page.runScript(source, name: "https://example.com/app.js", element: scriptNode)
//     page.finishParsing()        // readyState interactive, DOMContentLoaded
//     page.finishLoading()        // readyState complete, load
//     ... each App.run wake-up:
//     page.loop.runDueTasks(); if let ms = page.loop.nextDeadline() { ... }
//     ... input: page.dispatchMouse("click", at: node, ...) -> canceled?
//     page.tearDown()             // on navigation (or let it deinit)
//
// The page owns the JSRuntime, realm, event loop, console and bindings
// for one document: a new page per navigation (one realm per document).
// It registers one lib/html mutation observer on the document; the
// browser's LayoutEngine keeps its own.

/// Browser hooks. Every member has a harmless default, so a page works
/// stand-alone (host tests, /bin/js-style tools).
public struct JSDOMHost {
    // Time
    /// Monotonic milliseconds: timers, performance.now(), event timeStamps.
    public var now: () -> Double = { 0 }
    /// Wall-clock milliseconds since 1970 (Date.now(), performance.timeOrigin).
    public var wallClock: () -> Double = { 0 }

    // Output
    /// console.* output (already formatted like other browsers).
    public var console: (JSConsoleLevel, String) -> Void = { _, _ in }
    /// An uncaught exception in a script or callback: (message, stack).
    /// The page also fires `error` at the window first.
    public var reportError: (String, String) -> Void = { _, _ in }
    /// A script was stopped (time budget or heap cap).
    public var reportTermination: (JSTerminationReason) -> Void = { _ in }
    /// The time budget: called before every task/callback (reset a deadline).
    public var beginTask: () -> Void = {}

    // Navigation and history
    /// Navigate the tab: location.href/assign (replace false), location.replace
    /// (true), link activation, window.open in the same tab. Fragment-only
    /// changes never come here (see historyPush).
    public var navigate: (_ url: String, _ replace: Bool) -> Void = { _, _ in }
    public var reload: () -> Void = {}
    /// A same-document history entry: pushState / replaceState / fragment
    /// navigation. `id` names the entry's state; when the user goes back or
    /// forward to it, call JSDOMPage.popState(id:url:). The browser should
    /// show `url` and, for fragment changes, scroll to the fragment.
    public var historyPush: (_ id: Int, _ url: String, _ replace: Bool) -> Void = { _, _, _ in }
    /// history.back/forward/go(delta).
    public var historyGo: (_ delta: Int) -> Void = { _ in }
    public var historyLength: () -> Int = { 1 }
    /// A link was activated (click on <a>/<area> not canceled): url is
    /// resolved; target is the target attribute ("" for the same tab).
    public var followHyperlink: (_ link: HTMLNode, _ url: String, _ target: String) -> Void = { _, _, _ in }
    /// A form is submitted (submit event not canceled, or form.submit()).
    /// The browser builds the form data set from the DOM and
    /// JSDOMPage.controlValue(of:) / controlChecked(of:).
    public var submitForm: (_ form: HTMLNode, _ submitter: HTMLNode?) -> Void = { _, _ in }
    /// window.open(url, target) to another tab/window.
    public var openWindow: (_ url: String, _ target: String) -> Void = { _, _ in }
    public var referrer = ""

    // Cookies and storage
    /// document.cookie (HttpOnly cookies hidden).
    public var getCookie: () -> String = { "" }
    public var setCookie: (String) -> Void = { _ in }
    /// localStorage changed: persist the items if wanted.
    public var storageChanged: ([(String, String)]) -> Void = { _ in }

    // Viewport, scrolling, layout
    /// The viewport in CSS px (innerWidth/Height, matchMedia).
    public var viewport: () -> (Int, Int) = { (1024, 768) }
    public var screenSize: () -> (Int, Int) = { (1024, 768) }
    public var devicePixelRatio = 1.0
    public var darkColorScheme = false
    public var scrollPosition: () -> (Double, Double) = { (0, 0) }
    public var scrollTo: (_ x: Double, _ y: Double) -> Void = { _, _ in }
    /// The tab's layout engine for forced layout (getBoundingClientRect,
    /// offset*, getComputedStyle, elementFromPoint); nil: no layout (all
    /// metrics 0, getComputedStyle empty).
    var layout: () -> LayoutEngine? = { nil }
    /// Natural size of a loaded image by absolute URL (img.naturalWidth).
    public var imageSize: (String) -> (Int, Int)? = { _ in nil }
    /// True while an image is still being fetched (img.complete).
    public var imagePending: (String) -> Bool = { _ in false }
    /// requestAnimationFrame was called: schedule a rendering step, then
    /// call JSDOMPage.runAnimationFrames(now:) before painting.
    public var requestAnimationFrame: () -> Void = {}

    // UI
    public var alert: (String) -> Void = { _ in }
    public var confirm: (String) -> Bool = { _ in false }
    public var prompt: (_ message: String, _ default: String) -> String? = { _, _ in nil }
    /// Focus moved (element.focus(), blur(), label clicks); nil = none.
    public var focusChanged: (HTMLNode?) -> Void = { _ in }
    public var hasFocus: () -> Bool = { true }
    /// A form control's value/checkedness changed by script: repaint it.
    public var controlChanged: (HTMLNode) -> Void = { _ in }

    // Navigator
    public var userAgent = "Mozilla/5.0 (Wiffer; x86_64) WifferBrowse/0.9"
    public var languages = ["en-US", "en"]
    public var onLine = true

    public init() {}
}

/// Which event interface JSDOMPage.dispatch(event:kind:to:) creates.
public enum JSDOMEventKind {
    case event, mouse, pointer, wheel, keyboard, input, focus
}

/// Event fields for JSDOMPage's input entry points.
public struct JSDOMInputInfo {
    public var clientX = 0.0, clientY = 0.0, screenX = 0.0, screenY = 0.0
    public var offsetX = 0.0, offsetY = 0.0
    public var button = 0, buttons = 0, detail = 0
    public var ctrlKey = false, shiftKey = false, altKey = false, metaKey = false
    public var key = "", code = "", keyCode = 0, charCode = 0, repeatKey = false
    public var data: String? = nil
    public var inputType = ""
    public var deltaX = 0.0, deltaY = 0.0
    public var relatedTarget: HTMLNode? = nil
    public init() {}
}

public final class JSDOMPage {
    public let runtime: JSRuntime
    public let realm: JSRealm
    public let document: HTMLNode
    let bindings: JSDOMBindings
    public var loop: JSEventLoop { bindings.loop }
    var observerID = 0
    var tornDown = false

    /// Build the realm for `document` (already parsed) at `url`.
    public init(document: HTMLNode, url: String, host: JSDOMHost, limits: JSLimits = JSLimits()) {
        self.document = document
        runtime = JSRuntime(limits: limits)
        realm = runtime.makeRealm()
        let h = host
        realm.nowMs = { h.wallClock() }
        bindings = JSDOMBindings(realm: realm, document: document, host: host)
        bindings.url = URLRecord.parseOrNil(url)
        bindings.timeOrigin = host.now()
        bindings.loop = JSEventLoop(realm: realm, clock: { h.now() })
        bindings.loop.beginTask = { h.beginTask() }
        unowned(unsafe) let b = bindings
        bindings.loop.reportException = { e in b.reportUncaught(e) }
        bindings.loop.reportTermination = { why in h.reportTermination(why) }
        bindings.loop.reportRejection = { text in h.console(.error, text); h.reportError(text, "") }
        bindings.console = jsInstallConsole(realm, now: { h.now() }) { level, text in h.console(level, text) }
        bindings.install()
        observerID = document.addMutationObserver { m in b.domMutated(m) }
    }

    deinit { tearDown() }

    /// Stop the page: drop timers and observers, release the realm's hold
    /// on the DOM. Safe to call twice.
    public func tearDown() {
        if tornDown { return }
        tornDown = true
        document.removeMutationObserver(observerID)
        for (d, id) in bindings.hookedDocuments { d.removeMutationObserver(id) }
        bindings.hookedDocuments = []
        bindings.loop.clearAll()
        heapRelease()
    }

    func heapRelease() {
        bindings.rafCallbacks = []
        bindings.idleCallbacks = []
        bindings.observers = []
        bindings.nodeListeners = [:]
        bindings.handlers = [:]
        bindings.controls = [:]
        bindings.attrCache = [:]
        bindings.extraDocuments = []
        bindings.sheets.release()
        bindings.nodeIterators = []
        bindings.namedIndex = nil
        bindings.ce.release()
        bindings.heap.removeRootProvider(bindings.rootProviderID)
    }

    // MARK: Scripts

    /// Run a classic script as a task (exceptions reported, microtask
    /// checkpoint after). `element` becomes document.currentScript and the
    /// insertion point for document.write.
    @discardableResult
    public func runScript(_ source: String, name: String = "<script>", element: HTMLNode? = nil) -> JSCompletion {
        runScript(bytes: Array(source.utf8), name: name, element: element)
    }

    @discardableResult
    public func runScript(bytes: [UInt8], name: String = "<script>", element: HTMLNode? = nil) -> JSCompletion {
        let b = bindings
        let savedScript = b.currentScript
        let savedWrite = b.writeTarget
        b.currentScript = element
        b.writeTarget = nil
        b.host.beginTask()
        let c = realm.evaluate(source: bytes, name: name)
        switch c {
        case .normal: break
        case .exception(let e): b.reportUncaught(e)
        case .terminated(let why): b.host.reportTermination(why)
        }
        b.currentScript = savedScript
        b.writeTarget = savedWrite
        loop.performMicrotaskCheckpoint()
        return c
    }

    /// Evaluate for the console window: the completion value inspected
    /// like console.log does, or the error text.
    public func evaluateForConsole(_ source: String) -> String {
        bindings.host.beginTask()
        let c = realm.evaluate(source: source, name: "console")
        var out: String
        switch c {
        case .normal(let v):
            let d = realm.heap.rootDepth
            _ = realm.heap.root(v)
            out = jsInspect(realm, v)
            realm.heap.popRoots(to: d)
        case .exception(let e): out = "Uncaught " + e.message
        case .terminated: out = "(script terminated)"
        }
        loop.performMicrotaskCheckpoint()
        return out
    }

    // MARK: Document lifecycle

    /// After the parse and the deferred scripts: readyState "interactive",
    /// then DOMContentLoaded at the document (bubbling to the window).
    public func finishParsing() {
        upgradeParsedElements()
        setReadyState("interactive")
        bindings.fire("DOMContentLoaded", at: .node(document), bubbles: true)
        loop.performMicrotaskCheckpoint()
    }

    /// Subresources done: readyState "complete", then `load` at the window
    /// (target document, not bubbling through it) and pageshow.
    public func finishLoading() {
        setReadyState("complete")
        bindings.fire("load", at: .window)
        bindings.fire("pageshow", at: .window)
        loop.performMicrotaskCheckpoint()
    }

    public func setReadyState(_ s: String) {
        if bindings.readyState == s { return }
        bindings.readyState = s
        bindings.fire("readystatechange", at: .node(document))
    }

    public var readyState: String { bindings.readyState }

    /// Fire `load` (or `error`) at an element (img, script, link, style).
    public func fireElementEvent(_ type: String, at node: HTMLNode) {
        bindings.fire(type, at: .node(node))
        loop.performMicrotaskCheckpoint()
    }

    // MARK: Input (dispatch, then do the default action unless canceled)

    /// A mouse/pointer event at `node` (the hit-tested node; it is
    /// retargeted as the event travels). Returns true if canceled
    /// (preventDefault). For "click" the activation behavior (links via
    /// host.followHyperlink, checkboxes, submit buttons, labels) already ran.
    @discardableResult
    public func dispatchMouse(_ type: String, at node: HTMLNode, _ info: JSDOMInputInfo = JSDOMInputInfo()) -> Bool {
        let iface: JSDOMInterface
        switch type {
        case "wheel": iface = .WheelEvent
        case "pointerdown", "pointerup", "pointermove", "pointerover", "pointerout", "pointerenter", "pointerleave",
             "pointercancel": iface = .PointerEvent
        case "click", "auxclick", "contextmenu": iface = .PointerEvent
        default: iface = .MouseEvent
        }
        let e = JSDOMEvent(iface, type: type, time: bindings.now())
        let noBubble = type == "mouseenter" || type == "mouseleave" || type == "pointerenter" || type == "pointerleave"
        e.bubbles = !noBubble
        e.cancelable = !noBubble && type != "pointerenter"
        e.composed = true
        e.isTrusted = true
        e.viewIsWindow = true
        e.clientX = info.clientX; e.clientY = info.clientY; e.screenX = info.screenX; e.screenY = info.screenY
        e.offsetX = info.offsetX; e.offsetY = info.offsetY
        e.button = info.button; e.buttons = info.buttons; e.detail = info.detail
        e.ctrlKey = info.ctrlKey; e.shiftKey = info.shiftKey; e.altKey = info.altKey; e.metaKey = info.metaKey
        e.deltaX = info.deltaX; e.deltaY = info.deltaY
        e.relatedTarget = info.relatedTarget.map { .node($0) }
        if iface == .PointerEvent { e.pointerType = "mouse"; e.isPrimary = true; e.pointerId = 1 }
        return dispatch(e, to: node)
    }

    /// The general form: an event of `kind` at `node` (nil: the window).
    /// Returns true if the default action was prevented. Dispatch, then
    /// do the default action unless this returns true.
    @discardableResult
    public func dispatch(event type: String, kind: JSDOMEventKind, to node: HTMLNode?, bubbles: Bool = true,
                         cancelable: Bool = true, _ info: JSDOMInputInfo = JSDOMInputInfo()) -> Bool {
        let iface: JSDOMInterface
        switch kind {
        case .event: iface = .Event
        case .mouse: iface = .MouseEvent
        case .pointer: iface = .PointerEvent
        case .wheel: iface = .WheelEvent
        case .keyboard: iface = .KeyboardEvent
        case .input: iface = .InputEvent
        case .focus: iface = .FocusEvent
        }
        let e = JSDOMEvent(iface, type: type, time: bindings.now())
        e.bubbles = bubbles
        e.cancelable = cancelable
        e.composed = kind != .event
        e.isTrusted = true
        e.viewIsWindow = kind != .event
        e.clientX = info.clientX; e.clientY = info.clientY; e.screenX = info.screenX; e.screenY = info.screenY
        e.offsetX = info.offsetX; e.offsetY = info.offsetY
        e.button = info.button; e.buttons = info.buttons; e.detail = info.detail
        e.ctrlKey = info.ctrlKey; e.shiftKey = info.shiftKey; e.altKey = info.altKey; e.metaKey = info.metaKey
        e.key = info.key; e.code = info.code; e.keyCode = info.keyCode; e.charCode = info.charCode; e.repeatKey = info.repeatKey
        e.data = info.data; e.inputType = info.inputType
        e.deltaX = info.deltaX; e.deltaY = info.deltaY
        e.relatedTarget = info.relatedTarget.map { .node($0) }
        if kind == .pointer { e.pointerType = "mouse"; e.isPrimary = true; e.pointerId = 1 }
        guard let n = node else {
            let canceled = (try? bindings.dispatch(e, to: .window)) ?? false
            loop.performMicrotaskCheckpoint()
            return canceled
        }
        return dispatch(e, to: n)
    }

    /// keydown / keyup / keypress at the focused element (or body).
    @discardableResult
    public func dispatchKey(_ type: String, _ info: JSDOMInputInfo) -> Bool {
        let e = JSDOMEvent(.KeyboardEvent, type: type, time: bindings.now())
        e.bubbles = true
        e.cancelable = true
        e.composed = true
        e.isTrusted = true
        e.viewIsWindow = true
        e.key = info.key; e.code = info.code; e.keyCode = info.keyCode; e.charCode = info.charCode
        e.repeatKey = info.repeatKey
        e.ctrlKey = info.ctrlKey; e.shiftKey = info.shiftKey; e.altKey = info.altKey; e.metaKey = info.metaKey
        let target = bindings.focused.flatMap { $0.isConnected ? $0 : nil } ?? document.body ?? document
        return dispatch(e, to: target)
    }

    /// beforeinput (cancelable) / input (not) at a control.
    @discardableResult
    public func dispatchInput(_ type: String, at node: HTMLNode, _ info: JSDOMInputInfo) -> Bool {
        let e = JSDOMEvent(.InputEvent, type: type, time: bindings.now())
        e.bubbles = true
        e.cancelable = type == "beforeinput"
        e.composed = true
        e.isTrusted = true
        e.viewIsWindow = true
        e.data = info.data
        e.inputType = info.inputType
        return dispatch(e, to: node)
    }

    /// A simple trusted event (change, submit, scroll, resize, ...).
    @discardableResult
    public func fireEvent(_ type: String, at node: HTMLNode?, bubbles: Bool = false, cancelable: Bool = false) -> Bool {
        let canceled = bindings.fire(type, at: node.map { .node($0) } ?? .window, bubbles: bubbles, cancelable: cancelable)
        loop.performMicrotaskCheckpoint()
        return canceled
    }

    func dispatch(_ e: JSDOMEvent, to node: HTMLNode) -> Bool {
        let canceled = (try? bindings.dispatch(e, to: .node(node))) ?? false
        loop.performMicrotaskCheckpoint()
        return canceled
    }

    // MARK: Focus and form controls

    /// The browser moved focus (click on a focusable element, Tab):
    /// fires blur/focusout and focus/focusin.
    public func setFocus(_ node: HTMLNode?) {
        bindings.setFocus(node)
        loop.performMicrotaskCheckpoint()
    }
    public var focusedNode: HTMLNode? { bindings.focused }

    /// The value a control shows (input value, textarea value, select value).
    public func controlValue(of n: HTMLNode) -> String {
        if n.isHTML("textarea") { return bindings.HTMLTextAreaElement_value(n) }
        if n.isHTML("select") { return bindings.HTMLSelectElement_value(n) }
        return bindings.inputValue(n)
    }
    public func controlChecked(of n: HTMLNode) -> Bool { bindings.inputChecked(n) }
    public func optionSelected(_ n: HTMLNode) -> Bool { bindings.optionSelected(n) }

    /// The user edited a control: set its dirty value and fire `input`
    /// (and `change` when `commit`).
    public func setUserValue(_ n: HTMLNode, _ v: String, commit: Bool = false) {
        if n.isHTML("textarea") { bindings.HTMLTextAreaElement_set_value(n, v) }
        else if n.isHTML("select") { bindings.HTMLSelectElement_set_value(n, v) }
        else { try? bindings.HTMLInputElement_set_value(n, v) }
        var info = JSDOMInputInfo()
        info.inputType = "insertText"
        dispatchInput("input", at: n, info)
        if commit { fireEvent("change", at: n, bubbles: true) }
    }

    // MARK: Rendering, viewport, history

    public var hasAnimationFrameCallbacks: Bool { !bindings.rafCallbacks.isEmpty }

    /// Run the requestAnimationFrame callbacks (before restyle/paint).
    public func runAnimationFrames(now: Double) {
        bindings.runAnimationFrames(now - bindings.timeOrigin)
    }

    /// The viewport changed size: matchMedia lists re-evaluate (change
    /// events), then `resize` fires at the window.
    public func viewportChanged() {
        bindings.evaluateMediaQueries()
        bindings.fire("resize", at: .window)
        loop.performMicrotaskCheckpoint()
    }

    /// The page scrolled (by the user): `scroll` at the document.
    public func scrolled() {
        bindings.fire("scroll", at: .node(document), bubbles: true)
        loop.performMicrotaskCheckpoint()
    }

    /// The browser went back/forward to a same-document entry `id`.
    public func popState(id: Int, url: String) {
        bindings.popState(id: id, url: url)
        loop.performMicrotaskCheckpoint()
    }

    /// The document URL as scripts see it (location.href).
    public var url: String { bindings.url?.href ?? "about:blank" }

    /// Custom elements the parser inserted after their definition (the
    /// parser does not notify, and scripts run between parse chunks):
    /// upgrade them in tree order, as connecting them would. finishParsing
    /// calls this; a browser that parses in chunks may call it after each.
    public func upgradeParsedElements() {
        if bindings.ce.definitions.isEmpty { return }
        _ = try? bindings.ceReactions { () throws(JSThrow) -> JSValue in
            self.bindings.document.walkShadowIncluding { n in
                if n.kind == .element { self.bindings.ceTryUpgrade(n) }
                return true
            }
            return .undefined
        }
        loop.performMicrotaskCheckpoint()
    }

    /// Hand every adoptedStyleSheets list to host.layout() again (call
    /// after making a new LayoutEngine for this document).
    public func syncAdoptedStyleSheets() { bindings.syncAllAdopted() }

    /// Wrappers alive (diagnostics, tests).
    var wrapperCount: Int { bindings.nodeClass.liveCount }
}
