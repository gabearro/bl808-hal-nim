"""Validate the AGC path/page-bit probe and print constant-input truth masks.

For each path/page setting, mask bit (4*A + 2*B + C) is the branch result.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import re


CASE = re.compile(
    r"^AGC PATH PAGE CASE (0x[0-9A-F]+) (0x[0-9A-F]+) "
    r"(0x[0-9A-F]+) (0x[0-9A-F]+)$",
    re.M,
)
TRACE = re.compile(
    r"^AGC PATH PAGE TRACE (0x[0-9A-F]+) (0x[0-9A-F]+) "
    r"(0x[0-9A-F]+)$",
    re.M,
)


def decode(path: Path) -> tuple[tuple[int, int], ...]:
    content = path.read_text()
    if content.count("AGC PATH PAGE END") != 1:
        raise ValueError(f"{path}: incomplete or repeated capture")
    rows = [tuple(int(field, 16) for field in match.groups()) for match in CASE.finditer(content)]
    if len(rows) != 68 or [row[0] for row in rows] != list(range(68)):
        raise ValueError(f"{path}: missing, duplicate, or unordered cases")
    trace = TRACE.search(content)
    if trace is None:
        raise ValueError(f"{path}: missing trace summary")
    first, last, terminal_count = (int(field, 16) for field in trace.groups())
    if first >= 476 or last not in (476, 477):
        raise ValueError(f"{path}: probe did not reach terminal")
    if terminal_count + sum(sum(row[1:]) for row in rows) != 5_000_000:
        raise ValueError(f"{path}: fetch accounting mismatch")

    outcomes = []
    for case_index, _, true_count, false_count in rows:
        if (true_count > 0) == (false_count > 0):
            raise ValueError(f"{path}: case {case_index} not resolved")
        outcomes.append(true_count > 0)
    if [outcomes[index] for index in (0, 1, 66, 67)] != [True, False, True, False]:
        raise ValueError(f"{path}: controls disagree")

    masks = tuple(
        tuple(
            sum(1 << row for row in range(8) if outcomes[2 + config * 16 + comb * 8 + row])
            for comb in range(2)
        )
        for config in range(4)
    )
    marker_min = min(max(row[2], row[3]) for row in rows)
    print(f"{path}: controls passed; minimum marker samples {marker_min}")
    for config, (c0, c1) in enumerate(masks):
        print(f"  path={(config >> 1) & 1} page={config & 1}: C0={c0:02X} C1={c1:02X}")
    return masks


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", type=Path, nargs="+")
    args = parser.parse_args()
    masks = [decode(path) for path in args.logs]
    if len(set(masks)) != 1:
        raise ValueError("captures disagree")


if __name__ == "__main__":
    main()
