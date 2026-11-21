// MutationObserver (DOM Standard "Mutation observers") over lib/html's
// synchronous mutation hook, and the page's own reactions to DOM changes
// (live collection versions, on* content attributes, Attr detaching,
// slotchange). Records are queued per observer and delivered from one
// mutation-observer microtask, in observer creation order. The engine-only
// lib/html kinds (.slotchange, .shadowRootAttached, .customElementState)
// are not MutationRecords: slotchange becomes a `slotchange` event in the
// same microtask. Gaps: transient registered observers (records for
// subtrees removed from an observed subtree after the removal).

struct JSDOMObserverOptions {
    var childList = false
    var attributes = false
    var characterData = false
    var subtree = false
    var attributeOldValue = false
    var characterDataOldValue = false
    var attributeFilter: [String]? = nil
}

final class JSDOMMutationObserver {
    var callback: JSValue
    var wrapper: JSValue = .undefined
    var registrations: [(node: HTMLNode, options: JSDOMObserverOptions)] = []
    /// Transient registered observers (on nodes removed from an observed
    /// subtree), dropped at the next notification.
    var transient: [(node: HTMLNode, options: JSDOMObserverOptions)] = []
    var records: [JSDOMMutationRecord] = []
    init(_ cb: JSValue) { callback = cb }
    func mark(_ h: JSHeap) {
        h.markValue(callback)
        if !registrations.isEmpty || !records.isEmpty { h.markValue(wrapper) }
    }
}

final class JSDOMMutationRecord {
    let type: String
    let target: HTMLNode
    let added: [HTMLNode]
    let removed: [HTMLNode]
    let previousSibling: HTMLNode?
    let nextSibling: HTMLNode?
    let attributeName: String?
    let oldValue: String?
    init(type: String, target: HTMLNode, added: [HTMLNode], removed: [HTMLNode], previousSibling: HTMLNode?,
         nextSibling: HTMLNode?, attributeName: String?, oldValue: String?) {
        self.type = type
        self.target = target
        self.added = added
        self.removed = removed
        self.previousSibling = previousSibling
        self.nextSibling = nextSibling
        self.attributeName = attributeName
        self.oldValue = oldValue
    }
}

extension JSDOMBindings {
    /// The page's lib/html mutation observer (every document it watches).
    func domMutated(_ m: HTMLMutation) {
        mutationVersion &+= 1
        if m.kind == .childList {
            collectionTreeVersion &+= 1
            collectionClassVersion &+= 1
        } else if m.kind == .attributes && m.attributeName == "class" {
            collectionClassVersion &+= 1
        }
        if !ce.definitions.isEmpty { ceMutated(m) }
        if !nodeIterators.isEmpty && m.kind == .childList { iteratorsNoteRemoval(m) }
        switch m.kind {
        case .attributes:
            let name = m.attributeName
            if name.utf8.count > 2 && name.hasPrefix("on") && m.target.kind == .element {
                if scannedHandlers.contains(ObjectIdentifier(m.target)) {
                    contentHandlerChanged(m.target, String(name.dropFirst(2)), m.target.attribute(name))
                } else {
                    scanContentHandlers(m.target)
                }
            }
            if m.target.attribute(name) == nil { detachAttr(m.target, name) }
        case .slotchange:
            if !pendingSlotChanges.contains(where: { $0 === m.target }) { pendingSlotChanges.append(m.target) }
            queueMutationMicrotask()
            return
        case .shadowRootAttached, .customElementState:
            return
        default: break
        }
        if observers.isEmpty { return }
        queueRecord(m)
        if m.kind == .childList && !m.removedNodes.isEmpty { addTransientObservers(m) }
    }

    /// DOM "removing steps": subtree observers of the parent's inclusive
    /// ancestors keep watching the removed nodes until the next notification.
    func addTransientObservers(_ m: HTMLMutation) {
        var node: HTMLNode? = m.target
        var steps = 0
        while let n = node, steps < 100_000 {
            steps += 1
            for o in observers {
                for r in o.registrations where r.node === n && r.options.subtree {
                    for removed in m.removedNodes where o.transient.count < 100_000 {
                        o.transient.append((node: removed, options: r.options))
                    }
                }
            }
            node = n.parent
        }
    }

