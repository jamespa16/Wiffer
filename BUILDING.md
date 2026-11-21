Run `./build.sh` to build the kernel, user programs, and both bootable ISOs.
Python 3 is required for hashing build inputs, alongside the existing Swift,
LLVM, Limine, bsdtar, and xorriso tools.

Successful kernel and user builds are cached separately in `build/cache/`.
Keys include source contents and paths, dependency manifests, headers, fonts,
linker scripts, compiler versions, and build scripts. Changing a shared library
rebuilds its consumers; changing one program rebuilds that program. Rootfs and
ISO generation is also skipped when its inputs are unchanged. Missing final
outputs are rebuilt. Failed stages do not record a successful cache entry.

User programs compile with up to four concurrent jobs by default. Adjust for
available memory and CPUs with `WIFFER_JOBS=2 ./build.sh`. Each job performs a
whole-module optimized Swift compilation and LTO link, so large values can use
substantial memory. Kernel compilation remains serial and optimization flags
are unchanged.

Use `WIFFER_REBUILD=1 ./build.sh` to force all stages to rebuild. Removing
`build/` also performs a clean build. Avoid running separate builds concurrently
in the same checkout because they share output paths.
