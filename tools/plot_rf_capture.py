"""Plot verified CSI1 RF SRAM dumps as raw I/Q candidate waveforms."""

from __future__ import annotations

import argparse
from pathlib import Path
import re

import matplotlib.pyplot as plt
import numpy as np


WORD = re.compile(r"^CSI1 WORD 0x([0-9A-Fa-f]{8}) 0x([0-9A-Fa-f]{8})$", re.M)
FIELD = re.compile(r"([a-z_0-9]+)=0x([0-9A-Fa-f]+)")


def load_frame(path: Path) -> tuple[dict[str, int], np.ndarray, np.ndarray]:
    text = path.read_text()
    header = next((line for line in text.splitlines() if line.startswith("CSI1 BEGIN ")), None)
    if header is None or "CSI1 END" not in text:
        raise ValueError(f"{path}: incomplete CSI1 frame")
    fields = {key: int(value, 16) for key, value in FIELD.findall(header)}
    pairs = [(int(index, 16), int(word, 16)) for index, word in WORD.findall(text)]
    if fields.get("status") != 0 or len(pairs) != fields.get("memory_words"):
        raise ValueError(f"{path}: capture status or word count is invalid")
    if any(index != expected for expected, (index, _) in enumerate(pairs)):
        raise ValueError(f"{path}: sample indices are not consecutive")
    checksum = 0x811C9DC5
    for _, word in pairs:
        checksum = ((checksum ^ word) * 0x01000193) & 0xFFFFFFFF
    if checksum != fields.get("raw_fnv") and checksum != fields.get("raw_fnv32"):
        raise ValueError(f"{path}: FNV32 mismatch")
    words = np.array([word for _, word in pairs], dtype=np.uint32)
    i = (words >> 16).astype(np.uint16).view(np.int16).astype(np.float64)
    q = (words & 0xFFFF).astype(np.uint16).view(np.int16).astype(np.float64)
    return fields, i, q


def spectrum(i: np.ndarray, q: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    z = (i - i.mean()) + 1j * (q - q.mean())
    size = 512
    hop = size // 2
    window = np.hanning(size)
    spectra = []
    for start in range(0, len(z) - size + 1, hop):
        transformed = np.fft.fftshift(np.fft.fft(z[start:start + size] * window))
        spectra.append(np.abs(transformed) ** 2)
    mean_power = np.mean(spectra, axis=0)
    relative_db = 10 * np.log10(np.maximum(mean_power, 1e-20) / mean_power.max())
    cycles_per_sample = np.fft.fftshift(np.fft.fftfreq(size))
    return cycles_per_sample, relative_db


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tap0", type=Path)
    parser.add_argument("tap1", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    plt.style.use("seaborn-v0_8-whitegrid")
    fig, axes = plt.subplots(2, 3, figsize=(16, 9), layout="constrained")
    fig.suptitle("BL808 RF SRAM raw capture · tuned to 2412 MHz · sample clock unverified", fontsize=18, weight="bold")
    for row, path in enumerate((args.tap0, args.tap1)):
        fields, i, q = load_frame(path)
        tap = fields["tap"]
        first = min(512, len(i))
        sample_index = np.arange(first)

        wave, scatter, power = axes[row]
        wave.plot(sample_index, i[:first], lw=1.0, color="#136f9a", label="upper halfword (I candidate)")
        wave.plot(sample_index, q[:first], lw=1.0, color="#d07832", label="lower halfword (Q candidate)")
        wave.set_title(f"Tap {tap} · first {first} raw words")
        wave.set_xlabel("Sample index")
        wave.set_ylabel("Signed 16-bit code")
        wave.legend(fontsize=8, loc="upper right")

        scatter.hexbin(i, q, gridsize=40, mincnt=1, cmap="viridis", linewidths=0)
        scatter.set_title(f"Tap {tap} · candidate I/Q density")
        scatter.set_xlabel("Upper halfword")
        scatter.set_ylabel("Lower halfword")

        cycles_per_sample, relative_db = spectrum(i, q)
        power.plot(cycles_per_sample, relative_db, lw=1.2, color="#5a3f91")
        power.set_title(f"Tap {tap} · averaged spectrum")
        power.set_xlabel("Normalized frequency (cycles/sample)")
        power.set_ylabel("Relative power (dB)")
        power.set_ylim(-55, 3)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(args.output, dpi=180, facecolor="white")
    plt.close(fig)
    print(args.output)


if __name__ == "__main__":
    main()
