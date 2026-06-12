#!/usr/bin/env python3
"""Analyze SRAM-PUF cold-boot captures for PUF viability.

Reads run_*.txt (one hex word per line) produced by puf_collect.py and reports:
  - mean bit bias (should be ~50%),
  - intra-device noise (mean fractional Hamming distance between runs),
  - count of strongly-stable bits (the usable entropy for key extraction),
  - a go/no-go for a 256-bit key with repetition-code margin.

Usage:
  python3 tools/puf/puf_analyze.py puf_runs --stable-thresh 0.02
"""
from __future__ import annotations
import argparse
import sys
from pathlib import Path


def load_run(path: Path) -> list[int]:
    bits: list[int] = []
    for line in path.read_text().split():
        w = int(line, 16)
        for b in range(32):
            bits.append((w >> b) & 1)
    return bits


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("runs_dir")
    ap.add_argument("--stable-thresh", type=float, default=0.02,
                    help="max flip fraction for a bit to count as strongly stable")
    args = ap.parse_args()

    runs = sorted(Path(args.runs_dir).glob("run_*.txt"))
    if len(runs) < 2:
        print(f"need >= 2 runs, found {len(runs)} in {args.runs_dir}")
        sys.exit(1)

    data = [load_run(r) for r in runs]
    n = len(data[0])
    if any(len(d) != n for d in data):
        print("runs differ in length; aborting")
        sys.exit(1)
    nruns = len(data)
    print(f"{nruns} runs, {n} bits each")

    # Per-bit fraction of 1s (the reference = majority value).
    ones = [0] * n
    for d in data:
        for i, b in enumerate(d):
            ones[i] += b
    p1 = [c / nruns for c in ones]
    mean_bias = sum(p1) / n
    print(f"mean bit bias (P[1]): {mean_bias*100:.1f}%  (ideal ~50%)")

    # Intra-device noise: mean fractional Hamming distance between runs and the
    # per-bit majority reference.
    ref = [1 if c * 2 > nruns else 0 for c in ones]
    total_flips = 0
    for d in data:
        total_flips += sum(1 for i in range(n) if d[i] != ref[i])
    noise = total_flips / (nruns * n)
    print(f"intra-device noise vs majority: {noise*100:.2f}%  (lower is better)")

    # Strongly-stable bits: flip fraction below threshold.
    stable = 0
    for i in range(n):
        flips = min(ones[i], nruns - ones[i]) / nruns
        if flips <= args.stable_thresh:
            stable += 1
    print(f"strongly-stable bits (flip <= {args.stable_thresh*100:.0f}%): {stable}")

    # Go/no-go: a repetition code (r=11) over sub-1% bits reconstructs 256 key
    # bits at <1e-6 failure; need ~256*11 = 2816 strongly-stable bits w/ margin.
    need = 256 * 11
    verdict = "GO" if stable >= need else "MARGINAL/NO-GO"
    print(f"need ~{need} stable bits for a 256-bit key (r=11 repetition): {verdict}")


if __name__ == "__main__":
    main()
