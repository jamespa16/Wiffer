// Promise and the job (microtask) queue (ROADMAP Phase 9E).
//
// ============================================================ job queue
//
// Every realm has one FIFO job queue (the spec's HostEnqueuePromiseJob).
// Promise reactions, thenable resolution and `await` resumptions are
// queued here; nothing runs them except the embedder:
//
//     switch realm.evaluate(source: src, name: "page.js") { ... }
//     let c = realm.runJobs()          // microtask checkpoint
//
//   realm.runJobs() -> JSCompletion
//       Runs jobs until the queue is empty, including jobs queued by the
//       jobs themselves. A job that throws (only embedder jobs and
//       enqueueJob callbacks can; promise jobs turn errors into
//       rejections) is reported to `jobErrorHandler` (if set) and the
//       drain continues. Returns .normal(undefined) when drained,
//       .terminated(reason) if a job hit the heap cap or the interrupt
//       handler (the remaining jobs are dropped; the realm stays usable,
//       as after evaluate). After the drain, unhandled rejections are
//       reported (see below). Re-entrant calls (from inside a job) return
//       at once with .normal(undefined).
//   realm.hasPendingJobs -> Bool
//   realm.pendingJobCount -> Int
//   realm.enqueueJob(fn, args:)      call a JS function as a microtask
//       (queueMicrotask); fn is called with this = undefined.
//   realm.enqueueHostJob { (realm: JSRealm) throws(JSThrow) -> Void in ... }
//       a Swift job (it may call into JS; root what it keeps).
//   realm.jobErrorHandler: ((JSRealm, JSUncaughtException) -> Void)?
//       uncaught exceptions from jobs (default: dropped).
//
// ============================================================ rejections
//
//   realm.promiseRejectionTracker: ((JSRealm, JSValue, JSPromiseRejectionOperation) -> Void)?
//       HostPromiseRejectionTracker: called with (promise, .reject) when a
//       promise is rejected while it has no handler, and (promise,
//       .handle) when a handler is first added to an already rejected
//       promise. The promise value is valid only during the call (root
//       it to keep it). Must not run JS.
//   realm.unhandledRejectionHandler: ((JSRealm, JSValue, JSValue) -> Void)?
//       Convenience on top of the tracker (HTML's "notify about rejected
//       promises"): at the end of runJobs, called with (promise, reason)
//       for every promise rejected since the last drain that still has
//       no handler. Values valid during the call.
//
// =============================================================== Promise
//
// Built-ins: Promise(executor), Promise.prototype.then / catch / finally,
// Promise.resolve / reject / all / allSettled / any / race /
// withResolvers / try, get Promise[@@species], AggregateError.
//
// For Swift (natives, the VM, modules):
//   realm.newPromise() -> JSValue                    a pending %Promise%
//   realm.resolvePromise(p, v) / realm.rejectPromise(p, reason)
//       (resolve follows thenables, like the resolve function)
//   realm.promiseThen(p, onFulfilled, onRejected) -> JSValue   (then)
//   realm.promiseResolve(v) -> JSValue               PromiseResolve(%Promise%, v)
//   realm.promiseState(p) -> JSPromiseStateValue (.pending/.fulfilled/
//       .rejected) and realm.promiseResult(p)
//
// Layout: a promise is kind .promise; internalInt = state (0 pending, 1
// fulfilled, 2 rejected) | 8 (has a handler); slot 0 = the result, slots
// 1... = the pending reaction records. A reaction record is an internal
// object [capPromise, capResolve, capReject, handlerA, handlerB] whose
// internalInt is its type: 0 a then() reaction (handlers are JS values),
// 1 an await (handlerA = the suspended frame's state object,
// jsgenerator.swift), 2 an async generator's return await, 3 the
// async-from-sync iterator unwrap (bit 8: done), 4 a module evaluation
// step (jsmodule.swift). A capability with capResolve undefined resolves
// capPromise directly (the %Promise% fast path: no resolve functions).

public enum JSPromiseRejectionOperation { case reject, handle }
public enum JSPromiseStateValue { case pending, fulfilled, rejected }

struct JSJob {
    /// 0 fulfill reaction, 1 reject reaction, 2 resolve thenable, 3 JS
    /// callback (b = arguments array), 4 host closure.
    var kind: UInt8
    var a: JSValue = .undefined
    var b: JSValue = .undefined
    var c: JSValue = .undefined
    var host: ((JSRealm) throws(JSThrow) -> Void)? = nil
}

