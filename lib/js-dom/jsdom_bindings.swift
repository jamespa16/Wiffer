// JSDOMBindings: the JS side of one page (ROADMAP Phase 9G, "Bindings").
//
// One instance per JSDOMPage. It owns the prototype objects of every
// generated interface, the host classes, the node and event wrapper caches,
// event listeners and handlers, and the support functions the generated
// glue (jsdom_generated.swift, from idl/*.txt) calls. The DOM itself stays
// in lib/html: wrappers hold HTMLNodes, never copies.
//
// Wrappers. Every DOM node has at most one wrapper, made lazily by
// `wrapNode` through one JSHostClass<HTMLNode> (one identity cache; the
// prototype is chosen per node by `nodeInterface`). A node wrapper is a GC
// root while the node is connected, has listeners or handlers, or the
// wrapper has expando properties; otherwise an unreachable wrapper is
// collected and a later wrap makes a fresh one (unobservable). Events are
// one JSHostClass<JSDOMEvent>, the same way. Other platform objects
// (NodeList, DOMTokenList, ...) have a host class each (JSDOMClasses).
//
// `this` checks: generated members unwrap `this` with thisNode(v, .I) and
// friends; a node passes when its interface inherits I (the parents table
// is generated). Wrong `this` -> TypeError "Illegal invocation".
//
// Errors: DOM errors become DOMException objects (`throwDOM(name, msg)`;
// HTMLDOMError maps 1:1 via `throwDOM(error)`).

struct JSDOMCtx {
    let iface: String
    let member: String
}

/// An event target: a node, the window, or another platform object.
enum JSDOMTarget {
    case node(HTMLNode)
    case window
    case object(JSDOMEventTargetObject)

    func same(_ o: JSDOMTarget?) -> Bool {
        guard let o = o else { return false }
        switch (self, o) {
        case (.node(let a), .node(let b)): return a === b
        case (.window, .window): return true
        case (.object(let a), .object(let b)): return a === b
        default: return false
        }
    }
    var node: HTMLNode? { if case .node(let n) = self { return n }; return nil }
}

/// EventTarget objects that are not nodes or the window: `new EventTarget()`,
/// AbortSignal, MediaQueryList. One Swift class (no downcasts in Embedded
/// Swift), with optional per-interface state.
final class JSDOMEventTargetObject {
    let iface: JSDOMInterface
    let listeners = JSDOMListenerList()
    // AbortSignal
    var aborted = false
    var abortReasonSlot = false        // the reason lives in wrapper slot 0
    var abortAlgorithms: [() -> Void] = []
    // MediaQueryList
    var media = ""
    var mediaList = CSSMediaQueryList()
    var matches = false
    init(_ i: JSDOMInterface) { iface = i }
}

final class JSDOMBindings {
    let realm: JSRealm
    let heap: JSHeap
    let document: HTMLNode
    var host: JSDOMHost
    /// Prototype per interface (JSDOMInterface raw value).
    var protos: [JSValue]
    /// Interface objects (constructors) per interface.
    var ctors: [JSValue]
    var classes: JSDOMClasses!
    var nodeClass: JSHostClass<HTMLNode>!
    var eventClass: JSHostClass<JSDOMEvent>!
    var loop: JSEventLoop!
    var console: JSConsole!
    var rootProviderID = 0
    /// Persistent values the bindings keep (global singletons).
    var keep: [JSValue] = []

    // Events (jsdom_events.swift).
    var nodeListeners: [ObjectIdentifier: JSDOMListenerList] = [:]
    let windowListeners = JSDOMListenerList()
    var listenerTargets: [JSDOMEventTargetObject] = []
    var handlers: [JSDOMHandlerKey: JSDOMHandler] = [:]
    var currentEvent: JSValue = .undefined
    var formExoticID = -1
    var documentExoticID = -1
    /// Elements created by createElementNS with a prefix (name = prefix:local).
    var prefixedElements: Set<ObjectIdentifier> = []
    /// Namespaces of attributes set with setAttributeNS.
    var attrNamespaces: [JSDOMAttrKey: String] = [:]
    /// ProcessingInstruction nodes (comments) and their targets.
    var piTargets: [ObjectIdentifier: String] = [:]
    /// CDATASection nodes (text nodes).
    var cdataNodes: Set<ObjectIdentifier> = []

