// libwiffer: the system calls in Swift, for programs in user/<prog>/.
//
//   print(...)            fd 1 (the terminal that started the program)
//   File.stdout / .stderr write(String) and write(bytes)
//   Process.args          argv, argv[0] first
//   Process.pid, Process.exit(code), Process.yield()
//   Memory.map/unmap/protect   anonymous pages (the heap uses these)
//   Time.now, Time.sleep(ms)   ms since boot; block for ms (6D)
//   debugPrint(_:)        raw bytes to the kernel's serial port
//
// Results follow abi/syscalls.swift: negative values are -errno.

// MARK: Raw calls

@inline(__always)
func syscall(_ n: UInt64, _ a1: UInt64 = 0, _ a2: UInt64 = 0, _ a3: UInt64 = 0, _ a4: UInt64 = 0,
             _ a5: UInt64 = 0, _ a6: UInt64 = 0) -> Int {
    Int(wiffer_syscall(n, a1, a2, a3, a4, a5, a6))
}

func sysWrite(_ fd: Int, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    syscall(SyscallNumber.write, UInt64(fd), UInt64(UInt(bitPattern: buffer)), UInt64(count))
}

func sysMap(_ hint: UInt64, _ length: UInt64, _ prot: UInt64) -> Int {
    syscall(SyscallNumber.map, hint, length, prot)
}

func sysUnmap(_ address: UInt64, _ length: UInt64) -> Int {
    syscall(SyscallNumber.unmap, address, length)
}

func sysProtect(_ address: UInt64, _ length: UInt64, _ prot: UInt64) -> Int {
    syscall(SyscallNumber.protect, address, length, prot)
}

// MARK: Swift API

enum Process {
    /// argv as Strings (argv[0] is the program name).
    static var args: [String] {
        var out: [String] = []
        guard let argv = wifferArgv else { return out }
        for i in 0..<wifferArgc {
            guard let p = UnsafePointer<UInt8>(bitPattern: UInt(argv[i])) else { continue }
            var n = 0
            while p[n] != 0 { n += 1 }
            out.append(String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self))
        }
        return out
    }

    static var pid: Int { syscall(SyscallNumber.getpid) }

    static func exit(_ code: Int32) -> Never { wifferExit(code) }

    static func yield() { _ = syscall(SyscallNumber.yield) }
}

struct File {
    let fd: Int

    static let stdout = File(fd: 1)
    static let stderr = File(fd: 2)

    /// Bytes written, or -errno.
    @discardableResult
    func write(_ bytes: UnsafeRawBufferPointer) -> Int {
        guard let base = bytes.baseAddress, bytes.count > 0 else { return 0 }
        return sysWrite(fd, base, bytes.count)
    }

    @discardableResult
    func write(_ bytes: [UInt8]) -> Int { bytes.withUnsafeBytes { write($0) } }

    @discardableResult
    func write(_ text: String) -> Int {
        var s = text
        return s.withUTF8 { write(UnsafeRawBufferPointer($0)) }
    }
}

enum Memory {
    static let pageSize = 4096

    /// Anonymous zeroed pages (allocated on first touch), or nil.
    static func map(_ length: Int, prot: UInt64 = MapProt.read | MapProt.write, at hint: UInt = 0)
        -> UnsafeMutableRawPointer? {
        let r = sysMap(UInt64(hint), UInt64(length), prot)
        return r > 0 ? UnsafeMutableRawPointer(bitPattern: UInt(r)) : nil
    }

    @discardableResult
    static func unmap(_ p: UnsafeMutableRawPointer, _ length: Int) -> Int {
        sysUnmap(UInt64(UInt(bitPattern: p)), UInt64(length))
    }

    @discardableResult
    static func protect(_ p: UnsafeMutableRawPointer, _ length: Int, prot: UInt64) -> Int {
        sysProtect(UInt64(UInt(bitPattern: p)), UInt64(length), prot)
    }
}

enum Time {
    /// Milliseconds since boot (10 ms steps: the 100 Hz timer).
    static var now: Int { syscall(SyscallNumber.now) }

    /// Block for `ms` milliseconds (rounded up to 10 ms). 0, or -EINTR.
    @discardableResult
    static func sleep(_ ms: Int) -> Int { syscall(SyscallNumber.sleep, UInt64(max(ms, 0))) }
}

/// Raw bytes to the kernel's serial port (debugging; not the terminal).
func debugPrint(_ text: String) {
    var s = text
    s.withUTF8 { b in
        _ = syscall(SyscallNumber.debugWrite, UInt64(UInt(bitPattern: b.baseAddress)), UInt64(b.count))
    }
}
