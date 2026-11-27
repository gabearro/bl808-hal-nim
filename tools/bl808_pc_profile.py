"""Host-side collection and symbolization of live BL808 PC samples."""

from __future__ import annotations

from bisect import bisect_right
from collections import Counter
from collections.abc import Callable, Iterable, Iterator
from pathlib import Path
import random
import re
import subprocess
import time


D0_HPM_EVENTS = (
    "cycles", "instructions_retired", "l1i_accesses", "l1i_misses",
    "conditional_branch_mispredictions", "conditional_branches",
    "l1d_read_accesses", "l1d_read_misses", "l1d_write_accesses", "l1d_write_misses",
    "instruction_utlb_misses", "data_utlb_misses", "joint_tlb_misses",
)


def scan_value(reply: str, marker: str) -> int:
    lines = reply.replace("\x00", "").splitlines()
    for line in lines:
        match = re.fullmatch(rf"{marker} (0x[0-9a-fA-F]+)", line.strip())
        if match:
            return int(match[1], 16)
    details = " ".join(line.strip() for line in lines if line.strip() not in ("", ">"))
    raise RuntimeError(f"OpenOCD did not return {marker}: {details}")


def load_symbols(nm: str, elf: Path) -> list[tuple[int, int, str]]:
    proc = subprocess.run([nm, "-n", "-S", "--defined-only", str(elf.resolve())],
                          text=True, capture_output=True, timeout=30)
    if proc.returncode:
        raise RuntimeError(f"cannot read symbols from {elf}: {proc.stderr.strip()}")
    symbols = []
    for line in proc.stdout.splitlines():
        parts = line.split(maxsplit=3)
        if len(parts) != 4 or parts[2] not in "TtWw":
            continue
        start, length = (int(value, 16) for value in parts[:2])
        if length:
            symbols.append((start, start + length, parts[3]))
    return sorted(symbols)


def collect_samples(command, *, seconds: int, rate: int) -> tuple[float, list]:
    samples = []
    start = time.monotonic()
    deadline = start + seconds
    while (now := time.monotonic()) < deadline:
        pc = scan_value(command("m0_profile_pc"), "BL808_PROFILE_PC")
        samples.append({"at_us": round((now - start) * 1_000_000), "pc": f"0x{pc:08x}"})
        # Vary the sampling period to avoid locking to radio and timer cadence.
        delay = min(now + random.uniform(0.5, 1.5) / rate, deadline) - time.monotonic()
        if delay > 0:
            time.sleep(delay)
    return time.monotonic() - start, samples


def read_d0_capture(lines: Iterable[str], *, seconds: int, rate: int,
                    with_hpm: bool = False) -> tuple[float, list, int, dict | None]:
    """Decode a complete capture, including the observer's sample count."""
    prefix = "BL808_D0_PROFILE_"
    samples = []
    begun = False
    counters = None
    last_tick = -1
    for line in lines:
        if not (parts := line.split()):
            continue
        marker, *fields = parts
        if not marker.startswith(prefix) or marker == prefix + "READY":
            continue
        kind = marker[len(prefix):]
        if kind == "ERROR":
            raise RuntimeError(f"D0 observer rejected capture: {' '.join(fields)}")
        expected = {"BEGIN": 2, "SAMPLE": 3, "END": 3,
                    "HPM": 1 + len(D0_HPM_EVENTS) * 2}.get(kind)
        if len(fields) != expected or any(not re.fullmatch(r"0x[0-9a-fA-F]{8}", f)
                                          for f in fields):
            raise RuntimeError(f"invalid D0 observer record: {line!r}")
        values = [int(field, 16) for field in fields]
        if kind == "BEGIN":
            if begun or values != [seconds, rate]:
                raise RuntimeError("D0 observer began a different capture")
            begun = True
            continue
        if not begun:
            continue
        if kind == "SAMPLE":
            tick, status, pc_low = values
            if not last_tick < tick < seconds * 1_000_000:
                raise RuntimeError("D0 observer sample timestamp is out of order or range")
            last_tick = tick
            pc = (((status >> 16) & 0xff) << 32) | pc_low
            samples.append({"at_us": tick, "pc": f"0x{pc:010x}",
                            "status": f"0x{status:08x}",
                            "halted": bool(status & (1 << 25)),
                            "low_power_mode": (status >> 4) & 3})
        elif kind == "HPM":
            if not with_hpm or counters is not None:
                raise RuntimeError("unexpected D0 counter record")
            mask = values[0]
            if mask & 3 != 3 or mask >> len(D0_HPM_EVENTS):
                raise RuntimeError("invalid D0 hardware counter mask")
            counters = {name: (values[2 * i + 1] << 32) | values[2 * i + 2]
                        for i, name in enumerate(D0_HPM_EVENTS) if mask & (1 << i)}
        else:
            elapsed, count, unstable = values
            if elapsed < seconds * 1_000_000 or count != len(samples):
                raise RuntimeError("D0 observer end record does not match received samples")
            if with_hpm and counters is None:
                raise RuntimeError("D0 capture ended without hardware counters")
            return elapsed / 1_000_000, samples, unstable, counters
    stage = "end of capture" if begun else "capture start"
    raise RuntimeError(f"D0 observer did not send the {stage}")


def d0_uart_lines(read_available: Callable[[], str], *, seconds: int) -> Iterator[str]:
    deadline = time.monotonic() + 5
    partial = ""
    while time.monotonic() < deadline:
        chunk = read_available()
        if not chunk:
            time.sleep(0.005)
            continue
        *lines, partial = (partial + chunk).split("\n")
        for line in lines:
            if line.startswith("BL808_D0_PROFILE_BEGIN "):
                deadline = time.monotonic() + seconds + 5
            yield line.strip()


def hotspot_counts(samples: list, symbols: list[tuple[int, int, str]]) -> list[dict]:
    starts = [start for start, _, _ in symbols]
    counts: Counter[tuple[str, bool]] = Counter()
    for sample in samples:
        pc = int(sample["pc"], 16)
        idx = bisect_right(starts, pc) - 1
        if idx >= 0 and pc < symbols[idx][1]:
            counts[(symbols[idx][2], True)] += 1
        else:
            counts[(sample["pc"], False)] += 1
    return [{"site": label, "symbol": matched, "samples": count,
             "sample_percent": round(100 * count / len(samples), 2)}
            for (label, matched), count in counts.most_common()]
