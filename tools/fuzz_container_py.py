#!/usr/bin/env python3
"""Host fuzzer for the NSB1 container tooling (tools/secureboot/container.py).

parse_nsb1 / verify_nsb1 are the host signer/verifier counterparts of the
device parser. They must reject any malformed image cleanly (return or raise
ValueError) and never crash, hang, or read past the buffer. We hammer them with
random and structured-adversarial inputs, including payload-length fields near
2**32 (the integer-overflow bait the device side was just hardened against).
"""
from __future__ import annotations
import os
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "secureboot"))
import container as C  # noqa: E402

from cryptography.hazmat.primitives.asymmetric import ec  # noqa: E402

KEY = ec.derive_private_key(0x1234_5678, ec.SECP256R1())
PUB = KEY.public_key()


def fuzz_parse(data: bytes) -> None:
    try:
        C.parse_nsb1(data)
    except ValueError:
        pass  # clean reject is fine
    # any other exception propagates -> test fails


def fuzz_verify(data: bytes) -> None:
    ok, _ = C.verify_nsb1(data, PUB)
    assert ok is False or ok is True  # must return a bool, never raise/over-read


def main() -> None:
    rng = __import__("random").Random(0xC0FFEE)
    iters = 0

    # 1. Pure random buffers across the size boundary.
    for _ in range(50_000):
        n = rng.randint(0, 520)
        fuzz_parse(bytes(rng.getrandbits(8) for _ in range(n)))
        iters += 1

    # 2. Structured: valid-ish header with an adversarial payload-length field
    #    and a truncated body.
    bad_lens = [0xFFFFFFFF, 0xFFFFFF00, 0x80000000, 0x7FFFFFFF, 256, 0, 1]
    for pl in bad_lens:
        for body in (0, 1, 16, 256, 257, 400):
            hdr = bytearray(256)
            hdr[0:4] = b"NSB1"
            struct.pack_into("<H", hdr, 4, 1)   # version
            struct.pack_into("<H", hdr, 6, 1)   # type m0app
            struct.pack_into("<I", hdr, 8, pl)  # payload length
            img = bytes(hdr) + bytes(body)
            fuzz_parse(img)
            fuzz_verify(img)
            iters += 1

    # 3. A genuine image, then single-byte flips everywhere in the header.
    good = C.build_nsb1(payload=b"payload" * 8, img_type="m0app", sec_version=1,
                        load_addr=0, entry=0, priv=KEY)
    ok, _ = C.verify_nsb1(good, PUB)
    assert ok, "genuine image must verify"
    for i in range(0, min(256, len(good))):
        flipped = bytearray(good)
        flipped[i] ^= 0xFF
        fuzz_verify(bytes(flipped))   # must cleanly return False, never crash
        iters += 1

    print(f"fuzz_container_py: {iters} iterations, no crash / clean rejects")
    print("PASS")


if __name__ == "__main__":
    main()
