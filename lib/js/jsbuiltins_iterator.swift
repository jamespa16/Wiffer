// The Iterator global plus its prototype helpers.
//
// Installed here:
//   Iterator: the built-in constructor function (length 0, name "Iterator",
//   global binding {writable, configurable}, constructor flag set so it may
//   be used as the value of an extends clause). Its [[Prototype]] is the
//   intrinsic %FunctionPrototype% (set by defineConstructor), and its
//   .prototype is the intrinsic %IteratorPrototype% (%ArrayIteratorPrototype%
//   / %StringIteratorPrototype% / generator prototypes all inherit from it).
//   The helper methods (join / includes / chunks / windows) are
//   installed on %IteratorPrototype% with the correct descriptors —
//   {writable: true, enumerable: false, configurable: true}.
//
//   %IteratorHelperPrototype% (next / return / @@toStringTag "Iterator
//   Helper"), the prototype of the objects chunks and windows return.
//
// includes semantics:
//   1. the receiver must be an object (TypeError otherwise),
//   2. skippedElements is undefined -> +0F; otherwise it must already be
//      one of +Infinity, -Infinity, or an integral Number (NaN and
//      non-Number values are rejected with TypeError) — no coercion is
//      applied, so no valueOf/toString is called,
//   3. toSkip < -0F or (finite and > 2**53 - 1) -> RangeError,
//   4. on any validation failure the underlying iterator is closed and the
//      original error propagates (closing errors are masked),
//   5. the next method is read exactly once, immediately after
//      validation, before any iteration; a throwing next getter or a
//      non-callable next propagates without closing,
//   6. skip the first toSkip elements (done -> false), then iterate with
//      SameValueZero comparison; on a match the underlying iterator is
//      closed (errors propagate) and true is returned, without any close
//      on exhaustion or on next/done/value abrupt completion,
//   7. on exhaustion, return false (return is never consulted).
//
// join semantics:
//   1. the receiver must be an object (TypeError otherwise),
//   2. the separator argument is undefined -> "," (default; explicit null
//      is coerced to "null"); otherwise it is ToString-coerced exactly as
//      Array.prototype.join does (a Symbol separator throws TypeError);
//      a coercion error closes the underlying iterator (masked) and the
//      original error propagates (the close's own errors are masked and
//      the original is re-raised after the close),
//   3. the next method is read exactly once, after the separator is
//      coerced, and a non-callable next propagates without closing
//      (a throwing next getter propagates without closing),
//   4. iterator values are ToString-coerced (nullish values contribute
//      nothing but the separator field, mirroring Array.prototype.join);
//      a coercion error closes the underlying iterator (masked) and the
//      original error propagates,
//   5. the done bit is read before the value, and the value is read only
//      when not done; iterator exhaustion returns the accumulated string
//      without calling return; on next/done/value abrupt completions the
//      underlying iterator is not closed.
//
// chunks(chunkSize) / windows(windowSize, undersized) semantics:
//   1. the receiver must be an object (TypeError otherwise),
//   2. the size must already be an integral Number (TypeError otherwise, no
//      coercion) in 1 ... 2**32 - 1 (RangeError otherwise),
//   3. windows only: undersized is undefined (-> "only-full"), "only-full"
//      or "allow-partial" (TypeError otherwise, no coercion),
//   4. on any validation failure the underlying iterator is closed (closing
//      errors are masked),
//   5. next is read exactly once, after validation; it is not checked for
//      callability until the helper first calls it,
//   6. the helper behaves like the spec's generator-based iterator helper:
//      next/return while it is running throw TypeError; an abrupt step
//      completes it without closing the underlying iterator; return before
//      completion closes the underlying iterator (errors propagate).
//   chunks yields consecutive arrays of chunkSize values, then any shorter
//   remainder. windows yields each run of windowSize consecutive values; with
//   "allow-partial", an iterator that ends before the first full window
//   yields what it had.
//   A buffer needing more than limits.maxDenseArrayLength values is a
//   RangeError (it closes nothing, like any other failure inside next).
//
// An iterator helper object (kind .iteratorHelper; flags user0 = windows,
// user1 = allow-partial):
//   slot 0 underlying iterator   slot 1 its next method
//   slot 2... the buffered values (windows: a ring once full)
//   internalInt  size (bits 0-31) | ring head (bits 32-59) |
//                state (bits 60-61, JSIterHelperState)
//
// No VM or parser changes; the GC traces the helper's slots like any other
// object's.

