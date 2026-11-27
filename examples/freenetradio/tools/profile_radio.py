#!/usr/bin/env python3
"""Capture and inspect FreeNetRadio's M0 profiling data."""

import argparse
import http.client
import json
from pathlib import Path
import struct
import sys
import time
from urllib.error import HTTPError
from urllib.request import Request, urlopen


HEADER = struct.Struct("<4s17I")
TOTALS = struct.Struct("<4Q4I")
EVENT = struct.Struct("<IIIHH")
WAIT_BOUNDS_US = (0, 50, 100, 250, 500, 1000, 2000, 4000, 8000,
                  12000, 15000, 20000, 40000, 80000)
HISTOGRAM = struct.Struct(f"<{len(WAIT_BOUNDS_US) + 1}I")
M0_HPM_EVENTS = (
    "cycles", "instructions_retired", "l1i_accesses", "l1i_misses",
    "conditional_branch_mispredictions", "conditional_branches",
    "l1d_read_accesses", "l1d_read_misses", "l1d_write_accesses", "l1d_write_misses",
)
HPM = struct.Struct(f"<{len(M0_HPM_EVENTS)}QI4x")
REGIONS = (
    "Audio step", "MP3 decode", "Display draw", "Display flush start",
    "Display flush end", "Stream step", "HTTP step", "Controls", "NTP",
    "Network task", "Wi-Fi service", "Wi-Fi backend", "Wi-Fi firmware",
    "Wi-Fi deferred TX", "IRQ handlers",
)
WORK_UNITS = {1: "decoded frames", 10: "posted calls", 12: "dispatched events",
              13: "sent frames"}
TRIGGERS = {0: None, 1: "late_audio", 2: "underrun"}
IRQ_NAMES = {7: "Machine timer", 31: "DMA0", 32: "DMA1", 36: "IR RX",
             43: "SPI0", 52: "Timer0 channel 0", 56: "I2S", 70: "Wi-Fi MAC",
             79: "Wi-Fi IPC"}


def irq_name(vector):
    name = IRQ_NAMES.get(vector)
    return f"IRQ {vector} ({name})" if name else f"IRQ {vector}"


def percentile_bound(counts, percentile):
    """Return the inclusive histogram bound containing the requested rank."""
    if not sum(counts):
        return None
    rank = (sum(counts) * percentile + 99) // 100
    for bound, count in zip((*WAIT_BOUNDS_US, None), counts):
        rank -= count
        if rank <= 0:
            return bound if bound is not None else f">{WAIT_BOUNDS_US[-1]}"
    raise AssertionError("rank exceeds sample count")


