// Phase 6E4: a minimal timed park, for wait()'s timeout.
//
// parkUntil(deadline) parks the current task until it is unparked or
// `ticks` reaches `deadline` (100 Hz). The deadlines sit in a small list
// that the main loop sweeps once per iteration (wakeDueDeadlines, CPU 0,
// task context; the main loop runs at least once per tick while it is
// the idle context). It is deliberately isolated in this file: Phase 6D's
// timed park / deadline-list API replaces the body of parkUntil (and this
// file), and nothing else needs to change.
//
// Resolution is one tick (10 ms), and a deadline is late while CPU 0 is
// busy with something that doesn't yield.

struct TimedWait {
    let task: Task
    let deadline: UInt64
}

var deadlineLock = SpinLock()
var timedWaits: [TimedWait] = []

func msToTicks(_ ms: UInt64) -> UInt64 { (ms * timerHz + 999) / 1000 }

/// Park until unparked or `ticks >= deadline`. Like park(), wakeups can be
/// spurious: the caller re-checks its condition and the clock.
func parkUntil(_ deadline: UInt64) {
    guard let me = scheduler.current, !me.isMain else { return }
    if ticks >= deadline { return }
    let flags = deadlineLock.acquireIRQ()
    timedWaits.append(TimedWait(task: me, deadline: deadline))
    deadlineLock.releaseIRQ(flags)
    park()
    let f = deadlineLock.acquireIRQ()
    if let i = timedWaits.firstIndex(where: { $0.task === me }) { timedWaits.remove(at: i) }
    deadlineLock.releaseIRQ(f)
}

/// Unpark every task whose deadline has passed. Called by the main loop.
func wakeDueDeadlines() {
    guard !timedWaits.isEmpty else { return } // (racy read: a miss is caught next iteration)
    let now = ticks
    var due: [Task] = []
    let flags = deadlineLock.acquireIRQ()
    var i = 0
    while i < timedWaits.count {
        if timedWaits[i].deadline <= now {
            due.append(timedWaits[i].task)
            timedWaits.remove(at: i)
        } else {
            i += 1
        }
    }
    deadlineLock.releaseIRQ(flags)
    for t in due { unpark(t) }
}