func jsInstallIterator(_ realm: JSRealm) {
    let itp = realm.intrinsic(.iteratorPrototype)

    // The Iterator constructor. Spec contract: when called directly (NewTarget
    // undefined) or constructed directly (NewTarget === the active function
    // object), throw a TypeError. As a superconstructor of a derived class,
    // return a fresh object whose [[Prototype]] is the derived class's
    // prototype (or %IteratorPrototype% when it is not an object).
    _ = realm.defineConstructor("Iterator", length: 0, prototype: itp) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let nt = args.newTarget
        guard nt.isObject && nt != args.callee else {
            throw realm.throwTypeError("Iterator is not a constructor")
        }
        let proto = try realm.prototype(forNewTarget: nt, default: .iteratorPrototype)
        return realm.heap.newObject(proto: proto)
    }

    _ = realm.defineMethod(itp, "includes", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let heap = realm.heap
        let receiver = args.this

        // 1. The receiver must be an object.
        guard receiver.isObject else {
            throw realm.throwTypeError("'Iterator.prototype.includes' this value is not an object")
        }

        // 2. skippedElements validation (undefined -> 0). No coercion: a
        //    value is only a Number if it already is one.
        let searchElement = args[0]
        let skippedEl = args.count > 1 ? args[1] : .undefined
        let toSkip: Double
        if skippedEl.isUndefined {
            toSkip = 0
        } else {
            if !skippedEl.isNumber {
                try jsIteratorCloseUnderlying(realm, receiver, masked: true)
                throw realm.throwTypeError("Iterator.prototype.includes: skippedElements is not a Number")
            }
            let n = skippedEl.numberValue
            let integral = !n.isNaN && !n.isInfinite && n == n.rounded()
            if !(n == .infinity || n == -.infinity || integral) {
                try jsIteratorCloseUnderlying(realm, receiver, masked: true)
                throw realm.throwTypeError("Iterator.prototype.includes: skippedElements must be an integral Number")
            }
            if n < -0.0 {
                try jsIteratorCloseUnderlying(realm, receiver, masked: true)
                throw realm.throwRangeError("Iterator.prototype.includes: skippedElements is out of range")
            }
            if n.isFinite && n > 9007199254740991.0 {
                try jsIteratorCloseUnderlying(realm, receiver, masked: true)
                throw realm.throwRangeError("Iterator.prototype.includes: skippedElements is out of range")
            }
            toSkip = n
        }

        // 3. Read next exactly once (the getter is consulted here) and cache it.
        let nextMethod = try realm.getV(receiver, heap.key("next"))
        guard heap.isCallable(nextMethod) else {
            throw realm.throwTypeError("Iterator.prototype.includes: 'next' must be callable")
        }
        // A getter may have returned a function nothing else references.
        let rootedNext = heap.root(nextMethod)
        defer { heap.popRoots(to: rootedNext.slot) }

        // 4. Skip the first toSkip elements (or until exhaustion).
        var skipped: Double = 0
        while skipped < toSkip {
            let step = try jsIteratorStep(realm, receiver, nextMethod)
            if step.0 { return .false }
            skipped += 1
        }

        // 5. Search: on match close the underlying iterator (and propagate
        //    any close errors), then return true. Exhaustion returns false.
        while true {
            let step = try jsIteratorStep(realm, receiver, nextMethod)
            if step.0 { return .false }
            if heap.sameValueZero(step.1, searchElement) {
                try jsIteratorCloseUnderlying(realm, receiver, masked: false)
                return .true
            }
        }
    }

    // join: interpolate the receiver's values into a single string.
    _ = realm.defineMethod(itp, "join", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let heap = realm.heap
        let receiver = args.this

        // 1. The receiver must be an object.
        guard receiver.isObject else {
            throw realm.throwTypeError("'Iterator.prototype.join' this value is not an object")
        }

        let depth = heap.rootDepth
        defer { heap.popRoots(to: depth) }

        // 2. The separator: undefined -> ","; otherwise it is ToString-coerced.
        //    A coercion error closes the underlying iterator (masked) and
        //    the original error propagates. The receiver is consulted only
        //    after the separator is coerced (pinned-test order).
        let separator: JSValue
        let separatorArg = args.count > 0 ? args[0] : .undefined
        if separatorArg.isUndefined {
            separator = heap.atom(",")
        } else {
            do throws(JSThrow) {
                separator = try realm.toStringValue(separatorArg)
            } catch {
                let original = realm.pendingException
                _ = heap.root(original)
                try jsIteratorCloseUnderlying(realm, receiver, masked: true)
                throw realm.throwValue(original)
            }
        }
        _ = heap.root(separator)

        // 3. Read next exactly once.
        let nextMethod = try realm.getV(receiver, heap.key("next"))
        guard heap.isCallable(nextMethod) else {
            throw realm.throwTypeError("Iterator.prototype.join: 'next' must be callable")
        }
        _ = heap.root(nextMethod)

        // 4. Walk the iterator, collecting the coerced contents.
        var builder = JSStringBuilder()
        var first = true
        var k = 0
        let loopDepth = heap.rootDepth
        while true {
            heap.popRoots(to: loopDepth)
            let res = try realm.call(nextMethod, this: receiver, args: [])
            guard res.isObject else {
                throw realm.throwTypeError("Iterator result " + realm.describeForError(res) + " is not an object")
            }
            _ = heap.root(res)
            let doneRaw = try realm.getV(res, heap.names.done)
            if heap.toBoolean(doneRaw) { break }
            let value = try realm.getV(res, heap.names.value)
            _ = heap.root(value)
            if !value.isNullish {
                let s: JSValue
                do throws(JSThrow) {
                    s = try realm.toStringValue(value)
                } catch {
                    let original = realm.pendingException
                    _ = heap.root(original)
                    try jsIteratorCloseUnderlying(realm, receiver, masked: true)
                    throw realm.throwValue(original)
                }
                if !first { realm.jsAppend(&builder, separator) }
                realm.jsAppend(&builder, s)
            } else {
                if !first { realm.jsAppend(&builder, separator) }
            }
            first = false
            try realm.jsTick(k)
            k += 1
        }

        let r = heap.newString(builder)
        try realm.jsCheckAlloc()
        return r
    }
    _ = realm.defineMethod(itp, "chunks", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let receiver = args.this
        guard receiver.isObject else {
            throw realm.throwTypeError("'Iterator.prototype.chunks' this value is not an object")
        }
        let size = try jsIteratorWindowSize(realm, receiver, args[0], "Iterator.prototype.chunks: chunkSize")
        return try jsNewIteratorHelper(realm, receiver, size: size, flags: [])
    }
    _ = realm.defineMethod(itp, "windows", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let heap = realm.heap
        let receiver = args.this
        guard receiver.isObject else {
            throw realm.throwTypeError("'Iterator.prototype.windows' this value is not an object")
        }
        let size = try jsIteratorWindowSize(realm, receiver, args[0], "Iterator.prototype.windows: windowSize")
        var flags: JSObjectFlags = [.user0]
        let undersized = args[1]
        if !undersized.isUndefined {
            if undersized.isString && heap.sameValue(undersized, heap.atom("allow-partial")) {
                flags.insert(.user1)
            } else if !(undersized.isString && heap.sameValue(undersized, heap.atom("only-full"))) {
                try jsIteratorCloseUnderlying(realm, receiver, masked: true)
                throw realm.throwTypeError("Iterator.prototype.windows: undersized must be 'only-full' or 'allow-partial'")
            }
        }
        return try jsNewIteratorHelper(realm, receiver, size: size, flags: flags)
    }

    jsInstallIteratorHelperPrototype(realm, itp)
}