    // Page state (jsdom_window.swift, jsdom_htmlelements.swift).
    var focused: HTMLNode? = nil
    var controls: [ObjectIdentifier: JSDOMControlState] = [:]
    var mutationVersion = 0
    var observers: [JSDOMMutationObserver] = []
    var pendingMutationDelivery = false
    var mutationObserverID = 0
    var mediaLists: [JSDOMEventTargetObject] = []
    var rafCallbacks: [(id: Int, fn: JSValue)] = []
    var nextRAF = 1
    var idleCallbacks: [(id: Int, fn: JSValue)] = []
    var historyStates: [Int: JSValue] = [:]
    var currentStateID = 0
    var nextStateID = 1
    var url: URLRecord?
    var readyState = "loading"
    var attrCache: [JSDOMAttrKey: JSDOMAttr] = [:]
    var storageItems: [(String, String)] = []
    var sessionItems: [(String, String)] = []
    var timeOrigin = 0.0
    var marks: [(String, Double)] = []
    var currentScript: HTMLNode? = nil
    var writeTarget: HTMLNode? = nil
    var styleState = LayoutStyleState()
    var reportingError = false
    var scannedHandlers: Set<ObjectIdentifier> = []
    var clickInProgress: Set<ObjectIdentifier> = []
    /// Documents made by createDocument (XML documents: tagName keeps case).
    var xmlDocuments: Set<ObjectIdentifier> = []
    /// Script-made documents (DOMParser, createHTMLDocument), kept with the page.
    var extraDocuments: [HTMLNode] = []
    /// createElementNS with a namespace lib/html doesn't know: the URI.
    var foreignNamespaces: [ObjectIdentifier: String] = [:]
    var writeDepth = 0
    var designMode = false
    var dialogReturn: [ObjectIdentifier: String] = [:]
    var submitting: Set<ObjectIdentifier> = []
    var windowName = ""
    var messageOrigin = ""
    var scrollRestorationManual = false
    var locationSingleton: JSDOMLocation? = nil
    var historySingleton: JSDOMHistory? = nil
    var navigatorSingleton: JSDOMNavigator? = nil
    var screenSingleton: JSDOMScreen? = nil
    var selectionSingleton: JSDOMSelection? = nil
    var performanceSingleton: JSDOMPerformance? = nil
    var localStorageSingleton: JSDOMStorage? = nil
    var sessionStorageSingleton: JSDOMStorage? = nil
    var pendingSlotChanges: [HTMLNode] = []
    var mutationNotifier: JSValue = .undefined
    var hookedDocuments: [(doc: HTMLNode, id: Int)] = []

    init(realm: JSRealm, document: HTMLNode, host: JSDOMHost) {
        self.realm = realm
        self.heap = realm.heap
        self.document = document
        self.host = host
        let n = JSDOMInterface.count.rawValue
        protos = Array(repeating: .undefined, count: n)
        ctors = Array(repeating: .undefined, count: n)
    }

    /// Build every prototype, class and global. Called once by JSDOMPage.
    func install() {
        rootProviderID = heap.addRootProvider { [unowned(unsafe) self] h in self.markRoots(h) }
        makeGeneratedPrototypes()
        makeGeneratedClasses()
        nodeClass = JSHostClass<HTMLNode>(realm: realm, name: "Node", parent: protos[JSDOMInterface.Node.rawValue])
        nodeClass.prototypeFor = { [unowned(unsafe) self] n in self.protos[self.nodeInterface(n).rawValue] }
        nodeClass.shouldRoot = { [unowned(unsafe) self] n in self.nodeWrapperIsRoot(n) }
        eventClass = JSHostClass<JSDOMEvent>(realm: realm, name: "Event", parent: protos[JSDOMInterface.Event.rawValue])
        eventClass.prototypeFor = { [unowned(unsafe) self] e in self.protos[e.iface.rawValue] }
        classes.EventTargetObject.prototypeFor = { [unowned(unsafe) self] o in self.protos[o.iface.rawValue] }
        classes.EventTargetObject.shouldRoot = { o in !o.listeners.items.isEmpty }
        // DOMException.prototype inherits Error.prototype.
        _ = heap.setPrototypeOf(protos[JSDOMInterface.DOMException.rawValue], realm.intrinsic(.errorPrototype))
        formExoticID = realm.registerExoticHandler(makeFormExotic())
        documentExoticID = realm.registerExoticHandler(makeDocumentExotic())
        installGenerated()
        // @@toStringTag on the object kinds' prototypes too.
        var k = 0
        while k < protos.count {
            let p = protos[k]
            let tagKey = JSPropertyKey.symbol(heap.symbolsWellKnown.toStringTag.handle)
            if p.isObject && heap.getOwnProperty(p, tagKey) == nil {
                let tag = heap.newString(jsdomInterfaceNames[k])
                let d = heap.rootDepth
                _ = heap.root(tag)
                _ = heap.defineOwnProperty(p, tagKey, .data(tag, [.configurable]))
                heap.popRoots(to: d)
            }
            k += 1
        }
        installStyleProperties()
        installWindowExtras()
        // The global object is the Window.
        _ = heap.setPrototypeOf(realm.global, protos[JSDOMInterface.Window.rawValue])
    }

