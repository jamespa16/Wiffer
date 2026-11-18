// libwiffer's assembly: the process entry point, the syscall stub, the mem*
// functions the compiler may call, and the few instructions Swift can't
// express (rdtsc, pause, and the deliberate faults `crash` uses).
// Everything else is Swift (user/libwiffer/*.swift).

    .text

// The kernel enters here (ring 3) with rsp at argc (SysV initial stack:
// argc, argv..., NULL, envp..., NULL, auxv), every other register zero.
    .globl _start
    .type _start, @function
_start:
    xorl %ebp, %ebp
    movq %rsp, %r12             // callee-saved: survives the calls
    andq $-16, %rsp
    movq %r12, %rdi
    call wiffer_init            // runtime.swift: remember argc/argv
    movl (%r12), %edi           // argc
    leaq 8(%r12), %rsi          // argv
    call main                   // the program's main.swift
    movl %eax, %edi
    call wiffer_exit            // never returns
    ud2
    .size _start, . - _start

// int64_t wiffer_syscall(n, a1, a2, a3, a4, a5, a6): the ABI in
// abi/syscalls.swift (number in rax; rdi, rsi, rdx, r10, r8, r9).
    .globl wiffer_syscall
    .type wiffer_syscall, @function
wiffer_syscall:
    movq %rdi, %rax
    movq %rsi, %rdi
    movq %rdx, %rsi
    movq %rcx, %rdx
    movq %r8, %r10
    movq %r9, %r8
    movq 8(%rsp), %r9
    syscall
    ret
    .size wiffer_syscall, . - wiffer_syscall

    .globl memcpy
    .type memcpy, @function
memcpy:
    movq %rdi, %rax
    movq %rdx, %rcx
    rep movsb
    ret
    .size memcpy, . - memcpy

    .globl memmove
    .type memmove, @function
memmove:
    movq %rdi, %rax
    movq %rdx, %rcx
    cmpq %rsi, %rdi
    jbe 1f                      // dst at or below src: copy forward
    leaq -1(%rsi,%rdx), %rsi
    leaq -1(%rdi,%rdx), %rdi
    std
    rep movsb
    cld
    ret
1:  rep movsb
    ret
    .size memmove, . - memmove

    .globl memset
    .type memset, @function
memset:
    movq %rdi, %r9
    movl %esi, %eax
    movq %rdx, %rcx
    rep stosb
    movq %r9, %rax
    ret
    .size memset, . - memset

    .globl memcmp
    .type memcmp, @function
memcmp:
    xorl %eax, %eax
    movq %rdx, %rcx
    testq %rcx, %rcx
    jz 2f
    repe cmpsb
    je 2f
    movzbl -1(%rdi), %eax
    movzbl -1(%rsi), %ecx
    subl %ecx, %eax
2:  ret
    .size memcmp, . - memcmp

    .globl wiffer_rdtsc
    .type wiffer_rdtsc, @function
wiffer_rdtsc:
    rdtsc
    shlq $32, %rdx
    orq %rdx, %rax
    ret
    .size wiffer_rdtsc, . - wiffer_rdtsc

    .globl wiffer_pause
    .type wiffer_pause, @function
wiffer_pause:
    pause
    ret
    .size wiffer_pause, . - wiffer_pause

// Deliberate faults (the `crash` program). Each should kill the process.
    .globl wiffer_fault_ud2, wiffer_fault_div0, wiffer_fault_int3
    .globl wiffer_fault_hlt, wiffer_fault_cli, wiffer_fault_in
wiffer_fault_ud2:
    ud2
wiffer_fault_div0:
    xorl %ecx, %ecx
    movl $1, %eax
    xorl %edx, %edx
    divl %ecx
    ret
wiffer_fault_int3:
    int3
    ret
wiffer_fault_hlt:
    hlt
    ret
wiffer_fault_cli:
    cli
    ret
wiffer_fault_in:
    inb $0x60, %al
    ret

    .section .note.GNU-stack, "", @progbits

// 128-bit shifts (compiler-rt builtins LLVM calls for UInt128 shifts by a
// variable amount; lib/crypto's Poly1305 and X25519 use them). SysV: the
// value in rdi (low) and rsi (high), the count in edx; result in rax:rdx.
    .text
    .globl __lshrti3
    .type __lshrti3, @function
__lshrti3:
    movl %edx, %ecx
    movq %rdi, %rax
    movq %rsi, %rdx
    testb $64, %cl
    jnz 1f
    shrdq %cl, %rdx, %rax
    shrq %cl, %rdx
    ret
1:  movq %rdx, %rax
    shrq %cl, %rax
    xorl %edx, %edx
    ret
    .size __lshrti3, . - __lshrti3

    .globl __ashlti3
    .type __ashlti3, @function
__ashlti3:
    movl %edx, %ecx
    movq %rdi, %rax
    movq %rsi, %rdx
    testb $64, %cl
    jnz 1f
    shldq %cl, %rax, %rdx
    shlq %cl, %rax
    ret
1:  movq %rax, %rdx
    shlq %cl, %rdx
    xorl %eax, %eax
    ret
    .size __ashlti3, . - __ashlti3