def decode_capture(raw):
    if len(raw) < HEADER.size:
        raise ValueError("capture header is truncated")
    (magic, version, session, elapsed, wfi_us, wfi_calls, region_count, capacity,
     event_count, event_next, overwritten, trace_requested, trigger, trigger_at,
     queue_min, late_us, underruns, irq_count) = HEADER.unpack_from(raw)
    if (magic != b"BPRF" or version not in (1, 2, 3) or region_count != len(REGIONS) or
            irq_count != (80 if version >= 2 else 0)):
        raise ValueError("unrecognized FreeNetRadio profile format")
    event_offset = HEADER.size + (region_count + irq_count) * TOTALS.size + 2 * HISTOGRAM.size
    event_end = event_offset + capacity * EVENT.size
    if (not capacity or event_count > capacity or event_next >= capacity or
            event_next != (event_count + overwritten) % capacity or
            (event_count < capacity and overwritten) or
            len(raw) != event_end + (HPM.size if version == 3 else 0)):
        raise ValueError("invalid capture size or ring cursor")
    if trigger not in TRIGGERS:
        raise ValueError("unrecognized trace trigger")

    regions = []
    offset = HEADER.size
    for index, name in enumerate(REGIONS):
        wall, cycles, instructions, work_cycles, calls, work, max_us, calls_with_work = (
            TOTALS.unpack_from(raw, offset))
        offset += TOTALS.size
        row = dict(name=name, wall_us=wall, cycles=cycles, instructions=instructions,
                   calls=calls, max_us=max_us)
        if index in WORK_UNITS:
            row.update(work=work, work_unit=WORK_UNITS[index],
                       calls_with_work=calls_with_work, cycles_with_work=work_cycles)
        regions.append(row)

    irqs = []
    for vector in range(irq_count):
        wall, cycles, instructions, _, calls, _, max_us, _ = TOTALS.unpack_from(raw, offset)
        offset += TOTALS.size
        if calls:
            irqs.append(dict(vector=vector, name=irq_name(vector), wall_us=wall,
                             cycles=cycles, instructions=instructions, calls=calls,
                             max_us=max_us))
    if irq_count:
        aggregate = regions[-1]
        for key in ("wall_us", "cycles", "instructions", "calls"):
            aggregate[key] = sum(row[key] for row in irqs)
        aggregate["max_us"] = max((row["max_us"] for row in irqs), default=0)

    waits = {}
    for name in ("sleep", "yield"):
        counts = HISTOGRAM.unpack_from(raw, offset)
        offset += HISTOGRAM.size
        waits[name] = dict(samples=sum(counts), counts=counts,
                           p50_us=percentile_bound(counts, 50),
                           p99_us=percentile_bound(counts, 99))

    events = []
    for index in range(event_count):
        slot = (event_next - event_count + index) % capacity
        events.append(EVENT.unpack_from(raw, event_offset + slot * EVENT.size))
    events.sort(key=lambda event: event[0])

    summary = dict(session=session, elapsed_us=elapsed, wfi_us=wfi_us,
                   wfi_calls=wfi_calls, underruns=underruns,
                   queue_min_frames=None if queue_min == 0xFFFFFFFF else queue_min,
                   waits=waits, wait_bounds_us=WAIT_BOUNDS_US, regions=regions,
                   irqs=irqs,
                   trace=dict(requested=bool(trace_requested), events=event_count,
                              overwritten=overwritten, trigger=TRIGGERS[trigger],
                              trigger_at_us=trigger_at if trigger else None,
                              late_threshold_us=late_us))
    if version == 3:
        *counters, mask = HPM.unpack_from(raw, event_end)
        if mask & 3 != 3 or mask >> len(M0_HPM_EVENTS):
            raise ValueError("invalid M0 hardware counter mask")
        summary["hardware_counters"] = {name: count for i, (name, count) in
            enumerate(zip(M0_HPM_EVENTS, counters)) if mask & (1 << i)}
    return summary, events


def perfetto_trace(events):
    """Create separate tracks for the measured scopes and interrupt vectors."""
    names = {}
    records = []
    for at_us, duration_us, value, kind, detail in events:
        if kind == 1 and detail < len(REGIONS):
            track = detail
            name = REGIONS[detail]
            args = {}
            if detail == 14:
                track = 100 + value
                name = irq_name(value)
            elif detail == 10:
                args["source"] = "timer" if value else "posted"
            elif detail in WORK_UNITS:
                args[WORK_UNITS[detail]] = value
            names[track] = name
            records.append(dict(name=name, ph="X", pid=1, tid=track,
                                ts=at_us, dur=duration_us, args=args))
        elif kind == 2:
            names[20] = "Audio wake"
            name = "Yield resume" if detail else "Timer resume"
            records.append(dict(name=name, ph="i", s="t", pid=1, tid=20, ts=at_us,
                                args=dict(delay_us=duration_us)))
        elif kind == 3:
            records.append(dict(name="DAC queue", ph="C", pid=1, tid=21, ts=at_us,
                                args=dict(frames=value)))
        elif kind == 4 and detail in (1, 2):
            names[20] = "Audio wake"
            records.append(dict(name=TRIGGERS[detail], ph="i", s="t",
                                pid=1, tid=20, ts=at_us, args=dict(value=value)))
        else:
            raise ValueError(f"unrecognized trace event {kind}/{detail}")
    metadata = [dict(name="thread_name", ph="M", pid=1, tid=track, args=dict(name=name))
                for track, name in names.items()]
    return dict(traceEvents=metadata + records, displayTimeUnit="ms")


