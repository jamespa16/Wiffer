// The Date object (ROADMAP Phase 9C): constructor forms, Date.now / parse /
// UTC, every getter and setter (local and UTC), the string conversions,
// toISOString / toJSON, @@toPrimitive and the Annex B getYear / setYear /
// toGMTString, wrapping the pure date math in jsdate.swift.
//
// A Date object is kind .date with its time value in slot 0 (a number,
// NaN for an invalid date). The current time comes from the embedder's
// `realm.nowMs` hook (0 when unset, so host tests are deterministic); the
// local zone is `realm.dateZone` (UTC by default).

extension JSRealm {
    func b2DateNow() -> Double { nowMs?() ?? 0 }

    func b2ThisTime(_ t: JSValue) throws(JSThrow) -> Double {
        guard t.isObject, heap.kind(t) == .date else { throw throwTypeError("this is not a Date object.") }
        return heap.slot(t, 0).numberValue
    }

    func b2Bytes(_ b: [UInt8]) -> JSValue { heap.newString(latin1: b) }

    /// Fields of local time (or UTC) as doubles: year, month, date, h, m, s, ms.
    func b2DateParts(_ t: Double, utc: Bool) -> [Double] {
        let lt = utc ? t : jsDateLocalTime(t, dateZone)
        guard let f = jsDateFields(lt) else { return [Double](repeating: .nan, count: 7) }
        return [Double(f.year), Double(f.month), Double(f.day), Double(f.hour), Double(f.minute), Double(f.second), Double(f.ms)]
    }

    /// Time value from a constructor-style argument list (local or UTC).
    func b2DateFromArgs(_ args: JSArgs, utc: Bool) throws(JSThrow) -> Double {
        var n: [Double] = [.nan, 0, 1, 0, 0, 0, 0]
        for i in 0..<min(args.count, 7) { n[i] = try toNumber(args[i]) }
        let t = jsDateFromComponents(n[0], n[1], n[2], n[3], n[4], n[5], n[6])
        return jsDateTimeClip(utc ? t : jsDateUTC(t, dateZone))
    }

    func b2NewDate(_ proto: JSValue, _ tv: Double) -> JSValue {
        let rd = heap.rootDepth
        defer { heap.popRoots(to: rd) }
        _ = heap.root(proto)
        let o = heap.newObject(proto: proto, kind: .date)
        _ = heap.setSlots(o, [.number(tv)])
        return o
    }
}

