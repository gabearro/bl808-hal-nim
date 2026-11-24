#!/usr/bin/env python3
"""Audit saved Ox64 TCP DMA timing captures (no device access).

Each directory contains headers.pcap, device-trace.bin, and probe.json.
The wired SYN scopes the probe, not the timing or the transmit outcome.
An aggregate collapses byte-identical attempts at the same ring ordinals;
the trace has no boot ID. Exit 1 for incomplete or inconsistent evidence
(including no verified samples), 2 for invalid input.
"""

from __future__ import annotations

import argparse
import json
from collections import Counter, defaultdict
from collections.abc import Iterable
from dataclasses import dataclass, field
from pathlib import Path
from statistics import median

from analyze_wifi_tcp_path import (
    CAPACITY, DMA_SHAPE, DONE, DOORBELL, ENTRY, HTTP, HW_DONE, MAC, RETRY_LIMIT, RX,
    RX_REJECT, SNAPSHOT_SIZE, SUCCESS, SW_DONE, TICK_WRAP, TX, TX_REJECT,
    Event, Flow, Tcp, read_pcap, read_snapshot,
)


KINDS = ("SYN-ACK", "data")
OUTCOMES = ("ok", "retry-limit", "other")
STAGES = {TX: "TX output", TX_REJECT: "TX reject", DOORBELL: "DOORBELL",
          DMA_SHAPE: "DMA_SHAPE", HW_DONE: "HW_DONE", MAC: "host-confirm"}
SHAPE_FIELDS = ("hardware-head", "frame-size", "header-span", "buffer-span",
                "chain", "snap", "ipv4-length")
PUBLICATION_BIT = 1


@dataclass(frozen=True)
class Attempt:
    output: Event
    doorbell: Event
    done: Event
    confirm: Event
    shape: Event | None = None

    @property
    def outcome(self) -> str:
        status = self.done.detail
        if status & SUCCESS:
            return "ok"
        return "retry-limit" if status & RETRY_LIMIT else "other"

    @property
    def elapsed(self) -> tuple[int | None, int, int]:
        doorbell, done, confirm = (event.tick_offset_us for event in
                                  (self.doorbell, self.done, self.confirm))
        return (None if self.confirm.repush else doorbell - self.output.tick_offset_us,
                done - doorbell, confirm - done)


@dataclass
class Audit:
    head: int
    samples: list[Attempt] = field(default_factory=list)
    counts: Counter[str] = field(default_factory=Counter)
    issues: list[str] = field(default_factory=list)


def read_probe_ports(path: Path) -> tuple[set[int], int]:
    rows = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(rows, list) or not rows:
        raise ValueError("probe.json must contain a nonempty array of probes")
    ports, unresolved = set(), 0
    for index, row in enumerate(rows, 1):
        try:
            port = int(row["metrics"].split(maxsplit=1)[0])
            if not 0 <= port <= 65535 or port == HTTP:
                raise ValueError("expected a curl peer port other than the HTTP server port")
            if port in ports:
                raise ValueError(f"ambiguous repeated peer port {port}")
        except (AttributeError, IndexError, KeyError, TypeError, ValueError) as error:
            raise ValueError(f"probe.json row {index}: {error}") from error
        if port:
            ports.add(port)
        else:
            unresolved += 1
    return ports, unresolved


def client_syn(tcp: Tcp) -> bool:
    return tcp.dst == HTTP and tcp.kind == "SYN"


def key_label(event: Event) -> str:
    tcp = event.tcp
    return (f"port={tcp.dst} {tcp.kind} seq={tcp.seq} ack={tcp.ack} "
            f"flags=0x{tcp.flags:02x} len={tcp.length} ip_id={event.ip_id}")