    func markRoots(_ h: JSHeap) {
        for p in protos { h.markValue(p) }
        for c in ctors { h.markValue(c) }
        for v in keep { h.markValue(v) }
        for (_, l) in nodeListeners { l.mark(h) }
        windowListeners.mark(h)
        for o in listenerTargets { o.listeners.mark(h) }
        for (_, hd) in handlers { h.markValue(hd.value) }
        h.markValue(currentEvent)
        for r in rafCallbacks { h.markValue(r.fn) }
        for r in idleCallbacks { h.markValue(r.fn) }
        for (_, s) in historyStates { h.markValue(s) }
        for o in observers { o.mark(h) }
    }

    // MARK: Interfaces of nodes

    /// The most derived interface of a node.
    func nodeInterface(_ n: HTMLNode) -> JSDOMInterface {
        switch n.kind {
        case .document: return isHTMLDocument(n) ? .Document : .XMLDocument
        case .doctype: return .DocumentType
        case .text: return isCDATA(n) ? .CDATASection : .Text
        case .comment: return isPI(n) ? .ProcessingInstruction : .Comment
        case .documentFragment: return n.isShadowRoot ? .ShadowRoot : .DocumentFragment
        case .element:
            switch n.namespace {
            case .html:
                let local = prefixedElements.isEmpty ? n.name : elementLocalName(n)
                if let i = jsdomHTMLInterface(local) { return i }
                return jsdomIsPlainHTMLElementName(local) || htmlIsValidCustomElementName(local) ? .HTMLElement : .HTMLUnknownElement
            case .svg: return jsdomSVGInterface(n.name) ?? .SVGElement
            case .mathml: return .Element
            }
        }
    }

    /// Does interface `a` inherit (or equal) `b`?
    func inherits(_ a: JSDOMInterface, _ b: JSDOMInterface) -> Bool {
        var i = a.rawValue
        var k = 0
        while i >= 0 && k < 32 {
            if i == b.rawValue { return true }
            i = i < jsdomInterfaceParents.count ? jsdomInterfaceParents[i] : -1
            k += 1
        }
        return false
    }

    func nodeIs(_ n: HTMLNode, _ i: JSDOMInterface) -> Bool {
        switch i {
        case .EventTarget, .Node: return true
        case .Element: return n.kind == .element
        case .HTMLElement: return n.kind == .element && n.namespace == .html
        case .SVGElement: return n.kind == .element && n.namespace == .svg
        case .CharacterData: return n.kind == .text || n.kind == .comment
        case .Text: return n.kind == .text
        case .Comment: return n.kind == .comment && !isPI(n)
        case .Document: return n.kind == .document
        case .DocumentFragment: return n.kind == .documentFragment
        case .DocumentType: return n.kind == .doctype
        default: return inherits(nodeInterface(n), i)
        }
    }

    func nodeWrapperIsRoot(_ n: HTMLNode) -> Bool {
        if n.isConnected { return true }
        if let l = nodeListeners[ObjectIdentifier(n)], !l.items.isEmpty { return true }
        if let w = nodeClass.existingWrapper(for: n), heap.jsdomHasOwnProperties(w) { return true }
        return false
    }

    // MARK: Wrapping

    func wrapNode(_ n: HTMLNode?) -> JSValue {
        guard let n = n else { return .null }
        if let w = nodeClass.existingWrapper(for: n) { return w }
        let w = nodeClass.wrap(n)
        if w.isObject, n.kind == .element, n.namespace == .html, n.name == "form" || n.name == "select" {
            realm.makeExotic(w, handler: formExoticID)
        }
        if w.isObject, n.kind == .document { realm.makeExotic(w, handler: documentExoticID) }
        return w
    }

    func wrapEvent(_ e: JSDOMEvent?) -> JSValue {
        guard let e = e else { return .null }
        return eventClass.wrap(e)
    }

    func wrapTarget(_ t: JSDOMTarget?) -> JSValue {
        guard let t = t else { return .null }
        switch t {
        case .node(let n): return wrapNode(n)
        case .window: return realm.global
        case .object(let o): return classes.EventTargetObject.wrap(o)
        }
    }

    /// An array of node wrappers (rooted while it is built).
    func nodeArray(_ nodes: [HTMLNode]) -> JSValue {
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        var vals: [JSValue] = []
        vals.reserveCapacity(nodes.count)
        for n in nodes {
            let w = wrapNode(n)
            _ = heap.root(w)
            vals.append(w)
        }
        return heap.newArray(proto: realm.arrayPrototype, elements: vals)
    }

    func array(_ vals: [JSValue]) -> JSValue {
        heap.newArray(proto: realm.arrayPrototype, elements: vals)
    }

    func newObject() -> JSValue { heap.newObject(proto: realm.objectPrototype) }