// MARK: Iterator helpers (chunks / windows)

private enum JSIterHelperState {
    static let suspendedStart: Int64 = 0
    static let suspendedYield: Int64 = 1
    static let executing: Int64 = 2
    static let completed: Int64 = 3
}

private let jsIterHelperHeader = 2

private func jsInstallIteratorHelperPrototype(_ realm: JSRealm, _ itp: JSValue) {
    let heap = realm.heap
    let p = heap.newObject(proto: itp)
    realm.setIntrinsic(.iteratorHelperPrototype, p)

    _ = realm.defineMethod(p, "next", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let it = args.this
        let state = try jsIterHelperEnter(realm, it, "next")
        if state == JSIterHelperState.completed { return try realm.iterResult(.undefined, done: true) }
        jsIterHelperSetState(realm.heap, it, JSIterHelperState.executing)
        do throws(JSThrow) {
            return try jsIterHelperResume(realm, it)
        } catch {
            jsIterHelperComplete(realm.heap, it)
            throw error
        }
    }
    _ = realm.defineMethod(p, "return", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let heap = realm.heap
        let it = args.this
        let state = try jsIterHelperEnter(realm, it, "return")
        if state == JSIterHelperState.completed { return try realm.iterResult(.undefined, done: true) }
        let underlying = heap.slot(it, 0)
        let r = heap.root(underlying)
        defer { heap.popRoots(to: r.slot) }
        if state == JSIterHelperState.suspendedStart {
            // Completed before the close: a reentrant call sees a done helper.
            jsIterHelperComplete(heap, it)
            try jsIteratorCloseUnderlying(realm, underlying, masked: false)
        } else {
            // Running during the close: a reentrant call is a TypeError.
            jsIterHelperSetState(heap, it, JSIterHelperState.executing)
            defer { jsIterHelperComplete(heap, it) }
            try jsIteratorCloseUnderlying(realm, underlying, masked: false)
        }
        return try realm.iterResult(.undefined, done: true)
    }
    let tagKey = JSPropertyKey.symbol(heap.symbolsWellKnown.toStringTag.handle)
    _ = heap.defineOwnProperty(p, tagKey, .data(realm.string("Iterator Helper"), [.configurable]))
}

