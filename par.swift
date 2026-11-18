// Phase T: the `par` demo. Count the primes below n with one `.any` task per
// online CPU, then with a single task, and compare wall time. Workers never
// print (CPU 0's console flush isn't synchronised with stdoutLock); each
// posts one `.message` to the shell's task, packed as
//   worker << 48 | cpu << 40 | count
// (count < 2^40). Workers share nothing and write nothing shared.

let parChunk = 4096
let parDefaultN = 3_000_000
let parMaxN = 100_000_000

/// Primes in [lo, hi) by trial division with odd divisors.
func countPrimes(from lo: Int, to hi: Int) -> Int {
    var count = 0
    var n = max(lo, 2)
    while n < hi {
        if n == 2 { count += 1 }
        else if n & 1 == 1 {
            var isPrime = true
            var d = 3
            while d * d <= n {
                if n % d == 0 { isPrime = false; break }
                d += 2
            }
            if isPrime { count += 1 }
        }
        n += 1
    }
    return count
}

/// Worker `w` of `workers`: chunks w, w + workers, ... of [0, n). Strided so
/// the work balances (larger numbers cost more). Yields after each chunk so
/// the watchdog sees a cooperating task.
func countPrimesStrided(below n: Int, worker w: Int, of workers: Int, yielding: Bool = true) -> Int {
    var total = 0
    var lo = w * parChunk
    while lo < n {
        total += countPrimes(from: lo, to: min(lo + parChunk, n))
        lo += workers * parChunk
        if yielding { yield() }
    }
    return total
}

struct ParResult { var worker: Int; var cpu: Int; var count: Int }

/// Run `workers` tasks and gather their messages in the current task. Other
/// events that arrive meanwhile (keys...) are kept and re-posted afterwards.
/// Nil if a task couldn't be spawned.
func parRun(n: Int, workers: Int, me: Task) -> [ParResult]? {
    var spawned = 0
    for w in 0..<workers {
        let t = spawn("par\(w)", affinity: .any) {
            let c = countPrimesStrided(below: n, worker: w, of: workers)
            me.post(.message(w << 48 | currentCPU() << 40 | c))
        }
        if t == nil { break }
        spawned += 1
    }
    var results: [ParResult] = []
    var stash: [Event] = []
    while results.count < spawned {
        let e = waitEvent()
        if case .message(let m) = e {
            results.append(ParResult(worker: m >> 48, cpu: (m >> 40) & 0xFF, count: m & 0xFF_FFFF_FFFF))
        } else {
            stash.append(e) // a key, say: hand it back below
        }
    }
    for e in stash { me.post(e) }
    results.sort { $0.worker < $1.worker }
    return spawned == workers ? results : nil
}

/// The `par` command's output lines.
func parReport(n: Int, me: Task) -> [String] {
    let cpus = onlineCPUCount()
    var out = ["par: primes below \(n), \(cpus) worker\(cpus == 1 ? "" : "s") on \(cpus) CPU\(cpus == 1 ? "" : "s")"]
    let t0 = ticks
    guard let par = parRun(n: n, workers: cpus, me: me) else { return ["par: could not start the workers"] }
    let parTicks = Int(ticks - t0)
    var total = 0
    for r in par {
        out.append("  worker \(r.worker)  cpu \(r.cpu)  primes \(r.count)")
        total += r.count
    }
    let t1 = ticks
    guard let one = parRun(n: n, workers: 1, me: me) else { return ["par: could not start the worker"] }
    let singleTicks = Int(ticks - t1)
    let single = one[0].count
    let ms = 1000 / Int(timerHz)
    out.append("  parallel: \(total) primes in \(parTicks) ticks (\(parTicks * ms) ms)")
    out.append("  single:   \(single) primes in \(singleTicks) ticks (\(singleTicks * ms) ms) on cpu \(one[0].cpu)")
    if total != single {
        out.append("par: ERROR totals differ (\(total) parallel, \(single) single)")
    } else {
        let x100 = singleTicks * 100 / max(parTicks, 1)
        out.append("  speedup: \(x100 / 100).\(x100 % 100 < 10 ? "0" : "")\(x100 % 100)x")
    }
    return out
}

func parCommand(_ args: [Substring]) -> [String] {
    var n = parDefaultN
    if args.count > 1 { return ["usage: par [n]  (n from 2 to \(parMaxN))"] }
    if let a = args.first {
        guard let v = parseInt(a), v >= 2, v <= parMaxN else { return ["usage: par [n]  (n from 2 to \(parMaxN))"] }
        n = v
    }
    guard let me = scheduler.current, !me.isMain else { return ["par: needs a shell task"] }
    return parReport(n: n, me: me)
}

func parTests(_ t: inout SelfTest) {
    t.check("par: primes below 10, 100, 10000",
            countPrimes(from: 0, to: 10) == 4 && countPrimes(from: 0, to: 100) == 25
                && countPrimes(from: 0, to: 10000) == 1229)
    t.check("par: countPrimes edge cases",
            countPrimes(from: 0, to: 2) == 0 && countPrimes(from: 0, to: 3) == 1
                && countPrimes(from: 90, to: 100) == 1 && countPrimes(from: 100, to: 90) == 0)
    var sum = 0
    for w in 0..<3 { sum += countPrimesStrided(below: 20000, worker: w, of: 3, yielding: false) }
    t.check("par: strided shares add up (pi(20000) = 2262)", sum == 2262)
}
