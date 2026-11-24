#!/usr/bin/env python3
"""Estimate legacy 20 MHz OFDM CSI from a BL808 CSI1 raw I/Q UART frame.

No BL808 I/Q format or sample rate has yet been confirmed on hardware. The
defaults are hypotheses from the BL618 SDR sample, recorded in the output.
"""

from __future__ import annotations

import argparse
import cmath
import json
import math
import re
from dataclasses import dataclass
from pathlib import Path


# IEEE 802.11a-1999, Eq. (8), ordered from tone -26 through +26.
LTF_LEFT = (
    1, 1, -1, -1, 1, 1, -1, 1, -1, 1, 1, 1, 1,
    1, 1, -1, -1, 1, 1, -1, 1, -1, 1, 1, 1, 1,
)
LTF_RIGHT = (
    1, -1, -1, 1, 1, -1, 1, -1, 1, -1, -1, -1, -1,
    -1, 1, 1, -1, -1, 1, -1, 1, -1, 1, 1, 1, 1,
)
LTF_TONES = {k: value for k, value in zip(range(-26, 0), LTF_LEFT)}
LTF_TONES.update({k: value for k, value in zip(range(1, 27), LTF_RIGHT)})
LTF_TIME = tuple(
    sum(value * cmath.exp(2j * math.pi * k * n / 64)
        for k, value in LTF_TONES.items()) / 64
    for n in range(64)
)
LTF_ENERGY = sum(abs(v) ** 2 for v in LTF_TIME)

BEGIN = re.compile(r"CSI1 BEGIN((?:\s+[a-z_][a-z_0-9]*=0x[0-9a-fA-F]+)+)\s*$")
WORD = re.compile(r"CSI1 WORD (0x[0-9a-fA-F]+) (0x[0-9a-fA-F]+)\s*$")


class CsiError(ValueError):
    pass


@dataclass(frozen=True)
class Capture:
    metadata: dict[str, int]
    words: list[int]


def parse_uart_log(text: str) -> Capture:
    metadata: dict[str, int] | None = None
    words: list[int] = []
    finished = False
    for line in text.splitlines():
        line = line.strip()
        begin = BEGIN.fullmatch(line)
        if begin:
            if metadata is not None:
                raise CsiError("multiple CSI1 frames")
            metadata = dict(
                (key, int(value, 16))
                for key, value in re.findall(r"([a-z_][a-z_0-9]*)=(0x[0-9a-fA-F]+)", begin[1])
            )
            if metadata.get("version") != 1:
                raise CsiError("unsupported CSI1 version")
            if metadata.get("status") != 0 or metadata.get("changed", 0) == 0:
                raise CsiError("capture did not complete with changed data")
            if not (256 <= metadata.get("words", 0) <= 8192):
                raise CsiError("invalid capture length")
            stride = metadata.get("stride_words", 0)
            if (stride not in (1, 2, 4, 8) or
                    metadata.get("memory_words") != metadata["words"] * stride or
                    metadata.get("probe_status") != 0 or
                    metadata.get("probe_stride") != stride or
                    metadata.get("stray", 0) > 4):
                raise CsiError("invalid or unverified capture stride")
            continue
        word = WORD.fullmatch(line)
        if word:
            if metadata is None or finished:
                raise CsiError("word outside CSI1 frame")
            index, value = int(word[1], 16), int(word[2], 16)
            if index != len(words):
                raise CsiError(f"word index {index} follows {len(words)}")
            words.append(value)
            continue
        if line == "CSI1 END":
            if metadata is None or finished:
                raise CsiError("unexpected CSI1 END")
            finished = True
    if metadata is None or not finished or len(words) != metadata["memory_words"]:
        raise CsiError("incomplete CSI1 frame")
    if metadata.get("base") != 0x22028000 or metadata.get("start_index") != 0x2000:
        raise CsiError("unexpected RF SRAM destination")
    raw_hash = 0x811C9DC5
    for word in words:
        raw_hash = ((raw_hash ^ word) * 0x01000193) & 0xFFFFFFFF
    if raw_hash != metadata.get("raw_fnv32"):
        raise CsiError("raw word checksum mismatch")
    return Capture(metadata, words)


