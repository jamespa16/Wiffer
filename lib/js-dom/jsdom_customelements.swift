// Custom elements (ROADMAP Phase 9I; HTML Standard "Custom elements").
//
// customElements.define / get / getName / whenDefined / upgrade, the
// HTMLElement constructor ([HTMLConstructor]: `class extends HTMLElement`,
// definition lookup by new.target, the construction stack), upgrades,
// synchronous construction from document.createElement, and the reactions
// (connectedCallback, disconnectedCallback, adoptedCallback,
// attributeChangedCallback with observedAttributes) on the custom element
// reaction stack and the backup element queue.
//
// [CEReactions]: the generated glue wraps every member the IDL marks
// (jsdomCEReactionMembers) in ceReactions { ... }: push an element queue,
// run the member, pop the queue and invoke its reactions. Reactions queued
// with an empty stack (browser-driven mutations, the event loop) go to the
// backup element queue, processed from one microtask.
//
// Where reactions come from: lib/html's synchronous mutation records (the
// page's observer, domMutated) are the DOM's "insert" / "remove" /
// "change an attribute" hooks: an insertion connects custom elements
// (connectedCallback) or tries to upgrade undefined ones, a removal from a
// connected parent disconnects, an attribute record on a custom element
// queues attributeChangedCallback, and a custom element seen in a new
// document gets adoptedCallback. Records are delivered right after each
// primitive, so the reactions are queued in the same order as the spec's.
//
// Elements created by the parser before define() are "undefined" (lib/html
// sets that from the name) and are upgraded by define, in shadow-including
// tree order. Fragment parsing (innerHTML) creates elements in an inert
// document as the spec does, so they upgrade when they are connected.
// Customized built-ins (`is=`, define's `extends`) are not supported
// (NotSupportedError), as in Safari. A custom element's wrapper is the
// object its constructor returned; it is a GC root for the page's lifetime
// (class fields and private names live on it).

final class JSDOMCERegistry { init() {} }

final class JSDOMCEDefinition {
    let name: String
    let localName: String
    let ctor: JSValue
    let prototype: JSValue
    var connected: JSValue = .undefined
    var disconnected: JSValue = .undefined
    var adopted: JSValue = .undefined
    var attributeChanged: JSValue = .undefined
    var connectedMove: JSValue = .undefined
    var observed: [String] = []
    var formAssociated = false
    var disableInternals = false
    var disableShadow = false
    /// The construction stack (nil = the "already constructed" marker).
    var constructionStack: [HTMLNode?] = []

    init(name: String, localName: String, ctor: JSValue, prototype: JSValue) {
        self.name = name
        self.localName = localName
        self.ctor = ctor
        self.prototype = prototype
    }

    func mark(_ h: JSHeap) {
        h.markValue(ctor)
        h.markValue(prototype)
        h.markValue(connected)
        h.markValue(disconnected)
        h.markValue(adopted)
        h.markValue(attributeChanged)
        h.markValue(connectedMove)
    }

    func callback(_ name: String) -> JSValue {
        switch name {
        case "connectedCallback": return connected
        case "disconnectedCallback": return disconnected
        case "adoptedCallback": return adopted
        case "attributeChangedCallback": return attributeChanged
        case "connectedMoveCallback": return connectedMove
        default: return .undefined
        }
    }
}

enum JSDOMCEReaction {
    case upgrade(JSDOMCEDefinition)
    case callback(JSValue, [JSValue])
}

/// A custom element: its definition and the document it was last seen in
/// (for adoptedCallback).
struct JSDOMCEElement {
    let node: HTMLNode
    let definition: JSDOMCEDefinition
    var document: HTMLNode?
}

final class JSDOMElementInternals {
    let target: HTMLNode
    var states: JSValue = .undefined
    init(_ t: HTMLNode) { target = t }
}

