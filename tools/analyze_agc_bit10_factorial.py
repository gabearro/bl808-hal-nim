"""Validate bank-1 bit-9 response to AGC header bits 3 and 10."""

from __future__ import annotations

import argparse
from pathlib import Path
import re


CASE = re.compile(r"^AGC BIT10 FACTORIAL CASE (.+)$", re.M)
EVT2 = re.compile(r"^AGC BIT10 FACTORIAL EVT2 (0x[0-9A-F]+)$", re.M)


def decode(path: Path) -> None:
    content = path.read_text()
    if (content.count("AGC BIT10 FACTORIAL END") != 1 or
            "AGC BIT10 FACTORIAL IMAGE RESTORED" not in content):
        raise ValueError(f"{path}: incomplete capture or unrestored image")
    evt2 = EVT2.search(content)
    if evt2 is None or int(evt2.group(1), 16) == 0:
        raise ValueError(f"{path}: missing original EVT2 value")
    rows = [[int(value, 16) for value in match.group(1).split()]
            for match in CASE.finditer(content)]
    if len(rows) != 32 or any(len(row) != 9 for row in rows):
        raise ValueError(f"{path}: malformed or incomplete factorial matrix")
    for phase, row in enumerate(rows):
        case, control, samples, high_count, first, last, diag_or, diag_and, bad = row
        nibble, bit10 = phase >> 1, phase & 1
        expected_control = nibble | (bit10 << 10)
        expected_high = bool(bit10 and (nibble & 8))
        if case != phase or control != expected_control or samples == 0 or bad:
            raise ValueError(f"{path}: invalid parked state in phase {phase}")
        if (diag_or & 2) == 0 or (diag_and & 2) == 0:
            raise ValueError(f"{path}: baseline bank-1 bit 1 lost in phase {phase}")
        if bool(high_count) != expected_high or bool(diag_or & 0x200) != expected_high:
            raise ValueError(f"{path}: bank-1 bit 9 did not follow interaction in phase {phase}")
        if expected_high:
            if not 1 <= first <= 10 or not 490 <= last < 500 or high_count >= samples:
                raise ValueError(f"{path}: unexpected bit-9 timing in phase {phase}")
        elif first != 0xFFFFFFFF or last != 0 or diag_and & 0x200:
            raise ValueError(f"{path}: spurious bit-9 activity in phase {phase}")
    print(f"{path}: 32 parked cases valid; bank-1 bit 9 asserted only with "
          "header bits 3 and 10 both set")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", type=Path, nargs="+")
    args = parser.parse_args()
    for path in args.logs:
        decode(path)


if __name__ == "__main__":
    main()
