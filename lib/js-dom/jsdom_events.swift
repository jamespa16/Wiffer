// Events (DOM Standard "Events", HTML "Event handlers"): Event objects,
// listeners, the dispatch algorithm with capture/target/bubble along the
// composed path (shadow-boundary retargeting through lib/html's
// retargeted(against:)), activation behavior, and on<event> handlers
// compiled lazily from content attributes.
//
// Swift entry point for the browser (via JSDOMPage.dispatch):
//     let canceled = b.dispatch(event, to: .node(n))   // true: default prevented
// For click events the DOM's activation behavior (checkbox/radio toggle,
// label -> control, submit/reset buttons, links) runs inside dispatch, as
// in browsers; links and form submission reach the browser through
// JSDOMHost.followHyperlink / submitForm.

final class JSDOMEvent {
    var iface: JSDOMInterface
    var type: String
    var bubbles = false
    var cancelable = false
    var composed = false
    var isTrusted = false
    var timeStamp: Double
    var target: JSDOMTarget? = nil
    var relatedTarget: JSDOMTarget? = nil
    var currentTarget: JSDOMTarget? = nil
    var eventPhase = 0
    var stopPropagationFlag = false
    var stopImmediateFlag = false
    var canceledFlag = false
    var inPassiveListener = false
    var initialized = true
    var dispatchFlag = false
    var path: [JSDOMPathEntry] = []
    // UIEvent
    var viewIsWindow = false
    var detail = 0
    var which = 0
    // MouseEvent / PointerEvent / WheelEvent
    var screenX = 0.0, screenY = 0.0, clientX = 0.0, clientY = 0.0
    var offsetX = 0.0, offsetY = 0.0
    var ctrlKey = false, shiftKey = false, altKey = false, metaKey = false
    var button = 0, buttons = 0
    var pointerId = 0, width = 1.0, height = 1.0, pressure = 0.0, pointerType = "", isPrimary = false
    var deltaX = 0.0, deltaY = 0.0, deltaZ = 0.0, deltaMode = 0
    // KeyboardEvent / InputEvent
    var key = "", code = "", location = 0, repeatKey = false, isComposing = false, charCode = 0, keyCode = 0
    var data: String? = nil
    var inputType = ""
    // SubmitEvent
    var submitter: HTMLNode? = nil
    // HashChangeEvent, ErrorEvent, MediaQueryListEvent
    var oldURL = "", newURL = ""
    var message = "", filename = "", lineno = 0, colno = 0
    var media = "", matches = false

    init(_ iface: JSDOMInterface, type: String, time: Double) {
        self.iface = iface
        self.type = type
        self.timeStamp = time
    }
}

struct JSDOMPathEntry {
    var invocationTarget: JSDOMTarget
    var inShadowTree: Bool
    var shadowAdjustedTarget: JSDOMTarget?
    var relatedTarget: JSDOMTarget?
    var rootOfClosedTree: Bool
    var slotInClosedTree: Bool
}

final class JSDOMListener {
    let type: String
    var callback: JSValue
    let capture: Bool
    var passive: Bool
    let once: Bool
    var removed = false
    /// An event handler's listener (calls the handler's current value).
    let handlerKey: JSDOMHandlerKey?
    init(type: String, callback: JSValue, capture: Bool, passive: Bool, once: Bool, handlerKey: JSDOMHandlerKey? = nil) {
        self.type = type
        self.callback = callback
        self.capture = capture
        self.passive = passive
        self.once = once
        self.handlerKey = handlerKey
    }
}

final class JSDOMListenerList {
    var items: [JSDOMListener] = []
    init() {}
    func mark(_ h: JSHeap) { for l in items { h.markValue(l.callback) } }
}

struct JSDOMHandlerKey: Hashable {
    let target: Int
    let name: String
}

final class JSDOMHandler {
    /// The compiled function, or null.
    var value: JSValue = .null
    /// Uncompiled content-attribute source (compiled on first use).
    var source: String? = nil
    var listener: JSDOMListener? = nil
    init() {}
}

/// Mutable control state the DOM owns (value, checkedness, dirtiness).
final class JSDOMControlState {
    var value: String? = nil      // nil: not dirty (the default applies)
    var checked: Bool? = nil
    var selected: Bool? = nil
    var indeterminate = false
    var customValidity = ""
    var selectionStart = 0
    var selectionEnd = 0
    init() {}
}

/// Body element handlers that live on the window.
func jsdomForwardsToWindow(_ name: String) -> Bool {
    switch name {
    case "blur", "error", "focus", "load", "resize", "scroll",
         "afterprint", "beforeprint", "beforeunload", "hashchange", "languagechange", "message", "offline",
         "online", "pagehide", "pageshow", "popstate", "rejectionhandled", "storage", "unhandledrejection", "unload":
        return true
    default: return false
    }
}

extension JSDOMBindings {
    // MARK: Listener lists

    func listeners(_ t: JSDOMTarget, create: Bool) -> JSDOMListenerList? {
        switch t {
        case .window: return windowListeners
        case .object(let o):
            if create && o.listeners.items.isEmpty && !listenerTargets.contains(where: { $0 === o }) { listenerTargets.append(o) }
            return o.listeners
        case .node(let n):
            let k = ObjectIdentifier(n)
            if let l = nodeListeners[k] { return l }
            if !create { return nil }
            let l = JSDOMListenerList()
            nodeListeners[k] = l
            return l
        }
    }

    func targetID(_ t: JSDOMTarget) -> Int {
        switch t {
        case .window: return 0
        case .node(let n): return Int(bitPattern: UInt(bitPattern: ObjectIdentifier(n)))
        case .object(let o): return Int(bitPattern: UInt(bitPattern: ObjectIdentifier(o)))
        }
    }

    func addListener(_ t: JSDOMTarget, _ l: JSDOMListener, signal: JSDOMEventTargetObject? = nil) {
        if case .node(let n) = t { scanContentHandlers(n) }
        guard let list = listeners(t, create: true) else { return }
        if l.handlerKey == nil {
            for e in list.items where !e.removed && e.handlerKey == nil && e.type == l.type && e.capture == l.capture
                && e.callback == l.callback { return }
        }
        list.items.append(l)
        if let s = signal {
            s.abortAlgorithms.append { [unowned(unsafe) self] in self.removeListener(t, l) }
        }
    }