def decode_iq(words: list[int], order: str = "iq", bits: int = 16) -> list[complex]:
    if order not in ("iq", "qi"):
        raise CsiError("I/Q order must be iq or qi")
    if bits not in (11, 12, 16):
        raise CsiError("sample width must be 11, 12, or 16 bits")
    mask = (1 << bits) - 1
    sign = 1 << (bits - 1)
    result = []
    for word in words:
        high, low = (word >> 16) & mask, word & mask
        if high & sign:
            high -= 1 << bits
        if low & sign:
            low -= 1 << bits
        i, q = (high, low) if order == "iq" else (low, high)
        result.append(complex(i, q))
    return result


def decimate_to_20mhz(samples: list[complex], rate_hz: int) -> list[complex]:
    if rate_hz not in (20_000_000, 40_000_000, 80_000_000):
        raise CsiError("only 20, 40, or 80 MS/s input is supported")
    factor = rate_hz // 20_000_000
    if factor == 1:
        return samples
    radius = 12 * factor
    cutoff = 0.45 / factor
    taps = []
    for j in range(-radius, radius + 1):
        sinc = 2 * cutoff if j == 0 else math.sin(2 * math.pi * cutoff * j) / (math.pi * j)
        window = 0.5 + 0.5 * math.cos(math.pi * j / radius)
        taps.append(sinc * window)
    scale = sum(taps)
    taps = [tap / scale for tap in taps]
    return [
        sum(samples[center + offset] * tap
            for offset, tap in zip(range(-radius, radius + 1), taps))
        for center in range(radius, len(samples) - radius, factor)
    ]


def _dot(a: list[complex] | tuple[complex, ...], b: list[complex]) -> complex:
    return sum(x.conjugate() * y for x, y in zip(a, b))


def _power(samples: list[complex]) -> float:
    return sum(abs(v) ** 2 for v in samples)


