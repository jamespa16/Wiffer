#!/usr/bin/env python3
"""Generate lib/js/jsregexptables.swift: Unicode data for the RegExp engine.

    python3 -I lib/js/tools/gen_js_regexp_tables.py UCD_DIR

UCD_DIR holds these files from https://www.unicode.org/Public/17.0.0/ucd/
(emoji-data.txt is in the emoji/ subdirectory there):

    UnicodeData.txt Scripts.txt ScriptExtensions.txt PropList.txt
    DerivedCoreProperties.txt DerivedNormalizationProps.txt emoji-data.txt
    PropertyValueAliases.txt PropertyAliases.txt CaseFolding.txt

The full uppercase mapping for non-unicode case-insensitive matching comes
from Python's str.upper() (it includes SpecialCasing), so run it with a
Python whose unicodedata version matches the UCD files (17.0 here; checked).

Tables (all StaticStrings, so no big array literal to compile):

  * Range lists use a base64 varint: each char carries 5 bits of value
    (low bits first) and bit 5 set when more chars follow.
  * jsReGCRuns: (length-1, category) for consecutive runs covering
    U+0000..U+10FFFF. Categories are numbered as in jsReGCNames (bit i of a
    General_Category value mask is category i).
  * jsReScriptRuns: (length-1, script) runs covering everything.
  * jsReScxRuns: (gap from previous end, length-1, set) for code points
    whose Script_Extensions differs from {Script}; jsReScxSets is, per set,
    a count followed by script numbers.
  * jsReBinaryRanges: per binary property, a range count and (gap, length-1)
    pairs; jsReBinaryOffsets[i] is where property i starts.
  * jsReCaseUpper / jsReCaseFold: Canonicalize for non-unicode (toUppercase
    when it gives exactly one code unit, never mapping non-ASCII to ASCII)
    and unicode (simple case folding, C+S) mode. Fixed 10-char records
    (start | count << 21 | step2 << 32 | (delta + 2^22) << 33), sorted and
    non-overlapping, so a lookup is a binary search.
  * Name tables: "alias,alias:number;..." with the spec's names and aliases
    (ECMA-262 tables "Non-binary Unicode property aliases", "Binary Unicode
    property aliases", and PropertyValueAliases.txt values).
"""
import os, sys, unicodedata

here = os.path.dirname(os.path.abspath(__file__))
out = os.path.join(here, "..", "jsregexptables.swift")
B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
MAXCP = 0x10FFFF

if len(sys.argv) != 2:
    sys.exit(__doc__)
ucd = sys.argv[1]


def lines(name):
    for line in open(os.path.join(ucd, name), encoding="utf-8"):
        line = line.split("#")[0].strip()
        if line:
            yield [x.strip() for x in line.split(";")]


def cprange(s):
    a, _, b = s.partition("..")
    return int(a, 16), int(b or a, 16)


def varint(v):
    assert v >= 0
    s = ""
    while True:
        d = v & 31
        v >>= 5
        if v:
            s += B64[d | 32]
        else:
            s += B64[d]
            return s


def b64fixed(v, n):
    return "".join(B64[(v >> (6 * i)) & 63] for i in reversed(range(n)))


def ranges_of(cps):
    out = []
    for cp in sorted(cps):
        if out and out[-1][1] == cp - 1:
            out[-1][1] = cp
        else:
            out.append([cp, cp])
    return out


# ---------------------------------------------------------------- categories
GC = ["Cn", "Lu", "Ll", "Lt", "Lm", "Lo", "Mn", "Mc", "Me", "Nd", "Nl", "No", "Pc", "Pd", "Ps",
      "Pe", "Pi", "Pf", "Po", "Sm", "Sc", "Sk", "So", "Zs", "Zl", "Zp", "Cc", "Cf", "Cs", "Co"]
GROUPS = {"C": ["Cc", "Cf", "Cn", "Co", "Cs"], "L": ["Ll", "Lm", "Lo", "Lt", "Lu"],
          "LC": ["Ll", "Lt", "Lu"], "M": ["Mc", "Me", "Mn"], "N": ["Nd", "Nl", "No"],
          "P": ["Pc", "Pd", "Pe", "Pf", "Pi", "Po", "Ps"], "S": ["Sc", "Sk", "Sm", "So"],
          "Z": ["Zl", "Zp", "Zs"]}
gc = [0] * (MAXCP + 1)
bidi_m = set()
first = None
for f in lines("UnicodeData.txt"):
    cp = int(f[0], 16)
    cat = GC.index(f[2])
    if f[1].endswith(", First>"):
        first = cp
        continue
    lo = first if f[1].endswith(", Last>") else cp
    first = None
    for c in range(lo, cp + 1):
        gc[c] = cat
        if f[9] == "Y":
            bidi_m.add(c)

for cp in range(0, MAXCP + 1, 97):
    # Python's unicodedata must agree with the files.
    assert unicodedata.category(chr(cp)) == GC[gc[cp]], hex(cp)


