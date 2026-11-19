// Phases 7E/7F/8A selftests: getrandom and time (random.swift), MSI-X on
// virtio-net, and the socket calls from ring 3 (/bin/nettest), with the
// cleanup checked from the kernel side afterwards: no sockets, UDP ports,
// echo identifiers or listeners left, connections gone (TIME_WAIT ones are
// dropped by the test before comparing memory), no frames or heap leaked.

func socketTests(_ t: inout SelfTest) {
    randomTests(&t)
    guard let stack = netStack else {
        print("  (no network interface: socket tests skipped)")
        return
    }
    if let nic = stack.dev as? VirtioNet {
        let before = netInterrupts
        _ = stack.sendEcho(to: stack.gateway, id: 0x7E7E, seq: 1)
        sleepMilliseconds(200)
        t.check("7F: virtio-net interrupts through MSI-X (when the x2APIC is on)",
                !x2apicEnabled || (nic.msixVector == Vector.net && netInterrupts > before))
    }
    guard (try? vfs.lookup("/bin/nettest")) != nil else {
        t.check("7E: /bin/nettest in the rootfs", false)
        return
    }
    let udp0 = stack.udpSockets.count
    let tcp0 = stack.tcp.connections.count
    let frames = pmm.freeFrames, splits = splitPages, heap0 = HeapUsage()

    let run = runProgramForTest(["nettest"])
    if run.status != .exited(0) || !has(run.output, " 0 failed") || has(run.output, "FAIL") { print(run.output) }
    t.check("7E: nettest passes from ring 3 (TCP/UDP/ICMP loopback, wait, bad pointers, limits, resolve, getrandom)",
            run.status == .exited(0) && has(run.output, " 0 failed") && !has(run.output, "FAIL"))

    // Let closing connections finish their FIN exchanges (or resets).
    let deadline = ticks + 300
    func settled() -> Bool {
        stack.tcp.connections.allSatisfy { $0.state == .timeWait || $0.state == .closed }
    }
    while !settled() && ticks < deadline { sleepMilliseconds(20) }
    t.check("7E: no sockets left after nettest (and its killed child)",
            liveSockets == 0 && socketsByPid.isEmpty && stack.echoHandlers.isEmpty)
    t.check("7E: UDP ports and TCP listeners released", stack.udpSockets.count == udp0 && stack.tcp.listeners.isEmpty)
    t.check("7E: every TCP connection closed (TIME_WAIT at most)", settled())
    for c in stack.tcp.connections where c.state == .timeWait { c.finish() }
    t.check("7E: the TCP table is back to its size before", stack.tcp.connections.count == tcp0)
    resolveTable.removeAll()
    let leaked = frames - pmm.freeFrames - (splitPages - splits)
    if leaked != 0 { print("  pmm: \(leaked) frames leaked by the socket tests") }
    t.check("7E: no frames leaked by sockets", leaked == 0)
    // (Dictionaries and lists keep their capacity: allow a few blocks.)
    let heapNow = HeapUsage()
    if heapNow.blocks > heap0.blocks + 8 { print("  heap: \(heap0.blocks) -> \(heapNow.blocks) blocks") }
    t.check("7E: no heap leaked by sockets", heapNow.blocks <= heap0.blocks + 8 && heapNow.largeFrames == heap0.largeFrames)
}