def capture_from_board(base_url, seconds, summary_only):
    window_ms = round(seconds * 1000)
    path = "/profile/start-summary" if summary_only else "/profile/start"
    base_url = base_url.rstrip("/")
    request = Request(base_url + path, data=str(window_ms).encode("ascii"), method="POST")
    with urlopen(request, timeout=10) as response:
        if response.read() != b"recording\n":
            raise ValueError("board did not acknowledge the profiler start")
    time.sleep(window_ms / 1000)
    until = time.monotonic() + 10
    while True:
        try:
            with urlopen(base_url + "/profile/capture", timeout=15) as response:
                return response.read()
        except HTTPError as exc:
            if exc.code != 409 or time.monotonic() >= until:
                raise
        time.sleep(0.2)


def report(summary):
    elapsed = summary["elapsed_us"]
    wfi = 100 * summary["wfi_us"] / max(elapsed, 1)
    queue = summary["queue_min_frames"]
    low_water = f"{queue:,} frames" if queue is not None else "no playback samples"
    print(f"{elapsed / 1e6:.3f} s, WFI {wfi:.2f}%, DAC low water {low_water}, "
          f"{summary['underruns']} underruns")
    if "hardware_counters" in summary:
        print("M0 hardware counters")
        for name, count in summary["hardware_counters"].items():
            print(f"  {name:34s} {count:15,d}")
    print(f"{'Region (inclusive)':25} {'Calls':>8} {'Wall %':>7} "
          f"{'Cycles/call':>12} {'Insns/call':>12} {'Max us':>8}")
    rows = summary["regions"] + summary["irqs"]
    for row in sorted(rows, key=lambda item: -item["cycles"]):
        if not row["calls"]:
            continue
        print(f"{row['name']:25} {row['calls']:8,d} "
              f"{100 * row['wall_us'] / max(elapsed, 1):7.2f} "
              f"{row['cycles'] / row['calls']:12,.0f} "
              f"{row['instructions'] / row['calls']:12,.0f} {row['max_us']:8,d}")
        if "work" in row:
            calls = row["calls_with_work"]
            other = row["calls"] - calls
            active_cost = f"{row['cycles_with_work'] / calls:,.0f}" if calls else "n/a"
            other_cost = (f"{(row['cycles'] - row['cycles_with_work']) / other:,.0f}"
                          if other else "n/a")
            label = "posted" if row["work_unit"] == "posted calls" else "with work"
            print(f"  {row['work']:,} {row['work_unit']}  ·  "
                  f"cycles/call {label} {active_cost}, other calls {other_cost}")
    for name, row in summary["waits"].items():
        bound = f"{row['p99_us']} µs" if row["samples"] else "unavailable"
        print(f"Audio {name} delay p99 bucket upper bound {bound} "
              f"({row['samples']:,} samples)")
    trace = summary["trace"]
    print(f"Trace: {trace['events']} events, {trace['overwritten']} overwritten, "
          f"trigger {trace['trigger'] or 'none'}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    capture = subparsers.add_parser("capture", help="record a window on a running radio")
    capture.add_argument("url", help="radio base URL, e.g. http://192.168.1.114")
    capture.add_argument("--seconds", type=float, default=30)
    capture.add_argument("--summary-only", action="store_true")
    capture.add_argument("--out", type=Path,
                         default=Path("build/hw-validation/logs/freenetradio-profile"))
    analyze = subparsers.add_parser("analyze", help="decode a previously saved capture")
    analyze.add_argument("capture", type=Path)
    analyze.add_argument("--out", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "capture":
            if not 0.1 <= args.seconds <= 120:
                parser.error("--seconds must be between 0.1 and 120")
            raw = capture_from_board(args.url, args.seconds, args.summary_only)
            prefix = args.out
        else:
            raw = args.capture.read_bytes()
            prefix = args.out or args.capture.with_suffix("")
        summary, events = decode_capture(raw)
        trace = perfetto_trace(events) if summary["trace"]["requested"] else None
        prefix.parent.mkdir(parents=True, exist_ok=True)
        if args.command == "capture":
            Path(f"{prefix}.bin").write_bytes(raw)
        Path(f"{prefix}.summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        if trace is not None:
            Path(f"{prefix}.perfetto.json").write_text(json.dumps(trace) + "\n")
        report(summary)
    except (OSError, ValueError, http.client.HTTPException) as exc:
        print(f"profile_radio: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
