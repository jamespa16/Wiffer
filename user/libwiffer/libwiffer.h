// libwiffer's C-visible declarations (bridging header for user programs).
// The functions are in start.S; everything else is Swift.
#pragma once
#include <stdint.h>

// The raw system call: number, then up to six arguments (abi/syscalls.swift).
int64_t wiffer_syscall(uint64_t n, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4,
                       uint64_t a5, uint64_t a6);

uint64_t wiffer_rdtsc(void);
// A `pause` the optimiser can't remove (busy loops).
void wiffer_pause(void);

// Deliberate faults for `crash`.
void wiffer_fault_ud2(void);
void wiffer_fault_div0(void);
void wiffer_fault_int3(void);
void wiffer_fault_hlt(void);
void wiffer_fault_cli(void);
void wiffer_fault_in(void);