    func queueRecord(_ m: HTMLMutation) {
        let type: String
        switch m.kind {
        case .childList: type = "childList"
        case .attributes: type = "attributes"
        case .characterData: type = "characterData"
        default: return
        }
        // Interested observers and whether each wants the old value.
        var interested: [(JSDOMMutationObserver, Bool)] = []
        var node: HTMLNode? = m.target
        var steps = 0
        while let n = node, steps < 100_000 {
            steps += 1
            for o in observers {
                for r in o.registrations + o.transient where r.node === n {
                    let opt = r.options
                    if n !== m.target && !opt.subtree { continue }
                    if type == "attributes" {
                        if !opt.attributes { continue }
                        if let f = opt.attributeFilter, !f.contains(m.attributeName) { continue }
                    }
                    if type == "characterData" && !opt.characterData { continue }
                    if type == "childList" && !opt.childList { continue }
                    let wantOld = (type == "attributes" && opt.attributeOldValue) || (type == "characterData" && opt.characterDataOldValue)
                    if let i = interested.firstIndex(where: { $0.0 === o }) {
                        if wantOld { interested[i].1 = true }
                    } else {
                        interested.append((o, wantOld))
                    }
                }
            }
            node = n.parent ?? (n.isShadowRoot ? nil : nil)
        }
        if interested.isEmpty { return }
        for (o, wantOld) in interested {
            let rec = JSDOMMutationRecord(type: type, target: m.target, added: m.addedNodes, removed: m.removedNodes,
                                          previousSibling: m.previousSibling, nextSibling: m.nextSibling,
                                          attributeName: type == "attributes" ? m.attributeName : nil,
                                          oldValue: wantOld ? m.oldValue : nil)
            if o.records.count < 1_000_000 { o.records.append(rec) }
        }
        queueMutationMicrotask()
    }

    func queueMutationMicrotask() {
        if pendingMutationDelivery { return }
        pendingMutationDelivery = true
        if !mutationNotifier.isObject {
            unowned(unsafe) let b = self
            let idx = realm.registerNative("notifyMutationObservers", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
                try b.notifyMutationObservers()
                return .undefined
            }
            mutationNotifier = realm.newNativeFunction(idx)
            keep.append(mutationNotifier)
        }
        realm.enqueueJob(mutationNotifier, args: [])
    }

    /// DOM "notify mutation observers".
    func notifyMutationObservers() throws(JSThrow) {
        pendingMutationDelivery = false
        // Observers with records now (as engines do: one that gets its first
        // record from another observer's callback is called in the next
        // microtask, after this one's slotchange events).
        let list = observers.filter { !$0.records.isEmpty }
        let slots = pendingSlotChanges
        pendingSlotChanges = []
        for o in observers { o.transient = [] }
        for o in list {
            let recs = o.records
            o.records = []
            if recs.isEmpty { continue }
            let d = heap.rootDepth
            var vals: [JSValue] = []
            for r in recs { let w = classes.MutationRecord.wrap(r); _ = heap.root(w); vals.append(w) }
            let arr = array(vals)
            _ = heap.root(arr)
            _ = try runScriptCallback(o.callback, this: o.wrapper, args: [arr, o.wrapper])
            heap.popRoots(to: d)
        }
        for s in slots {
            let e = JSDOMEvent(.Event, type: "slotchange", time: now())
            e.bubbles = true
            e.isTrusted = true
            _ = try dispatch(e, to: .node(s))
        }
    }

    /// Watch another document's mutations too (observe() on a node there).
    func hookDocument(_ d: HTMLNode) {
        if d === document || hookedDocuments.contains(where: { $0.doc === d }) { return }
        unowned(unsafe) let b = self
        let id = d.addMutationObserver { m in b.domMutated(m) }
        hookedDocuments.append((doc: d, id: id))
    }

    // MARK: MutationObserver

    func MutationObserver_constructor(_ cb: JSValue, newTarget: JSValue) throws(JSThrow) -> JSValue {
        let o = JSDOMMutationObserver(cb)
        let w = classes.MutationObserver.wrap(o)
        o.wrapper = w
        observers.append(o)
        try adoptNewTarget(w, newTarget, .MutationObserver)
        return w
    }

