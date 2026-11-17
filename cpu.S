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
.macro ISR_STUB n
    .p2align 4
isr_stub_\n:
.if !(\n == 8 || (\n >= 10 && \n <= 14) || \n == 17 || \n == 21 || \n == 29 || \n == 30)
    pushq $0
.endif
    pushq $\n
    jmp isr_common
.endm

.irp n, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47
    ISR_STUB \n
.endr

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

    .section .rodata
    .p2align 3
    .globl isr_stub_table
isr_stub_table:
.irp n, 0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47
    .quad isr_stub_\n
.endr

    .section .note.GNU-stack, "", @progbits
