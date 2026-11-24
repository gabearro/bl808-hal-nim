#!/usr/bin/env python3
"""Audit packet CSI trace rate, spacing, gain, and repeated tone evidence."""

from __future__ import annotations

import argparse
import json
import math
import re
import statistics
from dataclasses import dataclass
from pathlib import Path


CONFIG = re.compile(r"RF PACKET TRACE CONFIG((?: [a-z_]+=(?:0x)?[0-9A-Fa-f]+)+)")
PACKET = re.compile(r"RF PACKET TRACE PACKET((?: 0x[0-9A-Fa-f]{8}){12})")
LTF_GAIN = re.compile(r"RF PACKET TRACE LTF GAIN((?: 0x[0-9A-Fa-f]{8}){12})")
FIELDS = (
    "index", "time_us", "attempt", "stf_corr_sq_milli", "ltf_score_sq_milli",
    "ltf_repeat_sq_milli", "gain_before", "gain_after", "mag_m16",
    "mag_m8", "mag_p8", "mag_p16",
)
MAGNITUDES = FIELDS[-4:]
LTF_GAIN_FIELDS = (
    "ltf_start_us", "ltf_end_us", "gain_samples", "gain_first_us",
    "gain_last_us", "gain_max_gap_us", "gain_unchanged_mask", "gain_riu03",
    "gain_rf", "gain_rc2", "gain_digital",
)
PACKET_RATE_GATE_HZ = 500
PACKET_P95_GAP_GATE_S = 0.002
TONE_RATE_GATE_HZ = 1000
TONE_P95_GAP_GATE_S = 0.001


@dataclass(frozen=True)
class Trace:
    path: Path
    config: dict[str, int]
    packets: list[dict[str, int]]


def load_trace(path: Path) -> Trace:
    lines = path.read_text(errors="replace").splitlines()
    if not any(line.strip() == "RF PACKET TRACE START" for line in lines):
        raise ValueError(f"{path}: missing start marker")
    if not any(line.strip() == "RF PACKET TRACE END" for line in lines):
        raise ValueError(f"{path}: missing end marker")
    configs = [CONFIG.fullmatch(line.strip()) for line in lines]
    configs = [match for match in configs if match]
    if len(configs) != 1:
        raise ValueError(f"{path}: expected one config")
    config = {key: int(value, 16) for key, value in
              re.findall(r" ([a-z_]+)=(0x[0-9A-Fa-f]+)", configs[0][1])}
    if config.get("failure") != 0 or config.get("probe_status") != 0 or config.get("probe_stride") != 1:
        raise ValueError(f"{path}: failed capture or stride probe")
    packets = []
    for line in lines:
        match = PACKET.fullmatch(line.strip())
        if match:
            values = [int(value, 16) for value in match[1].split()]
            packets.append(dict(zip(FIELDS, values)))
    if len(packets) != config.get("packets"):
        raise ValueError(f"{path}: packet count differs from config")
    if any(p["index"] != index for index, p in enumerate(packets)):
        raise ValueError(f"{path}: nonsequential packet index")
    gain_rows = []
    for line in lines:
        if line.strip().startswith("RF PACKET TRACE LTF GAIN"):
            match = LTF_GAIN.fullmatch(line.strip())
            if not match:
                raise ValueError(f"{path}: malformed LTF gain record")
            gain_rows.append([int(value, 16) for value in match[1].split()])
    if config.get("ltf_gain_trace") == 1:
        if [row[0] for row in gain_rows] != list(range(len(packets))):
            raise ValueError(f"{path}: expected one ordered LTF gain record per packet")
        for packet, row in zip(packets, gain_rows):
            packet.update(zip(LTF_GAIN_FIELDS, row[1:]))
    elif gain_rows:
        raise ValueError(f"{path}: LTF gain records without config marker")
    times = [p["time_us"] for p in packets]
    if times != sorted(times) or any(t > config["elapsed_us"] for t in times):
        raise ValueError(f"{path}: invalid packet timestamps")
    return Trace(path, config, packets)


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lo = math.floor(position)
    hi = math.ceil(position)
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (position - lo)


