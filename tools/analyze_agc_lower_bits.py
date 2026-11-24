"""Validate parked AGC lower-header-bit sweeps against RIU diagnostics."""

from __future__ import annotations

import argparse
from pathlib import Path
import re


CONFIG = re.compile(r"^AGC LOWER BIT CONFIG (.+)$", re.M)
CASE = re.compile(r"^AGC LOWER BIT CASE (.+)$", re.M)


def decode(path: Path) -> None:
    content = path.read_text()
    if (content.count("AGC LOWER BIT END") != 1 or
            "AGC LOWER BIT IMAGE RESTORED" not in content):
        raise ValueError(f"{path}: incomplete capture or unrestored image")
    config = CONFIG.search(content)
    if config is None:
        raise ValueError(f"{path}: missing configuration")
    values = [int(value, 16) for value in config.group(1).split()]
    if len(values) == 2:
        bank, saved_evt2 = values
        base = 0
    elif len(values) == 3:
        bank, base, saved_evt2 = values
    else:
        raise ValueError(f"{path}: invalid configuration")
    if bank not in (1, 2, 3, 5) or base not in (0, 15) or saved_evt2 == 0:
        raise ValueError(f"{path}: unexpected bank, base, or EVT2 state")
    rows = [[int(value, 16) for value in match.group(1).split()]
            for match in CASE.finditer(content)]
    if len(rows) != 16 or any(len(row) != 8 for row in rows):
        raise ValueError(f"{path}: incomplete or malformed case matrix")

    for phase, row in enumerate(rows):
        case, control, samples, diag_or, diag_and, first, last, bad = row
        expected_control = base ^ (0 if phase == 0 else 1 << (phase - 1))
        if case != phase or control != expected_control or samples == 0 or bad:
            raise ValueError(f"{path}: invalid parked state in phase {phase}")
        if bank == 1:
            expected_and = 2
            expected_or = 0x202 if base == 15 and phase == 11 else 2
            if (diag_and, diag_or, first, last) != (
                    expected_and, expected_or, 2, expected_or):
                raise ValueError(f"{path}: bank-1 mismatch in phase {phase}")
        elif bank == 2:
            high = ((control & 4) << 12) | ((control & 8) << 10)
            if any(value & 0xE000 != high for value in
                   (diag_or, diag_and, first, last)):
                raise ValueError(f"{path}: bank-2 controls do not follow bits 2/3 "
                                 f"in phase {phase}")
        else:
            expected = (0x3F40 if bank == 3 else
                        0x80 | ((control & 4) << 2))
            if (diag_or, diag_and, first, last) != (expected,) * 4:
                raise ValueError(f"{path}: bank-{bank} mismatch in phase {phase}")
    print(f"{path}: 16 parked one-bit cases valid, RIU bank {bank}, base {base:04X}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", type=Path, nargs="+")
    args = parser.parse_args()
    for path in args.logs:
        decode(path)


if __name__ == "__main__":
    main()