    func setProp(_ o: JSValue, _ name: String, _ v: JSValue) {
        let d = heap.rootDepth
        _ = heap.root(o)
        _ = heap.root(v)
        _ = heap.createDataProperty(o, heap.key(name), v)
        heap.popRoots(to: d)
    }

    func getProp(_ o: JSValue, _ name: String) throws(JSThrow) -> JSValue {
        guard o.isObject else { return .undefined }
        return try realm.getV(o, heap.key(name))
    }

    // MARK: `this`

    func thisNode(_ v: JSValue, _ i: JSDOMInterface) -> HTMLNode? {
        guard let n = nodeClass.unwrap(v), nodeIs(n, i) else { return nil }
        return n
    }

    func thisEvent(_ v: JSValue, _ i: JSDOMInterface) -> JSDOMEvent? {
        guard let e = eventClass.unwrap(v), inherits(e.iface, i) else { return nil }
        return e
    }

    func thisTargetObject(_ v: JSValue, _ i: JSDOMInterface) -> JSDOMEventTargetObject? {
        guard let o = classes.EventTargetObject.unwrap(v), inherits(o.iface, i) else { return nil }
        return o
    }

    func thisTarget(_ v: JSValue) -> JSDOMTarget? {
        if v.isNullish || v == realm.global { return .window }
        if let n = nodeClass.unwrap(v) { return .node(n) }
        if let o = classes.EventTargetObject.unwrap(v) { return .object(o) }
        return nil
    }

    func thisWindow(_ v: JSValue) -> JSDOMBindings? {
        if v.isNullish || v == realm.global { return self }
        return nil
    }

    // MARK: Errors

    func ctx(_ iface: String, _ member: String) -> JSDOMCtx { JSDOMCtx(iface: iface, member: member) }

    func illegal(_ iface: String, _ member: String) -> JSThrow {
        realm.throwTypeError("Illegal invocation: " + iface + "." + member)
    }

    func notEnoughArguments(_ iface: String, _ member: String, _ need: Int, _ got: Int) -> JSThrow {
        let what = member == "constructor" ? "Failed to construct '" + iface + "'" : "Failed to execute '" + member + "' on '" + iface + "'"
        return realm.throwTypeError(what + ": " + String(need) + " argument" + (need == 1 ? "" : "s")
                                    + " required, but only " + String(got) + " present.")
    }

    func typeError(_ c: JSDOMCtx, _ msg: String) -> JSThrow {
        realm.throwTypeError("Failed to execute '" + c.member + "' on '" + c.iface + "': " + msg)
    }

    /// A DOMException object.
    func domException(_ name: String, _ message: String) -> JSValue {
        classes.DOMException.wrap(JSDOMExceptionData(name: name, message: message))
    }

    func throwDOM(_ name: String, _ message: String = "") -> JSThrow {
        let e = domException(name, message.isEmpty ? name : message)
        return realm.throwValue(e)
    }

    func throwDOM(_ e: HTMLDOMError) -> JSThrow {
        let msg: String
        switch e {
        case .hierarchyRequest: msg = "The operation would yield an incorrect node tree."
        case .notFound: msg = "The object can not be found here."
        case .invalidCharacter: msg = "The string contains invalid characters."
        case .syntax: msg = "The string did not match the expected pattern."
        case .noModificationAllowed: msg = "The object can not be modified."
        case .notSupported: msg = "The operation is not supported."
        }
        return throwDOM(e.name, msg)
    }

    // MARK: Conversions (WebIDL)

    func toStr(_ v: JSValue) throws(JSThrow) -> String {
        if v.isString { return heap.swiftString(v) }
        return try realm.toSwiftString(v)
    }

    func toStrNullEmpty(_ v: JSValue) throws(JSThrow) -> String {
        if v.isNull { return "" }
        return try toStr(v)
    }

    func toEnum(_ v: JSValue, _ allowed: [String], _ c: JSDOMCtx) throws(JSThrow) -> String {
        let s = try toStr(v)
        if !allowed.contains(s) { throw typeError(c, "'" + s + "' is not a valid enum value.") }
        return s
    }

    /// ToNumber, then WebIDL's integer conversion (modulo 2^bits).
    func intConv(_ v: JSValue, bits: Int, signed: Bool) throws(JSThrow) -> Int {
        if v.isInt32 {
            let i = Int(v.asInt32)
            if bits == 32 && signed { return i }
            if bits >= 32 && !signed && i >= 0 { return i }
        }
        let d = try realm.toNumber(v)
        if d.isNaN || d.isInfinite { return 0 }
        var t = d < 0 ? -((-d).rounded(.down)) : d.rounded(.down)
        if bits >= 53 {
            if t > 9_007_199_254_740_991 { t = 9_007_199_254_740_991 }
            if t < -9_007_199_254_740_991 { t = -9_007_199_254_740_991 }
            return Int(t)
        }
        let m = Double(Int64(1) << Int64(bits))
        var r = t.truncatingRemainder(dividingBy: m)
        if r < 0 { r += m }
        var i = Int(r)
        if signed && i >= Int(Int64(1) << Int64(bits - 1)) { i -= Int(Int64(1) << Int64(bits)) }
        return i
    }

