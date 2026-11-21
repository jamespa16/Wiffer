#!/usr/bin/env python3
"""Exercise build orchestration with cheap stand-in tools; no Swift install needed."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    shutil.copy(REPO / 'build.sh', root)
    (root / 'tools').mkdir()
    shutil.copy(REPO / 'tools/build-key.py', root / 'tools')
    files = ['kernel.swift', 'abi/syscalls.swift', 'heap.swift', 'bridge.h',
             'limine.h', 'boot.c', 'cpu.S', 'font.S', 'fonts/font', 'linker.ld',
             'lib/bytes/reader.swift', 'lib/crypto/common.swift',
             'lib/crypto/tables.swift', 'lib/crypto/sha2.swift',
             'lib/crypto/chacha.swift', 'lib/crypto/drbg.swift',
             'user/hello/main.swift', 'user/echo/main.swift',
             'user/libwiffer/runtime.swift', 'user/libwiffer/libwiffer.h',
             'user/libwiffer/start.S', 'user/libwiffer/font.S', 'user/user.ld',
             'rootfs/js/example', 'lib/js/fixtures/bench/example',
             'tests/fixtures/fat32-lfn.sparse', 'limine.conf',
             'resources/embedded/x86_64-unknown-none-elf/libswiftUnicodeDataTables.a']
    for name in files:
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('input\n')
    share = root / 'share'
    share.mkdir()
    for name in ['limine-bios.sys', 'limine-bios-cd.bin', 'limine-uefi-cd.bin',
                 'BOOTX64.EFI', 'BOOTIA32.EFI']:
        (share / name).touch()
    bin_dir = root / 'bin'
    bin_dir.mkdir()
    tool = bin_dir / 'fake'
    tool.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
if '--version' in args:
    print(name + ' version test'); sys.exit()
if '-print-target-info' in args:
    print(json.dumps({'runtimeResourcePath': str(pathlib.Path('resources').resolve())})); sys.exit()
if name in ('llvm-nm', 'llvm-objdump', 'limine'): sys.exit()
if os.environ.get('FAIL_PROGRAM') in args and os.environ.get('FAIL_PROGRAM'): sys.exit(1)
flag = '-o' if '-o' in args else '-cf'
if flag in args:
    pathlib.Path(args[args.index(flag)+1]).write_text('output ' + name)
''')
    tool.chmod(0o755)
    for name in ['swiftc', 'clang', 'ld.lld', 'llvm-nm', 'llvm-objdump',
                 'bsdtar', 'xorriso', 'limine']:
        (bin_dir / name).symlink_to(tool)
    env = dict(os.environ, PATH=str(bin_dir) + ':' + os.environ['PATH'],
               LIMINE_SHARE=str(share), WIFFER_JOBS='2', WIFFER_REBUILD='0')
    def run(**extra):
        return subprocess.run(['bash', 'build.sh'], cwd=root, env=dict(env, **extra),
                              capture_output=True, text=True)
    result = run(); assert result.returncode == 0, result.stderr
    result = run(); assert result.returncode == 0, result.stderr
    assert 'OK: user/' not in result.stdout and 'CACHED: bootable ISOs' in result.stdout
    (root / 'user/hello/main.swift').write_text('edited')
    result = run(); assert result.returncode == 0, result.stderr
    assert 'OK: user/hello' in result.stdout and 'CACHED: user/echo' in result.stdout
    assert 'CACHED: build/kernel.elf' in result.stdout
    (root / 'build/user/hello').unlink()
    result = run(FAIL_PROGRAM='hello'); assert result.returncode != 0
    assert not (root / 'build/cache/user-hello').exists()
    result = run(); assert result.returncode == 0, result.stderr
    assert 'OK: user/hello' in result.stdout
    (root / 'rootfs/new-file').touch()
    result = run(); assert result.returncode == 0, result.stderr
    assert 'OK: build/wiffer.iso' in result.stdout and 'OK: user/' not in result.stdout
    result = run(WIFFER_REBUILD='1'); assert result.returncode == 0, result.stderr
    assert 'CACHED:' not in result.stdout
print('PASS: cache hits, selective rebuild, missing output, failed job, rootfs edit, force rebuild')