    func removeListener(_ t: JSDOMTarget, _ l: JSDOMListener) {
        guard let list = listeners(t, create: false) else { return }
        l.removed = true
        list.items.removeAll { $0 === l }
    }

    // MARK: EventTarget

    func EventTarget_constructor(newTarget: JSValue) throws(JSThrow) -> JSValue {
        let o = JSDOMEventTargetObject(.EventTarget)
        let w = classes.EventTargetObject.wrap(o)
        try adoptNewTarget(w, newTarget, .EventTarget)
        return w
    }

    func EventTarget_addEventListener(_ this: JSDOMTarget, _ type: String, _ callback: JSValue, _ options: JSValue) throws(JSThrow) {
        var capture = false
        var once = false
        var passive: Bool? = nil
        var signal: JSDOMEventTargetObject? = nil
        if options.isObject {
            let d = try dict_AddEventListenerOptions(options)
            capture = d.capture
            once = d.once
            passive = d.passive
            signal = d.signal
        } else if !options.isUndefined {
            capture = heap.toBoolean(options)
        }
        if let s = signal, s.aborted { return }
        if callback.isNullish { return }
        // passive defaults to true for touch/wheel listeners on the window, document and its root.
        if passive == nil, type == "touchstart" || type == "touchmove" || type == "wheel" || type == "mousewheel" {
            switch this {
            case .window: passive = true
            case .node(let n): passive = n === document || n === document.documentElement || n === document.body
            default: break
            }
        }
        addListener(this, JSDOMListener(type: type, callback: callback, capture: capture, passive: passive ?? false, once: once), signal: signal)
    }

    func EventTarget_removeEventListener(_ this: JSDOMTarget, _ type: String, _ callback: JSValue, _ options: JSValue) throws(JSThrow) {
        var capture = false
        if options.isObject {
            capture = heap.toBoolean(try realm.getV(options, heap.key("capture")))
        } else if !options.isUndefined {
            capture = heap.toBoolean(options)
        }
        guard let list = listeners(this, create: false) else { return }
        for l in list.items where l.handlerKey == nil && l.type == type && l.capture == capture && l.callback == callback {
            removeListener(this, l)
            return
        }
    }

    func EventTarget_dispatchEvent(_ this: JSDOMTarget, _ e: JSDOMEvent) throws(JSThrow) -> Bool {
        if e.dispatchFlag || !e.initialized { throw throwDOM("InvalidStateError", "The event is already being dispatched or was not initialized.") }
        e.isTrusted = false
        return !(try dispatch(e, to: this))
    }

    // MARK: Dispatch

    /// The parent in the event path ("get the parent").
    func eventParent(_ t: JSDOMTarget, _ e: JSDOMEvent) -> JSDOMTarget? {
        switch t {
        case .window, .object: return nil
        case .node(let n):
            if n.kind == .document {
                return e.type == "load" || n !== document ? nil : .window
            }
            if n.isShadowRoot {
                if !e.composed, let first = e.path.first, case .node(let f) = first.invocationTarget, f.rootNode === n { return nil }
                return n.host.map { .node($0) }
            }
            if n.isSlottable, let s = n.assignedSlotIncludingClosed { return .node(s) }
            return n.parent.map { .node($0) }
        }
    }

    /// Retarget A against B (DOM "retarget").
    func retarget(_ a: JSDOMTarget?, against b: JSDOMTarget) -> JSDOMTarget? {
        guard let a = a else { return nil }
        guard case .node(let an) = a else { return a }
        switch b {
        case .node(let bn): return .node(an.retargeted(against: bn))
        default:
            // Against the window: retarget out of every shadow tree.
            var x = an
            var k = 0
            while x.rootNode.isShadowRoot, let h = x.rootNode.host, k < 4096 { x = h; k += 1 }
            return .node(x)
        }
    }

    func inShadowTree(_ t: JSDOMTarget) -> Bool {
        if case .node(let n) = t { return n.rootNode.isShadowRoot }
        return false
    }

    func appendToPath(_ e: JSDOMEvent, _ target: JSDOMTarget, _ adjusted: JSDOMTarget?, _ related: JSDOMTarget?, slotInClosed: Bool) {
        var closed = false
        if case .node(let n) = target, n.isShadowRoot, n.shadowRootMode == .closed { closed = true }
        e.path.append(JSDOMPathEntry(invocationTarget: target, inShadowTree: inShadowTree(target), shadowAdjustedTarget: adjusted,
                                     relatedTarget: related, rootOfClosedTree: closed, slotInClosedTree: slotInClosed))
    }

    func hasActivationBehavior(_ t: JSDOMTarget) -> Bool {
        guard case .node(let n) = t, n.kind == .element, n.namespace == .html else { return false }
        switch n.name {
        case "a", "area": return n.attribute("href") != nil
        case "input":
            let ty = inputType(n)
            return ty == "checkbox" || ty == "radio" || ty == "submit" || ty == "image" || ty == "reset" || ty == "button"
        case "button", "label", "summary": return true
        default: return false
        }
    }