/// Phase 9E per-realm state (the job queue, hooks, native indices, module
/// records). Its values are GC roots (mark).
final class JSESState {
    var jobs: [JSJob] = []
    var jobHead = 0
    var draining = false
    var pendingRejections: [JSValue] = []
    var rejectionTracker: ((JSRealm, JSValue, JSPromiseRejectionOperation) -> Void)? = nil
    var unhandledRejectionHandler: ((JSRealm, JSValue, JSValue) -> Void)? = nil
    var jobErrorHandler: ((JSRealm, JSUncaughtException) -> Void)? = nil
    // Native indices.
    var resolveFn = -1, rejectFn = -1, executorFn = -1
    var thenFinallyFn = -1, catchFinallyFn = -1, valueThunkFn = -1, throwerFn = -1
    var allResolveFn = -1, allSettledFulfillFn = -1, allSettledRejectFn = -1, anyRejectFn = -1
    /// Generator.prototype.next / return / throw (consecutive).
    var genResumeBase = -1
    // Modules (jsmodule.swift).
    var modules: [JSValue] = []
    var moduleRecords: [JSModuleRecord] = []

    func mark(_ h: JSHeap) {
        var i = jobHead
        while i < jobs.count {
            h.markValue(jobs[i].a); h.markValue(jobs[i].b); h.markValue(jobs[i].c)
            i += 1
        }
        for p in pendingRejections { h.markValue(p) }
        for m in modules { h.markValue(m) }
        for r in moduleRecords { r.mark(h) }
    }
}

/// A promise capability (promise, resolve, reject); resolve undefined is
/// the %Promise% fast path.
struct JSCapability {
    var promise: JSValue
    var resolve: JSValue
    var reject: JSValue
}

extension JSHeap {
    /// Append one internal slot (false if refused by the heap cap).
    @discardableResult
    func appendSlotValue(_ o: JSValue, _ v: JSValue) -> Bool {
        guard let i = objectIndex(o), noteGrowth(8) else { return false }
        objects[i].slots.append(v)
        return true
    }
}

extension JSRealm {
    // MARK: Job queue (public API)

    public var hasPendingJobs: Bool { es.jobHead < es.jobs.count }
    public var pendingJobCount: Int { es.jobs.count - es.jobHead }

    public var promiseRejectionTracker: ((JSRealm, JSValue, JSPromiseRejectionOperation) -> Void)? {
        get { es.rejectionTracker }
        set { es.rejectionTracker = newValue }
    }
    public var unhandledRejectionHandler: ((JSRealm, JSValue, JSValue) -> Void)? {
        get { es.unhandledRejectionHandler }
        set { es.unhandledRejectionHandler = newValue }
    }
    public var jobErrorHandler: ((JSRealm, JSUncaughtException) -> Void)? {
        get { es.jobErrorHandler }
        set { es.jobErrorHandler = newValue }
    }

    func enqueue(_ j: JSJob) { es.jobs.append(j) }

    public func enqueueJob(_ fn: JSValue, args: [JSValue] = []) {
        let r = heap.root(fn)
        let a = heap.newArray(proto: arrayPrototype, elements: args)
        heap.popRoots(to: r.slot)
        enqueue(JSJob(kind: 3, a: fn, b: a))
    }

    public func enqueueHostJob(_ body: @escaping (JSRealm) throws(JSThrow) -> Void) {
        enqueue(JSJob(kind: 4, host: body))
    }

    public func runJobs() -> JSCompletion {
        if es.draining { return .normal(.undefined) }
        let outer = nativeDepth == 0 && frames.isEmpty
        if outer { stackFloor = jsVMStackFloor(limits) }
        es.draining = true
        defer { es.draining = false }
        while es.jobHead < es.jobs.count {
            let j = es.jobs[es.jobHead]
            es.jobs[es.jobHead] = JSJob(kind: 0)
            es.jobHead += 1
            if es.jobHead >= 1024 && es.jobHead * 2 >= es.jobs.count {
                es.jobs.removeFirst(es.jobHead)
                es.jobHead = 0
            }
            let depth = heap.rootDepth
            _ = heap.root(j.a); _ = heap.root(j.b); _ = heap.root(j.c)
            do throws(JSThrow) {
                try runJob(j)
                heap.popRoots(to: depth)
            } catch {
                heap.popRoots(to: depth)
                if heap.termination != nil {
                    es.jobs = []
                    es.jobHead = 0
                    es.pendingRejections = []
                    return finishCompletion(outer: outer)
                }
                let u = uncaught()
                exception = .undefined
                trace = []
                es.jobErrorHandler?(self, u)
            }
        }
        es.jobs.removeAll(keepingCapacity: true)
        es.jobHead = 0
        if outer && heap.termination == .interrupted { heap.clearTermination() }
        reportUnhandledRejections()
        return .normal(.undefined)
    }

    func reportUnhandledRejections() {
        let list = es.pendingRejections
        es.pendingRejections = []
        guard let h = es.unhandledRejectionHandler else { return }
        for p in list where heap.internalInt(p) & 8 == 0 && heap.internalInt(p) & 3 == 2 {
            h(self, p, heap.slot(p, 0))
        }
    }

