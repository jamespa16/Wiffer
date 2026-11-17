// Bridging header imported into Swift: Limine protocol types + tiny CPU helpers.
#pragma once
#include <stdint.h>
#include <stddef.h>
#include "limine.h"

// Defined in boot.c, placed in .limine_requests so the bootloader finds them.
extern volatile uint64_t limine_base_revision[3];
extern volatile struct limine_framebuffer_request framebuffer_request;
extern volatile struct limine_memmap_request memmap_request;
extern volatile struct limine_hhdm_request hhdm_request;

static inline void outb(uint16_t port, uint8_t value) {
    __asm__ volatile ("outb %0, %1" : : "a"(value), "Nd"(port));
}

static inline uint8_t inb(uint16_t port) {
    uint8_t value;
    __asm__ volatile ("inb %1, %0" : "=a"(value) : "Nd"(port));
    return value;
}

// Halt and catch fire: disable interrupts and stop forever.
static inline __attribute__((noreturn)) void hcf(void) {
    for (;;) __asm__ volatile ("cli; hlt");
}

// ---- Phase A/B: descriptor tables, interrupts, timer ----------------------

// Register frame built by the cpu.S stubs, lowest address first. The stub
// pushes the vector, then rax..r15. Before that, the CPU (or the stub, with a
// dummy 0) pushed the error code, and the CPU pushed rip, cs, rflags, rsp, ss.
struct interrupt_frame {
    uint64_t r15, r14, r13, r12, r11, r10, r9, r8;
    uint64_t rbp, rdi, rsi, rdx, rcx, rbx, rax;
    uint64_t vector, error_code;
    uint64_t rip, cs, rflags, rsp, ss;
};

// Operand of lgdt/lidt/sgdt/sidt.
struct __attribute__((packed)) descriptor_ptr {
    uint16_t limit;
    uint64_t base;
};

// cpu.S: lgdt, reload CS with lretq, reload DS/ES/FS/GS/SS, then ltr.
void gdt_load(const struct descriptor_ptr *gdtr, uint16_t code_sel,
              uint16_t data_sel, uint16_t tss_sel);
// cpu.S: entry stub addresses for vectors 0-47 (exceptions + PIC IRQs).
extern const uint64_t isr_stub_table[48];

static inline void lidt(const struct descriptor_ptr *idtr) {
    __asm__ volatile ("lidt %0" : : "m"(*idtr) : "memory");
}

static inline struct descriptor_ptr read_gdtr(void) {
    struct descriptor_ptr d;
    __asm__ volatile ("sgdt %0" : "=m"(d));
    return d;
}

static inline struct descriptor_ptr read_idtr(void) {
    struct descriptor_ptr d;
    __asm__ volatile ("sidt %0" : "=m"(d));
    return d;
}

static inline uint16_t read_tr(void) {
    uint16_t sel;
    __asm__ volatile ("str %0" : "=r"(sel));
    return sel;
}

static inline uint16_t read_cs(void) {
    uint16_t sel;
    __asm__ volatile ("mov %%cs, %0" : "=r"(sel));
    return sel;
}

static inline uint16_t read_ss(void) {
    uint16_t sel;
    __asm__ volatile ("mov %%ss, %0" : "=r"(sel));
    return sel;
}

static inline uint64_t read_cr2(void) {
    uint64_t value;
    __asm__ volatile ("mov %%cr2, %0" : "=r"(value));
    return value;
}

static inline uint64_t read_rflags(void) {
    uint64_t value;
    __asm__ volatile ("pushfq; popq %0" : "=r"(value));
    return value;
}

// The "memory" clobbers stop the compiler caching globals (such as the tick
// counter, which the timer IRQ writes) across these calls.
static inline void sti(void) { __asm__ volatile ("sti" : : : "memory"); }
static inline void cli(void) { __asm__ volatile ("cli" : : : "memory"); }
static inline void hlt(void) { __asm__ volatile ("hlt" : : : "memory"); }
// Compiler-only fence (no instruction): orders ring-buffer accesses against
// an interrupt handler on the same CPU.
static inline void compiler_barrier(void) { __asm__ volatile ("" : : : "memory"); }

// A short delay for the 8259 PIC: a write to the unused POST port 0x80.
static inline void io_wait(void) { outb(0x80, 0); }

// Deliberate faults for the `fault` command. Swift's `/` checks for a zero
// divisor and traps with ud2 before any `div` runs, so #DE needs real asm.
static inline void fault_invalid_opcode(void) { __asm__ volatile ("ud2"); }
static inline void fault_divide_by_zero(void) {
    __asm__ volatile ("xor %%ecx, %%ecx; div %%ecx" : : : "eax", "ecx", "edx");
}
// Point rsp at unmapped memory and push. The #PF can't be delivered on that
// stack either, so the CPU raises #DF, which runs on the IST1 stack.
static inline void fault_double(void) {
    __asm__ volatile ("movabs $0x0000700000000000, %%rsp; pushq $0" : : : "memory");
}

