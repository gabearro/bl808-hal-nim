#!/usr/bin/env python3
"""Enroll SRAM-PUF helper data from a reference capture.

Code-offset repetition construction: for each of 256 key bits, pick r cell
indices in the 4 KB window and record offset[j] = golden_cell[j] XOR keyBit,
where keyBit is the golden majority of that group. On any later boot, the device
reconstructs the same keyBits (majority vote of cell XOR offset) and HKDFs them
into the root. Helper data is public.

Emits a Nim const include (examples/puf_helper_data.nim) consumed by the
m0_puf_root_test firmware, so the device runs reconstruct + HKDF on real SRAM.

Usage:
  python3 tools/puf/puf_enroll.py puf_runs/run_001.txt --r 11 --seed 1
"""
from __future__ import annotations
import argparse
import random
from pathlib import Path

KEY_BITS = 256
WINDOW_BITS = 1024 * 32   # 4 KB window


def load_window_bits(path: Path) -> list[int]:
    bits: list[int] = []
    for w in path.read_text().split():
        v = int(w, 16)
        for b in range(32):
            bits.append((v >> b) & 1)
    return bits


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("reference")
    ap.add_argument("--r", type=int, default=11)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--out", default="examples/puf_helper_data.nim")
    args = ap.parse_args()

    golden = load_window_bits(Path(args.reference))
    assert len(golden) >= WINDOW_BITS, f"reference too short: {len(golden)}"
    rng = random.Random(args.seed)
    r = args.r

    indices = []   # KEY_BITS * r cell indices
    offsets = []   # KEY_BITS * r offset bits
    for i in range(KEY_BITS):
        idx = [rng.randrange(WINDOW_BITS) for _ in range(r)]
        ones = sum(golden[k] for k in idx)
        keybit = 1 if ones * 2 > r else 0
        for k in idx:
            indices.append(k)
            offsets.append(golden[k] ^ keybit)

    out = Path(args.out)
    lines = [
        "## AUTO-GENERATED PUF helper data (code-offset repetition). Do not edit.",
        f"const PufHelperR* = {r}",
        f"const PufHelperIdx*: array[{len(indices)}, uint32] = [",
        "  " + ", ".join(f"{v}'u32" for v in indices),
        "]",
        f"const PufHelperOff*: array[{len(offsets)}, uint8] = [",
        "  " + ", ".join(f"{v}'u8" for v in offsets),
        "]",
    ]
    out.write_text("\n".join(lines) + "\n")
    print(f"enrolled {KEY_BITS} key bits, r={r} -> {out} "
          f"({len(indices)} cells)")


if __name__ == "__main__":
    main()
