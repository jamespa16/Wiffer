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
extern volatile struct limine_module_request module_request;
extern volatile struct limine_executable_cmdline_request cmdline_request;

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
extern const uint64_t isr_stub_table[256];
static inline const uint64_t *isr_stubs(void) { return isr_stub_table; }

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

// ---- Phase H: cooperative tasks (cpu.S) -----------------------------------

// Push rbp, rbx, r12-r15, MXCSR and the x87 control word, store rsp in
// *save_rsp, load load_rsp, then store 0 to *on_cpu (the outgoing task's
// "still on a CPU" word: from here another CPU may resume it), pop the same
// from the new stack and ret. Phase S.
void context_switch(uint64_t *save_rsp, uint64_t load_rsp, uint64_t *on_cpu);
// Address of the first-run trampoline a new task's stack "returns" into.
extern const uint64_t task_trampoline_address;
// Selftest: load rbx, rbp, r12-r15 with seed+1...seed+6, MXCSR and the x87
// control word with the given values, call fn, and return a bitmask of what
// changed (bits 0-5 registers in that order, 6 MXCSR control bits, 7 FCW).
// Restores the caller's MXCSR and control word.
uint32_t check_callee_saved(void (*fn)(void), uint64_t seed, uint32_t mxcsr, uint32_t fcw);

// ---- Phase P: atomics, spinlocks, per-CPU data ----------------------------
// Sequentially consistent __atomic builtins on 64-bit words. Swift passes the
// address of the word (a field of a global struct: see spinlock.swift).

static inline uint64_t atomic_load64(const volatile uint64_t *p) {
    return __atomic_load_n(p, __ATOMIC_SEQ_CST);
}

static inline void atomic_store64(volatile uint64_t *p, uint64_t value) {
    __atomic_store_n(p, value, __ATOMIC_SEQ_CST);
}

static inline uint64_t atomic_exchange64(volatile uint64_t *p, uint64_t value) {
    return __atomic_exchange_n(p, value, __ATOMIC_SEQ_CST);
}

// Returns 1 (and stores `desired`) if *p was `expected`, else 0.
static inline int atomic_cas64(volatile uint64_t *p, uint64_t expected, uint64_t desired) {
    return __atomic_compare_exchange_n(p, &expected, desired, 0,
                                       __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
}

// Returns the old value.
static inline uint64_t atomic_fetch_add64(volatile uint64_t *p, uint64_t value) {
    return __atomic_fetch_add(p, value, __ATOMIC_SEQ_CST);
}

// Return the old value.
static inline uint64_t atomic_fetch_or64(volatile uint64_t *p, uint64_t value) {
    return __atomic_fetch_or(p, value, __ATOMIC_SEQ_CST);
}

static inline uint64_t atomic_fetch_and64(volatile uint64_t *p, uint64_t value) {
    return __atomic_fetch_and(p, value, __ATOMIC_SEQ_CST);
}

// Spin-wait hint.
static inline void cpu_pause(void) { __asm__ volatile ("pause" : : : "memory"); }

static inline uint64_t rdmsr(uint32_t msr) {
    uint32_t lo, hi;
    __asm__ volatile ("rdmsr" : "=a"(lo), "=d"(hi) : "c"(msr));
    return (uint64_t)hi << 32 | lo;
}

static inline void wrmsr(uint32_t msr, uint64_t value) {
    __asm__ volatile ("wrmsr" : : "c"(msr), "a"((uint32_t)value), "d"((uint32_t)(value >> 32))
                      : "memory");
}

// Per-CPU block (percpu.swift): IA32_GS_BASE points at this CPU's PerCPU
// entry, whose word 0 is its own address and word 1 its CPU index.
// volatile: a task may move to another CPU between two reads (Phase S).
static inline uint64_t this_cpu_address(void) {
    uint64_t v;
    __asm__ volatile ("movq %%gs:0, %0" : "=r"(v));
    return v;
}

static inline uint64_t this_cpu_index(void) {
    uint64_t v;
    __asm__ volatile ("movq %%gs:8, %0" : "=r"(v));
    return v;
}

// ---- Phase Q: CPUID --------------------------------------------------------

struct cpuid_result { uint32_t eax, ebx, ecx, edx; };

static inline struct cpuid_result cpuid(uint32_t leaf, uint32_t subleaf) {
    struct cpuid_result r;
    __asm__ volatile ("cpuid" : "=a"(r.eax), "=b"(r.ebx), "=c"(r.ecx), "=d"(r.edx)
                      : "a"(leaf), "c"(subleaf));
    return r;
}

// ---- Phase R: AP bring-up --------------------------------------------------

extern volatile struct limine_mp_request mp_request;

// switch_stack with one argument: move rsp to `top` and call fn(arg).
static inline __attribute__((noreturn)) void switch_stack_arg(uint64_t top, uint64_t arg,
                                                              void (*fn)(uint64_t)) {
    __asm__ volatile ("movq %0, %%rsp\n\txorl %%ebp, %%ebp\n\tcall *%1\n\tud2"
                      : : "r"(top), "r"(fn), "D"(arg) : "memory");
    __builtin_unreachable();
}

// Start a Limine AP: set its extra_argument, then (last, atomically: the AP
// spins on this word) its goto_address.
static inline void mp_start(struct limine_mp_info *info, uint64_t arg, limine_goto_address entry) {
    info->extra_argument = arg;
    __atomic_store_n((uint64_t *)&info->goto_address, (uint64_t)entry, __ATOMIC_SEQ_CST);
}

// `sti; hlt` as one asm: an interrupt can't slip in between and be lost.
static inline void sti_hlt(void) { __asm__ volatile ("sti\n\thlt" : : : "memory"); }

// ---- Phase V: PCI and virtio-blk -------------------------------------------
// 16/32-bit port I/O (PCI config mechanism #1, the legacy virtio registers).

static inline void outw(uint16_t port, uint16_t value) {
    __asm__ volatile ("outw %0, %1" : : "a"(value), "Nd"(port) : "memory");
}

static inline uint16_t inw(uint16_t port) {
    uint16_t value;
    __asm__ volatile ("inw %1, %0" : "=a"(value) : "Nd"(port) : "memory");
    return value;
}

static inline void outl(uint16_t port, uint32_t value) {
    __asm__ volatile ("outl %0, %1" : : "a"(value), "Nd"(port) : "memory");
}

static inline uint32_t inl(uint16_t port) {
    uint32_t value;
    __asm__ volatile ("inl %1, %0" : "=a"(value) : "Nd"(port) : "memory");
    return value;
}

// Virtqueue memory shared with the device (DMA). Ring indices go through
// these so the compiler can't cache or reorder them: dma_store16 is a
// release (the descriptor and ring writes before it are visible first),
// dma_load16/dma_load8 an acquire (reads after it of the used ring, the
// status byte and the data see what the device wrote).
static inline uint16_t dma_load16(const void *p) {
    return __atomic_load_n((const volatile uint16_t *)p, __ATOMIC_ACQUIRE);
}

static inline void dma_store16(void *p, uint16_t value) {
    __atomic_store_n((volatile uint16_t *)p, value, __ATOMIC_RELEASE);
}

static inline uint8_t dma_load8(const void *p) {
    return __atomic_load_n((const volatile uint8_t *)p, __ATOMIC_ACQUIRE);
}

// Full fence (mfence): ring updates before the notify port write.
static inline void dma_fence(void) { __atomic_thread_fence(__ATOMIC_SEQ_CST); }