/// Per-page custom element state (one registry per window).
final class JSDOMCEState {
    var definitions: [String: JSDOMCEDefinition] = [:]
    var order: [JSDOMCEDefinition] = []
    var definitionRunning = false
    var elements: [ObjectIdentifier: JSDOMCEElement] = [:]
    var queues: [ObjectIdentifier: [JSDOMCEReaction]] = [:]
    var stack: [[HTMLNode]] = []
    var backup: [HTMLNode] = []
    var backupScheduled = false
    var backupProcessor: JSValue = .undefined
    var whenDefined: [String: JSValue] = [:]
    /// createElement whose constructor failed: HTMLUnknownElement.
    var unknown: Set<ObjectIdentifier> = []
    var internals: [ObjectIdentifier: JSDOMElementInternals] = [:]
    var registry: JSDOMCERegistry? = nil
    init() {}

    func release() {
        definitions = [:]
        order = []
        elements = [:]
        queues = [:]
        stack = []
        backup = []
        whenDefined = [:]
        internals = [:]
    }

    func mark(_ h: JSHeap) {
        for d in order { d.mark(h) }
        for (_, q) in queues {
            for r in q {
                if case .callback(let f, let args) = r {
                    h.markValue(f)
                    for a in args { h.markValue(a) }
                }
            }
        }
        h.markValue(backupProcessor)
        for (_, p) in whenDefined { h.markValue(p) }
        for (_, i) in internals { h.markValue(i.states) }
    }
}

let jsdomCEMaxReactions = 1_000_000

extension JSDOMBindings {
    // MARK: [CEReactions]

    /// Run a [CEReactions] member: push an element queue, run `body`, pop
    /// the queue and invoke its reactions (the result stays rooted).
    func ceReactions(_ body: () throws(JSThrow) -> JSValue) throws(JSThrow) -> JSValue {
        if ce.stack.count >= 10_000 { throw realm.throwRangeError("Maximum custom element reaction depth exceeded") }
        ce.stack.append([])
        let r: JSValue
        do throws(JSThrow) {
            r = try body()
        } catch {
            let q = ce.stack.removeLast()
            if !realm.isTerminating {
                // The member's exception stays pending while reactions run.
                let saved = realm.pendingException
                let d = heap.rootDepth
                _ = heap.root(saved)
                let savedTrace = realm.trace
                realm.exception = .undefined
                ceInvoke(q)
                realm.exception = saved
                realm.trace = savedTrace
                heap.popRoots(to: d)
            }
            throw error
        }
        let q = ce.stack.removeLast()
        if q.isEmpty { return r }
        let d = heap.rootDepth
        _ = heap.root(r)
        ceInvoke(q)
        heap.popRoots(to: d)
        if realm.isTerminating { throw JSThrow() }
        return r
    }

    /// [CEReactions] around hand-written members (DOMStringMap, style
    /// properties).
    func ceRun(_ body: () throws(JSThrow) -> Void) throws(JSThrow) {
        _ = try ceReactions { () throws(JSThrow) -> JSValue in
            try body()
            return .undefined
        }
    }

    /// "Enqueue an element on the appropriate element queue".
    func ceEnqueueElement(_ el: HTMLNode) {
        if !ce.stack.isEmpty {
            ce.stack[ce.stack.count - 1].append(el)
            return
        }
        ce.backup.append(el)
        if ce.backupScheduled { return }
        ce.backupScheduled = true
        if !ce.backupProcessor.isObject {
            unowned(unsafe) let b = self
            let idx = realm.registerNative("processBackupElementQueue", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
                b.ceProcessBackup()
                if realm.isTerminating { throw JSThrow() }
                return .undefined
            }
            ce.backupProcessor = realm.newNativeFunction(idx)
        }
        realm.enqueueJob(ce.backupProcessor, args: [])
    }

    func ceProcessBackup() {
        var rounds = 0
        while !ce.backup.isEmpty && rounds < 10_000 {
            rounds += 1
            let q = ce.backup
            ce.backup = []
            ceInvoke(q)
            if realm.isTerminating { ce.backup = []; break }
        }
        ce.backupScheduled = false
    }