    func toLong(_ v: JSValue) throws(JSThrow) -> Int { try intConv(v, bits: 32, signed: true) }
    func toUnsignedLong(_ v: JSValue) throws(JSThrow) -> Int { try intConv(v, bits: 32, signed: false) }
    func toShort(_ v: JSValue) throws(JSThrow) -> Int { try intConv(v, bits: 16, signed: true) }
    func toUnsignedShort(_ v: JSValue) throws(JSThrow) -> Int { try intConv(v, bits: 16, signed: false) }
    func toByte(_ v: JSValue) throws(JSThrow) -> Int { try intConv(v, bits: 8, signed: true) }
    func toOctet(_ v: JSValue) throws(JSThrow) -> Int { try intConv(v, bits: 8, signed: false) }
    func toLongLong(_ v: JSValue) throws(JSThrow) -> Int { try intConv(v, bits: 64, signed: true) }
    func toUnsignedLongLong(_ v: JSValue) throws(JSThrow) -> Int { max(0, try intConv(v, bits: 64, signed: true)) }

    func toDouble(_ v: JSValue, _ c: JSDOMCtx) throws(JSThrow) -> Double {
        let d = try realm.toNumber(v)
        if d.isNaN || d.isInfinite { throw typeError(c, "The provided double value is non-finite.") }
        return d
    }

    func toObjectArg(_ v: JSValue, nullable: Bool, _ c: JSDOMCtx) throws(JSThrow) -> JSValue {
        if nullable && v.isNullish { return .null }
        if !v.isObject { throw typeError(c, "parameter is not an object.") }
        return v
    }

    func toCallbackFunction(_ v: JSValue, nullable: Bool, _ c: JSDOMCtx) throws(JSThrow) -> JSValue {
        if nullable && v.isNullish { return .null }
        if !heap.isCallable(v) { throw typeError(c, "The callback provided as parameter is not a function.") }
        return v
    }

    func toCallbackInterface(_ v: JSValue, nullable: Bool, _ c: JSDOMCtx) throws(JSThrow) -> JSValue {
        if nullable && v.isNullish { return .null }
        if !v.isObject { throw typeError(c, "The callback provided as parameter is not an object.") }
        return v
    }

    func toNode(_ v: JSValue, _ i: JSDOMInterface, _ c: JSDOMCtx) throws(JSThrow) -> HTMLNode {
        guard let n = nodeClass.unwrap(v), nodeIs(n, i) else {
            throw typeError(c, "parameter is not of type '" + jsdomInterfaceNames[i.rawValue] + "'.")
        }
        return n
    }

    func toNodeOrNull(_ v: JSValue, _ i: JSDOMInterface, _ c: JSDOMCtx) throws(JSThrow) -> HTMLNode? {
        if v.isNullish { return nil }
        return try toNode(v, i, c)
    }

    func toEvent(_ v: JSValue, _ i: JSDOMInterface, _ c: JSDOMCtx) throws(JSThrow) -> JSDOMEvent {
        guard let e = thisEvent(v, i) else {
            throw typeError(c, "parameter is not of type '" + jsdomInterfaceNames[i.rawValue] + "'.")
        }
        return e
    }

    func toTarget(_ v: JSValue, _ c: JSDOMCtx) throws(JSThrow) -> JSDOMTarget {
        if v == realm.global { return .window }
        if let n = nodeClass.unwrap(v) { return .node(n) }
        if let o = classes.EventTargetObject.unwrap(v) { return .object(o) }
        throw typeError(c, "parameter is not of type 'EventTarget'.")
    }

    func toTargetObject(_ v: JSValue, _ i: JSDOMInterface, _ c: JSDOMCtx) throws(JSThrow) -> JSDOMEventTargetObject {
        guard let o = thisTargetObject(v, i) else {
            throw typeError(c, "parameter is not of type '" + jsdomInterfaceNames[i.rawValue] + "'.")
        }
        return o
    }

    func toObj<T: AnyObject>(_ cls: JSHostClass<T>, _ v: JSValue, _ c: JSDOMCtx) throws(JSThrow) -> T {
        guard let o = cls.unwrap(v) else { throw typeError(c, "parameter is not of type '" + cls.name + "'.") }
        return o
    }

