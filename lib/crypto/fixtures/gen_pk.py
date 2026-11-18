#!/usr/bin/env python3
# Regenerates the public-key fixtures with Python `cryptography` (OpenSSL):
#   python3 -I lib/crypto/fixtures/gen_pk.py lib/crypto/fixtures
# Keys are random, so the files change on every run; the tests only need
# them to be self-consistent.
#
# ecdsa.txt   curve hash pubkey(04||X||Y) message der-signature
# ecdh.txt    curve private peer-public shared-x own-public
# rsa.txt     scheme hash salt-len n e message signature
# x25519.txt  private peer-public shared own-public
import os, sys
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa, padding, x25519

out = sys.argv[1]
H = {"sha256": hashes.SHA256(), "sha384": hashes.SHA384(), "sha512": hashes.SHA512()}
CURVES = {"p256": ec.SECP256R1(), "p384": ec.SECP384R1()}

def pub(k):
    return k.public_key().public_bytes(serialization.Encoding.X962,
                                       serialization.PublicFormat.UncompressedPoint).hex()

lines = ["# curve hash pubkey message der-signature (Python cryptography)"]
for cname, curve in CURVES.items():
    for hname in H:
        for i in range(6):
            k = ec.generate_private_key(curve)
            msg = os.urandom(i * 17)
            sig = k.sign(msg, ec.ECDSA(H[hname]))
            lines.append(" ".join([cname, hname, pub(k), msg.hex() or "-", sig.hex()]))
    # Degenerate keys: Q = G, 2G and -G (so G + Q is doubling or infinity
    # inside the verifier's double-scalar multiplication).
    order = {"p256": 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551,
             "p384": 0xffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973}[cname]
    for d in (1, 2, order - 1):
        k = ec.derive_private_key(d, curve)
        msg = os.urandom(20)
        sig = k.sign(msg, ec.ECDSA(hashes.SHA256()))
        lines.append(" ".join([cname, "sha256", pub(k), msg.hex(), sig.hex()]))
open(os.path.join(out, "ecdsa.txt"), "w").write("\n".join(lines) + "\n")

lines = ["# curve private peer-public shared-x own-public (Python cryptography)"]
for cname, curve in CURVES.items():
    for i in range(8):
        a = ec.generate_private_key(curve)
        b = ec.generate_private_key(curve)
        size = 32 if cname == "p256" else 48
        d = a.private_numbers().private_value.to_bytes(size, "big")
        lines.append(" ".join([cname, d.hex(), pub(b), a.exchange(ec.ECDH(), b.public_key()).hex(), pub(a)]))
open(os.path.join(out, "ecdh.txt"), "w").write("\n".join(lines) + "\n")

lines = ["# x25519: private peer-public shared own-public (Python cryptography)"]
raw = (serialization.Encoding.Raw, serialization.PublicFormat.Raw)
for i in range(16):
    a = x25519.X25519PrivateKey.generate()
    b = x25519.X25519PrivateKey.generate()
    ab = a.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
                         serialization.NoEncryption())
    lines.append(" ".join([ab.hex(), b.public_key().public_bytes(*raw).hex(),
                           a.exchange(b.public_key()).hex(), a.public_key().public_bytes(*raw).hex()]))
open(os.path.join(out, "x25519.txt"), "w").write("\n".join(lines) + "\n")

lines = ["# scheme hash salt-len n e message signature (Python cryptography)"]
for bits, e in ((1024, 65537), (2048, 65537), (2049, 65537), (2048, 3), (3072, 65537), (4095, 65537), (4096, 65537)):
    k = rsa.generate_private_key(public_exponent=e, key_size=bits)
    n = k.public_key().public_numbers().n
    nhex = n.to_bytes((n.bit_length() + 7) // 8, "big").hex()
    ehex = e.to_bytes((e.bit_length() + 7) // 8, "big").hex()
    for hname in H:
        msg = os.urandom(bits // 64)
        sig = k.sign(msg, padding.PKCS1v15(), H[hname])
        lines.append(" ".join(["pkcs1", hname, "0", nhex, ehex, msg.hex(), sig.hex()]))
        salts = [H[hname].digest_size] + ([0, 20] if bits == 2048 and e == 65537 else [])
        for s in salts:
            if bits == 1024 and hname == "sha512":
                continue  # emLen too small for a 64-byte salt
            sig = k.sign(msg, padding.PSS(mgf=padding.MGF1(H[hname]), salt_length=s), H[hname])
            lines.append(" ".join(["pss", hname, str(s), nhex, ehex, msg.hex(), sig.hex()]))
open(os.path.join(out, "rsa.txt"), "w").write("\n".join(lines) + "\n")