    /// DOM "dispatch". Returns true if the event was canceled.
    @discardableResult
    func dispatch(_ e: JSDOMEvent, to targetIn: JSDOMTarget) throws(JSThrow) -> Bool {
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        _ = heap.root(wrapEvent(e))
        _ = heap.root(wrapTarget(targetIn))
        e.dispatchFlag = true
        var target = targetIn
        var activationTarget: JSDOMTarget? = nil
        var related = retarget(e.relatedTarget, against: target)
        var clearTargets = false
        e.path = []
        if !target.same(related) || target.same(e.relatedTarget) {
            appendToPath(e, target, target, related, slotInClosed: false)
            let isActivation = e.iface == .MouseEvent || e.iface == .PointerEvent ? e.type == "click" : false
            if isActivation && hasActivationBehavior(target) { activationTarget = target }
            var slottable: HTMLNode? = nil
            if case .node(let n) = target, n.isSlottable, n.assignedSlotIncludingClosed != nil { slottable = n }
            var slotInClosed = false
            var parent = eventParent(target, e)
            var guardCount = 0
            while let p = parent, guardCount < 100_000 {
                guardCount += 1
                if slottable != nil, case .node(let pn) = p, pn.isSlot {
                    slottable = nil
                    if pn.rootNode.isShadowRoot && pn.rootNode.shadowRootMode == .closed { slotInClosed = true }
                }
                if case .node(let pn) = p, pn.isSlottable, pn.assignedSlotIncludingClosed != nil { slottable = pn }
                related = retarget(e.relatedTarget, against: p)
                var isAncestorCase = false
                switch p {
                case .window: isAncestorCase = true
                case .node(let pn):
                    if case .node(let tn) = target { isAncestorCase = tn.rootNode.isShadowIncludingInclusiveAncestor(of: pn) }
                default: break
                }
                if isAncestorCase {
                    if isActivation && activationTarget == nil && hasActivationBehavior(p) {
                        if case .window = p {} else { activationTarget = p }
                    }
                    appendToPath(e, p, nil, related, slotInClosed: slotInClosed)
                } else if p.same(related) {
                    parent = nil
                    slotInClosed = false
                    continue
                } else {
                    target = p
                    if isActivation && activationTarget == nil && hasActivationBehavior(target) { activationTarget = target }
                    appendToPath(e, p, target, related, slotInClosed: slotInClosed)
                }
                parent = eventParent(p, e)
                slotInClosed = false
            }
            // Clear targets if the last shadow-adjusted target is in a shadow tree.
            var k = e.path.count - 1
            while k >= 0 { if e.path[k].shadowAdjustedTarget != nil { break }; k -= 1 }
            if k >= 0 {
                let s = e.path[k]
                func shadowNode(_ t: JSDOMTarget?) -> Bool {
                    if case .node(let n)? = t { return n.rootNode.isShadowRoot }
                    return false
                }
                if shadowNode(s.shadowAdjustedTarget) || shadowNode(s.relatedTarget) { clearTargets = true }
            }
            // Legacy-pre-activation behavior (checkboxes and radios toggle first).
            var preState: (HTMLNode, Bool, HTMLNode?)? = nil
            if let at = activationTarget, case .node(let an) = at { preState = legacyPreActivation(an) }
            // Capture, then target and bubble.
            var i = e.path.count - 1
            while i >= 0 {
                let s = e.path[i]
                e.eventPhase = s.shadowAdjustedTarget != nil ? 2 : 1
                try invoke(e, i, phase: 1)
                i -= 1
            }
            i = 0
            while i < e.path.count {
                let s = e.path[i]
                if s.shadowAdjustedTarget != nil {
                    e.eventPhase = 2
                } else {
                    if !e.bubbles { i += 1; continue }
                    e.eventPhase = 3
                }
                try invoke(e, i, phase: 3)
                i += 1
            }
            e.eventPhase = 0
            e.currentTarget = nil
            e.path = []
            e.dispatchFlag = false
            e.stopPropagationFlag = false
            e.stopImmediateFlag = false
            if clearTargets { e.target = nil; e.relatedTarget = nil }
            if let at = activationTarget, case .node(let an) = at {
                if !e.canceledFlag {
                    try activationBehavior(an, e)
                } else if let ps = preState {
                    legacyCanceledActivation(ps)
                }
            }
            return e.canceledFlag
        }
        e.eventPhase = 0
        e.currentTarget = nil
        e.path = []
        e.dispatchFlag = false
        e.stopPropagationFlag = false
        e.stopImmediateFlag = false
        return e.canceledFlag
    }

    /// DOM "invoke" for path entry `idx` in `phase` (1 capture, 3 bubble).
    func invoke(_ e: JSDOMEvent, _ idx: Int, phase: Int) throws(JSThrow) {
        guard idx < e.path.count else { return }
        let s = e.path[idx]
        // target = the last shadow-adjusted target at or before idx.
        var k = idx
        while k >= 0 { if e.path[k].shadowAdjustedTarget != nil { break }; k -= 1 }
        if k >= 0 { e.target = e.path[k].shadowAdjustedTarget }
        e.relatedTarget = s.relatedTarget
        if e.stopPropagationFlag { return }
        e.currentTarget = s.invocationTarget
        if case .node(let n) = s.invocationTarget { scanContentHandlers(n) }
        guard let list = listeners(s.invocationTarget, create: false), !list.items.isEmpty else { return }
        let snapshot = list.items
        let cur = wrapTarget(s.invocationTarget)
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        _ = heap.root(cur)
        let ev = wrapEvent(e)
        _ = heap.root(ev)
        for l in snapshot {
            if l.removed || l.type != e.type { continue }
            if phase == 1 && !l.capture { continue }
            if phase == 3 && l.capture { continue }
            if l.once { removeListener(s.invocationTarget, l) }
            let savedEvent = currentEvent
            if !s.inShadowTree { currentEvent = ev }
            if l.passive { e.inPassiveListener = true }
            if let hk = l.handlerKey {
                try callHandler(hk, e, ev, this: cur)
            } else {
                try callListener(l.callback, this: cur, event: ev)
            }
            e.inPassiveListener = false
            currentEvent = savedEvent
            if e.stopImmediateFlag { return }
        }
    }

    func callListener(_ cb: JSValue, this: JSValue, event: JSValue) throws(JSThrow) {
        var f = cb
        var thisArg = this
        if !heap.isCallable(cb) {
            // handleEvent on a callback interface object.
            let c = realm.runCallbackGet(cb, "handleEvent")
            switch c {
            case .normal(let h):
                _ = heap.root(h)
                if !heap.isCallable(h) {
                    reportError(message: "TypeError: handleEvent is not a function", value: .undefined)
                    return
                }
                f = h
                thisArg = cb
            case .exception(let ex): reportUncaught(ex); return
            case .terminated: if realm.isTerminating { throw JSThrow() }; return
            }
        }
        _ = try runScriptCallback(f, this: thisArg, args: [event])
    }

