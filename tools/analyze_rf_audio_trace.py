#!/usr/bin/env python3
"""Compare timed RF SRAM power traces from silence and speaker playback."""

from __future__ import annotations

import argparse
import cmath
import json
import math
import statistics
from pathlib import Path


def load(path: Path) -> tuple[list[int], list[int]]:
    config = None
    frames = []
    for line in path.read_text().splitlines():
        if line.startswith("CSI CADENCE CONFIG "):
            config = [int(item, 16) for item in line.split()[3:]]
        elif line.startswith("CSI CADENCE CASE "):
            frames.append([int(item, 16) for item in line.split()[3:]])
    if config is None or len(config) != 10:
        raise ValueError(f"{path}: missing ten-field power configuration")
    words, tap, count, probe, stride, fast, timed, freq, power, samples = config
    if (words != 256 or tap != 1 or count != len(frames) or probe != 0 or
            stride != 1 or fast != 0 or timed != 1 or power != 1 or
            samples != 16 or not 2412 <= freq <= 2484):
        raise ValueError(f"{path}: unexpected power trace configuration")
    if any(len(frame) != 9 or frame[0] != index or frame[2] != 0 or
           frame[3] != 4 or frame[7] != 125 * index
           for index, frame in enumerate(frames)):
        raise ValueError(f"{path}: failed or mistimed capture frame")
    return config, [frame[8] for frame in frames]


def spectral_summary(values: list[float], sample_rate: int) -> dict[str, float | int]:
    count = len(values)
    mean = statistics.mean(values)
    windowed = [
        (value - mean) * (0.5 - 0.5 * math.cos(2 * math.pi * index / (count - 1)))
        for index, value in enumerate(values)
    ]
    bins = range(math.ceil(200 * count / sample_rate),
                 math.floor(400 * count / sample_rate) + 1)
    power = {
        bin_index: abs(sum(value * cmath.exp(-2j * math.pi * bin_index * index / count)
                           for index, value in enumerate(windowed))) ** 2
        for bin_index in bins
    }
    tone_bins = [index for index in bins
                 if 285 <= index * sample_rate / count <= 315]
    tone = max(tone_bins, key=power.__getitem__)
    top = max(power, key=power.__getitem__)
    return {
        "tone_bin_hz": tone * sample_rate / count,
        "tone_to_band_median": power[tone] / statistics.median(power.values()),
        "tone_rank_in_band": 1 + sum(value > power[tone] for value in power.values()),
        "band_bin_count": len(power),
        "strongest_band_hz": top * sample_rate / count,
    }


def summarize(path: Path) -> dict[str, object]:
    config, powers = load(path)
    median = statistics.median(powers)
    packet_bins = [max(powers[index:index + 8])
                   for index in range(0, len(powers), 8)]
    return {
        "path": str(path),
        "freq_mhz": config[7],
        "frames": len(powers),
        "duration_ms": len(powers) / 8,
        "median_power": median,
        "high_energy_frames_over_10x_median": sum(value > 10 * median for value in powers),
        "frame_log_spectrum": spectral_summary([math.log1p(value) for value in powers], 8000),
        "packet_bin_max_log_spectrum": spectral_summary(
            [math.log1p(value) for value in packet_bins], 1000),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("silent", type=Path)
    parser.add_argument("speaker", type=Path)
    args = parser.parse_args()
    silent = summarize(args.silent)
    speaker = summarize(args.speaker)
    if silent["freq_mhz"] != speaker["freq_mhz"] or silent["frames"] != speaker["frames"]:
        raise ValueError("traces have different channel or frame count")
    print(json.dumps({"silent": silent, "speaker": speaker}, indent=2))


if __name__ == "__main__":
    main()
