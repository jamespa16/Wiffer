// Phase 6C: the shell runs programs from /bin, and `ps` and `kill`.
//
// A word that isn't a built-in command is looked up as /bin/<word> (or as
// a path, if it has a `/`), spawned with the words as argv, and waited for:
// its output (fds 1 and 2) is copied to this terminal as it arrives, and a
// fault report or a nonzero exit status is shown when it ends. Ctrl-C (or
// closing the terminal's window) while it runs kills it. A trailing `&`
// runs it in the background instead: the shell prints its pid and doesn't
// wait, its output goes to the kernel log, and it is reaped when it exits.

extension Shell {
    static func processCommands() -> [Command<T>] {
        [
            Command(name: "ps", args: "", help: "list processes") { sh, _ in
                for l in psLines() { sh.say(l) }
            },
            Command(name: "kill", args: "<pid>", help: "kill a process") { sh, args in
                guard args.count == 1, let pid = Int(args[0]) else { sh.say("usage: kill <pid>"); return }
                if !killProcess(pid) { sh.say("kill: no such process: \(pid)") }
            },
        ]
    }

    /// Run `words` as a program if one exists. False if there is none (the
    /// caller reports an unknown command).
    mutating func runProgram(_ words: [Substring]) -> Bool {
        var argv = words.map { String($0) }
        let background = argv.last == "&"
        if background { argv.removeLast() }
        guard let name = argv.first else { return false }
        let path = name.utf8.contains(0x2F) ? name : "/bin/" + name
        guard let node = try? fs.lookup(path, cwd: cwd), !node.isDirectory else { return false }
        guard let me = scheduler.current, !me.isMain else {
            say("\(name): programs can't run from the main loop")
            return true
        }
        let output = background ? nil : ProcessOutput(reader: me)
        let p: Process
        do throws(ExecError) {
            p = try spawnProcess(path: path, cwd: cwd, argv: argv, output: output, waiter: background ? nil : me)
        } catch {
            say("\(name): \(error.message)")
            return true
        }
        if background {
            say("[\(p.pid)]")
            return true
        }
        let status = waitProcess(p, sink: { bytes in self.write(String(decoding: bytes, as: UTF8.self)) },
                                 interrupt: { takeInterruptKey() })
        if let line = exitSummary(name, status) { say(line) }
        return true
    }
}

/// While the shell waits: Ctrl-C in its inbox (removed), or its window
/// closing (left for the terminal to see) means kill the program.
func takeInterruptKey() -> Bool {
    guard let me = scheduler.current else { return false }
    return schedLock.withIRQsOff {
        var i = me.inbox.head
        while i < me.inbox.events.count {
            switch me.inbox.events[i] {
            case .key(let k) where k.code == .char(0x03):
                me.inbox.events.remove(at: i)
                return true
            case .close:
                return true
            default:
                i += 1
            }
        }
        return false
    }
}
