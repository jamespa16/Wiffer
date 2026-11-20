// The RegExp matcher: a backtracking interpreter for the bytecode in
// jsregexp_compile.swift with an explicit backtrack stack (no Swift
// recursion at all), a step budget and a stack cap.
//
// Backtrack stack entries are three Int32 words: (kind | v << 4, a, b).
//   restore    v = register, a = old value
//   branch     v = pc, a = pos
//   starG      v = pc to resume, a = pos reached, b = lowest pos (min done)
//   starL      v = pc of the starL instruction, a = pos, b = count so far
//   lookPos / lookNeg (barriers)  v = pc after the lookaround, a = pos at entry
// A failing path pops entries: restores are applied, the first branch-like
// entry resumes. A lookaround body that matches cuts the stack back to its
// barrier: a positive one keeps only the restore entries (captures stay,
// and are undone if the outer match backtracks past it); a negative one
// undoes everything and fails. A body that fails pops its barrier, which
// for a negative lookaround means success.

private enum JSReEntry {
    static let restore: Int32 = 0
    static let branch: Int32 = 1
    static let starG: Int32 = 2
    static let starL: Int32 = 3
    static let lookPos: Int32 = 4
    static let lookNeg: Int32 = 5
}

enum JSReAttempt { case matched, failed, steps, stack }

@inline(__always) private func jsReIsLineTerminator(_ c: UInt32) -> Bool {
    c == 0x0A || c == 0x0D || c == 0x2028 || c == 0x2029
}

@inline(__always) private func jsReIsWordUnit(_ c: UInt32, _ extra: Bool) -> Bool {
    if c < 0x80 {
        return (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39) || c == 0x5F
    }
    return extra && (c == 0x17F || c == 0x212A)
}

struct JSReMatcher<S: RandomAccessCollection> where S.Element: FixedWidthInteger & UnsignedInteger, S.Index == Int {
    let prog: JSRegExpProgram
    let s: S
    let base: Int
    let end: Int
    let code: [Int32]
    let sets: [UInt32]
    let caseRuns: [UInt64]
    let unicode: Bool
    let wordExtra: Bool
    let stepLimit: Int
    let maxStack: Int
    var regs: [Int32]
    var stack: [Int32]
    var steps = 0
    var overflow = false

    init(program: JSRegExpProgram, subject: S, stepLimit: Int) {
        prog = program
        s = subject
        base = subject.startIndex
        end = subject.count
        code = program.code
        sets = program.sets
        caseRuns = program.caseRuns
        unicode = program.flags.unicodeMode
        wordExtra = program.flags.unicodeMode && program.flags.ignoreCase
        self.stepLimit = stepLimit
        maxStack = max(program.maxBacktrackEntries, 16) * 3
        regs = program.scratchRegs
        stack = program.scratchStack
        program.scratchRegs = []
        program.scratchStack = []
    }

    mutating func giveBackScratch() {
        stack.removeAll(keepingCapacity: true)
        if stack.capacity > 1 << 16 { stack = [] }   // don't pin a huge stack
        prog.scratchRegs = regs
        prog.scratchStack = stack
    }

    @inline(__always) func unit(_ k: Int) -> UInt32 { UInt32(truncatingIfNeeded: s[base + k]) }

    /// The character at pos (pos < end) and the position after it.
    @inline(__always) func readF(_ pos: Int) -> (UInt32, Int) {
        let c = unit(pos)
        if unicode && jsReIsLead(c) && pos + 1 < end {
            let d = unit(pos + 1)
            if jsReIsTrail(d) { return (0x10000 + ((c - 0xD800) << 10) + (d - 0xDC00), pos + 2) }
        }
        return (c, pos + 1)
    }

    /// The character before pos (pos > 0) and the position before it.
    @inline(__always) func readB(_ pos: Int) -> (UInt32, Int) {
        let c = unit(pos - 1)
        if unicode && jsReIsTrail(c) && pos >= 2 {
            let d = unit(pos - 2)
            if jsReIsLead(d) { return (0x10000 + ((d - 0xD800) << 10) + (c - 0xDC00), pos - 2) }
        }
        return (c, pos - 1)
    }