    func runJob(_ j: JSJob) throws(JSThrow) {
        switch j.kind {
        case 0, 1: try reactionJob(j.a, j.b, rejected: j.kind == 1)
        case 2:
            let (res, rej) = createResolvingFunctions(j.a)
            let d = heap.rootDepth
            defer { heap.popRoots(to: d) }
            _ = heap.root(res); _ = heap.root(rej)
            do throws(JSThrow) {
                _ = try call(j.c, this: j.b, args: [res, rej])
            } catch {
                if heap.termination != nil { throw error }
                let e = exception
                exception = .undefined
                _ = heap.root(e)
                _ = try call(rej, this: .undefined, args: [e])
            }
        case 3:
            var args: [JSValue] = []
            let n = Int(heap.arrayLength(j.b))
            for i in 0..<n {
                if case .value(let v) = heap.getProperty(j.b, .index(UInt32(i))) { args.append(v) } else { args.append(.undefined) }
            }
            _ = try call(j.a, this: .undefined, args: args)
        default:
            if let h = j.host { try h(self) }
        }
    }

    // MARK: Promise internals

    public func isPromise(_ v: JSValue) -> Bool { v.isObject && heap.kind(v) == .promise }

    public func promiseState(_ p: JSValue) -> JSPromiseStateValue {
        switch heap.internalInt(p) & 3 {
        case 1: return .fulfilled
        case 2: return .rejected
        default: return .pending
        }
    }
    public func promiseResult(_ p: JSValue) -> JSValue { heap.slot(p, 0) }

    func newPromiseObject(proto: JSValue) -> JSValue {
        let p = heap.newObject(proto: proto.isObject ? proto : intrinsic(.promisePrototype), kind: .promise)
        heap.setSlots(p, [.undefined])
        return p
    }

    public func newPromise() -> JSValue { newPromiseObject(proto: intrinsic(.promisePrototype)) }

    /// A function object for native idx with internal slots.
    func nativeClosure(_ idx: Int, _ slots: [JSValue], length: Int? = nil) -> JSValue {
        let d = heap.rootDepth
        for s in slots { _ = heap.root(s) }
        let f = newNativeFunction(idx)
        heap.setSlots(f, slots)
        heap.popRoots(to: d)
        return f
    }

    func createResolvingFunctions(_ p: JSValue) -> (JSValue, JSValue) {
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        _ = heap.root(p)
        let rec = heap.newObject(proto: .null, kind: .internalObject)
        _ = heap.root(rec)
        let res = nativeClosure(es.resolveFn, [p, rec])
        _ = heap.root(res)
        let rej = nativeClosure(es.rejectFn, [p, rec])
        return (res, rej)
    }

    func triggerReactions(_ p: JSValue, _ v: JSValue, rejected: Bool) {
        let n = heap.slotCount(p)
        var rs: [JSValue] = []
        for i in 1..<max(1, n) { rs.append(heap.slot(p, i)) }
        heap.setSlots(p, [v])
        for r in rs { enqueue(JSJob(kind: rejected ? 1 : 0, a: r, b: v)) }
    }

    func fulfillPromise(_ p: JSValue, _ v: JSValue) {
        guard heap.internalInt(p) & 3 == 0 else { return }
        heap.setInternalInt(p, (heap.internalInt(p) & ~3) | 1)
        triggerReactions(p, v, rejected: false)
    }

    public func rejectPromise(_ p: JSValue, _ reason: JSValue) {
        guard heap.internalInt(p) & 3 == 0 else { return }
        heap.setInternalInt(p, (heap.internalInt(p) & ~3) | 2)
        triggerReactions(p, reason, rejected: true)
        if heap.internalInt(p) & 8 == 0 { trackRejection(p, .reject) }
    }

    func trackRejection(_ p: JSValue, _ op: JSPromiseRejectionOperation) {
        es.rejectionTracker?(self, p, op)
        if es.unhandledRejectionHandler != nil {
            if op == .reject {
                es.pendingRejections.append(p)
            } else if let i = es.pendingRejections.firstIndex(of: p) {
                es.pendingRejections.remove(at: i)
            }
        }
    }

    /// The resolve function's algorithm (follows thenables).
    public func resolvePromise(_ p: JSValue, _ x: JSValue) throws(JSThrow) {
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        _ = heap.root(p); _ = heap.root(x)
        if x == p {
            rejectPromise(p, makeError(.typeError, "Chaining cycle detected for promise"))
            return
        }
        guard x.isObject else { fulfillPromise(p, x); return }
        let then: JSValue
        do throws(JSThrow) {
            then = try getV(x, heap.names.then)
        } catch {
            if heap.termination != nil { throw error }
            let e = exception
            exception = .undefined
            rejectPromise(p, e)
            return
        }
        guard heap.isCallable(then) else { fulfillPromise(p, x); return }
        enqueue(JSJob(kind: 2, a: p, b: x, c: then))
    }

