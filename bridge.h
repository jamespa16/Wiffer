// Bridging header imported into Swift: Limine protocol types + tiny CPU helpers.
#pragma once
#include <stdint.h>
#include <stddef.h>
#include "limine.h"

// Defined in boot.c, placed in .limine_requests so the bootloader finds them.
extern volatile uint64_t limine_base_revision[3];
extern volatile struct limine_framebuffer_request framebuffer_request;
extern volatile struct limine_memmap_request memmap_request;

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
