"""Validate and compare all 64 AGC predicate IDs in idle hardware sweeps."""

from __future__ import annotations

import argparse
from pathlib import Path
import re


CASE = re.compile(r"^AGC PREDICATE CASE (.+)$", re.M)
CONFIG = re.compile(
    r"^AGC PREDICATE CONFIG (0x[0-9A-F]+) (0x[0-9A-F]+) "
    r"(0x[0-9A-F]+) (0x[0-9A-F]+)(?: (0x[0-9A-F]+))?"
    r"(?: (0x[0-9A-F]+))?$",
    re.M,
)


def decode(path: Path) -> tuple[tuple[int, int, int, int], tuple[bool, ...]]:
    content = path.read_text()
    if content.count("AGC PREDICATE END") != 1 or "AGC PREDICATE IMAGE RESTORED" not in content:
        raise ValueError(f"{path}: incomplete capture or image not restored")
    config_match = CONFIG.search(content)
    if config_match is None:
        raise ValueError(f"{path}: missing configuration")
    page, path_bit, timer_count, evt2 = (int(value, 16) for value in config_match.groups()[:4])
    force_rx = int(config_match.group(5), 16) if config_match.group(5) else 0
    control = int(config_match.group(6), 16) if config_match.group(6) else 0x8F
    if page not in (0, 1) or path_bit not in (0, 1) or timer_count != 1000 or evt2 == 0:
        raise ValueError(f"{path}: unexpected configuration")
    rows = [tuple(int(value, 16) for value in match.group(1).split())
            for match in CASE.finditer(content)]
    if len(rows) != 64 or any(len(row) != 9 for row in rows) or [row[0] for row in rows] != list(range(64)):
        raise ValueError(f"{path}: incomplete predicate matrix")
    outcomes = []
    for predicate, source, true_count, false_count, bad, first_tick, diag_samples, diag_or, diag_and in rows:
        if bad or (true_count > 0) == (false_count > 0):
            raise ValueError(f"{path}: predicate {predicate:02X} has ambiguous marker")
        if diag_samples != source:
            raise ValueError(f"{path}: predicate {predicate:02X} diagnostic accounting mismatch")
        if source and force_rx == 0 and control == 0x8F and (diag_or != 2 or diag_and != 2):
            raise ValueError(f"{path}: predicate {predicate:02X} has different parked bank-1 status")
        if force_rx == 0 and control == 0x8F and true_count and predicate != 2 and first_tick > 1:
            raise ValueError(f"{path}: predicate {predicate:02X} was not immediately true")
        if (false_count or predicate == 2) and first_tick not in (99, 100, 101):
            raise ValueError(f"{path}: predicate {predicate:02X} missed timer deadline")
        outcomes.append(true_count > 0)
    if outcomes[:3] != [False, True, True]:
        raise ValueError(f"{path}: constant/timer controls disagree")
    true_codes = [index for index, outcome in enumerate(outcomes) if outcome]
    print(f"{path}: page={page} path={path_bit} force_rx={force_rx} "
          f"control={control:04X}; "
          f"true marker = {' '.join(f'{code:02X}' for code in true_codes)} "
          "(02 at timer expiry; other first-hit times in UART rows)")
    return (page, path_bit, force_rx, control), tuple(outcomes)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("logs", type=Path, nargs="+")
    args = parser.parse_args()
    results = [decode(path) for path in args.logs]
    if len(set(result[0] for result in results)) != len(results):
        raise ValueError("duplicate path/page configuration")
    for force_rx, control in {(result[0][2], result[0][3]) for result in results}:
        signatures = {result[1] for result in results
                      if result[0][2:] == (force_rx, control)}
        if len(signatures) != 1:
            raise ValueError(f"path/page predicate outcomes differ for "
                             f"force_rx={force_rx}, control={control:04X}")


if __name__ == "__main__":
    main()
