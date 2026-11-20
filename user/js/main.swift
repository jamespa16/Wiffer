// /bin/js [options] [file.js]: run a JavaScript file, or with no file a REPL
// in the terminal (ROADMAP Phase 9F).
//
//   js file.js          run it, then the event loop until no timer is left
//   js -e code...       run the rest of the line as code
//   js                  REPL (raw terminal, line editing, history; Ctrl-C
//                       stops a running script, Ctrl-D exits)
//   --budget MS         wall-clock budget per task (default 5000 for files,
//                       none in the REPL; 0 turns it off)
//   --heap MIB          heap cap (default 64)
//
// Exit status: 0, 1 for an uncaught exception, 2 when the script was
// terminated (time budget, heap cap), 64 for bad usage or an unreadable file.

var jsArgs = Array(Process.args.dropFirst())
var jsFile: String? = nil
var jsEval: String? = nil
var jsBudget = -1
var jsHeap = 64

func jsUsage() -> Never {
    File.stderr.write("usage: js [--budget ms] [--heap MiB] [file.js | -e code]\n")
    Process.exit(64)
}

func jsNumberArg(_ s: String) -> Int {
    var n = 0
    if s.isEmpty { jsUsage() }
    for u in s.utf8 {
        if u < 0x30 || u > 0x39 || n > 1_000_000_000 { jsUsage() }
        n = n * 10 + Int(u - 0x30)
    }
    return n
}

var jsIndex = 0
while jsIndex < jsArgs.count {
    let a = jsArgs[jsIndex]
    jsIndex += 1
    if a == "--budget" {
        if jsIndex >= jsArgs.count { jsUsage() }
        jsBudget = jsNumberArg(jsArgs[jsIndex]); jsIndex += 1
    } else if a == "--heap" {
        if jsIndex >= jsArgs.count { jsUsage() }
        jsHeap = max(1, min(jsNumberArg(jsArgs[jsIndex]), 400)); jsIndex += 1
    } else if a == "-e" {
        // The shell has no quoting: the rest of the line is the code.
        if jsIndex >= jsArgs.count { jsUsage() }
        var code = ""
        while jsIndex < jsArgs.count {
            if !code.isEmpty { code += " " }
            code += jsArgs[jsIndex]
            jsIndex += 1
        }
        jsEval = code
    } else if a.hasPrefix("-") && a != "-" {
        jsUsage()
    } else {
        jsFile = a
    }
}

let jsRepl = jsFile == nil && jsEval == nil
let jsShell = JSShell(heapMiB: jsHeap, budgetMs: jsBudget >= 0 ? jsBudget : (jsRepl ? 0 : 5000))

if jsRepl {
    jsRunRepl(jsShell)
    Process.exit(0)
}

var jsSource: [UInt8] = []
var jsName = "[eval]"
if let code = jsEval {
    jsSource = Array(code.utf8)
} else if let path = jsFile {
    jsName = path
    do throws(SysError) {
        let f = try File.open(path)
        jsSource = try f.readAll()
        f.close()
    } catch {
        File.stderr.write("js: \(path): \(error.message)\n")
        Process.exit(64)
    }
}
jsShell.run(jsSource, name: jsName)
if !jsShell.failed {
    jsShell.loop.performMicrotaskCheckpoint()
    jsShell.loop.runUntilIdle(sleep: { ms in jsShell.flush(); Time.sleep(ms) },
                              shouldStop: { jsShell.terminated })
}
jsShell.flush()
Process.exit(jsShell.terminated ? 2 : (jsShell.failed ? 1 : 0))