    /// "Invoke custom element reactions" in an element queue.
    func ceInvoke(_ queue: [HTMLNode]) {
        var budget = jsdomCEMaxReactions
        for el in queue {
            let id = ObjectIdentifier(el)
            while budget > 0 {
                guard var q = ce.queues[id], !q.isEmpty else { break }
                let r = q.removeFirst()
                ce.queues[id] = q.isEmpty ? nil : q
                budget -= 1
                if realm.isTerminating { ce.queues[id] = nil; continue }
                switch r {
                case .upgrade(let def):
                    ceUpgrade(el, def)
                case .callback(let f, let args):
                    let d = heap.rootDepth
                    _ = heap.root(f)
                    for a in args { _ = heap.root(a) }
                    let w = wrapNode(el)
                    _ = heap.root(w)
                    _ = try? runScriptCallback(f, this: w, args: args)
                    heap.popRoots(to: d)
                }
            }
        }
    }

    // MARK: Reactions

    func ceIsCustom(_ el: HTMLNode) -> JSDOMCEDefinition? {
        guard el.kind == .element, let e = ce.elements[ObjectIdentifier(el)], el.customElementState == .custom else { return nil }
        return e.definition
    }

    /// "Enqueue a custom element callback reaction".
    func ceEnqueueCallback(_ el: HTMLNode, _ name: String, _ args: [JSValue]) {
        guard let e = ce.elements[ObjectIdentifier(el)] else { return }
        let def = e.definition
        let f = def.callback(name)
        if !f.isObject { return }
        if name == "attributeChangedCallback" {
            guard let a = args.first, a.isString, def.observed.contains(heap.swiftString(a)) else { return }
        }
        let id = ObjectIdentifier(el)
        var q = ce.queues[id] ?? []
        if q.count >= jsdomCEMaxReactions { return }
        q.append(.callback(f, args))
        ce.queues[id] = q
        ceEnqueueElement(el)
    }

    func ceEnqueueUpgrade(_ el: HTMLNode, _ def: JSDOMCEDefinition) {
        let id = ObjectIdentifier(el)
        var q = ce.queues[id] ?? []
        if q.count >= jsdomCEMaxReactions { return }
        q.append(.upgrade(def))
        ce.queues[id] = q
        ceEnqueueElement(el)
    }

    /// "Look up a custom element definition" (autonomous only; documents
    /// without a browsing context have none).
    func ceLookup(_ doc: HTMLNode?, _ el: HTMLNode) -> JSDOMCEDefinition? {
        guard doc === document, el.kind == .element, el.namespace == .html, !ce.definitions.isEmpty else { return nil }
        return ce.definitions[el.name]
    }

    /// "Try to upgrade an element".
    func ceTryUpgrade(_ el: HTMLNode) {
        guard el.customElementState == .undefined, let def = ceLookup(el.nodeDocument, el) else { return }
        ceEnqueueUpgrade(el, def)
    }

    /// The page's mutation observer, before anything else: custom element
    /// reactions for insertions, removals and attribute changes.
    func ceMutated(_ m: HTMLMutation) {
        switch m.kind {
        case .childList:
            if !m.removedNodes.isEmpty && m.target.isConnected && !ce.elements.isEmpty {
                for r in m.removedNodes {
                    r.walkShadowIncluding { n in
                        if self.ceIsCustom(n) != nil { self.ceEnqueueCallback(n, "disconnectedCallback", []) }
                        return true
                    }
                }
            }
            for a in m.addedNodes {
                a.walkShadowIncluding { n in
                    if n.kind != .element { return true }
                    let id = ObjectIdentifier(n)
                    if var e = self.ce.elements[id], e.document !== n.nodeDocument {
                        let old = e.document
                        e.document = n.nodeDocument
                        self.ce.elements[id] = e
                        if n.customElementState == .custom { self.ceAdopted(n, from: old) }
                    }
                    if n.isConnected {
                        if self.ceIsCustom(n) != nil { self.ceEnqueueCallback(n, "connectedCallback", []) }
                        else { self.ceTryUpgrade(n) }
                    }
                    return true
                }
            }
        case .attributes:
            let el = m.target
            guard let def = ceIsCustom(el), def.attributeChanged.isObject else { return }
            let local = attrLocalName(el, m.attributeName)
            if !def.observed.contains(local) { return }
            let ns = attrNamespace(el, m.attributeName)
            let d = heap.rootDepth
            let a0 = str(local); _ = heap.root(a0)
            let a1 = strOrNull(m.oldValue); _ = heap.root(a1)
            let a2 = strOrNull(el.attribute(m.attributeName)); _ = heap.root(a2)
            let a3 = strOrNull(ns); _ = heap.root(a3)
            ceEnqueueCallback(el, "attributeChangedCallback", [a0, a1, a2, a3])
            heap.popRoots(to: d)
        default:
            break
        }
    }

