#!/usr/bin/env python3
"""sbtool — BL808 soft secure-boot tooling.

Subcommands:
  keygen    generate a dev ECDSA-P256 key + pubinfo (SOFT DEV KEY)
  sign      wrap a raw binary in a signed (optionally encrypted) NSB1 image
  verify    verify an NSB1 image against a public key
  gen-efuse emit the eFuse provisioning a production burn WOULD apply (DRY-RUN)
  selftest  end-to-end host self-test (no hardware)

Reversible mode: nothing here ever touches a device or burns eFuses.
"""
from __future__ import annotations
import argparse
import json
import hashlib
import sys
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

sys.path.insert(0, str(Path(__file__).resolve().parent))
import container as C  # noqa: E402


def cmd_keygen(args):
    priv = ec.generate_private_key(ec.SECP256R1())
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    label = args.label
    (out / f"{label}.p256.pem").write_bytes(priv.private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption()))
    pub = priv.public_key()
    (out / f"{label}.pub.pem").write_bytes(pub.public_bytes(
        serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo))
    xy = C.pubkey_xy(pub)
    info = {
        "label": label, "curve": "secp256r1",
        "pub_x": xy[:32].hex(), "pub_y": xy[32:].hex(),
        "pubkey_sha256": hashlib.sha256(xy).hexdigest(),
        "pubkey_id": f"0x{C.pubkey_id(pub):08x}",
        "WARNING": "SOFT DEV KEY — NOT FOR PRODUCTION",
    }
    (out / f"{label}.pubinfo.json").write_text(json.dumps(info, indent=2))
    print(f"wrote {label}.p256.pem / .pub.pem / .pubinfo.json  (pubkey_id {info['pubkey_id']})")


def cmd_sign(args):
    priv = serialization.load_pem_private_key(Path(args.key).read_bytes(), password=None)
    payload = Path(args.infile).read_bytes()
    aes_key = Path(args.aes_key).read_bytes() if args.aes_key else None
    nonce = bytes.fromhex(args.nonce) if args.nonce else b"\x00" * 16
    img = C.build_nsb1(payload=payload, img_type=args.type, sec_version=args.secver,
                       load_addr=int(args.load, 0), entry=int(args.entry, 0),
                       priv=priv, aes_key=aes_key, nonce=nonce)
    Path(args.out).write_bytes(img)
    print(f"signed {args.type} image: {len(img)} bytes -> {args.out}"
          + (" [encrypted]" if aes_key else ""))


def cmd_verify(args):
    pub = serialization.load_pem_public_key(Path(args.key).read_bytes())
    aes_key = Path(args.aes_key).read_bytes() if args.aes_key else None
    ok, reason = C.verify_nsb1(Path(args.infile).read_bytes(), pub, aes_key)
    print(f"verify: {'OK' if ok else 'FAIL'} ({reason})")
    sys.exit(0 if ok else 1)


# --- ef_data_0 bit layout (mirrors src/bl808/efuse.nim, byte-for-byte) -------
EF_WORD_CFG0 = 0x00 // 4          # 0
EF_WORD_SW_USAGE0 = 0x5C // 4     # 23
EF_WORD_LOCK = 0x7C // 4          # 31
EF_CFG_SF_AES_SHIFT = 0
EF_CFG_SBOOT_EN_SHIFT = 4
EF_CFG_SE_DBG_DIS = 22
EF_CFG_JTAG1_DIS_MASK = 0x3 << 24
EF_CFG_JTAG0_DIS_MASK = 0x3 << 26
EF_CFG_DBG_MODE_SHIFT = 28
EF_SW_SBOOT_SIGN_SHIFT = 8
EF_LOCK_WR_KEYSLOT0 = 17          # slots 1..3 at +1
EF_LOCK_RD_KEYSLOT0 = 27          # slots 1..3 at +1


def compute_provision_plan(spec: dict) -> dict[int, int]:
    """Pure port of efuse.computeProvisionPlan: spec -> {word: or_mask}.

    spec keys: enable_secure_boot(bool), sign_mode(0|1|2), sf_aes_mode(0..3),
    disable_jtag(bool), disable_se_dbg(bool), lock_read(set[0..3]),
    lock_write(set[0..3]).
    """
    plan: dict[int, int] = {}

    def add(word: int, or_mask: int):
        if or_mask:
            plan[word] = plan.get(word, 0) | or_mask

    cfg0 = 0
    if spec.get("enable_secure_boot"):
        cfg0 |= 1 << EF_CFG_SBOOT_EN_SHIFT
    cfg0 |= (spec.get("sf_aes_mode", 0) & 0x3) << EF_CFG_SF_AES_SHIFT
    if spec.get("disable_se_dbg"):
        cfg0 |= 1 << EF_CFG_SE_DBG_DIS
    if spec.get("disable_jtag"):
        cfg0 |= EF_CFG_JTAG0_DIS_MASK | EF_CFG_JTAG1_DIS_MASK
        cfg0 |= 4 << EF_CFG_DBG_MODE_SHIFT
    add(EF_WORD_CFG0, cfg0)

    if spec.get("sign_mode", 0):
        add(EF_WORD_SW_USAGE0, spec["sign_mode"] << EF_SW_SBOOT_SIGN_SHIFT)

    lock = 0
    for s in spec.get("lock_read", ()):
        lock |= 1 << (EF_LOCK_RD_KEYSLOT0 + s)
    for s in spec.get("lock_write", ()):
        lock |= 1 << (EF_LOCK_WR_KEYSLOT0 + s)
    add(EF_WORD_LOCK, lock)
    return plan