    /// Call `f` the way HTML "calls a user object's operation": exceptions
    /// are reported (not propagated); terminations propagate; a microtask
    /// checkpoint runs when the JS stack becomes empty.
    func runScriptCallback(_ f: JSValue, this: JSValue, args: [JSValue]) throws(JSThrow) -> JSValue? {
        let outer = realm.nativeDepth == 0 && realm.frames.isEmpty
        if outer { loop.beginTask?() }
        let c = realm.runCallback(f, this: this, args: args)
        var result: JSValue? = nil
        switch c {
        case .normal(let v): result = v
        case .exception(let ex): reportUncaught(ex)
        case .terminated(let why):
            if realm.isTerminating { throw JSThrow() }
            loop.reportTermination?(why)
        }
        if outer { loop.performMicrotaskCheckpoint() }
        return result
    }

    // MARK: Errors

    func reportUncaught(_ ex: JSUncaughtException) {
        let d = heap.rootDepth
        _ = heap.root(ex.value)
        reportError(message: ex.message, value: ex.value)
        heap.popRoots(to: d)
        host.reportError(ex.message, ex.stack)
    }

    /// Fire `error` at the window (once; not re-entrantly).
    func reportError(message: String, value: JSValue) {
        if reportingError { return }
        reportingError = true
        defer { reportingError = false }
        let e = JSDOMEvent(.ErrorEvent, type: "error", time: now())
        e.cancelable = true
        e.isTrusted = true
        e.message = message
        let w = wrapEvent(e)
        let d = heap.rootDepth
        _ = heap.root(w)
        setHiddenSlot(w, 0, value)
        _ = try? dispatch(e, to: .window)
        heap.popRoots(to: d)
    }

    func now() -> Double { host.now() - timeOrigin }

    // MARK: Event handlers

    func handlerTarget(_ t: JSDOMTarget, _ name: String, forward: Bool) -> JSDOMTarget {
        if forward { return .window }
        if case .node(let n) = t, n.kind == .element, n.namespace == .html, n.name == "body" || n.name == "frameset",
           jsdomForwardsToWindow(name) {
            return .window
        }
        return t
    }

    func getEventHandler(_ t0: JSDOMTarget, _ name: String, forwardToWindow: Bool) -> JSValue {
        let t = handlerTarget(t0, name, forward: forwardToWindow)
        if case .node(let n) = t0 { scanContentHandlers(n) }
        guard let h = handlers[JSDOMHandlerKey(target: targetID(t), name: name)] else { return .null }
        if h.source != nil { compileHandler(h, t, t0, name) }
        return h.value
    }

    func setEventHandler(_ t0: JSDOMTarget, _ name: String, _ v: JSValue, forwardToWindow: Bool) throws(JSThrow) {
        let t = handlerTarget(t0, name, forward: forwardToWindow)
        if case .node(let n) = t0 { scanContentHandlers(n) }
        let value: JSValue = v.isObject ? v : .null   // [LegacyTreatNonObjectAsNull]
        setHandlerValue(t, name, value, source: nil)
    }

    func setHandlerValue(_ t: JSDOMTarget, _ name: String, _ value: JSValue, source: String?) {
        let key = JSDOMHandlerKey(target: targetID(t), name: name)
        if value.isNull && source == nil {
            if let h = handlers[key] {
                if let l = h.listener { removeListener(t, l) }
                handlers[key] = nil
            }
            return
        }
        let h = handlers[key] ?? JSDOMHandler()
        h.value = value
        h.source = source
        handlers[key] = h
        if h.listener == nil {
            let l = JSDOMListener(type: name, callback: .undefined, capture: false, passive: false, once: false, handlerKey: key)
            h.listener = l
            if let list = listeners(t, create: true) { list.items.append(l) }
        }
    }

    /// Register handlers for the on* content attributes of a node the
    /// first time it matters (dispatch, addEventListener, onX getter).
    func scanContentHandlers(_ n: HTMLNode) {
        guard n.kind == .element, !n.attributes.isEmpty else { return }
        let k = ObjectIdentifier(n)
        if scannedHandlers.contains(k) { return }
        scannedHandlers.insert(k)
        for a in n.attributes where a.name.utf8.count > 2 && a.name.hasPrefix("on") {
            let name = String(a.name.dropFirst(2))
            contentHandlerChanged(n, name, a.value)
        }
    }

    /// An on* content attribute was set (value) or removed (nil).
    func contentHandlerChanged(_ n: HTMLNode, _ name: String, _ value: String?) {
        let t = handlerTarget(.node(n), name, forward: false)
        if let v = value {
            setHandlerValue(t, name, .null, source: v)
        } else {
            setHandlerValue(t, name, .null, source: nil)
        }
    }

    func compileHandler(_ h: JSDOMHandler, _ t: JSDOMTarget, _ element: JSDOMTarget, _ name: String) {
        guard let src = h.source else { return }
        h.source = nil
        h.value = .null
        let params = name == "error" && (t.same(.window)) ? "event, source, lineno, colno, error" : "event"
        let code = "(function(__d, __f, __e) { with (__d) with (__f) with (__e) return function on" + name + "(" + params
            + ") {\n" + src + "\n}; })"
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        let c = realm.evaluate(source: code, name: "on" + name)
        guard case .normal(let maker) = c else {
            if case .exception(let ex) = c { reportUncaught(ex) }
            return
        }
        _ = heap.root(maker)
        var el: JSValue = .undefined
        var form: JSValue = .undefined
        var doc: JSValue = .undefined
        if case .node(let n) = element {
            el = wrapNode(n)
            _ = heap.root(el)
            doc = wrapNode(n.ownerDocument ?? document)
            _ = heap.root(doc)
            if let f = formOwner(n) { form = wrapNode(f); _ = heap.root(form) }
        } else {
            el = newObject()
            _ = heap.root(el)
            doc = newObject()
            _ = heap.root(doc)
        }
        if form.isUndefined { form = newObject(); _ = heap.root(form) }
        let r = realm.runCallback(maker, this: .undefined, args: [doc, form, el])
        if case .normal(let f) = r, heap.isCallable(f) { h.value = f }
        else if case .exception(let ex) = r { reportUncaught(ex) }
    }