def audit_key(events: list[Event], require_shape: bool = False) -> tuple[list[Attempt], str | None]:
    """Validate a complete exact-key chain before releasing any timing rows."""
    outputs = [event for event in events if event.stage == TX]
    if not outputs:
        raise ValueError("missing TX output; orphan timing or terminal record")
    if len(outputs) != 1:
        raise ValueError("ambiguous repeated TX output for exact key")
    output = outputs[0]
    if output != events[0]:
        raise ValueError("orphan record before TX output")
    if len(events) == 2 and events[1].stage == TX_REJECT:
        return [], "rejected"
    if any(event.stage == TX_REJECT for event in events):
        raise ValueError("ambiguous TX rejection alongside other records for exact key")
    if len(events) == 1:
        raise ValueError("missing DOORBELL or terminal record after TX output")

    def expect(index: int, stage: int) -> Event:
        previous = events[index - 1]
        if index == len(events):
            raise ValueError(f"missing {STAGES[stage]} after ordinal {previous.ordinal}")
        row = events[index]
        if row.stage != stage:
            raise ValueError(f"expected {STAGES[stage]}, got {STAGES[row.stage]} "
                             f"at ordinal {row.ordinal} (out of order, missing or orphan record)")
        return row

    def check_tick(previous: Event, row: Event) -> None:
        if not 0 <= row.tick_offset_us - previous.tick_offset_us < TICK_WRAP // 2:
            raise ValueError(f"out-of-order or ambiguous ticks between ordinals "
                             f"{previous.ordinal} and {row.ordinal}")

    attempts = []
    i = 1
    while i < len(events):
        row = events[i]
        check_tick(events[i - 1], row)
        if row.stage == MAC and row.detail & SW_DONE:
            if row.repush != len(attempts) or i + 1 != len(events):
                raise ValueError(f"ambiguous software retirement at ordinal {row.ordinal}")
            return attempts, "software-retired"

        doorbell = expect(i, DOORBELL)
        i += 1
        shape = None
        if i < len(events) and events[i].stage == DMA_SHAPE:
            shape = events[i]
            if (shape.ordinal != doorbell.ordinal + 1
                    or shape.tick_offset_us != doorbell.tick_offset_us):
                raise ValueError(f"DMA_SHAPE does not belong to doorbell at ordinal {doorbell.ordinal}")
            i += 1
        elif require_shape:
            raise ValueError(f"missing DMA_SHAPE after doorbell at ordinal {doorbell.ordinal}")
        done = expect(i, HW_DONE)
        confirm = expect(i + 1, MAC)
        check_tick(doorbell, done)
        check_tick(done, confirm)
        if done.detail & (DONE | SW_DONE) != DONE:
            raise ValueError(f"invalid raw HW_DONE status 0x{done.detail:08x} at ordinal {done.ordinal}")
        if (done.detail ^ confirm.detail) & ~PUBLICATION_BIT:
            raise ValueError(f"status mismatch at ordinals {done.ordinal}/{confirm.ordinal}: "
                             f"raw=0x{done.detail:08x} host=0x{confirm.detail:08x}")
        if confirm.repush != len(attempts):
            raise ValueError(f"expected repush={len(attempts)}, got {confirm.repush} "
                             f"at host-confirm ordinal {confirm.ordinal}")
        attempts.append(Attempt(output, doorbell, done, confirm, shape))
        i += 2
    return attempts, None


