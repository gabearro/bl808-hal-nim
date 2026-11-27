"""Check the host decoder at the capture ring and histogram boundaries."""

import importlib.util
from pathlib import Path
import struct

import pytest

from bl808_pc_profile import D0_HPM_EVENTS, hotspot_counts, read_d0_capture, scan_value


TOOL = (Path(__file__).resolve().parents[1] /
        "examples/freenetradio/tools/profile_radio.py")
spec = importlib.util.spec_from_file_location("profile_radio", TOOL)
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)


@pytest.mark.parametrize("version", [1, 2, 3])
def test_decoder_recovers_wrapped_trace_and_wait_bounds(version):
    # The next write goes into slot one, so the oldest
    # surviving event is in slot one. A completed span can start before it.
    irq_count = 80 if version >= 2 else 0
    raw = bytearray(struct.pack("<4s17I", b"BPRF", version, 2, 50000, 5000, 20,
                                15, 3, 3, 1, 1, 1, 1, 22000, 4500, 15000, 0, irq_count))
    for index in range(15):
        raw.extend(struct.pack("<4Q4I", *(
            (2000, 320000, 120000, 300000, 3, 2, 1100, 2) if index == 12 else (0,) * 8
        )))
    for vector in range(irq_count):
        raw.extend(struct.pack("<4Q4I", *(
            (10, 1600, 500, 0, 1, 0, 10, 0) if vector in (43, 79) else (0,) * 8
        )))
    raw.extend(struct.pack("<15I", 99, *([0] * 13), 1))
    raw.extend(struct.pack("<15I", 98, *([0] * 13), 2))
    raw.extend(struct.pack("<IIIHH", 22000, 0, 15000, 4, 1))
    raw.extend(struct.pack("<IIIHH", 5000, 0, 4500, 3, 0))
    raw.extend(struct.pack("<IIIHH", 4000, 1500, 0, 1, 10))

    if version == 3:
        counters = [0x100000000 + i for i in range(len(profile.M0_HPM_EVENTS))]
        raw.extend(profile.HPM.pack(*counters, (1 << len(counters)) - 1))

    summary, events = profile.decode_capture(raw)
    assert summary["trace"]["trigger"] == "late_audio"
    assert summary["trace"]["overwritten"] == 1
    assert summary["waits"]["sleep"]["p99_us"] == 0
    assert summary["waits"]["yield"]["p99_us"] == ">80000"
    assert summary["regions"][12]["cycles_with_work"] == 300000
    if version >= 2:
        assert summary["regions"][-1]["cycles"] == 3200
        assert [row["vector"] for row in summary["irqs"]] == [43, 79]
    if version == 3:
        assert tuple(summary["hardware_counters"]) == D0_HPM_EVENTS[:-3]
        assert summary["hardware_counters"]["cycles"] == 0x100000000
    else:
        assert "hardware_counters" not in summary
    assert [event[0] for event in events] == [4000, 5000, 22000]
    trace = profile.perfetto_trace(events)["traceEvents"]
    assert [(entry["ph"], entry["ts"]) for entry in trace if "ts" in entry] == [
        ("X", 4000), ("C", 5000), ("i", 22000)]

    with pytest.raises(ValueError, match="size or ring cursor"):
        profile.decode_capture(raw[:-1])
    struct.pack_into("<I", raw, 9 * 4, 2)
    with pytest.raises(ValueError, match="size or ring cursor"):
        profile.decode_capture(raw)


def test_live_profile_symbol_lookup_preserves_unmatched_pcs():
    reply = "m0_profile_pc\r\n\x00BL808_PROFILE_PC 0x58000004\r\n>"
    assert scan_value(reply, "BL808_PROFILE_PC") == 0x58000004
    with pytest.raises(RuntimeError, match="OpenOCD did not return"):
        scan_value("m0_profile_pc\r\n>", "BL808_PROFILE_PC")

    samples = [{"pc": pc} for pc in ["0x58000004", "0x5800000e", "0x58000010"]]
    symbols = [(0x58000000, 0x58000010, "example")]
    assert hotspot_counts(samples, symbols) == [
        {"site": "example", "symbol": True, "samples": 2, "sample_percent": 66.67},
        {"site": "0x58000010", "symbol": False, "samples": 1, "sample_percent": 33.33},
    ]


D0_BEGIN = "BL808_D0_PROFILE_BEGIN 0x00000001 0x0000001e"
D0_SAMPLE = "BL808_D0_PROFILE_SAMPLE 0x00000400 0x02ab0030 0x01234568"
D0_END = "BL808_D0_PROFILE_END 0x000f4242 0x00000001 0x00000002"


def test_d0_capture_recovers_pcs_and_64_bit_counters():
    hpm = "BL808_D0_PROFILE_HPM 0x00001003" + " 0x00000001 0x00000002" * len(D0_HPM_EVENTS)
    elapsed, samples, unstable, counters = read_d0_capture(
        ["BL808_D0_PROFILE_READY", D0_BEGIN, D0_SAMPLE, hpm, D0_END],
        seconds=1, rate=30, with_hpm=True)
    assert elapsed == 1.000002
    assert samples == [{"at_us": 1024, "pc": "0xab01234568", "status": "0x02ab0030",
                        "halted": True, "low_power_mode": 3}]
    assert unstable == 2
    assert counters == dict.fromkeys((*D0_HPM_EVENTS[:2], D0_HPM_EVENTS[-1]), 0x100000002)
    assert read_d0_capture([D0_BEGIN, D0_SAMPLE, D0_END], seconds=1, rate=30)[3] is None


@pytest.mark.parametrize("records, with_hpm, error", [
    ([D0_BEGIN, D0_SAMPLE], False, "end of capture"),
    ([D0_BEGIN, D0_END], False, "does not match"),
    ([D0_BEGIN, D0_SAMPLE, D0_SAMPLE], False, "timestamp"),
    ([D0_BEGIN, D0_SAMPLE, D0_END], True, "without hardware counters"),
])
def test_d0_capture_rejects_incomplete_data(records, with_hpm, error):
    with pytest.raises(RuntimeError, match=error):
        read_d0_capture(records, seconds=1, rate=30, with_hpm=with_hpm)