    func MutationObserver_observe(_ o: JSDOMMutationObserver, _ target: HTMLNode, _ d: JSDOM_MutationObserverInit) throws(JSThrow) {
        var opt = JSDOMObserverOptions()
        opt.childList = d.childList
        opt.subtree = d.subtree
        var attributes = d.attributes
        var characterData = d.characterData
        if attributes == nil && (d.attributeOldValue != nil || d.attributeFilter != nil) { attributes = true }
        if characterData == nil && d.characterDataOldValue != nil { characterData = true }
        opt.attributes = attributes ?? false
        opt.characterData = characterData ?? false
        opt.attributeOldValue = d.attributeOldValue ?? false
        opt.characterDataOldValue = d.characterDataOldValue ?? false
        opt.attributeFilter = d.attributeFilter
        if !opt.childList && !opt.attributes && !opt.characterData {
            throw realm.throwTypeError("Failed to execute 'observe' on 'MutationObserver': The options object must set at least one of 'attributes', 'characterData', or 'childList' to true.")
        }
        if opt.attributeOldValue && !opt.attributes {
            throw realm.throwTypeError("Failed to execute 'observe' on 'MutationObserver': The options object may only set 'attributeOldValue' to true when 'attributes' is true or not present.")
        }
        if opt.attributeFilter != nil && !opt.attributes {
            throw realm.throwTypeError("Failed to execute 'observe' on 'MutationObserver': The options object may only set 'attributeFilter' when 'attributes' is true or not present.")
        }
        if opt.characterDataOldValue && !opt.characterData {
            throw realm.throwTypeError("Failed to execute 'observe' on 'MutationObserver': The options object may only set 'characterDataOldValue' to true when 'characterData' is true or not present.")
        }
        if let doc = target.nodeDocument ?? (target.kind == .document ? target : nil) { hookDocument(doc) }
        if let i = o.registrations.firstIndex(where: { $0.node === target }) {
            o.registrations[i].options = opt
        } else {
            o.registrations.append((node: target, options: opt))
        }
    }

    func MutationObserver_disconnect(_ o: JSDOMMutationObserver) {
        o.registrations = []
        o.transient = []
        o.records = []
    }

    func MutationObserver_takeRecords(_ o: JSDOMMutationObserver) -> JSValue {
        let recs = o.records
        o.records = []
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        var vals: [JSValue] = []
        for r in recs { let w = classes.MutationRecord.wrap(r); _ = heap.root(w); vals.append(w) }
        return array(vals)
    }

    func MutationRecord_type(_ r: JSDOMMutationRecord) -> String { r.type }
    func MutationRecord_target(_ r: JSDOMMutationRecord) -> HTMLNode? { r.target }
    func MutationRecord_addedNodes(_ r: JSDOMMutationRecord) -> JSValue { staticNodeList(r.added) }
    func MutationRecord_removedNodes(_ r: JSDOMMutationRecord) -> JSValue { staticNodeList(r.removed) }
    func MutationRecord_previousSibling(_ r: JSDOMMutationRecord) -> HTMLNode? { r.previousSibling }
    func MutationRecord_nextSibling(_ r: JSDOMMutationRecord) -> HTMLNode? { r.nextSibling }
    func MutationRecord_attributeName(_ r: JSDOMMutationRecord) -> String? { r.attributeName }
    func MutationRecord_attributeNamespace(_ r: JSDOMMutationRecord) -> String? {
        guard let n = r.attributeName else { return nil }
        if n.hasPrefix("xlink:") { return "http://www.w3.org/1999/xlink" }
        if n.hasPrefix("xml:") { return "http://www.w3.org/XML/1998/namespace" }
        return nil
    }
    func MutationRecord_oldValue(_ r: JSDOMMutationRecord) -> String? { r.oldValue }

    // MARK: MessageEvent

    func MessageEvent_constructor(_ type: String, _ d: JSDOM_MessageEventInit, newTarget: JSValue) throws(JSThrow) -> JSValue {
        let e = makeEvent(.MessageEvent, type, baseInit(bubbles: d.bubbles, cancelable: d.cancelable, composed: d.composed))
        e.oldURL = d.origin
        e.newURL = d.lastEventId
        let w = try finishEvent(e, newTarget)
        setHiddenSlot(w, 0, d.data)
        return w
    }
    func MessageEvent_origin(_ e: JSDOMEvent) -> String { e.oldURL.isEmpty && e.isTrusted ? messageOrigin : e.oldURL }
    func MessageEvent_lastEventId(_ e: JSDOMEvent) -> String { e.newURL }
    func MessageEvent_source(_ e: JSDOMEvent) -> JSValue { e.isTrusted ? realm.global : .null }
    func MessageEvent_ports(_ e: JSDOMEvent) -> JSValue { array([]) }
}
