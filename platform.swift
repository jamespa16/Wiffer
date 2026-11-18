// Embedded Swift standard-output hooks (EmbeddedPlatform.h): print() goes to
// COM1 and, through putc, to the framebuffer console (console.swift).

@_cdecl("_swift_writeToStandardOutput")
public func swiftWriteToStandardOutput(_ chars: UnsafePointer<UInt8>?, _ count: UInt) -> UInt {
    guard let chars else { return 0 }
    stdoutLock.acquire()
    defer { stdoutLock.release() }
    for i in 0..<Int(count) {
        if chars[i] == 0x0A { putc(0x0D) } // terminals need \r\n
        putc(chars[i])
    }
    return count
}

// The recursive stdout lock (spinlock.swift), shared with puts/printHex/
// printDec. Nothing prints from interrupt handlers except the dying paths,
// which take it with acquireForPanic.
@_cdecl("_swift_lockStandardOutput")
public func swiftLockStandardOutput() { stdoutLock.acquire() }

@_cdecl("_swift_unlockStandardOutput")
public func swiftUnlockStandardOutput() { stdoutLock.release() }
