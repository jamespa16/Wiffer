// Embedded Swift standard-output hooks (EmbeddedPlatform.h): print() goes to
// COM1 and, through putc, to the framebuffer console (console.swift).

@_cdecl("_swift_writeToStandardOutput")
public func swiftWriteToStandardOutput(_ chars: UnsafePointer<UInt8>?, _ count: UInt) -> UInt {
    guard let chars else { return 0 }
    for i in 0..<Int(count) {
        if chars[i] == 0x0A { putc(0x0D) } // terminals need \r\n
        putc(chars[i])
    }
    return count
}

// One CPU, and nothing prints from interrupt handlers, so the (recursive)
// stdout lock can be a no-op.
@_cdecl("_swift_lockStandardOutput")
public func swiftLockStandardOutput() {}

@_cdecl("_swift_unlockStandardOutput")
public func swiftUnlockStandardOutput() {}
