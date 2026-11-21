// CPU-0-only cooperative mutex regressions. These deliberately sleep while
// holding the mutex, as virtio DMA does, and exercise recursive acquisition.
final class DiskLockTestState {
    let lock = DiskOperationLock()
    var active = 0
    var completed = 0
    var failures = 0
    var progress = 0
}

final class DiskReadTestState {
    var done = false
    var valid = true
}

func diskParkingTests(_ t: inout SelfTest, _ disk: VirtioBlock) {
    guard let expected = try? disk.read(0, count: 1) else { return }
    let state = DiskReadTestState()
    let parked = disk.parkedRequests
    let freed = withUnsafeMutablePointer(to: &tasksFreed) { atomicLoad($0) }
    let spawned = spawn("disk-read", affinity: .cpu(0), {
        for _ in 0..<8 {
            if (try? disk.read(0, count: 1)) != expected { state.valid = false }
        }
        state.done = true
    }) != nil
    let deadline = ticks + 5 * timerHz
    while !state.done && ticks < deadline { yield() }
    t.check("virtio: task reads complete through sleeping requests", spawned && state.done && state.valid
        && disk.parkedRequests > parked)
    t.check("virtio: sleeping reader task freed", waitTasksFreed(since: freed, spawned ? 1 : 0))
}

func diskLockTests(_ t: inout SelfTest) {
    let state = DiskLockTestState()
    let freed = withUnsafeMutablePointer(to: &tasksFreed) { atomicLoad($0) }
    var spawned = 0
    for _ in 0..<2 {
        if spawn("disk-mutex", affinity: .cpu(0), {
            for _ in 0..<4 {
                state.lock.acquire()
                state.lock.acquire()
                state.active += 1
                if state.active != 1 { state.failures += 1 }
                let until = ticks + 2
                while ticks < until { parkUntil(until) }
                state.lock.release()
                // Releasing just the nested acquisition must keep ownership
                // while another contender gets a chance to run.
                yield()
                if state.active != 1 { state.failures += 1 }
                state.active -= 1
                state.lock.release()
                yield()
            }
            state.completed += 1
        }) != nil { spawned += 1 }
    }
    let deadline = ticks + 5 * timerHz
    while state.completed < spawned && ticks < deadline {
        if state.active != 0 { state.progress += 1 }
        yield()
    }
    t.check("disk mutex: both contenders finish", spawned == 2 && state.completed == 2)
    t.check("disk mutex: recursive ownership survives sleep and yield", state.failures == 0 && state.active == 0)
    t.check("disk mutex: other CPU-0 work runs while owner sleeps", state.progress > 0)
    t.check("disk mutex: finished tasks are freed", waitTasksFreed(since: freed, spawned))
}
