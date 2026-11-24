"""Validate the two- and seven-slot BL808 AGC branch-priority captures."""

from __future__ import annotations

import argparse
from pathlib import Path
import re


CASE = re.compile(
    r"^AGC PRIORITY CASE (0x[0-9A-F]+) (0x[0-9A-F]+) "
    r"(0x[0-9A-F]+) (0x[0-9A-F]+)$",
    re.M,
)
TRACE = re.compile(
    r"^AGC PRIORITY TRACE (0x[0-9A-F]+) (0x[0-9A-F]+) "
    r"(0x[0-9A-F]+)$",
    re.M,
)
SLOTS = re.compile(r"^AGC PRIORITY SLOTS (0x[0-9A-F]+)$", re.M)


def check(path: Path) -> None:
    content = path.read_text()
    if content.count("AGC PRIORITY END") != 1:
        raise ValueError(f"{path}: incomplete or repeated capture")
    slot_match = SLOTS.search(content)
    slots = int(slot_match[1], 16) if slot_match else 2
    if slots not in (2, 7):
        raise ValueError(f"{path}: unknown probe width {slots}")
    expected = (["A", "B", "A", "B", "A", "A", "B", "B"]
                if slots == 2 else ["A"] * 13 + ["B"] * 6)
    rows = [tuple(int(field, 16) for field in match.groups()) for match in CASE.finditer(content)]
    if len(rows) != len(expected) or [row[0] for row in rows] != list(range(len(expected))):
        raise ValueError(f"{path}: missing, duplicate, or unordered cases")
    trace = TRACE.search(content)
    if trace is None:
        raise ValueError(f"{path}: missing trace summary")
    first, last, terminal_count = (int(field, 16) for field in trace.groups())
    terminal = len(expected) * (7 if slots == 2 else 12)
    if first >= terminal or last not in (terminal, terminal + 1):
        raise ValueError(f"{path}: probe did not reach the terminal state")
    if terminal_count + sum(sum(row[1:]) for row in rows) != 5_000_000:
        raise ValueError(f"{path}: fetch sample accounting mismatch")
    results = []
    for case_index, _, count_a, count_b in rows:
        if (count_a > 0) == (count_b > 0):
            raise ValueError(f"{path}: case {case_index} has ambiguous markers")
        results.append("A" if count_a else "B")
    if results != expected:
        raise ValueError(f"{path}: observed {''.join(results)}, expected {''.join(expected)}")
    minimum = min(max(count_a, count_b) for _, _, count_a, count_b in rows)
    print(f"{path}: {slots} slots, {len(rows)} cases, minimum marker samples {minimum}; "
          "first eligible slot wins every overlap")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", type=Path, nargs="+")
    for path in parser.parse_args().logs:
        check(path)


if __name__ == "__main__":
    main()