    func ceAdopted(_ el: HTMLNode, from old: HTMLNode?) {
        let d = heap.rootDepth
        let a0 = wrapNode(old); _ = heap.root(a0)
        let a1 = wrapNode(el.nodeDocument); _ = heap.root(a1)
        ceEnqueueCallback(el, "adoptedCallback", [a0, a1])
        heap.popRoots(to: d)
    }

    /// adoptNode moved `n` from `old`: adoptedCallback for its custom
    /// elements (before any insertion's connectedCallback).
    func ceAdoptedSubtree(_ n: HTMLNode, from old: HTMLNode?) {
        if ce.elements.isEmpty || old === n.nodeDocument { return }
        n.walkShadowIncluding { x in
            let id = ObjectIdentifier(x)
            if var e = self.ce.elements[id], e.document !== x.nodeDocument {
                let prev = e.document
                e.document = x.nodeDocument
                self.ce.elements[id] = e
                if x.customElementState == .custom { self.ceAdopted(x, from: prev) }
            }
            return true
        }
    }

    /// A clone or import in the page's document: undefined custom elements
    /// with a definition get an upgrade reaction (create an element with
    /// the synchronous custom elements flag unset).
    func ceCloned(_ c: HTMLNode) {
        if ce.definitions.isEmpty { return }
        c.walkShadowIncluding { n in
            self.ceTryUpgrade(n)
            return true
        }
    }

    // MARK: Construction

    /// [[Construct]] of a definition's constructor as a callback.
    func ceConstruct(_ f: JSValue) -> JSCompletion {
        let outer = realm.nativeDepth == 0 && realm.frames.isEmpty
        if outer { realm.stackFloor = jsVMStackFloor(realm.limits) }
        do throws(JSThrow) {
            let v = try realm.construct(f, args: [])
            if outer && heap.termination == .interrupted { heap.clearTermination() }
            return .normal(v)
        } catch {
            return realm.finishCompletion(outer: outer)
        }
    }

    /// Report the pending exception (thrown by us, not by script).
    func ceReportPending() {
        if realm.isTerminating { return }
        if case .exception(let u) = realm.finishCompletion(outer: false) { reportUncaught(u) }
    }

    /// "Upgrade an element".
    func ceUpgrade(_ el: HTMLNode, _ def: JSDOMCEDefinition) {
        let st = el.customElementState
        if st != .undefined && st != .uncustomized { return }
        let id = ObjectIdentifier(el)
        ce.elements[id] = JSDOMCEElement(node: el, definition: def, document: el.nodeDocument)
        el.setCustomElementState(.failed)
        if def.attributeChanged.isObject {
            for a in el.attributes {
                let d = heap.rootDepth
                let local = attrLocalName(el, a.name)
                let a0 = str(local); _ = heap.root(a0)
                let a2 = str(a.value); _ = heap.root(a2)
                let a3 = strOrNull(attrNamespace(el, a.name)); _ = heap.root(a3)
                ceEnqueueCallback(el, "attributeChangedCallback", [a0, .null, a2, a3])
                heap.popRoots(to: d)
            }
        }
        if el.isConnected { ceEnqueueCallback(el, "connectedCallback", []) }
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        let w = wrapNode(el)
        _ = heap.root(w)
        var ok = true
        if def.disableShadow && el.attachedShadowRoot != nil {
            _ = throwDOM("NotSupportedError", "Failed to upgrade '" + def.name + "': the element has a shadow root and its definition disables shadow.")
            ceReportPending()
            ok = false
        } else {
            el.setCustomElementState(.precustomized)
            def.constructionStack.append(el)
            let c = ceConstruct(def.ctor)
            if !def.constructionStack.isEmpty { def.constructionStack.removeLast() }
            switch c {
            case .normal(let v):
                if v != w {
                    _ = realm.throwTypeError("Failed to upgrade '" + def.name + "': the constructor did not return the element.")
                    ceReportPending()
                    ok = false
                }
            case .exception(let u):
                reportUncaught(u)
                ok = false
            case .terminated:
                ok = false
            }
        }
        if !ok {
            ce.elements[id] = nil
            ce.queues[id] = nil
            el.setCustomElementState(.failed)
            return
        }
        el.setCustomElementState(.custom)
    }

