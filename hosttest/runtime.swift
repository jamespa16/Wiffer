// Host runtime hooks for Embedded Swift on macOS/Linux. Allocation, the
// hash seed and fatalError come from libswiftEmbeddedPlatformPOSIX.a;
// print's stdout lock is ours (single-threaded).
@_cdecl("_swift_lockStandardOutput") public func hostLockStandardOutput() {}
@_cdecl("_swift_unlockStandardOutput") public func hostUnlockStandardOutput() {}
