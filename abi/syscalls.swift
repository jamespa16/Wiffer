// The system call ABI, compiled into both the kernel and libwiffer (user
// programs). Our own small table, not Linux's (ROADMAP Parts 6-8, "Kernel
// entry and exit").
//
// Calling convention: `syscall` with the number in rax and arguments in
// rdi, rsi, rdx, r10, r8, r9. The result comes back in rax; a value in
// -4095...-1 is -errno. rcx and r11 are clobbered (the CPU uses them);
// everything else but rax is preserved. libwiffer's stubs are real
// functions, so the compiler also treats the SSE registers as clobbered.
//
// Numbers are grouped by area, with room left for later phases. A number
// marked "reserved" isn't implemented yet and returns -ENOSYS.
//
// Names here are unique across the kernel and libwiffer (one module each).

enum SyscallNumber {
    // Processes (6B, 6C; 6D sleep/now).
    /// exit(code: Int) -> never returns.
    static let exit: UInt64 = 0
    /// yield(): let other ready tasks run.
    static let yield: UInt64 = 1
    /// debug_write(buf, len) -> len: raw bytes to the kernel's serial port.
    static let debugWrite: UInt64 = 2
    /// getpid() -> pid.
    static let getpid: UInt64 = 3
    /// sleep(ms) (reserved: 6D).
    static let sleep: UInt64 = 4
    /// now() -> ms since boot (reserved: 6D).
    static let now: UInt64 = 5
    /// spawn(path, argv, ...) -> pid (reserved: 6E).
    static let spawn: UInt64 = 6
    /// waitpid(pid) -> status (reserved: 6E).
    static let waitpid: UInt64 = 7
    /// kill(pid) (reserved: 6E).
    static let kill: UInt64 = 8

    // Memory (6C).
    /// map(hint, len, prot) -> address: anonymous, zeroed, allocated on
    /// first touch. hint 0: the kernel picks. Page-granular.
    static let map: UInt64 = 10
    /// unmap(addr, len).
    static let unmap: UInt64 = 11
    /// protect(addr, len, prot).
    static let protect: UInt64 = 12

    // Files and stdio (6E). Only `write` to fds 1 and 2 exists in 6C.
    static let open: UInt64 = 20
    static let close: UInt64 = 21
    static let read: UInt64 = 22
    /// write(fd, buf, len) -> bytes written.
    static let write: UInt64 = 23
    static let seek: UInt64 = 24
    static let stat: UInt64 = 25
    static let readdir: UInt64 = 26
    static let mkdir: UInt64 = 27
    static let unlink: UInt64 = 28
    static let rename: UInt64 = 29
    static let getcwd: UInt64 = 30
    static let chdir: UInt64 = 31
    static let dup2: UInt64 = 32
    static let pipe: UInt64 = 33
    /// wait(fds, events, timeout) -> ready (the poll-like multiplexer).
    static let wait: UInt64 = 34
    static let consoleMode: UInt64 = 35

    // Windows (6F): 40-49 reserved (win_create, win_present, win_resize,
    // win_set_title).
    static let winCreate: UInt64 = 40
    static let winPresent: UInt64 = 41
    static let winResize: UInt64 = 42
    static let winSetTitle: UInt64 = 43

    // Sockets (7E): 50-59 reserved.
    static let socket: UInt64 = 50

    // Randomness (8A).
    static let getrandom: UInt64 = 60

    /// Kernel selftests only: halt (sti; hlt) until `count` interrupts have
    /// arrived on this CPU while in this syscall, or `limit` timer ticks
    /// pass. Returns the count seen. Not for programs.
    static let testWaitIRQs: UInt64 = 99

    /// One past the highest number (dispatch bound).
    static let count: UInt64 = 100
}

/// Error numbers (results are -errno). The usual POSIX values.
enum Errno {
    static let EPERM: Int = 1
    static let ENOENT: Int = 2
    static let ESRCH: Int = 3
    static let EINTR: Int = 4
    static let EIO: Int = 5
    static let E2BIG: Int = 7
    static let ENOEXEC: Int = 8
    static let EBADF: Int = 9
    static let ECHILD: Int = 10
    static let EAGAIN: Int = 11
    static let ENOMEM: Int = 12
    static let EACCES: Int = 13
    static let EFAULT: Int = 14
    static let EEXIST: Int = 17
    static let ENOTDIR: Int = 20
    static let EISDIR: Int = 21
    static let EINVAL: Int = 22
    static let EMFILE: Int = 24
    static let ENOSPC: Int = 28
    static let ESPIPE: Int = 29
    static let EPIPE: Int = 32
    static let ERANGE: Int = 34
    static let ENAMETOOLONG: Int = 36
    static let ENOSYS: Int = 38
    static let ENOTEMPTY: Int = 39
}

/// map/protect `prot` bits. Write and exec together are refused (W^X).
enum MapProt {
    static let read: UInt64 = 1
    static let write: UInt64 = 2
    static let exec: UInt64 = 4
}

/// Auxiliary vector keys on the initial stack (the ELF/SysV values).
enum AuxKey {
    static let null: UInt64 = 0
    static let phdr: UInt64 = 3
    static let phent: UInt64 = 4
    static let phnum: UInt64 = 5
    static let pagesz: UInt64 = 6
    static let entry: UInt64 = 9
}

/// User address-space layout shared by the kernel, user.ld and libwiffer.
enum UserLayout {
    /// Programs link here (PML4 slot 2; user/user.ld).
    static let imageBase: UInt64 = 0x0000_0100_0000_0000
    /// map() picks addresses from here up (slot 128).
    static let mapBase: UInt64 = 0x0000_4000_0000_0000
    /// The initial stack's top: the end of slot 254. Below the stack's
    /// reserved region is an unmapped guard page.
    static let stackTop: UInt64 = 0x0000_7F80_0000_0000
    static let stackSize: UInt64 = 1 << 20
    /// Limits on spawn arguments.
    static let maxArgs = 256
    static let maxArgBytes = 64 * 1024
}
