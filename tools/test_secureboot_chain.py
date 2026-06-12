#!/usr/bin/env python3
"""Host validation of the secure-boot CHAIN test's inputs and expected outcomes.

Parses the exact image bytes the device firmware embeds (examples/sb_chain_vector.nim)
and independently reproduces every decision the device-side securestage logic makes,
so the on-silicon assertions are confirmed correct without hardware:
  - the three genuine images verify against the root pubkey;
  - a tampered payload and a wrong-key image are rejected;
  - the downgraded image verifies cryptographically but is below the rollback floor;
  - the combined boot measurement equals the value the firmware asserts.

The device runs the same checks with the BL808 PKA/SHA (already silicon-proven by
m0_secureboot_verify_test); this pins down that it will see the right answers.
"""
from __future__ import annotations
import hashlib
import re
import sys
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric import ec

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools" / "secureboot"))
import container as C  # noqa: E402

VEC = ROOT / "examples" / "sb_chain_vector.nim"
FLOOR = 1  # device floor: secver >= 1 per image type


def parse_byte_array(text: str, name: str) -> bytes:
    m = re.search(rf"const {name}\*: array\[\d+, uint8\] = \[(.*?)\]", text, re.S)
    if not m:
        raise SystemExit(f"missing {name} in {VEC}")
    return bytes(int(x, 16) for x in re.findall(r"0x([0-9A-Fa-f]{2})'u8", m.group(1)))


def main():
    root = ec.derive_private_key(0x1111_2222_3333_4444, ec.SECP256R1())
    text = VEC.read_text()
    imgs = {n: parse_byte_array(text, n)
            for n in ("GoodM0", "GoodD0", "GoodEnc", "WrongKey", "OldVer")}
    expected_meas = parse_byte_array(text, "ExpectedMeasurement")

    pub = root.public_key()
    fails = 0

    def check(label, ok):
        nonlocal fails
        print(f"[{'PASS' if ok else 'FAIL'}] {label}")
        if not ok:
            fails += 1

    # 1. genuine set verifies against the root key
    for n in ("GoodM0", "GoodD0", "GoodEnc"):
        ok, reason = C.verify_nsb1(imgs[n], pub)
        check(f"{n} verifies against root key", ok and reason == "ok")

    # 2. rollback floor: genuine images carry secver >= floor; OldVer is below it
    for n in ("GoodM0", "GoodD0", "GoodEnc"):
        h = C.parse_nsb1(imgs[n])
        check(f"{n} secver {h.sec_version} meets floor {FLOOR}", h.sec_version >= FLOOR)
    old = C.parse_nsb1(imgs["OldVer"])
    ok, _ = C.verify_nsb1(imgs["OldVer"], pub)
    check("OldVer is cryptographically valid but below floor (rollback reject)",
          ok and old.sec_version < FLOOR)

    # 3. tampered payload rejected (bad hash)
    bad = bytearray(imgs["GoodM0"]); bad[C.HEADER_SIZE + 2] ^= 0xFF
    ok, reason = C.verify_nsb1(bytes(bad), pub)
    check("tampered payload rejected", (not ok) and reason == "payload hash")

    # 4. wrong-key image rejected (bad signature)
    ok, reason = C.verify_nsb1(imgs["WrongKey"], pub)
    check("wrong-key image rejected", (not ok) and reason == "signature")

    # 5. combined measurement = SHA-256(h_m0 || h_d0 || h_enc), as the device asserts
    combined = hashlib.sha256(
        imgs["GoodM0"][32:64] + imgs["GoodD0"][32:64] + imgs["GoodEnc"][32:64]
    ).digest()
    check("combined boot measurement matches firmware's expected value",
          combined == expected_meas)
    print(f"      combined measurement = {combined.hex()}")

    print("PASS" if fails == 0 else f"FAIL ({fails})")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