    func callHandler(_ key: JSDOMHandlerKey, _ e: JSDOMEvent, _ ev: JSValue, this: JSValue) throws(JSThrow) {
        guard let h = handlers[key] else { return }
        if h.source != nil, let t = e.currentTarget { compileHandler(h, t, t, key.name) }
        let f = h.value
        if !heap.isCallable(f) { return }
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        _ = heap.root(f)
        var args: [JSValue] = [ev]
        let isWindowError = key.name == "error" && key.target == 0 && e.iface == .ErrorEvent
        if isWindowError {
            args = [str(e.message), str(e.filename), .number(e.lineno), .number(e.colno), hiddenSlot(ev, 0)]
            for a in args { _ = heap.root(a) }
        }
        guard let rv = try runScriptCallback(f, this: this, args: args) else { return }
        if isWindowError {
            if rv == .true { e.canceledFlag = e.cancelable }
        } else if key.name == "beforeunload" {
            if !rv.isNullish { e.canceledFlag = e.cancelable }
        } else if rv == .false {
            if e.cancelable && !e.inPassiveListener { e.canceledFlag = true }
        }
    }

    // MARK: Event objects

    func makeEvent(_ i: JSDOMInterface, _ type: String, _ d: JSDOM_EventInit) -> JSDOMEvent {
        let e = JSDOMEvent(i, type: type, time: now())
        e.bubbles = d.bubbles
        e.cancelable = d.cancelable
        e.composed = d.composed
        return e
    }

    func adoptNewTarget(_ w: JSValue, _ newTarget: JSValue, _ i: JSDOMInterface) throws(JSThrow) {
        guard newTarget.isObject, w.isObject else { return }
        // The fresh wrapper must survive whatever the prototype getter does.
        _ = heap.root(w)
        let p = try realm.getV(newTarget, heap.names.prototype)
        if p.isObject && p != protos[i.rawValue] { _ = heap.setPrototypeOf(w, p) }
    }

    func eventInit<D>(_ d: D, _ f: (D) -> JSDOM_EventInit) -> JSDOM_EventInit { f(d) }

    func finishEvent(_ e: JSDOMEvent, _ newTarget: JSValue) throws(JSThrow) -> JSValue {
        let w = wrapEvent(e)
        try adoptNewTarget(w, newTarget, e.iface)
        return w
    }

    func Event_constructor(_ type: String, _ d: JSDOM_EventInit, newTarget: JSValue) throws(JSThrow) -> JSValue {
        try finishEvent(makeEvent(.Event, type, d), newTarget)
    }

    func baseInit(bubbles: Bool, cancelable: Bool, composed: Bool) -> JSDOM_EventInit {
        var b = JSDOM_EventInit()
        b.bubbles = bubbles
        b.cancelable = cancelable
        b.composed = composed
        return b
    }

    func CustomEvent_constructor(_ type: String, _ d: JSDOM_CustomEventInit, newTarget: JSValue) throws(JSThrow) -> JSValue {
        let e = makeEvent(.CustomEvent, type, baseInit(bubbles: d.bubbles, cancelable: d.cancelable, composed: d.composed))
        let w = try finishEvent(e, newTarget)
        setHiddenSlot(w, 0, d.detail)
        return w
    }

    func uiEvent(_ i: JSDOMInterface, _ type: String, bubbles: Bool, cancelable: Bool, composed: Bool, view: JSValue,
                 detail: Int, which: Int) throws(JSThrow) -> JSDOMEvent {
        let e = makeEvent(i, type, baseInit(bubbles: bubbles, cancelable: cancelable, composed: composed))
        if !view.isNullish {
            if view != realm.global { throw realm.throwTypeError("Failed to construct '" + jsdomInterfaceNames[i.rawValue] + "': member view is not of type Window.") }
            e.viewIsWindow = true
        }
        e.detail = detail
        e.which = which
        return e
    }

    func UIEvent_constructor(_ type: String, _ d: JSDOM_UIEventInit, newTarget: JSValue) throws(JSThrow) -> JSValue {
        try finishEvent(try uiEvent(.UIEvent, type, bubbles: d.bubbles, cancelable: d.cancelable, composed: d.composed,
                                    view: d.view, detail: d.detail, which: d.which), newTarget)
    }

    func mouseFields(_ e: JSDOMEvent, screenX: Int, screenY: Int, clientX: Int, clientY: Int, button: Int, buttons: Int,
                     ctrl: Bool, shift: Bool, alt: Bool, meta: Bool, related: JSDOMTarget?) {
        e.screenX = Double(screenX); e.screenY = Double(screenY)
        e.clientX = Double(clientX); e.clientY = Double(clientY)
        e.button = button; e.buttons = buttons
        e.ctrlKey = ctrl; e.shiftKey = shift; e.altKey = alt; e.metaKey = meta
        e.relatedTarget = related
    }

    func MouseEvent_constructor(_ type: String, _ d: JSDOM_MouseEventInit, newTarget: JSValue) throws(JSThrow) -> JSValue {
        let e = try uiEvent(.MouseEvent, type, bubbles: d.bubbles, cancelable: d.cancelable, composed: d.composed,
                            view: d.view, detail: d.detail, which: d.which)
        mouseFields(e, screenX: d.screenX, screenY: d.screenY, clientX: d.clientX, clientY: d.clientY, button: d.button,
                    buttons: d.buttons, ctrl: d.ctrlKey, shift: d.shiftKey, alt: d.altKey, meta: d.metaKey, related: d.relatedTarget)
        return try finishEvent(e, newTarget)
    }

    func PointerEvent_constructor(_ type: String, _ d: JSDOM_PointerEventInit, newTarget: JSValue) throws(JSThrow) -> JSValue {
        let e = try uiEvent(.PointerEvent, type, bubbles: d.bubbles, cancelable: d.cancelable, composed: d.composed,
                            view: d.view, detail: d.detail, which: d.which)
        mouseFields(e, screenX: d.screenX, screenY: d.screenY, clientX: d.clientX, clientY: d.clientY, button: d.button,
                    buttons: d.buttons, ctrl: d.ctrlKey, shift: d.shiftKey, alt: d.altKey, meta: d.metaKey, related: d.relatedTarget)
        e.pointerId = d.pointerId; e.width = d.width; e.height = d.height; e.pressure = d.pressure
        e.pointerType = d.pointerType; e.isPrimary = d.isPrimary
        return try finishEvent(e, newTarget)
    }