def cmd_gen_efuse(args):
    pub = serialization.load_pem_public_key(Path(args.key).read_bytes())
    pk_hash = hashlib.sha256(C.pubkey_xy(pub)).digest()
    spec = {
        "enable_secure_boot": True,
        "sign_mode": 2,                       # ECC-secp256r1
        "sf_aes_mode": 0,
        "disable_jtag": bool(args.disable_jtag),
        "disable_se_dbg": bool(args.disable_se_dbg),
        "lock_read": set(range(4)) if args.lock_key_slots else set(),
        "lock_write": set(range(4)) if args.lock_key_slots else set(),
    }
    packed = compute_provision_plan(spec)
    # DevCube-style 128-word ef_data_0 image + write mask.
    n_words = 128
    data = bytearray(n_words * 4)
    mask = bytearray(n_words * 4)
    for word, or_mask in packed.items():
        data[word * 4:word * 4 + 4] = or_mask.to_bytes(4, "little")
        mask[word * 4:word * 4 + 4] = (0xFFFFFFFF if or_mask else 0).to_bytes(4, "little")
    out = Path(args.out)
    out.write_text(json.dumps({
        "applied": False,
        "NOTE": "DRY-RUN — REVERSIBLE MODE — NEVER BURNED",
        "spec": {k: (sorted(v) if isinstance(v, set) else v) for k, v in spec.items()},
        "packed_writes": [{"word": w, "or_mask": f"0x{packed[w]:08x}"}
                          for w in sorted(packed)],
        "pubkey_sha256": pk_hash.hex(),
        "pubkey_id": f"0x{C.pubkey_id(pub):08x}",
    }, indent=2))
    if args.emit_bin:
        Path(args.emit_bin + "data.bin").write_bytes(data)
        Path(args.emit_bin + "mask.bin").write_bytes(mask)
    print(f"wrote DRY-RUN efuse provisioning descriptor -> {out} (applied=false)")


def cmd_selftest(args):
    import tempfile, os
    with tempfile.TemporaryDirectory() as d:
        priv = ec.generate_private_key(ec.SECP256R1())
        other = ec.generate_private_key(ec.SECP256R1())
        payload = b"hello secure boot" * 16
        img = C.build_nsb1(payload=payload, img_type="m0app", sec_version=1,
                           load_addr=0, entry=0x58000000, priv=priv)
        ok, _ = C.verify_nsb1(img, priv.public_key())
        assert ok, "valid image must verify"
        # tamper a payload byte
        bad = bytearray(img); bad[C.HEADER_SIZE + 4] ^= 0xFF
        ok, reason = C.verify_nsb1(bytes(bad), priv.public_key())
        assert not ok and reason == "payload hash", f"tamper not caught: {reason}"
        # wrong key
        ok, reason = C.verify_nsb1(img, other.public_key())
        assert not ok and reason == "signature", f"wrong key not caught: {reason}"
        # encrypted round-trip
        key = os.urandom(16)
        enc = C.build_nsb1(payload=payload, img_type="enclave", sec_version=2,
                           load_addr=0, entry=0, priv=priv, aes_key=key,
                           nonce=os.urandom(16))
        ok, _ = C.verify_nsb1(enc, priv.public_key(), key)
        assert ok, "encrypted image must verify with key"
        ok, _ = C.verify_nsb1(enc, priv.public_key())  # no key
        assert not ok, "encrypted image must fail without key"
    print("selftest: PASS (sign/verify, tamper-reject, wrong-key-reject, encrypt round-trip)")


def main():
    p = argparse.ArgumentParser(description="BL808 soft secure-boot tooling")
    sub = p.add_subparsers(dest="cmd", required=True)

    k = sub.add_parser("keygen"); k.add_argument("--out-dir", default="keys"); k.add_argument("--label", default="dev-root"); k.set_defaults(func=cmd_keygen)
    s = sub.add_parser("sign")
    s.add_argument("--type", required=True, choices=list(C.IMG_TYPES))
    s.add_argument("--key", required=True); s.add_argument("--in", dest="infile", required=True); s.add_argument("--out", required=True)
    s.add_argument("--secver", type=int, default=1); s.add_argument("--load", default="0"); s.add_argument("--entry", default="0x58000000")
    s.add_argument("--aes-key", default=None); s.add_argument("--nonce", default=None); s.set_defaults(func=cmd_sign)
    v = sub.add_parser("verify"); v.add_argument("--key", required=True); v.add_argument("--in", dest="infile", required=True); v.add_argument("--aes-key", default=None); v.set_defaults(func=cmd_verify)
    e = sub.add_parser("gen-efuse"); e.add_argument("--key", required=True); e.add_argument("--out", default="efuse_provision.json"); e.add_argument("--disable-jtag", action="store_true"); e.add_argument("--disable-se-dbg", action="store_true"); e.add_argument("--lock-key-slots", action="store_true"); e.add_argument("--emit-bin", default=None, help="prefix for DevCube efusedata.bin/efusemask.bin"); e.set_defaults(func=cmd_gen_efuse)
    t = sub.add_parser("selftest"); t.set_defaults(func=cmd_selftest)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