/// Validate a chunk/window size (no coercion); closes the underlying iterator
/// (masked) before throwing.
private func jsIteratorWindowSize(_ realm: JSRealm, _ O: JSValue, _ v: JSValue,
                                  _ what: String) throws(JSThrow) -> Int64 {
    let n = v.isNumber ? v.numberValue : .nan
    guard n.isFinite && n == n.rounded() else {
        try jsIteratorCloseUnderlying(realm, O, masked: true)
        throw realm.throwTypeError(what + " must be an integral Number")
    }
    guard n >= 1 && n <= 4294967295.0 else {
        try jsIteratorCloseUnderlying(realm, O, masked: true)
        throw realm.throwRangeError(what + " is out of range")
    }
    return Int64(n)
}

/// Read the underlying next method once and build the helper object.
private func jsNewIteratorHelper(_ realm: JSRealm, _ O: JSValue, size: Int64,
                                 flags: JSObjectFlags) throws(JSThrow) -> JSValue {
    let heap = realm.heap
    let next = try realm.getV(O, heap.key("next"))
    let r = heap.root(next)
    defer { heap.popRoots(to: r.slot) }
    let it = heap.newObject(proto: realm.intrinsic(.iteratorHelperPrototype), kind: .iteratorHelper,
                            flags: flags.union(.extensible))
    heap.setSlots(it, [O, next])
    heap.setInternalInt(it, size)
    try realm.jsCheckAlloc()
    return it
}

/// The helper's state, after the receiver and reentrancy checks.
private func jsIterHelperEnter(_ realm: JSRealm, _ it: JSValue, _ method: String) throws(JSThrow) -> Int64 {
    guard realm.heap.kind(it) == .iteratorHelper else {
        throw realm.throwTypeError(method + " method called on an incompatible receiver " + realm.describeForError(it))
    }
    let state = realm.heap.internalInt(it) >> 60
    if state == JSIterHelperState.executing { throw realm.throwTypeError("Iterator helper is already running") }
    return state
}

private func jsIterHelperSetState(_ heap: JSHeap, _ it: JSValue, _ state: Int64) {
    heap.setInternalInt(it, (heap.internalInt(it) & 0x0FFF_FFFF_FFFF_FFFF) | state << 60)
}

/// Mark the helper done and drop everything it holds.
private func jsIterHelperComplete(_ heap: JSHeap, _ it: JSValue) {
    jsIterHelperSetState(heap, it, JSIterHelperState.completed)
    heap.setSlots(it, [.undefined, .undefined])
}