    func WheelEvent_constructor(_ type: String, _ d: JSDOM_WheelEventInit, newTarget: JSValue) throws(JSThrow) -> JSValue {
        let e = try uiEvent(.WheelEvent, type, bubbles: d.bubbles, cancelable: d.cancelable, composed: d.composed,
                            view: d.view, detail: d.detail, which: d.which)
        mouseFields(e, screenX: d.screenX, screenY: d.screenY, clientX: d.clientX, clientY: d.clientY, button: d.button,
                    buttons: d.buttons, ctrl: d.ctrlKey, shift: d.shiftKey, alt: d.altKey, meta: d.metaKey, related: d.relatedTarget)
        e.deltaX = d.deltaX; e.deltaY = d.deltaY; e.deltaZ = d.deltaZ; e.deltaMode = d.deltaMode
        return try finishEvent(e, newTarget)
    }

    func KeyboardEvent_constructor(_ type: String, _ d: JSDOM_KeyboardEventInit, newTarget: JSValue) throws(JSThrow) -> JSValue {
        let e = try uiEvent(.KeyboardEvent, type, bubbles: d.bubbles, cancelable: d.cancelable, composed: d.composed,
                            view: d.view, detail: d.detail, which: d.which)
        e.ctrlKey = d.ctrlKey; e.shiftKey = d.shiftKey; e.altKey = d.altKey; e.metaKey = d.metaKey
        e.key = d.key; e.code = d.code; e.location = d.location; e.repeatKey = d.`repeat`
        e.isComposing = d.isComposing; e.charCode = d.charCode; e.keyCode = d.keyCode
        return try finishEvent(e, newTarget)
    }

    func InputEvent_constructor(_ type: String, _ d: JSDOM_InputEventInit, newTarget: JSValue) throws(JSThrow) -> JSValue {
        let e = try uiEvent(.InputEvent, type, bubbles: d.bubbles, cancelable: d.cancelable, composed: d.composed,
                            view: d.view, detail: d.detail, which: d.which)
        e.data = d.data; e.isComposing = d.isComposing; e.inputType = d.inputType
        return try finishEvent(e, newTarget)
    }

    func FocusEvent_constructor(_ type: String, _ d: JSDOM_FocusEventInit, newTarget: JSValue) throws(JSThrow) -> JSValue {
        let e = try uiEvent(.FocusEvent, type, bubbles: d.bubbles, cancelable: d.cancelable, composed: d.composed,
                            view: d.view, detail: d.detail, which: d.which)
        e.relatedTarget = d.relatedTarget
        return try finishEvent(e, newTarget)
    }

    func SubmitEvent_constructor(_ type: String, _ d: JSDOM_SubmitEventInit, newTarget: JSValue) throws(JSThrow) -> JSValue {
        let e = makeEvent(.SubmitEvent, type, baseInit(bubbles: d.bubbles, cancelable: d.cancelable, composed: d.composed))
        e.submitter = d.submitter
        return try finishEvent(e, newTarget)
    }

    func PopStateEvent_constructor(_ type: String, _ d: JSDOM_PopStateEventInit, newTarget: JSValue) throws(JSThrow) -> JSValue {
        let e = makeEvent(.PopStateEvent, type, baseInit(bubbles: d.bubbles, cancelable: d.cancelable, composed: d.composed))
        let w = try finishEvent(e, newTarget)
        setHiddenSlot(w, 0, d.state)
        return w
    }

    func HashChangeEvent_constructor(_ type: String, _ d: JSDOM_HashChangeEventInit, newTarget: JSValue) throws(JSThrow) -> JSValue {
        let e = makeEvent(.HashChangeEvent, type, baseInit(bubbles: d.bubbles, cancelable: d.cancelable, composed: d.composed))
        e.oldURL = d.oldURL; e.newURL = d.newURL
        return try finishEvent(e, newTarget)
    }

    func ErrorEvent_constructor(_ type: String, _ d: JSDOM_ErrorEventInit, newTarget: JSValue) throws(JSThrow) -> JSValue {
        let e = makeEvent(.ErrorEvent, type, baseInit(bubbles: d.bubbles, cancelable: d.cancelable, composed: d.composed))
        e.message = d.message; e.filename = d.filename; e.lineno = d.lineno; e.colno = d.colno
        let w = try finishEvent(e, newTarget)
        setHiddenSlot(w, 0, d.error)
        return w
    }

    func MediaQueryListEvent_constructor(_ type: String, _ d: JSDOM_MediaQueryListEventInit, newTarget: JSValue) throws(JSThrow) -> JSValue {
        let e = makeEvent(.MediaQueryListEvent, type, baseInit(bubbles: d.bubbles, cancelable: d.cancelable, composed: d.composed))
        e.media = d.media; e.matches = d.matches
        return try finishEvent(e, newTarget)
    }

    // MARK: Event members

    func Event_type(_ e: JSDOMEvent) -> String { e.type }
    func Event_target(_ e: JSDOMEvent) -> JSDOMTarget? { e.target }
    func Event_srcElement(_ e: JSDOMEvent) -> JSDOMTarget? { e.target }
    func Event_currentTarget(_ e: JSDOMEvent) -> JSDOMTarget? { e.currentTarget }
    func Event_eventPhase(_ e: JSDOMEvent) -> Int { e.eventPhase }
    func Event_stopPropagation(_ e: JSDOMEvent) { e.stopPropagationFlag = true }
    func Event_cancelBubble(_ e: JSDOMEvent) -> Bool { e.stopPropagationFlag }
    func Event_set_cancelBubble(_ e: JSDOMEvent, _ v: Bool) { if v { e.stopPropagationFlag = true } }
    func Event_stopImmediatePropagation(_ e: JSDOMEvent) { e.stopPropagationFlag = true; e.stopImmediateFlag = true }
    func Event_bubbles(_ e: JSDOMEvent) -> Bool { e.bubbles }
    func Event_cancelable(_ e: JSDOMEvent) -> Bool { e.cancelable }
    func Event_returnValue(_ e: JSDOMEvent) -> Bool { !e.canceledFlag }
    func Event_set_returnValue(_ e: JSDOMEvent, _ v: Bool) { if !v && e.cancelable && !e.inPassiveListener { e.canceledFlag = true } }
    func Event_preventDefault(_ e: JSDOMEvent) { if e.cancelable && !e.inPassiveListener { e.canceledFlag = true } }
    func Event_defaultPrevented(_ e: JSDOMEvent) -> Bool { e.canceledFlag }
    func Event_composed(_ e: JSDOMEvent) -> Bool { e.composed }
    func Event_isTrusted(_ e: JSDOMEvent) -> Bool { e.isTrusted }
    func Event_timeStamp(_ e: JSDOMEvent) -> Double { e.timeStamp }

