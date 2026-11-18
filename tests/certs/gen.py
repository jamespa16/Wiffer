#!/usr/bin/env python3
"""Test PKI for lib/x509 and lib/tls (ROADMAP Phase 8A).

    python3 -I tests/certs/gen.py        (needs the `cryptography` package)

Writes into tests/certs/ (all committed; keys are test-only):
  <name>.der            every certificate, DER
  <name>.key.pem        private keys of the leaves openssl s_server serves
  <name>.chain.pem      leaf + intermediates, for openssl s_server -cert
  roots.der             the test trust store (concatenated DER, like
                        /etc/roots.der): root-rsa and root-ec

Good chains (valid 2025-01-01 .. 2035-01-01; tests use a fixed "now"):
  root-rsa (RSA-2048, self-signed sha256WithRSA)
    int-ec (P-256, sha384WithRSA, pathlen 0, EKU serverAuth)
      leaf-ec (P-256, ecdsa-with-SHA256): localhost, *.wiffer.test,
               127.0.0.1, ::1
  root-ec (P-384, self-signed ecdsa-with-SHA384)
    int-rsa (RSA-2048, ecdsa-with-SHA384)
      leaf-rsa (RSA-2048, RSASSA-PSS SHA-256 salt 32): same names
Bad ones, each with one problem:
  leaf-expired, leaf-notyet       dates (under int-ec)
  leaf-untrusted                  under rogue-root (not in roots.der)
  leaf-badsig                     leaf-ec with its signature corrupted
  leaf-via-nonca                  under int-nonca (basicConstraints cA false)
  leaf-via-nokeycertsign          under int-noks (keyUsage digitalSignature only)
  leaf-pathlen                    under int-sub, under int-ec (pathlen 0)
  leaf-clientauth                 EKU clientAuth only
  leaf-nc-evil                    evil.test under int-nc (permitted allowed.test)
  leaf-nc-ok                      ok.allowed.test under int-nc
"""
import datetime, ipaddress, os
from cryptography import x509
from cryptography.x509.oid import NameOID, ExtendedKeyUsageOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa, padding

HERE = os.path.dirname(os.path.abspath(__file__))
UTC = datetime.timezone.utc
NB = datetime.datetime(2025, 1, 1, tzinfo=UTC)
NA = datetime.datetime(2035, 1, 1, tzinfo=UTC)
NAMES = ["localhost", "*.wiffer.test"]
IPS = ["127.0.0.1", "::1"]

def name(cn):
    return x509.Name([x509.NameAttribute(NameOID.COUNTRY_NAME, "XX"),
                      x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Wiffer Test PKI"),
                      x509.NameAttribute(NameOID.COMMON_NAME, cn)])

def rsa_key():
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)

def cert(subject, key, issuer=None, issuer_key=None, ca=False, pathlen=None, names=None, ips=None,
         nb=NB, na=NA, eku=(ExtendedKeyUsageOID.SERVER_AUTH,), ku=None, hash_=hashes.SHA256(),
         pss=False, nc=None, serial=None):
    issuer = issuer or (subject, key)
    iname, ikey = issuer[0], issuer_key or issuer[1]
    b = (x509.CertificateBuilder().subject_name(name(subject)).issuer_name(name(iname))
         .public_key(key.public_key()).serial_number(serial or x509.random_serial_number())
         .not_valid_before(nb).not_valid_after(na))
    b = b.add_extension(x509.BasicConstraints(ca=ca, path_length=pathlen), critical=True)
    if ku is None:
        ku = "ca" if ca else "leaf"
    if ku == "ca":
        b = b.add_extension(x509.KeyUsage(False, False, False, False, False, True, True, False, False), critical=True)
    elif ku == "leaf":
        b = b.add_extension(x509.KeyUsage(True, False, False, False, False, False, False, False, False), critical=True)
    b = b.add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False)
    b = b.add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(ikey.public_key()), critical=False)
    if eku:
        b = b.add_extension(x509.ExtendedKeyUsage(list(eku)), critical=False)
    if names or ips:
        alt = [x509.DNSName(n) for n in (names or [])] + [x509.IPAddress(ipaddress.ip_address(i)) for i in (ips or [])]
        b = b.add_extension(x509.SubjectAlternativeName(alt), critical=False)
    if nc:
        b = b.add_extension(x509.NameConstraints(permitted_subtrees=[x509.DNSName(nc)], excluded_subtrees=None), critical=True)
    if isinstance(ikey, ec.EllipticCurvePrivateKey):
        return b.sign(ikey, hash_)
    if pss:
        return b.sign(ikey, hash_, rsa_padding=padding.PSS(mgf=padding.MGF1(hash_), salt_length=32))
    return b.sign(ikey, hash_)

def der(c):
    return c.public_bytes(serialization.Encoding.DER)

def pem(c):
    return c.public_bytes(serialization.Encoding.PEM)

def write(path, data):
    with open(os.path.join(HERE, path), "wb") as f:
        f.write(data)

