#!/usr/bin/env python3
"""Generate a multi-image secure-boot CHAIN test vector (Nim include).

Emits examples/sb_chain_vector.nim with a full image set the device-side
securestage logic walks end-to-end:
  - three genuine images (m0app, d0, enclave) signed by the root key,
  - one image signed by a DIFFERENT key (wrong-key reject),
  - one genuine-but-downgraded image (secver below the floor -> rollback reject),
  - the root pubkey in PKA word layout, and
  - the expected combined boot measurement (SHA-256 over the accepted images'
    payload hashes) so the device can assert it byte-for-byte.

Deterministic (fixed seed keys) so the vector is reproducible. Reversible mode:
touches no device and burns nothing.
"""
from __future__ import annotations
import hashlib
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import serialization

import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
import container as C  # noqa: E402

OUT = Path(__file__).resolve().parents[2] / "examples" / "sb_chain_vector.nim"


def det_key(seed: int) -> ec.EllipticCurvePrivateKey:
    # Deterministic P-256 key from a fixed scalar so the vector is reproducible.
    return ec.derive_private_key(seed, ec.SECP256R1())


def pka_words(be32: bytes) -> list[int]:
    # 32-byte big-endian value -> 8 PKA words: word order big-endian (word0=MSW),
    # bytes little-endian within each word. Matches verify.nim bytesToWordsBe.
    return [int.from_bytes(be32[w * 4:w * 4 + 4], "little") for w in range(8)]


def words_literal(name: str, words: list[int]) -> str:
    body = ", ".join(f"0x{w:08X}'u32" for w in words)
    return f"const {name}*: array[8, uint32] = [{body}]\n"


def bytes_literal(name: str, data: bytes) -> str:
    elems = ", ".join(f"0x{b:02X}'u8" for b in data)
    return (f"const {name}Len* = {len(data)}\n"
            f"const {name}*: array[{len(data)}, uint8] = [{elems}]\n")


def main():
    root = det_key(0x1111_2222_3333_4444)
    other = det_key(0x5555_6666_7777_8888)
    rpub = root.public_key()
    xy = C.pubkey_xy(rpub)

    # Genuine set: distinct payloads, secver=2, meet a floor of 1.
    imgs = {
        "GoodM0":   C.build_nsb1(payload=b"m0-app-payload\x01" * 4, img_type="m0app",
                                 sec_version=2, load_addr=0, entry=0x58000000, priv=root),
        "GoodD0":   C.build_nsb1(payload=b"d0-payload\x02" * 5, img_type="d0",
                                 sec_version=2, load_addr=0, entry=0x3EFF0000, priv=root),
        "GoodEnc":  C.build_nsb1(payload=b"enclave-payload\x03" * 3, img_type="enclave",
                                 sec_version=2, load_addr=0, entry=0, priv=root),
        "GoodLp":   C.build_nsb1(payload=b"lp-payload\x06" * 4, img_type="lp",
                                 sec_version=2, load_addr=0, entry=0x58080000, priv=root),
        # Same logical m0 image but signed by the wrong key.
        "WrongKey": C.build_nsb1(payload=b"m0-app-payload\x01" * 4, img_type="m0app",
                                 sec_version=2, load_addr=0, entry=0x58000000, priv=other),
        # Genuine signature by root, but secver 0 < floor 1 -> downgrade.
        "OldVer":   C.build_nsb1(payload=b"m0-old\x04" * 8, img_type="m0app",
                                 sec_version=0, load_addr=0, entry=0x58000000, priv=root),
    }

    # Expected combined measurement = SHA-256(h_m0 || h_d0 || h_enc), the order the
    # device accepts them. Each h is the plaintext payload hash (header[32:64]).
    combined = hashlib.sha256(
        imgs["GoodM0"][32:64] + imgs["GoodD0"][32:64] + imgs["GoodEnc"][32:64]
    ).digest()

    # Encrypted image (AES-128-CTR payload) for the E test: a fixed key + nonce
    # so the device can decrypt and check the plaintext hash.
    enc_key = bytes(range(0x10, 0x20))          # 16-byte AES key
    enc_nonce = bytes(range(0x20, 0x30))        # 16-byte CTR nonce
    enc_plain = b"encrypted-m0-payload\x07" * 3
    enc_img = C.build_nsb1(payload=enc_plain, img_type="m0app", sec_version=2,
                           load_addr=0, entry=0x58000000, priv=root,
                           aes_key=enc_key, nonce=enc_nonce)

    lines = ["## AUTO-GENERATED secure-boot chain vector (gen_chain_vector.py). Do not edit.\n"]
    lines.append(words_literal("RootPubX", pka_words(xy[:32])))
    lines.append(words_literal("RootPubY", pka_words(xy[32:])))
    for name, img in imgs.items():
        lines.append(bytes_literal(name, img))
    lines.append(bytes_literal("ExpectedMeasurement", combined))
    lines.append(bytes_literal("EncImg", enc_img))
    lines.append(bytes_literal("EncKey", enc_key))
    lines.append(bytes_literal("EncPlain", enc_plain))
    OUT.write_text("".join(lines))
    print(f"wrote {OUT} ({len(imgs)} images, root pubkey_id 0x{C.pubkey_id(rpub):08x})")


if __name__ == "__main__":
    main()