    func Event_initEvent(_ e: JSDOMEvent, _ type: String, _ bubbles: Bool, _ cancelable: Bool) {
        if e.dispatchFlag { return }
        e.initialized = true
        e.stopPropagationFlag = false
        e.stopImmediateFlag = false
        e.canceledFlag = false
        e.isTrusted = false
        e.target = nil
        e.type = type
        e.bubbles = bubbles
        e.cancelable = cancelable
    }

    /// DOM "composedPath()".
    func Event_composedPath(_ e: JSDOMEvent) -> JSValue {
        let path = e.path
        guard !path.isEmpty, let cur = e.currentTarget else { return array([]) }
        var composed: [JSDOMTarget] = []
        var currentTargetIndex = 0
        var currentTargetHiddenLevel = 0
        var index = path.count - 1
        while index >= 0 {
            if path[index].rootOfClosedTree { currentTargetHiddenLevel += 1 }
            if path[index].invocationTarget.same(cur) { currentTargetIndex = index; break }
            if path[index].slotInClosedTree { currentTargetHiddenLevel -= 1 }
            index -= 1
        }
        var currentHiddenLevel = currentTargetHiddenLevel
        var maxHiddenLevel = currentTargetHiddenLevel
        index = currentTargetIndex - 1
        var before: [JSDOMTarget] = []
        while index >= 0 {
            if path[index].rootOfClosedTree { currentHiddenLevel += 1 }
            if currentHiddenLevel <= maxHiddenLevel { before.append(path[index].invocationTarget) }
            if path[index].slotInClosedTree {
                currentHiddenLevel -= 1
                if currentHiddenLevel < maxHiddenLevel { maxHiddenLevel = currentHiddenLevel }
            }
            index -= 1
        }
        composed = before.reversed()
        composed.append(cur)
        currentHiddenLevel = currentTargetHiddenLevel
        maxHiddenLevel = currentTargetHiddenLevel
        index = currentTargetIndex + 1
        while index < path.count {
            if path[index].slotInClosedTree { currentHiddenLevel += 1 }
            if currentHiddenLevel <= maxHiddenLevel { composed.append(path[index].invocationTarget) }
            if path[index].rootOfClosedTree {
                currentHiddenLevel -= 1
                if currentHiddenLevel < maxHiddenLevel { maxHiddenLevel = currentHiddenLevel }
            }
            index += 1
        }
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        var vals: [JSValue] = []
        for t in composed { let w = wrapTarget(t); _ = heap.root(w); vals.append(w) }
        return array(vals)
    }

    func CustomEvent_detail(_ e: JSDOMEvent) -> JSValue {
        guard let w = eventClass.existingWrapper(for: e) else { return .null }
        let v = hiddenSlot(w, 0)
        return v.isUndefined && e.iface == .CustomEvent ? .null : v
    }

    func CustomEvent_initCustomEvent(_ e: JSDOMEvent, _ type: String, _ bubbles: Bool, _ cancelable: Bool, _ detail: JSValue) {
        if e.dispatchFlag { return }
        Event_initEvent(e, type, bubbles, cancelable)
        if let w = eventClass.existingWrapper(for: e) { setHiddenSlot(w, 0, detail) }
    }

    func UIEvent_view(_ e: JSDOMEvent) -> JSValue { e.viewIsWindow ? realm.global : .null }
    func UIEvent_detail(_ e: JSDOMEvent) -> Int { e.detail }
    func UIEvent_which(_ e: JSDOMEvent) -> Int {
        if e.which != 0 { return e.which }
        if e.iface == .KeyboardEvent { return e.keyCode != 0 ? e.keyCode : e.charCode }
        if e.iface == .MouseEvent || e.iface == .PointerEvent { return e.button + 1 }
        return 0
    }
    func UIEvent_initUIEvent(_ e: JSDOMEvent, _ type: String, _ bubbles: Bool, _ cancelable: Bool, _ view: JSValue, _ detail: Int) {
        if e.dispatchFlag { return }
        Event_initEvent(e, type, bubbles, cancelable)
        e.viewIsWindow = view == realm.global
        e.detail = detail
    }

    func scroll() -> (Double, Double) { host.scrollPosition() }