func jsInstallDate(_ realm: JSRealm) {
    let heap = realm.heap
    let dp = heap.newObject(proto: realm.objectPrototype)
    realm.setIntrinsic(.datePrototype, dp)
    let ctor = realm.defineConstructor("Date", length: 7, prototype: dp, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        if !args.isConstruct {
            return realm.b2Bytes(jsDateToString(realm.b2DateNow(), realm.dateZone))
        }
        var tv: Double
        if args.count == 0 {
            tv = realm.b2DateNow()
        } else if args.count == 1 {
            let v = args[0]
            if v.isObject && realm.heap.kind(v) == .date {
                tv = realm.heap.slot(v, 0).numberValue
            } else {
                let p = try realm.toPrimitive(v)
                if p.isString {
                    tv = jsDateParse(realm.heap.stringUnits(p), realm.dateZone)
                } else {
                    tv = jsDateTimeClip(try realm.toNumber(p))
                }
            }
        } else {
            tv = try realm.b2DateFromArgs(args, utc: false)
        }
        let proto = try realm.prototype(forNewTarget: args.newTarget, default: .datePrototype)
        return realm.b2NewDate(proto, tv)
    })
    realm.setIntrinsic(.dateConstructor, ctor)
    realm.defineMethod(ctor, "now", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        .number(realm.b2DateNow())
    }
    realm.defineMethod(ctor, "parse", length: 1, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let s = try realm.b2Str(args[0])
        return .number(jsDateParse(realm.heap.stringUnits(s), realm.dateZone))
    })
    realm.defineMethod(ctor, "UTC", length: 7) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        .number(try realm.b2DateFromArgs(args, utc: true))
    }

    // Getters.
    func getter(_ name: String, _ utc: Bool, _ idx: Int) {
        realm.defineMethod(dp, name, length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let t = try realm.b2ThisTime(args.this)
            if t.isNaN { return .nan }
            return .number(realm.b2DateParts(t, utc: utc)[idx])
        }
    }
    getter("getFullYear", false, 0); getter("getUTCFullYear", true, 0)
    getter("getMonth", false, 1); getter("getUTCMonth", true, 1)
    getter("getDate", false, 2); getter("getUTCDate", true, 2)
    getter("getHours", false, 3); getter("getUTCHours", true, 3)
    getter("getMinutes", false, 4); getter("getUTCMinutes", true, 4)
    getter("getSeconds", false, 5); getter("getUTCSeconds", true, 5)
    getter("getMilliseconds", false, 6); getter("getUTCMilliseconds", true, 6)
    func dayGetter(_ name: String, _ utc: Bool) {
        realm.defineMethod(dp, name, length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let t = try realm.b2ThisTime(args.this)
            if t.isNaN { return .nan }
            return .number(jsDateWeekDay(utc ? t : jsDateLocalTime(t, realm.dateZone)))
        }
    }
    dayGetter("getDay", false); dayGetter("getUTCDay", true)
    realm.defineMethod(dp, "getTime", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        .number(try realm.b2ThisTime(args.this))
    }
    realm.defineMethod(dp, "valueOf", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        .number(try realm.b2ThisTime(args.this))
    }
    realm.defineMethod(dp, "getTimezoneOffset", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let t = try realm.b2ThisTime(args.this)
        if t.isNaN { return .nan }
        return .number(jsDateTimezoneOffsetMinutes(t, realm.dateZone))
    }
    realm.defineMethod(dp, "getYear", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let t = try realm.b2ThisTime(args.this)
        if t.isNaN { return .nan }
        return .number(realm.b2DateParts(t, utc: false)[0] - 1900)
    }

    // Setters: `first` is the index of the first field set, `maxArgs` how many it takes.
    func setter(_ name: String, _ utc: Bool, _ first: Int, _ maxArgs: Int) {
        realm.defineMethod(dp, name, length: maxArgs) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let t = try realm.b2ThisTime(args.this)
            var vals: [Double] = []
            let n = max(1, min(args.count, maxArgs))
            for i in 0..<n { vals.append(try realm.toNumber(args[i])) }
            var base = t
            if t.isNaN {
                if first != 0 { return .nan }
                base = 0
            }
            var p = realm.b2DateParts(base, utc: utc || t.isNaN)
            if t.isNaN && !utc { p = realm.b2DateParts(0, utc: true) }
            for i in 0..<n { p[first + i] = vals[i] }
            let date = jsDateMakeDate(jsDateMakeDay(p[0], p[1], p[2]), jsDateMakeTime(p[3], p[4], p[5], p[6]))
            let tv = jsDateTimeClip(utc ? date : jsDateUTC(date, realm.dateZone))
            realm.heap.setSlot(args.this, 0, .number(tv))
            return .number(tv)
        }
    }
    setter("setFullYear", false, 0, 3); setter("setUTCFullYear", true, 0, 3)
    setter("setMonth", false, 1, 2); setter("setUTCMonth", true, 1, 2)
    setter("setDate", false, 2, 1); setter("setUTCDate", true, 2, 1)
    setter("setHours", false, 3, 4); setter("setUTCHours", true, 3, 4)
    setter("setMinutes", false, 4, 3); setter("setUTCMinutes", true, 4, 3)
    setter("setSeconds", false, 5, 2); setter("setUTCSeconds", true, 5, 2)
    setter("setMilliseconds", false, 6, 1); setter("setUTCMilliseconds", true, 6, 1)
    realm.defineMethod(dp, "setTime", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        _ = try realm.b2ThisTime(args.this)
        let v = jsDateTimeClip(try realm.toNumber(args[0]))
        realm.heap.setSlot(args.this, 0, .number(v))
        return .number(v)
    }
    realm.defineMethod(dp, "setYear", length: 1) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let t = try realm.b2ThisTime(args.this)
        let y = try realm.toNumber(args[0])
        if y.isNaN {
            realm.heap.setSlot(args.this, 0, .nan)
            return .nan
        }
        let yi = jsTrunc(y)
        let yyyy = (yi >= 0 && yi <= 99) ? yi + 1900 : y
        var p = realm.b2DateParts(t.isNaN ? 0 : t, utc: t.isNaN)
        p[0] = yyyy
        let date = jsDateMakeDate(jsDateMakeDay(p[0], p[1], p[2]), jsDateMakeTime(p[3], p[4], p[5], p[6]))
        let tv = jsDateTimeClip(jsDateUTC(date, realm.dateZone))
        realm.heap.setSlot(args.this, 0, .number(tv))
        return .number(tv)
    }

    // String conversions.
    func stringer(_ name: String, _ f: @escaping (Double, JSDateZone) -> [UInt8]) {
        realm.defineMethod(dp, name, length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
            let t = try realm.b2ThisTime(args.this)
            return realm.b2Bytes(f(t, realm.dateZone))
        }
    }
    stringer("toString") { (t: Double, z: JSDateZone) -> [UInt8] in jsDateToString(t, z) }
    stringer("toDateString") { (t: Double, z: JSDateZone) -> [UInt8] in jsDateToDateString(t, z) }
    stringer("toTimeString") { (t: Double, z: JSDateZone) -> [UInt8] in jsDateToTimeString(t, z) }
    stringer("toLocaleString") { (t: Double, z: JSDateZone) -> [UInt8] in jsDateToLocaleString(t, z) }
    stringer("toLocaleDateString") { (t: Double, z: JSDateZone) -> [UInt8] in jsDateToLocaleDateString(t, z) }
    stringer("toLocaleTimeString") { (t: Double, z: JSDateZone) -> [UInt8] in jsDateToLocaleTimeString(t, z) }
    let utcString = realm.defineMethod(dp, "toUTCString", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let t = try realm.b2ThisTime(args.this)
        return realm.b2Bytes(jsDateToUTCString(t))
    }
    realm.defineValue(dp, "toGMTString", utcString)
    realm.defineMethod(dp, "toISOString", length: 0) { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let t = try realm.b2ThisTime(args.this)
        guard let b = jsDateToISOString(t) else { throw realm.throwRangeError("Invalid time value") }
        return realm.b2Bytes(b)
    }
    realm.defineMethod(dp, "toJSON", length: 1, b2Rooted { (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let o = try realm.toObject(args.this)
        _ = realm.heap.root(o)
        let tv = try realm.toPrimitive(o, hint: .number)
        if tv.isNumber && !tv.numberValue.isFinite { return .null }
        let f = try realm.getV(o, realm.b2.kToISOString)
        guard realm.heap.isCallable(f) else { throw realm.throwTypeError("toISOString is not a function") }
        return try realm.call(f, this: o, args: [])
    })
    let tp = realm.defineMethod(dp, "[Symbol.toPrimitive]", length: 1, key: .symbol(heap.symbolsWellKnown.toPrimitive.handle), b2Rooted {
        (realm: JSRealm, args: JSArgs) throws(JSThrow) -> JSValue in
        let o = args.this
        guard o.isObject else { throw realm.throwTypeError("Date.prototype[Symbol.toPrimitive] called on non-object") }
        let h = args[0]
        var stringFirst = false
        if h.isString {
            let hs = realm.heap.swiftString(h)
            if hs == "string" || hs == "default" { stringFirst = true }
            else if hs != "number" { throw realm.throwTypeError("Invalid hint: " + hs) }
        } else {
            throw realm.throwTypeError("Invalid hint")
        }
        let names = stringFirst ? [realm.heap.names.toString, realm.heap.names.valueOf] : [realm.heap.names.valueOf, realm.heap.names.toString]
        for k in names {
            let m = try realm.getV(o, k)
            if realm.heap.isCallable(m) {
                let r = try realm.call(m, this: o, args: [])
                if !r.isObject { return r }
            }
        }
        throw realm.throwTypeError("Cannot convert object to primitive value")
    })
    _ = heap.defineOwnProperty(dp, .symbol(heap.symbolsWellKnown.toPrimitive.handle), .data(tp, [.configurable]))
}
