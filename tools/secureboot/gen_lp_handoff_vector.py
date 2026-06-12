#!/usr/bin/env python3
"""Wrap the built LP RAM probe binary as a signed NSB1 image for the verified
LP handoff, emitting examples/lp_fw_vector.nim.

M0 embeds this image, verifies its signature + payload hash (real PKA), copies
the verified payload (the LP binary) into LP RAM at 0x22050000, and boots LP
there via releaseLPAt — a faithful secure handoff for the E902.

Signed with the same deterministic root key as gen_chain_vector.py, so the M0
test reuses RootPubX/RootPubY from sb_chain_vector.nim.
"""
from __future__ import annotations
import sys
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric import ec

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "secureboot"))
import container as C  # noqa: E402

LP_LOAD = 0x2205_0000
LP_BIN = ROOT / "build" / "lp_handoff_ram_probe.bin"
OUT = ROOT / "examples" / "lp_fw_vector.nim"


def bytes_literal(name: str, data: bytes) -> str:
    elems = ", ".join(f"0x{b:02X}'u8" for b in data)
    return (f"const {name}Len* = {len(data)}\n"
            f"const {name}*: array[{len(data)}, uint8] = [{elems}]\n")


def main() -> None:
    if not LP_BIN.exists():
        raise SystemExit(f"missing {LP_BIN}; build lp_handoff_ram_probe first")
    root = ec.derive_private_key(0x1111_2222_3333_4444, ec.SECP256R1())
    lp_bin = LP_BIN.read_bytes()
    img = C.build_nsb1(payload=lp_bin, img_type="lp", sec_version=2,
                       load_addr=LP_LOAD, entry=LP_LOAD, priv=root)
    lines = ["## AUTO-GENERATED LP handoff vector (gen_lp_handoff_vector.py). Do not edit.\n",
             f"const LpFwLoadAddr* = 0x{LP_LOAD:08X}'u\n",
             bytes_literal("LpFwImg", img)]
    OUT.write_text("".join(lines))
    print(f"wrote {OUT} (NSB1 {len(img)} bytes, LP payload {len(lp_bin)} bytes)")


if __name__ == "__main__":
    main()