/// Step the underlying iterator until there is an array to yield or it ends.
private func jsIterHelperResume(_ realm: JSRealm, _ it: JSValue) throws(JSThrow) -> JSValue {
    let heap = realm.heap
    let isWindows = heap.flags(it).contains(.user0)
    let allowPartial = heap.flags(it).contains(.user1)
    let size = Int(heap.internalInt(it) & 0xFFFF_FFFF)
    var k = 0
    while true {
        let (done, value) = try jsIteratorStep(realm, heap.slot(it, 0), heap.slot(it, 1))
        let count = heap.slotCount(it) - jsIterHelperHeader
        if done {
            // A remainder: the last short chunk, or the only short window.
            let partial = count > 0 && (isWindows ? allowPartial && count < size : true)
            if !partial {
                jsIterHelperComplete(heap, it)
                return try realm.iterResult(.undefined, done: true)
            }
            let array = jsIterHelperArray(realm, it, head: 0)
            jsIterHelperComplete(heap, it)
            return try realm.iterResult(array, done: false)
        }

        var head = Int((heap.internalInt(it) >> 32) & 0x0FFF_FFFF)
        if isWindows && count == size {
            // Slide: the new value replaces the oldest.
            heap.setSlot(it, jsIterHelperHeader + head, value)
            head = (head + 1) % size
            heap.setInternalInt(it, (heap.internalInt(it) & ~(0x0FFF_FFFF << 32)) | Int64(head) << 32)
        } else {
            if count >= heap.limits.maxDenseArrayLength { throw realm.throwRangeError("Too many elements") }
            if !heap.appendSlotValue(it, value) { throw JSThrow() }
        }

        if heap.slotCount(it) - jsIterHelperHeader == size {
            let array = jsIterHelperArray(realm, it, head: head)
            let r = heap.root(array)
            defer { heap.popRoots(to: r.slot) }
            try realm.jsCheckAlloc()
            // A chunk starts over; a window keeps its values.
            if !isWindows { heap.setSlots(it, [heap.slot(it, 0), heap.slot(it, 1)]) }
            jsIterHelperSetState(heap, it, JSIterHelperState.suspendedYield)
            return try realm.iterResult(array, done: false)
        }
        try realm.jsTick(k)
        k &+= 1
    }
}

/// A new array of the buffered values, oldest (at `head`) first (allocates;
/// the result is unrooted).
private func jsIterHelperArray(_ realm: JSRealm, _ it: JSValue, head: Int) -> JSValue {
    let heap = realm.heap
    let count = heap.slotCount(it) - jsIterHelperHeader
    var values: [JSValue] = []
    values.reserveCapacity(count)
    for i in 0..<count { values.append(heap.slot(it, jsIterHelperHeader + (head + i) % count)) }
    return realm.jsNewArray(values)
}

// MARK: includes helpers (not callable from user JS)

/// One step of an underlying iterator: invoke `next` (this = O) and extract
/// (done, value). Mirrors the VM's `iteratorStep` semantics for the
/// external-iterator case: propagates next/done/value abrupt completions.
func jsIteratorStep(_ realm: JSRealm, _ O: JSValue, _ next: JSValue) throws(JSThrow) -> (Bool, JSValue) {
    let heap = realm.heap
    let res = try realm.call(next, this: O, args: [])
    guard res.isObject else {
        throw realm.throwTypeError("Iterator result " + realm.describeForError(res) + " is not an object")
    }
    let r = heap.root(res)
    defer { heap.popRoots(to: r.slot) }
    if heap.toBoolean(try realm.getV(res, heap.names.done)) { return (true, .undefined) }
    return (false, try realm.getV(res, heap.names.value))
}

/// Close an underlying iterator by calling its `return` method (the getter is
/// consulted). With `masked: true` every error of the close (getter, call,
/// non-callable return, non-object result) is swallowed, so a validation
/// error is preserved; with `masked: false`, close errors propagate. A
/// nullish return method skips the close silently (e.g. array values
/// iterators have no `return`).
func jsIteratorCloseUnderlying(_ realm: JSRealm, _ O: JSValue, masked: Bool) throws(JSThrow) {
    if masked {
        do { try jsIteratorCloseUnderlyingImpl(realm: realm, O: O) } catch { /* masked */ return }
        return
    }
    try jsIteratorCloseUnderlyingImpl(realm: realm, O: O)
}

private func jsIteratorCloseUnderlyingImpl(realm: JSRealm, O: JSValue) throws(JSThrow) {
    let heap = realm.heap
    let ret = try realm.getV(O, heap.key("return"))
    if ret.isNullish { return }
    guard heap.isCallable(ret) else {
        throw realm.throwTypeError("iterator.return is not a function")
    }
    let res = try realm.call(ret, this: O, args: [])
    guard res.isObject else {
        throw realm.throwTypeError("Iterator result " + realm.describeForError(res) + " is not an object")
    }
}
