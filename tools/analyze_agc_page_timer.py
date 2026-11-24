"""Validate page/path settings against the AGC timer operand 02."""

from __future__ import annotations

import argparse
from pathlib import Path
import re


CASE = re.compile(
    r"^AGC PAGE TIMER CASE (0x[0-9A-F]+) (0x[0-9A-F]+) "
    r"(0x[0-9A-F]+) (0x[0-9A-F]+) (0x[0-9A-F]+)$",
    re.M,
)
COUNT = re.compile(r"^AGC PAGE TIMER COUNT (0x[0-9A-F]+)$", re.M)


def decode(path: Path) -> int:
    content = path.read_text()
    if content.count("AGC PAGE TIMER END") != 1:
        raise ValueError(f"{path}: incomplete or repeated capture")
    count_match = COUNT.search(content)
    if count_match is None:
        raise ValueError(f"{path}: missing timer count")
    count = int(count_match.group(1), 16)
    if count not in (1000, 2000):
        raise ValueError(f"{path}: unsupported count for this analyzer: {count}")
    rows = [tuple(int(field, 16) for field in match.groups()) for match in CASE.finditer(content)]
    if len(rows) != 48 or [(row[0], row[1]) for row in rows] != [
        (phase, bin_index) for phase in range(8) for bin_index in range(6)
    ]:
        raise ValueError(f"{path}: missing, duplicate, or unordered cases")
    switch_bin = count // 500
    for phase, bin_index, source, marker, bad in rows:
        if bad or source + marker == 0:
            raise ValueError(f"{path}: invalid fetch in phase {phase}, bin {bin_index}")
        expected_marker = phase >= 4 and bin_index >= switch_bin
        if expected_marker and (marker == 0 or source != 0):
            raise ValueError(f"{path}: no clean timer transfer in phase {phase}, bin {bin_index}")
        near_boundary = (phase >= 4 and bin_index == switch_bin - 1 and
                         source > 0 and marker <= 1)
        if not expected_marker and not near_boundary and (source == 0 or marker != 0):
            raise ValueError(f"{path}: early timer transfer in phase {phase}, bin {bin_index}")
    print(f"{path}: count={count}, timer-disabled phases stay parked; "
          f"all path/page settings transfer in bin {switch_bin} at {switch_bin * 50} us")
    return count


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", type=Path, nargs="+")
    args = parser.parse_args()
    for path in args.logs:
        decode(path)


if __name__ == "__main__":
    main()
