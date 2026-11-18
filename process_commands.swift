// Phase 6C/6E: the shell runs programs from /bin (and pipelines of them),
// and `ps` and `kill`.
//
// A word that isn't a built-in command is looked up as /bin/<word> (or as
// a path, if it has a `/`), spawned with the words as argv, and waited for.
// Resolution order, explicitly: built-in commands first (`cat`, `ls`, `echo`
// are still built in, for the in-kernel selftests and the serial flows),
// then /bin/<word>. A path with a `/` always runs the program, so
// `/bin/cat` is the ported one. Inside a pipeline every stage is a program
// (built-ins can't be piped), so `cat f | wc` runs /bin/cat and /bin/wc.
//
// 6E: a command line's programs share one ConsoleChannel (the terminal),
// and the shell, while it waits, is the console's pump (waitProcesses): it
// copies output to the terminal, feeds typed keys to the console's line
// discipline (so a program that reads stdin gets cooked lines, or raw keys
// after console_mode) and kills the programs on Ctrl-C or window close.
// `a | b` joins stdout to stdin with a pipe; the shell holds a count on each
// pipe end until every stage has its fds, so EOF arrives when the writer
// exits. `set affinity <cpu>` pins started programs to a CPU (until 6D, a
// program spinning in ring 3 on CPU 0 can't be interrupted).
// A trailing `&` runs the line in the background instead: the shell prints
// its pid and doesn't wait, its output goes to the kernel log, and it is
// reaped when it exits.

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
    /// caller reports an unknown command). `a | b | c` runs a pipeline.
    mutating func runProgram(_ words: [Substring]) -> Bool {
        var argv = words.map { String($0) }
        let background = argv.last == "&"
        if background { argv.removeLast() }
        var stages: [[String]] = [[]]
        for w in argv {
            if w == "|" { stages.append([]) } else { stages[stages.count - 1].append(w) }
        }
        return runStages(stages, background: background)
    }

    /// Where a stage's program lives: a word with a `/` is a path, else
    /// /bin/<word>.
    func programPath(_ name: String) -> String {
        name.utf8.contains(0x2F) ? name : "/bin/" + name
    }

    /// `set affinity <cpu>` pins the programs this shell starts to a CPU.
    func programAffinity() -> Affinity {
        if let n = vars["affinity"], n >= 0, n < smpStarted { return .cpu(n) }
        return .any
    }

    mutating func runStages(_ stages: [[String]], background: Bool) -> Bool {
        var paths: [String] = []
        for argv in stages {
            guard let name = argv.first else {
                say("syntax error: empty command in pipeline")
                return true
            }
            let path = programPath(name)
            guard let node = try? fs.lookup(path, cwd: cwd), !node.isDirectory else {
                if stages.count == 1 { return false }
                say("\(name): command not found")
                return true
            }
            paths.append(path)
        }
        guard let me = scheduler.current, !me.isMain else {
            say("\(stages[0][0]): programs can't run from the main loop")
            return true
        }
        let channel = background ? nil : ConsoleChannel(reader: me)
        let console = ConsoleFile(channel ?? ConsoleChannel(reader: nil))
        var pipes: [(PipeEnd, PipeEnd)] = []
        for _ in 0..<(stages.count - 1) {
            let pair = PipeEnd.make()
            pair.0.addRef() // held by this shell until every stage has its fds
            pair.1.addRef()
            pipes.append(pair)
        }
        var procs: [Process] = []
        var failure: String?
        for (i, argv) in stages.enumerated() {
            var stdio: [FileObject?] = [console, console, console]
            if i > 0 { stdio[0] = pipes[i - 1].0 }
            if i < stages.count - 1 { stdio[1] = pipes[i].1 }
            do throws(ExecError) {
                procs.append(try spawnProcess(path: paths[i], cwd: cwd, argv: argv, output: channel,
                                              waiter: background ? nil : me, affinity: programAffinity(),
                                              stdio: stdio))
            } catch {
                failure = "\(argv[0]): \(error.message)"
                break
            }
        }
        for pair in pipes {
            pair.0.dropRef()
            pair.1.dropRef()
        }
        if let failure {
            say(failure)
            for p in procs { killProcess(p.pid) }
            if !background { _ = waitProcesses(procs, console: channel, sink: { _ in }) }
            return true
        }
        if background {
            say("[\(procs[procs.count - 1].pid)]")
            return true
        }
        let statuses = waitProcesses(procs, console: channel,
                                     sink: { bytes in self.write(String(decoding: bytes, as: UTF8.self)) },
                                     keys: { takeTypedKeys() })
        for (i, status) in statuses.enumerated() {
            if let line = exitSummary(stages[i][0], status) { say(line) }
        }
        return true
    }
}

/// While the shell waits for a program: the keys typed in its inbox (taken
/// out, for the console's line discipline), and whether its window closed
/// (left in the inbox for the terminal to see).
func takeTypedKeys() -> (keys: [KeyEvent], closed: Bool) {
    guard let me = scheduler.current else { return ([], false) }
    return schedLock.withIRQsOff {
        var keys: [KeyEvent] = []
        var closed = false
        var i = me.inbox.head
        while i < me.inbox.events.count {
            switch me.inbox.events[i] {
            case .key(let k):
                keys.append(k.code)
                me.inbox.events.remove(at: i)
            case .close:
                closed = true
                i += 1
            default:
                i += 1
            }
        }
        return (keys, closed)
    }
}