    /// HTMLElement's constructor ([HTMLConstructor]).
    func HTMLElement_constructor(newTarget: JSValue) throws(JSThrow) -> JSValue {
        let active = ctors[JSDOMInterface.HTMLElement.rawValue]
        if !newTarget.isObject || newTarget == active { throw realm.throwTypeError("Illegal constructor") }
        guard let def = ce.order.first(where: { $0.ctor == newTarget }) else {
            throw realm.throwTypeError("Illegal constructor: this constructor is not a defined custom element")
        }
        var proto = try realm.getV(newTarget, heap.names.prototype)
        if !proto.isObject { proto = protos[JSDOMInterface.HTMLElement.rawValue] }
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        _ = heap.root(proto)
        if def.constructionStack.isEmpty {
            let el = document.makeElement(def.localName, .html)
            ce.elements[ObjectIdentifier(el)] = JSDOMCEElement(node: el, definition: def, document: document)
            el.setCustomElementState(.custom)
            let w = wrapNode(el)
            if w.isObject { _ = heap.setPrototypeOf(w, proto) }
            return w
        }
        guard let last = def.constructionStack.last, let el = last else {
            throw realm.throwTypeError("Failed to construct 'HTMLElement': this instance is already constructed")
        }
        let w = wrapNode(el)
        if w.isObject { _ = heap.setPrototypeOf(w, proto) }
        def.constructionStack[def.constructionStack.count - 1] = nil
        return w
    }

    /// document.createElement(NS) of a defined custom element: construct it
    /// synchronously; on failure report and return an HTMLUnknownElement
    /// in the failed state.
    func ceCreateSync(_ def: JSDOMCEDefinition) throws(JSThrow) -> HTMLNode {
        let c = ceConstruct(def.ctor)
        switch c {
        case .normal(let v):
            let d = heap.rootDepth
            _ = heap.root(v)
            defer { heap.popRoots(to: d) }
            var problem = ""
            if let el = nodeClass.unwrap(v), el.kind == .element, el.namespace == .html {
                if !el.attributes.isEmpty { problem = "The result must not have attributes" }
                else if !el.children.isEmpty { problem = "The result must not have children" }
                else if el.parent != nil { problem = "The result must not have a parent" }
                else if el.nodeDocument !== document { problem = "The result must be in the same document" }
                else if el.name != def.localName { problem = "The result must have the same localName" }
                if problem.isEmpty { return el }
                _ = throwDOM("NotSupportedError", "Failed to create '" + def.name + "': " + problem + ".")
            } else {
                _ = realm.throwTypeError("Failed to create '" + def.name + "': the constructor did not return an HTMLElement.")
            }
            ceReportPending()
        case .exception(let u):
            reportUncaught(u)
        case .terminated:
            throw JSThrow()
        }
        let el = document.makeElement(def.localName, .html)
        el.setCustomElementState(.failed)
        ce.unknown.insert(ObjectIdentifier(el))
        return el
    }

    // MARK: CustomElementRegistry

    func Window_customElements(_ w: JSDOMBindings) -> JSValue {
        if ce.registry == nil { ce.registry = JSDOMCERegistry() }
        guard let r = ce.registry else { return .undefined }
        let v = classes.CustomElementRegistry.wrap(r)
        classes.CustomElementRegistry.pin(r, true)
        return v
    }

