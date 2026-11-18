// libwiffer: the Embedded Swift runtime hooks for user programs.
//
// The heap is the kernel's heap.swift, compiled into every program a second
// time (build.sh). It asks `pmm` for frames and takes `heapLock`; here
// those are shims: frames come from the map() syscall (zeroed, allocated by
// the kernel on first touch) and go back with unmap(), and the lock is a
// no-op (processes are single-threaded). heap.swift's diagnostics print
// through puts/printHex/newline, which go to debug_write.

// MARK: heap.swift's environment

let frameSize = 4096

struct UserFrames {
    /// `count` contiguous pages from map(), as an address (never 0).
    mutating func allocate(count: Int = 1) -> UInt? {
        let r = sysMap(0, UInt64(count * frameSize), MapProt.read | MapProt.write)
        return r > 0 ? UInt(r) : nil
    }

    mutating func free(_ address: UInt, count: Int = 1) {
        _ = sysUnmap(UInt64(address), UInt64(count * frameSize))
    }
}

var pmm = UserFrames()

struct UserHeapLock {
    mutating func acquireIRQ() -> UInt64 { 0 }
    mutating func releaseIRQ(_ flags: UInt64) {}
}

var heapLock = UserHeapLock()

func puts(_ s: StaticString) {
    _ = wiffer_syscall(SyscallNumber.debugWrite, UInt64(UInt(bitPattern: s.utf8Start)), UInt64(s.utf8CodeUnitCount),
                       0, 0, 0, 0)
}

func newline() { puts("\n") }

func printHex(_ value: UInt64) {
    var bytes = InlineArray<18, UInt8>(repeating: 0x30)
    bytes[1] = 0x78
    for i in 0..<16 {
        let nibble = UInt8(truncatingIfNeeded: (value >> UInt64(60 - 4 * i)) & 0xF)
        bytes[2 + i] = nibble < 10 ? 0x30 + nibble : 0x61 + nibble - 10
    }
    withUnsafePointer(to: &bytes) { p in
        _ = wiffer_syscall(SyscallNumber.debugWrite, UInt64(UInt(bitPattern: p)), 18, 0, 0, 0, 0)
    }
}

// MARK: Embedded Swift hooks

@_cdecl("_swift_writeToStandardOutput")
public func swiftWriteToStandardOutput(_ chars: UnsafePointer<UInt8>?, _ count: UInt) -> UInt {
    guard let chars, count > 0 else { return 0 }
    let r = sysWrite(1, UnsafeRawPointer(chars), Int(count))
    return r > 0 ? UInt(r) : 0
}

@_cdecl("_swift_lockStandardOutput")
public func swiftLockStandardOutput() {}

@_cdecl("_swift_unlockStandardOutput")
public func swiftUnlockStandardOutput() {}

/// Hasher's per-process seed: the TSC through splitmix64 (not
/// cryptographic; 8A's getrandom will be).
@_cdecl("_swift_generateRandomHashSeed")
public func swiftGenerateRandomHashSeed(_ buffer: UnsafeMutableRawPointer, _ count: Int) {
    var state = wiffer_rdtsc()
    let bytes = buffer.assumingMemoryBound(to: UInt8.self)
    var i = 0
    while i < count {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        for _ in 0..<8 where i < count {
            bytes[i] = UInt8(truncatingIfNeeded: z)
            z >>= 8
            i += 1
        }
    }
}

/// libm `ceil` (Dictionary and Set's capacity maths), as in the kernel.
@_cdecl("ceil")
public func wifferCeil(_ x: Double) -> Double {
    guard x.magnitude < 4_503_599_627_370_496.0 else { return x }
    let t = Double(Int64(x))
    let r = t < x ? t + 1 : t
    return r == 0 && x.sign == .minus ? -0.0 : r
}

// MARK: Process entry and exit (start.S)

var wifferArgc = 0
var wifferArgv: UnsafePointer<UInt64>? = nil

/// Called by _start with the initial stack pointer (at argc).
@_cdecl("wiffer_init")
public func wifferInit(_ sp: UnsafePointer<UInt64>) {
    wifferArgc = Int(sp[0])
    wifferArgv = sp + 1
}

/// main returned (or Process.exit): end the process.
@_cdecl("wiffer_exit")
public func wifferExit(_ code: Int32) -> Never {
    _ = wiffer_syscall(SyscallNumber.exit, UInt64(bitPattern: Int64(code)), 0, 0, 0, 0, 0)
    while true { wiffer_fault_ud2() } // not reached
}
