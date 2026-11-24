"""Attribute a captured BL808 AP PC sample stream to firmware ELF symbols."""

import argparse
from bisect import bisect_right
from collections import Counter
from pathlib import Path
from statistics import median
from struct import iter_unpack
from subprocess import check_output


def symbol_ranges(elf: Path, nm: str) -> list[tuple[int, int, str]]:
    by_start: dict[int, tuple[int, int, str]] = {}
    for line in check_output([nm, "-S", "--defined-only", elf], text=True).splitlines():
        fields = line.split(maxsplit=3)
        if len(fields) != 4 or fields[2] not in {"T", "t", "W", "w"}:
            continue
        start, size = (int(v, 16) for v in fields[:2])
        if size and (start not in by_start or start + size > by_start[start][1]):
            by_start[start] = (start, start + size, fields[3])
    return sorted(by_start.values())


def classify(name: str) -> str:
    short = name.split("__", 1)[0]
    if short in {"leasedShaBlock", "loadShaBlock", "byteSwap"}:
        return "leased driver and packing"
    if name in {"bl808_mbedtls_sha1_process", "mbedtls_internal_sha1_process"}:
        return "block wrappers"
    if name in {"memcpy", "memset", "memmove"}:
        return "libc memory routines"
    if name.startswith("mbedtls_sha1_"):
        return "SHA-1 stream and padding"
    if name.startswith("mbedtls_md_"):
        return "Mbed TLS digest dispatch and HMAC"
    if name == "mbedtls_pkcs5_pbkdf2_hmac":
        return "Mbed TLS derivation loop"
    if name == "<unmapped>":
        return "unmapped"
    return "other"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("elf", type=Path)
    parser.add_argument("samples", type=Path, help="little-endian pairs of mtime-low and mepc")
    parser.add_argument("start", type=lambda s: int(s, 0), help="key callback start tick")
    parser.add_argument("end", type=lambda s: int(s, 0), help="key callback end tick")
    parser.add_argument("--nm", default="riscv64-unknown-elf-nm")
    args = parser.parse_args()
    mask = (1 << 32) - 1
    duration = (args.end - args.start) & mask
    if not 0 < duration <= 1_000_000:
        parser.error("invalid callback interval")

    ranges = symbol_ranges(args.elf, args.nm)
    starts = [row[0] for row in ranges]
    ticks: list[int] = []
    functions: Counter[str] = Counter()
    categories: Counter[str] = Counter()
    for at, pc in iter_unpack("<II", args.samples.read_bytes()):
        tick = (at - args.start) & mask
        if tick >= duration:
            continue
        ticks.append(tick)
        i = bisect_right(starts, pc) - 1
        name = ranges[i][2] if i >= 0 and pc < ranges[i][1] else "<unmapped>"
        functions[name] += 1
        categories[classify(name)] += 1
    if len(ticks) < 2:
        parser.error("fewer than two samples in the callback")
    gaps = [b - a for a, b in zip(ticks, ticks[1:])]
    if min(gaps) <= 0:
        parser.error("sample timestamps are not strictly increasing")
    print(f"{len(ticks)} samples, {duration / 1000:.3f} ms; "
          f"sample gaps {min(gaps)}/{median(gaps):g}/{max(gaps)} us (min/median/max)")
    for counter in (categories, functions):
        for name, n in counter.most_common():
            print(f"{n:5} {100 * n / len(ticks):5.1f}% {duration * n / len(ticks) / 1000:6.1f} ms  {name}")
        print()


if __name__ == "__main__":
    main()
