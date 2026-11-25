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
//   includes is implemented (Stage 1) with the full semantics of the
//   pinned Test262 commit's Iterator Includes proposal:
//     1. the receiver must be an object (TypeError otherwise),
//     2. skippedElements is undefined -> +0F; otherwise it must already be
//        one of +Infinity, -Infinity, or an integral Number (NaN and
//        non-Number values are rejected with TypeError) — no coercion is
//        applied, so no valueOf/toString is called,
//     3. toSkip < -0F or (finite and > 2**53 - 1) -> RangeError,
//     4. on any validation failure the underlying iterator is closed and
//        the original error propagates (closing errors are masked),
//     5. the next method is read exactly once, immediately after
//        validation, before any iteration; a throwing next getter or a
//        non-callable next propagates without closing,
//     6. skip the first toSkip elements (done -> false), then iterate
//        with SameValueZero comparison; on a match the underlying iterator
//        is closed and true is returned, without any close on exhaustion
//        or on next/done/value abrupt completion,
//     7. on exhaustion, return false (return is never consulted).
//
// join / chunks / windows remain skeletons for later stages.
//
// Calls into existing infrastructure only (no VM / GC / parser changes):
//   realm.defineConstructor / defineMethod / newObject, and
//   realm.prototype(forNewTarget:default:) for the superconstructor path.

func jsInstallIterator(_ realm: JSRealm) {
    let heap = realm.heap
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

    // Helper methods with correct descriptors, still unimplemented (later stages).
    _ = realm.defineMethod(itp, "join", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        throw realm.throwTypeError("Iterator.prototype.join: not implemented yet")
    }
    _ = realm.defineMethod(itp, "chunks", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        throw realm.throwTypeError("Iterator.prototype.chunks: not implemented yet")
    }
    _ = realm.defineMethod(itp, "windows", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        throw realm.throwTypeError("Iterator.prototype.windows: not implemented yet")
    }
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
        throw realm.throwTypeError("Iterator.prototype.includes: iterator.return is not a function")
    }
    let res = try realm.call(ret, this: O, args: [])
    guard res.isObject else {
        throw realm.throwTypeError("Iterator result " + realm.describeForError(res) + " is not an object")
    }
}