    /// PerformPromiseThen with a capability (or none: promise undefined).
    func performPromiseThen(_ p: JSValue, _ onF: JSValue, _ onR: JSValue, _ cap: JSCapability, type: Int64 = 0) {
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        _ = heap.root(p)
        for v in [onF, onR, cap.promise, cap.resolve, cap.reject] { _ = heap.root(v) }
        let r = heap.newObject(proto: .null, kind: .internalObject)
        heap.setSlots(r, [cap.promise, cap.resolve, cap.reject, onF, onR])
        heap.setInternalInt(r, type)
        let st = heap.internalInt(p)
        switch st & 3 {
        case 0: heap.appendSlotValue(p, r)
        case 1: enqueue(JSJob(kind: 0, a: r, b: heap.slot(p, 0)))
        default:
            if st & 8 == 0 { trackRejection(p, .handle) }
            enqueue(JSJob(kind: 1, a: r, b: heap.slot(p, 0)))
        }
        heap.setInternalInt(p, heap.internalInt(p) | 8)
    }

    func settleCapability(_ cap: JSCapability, ok: Bool, _ v: JSValue) throws(JSThrow) {
        if cap.promise.isUndefined && cap.resolve.isUndefined { return }
        if cap.resolve.isUndefined {
            if ok { try resolvePromise(cap.promise, v) } else { rejectPromise(cap.promise, v) }
            return
        }
        _ = try call(ok ? cap.resolve : cap.reject, this: .undefined, args: [v])
    }

    func capability(ofReaction r: JSValue) -> JSCapability {
        JSCapability(promise: heap.slot(r, 0), resolve: heap.slot(r, 1), reject: heap.slot(r, 2))
    }

    func reactionJob(_ r: JSValue, _ arg: JSValue, rejected: Bool) throws(JSThrow) {
        let type = heap.internalInt(r) & 0xFF
        switch type {
        case 1:
            try resumeAwait(heap.slot(r, 3), arg, mode: rejected ? 1 : 0)
        case 2:
            try asyncGenAwaitReturnSettled(heap.slot(r, 3), arg, rejected: rejected)
        case 3:
            let cap = capability(ofReaction: r)
            if rejected { try settleCapability(cap, ok: false, arg); return }
            let res = try iterResult(arg, done: heap.internalInt(r) & 0x100 != 0)
            let k = heap.root(res)
            defer { heap.popRoots(to: k.slot) }
            try settleCapability(cap, ok: true, res)
        case 4:
            try moduleReaction(heap.slot(r, 3), arg, rejected: rejected)
        default:
            let handler = heap.slot(r, rejected ? 4 : 3)
            var result = arg
            var ok = !rejected
            if heap.isCallable(handler) {
                do throws(JSThrow) {
                    result = try call(handler, this: .undefined, args: [arg])
                    ok = true
                } catch {
                    if heap.termination != nil { throw error }
                    result = exception
                    exception = .undefined
                    ok = false
                }
            }
            let k = heap.root(result)
            defer { heap.popRoots(to: k.slot) }
            try settleCapability(capability(ofReaction: r), ok: ok, result)
        }
    }

    // MARK: Abstract operations

    func speciesConstructor(_ o: JSValue, _ dflt: JSValue) throws(JSThrow) -> JSValue {
        let c = try getV(o, heap.names.constructor)
        if c.isUndefined { return dflt }
        guard c.isObject else { throw throwTypeError("object.constructor is not an object") }
        let s = try getV(c, .symbol(heap.symbolsWellKnown.species.handle))
        if s.isNullish { return dflt }
        if s.isObject && heap.flags(s).contains(.constructor) { return s }
        throw throwTypeError("object.constructor[Symbol.species] is not a constructor")
    }

    /// NewPromiseCapability(C). `functions`: make real resolve/reject
    /// functions even for %Promise%.
    func newPromiseCapability(_ c: JSValue, functions: Bool = false) throws(JSThrow) -> JSCapability {
        if c == intrinsic(.promiseConstructor) {
            let p = newPromise()
            if !functions { return JSCapability(promise: p, resolve: .undefined, reject: .undefined) }
            let r = heap.root(p)
            defer { heap.popRoots(to: r.slot) }
            let (res, rej) = createResolvingFunctions(p)
            return JSCapability(promise: p, resolve: res, reject: rej)
        }
        guard c.isObject && heap.flags(c).contains(.constructor) else {
            throw throwTypeError(describeForError(c) + " is not a constructor")
        }
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        let ex = nativeClosure(es.executorFn, [.undefined, .undefined])
        _ = heap.root(ex)
        let p = try construct(c, args: [ex])
        _ = heap.root(p)
        let res = heap.slot(ex, 0), rej = heap.slot(ex, 1)
        guard heap.isCallable(res) else { throw throwTypeError("Promise resolve function is not callable") }
        guard heap.isCallable(rej) else { throw throwTypeError("Promise reject function is not callable") }
        return JSCapability(promise: p, resolve: res, reject: rej)
    }

