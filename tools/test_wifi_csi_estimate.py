import cmath
import json
import math
import random
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from wifi_csi_estimate import (
    Capture,
    CsiError,
    LTF_TONES,
    decode_iq,
    estimate_capture,
    parse_uart_log,
)


def synthetic_capture(*, cfo_hz=73_000, channel=0.7 + 0.3j,
                      echo=0j):
    rng = random.Random(808)
    stf = [cmath.exp(2j * math.pi * n / 32) for n in range(320)]
    ltf = [
        sum(value * cmath.exp(2j * math.pi * k * n / 128)
            for k, value in LTF_TONES.items()) / 64
        for n in range(128)
    ]
    packet = stf + ltf[-64:] + ltf + ltf
    waveform = [0j] * 120 + packet + [0j] * 300
    words = []
    for n, value in enumerate(waveform):
        noise = complex(rng.gauss(0, 1), rng.gauss(0, 1))
        delayed = waveform[n - 2] if n >= 2 else 0j
        received = ((value * channel + delayed * echo) * 800 + noise) * cmath.exp(
            2j * math.pi * cfo_hz * n / 40_000_000
        )
        i = round(received.real)
        q = round(received.imag)
        assert -2048 < i < 2048 and -2048 < q < 2048
        words.append(((i & 0xFFFF) << 16) | (q & 0xFFFF))
    metadata = {
        "version": 1,
        "status": 0,
        "freq_mhz": 2412,
        "tap": 1,
        "rate_hz_nominal": 40_000_000,
        "start_index": 0x2000,
        "base": 0x22028000,
        "words": len(words),
        "memory_words": len(words),
        "stride_words": 1,
        "probe_status": 0,
        "probe_stride": 1,
        "probe_end_extra": 0,
        "changed": len(words),
        "stray": 0,
        "end_extra": 0,
        "ctrl_before": 0,
        "ctrl_done": 1,
        "status_done": 0,
    }
    raw_hash = 0x811C9DC5
    for word in words:
        raw_hash = ((raw_hash ^ word) * 0x01000193) & 0xFFFFFFFF
    metadata["raw_fnv32"] = raw_hash
    return Capture(metadata, words)


class CsiEstimateTests(unittest.TestCase):
    def test_known_flat_channel_and_cfo(self):
        capture = synthetic_capture()
        result = estimate_capture(capture)
        self.assertEqual(len(result["tones"]), 52)
        self.assertEqual([entry["tone"] for entry in result["tones"]],
                         list(range(-26, 0)) + list(range(1, 27)))
        self.assertLess(abs(result["cfo_hz"] - 73_000), 4_000)
        self.assertGreater(result["ltf_repeat_score"], 0.95)
        values = [complex(entry["real"], entry["imag"]) for entry in result["tones"]]
        mean = sum(values) / len(values)
        self.assertGreater(abs(mean), 300)
        self.assertLess(max(abs(value / mean - 1) for value in values), 0.18)
        self.assertEqual(len(result["raw_words_hex"]), len(capture.words))

    def test_parser_rejects_truncated_and_failed_frames(self):
        capture = synthetic_capture()
        fields = " ".join(f"{key}=0x{value:X}" for key, value in capture.metadata.items())
        lines = [f"CSI1 BEGIN {fields}"]
        lines += [f"CSI1 WORD 0x{index:08X} 0x{word:08X}"
                  for index, word in enumerate(capture.words)]
        lines.append("CSI1 END")
        self.assertEqual(parse_uart_log("\n".join(lines)).words, capture.words)
        with self.assertRaisesRegex(CsiError, "incomplete"):
            parse_uart_log("\n".join(lines[:-2] + ["CSI1 END"]))
        with self.assertRaisesRegex(CsiError, "follows"):
            parse_uart_log("\n".join(lines[:1] + lines[2:]))
        with self.assertRaisesRegex(CsiError, "did not complete"):
            parse_uart_log("\n".join(lines).replace("status=0x0", "status=0x4"))
        corrupted = list(lines)
        corrupted[5] = corrupted[5][:-1] + ("F" if corrupted[5][-1] != "F" else "E")
        with self.assertRaisesRegex(CsiError, "checksum mismatch"):
            parse_uart_log("\n".join(corrupted))

    def test_known_two_path_frequency_response(self):
        h0, h1 = 0.75 + 0.1j, 0.18 - 0.13j
        result = estimate_capture(synthetic_capture(channel=h0, echo=h1))
        values = {entry["tone"]: complex(entry["real"], entry["imag"])
                  for entry in result["tones"]}
        reference = values[1] / (h0 + h1 * cmath.exp(-2j * math.pi / 64))
        errors = [
            abs(values[k] / reference -
                (h0 + h1 * cmath.exp(-2j * math.pi * k / 64)))
            for k in values
        ]
        self.assertLess(max(errors), 0.23)

    def test_strided_memory_preserves_raw_gaps(self):
        capture = synthetic_capture()
        interleaved = [word for sample in capture.words
                       for word in (sample, 0xA5A0055A)]
        metadata = dict(capture.metadata, memory_words=len(interleaved),
                        stride_words=2, probe_stride=2)
        result = estimate_capture(Capture(metadata, interleaved))
        self.assertEqual(len(result["tones"]), 52)
        self.assertEqual(result["raw_words_hex"][1], "0xA5A0055A")

    def test_sample_width_and_iq_order(self):
        word = ((-3 & 0x0FFF) << 16) | (5 & 0x0FFF)
        self.assertEqual(decode_iq([word], "iq", 12), [-3 + 5j])
        self.assertEqual(decode_iq([word], "qi", 12), [5 - 3j])

    def test_cli_reads_uart_log_and_writes_json(self):
        capture = synthetic_capture()
        fields = " ".join(f"{key}=0x{value:X}" for key, value in capture.metadata.items())
        lines = [f"CSI1 BEGIN {fields}"]
        lines += [f"CSI1 WORD 0x{index:08X} 0x{word:08X}"
                  for index, word in enumerate(capture.words)]
        lines.append("CSI1 END")
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "capture.uart.log"
            output = Path(directory) / "csi.json"
            source.write_text("\n".join(lines) + "\n")
            subprocess.run([sys.executable, str(Path(__file__).with_name("wifi_csi_estimate.py")),
                            str(source), "--output", str(output)], check=True)
            result = json.loads(output.read_text())
        self.assertEqual(len(result["tones"]), 52)
        self.assertEqual(len(result["raw_words_hex"]), len(capture.words))

    def test_rejects_noise_without_preamble(self):
        rng = random.Random(808)
        capture = synthetic_capture()
        words = [((rng.randrange(-10, 11) & 0xFFFF) << 16) |
                 (rng.randrange(-10, 11) & 0xFFFF) for _ in capture.words]
        with self.assertRaises(CsiError):
            estimate_capture(Capture(capture.metadata, words))


if __name__ == "__main__":
    unittest.main()
