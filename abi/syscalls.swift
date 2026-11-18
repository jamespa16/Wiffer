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
    /// spawn(path, pathLen, argv, argvLen, fds) -> pid (6E). `argv` is the
    /// arguments as NUL-terminated strings, back to back. `fds`: 0 to give
    /// the child this process's fds 0-2, else the address of three Int64
    /// fds of this process to become the child's 0, 1 and 2 (-1: none).
    static let spawn: UInt64 = 6
    /// waitpid(pid, statusOut, flags) -> pid (6E). pid -1: any child. Blocks
    /// until a child has exited, reaps it and stores its WaitStatus (an Int64)
    /// at statusOut (0: don't). `WaitFlag.noHang`: returns 0 instead of
    /// blocking. -ECHILD if there's no such child.
    static let waitpid: UInt64 = 7
    /// kill(pid) (6E): ask a child (or this process) to exit. -ESRCH if none.
    static let kill: UInt64 = 8

    // Memory (6C).
    /// map(hint, len, prot) -> address: anonymous, zeroed, allocated on
    /// first touch. hint 0: the kernel picks. Page-granular.
    static let map: UInt64 = 10
    /// unmap(addr, len).
    static let unmap: UInt64 = 11
    /// protect(addr, len, prot).
    static let protect: UInt64 = 12

    // Files and stdio (6E). Paths are (pointer, length) pairs, not NUL
    // terminated, resolved against the process's cwd.
    /// open(path, pathLen, OpenFlags) -> fd.
    static let open: UInt64 = 20
    /// close(fd).
    static let close: UInt64 = 21
    /// read(fd, buf, len) -> bytes read; 0 is end of file.
    static let read: UInt64 = 22
    /// write(fd, buf, len) -> bytes written.
    static let write: UInt64 = 23
    /// seek(fd, offset, whence: SeekWhence) -> new position.
    static let seek: UInt64 = 24
    /// stat(path, pathLen, StatInfo out).
    static let stat: UInt64 = 25
    /// readdir(fd, buf, len) -> bytes of DirRecords (whole records only);
    /// 0 at the end. `fd` is a directory opened with `OpenFlags.read`.
    static let readdir: UInt64 = 26
    /// mkdir(path, pathLen).
    static let mkdir: UInt64 = 27
    /// unlink(path, pathLen): a file or an empty directory.
    static let unlink: UInt64 = 28
    /// rename(from, fromLen, to, toLen).
    static let rename: UInt64 = 29
    /// getcwd(buf, len) -> length (no NUL); -ERANGE if it doesn't fit.
    static let getcwd: UInt64 = 30
    /// chdir(path, pathLen).
    static let chdir: UInt64 = 31
    /// dup2(old, new) -> new.
    static let dup2: UInt64 = 32
    /// pipe(out): stores the read and write fds as two Int64s.
    static let pipe: UInt64 = 33
    /// wait(fds, count, timeoutMs) -> number of fds with revents set. `fds`
    /// is an array of WaitFD. timeout -1 waits forever, 0 only polls. The
    /// one blocking multiplexer: files, pipes, the console (later sockets
    /// and windows).
    static let wait: UInt64 = 34
    /// console_mode(fd, mode) -> previous ConsoleMode bits. mode ==
    /// UInt64.max only asks.
    static let consoleMode: UInt64 = 35
    /// fstat(fd, StatInfo out).
    static let fstat: UInt64 = 36

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
    static let EBUSY: Int = 16
    static let EXDEV: Int = 18
    static let ENOTDIR: Int = 20
    static let EISDIR: Int = 21
    static let EINVAL: Int = 22
    static let EMFILE: Int = 24
    static let ENOTTY: Int = 25
    static let ENOSPC: Int = 28
    static let ESPIPE: Int = 29
    static let EPIPE: Int = 32
    static let ERANGE: Int = 34
    static let ENAMETOOLONG: Int = 36
    static let ENOSYS: Int = 38
    static let ENOTEMPTY: Int = 39
}

/// open() flags.
enum OpenFlags {
    static let read: UInt64 = 1
    static let write: UInt64 = 2
    /// Create the file if it doesn't exist.
    static let create: UInt64 = 4
    static let truncate: UInt64 = 8
    static let append: UInt64 = 16
    /// With `create`: fail with -EEXIST if it exists.
    static let exclusive: UInt64 = 32
}

enum SeekWhence {
    static let set: UInt64 = 0
    static let current: UInt64 = 1
    static let end: UInt64 = 2
}

/// StatInfo.kind.
enum StatKind {
    static let file: UInt64 = 1
    static let directory: UInt64 = 2
    /// Pipes, the console and other things that aren't files.
    static let device: UInt64 = 3
}

/// stat/fstat's result (three Int64-sized fields, in this order).
struct StatInfo {
    var size: UInt64 = 0
    var kind: UInt64 = 0
    /// Timer ticks (100 Hz since boot) of the last change.
    var modified: UInt64 = 0
}

/// One entry of readdir's buffer: kind (UInt8, a StatKind), name length
/// (UInt8), six zero bytes, the size (UInt64, little endian), then the name,
/// padded with zeros to a multiple of 8 bytes. `DirRecord.headerSize` is 16.
enum DirRecord {
    static let headerSize = 16
}

/// WaitFD.events and revents bits.
enum WaitEvent {
    static let readable: Int16 = 1
    static let writable: Int16 = 2
    /// revents only: the other end is gone (a pipe's writer closed: reads
    /// return end of file; a reader closed: writes fail).
    static let hangup: Int16 = 4
    /// revents only: the fd isn't open.
    static let invalid: Int16 = 8
}

/// One entry of wait()'s array (8 bytes).
struct WaitFD {
    var fd: Int32
    var events: Int16
    var revents: Int16
}

/// console_mode bits. Mode 0 is cooked: the kernel edits the line (echo,
/// backspace, Ctrl-U) and read returns one line at a time; Ctrl-D at the
/// start of a line is end of file; Ctrl-C kills the foreground programs.
enum ConsoleMode {
    /// Keys arrive as they are typed (arrows as ESC [ A..D), no echo.
    static let raw: UInt64 = 1
    /// Ctrl-C is a byte (0x03), not a kill.
    static let passInterrupt: UInt64 = 2
}

/// waitpid flags, and how a status is encoded.
enum WaitFlag {
    static let noHang: UInt64 = 1
}

/// waitpid's status: exited: the code (0...255); faulted: 0x100 | vector << 16;
/// killed: 0x200.
enum WaitStatus {
    static let faulted: Int64 = 0x100
    static let killed: Int64 = 0x200
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
