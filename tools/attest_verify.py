#!/usr/bin/env python3
"""Independently verify a BL808 enclave attestation quote.

Reads the ATTEST pubkey/quote/nonce lines emitted by m0_attest_test from a UART
log (or stdin) and verifies the ECDSA-P256 signature with the `cryptography`
library, recomputing the signed digest = SHA-256(chip_id ‖ measurement ‖ nonce).

Usage:
  python3 tools/attest_verify.py < uart.log
  python3 tools/attest_verify.py path/to/uart.log
"""
from __future__ import annotations
import hashlib
import re
import sys

from cryptography.hazmat.primitives.asymmetric import ec, utils as au
from cryptography.hazmat.primitives import hashes


def grab(text: str, key: str) -> bytes:
    m = re.search(rf"ATTEST {key}=([0-9a-fA-F]+)", text)
    if not m:
        raise SystemExit(f"missing ATTEST {key}= line")
    return bytes.fromhex(m.group(1))


def main():
    text = open(sys.argv[1]).read() if len(sys.argv) > 1 else sys.stdin.read()
    pub = grab(text, "pubkey")     # x[32] || y[32]
    quote = grab(text, "quote")    # id[8] || meas[32] || sig r||s[64]
    nonce = grab(text, "nonce")    # 32

    assert len(pub) == 64, f"pubkey len {len(pub)}"
    assert len(quote) == 104, f"quote len {len(quote)}"
    assert len(nonce) == 32, f"nonce len {len(nonce)}"

    chip_id = quote[0:8]
    meas = quote[8:40]
    r = int.from_bytes(quote[40:72], "big")
    s = int.from_bytes(quote[72:104], "big")

    x = int.from_bytes(pub[0:32], "big")
    y = int.from_bytes(pub[32:64], "big")
    pubkey = ec.EllipticCurvePublicNumbers(x, y, ec.SECP256R1()).public_key()

    digest = hashlib.sha256(chip_id + meas + nonce).digest()
    der = au.encode_dss_signature(r, s)
    try:
        pubkey.verify(der, digest, ec.ECDSA(au.Prehashed(hashes.SHA256())))
        print("attestation: VERIFIED")
        print(f"  chip_id     = {chip_id.hex()}")
        print(f"  measurement = {meas.hex()}")
        print(f"  pubkey x    = {pub[:32].hex()}")
        print("==> the device produced a valid ECDSA-P256 attestation over "
              "(chip_id || measurement || nonce).")
    except Exception as e:
        print(f"attestation: FAILED ({e})")
        sys.exit(1)


if __name__ == "__main__":
    main()