    func CustomElementRegistry_define(_ r: JSDOMCERegistry, _ name: String, _ ctor: JSValue, _ options: JSValue) throws(JSThrow) {
        let what = "Failed to execute 'define' on 'CustomElementRegistry': "
        if !realm.isConstructor(ctor) { throw realm.throwTypeError(what + "parameter 2 is not a constructor.") }
        if !htmlIsValidCustomElementName(name) {
            throw throwDOM("SyntaxError", what + "\"" + name + "\" is not a valid custom element name")
        }
        if ce.definitions[name] != nil {
            throw throwDOM("NotSupportedError", what + "the name \"" + name + "\" has already been used with this registry")
        }
        if ce.order.contains(where: { $0.ctor == ctor }) {
            throw throwDOM("NotSupportedError", what + "this constructor has already been used with this registry")
        }
        if options.isObject {
            let ext = try realm.getV(options, heap.key("extends"))
            if !ext.isUndefined && !ext.isNull {
                throw throwDOM("NotSupportedError", what + "customized built-in elements are not supported")
            }
        } else if !options.isUndefined && !options.isNull {
            throw realm.throwTypeError(what + "parameter 3 is not an object.")
        }
        if ce.definitionRunning {
            throw throwDOM("NotSupportedError", what + "this registry is already defining an element")
        }
        ce.definitionRunning = true
        defer { ce.definitionRunning = false }
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        let proto = try realm.getV(ctor, heap.names.prototype)
        _ = heap.root(proto)
        if !proto.isObject { throw realm.throwTypeError(what + "the constructor's prototype is not an object.") }
        let def = JSDOMCEDefinition(name: name, localName: name, ctor: ctor, prototype: proto)
        // (connectedMoveCallback too once moveBefore exists.)
        for cb in ["connectedCallback", "disconnectedCallback", "adoptedCallback", "attributeChangedCallback"] {
            let v = try realm.getV(proto, heap.key(cb))
            if v.isUndefined { continue }
            _ = heap.root(v)
            if !heap.isCallable(v) { throw realm.throwTypeError(what + "the '" + cb + "' property is not a function.") }
            switch cb {
            case "connectedCallback": def.connected = v
            case "disconnectedCallback": def.disconnected = v
            case "adoptedCallback": def.adopted = v
            case "attributeChangedCallback": def.attributeChanged = v
            default: def.connectedMove = v
            }
        }
        if def.attributeChanged.isObject {
            let oa = try realm.getV(ctor, heap.key("observedAttributes"))
            if !oa.isUndefined {
                def.observed = try toSequence(oa, ctx("CustomElementRegistry", "define")) { (v: JSValue) throws(JSThrow) -> String in try self.toStr(v) }
            }
        }
        let df = try realm.getV(ctor, heap.key("disabledFeatures"))
        if !df.isUndefined {
            let feats = try toSequence(df, ctx("CustomElementRegistry", "define")) { (v: JSValue) throws(JSThrow) -> String in try self.toStr(v) }
            def.disableInternals = feats.contains("internals")
            def.disableShadow = feats.contains("shadow")
        }
        let fa = try realm.getV(ctor, heap.key("formAssociated"))
        def.formAssociated = heap.toBoolean(fa)
        if def.formAssociated {
            for cb in ["formAssociatedCallback", "formResetCallback", "formDisabledCallback", "formStateRestoreCallback"] {
                let v = try realm.getV(proto, heap.key(cb))
                if !v.isUndefined && !heap.isCallable(v) { throw realm.throwTypeError(what + "the '" + cb + "' property is not a function.") }
            }
        }
        ce.definitionRunning = false
        ce.definitions[name] = def
        ce.order.append(def)
        // Upgrade candidates in shadow-including tree order.
        document.walkShadowIncluding { n in
            if n.kind == .element && n.namespace == .html && n.name == name && n.customElementState == .undefined {
                self.ceEnqueueUpgrade(n, def)
            }
            return true
        }
        if let p = ce.whenDefined[name] {
            ce.whenDefined[name] = nil
            _ = heap.root(p)
            try realm.resolvePromise(p, ctor)
        }
    }

    func CustomElementRegistry_get(_ r: JSDOMCERegistry, _ name: String) -> JSValue {
        ce.definitions[name]?.ctor ?? .undefined
    }