    @inline(__always) func canon(_ c: UInt32) -> UInt32 { jsReCanonicalize(c, caseRuns, unicode: unicode) }

    func setHas(_ k: Int, _ c: UInt32) -> Bool {
        if c < 128 { return (sets[k + Int(c >> 5)] >> (c & 31)) & 1 != 0 }
        let fl = sets[k + 4]
        let x = fl & 2 != 0 ? canon(c) : c
        let n = Int(sets[k + 5])
        let r = k + JSReSetLayout.header
        var lo = 0, hi = n - 1
        var found = false
        while lo <= hi {
            let mid = (lo + hi) >> 1
            if x < sets[r + 2 * mid] { hi = mid - 1 } else if x > sets[r + 2 * mid + 1] { lo = mid + 1 } else { found = true; break }
        }
        return found != (fl & 1 != 0)
    }

    /// One character op at pos: the new position, or -1.
    @inline(__always) func matchOne(_ o: Int32, _ arg: Int32, _ pos: Int, backward: Bool) -> Int {
        let c: UInt32, np: Int
        if backward {
            if pos <= 0 { return -1 }
            (c, np) = readB(pos)
        } else {
            if pos >= end { return -1 }
            (c, np) = readF(pos)
        }
        let ok: Bool
        switch o {
        case JSReOp.char: ok = c == UInt32(bitPattern: arg)
        case JSReOp.charI: ok = canon(c) == UInt32(bitPattern: arg)
        case JSReOp.any: ok = !jsReIsLineTerminator(c)
        case JSReOp.anyAll: ok = true
        default: ok = setHas(Int(arg), c)
        }
        return ok ? np : -1
    }

    @inline(__always) mutating func push(_ kind: Int32, _ v: Int32, _ a: Int32, _ b: Int32 = 0) {
        if stack.count >= maxStack { overflow = true; return }
        stack.append(kind | v << 4)
        stack.append(a)
        stack.append(b)
    }

    @inline(__always) mutating func setReg(_ r: Int, _ v: Int32) {
        push(JSReEntry.restore, Int32(r), regs[r])
        regs[r] = v
    }

    func isWordAt(_ k: Int) -> Bool {
        k >= 0 && k < end && jsReIsWordUnit(unit(k), wordExtra)
    }

    mutating func run(from lastIndex: Int) -> JSRegExpResult {
        if lastIndex > end { return .noMatch }
        var start = max(0, lastIndex)
        if unicode && start > 0 && start < end && jsReIsTrail(unit(start)) && jsReIsLead(unit(start - 1)) { start -= 1 }
        let sticky = prog.flags.sticky
        if regs.count != prog.regCount { regs = [Int32](repeating: -1, count: prog.regCount) }
        while true {
            if prog.anchoredStart && start > 0 { return .noMatch }
            if !sticky && prog.firstChar >= 0 {
                let fc = UInt32(prog.firstChar)
                while start < end && unit(start) != fc { start += 1 }
                if start >= end { return .noMatch }
            }
            switch attempt(start) {
            case .matched:
                return .match(JSRegExpMatch(captures: Array(regs[0..<(2 * (prog.captureCount + 1))])))
            case .steps: return .stepLimit
            case .stack: return .stackLimit
            case .failed: break
            }
            if sticky || start >= end { return .noMatch }
            start += 1
            if unicode && start < end && jsReIsTrail(unit(start)) && jsReIsLead(unit(start - 1)) { start += 1 }
        }
    }

