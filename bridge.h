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

// Page-table root, for aliasing the HHDM into the lower half (see pmm.swift).
static inline uint64_t read_cr3(void) {
    uint64_t value;
    __asm__ volatile ("mov %%cr3, %0" : "=r"(value));
    return value;
}

static inline void write_cr3(uint64_t value) {
    __asm__ volatile ("mov %0, %%cr3" : : "r"(value) : "memory");
}
