#!/usr/bin/env python3
"""Host tests for the NSB1 secure-boot container + sbtool.

Run: python3 tools/test_sbtool_container.py
Covers: sign/verify round-trip, tamper rejection, wrong-key rejection,
encrypted round-trip, and header field round-trip through parse_nsb1.
"""
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "secureboot"))
import container as C  # noqa: E402
from cryptography.hazmat.primitives.asymmetric import ec  # noqa: E402


def test_roundtrip_and_fields():
    priv = ec.generate_private_key(ec.SECP256R1())
    payload = b"firmware-payload" * 8
    img = C.build_nsb1(payload=payload, img_type="enclave", sec_version=9,
                       load_addr=0x1234, entry=0x58000100, priv=priv)
    h = C.parse_nsb1(img)
    assert h.img_type == 4 and h.sec_version == 9
    assert h.load_addr == 0x1234 and h.entry == 0x58000100
    assert h.payload_len == len(payload)
    ok, reason = C.verify_nsb1(img, priv.public_key())
    assert ok, reason


def test_tamper_rejected():
    priv = ec.generate_private_key(ec.SECP256R1())
    img = bytearray(C.build_nsb1(payload=b"x" * 64, img_type="m0app",
                                 sec_version=1, load_addr=0, entry=0, priv=priv))
    img[C.HEADER_SIZE + 1] ^= 0xFF
    ok, reason = C.verify_nsb1(bytes(img), priv.public_key())
    assert not ok and reason == "payload hash", reason


def test_wrong_key_rejected():
    priv = ec.generate_private_key(ec.SECP256R1())
    other = ec.generate_private_key(ec.SECP256R1())
    img = C.build_nsb1(payload=b"y" * 64, img_type="m0app", sec_version=1,
                       load_addr=0, entry=0, priv=priv)
    ok, reason = C.verify_nsb1(img, other.public_key())
    assert not ok and reason == "signature", reason


def test_encrypted_roundtrip():
    priv = ec.generate_private_key(ec.SECP256R1())
    key = os.urandom(16)
    nonce = os.urandom(16)
    img = C.build_nsb1(payload=b"z" * 96, img_type="enclave", sec_version=3,
                       load_addr=0, entry=0, priv=priv, aes_key=key, nonce=nonce)
    ok, _ = C.verify_nsb1(img, priv.public_key(), key)
    assert ok
    ok, _ = C.verify_nsb1(img, priv.public_key())
    assert not ok, "must fail without key"


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
            print(f"PASS {name}")
    print("all NSB1 container tests passed")