    func toSequence<T>(_ v: JSValue, _ c: JSDOMCtx, _ conv: (JSValue) throws(JSThrow) -> T) throws(JSThrow) -> [T] {
        if !v.isObject { throw typeError(c, "The provided value cannot be converted to a sequence.") }
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        _ = heap.root(v)
        let (it, next) = try realm.getIterator(v)
        _ = heap.root(it)
        _ = heap.root(next)
        var out: [T] = []
        var n = 0
        while true {
            let (done, x) = try realm.iteratorStep(it, next)
            if done { break }
            _ = heap.root(x)
            out.append(try conv(x))
            n += 1
            if n > 10_000_000 { throw realm.throwRangeError("sequence too long") }
        }
        return out
    }

    // MARK: Results

    func str(_ s: String) -> JSValue { heap.newString(s) }
    func strOrNull(_ s: String?) -> JSValue { s.map { heap.newString($0) } ?? .null }
    func numOrNull(_ i: Int?) -> JSValue { i.map { JSValue.number($0) } ?? .null }
    func numOrNull(_ d: Double?) -> JSValue { d.map { JSValue.number($0) } ?? .null }

    /// [SameObject]: the cached result in the wrapper's slot, else make it.
    func sameObject(_ this: JSValue, slot: Int, _ make: () throws(JSThrow) -> JSValue) throws(JSThrow) -> JSValue {
        if this.isObject && slot < heap.slotCount(this) {
            let v = heap.slot(this, slot)
            if v.isObject { return v }
        }
        let v = try make()
        if this.isObject && v.isObject {
            let n = heap.slotCount(this)
            if slot >= n {
                var s: [JSValue] = []
                var i = 0
                while i < n { s.append(heap.slot(this, i)); i += 1 }
                while s.count <= slot { s.append(.undefined) }
                let d = heap.rootDepth
                _ = heap.root(v)
                heap.setSlots(this, s)
                heap.popRoots(to: d)
            }
            heap.setSlot(this, slot, v)
        }
        return v
    }

    /// A per-wrapper hidden value (for values only JS can hold, e.g.
    /// CustomEvent.detail): slots after the [SameObject] caches.
    func hiddenSlot(_ o: JSValue, _ k: Int) -> JSValue {
        let i = jsdomSameObjectSlotCount + k
        return i < heap.slotCount(o) ? heap.slot(o, i) : .undefined
    }

    func setHiddenSlot(_ o: JSValue, _ k: Int, _ v: JSValue) {
        guard o.isObject else { return }
        let i = jsdomSameObjectSlotCount + k
        let n = heap.slotCount(o)
        if i >= n {
            var s: [JSValue] = []
            var j = 0
            while j < n { s.append(heap.slot(o, j)); j += 1 }
            while s.count <= i { s.append(.undefined) }
            let d = heap.rootDepth
            _ = heap.root(o)
            _ = heap.root(v)
            heap.setSlots(o, s)
            heap.popRoots(to: d)
        }
        heap.setSlot(o, i, v)
    }

    // MARK: Reflection

    func reflectURL(_ n: HTMLNode, _ name: String) -> String {
        guard let v = n.attribute(name) else { return "" }
        return resolveURL(v) ?? v
    }

    func reflectInt(_ n: HTMLNode, _ name: String, default d: Int, unsigned: Bool) -> Int {
        guard let v = n.attribute(name), let i = jsdomParseInteger(v) else { return d }
        if unsigned && i < 0 { return d }
        if i > 2_147_483_647 || i < -2_147_483_648 { return d }
        return i
    }

    func reflectSetBool(_ n: HTMLNode, _ name: String, _ v: Bool) throws(JSThrow) {
        if v { n.setAttributeValue(name, "") } else { n.removeAttribute(name) }
    }

    func reflectSetString(_ n: HTMLNode, _ name: String, _ v: String) throws(JSThrow) {
        n.setAttributeValue(name, v)
    }

    func reflectSetStringOrNull(_ n: HTMLNode, _ name: String, _ v: String?) throws(JSThrow) {
        if let s = v { n.setAttributeValue(name, s) } else { n.removeAttribute(name) }
    }

    func reflectSetInt(_ n: HTMLNode, _ name: String, _ v: Int) throws(JSThrow) {
        n.setAttributeValue(name, String(v))
    }

    /// [Replaceable]: shadow the accessor with a data property.
    func replaceAttribute(_ this: JSValue, _ name: String, _ v: JSValue) throws(JSThrow) {
        let o = this.isNullish ? realm.global : this
        guard o.isObject else { return }
        try realm.objDefinePropertyOrThrow(o, heap.key(name),
            JSPropertyDescriptor(value: v, writable: true, enumerable: true, configurable: true))
    }

    // MARK: Definition helpers (generated code)