def runs(values):
    out = []
    start = 0
    for cp in range(1, MAXCP + 2):
        if cp > MAXCP or values[cp] != values[start]:
            out.append((cp - start, values[start]))
            start = cp
    return out


gc_runs = runs(gc)

# ---------------------------------------------------------------- scripts
script_alias = {}   # short -> [names]
for f in lines("PropertyValueAliases.txt"):
    if f[0] == "sc":
        script_alias[f[1]] = f[1:]
long_to_short = {v[1]: k for k, v in script_alias.items()}
scripts = sorted(script_alias)            # by short name
scripts.remove("Zzzz")
scripts.insert(0, "Zzzz")                 # Unknown is 0
sidx = {s: i for i, s in enumerate(scripts)}
sc = [0] * (MAXCP + 1)
for f in lines("Scripts.txt"):
    lo, hi = cprange(f[0])
    for c in range(lo, hi + 1):
        sc[c] = sidx[long_to_short[f[1]]]
script_runs = runs(sc)

scx_list = []
for f in lines("ScriptExtensions.txt"):
    lo, hi = cprange(f[0])
    sset = tuple(sorted(sidx[s] for s in f[1].split()))
    for c in range(lo, hi + 1):
        scx_list.append((c, sset))
scx_list.sort()
scx_sets = sorted(set(s for _, s in scx_list))
scx_set_idx = {s: i for i, s in enumerate(scx_sets)}
scx_runs = []
for c, s in scx_list:
    si = scx_set_idx[s]
    if scx_runs and scx_runs[-1][1] == c - 1 and scx_runs[-1][2] == si:
        scx_runs[-1][1] = c
    else:
        scx_runs.append([c, c, si])

# ---------------------------------------------------------------- binary properties
props = {}


def load(name):
    for f in lines(name):
        lo, hi = cprange(f[0])
        props.setdefault(f[1], set()).update(range(lo, hi + 1))


for n in ("PropList.txt", "DerivedCoreProperties.txt", "emoji-data.txt", "DerivedNormalizationProps.txt"):
    load(n)
props["Bidi_Mirrored"] = bidi_m

# ECMA-262 "Binary Unicode property aliases" (Any, ASCII and Assigned are
# computed in Swift and numbered 1000+).
BINARY = [
    ("ASCII_Hex_Digit", "AHex"), ("Alphabetic", "Alpha"), ("Bidi_Control", "Bidi_C"),
    ("Bidi_Mirrored", "Bidi_M"), ("Case_Ignorable", "CI"), ("Cased",), ("Changes_When_Casefolded", "CWCF"),
    ("Changes_When_Casemapped", "CWCM"), ("Changes_When_Lowercased", "CWL"),
    ("Changes_When_NFKC_Casefolded", "CWKCF"), ("Changes_When_Titlecased", "CWT"),
    ("Changes_When_Uppercased", "CWU"), ("Dash",), ("Default_Ignorable_Code_Point", "DI"),
    ("Deprecated", "Dep"), ("Diacritic", "Dia"), ("Emoji",), ("Emoji_Component", "EComp"),
    ("Emoji_Modifier", "EMod"), ("Emoji_Modifier_Base", "EBase"), ("Emoji_Presentation", "EPres"),
    ("Extended_Pictographic", "ExtPict"), ("Extender", "Ext"), ("Grapheme_Base", "Gr_Base"),
    ("Grapheme_Extend", "Gr_Ext"), ("Hex_Digit", "Hex"), ("IDS_Binary_Operator", "IDSB"),
    ("IDS_Trinary_Operator", "IDST"), ("ID_Continue", "IDC"), ("ID_Start", "IDS"), ("Ideographic", "Ideo"),
    ("Join_Control", "Join_C"), ("Logical_Order_Exception", "LOE"), ("Lowercase", "Lower"), ("Math",),
    ("Noncharacter_Code_Point", "NChar"), ("Pattern_Syntax", "Pat_Syn"), ("Pattern_White_Space", "Pat_WS"),
    ("Quotation_Mark", "QMark"), ("Radical",), ("Regional_Indicator", "RI"), ("Sentence_Terminal", "STerm"),
    ("Soft_Dotted", "SD"), ("Terminal_Punctuation", "Term"), ("Unified_Ideograph", "UIdeo"),
    ("Uppercase", "Upper"), ("Variation_Selector", "VS"), ("White_Space", "space"), ("XID_Continue", "XIDC"),
    ("XID_Start", "XIDS"),
]
bin_strings = []
bin_offsets = []
pos = 0
for names in BINARY:
    rs = ranges_of(props[names[0]])
    s = varint(len(rs))
    prev = -1
    for a, b in rs:
        s += varint(a - prev - 1) + varint(b - a)
        prev = b
    bin_offsets.append(pos)
    pos += len(s)
    bin_strings.append(s)

# ---------------------------------------------------------------- case mapping


