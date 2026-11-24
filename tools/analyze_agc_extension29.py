"""Validate the event-isolated AGC selector-0x29 diagnostic sweeps."""

from __future__ import annotations

import argparse
from pathlib import Path
import re


CASE = re.compile(r"^AGC EXT29 CASE (.+)$", re.M)
TOP = re.compile(r"^AGC EXT29 TOP (0x[0-9A-F]+) (0x[0-9A-F]+) (0x[0-9A-F]+)$", re.M)
BANK = re.compile(r"^AGC EXT29 DIAG BANK (0x[0-9A-F]+)$", re.M)
WORDS = (
    0, 0x29000000, 0x29000300, 0x29000100,
    0x29000301, 0x29000101, 0x29000001,
    0x29030002, 0x29000302, 0x29010002,
    0x29000102, 0x29000002, 0,
)


def decode(path: Path) -> None:
    content = path.read_text()
    if content.count("AGC EXT29 END") != 1 or "AGC EXT29 IMAGE RESTORED" not in content:
        raise ValueError(f"{path}: incomplete capture or image not restored")
    bank_match = BANK.search(content)
    if bank_match is None:
        raise ValueError(f"{path}: missing diagnostic bank")
    bank = int(bank_match.group(1), 16)
    rows = [tuple(int(value, 16) for value in match.group(1).split())
            for match in CASE.finditer(content)]
    if len(rows) != 13 or any(len(row) != 12 for row in rows):
        raise ValueError(f"{path}: incomplete case matrix")
    if tuple(row[0] for row in rows) != tuple(range(13)) or tuple(row[1] for row in rows) != WORDS:
        raise ValueError(f"{path}: unexpected selector payload or case order")
    tops = [tuple(int(value, 16) for value in match.groups()) for match in TOP.finditer(content)]
    if tops != [(phase, 1 if word == 0 else 2, 5000)
                for phase, word in enumerate(WORDS)]:
        raise ValueError(f"{path}: fetch addresses were not continuously parked")
    for row in rows:
        phase, word, first, last, minimum, maximum, diag_or, diag_and, bad, first_bad, last_bad, evt2 = row
        if bad or first_bad or last_bad or evt2:
            raise ValueError(f"{path}: phase {phase} was not isolated from event 2")
        if not (minimum <= first <= maximum and minimum <= last <= maximum):
            raise ValueError(f"{path}: phase {phase} has invalid diagnostic range")
        if bank == 3 and (first, last, minimum, maximum, diag_or, diag_and) != (0x3F40,) * 6:
            raise ValueError(f"{path}: gain diagnostic changed in phase {phase}")
        if bank == 5:
            expected = 0x90 if word == 0 else 0x110
            if (first, last, minimum, maximum, diag_or, diag_and) != (expected,) * 6:
                raise ValueError(f"{path}: FSM diagnostic changed beyond address in phase {phase}")
        if bank == 2 and (diag_or & 0xE000 != 0x6000 or diag_and & 0xE000 != 0x6000):
            raise ValueError(f"{path}: in-band control lanes changed in phase {phase}")
    print(f"{path}: bank {bank}; 11 payloads plus two controls; "
          "all 5000 fetches per phase parked; no measured high-lane change")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", type=Path, nargs="+")
    args = parser.parse_args()
    for path in args.logs:
        decode(path)


if __name__ == "__main__":
    main()