def _stf_runs(samples: list[complex], min_corr: float = 0.82) -> list[tuple[int, int, complex]]:
    powers = sorted(abs(v) ** 2 for v in samples)
    floor = max(powers[len(powers) // 10], 1e-8)
    hits: list[tuple[int, complex]] = []
    for start in range(len(samples) - 80):
        a, b = samples[start:start + 64], samples[start + 16:start + 80]
        ea, eb = _power(a), _power(b)
        if min(ea, eb) < 64 * floor * 2:
            continue
        p = _dot(a, b)
        if abs(p) / math.sqrt(ea * eb) >= min_corr:
            hits.append((start, p))
    runs: list[tuple[int, int, complex]] = []
    for start, p in hits:
        if runs and start <= runs[-1][1] + 2:
            first, _, total = runs[-1]
            runs[-1] = (first, start, total + p)
        else:
            runs.append((start, start, p))
    return [run for run in runs if run[1] - run[0] >= 12]


def _fft64(symbol: list[complex]) -> list[complex]:
    return [
        sum(value * cmath.exp(-2j * math.pi * k * n / 64)
            for n, value in enumerate(symbol))
        for k in range(64)
    ]


def estimate_20mhz(samples: list[complex], stf_min_corr: float = 0.82) -> dict:
    if len(samples) < 320:
        raise CsiError("too few 20 MS/s samples for a complete preamble")
    mean = sum(samples) / len(samples)
    samples = [v - mean for v in samples]
    if not 0.5 <= stf_min_corr <= 0.95:
        raise CsiError("STF correlation threshold must be between 0.5 and 0.95")
    runs = _stf_runs(samples, stf_min_corr)
    if not runs:
        raise CsiError("no 16-sample short-training repetition")

    candidates = []
    for first, last, phase_sum in runs:
        coarse_hz = cmath.phase(phase_sum) * 20_000_000 / (2 * math.pi * 16)
        corrected = [
            value * cmath.exp(-2j * math.pi * coarse_hz * n / 20_000_000)
            for n, value in enumerate(samples)
        ]
        low = max(first + 112, 32)
        high = min(last + 248, len(samples) - 128)
        for start in range(low, high + 1):
            a = corrected[start:start + 64]
            b = corrected[start + 64:start + 128]
            ea, eb = _power(a), _power(b)
            if min(ea, eb) < 1e-8:
                continue
            c1, c2 = _dot(LTF_TIME, a), _dot(LTF_TIME, b)
            score = (abs(c1) / math.sqrt(LTF_ENERGY * ea) +
                     abs(c2) / math.sqrt(LTF_ENERGY * eb)) / 2
            repeat = abs(_dot(a, b)) / math.sqrt(ea * eb)
            candidates.append((score * repeat, score, repeat, start, coarse_hz, corrected))
    if not candidates:
        raise CsiError("no complete long training field")
    _, score, repeat, start, coarse_hz, corrected = max(candidates, key=lambda row: row[0])
    if score < 0.55 or repeat < 0.80:
        raise CsiError(f"LTF quality too low (template={score:.3f}, repeat={repeat:.3f})")

    a = corrected[start:start + 64]
    b = corrected[start + 64:start + 128]
    fine_hz = cmath.phase(_dot(a, b)) * 20_000_000 / (2 * math.pi * 64)
    corrected = [
        value * cmath.exp(-2j * math.pi * fine_hz * n / 20_000_000)
        for n, value in enumerate(corrected)
    ]
    fft_a = _fft64(corrected[start:start + 64])
    fft_b = _fft64(corrected[start + 64:start + 128])
    tones = []
    for tone in sorted(LTF_TONES):
        index = tone % 64
        h = (fft_a[index] + fft_b[index]) / (2 * LTF_TONES[tone])
        tones.append({"tone": tone, "real": h.real, "imag": h.imag})
    return {
        "sample_rate_hz": 20_000_000,
        "ltf_start_sample": start,
        "cfo_hz": coarse_hz + fine_hz,
        "stf_runs": len(runs),
        "ltf_template_score": score,
        "ltf_repeat_score": repeat,
        "tones": tones,
    }


def estimate_capture(capture: Capture, *, sample_rate_hz: int | None = None,
                     iq_order: str = "iq", sample_bits: int = 16,
                     stf_min_corr: float = 0.82) -> dict:
    rate = sample_rate_hz or capture.metadata.get("rate_hz_nominal", 0)
    stride = capture.metadata.get("stride_words", 0)
    if stride not in (1, 2, 4, 8) or len(capture.words) != capture.metadata.get("words", 0) * stride:
        raise CsiError("capture memory does not match observed stride")
    sample_words = capture.words[::stride]
    samples = decimate_to_20mhz(decode_iq(sample_words, iq_order, sample_bits), rate)
    result = estimate_20mhz(samples, stf_min_corr)
    result["input_metadata"] = capture.metadata
    result["input_rate_hz"] = rate
    result["iq_order"] = iq_order
    result["sample_bits"] = sample_bits
    result["stf_min_corr"] = stf_min_corr
    result["raw_words_hex"] = [f"0x{word:08X}" for word in capture.words]
    result["hardware_format_verified"] = False
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("uart_log", type=Path)
    parser.add_argument("--output", type=Path, help="write JSON here instead of stdout")
    parser.add_argument("--sample-rate-hz", type=int,
                        help="override provisional rate in capture metadata")
    parser.add_argument("--iq-order", choices=("iq", "qi"), default="iq")
    parser.add_argument("--sample-bits", type=int, choices=(11, 12, 16), default=16)
    parser.add_argument("--stf-min-corr", type=float, default=0.82,
                        help="minimum normalized STF repetition; default 0.82")
    args = parser.parse_args()
    try:
        capture = parse_uart_log(args.uart_log.read_text(errors="replace"))
        result = estimate_capture(capture, sample_rate_hz=args.sample_rate_hz,
                                  iq_order=args.iq_order,
                                  sample_bits=args.sample_bits,
                                  stf_min_corr=args.stf_min_corr)
    except CsiError as exc:
        parser.error(str(exc))
    payload = json.dumps(result, indent=2) + "\n"
    if args.output:
        args.output.write_text(payload)
    else:
        print(payload, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