    /// Pop entries until one resumes (true) or the stack is empty (false).
    mutating func backtrack(_ pc: inout Int, _ pos: inout Int) -> Bool {
        while stack.count >= 3 {
            let t = stack.count - 3
            let kv = stack[t], a = stack[t + 1], b = stack[t + 2]
            stack.removeLast(3)
            let v = Int(kv >> 4)
            switch kv & 15 {
            case JSReEntry.restore:
                regs[v] = a
            case JSReEntry.branch:
                steps += 1
                pc = v; pos = Int(a)
                return true
            case JSReEntry.starG:
                steps += 1
                var np = Int(a) - 1
                if unicode && np > Int(b) && jsReIsTrail(unit(np)) && jsReIsLead(unit(np - 1)) { np -= 1 }
                if np > Int(b) { push(JSReEntry.starG, Int32(v), Int32(np), b) }
                pc = v; pos = np
                return true
            case JSReEntry.starL:
                steps += 1
                let mx = code[v + 2]
                if mx >= 0 && b >= mx { continue }
                let np = matchOne(code[v + 3], code[v + 4], Int(a), backward: false)
                if np < 0 { continue }
                push(JSReEntry.starL, Int32(v), Int32(np), b + 1)
                pc = v + 5; pos = np
                return true
            case JSReEntry.lookNeg:
                pc = v; pos = Int(a)
                return true
            default: // lookPos: the body failed, keep failing
                break
            }
        }
        return false
    }

    /// Index of the innermost lookaround barrier entry.
    func barrierIndex() -> Int {
        var t = stack.count - 3
        while t >= 0 {
            let k = stack[t] & 15
            if k == JSReEntry.lookPos || k == JSReEntry.lookNeg { return t }
            t -= 3
        }
        return -1
    }

    mutating func backrefMatch(_ n: Int, _ pos: Int, backward: Bool, fold: Bool) -> Int {
        let s0 = Int(regs[2 * n]), e0 = Int(regs[2 * n + 1])
        if s0 < 0 || e0 < 0 { return pos }
        let len = e0 - s0
        let from: Int
        if backward {
            if pos - len < 0 { return -1 }
            from = pos - len
        } else {
            if pos + len > end { return -1 }
            from = pos
        }
        steps += len
        if !fold {
            for k in 0..<len where unit(s0 + k) != unit(from + k) { return -1 }
        } else {
            var x = s0, y = from
            while x < e0 {
                let (c1, nx) = readF(x)
                if y >= from + len { return -1 }
                let (c2, ny) = readF(y)
                if canon(c1) != canon(c2) { return -1 }
                x = nx; y = ny
            }
            if y != from + len { return -1 }
        }
        return backward ? from : pos + len
    }

