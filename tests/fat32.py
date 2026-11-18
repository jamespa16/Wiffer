#!/usr/bin/env python3
"""Host-side FAT32 tool for Wiffer disk images (Phase Z).

An independent implementation written from Microsoft's FAT32 File System
Specification (fatgen103), so it can cross-check the kernel's fat32.swift.
Python 3 stdlib only. Images are whole-disk ("superfloppy") FAT32 with
512-byte sectors and no partition table.

CLI:
    fat32.py mkfs IMG [--size 64M] [--label WIFFER]
    fat32.py ls IMG [path] [-R]
    fat32.py cat IMG path
    fat32.py put IMG hostfile path       (hostfile "-" reads stdin)
    fat32.py mkdir IMG path
    fat32.py rm IMG path [-r]
    fat32.py fsck IMG                    (exit 1 and print problems)
    fat32.py info IMG
    fat32.py fixture IMG [--gzip OUT.gz] [--sparse OUT]

API (for the test harness):
    mkfs(path, size=64*MiB, label="WIFFER", volume_id=None, when=None)
    fsck(path) -> list[str]                  # [] when clean
    Volume(path, readonly=False, when=None)  # context manager
        .label .cluster_size .total_clusters .free_clusters
        .list(path) -> list[Entry]   .read(path) -> bytes
        .write(path, data)  .mkdir(path)  .remove(path, recursive=False)
        .exists(path) .stat(path) -> Entry  .walk(path="/") .tree()
        .sync()  .close()  .check() -> list[str]
    Entry(name, is_dir, size, short_name, cluster)
    FATError(code, detail): code is one of FATError.CODES
    read_file(img, path), write_file(img, path, data), list_dir(img, path)
    build_fixture(path) / FIXTURE_TREE, write_sparse(img, out), read_sparse(src, img)

Paths are "/"-separated strings (leading "/" optional) or lists of
components; lookup is case-insensitive, as FAT requires.
"""
import argparse
import array
import collections
import gzip
import os
import struct
import sys
import time

SECTOR = 512
MiB = 1 << 20
MIN_CLUSTERS = 65525           # fewer clusters than this is FAT16 by definition
MAX_CLUSTERS = 0x0FFFFFF5
MASK = 0x0FFFFFFF              # FAT32 entries are 28 bits; the top 4 are reserved
EOC = 0x0FFFFFFF
EOC_MIN = 0x0FFFFFF8
BAD = 0x0FFFFFF7
FREE = 0
CLEAN_SHUTDOWN = 0x08000000    # FAT[1] bit: set = volume cleanly unmounted
HARD_ERROR = 0x04000000        # FAT[1] bit: set = no disk I/O errors seen

ATTR_READ_ONLY = 0x01
ATTR_HIDDEN = 0x02
ATTR_SYSTEM = 0x04
ATTR_VOLUME_ID = 0x08
ATTR_DIRECTORY = 0x10
ATTR_ARCHIVE = 0x20
ATTR_LONG_NAME = 0x0F
NT_LOWER_BASE = 0x08
NT_LOWER_EXT = 0x10

LEAD_SIG = 0x41615252
STRUC_SIG = 0x61417272
TRAIL_SIG = 0xAA550000
MAX_DIR_ENTRIES = 65536        # spec: a directory may not exceed 65536 32-byte entries

# Characters allowed in an 8.3 short name besides A-Z and 0-9 (and >127,
# which this tool never generates).
SHORT_SPECIAL = set("$%'-_@~`!(){}^#&")
SHORT_OK = set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789") | SHORT_SPECIAL
LONG_BAD = set('"*/:<>?\\|')

DEFAULT_WHEN = (2026, 1, 1, 0, 0, 0)


class FATError(Exception):
    CODES = {
        "notFAT32": "not a FAT32 volume",
        "corrupt": "file system is corrupt",
        "notFound": "no such file or directory",
        "exists": "file exists",
        "notADirectory": "not a directory",
        "isADirectory": "is a directory",
        "notEmpty": "directory not empty",
        "invalidName": "invalid name",
        "noSpace": "no space left on volume",
        "readOnly": "volume opened read-only",
    }

    def __init__(self, code, detail=""):
        assert code in self.CODES, code
        self.code = code
        self.detail = detail
        msg = self.CODES[code]
        super().__init__(f"{detail}: {msg}" if detail else msg)


Entry = collections.namedtuple("Entry", "name is_dir size short_name cluster")


# ---------------------------------------------------------------- helpers

def parse_size(text):
    """'64M', '33MiB', '1G', '512K', '67108864' -> bytes."""
    t = str(text).strip().upper().removesuffix("IB").removesuffix("B")
    mult = 1
    if t and t[-1] in "KMG":
        mult = {"K": 1 << 10, "M": 1 << 20, "G": 1 << 30}[t[-1]]
        t = t[:-1]
    return int(float(t) * mult)


def sectors_per_cluster(total_sectors):
    """Microsoft's DskSzToSecPerClus table for FAT32 (512-byte sectors).
    0 means the disk is too small for FAT32."""
    for limit, spc in ((66600, 0), (532480, 1), (16777216, 8),
                       (33554432, 16), (67108864, 32)):
        if total_sectors <= limit:
            return spc
    return 64


def fat_size(total_sectors, reserved, spc, nfats):
    """FAT size in sectors, per the spec's formula (slightly generous)."""
    tmp1 = total_sectors - reserved          # RootDirSectors is 0 on FAT32
    tmp2 = (256 * spc + nfats) // 2
    return (tmp1 + tmp2 - 1) // tmp2


def lfn_checksum(name11):
    s = 0
    for b in name11:
        s = ((((s & 1) << 7) | (s >> 1)) + b) & 0xFF
    return s


def _pack_date(when):
    y, mo, d = when[0], when[1], when[2]
    return ((max(y, 1980) - 1980) << 9) | (mo << 5) | d


