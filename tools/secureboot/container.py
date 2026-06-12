"""NSB1 secure-boot image container (host side).

Builds and verifies the same fixed 256-byte header that
src/bl808/secureboot/container.nim parses on the device. Little-endian; the
signed region is bytes [0, 160). Signature is raw ECDSA-P256 r||s (64 bytes).
"""
from __future__ import annotations
import struct
import hashlib
from dataclasses import dataclass

from cryptography.hazmat.primitives.asymmetric import ec, utils as asym_utils
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

HEADER_SIZE = 256
SIGNED_LEN = 160
MAGIC = b"NSB1"

IMG_TYPES = {"m0app": 1, "d0": 2, "lp": 3, "enclave": 4}
FLAG_ENCRYPTED = 0x1


def pubkey_xy(pub: ec.EllipticCurvePublicKey) -> bytes:
    nums = pub.public_numbers()
    return nums.x.to_bytes(32, "big") + nums.y.to_bytes(32, "big")


def pubkey_id(pub: ec.EllipticCurvePublicKey) -> int:
    digest = hashlib.sha256(pubkey_xy(pub)).digest()
    return struct.unpack("<I", digest[:4])[0]


def raw_sig_from_der(der: bytes) -> bytes:
    r, s = asym_utils.decode_dss_signature(der)
    return r.to_bytes(32, "big") + s.to_bytes(32, "big")


def der_from_raw_sig(raw: bytes) -> bytes:
    r = int.from_bytes(raw[:32], "big")
    s = int.from_bytes(raw[32:64], "big")
    return asym_utils.encode_dss_signature(r, s)


def aes_ctr(key: bytes, nonce: bytes, data: bytes) -> bytes:
    c = Cipher(algorithms.AES(key), modes.CTR(nonce))
    e = c.encryptor()
    return e.update(data) + e.finalize()


def build_nsb1(*, payload: bytes, img_type: str, sec_version: int,
               load_addr: int, entry: int,
               priv: ec.EllipticCurvePrivateKey,
               aes_key: bytes | None = None, nonce: bytes = b"\x00" * 16) -> bytes:
    """Construct a signed (optionally encrypted) NSB1 image: header || payload."""
    plain_hash = hashlib.sha256(payload).digest()
    flags = 0
    out_payload = payload
    if aes_key is not None:
        flags |= FLAG_ENCRYPTED
        out_payload = aes_ctr(aes_key, nonce, payload)

    pub = priv.public_key()
    hdr = bytearray(HEADER_SIZE)
    hdr[0:4] = MAGIC
    struct.pack_into("<H", hdr, 4, 1)                      # header version
    struct.pack_into("<H", hdr, 6, IMG_TYPES[img_type])
    struct.pack_into("<I", hdr, 8, len(payload))           # plaintext length
    struct.pack_into("<I", hdr, 12, load_addr)
    struct.pack_into("<I", hdr, 16, entry)
    struct.pack_into("<I", hdr, 20, sec_version)
    struct.pack_into("<I", hdr, 24, flags)
    struct.pack_into("<I", hdr, 28, pubkey_id(pub))
    hdr[32:64] = plain_hash
    hdr[64:80] = nonce

    # Sign SHA-256(header[0..159]).
    digest = hashlib.sha256(bytes(hdr[:SIGNED_LEN])).digest()
    der = priv.sign(digest, ec.ECDSA(asym_utils.Prehashed(hashes.SHA256())))
    hdr[160:224] = raw_sig_from_der(der)
    return bytes(hdr) + out_payload


@dataclass
class Nsb1Header:
    hdr_version: int
    img_type: int
    payload_len: int
    load_addr: int
    entry: int
    sec_version: int
    flags: int
    pubkey_id: int
    payload_hash: bytes
    nonce: bytes
    signature: bytes


def parse_nsb1(raw: bytes) -> Nsb1Header:
    if len(raw) < HEADER_SIZE:
        raise ValueError("short image")
    if raw[0:4] != MAGIC:
        raise ValueError("bad magic")
    (hv, it, pl, la, en, sv, fl, pid) = struct.unpack_from("<HHIIIIII", raw, 4)
    return Nsb1Header(hv, it, pl, la, en, sv, fl, pid,
                      raw[32:64], raw[64:80], raw[160:224])


def verify_nsb1(raw: bytes, pub: ec.EllipticCurvePublicKey,
                aes_key: bytes | None = None) -> tuple[bool, str]:
    """Verify signature + payload hash. Returns (ok, reason)."""
    try:
        h = parse_nsb1(raw)
    except ValueError as e:
        return False, str(e)
    # signature over header[0..159]
    digest = hashlib.sha256(raw[:SIGNED_LEN]).digest()
    try:
        pub.verify(der_from_raw_sig(h.signature), digest,
                   ec.ECDSA(asym_utils.Prehashed(hashes.SHA256())))
    except Exception:
        return False, "signature"
    payload = raw[HEADER_SIZE:HEADER_SIZE + h.payload_len]
    if h.flags & FLAG_ENCRYPTED:
        if aes_key is None:
            return False, "encrypted but no key"
        payload = aes_ctr(aes_key, h.nonce, payload)
    if hashlib.sha256(payload).digest() != h.payload_hash:
        return False, "payload hash"
    return True, "ok"
