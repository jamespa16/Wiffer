"""Tests for tests/fat32.py: python3 -m unittest tests/test_fat32.py

Cross-checks against host tools when present: fsck_msdos (macOS) or
fsck.fat (Linux) on images this tool writes, mtools (mdir/mcopy) and
mkfs.fat images read back by this tool. Set FAT32_MOUNT_TEST=1 on macOS to
also attach images with hdiutil and mount them with diskutil (no sudo
needed) in both directions.
"""
import contextlib
import gzip
import io
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fat32  # noqa: E402
from fat32 import FATError, MiB, SECTOR  # noqa: E402

FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")
WHEN = (2026, 3, 4, 5, 6, 8)


def _host_fsck():
    if shutil.which("fsck_msdos"):
        return ["fsck_msdos", "-n"]
    for t in ("fsck.fat", "fsck.vfat", "dosfsck"):
        if shutil.which(t):
            return [t, "-n", "-v"]
    return None


HOST_FSCK = _host_fsck()


class Base(unittest.TestCase):
    size = 64 * MiB

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.img = os.path.join(self.tmp.name, "disk.img")
        fat32.mkfs(self.img, self.size, "WIFFER", 0x1234ABCD, WHEN)

    def tearDown(self):
        self.tmp.cleanup()

    def vol(self, **kw):
        return fat32.Volume(self.img, when=WHEN, **kw)

    def assertClean(self, img=None):
        img = img or self.img
        self.assertEqual(fat32.fsck(img), [])
        if HOST_FSCK:
            r = subprocess.run(HOST_FSCK + [img], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def poke(self, offset, data):
        with open(self.img, "r+b") as f:
            f.seek(offset)
            f.write(data)

    def peek(self, offset, n):
        with open(self.img, "rb") as f:
            f.seek(offset)
            return f.read(n)

    def assertProblem(self, fragment):
        problems = fat32.fsck(self.img)
        self.assertTrue(any(fragment in p for p in problems), f"{fragment!r} not in {problems}")
        return problems

    def recs(self, v, path="/"):
        d = v._dir_at(fat32._split(path))
        return d, {r.name: r for r in d.recs}


class TestMkfs(Base):
    def test_geometry_64m(self):
        b = fat32.parse_bpb(self.peek(0, SECTOR))
        self.assertEqual((b.bps, b.spc, b.reserved, b.nfats), (512, 1, 32, 2))
        self.assertEqual((b.root_ents, b.tot16, b.fat16, b.media), (0, 0, 0, 0xF8))
        self.assertEqual(b.tot32, 131072)
        # spec formula: ceil((131072 - 32) / (256*1 + 2)/2) = ceil(131040 / 129)
        self.assertEqual(b.fatsz, 1016)
        self.assertEqual((b.root_cluster, b.fsinfo, b.backup), (2, 1, 6))
        self.assertEqual((b.boot_sig, b.vol_id, b.vol_label, b.fs_type),
                         (0x29, 0x1234ABCD, b"WIFFER     ", b"FAT32   "))
        self.assertEqual(b.sig, 0xAA55)
        self.assertEqual(self.peek(6 * SECTOR, SECTOR), self.peek(0, SECTOR))
        for sec in (1, 7):
            fsi = self.peek(sec * SECTOR, SECTOR)
            self.assertEqual(struct.unpack_from("<I", fsi, 0)[0], 0x41615252)
            self.assertEqual(struct.unpack_from("<III", fsi, 484), (0x61417272, 129007, 3))
            self.assertEqual(struct.unpack_from("<I", fsi, 508)[0], 0xAA550000)
        for fat in (32, 32 + 1016):
            self.assertEqual(struct.unpack("<III", self.peek(fat * SECTOR, 12)),
                             (0x0FFFFFF8, 0x0FFFFFFF, 0x0FFFFFFF))
        with self.vol() as v:
            self.assertEqual(v.total_clusters, (131072 - 32 - 2 * 1016))
            self.assertEqual(v.total_clusters, 129008)
            self.assertEqual(v.free_clusters, 129007)
            self.assertEqual(v.cluster_size, 512)
            self.assertEqual(v.label, "WIFFER")
            self.assertEqual(v.list("/"), [])
            d, recs = self.recs(v)
            self.assertEqual(recs["WIFFER"].kind, "label")
            self.assertEqual(recs["WIFFER"].attr, fat32.ATTR_VOLUME_ID)
        self.assertClean()

    def test_sectors_per_cluster_table(self):
        spc = fat32.sectors_per_cluster
        self.assertEqual(spc(66600), 0)
        self.assertEqual(spc(66601), 1)
        self.assertEqual(spc(532480), 1)
        self.assertEqual(spc(532481), 8)
        self.assertEqual(spc(16777216), 8)
        self.assertEqual(spc(16777217), 16)
        self.assertEqual(spc(33554433), 32)
        self.assertEqual(spc(67108865), 64)

    def test_sizes(self):
        small = os.path.join(self.tmp.name, "small.img")
        with self.assertRaises(ValueError):
            fat32.mkfs(small, 32 * MiB)
        fat32.mkfs(small, "33M")
        with fat32.Volume(small) as v:
            self.assertGreaterEqual(v.total_clusters, 65525)
            self.assertEqual(v.total_clusters, 66504)
        self.assertClean(small)
        big = os.path.join(self.tmp.name, "big.img")
        fat32.mkfs(big, "1G")          # sparse file: cheap
        with fat32.Volume(big) as v:
            self.assertEqual(v.cluster_size, 4096)
            v.write("/x.bin", bytes(range(256)) * 40)
        self.assertClean(big)
        self.assertEqual(fat32.parse_size("64M"), 64 * MiB)
        self.assertEqual(fat32.parse_size("64MiB"), 64 * MiB)
        self.assertEqual(fat32.parse_size("512k"), 512 * 1024)

    def test_mkfs_overwrites(self):
        with self.vol() as v:
            v.write("/a.txt", b"x" * 5000)
        fat32.mkfs(self.img, 40 * MiB, "AGAIN")
        self.assertEqual(os.path.getsize(self.img), 40 * MiB)
        with self.vol() as v:
            self.assertEqual(v.list(), [])
            self.assertEqual(v.label, "AGAIN")
        self.assertClean()

    def test_bad_label(self):
        with self.assertRaises(ValueError):
            fat32.mkfs(self.img, 64 * MiB, "TOO LONG LABEL")
        with self.assertRaises(ValueError):
            fat32.mkfs(self.img, 64 * MiB, "a/b")

    def test_not_fat32(self):
        junk = os.path.join(self.tmp.name, "junk.img")
        with open(junk, "wb") as f:
            f.write(bytes(40 * MiB))
        with self.assertRaises(FATError) as cm:
            fat32.Volume(junk)
        self.assertEqual(cm.exception.code, "notFAT32")
        self.assertTrue(fat32.fsck(junk))


class TestFiles(Base):
    def test_round_trips(self):
        cases = {
            "/empty": b"",
            "/one.bin": b"\x01",
            "/cluster.bin": bytes(range(256)) * 2,          # exactly 512
            "/cluster1.bin": bytes(range(256)) * 2 + b"!",  # 513
            "/multi.bin": os.urandom(100_000),
        }
        with self.vol() as v:
            free0 = v.free_clusters
            for p, data in cases.items():
                v.write(p, data)
            for p, data in cases.items():
                self.assertEqual(v.read(p), data)
            self.assertEqual(free0 - v.free_clusters, 0 + 1 + 1 + 2 + 196)
            e = v.stat("/empty")
            self.assertEqual((e.size, e.cluster), (0, 0))
        with self.vol(readonly=True) as v:     # persisted
            for p, data in cases.items():
                self.assertEqual(v.read(p), data)
        self.assertEqual(fat32.read_file(self.img, "/MULTI.BIN"), cases["/multi.bin"])
        self.assertClean()

    def test_replace(self):
        with self.vol() as v:
            free0 = v.free_clusters
            v.write("/f.txt", b"a" * 3000)          # 6 clusters
            old = v.stat("/f.txt").cluster
            v.write("/F.TXT", b"b" * 600)           # same file, case-insensitive
            self.assertEqual(v.read("/f.txt"), b"b" * 600)
            self.assertNotEqual(v.stat("/f.txt").cluster, old)  # new chain first
            self.assertEqual(free0 - v.free_clusters, 2)
            self.assertEqual([e.name for e in v.list()], ["f.txt"])
            v.write("/f.txt", b"")
            self.assertEqual(v.free_clusters, free0)
            self.assertEqual(v.stat("/f.txt").cluster, 0)
            v.write("/f.txt", b"c" * 10000)
            self.assertEqual(v.read("/f.txt"), b"c" * 10000)
        self.assertClean()

    def test_directory_growth(self):
        with self.vol() as v:
            v.mkdir("/many")
            names = [f"File Number {i:03d}.txt" for i in range(60)]   # 3 slots each
            for n in names:
                v.write(f"/many/{n}", n.encode())
            d, _ = self.recs(v, "/many")
            self.assertGreaterEqual(len(d.chain), 12)
            self.assertEqual([e.name for e in v.list("/many")], names)
            for n in names:
                self.assertEqual(v.read(f"/many/{n.upper()}"), n.encode())
            # root grows too
            for i in range(40):
                v.write(f"/r{i}.txt", b"r")
            self.assertGreater(len(self.recs(v)[0].chain), 1)
        self.assertClean()

    def test_deleted_slots_reused(self):
        with self.vol() as v:
            for i in range(10):
                v.write(f"/F{i}", b"")
            v.remove("/F3")
            v.remove("/F4")
            v.write("/NEW", b"n")
            d, recs = self.recs(v)
            self.assertEqual(recs["NEW"].slot, 4)    # slot 0 is the label
            v.write("/a longer name.txt", b"")       # needs 3 slots: goes to the end
            self.assertEqual(self.recs(v)[1]["a longer name.txt"].first, 11)
        self.assertClean()

    def test_names(self):
        with self.vol() as v:
            v.write("/README.TXT", b"1")
            v.write("/hello.txt", b"2")
            v.write("/Makefile", b"3")
            v.write("/MiXeD.Txt", b"4")
            v.write("/foo.c", b"5")
            v.write("/UPPER.c", b"6")
            v.write("/A Long File Name With Spaces.markdown", b"7")
            v.write("/.bashrc", b"8")
            v.write("/a+b=c[1].txt", b"9")
            v.write("/many.dots.tar.gz", b"10")
            v.write("/café über.txt", b"11")
            d, r = self.recs(v)
            expect = {
                "README.TXT": (b"README  TXT", 0, False),
                "hello.txt": (b"HELLO   TXT", 0x18, False),
                "Makefile": (b"MAKEFILE   ", 0, True),
                "MiXeD.Txt": (b"MIXED   TXT", 0, True),
                "foo.c": (b"FOO     C  ", 0x18, False),
                "UPPER.c": (b"UPPER   C  ", 0x10, False),
                "A Long File Name With Spaces.markdown": (b"ALONGF~1MAR", 0, True),
                ".bashrc": (b"BASHRC~1   ", 0, True),
                "a+b=c[1].txt": (b"A_B_C_~1TXT", 0, True),
                "many.dots.tar.gz": (b"MANYDO~1GZ ", 0, True),
                "café über.txt": (b"CAF__BER~1TXT"[:6] + b"~1TXT", 0, True),
            }
            for name, (n11, ntres, lfn) in expect.items():
                self.assertIn(name, r)
                self.assertEqual(r[name].name11, n11, name)
                self.assertEqual(r[name].ntres, ntres, name)
                self.assertEqual(r[name].lfn, lfn, name)
            self.assertEqual(v.read("/makefile"), b"3")
            self.assertEqual(v.read("/mixed.txt"), b"4")
            self.assertEqual(v.read("/ALONGF~1.MAR"), b"7")     # short name lookup
            self.assertEqual(v.read("/CAFÉ ÜBER.TXT"), b"11")
            self.assertEqual(v.list()[1].short_name, "hello.txt")
        self.assertClean()

    def test_long_name_lengths(self):
        with self.vol() as v:
            for n in (13, 26, 27, 255):
                name = ("abcdefghijklmnopqrstuvwxyz" * 10)[:n - 4] + ".txt"
                v.write("/" + name, name.encode())
                self.assertEqual(v.read("/" + name.upper()), name.encode())
            with self.assertRaises(FATError) as cm:
                v.write("/" + "x" * 256, b"")
            self.assertEqual(cm.exception.code, "invalidName")
        self.assertClean()

    def test_collisions(self):
        with self.vol() as v:
            for i in range(1, 12):
                v.write(f"/longfilename{i}.txt", b"%d" % i)
            r = self.recs(v)[1]
            self.assertEqual(r["longfilename1.txt"].name11, b"LONGFI~1TXT")
            self.assertEqual(r["longfilename2.txt"].name11, b"LONGFI~2TXT")
            self.assertEqual(r["longfilename9.txt"].name11, b"LONGFI~9TXT")
            self.assertEqual(r["longfilename10.txt"].name11, b"LONGF~10TXT")
            # mixed-case exact 8.3 names collide with an existing short name
            v.write("/Readme.txt", b"a")       # README.TXT + LFN, no tail
            v.write("/Readme.txT", b"b")       # same name case-insensitively: replaces
            self.assertEqual(v.read("/readme.txt"), b"b")
            self.assertEqual(self.recs(v)[1]["Readme.txt"].name11, b"README  TXT")
            for i in range(11):
                self.assertEqual(v.read(f"/LONGFILENAME{i + 1}.TXT"), b"%d" % (i + 1))
        self.assertClean()

    def test_invalid_names(self):
        with self.vol() as v:
            for bad in ("a:b", "q?", "star*", "pipe|", "lt<", 'quo"te', "back\\slash",
                        "trailing.", "trailing ", "ctl\x01", "."):
                with self.assertRaises(FATError, msg=bad) as cm:
                    v.write(["", bad] if bad == "." else "/" + bad, b"")
                self.assertIn(cm.exception.code, ("invalidName", "isADirectory"), bad)
            with self.assertRaises(FATError) as cm:
                v.mkdir("/bad:dir")
            self.assertEqual(cm.exception.code, "invalidName")
            self.assertEqual(v.list(), [])
        self.assertClean()

    def test_mkdir(self):
        with self.vol() as v:
            v.mkdir("/a")
            v.mkdir("/a/Bee")
            v.mkdir("/A/bee/c")
            v.write("/a/bee/c/f.txt", b"deep")
            self.assertEqual(v.read("/A/BEE/C/F.TXT"), b"deep")
            a, b, c = v.stat("/a"), v.stat("/a/bee"), v.stat("/a/bee/c")
            for e, parent in ((a, 0), (b, a.cluster), (c, b.cluster)):
                self.assertTrue(e.is_dir)
                dots = [r for r in v._read_dir(e.cluster).recs if r.kind == "dot"]
                self.assertEqual([(r.name, r.cluster, r.slot) for r in dots],
                                 [(".", e.cluster, 0), ("..", parent, 1)])
            for path, code in (("/a", "exists"), ("/A/BEE", "exists"), ("/x/y", "notFound"),
                               ("/a/bee/c/f.txt/z", "notADirectory")):
                with self.assertRaises(FATError) as cm:
                    v.mkdir(path)
                self.assertEqual(cm.exception.code, code, path)
            with self.assertRaises(FATError) as cm:
                v.write("/a/bee", b"")
            self.assertEqual(cm.exception.code, "isADirectory")
            with self.assertRaises(FATError) as cm:
                v.read("/a")
            self.assertEqual(cm.exception.code, "isADirectory")
            with self.assertRaises(FATError) as cm:
                v.read("/nope")
            self.assertEqual(cm.exception.code, "notFound")
            self.assertEqual(sorted(p for p, _ in v.walk()),
                             ["/a", "/a/Bee", "/a/Bee/c", "/a/Bee/c/f.txt"])
        self.assertClean()

    def test_rm(self):
        with self.vol() as v:
            free0 = v.free_clusters
            v.write("/big.bin", os.urandom(50_000))
            v.mkdir("/d")
            v.write("/d/Some Long Name.txt", b"x" * 1500)
            v.mkdir("/d/e")
            with self.assertRaises(FATError) as cm:
                v.remove("/d")
            self.assertEqual(cm.exception.code, "notEmpty")
            v.remove("/BIG.BIN")
            self.assertFalse(v.exists("/big.bin"))
            v.remove("/d/some long name.TXT")
            v.remove("/d/e")
            self.assertEqual(v.list("/d"), [])
            v.remove("/d")
            self.assertEqual(v.free_clusters, free0)
            self.assertEqual(v.list(), [])
            with self.assertRaises(FATError) as cm:
                v.remove("/d")
            self.assertEqual(cm.exception.code, "notFound")
            v.mkdir("/t")
            v.mkdir("/t/u")
            v.write("/t/u/f", b"f" * 2000)
            v.remove("/t", recursive=True)
            self.assertEqual(v.free_clusters, free0)
        with self.vol() as v:
            self.assertEqual(v.free_clusters, free0)        # FSInfo written back
        self.assertClean()

    def test_full_disk(self):
        small = os.path.join(self.tmp.name, "small.img")
        fat32.mkfs(small, "33M", when=WHEN)
        with fat32.Volume(small, when=WHEN) as v:
            v.write("/keep.txt", b"keep")
            room = v.free_clusters * v.cluster_size
            with self.assertRaises(FATError) as cm:
                v.write("/huge.bin", bytes(room + 1))
            self.assertEqual(cm.exception.code, "noSpace")
            self.assertFalse(v.exists("/huge.bin"))
            v.write("/fill.bin", b"\xAA" * room)
            self.assertEqual(v.free_clusters, 0)
            with self.assertRaises(FATError) as cm:
                v.write("/one.txt", b"1")
            self.assertEqual(cm.exception.code, "noSpace")
            with self.assertRaises(FATError):
                v.mkdir("/dir")
            v.write("/keep.txt", b"")              # frees one cluster
            v.write("/one.txt", b"1")
            self.assertEqual(v.read("/keep.txt"), b"")
        self.assertEqual(fat32.fsck(small), [])
        os.remove(small)

    def test_cli(self):
        host = os.path.join(self.tmp.name, "host.txt")
        with open(host, "wb") as f:
            f.write(b"from the host\n")

        def run(*args):
            out = io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
                rc = fat32.main(list(args))
            return rc, out.getvalue()

        self.assertEqual(run("mkdir", self.img, "/Dir One")[0], 0)
        self.assertEqual(run("put", self.img, host, "/Dir One/Host File.txt")[0], 0)
        self.assertEqual(run("put", self.img, host, "/dir one/")[0], 0)     # into a directory
        rc, out = run("ls", self.img, "/")
        self.assertEqual(out.split(), ["Dir", "One/"])
        rc, out = run("ls", self.img, "-R")
        self.assertIn("14  /Dir One/Host File.txt", out)
        self.assertIn("14  /Dir One/host.txt", out)
        self.assertIn("/Dir One/\n", out)
        r = subprocess.run([sys.executable, fat32.__file__, "cat", self.img, "/DIR ONE/HOST FILE.TXT"],
                           capture_output=True)
        self.assertEqual(r.stdout, b"from the host\n")
        rc, out = run("fsck", self.img)
        self.assertEqual(rc, 0)
        self.assertIn("clean", out)
        self.assertEqual(run("rm", self.img, "/Dir One")[0], 1)            # not empty
        self.assertEqual(run("rm", self.img, "-r", "/Dir One")[0], 0)
        self.assertEqual(run("cat", self.img, "/nope")[0], 1)
        self.assertEqual(run("put", self.img, host, "/bad:name")[0], 1)
        self.assertEqual(run("info", self.img)[0], 0)
        self.poke(510, b"\0\0")
        rc, out = run("fsck", self.img)
        self.assertEqual(rc, 1)
        self.assertIn("signature", out)


class TestFsck(Base):
    """Each test injects one kind of corruption into a known-good image."""

    def setUp(self):
        super().setUp()
        with self.vol() as v:
            v.write("/a.bin", bytes(range(256)) * 8)       # 4 clusters
            v.write("/b.bin", b"b" * 1000)                 # 2 clusters
            v.mkdir("/dir")
            v.mkdir("/dir/sub")
            v.write("/dir/A Long Name.txt", b"long")
            self.a = v.chain(v.stat("/a.bin").cluster)
            self.b = v.chain(v.stat("/b.bin").cluster)
            self.dir = v.stat("/dir").cluster
            self.sub = v.stat("/dir/sub").cluster
            self.fat1 = 32 * SECTOR
            self.fat2 = (32 + v.bpb.fatsz) * SECTOR
            d, recs = self.recs(v, "/dir")
            self.lfn_rec = recs["A Long Name.txt"]
            self.dir_slot = lambda i, d=d: v._slot_offset(d, i)
            d, recs = self.recs(v)
            self.b_slot = v._slot_offset(d, recs["b.bin"].slot)
            self.data = lambda c: v._offset(c)
        self.assertClean()

    def set_fat(self, c, value, both=True):
        for base in ((self.fat1, self.fat2) if both else (self.fat1,)):
            self.poke(base + 4 * c, struct.pack("<I", value))

    def test_boot_signature(self):
        self.poke(510, b"\x55\xAB")
        self.assertProblem("boot sector signature")
        with self.assertRaises(FATError) as cm:
            fat32.Volume(self.img)
        self.assertEqual(cm.exception.code, "notFAT32")

    def test_bad_bpb(self):
        self.poke(11, struct.pack("<H", 1024))
        self.assertProblem("bytes per sector")
        self.poke(11, struct.pack("<H", 512))
        self.poke(13, b"\x03")
        self.assertProblem("power of two")
        self.poke(13, b"\x01")
        self.poke(17, struct.pack("<H", 512))       # FAT16-style root entry count
        self.assertProblem("FAT12/16 fields")

    def test_too_few_clusters(self):
        self.poke(32, struct.pack("<I", 60000))     # TotSec32
        self.assertProblem("fewer than 65525")

    def test_backup_boot(self):
        self.poke(6 * SECTOR + 3, b"OTHEROEM")
        self.assertProblem("backup boot sector")

    def test_fsinfo_signature(self):
        self.poke(1 * SECTOR, b"\0\0\0\0")
        self.assertProblem("FSInfo (sector 1) has bad signatures")
        self.poke(7 * SECTOR + 508, b"\0\0\0\0")
        self.assertProblem("backup FSInfo (sector 7) has bad signatures")

    def test_fsinfo_free_count(self):
        self.poke(1 * SECTOR + 488, struct.pack("<I", 5))
        self.assertProblem("FSInfo free count 5 is wrong")
        self.poke(1 * SECTOR + 488, struct.pack("<I", 0xFFFFFFFF))   # unknown is fine
        self.assertEqual(fat32.fsck(self.img), [])

    def test_fat_copies_differ(self):
        self.set_fat(self.a[0], self.a[2], both=False)
        p = fat32.fsck(self.img)
        self.assertTrue(any("FAT copies differ" in x and f"cluster {self.a[0]}" in x for x in p), p)

    def test_lost_clusters(self):
        self.set_fat(60000, fat32.EOC)
        self.set_fat(60001, 60002)
        self.set_fat(60002, fat32.EOC)
        p = self.assertProblem("3 lost clusters")
        self.assertTrue(any("FSInfo free count" in x for x in p))

    def test_cross_link(self):
        self.poke(self.b_slot + 26, struct.pack("<H", self.a[2]))
        self.assertProblem("cross-linked with /a.bin")

    def test_chain_loop(self):
        self.set_fat(self.a[-1], self.a[1])
        self.assertProblem("cluster chain loop")
        with self.vol() as v:
            with self.assertRaises(FATError) as cm:
                v.read("/a.bin")
            self.assertEqual(cm.exception.code, "corrupt")

    def test_chain_into_free(self):
        self.set_fat(self.a[1], 70000)
        self.assertProblem("chain runs into free cluster")

    def test_size_mismatch(self):
        self.poke(self.b_slot + 28, struct.pack("<I", 1500))
        self.assertProblem("size 1500 needs 3 clusters, chain has 2")
        self.poke(self.b_slot + 28, struct.pack("<I", 200))
        self.assertProblem("size 200 needs 1 clusters, chain has 2")

    def test_lfn_checksum(self):
        for i in range(self.lfn_rec.first, self.lfn_rec.slot):   # every LFN entry
            off = self.dir_slot(i)
            e = bytearray(self.peek(off, 32))
            e[13] ^= 0xFF
            self.poke(off, bytes(e))
        self.assertProblem("LFN checksum mismatch")
        with self.vol(readonly=True) as v:     # falls back to the short name
            self.assertEqual([e.name for e in v.list("/dir")], ["sub", "ALONGN~1.TXT"])

    def test_lfn_inconsistent_checksum(self):
        off = self.dir_slot(self.lfn_rec.first)
        e = bytearray(self.peek(off, 32))
        e[13] ^= 0xFF
        self.poke(off, bytes(e))
        self.assertProblem("the sequence has")

    def test_orphan_lfn(self):
        self.poke(self.dir_slot(self.lfn_rec.slot), b"\xE5")   # delete only the short entry
        self.assertProblem("orphan LFN")

    def test_lfn_out_of_sequence(self):
        off = self.dir_slot(self.lfn_rec.first)
        self.poke(off, b"\x45")                 # last-flag with ordinal 5 (sequence has 2)
        self.assertProblem("orphan LFN entry")

    def test_dot_entries(self):
        self.poke(self.data(self.sub) + 32 + 26, struct.pack("<H", 1234))
        self.assertProblem("'..' points to cluster 1234, expected %d" % self.dir)
        self.poke(self.data(self.sub) + 32 + 26, struct.pack("<H", self.dir))
        self.poke(self.data(self.dir) + 26, struct.pack("<H", 99))
        self.assertProblem("'.' points to cluster 99")
        self.poke(self.data(self.dir) + 26, struct.pack("<H", self.dir))
        self.poke(self.data(self.dir), b"X")
        self.assertProblem("missing '.' and '..'")

    def test_dirty_bit(self):
        self.set_fat(1, 0x07FFFFFF)
        self.assertProblem("dirty bit")


class TestFixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.img = os.path.join(self.tmp.name, "fix.img")
        fat32.build_fixture(self.img)

    def tearDown(self):
        self.tmp.cleanup()

    def test_tree(self):
        self.assertEqual(fat32.fsck(self.img), [])
        with fat32.Volume(self.img, readonly=True) as v:
            self.assertEqual(v.tree(), fat32.FIXTURE_TREE)
            self.assertEqual(v.label, "WIFFERFIX")
            shorts = {p: e.short_name for p, e in v.walk()}
            self.assertEqual(shorts["/longfilename2.txt"], "LONGFI~2.TXT")
            self.assertEqual(shorts["/a+b=c.txt"], "A_B_C~1.TXT")
            self.assertEqual(shorts["/hello.txt"], "hello.txt")
            self.assertEqual(shorts["/docs/Notes"], "NOTES")
            self.assertEqual(len(v.chain(v.stat("/docs/big.bin").cluster)), 10)
            d = v._read_dir(v.root_cluster)
            self.assertEqual(len(d.chain), 2)
            self.assertEqual(sum(1 for i in range(len(d.raw) // 32) if d.raw[i * 32] == 0xE5), 3)

    def test_committed_fixtures_match(self):
        with open(self.img, "rb") as f:
            want = f.read()
        gz = os.path.join(FIXTURES, "fat32-lfn.img.gz")
        sp = os.path.join(FIXTURES, "fat32-lfn.sparse")
        with gzip.open(gz, "rb") as f:
            self.assertEqual(f.read(), want, "regenerate: tests/fat32.py fixture IMG --gzip ... --sparse ...")
        out = os.path.join(self.tmp.name, "from-sparse.img")
        fat32.read_sparse(sp, out)
        with open(out, "rb") as f:
            self.assertEqual(f.read(), want)
        again = os.path.join(self.tmp.name, "again.sparse")
        fat32.write_sparse(self.img, again)
        with open(again, "rb") as a, open(sp, "rb") as b:
            self.assertEqual(a.read(), b.read())


@unittest.skipUnless(HOST_FSCK, "no fsck_msdos / fsck.fat")
class TestHostFsck(Base):
    def test_host_fsck_after_many_operations(self):
        with self.vol() as v:
            for i in range(30):
                v.write(f"/Dir Entry Number {i}.txt", os.urandom(i * 300))
            v.mkdir("/sub")
            v.mkdir("/sub/Deeper Dir")
            v.write("/sub/Deeper Dir/x", b"x" * 9000)
            for i in range(0, 30, 3):
                v.remove(f"/dir entry number {i}.TXT")
            v.write("/Dir Entry Number 1.txt", b"replaced")
        self.assertClean()

    def test_host_fsck_detects_injected_lost_cluster(self):
        with self.vol() as v:
            v._set(5000, fat32.EOC)
        r = subprocess.run(HOST_FSCK + [self.img], capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)


@unittest.skipUnless(shutil.which("mkfs.fat"), "no mkfs.fat")
class TestMkfsFat(unittest.TestCase):
    def test_read_mkfs_fat_image(self):
        with tempfile.TemporaryDirectory() as tmp:
            img = os.path.join(tmp, "m.img")
            subprocess.run(["mkfs.fat", "-F", "32", "-C", img, str(64 * 1024)], check=True,
                           capture_output=True)
            self.assertEqual(fat32.fsck(img), [])
            with fat32.Volume(img) as v:
                v.write("/Hello There.txt", b"hi")
            self.assertEqual(fat32.fsck(img), [])
            if shutil.which("mtype"):
                r = subprocess.run(["mtype", "-i", img, "::/Hello There.txt"], capture_output=True)
                self.assertEqual(r.stdout, b"hi")


@unittest.skipUnless(shutil.which("mcopy") and shutil.which("mdir"), "no mtools")
class TestMtools(Base):
    def test_mtools_both_ways(self):
        with self.vol() as v:
            v.mkdir("/Mixed Dir")
            v.write("/Mixed Dir/Long Name File.txt", b"ours")
        env = dict(os.environ, MTOOLS_SKIP_CHECK="1")
        r = subprocess.run(["mtype", "-i", self.img, "::/Mixed Dir/Long Name File.txt"],
                           capture_output=True, env=env)
        self.assertEqual(r.stdout, b"ours")
        host = os.path.join(self.tmp.name, "theirs.txt")
        with open(host, "wb") as f:
            f.write(b"theirs" * 500)
        subprocess.run(["mcopy", "-i", self.img, host, "::/Mixed Dir/From Mtools.txt"],
                       check=True, env=env)
        subprocess.run(["mmd", "-i", self.img, "::/mtools dir"], check=True, env=env)
        self.assertEqual(fat32.read_file(self.img, "/mixed dir/from mtools.txt"), b"theirs" * 500)
        with fat32.Volume(self.img, readonly=True) as v:
            self.assertTrue(v.stat("/MTOOLS DIR").is_dir)
        problems = fat32.fsck(self.img)
        # mtools may leave FSInfo's free count stale; anything else is a real problem
        self.assertEqual([p for p in problems if "FSInfo free count" not in p], [])


@unittest.skipUnless(sys.platform == "darwin" and os.environ.get("FAT32_MOUNT_TEST")
                     and shutil.which("hdiutil"), "set FAT32_MOUNT_TEST=1 on macOS")
class TestMacMount(Base):
    """Attach with hdiutil, mount with diskutil (works without sudo)."""

    @contextlib.contextmanager
    def mounted(self, readonly):
        args = ["hdiutil", "attach", "-imagekey", "diskimage-class=CRawDiskImage", "-nomount", self.img]
        if readonly:
            args.insert(2, "-readonly")
        dev = subprocess.run(args, capture_output=True, text=True, check=True).stdout.split()[0]
        mnt = os.path.join(self.tmp.name, "mnt")
        os.makedirs(mnt, exist_ok=True)
        try:
            subprocess.run(["diskutil", "mount"] + (["readOnly"] if readonly else []) +
                           ["-mountPoint", mnt, dev], check=True, capture_output=True)
            yield mnt
        finally:
            subprocess.run(["diskutil", "eject", dev], capture_output=True)

    def test_macos_reads_our_writes(self):
        with self.vol() as v:
            v.mkdir("/Some Dir")
            v.write("/Some Dir/A Long Mixed Name.txt", b"hello mac")
            v.write("/lower.txt", b"lower")
        with self.mounted(readonly=True) as m:
            self.assertEqual(sorted(os.listdir(m)), ["Some Dir", "lower.txt"])
            with open(os.path.join(m, "Some Dir", "A Long Mixed Name.txt"), "rb") as f:
                self.assertEqual(f.read(), b"hello mac")

    def test_we_read_macos_writes(self):
        data = os.urandom(70_000)
        with self.mounted(readonly=False) as m:
            os.makedirs(os.path.join(m, "Mac Dir", "Inner"))
            with open(os.path.join(m, "Mac Dir", "Inner", "Written By macOS.bin"), "wb") as f:
                f.write(data)
        self.assertEqual(fat32.read_file(self.img, "/mac dir/inner/written by macos.bin"), data)
        self.assertEqual(fat32.fsck(self.img), [])


if __name__ == "__main__":
    unittest.main()