    func makePrototype(_ i: JSDOMInterface, parent: JSDOMInterface?) {
        let pp = parent.map { protos[$0.rawValue] } ?? realm.objectPrototype
        let p = heap.newObject(proto: pp)
        protos[i.rawValue] = p
        // @@toStringTag, so Object.prototype.toString says [object HTMLDivElement].
        let tag = heap.newString(jsdomInterfaceNames[i.rawValue])
        let d = heap.rootDepth
        _ = heap.root(tag)
        _ = heap.defineOwnProperty(p, .symbol(heap.symbolsWellKnown.toStringTag.handle), .data(tag, [.configurable]))
        heap.popRoots(to: d)
    }

    @discardableResult
    func defineInterfaceObject(_ i: JSDOMInterface, length: Int, _ ctor: JSNativeFunction?) -> JSValue {
        let name = jsdomInterfaceNames[i.rawValue]
        let p = protos[i.rawValue]
        let f = realm.defineConstructor(name, length: length, prototype: p) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            guard let c = ctor else { throw realm.throwTypeError("Illegal constructor") }
            return try c(realm, args)
        }
        ctors[i.rawValue] = f
        let parent = jsdomInterfaceParents[i.rawValue]
        if parent >= 0, ctors[parent].isObject { _ = heap.setPrototypeOf(f, ctors[parent]) }
        return f
    }

    func defineConstant(_ p: JSValue, _ ctor: JSValue, _ name: String, _ v: Int) {
        realm.defineValue(p, name, .number(v), [.enumerable])
        if ctor.isObject { realm.defineValue(ctor, name, .number(v), [.enumerable]) }
    }

    /// iterable<T> on an indexed object: Array.prototype's iteration methods.
    func defineValueIterator(_ p: JSValue) {
        let ap = realm.arrayPrototype
        for name in ["entries", "keys", "values", "forEach"] {
            if case .value(let f) = heap.getProperty(ap, heap.key(name)) {
                realm.defineValue(p, name, f, [.writable, .enumerable, .configurable])
            }
        }
        _ = heap.defineOwnProperty(p, .symbol(heap.symbolsWellKnown.iterator.handle),
                                   .data(realm.intrinsic(.arrayValues), [.writable, .configurable]))
    }

    /// Indexed objects without iterable<T> (HTMLCollection) still get @@iterator.
    func defineIndexedIterator(_ p: JSValue) {
        _ = heap.defineOwnProperty(p, .symbol(heap.symbolsWellKnown.iterator.handle),
                                   .data(realm.intrinsic(.arrayValues), [.writable, .configurable]))
    }

    /// A WebIDL attribute: an enumerable, configurable accessor.
    func defineAttribute(_ obj: JSValue, _ name: String, setter: JSNativeFunction?, _ getter: @escaping JSNativeFunction) {
        let r = heap.root(obj)
        let g = realm.newNativeFunction(realm.registerNative("get " + name, length: 0, getter))
        _ = heap.root(g)
        var s: JSValue = .undefined
        if let st = setter {
            s = realm.newNativeFunction(realm.registerNative("set " + name, length: 1, st))
            _ = heap.root(s)
        }
        _ = heap.defineOwnProperty(obj, heap.key(name), .accessor(get: g, set: s, [.enumerable, .configurable]))
        heap.popRoots(to: r.slot)
    }

    /// A WebIDL operation: an enumerable, writable, configurable method.
    func defineOperation(_ obj: JSValue, _ name: String, length: Int, _ fn: @escaping JSNativeFunction) {
        let r = heap.root(obj)
        let f = realm.newNativeFunction(realm.registerNative(name, length: length, fn))
        _ = heap.root(f)
        _ = heap.defineOwnProperty(obj, heap.key(name), .data(f, [.writable, .enumerable, .configurable]))
        heap.popRoots(to: r.slot)
    }

    func defineStringifier(_ p: JSValue, _ i: JSDOMInterface) {}

    /// `stringifier attribute`: toString() returns the attribute.
    func defineStringifierFrom(_ p: JSValue, _ name: String, method: Bool = false) {
        if method { return }
        let k = heap.key(name)
        realm.defineMethod(p, "toString", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            if !args.this.isObject { throw realm.throwTypeError("Illegal invocation") }
            return try realm.toStringValue(try realm.getV(args.this, k))
        }
    }

    func defineNamespaceObject(_ name: String) -> JSValue {
        let o = newObject()
        realm.defineGlobal(name, o)
        return o
    }

    func defineFactoryFunction(_ name: String, _ i: JSDOMInterface, _ fn: @escaping JSNativeFunction) {
        let f = realm.defineConstructor(name, length: 0, prototype: protos[i.rawValue], fn)
        // `Image.prototype.constructor` stays HTMLImageElement.
        if ctors[i.rawValue].isObject {
            _ = heap.defineOwnProperty(protos[i.rawValue], heap.names.constructor, .data(ctors[i.rawValue], [.writable, .configurable]))
        }
        keep.append(f)
    }

    func isHTMLDocument(_ d: HTMLNode) -> Bool { !xmlDocuments.contains(ObjectIdentifier(d)) }

    // MARK: URLs

    var baseURL: URLRecord? {
        if let b = document.firstElement(where: { $0.namespace == .html && $0.name == "base" && $0.attribute("href") != nil }),
           let h = b.attribute("href"), let u = url, let r = u.resolve(h) {
            return r
        }
        return url
    }

    func resolveURL(_ s: String) -> String? {
        guard let b = baseURL else { return URLRecord.parseOrNil(s)?.href }
        return b.resolve(s)?.href
    }
}