def key_pem(k):
    return k.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())

def main():
    out = {}
    root_rsa_k = rsa_key()
    out["root-rsa"] = cert("Wiffer Test Root RSA", root_rsa_k, ca=True)
    root_ec_k = ec.generate_private_key(ec.SECP384R1())
    out["root-ec"] = cert("Wiffer Test Root EC", root_ec_k, ca=True, hash_=hashes.SHA384())
    RR = ("Wiffer Test Root RSA", root_rsa_k)
    RE = ("Wiffer Test Root EC", root_ec_k)

    int_ec_k = ec.generate_private_key(ec.SECP256R1())
    out["int-ec"] = cert("Wiffer Test Intermediate EC", int_ec_k, issuer=RR, ca=True, pathlen=0, hash_=hashes.SHA384())
    IE = ("Wiffer Test Intermediate EC", int_ec_k)
    int_rsa_k = rsa_key()
    out["int-rsa"] = cert("Wiffer Test Intermediate RSA", int_rsa_k, issuer=RE, ca=True, eku=None, hash_=hashes.SHA384())
    IR = ("Wiffer Test Intermediate RSA", int_rsa_k)

    leaf_ec_k = ec.generate_private_key(ec.SECP256R1())
    out["leaf-ec"] = cert("localhost", leaf_ec_k, issuer=IE, names=NAMES, ips=IPS)
    leaf_rsa_k = rsa_key()
    out["leaf-rsa"] = cert("localhost", leaf_rsa_k, issuer=IR, names=NAMES, ips=IPS, pss=True)
    write("leaf-ec.key.pem", key_pem(leaf_ec_k))
    write("leaf-rsa.key.pem", key_pem(leaf_rsa_k))

    k = ec.generate_private_key(ec.SECP256R1())
    out["leaf-expired"] = cert("localhost", k, issuer=IE, names=NAMES,
                               nb=datetime.datetime(2020, 1, 1, tzinfo=UTC), na=datetime.datetime(2021, 1, 1, tzinfo=UTC))
    out["leaf-notyet"] = cert("localhost", k, issuer=IE, names=NAMES,
                              nb=datetime.datetime(2040, 1, 1, tzinfo=UTC), na=datetime.datetime(2041, 1, 1, tzinfo=UTC))
    rogue_k = ec.generate_private_key(ec.SECP256R1())
    out["rogue-root"] = cert("Wiffer Test Root RSA", rogue_k, ca=True)   # same name as the real root
    out["leaf-untrusted"] = cert("localhost", k, issuer=("Wiffer Test Root RSA", rogue_k), names=NAMES)
    bad = bytearray(der(out["leaf-ec"]))
    bad[-1] ^= 0x01
    write("leaf-badsig.der", bytes(bad))

    nonca_k = ec.generate_private_key(ec.SECP256R1())
    out["int-nonca"] = cert("Wiffer Test Not A CA", nonca_k, issuer=RR, ca=False, ku="ca")
    out["leaf-via-nonca"] = cert("localhost", k, issuer=("Wiffer Test Not A CA", nonca_k), names=NAMES)
    noks_k = ec.generate_private_key(ec.SECP256R1())
    out["int-noks"] = cert("Wiffer Test No KeyCertSign", noks_k, issuer=RR, ca=True, ku="leaf")
    out["leaf-via-nokeycertsign"] = cert("localhost", k, issuer=("Wiffer Test No KeyCertSign", noks_k), names=NAMES)
    sub_k = ec.generate_private_key(ec.SECP256R1())
    out["int-sub"] = cert("Wiffer Test Sub Intermediate", sub_k, issuer=IE, ca=True)
    out["leaf-pathlen"] = cert("localhost", k, issuer=("Wiffer Test Sub Intermediate", sub_k), names=NAMES)
    out["leaf-clientauth"] = cert("localhost", k, issuer=IE, names=NAMES, eku=(ExtendedKeyUsageOID.CLIENT_AUTH,))
    nc_k = ec.generate_private_key(ec.SECP256R1())
    out["int-nc"] = cert("Wiffer Test Constrained", nc_k, issuer=RR, ca=True, nc="allowed.test")
    NC = ("Wiffer Test Constrained", nc_k)
    out["leaf-nc-evil"] = cert("evil.test", k, issuer=NC, names=["evil.test"])
    out["leaf-nc-ok"] = cert("ok.allowed.test", k, issuer=NC, names=["ok.allowed.test"])

    for n, c in out.items():
        write(n + ".der", der(c))
    write("leaf-ec.chain.pem", pem(out["leaf-ec"]) + pem(out["int-ec"]))
    write("leaf-rsa.chain.pem", pem(out["leaf-rsa"]) + pem(out["int-rsa"]))
    write("roots.der", der(out["root-rsa"]) + der(out["root-ec"]))
    print(f"wrote {len(out) + 1} certificates to {HERE}")

main()