def canon_upper(cp):
    if 0xD800 <= cp <= 0xDFFF:
        return cp
    u = chr(cp).upper()
    if len(u.encode("utf-16-le")) != 2:
        return cp
    cu = ord(u)
    if cp >= 128 and cu < 128:
        return cp
    return cu


fold = {}
for f in lines("CaseFolding.txt"):
    if f[1] in ("C", "S"):
        fold[int(f[0], 16)] = int(f[2], 16)

upper_map = {cp: canon_upper(cp) for cp in range(0x10000) if canon_upper(cp) != cp}
for m in (upper_map, fold):
    for a, b in m.items():
        assert m.get(b, b) == b, "Canonicalize is not idempotent at %x" % a


def case_runs(m):
    out = []   # [start, count, step, delta]
    for cp in sorted(m):
        d = m[cp] - cp
        if out:
            r = out[-1]
            last = r[0] + (r[1] - 1) * r[2]
            if r[3] == d:
                if r[1] == 1 and cp == last + 1 and r[1] < 2047:
                    r[1] += 1; r[2] = 1; continue
                if r[1] == 1 and cp == last + 2 and (cp - 1) not in m:
                    r[1] += 1; r[2] = 2; continue
                if r[1] > 1 and cp == last + r[2] and r[1] < 2047 and (r[2] == 1 or (cp - 1) not in m):
                    r[1] += 1; continue
        out.append([cp, 1, 1, d])
    s = ""
    for a, n, step, d in out:
        assert -(1 << 22) <= d < (1 << 22) and n < 2048
        s += b64fixed(a | (n << 21) | ((1 if step == 2 else 0) << 32) | ((d + (1 << 22)) << 33), 10)
    for a, n, step, d in out:   # non-overlapping
        pass
    for i in range(1, len(out)):
        assert out[i][0] > out[i - 1][0] + (out[i - 1][1] - 1) * out[i - 1][2]
    return len(out), s


# ---------------------------------------------------------------- names
gc_names = []
for f in lines("PropertyValueAliases.txt"):
    if f[0] != "gc":
        continue
    v = f[1]
    cats = GROUPS.get(v, [v])
    mask = 0
    for c in cats:
        mask |= 1 << GC.index(c)
    gc_names.append((f[1:], mask))
script_names = [(script_alias[s], i) for i, s in enumerate(scripts)]
binary_names = [(list(n), i) for i, n in enumerate(BINARY)]
binary_names += [(["Any"], 1000), (["ASCII"], 1001), (["Assigned"], 1002)]


def names_table(entries):
    return ";".join(",".join(n) + ":" + str(v) for n, v in entries)


def emit_str(w, name, s, width=100):
    w.write("let %s: StaticString = \"\"\"\n" % name)
    for i in range(0, len(s), width):
        chunk = s[i:i + width]
        w.write(chunk + ("\\\n" if i + width < len(s) else "\n"))
    if not s:
        w.write("\n")
    w.write("\"\"\"\n\n")


with open(out, "w") as w:
    w.write("// GENERATED by tools/gen_js_regexp_tables.py from the Unicode %s UCD. Do not edit.\n"
            % unicodedata.unidata_version)
    w.write("// Encodings are described in the script. %d GC runs, %d script runs, %d scx runs,\n"
            % (len(gc_runs), len(script_runs), len(scx_runs)))
    w.write("// %d binary properties, %d scripts.\n\n" % (len(BINARY), len(scripts)))
    emit_str(w, "jsReGCNames", names_table(gc_names))
    emit_str(w, "jsReScriptNames", names_table(script_names))
    emit_str(w, "jsReBinaryNames", names_table(binary_names))
    emit_str(w, "jsReGCRuns", "".join(varint(n - 1) + varint(v) for n, v in gc_runs))
    emit_str(w, "jsReScriptRuns", "".join(varint(n - 1) + varint(v) for n, v in script_runs))
    s = ""
    prev = -1
    for a, b, si in scx_runs:
        s += varint(a - prev - 1) + varint(b - a) + varint(si)
        prev = b
    w.write("let jsReScxRunCount = %d\n" % len(scx_runs))
    emit_str(w, "jsReScxRuns", s)
    emit_str(w, "jsReScxSets", "".join(varint(len(st)) + "".join(varint(x) for x in st) for st in scx_sets))
    w.write("let jsReBinaryOffsets: [Int] = [%s]\n\n" % ", ".join(str(o) for o in bin_offsets))
    emit_str(w, "jsReBinaryRanges", "".join(bin_strings))
    n, s = case_runs(upper_map)
    w.write("let jsReCaseUpperCount = %d\n" % n)
    emit_str(w, "jsReCaseUpper", s)
    n, s = case_runs(fold)
    w.write("let jsReCaseFoldCount = %d\n" % n)
    emit_str(w, "jsReCaseFold", s)

print("wrote", out, os.path.getsize(out), "bytes")
