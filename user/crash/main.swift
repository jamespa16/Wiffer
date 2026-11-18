// /bin/crash <kind>: fault on purpose. The kernel should kill the process
// with a one-line report and the shell should carry on.

let kinds = "null write exec kernel ident ud trap de bp hlt cli io stack exit"

/// An address the optimiser can't see through.
@inline(never) func opaque(_ x: UInt) -> UInt { x }

@inline(never) func recurse(_ n: Int) -> Int {
    var pad = InlineArray<64, Int>(repeating: n) // 512 bytes of stack per level
    pad[n & 63] = n
    return recurse(n + 1) &+ pad[(n + 1) & 63]
}

let args = Process.args
guard args.count == 2 else {
    print("usage: crash <\(kinds.split(separator: " ").joined(separator: "|"))>")
    Process.exit(2)
}

switch args[1] {
case "null": // read near address 0 (unmapped)
    print(UnsafePointer<UInt64>(bitPattern: opaque(8))!.pointee)
case "write": // write to our own (read + exec only) code
    let code = unsafeBitCast(wiffer_fault_ud2 as @convention(c) () -> Void, to: UInt.self)
    UnsafeMutablePointer<UInt8>(bitPattern: opaque(code))!.pointee = 0x90
case "exec": // run code from a data page (NX)
    guard let page = Memory.map(4096) else { print("crash: map failed"); Process.exit(1) }
    page.storeBytes(of: 0xC3, as: UInt8.self) // ret
    let f = unsafeBitCast(page, to: (@convention(c) () -> Void).self)
    f()
case "kernel": // read the kernel image (supervisor-only)
    print(UnsafePointer<UInt64>(bitPattern: opaque(0xFFFF_FFFF_8000_0000))!.pointee)
case "ident": // read the kernel's identity map (PML4 slot 0, supervisor-only)
    print(UnsafePointer<UInt64>(bitPattern: opaque(0x10_0000))!.pointee)
case "ud": wiffer_fault_ud2()
case "trap": // a Swift runtime trap (array index out of range)
    let a = [1, 2, 3]
    print(a[Int(opaque(5))])
case "de": wiffer_fault_div0()
case "bp": wiffer_fault_int3()
case "hlt": wiffer_fault_hlt()
case "cli": wiffer_fault_cli()
case "io": wiffer_fault_in()
case "stack": print(recurse(0)) // runs into the guard page below the stack
case "exit": Process.exit(3)
default:
    print("crash: unknown kind '\(args[1])' (\(kinds))")
    Process.exit(2)
}
print("crash: \(args[1]) did not fault")