def _pack_time(when):
    return (when[3] << 11) | (when[4] << 5) | (when[5] // 2)


def _split(path):
    if isinstance(path, (list, tuple)):
        parts = list(path)
    else:
        parts = str(path).split("/")
    out = []
    for p in parts:
        if p in ("", "."):
            continue
        if p == "..":
            if out:
                out.pop()
            continue
        out.append(p)
    return out


def _join(parts):
    return "/" + "/".join(parts)


def check_long_name(name):
    """Raise FATError('invalidName') unless `name` is a legal long name."""
    if not name or name in (".", ".."):
        raise FATError("invalidName", repr(name))
    for c in name:
        if ord(c) < 0x20 or c in LONG_BAD:
            raise FATError("invalidName", repr(name))
    if name[-1] in ". ":
        raise FATError("invalidName", repr(name))
    if len(name.encode("utf-16-le", "surrogatepass")) // 2 > 255:
        raise FATError("invalidName", repr(name))


def exact_short(name):
    """If `name` is a legal 8.3 name (ignoring case), return (name11,
    ntres, mixed): ntres holds the NT lowercase bits when base and/or
    extension are all-lowercase, mixed is True when either part mixes cases
    (so an LFN is needed to keep the case). Otherwise None."""
    if name in (".", "..") or name.count(".") > 1:
        return None
    base, dot, ext = name.partition(".")
    if dot and not ext:
        return None
    if not 1 <= len(base) <= 8 or len(ext) > 3:
        return None
    for c in base + ext:
        if not c.isascii() or c.upper() not in SHORT_OK:
            return None
    ntres, mixed = 0, False
    for part, bit in ((base, NT_LOWER_BASE), (ext, NT_LOWER_EXT)):
        lower = any(c.islower() for c in part)
        upper = any(c.isupper() for c in part)
        if lower and upper:
            mixed = True
        elif lower:
            ntres |= bit
    if mixed:
        ntres = 0
    n11 = (base.upper().ljust(8) + ext.upper().ljust(3)).encode("ascii")
    return n11, ntres, mixed


def short_name_for(name, taken):
    """Choose the 8.3 name for long name `name` given the set of 11-byte
    short names already in the directory. Returns (name11, ntres, needs_lfn)."""
    ex = exact_short(name)
    if ex and ex[0] not in taken:
        n11, ntres, mixed = ex
        return n11, ntres, mixed
    # Basis-name generation (spec section 7 / fatgen103 "Basis-Name Generation").
    s = name.upper().replace(" ", "").lstrip(".")
    if "." in s:
        base, ext = s.rsplit(".", 1)
        base = base.replace(".", "")
    else:
        base, ext = s, ""

    def conv(t):
        return "".join(c if c.isascii() and c in SHORT_OK else "_" for c in t)

    base, ext = conv(base)[:8] or "_", conv(ext)[:3]
    for i in range(1, 1000000):
        tail = f"~{i}"
        n11 = (base[:8 - len(tail)] + tail).ljust(8).encode("ascii") + ext.ljust(3).encode("ascii")
        if n11 not in taken:
            return n11, 0, True
    raise FATError("exists", name)


def lfn_slots(name, csum):
    """The LFN directory entries for `name`, in on-disk order (last first)."""
    raw = name.encode("utf-16-le", "surrogatepass")
    units = list(struct.unpack(f"<{len(raw) // 2}H", raw))
    if len(units) % 13:
        units.append(0)
        while len(units) % 13:
            units.append(0xFFFF)
    n = len(units) // 13
    slots = []
    for k in range(n, 0, -1):
        part = units[(k - 1) * 13:k * 13]
        e = bytearray(32)
        e[0] = k | (0x40 if k == n else 0)
        struct.pack_into("<5H", e, 1, *part[0:5])
        e[11] = ATTR_LONG_NAME
        e[13] = csum
        struct.pack_into("<6H", e, 14, *part[5:11])
        struct.pack_into("<2H", e, 28, *part[11:13])
        slots.append(bytes(e))
    return slots


def short_entry(name11, attr, cluster, size, when, ntres=0):
    e = bytearray(32)
    e[0:11] = name11
    e[11] = attr
    e[12] = ntres
    e[13] = (when[5] % 2) * 100
    d, t = _pack_date(when), _pack_time(when)
    struct.pack_into("<HHHHHHHI", e, 14, t, d, d, cluster >> 16, t, d, cluster & 0xFFFF, size)
    return bytes(e)


def _display_short(e):
    base = bytearray(e[0:8])
    if base[0] == 0x05:
        base[0] = 0xE5
    b = base.decode("cp437").rstrip(" ")
    x = bytes(e[8:11]).decode("cp437").rstrip(" ")
    if e[12] & NT_LOWER_BASE:
        b = b.lower()
    if e[12] & NT_LOWER_EXT:
        x = x.lower()
    return b + ("." + x if x else "")


def _lfn_units(e):
    return struct.unpack_from("<5H", e, 1) + struct.unpack_from("<6H", e, 14) + struct.unpack_from("<2H", e, 28)


class _Rec:
    """A parsed directory record: a short entry plus its LFN run, if any."""
    __slots__ = ("kind", "name", "short", "name11", "attr", "ntres", "cluster",
                 "size", "first", "slot", "lfn")

    def entry(self):
        return Entry(self.name, self.kind == "dir", self.size, self.short, self.cluster)


def parse_dir(raw, problems=None, where="/"):
    """Parse directory bytes into _Rec objects (kinds: file, dir, label,
    dot). LFN runs are verified (complete ordinal sequence, matching
    checksum); a bad run falls back to the 8.3 name and is reported in
    `problems` when given."""
    def report(msg):
        if problems is not None:
            problems.append(f"{where}: {msg}")

    recs = []
    run = []                       # pending LFN entries: (slot, ord, csum, units)
    for i in range(len(raw) // 32):
        e = raw[i * 32:i * 32 + 32]
        b0 = e[0]
        if b0 == 0x00:
            if run:
                report(f"orphan LFN entries at slot {run[0][0]} (no short entry follows)")
            break
        if b0 == 0xE5:
            if run:
                report(f"orphan LFN entries at slot {run[0][0]} (followed by a deleted entry)")
                run = []
            continue
        attr = e[11]
        if attr & 0x3F == ATTR_LONG_NAME:
            o = b0 & 0x3F
            if b0 & 0x40:
                if run:
                    report(f"orphan LFN entries at slot {run[0][0]} (new sequence starts)")
                run = [(i, o, e[13], _lfn_units(e))] if 1 <= o <= 20 else []
                if not run:
                    report(f"LFN entry at slot {i} has bad ordinal {o}")
            elif run and o == run[-1][1] - 1 and e[13] == run[0][2]:
                run.append((i, o, e[13], _lfn_units(e)))
            elif run and o == run[-1][1] - 1:
                report(f"LFN entry at slot {i} has checksum {e[13]:#04x}, the sequence has {run[0][2]:#04x}")
                run = []
            else:
                report(f"orphan LFN entry at slot {i} (ordinal {o} out of sequence)")
                run = []
            continue
        r = _Rec()
        r.name11 = bytes(e[0:11])
        r.attr = attr
        r.ntres = e[12]
        r.cluster = (struct.unpack_from("<H", e, 20)[0] << 16) | struct.unpack_from("<H", e, 26)[0]
        r.size = struct.unpack_from("<I", e, 28)[0]
        r.slot = i
        r.first = i
        r.lfn = False
        r.short = _display_short(e)
        r.name = r.short
        if attr & ATTR_VOLUME_ID and not attr & ATTR_DIRECTORY:
            r.kind = "label"
            r.name = r.short = bytes(e[0:11]).decode("cp437").rstrip(" ")
        elif r.name11 in (b".          ", b"..         "):
            r.kind = "dot"
            r.name = r.short = r.name11.decode().rstrip()
        else:
            r.kind = "dir" if attr & ATTR_DIRECTORY else "file"
        if run:
            csum = lfn_checksum(r.name11)
            if run[-1][1] != 1:
                report(f"incomplete LFN sequence before {r.short!r} at slot {i}")
            elif run[0][2] != csum:
                report(f"LFN checksum mismatch for {r.short!r} at slot {i} "
                       f"(stored {run[0][2]:#04x}, expected {csum:#04x})")
            elif r.kind in ("label", "dot"):
                report(f"LFN entries attached to {r.kind} entry at slot {i}")
            else:
                units = []
                for _, _, _, u in reversed(run):
                    units.extend(u)
                if 0 in units:
                    units = units[:units.index(0)]
                r.name = struct.pack(f"<{len(units)}H", *units).decode("utf-16-le", "replace")
                r.first = run[0][0]
                r.lfn = True
            run = []
        recs.append(r)
    return recs


# ---------------------------------------------------------------- BPB

BPB = collections.namedtuple("BPB", "jmp oem bps spc reserved nfats root_ents tot16 media "
                                    "fat16 tot32 fatsz ext_flags fs_ver root_cluster fsinfo "
                                    "backup drive boot_sig vol_id vol_label fs_type sig")


def parse_bpb(s):
    (bps, spc, reserved, nfats, root_ents, tot16, media, fat16) = struct.unpack_from("<HBHBHHBH", s, 11)
    (tot32, fatsz, ext_flags, fs_ver, root_cluster, fsinfo, backup) = struct.unpack_from("<IIHHIHH", s, 32)
    drive, boot_sig, vol_id = s[64], s[66], struct.unpack_from("<I", s, 67)[0]
    return BPB(bytes(s[0:3]), bytes(s[3:11]), bps, spc, reserved, nfats, root_ents, tot16, media,
               fat16, tot32, fatsz, ext_flags, fs_ver, root_cluster, fsinfo, backup, drive,
               boot_sig, vol_id, bytes(s[71:82]), bytes(s[82:90]), struct.unpack_from("<H", s, 510)[0])


def bpb_problems(b, file_size):
    """Problems with a BPB. Geometry checks that make the volume unusable
    come first; returns (problems, fatal)."""
    p = []
    if b.sig != 0xAA55:
        p.append(f"boot sector signature is {b.sig:#06x}, not 0xaa55")
    if not (b.jmp[0] == 0xEB and b.jmp[2] == 0x90) and b.jmp[0] != 0xE9:
        p.append(f"boot sector jump {b.jmp.hex()} is not EB xx 90 or E9 xx xx")
    fatal = False
    if b.bps != SECTOR:
        p.append(f"bytes per sector is {b.bps}, expected 512")
        fatal = True
    if b.spc == 0 or b.spc & (b.spc - 1) or b.spc > 128:
        p.append(f"sectors per cluster {b.spc} is not a power of two <= 128")
        fatal = True
    if b.reserved == 0:
        p.append("reserved sector count is 0")
        fatal = True
    if b.nfats == 0:
        p.append("number of FATs is 0")
        fatal = True
    if b.root_ents != 0 or b.fat16 != 0 or b.tot16 != 0:
        p.append("FAT12/16 fields (root entries, FATSz16, TotSec16) are not zero")
        fatal = True
    if b.fatsz == 0 or b.tot32 == 0:
        p.append("FATSz32 or TotSec32 is zero")
        fatal = True
    if fatal:
        return p, True
    if b.tot32 * SECTOR > file_size:
        p.append(f"volume ({b.tot32} sectors) is larger than the image ({file_size // SECTOR} sectors)")
        fatal = True
    first_data = b.reserved + b.nfats * b.fatsz
    if first_data >= b.tot32:
        p.append("FATs extend past the end of the volume")
        return p, True
    clusters = (b.tot32 - first_data) // b.spc
    if clusters < MIN_CLUSTERS:
        p.append(f"{clusters} clusters is fewer than 65525: FAT12/16, not FAT32")
        fatal = True
    if b.fatsz * SECTOR // 4 < clusters + 2:
        p.append(f"FAT ({b.fatsz} sectors) is too small for {clusters} clusters")
        fatal = True
    if not 2 <= b.root_cluster < clusters + 2:
        p.append(f"root cluster {b.root_cluster} is out of range")
        fatal = True
    if b.fs_ver != 0:
        p.append(f"FAT32 version {b.fs_ver:#x} is not 0.0")
    if b.ext_flags & 0x80:
        p.append("FAT mirroring is disabled (BPB_ExtFlags bit 7)")
    if b.fsinfo in (0, 0xFFFF) or b.fsinfo >= b.reserved:
        p.append(f"FSInfo sector {b.fsinfo} is not in the reserved region")
    if b.backup not in (0, 0xFFFF) and b.backup + 1 >= b.reserved:
        p.append(f"backup boot sector {b.backup} is not in the reserved region")
    return p, fatal


# ---------------------------------------------------------------- mkfs

def mkfs(path, size=64 * MiB, label="WIFFER", volume_id=None, when=None):
    """Create (or overwrite) `path` as a superfloppy FAT32 image of `size`
    bytes. Raises ValueError if the size can't hold 65525 clusters."""
    if isinstance(size, str):
        size = parse_size(size)
    if size % SECTOR:
        raise ValueError("size must be a multiple of 512")
    total = size // SECTOR
    if total > 0xFFFFFFFF:
        raise ValueError("volume too large")
    spc = sectors_per_cluster(total)
    if spc == 0:
        raise ValueError(f"{size} bytes is too small for FAT32 (minimum 66601 sectors, about 32.5 MiB)")
    reserved, nfats = 32, 2
    fatsz = fat_size(total, reserved, spc, nfats)
    clusters = (total - reserved - nfats * fatsz) // spc
    if clusters < MIN_CLUSTERS:
        raise ValueError(f"only {clusters} clusters: FAT32 needs at least {MIN_CLUSTERS}")
    if clusters > MAX_CLUSTERS:
        raise ValueError("too many clusters")
    when = when or time.localtime()[:6]
    if volume_id is None:
        volume_id = (_pack_date(when) << 16 | _pack_time(when)) ^ int.from_bytes(os.urandom(4), "little")
    lab = (label or "NO NAME").upper()
    if len(lab) > 11 or any(not c.isascii() or (c not in SHORT_OK and c != " ") for c in lab):
        raise ValueError(f"bad volume label {label!r} (up to 11 of A-Z 0-9 space {''.join(sorted(SHORT_SPECIAL))})")
    lab11 = lab.ljust(11).encode("ascii")

    boot = bytearray(SECTOR)
    boot[0:3] = b"\xEB\x58\x90"
    boot[3:11] = b"MSWIN4.1"
    struct.pack_into("<HBHBHHBHHHII", boot, 11, SECTOR, spc, reserved, nfats, 0, 0, 0xF8, 0,
                     32, 64, 0, total)
    struct.pack_into("<IHHIHH", boot, 36, fatsz, 0, 0, 2, 1, 6)
    boot[64] = 0x80                         # BS_DrvNum
    boot[66] = 0x29                         # BS_BootSig: the next three fields are present
    struct.pack_into("<I", boot, 67, volume_id & 0xFFFFFFFF)
    boot[71:82] = lab11
    boot[82:90] = b"FAT32   "
    boot[90:92] = b"\xCD\x18"               # not bootable: int 18h
    boot[510:512] = b"\x55\xAA"

    fsinfo = bytearray(SECTOR)
    struct.pack_into("<I", fsinfo, 0, LEAD_SIG)
    struct.pack_into("<III", fsinfo, 484, STRUC_SIG, clusters - 1, 3)
    struct.pack_into("<I", fsinfo, 508, TRAIL_SIG)

    fat0 = bytearray(SECTOR)
    struct.pack_into("<III", fat0, 0, 0x0FFFFF00 | 0xF8, EOC, EOC)   # media, clean+no-error EOC, root

    root = bytearray(spc * SECTOR)
    if label:
        root[0:32] = short_entry(lab11, ATTR_VOLUME_ID, 0, 0, when)

    with open(path, "wb") as f:
        f.truncate(total * SECTOR)          # sparse zeros everywhere else
        for sec, data in ((0, boot), (1, fsinfo), (6, boot), (7, fsinfo),
                          (reserved, fat0), (reserved + fatsz, fat0),
                          (reserved + nfats * fatsz, root)):
            f.seek(sec * SECTOR)
            f.write(data)


# ---------------------------------------------------------------- volume

class _Dir:
    __slots__ = ("cluster", "chain", "raw", "recs")


class Volume:
    """An open FAT32 image. Mutating calls write through and sync before
    returning; use as a context manager or call close()."""

    def __init__(self, path, readonly=False, when=None):
        self.path = path
        self.readonly = readonly
        self.when = when
        self._f = open(path, "rb" if readonly else "r+b")
        try:
            self._load()
        except BaseException:
            self._f.close()
            raise

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def close(self):
        if self._f.closed:
            return
        try:
            if not self.readonly:
                self.sync()
        finally:
            self._f.close()

    # ---- raw I/O

    def _pread(self, off, n):
        self._f.seek(off)
        data = self._f.read(n)
        if len(data) != n:
            raise FATError("corrupt", f"short read at offset {off}")
        return data

    def _pwrite(self, off, data):
        if self.readonly:
            raise FATError("readOnly")
        self._f.seek(off)
        self._f.write(data)

    def _load(self):
        size = os.fstat(self._f.fileno()).st_size
        if size < SECTOR:
            raise FATError("notFAT32", "image smaller than one sector")
        b = parse_bpb(self._pread(0, SECTOR))
        problems, fatal = bpb_problems(b, size)
        if fatal or b.sig != 0xAA55:
            raise FATError("notFAT32", problems[0])
        self.bpb = b
        self.spc = b.spc
        self.cluster_size = b.spc * SECTOR
        self.first_data = b.reserved + b.nfats * b.fatsz
        self.total_clusters = (b.tot32 - self.first_data) // b.spc
        self.root_cluster = b.root_cluster
        self.volume_id = b.vol_id
        self.fat = array.array("I")
        self.fat.frombytes(self._pread(b.reserved * SECTOR, b.fatsz * SECTOR))
        if sys.byteorder == "big":
            self.fat.byteswap()
        self._dirty = set()
        fsi = self._pread(b.fsinfo * SECTOR, SECTOR) if 0 < b.fsinfo < b.reserved else bytes(SECTOR)
        hint = struct.unpack_from("<I", fsi, 492)[0]
        self._next = hint if 2 <= hint < self.total_clusters + 2 else 2
        n = self.total_clusters
        fat = self.fat
        self.free_clusters = sum(1 for c in range(2, n + 2) if fat[c] & MASK == FREE)
        self._fsinfo_dirty = True
        lab = [r for r in self._read_dir(self.root_cluster).recs if r.kind == "label"]
        self.label = lab[0].name if lab else b.vol_label.decode("cp437").rstrip()

    def _now(self):
        return self.when or time.localtime()[:6]

    # ---- FAT

    def _get(self, c):
        return self.fat[c] & MASK

    def _set(self, c, v):
        self.fat[c] = (self.fat[c] & ~MASK & 0xFFFFFFFF) | v
        self._dirty.add(c // (SECTOR // 4))

    def _flush_fat(self):
        b = self.bpb
        per = SECTOR // 4
        for s in sorted(self._dirty):
            chunk = self.fat[s * per:(s + 1) * per]
            if sys.byteorder == "big":
                chunk.byteswap()
            data = chunk.tobytes()
            for i in range(b.nfats):
                self._pwrite((b.reserved + i * b.fatsz + s) * SECTOR, data)
        self._dirty.clear()

    def _valid(self, c):
        return 2 <= c < self.total_clusters + 2

    def chain(self, start):
        """Cluster numbers of the chain starting at `start` ([] for 0)."""
        if start == 0:
            return []
        out, seen, c = [], set(), start
        while True:
            if not self._valid(c):
                raise FATError("corrupt", f"cluster {c} out of range")
            if c in seen:
                raise FATError("corrupt", f"cluster chain loop at {c}")
            seen.add(c)
            out.append(c)
            v = self._get(c)
            if v >= EOC_MIN:
                return out
            if v in (FREE, BAD) or not self._valid(v):
                raise FATError("corrupt", f"cluster {c} links to {v:#x}")
            c = v

    def _alloc(self, count):
        if count == 0:
            return []
        if count > self.free_clusters:
            raise FATError("noSpace")
        n = self.total_clusters
        out, c = [], self._next
        for _ in range(n):
            if self.fat[c] & MASK == FREE:
                out.append(c)
                if len(out) == count:
                    break
            c = c + 1 if c + 1 < n + 2 else 2
        if len(out) < count:
            raise FATError("noSpace")
        for a, b2 in zip(out, out[1:]):
            self._set(a, b2)
        self._set(out[-1], EOC)
        self.free_clusters -= count
        self._next = out[-1] + 1 if out[-1] + 1 < n + 2 else 2
        self._fsinfo_dirty = True
        return out

    def _free(self, chain):
        for c in chain:
            self._set(c, FREE)
        self.free_clusters += len(chain)
        self._fsinfo_dirty = True

    def _offset(self, c):
        return (self.first_data + (c - 2) * self.spc) * SECTOR

    def _runs(self, chain):
        """Group a chain into (first cluster, count) runs of adjacent clusters."""
        runs = []
        for c in chain:
            if runs and runs[-1][0] + runs[-1][1] == c:
                runs[-1][1] += 1
            else:
                runs.append([c, 1])
        return runs

    def _read_chain(self, chain):
        return b"".join(self._pread(self._offset(c), n * self.cluster_size) for c, n in self._runs(chain))

    def _write_chain(self, chain, data):
        cs = self.cluster_size
        data = bytes(data) + bytes(len(chain) * cs - len(data))
        pos = 0
        for c, n in self._runs(chain):
            self._pwrite(self._offset(c), data[pos:pos + n * cs])
            pos += n * cs

    # ---- directories

    def _read_dir(self, cluster):
        d = _Dir()
        d.cluster = cluster
        d.chain = self.chain(cluster)
        d.raw = bytearray(self._read_chain(d.chain))
        d.recs = parse_dir(d.raw)
        return d

    def _slot_offset(self, d, i):
        per = self.cluster_size // 32
        return self._offset(d.chain[i // per]) + (i % per) * 32

    def _write_slot(self, d, i, data):
        d.raw[i * 32:i * 32 + 32] = data
        self._pwrite(self._slot_offset(d, i), data)

    def _lookup(self, d, name):
        u = name.upper()
        for r in d.recs:
            if r.kind in ("file", "dir") and (r.name.upper() == u or r.short.upper() == u):
                return r
        return None

    def _dir_at(self, parts):
        d = self._read_dir(self.root_cluster)
        for i, p in enumerate(parts):
            r = self._lookup(d, p)
            if r is None:
                raise FATError("notFound", _join(parts[:i + 1]))
            if r.kind != "dir":
                raise FATError("notADirectory", _join(parts[:i + 1]))
            if r.cluster == 0:
                raise FATError("corrupt", f"{_join(parts[:i + 1])}: directory has no cluster")
            d = self._read_dir(r.cluster)
        return d

    def _parent(self, path):
        parts = _split(path)
        if not parts:
            return None, None, parts
        return self._dir_at(parts[:-1]), parts[-1], parts

    def _add(self, d, name, attr, cluster, size):
        """Write LFN + short entries for `name` into directory `d`, growing
        it if needed. Returns the short entry's slot."""
        check_long_name(name)
        taken = {r.name11 for r in d.recs}
        n11, ntres, needs_lfn = short_name_for(name, taken)
        when = self._now()
        slots = (lfn_slots(name, lfn_checksum(n11)) if needs_lfn else [])
        slots.append(short_entry(n11, attr, cluster, size, when, ntres))
        need = len(slots)
        start = self._find_free(d, need)
        if start is None:
            nslots = len(d.raw) // 32
            tail = 0
            while tail < nslots and d.raw[(nslots - tail - 1) * 32] in (0x00, 0xE5):
                tail += 1
            per = self.cluster_size // 32
            grow = -(-(need - tail) // per)
            if nslots + grow * per > MAX_DIR_ENTRIES:
                raise FATError("noSpace", "directory full")
            new = self._alloc(grow)
            self._write_chain(new, b"")
            self._set(d.chain[-1], new[0])
            self._flush_fat()
            d.chain += new
            d.raw += bytes(grow * self.cluster_size)
            start = self._find_free(d, need)
        for k, s in enumerate(slots):
            self._write_slot(d, start + k, s)
        d.recs = parse_dir(d.raw)
        return start + need - 1

    @staticmethod
    def _find_free(d, need):
        run = 0
        for i in range(len(d.raw) // 32):
            b0 = d.raw[i * 32]
            if b0 == 0x00:
                # everything from the end marker on is free
                return i - run if (len(d.raw) // 32 - i + run) >= need else None
            if b0 == 0xE5:
                run += 1
                if run == need:
                    return i - need + 1
            else:
                run = 0
        return None

    def _delete(self, d, r):
        for i in range(r.first, r.slot + 1):
            e = bytearray(d.raw[i * 32:i * 32 + 32])
            e[0] = 0xE5
            self._write_slot(d, i, bytes(e))
        d.recs = parse_dir(d.raw)

    # ---- public API

    def stat(self, path):
        d, name, parts = self._parent(path)
        if d is None:
            return Entry("/", True, 0, "", self.root_cluster)
        r = self._lookup(d, name)
        if r is None:
            raise FATError("notFound", _join(parts))
        return r.entry()

    def exists(self, path):
        try:
            self.stat(path)
            return True
        except FATError as e:
            if e.code in ("notFound", "notADirectory"):
                return False
            raise

    def list(self, path="/"):
        d = self._dir_at(_split(path))
        return [r.entry() for r in d.recs if r.kind in ("file", "dir")]

    def read(self, path):
        e = self.stat(path)
        if e.is_dir:
            raise FATError("isADirectory", _join(_split(path)))
        chain = self.chain(e.cluster)
        if len(chain) * self.cluster_size < e.size:
            raise FATError("corrupt", f"{_join(_split(path))}: chain shorter than file size")
        need = -(-e.size // self.cluster_size)
        return self._read_chain(chain[:need])[:e.size]

    def write(self, path, data):
        """Create or replace a file. New data goes into new clusters, then
        the entry is pointed at them, then the old chain is freed."""
        data = bytes(data)
        d, name, parts = self._parent(path)
        if d is None:
            raise FATError("isADirectory", "/")
        check_long_name(name)
        old = self._lookup(d, name)
        if old is not None and old.kind == "dir":
            raise FATError("isADirectory", _join(parts))
        old_chain = self.chain(old.cluster) if old is not None else []
        new = self._alloc(-(-len(data) // self.cluster_size))
        try:
            self._write_chain(new, data)
            self._flush_fat()
            first = new[0] if new else 0
            if old is None:
                self._add(d, name, ATTR_ARCHIVE, first, len(data))
            else:
                e = bytearray(d.raw[old.slot * 32:old.slot * 32 + 32])
                when = self._now()
                struct.pack_into("<H", e, 18, _pack_date(when))
                struct.pack_into("<HHHHI", e, 20, first >> 16, _pack_time(when), _pack_date(when),
                                 first & 0xFFFF, len(data))
                e[11] |= ATTR_ARCHIVE
                self._write_slot(d, old.slot, bytes(e))
        except BaseException:
            self._free(new)
            self._flush_fat()
            raise
        self._free(old_chain)
        self.sync()

    def mkdir(self, path):
        d, name, parts = self._parent(path)
        if d is None:
            raise FATError("exists", "/")
        check_long_name(name)
        if self._lookup(d, name) is not None:
            raise FATError("exists", _join(parts))
        new = self._alloc(1)
        try:
            when = self._now()
            parent = 0 if d.cluster == self.root_cluster else d.cluster
            body = (short_entry(b".          ", ATTR_DIRECTORY, new[0], 0, when) +
                    short_entry(b"..         ", ATTR_DIRECTORY, parent, 0, when))
            self._write_chain(new, body)
            self._flush_fat()
            self._add(d, name, ATTR_DIRECTORY, new[0], 0)
        except BaseException:
            self._free(new)
            self._flush_fat()
            raise
        self.sync()

    def remove(self, path, recursive=False):
        """Remove a file or an empty directory (any directory if recursive)."""
        d, name, parts = self._parent(path)
        if d is None:
            raise FATError("isADirectory", "/")
        r = self._lookup(d, name)
        if r is None:
            raise FATError("notFound", _join(parts))
        if r.kind == "dir":
            sub = self._read_dir(r.cluster)
            kids = [k for k in sub.recs if k.kind in ("file", "dir")]
            if kids and not recursive:
                raise FATError("notEmpty", _join(parts))
            for k in kids:
                self.remove(parts + [k.name], recursive=True)
            d = self._dir_at(parts[:-1])
            r = self._lookup(d, name)
        chain = self.chain(r.cluster)
        self._delete(d, r)
        self._free(chain)
        self.sync()

    def walk(self, path="/"):
        """Yield (path, Entry) for everything below `path`, depth first."""
        base = _split(path)
        for e in self.list(base):
            p = base + [e.name]
            yield _join(p), e
            if e.is_dir:
                yield from self.walk(p)

    def tree(self):
        """{path: bytes for files, None for directories} for the whole volume."""
        return {p: (None if e.is_dir else self.read(p)) for p, e in self.walk()}

    def sync(self):
        if self.readonly:
            return
        self._flush_fat()
        if self._fsinfo_dirty and 0 < self.bpb.fsinfo < self.bpb.reserved:
            fsi = bytearray(self._pread(self.bpb.fsinfo * SECTOR, SECTOR))
            if struct.unpack_from("<I", fsi, 0)[0] == LEAD_SIG:
                struct.pack_into("<II", fsi, 488, self.free_clusters, self._next)
                self._pwrite(self.bpb.fsinfo * SECTOR, bytes(fsi))
            self._fsinfo_dirty = False
        self._f.flush()

    def check(self):
        self.sync()
        return fsck(self.path)


# ---------------------------------------------------------------- fsck

def fsck(path):
    """Check an image; returns a list of problems ([] when clean)."""
    p = []
    with open(path, "rb") as f:
        size = os.fstat(f.fileno()).st_size

        def rd(sector, count=1):
            f.seek(sector * SECTOR)
            return f.read(count * SECTOR).ljust(count * SECTOR, b"\0")

        if size < SECTOR:
            return ["image is smaller than one sector"]
        s0 = rd(0)
        b = parse_bpb(s0)
        bp, fatal = bpb_problems(b, size)
        p += bp
        if fatal:
            return p
        if b.boot_sig != 0x29:
            p.append(f"extended boot signature is {b.boot_sig:#04x}, not 0x29")
        if b.fs_type != b"FAT32   ":
            p.append(f"BS_FilSysType is {b.fs_type!r}, not 'FAT32   '")
        if b.backup not in (0, 0xFFFF) and b.backup + 1 < b.reserved:
            if rd(b.backup) != s0:
                p.append(f"backup boot sector (sector {b.backup}) differs from sector 0")
        fsi_free = None
        n = (b.tot32 - b.reserved - b.nfats * b.fatsz) // b.spc
        where = [(b.fsinfo, "FSInfo")]
        if b.backup not in (0, 0xFFFF):
            where.append((b.backup + b.fsinfo, "backup FSInfo"))
        for sec, which in where:
            if sec in (0, 0xFFFF) or sec >= b.reserved:
                continue
            fsi = rd(sec)
            lead, = struct.unpack_from("<I", fsi, 0)
            struc, free, nxt = struct.unpack_from("<III", fsi, 484)
            trail, = struct.unpack_from("<I", fsi, 508)
            if (lead, struc, trail) != (LEAD_SIG, STRUC_SIG, TRAIL_SIG):
                p.append(f"{which} (sector {sec}) has bad signatures")
            elif which == "FSInfo":
                fsi_free = free
                if nxt != 0xFFFFFFFF and not 2 <= nxt < n + 2:
                    p.append(f"FSInfo next-free hint {nxt} is out of range")

        cs = b.spc * SECTOR
        first_data = b.reserved + b.nfats * b.fatsz
        fats = [rd(b.reserved + i * b.fatsz, b.fatsz) for i in range(b.nfats)]
        fat = array.array("I")
        fat.frombytes(fats[0])
        if sys.byteorder == "big":
            fat.byteswap()
        for i in range(1, b.nfats):
            if fats[i] != fats[0]:
                other = array.array("I")
                other.frombytes(fats[i])
                diff = [c for c in range(n + 2) if fat[c] != other[c]]
                if diff:
                    p.append(f"FAT copies differ: FAT {i + 1} differs from FAT 1 in {len(diff)} "
                             f"entries (first: cluster {diff[0]})")
                else:
                    p.append(f"FAT copies differ: FAT {i + 1} differs from FAT 1 past the last cluster")
        if fat[0] & 0xFF != b.media or fat[0] & MASK | 0xFF != MASK:
            p.append(f"FAT[0] is {fat[0]:#010x}, expected media byte {b.media:#04x} in 0x0FFFFFxx")
        if (fat[1] | CLEAN_SHUTDOWN | HARD_ERROR) & MASK != EOC:
            p.append(f"FAT[1] is {fat[1]:#010x}, not an end-of-chain mark")
        else:
            if not fat[1] & CLEAN_SHUTDOWN:
                p.append("volume dirty bit set (FAT[1] clean-shutdown bit clear)")
            if not fat[1] & HARD_ERROR:
                p.append("FAT[1] hard-error bit clear (disk errors were seen)")

        owner = {}

        def walk_chain(start, what):
            """Follow a chain, claiming its clusters; report problems."""
            out = []
            if not 2 <= start < n + 2:
                p.append(f"{what}: first cluster {start} out of range")
                return out
            c = start
            local = set()
            while True:
                if c in local:
                    p.append(f"{what}: cluster chain loop at cluster {c}")
                    return out
                if c in owner:
                    p.append(f"{what}: cross-linked with {owner[c]} at cluster {c}")
                    return out
                local.add(c)
                owner[c] = what
                out.append(c)
                v = fat[c] & MASK
                if v >= EOC_MIN:
                    return out
                if v == FREE:
                    p.append(f"{what}: chain runs into free cluster at {c}")
                    return out
                if v == BAD:
                    p.append(f"{what}: chain contains bad cluster mark at {c}")
                    return out
                if not 2 <= v < n + 2:
                    p.append(f"{what}: cluster {c} links to out-of-range {v:#x}")
                    return out
                c = v

        def read_chain(chain):
            return b"".join(rd(first_data + (c - 2) * b.spc, b.spc) for c in chain)

        files = dirs = 0
        stack = [("/", b.root_cluster, None)]        # (path, cluster, parent cluster or None for root)
        root_chain = walk_chain(b.root_cluster, "/")
        chains = {b.root_cluster: root_chain}
        labels = 0
        while stack:
            dpath, dcl, parent = stack.pop()
            chain = chains[dcl]
            raw = read_chain(chain)
            recs = parse_dir(raw, p, dpath)
            names, shorts = set(), set()
            for idx, r in enumerate(recs):
                if r.kind == "label":
                    if parent is not None:
                        p.append(f"{dpath}: volume label entry in a subdirectory")
                    labels += 1
                    continue
                if r.kind == "dot":
                    want = (dcl if r.name == "." else (0 if parent == b.root_cluster else parent))
                    if parent is None:
                        p.append(f"{dpath}: root directory has a {r.name!r} entry")
                    elif r.slot != (0 if r.name == "." else 1):
                        p.append(f"{dpath}: {r.name!r} entry at slot {r.slot}, expected slot "
                                 f"{0 if r.name == '.' else 1}")
                    elif not r.attr & ATTR_DIRECTORY:
                        p.append(f"{dpath}: {r.name!r} entry is not a directory")
                    elif r.cluster != want:
                        p.append(f"{dpath}: {r.name!r} points to cluster {r.cluster}, expected {want}")
                    continue
                full = dpath.rstrip("/") + "/" + r.name
                bad = [c for c in r.name11.decode("cp437")
                       if c != " " and not (c in SHORT_OK or ord(c) > 127)]
                if bad or r.name11[0] == 0x20:
                    p.append(f"{full}: invalid short name {r.name11!r}")
                if r.name.upper() in names:
                    p.append(f"{full}: duplicate name in {dpath}")
                if r.name11 in shorts:
                    p.append(f"{full}: duplicate short name {r.short!r} in {dpath}")
                names.add(r.name.upper())
                shorts.add(r.name11)
                if r.kind == "dir":
                    dirs += 1
                    if r.size != 0:
                        p.append(f"{full}: directory has nonzero size {r.size}")
                    if r.cluster == 0:
                        p.append(f"{full}: directory has no cluster")
                        continue
                    if r.cluster in owner:
                        p.append(f"{full}: cross-linked with {owner[r.cluster]} at cluster {r.cluster}")
                        continue
                    ch = walk_chain(r.cluster, full)
                    if ch:
                        chains[r.cluster] = ch
                        sub = parse_dir(read_chain(ch[:1]))
                        dots = [s for s in sub if s.kind == "dot"]
                        if len(dots) < 2 or dots[0].slot != 0 or dots[1].slot != 1:
                            p.append(f"{full}: missing '.' and '..' entries")
                        stack.append((full, r.cluster, dcl))
                else:
                    files += 1
                    if r.cluster == 0:
                        if r.size:
                            p.append(f"{full}: size {r.size} but no clusters")
                        continue
                    ch = walk_chain(r.cluster, full)
                    want = -(-r.size // cs)
                    if ch and len(ch) != want:
                        p.append(f"{full}: size {r.size} needs {want} clusters, chain has {len(ch)}")
        if labels > 1:
            p.append(f"/: {labels} volume label entries")

        lost = [c for c in range(2, n + 2) if fat[c] & MASK not in (FREE, BAD) and c not in owner]
        if lost:
            shown = ", ".join(map(str, lost[:8])) + (", ..." if len(lost) > 8 else "")
            p.append(f"{len(lost)} lost clusters (allocated but unreferenced): {shown}")
        free = sum(1 for c in range(2, n + 2) if fat[c] & MASK == FREE)
        if fsi_free is not None and fsi_free != 0xFFFFFFFF and fsi_free != free:
            p.append(f"FSInfo free count {fsi_free} is wrong: {free} clusters are free")
    return p


# ---------------------------------------------------------------- conveniences

def read_file(img, path):
    with Volume(img, readonly=True) as v:
        return v.read(path)


def write_file(img, path, data, when=None):
    with Volume(img, when=when) as v:
        v.write(path, data)


def list_dir(img, path="/"):
    with Volume(img, readonly=True) as v:
        return v.list(path)


# ---------------------------------------------------------------- fixture

def _fixture_big():
    return bytes((i * 7 + i // 512) & 0xFF for i in range(5000))


FIXTURE_SIZE = 33 * MiB
FIXTURE_LABEL = "WIFFERFIX"
FIXTURE_VOLUME_ID = 0x20260101
FIXTURE_TREE = {
    "/README.TXT": b"Wiffer FAT32 fixture\n",
    "/hello.txt": b"hello, world\n",
    "/Mixed Case Name.md": b"# Mixed\n",
    "/A Very Long File Name That Goes Past Thirteen Characters.txt": b"long\n",
    "/longfilename1.txt": b"one\n",
    "/longfilename2.txt": b"two\n",
    "/a+b=c.txt": b"lossy\n",
    "/empty.txt": b"",
    "/docs": None,
    "/docs/big.bin": _fixture_big(),
    "/docs/Notes": None,
    "/docs/Notes/deep": None,
    "/docs/Notes/deep/leaf.txt": b"leaf\n",
}


def build_fixture(path):
    """Write the fixture image to `path`. Its contents are FIXTURE_TREE.

    Fixture image (tests/fixtures/fat32-lfn.img.gz, sparse form fat32-lfn.sparse):
    33 MiB superfloppy FAT32, 512-byte clusters (66,504 clusters), label
    WIFFERFIX, volume id 0x20260101, every timestamp 2026-01-01 00:00:00.
    Root directory listing, in on-disk order (short name in brackets):

      README.TXT            21  [README.TXT]   plain 8.3, no LFN
      hello.txt             13  [HELLO.TXT]    no LFN, NT lowercase bits 0x18
      Mixed Case Name.md     8  [MIXEDC~1.MD]  2 LFN entries
      A Very Long File Name That Goes Past Thirteen Characters.txt
                             5  [AVERYL~1.TXT] 5 LFN entries
      longfilename1.txt      4  [LONGFI~1.TXT] "one\\n"
      longfilename2.txt      4  [LONGFI~2.TXT] "two\\n" (~2 tail)
      a+b=c.txt              6  [A_B_C~1.TXT]  lossy chars become '_'
      empty.txt              0  [EMPTY.TXT]    cluster 0, lowercase bits
      docs/                     [DOCS]         lowercase bits 0x08
        big.bin           5000  [BIG.BIN]      10 clusters; byte i is
                                               (7*i + i//512) & 0xFF
        Notes/                  [NOTES]        mixed case: 1 LFN entry
          deep/                 [DEEP]
            leaf.txt         5  [LEAF.TXT]     "leaf\\n"

    plus a deleted (0xE5) LFN+short run for "deleted file.txt" between
    longfilename2.txt and a+b=c.txt, and the volume label entry first in root.
    The root directory spans clusters 2 and 9; the LONGFI~2 run crosses them.
    Regenerate the committed copies with
    `tests/fat32.py fixture IMG --gzip tests/fixtures/fat32-lfn.img.gz
    --sparse tests/fixtures/fat32-lfn.sparse`.
    """
    mkfs(path, FIXTURE_SIZE, FIXTURE_LABEL, FIXTURE_VOLUME_ID, DEFAULT_WHEN)
    with Volume(path, when=DEFAULT_WHEN) as v:
        for p, data in FIXTURE_TREE.items():
            if p == "/a+b=c.txt":
                v.write("/deleted file.txt", b"gone\n")
            if data is None:
                v.mkdir(p)
            else:
                v.write(p, data)
        v.remove("/deleted file.txt")


FIXTURE_DOC = build_fixture.__doc__

SPARSE_MAGIC = b"FATSPRS1"


def write_sparse(img, out):
    """Write `img` in a trivial sparse form the kernel can load without
    decompression: magic "FATSPRS1", u32 total sectors, u32 extent count,
    then per extent u32 first LBA, u32 sector count and the sectors' bytes
    (all little-endian). Only non-zero sectors are stored."""
    extents = []
    with open(img, "rb") as f:
        total = os.fstat(f.fileno()).st_size // SECTOR
        zero = bytes(SECTOR)
        lba = 0
        while lba < total:
            chunk = f.read(SECTOR * 2048)
            for k in range(len(chunk) // SECTOR):
                s = chunk[k * SECTOR:(k + 1) * SECTOR]
                if s != zero:
                    if extents and extents[-1][0] + len(extents[-1][1]) // SECTOR == lba + k:
                        extents[-1][1].extend(s)
                    else:
                        extents.append([lba + k, bytearray(s)])
            lba += len(chunk) // SECTOR
    with open(out, "wb") as o:
        o.write(SPARSE_MAGIC + struct.pack("<II", total, len(extents)))
        for first, data in extents:
            o.write(struct.pack("<II", first, len(data) // SECTOR))
            o.write(data)


def read_sparse(src, img):
    """Expand a sparse file written by write_sparse into image `img`."""
    with open(src, "rb") as s, open(img, "wb") as o:
        if s.read(8) != SPARSE_MAGIC:
            raise ValueError("not a FATSPRS1 file")
        total, count = struct.unpack("<II", s.read(8))
        o.truncate(total * SECTOR)
        for _ in range(count):
            first, n = struct.unpack("<II", s.read(8))
            o.seek(first * SECTOR)
            o.write(s.read(n * SECTOR))


def write_gzip(img, out):
    """gzip `img` reproducibly (mtime 0, no file name)."""
    with open(img, "rb") as f, open(out, "wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, compresslevel=9, mtime=0) as g:
            while chunk := f.read(1 << 20):
                g.write(chunk)


# ---------------------------------------------------------------- CLI

def _cli(argv=None):
    ap = argparse.ArgumentParser(prog="fat32.py", description="FAT32 image tool")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("mkfs", help="create a FAT32 image")
    s.add_argument("img")
    s.add_argument("--size", default="64M")
    s.add_argument("--label", default="WIFFER")
    s = sub.add_parser("ls", help="list a directory")
    s.add_argument("img")
    s.add_argument("path", nargs="?", default="/")
    s.add_argument("-R", action="store_true", help="recursive")
    s = sub.add_parser("cat", help="write a file's bytes to stdout")
    s.add_argument("img")
    s.add_argument("path")
    s = sub.add_parser("put", help="copy a host file in (create or replace)")
    s.add_argument("img")
    s.add_argument("hostfile")
    s.add_argument("path")
    s = sub.add_parser("mkdir", help="make a directory")
    s.add_argument("img")
    s.add_argument("path")
    s = sub.add_parser("rm", help="remove a file or empty directory")
    s.add_argument("img")
    s.add_argument("path")
    s.add_argument("-r", action="store_true", help="remove directories recursively")
    s = sub.add_parser("fsck", help="check an image")
    s.add_argument("img")
    s = sub.add_parser("info", help="show volume geometry")
    s.add_argument("img")
    s = sub.add_parser("fixture", help="build the kernel selftest fixture")
    s.add_argument("img")
    s.add_argument("--gzip", metavar="OUT")
    s.add_argument("--sparse", metavar="OUT")
    a = ap.parse_args(argv)

    if a.cmd == "mkfs":
        mkfs(a.img, parse_size(a.size), a.label)
    elif a.cmd == "ls":
        with Volume(a.img, readonly=True) as v:
            items = (v.walk(a.path) if a.R else
                     ((e.name, e) for e in v.list(a.path)))
            for name, e in items:
                size = "" if e.is_dir else str(e.size)
                print(f"{size:>10}  {name}{'/' if e.is_dir else ''}")
    elif a.cmd == "cat":
        with Volume(a.img, readonly=True) as v:
            data = v.read(a.path)
        sys.stdout.buffer.write(data)
    elif a.cmd == "put":
        if a.hostfile == "-":
            data = sys.stdin.buffer.read()
        else:
            with open(a.hostfile, "rb") as f:
                data = f.read()
        with Volume(a.img) as v:
            target = a.path
            if a.path.endswith("/") or (_split(a.path) and v.exists(a.path) and v.stat(a.path).is_dir):
                target = a.path.rstrip("/") + "/" + os.path.basename(a.hostfile)
            v.write(target, data)
    elif a.cmd == "mkdir":
        with Volume(a.img) as v:
            v.mkdir(a.path)
    elif a.cmd == "rm":
        with Volume(a.img) as v:
            v.remove(a.path, recursive=a.r)
    elif a.cmd == "fsck":
        problems = fsck(a.img)
        for x in problems:
            print(x)
        if problems:
            return 1
        with Volume(a.img, readonly=True) as v:
            n = sum(1 for _ in v.walk())
            print(f"{a.img}: clean, {n} files and directories, "
                  f"{v.free_clusters}/{v.total_clusters} clusters free")
    elif a.cmd == "info":
        with Volume(a.img, readonly=True) as v:
            b = v.bpb
            print(f"label {v.label!r}  id {v.volume_id:08X}")
            print(f"{b.tot32} sectors, {b.spc} sectors/cluster ({v.cluster_size} bytes), "
                  f"{b.reserved} reserved, {b.nfats} FATs of {b.fatsz} sectors")
            print(f"{v.total_clusters} clusters, {v.free_clusters} free, root at cluster {v.root_cluster}")
    elif a.cmd == "fixture":
        build_fixture(a.img)
        if a.gzip:
            write_gzip(a.img, a.gzip)
        if a.sparse:
            write_sparse(a.img, a.sparse)
    return 0


def main(argv=None):
    try:
        return _cli(argv)
    except FATError as e:
        print(f"fat32.py: {e}", file=sys.stderr)
        return 1
    except (ValueError, OSError) as e:
        print(f"fat32.py: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