def audit_round(path: Path, require_shape: bool = False) -> tuple[Audit, bytes]:
    ports, unresolved = read_probe_ports(path / "probe.json")
    with (path / "device-trace.bin").open("rb") as trace:
        raw = trace.read(SNAPSHOT_SIZE + 1)
    snapshot = read_snapshot(raw)
    audit = Audit(snapshot.head)
    audit.counts.update({"probes": len(ports) + unresolved, "unresolved-port": unresolved})
    ring_start = max(0, snapshot.head - CAPACITY)
    holes = set(range(ring_start, snapshot.head)) - {e.ordinal for e in snapshot.events}
    if snapshot.invalid or snapshot.unused_nonzero:
        audit.issues.append(f"trace ring invalid={snapshot.invalid} stale-slots={snapshot.unused_nonzero}")

    wire: dict[int, dict[Flow, set[Tcp]]] = defaultdict(lambda: defaultdict(set))
    with (path / "headers.pcap").open("rb", buffering=0) as capture:
        for flow, tcp in read_pcap(capture):
            if flow.peer_port in ports:
                syns = wire[flow.peer_port][flow]
                if client_syn(tcp):
                    syns.add(tcp)

    syns_by_port: dict[int, list[Event]] = defaultdict(list)
    tx_by_port: dict[int, list[Event]] = defaultdict(list)
    for event in snapshot.events:
        tcp = event.tcp
        if event.stage in (RX, RX_REJECT) and tcp.src in ports and client_syn(tcp):
            syns_by_port[tcp.src].append(event)
        elif (event.stage in STAGES and tcp.src == HTTP and tcp.dst in ports
              and tcp.kind in KINDS):
            tx_by_port[tcp.dst].append(event)

    for port in sorted(ports):
        flows = wire[port]
        if len(flows) != 1:
            problem = "missing wired flow" if not flows else "ambiguous wired flows"
            audit.issues.append(f"port={port}: {problem}")
            continue
        wired_syns = next(iter(flows.values()))
        if len(wired_syns) != 1:
            problem = "missing wired SYN" if not wired_syns else "ambiguous wired SYN signatures"
            audit.issues.append(f"port={port}: {problem}")
            continue

        # Ring heads are boot-global; a snapshot can still hold earlier probes.
        # Require a wire anchor and stop at the next device SYN with a new ISN.
        syns = syns_by_port[port]
        matches = [event for event in syns if event.tcp in wired_syns]
        if not matches:
            audit.issues.append(f"port={port}: no retained trace SYN matching the wired SYN; "
                                "probe-window coverage unknown")
            continue
        start = matches[0]
        stop = next((event.ordinal for event in syns if event.ordinal > start.ordinal
                     and event.tcp.seq != start.tcp.seq), snapshot.head)
        if matches[-1].ordinal >= stop:
            audit.issues.append(f"port={port}: matching SYN recurs across connection boundaries")
            continue
        if any(start.ordinal < hole < stop for hole in holes):
            audit.issues.append(f"port={port}: invalid trace row in the probe window")
            continue

        audit.counts["scoped-ports"] += 1
        groups: dict[tuple[Tcp, int], list[Event]] = defaultdict(list)
        for row in tx_by_port[port]:
            if start.ordinal < row.ordinal < stop:
                groups[row.tcp, row.ip_id].append(row)
                audit.counts["outputs"] += row.stage == TX
        for events in groups.values():
            try:
                attempts, terminal = audit_key(events, require_shape)
            except ValueError as error:
                audit.counts["excluded-keys"] += 1
                audit.issues.append(f"{key_label(events[0])}: {error}")
            else:
                audit.samples.extend(attempts)
                for attempt in attempts:
                    shape = attempt.shape
                    if shape is not None and shape.detail >> 16:
                        audit.issues.append(f"{key_label(shape)}: DMA shape at ordinal "
                                            f"{shape.ordinal}: {format_shape(shape)}")
                if terminal is not None:
                    audit.counts[terminal] += 1

    if not audit.samples:
        audit.issues.append("no verified hardware timing samples")
    return audit, raw


def timing_stats(values: list[int]) -> str:
    if not values:
        return "n/a"
    values.sort()
    middle = str(median(values)).removesuffix(".0")
    return f"{values[0]}/{middle}/{values[(95 * len(values) - 1) // 100]}/{values[-1]}"


def print_summary(samples: Iterable[Attempt]) -> None:
    groups = defaultdict(list)
    for sample in samples:
        groups[sample.output.tcp.kind, bool(sample.confirm.repush), sample.outcome].append(sample)
    for kind in KINDS:
        for repush, label in ((False, "first-output"), (True, "repush")):
            for outcome in OUTCOMES:
                rows = groups[kind, repush, outcome]
                if not rows:
                    continue
                queue, dma, host = zip(*(row.elapsed for row in rows))
                print(f"  {kind} {label} {outcome} n={len(rows)} "
                      f"queue-to-first-doorbell={timing_stats([v for v in queue if v is not None])} "
                      f"doorbell-to-DONE={timing_stats(list(dma))} "
                      f"DONE-to-host={timing_stats(list(host))}")


def detail_line(sample: Attempt) -> str:
    detail = sample.doorbell.detail
    queue, dma, host = sample.elapsed
    mode = "appended" if detail & (1 << 19) else "new-head"
    tid = detail >> 24
    tid_text = "255(no-sw-seq)" if tid == 255 else str(tid)
    ordinals = "/".join(str(row.ordinal) for row in
                        (sample.output, sample.doorbell, sample.done, sample.confirm))
    return (f"{key_label(sample.output)} ordinals={ordinals} repush={sample.confirm.repush} "
            f"{sample.outcome} pre-MAC-seq-ctrl=0x{detail & 0xffff:04x} "
            f"AC={(detail >> 16) & 7} {mode} TID={tid_text} "
            f"raw=0x{sample.done.detail:08x} host=0x{sample.confirm.detail:08x} "
            f"queue-to-first-doorbell={queue if queue is not None else 'n/a'} "
            f"doorbell-to-DONE={dma} DONE-to-host={host}"
            + (f" {format_shape(sample.shape)}" if sample.shape is not None else ""))


