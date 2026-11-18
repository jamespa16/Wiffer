// The parts of CPU setup that Swift can't express: interrupt entry stubs
// (Swift has no interrupt calling convention or iretq) and the segment
// register reload after lgdt (CS can only change through a far jump/return).
// Everything else (the tables, the dispatcher, the PIC and PIT) is in Swift.

    .text

// void gdt_load(const struct descriptor_ptr *gdtr, uint16_t code_sel,
//               uint16_t data_sel, uint16_t tss_sel)
//   rdi = gdtr, si = code selector, dx = data selector, cx = TSS selector
    .globl gdt_load
    .type gdt_load, @function
gdt_load:
    lgdt (%rdi)
    movw %dx, %ds
    movw %dx, %es
    movw %dx, %fs
    movw %dx, %gs
    movw %dx, %ss
    movzwq %si, %rsi
    pushq %rsi                  // new CS
    leaq 1f(%rip), %rax
    pushq %rax                  // return address
    lretq                       // pops RIP, then CS
1:  ltr %cx
    ret
    .size gdt_load, . - gdt_load

// One stub per vector. The CPU pushes an error code only for these vectors;
// for every other vector the stub pushes a dummy 0, so the frame layout
// (struct interrupt_frame in bridge.h) is the same for all of them.
// All 256 vectors; .altmacro lets %isr_i turn the counter into a symbol suffix.
.altmacro
.macro ISR_STUB n
    .p2align 4
isr_stub_\n:
.if !(\n == 8 || (\n >= 10 && \n <= 14) || \n == 17 || \n == 21 || \n == 29 || \n == 30)
    pushq $0
.endif
    pushq $\n
    jmp isr_common
.endm

.set isr_i, 0
.rept 256
    ISR_STUB %isr_i
    .set isr_i, isr_i + 1
.endr
.noaltmacro

// Save the general-purpose registers and the SSE/x87 state, call the Swift
// dispatcher with a pointer to the frame, restore, drop vector + error code,
// and iretq.
// SSE state: Swift code in the handler may use xmm registers (and MXCSR), so
// fxsave it into a 512-byte area on the stack below the frame. fxsave needs
// 16-byte alignment, and the SysV ABI needs rsp 16-aligned at the call (with
// SSE on, a misaligned movaps faults). The CPU aligns rsp to 16 before pushing
// its 5 words, and error code + vector + 15 registers make 22 words, so rsp is
// already aligned here; the andq keeps it so if the frame layout ever changes.
// rbx (already saved in the frame, callee-saved across the call) remembers
// the frame address.
isr_common:
    pushq %rax
    pushq %rbx
    pushq %rcx
    pushq %rdx
    pushq %rsi
    pushq %rdi
    pushq %rbp
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    cld
    movq %rsp, %rbx             // rbx = frame
    andq $-16, %rsp
    subq $512, %rsp
    fxsave (%rsp)
    movq %rbx, %rdi
    call interrupt_dispatch
    fxrstor (%rsp)
    movq %rbx, %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %r11
    popq %r10
    popq %r9
    popq %r8
    popq %rbp
    popq %rdi
    popq %rsi
    popq %rdx
    popq %rcx
    popq %rbx
    popq %rax
    addq $16, %rsp              // vector + error code
    iretq


// ---- Phase H: cooperative task switch ------------------------------------
// void context_switch(uint64_t *save_rsp, uint64_t load_rsp, uint64_t *on_cpu)
// The SysV callee-saved state: rbx, rbp, r12-r15, plus MXCSR's control bits
// and the x87 control word. Everything else is caller-saved, so the Swift
// caller has already spilled what it needs. Interrupts may arrive at any
// point: rsp always points into a valid stack.
    .globl context_switch
    .type context_switch, @function
context_switch:
    pushq %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    subq $8, %rsp
    stmxcsr (%rsp)
    fnstcw 4(%rsp)
    movq %rsp, (%rdi)
    movq %rsi, %rsp
    // Phase S: only now, off the old stack, release the outgoing task to the
    // other CPUs (a plain store is a release on x86: the pushes and the rsp
    // save above are visible first). Clearing it before the rsp load would
    // let an interrupt push onto a stack another CPU had already resumed.
    movq $0, (%rdx)
    ldmxcsr (%rsp)
    fldcw 4(%rsp)
    addq $8, %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret
    .size context_switch, . - context_switch

// A new task's first context_switch returns here, with rsp at the 16-byte
// aligned top of its stack (Task.buildInitialFrame). task_main never returns.
    .type task_trampoline, @function
task_trampoline:
    xorl %ebp, %ebp
    call task_main
    ud2
    .size task_trampoline, . - task_trampoline

// uint32_t check_callee_saved(void (*fn)(void), uint64_t seed,
//                             uint32_t mxcsr, uint32_t fcw)
// Selftest only. Frame: 0 caller MXCSR, 4 caller FCW, 8 seed,
// 16 test MXCSR, 20 test FCW, 24/28 scratch.
    .globl check_callee_saved
    .type check_callee_saved, @function
check_callee_saved:
    pushq %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    subq $40, %rsp              // 8 + 48 + 40: rsp 16-aligned for the call
    stmxcsr 0(%rsp)
    fnstcw 4(%rsp)
    movq %rsi, 8(%rsp)
    movl %edx, 16(%rsp)
    movl %ecx, 20(%rsp)
    ldmxcsr 16(%rsp)
    fldcw 20(%rsp)
    leaq 1(%rsi), %rbx
    leaq 2(%rsi), %rbp
    leaq 3(%rsi), %r12
    leaq 4(%rsi), %r13
    leaq 5(%rsi), %r14
    leaq 6(%rsi), %r15
    call *%rdi
    xorl %eax, %eax
    movq 8(%rsp), %rsi
.macro CHECK_REG reg, k, bit
    leaq \k(%rsi), %rdx
    cmpq %rdx, \reg
    je 1f
    orl $\bit, %eax
1:
.endm
    CHECK_REG %rbx, 1, 1
    CHECK_REG %rbp, 2, 2
    CHECK_REG %r12, 3, 4
    CHECK_REG %r13, 4, 8
    CHECK_REG %r14, 5, 16
    CHECK_REG %r15, 6, 32
    stmxcsr 24(%rsp)
    movl 24(%rsp), %edx
    xorl 16(%rsp), %edx
    andl $0xFFC0, %edx          // control bits only; 0-5 are sticky flags
    jz 2f
    orl $64, %eax
2:  fnstcw 28(%rsp)
    movzwl 28(%rsp), %edx
    xorw 20(%rsp), %dx
    jz 3f
    orl $128, %eax
3:  ldmxcsr 0(%rsp)
    fldcw 4(%rsp)
    addq $40, %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret
    .size check_callee_saved, . - check_callee_saved

    .section .rodata
    .p2align 3
    .globl isr_stub_table
isr_stub_table:
.altmacro
.macro ISR_ENTRY n
    .quad isr_stub_\n
.endm
.set isr_i, 0
.rept 256
    ISR_ENTRY %isr_i
    .set isr_i, isr_i + 1
.endr
.noaltmacro

    .globl task_trampoline_address
task_trampoline_address:
    .quad task_trampoline

    .section .note.GNU-stack, "", @progbits
