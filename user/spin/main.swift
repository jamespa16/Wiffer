// /bin/spin [n]: burn CPU in ring 3. With n, spin n million iterations and
// exit; without, forever (until `kill`; 6D preempts it).

let args = Process.args
var limit: UInt64 = .max
if args.count > 1, let n = UInt64(args[1]) { limit = n &* 1_000_000 }
var i: UInt64 = 0
while i < limit {
    wiffer_pause()
    i &+= 1
}
print("spin: done")