extension JSHeap {
    /// True if the object has any own property (expandos on a wrapper).
    func jsdomHasOwnProperties(_ v: JSValue) -> Bool {
        guard let i = objectIndex(v) else { return false }
        let c = objects[i]
        return c.props.count > Int(c.deletedCount) || !c.elements.isEmpty || !c.sparse.isEmpty
    }
}

/// HTML elements whose interface is plain HTMLElement.
func jsdomIsPlainHTMLElementName(_ n: String) -> Bool {
    switch n {
    case "article", "section", "nav", "aside", "hgroup", "header", "footer", "address", "main", "search",
         "figure", "figcaption", "dt", "dd", "em", "strong", "small", "s", "cite", "dfn", "abbr", "ruby", "rt",
         "rp", "code", "var", "samp", "kbd", "sub", "sup", "i", "b", "u", "mark", "bdi", "bdo", "wbr", "summary",
         "noscript", "acronym", "basefont", "big", "center", "nobr", "noembed", "noframes", "plaintext", "rb",
         "rtc", "strike", "tt", "image", "menuitem", "selectedcontent", "keygen", "marquee", "math":
        return true
    default: return false
    }
}

/// HTML's "rules for parsing integers" (leading whitespace, sign, digits).
func jsdomParseInteger(_ s: String) -> Int? {
    var it = Array(s.utf8)[...]
    while let f = it.first, f == 0x20 || f == 0x09 || f == 0x0a || f == 0x0c || f == 0x0d { it = it.dropFirst() }
    var neg = false
    if let f = it.first, f == 0x2d || f == 0x2b { neg = f == 0x2d; it = it.dropFirst() }
    var v = 0
    var any = false
    for b in it {
        guard b >= 0x30 && b <= 0x39 else { break }
        any = true
        if v < 10_000_000_000 { v = v * 10 + Int(b - 0x30) }
    }
    return any ? (neg ? -v : v) : nil
}

/// The DOMException payload.
final class JSDOMExceptionData {
    let name: String
    let message: String
    init(name: String, message: String) { self.name = name; self.message = message }

    var code: Int {
        switch name {
        case "IndexSizeError": return 1
        case "HierarchyRequestError": return 3
        case "WrongDocumentError": return 4
        case "InvalidCharacterError": return 5
        case "NoModificationAllowedError": return 7
        case "NotFoundError": return 8
        case "NotSupportedError": return 9
        case "InUseAttributeError": return 10
        case "InvalidStateError": return 11
        case "SyntaxError": return 12
        case "InvalidModificationError": return 13
        case "NamespaceError": return 14
        case "InvalidAccessError": return 15
        case "TypeMismatchError": return 17
        case "SecurityError": return 18
        case "NetworkError": return 19
        case "AbortError": return 20
        case "URLMismatchError": return 21
        case "QuotaExceededError": return 22
        case "TimeoutError": return 23
        case "InvalidNodeTypeError": return 24
        case "DataCloneError": return 25
        default: return 0
        }
    }
}

extension JSDOMBindings {
    func DOMException_constructor(_ message: String, _ name: String, newTarget: JSValue) throws(JSThrow) -> JSValue {
        let w = domException(name, message)
        if newTarget.isObject, case .value(let p) = heap.getProperty(newTarget, heap.names.prototype), p.isObject,
           p != protos[JSDOMInterface.DOMException.rawValue] {
            _ = heap.setPrototypeOf(w, p)
        }
        return w
    }
    func DOMException_name(_ this: JSDOMExceptionData) -> String { this.name }
    func DOMException_message(_ this: JSDOMExceptionData) -> String { this.message }
    func DOMException_code(_ this: JSDOMExceptionData) -> Int { this.code }
}

func jsdomHasSubstring(_ s: String, _ sub: String) -> Bool {
    let a = Array(s.utf8), b = Array(sub.utf8)
    if b.isEmpty { return true }
    if b.count > a.count { return false }
    var i = 0
    while i + b.count <= a.count {
        var j = 0
        while j < b.count && a[i + j] == b[j] { j += 1 }
        if j == b.count { return true }
        i += 1
    }
    return false
}
