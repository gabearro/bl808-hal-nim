"""Validate AGC state-bit probe logs against the RIU bank-2 control lanes."""

from __future__ import annotations

import argparse
from pathlib import Path
import re


CASE = re.compile(
    r"^AGC STATE DIAG CASE (0x[0-9A-F]+) (0x[0-9A-F]+) "
    r"(0x[0-9A-F]+) (0x[0-9A-F]+) (0x[0-9A-F]+) "
    r"(0x[0-9A-F]+)$",
    re.M,
)


def decode(path: Path) -> None:
    content = path.read_text()
    if content.count("AGC STATE DIAG END") != 1 or "AGC STATE DIAG IMAGE RESTORED" not in content:
        raise ValueError(f"{path}: incomplete capture or image not restored")
    rows = [tuple(int(field, 16) for field in match.groups()) for match in CASE.finditer(content)]
    if len(rows) != 64 or [(row[0], row[1]) for row in rows] != [
        (phase, bin_index) for phase in range(8) for bin_index in range(8)
    ]:
        raise ValueError(f"{path}: missing, duplicate, or unordered cases")
    for phase, bin_index, samples, diag_or, diag_and, bad_address in rows:
        if samples == 0 or bad_address or diag_or & 0x8000 or diag_and & 0x8000:
            raise ValueError(f"{path}: invalid samples in phase {phase}, bin {bin_index}")
        expected_delay_line = bool(phase & 2)
        if bool(diag_or & 0x4000) != expected_delay_line or bool(diag_and & 0x4000) != expected_delay_line:
            raise ValueError(f"{path}: bank-2 bit 14 does not follow header bit 2 "
                             f"in phase {phase}, bin {bin_index}")
        if bin_index > 0:
            expected_high = 0x6000 if expected_delay_line else 0x2000
            if diag_or & 0xF000 != expected_high or diag_and & 0xF000 != expected_high:
                raise ValueError(f"{path}: steady high control lanes differ "
                                 f"in phase {phase}, bin {bin_index}")
    print(f"{path}: all 64 bins sampled parked state; bank-2 bit 14 exactly "
          "follows header bit 2; bank-2 bit 15 remains clear")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", type=Path, nargs="+")
    args = parser.parse_args()
    for path in args.logs:
        decode(path)


if __name__ == "__main__":
    main()