    /// PromiseResolve(C, x).
    func promiseResolve(_ c: JSValue, _ x: JSValue) throws(JSThrow) -> JSValue {
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        _ = heap.root(c); _ = heap.root(x)
        if isPromise(x) {
            let xc = try getV(x, heap.names.constructor)
            if xc == c { return x }
        }
        let cap = try newPromiseCapability(c)
        _ = heap.root(cap.promise); _ = heap.root(cap.resolve); _ = heap.root(cap.reject)
        try settleCapability(cap, ok: true, x)
        return cap.promise
    }

    /// PromiseResolve(%Promise%, v) (await, async iteration).
    public func promiseResolve(_ v: JSValue) throws(JSThrow) -> JSValue {
        try promiseResolve(intrinsic(.promiseConstructor), v)
    }

    /// p.then(onFulfilled, onRejected) on a %Promise% (no species lookup).
    public func promiseThen(_ p: JSValue, _ onF: JSValue, _ onR: JSValue) -> JSValue {
        let d = heap.rootDepth
        defer { heap.popRoots(to: d) }
        _ = heap.root(p); _ = heap.root(onF); _ = heap.root(onR)
        let np = newPromise()
        _ = heap.root(np)
        performPromiseThen(p, onF, onR, JSCapability(promise: np, resolve: .undefined, reject: .undefined))
        return np
    }

    func invoke(_ v: JSValue, _ k: JSPropertyKey, _ args: [JSValue]) throws(JSThrow) -> JSValue {
        let f = try getV(v, k)
        let r = heap.root(f)
        defer { heap.popRoots(to: r.slot) }
        return try call(f, this: v, args: args)
    }

    /// The pending exception, cleared (after catching a non-termination).
    func takeException() -> JSValue {
        let e = exception
        exception = .undefined
        trace = []
        return e
    }
}

// MARK: Built-ins