def format_shape(shape: Event) -> str:
    flags = shape.detail >> 16
    names = [label for i, label in enumerate(SHAPE_FIELDS) if flags & (1 << i)]
    unknown = flags >> len(SHAPE_FIELDS)
    if unknown:
        names.append(f"unknown=0x{unknown:x}")
    return f"mac-bytes={shape.detail & 0xffff} shape={','.join(names) or 'ok'}"


def sample_identity(sample: Attempt, raw: bytes) -> tuple[tuple[int, bytes], ...]:
    # Relative offsets change between overlapping snapshots. Compare the raw
    # rows (including the original ticks) at their boot-global ordinals.
    def row_bytes(event: Event) -> tuple[int, bytes]:
        offset = 4 + event.ordinal % CAPACITY * ENTRY.size
        return event.ordinal, raw[offset:offset + ENTRY.size]

    rows = (sample.output, sample.doorbell, sample.done, sample.confirm)
    return tuple(map(row_bytes, rows if sample.shape is None else (*rows, sample.shape)))


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rounds", type=Path, nargs="+", metavar="CAPTURE_DIR")
    parser.add_argument("--detail-port", type=int, action="append", default=[],
                        help="show verified attempt details for this peer port (repeatable)")
    parser.add_argument("--require-shape", action="store_true",
                        help="require the optional pre-doorbell DMA shape record per submission")
    args = parser.parse_args(argv)
    if any(not 1 <= port <= 65535 or port == HTTP for port in args.detail_port):
        parser.error("--detail-port must be in 1..65535 and cannot be the HTTP server port")
    if len({path.resolve() for path in args.rounds}) != len(args.rounds):
        parser.error("the same capture directory was supplied more than once")

    print("Device elapsed times in us (min/median/p95/max). Queue starts at TX output before enqueue.")
    print("Doorbell is after the MMIO write; DONE is the accepted status read, not an on-air observation.")
    print("Only complete ordered chains with matching status (ignoring publication bit 0) are timed.")
    print("First-output is the initial attempt for each TCP output; repushes have no queue sample.")
    print("Probe windows start at a retained wired SYN match and end at the next different SYN or ring head. "
          "Curl port 0 is not assigned.")
    aggregate, repeated = {}, 0
    failed = invalid = 0
    for path in args.rounds:
        print(f"Capture: {path}")
        try:
            audit, raw = audit_round(path, args.require_shape)
        except (OSError, ValueError) as error:
            print(f"  Audit: INVALID: {error}")
            invalid += 1
            continue
        print(f"  Retained ring ordinals: [{max(0, audit.head - CAPACITY)}, {audit.head})")
        print("  " + " ".join(f"{key}={audit.counts[key]}" for key in
                             ("probes", "unresolved-port", "scoped-ports", "outputs",
                              "rejected", "software-retired", "excluded-keys"))
              + f" verified-attempts={len(audit.samples)}"
              + (f" shape-ok={sum(s.shape is not None and s.shape.detail >> 16 == 0 for s in audit.samples)}"
                 if args.require_shape or any(s.shape is not None for s in audit.samples) else ""))
        print_summary(audit.samples)
        for sample in sorted(audit.samples, key=lambda row: row.doorbell.ordinal):
            if sample.output.tcp.dst in args.detail_port:
                print(f"    {detail_line(sample)}")
            identity = sample_identity(sample, raw)
            repeated += identity in aggregate
            aggregate.setdefault(identity, sample)
        print("  Audit: " + ("FAIL (timings shown for verified keys only)" if audit.issues else "PASS"))
        for issue in audit.issues:
            print(f"    {issue}")
        failed += bool(audit.issues)

    if len(args.rounds) > 1:
        print(f"Aggregate: captures={len(args.rounds)} failed={failed} invalid={invalid} "
              f"verified-attempts={len(aggregate)} duplicate-ring-samples={repeated}")
        print_summary(aggregate.values())
    return 2 if invalid else int(bool(failed))


if __name__ == "__main__":
    raise SystemExit(main())
