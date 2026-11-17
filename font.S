// The console font, embedded verbatim: Spleen 8x16 (PSF1 with a Unicode
// table, BSD-2-Clause, see fonts/LICENSE.spleen). Parsed in console.swift.

    .section .rodata
    .p2align 4
    .globl font_psf
font_psf:
    .incbin "fonts/spleen-8x16.psfu"
font_psf_end:

    .p2align 3
    .globl font_psf_size
font_psf_size:
    .quad font_psf_end - font_psf

    .section .note.GNU-stack, "", @progbits