func jsInstallPromise(_ realm: JSRealm) {
    let heap = realm.heap
    let es = realm.es
    let op = realm.objectPrototype
    let pp = heap.newObject(proto: op)
    realm.setIntrinsic(.promisePrototype, pp)

    es.resolveFn = realm.registerNative("", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let rec = h.slot(args.callee, 1)
        if h.internalInt(rec) != 0 { return .undefined }
        h.setInternalInt(rec, 1)
        try realm.resolvePromise(h.slot(args.callee, 0), args[0])
        return .undefined
    }
    es.rejectFn = realm.registerNative("", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let rec = h.slot(args.callee, 1)
        if h.internalInt(rec) != 0 { return .undefined }
        h.setInternalInt(rec, 1)
        realm.rejectPromise(h.slot(args.callee, 0), args[0])
        return .undefined
    }
    es.executorFn = realm.registerNative("", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let f = args.callee
        if !h.slot(f, 0).isUndefined || !h.slot(f, 1).isUndefined {
            throw realm.throwTypeError("Promise executor has already been invoked with non-undefined arguments")
        }
        h.setSlot(f, 0, args[0])
        h.setSlot(f, 1, args[1])
        return .undefined
    }

    // ---------------------------------------------------------- constructor
    let ctor = realm.defineConstructor("Promise", length: 1, prototype: pp) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        guard args.isConstruct else { throw realm.throwTypeError("Promise constructor cannot be invoked without 'new'") }
        let executor = args[0]
        guard h.isCallable(executor) else { throw realm.throwTypeError("Promise resolver " + realm.describeForError(executor) + " is not a function") }
        let d = h.rootDepth
        defer { h.popRoots(to: d) }
        let proto = try realm.prototype(forNewTarget: args.newTarget, default: .promisePrototype)
        _ = h.root(proto)
        let p = realm.newPromiseObject(proto: proto)
        _ = h.root(p)
        let (res, rej) = realm.createResolvingFunctions(p)
        _ = h.root(res); _ = h.root(rej)
        do throws(JSThrow) {
            _ = try realm.call(executor, this: .undefined, args: [res, rej])
        } catch {
            if realm.isTerminating { throw error }
            let e = realm.takeException()
            _ = h.root(e)
            _ = try realm.call(rej, this: .undefined, args: [e])
        }
        return p
    }
    realm.setIntrinsic(.promiseConstructor, ctor)
    realm.defineGetter(ctor, "[Symbol.species]", key: .symbol(heap.symbolsWellKnown.species.handle)) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        args.this
    }
    _ = heap.defineOwnProperty(pp, .symbol(heap.symbolsWellKnown.toStringTag.handle), .data(realm.string("Promise"), [.configurable]))

    // ---------------------------------------------------------- prototype
    realm.defineMethod(pp, "then", length: 2) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let p = args.this
        guard realm.isPromise(p) else { throw realm.throwTypeError("Promise.prototype.then called on incompatible receiver") }
        let d = h.rootDepth
        defer { h.popRoots(to: d) }
        let c = try realm.speciesConstructor(p, realm.intrinsic(.promiseConstructor))
        _ = h.root(c)
        let cap = try realm.newPromiseCapability(c)
        let onF = h.isCallable(args[0]) ? args[0] : JSValue.undefined
        let onR = h.isCallable(args[1]) ? args[1] : JSValue.undefined
        realm.performPromiseThen(p, onF, onR, cap)
        return cap.promise
    }
    realm.defineMethod(pp, "catch", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        try realm.invoke(args.this, realm.heap.names.then, [.undefined, args[0]])
    }
    es.thenFinallyFn = realm.registerNative("", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let d = h.rootDepth
        defer { h.popRoots(to: d) }
        let onFinally = h.slot(args.callee, 0), c = h.slot(args.callee, 1)
        let result = try realm.call(onFinally, this: .undefined, args: [])
        _ = h.root(result)
        let p = try realm.promiseResolve(c, result)
        _ = h.root(p)
        let thunk = realm.nativeClosure(realm.es.valueThunkFn, [args[0]])
        _ = h.root(thunk)
        return try realm.invoke(p, h.names.then, [thunk])
    }
    es.catchFinallyFn = realm.registerNative("", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let d = h.rootDepth
        defer { h.popRoots(to: d) }
        let onFinally = h.slot(args.callee, 0), c = h.slot(args.callee, 1)
        let result = try realm.call(onFinally, this: .undefined, args: [])
        _ = h.root(result)
        let p = try realm.promiseResolve(c, result)
        _ = h.root(p)
        let thrower = realm.nativeClosure(realm.es.throwerFn, [args[0]])
        _ = h.root(thrower)
        return try realm.invoke(p, h.names.then, [thrower])
    }
    es.valueThunkFn = realm.registerNative("", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        realm.heap.slot(args.callee, 0)
    }
    es.throwerFn = realm.registerNative("", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        throw realm.throwValue(realm.heap.slot(args.callee, 0))
    }
    realm.defineMethod(pp, "finally", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let p = args.this
        guard p.isObject else { throw realm.throwTypeError("Promise.prototype.finally called on a non-object") }
        let d = h.rootDepth
        defer { h.popRoots(to: d) }
        let c = try realm.speciesConstructor(p, realm.intrinsic(.promiseConstructor))
        _ = h.root(c)
        let onFinally = args[0]
        if !h.isCallable(onFinally) {
            return try realm.invoke(p, h.names.then, [onFinally, onFinally])
        }
        let tf = realm.nativeClosure(realm.es.thenFinallyFn, [onFinally, c])
        _ = h.root(tf)
        let cf = realm.nativeClosure(realm.es.catchFinallyFn, [onFinally, c])
        _ = h.root(cf)
        return try realm.invoke(p, h.names.then, [tf, cf])
    }

    // ---------------------------------------------------------- statics
    realm.defineMethod(ctor, "resolve", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        guard args.this.isObject else { throw realm.throwTypeError("PromiseResolve called on non-object") }
        return try realm.promiseResolve(args.this, args[0])
    }
    realm.defineMethod(ctor, "reject", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let cap = try realm.newPromiseCapability(args.this)
        let r = realm.heap.root(cap.promise)
        defer { realm.heap.popRoots(to: r.slot) }
        try realm.settleCapability(cap, ok: false, args[0])
        return cap.promise
    }
    realm.defineMethod(ctor, "withResolvers", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let d = h.rootDepth
        defer { h.popRoots(to: d) }
        let cap = try realm.newPromiseCapability(args.this, functions: true)
        for v in [cap.promise, cap.resolve, cap.reject] { _ = h.root(v) }
        let o = h.newObject(proto: realm.objectPrototype)
        _ = h.root(o)
        _ = h.createDataProperty(o, h.key("promise"), cap.promise)
        _ = h.createDataProperty(o, h.key("resolve"), cap.resolve)
        _ = h.createDataProperty(o, h.key("reject"), cap.reject)
        return o
    }
    realm.defineMethod(ctor, "try", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let d = h.rootDepth
        defer { h.popRoots(to: d) }
        let cap = try realm.newPromiseCapability(args.this)
        for v in [cap.promise, cap.resolve, cap.reject] { _ = h.root(v) }
        var rest: [JSValue] = []
        if args.count > 1 { for i in 1..<args.count { rest.append(args[i]) } }
        do throws(JSThrow) {
            let v = try realm.call(args[0], this: .undefined, args: rest)
            _ = h.root(v)
            try realm.settleCapability(cap, ok: true, v)
        } catch {
            if realm.isTerminating { throw error }
            let e = realm.takeException()
            _ = h.root(e)
            try realm.settleCapability(cap, ok: false, e)
        }
        return cap.promise
    }

    // Combinators: element functions hold [index, values, capability
    // record, remaining counter, alreadyCalled] in their slots.
    func element(_ realm: JSRealm, _ args: JSArgs, _ store: (JSRealm, JSValue) throws(JSThrow) -> JSValue,
                 finishWithError: Bool) throws(JSThrow) -> JSValue {
        let h = realm.heap
        let f = args.callee
        if h.slot(f, 4) == .true { return .undefined }
        h.setSlot(f, 4, .true)
        if h.slotCount(f) > 5 { h.setSlot(h.slot(f, 5), 4, .true) }
        let d = h.rootDepth
        defer { h.popRoots(to: d) }
        let idx = h.slot(f, 0), values = h.slot(f, 1), capRec = h.slot(f, 2), remaining = h.slot(f, 3)
        let v = try store(realm, args[0])
        _ = h.root(v)
        _ = h.createDataProperty(values, .index(UInt32(truncatingIfNeeded: Int(idx.numberValue))), v)
        let left = h.internalInt(remaining) - 1
        h.setInternalInt(remaining, left)
        if left == 0 {
            let cap = realm.capability(ofReaction: capRec)
            if finishWithError {
                let e = realm.makeError(.aggregateError, "All promises were rejected")
                _ = h.root(e)
                let list = h.newArray(proto: realm.arrayPrototype)
                _ = h.root(list)
                let n = Int(h.arrayLength(values))
                for i in 0..<n {
                    if case .value(let x) = h.getProperty(values, .index(UInt32(i))) { _ = h.createDataProperty(list, .index(UInt32(i)), x) }
                }
                _ = h.defineOwnProperty(e, h.names.errors, .data(list, [.writable, .configurable]))
                try realm.settleCapability(cap, ok: false, e)
            } else {
                try realm.settleCapability(cap, ok: true, values)
            }
        }
        return .undefined
    }
    func settled(_ realm: JSRealm, _ status: String, _ key: String, _ v: JSValue) -> JSValue {
        let h = realm.heap
        let r = h.root(v)
        defer { h.popRoots(to: r.slot) }
        let o = h.newObject(proto: realm.objectPrototype)
        _ = h.root(o)
        _ = h.createDataProperty(o, h.key("status"), realm.string(status))
        _ = h.createDataProperty(o, h.key(key), v)
        return o
    }
    es.allResolveFn = realm.registerNative("", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        try element(realm, args, { (realm: JSRealm, v: JSValue) throws(JSThrow) -> JSValue in v }, finishWithError: false)
    }
    es.allSettledFulfillFn = realm.registerNative("", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        try element(realm, args, { (realm: JSRealm, v: JSValue) throws(JSThrow) -> JSValue in settled(realm, "fulfilled", "value", v) }, finishWithError: false)
    }
    es.allSettledRejectFn = realm.registerNative("", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        try element(realm, args, { (realm: JSRealm, v: JSValue) throws(JSThrow) -> JSValue in settled(realm, "rejected", "reason", v) }, finishWithError: false)
    }
    es.anyRejectFn = realm.registerNative("", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        try element(realm, args, { (realm: JSRealm, v: JSValue) throws(JSThrow) -> JSValue in v }, finishWithError: true)
    }

    /// 0 all, 1 allSettled, 2 any, 3 race.
    func combinator(_ realm: JSRealm, _ args: JSArgs, _ which: Int) throws(JSThrow) -> JSValue {
        let h = realm.heap
        let c = args.this
        let d = h.rootDepth
        defer { h.popRoots(to: d) }
        let cap = try realm.newPromiseCapability(c, functions: true)
        for v in [cap.promise, cap.resolve, cap.reject] { _ = h.root(v) }
        var done = true
        var itRoot: JSRooted? = nil
        var nextRoot: JSRooted? = nil
        do throws(JSThrow) {
            let resolveFn = try realm.getV(c, h.key("resolve"))
            _ = h.root(resolveFn)
            guard h.isCallable(resolveFn) else { throw realm.throwTypeError("Promise resolve is not a function") }
            let (it, next) = try realm.getIterator(args[0])
            itRoot = h.root(it)
            nextRoot = h.root(next)
            done = false
            let values = h.newArray(proto: realm.arrayPrototype)
            _ = h.root(values)
            let remaining = h.newObject(proto: .null, kind: .internalObject)
            _ = h.root(remaining)
            h.setInternalInt(remaining, 1)
            let capRec = h.newObject(proto: .null, kind: .internalObject)
            _ = h.root(capRec)
            h.setSlots(capRec, [cap.promise, cap.resolve, cap.reject])
            var index = 0
            while true {
                done = true
                let (fin, v) = try realm.iteratorStep(it, next)
                if fin { break }
                done = false
                let vd = h.rootDepth
                _ = h.root(v)
                if which != 3 { _ = h.createDataProperty(values, .index(UInt32(truncatingIfNeeded: index)), .undefined) }
                let np = try realm.call(resolveFn, this: c, args: [v])
                _ = h.root(np)
                switch which {
                case 3:
                    _ = try realm.invoke(np, h.names.then, [cap.resolve, cap.reject])
                default:
                    let slots: [JSValue] = [.number(index), values, capRec, remaining, .false]
                    let idxA = which == 2 ? realm.es.anyRejectFn : which == 1 ? realm.es.allSettledFulfillFn : realm.es.allResolveFn
                    let fa = realm.nativeClosure(idxA, slots)
                    _ = h.root(fa)
                    var fb = cap.reject
                    if which == 1 {
                        // Shares alreadyCalled with fa through a common flag object.
                        fb = realm.nativeClosure(realm.es.allSettledRejectFn, slots)
                        _ = h.root(fb)
                    }
                    h.setInternalInt(remaining, h.internalInt(remaining) + 1)
                    if which == 2 {
                        _ = try realm.invoke(np, h.names.then, [cap.resolve, fa])
                    } else {
                        _ = try realm.invoke(np, h.names.then, [fa, fb])
                    }
                    if which == 1 { jsLinkSettled(h, fa, fb) }
                }
                h.popRoots(to: vd)
                index += 1
                if h.termination != nil { throw JSThrow() }
            }
            done = true
            if which != 3 {
                let left = h.internalInt(remaining) - 1
                h.setInternalInt(remaining, left)
                if left == 0 {
                    if which == 2 {
                        let e = realm.makeError(.aggregateError, "All promises were rejected")
                        _ = h.root(e)
                        _ = h.defineOwnProperty(e, h.names.errors, .data(values, [.writable, .configurable]))
                        try realm.settleCapability(cap, ok: false, e)
                    } else {
                        try realm.settleCapability(cap, ok: true, values)
                    }
                }
            }
        } catch {
            if realm.isTerminating { throw error }
            let e = realm.takeException()
            _ = h.root(e)
            if !done, let ir = itRoot, let nr = nextRoot {
                do throws(JSThrow) { try realm.iteratorClose(h[ir], h[nr]) } catch {
                    if realm.isTerminating { throw error }
                    _ = realm.takeException()
                }
            }
            try realm.settleCapability(cap, ok: false, e)
        }
        return cap.promise
    }
    realm.defineMethod(ctor, "all", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        try combinator(realm, args, 0)
    }
    realm.defineMethod(ctor, "allSettled", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        try combinator(realm, args, 1)
    }
    realm.defineMethod(ctor, "any", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        try combinator(realm, args, 2)
    }
    realm.defineMethod(ctor, "race", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        try combinator(realm, args, 3)
    }

    // ---------------------------------------------------------- AggregateError
    let ep = realm.intrinsic(.errorPrototype)
    let ap = heap.newObject(proto: ep)
    realm.setIntrinsic(.aggregateErrorPrototype, ap)
    realm.defineValue(ap, "name", realm.string("AggregateError"))
    realm.defineValue(ap, "message", .string(0))
    let agg = realm.defineConstructor("AggregateError", length: 2, prototype: ap) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let h = realm.heap
        let d = h.rootDepth
        defer { h.popRoots(to: d) }
        let proto = args.isConstruct ? try realm.prototype(forNewTarget: args.newTarget, default: .aggregateErrorPrototype)
                                     : realm.intrinsic(.aggregateErrorPrototype)
        _ = h.root(proto)
        var msg: JSValue = .undefined
        if !args[1].isUndefined { msg = try realm.toStringValue(args[1]); _ = h.root(msg) }
        let e = realm.makeErrorObject(.aggregateError, message: msg, proto: proto)
        _ = h.root(e)
        let opts = args[2]
        if opts.isObject && h.hasProperty(opts, h.names.cause) {
            let cv = try realm.getV(opts, h.names.cause)
            _ = h.defineOwnProperty(e, h.names.cause, .data(cv, [.writable, .configurable]))
        }
        let list = h.newArray(proto: realm.arrayPrototype)
        _ = h.root(list)
        let (it, next) = try realm.getIterator(args[0])
        _ = h.root(it); _ = h.root(next)
        while true {
            let (fin, v) = try realm.iteratorStep(it, next)
            if fin { break }
            _ = h.createDataProperty(list, .index(h.arrayLength(list)), v)
            if h.termination != nil { throw JSThrow() }
        }
        _ = h.defineOwnProperty(e, h.names.errors, .data(list, [.writable, .configurable]))
        return e
    }
    let errCtor = realm.intrinsic(.errorConstructor)
    if errCtor.isObject { _ = heap.setPrototypeOf(agg, errCtor) }
    realm.setIntrinsic(.aggregateErrorConstructor, agg)
}

/// allSettled: the fulfill and reject functions of one element share
/// alreadyCalled. fb's slot 4 points at fa; element() checks fa's flag.
func jsLinkSettled(_ h: JSHeap, _ fa: JSValue, _ fb: JSValue) {
    h.setSlot(fb, 4, .false)
    h.appendSlotValue(fb, fa)
    h.appendSlotValue(fa, fb)
}
