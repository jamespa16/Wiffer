// Phase M3: shell commands over the RAM filesystem. Paths are resolved
// against the shell's own `cwd`, so each Shell (one per terminal window in
// Phase L) has its own current directory over the shared `sh.fs`.

extension Shell {
    /// Print "<cmd>: <path>: <reason>".
    mutating func fsFail(_ cmd: StaticString, _ path: Substring, _ error: FSError) {
        say("\(cmd): \(path): \(error.message)")
    }

    /// The words from `args[from]` to the end of the line, inner spacing kept.
    func rest(_ args: [Substring], from: Int) -> String {
        guard from < args.count, let last = args.last else { return "" }
        return String(args[from].base[args[from].startIndex..<last.endIndex])
    }

    /// Split off a leading flag such as "-r".
    func flag(_ args: [Substring], _ name: Substring) -> (Bool, ArraySlice<Substring>) {
        if let first = args.first, first == name { return (true, args.dropFirst()) }
        return (false, args[...])
    }

    mutating func listing(_ path: Substring, header: Bool) {
        do throws(FSError) {
            let node = try fs.lookup(String(path), cwd: cwd)
            if header { say("\(path):") }
            for n in node.isDirectory ? node.sortedChildren : [node] {
                say(n.isDirectory ? pad("", 8) + "  " + n.name + "/" : pad("\(n.size)", 8, left: true) + "  " + n.name)
            }
        } catch {
            fsFail("ls", path, error)
        }
    }

    mutating func changeDirectory(_ path: Substring) {
        do throws(FSError) {
            let n = try fs.lookup(String(path), cwd: cwd)
            guard n.isDirectory else { throw FSError.notADirectory }
            cwd = FileSystem.normalize(String(path), cwd: cwd)
        } catch {
            fsFail("cd", path, error)
        }
    }

    mutating func move(_ from: Substring, _ to: Substring) {
        var target = String(to)
        // An existing directory as the target: move into it, keeping the name.
        if let d = try? fs.lookup(target, cwd: cwd), d.isDirectory,
           let name = FileSystem.components(String(from), cwd: cwd).last {
            target = FileSystem.normalize(target, cwd: cwd) + "/" + name
        }
        do throws(FSError) {
            try fs.rename(String(from), to: target, cwd: cwd)
        } catch {
            fsFail("mv", from, error)
        }
    }

    static func fileCommands() -> [Command<T>] {
        [
            Command(name: "pwd", args: "", help: "print the current directory") { sh, _ in sh.say(sh.cwd) },
            Command(name: "cd", args: "[dir]", help: "change directory (default /)") { sh, args in
                guard args.count <= 1 else { sh.say("usage: cd [dir]"); return }
                sh.changeDirectory(args.first ?? "/")
            },
            Command(name: "ls", args: "[path]...", help: "list a directory (sizes in bytes)") { sh, args in
                if args.isEmpty { sh.listing(".", header: false) }
                for a in args { sh.listing(a, header: args.count > 1) }
            },
            Command(name: "cat", args: "<file>...", help: "print files") { sh, args in
                if args.isEmpty { sh.say("usage: cat <file>..."); return }
                for a in args {
                    do throws(FSError) {
                        let bytes = try sh.fs.read(String(a), cwd: sh.cwd)
                        sh.write(String(decoding: bytes, as: UTF8.self))
                        if let last = bytes.last, last != 0x0A { sh.write("\n") }
                    } catch {
                        sh.fsFail("cat", a, error)
                    }
                }
            },
            Command(name: "mkdir", args: "<dir>...", help: "make directories (mkdir -p: and parents)") { sh, args in
                let (parents, dirs) = sh.flag(args, "-p")
                if dirs.isEmpty { sh.say("usage: mkdir [-p] <dir>..."); return }
                for d in dirs {
                    do throws(FSError) { try sh.fs.mkdir(String(d), cwd: sh.cwd, parents: parents) } catch { sh.fsFail("mkdir", d, error) }
                }
            },
            Command(name: "rm", args: "[-r] <path>", help: "remove files, empty dirs (-r: any)") { sh, args in
                let (recursive, paths) = sh.flag(args, "-r")
                if paths.isEmpty { sh.say("usage: rm [-r] <path>..."); return }
                for p in paths {
                    do throws(FSError) { try sh.fs.remove(String(p), cwd: sh.cwd, recursive: recursive) } catch { sh.fsFail("rm", p, error) }
                }
            },
            Command(name: "mv", args: "<from> <to>", help: "rename or move into a directory") { sh, args in
                guard args.count == 2 else { sh.say("usage: mv <from> <to>"); return }
                sh.move(args[0], args[1])
            },
            Command(name: "touch", args: "<file>...", help: "create empty files or update times") { sh, args in
                if args.isEmpty { sh.say("usage: touch <file>..."); return }
                for a in args {
                    do throws(FSError) { try sh.fs.touch(String(a), cwd: sh.cwd) } catch { sh.fsFail("touch", a, error) }
                }
            },
            Command(name: "write", args: "<file>", help: "write <file> <text>: replace a file with the text") { sh, args in
                guard let file = args.first else { sh.say("usage: write <file> <text>"); return }
                let text = sh.rest(args, from: 1)
                do throws(FSError) {
                    try sh.fs.write(String(file), Array((text.isEmpty ? "" : text + "\n").utf8), cwd: sh.cwd)
                } catch {
                    sh.fsFail("write", file, error)
                }
            },
            Command(name: "df", args: "", help: "filesystem usage") { sh, _ in
                let u = sh.fs.usage
                sh.say("fs: \(u.bytes) bytes in \(u.files) files, \(u.directories) directories")
            },
        ]
    }
}
