// /bin/sleep [-v] <ms>: block for ms milliseconds (Phase 6D). With -v, print
// how long it took by the kernel's clock.

let args = Process.args
var first = 1
let verbose = args.count > 1 && args[1] == "-v"
if verbose { first = 2 }
guard args.count == first + 1, let ms = Int(args[first]), ms >= 0 else {
    print("usage: sleep [-v] <ms>")
    Process.exit(2)
}
let start = Time.now
if Time.sleep(ms) != 0 { Process.exit(1) }
if verbose { print("slept \(Time.now - start) ms") }