// Interrupt guard for the allocator (Swift has no inline asm).
// irq_save: read RFLAGS, then cli. irq_restore: sti only if IF (bit 9) was set,
// so nested guards and callers that already had interrupts off stay correct.
static inline uint64_t irq_save(void) {
    uint64_t flags;
    __asm__ volatile ("pushfq; popq %0; cli" : "=r"(flags) : : "memory");
    return flags;
}

static inline void irq_restore(uint64_t flags) {
    if (flags & (1ull << 9)) __asm__ volatile ("sti" : : : "memory");
}

// font.S: the embedded PSF console font and its size in bytes.
extern const uint8_t font_psf[];
extern const uint64_t font_psf_size;
static inline const uint8_t *font_data(void) { return font_psf; }

// Page-table root, for aliasing the HHDM into the lower half (see pmm.swift).
static inline uint64_t read_cr3(void) {
    uint64_t value;
    __asm__ volatile ("mov %%cr3, %0" : "=r"(value));
    return value;
}

static inline void write_cr3(uint64_t value) {
    __asm__ volatile ("mov %0, %%cr3" : : "r"(value) : "memory");
}

// ---- Phase D: SSE ---------------------------------------------------------
// The CR0/CR4 setup itself is in Swift (sse.swift); these are just the
// instructions Swift can't express.

static inline uint64_t read_cr0(void) {
    uint64_t value;
    __asm__ volatile ("mov %%cr0, %0" : "=r"(value));
    return value;
}

static inline void write_cr0(uint64_t value) {
    __asm__ volatile ("mov %0, %%cr0" : : "r"(value) : "memory");
}

static inline uint64_t read_cr4(void) {
    uint64_t value;
    __asm__ volatile ("mov %%cr4, %0" : "=r"(value));
    return value;
}

static inline void write_cr4(uint64_t value) {
    __asm__ volatile ("mov %0, %%cr4" : : "r"(value) : "memory");
}

static inline void fninit(void) { __asm__ volatile ("fninit" : : : "memory"); }

// Move rsp to `top` (16-byte aligned) and call fn there; never returns.
static inline __attribute__((noreturn)) void switch_stack(uint64_t top, void (*fn)(void)) {
    __asm__ volatile ("movq %0, %%rsp\n\txorl %%ebp, %%ebp\n\tcall *%1\n\tud2"
                      : : "r"(top), "r"(fn) : "memory");
    __builtin_unreachable();
}

static inline uint64_t rdtsc(void) {
    uint32_t lo, hi;
    __asm__ volatile ("rdtsc" : "=a"(lo), "=d"(hi));
    return (uint64_t)hi << 32 | lo;
}

static inline uint32_t read_mxcsr(void) {
    uint32_t value;
    __asm__ volatile ("stmxcsr %0" : "=m"(value));
    return value;
}

// Selftest: hold `a` in xmm0 and `b` in xmm15 inside one asm block (so the
// compiler can't touch them) while `*ticks` advances by `n` timer interrupts,
// then return what the registers hold. Needs interrupts enabled.
static inline void sse_hold_across_ticks(uint64_t a, uint64_t b, const volatile uint64_t *ticks,
                                         uint64_t n, uint64_t out[2]) {
    uint64_t target = *ticks + n;
    __asm__ volatile (
        "movq %[a], %%xmm0\n\t"
        "movq %[b], %%xmm15\n\t"
        "1: pause\n\t"
        "cmpq (%[t]), %[target]\n\t"
        "ja 1b\n\t"
        "movq %%xmm0, %[a]\n\t"
        "movq %%xmm15, %[b]"
        : [a] "+r"(a), [b] "+r"(b)
        : [t] "r"(ticks), [target] "r"(target)
        : "xmm0", "xmm15", "memory", "cc");
    out[0] = a;
    out[1] = b;
}

// Selftest: what an SSE-using interrupt handler might do. Overwrite every
// xmm register and change MXCSR (rounding mode: toward zero).
static inline void sse_clobber_all(void) {
    uint32_t mxcsr = 0x7F80;
    __asm__ volatile (
        "pcmpeqd %%xmm0, %%xmm0\n\t"
        "movdqa %%xmm0, %%xmm1\n\t"  "movdqa %%xmm0, %%xmm2\n\t"
        "movdqa %%xmm0, %%xmm3\n\t"  "movdqa %%xmm0, %%xmm4\n\t"
        "movdqa %%xmm0, %%xmm5\n\t"  "movdqa %%xmm0, %%xmm6\n\t"
        "movdqa %%xmm0, %%xmm7\n\t"  "movdqa %%xmm0, %%xmm8\n\t"
        "movdqa %%xmm0, %%xmm9\n\t"  "movdqa %%xmm0, %%xmm10\n\t"
        "movdqa %%xmm0, %%xmm11\n\t" "movdqa %%xmm0, %%xmm12\n\t"
        "movdqa %%xmm0, %%xmm13\n\t" "movdqa %%xmm0, %%xmm14\n\t"
        "movdqa %%xmm0, %%xmm15\n\t"
        "ldmxcsr %0"
        : : "m"(mxcsr)
        : "xmm0", "xmm1", "xmm2", "xmm3", "xmm4", "xmm5", "xmm6", "xmm7",
          "xmm8", "xmm9", "xmm10", "xmm11", "xmm12", "xmm13", "xmm14", "xmm15");
}