    func MouseEvent_screenX(_ e: JSDOMEvent) -> Double { e.screenX }
    func MouseEvent_screenY(_ e: JSDOMEvent) -> Double { e.screenY }
    func MouseEvent_clientX(_ e: JSDOMEvent) -> Double { e.clientX }
    func MouseEvent_clientY(_ e: JSDOMEvent) -> Double { e.clientY }
    func MouseEvent_x(_ e: JSDOMEvent) -> Double { e.clientX }
    func MouseEvent_y(_ e: JSDOMEvent) -> Double { e.clientY }
    func MouseEvent_pageX(_ e: JSDOMEvent) -> Double { e.clientX + scroll().0 }
    func MouseEvent_pageY(_ e: JSDOMEvent) -> Double { e.clientY + scroll().1 }
    func MouseEvent_offsetX(_ e: JSDOMEvent) -> Double { e.offsetX }
    func MouseEvent_offsetY(_ e: JSDOMEvent) -> Double { e.offsetY }
    func MouseEvent_ctrlKey(_ e: JSDOMEvent) -> Bool { e.ctrlKey }
    func MouseEvent_shiftKey(_ e: JSDOMEvent) -> Bool { e.shiftKey }
    func MouseEvent_altKey(_ e: JSDOMEvent) -> Bool { e.altKey }
    func MouseEvent_metaKey(_ e: JSDOMEvent) -> Bool { e.metaKey }
    func MouseEvent_button(_ e: JSDOMEvent) -> Int { e.button }
    func MouseEvent_buttons(_ e: JSDOMEvent) -> Int { e.buttons }
    func MouseEvent_relatedTarget(_ e: JSDOMEvent) -> JSDOMTarget? { e.relatedTarget }
    func MouseEvent_getModifierState(_ e: JSDOMEvent, _ k: String) -> Bool {
        switch k {
        case "Control": return e.ctrlKey
        case "Shift": return e.shiftKey
        case "Alt": return e.altKey
        case "Meta": return e.metaKey
        default: return false
        }
    }
    func PointerEvent_pointerId(_ e: JSDOMEvent) -> Int { e.pointerId }
    func PointerEvent_width(_ e: JSDOMEvent) -> Double { e.width }
    func PointerEvent_height(_ e: JSDOMEvent) -> Double { e.height }
    func PointerEvent_pressure(_ e: JSDOMEvent) -> Double { e.pressure }
    func PointerEvent_pointerType(_ e: JSDOMEvent) -> String { e.pointerType }
    func PointerEvent_isPrimary(_ e: JSDOMEvent) -> Bool { e.isPrimary }
    func WheelEvent_deltaX(_ e: JSDOMEvent) -> Double { e.deltaX }
    func WheelEvent_deltaY(_ e: JSDOMEvent) -> Double { e.deltaY }
    func WheelEvent_deltaZ(_ e: JSDOMEvent) -> Double { e.deltaZ }
    func WheelEvent_deltaMode(_ e: JSDOMEvent) -> Int { e.deltaMode }
    func KeyboardEvent_key(_ e: JSDOMEvent) -> String { e.key }
    func KeyboardEvent_code(_ e: JSDOMEvent) -> String { e.code }
    func KeyboardEvent_location(_ e: JSDOMEvent) -> Int { e.location }
    func KeyboardEvent_repeat(_ e: JSDOMEvent) -> Bool { e.repeatKey }
    func KeyboardEvent_isComposing(_ e: JSDOMEvent) -> Bool { e.isComposing }
    func KeyboardEvent_charCode(_ e: JSDOMEvent) -> Int { e.charCode }
    func KeyboardEvent_keyCode(_ e: JSDOMEvent) -> Int { e.keyCode }
    func InputEvent_data(_ e: JSDOMEvent) -> String? { e.data }
    func InputEvent_inputType(_ e: JSDOMEvent) -> String { e.inputType }
    func SubmitEvent_submitter(_ e: JSDOMEvent) -> HTMLNode? { e.submitter }
    func HashChangeEvent_oldURL(_ e: JSDOMEvent) -> String { e.oldURL }
    func HashChangeEvent_newURL(_ e: JSDOMEvent) -> String { e.newURL }
    func ErrorEvent_message(_ e: JSDOMEvent) -> String { e.message }
    func ErrorEvent_filename(_ e: JSDOMEvent) -> String { e.filename }
    func ErrorEvent_lineno(_ e: JSDOMEvent) -> Int { e.lineno }
    func ErrorEvent_colno(_ e: JSDOMEvent) -> Int { e.colno }
    func MediaQueryListEvent_media(_ e: JSDOMEvent) -> String { e.media }
    func MediaQueryListEvent_matches(_ e: JSDOMEvent) -> Bool { e.matches }

    // MARK: Firing (Swift side)

    /// Fire a simple event (HTML "fire an event").
    @discardableResult
    func fire(_ type: String, at t: JSDOMTarget, bubbles: Bool = false, cancelable: Bool = false,
              iface: JSDOMInterface = .Event, trusted: Bool = true) -> Bool {
        let e = JSDOMEvent(iface, type: type, time: now())
        e.bubbles = bubbles
        e.cancelable = cancelable
        e.isTrusted = trusted
        return (try? dispatch(e, to: t)) ?? false
    }

    // MARK: AbortController / AbortSignal

    func AbortController_constructor(newTarget: JSValue) throws(JSThrow) -> JSValue {
        classes.AbortController.wrap(JSDOMAbortController(JSDOMEventTargetObject(.AbortSignal)))
    }
    func AbortController_signal(_ c: JSDOMAbortController) -> JSValue { classes.EventTargetObject.wrap(c.signal) }
    func AbortController_abort(_ c: JSDOMAbortController, _ reason: JSValue) { signalAbort(c.signal, reason) }

    func signalAbort(_ s: JSDOMEventTargetObject, _ reason: JSValue) {
        if s.aborted { return }
        s.aborted = true
        let w = classes.EventTargetObject.wrap(s)
        let d = heap.rootDepth
        _ = heap.root(w)
        let r = reason.isUndefined ? domException("AbortError", "signal is aborted without reason") : reason
        _ = heap.root(r)
        setHiddenSlot(w, 0, r)
        // Keep the reason reachable while anything can ask for it.
        keep.append(w)
        let algos = s.abortAlgorithms
        s.abortAlgorithms = []
        for a in algos { a() }
        fire("abort", at: .object(s))
        heap.popRoots(to: d)
    }

    func AbortSignal_static_abort(_ reason: JSValue) throws(JSThrow) -> JSValue {
        let s = JSDOMEventTargetObject(.AbortSignal)
        let w = classes.EventTargetObject.wrap(s)
        let d = heap.rootDepth
        _ = heap.root(w)
        signalAbort(s, reason)
        heap.popRoots(to: d)
        return w
    }
    func AbortSignal_aborted(_ s: JSDOMEventTargetObject) -> Bool { s.aborted }
    func AbortSignal_reason(_ s: JSDOMEventTargetObject) -> JSValue {
        guard s.aborted, let w = classes.EventTargetObject.existingWrapper(for: s) else { return .undefined }
        return hiddenSlot(w, 0)
    }
    func AbortSignal_throwIfAborted(_ s: JSDOMEventTargetObject) throws(JSThrow) {
        if s.aborted { throw realm.throwValue(AbortSignal_reason(s)) }
    }
}

final class JSDOMAbortController {
    let signal: JSDOMEventTargetObject
    init(_ s: JSDOMEventTargetObject) { signal = s }
}

extension JSRealm {
    /// Get o[name] as a top-level callback would (exceptions become a completion).
    func runCallbackGet(_ o: JSValue, _ name: String) -> JSCompletion {
        let outer = nativeDepth == 0 && frames.isEmpty
        if outer { stackFloor = jsVMStackFloor(limits) }
        do throws(JSThrow) {
            return .normal(try getV(o, heap.key(name)))
        } catch {
            return finishCompletion(outer: outer)
        }
    }
}
