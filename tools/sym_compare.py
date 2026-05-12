#!/usr/bin/env python3
"""
Compare text symbols between reference blob and Nim reimplementation object file.
"""

import subprocess
import sys
from collections import defaultdict

def extract_symbols(cmd):
    """Run nm command and parse text symbols. Returns dict: name -> max_size."""
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"ERROR running: {cmd}", file=sys.stderr)
        print(result.stderr, file=sys.stderr)
        sys.exit(1)

    symbols = defaultdict(int)
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split()
        # Expected format: [addr] size type name
        # With -S: "00000000 00000042 t name" (4 parts)
        # Without size: "00000000 t name" (3 parts)
        if len(parts) == 4:
            try:
                size = int(parts[1], 16)
                name = parts[3]
            except ValueError:
                continue
        elif len(parts) == 3:
            size = 0
            name = parts[2]
        else:
            continue
        # Keep max size for duplicates (same symbol in multiple .o files)
        if size > symbols[name]:
            symbols[name] = size

    return dict(symbols)

def main():
    BLOB_CMD = "riscv64-unknown-elf-nm -S tools/ref/libwifi_bl808.a | grep ' [tT] '"
    NIM_CMD  = "riscv64-unknown-elf-nm -S build/wifi_fw_nim.o | grep ' [tT] '"

    print("Extracting blob symbols...")
    blob = extract_symbols(BLOB_CMD)
    print(f"  -> {len(blob)} unique symbols in blob")

    print("Extracting Nim symbols...")
    nim = extract_symbols(NIM_CMD)
    print(f"  -> {len(nim)} unique symbols in Nim object")
    print()

    blob_names = set(blob.keys())
    nim_names  = set(nim.keys())

    common      = blob_names & nim_names
    blob_only   = blob_names - nim_names
    nim_only    = nim_names  - blob_names

    # ---- Summary counts ----
    print("=" * 60)
    print("SYMBOL COUNTS")
    print("=" * 60)
    print(f"  Common symbols       : {len(common)}")
    print(f"  Blob-only (missing)  : {len(blob_only)}")
    print(f"  Nim-only (extra)     : {len(nim_only)}")
    print()

    # ---- Byte coverage ----
    total_blob_bytes = sum(blob.values())
    total_nim_bytes  = sum(nim.values())
    # coverage = nim bytes for common symbols vs blob bytes for all symbols
    common_nim_bytes  = sum(nim[n]  for n in common)
    common_blob_bytes = sum(blob[n] for n in common)
    byte_coverage = (common_nim_bytes / total_blob_bytes * 100) if total_blob_bytes else 0.0

    print("=" * 60)
    print("BYTE COVERAGE")
    print("=" * 60)
    print(f"  Total blob text bytes          : {total_blob_bytes:,}")
    print(f"  Total Nim text bytes           : {total_nim_bytes:,}")
    print(f"  Blob bytes for common symbols  : {common_blob_bytes:,}")
    print(f"  Nim  bytes for common symbols  : {common_nim_bytes:,}")
    print(f"  Byte coverage (common nim/all blob) : {byte_coverage:.2f}%")
    print()

    # ---- Per-symbol ratios ----
    ratios = {}
    for name in common:
        b = blob[name]
        n = nim[name]
        if b > 0:
            ratios[name] = n / b
        else:
            ratios[name] = float('inf') if n > 0 else 1.0

    ratio_list = list(ratios.values())

    well_matched = sum(1 for r in ratio_list if 0.65 <= r <= 1.50)
    near_exact   = sum(1 for r in ratio_list if 0.95 <= r <= 1.05)
    undersized   = [(n, blob[n], nim[n], ratios[n])
                    for n in common
                    if ratios[n] < 0.65 and blob[n] > 30]

    sorted_ratios = sorted(ratio_list)
    n = len(sorted_ratios)
    if n:
        mid = n // 2
        median = sorted_ratios[mid] if n % 2 == 1 else (sorted_ratios[mid-1] + sorted_ratios[mid]) / 2
        mean = sum(sorted_ratios) / n
    else:
        median = mean = 0.0

    print("=" * 60)
    print("RATIO STATISTICS  (nim_size / blob_size, common symbols)")
    print("=" * 60)
    print(f"  Well-matched  (0.65 - 1.50)   : {well_matched} / {len(common)}")
    print(f"  Near-exact    (0.95 - 1.05)   : {near_exact} / {len(common)}")
    print(f"  Undersized    (<0.65, blob>30) : {len(undersized)}")
    print(f"  Median ratio                  : {median:.4f}")
    print(f"  Mean   ratio                  : {mean:.4f}")
    print()

    # ---- Undersized symbols ----
    undersized_sorted = sorted(undersized, key=lambda x: x[1] - x[2], reverse=True)
    print("=" * 60)
    print("UNDERSIZED SYMBOLS  (<0.65 ratio, blob>30 bytes)")
    print(f"  {'Symbol':<50} {'Blob':>6} {'Nim':>6} {'Ratio':>7} {'Gap':>6}")
    print("  " + "-" * 80)
    for name, bsz, nsz, ratio in undersized_sorted:
        gap = bsz - nsz
        print(f"  {name:<50} {bsz:>6} {nsz:>6} {ratio:>7.3f} {gap:>6}")
    print()

    # ---- Blob-only (missing) symbols ----
    blob_only_sorted = sorted(blob_only, key=lambda n: blob[n], reverse=True)
    print("=" * 60)
    print(f"BLOB-ONLY (MISSING) SYMBOLS  [{len(blob_only)} total]")
    print(f"  {'Symbol':<50} {'Blob size':>9}")
    print("  " + "-" * 62)
    for name in blob_only_sorted:
        print(f"  {name:<50} {blob[name]:>9}")
    print()

    # ---- Nim-only symbols (brief) ----
    nim_only_sorted = sorted(nim_only, key=lambda n: nim[n], reverse=True)
    print("=" * 60)
    print(f"NIM-ONLY (EXTRA) SYMBOLS  [{len(nim_only)} total]")
    print(f"  {'Symbol':<50} {'Nim size':>8}")
    print("  " + "-" * 61)
    for name in nim_only_sorted:
        print(f"  {name:<50} {nim[name]:>8}")


if __name__ == "__main__":
    main()
