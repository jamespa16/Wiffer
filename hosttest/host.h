// Host test runner only (hosttest.sh): the bits of libc the runner uses to
// read fixtures and report. Libraries in lib/ never see this header; they
// must build freestanding (hosttest.sh checks with x86_64-unknown-none-elf).
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