    mutating func attempt(_ start: Int) -> JSReAttempt {
        for k in 0..<regs.count { regs[k] = -1 }
        stack.removeAll(keepingCapacity: true)
        var pc = 0
        var pos = start
        while true {
            steps += 1
            if steps > stepLimit { return .steps }
            let o = code[pc]
            let bw = o & JSReOp.back != 0
            var ok = true
            switch o & 0xFF {
            case JSReOp.match:
                regs[0] = Int32(start)
                regs[1] = Int32(pos)
                return .matched
            case JSReOp.char, JSReOp.charI, JSReOp.any, JSReOp.anyAll, JSReOp.set:
                let np = matchOne(o & 0xFF, code[pc + 1], pos, backward: bw)
                if np < 0 { ok = false } else { pos = np; pc += JSReOp.length(o) }
            case JSReOp.bol:
                if pos == 0 { pc += 1 } else { ok = false }
            case JSReOp.eol:
                if pos == end { pc += 1 } else { ok = false }
            case JSReOp.bolM:
                if pos == 0 || jsReIsLineTerminator(unit(pos - 1)) { pc += 1 } else { ok = false }
            case JSReOp.eolM:
                if pos == end || jsReIsLineTerminator(unit(pos)) { pc += 1 } else { ok = false }
            case JSReOp.wordB, JSReOp.notWordB:
                let at = isWordAt(pos - 1) != isWordAt(pos)
                if at == (o == JSReOp.wordB) { pc += 1 } else { ok = false }
            case JSReOp.jump:
                pc = Int(code[pc + 1])
            case JSReOp.splitNext:
                push(JSReEntry.branch, code[pc + 1], Int32(pos))
                pc += 2
            case JSReOp.splitJump:
                push(JSReEntry.branch, Int32(pc + 2), Int32(pos))
                pc = Int(code[pc + 1])
            case JSReOp.save, JSReOp.savePos:
                setReg(Int(code[pc + 1]), Int32(pos))
                pc += 2
            case JSReOp.setZero:
                setReg(Int(code[pc + 1]), 0)
                pc += 2
            case JSReOp.reset:
                let lo = Int(code[pc + 1]), hi = Int(code[pc + 2])
                for r in lo..<hi where regs[r] != -1 { setReg(r, -1) }
                pc += 3
            case JSReOp.emptyCheck:
                if Int32(pos) == regs[Int(code[pc + 1])] { ok = false } else { pc += 2 }
            case JSReOp.loop:
                let c = Int(code[pc + 1])
                let cnt = regs[c], mn = code[pc + 2], mx = code[pc + 3]
                let exit = code[pc + 5]
                if cnt < mn {
                    pc += 6
                } else if mx >= 0 && cnt >= mx {
                    pc = Int(exit)
                } else if code[pc + 4] != 0 {
                    push(JSReEntry.branch, exit, Int32(pos))
                    pc += 6
                } else {
                    push(JSReEntry.branch, Int32(pc + 6), Int32(pos))
                    pc = Int(exit)
                }
            case JSReOp.loopTail:
                let c = Int(code[pc + 1])
                let cnt = regs[c], p = Int(code[pc + 3])
                if p >= 0 && cnt >= code[pc + 2] && Int32(pos) == regs[p] {
                    ok = false
                } else {
                    setReg(c, cnt &+ 1)
                    pc = Int(code[pc + 4])
                }
            case JSReOp.backref, JSReOp.backrefI:
                let np = backrefMatch(Int(code[pc + 1]), pos, backward: bw, fold: o & 0xFF == JSReOp.backrefI)
                if np < 0 { ok = false } else { pos = np; pc += 2 }
            case JSReOp.look:
                let neg = code[pc + 1] & 1 != 0
                push(neg ? JSReEntry.lookNeg : JSReEntry.lookPos, code[pc + 2], Int32(pos))
                pc += 3
            case JSReOp.lookEnd:
                let t = barrierIndex()
                if t < 0 { ok = false; break }
                let kind = stack[t] & 15
                let entryPos = Int(stack[t + 1])
                if kind == JSReEntry.lookPos {
                    var w = t
                    var k = t + 3
                    while k < stack.count {
                        if stack[k] & 15 == JSReEntry.restore {
                            stack[w] = stack[k]; stack[w + 1] = stack[k + 1]; stack[w + 2] = stack[k + 2]
                            w += 3
                        }
                        k += 3
                    }
                    steps += (stack.count - t) / 3
                    stack.removeLast(stack.count - w)
                    pos = entryPos
                    pc += 1
                } else {
                    while stack.count > t + 3 {
                        let e = stack.count - 3
                        if stack[e] & 15 == JSReEntry.restore { regs[Int(stack[e] >> 4)] = stack[e + 1] }
                        stack.removeLast(3)
                        steps += 1
                    }
                    stack.removeLast(3)
                    ok = false
                }
            case JSReOp.starG, JSReOp.starL:
                let mn = Int(code[pc + 1]), mx = Int(code[pc + 2])
                let ao = code[pc + 3], aa = code[pc + 4]
                var count = 0
                var p = pos
                let greedy = o == JSReOp.starG
                let limit = greedy ? (mx < 0 ? Int.max : mx) : mn
                var minPos = pos
                while count < limit {
                    let np = matchOne(ao, aa, p, backward: false)
                    if np < 0 { break }
                    p = np
                    count += 1
                    if count == mn { minPos = p }
                    steps += 1
                    if steps > stepLimit { return .steps }
                }
                if count < mn { ok = false; break }
                if mn == 0 { minPos = pos }
                if greedy {
                    if p > minPos { push(JSReEntry.starG, Int32(pc + 5), Int32(p), Int32(minPos)) }
                } else {
                    push(JSReEntry.starL, Int32(pc), Int32(p), Int32(count))
                }
                pos = p
                pc += 5
            default: // fail
                ok = false
            }
            if overflow { return .stack }
            if !ok {
                if !backtrack(&pc, &pos) { return .failed }
                if overflow { return .stack }
            }
        }
    }
}
