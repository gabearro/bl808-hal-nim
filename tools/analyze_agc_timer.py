"""Check AGC timer dwell times against the board's 1 MHz mtime counter."""

from __future__ import annotations

import argparse
from pathlib import Path
import re


CASE = re.compile(r"^AGC TIMER CASE ((?:0x[0-9A-F]+ ?){7})$", re.M)
CLOCK = re.compile(r"^AGC TIMER CLOCK ((?:0x[0-9A-F]+ ?){4})$", re.M)
COUNTS = (2000, 50, 100, 200, 500, 1000, 2000, 50, 500, 1000, 2000)


def check(path: Path) -> None:
    content = path.read_text()
    if content.count("AGC TIMER END") != 1:
        raise ValueError(f"{path}: incomplete or repeated capture")
    rows = [tuple(int(field, 16) for field in match[1].split())
            for match in CASE.finditer(content)]
    if len(rows) != 12 or [row[0] for row in rows] != list(range(12)):
        raise ValueError(f"{path}: missing or unordered timer states")
    if tuple(row[1] for row in rows[:-1]) != COUNTS:
        raise ValueError(f"{path}: unexpected programmed counts")
    if tuple(row[6] for row in rows[:-1]) != (0,) * 7 + (1,) * 4:
        raise ValueError(f"{path}: unexpected bit-26 settings")
    if sum(row[4] for row in rows) != 2_000_000:
        raise ValueError(f"{path}: fetch sample accounting mismatch")

    clock = CLOCK.search(content)
    if clock is None:
        raise ValueError(f"{path}: missing clock calibration")
    cycle_start, cycle_end, mtime_start, mtime_end = (
        int(field, 16) for field in clock[1].split()
    )
    elapsed_cycles = (cycle_end - cycle_start) & 0xFFFFFFFF
    elapsed_mtime = (mtime_end - mtime_start) & 0xFFFFFFFF
    cycles_per_mtime = elapsed_cycles / elapsed_mtime
    if abs(cycles_per_mtime - 320) > 0.1:
        raise ValueError(f"{path}: unexpected M0 cycles/mtime tick {cycles_per_mtime}")

    for row, following in zip(rows, rows[1:]):
        index, count, cycle_first, _, samples, mtime_first, high_bit = row
        if samples < 2:
            raise ValueError(f"{path}: too few samples in state {index}")
        delta_mtime = (following[5] - mtime_first) & 0xFFFFFFFF
        delta_cycles = (following[2] - cycle_first) & 0xFFFFFFFF
        expected_us = count / 10
        if abs(delta_mtime - expected_us) > 2 or abs(delta_cycles / 320 - expected_us) > 2:
            raise ValueError(f"{path}: state {index} count {count} bit26 {high_bit} "
                             f"took {delta_mtime} mtime ticks / {delta_cycles} cycles")
        print(f"count={count:4} bit26={high_bit}: {delta_mtime:3} mtime ticks, "
              f"{delta_cycles:5} M0 cycles")
    print(f"{path}: timer count is 0.1 us at this clock setting; "
          f"M0 cycles/mtime tick={cycles_per_mtime:.6f}; bit 26 is not a count high bit")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    check(parser.parse_args().log)


if __name__ == "__main__":
    main()
