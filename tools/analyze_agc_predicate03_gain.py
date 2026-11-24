"""Validate readback-checked P03/P04 RC2 gain-limit hardware sweeps."""

from __future__ import annotations

import argparse
from pathlib import Path
import re


CASE = re.compile(r"^AGC P03 GAIN CASE (.+)$", re.M)
SAVED = re.compile(r"^AGC P03 GAIN SAVED (0x[0-9A-F]+) (0x[0-9A-F]+)$", re.M)
CONFIG = re.compile(r"^AGC P03 GAIN CONFIG (0x[0-9A-F]+) (0x[0-9A-F]+)$", re.M)


def decode(path: Path) -> None:
    content = path.read_text()
    if content.count("AGC P03 GAIN END") != 1 or "AGC P03 GAIN IMAGE RESTORED" not in content:
        raise ValueError(f"{path}: incomplete capture or image not restored")
    saved = SAVED.search(content)
    if saved is None or int(saved.group(1), 16) != 0x003E0504 or int(saved.group(2), 16) == 0:
        raise ValueError(f"{path}: unexpected original register state")
    config = CONFIG.search(content)
    predicate, shift = ((int(config.group(1), 16), int(config.group(2), 16))
                        if config else (3, 0))
    if (predicate, shift) not in ((3, 0), (4, 16)):
        raise ValueError(f"{path}: unexpected predicate/field selection")
    default = 62 if shift == 16 else 4
    thresholds = (default, default, default, 0, 32, 63, 255, default, default)
    predicates = (0, 1, predicate, predicate, predicate, predicate,
                  predicate, predicate, 0)
    rows = [tuple(int(value, 16) for value in match.group(1).split())
            for match in CASE.finditer(content)]
    if len(rows) != 9 or any(len(row) != 12 for row in rows):
        raise ValueError(f"{path}: incomplete case matrix")
    for index, row in enumerate(rows):
        case, predicate, threshold, limits, gain, source, true_count, false_count, bad, first_tick, diag_or, diag_and = row
        if (case, predicate, threshold) != (index, predicates[index], thresholds[index]):
            raise ValueError(f"{path}: wrong case {index}")
        expected_limits = (0x003E0504 & ~(0xFF << shift)) | (threshold << shift)
        if limits != expected_limits or gain != 0x3F40 or bad:
            raise ValueError(f"{path}: register/control mismatch in case {index}")
        if (diag_or & ~1) != 2 or (diag_and & ~1) != 2:
            raise ValueError(f"{path}: bank-1 diagnostic changed in case {index}")
        if predicate == 0 or predicate == 4:
            if true_count or false_count == 0 or first_tick not in (99, 100, 101):
                raise ValueError(f"{path}: false control failed in case {index}")
        elif false_count or true_count == 0 or first_tick > 1:
            raise ValueError(f"{path}: immediate branch failed in case {index}")
    print(f"{path}: all thresholds read back; P{predicates[2]:02X} branch "
          f"and bank-1 diagnostic remain unchanged; gain stays 3F40; controls pass")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", type=Path, nargs="+")
    args = parser.parse_args()
    for path in args.logs:
        decode(path)


if __name__ == "__main__":
    main()
