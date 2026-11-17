// Phase D: SSE. The kernel is compiled with SSE codegen on (Dictionary, Set
// and Float need it), so SSE must be enabled before any compiled code that
// might use it runs. See kernelEntry (kernel.swift) for how that's ensured.
// The interrupt stubs (cpu.S) fxsave/fxrstor the state around the dispatcher.

enum CR0 {
    static let monitorCoprocessor: UInt64 = 1 << 1 // MP: wait/fwait honour TS
    static let emulation: UInt64 = 1 << 2          // EM: x87/SSE raise #UD
    static let taskSwitched: UInt64 = 1 << 3       // TS: next FPU/SSE use raises #NM
}

enum CR4 {
    static let osfxsr: UInt64 = 1 << 9      // fxsave/fxrstor + SSE instructions
    static let osxmmexcpt: UInt64 = 1 << 10 // unmasked SIMD FP errors raise #XM
}

/// CR0.MP=1, CR0.EM=0 (and TS=0), CR4.OSFXSR + OSXMMEXCPT, then fninit.
/// Integer-only by construction; inlined into kernel_main, which build.sh
/// checks for xmm instructions.
@inline(__always)
func enableSSE() {
    write_cr0(read_cr0() & ~(CR0.emulation | CR0.taskSwitched) | CR0.monitorCoprocessor)
    write_cr4(read_cr4() | CR4.osfxsr | CR4.osxmmexcpt)
    fninit()
}

var sseEnabled: Bool {
    read_cr0() & (CR0.emulation | CR0.monitorCoprocessor) == CR0.monitorCoprocessor
        && read_cr4() & (CR4.osfxsr | CR4.osxmmexcpt) == CR4.osfxsr | CR4.osxmmexcpt
}

/// Embedded Swift hook (EmbeddedPlatform.h): per-boot seed for Hasher, used by
/// Dictionary and Set. It needn't be cryptographic, so it's the TSC run
/// through splitmix64.
@_cdecl("_swift_generateRandomHashSeed")
public func swiftGenerateRandomHashSeed(_ buffer: UnsafeMutableRawPointer, _ count: Int) {
    var state = rdtsc()
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

/// Selftest hook: while set, every IRQ overwrites all xmm registers and
/// MXCSR before it is handled, as an SSE-using handler might.
var sseClobberInIRQ = false

/// libm `ceil`: Dictionary/Set's capacity maths calls it (there is no libm).
/// Written without `rounded(.up)`, which would lower back to a ceil call.
/// Baseline x86-64 has no SSE4.1 `roundsd`, so: truncate, then step up.
@_cdecl("ceil")
public func kernelCeil(_ x: Double) -> Double {
    // NaN, infinities and |x| >= 2^52 are already integral.
    guard x.magnitude < 4_503_599_627_370_496.0 else { return x }
    let t = Double(Int64(x)) // toward zero
    let r = t < x ? t + 1 : t
    return r == 0 && x.sign == .minus ? -0.0 : r // ceil(-0.5) == -0.0
}