    func CustomElementRegistry_getName(_ r: JSDOMCERegistry, _ ctor: JSValue) throws(JSThrow) -> String? {
        if !realm.isConstructor(ctor) {
            throw realm.throwTypeError("Failed to execute 'getName' on 'CustomElementRegistry': parameter 1 is not of type 'CustomElementConstructor'.")
        }
        return ce.order.first(where: { $0.ctor == ctor })?.name
    }

    func CustomElementRegistry_whenDefined(_ r: JSDOMCERegistry, _ name: String) -> JSValue {
        let p = realm.newPromise()
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        _ = heap.root(p)
        if !htmlIsValidCustomElementName(name) {
            let e = domException("SyntaxError", "\"" + name + "\" is not a valid custom element name")
            _ = heap.root(e)
            realm.rejectPromise(p, e)
            return p
        }
        if let def = ce.definitions[name] {
            _ = try? realm.resolvePromise(p, def.ctor)
            return p
        }
        if let existing = ce.whenDefined[name] { return existing }
        ce.whenDefined[name] = p
        return p
    }

    func CustomElementRegistry_upgrade(_ r: JSDOMCERegistry, _ root: HTMLNode) {
        root.walkShadowIncluding { n in
            if n.kind == .element { self.ceTryUpgrade(n) }
            return true
        }
    }

    // MARK: ElementInternals

    func HTMLElement_attachInternals(_ n: HTMLNode) throws(JSThrow) -> JSValue {
        let what = "Failed to execute 'attachInternals' on 'HTMLElement': "
        guard let def = ceLookup(n.nodeDocument, n) ?? ce.elements[ObjectIdentifier(n)]?.definition else {
            throw throwDOM("NotSupportedError", what + "Unable to attach ElementInternals to non-custom elements.")
        }
        if def.disableInternals { throw throwDOM("NotSupportedError", what + "ElementInternals is disabled by disabledFeature static field.") }
        if ce.internals[ObjectIdentifier(n)] != nil {
            throw throwDOM("NotSupportedError", what + "ElementInternals for the specified element was already attached.")
        }
        let st = n.customElementState
        if st != .precustomized && st != .custom {
            throw throwDOM("NotSupportedError", what + "The attachInternals() function cannot be called prior to the execution of the custom element constructor.")
        }
        let i = JSDOMElementInternals(n)
        ce.internals[ObjectIdentifier(n)] = i
        let w = classes.ElementInternals.wrap(i)
        classes.ElementInternals.pin(i, true)
        return w
    }

    func ElementInternals_shadowRoot(_ i: JSDOMElementInternals) -> JSValue {
        guard let s = i.target.attachedShadowRoot, s.availableToElementInternals else { return .null }
        return wrapNode(s)
    }
    func ElementInternals_states(_ i: JSDOMElementInternals) -> JSValue {
        if i.states.isObject { return i.states }
        // A CustomStateSet stand-in: a Set (add / delete / has / iteration).
        guard let setCtor = try? realm.getV(realm.global, heap.key("Set")), realm.isConstructor(setCtor),
              let s = try? realm.construct(setCtor, args: []) else { return .undefined }
        i.states = s
        return s
    }
    func ElementInternals_form(_ i: JSDOMElementInternals) -> JSValue { .null }
    func ElementInternals_setFormValue(_ i: JSDOMElementInternals, _ v: JSValue, _ state: JSValue) {}
    func ElementInternals_setValidity(_ i: JSDOMElementInternals, _ f: JSValue, _ m: JSValue, _ a: JSValue) {}
    func ElementInternals_willValidate(_ i: JSDOMElementInternals) -> Bool { false }
    func ElementInternals_validity(_ i: JSDOMElementInternals) -> JSValue { .undefined }
    func ElementInternals_validationMessage(_ i: JSDOMElementInternals) -> String { "" }
    func ElementInternals_checkValidity(_ i: JSDOMElementInternals) -> Bool { true }
    func ElementInternals_reportValidity(_ i: JSDOMElementInternals) -> Bool { true }
    func ElementInternals_labels(_ i: JSDOMElementInternals) -> JSValue { staticNodeList([]) }
}
