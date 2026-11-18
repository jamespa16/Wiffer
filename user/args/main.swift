// /bin/args: print argc and each argument.
let args = Process.args
print("argc=\(args.count)")
for (i, a) in args.enumerated() { print("argv[\(i)]=\(a)") }