def summarize(trace: Trace) -> dict:
    c = trace.config
    times = [p["time_us"] / 1e6 for p in trace.packets]
    gaps = [b - a for a, b in zip(times, times[1:])]
    elapsed = c["elapsed_us"] / 1e6
    mean_gap = statistics.mean(gaps) if gaps else None
    stable_packets = [p for p in trace.packets
                      if p["gain_before"] == p["gain_after"]]
    stable_times = [p["time_us"] / 1e6 for p in stable_packets]
    stable_gaps = [b - a for a, b in zip(stable_times, stable_times[1:])]
    stable_rate = len(stable_packets) / elapsed
    stable_p95 = percentile(stable_gaps, 0.95)
    result = {
        "path": str(trace.path),
        "duration_s": elapsed,
        "attempts": c["attempts"],
        "burst_candidates": c.get("burst_candidates"),
        "stf_candidates": c["stf_candidates"],
        "packets": len(times),
        "decoded_packets_per_s": len(times) / elapsed,
        "stable_gain_packets": len(stable_packets),
        "stable_gain_packets_per_s": stable_rate,
        "median_gap_ms": 1e3 * statistics.median(gaps) if gaps else None,
        "p95_gap_ms": 1e3 * percentile(gaps, 0.95) if gaps else None,
        "max_gap_ms": 1e3 * max(gaps) if gaps else None,
        "gap_cv": statistics.pstdev(gaps) / mean_gap if mean_gap and len(gaps) > 1 else None,
        "stable_gain_p95_gap_ms": 1e3 * stable_p95 if stable_p95 else None,
        "packet_rate_gate_met": len(times) / elapsed >= PACKET_RATE_GATE_HZ and
            len(gaps) >= 2 and percentile(gaps, 0.95) <= PACKET_P95_GAP_GATE_S,
        "tone_cadence_gate_met": stable_rate >= TONE_RATE_GATE_HZ and
            len(stable_gaps) >= 2 and stable_p95 <= TONE_P95_GAP_GATE_S,
    }
    if c.get("ltf_gain_trace") == 1:
        covered = [p for p in trace.packets if p["gain_samples"] >= 2]
        result["ltf_gain"] = {
            "packets_with_bracketed_ltf": len(covered),
            "max_poll_gap_us": max((p["gain_max_gap_us"] for p in covered), default=None),
            "packets_with_unchanged_readouts": sum(
                p["gain_unchanged_mask"] == 0xF for p in covered),
            "packets_with_unchanged_readouts_and_gap_at_most_2us": sum(
                p["gain_unchanged_mask"] == 0xF and p["gain_max_gap_us"] <= 2
                for p in covered),
            "calibrated": False,
        }
    return result


def spectrum(trace: Trace, field: str) -> dict:
    """Use timestamped coherent projection; only call after the rate gate."""
    packets = [p for p in trace.packets if p["gain_before"] == p["gain_after"]]
    times = [p["time_us"] / 1e6 for p in packets]
    values = [math.log1p(p[field]) for p in packets]
    mean_t, mean_v = statistics.mean(times), statistics.mean(values)
    centered_t = [t - mean_t for t in times]
    centered_v = [v - mean_v for v in values]
    slope = sum(t * v for t, v in zip(centered_t, centered_v)) / sum(t * t for t in centered_t)
    residual = [v - slope * t for t, v in zip(centered_t, centered_v)]
    amplitudes = {}
    for frequency in range(200, 401):
        re = sum(v * math.cos(2 * math.pi * frequency * t)
                 for v, t in zip(residual, times))
        im = sum(v * math.sin(2 * math.pi * frequency * t)
                 for v, t in zip(residual, times))
        amplitudes[frequency] = math.hypot(re, im) / len(times)
    noise = statistics.median(amplitudes.values())
    peak = max(amplitudes, key=amplitudes.get)
    return {
        "peak_hz": peak,
        "peak_to_band_median": amplitudes[peak] / noise if noise else None,
        "ratio_300": amplitudes[300] / noise if noise else None,
        "ratio_330": amplitudes[330] / noise if noise else None,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--silent", type=Path, nargs="+", required=True)
    parser.add_argument("--tone300", type=Path, nargs="+")
    parser.add_argument("--tone330", type=Path, nargs="+")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    groups = {name: paths for name, paths in
              (("silent", args.silent), ("tone300", args.tone300), ("tone330", args.tone330))
              if paths}
    if args.tone300 and args.tone330 and any(len(paths) < 5 for paths in groups.values()):
        parser.error("a full sound comparison requires five runs per condition")
    try:
        result = {name: [summarize(load_trace(path)) for path in paths]
                  for name, paths in groups.items()}
    except (OSError, ValueError) as exc:
        parser.error(str(exc))
    result["all_rate_gates_met"] = all(
        row["packet_rate_gate_met"] for runs in result.values()
        if isinstance(runs, list) for row in runs)
    result["tone_test_interpretable"] = (
        len(groups) == 3 and all(len(paths) >= 5 for paths in groups.values())
        and all(row["tone_cadence_gate_met"] for runs in result.values()
                if isinstance(runs, list) for row in runs)
    )
    result["tone_line_moves_in_every_repeat"] = False
    if result["tone_test_interpretable"]:
        traces = {name: [load_trace(path) for path in paths]
                  for name, paths in groups.items()}
        spectral = {name: [{field: spectrum(trace, field) for field in MAGNITUDES}
                           for trace in runs] for name, runs in traces.items()}
        result["spectra"] = spectral
        result["tone_line_moves_in_every_repeat"] = any(
            all(abs(run[field]["peak_hz"] - 300) <= 3 and
                run[field]["ratio_300"] >= 3 for run in spectral["tone300"])
            and all(abs(run[field]["peak_hz"] - 330) <= 3 and
                    run[field]["ratio_330"] >= 3 for run in spectral["tone330"])
            and all(run[field]["ratio_300"] < 3 and
                    run[field]["ratio_330"] < 3 for run in spectral["silent"])
            for field in MAGNITUDES
        )
    text = json.dumps(result, indent=2) + "\n"
    if args.output:
        args.output.write_text(text)
    else:
        print(text, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
